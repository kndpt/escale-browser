import Foundation
import Testing
import WebKit
@testable import Escale

// Screens' rules (Screens.swift, ScreenRuler.swift, ScreenPhone.swift) and
// what screens.js reads from a page: its breakpoints in every way CSS writes
// them, and the one element to fix when the page scrolls sideways. Pages are
// loaded from strings; nothing is fetched.

@MainActor
private final class Landed: NSObject, WKNavigationDelegate {
    var done = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
}

/// What screens.js measures in a 400-point page holding `html`.
@MainActor
private func measured(_ html: String) async throws -> [String: Any] {
    let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
    let landed = Landed()
    web.navigationDelegate = landed
    web.loadHTMLString(html, baseURL: nil)
    for _ in 0..<500 where !landed.done { try await Task.sleep(nanoseconds: 20_000_000) }
    try #require(landed.done)
    let source = Bundled.configured(Bundled.script("screens.js"), with: ["action": "measure", "show": false, "reveal": false, "colour": "red"])
    let value = try await web.evaluateJavaScript(source, contentWorld: .defaultClient)
    return try #require(value as? [String: Any])
}

@MainActor
@Suite struct ScreensTests {
    @Test func everyWayOfWritingABreakpointGivesTheFirstWidthOfItsLayout() async throws {
        let body = try await measured("""
            <style>
            @media (min-width: 640px) { a { color: red } }
            @media (max-width: 767.98px) { a { color: red } }
            @media (width >= 64rem) { a { color: red } }
            @media (width < 80em) { a { color: red } }
            @media (1440px <= width) { a { color: red } }
            @media (min-device-width: 999px) { a { color: red } }
            @supports (display: grid) { @media screen and (max-width: 499px) { a { color: red } } }
            </style>
            """)
        #expect(body["edges"] as? [Int] == [500, 640, 768, 1024, 1280, 1440])
        #expect(body["unread"] as? Int == 0)
    }

    @Test func onlyTheOutermostElementPastTheSideIsOverflow() async throws {
        let wide = try await measured("""
            <body style="margin:0">
            <div style="width:600px"><p style="width:500px">inside</p></div>
            <div style="overflow-x:auto"><div style="width:900px">scrolls in its box</div></div>
            <div style="position:fixed;left:-300px;width:200px;height:20px">drawer</div>
            </body>
            """)
        #expect(wide["overflow"] as? Int == 1)

        let fits = try await measured("<body style=\"margin:0\"><div style=\"width:100%\">fits</div></body>")
        #expect(fits["overflow"] as? Int == 0)
        #expect(fits["edges"] as? [Int] == [])
    }

    @Test func stepsLandOnEachSideOfABreakpoint() {
        let edges = [640, 768]
        #expect(ScreenStep.edge(from: 402, up: true, in: edges) == 639)
        #expect(ScreenStep.edge(from: 639, up: true, in: edges) == 640)
        #expect(ScreenStep.edge(from: 700, up: true, in: edges) == 767)
        #expect(ScreenStep.edge(from: 768, up: true, in: edges) == nil)
        #expect(ScreenStep.edge(from: 700, up: false, in: edges) == 640)
        #expect(ScreenStep.edge(from: 639, up: false, in: edges) == nil)
    }

    @Test func aDragIsCaughtOnlyWithinAFewPointsOfASideOrADevice() {
        // At one point per pixel, four points of reach.
        #expect(ScreenStep.caught(766, perPixel: 1, edges: [768]) == 767)
        #expect(ScreenStep.caught(769.5, perPixel: 1, edges: [768]) == 768)
        #expect(ScreenStep.caught(760, perPixel: 1, edges: [768]) == nil)
        #expect(ScreenStep.caught(401, perPixel: 1, edges: []) == 402)
        // Drawn at half size, the same four points reach twice as far.
        #expect(ScreenStep.caught(760, perPixel: 0.5, edges: [768]) == 767)
    }

    @Test(arguments: [(3.0, 1 / 1.1), (2.625, 0.75823), (2.0, 0.6129), (3.0, 0.33)])
    func aDeviceReadsItsOwnDensityExactly(density: CGFloat, drawn: CGFloat) {
        let factor = Screen.factor(density, over: drawn)
        #expect(Swift.Float(factor) * Swift.Float(drawn) == Swift.Float(density))
    }

    @Test func aRangeRunsFromItsBreakpointToTheNextOneLess() {
        let edges = [640, 768]
        #expect(Screen.range(of: 402, in: edges) == "< 640")
        #expect(Screen.range(of: 640, in: edges) == "640 – 767")
        #expect(Screen.range(of: 767, in: edges) == "640 – 767")
        #expect(Screen.range(of: 1440, in: edges) == "≥ 768")
        #expect(Screen.range(of: 402, in: []) == nil)
    }

    @Test func aLocalAddressMovesToThisMacAndAnyOtherStays() throws {
        let site = try #require(URL(string: "https://example.com/a?b=1"))
        #expect(ScreenPhone.reachable(site) == site)
        #expect(!ScreenPhone.local(site))

        let local = try #require(URL(string: "http://localhost:5173/docs?x=1#top"))
        #expect(ScreenPhone.local(local))
        #expect(ScreenPhone.local(try #require(URL(string: "http://app.localhost:3000/"))))
        #expect(ScreenPhone.local(try #require(URL(string: "http://127.0.0.1:8000/"))))
        // A Mac with no network address has nowhere to send the phone.
        guard let address = ScreenPhone.lanAddress() else {
            #expect(ScreenPhone.reachable(local) == nil)
            return
        }
        #expect(ScreenPhone.reachable(local)?.absoluteString == "http://\(address):5173/docs?x=1#top")
    }
}
