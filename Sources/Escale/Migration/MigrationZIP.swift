// Safari exports are ZIP containers, but extraction must not write plaintext
// credentials or trust archive paths. Read a bounded central directory and
// inflate one entry at a time using the macOS toolchain's zlib. ZIP64,
// encryption, symlinks and overlapping members are rejected. Both compressed
// input and total expanded data are capped at 32 MiB; there are at most 128
// entries. CRC and actual stream lengths are checked before interpreting data.
import Foundation
import zlib

struct MigrationZIP {
    struct Entry {
        let name: String
        let start: Int
        let compressed: Int
        let expanded: Int
        let method: Int
        let crc: UInt32
    }
    let data: Data
    let entries: [Entry]

    init(_ data: Data) throws {
        guard data.count <= MigrationLimits.bytes else { throw MigrationFailure.tooLarge }
        guard data.count >= 22 else { throw MigrationFailure.malformed }
        func number(_ offset: Int, _ size: Int) throws -> Int {
            guard offset >= 0, offset + size <= data.count else { throw MigrationFailure.malformed }
            return (0..<size).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
        }
        var end: Int?
        for at in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if (try number(at, 4)) == 0x06054b50, at + 22 + (try number(at + 20, 2)) == data.count { end = at; break }
        }
        guard let end else { throw MigrationFailure.malformed }
        guard (try number(end + 4, 2)) == 0, (try number(end + 6, 2)) == 0 else { throw MigrationFailure.unsupported }
        let count = (try number(end + 10, 2)), size = (try number(end + 12, 4)), start = (try number(end + 16, 4))
        guard count <= 128 else { throw MigrationFailure.tooLarge }
        guard (try number(end + 8, 2)) == count, start + size == end else { throw MigrationFailure.malformed }
        var cursor = start, total = 0, made: [Entry] = [], names = Set<String>(), spans: [Range<Int>] = []
        for _ in 0..<count {
            guard (try number(cursor, 4)) == 0x02014b50 else { throw MigrationFailure.malformed }
            let flags = (try number(cursor + 8, 2)), method = (try number(cursor + 10, 2))
            let crc = (try number(cursor + 16, 4)), compressed = (try number(cursor + 20, 4)), expanded = (try number(cursor + 24, 4))
            let nameLength = (try number(cursor + 28, 2)), extra = (try number(cursor + 30, 2)), comment = (try number(cursor + 32, 2))
            let external = (try number(cursor + 38, 4)), local = (try number(cursor + 42, 4))
            guard flags & 1 == 0, flags & 0x40 == 0, [0, 8].contains(method),
                  (external >> 16) & 0xF000 != 0xA000, (try number(cursor + 34, 2)) == 0 else { throw MigrationFailure.unsupported }
            total += expanded
            guard total <= MigrationLimits.bytes, compressed <= MigrationLimits.bytes else { throw MigrationFailure.tooLarge }
            guard cursor + 46 + nameLength + extra + comment <= end else { throw MigrationFailure.malformed }
            let nameData = data.subdata(in: cursor + 46..<cursor + 46 + nameLength)
            guard let name = String(data: nameData, encoding: .utf8), !name.isEmpty,
                  !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"),
                  !name.split(separator: "/").contains(".."), !name.split(separator: "/").contains("."),
                  names.insert(name.lowercased()).inserted else { throw MigrationFailure.malformed }
            guard (try number(local, 4)) == 0x04034b50, (try number(local + 6, 2)) == flags,
                  (try number(local + 8, 2)) == method else { throw MigrationFailure.malformed }
            let localName = (try number(local + 26, 2)), localExtra = (try number(local + 28, 2))
            let payload = local + 30 + localName + localExtra
            guard payload + compressed <= start, local + 30 + localName <= start,
                  data.subdata(in: local + 30..<local + 30 + localName) == nameData else { throw MigrationFailure.malformed }
            if flags & 8 == 0 {
                guard (try number(local + 14, 4)) == crc, (try number(local + 18, 4)) == compressed,
                      (try number(local + 22, 4)) == expanded else { throw MigrationFailure.malformed }
            }
            let span = local..<payload + compressed
            guard !spans.contains(where: { $0.overlaps(span) }) else { throw MigrationFailure.malformed }
            spans.append(span)
            if !name.hasSuffix("/") { made.append(Entry(name: name, start: payload, compressed: compressed, expanded: expanded, method: method, crc: UInt32(crc))) }
            else if expanded != 0 { throw MigrationFailure.malformed }
            cursor += 46 + nameLength + extra + comment
        }
        guard cursor == end else { throw MigrationFailure.malformed }
        self.data = data; entries = made
    }

    func contents(_ entry: Entry) throws -> Data {
        let compressed = data.subdata(in: entry.start..<entry.start + entry.compressed)
        let output: Data
        if entry.method == 0 {
            guard compressed.count == entry.expanded else { throw MigrationFailure.malformed }
            output = compressed
        } else {
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw MigrationFailure.malformed }
            defer { inflateEnd(&stream) }
            var bytes = [UInt8](repeating: 0, count: entry.expanded + 1)
            let result = compressed.withUnsafeBytes { source -> Int32 in
                bytes.withUnsafeMutableBytes { target in
                    stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(compressed.count)
                    stream.next_out = target.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(target.count)
                    return inflate(&stream, Z_FINISH)
                }
            }
            guard result == Z_STREAM_END, stream.total_out == entry.expanded,
                  stream.total_in == entry.compressed else { throw MigrationFailure.malformed }
            output = Data(bytes.prefix(entry.expanded))
        }
        let crc = output.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(output.count)) }
        guard UInt32(crc) == entry.crc else { throw MigrationFailure.malformed }
        return output
    }
}
