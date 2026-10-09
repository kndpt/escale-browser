import Foundation
import Testing
@testable import Escale

// Search keywords (Keyword.swift): `npm react` searches the site
// written for `npm`, and anything else keeps the meaning it had. Synthetic
// templates on example.test; nothing is fetched.
@MainActor
@Suite struct KeywordTests {
    private let written = """
        npm https://npm.example.test/search?q=%s
        MDN https://www.mdn.example.test/find?term=%s&x=1
        """

    @Test(arguments: [
        ("npm react", "npm", "react", "https://npm.example.test/search?q=react"),
        ("  NPM   react hooks ", "npm", "react hooks", "https://npm.example.test/search?q=react%20hooks"),
        ("mdn a&b=c/é", "mdn", "a&b=c/é", "https://www.mdn.example.test/find?term=a%26b%3Dc%2F%C3%A9&x=1"),
    ])
    func aKnownKeywordSearchesItsSite(typed: String, word: String, words: String, url: String) {
        let found = Keyword.search(typed, in: written)
        #expect(found?.keyword.word == word)
        #expect(found?.words == words)
        #expect(found?.url.absoluteString == url)
    }

    @Test(arguments: ["yarn react", "npm", "npm   ", "npmreact", "react npm", ""])
    func anythingElseIsNoKeywordSearch(typed: String) {
        #expect(Keyword.search(typed, in: written) == nil)
    }

    @Test func theListStartsEmpty() {
        #expect(Keyword.list("").isEmpty)
        #expect(Keyword.search("npm react", in: "") == nil)
    }

    @Test func anInvalidTemplateIsRefused() {
        let text = """
            plain https://plain.example.test/search
            ftp ftp://ftp.example.test/?q=%s
            host https://%s.example.test/
            words three parts https://x.example.test/?q=%s
            ok https://ok.example.test/?q=%s
            ok https://second.example.test/?q=%s

            """
        #expect(Keyword.list(text).map(\.word) == ["ok"])
        #expect(Keyword.list(text).first?.template == "https://ok.example.test/?q=%s")
        #expect(Keyword.refused(text) == 5)
        #expect(Keyword.refused(written) == 0)
        #expect(Keyword.search("plain words", in: text) == nil)
        // A lookup reads only the lines of its word, and agrees with the list.
        #expect(Keyword.search("ok words", in: text)?.url.absoluteString == "https://ok.example.test/?q=words")
        #expect(Keyword.search("OK words", in: "ok nothing\nok https://ok.example.test/?q=%s")?.keyword.template
                == "https://ok.example.test/?q=%s")
    }

    @Test func theRowNamesTheSite() {
        #expect(Keyword.list(written).map(\.site) == ["npm.example.test", "mdn.example.test"])
    }

    @Test func theFieldOffersTheSiteFirstInPlaceOfTheEngine() {
        let field = Field(history: History(file: FileManager.default.temporaryDirectory
                              .appendingPathComponent("escale-keyword-\(UUID().uuidString).json")),
                          search: { URL(string: "https://engine.example.test/?q=\($0.count)") },
                          engine: { "Engine" },
                          keyword: { Keyword.search($0, in: written) },
                          others: { [] })

        field.typed = "npm react"
        #expect(field.offers.first?.kind == .keyword)
        #expect(field.offers.first?.title == "Search npm.example.test for react")
        #expect(field.offers.first?.url.absoluteString == "https://npm.example.test/search?q=react")
        #expect(!field.offers.contains { $0.kind == .search })

        field.typed = "yarn react"
        #expect(field.offers.last?.kind == .search)
        #expect(!field.offers.contains { $0.kind == .keyword })

        field.typed = "npm.example.test"
        #expect(!field.offers.contains { $0.kind == .keyword || $0.kind == .search })
    }
}
