// A bookmark owns explicit destinations, copied as values with its Space.
// At most 20 entries of 80/4096 characters bound editing and address matching.
// Host and effective port come first and keep labels stable across routes.
// Consoles that share one endpoint for PROD and DEV differ only by a path, so a
// destination may also claim the leading segments of its saved path. Priority
// is explicit, never list order: the saved address itself, then the longest
// claimed path, then the one destination claiming the whole domain. A tie at
// any level shows no label, since a wrong one is worse than none.
import Foundation

struct BookmarkEnvironment: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var url: String
    var colour: Swatch?
    /// Leading path segments of `url` that identify this destination; nil
    /// claims the whole domain, as associations always did.
    var depth: Int?

    init(id: UUID = UUID(), name: String, url: String, colour: Swatch? = nil, depth: Int? = nil) {
        self.id = id
        self.name = Self.normalName(name)
        self.url = url
        self.colour = colour
        self.depth = depth
    }

    static func normalName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Five visible characters, including the ellipsis; the saved name stays whole.
    var badge: String { name.count > 5 ? String(name.prefix(4)) + "…" : name }

    private enum CodingKeys: String, CodingKey { case id, name, url, colour, depth }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = Self.normalName(try values.decode(String.self, forKey: .name))
        url = try values.decode(String.self, forKey: .url)
        // Older files have no colour; an unknown future choice also stays neutral.
        colour = try values.decodeIfPresent(String.self, forKey: .colour).flatMap(Swatch.init(rawValue:))
        depth = try values.decodeIfPresent(Int.self, forKey: .depth)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(Self.normalName(name), forKey: .name)
        try values.encode(url, forKey: .url)
        try values.encodeIfPresent(colour?.rawValue, forKey: .colour)
        try values.encodeIfPresent(depth, forKey: .depth)
    }

    static let limit = 20
    static let nameLimit = 80
    static let urlLimit = 4096

    static func address(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= urlLimit,
              !text.contains(where: { $0.isWhitespace || $0.isNewline }),
              let parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty, !host.contains("%"),
              parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        return parts.url
    }

    static func key(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if (parts.scheme == "http" && parts.port == 80) || (parts.scheme == "https" && parts.port == 443) { parts.port = nil }
        if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
        return parts.string ?? url.absoluteString
    }

    struct Endpoint: Hashable {
        var host: String
        var port: Int
    }

    static func endpoint(_ url: URL) -> Endpoint? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        // The scheme supplies only the default port: explicit ports identify
        // the same endpoint even when its transport changes.
        return Endpoint(host: host, port: parts.port ?? (scheme == "https" ? 443 : 80))
    }

    /// Whole decoded segments, split before decoding so an encoded slash stays
    /// inside its segment. Case and repeated slashes are kept: servers may
    /// treat them as distinct paths. Only the root and trailing slash go.
    static func segments(_ url: URL) -> [String] {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [] }
        var pieces = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if pieces.first == "" { pieces.removeFirst() }
        if pieces.last == "" { pieces.removeLast() }
        return pieces.map { $0.removingPercentEncoding ?? $0 }
    }

    /// The path this destination claims, or nil when it claims its whole domain
    /// or its depth no longer fits its address.
    var claim: [String]? {
        guard let depth, depth > 0, let url = Self.address(url) else { return nil }
        let parts = Self.segments(url)
        return depth <= parts.count ? Array(parts.prefix(depth)) : nil
    }

    static func current(in entries: [Self], at address: URL?) -> Self? {
        guard let address, let target = endpoint(address) else { return nil }
        let matches = entries.compactMap { item -> (item: Self, url: URL)? in
            guard let url = Self.address(item.url), endpoint(url) == target else { return nil }
            return (item, url)
        }
        let exact = key(address)
        let saved = matches.filter { key($0.url) == exact }
        if !saved.isEmpty { return saved.count == 1 ? saved.first?.item : nil }
        let path = segments(address)
        let claims = matches.compactMap { match -> (item: Self, claim: [String])? in
            guard let claim = match.item.claim, path.starts(with: claim) else { return nil }
            return (match.item, claim)
        }
        if let longest = claims.map(\.claim.count).max() {
            let winners = claims.filter { $0.claim.count == longest }
            return winners.count == 1 ? winners.first?.item : nil
        }
        let domain = matches.filter { $0.item.depth == nil }
        return domain.count == 1 ? domain.first?.item : nil
    }

    /// The shortest claim that sets this destination apart from the others on
    /// its endpoint, offered when someone switches it to Domain + Path.
    static func proposedDepth(for item: Self, among entries: [Self]) -> Int? {
        guard let url = address(item.url), let place = endpoint(url) else { return nil }
        let own = segments(url)
        guard !own.isEmpty else { return nil }
        let others = entries.compactMap { other -> [String]? in
            guard other.id != item.id, let url = address(other.url), endpoint(url) == place else { return nil }
            return segments(url)
        }
        return (1...own.count).first { depth in
            others.allSatisfy { Array($0.prefix(depth)) != Array(own.prefix(depth)) }
        } ?? own.count
    }

    struct Problem: Equatable {
        var name: String?
        var url: String?
        var path: String?
    }

    static func problems(_ entries: [Self]) -> [UUID: Problem] {
        var result: [UUID: Problem] = [:]
        for item in entries {
            let name = normalName(item.name)
            var problem = Problem()
            if name.isEmpty { problem.name = "Enter a name." }
            else if name.count > nameLimit { problem.name = "Use at most \(nameLimit) characters." }
            else if entries.filter({ normalName($0.name) == name }).count > 1 {
                problem.name = "This name is already used."
            }
            if let url = address(item.url) {
                if entries.filter({ address($0.url).map { key($0) == key(url) } ?? false }).count > 1 {
                    problem.url = "This address is already used."
                }
            } else { problem.url = "Enter a full http:// or https:// address without spaces or credentials." }
            if problem.url == nil, item.depth != nil {
                if let claim = item.claim, let url = address(item.url) {
                    let place = endpoint(url)
                    if entries.contains(where: { other in
                        other.id != item.id && other.claim == claim
                            && address(other.url).flatMap(endpoint) == place
                    }) { problem.path = "Another environment is recognised on this path." }
                } else { problem.path = "Choose a part of this address's path." }
            }
            if problem.name != nil || problem.url != nil || problem.path != nil { result[item.id] = problem }
        }
        return result
    }

    static func valid(_ entries: [Self]) -> Bool {
        entries.count <= limit && Set(entries.map(\.id)).count == entries.count && problems(entries).isEmpty
    }
}

extension Bookmark {
    var destinations: [BookmarkEnvironment] { environments ?? [] }
}

extension Browser {
    /// Resolve the saved identity again: a stale menu cannot resurrect a removed bookmark.
    func openEnvironment(_ item: BookmarkEnvironment, bookmark: Bookmark.ID, space: UUID, shy: Bool? = nil) {
        guard space == spaceID, let node = bookmarks.find(bookmark),
              node.destinations.contains(item), let url = BookmarkEnvironment.address(item.url) else { return }
        bookmarking = false
        bookmarksOpen = false
        // The shelf keeps its linked page; search supplies its own privacy
        // context so an ordinary request cannot navigate a private bookmark.
        if let tab = tabs.first(where: { shelfTabs[$0.id] == bookmark && $0.pin == nil
            && (shy == nil || $0.shy == shy) }) {
            tab.go(to: url)
            select(tab)
        } else {
            shelfTabs = shelfTabs.filter { $0.value != bookmark }
            let tab = open(url, foreground: true, shy: shy ?? false)
            shelfTabs[tab.id] = bookmark
        }
    }

    func editEnvironments(_ node: Bookmark, in bookmarks: Bookmarks) {
        guard !node.isFolder else { return }
        bookmarking = false
        bookmarksOpen = false
        environmentEditor.begin(node, in: bookmarks)
    }
}

extension BookmarkEnvironment {
    /// Test-world operations use the same saved edit and navigation as the UI.
    @MainActor static func bench(_ request: [String: Any], browser: Browser) -> [String: Any] {
        guard Store.testing else { return ["error": "environments requires a test world"] }
        let name = request["bookmark"] as? String ?? ""
        func find(_ nodes: [Bookmark]) -> Bookmark? {
            for node in nodes {
                if node.title == name || node.id.uuidString == name { return node }
                if let found = find(node.children ?? []) { return found }
            }
            return nil
        }
        guard var node = find(browser.bookmarks.roots), !node.isFolder else { return ["error": "no bookmark"] }
        if let json = request["set"] as? String {
            guard let data = json.data(using: .utf8),
                  let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return ["error": "invalid entries"] }
            let entries = values.map { Self(name: $0["name"] as? String ?? "", url: $0["url"] as? String ?? "",
                                            colour: ($0["colour"] as? String).flatMap(Swatch.init(rawValue:)), depth: $0["depth"] as? Int) }
            guard browser.bookmarks.setEnvironments(entries, for: node.id),
                  let updated = browser.bookmarks.find(node.id) else { return ["error": "invalid entries"] }
            node = updated
        }
        if request["edit"] as? Bool == true { browser.editEnvironments(node, in: browser.bookmarks) }
        if let name = request["open"] as? String {
            guard let item = node.destinations.first(where: { $0.name == name }) else { return ["error": "no environment"] }
            browser.openEnvironment(item, bookmark: node.id, space: browser.spaceID)
        }
        let tab = browser.tabs.first { browser.shelfTabs[$0.id] == node.id && $0.pin == nil }
        return ["id": node.id.uuidString, "original": node.url ?? "",
                "entries": node.destinations.map { item -> [String: Any] in
                    var entry: [String: Any] = ["name": item.name, "url": item.url, "colour": item.colour?.rawValue ?? "neutral"]
                    if let depth = item.depth { entry["depth"] = depth }
                    return entry
                },
                "tab": tab?.id.uuidString ?? "", "built": tab?.built != nil,
                "address": tab?.address?.absoluteString ?? "",
                "badge": Self.current(in: node.destinations, at: tab?.address)?.name ?? ""]
    }
}
