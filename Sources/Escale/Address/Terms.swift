// What a query typed into Bearings asks of a place: the words it holds, not
// the punctuation between them. "orchestrator handlers" finds a bookmark
// called iso--checkout--orchestrator-handlers, a tab on a path
// .../orchestrator_handlers, a page titled "Orchestrator · Handlers" and a
// file OrchestratorHandlers.java.
//
// A match has three strengths, so that loosening the rule never pushes down
// what already matched: the text as typed, found as one run in one name; the
// same words in the same order with only separators between them; every word
// starting a word of the place, in any order. Words are runs of letters and
// digits, so spaces, dashes, underscores, dots and slashes all separate them,
// and so does a capital after a lowercase letter or a digit (camelCase). A word
// has to start a word of the place, which keeps "a b" from matching every name
// holding both letters, while the last word can still be half typed.
//
// A place has several names: a title and an address, a bookmark's
// environments. The words may be spread across them, so "orchestrator handlers
// swa" finds "Swagger UI" at reception-orchestrator-handlers.example; the
// joined strength still needs one name holding the words in order.
//
// The words are cut once per keystroke; names are walked only when the query
// was not already found as typed, and nothing is kept between queries. The
// query itself is never rewritten: what is opened or searched for is still
// what was typed.

import Foundation

struct Terms {
    /// How closely a name answered the query, closest first.
    enum Match: Int, Comparable, CaseIterable {
        /// The query as typed, contiguous, ignoring case.
        case typed
        /// The same words in order, with only separators between them.
        case joined
        /// Every word starts a word of the name, in any order.
        case words

        static func < (a: Match, b: Match) -> Bool { a.rawValue < b.rawValue }
    }

    /// The query lowercased, each run of spaces as one, as the contiguous match reads it.
    let whole: String
    /// Its words, lowercased, in the order they were typed.
    let words: [String]
    /// The same words as UTF-8, the form they are searched for in.
    private let bytes: [[UInt8]]
    /// Words of plain ASCII are looked for in each name as it is, ignoring
    /// case; others in a lowercased, composed copy made only for them.
    private let ascii: [Bool]
    /// Whether the words can find more than the query as typed: not for a
    /// single bare word, which cannot start a word it is not contained in.
    let loosens: Bool
    /// Whether words were typed apart, which no address holds as typed.
    let spaced: Bool
    /// The words as one run, to recognise them joined by any separators.
    private let joined: String

    init(_ typed: String) {
        // Composed (NFC), the form names are compared in: bytes are searched,
        // not canonically equivalent characters.
        whole = typed.precomposedStringWithCanonicalMapping.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        words = whole.split { !$0.unicodeScalars.contains(where: Terms.inWord) }.map(String.init)
        bytes = words.map { Array($0.utf8) }
        ascii = bytes.map { $0.allSatisfy { $0 < 0x80 } }
        loosens = !words.isEmpty && words != [whole]
        spaced = whole.utf8.contains(UInt8(ascii: " "))
        joined = words.joined(separator: " ")
    }

    var isEmpty: Bool { whole.isEmpty }

    /// The closest way `text` answers the query, or nil if it does not.
    func match(_ text: String) -> Match? { match([text]) }

    /// The closest way a place known by these names answers the query.
    func match(_ names: [String]) -> Match? {
        guard !whole.isEmpty else { return nil }
        if names.contains(where: { $0.lowercased().contains(whole) }) { return .typed }
        return byWords(names.map { $0[...] })
    }

    /// Whether the first word could start a word of either name: turns most
    /// places away before any name is cut, copied or put in a list.
    func mayMatch(_ first: String, _ second: String) -> Bool {
        guard loosens, let word = bytes.first else { return false }
        guard ascii[0] else { return true }
        return Terms.starts(word, in: first[...], folding: true) || Terms.starts(word, in: second[...], folding: true)
    }

    /// Only the looser matches, over a place's names in their own case, once
    /// none holds the query as typed: the history reads 2,000 places a key and
    /// copies none of them for an ASCII query.
    func byWords(_ names: [Substring]) -> Match? {
        guard loosens else { return nil }
        var folded: [Int: String] = [:]
        func fold(_ index: Int) -> String {
            if let made = folded[index] { return made }
            let made = String(names[index]).precomposedStringWithCanonicalMapping.lowercased()
            folded[index] = made
            return made
        }
        for (index, word) in bytes.enumerated() {
            let found = names.indices.contains { name in
                ascii[index] ? Terms.starts(word, in: names[name], folding: true)
                    : Terms.starts(word, in: fold(name)[...], folding: false)
            }
            guard found else { return nil }
        }
        return names.contains { Terms.normalised($0).contains(joined) } ? .joined : .words
    }

    private static func inWord(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    /// Names are read as a buffer of bytes, not through a generic
    /// collection: unspecialised, a debug build took seconds over a history.
    private typealias Bytes = UnsafeBufferPointer<UInt8>

    private static func starts(_ word: [UInt8], in name: Substring, folding: Bool) -> Bool {
        name.utf8.withContiguousStorageIfAvailable { starts(word, in: $0, folding: folding) }
            ?? Array(name.utf8).withUnsafeBufferPointer { starts(word, in: $0, folding: folding) }
    }

    /// Whether `word` begins a word somewhere in `text`, both UTF-8, with
    /// ASCII capitals read as lowercase when `folding`. Read byte by byte:
    /// Foundation's `contains` and `range(of:)` cost as much per name as the
    /// rest of a keystroke, and doubled it on a full history.
    private static func starts(_ word: [UInt8], in text: Bytes, folding: Bool) -> Bool {
        guard let first = word.first, text.count >= word.count else { return false }
        var at = 0
        let last = text.count - word.count
        while at <= last {
            if folded(text[at], folding) == first, boundary(before: at, in: text) {
                var offset = 1
                while offset < word.count, folded(text[at + offset], folding) == word[offset] { offset += 1 }
                // Followed by a combining accent, the last letter is another one.
                if offset == word.count, !combining(at: at + word.count, in: text) { return true }
            }
            at += 1
        }
        return false
    }

    private static func folded(_ byte: UInt8, _ folding: Bool) -> UInt8 {
        folding && byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
    }

    /// Whether a combining diacritic (U+0300–U+036F) starts at `at`.
    private static func combining(at: Int, in text: Bytes) -> Bool {
        guard at < text.count else { return false }
        if text[at] == 0xCC { return true }
        return text[at] == 0xCD && at + 1 < text.count && text[at + 1] < 0xB0
    }

    /// Whether a word starts at `at`: after a separator, or at a capital
    /// following a lowercase letter or a digit.
    private static func boundary(before at: Int, in text: Bytes) -> Bool {
        guard at > 0 else { return true }
        let current = text[at]
        // A continuation byte is never the start of a match.
        if current & 0xC0 == 0x80 { return false }
        let capital = current >= 0x41 && current <= 0x5A
        let previous = text[at - 1]
        if previous < 0x80 {
            let lower = previous >= 0x61 && previous <= 0x7A
            let digit = previous >= 0x30 && previous <= 0x39
            guard lower || digit || (previous >= 0x41 && previous <= 0x5A) else { return true }
            return capital && (lower || digit)
        }
        var start = at - 1
        while start > 0, text[start] & 0xC0 == 0x80 { start -= 1 }
        var iterator = text[start..<at].makeIterator()
        var decoder = UTF8()
        guard case .scalarValue(let scalar) = decoder.decode(&iterator) else { return true }
        return !inWord(scalar) || (capital && scalar.properties.isLowercase)
    }

    /// Lowercased, each run of separators and each camelCase step as one
    /// space, so joined words can be found as one run.
    private static func normalised(_ name: Substring) -> String {
        var out = ""
        var gap = false
        var previous: Unicode.Scalar?
        let decomposed = name.utf8.contains { $0 == 0xCC || $0 == 0xCD }
        let text = decomposed ? String(name).precomposedStringWithCanonicalMapping[...] : name
        for scalar in text.unicodeScalars {
            if inWord(scalar) {
                let step = scalar.properties.isUppercase
                    && (previous.map { $0.properties.isLowercase || $0.properties.numericType != nil } ?? false)
                if gap || step, !out.isEmpty { out.append(" ") }
                out.append(scalar.properties.lowercaseMapping)
                gap = false
            } else {
                gap = true
            }
            previous = scalar
        }
        return out
    }
}
