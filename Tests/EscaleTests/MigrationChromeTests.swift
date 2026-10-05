// Chrome Stable is the first Chromium brand made automatic through its brand
// card alone: the fixtures copy the layout observed on Chrome 154 (structure
// only, never a personal profile) and the rollback journal its History keeps,
// which the shared snapshot must carry so an unfinished write is rolled back.
import Foundation
import Testing
import SQLite3
@testable import Escale

private func chromeFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-fixture-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private let chromeBookmarks = #"{"version":1,"roots":{"bookmark_bar":{"guid":"0bc5d13f-2cba-5d74-951f-3f233fe6c908","type":"folder","name":"Bookmarks bar","children":[{"guid":"ID","type":"url","name":"Site","url":"https://chrome.invalid/ID"}]},"other":{"guid":"82b081ec-3dd3-529c-8475-ab6c344590dd","type":"folder","name":"Other bookmarks","children":[]},"synced":{"guid":"4cf2e351-0e85-532b-bb37-df045d8f8d0f","type":"folder","name":"Mobile bookmarks","children":[]}}}"#

@Test func chromeStableKeepsItsOwnHomeAlongsideOtherBrands() throws {
    let user = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
    #expect(MigrationBrowser.chrome.route == .automatic)
    #expect(MigrationBrowser.chrome.applicationID == "com.google.Chrome")
    #expect(MigrationBrowser.chrome.location(user: user, testRoot: nil)?.path == "/Users/fixture/Library/Application Support/Google/Chrome")
    #expect(MigrationBrowser.chrome.slug == "chrome")
    #expect(MigrationBrowser.chrome.folderHelp.contains("~/Library/Application Support/Google/Chrome"))
    // Each brand now has an explicit identity and home, with format fixtures.
    for brand in [MigrationBrowser.chromium, .edge, .brave, .vivaldi, .opera, .dia] {
        #expect(brand.route == .automatic)
        #expect(brand.applicationID != nil)
    }
}

@Test func chromeDiscoveryFollowsTheObservedStableLayout() throws {
    let root = try chromeFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let fm = FileManager.default
    // Chrome 154: Local State names profiles among many other keys; the home
    // also holds System/Guest profiles and caches that are never sources.
    try Data(#"{"profile":{"last_used":"Default","info_cache":{"Default":{"name":"Personal","active_time":1790000000.0,"avatar_icon":"chrome://theme/IDR_PROFILE_AVATAR_26"},"Profile 1":{"name":"Travail — été","is_using_default_name":false},"Profile 9":{"name":"Removed"}}}}"#.utf8)
        .write(to: root.appendingPathComponent("Local State"))
    for name in ["Default", "Profile 1", "System Profile", "Guest Profile", "Crashpad", "Safe Browsing", "component_crx_cache"] {
        try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    // The observed Default has History and no Bookmarks file until one is saved.
    try Data().write(to: root.appendingPathComponent("Default/History"))
    try Data().write(to: root.appendingPathComponent("Default/History-journal"))
    try Data(chromeBookmarks.replacingOccurrences(of: "ID", with: "local").utf8).write(to: root.appendingPathComponent("Profile 1/Bookmarks"))
    try Data(chromeBookmarks.replacingOccurrences(of: "ID", with: "account").utf8).write(to: root.appendingPathComponent("Profile 1/AccountBookmarks"))
    for name in ["System Profile", "Guest Profile"] {
        try Data(chromeBookmarks.utf8).write(to: root.appendingPathComponent("\(name)/Bookmarks"))
    }
    let sources = try MigrationBrowser.chrome.discover(in: root, cancellation: MigrationCancellation())
    #expect(sources.map(\.profile) == ["Personal", "Travail — été"])
    #expect(sources.map(\.categories) == [[.history], [.bookmarks]])
    #expect(sources.allSatisfy { $0.browser == "Chrome" && $0.format == "chromium" })

    let values = try MigrationChromium(temporaryRoot: root.appendingPathComponent("scratch"))
        .read(sources[1], categories: [.bookmarks], cancellation: MigrationCancellation())
    #expect(values.bookmarks.map(\.title) == ["Bookmarks bar", "Other bookmarks", "Mobile bookmarks",
                                              "Bookmarks bar", "Other bookmarks", "Mobile bookmarks"])
    #expect(values.bookmarks[3].children.first?.url?.absoluteString == "https://chrome.invalid/account")
    #expect(!values.notices.contains { $0.hasPrefix("Browser release is unqualified") })
}

@Test func chromeHistoryWithAnUnfinishedWriteIsReadAsLastCommitted() throws {
    let live = try chromeFixture(), profile = try chromeFixture()
    defer { try? FileManager.default.removeItem(at: live); try? FileManager.default.removeItem(at: profile) }
    var db: OpaquePointer?
    guard sqlite3_open(live.appendingPathComponent("History").path, &db) == SQLITE_OK, let db else { throw MigrationFailure.unreadable }
    defer { sqlite3_close(db) }
    func exec(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw MigrationFailure.malformed } }
    try exec("""
    PRAGMA journal_mode=PERSIST;
    CREATE TABLE urls (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER);
    """)
    for index in 0..<300 {
        try exec("INSERT INTO urls (url, title, visit_count, typed_count, last_visit_time, hidden) VALUES ('https://chrome.invalid/\(index)', 'Committed \(String(repeating: "c", count: 500))', 3, 0, 13434292800000000, 0);")
    }
    // A one-page cache spills an open transaction into the main file, as a
    // copy in the middle of Chrome's write would find it: without its hot
    // journal that file is malformed; with it, SQLite rolls the copy back.
    try exec("PRAGMA cache_size=1; PRAGMA cache_spill=1; BEGIN; UPDATE urls SET title = 'Uncommitted'; DELETE FROM urls WHERE id > 10;")
    for name in ["History", "History-journal"] {
        try FileManager.default.copyItem(at: live.appendingPathComponent(name), to: profile.appendingPathComponent(name))
    }
    try exec("ROLLBACK;")
    let names = ["History", "History-journal"]
    let before = try names.map { try Data(contentsOf: profile.appendingPathComponent($0)) }
    #expect(before[1].count > 0)

    let source = MigrationSource(id: "fixture", browser: "Chrome", profile: "Default", location: profile, format: "chromium", categories: [.history])
    let values = try MigrationChromium(temporaryRoot: profile.appendingPathComponent("scratch"))
        .read(source, categories: [.history], cancellation: MigrationCancellation())
    #expect(values.history.count == 300)
    #expect(values.history.allSatisfy { $0.title.hasPrefix("Committed") })
    #expect(try names.map { try Data(contentsOf: profile.appendingPathComponent($0)) } == before)
    #expect(try FileManager.default.contentsOfDirectory(atPath: profile.appendingPathComponent("scratch").path).isEmpty)
}

@Test func aFolderMacOSRefusesIsToldApartFromOneThatIsMissing() {
    let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                         userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
    #expect(MigrationFailure.refused(denied))
    #expect(MigrationFailure.refused(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
    #expect(!MigrationFailure.refused(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)))
    #expect(!MigrationFailure.refused(MigrationFailure.malformed))
    #expect(MigrationBrowser.chrome.refused.contains("Choose its folder"))
}

@MainActor @Test func aRefusedFolderStaysWantedUntilTheViewTakesIt() async throws {
    let home = try chromeFixture()
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path); try? FileManager.default.removeItem(at: home) }
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: home.path)
    let flow = MigrationFlow(journal: home.deletingLastPathComponent().appendingPathComponent("journal-\(UUID())"),
                             scratch: home.deletingLastPathComponent(), homes: [.chrome: home])
    flow.useBrowser(.chrome)
    for _ in 0..<100 where !flow.folderWanted { try await Task.sleep(nanoseconds: 50_000_000) }
    // Nobody was watching when the refusal landed, and it is still there to take.
    #expect(flow.folderWanted)
    flow.folderOffered()
    #expect(!flow.folderWanted)
}
