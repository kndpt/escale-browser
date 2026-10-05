import Foundation
import Testing
@testable import Escale

// A tab held in a sidebar stays under the pointer: rows and pointer movement
// share the same final points, with no transformed coordinate space.
@Suite @MainActor struct SideDragTests {
    @Test func aFinalDragMovesTheLayoutByTheSameVisibleDistance() {
        for size in [InterfaceSize.compact, .standard, .large] {
            let metrics = ChromeMetrics(size: size)
            let row = metrics.length(28 + 2)
            let window = CGSize(width: 10, height: row)
            let moved = SideBar.layout(window)
            #expect(abs(moved.width - window.width) < 0.001, "\(size)")
            #expect(abs(moved.height - window.height) < 0.001, "\(size)")
        }
    }

    @Test func aLargeDragShortOfTwoRowsCrossesOnlyOne() {
        let row = ChromeMetrics(size: .large).length(28 + 2)
        let moved = SideBar.layout(CGSize(width: 0, height: 1.4 * row))
        #expect(Int((moved.height / row).rounded()) == 1)
    }
}
