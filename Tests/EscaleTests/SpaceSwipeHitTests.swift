import Foundation
import Testing
@testable import Escale

// A swipe starting in the enlarged part of the visible chrome must reach the
// spaces; one starting just beyond its edge remains a page gesture.
@Suite @MainActor struct SpaceSwipeHitTests {
    @Test func theFinalSidebarIsAllSwipeable() {
        let width: CGFloat = 232
        let metrics = ChromeMetrics(size: .large)
        let edge = metrics.sidebarFootprint(width, rail: true, folded: false)
        #expect(SpaceSwipe.covers(CGPoint(x: edge - 1, y: 400), height: 780,
                                  sideWidth: edge, sidebar: true, strip: metrics.strip))
        #expect(!SpaceSwipe.covers(CGPoint(x: edge + 1, y: 400), height: 780,
                                   sideWidth: edge, sidebar: true, strip: metrics.strip))
    }

    @Test func theFinalTopStripIsAllSwipeable() {
        let metrics = ChromeMetrics(size: .large)
        let edge = 780 - metrics.strip
        #expect(SpaceSwipe.covers(CGPoint(x: 400, y: edge + 1), height: 780,
                                  sideWidth: 232, sidebar: false, strip: metrics.strip))
        #expect(!SpaceSwipe.covers(CGPoint(x: 400, y: edge - 1), height: 780,
                                   sideWidth: 232, sidebar: false, strip: metrics.strip))
    }
}
