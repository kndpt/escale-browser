// Welcome steps aside while the GitHub code is typed and comes back on
// GitHub's answer: the last step once connected, the GitHub step on a failure,
// and not at all when the code is cancelled from Settings.

import Foundation
import Testing
@testable import Escale

@MainActor
@Suite struct WelcomeReturnTests {
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(condition())
    }

    private func access(_ credential: GitHubCredential?) -> GitHubAccess {
        let secrets = GitHubTestSecrets()
        secrets.value = credential
        return GitHubAccess(space: UUID(), configuration: .init(clientID: "fixture"), secrets: secrets)
    }

    @Test func aConnectionLeadsToTheLastStep() async {
        let welcome = WelcomeReturn(), access = access(githubCredential(at: Date()))
        var answers: [WelcomePanel.Step] = []
        welcome.watch(access) { answers.append($0) }
        await access.restore()
        await settle { !answers.isEmpty }
        #expect(answers == [.done])
        #expect(welcome.step == .done)
    }

    @Test func aFailureLeadsBackToTheGitHubStep() async {
        let other = githubCredential(at: Date())
        let foreign = GitHubCredential(clientID: "other", authority: other.authority, token: other.token)
        let welcome = WelcomeReturn(), access = access(foreign)
        var answers: [WelcomePanel.Step] = []
        welcome.watch(access) { answers.append($0) }
        await access.restore()
        await settle { !answers.isEmpty }
        #expect(answers == [.github])
    }

    @Test func aCancelledCodeEndsTheWaitWithoutAnAnswer() async throws {
        let welcome = WelcomeReturn(), access = access(githubCredential(at: Date()))
        var answers: [WelcomePanel.Step] = []
        welcome.watch(access) { answers.append($0) }
        access.cancelConnection()
        try await Task.sleep(nanoseconds: 20_000_000)
        await access.restore()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(answers.isEmpty)
        #expect(welcome.step == nil)
    }
}
