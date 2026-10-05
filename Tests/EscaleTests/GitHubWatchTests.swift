// The watch between a visible GitHub search and the data side, with a real
// private tab whose page is a local copy of GitHub's label markup loaded under
// a GitHub address: nothing is fetched, and no file or secret is written.

import Combine
import Foundation
import Testing
import WebKit
@testable import Escale

@MainActor
private final class Shown: ObservableObject {
    @Published var github: GitHubSearch?
}

@MainActor
@Suite struct GitHubWatchTests {
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(condition())
    }

    @Test func aRowWhosePageFinishesLoadingLaterIsStillRead() async throws {
        let space = UUID()
        let url = try #require(URL(string: "https://github.com/fixture/repo/pull/7"))
        let tab = Tab(shy: true, space: space)
        let destination = try #require(GitHubItem.Destination(url: url, title: "Fixture", source: .tab(tab.id), visitedAt: Date()))
        let item = try #require(GitHubItem(space: space, destination: destination))
        let github = GitHubSpaces(history: { _ in nil }, configuration: .init(clientID: "fixture"),
                                  secrets: { _ in GitHubTestSecrets() },
                                  file: { FileManager.default.temporaryDirectory.appendingPathComponent("github-watch-\($0).json") },
                                  http: GitHubHTTP { _ in throw GitHubFailure.offline })
        let memory = github.privateMemory(for: space)
        let search = GitHubSearch(space: space, shy: true, memory: memory, sources: { [.init(item)] }, active: { nil })
        let shown = Shown()
        shown.github = search
        GitHubWatch.start(search, ending: shown.$github, github: github, tabs: { [tab] })

        // Bearings opens while the page is still loading: nothing can be read yet.
        tab.web.loadHTMLString(#"<span class="prc-StateLabel-StateLabel-x" data-status="pullMerged">Merged</span>"#, baseURL: url)
        search.ask("")
        #expect(memory.reading(item.id).observation == nil)

        // The load ends; the search publishes the same rows again.
        await settle { tab.built?.isLoading == false }
        search.refresh()
        await settle { memory.reading(item.id).observation != nil }
        #expect(memory.reading(item.id).observation?.state == .merged)
        #expect(search.results.map(\.id) == [item.id])

        // Closing the search drops the private cache.
        shown.github = nil
        #expect(memory.count == 0)
        tab.close()
    }

    @Test func theFirstSearchAfterLaunchIsRefreshedOnceTheConnectionIsRestored() async throws {
        let space = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("github-watch-restore-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { Writer.flushAll(); try? FileManager.default.removeItem(at: root) }
        let url = try #require(URL(string: "https://github.com/fixture/repo/pull/7"))
        let history = History(file: root.appendingPathComponent("history.json"))
        history.record(url, title: "Fixture")
        let destination = try #require(GitHubItem.Destination(url: url, title: "Fixture", source: .history, visitedAt: Date()))
        let item = try #require(GitHubItem(space: space, destination: destination))
        let secrets = GitHubTestSecrets()
        secrets.value = githubCredential(at: Date())
        var calls: [URLRequest] = []
        let github = GitHubSpaces(history: { $0 == space ? history : nil }, configuration: .init(clientID: "fixture"),
                                  secrets: { _ in secrets }, file: { root.appendingPathComponent("github-\($0).json") },
                                  http: GitHubHTTP { request in
                                      calls.append(request)
                                      return githubReply(#"{"number":7,"state":"closed","draft":false,"merged":true}"#)
                                  })
        // Opening the mode makes the Space's owners; the keychain read is still under way.
        let owner = github.owner(for: space)
        #expect(owner.access.connection == .local)
        let search = GitHubSearch(space: space, shy: false, memory: owner.memory, sources: { [.init(item)] }, active: { nil })
        let shown = Shown()
        shown.github = search
        GitHubWatch.start(search, ending: shown.$github, github: github, tabs: { [] })
        search.ask("")
        #expect(search.results.map(\.id) == [item.id])

        // No key is pressed: the restored connection alone asks about the row on screen.
        await settle { owner.memory.reading(item.id).observation != nil }
        #expect(owner.memory.reading(item.id).observation?.state == .merged)
        #expect(calls.count == 1)
        shown.github = nil
    }
}
