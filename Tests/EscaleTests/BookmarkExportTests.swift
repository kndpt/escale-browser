import Foundation
import Testing
@testable import Escale

// The exported file is read back by Escale's own HTML import, the same reader
// other browsers' files go through, so a round trip proves structure, order
// and escaping without a browser. Files go to a temporary folder only.
@Suite struct BookmarkExportTests {
    private func site(_ title: String, _ url: String, environments: [BookmarkEnvironment]? = nil) -> Bookmark {
        Bookmark(title: title, url: url, children: nil, environments: environments)
    }

    /// One line per node, indented by depth: folders end with a slash.
    private func outline(_ nodes: [Bookmark]) -> [String] {
        nodes.flatMap { node in
            [node.url.map { "\(node.title) <\($0)>" } ?? "\(node.title)/"] + outline(node.children ?? []).map { "  " + $0 }
        }
    }

    private func outline(_ nodes: [MigrationBookmark]) -> [String] {
        nodes.flatMap { node in
            [node.url.map { "\(node.title) <\($0.absoluteString)>" } ?? "\(node.title)/"] + outline(node.children).map { "  " + $0 }
        }
    }

    private func roundTrip(_ roots: [Bookmark]) throws -> (sent: Int, back: [MigrationBookmark]) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("escale-export-\(UUID()).html")
        defer { try? FileManager.default.removeItem(at: file) }
        let sent = try BookmarkExport.write(roots, to: file)
        return (sent, try MigrationExchange.html(String(contentsOf: file, encoding: .utf8)).bookmarks)
    }

    @Test func escapesTitlesAndAddresses() throws {
        let tricky = site(#"Tom & "Jerry" <b>'s</b> &amp;"#, "https://example.test/a?x=1&y='2'")
        let text = BookmarkExport.html([tricky]).text
        #expect(text.contains(#"HREF="https://example.test/a?x=1&amp;y=&#39;2&#39;""#))
        #expect(text.contains("Tom &amp; &quot;Jerry&quot; &lt;b&gt;&#39;s&lt;/b&gt; &amp;amp;</A>"))
        #expect(!text.contains("<b>"))
        #expect(try outline(roundTrip([tricky]).back) == outline([tricky]))
    }

    @Test func keepsEmptyAndNestedFoldersInOrder() throws {
        let roots: [Bookmark] = [
            site("First", "https://first.example.test/"),
            .folder("Outer", [
                site("Inner one", "https://one.example.test/path"),
                .folder("Empty", []),
                Bookmark(title: "No children", url: nil, children: nil),
                .folder("Deeper", [.folder("Deepest", [site("Leaf", "https://leaf.example.test/")])]),
                site("Inner two", "https://two.example.test/"),
            ]),
            .folder("", []),
            site("Last", "https://last.example.test/"),
        ]
        let (sent, back) = try roundTrip(roots)
        #expect(sent == 0)
        #expect(outline(back) == outline(roots))
        #expect(!BookmarkExport.html(roots).text.contains(BookmarkExport.environmentsFolder))
    }

    @Test func emptyListIsAValidEmptyFile() throws {
        let (sent, back) = try roundTrip([])
        #expect(sent == 0 && back.isEmpty)
    }

    @Test func environmentsFollowTheListInTheirOwnFolder() throws {
        let environments = [BookmarkEnvironment(name: "prod", url: "https://console.example.test/"),
                            BookmarkEnvironment(name: "dev", url: "http://localhost:8080/")]
        let console = site("Console", "https://console.example.test/", environments: environments)
        let roots: [Bookmark] = [.folder("Work", [console]), site("Plain", "https://plain.example.test/")]
        let (sent, back) = try roundTrip(roots)
        #expect(sent == 2)
        let carried: [Bookmark] = [.folder(BookmarkExport.environmentsFolder, [
            .folder("Console", [site("PROD", "https://console.example.test/"), site("DEV", "http://localhost:8080/")]),
        ])]
        // The list itself comes back unchanged, the environments after it.
        #expect(outline(back) == outline(roots + carried))
    }
}
