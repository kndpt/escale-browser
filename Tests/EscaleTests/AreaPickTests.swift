// The geometry behind Select Area: a rectangle stays on the page, and only a
// drawn area of some size is worth capturing.
import Foundation
import Testing
@testable import Escale

@Suite struct AreaPickTests {
    private let page = CGSize(width: 800, height: 600)

    @Test func rectangleIsKeptOnThePage() {
        let inside = AreaPick.inside(CGRect(x: -40, y: 550, width: 300, height: 200), of: page)
        #expect(inside == CGRect(x: 0, y: 550, width: 260, height: 50))
        let gone = AreaPick.inside(CGRect(x: 900, y: 10, width: 50, height: 50), of: page)
        #expect(gone.width == 0)
    }

    @MainActor @Test func smallRectangleIsNotReadyAndFitFollowsTheWindow() {
        let pick = AreaPick()
        pick.fit(to: page)
        pick.start()
        pick.draw(CGRect(x: 10, y: 10, width: 3, height: 40))
        #expect(!pick.ready)
        pick.draw(CGRect(x: 700, y: 500, width: 90, height: 90))
        #expect(pick.ready)
        pick.fit(to: CGSize(width: 600, height: 400))
        #expect(!pick.ready && (pick.rect?.maxX ?? 0) <= 600 && (pick.rect?.maxY ?? 0) <= 400)
        pick.stop()
        #expect(!pick.active && pick.rect == nil)
    }
}
