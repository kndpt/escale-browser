import Foundation
import Testing
@testable import Escale

// The address field's own rules (see Field.swift): what it offers for what
// is typed, the ending it draws, the row the arrow keys walk to and ⌘K's
// switcher. A history on a file of the test's own; searches go to a
// synthetic engine and nothing is fetched. No Browser, no preferences, no tab.

/// A folder of the test's own, removed afterwards.
private func folder() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("escale-field-\(UUID().uuidString)", isDirectory: true)
}

/// Words as the synthetic engine would search them; nil for none.
private func searching(_ words: String) -> URL? {
    let trimmed = words.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    return URL(string: "https://search.example.test/?q=\(trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")")
}

/// A field over a history holding two places, the first visited most, and
/// no tab open but the one on screen.
@MainActor
private func field(in root: URL) -> Field {
    let history = History(file: root.appendingPathComponent("history.json"))
    let now = Date()
    for (host, count) in [("fieldalpha.example.test", 50), ("fieldbeta.example.test", 40)] {
        guard let url = URL(string: "https://\(host)/") else { continue }
        history.take(url, title: host, count: count, last: now)
    }
    history.settle()
    return Field(history: history, search: searching, engine: { "Synthetic" }, others: { [] })
}

@MainActor
@Suite struct FieldTests {
    @Test func typingOffersTheMostVisitedPlaceAndDrawsItsEnding() {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let field = field(in: root)

        field.typed = "fieldal"

        #expect(field.offers.first?.key == "fieldalpha.example.test")
        #expect(field.ending == "pha.example.test")
        #expect(field.completed == "fieldalpha.example.test")
        #expect(field.picked == nil)
    }

    @Test func wordsThatAreNoPlaceEndWithASearchAndAnAddressDoesNot() {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let field = field(in: root)

        field.typed = "field notes"
        #expect(field.offers.last?.kind == .search)
        #expect(field.offers.last?.title == "Synthetic")
        #expect(field.offers.last?.url == searching("field notes"))

        field.typed = "example.test/docs"
        #expect(!field.offers.contains { $0.kind == .search })
    }

    @Test func aBlankFieldOffersNothing() {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let field = field(in: root)

        field.typed = "field"
        field.typed = "   "

        #expect(field.offers.isEmpty)
        #expect(field.ending == nil)
        #expect(field.picked == nil)
    }

    @Test func theArrowKeysWalkTheListAndWalkOffEitherEnd() {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let field = field(in: root)
        field.typed = "field"
        let rows = field.offers.count
        #expect(rows >= 2)

        field.walk(1)
        #expect(field.picked == 0)
        #expect(field.completed == field.offers[0].url.absoluteString)
        for _ in 1..<rows { field.walk(1) }
        #expect(field.picked == rows - 1)
        field.walk(1)
        #expect(field.picked == nil)

        field.walk(-1)
        #expect(field.picked == rows - 1)
        for _ in 1..<rows { field.walk(-1) }
        field.walk(-1)
        #expect(field.picked == nil)
    }

    @Test func aNewKeyLetsGoOfThePickedRow() {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let field = field(in: root)
        field.typed = "field"
        field.walk(1)

        field.typed = "fieldb"

        #expect(field.picked == nil)
        #expect(field.offers.first?.key == "fieldbeta.example.test")
    }

    @Test func nothingToWalkWithNothingOffered() {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let field = field(in: root)

        field.walk(1)
        field.walk(-1)

        #expect(field.picked == nil)
    }

    @Test func walkingNewTabShowsEachRowsAddressAndGivesTheTypingBack() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try #require(URL(string: "https://project.example.test/releases?page=2"))
        let field = Field(history: History(file: root.appendingPathComponent("history.json")),
                          search: searching, engine: { "Synthetic" }, others: { [] },
                          newTab: { true }, bookmarks: { [Bookmark.site("Project", url)] })
        field.typed = "project"
        #expect(field.offers.map(\.kind) == [.bookmark, .search])

        field.walk(1)
        // The address, not the bookmark's title.
        #expect(field.completed == url.absoluteString)
        field.walk(1)
        #expect(field.completed == "project")
        field.walk(-1)
        field.walk(-1)
        #expect(field.picked == nil)
        #expect(field.completed == "project")
    }

    @Test func walkingOntoADataAddressShowsItsTitle() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try #require(URL(string: "data:text/html,<p>project</p>"))
        let field = Field(history: History(file: root.appendingPathComponent("history.json")),
                          search: searching, engine: { "Synthetic" }, others: { [] },
                          newTab: { true }, bookmarks: { [Bookmark.site("Project inline", url)] })
        field.typed = "project"
        field.walk(1)
        #expect(field.selected?.url == url)
        #expect(field.completed == "Project inline")
    }

    @Test func aBackspaceDropsTheEndingAndTabTakesIt() {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let field = field(in: root)

        field.typed = "fieldal"
        field.stopCompleting()
        #expect(field.ending == nil)
        #expect(field.completed == "fieldal")

        field.typed = "fieldal"
        field.acceptEnding()
        #expect(field.typed == "fieldalpha.example.test")
    }

    @Test func theSwitcherOffersOpenPagesOnlyAndGivesTheHistoryBack() {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let field = field(in: root)

        field.startSummoning()
        #expect(field.summoning)
        #expect(field.typed.isEmpty)
        field.typed = "field"
        // No other tab is open: nothing, not the history's places.
        #expect(field.offers.isEmpty)
        #expect(field.ending == nil)
        #expect(field.picked == nil)

        field.stopSummoning()
        field.typed = "fieldal"
        #expect(field.offers.first?.key == "fieldalpha.example.test")
    }

    @Test func aSecondCommandKWalksOneStep() {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let field = field(in: root)
        field.typed = "field"

        field.stepSummon()

        #expect(field.cycling)
        #expect(field.picked == 0)
    }

    @Test func refusalsAndFocusRequestsAreCounted() {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let field = field(in: root)

        field.refuse()
        field.askFocus()
        field.askFocus()

        #expect(field.refusals == 1)
        #expect(field.focusRequest == 2)
    }
}

@MainActor
@Suite struct NewTabSearchTests {
    @Test func matchingEnvironmentsRankBeforeTheSavedResultLimit() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try #require(URL(string: "https://project.example.test"))
        let ordinary = (0..<4).map { Bookmark.site("Project \($0)", url) }
        var first = Bookmark.site("Project environments", url)
        first.environments = [.init(name: "PREP", url: "https://prep.example.test")]
        var second = Bookmark.site("Another title", url)
        second.environments = [.init(name: "PROJECT", url: "https://other.example.test")]
        var unrelated = Bookmark.site("Unrelated", try #require(URL(string: "https://unrelated.test")))
        unrelated.environments = [.init(name: "DEV", url: "https://unrelated.test")]
        let roots = ordinary + [.folder("Nested", [first, unrelated, second])]
        let matches = SearchEnvironments.matches(roots, query: "project", limit: 3)
        #expect(matches.map(\.bookmark) == [first.id, second.id, ordinary[0].id])
        #expect(SearchEnvironments.matches(roots, query: "missing", limit: 3).isEmpty)
        #expect(SearchEnvironments.matches(roots, query: "", limit: 3).isEmpty)
        let field = Field(history: History(file: root.appendingPathComponent("history.json")),
                          search: searching, engine: { "Synthetic" }, others: { [] },
                          newTab: { true }, bookmarks: { roots })
        field.typed = "project"
        #expect(field.offers.prefix(2).map(\.bookmark) == [first.id, second.id])
        #expect(field.offers.last?.kind == .search)
    }

    @Test func bookmarkChoicesPreserveTheQueryAndHaveSeparateFocus() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try #require(URL(string: "https://project.example.test/"))
        var bookmark = Bookmark.site("Project", base)
        bookmark.environments = [BookmarkEnvironment(name: "Prod", url: base.absoluteString),
                                 BookmarkEnvironment(name: "Dev", url: "http://localhost:8000/app?dev=1#start")]
        let field = Field(history: History(file: root.appendingPathComponent("history.json")),
                          search: searching, engine: { "Synthetic" }, others: { [] },
                          newTab: { true }, bookmarks: { [bookmark] })
        field.typed = "project"
        #expect(field.offers.first?.bookmark == bookmark.id)
        #expect(field.focusEnvironments())
        #expect(field.environmentFocused)
        #expect(field.selectedEnvironment?.name == "PROD")
        field.moveEnvironment(1)
        #expect(field.selectedEnvironment?.name == "DEV")
        #expect(field.completed == "http://localhost:8000/app?dev=1#start")
        field.leaveEnvironments()
        #expect(!field.environmentFocused)
        #expect(field.selectedEnvironment?.name == "DEV")
        #expect(field.focusEnvironments())
        field.leaveEnvironments(cancel: true)
        #expect(field.selectedEnvironment == nil)
        #expect(field.picked == 0)
        field.focusEnvironments()
        field.moveEnvironment(-1)
        #expect(field.selectedEnvironment?.name == "DEV")
        // Walking onto the row rings its current environment without choosing it.
        field.picked = nil
        field.walk(1)
        #expect(field.environmentFocused)
        #expect(field.environmentIndex == 0)
        #expect(field.selectedEnvironment == nil)
        #expect(field.ringedEnvironment?.name == "PROD")
        field.moveEnvironment(1)
        #expect(field.selectedEnvironment?.name == "DEV")
        field.typed = "something else"
        #expect(field.selectedEnvironment == nil)
        #expect(!field.environmentFocused)
        #expect(field.picked == nil)
        #expect(!field.focusEnvironments())
        field.startSummoning()
        #expect(!field.showsEnvironments)
        #expect(!field.focusEnvironments())
    }

    @Test func nestedBookmarksAreBoundedAndSingleDestinationsNeedNoFocusStep() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try #require(URL(string: "https://project.example.test/"))
        var bookmark = Bookmark.site("Project", base)
        bookmark.environments = [BookmarkEnvironment(name: "Only", url: base.absoluteString)]
        let roots = [Bookmark.folder("Folder", (0..<20).map { _ in bookmark })]
        #expect(SearchEnvironments.matches(roots, query: "project", limit: 3).count == 3)
        #expect(SearchEnvironments.matches(roots, query: "  ", limit: 3).isEmpty)
        let field = Field(history: History(file: root.appendingPathComponent("history.json")),
                          search: searching, engine: { "Synthetic" }, others: { [] },
                          newTab: { true }, bookmarks: { [bookmark] })
        field.typed = "project"
        field.walk(1)
        #expect(!field.focusEnvironments())
        #expect(field.selected?.url == base)
        bookmark.environments = []
        field.refresh()
        #expect(!field.focusEnvironments())
        #expect(field.selected?.environments.isEmpty == true)
    }

    @Test func sameTitlesHaveDistinctIdentitiesAndRemovingABookmarkDropsSelection() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try #require(URL(string: "https://project.example.test/"))
        let one = Suggestion(key: "Same", title: "", url: url, kind: .open, tab: UUID())
        let two = Suggestion(key: "Same", title: "", url: url, kind: .open, tab: UUID())
        #expect(one.id != two.id)
        var roots = [Bookmark.site("Project", url)]
        let field = Field(history: History(file: root.appendingPathComponent("history.json")),
                          search: searching, engine: { "Synthetic" }, others: { [] },
                          newTab: { true }, bookmarks: { roots })
        field.typed = "project"
        field.walk(1)
        roots = []
        field.refresh()
        #expect(field.picked == nil)
        #expect(!field.offers.contains { $0.bookmark != nil })
    }
}

@MainActor
@Suite struct DeferredTabTests {
    @Test func openingIsTransientAndCarriesItsOwnPrivacyContext() {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let field = field(in: root)
        field.startOpening(shy: true)
        let first = field.opening
        #expect(first?.shy == true)
        field.typed = "unfinished address"
        #expect(field.opening == first)
        field.startOpening(shy: true)
        #expect(field.opening?.id != first?.id)
        #expect(field.typed.isEmpty)
        field.startSummoning()
        #expect(field.opening == nil)
        field.startOpening(shy: false)
        #expect(field.opening?.shy == false)
        field.stopOpening()
        #expect(field.opening == nil)
    }
}


@Suite struct SearchEnvironmentBadgeTests {
    @Test func activeBadgeRequiresALinkAndAnUnambiguousDestination() throws {
        let url = try #require(URL(string: "https://project.example.test/dev?mode=1"))
        let dev = BookmarkEnvironment(name: "Dev", url: url.absoluteString, colour: .blue)
        var offer = Suggestion(key: "Project", title: "", url: url, kind: .open,
                               tab: UUID(), bookmark: UUID(), environments: [dev])
        #expect(offer.activeEnvironment == dev)
        offer.bookmark = nil
        #expect(offer.activeEnvironment == nil)
        offer.bookmark = UUID()
        offer.environments = [BookmarkEnvironment(name: "Dev", url: "https://project.example.test/dev")]
        #expect(offer.activeEnvironment == offer.environments.first)
        offer.environments = [dev, dev]
        #expect(offer.activeEnvironment == nil)
        offer.environments = [dev]
        offer.tab = nil
        #expect(offer.activeEnvironment == nil)
    }
}

@MainActor
@Suite struct NewTabWordsTests {
    /// The reported case: words typed with a space find a bookmark named with
    /// dashes, the contiguous match stays first, and the web search keeps the
    /// original text.
    @Test func wordsFindBookmarksAndKeepTheSearchAsTyped() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = Bookmark.site("iso--checkout--orchestrator-handlers",
                                       try #require(URL(string: "https://github.test/acme/iso--checkout--orchestrator-handlers")))
        let loose = Bookmark.site("Handlers of the orchestrator", try #require(URL(string: "https://wiki.test/handlers")))
        let exact = Bookmark.site("Orchestrator handlers", try #require(URL(string: "https://exact.test/")))
        let other = Bookmark.site("Orchestrator gateway", try #require(URL(string: "https://gateway.test/")))
        let roots = [loose, other, .folder("Work", [repository]), exact]

        #expect(SearchEnvironments.matches(roots, query: "orchestrator handlers", limit: 3).map(\.bookmark)
                == [exact.id, repository.id, loose.id])
        #expect(SearchEnvironments.matches(roots, query: "orchestrator-handlers", limit: 3).map(\.bookmark)
                == [repository.id, exact.id, loose.id])
        #expect(SearchEnvironments.matches(roots, query: "ORCHESTRATOR   hand", limit: 3).map(\.bookmark)
                == [exact.id, repository.id, loose.id])
        #expect(SearchEnvironments.matches(roots, query: "orchestrator nothing", limit: 3).isEmpty)

        let history = History(file: root.appendingPathComponent("history.json"))
        history.take(try #require(URL(string: "https://visited.test/orchestrator/handlers")),
                     title: "Visited", count: 80, last: Date())
        history.settle()
        let field = Field(history: history, search: searching, engine: { "Synthetic" }, others: { [] },
                          newTab: { true }, bookmarks: { [loose, repository] })
        let typed = "orchestrator  handlers"
        field.typed = typed
        // The joined bookmark and page lead the bookmark that only shares words.
        #expect(field.offers.map(\.url.host) == ["github.test", "visited.test", "wiki.test", "search.example.test"])
        #expect(field.offers.last?.kind == .search)
        #expect(field.offers.last?.key == typed)
        #expect(field.offers.last?.url == searching(typed))
        #expect(field.typed == typed)
    }

    /// Environments keep their lead; a words match does not hide one.
    @Test func environmentsAndClosenessBoundTheSavedFew() throws {
        let url = try #require(URL(string: "https://project.test/"))
        var environment = Bookmark.site("atlas_project_admin", url)
        environment.environments = [.init(name: "DEV", url: "https://dev.project.test")]
        let ordinary = (0..<5).map { Bookmark.site("Atlas project \($0)", url) }
        let roots = ordinary + [environment]
        let matches = SearchEnvironments.matches(roots, query: "atlas project", limit: 3)
        #expect(matches.map(\.bookmark) == [environment.id, ordinary[0].id, ordinary[1].id])
        #expect(matches.map(\.match) == [.joined, .typed, .typed])
    }

    /// Words shared between a bookmark and its environments, and between a
    /// page's title and address, as in the Swagger report.
    @Test func wordsSpreadAcrossTitlesAddressesAndEnvironments() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        var atlas = Bookmark.site("Project Atlas", try #require(URL(string: "https://atlas.test/")))
        atlas.environments = [.init(name: "DEV", url: "https://dev.atlas.test")]
        let swagger = Bookmark.site("Swagger UI",
                                    try #require(URL(string: "https://reception-orchestrator-handlers.priv.example.test/api")))
        #expect(SearchEnvironments.matches([atlas, swagger], query: "atlas dev", limit: 3).map(\.bookmark) == [atlas.id])
        #expect(SearchEnvironments.matches([atlas, swagger], query: "orchestrator handlers swa", limit: 3).map(\.bookmark) == [swagger.id])

        let history = History(file: root.appendingPathComponent("history.json"))
        history.take(try #require(URL(string: "https://reception-orchestrator-handlers.priv.example.test/api")),
                     title: "Swagger UI", count: 1, last: Date())
        history.settle()
        #expect(history.suggestions(for: "orchestrator handlers swa").map(\.key)
                == ["reception-orchestrator-handlers.priv.example.test/api"])
        let field = Field(history: history, search: searching, engine: { "Synthetic" }, others: { [] },
                          newTab: { true }, bookmarks: { [] })
        field.typed = "orchestrator handlers swa"
        #expect(field.offers.map(\.kind) == [.visited, .search])
    }

    /// Three earlier bookmarks that only share the words fill the list, and a
    /// later exact one still takes the lead.
    @Test func aLaterExactBookmarkOutranksEarlierWords() throws {
        let url = try #require(URL(string: "https://project.test/"))
        let loose = (0..<3).map { Bookmark.site("Handlers of the orchestrator \($0)", url) }
        let exact = Bookmark.site("Orchestrator handlers", url)
        let matches = SearchEnvironments.matches(loose + [exact], query: "orchestrator handlers", limit: 3)
        #expect(matches.map(\.bookmark) == [exact.id, loose[0].id, loose[1].id])
        var environment = Bookmark.site("Orchestrator handlers admin", url)
        environment.environments = [.init(name: "DEV", url: "https://dev.project.test")]
        var weaker = (0..<3).map { Bookmark.site("Handlers, orchestrator \($0)", url) }
        for index in weaker.indices { weaker[index].environments = environment.environments }
        #expect(SearchEnvironments.matches(weaker + [environment], query: "orchestrator handlers", limit: 3).first?.bookmark
                == environment.id)
    }
}
