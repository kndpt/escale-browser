// All databases and archives are generated from documented field layouts in
// temporary directories. An open WAL producer remains alive during snapshot
// tests; hashes of its main, WAL and shared-memory files must remain unchanged.
import Foundation
import Testing
import SQLite3
import zlib
@testable import Escale

private struct ReaderFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("escale-reader-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func file(_ name: String) -> URL { root.appendingPathComponent(name) }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func database(_ name: String, sql: String) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(file(name).path, &db) == SQLITE_OK, let db else { throw MigrationFailure.unreadable }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { sqlite3_close(db); throw MigrationFailure.malformed }
        return db
    }
    func source(_ format: String, categories: Set<MigrationCategory>) -> MigrationSource {
        MigrationSource(id: "fixture", browser: "Synthetic \(format)", profile: "Profile", location: root, format: format, categories: categories)
    }
}

@Test func migrationSQLiteWALSnapshotLeavesEverySourceFileUnchanged() throws {
    let fixture = try ReaderFixture()
    defer { fixture.clean() }
    let db = try fixture.database("History", sql: """
    PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
    CREATE TABLE urls (url TEXT, title TEXT, visit_count INTEGER, last_visit_time INTEGER, hidden INTEGER);
    INSERT INTO urls VALUES ('https://wal.test/page', 'Only in WAL', 9, 13344473600000000, 0);
    """)
    defer { sqlite3_close(db) }
    let names = ["History", "History-wal", "History-shm"]
    let before = try names.map { try Data(contentsOf: fixture.file($0)) }
    let values = try MigrationChromium(temporaryRoot: fixture.file("scratch")).read(fixture.source("chromium", categories: [.history]), categories: [.history], cancellation: MigrationCancellation())
    #expect(values.history.count == 1)
    #expect(values.history[0].title == "Only in WAL")
    #expect(values.history[0].count == 9)
    #expect(try names.map { try Data(contentsOf: fixture.file($0)) } == before)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.file("scratch").path).isEmpty)
}

@Test func migrationSQLiteRejectsCorruptionAndCancelsWithCleanup() throws {
    let fixture = try ReaderFixture()
    defer { fixture.clean() }
    try Data("not a database".utf8).write(to: fixture.file("History"))
    #expect(throws: (any Error).self) {
        try MigrationSQLite.read(fixture.file("History"), temporaryRoot: fixture.file("scratch"), cancellation: MigrationCancellation()) { _ in () }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.file("scratch").path).isEmpty)
    let cancelled = MigrationCancellation(); cancelled.cancel()
    #expect(throws: MigrationFailure.cancelled) {
        try MigrationSQLite.read(fixture.file("History"), temporaryRoot: fixture.file("scratch"), cancellation: cancelled) { _ in () }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.file("scratch").path).isEmpty)
}

@Test func migrationChromiumDiscoversProfilesWithoutPasswordDatabase() throws {
    let fixture = try ReaderFixture()
    defer { fixture.clean() }
    for name in ["Default", "Profile été"] {
        let folder = fixture.file(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("Bookmarks"))
    }
    let sources = try MigrationProfiles.discover(in: fixture.root, browser: "Chromium fixture", family: "chromium")
    #expect(sources.map(\.profile) == ["Default", "Profile été"])
    #expect(sources.allSatisfy { $0.categories == [.bookmarks] })
    #expect(Set(sources.map(\.id)).count == 2)
}

@Test func migrationChromiumVersionAndNativeIdentitiesAreValidated() throws {
    let json = #"{"version":1,"roots":{"bookmark_bar":{"id":"1","type":"folder","name":"Bar","children":[{"id":"2","guid":"persistent-site","type":"url","name":"Site","url":"https://example.test"}]},"other":{"id":"3","type":"folder","name":"Other","children":[]}}}"#
    let values = try MigrationChromium.bookmarks(Data(json.utf8), cancellation: MigrationCancellation())
    #expect(values.bookmarks.count == 2)
    #expect(values.bookmarks[0].children[0].id == "persistent-site")
    #expect(values.bookmarks[1].children.isEmpty)
    #expect(throws: MigrationFailure.unsupported) {
        try MigrationChromium.bookmarks(Data(json.replacingOccurrences(of: "\"version\":1", with: "\"version\":999").utf8), cancellation: MigrationCancellation())
    }
}

@Test func migrationGeckoProfilesAndPlacesKeepNamedRootsAndOrder() throws {
    let fixture = try ReaderFixture()
    defer { fixture.clean() }
    let db = try fixture.database("places.sqlite", sql: """
    PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
    CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, last_visit_date INTEGER, hidden INTEGER);
    CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, parent INTEGER, type INTEGER, title TEXT, fk INTEGER, position INTEGER, guid TEXT);
    INSERT INTO moz_places VALUES (1,'https://gecko.test/a','Gecko',4,1700000000000000,0);
    INSERT INTO moz_bookmarks VALUES (1,0,2,'',NULL,0,'root________'),(2,1,2,'',NULL,0,'toolbar_____'),(3,2,1,'Second',1,1,'second______'),(4,2,1,'First',1,0,'first_______'),(5,2,2,'Empty',NULL,2,'empty_______');
    """)
    defer { sqlite3_close(db) }
    let ini = "[Profile0]\nName=Relative\nIsRelative=1\nPath=.\n[Profile1]\nName=Absolute\nIsRelative=0\nPath=\(fixture.root.path)\n[InstallX]\nDefault=.\n"
    try Data(ini.utf8).write(to: fixture.file("profiles.ini"))
    let sources = try MigrationProfiles.discover(in: fixture.root, browser: "Firefox fixture", family: "gecko")
    #expect(sources.count == 1)
    let source = try #require(sources.first)
    let values = try MigrationGecko(temporaryRoot: fixture.file("scratch")).read(source, categories: [.bookmarks, .history], cancellation: MigrationCancellation())
    #expect(values.bookmarks[0].title == "Bookmarks Toolbar")
    #expect(values.bookmarks[0].children.map(\.title) == ["First", "Second", "Empty"])
    #expect(values.history[0].last == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(values.history[0].count == 4)
}

private func archive(_ members: [(String, Data)]) -> Data {
    var result = Data(), central = Data()
    func le(_ number: Int, _ length: Int) -> Data { Data((0..<length).map { UInt8(truncatingIfNeeded: number >> ($0 * 8)) }) }
    for (name, bytes) in members {
        let encoded = Data(name.utf8), offset = result.count
        let crc = bytes.withUnsafeBytes { Int(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))) }
        for (n, length) in [(0x04034b50,4),(20,2),(0,2),(0,2),(0,4),(crc,4),(bytes.count,4),(bytes.count,4),(encoded.count,2),(0,2)] { result += le(n,length) }
        result += encoded; result += bytes
        for (n, length) in [(0x02014b50,4),(20,2),(20,2),(0,2),(0,2),(0,4),(crc,4),(bytes.count,4),(bytes.count,4),(encoded.count,2),(0,2),(0,2),(0,2),(0,2),(0,4),(offset,4)] { central += le(n,length) }
        central += encoded
    }
    let start = result.count
    result += central
    for (n, length) in [(0x06054b50,4),(0,4),(members.count,2),(members.count,2),(central.count,4),(start,4),(0,2)] { result += le(n,length) }
    return result
}

@Test func migrationZIPRejectsTraversalCorruptionDuplicatesAndBombSizes() throws {
    let bytes = Data("synthetic".utf8)
    #expect(throws: MigrationFailure.malformed) { try MigrationZIP(archive([("../escape", bytes)])) }
    #expect(throws: MigrationFailure.malformed) { try MigrationZIP(archive([("/escape", bytes)])) }
    #expect(throws: MigrationFailure.malformed) { try MigrationZIP(archive([("Name", bytes), ("name", bytes)])) }
    #expect(throws: MigrationFailure.malformed) { try MigrationZIP(Data(archive([("x", bytes)]).dropLast(1))) }
    var corrupt = archive([("x", bytes)])
    corrupt[31] ^= 1
    let zip = try MigrationZIP(corrupt)
    #expect(throws: MigrationFailure.malformed) { try zip.contents(zip.entries[0]) }
    var bomb = archive([("x", bytes)])
    let central = 31 + bytes.count
    bomb[central + 24] = 255; bomb[central + 25] = 255; bomb[central + 26] = 255; bomb[central + 27] = 127
    #expect(throws: MigrationFailure.tooLarge) { try MigrationZIP(bomb) }
}

@Test func migrationSafariDetectsLocalizedSharedDataAndSeparateHistoryProfiles() throws {
    let fixture = try ReaderFixture()
    defer { fixture.clean() }
    let history = #"{"metadata":{"browser_name":"Safari","browser_version":"18.2-fixture","schema_version":1,"data_type":"history"},"history":[{"url":"https://safari.test/","title":"Safari fixture","time_usec":1700000000000000,"visits_count":7}]}"#
    let html = "<!DOCTYPE NETSCAPE-Bookmark-file-1><DL><A HREF='https://bookmark.test'>Bookmark</A></DL>"
    let data = archive([("Favoris.html", Data(html.utf8)), ("Mots de passe.csv", Data("Title,URL,Username,Password,Notes,OTPAuth\nSite,https://safari.test,u,synthetic-secret,note,\n".utf8)), ("Historique Personnel.json", Data(history.utf8)), ("Historique Travail.json", Data(history.utf8))])
    let file = fixture.file("Safari.zip"); try data.write(to: file)
    let sources = try MigrationSafari.discover(file, cancellation: MigrationCancellation())
    #expect(sources.count == 3)
    #expect(sources[0].categories == [.bookmarks, .passwords])
    #expect(sources[1].categories == [.history])
    let values = try MigrationSafari().read(sources[0], categories: sources[0].categories, cancellation: MigrationCancellation())
    #expect(values.bookmarks.count == 1)
    #expect(values.passwords.count == 1)
    #expect(values.history.isEmpty)
    #expect(!values.notices.joined().contains("synthetic-secret"))
    let visits = try MigrationSafari().read(sources[1], categories: [.history], cancellation: MigrationCancellation())
    #expect(visits.history.count == 1)
    #expect(visits.history[0].count == 7)
    #expect(try Data(contentsOf: file) == data)
    #expect(throws: MigrationFailure.unsupported) { try MigrationSafari.history(Data(history.replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":99").utf8)) }
}

@Test func migrationZIPReadsIndependentDeflateFixtureAndRejectsSymlinks() throws {
    // Generated with Python standard-library zipfile, ZIP_DEFLATED, UTF-8 name.
    let data = try #require(Data(base64Encoded: "UEsDBBQAAAgIACQIO10ke+sXHgAAABwAAAANAAAAbG9jYWxpc8OpLnR4dEtUKK7MK8lILclMVkhJTctJLElNUUgsSs7ILEsFAFBLAQIUAxQAAAgIACQIO10ke+sXHgAAABwAAAANAAAAAAAAAAAAAACAAQAAAABsb2NhbGlzw6kudHh0UEsFBgAAAAABAAEAOwAAAEkAAAAAAA=="))
    let zip = try MigrationZIP(data)
    #expect(zip.entries[0].name == "localisé.txt")
    #expect(try String(data: zip.contents(zip.entries[0]), encoding: .utf8) == "a synthetic deflated archive")
    var link = archive([("link", Data("target".utf8))])
    let central = 30 + 4 + 6
    link[central + 41] = 0xA0
    #expect(throws: MigrationFailure.unsupported) { try MigrationZIP(link) }
}

@Test func migrationCopiedLinksKeepOrderAndReportLostOrganisation() throws {
    let values = try MigrationExchange.links("https://first.test\n- [Second](https://second.test/path)\nhttps://first.test\nfolder heading\n")
    #expect(values.bookmarks.map(\.title) == ["https://first.test", "Second", "https://first.test"])
    #expect(values.bookmarks[0].id != values.bookmarks[2].id)
    #expect(values.notices.last == "1 lines without a supported link omitted.")
}

@Test func migrationSQLiteRejectsAChangedSourceAndRecoversAbandonedCopies() throws {
    let fixture = try ReaderFixture()
    defer { fixture.clean() }
    let db = try fixture.database("History", sql: "CREATE TABLE sample (value TEXT); INSERT INTO sample VALUES ('first');")
    defer { sqlite3_close(db) }
    let scratch = fixture.file("scratch")
    try FileManager.default.createDirectory(at: scratch.appendingPathComponent("snapshot-\(UUID())"), withIntermediateDirectories: true)
    #expect(throws: MigrationFailure.sourceChanged) {
        try MigrationSQLite.read(fixture.file("History"), temporaryRoot: scratch, cancellation: MigrationCancellation(), afterCopy: {
            #expect(sqlite3_exec(db, "INSERT INTO sample VALUES ('changed')", nil, nil, nil) == SQLITE_OK)
        }) { _ in () }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    try MigrationSQLite.read(fixture.file("History"), temporaryRoot: scratch, cancellation: MigrationCancellation()) { snapshot in
        var values: [String] = []
        try snapshot.rows("SELECT value FROM sample", cancellation: MigrationCancellation()) { values.append(try MigrationSQLite.text($0, 0)) }
        #expect(values == ["first", "changed"])
    }
}

@Test func migrationInputBoundsApplyBeforeLoadingAndUnknownSchemasFail() throws {
    let fixture = try ReaderFixture()
    defer { fixture.clean() }
    let big = fixture.file("oversize")
    #expect(FileManager.default.createFile(atPath: big.path, contents: nil))
    let handle = try FileHandle(forWritingTo: big)
    try handle.truncate(atOffset: UInt64(MigrationLimits.bytes + 1)); try handle.close()
    #expect(throws: MigrationFailure.tooLarge) { try MigrationLimits.data(big) }
    let db = try fixture.database("History", sql: "CREATE TABLE unknown (value TEXT);")
    defer { sqlite3_close(db) }
    #expect(throws: MigrationFailure.unsupported) {
        try MigrationChromium(temporaryRoot: fixture.file("scratch")).read(fixture.source("chromium", categories: [.history]), categories: [.history], cancellation: MigrationCancellation())
    }
}
