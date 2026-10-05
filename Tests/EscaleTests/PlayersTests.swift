// Which addresses are meetings. The page-side choice of who to show is checked
// against real WebKit by the call_float scenario; this is only the address rule.

import Foundation
import Testing
@testable import Escale

struct PlayersTests {
    @Test(arguments: [
        "https://meet.google.com/abc-defg-hij",
        "https://meet.google.com/abc-defg-hij?authuser=1",
        "https://MEET.google.com/lookup/team-standup",
    ])
    func meetingAddressesAreCalls(address: String) {
        #expect(Players.isCall(URL(string: address)))
        #expect(Players.knows(URL(string: address)))
    }

    @Test(arguments: [
        "https://meet.google.com/",
        "https://meet.google.com",
        "https://meet.google.com/landing",
        "https://google.com/abc-defg-hij",
        "https://notmeet.google.com/abc-defg-hij",
        "https://meet.google.com.example.org/abc-defg-hij",
        "http://127.0.0.1:8000/call",
    ])
    func otherAddressesAreNot(address: String) {
        #expect(!Players.isCall(URL(string: address)))
    }

    @Test func nothingIsNotACall() {
        #expect(!Players.isCall(nil))
    }

    @Test func filmSitesAreKnownButNotCalls() {
        let film = URL(string: "https://www.youtube.com/watch?v=abc")
        #expect(Players.knows(film))
        #expect(!Players.isCall(film))
    }
}
