import AppKit
import SwiftUI
import WebKit
import Combine

// Chrome extensions, on WebKit.
//
// The engine is Apple's: WKWebExtension, the same one Safari runs its
// extensions on, reading the same manifest.json a Chrome extension ships.
// What is here is the browser's half of the contract — which tabs exist and
// which one is in front, what a new tab or a popup means in this window, who
// is asked for a permission and how — plus the Chrome Web Store install
// (Crx.swift) and the APIs WebKit doesn't have, filled in natively
// (ExtensionShims.swift, ExtensionNative.swift, ExtensionSocket.swift).
//
// Tab is a Swift class and the protocols are Objective-C ones, so each tab
// is represented to WebKit by a small adapter (ExtensionTabs.swift); the
// buttons in the bar are in ExtensionButtons.swift.
//
// Each Space has its own extensions, unless one set serves every Space
// (`sharesOne`, chosen once at Welcome). A tab carries one controller, which
// runs every extension it holds in every page attached to it, and an
// extension's sign-in lives in its controller: so it is a mode, not a choice
// per extension. Shared, the first Space's owner serves them all, its pages
// in a store that is no Space's, and each Space is a window to WebKit, the
// one on screen focused. Sites stay per Space either way: the tabs keep
// their Space's store.

/// One installed extension, as the list in Settings shows it.
struct Installed: Codable, Identifiable, Equatable {
    /// The Chrome Web Store id, or "local-…" for one loaded from a folder.
    let id: String
    var name: String
    var version: String
    var enabled: Bool
    var fromStore: Bool
    /// The permissions it was installed with, so an update that asks for more
    /// is asked about rather than slipped through.
    var permissions: [String]
    /// Kept in the row beside the menu rather than only in it. Optional, so
    /// a list written before there was pinning still reads.
    var pinned: Bool? = nil
    /// For one loaded from a folder: where that folder is, so Reload can
    /// bring the author's latest edits in.
    var source: String? = nil
}

@available(macOS 15.4, *)
@MainActor
final class Extensions: NSObject, ObservableObject {
    // A controller's contexts and WebKit storage cannot be retargeted after
    // creation. Keep one owner per space, including parked spaces.
    private static var owners: [UUID: Extensions] = [:]
    static var shared: Extensions { forSpace(Spaces.current) }

    /// One set of extensions for every Space, chosen at Welcome. Absent is
    /// per Space, what there was before the choice.
    nonisolated static var sharesOne: Bool { Store.settings.bool(forKey: "extensions.shared") }

    /// The Space whose owner serves `space`: its own, or the first's.
    nonisolated static func owner(of space: UUID, sharing: Bool = sharesOne) -> UUID { sharing ? Space.firstID : space }

    /// What a Space keeps installed, read from its list without building its
    /// WebKit controller and data store: a transfer file must not wake Spaces.
    static func saved(space: UUID) -> [Installed] {
        let space = owner(of: space)
        if let owner = owners[space] { return owner.installed }
        let folder = Store.file(space == Space.firstID ? "Extensions" : "Extensions-\(space.uuidString)")
        let data = try? Data(contentsOf: folder.appendingPathComponent("installed.json"))
        return data.flatMap { try? JSONDecoder().decode([Installed].self, from: $0) } ?? []
    }

    static func forSpace(_ space: UUID) -> Extensions {
        let space = owner(of: space)
        if let owner = owners[space] { return owner }
        let owner = Extensions(space: space)
        owners[space] = owner
        return owner
    }

    static func erase(space: UUID) {
        guard space != Space.firstID else { return }
        let owner = owners.removeValue(forKey: space)
        owner?.stop()
        // Per-extension grants and configuration use the space suffix. Their
        // folder is removed below; neither may be inherited by another space.
        let suffix = ".\(space.uuidString)"
        for key in Store.settings.dictionaryRepresentation().keys
            where key.hasPrefix("extensions.") && key.hasSuffix(suffix) {
            Store.settings.removeObject(forKey: key)
        }
        let folder = Store.file("Extensions-\(space.uuidString)")
        try? FileManager.default.removeItem(at: folder)
    }

    /// Every page view built for a tab is handed the controller at birth —
    /// it can't be given one later.
    static func attach(_ configuration: WKWebViewConfiguration, space: UUID) {
        configuration.webExtensionController = forSpace(space).controller
    }

    let space: UUID
    /// Serving every Space rather than its own (`sharesOne`).
    private(set) var shared: Bool
    /// Made again only by Welcome's choice, before any extension (`remake`).
    private(set) var controller: WKWebExtensionController
    @Published private(set) var installed: [Installed] = []
    /// The loaded ones, by id.
    @Published private(set) var contexts: [String: WKWebExtensionContext] = [:]
    /// Bumped when any extension's button changes — icon, badge, enabled.
    @Published private(set) var actionsChanged = 0
    @Published private(set) var busy: String?
    /// Why the last store install of an id failed, for the row that asked.
    @Published private(set) var failed: [String: String] = [:]
    /// Errors an extension's pages and worker ran into, newest last, a few
    /// dozen at most per extension.
    @Published private(set) var errors: [String: [String]] = [:]

    func noteError(_ text: String, for id: String) {
        var list = errors[id] ?? []
        list.append(text)
        errors[id] = Array(list.suffix(40))
    }

    weak var browser: Browser?
    private var adapters: [Tab.ID: ExtensionTab] = [:]
    /// Each window's tabs, in the order WebKit was last told.
    private var order: [UUID: [Tab.ID]] = [:]
    private var watching: [Tab.ID: [AnyCancellable]] = [:]
    private var bag = Set<AnyCancellable>()
    /// A window per Space this owner sees, by Space, and those WebKit was
    /// told are open.
    private var windows: [UUID: ExtensionWindow] = [:]
    private var opened: [UUID] = []
    private var focused: UUID?

    func window(_ space: UUID) -> ExtensionWindow {
        if let made = windows[space] { return made }
        let made = ExtensionWindow(owner: self, space: space)
        windows[space] = made
        return made
    }

    /// The window in front: the Space on screen's.
    var window: ExtensionWindow { window(here) }

    /// The Space this owner answers for when nothing says which: its own,
    /// or, serving every Space, the one on screen.
    var here: UUID { shared ? browser?.spaceID ?? space : space }

    /// Whose set this is, for the surfaces that say it: "every Space", or
    /// its Space's name. Nil with Spaces off, where there is one set.
    var whose: String? {
        guard let browser, browser.prefs.usesSpaces else { return nil }
        return shared ? "every Space" : browser.spaces.first { $0.id == space }?.name
    }
    /// Where each extension's button is on screen, for its popup to hang from.
    var anchors: [String: WeakView] = [:]

    var folder: URL {
        Store.file(space == Space.firstID ? "Extensions" : "Extensions-\(space.uuidString)")
    }

    /// An extension's pages are served from chrome-extension://<id>/, the
    /// address they have in Chrome — Escale uses the same ids. Servers allow
    /// their own extension in by that origin (Raindrop's refuses any other),
    /// and sites look for an extension at it. WebKit's own
    /// webkit-extension:// is what Escale used before; addresses kept from
    /// then are read as the new ones.
    static let scheme = "chrome-extension"
    static let formerScheme = "webkit-extension"

    static func current(_ url: URL) -> URL {
        guard url.scheme == formerScheme, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.scheme = scheme
        return parts.url ?? url
    }
    private var list: URL { folder.appendingPathComponent("installed.json") }
    func folder(for id: String) -> URL { folder.appendingPathComponent(id, isDirectory: true) }

    func settingKey(_ family: String, _ id: String? = nil) -> String {
        let base = "extensions.\(family)" + (id.map { ".\($0)" } ?? "")
        return space == Space.firstID ? base : "\(base).\(space.uuidString)"
    }

    func scope(_ id: String) -> String { "\(space.uuidString)/\(id)" }

    private init(space: UUID) {
        self.space = space
        shared = space == Space.firstID && Extensions.sharesOne
        WKWebExtension.MatchPattern.registerCustomURLScheme(Extensions.scheme)
        controller = Extensions.controller(space: space, shared: shared)
        super.init()
        controller.delegate = self
        installed = (try? JSONDecoder().decode([Installed].self, from: Data(contentsOf: list))) ?? []
    }

    private static func controller(space: UUID, shared: Bool) -> WKWebExtensionController {
        // A test run keeps its extensions' storage apart, as it does its
        // cookies and passwords.
        let configuration: WKWebExtensionController.Configuration = space != Space.firstID
            ? .init(identifier: space)
            : (Store.testing && !Store.ownContainer ? .init(identifier: Store.probeStore(2)) : .default())
        // Shared, an extension's pages are no Space's: `chrome.cookies`
        // without a store id reads theirs, and clearing a Space keeps them.
        let pages = shared ? Store.extensionPages : Spaces.store(for: space)
        configuration.defaultWebsiteDataStore = pages
        let views = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        // Its own configuration starts with WebKit's default store; an
        // extension's pages keep what they store where the browser does —
        // and a test run's apart from the real one's.
        views.websiteDataStore = pages
        // The same user agent as the web tabs, to the letter. WebKit gives
        // workers the user agent of the last page that loaded and, when it
        // differs, stops the running workers to apply it — and extension
        // workers it then never starts again: every page that opened killed
        // the extensions. Extensions are told they run in Chrome by the shim
        // instead (navigator.userAgent in their pages and workers).
        views.applicationNameForUserAgent = Web.userAgentName
        // A test run sits behind other windows, where WebKit slows its views
        // to a crawl and messages between an extension's popup and its
        // worker stop arriving. Not what anyone is testing.
        if Store.testing, !Store.measuring, !Store.beta { views.preferences.inactiveSchedulingPolicy = .none }
        configuration.webViewConfiguration = views
        return WKWebExtensionController(configuration: configuration)
    }

    /// The first Space's owner is made at launch, in the mode stored then;
    /// Welcome's choice, made before any extension is installed, makes its
    /// controller again for the other. Tabs made with the old one are made
    /// again by the caller (ExtensionMode.swift).
    private func remake() {
        let sharing = space == Space.firstID && Extensions.sharesOne
        guard sharing != shared, contexts.isEmpty else { return }
        let browser = browser
        for space in opened { controller.didCloseWindow(window(space)) }
        bag.removeAll()
        adapters = [:]
        order = [:]
        watching = [:]
        windows = [:]
        opened = []
        focused = nil
        shared = sharing
        controller = Extensions.controller(space: space, shared: sharing)
        controller.delegate = self
        self.browser = nil
        if let browser { start(for: browser) }
    }

    /// After Welcome's choice is stored: the owners made for the other mode
    /// are let go, or made again for the first Space.
    static func adopt() {
        if sharesOne {
            for (space, owner) in owners where space != Space.firstID {
                owner.stop()
                owners[space] = nil
            }
        }
        owners[Space.firstID]?.remake()
    }

    // MARK: - starting

    func start(for browser: Browser) {
        guard self.browser == nil else { return }
        self.browser = browser
        browser.$tabs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.follow() }
            .store(in: &bag)
        browser.$activeID
            .removeDuplicates()
            .scan((nil, nil)) { ($0.1, $1) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pair in self?.activated(from: pair.0, to: pair.1) }
            .store(in: &bag)
        browser.$spaceID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.follow() }
            }
            .store(in: &bag)
        // A Space made or deleted is a window opened or closed.
        if shared {
            browser.$spaces
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.follow() }
                .store(in: &bag)
        }
        // Once the window is up: loading one takes the main thread for tens
        // of milliseconds (uBlock Origin Lite, 45), and the first frame
        // waited behind it.
        Links.onceShown { [weak self] in
            Task { [weak self] in
                guard let self else { return }
                // One after another, a moment apart: started all at once, WebKit
                // fails some of their workers and never tries them again.
                for item in installed where item.enabled {
                    await load(item)
                    if contexts[item.id]?.webExtension.hasBackgroundContent == true {
                        try? await Task.sleep(for: .milliseconds(400))
                    }
                }
                checkForUpdates()
            }
        }
        follow()
    }

    private func stop() {
        bag.removeAll()
        // A deleted Space's tabs are closed while it is parked, which `follow`
        // never sees: their watches go here, or they hold this owner for good.
        watching = [:]
        for id in Array(contexts.keys) { unload(id) }
        for observer in errorWatchers.values { NotificationCenter.default.removeObserver(observer) }
        errorWatchers = [:]
        ExtensionShims.release(space: space)
        for space in opened { controller.didCloseWindow(window(space)) }
        opened = []
        browser = nil
    }

    /// The Spaces this owner sees: its own, or, serving every Space, each
    /// with a row, on screen or parked, in the rail's order.
    private var seenSpaces: [UUID] {
        guard let browser else { return [] }
        guard shared else { return [space] }
        return browser.spaces.map(\.id).filter { $0 == browser.spaceID || browser.parked[$0] != nil }
    }

    private func row(_ space: UUID) -> [Tab] {
        guard let browser else { return [] }
        let tabs = browser.spaceID == space ? browser.tabs : browser.parked[space]?.tabs ?? []
        return tabs.filter { $0.space == space }
    }

    // MARK: - the row, as WebKit sees it

    func adapter(for tab: Tab) -> ExtensionTab {
        if let known = adapters[tab.id] { return known }
        let made = ExtensionTab(tab: tab, owner: self)
        adapters[tab.id] = made
        return made
    }

    /// Private tabs keep nothing and see no extensions, unless Settings ›
    /// Extensions says they may — and then only the ones made since, which
    /// carry the controller; one made before the switch has no page an
    /// extension could reach.
    private func seen(_ tab: Tab) -> Bool { !tab.shy || tab.carriesExtensions }
    func visibleTabs(in space: UUID) -> [Tab] { row(space).filter(seen) }
    /// The window in front's: what a tab's place in the row is counted in.
    var visibleTabs: [Tab] { visibleTabs(in: here) }

    /// The tab selected in a Space's window: the one on screen's, or a
    /// parked Space's when one owner serves them all.
    func activeID(in space: UUID) -> Tab.ID? {
        guard let browser else { return nil }
        if browser.spaceID == space { return browser.activeID }
        return shared ? browser.parked[space]?.active : nil
    }

    func activeAdapter(in space: UUID) -> ExtensionTab? {
        guard let id = activeID(in: space), let tab = row(space).first(where: { $0.id == id }), seen(tab) else { return nil }
        return adapter(for: tab)
    }

    var activeAdapter: ExtensionTab? {
        guard let browser, browser.spaceID == here, let tab = browser.active, seen(tab) else { return nil }
        return adapter(for: tab)
    }

    /// Each window holds its Space's row, including while that Space is
    /// parked: switching the visible Space does not report its tabs as
    /// closed, only which window is in front. Actual closes and moves are
    /// reported to the owner of the tab's Space; parked pages and their
    /// content scripts retain the same owner.
    private func follow() {
        let spaces = seenSpaces
        for space in opened where !spaces.contains(space) {
            for id in order[space] ?? [] {
                if let adapter = adapters[id] { controller.didCloseTab(adapter, windowIsClosing: true) }
                adapters[id] = nil
                watching[id] = nil
            }
            order[space] = nil
            controller.didCloseWindow(window(space))
            windows[space] = nil
        }
        opened.removeAll { !spaces.contains($0) }
        for space in spaces {
            if !opened.contains(space) {
                opened.append(space)
                controller.didOpenWindow(window(space))
            }
            follow(space)
        }
        if shared, let browser, focused != browser.spaceID {
            if focused != nil { controller.didFocusWindow(window(browser.spaceID)) }
            focused = browser.spaceID
        }
    }

    private func follow(_ space: UUID) {
        let now = visibleTabs(in: space)
        let ids = now.map(\.id)
        let order = order[space] ?? []
        let gone = order.filter { !ids.contains($0) }
        for id in gone {
            if let adapter = adapters[id] { controller.didCloseTab(adapter, windowIsClosing: false) }
            adapters[id] = nil
            watching[id] = nil
        }
        for tab in now where !order.contains(tab.id) {
            controller.didOpenTab(adapter(for: tab))
            watch(tab)
        }
        // Moves: anything whose position changed among the ones that stayed.
        let stayed = order.filter { ids.contains($0) }
        let newOrder = ids.filter { stayed.contains($0) }
        for (index, id) in stayed.enumerated() where newOrder.firstIndex(of: id) != index {
            if let adapter = adapters[id] { controller.didMoveTab(adapter, from: index, in: window(space)) }
        }
        self.order[space] = ids
    }

    private func watch(_ tab: Tab) {
        let id = tab.id
        func changed(_ properties: WKWebExtension.TabChangedProperties) {
            guard let adapter = adapters[id] else { return }
            controller.didChangeTabProperties(properties, for: adapter)
        }
        watching[id] = [
            tab.$title.dropFirst().removeDuplicates().sink { _ in changed(.title) },
            tab.$address.dropFirst().removeDuplicates().sink { _ in changed(.URL) },
            tab.$loading.dropFirst().removeDuplicates().sink { _ in changed(.loading) },
            tab.$pin.dropFirst().map { $0 != nil }.removeDuplicates().sink { _ in changed(.pinned) },
        ]
    }

    private func activated(from old: Tab.ID?, to new: Tab.ID?) {
        let space = here
        guard let new, let tab = browser?.tabs.first(where: { $0.id == new && $0.space == space }), seen(tab) else { return }
        // Another Space brought in is another window in front, not a tab
        // selected in it (see `follow`).
        if shared, let old, browser?.parkedTabs.contains(where: { $0.id == old }) == true {
            actionsChanged += 1
            return
        }
        let previous = old.flatMap { id in browser?.tabs.first(where: { $0.id == id && $0.space == space }) }.map(adapter(for:))
        controller.didActivateTab(adapter(for: tab), previousActiveTab: previous)
        actionsChanged += 1
    }

    // MARK: - loading

    @discardableResult
    private func load(_ item: Installed) async -> Bool {
        // The shim this build of Escale carries, in place of whatever the
        // build that installed it carried — away from the main thread: the
        // first launch after an update reads and rewrites every script and
        // page each extension ships (Grammarly: 450 ms).
        let folder = folder(for: item.id)
        try? await Task.detached(priority: .userInitiated) { try ExtensionShims.prepare(folder) }.value
        do {
            let found = try await WKWebExtension(resourceBaseURL: folder)
            let context = WKWebExtensionContext(for: found)
            context.uniqueIdentifier = item.id
            // The same origin every launch. WebKit picks a fresh one
            // otherwise, and everything an extension keeps in its own pages
            // — localStorage, IndexedDB — is filed under its origin.
            if let stable = URL(string: "\(Extensions.scheme)://\(item.id)/") { context.baseURL = stable }
            context.isInspectable = true
            // Installing was the consent: everything it asked for then is
            // granted each time it loads. Optional ones are asked for when
            // the extension asks.
            for permission in found.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
            for pattern in found.allRequestedMatchPatterns {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
            try controller.load(context)
            watch(context)
            if contexts[item.id] == nil, loadsThisRun.contains(item.id) { loadedBefore.insert(item.id) }
            loadsThisRun.insert(item.id)
            contexts[item.id] = context
            actionsChanged += 1
            return true
        } catch {
            NSLog("Extensions: couldn't load %@: %@", item.id, error.localizedDescription)
            return false
        }
    }

    private func unload(_ id: String) {
        guard let context = contexts[id] else { return }
        ExtensionSpeech.shared.release(scope: scope(id))
        try? controller.unload(context)
        contexts[id] = nil
        actionsChanged += 1
    }

    private func save() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(installed).write(to: list, options: .atomic)
    }

    // MARK: - installing

    /// A store link or an id, from the field in Settings or the bar that
    /// shows on a store page.
    /// `confirm: false` is for the bench in a test run only — there is no
    /// way to reach it from the real browser.
    func install(from text: String, confirm: Bool = true) {
        guard let id = Crx.id(in: text) else {
            browser?.announce(Crx.Refused.notAnID.localizedDescription)
            return
        }
        if installed.contains(where: { $0.id == id }) {
            browser?.announce("Already installed")
            return
        }
        busy = id
        failed[id] = nil
        Task {
            defer { busy = nil }
            do {
                let crx = try await Crx.fetch(id)
                let zip = try Crx.verifiedZip(crx, id: id)
                let target = folder(for: id)
                let staged = folder.appendingPathComponent(".staging-\(id)", isDirectory: true)
                try Crx.unpack(zip, into: staged)
                try ExtensionShims.prepare(staged)
                try await admit(staged, as: id, fromStore: true, finalFolder: target, confirm: confirm || !Store.testing)
            } catch {
                failed[id] = error.localizedDescription
                browser?.announce(error.localizedDescription)
            }
        }
    }

    /// An unpacked extension from disk — a developer's own, or one exported
    /// from another browser. Copied in, so moving the original breaks nothing.
    func installFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Load Extension"
        panel.message = "Choose the folder that holds the extension's manifest.json."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        installFolder(at: source)
    }

    func installFolder(at source: URL, confirm: Bool = true) {
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
            browser?.announce("That folder has no manifest.json")
            return
        }
        let id = "local-" + String(UUID().uuidString.prefix(8)).lowercased()
        let staged = folder.appendingPathComponent(".staging-\(id)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.copyItem(at: source, to: staged)
            try ExtensionShims.prepare(staged)
        } catch {
            browser?.announce("Couldn't copy the extension")
            return
        }
        Task { try? await admit(staged, as: id, fromStore: false, finalFolder: folder(for: id), confirm: confirm || !Store.testing, source: source) }
    }

    /// Takes the extension up again — the way Chrome's reload button does
    /// in developer mode. One loaded from a folder is copied in afresh from
    /// that folder first, so what its author just saved is what runs.
    func reload(_ id: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        let target = folder(for: id)
        if let path = installed[index].source {
            let source = URL(fileURLWithPath: path, isDirectory: true)
            let files = FileManager.default
            guard files.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
                browser?.announce("The folder \(installed[index].name) was loaded from is gone")
                return
            }
            let staged = folder.appendingPathComponent(".staging-\(id)", isDirectory: true)
            do {
                try? files.removeItem(at: staged)
                try files.copyItem(at: source, to: staged)
                try ExtensionShims.prepare(staged)
                try? files.removeItem(at: target)
                try files.moveItem(at: staged, to: target)
            } catch {
                try? files.removeItem(at: staged)
                browser?.announce("Couldn't copy \(installed[index].name) again")
                return
            }
        }
        unload(id)
        errors[id] = nil
        Task {
            if let found = try? await WKWebExtension(resourceBaseURL: target),
               let index = installed.firstIndex(where: { $0.id == id }) {
                installed[index].name = found.displayName ?? installed[index].name
                installed[index].version = found.version ?? installed[index].version
                installed[index].permissions = found.requestedPermissions.map(\.rawValue).sorted()
                save()
            }
            guard let item = installed.first(where: { $0.id == id }), item.enabled else { return }
            browser?.announce(await load(item) ? "\(item.name) reloaded" : "\(item.name) couldn't start — see Settings › Extensions")
        }
    }

    /// An extension whose worker won't start again: unloaded and loaded,
    /// as a relaunch would — at most once a minute, so one that can never
    /// start doesn't go round in circles.
    private var revived: [String: Date] = [:]
    /// Recent failed native messages, per extension and host.
    private var failures: [String: [Date]] = [:]

    /// Loaded at least once since the browser started, and loaded again.
    private var loadsThisRun: Set<String> = []
    private(set) var loadedBefore: Set<String> = []

    func revive(_ id: String, because reason: String) {
        guard let item = installed.first(where: { $0.id == id }), item.enabled,
              Date().timeIntervalSince(revived[id] ?? .distantPast) > 60 else { return }
        revived[id] = Date()
        noteError("restarted the extension: \(reason)", for: id)
        // Its popup goes with it; it is opened again once the extension is back.
        let popup = ExtensionPopup.shared.extensionID == id ? ExtensionPopup.shared.view?.url : nil
        let anchor = anchors[id]?.view?.window != nil ? anchors[id]?.view : anchors[Extensions.menuAnchor]?.view
        unload(id)
        Task {
            guard await load(item), browser?.spaceID == here,
                  let popup, let context = contexts[id] else { return }
            ExtensionPopup.shared.show(popup, for: context, from: anchor)
        }
    }

    /// WebKit records a worker that failed to start as an error on its
    /// context, and then doesn't try again: the extension would be dead
    /// until someone noticed. It is taken up afresh as soon as that shows.
    private var errorWatchers: [String: NSObjectProtocol] = [:]
    private func watch(_ context: WKWebExtensionContext) {
        let id = context.uniqueIdentifier
        if let old = errorWatchers[id] { NotificationCenter.default.removeObserver(old) }
        errorWatchers[id] = NotificationCenter.default.addObserver(forName: WKWebExtensionContext.errorsDidUpdateNotification, object: context, queue: .main) { [weak self, weak context] _ in
            MainActor.assumeIsolated {
                guard let self, let context, self.contexts[id] === context else { return }
                let failed = context.errors.contains { error in
                    let e = error as NSError
                    return e.domain == WKWebExtensionContext.errorDomain && e.code == WKWebExtensionContext.Error.backgroundContentFailedToLoad.rawValue
                }
                guard failed else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.contexts[id] === context else { return }
                    self.revive(id, because: "its worker failed to start")
                }
            }
        }
    }

    func setPinned(_ id: String, _ on: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].pinned = on
        save()
        actionsChanged += 1
    }

    /// Reads what was unpacked, asks, and — on yes — moves it into place and
    /// loads it. On no, nothing is left behind.
    private func admit(_ staged: URL, as id: String, fromStore: Bool, finalFolder: URL, confirm: Bool = true, source: URL? = nil) async throws {
        let files = FileManager.default
        let found: WKWebExtension
        do {
            found = try await WKWebExtension(resourceBaseURL: staged)
        } catch {
            try? files.removeItem(at: staged)
            throw error
        }
        let name = found.displayName ?? id
        let wants = Extensions.describe(found, in: staged)
        let accepted = confirm ? await ask(install: name, wants: wants, icon: found.icon(for: CGSize(width: 64, height: 64))) : true
        guard accepted else {
            try? files.removeItem(at: staged)
            return
        }
        try? files.removeItem(at: finalFolder)
        try files.moveItem(at: staged, to: finalFolder)
        let item = Installed(
            id: id, name: name, version: found.version ?? "?", enabled: true, fromStore: fromStore,
            permissions: found.requestedPermissions.map(\.rawValue).sorted(),
            source: source?.path
        )
        installed.removeAll { $0.id == id }
        installed.append(item)
        save()
        // The first install settles the mode at the latest (see Welcome).
        if browser?.prefs.sharedExtensions == nil { browser?.prefs.sharedExtensions = false }
        browser?.installedExtension(item, in: space)
        if await load(item) {
            browser?.announce("\(name) is installed")
        } else {
            browser?.announce("\(name) is installed, but WebKit couldn't start it")
        }
    }

    func remove(_ id: String) {
        unload(id)
        errors[id] = nil
        setSettings([:], for: id)
        Store.settings.removeObject(forKey: settingKey("granted", id))
        loadsThisRun.remove(id)
        loadedBefore.remove(id)
        Store.settings.removeObject(forKey: settingKey("newtab", id))
        installed.removeAll { $0.id == id }
        save()
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    // MARK: - new tab pages

    /// The page an extension asks to show in new tabs, from the one added
    /// last — once you've said yes to it. Nil while nobody asks, or you
    /// said no.
    var newTabPage: URL? {
        guard let (id, url) = newTabCandidate else { return nil }
        return Store.settings.object(forKey: settingKey("newtab", id)) as? Bool == true ? url : nil
    }

    private var newTabCandidate: (String, URL)? {
        for item in installed.reversed() where item.enabled {
            if let url = contexts[item.id]?.overrideNewTabPageURL { return (item.id, url) }
        }
        return nil
    }

    /// Chrome asks the first time an extension's page takes the place of
    /// the new tab — an extension that did it quietly could be anything.
    /// Escale asks from the pending search and creates the page only if that
    /// same request is still current when the answer arrives.
    func offerNewTabPage() {
        guard let (id, url) = newTabCandidate, Store.settings.object(forKey: settingKey("newtab", id)) == nil,
              let name = installed.first(where: { $0.id == id })?.name else { return }
        guard let opening = browser?.field.opening, !opening.shy else { return }
        Task {
            let yes = await ask("Show “\(name)” in new tabs?", detail: "It asked to replace the new tab page. You can change this later in Settings › Extensions.",
                                icon: contexts[id]?.webExtension.icon(for: CGSize(width: 64, height: 64)), yes: "Keep It", no: "Don't Allow")
            Store.settings.set(yes, forKey: settingKey("newtab", id))
            if yes, let browser, browser.field.opening == opening, browser.field.typed.isEmpty {
                browser.open(url, foreground: true)
            }
        }
    }

    /// What an extension set through chrome.privacy and chrome.proxy.
    func settings(for id: String) -> [String: Any] {
        Store.settings.dictionary(forKey: settingKey("settings", id)) ?? [:]
    }

    func setSettings(_ values: [String: Any], for id: String) {
        if values.isEmpty { Store.settings.removeObject(forKey: settingKey("settings", id)) }
        else { Store.settings.set(values, forKey: settingKey("settings", id)) }
    }

    /// The extension, on and running, that asked the browser not to offer to
    /// save passwords — a password manager doing the saving itself.
    var passwordSavingTakenBy: String? {
        installed.first { $0.enabled && settings(for: $0.id)["privacy.services.passwordSavingEnabled"] as? Bool == false }?.name
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].enabled = on
        save()
        if on {
            Task { await load(installed[index]) }
        } else {
            unload(id)
        }
    }

    func openOptions(_ id: String) {
        guard let url = contexts[id]?.optionsPageURL else { return }
        browser?.open(url, foreground: true)
    }

    // MARK: - updates

    /// Once a day, the store is asked whether anything installed from it has
    /// a newer version; if so it is fetched, checked and swapped in. One that
    /// asks for more than it was installed with is asked about first.
    func checkForUpdates() {
        let key = settingKey("checked")
        let last = Store.settings.object(forKey: key) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 60 * 60 * 20 else { return }
        Store.settings.set(Date(), forKey: key)
        for item in installed where item.fromStore {
            Task { await update(item) }
        }
    }

    private func update(_ item: Installed) async {
        var parts = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        parts.queryItems = [
            URLQueryItem(name: "response", value: "updatecheck"),
            URLQueryItem(name: "prodversion", value: Crx.chromeVersion),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(item.id)&v=\(item.version)&uc"),
        ]
        guard let url = parts.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let xml = String(data: data, encoding: .utf8),
              xml.contains("status=\"ok\""),
              let version = xml.range(of: #"version="([^"]+)""#, options: .regularExpression)
                .map({ String(xml[$0].dropFirst(9).dropLast()) }),
              version != item.version
        else { return }
        do {
            let zip = try Crx.verifiedZip(try await Crx.fetch(item.id), id: item.id)
            let staged = folder.appendingPathComponent(".staging-\(item.id)", isDirectory: true)
            try Crx.unpack(zip, into: staged)
            try ExtensionShims.prepare(staged)
            let found = try await WKWebExtension(resourceBaseURL: staged)
            let wants = Set(found.requestedPermissions.map(\.rawValue))
            // Every site the installed version asks for was granted when it
            // was installed; the version on disk is the record of them.
            let before = try? await WKWebExtension(resourceBaseURL: folder(for: item.id))
            let reaches = before.map { Extensions.widens($0.allRequestedMatchPatterns, to: found.allRequestedMatchPatterns) } ?? true
            if !wants.isSubset(of: Set(item.permissions)) || reaches {
                guard await ask(install: "An update to \(item.name)", wants: Extensions.describe(found, in: staged), icon: found.icon(for: CGSize(width: 64, height: 64)), update: true) else {
                    try? FileManager.default.removeItem(at: staged)
                    return
                }
            }
            unload(item.id)
            let target = folder(for: item.id)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: staged, to: target)
            if let index = installed.firstIndex(where: { $0.id == item.id }) {
                installed[index].version = found.version ?? version
                installed[index].permissions = wants.sorted()
                save()
                if installed[index].enabled { await load(installed[index]) }
            }
        } catch {
            NSLog("Extensions: update of %@ failed: %@", item.id, error.localizedDescription)
        }
    }

    /// Whether an update reaches a site the installed version could not:
    /// each pattern it asks for must be covered by one already granted.
    static func widens(_ granted: Set<WKWebExtension.MatchPattern>, to asked: Set<WKWebExtension.MatchPattern>) -> Bool {
        !asked.allSatisfy { pattern in granted.contains { $0.matches(pattern) } }
    }

    /// The page the manifest names for the button, when WebKit hasn't said.
    static func popupURL(for context: WKWebExtensionContext) -> URL? {
        let manifest = context.webExtension.manifest
        let action = (manifest["action"] ?? manifest["browser_action"]) as? [String: Any]
        guard let path = action?["default_popup"] as? String, !path.isEmpty else { return nil }
        // Relative to the extension, and keeping a query it may carry.
        return URL(string: path, relativeTo: context.baseURL)?.absoluteURL
    }

    // MARK: - asking

    /// What an extension wants, in words.
    static func describe(_ found: WKWebExtension, in folder: URL) -> [String] {
        var out: [String] = []
        // Leaving out what Escale itself added to the manifest.
        let added = Set((try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(".escale-added")))) as? [String] ?? [])
        let declared = Set(((try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json")))) as? [String: Any])?["permissions"] as? [String] ?? [])
        let patterns = found.allRequestedMatchPatterns
        if patterns.contains(where: { $0.matchesAllHosts || $0.matchesAllURLs }) {
            out.append("Read and change everything on every website")
        } else if !patterns.isEmpty {
            let hosts = patterns.compactMap(\.host).filter { !$0.isEmpty }
            out.append("Read and change what's on " + (hosts.prefix(4).joined(separator: ", ")) + (hosts.count > 4 ? " and \(hosts.count - 4) more" : ""))
        }
        let words: [WKWebExtension.Permission: String] = [
            .tabs: "See your open tabs and their addresses",
            .cookies: "Read and change cookies",
            .webNavigation: "See where you go",
            .webRequest: "See the requests pages make",
            .declarativeNetRequest: "Block or change requests pages make",
            .clipboardWrite: "Write to the clipboard",
            .nativeMessaging: "Talk to apps on this Mac",
            .scripting: "Run scripts in pages",
        ]
        for (permission, sentence) in words where found.requestedPermissions.contains(permission) && !added.contains(permission.rawValue) {
            out.append(sentence)
        }
        // Chrome's own, which Escale answers itself.
        let ours: [(String, String)] = [
            ("userScripts", "Run scripts you add to it on websites"), ("history", "Read and change your history"),
            ("bookmarks", "Read and change your bookmarks"), ("downloads", "Manage your downloads"),
            ("privacy", "Change your privacy settings"), ("browsingData", "Clear your browsing data"),
            ("management", "See your other extensions"), ("notifications", "Show notifications"),
        ]
        for (name, sentence) in ours where declared.contains(name) { out.append(sentence) }
        return out
    }

    /// Says which set it joins: every Space's, or this Space's alone.
    private func ask(install name: String, wants: [String], icon: NSImage?, update: Bool = false) async -> Bool {
        let set = update ? nil : whose
        let title = switch (set, shared) {
        case (nil, _): "Add “\(name)” to Escale?"
        case (_, true): "Add “\(name)”?"
        case (let space?, false): "Add “\(name)” to “\(space)”?"
        }
        let reach = set.map { _ in shared ? "It will be available in every Space." : "Other Spaces keep their own extensions." }
        let can = wants.isEmpty ? "It doesn't ask for anything special." : "It will be able to:\n• " + wants.joined(separator: "\n• ")
        return await ask(title, detail: [reach, can].compactMap { $0 }.joined(separator: "\n\n"),
                         icon: icon, yes: "Add Extension", no: "Cancel")
    }

    /// An extension asking, through permissions.request, for one of the
    /// permissions Escale answers itself.
    func ask(more names: String, context: WKWebExtensionContext) async -> Bool {
        await ask("asks for more access", detail: names, context: context)
    }

    /// An extension asking, through downloads.open, to open a download in
    /// the app that handles it.
    func ask(open name: String, context: WKWebExtensionContext) async -> Bool {
        await ask("wants to open \u{201C}\(name)\u{201D}", detail: "It opens in the app your Mac uses for it.", context: context)
    }

    private func ask(_ question: String, detail: String, context: WKWebExtensionContext) async -> Bool {
        await ask(
            "\(context.webExtension.displayName ?? "An extension") \(question)",
            detail: detail, icon: context.webExtension.icon(for: CGSize(width: 64, height: 64)),
            yes: "Allow", no: "Don't Allow"
        )
    }

    /// The last question asked, so the next waits for its answer.
    private var question: Task<Bool, Never>?
    /// For the bench, in a test run only: answer every question this way
    /// instead of asking. Nil asks.
    var answerForTests: Bool?
    /// What was asked, for the bench.
    private(set) var asked: [String] = []

    /// One question at a time, as a sheet on the browser's window. An alert
    /// run modally would stop the whole browser — pages, downloads, every
    /// other extension — for as long as it waits, and an extension can ask
    /// when nobody is looking.
    private func ask(_ title: String, detail: String, icon: NSImage?, yes: String, no: String) async -> Bool {
        let before = question
        let task = Task { @MainActor [weak self] () -> Bool in
            _ = await before?.value
            self?.asked.append(title)
            if Store.testing, let answer = self?.answerForTests { return answer }
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = detail
            if let icon { alert.icon = icon }
            alert.addButton(withTitle: yes)
            alert.addButton(withTitle: no)
            guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
                return alert.runModal() == .alertFirstButtonReturn
            }
            return await withCheckedContinuation { done in
                alert.beginSheetModal(for: window) { done.resume(returning: $0 == .alertFirstButtonReturn) }
            }
        }
        question = task
        return await task.value
    }

    // MARK: - the buttons

    struct Button: Identifiable {
        let id: String
        let name: String
        let label: String
        let icon: NSImage?
        let badge: String
        let enabled: Bool
        let pinned: Bool
    }

    /// The list behind the puzzle button.
    @Published var menuOpen = false
    /// Where a popup hangs when its extension isn't pinned: the puzzle button.
    static let menuAnchor = "__menu"

    /// One per loaded extension that has something to press, in install order.
    var buttons: [Button] {
        _ = actionsChanged
        let tab = activeAdapter
        return installed.compactMap { item in
            guard let context = contexts[item.id], let action = context.action(for: tab) else { return nil }
            return Button(
                id: item.id,
                name: item.name,
                label: action.label.isEmpty ? item.name : action.label,
                icon: action.icon(for: CGSize(width: 16, height: 16)),
                badge: action.badgeText,
                enabled: action.isEnabled,
                pinned: item.pinned ?? false
            )
        }
    }

    func press(_ id: String) {
        guard let context = contexts[id], !ExtensionPopup.shared.closes(id) else { return }
        if let tab = activeAdapter { context.userGesturePerformed(in: tab) }
        // An extension that asked for its button to open its side panel.
        if ExtensionShims.panelOnClick.contains(scope(id)), context.action(for: activeAdapter)?.presentsPopup != true {
            ExtensionShims.openPanel(context, owner: self)
            return
        }
        // A popup is opened here, straight away. Left to WebKit, it builds
        // a popup of its own first, and closing that one in favour of
        // Escale's lost the new popup's first messages to its worker.
        if context.action(for: activeAdapter)?.presentsPopup == true, let url = popupURL(for: context) {
            let own = anchors[id]?.view
            ExtensionPopup.shared.show(url, for: context, from: own?.window != nil ? own : anchors[Extensions.menuAnchor]?.view)
            return
        }
        context.performAction(for: activeAdapter)
    }

    /// The page the button's popup is now: one the extension set for this
    /// tab or for all of them, else its manifest's.
    private func popupURL(for context: WKWebExtensionContext) -> URL? {
        let set = ExtensionShims.popups[scope(context.uniqueIdentifier)] ?? [:]
        let path = browser?.active.flatMap { set[$0.id.uuidString] } ?? set["*"]
        guard let path else { return Extensions.popupURL(for: context) }
        guard !path.isEmpty else { return nil }
        return URL(string: path, relativeTo: context.baseURL)?.absoluteURL
    }

    /// A keystroke an extension registered for.
    func take(_ event: NSEvent) -> Bool {
        for context in contexts.values where context.command(for: event) != nil {
            return context.performCommand(for: event)
        }
        return false
    }

    /// Right-click items an extension added, for the page's menu.
    func menuItems(for tab: Tab) -> [NSMenuItem] {
        guard seen(tab) else { return [] }
        let adapter = adapter(for: tab)
        return contexts.values.flatMap { $0.menuItems(for: adapter) }
    }
}

// MARK: - WebKit asks, the browser answers

@available(macOS 15.4, *)
extension Extensions: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        opened.map(window)
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        window
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        guard let browser, browser.spaceID == here else { return nil }
        let url = configuration.url ?? URL(string: "about:blank")!
        let tab = browser.open(url, foreground: configuration.shouldBeActive, atEnd: true)
        if configuration.shouldBePinned { browser.pin(tab) }
        return adapter(for: tab)
    }

    /// One window, on purpose. A new window's pages become tabs in this one.
    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionWindow)? {
        guard let browser, browser.spaceID == here else { return nil }
        for (index, url) in configuration.tabURLs.enumerated() {
            browser.open(url, foreground: index == 0 && configuration.shouldBeFocused, atEnd: true)
        }
        return window
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext) async throws {
        guard browser?.spaceID == here, let url = extensionContext.optionsPageURL else { return }
        browser?.open(url, foreground: true)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.Permission>, Date?) {
        let detail = permissions.map(\.rawValue).sorted().joined(separator: ", ")
        return await ask("asks for more access", detail: detail, context: extensionContext) ? (permissions, nil) : ([], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<URL>, Date?) {
        // WebKit asks this the way Safari does: whenever an extension reaches
        // for a page it has no host permission for — listing tabs, running a
        // script in one — often with nobody having touched anything. Chrome
        // never asks there: the extension has the sites its manifest named,
        // the page it was clicked on (activeTab), and the ones it asked for
        // through permissions.request. So neither does Escale.
        asked.append("(refused) \(extensionContext.webExtension.displayName ?? "?") → \(Set(urls.compactMap { $0.host() }).sorted().joined(separator: ", "))")
        return ([], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        let all = matchPatterns.contains { $0.matchesAllHosts || $0.matchesAllURLs }
        let what = all ? "every website" : matchPatterns.map(\.string).sorted().joined(separator: ", ")
        return await ask("wants to read and change \(what)", detail: "Until you remove the extension.", context: extensionContext) ? (matchPatterns, nil) : ([], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        actionsChanged += 1
    }

    /// The popup page, in a popover of the browser's own (ExtensionPopup
    /// says why): WebKit's view is only asked which page it would show.
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext) async throws {
        let url = action.popupWebView?.url ?? Extensions.popupURL(for: context)
        action.closePopup()
        guard browser?.spaceID == here, let url else { return }
        let own = anchors[context.uniqueIdentifier]?.view
        let anchor = own?.window != nil ? own : anchors[Extensions.menuAnchor]?.view
        ExtensionPopup.shared.show(url, for: context, from: anchor)
    }

    /// `runtime.sendNativeMessage`. To "escale" — the APIs WebKit doesn't
    /// have, answered by this app. To anything else — a Chrome native
    /// messaging host installed on this Mac, spoken to the way Chrome would.
    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?, for extensionContext: WKWebExtensionContext) async throws -> Any? {
        if applicationIdentifier == nil || applicationIdentifier == ExtensionShims.application {
            return try await ExtensionShims.answer(message, from: extensionContext, owner: self)
        }
        let id = extensionContext.uniqueIdentifier, host = applicationIdentifier!
        do {
            return try await ExtensionNative.send(message, to: host, from: id)
        } catch {
            // An extension asking an app that isn't there, over and over —
            // a retry loop — is answered slowly once it has asked a dozen
            // times in a second, so it can't swamp the browser.
            let key = id + "→" + host, now = Date()
            failures[key] = (failures[key] ?? []).filter { now.timeIntervalSince($0) < 1 } + [now]
            if (failures[key]?.count ?? 0) > 12 { try? await Task.sleep(for: .seconds(1)) }
            throw error
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort, for extensionContext: WKWebExtensionContext) async throws {
        if port.applicationIdentifier == ExtensionSocket.name {
            ExtensionSocket.connect(port, from: extensionContext.uniqueIdentifier)
            return
        }
        try ExtensionNative.connect(port, from: extensionContext.uniqueIdentifier)
    }
}
