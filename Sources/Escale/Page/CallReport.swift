// The bug report the API Calls panel copies: one observed exchange and the
// tab it happened in, as Markdown someone can paste into an issue. Everything
// comes from what WebKit saw; nothing is fetched or replayed to fill it in.
// Credentials in headers are replaced, because a report is meant to be
// shared; bodies are not rewritten, only cut, and the cut is stated.
import Foundation

struct CallReport {
    /// Each body, sent and received, is cut to this many characters.
    static let bodyLimit = 16 * 1024

    struct Context {
        var page = ""
        var title = ""
        /// The bookmark's environment label linked to the tab, if any.
        var environment = ""
        var space = ""
        var version = ""
        var system = ""
    }

    let call: Call
    let detail: CallDetail?
    let body: CallBody?
    let context: Context

    /// Header names whose value is a credential, whole or in part.
    static func secret(_ name: String) -> Bool {
        let name = name.lowercased()
        if ["authorization", "proxy-authorization", "cookie", "set-cookie"].contains(name) { return true }
        return ["token", "secret", "key", "session", "password", "auth"].contains { name.contains($0) }
    }

    static func cut(_ text: String, limit: Int = bodyLimit) -> (String, Bool) {
        text.count > limit ? (String(text.prefix(limit)), true) : (text, false)
    }

    /// The call in one line: what was asked and what came back.
    static func headline(_ call: Call) -> String {
        let outcome: String
        switch call.state {
        case .loading: outcome = "pending"
        case .done(let status): outcome = call.statusText.isEmpty ? "\(status)" : "\(status) \(call.statusText)"
        case .failed(let reason): outcome = "failed (\(reason))"
        case .canceled: outcome = "canceled"
        case .earlier: outcome = "loaded before the collection began"
        }
        return "\(call.method) \(call.path) → \(outcome)"
    }

    var text: String {
        var out: [String] = []
        out.append("## " + Self.headline(call))
        out.append("")
        out.append("- URL: " + call.url)
        var facts = ["Method: " + call.method, "Type: " + call.type]
        if let status = call.status { facts.append("Status: \(status)" + (call.statusText.isEmpty ? "" : " " + call.statusText)) }
        if let duration = call.duration { facts.append("Duration: " + Call.milliseconds(duration)) }
        out.append("- " + facts.joined(separator: " · "))
        if call.size != nil || call.transfer != nil {
            out.append("- Response size: \(Call.bytes(call.size)) decoded, \(Call.bytes(call.transfer)) transferred")
        }
        switch call.state {
        case .failed(let reason): out.append("- Failure (WebKit): " + reason)
        case .canceled: out.append("- Canceled before completion")
        default: break
        }
        if call.redirects > 0 {
            out.append("- Redirects: \(call.redirects)")
            for hop in detail?.redirects ?? [] { out.append("  - " + (hop.status.map { "\($0) " } ?? "") + hop.url) }
        }
        out.append("- Made by: " + call.origin + (call.source.isEmpty ? "" : " · served from " + call.source))
        if let initiator = detail?.initiator, !initiator.isEmpty { out.append("- Initiator: " + initiator) }

        out.append("")
        out.append("### Environment")
        out.append("")
        out.append("- Page: " + context.page + (context.title.isEmpty ? "" : " (\(context.title))"))
        if !context.environment.isEmpty { out.append("- Environment (bookmark label): " + context.environment) }
        if !context.space.isEmpty { out.append("- Space: " + context.space) }
        out.append("- Escale \(context.version) · \(context.system)")

        if let detail {
            section(&out, "Request headers", headers: detail.requestHeaders)
            if let body = detail.requestBody {
                let length = detail.requestLength ?? body.count
                let (shown, cut) = Self.cut(body)
                let kind = detail.requestType.isEmpty ? "" : detail.requestType + ", "
                out.append("")
                out.append("### Request body (\(kind)\(length) characters\(cut ? ", first \(Self.bodyLimit) shown" : ""))")
                out.append("")
                fence(&out, shown, json: detail.requestType.contains("json"))
            }
            section(&out, "Response headers", headers: detail.responseHeaders)
        } else {
            out.append("")
            out.append("Headers: unavailable (the call belongs to an earlier inspection session).")
        }

        out.append("")
        switch body {
        case .text(let text, let length, let cut)?:
            let (shown, cutHere) = Self.cut(text)
            let partial = cut || cutHere
            let kind = call.mime.isEmpty ? "" : call.mime + ", "
            out.append("### Response body (\(kind)\(length) characters\(partial ? ", first \(shown.count) shown" : ""))")
            out.append("")
            fence(&out, shown, json: call.mime.contains("json"))
        case .binary(let length)?:
            out.append("### Response body")
            out.append("")
            out.append("Binary (\(call.mime.isEmpty ? "unknown type" : call.mime)), about \(Call.bytes(Double(length))); not included.")
        case .unavailable(let reason)?:
            out.append("### Response body")
            out.append("")
            out.append("Unavailable: " + reason)
        case .reading?, nil:
            out.append("### Response body")
            out.append("")
            out.append("Not read.")
        }
        out.append("")
        out.append("_Observed by Escale's Network tool (Developer mode) from WebKit's inspector collection; nothing was replayed. Credential headers are redacted._")
        return out.joined(separator: "\n")
    }

    private func section(_ out: inout [String], _ title: String, headers: [CallDetail.Header]) {
        out.append("")
        out.append("### " + title)
        out.append("")
        guard !headers.isEmpty else { out.append("None reported by WebKit."); return }
        out.append("```http")
        for header in headers {
            out.append(header.name + ": " + (Self.secret(header.name) ? "[redacted]" : header.value))
        }
        out.append("```")
    }

    /// A fence longer than any run of backticks in the text, so a body that
    /// holds Markdown cannot close it early.
    private func fence(_ out: inout [String], _ text: String, json: Bool) {
        var longest = 0, run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let marks = String(repeating: "`", count: max(3, longest + 1))
        out.append(marks + (json ? "json" : ""))
        out.append(text)
        out.append(marks)
    }
}
