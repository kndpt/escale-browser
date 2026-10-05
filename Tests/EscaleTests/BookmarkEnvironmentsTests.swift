// Value fixtures exercise validation, host matching and older bookmark files.
// No Browser, WebKit or default Store is needed to prove these rules.
import Foundation
import Testing
@testable import Escale

@Suite struct BookmarkEnvironmentsTests {
    @Test func olderBookmarksAndNestedCopiesKeepTheirValues() throws {
        let old = Data("{\"id\":\"00000000-0000-0000-0000-000000000088\",\"title\":\"Shop\",\"url\":\"https://shop.test\"}".utf8)
        var site = try JSONDecoder().decode(Bookmark.self, from: old)
        #expect(site.destinations.isEmpty)
        site.environments = [.init(name: "Recette", url: "https://recette.test/app?x=1#start")]
        let folder = Bookmark.folder("Project", [site])
        var copy = try JSONDecoder().decode(Bookmark.self, from: JSONEncoder().encode(folder))
        #expect(copy == folder)
        copy.children?[0].environments?[0].name = "Renamed"
        #expect(folder.children?[0].destinations.first?.name == "RECETTE")
    }


    @Test func persistedNamesAndColoursMigrateWithoutLosingTheFullLabel() throws {
        let old = Data(#"{"id":"00000000-0000-0000-0000-000000000088","name":"  Staging  ","url":"https://staging.test"}"#.utf8)
        let legacy = try JSONDecoder().decode(BookmarkEnvironment.self, from: old)
        #expect(legacy.name == "STAGING")
        #expect(legacy.badge == "STAG…")
        #expect(legacy.colour == nil)
        #expect(BookmarkEnvironment(name: "uat 1", url: legacy.url).badge == "UAT 1")
        for colour in Swatch.allCases {
            var entry = BookmarkEnvironment(name: "Recette", url: legacy.url, colour: colour)
            entry.name = " recette "
            let restored = try JSONDecoder().decode(BookmarkEnvironment.self, from: JSONEncoder().encode(entry))
            #expect(restored.name == "RECETTE")
            #expect(restored.colour == colour)
            #expect(restored.badge.count == 5)
        }
        let unknown = Data(#"{"id":"00000000-0000-0000-0000-000000000088","name":"dev","url":"https://dev.test","colour":"future"}"#.utf8)
        #expect(try JSONDecoder().decode(BookmarkEnvironment.self, from: unknown).colour == nil)
        let duplicate = [BookmarkEnvironment(name: "straße", url: "https://a.test"),
                         BookmarkEnvironment(name: "STRASSE", url: "https://b.test")]
        #expect(!BookmarkEnvironment.valid(duplicate))
    }

    @Test(arguments: ["", "shop.test", "https://", "https://exa mple.test", "https://example.test/a b",
                      "file:///tmp/test", "javascript:alert(1)", "https://user:pass@example.test",
                      "http://example.test:65536", "http://example.test:0", "https://example.test/" + String(repeating: "x", count: 4096)])
    func rejectsInvalidAddresses(_ text: String) {
        #expect(BookmarkEnvironment.address(text) == nil)
    }

    @Test func namesAndURLsMustBeDistinctAndBounded() {
        let first = BookmarkEnvironment(name: "Local", url: "http://LOCALHOST:80")
        let duplicate = BookmarkEnvironment(name: " local ", url: "http://localhost/")
        let issues = BookmarkEnvironment.problems([first, duplicate])
        #expect(issues[first.id]?.name != nil && issues[first.id]?.url != nil)
        #expect(issues[duplicate.id]?.name != nil && issues[duplicate.id]?.url != nil)
        #expect(!BookmarkEnvironment.valid([.init(name: "  ", url: "https://example.test")]))
        #expect(!BookmarkEnvironment.valid([.init(name: String(repeating: "x", count: 81), url: "https://example.test")]))
        #expect(BookmarkEnvironment.valid([]))
        #expect(!BookmarkEnvironment.valid([first, first]))
        let entries = (0...20).map { BookmarkEnvironment(name: "E\($0)", url: "https://e\($0).test") }
        #expect(!BookmarkEnvironment.valid(entries))
        #expect(BookmarkEnvironment.valid(Array(entries.prefix(20))))
    }

    @Test(arguments: ["https://shop.test", "https://shop.test/", "https://SHOP.test:443/app",
                      "https://shop.test/app/other", "https://shop.test/app?x=2#other"])
    func routesKeepTheirHostLabel(_ address: String) {
        for saved in ["https://shop.test", "https://SHOP.test:443/app?x=1#start"] {
            let item = BookmarkEnvironment(name: "Recette", url: saved)
            #expect(BookmarkEnvironment.current(in: [item], at: URL(string: address)) == item)
        }
    }

    @Test(arguments: ["http://shop.test/app", "https://shop.test:444/app", "https://other.test/app",
                      "https://prep.shop.test/app", "https://shop.test.evil.test/app",
                      "https://test/app", "file://shop.test/app", "about:blank"])
    func otherHostsAndPortsHaveNoLabel(_ address: String) {
        let item = BookmarkEnvironment(name: "Recette", url: "https://shop.test/app")
        #expect(BookmarkEnvironment.current(in: [item], at: URL(string: address)) == nil)
    }

    @Test func portsIdentifyDestinationsWithoutRequiringAScheme() {
        let local = BookmarkEnvironment(name: "Local", url: "http://localhost:8000/app")
        let other = BookmarkEnvironment(name: "Other", url: "http://localhost:8001/app")
        let root = BookmarkEnvironment(name: "Root", url: "http://LOCALHOST:80/app")
        let entries = [local, other, root]
        #expect(BookmarkEnvironment.current(in: entries, at: URL(string: "http://localhost:8000/next")) == local)
        #expect(BookmarkEnvironment.current(in: entries, at: URL(string: "https://localhost:8001/next")) == other)
        #expect(BookmarkEnvironment.current(in: entries, at: URL(string: "http://localhost/next")) == root)
        #expect(BookmarkEnvironment.current(in: entries, at: URL(string: "http://localhost:8002/next")) == nil)
        #expect(BookmarkEnvironment.current(in: entries, at: nil) == nil)
        #expect(BookmarkEnvironment.current(in: [], at: URL(string: local.url)) == nil)
    }

    @Test func sharedHostsNeedOneExactURLRegardlessOfOrder() {
        let first = BookmarkEnvironment(name: "First", url: "https://SHOP.test:443/app?x=1#start")
        let query = BookmarkEnvironment(name: "Query", url: "https://shop.test/app?x=2#start")
        let fragment = BookmarkEnvironment(name: "Fragment", url: "https://shop.test/app?x=1#other")
        let root = BookmarkEnvironment(name: "Root", url: "https://shop.test")
        for entries in [[first, query, fragment, root], [root, fragment, query, first]] {
            for item in entries {
                #expect(BookmarkEnvironment.current(in: entries, at: URL(string: item.url)) == item)
            }
            #expect(BookmarkEnvironment.current(in: entries, at: URL(string: "https://shop.test/")) == root)
            #expect(BookmarkEnvironment.current(in: entries, at: URL(string: "https://shop.test/app?x=1#start")) == first)
            #expect(BookmarkEnvironment.current(in: entries, at: URL(string: "https://shop.test/elsewhere")) == nil)
        }
        #expect(BookmarkEnvironment.current(in: [first, first], at: URL(string: first.url)) == nil)
    }

    private static let console = "https://console.example.com/console/"
    private let prod = BookmarkEnvironment(name: "Prod", url: console + "cluster-prod/home", depth: 2)
    private let dev = BookmarkEnvironment(name: "Dev", url: console + "cluster-dev/home", depth: 2)
    private let staging = BookmarkEnvironment(name: "Staging", url: console + "cluster-staging/home?tab=1#top", depth: 2)

    @Test func pathClaimsFollowSubpagesOnASharedDomain() {
        for entries in [[prod, dev, staging], [staging, dev, prod]] {
            #expect(BookmarkEnvironment.valid(entries))
            for (item, route) in [(prod, "cluster-prod/home"), (prod, "cluster-prod/topics/a?x=1#b"),
                                  (prod, "cluster-prod"), (prod, "cluster-prod/"), (dev, "cluster-dev/topics"),
                                  (staging, "cluster-staging/home"), (staging, "cluster-staging/home?tab=2")] {
                #expect(BookmarkEnvironment.current(in: entries, at: URL(string: Self.console + route)) == item)
            }
            for route in ["https://console.example.com/", Self.console, Self.console + "cluster-production/home",
                          Self.console + "Cluster-Prod/home", Self.console + "cluster-prod%2Fhome",
                          "https://console.example.com/other/cluster-prod/home",
                          "https://other.example.com/console/cluster-prod/home",
                          "https://console.example.com:8443/console/cluster-prod/home",
                          "http://console.example.com/console/cluster-prod/home"] {
                #expect(BookmarkEnvironment.current(in: entries, at: URL(string: route)) == nil)
            }
        }
        // Encoded characters compare by their meaning, whole segments at a time.
        let encoded = BookmarkEnvironment(name: "Space", url: Self.console + "my%20cluster/home", depth: 2)
        #expect(BookmarkEnvironment.current(in: [encoded, dev], at: URL(string: Self.console + "my%20cluster/x")) == encoded)
        #expect(BookmarkEnvironment.current(in: [encoded, dev], at: URL(string: Self.console + "my%20clusters/x")) == nil)
        // A repeated slash is a segment of its own, not a spelling of the single one.
        let doubled = BookmarkEnvironment(name: "Doubled", url: Self.console + "/cluster-prod/home", depth: 3)
        #expect(BookmarkEnvironment.valid([doubled, prod]))
        #expect(BookmarkEnvironment.current(in: [doubled, prod], at: URL(string: Self.console + "/cluster-prod/x")) == doubled)
        #expect(BookmarkEnvironment.current(in: [doubled, dev], at: URL(string: Self.console + "cluster-prod/x")) == nil)
        #expect(URL(string: "https://a.test/").map(BookmarkEnvironment.segments) == [])
        #expect(URL(string: "https://a.test/a//b/").map(BookmarkEnvironment.segments) == ["a", "", "b"])
    }

    @Test func nestedClaimsPreferTheLongestAndTheSavedAddressComesFirst() {
        let parent = BookmarkEnvironment(name: "Console", url: Self.console + "overview", depth: 1)
        let domain = BookmarkEnvironment(name: "Root", url: "https://console.example.com/")
        for entries in [[parent, prod, domain], [domain, prod, parent]] {
            #expect(BookmarkEnvironment.valid(entries))
            #expect(BookmarkEnvironment.current(in: entries, at: URL(string: Self.console + "cluster-prod/x")) == prod)
            #expect(BookmarkEnvironment.current(in: entries, at: URL(string: Self.console + "cluster-dev/x")) == parent)
            #expect(BookmarkEnvironment.current(in: entries, at: URL(string: "https://console.example.com/login")) == domain)
        }
        // A saved address inside someone else's claim still shows its own name.
        let pinned = BookmarkEnvironment(name: "Pinned", url: Self.console + "cluster-prod/special")
        #expect(BookmarkEnvironment.current(in: [prod, pinned], at: URL(string: pinned.url)) == pinned)
        #expect(BookmarkEnvironment.current(in: [prod, pinned], at: URL(string: Self.console + "cluster-prod/other")) == prod)
        #expect(BookmarkEnvironment.current(in: [prod, pinned], at: URL(string: "https://console.example.com/elsewhere")) == pinned)
        // Two domain claims beside a path claim still need their exact address.
        let other = BookmarkEnvironment(name: "Other", url: "https://console.example.com/other")
        #expect(BookmarkEnvironment.current(in: [prod, pinned, other], at: URL(string: "https://console.example.com/elsewhere")) == nil)
    }

    @Test func identicalOrUnfitClaimsAreRejected() {
        let twin = BookmarkEnvironment(name: "Twin", url: Self.console + "cluster-prod/other", depth: 2)
        let issues = BookmarkEnvironment.problems([prod, twin])
        #expect(issues[prod.id]?.path != nil && issues[twin.id]?.path != nil)
        #expect(BookmarkEnvironment.current(in: [prod, twin], at: URL(string: Self.console + "cluster-prod/x")) == nil)
        // The same claim on another port or host belongs to another endpoint.
        let port = BookmarkEnvironment(name: "Port", url: "https://console.example.com:8443/console/cluster-prod/", depth: 2)
        #expect(BookmarkEnvironment.valid([prod, port]))
        for depth in [0, -1, 4] {
            let unfit = BookmarkEnvironment(name: "Unfit", url: prod.url, depth: depth)
            #expect(BookmarkEnvironment.problems([unfit])[unfit.id]?.path != nil)
        }
        let root = BookmarkEnvironment(name: "Root", url: "https://console.example.com", depth: 1)
        #expect(!BookmarkEnvironment.valid([root]))
    }

    @Test func claimsPersistAndOlderEntriesKeepTheirDomain() throws {
        let restored = try JSONDecoder().decode(BookmarkEnvironment.self, from: JSONEncoder().encode(prod))
        #expect(restored == prod && restored.depth == 2)
        let old = Data(#"{"id":"00000000-0000-0000-0000-000000000088","name":"dev","url":"https://dev.test/a/b"}"#.utf8)
        #expect(try JSONDecoder().decode(BookmarkEnvironment.self, from: old).depth == nil)
        let encoded = try JSONEncoder().encode(BookmarkEnvironment(name: "Dev", url: "https://dev.test"))
        #expect(!String(decoding: encoded, as: UTF8.self).contains("depth"))
    }

    @Test func proposedClaimsStopAtTheFirstDistinctSegment() {
        let entries = [prod, dev, staging].map { item -> BookmarkEnvironment in
            var item = item
            item.depth = nil
            return item
        }
        for item in entries { #expect(BookmarkEnvironment.proposedDepth(for: item, among: entries) == 2) }
        let alone = BookmarkEnvironment(name: "Alone", url: "https://alone.test/a/b")
        #expect(BookmarkEnvironment.proposedDepth(for: alone, among: [alone] + entries) == 1)
        let root = BookmarkEnvironment(name: "Root", url: "https://alone.test/")
        #expect(BookmarkEnvironment.proposedDepth(for: root, among: [root]) == nil)
        let deeper = BookmarkEnvironment(name: "Deeper", url: Self.console + "cluster-prod/home/more")
        #expect(BookmarkEnvironment.proposedDepth(for: deeper, among: [deeper, prod]) == 4)
    }
}
