import Foundation

// ⌘L over an address with a query unfolds it: one row per parameter under the
// field, in the address's order, repeated keys and all. The field stays the
// one place the address is written. A parameter turned off leaves the address
// but keeps its row, so it comes back as it was. Typing in the field re-reads
// the rows while it is still this page (the same text before `?`); anything
// else typed is another address, and the list goes back to suggestions.
//
// Only what changes is written differently: a parameter keeps its raw,
// percent-encoded text, so an address left alone loads exactly as it was.
// Values are decoded only to be read, the way URLSearchParams reads them.
//
// Parsed when ⌘L opens and on each key while it is up, from at most 4096
// bytes, as Environment.swift bounds an address. Nothing is kept once the
// field closes.
struct Query: Equatable {
    struct Parameter: Equatable {
        /// As written in the address, still percent-encoded.
        var key: String
        /// Nil for a bare key (`?flag`), which is not `?flag=`.
        var value: String?
        var on = true
        /// Where the value, or a bare key, sits in the field, in UTF-16 units.
        /// Nil while off: it is not in the address.
        var range: NSRange?

        var name: String { Query.decoded(key) }
        var text: String { Query.decoded(value ?? "") }

        /// Campaign and click identifiers, which say nothing about the page.
        var tracking: Bool {
            let name = name.lowercased()
            return name.hasPrefix("utm_") || Query.trackers.contains(name)
        }

        /// What the value is, when that is worth a word beside it.
        var kind: String? {
            let text = text
            if text.hasPrefix("https://") || text.hasPrefix("http://") { return "URL" }
            if text.hasPrefix("eyJ"), text.split(separator: ".", omittingEmptySubsequences: false).count == 3 { return "JWT" }
            return nil
        }
    }

    private static let trackers: Set<String> = ["gclid", "gbraid", "wbraid", "dclid", "fbclid", "msclkid", "mc_cid", "mc_eid"]

    /// The address up to `?`, and from `#` on, as written.
    let base: String
    let fragment: String
    private(set) var parameters: [Parameter]

    /// An http(s) address with at least one parameter; nil for anything else.
    init?(_ address: String) {
        guard let read = Query.parse(address), !read.parameters.isEmpty else { return nil }
        let scheme = read.base.prefix(8).lowercased()
        guard scheme.hasPrefix("https://") || scheme.hasPrefix("http://") else { return nil }
        self = read
    }

    private init(base: String, fragment: String, parameters: [Parameter]) {
        self.base = base
        self.fragment = fragment
        self.parameters = parameters
    }

    /// The address with the parameters that are on.
    var address: String {
        let written = parameters.filter(\.on).map { parameter in
            parameter.value.map { parameter.key + "=" + $0 } ?? parameter.key
        }
        return base + (written.isEmpty ? "" : "?" + written.joined(separator: "&")) + fragment
    }

    /// These rows after `text` was typed, or nil when it is another page.
    /// With as many parameters as were on, each written one takes the place
    /// of the one it was; otherwise the ones turned off keep their index as
    /// far as the new list goes.
    func reading(_ text: String) -> Query? {
        guard let read = Query.parse(text), read.base == base else { return nil }
        let off = parameters.enumerated().filter { !$0.element.on }
        var merged = read.parameters
        if read.parameters.count == parameters.count - off.count {
            merged = parameters
            var written = read.parameters.makeIterator()
            for index in merged.indices where merged[index].on {
                if let next = written.next() { merged[index] = next }
            }
        } else {
            for (index, parameter) in off { merged.insert(parameter, at: min(index, merged.count)) }
        }
        return Query(base: read.base, fragment: read.fragment, parameters: merged)
    }

    mutating func toggle(_ index: Int) {
        guard parameters.indices.contains(index) else { return }
        parameters[index].on.toggle()
        // Off, it is no longer in the field; back on, the next reading places it.
        parameters[index].range = nil
    }

    mutating func removeTracking() { parameters.removeAll(where: \.tracking) }

    static func decoded(_ raw: String) -> String {
        let spaced = raw.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    private static func parse(_ text: String) -> Query? {
        guard text.utf8.count <= 4096 else { return nil }
        let hash = text.firstIndex(of: "#") ?? text.endIndex
        let head = text[..<hash]
        guard let mark = head.firstIndex(of: "?") else {
            return Query(base: String(head), fragment: String(text[hash...]), parameters: [])
        }
        let parameters = head[head.index(after: mark)...].split(separator: "&").map { piece in
            guard let equals = piece.firstIndex(of: "=") else {
                return Parameter(key: String(piece), value: nil, range: NSRange(piece.startIndex..<piece.endIndex, in: text))
            }
            let start = piece.index(after: equals)
            return Parameter(key: String(piece[..<equals]), value: String(piece[start...]),
                             range: NSRange(start..<piece.endIndex, in: text))
        }
        return Query(base: String(head[..<mark]), fragment: String(text[hash...]), parameters: parameters)
    }
}
