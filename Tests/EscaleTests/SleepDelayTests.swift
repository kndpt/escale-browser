import Testing
@testable import Escale

// The delay before an idle tab sleeps: half an hour unless chosen, and the
// bench's `sleep.after` still wins so it can make a tab sleep in seconds.
@Suite struct SleepDelayTests {
    @Test func unsetOrUnknownIsHalfAnHour() {
        #expect(SleepDelay.stored(nil) == .half)
        #expect(SleepDelay.stored(45) == .half)
        #expect(SleepDelay.stored(nil).seconds == 30 * 60)
    }

    @Test(arguments: [15, 30, 60, 120])
    func chosenDelay(minutes: Int) {
        #expect(SleepDelay.stored(minutes).seconds == Double(minutes * 60))
    }

    @MainActor @Test func benchOverridesTheChoice() {
        #expect(Browser.sleepAfter(.twoHours, bench: 0) == 2 * 60 * 60)
        #expect(Browser.sleepAfter(.quarter, bench: 2) == 2)
    }
}
