// GitHub Bearings reads local metadata only. Grouping precedes the six-row cut,
// so visited subpages cannot crowd out another object. A query captures its
// order; later source changes remove invalid destinations without letting a
// status reply move the selected identity. The optional memory is borrowed
// from the data owner: this search never creates a cache or starts a request.
// The mode GitHub sits beside in Bearings (Bearing.swift) sets what leads:
// beside tab search, every open tab comes first; beside New Tab, the tabs
// visited this session do, at most three, as New Tab itself shows them, and
// a typed query keeps open tabs ahead only between equally good matches.
// An exact owner/repo#N that nothing local knows becomes an offer to open it
// on github.com: a row only, with no request and no memory until Return.
import Foundation
import Combine

@MainActor
final class GitHubSearch: ObservableObject {
    struct Candidate {
        let item: GitHubItem
        let count: Int
        /// An open tab whose page was visited this session.
        let recent: Bool
        init(_ item: GitHubItem, count: Int = 1, recent: Bool = false) {
            self.item = item; self.count = count; self.recent = recent
        }
    }
    /// What this search sits beside in Bearings; nil ranks without lifting tabs.
    enum Lead { case tabs, newTab }
    /// How many visited tabs lead beside New Tab, as New Tab shows them.
    static let newTabLead = 3
    struct Result: Identifiable {
        let item: GitHubItem
        let match: Terms.Match
        let exact: Bool
        let frequency: Double
        var recent = false
        var id: GitHubItem.ID { item.id }
        var isOpen: Bool { if case .tab = item.destination.source { return true }; return false }
        /// The identity is lowercased to group visits; the row keeps the visited spelling.
        var repository: String {
            let path = item.destination.url.pathComponents
            let canonical = "\(id.owner)/\(id.repository)"
            guard path.count > 2 else { return canonical }
            let visited = "\(path[1])/\(path[2])"
            return visited.lowercased() == canonical ? visited : canonical
        }
    }

    /// One object's visits and the names a query is matched against, made
    /// once per source snapshot rather than once per key. With the scalar
    /// sort keys in `rank`, a key over 2,000 matching objects went from
    /// 10.7 to 4.3 ms of insert time (median, release build; ordinary
    /// Bearings 2.9 ms on the same history).
    struct Group {
        let id: GitHubItem.ID
        let values: [Candidate]
        let names: [String]
        let folded: [String]
        let references: Set<String>
    }

    let space: UUID
    let shy: Bool
    let memory: GitHubMemory?
    let lead: Lead?
    private let sources: () -> [Candidate]
    private var local: [Group] = []
    private let active: () -> UUID?
    private let lifts: (String) -> [String: Double]
    private var query = ""
    private var watches: [AnyCancellable] = []
    private var refreshQueued = false

    /// Source watches exist only while this search is visible. Their deferred
    /// read sees @Published's new metadata and coalesces a navigation's burst.
    func watch(history: History?, tabs: [Tab]) {
        watches = []
        if let history { watches.append(history.objectWillChange.sink { [weak self] _ in
            self?.sourceChanged()
        }) }
        for tab in tabs { watches.append(tab.objectWillChange.sink { [weak self] _ in
            self?.sourceChanged()
        }) }
    }

    private func sourceChanged() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.refresh()
        }
    }

    /// An exact reference nothing here knows. Its URL keeps the typed
    /// spelling; GitHub sends an issue's address on to a pull request.
    struct Offer {
        let id: GitHubItem.ID
        let name: String
        let url: URL
    }

    @Published private(set) var results: [Result] = []
    @Published private(set) var offer: Offer?
    @Published private(set) var picked: GitHubItem.ID?

    init(space: UUID, shy: Bool, memory: GitHubMemory? = nil, lead: Lead? = nil,
         sources: @escaping () -> [Candidate], active: @escaping () -> UUID?,
         lifts: @escaping (String) -> [String: Double] = { _ in [:] }) {
        self.space = space
        self.shy = shy
        self.lead = lead
        self.memory = memory.flatMap { $0.space == space && $0.isPrivate == shy ? $0 : nil }
        self.sources = sources
        self.active = active
        self.lifts = lifts
        local = admitted()
    }

    private func admitted() -> [Group] {
        Self.prepare(sources().filter { $0.item.id.space == space && (!shy || $0.item.destination.source != .history) })
    }

    var selected: Result? { results.first { $0.id == picked } }

    func ask(_ typed: String) {
        query = typed
        results = Array(ranked().prefix(Field.room))
        offer = unknown()
        picked = offer?.id ?? results.first?.id
    }

    /// Refresh membership, keeping surviving identities in their captured order.
    func refresh() {
        local = admitted()
        let candidates = ranked()
        let available = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let kept = results.compactMap { available[$0.id] }
        let identities = Set(kept.map(\.id))
        results = Array((kept + candidates.filter { !identities.contains($0.id) }).prefix(Field.room))
        offer = unknown()
        if picked != offer?.id, !results.contains(where: { $0.id == picked }) { picked = offer?.id ?? results.first?.id }
    }

    func walk(_ step: Int) {
        let rows = (offer.map { [$0.id] } ?? []) + results.map(\.id)
        guard !rows.isEmpty else { return }
        let index = picked.flatMap { rows.firstIndex(of: $0) } ?? 0
        picked = rows[min(rows.count - 1, max(0, index + step))]
    }

    /// The offer for what is typed, unless a row already is that object. A
    /// private search has none: it opens nothing outside its own tabs.
    private func unknown() -> Offer? {
        guard !shy, let offer = Self.offer(query, space: space) else { return nil }
        let known = results.contains {
            $0.id.owner == offer.id.owner && $0.id.repository == offer.id.repository && $0.id.number == offer.id.number
        }
        return known ? nil : offer
    }

    /// Exactly `owner/repo#N`, checked as GitHub names are, or nil.
    static func offer(_ typed: String, space: UUID) -> Offer? {
        let name = typed.trimmingCharacters(in: .whitespaces)
        let parts = name.split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let path = parts[0].split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 2, let url = URL(string: "https://github.com/\(path[0])/\(path[1])/issues/\(parts[1])"),
              let id = GitHubItem.ID(url: url, space: space),
              let canonical = URL(string: "https://github.com/\(path[0])/\(path[1])/issues/\(id.number)") else { return nil }
        return Offer(id: id, name: name, url: canonical)
    }

    private func ranked() -> [Result] {
        Self.rank(local, typed: query, active: active(), lead: lead, lifts: shy ? [:] : lifts(query),
                  reading: { self.memory?.reading($0) ?? GitHubReading(observation: nil, failure: nil) })
    }

    /// A canonical page key reuses the existing bounded, per-Space Habits file.
    static func destination(_ id: GitHubItem.ID) -> String {
        "page:\(id.host)/\(id.owner)/\(id.repository)/\(id.kind == .pull ? "pull" : "issues")/\(id.number)"
    }

    static func prepare(_ candidates: [Candidate]) -> [Group] {
        Dictionary(grouping: candidates, by: { $0.item.id }).map { id, values in
            let number = String(id.number), repository = "\(id.owner)/\(id.repository)"
            let names = values.map { $0.item.destination.title } + values.map { $0.item.destination.url.absoluteString }
                + ["\(repository) #\(number)", id.kind == .pull ? "PR pull request" : "issue"]
            return Group(id: id, values: values, names: names, folded: names.map { $0.lowercased() },
                         references: ["\(id.repository) #\(number)", "\(id.repository) \(number)", "\(repository)#\(number)",
                                      "\(id.repository)#\(number)", "\(repository) #\(number)", "\(repository) \(number)"])
        }
    }

    static func rank(_ candidates: [Candidate], typed: String, active: UUID?, lead: Lead? = nil,
                     lifts: [String: Double] = [:], now: Date = Date(),
                     reading: (GitHubItem.ID) -> GitHubReading = { _ in GitHubReading(observation: nil, failure: nil) }) -> [Result] {
        rank(prepare(candidates), typed: typed, active: active, lead: lead, lifts: lifts, now: now, reading: reading)
    }

    static func rank(_ groups: [Group], typed: String, active: UUID?, lead: Lead? = nil,
                     lifts: [String: Double] = [:], now: Date = Date(),
                     reading: (GitHubItem.ID) -> GitHubReading = { _ in GitHubReading(observation: nil, failure: nil) }) -> [Result] {
        let terms = Terms(typed)
        var learned: [GitHubItem.ID: Double] = [:]
        if let space = groups.first?.id.space {
            for (key, lift) in lifts {
                guard let path = Habits.visit(in: key), let url = URL(string: "https://" + path),
                      let id = GitHubItem.ID(url: url, space: space) else { continue }
                learned[id] = max(learned[id] ?? 0, min(Habits.highest, max(0, lift)))
            }
        }
        func priority(_ source: GitHubItem.Source) -> Int {
            if case .tab(let id) = source { return id == active ? 0 : 1 }
            return 2
        }
        // The typed address is parsed once per Space, not once per object.
        let typedURL = URL(string: terms.whole)
        var typedIDs: [UUID: GitHubItem.ID?] = [:]
        let rows = groups.compactMap { group -> Result? in
            let id = group.id
            let exactURL = typedURL.flatMap { url -> GitHubItem.ID? in
                if let known = typedIDs[id.space] { return known }
                let parsed = GitHubItem.ID(url: url, space: id.space)
                typedIDs[id.space] = parsed
                return parsed
            } == id
            let exactName = group.references.contains(terms.whole)
            let match: Terms.Match?
            if terms.isEmpty || exactURL || exactName { match = .typed }
            else if group.folded.contains(where: { $0.contains(terms.whole) }) { match = .typed }
            else { match = terms.byWords(group.names.map { $0[...] }) }
            guard let match else { return nil }
            let values = group.values
            let sorted = values.sorted {
                let left = $0.item.destination, right = $1.item.destination
                if priority(left.source) != priority(right.source) { return priority(left.source) < priority(right.source) }
                if left.visitedAt != right.visitedAt { return left.visitedAt > right.visitedAt }
                if left.url != right.url { return left.url.absoluteString < right.url.absoluteString }
                return String(describing: left.source) < String(describing: right.source)
            }
            guard let destination = sorted.first?.item else { return nil }
            let frequency = values.map { Double($0.count) * exp(-max(0, now.timeIntervalSince($0.item.destination.visitedAt)) / Habits.fade) }.max() ?? 0
            let recent = values.contains { $0.recent && $0.item.destination.source == destination.destination.source }
            return Result(item: destination, match: match, exact: exactURL || exactName, frequency: frequency, recent: recent)
        }
        // The tabs that lead (see the top of this file), chosen before the sort.
        let leading: Set<GitHubItem.ID>
        switch lead {
        case .tabs:
            leading = Set(rows.filter(\.isOpen).map(\.id))
        case .newTab where terms.isEmpty:
            leading = Set(rows.filter { $0.isOpen && $0.recent }
                .sorted { $0.item.destination.visitedAt > $1.item.destination.visitedAt }
                .prefix(newTabLead).map(\.id))
        default:
            leading = []
        }
        let opensAhead = lead == .newTab && !terms.isEmpty
        // Capture freshness and learning once, not inside the comparator: the
        // order cannot contradict itself when an observation expires during
        // this sort, and comparisons read scalars instead of hashing identities.
        struct Key { let row: Int; let exact: Bool; let leads: Bool; let relevance: Double; let open: Bool; let status: Int; let frequency: Double; let visited: Date }
        let keys = rows.indices.map { index -> Key in
            let row = rows[index]
            let state = reading(row.id).current(at: now)
            let leads = leading.contains(row.id)
            // Leading tabs stay in the order they were looked at, whatever their state.
            return Key(row: index, exact: row.exact, leads: leads,
                       relevance: terms.isEmpty ? 0 : Double(2 - row.match.rawValue) + (learned[row.id] ?? 0),
                       open: opensAhead && row.isOpen,
                       status: leads ? 1 : state == .open || state == .draft ? 0 : state == .closed || state == .merged ? 2 : 1,
                       frequency: terms.isEmpty ? 0 : row.frequency, visited: row.item.destination.visitedAt)
        }
        return keys.sorted {
            if $0.exact != $1.exact { return $0.exact }
            if $0.leads != $1.leads { return $0.leads }
            if $0.relevance != $1.relevance { return $0.relevance > $1.relevance }
            if $0.open != $1.open { return $0.open }
            if $0.status != $1.status { return $0.status < $1.status }
            if $0.frequency != $1.frequency { return $0.frequency > $1.frequency }
            if $0.visited != $1.visited { return $0.visited > $1.visited }
            return destination(rows[$0.row].id) < destination(rows[$1.row].id)
        }.map { rows[$0.row] }
    }
}
