import Foundation
import Testing
@testable import Escale

// The rule Bearings uses to read a query by its words (see Terms.swift):
// separators, case, spaces, partial last words and the order of closeness.
// Pure strings; nothing is opened or searched.

@Suite struct TermsTests {
    @Test(arguments: [
        "iso--checkout--orchestrator-handlers",
        "orchestrator_handlers",
        "github.test/acme/orchestrator/handlers/readme",
        "Orchestrator · Handlers",
    ])
    func wordsFindNamesWhateverTheirSeparators(_ name: String) {
        #expect(Terms("orchestrator handlers").match(name) != nil)
        #expect(Terms("  ORCHESTRATOR    Handlers ").match(name) != nil)
        #expect(Terms("orchestrator hand").match(name) != nil)
        #expect(Terms("orchestrator-handlers").match(name) != nil)
    }

    @Test func everyWordIsRequiredAndStartsAWord() {
        let name = "iso--checkout--orchestrator-handlers"
        #expect(Terms("orchestrator gateway").match(name) == nil)
        #expect(Terms("chestrator handlers").match(name) == nil)
        #expect(Terms("o h").match(name) == .words)
        #expect(Terms("a b").match(name) == nil)
        #expect(Terms("handlers checkout").match(name) == .words)
    }

    @Test func closenessKeepsWhatAlreadyMatchedFirst() {
        let terms = Terms("orchestrator handlers")
        #expect(terms.match("Orchestrator handlers guide") == .typed)
        #expect(terms.match("iso--checkout--orchestrator-handlers") == .joined)
        #expect(terms.match("Handlers of the orchestrator") == .words)
        #expect(Terms.Match.typed < .joined && Terms.Match.joined < .words)
        #expect(terms.match(["Handlers of the orchestrator", "orchestrator_handlers"]) == .joined)
        #expect(terms.match(["unrelated", "other"]) == nil)
    }

    @Test func aSingleWordStaysAContiguousMatch() {
        #expect(Terms("chestra").match("orchestrator") == .typed)
        #expect(Terms("hand").match("orchestrator-handlers") == .typed)
        #expect(Terms("gateway").match("orchestrator-handlers") == nil)
        #expect(Terms("").match("anything") == nil)
        #expect(Terms("   ").isEmpty)
        #expect(Terms(" -- ").match("anything -- here") == .typed)
        #expect(Terms(" -- ").match("anything") == nil)
    }
}

@Suite struct TermsUnicodeTests {
    /// macOS file names and some pages carry decomposed accents (NFD); a
    /// query typed composed still finds them by their words, and the reverse.
    @Test func decomposedAccentsMatchComposedWords() {
        let decomposed = "Cafe\u{301}-re\u{301}sume\u{301}"
        #expect(Terms("café résumé").match(decomposed) == .joined)
        #expect(Terms("résumé café").match(decomposed) == .words)
        #expect(Terms("re\u{301}sume\u{301} cafe\u{301}").match("Café-résumé") == .words)
        #expect(Terms("resume cafe").match(decomposed) == nil)
    }
}

@Suite struct TermsNamesTests {
    /// The reported case: the title holds one word, the address the others.
    @Test func wordsSpreadAcrossTheNamesOfAPlace() {
        let names = ["Swagger UI", "reception-orchestrator-handlers.priv.example.test/api"]
        #expect(Terms("orchestrator handlers swa").match(names) == .words)
        #expect(Terms("orchestrator handlers").match(names) == .joined)
        #expect(Terms("swagger reception").match(names) == .words)
        #expect(Terms("orchestrator handlers gateway").match(names) == nil)
        #expect(Terms("swagger ui").match(names) == .typed)
    }

    @Test func camelCaseStepsStartWords() {
        #expect(Terms("orchestrator handlers").match("OrchestratorHandlers.java") == .joined)
        #expect(Terms("handlers orch").match("github.test/OrchestratorHandlers") == .words)
        #expect(Terms("api client").match("v2ApiClient") == .joined)
        // Only a capital after a lowercase letter or a digit starts a word.
        #expect(Terms("server http").match("HTTPServer") == nil)
        #expect(Terms("chestrator handlers").match("OrchestratorHandlers") == nil)
    }
}
