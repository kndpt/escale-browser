import Foundation

// The local servers a developer actually opened, by space and by origin.
// History's readable key drops ports, so two development servers on localhost
// would overwrite one another there. Keep at most twelve recent endpoints per
// space in a small Store file, updated only after a successful navigation.
// A visit is history, never proof that a server is still there: it is kept,
// and judged against the newest evidence. When the panel opens, the listening
// ports are read once (Listening.swift); a visit newer than that reading, or
// older than the Mac's last start, is judged without it. Nothing runs while
// the panel is closed: no port scan, timer or request. A stopped server's
// entry is not deleted, since it may be running again at the next visit.

@MainActor
final class Localhost: ObservableObject {
    struct Entry: Codable, Identifiable, Equatable {
        var origin: String
        var url: String
        var title: String
        var visited: Date

        var id: String { origin }
        var address: URL? { URL(string: url) }
    }

    /// What the newest evidence says about an entry's server.
    enum Availability {
        /// A server listens on the entry's port.
        case running
        /// The ports were read after the visit and nothing listens there.
        case stopped
        /// The Mac started again after the visit, and nothing newer says otherwise.
        case restarted
        /// Visited since the last start and not read since: nothing says it is gone.
        case unconfirmed

        /// Whether the door counts it as a page that may still load.
        var counts: Bool { self == .running || self == .unconfirmed }
    }

    @Published private var saved: [String: [Entry]] = [:]
    /// The last reading of the listening ports, in memory only. Nil until the
    /// panel opens, and again when a reading fails.
    @Published private(set) var listening: Listening?
    private(set) var reading = false
    /// When each endpoint's page last arrived, in memory: a reload the file
    /// needn't hear about still names it (retitle). One date per local
    /// origin opened since launch, a handful.
    private var arrived: [String: Date] = [:]
    private let file: URL
    static let limit = 12

    init(file: URL = Store.file("localhost.json")) {
        self.file = file
        Writer.to(file).flush()
        guard let data = try? Data(contentsOf: file) else { return }
        if let read = try? JSONDecoder().decode([String: [Entry]].self, from: data) {
            saved = read.mapValues { Array($0.prefix(Self.limit)) }
        } else {
            Store.quarantine(file)
        }
    }

    static func origin(of url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased() else { return nil }
        let octets = host.split(separator: ".")
        let loopback = octets.count == 4 && octets.first == "127"
            && octets.allSatisfy { UInt8($0) != nil }
        let local = host == "localhost" || host.hasSuffix(".localhost")
            || host == "::1" || host == "[::1]" || loopback
        guard local else { return nil }
        // A default port names the same origin as no port at all.
        let port = parts.port.flatMap { $0 == (scheme == "https" ? 443 : 80) ? nil : ":\($0)" } ?? ""
        let name = host.contains(":") ? "[\(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))]" : host
        return "\(scheme)://\(name)\(port)"
    }

    func entries(in space: UUID) -> [Entry] { saved[space.uuidString] ?? [] }

    /// How many of the space's entries may still load, the door's number.
    func reachable(in space: UUID) -> Int {
        entries(in: space).filter { availability(of: $0).counts }.count
    }

    func availability(of entry: Entry) -> Availability {
        Self.availability(of: entry, listening: listening, booted: Listening.booted)
    }

    /// The newest of the visit, the reading and the Mac's start decides. A
    /// reading older than the visit proves nothing about it: the page loaded.
    static func availability(of entry: Entry, listening: Listening?, booted: Date?) -> Availability {
        if let listening, listening.taken >= entry.visited {
            return listening.serves(origin: entry.origin) ? .running : .stopped
        }
        if let booted, entry.visited < booted { return .restarted }
        return .unconfirmed
    }

    /// Reads the listening ports once, off the main thread, as the panel opens.
    /// A failed reading drops the last one rather than keep a stale answer.
    func check() {
        guard !reading else { return }
        reading = true
        Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) { Listening.read() }.value
            self?.listening = snapshot
            self?.reading = false
        }
    }

    /// Whether an open tab can stand for this endpoint. A private tab has its
    /// own cookies, so a remembered visit never lands in one.
    static func reuses(shy: Bool, address: URL?, origin: String) -> Bool {
        !shy && address.flatMap(Self.origin) == origin
    }

    /// Where a bookmark sends this endpoint: one of its saved environments, or
    /// the bookmark's own address when it has none.
    struct Destination: Equatable {
        var bookmark: Bookmark.ID
        var environment: BookmarkEnvironment?
        var url: URL
    }

    /// The bookmarks that own this endpoint, one destination each. A bookmark
    /// with environments counts only through them, and two on one origin are
    /// told apart by the remembered page's path; if that path does not choose,
    /// the bookmark stays out rather than guess.
    static func destinations(for entry: Entry, in roots: [Bookmark]) -> [Destination] {
        roots.flatMap { node -> [Destination] in
            if node.isFolder { return destinations(for: entry, in: node.children ?? []) }
            if node.destinations.isEmpty {
                guard let url = node.url.flatMap(URL.init(string:)), origin(of: url) == entry.origin else { return [] }
                return [Destination(bookmark: node.id, environment: nil, url: url)]
            }
            let here = node.destinations.filter {
                BookmarkEnvironment.address($0.url).flatMap(origin) == entry.origin
            }
            guard let item = BookmarkEnvironment.current(in: here, at: entry.address) ?? (here.count == 1 ? here.first : nil),
                  let url = BookmarkEnvironment.address(item.url) else { return [] }
            return [Destination(bookmark: node.id, environment: item, url: url)]
        }
    }

    func record(_ url: URL, title: String, in space: UUID, at now: Date = Date()) {
        guard let origin = Self.origin(of: url) else { return }
        let key = space.uuidString
        arrived[key + " " + origin] = now
        var list = saved[key] ?? []
        let old = list.first { $0.origin == origin }
        // A reload or short run through routes on one server needn't write
        // the same endpoint repeatedly. A new title still matters.
        if let old, now.timeIntervalSince(old.visited) < 300,
           old.url == url.absoluteString,
           (title.isEmpty || old.title == title) { return }
        list.removeAll { $0.origin == origin }
        list.insert(Entry(origin: origin, url: url.absoluteString,
                          title: String((title.isEmpty ? old?.title ?? "" : title).prefix(80)),
                          visited: now), at: 0)
        saved[key] = Array(list.prefix(Self.limit))
        Writer.to(file).save(saved)
    }

    /// Only while the page is still naming itself, as in History.retitle.
    func retitle(_ url: URL, title: String, in space: UUID, at now: Date = Date()) {
        let title = String(title.prefix(80))
        guard let origin = Self.origin(of: url), !title.isEmpty,
              let index = saved[space.uuidString]?.firstIndex(where: { $0.origin == origin }),
              saved[space.uuidString]?[index].title != title,
              let since = arrived[space.uuidString + " " + origin],
              now.timeIntervalSince(since) < History.naming else { return }
        saved[space.uuidString]?[index].title = title
        Writer.to(file).save(saved)
    }

    func forget(_ origin: String, in space: UUID) {
        saved[space.uuidString]?.removeAll { $0.origin == origin }
        Writer.to(file).save(saved)
    }

    func forget(space: UUID) {
        saved[space.uuidString] = nil
        Writer.to(file).save(saved)
    }

    // History belongs to one space, so removing a visit or a period there
    // prunes only that space's endpoints.
    func forget(url: URL, in space: UUID) {
        remove(in: space) { $0.url == url.absoluteString }
    }

    func forget(from start: Date, through end: Date = .distantFuture, in space: UUID) {
        remove(in: space) { $0.visited >= start && $0.visited <= end }
    }

    private func remove(in space: UUID, where matches: (Entry) -> Bool) {
        let key = space.uuidString
        let old = saved[key] ?? []
        let kept = old.filter { !matches($0) }
        guard kept.count != old.count else { return }
        saved[key] = kept.isEmpty ? nil : kept
        Writer.to(file).save(saved)
    }
}
