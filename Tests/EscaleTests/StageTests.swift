// A stage let go with WebKit's docked inspector still inside: closing the tab
// or rebuilding the window used to abort Escale as the stage tried to watch
// itself while being freed.
import AppKit
import Testing
import WebKit
@testable import Escale

@MainActor struct StageTests {
    @Test func aStageFreedWithItsInspectorDockedLetsGo() throws {
        let kind = try #require(NSClassFromString("WKInspectorWKWebView") as? WKWebView.Type)
        weak var gone: StageView?
        autoreleasepool {
            let stage = StageView()
            stage.addSubview(kind.init(frame: .zero, configuration: WKWebViewConfiguration()))
            gone = stage
        }
        #expect(gone == nil)
    }
}
