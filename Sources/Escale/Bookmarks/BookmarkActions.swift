import AppKit

// What a bookmark's right-click does besides filing it: one site in a new
// tab or its address on the clipboard, a whole folder in tabs, a site's title
// and address edited together. The column and the Bookmarks panel call the
// same actions, so their two menus cannot drift apart.
//
// A folder opened in tabs builds only its first page. The others wait with
// their address and title, as a restored session's tabs do, until they are
// looked at: twenty pages loading at once would cost more than the person
// asked for. Past `openAllAsk` sites it asks first, since a large folder is
// easier to open by mistake than to close.
//
// The edit is a sheet on the window, as a Space's questions are (Ask). An
// address that is empty or not a place is refused: the sheet comes back
// with what was typed and why, rather than saving half the edit.

extension Browser {
    /// More sites than this and Open All in Tabs asks first.
    static let openAllAsk = 15

    func openInNewTab(_ node: Bookmark) {
        guard let url = node.url.flatMap(URL.init(string:)) else { return }
        bookmarking = false
        bookmarksOpen = false
        open(url, foreground: true, from: active)
    }

    func copyLink(_ node: Bookmark) {
        guard let url = node.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    /// Every site in the folder, its folders' too, in order after the tab on
    /// screen; the first is the one shown.
    func openAll(_ folder: Bookmark) {
        let sites = FolderSearch.sites(folder.children ?? []).compactMap { site in
            site.url.flatMap(URL.init(string:)).map { (title: site.title, url: $0) }
        }
        guard !sites.isEmpty else { return }
        guard sites.count > Browser.openAllAsk else { openAll(sites); return }
        let alert = NSAlert()
        alert.messageText = "Open \(sites.count) tabs?"
        alert.informativeText = "Every site in “\(folder.title)” opens in a tab of its own."
        alert.addButton(withTitle: "Open All")
        alert.addButton(withTitle: "Cancel")
        present(alert) { [weak self] in if $0 { self?.openAll(sites) } }
    }

    private func openAll(_ sites: [(title: String, url: URL)]) {
        guard let first = sites.first else { return }
        bookmarking = false
        bookmarksOpen = false
        openWaiting(Array(sites.dropFirst()), after: open(first.url, foreground: true))
    }

    /// `title` and `address` are what was typed last time, when the address
    /// was refused.
    func editBookmark(_ node: Bookmark, in bookmarks: Bookmarks, title: String? = nil, address: String? = nil) {
        guard !node.isFolder else { return }
        let alert = NSAlert()
        alert.messageText = "Edit Bookmark"
        if address != nil { alert.informativeText = "Enter an address such as example.com or https://example.com/page." }
        let name = NSTextField(string: title ?? node.title)
        name.placeholderString = "Name"
        let link = NSTextField(string: address ?? node.url ?? "")
        link.placeholderString = "Address"
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Name"), name],
                                      [NSTextField(labelWithString: "Address"), link]])
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 260
        grid.frame.size = grid.fittingSize
        alert.accessoryView = grid
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = address == nil ? name : link
        present(alert) { [weak self, weak bookmarks] saved in
            guard saved, let bookmarks, bookmarks.find(node.id) != nil,
                  !bookmarks.edit(node.id, title: name.stringValue, address: link.stringValue) else { return }
            // After this sheet has gone, or the next one has nowhere to go.
            DispatchQueue.main.async {
                self?.editBookmark(node, in: bookmarks, title: name.stringValue, address: link.stringValue)
            }
        }
    }

    private func present(_ alert: NSAlert, _ done: @escaping (Bool) -> Void) {
        guard let window = Links.window else {
            done(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: window) { done($0 == .alertFirstButtonReturn) }
    }
}
