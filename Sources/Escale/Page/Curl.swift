// A call as the curl command that sends it again from a terminal, the way
// browsers' "Copy as cURL" writes it: the URL, the method when the body
// does not imply it, the request headers WebKit reported, and the body.
// Escale never runs it: this only writes text for the person to paste.
// Headers curl sets itself (Host, Content-Length) are left out, and
// Accept-Encoding becomes `--compressed` so the answer reads as text.
// Values are POSIX single-quoted, which every shell reads literally.
//
// Copy as › fetch writes the same request for a JavaScript console or Node,
// refused in the same cases. It drops Accept-Encoding too: fetch negotiates
// compression itself, and a browser refuses the header.
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

enum Fetch {
    static func command(_ call: Call, _ detail: CallDetail) -> String {
        var options: [String] = []
        let method = call.method.uppercased()
        if method != "GET" { options.append(#""method": "# + string(method)) }
        let headers = detail.requestHeaders.filter { !["host", "content-length", "accept-encoding"].contains($0.name.lowercased()) }
        if !headers.isEmpty {
            let lines = headers.map { "    " + string($0.name) + ": " + string($0.value) }
            options.append(#""headers": {"# + "\n" + lines.joined(separator: ",\n") + "\n  }")
        }
        if let body = detail.requestBody { options.append(#""body": "# + string(body)) }
        let url = string(call.url)
        guard !options.isEmpty else { return "fetch(" + url + ");" }
        return "fetch(" + url + ", {\n  " + options.joined(separator: ",\n  ") + "\n});"
    }

    /// A double-quoted JavaScript string that reads back as `text`. Control
    /// characters, a binary body's included, and the two separators
    /// JavaScript also ends lines on are escaped: the literal stays one line.
    static func string(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0..<0x20, 0x7F, 0x2028, 0x2029: out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
