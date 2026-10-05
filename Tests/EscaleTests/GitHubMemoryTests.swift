// Exercise the real derived cache and ordered Writer with temporary fixture
// files. These tests prove data boundaries, not Browser hooks or a live GitHub
// authorization. No secrets, personal history or network are involved.

import Foundation
import Testing
@testable import Escale

@MainActor
@Suite struct GitHubMemoryTests {
    private let space = UUID()
    private let account = GitHubAuthority(account: GitHubAccount(id: 1, login: "fixture"), generation: UUID())
    private let now = Date(timeIntervalSince1970: 1_000)

    private func item(_ number: Int = 1, space: UUID? = nil) throws -> GitHubItem.ID {
        let url = try #require(URL(string: "https://github.com/fixture/repo/pull/\(number)"))
        return try #require(GitHubItem.ID(url: url, space: space ?? self.space))
    }

    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("escale-github-\(UUID()).json")
    }

    private func restore(_ memory: GitHubMemory) async -> Bool {
        await withCheckedContinuation { continuation in memory.restore { continuation.resume(returning: $0) } }
    }

    @Test func latestRequestWinsAndCancellationRejectsHeldReplies() throws {
        let memory = GitHubMemory(space: space, isPrivate: true)
        let id = try item()
        memory.reconcile(history: [], visible: [id])
        var cancelled: [GitHubMemory.Ticket] = []
        memory.cancelled = { cancelled.append($0) }
        let first = try #require(memory.request(id, api: false))
        let second = try #require(memory.request(id, api: false))
        #expect(cancelled == [first])
        #expect(!memory.receive(.closed, at: now, for: first))
        #expect(memory.receive(.open, at: now, for: second))
        let third = try #require(memory.request(id, api: false))
        memory.cancel()
        #expect(!memory.receive(.merged, at: now, for: third))
        #expect(memory.reading(id).observation?.state == .open)
    }

    @Test func failedRefreshDoesNotRefreshDateAndAccessLossIsNotClosed() throws {
        let memory = GitHubMemory(space: space, isPrivate: true)
        let id = try item()
        memory.reconcile(history: [], visible: [id])
        #expect(memory.receive(.open, at: now, for: try #require(memory.request(id, api: false))))
        #expect(memory.fail(.offline, for: try #require(memory.request(id, api: false))))
        #expect(memory.reading(id).observation?.observedAt == now)
        #expect(memory.reading(id).failure == .offline)
        // A refusal is not closed, and what the page showed stays, without a current state.
        #expect(memory.fail(.notFound, for: try #require(memory.request(id, api: false))))
        #expect(memory.reading(id).observation?.state == .open)
        #expect(memory.reading(id).current(at: now) == nil)
        #expect(memory.reading(id).failure == .notFound)
        #expect(memory.fail(.unauthorized, for: try #require(memory.request(id, api: false))))
        #expect(memory.reading(id).observation == nil)
        #expect(memory.reading(id).failure == .unauthorized)
    }

    @Test func olderPageCannotOverwriteAPIAndEqualDatePrefersAPI() throws {
        let path = file()
        defer { Writer.to(path).flush(); try? FileManager.default.removeItem(at: path) }
        let memory = GitHubMemory(space: space, authority: account, file: path)
        let id = try item()
        memory.reconcile(history: [id], visible: [id])
        #expect(memory.receive(.merged, at: now, for: try #require(memory.request(id, api: true))))
        for time in [now.addingTimeInterval(-1), now] {
            #expect(!memory.receive(.open, at: time, for: try #require(memory.request(id, api: false))))
        }
        #expect(memory.reading(id).observation?.state == .merged)
        #expect(memory.receive(.closed, at: now.addingTimeInterval(1), for: try #require(memory.request(id, api: false))))
        memory.flush()
    }

    @Test func accountChangeForgetAndDeletionRejectLateResponses() throws {
        let path = file()
        defer { Writer.to(path).flush(); try? FileManager.default.removeItem(at: path) }
        let memory = GitHubMemory(space: space, authority: account, file: path)
        let id = try item()
        memory.reconcile(history: [id], visible: [id])
        let old = try #require(memory.request(id, api: true))
        memory.authorize(GitHubAuthority(account: account.account, generation: UUID()))
        #expect(!memory.receive(.open, at: now, for: old))
        let forgotten = try #require(memory.request(id, api: true))
        memory.forget(id)
        #expect(!memory.receive(.open, at: now, for: forgotten))
        #expect(memory.reading(id).observation == nil)
        let removed = try #require(memory.request(id, api: true))
        memory.erase()
        #expect(!memory.receive(.open, at: now, for: removed))
        memory.reconcile(history: [id], visible: [id])
        #expect(memory.request(id, api: true) == nil)
        memory.flush()
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test func privateContextHasNoDiskOrNormalAccountAccess() async throws {
        let path = file()
        let memory = GitHubMemory(space: space, isPrivate: true, authority: account, file: path)
        let id = try item()
        memory.reconcile(history: [id], visible: [id])
        memory.authorize(account)
        #expect(memory.request(id, api: true) == nil)
        #expect(memory.receive(.open, at: now, for: try #require(memory.request(id, api: false))))
        #expect(memory.persistentCount == 0)
        #expect(await restore(memory))
        memory.flush()
        #expect(!FileManager.default.fileExists(atPath: path.path))
        memory.erase()
        #expect(memory.count == 0)
    }

    @Test func persistenceRestoresOnlyEligibleObjectsAndSameAuthority() async throws {
        let path = file()
        defer { Writer.to(path).flush(); try? FileManager.default.removeItem(at: path) }
        let first = try item(1), second = try item(2), transient = try item(3)
        let memory = GitHubMemory(space: space, authority: account, file: path)
        #expect(await restore(memory))
        memory.reconcile(history: [first, second], visible: [first, second, transient])
        for id in [first, second, transient] {
            #expect(memory.receive(.open, at: now, for: try #require(memory.request(id, api: true))))
        }
        memory.flush()
        let reopened = GitHubMemory(space: space, authority: account, file: path)
        reopened.reconcile(history: [first], visible: [transient])
        #expect(await restore(reopened))
        #expect(reopened.reading(first).observation?.source == .api(account))
        #expect(reopened.reading(second).observation == nil)
        #expect(reopened.reading(transient).observation == nil)
        let other = GitHubMemory(space: space, authority: GitHubAuthority(account: account.account, generation: UUID()), file: path)
        other.reconcile(history: [first], visible: [])
        #expect(await restore(other))
        #expect(other.count == 0)
    }

    @Test func pageObservationsRestoreOnlyUnderTheAuthorizationTheyWereSeenWith() async throws {
        let path = file()
        defer { Writer.to(path).flush(); try? FileManager.default.removeItem(at: path) }
        let id = try item()
        let seen = GitHubMemory(space: space, authority: account, file: path)
        #expect(await restore(seen))
        seen.reconcile(history: [id], visible: [id])
        #expect(seen.receive(.open, at: now, for: try #require(seen.request(id, api: false))))
        seen.flush()
        let other = GitHubAuthority(account: GitHubAccount(id: 2, login: "other"), generation: UUID())
        for authority in [nil, other] {
            let reopened = GitHubMemory(space: space, authority: authority, file: path)
            reopened.reconcile(history: [id], visible: [id])
            #expect(await restore(reopened))
            #expect(reopened.count == 0)
        }
        // The mismatched restore also removed the stale snapshot from disk.
        Writer.to(path).flush()
        let same = GitHubMemory(space: space, authority: account, file: path)
        same.reconcile(history: [id], visible: [])
        #expect(await restore(same))
        #expect(same.count == 0)
    }

    @Test func pageObservationsSurviveRestartUnderTheSameAuthorization() async throws {
        let path = file()
        defer { Writer.to(path).flush(); try? FileManager.default.removeItem(at: path) }
        let id = try item()
        let seen = GitHubMemory(space: space, authority: account, file: path)
        #expect(await restore(seen))
        seen.reconcile(history: [id], visible: [id])
        #expect(seen.receive(.closed, at: now, for: try #require(seen.request(id, api: false))))
        seen.flush()
        let reopened = GitHubMemory(space: space, authority: account, file: path)
        reopened.reconcile(history: [id], visible: [])
        #expect(await restore(reopened))
        #expect(reopened.reading(id).observation?.source == .page)
    }

    @Test func boundsEvictionAndPressureKeepLocalIdentityIndependent() async throws {
        let path = file()
        defer { Writer.to(path).flush(); try? FileManager.default.removeItem(at: path) }
        let memory = GitHubMemory(space: space, file: path)
        #expect(await restore(memory))
        let ids = try (1...2_008).map { try item($0) }
        memory.reconcile(history: Array(ids.prefix(2_001)), visible: Array(ids.suffix(8)))
        for id in ids.prefix(6) { #expect(memory.request(id, api: false) != nil) }
        #expect(memory.request(ids[6], api: false) == nil)
        #expect(memory.pendingCount == 6)
        memory.cancel()
        for id in ids {
            if let ticket = memory.request(id, api: false) { #expect(memory.receive(.open, at: now, for: ticket)) }
        }
        #expect(memory.count == 2_006)
        #expect(memory.persistentCount == 2_000)
        memory.flush()
        #expect(try Data(contentsOf: path).count < GitHubMemory.bytes)
        memory.reconcile(history: [ids[0]], visible: [])
        #expect(memory.count == 1)
        memory.relieve()
        #expect(memory.count == 0)
        #expect(memory.request(ids[0], api: false) != nil)
        memory.flush()
        // Relief frees memory only: the file is read again on the next restore.
        #expect(!memory.loaded)
        #expect(await restore(memory))
        #expect(memory.reading(ids[0]).observation?.state == .open)
    }

    @Test func anUnusableReplyStillFreesItsWorkSlot() throws {
        let memory = GitHubMemory(space: space, isPrivate: true)
        let issues = try (1...7).map { n -> GitHubItem.ID in
            let url = try #require(URL(string: "https://github.com/fixture/repo/issues/\(n)"))
            return try #require(GitHubItem.ID(url: url, space: space))
        }
        memory.reconcile(history: [], visible: Array(issues.prefix(6)))
        // An issue cannot be merged, and a date must be finite.
        for (index, id) in issues.prefix(6).enumerated() {
            let ticket = try #require(memory.request(id, api: false))
            #expect(!memory.receive(index.isMultiple(of: 2) ? .merged : .open, at: index.isMultiple(of: 2) ? now : .init(timeIntervalSince1970: .infinity), for: ticket))
        }
        #expect(memory.pendingCount == 0)
        memory.reconcile(history: [], visible: Array(issues.suffix(6)))
        #expect(memory.request(issues[6], api: false) != nil)
    }

    @Test func ownersAndSpacesCannotAcceptEachOthersTickets() throws {
        let a = GitHubMemory(space: space, isPrivate: true)
        let b = GitHubMemory(space: space, isPrivate: true)
        let id = try item()
        a.reconcile(history: [], visible: [id])
        b.reconcile(history: [], visible: [id, try item(space: UUID())])
        let ticket = try #require(a.request(id, api: false))
        #expect(!b.receive(.closed, at: now, for: ticket))
        #expect(b.request(try item(space: UUID()), api: false) == nil)
        a.reconcile(history: [], visible: [])
        #expect(!a.receive(.closed, at: now, for: ticket))
    }

    @Test func corruptOversizeDuplicateAndForeignSpaceFilesAreRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("escale-github-bad-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try item()
        let observation = GitHubObservation(state: .open, source: .page, observedAt: now)
        let entry = GitHubDisk.Entry(item: id, observation: observation)
        let fixtures = [
            Data("broken".utf8), Data(repeating: 32, count: GitHubMemory.bytes + 1),
            try JSONEncoder().encode(GitHubDisk.Snapshot(entries: [entry, entry])),
            try JSONEncoder().encode(GitHubDisk.Snapshot(entries: [GitHubDisk.Entry(item: try item(space: UUID()), observation: observation)]))
        ]
        for (index, data) in fixtures.enumerated() {
            let path = root.appendingPathComponent("fixture-\(index).json")
            try data.write(to: path)
            let memory = GitHubMemory(space: space, file: path)
            memory.reconcile(history: [id], visible: [])
            #expect(!(await restore(memory)))
            #expect(memory.loadRejected)
            #expect(memory.count == 0)
            #expect(!FileManager.default.fileExists(atPath: path.path))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == fixtures.count)
    }

    @Test func forgottenWhileLoadingCannotBeRestored() async throws {
        let path = file()
        defer { Writer.to(path).flush(); try? FileManager.default.removeItem(at: path) }
        let id = try item()
        let snapshot = GitHubDisk.Snapshot(entries: [GitHubDisk.Entry(item: id, observation: GitHubObservation(state: .open, source: .page, observedAt: now))])
        try JSONEncoder().encode(snapshot).write(to: path)
        let memory = GitHubMemory(space: space, file: path)
        memory.reconcile(history: [id], visible: [id])
        await withCheckedContinuation { continuation in
            memory.restore { _ in continuation.resume() }
            memory.forget()
        }
        #expect(memory.loaded)
        #expect(memory.count == 0)
        memory.flush()
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test func oneObjectForgottenWhileLoadingStaysGoneAndTheOthersReturn() async throws {
        let path = file()
        defer { Writer.to(path).flush(); try? FileManager.default.removeItem(at: path) }
        let first = try item(1), second = try item(2)
        let observation = GitHubObservation(state: .open, source: .page, observedAt: now)
        try JSONEncoder().encode(GitHubDisk.Snapshot(entries: [first, second].map { GitHubDisk.Entry(item: $0, observation: observation) })).write(to: path)
        let memory = GitHubMemory(space: space, file: path)
        memory.reconcile(history: [first, second], visible: [])
        await withCheckedContinuation { continuation in
            memory.restore { _ in continuation.resume() }
            memory.forget(first)
            // Visited again before the read returned: still no old state for it.
            memory.reconcile(history: [first, second], visible: [])
        }
        #expect(memory.reading(first).observation == nil)
        #expect(memory.reading(second).observation == observation)
    }

    @Test func nothingIsWrittenBeforeTheCacheIsLoaded() async throws {
        let path = file()
        defer { Writer.to(path).flush(); try? FileManager.default.removeItem(at: path) }
        let first = try item(1), second = try item(2)
        let old = GitHubObservation(state: .closed, source: .api(account), observedAt: now)
        try JSONEncoder().encode(GitHubDisk.Snapshot(entries: [GitHubDisk.Entry(item: first, observation: old)], authority: account)).write(to: path)
        let memory = GitHubMemory(space: space, file: path)
        memory.reconcile(history: [first, second], visible: [second])
        // The authorization arrives after construction, as GitHubAccess restores it.
        memory.authorize(account)
        #expect(memory.receive(.open, at: now, for: try #require(memory.request(second, api: false))))
        memory.relieve()
        memory.flush()
        #expect(try JSONDecoder().decode(GitHubDisk.Snapshot.self, from: Data(contentsOf: path)).entries.count == 1)
        #expect(await restore(memory))
        #expect(memory.reading(first).observation == old)
    }

    @Test func forgettingAnUnloadedCacheDropsItsFile() throws {
        let path = file()
        defer { Writer.to(path).flush(); try? FileManager.default.removeItem(at: path) }
        let id = try item()
        try JSONEncoder().encode(GitHubDisk.Snapshot(entries: [GitHubDisk.Entry(item: id, observation: GitHubObservation(state: .open, source: .page, observedAt: now))])).write(to: path)
        let memory = GitHubMemory(space: space, file: path)
        memory.reconcile(history: [id], visible: [])
        memory.forget(id)
        memory.flush()
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }
    @Test func missingCacheStartsEmpty() async throws {
        let path = file()
        defer { Writer.to(path).flush(); try? FileManager.default.removeItem(at: path) }
        let memory = GitHubMemory(space: space, file: path)
        memory.reconcile(history: [try item()], visible: [])
        #expect(await restore(memory))
        #expect(memory.count == 0)
        #expect(!memory.loadRejected)
    }

    @Test func largestValidSnapshotFitsTheDiskBound() throws {
        let owner = String(repeating: "a", count: 39)
        let repository = String(repeating: "_", count: 100)
        let authority = GitHubAuthority(account: GitHubAccount(id: Int.max, login: String(repeating: "\u{0001}", count: 100)), generation: UUID())
        let observation = GitHubObservation(state: .unknown, source: .api(authority), observedAt: now)
        let entries = try (1...GitHubMemory.room).map { n in
            let url = try #require(URL(string: "https://github.com/\(owner)/\(repository)/pull/\(Int.max - n)"))
            let id = try #require(GitHubItem.ID(url: url, space: space))
            return GitHubDisk.Entry(item: id, observation: observation)
        }
        #expect(try JSONEncoder().encode(GitHubDisk.Snapshot(entries: entries, authority: authority)).count < GitHubMemory.bytes)
    }

    @Test func leavingVisibleBatchCancelsAPIEvenWhenHistoryStillContainsTheItem() throws {
        let path = file()
        defer { Writer.to(path).flush(); try? FileManager.default.removeItem(at: path) }
        let memory = GitHubMemory(space: space, authority: account, file: path)
        let id = try item()
        memory.reconcile(history: [id], visible: [])
        #expect(memory.request(id, api: true) == nil)
        memory.reconcile(history: [id], visible: [id])
        let ticket = try #require(memory.request(id, api: true))
        var stopped = false
        memory.cancelled = { if $0 == ticket { stopped = true } }
        memory.reconcile(history: [id], visible: [])
        #expect(stopped)
        #expect(!memory.receive(.open, at: now, for: ticket))
        #expect(memory.pendingCount == 0)
    }

}
