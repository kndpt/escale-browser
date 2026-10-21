// What VoiceOver reads after a bookmark's title: a folder open or shut, a
// site's page on screen, open elsewhere or sleeping, and nothing for a shut
// bookmark. The rows in the running app are checked by
// Tests/Bench/bookmark_access.py.

import Testing
@testable import Escale

struct BookmarkAccessTests {
    @Test func aFolderSaysWhetherItIsOpen() {
        #expect(BookmarkAccess.shown(true) == "Expanded")
        #expect(BookmarkAccess.shown(false) == "Collapsed")
    }

    @Test(arguments: [
        (false, false, false, ""),
        (true, false, false, "Open"),
        (true, true, false, "Active"),
        (true, false, true, "Open, Sleeping"),
    ])
    func aSiteSaysWhereItsPageIs(open: Bool, live: Bool, sleeping: Bool, said: String) {
        #expect(BookmarkAccess.state(open: open, live: live, sleeping: sleeping) == said)
    }

    @Test func sleepingIsTheMarkersOwnWord() {
        #expect(BookmarkAccess.state(open: true, live: false, sleeping: true).hasSuffix(SleepLabel.name))
    }
}
