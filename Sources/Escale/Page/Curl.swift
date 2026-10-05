// A call as the curl command that sends it again from a terminal, the way
// browsers' "Copy as cURL" writes it: the URL, the method when the body
// does not imply it, the request headers WebKit reported, and the body.
// Escale never runs it: this only writes text for the person to paste.
// Headers curl sets itself (Host, Content-Length) are left out, and
// Accept-Encoding becomes `--compressed` so the answer reads as text.
// Values are POSIX single-quoted, which every shell reads literally.
import Foundation

enum Curl {
    /// Why no faithful command can be written, or nil when one can.
    static func missing(_ call: Call, _ detail: CallDetail?) -> String? {
        guard let detail else { return "Headers unavailable" }
        if detail.requestBody != nil, detail.requestCut { return "Body too long to copy" }
        guard !call.url.isEmpty else { return "No address" }
        return nil
    }

    static func command(_ call: Call, _ detail: CallDetail) -> String {
        var parts = ["curl " + quote(call.url)]
        let body = detail.requestBody
        let method = call.method.uppercased()
        switch (method, body) {
        case ("GET", nil): break
        case ("HEAD", nil): parts.append("--head")
        case ("POST", .some): break
        default: parts.append("-X " + quote(method))
        }
        var compressed = false
        for header in detail.requestHeaders {
            switch header.name.lowercased() {
            case "host", "content-length": continue
            case "accept-encoding": compressed = true
            default: parts.append("-H " + quote(header.name + ": " + header.value))
            }
        }
        if let body { parts.append("--data-raw " + quote(body)) }
        if compressed { parts.append("--compressed") }
        return parts.joined(separator: " \\\n  ")
    }

    /// A POSIX single-quoted word: nothing inside is interpreted, and a
    /// quote is closed, escaped and reopened.
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
