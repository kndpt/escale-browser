// Arc keeps its sidebar in StorableSidebar.json, beside Chromium profiles in
// "User Data". That file is not a published contract: the shape observed in
// Arc 1.166.0 (build 87668, top-level version 1) is decoded structurally and
// anything else is refused, leaving Copy All Links as the fallback. Listing
// Spaces reads that one file (32 MiB cap), never History, Login Data or cookies.
//
// Each Arc Space is one source. Its pinned tree keeps folders, order and Arc's
// own item IDs, so a reimport adds nothing twice; the Favorites of its profile
// become a Favorites folder. History belongs to the Space's Chromium profile,
// which several Spaces may share while Escale keeps one history per Space: the
// notices say so. Today tabs, Easels and unknown items are counted as losses.
import Foundation

struct MigrationArc: MigrationReader {
    let temporaryRoot: URL

    struct Sidebar {
        struct Space {
            let id: String
            let title: String
            /// The Chromium profile folder under User Data, when recognised.
            let profile: String?
            let pinned: String
            let today: String?
        }
        /// A container carries the Space that owns it (`spaceItems._0`), when it has one.
        enum Kind { case tab(URL?, String?), folder, container(String?), other }
        struct Item {
            let title: String?
            let children: [String]
            let kind: Kind
        }
        let spaces: [Space]
        let items: [String: Item]
        /// Favorites container by profile folder.
        let favorites: [String: String]
    }

    static let file = "StorableSidebar.json"

    static func discover(in root: URL, cancellation: MigrationCancellation) throws -> [MigrationSource] {
        try cancellation.check()
        let sidebar = try Self.sidebar(MigrationLimits.data(root.appendingPathComponent(file)), cancellation: cancellation)
        let labels = (try? MigrationProfiles.localState(profiles(root))) ?? [:]
        let named = Set(sidebar.spaces.compactMap(\.profile)).count > 1
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        var result: [MigrationSource] = []
        for space in sidebar.spaces {
            try cancellation.check()
            var categories = Set<MigrationCategory>()
            if !sidebar.bookmarks(for: space).isEmpty { categories.insert(.bookmarks) }
            if let profile = space.profile {
                let history = profiles(root).appendingPathComponent(profile).appendingPathComponent("History")
                if FileManager.default.fileExists(atPath: history.path),
                   history.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base + "/") { categories.insert(.history) }
            }
            guard !categories.isEmpty else { continue }
            guard result.count < 200 else { throw MigrationFailure.tooLarge }
            let label = named ? "\(space.title) · \(space.profile.map { labels[$0] ?? $0 } ?? "Unknown profile")" : space.title
            result.append(MigrationSource(id: MigrationLimits.identity("arc", base, space.id).uuidString, browser: "Arc",
                                          profile: label, location: root, format: "arc", categories: categories, part: space.id))
        }
        return result
    }

    static func profiles(_ root: URL) -> URL { root.appendingPathComponent("User Data", isDirectory: true) }

    func read(_ source: MigrationSource, categories: Set<MigrationCategory>, cancellation: MigrationCancellation) throws -> MigrationValues {
        let sidebar = try Self.sidebar(MigrationLimits.data(source.location.appendingPathComponent(Self.file)), cancellation: cancellation)
        guard let space = sidebar.spaces.first(where: { $0.id == source.part }) else { throw MigrationFailure.sourceChanged }
        let sharing = sidebar.spaces.filter { $0.profile != nil && $0.profile == space.profile }.count
        var values = MigrationValues()
        if categories.contains(.bookmarks) {
            var omitted = 0
            values.bookmarks = sidebar.bookmarks(for: space, omitted: &omitted)
            values.notices.append("Pinned tabs keep their folders and order. Renamed tabs keep the name you gave them in Arc.")
            if sharing > 1, values.bookmarks.first?.id.hasPrefix("favorites:") == true {
                values.notices.append("Favorites are shared by \(sharing) Arc Spaces of this profile. Each Escale Space keeps its own copy.")
            }
            let today = space.today.map { sidebar.count(below: $0) } ?? 0
            if today > 0 {
                values.notices.append(today == 1 ? "1 Today tab is not imported; only pinned tabs and Favorites are."
                                      : "\(today) Today tabs are not imported; only pinned tabs and Favorites are.")
            }
            if omitted > 0 {
                values.notices.append("\(omitted == 1 ? "1 sidebar item is" : "\(omitted) sidebar items are") not imported: Arc pages, extensions, Easels, notes or entries missing from Arc's file.")
            }
        }
        if categories.contains(.history) {
            guard let profile = space.profile else { throw MigrationFailure.unsupported }
            let folder = Self.profiles(source.location).appendingPathComponent(profile, isDirectory: true)
            let base = source.location.resolvingSymlinksInPath().standardizedFileURL.path
            guard folder.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base + "/") else { throw MigrationFailure.unreadable }
            let profileSource = MigrationSource(id: source.id, browser: source.browser, profile: profile, location: folder,
                                                format: "chromium", categories: [.history])
            let read = try MigrationChromium(temporaryRoot: temporaryRoot).read(profileSource, categories: [.history], cancellation: cancellation)
            values.history = read.history
            values.notices += read.notices
            if sharing > 1 {
                values.notices.append("This history belongs to an Arc profile shared by \(sharing) Spaces. Escale keeps one history per Space, so importing it into several Spaces copies it into each.")
            }
        }
        return values
    }

    /// Decodes the observed version 1 layout. Arc encodes its dictionaries as
    /// arrays alternating a key and its value; every key must equal the id.
    static func sidebar(_ data: Data, cancellation: MigrationCancellation) throws -> Sidebar {
        guard data.count <= MigrationLimits.bytes else { throw MigrationFailure.tooLarge }
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MigrationFailure.malformed }
        guard top["version"] as? Int == 1, let containers = (top["sidebar"] as? [String: Any])?["containers"] as? [[String: Any]] else {
            throw MigrationFailure.unsupported
        }
        let main = containers.filter { $0["spaces"] != nil && $0["items"] != nil }
        guard main.count == 1, let rawSpaces = main[0]["spaces"] as? [Any], let rawItems = main[0]["items"] as? [Any] else {
            throw MigrationFailure.unsupported
        }
        func pairs(_ array: [Any]) throws -> [[String: Any]] {
            guard array.count % 2 == 0 else { throw MigrationFailure.malformed }
            return try stride(from: 0, to: array.count, by: 2).map { index in
                guard let key = array[index] as? String, let value = array[index + 1] as? [String: Any],
                      value["id"] as? String == key else { throw MigrationFailure.malformed }
                return value
            }
        }
        func text(_ value: Any?) throws -> String? {
            guard let value, !(value is NSNull) else { return nil }
            guard let string = value as? String else { throw MigrationFailure.malformed }
            guard string.utf8.count <= MigrationLimits.field else { throw MigrationFailure.tooLarge }
            return string
        }
        func profile(_ value: Any?) throws -> String? {
            guard let value = value as? [String: Any] else { return nil }
            if value["default"] as? Bool == true { return "Default" }
            let name = ((value["custom"] as? [String: Any])?["_0"] as? [String: Any])?["directoryBasename"] as? String
            guard let name else { return nil }
            guard !name.isEmpty, !name.contains("/"), name != ".", name != "..", name.utf8.count <= MigrationLimits.field else {
                throw MigrationFailure.malformed
            }
            return name
        }

        let itemValues = try pairs(rawItems)
        guard itemValues.count <= MigrationLimits.records else { throw MigrationFailure.tooLarge }
        var items: [String: Sidebar.Item] = [:]
        for raw in itemValues {
            try cancellation.check()
            guard let id = raw["id"] as? String, let children = raw["childrenIds"] as? [String],
                  let data = raw["data"] as? [String: Any], items[id] == nil else { throw MigrationFailure.malformed }
            let kind: Sidebar.Kind
            if let tab = data["tab"] as? [String: Any] {
                guard let link = try text(tab["savedURL"]) else { throw MigrationFailure.malformed }
                kind = .tab(MigrationLimits.url(link), try text(tab["savedTitle"]))
            } else if data["list"] is [String: Any] {
                kind = .folder
            } else if let container = data["itemContainer"] as? [String: Any] {
                let owner = ((container["containerType"] as? [String: Any])?["spaceItems"] as? [String: Any])?["_0"]
                kind = .container(owner as? String)
            } else { kind = .other }
            items[id] = Sidebar.Item(title: try text(raw["title"]), children: children, kind: kind)
        }

        // Refuse an oversized list before decoding it, not after.
        guard rawSpaces.count <= 400 else { throw MigrationFailure.tooLarge }
        var spaces: [Sidebar.Space] = [], seen = Set<String>()
        for raw in try pairs(rawSpaces) {
            try cancellation.check()
            guard let id = raw["id"] as? String, seen.insert(id).inserted,
                  let markers = raw["containerIDs"] as? [String], markers.count % 2 == 0 else {
                throw MigrationFailure.malformed
            }
            var containers: [String: String] = [:]
            for index in stride(from: 0, to: markers.count, by: 2) { containers[markers[index]] = markers[index + 1] }
            // Pinned tabs come from the container this Space owns, never another's.
            guard let pinned = containers["pinned"], case .container(id)? = items[pinned]?.kind else { throw MigrationFailure.malformed }
            let title = try text(raw["title"]).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled Space"
            spaces.append(Sidebar.Space(id: id, title: title, profile: try profile(raw["profile"]), pinned: pinned,
                                        today: containers["unpinned"].flatMap { items[$0] == nil ? nil : $0 }))
        }

        var favorites: [String: String] = [:]
        if let raw = main[0]["topAppsContainerIDs"] as? [Any] {
            guard raw.count % 2 == 0 else { throw MigrationFailure.malformed }
            for index in stride(from: 0, to: raw.count, by: 2) {
                guard let container = raw[index + 1] as? String else { throw MigrationFailure.malformed }
                if let owner = try profile(raw[index]), case .container? = items[container]?.kind { favorites[owner] = container }
            }
        }
        return Sidebar(spaces: spaces, items: items, favorites: favorites)
    }
}

extension MigrationArc.Sidebar {
    func bookmarks(for space: Space) -> [MigrationBookmark] {
        var omitted = 0
        return bookmarks(for: space, omitted: &omitted)
    }

    /// Favorites first, as Arc shows them above the Space, then the pinned tree.
    /// Missing children and cycles are skipped rather than trusted.
    func bookmarks(for space: Space, omitted: inout Int) -> [MigrationBookmark] {
        var visited = Set<String>()
        func nodes(_ ids: [String], depth: Int) -> [MigrationBookmark] {
            ids.compactMap { id in
                guard depth < MigrationLimits.depth, let item = items[id], visited.insert(id).inserted else { omitted += 1; return nil }
                switch item.kind {
                case .tab(let url, let saved):
                    guard let url else { omitted += 1; return nil }
                    let title = [item.title, saved].compactMap { $0 }.first { !$0.isEmpty } ?? url.absoluteString
                    return MigrationBookmark(id: id, title: title, url: url)
                case .folder:
                    return MigrationBookmark(id: id, title: item.title ?? "Untitled folder", children: nodes(item.children, depth: depth + 1))
                case .container, .other:
                    omitted += 1; return nil
                }
            }
        }
        var result: [MigrationBookmark] = []
        if let profile = space.profile, let container = favorites[profile], let top = items[container] {
            let links = nodes(top.children, depth: 1)
            if !links.isEmpty { result.append(MigrationBookmark(id: "favorites:\(container)", title: "Favorites", children: links)) }
        }
        return result + nodes(items[space.pinned]?.children ?? [], depth: 0)
    }

    /// Links below a container, for the Today loss notice. Bounded to the
    /// same folder depth as the pinned tree, so a damaged sidebar cannot
    /// exhaust the stack.
    func count(below id: String) -> Int {
        var seen = Set<String>()
        func walk(_ id: String, depth: Int) -> Int {
            guard depth < MigrationLimits.depth, seen.insert(id).inserted, let item = items[id] else { return 0 }
            if case .tab = item.kind { return 1 }
            return item.children.reduce(0) { $0 + walk($1, depth: depth + 1) }
        }
        return (items[id]?.children ?? []).reduce(0) { $0 + walk($1, depth: 0) }
    }
}
