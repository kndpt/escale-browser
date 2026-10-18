// Copy Link with Highlight's rule: how the page's terms are encoded and joined
// to the address. Reading the selection is the page script's, left to the app.
import Foundation
import Testing
@testable import Escale

@Suite struct TextFragmentTests {
    private func fragment(_ start: String, end: String? = nil, prefix: String? = nil, suffix: String? = nil) throws -> TextFragment {
        try #require(TextFragment(start: start, end: end, prefix: prefix, suffix: suffix))
    }

    @Test(arguments: [
        ("plain", "plain"),
        ("two words", "two%20words"),
        // The directive's own syntax is always escaped.
        ("well-known, a & b", "well%2Dknown%2C%20a%20%26%20b"),
        ("100% #1: a=b?", "100%25%20%231%3A%20a%3Db%3F"),
        ("kept _.!~*'()", "kept%20_.!~*'()"),
        ("café", "caf%C3%A9"),
        ("日本", "%E6%97%A5%E6%9C%AC"),
    ])
    func termsAreEncodedAsTheSpecAsks(term: String, encoded: String) {
        #expect(TextFragment.encode(term) == encoded)
    }

    @Test func aUniquePassageIsItsOwnTerm() throws {
        #expect(try fragment("quick brown fox").directive == "text=quick%20brown%20fox")
    }

    @Test func contextAndRangeTakeTheirPlaces() throws {
        #expect(try fragment("restart", prefix: "Beta said:", suffix: ", quickly.").directive
                == "text=Beta%20said%3A-,restart,-%2C%20quickly.")
        #expect(try fragment("Alpha said", end: "quickly").directive == "text=Alpha%20said,quickly")
        #expect(try fragment("a", end: "b", prefix: "p", suffix: "s").directive == "text=p-,a,b,-s")
    }

    @Test func whiteSpaceIsOneSpaceAndAnEmptyTermIsNone() throws {
        let made = try fragment("  two \n\t words ", end: " ", prefix: "", suffix: "\n")
        #expect(made.start == "two words" && made.end == nil && made.prefix == nil && made.suffix == nil)
        #expect(TextFragment(start: " \n ") == nil)
    }

    @Test(arguments: [
        ("https://example.com/doc", "https://example.com/doc#:~:text=x"),
        ("https://example.com/doc?q=1", "https://example.com/doc?q=1#:~:text=x"),
        // A page's own fragment stays: it may be how the page routes.
        ("https://example.com/#/notes/2", "https://example.com/#/notes/2:~:text=x"),
        ("https://example.com/doc#part", "https://example.com/doc#part:~:text=x"),
        // An earlier directive is replaced, not stacked.
        ("https://example.com/doc#part:~:text=old", "https://example.com/doc#part:~:text=x"),
        ("https://example.com/doc#:~:text=old", "https://example.com/doc#:~:text=x"),
    ])
    func theLinkIsTheAddressWithTheDirective(address: String, link: String) throws {
        let url = try #require(URL(string: address))
        #expect(try fragment("x").link(to: url) == link)
    }

    @Test func theLinkIsAValidAddress() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let link = try fragment("a-b, c & d #e", prefix: "été", suffix: "→").link(to: url)
        #expect(URL(string: link) != nil)
    }

    @Test func thePageAnswerIsCheckedFirst() throws {
        let answer: [String: Any] = ["start": "restart", "end": "", "prefix": "Beta said:", "suffix": ","]
        #expect(TextFragment(answer) == TextFragment(start: "restart", prefix: "Beta said:", suffix: ","))
        #expect(TextFragment(["start": "only"] as [String: Any]) == TextFragment(start: "only"))
        #expect(TextFragment(nil as Any?) == nil)
        #expect(TextFragment(NSNull()) == nil)
        #expect(TextFragment([:] as [String: Any]) == nil)
        #expect(TextFragment(["start": ""] as [String: Any]) == nil)
        #expect(TextFragment(["start": 3] as [String: Any]) == nil)
        #expect(TextFragment(["start": "a", "prefix": 1] as [String: Any]) == nil)
    }
}
