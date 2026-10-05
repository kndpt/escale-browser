import Foundation

// Files written in the order they changed.
//
// The session, the bookmarks, the history, the downloads list and the hidden
// elements each keep their state in memory and write the whole of it out as
// a JSON snapshot. Writing atomically keeps a reader from ever seeing half a
// file, but it says nothing about which of two snapshots lands last. Handed
// to a concurrent queue, an old one can: a 20,000-tab session queued in the
// background finished after a one-tab session written straight away, and the
// old tabs were what stayed on disk (WriterTests reproduces it).
//
// So each file has one writer, and each writer one serial queue. It keeps
// only the latest snapshot waiting: a burst of changes that arrives while a
// write is under way is written once, after it, as the state it ended in —
// a hundred edits during a slow write cost two writes, not a hundred and one.
// Removing the file is a change like any other, so a snapshot already
// waiting can't bring a deleted file back, and a later one can't be undone
// by an earlier removal.
//
// `flush` waits for what is under way and writes what is still waiting, on
// the caller's time: what quitting needs, since nothing finishes a
// background queue's work once the process has gone. A write that fails is
// logged, kept as `failure`, and kept waiting until something newer
// replaces it or the next flush tries it again: the state in memory is
// still the one that ought to be on disk. The first failure in a row is
// also said out loud (`trouble`), since a person whose changes stop saving
// is the one who can free the disk before quitting.

final class Writer {
    /// What the file should become.
    private enum Change {
        case save(() throws -> Data)
        case remove
    }

    let file: URL
    private let queue: DispatchQueue
    private let lock = NSLock()
    /// The latest change not yet written. Only ever one: a newer change
    /// replaces it rather than queueing behind it.
    private var waiting: Change?
    /// Whether a write is already on the queue to pick `waiting` up.
    private var queued = false
    private var failed: Error?

    /// Run on the writer's queue just before each change reaches the disk.
    /// Nil outside tests, which hold the writer here to slow it down and
    /// count its writes.
    var gate: (() -> Void)?

    /// Told, on the writer's queue, when a file that was saving fine fails:
    /// once per run of failures, not at every retry. The browser says so
    /// (see Browser.init); the file and the error are in the log.
    static var trouble: ((URL) -> Void)?

    /// Every file's writer, made the first time it is asked for: one per
    /// file, whoever asks, or two owners of one file would race again.
    private static var all: [String: Writer] = [:]
    private static let registry = NSLock()

    static func to(_ file: URL) -> Writer {
        let key = file.standardizedFileURL.path
        registry.lock()
        defer { registry.unlock() }
        if let made = all[key] { return made }
        let made = Writer(file: file)
        all[key] = made
        return made
    }

    /// Every file waiting to be written, written. For quitting (see Links).
    static func flushAll() {
        registry.lock()
        let writers = Array(all.values)
        registry.unlock()
        for writer in writers { writer.flush() }
    }

    private init(file: URL) {
        self.file = file
        queue = DispatchQueue(label: "escale.writer.\(file.lastPathComponent)", qos: .utility)
    }

    /// The last write that failed, or nil once one has gone through.
    var failure: Error? {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }

    /// A snapshot to write. It is encoded on the writer's queue, so pass a
    /// value, not something that goes on changing on the main thread.
    func save<Value: Encodable>(_ value: Value) {
        submit(.save { try JSONEncoder().encode(value) })
    }

    /// The file gone, after whatever was asked of it before.
    func remove() {
        submit(.remove)
    }

    /// Returns once everything asked of this writer so far is on disk, or
    /// has failed and been logged. Never from the writer's own queue.
    func flush() {
        queue.sync { drain() }
    }

    /// A durable boundary without making the main thread wait for file I/O.
    /// The callback runs on this writer's queue and never includes saved data.
    func acknowledge(_ done: @escaping (Bool) -> Void) {
        queue.async {
            self.drain()
            done(self.failure == nil)
        }
    }

    private func submit(_ change: Change) {
        lock.lock()
        waiting = change
        let schedule = !queued
        queued = true
        lock.unlock()
        if schedule { queue.async { self.drain() } }
    }

    /// On the queue: whatever is waiting, written.
    private func drain() {
        lock.lock()
        let change = waiting
        waiting = nil
        queued = false
        lock.unlock()
        guard let change else { return }
        gate?()
        do {
            try apply(change)
            lock.lock()
            failed = nil
            lock.unlock()
        } catch {
            NSLog("Escale: couldn't write %@: %@", file.path, String(describing: error))
            lock.lock()
            let first = failed == nil
            failed = error
            // Tried again at the next flush, unless something newer came in
            // meanwhile — that is the one to write now.
            if waiting == nil { waiting = change }
            lock.unlock()
            if first { Writer.trouble?(file) }
        }
    }

    private func apply(_ change: Change) throws {
        switch change {
        case .save(let encode):
            let data = try encode()
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: file, options: .atomic)
        case .remove:
            do {
                try FileManager.default.removeItem(at: file)
            } catch CocoaError.fileNoSuchFile {
                // Already gone is what was asked for.
            }
        }
    }
}
