import AppKit
import WebKit

// The permissions Escale answers itself: granted when a manifest names
// them, asked for when they are optional, and kept per extension.

@available(macOS 15.4, *)
extension ExtensionShims {
    static func grants(_ asked: Asked) async throws -> Any? {
        let api = asked.api
        let first = asked.first
        let id = asked.id
        let context = asked.context
        let owner = asked.owner
        switch api {
        // MARK: permissions Escale grants itself
        case "permissions.granted":
            return Store.settings.stringArray(forKey: owner.settingKey("granted", id)) ?? []
        case "permissions.request":
            let wanted = (first as? [String]) ?? []
            guard requestable(wanted, manifest: context.webExtension.manifest) else {
                throw Unsupported(what: "Only permissions specified in the manifest may be requested.")
            }
            // Those Chrome grants without a word, having nothing to warn of.
            let silent: Set<String> = ["tabGroups", "sidePanel", "offscreen", "idle", "power", "fontSettings", "search",
                                       "system.cpu", "system.memory", "system.display", "favicon"]
            let names = wanted.map { $0.replacingOccurrences(of: ".", with: " ") }.joined(separator: ", ")
            let yes = wanted.allSatisfy(silent.contains) ? true : await owner.ask(more: names, context: context)
            guard yes else { return false }
            let had = Store.settings.stringArray(forKey: owner.settingKey("granted", id)) ?? []
            Store.settings.set(Array(Set(had + wanted)).sorted(), forKey: owner.settingKey("granted", id))
            return true
        case "permissions.remove":
            let gone = Set((first as? [String]) ?? [])
            let had = Store.settings.stringArray(forKey: owner.settingKey("granted", id)) ?? []
            Store.settings.set(had.filter { !gone.contains($0) }, forKey: owner.settingKey("granted", id))
            return true

        default:
            throw unknown(api)
        }
    }

    /// Chrome grants at run time only what the manifest lists as optional:
    /// checked here, since the shim's own check runs beside the extension's
    /// code and stops only the honest.
    nonisolated static func requestable(_ wanted: [String], manifest: [String: Any]) -> Bool {
        let optional = Set((manifest["optional_permissions"] as? [Any] ?? []).compactMap { $0 as? String })
        return wanted.allSatisfy(optional.contains)
    }
}
