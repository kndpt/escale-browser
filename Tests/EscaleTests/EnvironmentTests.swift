// Addresses are fixtures, not loaded pages. These cases bound editable name
// suggestions when creating an environment; they no longer produce badges.
import Foundation
import Testing
@testable import Escale

@Suite struct EnvironmentTests {
    @Test(arguments: [
        ("https://dev.example.test", "DEV"),
        ("https://sit.example.test", "SIT"),
        ("https://uat.example.test", "UAT"),
        ("https://uat1.example.test", "UAT 1"),
        ("https://uat2.example.test", "UAT 2"),
        ("https://staging.example.test", "STAGING"),
        ("https://example.test/preprod/dashboard", "PREPROD"),
        ("https://prod.example.test", "PROD"),
        ("http://localhost:8080", "LOCAL"),
        ("http://127.0.0.1:3000", "LOCAL"),
        ("https://example.test/app_dev2", "DEV 2"),
    ])
    func recognises(address: String, label: String) {
        guard let url = URL(string: address) else {
            Issue.record("Invalid test URL: \(address)")
            return
        }
        #expect(Environment.from(url)?.label == label)
    }

    @Test(arguments: [
        "https://developer.example.test",
        "https://visit.example.test",
        "https://product.example.test",
        "https://example.test/development",
        "https://example.test/?return=https://prod.example.test",
        "https://example.test/#uat1",
        "https://uat0.example.test",
        "https://uat123.example.test",
        "https://uat1.example.test/dev",
        "https://uat1.example.test/uat2",
        "https://example.test",
        "file:///tmp/prod/index.html",
        "https://prod.example.test/" + String(repeating: "a", count: 4096),
    ])
    func withholds(address: String) {
        guard let url = URL(string: address) else {
            Issue.record("Invalid test URL: \(address)")
            return
        }
        #expect(Environment.from(url) == nil)
    }
}
