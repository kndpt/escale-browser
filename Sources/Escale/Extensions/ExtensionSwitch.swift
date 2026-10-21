// How extensions are kept, changed after Welcome: for whoever arrived before
// the choice existed, or wants the other answer. Owners, controllers and
// every tab are built for one mode at launch, and two controllers on one
// identifier lose each other's writes (Extensions.swift), so the new mode is
// stored and Escale relaunches rather than rebuilding them live. Nothing is
// deleted: the first Space's set is the shared one, every other Space's own
// set stays in its folder and is read again on the way back, and what a
// Space would lose sight of is listed to reinstall.
import AppKit

extension Browser {
    /// Asks, then stores the other mode and relaunches.
    func askToSwitchExtensions() {
        guard #available(macOS 15.4, *) else { return }
        let sharing = prefs.sharedExtensions != true
        let first = spaces.first(where: \.isFirst)?.name ?? "the first Space"
        let alert = NSAlert()
        if sharing {
            alert.messageText = "Use the same extensions in every Space?"
            alert.informativeText = "“\(first)”’s extensions will run in every Space, with their settings; some may ask you to sign in again. "
                + "Those only other Spaces have are listed to reinstall. Nothing is deleted, and switching back brings them back. "
                + "Sites and sign-ins stay separate in every Space. Escale relaunches."
            alert.addButton(withTitle: "Share and Relaunch")
        } else {
            alert.messageText = "Give each Space its own extensions?"
            alert.informativeText = "The extensions you have now stay in “\(first)”. Other Spaces get back the ones they had before "
                + "and list the rest to reinstall. Nothing is deleted. Escale relaunches."
            alert.addButton(withTitle: "Separate and Relaunch")
        }
        alert.addButton(withTitle: "Cancel")
        Ask.show(alert) { [weak self] ok in
            guard ok, let self else { return }
            if self.keepExtensions(shared: sharing) {
                Updater.shared.relaunch()
            } else {
                self.announce("Couldn't change how extensions are kept")
            }
        }
    }

    /// Stores `shared` as the mode, with every Space's list to reinstall;
    /// false, and nothing changed, if the list couldn't be written. Takes
    /// effect at the next launch.
    @discardableResult
    func keepExtensions(shared: Bool) -> Bool {
        guard #available(macOS 15.4, *) else { return false }
        var sets: [UUID: [Installed]] = [:]
        for space in spaces { sets[space.id] = Extensions.saved(space: space.id, sharing: false) }
        let replanned = Browser.replanned(spaces, sharing: shared, sets: sets)
        guard Spaces.write(replanned) else { return false }
        spaces = replanned
        prefs.sharedExtensions = shared
        return true
    }

    /// Every Space's list to reinstall under `sharing`, from what each Space
    /// keeps of its own (`sets`). Shared, the first's set serves them all and
    /// a Space lists what only it had; per Space, a Space lists what the
    /// first has and it doesn't. What a Space then holds leaves its list.
    nonisolated static func replanned(_ spaces: [Space], sharing: Bool, sets: [UUID: [Installed]]) -> [Space] {
        let first = sets[Space.firstID] ?? []
        return spaces.map { space in
            let own = sets[space.id] ?? []
            let held = sharing || space.isFirst ? first : own
            let gained = space.isFirst ? [] : (sharing ? own : first)
                .map { PlannedExtension(name: $0.name, storeID: $0.fromStore ? $0.id : nil) }
            var plan: [PlannedExtension] = []
            for item in (space.plannedExtensions ?? []) + gained
                where !plan.contains(item) && !held.contains(where: item.names) {
                plan.append(item)
            }
            var made = space
            made.plannedExtensions = plan.isEmpty ? nil : plan
            return made
        }
    }
}
