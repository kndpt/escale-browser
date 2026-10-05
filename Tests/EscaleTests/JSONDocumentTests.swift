// Lossless parsing and bounds protect response fidelity and the UI from
// attacker-controlled JSON. These cases exercise the production index.
import Foundation
import Testing
@testable import Escale

@Suite struct JSONDocumentTests {
    @Test func fidelityAndPointers() throws {
        let source = #"{"a/b~":{"": [9007199254740993123456789,1.2300e+99,"é🌍\u0041",null,true]},"duplicate":1,"duplicate":2}"#
        let document = try JSONDocument(source)
        #expect(document.value(0) == source)
        #expect(document.value(3) == "9007199254740993123456789")
        #expect(document.path(3) == "/a~1b~0//0")
        #expect(document.nodes.filter { $0.label == "duplicate" }.count == 2)
        #expect(document.path(0).isEmpty)
    }
    @Test(arguments: ["0", "-0", "1.23e-10", "true", "false", "null", #""hello\n世界""#, "[]", "{}"])
    func scalars(_ source: String) throws { #expect(try JSONDocument(source).value(0) == source) }
    @Test(arguments: ["", "01", "NaN", "1.", "1e", "--1", "[1,]", "{\"a\":}", "{\"a\":1,}", "true false", "\"bad\nstring\"", #""\x""#])
    func invalid(_ source: String) { #expect(throws: JSONDocument.Invalid.self) { try JSONDocument(source) } }
    @Test func bounds() {
        #expect(throws: JSONDocument.Invalid.self) { try JSONDocument(String(repeating: "[", count: 66) + "0" + String(repeating: "]", count: 66)) }
        #expect(throws: JSONDocument.Invalid.self) { try JSONDocument("[" + Array(repeating: "0", count: 20_001).joined(separator: ",") + "]") }
        #expect(throws: JSONDocument.Invalid.self) { try JSONDocument("\"" + String(repeating: "x", count: JSONDocument.byteLimit) + "\"") }
    }
    @MainActor @Test func cookieScopes() throws {
        let parent = try #require(HTTPCookie(properties: [.domain: ".example.com", .path: "/other", .name: "id", .value: "one"]))
        let host = try #require(HTTPCookie(properties: [.domain: "app.example.com", .path: "/", .name: "id", .value: "two"]))
        #expect(SiteStorage.matches(parent, host: "app.example.com"))
        #expect(SiteStorage.matches(parent, host: "example.com"))
        #expect(!SiteStorage.matches(parent, host: "notexample.com"))
        #expect(!SiteStorage.matches(host, host: "other.app.example.com"))
    }
}
