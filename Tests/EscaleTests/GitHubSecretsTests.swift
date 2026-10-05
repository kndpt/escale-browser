// Real Security.framework qualification uses only newly generated fixture
// namespaces, two worlds and two Spaces. Every item contains synthetic text;
// cleanup names those exact services. No Store/Vault or existing key is read.

import Foundation
import Testing
@testable import Escale

@MainActor
@Suite struct GitHubSecretsTests {
    @Test func worldsSpacesAndAccountsStaySeparateAndPairsRotateAtomically() async throws {
        let world = UUID(), space = UUID()
        let first = GitHubSecrets.fixture(world: world, space: space)
        let second = GitHubSecrets.fixture(world: UUID(), space: space)
        let third = GitHubSecrets.fixture(world: world, space: UUID())
        let stores = [first, second, third]
        do {
            let original = githubCredential(at: Date())
            try await first.save(original)
            #expect(try await first.load()?.token.access == original.token.access)
            #expect(try await second.load() == nil)
            #expect(try await third.load() == nil)
            let replacement = GitHubCredential(clientID: original.clientID, authority: original.authority,
                token: GitHubToken(access: "fixture_new_access", refresh: "fixture_new_refresh", expiresAt: Date().addingTimeInterval(100), refreshExpiresAt: Date().addingTimeInterval(200)))
            try await first.save(replacement)
            let reloaded = try await first.load()
            #expect(reloaded?.token.access == "fixture_new_access")
            #expect(reloaded?.token.refresh == "fixture_new_refresh")
            try await second.save(original)
            try await first.erase().value
            #expect(try await first.load() == nil)
            #expect(try await second.load()?.authority == original.authority)
            let other = GitHubCredential(clientID: "fixture", authority: GitHubAuthority(account: GitHubAccount(id: 2, login: "other-fixture"), generation: UUID()), token: replacement.token)
            try await first.save(other)
            #expect(try await first.load()?.authority.account.id == 2)
            #expect(first.service != second.service && first.service != third.service)
            #expect(!String(describing: other).contains("fixture_new_access"))
        } catch {
            for store in stores { try? await store.erase().value }
            throw error
        }
        for store in stores { try await store.erase().value }
    }
}
