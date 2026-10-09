import Foundation

enum Engine: String, CaseIterable, Identifiable {
    case google, duckduckgo, bing, ecosia, startpage, kagi, brave, qwant, custom

    static let standard = Engine.google

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .ecosia: return "Ecosia"
        case .startpage: return "Startpage"
        case .kagi: return "Kagi"
        case .brave: return "Brave Search"
        case .qwant: return "Qwant"
        case .custom: return "Custom"
        }
    }

    func template(custom: String) -> String {
        switch self {
        case .google: return "https://www.google.com/search?q=%s"
        case .duckduckgo: return "https://duckduckgo.com/?q=%s"
        case .bing: return "https://www.bing.com/search?q=%s"
        case .ecosia: return "https://www.ecosia.org/search?q=%s"
        case .startpage: return "https://www.startpage.com/sp/search?query=%s"
        case .kagi: return "https://kagi.com/search?q=%s"
        case .brave: return "https://search.brave.com/search?q=%s"
        case .qwant: return "https://www.qwant.com/?q=%s"
        case .custom:
            let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
            return Engine.accepts(trimmed) ? trimmed : Engine.standard.template(custom: "")
        }
    }

    func name(custom: String) -> String {
        guard self == .custom else { return title }
        guard let host = Engine.host(of: custom) else { return Engine.standard.title }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func accepts(_ template: String) -> Bool {
        host(of: template) != nil
    }

    static func url(for text: String, template: String) -> URL? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty,
              let escaped = words.addingPercentEncoding(withAllowedCharacters: unreserved),
              let base = URL(string: template.replacingOccurrences(of: "%s", with: mark))?.absoluteString
        else { return nil }
        return URL(string: base.replacingOccurrences(of: mark, with: escaped), encodingInvalidCharacters: false)
    }

    private static let mark = "SEARCHWORDSGOHERE"

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func host(of template: String) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("%s"),
              let parts = URLComponents(string: trimmed.replacingOccurrences(of: "%s", with: "a")),
              let other = URLComponents(string: trimmed.replacingOccurrences(of: "%s", with: "b")),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host, !host.isEmpty, host == other.host
        else { return nil }
        return host.lowercased()
    }
}

/// A site searched by the word typed before the words: `npm react` searches
/// npm for react. Settings holds them one per line, `npm https://…?q=%s`, and
/// the list starts empty, so nothing typed changes meaning until one is written.
struct Keyword: Equatable {
    let word: String
    let template: String

    /// The site its searches go to, as the row names it.
    var site: String { Engine.custom.name(custom: template) }

    /// The keywords written, one `word template` per line. A line that is not
    /// two parts, or whose template is not an http or https address with %s,
    /// is refused; a word written twice keeps its first line. Case is ignored.
    static func list(_ text: String) -> [Keyword] {
        var found: [Keyword] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            let word = parts[0].lowercased(), template = String(parts[1])
            guard Engine.accepts(template), !found.contains(where: { $0.word == word }) else { continue }
            found.append(Keyword(word: word, template: template))
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
        guard let keyword = list(text).first(where: { $0.word == word }),
              let url = Engine.url(for: words, template: keyword.template) else { return nil }
        return (keyword, words, url)
    }
}
