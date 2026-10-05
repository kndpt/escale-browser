// Firefox sessions expose only saved web addresses, not forms or engine state.
// The newest current/recovery snapshot wins; corrupt current data never falls
// back silently to an older session. Closed/private windows and POST entries
// are left out. Stable Zen IDs are interpreted by MigrationZen; Firefox lacks
// durable tab IDs, so position plus URL identifies a tab for conservative replay.
import Foundation

enum MigrationGeckoSession {
    static let files = ["sessionstore.jsonlz4", "sessionstore-backups/recovery.jsonlz4"]

    static func selected(in root: URL) throws -> String? {
        let candidates = try files.filter { MigrationInput.exists($0, in: root) }.map { name -> (String, Date) in
            let url = try MigrationInput.file(name, in: root)
            return (name, try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast)
        }
        return candidates.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.first?.0
    }

    static func object(_ file: String, in root: URL, cancellation: MigrationCancellation) throws -> [String: Any] {
        let data = try MigrationMozLZ4.decode(MigrationInput.data(file, in: root, cancellation: cancellation), cancellation: cancellation)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MigrationFailure.malformed }
        return object
    }

    static func read(in root: URL, cancellation: MigrationCancellation) throws -> MigrationValues {
        guard let file = try selected(in: root) else { throw MigrationFailure.unreadable }
        let object = try object(file, in: root, cancellation: cancellation)
        guard let version = object["version"] as? [Any], version.count == 2,
              version[0] as? String == "sessionrestore", version[1] as? Int == 1 else { throw MigrationFailure.unsupported }
        guard let windows = object["windows"] as? [[String: Any]] else { throw MigrationFailure.malformed }
        guard windows.count <= 200 else { throw MigrationFailure.tooLarge }
        var result = MigrationValues(), omitted = 0, count = 0
        for (wi, window) in windows.enumerated() {
            try cancellation.check()
            guard let tabs = window["tabs"] as? [[String: Any]] else { throw MigrationFailure.malformed }
            count += tabs.count
            guard count <= 2_000 else { throw MigrationFailure.tooLarge }
            if window["isPrivate"] as? Bool == true { omitted += tabs.count; continue }
            for (ti, raw) in tabs.enumerated() {
                try cancellation.check()
                if let tab = try tab(raw, id: "window:\(wi):tab:\(ti)") { result.tabs.append(tab) }
                else { omitted += 1 }
            }
        }
        result.notices = ["Windows are combined in the chosen Space. Groups, containers and sign-ins are not transferred. Tabs stay asleep; no navigation history, form data or POST is restored.",
                          "Firefox has no persistent tab identity here: moving a source tab or changing its URL can add a new tab on reimport."]
        if omitted > 0 { result.notices.append("\(omitted) private, empty, POST or non-web tabs omitted.") }
        return result
    }

    static func tab(_ raw: [String: Any], id: String, stable: Bool = false) throws -> MigrationTab? {
        if raw["isPrivate"] as? Bool == true || raw["zenIsEmpty"] as? Bool == true || raw["zenIsGlance"] as? Bool == true { return nil }
        guard let entries = raw["entries"] as? [[String: Any]], entries.count <= MigrationLimits.records else { throw MigrationFailure.malformed }
        if entries.isEmpty { return nil }
        guard let index = raw["index"] as? Int, index >= 1, index <= entries.count else { throw MigrationFailure.malformed }
        let entry = entries[index - 1]
        if entry["postdata_b64"] != nil || entry["postdata"] != nil { return nil }
        guard let text = entry["url"] as? String else { throw MigrationFailure.malformed }
        guard let url = MigrationLimits.url(text) else { return nil }
        let title = try MigrationInput.text(raw["zenStaticLabel"] as? String ?? entry["title"] as? String ?? "")
        return MigrationTab(id: stable ? id : MigrationLimits.identity(id, text).uuidString,
                            url: url, title: title, pinned: raw["pinned"] as? Bool == true || raw["zenEssential"] as? Bool == true)
    }
}
