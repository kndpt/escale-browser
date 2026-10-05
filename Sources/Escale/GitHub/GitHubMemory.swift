// One Space owns its derived observations. Search owns the local destinations;
// this cache cannot bring back a forgotten link. History admits at most 2,000
// identities, a visible surface another six, and only historical observations
// reach disk. Private contexts have no file and refuse API admission entirely.
//
// Tickets capture this owner's lifetime, authorization and latest request for
// an item. Cancelling also notifies the transport, but even an uncancellable
// late reply must pass the ticket check. There is no timer or automatic network
// work. The coordinator calls the explicit lifecycle methods below.
//
// Until `restore` has read the file, memory holds only part of the cache, so
// nothing writes it: an authorization arriving first, an early observation or
// pressure relief would otherwise replace the whole snapshot with that part.
// Forgetting while unloaded drops the file instead; the cache is expendable.

import Combine
import Foundation

@MainActor
final class GitHubMemory: ObservableObject {
    struct Ticket: Hashable {
        let item: GitHubItem.ID
        fileprivate let owner: UUID
        fileprivate let request: UUID
        fileprivate let authority: GitHubAuthority?
        fileprivate let api: Bool
    }

    static let room = 2_000
    static let visibleRoom = 6
    static let bytes = 4 * 1_024 * 1_024

    let space: UUID
    let isPrivate: Bool
    private let file: URL?
    private let lifetime = UUID()
    private var ended = false
    private var restoring = false
    /// Forgotten during a read, so the snapshot cannot bring them back.
    private var dropped = Set<GitHubItem.ID>()
    private var droppedAll = false
    private(set) var loaded: Bool
    private var authority: GitHubAuthority?
    private var historical = Set<GitHubItem.ID>()
    private var visible = Set<GitHubItem.ID>()
    private var pending: [GitHubItem.ID: Ticket] = [:]
    @Published private var readings: [GitHubItem.ID: GitHubReading] = [:]
    private(set) var loadRejected = false
    /// The HTTP/page owner cancels only the work represented by this ticket.
    var cancelled: ((Ticket) -> Void)?

    static func file(for space: UUID) -> URL { Store.file("github-\(space.uuidString).json") }

    /// A supplied path is a test seam. Private contexts ignore it unconditionally.
    init(space: UUID, isPrivate: Bool = false, authority: GitHubAuthority? = nil, file: URL? = nil) {
        self.space = space
        self.isPrivate = isPrivate
        self.authority = !isPrivate && authority?.account.valid == true ? authority : nil
        self.file = isPrivate ? nil : (file ?? Self.file(for: space))
        loaded = self.file == nil
    }

    var count: Int { readings.count }
    var pendingCount: Int { pending.count }
    var persistentCount: Int { readings.keys.filter { historical.contains($0) }.count }

    func reading(_ item: GitHubItem.ID) -> GitHubReading {
        readings[item] ?? GitHubReading(observation: nil, failure: nil)
    }

    /// Inputs are the current local snapshot, before display truncation for history.
    /// Visible order is retained by the caller; status updates never sort that array.
    func reconcile(history: [GitHubItem.ID], visible: [GitHubItem.ID]) {
        guard !ended else { return }
        let wasHistorical = historical
        historical = isPrivate ? [] : admitted(history, limit: Self.room)
        self.visible = admitted(visible, limit: Self.visibleRoom)
        for ticket in Array(pending.values) where !eligible(ticket.item) || (ticket.api && !self.visible.contains(ticket.item)) { cancel(ticket) }
        let kept = readings.filter { eligible($0.key) }
        let changed = kept != readings
        if changed { readings = kept }
        if changed || (wasHistorical != historical && !readings.isEmpty) { save() }
    }

    private func admitted(_ items: [GitHubItem.ID], limit: Int) -> Set<GitHubItem.ID> {
        var result = Set<GitHubItem.ID>()
        for item in items where item.space == space && item.valid {
            if result.count == limit { break }
            result.insert(item)
        }
        return result
    }

    private func eligible(_ item: GitHubItem.ID) -> Bool {
        !ended && item.space == space && (historical.contains(item) || visible.contains(item))
    }

    /// A request must be local, eligible and within the six-object work bound.
    func request(_ item: GitHubItem.ID, api: Bool) -> Ticket? {
        guard eligible(item), !api || (!isPrivate && authority != nil && visible.contains(item)),
              pending[item] != nil || pending.count < Self.visibleRoom else { return nil }
        if let old = pending[item] { cancel(old) }
        let ticket = Ticket(item: item, owner: lifetime, request: UUID(), authority: authority, api: api)
        pending[item] = ticket
        return ticket
    }

    func cancel(_ ticket: Ticket) {
        guard pending[ticket.item] == ticket else { return }
        pending[ticket.item] = nil
        cancelled?(ticket)
    }

    /// Closing the surface cancels its outstanding work without erasing good observations.
    func cancel() {
        for ticket in Array(pending.values) { cancel(ticket) }
    }

    /// The timestamp is when the source was successfully observed, never a navigation date.
    @discardableResult
    func receive(_ state: GitHubState, at date: Date, for ticket: Ticket) -> Bool {
        guard accepts(ticket) else { return false }
        // A reply ends its ticket even when it cannot be kept: an unusable one
        // must not hold one of the six work slots until the next reconcile.
        pending[ticket.item] = nil
        let source: GitHubObservation.Source
        if ticket.api {
            guard let authority = ticket.authority else { return false }
            source = .api(authority)
        } else { source = .page }
        let observation = GitHubObservation(state: state, source: source, observedAt: date)
        guard observation.valid(for: ticket.item) else { return false }
        if let old = readings[ticket.item]?.observation {
            guard observation.observedAt >= old.observedAt else { return false }
            if observation.observedAt == old.observedAt, case .api = old.source, !ticket.api { return false }
        }
        readings[ticket.item] = GitHubReading(observation: observation, failure: nil)
        save()
        return true
    }

    /// A refusal drops what the API said but keeps what a page showed: GitHub
    /// hides an unshared private repository from the app, not from the person.
    @discardableResult
    func fail(_ failure: GitHubFailure, for ticket: Ticket, at date: Date = Date()) -> Bool {
        guard accepts(ticket) else { return false }
        pending[ticket.item] = nil
        if failure == .cancelled { return true }
        var old = readings[ticket.item]?.observation
        if failure.invalidatesObservation, !(failure.refused && old?.source == .page) { old = nil }
        readings[ticket.item] = GitHubReading(observation: old, failure: failure, failedAt: date)
        save()
        return true
    }

    /// Sharing on GitHub may have changed: refused rows are asked again on their next showing.
    func retryRefused() {
        guard !ended else { return }
        var next = readings
        for (item, reading) in readings where reading.failure?.refused == true {
            next[item] = GitHubReading(observation: reading.observation, failure: nil)
        }
        if next != readings { readings = next }
    }

    func isCurrent(_ ticket: Ticket) -> Bool { accepts(ticket) }

    private func accepts(_ ticket: Ticket) -> Bool {
        eligible(ticket.item) && ticket.owner == lifetime && pending[ticket.item] == ticket
            && ticket.authority == authority && (!ticket.api || (!isPrivate && authority != nil && visible.contains(ticket.item)))
    }

    /// Account change and disconnect purge private enrichment, including page observations.
    /// Before the read, the snapshot's own authorization decides what comes back.
    func authorize(_ next: GitHubAuthority?) {
        guard !ended, !isPrivate, next?.account.valid != false, next != authority else { return }
        cancel()
        authority = next
        readings = [:]
        save()
    }

    /// Forget one whole object, whatever subpage the history removed; nil clears all.
    /// Kept open tabs remain local results but get no observation from this cache.
    func forget(_ item: GitHubItem.ID? = nil) {
        guard !ended else { return }
        if let item {
            if let ticket = pending[item] { cancel(ticket) }
            historical.remove(item)
            readings[item] = nil
            if restoring { dropped.insert(item) }
        } else {
            cancel()
            historical = []
            readings = [:]
            if restoring { droppedAll = true }
        }
        if loaded { save() } else if !restoring, let file { Writer.to(file).remove() }
    }

    /// The cache is expendable under pressure; local result values stay with their owner.
    /// The file stays: the next `restore` reads it again.
    func relieve() {
        guard !ended, !restoring else { return }
        cancel()
        readings = [:]
        loaded = file == nil
    }

    /// Terminal for Space deletion or the end of a private context.
    func erase() {
        guard !ended else { return }
        cancel()
        ended = true
        authority = nil
        historical = []
        visible = []
        readings = [:]
        if let file { Writer.to(file).remove() }
    }

    /// Restore is explicit, after the local snapshot and current authorization are known.
    /// I/O and validation run off the main thread. What changed meanwhile wins:
    /// newer observations stay, and forgotten objects or another authorization
    /// keep the snapshot out. `done` is false for a rejected or abandoned read.
    func restore(done: @escaping (Bool) -> Void) {
        guard !ended, !restoring else { done(false); return }
        guard let file, !loaded else { done(true); return }
        restoring = true
        dropped = []
        droppedAll = false
        GitHubDisk.read(file, space: space) { [weak self] snapshot in
            guard let self else { done(false); return }
            self.restoring = false
            guard !self.ended else { done(false); return }
            self.loaded = true
            self.loadRejected = snapshot == nil
            // A snapshot from another account, generation or a signed-out run brings
            // back nothing, page observations included.
            if let snapshot, snapshot.authority == self.authority, !self.droppedAll {
                var restored = self.readings
                for entry in snapshot.entries where self.historical.contains(entry.item)
                    && !self.dropped.contains(entry.item) && restored[entry.item] == nil {
                    if case .api(let authority) = entry.observation.source, authority != self.authority { continue }
                    restored[entry.item] = GitHubReading(observation: entry.observation, failure: nil)
                }
                self.readings = restored
            }
            self.dropped = []
            self.droppedAll = false
            self.save()
            done(snapshot != nil)
        }
    }

    private func save() {
        guard let file, !ended, loaded else { return }
        let entries = readings.compactMap { item, reading -> GitHubDisk.Entry? in
            guard historical.contains(item), let observation = reading.observation else { return nil }
            return GitHubDisk.Entry(item: item, observation: observation)
        }
        // An empty, never-activated cache needs no new file.
        if entries.isEmpty { Writer.to(file).remove() }
        else { Writer.to(file).save(GitHubDisk.Snapshot(entries: entries, authority: authority)) }
    }

    /// The ordinary ordered Writer handles both saves and terminal removal.
    func flush() {
        if let file { Writer.to(file).flush() }
    }
}
