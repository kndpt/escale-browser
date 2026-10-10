// The active badge averages files, not bytes, and never assigns an exact
// global percentage to a set containing an indeterminate transfer. A file
// sent as an attachment is kept, whatever WebKit could show.
import Foundation
import Testing
@testable import Escale

@Suite struct DownloadsTests {
    @Test func knownTransfersHaveEqualWeight() {
        #expect(Downloads.fraction([0.25]) == 0.25)
        #expect(Downloads.fraction([0.25, 0.75]) == 0.5)
        #expect(Downloads.fraction([0, 0.5, 1]) == 0.5)
        #expect(Downloads.fraction([-1, 2]) == 0.5)
    }
    @Test func unknownAndEmptyHaveNoPercentage() {
        #expect(Downloads.fraction([]) == nil)
        #expect(Downloads.fraction([nil]) == nil)
        #expect(Downloads.fraction([0.5, nil]) == nil)
        #expect(Downloads.fraction([.nan]) == nil)
        #expect(Downloads.fraction([.infinity]) == nil)
    }
    @Test func attachmentIsKeptWhateverItsType() {
        func response(_ disposition: String?) -> URLResponse {
            let url = URL(fileURLWithPath: "/") // only the headers matter
            let headers = disposition.map { ["Content-Disposition": $0] } ?? [:]
            return HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers) ?? URLResponse()
        }
        #expect(Downloads.isAttachment(response("attachment;filename=\"Toc Toc.wav\"")))
        #expect(Downloads.isAttachment(response("Attachment")))
        #expect(Downloads.isAttachment(response(" attachment ; filename=a.pdf")))
        #expect(!Downloads.isAttachment(response(nil)))
        #expect(!Downloads.isAttachment(response("inline")))
        #expect(!Downloads.isAttachment(response("inline; filename=attachment.pdf")))
        #expect(!Downloads.isAttachment(response("attachments")))
        #expect(!Downloads.isAttachment(response("")))
        #expect(!Downloads.isAttachment(URLResponse()))
    }
}
