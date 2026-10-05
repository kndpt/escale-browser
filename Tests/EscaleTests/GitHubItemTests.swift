// Identity and observation rules use synthetic paths only. No GitHub requests,
// Browser or WebKit page are needed to prove the common UI/data value contract.

import Foundation
import Testing
@testable import Escale

@Suite struct GitHubItemTests {
    private let space = UUID()
    private func id(_ text: String, space: UUID? = nil) throws -> GitHubItem.ID? {
        GitHubItem.ID(url: try #require(URL(string: text)), space: space ?? self.space)
    }

    @Test func subpagesShareIdentityButDestinationsRemainExact() throws {
        let canonical = try #require(try id("https://github.com/Kndpt/Escale/pull/271"))
        for tail in ["", "/", "/files", "/commits", "/checks", "/files/abcdef1234567", "#issuecomment-1", "/files?diff=split#diff-1"] {
            let url = try #require(URL(string: "https://GITHUB.COM/kndpt/escale/pull/271" + tail))
            let destination = try #require(GitHubItem.Destination(url: url, title: "A PR", source: .tab(UUID()), visitedAt: Date()))
            let item = try #require(GitHubItem(space: space, destination: destination))
            #expect(item.id == canonical)
            #expect(item.destination.url == url)
        }
        #expect(try id("https://github.com/kndpt/escale/issues/271") != canonical)
        #expect(try id("https://github.com/kndpt/escale/pull/271", space: UUID()) != canonical)
        #expect(try id("https://github.com:443/kndpt/escale/pull/00271") == canonical)
    }

    @Test func spoofingAndUnqualifiedPathsAreRejected() throws {
        for text in [
            "http://github.com/a/b/pull/1", "https://github.com.evil.test/a/b/pull/1",
            "https://evilgithub.com/a/b/pull/1", "https://github.com./a/b/pull/1",
            "https://github.enterprise.test/a/b/pull/1", "https://github.com@evil.test/a/b/pull/1",
            "https://user@github.com/a/b/pull/1", "https://github.com:444/a/b/pull/1",
            "https://github.com/a/b/pull/0", "https://github.com/a/b/pull/-1",
            "https://github.com/a/b/pull/9999999999999999999999999",
            "https://github.com/a/b/pull/1/unknown", "https://github.com/a/b/issues/1/files",
            "https://github.com/a/b/pull/1//files", "https://github.com/a/b/pull/1/files/xyz",
            "https://github.com/a/b/pull/1/checks/123", "https://github.com/a/b/pulls/1",
            "https://github.com/a/b/pull/%31", "https://github.com/a%2Fb/c/pull/1",
            "https://github.com/-a/b/pull/1", "https://github.com/a--b/c/pull/1"
        ] { #expect(try id(text) == nil, "Accepted \(text)") }
    }

    @Test func successfulObservationIsDistinctFromVisitAndFailure() throws {
        let item = try #require(try id("https://github.com/a/b/issues/1"))
        let now = Date(timeIntervalSince1970: 1_000)
        let observation = GitHubObservation(state: .open, source: .page, observedAt: now)
        #expect(observation.valid(for: item))
        #expect(observation.isFresh(at: now))
        #expect(!observation.isFresh(at: now.addingTimeInterval(300)))
        #expect(!observation.isFresh(at: now.addingTimeInterval(-1)))
        #expect(GitHubReading(observation: observation, failure: .offline).current(at: now) == nil)
        #expect(!GitHubObservation(state: .merged, source: .page, observedAt: now).valid(for: item))
        #expect(!GitHubObservation(state: .draft, source: .page, observedAt: now).valid(for: item))
        #expect(!GitHubObservation(state: .open, source: .page, observedAt: Date(timeIntervalSince1970: .infinity)).valid(for: item))
    }

    @Test func decodedIdentitiesMustStillPassSemanticValidation() throws {
        let item = try #require(try id("https://github.com/a/b/pull/1"))
        let data = try JSONEncoder().encode(item)
        let text = try #require(String(data: data, encoding: .utf8))
        let wrong = Data(text.replacingOccurrences(of: "github.com", with: "evil.test").utf8)
        #expect(!(try JSONDecoder().decode(GitHubItem.ID.self, from: wrong)).valid)
    }
    @Test func titleBoundCountsBytesEvenForOneHugeGrapheme() throws {
        let url = try #require(URL(string: "https://github.com/a/b/pull/1"))
        let title = "a" + String(repeating: "\u{0301}", count: 10_000)
        let destination = try #require(GitHubItem.Destination(url: url, title: title, source: .history, visitedAt: Date()))
        #expect(destination.title.utf8.count <= GitHubItem.longestTitle)
        #expect(Array(title.utf8.prefix(destination.title.utf8.count)) == Array(destination.title.utf8))
        let emoji = try #require(GitHubItem.Destination(url: url, title: String(repeating: "🎈", count: 1_000), source: .history, visitedAt: Date()))
        #expect(emoji.title.utf8.count == GitHubItem.longestTitle)
    }

}
