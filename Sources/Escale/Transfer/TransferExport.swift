// Taking Escale off a Mac. Everything is read in one turn of the main actor,
// where every owner lives, after what was waiting to be written has been:
// so the file is the state at that moment, parked and never-opened Spaces
// included, and no file is copied while something else writes it. Passwords
// are read afterwards and off the main actor, only when asked for, because the
// keychain is read one item at a time. Then one sealed blob is written beside
// its destination and moved into place, so a file that fails halfway never
// replaces the export that was there.
import Foundation

extension Browser {
    /// The organisation of every Space, the window's link rules and the
    /// portable preferences, without passwords (see `TransferExport.logins`).
    func transferSnapshot() -> TransferPayload {
        flush()
        Writer.flushAll()
        var out: [TransferSpace] = []
        for space in spaces {
            var extensions = space.plannedExtensions ?? []
            if #available(macOS 15.4, *) {
                for item in Extensions.saved(space: space.id) {
                    let planned = PlannedExtension(name: item.name, storeID: item.fromStore ? item.id : nil)
                    if !extensions.contains(planned) { extensions.append(planned) }
                }
            }
            out.append(TransferSpace(
                id: space.id, name: space.name, colour: space.colour, icon: space.icon, extensions: extensions,
                session: Session.read(space: space.id),
                // A Space nobody opened is read and let go, not kept loaded for good.
                bookmarks: (shelves[space.id]?.list ?? Bookmarks(space: space.id)).roots,
                history: History.saved(space: space.id),
                habits: Habits.saved(space: space.id),
                hidden: (curtains[space.id] ?? Curtain(space: space.id)).byHost,
                zoom: Store.zooms(in: space.id),
                paused: Shield.shared.paused(in: space.id).sorted(),
                never: Vault.never(in: space.id).sorted(),
                logins: nil))
        }
        return TransferPayload(id: UUID(), created: Date(), app: Updater.version, spaces: out,
                               preferences: TransferPreferences.snapshot(prefs), linkRules: linkRoutes.rules,
                               includesPasswords: false)
    }
}

enum TransferExport {
    /// What the passwords of each Space are, read off the main actor.
    nonisolated static func logins(of spaces: [UUID]) -> [UUID: [TransferLogin]] {
        var found: [UUID: [TransferLogin]] = [:]
        for space in spaces {
            found[space] = Vault.all(space: space).map { TransferLogin(host: $0.host, user: $0.user, password: $0.password, used: $0.used) }
        }
        return found
    }

    nonisolated static func encode(_ payload: TransferPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    /// Sealed and moved into place in one step: `Data.write(.atomic)` writes a
    /// sibling and renames it, so an earlier export survives any failure here.
    nonisolated static func write(_ payload: TransferPayload, passphrase: String, to url: URL, rounds: UInt32 = TransferFile.rounds) throws {
        let sealed = try TransferFile.seal(try encode(payload), passphrase: passphrase, rounds: rounds)
        do { try sealed.write(to: url, options: .atomic) }
        catch { throw TransferError.unavailable("Escale couldn't write the file there: \(error.localizedDescription)") }
    }

    /// `Escale-2026-09-30.escale`, in the reader's own calendar day.
    static func suggestedName(on date: Date = Date()) -> String {
        let day = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "Escale-%04d-%02d-%02d.escale", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }
}
