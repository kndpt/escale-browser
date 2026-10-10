import Foundation

// What the address field holds while it is being typed into: the text, the
// few places offered under it, the grey ending after the caret, the row the
// arrow keys have walked to, and whether ⌘K has made it a switcher.
//
// Every keystroke changes this, so it has an owner of its own. Held in
// `Browser`, each key would publish the whole window, and every view observing
// `Browser` (32 in 18 files when this was split out) would be asked again for
// its body; here, only the field and its list observe it. Whether that
// shortens a keystroke is measured, not assumed.
//
// `Browser` keeps what decides between tabs: whether the field is up at all
// (`editing`, once per opening rather than once per key), and what Return,
// a click on a row or ⌘K do to the row of tabs (`submit`, `take`, `summon`).
// The field sees no `Browser`: it reads the history, and asks narrow
// questions of the window, including its current Space’s bookmarks and
// eligible open tabs. It never creates a WebKit view to answer them.
//
// One per window, for the window's life. No timer, no subscription, no
// polling: the list changes with typing, opening or visible source mutations,
// and holds at most six matches plus a search, or three recent open pages.
// New Tab reads only its Space and privacy context; ⌘L keeps address history.
// The bounded open results resolve their explicit bookmark link for badges and
// destinations, without scanning pages or inferring identity from a shared URL.
//
// One order for every source (`ranked`): how a row stands — a bookmark's
// environments in New Tab, then the closer match — plus what choosing it
// after this query earned it (Habits.swift, which has the weights), then the
// order its source gave. Each source hands over as many rows as the list
// shows, and the places learned for the query even past that, so the cut
// comes after the order. The grey ending keeps the order before any lift.

@MainActor
final class Field: ObservableObject {
    /// What is in the field. Every change re-reads the history, because the
    /// list under the field and the grey ending inside it are both just
    /// answers to this string.
    @Published var typed = "" { didSet { guess() } }
    /// What the field is offering, best first.
    @Published private(set) var offers: [Suggestion] = []
    /// The rest of the best match, drawn grey after the caret. → takes it.
    @Published private(set) var ending: String?
    /// Which row the arrow keys have walked to, if any.
    @Published var picked: Int? { didSet { environmentIndex = nil; environmentFocused = false; environmentChosen = false } }
    @Published private(set) var environmentIndex: Int?
    @Published private(set) var environmentFocused = false
    /// False while walking onto a row only rings the environment it is on:
    /// Return keeps its plain meaning until an arrow, a click or → chooses one.
    @Published private(set) var environmentChosen = false
    /// Bumped when what was typed isn't an address and can't be searched for.
    @Published private(set) var refusals = 0
    /// Bumped whenever the cursor should go back into the field.
    @Published private(set) var focusRequest = 0
    /// The last request the field has answered with the keyboard in it. Not
    /// published: nothing is drawn from it; a script waits on it before typing.
    var focusGiven = 0

    @Published private(set) var github: GitHubSearch?
    private(set) var focusSelectsAll = true

    func startGitHub(_ search: GitHubSearch, typed: String) {
        summoning = false
        cycling = false
        github = search
        self.typed = typed
    }

    func stopGitHub() { github = nil }

    struct Opening: Equatable {
        let id = UUID()
        let shy: Bool
    }
    @Published private(set) var opening: Opening?

    func startOpening(shy: Bool) {
        stopGitHub()
        summoning = false
        cycling = false
        opening = Opening(shy: shy)
        typed = ""
    }

    func stopOpening() {
        stopGitHub()
        if opening != nil { opening = nil }
    }

    /// True while the field is a switcher rather than an address bar. ⌘K asks
    /// one question — which of the pages I already have open — and answering it
    /// with somewhere you went last week would be answering a different one.
    @Published private(set) var summoning = false
    /// True between the first ⌘K and letting go of ⌘.
    var cycling = false

    private let history: () -> History
    /// Where words would be searched for, or nil when they can't be.
    private let search: (String) -> URL?
    /// The name of the engine that search goes to, for its row.
    private let engine: () -> String
    /// Eligible tabs; a pending New Tab also offers the page underneath.
    private let others: () -> [Tab]
    private let newTab: () -> Bool
    private let bookmarks: () -> [Bookmark]
    private let bookmarkForTab: (UUID) -> Bookmark?
    /// What the rows taken before have taught, for the current Space.
    private let habits: () -> Habits?

    init(
        history: @escaping () -> History,
        search: @escaping (String) -> URL?,
        engine: @escaping () -> String,
        others: @escaping () -> [Tab],
        newTab: @escaping () -> Bool = { false },
        bookmarks: @escaping () -> [Bookmark] = { [] },
        bookmarkForTab: @escaping (UUID) -> Bookmark? = { _ in nil },
        habits: @escaping () -> Habits? = { nil }
    ) {
        self.history = history
        self.search = search
        self.engine = engine
        self.others = others
        self.newTab = newTab
        self.bookmarks = bookmarks
        self.bookmarkForTab = bookmarkForTab
        self.habits = habits
    }

    convenience init(
        history: History,
        search: @escaping (String) -> URL?,
        engine: @escaping () -> String,
        others: @escaping () -> [Tab],
        newTab: @escaping () -> Bool = { false },
        bookmarks: @escaping () -> [Bookmark] = { [] },
        bookmarkForTab: @escaping (UUID) -> Bookmark? = { _ in nil },
        habits: Habits? = nil
    ) {
        self.init(history: { history }, search: search, engine: engine, others: others, newTab: newTab,
                  bookmarks: bookmarks, bookmarkForTab: bookmarkForTab, habits: { habits })
    }

    /// Rows New Tab shows before its search row; ⌘L shows three.
    static let room = 6

    /// Typed plus whatever the field is quietly finishing for you; on a
    /// walked-to row, where Return goes. Walking off the top gives back what
    /// was typed, since `typed` never changes while walking.
    var completed: String {
        if github != nil { return typed }
        guard let selected else { return typed + (ending ?? "") }
        if let selectedEnvironment { return selectedEnvironment.url }
        // A row's key can be a tab's or a bookmark's title; a search's is the words.
        return selected.kind == .search ? selected.key : selected.url.absoluteString
    }

    /// Put the cursor back in the field, from wherever asked.
    func askFocus(selectAll: Bool = true) {
        focusSelectsAll = selectAll
        focusRequest += 1
    }

    /// What was typed can't be gone to; the field says so.
    func refuse() { refusals += 1 }

    /// ⌘K. Only what is open, nothing else: the list is the open pages from
    /// the first frame, before anything is typed.
    func startSummoning() {
        stopOpening()
        summoning = true
        typed = ""
    }

    func stopSummoning() { summoning = false }

    /// ⌘K again, with ⌘ still down: one step further down the list.
    func stepSummon() {
        cycling = true
        walk(1)
    }

    /// A backspace means the ending was not wanted. Recomputing it on the very
    /// next keystroke is right; putting it back on this one is what makes a
    /// field impossible to shorten.
    func stopCompleting() { ending = nil }

    /// The right arrow at the end of the line: take what is offered.
    func acceptEnding() {
        guard let ending, !ending.isEmpty else { return }
        typed += ending
    }

    /// The arrow keys walk the list, and walking off the top lets go of it.
    func walk(_ step: Int) {
        if let github { github.walk(step); return }
        guard !offers.isEmpty else { return }
        switch picked {
        case nil:
            picked = step > 0 ? 0 : offers.count - 1
        case let here?:
            let next = here + step
            picked = (next < 0 || next >= offers.count) ? nil : next
        }
        showCurrentEnvironment()
    }

    /// Walking onto a bookmark with environments rings the one it is on, so
    /// the first arrow already moves; nothing is chosen until it does.
    private func showCurrentEnvironment() {
        guard showsEnvironments, let selected else { return }
        let current = BookmarkEnvironment.current(in: selected.environments, at: selected.url)
        environmentIndex = current.flatMap { selected.environments.firstIndex(of: $0) } ?? 0
        environmentFocused = true
    }

    private func guess() {
        environmentIndex = nil
        environmentFocused = false
        environmentChosen = false
        if let github {
            offers = []
            ending = nil
            picked = nil
            github.ask(typed)
            return
        }
        let lifts = typed.isEmpty ? [:] : habits()?.lifts(for: typed) ?? [:]
        let learned = Set(lifts.keys)
        guard !summoning else {
            // Learned tabs past the cut compete, then the switcher keeps its count.
            let limit = Terms(typed).isEmpty ? Field.room : 3
            offers = Array(Field.ranked(openPages(matching: typed, keeping: learned), environments: false, lifts: lifts)
                .prefix(limit))
            ending = nil
            // The most recent page is already chosen, so ⌘K then Return is the
            // whole gesture.
            picked = offers.isEmpty ? nil : 0
            return
        }

        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else {
            offers = newTab() ? Array(openPages(matching: "").prefix(3)) : []
            ending = nil
            picked = nil
            return
        }

        let room = newTab() ? Field.room : 3
        let visited = history().suggestions(for: typed, limit: room, keeping: Set(learned.compactMap(Habits.visit)))
        var candidates = visited
        if newTab() {
            let saved = SearchEnvironments.matches(bookmarks(), query: typed, limit: room,
                                                   keeping: Set(learned.compactMap(Habits.bookmark)))
            let opened = openPages(matching: typed, keeping: learned)
            // A bookmark keeps its environment action even if its base URL
            // is open; history duplicates add no additional action.
            let openURLs = Set(opened.map { BookmarkEnvironment.key($0.url) })
            var savedURLs = Set<String>()
            let places = saved + visited.filter {
                let key = BookmarkEnvironment.key($0.url)
                return !openURLs.contains(key) && !saved.contains { BookmarkEnvironment.key($0.url) == key }
                    && savedURLs.insert(key).inserted
            }
            candidates = opened + places
        }
        var list = Array(Field.ranked(candidates, environments: newTab(), lifts: lifts).prefix(room))
        // Last in the list, and only when what was typed cannot be a place.
        if !typed.isEmpty,
           Address.url(from: typed) == nil,
           let asked = search(typed) {
            list.append(
                Suggestion(key: typed, title: engine(), url: asked, kind: .search)
            )
        }
        offers = list
        // What Return finishes without a chosen row is what was typed, read
        // as before anything was learned: rows move, the address does not.
        let shown = Set(list.map(\.id))
        ending = history().completion(for: typed, among: Field.ranked(candidates, environments: newTab(), lifts: [:])
            .filter { shown.contains($0.id) && ($0.kind == .visited || $0.kind == .known) })
        // A row that was picked stops being the right row the moment the
        // question changes.
        picked = nil
    }

    /// Candidates in the order the list shows them. A row stands on its
    /// closeness to the query (`Terms.Match`), a step each, and in New Tab on
    /// a bookmark's environments, ahead of every closeness; then on what it
    /// earned (`Habits.lifts`); then on the order its source gave it, so equal
    /// rows keep their places and the same data gives the same list.
    static func ranked(_ candidates: [Suggestion], environments: Bool, lifts: [String: Double]) -> [Suggestion] {
        let steps = Terms.Match.allCases.count
        return candidates.enumerated()
            .map { offset, offer -> (offer: Suggestion, offset: Int, standing: Double) in
                var standing = Double(steps - 1 - offer.match.rawValue)
                if environments, !offer.environments.isEmpty { standing += Double(steps) }
                if !lifts.isEmpty, let place = Habits.destination(of: offer) { standing += lifts[place] ?? 0 }
                return (offer, offset, standing)
            }
            .sorted { $0.standing != $1.standing ? $0.standing > $1.standing : $0.offset < $1.offset }
            .map(\.offer)
    }

    var selected: Suggestion? {
        guard let picked, offers.indices.contains(picked) else { return nil }
        return offers[picked]
    }

    /// The environment the ring is on, chosen or not: what VoiceOver says.
    var ringedEnvironment: BookmarkEnvironment? {
        guard environmentFocused, let selected, let environmentIndex,
              selected.environments.indices.contains(environmentIndex) else { return nil }
        return selected.environments[environmentIndex]
    }

    var selectedEnvironment: BookmarkEnvironment? {
        guard environmentChosen, let selected, let environmentIndex,
              selected.environments.indices.contains(environmentIndex) else { return nil }
        return selected.environments[environmentIndex]
    }

    var showsEnvironments: Bool { !summoning && (selected?.environments.count ?? 0) > 1 }

    /// The right arrow enters the environments once (walking onto the row has
    /// usually done it already); ← and → then choose one.
    @discardableResult func focusEnvironments() -> Bool {
        guard !summoning else { return false }
        if picked == nil, let first = offers.first, first.environments.count > 1 { picked = 0 }
        guard let selected, selected.environments.count > 1 else { return false }
        if environmentIndex == nil {
            let current = BookmarkEnvironment.current(in: selected.environments, at: selected.url)
            environmentIndex = current.flatMap { selected.environments.firstIndex(of: $0) } ?? 0
        }
        environmentFocused = true
        environmentChosen = true
        return true
    }

    func moveEnvironment(_ step: Int) {
        guard environmentFocused, let selected, let environmentIndex else { return }
        self.environmentIndex = (environmentIndex + step + selected.environments.count) % selected.environments.count
        environmentChosen = true
    }

    func leaveEnvironments(cancel: Bool = false) {
        environmentFocused = false
        if cancel { environmentIndex = nil; environmentChosen = false }
    }

    /// Live list changes never keep a closed tab or a removed bookmark selected.
    func refresh() {
        if let github { github.refresh(); return }
        let identity = selected?.id
        guess()
        picked = identity.flatMap { id in offers.firstIndex { $0.id == id } }
    }

    /// What is open, most recently looked at first, filtered by what has been
    /// typed. On an empty field this is the whole point of the summon: it is
    /// the tab strip, except you read it only when you ask for it.
    private func openPages(matching typed: String, keeping learned: Set<String> = []) -> [Suggestion] {
        let terms = Terms(typed)
        let prioritise = newTab() && !summoning && !terms.isEmpty
        let limit = terms.isEmpty || prioritise ? Field.room : 3
        // The closer match first (`Terms`), then the most recently looked at.
        let matching = others()
            .filter { !$0.isBlank && (!newTab() || summoning || !terms.isEmpty || $0.visited) }
            .compactMap { tab -> (tab: Tab, match: Terms.Match)? in
                guard !terms.isEmpty else { return (tab, .typed) }
                let address = tab.address.map { Address.pretty($0) } ?? ""
                return terms.match([tab.label, address]).map { (tab, $0) }
            }
            .sorted { $0.match != $1.match ? $0.match < $1.match : $0.tab.touched > $1.tab.touched }
        // Keep only bounded candidates while looking past recent ordinary
        // tabs for a matching environment, and for a learned place (Habits),
        // which follows. Recents and ⌘K keep their order.
        var preferred: [Suggestion] = []
        var ordinary: [Suggestion] = []
        var kept: [Suggestion] = []
        func wanted(_ offer: Suggestion) -> Bool { Habits.destination(of: offer).map(learned.contains) == true }
        for (tab, match) in matching {
            let full = prioritise ? preferred.count == limit : ordinary.count == limit
            if full, learned.isEmpty { break }
            guard let url = tab.address else { continue }
            let bookmark = bookmarkForTab(tab.id)
            let hasPriority = prioritise && !(bookmark?.destinations.isEmpty ?? true)
            let offer = Suggestion(key: tab.label, title: Address.pretty(url), url: url, kind: .open,
                                   tab: tab.id, bookmark: bookmark?.id, environments: bookmark?.destinations ?? [],
                                   match: match)
            if !full, hasPriority { preferred.append(offer) }
            else if !full, ordinary.count < limit { ordinary.append(offer) }
            else if wanted(offer) { kept.append(offer) }
        }
        let found = preferred + ordinary
        return Array(found.prefix(limit)) + found.dropFirst(limit).filter(wanted) + kept
    }
}
