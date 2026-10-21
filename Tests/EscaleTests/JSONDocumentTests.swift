// Lossless parsing and bounds protect response fidelity and the UI from
// attacker-controlled JSON; the copies (JavaScript paths, minified and
// indented layouts) must not change what was received. These cases exercise
// the production index.
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
    @Test func scriptPaths() throws {
        let source = #"{"data":[{"id":1}],"odd key":{"a\"b\\c\n":0},"café":{"日本":true,"🌍":1},"$x_1":[[2]],"1a":0,"":0,"class":0,"a-b":0,"\u2028":0}"#
        let document = try JSONDocument(source)
        func script(_ label: String) throws -> String { document.script(try #require(document.nodes.first { $0.label == label }).id) }
        #expect(document.script(0).isEmpty)
        #expect(try script("id") == ".data[0].id")
        #expect(try script("a\"b\\c\n") == #"["odd key"]["a\"b\\c\n"]"#)
        #expect(try script("日本") == ".café.日本")
        #expect(try script("🌍") == #".café["🌍"]"#)
        #expect(document.script(try #require(document.nodes.first { document.value($0.id) == "2" }).id) == ".$x_1[0][0]")
        #expect(try script("1a") == #"["1a"]"#)
        #expect(try script("") == #"[""]"#)
        #expect(try script("class") == ".class")
        #expect(try script("a-b") == #"["a-b"]"#)
        #expect(try script("\u{2028}") == #"["\u2028"]"#)
    }
    @Test func losslessLayout() throws {
        let source = #"{ "big" : 9007199254740993123456789, "exp":[1.2300e+99, -0E-0], "dup":1,"dup":2, "s":"a , : { [ \" \\ é", "z":{ }, "a":[ ] , "n":[[1,2],{"k":null}] }"#
        let document = try JSONDocument(source)
        let minified = document.formatted(0, indent: false)
        #expect(minified == #"{"big":9007199254740993123456789,"exp":[1.2300e+99,-0E-0],"dup":1,"dup":2,"s":"a , : { [ \" \\ é","z":{},"a":[],"n":[[1,2],{"k":null}]}"#)
        let indented = document.formatted(0, indent: true)
        #expect(indented == """
        {
          "big": 9007199254740993123456789,
          "exp": [
            1.2300e+99,
            -0E-0
          ],
          "dup": 1,
          "dup": 2,
          "s": "a , : { [ \\" \\\\ é",
          "z": {},
          "a": [],
          "n": [
            [
              1,
              2
            ],
            {
              "k": null
            }
          ]
        }
        """)
        // Laid out again, each keeps every node and value in the same order.
        for text in [minified, indented] {
            let again = try JSONDocument(text)
            #expect(again.nodes.map(\.label) == document.nodes.map(\.label))
            func scalars(_ json: JSONDocument) -> [String] { json.nodes.filter { $0.kind != "object" && $0.kind != "array" }.map { json.value($0.id) } }
            #expect(scalars(again) == scalars(document))
        }
        let inner = try #require(document.nodes.first { $0.label == "n" }).id
        #expect(document.formatted(inner, indent: false) == #"[[1,2],{"k":null}]"#)
        #expect(try JSONDocument(" [ ] ").formatted(0, indent: true) == "[]")
    }
    @Test func subtrees() throws {
        let document = try JSONDocument(#"{"a":{"b":[1,{"c":2}]},"d":3}"#)
        #expect(document.subtree(0) == 0..<document.nodes.count)
        let a = try #require(document.nodes.first { $0.label == "a" }).id
        #expect(document.subtree(a).map { document.nodes[$0].label } == ["a", "b", "0", "1", "c"])
        let d = try #require(document.nodes.first { $0.label == "d" }).id
        #expect(document.subtree(d) == d..<d + 1)
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
