// Aside's synthetic profiles prove bounded discovery and native identities.
// No fixture reads a personal profile; escapes and cancellation are rejected
// before acquisition, while an absent credential store remains irrelevant.
import Foundation
import Testing
@testable import Escale

private func asideFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("aside-fixture-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func asideDiscoveryKeepsProfilesSeparateAndIgnoresSecrets() throws {
    let root = try asideFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["Default", "Profile 1", "AsidePasswordManager"] {
        let profile = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("not parsed during discovery".utf8).write(to: profile.appendingPathComponent("Bookmarks"))
    }
    try Data(#"{"profile":{"info_cache":{"Default":{"name":"Personal"},"Profile 1":{"name":"Work — été"}}}}"#.utf8)
        .write(to: root.appendingPathComponent("Local State"))
    try Data().write(to: root.appendingPathComponent("Profile 1/History"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Profile alias"), withDestinationURL: root.appendingPathComponent("Default"))
    let sources = try MigrationBrowser.aside.discover(in: root, cancellation: MigrationCancellation())
    #expect(sources.map(\.profile) == ["Personal", "Work — été"])
    #expect(sources[0].categories == [.bookmarks])
    #expect(sources[1].categories == [.bookmarks, .history])
    #expect(Set(sources.map(\.id)).count == 2)
    #expect(try MigrationBrowser.aside.discover(in: root, cancellation: MigrationCancellation()).map(\.id) == sources.map(\.id))
}

@Test func asideDiscoveryRejectsMalformedNamesAndDoesNotFollowExternalProfiles() throws {
    let root = try asideFixture(), outside = try asideFixture()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    try Data().write(to: outside.appendingPathComponent("Bookmarks"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Default"), withDestinationURL: outside)
    #expect(try MigrationBrowser.aside.discover(in: root, cancellation: MigrationCancellation()).isEmpty)
    try Data(#"{"profile":{"info_cache":{"../outside":{"name":"Escaped"}}}}"#.utf8).write(to: root.appendingPathComponent("Local State"))
    #expect(throws: MigrationFailure.malformed) { try MigrationBrowser.aside.discover(in: root, cancellation: MigrationCancellation()) }
    let token = MigrationCancellation(); token.cancel()
    #expect(throws: MigrationFailure.cancelled) { try MigrationBrowser.aside.discover(in: root, cancellation: token) }
}

@Test func asideTestLocationNeverFallsBackToPersonalProfile() throws {
    let root = try asideFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let absent = root.appendingPathComponent("not-created")
    for brand in MigrationBrowser.allCases where brand.automatic {
        let selected = try #require(brand.location(user: URL(fileURLWithPath: "/never-read"), testRoot: absent))
        #expect(selected == absent)
        #expect(throws: (any Error).self) { try brand.discover(in: selected, cancellation: MigrationCancellation()) }
    }
}

@Test func asideDirectBookmarksKeepIdentityAcrossDiscoveryAndSourceRename() throws {
    let root = try asideFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = root.appendingPathComponent("Default")
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    let data = Data(#"{"version":1,"roots":{"bookmark_bar":{"guid":"root","type":"folder","name":"Bar","children":[{"guid":"site","type":"url","name":"Before","url":"https://aside.test/path?a=1&section=2"}]}}}"#.utf8)
    try data.write(to: profile.appendingPathComponent("Bookmarks"))
    let source = try #require(MigrationBrowser.aside.discover(in: root, cancellation: MigrationCancellation()).first)
    let reader = MigrationChromium(temporaryRoot: root.appendingPathComponent("scratch"))
    let values = try reader.read(source, categories: [.bookmarks], cancellation: MigrationCancellation())
    let plan = try MigrationPlan(source: source, destination: UUID(), categories: [.bookmarks], values: values)
    let first = plan.bookmarks(keeping: [])
    try Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "Before", with: "After").utf8)
        .write(to: profile.appendingPathComponent("Bookmarks"))
    let again = try MigrationPlan(source: source, destination: plan.destination, categories: [.bookmarks],
                                  values: reader.read(source, categories: [.bookmarks], cancellation: MigrationCancellation()))
    #expect(again.bookmarks(keeping: first.roots).added == 0)
    #expect(again.bookmarks(keeping: first.roots).roots == first.roots)
    #expect(values.bookmarks[0].children[0].url?.absoluteString == "https://aside.test/path?a=1&section=2")
}
