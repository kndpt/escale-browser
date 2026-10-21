// When a page's sheet offers to stop it asking, and how long that lasts: a
// page that asks again the moment it is answered would otherwise hold the
// window for good. The count is per page and starts again on its next one.
import Testing
@testable import Escale

@Suite struct DialogAskingTests {
    @Test func offersToStopFromTheSecondQuestion() {
        var page = Dialogs.Asking()
        #expect(page.ask() == false)
        #expect(page.ask() == true)
        #expect(page.ask() == true)
        #expect(page.count == 3)
        #expect(page.stopped == false)
    }

    @Test func stoppedUntilThePageNavigates() {
        var page = Dialogs.Asking()
        _ = page.ask()
        _ = page.ask()
        page.stop()
        #expect(page.stopped)
        page.navigated()
        #expect(page.stopped == false)
        #expect(page.count == 0)
        #expect(page.ask() == false)
    }

    @Test func anotherPageCountsOnItsOwn() {
        var loud = Dialogs.Asking()
        var quiet = Dialogs.Asking()
        _ = loud.ask()
        _ = loud.ask()
        loud.stop()
        #expect(quiet.ask() == false)
        #expect(quiet.stopped == false)
        #expect(loud.stopped)
    }
}
