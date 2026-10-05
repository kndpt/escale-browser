import Foundation
import Testing
@testable import Escale

// A local sender has only four event types and bounded text. Invalid payloads
// are refused before they can reach macOS notifications.
@Suite struct DeveloperAlertsTests {
    @Test(arguments: ["agent", "build", "pr", "workflow"])
    func acceptsKnownKinds(kind: String) throws {
        let data = try #require("{\"kind\":\"\(kind)\",\"title\":\"Done\",\"body\":\"Ready\"}".data(using: .utf8))
        let event = try JSONDecoder().decode(DeveloperAlerts.Event.self, from: data)
        #expect(event.cleaned?.title == "Done")
    }

    @Test func refusesUnboundedOrBlankText() {
        let kind = DeveloperAlerts.Kind.agent
        #expect(DeveloperAlerts.Event(kind: kind, title: " \n ", body: "").cleaned?.title == nil)
        #expect(DeveloperAlerts.Event(kind: kind, title: String(repeating: "a", count: 101), body: "").cleaned?.title == nil)
        #expect(DeveloperAlerts.Event(kind: kind, title: "Done", body: String(repeating: "a", count: 501)).cleaned?.title == nil)
    }
}
