// Welcome pauses, rather than ends, while the GitHub device code is typed on
// github.com: that tab needs the window Welcome covers. It keeps where it
// stood and comes back by itself when GitHub answers, on its last step once
// connected, on the GitHub step to explain a failure, even over Settings, so
// setup is never left unfinished. Only that one connection is watched, and
// only until it answers; only the tab Welcome opened is closed. Kept in
// memory only: quitting meanwhile leaves Welcome unfinished, and it starts
// again next time.
import Combine
import Foundation

@MainActor
final class WelcomeReturn {
    /// Where Welcome opens next while it is unfinished; nil from the start.
    private(set) var step: WelcomePanel.Step?
    /// Whether this setup imported anything, for the last step's summary.
    var imported = false
    private var wait: AnyCancellable?
    /// The tab opened for the code, the only one closed once GitHub agrees.
    private weak var codeTab: Tab?

    /// Hides Welcome, opens GitHub's page and brings Welcome back once GitHub answers.
    func pause(_ browser: Browser, for access: GitHubAccess, at url: URL) {
        step = .github
        browser.welcoming = false
        browser.openGitHub(url)
        codeTab = browser.active
        watch(access) { [weak self, weak browser] step in
            guard let browser else { return }
            if step == .done, let tab = self?.codeTab, tab.address.map(Self.isCodePage) == true { browser.close(tab) }
            browser.welcoming = true
        }
    }

    /// Calls back once with the step GitHub's answer leads to. A cancelled
    /// code (from Settings) ends the wait without bringing Welcome back.
    func watch(_ access: GitHubAccess, answered: @escaping (WelcomePanel.Step) -> Void) {
        // Only a change answers; it is read after it lands, not in willSet.
        wait = access.$connection.dropFirst().receive(on: RunLoop.main).sink { [weak self] connection in
            guard let self else { return }
            switch connection {
            case .connecting, .authorizing, .disconnecting: return
            case .local: self.wait = nil
            case .connected: self.finish(.done, answered)
            case .unavailable: self.finish(.github, answered)
            }
        }
    }

    func end() {
        step = nil
        imported = false
        wait = nil
        codeTab = nil
    }

    private func finish(_ next: WelcomePanel.Step, _ answered: (WelcomePanel.Step) -> Void) {
        wait = nil
        step = next
        answered(next)
    }

    private static func isCodePage(_ url: URL) -> Bool {
        url.host == "github.com" && url.path.hasPrefix("/login/device")
    }
}
