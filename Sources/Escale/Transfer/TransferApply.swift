// Bringing a transfer file in. The file has already been opened and checked
// (`TransferPayload.checked`) and nothing here reads anything from it that was
// not validated. Every Space in the file is added as a new Space with a new
// identity, never merged by name and never over an existing one: its files are
// written and flushed first, the Space list is written next, and only then is
// the Space published, the way a duplicated Space is (SpaceCopy.swift). A
// Space that fails is erased again and reported; the others stand, because
// nothing spans files and the keychain, so only what was acknowledged is
// claimed. Passwords come last, add-only, into the Space that is already
// there. Every new identity derives from the file's own transfer id and the
// old identity, so the same file opened again finds its Spaces instead of
// making more, and a password that was refused the first time is retried.
//
// One exception: an Escale with nothing of its own yet (`isPristine`) takes the
// file's first Space in its first Space. That one can't be deleted, as it owns
// the locations from before Spaces, so beside the import it would stay empty
// for good. The identity it stands for is kept in the settings, which an
// older Escale rewriting the Space list leaves alone, so the same file opened
// again finds it there.
//
// Each new Space gets a WebKit store of its own on first use: no cookie,
// sign-in or site data of the source travels, and none is shared.
import Foundation

struct TransferReport: Equatable {
    var imported: [String] = []
    var already: [String] = []
    var failed: [String] = []
    var passwordsAdded = 0
    var passwordsKept = 0
    var passwordsFailed = 0
    var preferences = 0
    var linkRules = 0
    var notes: [String] = []
    var stopped = false

    var changed: Bool { !imported.isEmpty || passwordsAdded > 0 || preferences > 0 || linkRules > 0 }
}

enum TransferApply {
    /// Test worlds only: names of steps that fail as a full disk would
    /// ("files", "spaces", "keychain"), so the failure paths are exercised for real,
    /// and "slow", which waits between Spaces so a stop can land between two.
    static var failing: Set<String> = []

    static func identity(_ transfer: UUID, _ old: UUID) -> UUID {
        MigrationLimits.identity("escale-transfer", transfer.uuidString, old.uuidString)
    }

    static func fails(_ step: String) -> Bool { Store.testing && failing.contains(step) }

    /// The identity of the file's Space that filled the first Space.
    private static let filledKey = "transfer.first"

    /// Kept once the first Space took the file's Space with this identity.
    static func fill(_ identity: UUID, settings: UserDefaults = Store.settings) {
        settings.set(identity.uuidString, forKey: filledKey)
    }

    /// Where a Space of the file goes, and whether an earlier opening already
    /// put it there: the first Space once it was filled with this one, or
    /// now when this Escale is pristine and it is the file's first; its own
    /// identity otherwise.
    static func target(_ identity: UUID, index: Int, pristine: Bool, here: [UUID],
                       settings: UserDefaults = Store.settings) -> (id: UUID, already: Bool) {
        let home = settings.string(forKey: filledKey) == identity.uuidString ? Space.firstID : identity
        if here.contains(home) { return (home, true) }
        return (pristine && index == 0 ? Space.firstID : home, false)
    }

    /// What an imported Space is to reinstall: its own list and the source's
    /// shared set, once each, less what already runs in every Space here.
    static func plan(_ own: [PlannedExtension], shared: [PlannedExtension], running: [Installed]) -> [PlannedExtension] {
        var planned: [PlannedExtension] = []
        for item in own + shared where !planned.contains(item) && !running.contains(where: item.names) {
            planned.append(item)
        }
        return planned
    }
}

extension Browser {
    /// Whether this Escale holds nothing of its own yet: one Space, empty, and
    /// no portable preference ever set. A settings change alone is its owner's.
    var isPristine: Bool {
        guard spaces.count == 1, let only = spaces.first, only.isFirst, !TransferPreferences.touched() else { return false }
        return Session.read(space: only.id).tabs.isEmpty && bookmarks(of: only.id).isEmpty
            && History.saved(space: only.id).isEmpty && Vault.all(space: only.id).isEmpty
    }

    func applyTransfer(_ payload: TransferPayload, preferences: Bool, progress: @escaping (String) -> Void) async -> TransferReport {
        var report = TransferReport()
        var arrived: [UUID: UUID] = [:]
        let pristine = isPristine
        for (index, space) in payload.spaces.enumerated() {
            if TransferApply.fails("slow") { try? await Task.sleep(nanoseconds: 800_000_000) }
            if Task.isCancelled { report.stopped = true; break }
            progress("Saving “\(space.name)” (\(index + 1) of \(payload.spaces.count))…")
            let (id, already) = TransferApply.target(TransferApply.identity(payload.id, space.id), index: index,
                                                     pristine: pristine, here: spaces.map(\.id))
            if already {
                report.already.append(space.name)
            } else if place(space, as: id, from: payload.id, shared: payload.sharedExtensions ?? []) {
                report.imported.append(space.name)
            } else {
                report.failed.append(space.name)
                continue
            }
            arrived[space.id] = id
            if let logins = space.logins, !logins.isEmpty {
                progress("Adding passwords to “\(space.name)”…")
                let refused = TransferApply.fails("keychain")
                let added = await Task.detached(priority: .userInitiated) { () -> (Int, Int, Int) in
                    var counts = (0, 0, 0)
                    if refused { return (0, 0, logins.count) }
                    for login in logins {
                        switch Vault.importPassword(MigrationPassword(host: login.host, user: login.user, password: login.password), space: id) {
                        case .added: counts.0 += 1
                        case .kept: counts.1 += 1
                        case .failed: counts.2 += 1
                        }
                    }
                    return counts
                }.value
                report.passwordsAdded += added.0; report.passwordsKept += added.1; report.passwordsFailed += added.2
            }
            await Task.yield()
        }

        // Link rules follow the Spaces that arrived; a rule already made by an
        // earlier opening of this file is not made twice.
        let present = Set(linkRoutes.rules.map(\.id))
        var additions: [LinkRule] = []
        for rule in payload.linkRules {
            guard let destination = arrived[rule.destination] else { continue }
            var made = rule
            made.id = TransferApply.identity(payload.id, rule.id)
            made.destination = destination
            if !present.contains(made.id) { additions.append(made) }
        }
        if !additions.isEmpty {
            if linkRoutes.rules.count + additions.count > LinkRule.limit {
                report.notes.append("Link rules weren't added: Escale keeps at most \(LinkRule.limit).")
            } else if linkRoutes.save(linkRoutes.rules + additions, spaces: Set(spaces.map(\.id))) {
                report.linkRules = additions.count
            }
        }
        if preferences && !report.stopped {
            report.preferences = TransferPreferences.apply(payload.preferences, to: prefs)
        }
        // The first Space shows with Spaces off: only the others are hidden.
        if !self.prefs.usesSpaces && arrived.values.contains(where: { $0 != Space.firstID }) && !report.imported.isEmpty {
            report.notes.append("Spaces are switched off in Settings, so the imported Spaces won't show until you switch them on.")
        }
        return report
    }

    /// One Space, all or nothing as far as files go. The Space is published
    /// last, so a failure anywhere before leaves nothing visible and nothing
    /// of it on disk. The source's shared set, if it had one, is planned
    /// here too: this Mac's mode decides how plans show (SpaceCopy.swift).
    /// The first Space is filled rather than made: its owners write what they
    /// hold first, so nothing of theirs lands over what arrives, and what it
    /// hid and learned is kept to be put back if this fails.
    private func place(_ space: TransferSpace, as id: UUID, from transfer: UUID, shared: [PlannedExtension]) -> Bool {
        let filling = id == Space.firstID
        if filling {
            writeSession(of: id, now: true)
            histories[id]?.flush(); curtains[id]?.flush(); habitsBySpace[id]?.flush()
        }
        let hidden = filling ? curtain(for: id).byHost : [:]
        let learned = filling ? Habits.saved(space: id) : [:]
        var bookmarkIDs: [UUID: UUID] = [:]
        func collect(_ nodes: [Bookmark]) {
            for node in nodes {
                bookmarkIDs[node.id] = TransferApply.identity(transfer, node.id)
                collect(node.children ?? [])
            }
        }
        collect(space.bookmarks)
        // The first Space's own extensions run in it already, shared or not.
        var running: [Installed] = []
        if #available(macOS 15.4, *), prefs.sharedExtensions == true || filling { running = Extensions.saved(space: Space.firstID) }
        let planned = TransferApply.plan(space.extensions, shared: shared, running: running)
        let made = Space(id: id, name: space.name, colour: space.colour, icon: space.icon, swatch: space.swatch, sharesSignIns: nil,
                         downloads: filling ? spaces.first(where: \.isFirst)?.downloads : nil,
                         plannedExtensions: planned.isEmpty ? nil : planned)
        let list = filling ? spaces.map { $0.isFirst ? made : $0 } : spaces + [made]
        let written = !TransferApply.fails("files")
            && Session.copy(space.session, to: id, bookmarks: bookmarkIDs)
            && Bookmarks.copy(space.bookmarks, to: id, identities: bookmarkIDs)
            && Curtain.copy(space.hidden, to: id)
            && History.restore(space.history, to: id)
            && Habits.restore(space.habits, to: id, bookmarks: bookmarkIDs)
        guard written, !TransferApply.fails("spaces"), Spaces.write(list) else {
            if filling {
                // Pristine: no tab, bookmark or visit to put back.
                _ = Session.copy(Session.Shape(tabs: [], active: 0), to: id)
                _ = Bookmarks.copy([], to: id)
                _ = Curtain.copy(hidden, to: id)
                _ = History.restore([], to: id)
                _ = Habits.restore(learned, to: id, bookmarks: [:])
                return false
            }
            Session.erase(space: id)
            Bookmarks.erase(space: id)
            Curtain.erase(space: id)
            History.erase(space: id)
            Habits.erase(space: id)
            return false
        }
        // Settings, not files: set once the list stands, so a failure has none to take back.
        for (host, zoom) in space.zoom { Store.settings.set(zoom, forKey: Store.zoomKey(host, space: id)) }
        for host in space.paused { Shield.shared.pause(host, true, in: id) }
        if !space.never.isEmpty { Vault.setNever(Vault.never(in: id).union(space.never), in: id) }
        guard filling else {
            spaces.append(made)
            return true
        }
        TransferApply.fill(TransferApply.identity(transfer, space.id))
        // Its owners read again what arrived, and its row shows the tabs that came.
        shelves[id] = nil; histories[id] = nil; historyWatches[id] = nil
        curtains[id] = nil; habitsBySpace[id] = nil
        spaces = list
        showArrived()
        return true
    }

    /// The first Space's row after an import filled it: the tabs that came,
    /// then any the person still has open, while only an empty tab is let go.
    private func showArrived() {
        guard spaceID == Space.firstID else { return }
        let row = loadRow(Space.firstID)
        guard !row.tabs.isEmpty else { return }
        let blank = tabs.filter(\.isBlank)
        showRow(row.tabs + tabs.filter { !$0.isBlank }, active: row.active)
        for tab in blank { tab.close() }
        wakePanels()
    }
}
