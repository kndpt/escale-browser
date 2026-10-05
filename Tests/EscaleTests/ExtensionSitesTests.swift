// An extension update that reaches more sites than the installed version is
// asked about, as one that asks for more permissions is. Patterns only: no
// extension is loaded.
import Foundation
import Testing
import WebKit
@testable import Escale

@MainActor
@Suite struct ExtensionSitesTests {
    @available(macOS 15.4, *)
    private func patterns(_ strings: [String]) throws -> Set<WKWebExtension.MatchPattern> {
        Set(try strings.map { try WKWebExtension.MatchPattern(string: $0) })
    }

    @Test func reachingEverySiteIsWider() throws {
        guard #available(macOS 15.4, *) else { return }
        #expect(Extensions.widens(try patterns(["https://example.test/*"]), to: try patterns(["<all_urls>"])))
        #expect(Extensions.widens(try patterns(["https://example.test/*"]), to: try patterns(["https://example.test/*", "https://other.test/*"])))
        #expect(Extensions.widens([], to: try patterns(["https://example.test/*"])))
    }

    @Test func theSameOrFewerSitesAreNot() throws {
        guard #available(macOS 15.4, *) else { return }
        #expect(!Extensions.widens(try patterns(["https://example.test/*"]), to: try patterns(["https://example.test/*"])))
        #expect(!Extensions.widens(try patterns(["<all_urls>"]), to: try patterns(["https://example.test/*"])))
        #expect(!Extensions.widens(try patterns(["*://*.example.test/*"]), to: try patterns(["https://api.example.test/*"])))
        #expect(!Extensions.widens(try patterns(["https://example.test/*"]), to: []))
    }
}
