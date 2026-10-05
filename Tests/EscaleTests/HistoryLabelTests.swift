// History labels hide query/fragment noise without changing the destination.
// Missing titles, WebKit's URL fallback and non-network pages stay readable.
import Foundation
import Testing
@testable import Escale

@Suite struct HistoryLabelTests {
    @Test func longQueryAndFragmentStayOutOfBothFallbackLabels() throws {
        let url = try #require(URL(string: "https://example.test:8443/docs/page?token=private#section"))
        for title in [nil, "", " \n ", url.absoluteString] {
            let label = HistoryLabel(title: title, url: url)
            #expect(label.title == "example.test:8443/docs/page")
            #expect(label.place == "example.test:8443/docs/page")
        }
        let label = HistoryLabel(title: "  A guide\n to WebKit  ", url: url)
        #expect(label.title == "A guide to WebKit")
        #expect(!label.place.contains("private"))
        #expect(url.query == "token=private")
    }

    @Test func longPathsStayWithinAMenuRow() throws {
        let url = try #require(URL(string: "https://example.test/" + String(repeating: "segment/", count: 100)))
        let label = HistoryLabel(title: nil, url: url)
        #expect(label.place.count == 80)
        #expect(label.title.count == 80)
        #expect(label.place.hasPrefix("example.test/segment/"))
    }

    @Test func nonNetworkFallbacksDoNotExposeDocumentContents() throws {
        let data = try #require(URL(string: "data:text/html,private-content"))
        #expect(HistoryLabel(title: nil, url: data).title == "Data document")
        let file = URL(fileURLWithPath: "/tmp/report.html")
        #expect(HistoryLabel(title: nil, url: file).title == "report.html")
    }
}
