// Authorization belongs to the originating Space, not to whichever Space is
// visible when GitHub replies. Device polling exists only during that explicit
// transaction; renewal happens on use and shares one rotation. Epoch checks
// surround every suspension, including ordered keychain writes, so disconnect
// cannot be undone by a late token response. The UI observes connection directly.

import Combine
import Foundation

@MainActor
final class GitHubAccess: ObservableObject {
    struct Configuration {
        let clientID: String
        /// The app's name in its github.com address, where people share private repositories with it.
        var slug = ""
        var valid: Bool {
            !clientID.isEmpty && clientID.utf8.count <= 128
                && clientID.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46 || $0 == 95 }
        }
        /// GitHub's page where a person or an organization chooses the repositories the app may read.
        var installURL: URL? {
            guard valid, (1...100).contains(slug.utf8.count),
                  slug.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }) else { return nil }
            return URL(string: "https://github.com/apps/\(slug)/installations/new")
        }
    }

    let space: UUID
    let isPrivate: Bool
    @Published private(set) var connection: GitHubConnection = .local
    private(set) var authority: GitHubAuthority?
    private(set) var retryAt: Date?
    var authorityChanged: ((GitHubAuthority?) -> Void)?
    private let configuration: Configuration
    private let secrets: GitHubCredentialStore
    private let http: GitHubHTTP
    private let now: () -> Date
    private let pause: (TimeInterval) async throws -> Void
    private var credential: GitHubCredential?
    private var epoch = UUID()
    private var flow: Task<Void, Never>?
    private var rotation: (id: UUID, task: Task<GitHubToken, Error>)?
    private var ended = false

    init(space: UUID, isPrivate: Bool = false, configuration: Configuration,
         secrets: GitHubCredentialStore, http: GitHubHTTP = GitHubHTTP(),
         now: @escaping () -> Date = Date.init,
         pause: @escaping (TimeInterval) async throws -> Void = { seconds in
             try await Task.sleep(nanoseconds: UInt64(max(0, min(seconds, 3_600)) * 1_000_000_000))
         }) {
        self.space = space
        self.isPrivate = isPrivate
        self.configuration = configuration
        self.secrets = secrets
        self.http = http
        self.now = now
        self.pause = pause
    }

    /// The UI opens this address and copies the displayed code only on explicit action.
    static var verificationURL: URL? { URL(string: "https://github.com/login/device") }
    static var revocationURL: URL? { URL(string: "https://github.com/settings/apps/authorizations") }
    /// False in a private context or a build without a GitHub App: only local search is offered.
    var canConnect: Bool { !ended && !isPrivate && configuration.valid }
    var installURL: URL? { configuration.installURL }

    func restore() async {
        guard !ended, !isPrivate, flow == nil, credential == nil else { return }
        let captured = epoch
        do {
            let saved = try await secrets.load()
            try check(captured)
            guard let saved else { return }
            guard saved.valid, saved.clientID == configuration.clientID else { throw GitHubFailure.configuration }
            credential = saved
            authority = saved.authority
            connection = .connected(saved.authority.account)
            authorityChanged?(authority)
        } catch { if captured == epoch { connection = .unavailable(Self.failure(error)) } }
    }

    func connect() async {
        guard !ended, !isPrivate, configuration.valid else {
            if !ended && !isPrivate { connection = .unavailable(.configuration) }
            return
        }
        if let retryAt, retryAt > now() { connection = .unavailable(.rateLimited); return }
        cancelConnection()
        let captured = epoch
        let task = Task { await self.runConnection(captured) }
        flow = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if task.isCancelled, captured == epoch { cancelConnection() }
        if captured == epoch { flow = nil }
    }

    private func runConnection(_ captured: UUID) async {
        do {
            // Cancelled before its first turn: the account in place stays untouched.
            try check(captured)
            // Account replacement is explicit. Erase before requesting a code; no
            // second account can leave orphaned secrets under the Space's service.
            credential = nil
            rotation?.task.cancel()
            rotation = nil
            authority = nil
            authorityChanged?(nil)
            connection = .connecting
            try await secrets.erase().value
            try check(captured)
            let reply = try await http.exchange(GitHubHTTP.request(path: "/login/device/code", form: ["client_id": configuration.clientID]))
            try check(captured)
            try accept(reply)
            let device = try Self.decode(Device.self, reply.data)
            guard device.valid else { throw GitHubFailure.invalidResponse }
            let deadline = now().addingTimeInterval(device.expiresIn)
            connection = .authorizing(code: device.userCode, expiresAt: deadline)
            var interval = device.interval
            // A hard attempt bound also protects against a broken injected clock.
            for _ in 0..<720 {
                let remaining = deadline.timeIntervalSince(now())
                guard remaining > interval else { throw GitHubFailure.expired }
                try await pause(interval)
                try check(captured)
                guard now() < deadline else { throw GitHubFailure.expired }
                let response = try await http.exchange(GitHubHTTP.request(path: "/login/oauth/access_token", form: [
                    "client_id": configuration.clientID, "device_code": device.deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
                ]))
                try check(captured)
                guard now() < deadline else { throw GitHubFailure.expired }
                try accept(response)
                let payload = try Self.decode(TokenReply.self, response.data)
                if payload.error == "authorization_pending" { continue }
                if payload.error == "slow_down" {
                    interval = min(3_600, max(interval + 5, payload.interval ?? 0))
                    continue
                }
                let token = try payload.token(at: now())
                let userReply = try await http.exchange(GitHubHTTP.request(path: "/user", token: token.access))
                try check(captured)
                try accept(userReply)
                let account = try Self.decode(GitHubAccount.self, userReply.data)
                guard account.valid else { throw GitHubFailure.invalidResponse }
                let authority = GitHubAuthority(account: account, generation: UUID())
                let value = GitHubCredential(clientID: configuration.clientID, authority: authority, token: token)
                try await secrets.save(value)
                try check(captured)
                credential = value
                self.authority = authority
                connection = .connected(account)
                authorityChanged?(authority)
                return
            }
            throw GitHubFailure.expired
        } catch {
            guard captured == epoch else { return }
            connection = error is CancellationError ? .local : .unavailable(Self.failure(error))
        }
    }

    /// Dismissing the authorization screen stops its polling immediately.
    func cancelConnection() {
        let unfinished = flow != nil && credential == nil
        epoch = UUID()
        flow?.cancel()
        flow = nil
        rotation?.task.cancel()
        rotation = nil
        connection = credential.map { .connected($0.authority.account) } ?? .local
        if unfinished {
            let captured = epoch
            let deletion = secrets.erase()
            Task {
                do { try await deletion.value }
                catch { if captured == self.epoch { self.connection = .unavailable(.storage) } }
            }
        }
    }

    /// Secrets are removed locally; remote revocation remains an explicit GitHub action.
    func disconnect(reason: GitHubFailure? = nil) async {
        cancelConnection()
        guard !isPrivate else { connection = .local; return }
        let captured = epoch
        credential = nil
        authority = nil
        authorityChanged?(nil)
        connection = .disconnecting
        do {
            try await secrets.erase().value
            if captured == epoch { connection = reason.map { .unavailable($0) } ?? .local }
        } catch { if captured == epoch { connection = .unavailable(.storage) } }
    }

    func erase() async {
        ended = true
        await disconnect()
    }

    /// Called by the visible-item owner only, never a launch timer.
    func token() async throws -> GitHubToken {
        guard !ended, !isPrivate, let credential, let authority, authority == credential.authority else {
            throw GitHubFailure.unauthorized
        }
        let captured = epoch
        if let retryAt, retryAt > now() { throw GitHubFailure.rateLimited }
        if let rotation {
            let token = try await rotation.task.value
            try check(captured)
            return token
        }
        if credential.token.expiresAt.map({ $0.timeIntervalSince(now()) > 60 }) ?? true { return credential.token }
        guard let refresh = credential.token.refresh,
              credential.token.refreshExpiresAt.map({ $0 > now() }) == true else {
            await disconnect(reason: .expired)
            throw GitHubFailure.expired
        }
        let id = UUID()
        let task = Task { () throws -> GitHubToken in
            let response = try await self.http.exchange(GitHubHTTP.request(path: "/login/oauth/access_token", form: [
                "client_id": self.configuration.clientID, "grant_type": "refresh_token", "refresh_token": refresh
            ]))
            try self.check(captured)
            try self.accept(response)
            let token = try Self.decode(TokenReply.self, response.data).token(at: self.now())
            let value = GitHubCredential(clientID: credential.clientID, authority: authority, token: token)
            try await self.secrets.save(value)
            try self.check(captured)
            self.credential = value
            return token
        }
        rotation = (id, task)
        do {
            let result = try await task.value
            try check(captured)
            if rotation?.id == id { rotation = nil }
            return result
        } catch {
            if captured == epoch {
                if rotation?.id == id { rotation = nil }
                let failure = Self.failure(error)
                if failure == .unauthorized || failure == .expired || failure == .storage {
                    await disconnect(reason: failure)
                }
            }
            throw error
        }
    }

    /// Surface deactivation cancels renewal as well as a pending device transaction.
    func cancel() { cancelConnection() }

    private func check(_ captured: UUID) throws {
        try Task.checkCancellation()
        guard !ended, epoch == captured else { throw CancellationError() }
    }

    static func failure(_ error: Error) -> GitHubFailure {
        if error is CancellationError { return .cancelled }
        return error as? GitHubFailure ?? .invalidResponse
    }

    private func accept(_ reply: GitHubReply) throws {
        if let date = reply.retryDate(at: now()) { retryAt = date }
        try Self.requireSuccess(reply, at: now())
    }

    static func requireSuccess(_ reply: GitHubReply, at now: Date) throws {
        guard reply.data.count <= GitHubHTTP.limit else { throw GitHubFailure.invalidResponse }
        if let failure = reply.failure(at: now) { throw failure }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        guard data.count <= GitHubHTTP.limit else { throw GitHubFailure.invalidResponse }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(type, from: data) }
        catch { throw GitHubFailure.invalidResponse }
    }

    private struct Device: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationUri: String
        let expiresIn: TimeInterval
        let interval: TimeInterval
        var valid: Bool {
            GitHubToken.validSecret(deviceCode) && (1...32).contains(userCode.utf8.count)
                && userCode.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) || $0 == 45 }
                && verificationUri == "https://github.com/login/device"
                && expiresIn.isFinite && (1...3_600).contains(expiresIn)
                && interval.isFinite && (1...3_600).contains(interval)
        }
    }

    private struct TokenReply: Decodable {
        let error: String?
        let interval: TimeInterval?
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: TimeInterval?
        let refreshTokenExpiresIn: TimeInterval?
        let tokenType: String?
        let scope: String?

        func token(at now: Date) throws -> GitHubToken {
            if let error {
                switch error {
                case "access_denied": throw GitHubFailure.denied
                case "expired_token", "token_expired": throw GitHubFailure.expired
                case "bad_refresh_token", "bad_verification_code": throw GitHubFailure.unauthorized
                case "incorrect_client_credentials", "device_flow_disabled": throw GitHubFailure.configuration
                default: throw GitHubFailure.invalidResponse
                }
            }
            guard let accessToken, tokenType?.lowercased() == "bearer", scope == nil || scope == "",
                  [expiresIn, refreshTokenExpiresIn].allSatisfy({ $0.map { $0.isFinite && (1...31_622_400).contains($0) } ?? true }),
                  (expiresIn == nil && refreshToken == nil && refreshTokenExpiresIn == nil)
                    || (expiresIn != nil && refreshToken != nil && refreshTokenExpiresIn != nil)
            else { throw GitHubFailure.invalidResponse }
            let token = GitHubToken(access: accessToken, refresh: refreshToken,
                                    expiresAt: expiresIn.map { now.addingTimeInterval($0) },
                                    refreshExpiresAt: refreshTokenExpiresIn.map { now.addingTimeInterval($0) })
            guard token.valid else { throw GitHubFailure.invalidResponse }
            return token
        }
    }
}
