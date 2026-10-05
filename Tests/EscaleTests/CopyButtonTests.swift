// The copy button's way back from its check: a press while it shows holds the
// check for a whole new turn, and a button that leaves the screen drops the
// wait instead of flipping later. The clock is a gate the test opens, so no
// result depends on how busy the machine is. Drawing is left to the app journey.
import Foundation
import Testing
@testable import Escale

@MainActor
private final class Gate {
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait(_: TimeInterval) async {
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Until `count` holds are being waited on.
    func reached(_ count: Int) async {
        while waiting.count < count { await Task.yield() }
    }

    func open(_ index: Int) async {
        waiting[index].resume()
        for _ in 0..<20 { await Task.yield() }
    }
}

@MainActor
@Suite struct CopyButtonTests {
    @Test func aPressShowsTheCheckThenLetsItGo() async {
        let gate = Gate()
        let cycle = CopyCycle(wait: { await gate.wait($0) })
        #expect(!cycle.done)
        cycle.press()
        #expect(cycle.done)
        await gate.reached(1)
        await gate.open(0)
        #expect(!cycle.done)
    }

    @Test func aSecondPressStartsTheHoldOver() async {
        let gate = Gate()
        let cycle = CopyCycle(wait: { await gate.wait($0) })
        cycle.press()
        await gate.reached(1)
        cycle.press()
        await gate.reached(2)
        // The first hold ends, but it was replaced: the check stays.
        await gate.open(0)
        #expect(cycle.done)
        await gate.open(1)
        #expect(!cycle.done)
    }

    @Test func leavingTheScreenDropsTheCheckAndItsTimer() async {
        let gate = Gate()
        let cycle = CopyCycle(wait: { await gate.wait($0) })
        cycle.press()
        await gate.reached(1)
        cycle.cancel()
        #expect(!cycle.done)
        // A press that follows is not cut short by the timer that was dropped.
        cycle.press()
        await gate.reached(2)
        await gate.open(0)
        #expect(cycle.done)
        await gate.open(1)
        #expect(!cycle.done)
    }
}
