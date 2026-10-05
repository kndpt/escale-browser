import Foundation
import Testing
import WebKit
@testable import Escale

// What the Passwords panel's list keeps, and when (see Logins.swift). The
// logins are synthetic and handed over by the test: no keychain is read.

@MainActor
@Suite struct LoginsTests {
    private static let kept = [
        Login(host: "beta.example.test", user: "zed", password: "synthetic-1", used: nil),
        Login(host: "alpha.example.test", user: "ann", password: "synthetic-2", used: nil),
        Login(host: "beta.example.test", user: "amy", password: "synthetic-3", used: nil),
    ]

    /// A list whose reads are counted.
    private final class Reads {
        var count = 0
    }

    private func logins(_ reads: Reads) -> Logins {
        Logins(say: { _ in }, tab: { _ in nil }, read: {
            reads.count += 1
            return LoginsTests.kept
        })
    }

    @Test func nothingIsReadOrHeldBeforeThePanelShows() {
        let reads = Reads()
        let logins = logins(reads)

        logins.relist()

        #expect(reads.count == 0)
        #expect(logins.saved.isEmpty)
    }

    @Test func thePanelShowingReadsTheListAndClosingLetsGoOfIt() {
        let reads = Reads()
        let logins = logins(reads)

        logins.show()
        #expect(reads.count == 1)
        #expect(logins.saved.count == 3)

        logins.hunting = "beta"
        logins.hide()
        #expect(logins.saved.isEmpty)
        #expect(logins.hunting.isEmpty)
        #expect(logins.shownSites.isEmpty)

        logins.relist()
        #expect(reads.count == 1)

        logins.show()
        #expect(reads.count == 2)
        #expect(logins.saved.count == 3)
    }

    @Test func theListIsGroupedBySiteAndFilteredByWhatIsTyped() {
        let logins = logins(Reads())
        logins.show()

        #expect(logins.shownSites.map(\.host) == ["alpha.example.test", "beta.example.test"])
        #expect(logins.shownSites.last?.logins.map(\.user) == ["amy", "zed"])

        logins.hunting = " ZED "
        #expect(logins.shownSites.map(\.host) == ["beta.example.test"])
        #expect(logins.shownSites.first?.logins.map(\.user) == ["zed"])

        logins.hunting = "nowhere"
        #expect(logins.shownSites.isEmpty)
    }

    // The caret in a sign-in box. The keychain can stop to ask macOS for
    // permission and wait as long as the answer takes: the caret's event has
    // to return at once, and the list to come when the read does.

    /// A lookup that waits for the test to let it answer.
    private final class Gate: @unchecked Sendable {
        private let door = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var sites: [String] = []
        func wait(_ host: String) {
            lock.withLock { sites.append(host) }
            door.wait()
        }
        func open() { door.signal() }
        var asked: [String] { lock.withLock { sites } }
    }

    private func caretLogins(_ gate: Gate, tab: Tab) -> Logins {
        Logins(say: { _ in }, tab: { _ in tab }, lookup: { host, _ in
            gate.wait(host)
            return LoginsTests.kept.filter { $0.host == host }
        })
    }

    private func settle(_ until: @MainActor () -> Bool) async {
        for _ in 0..<200 where !until() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    private let spot = CGRect(x: 10, y: 20, width: 100, height: 24)

    @Test func theCaretReturnsWhileTheKeychainIsStillAsking() async {
        let tab = Tab(space: UUID(), configuration: WKWebViewConfiguration())
        let gate = Gate()
        let logins = caretLogins(gate, tab: tab)

        logins.caret(in: tab.id, at: spot, host: "beta.example.test", filling: true)
        #expect(logins.suggesting == nil)

        gate.open()
        await settle { logins.suggesting != nil }
        #expect(logins.suggesting?.logins.map(\.user) == ["zed", "amy"])
        #expect(logins.suggesting?.spot == spot)
    }

    @Test func aCaretThatLeftBeforeTheAnswerShowsNothing() async {
        let tab = Tab(space: UUID(), configuration: WKWebViewConfiguration())
        let gate = Gate()
        let logins = caretLogins(gate, tab: tab)

        logins.caret(in: tab.id, at: spot, host: "beta.example.test", filling: true)
        logins.caret(in: tab.id, at: nil, host: nil, filling: true)
        gate.open()
        await settle { gate.asked.count == 1 }
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(logins.suggesting == nil)
    }

    @Test func eventsDuringOneReadAddNoSecondReadForTheSameSite() async {
        let tab = Tab(space: UUID(), configuration: WKWebViewConfiguration())
        let gate = Gate()
        let logins = caretLogins(gate, tab: tab)

        logins.caret(in: tab.id, at: spot, host: "beta.example.test", filling: true)
        await settle { gate.asked.count == 1 }
        logins.caret(in: tab.id, at: spot.offsetBy(dx: 0, dy: 30), host: "beta.example.test", filling: true)
        gate.open()
        await settle { logins.suggesting != nil }

        #expect(gate.asked == ["beta.example.test"])
        // Shown where the caret is now, not where it was when the read began.
        #expect(logins.suggesting?.spot == spot.offsetBy(dx: 0, dy: 30))
    }

    @Test func aListDroppedWhileTheKeychainIsAskingDoesNotComeBack() async {
        let tab = Tab(space: UUID(), configuration: WKWebViewConfiguration())
        let gate = Gate()
        let logins = caretLogins(gate, tab: tab)

        logins.caret(in: tab.id, at: spot, host: "beta.example.test", filling: true)
        await settle { gate.asked.count == 1 }
        // Filling turned off while macOS is still asking.
        logins.dropChoice()
        gate.open()
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(logins.suggesting == nil)
    }

    @Test func navigationDropsOnlyItsTabsChoice() async {
        let first = Tab(space: UUID(), configuration: WKWebViewConfiguration())
        let second = Tab(space: UUID(), configuration: WKWebViewConfiguration())
        let gate = Gate()
        let logins = Logins(say: { _ in }, tab: { id in id == first.id ? first : second }, lookup: { _, _ in
            gate.wait("beta.example.test")
            return LoginsTests.kept
        })

        logins.caret(in: first.id, at: spot, host: "beta.example.test", filling: true)
        gate.open()
        await settle { logins.suggesting != nil }
        logins.dropChoice(in: second.id)
        #expect(logins.suggesting?.tab == first.id)

        logins.dropChoice(in: first.id)
        #expect(logins.suggesting == nil)
    }
}
