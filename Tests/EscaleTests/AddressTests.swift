import Foundation
import Testing
@testable import Escale

// Addresses are a local rule: these synthetic strings must never open a page,
// read a profile or turn a rejected input into a search request.
@Suite struct AddressTests {
    @Test(arguments: [
        ("localhost:8080/path", "http://localhost:8080/path"),
        ("app.localhost", "http://app.localhost"),
        ("127.0.0.1:3000", "http://127.0.0.1:3000"),
        ("192.168.1.8", "http://192.168.1.8"),
        ("10.0.0.2", "http://10.0.0.2"),
        ("example.test/docs", "https://example.test/docs"),
        (" HTTPS://example.test/path ", "HTTPS://example.test/path"),
        ("file:///tmp/escale-fixture", "file:///tmp/escale-fixture"),
        ("about:blank", "about:blank"),
        ("data:text/plain,hello", "data:text/plain,hello"),
    ])
    func accepts(typed: String, expected: String) {
        #expect(Address.url(from: typed)?.absoluteString == expected)
    }

    @Test(arguments: ["", "  \n ", "a search", "todo", "someone@example.test",
                      "ftp://example.test", "mailto:me@example.test", "custom://host",
                      "a..test", "-bad.test", "version.123"])
    func refuses(typed: String) {
        #expect(Address.url(from: typed) == nil)
    }

    @Test(arguments: [
        ("https://www.example.test/", "example.test"),
        ("https://www.example.test/docs/start?x=1#part", "example.test/docs/start"),
        ("about:blank", "about:blank"),
    ])
    func presents(url: String, expected: String) {
        guard let url = URL(string: url) else {
            Issue.record("Invalid test URL: \(url)")
            return
        }
        #expect(Address.pretty(url) == expected)
    }
}
