// Controlled replies exercise the seam between local identity, authorization
// and enrichment. The local row array is deliberately outside the owner; a
// response can only update its observation, not replace its identity or order.

import Foundation
import Testing
@testable import Escale

@MainActor
@Suite struct GitHubRefreshTests {
    private func item(_ space: UUID, _ n: Int = 1, issue: Bool = false) throws -> GitHubItem.ID {
        let url = try #require(URL(string: "https://github.com/fixture/repo/\(issue ? "issues" : "pull")/\(n)"))
        return try #require(GitHubItem.ID(url: url, space: space))
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(condition())
    }

    @Test func delayedResponseChangesOnlyTheObservationAnd304RenewsIt() async throws {
        let space = UUID(), clock = GitHubTestClock(), secrets = GitHubTestSecrets()
        secrets.value = githubCredential(at: clock.date)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("github-refresh-\(UUID()).json")
        defer { Writer.to(file).flush(); try? FileManager.default.removeItem(at: file) }
        let memory = GitHubMemory(space: space, file: file)
        let access = GitHubAccess(space: space, configuration: .init(clientID: "fixture"), secrets: secrets, now: { clock.date })
        await access.restore()
        let id = try item(space)
        let rows = [id], selection = id
        var held: CheckedContinuation<GitHubReply, Never>?
        var calls: [URLRequest] = []
        let refresh = GitHubRefresh(memory: memory, access: access, http: GitHubHTTP { request in
            calls.append(request)
            if calls.count == 1 { return await withCheckedContinuation { held = $0 } }
            return githubReply("", status: 304)
        }, now: { clock.date }, pause: { _ in })
        refresh.update(history: rows, visible: rows)
        await settle { held != nil }
        #expect(memory.reading(id).observation == nil)
        #expect(rows == [selection])
        let reply = try #require(held)
        reply.resume(returning: githubReply(#"{"number":1,"state":"open","draft":true,"merged":false}"#, headers: ["etag":"fixture-etag"]))
        await settle { memory.reading(id).observation != nil }
        #expect(memory.reading(id).observation?.state == .draft)
        #expect(rows == [selection])
        let before = memory.reading(id).observation?.observedAt
        clock.date.addTimeInterval(301)
        refresh.update(history: rows, visible: rows, manual: true)
        await settle { memory.reading(id).observation?.observedAt != before }
        #expect(calls.count == 2)
        #expect(calls.last?.value(forHTTPHeaderField: "If-None-Match") == "fixture-etag")
        #expect(memory.reading(id).observation?.state == .draft)
        refresh.stop()
    }

    @Test func aRestartKeepsTheCacheWhenTheAuthorizationArrivesBeforeTheRead() async throws {
        let space = UUID(), clock = GitHubTestClock(), secrets = GitHubTestSecrets()
        let credential = githubCredential(at: clock.date)
        secrets.value = credential
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("github-refresh-\(UUID()).json")
        defer { Writer.to(file).flush(); try? FileManager.default.removeItem(at: file) }
        let id = try item(space)
        let seen = GitHubObservation(state: .merged, source: .api(credential.authority), observedAt: clock.date)
        try JSONEncoder().encode(GitHubDisk.Snapshot(entries: [GitHubDisk.Entry(item: id, observation: seen)], authority: credential.authority)).write(to: file)
        // Launch order: owners exist, the surface subscribes, then the keychain answers.
        let memory = GitHubMemory(space: space, file: file)
        memory.reconcile(history: [id], visible: [])
        let access = GitHubAccess(space: space, configuration: .init(clientID: "fixture"), secrets: secrets, now: { clock.date })
        let refresh = GitHubRefresh(memory: memory, access: access, http: GitHubHTTP { _ in throw GitHubFailure.offline },
                                    now: { clock.date }, pause: { _ in })
        await access.restore()
        Writer.to(file).flush()
        #expect(FileManager.default.fileExists(atPath: file.path))
        await withCheckedContinuation { continuation in memory.restore { _ in continuation.resume() } }
        #expect(memory.reading(id).observation == seen)
        refresh.stop()
    }

    @Test func staleRepliesAfterDismissAndQuotaNeverRepopulateRows() async throws {
        let space = UUID(), secrets = GitHubTestSecrets(), clock = GitHubTestClock()
        secrets.value = githubCredential(at: clock.date)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("github-stop-\(UUID()).json")
        defer { Writer.to(file).flush(); try? FileManager.default.removeItem(at: file) }
        let memory = GitHubMemory(space: space, file: file)
        let access = GitHubAccess(space: space, configuration: .init(clientID: "fixture"), secrets: secrets, now: { clock.date })
        await access.restore()
        let id = try item(space)
        var held: CheckedContinuation<GitHubReply, Never>?
        let refresh = GitHubRefresh(memory: memory, access: access, http: GitHubHTTP { _ in
            await withCheckedContinuation { held = $0 }
        }, now: { clock.date }, pause: { _ in })
        refresh.update(history: [id], visible: [id])
        await settle { held != nil }
        refresh.stop()
        let continuation = try #require(held)
        continuation.resume(returning: githubReply(#"{"number":1,"state":"closed","draft":false,"merged":true}"#))
        for _ in 0..<10 { await Task.yield() }
        #expect(memory.reading(id).observation == nil)
        #expect(memory.pendingCount == 0)
        var count = 0
        let limited = GitHubRefresh(memory: memory, access: access, http: GitHubHTTP { _ in
            count += 1
            return githubReply("", status: 429, headers: ["retry-after":"600"])
        }, now: { clock.date }, pause: { _ in })
        limited.update(history: [id], visible: [id])
        await settle { limited.failure == .rateLimited }
        #expect(memory.reading(id).failure == .rateLimited)
        limited.update(history: [id], visible: [id], manual: true)
        #expect(count == 1)
        #expect(limited.retryAt == clock.date.addingTimeInterval(600))
        limited.stop()
    }

    @Test func responseIdentityAndStateMustMatchTheRequestedObject() throws {
        let space = UUID(), pull = try item(space), issue = try item(space, issue: true)
        let closed = Data(#"{"number":1,"state":"closed","draft":false,"merged":false}"#.utf8)
        #expect(try GitHubRefresh.state(closed, for: pull) == .closed)
        #expect(try GitHubRefresh.state(closed, for: issue) == .closed)
        #expect(throws: GitHubFailure.self) { try GitHubRefresh.state(Data(#"{"number":2,"state":"open"}"#.utf8), for: issue) }
        #expect(throws: GitHubFailure.self) { try GitHubRefresh.state(Data(#"{"number":1,"state":"open","pull_request":{}}"#.utf8), for: issue) }
        #expect(throws: GitHubFailure.self) { try GitHubRefresh.state(Data("broken".utf8), for: pull) }
        #expect(throws: GitHubFailure.self) { try GitHubRefresh.state(Data(repeating: 0, count: GitHubHTTP.limit + 1), for: pull) }
    }
    @Test func forgettingHistoryInvalidatesTheWholeQueuedBatch() async throws {
        let space = UUID(), secrets = GitHubTestSecrets(), clock = GitHubTestClock()
        secrets.value = githubCredential(at: clock.date)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("github-forget-batch-\(UUID()).json")
        defer { Writer.to(file).flush(); try? FileManager.default.removeItem(at: file) }
        let memory = GitHubMemory(space: space, file: file)
        let access = GitHubAccess(space: space, configuration: .init(clientID: "fixture"), secrets: secrets, now: { clock.date })
        await access.restore()
        let ids = try [item(space, 1), item(space, 2)]
        var held: CheckedContinuation<GitHubReply, Never>?
        var calls = 0
        let refresh = GitHubRefresh(memory: memory, access: access, http: GitHubHTTP { _ in
            calls += 1
            return await withCheckedContinuation { held = $0 }
        }, now: { clock.date }, pause: { _ in })
        refresh.update(history: ids, visible: ids)
        await settle { held != nil }
        #expect(memory.pendingCount == 2)
        memory.forget()
        let response = try #require(held)
        response.resume(returning: githubReply(#"{"number":1,"state":"open","draft":false,"merged":false}"#))
        for _ in 0..<10 { await Task.yield() }
        #expect(calls == 1)
        #expect(memory.count == 0)
        #expect(memory.pendingCount == 0)
        refresh.stop()
    }

}
