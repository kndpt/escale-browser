// The transfer file's rules without the app: what opens, what is refused and
// why, and what a valid file may and may not contain. Writing into a real
// destination is the bench's (Tests/Bench/transfer.py).
import Foundation
import Testing
@testable import Escale

@Suite @MainActor struct TransferTests {
    private static let rounds: UInt32 = 100_000

    private func space(_ name: String = "Work", id: UUID = UUID(), bookmark: Bookmark? = nil, tabs: [Session.Entry] = []) -> TransferSpace {
        TransferSpace(id: id, name: name, colour: 1, icon: "briefcase", extensions: [],
                      session: Session.Shape(tabs: tabs, active: 0),
                      bookmarks: bookmark.map { [$0] } ?? [], history: [], habits: [:], hidden: [:],
                      zoom: [:], paused: [], never: [], logins: nil)
    }

    private func payload(_ spaces: [TransferSpace], rules: [LinkRule] = []) -> TransferPayload {
        TransferPayload(id: UUID(), created: Date(), app: "test", spaces: spaces, preferences: [:],
                        linkRules: rules, includesPasswords: false)
    }

    private func site(_ url: String = "https://example.com/") -> Bookmark { .site("Example", URL(string: url) ?? URL(fileURLWithPath: "/")) }

    // MARK: - the envelope

    @Test func sealedFileOpensWithItsPassphraseOnly() throws {
        let data = Data("synthetic payload".utf8)
        let file = try TransferFile.seal(data, passphrase: "correct horse", rounds: Self.rounds)
        #expect(try TransferFile.open(file, passphrase: "correct horse") == data)
        #expect(throws: TransferError.cannotOpen) { try TransferFile.open(file, passphrase: "wrong horse") }
        #expect(throws: TransferError.emptyPassphrase) { try TransferFile.open(file, passphrase: "") }
        // Nothing of the payload is readable in the file.
        #expect(file.range(of: data) == nil)
    }

    @Test func twoSpellingsOfOneLetterAreOnePassphrase() throws {
        let composed = "caf\u{e9}", decomposed = "cafe\u{301}"
        let file = try TransferFile.seal(Data("x".utf8), passphrase: composed, rounds: Self.rounds)
        #expect(try TransferFile.open(file, passphrase: decomposed) == Data("x".utf8))
    }

    @Test func everySealIsDifferent() throws {
        let a = try TransferFile.seal(Data("same".utf8), passphrase: "phrase", rounds: Self.rounds)
        let b = try TransferFile.seal(Data("same".utf8), passphrase: "phrase", rounds: Self.rounds)
        #expect(a != b)
    }

    @Test func alteredOrCutFilesAreRefused() throws {
        let file = try TransferFile.seal(Data("payload".utf8), passphrase: "phrase", rounds: Self.rounds)
        for index in [TransferFile.headerLength + 3, file.count - 1, 20] {
            var altered = file
            altered[index] ^= 0x01
            #expect(throws: TransferError.cannotOpen) { try TransferFile.open(altered, passphrase: "phrase") }
        }
        #expect(throws: TransferError.truncated) { try TransferFile.open(file.prefix(TransferFile.headerLength + 5), passphrase: "phrase") }
        #expect(throws: TransferError.notATransfer) { try TransferFile.open(Data("hello world".utf8), passphrase: "phrase") }
        #expect(throws: TransferError.notATransfer) { try TransferFile.open(Data(), passphrase: "phrase") }
    }

    @Test func aNewerFormatIsRefusedBeforeAnythingIsRead() throws {
        var file = try TransferFile.seal(Data("payload".utf8), passphrase: "phrase", rounds: Self.rounds)
        file[9] = 2
        #expect(throws: TransferError.unsupported(2)) { try TransferFile.open(file, passphrase: "phrase") }
    }

    @Test func aHostileCostIsRefusedNotPaid() throws {
        var file = try TransferFile.seal(Data("payload".utf8), passphrase: "phrase", rounds: Self.rounds)
        for (index, byte) in [0xff, 0xff, 0xff, 0xff].enumerated() { file[10 + index] = UInt8(byte) }
        #expect(throws: TransferError.invalid("unusual key stretching")) { try TransferFile.inspect(file) }
        for (index, byte) in [0, 0, 0, 1].enumerated() { file[10 + index] = UInt8(byte) }
        #expect(throws: TransferError.invalid("unusual key stretching")) { try TransferFile.inspect(file) }
    }

    @Test func anOversizedFileIsRefusedUnread() {
        var huge = Data(TransferFile.magic)
        huge.append(Data(count: TransferFile.largest))
        #expect(throws: TransferError.tooLarge) { try TransferFile.inspect(huge) }
    }

    // MARK: - the payload

    @Test func payloadSurvivesEncodingAndSealing() throws {
        let bookmark = site()
        var made = space(bookmark: bookmark, tabs: [Session.Entry(url: "https://example.com/a", title: "A", bookmark: bookmark.id)])
        made.zoom = ["example.com": 1.25]
        made.paused = ["example.com"]
        let source = payload([made], rules: [LinkRule(scope: .host, host: "example.com", destination: made.id)])
        let file = try TransferFile.seal(TransferExport.encode(source), passphrase: "phrase", rounds: Self.rounds)
        let opened = try JSONDecoder().decode(TransferPayload.self, from: TransferFile.open(file, passphrase: "phrase"))
        let (checked, summary) = try opened.checked()
        #expect(checked.spaces.first?.bookmarks.first?.id == bookmark.id)
        #expect(checked.spaces.first?.zoom["example.com"] == 1.25)
        #expect(summary.lines == [TransferLine(name: "Work", tabs: 1, bookmarks: 1, history: 0, passwords: 0, extensions: 0)])
        #expect(summary.linkRules == 1)
    }

    @Test func structuralFaultsRefuseTheWholeFile() {
        let id = UUID()
        #expect(throws: TransferError.self) { try payload([]).checked() }
        #expect(throws: TransferError.self) { try payload([space(id: id), space("Other", id: id)]).checked() }
        let twice = site()
        let repeated = space(bookmark: Bookmark.folder("F", [twice, twice]))
        #expect(throws: TransferError.self) { try payload([repeated]).checked() }
        // A tab pointing at a bookmark that is not in the file.
        let dangling = space(tabs: [Session.Entry(url: "https://example.com/", title: "T", bookmark: UUID())])
        #expect(throws: TransferError.self) { try payload([dangling]).checked() }
        // A link rule into a Space that is not in the file.
        let stranded = LinkRule(scope: .host, host: "example.com", destination: UUID())
        #expect(throws: TransferError.self) { try payload([space()], rules: [stranded]).checked() }
        var future = payload([space()])
        future.schema = 99
        #expect(throws: TransferError.unsupported(99)) { try future.checked() }
    }

    @Test func deepOrHugeBookmarkTreesAreRefused() {
        var node = site()
        for _ in 0...TransferLimits.depth + 1 { node = Bookmark.folder("F", [node]) }
        #expect(throws: TransferError.self) { try payload([space(bookmark: node)]).checked() }
    }

    @Test func addressesThatAreNotWebPagesAreLeftOutAndCounted() throws {
        let kept = site("https://example.com/")
        let folder = Bookmark.folder("F", [kept, site("javascript:alert(1)"), site("file:///etc/passwd")])
        var made = space(bookmark: folder, tabs: [Session.Entry(url: "data:text/html,x", title: "X"), Session.Entry(url: "https://example.com/t", title: "T")])
        made.history = [Visit(url: "https://example.com/", key: "example.com", title: "E", count: 2, last: Date()),
                        Visit(url: "ftp://example.com/", key: "ftp", title: "F", count: 1, last: Date())]
        made.zoom = ["example.com": 1.5, "bad host": 2, "example.org": .infinity]
        let (checked, summary) = try payload([made]).checked()
        let clean = try #require(checked.spaces.first)
        #expect(clean.bookmarks.first?.children?.count == 1)
        #expect(clean.session.tabs.map(\.title) == ["T"])
        #expect(clean.history.count == 1)
        #expect(clean.zoom == ["example.com": 1.5])
        #expect(summary.skipped == 2 + 1 + 1)
    }

    @Test func passwordsTravelOnlyWhenTheFileSaysSo() throws {
        var made = space()
        made.logins = [TransferLogin(host: "example.com", user: "a", password: "x", used: nil)]
        let off = try payload([made]).checked().payload
        #expect(off.spaces.first?.logins == nil)
        var on = payload([made])
        on.includesPasswords = true
        let kept = try on.checked()
        #expect(kept.payload.spaces.first?.logins?.count == 1)
        #expect(kept.summary.lines.first?.passwords == 1)
    }

    @Test func splitsNeedTheWholeRowOrAreRefused() {
        let entries = [Session.Entry(url: "https://example.com/a", title: "A"), Session.Entry(url: "data:x", title: "B")]
        var made = space(tabs: entries)
        made.session.panels = [Session.SavedPanels(members: [0, 1], active: 0, horizontal: true, weights: [0.5, 0.5])]
        #expect(throws: TransferError.self) { try payload([made]).checked() }
    }

    @Test func splitTabsMustAllBeWebAddresses() {
        var made = space(tabs: [Session.Entry(url: "https://example.com/a", title: "A"), Session.Entry(url: "httpx://example.com/b", title: "B")])
        made.session.panels = [Session.SavedPanels(members: [0, 1], active: 0, horizontal: true, weights: [0.5, 0.5])]
        #expect(throws: TransferError.self) { try payload([made]).checked() }
        made.session.tabs[1].url = "https://user:secret@example.com/b"
        #expect(throws: TransferError.self) { try payload([made]).checked() }
        made.session.tabs[1].url = "https://example.com/b"
        #expect((try? payload([made]).checked()) != nil)
    }

    // MARK: - identities and preferences

    @Test func newIdentitiesAreStableForOneFileAndDifferentAcrossFiles() {
        let transfer = UUID(), old = UUID()
        #expect(TransferApply.identity(transfer, old) == TransferApply.identity(transfer, old))
        #expect(TransferApply.identity(transfer, old) != TransferApply.identity(UUID(), old))
        #expect(TransferApply.identity(transfer, old) != old)
        #expect(TransferApply.identity(transfer, old) != Space.firstID)
    }

    @Test func preferencesAreAClosedList() {
        let known = TransferPreferences.known(["look": .word("dark"), "bench": .flag(true), "downloads": .word("/tmp"), "sidebar": .flag(false)])
        #expect(known == 2)
    }
}
