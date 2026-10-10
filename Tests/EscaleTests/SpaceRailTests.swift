import Foundation
import Testing
@testable import Escale

// The rail is a vertical, fixed-width anchor rather than the old horizontal
// space row. These checks keep its hit boxes inside the rail, land a dragged
// icon on a whole door, and preserve the column's independent width when the
// rail is added to the window.
@Suite @MainActor struct SpaceRailTests {
    @Test func everySpaceDoorFitsInsideTheRail() {
        let metrics = ChromeMetrics(size: .standard)
        let rail = metrics.spaceRailWidth
        let icon = metrics.length(SpaceRail.icon)
        #expect(rail == 54)
        #expect(icon <= rail)
        #expect(metrics.spaceRailInset > 0)
        #expect(metrics.length(SpaceRail.glyph) < icon)
        #expect(metrics.spaceRailGap == 0)
        #expect(Motion.fadeDuration == 0.5)
    }

    @Test func theRailIsPresentForOneSpace() {
        let metrics = ChromeMetrics(size: .standard)
        let open = metrics.sidebarFootprint(Metrics.side, rail: true, folded: false)
        let folded = metrics.sidebarFootprint(Metrics.side, rail: true, folded: true)
        #expect(folded == metrics.spaceRailWidth)
        #expect(open > folded)
    }

    @Test func disablingSpacesKeepsTheOriginalColumnGeometry() {
        let metrics = ChromeMetrics(size: .standard)
        #expect(metrics.sidebarFootprint(Metrics.side, rail: false, folded: false) == metrics.sidebarWidth(Metrics.side))
        #expect(metrics.sidebarFootprint(Metrics.side, rail: false, folded: true) == 0)
    }

    /// A held icon lands one door per step travelled, past half a step, and
    /// never beyond the first or last Space.
    @Test func aDraggedIconLandsByWholeDoors() {
        let step = ChromeMetrics(size: .standard).length(SpaceRail.icon + SpaceRail.gap)
        #expect(SpaceReorder.landing(from: 2, travel: -2 * step, step: step, count: 4) == 0)
        #expect(SpaceReorder.landing(from: 2, travel: -0.4 * step, step: step, count: 4) == 2)
        #expect(SpaceReorder.landing(from: 2, travel: 0.6 * step, step: step, count: 4) == 3)
        #expect(SpaceReorder.landing(from: 0, travel: -5 * step, step: step, count: 4) == 0)
        #expect(SpaceReorder.landing(from: 1, travel: 9 * step, step: step, count: 4) == 3)
        #expect(SpaceReorder.landing(from: 0, travel: step, step: step, count: 0) == 0)
    }

    /// Only the doors between the held one and its landing step aside, towards
    /// the place it left.
    @Test func theDoorsPassedStepAside() {
        #expect((0..<4).map { SpaceReorder.shift($0, from: 2, to: 0) } == [1, 1, 0, 0])
        #expect((0..<4).map { SpaceReorder.shift($0, from: 0, to: 2) } == [0, -1, -1, 0])
        #expect((0..<4).map { SpaceReorder.shift($0, from: 1, to: 1) } == [0, 0, 0, 0])
    }

    /// The lights stay where they are when the column folds: the line over
    /// the page, which then starts at the rail, steps clear of them so back
    /// is not drawn behind them. AppKit's three buttons end 79 points in.
    @Test func theFoldedLineClearsTheTrafficLights() {
        let lightsEnd: CGFloat = 79
        for size in InterfaceSize.allCases {
            let metrics = ChromeMetrics(size: size)
            #expect(metrics.lightsClear > lightsEnd)
            for rail in [true, false] {
                let folded = metrics.sidebarFootprint(Metrics.side, rail: rail, folded: true)
                let start = folded + AddressBar.inset(metrics)
                #expect(start + metrics.clearingLights(from: start) >= metrics.lightsClear)
                let open = metrics.sidebarFootprint(Metrics.side, rail: rail, folded: false)
                #expect(metrics.clearingLights(from: open + AddressBar.inset(metrics)) == 0)
            }
        }
    }
}
