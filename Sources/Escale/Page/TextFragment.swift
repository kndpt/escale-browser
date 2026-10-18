import AppKit
import WebKit

// Copy Link with Highlight: the page's address with a text fragment
// (`#:~:text=`, https://wicg.github.io/scroll-to-text-fragment/), which
// scrolls to the passage and marks it when the link is opened, in WebKit and
// Chromium alike. It is the selection menu's link, and the right-click
// menu's where WebKit doesn't offer its own (macOS 27's WebKit does, outside
// frames); one name for both, WebKit's.
//
// What to point at is read from the page only when the entry is chosen
// (text-fragment.js, in Escale's own script world, main frame only): the
// passage, or its first and last words when it is long or spans blocks, and
// a few words either side while it is found more than once. The terms are
// encoded and joined to the address here, as a rule the tests hold to the
// spec. Nothing runs before the click and nothing stays after it.
//
// Where no fragment would find the text again — a field, a frame, a shadow
// root — the plain address is copied, and the line at the window's foot says
// so rather than hand over a link that goes nowhere.

/// The words a text fragment looks for, as the page named them.
struct TextFragment: Equatable {
    var start: String
    var end: String?
    var prefix: String?
    var suffix: String?

    static let script = Bundled.script("text-fragment.js")

    /// Each term with its runs of white space made one space; an empty one
    /// is none. Nil without a start.
    init?(start: String, end: String? = nil, prefix: String? = nil, suffix: String? = nil) {
        func term(_ text: String?) -> String? {
            let words = text?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
            return words.isEmpty ? nil : words
        }
        guard let start = term(start) else { return nil }
        self.start = start
        self.end = term(end)
        self.prefix = term(prefix)
        self.suffix = term(suffix)
    }

    /// The page script's answer; nil when it found nothing it could point
    /// at, or anything but strings.
    init?(_ answer: Any?) {
        guard let body = answer as? [String: Any], let start = body["start"] as? String,
              ["end", "prefix", "suffix"].allSatisfy({ body[$0] == nil || body[$0] is String })
        else { return nil }
        self.init(start: start, end: body["end"] as? String, prefix: body["prefix"] as? String, suffix: body["suffix"] as? String)
    }

    /// `text=[prefix-,]start[,end][,-suffix]`.
    var directive: String {
        var terms = [Self.encode(start)]
        if let prefix { terms.insert(Self.encode(prefix) + "-", at: 0) }
        if let end { terms.append(Self.encode(end)) }
        if let suffix { terms.append("-" + Self.encode(suffix)) }
        return "text=" + terms.joined(separator: ",")
    }

    /// `address` with its own fragment kept, so a page that routes by it
    /// still opens where it was, and any directive it carried replaced.
    func link(to address: URL) -> String {
        let whole = address.absoluteString
        let mark = whole.firstIndex(of: "#")
        let base = mark.map { String(whole[..<$0]) } ?? whole
        var fragment = mark.map { String(whole[whole.index(after: $0)...]) } ?? ""
        if let directives = fragment.range(of: ":~:") { fragment = String(fragment[..<directives.lowerBound]) }
        return base + "#" + fragment + ":~:" + directive
    }

    /// Percent-encoded as `encodeURIComponent` does, and `-` too: with `,`
    /// and `&` it is the directive's own syntax.
    static func encode(_ term: String) -> String {
        term.addingPercentEncoding(withAllowedCharacters: kept) ?? ""
    }

    private static let kept = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.!~*'()")
}

extension Browser {
    /// Copy Link with Highlight, from either menu: the selection is read now,
    /// once, and the page's address is the fallback.
    func copyHighlightLink(in tab: Tab) {
        guard let page = tab.built, let address = tab.address else { return }
        page.evaluateJavaScript(TextFragment.script, in: nil, in: .defaultClient) { [weak self] result in
            guard let self, tab.built === page else { return }
            let fragment = TextFragment(try? result.get())
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(fragment?.link(to: address) ?? address.absoluteString, forType: .string)
            if fragment == nil {
                announce("Page address copied: this text can't be linked to", symbol: "link")
            } else {
                announce("Link with highlight copied", symbol: "link")
            }
        }
    }
}
