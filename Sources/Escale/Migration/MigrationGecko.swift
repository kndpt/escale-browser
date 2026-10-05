// Places owns Gecko bookmarks and history, independently of its compressed
// session state. Both categories use one verified SQLite snapshot. GUIDs and
// sibling positions preserve repeated URLs, empty folders and source order;
// containers and visual workspaces are not invented from a profile's name.
import Foundation
import SQLite3

struct MigrationGecko: MigrationReader {
    let temporaryRoot: URL

    private struct Node {
        let id: Int64
        let parent: Int64
        let type: Int64
        let title: String
        let url: String
        let position: Int64
        let guid: String
    }

    func read(_ source: MigrationSource, categories: Set<MigrationCategory>, cancellation: MigrationCancellation) throws -> MigrationValues {
        var result = MigrationValues()
        if !categories.intersection([.bookmarks, .history]).isEmpty {
            result = try MigrationSQLite.read(MigrationInput.file("places.sqlite", in: source.location), temporaryRoot: temporaryRoot, cancellation: cancellation) { db in
            var values = MigrationValues()
            if categories.contains(.bookmarks) {
                var nodes: [Int64: Node] = [:], children: [Int64: [Node]] = [:]
                try db.rows("SELECT b.id, b.parent, b.type, b.title, p.url, b.position, b.guid FROM moz_bookmarks b LEFT JOIN moz_places p ON b.fk = p.id", cancellation: cancellation) { row in
                    let node = Node(id: sqlite3_column_int64(row, 0), parent: sqlite3_column_int64(row, 1), type: sqlite3_column_int64(row, 2),
                                    title: try MigrationSQLite.text(row, 3), url: try MigrationSQLite.text(row, 4),
                                    position: sqlite3_column_int64(row, 5), guid: try MigrationSQLite.text(row, 6))
                    guard nodes[node.id] == nil, node.position >= 0, !node.guid.isEmpty else { throw MigrationFailure.malformed }
                    nodes[node.id] = node; children[node.parent, default: []].append(node)
                }
                var seen = Set<Int64>(), omitted = 0
                func convert(_ node: Node, depth: Int) throws -> MigrationBookmark? {
                    try cancellation.check()
                    guard depth <= MigrationLimits.depth else { throw MigrationFailure.tooLarge }
                    guard seen.insert(node.id).inserted else { throw MigrationFailure.malformed }
                    switch node.type {
                    case 1:
                        guard let url = MigrationLimits.url(node.url) else { omitted += 1; return nil }
                        return MigrationBookmark(id: node.guid, title: node.title, url: url)
                    case 2:
                        let ordered = (children[node.id] ?? []).sorted { $0.position == $1.position ? $0.id < $1.id : $0.position < $1.position }
                        return MigrationBookmark(id: node.guid, title: node.title.isEmpty ? Self.rootName(node.guid) : node.title,
                                                 children: try ordered.compactMap { try convert($0, depth: depth + 1) })
                    case 3: omitted += 1; return nil
                    default: throw MigrationFailure.unsupported
                    }
                }
                for guid in ["toolbar_____", "menu________", "unfiled_____", "mobile______"] {
                    let matching = nodes.values.filter { $0.guid == guid }
                    guard matching.count <= 1 else { throw MigrationFailure.malformed }
                    if let node = matching.first, let made = try convert(node, depth: 0) { values.bookmarks.append(made) }
                }
                guard !values.bookmarks.isEmpty else { throw MigrationFailure.unsupported }
                if omitted > 0 { values.notices.append("\(omitted) separators or bookmarks with unsupported URLs omitted.") }
                values.notices.append("Tags, saved searches and annotations are not transferred.")
            }
            if categories.contains(.history) {
                try db.rows("SELECT url, title, visit_count, last_visit_date FROM moz_places WHERE hidden = 0 AND visit_count > 0 ORDER BY last_visit_date DESC LIMIT 2001", cancellation: cancellation) { row in
                    guard let url = MigrationLimits.url(try MigrationSQLite.text(row, 0)) else { return }
                    let count = sqlite3_column_int64(row, 2)
                    let date = Date(timeIntervalSince1970: Double(sqlite3_column_int64(row, 3)) / 1_000_000)
                    guard count > 0, count <= Int32.max, date >= Date(timeIntervalSince1970: 0), date <= Date().addingTimeInterval(86400) else { return }
                    values.history.append(MigrationVisit(url: url, title: try MigrationSQLite.text(row, 1), count: Int(count), last: date))
                }
                values.notices.append("History is limited to 2,000 places. Invalid dates and unsupported URLs are omitted.")
            }
            values.notices.append("Spaces in Escale have separate sign-ins. Containers and extensions are not transferred. Use CSV for passwords.")
            return values
            }
        }
        if categories.contains(.tabs) {
            let session = try MigrationGeckoSession.read(in: source.location, cancellation: cancellation)
            result.tabs = session.tabs; result.notices += session.notices
        }
        return result
    }

    private static func rootName(_ guid: String) -> String {
        switch guid {
        case "toolbar_____": return "Bookmarks Toolbar"
        case "menu________": return "Bookmarks Menu"
        case "unfiled_____": return "Other Bookmarks"
        case "mobile______": return "Mobile Bookmarks"
        default: return "Folder"
        }
    }
}
