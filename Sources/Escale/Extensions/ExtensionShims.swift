import AppKit
import WebKit
import Combine
import NaturalLanguage
import UserNotifications
import IOKit.pwr_mgt
import CryptoKit

// The Chrome APIs WebKit doesn't have, filled in by the browser itself.
//
// Safari's extension engine covers tabs, storage, scripting, request rules,
// cookies, menus, alarms and messaging. Chrome extensions also reach for
// bookmarks, history, downloads, the side panel, offscreen documents, tab
// groups and OAuth — and fall over when those are undefined.
//
// So when an extension is installed, a small script is put at the front of
// its background and of every page it ships: `chrome.bookmarks` and the rest
// are defined there, and every call becomes a native message to this app,
// which answers from its own bookmarks, history and downloads. To the
// extension it looks like Chrome. The files are changed after the store's
// signature has been checked, and only by adding.

@available(macOS 15.4, *)
@MainActor
enum ExtensionShims {
    /// The name native messages to the browser itself go to.
    static let application = "escale"
    nonisolated static let file = "escale-shim.js"
    /// What content scripts get: the part of the shim that runs on a web
    /// page, in every matching frame of every site, so the rest stays out.
    nonisolated static let contentFile = "escale-content.js"
    /// The first line of a worker that already carries the shim.
    nonisolated static let marker = "/* Escale: Chrome APIs WebKit lacks, filled in (ExtensionShims.swift) */"
    nonisolated static let ender = "/* Escale: end of shim */"

    // MARK: - at install

    /// Written beside a prepared extension: which shim it carries. The same
    /// one needs nothing redone, which matters at launch — preparing reads
    /// every script and page an extension ships.
    nonisolated static let stamp = ".escale-shim"
    nonisolated static let version: Result<String, Error> = shipped.map {
        SHA256.hash(data: Data($0.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + (Store.testing ? "-test" : "")
    }

    nonisolated static func prepare(_ folder: URL) throws {
        let version = try version.get()
        let files = FileManager.default
        let stampURL = folder.appendingPathComponent(stamp)
        if (try? String(contentsOf: stampURL, encoding: .utf8)) == version { return }
        defer { try? version.write(to: stampURL, atomically: true, encoding: .utf8) }
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        else { throw Crx.Refused.unpack }

        // A package never prepared that ships a file under one of these
        // names is refused: writing over it would lose the extension's code.
        if !files.fileExists(atPath: stampURL.path),
           [file, contentFile].contains(where: { files.fileExists(atPath: folder.appendingPathComponent($0).path) }) {
            throw Crx.Refused.unpack
        }
        let script = try shim(for: folder)
        try script.write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try content(of: script).write(to: folder.appendingPathComponent(contentFile), atomically: true, encoding: .utf8)

        // Native messaging is how the shim reaches the browser; user scripts
        // are carried out through WebKit's registered content scripts, which
        // need scripting. What is added is written down, so the extension is
        // described by what it asked for, not by what Escale gave it.
        var permissions = manifest["permissions"] as? [Any] ?? []
        let asked = Set(permissions.compactMap { $0 as? String })
        var added = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(".escale-added")))) as? [String] ?? []
        for needed in ["nativeMessaging"] + (asked.contains("userScripts") ? ["scripting"] : []) where !asked.contains(needed) {
            permissions.append(needed)
            added.append(needed)
        }
        manifest["permissions"] = permissions
        if let data = try? JSONSerialization.data(withJSONObject: Array(Set(added)).sorted()) {
            try? data.write(to: folder.appendingPathComponent(".escale-added"))
        }

        // The background, whichever kind it is, gets the shim first. A
        // service worker gets it written at the top of its own file: that
        // holds whether WebKit runs it as a worker or as a page, as a classic
        // script or a module, where a wrapper importing it would not.
        if var background = manifest["background"] as? [String: Any] {
            // A manifest is not a way out of its own package: a worker path
            // that resolves outside the folder, or is a link, is left alone.
            if let worker = background["service_worker"] as? String,
               let path = inside(worker, of: folder) {
                if var source = try? String(contentsOf: path, encoding: .utf8) {
                    // Already carrying one: take the old one off, so a newer
                    // Escale puts its newer shim in its place.
                    if source.hasPrefix(marker), let end = source.range(of: ender) {
                        source = String(source[end.upperBound...]).trimmingPrefix("\n").description
                    }
                    // A copy from before there was an end marker: it ends
                    // where its function does, the first `})();` that
                    // starts a line.
                    while source.hasPrefix(marker), let end = source.range(of: "\n})();\n") {
                        source = String(source[end.upperBound...])
                    }
                    try (marker + "\n" + script + "\n" + ender + "\n" + source).write(to: path, atomically: true, encoding: .utf8)
                }
            }
            // Scripts, alone or beside a worker — WebKit runs them as a page
            // when a manifest names both.
            if var scripts = background["scripts"] as? [String] {
                if scripts.first != file { scripts.insert(file, at: 0) }
                background["scripts"] = scripts
            }
            manifest["background"] = background
        }

        // Content scripts get their own part, in place of the whole shim an
        // earlier Escale put there.
        if let entries = manifest["content_scripts"] as? [[String: Any]] {
            manifest["content_scripts"] = entries.map { entry -> [String: Any] in
                var entry = entry
                if var js = entry["js"] as? [String], js.first != contentFile {
                    if js.first == file { js.removeFirst() }
                    js.insert(contentFile, at: 0)
                    entry["js"] = js
                }
                return entry
            }
        }

        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: manifestURL, options: .atomic)

        // Every page it ships — popup, options, background page, side panel.
        let walker = files.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  ["html", "htm"].contains(url.pathExtension.lowercased()),
                  var html = try? String(contentsOf: url, encoding: .utf8),
                  !html.contains(file)
            else { continue }
            let tag = "<script src=\"/\(file)\"></script>"
            if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                html.insert(contentsOf: tag, at: head.upperBound)
            } else {
                html = tag + html
            }
            try? html.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// A path a package names, resolved and kept inside the folder it came
    /// in: `..` in a manifest is not a way out of the package. Nor is a
    /// symbolic link, which a folder install keeps as it is: the worker is
    /// read through it and written back over it as a regular file, so a
    /// link to a file elsewhere would put that file's bytes in the package.
    /// A folder on the way that is a link is caught by where it resolves.
    nonisolated static func inside(_ name: String, of folder: URL) -> URL? {
        let path = folder.appendingPathComponent(name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).standardizedFileURL
        guard path.path.hasPrefix(folder.standardizedFileURL.path + "/"),
              (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              path.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/")
        else { return nil }
        return path
    }

    /// The shim as this extension gets it: with the events its code mentions
    /// — `chrome.tabs.onUpdated`, `e.runtime.onInstalled` — so its worker
    /// can take their listeners late (see the end of the script).
    nonisolated static func shim(for folder: URL) throws -> String {
        let script = try shipped.get()
        var found = Set<String>()
        let pattern = try! NSRegularExpression(pattern: #"\.([a-zA-Z]+)\.(on[A-Z][A-Za-z]+)\b"#)
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "js", url.lastPathComponent != file, url.lastPathComponent != contentFile,
                  var text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // Not the shim's own words, in a worker that already carries it.
            if text.hasPrefix(marker), let end = text.range(of: ender) { text = String(text[end.upperBound...]) }
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let a = Range(match.range(at: 1), in: text), let b = Range(match.range(at: 2), in: text) else { continue }
                found.insert("\(text[a]).\(text[b])")
            }
        }
        let list = (try? JSONSerialization.data(withJSONObject: found.sorted())).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        // And the scripts it ships, so its worker can be told at once that
        // one isn't there (see importScripts in the script).
        var scripts: [String] = []
        let all = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = all?.nextObject() as? URL {
            guard url.pathExtension == "js" else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count))
            // An empty one is marked: there is nothing to run in it.
            let empty = ((try? String(contentsOf: url, encoding: .utf8)) ?? "x").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            scripts.append((empty ? "-" : "") + path)
        }
        let shipped = (try? JSONSerialization.data(withJSONObject: scripts.sorted())).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return script.replacingOccurrences(of: "__ESCALE_EVENTS__", with: list)
            .replacingOccurrences(of: "__ESCALE_SCRIPTS__", with: shipped)
            .replacingOccurrences(of: "__ESCALE_CHROME__", with: Crx.chromeVersion)
            .replacingOccurrences(of: "__ESCALE_VERBOSE__", with: Store.testing ? "true" : "false")
    }

    /// The shim up to where a content script stops (`if (inContent)
    /// return;`), closed there. Without that line, the whole shim.
    nonisolated static func content(of script: String) -> String {
        guard let stop = script.range(of: "\n  if (inContent) return;\n") else { return script }
        return script[..<stop.lowerBound] + "\n})();\n"
    }

    /// The shim's files, one concern each, in the order they run as one
    /// function: shim.js opens it and is all a content script gets.
    nonisolated static let parts = ["shim.js", "shim-calls.js", "shim-messaging.js", "shim-worker.js", "shim-apis.js",
                                    "shim-mends.js", "shim-permissions.js", "shim-user-scripts.js", "shim-background.js",
                                    "shim-filesystem.js", "shim-errors.js"]

    /// Defines only what is missing, so the day WebKit implements an API,
    /// WebKit's is the one used. Read from Extensions/Scripts the first time
    /// an extension is prepared (see Bundled.swift), then kept while the app
    /// runs: 114 KB, and nothing read without an extension.
    nonisolated static let shipped = Result { try parts.map { try Bundled.text($0) }.joined(separator: "\n") }

    // MARK: - answering

    /// Remembered per extension: the side panel it set, and whether its
    /// button should open it.
    static var panelPath: [String: String] = [:]
    static var panelOnClick: Set<String> = []
    /// Offscreen documents, one per extension, as Chrome allows.
    static var offscreen: [String: WKWebView] = [:]

    static func answer(_ message: Any, from context: WKWebExtensionContext, owner: Extensions) async throws -> Any? {
        guard let body = message as? [String: Any], let api = body["api"] as? String else {
            return ["error": "Not an Escale message"]
        }
        let args = body["args"] as? [Any] ?? []
        do {
            return ["value": try await run(api, args, context: context, owner: owner) ?? NSNull()]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    struct Unsupported: LocalizedError {
        let what: String
        var errorDescription: String? { what }
    }

    static func unknown(_ api: String) -> Unsupported { Unsupported(what: "\(api) isn't available in Escale") }

    /// One call from the shim, with what answering it needs. Each family
    /// answers its own (ExtensionBookmarks.swift and the files beside it).
    @MainActor struct Asked {
        let api: String
        let args: [Any]
        let context: WKWebExtensionContext
        let owner: Extensions
        let browser: Browser
        var first: Any? { args.first }
        var id: String { context.uniqueIdentifier }
        var scope: String { owner.scope(id) }
    }

    /// The families Chrome gives only to an extension that asked for them:
    /// what the browser knows about the person using it, what the Mac says
    /// about itself, and what acts on its behalf — a notification, speech,
    /// a page out of sight, a sign-in tab. WebKit keeps no permission object
    /// for them, they are the APIs this shim exists to supply, so the gate
    /// reads the names the extension's own manifest asked for. Tab groups
    /// answer nothing, and stay open.
    nonisolated private static let gates: [String: String] = [
        "bookmarks": "bookmarks",
        "history": "history",
        "downloads": "downloads",
        "sessions": "sessions",
        "topSites": "topSites",
        "browsingData": "browsingData",
        "readingList": "readingList",
        "userScripts": "userScripts",
        "notifications": "notifications",
        "idle": "idle",
        "power": "power",
        "identity": "identity",
        "offscreen": "offscreen",
        "tts": "tts",
        "search": "search",
        "fontSettings": "fontSettings",
        "sidePanel": "sidePanel",
    ]

    /// The names `api` needs. Opening a download hands a file to another
    /// app, so Chrome asks for a permission of its own on top of the family's;
    /// a setting needs its family;
    /// each part of `system` has its own; `management` is needed for any
    /// extension but the caller.
    nonisolated static func needs(_ api: String) -> [String] {
        // A setting, `setting.get:privacy.…`, needs its family: privacy or proxy.
        if api.hasPrefix("setting."), let name = api.split(separator: ":", maxSplits: 1).last {
            return [String(name.prefix(while: { $0 != "." }))]
        }
        let name = String(api.prefix(while: { $0 != "." }))
        if name == "system" { return [api.split(separator: ".").prefix(2).joined(separator: ".")] }
        if name == "management" { return api == "management.getSelf" || api == "management.uninstallSelf" ? [] : ["management"] }
        let family = gates[name].map { [$0] } ?? []
        return api == "downloads.open" ? family + ["downloads.open"] : family
    }

    /// What this extension asked for: the names in its manifest and any
    /// optional ones granted since. The checks inside the shim are a
    /// courtesy to honest code, the shim runs beside the extension's own,
    /// so the one that counts is here. The manifest is the one WebKit
    /// already holds, not the file read again on every call.
    private static func allowed(_ id: String, context: WKWebExtensionContext, owner: Extensions) -> Set<String> {
        let asked = (context.webExtension.manifest["permissions"] as? [Any] ?? []).compactMap { $0 as? String }
        return Set(asked + (Store.settings.stringArray(forKey: owner.settingKey("granted", id)) ?? []))
    }

    private static func run(_ api: String, _ args: [Any], context: WKWebExtensionContext, owner: Extensions) async throws -> Any? {
        guard let browser = owner.browser else { throw Unsupported(what: "No browser window") }
        let first = args.first
        let id = context.uniqueIdentifier

        // What leaves this app is answered here, not in the injected script:
        // the shim runs beside the extension's own code, so its checks stop
        // only the honest. A family this extension never asked for is an
        // error, the way Chrome answers a call to an API it lacks.
        // `tabs.describe` is the one call inside a family WebKit does own
        // where the permission guards reading a tab rather than moving or
        // selecting it. WebKit keeps that permission, optional grants
        // included, so it is asked.
        if api == "tabs.describe", !context.hasPermission(.tabs) {
            throw Unsupported(what: "The extension never asked for \u{201C}tabs\u{201D}")
        }
        let needed = needs(api)
        if !needed.isEmpty {
            let granted = allowed(id, context: context, owner: owner)
            if let missing = needed.first(where: { !granted.contains($0) }) {
                throw Unsupported(what: "The extension never asked for \u{201C}\(missing)\u{201D}")
            }
        }

        if api.hasPrefix("setting.") { return setting(api, first as? [String: Any] ?? [:], extension: id, owner: owner) }

        let asked = Asked(api: api, args: args, context: context, owner: owner, browser: browser)
        switch api.prefix(while: { $0 != "." }) {
        case "bookmarks": return try await bookmarks(asked)
        case "history", "sessions", "topSites", "readingList", "browsingData": return try await history(asked)
        case "downloads": return try await downloads(asked)
        case "sidePanel", "offscreen", "action", "tabs", "tabGroups", "search": return try await pages(asked)
        case "fontSettings", "idle", "power", "system", "notifications", "tts", "i18n", "runtime", "management": return try await system(asked)
        case "background", "debug": return try await worker(asked)
        case "permissions": return try await grants(asked)
        case "userScripts": return try await userScripts(asked)
        case "identity": return try await identity(asked)
        default: throw unknown(api)
        }
    }

    // MARK: - kept per extension

    /// Popups extensions set for their buttons: per tab, or "*" for all.
    static var popups: [String: [String: String]] = [:]

    /// Keep-awake assertions, one per extension that asked.
    static var awake: [String: IOPMAssertionID] = [:]

    static func release(space: UUID) {
        let prefix = space.uuidString + "/"
        panelPath = panelPath.filter { !$0.key.hasPrefix(prefix) }
        panelOnClick = panelOnClick.filter { !$0.hasPrefix(prefix) }
        offscreen = offscreen.filter { !$0.key.hasPrefix(prefix) }
        popups = popups.filter { !$0.key.hasPrefix(prefix) }
        for key in awake.keys.filter({ $0.hasPrefix(prefix) }) {
            if let assertion = awake.removeValue(forKey: key) { IOPMAssertionRelease(assertion) }
        }
    }

    /// chrome.privacy and chrome.proxy: what each extension set, kept across
    /// launches as Chrome keeps it. Escale acts on one of them — an
    /// extension turning the browser's own offer to save passwords off,
    /// which is how every password manager asks Chrome to step aside.
    private static func setting(_ api: String, _ details: [String: Any], extension id: String, owner: Extensions) -> Any? {
        let parts = api.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let name = parts[1]
        var mine = owner.settings(for: id)
        switch parts[0] {
        case "setting.set":
            mine[name] = details["value"]
        case "setting.clear":
            mine[name] = nil
        default:
            let value = mine[name] ?? defaultSetting(name, owner: owner)
            return ["value": value ?? NSNull(), "levelOfControl": mine[name] != nil ? "controlled_by_this_extension" : "controllable_by_this_extension"]
        }
        owner.setSettings(mine, for: id)
        owner.objectWillChange.send()
        return nil
    }

    private static func defaultSetting(_ name: String, owner: Extensions) -> Any? {
        switch name {
        case "privacy.services.passwordSavingEnabled": return owner.browser?.prefs.savesPasswords ?? true
        case "privacy.network.webRTCIPHandlingPolicy": return "default"
        case "privacy.websites.doNotTrackEnabled", "privacy.websites.adMeasurementEnabled",
             "privacy.websites.fledgeEnabled", "privacy.websites.topicsEnabled",
             "privacy.services.safeBrowsingExtendedReportingEnabled": return false
        case "proxy.settings": return ["mode": "system"]
        default: return true
        }
    }
}
