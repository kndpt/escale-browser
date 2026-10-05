// Explicit, opt-in qualification against the development GitHub App. Ordinary
// verification never sends these requests. The sole file contains the user code
// displayed for authorization and a non-secret receipt; credentials live in a
// fresh fixture keychain service and are erased on success and failure.

import Combine
import Foundation
import Testing
@testable import Escale

@MainActor
@Suite struct GitHubLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ESCALE_GITHUB_LIVE"] == "1"))
    func developmentDeviceFlowPrivateReadRotationAndRestart() async throws {
        let env = ProcessInfo.processInfo.environment
        let client = try #require(env["ESCALE_GITHUB_CLIENT_ID"])
        let path = try #require(env["ESCALE_GITHUB_LIVE_RECEIPT"])
        guard path.hasPrefix("/tmp/escale-github-live-"), path.hasSuffix("/receipt.json") else {
            throw GitHubFailure.configuration
        }
        let receipt = URL(fileURLWithPath: path)
        func record(_ values: [String: String]) {
            do { try Store.export(JSONEncoder().encode(values), to: receipt) }
            catch { Issue.record("Could not save non-secret live receipt") }
        }
        let space = UUID(), world = UUID()
        let secrets = GitHubSecrets.fixture(world: world, space: space)
        var clockOffset: TimeInterval = 0
        let now = { Date().addingTimeInterval(clockOffset) }
        let access = GitHubAccess(space: space, configuration: .init(clientID: client), secrets: secrets, now: now)
        let observing = access.$connection.sink { state in
            switch state {
            case .authorizing(let code, _): record(["phase":"authorize", "user_code":code])
            case .unavailable(let failure): record(["phase":"failure", "reason":failure.rawValue])
            default: break
            }
        }
        defer { observing.cancel() }
        do {
            await access.connect()
            let authority = try #require(access.authority)
            try #require(authority.account.login == "kndpt")
            let before = try await access.token()
            let http = GitHubHTTP()
            let pull = try await http.exchange(GitHubHTTP.request(path: "/repos/kndpt/escale-github-fixture/pulls/1", token: before.access))
            try GitHubAccess.requireSuccess(pull, at: Date())
            let url = try #require(URL(string: "https://github.com/kndpt/escale-github-fixture/pull/1"))
            let id = try #require(GitHubItem.ID(url: url, space: space))
            try #require(try GitHubRefresh.state(pull.data, for: id) == .draft)
            let issue = try await http.exchange(GitHubHTTP.request(path: "/repos/kndpt/escale-github-fixture/issues/2", token: before.access))
            try GitHubAccess.requireSuccess(issue, at: Date())
            let issueURL = try #require(URL(string: "https://github.com/kndpt/escale-github-fixture/issues/2"))
            let issueID = try #require(GitHubItem.ID(url: issueURL, space: space))
            try #require(try GitHubRefresh.state(issue.data, for: issueID) == .open)
            // Renew a real token without waiting eight hours. Only this test's
            // injected clock advances; macOS and the account settings stay unchanged.
            clockOffset += 8 * 3_600
            let rotated = try await access.token()
            try #require(rotated.access != before.access)
            try #require(rotated.refresh != before.refresh)
            let reopened = GitHubAccess(space: space, configuration: .init(clientID: client), secrets: secrets, now: now)
            await reopened.restore()
            try #require(reopened.authority == authority)
            let saved = try await reopened.token()
            try #require(saved.access == rotated.access)
            let confirmed = try await http.exchange(GitHubHTTP.request(path: "/user", token: saved.access))
            try GitHubAccess.requireSuccess(confirmed, at: Date())
            await reopened.disconnect()
            await access.erase()
            try #require(try await secrets.load() == nil)
            record(["phase":"passed", "account":authority.account.login, "permissions":"issues:read,pull_requests:read,metadata:read", "checks":"device,private-pull,private-issue,rotation,restart,keychain-cleanup"])
        } catch {
            await access.erase()
            record(["phase":"failed", "reason":GitHubAccess.failure(error).rawValue])
            throw error
        }
    }
}
