import Security
import SwiftUI

// Everything there is to set, in one observable place.
//
// Each of these is a line in the settings file and nothing more; the object
// exists so that a panel can bind to them and the rest of the window can
// redraw when one changes. Defaults are chosen so that a browser nobody has
// configured behaves the way it always did, except the faster shortcut
// transitions, adopted on purpose.

/// What a tab wears beside its title, and what a pinned one is reduced to: a
/// letter, or the site's own icon.
enum Glyph: String, CaseIterable, Identifiable {
    case letters, icons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .letters: return "Letters"
        case .icons: return "Site icons"
        }
    }
}

@MainActor
final class Preferences: ObservableObject {
    private let store = Store.settings

    /// The complete override snapshot is committed once, including collision removals.
    @Published var keyBindings: KeyBindings {
        didSet { if let data = keyBindings.data { store.set(data, forKey: "keyboard.bindings") } }
    }

    func keys(_ action: KeyAction) -> String { keyBindings.keys(action).map(\.label).joined(separator: " / ") }
    func keyHelp(_ action: KeyAction, _ title: String? = nil) -> String {
        let keys = keys(action)
        return (title ?? action.command.title) + (keys.isEmpty ? "" : "   " + keys)
    }

    /// A local socket a script can drive the browser through, in tabs of its
    /// own. Off unless asked for.
    @Published var bench: Bool {
        didSet { store.set(bench, forKey: "bench") }
    }
    /// Local tools may send short development events to macOS. Off unless
    /// asked for: otherwise there is no notification socket or OS prompt.
    @Published var developerAlerts: Bool {
        didSet { store.set(developerAlerts, forKey: "alerts.local") }
    }
    @Published var alertAgents: Bool { didSet { store.set(alertAgents, forKey: "alerts.agents") } }
    @Published var alertBuilds: Bool { didSet { store.set(alertBuilds, forKey: "alerts.builds") } }
    @Published var alertPRs: Bool { didSet { store.set(alertPRs, forKey: "alerts.prs") } }
    @Published var alertWorkflows: Bool { didSet { store.set(alertWorkflows, forKey: "alerts.workflows") } }
    /// Light, dark, or the Mac's own.
    @Published var look: Look {
        didSet {
            store.set(look.rawValue, forKey: "look")
            look.apply()
        }
    }
    /// How much of the desktop and the page shows through Escale's own
    /// surfaces (Glass.swift). Pages themselves stay opaque at every level.
    /// Stored as its name; absent or unknown reads as Subtle, the default
    /// for new and existing profiles alike, and Solid is the look before it.
    @Published var depth: Depth {
        didSet { store.set(depth.rawValue, forKey: "depth") }
    }
    /// Escale's own Increase Contrast: stronger edges, separators and
    /// secondary text, as the Mac's setting gives. Off unless asked for.
    @Published var increasesContrast: Bool {
        didSet {
            store.set(increasesContrast, forKey: "glass.contrast")
            Palette.contrast = increasesContrast
        }
    }
    /// Neutral greys or Escale's own warm colours, in either look
    /// (Palette.tone). Neutral unless asked for.
    @Published var tone: Tone {
        didSet {
            store.set(tone.rawValue, forKey: "tone")
            Palette.tone = tone
        }
    }
    /// Faster tab/layout transitions for shortcuts, including existing profiles.
    @Published var fasterShortcuts: Bool {
        didSet { store.set(fasterShortcuts, forKey: "motion.shortcuts") }
    }
    /// A button that copies the page's address: beside the title under the
    /// pointer in the bar over the page, at the right end of the tab row (see
    /// Where and CopyDoor in Bar.swift). On unless turned off; off, Copy
    /// Address stays in the site's card and on ⇧⌘C.
    @Published var copyDoor: Bool {
        didSet { store.set(copyDoor, forKey: "bar.copy") }
    }
    /// Only Escale's controls and panels grow; WebKit keeps its own zoom.
    @Published var interfaceSize: InterfaceSize {
        didSet { store.set(interfaceSize.rawValue, forKey: "interface.size") }
    }
    /// Titles down the left instead of across the top.
    @Published var sidebar: Bool {
        didSet { store.set(sidebar, forKey: "sidebar") }
    }
    /// The column folded away whenever the pointer isn't at the left edge,
    /// rather than only after ⌘S (see Fold.swift). Off unless asked for.
    @Published var sideHides: Bool {
        didSet { store.set(sideHides, forKey: "sidebar.hides") }
    }
    /// Back, forward, reload and the address in a bar over the page, in
    /// the column's mode (see Bar.swift). On unless turned off: the page's
    /// address in plain sight is part of working on a project.
    @Published var addressBar: Bool {
        didSet { store.set(addressBar, forKey: "sidebar.bar") }
    }
    /// The bookmarks in the column, above the tabs (see Shelf.swift). On
    /// unless turned off: they are where a space keeps its project's pages.
    @Published var sideBookmarks: Bool {
        didSet { store.set(sideBookmarks, forKey: "sidebar.bookmarks") }
    }
    /// Those bookmarks folded under their heading. Remembered.
    @Published var sideBookmarksFolded: Bool {
        didSet { store.set(sideBookmarksFolded, forKey: "sidebar.bookmarks.folded") }
    }
    /// How wide the column is. Pulled by its edge, and remembered.
    @Published var sideWidth: CGFloat {
        didSet { store.set(Double(sideWidth), forKey: "sidebar.width") }
    }
    @Published var glyph: Glyph {
        didSet { store.set(glyph.rawValue, forKey: "glyph") }
    }
    @Published var engine: Engine {
        didSet { store.set(engine.rawValue, forKey: "search.engine") }
    }
    @Published var customEngine: String {
        didSet { store.set(customEngine, forKey: "search.custom") }
    }
    /// Sites searched by a keyword typed first, one `word template` per line
    /// (Keyword in Engine.swift). Empty unless written.
    @Published var searchKeywords: String {
        didSet { store.set(searchKeywords, forKey: "search.keywords") }
    }
    /// Tabs nobody has looked at for `sleepDelay` give their page back and
    /// keep where they were. On unless turned off.
    @Published var sleepsTabs: Bool {
        didSet { store.set(sleepsTabs, forKey: "tabs.sleep") }
    }
    /// Half an hour unless chosen otherwise (see Sleep.swift).
    @Published var sleepDelay: SleepDelay {
        didSet { store.set(sleepDelay.rawValue, forKey: "tabs.sleep.after") }
    }
    @Published var showsReading: Bool {
        didSet { store.set(showsReading, forKey: "tabs.reading") }
    }
    /// The ad blocker. On unless turned off; there is nothing else to it.
    @Published var shielded: Bool {
        didSet { store.set(shielded, forKey: "shield") }
    }
    /// A private tab gets extensions too, not just every other page. Off
    /// unless asked for - a private tab keeps nothing by default, extensions
    /// included, and some watch what a page does.
    @Published var extensionsInPrivate: Bool {
        didSet { store.set(extensionsInPrivate, forKey: "extensions.private") }
    }
    /// Whether sites may ask for a passkey here. Off sends them to the
    /// password instead — the only thing that works in a build without
    /// Apple's browser entitlement.
    @Published var passkeys: Bool {
        didSet { store.set(passkeys, forKey: "passkeys") }
    }
    /// Whether this build can actually do them: signed with the entitlement,
    /// its profile embedded. Fixed for the life of the process.
    let passkeysPossible: Bool

    /// Asked of the running process's own signature, which is the only thing
    /// that decides it — a profile file in the bundle proves nothing on its
    /// own, and an ad-hoc build has neither.
    static var entitledToPasskeys: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.web-browser.public-key-credential" as CFString, nil
        )
        return (value as? Bool) == true
    }
    @Published var downloads: URL {
        didSet { store.set(downloads.path, forKey: "downloads") }
    }
    @Published var asksWhereToSave: Bool {
        didSet { store.set(asksWhereToSave, forKey: "downloads.ask") }
    }
    /// Offer to keep a password the first time a site sees it.
    @Published var savesPasswords: Bool {
        didSet { store.set(savesPasswords, forKey: "passwords.save") }
    }
    /// Put a kept name and password into a sign-in as soon as one appears.
    @Published var fillsPasswords: Bool {
        didSet { store.set(fillsPasswords, forKey: "passwords.fill") }
    }
    /// The first launch has been walked through. Until then the welcome
    /// stands over the window.
    @Published var welcomed: Bool {
        didSet { store.set(welcomed, forKey: "welcomed") }
    }
    /// A click of the wheel scrolls the page as on Windows (see AutoScroll.swift).
    /// On unless turned off.
    @Published var autoScroll: Bool {
        didSet {
            store.set(autoScroll, forKey: "autoscroll")
            AutoScroll.on = autoScroll
        }
    }
    /// Where a link goes, at the bottom of the page while the pointer is on
    /// it (see StatusLine.swift). On unless turned off.
    @Published var showsLinks: Bool {
        didSet {
            store.set(showsLinks, forKey: "links.show")
            HoveredLink.on = showsLinks
        }
    }
    /// Copy and Translate over text selected with the mouse (see
    /// SelectionMenu.swift). On unless turned off.
    @Published var selectionMenu: Bool {
        didSet {
            store.set(selectionMenu, forKey: "selection.menu")
            SelectionWatch.on = selectionMenu
        }
    }
    /// Separate sets of tabs, each with its own sign-ins (see Spaces.swift).
    /// On unless turned off: with one space, nothing more runs than without.
    @Published var usesSpaces: Bool {
        didSet { store.set(usesSpaces, forKey: "spaces") }
    }

    init() {
        keyBindings = KeyBindings.read(store.data(forKey: "keyboard.bindings"))
        // Carried over from when there were four ways of holding the browser
        // and this was one of them.
        // The Mac's own unless asked otherwise — a Mac in dark mode expects
        // a dark browser, pages included.
        bench = store.bool(forKey: "bench")
        developerAlerts = store.bool(forKey: "alerts.local")
        alertAgents = store.object(forKey: "alerts.agents") as? Bool ?? true
        alertBuilds = store.object(forKey: "alerts.builds") as? Bool ?? true
        alertPRs = store.object(forKey: "alerts.prs") as? Bool ?? true
        alertWorkflows = store.object(forKey: "alerts.workflows") as? Bool ?? true
        let chosen = store.string(forKey: "look").flatMap(Look.init) ?? .system
        look = chosen
        // Before the first window, and not deferred: the window that is about
        // to be made should be made in the right appearance. Through `shared`
        // rather than `NSApp`: on macOS 14 SwiftUI builds this before it has
        // made the application, and `NSApp` is still nil here.
        NSApplication.shared.appearance = chosen.appearance
        depth = Depth.stored(store.string(forKey: "depth"))
        fasterShortcuts = store.object(forKey: "motion.shortcuts") as? Bool ?? true
        copyDoor = store.object(forKey: "bar.copy") as? Bool ?? true
        let contrast = store.bool(forKey: "glass.contrast")
        increasesContrast = contrast
        // Before the first window is drawn, like the look.
        Palette.contrast = contrast
        let tone = Tone.stored(store.string(forKey: "tone"))
        self.tone = tone
        Palette.tone = tone
        interfaceSize = InterfaceSize.stored(store.string(forKey: "interface.size"))
        sidebar = store.object(forKey: "sidebar") as? Bool
            ?? (store.string(forKey: "manner") == "side")
        sideHides = store.bool(forKey: "sidebar.hides")
        addressBar = store.object(forKey: "sidebar.bar") as? Bool ?? true
        sideBookmarks = store.object(forKey: "sidebar.bookmarks") as? Bool ?? true
        sideBookmarksFolded = store.bool(forKey: "sidebar.bookmarks.folded")
        let width = store.object(forKey: "sidebar.width") as? Double ?? Double(Metrics.side)
        sideWidth = min(Metrics.sideMax, max(Metrics.sideMin, CGFloat(width)))
        glyph = store.string(forKey: "glyph").flatMap(Glyph.init) ?? .letters
        engine = store.string(forKey: "search.engine").flatMap(Engine.init) ?? .standard
        customEngine = store.string(forKey: "search.custom") ?? ""
        searchKeywords = store.string(forKey: "search.keywords") ?? ""
        sleepsTabs = store.object(forKey: "tabs.sleep") as? Bool ?? true
        sleepDelay = SleepDelay.stored(store.object(forKey: "tabs.sleep.after") as? Int)
        showsReading = store.object(forKey: "tabs.reading") as? Bool ?? true
        shielded = store.object(forKey: "shield") as? Bool ?? true
        extensionsInPrivate = store.bool(forKey: "extensions.private")
        // Offered by default only in a build that can actually do them —
        // one with Apple's browser entitlement and its profile embedded. A
        // choice made while they couldn't work is not a choice about them:
        // the first run of a build that can offers them, whatever was set
        // before; from then on the switch is the person's.
        let entitled = Preferences.entitledToPasskeys
        passkeysPossible = entitled
        if entitled, !store.bool(forKey: "passkeys.entitled") {
            passkeys = true
            store.set(true, forKey: "passkeys")
        } else {
            passkeys = store.object(forKey: "passkeys") as? Bool ?? entitled
        }
        store.set(entitled, forKey: "passkeys.entitled")
        // A test run downloads into its own folder: ~/Downloads would have
        // macOS stop it to ask for access, with a dialog on the screen of
        // whoever is working beside it.
        let testDownloads = Store.folder.appendingPathComponent("Downloads", isDirectory: true)
        if Store.testing { try? FileManager.default.createDirectory(at: testDownloads, withIntermediateDirectories: true) }
        downloads = Store.testing
            ? testDownloads
            : (store.string(forKey: "downloads")).map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        asksWhereToSave = store.bool(forKey: "downloads.ask")
        savesPasswords = store.object(forKey: "passwords.save") as? Bool ?? true
        fillsPasswords = store.object(forKey: "passwords.fill") as? Bool ?? true
        // Anyone who already has a session was here before the welcome
        // existed; they are not asked to sit through it.
        welcomed = store.bool(forKey: "welcomed") || store.object(forKey: "glyph") != nil
        usesSpaces = store.object(forKey: "spaces") as? Bool ?? true
        let links = store.object(forKey: "links.show") as? Bool ?? true
        showsLinks = links
        HoveredLink.on = links
        let selecting = store.object(forKey: "selection.menu") as? Bool ?? true
        selectionMenu = selecting
        SelectionWatch.on = selecting
        let scrolls = store.object(forKey: "autoscroll") as? Bool ?? true
        autoScroll = scrolls
        AutoScroll.on = scrolls
        // Left behind by the Web Inspector's switch, from before it was
        // always there.
        store.removeObject(forKey: "inspector")
        // Retired Web Pages options must not revive from an older profile.
        for key in ["autocorrect", "pages.120", "float.flicks", "float.away"] {
            store.removeObject(forKey: key)
        }
        // Before the first web view exists: WebKit reads these once.
        Preferences.configurePageText()
        // Left behind by an assistant this browser no longer has.
        for key in ["mind.model", "mind.effort", "mind.acting", "mind.width", "mind.open"] {
            store.removeObject(forKey: key)
        }
    }

    /// WebKit's text checker takes its orders from the app's standard
    /// defaults — not the test suite, because it is WebKit reading them and
    /// not us. A test run's standard defaults are its own copy's, never the
    /// real browser's (see Store.admit). Correction, smart quotes and dashes stay off
    /// outright: in a browser they are wrong in every code field and wanted
    /// in almost none.
    private static func configurePageText() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "WebAutomaticSpellingCorrectionEnabled")
        defaults.set(false, forKey: "WebAutomaticQuoteSubstitutionEnabled")
        defaults.set(false, forKey: "WebAutomaticDashSubstitutionEnabled")
    }
}
