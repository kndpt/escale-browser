// What VoiceOver reads after a tab's title: its state, in a fixed order, and
// nothing for an ordinary tab. The element and its actions in the running app
// are checked by Tests/Bench/tab_access.py.

import Testing
@testable import Escale

struct TabAccessTests {
    @Test func anOrdinaryTabHasNoState() {
        #expect(TabAccess.state(live: false, pinned: false, sleeping: false) == "")
    }

    @Test(arguments: [
        (true, false, false, "Active"),
        (false, true, false, "Pinned"),
        (false, false, true, "Sleeping"),
        (true, true, false, "Active, Pinned"),
        (false, true, true, "Pinned, Sleeping"),
        (true, true, true, "Active, Pinned, Sleeping"),
    ])
    func eachStateIsSaidOnceInOrder(live: Bool, pinned: Bool, sleeping: Bool, said: String) {
        #expect(TabAccess.state(live: live, pinned: pinned, sleeping: sleeping) == said)
    }

    @Test func sleepingIsTheMarkersOwnWord() {
        #expect(TabAccess.state(live: false, pinned: false, sleeping: true) == SleepLabel.name)
    }
}
