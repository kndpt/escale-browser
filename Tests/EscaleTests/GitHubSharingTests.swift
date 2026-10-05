// A private repository not shared with the app answers 404 to a connected
// Space. These replies check what the person keeps meanwhile (the state a page
// showed), when Escale asks again (after sharing may have changed, or once the
// refusal is five minutes old) and what the list of shares accepts from GitHub.

import Foundation
import Testing
@testable import Escale

@MainActor
@Suite struct GitHubSharingTests {
    private func item(_ space: UUID) throws -> GitHubItem.ID {
        let url = try #require(URL(string: "https://github.com/fixture/private/pull/7"))
        return try #require(GitHubItem.ID(url: url, space: space))
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(condition())
    }

    @Test func aRefusedRowKeepsItsPageStateAndIsAskedAgainAfterSharingOrFiveMinutes() async throws {
        let space = UUID(), clock = GitHubTestClock(), secrets = GitHubTestSecrets()
        secrets.value = githubCredential(at: clock.date)
        let memory = GitHubMemory(space: space, file: FileManager.default.temporaryDirectory.appendingPathComponent("github-share-\(UUID()).json"))
        let access = GitHubAccess(space: space, configuration: .init(clientID: "fixture"), secrets: secrets, now: { clock.date })
        await access.restore()
        var calls = 0
        let refresh = GitHubRefresh(memory: memory, access: access, http: GitHubHTTP { _ in
            calls += 1
            return githubReply(#"{"message":"Not Found"}"#, status: 404)
        }, now: { clock.date }, pause: { _ in })
        let id = try item(space)
        memory.reconcile(history: [id], visible: [id])
        let page = try #require(memory.request(id, api: false))
        #expect(memory.receive(.merged, at: clock.date, for: page))

        // The page's state is old enough to ask GitHub, which refuses.
        clock.date.addTimeInterval(301)
        refresh.update(history: [id], visible: [id])
        await settle { memory.reading(id).failure == .notFound }
        #expect(calls == 1)
        #expect(memory.reading(id).observation?.state == .merged)
        #expect(memory.reading(id).observation?.source == .page)

        // Within five minutes the refusal stands, even on a new showing.
        clock.date.addTimeInterval(60)
        refresh.stop()
        refresh.update(history: [id], visible: [id])
        for _ in 0..<20 { await Task.yield() }
        #expect(calls == 1)

        // Sharing may have changed: the next showing asks again.
        memory.retryRefused()
        #expect(memory.reading(id).failure == nil)
        #expect(memory.reading(id).observation?.state == .merged)
        refresh.stop()
        refresh.update(history: [id], visible: [id])
        await settle { calls == 2 && memory.reading(id).failure == .notFound }

        // Or, without anything said, once the refusal is five minutes old.
        clock.date.addTimeInterval(301)
        refresh.stop()
        refresh.update(history: [id], visible: [id])
        await settle { calls == 3 }
        refresh.stop()
    }

    @Test func anAPIStateDoesNotOutliveARefusal() async throws {
        let space = UUID(), clock = GitHubTestClock(), secrets = GitHubTestSecrets()
        secrets.value = githubCredential(at: clock.date)
        let memory = GitHubMemory(space: space, file: FileManager.default.temporaryDirectory.appendingPathComponent("github-share-\(UUID()).json"))
        let access = GitHubAccess(space: space, configuration: .init(clientID: "fixture"), secrets: secrets, now: { clock.date })
        await access.restore()
        _ = GitHubRefresh(memory: memory, access: access, now: { clock.date }, pause: { _ in })
        let id = try item(space)
        memory.reconcile(history: [id], visible: [id])
        let api = try #require(memory.request(id, api: true))
        #expect(memory.receive(.open, at: clock.date, for: api))
        let again = try #require(memory.request(id, api: true))
        #expect(memory.fail(.notFound, for: again, at: clock.date))
        #expect(memory.reading(id).observation == nil)
        #expect(memory.reading(id).failedAt == clock.date)
    }

    @Test func sharesComeFromTheConnectedAccountAndReopenRefusedRows() async throws {
        let space = UUID(), clock = GitHubTestClock(), secrets = GitHubTestSecrets()
        secrets.value = githubCredential(at: clock.date)
        let memory = GitHubMemory(space: space, file: FileManager.default.temporaryDirectory.appendingPathComponent("github-share-\(UUID()).json"))
        let access = GitHubAccess(space: space, configuration: .init(clientID: "fixture"), secrets: secrets, now: { clock.date })
        await access.restore()
        _ = GitHubRefresh(memory: memory, access: access, now: { clock.date }, pause: { _ in })
        let id = try item(space)
        memory.reconcile(history: [id], visible: [id])
        let ticket = try #require(memory.request(id, api: true))
        #expect(memory.fail(.notFound, for: ticket, at: clock.date))

        var requests: [URLRequest] = []
        let shares = GitHubShares(memory: memory, access: access, http: GitHubHTTP { request in
            requests.append(request)
            return githubReply("""
            {"total_count":3,"installations":[
             {"id":1,"account":{"login":"kndpt"},"repository_selection":"all","html_url":"https://evil.example/settings/installations/1"},
             {"id":2,"account":{"login":"Acme"},"repository_selection":"selected","html_url":"https://github.com/organizations/Acme/settings/installations/2"},
             {"id":3,"account":null,"repository_selection":"all","html_url":"https://github.com/settings/installations/3"}]}
            """)
        })
        shares.load()
        await settle { shares.shares != nil }
        #expect(requests.first?.url?.absoluteString == "https://api.github.com/user/installations")
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture_access")
        #expect(shares.shares?.map(\.account) == ["Acme", "kndpt"])
        #expect(shares.shares?.map(\.all) == [false, true])
        #expect(shares.shares?.first?.page?.host == "github.com")
        #expect(shares.shares?.last?.page == nil)
        #expect(memory.reading(id).failure == nil)

        await access.disconnect()
        #expect(shares.shares == nil)
    }

    @Test func theSharingPageNeedsAValidAppName() {
        #expect(GitHubAccess.Configuration(clientID: "Iv23fixture", slug: "escale-browser").installURL?.absoluteString
                == "https://github.com/apps/escale-browser/installations/new")
        #expect(GitHubAccess.Configuration(clientID: "Iv23fixture").installURL == nil)
        #expect(GitHubAccess.Configuration(clientID: "Iv23fixture", slug: "../evil").installURL == nil)
        #expect(GitHubAccess.Configuration(clientID: "", slug: "escale-browser").installURL == nil)
    }
}
