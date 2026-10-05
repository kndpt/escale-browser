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
        for (index, space) in payload.spaces.enumerated() {
            if TransferApply.fails("slow") { try? await Task.sleep(nanoseconds: 800_000_000) }
            if Task.isCancelled { report.stopped = true; break }
            progress("Saving “\(space.name)” (\(index + 1) of \(payload.spaces.count))…")
            let id = TransferApply.identity(payload.id, space.id)
            if spaces.contains(where: { $0.id == id }) {
                report.already.append(space.name)
            } else if place(space, as: id, from: payload.id) {
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
        if !self.prefs.usesSpaces && !report.imported.isEmpty {
            report.notes.append("Spaces are switched off in Settings, so the imported Spaces won't show until you switch them on.")
        }
        return report
    }

    /// One Space, all or nothing as far as files go. The Space is published
    /// last, so a failure anywhere before leaves nothing visible and nothing
    /// of it on disk.
    private func place(_ space: TransferSpace, as id: UUID, from transfer: UUID) -> Bool {
        var bookmarkIDs: [UUID: UUID] = [:]
        func collect(_ nodes: [Bookmark]) {
            for node in nodes {
                bookmarkIDs[node.id] = TransferApply.identity(transfer, node.id)
                collect(node.children ?? [])
            }
        }
        collect(space.bookmarks)
        let made = Space(id: id, name: space.name, colour: space.colour, icon: space.icon, sharesSignIns: nil,
                         downloads: nil, plannedExtensions: space.extensions.isEmpty ? nil : space.extensions)
        let written = !TransferApply.fails("files")
            && Session.copy(space.session, to: id, bookmarks: bookmarkIDs)
            && Bookmarks.copy(space.bookmarks, to: id, identities: bookmarkIDs)
            && Curtain.copy(space.hidden, to: id)
            && History.restore(space.history, to: id)
            && Habits.restore(space.habits, to: id, bookmarks: bookmarkIDs)
        if written {
            for (host, zoom) in space.zoom { Store.settings.set(zoom, forKey: Store.zoomKey(host, space: id)) }
            for host in space.paused { Shield.shared.pause(host, true, in: id) }
            if !space.never.isEmpty { Vault.setNever(Set(space.never), in: id) }
        }
        guard written, !TransferApply.fails("spaces"), Spaces.write(spaces + [made]) else {
            Session.erase(space: id)
            Bookmarks.erase(space: id)
            Curtain.erase(space: id)
            History.erase(space: id)
            Habits.erase(space: id)
            Shield.shared.erase(space: id)
            Store.eraseZoom(space: id)
            Vault.erase(space: id)
            return false
        }
        spaces.append(made)
        return true
    }
}
