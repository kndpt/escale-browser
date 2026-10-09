import Testing
@testable import Escale

// The delay before an idle tab sleeps: half an hour unless chosen, and the
// bench's `sleep.after` still wins so a scenario can wait seconds, not minutes.
@Suite @MainActor struct SleepDelayTests {
    @Test func unsetReadsAsHalfAnHour() {
        #expect(SleepDelay.stored(nil) == .half)
        #expect(SleepDelay.stored("ninety") == .half)
        #expect(Browser.sleepAfter(.stored(nil), bench: 0) == 30 * 60)
    }

    @Test(arguments: [(SleepDelay.quarter, 15.0), (.half, 30), (.hour, 60), (.twoHours, 120)])
    func chosenDelayIsRead(delay: SleepDelay, minutes: Double) {
        #expect(SleepDelay.stored(delay.rawValue) == delay)
        #expect(Browser.sleepAfter(delay, bench: 0) == minutes * 60)
    }

    @Test func benchOverrideWins() {
        #expect(Browser.sleepAfter(.twoHours, bench: 2) == 2)
    }
}
