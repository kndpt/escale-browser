import Foundation
import Testing
import WebKit
@testable import Escale

// An answer from the page is taken only while it answers the question on
// screen (see Find.swift). Two local pages, loaded from strings; nothing is
// fetched.

@MainActor
private final class Loaded: NSObject, WKNavigationDelegate {
    var done = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
}

/// A web view holding `html`, once it has finished loading.
@MainActor
private func page(_ html: String) async throws -> WKWebView {
    let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
    let loaded = Loaded()
    web.navigationDelegate = loaded
    web.loadHTMLString(html, baseURL: nil)
    // Counted in sleeps, not wall time: a CI runner can stall the main
    // thread for seconds, and a clock deadline would spend itself meanwhile.
    for _ in 0..<500 where !loaded.done { try await Task.sleep(nanoseconds: 20_000_000) }
    #expect(loaded.done)
    return web
}

/// Until `condition` holds, or two seconds of sleeps pass.
@MainActor
private func waited(_ condition: () -> Bool) async throws {
    for _ in 0..<100 where !condition() { try await Task.sleep(nanoseconds: 20_000_000) }
}

@MainActor
@Suite struct FindTests {
    @Test func aWordThePageLacksIsMissedAndOneItHoldsIsNot() async throws {
        let web = try await page("<p>an apple and a banana</p>")
        let find = Find(page: { web })

        find.needle = "cherry"
        try await waited { find.missed }
        #expect(find.missed)

        find.needle = "banana"
        try await waited { !find.missed }
        #expect(!find.missed)
    }

    @Test func anAnswerForAPageNoLongerOnScreenIsNotTaken() async throws {
        let first = try await page("<p>an apple</p>")
        let second = try await page("<p>a cherry</p>")
        var onScreen = first
        let find = Find(page: { onScreen })

        // Asked of the first page, which lacks it; the second is on screen
        // before the answer comes, and holds it.
        find.needle = "cherry"
        onScreen = second
        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(!find.missed)
    }
}
