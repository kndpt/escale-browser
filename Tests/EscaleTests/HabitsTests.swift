import Foundation
import Testing
@testable import Escale

// What Bearings learns from the rows taken (see Habits.swift), and how Field
// orders its rows with it. Files of the test's own; places are synthetic
// hosts under .test; searches go to a synthetic engine and nothing is fetched.
// No Browser: taking a row is `learn`, as Browser.take calls it once the row
// was gone to (the app journey is in Tests/Bench/new_tab_search.py).

private func folder() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("escale-habits-\(UUID().uuidString)", isDirectory: true)
}

private func searching(_ words: String) -> URL? {
    let trimmed = words.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    return URL(string: "https://search.example.test/?q=\(trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")")
}

private func url(_ text: String) -> URL {
    URL(string: text) ?? URL(fileURLWithPath: "/")
}

private func page(_ text: String) -> Suggestion {
    Suggestion(key: Address.pretty(url(text)), title: "", url: url(text), kind: .visited)
}

@MainActor
private func destination(_ offer: Suggestion) -> String {
    Habits.destination(of: offer) ?? ""
}

private let day: TimeInterval = 86_400

@MainActor
@Suite struct HabitsModelTests {
    @Test func queriesAreReadAsTermsReadThemAndLongOnesAreNotLearned() {
        #expect(Habits.query("  Handlers ") == "handlers")
        #expect(Habits.query("orchestrator   HANDLERS") == "orchestrator handlers")
        #expect(Habits.query("handler") == "handler")
        #expect(Habits.query("   ") == nil)
        #expect(Habits.query(String(repeating: "a", count: Habits.longestQuery)) != nil)
        #expect(Habits.query(String(repeating: "a", count: Habits.longestQuery + 1)) == nil)
    }

    @Test func aDestinationIsTheBookmarkOrThePageWithItsPortAndNeverASearch() {
        let bookmark = UUID()
        let saved = Suggestion(key: "Project", title: "", url: url("https://a.test/"), kind: .bookmark, bookmark: bookmark)
        var open = Suggestion(key: "Project", title: "", url: url("https://a.test/dev?x=1"), kind: .open, tab: UUID(), bookmark: bookmark)
        #expect(destination(saved) == "bookmark:" + bookmark.uuidString)
        // Its open tab, in whatever environment, is the same row.
        #expect(destination(open) == destination(saved))
        open.bookmark = nil
        // A plain tab is its page, as the history keys it.
        #expect(destination(open) == "page:a.test/dev")
        #expect(destination(page("https://www.A.test/dev#top")) == "page:a.test/dev")
        #expect(destination(page("http://localhost:3000/app")) == "page:localhost/app :3000")
        #expect(destination(page("http://localhost:3000/app")) != destination(page("http://localhost:5173/app")))
        #expect(Habits.visit(in: destination(page("http://localhost:3000/app"))) == "localhost/app")
        #expect(Habits.bookmark(in: destination(saved)) == bookmark)
        #expect(Habits.bookmark(in: "page:a.test") == nil)
        let search = Suggestion(key: "handlers", title: "Synthetic", url: url("https://search.example.test/?q=handlers"), kind: .search)
        #expect(Habits.destination(of: search) == nil)
    }

    @Test func oneChoiceLiftsLevelRowsAndRepeatedChoicesAreBounded() {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let habits = Habits(file: root.appendingPathComponent("habits.json"))
        let now = Date()
        let chosen = destination(page("https://c.test/handlers"))
        #expect(habits.lifts(for: "handlers", now: now).isEmpty)
        habits.learn("handlers", chose: chosen, now: now)
        #expect(habits.lifts(for: "handlers", now: now) == [chosen: Habits.step])
        // The same query however it was typed; another query learns nothing.
        #expect(habits.lifts(for: " HANDLERS", now: now) == [chosen: Habits.step])
        #expect(habits.lifts(for: "handler", now: now).isEmpty)
        #expect(habits.lifts(for: "handlers api", now: now).isEmpty)
        habits.learn("handlers", chose: chosen, now: now)
        #expect(habits.lifts(for: "handlers", now: now)[chosen] == 2 * Habits.step)
        for _ in 0..<20 { habits.learn("handlers", chose: chosen, now: now) }
        #expect(habits.lifts(for: "handlers", now: now)[chosen] == Habits.highest)
    }

    @Test func aChangedHabitWinsOnItsSecondChoice() {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let habits = Habits(file: root.appendingPathComponent("habits.json"))
        let now = Date()
        let (old, new) = (destination(page("https://old.test/")), destination(page("https://new.test/")))
        for _ in 0..<10 { habits.learn("handlers", chose: old, now: now) }
        habits.learn("handlers", chose: new, now: now)
        var lifts = habits.lifts(for: "handlers", now: now)
        #expect(lifts[old] ?? 0 > lifts[new] ?? 0)
        habits.learn("handlers", chose: new, now: now)
        lifts = habits.lifts(for: "handlers", now: now)
        #expect(lifts[new] ?? 0 > lifts[old] ?? 0)
    }

    @Test func aChoiceFadesAndIsForgottenAfterAboutTenWeeks() {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let habits = Habits(file: root.appendingPathComponent("habits.json"))
        let then = Date()
        let chosen = destination(page("https://c.test/"))
        habits.learn("handlers", chose: chosen, now: then)
        let month = habits.lifts(for: "handlers", now: then.addingTimeInterval(30 * day))[chosen] ?? 0
        #expect(abs(month - Habits.step / M_E) < 0.001)
        #expect(habits.lifts(for: "handlers", now: then.addingTimeInterval(60 * day))[chosen] != nil)
        #expect(habits.lifts(for: "handlers", now: then.addingTimeInterval(70 * day)).isEmpty)
        // A choice long after starts again from one, not from what faded.
        habits.learn("handlers", chose: chosen, now: then.addingTimeInterval(365 * day))
        #expect(habits.lifts(for: "handlers", now: then.addingTimeInterval(365 * day))[chosen] == Habits.step)
    }

    @Test func placesAndQueriesStayWithinTheirBoundsTheSameWayEveryTime() {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let habits = Habits(file: root.appendingPathComponent("habits.json"))
        let now = Date()
        let places = (0..<5).map { destination(page("https://p\($0).test/")) }
        // p0 five times (5), then p1…p4 once each, each halving the others:
        // p0 0.3125, p1 0.125, p2 0.25, p3 0.5, p4 1. Five places, four kept.
        for _ in 0..<5 { habits.learn("handlers", chose: places[0], now: now) }
        for place in places.dropFirst() { habits.learn("handlers", chose: place, now: now) }
        let kept = habits.lifts(for: "handlers", now: now)
        #expect(Set(kept.keys) == [places[0], places[2], places[3], places[4]])
        #expect(kept[places[4]] == Habits.step)
        // Halving lets go of what no longer counts: p0 0.078, p2 0.0625.
        for _ in 0..<2 { habits.learn("handlers", chose: places[4], now: now) }
        #expect(Set(habits.lifts(for: "handlers", now: now).keys) == [places[3], places[4]])

        let before = habits.lifts(for: "handlers", now: now)
        habits.learn("handlers", chose: "page:" + String(repeating: "p", count: Habits.longestPlace), now: now)
        habits.learn(String(repeating: "q", count: Habits.longestQuery + 1), chose: places[0], now: now)
        #expect(habits.lifts(for: "handlers", now: now) == before)
        #expect(habits.count == 1)

        // Past the bound, the weakest queries go first, then by their text;
        // the query just learned always stays. "handlers" (p4 at 3, fading
        // for a day) outlasts queries chosen once.
        let later = now.addingTimeInterval(day)
        for index in 0..<(Habits.queries + 10) {
            habits.learn("query \(String(format: "%03d", index))", chose: places[0], now: later)
        }
        #expect(habits.count == Habits.queries)
        #expect(!habits.lifts(for: "handlers", now: later).isEmpty)
        #expect((0...10).allSatisfy { habits.lifts(for: "query \(String(format: "%03d", $0))", now: later).isEmpty })
        #expect((11..<(Habits.queries + 10)).allSatisfy {
            habits.lifts(for: "query \(String(format: "%03d", $0))", now: later).count == 1
        })
    }

    @Test func vanishedBookmarksAndForgottenPagesAreLetGo() {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let habits = Habits(file: root.appendingPathComponent("habits.json"))
        let now = Date()
        let (gone, stays) = (UUID(), UUID())
        let visited = destination(page("http://localhost:3000/app"))
        habits.learn("project", chose: "bookmark:" + gone.uuidString, now: now)
        habits.learn("project", chose: visited, now: now)
        habits.learn("other", chose: "bookmark:" + gone.uuidString, now: now)
        habits.learn("project", chose: "bookmark:" + stays.uuidString, now: now) { place in
            Habits.bookmark(in: place) != gone
        }
        #expect(Set(habits.lifts(for: "project", now: now).keys) == ["bookmark:" + stays.uuidString, visited])
        #expect(habits.lifts(for: "other", now: now).isEmpty)

        habits.forget(visit: "localhost/app")
        #expect(Set(habits.lifts(for: "project", now: now).keys) == ["bookmark:" + stays.uuidString])
        habits.forget()
        #expect(habits.count == 0)
    }

    /// Every way a page leaves the history (the History panel, Clear
    /// History, an extension's chrome.history) goes through History.forget,
    /// which tells its owner; Browser forwards it to the Space's habits.
    @Test func theHistoryTellsWhatItForgets() {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = History(file: root.appendingPathComponent("history.json"))
        var told: [String?] = []
        history.forgotten = { told.append($0) }
        history.record(url("https://a.test/page"), title: "A")
        history.forget("a.test/page")
        history.forget()
        #expect(told == ["a.test/page", nil])
    }

    @Test func whatIsLearnedIsWrittenAndReadBack() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("habits.json")
        let habits = Habits(file: file)
        let now = Date()
        let chosen = destination(page("https://c.test/"))
        habits.learn("handlers", chose: chosen, now: now)
        habits.learn("handlers", chose: chosen, now: now)
        habits.flush()
        let again = Habits(file: file)
        #expect(again.lifts(for: "handlers", now: now) == habits.lifts(for: "handlers", now: now))

        again.forget()
        again.flush()
        #expect(Habits(file: file).count == 0)
    }

    @Test(arguments: [
        #"not json"#,
        #"[{"query":"Handlers","picks":[{"to":"page:a.test","count":1,"last":0}]}]"#,
        #"[{"query":"a","picks":[{"to":"page:a.test","count":1,"last":0}]},{"query":"a","picks":[{"to":"page:b.test","count":1,"last":0}]}]"#,
        #"[{"query":"a","picks":[{"to":"page:a.test","count":9,"last":0}]}]"#,
        #"[{"query":"a","picks":[{"to":"elsewhere","count":1,"last":0}]}]"#,
        #"[{"query":"a","picks":[{"to":"page:a.test","count":1,"last":0},{"to":"page:a.test","count":1,"last":0}]}]"#,
    ])
    func aFileThatIsNotHabitsIsSetAside(_ text: String) throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("habits.json")
        try Data(text.utf8).write(to: file)
        let habits = Habits(file: file)
        #expect(habits.count == 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let aside = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(aside.contains { $0.hasPrefix("habits.unreadable-") })
    }

    @Test func aFileOverTheBoundIsCutOnReading() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("habits.json")
        let last = Date().timeIntervalSinceReferenceDate
        let entries = (0..<(Habits.queries + 5)).map { index in
            ["query": "q\(index)",
             "picks": (0..<6).map { ["to": "page:p\($0).test", "count": 0.8 * Double(1 + $0), "last": last] }] as [String: Any]
        }
        try JSONSerialization.data(withJSONObject: entries).write(to: file)
        let habits = Habits(file: file)
        #expect(habits.count == Habits.queries)
        // Level queries go by their text: q0, q1, q10, q100, q101.
        #expect(habits.lifts(for: "q0").isEmpty)
        #expect(habits.lifts(for: "q101").isEmpty)
        let kept = habits.lifts(for: "q2")
        #expect(kept.count == Habits.places)
        #expect(kept["page:p0.test"] == nil)
        #expect(kept["page:p5.test"] == Habits.highest)
    }
}

@MainActor
@Suite struct HabitsRankingTests {
    /// Five pages holding `handlers`, most visited first, and the history
    /// behind a New Tab field, or ⌘L's.
    private func fixture(_ root: URL, newTab: Bool, bookmarks: [Bookmark] = []) -> (Field, Habits, [URL]) {
        let history = History(file: root.appendingPathComponent("history.json"))
        let now = Date()
        let pages = (0..<5).map { url("https://handlers\($0).test/") }
        for (index, place) in pages.enumerated() {
            history.take(place, title: "Handlers \(index)", count: 50 - index, last: now)
        }
        history.settle()
        let habits = Habits(file: root.appendingPathComponent("habits.json"))
        let field = Field(history: history, search: searching, engine: { "Synthetic" }, others: { [] },
                          newTab: { newTab }, bookmarks: { bookmarks }, habits: habits)
        return (field, habits, pages)
    }

    @Test func theRowTakenForHandlersLeadsTheNextHandlers() {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let (field, habits, pages) = fixture(root, newTab: true)
        field.typed = "handlers"
        #expect(field.offers.prefix(5).map(\.url) == pages)
        let before = field.offers
        let third = field.offers[2]
        habits.learn("handlers", chose: destination(third))

        field.typed = ""
        field.typed = "handlers"
        #expect(field.offers.first?.url == pages[2])
        // Nothing else moves, nothing is added, and the search stays last.
        #expect(field.offers.dropFirst().prefix(4).map(\.url) == [pages[0], pages[1], pages[3], pages[4]])
        #expect(field.offers.count == before.count)
        #expect(field.offers.last?.kind == .search)
        #expect(field.offers.last?.url == searching("handlers"))

        // Another query is not contaminated, even one that contains it.
        field.typed = "handlers1"
        #expect(field.offers.first?.url == pages[1])
        field.typed = "handler"
        #expect(field.offers.first?.url == pages[0])
    }

    @Test func theSameDataGivesTheSameListAndWalkingTeachesNothing() {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let (field, habits, _) = fixture(root, newTab: true)
        field.typed = "handlers"
        habits.learn("handlers", chose: destination(field.offers[3]))
        field.typed = "handlers "
        let first = field.offers.map(\.id)
        for _ in 0..<5 { field.walk(1) }
        field.walk(-1)
        field.typed = "handlers"
        #expect(field.offers.map(\.id) == first)
        #expect(habits.lifts(for: "handlers").count == 1)
        // A row picked keeps its identity when the list is asked again.
        field.walk(1)
        field.walk(1)
        let picked = field.selected?.id
        field.refresh()
        #expect(field.selected?.id == picked)
    }

    @Test func aLooserMatchChosenTwicePassesOneStepAndNoMore() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let exact = Bookmark.site("Orchestrator handlers", url("https://exact.test/"))
        let joined = Bookmark.site("iso--orchestrator-handlers", url("https://joined.test/"))
        let words = Bookmark.site("Handlers of the orchestrator", url("https://words.test/"))
        let history = History(file: root.appendingPathComponent("history.json"))
        let habits = Habits(file: root.appendingPathComponent("habits.json"))
        let field = Field(history: history, search: searching, engine: { "Synthetic" }, others: { [] },
                          newTab: { true }, bookmarks: { [words, joined, exact] }, habits: habits)
        let typed = "orchestrator handlers"
        field.typed = typed
        #expect(field.offers.compactMap(\.bookmark) == [exact.id, joined.id, words.id])

        let loose = try #require(field.offers.first { $0.bookmark == words.id })
        habits.learn(typed, chose: destination(loose))
        field.typed = ""
        field.typed = typed
        // One choice orders level rows only: a words match stays last.
        #expect(field.offers.compactMap(\.bookmark) == [exact.id, joined.id, words.id])
        for _ in 0..<5 { habits.learn(typed, chose: destination(loose)) }
        field.typed = ""
        field.typed = typed
        // Chosen again and again, it passes the joined words, never the query as typed.
        #expect(field.offers.compactMap(\.bookmark) == [exact.id, words.id, joined.id])
    }

    @Test func environmentsKeepTheirLeadOverASingleChoice() {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        var atlas = Bookmark.site("Handlers atlas", url("https://atlas.test/"))
        atlas.environments = [.init(name: "DEV", url: "https://dev.atlas.test")]
        let (field, habits, pages) = fixture(root, newTab: true, bookmarks: [atlas])
        field.typed = "handlers"
        #expect(field.offers.first?.bookmark == atlas.id)
        habits.learn("handlers", chose: destination(page(pages[4].absoluteString)))
        field.typed = ""
        field.typed = "handlers"
        #expect(field.offers.first?.bookmark == atlas.id)
        #expect(field.offers[1].url == pages[4])
        // Its environments stay on its row.
        #expect(field.offers.first?.environments.map(\.name) == ["DEV"])
    }

    @Test func aLearnedPageIsKeptPastItsSourcesCut() {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = History(file: root.appendingPathComponent("history.json"))
        let now = Date()
        let pages = (0..<12).map { url("https://handlers\(String(format: "%02d", $0)).test/") }
        for (index, place) in pages.enumerated() {
            history.take(place, title: "", count: 100 - index, last: now)
        }
        history.settle()
        let habits = Habits(file: root.appendingPathComponent("habits.json"))
        for newTab in [true, false] {
            let field = Field(history: history, search: searching, engine: { "Synthetic" }, others: { [] },
                              newTab: { newTab }, habits: habits)
            field.typed = "handlers"
            #expect(!field.offers.contains { $0.url == pages[11] })
            habits.learn("handlers", chose: destination(page(pages[11].absoluteString)))
            field.typed = ""
            field.typed = "handlers"
            #expect(field.offers.first?.url == pages[11])
            // The list keeps its length; the last of the others makes room.
            #expect(field.offers.filter { $0.kind == .visited }.count == (newTab ? Field.room : 3))
            habits.forget()
        }
        #expect(history.suggestions(for: "handlers", limit: 3).map(\.url) == Array(pages.prefix(3)))
        #expect(history.suggestions(for: "handlers", limit: 3, keeping: ["handlers11.test"]).map(\.url)
                == Array(pages.prefix(3)) + [pages[11]])
        #expect(history.suggestions(for: "handlers", limit: 3, keeping: ["handlers01.test", "elsewhere.test"]).map(\.url)
                == Array(pages.prefix(3)))
        #expect(history.suggestions(for: "nothing", limit: 3, keeping: ["handlers11.test"]).isEmpty)
    }

    @Test func aLearnedBookmarkIsKeptPastTheSavedFew() {
        let bookmarks = (0..<8).map { Bookmark.site("Handlers \($0)", url("https://b\($0).test/")) }
        let matches = SearchEnvironments.matches(bookmarks, query: "handlers", limit: 3, keeping: [bookmarks[7].id])
        #expect(matches.compactMap(\.bookmark) == bookmarks.prefix(3).map(\.id) + [bookmarks[7].id])
        #expect(SearchEnvironments.matches(bookmarks, query: "other", limit: 3, keeping: [bookmarks[7].id]).isEmpty)
        var environment = bookmarks[0]
        environment.environments = [.init(name: "DEV", url: "https://dev.test")]
        // An early bookmark pushed out by later environments is kept too.
        let pushed = [bookmarks[1]] + (2..<5).map { index -> Bookmark in
            var node = bookmarks[index]
            node.environments = environment.environments
            return node
        }
        #expect(SearchEnvironments.matches(pushed, query: "handlers", limit: 3, keeping: [bookmarks[1].id])
            .compactMap(\.bookmark) == [bookmarks[2].id, bookmarks[3].id, bookmarks[4].id, bookmarks[1].id])
    }

    @Test func aTypedAddressKeepsItsEndingWhateverWasLearned() {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = History(file: root.appendingPathComponent("history.json"))
        let now = Date()
        history.take(url("https://github.test/"), title: "GitHub", count: 40, last: now)
        history.take(url("https://github.test/escale/issues"), title: "Issues", count: 5, last: now)
        history.settle()
        let habits = Habits(file: root.appendingPathComponent("habits.json"))
        let field = Field(history: history, search: searching, engine: { "Synthetic" }, others: { [] }, habits: habits)
        field.typed = "github.test"
        #expect(field.ending == nil)
        #expect(field.completed == "github.test")
        field.typed = "git"
        #expect(field.ending == "hub.test")
        for typed in ["github.test", "git"] {
            for _ in 0..<3 { habits.learn(typed, chose: "page:github.test/escale/issues") }
        }
        field.typed = "github.test"
        #expect(field.offers.first?.key == "github.test/escale/issues")
        #expect(field.ending == nil)
        #expect(field.completed == "github.test")
        field.typed = "git"
        #expect(field.offers.first?.key == "github.test/escale/issues")
        #expect(field.ending == "hub.test")
    }

    @Test func theSwitcherOrdersItsOpenPagesTheSameWay() {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let habits = Habits(file: root.appendingPathComponent("habits.json"))
        let ordered = Field.ranked([page("https://a.test/"), page("https://b.test/"), page("https://c.test/")],
                                   environments: false,
                                   lifts: habits.lifts(for: "x"))
        #expect(ordered.map(\.url.host) == ["a.test", "b.test", "c.test"])
        habits.learn("x", chose: "page:c.test")
        let lifted = Field.ranked([page("https://a.test/"), page("https://b.test/"), page("https://c.test/")],
                                  environments: false, lifts: habits.lifts(for: "x"))
        #expect(lifted.map(\.url.host) == ["c.test", "a.test", "b.test"])
    }
}
