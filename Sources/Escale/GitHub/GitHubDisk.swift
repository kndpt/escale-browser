// Cache files contain successful observations only, never titles, destinations
// or tokens. A bounded read precedes decoding, and semantic validation rejects
// the whole snapshot before it reaches the Space. The existing Writer provides
// coalesced, ordered, atomic writes; disk work is never part of row rendering.

import Foundation

enum GitHubDisk {
    struct Entry: Codable {
        let item: GitHubItem.ID
        let observation: GitHubObservation
    }

    struct Snapshot: Codable {
        var version = 1
        let entries: [Entry]
        /// Every reading in memory shares the authorization it was written under,
        /// because a change purges them all. Page observations carry no account
        /// of their own, so restore matches this value instead.
        var authority: GitHubAuthority? = nil
    }

    @MainActor
    static func read(_ file: URL, space: UUID, done: @escaping (Snapshot?) -> Void) {
        // Capture static bounds here; the worker does not reach through a main-thread owner.
        let bytes = GitHubMemory.bytes
        let room = GitHubMemory.room
        // Read and quarantine on the same serial lane as writes. A corrupt older
        // read must never move aside a newer snapshot written in the meantime.
        Writer.to(file).acknowledge { _ in
            let snapshot: Snapshot?
            do {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: bytes + 1) ?? Data()
                guard data.count <= bytes else { throw Invalid.file }
                let decoded = try JSONDecoder().decode(Snapshot.self, from: data)
                guard decoded.version == 1, decoded.entries.count <= room, decoded.authority?.account.valid != false,
                      Set(decoded.entries.map(\.item)).count == decoded.entries.count,
                      decoded.entries.allSatisfy({ $0.item.space == space && $0.item.valid && $0.observation.valid(for: $0.item) })
                else { throw Invalid.file }
                snapshot = decoded
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                snapshot = Snapshot(entries: [])
            } catch {
                Store.quarantine(file)
                snapshot = nil
            }
            DispatchQueue.main.async { done(snapshot) }
        }
    }

    private enum Invalid: Error { case file }
}
