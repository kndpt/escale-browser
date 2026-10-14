// When Welcome asks how extensions are kept: only on a first arrival with
// nothing installed and no mode settled outside it, since the answer moves
// where extensions keep their data.
import Testing
@testable import Escale

@Suite struct WelcomeExtensionsTests {
    @Test func aFirstArrivalAsks() {
        #expect(WelcomePanel.asksForExtensions(welcomed: false, decided: false, installed: false))
    }

    @Test func welcomeReopenedFromTheMenuNeverAsks() {
        #expect(!WelcomePanel.asksForExtensions(welcomed: true, decided: false, installed: false))
        #expect(!WelcomePanel.asksForExtensions(welcomed: true, decided: true, installed: true))
    }

    @Test func dismissedThenAnExtensionInstalledNoLongerAsks() {
        // The install settled the mode per Space.
        #expect(!WelcomePanel.asksForExtensions(welcomed: false, decided: true, installed: true))
        #expect(!WelcomePanel.asksForExtensions(welcomed: false, decided: false, installed: true))
    }

    @Test func aModeSettledOutsideThisArrivalIsNotAskedAgain() {
        #expect(!WelcomePanel.asksForExtensions(welcomed: false, decided: true, installed: false))
    }
}
