// Orion owns different formats from Safari despite sharing WebKit. Its profile
// registry and flat bookmark tree are read as property lists, with parent IDs
// and sibling indices, following the public Orion reader cited in docs/MIGRATION.md.
// History uses Orion's own SQLite schema and the existing private snapshot.
// Unknown structures fail explicitly; named windows and the Orion keychain
// have no qualified adapter and are never guessed from Safari's formats.
import Foundation
import SQLite3

struct MigrationOrion: MigrationReader {
    let temporaryRoot: URL

    static func discover(in root: URL, cancellation: MigrationCancellation) throws -> [MigrationSource] {
        try cancellation.check()
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw MigrationFailure.unreadable }
        var candidates: [(String, String)] = [("", root.lastPathComponent)]
        if MigrationInput.exists("profiles", in: root) {
            let data = try MigrationInput.data("profiles", in: root, cancellation: cancellation)
            guard let registry = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let defaults = registry["defaults"] as? [String: Any],
                  let profiles = registry["profiles"] as? [[String: Any]] else { throw MigrationFailure.unsupported }
            guard profiles.count < 200 else { throw MigrationFailure.tooLarge }
            candidates = [("Defaults", try MigrationInput.text(defaults["name"]))]
            for profile in profiles {
                let id = try MigrationInput.text(profile["identifier"])
                guard !id.isEmpty, !id.contains("/"), id != ".", id != ".." else { throw MigrationFailure.malformed }
                candidates.append((id, try MigrationInput.text(profile["name"])))
            }
        } else if MigrationInput.exists("Defaults", in: root) { candidates.append(("Defaults", "Default")) }
        var seen = Set<String>(), result: [MigrationSource] = []
        for (path, name) in candidates {
            try cancellation.check()
            let folder = path.isEmpty ? root : try MigrationInput.file(path, in: root)
            guard seen.insert(folder.standardizedFileURL.path).inserted else { throw MigrationFailure.malformed }
            var categories = Set<MigrationCategory>()
            if MigrationInput.exists("favourites.plist", in: folder) { categories.insert(.bookmarks) }
            if MigrationInput.exists("history", in: folder) { categories.insert(.history) }
            if !categories.isEmpty {
                result.append(MigrationSource(id: MigrationLimits.identity("orion", folder.resolvingSymlinksInPath().path).uuidString,
                                              browser: "Orion", profile: name, location: folder, format: "orion", categories: categories))
            }
        }
        return result
    }

    func read(_ source: MigrationSource, categories: Set<MigrationCategory>, cancellation: MigrationCancellation) throws -> MigrationValues {
        var result = MigrationValues()
        if categories.contains(.bookmarks) {
            result = try Self.bookmarks(MigrationInput.data("favourites.plist", in: source.location, cancellation: cancellation), cancellation: cancellation)
        }
        if categories.contains(.history) {
            result.history = try MigrationSQLite.read(MigrationInput.file("history", in: source.location), temporaryRoot: temporaryRoot, cancellation: cancellation) { db in
                var visits: [MigrationVisit] = []
                try db.rows("SELECT url, title, visit_count, last_visit_time FROM history_items WHERE visit_count > 0 ORDER BY last_visit_time DESC LIMIT 2001", cancellation: cancellation) { row in
                    guard let url = MigrationLimits.url(try MigrationSQLite.text(row, 0)) else { return }
                    let count = sqlite3_column_int64(row, 2)
                    let date: Date?
                    switch sqlite3_column_type(row, 3) {
                    case SQLITE_INTEGER, SQLITE_FLOAT:
                        date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(row, 3))
                    case SQLITE_TEXT:
                        let text = try MigrationSQLite.text(row, 3)
                        date = ISO8601DateFormatter().date(from: text)
                    default: date = nil
                    }
                    guard let date, date.timeIntervalSince1970.isFinite, count > 0, count <= Int32.max,
                          date >= Date(timeIntervalSince1970: 0), date <= Date().addingTimeInterval(86400) else { return }
                    visits.append(MigrationVisit(url: url, title: try MigrationSQLite.text(row, 1), count: Int(count), last: date))
                }
                return visits
            }
            result.notices.append("History is limited to 2,000 places. Unsupported URLs and dates are omitted; numeric dates use Orion’s WebKit epoch (2001).")
        }
        result.notices.append("Orion’s named windows, pins, reading list, extensions and sign-ins are not transferred. This reader is tested on synthetic public-format fixtures, not a released Orion profile.")
        return result
    }

    static func bookmarks(_ data: Data, cancellation: MigrationCancellation) throws -> MigrationValues {
        guard data.count <= MigrationLimits.bytes else { throw MigrationFailure.tooLarge }
        guard let raw = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]] else { throw MigrationFailure.unsupported }
        guard raw.count <= MigrationLimits.records else { throw MigrationFailure.tooLarge }
        struct Node { let id: String; let parent: String; let title: String; let type: String; let index: Int; let url: String? }
        var nodes: [String: Node] = [:], children: [String: [Node]] = [:]
        var textBytes = 0
        for (key, item) in raw {
            try cancellation.check()
            let id = try MigrationInput.text(item["id"]), parent = try MigrationInput.text(item["parentId"])
            guard id == key, !id.isEmpty, let index = item["index"] as? Int, index >= 0 else { throw MigrationFailure.malformed }
            let node = Node(id: id, parent: parent, title: try MigrationInput.text(item["title"]),
                            type: try MigrationInput.text(item["type"]), index: index, url: item["url"] as? String)
            // Binary plists can share one string across thousands of records.
            // Bound the expanded canonical text as well as the source bytes.
            textBytes += id.utf8.count + parent.utf8.count + node.title.utf8.count + (node.url?.utf8.count ?? 0)
            guard textBytes <= MigrationLimits.bytes else { throw MigrationFailure.tooLarge }
            guard ["folder", "bookmark", "separator"].contains(node.type) else { throw MigrationFailure.unsupported }
            nodes[id] = node; children[parent, default: []].append(node)
        }
        func ordered(_ nodes: [Node]) -> [Node] { nodes.sorted { $0.index == $1.index ? $0.id < $1.id : $0.index < $1.index } }
        var seen = Set<String>(), omitted = 0
        func convert(_ node: Node, depth: Int, omitted: inout Int) throws -> MigrationBookmark? {
            try cancellation.check()
            guard depth <= MigrationLimits.depth else { throw MigrationFailure.tooLarge }
            guard seen.insert(node.id).inserted else { throw MigrationFailure.malformed }
            if node.type == "folder" {
                return MigrationBookmark(id: node.id, title: node.title, children: try ordered(children[node.id] ?? []).compactMap { try convert($0, depth: depth + 1, omitted: &omitted) })
            }
            guard children[node.id] == nil else { throw MigrationFailure.malformed }
            guard node.type == "bookmark", let text = node.url, let url = MigrationLimits.url(text) else { omitted += 1; return nil }
            return MigrationBookmark(id: node.id, title: node.title, url: url)
        }
        let roots = ordered(nodes.values.filter { nodes[$0.parent] == nil })
        var values = MigrationValues(bookmarks: try roots.compactMap { try convert($0, depth: 0, omitted: &omitted) })
        guard seen.count == nodes.count else { throw MigrationFailure.malformed }
        if omitted > 0 { values.notices.append("\(omitted) separators or unsupported bookmark URLs omitted.") }
        return values
    }
}
