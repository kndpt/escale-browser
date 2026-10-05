// The editing journey is tested as values: pasted addresses, explicit scope
// choices and unfinished drafts must survive navigation without changing the
// active rules. Native input and menu entry are exercised by the app scenario.
import Foundation
import Testing
@testable import Escale

@Suite @MainActor struct LinkDraftTests {
    private let space = UUID()

    @Test func copiedAddressInfersUsefulScope() throws {
        for (text, scope, host, port, path) in [
            ("github.com", LinkRule.Scope.host, "github.com", "", "/"),
            ("https://github.com/", .host, "github.com", "", "/"),
            (" https://github.com/acme ", .path, "github.com", "", "/acme"),
            ("localhost:3000/project", .path, "localhost", "3000", "/project"),
            ("http://[::1]:8080/a", .path, "[::1]", "8080", "/a"),
            ("https://example.org/a?x=1#f", .exact, "example.org", "", "/a")
        ] {
            let draft = LinkDraft(rules: [])
            #expect(draft.add(destination: space, address: text))
            let rule = try #require(draft.rules.first)
            #expect(rule.scope == scope && rule.host == host && rule.port == port && rule.path == path)
            #expect(draft.error(spaces: [space]) == nil)
            #expect(draft.address(for: rule) == text)
        }
    }

    @Test func typingThenChoosingScopePreservesTheAddress() throws {
        let draft = LinkDraft(rules: [])
        draft.add(destination: space)
        let id = try #require(draft.editing)
        for text in ["g", "github.com", "https://github.com/acme"] { draft.enter(text, for: id) }
        #expect(draft.rules[0].scope == .path)
        draft.scope(.host, for: id)
        draft.enter("https://github.com/acme/checkout?q=1", for: id)
        #expect(draft.rules[0].scope == .host)
        #expect(draft.rules[0].matches(try #require(URL(string: "http://github.com/other"))))
        draft.scope(.path, for: id)
        #expect(!draft.rules[0].matches(try #require(URL(string: "https://github.com/acme/checkouts"))))
        draft.scope(.exact, for: id)
        #expect(draft.rules[0].exact == "https://github.com/acme/checkout?q=1")
        #expect(!draft.rules[0].matches(try #require(URL(string: "http://github.com/acme/checkout?q=1"))))
    }

    @Test func invalidInputCannotSaveOrKeepMatchingAnOlderAddress() throws {
        let draft = LinkDraft(rules: [])
        draft.add(destination: space, address: "https://github.com/acme")
        let id = try #require(draft.editing)
        for text in ["", "https://", "bad host", "ftp://github.com", "https://user:pw@github.com/a", "localhost:65536", String(repeating: "a", count: 2049)] {
            draft.enter(text, for: id)
            #expect(draft.error(spaces: [space]) != nil)
            #expect(!draft.rules[0].matches(try #require(URL(string: "https://github.com/acme"))))
        }
        draft.enter("https://github.com/acme", for: id)
        #expect(draft.error(spaces: [space]) == nil)
    }

    @Test func existingScopeAndCriteriaSurviveEditing() throws {
        let rule = LinkRule(scope: .path, host: "localhost", subdomains: true, port: "3000", path: "/project%2Fone", destination: space)
        let draft = LinkDraft(rules: [rule])
        #expect(draft.address(for: rule) == "localhost:3000/project%2Fone")
        draft.enter("https://localhost:8443/project%2Ftwo?ignored=1", for: rule.id)
        #expect(draft.rules[0].scope == .path && draft.rules[0].subdomains)
        #expect(draft.rules[0].port == "8443" && draft.rules[0].path == "/project%2Ftwo")
        #expect(draft.rules[0].matches(try #require(URL(string: "https://dev.localhost:8443/project%2Ftwo/child"))))
    }

    @Test func windowOwnsDraftAndNewEntriesAppendWithoutSaving() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let routes = LinkRoutes(file: folder.appendingPathComponent("rules.json"))
        let firstVisit = routes.draft
        firstVisit.add(destination: space, address: "https://github.com/acme")
        firstVisit.trial = "https://github.com/acme/a"
        let id = try #require(firstVisit.editing)
        let returnVisit = routes.draft
        #expect(firstVisit === returnVisit)
        #expect(returnVisit.editing == id && returnVisit.trial == firstVisit.trial)
        returnVisit.add(destination: space, address: "https://example.org/a?x=1")
        #expect(returnVisit.rules.count == 2 && routes.rules.isEmpty)
        #expect(returnVisit.address(for: returnVisit.rules[0]) == "https://github.com/acme")
        #expect(routes.save(returnVisit.rules, spaces: [space]))
        returnVisit.reset(to: routes.rules)
        #expect(!returnVisit.changed(from: routes.rules))
        Writer.to(folder.appendingPathComponent("rules.json")).flush()
        #expect(LinkRoutes(file: folder.appendingPathComponent("rules.json")).rules == routes.rules)
    }

    @Test func unchangedDraftFollowsStorageButUnfinishedWorkDoesNot() {
        let first = LinkRule(host: "github.com", destination: space)
        let draft = LinkDraft(rules: [first])
        draft.follow([first], with: [])
        #expect(draft.rules.isEmpty)
        draft.add(destination: space, address: "https://github.com/acme")
        let unfinished = draft.rules
        draft.follow([], with: [first])
        #expect(draft.rules == unfinished)
        #expect(draft.error(spaces: []) != nil)
        draft.reset(to: [first])
        #expect(draft.rules == [first] && !draft.changed(from: [first]))
    }

    @Test func quotaAndRemovalBoundTheDraft() throws {
        let draft = LinkDraft(rules: (0..<LinkRule.limit).map { _ in LinkRule(host: "example.org", destination: space) })
        #expect(!draft.add(destination: space, address: "https://example.org/new"))
        draft.remove(try #require(draft.rules.first).id)
        #expect(draft.add(destination: space, address: "https://example.org/new"))
        #expect(draft.rules.count == LinkRule.limit)
    }
}
