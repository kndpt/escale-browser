// Local retrieval and selection use value fixtures and explicit temporary
// files. No Browser singleton, WebKit view, defaults or real history is read.
import Foundation
import Testing
@testable import Escale

@MainActor
@Suite struct GitHubSearchTests {
    private let space = UUID()
    private let now = Date(timeIntervalSince1970: 10_000)

    private func candidate(_ number: Int, repo: String = "browser", tail: String = "", title: String = "Fix keyboard", source: GitHubItem.Source = .history, count: Int = 1, time: Date? = nil, space: UUID? = nil, recent: Bool = false) throws -> GitHubSearch.Candidate {
        let url = try #require(URL(string: "https://github.com/fixture/\(repo)/pull/\(number)\(tail)"))
        let destination = try #require(GitHubItem.Destination(url: url, title: title, source: source, visitedAt: time ?? now))
        return .init(try #require(GitHubItem(space: space ?? self.space, destination: destination)), count: count, recent: recent)
    }

    private func reading(_ state: GitHubState, at date: Date? = nil) -> GitHubReading {
        .init(observation: .init(state: state, source: .page, observedAt: date ?? now), failure: nil)
    }

    @Test func groupsBeforeCutAndMatchesAnOlderSubview() throws {
        var values = try (1...12).map { try candidate(1, tail: "/files#diff-\($0)", title: "File \($0)") }
        values += try (2...15).map { try candidate($0, title: $0 == 15 ? "Needle" : "Other") }
        let search = GitHubSearch(space: space, shy: false, sources: { values }, active: { nil })
        search.ask("")
        #expect(search.results.count == 6)
        #expect(Set(search.results.map(\.id)).count == 6)
        search.ask("needle")
        #expect(search.results.map(\.id.number) == [15])
        search.ask("File 12")
        #expect(search.results.map(\.id.number) == [1])
    }

    @Test func activeThenRecentTabWinsWithoutLosingSubview() throws {
        let active = UUID(), other = UUID()
        let values = try [candidate(1, tail: "/files#draft", source: .tab(active)),
                          candidate(1, tail: "/commits", source: .tab(other), time: now.addingTimeInterval(10)),
                          candidate(1, count: 100, time: now.addingTimeInterval(20))]
        let row = try #require(GitHubSearch.rank(values, typed: "", active: active).first)
        #expect(row.item.destination.source == .tab(active))
        #expect(row.item.destination.url.fragment == "draft")
        #expect(GitHubSearch.rank(values, typed: "", active: nil).first?.item.destination.source == .tab(other))
    }

    @Test func exactClosedWinsAndStatusesOnlyBreakTies() throws {
        let values = try [candidate(1, title: "browser #1"), candidate(2, title: "browser #1 discussion")]
        let read: (GitHubItem.ID) -> GitHubReading = { self.reading($0.number == 1 ? .merged : .open) }
        #expect(GitHubSearch.rank(values, typed: "browser #1", active: nil, now: now, reading: read).first?.id.number == 1)
        #expect(GitHubSearch.rank(values, typed: "browser", active: nil, now: now, reading: read).first?.id.number == 2)
        let learned = [GitHubSearch.destination(values[0].item.id): 0.6]
        #expect(GitHubSearch.rank(values, typed: "browser", active: nil, lifts: learned, now: now, reading: read).first?.id.number == 1)
        #expect(GitHubSearch.rank(values, typed: values[0].item.destination.url.absoluteString, active: nil, now: now, reading: read).first?.id.number == 1)
    }

    @Test func staleAndFailedObservationsAreNeutralAndDraftIsOpen() throws {
        let values = try [candidate(1), candidate(2), candidate(3)]
        let result = GitHubSearch.rank(values, typed: "", active: nil, now: now) { id in
            if id.number == 1 { return self.reading(.merged, at: self.now.addingTimeInterval(-301)) }
            if id.number == 2 { return self.reading(.draft) }
            return GitHubReading(observation: nil, failure: .offline)
        }
        #expect(result.map(\.id.number) == [2, 1, 3])
    }

    @Test func countsAndLearnedSubviewsAreNeverSummed() throws {
        let values = try [candidate(1, count: 3), candidate(1, tail: "/files", count: 3), candidate(2, count: 5)]
        #expect(GitHubSearch.rank(values, typed: "keyboard", active: nil, now: now).first?.id.number == 2)
        let lifts = [GitHubSearch.destination(values[0].item.id): 0.6,
                     GitHubSearch.destination(values[0].item.id) + "/files": 0.6,
                     GitHubSearch.destination(values[2].item.id): 0.7]
        #expect(GitHubSearch.rank(values, typed: "keyboard", active: nil, lifts: lifts, now: now).first?.id.number == 2)
    }

    @Test func replyChangesReadingWithoutMovingSelectionAndRemovalRevalidates() throws {
        var values = try [candidate(1, source: .tab(UUID())), candidate(2, source: .tab(UUID()))]
        let memory = GitHubMemory(space: space, isPrivate: true)
        memory.reconcile(history: [], visible: values.map { $0.item.id })
        let search = GitHubSearch(space: space, shy: true, memory: memory, sources: { values }, active: { nil })
        search.ask("")
        search.walk(1)
        let order = search.results.map(\.id), selected = search.picked
        let ticket = try #require(memory.request(values[0].item.id, api: false))
        #expect(memory.receive(.merged, at: Date(), for: ticket))
        #expect(search.results.map(\.id) == order)
        #expect(search.picked == selected)
        search.refresh()
        #expect(search.results.map(\.id) == order)
        #expect(search.picked == selected)
        values.removeLast()
        search.refresh()
        #expect(search.results.count == 1)
        #expect(search.picked == values.first?.item.id)
    }

    @Test func privateRejectsHistoryOtherSpacesAndLearning() throws {
        let values = try [candidate(1), candidate(2, source: .tab(UUID())), candidate(3, source: .tab(UUID()), space: UUID())]
        var reads = 0
        let search = GitHubSearch(space: space, shy: true, sources: { values }, active: { nil }, lifts: { _ in reads += 1; return [:] })
        search.ask("keyboard")
        #expect(search.results.map(\.id.number) == [2])
        #expect(reads == 0)
    }

    @Test func forgettingAnySubviewForgetsCanonicalLearning() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("github-habits-\(UUID()).json")
        let habits = Habits(file: file)
        defer { habits.flush(); try? FileManager.default.removeItem(at: file) }
        let first = try candidate(1), second = try candidate(1, repo: "another")
        habits.learn("keyboard", chose: GitHubSearch.destination(first.item.id))
        habits.learn("keyboard", chose: GitHubSearch.destination(second.item.id))
        habits.forget(visit: "github.com/fixture/browser/pull/1/files", space: space)
        #expect(habits.lifts(for: "keyboard")[GitHubSearch.destination(first.item.id)] == nil)
        #expect(habits.lifts(for: "keyboard")[GitHubSearch.destination(second.item.id)] != nil)
    }
    @Test func equalNumbersInDifferentRepositoriesStayDistinctAndDeterministic() throws {
        let values = try [candidate(12, repo: "zebra"), candidate(12, repo: "alpha")]
        let first = GitHubSearch.rank(values, typed: "12", active: nil, now: now).map(\.id)
        let reverse = GitHubSearch.rank(values.reversed(), typed: "12", active: nil, now: now).map(\.id)
        #expect(first == reverse)
        #expect(first.map(\.repository) == ["alpha", "zebra"])
    }

    @Test func fieldGitHubPathNeverReadsNormalSourcesAndReleasesItsSearch() throws {
        let values = try [candidate(1, source: .tab(UUID()))]
        var ordinaryReads = 0
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("github-field-\(UUID()).json")
        let history = History(file: file)
        let field = Field(history: { ordinaryReads += 1; return history }, search: { _ in nil },
                          engine: { "Fixture" }, others: { ordinaryReads += 1; return [] },
                          habits: { ordinaryReads += 1; return nil })
        weak var released: GitHubSearch?
        do {
            let search = GitHubSearch(space: space, shy: true, sources: { values }, active: { nil })
            released = search
            field.startGitHub(search, typed: "keyboard")
        }
        field.typed = "browser #1"
        #expect(field.completed == "browser #1")
        #expect(field.ending == nil)
        #expect(field.offers.isEmpty)
        #expect(ordinaryReads == 0)
        field.stopOpening()
        #expect(released == nil)
    }

    @Test func besideTabSearchEveryOpenTabLeads() throws {
        // Newer history would come first on its own; beside ⌘K, open tabs lead.
        let values = try [candidate(1, time: now.addingTimeInterval(50)),
                          candidate(2, source: .tab(UUID()), time: now),
                          candidate(3, source: .tab(UUID()), time: now.addingTimeInterval(10))]
        #expect(GitHubSearch.rank(values, typed: "", active: nil).map(\.id.number) == [1, 3, 2])
        #expect(GitHubSearch.rank(values, typed: "", active: nil, lead: .tabs).map(\.id.number) == [3, 2, 1])
    }

    @Test func besideNewTabThreeVisitedTabsLeadThenTiesGoToOpenTabs() throws {
        var values = try (1...4).map { try candidate($0, source: .tab(UUID()), time: now.addingTimeInterval(Double($0)), recent: true) }
        values.append(try candidate(5, source: .tab(UUID()), time: now.addingTimeInterval(9)))
        values.append(try candidate(6, time: now.addingTimeInterval(100)))
        let rows = GitHubSearch.rank(values, typed: "", active: nil, lead: .newTab).map(\.id.number)
        // The three most recently visited this session, then the rest as before.
        #expect(Array(rows.prefix(3)) == [4, 3, 2])
        #expect(rows.firstIndex(of: 6) ?? 0 < rows.firstIndex(of: 5) ?? 0)
        let typed = try [candidate(7, title: "Keyboard", time: now.addingTimeInterval(100)),
                         candidate(8, title: "Keyboard", source: .tab(UUID()), time: now)]
        #expect(GitHubSearch.rank(typed, typed: "keyboard", active: nil, lead: .newTab).first?.id.number == 8)
    }

    @Test func rowKeepsVisitedRepositorySpellingWhileGroupingIgnoresCase() throws {
        func visit(_ path: String, time: Date) throws -> GitHubSearch.Candidate {
            let url = try #require(URL(string: "https://github.com/\(path)/pull/7"))
            let destination = try #require(GitHubItem.Destination(url: url, title: "Zoom", source: .history, visitedAt: time))
            return .init(try #require(GitHubItem(space: space, destination: destination)))
        }
        let rows = GitHubSearch.rank(try [visit("webkit/webkit", time: now), visit("WebKit/WebKit", time: now.addingTimeInterval(1))],
                                     typed: "", active: nil)
        #expect(rows.count == 1)
        #expect(rows.first?.repository == "WebKit/WebKit")
        #expect(GitHubSearch.rank(try [visit("webkit/webkit", time: now)], typed: "WebKit #7", active: nil).first?.exact == true)
    }

    @Test func exactReferenceNobodyVisitedIsOffered() throws {
        let offer = try #require(GitHubSearch.offer(" Octo-Org/My.Repo_2#42 ", space: space))
        #expect(offer.url.absoluteString == "https://github.com/Octo-Org/My.Repo_2/issues/42")
        #expect(offer.name == "Octo-Org/My.Repo_2#42")
        #expect(offer.id.owner == "octo-org" && offer.id.repository == "my.repo_2" && offer.id.number == 42)
        #expect(GitHubSearch.offer("a/b#007", space: space)?.url.absoluteString == "https://github.com/a/b/issues/7")
    }

    @Test(arguments: ["octo/repo#0", "octo/repo#", "octo/repo", "octo repo#1", "octo/re po#1", "octo/repo #1",
                      "octo/re$po#1", "oc_to/repo#1", "-octo/repo#1", "octo/repo#1#2", "octo/repo/x#1",
                      "octo/repo#1a", "octo/repo#42?x", "octo/repo#42%20", "octo/repo#42/files", "octo/..#1", "octo/repo#99999999999999999999", "/repo#1", "octo/#1"])
    func invalidReferencesAreRefused(typed: String) {
        #expect(GitHubSearch.offer(typed, space: space) == nil)
    }

    @Test func knownReferenceStaysTheOnlyRowAndUnknownLeads() throws {
        let values = try [candidate(1), candidate(30, title: "fixture/browser#30 follow-up")]
        let search = GitHubSearch(space: space, shy: false, sources: { values }, active: { nil })
        search.ask("fixture/browser#1")
        #expect(search.offer == nil)
        #expect(search.results.first?.id.number == 1)
        #expect(search.picked == search.results.first?.id)
        search.ask("fixture/browser#3")
        let offer = try #require(search.offer)
        #expect(search.picked == offer.id)
        #expect(search.results.map(\.id.number) == [30])
        search.walk(1)
        #expect(search.picked == search.results.first?.id)
        search.walk(-1)
        #expect(search.picked == offer.id)
        let shy = GitHubSearch(space: space, shy: true, sources: { [] }, active: { nil })
        shy.ask("fixture/browser#3")
        #expect(shy.offer == nil)
    }
}
