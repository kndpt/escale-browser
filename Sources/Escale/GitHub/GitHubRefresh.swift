// A visible batch enriches existing local rows in place. It never discovers
// repositories or transmits search words. Six items, one request at a time,
// a short cancellable debounce and no idle timer bound the work. Conditional
// validators belong to this surface/account and disappear when it closes.

import Combine
import Foundation

@MainActor
final class GitHubRefresh: ObservableObject {
    @Published private(set) var retryAt: Date?
    @Published private(set) var failure: GitHubFailure?
    private let memory: GitHubMemory
    private let access: GitHubAccess
    private let http: GitHubHTTP
    private let now: () -> Date
    private let pause: (TimeInterval) async throws -> Void
    private var batch: Task<Void, Never>?
    private var active: (ticket: GitHubMemory.Ticket, task: Task<Void, Never>)?
    private var visible: [GitHubItem.ID] = []
    private var tickets: [GitHubMemory.Ticket] = []
    private var validators: [GitHubItem.ID: String] = [:]
    private var attempted: [GitHubItem.ID: Date] = [:]
    private var epoch = UUID()
    private var authority: GitHubAuthority?
    private var connection: AnyCancellable?

    init(memory: GitHubMemory, access: GitHubAccess, http: GitHubHTTP = GitHubHTTP(),
         now: @escaping () -> Date = Date.init,
         pause: @escaping (TimeInterval) async throws -> Void = { seconds in
             try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         }) {
        self.memory = memory
        self.access = access
        self.http = http
        self.now = now
        self.pause = pause
        self.authority = access.authority
        memory.authorize(access.authority)
        memory.cancelled = { [weak self] ticket in
            if self?.active?.ticket == ticket { self?.active?.task.cancel() }
        }
        connection = access.$connection.sink { [weak self] state in
            guard let self else { return }
            if case .connected = state, self.authority == access.authority { return }
            self.stop(cancelAccess: false)
            self.authority = access.authority
            memory.authorize(access.authority)
            self.retryAt = nil
        }
    }

    /// Call after local search, passing the full history identity snapshot and
    /// only the rows actually visible. The caller retains row order and selection.
    func update(history: [GitHubItem.ID], visible items: [GitHubItem.ID], manual: Bool = false) {
        var seen = Set<GitHubItem.ID>()
        var next: [GitHubItem.ID] = []
        for item in items where item.space == memory.space && item.valid && seen.insert(item).inserted {
            next.append(item)
            if next.count == GitHubMemory.visibleRoom { break }
        }
        memory.reconcile(history: history, visible: next)
        // Signed out: nothing to refresh, but an authorization under way in
        // Settings is not this surface's to cancel.
        guard !memory.isPrivate, access.space == memory.space, access.authority != nil else { stop(cancelAccess: false); return }
        guard manual || next != visible || batch == nil else { return }
        stopWork()
        visible = next
        validators = validators.filter { next.contains($0.key) }
        attempted = attempted.filter { next.contains($0.key) }
        if let retryAt, retryAt > now() { failure = .rateLimited; return }
        let captured = epoch
        batch = Task {
            do { try await self.pause(0.25) } catch { return }
            guard captured == self.epoch, !Task.isCancelled else { return }
            // Capture every ticket before the first suspension. An intervening
            // history purge must invalidate queued items as well as the active one.
            self.tickets = next.compactMap { item in
                let reading = self.memory.reading(item)
                if !manual {
                    if reading.current(at: self.now()) != nil || reading.refused(at: self.now()) { return nil }
                    if let attempted = self.attempted[item], self.now().timeIntervalSince(attempted) < 30 { return nil }
                }
                return self.memory.request(item, api: true)
            }
            for ticket in self.tickets {
                guard captured == self.epoch, !Task.isCancelled else { return }
                if let retryAt = self.retryAt, retryAt > self.now() { break }
                guard self.memory.isCurrent(ticket) else { continue }
                let item = ticket.item
                let job = Task { await self.fetch(item, ticket: ticket, epoch: captured) }
                self.active = (ticket, job)
                await job.value
                if self.active?.ticket == ticket { self.active = nil }
            }
            if captured == self.epoch {
                for ticket in self.tickets { self.memory.cancel(ticket) }
                self.tickets = []
                self.batch = nil
            }
        }
    }

    /// Dismissal, disable, Space change or quit leaves no background work.
    func stop(cancelAccess: Bool = true) {
        stopWork()
        if cancelAccess { access.cancel() }
        visible = []
        validators = [:]
        attempted = [:]
        failure = nil
    }

    private func stopWork() {
        epoch = UUID()
        batch?.cancel()
        batch = nil
        active?.task.cancel()
        for ticket in tickets { memory.cancel(ticket) }
        tickets = []
        active = nil
    }

    private func fetch(_ item: GitHubItem.ID, ticket: GitHubMemory.Ticket, epoch captured: UUID) async {
        attempted[item] = now()
        do {
            let token = try await access.token()
            try Task.checkCancellation()
            guard captured == epoch, access.authority == authority else { throw CancellationError() }
            let path = "/repos/\(item.owner)/\(item.repository)/\(item.kind == .pull ? "pulls" : "issues")/\(item.number)"
            // A validator is useful only with its retained successful API observation.
            let old = memory.reading(item).observation
            let conditional: String?
            if let old, case .api(let source) = old.source, source == authority { conditional = validators[item] }
            else { conditional = nil }
            let reply = try await http.exchange(GitHubHTTP.request(path: path, token: token.access, etag: conditional))
            try Task.checkCancellation()
            guard captured == epoch, access.authority == authority else { throw CancellationError() }
            if let date = reply.retryDate(at: now()) { retryAt = date }
            if let error = reply.failure(at: now()) { throw error }
            let state: GitHubState
            if reply.status == 304 {
                guard conditional != nil, let old else { throw GitHubFailure.invalidResponse }
                state = old.state
            } else {
                guard reply.status == 200 else { throw GitHubFailure.invalidResponse }
                state = try Self.state(reply.data, for: item)
            }
            if memory.receive(state, at: now(), for: ticket) {
                failure = nil
                if reply.status != 304 {
                    let etag = reply.header("etag")
                    validators[item] = etag.flatMap { $0.utf8.count <= 512 ? $0 : nil }
                }
            }
        } catch {
            guard captured == epoch else { return }
            let reason = GitHubAccess.failure(error)
            if let date = access.retryAt, date > now() { retryAt = max(retryAt ?? date, date) }
            memory.fail(reason, for: ticket, at: now())
            if reason != .cancelled { failure = reason }
            if reason.invalidatesObservation { validators[item] = nil }
            if reason == .unauthorized {
                await access.disconnect(reason: .unauthorized)
            }
        }
    }

    static func state(_ data: Data, for item: GitHubItem.ID) throws -> GitHubState {
        struct Payload: Decodable {
            let number: Int
            let state: String
            let draft: Bool?
            let merged: Bool?
            let pullRequest: Pointer?
            struct Pointer: Decodable { let url: String? }
        }
        let value = try GitHubAccess.decode(Payload.self, data)
        guard value.number == item.number else { throw GitHubFailure.invalidResponse }
        if item.kind == .issue {
            guard value.pullRequest == nil else { throw GitHubFailure.invalidResponse }
            switch value.state {
            case "open": return .open
            case "closed": return .closed
            default: throw GitHubFailure.invalidResponse
            }
        }
        guard let merged = value.merged, let draft = value.draft else { throw GitHubFailure.invalidResponse }
        if merged { guard value.state == "closed" else { throw GitHubFailure.invalidResponse }; return .merged }
        switch value.state {
        case "open": return draft ? .draft : .open
        case "closed": return .closed
        default: throw GitHubFailure.invalidResponse
        }
    }
}
