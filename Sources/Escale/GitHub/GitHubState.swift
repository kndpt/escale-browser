// A successful observation says what one source knew at one instant, not what
// GitHub must say now. Failures and access loss are separate from object state,
// and freshness is evaluated when read, without an idle timer or a false new
// verification date after a failed request. No credentials enter these values.

import Foundation

enum GitHubState: String, Codable { case open, draft, closed, merged, unknown }

struct GitHubAccount: Codable, Hashable {
    let id: Int
    let login: String

    var valid: Bool { id > 0 && !login.isEmpty && login.utf8.count <= 100 }
}

struct GitHubAuthority: Codable, Hashable {
    let account: GitHubAccount
    /// Replaced on each new authorization, even for the same GitHub account.
    let generation: UUID
}

enum GitHubConnection: Equatable {
    case local
    case connecting, disconnecting
    case authorizing(code: String, expiresAt: Date)
    case connected(GitHubAccount)
    case unavailable(GitHubFailure)
}

enum GitHubFailure: String, Codable, Error {
    case offline, rateLimited, unauthorized, forbidden, notFound, invalidResponse, unavailable, cancelled
    case configuration, expired, denied, storage

    /// A forbidden/quota response must be classified by the transport first.
    var invalidatesObservation: Bool {
        self == .unauthorized || self == .forbidden || self == .notFound
    }

    /// GitHub hides a private repository the app was not given as missing or forbidden.
    var refused: Bool { self == .forbidden || self == .notFound }
}

struct GitHubObservation: Codable, Equatable {
    enum Source: Codable, Equatable {
        case page
        case api(GitHubAuthority)
    }

    let state: GitHubState
    let source: Source
    let observedAt: Date

    static let freshFor: TimeInterval = 5 * 60

    func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(observedAt)
        return age >= 0 && age < Self.freshFor
    }

    func valid(for id: GitHubItem.ID) -> Bool {
        guard observedAt.timeIntervalSince1970.isFinite,
              id.kind == .pull || (state != .merged && state != .draft) else { return false }
        if case .api(let authority) = source { return authority.account.valid }
        return true
    }
}

struct GitHubReading: Equatable {
    let observation: GitHubObservation?
    let failure: GitHubFailure?
    /// When the failure came; a refusal is asked again once it is this old.
    var failedAt: Date? = nil

    /// Unknown, stale and failed readings never acquire a current-state sort weight.
    func current(at now: Date) -> GitHubState? {
        guard failure == nil, let observation, observation.isFresh(at: now), observation.state != .unknown else { return nil }
        return observation.state
    }

    /// Refused within the freshness window: not asked again before then, unless
    /// sharing changed (GitHubMemory.retryRefused). Sharing a private repository
    /// on GitHub reaches Escale by itself at most this late.
    func refused(at now: Date) -> Bool {
        guard failure?.invalidatesObservation == true else { return false }
        guard let failedAt else { return true }
        return now.timeIntervalSince(failedAt) < GitHubObservation.freshFor
    }
}
