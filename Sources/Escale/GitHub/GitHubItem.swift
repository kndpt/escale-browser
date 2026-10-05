// A GitHub object keeps the same identity across its visited subpages. Local
// destinations remain separate values: neither a status reply nor a cache
// eviction should change which tab Return resumes. Only github.com is admitted;
// extending this boundary requires qualifying another host and its API origin.

import Foundation

struct GitHubItem: Identifiable, Equatable {
    struct ID: Hashable, Codable {
        let space: UUID
        let host: String
        let owner: String
        let repository: String
        let kind: Kind
        let number: Int

        enum Kind: String, Codable { case pull, issue }

        init?(url: URL, space: UUID) {
            guard url.absoluteString.utf8.count <= GitHubItem.longestURL,
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.scheme?.lowercased() == "https", parts.host?.lowercased() == "github.com",
                  parts.user == nil, parts.password == nil,
                  parts.port == nil || parts.port == 443,
                  !parts.percentEncodedPath.contains("%") else { return nil }
            var path = parts.path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.first == "" else { return nil }
            path.removeFirst()
            if path.last == "" { path.removeLast() }
            guard path.count >= 4,
                  Self.validOwner(String(path[0])), Self.validRepository(String(path[1])),
                  let kind = path[2] == "pull" ? Kind.pull : (path[2] == "issues" ? Kind.issue : nil),
                  !path[3].isEmpty, path[3].utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(path[3]), number > 0 else { return nil }
            let tail = path.dropFirst(4)
            if !tail.isEmpty {
                guard kind == .pull, tail.count <= 2,
                      ["files", "commits", "checks"].contains(String(tail.first ?? "")) else { return nil }
                if tail.count == 2 {
                    guard tail.first != "checks", let sha = tail.last,
                          (7...40).contains(sha.count),
                          sha.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
                    else { return nil }
                }
            }
            self.space = space
            host = "github.com"
            owner = path[0].lowercased()
            repository = path[1].lowercased()
            self.kind = kind
            self.number = number
        }

        /// Also checks decoded identities, which do not pass through the URL parser.
        var valid: Bool {
            host == "github.com" && owner == owner.lowercased() && repository == repository.lowercased()
                && Self.validOwner(owner) && Self.validRepository(repository) && number > 0
        }

        private static func validOwner(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 39 && value.first != "-" && value.last != "-"
                && !value.contains("--") && value.utf8.allSatisfy { asciiLetterOrDigit($0) || $0 == 45 }
        }

        private static func validRepository(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 100 && value != "." && value != ".."
                && value.utf8.allSatisfy { asciiLetterOrDigit($0) || [45, 46, 95].contains($0) }
        }

        private static func asciiLetterOrDigit(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
    }

    enum Source: Equatable { case history, tab(UUID) }

    /// A value captured from history or tab metadata, never from a newly built page.
    struct Destination: Equatable {
        let url: URL
        let title: String
        let source: Source
        let visitedAt: Date

        init?(url: URL, title: String, source: Source, visitedAt: Date) {
            guard url.absoluteString.utf8.count <= GitHubItem.longestURL,
                  visitedAt.timeIntervalSince1970.isFinite else { return nil }
            self.url = url
            self.title = GitHubItem.boundedTitle(title)
            self.source = source
            self.visitedAt = visitedAt
        }
    }

    /// Count bytes rather than graphemes: one character can contain an arbitrary
    /// number of combining marks. Drop only a partial final UTF-8 scalar.
    private static func boundedTitle(_ title: String) -> String {
        var bytes = Array(title.utf8.prefix(longestTitle))
        while !bytes.isEmpty {
            if let text = String(bytes: bytes, encoding: .utf8) { return text }
            bytes.removeLast()
        }
        return ""
    }

    static let longestURL = 2_048
    static let longestTitle = 1_024
    let id: ID
    let destination: Destination

    init?(space: UUID, destination: Destination) {
        guard let id = ID(url: destination.url, space: space) else { return nil }
        self.id = id
        self.destination = destination
    }
}
