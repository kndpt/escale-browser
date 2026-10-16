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
