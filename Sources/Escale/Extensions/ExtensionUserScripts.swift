import AppKit
import WebKit
import CryptoKit

// chrome.userScripts, carried out through WebKit's registered content
// scripts: each script a file of the extension's own, wrapped so Chrome's
// globs and worlds hold.

@available(macOS 15.4, *)
extension ExtensionShims {
    static func userScripts(_ asked: Asked) async throws -> Any? {
        let api = asked.api
        let first = asked.first
        let id = asked.id
        let owner = asked.owner
        switch api {
        // MARK: user scripts
        case "userScripts.file":
            return try userScriptFile(first as? [String: Any] ?? [:], in: owner.folder(for: id))
        case "userScripts.list":
            return (try? JSONSerialization.jsonObject(with: Data(contentsOf: own(in: owner.folder(for: id)).appendingPathComponent("userscripts.json")))) ?? []
        case "userScripts.save":
            let folder = own(in: owner.folder(for: id))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let scripts = first as? [[String: Any]] ?? []
            try JSONSerialization.data(withJSONObject: scripts).write(to: folder.appendingPathComponent("userscripts.json"), options: .atomic)
            // Files no saved script is written in any more, once a moment
            // has passed — one being injected right now is left alone.
            let keep = Set(scripts.compactMap { try? userScriptFile($0, in: owner.folder(for: id)) }.map { URL(fileURLWithPath: $0).lastPathComponent })
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where file.lastPathComponent.hasPrefix("us-") && !keep.contains(file.lastPathComponent) {
                let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow } ?? 999
                if age > 60 { try? FileManager.default.removeItem(at: file) }
            }
            return nil
        case "userScripts.world", "userScripts.worlds":
            let url = own(in: owner.folder(for: id)).appendingPathComponent("worlds.json")
            var worlds = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [[String: Any]] ?? []
            if api == "userScripts.worlds" { return worlds }
            let props = first as? [String: Any] ?? [:]
            let world = props["worldId"] as? String ?? ""
            worlds.removeAll { ($0["worldId"] as? String ?? "") == world }
            if props["reset"] as? Bool != true { worlds.append(props) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: worlds).write(to: url, options: .atomic)
            return nil

        default:
            throw unknown(api)
        }
    }

    /// A user script as a file WebKit can inject: its code — inline, or read
    /// from the extension's own files — inside a block that leaves at once
    /// on a page its globs rule out and, for Chrome's USER_SCRIPT world,
    /// gives the code a `chrome` whose messages are marked as a user
    /// script's. Named by what is in it, so a changed script is a new file
    /// and never a stale one WebKit has already read.
    /// The `chrome` a user script sees in Chrome's USER_SCRIPT world, from
    /// Extensions/Scripts/user-script-chrome.js, read once when first needed.
    nonisolated static let userChrome = Result { try Bundled.text("user-script-chrome.js") }

    // (see Extensions/Scripts/user-script-shell.js) Read once when user scripts are prepared.
    nonisolated static let userScriptShell = Bundled.script("user-script-shell.js")

    static func userScriptFile(_ script: [String: Any], in folder: URL) throws -> String {
        let json = { (value: Any) in
            (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        var code = ""
        for source in script["js"] as? [[String: Any]] ?? [] {
            if let inline = source["code"] as? String {
                code += inline + "\n;\n"
            } else if let file = source["file"] as? String, let path = inside(file, of: folder),
                      let text = try? String(contentsOf: path, encoding: .utf8) {
                code += text + "\n;\n"
            }
        }
        let userWorld = (script["world"] as? String) != "MAIN"
        let prelude = userWorld ? try userChrome.get() : ""
        let template = userScriptShell
        guard !template.isEmpty,
              let include = template.range(of: "__ESCALE_INCLUDE__"),
              let exclude = template.range(of: "__ESCALE_EXCLUDE__", range: include.upperBound..<template.endIndex),
              let preludeSlot = template.range(of: "__ESCALE_PRELUDE__", range: exclude.upperBound..<template.endIndex),
              let codeSlot = template.range(of: "__ESCALE_CODE__", range: preludeSlot.upperBound..<template.endIndex)
        else { throw Bundled.Missing(name: "user-script-shell.js") }
        var text = String(template[..<include.lowerBound])
        text += json(script["includeGlobs"] ?? [])
        text += template[include.upperBound..<exclude.lowerBound]
        text += json(script["excludeGlobs"] ?? [])
        text += template[exclude.upperBound..<preludeSlot.lowerBound]
        text += prelude
        text += template[preludeSlot.upperBound..<codeSlot.lowerBound]
        text += code
        text += template[codeSlot.upperBound...]
        let name = "us-" + SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + ".js"
        let dir = own(in: folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { try text.write(to: url, atomically: true, encoding: .utf8) }
        return ownFolder + "/" + name
    }

    /// The folder Escale writes into inside an extension's own: user scripts,
    /// their list and their worlds. Chrome reserves names that start with an
    /// underscore, so no extension ships one of its own. Earlier builds named
    /// it `_search`, after the browser Escale started from; the first use
    /// moves that folder across, so the scripts people saved are kept. If the
    /// move fails, the old folder is left where it is and tried again later.
    nonisolated static let ownFolder = "_escale"

    nonisolated static func own(in folder: URL) -> URL {
        let own = folder.appendingPathComponent(ownFolder, isDirectory: true)
        let earlier = folder.appendingPathComponent("_search", isDirectory: true)
        let files = FileManager.default
        if !files.fileExists(atPath: own.path), files.fileExists(atPath: earlier.path) {
            try? files.moveItem(at: earlier, to: own)
        }
        return own
    }
}
