import Combine
import Foundation
import Testing
@testable import Escale

// The history's bound and its suggestions, on a file of the test's own. The
// places are synthetic hosts under .test; nothing is read from a browser.

/// A folder of the test's own, removed afterwards.
private func folder() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("escale-history-\(UUID().uuidString)", isDirectory: true)
}

private func site(_ i: Int) -> URL {
    URL(string: "https://site\(i).example.test/") ?? URL(fileURLWithPath: "/")
}

/// `n` places as an import brings them, each a minute older than the one
/// before, so the most recent are the ones worth keeping.
@MainActor
private func imported(_ n: Int, into history: History, count: Int = 1, from now: Date = Date()) {
    for i in 0..<n {
        history.take(site(i), title: "Site \(i)", count: count, last: now.addingTimeInterval(-60 * Double(i)))
    }
    history.settle()
}

/// The keys in the history file, once everything waiting has been written.
@MainActor
private func onDisk(_ history: History, _ file: URL) throws -> Set<String> {
    history.flush()
    let list = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]] ?? []
    return Set(list.compactMap { $0["key"] as? String })
}

@MainActor
private func held(_ history: History) -> Set<String> {
    Set(history.everything().map(\.key))
}

// MARK: - the bound

@MainActor
@Test(arguments: [0, 1, History.room - 1, History.room, History.room + 1, 20_000])
func anImportLeavesAtMostTheRoomInMemoryAndOnDisk(_ n: Int) throws {
    let root = folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("history.json")
    let history = History(file: file)

    imported(n, into: history)

    let kept = min(n, History.room)
    #expect(history.count == kept)
    let saved = try onDisk(history, file)
    #expect(saved.count == kept)
    #expect(saved == held(history))
    if n > 0 { #expect(saved.contains("site0.example.test")) }
    // What went is what was visited longest ago.
    if n > History.room {
        #expect(!saved.contains("site\(n - 1).example.test"))
        #expect(saved.contains("site\(History.room - 1).example.test"))
    }
}

@MainActor
@Test func visitsPastTheRoomKeepTheCountAndThePageJustOpened() throws {
    let root = folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("history.json")
    let history = History(file: file)
    // Places visited often and lately: each outranks a page seen once, so
    // only sparing the page just opened keeps it.
    imported(History.room, into: history, count: 50)

    for i in 0..<300 {
        guard let url = URL(string: "https://new\(i).example.test/docs/page") else { continue }
        history.record(url, title: "New \(i)")
        #expect(history.count == History.room)
        #expect(history.suggestions(for: "new\(i).example.test/docs").map(\.key) == ["new\(i).example.test/docs/page"])
        #expect(history.suggestions(for: "new\(i).example").first?.key == "new\(i).example.test")
    }
    #expect(try onDisk(history, file).count == History.room)
}

@MainActor
@Test func aFileOverTheRoomIsReadBackWithinIt() throws {
    let root = folder()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("history.json")
    let now = Date().timeIntervalSinceReferenceDate
    let list: [[String: Any]] = (0..<3_000).map { i in
        ["url": site(i).absoluteString, "key": "site\(i).example.test", "title": "Site \(i)",
         "count": 1, "last": now - 60 * Double(i)]
    }
    try JSONSerialization.data(withJSONObject: list).write(to: file)

    let history = History(file: file)

    #expect(history.count == History.room)
    #expect(held(history).contains("site0.example.test"))
    #expect(!held(history).contains("site2999.example.test"))
    #expect(try onDisk(history, file) == held(history))
}

// MARK: - forgetting and importing

@MainActor
@Test func forgettingAPlaceOrEverythingReachesTheFile() throws {
    let root = folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("history.json")
    let history = History(file: file)
    imported(10, into: history)

    history.forget("site3.example.test")
    #expect(history.count == 9)
    #expect(try !onDisk(history, file).contains("site3.example.test"))

    history.forget()
    #expect(history.count == 0)
    #expect(try onDisk(history, file).isEmpty)
    #expect(History(file: file).count == 0)
}

@MainActor
@Test func anImportAddsToWhatWasAlreadyThere() throws {
    let root = folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = History(file: root.appendingPathComponent("history.json"))
    let then = Date(timeIntervalSinceNow: -86_400)
    guard let url = URL(string: "https://docs.example.test/guide") else { return }

    history.record(url, title: "")
    history.take(url, title: "Guide", count: 4, last: then)
    history.settle()

    let trace = history.everything().first { $0.key == "docs.example.test/guide" }
    #expect(trace?.count == 5)
    // The title was missing and the import had one; the visit is the latest.
    #expect(trace?.title == "Guide")
    #expect((trace?.last ?? then) > then)
}

// MARK: - suggestions

/// A place and how it was visited, for ranking fixtures.
struct Seen: Sendable, CustomTestStringConvertible {
    let url: String
    let count: Int
    let daysAgo: Double

    var testDescription: String { "\(url)×\(count)" }
}

private let fixed = Date()

@MainActor
private func history(of places: [Seen], in root: URL) -> History {
    let history = History(file: root.appendingPathComponent("history.json"))
    for place in places {
        guard let url = URL(string: place.url) else { continue }
        history.take(url, title: "", count: place.count, last: fixed.addingTimeInterval(-86_400 * place.daysAgo))
    }
    history.settle()
    return history
}

struct Ranking: Sendable, CustomTestStringConvertible {
    let why: String
    let places: [Seen]
    let typed: String
    let expected: [String]

    var testDescription: String { why }
}

@MainActor
@Test(arguments: [
    Ranking(why: "the start of the address before the middle of a host",
            places: [Seen(url: "https://myhub.test/", count: 1, daysAgo: 0), Seen(url: "https://hubspot.test/", count: 1, daysAgo: 0)],
            typed: "hub", expected: ["hubspot.test", "myhub.test", "github.com"]),
    Ranking(why: "a name after the first dot, as with github.com",
            places: [Seen(url: "https://git.hubbub.test/", count: 1, daysAgo: 0)],
            typed: "hubbub", expected: ["git.hubbub.test"]),
    Ranking(why: "the front door before a room inside it",
            places: [Seen(url: "https://example.test/", count: 1, daysAgo: 0), Seen(url: "https://example.test/docs", count: 1, daysAgo: 0)],
            typed: "exa", expected: ["example.test", "example.test/docs"]),
    Ranking(why: "often and lately before once and long ago",
            places: [Seen(url: "https://qa.test/", count: 1, daysAgo: 90), Seen(url: "https://qb.test/", count: 8, daysAgo: 1)],
            typed: "q", expected: ["qb.test", "qa.test"]),
    Ranking(why: "somewhere visited before a well-known name",
            places: [Seen(url: "https://gitea.test/", count: 1, daysAgo: 200)],
            typed: "git", expected: ["gitea.test", "github.com"]),
    Ranking(why: "a well-known name once visited counts as visited",
            places: [Seen(url: "https://github.com/", count: 1, daysAgo: 0)],
            typed: "github", expected: ["github.com"]),
    Ranking(why: "equal places: the shorter, then the alphabet",
            places: [Seen(url: "https://zz.test/", count: 2, daysAgo: 1), Seen(url: "https://zzz.test/", count: 2, daysAgo: 1),
                     Seen(url: "https://zy.test/", count: 2, daysAgo: 1)],
            typed: "z", expected: ["zy.test", "zz.test", "zzz.test"]),
    Ranking(why: "a meaningful term in the path",
            places: [Seen(url: "https://example.test/blog", count: 3, daysAgo: 0)],
            typed: "blog", expected: ["example.test/blog"]),
    Ranking(why: "one letter matches only the start",
            places: [Seen(url: "https://netflix.test/", count: 3, daysAgo: 0)],
            typed: "x", expected: ["x.com"]),
    Ranking(why: "an empty field proposes nothing",
            places: [Seen(url: "https://example.test/", count: 3, daysAgo: 0)],
            typed: "  ", expected: []),
])
func suggestionsRankAsTheFieldExpects(_ ranking: Ranking) {
    let root = folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = history(of: ranking.places, in: root)
    #expect(history.suggestions(for: ranking.typed, limit: 5).map(\.key) == ranking.expected)
}

/// The best few, kept as they come, are the head of the whole ranking.
@MainActor
@Test func aShortListIsTheHeadOfTheLongOne() {
    let root = folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let places = (0..<300).map { i in
        Seen(url: "https://project\(i % 97).example.test/" + (i % 3 == 0 ? "" : "page\(i)"),
             count: 1 + (i * 7) % 11, daysAgo: Double((i * 13) % 60))
    }
    let history = history(of: places, in: root)

    for typed in ["p", "project", "project4", "example", "ex"] {
        let all = history.suggestions(for: typed, limit: 1_000)
        #expect(all.count > 8)
        for limit in 0...8 {
            #expect(history.suggestions(for: typed, limit: limit) == Array(all.prefix(limit)))
        }
    }
}

/// Page names and repository paths survive closing the page; generic content
/// cannot displace a domain, and the bounded list has deterministic ordering.
@MainActor
@Test func historyFindsTitlesAndPaths() throws {
    let root = folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = History(file: root.appendingPathComponent("history.json"))
    history.take(try #require(URL(string: "https://github.test/kndpt/Escale/pulls")),
                 title: "Pull requests · Project Compass", count: 3, last: fixed)
    for term in ["compass", "CoMpA", "escale", "EsCaL"] {
        #expect(history.suggestions(for: term).first?.key == "github.test/kndpt/escale/pulls")
    }
    #expect(history.suggestions(for: "co").allSatisfy { $0.key != "github.test/kndpt/escale/pulls" })
    for i in 0..<20 {
        history.take(try #require(URL(string: "https://site\(i).test/compass")),
                     title: "Compass guide", count: 100 + i, last: fixed)
    }
    history.take(try #require(URL(string: "https://compass.test")), title: "Home", count: 1, last: fixed)
    let matches = history.suggestions(for: "compass")
    #expect(matches.count == 5)
    #expect(matches.first?.key == "compass.test")
    #expect(matches.dropFirst().first?.key == "site19.test/compass")
    #expect(history.suggestions(for: "compass", limit: 0).isEmpty)
    #expect(matches == Array(history.suggestions(for: "compass", limit: 100).prefix(5)))
    history.take(try #require(URL(string: "https://opaque.test/page?q=secretneedle#fragmentneedle")),
                 title: "Other page", count: 1, last: fixed)
    #expect(history.suggestions(for: "secretneedle").isEmpty)
    #expect(history.suggestions(for: "fragmentneedle").isEmpty)
    history.settle()
    history.flush()
    let reopened = History(file: root.appendingPathComponent("history.json"))
    #expect(reopened.suggestions(for: "escal").first?.key == "github.test/kndpt/escale/pulls")
}

/// Words typed with spaces find a page whose title or path joins them with
/// dashes or underscores, below every match as typed, and never through the
/// query string; every word is required.
@MainActor
@Test func historyFindsPagesByTheirWords() throws {
    let root = folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = History(file: root.appendingPathComponent("history.json"))
    history.take(try #require(URL(string: "https://github.test/acme/iso--checkout--orchestrator-handlers")),
                 title: "Repository", count: 1, last: fixed)
    history.take(try #require(URL(string: "https://docs.test/orchestrator_handlers")),
                 title: "Docs", count: 1, last: fixed)
    history.take(try #require(URL(string: "https://wiki.test/page")),
                 title: "Handlers for the Orchestrator", count: 50, last: fixed)
    history.take(try #require(URL(string: "https://notes.test/other?q=orchestrator-handlers")),
                 title: "Notes", count: 1, last: fixed)
    history.take(try #require(URL(string: "https://often.test/guide")),
                 title: "orchestrator handlers guide", count: 1, last: fixed.addingTimeInterval(-86_400 * 90))

    let found = history.suggestions(for: "Orchestrator   handlers", limit: 10)
    #expect(found.map(\.key) == [
        "often.test/guide",
        "docs.test/orchestrator_handlers",
        "github.test/acme/iso--checkout--orchestrator-handlers",
        "wiki.test/page",
    ])
    #expect(found.map(\.match) == [.typed, .joined, .joined, .words])
    #expect(history.suggestions(for: "orchestrator hand").count == 4)
    #expect(history.suggestions(for: "orchestrator gateway").isEmpty)
    #expect(history.suggestions(for: "checkout handlers").map(\.key) == ["github.test/acme/iso--checkout--orchestrator-handlers"])
}

/// Pasted line breaks alone are an empty query, not a match for every page.
@MainActor
@Test func lineBreaksAloneProposeNothing() throws {
    let root = folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = History(file: root.appendingPathComponent("history.json"))
    history.take(try #require(URL(string: "https://example.test/page")), title: "Page", count: 3, last: fixed)
    for typed in ["\n\n\n", " \n\t\n "] {
        #expect(history.suggestions(for: typed).isEmpty)
    }
}

@MainActor
@Test func aPageIsAskedForItsLastVisitByItsAddress() throws {
    let root = folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = History(file: root.appendingPathComponent("history.json"))
    let then = Date(timeIntervalSince1970: 1_000_000)
    history.take(try #require(URL(string: "https://www.docs.example.test/guide")), title: "Guide", count: 1, last: then)

    #expect(history.last(try #require(URL(string: "https://docs.example.test/guide"))) == then)
    #expect(history.last(try #require(URL(string: "https://docs.example.test/other"))) == nil)
}

// MARK: - titles

@MainActor
@Test func aTitleIsTakenWhileThePageNamesItselfThenLeftAlone() throws {
    let root = folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("history.json")
    let history = History(file: file)
    let url = try #require(URL(string: "https://mail.example.test/inbox"))
    history.record(url, title: "")
    let visited = try #require(history.last(url))
    var changes = 0
    let watch = history.objectWillChange.sink { changes += 1 }
    defer { watch.cancel() }

    history.retitle(url, "Inbox", at: visited.addingTimeInterval(History.naming - 1))
    #expect(changes == 1)
    // An unread count ticking long after the page arrived: not a name.
    history.retitle(url, "(3) Inbox", at: visited.addingTimeInterval(History.naming))
    history.retitle(url, "(4) Inbox", at: visited.addingTimeInterval(600))
    #expect(changes == 1)
    #expect(history.everything().first { $0.key == "mail.example.test/inbox" }?.title == "Inbox")
    history.flush()
    #expect(History(file: file).everything().first { $0.key == "mail.example.test/inbox" }?.title == "Inbox")
}
