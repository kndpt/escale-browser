// Zen's sidebar is independent of Places. The pre-1.18 window snapshot and
// the 1.18+ shared sidebar are different envelopes; both keep workspace IDs,
// pinned IDs and folder relationships. Each workspace is an explicit source,
// never silently a new sign-in identity. Shared essentials arrive in each
// chosen workspace, and mirrored tabs with a stable source ID arrive once.
// Shapes follow release-tagged upstream code (see docs/MIGRATION.md), not a
// claim that a real Zen release was run. Unrecognised shapes keep Places usable.
import Foundation
import SQLite3

struct MigrationZen: MigrationReader {
    let temporaryRoot: URL
    struct Sidebar {
        let spaces: [[String: Any]]
        let tabs: [[String: Any]]
        let folders: [[String: Any]]
        let legacy: Bool
    }

    static func sidebar(in root: URL, temporaryRoot: URL? = nil, cancellation: MigrationCancellation) throws -> Sidebar {
        let modern = MigrationInput.exists("zen-sessions.jsonlz4", in: root)
        guard let file = modern ? "zen-sessions.jsonlz4" : try MigrationGeckoSession.selected(in: root) else { throw MigrationFailure.unreadable }
        let object = try MigrationGeckoSession.object(file, in: root, cancellation: cancellation)
        var spaces: [[String: Any]] = [], tabs: [[String: Any]] = [], folders: [[String: Any]] = []
        if modern {
            guard object["lastCollected"] is NSNumber,
                  let rawSpaces = object["spaces"] as? [[String: Any]],
                  let rawTabs = object["tabs"] as? [[String: Any]] else { throw MigrationFailure.unsupported }
            spaces = rawSpaces; tabs = rawTabs
            folders = object["folders"] as? [[String: Any]] ?? []
            if object["folders"] != nil && !(object["folders"] is [[String: Any]]) { throw MigrationFailure.malformed }
        } else {
            guard let version = object["version"] as? [Any], version.count == 2,
                  version[0] as? String == "sessionrestore", version[1] as? Int == 1,
                  let windows = object["windows"] as? [[String: Any]], windows.count <= 200 else { throw MigrationFailure.unsupported }
            var spaceIDs = Set<String>(), folderIDs = Set<String>()
            for window in windows where window["isPrivate"] as? Bool != true {
                guard let windowTabs = window["tabs"] as? [[String: Any]] else { throw MigrationFailure.malformed }
                tabs += windowTabs
                guard tabs.count <= MigrationLimits.records else { throw MigrationFailure.tooLarge }
                for space in window["spaces"] as? [[String: Any]] ?? [] {
                    if spaceIDs.insert(try MigrationInput.text(space["uuid"])).inserted { spaces.append(space) }
                }
                for folder in window["folders"] as? [[String: Any]] ?? [] {
                    if folderIDs.insert(try MigrationInput.text(folder["id"])).inserted { folders.append(folder) }
                }
            }
        }
        if !modern, spaces.isEmpty, MigrationInput.exists("places.sqlite", in: root) {
            guard let temporaryRoot else { throw MigrationFailure.unsupported }
            spaces = try MigrationSQLite.read(MigrationInput.file("places.sqlite", in: root), temporaryRoot: temporaryRoot, cancellation: cancellation) { db in
                var result: [[String: Any]] = []
                try db.rows("SELECT uuid, name, position, container_id FROM zen_workspaces ORDER BY position, created_at", cancellation: cancellation) { row in
                    result.append(["uuid": try MigrationSQLite.text(row, 0), "name": try MigrationSQLite.text(row, 1),
                                   "position": Int(sqlite3_column_int64(row, 2)), "containerTabId": Int(sqlite3_column_int64(row, 3))])
                    guard result.count <= 200 else { throw MigrationFailure.tooLarge }
                }
                return result
            }
        }
        guard spaces.count <= 200, tabs.count <= MigrationLimits.records, folders.count <= MigrationLimits.records else { throw MigrationFailure.tooLarge }
        guard !spaces.isEmpty else { throw MigrationFailure.unsupported }
        var identities = Set<String>()
        for space in spaces {
            let id = try MigrationInput.text(space["uuid"])
            guard !id.isEmpty, identities.insert(id).inserted else { throw MigrationFailure.malformed }
            _ = try MigrationInput.text(space["name"])
        }
        spaces.sort { ($0["position"] as? Int ?? 0) < ($1["position"] as? Int ?? 0) }
        // 1.18 writes one shared list. A legacy mirror can appear in multiple
        // windows: prefer the explicitly active copy, otherwise keep the first.
        var unique: [[String: Any]] = [], known: [String: Int] = [:]
        for (index, tab) in tabs.enumerated() {
            try cancellation.check()
            let stable = (tab["zenSyncId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (tab["zenPinnedId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if modern && stable == nil { throw MigrationFailure.malformed }
            let id = stable ?? "legacy-position:\(index)"
            var tab = tab; tab["escaleSourceID"] = id
            if let at = known[id] {
                if tab["_zenIsActiveTab"] as? Bool == true { unique[at] = tab }
            } else { known[id] = unique.count; unique.append(tab) }
        }
        guard unique.count <= 2_000 else { throw MigrationFailure.tooLarge }
        return Sidebar(spaces: spaces, tabs: unique, folders: folders, legacy: !modern)
    }

    static func discover(_ profiles: [MigrationSource], temporaryRoot: URL? = nil, cancellation: MigrationCancellation) throws -> [MigrationSource] {
        var sources: [MigrationSource] = []
        for profile in profiles {
            try cancellation.check()
            var base = profile
            base.categories.remove(.tabs)
            if !base.categories.isEmpty { sources.append(base) }
            do {
                let sidebar = try sidebar(in: profile.location, temporaryRoot: temporaryRoot, cancellation: cancellation)
                for space in sidebar.spaces {
                    let id = try MigrationInput.text(space["uuid"])
                    let name = try MigrationInput.text(space["name"])
                    sources.append(MigrationSource(id: MigrationLimits.identity(profile.id, "workspace", id).uuidString,
                                                   browser: "Zen", profile: "\(profile.profile) · \(name)", location: profile.location,
                                                   format: "zen", version: profile.version, categories: [.bookmarks, .tabs], part: id))
                }
            } catch MigrationFailure.cancelled { throw MigrationFailure.cancelled }
            catch {
                // The profile still exposes a session action so corruption is
                // reported when requested, rather than silently called empty.
                if MigrationInput.exists("zen-sessions.jsonlz4", in: profile.location) || (try? MigrationGeckoSession.selected(in: profile.location)) != nil {
                    sources.append(MigrationSource(id: MigrationLimits.identity(profile.id, "session").uuidString, browser: "Zen",
                                                   profile: "\(profile.profile) · Saved session", location: profile.location,
                                                   format: "zen", version: profile.version, categories: [.tabs]))
                }
            }
            guard sources.count <= 200 else { throw MigrationFailure.tooLarge }
        }
        return sources
    }

    func read(_ source: MigrationSource, categories: Set<MigrationCategory>, cancellation: MigrationCancellation) throws -> MigrationValues {
        let sidebar = try Self.sidebar(in: source.location, temporaryRoot: temporaryRoot, cancellation: cancellation)
        guard let workspace = source.part, sidebar.spaces.contains(where: { $0["uuid"] as? String == workspace }) else { throw MigrationFailure.sourceChanged }
        func essential(_ raw: [String: Any]) -> Bool { raw["zenEssential"] as? Bool == true || raw["zenEssential"] as? String == "true" }
        let tabs = sidebar.tabs.filter { $0["zenWorkspace"] as? String == workspace || essential($0) }
        var result = MigrationValues(), omitted = 0
        var mapped: [(raw: [String: Any], tab: MigrationTab)] = []
        for raw in tabs {
            try cancellation.check()
            let id = try MigrationInput.text(raw["escaleSourceID"])
            if var tab = try MigrationGeckoSession.tab(raw, id: id, stable: !id.hasPrefix("legacy-position:")) {
                tab.pinned = tab.pinned || essential(raw)
                mapped.append((raw, tab))
            } else { omitted += 1 }
        }
        if categories.contains(.tabs) { result.tabs = mapped.map(\.tab) }
        if categories.contains(.bookmarks) {
            let folders = sidebar.folders.filter { $0["workspaceId"] as? String == workspace || $0["essential"] as? Bool == true }
            var byID: [String: [String: Any]] = [:]
            for folder in folders {
                let id = try MigrationInput.text(folder["id"])
                guard !id.isEmpty, byID.updateValue(folder, forKey: id) == nil else { throw MigrationFailure.malformed }
            }
            let foldersByParent = Dictionary(grouping: folders) { $0["parentId"] as? String ?? "" }
            let tabsByParent = Dictionary(grouping: mapped.filter { $0.tab.pinned }) { item in
                let group = item.raw["groupId"] as? String ?? ""
                return byID[group] != nil ? group : ""
            }
            var visited = Set<String>()
            func children(_ parent: String?, depth: Int) throws -> [MigrationBookmark] {
                try cancellation.check()
                guard depth <= MigrationLimits.depth else { throw MigrationFailure.tooLarge }
                var nodes: [String: MigrationBookmark] = [:], next: [String: String] = [:]
                var first: String?, last: String?
                func insert(_ node: MigrationBookmark, after previous: String?, atStart: Bool = false) {
                    nodes[node.id] = node
                    if let previous, nodes[previous] != nil {
                        if let following = next[previous] { next[node.id] = following }
                        next[previous] = node.id
                        if last == previous { last = node.id }
                    } else if atStart {
                        if let first { next[node.id] = first }
                        first = node.id
                        if last == nil { last = node.id }
                    } else {
                        if let last { next[last] = node.id } else { first = node.id }
                        last = node.id
                    }
                }
                for item in tabsByParent[parent ?? ""] ?? [] {
                    insert(MigrationBookmark(id: "tab:" + item.tab.id, title: item.tab.title, url: item.tab.url), after: nil)
                }
                for folder in foldersByParent[parent ?? ""] ?? [] {
                    let id = try MigrationInput.text(folder["id"])
                    guard visited.insert(id).inserted else { throw MigrationFailure.malformed }
                    let node = MigrationBookmark(id: "folder:" + id, title: try MigrationInput.text(folder["name"]), children: try children(id, depth: depth + 1))
                    let previous = folder["prevSiblingInfo"] as? [String: Any]
                    let prefix = previous?["type"] as? String == "tab" ? "tab:" : "folder:"
                    insert(node, after: (previous?["id"] as? String).map { prefix + $0 }, atStart: previous?["type"] as? String == "start")
                }
                var made: [MigrationBookmark] = [], cursor = first
                while let id = cursor, let node = nodes[id] {
                    made.append(node); cursor = next[id]
                }
                return made
            }
            result.bookmarks = try children(nil, depth: 0)
            guard visited.count == folders.count else { throw MigrationFailure.malformed }
        }
        result.notices = ["This Zen workspace goes into the Escale Space you chose. Shared essentials are included; containers, accounts and sign-ins are not transferred. Choose a separate Escale Space for separate sign-ins.",
                          "Pinned tabs and folders can become bookmarks; Tabs restores saved web addresses and pins asleep. Split views, live-folder rules, icons and group appearance are omitted."]
        if sidebar.legacy { result.notices.append("Legacy Zen session: pinned IDs are deduplicated across windows; ordinary tabs without stable IDs use position and URL. Moving those tabs can add new ones on reimport.") }
        if omitted > 0 { result.notices.append("\(omitted) empty, temporary, private, POST or non-web tabs omitted.") }
        return result
    }
}
