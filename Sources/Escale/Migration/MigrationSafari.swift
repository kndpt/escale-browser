// Safari's documented export separates shared bookmarks/passwords from each
// profile's history. Identify files by content, never localized basenames.
// Shared data is a separate choice so it is not silently assigned to every
// profile. Cards and extension binaries are never imported; extension metadata
// is counted only. The ZIP remains in memory and is never extracted to disk.
import Foundation

struct MigrationSafari: MigrationReader {
    static let shared = "Shared bookmarks and passwords"

    static func discover(_ file: URL, cancellation: MigrationCancellation) throws -> [MigrationSource] {
        let zip = try MigrationZIP(MigrationLimits.data(file))
        var common = Set<MigrationCategory>(), profiles: [MigrationSource] = []
        let sourceID = MigrationLimits.identity("safari", file.standardizedFileURL.path).uuidString
        for entry in zip.entries {
            try cancellation.check()
            let data = try zip.contents(entry)
            if let text = text(data), isHTML(text) { common.insert(.bookmarks) }
            else if let text = text(data), isCSV(text) { common.insert(.passwords) }
            else if let metadata = metadata(data), metadata["data_type"] as? String == "history" {
                try validate(metadata)
                profiles.append(MigrationSource(id: MigrationLimits.identity(sourceID, entry.name).uuidString, browser: "Safari",
                                                profile: entry.name, location: file, format: "safari",
                                                version: metadata["browser_version"] as? String ?? "Unknown", categories: [.history]))
            }
        }
        if !common.isEmpty {
            profiles.insert(MigrationSource(id: MigrationLimits.identity(sourceID, "shared").uuidString, browser: "Safari",
                                            profile: shared, location: file, format: "safari", categories: common), at: 0)
        }
        guard !profiles.isEmpty else { throw MigrationFailure.unsupported }
        return profiles
    }

    func read(_ source: MigrationSource, categories: Set<MigrationCategory>, cancellation: MigrationCancellation) throws -> MigrationValues {
        let zip = try MigrationZIP(MigrationLimits.data(source.location))
        var values = MigrationValues(), found = Set<MigrationCategory>(), extensions = 0
        for entry in zip.entries {
            try cancellation.check()
            let data = try zip.contents(entry)
            if categories.contains(.bookmarks), let text = Self.text(data), Self.isHTML(text) {
                guard found.insert(.bookmarks).inserted else { throw MigrationFailure.malformed }
                let decoded = try MigrationExchange.html(text)
                values.bookmarks = decoded.bookmarks; values.notices += decoded.notices
            } else if categories.contains(.passwords), let text = Self.text(data), Self.isCSV(text) {
                guard found.insert(.passwords).inserted else { throw MigrationFailure.malformed }
                let decoded = try MigrationExchange.csv(text)
                values.passwords = decoded.passwords; values.notices += decoded.notices
            } else if let metadata = Self.metadata(data) {
                if categories.contains(.history), entry.name == source.profile, metadata["data_type"] as? String == "history" {
                    try Self.validate(metadata)
                    guard found.insert(.history).inserted else { throw MigrationFailure.malformed }
                    values.history = try Self.history(data)
                } else if metadata["data_type"] as? String == "extensions",
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let list = object["extensions"] as? [[String: Any]] { extensions += list.count }
            }
        }
        guard found == categories else { throw MigrationFailure.sourceChanged }
        values.notices.append("Safari bookmarks and passwords are shared across profiles. History is imported only for the selected profile; Escale Spaces have separate sign-ins.")
        values.notices.append("Open tabs, tab groups, pins, payment cards, cookies and passkeys are not imported.")
        if extensions > 0 { values.notices.append("The archive lists \(extensions) extensions. Reinstall compatible extensions yourself in Settings; WebKit extensions require macOS 15.4 or later.") }
        return values
    }

    static func history(_ data: Data) throws -> [MigrationVisit] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = object["metadata"] as? [String: Any],
              let history = object["history"] as? [[String: Any]] else { throw MigrationFailure.malformed }
        try validate(metadata)
        guard history.count <= MigrationLimits.records else { throw MigrationFailure.tooLarge }
        return try history.compactMap { row in
            guard let raw = row["url"] as? String, let stamp = row["time_usec"] as? Double,
                  let count = row["visits_count"] as? Int, count > 0, count <= Int32.max else { throw MigrationFailure.malformed }
            guard let url = MigrationLimits.url(raw) else { return nil }
            let date = Date(timeIntervalSince1970: stamp / 1_000_000)
            guard date >= Date(timeIntervalSince1970: 0), date <= Date().addingTimeInterval(86400) else { return nil }
            return MigrationVisit(url: url, title: row["title"] as? String ?? "", count: count, last: date)
        }
    }

    private static func validate(_ metadata: [String: Any]) throws {
        guard metadata["schema_version"] as? Int == 1,
              ["Safari", "Safari Technology Preview"].contains(metadata["browser_name"] as? String ?? "") else { throw MigrationFailure.unsupported }
    }

    private static func metadata(_ data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["metadata"] as? [String: Any]
    }

    private static func text(_ data: Data) -> String? {
        let text = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
            ? String(data: data, encoding: .utf16) : String(data: data, encoding: .utf8)
        return text.map { $0.hasPrefix("\u{FEFF}") ? String($0.dropFirst()) : $0 }
    }
    private static func isHTML(_ text: String) -> Bool {
        text.prefix(4096).range(of: "NETSCAPE-Bookmark-file", options: .caseInsensitive) != nil
    }
    private static func isCSV(_ text: String) -> Bool {
        let header = text.prefix(4096).components(separatedBy: .newlines).first?.lowercased() ?? ""
        return header.contains("url") && header.contains("username") && header.contains("password")
    }
}
