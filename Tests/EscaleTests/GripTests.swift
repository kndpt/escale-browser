// The corner of a floating window without a shape of its own (a meeting's):
// it follows the pointer both ways, within the window's bounds, and the top
// left stays put. A film's corner keeps its shape and is not this rule.

import AppKit
import Testing
@testable import Escale

struct GripTests {
    private let was = NSRect(x: 100, y: 200, width: 380, height: 400)
    private let smallest = NSSize(width: 300, height: 240)
    private let screen = NSSize(width: 1600, height: 1000)

    @Test func widensWithoutGrowingTaller() {
        let now = Grip.stretched(was, by: NSPoint(x: 220, y: 0), smallest: smallest, limit: screen)
        #expect(now.size == NSSize(width: 600, height: 400))
        #expect(now.minX == was.minX && now.maxY == was.maxY)
    }

    @Test func draggingDownMakesItTaller() {
        // Screen coordinates run up: moving the corner down is a negative dy.
        let now = Grip.stretched(was, by: NSPoint(x: 0, y: -150), smallest: smallest, limit: screen)
        #expect(now.size == NSSize(width: 380, height: 550))
        #expect(now.maxY == was.maxY)
    }

    @Test func staysWithinItsBounds() {
        let small = Grip.stretched(was, by: NSPoint(x: -500, y: 500), smallest: smallest, limit: screen)
        #expect(small.size == smallest)
        let large = Grip.stretched(was, by: NSPoint(x: 5000, y: -5000), smallest: smallest, limit: screen)
        #expect(large.size == NSSize(width: 1360, height: 850))
    }
}
