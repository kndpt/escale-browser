import Foundation
import Testing
@testable import Escale

// ⌘L's parameters (Query.swift, and their walk in Field.swift): read in
// order, written back unchanged unless changed, turned off without being lost,
// and given back to suggestions once the field is another page. Synthetic
// addresses only; nothing is loaded.
@MainActor
@Suite struct QueryTests {
    private let address = "https://app.example.test/search?q=escale%20browser&tag=a&tag=b&flag&empty=&utm_source=x&gclid=y#top"

    @Test func readsEveryParameterInOrderAndWritesTheAddressBackAsItWas() throws {
        let query = try #require(Query(address))
        #expect(query.parameters.map(\.key) == ["q", "tag", "tag", "flag", "empty", "utm_source", "gclid"])
        #expect(query.parameters[0].text == "escale browser")
        #expect(query.parameters[3].value == nil)
        #expect(query.parameters[4].value == "")
        #expect(query.parameters.filter(\.tracking).map(\.key) == ["utm_source", "gclid"])
        #expect(query.fragment == "#top")
        #expect(query.address == address)
    }

    @Test(arguments: ["https://app.example.test/", "https://app.example.test/?", "about:blank?x=1", "data:text/plain,a?b=1"])
    func unfoldsOnlyAnHTTPAddressWithParameters(_ text: String) {
        #expect(Query(text) == nil)
    }

    @Test func aParameterTurnedOffLeavesTheAddressAndComesBackInItsPlace() throws {
        var query = try #require(Query("https://a.test/?a=1&b=2&c=3"))
        query.toggle(1)
        #expect(query.address == "https://a.test/?a=1&c=3")
        let read = try #require(query.reading(query.address))
        #expect(read.parameters.map(\.on) == [true, false, true])
        var back = read
        back.toggle(1)
        #expect(back.address == "https://a.test/?a=1&b=2&c=3")
    }

    @Test func typingAValueRereadsItsRowAndAnotherPageIsNoLongerThisQuery() throws {
        let query = try #require(Query("https://a.test/p?a=1&b=2"))
        let typed = try #require(query.reading("https://a.test/p?a=1&b=two"))
        #expect(typed.parameters[1].text == "two")
        #expect(query.reading("https://other.test/p?a=1") == nil)
        #expect(query.reading("github.com") == nil)
    }

    @Test func aValueIsSelectedWhereTheFieldShowsIt() throws {
        let text = "https://a.test/?a=1&long=value"
        let query = try #require(Query(text))
        let range = try #require(query.parameters[1].range)
        #expect((text as NSString).substring(with: range) == "value")
    }

    @Test func valuesSayWhenTheyAreAnAddressOrAToken() throws {
        let query = try #require(Query("https://a.test/?next=https%3A%2F%2Fb.test%2F&t=eyJh.eyJi.c&n=3"))
        #expect(query.parameters.map(\.kind) == ["URL", "JWT", nil])
    }

    @Test func theFieldWalksParametersTogglesWithSpaceAndRemovesTracking() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("escale-query-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let field = Field(history: History(file: file), search: { _ in nil }, engine: { "" }, others: { [] })
        field.unfold("https://a.test/?a=1&utm_source=x&b=2")
        #expect(field.offers.isEmpty)
        #expect(field.shownParameters == [0, 2])

        field.walk(1)
        field.walk(1)
        #expect(field.parameter == 2)
        #expect(field.toggle())
        #expect(field.typed == "https://a.test/?a=1&utm_source=x")

        field.removeTracking()
        #expect(field.typed == "https://a.test/?a=1")
        #expect(field.query?.parameters.map(\.key) == ["a", "b"])

        field.typed = "github.com"
        #expect(field.query == nil)
        #expect(field.parameter == nil)
    }
}
