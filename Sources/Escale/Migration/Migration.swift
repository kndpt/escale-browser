// One visible import owns its worker, cancellation and non-secret checkpoint.
// Reads run serially off the main thread; an explicit import starts mutations.
// Each category is acknowledged by its owner before the next begins. Restart
// rereads a user-selected source and replays add-only/max merges, including the
// crash window between a durable category and its checkpoint. No global atomic
// transaction or rollback is implied. Passwords leave memory on every exit.
import Foundation

struct MigrationReceipt: Codable {
    var destination: UUID
    var source: String
    var completed: [MigrationCategory] = []
    var addedBookmarks = 0
    var keptBookmarks = 0
    // Optional so receipts saved before history volumes still decode.
    var historyPlaces: Int?
    var addedTabs: Int?
    var keptTabs: Int?
    var passwordAdds = 0
    var passwordKeeps = 0
    var passwordFailures = 0
    var finished = false
}

@MainActor
final class Migration: ObservableObject {
    enum Phase: Equatable { case choosing, reading, preview, applying(MigrationCategory?), finished, stopped }
    @Published private(set) var phase: Phase = .choosing
    @Published private(set) var plan: MigrationPlan?
    @Published private(set) var bookmarkPreview: MigrationPlan.BookmarkMerge?
    private var originalBookmarks: [Bookmark] = []
    @Published private(set) var receipt: MigrationReceipt?
    @Published private(set) var message: String?
    @Published private(set) var completedPasswords = 0
    private let worker = DispatchQueue(label: "escale.migration", qos: .userInitiated)
    private let journal: URL
    private var cancellation = MigrationCancellation()
    private var pending: [MigrationCategory] = []
    private var target: Destination?

    /// These are the real data owners, resolved for the captured Space. Tests
    /// supply isolated files and a keychain seam without application singletons.
    struct Destination {
        let bookmarks: Bookmarks
        let history: History
        let exists: () -> Bool
        var password: (MigrationPassword, UUID) -> Vault.ImportResult = Vault.importPassword
        var tabs: (MigrationPlan) throws -> (added: Int, kept: Int) = { _ in throw MigrationFailure.unsupported }
    }

    init(journal: URL) { self.journal = journal }

    var busy: Bool {
        switch phase { case .reading, .applying: return true; default: return false }
    }

    /// Read only on opening the import flow, never during view evaluation.
    func restoreReceipt() {
        guard phase == .choosing else { return }
        let file = journal
        worker.async(execute: DispatchWorkItem {
            let saved = (try? MigrationLimits.data(file)).flatMap { try? JSONDecoder().decode(MigrationReceipt.self, from: $0) }
            DispatchQueue.main.async {
                guard self.phase == .choosing else { return }
                self.receipt = saved
            }
        })
    }

    func prepare(source: MigrationSource, destination: UUID, categories: Set<MigrationCategory>, keeping bookmarks: [Bookmark] = [], reader: any MigrationReader, ready: (() -> Void)? = nil) {
        guard !busy else { return }
        plan = nil; bookmarkPreview = nil; originalBookmarks = bookmarks
        receipt = nil; message = nil; completedPasswords = 0
        cancellation = MigrationCancellation()
        let token = cancellation
        phase = .reading
        worker.async(execute: DispatchWorkItem {
            let result = Result {
                let values = try reader.read(source, categories: categories, cancellation: token)
                try token.check()
                let plan = try MigrationPlan(source: source, destination: destination, categories: categories, values: values)
                return (plan, plan.bookmarks(keeping: bookmarks))
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let result):
                    do {
                        try token.check()
                        self.plan = result.0; self.bookmarkPreview = result.1; self.phase = .preview
                        // A row's Import already authorizes this category. Invoke
                        // after publishing the phase so confirm sees the new state.
                        try token.check()
                        ready?()
                    }
                    catch { self.stop(error) }
                case .failure(let error): self.stop(error)
                }
            }
        })
    }

    func confirm(destination: Destination) {
        guard phase == .preview, let plan else { return }
        guard destination.exists() else { stop(MigrationFailure.destinationGone); return }
        if plan.categories.contains(.bookmarks), destination.bookmarks.roots != originalBookmarks {
            stop(MigrationFailure.destinationChanged); return
        }
        target = destination
        receipt = MigrationReceipt(destination: plan.destination,
                                   source: MigrationLimits.identity(plan.source.id).uuidString)
        pending = MigrationCategory.allCases.filter { plan.categories.contains($0) }
        phase = .applying(nil)
        checkpoint { self.next() }
    }

    func cancel() {
        cancellation.cancel()
        if !busy { stop(MigrationFailure.cancelled) }
    }

    func reset() {
        guard !busy else { return }
        plan = nil; bookmarkPreview = nil; originalBookmarks = []; receipt = nil; target = nil; pending = []; message = nil; phase = .choosing
    }

    private func next() {
        do { try cancellation.check() } catch { stop(error); return }
        guard let plan, let target, target.exists() else { stop(MigrationFailure.destinationGone); return }
        guard !pending.isEmpty else {
            receipt?.finished = true
            checkpoint {
                self.plan = nil; self.bookmarkPreview = nil; self.originalBookmarks = []; self.target = nil; self.phase = .finished
            }
            return
        }
        let category = pending.removeFirst()
        phase = .applying(category)
        switch category {
        case .bookmarks:
            guard target.bookmarks.roots == originalBookmarks else { stop(MigrationFailure.destinationChanged); return }
            guard let merge = bookmarkPreview else { stop(MigrationFailure.malformed); return }
            target.bookmarks.importPlanned(merge.roots) { saved in
                DispatchQueue.main.async {
                    guard saved else { self.stop(MigrationFailure.storage); return }
                    self.receipt?.addedBookmarks = merge.added
                    self.receipt?.keptBookmarks = merge.kept
                    self.acquired(.bookmarks)
                }
            }
        case .history:
            target.history.importVisits(plan.values.history) { saved in
                DispatchQueue.main.async {
                    guard saved else { self.stop(MigrationFailure.storage); return }
                    self.receipt?.historyPlaces = target.history.count
                    self.acquired(.history)
                }
            }
        case .tabs:
            do {
                let result = try target.tabs(plan)
                receipt?.addedTabs = result.added; receipt?.keptTabs = result.kept
                acquired(.tabs)
            } catch { stop(error) }
        case .passwords: password(at: 0)
        }
    }

    private func password(at index: Int) {
        do { try cancellation.check() } catch { stop(error); return }
        guard let plan, let target, target.exists() else { stop(MigrationFailure.destinationGone); return }
        guard index < plan.values.passwords.count else {
            if (receipt?.passwordFailures ?? 0) > 0 {
                checkpoint { self.stop(MigrationFailure.keychain) }
            } else { acquired(.passwords) }
            return
        }
        let login = plan.values.passwords[index], space = plan.destination, write = target.password
        worker.async {
            let result = write(login, space)
            DispatchQueue.main.async {
                switch result {
                case .added: self.receipt?.passwordAdds += 1
                case .kept: self.receipt?.passwordKeeps += 1
                case .failed: self.receipt?.passwordFailures += 1
                }
                self.completedPasswords = index + 1
                self.password(at: index + 1)
            }
        }
    }

    private func acquired(_ category: MigrationCategory) {
        receipt?.completed.append(category)
        checkpoint { self.next() }
    }

    private func checkpoint(_ then: @escaping () -> Void) {
        guard let receipt else { stop(MigrationFailure.storage); return }
        let writer = Writer.to(journal)
        writer.save(receipt)
        writer.acknowledge { saved in
            DispatchQueue.main.async {
                if saved { then() } else { self.stop(MigrationFailure.storage) }
            }
        }
    }

    private func stop(_ error: Error) {
        // Never display underlying decoder/file errors: they can contain data
        // from a source, including CSV secrets. Only our fixed diagnostics leave.
        message = (error as? MigrationFailure ?? .unreadable).localizedDescription
        plan = nil; bookmarkPreview = nil; originalBookmarks = []; target = nil; pending = []; phase = .stopped
        if let receipt { Writer.to(journal).save(receipt) }

    }
}
