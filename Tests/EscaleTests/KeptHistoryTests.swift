import AppKit
import Testing
import WebKit
@testable import Escale

// What a tab made from another takes of its Back and Forward (#60): a
// private tab's and an extension page's stay behind, and a closed tab keeps
// only a light one, so each Space's closed tabs stay bounded. The history
// here is synthetic bytes; no page is loaded.

@MainActor
@Suite struct KeptHistoryTests {
    private let history = Data(repeating: 7, count: 2048)

    private func tab(_ address: String, shy: Bool = false, history: Any?) throws -> Tab {
        // A restored tab looks for its site's icon, which reads the appearance.
        _ = NSApplication.shared
        let tab = Tab(shy: shy, space: UUID(), configuration: WKWebViewConfiguration())
        tab.restore(url: try #require(URL(string: address)), title: "Page", memory: history)
        return tab
    }

    @Test func anOrdinaryTabCarriesItsHistory() throws {
        let tab = try tab("http://127.0.0.1:8080/c", history: history)
        #expect(tab.carried as? Data == history)
    }

    @Test func aTabWithNoHistoryCarriesNothing() throws {
        #expect(try tab("http://127.0.0.1:8080/c", history: nil).carried == nil)
    }

    @Test func aPrivateTabKeepsItsHistoryToItself() throws {
        #expect(try tab("http://127.0.0.1:8080/c", shy: true, history: history).carried == nil)
    }

    @Test(arguments: ["chrome-extension://abcdef/options.html", "webkit-extension://abcdef/options.html"])
    func anExtensionPageKeepsItsHistoryToItself(address: String) throws {
        #expect(try tab(address, history: history).carried == nil)
    }

    private let c = URL(string: "http://127.0.0.1:8080/c")
    private let d = URL(string: "http://127.0.0.1:8080/d")
    private let fresh = Data(repeating: 9, count: 1024)

    @Test(arguments: [true, false])
    func aRestingTabCarriesWhatItKept(hasView: Bool) {
        // Asleep (no view), or waking before its view has a page.
        let kept = Tab.history(resting: true, memory: history, current: hasView ? nil : c, address: c) { fresh }
        #expect(kept as? Data == history)
    }

    @Test func anAwakeTabCarriesItsViewNotAStaleWake() {
        // A wake cancelled before the page took `memory` leaves it set.
        let kept = Tab.history(resting: false, memory: history, current: c, address: c) { fresh }
        #expect(kept as? Data == fresh)
    }

    @Test func aTabSentElsewhereCarriesNothingUntilThePageCommits() {
        // Still loading D, or failed to: the list is still on C.
        var asked = false
        let kept = Tab.history(resting: false, memory: nil, current: c, address: d) { asked = true; return fresh }
        #expect(kept == nil)
        #expect(!asked)
        #expect(Tab.history(resting: false, memory: nil, current: nil, address: d) { fresh } == nil)
    }

    @Test func aClosedTabKeepsALightHistory() {
        let edge = Data(count: Browser.Ghost.heaviest)
        #expect(Browser.Ghost.weighed(edge) as? Data == edge)
        #expect(Browser.Ghost.weighed(history) as? Data == history)
    }

    @Test func aClosedTabDropsAHeavyOrUnknownHistory() {
        #expect(Browser.Ghost.weighed(Data(count: Browser.Ghost.heaviest + 1)) == nil)
        #expect(Browser.Ghost.weighed("not session data") == nil)
        #expect(Browser.Ghost.weighed(nil) == nil)
    }

    @Test func eachSpacesClosedTabsHoldTwoAndAHalfMegabytesAtMost() {
        #expect(Browser.Ghost.kept * Browser.Ghost.heaviest == 2_621_440)
    }
}
