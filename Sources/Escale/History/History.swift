import Foundation

// Where you have been, so the field can finish the address for you. Kept in one
// small file next to the app's own settings, written a moment after a visit
// rather than on every keystroke.
//
// At most 2,000 places, in memory as on disk. The file was always cut to that
// on saving, but the dictionary behind it never was: 20,000 imported or
// visited places stayed resident, and every key typed into the field read
// all of them — about 80 ms a key against 8 at 2,000 in a model benchmark
// (release build, M1). So the bound is applied where
// places come in — each visit, the end of an import, the file read at launch
// — and what goes is what has been visited least and longest ago: the order
// frecency gives, the same one the file was cut by. What is held is then
// exactly what is saved, and saving no longer sorts anything; a visit at the
// bound sorts the 2,000 once instead, about 0.4 ms on an M1. The field keeps
// only the best few matches as they come rather than sorting them all, which
// took a prefix every place shares from 8 ms to under 2 at 2,000 (release,
// same model benchmark).

struct Suggestion: Identifiable, Equatable {
    /// What you would have typed to get here: no scheme, no www.
    let key: String
    let title: String
    let url: URL
    let kind: Kind
    /// Set when this is a page you already have open somewhere.
    var tab: UUID?
    var bookmark: UUID?
    var environments: [BookmarkEnvironment] = []
    /// Set when this is a browser command, typed after `>` in New Tab.
    var action: KeyAction?
    /// How closely it answered what was typed, so New Tab can merge its sources.
    var match: Terms.Match = .typed

    /// Only a linked open page can claim an unambiguous environment.
    var activeEnvironment: BookmarkEnvironment? {
        guard tab != nil, bookmark != nil else { return nil }
        return BookmarkEnvironment.current(in: environments, at: url)
    }

    enum Kind {
        /// A page that is open right now.
        case open
        /// A saved site, with its existing environment choices.
        case bookmark
        /// Somewhere you have actually been.
        case visited
        /// One of the well-known addresses the field knows from the start.
        case known
        /// Not a place at all — words, and an engine to ask.
        case search
        /// Words, and the site whose keyword was typed before them.
        case keyword
        /// Not a place either: a command, run as its shortcut would run it.
        case command
    }

    var id: String { tab?.uuidString ?? bookmark?.uuidString ?? "\(kind):\(url.absoluteString)" }
}

struct Visit: Codable {
    var url: String
    var key: String
    var title: String
    var count: Int
    var last: Date
}

@MainActor
final class History: ObservableObject {
    private var visits: [String: Visit] = [:] {
        didSet {
            recentCache = nil
            objectWillChange.send()
        }
    }
    /// The last few places, as the History menu lists them. The menu bar is
    /// drawn again whenever anything in the window changes — every key typed
    /// into the address field included — and sorting the whole history for
    /// it each time cost more than everything else a key press does.
    private var recentCache: [Trace]?
    /// Told when places are forgotten, one key or all of them (nil), by any
    /// way in: what was learned about them goes too (Habits.swift).
    var forgotten: ((String?) -> Void)?
    private var saving = false
    private let file: URL

    /// How many places are kept, in memory and on disk.
    static let room = 2_000

    /// Existing history stays with the first space. Other spaces start empty.
    static func file(for space: UUID) -> URL {
        Store.file(space == Space.firstID ? "history.json" : "history-\(space.uuidString).json")
    }

    /// Another file only for tests; the browser's is the default.
    init(file: URL = Store.file("history.json")) {
        self.file = file
        load()
    }

    convenience init(space: UUID) { self.init(file: History.file(for: space)) }

    static func erase(space: UUID) {
        guard space != Space.firstID else { return }
        Writer.to(file(for: space)).remove()
    }

    /// A Space's places as its file holds them, for a transfer file: what the
    /// history was still waiting to write has been handed over first
    /// (Browser.flush), and the file read here is what is on disk by then.
    static func saved(space: UUID) -> [Visit] {
        let file = file(for: space)
        Writer.to(file).flush()
        guard let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([Visit].self, from: data) else { return [] }
        return list
    }

    /// The places of an arriving Space, on disk before the Space is published.
    static func restore(_ visits: [Visit], to space: UUID) -> Bool {
        let writer = Writer.to(file(for: space))
        writer.save(visits)
        writer.flush()
        return writer.failure == nil
    }

    /// How many places are held, the domains credited for their pages included.
    var count: Int { visits.count }

    // MARK: - writing

    func record(_ url: URL, title: String) {
        guard url.scheme == "http" || url.scheme == "https" else { return }
        let key = Address.pretty(url).lowercased()
        guard !key.isEmpty else { return }
        // Never the page just opened, nor its domain: whatever else is least
        // used makes room for them.
        var spared: Set<String> = [key]

        // Reading a deep page is also, in the way that matters here, another
        // visit to the site. Without this, typing three letters offers the
        // article you happened to open last week rather than the front page —
        // and nobody types a domain meaning to land halfway down it.
        if let host = url.host(), key.contains("/") {
            let root = (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host).lowercased()
            var home = visits[root] ?? Visit(
                url: "https://" + root + "/", key: root, title: "", count: 0, last: Date()
            )
            home.count += 1
            home.last = Date()
            visits[root] = home
            spared.insert(root)
        }

        if var seen = visits[key] {
            seen.count += 1
            seen.last = Date()
            seen.url = url.absoluteString
            if !title.isEmpty { seen.title = title }
            visits[key] = seen
        } else {
            visits[key] = Visit(
                url: url.absoluteString,
                key: key,
                title: title,
                count: 1,
                last: Date()
            )
        }
        trim(sparing: spared)
        save()
    }

    /// Somewhere another browser has been. Counted as it was counted there,
    /// so a site visited daily for a year outranks one seen once — the day
    /// you switch, the field already knows you. A batch of these ends with
    /// `settle`, which brings the history back within its bound.
    func take(_ url: URL, title: String, count: Int, last: Date) {
        guard url.scheme == "http" || url.scheme == "https" else { return }
        let key = Address.pretty(url).lowercased()
        guard !key.isEmpty else { return }
        if var seen = visits[key] {
            seen.count += count
            if last > seen.last { seen.last = last }
            if seen.title.isEmpty { seen.title = title }
            visits[key] = seen
        } else {
            visits[key] = Visit(url: url.absoluteString, key: key, title: title, count: count, last: last)
        }
    }

    /// Migration uses maxima rather than addition, so a replay after a crash
    /// cannot inflate visits. Existing titles win and the normal bound applies.
    func importVisits(_ incoming: [MigrationVisit], done: @escaping (Bool) -> Void) {
        var next = visits
        for visit in incoming {
            let key = Address.pretty(visit.url).lowercased()
            guard !key.isEmpty else { continue }
            if var old = next[key] {
                old.count = max(old.count, visit.count)
                old.last = max(old.last, visit.last)
                if old.title.isEmpty { old.title = visit.title }
                next[key] = old
            } else {
                next[key] = Visit(url: visit.url.absoluteString, key: key, title: visit.title,
                                  count: visit.count, last: visit.last)
            }
        }
        visits = next
        trim()
        let writer = Writer.to(file)
        writer.save(Array(visits.values))
        writer.acknowledge(done)
    }

    /// After a batch of `take`s: back within the bound, then saved.
    func settle() {
        trim()
        save()
    }

    /// A page's title usually lands a beat after the page does.
    func retitle(_ url: URL, _ title: String) {
        let key = Address.pretty(url).lowercased()
        guard !title.isEmpty, var seen = visits[key], seen.title != title else { return }
        seen.title = title
        visits[key] = seen
        save()
    }

    func forget() {
        visits = [:]
        save()
        forgotten?(nil)
    }

    /// Everywhere you have been, newest first, for the window that shows it.
    struct Trace: Identifiable, Equatable {
        let key: String
        let title: String
        let url: URL
        let last: Date
        let count: Int

        var id: String { key }
    }

    func everything(matching typed: String = "") -> [Trace] {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        return visits.values
            // Every visit to a page also credits its domain, so the address
            // field can offer the front door. Those credits have no title of
            // their own, and in a list of where you have been they are a second
            // copy of every line.
            .filter { !($0.title.isEmpty && !$0.key.contains("/")) }
            .filter {
                needle.isEmpty
                    || $0.key.contains(needle)
                    || $0.title.lowercased().contains(needle)
            }
            .sorted { $0.last > $1.last }
            .compactMap { visit in
                URL(string: visit.url).map {
                    Trace(
                        key: visit.key,
                        title: visit.title,
                        url: $0,
                        last: visit.last,
                        count: visit.count
                    )
                }
            }
    }

    func forget(_ key: String) {
        visits[key] = nil
        save()
        forgotten?(key)
    }

    /// The last eight places, newest first; worked out again only once the
    /// history has changed.
    func recent() -> [Trace] {
        if let recentCache { return recentCache }
        let made = Array(everything().prefix(8))
        recentCache = made
        return made
    }

    // MARK: - reading

    /// When this page was last opened, while it is still remembered.
    func last(_ url: URL) -> Date? {
        visits[Address.pretty(url).lowercased()]?.last
    }

    /// Domain matches lead; titles and paths also recover a visited page,
    /// as typed first, then by their words (`Terms`). Frequency and recency
    /// distinguish visits within each match category. Places under a key in
    /// `keeping` (Habits.swift) follow the best few when they match but do
    /// not make it, so Field can weigh what was learned before it cuts.
    func suggestions(for typed: String, limit: Int = 5, keeping: Set<String> = []) -> [Suggestion] {
        let needle = strip(typed)
        let terms = Terms(needle)
        // An empty field proposes nothing. A list of guesses in front of
        // someone who has not yet said what they want is noise, and it is in
        // the way of the one thing they came here to do.
        guard !needle.isEmpty else { return [] }

        let now = Date()
        // Only the best few are kept as they come, instead of every match
        // being made into a suggestion and the lot sorted: a common prefix
        // matches nearly the whole history, and the list shows three.
        var best: [(Suggestion, Double)] = []
        var kept: [(Suggestion, Double)] = []

        /// Whether a score and key come before another's: higher first, then
        /// the shorter address, then the alphabet, so that equal places come
        /// out in the same order every time.
        func ahead(_ score: Double, _ key: String, of other: (Suggestion, Double)) -> Bool {
            if score != other.1 { return score > other.1 }
            if key.count != other.0.key.count { return key.count < other.0.key.count }
            return key < other.0.key
        }

        func offer(_ key: String, _ score: Double, _ made: () -> Suggestion?) {
            // Full, and not ahead of the last one: only a kept place goes on.
            if best.count >= limit, best.last.map({ !ahead(score, key, of: $0) }) ?? true {
                if keeping.contains(key), let suggestion = made() { kept.append((suggestion, score)) }
                return
            }
            // Only now, for the few that make it: reading the address into a
            // URL was most of what a match cost.
            guard let suggestion = made() else { return }
            let at = best.firstIndex { ahead(score, key, of: $0) } ?? best.endIndex
            best.insert((suggestion, score), at: at)
            if best.count > limit, let out = best.popLast(), keeping.contains(out.0.key) { kept.append(out) }
        }

        for visit in visits.values {
            let domain = rank(visit.key, against: needle)
            let content = domain == nil ? contentRank(visit, against: needle, terms: terms) : nil
            guard let rank = domain ?? content?.rank else { continue }
            // The front door before the room inside it: a bare domain is
            // what a bare domain typed into a field means.
            // Content matches stay below domain matches, even for frequent pages.
            let weight = frecency(visit, now: now)
            let score = domain == nil
                ? rank + weight / (10 + weight)
                : rank + 4 + weight + (visit.key.contains("/") ? 0 : 1.5)
            offer(visit.key, score) {
                URL(string: visit.url).map {
                    Suggestion(key: visit.key, title: visit.title, url: $0, kind: .visited, match: content?.match ?? .typed)
                }
            }
        }

        // Only where memory has nothing to offer. A list of famous websites is
        // a poor substitute for knowing where someone actually goes.
        for known in History.known where visits[known.0] == nil {
            guard let rank = rank(known.0, against: needle) else { continue }
            offer(known.0, rank) {
                URL(string: "https://" + known.0).map { Suggestion(key: known.0, title: known.1, url: $0, kind: .known) }
            }
        }

        kept.sort { ahead($0.1, $0.0.key, of: $1) }
        return (best + kept).map(\.0)
    }

    /// What the field should draw greyed out after the caret: the rest of the
    /// best match, or nothing if it doesn't carry on from what was typed.
    func completion(for typed: String, among options: [Suggestion]) -> String? {
        let lower = typed.lowercased()
        guard !lower.isEmpty, lower.count >= 2 else { return nil }
        guard let hit = options.first(where: { $0.key.hasPrefix(lower) }) else { return nil }
        let rest = String(hit.key.dropFirst(lower.count))
        return rest.isEmpty ? nil : rest
    }

    /// Frecency, plus the same preference for a front door over a room inside
    /// it that the search uses.
    private func standing(_ visit: Visit, now: Date) -> Double {
        frecency(visit, now: now) + (visit.key.contains("/") ? 0 : 1.5)
    }

    /// Where the match falls decides most of the ordering: the start of the
    /// host is what people mean, the middle of a path almost never is.
    private func rank(_ key: String, against needle: String) -> Double? {
        if key.hasPrefix(needle) { return 6 }
        // Read in place: this runs for every place in the history on every
        // key, and splitting each key into new strings was most of its cost.
        let host = key[..<(key.firstIndex(of: "/") ?? key.endIndex)]
        // "hub" finding github.com, once the "git" has been skipped.
        if let dot = host.firstIndex(of: "."), host[host.index(after: dot)...].hasPrefix(needle) { return 3 }
        // Only from two letters up. A single letter matching anywhere inside
        // a name turns "x" into example.com and netflix.com, which is not what
        // anybody meant by it.
        if needle.count >= 2, host.contains(needle) { return 2 }
        return nil
    }

    /// Three letters keep incidental path/title matches out of short domain
    /// queries. Query strings and fragments are not useful page names.
    /// Matches by words rank below every match as typed, whatever the habit:
    /// the frecency share of a score stays under one.
    private func contentRank(_ visit: Visit, against needle: String, terms: Terms) -> (rank: Double, match: Terms.Match)? {
        guard needle.count >= 3 else { return nil }
        let typed = terms.whole
        let title = visit.title.lowercased()
        if title.contains(typed) { return (1, .typed) }
        // Most visits do not match. Reject them before walking URL delimiters;
        // the domain check already ruled out a match in the host. An address
        // holds no space, so words typed apart are only looked for by word.
        if !terms.spaced, visit.key.contains(typed),
           visit.key.prefix(while: { $0 != "?" && $0 != "#" }).contains(typed) { return (0.5, .typed) }
        guard terms.mayMatch(visit.title, visit.key) else { return nil }
        // Words may be spread across the title and the address.
        let address = visit.key.prefix { $0 != "?" && $0 != "#" }
        guard let match = terms.byWords([visit.title[...], address]) else { return nil }
        return (match == .joined ? -1 : -2, match)
    }

    /// Often, and lately. A month-old visit counts for about a third of a
    /// fresh one, which is roughly how long a habit takes to stop being one.
    private func frecency(_ visit: Visit, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(visit.last) / 86_400)
        return Double(visit.count) * exp(-days / 30)
    }

    private func strip(_ typed: String) -> String {
        var text = typed.trimmingCharacters(in: .whitespaces).lowercased()
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count))
        }
        if text.hasPrefix("www.") { text = String(text.dropFirst(4)) }
        return text
    }

    // MARK: - the bound

    /// Back to `room` places, the least used going first. `sparing` is what
    /// has just been visited, which stays whatever its count.
    private func trim(sparing spared: Set<String> = []) {
        let over = visits.count - History.room
        guard over > 0 else { return }
        let now = Date()
        // Scored once rather than in every comparison. Ties go by key, so the
        // same history always keeps the same places.
        var scored: [(key: String, score: Double)] = []
        for visit in visits.values where !spared.contains(visit.key) {
            scored.append((visit.key, frecency(visit, now: now)))
        }
        scored.sort { $0.score == $1.score ? $0.key > $1.key : $0.score < $1.score }
        let doomed = scored.prefix(over)
        var left = visits
        for place in doomed { left[place.key] = nil }
        visits = left
    }

    // MARK: - the file

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        guard let list = try? JSONDecoder().decode([Visit].self, from: data) else {
            Store.quarantine(file)
            return
        }
        visits = Dictionary(uniqueKeysWithValues: list.map { ($0.key, $0) })
        // A file from before the bound, or from elsewhere: cut to it once,
        // and saved that way.
        if visits.count > History.room {
            trim()
            save()
        }
    }

    /// Coalesced: a busy minute of browsing writes the file once, not thirty
    /// times, never on the main thread, and in the order it changed (see
    /// Writer.swift) — a history cleared stays cleared.
    private func save() {
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.hand()
        }
    }

    /// What the wait above is holding back, handed to the writer now.
    private func hand() {
        guard saving else { return }
        saving = false
        // Already within the bound (see trim): nothing to sort or cut here.
        Writer.to(file).save(Array(visits.values))
    }

    /// Quitting doesn't wait out the moment: the last visits are written
    /// before this returns (see Browser.flush).
    func flush() {
        hand()
        Writer.to(file).flush()
    }

    /// Somewhere to start on the first day, before there is any history to go
    /// on. Ranked below anything actually visited, and dropped from the list
    /// the moment you have been there yourself.
    private static let known: [(String, String)] = [
        ("google.com", "Google"), ("mail.google.com", "Gmail"),
        ("drive.google.com", "Google Drive"), ("calendar.google.com", "Google Calendar"),
        ("maps.google.com", "Google Maps"), ("youtube.com", "YouTube"),
        ("github.com", "GitHub"), ("figma.com", "Figma"), ("vercel.com", "Vercel"),
        ("notion.so", "Notion"), ("linear.app", "Linear"), ("slack.com", "Slack"),
        ("discord.com", "Discord"), ("x.com", "X"), ("linkedin.com", "LinkedIn"),
        ("instagram.com", "Instagram"), ("reddit.com", "Reddit"),
        ("news.ycombinator.com", "Hacker News"), ("stackoverflow.com", "Stack Overflow"),
        ("claude.ai", "Claude"), ("chatgpt.com", "ChatGPT"),
        ("dribbble.com", "Dribbble"), ("behance.net", "Behance"),
        ("awwwards.com", "Awwwards"), ("mobbin.com", "Mobbin"),
        ("siteinspire.com", "SiteInspire"), ("are.na", "Are.na"),
        ("pinterest.com", "Pinterest"), ("framer.com", "Framer"),
        ("webflow.com", "Webflow"), ("developer.apple.com", "Apple Developer"),
        ("swift.org", "Swift"), ("npmjs.com", "npm"), ("supabase.com", "Supabase"),
        ("stripe.com", "Stripe"), ("shopify.com", "Shopify"),
        ("cloudflare.com", "Cloudflare"), ("netlify.com", "Netlify"),
        ("apple.com", "Apple"), ("spotify.com", "Spotify"), ("netflix.com", "Netflix"),
        ("wikipedia.org", "Wikipedia"), ("deepl.com", "DeepL"), ("loom.com", "Loom"),
        ("amazon.fr", "Amazon"), ("leboncoin.fr", "leboncoin"), ("lemonde.fr", "Le Monde"),
    ]
}
