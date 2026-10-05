// Synthetic addresses cover routing boundaries without a page or singleton.
// Persistence uses an explicit temporary file, including a corrupt snapshot;
// every assertion exercises the production matcher and ordered writer.
import Foundation
import Testing
@testable import Escale

@Suite struct LinkRuleTests {
    private let space = UUID()

    @Test func hostAndSubdomains() throws {
        var rule = LinkRule(host: "meet.google.com", destination: space)
        for text in ["https://meet.google.com/a", "http://MEET.GOOGLE.COM./a"] {
            #expect(rule.matches(try #require(URL(string: text))))
        }
        for text in ["https://meet.google.com.example.org", "https://evilmeet.google.com", "https://x.meet.google.com", "file://meet.google.com/a", "https://meet.google.com@evil.org", "https://evil.org/?meet.google.com"] {
            #expect(!rule.matches(try #require(URL(string: text))))
        }
        rule.subdomains = true
        #expect(rule.matches(try #require(URL(string: "https://x.y.meet.google.com"))))
        #expect(!rule.matches(try #require(URL(string: "https://evilmeet.google.com"))))
        #expect(!rule.matches(try #require(URL(string: "https://meet.google.com.evil.org"))))
    }

    @Test func portsAndPaths() throws {
        var rule = LinkRule(scope: .path, host: "localhost", port: "3000", path: "/project", destination: space)
        for text in ["http://localhost:3000/project", "http://localhost:3000/project/a?q=1#f"] {
            #expect(rule.matches(try #require(URL(string: text))))
        }
        for text in ["http://localhost:3001/project", "http://localhost:3000/projects", "http://localhost:3000/Project", "http://localhost:3000/project%2Fsecret", "http://localhost:3000/other?path=/project"] {
            #expect(!rule.matches(try #require(URL(string: text))))
        }
        rule.port = "80"
        #expect(rule.matches(try #require(URL(string: "http://localhost/project"))))
        #expect(!rule.matches(try #require(URL(string: "https://localhost/project"))))
        rule.port = ""
        #expect(rule.matches(try #require(URL(string: "https://localhost:8443/project"))))
        rule.path = "/project/"
        #expect(!rule.matches(try #require(URL(string: "http://localhost/project"))))
    }

    @Test func exactIncludesQueryFragmentAndScheme() throws {
        let rule = LinkRule(scope: .exact, exact: "https://EXAMPLE.org:443/a?x=1#f", destination: space)
        #expect(rule.matches(try #require(URL(string: "https://example.org/a?x=1#f"))))
        for text in ["http://example.org/a?x=1#f", "https://example.org/a?x=2#f", "https://example.org/a?x=1#other", "https://example.org/a?x=1", "https://example.org/a/child?x=1#f"] {
            #expect(!rule.matches(try #require(URL(string: text))))
        }
    }

    @Test func validationPriorityAndMissingDestination() throws {
        let first = LinkRule(host: "example.org", destination: space)
        let other = UUID()
        let second = LinkRule(scope: .path, host: "example.org", path: "/a", destination: other)
        let url = try #require(URL(string: "https://example.org/a"))
        #expect(LinkRule.winner(in: [first, second], for: url, spaces: [space, other])?.id == first.id)
        #expect(LinkRule.winner(in: [second, first], for: url, spaces: [space, other])?.id == second.id)
        #expect(LinkRule.winner(in: [second, first], for: url, spaces: [space])?.id == first.id)
        #expect(LinkRule.winner(in: [second], for: url, spaces: [space]) == nil)
        for host in ["", "https://example.org", "example.org:3000", "example.org/a", "example.org?x=1", "bad host", "user@example.org"] {
            #expect(LinkRule(host: host, destination: space).error != nil)
        }
        for port in ["0", "65536", "x", "-1"] {
            #expect(LinkRule(host: "localhost", port: port, destination: space).error != nil)
        }
        for path in ["a", "/a?x=1", "/a#b", "/two words"] {
            #expect(LinkRule(scope: .path, host: "localhost", path: path, destination: space).error != nil)
        }
        #expect(LinkRule.validation([first, first]) != nil)
        #expect(LinkRule.validation((0...128).map { _ in LinkRule(host: "example.org", destination: space) }) != nil)
        #expect(LinkRule(host: String(repeating: "a", count: 2049), destination: space).error != nil)
    }

    /// Trying a link reads the draft as it stands: invalid or orphaned rules
    /// never win, and order decides between two that match.
    @Test func trialFollowsTheDraft() {
        let other = UUID()
        let site = LinkRule(host: "meet.google.com", destination: space)
        let path = LinkRule(scope: .path, host: "meet.google.com", path: "/abc", destination: other)
        let broken = LinkRule(host: "bad host", destination: space)
        #expect(LinkTrial("", in: [site], spaces: [space]) == .empty)
        #expect(LinkTrial("  ", in: [site], spaces: [space]) == .empty)
        for text in ["meet.google.com", "ftp://meet.google.com/a", "https://user:pw@meet.google.com/a"] {
            #expect(LinkTrial(text, in: [site], spaces: [space]) == .invalid)
        }
        #expect(LinkTrial("https://example.org", in: [site], spaces: [space]) == .usual)
        #expect(LinkTrial(" https://meet.google.com/abc ", in: [broken, path, site], spaces: [space, other]) == .rule(1))
        #expect(LinkTrial("https://meet.google.com/abc", in: [broken, site, path], spaces: [space, other]) == .rule(1))
        #expect(LinkTrial("https://meet.google.com/abc", in: [path, site], spaces: [space]) == .rule(1))
    }

    /// A rule reads without its editor: the site, then how much of it.
    @Test func summaryNamesSiteAndReach() {
        var rule = LinkRule(destination: space)
        #expect(rule.blank && rule.site == "New rule" && !rule.precise)
        rule.host = "meet.google.com"
        #expect(rule.site == "meet.google.com" && rule.reach == "Whole site" && !rule.precise)
        rule.subdomains = true
        rule.port = "8443"
        #expect(rule.reach == "Site and subdomains · port 8443" && rule.precise)
        rule.scope = .path
        rule.path = "/project"
        #expect(rule.reach == "Pages under /project, subdomains too · port 8443")
        rule.scope = .exact
        #expect(rule.blank)
        rule.exact = "https://meet.google.com/abc"
        #expect(rule.site == "https://meet.google.com/abc" && rule.reach == "This exact address")
    }

    @Test @MainActor func persistenceRemovalAndCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rules.json")
        let routes = LinkRoutes(file: file)
        let rule = LinkRule(host: "meet.google.com", destination: space)
        #expect(routes.rules.isEmpty)
        #expect(routes.save([rule], spaces: [space]))
        Writer.to(file).flush()
        #expect(LinkRoutes(file: file).rules == [rule])
        #expect(!routes.save([rule], spaces: []))
        #expect(routes.rules == [rule])
        routes.remove(space: space)
        Writer.to(file).flush()
        #expect(LinkRoutes(file: file).rules.isEmpty)
        try Data("corrupt".utf8).write(to: file)
        let broken = LinkRoutes(file: file)
        #expect(broken.rules.isEmpty)
        #expect(broken.problem != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0 != "rules.json" })
    }
}
