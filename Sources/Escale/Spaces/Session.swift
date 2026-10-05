// What was open last time: addresses, names and the selected entry, plus split
// membership and proportions. Groups refer to filtered entry indices so the
// file never needs live tab identities or any of the page's document state.
import Foundation

enum Session {
    struct Entry: Codable {
        var url: String
        var title: String
        var pin: String?
        /// The name you gave the tab, when you gave it one.
        var name: String?
        var bookmark: UUID? = nil
        /// Provenance for conservative browser imports, kept across restarts.
        var migration: UUID? = nil
    }

    struct Shape: Codable {
        var tabs: [Entry]
        var active: Int
        var panels: [SavedPanels]? = nil
    }

    struct SavedPanels: Codable {
        var members: [Int]
        var active: Int
        var horizontal: Bool
        var weights: [Double]
    }

    static func valid(_ shape: Shape) -> Bool {
        // Legacy rows keep their existing per-entry filtering and selection
        // clamping. Only an indexed composition requires the whole row to
        // preserve its positions, or a skipped address could retarget a pane.
        guard let groups = shape.panels, !groups.isEmpty else { return true }
        guard shape.tabs.allSatisfy({ URL(string: $0.url)?.scheme?.hasPrefix("http") == true }),
              shape.tabs.isEmpty ? shape.active == 0 : shape.tabs.indices.contains(shape.active) else { return false }
        var used = Set<Int>()
        for group in groups {
            guard (2...3).contains(group.members.count), group.members.contains(group.active),
                  group.weights.count == group.members.count,
                  group.weights.allSatisfy({ $0.isFinite && $0 > 0 }),
                  abs(group.weights.reduce(0, +) - 1) < 0.0001 else { return false }
            for member in group.members {
                guard shape.tabs.indices.contains(member), used.insert(member).inserted else { return false }
            }
        }
        return true
    }

    /// A row as it is saved: the entries of the tabs that are kept, in order
    /// (`nil` for one left out: private, the bench's, a bookmark's, no web
    /// address), and which of them was being looked at. The index counts
    /// only the kept, because it's all the file has: counted in the whole
    /// row, one left out before it made the next launch open the tab after
    /// the right one, or past the end. When the one looked at is itself
    /// left out, its nearest kept neighbour before it stands in — or, with
    /// none, the first after it — so the same row always comes back the
    /// same way. `active` is its place in the row, `nil` for none.
    static func shape(_ row: [Entry?], active: Int?) -> Shape {
        let tabs = row.compactMap { $0 }
        guard let active, row.indices.contains(active) else { return Shape(tabs: tabs, active: 0) }
        let before = row[..<active].filter { $0 != nil }.count
        return Shape(tabs: tabs, active: row[active] != nil ? before : max(before - 1, 0))
    }

    /// The first space's is the session there always was; each other space
    /// keeps its own beside it.
    private static func file(_ space: UUID) -> URL {
        Store.file(space == Space.firstID ? "session.json" : "session-\(space.uuidString).json")
    }

    /// In turn with its writes (see Writer.swift): a snapshot still waiting
    /// can't put a deleted space's session back.
    static func erase(space: UUID) {
        guard space != Space.firstID else { return }
        Writer.to(file(space)).remove()
    }

    /// A duplication writes only saved addresses and pin metadata, never a
    /// live page or its form state. The new file is visible only after flush.
    static func copy(_ shape: Shape, to space: UUID, bookmarks: [UUID: UUID] = [:]) -> Bool {
        guard space != Space.firstID else { return false }
        let writer = Writer.to(file(space))
        // Both files receive the same new identities for grouped bookmarks.
        // A missing bookmark never becomes a reference into another Space.
        var copy = shape
        for index in copy.tabs.indices {
            copy.tabs[index].bookmark = copy.tabs[index].bookmark.flatMap { bookmarks[$0] }
        }
        writer.save(copy)
        writer.flush()
        return writer.failure == nil
    }

    static func read(space: UUID = Space.firstID) -> Shape {
        let file = file(space)
        // What was last written, not what was on disk before it.
        Writer.to(file).flush()
        guard let data = try? Data(contentsOf: file) else { return Shape(tabs: [], active: 0) }
        guard let shape = try? JSONDecoder().decode(Shape.self, from: data), valid(shape) else {
            // A file that's there but won't decode is not the same as no
            // file: something wrote it, and overwriting it on the next save
            // without a trace is how yesterday's tabs actually disappear.
            Store.quarantine(file)
            return Shape(tabs: [], active: 0)
        }
        return shape
    }

    /// Used after adding imported addresses: acknowledge before publishing tabs.
    static func saved(space: UUID) -> Bool {
        let writer = Writer.to(file(space))
        writer.flush()
        return writer.failure == nil
    }

    /// Each space's file has one writer, which writes its snapshots in the
    /// order they were taken (see Writer.swift). `now` also waits for it,
    /// on the calling thread: quitting doesn't wait for a background queue,
    /// and a session handed to one on the way out is a session that may
    /// never reach the disk.
    static func write(now: Bool = false, space: UUID = Space.firstID, _ shape: Shape) {
        let writer = Writer.to(file(space))
        writer.save(shape)
        if now { writer.flush() }
    }
}
