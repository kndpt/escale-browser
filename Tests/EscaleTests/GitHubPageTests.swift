// The page script on local copies of GitHub's two label markups, as seen in
// October 2026, loaded from strings: nothing is fetched. These prove the
// reading rule, not that GitHub still draws its pages this way.

import Foundation
import Testing
import WebKit
@testable import Escale

@MainActor
private final class Loaded: NSObject, WKNavigationDelegate {
    var done = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
}

@MainActor
@Suite struct GitHubPageTests {
    private func token(_ html: String) async throws -> String? {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let loaded = Loaded()
        web.navigationDelegate = loaded
        web.loadHTMLString(html, baseURL: nil)
        // Counted in sleeps, not wall time: a CI runner can stall the main
        // thread for seconds, and a clock deadline would spend itself meanwhile.
        for _ in 0..<500 where !loaded.done { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(loaded.done)
        let value = try await web.evaluateJavaScript(GitHubPage.script, in: nil, contentWorld: .defaultClient)
        return value as? String
    }

    @Test func primerAndOlderLabelsAreReadWhenTheyAgree() async throws {
        let primer = #"<span class="prc-StateLabel-StateLabel-Iawzp flex-self-start" data-status="pullMerged">Merged</span>"#
        #expect(try await token(primer + primer) == "pullMerged")
        let older = #"<span title="Status: Merged" class="State State--merged">Merged</span><span class="State State--merged State--small">Merged</span>"#
        #expect(try await token(older) == "State--merged")
        #expect(try await token(#"<span class="prc-StateLabel-StateLabel-x" data-status="issueOpened">Open</span>"#) == "issueOpened")
    }

    @Test func primerLabelsOutweighOlderOnesForMentionedObjects() async throws {
        // A closed pull request whose conversation lists merged ones.
        let header = #"<span class="prc-StateLabel-StateLabel-x" data-status="pullClosed">Closed</span>"#
        let mentioned = #"<span class="State State--merged">Merged</span>"#
        #expect(try await token(header + header + mentioned + mentioned) == "pullClosed")
    }

    @Test func disagreeingMissingOrForeignMarkupIsUnknown() async throws {
        #expect(try await token("<p>Merged</p>") == nil)
        #expect(try await token(#"<span class="prc-StateLabel-StateLabel-x" data-status="pullOpened">Open</span><span class="prc-StateLabel-StateLabel-x" data-status="issueClosed">Closed</span>"#) == nil)
        // A data-status outside a state label is somebody else's.
        #expect(try await token(#"<div data-status="pullMerged"></div>"#) == nil)
    }

    @Test func tokensMapOnlyToTheirOwnKind() {
        #expect(GitHubPage.state("pullOpened", kind: .pull) == .open)
        #expect(GitHubPage.state("draft", kind: .pull) == .draft)
        #expect(GitHubPage.state("State--draft", kind: .pull) == .draft)
        #expect(GitHubPage.state("pullMerged", kind: .pull) == .merged)
        #expect(GitHubPage.state("pullClosed", kind: .pull) == .closed)
        #expect(GitHubPage.state("issueOpened", kind: .issue) == .open)
        #expect(GitHubPage.state("issueClosedNotPlanned", kind: .issue) == .closed)
        #expect(GitHubPage.state("pullMerged", kind: .issue) == nil)
        #expect(GitHubPage.state("issueOpened", kind: .pull) == nil)
        #expect(GitHubPage.state("draft", kind: .issue) == nil)
        #expect(GitHubPage.state("unavailable", kind: .pull) == nil)
    }
}
