// A build shows what it brought once, on its first launch in a profile that
// was here before it; a new profile gets the welcome instead, and a
// development build, which has no number, never compares.
import Foundation
import Testing
@testable import Escale

@Suite struct GateTests {
    @Test func newerBuildArrivesOnce() {
        #expect(Arrival.due(build: 202610011200, seen: 202609301437, returning: true))
        #expect(!Arrival.due(build: 202609301437, seen: 202609301437, returning: true))
        #expect(!Arrival.due(build: 202609301437, seen: 202610011200, returning: true))
    }

    @Test func noRecordMeansNewOrOlderThanTheRecord() {
        #expect(Arrival.due(build: 202610011200, seen: 0, returning: true))
        #expect(!Arrival.due(build: 202610011200, seen: 0, returning: false))
    }

    @Test func developmentBuildNeverArrives() {
        #expect(!Arrival.due(build: 0, seen: 0, returning: true))
        #expect(!Arrival.due(build: 0, seen: 202609301437, returning: true))
    }

    @Test func theDoorShowsFromTheFirstByteUntilTaken() {
        let release = Updater.Release(
            version: "0.3", build: 2, archive: URL(fileURLWithPath: "/tmp/Escale.zip"),
            dmg: URL(fileURLWithPath: "/tmp/Escale.dmg"), sha256: nil, notes: nil, minimumSystemVersion: nil
        )
        #expect(Updater.Stage.fetching(release).shown == release)
        #expect(Updater.Stage.ready(release).shown == release)
        #expect(Updater.Stage.offered(release).shown == release)
        #expect(Updater.Stage.none.shown == nil)
    }
}
