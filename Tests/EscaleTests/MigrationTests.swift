// Synthetic exports and isolated files exercise preservation and replay,
// including the durable-write/checkpoint gap. No test opens a personal profile
// or the real keychain; failures enter through the same narrow owner boundary.
import Foundation
import Testing
@testable import Escale

private let migrationHTML = """
<!DOCTYPE NETSCAPE-Bookmark-file-1>
<DL><p><DT><H3>Work &amp; docs</H3><DL><p>
<DT><A HREF="https://example.test/a?x=1&amp;y=2">A &#x1F680;</A>
<DT><A HREF='https://example.test/a?x=1&amp;y=2'>Repeated</A>
<DT><H3>Empty</H3><DL><p></DL><p></DL><p>
<DT><A HREF="javascript:alert(1)">Excluded</A></DL><p>
"""

private func migrationRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("escale-migration-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func migrationCleanup(_ root: URL) {
    try? FileManager.default.removeItem(at: root.appendingPathComponent("blocked"))
    for name in ["bookmarks.json", "history.json", "receipt.json", "marks", "journal", "history", "receipt", "other-marks", "other-history", "blocked/cannot-write"] {
        let writer = Writer.to(root.appendingPathComponent(name))
        writer.remove(); writer.flush()
    }
    try? FileManager.default.removeItem(at: root)
}

private func migrationSource(_ file: URL, format: String = "html") -> MigrationSource {
    MigrationSource(id: "fixture-profile", browser: "Fixture", profile: "Synthetic", location: file,
                    format: format, categories: Set(MigrationCategory.allCases))
}

@Test func migrationHTMLKeepsHierarchyRepeatsAndEntities() throws {
    let values = try MigrationExchange.html(migrationHTML)
    #expect(values.bookmarks.count == 1)
    #expect(values.bookmarks[0].title == "Work & docs")
    let children = values.bookmarks[0].children
    #expect(children.count == 3)
    #expect(children[0].title == "A 🚀")
    #expect(children[0].url?.absoluteString == "https://example.test/a?x=1&y=2")
    #expect(children[0].id != children[1].id)
    #expect(children[2].children.isEmpty)
    #expect(values.notices.count == 1)
    #expect(try MigrationExchange.html(migrationHTML).bookmarks == values.bookmarks)
}

@Test func migrationCSVHandlesQuotedMultilineSecretsWithoutDiagnosticsLeaks() throws {
    let values = try MigrationExchange.csv("url,username,password,Notes,OTPAuth\r\nhttps://example.test,\"a,b\",\"line1\nline2\"\"x\",private-note,private-otp\r\n")
    #expect(values.passwords.count == 1)
    #expect(values.passwords[0].user == "a,b")
    #expect(values.passwords[0].password == "line1\nline2\"x")
    #expect(values.notices.count == 1)
    #expect(!values.notices.joined().contains("private"))
    #expect(throws: MigrationFailure.malformed) { try MigrationExchange.csv("url,username,password\nhttps://example.test,u,\"broken") }
    #expect(throws: MigrationFailure.malformed) { try MigrationExchange.csv("url,username,password\nhttps://example.test,u,\"closed\"junk") }
    #expect(throws: MigrationFailure.unsupported) { try MigrationExchange.csv("name,secret\na,b") }
}

@Test func migrationRejectsOversizeDepthAndUnfinishedExports() throws {
    #expect(throws: MigrationFailure.tooLarge) { try MigrationExchange.csv(String(repeating: "x", count: MigrationLimits.field + 1)) }
    #expect(throws: MigrationFailure.malformed) { try MigrationExchange.html("<!DOCTYPE NETSCAPE-Bookmark-file-1><DL><A HREF='https://test.test'>unfinished") }
    let deep = "<!DOCTYPE NETSCAPE-Bookmark-file-1><DL>" + String(repeating: "<H3>x</H3><DL>", count: 40)
    #expect(throws: MigrationFailure.tooLarge) { try MigrationExchange.html(deep) }
    #expect(MigrationLimits.url("https://user:secret@example.test") == nil)
    #expect(MigrationLimits.url("file:///etc/passwd") == nil)
}

@Test func migrationMergeKeepsHomonymsEditsAndMovedFolders() throws {
    let source = migrationSource(URL(fileURLWithPath: "/synthetic"))
    let values = try MigrationExchange.html(migrationHTML)
    let plan = try MigrationPlan(source: source, destination: UUID(), categories: [.bookmarks], values: values)
    let own = Bookmark.folder("Work & docs", [])
    let first = plan.bookmarks(keeping: [own])
    #expect(first.roots[0] == own)
    #expect(first.added == 4)
    #expect(first.roots.count == 2)
    let replay = plan.bookmarks(keeping: first.roots)
    #expect(replay.roots == first.roots)
    #expect(replay.added == 0)
    var edited = first.roots[1]
    edited.title = "My title"
    let container = Bookmark.folder("Moved here", [edited])
    let moved = plan.bookmarks(keeping: [own, container])
    #expect(moved.roots == [own, container])
    #expect(moved.conflicts == 1)
    var changed = values
    changed.bookmarks[0].children.append(MigrationBookmark(id: "new", title: "New", url: URL(string: "https://new.test")))
    let changedPlan = try MigrationPlan(source: source, destination: UUID(), categories: [.bookmarks], values: changed)
    let result = changedPlan.bookmarks(keeping: [own, container])
    #expect(result.added == 1)
    #expect(result.roots[1].children?[0].children?.count == 4)
}

@MainActor
private func migrationWait(_ predicate: () -> Bool) async throws {
    // Counted in sleeps, not wall time: a CI runner can stall the main
    // thread for seconds, and a clock deadline would spend itself meanwhile.
    for _ in 0..<2000 where !predicate() { try await Task.sleep(for: .milliseconds(5)) }
    #expect(predicate())
}

private struct FixtureReader: MigrationReader {
    let values: MigrationValues
    func read(_ source: MigrationSource, categories: Set<MigrationCategory>, cancellation: MigrationCancellation) throws -> MigrationValues {
        try cancellation.check(); return values
    }
}

@MainActor
@Test func migrationPreviewAndRestartAreNonDestructiveAndIdempotent() async throws {
    let root = try migrationRoot()
    defer { migrationCleanup(root) }
    let marks = root.appendingPathComponent("bookmarks.json"), historyFile = root.appendingPathComponent("history.json")
    let journal = root.appendingPathComponent("receipt.json"), input = root.appendingPathComponent("source.html")
    try Data(migrationHTML.utf8).write(to: input)
    let before = try Data(contentsOf: input)
    let space = UUID()
    var values = try MigrationExchange.html(migrationHTML)
    let url = try #require(URL(string: "https://visit.test/page"))
    values.history = [MigrationVisit(url: url, title: "Visit", count: 8, last: Date())]
    for _ in 0..<2 {
        let bookmarks = Bookmarks(space: space, file: marks), history = History(file: historyFile)
        let migration = Migration(journal: journal)
        migration.prepare(source: migrationSource(input), destination: space, categories: [.bookmarks, .history], keeping: bookmarks.roots, reader: FixtureReader(values: values))
        try await migrationWait { migration.phase == .preview }
        #expect(migration.receipt == nil)
        migration.confirm(destination: .init(bookmarks: bookmarks, history: history, exists: { true }))
        try await migrationWait { migration.phase == .finished }
        #expect(bookmarks.roots.count == 1)
        #expect(history.everything().first?.count == 8)
        #expect(migration.plan == nil)
        let receipt = try JSONDecoder().decode(MigrationReceipt.self, from: Data(contentsOf: journal))
        #expect(receipt.completed == [.bookmarks, .history])
        #expect(receipt.finished)
        #expect(receipt.historyPlaces == history.count)
    }
    #expect(try Data(contentsOf: input) == before)
}

@MainActor
@Test func migrationCancellationAndRemovedDestinationWriteNothing() async throws {
    let root = try migrationRoot()
    defer { migrationCleanup(root) }
    let marks = root.appendingPathComponent("marks"), journal = root.appendingPathComponent("journal")
    let migration = Migration(journal: journal)
    let source = migrationSource(root.appendingPathComponent("source"))
    let values = try MigrationExchange.html(migrationHTML)
    migration.prepare(source: source, destination: UUID(), categories: [.bookmarks], reader: FixtureReader(values: values))
    try await migrationWait { migration.phase == .preview }
    migration.cancel()
    #expect(migration.phase == .stopped)
    #expect(!FileManager.default.fileExists(atPath: journal.path))
    migration.prepare(source: source, destination: UUID(), categories: [.bookmarks], reader: FixtureReader(values: values))
    try await migrationWait { migration.phase == .preview }
    migration.confirm(destination: .init(bookmarks: Bookmarks(file: marks), history: History(file: root.appendingPathComponent("history")), exists: { false }))
    #expect(migration.phase == .stopped)
    #expect(!FileManager.default.fileExists(atPath: marks.path))
}

@MainActor
@Test func migrationDiskAndKeychainFailuresAreReportedWithoutSecrets() async throws {
    let root = try migrationRoot()
    defer { migrationCleanup(root) }
    let blocked = root.appendingPathComponent("blocked")
    try Data().write(to: blocked)
    let migration = Migration(journal: root.appendingPathComponent("receipt"))
    let space = UUID(), secret = "fixture-secret-never-journalled"
    let values = MigrationValues(passwords: [MigrationPassword(host: "example.test", user: "u", password: secret)])
    let source = migrationSource(root)
    migration.prepare(source: source, destination: space, categories: [.passwords], reader: FixtureReader(values: values))
    try await migrationWait { migration.phase == .preview }
    migration.confirm(destination: .init(bookmarks: Bookmarks(file: root.appendingPathComponent("marks")), history: History(file: root.appendingPathComponent("history")), exists: { true }, password: { _, _ in .failed }))
    try await migrationWait { migration.phase == .stopped }
    #expect(migration.receipt?.passwordFailures == 1)
    #expect(migration.plan == nil)
    #expect(try !String(contentsOf: root.appendingPathComponent("receipt"), encoding: .utf8).contains(secret))
    #expect(!(migration.message ?? "").contains(secret))
    let disk = Migration(journal: blocked.appendingPathComponent("cannot-write"))
    disk.prepare(source: source, destination: space, categories: [.passwords], reader: FixtureReader(values: values))
    try await migrationWait { disk.phase == .preview }
    var writes = 0
    disk.confirm(destination: .init(bookmarks: Bookmarks(file: root.appendingPathComponent("other-marks")), history: History(file: root.appendingPathComponent("other-history")), exists: { true }, password: { _, _ in writes += 1; return .added }))
    try await migrationWait { disk.phase == .stopped }
    #expect(writes == 0)
}

@MainActor
@Test func migrationStopsBetweenDurableCategoriesAndReplaysAfterInterruption() async throws {
    let root = try migrationRoot()
    defer { migrationCleanup(root) }
    let marks = root.appendingPathComponent("bookmarks.json"), historyFile = root.appendingPathComponent("history.json")
    let space = UUID(), journal = root.appendingPathComponent("receipt.json")
    let migration = Migration(journal: journal)
    var values = try MigrationExchange.html(migrationHTML)
    values.history = [MigrationVisit(url: try #require(URL(string: "https://test.test/page")), title: "History", count: 5, last: Date())]
    let source = migrationSource(root)
    let bookmarks = Bookmarks(space: space, file: marks), history = History(file: historyFile)
    migration.prepare(source: source, destination: space, categories: [.bookmarks, .history], reader: FixtureReader(values: values))
    try await migrationWait { migration.phase == .preview }
    var checks = 0
    migration.confirm(destination: .init(bookmarks: bookmarks, history: history, exists: { checks += 1; return checks < 3 }))
    try await migrationWait { migration.phase == .stopped }
    #expect(migration.receipt?.completed == [.bookmarks])
    #expect(Bookmarks(space: space, file: marks).roots.count == 1)
    #expect(!FileManager.default.fileExists(atPath: historyFile.path))
    let restart = Migration(journal: journal)
    restart.restoreReceipt()
    try await migrationWait { restart.receipt != nil }
    #expect(restart.receipt?.finished == false)
    restart.prepare(source: source, destination: space, categories: [.bookmarks, .history], keeping: bookmarks.roots, reader: FixtureReader(values: values))
    try await migrationWait { restart.phase == .preview }
    restart.confirm(destination: .init(bookmarks: bookmarks, history: history, exists: { true }))
    try await migrationWait { restart.phase == .finished }
    #expect(restart.receipt?.addedBookmarks == 0)
    #expect(history.everything().first?.count == 5)
}

@MainActor
@Test func migrationRejectsAStalePreviewInsteadOfOverwritingAnEdit() async throws {
    let root = try migrationRoot()
    defer { migrationCleanup(root) }
    let bookmarks = Bookmarks(file: root.appendingPathComponent("marks"))
    let migration = Migration(journal: root.appendingPathComponent("receipt"))
    migration.prepare(source: migrationSource(root), destination: UUID(), categories: [.bookmarks], reader: FixtureReader(values: try MigrationExchange.html(migrationHTML)))
    try await migrationWait { migration.phase == .preview }
    bookmarks.add(try #require(URL(string: "https://mine.test/")), title: "User edit")
    migration.confirm(destination: .init(bookmarks: bookmarks, history: History(file: root.appendingPathComponent("history")), exists: { true }))
    #expect(migration.phase == .stopped)
    #expect(bookmarks.roots.count == 1)
    #expect(bookmarks.roots[0].title == "User edit")
}

@Test func migrationRejectsDuplicateSourceIdentitiesAndBoundsHistory() throws {
    let source = migrationSource(URL(fileURLWithPath: "/synthetic"))
    let repeated = MigrationBookmark(id: "same", title: "Folder")
    #expect(throws: MigrationFailure.malformed) {
        try MigrationPlan(source: source, destination: UUID(), categories: [.bookmarks], values: MigrationValues(bookmarks: [repeated, repeated]))
    }
    let url = try #require(URL(string: "https://test.test/"))
    let visits = (0..<3_000).map { MigrationVisit(url: url, title: "Page", count: 1, last: Date(timeIntervalSince1970: 1_700_000_000 + Double($0))) }
    let plan = try MigrationPlan(source: source, destination: UUID(), categories: [.history], values: MigrationValues(history: visits))
    #expect(plan.values.history.count == 2_000)
    #expect(plan.values.history.first?.last == visits.last?.last)
    #expect(!plan.values.notices.isEmpty)
}

// Hold a real read until cancellation is issued; no timing race or fixed sleep
// decides whether the automatically authorized write can start.
private struct PausedMigrationReader: MigrationReader {
    let started: DispatchSemaphore
    let release: DispatchSemaphore
    let values: MigrationValues
    func read(_ source: MigrationSource, categories: Set<MigrationCategory>, cancellation: MigrationCancellation) throws -> MigrationValues {
        started.signal()
        guard release.wait(timeout: .now() + 5) == .success else { throw MigrationFailure.unreadable }
        try cancellation.check()
        return values
    }
}

@MainActor
@Test func migrationAuthorizedReadAppliesWithoutASecondConfirmation() async throws {
    let root = try migrationRoot()
    defer { migrationCleanup(root) }
    let marks = Bookmarks(file: root.appendingPathComponent("marks"))
    let history = History(file: root.appendingPathComponent("history"))
    let migration = Migration(journal: root.appendingPathComponent("receipt"))
    migration.prepare(source: migrationSource(root), destination: UUID(), categories: [.bookmarks],
                      reader: FixtureReader(values: try MigrationExchange.html(migrationHTML)), ready: {
        migration.confirm(destination: .init(bookmarks: marks, history: history, exists: { true }))
    })
    try await migrationWait { migration.phase == .finished }
    #expect(migration.receipt?.completed == [.bookmarks])
    #expect(Bookmarks(file: root.appendingPathComponent("marks")).roots.count == 1)
}

@MainActor
@Test func migrationCancelledReadCannotApplyItsAuthorizedContinuation() async throws {
    let root = try migrationRoot()
    defer { migrationCleanup(root) }
    let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let migration = Migration(journal: root.appendingPathComponent("receipt"))
    var continued = false
    migration.prepare(source: migrationSource(root), destination: UUID(), categories: [.bookmarks],
                      reader: PausedMigrationReader(started: started, release: release,
                                                    values: try MigrationExchange.html(migrationHTML)), ready: { continued = true })
    var readerStarted = false
    try await migrationWait {
        if !readerStarted { readerStarted = started.wait(timeout: .now()) == .success }
        return readerStarted
    }
    migration.cancel()
    release.signal()
    try await migrationWait { migration.phase == .stopped }
    #expect(!continued)
    #expect(migration.plan == nil)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("receipt").path))
}

@Test func migrationOlderReceiptsRemainReadableWithoutHistoryVolume() throws {
    let old = MigrationReceipt(destination: UUID(), source: "fixture")
    let data = try JSONEncoder().encode(old)
    let decoded = try JSONDecoder().decode(MigrationReceipt.self, from: data)
    #expect(decoded.historyPlaces == nil)
}
