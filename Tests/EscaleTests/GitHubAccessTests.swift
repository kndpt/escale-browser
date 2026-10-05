// Authorization fixtures control network replies and time. Credentials stay in
// a test-only memory store here; the separate explicit keychain fixture checks
// the real Security boundary without calling Store or reading a normal account.

import Foundation
import Testing
@testable import Escale

@MainActor
final class GitHubTestSecrets: GitHubCredentialStore {
    var value: GitHubCredential?
    var writes = 0
    var erases = 0
    var hold: CheckedContinuation<Void, Never>?
    var holdSave = false
    var failSave = false
    func load() async throws -> GitHubCredential? { value }
    func save(_ credential: GitHubCredential) async throws {
        if failSave { throw GitHubFailure.storage }
        value = credential
        writes += 1
        if holdSave { await withCheckedContinuation { hold = $0 } }
    }
    func erase() -> Task<Void, Error> {
        value = nil
        erases += 1
        return Task {}
    }
}

@MainActor
final class GitHubTestClock {
    var date = Date(timeIntervalSince1970: 1_000)
    var intervals: [TimeInterval] = []
    func pause(_ seconds: TimeInterval) async throws { intervals.append(seconds); date.addTimeInterval(seconds) }
}

@MainActor
func githubReply(_ json: String, status: Int = 200, headers: [String: String] = [:]) -> GitHubReply {
    GitHubReply(status: status, headers: headers, data: Data(json.utf8))
}

@MainActor
func githubCredential(at date: Date, expired: Bool = false) -> GitHubCredential {
    GitHubCredential(clientID: "fixture", authority: GitHubAuthority(account: GitHubAccount(id: 1, login: "fixture"), generation: UUID()),
                     token: GitHubToken(access: "fixture_access", refresh: "fixture_refresh",
                                        expiresAt: date.addingTimeInterval(expired ? -1 : 3_600), refreshExpiresAt: date.addingTimeInterval(10_000)))
}

@MainActor
@Suite struct GitHubAccessTests {
    private let device = #"{"device_code":"fixture_device","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#
    private let token = #"{"access_token":"fixture_access_new","refresh_token":"fixture_refresh_new","expires_in":28800,"refresh_token_expires_in":15897600,"token_type":"bearer","scope":""}"#

    @Test func deviceFlowUsesBodyAndHonorsPendingAndSlowDown() async throws {
        let secrets = GitHubTestSecrets(), clock = GitHubTestClock()
        var calls: [URLRequest] = []
        var replies = [device, #"{"error":"authorization_pending"}"#, #"{"error":"slow_down","interval":12}"#, token, #"{"id":12,"login":"fixture"}"#]
        let access = GitHubAccess(space: UUID(), configuration: .init(clientID: "fixture"), secrets: secrets,
                                  http: GitHubHTTP { request in
                                      calls.append(request)
                                      return githubReply(replies.removeFirst())
                                  }, now: { clock.date }, pause: clock.pause)
        await access.connect()
        #expect(access.connection == .connected(GitHubAccount(id: 12, login: "fixture")))
        #expect(clock.intervals == [5, 5, 12])
        #expect(calls.count == 5)
        #expect(calls.allSatisfy { $0.url?.query == nil })
        #expect(calls.first?.url?.host == "github.com")
        #expect(calls.last?.url?.host == "api.github.com")
        #expect(calls.first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(calls.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture_access_new")
        #expect(secrets.writes == 1)
        #expect(secrets.value?.authority == access.authority)
    }

    @Test func refusalExpirationAndConfigurationErrorsExitWithoutSaving() async throws {
        for (code, expected) in [("access_denied", GitHubFailure.denied), ("expired_token", .expired), ("device_flow_disabled", .configuration)] {
            let secrets = GitHubTestSecrets(), clock = GitHubTestClock()
            let access = GitHubAccess(space: UUID(), configuration: .init(clientID: "fixture"), secrets: secrets,
                                      http: GitHubHTTP { request in
                                          githubReply(request.url?.path == "/login/device/code" ? device : "{\"error\":\"\(code)\"}")
                                      }, now: { clock.date }, pause: clock.pause)
            await access.connect()
            #expect(access.connection == .unavailable(expected))
            #expect(secrets.value == nil)
            #expect(secrets.writes == 0)
        }
    }

    @Test func privateContextDoesNotReadWriteOrCallHTTP() async {
        let secrets = GitHubTestSecrets()
        var calls = 0
        let access = GitHubAccess(space: UUID(), isPrivate: true, configuration: .init(clientID: "fixture"), secrets: secrets,
                                  http: GitHubHTTP { _ in calls += 1; throw GitHubFailure.unavailable })
        await access.restore()
        await access.connect()
        #expect(calls == 0)
        #expect(secrets.erases == 0)
        #expect(secrets.writes == 0)
        #expect(access.connection == .local)
    }

    @Test func cancellationDuringSaveDeletesThePendingCredential() async throws {
        let secrets = GitHubTestSecrets(), clock = GitHubTestClock()
        secrets.holdSave = true
        var replies = [device, token, #"{"id":1,"login":"fixture"}"#]
        let access = GitHubAccess(space: UUID(), configuration: .init(clientID: "fixture"), secrets: secrets,
                                  http: GitHubHTTP { _ in githubReply(replies.removeFirst()) }, now: { clock.date }, pause: clock.pause)
        let flow = Task { await access.connect() }
        for _ in 0..<100 where secrets.hold == nil { await Task.yield() }
        let hold = try #require(secrets.hold)
        access.cancelConnection()
        hold.resume()
        await flow.value
        #expect(secrets.value == nil)
        #expect(access.authority == nil)
        #expect(access.connection == .local)
    }

    @Test func aSingleRotationServesConcurrentUsesAndKeepsItsGeneration() async throws {
        let secrets = GitHubTestSecrets(), clock = GitHubTestClock()
        let original = githubCredential(at: clock.date, expired: true)
        secrets.value = original
        var rotations = 0
        let access = GitHubAccess(space: UUID(), configuration: .init(clientID: "fixture"), secrets: secrets,
                                  http: GitHubHTTP { request in
                                      rotations += 1
                                      await Task.yield()
                                      #expect(request.url?.path == "/login/oauth/access_token")
                                      return githubReply(token)
                                  }, now: { clock.date })
        await access.restore()
        async let first = access.token()
        async let second = access.token()
        let values = try await [first, second]
        #expect(rotations == 1)
        #expect(values.allSatisfy { $0.access == "fixture_access_new" })
        #expect(secrets.value?.authority == original.authority)
        #expect(secrets.value?.token.refresh == "fixture_refresh_new")
        #expect(secrets.writes == 1)
    }

    @Test func aReauthorizationCancelledBeforeItStartsKeepsTheAccount() async throws {
        let secrets = GitHubTestSecrets(), clock = GitHubTestClock()
        let saved = githubCredential(at: clock.date)
        secrets.value = saved
        var calls = 0
        let access = GitHubAccess(space: UUID(), configuration: .init(clientID: "fixture"), secrets: secrets,
                                  http: GitHubHTTP { _ in calls += 1; return githubReply("{}", status: 500) }, now: { clock.date })
        await access.restore()
        // The main actor runs in order: connect() queues its flow, then this
        // test cancels before that flow has had a turn.
        let connecting = Task { await access.connect() }
        await Task.yield()
        access.cancelConnection()
        await connecting.value
        #expect(access.connection == .connected(saved.authority.account))
        #expect(access.authority == saved.authority)
        #expect(secrets.value != nil)
        #expect(secrets.erases == 0)
        #expect(calls == 0)
    }

    @Test func disconnectDuringRotationRejectsLateSuccess() async throws {
        let secrets = GitHubTestSecrets(), clock = GitHubTestClock()
        secrets.value = githubCredential(at: clock.date, expired: true)
        var held: CheckedContinuation<GitHubReply, Never>?
        let access = GitHubAccess(space: UUID(), configuration: .init(clientID: "fixture"), secrets: secrets,
                                  http: GitHubHTTP { _ in await withCheckedContinuation { held = $0 } }, now: { clock.date })
        await access.restore()
        let rotating = Task { try await access.token() }
        for _ in 0..<100 where held == nil { await Task.yield() }
        let reply = try #require(held)
        await access.disconnect()
        reply.resume(returning: githubReply(token))
        do { _ = try await rotating.value; Issue.record("Late token was accepted") } catch {}
        #expect(access.authority == nil)
        #expect(secrets.value == nil)
        #expect(secrets.writes == 0)
    }

    @Test func fixedOriginsNoRedirectInputAndQuotaClassification() throws {
        let id = try #require(URL(string: "https://github.com/fixture/repo/pull/1"))
        #expect(id.host == "github.com")
        #expect(throws: GitHubFailure.self) { try GitHubHTTP.request(path: "https://evil.test/", token: "fixture") }
        #expect(throws: GitHubFailure.self) { try GitHubHTTP.request(path: "/login/device/code", token: "fixture") }
        #expect(throws: GitHubFailure.self) { try GitHubHTTP.request(path: "/user", token: "bad\r\nheader") }
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(githubReply("", status: 403).failure(at: now) == .forbidden)
        #expect(githubReply("", status: 403, headers: ["retry-after":"120"]).failure(at: now) == .rateLimited)
        #expect(githubReply("", status: 429, headers: ["retry-after":"120"]).retryDate(at: now) == now.addingTimeInterval(120))
        #expect(githubReply("", status: 404).failure(at: now) == .notFound)
    }
    @Test func authorizationQuotaPreventsAnImmediateNewFlow() async {
        let secrets = GitHubTestSecrets(), clock = GitHubTestClock()
        var calls = 0
        let access = GitHubAccess(space: UUID(), configuration: .init(clientID: "fixture"), secrets: secrets,
                                  http: GitHubHTTP { _ in
                                      calls += 1
                                      return githubReply("", status: 429, headers: ["retry-after":"600"])
                                  }, now: { clock.date }, pause: clock.pause)
        await access.connect()
        await access.connect()
        #expect(calls == 1)
        #expect(access.connection == .unavailable(.rateLimited))
        #expect(access.retryAt == clock.date.addingTimeInterval(600))
    }

}
