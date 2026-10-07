import Foundation
import Testing
@testable import Escale

// A malformed list must survive a later save, so it can be recovered by hand,
// and a saved order comes back as it was, the first Space included.
// This uses only synthetic files in a fresh temporary folder.

@Suite struct SpacesReadTests {
    @Test func aMalformedListIsKeptBeforeTheNextSave() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("escale-spaces-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("spaces.json")
        let malformed = Data("[{bad spaces data]".utf8)
        try malformed.write(to: file)

        let fallback = Spaces.read(from: file)
        #expect(fallback.map(\.id) == [Space.firstID])

        let saved = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("spaces.unreadable-") }
        #expect(saved.count == 1)
        #expect(try saved.first.map { try Data(contentsOf: $0) } == malformed)

        // A later space edit writes a valid list at the original address.
        try JSONEncoder().encode(fallback).write(to: file, options: .atomic)
        #expect(try saved.first.map { try Data(contentsOf: $0) } == malformed)
    }

    @Test func aMovedFirstSpaceKeepsItsPlace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("escale-spaces-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("spaces.json")
        let work = Space(id: UUID(), name: "Work", colour: 0)
        let first = Space(id: Space.firstID, name: "Personal", colour: 0)
        try JSONEncoder().encode([work, first]).write(to: file)
        #expect(Spaces.read(from: file).map(\.id) == [work.id, Space.firstID])

        // A list without the first Space still gets it, in front.
        try JSONEncoder().encode([work]).write(to: file)
        #expect(Spaces.read(from: file).map(\.id) == [Space.firstID, work.id])
    }
}
