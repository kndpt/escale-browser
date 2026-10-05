// Mozilla's jsonlz4 envelope is not an LZ4 frame: eight magic bytes, a little
// endian expanded length and one raw block. Apple Compression decodes that
// block after its tokens have been checked against both bounds. Validation
// also rejects trailing data and invalid back-references that a size-only
// native decode cannot distinguish. No external codec or source code is used.
import Foundation
import Compression

enum MigrationMozLZ4 {
    static func decode(_ data: Data, cancellation: MigrationCancellation) throws -> Data {
        try cancellation.check()
        guard data.count <= MigrationLimits.bytes else { throw MigrationFailure.tooLarge }
        guard data.count >= 13, data.prefix(8) == Data([109, 111, 122, 76, 122, 52, 48, 0]) else { throw MigrationFailure.malformed }
        let length = (0..<4).reduce(0) { $0 | (Int(data[8 + $1]) << (8 * $1)) }
        guard length > 0, length <= MigrationLimits.bytes else { throw MigrationFailure.tooLarge }
        var cursor = 12, expanded = 0
        func extended(_ initial: Int) throws -> Int {
            var size = initial
            if initial == 15 {
                while true {
                    guard cursor < data.count else { throw MigrationFailure.malformed }
                    let byte = Int(data[cursor]); cursor += 1; size += byte
                    guard size <= MigrationLimits.bytes else { throw MigrationFailure.tooLarge }
                    if byte != 255 { break }
                }
            }
            return size
        }
        while cursor < data.count {
            try cancellation.check()
            let token = Int(data[cursor]); cursor += 1
            let literals = try extended(token >> 4)
            guard literals <= data.count - cursor, literals <= length - expanded else { throw MigrationFailure.malformed }
            cursor += literals; expanded += literals
            if cursor == data.count { break }
            guard data.count - cursor >= 2 else { throw MigrationFailure.malformed }
            let offset = Int(data[cursor]) | (Int(data[cursor + 1]) << 8); cursor += 2
            guard offset > 0, offset <= expanded else { throw MigrationFailure.malformed }
            let match = try extended(token & 15) + 4
            guard match <= length - expanded else { throw MigrationFailure.malformed }
            expanded += match
        }
        guard expanded == length else { throw MigrationFailure.malformed }
        var output = Data(count: length)
        let count = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                guard let dst = destination.bindMemory(to: UInt8.self).baseAddress,
                      let src = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dst, length, src + 12, data.count - 12, nil, COMPRESSION_LZ4_RAW)
            }
        }
        guard count == length else { throw MigrationFailure.malformed }
        try cancellation.check()
        return output
    }
}
