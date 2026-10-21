import AppKit
import WebKit

// The questions a page is allowed to ask, and the answers it gets.
//
// WebKit does nothing with alert(), confirm(), prompt(), a file input or a
// password-protected site unless somebody answers for them — and "nothing"
// means confirm() is always false, so "leave without saving?" leaves, and a
// file picker that never opens. Each one here is the system's own sheet on the
// window the page is in, which is what every other browser on this Mac shows.
//
// A sheet holds the whole window, so a page that asks again the moment it is
// answered would hold it for good: from its second question since it last
// navigated, the sheet offers to stop it, and once stopped it is answered at
// once, as if cancelled. A page behind another tab asks nobody until its tab
// is shown, rather than over the page you are looking at.

extension Browser {
    // MARK: - alert, confirm, prompt

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = Dialogs.alert(from: frame, saying: message)
        alert.addButton(withTitle: "OK")
        Dialogs.ask(alert, from: webView) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = Dialogs.alert(from: frame, saying: message)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        Dialogs.ask(alert, from: webView) { answer in
            completionHandler(answer == .alertFirstButtonReturn)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = Dialogs.alert(from: frame, saying: prompt)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        Dialogs.ask(alert, from: webView) { answer in
            completionHandler(answer == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    // MARK: - choosing a file

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.resolvesAliases = true
        let finish: (NSApplication.ModalResponse) -> Void = { answer in
            completionHandler(answer == .OK ? panel.urls : nil)
        }
        Dialogs.present(over: webView, { panel.beginSheetModal(for: $0, completionHandler: finish) }) { finish(.cancel) }
    }

    // MARK: - a site that asks who you are, or can't prove who it is

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            trust(webView, challenge, completionHandler)
        case NSURLAuthenticationMethodHTTPBasic,
             NSURLAuthenticationMethodHTTPDigest,
             NSURLAuthenticationMethodNTLM:
            signIn(webView, challenge, completionHandler)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    /// Every https connection comes through here, not only the broken ones,
    /// so the certificate is checked first and the system is left to it when
    /// it holds up. When it doesn't: a server on this Mac is taken on trust,
    /// because that is where self-signed certificates live. Anything else,
    /// a .local name or a private address included, is asked about once per
    /// site per launch, and only for the page itself, never for something a
    /// page pulled in: on a shared network, any machine can claim those.
    private func trust(
        _ webView: WKWebView,
        _ challenge: URLAuthenticationChallenge,
        _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = challenge.protectionSpace.host.lowercased()
        if Dialogs.isLoopback(host) || Dialogs.excused.contains(host) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        // A picture, a script, a font from a site with a bad certificate is
        // simply not loaded. Only the page you asked for is worth a question.
        guard let tab = tab(for: webView),
              (tab.address?.host() ?? tab.pending?.host())?.lowercased() == host
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "\(host) can't prove who it is"
        alert.informativeText = "Its certificate isn't trusted by this Mac. Someone could be reading what you send. Continue only if you know why it looks like this."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Go Back")
        alert.addButton(withTitle: "Continue Anyway")
        Dialogs.show(alert, over: webView) { answer in
            guard answer == .alertSecondButtonReturn else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            Dialogs.excused.insert(host)
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    /// A site behind a name and a password — a staging server, a router. One
    /// wrong answer gets another go; the second is taken as "not for me".
    private func signIn(
        _ webView: WKWebView,
        _ challenge: URLAuthenticationChallenge,
        _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.previousFailureCount < 2 else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let space = challenge.protectionSpace
        let alert = NSAlert()
        alert.messageText = "\(space.host) asks you to sign in"
        alert.informativeText = space.realm.map { "“\($0)”" } ?? "The site wants a name and a password."
        if challenge.previousFailureCount > 0 {
            alert.informativeText += "\nThat wasn't accepted — try again."
        }
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        let name = NSTextField(frame: NSRect(x: 0, y: 32, width: 260, height: 24))
        name.placeholderString = "Name"
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        pass.placeholderString = "Password"
        name.nextKeyView = pass
        box.addSubview(name)
        box.addSubview(pass)
        alert.accessoryView = box
        alert.window.initialFirstResponder = name

        Dialogs.show(alert, over: webView) { answer in
            guard answer == .alertFirstButtonReturn else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(
                .useCredential,
                URLCredential(user: name.stringValue, password: pass.stringValue, persistence: .forSession)
            )
        }
    }

    // MARK: - a page whose process went away

    /// WebKit runs each page in a process of its own, and the system kills
    /// those under memory pressure — background tabs first. Left alone, the
    /// tab shows white until somebody thinks to reload. Saying so, with the
    /// one thing worth offering, is what the failure view is for.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // A question its page can no longer hear isn't worth showing later.
        (webView as? PageView).map(Dialogs.refuseHeld)
        guard let tab = tab(for: webView) else { return }
        tab.calls.lost(reason: "The page's process ended; WebKit's collection went with it.")
        // In front of you: straight back, a reload beats a white page with a
        // button on it. Behind another tab: the moment you come back to it.
        if tab.id == activeID, !tab.isBlank {
            tab.recoverFromCrash()
        } else {
            tab.stale = true
        }
    }
}

enum Dialogs {
    /// Sites with bad certificates that were accepted, for this launch only.
    static var excused = Set<String>()

    static func alert(from frame: WKFrameInfo, saying message: String) -> NSAlert {
        let alert = NSAlert()
        // The site's name as the title, so a page can't dress its message up
        // as one from the system or from the browser.
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? "This page says" : host
        alert.informativeText = message
        alert.alertStyle = .informational
        return alert
    }

    /// The checkbox a sheet offers from a page's second question on.
    static let stopAsking = "Don't let this page ask again"

    /// How far a page has gone asking since it last navigated: how many
    /// questions, and whether you stopped it. One per page, so another tab,
    /// or this one on its next page, asks as before.
    struct Asking {
        private(set) var count = 0
        private(set) var stopped = false

        /// One more question; whether its sheet offers to stop the page.
        mutating func ask() -> Bool {
            count += 1
            return count > 1
        }

        mutating func stop() { stopped = true }

        /// A new document: a change of address within the page isn't one.
        mutating func navigated() { self = Asking() }
    }

    /// A question waiting for its page to be in a window.
    struct Held {
        let show: (NSWindow) -> Void
        let refuse: () -> Void
    }

    /// A page's alert, confirm or prompt. Once you stop the page, alert
    /// returns, confirm says no and prompt gives nothing, without a sheet.
    static func ask(
        _ alert: NSAlert,
        from webView: WKWebView,
        then finish: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        guard let page = webView as? PageView else { show(alert, over: webView, then: finish); return }
        guard !page.asking.stopped else { finish(.cancel); return }
        alert.showsSuppressionButton = page.asking.ask()
        if alert.showsSuppressionButton { alert.suppressionButton?.title = stopAsking }
        show(alert, over: page) { [weak page] answer in
            if alert.showsSuppressionButton, alert.suppressionButton?.state == .on { page?.asking.stop() }
            finish(answer)
        }
    }

    static func show(
        _ alert: NSAlert,
        over webView: WKWebView,
        then finish: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        present(over: webView, { alert.beginSheetModal(for: $0, completionHandler: finish) }) { finish(.cancel) }
    }

    /// On the page's own window, or held until the page is in one: a tab
    /// that isn't on stage has no window, and the browser's would put its
    /// question over another page. Refused if it can't wait.
    static func present(over webView: WKWebView, _ show: @escaping (NSWindow) -> Void, otherwise refuse: @escaping () -> Void) {
        if let window = webView.window { show(window); return }
        guard let page = webView as? PageView else { refuse(); return }
        page.held.append(Held(show: show, refuse: refuse))
    }

    /// The page has come on stage: what it asked meanwhile, in order. A
    /// window queues a sheet behind the one it shows.
    static func showHeld(_ page: PageView) {
        guard let window = page.window, !page.held.isEmpty else { return }
        let held = page.held
        page.held = []
        held.forEach { $0.show(window) }
    }

    /// The page is going: WebKit waits for every answer, so each is given.
    static func refuseHeld(_ page: PageView) {
        let held = page.held
        page.held = []
        held.forEach { $0.refuse() }
    }

    /// This Mac itself: nothing on the network can stand in for it, so its
    /// self-signed certificates are taken on trust.
    static func isLoopback(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.first == "127" && parts.allSatisfy { UInt8($0) != nil }
    }
}
