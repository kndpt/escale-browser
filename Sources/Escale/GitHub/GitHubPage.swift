// Without a connection, the only state Bearings can know is the one a page
// already on screen shows. It is read once, when Bearings lists that page:
// never a build, wake or load for it, nothing installed in the page, and the
// read runs in WebKit's isolated client world (github-state.js). A private tab
// answers only a private cache, so nothing it shows reaches a file.
//
// The answer counts only if the tab still holds the same view, at the same
// load, on the same object; otherwise the ticket is cancelled and the state
// stays what it was. GitHub's markup can change: a label it does not know, or
// labels that disagree, leave the object unknown rather than guessed. The date
// is the read's: GitHub keeps the header label of these pages updated live.

import Foundation
import WebKit

@MainActor
enum GitHubPage {
    static let script = Bundled.script("github-state.js")

    /// Reads the state `tab` shows for `item` into `memory`, if it is loaded.
    static func read(_ tab: Tab, as item: GitHubItem.ID, into memory: GitHubMemory, now: @escaping () -> Date = Date.init) {
        guard tab.shy == memory.isPrivate, let web = tab.built, shows(web, item),
              let ticket = memory.request(item, api: false) else { return }
        let asked = tab.dataRevision
        web.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak tab, weak web, weak memory] result in
            guard let memory else { return }
            guard let tab, let web, tab.built === web, tab.dataRevision == asked, shows(web, item),
                  case .success(let value) = result, let token = value as? String,
                  let state = state(token, kind: item.kind)
            else { memory.cancel(ticket); return }
            memory.receive(state, at: now(), for: ticket)
        }
    }

    private static func shows(_ web: WKWebView, _ item: GitHubItem.ID) -> Bool {
        guard !web.isLoading, let url = web.url else { return false }
        return GitHubItem.ID(url: url, space: item.space) == item
    }

    /// GitHub's label names, Primer's and the older State-- classes alike.
    static func state(_ token: String, kind: GitHubItem.ID.Kind) -> GitHubState? {
        switch (kind, token) {
        case (.pull, "pullOpened"), (.pull, "pullQueued"), (.pull, "State--open"),
             (.issue, "issueOpened"), (.issue, "State--open"):
            return .open
        case (.pull, "draft"), (.pull, "State--draft"):
            return .draft
        case (.pull, "pullMerged"), (.pull, "State--merged"):
            return .merged
        case (.pull, "pullClosed"), (.pull, "State--closed"),
             (.issue, "issueClosed"), (.issue, "issueClosedNotPlanned"), (.issue, "State--closed"):
            return .closed
        default:
            return nil
        }
    }
}
