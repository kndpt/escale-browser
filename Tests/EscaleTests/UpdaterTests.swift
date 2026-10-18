// What an update's signature must satisfy before the updater swaps it in: a
// Developer ID certificate from Apple, for this team. Checked against
// requirement text and a binary Apple signed itself, which is not Developer ID.
// And how often the feed is read on its own, against the hourly clock, and
// what each read says it is the first of. And what a read and a refused
// install say: a failed read is never "the latest one".
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

    @Test func aReadSaysWhatItIsTheFirstOf() throws {
        func utc(_ text: String) throws -> Date { try #require(ISO8601DateFormatter().date(from: text)) }
        #expect(Updater.firsts(since: nil) == ["install", "day", "week", "month"])
        let wednesday = try utc("2026-10-07T23:00:00Z")
        #expect(Updater.firsts(since: wednesday, now: try utc("2026-10-07T23:50:00Z")) == [])
        #expect(Updater.firsts(since: wednesday, now: try utc("2026-10-08T00:10:00Z")) == ["day"])
        #expect(Updater.firsts(since: wednesday, now: try utc("2026-10-12T09:00:00Z")) == ["day", "week"])
        // Thursday 31 December and Friday 1 January share an ISO week.
        #expect(Updater.firsts(since: try utc("2026-12-31T12:00:00Z"), now: try utc("2027-01-01T12:00:00Z")) == ["day", "month"])
    }

    private func release(build: Int, needs system: String? = nil) throws -> Updater.Release {
        Updater.Release(
            version: "9.9", build: build,
            archive: try #require(URL(string: "https://example.invalid/Escale.zip")),
            dmg: try #require(URL(string: "https://example.invalid/Escale.dmg")),
            sha256: nil, notes: nil, minimumSystemVersion: system
        )
    }

    @Test func aReadSaysWhatItCameTo() throws {
        #expect(Updater.Read(nil, over: 10) == .failed)
        #expect(Updater.Read(nil, over: 10).said == "Couldn't check for updates")
        #expect(Updater.Read(try release(build: 10), over: 10) == .latest)
        #expect(Updater.Read(try release(build: 9), over: 10).said == "This is the latest one")
        // Newer, but not for this Mac.
        #expect(Updater.Read(try release(build: 11, needs: "99.0"), over: 10) == .latest)
        let newer = try release(build: 11)
        #expect(Updater.Read(newer, over: 10) == .newer(newer))
        #expect(Updater.Read(newer, over: 10).said == nil)
    }

    @Test func aFailedReadKeepsTheLastDate() {
        let hour = Date().addingTimeInterval(-60 * 60)
        let when = hour.formatted(.relative(presentation: .named))
        #expect(Updater.line(checked: nil, failed: false) == "Checked every 2 hours on its own")
        #expect(Updater.line(checked: hour, failed: false) == "Checked \(when) — every 2 hours on its own")
        #expect(Updater.line(checked: nil, failed: true) == "Couldn't check for updates")
        #expect(Updater.line(checked: hour, failed: true) == "Couldn't check for updates — last checked \(when)")
    }

    @Test(arguments: [
        (Swap.Refused.unsignedHere, Updater.Refusal.unsigned),
        (.readOnly, .place),
        (.download, .interrupted), (.move, .interrupted),
        (.hash, .untrusted), (.archive, .untrusted), (.plist, .untrusted), (.wrongApp, .untrusted),
        (.notNewer, .untrusted), (.unsigned, .untrusted), (.wrongTeam, .untrusted),
    ])
    func aRefusalNamesItsReason(_ refused: Swap.Refused, _ reason: Updater.Refusal) {
        #expect(Updater.Refusal(refused) == reason)
    }

    @Test func aRefusalSaysWhatToDo() {
        // A download that broke off on the network is tried again.
        #expect(Updater.Refusal(URLError(.notConnectedToInternet)) == .interrupted)
        #expect(Updater.Refusal.unsigned.said == "This copy can't update itself — download the disk image")
        #expect(Updater.Refusal.place.said
            == "This copy can't be replaced where it is — move it to Applications, or download the disk image")
        #expect(Updater.Refusal.interrupted.said == "The download broke off — try again")
        #expect(Updater.Refusal.untrusted.said == "The download didn't pass its checks — download the disk image")
    }
}
