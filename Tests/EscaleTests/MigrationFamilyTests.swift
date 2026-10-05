// One Chromium discovery serves every brand, so each layout the family uses on
// macOS gets a synthetic fixture: a profile at the root (Opera), names from
// Local State, System/Guest profiles, Chrome's AccountBookmarks and extra
// bookmark roots (Vivaldi). No fixture is copied from a personal profile.
import Foundation
import Testing
@testable import Escale

private func familyFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("chromium-family-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func folder(_ root: URL, _ name: String, files: [String]) throws {
    let url = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    for file in files { try Data().write(to: url.appendingPathComponent(file)) }
}

private let bar = #"{"version":1,"roots":{"bookmark_bar":{"guid":"0bc5d13f-2cba-5d74-951f-3f233fe6c908","type":"folder","name":"Bookmarks bar","children":[{"guid":"GUID","type":"url","name":"TITLE","url":"URL"}]},"other":{"guid":"82b081ec-3dd3-529c-8475-ab6c344590dd","type":"folder","name":"Other bookmarks","children":[]}}}"#

private func bookmarks(_ guid: String, _ title: String, _ url: String) -> Data {
    Data(bar.replacingOccurrences(of: "GUID", with: guid).replacingOccurrences(of: "TITLE", with: title)
        .replacingOccurrences(of: "URL", with: url).utf8)
}

@Test func chromiumDiscoveryReadsAProfileAtTheRootAsOperaKeepsIt() throws {
    let root = try familyFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"profile":{"info_cache":{}}}"#.utf8).write(to: root.appendingPathComponent("Local State"))
    try bookmarks("site", "Site", "https://opera.invalid").write(to: root.appendingPathComponent("Bookmarks"))
    try Data().write(to: root.appendingPathComponent("History"))
    let sources = try MigrationProfiles.discover(in: root, browser: "Opera fixture", family: "chromium")
    #expect(sources.count == 1)
    #expect(sources[0].location == root)
    #expect(sources[0].categories == [.bookmarks, .history])
}

@Test func chromiumDiscoveryUsesLocalStateNamesAndSkipsSystemProfiles() throws {
    let root = try familyFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["Default", "Work", "System Profile", "Guest Profile", "Crashpad"] {
        try folder(root, name, files: ["Bookmarks"])
    }
    try Data(#"{"profile":{"info_cache":{"Default":{"name":"Personal"},"Work":{"name":"Client work"}}}}"#.utf8)
        .write(to: root.appendingPathComponent("Local State"))
    let sources = try MigrationProfiles.discover(in: root, browser: "Chrome fixture", family: "chromium")
    #expect(sources.map(\.profile) == ["Personal", "Client work"])
}

@Test func chromiumDiscoveryRefusesAMalformedLocalStateForEveryBrand() throws {
    let root = try familyFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try folder(root, "Default", files: ["Bookmarks"])
    try Data("{".utf8).write(to: root.appendingPathComponent("Local State"))
    #expect(throws: (any Error).self) { try MigrationProfiles.discover(in: root, browser: "Edge fixture", family: "chromium") }
    let token = MigrationCancellation(); token.cancel()
    #expect(throws: MigrationFailure.cancelled) {
        try MigrationProfiles.discover(in: root, browser: "Edge fixture", family: "chromium", cancellation: token)
    }
}

@Test func chromiumAccountBookmarksJoinLocalOnesWithoutIdentityCollisions() throws {
    let root = try familyFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try folder(root, "Default", files: [])
    let profile = root.appendingPathComponent("Default")
    try bookmarks("local", "Local", "https://local.invalid").write(to: profile.appendingPathComponent("Bookmarks"))
    try bookmarks("account", "Account", "https://account.invalid").write(to: profile.appendingPathComponent("AccountBookmarks"))
    let source = try #require(MigrationProfiles.discover(in: root, browser: "Chrome fixture", family: "chromium").first)
    #expect(source.categories == [.bookmarks])
    let values = try MigrationChromium(temporaryRoot: root.appendingPathComponent("scratch"))
        .read(source, categories: [.bookmarks], cancellation: MigrationCancellation())
    #expect(values.bookmarks.count == 4)
    #expect(values.bookmarks[2].id.hasPrefix("account:"))
    let plan = try MigrationPlan(source: source, destination: UUID(), categories: [.bookmarks], values: values)
    #expect(plan.bookmarks(keeping: []).added == 6)

    try FileManager.default.removeItem(at: profile.appendingPathComponent("Bookmarks"))
    let accountOnly = try #require(MigrationProfiles.discover(in: root, browser: "Chrome fixture", family: "chromium").first)
    #expect(accountOnly.categories == [.bookmarks])
}

@Test func chromiumBrandRootsAreReportedAndOnlyUnqualifiedBrandsWarn() throws {
    let root = try familyFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try folder(root, "Default", files: [])
    let json = String(decoding: bookmarks("site", "Site", "https://vivaldi.invalid"), as: UTF8.self)
        .replacingOccurrences(of: #""other":"#, with: #""trash":{"guid":"t","type":"folder","name":"Trash","children":[]},"other":"#)
    try Data(json.utf8).write(to: root.appendingPathComponent("Default/Bookmarks"))
    let reader = MigrationChromium(temporaryRoot: root.appendingPathComponent("scratch"))
    for (brand, warned) in [("Unqualified Chromium", true), ("Vivaldi", false), ("Aside", false)] {
        let source = try #require(MigrationProfiles.discover(in: root, browser: brand, family: "chromium").first)
        let values = try reader.read(source, categories: [.bookmarks], cancellation: MigrationCancellation())
        #expect(values.notices.contains("Additional browser-specific bookmark roots are not imported."))
        #expect(values.notices.contains { $0.hasPrefix("Browser release is unqualified") } == warned)
    }
}

@Test func chromiumDiscoveryIgnoresALocalStateLinkedFromOutside() throws {
    let root = try familyFixture(), outside = try familyFixture()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    try folder(root, "Default", files: ["Bookmarks"])
    try Data(#"{"profile":{"info_cache":{"Default":{"name":"Outside name"}}}}"#.utf8)
        .write(to: outside.appendingPathComponent("Local State"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Local State"),
                                               withDestinationURL: outside.appendingPathComponent("Local State"))
    #expect(try MigrationProfiles.discover(in: root, browser: "Chrome fixture", family: "chromium").map(\.profile) == ["Default"])
}
