// A lossless JSON index: values remain UTF-8 ranges in the original response,
// so a large integer, duplicate key or exponent is never rounded or rewritten.
// Parsing runs on one worker; 2 MiB, 20,000 nodes and 64 levels bound work and
// retained state. JSON Pointer paths escape slashes and tildes unambiguously.
import Foundation

struct JSONDocument {
    static let byteLimit = 2 * 1024 * 1024
    static let nodeLimit = 20_000
    static let depthLimit = 64
    struct Node: Identifiable {
        let id: Int
        let parent: Int?
        let label: String
        let component: String
        let depth: Int
        let kind: String
        var range: Range<Int>
        var children: [Int] = []
    }
    struct Invalid: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    let bytes: [UInt8]
    let nodes: [Node]

    init(_ text: String) throws {
        guard text.utf8.count <= Self.byteLimit else { throw Invalid(message: "JSON exceeds 2 MiB. The original response remains available.") }
        var parser = Parser(bytes: Array(text.utf8))
        try parser.value(parent: nil, label: "$", component: "", depth: 0)
        parser.space()
        guard parser.at == parser.bytes.count else { throw parser.invalid() }
        bytes = parser.bytes
        nodes = parser.nodes
    }
    func value(_ id: Int) -> String { String(decoding: bytes[nodes[id].range], as: UTF8.self) }
    func path(_ id: Int) -> String {
        var components: [String] = []
        var next: Int? = id
        while let index = next, nodes[index].parent != nil {
            components.append(nodes[index].component.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1"))
            next = nodes[index].parent
        }
        return components.isEmpty ? "" : "/" + components.reversed().joined(separator: "/")
    }
    private struct Parser {
        let bytes: [UInt8]
        var at = 0
        var nodes: [Node] = []
        mutating func space() { while at < bytes.count && [9, 10, 13, 32].contains(bytes[at]) { at += 1 } }
        func invalid() -> Invalid { Invalid(message: "Invalid JSON near byte \(at + 1). The original response is unchanged.") }
        mutating func eat(_ byte: UInt8) -> Bool {
            space()
            if at < bytes.count && bytes[at] == byte { at += 1; return true }
            return false
        }
        mutating func string() throws -> String {
            space()
            let start = at
            guard at < bytes.count, bytes[at] == 34 else { throw invalid() }
            at += 1
            while at < bytes.count {
                let byte = bytes[at]
                at += 1
                if byte == 92 { guard at < bytes.count else { throw invalid() }; at += 1 }
                else if byte == 34 {
                    guard let decoded = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<at])) else { throw invalid() }
                    return decoded
                }
            }
            throw invalid()
        }
        @discardableResult mutating func value(parent: Int?, label: String, component: String, depth: Int) throws -> Int {
            space()
            guard depth <= JSONDocument.depthLimit, nodes.count < JSONDocument.nodeLimit else {
                throw Invalid(message: "JSON exceeds 64 levels or 20,000 values. Use the original response.")
            }
            guard at < bytes.count else { throw invalid() }
            let start = at, id = nodes.count, first = bytes[at]
            let kind = first == 123 ? "object" : first == 91 ? "array" : first == 34 ? "string" : first == 110 ? "null" : (first == 116 || first == 102) ? "boolean" : "number"
            nodes.append(Node(id: id, parent: parent, label: label, component: component, depth: depth, kind: kind, range: start..<start))
            if first == 123 || first == 91 {
                at += 1
                let end: UInt8 = first == 123 ? 125 : 93
                if !eat(end) {
                    var index = 0
                    repeat {
                        let key = first == 123 ? try string() : String(index)
                        if first == 123 && !eat(58) { throw invalid() }
                        let child = try value(parent: id, label: key, component: key, depth: depth + 1)
                        nodes[id].children.append(child)
                        index += 1
                        if eat(end) { break }
                        guard eat(44) else { throw invalid() }
                    } while true
                }
            } else if first == 34 { _ = try string() }
            else if first == 116 || first == 102 || first == 110 {
                let literal = Array((first == 116 ? "true" : first == 102 ? "false" : "null").utf8)
                guard at + literal.count <= bytes.count, Array(bytes[at..<at + literal.count]) == literal else { throw invalid() }
                at += literal.count
            } else {
                if bytes[at] == 45 { at += 1 }
                guard at < bytes.count else { throw invalid() }
                if bytes[at] == 48 { at += 1 }
                else {
                    guard (49...57).contains(bytes[at]) else { throw invalid() }
                    digits()
                }
                if at < bytes.count && bytes[at] == 46 {
                    at += 1
                    guard at < bytes.count, (48...57).contains(bytes[at]) else { throw invalid() }
                    digits()
                }
                if at < bytes.count && [69, 101].contains(bytes[at]) {
                    at += 1
                    if at < bytes.count && [43, 45].contains(bytes[at]) { at += 1 }
                    guard at < bytes.count, (48...57).contains(bytes[at]) else { throw invalid() }
                    digits()
                }
            }
            nodes[id].range = start..<at
            return id
        }
        mutating func digits() { while at < bytes.count && (48...57).contains(bytes[at]) { at += 1 } }
    }
}
