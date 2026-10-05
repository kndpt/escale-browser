// The editor accepts what people copy from the address bar. Parsing an input
// into the existing rule format keeps routing and stored-rule compatibility
// unchanged. Invalid input remains invalid, never a previously valid rule;
// only a new draft infers scope, until an explicit choice takes precedence.
import Foundation

enum LinkAddress {
    static func text(for rule: LinkRule) -> String {
        if rule.scope == .exact { return rule.exact }
        return rule.host + (rule.port.isEmpty ? "" : ":" + rule.port)
            + (rule.scope == .path ? rule.path : "")
    }

    private static func parts(_ input: String) -> URLComponents? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= LinkRule.fieldLimit,
              let parts = LinkRule.address(text.contains("://") ? text : "https://" + text),
              let host = parts.host,
              LinkRule(host: host, destination: UUID()).error == nil else { return nil }
        return parts
    }

    static func error(_ text: String) -> String? {
        if text.utf8.count > LinkRule.fieldLimit { return "Keep the address within 2,048 bytes." }
        return parts(text) == nil ? "Enter a site or an HTTP(S) address, such as github.com/acme, without a username or password." : nil
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
