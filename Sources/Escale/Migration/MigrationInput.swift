// Profile files are untrusted and can change while their browser is running.
// A bounded snapshot checks the file identity, size and modification date on
// both sides of the read. Links may not escape the selected profile. SQLite
// has its separate coherent acquisition in MigrationSQLite; neither reader
// repairs or writes the original. This is per-file, not a profile transaction.
import Foundation

enum MigrationInput {
    static func file(_ name: String, in root: URL) throws -> URL {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(base.path + "/") else { throw MigrationFailure.unreadable }
        return file
    }

    static func exists(_ name: String, in root: URL) -> Bool {
        guard let file = try? file(name, in: root) else { return false }
        return FileManager.default.fileExists(atPath: file.path)
    }

    static func data(_ name: String, in root: URL, cancellation: MigrationCancellation) throws -> Data {
        try cancellation.check()
        let file = try file(name, in: root)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        guard before[.type] as? FileAttributeType == .typeRegular else { throw MigrationFailure.unreadable }
        let data = try MigrationLimits.data(file)
        try cancellation.check()
        let afterFile = try self.file(name, in: root)
        let after = try FileManager.default.attributesOfItem(atPath: afterFile.path)
        for key in [FileAttributeKey.systemFileNumber, .size, .modificationDate] {
            guard (before[key] as? NSObject) == (after[key] as? NSObject) else { throw MigrationFailure.sourceChanged }
        }
        guard file == afterFile else { throw MigrationFailure.sourceChanged }
        return data
    }

    static func text(_ value: Any?) throws -> String {
        guard let value = value as? String else { throw MigrationFailure.malformed }
        guard value.utf8.count <= MigrationLimits.field else { throw MigrationFailure.tooLarge }
        return value
    }
}
