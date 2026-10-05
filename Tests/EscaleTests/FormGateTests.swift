import Foundation
import Testing
import WebKit
@testable import Escale

// When a tab lets its page ask for or receive passwords (see `formHost` in
// Tab.swift). Pages are local HTML with a synthetic base URL: nothing loads
// from the network and no keychain is read.

@MainActor
@Suite struct FormGateTests {
    private func committed(at host: String, scheme: String = "https") -> Tab {
        let tab = Tab(space: UUID(), configuration: WKWebViewConfiguration())
        tab.web.loadHTMLString("<form></form>", baseURL: URL(string: "\(scheme)://\(host)/"))
        tab.arrived()
        return tab
    }

    @Test func plainHTTPGetsNoPasswordsUnlessItIsThisMac() {
        #expect(committed(at: "account.example.test", scheme: "http").formHost == nil)
        #expect(committed(at: "192.168.1.20", scheme: "http").formHost == nil)
        #expect(committed(at: "localhost", scheme: "http").formHost == "localhost")
        #expect(committed(at: "app.localhost", scheme: "http").formHost == "app.localhost")
        #expect(committed(at: "127.0.0.1", scheme: "http").formHost == "127.0.0.1")
    }

    @Test func loopbackIsOnlyThisMac() {
        for host in ["localhost", "api.localhost", "127.0.0.1", "127.1.2.3", "::1", "[::1]"] {
            #expect(Dialogs.isLoopback(host))
        }
        for host in ["localhost.example.test", "127.0.0.1.example.test", "10.0.0.1", "192.168.1.1", "printer.local", "127.0.0", "127.0.0.256"] {
            #expect(!Dialogs.isLoopback(host))
        }
    }

    @Test func aCommittedPageHasItsFormsWithoutWww() {
        let tab = committed(at: "www.alpha.example.test")
        #expect(tab.formHost == "alpha.example.test")
    }

    @Test func aLoadThatEndsWithoutADocumentGivesTheFormsBack() {
        let tab = committed(at: "alpha.example.test")

        tab.invalidatePageData()
        #expect(tab.formHost == nil)

        tab.stayed()
        #expect(tab.formHost == "alpha.example.test")
    }

    @Test func aFailedLoadKeepsTheFormsClosed() {
        let tab = committed(at: "alpha.example.test")

        tab.invalidatePageData()
        tab.failed("No site at that address.", at: URL(string: "https://beta.example.test/"))
        tab.stayed()

        #expect(tab.formHost == nil)
    }

    @Test func aViewNamingAnotherHostKeepsTheFormsClosed() {
        let tab = committed(at: "alpha.example.test")

        tab.web.loadHTMLString("<form></form>", baseURL: URL(string: "https://beta.example.test/"))
        tab.invalidatePageData()
        tab.stayed()

        #expect(tab.formHost == nil)
    }
}

/// A message as a page would post it, from no committed document: the
/// credentials gate always refuses it.
private final class Posted: WKScriptMessage {
    private let said: [String: Any]
    init(_ said: [String: Any]) { self.said = said }
    override var body: Any { said }
    override var webView: WKWebView? { nil }
}

@MainActor
@Suite struct FormRelayTests {
    @Test func fullscreenAndTypingPassWhileTheGateIsClosed() {
        let tab = Tab(space: UUID(), configuration: WKWebViewConfiguration())
        let relay = FormRelay()
        relay.tab = tab
        let controller = WKUserContentController()

        relay.userContentController(controller, didReceive: Posted(["kind": "fullscreen", "on": true]))
        #expect(tab.immersed)
        relay.userContentController(controller, didReceive: Posted(["kind": "fullscreen", "on": false]))
        #expect(!tab.immersed)

        relay.userContentController(controller, didReceive: Posted(["kind": "focus", "typing": true]))
        #expect(tab.typing)
    }
}
