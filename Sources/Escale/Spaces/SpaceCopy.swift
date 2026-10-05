// A Space can be copied as an organisation, never as a live browser session.
// The copy receives new file and bookmark identities. Its page addresses stay
// exactly as written in the source, while WebKit stores, secrets, history and
// extension contexts start empty. The space is published only after its
// value files have reached disk; a failed copy leaves no visible half-space.

import AppKit

struct PlannedExtension: Codable, Equatable {
    var name: String
    /// Nil for an unpacked extension: its folder must be chosen again.
    var storeID: String?
}

extension Browser {
    func askToDuplicateSpace(_ id: UUID) {
        guard let source = spaces.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Duplicate “\(source.name)”"
        alert.informativeText = "Copies pages, bookmarks, organisation and Space settings. The addresses still point to the same sites. You'll need to sign in to sites and set up extension accounts again."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "New Space name"
        field.stringValue = source.name + " Copy"
        alert.accessoryView = field
        alert.addButton(withTitle: "Duplicate")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let finish: (Bool) -> Void = { [weak self] accepted in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if accepted, !name.isEmpty { self?.duplicateSpace(id, named: name) }
        }
        if let window = Links.window {
            alert.beginSheetModal(for: window) { finish($0 == .alertFirstButtonReturn) }
        } else {
            finish(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    /// The saved row excludes private and bench tabs; grouped bookmarks keep
    /// an association remapped to the copied bookmark identities.
    /// Neither reading it nor writing the new row constructs a WKWebView.
    func duplicateSpace(_ id: UUID, named name: String, identifier: UUID = UUID()) {
        guard let source = spaces.first(where: { $0.id == id }),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              identifier != Space.firstID,
              !spaces.contains(where: { $0.id == identifier }) else { return }
        writeSession(of: id, now: true)
        let session = Session.read(space: id)
        let bookmarks = bookmarks(of: id).roots
        let hidden = curtain(for: id).byHost
        var extensions: [PlannedExtension] = []
        if #available(macOS 15.4, *) {
            extensions = Extensions.forSpace(id).installed.map {
                PlannedExtension(name: $0.name, storeID: $0.fromStore ? $0.id : nil)
            }
        }
        let plan = (source.plannedExtensions ?? []) + extensions
        var made = source
        made.id = identifier
        made.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        made.sharesSignIns = nil
        var unique: [PlannedExtension] = []
        for item in plan where !unique.contains(item) {
            unique.append(item)
        }
        made.plannedExtensions = unique

        let bookmarkIDs = Dictionary(uniqueKeysWithValues: Set(session.tabs.compactMap(\.bookmark)).map { ($0, UUID()) })
        let copiedSession = Session.copy(session, to: made.id, bookmarks: bookmarkIDs)
        let copiedBookmarks = copiedSession && Bookmarks.copy(bookmarks, to: made.id, identities: bookmarkIDs)
        let copiedHidden = copiedBookmarks && Curtain.copy(hidden, to: made.id)
        if copiedHidden {
            Shield.shared.copyPaused(from: id, to: made.id)
            for (host, zoom) in Store.zooms(in: id) {
                Store.settings.set(zoom, forKey: Store.zoomKey(host, space: made.id))
            }
        }
        guard copiedHidden, Spaces.write(spaces + [made]) else {
            Session.erase(space: made.id)
            Bookmarks.erase(space: made.id)
            Curtain.erase(space: made.id)
            Shield.shared.erase(space: made.id)
            Store.eraseZoom(space: made.id)
            announce("Couldn't duplicate the Space")
            return
        }
        spaces.append(made)
        announce("Duplicated “\(source.name)” as “\(made.name)”")
    }

    func installedExtension(_ item: Installed, in space: UUID) {
        guard let index = spaces.firstIndex(where: { $0.id == space }) else { return }
        var planned = spaces[index].plannedExtensions ?? []
        planned.removeAll {
            if item.fromStore { return $0.storeID == item.id }
            return $0.storeID == nil && $0.name == item.name
        }
        guard planned != (spaces[index].plannedExtensions ?? []) else { return }
        spaces[index].plannedExtensions = planned
        Spaces.write(spaces)
    }
}
