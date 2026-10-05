// Public-format fixtures qualify parser behaviour independently of installed
// browsers. Literal-only mozLz4 is constructed here without Apple's encoder;
// a hand-encoded match block also checks interoperability. SNSS commands use
// the documented little-endian structures, not the production parser's code.
// All source files are disposable; no browser profile is read or modified.
import Foundation
import Testing
import SQLite3
@testable import Escale

private struct ImportFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-import-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func put(_ name: String, _ data: Data) throws {
        let file = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }
    func json(_ name: String, _ object: Any) throws { try put(name, JSONSerialization.data(withJSONObject: object)) }
    func plist(_ name: String, _ object: Any) throws { try put(name, PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)) }
    func session(_ name: String, _ object: Any) throws { try put(name, moz(JSONSerialization.data(withJSONObject: object))) }
}

private func le(_ value: Int, bytes: Int = 4) -> Data {
    Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
}
private func moz(_ data: Data) -> Data {
    var result = Data([109,111,122,76,122,52,48,0]) + le(data.count)
    result.append(UInt8(min(data.count, 15) << 4))
    if data.count >= 15 {
        var rest = data.count - 15
        while rest >= 255 { result.append(255); rest -= 255 }
        result.append(UInt8(rest))
    }
    return result + data
}
private func snssString(_ text: String, wide: Bool = false) -> Data {
    let bytes = wide ? Data(text.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }) : Data(text.utf8)
    var result = le(wide ? text.utf16.count : bytes.count) + bytes
    while result.count % 4 != 0 { result.append(0) }
    return result
}
private func command(_ id: UInt8, _ data: Data) -> Data { le(data.count + 1, bytes: 2) + Data([id]) + data }
private func navigation(_ id: Int, _ index: Int, _ url: String, post: Bool = false) -> Data {
    let data = le(id) + le(index) + snssString(url) + snssString("Café 🦊", wide: true) + snssString("engine state must never be restored") + le(0) + le(post ? 1 : 0)
    return command(6, le(data.count) + data)
}
private func snss(version: Int = 3) -> Data {
    Data("SNSS".utf8) + le(version) + command(0, le(1) + le(42)) + command(2, le(42) + le(0))
        + navigation(42, 0, "https://old.invalid") + navigation(42, 1, "https://current.invalid")
        + command(7, le(42) + le(1)) + command(12, le(42) + le(1)) + command(255, Data())
}
private func ffTab(_ url: String, id: String? = nil, workspace: String? = nil) -> [String: Any] {
    var tab: [String: Any] = ["entries": [["url": url, "title": "Page"]], "index": 1]
    if let id { tab["zenSyncId"] = id }
    if let workspace { tab["zenWorkspace"] = workspace }
    return tab
}
private let token = MigrationCancellation()

@Test func publicBrandsHaveDistinctHomesAndDoNotFallBackOutsideTests() throws {
    let brands: [(MigrationBrowser, String, String)] = [
        (.chromium, "org.chromium.Chromium", "Chromium"), (.edge, "com.microsoft.edgemac", "Microsoft Edge"),
        (.brave, "com.brave.Browser", "BraveSoftware/Brave-Browser"), (.vivaldi, "com.vivaldi.Vivaldi", "Vivaldi"),
        (.opera, "com.operasoftware.Opera", "com.operasoftware.Opera"), (.operaGX, "com.operasoftware.OperaGX", "com.operasoftware.OperaGX"),
        (.dia, "company.thebrowser.dia", "Dia"), (.firefox, "org.mozilla.firefox", "Firefox"),
        (.zen, "app.zen-browser.zen", "Zen"), (.orion, "com.kagi.kagimacOS", "Orion")]
    let fixture = try ImportFixture(); defer { fixture.remove() }
    for (brand, app, home) in brands {
        #expect(brand.automatic)
        #expect(brand.applicationID == app)
        #expect(brand.home == home)
        #expect(brand.location(user: URL(fileURLWithPath: "/never"), testRoot: fixture.root) == fixture.root)
    }
    #expect(MigrationBrowser.firefox.applicationIDs.contains("org.mozilla.nightly"))
    #expect(MigrationBrowser.firefox.applicationIDs.contains("org.mozilla.firefoxdeveloperedition"))
    #expect(MigrationBrowser.safari.route == .export && MigrationBrowser.safari.checklist)
}

@Test(arguments: [MigrationBrowser.chromium, .edge, .brave, .vivaldi, .opera, .operaGX, .dia])
func newChromiumBrandsDiscoverReadAndReplayTheirOwnSyntheticProfile(_ brand: MigrationBrowser) throws {
    let fixture = try ImportFixture(); defer { fixture.remove() }
    let profile = brand == .opera || brand == .operaGX ? "" : "Default/"
    try fixture.json(profile + "Bookmarks", ["version": 1, "roots": ["bookmark_bar": ["type": "folder", "id": "root", "name": "Speed Dial", "children": [["type": "url", "id": "site", "name": "Site", "url": "https://fixture.invalid"]]]]])
    let source = try #require(brand.discover(in: fixture.root, cancellation: token).first)
    #expect(source.browser == brand.rawValue)
    let before = try Data(contentsOf: source.location.appendingPathComponent("Bookmarks"))
    let values = try MigrationChromium(temporaryRoot: fixture.root.appendingPathComponent("scratch")).read(source, categories: [.bookmarks], cancellation: token)
    let plan = try MigrationPlan(source: source, destination: UUID(), categories: [.bookmarks], values: values)
    let first = plan.bookmarks(keeping: [])
    #expect(first.added == 2)
    #expect(plan.bookmarks(keeping: first.roots).added == 0)
    #expect(try Data(contentsOf: source.location.appendingPathComponent("Bookmarks")) == before)
}

@Test func mozLZ4DecodesIndependentLiteralAndOverlappingMatchBlocks() throws {
    let text = Data(String(repeating: "α JSON ", count: 80).utf8)
    #expect(try MigrationMozLZ4.decode(moz(text), cancellation: token) == text)
    // Four literals, an eight-byte overlapping match, five final literals.
    let match = Data([109,111,122,76,122,52,48,0]) + le(17) + Data([0x44]) + Data("abcd".utf8) + Data([4,0,0x50]) + Data("12345".utf8)
    #expect(try MigrationMozLZ4.decode(match, cancellation: token) == Data("abcdabcdabcd12345".utf8))
}

@Test func mozLZ4RefusesTruncationBombsOffsetsAndCancellation() throws {
    let good = moz(Data("hello world".utf8))
    #expect(throws: MigrationFailure.malformed) { try MigrationMozLZ4.decode(Data(good.dropLast()), cancellation: token) }
    #expect(throws: MigrationFailure.malformed) { try MigrationMozLZ4.decode(good + Data([0]), cancellation: token) }
    var bomb = good; bomb.replaceSubrange(8..<12, with: le(MigrationLimits.bytes + 1))
    #expect(throws: MigrationFailure.tooLarge) { try MigrationMozLZ4.decode(bomb, cancellation: token) }
    let badOffset = Data([109,111,122,76,122,52,48,0]) + le(4) + Data([0,0,0])
    #expect(throws: MigrationFailure.malformed) { try MigrationMozLZ4.decode(badOffset, cancellation: token) }
    let cancelled = MigrationCancellation(); cancelled.cancel()
    #expect(throws: MigrationFailure.cancelled) { try MigrationMozLZ4.decode(good, cancellation: cancelled) }
}

@Test func firefoxProfilesIncludeExternalUnicodeAndSessionsWithoutPlaces() throws {
    let fixture = try ImportFixture(), external = try ImportFixture(); defer { fixture.remove(); external.remove() }
    try fixture.put("profiles.ini", Data("[Profile0]\nName=Travail été\nIsRelative=1\nPath=Profiles/work\n[Profile1]\nName=Nightly\nIsRelative=0\nPath=\(external.root.path)\n".utf8))
    let state: [String: Any] = ["version": ["sessionrestore", 1], "windows": [["tabs": [ffTab("https://profile.invalid")]]]]
    try fixture.session("Profiles/work/sessionstore.jsonlz4", state)
    try external.session("sessionstore.jsonlz4", state)
    let sources = try MigrationBrowser.firefox.discover(in: fixture.root, cancellation: token)
    #expect(sources.map(\.profile) == ["Travail été", "Nightly"])
    #expect(sources.allSatisfy { $0.categories == [.tabs] })
    let values = try MigrationGecko(temporaryRoot: fixture.root.appendingPathComponent("scratch")).read(sources[0], categories: [.tabs], cancellation: token)
    #expect(values.tabs.count == 1)
}

@Test func firefoxSessionsSelectCurrentEntryAndOmitPrivatePOSTAndClosedWindows() throws {
    let fixture = try ImportFixture(); defer { fixture.remove() }
    var post = ffTab("https://post.invalid"); post["entries"] = [["url": "https://post.invalid", "postdata_b64": "private-body"]]
    var pinned = ffTab("https://current.invalid"); pinned["pinned"] = true
    pinned["entries"] = [["url": "https://old.invalid"], ["url": "https://current.invalid"]]; pinned["index"] = 2
    try fixture.session("sessionstore.jsonlz4", ["version": ["sessionrestore", 1], "windows": [["tabs": [pinned, post, ffTab("about:config")]], ["isPrivate": true, "tabs": [ffTab("https://private.invalid")]]], "_closedWindows": [["tabs": [ffTab("https://closed.invalid")]]]])
    let values = try MigrationGeckoSession.read(in: fixture.root, cancellation: token)
    #expect(values.tabs.map(\.url.absoluteString) == ["https://current.invalid"])
    #expect(values.tabs[0].pinned)
    #expect(values.notices.contains { $0.contains("3 private") })
    try fixture.session("sessionstore.jsonlz4", ["version": ["sessionrestore", 9], "windows": []])
    #expect(throws: MigrationFailure.unsupported) { try MigrationGeckoSession.read(in: fixture.root, cancellation: token) }
}

@Test func chromiumSessionsReplayNavigationOrderPinsAndClosures() throws {
    let first = try MigrationChromiumSession.decode(snss(), identity: "fixture", cancellation: token)
    #expect(first.tabs.count == 1)
    #expect(first.tabs[0].url.absoluteString == "https://current.invalid")
    #expect(first.tabs[0].title == "Café 🦊" && first.tabs[0].pinned)
    let closed = snss() + command(16, le(42) + le(0, bytes: 12))
    #expect(try MigrationChromiumSession.decode(closed, identity: "fixture", cancellation: token).tabs.isEmpty)
    let post = snss() + navigation(42, 1, "https://post.invalid", post: true)
    #expect(try MigrationChromiumSession.decode(post, identity: "fixture", cancellation: token).tabs.isEmpty)
    let pruned = snss() + command(24, le(42) + le(0) + le(1))
    #expect(try MigrationChromiumSession.decode(pruned, identity: "fixture", cancellation: token).tabs.first?.url.absoluteString == "https://current.invalid")
}

@Test func chromiumSessionsRejectUnknownEncryptedPartialAndUnmarkedFiles() throws {
    for version in [2,4,5] { #expect(throws: MigrationFailure.encryptedSession) { try MigrationChromiumSession.decode(snss(version: version), identity: "fixture", cancellation: token) } }
    #expect(throws: MigrationFailure.unsupported) { try MigrationChromiumSession.decode(snss(version: 9), identity: "fixture", cancellation: token) }
    #expect(throws: MigrationFailure.malformed) { try MigrationChromiumSession.decode(Data(snss().dropLast()), identity: "fixture", cancellation: token) }
    #expect(throws: MigrationFailure.malformed) { try MigrationChromiumSession.decode(Data(snss().dropLast(3)), identity: "fixture", cancellation: token) }
    #expect(throws: MigrationFailure.unsupported) { try MigrationChromiumSession.decode(snss() + command(240, Data()), identity: "fixture", cancellation: token) }
    let fixture = try ImportFixture(); defer { fixture.remove() }
    try fixture.put("Sessions/Session_1", snss())
    try fixture.put("Sessions_Encrypted/Session_2", snss(version: 5))
    #expect(throws: MigrationFailure.encryptedSession) { try MigrationChromiumSession.read(in: fixture.root, cancellation: token) }
}

@Test func tabMergeKeepsEditsAndSurvivesSessionEncoding() throws {
    let source = MigrationSource(id: "source", browser: "Firefox", profile: "Profile", location: URL(fileURLWithPath: "/not-read"), format: "gecko", categories: [.tabs])
    let values = MigrationValues(tabs: [MigrationTab(id: "tab", url: try #require(URL(string: "https://fixture.invalid")), title: "Original", pinned: true)])
    let plan = try MigrationPlan(source: source, destination: UUID(), categories: [.tabs], values: values)
    var first = MigrationTabs.merge(plan, into: Session.Shape(tabs: [], active: 0)).shape
    #expect(first.tabs.count == 1 && first.tabs[0].pin == "F")
    first.tabs[0].title = "My edit"
    let saved = try JSONDecoder().decode(Session.Shape.self, from: JSONEncoder().encode(first))
    let replay = MigrationTabs.merge(plan, into: saved)
    #expect(replay.added.isEmpty && replay.kept == 1)
    #expect(replay.shape.tabs[0].title == "My edit")
    let existing = Session.Shape(tabs: [Session.Entry(url: "https://one.invalid", title: "One"), Session.Entry(url: "https://two.invalid", title: "Two")], active: 1,
                                 panels: [Session.SavedPanels(members: [0, 1], active: 1, horizontal: true, weights: [0.5, 0.5])])
    let inserted = MigrationTabs.merge(plan, into: existing).shape
    #expect(inserted.tabs.map(\.title) == ["Original", "One", "Two"])
    #expect(inserted.active == 2 && inserted.panels?.first?.members == [1, 2] && inserted.panels?.first?.active == 2)
    #expect(Session.valid(inserted))
}

@Test func orionPreservesNestedEmptyFoldersAndRepeatedURLsWithStableIDs() throws {
    let fixture = try ImportFixture(); defer { fixture.remove() }
    try fixture.plist("profiles", ["defaults": ["name": "Personal"], "profiles": [["identifier": "work", "name": "Personal"]]])
    let marks: [String: Any] = [
        "root": ["id": "root", "parentId": "0", "type": "folder", "title": "Favorites", "index": 0],
        "empty": ["id": "empty", "parentId": "root", "type": "folder", "title": "Empty", "index": 0],
        "second": ["id": "second", "parentId": "root", "type": "bookmark", "title": "Repeated", "url": "https://orion.invalid", "index": 2],
        "first": ["id": "first", "parentId": "root", "type": "bookmark", "title": "Repeated", "url": "https://orion.invalid", "index": 1]]
    try fixture.plist("Defaults/favourites.plist", marks); try fixture.plist("work/favourites.plist", marks)
    let sources = try MigrationBrowser.orion.discover(in: fixture.root, cancellation: token)
    #expect(sources.map(\.profile) == ["Personal", "Personal"] && Set(sources.map(\.id)).count == 2)
    let reader = MigrationOrion(temporaryRoot: fixture.root.appendingPathComponent("scratch"))
    let values = try reader.read(sources[0], categories: [.bookmarks], cancellation: token)
    #expect(values.bookmarks[0].children.map(\.id) == ["empty", "first", "second"])
    let plan = try MigrationPlan(source: sources[0], destination: UUID(), categories: [.bookmarks], values: values)
    #expect(plan.bookmarks(keeping: plan.bookmarks(keeping: []).roots).added == 0)
    var broken = marks; broken["root"] = ["id": "root", "parentId": "empty", "type": "folder", "title": "Cycle", "index": 0]
    #expect(throws: MigrationFailure.malformed) { try MigrationOrion.bookmarks(PropertyListSerialization.data(fromPropertyList: broken, format: .binary, options: 0), cancellation: token) }
}

@Test func importedFilesCannotEscapeTheChosenRootAfterDiscovery() throws {
    let fixture = try ImportFixture(), outside = try ImportFixture(); defer { fixture.remove(); outside.remove() }
    try outside.put("file", Data("external".utf8))
    try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("Bookmarks"), withDestinationURL: outside.root.appendingPathComponent("file"))
    #expect(throws: MigrationFailure.unreadable) { try MigrationInput.data("Bookmarks", in: fixture.root, cancellation: token) }
    #expect(throws: MigrationFailure.unreadable) { try MigrationInput.file("../outside", in: fixture.root) }
}

@Test func orionReportsSeparatorsAndUnsupportedLinks() throws {
    let nodes: [String: Any] = [
        "separator": ["id": "separator", "parentId": "0", "title": "", "type": "separator", "index": 0],
        "internal": ["id": "internal", "parentId": "0", "title": "Internal", "type": "bookmark", "index": 1, "url": "orion://settings"]]
    let values = try MigrationOrion.bookmarks(PropertyListSerialization.data(fromPropertyList: nodes, format: .binary, options: 0), cancellation: token)
    #expect(values.bookmarks.isEmpty)
    #expect(values.notices == ["2 separators or unsupported bookmark URLs omitted."])
}

@Test func orionBoundsSharedBinaryPlistStringsAfterExpansion() throws {
    let title = String(repeating: "x", count: MigrationLimits.field)
    let nodes = Dictionary(uniqueKeysWithValues: (0..<1024).map { index in
        ("item:\(index)", ["id": "item:\(index)", "parentId": "0", "title": title, "type": "folder", "index": index] as [String: Any])
    })
    let data = try PropertyListSerialization.data(fromPropertyList: nodes, format: .binary, options: 0)
    #expect(data.count < 1_048_576)
    #expect(throws: MigrationFailure.tooLarge) { try MigrationOrion.bookmarks(data, cancellation: token) }
}

@Test func zenWorkspacesKeepEssentialsFoldersAndMirrorsSeparateFromProfiles() throws {
    let fixture = try ImportFixture(); defer { fixture.remove() }
    var pin = ffTab("https://pin.invalid", id: "pin", workspace: "one"); pin["pinned"] = true; pin["groupId"] = "folder"
    var essential = ffTab("https://essential.invalid", id: "essential"); essential["zenEssential"] = true
    let other = ffTab("https://other.invalid", id: "other", workspace: "two")
    let spaces: [[String: Any]] = [["uuid": "one", "name": "Same", "position": 0], ["uuid": "two", "name": "Same", "position": 1]]
    let folders: [[String: Any]] = [["id": "folder", "name": "Project", "workspaceId": "one", "parentId": NSNull()], ["id": "empty", "name": "Empty", "workspaceId": "one", "parentId": "folder"]]
    try fixture.session("zen-sessions.jsonlz4", ["lastCollected": 123, "spaces": spaces, "tabs": [pin, essential, pin, other], "folders": folders])
    let sources = try MigrationBrowser.zen.discover(in: fixture.root, cancellation: token)
    #expect(sources.count == 2 && Set(sources.map(\.id)).count == 2)
    let reader = MigrationZen(temporaryRoot: fixture.root.appendingPathComponent("scratch"))
    let one = try reader.read(sources[0], categories: [.bookmarks, .tabs], cancellation: token)
    #expect(one.tabs.map(\.id) == ["pin", "essential"])
    #expect(one.bookmarks.contains { $0.id == "folder:folder" && $0.children.count == 2 })
    let two = try reader.read(sources[1], categories: [.tabs], cancellation: token)
    #expect(two.tabs.map(\.id) == ["essential", "other"])
    #expect(one.notices.contains { $0.contains("containers") })
}

@Test func zenLegacyPinnedIDsDeduplicateAcrossMirroredWindows() throws {
    let fixture = try ImportFixture(); defer { fixture.remove() }
    var pin = ffTab("https://legacy.invalid", workspace: "one"); pin["zenPinnedId"] = "legacy"; pin["zenEssential"] = "true"
    let window: [String: Any] = ["spaces": [["uuid": "one", "name": "Work"]], "tabs": [pin], "folders": []]
    try fixture.session("sessionstore.jsonlz4", ["version": ["sessionrestore", 1], "windows": [window, window]])
    let sources = try MigrationBrowser.zen.discover(in: fixture.root, cancellation: token)
    let values = try MigrationZen(temporaryRoot: fixture.root.appendingPathComponent("scratch")).read(try #require(sources.first), categories: [.tabs], cancellation: token)
    #expect(values.tabs.count == 1 && values.tabs[0].pinned)
}

@Test func zenLegacyWorkspacesComeFromPlacesRatherThanGuessedWindowNames() throws {
    let fixture = try ImportFixture(); defer { fixture.remove() }
    var pin = ffTab("https://legacy.invalid", workspace: "one"); pin["zenPinnedId"] = "pin"; pin["pinned"] = true
    try fixture.session("sessionstore.jsonlz4", ["version": ["sessionrestore", 1], "windows": [["tabs": [pin], "folders": []]]])
    var database: OpaquePointer?
    guard sqlite3_open(fixture.root.appendingPathComponent("places.sqlite").path, &database) == SQLITE_OK, let database else { throw MigrationFailure.storage }
    defer { sqlite3_close(database) }
    #expect(sqlite3_exec(database, "CREATE TABLE zen_workspaces(uuid TEXT, name TEXT, position INTEGER, container_id INTEGER, created_at INTEGER); INSERT INTO zen_workspaces VALUES ('one', 'Work', 0, 4, 1);", nil, nil, nil) == SQLITE_OK)
    let sources = try MigrationBrowser.zen.discover(in: fixture.root, cancellation: token, temporaryRoot: fixture.root.appendingPathComponent("scratch"))
    #expect(sources.count == 2)
    #expect(sources[0].categories == [.bookmarks, .history])
    #expect(sources[1].part == "one")
    let values = try MigrationZen(temporaryRoot: fixture.root.appendingPathComponent("scratch")).read(sources[1], categories: [.tabs], cancellation: token)
    #expect(values.tabs.count == 1)
}

@Test func tabValidationRefusesDuplicatesInvalidAddressesAndOversizeImports() throws {
    let source = MigrationSource(id: "source", browser: "Chrome", profile: "Fixture", location: URL(fileURLWithPath: "/unused"), format: "chromium", categories: [.tabs])
    let tab = MigrationTab(id: "id", url: try #require(URL(string: "https://fixture.invalid")), title: "Tab")
    #expect(throws: MigrationFailure.malformed) { try MigrationPlan(source: source, destination: UUID(), categories: [.tabs], values: MigrationValues(tabs: [tab, tab])) }
    #expect(throws: MigrationFailure.tooLarge) { try MigrationPlan(source: source, destination: UUID(), categories: [.tabs], values: MigrationValues(tabs: Array(repeating: tab, count: 2001))) }
    let invalid = MigrationTab(id: "bad", url: try #require(URL(string: "file:///private")), title: "Invalid")
    #expect(throws: MigrationFailure.malformed) { try MigrationPlan(source: source, destination: UUID(), categories: [.tabs], values: MigrationValues(tabs: [invalid])) }
}

@Test func chromiumSessionOrderGUIDAndAppWindowFilteringAreExplicit() throws {
    let guid = "E10FEC22-36EF-426F-8CAA-3BFAC813D932"
    let payload = le(42) + snssString(guid)
    let data = snss() + command(28, le(payload.count) + payload) + command(0, le(1) + le(43))
        + command(2, le(43) + le(0)) + command(2, le(42) + le(1)) + navigation(43, 0, "https://first.invalid")
    let values = try MigrationChromiumSession.decode(data, identity: "fixture", cancellation: token)
    #expect(values.tabs.map(\.url.absoluteString) == ["https://first.invalid", "https://current.invalid"])
    #expect(values.tabs[1].id == guid.lowercased())
    #expect(try MigrationChromiumSession.decode(data + command(9, le(1) + le(2)), identity: "fixture", cancellation: token).tabs.isEmpty)
}

@Test func profilesINIBoundsIncludeTheLastProfile() throws {
    let ini = (0...200).map { "[Profile\($0)]\nPath=p\($0)\nIsRelative=1" }.joined(separator: "\n")
    #expect(throws: MigrationFailure.tooLarge) { try MigrationProfiles.profilesINI(ini) }
}
