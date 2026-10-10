import Foundation
import AppKit

// What you have kept. Downloads work already; this is only the memory of them,
// so a file you fetched an hour ago is one click from the Finder rather than a
// hunt through a folder.

struct Keep: Codable, Identifiable, Equatable {
    var name: String
    var from: String
    var path: String
    var date: Date

    var id: String { path }

    var url: URL { URL(fileURLWithPath: path) }
    var stillThere: Bool { FileManager.default.fileExists(atPath: path) }
}

@MainActor
final class Loot: ObservableObject {
    @Published private(set) var kept: [Keep] = []
    private let file: URL

    init(space: UUID = Space.firstID) {
        file = Loot.file(for: space)
        load()
    }

    func add(_ keep: Keep) {
        kept.removeAll { $0.path == keep.path }
        kept.insert(keep, at: 0)
        // Fifty is more than anybody scrolls back through.
        if kept.count > 50 { kept.removeLast(kept.count - 50) }
        save()
    }

    func forget(_ keep: Keep) {
        kept.removeAll { $0.id == keep.id }
        save()
    }

    /// Only the list is emptied. Files you asked for are yours, and deleting
    /// them is the Finder's business, not a browser's.
    func forgetAll() {
        kept = []
        save()
    }

    func reveal(_ keep: Keep) {
        if Loot.scripted { Loot.handed.append("show \(keep.name)"); return }
        NSWorkspace.shared.activateFileViewerSelecting([keep.url])
    }

    func open(_ keep: Keep) {
        if Loot.scripted { Loot.handed.append("open \(keep.name)"); return }
        NSWorkspace.shared.open(keep.url)
    }

    /// What a scripted test world was asked to open or show in the Finder,
    /// in order. There no file goes to another app, on a desktop the script
    /// shares with the person at this Mac (see BenchKeys.swift).
    private(set) static var handed: [String] = []
    private static var scripted: Bool { Store.testing && Bench.shared.running }

    private static func file(for space: UUID) -> URL {
        Store.file(space == Space.firstID ? "downloads.json" : "downloads-\(space.uuidString).json")
    }

    static func erase(space: UUID) {
        guard space != Space.firstID else { return }
        Writer.to(file(for: space)).remove()
    }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder().decode([Keep].self, from: data)
        else { return }
        kept = list
    }

    /// Written in the order it changed, off the main thread (see Writer.swift).
    private func save() {
        Writer.to(file).save(kept)
    }
}
