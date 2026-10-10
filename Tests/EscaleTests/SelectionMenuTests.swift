// The menu over selected text: where it goes, what a page may post, and the
// shapes of its arrival. Drawing and WebKit are left to the app journey.
import Foundation
import Testing
@testable import Escale

@Suite struct SelectionMenuTests {
    private let page = CGSize(width: 800, height: 600)
    private let menu = CGSize(width: 150, height: 36)

    @Test func aSingleLineGetsTheMenuBelowWithCopyUnderThePointer() {
        let spot = SelectionSpot(x: 300, lineTop: 100, lineBottom: 120, top: 100, bottom: 120)
        #expect(!spot.above)
        let origin = spot.origin(for: menu, in: page)
        #expect(origin.x == 300 - Metrics.selectionButton / 2)
        #expect(origin.y == 120 + Metrics.selectionOffset)
    }

    @Test func releasedOnTheLastLineTheMenuStaysClearOfTheLinesAbove() {
        let spot = SelectionSpot(x: 200, lineTop: 180, lineBottom: 200, top: 100, bottom: 200)
        #expect(!spot.above)
        #expect(spot.origin(for: menu, in: page).y == 200 + Metrics.selectionOffset)
    }

    @Test func selectedUpwardsTheMenuGoesAboveTheFirstLine() {
        let spot = SelectionSpot(x: 200, lineTop: 100, lineBottom: 120, top: 100, bottom: 200)
        #expect(spot.above)
        #expect(spot.origin(for: menu, in: page).y == 100 - Metrics.selectionOffset - menu.height)
    }

    @Test func noRoomOnOneSideSendsItToTheOtherSideOfTheSelection() {
        let low = SelectionSpot(x: 200, lineTop: 560, lineBottom: 580, top: 500, bottom: 580)
        #expect(low.origin(for: menu, in: page).y == 500 - Metrics.selectionOffset - menu.height)
        let high = SelectionSpot(x: 200, lineTop: 4, lineBottom: 24, top: 4, bottom: 90)
        #expect(high.origin(for: menu, in: page).y == 90 + Metrics.selectionOffset)
    }

    @Test func theMenuNeverLeavesThePage() {
        for x in [-50.0, 0, 790, 2000] {
            let spot = SelectionSpot(x: x, lineTop: 0, lineBottom: 600, top: 0, bottom: 600)
            let origin = spot.origin(for: menu, in: page)
            #expect(origin.x >= Metrics.selectionMargin)
            #expect(origin.x + menu.width <= page.width - Metrics.selectionMargin)
            #expect(origin.y >= Metrics.selectionMargin)
            #expect(origin.y + menu.height <= page.height - Metrics.selectionMargin)
        }
    }

    @Test func aPagesMessageIsReadInPointsAndCheckedFirst() throws {
        // A 1000-pixel viewport in a 1500-point view: zoomed or magnified by 1.5.
        let body: [String: Any] = ["x": 10, "lineTop": 20, "lineBottom": 30, "top": 5, "bottom": 30, "viewport": 1000]
        let spot = try #require(SelectionSpot(body, pageWidth: 1500))
        #expect(spot == SelectionSpot(x: 15, lineTop: 30, lineBottom: 45, top: 7.5, bottom: 45))
        #expect(SelectionSpot([:], pageWidth: 1000) == nil)
        #expect(SelectionSpot(["x": 1, "lineTop": 1, "lineBottom": 2, "top": 1, "bottom": 2], pageWidth: 1000) == nil)
        #expect(SelectionSpot(["x": 1, "lineTop": 1, "lineBottom": 2, "top": 1, "bottom": 2, "viewport": 0], pageWidth: 1000) == nil)
        #expect(SelectionSpot(["x": "10", "lineTop": 1, "lineBottom": 2, "top": 1, "bottom": 2, "viewport": 1000], pageWidth: 1000) == nil)
        #expect(SelectionSpot(["x": Double.nan, "lineTop": 1, "lineBottom": 2, "top": 1, "bottom": 2, "viewport": 1000], pageWidth: 1000) == nil)
        #expect(SelectionSpot(["x": 1, "lineTop": 9, "lineBottom": 2, "top": 1, "bottom": 2, "viewport": 1000], pageWidth: 1000) == nil)
    }

    @Test func theSpringStartsAtRestOvershootsAndSettles() {
        let spring = Bubble.spring(Motion.selectionPopBounce)
        #expect(spring(0) == 0)
        #expect(spring(1) == 1)
        let peak = stride(from: 0.0, through: 1, by: 0.01).map(spring).max() ?? 0
        #expect(peak > 1.02 && peak < 1.2)
        let flat = Bubble.spring(0)
        #expect(stride(from: 0.0, through: 1, by: 0.01).map(flat).max() ?? 0 < 1.01)
    }

    @Test func translateLeavesFromInsideCopyAndEndsBesideIt() throws {
        let width: CGFloat = 110, size = Metrics.selectionButton
        let first = SelectionFrame.at(0, pill: width)
        let pill = try #require(first.pill)
        #expect(first.copy == .zero && first.opacity == 0 && first.label == 0 && first.edge == 0)
        #expect(pill.width <= size && pill.minX >= 0 && pill.maxX <= size)

        let touching = SelectionFrame.at(Motion.selectionPullDelay + 0.01, pill: width)
        #expect(touching.edge == 0 && touching.label == 0)

        let last = SelectionFrame.at(SelectionFrame.total, pill: width)
        #expect(last.copy == CGSize(width: 1, height: 1))
        #expect(last.pill == CGRect(x: size + Metrics.selectionGap, y: 0, width: width, height: size))
        #expect(last.label == 1 && last.edge == 1 && last.opacity == 1)
        #expect(SelectionFrame.at(.infinity, pill: width) == last)
    }

    @Test func withoutTranslateCopySettlesAlone() {
        let last = SelectionFrame.at(SelectionFrame.total, pill: nil)
        #expect(last.pill == nil && last.copy == CGSize(width: 1, height: 1) && last.edge == 1)
    }
}
