import Foundation

// A site searched by the word typed before the words: `npm react` searches
// npm for react, where the engine in Settings would have searched the web.
// Settings holds the keywords as plain text, one `word template` per line,
// so the list is easy to write and travels in a transfer as one word. It
// starts empty: nothing typed changes meaning until a keyword is written.
//
// Bearings asks on every keystroke once a space is typed, so a lookup reads
// the lines by their first word and checks only the matching line's template;
// the whole list is parsed only for Settings. Nothing is cached, and nothing
// is sent before Return.

struct Keyword: Equatable {
    let word: String
    let template: String

    /// The site its searches go to, as the row names it.
    var site: String { Engine.custom.name(custom: template) }

    /// The keywords written, one `word template` per line. A line that is not
    /// two parts, or whose template is not an http or https address with %s,
    /// is refused; a word written twice keeps its first line. Case is ignored.
    static func list(_ text: String) -> [Keyword] {
        var found: [Keyword] = [], words = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let keyword = read(line), words.insert(keyword.word).inserted else { continue }
            found.append(keyword)
        }
        return found
    }

    /// How many written lines are not used, for Settings to say so.
    static func refused(_ text: String) -> Int {
        let lines = text.split(whereSeparator: \.isNewline)
            .filter { !$0.allSatisfy(\.isWhitespace) }
        return lines.count - list(text).count
    }

    /// What was typed read as a keyword and its words, and where they go: nil
    /// when the first word is no keyword or no words follow it.
    static func search(_ typed: String, in text: String) -> (keyword: Keyword, words: String, url: URL)? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let space = trimmed.firstIndex(where: \.isWhitespace) else { return nil }
        let word = trimmed[..<space].lowercased()
        let words = trimmed[space...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let keyword = text.split(whereSeparator: \.isNewline).lazy.compactMap({ read($0, only: word) }).first,
              let url = Engine.url(for: words, template: keyword.template) else { return nil }
        return (keyword, words, url)
    }

    /// One line as a keyword; with `only`, nil for any other word before its
    /// template is read.
    private static func read(_ line: Substring, only: String? = nil) -> Keyword? {
        let parts = line.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2 else { return nil }
        let word = parts[0].lowercased(), template = String(parts[1])
        guard only == nil || word == only, Engine.accepts(template) else { return nil }
        return Keyword(word: word, template: template)
    }
}
