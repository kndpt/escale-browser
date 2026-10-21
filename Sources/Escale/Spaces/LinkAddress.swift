// The editor accepts what people copy from the address bar. Parsing an input
// into the existing rule format keeps routing and stored-rule compatibility
// unchanged. Invalid input remains invalid, never a previously valid rule;
// only a new draft infers scope, until an explicit choice takes precedence.
// A host must be one a link can carry, as no rule matches `*` literally. The
// check lives here, not in `LinkRule`, so saved rules still load as before.
import Foundation

enum LinkAddress {
    static func text(for rule: LinkRule) -> String {
        if rule.scope == .exact { return rule.exact }
        return rule.host + (rule.port.isEmpty ? "" : ":" + rule.port)
            + (rule.scope == .path ? rule.path : "")
    }

    private static func components(_ input: String) -> URLComponents? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= LinkRule.fieldLimit else { return nil }
        return LinkRule.address(text.contains("://") ? text : "https://" + text)
    }

    private static func parts(_ input: String) -> URLComponents? {
        guard let parts = components(input), let host = parts.host, visitable(host),
              LinkRule(host: host, destination: UUID()).error == nil else { return nil }
        return parts
    }

    /// ASCII letters, digits, `-`, `_` and `.`, or a bracketed IPv6 address
    /// with its optional zone. Other scalars are IDN, which `URLComponents`
    /// already checked when it decoded the punycode.
    private static func visitable(_ host: String) -> Bool {
        if host.hasPrefix("["), host.hasSuffix("]") {
            var address = in6_addr()
            let literal = host.dropFirst().dropLast().split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
            return inet_pton(AF_INET6, String(literal[0]), &address) == 1
        }
        return host.unicodeScalars.allSatisfy { !$0.isASCII || CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }
    }

    static func error(_ text: String) -> String? {
        if text.utf8.count > LinkRule.fieldLimit { return "Keep the address within 2,048 bytes." }
        if parts(text) != nil { return nil }
        if components(text)?.host?.contains("*") == true {
            return "Wildcards are not supported. Enter a host such as meet.google.com."
        }
        return "Enter a site or an HTTP(S) address, such as github.com/acme, without a username or password."
    }

    static func rule(_ text: String, basedOn original: LinkRule, infer: Bool) -> LinkRule {
        var rule = original
        guard let parts = parts(text) else {
            rule.host = text
            rule.exact = text
            return rule
        }
        if infer {
            if parts.query != nil || parts.fragment != nil { rule.scope = .exact }
            else if !parts.path.isEmpty && parts.path != "/" { rule.scope = .path }
            else { rule.scope = .host }
        }
        rule.host = parts.host ?? ""
        rule.port = parts.port.map(String.init) ?? ""
        rule.path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        rule.exact = parts.string ?? text
        return rule
    }
}
