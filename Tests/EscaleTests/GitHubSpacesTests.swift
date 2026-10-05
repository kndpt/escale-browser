// The per-Space coordinator with temporary files, in-memory secrets and a
// transport that fails if called. These tests prove the order between owners
// and the lifecycle hooks' effects on disk, not that Browser calls them.

import Foundation
import Testing
@testable import Escale

@MainActor
@Suite struct GitHubSpacesTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("escale-github-spaces-\(UUID())")
    private let now = Date(timeIntervalSince1970: 1_000)

    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }

    @MainActor
    private final class Keys {
        var stores: [UUID: GitHubTestSecrets] = [:]
        func store(_ space: UUID) -> GitHubTestSecrets {
            if let known = stores[space] { return known }
            let made = GitHubTestSecrets()
            stores[space] = made
            return made
        }
    }

    private func item(_ space: UUID, _ number: Int = 1) throws -> GitHubItem.ID {
        let url = try #require(URL(string: "https://github.com/fixture/repo/pull/\(number)"))
        return try #require(GitHubItem.ID(url: url, space: space))
    }

    private func path(_ space: UUID) -> URL { root.appendingPathComponent("github-\(space.uuidString).json") }

    private func spaces(_ histories: [UUID: History] = [:], keys: Keys,
                        http: GitHubHTTP = GitHubHTTP { _ in throw GitHubFailure.offline }) -> GitHubSpaces {
        GitHubSpaces(history: { histories[$0] }, configuration: .init(clientID: "fixture"),
                            secrets: { keys.store($0) }, file: { path($0) }, http: http)
    }

    private func history(_ urls: [String]) throws -> History {
        let made = History(file: root.appendingPathComponent("history-\(UUID()).json"))
        for url in urls { made.record(try #require(URL(string: url)), title: "Fixture") }
        return made
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(condition())
    }

    private func cleanUp() {
        Writer.flushAll()
        try? FileManager.default.removeItem(at: root)
    }

    @Test func historyIdentitiesAreOneRowPerObjectAndFollowTheHistory() throws {
        defer { cleanUp() }
        let space = UUID()
        let history = try history([
            "https://github.com/fixture/repo/pull/1", "https://github.com/fixture/repo/pull/1/files",
            "https://github.com/fixture/repo/issues/2", "https://example.com/fixture/repo/pull/3"
        ])
        let github = spaces([space: history], keys: Keys())
        #expect(Set(github.history(of: space).map(\.number)) == [1, 2])
        history.record(try #require(URL(string: "https://github.com/fixture/repo/pull/4")), title: "Fixture")
        #expect(github.history(of: space).count == 3)
    }

    @Test func theCacheIsReadAfterTheAuthorizationAndSurvivesARestart() async throws {
        defer { cleanUp() }
        let space = UUID(), keys = Keys()
        let credential = githubCredential(at: now)
        keys.store(space).value = credential
        let history = try history(["https://github.com/fixture/repo/pull/1"])
        let id = try item(space)
        let seen = GitHubObservation(state: .merged, source: .api(credential.authority), observedAt: now)
        try JSONEncoder().encode(GitHubDisk.Snapshot(entries: [GitHubDisk.Entry(item: id, observation: seen)], authority: credential.authority))
            .write(to: path(space))
        let github = spaces([space: history], keys: keys)
        let owner = github.owner(for: space)
        await settle { owner.memory.loaded }
        #expect(owner.memory.reading(id).observation == seen)
        #expect(owner.access.connection == .connected(credential.authority.account))
        // Relief frees memory; the next opening reads the file again.
        github.relieve()
        #expect(owner.memory.count == 0)
        _ = github.owner(for: space)
        await settle { owner.memory.loaded }
        #expect(owner.memory.reading(id).observation == seen)
    }

    @Test func forgettingASubpageForgetsTheObjectAndOtherPlacesAreIgnored() async throws {
        defer { cleanUp() }
        let space = UUID(), keys = Keys()
        let history = try history(["https://github.com/fixture/repo/pull/1", "https://github.com/fixture/repo/pull/2"])
        let github = spaces([space: history], keys: keys)
        let owner = github.owner(for: space)
        await settle { owner.memory.loaded }
        let ids = github.history(of: space)
        owner.memory.reconcile(history: ids, visible: ids)
        for id in ids { #expect(owner.memory.receive(.open, at: now, for: try #require(owner.memory.request(id, api: false)))) }
        github.forget("example.com/fixture", in: space)
        #expect(owner.memory.count == 2)
        github.forget("github.com/fixture/repo/pull/1/files", in: space)
        #expect(owner.memory.count == 1)
        #expect(owner.memory.reading(try item(space)).observation == nil)
        github.forget(nil, in: space)
        #expect(owner.memory.count == 0)
        owner.memory.flush()
        #expect(!FileManager.default.fileExists(atPath: path(space).path))
    }

    @Test func aSpaceNeverOpenedInGitHubModeStillLosesItsCacheWhenForgottenOrDeleted() throws {
        defer { cleanUp() }
        let space = UUID(), keys = Keys()
        let github = spaces(keys: keys)
        try Data("{}".utf8).write(to: path(space))
        github.forget("example.com/page", in: space)
        Writer.to(path(space)).flush()
        #expect(FileManager.default.fileExists(atPath: path(space).path))
        github.forget("github.com/fixture/repo/issues/9", in: space)
        Writer.to(path(space)).flush()
        #expect(!FileManager.default.fileExists(atPath: path(space).path))
        let setAside = root.appendingPathComponent("github-\(space.uuidString).unreadable-1.json")
        try Data("{}".utf8).write(to: setAside)
        github.forget(nil, in: space)
        Writer.to(path(space)).flush()
        #expect(!FileManager.default.fileExists(atPath: setAside.path))
    }

    @Test func deletionRemovesCacheSetAsideFilesAndSecretsEvenWhileRestoring() async throws {
        defer { cleanUp() }
        let space = UUID(), other = UUID(), keys = Keys()
        keys.store(space).value = githubCredential(at: now)
        let github = spaces(keys: keys)
        let setAside = root.appendingPathComponent("github-\(space.uuidString).unreadable-1.json")
        let kept = root.appendingPathComponent("github-\(other.uuidString).unreadable-1.json")
        for file in [path(space), setAside, kept] { try Data("{}".utf8).write(to: file) }
        let owner = github.owner(for: space)
        github.erase(space)
        Writer.to(path(space)).flush()
        await settle { keys.store(space).erases > 0 }
        #expect(!FileManager.default.fileExists(atPath: path(space).path))
        #expect(!FileManager.default.fileExists(atPath: setAside.path))
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(owner.memory.count == 0)
        // A late restore has nothing to come back to, and a recreated owner starts empty.
        try? await Task.sleep(nanoseconds: 20_000_000)
        Writer.to(path(space)).flush()
        #expect(!FileManager.default.fileExists(atPath: path(space).path))
        #expect(github.owner(for: space).memory !== owner.memory)
    }

    @Test func deletingASpaceNeverOpenedErasesItsSecretsToo() async throws {
        defer { cleanUp() }
        let space = UUID(), keys = Keys()
        let github = spaces(keys: keys)
        github.erase(space)
        await settle { keys.store(space).erases == 1 }
    }

    @Test func closingBearingsLeavesAnAuthorizationUnderWayInSettings() async throws {
        defer { cleanUp() }
        let space = UUID(), keys = Keys()
        let device = #"{"device_code":"fixture_device","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#
        let github = spaces(keys: keys, http: GitHubHTTP { request in
            request.url?.path == "/login/device/code" ? githubReply(device) : githubReply("{}", status: 500)
        })
        let owner = github.owner(for: space)
        await settle { owner.memory.loaded }
        let connecting = Task { await owner.access.connect() }
        func authorizing() -> Bool { if case .authorizing = owner.access.connection { return true }; return false }
        await settle(authorizing)
        // A search while signed out, then the surface closing.
        owner.refresh.update(history: [], visible: [try item(space)])
        github.leave(space)
        #expect(authorizing())
        owner.access.cancelConnection()
        await connecting.value
        #expect(owner.access.connection == .local)
    }

    @Test func aPrivateSearchKeepsNothingAfterTheSurfaceCloses() throws {
        defer { cleanUp() }
        let space = UUID(), keys = Keys()
        let github = spaces(keys: keys)
        let memory = github.privateMemory(for: space)
        #expect(github.privateMemory(for: space) === memory)
        let id = try item(space)
        memory.reconcile(history: [id], visible: [id])
        #expect(memory.request(id, api: true) == nil)
        #expect(memory.receive(.open, at: now, for: try #require(memory.request(id, api: false))))
        github.leave(space)
        #expect(memory.count == 0)
        #expect(github.privateMemory(for: space) !== memory)
        #expect(github.privateMemory(for: space).count == 0)
        #expect(!FileManager.default.fileExists(atPath: path(space).path))
        #expect(keys.stores.isEmpty)
    }
}
