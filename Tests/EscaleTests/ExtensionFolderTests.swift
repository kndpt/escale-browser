// Where Escale keeps its own files inside an extension's folder, and how the
// folder earlier builds named `_search` is carried over. Temporary folders
// only: no extension is loaded.
import Foundation
import Testing
@testable import Escale

@Suite struct ExtensionFolderTests {
    private func extensionFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("escale-extension-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func earlierFolderMovesAcrossWithItsFiles() throws {
        guard #available(macOS 15.4, *) else { return }
        let folder = try extensionFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let earlier = folder.appendingPathComponent("_search", isDirectory: true)
        try FileManager.default.createDirectory(at: earlier, withIntermediateDirectories: true)
        try Data("[{\"id\":\"kept\"}]".utf8).write(to: earlier.appendingPathComponent("userscripts.json"))

        let own = ExtensionShims.own(in: folder)

        #expect(own.lastPathComponent == "_escale")
        #expect(!FileManager.default.fileExists(atPath: earlier.path))
        #expect(try String(contentsOf: own.appendingPathComponent("userscripts.json"), encoding: .utf8) == "[{\"id\":\"kept\"}]")
    }

    @Test func existingFolderIsNeverReplacedByTheEarlierOne() throws {
        guard #available(macOS 15.4, *) else { return }
        let folder = try extensionFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let earlier = folder.appendingPathComponent("_search", isDirectory: true)
        let current = folder.appendingPathComponent("_escale", isDirectory: true)
        for (place, text) in [(earlier, "old"), (current, "new")] {
            try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: place.appendingPathComponent("userscripts.json"))
        }

        let own = ExtensionShims.own(in: folder)

        #expect(try String(contentsOf: own.appendingPathComponent("userscripts.json"), encoding: .utf8) == "new")
        #expect(FileManager.default.fileExists(atPath: earlier.appendingPathComponent("userscripts.json").path))
    }

    @Test func freshExtensionGetsTheFolderNameWithoutCreatingIt() throws {
        guard #available(macOS 15.4, *) else { return }
        let folder = try extensionFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let own = ExtensionShims.own(in: folder)

        #expect(own == folder.appendingPathComponent("_escale", isDirectory: true))
        #expect(!FileManager.default.fileExists(atPath: own.path))
    }
}
