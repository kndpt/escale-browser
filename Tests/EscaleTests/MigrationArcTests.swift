// Arc's sidebar fixtures follow the structure observed in Arc 1.166.0: keyed
// arrays alternating an id and its object, pinned/unpinned containers per
// Space and Favorites per profile. Values are synthetic; no personal sidebar.
import Foundation
import Testing
import SQLite3
@testable import Escale

private struct ArcFixture {
    let root: URL
    var spaces: [[String: Any]] = []
    var items: [[String: Any]] = []
    var favorites: [Any] = []
    var version = 1

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("arc-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("User Data"), withIntermediateDirectories: true)
    }

    mutating func item(_ id: String, parent: String?, _ data: [String: Any], title: String? = nil, children: [String] = []) {
        items.append(["id": id, "parentID": parent.map { $0 as Any } ?? NSNull(), "childrenIds": children,
                      "title": title.map { $0 as Any } ?? NSNull(),
                      "data": data, "createdAt": 0, "isUnread": false, "originatingDevice": "fixture"])
    }
    mutating func tab(_ id: String, in parent: String, _ url: String, saved: String? = "Saved", title: String? = nil) {
        item(id, parent: parent, ["tab": ["savedURL": url, "savedTitle": saved.map { $0 as Any } ?? NSNull(), "timeLastActiveAt": 0]], title: title)
    }
    mutating func space(_ id: String, _ title: String, profile: [String: Any], pinned: [String], today: [String] = []) {
        item("pin-\(id)", parent: nil, ["itemContainer": ["containerType": ["spaceItems": ["_0": id]]]], children: pinned)
        item("day-\(id)", parent: nil, ["itemContainer": ["containerType": ["spaceItems": ["_0": id]]]], children: today)
        spaces.append(["id": id, "title": title, "profile": profile,
                       "containerIDs": ["pinned", "pin-\(id)", "unpinned", "day-\(id)"]])
    }
    mutating func favorites(_ profile: [String: Any], _ children: [String]) {
        item("fav", parent: nil, ["itemContainer": ["containerType": ["topApps": ["_0": profile]]]], children: children)
        favorites += [profile, "fav"]
    }

    func write(_ edit: (inout [String: Any]) -> Void = { _ in }) throws {
        func keyed(_ values: [[String: Any]]) -> [Any] { values.flatMap { [$0["id"] as Any, $0] } }
        var top: [String: Any] = ["version": version, "sidebar": ["containers": [
            ["global": [:]], ["spaces": keyed(spaces), "items": keyed(items), "topAppsContainerIDs": favorites]]]]
        edit(&top)
        try JSONSerialization.data(withJSONObject: top).write(to: root.appendingPathComponent("StorableSidebar.json"))
    }

    func history(_ profile: String) throws {
        let folder = root.appendingPathComponent("User Data/\(profile)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(folder.appendingPathComponent("History").path, &db) == SQLITE_OK, let db else { throw MigrationFailure.unreadable }
        defer { sqlite3_close(db) }
        let sql = "CREATE TABLE urls(url TEXT,title TEXT,visit_count INTEGER,last_visit_time INTEGER,hidden INTEGER);" +
            "INSERT INTO urls VALUES ('https://history.invalid','History',3,13434292800000000,0);"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw MigrationFailure.malformed }
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
    var reader: MigrationArc { MigrationArc(temporaryRoot: root.appendingPathComponent("scratch")) }
}

private let personal: [String: Any] = ["default": true]
private let client: [String: Any] = ["custom": ["_0": ["directoryBasename": "Profile 1"]]]

/// Two Spaces share the default profile; a third uses a custom profile.
private func standard() throws -> ArcFixture {
    var arc = try ArcFixture()
    arc.space("work", "Work", profile: personal, pinned: ["docs", "dup-1", "dup-2", "empty", "ext", "easel", "gone"],
              today: ["today-1", "today-folder"])
    arc.item("docs", parent: "pin-work", ["list": [:]], title: "Docs", children: ["guide", "nested"])
    arc.tab("guide", in: "docs", "https://docs.invalid/guide", saved: "Saved guide", title: "Renamed guide")
    arc.item("nested", parent: "docs", ["list": [:]], title: "Docs", children: ["deep"])
    arc.tab("deep", in: "nested", "https://docs.invalid/deep", saved: nil)
    arc.tab("dup-1", in: "pin-work", "https://same.invalid/")
    arc.tab("dup-2", in: "pin-work", "https://same.invalid/")
    arc.item("empty", parent: "pin-work", ["list": [:]], title: "Empty")
    arc.tab("ext", in: "pin-work", "chrome-extension://abc/page.html")
    arc.item("easel", parent: "pin-work", ["easel": ["title": "Board"]])
    arc.tab("today-1", in: "day-work", "https://today.invalid/1")
    arc.item("today-folder", parent: "day-work", ["list": [:]], title: "Split", children: ["today-2"])
    arc.tab("today-2", in: "today-folder", "https://today.invalid/2")
    arc.space("home", "Home", profile: personal, pinned: ["recipe"])
    arc.tab("recipe", in: "pin-home", "https://recipes.invalid/")
    arc.space("client", "Client", profile: client, pinned: ["ticket"])
    arc.tab("ticket", in: "pin-client", "https://tickets.invalid/")
    arc.favorites(personal, ["mail", "calendar"])
    arc.tab("mail", in: "fav", "https://mail.invalid/")
    arc.tab("calendar", in: "fav", "https://calendar.invalid/")
    try arc.write()
    try Data(#"{"profile":{"info_cache":{"Default":{"name":"Personal"},"Profile 1":{"name":"Client"}}}}"#.utf8)
        .write(to: arc.root.appendingPathComponent("User Data/Local State"))
    try arc.history("Default")
    return arc
}

@Test func arcSpacesAreSourcesWithTheirProfileAndCategories() throws {
    let arc = try standard()
    defer { arc.clean() }
    let sources = try MigrationBrowser.arc.discover(in: arc.root, cancellation: MigrationCancellation())
    #expect(sources.map(\.profile) == ["Work · Personal", "Home · Personal", "Client · Client"])
    #expect(sources.map(\.categories) == [[.bookmarks, .history], [.bookmarks, .history], [.bookmarks]])
    #expect(Set(sources.map(\.id)).count == 3)
    #expect(try MigrationBrowser.arc.discover(in: arc.root, cancellation: MigrationCancellation()).map(\.id) == sources.map(\.id))
}

@Test func arcPinnedTreeKeepsOrderFoldersAndFavoritesAndReportsLosses() throws {
    let arc = try standard()
    defer { arc.clean() }
    let work = try #require(MigrationBrowser.arc.discover(in: arc.root, cancellation: MigrationCancellation()).first)
    let values = try arc.reader.read(work, categories: [.bookmarks], cancellation: MigrationCancellation())
    #expect(values.bookmarks.map(\.title) == ["Favorites", "Docs", "Saved", "Saved", "Empty"])
    #expect(values.bookmarks[0].children.map { $0.url?.host } == ["mail.invalid", "calendar.invalid"])
    #expect(values.bookmarks[1].children.map(\.title) == ["Renamed guide", "Docs"])
    #expect(values.bookmarks[1].children[1].children[0].title == "https://docs.invalid/deep")
    #expect(values.bookmarks[2].id != values.bookmarks[3].id)
    #expect(values.bookmarks[4].children.isEmpty && values.bookmarks[4].url == nil)
    #expect(values.notices.contains("2 Today tabs are not imported; only pinned tabs and Favorites are."))
    #expect(values.notices.contains { $0.hasPrefix("3 sidebar items are not imported") })
    #expect(values.notices.contains { $0.hasPrefix("Favorites are shared by 2 Arc Spaces") })
    let client = try #require(MigrationBrowser.arc.discover(in: arc.root, cancellation: MigrationCancellation()).last)
    #expect(try arc.reader.read(client, categories: [.bookmarks], cancellation: MigrationCancellation()).bookmarks.map(\.title) == ["Saved"])
}

@Test func arcReimportKeepsIdentitiesAfterRenamesAndLeavesTheSourceUnchanged() throws {
    var arc = try standard()
    defer { arc.clean() }
    let files = [arc.root.appendingPathComponent("StorableSidebar.json"), arc.root.appendingPathComponent("User Data/Default/History")]
    let before = try files.map { try Data(contentsOf: $0) }
    let work = try #require(MigrationBrowser.arc.discover(in: arc.root, cancellation: MigrationCancellation()).first)
    let values = try arc.reader.read(work, categories: [.bookmarks, .history], cancellation: MigrationCancellation())
    #expect(values.history.map(\.url.host) == ["history.invalid"])
    #expect(values.notices.contains { $0.hasPrefix("This history belongs to an Arc profile shared by 2 Spaces") })
    let plan = try MigrationPlan(source: work, destination: UUID(), categories: [.bookmarks, .history], values: values)
    let first = plan.bookmarks(keeping: [])
    #expect(try files.map { try Data(contentsOf: $0) } == before)

    let index = try #require(arc.items.firstIndex { $0["id"] as? String == "guide" })
    arc.items[index]["title"] = "Renamed again"
    try arc.write()
    let again = try MigrationPlan(source: work, destination: plan.destination, categories: [.bookmarks],
                                  values: arc.reader.read(work, categories: [.bookmarks], cancellation: MigrationCancellation()))
    #expect(again.bookmarks(keeping: first.roots).added == 0)
    #expect(again.bookmarks(keeping: first.roots).roots == first.roots)
}

@Test func arcCustomProfileHistoryAndUnknownProfilesStaySeparate() throws {
    var arc = try standard()
    defer { arc.clean() }
    try arc.history("Profile 1")
    #expect(try MigrationBrowser.arc.discover(in: arc.root, cancellation: MigrationCancellation()).last?.categories == [.bookmarks, .history])
    arc.spaces[2]["profile"] = ["future": ["_0": "shape"]]
    try arc.write()
    let client = try #require(MigrationBrowser.arc.discover(in: arc.root, cancellation: MigrationCancellation()).last)
    #expect(client.categories == [.bookmarks])
    arc.spaces[2]["profile"] = ["custom": ["_0": ["directoryBasename": "../escape"]]]
    try arc.write()
    #expect(throws: MigrationFailure.malformed) { try MigrationBrowser.arc.discover(in: arc.root, cancellation: MigrationCancellation()) }
}

@Test func arcRefusesUnknownVersionsAndDamagedSidebars() throws {
    var arc = try standard()
    defer { arc.clean() }
    let token = MigrationCancellation()
    arc.version = 2
    try arc.write()
    #expect(throws: MigrationFailure.unsupported) { try MigrationBrowser.arc.discover(in: arc.root, cancellation: token) }
    arc.version = 1
    try Data("{\"version\":1,".utf8).write(to: arc.root.appendingPathComponent("StorableSidebar.json"))
    #expect(throws: MigrationFailure.malformed) { try MigrationBrowser.arc.discover(in: arc.root, cancellation: token) }
    var odd = arc
    let last = try #require(odd.items.last)
    odd.items.removeLast()
    try odd.write { top in
        // One key without its object: the keyed array has an odd length.
        let items = odd.items.flatMap { [$0["id"] as Any, $0] } + [last["id"] as Any]
        top["sidebar"] = ["containers": [["global": [:]], ["spaces": odd.spaces.flatMap { [$0["id"] as Any, $0] },
                                                          "items": items, "topAppsContainerIDs": odd.favorites]]]
    }
    #expect(throws: MigrationFailure.malformed) { try MigrationBrowser.arc.discover(in: arc.root, cancellation: token) }
    arc.spaces[0]["containerIDs"] = ["unpinned", "day-work"]
    try arc.write()
    #expect(throws: MigrationFailure.malformed) { try MigrationBrowser.arc.discover(in: arc.root, cancellation: token) }
    try FileManager.default.removeItem(at: arc.root.appendingPathComponent("StorableSidebar.json"))
    #expect(throws: (any Error).self) { try MigrationBrowser.arc.discover(in: arc.root, cancellation: token) }
    token.cancel()
    #expect(throws: MigrationFailure.cancelled) { try MigrationBrowser.arc.discover(in: arc.root, cancellation: token) }
}

@Test func arcSpaceRemovedAfterDiscoveryIsAChangedSource() throws {
    var arc = try standard()
    defer { arc.clean() }
    let home = try #require(MigrationBrowser.arc.discover(in: arc.root, cancellation: MigrationCancellation())
        .first { $0.profile.hasPrefix("Home") })
    arc.spaces.remove(at: 1)
    try arc.write()
    #expect(throws: MigrationFailure.sourceChanged) {
        try arc.reader.read(home, categories: [.bookmarks], cancellation: MigrationCancellation())
    }
}

@Test func arcRefusesSpacesThatAreRepeatedOrPointAtAnotherSpacesTabs() throws {
    var arc = try standard()
    defer { arc.clean() }
    let token = MigrationCancellation()
    var repeated = arc
    repeated.spaces.append(repeated.spaces[1])
    try repeated.write()
    #expect(throws: MigrationFailure.malformed) { try MigrationBrowser.arc.discover(in: arc.root, cancellation: token) }
    arc.spaces[0]["containerIDs"] = ["pinned", "pin-home", "unpinned", "day-work"]
    try arc.write()
    #expect(throws: MigrationFailure.malformed) { try MigrationBrowser.arc.discover(in: arc.root, cancellation: token) }
}

@Test func arcRefusesMoreThanTwoHundredSpaces() throws {
    var arc = try ArcFixture()
    defer { arc.clean() }
    for index in 0...200 { arc.space("s\(index)", "Space \(index)", profile: personal, pinned: []) }
    try arc.write()
    #expect(throws: MigrationFailure.tooLarge) { try MigrationBrowser.arc.discover(in: arc.root, cancellation: MigrationCancellation()) }
}

@Test func arcTodayCountStaysBoundedInADeepTree() throws {
    var arc = try ArcFixture()
    defer { arc.clean() }
    let depth = 40_000
    arc.space("deep", "Deep", profile: personal, pinned: ["site"], today: ["level-0"])
    arc.tab("site", in: "pin-deep", "https://deep.invalid/")
    for level in 0..<depth {
        arc.item("level-\(level)", parent: level == 0 ? "day-deep" : "level-\(level - 1)", ["list": [:]], title: "Level",
                 children: level + 1 < depth ? ["level-\(level + 1)"] : ["leaf"])
    }
    arc.tab("leaf", in: "level-\(depth - 1)", "https://deep.invalid/leaf")
    try arc.write()
    let source = try #require(MigrationBrowser.arc.discover(in: arc.root, cancellation: MigrationCancellation()).first)
    let values = try arc.reader.read(source, categories: [.bookmarks], cancellation: MigrationCancellation())
    #expect(values.bookmarks.map(\.title) == ["Saved"])
    #expect(!values.notices.contains { $0.contains("Today tab") })
}

/// MigrationSQLite accepts only ordinary files, so a History turned into a link
/// after discovery is refused before anything outside the Arc folder is read.
@Test func arcHistoryLinkedOutsideTheArcFolderIsRefusedAtRead() throws {
    let arc = try standard()
    defer { arc.clean() }
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent("arc-outside-\(UUID())")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    let work = try #require(MigrationBrowser.arc.discover(in: arc.root, cancellation: MigrationCancellation()).first)
    let history = arc.root.appendingPathComponent("User Data/Default/History")
    try FileManager.default.moveItem(at: history, to: outside.appendingPathComponent("History"))
    try FileManager.default.createSymbolicLink(at: history, withDestinationURL: outside.appendingPathComponent("History"))
    #expect(throws: MigrationFailure.unreadable) {
        try arc.reader.read(work, categories: [.history], cancellation: MigrationCancellation())
    }
}
