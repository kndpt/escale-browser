// A Space can be copied as an organisation, never as a live browser session.
// The copy receives new file and bookmark identities. Its page addresses stay
// exactly as written in the source, while WebKit stores, secrets, history and
// extension contexts start empty. The space is published only after its
// value files have reached disk; a failed copy leaves no visible half-space.

import AppKit

struct PlannedExtension: Codable, Hashable {
    var name: String
    /// Nil for an unpacked extension: its folder must be chosen again.
    var storeID: String?

    /// Whether `item` is this one installed: by store id, or by name for an
    /// unpacked one.
    func names(_ item: Installed) -> Bool {
        item.fromStore ? storeID == item.id : storeID == nil && name == item.name
    }
}

extension Browser {
    func askToDuplicateSpace(_ id: UUID) {
        guard let source = spaces.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Duplicate “\(source.name)”"
        // Shared extensions are already in the copy: only sites need a sign-in.
        alert.informativeText = "Copies pages, bookmarks, organisation and Space settings. The addresses still point to the same sites. "
            + (prefs.sharedExtensions == true ? "You'll need to sign in to sites again." : "You'll need to sign in to sites and set up extension accounts again.")
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
        // Shared, the copy runs the same extensions: nothing to reinstall.
        let shared = prefs.sharedExtensions == true
        var extensions: [PlannedExtension] = []
        if #available(macOS 15.4, *), !shared {
            extensions = Extensions.forSpace(id).installed.map {
                PlannedExtension(name: $0.name, storeID: $0.fromStore ? $0.id : nil)
            }
        }
        let plan = shared ? [] : (source.plannedExtensions ?? []) + extensions
        var made = source
        made.id = identifier
        made.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        made.sharesSignIns = nil
        var unique: [PlannedExtension] = []
        for item in plan where !unique.contains(item) {
            unique.append(item)
        }
        made.plannedExtensions = shared ? nil : unique

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

    /// Shared, an extension installed once is installed in every Space, so
    /// it leaves every Space's list.
    func installedExtension(_ item: Installed, in space: UUID) {
        dropPlanned(in: prefs.sharedExtensions == true ? nil : space) { $0.names(item) }
    }

    /// One the person chose not to reinstall: from every Space's list when
    /// one set serves them all.
    func forgetPlannedExtension(_ item: PlannedExtension, in space: UUID) {
        dropPlanned(in: prefs.sharedExtensions == true ? nil : space) { $0 == item }
    }

    /// The extensions to reinstall that the bar and Settings show: the Space
    /// on screen's, or, with one set for every Space, every Space's, once.
    var plannedExtensions: [PlannedExtension] {
        guard prefs.sharedExtensions == true else { return space.plannedExtensions ?? [] }
        var seen = Set<PlannedExtension>()
        return spaces.flatMap { $0.plannedExtensions ?? [] }.filter { seen.insert($0).inserted }
    }

    private func dropPlanned(in space: UUID? = nil, where match: (PlannedExtension) -> Bool) {
        var changed = false
        for index in spaces.indices where space == nil || spaces[index].id == space {
            var planned = spaces[index].plannedExtensions ?? []
            planned.removeAll(where: match)
            guard planned != (spaces[index].plannedExtensions ?? []) else { continue }
            spaces[index].plannedExtensions = planned
            changed = true
        }
        if changed { Spaces.write(spaces) }
    }
}
