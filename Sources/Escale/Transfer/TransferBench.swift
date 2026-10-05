// The bench exposes the real save and import walks in isolated worlds, with
// bounded state that never includes a passphrase, a password or an address of
// a page. `fail` makes the named write step fail as a full disk would, so the
// failure paths run against the real owners. Test worlds only.
import CryptoKit
import Foundation

extension TransferFlow {
    func bench(_ request: [String: Any], browser: Browser) -> [String: Any] {
        guard Store.testing else { return ["error": "transfer only works in a test world"] }
        switch request["action"] as? String ?? "state" {
        case "save":
            guard let path = request["path"] as? String, let phrase = request["passphrase"] as? String else {
                return ["error": "save needs a path and a passphrase"]
            }
            save(to: URL(fileURLWithPath: path), passphrase: phrase, withPasswords: request["passwords"] as? Bool == true, browser: browser)
        case "choose":
            guard let path = request["path"] as? String else { return ["error": "choose needs a file"] }
            choose(URL(fileURLWithPath: path))
        case "unlock":
            unlock(passphrase: request["passphrase"] as? String ?? "", browser: browser)
        case "apply":
            if let preferences = request["preferences"] as? Bool { takesPreferences = preferences }
            apply(browser: browser)
        case "fail":
            TransferApply.failing = Set(request["steps"] as? [String] ?? [])
        case "logins":
            // What the keychain holds for a Space's synthetic site, as hashes:
            // the app reads its own items, so nothing asks the person.
            guard let text = request["space"] as? String, let space = UUID(uuidString: text) else { return ["error": "logins needs a space"] }
            var out = state(browser)
            out["logins"] = Vault.logins(for: "issue40.invalid", space: space).map {
                ["user": $0.user, "digest": SHA256.hash(data: Data($0.password.utf8)).map { String(format: "%02x", $0) }.joined()]
            }
            return out
        case "open":
            // The import page of Settings with Escale chosen, for a picture.
            browser.showMigration()
            browser.migration.useBrowser(.escale)
        case "cancel": cancel()
        case "forget": forget()
        case "state": break
        default: return ["error": "unknown transfer action"]
        }
        return state(browser)
    }

    private func state(_ browser: Browser) -> [String: Any] {
        var out: [String: Any] = [
            "saving": "idle", "bringing": "idle", "busy": busy, "mistake": mistake ?? "",
            "pristine": pristine, "takesPreferences": takesPreferences,
            "spaces": browser.spaces.map { ["id": $0.id.uuidString, "name": $0.name] },
        ]
        switch saving {
        case .idle: break
        case .working: out["saving"] = "working"
        case .saved(let name, let count): out["saving"] = "saved"; out["savedName"] = name; out["savedSpaces"] = count
        case .failed(let message): out["saving"] = "failed"; out["failure"] = message
        }
        switch bringing {
        case .idle: break
        case .locked(let name): out["bringing"] = "locked"; out["file"] = name
        case .opening: out["bringing"] = "opening"
        case .summary(let summary):
            out["bringing"] = "summary"
            out["summary"] = ["lines": summary.lines.map {
                ["name": $0.name, "tabs": $0.tabs, "bookmarks": $0.bookmarks, "history": $0.history,
                 "passwords": $0.passwords, "extensions": $0.extensions] as [String: Any] },
                              "linkRules": summary.linkRules, "preferences": summary.preferences,
                              "skipped": summary.skipped, "includesPasswords": summary.includesPasswords,
                              "app": summary.app] as [String: Any]
        case .applying(let text): out["bringing"] = "applying"; out["progress"] = text
        case .finished(let report):
            out["bringing"] = "finished"
            out["report"] = ["imported": report.imported, "already": report.already, "failed": report.failed,
                             "passwordsAdded": report.passwordsAdded, "passwordsKept": report.passwordsKept,
                             "passwordsFailed": report.passwordsFailed, "preferences": report.preferences,
                             "linkRules": report.linkRules, "notes": report.notes, "stopped": report.stopped] as [String: Any]
        case .failed(let message): out["bringing"] = "failed"; out["failure"] = message
        }
        return out
    }
}
