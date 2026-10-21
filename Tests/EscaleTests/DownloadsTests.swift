// The active badge averages files, not bytes, and never assigns an exact
// global percentage to a set containing an indeterminate transfer. A file
// sent as an attachment is kept, whatever WebKit could show. A downloads
// list written before sizes and addresses still reads, and the new fields
// go to disk through the real writer. A retry trashes only the very half
// file that failed, never one put at its path since, and goes only through
// a tab of the failure's own Space and website store.
import Foundation
import Testing
import WebKit
@testable import Escale

@Suite struct DownloadsTests {
    @Test func onlyTheSameFileIsTheHalfThatFailed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("escale-partial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("half.bin")
        try Data("half".utf8).write(to: file)
        let partial = Downloads.identity(of: file)
        #expect(partial != nil)
        #expect(Downloads.same(file, as: partial))
        try Data("grown".utf8).write(to: file, options: [])
        #expect(Downloads.same(file, as: partial), "written in place, still the same file")

        // Another file renamed over the path, as a save does.
        try Data("someone else's".utf8).write(to: file, options: .atomic)
        #expect(!Downloads.same(file, as: partial))
        try FileManager.default.removeItem(at: file)
        #expect(!Downloads.same(file, as: partial))
        #expect(!Downloads.same(file, as: nil))
    }

    @MainActor @Test func aRetryGoesOnlyThroughItsOwnStore() {
        func tab(_ space: UUID, _ store: WKWebsiteDataStore, shy: Bool = false) -> Tab {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = store
            return Tab(shy: shy, space: space, configuration: configuration)
        }
        let space = UUID(), other = UUID()
        let shared = WKWebsiteDataStore.nonPersistent(), secret = WKWebsiteDataStore.nonPersistent()
        let ordinary = tab(space, shared), alsoOrdinary = tab(space, shared)
        let shy = tab(space, secret, shy: true), elsewhere = tab(other, secret, shy: true)
        let tabs = [ordinary, shy, elsewhere, alsoOrdinary]
        #expect(Downloads.sharing(shared, in: space, among: tabs).map(\.id) == [ordinary.id, alsoOrdinary.id])
        #expect(Downloads.sharing(secret, in: space, among: tabs).map(\.id) == [shy.id])
        #expect(Downloads.sharing(.nonPersistent(), in: space, among: tabs).isEmpty)
    }

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
