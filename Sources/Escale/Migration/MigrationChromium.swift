// Chromium-format bookmarks and history, for one explicitly chosen profile.
// JSON version 1 is decoded structurally, with persistent GUID/ID provenance;
// SQLite uses the verified private snapshot in MigrationSQLite. Sharing this
// format does not qualify a distributed browser version or its private data.
// Cleartext sessions have their own bounded journal reader. Icons, collections,
// workspaces and encrypted passwords stay out.
// Chrome keeps account-only bookmarks in AccountBookmarks, same format; its
// permanent folders share their GUIDs with Bookmarks, so they are prefixed.
import Foundation
import SQLite3

struct MigrationChromium: MigrationReader {
    let temporaryRoot: URL
    func read(_ source: MigrationSource, categories: Set<MigrationCategory>, cancellation: MigrationCancellation) throws -> MigrationValues {
        var values = MigrationValues()
        if categories.contains(.bookmarks) {
            let files = MigrationProfiles.chromiumBookmarkFiles.filter {
                FileManager.default.fileExists(atPath: source.location.appendingPathComponent($0).path)
            }
            guard !files.isEmpty else { throw MigrationFailure.unreadable }
            for file in files {
                let read = try Self.bookmarks(MigrationInput.data(file, in: source.location, cancellation: cancellation), cancellation: cancellation,
                                              prefix: file == "Bookmarks" ? "" : "account:")
                values.bookmarks += read.bookmarks
                values.notices += read.notices.filter { !values.notices.contains($0) }
            }
        }
        if categories.contains(.history) {
            values.history = try MigrationSQLite.read(MigrationInput.file("History", in: source.location), temporaryRoot: temporaryRoot, cancellation: cancellation) { db in
                var places: [MigrationVisit] = []
                try db.rows("SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 AND visit_count > 0 ORDER BY last_visit_time DESC LIMIT 2001", cancellation: cancellation) { row in
                    let text = try MigrationSQLite.text(row, 0)
                    guard let url = MigrationLimits.url(text) else { return }
                    let count = sqlite3_column_int64(row, 2), stamp = sqlite3_column_int64(row, 3)
                    let date = Date(timeIntervalSince1970: Double(stamp) / 1_000_000 - 11_644_473_600)
                    guard count > 0, count <= Int32.max, date >= Date(timeIntervalSince1970: 0), date <= Date().addingTimeInterval(86400) else { return }
                    places.append(MigrationVisit(url: url, title: try MigrationSQLite.text(row, 1), count: Int(count), last: date))
                }
                return places
            }
            values.notices.append("History is limited to 2,000 places. Invalid dates and unsupported URLs are omitted.")
        }
        if categories.contains(.tabs) {
            let session = try MigrationChromiumSession.read(in: source.location, cancellation: cancellation)
            values.tabs = session.tabs; values.notices += session.notices
        }
        if MigrationBrowser(rawValue: source.browser)?.automatic != true {
            values.notices.append("Browser release is unqualified. Chromium-format bookmarks, history and supported cleartext sessions can be read; workspaces, collections, icons, extensions and sign-ins are not imported. Use CSV for passwords.")
        }
        return values
    }

    static func bookmarks(_ data: Data, cancellation: MigrationCancellation, prefix: String = "") throws -> MigrationValues {
        guard data.count <= MigrationLimits.bytes else { throw MigrationFailure.tooLarge }
        guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = top["version"] as? Int, version == 1,
              let roots = top["roots"] as? [String: Any] else { throw MigrationFailure.unsupported }
        var count = 0, skipped = 0
        func node(_ raw: [String: Any], depth: Int) throws -> MigrationBookmark? {
            try cancellation.check()
            count += 1
            guard count <= MigrationLimits.records, depth <= MigrationLimits.depth else { throw MigrationFailure.tooLarge }
            guard let title = raw["name"] as? String,
                  let identity = (raw["guid"] as? String) ?? (raw["id"] as? String), !identity.isEmpty,
                  let type = raw["type"] as? String else { throw MigrationFailure.malformed }
            guard title.utf8.count <= MigrationLimits.field else { throw MigrationFailure.tooLarge }
            switch type {
            case "folder":
                guard let children = raw["children"] as? [[String: Any]] else { throw MigrationFailure.malformed }
                return MigrationBookmark(id: prefix + identity, title: title, children: try children.compactMap { try node($0, depth: depth + 1) })
            case "url":
                guard let text = raw["url"] as? String else { throw MigrationFailure.malformed }
                guard let url = MigrationLimits.url(text) else { skipped += 1; return nil }
                return MigrationBookmark(id: prefix + identity, title: title, url: url)
            default: throw MigrationFailure.unsupported
            }
        }
        var values = MigrationValues()
        for key in ["bookmark_bar", "other", "synced"] {
            if let raw = roots[key] as? [String: Any], let root = try node(raw, depth: 0) { values.bookmarks.append(root) }
        }
        guard !values.bookmarks.isEmpty else { throw MigrationFailure.malformed }
        if skipped > 0 { values.notices.append("\(skipped) bookmarks with unsupported URLs omitted.") }
        if Set(roots.keys).subtracting(["bookmark_bar", "other", "synced"]).isEmpty == false {
            values.notices.append("Additional browser-specific bookmark roots are not imported.")
        }
        return values
    }
}
