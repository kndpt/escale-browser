// A plan is a bounded value snapshot, safe to inspect before any write.
// Source identities keep same-named folders and repeated URLs distinct. The
// merge only adds missing identities; user edits and moves always win. HTML
// has no durable IDs, so renaming a source folder is explicitly a new folder.
import Foundation

struct MigrationPlan {
    let source: MigrationSource
    let destination: UUID
    let categories: Set<MigrationCategory>
    let values: MigrationValues
    struct OutlineLine: Identifiable {
        let id: String
        let title: String
        let url: URL?
        let depth: Int
    }
    let outline: [OutlineLine]
    let bookmarkCount: Int

    init(source: MigrationSource, destination: UUID, categories: Set<MigrationCategory>, values: MigrationValues) throws {
        guard categories.isSubset(of: source.categories), !categories.isEmpty else { throw MigrationFailure.unsupported }
        var count = 0, ids = Set<String>()
        func validate(_ nodes: [MigrationBookmark], depth: Int) throws {
            guard depth <= MigrationLimits.depth else { throw MigrationFailure.tooLarge }
            for node in nodes {
                count += 1
                guard count <= MigrationLimits.records, node.title.utf8.count <= MigrationLimits.field,
                      node.id.utf8.count <= MigrationLimits.field else { throw MigrationFailure.tooLarge }
                guard !node.id.isEmpty, ids.insert(node.id).inserted else { throw MigrationFailure.malformed }
                if let url = node.url {
                    guard MigrationLimits.url(url.absoluteString) != nil, node.children.isEmpty else { throw MigrationFailure.malformed }
                }
                try validate(node.children, depth: depth + 1)
            }
        }
        try validate(values.bookmarks, depth: 0)
        guard values.history.count <= MigrationLimits.records, values.passwords.count <= MigrationLimits.records else {
            throw MigrationFailure.tooLarge
        }
        for visit in values.history {
            guard MigrationLimits.url(visit.url.absoluteString) != nil, visit.count > 0,
                  visit.count <= Int(Int32.max), visit.last.timeIntervalSince1970.isFinite,
                  visit.last >= Date(timeIntervalSince1970: 0), visit.last <= Date().addingTimeInterval(86400),
                  visit.title.utf8.count <= MigrationLimits.field else { throw MigrationFailure.malformed }
        }
        for login in values.passwords {
            guard !login.host.isEmpty, !login.password.isEmpty,
                  login.host.utf8.count <= MigrationLimits.field, login.user.utf8.count <= MigrationLimits.field,
                  login.password.utf8.count <= MigrationLimits.field else { throw MigrationFailure.malformed }
        }
        guard values.tabs.count <= 2_000 else { throw MigrationFailure.tooLarge }
        var tabIDs = Set<String>()
        for tab in values.tabs {
            guard !tab.id.isEmpty, tabIDs.insert(tab.id).inserted,
                  MigrationLimits.url(tab.url.absoluteString) != nil else { throw MigrationFailure.malformed }
            guard tab.id.utf8.count <= MigrationLimits.field, tab.title.utf8.count <= MigrationLimits.field else { throw MigrationFailure.tooLarge }
        }
        var bounded = values
        if bounded.history.count > 2_000 {
            bounded.history = Array(values.history.sorted { $0.last > $1.last }.prefix(2_000))
            bounded.notices.append("Only the 2,000 most recent source history entries are considered; Escale keeps at most 2,000 places overall.")
        }
        var outline: [OutlineLine] = []
        func preview(_ nodes: [MigrationBookmark], depth: Int) {
            for node in nodes {
                guard outline.count < 200 else { return }
                outline.append(OutlineLine(id: node.id, title: node.title, url: node.url, depth: depth))
                preview(node.children, depth: depth + 1)
            }
        }
        preview(bounded.bookmarks, depth: 0)
        self.outline = outline; bookmarkCount = count
        self.source = source; self.destination = destination; self.categories = categories; self.values = bounded
    }

    struct BookmarkMerge {
        let roots: [Bookmark]
        let added: Int
        let kept: Int
        let conflicts: Int
    }

    func bookmarks(keeping existing: [Bookmark]) -> BookmarkMerge {
        var incoming: [UUID: MigrationBookmark] = [:], known = Set<UUID>()
        func id(_ node: MigrationBookmark) -> UUID { MigrationLimits.identity(source.id, node.id) }
        func index(_ nodes: [MigrationBookmark]) {
            for node in nodes { incoming[id(node)] = node; index(node.children) }
        }
        func remember(_ nodes: [Bookmark]) {
            for node in nodes { known.insert(node.id); remember(node.children ?? []) }
        }
        index(values.bookmarks); remember(existing)
        var added = 0, kept = 0, conflicts = 0
        func fresh(_ node: MigrationBookmark) -> Bookmark? {
            guard !known.contains(id(node)) else { return nil }
            added += 1
            return Bookmark(id: id(node), title: node.title, url: node.url?.absoluteString,
                            children: node.url == nil ? node.children.compactMap(fresh) : nil)
        }
        func merge(_ nodes: [Bookmark]) -> [Bookmark] {
            nodes.map { old in
                var node = old
                if let source = incoming[node.id] {
                    kept += 1
                    if source.title != node.title || source.url?.absoluteString != node.url { conflicts += 1 }
                    if node.isFolder { node.children = merge(node.children ?? []) + source.children.compactMap(fresh) }
                } else if node.isFolder { node.children = merge(node.children ?? []) }
                return node
            }
        }
        let roots = merge(existing) + values.bookmarks.compactMap(fresh)
        return BookmarkMerge(roots: roots, added: added, kept: kept, conflicts: conflicts)
    }
}
