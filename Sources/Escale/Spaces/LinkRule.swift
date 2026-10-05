// Link rules match parsed HTTP addresses, never arbitrary substrings. Their
// order is their priority: the first match wins. At most 128 explicit rules,
// with 2,048 bytes per field, bound work at each intentional opening without
// a cache, timer, page script or a request to the destination site.
import Foundation

struct LinkRule: Codable, Equatable, Identifiable {
    enum Scope: String, Codable, CaseIterable {
        case host, path, exact
        var title: String {
            switch self {
            case .host: return "Whole site"
            case .path: return "Path"
            case .exact: return "Exact URL"
            }
        }
    }

    var id = UUID()
    var scope: Scope = .host
    var host = ""
    var subdomains = false
    var port = ""
    var path = ""
    var exact = ""
    var destination: UUID

    static let limit = 128
    static let fieldLimit = 2_048

    /// Host spelling is case insensitive; one DNS root dot is immaterial.
    static func hostname(_ text: String) -> String {
        var host = text.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }

    static func address(_ text: String) -> URLComponents? {
        guard let parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              parts.url != nil else { return nil }
        return parts
    }

    var error: String? {
        guard [host, port, path, exact].allSatisfy({ $0.utf8.count <= Self.fieldLimit }) else {
            return "Each field is limited to 2,048 bytes."
        }
        if scope == .exact {
            return Self.address(exact) == nil ? "Enter a complete HTTP or HTTPS URL without credentials." : nil
        }
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
              let parts = Self.address("https://\(host)"),
              parts.path.isEmpty, parts.query == nil, parts.fragment == nil, parts.port == nil,
              Self.hostname(parts.host ?? "") == Self.hostname(host) else {
            return "Enter a host only, such as meet.google.com or localhost."
        }
        if !port.isEmpty, Int(port).map({ (1...65535).contains($0) }) != true {
            return "Enter a port between 1 and 65535, or leave it empty for any port."
        }
        if scope == .path {
            guard path.hasPrefix("/"), !path.contains("?"), !path.contains("#"),
                  let parts = URLComponents(string: "https://example.org" + path),
                  parts.percentEncodedPath == path else {
                return "Enter an encoded path starting with /, without a query or fragment."
            }
        }
        return nil
    }

    func matches(_ url: URL) -> Bool {
        guard error == nil, let candidate = Self.address(url.absoluteString) else { return false }
        if scope == .exact {
            guard let expected = Self.address(exact) else { return false }
            return candidate.scheme?.lowercased() == expected.scheme?.lowercased()
                && Self.hostname(candidate.host ?? "") == Self.hostname(expected.host ?? "")
                && Self.effectivePort(candidate) == Self.effectivePort(expected)
                && Self.documentPath(candidate) == Self.documentPath(expected)
                && candidate.percentEncodedQuery == expected.percentEncodedQuery
                && candidate.percentEncodedFragment == expected.percentEncodedFragment
        }
        let actual = Self.hostname(candidate.host ?? "")
        let wanted = Self.hostname(host)
        guard actual == wanted || (subdomains && actual.hasSuffix("." + wanted)) else { return false }
        if let port = Int(port), port != Self.effectivePort(candidate) { return false }
        guard scope == .path else { return true }
        let actualPath = Self.documentPath(candidate)
        return actualPath == path || actualPath.hasPrefix(path.hasSuffix("/") ? path : path + "/")
    }

    private static func effectivePort(_ parts: URLComponents) -> Int {
        parts.port ?? (parts.scheme?.lowercased() == "https" ? 443 : 80)
    }

    private static func documentPath(_ parts: URLComponents) -> String {
        parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
    }

    static func winner(in rules: [LinkRule], for url: URL, spaces: Set<UUID>) -> LinkRule? {
        rules.first { spaces.contains($0.destination) && $0.matches(url) }
    }

    static func validation(_ rules: [LinkRule]) -> String? {
        if rules.count > limit { return "Keep at most 128 rules." }
        if Set(rules.map(\.id)).count != rules.count { return "Each rule needs a unique identity." }
        return rules.enumerated().compactMap { index, rule in
            rule.error.map { "Rule \(index + 1): \($0)" }
        }.first
    }
}
