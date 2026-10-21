// A link copied as Markdown, from a page's address (⌘⌥C) or a link's
// right-click menu: its text can't end or break the link, it stays on one
// line, and a link with no text at all still has something to click.
import Foundation
import Testing
@testable import Escale

@Suite struct MarkdownLinkTests {
    private let url = URL(string: "https://example.com/a?b=1")!

    @Test func textAndAddress() {
        #expect(Browser.markdownLink("Example", to: url) == "[Example](https://example.com/a?b=1)")
    }

    @Test func bracketsAndBackslashesAreEscaped() {
        #expect(Browser.markdownLink(#"Docs [v2] \ notes"#, to: url) == #"[Docs \[v2\] \\ notes](https://example.com/a?b=1)"#)
    }

    @Test(arguments: ["", "  \n\t "])
    func noTextGivesTheAddress(_ text: String) {
        #expect(Browser.markdownLink(text, to: url) == "[https://example.com/a?b=1](https://example.com/a?b=1)")
    }

    @Test func anAddressStandingInIsEscapedToo() {
        let local = URL(string: "http://[::1]:8080/")!
        #expect(Browser.markdownLink("", to: local) == #"[http://\[::1\]:8080/](http://[::1]:8080/)"#)
    }

    @Test func linesAndRunsOfSpaceBecomeOneSpace() {
        #expect(Browser.markdownLink("  Read\n  more\t here ", to: url) == "[Read more here](https://example.com/a?b=1)")
    }
}
