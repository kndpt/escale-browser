// Values crossing the migration boundary contain no live browser objects.
// A selected profile is distinct from a visual workspace. Limits reject a
// whole overlarge input rather than silently deleting durable bookmarks.
// Secrets deliberately do not conform to Codable or appear in diagnostics.
import Foundation
import CryptoKit

enum MigrationCategory: String, CaseIterable, Codable, Hashable {
    case bookmarks, history, tabs, passwords
}

struct MigrationSource: Identifiable, Hashable {
    let id: String
    let browser: String
    let profile: String
    let location: URL
    let format: String
    var version: String = "Unqualified version"
    var categories: Set<MigrationCategory>
    /// A selection inside the source's files, such as one Arc Space.
    var part: String? = nil
}

struct MigrationBookmark: Equatable {
    let id: String
    let title: String
    var url: URL?
    var children: [MigrationBookmark] = []
}

struct MigrationVisit: Equatable {
    let url: URL
    let title: String
    let count: Int
    let last: Date
}

struct MigrationPassword {
    let host: String
    let user: String
    let password: String
}

struct MigrationTab: Equatable {
    let id: String
    let url: URL
    let title: String
    var pinned = false
}

struct MigrationValues {
    var bookmarks: [MigrationBookmark] = []
    var history: [MigrationVisit] = []
    var passwords: [MigrationPassword] = []
    var tabs: [MigrationTab] = []
    var notices: [String] = []
}

protocol MigrationReader {
    func read(_ source: MigrationSource, categories: Set<MigrationCategory>,
              cancellation: MigrationCancellation) throws -> MigrationValues
}

final class MigrationCancellation {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = stopped; lock.unlock()
        if value { throw MigrationFailure.cancelled }
    }
}

enum MigrationFailure: Error, LocalizedError, Equatable {
    case encryptedSession, cancelled, tooLarge, unreadable, unsupported, malformed, sourceChanged, destinationGone, destinationChanged, storage, keychain
    var errorDescription: String? {
        switch self {
        case .encryptedSession: return "This browser encrypts its saved sessions. Escale cannot import them. Save the tabs as bookmarks and import those instead."
        case .cancelled: return "Import stopped. Completed categories remain saved."
        case .tooLarge: return "This source exceeds the import limits. Export a smaller selection."
        case .unreadable: return "The selected source could not be read. Check its permissions or choose an export."
        case .unsupported: return "This format or version is not supported. Choose a bookmarks HTML or passwords CSV export."
        case .malformed: return "The selected data is incomplete or damaged. Make a fresh export."
        case .sourceChanged: return "The source changed while being read. Close that browser or choose a fresh export, then retry."
        case .destinationGone: return "The destination Space no longer exists. Choose another Space."
        case .destinationChanged: return "Bookmarks changed since the preview. Preview this import again."
        case .storage: return "Changes could not be saved. Check free disk space, then retry."
        case .keychain: return "The keychain did not accept all passwords. Unlock it and retry."
        }
    }

    /// macOS refuses a browser's data folder to an app that was not handed it,
    /// and for these folders it does so without ever asking the person. Only a
    /// choice made in the file picker lifts the refusal, so it is told apart
    /// from a missing or damaged folder.
    static func refused(_ error: Error) -> Bool {
        let error = error as NSError
        let code = error.domain == NSPOSIXErrorDomain ? Int32(error.code)
            : (error.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? Int32($0.code) : nil }
        if let code, code == EPERM || code == EACCES { return true }
        return error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError
    }
}

enum MigrationLimits {
    static let bytes = 32 * 1024 * 1024
    static let records = 50_000
    static let depth = 32
    static let field = 32_768

    static func data(_ file: URL) throws -> Data {
        // Read through a handle with a cap, including files replaced/grown after selection.
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw MigrationFailure.unreadable }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes + 1) else { throw MigrationFailure.unreadable }
        guard data.count <= bytes else { throw MigrationFailure.tooLarge }
        return data
    }

    static func text(_ file: URL) throws -> String {
        let data = try self.data(file)
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
        } else { text = String(data: data, encoding: .utf8) }
        guard let text else { throw MigrationFailure.unsupported }
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    static func url(_ text: String) -> URL? {
        guard text.utf8.count <= field, let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func identity(_ parts: String...) -> UUID {
        let digest = SHA256.hash(data: Data(parts.map { "\($0.utf8.count):\($0)" }.joined().utf8))
        let b = Array(digest.prefix(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
