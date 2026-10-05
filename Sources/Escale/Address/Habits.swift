// What Bearings learns from the rows you take: for a query, the places you
// went to from it, so that typing it again puts them higher.
// Type `handlers`, take the third row, and the next `handlers` shows it first
// among the rows that answer as well; take it again and it can pass a row
// that answers a little better. Nothing is shown for it in the rows: the
// order is the whole of the feature.
//
// The model, small enough to explain and to test:
//
// - A query is read as `Terms` reads it: lowercased, composed, spaces as one.
//   `Handlers ` and `handlers` are one query, `handler` another; two
//   questions are never merged. Past 64 characters it is not learned.
// - A destination is what a row leads to, the same whichever way it is
//   offered: a bookmark by its identity, with its open tab and whatever
//   environment was chosen (one row either way); any other page by the key
//   the history keeps it under (no scheme, www, query or fragment), plus its
//   port, so two local servers stay apart. A tab taken and then closed still
//   lifts the same page in the history. A web search is never learned: its
//   row stays last and its words are what was typed.
// - Each choice counts one, capped at five, and halves every other place
//   remembered for that query, so a changed habit wins on its second choice.
//   A count fades as the history's frecency does, to a third in a month, and
//   is forgotten under a tenth: a single choice lasts about ten weeks.
// - A remembered place earns its row 0.6 per choice, at most 1.5 (`lift`).
//   In Field, a closer match (`Terms.Match`) is worth a whole step and a
//   bookmark's environments three, so one choice orders rows that stand
//   level, two can pass the step just above, and nothing passes two: a match
//   by scattered words, however often chosen, stays under the query as typed.
// - Only rows already offered for the current query are lifted. Nothing is
//   added, so a closed tab, a deleted bookmark or a forgotten page does not
//   come back. The grey completion and Return with no row chosen keep the
//   order before any lift: an address typed out goes where it says.
//
// Worked through: `handlers` offers A, B, C, all matching as typed. Take C:
// C (0.6) leads A and B. Take B twice: B has 2 (lift 1.2), C 0.25 (0.15), and
// the order is B, C, A. With `orchestrator handlers`, a page matching by
// scattered words (standing 0) chosen twice (1.2) passes pages with the words
// joined (1), not a page holding the query as typed (2).
//
// Bounds: 200 queries, 4 places each, 512 characters a place. Past 200 the
// queries whose strongest place is weakest go, ties by the query's text, so
// the same memory always keeps the same queries; at most about 450 KB on
// disk, usually a few. A choice also lets go of faded places and of bookmarks
// no longer in the Space.
//
// One per Space, in its own file through `Store`, so a test world keeps its
// own. A deleted Space takes its file; clearing the history clears it and
// forgetting a page forgets it there too, whoever asks (History.forgotten,
// extensions included). Private search learns nothing.
// Read once, when its Space's field first asks; a key typed looks up one
// query in a dictionary; a choice is written a moment later, coalesced and
// off the main thread (Writer.swift). No timer, no network.

import Foundation

@MainActor
final class Habits {
    /// One place taken after a query.
    struct Pick: Codable, Equatable {
        /// `bookmark:ID`, or `page:` and the history's key, then ` :port`.
        var to: String
        /// Choices, halved by each choice of another place, before fading.
        var count: Double
        var last: Date
    }

    private struct Entry: Codable {
        var query: String
        var picks: [Pick]
    }

    private var picks: [String: [Pick]] = [:]
    private var saving = false
    private let file: URL

    static let queries = 200
    static let places = 4
    static let longestQuery = 64
    static let longestPlace = 512
    /// The most one place counts for a query.
    static let most = 5.0
    /// Under this, a place is forgotten.
    static let faint = 0.1
    /// A count's decay, the history's frecency's (History.swift).
    static let fade: TimeInterval = 30 * 86_400
    /// What a choice earns a row in Field, and the most any place earns.
    static let step = 0.6
    static let highest = 1.5

    static func file(for space: UUID) -> URL {
        Store.file("habits-\(space.uuidString).json")
    }

    /// Another file only for tests; a Space's is `init(space:)`.
    init(file: URL) {
        self.file = file
        load()
    }

    convenience init(space: UUID) { self.init(file: Habits.file(for: space)) }

    static func erase(space: UUID) {
        Writer.to(file(for: space)).remove()
    }

    /// What a Space has learned, for a transfer file.
    static func saved(space: UUID) -> [String: [Pick]] {
        Writer.to(file(for: space)).flush()
        return Habits(space: space).picks
    }

    /// What an arriving Space has learned, before it is published. A place
    /// that was a bookmark follows the bookmark's new identity; one whose
    /// bookmark didn't arrive is let go, as a choice lets go of it.
    static func restore(_ learned: [String: [Pick]], to space: UUID, bookmarks: [UUID: UUID]) -> Bool {
        var list: [Entry] = []
        for (query, places) in learned.sorted(by: { $0.key < $1.key }) {
            let kept = places.compactMap { pick -> Pick? in
                guard let old = bookmark(in: pick.to) else { return pick }
                guard let new = bookmarks[old] else { return nil }
                var moved = pick
                moved.to = "bookmark:" + new.uuidString
                return moved
            }
            if !kept.isEmpty { list.append(Entry(query: query, picks: kept)) }
        }
        guard valid(list) else { return false }
        let writer = Writer.to(file(for: space))
        writer.save(list)
        writer.flush()
        return writer.failure == nil
    }

    /// How many queries are remembered.
    var count: Int { picks.count }

    // MARK: - identities

    /// A query as it is remembered, or nil if it is not.
    static func query(_ typed: String) -> String? {
        let whole = Terms(typed).whole
        return whole.isEmpty || whole.count > longestQuery ? nil : whole
    }

    /// Where a row leads, or nil for a web search.
    static func destination(of offer: Suggestion) -> String? {
        guard offer.kind != .search else { return nil }
        if let bookmark = offer.bookmark { return "bookmark:" + bookmark.uuidString }
        let key = "page:" + Address.pretty(offer.url).lowercased()
        return offer.url.port.map { key + " :\($0)" } ?? key
    }

    /// The bookmark a destination names, if it names one.
    static func bookmark(in destination: String) -> UUID? {
        guard destination.hasPrefix("bookmark:") else { return nil }
        return UUID(uuidString: String(destination.dropFirst("bookmark:".count)))
    }

    /// The history's key for a page destination: the page, whatever its port.
    static func visit(in destination: String) -> String? {
        guard destination.hasPrefix("page:") else { return nil }
        return String(destination.dropFirst("page:".count).prefix { $0 != " " })
    }

    // MARK: - reading

    /// What each place remembered for this query earns its row.
    func lifts(for typed: String, now: Date = Date()) -> [String: Double] {
        guard let query = Habits.query(typed), let known = picks[query] else { return [:] }
        var lifts: [String: Double] = [:]
        for pick in known {
            let strength = Habits.strength(pick, now: now)
            guard strength >= Habits.faint else { continue }
            lifts[pick.to] = min(Habits.highest, Habits.step * strength)
        }
        return lifts
    }

    private static func strength(_ pick: Pick, now: Date) -> Double {
        pick.count * exp(-max(0, now.timeIntervalSince(pick.last)) / fade)
    }

    // MARK: - writing

    /// A row was taken for `typed`. `alive` says whether a remembered place
    /// still exists; the ones that do not are let go.
    func learn(_ typed: String, chose destination: String, now: Date = Date(),
               alive: (String) -> Bool = { _ in true }) {
        guard let query = Habits.query(typed), destination.count <= Habits.longestPlace else { return }
        var chosen = Pick(to: destination, count: 1, last: now)
        var others: [Pick] = []
        for pick in picks[query] ?? [] {
            let strength = Habits.strength(pick, now: now)
            if pick.to == destination {
                // What had faded out counts for nothing: this starts again.
                chosen.count = min(Habits.most, (strength >= Habits.faint ? strength : 0) + 1)
            } else if strength / 2 >= Habits.faint, alive(pick.to) {
                others.append(Pick(to: pick.to, count: strength / 2, last: now))
            }
        }
        // The chosen place always stays; the strongest others fill the rest.
        others.sort { $0.count != $1.count ? $0.count > $1.count : $0.to < $1.to }
        picks[query] = [chosen] + others.prefix(Habits.places - 1)
        settle(now: now, sparing: query, alive: alive)
        save()
    }

    /// Clearing the history: nothing learned stays either.
    func forget() {
        guard !picks.isEmpty else { return }
        picks = [:]
        save()
    }

    /// A page forgotten from the history, under its key and on every port.
    func forget(visit key: String, space: UUID? = nil) {
        let object = space.flatMap { context in
            URL(string: "https://" + key).flatMap { GitHubItem.ID(url: $0, space: context) }
        }
        var left = picks
        var changed = false
        for (query, list) in picks {
            let kept = list.filter { pick in
                guard let visit = Habits.visit(in: pick.to) else { return true }
                if visit == key { return false }
                guard let object, let url = URL(string: "https://" + visit) else { return true }
                return GitHubItem.ID(url: url, space: object.space) != object
            }
            guard kept.count != list.count else { continue }
            left[query] = kept.isEmpty ? nil : kept
            changed = true
        }
        guard changed else { return }
        picks = left
        save()
    }

    /// Faded and vanished places let go, then back within `queries`.
    private func settle(now: Date, sparing spared: String? = nil, alive: (String) -> Bool = { _ in true }) {
        var strongest: [(query: String, strength: Double)] = []
        var left: [String: [Pick]] = [:]
        for (query, list) in picks {
            let kept = list.filter { Habits.strength($0, now: now) >= Habits.faint && alive($0.to) }
            guard !kept.isEmpty else { continue }
            left[query] = kept
            if query != spared {
                strongest.append((query, kept.map { Habits.strength($0, now: now) }.max() ?? 0))
            }
        }
        let over = left.count - Habits.queries
        if over > 0 {
            strongest.sort { $0.strength != $1.strength ? $0.strength < $1.strength : $0.query < $1.query }
            for doomed in strongest.prefix(over) { left[doomed.query] = nil }
        }
        picks = left
    }

    // MARK: - the file

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        guard let list = try? JSONDecoder().decode([Entry].self, from: data), Habits.valid(list) else {
            Store.quarantine(file)
            return
        }
        for entry in list {
            // Strongest first, as `learn` keeps them; a longer list is cut.
            let sorted = entry.picks.sorted { $0.count != $1.count ? $0.count > $1.count : $0.to < $1.to }
            picks[entry.query] = Array(sorted.prefix(Habits.places))
        }
        let before = picks.count
        settle(now: Date())
        if picks.count != before { save() }
    }

    /// Unique, normalised queries, each with distinct places and counts a
    /// choice could have made. Anything else is not this file.
    private static func valid(_ list: [Entry]) -> Bool {
        var seen = Set<String>()
        for entry in list {
            guard query(entry.query) == entry.query, seen.insert(entry.query).inserted,
                  !entry.picks.isEmpty, Set(entry.picks.map(\.to)).count == entry.picks.count
            else { return false }
            for pick in entry.picks {
                guard pick.count.isFinite, pick.count > 0, pick.count <= most,
                      !pick.to.isEmpty, pick.to.count <= longestPlace,
                      bookmark(in: pick.to) != nil || visit(in: pick.to).map({ !$0.isEmpty }) == true
                else { return false }
            }
        }
        return true
    }

    /// Coalesced, as the history's: a burst of choices writes once, never
    /// on the main thread, in the order it changed (Writer.swift).
    private func save() {
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.hand()
        }
    }

    private func hand() {
        guard saving else { return }
        saving = false
        let list = picks.keys.sorted().map { Entry(query: $0, picks: picks[$0] ?? []) }
        Writer.to(file).save(list)
    }

    /// Quitting doesn't wait out the moment (see Browser.flush).
    func flush() {
        hand()
        Writer.to(file).flush()
    }
}

/// What was typed, and where, read before a row is taken: going there
/// empties the field and ends the New Tab that knew it was private.
struct Choice {
    let typed: String
    let shy: Bool
    let space: UUID

    @MainActor init(of browser: Browser) {
        typed = browser.field.typed
        shy = browser.searchIsPrivate
        space = browser.spaceID
    }
}

extension Browser {
    func habits(for id: UUID) -> Habits {
        if let known = habitsBySpace[id] { return known }
        let made = Habits(space: id)
        habitsBySpace[id] = made
        return made
    }

    /// A row taken and gone to, by the keyboard or the pointer: remembered
    /// for what was typed. A row only walked to, or shown, teaches nothing;
    /// neither does private search.
    func learn(_ offer: Suggestion, _ choice: Choice) {
        guard !choice.shy, Habits.query(choice.typed) != nil,
              let destination = Habits.destination(of: offer) else { return }
        // Once per choice, not per key: the Space's bookmarks, to let go of
        // places learned for bookmarks deleted since.
        var saved = Set<UUID>()
        func gather(_ nodes: [Bookmark]) {
            for node in nodes {
                saved.insert(node.id)
                gather(node.children ?? [])
            }
        }
        gather(bookmarks(of: choice.space).roots)
        habits(for: choice.space).learn(choice.typed, chose: destination) { place in
            Habits.bookmark(in: place).map(saved.contains) ?? true
        }
    }
}
