// The bench exposes the real import actions and bounded, secret-free state in
// isolated worlds. It never installs a parser fixture inside the app, bypasses
// category validation, reads source keys, or creates a page while inspecting progress.
import Foundation
import CryptoKit

extension MigrationFlow {
    func bench(_ request: [String: Any], browser: Browser) -> [String: Any] {
        guard Store.testing else { return ["error": "migration only works in a test world"] }
        switch request["action"] as? String ?? "state" {
        case "password-matches":
            guard let world = Store.world, let expected = request["digest"] as? String,
                  let login = Vault.logins(for: "\(world).invalid", space: destination).first(where: { $0.user == world })
            else { return ["matches": false] }
            let digest = SHA256.hash(data: Data(login.password.utf8)).map { String(format: "%02x", $0) }.joined()
            return ["matches": digest == expected]
        case "open": browser.showMigration()
        case "automatic":
            guard let name = request["browser"] as? String, let brand = MigrationBrowser(rawValue: name), brand.automatic else {
                return ["error": "automatic needs an automatic browser"]
            }
            useBrowser(brand)
        case "pause": pause()
        case "step":
            guard let name = request["category"] as? String, let category = MigrationCategory(rawValue: name) else {
                return ["error": "step needs a category"]
            }
            startStep(category, in: browser)
        case "step-export":
            guard let path = request["path"] as? String else { return ["error": "step-export needs a file"] }
            let category = (request["category"] as? String).flatMap(MigrationCategory.init(rawValue:)) ?? .passwords
            chooseStepExport(URL(fileURLWithPath: path), category: category, in: browser)
        case "choose":
            guard let path = request["path"] as? String else { return ["error": "choose needs a file or folder"] }
            if let name = request["browser"] as? String, let brand = MigrationBrowser(rawValue: name) { self.browser = brand }
            choose(URL(fileURLWithPath: path), folder: request["folder"] as? Bool == true)
        case "select":
            guard let index = request["index"] as? Int, sources.indices.contains(index) else { return ["error": "unknown source index"] }
            select(sources[index].id)
        case "destination":
            guard !busy, let index = request["index"] as? Int, browser.spaces.indices.contains(index) else { return ["error": "unknown destination or busy"] }
            destination = browser.spaces[index].id
        case "categories":
            guard !busy, let names = request["categories"] as? [String] else { return ["error": "categories needs names"] }
            let parsed = Set(names.compactMap(MigrationCategory.init(rawValue:)))
            guard parsed.count == names.count, parsed.isSubset(of: source?.categories ?? []) else { return ["error": "category unavailable"] }
            categories = parsed
        case "preview": preview(in: browser)
        case "confirm": confirm(in: browser)
        case "cancel": cancel()
        case "reset": again()
        case "state": break
        default: return ["error": "unknown migration action"]
        }
        let phase: String
        switch migration.phase {
        case .choosing: phase = "choosing"
        case .reading: phase = "reading"
        case .preview: phase = "preview"
        case .applying: phase = "applying"
        case .finished: phase = "finished"
        case .stopped: phase = "stopped"
        }
        return ["phase": phase, "browser": self.browser?.rawValue ?? "", "discovering": discovering, "message": message ?? migration.message ?? "",
                "activeStep": activeStep?.rawValue ?? "",
                "stepResults": Dictionary(uniqueKeysWithValues: stepResults.map { ($0.key.rawValue, $0.value) }),
                "sources": sources.map { ["profile": $0.profile, "format": $0.format, "categories": $0.categories.map(\.rawValue).sorted()] },
                "notices": migration.plan?.values.notices ?? [],
                "stepNotices": Dictionary(uniqueKeysWithValues: stepNotices.map { ($0.key.rawValue, $0.value) }),
                "destination": destination.uuidString, "categories": categories.map(\.rawValue).sorted(),
                "previewBookmarks": migration.plan?.bookmarkCount ?? 0,
                "previewHistory": migration.plan?.values.history.count ?? 0,
                "previewPasswords": migration.plan?.values.passwords.count ?? 0,
                "historyPlaces": migration.receipt?.historyPlaces ?? 0,
                "addedTabs": migration.receipt?.addedTabs ?? 0,
                "keptTabs": migration.receipt?.keptTabs ?? 0,
                "previewTabs": migration.plan?.values.tabs.count ?? 0,
                "addedBookmarks": migration.receipt?.addedBookmarks ?? 0,
                "keptBookmarks": migration.receipt?.keptBookmarks ?? 0,
                "passwordAdds": migration.receipt?.passwordAdds ?? 0,
                "passwordKeeps": migration.receipt?.passwordKeeps ?? 0,
                "passwordFailures": migration.receipt?.passwordFailures ?? 0,
                "completed": migration.receipt?.completed.map(\.rawValue) ?? [],
                "finished": migration.receipt?.finished ?? false,
                "pages": browser.tabs.filter { $0.built != nil }.count]
    }
}
