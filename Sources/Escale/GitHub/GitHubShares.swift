// Which accounts have shared repositories with Escale's GitHub App. A
// connection reads public repositories by itself; a private one answers only
// once its owner, the person or an organization, has installed the app and
// chosen it. That choice is made on GitHub's own page (installURL): GitHub lets
// no app pick repositories for anyone, and an organization's owners may have
// to approve a member's request there.
//
// The list costs one request, made only while Settings › GitHub shows a
// connected Space, and is forgotten with the connection. A new list, or a
// person leaving for GitHub's page, means sharing may have changed, so rows
// GitHub refused are asked again on their next showing (GitHubMemory).

import Combine
import Foundation

@MainActor
final class GitHubShares: ObservableObject {
    struct Share: Identifiable, Equatable {
        let id: Int
        let account: String
        /// Every repository of the account, present and future, or a chosen few.
        let all: Bool
        /// GitHub's page for changing that choice.
        let page: URL?
    }

    /// Nil until read for the current connection.
    @Published private(set) var shares: [Share]?
    private let memory: GitHubMemory
    private let access: GitHubAccess
    private let http: GitHubHTTP
    private var reading: Task<Void, Never>?
    private var authority: GitHubAuthority?
    private var connection: AnyCancellable?

    init(memory: GitHubMemory, access: GitHubAccess, http: GitHubHTTP = GitHubHTTP()) {
        self.memory = memory
        self.access = access
        self.http = http
        authority = access.authority
        connection = access.$connection.sink { [weak self] _ in
            guard let self, self.authority != access.authority else { return }
            self.stop()
            self.authority = access.authority
        }
    }

    /// Read again whenever Settings shows the connection, since sharing happens on GitHub.
    func load() {
        guard reading == nil, let authority = access.authority else { return }
        reading = Task {
            defer { if self.authority == authority { self.reading = nil } }
            do {
                let token = try await access.token()
                let reply = try await http.exchange(GitHubHTTP.request(path: "/user/installations", token: token.access))
                try Task.checkCancellation()
                guard access.authority == authority else { return }
                try GitHubAccess.requireSuccess(reply, at: Date())
                let found = try Self.shares(reply.data)
                if shares != found { shares = found }
                memory.retryRefused()
            } catch {
                // The list is a convenience: the button to share stays, and rows keep their own failures.
            }
        }
    }

    /// The person is going to GitHub's page to share repositories.
    func sharing() { memory.retryRefused() }

    func stop() {
        reading?.cancel()
        reading = nil
        shares = nil
    }

    static func shares(_ data: Data) throws -> [Share] {
        struct Payload: Decodable {
            let installations: [Installation]
            struct Installation: Decodable {
                let id: Int
                let account: Account?
                let repositorySelection: String
                let htmlUrl: String?
                struct Account: Decodable { let login: String }
            }
        }
        let value = try GitHubAccess.decode(Payload.self, data)
        return value.installations.compactMap { installation in
            guard let login = installation.account?.login, !login.isEmpty, login.utf8.count <= 100 else { return nil }
            let page = installation.htmlUrl.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" && $0.host == "github.com" ? $0 : nil }
            return Share(id: installation.id, account: login, all: installation.repositorySelection == "all", page: page)
        }
        .sorted { $0.account.localizedCaseInsensitiveCompare($1.account) == .orderedAscending }
    }
}
