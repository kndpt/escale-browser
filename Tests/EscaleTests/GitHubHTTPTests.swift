// URLProtocol feeds the production receiving delegate. Responses never leave
// this process; payload limits, headers, redirection and cancellation are tested
// at URLSession's boundary, beyond the higher-level exchange fixtures.

import Foundation
import Testing
@testable import Escale

private final class GitHubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.github.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path
        if path == "/held" { return }
        if path == "/redirect" {
            guard let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location":"https://evil.test/"]),
                  let destination = URL(string: "https://evil.test/") else { return }
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: response)
            return
        }
        let oversized = path == "/declared"
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: oversized ? ["Content-Length":String(GitHubHTTP.limit + 1)] : ["ETag":"fixture-etag"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path == "/stream" {
            for _ in 0..<17 { client?.urlProtocol(self, didLoad: Data(repeating: 32, count: 65_536)) }
        } else { client?.urlProtocol(self, didLoad: Data("{}".utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite struct GitHubHTTPTests {
    private func http() -> GitHubHTTP {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GitHubProtocol.self]
        return GitHubHTTP(configuration: config)
    }

    @Test func responseIsBoundedDuringDeclaredAndChunkedReception() async throws {
        for path in ["/declared", "/stream", "/redirect"] {
            do {
                _ = try await http().exchange(GitHubHTTP.request(path: path))
                Issue.record("Accepted an oversized or redirected response")
            } catch { #expect(error as? GitHubFailure == .invalidResponse) }
        }
        let reply = try await http().exchange(GitHubHTTP.request(path: "/user"))
        #expect(reply.data == Data("{}".utf8))
        #expect(reply.header("etag") == "fixture-etag")
    }

    @Test func cancellationBeforeAndDuringReceptionFinishes() async throws {
        let client = http()
        let task = Task { try await client.exchange(GitHubHTTP.request(path: "/held")) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled transport completed") }
        catch { #expect(error is CancellationError || error as? GitHubFailure == .cancelled) }
    }
    @Test func rawRequestsCannotBypassTheFixedOriginBoundary() async throws {
        let url = try #require(URL(string: "https://evil.test/"))
        do { _ = try await http().exchange(URLRequest(url: url)); Issue.record("Foreign origin accepted") }
        catch { #expect(error as? GitHubFailure == .invalidResponse) }
    }

}
