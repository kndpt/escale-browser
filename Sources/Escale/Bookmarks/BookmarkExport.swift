// "Export bookmarks…" writes one Space's list as the Netscape bookmarks file
// every browser imports, so bookmarks can leave Escale the way they came in
// (MigrationExchange.swift reads the same format). Folders and order are kept;
// titles and addresses are escaped, so a quote or an ampersand cannot change
// the file's structure. The format has no place for environments: they follow
// the list in one last folder, a subfolder per bookmark, so their addresses
// leave too and the list itself stays as it was. The file is built and written
// off the main thread, only to the place the person chose; nothing goes on the
// network.
import AppKit
import UniformTypeIdentifiers

enum BookmarkExport {
    /// The last folder, which carries environments.
    static let environmentsFolder = "Environments"

    /// The whole file, and how many environments went into their folder.
    static func html(_ roots: [Bookmark]) -> (text: String, environments: Int) {
        var lines = ["<!DOCTYPE NETSCAPE-Bookmark-file-1>",
                     "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">",
                     "<TITLE>Bookmarks</TITLE>",
                     "<H1>Bookmarks</H1>"]
        func list(_ nodes: [Bookmark], depth: Int) {
            let pad = String(repeating: "    ", count: depth)
            lines.append(pad + "<DL><p>")
            for node in nodes {
                if let url = node.url {
                    lines.append(pad + "    <DT><A HREF=\"\(escape(url))\">\(escape(node.title))</A>")
                } else {
                    lines.append(pad + "    <DT><H3>\(escape(node.title))</H3>")
                    list(node.children ?? [], depth: depth + 1)
                }
            }
            lines.append(pad + "</DL><p>")
        }
        func sites(_ nodes: [Bookmark]) -> [Bookmark] {
            nodes.flatMap { $0.isFolder ? sites($0.children ?? []) : [$0] }
        }
        let carried = sites(roots).filter { !$0.destinations.isEmpty }.map { node in
            Bookmark.folder(node.title, node.destinations.map { Bookmark(title: $0.name, url: $0.url, children: nil) })
        }
        list(carried.isEmpty ? roots : roots + [.folder(environmentsFolder, carried)], depth: 0)
        return (lines.joined(separator: "\n") + "\n", carried.reduce(0) { $0 + ($1.children?.count ?? 0) })
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    /// Replaces `url` whole or not at all; returns the environments carried.
    static func write(_ roots: [Bookmark], to url: URL) throws -> Int {
        let file = html(roots)
        try Data(file.text.utf8).write(to: url, options: .atomic)
        return file.environments
    }

    /// Asks where, then writes off the main thread. `done` gets the file's
    /// name and the environments carried, or why it failed; a cancelled
    /// panel calls nothing.
    @MainActor
    static func choose(_ roots: [Bookmark], done: @escaping (String, Result<Int, Error>) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "Escale Bookmarks.html"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try write(roots, to: url) }
                }.value
                done(url.lastPathComponent, result)
            }
        }
        if let window = Links.window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(panel.runModal()) }
    }
}
