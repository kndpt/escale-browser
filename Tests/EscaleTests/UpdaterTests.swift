// What an update's signature must satisfy before the updater swaps it in: a
// Developer ID certificate from Apple, for this team. Checked against
// requirement text and a binary Apple signed itself, which is not Developer ID.
// And how often the feed is read on its own, against the hourly clock.
import Foundation
import Security
import Testing
@testable import Escale

@Suite struct UpdaterTests {
    @Test func aTeamIDBuildsARequirement() {
        #expect(Updater.developerID(team: "66674CLT83") != nil)
    }

    @Test func anythingElseBuildsNone() {
        for team in ["", "66674clt83", "66674CLT8", "66674CLT833", "AB\" or anchor", "ABCDE FGHI"] {
            #expect(Updater.developerID(team: team) == nil)
        }
    }

    @Test func anAppleSignedBinaryIsNotDeveloperID() throws {
        let requirement = try #require(Updater.developerID(team: "66674CLT83"))
        var code: SecStaticCode?
        #expect(SecStaticCodeCreateWithPath(URL(fileURLWithPath: "/usr/bin/true") as CFURL, [], &code) == errSecSuccess)
        let binary = try #require(code)
        #expect(SecStaticCodeCheckValidity(binary, [], nil) == errSecSuccess)
        #expect(SecStaticCodeCheckValidity(binary, [], requirement) != errSecSuccess)
    }

    @Test func theFeedIsReadEverySecondHourlyTick() {
        let start = Date()
        // A tick five minutes late, and a fetch that took a few seconds.
        let last = start.addingTimeInterval(5 * 60 + 10)
        #expect(!Updater.due(since: last, now: start.addingTimeInterval(60 * 60)))
        #expect(Updater.due(since: last, now: start.addingTimeInterval(2 * 60 * 60)))
        #expect(Updater.due(since: .distantPast))
    }
}
