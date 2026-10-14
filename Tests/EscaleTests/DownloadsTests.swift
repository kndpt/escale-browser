// The active badge averages files, not bytes, and never assigns an exact
// global percentage to a set containing an indeterminate transfer. A file
// sent as an attachment is kept, whatever WebKit could show. A downloads
// list written before sizes and addresses still reads, and the new fields
// go to disk through the real writer.
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
    @Test func anOldListReadsAndTheNewFieldsAreSaved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("escale-downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("downloads.json")
        try Data(#"[{"name":"a.pdf","from":"example.test","path":"/tmp/a.pdf","date":0}]"#.utf8).write(to: file)

        let old = try JSONDecoder().decode([Keep].self, from: Data(contentsOf: file))
        #expect(old.map(\.name) == ["a.pdf"])
        #expect(old[0].size == nil && old[0].address == nil)

        let new = Keep(name: "b.zip", from: "example.test", path: "/tmp/b.zip", date: Date(timeIntervalSinceReferenceDate: 0),
                       size: 917_504, address: "https://example.test/files/b.zip?v=2")
        let writer = Writer.to(file)
        writer.save([new] + old)
        writer.flush()
        #expect(try JSONDecoder().decode([Keep].self, from: Data(contentsOf: file)) == [new] + old)
    }
}
