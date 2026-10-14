import AppKit
import WebKit
import Combine

// chrome.identity: launchWebAuthFlow in a tab of its own, and the
// Google-only calls refused the way Chrome refuses them without an account.

@available(macOS 15.4, *)
extension ExtensionShims {
    static func identity(_ asked: Asked) async throws -> Any? {
        let api = asked.api
        let first = asked.first
        let id = asked.id
        let browser = asked.browser
        let owner = asked.owner
        switch api {
        // MARK: identity
        case "identity.launchWebAuthFlow":
            let spec = first as? [String: Any] ?? [:]
            guard let url = (spec["url"] as? String).flatMap(URL.init(string:)) else { throw Unsupported(what: "No authorization url") }
            guard browser.spaceID == owner.here else { throw Unsupported(what: "This space is parked") }
            return try await ExtensionAuth.run(url, extension: id, browser: browser).absoluteString
        case "identity.getProfileUserInfo":
            return ["email": "", "id": ""]
        case "identity.removeCachedAuthToken", "identity.clearAllCachedAuthTokens":
            return nil
        case "identity.getAuthToken":
            throw Unsupported(what: "getAuthToken needs a Google account signed into Chrome; this extension would need launchWebAuthFlow instead")

        default:
            throw unknown(api)
        }
    }
}

/// chrome.identity.launchWebAuthFlow: a tab for the provider's sign-in, and
/// the moment it tries to go to https://<id>.chromiumapp.org/, that address
/// is the answer and the tab goes. Browser asks `intercept` about every
/// navigation; nothing is ever loaded from chromiumapp.org.
@MainActor
enum ExtensionAuth {
    private static var waiting: [String: (tab: Tab.ID, finish: (Result<URL, Error>) -> Void)] = [:]
    private static var watch: AnyCancellable?

    static var pending: Int { waiting.count }

    /// A deleted Space cannot leave an extension's OAuth continuation waiting
    /// for a redirect from a tab that no longer exists (see Spaces.swift).
    static func cancel(in space: UUID) {
        let prefix = space.uuidString + "/"
        for (key, entry) in waiting where key.hasPrefix(prefix) {
            waiting[key] = nil
            entry.finish(.failure(Declined()))
        }
        if waiting.isEmpty { watch = nil }
    }

    struct Declined: LocalizedError {
        var errorDescription: String? { "The user did not approve access." }
    }

    static func run(_ url: URL, extension id: String, browser: Browser) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let scope = browser.spaceID.uuidString + "/" + id
            waiting[scope]?.finish(.failure(Declined()))
            let tab = browser.open(url, foreground: true)
            waiting[scope] = (tab.id, { result in continuation.resume(with: result) })
            // Closing the tab is saying no.
            watch = browser.$tabs.sink { tabs in
                for (key, entry) in waiting where !(tabs + browser.parkedTabs).contains(where: { $0.id == entry.tab }) {
                    waiting[key] = nil
                    entry.finish(.failure(Declined()))
                }
                if waiting.isEmpty { watch = nil }
            }
        }
    }

    /// True when the address is an extension's OAuth redirect arriving in
    /// the tab that began the sign-in, which is then handed over and never
    /// loaded. Any page can go to an address shaped like one of these, and
    /// what it carries would be delivered as the flow's answer: only the
    /// tab the flow was started in may finish it, or a window that tab's
    /// page opened, since some providers finish the sign-in in a popup.
    static func intercept(_ url: URL, browser: Browser, from webView: WKWebView) -> Bool {
        guard let host = url.host()?.lowercased(), host.hasSuffix(".chromiumapp.org") else { return false }
        let id = String(host.dropLast(".chromiumapp.org".count))
        guard let from = browser.tab(for: webView),
              let entry = waiting[from.space.uuidString + "/" + id],
              from.id == entry.tab || from.opener == entry.tab
        else { return false }
        waiting.removeValue(forKey: from.space.uuidString + "/" + id)
        entry.finish(.success(url))
        if waiting.isEmpty { watch = nil }
        // The popup, when the answer came in one, goes with the flow's tab:
        // left behind, it would hold a redirect that never loads.
        if from.id != entry.tab { browser.close(from) }
        if let tab = (browser.tabs + browser.parkedTabs).first(where: { $0.id == entry.tab }) { browser.close(tab) }
        return true
    }
}
