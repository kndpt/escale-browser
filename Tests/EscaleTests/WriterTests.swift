import Foundation
import Testing
@testable import Escale

// The real Writer on temporary files. A write is slowed by holding it at the
// writer's gate, so the order of changes is set by the test, not by how long
// a big file takes; every wait has a deadline.

/// Holds the first write at the gate until released, and counts them all.
private final class Hold {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0

    var writes: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func gate() {
        lock.lock()
        calls += 1
        let first = calls == 1
        lock.unlock()
        guard first else { return }
        entered.signal()
        _ = released.wait(timeout: .now() + 10)
    }

    /// True once the first write is being held.
    func holding() -> Bool { entered.wait(timeout: .now() + 5) == .success }

    func release() { released.signal() }
}

/// Counts `Writer.trouble` calls for one file; other tests' files are not
/// this one's business.
private final class Told {
    private let file: URL
    private let lock = NSLock()
    private var calls = 0

    init(_ file: URL) { self.file = file }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func take(_ url: URL) {
        guard url == file else { return }
        lock.lock()
        calls += 1
        lock.unlock()
    }
}

/// A folder of the test's own, removed afterwards.
private func folder() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("escale-writer-\(UUID().uuidString)", isDirectory: true)
}

private func shape(_ urls: [String]) -> Session.Shape {
    Session.Shape(tabs: urls.map { Session.Entry(url: $0, title: $0) }, active: 0)
}

private func onDisk(_ file: URL) throws -> [String] {
    try JSONDecoder().decode(Session.Shape.self, from: Data(contentsOf: file)).tabs.map(\.url)
}

@Test func aBurstIsWrittenOnceAfterTheWriteUnderWay() throws {
    let root = folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("bookmarks.json")
    let writer = Writer.to(file)
    let hold = Hold()
    writer.gate = hold.gate

    writer.save(shape(["https://0.example.test"]))
    #expect(hold.holding())
    for n in 1...500 { writer.save(shape(["https://\(n).example.test"])) }
    hold.release()
    writer.flush()

    #expect(try onDisk(file) == ["https://500.example.test"])
    #expect(hold.writes == 2)
}

@Test func anOlderWriteUnderWayNeverLandsAfterAFlush() throws {
    let root = folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("session.json")
    let writer = Writer.to(file)
    let hold = Hold()
    writer.gate = hold.gate

    writer.save(shape(["https://old.example.test"]))
    #expect(hold.holding())
    writer.save(shape(["https://latest.example.test"]))

    // The case that lost tabs: an old session still being written when a newer one
    // is written `now`, as quitting does. The flush, from another thread
    // while the old write is held, must not return before both are done.
    let flushed = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        writer.flush()
        flushed.signal()
    }
    #expect(flushed.wait(timeout: .now() + 0.2) == .timedOut)
    hold.release()
    #expect(flushed.wait(timeout: .now() + 5) == .success)

    #expect(try onDisk(file) == ["https://latest.example.test"])
}

@Test func aRemovalIsNotUndoneByAWriteAlreadyWaiting() throws {
    let root = folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("session-space.json")
    let writer = Writer.to(file)
    let hold = Hold()
    writer.gate = hold.gate

    writer.save(shape(["https://old.example.test"]))
    #expect(hold.holding())
    writer.save(shape(["https://waiting.example.test"]))
    writer.remove()
    hold.release()
    writer.flush()

    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(writer.failure == nil)

    // And the other way round: a save after a removal is the file again.
    writer.remove()
    writer.save(shape(["https://again.example.test"]))
    writer.flush()
    #expect(try onDisk(file) == ["https://again.example.test"])
}

@Test func aFailedWriteIsReportedAndTriedAgainAtTheNextFlush() throws {
    let root = folder()
    defer { try? FileManager.default.removeItem(at: root) }
    // A file where the writer needs a folder: nothing can be written under it.
    let blocked = root.appendingPathComponent("blocked")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("not a folder".utf8).write(to: blocked)
    let file = blocked.appendingPathComponent("downloads.json")
    let writer = Writer.to(file)
    // Told once for the run of failures, however many retries it takes.
    let told = Told(file)
    Writer.trouble = told.take

    writer.save(shape(["https://kept.example.test"]))
    writer.flush()
    writer.flush()
    #expect(writer.failure != nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(told.count == 1)

    // The obstacle gone, the snapshot that failed is still the one written.
    try FileManager.default.removeItem(at: blocked)
    writer.flush()
    #expect(writer.failure == nil)
    #expect(try onDisk(file) == ["https://kept.example.test"])
}

@Test func oneFileHasOneWriter() {
    let root = folder()
    let file = root.appendingPathComponent("history.json")
    let roundabout = root.appendingPathComponent("sub/../history.json")
    #expect(Writer.to(file) === Writer.to(roundabout))
    #expect(Writer.to(file) !== Writer.to(root.appendingPathComponent("hidden.json")))
}
