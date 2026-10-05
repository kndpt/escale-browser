// Discovery starts only inside a folder explicitly selected by the user, or a
// brand's known home after the user chose that brand. It lists at most 200
// profiles and never depends on Login Data or asks for a source keychain key.
// Browser names are provenance labels, not a claim that every brand's private
// workspaces/sessions share its engine's file formats. One Chromium rule
// serves every brand: Local State names, Default/Profile N folders, a profile
// at the root (Opera, or a profile folder chosen directly), and no link that
// leaves the chosen folder. System and Guest profiles hold no user data.
import Foundation

enum MigrationProfiles {
    static func discover(in root: URL, browser: String, family: String,
                         cancellation: MigrationCancellation = MigrationCancellation()) throws -> [MigrationSource] {
        switch family {
        case "chromium": return try chromium(in: root, browser: browser, cancellation: cancellation)
        case "gecko": return try gecko(in: root, browser: browser, cancellation: cancellation)
        default: throw MigrationFailure.unsupported
        }
    }

    /// Chrome keeps bookmarks saved to the signed-in account in their own file.
    static let chromiumBookmarkFiles = ["Bookmarks", "AccountBookmarks"]

    static func chromium(in root: URL, browser: String, cancellation: MigrationCancellation) throws -> [MigrationSource] {
        try cancellation.check()
        let fm = FileManager.default
        let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
        guard children.count <= 2_000 else { throw MigrationFailure.tooLarge }
        let labels = try localState(root)
        var candidates: [(URL, String)] = [(root, root.lastPathComponent)]
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = child.lastPathComponent
            guard name != "System Profile", name != "Guest Profile",
                  name == "Default" || name.hasPrefix("Profile ") || labels[name] != nil,
                  try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            candidates.append((child, labels[name] ?? name))
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        func inside(_ url: URL) -> Bool { url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base + "/") }
        var seen = Set<String>(), result: [MigrationSource] = []
        for (url, label) in candidates {
            try cancellation.check()
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path == base || inside(url), seen.insert(path).inserted else { continue }
            var categories = Set<MigrationCategory>()
            for (file, category) in chromiumBookmarkFiles.map({ ($0, MigrationCategory.bookmarks) }) + [("History", .history)] {
                let item = url.appendingPathComponent(file)
                if fm.fileExists(atPath: item.path), inside(item) { categories.insert(category) }
            }
            if !(try MigrationChromiumSession.files(in: url)).isEmpty { categories.insert(.tabs) }
            guard !categories.isEmpty else { continue }
            guard result.count < 200 else { throw MigrationFailure.tooLarge }
            result.append(MigrationSource(id: MigrationLimits.identity("chromium", path).uuidString, browser: browser,
                                          profile: label, location: url, format: "chromium", categories: categories))
        }
        return result
    }

    /// Profile names from Local State. A malformed file is refused rather than
    /// guessed around, and a name can never point outside the chosen folder.
    static func localState(_ root: URL) throws -> [String: String] {
        let state = root.appendingPathComponent("Local State")
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: state.path),
              state.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base + "/") else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: MigrationLimits.data(state)) as? [String: Any] else {
            throw MigrationFailure.malformed
        }
        guard let cache = (object["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]] else { return [:] }
        guard cache.count <= 200 else { throw MigrationFailure.tooLarge }
        var labels: [String: String] = [:]
        for (key, value) in cache {
            guard !key.isEmpty, !key.contains("/"), key != ".", key != ".." else { throw MigrationFailure.malformed }
            let name = value["name"] as? String ?? key
            guard name.utf8.count <= MigrationLimits.field else { throw MigrationFailure.tooLarge }
            labels[key] = name
        }
        return labels
    }

    private static func gecko(in root: URL, browser: String, cancellation: MigrationCancellation) throws -> [MigrationSource] {
        var candidates: [(URL, String)] = [(root, root.lastPathComponent)]
        let fm = FileManager.default
        let ini = root.appendingPathComponent("profiles.ini")
        if fm.fileExists(atPath: ini.path) {
            candidates = []
            let sections = try profilesINI(MigrationLimits.text(ini))
            for section in sections {
                guard let path = section["Path"], !path.isEmpty else { continue }
                let url: URL
                if section["IsRelative"] == "1" { url = root.appendingPathComponent(path).standardizedFileURL }
                else if path.hasPrefix("/") { url = URL(fileURLWithPath: path) }
                else { throw MigrationFailure.malformed }
                candidates.append((url, section["Name"] ?? url.lastPathComponent))
            }
        } else {
            let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
            guard children.count <= 2_000 else { throw MigrationFailure.tooLarge }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    candidates.append((child, child.lastPathComponent))
                }
            }
        }
        var seen = Set<String>(), result: [MigrationSource] = []
        for (url, name) in candidates {
            try cancellation.check()
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            var categories = Set<MigrationCategory>()
            if MigrationInput.exists("places.sqlite", in: url) { categories.formUnion([.bookmarks, .history]) }
            if MigrationGeckoSession.files.contains(where: { MigrationInput.exists($0, in: url) }) { categories.insert(.tabs) }
            guard !categories.isEmpty || (browser == MigrationBrowser.zen.rawValue && MigrationInput.exists("zen-sessions.jsonlz4", in: url)) else { continue }
            guard result.count < 200 else { throw MigrationFailure.tooLarge }
            result.append(MigrationSource(id: MigrationLimits.identity("gecko", path).uuidString, browser: browser,
                                          profile: name, location: url, format: "gecko", version: try geckoVersion(in: url, cancellation: cancellation), categories: categories))
        }
        return result
    }

    static func geckoVersion(in root: URL, cancellation: MigrationCancellation) throws -> String {
        guard MigrationInput.exists("compatibility.ini", in: root) else { return "Unqualified version" }
        let data = try MigrationInput.data("compatibility.ini", in: root, cancellation: cancellation)
        guard let text = String(data: data, encoding: .utf8),
              let line = text.components(separatedBy: .newlines).first(where: { $0.hasPrefix("LastVersion=") }) else { return "Unqualified version" }
        return try MigrationInput.text(String(line.dropFirst("LastVersion=".count).prefix(128)))
    }

    static func profilesINI(_ text: String) throws -> [[String: String]] {
        guard text.utf8.count <= MigrationLimits.bytes else { throw MigrationFailure.tooLarge }
        var result: [[String: String]] = [], current: [String: String]?, sections = Set<String>()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.utf8.count <= MigrationLimits.field else { throw MigrationFailure.tooLarge }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                if let current { result.append(current) }
                let section = String(line.dropFirst().dropLast())
                guard sections.insert(section).inserted else { throw MigrationFailure.malformed }
                current = section.hasPrefix("Profile") ? [:] : nil
            } else if current != nil, !line.hasPrefix(";"), !line.hasPrefix("#"), let split = line.firstIndex(of: "=") {
                let key = String(line[..<split]), value = String(line[line.index(after: split)...])
                guard current?[key] == nil else { throw MigrationFailure.malformed }
                current?[key] = value
            }
            guard result.count <= 200 else { throw MigrationFailure.tooLarge }
        }
        if let current { result.append(current) }
        guard result.count <= 200 else { throw MigrationFailure.tooLarge }
        return result
    }
}
