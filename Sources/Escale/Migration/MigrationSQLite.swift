// SQLite is only opened on a private, verified copy: even a read-only SQLite
// connection can create/update shared-memory sidecars in the source directory.
// Copy main, WAL and rollback journal, then reread and hash each with unchanged
// file identities and timestamps before using SQLite's backup API on that copy.
// Chrome's History keeps a rollback journal: copied with it, a write caught
// half-done is rolled back on the copy, where the main file alone would read
// uncommitted rows. Active changes fail explicitly; this is not a transaction
// across a whole browser profile.
// Input is capped at 256 MiB total, copied in 1 MiB chunks; temporary files are
// owned by one call and removed on all exits. No password database is accepted.
import Foundation
import CryptoKit
import SQLite3

final class MigrationSQLite {
    private let db: OpaquePointer
    private init(_ db: OpaquePointer) { self.db = db }
    private static let scratchLock = NSLock()
    static let byteLimit = 256 * 1024 * 1024

    private struct Stamp: Equatable {
        let size: Int
        let modified: Date
        let inode: UInt64
    }

    private static func stamp(_ file: URL) throws -> Stamp? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let values = try FileManager.default.attributesOfItem(atPath: file.path)
        guard values[.type] as? FileAttributeType == .typeRegular,
              let size = values[.size] as? NSNumber, let modified = values[.modificationDate] as? Date,
              let inode = values[.systemFileNumber] as? NSNumber else { throw MigrationFailure.unreadable }
        guard size.intValue <= byteLimit else { throw MigrationFailure.tooLarge }
        return Stamp(size: size.intValue, modified: modified, inode: inode.uint64Value)
    }

    private static func copyHash(_ source: URL, to destination: URL?, cancellation: MigrationCancellation) throws -> SHA256.Digest {
        let read = try FileHandle(forReadingFrom: source)
        defer { try? read.close() }
        var write: FileHandle?
        if let destination {
            guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw MigrationFailure.storage }
            write = try FileHandle(forWritingTo: destination)
        }
        defer { try? write?.close() }
        var hash = SHA256(), count = 0
        while true {
            try cancellation.check()
            let chunk = try read.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            count += chunk.count
            guard count <= byteLimit else { throw MigrationFailure.tooLarge }
            hash.update(data: chunk)
            try write?.write(contentsOf: chunk)
        }
        return hash.finalize()
    }

    static func read<T>(_ file: URL, temporaryRoot: URL, cancellation: MigrationCancellation,
                        afterCopy: (() throws -> Void)? = nil, body: (MigrationSQLite) throws -> T) throws -> T {
        scratchLock.lock()
        defer { scratchLock.unlock() }
        try cancellation.check()
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Recover only our UUID-named directories after an interrupted process.
        // The process-wide lock prevents a second reader cleaning a live copy.
        for old in try FileManager.default.contentsOfDirectory(at: temporaryRoot, includingPropertiesForKeys: nil) {
            let name = old.lastPathComponent
            if name.hasPrefix("snapshot-"), UUID(uuidString: String(name.dropFirst(9))) != nil {
                try FileManager.default.removeItem(at: old)
            }
        }
        let files = ["", "-wal", "-journal"].map { URL(fileURLWithPath: file.path + $0) }
        let before = try files.map(stamp)
        guard before[0] != nil else { throw MigrationFailure.unreadable }
        guard before.compactMap({ $0 }).reduce(0, { $0 + $1.size }) <= byteLimit else { throw MigrationFailure.tooLarge }
        let scratch = temporaryRoot.appendingPathComponent("snapshot-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent("source.db")
        let destinations = ["", "-wal", "-journal"].map { URL(fileURLWithPath: copy.path + $0) }
        var hashes: [SHA256.Digest?] = []
        for i in files.indices {
            hashes.append(before[i] == nil ? nil : try copyHash(files[i], to: destinations[i], cancellation: cancellation))
        }
        try afterCopy?()
        for i in files.indices {
            guard try stamp(files[i]) == before[i] else { throw MigrationFailure.sourceChanged }
            if let hash = hashes[i] {
                guard try copyHash(files[i], to: nil, cancellation: cancellation) == hash else { throw MigrationFailure.sourceChanged }
            }
        }
        guard try files.map(stamp) == before else { throw MigrationFailure.sourceChanged }
        var source: OpaquePointer?, snapshot: OpaquePointer?
        defer { if let source { sqlite3_close(source) }; if let snapshot { sqlite3_close(snapshot) } }
        guard sqlite3_open_v2(copy.path, &source, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let source,
              sqlite3_open_v2(scratch.appendingPathComponent("snapshot.db").path, &snapshot, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let snapshot else { throw MigrationFailure.unreadable }
        sqlite3_limit(source, SQLITE_LIMIT_LENGTH, Int32(MigrationLimits.bytes))
        sqlite3_limit(snapshot, SQLITE_LIMIT_LENGTH, Int32(MigrationLimits.bytes))
        // Lock waits and the backup have a deadline; a live writer cannot keep
        // an import indefinitely busy, even when its copied WAL is damaged.
        sqlite3_busy_timeout(source, 100)
        var pageSize: Int64 = 0
        try MigrationSQLite(source).rows("PRAGMA page_size", cancellation: cancellation) { pageSize = sqlite3_column_int64($0, 0) }
        guard pageSize >= 512, pageSize <= 65_536 else { throw MigrationFailure.malformed }
        guard let backup = sqlite3_backup_init(snapshot, "main", source, "main") else { throw MigrationFailure.malformed }
        var result: Int32 = SQLITE_OK
        let deadline = Date().addingTimeInterval(5)
        do {
            repeat {
                try cancellation.check()
                guard Date() < deadline else { throw MigrationFailure.unreadable }
                result = sqlite3_backup_step(backup, 256)
                guard Int64(sqlite3_backup_pagecount(backup)) * pageSize <= Int64(byteLimit) else { throw MigrationFailure.tooLarge }
            } while result == SQLITE_OK
        } catch { sqlite3_backup_finish(backup); throw error }
        let finish = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finish == SQLITE_OK else { throw MigrationFailure.malformed }
        sqlite3_exec(snapshot, "PRAGMA query_only=ON; PRAGMA trusted_schema=OFF; PRAGMA cache_size=-2048", nil, nil, nil)
        return try body(MigrationSQLite(snapshot))
    }

    private final class QueryBudget {
        let cancellation: MigrationCancellation
        let deadline = Date().addingTimeInterval(5)
        init(_ cancellation: MigrationCancellation) { self.cancellation = cancellation }
    }

    func rows(_ sql: String, cancellation: MigrationCancellation, each: (OpaquePointer) throws -> Void) throws {
        let budget = QueryBudget(cancellation)
        let context = Unmanaged.passUnretained(budget).toOpaque()
        sqlite3_progress_handler(db, 1_000, { context in
            guard let context else { return 1 }
            let budget = Unmanaged<QueryBudget>.fromOpaque(context).takeUnretainedValue()
            do { try budget.cancellation.check() } catch { return 1 }
            return Date() < budget.deadline ? 0 : 1
        }, context)
        defer { sqlite3_progress_handler(db, 0, nil, nil); withExtendedLifetime(budget) {} }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw MigrationFailure.unsupported }
        defer { sqlite3_finalize(statement) }
        var count = 0
        while true {
            try cancellation.check()
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            try cancellation.check()
            guard result == SQLITE_ROW else { throw MigrationFailure.malformed }
            count += 1
            guard count <= MigrationLimits.records else { throw MigrationFailure.tooLarge }
            try each(statement)
        }
    }

    static func text(_ row: OpaquePointer, _ column: Int32) throws -> String {
        guard sqlite3_column_bytes(row, column) <= MigrationLimits.field else { throw MigrationFailure.tooLarge }
        return sqlite3_column_text(row, column).map { String(cString: $0) } ?? ""
    }
}
