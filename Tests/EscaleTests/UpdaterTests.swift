// What an update's signature must satisfy before the updater swaps it in: a
// Developer ID certificate from Apple, for this team. Checked against
// requirement text and a binary Apple signed itself, which is not Developer ID.
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
}
