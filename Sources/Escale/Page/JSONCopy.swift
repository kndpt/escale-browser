// What the JSON reader copies besides a value as written: a JavaScript path
// (`.data[0].id`, `["odd key"]`), and an object or an array minified or
// indented. Both read the original bytes (JSONDocument.swift) and change only
// whitespace outside strings, so numbers, escapes, duplicate keys and key
// order stay as received; a JavaScript round trip would round big integers
// and drop duplicates. Work is bounded by the document's own limits.
// Used by the tab (JSONReader.swift) and the API Calls panel (CallsPanel.swift).
import SwiftUI

extension JSONDocument {
    /// The path from the parsed root as JavaScript writes it: `.key` for an
    /// identifier, `["key"]` otherwise, `[0]` for an index. The root's is empty.
    func script(_ id: Int) -> String {
        var parts: [String] = []
        var next = id
        while let parent = nodes[next].parent {
            let key = nodes[next].component
            if nodes[parent].kind == "array" { parts.append("[\(key)]") }
            else if Self.identifier(key) { parts.append("." + key) }
            else { parts.append("[" + Self.quoted(key) + "]") }
            next = parent
        }
        return parts.reversed().joined()
    }

    /// An ECMAScript IdentifierName; reserved words are valid after a dot.
    static func identifier(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, first.properties.isIDStart || first == "$" || first == "_" else { return false }
        return key.unicodeScalars.dropFirst().allSatisfy {
            $0.properties.isIDContinue || $0 == "$" || $0 == "\u{200C}" || $0 == "\u{200D}"
        }
    }

    /// A double-quoted string literal, with control and line separator
    /// characters escaped so the path stays on one line.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    out += String(format: "\\u%04x", scalar.value)
                } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    /// The value without whitespace, or laid out two spaces a level as
    /// `JSON.stringify(value, null, 2)` does; tokens are copied byte for byte.
    func formatted(_ id: Int, indent: Bool) -> String {
        let range = nodes[id].range
        var out: [UInt8] = []
        out.reserveCapacity(range.count)
        var depth = 0
        var at = range.lowerBound
        func line() { out.append(10); out.append(contentsOf: repeatElement(32, count: depth * 2)) }
        // The document is valid, so every string and container closes in range.
        while at < range.upperBound {
            let byte = bytes[at]
            switch byte {
            case 34:
                let start = at
                at += 1
                while bytes[at] != 34 { at += bytes[at] == 92 ? 2 : 1 }
                out.append(contentsOf: bytes[start...at])
            case 9, 10, 13, 32:
                break
            case 123, 91:
                out.append(byte)
                var next = at + 1
                while [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                // `}` and `]` follow `{` and `[` two code points later.
                if bytes[next] == byte + 2 { out.append(byte + 2); at = next }
                else { depth += 1; if indent { line() } }
            case 125, 93:
                depth -= 1
                if indent { line() }
                out.append(byte)
            case 44:
                out.append(byte)
                if indent { line() }
            case 58:
                out.append(byte)
                if indent { out.append(32) }
            default:
                out.append(byte)
            }
            at += 1
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// One menu of copies for a row of the tree, in the tab and in the panel.
struct JSONCopies: View {
    let document: JSONDocument
    let id: Int

    var body: some View {
        Button("Copy Value") { Clipboard.put(document.value(id)) }
        if ["object", "array"].contains(document.nodes[id].kind) {
            Button("Copy Minified") { Clipboard.put(document.formatted(id, indent: false)) }
            Button("Copy Indented") { Clipboard.put(document.formatted(id, indent: true)) }
        }
        Divider()
        Button("Copy JavaScript Path") { Clipboard.put(document.script(id)) }
        Button("Copy JSON Pointer") { Clipboard.put(document.path(id)) }
    }
}
