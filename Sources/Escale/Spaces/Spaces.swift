import SwiftUI
import WebKit

// Spaces: separate sets of tabs in the one window, each with its own
// cookies and sign-ins, and a downloads folder of its own if you like.
//
// On unless turned off in Settings › Tabs & Spaces. Off, there is one space, the
// first, and nothing about it shows: its tabs are the session there has
// always been and its sites use the store there has always been, so
// turning spaces on signs nobody out.
//
// A space's sites live in a WebKit store of their own, made by identifier,
// and its history, downloads list, passwords, bookmarks, site settings and
// extensions carry that same identity. Switching swaps the row of tabs:
// the ones left behind are parked, their sound continues, and they sleep
// after half an hour as any tab does. ⌃1–⌃9 switch, as in Arc.

struct Space: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// Which of `Spaces.colours` — from before spaces had icons; kept so an
    /// older list still reads.
    var colour: Int
    /// Its icon, one of `Spaces.icons`.
    var icon: String?
    /// Legacy field read from old lists. Existing shared website data stays
    /// with the first space; no other space receives a copy during migration.
    var sharesSignIns: Bool?
    /// Where this space's downloads go; nil for the folder in Settings.
    var downloads: String?
    /// Names and store IDs to reinstall after an explicit duplication.
    var plannedExtensions: [PlannedExtension]?

    /// The first space: the session and the store there were before spaces.
    static let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
    var isFirst: Bool { id == Space.firstID }

    /// The icon it shows: its own, or a house for the first and a
    /// briefcase for any other that has none yet.
    var symbol: String { icon.flatMap { Spaces.icons.contains($0) ? $0 : nil } ?? (isFirst ? "house" : "briefcase") }
}

enum Spaces {
    /// By index, as stored: the order never changes (see Palette.spaces).
    static let colours: [Color] = Palette.spaces
    static let colourNames = ["Slate", "Blue", "Green", "Orange", "Red", "Violet"]

    /// The icons a space can wear: Apple's own symbols, drawn in one weight
    /// and one grey, grouped as work, thinking, leisure and life.
    static let icons = [
        "briefcase", "building.2", "desktopcomputer", "laptopcomputer", "chevron.left.forwardslash.chevron.right", "terminal",
        "sparkles", "brain.head.profile", "lightbulb", "gamecontroller", "beach.umbrella", "cup.and.saucer",
        "music.note", "film", "paintpalette", "camera", "house", "book",
        "graduationcap", "cart", "airplane", "dumbbell", "leaf", "heart",
    ]
    static let iconNames = [
        "Work", "Office", "Desktop", "Laptop", "Code", "Terminal",
        "AI", "Thinking", "Ideas", "Games", "Leisure", "Café",
        "Music", "Film", "Art", "Photos", "Home", "Reading",
        "Studies", "Shopping", "Travel", "Sport", "Nature", "Personal",
    ]

    private static var file: URL { Store.file("spaces.json") }

    /// Every space in its saved order, with the first one made on the spot
    /// if the list has none.
    static func read() -> [Space] {
        read(from: file)
    }

    /// An explicit path lets persistence tests use only their own file.
    static func read(from file: URL) -> [Space] {
        let first = Space(id: Space.firstID, name: "Personal", colour: 0)
        guard let data = try? Data(contentsOf: file) else { return [first] }
        guard let saved = try? JSONDecoder().decode([Space].self, from: data) else {
            // Keep the original before a later space edit replaces this file
            // with the default list (see Store.quarantine).
            Store.quarantine(file)
            return [first]
        }
        return saved.contains(where: \.isFirst) ? saved : [first] + saved
    }

    @discardableResult
    static func write(_ spaces: [Space]) -> Bool {
        do {
            let data = try JSONEncoder().encode(spaces)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            NSLog("Spaces: couldn't save list: %@", String(describing: error))
            return false
        }
    }

    /// The space new tabs are made in: the one on screen.
    @MainActor static var current = Space.firstID

    /// Each space's store, made once: WebKit shares processes between views
    /// that ask for the same store object.
    @MainActor private static var stores: [UUID: WKWebsiteDataStore] = [:]
    @MainActor static func store(for id: UUID) -> WKWebsiteDataStore {
        if id == Space.firstID { return Store.websites }
        if let made = stores[id] { return made }
        let made = WKWebsiteDataStore(forIdentifier: id)
        stores[id] = made
        return made
    }

    /// A space's store and everything in it, gone. What it holds — cookies,
    /// sign-ins, storage, caches — is emptied at once. The store itself
    /// WebKit won't remove while this run still holds on to it, however
    /// closed its tabs, so it is written down and removed at the next
    /// launch if the tries in between don't manage.
    @MainActor static func erase(_ id: UUID) {
        guard id != Space.firstID else { return }
        // And once more a moment later, for what its closing tabs were
        // still writing — the cache of the page on screen, for one.
        let store = store(for: id)
        let everything = WKWebsiteDataStore.allWebsiteDataTypes()
        store.removeData(ofTypes: everything, modifiedSince: .distantPast) {}
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            store.removeData(ofTypes: everything, modifiedSince: .distantPast) {}
        }
        stores[id] = nil
        let pending = Set(Store.settings.stringArray(forKey: "spaces.erasing") ?? []).union([id.uuidString])
        Store.settings.set(pending.sorted(), forKey: "spaces.erasing")
        sweep()
        for delay in [3.0, 15.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { sweep() }
        }
    }

    /// Every store of a deleted space that is still there, tried again.
    @MainActor static func sweep() {
        for text in Store.settings.stringArray(forKey: "spaces.erasing") ?? [] {
            guard let id = UUID(uuidString: text) else { continue }
            Task { @MainActor in
                do { try await WKWebsiteDataStore.remove(forIdentifier: id) } catch {
                    // Gone already is as good as removed; anything else is
                    // tried again later.
                    let left = await WKWebsiteDataStore.allDataStoreIdentifiers
                    guard !left.contains(id) else { return }
                }
                let now = (Store.settings.stringArray(forKey: "spaces.erasing") ?? []).filter { $0 != text }
                Store.settings.set(now, forKey: "spaces.erasing")
            }
        }
    }
}

/// A space's row of tabs while another space is on screen.
struct Parked {
    var tabs: [Tab]
    var active: Tab.ID?
}

extension Browser {
    var space: Space { spaces.first { $0.id == spaceID } ?? spaces[0] }

    /// Every tab of the spaces not on screen. Parked is not closed: their
    /// pages go on loading and calling back, settings reach them, and the
    /// sleep timer counts them.
    var parkedTabs: [Tab] { parked.values.flatMap(\.tabs) }

    /// Where a download from the space on screen lands.
    var downloadsFolder: URL { downloadsFolder(for: spaceID) }

    /// Where a download lands: its space's folder, or the one in Settings.
    func downloadsFolder(for id: UUID) -> URL {
        guard prefs.usesSpaces, let path = spaces.first(where: { $0.id == id })?.downloads else { return prefs.downloads }
        return URL(fileURLWithPath: path)
    }

    /// ⌃1–⌃9, and the menu on the space's dot.
    func switchSpace(to id: UUID, focus: Bool = true, waking: Bool = true) {
        guard prefs.usesSpaces else { return }
        enter(id, focus: focus, waking: waking)
    }

    private func enter(_ id: UUID, focus: Bool = true, waking: Bool = true) {
        guard id != spaceID, let to = spaces.firstIndex(where: { $0.id == id }) else { return }
        // Which way the icon at the foot turns over: the way the spaces lie.
        if !makingSpace { spaceStep = to > (spaces.firstIndex { $0.id == spaceID } ?? 0) ? 1 : -1 }
        field.stopOpening()
        github.leave(spaceID)
        cancelTabEdit()
        shelfNaming = nil
        cancelCapture()
        // A video comes home with the row it left. A meeting does not: it is
        // still there to be seen while you work in another Space, and leaving
        // the tab it lives in puts it in the window as it would within a row.
        if floater.showing, !floater.call { land() }
        if Players.isCall(active?.address) { leaving() }
        if #available(macOS 15.4, *) { ExtensionPopup.shared.close() }
        writeSession(now: true)

        // Media stays in its source page across Spaces; MiniPlayer can return
        // to that stable tab identity without constructing another page.
        parked[spaceID] = Parked(tabs: tabs, active: activeID)

        spaceID = id
        Spaces.current = id
        // Offers from parked pages wait in their own space (see Logins.swift).
        logins.enter(id)
        Store.settings.set(id.uuidString, forKey: "space.current")
        if #available(macOS 15.4, *) { Extensions.forSpace(id).start(for: self) }
        followStore()
        if let back = parked.removeValue(forKey: id), !back.tabs.isEmpty {
            showRow(back.tabs, active: back.active)
            if waking { wakePanels() }
        } else if !waking {
            // A routed link will select its own new tab in this turn. Loading
            // the old selection first would wake an unrelated page.
            let row = loadRow(id)
            showRow(row.tabs, active: row.active)
        } else {
            showRow([], active: nil)
            restoreSession()
        }
        // Back on the tab whose meeting is out: it comes home, as selecting it does.
        if let out = floating, activeID == out { land() }
        editing = active?.isBlank ?? true
        field.typed = ""
        if focus { field.askFocus() }
        announce(space.name)
    }

    /// A tab of a space not on screen closed by its own page — a sign-in
    /// window done with itself. It leaves that space's row, which goes back
    /// to the tab that opened it, or to its neighbour; a pinned one is put
    /// down instead, as ⌘W would (see Browser.close).
    func closeParked(_ tab: Tab) {
        guard var row = parked[tab.space], let at = row.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        defer { rememberSession(tab.space) }
        if tab.pin != nil {
            tab.rest()
            return
        }
        row.tabs.remove(at: at)
        if row.active == tab.id {
            row.active = row.tabs.first { $0.id == tab.opener }?.id
                ?? (row.tabs.isEmpty ? nil : row.tabs[min(at, row.tabs.count - 1)].id)
        }
        parked[tab.space] = row
        tab.close()
    }

    /// Every other space's row, made ahead of time, so the column can show
    /// the next space beside this one while two fingers bring it in.
    func preloadSpaces() {
        for space in spaces where space.id != spaceID && parked[space.id] == nil {
            parked[space.id] = loadRow(space.id)
        }
    }

    func switchSpace(index: Int) {
        guard spaces.indices.contains(index) else { return }
        switchSpace(to: spaces[index].id)
    }

    /// The icon a new space gets unless told: the first no space wears yet.
    var freeIcon: String {
        let used = Set(spaces.map(\.symbol))
        return Spaces.icons.first { !used.contains($0) } ?? "briefcase"
    }

    /// A new space starts with an empty website store (see Spaces.store).
    func addSpace(named name: String, icon: String? = nil) {
        makingSpace = false
        let made = Space(id: UUID(), name: name, colour: 0, icon: icon ?? freeIcon)
        spaces.append(made)
        Spaces.write(spaces)
        switchSpace(to: made.id)
    }

    /// Dragged to another place among the dots. ⌃1–⌃9 follow the order.
    func moveSpace(_ id: UUID, to index: Int) {
        guard let from = spaces.firstIndex(where: { $0.id == id }), spaces.indices.contains(index), from != index else { return }
        spaces.move(fromOffsets: IndexSet(integer: from), toOffset: index > from ? index + 1 : index)
        Spaces.write(spaces)
    }

    /// "Move Up" and "Move Down": one step along the rail.
    func moveSpace(_ id: UUID, by step: Int) {
        guard let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        moveSpace(id, to: at + step)
    }

    /// "New Space…": the card for a new space, in the column or the bar.
    func askForSpace() {
        // In place, where the next space would come in, in the column or the
        // bar alike; a question only while the tabs are folded out of sight.
        if !folded || peeking {
            let here = spaces.firstIndex { $0.id == spaceID } ?? 0
            SpaceSwipe.shared.start(for: self)
            SpaceSwipe.shared.slide(self, to: spaces.count, from: here)
        } else {
            Ask.newSpace { name in self.addSpace(named: name) }
        }
    }

    func askToRenameSpace(_ id: UUID) {
        guard let here = spaces.first(where: { $0.id == id }) else { return }
        Ask.name("Rename Space", placeholder: here.name, initial: here.name, confirm: "Rename") { self.renameSpace(id, to: $0) }
    }

    func renameSpace(_ id: UUID, to name: String) {
        guard let at = spaces.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        spaces[at].name = name
        Spaces.write(spaces)
    }

    func setSpaceIcon(_ id: UUID, to icon: String) {
        guard let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[at].icon = icon
        Spaces.write(spaces)
    }

    func setSpaceDownloads(_ id: UUID, to folder: URL?) {
        guard let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[at].downloads = folder?.path
        Spaces.write(spaces)
    }

    /// Deleting always asks first, from a menu or a key.
    func askToDeleteSpace(_ id: UUID) {
        guard let here = spaces.first(where: { $0.id == id }), !here.isFirst else { return }
        Ask.sure("Delete “\(here.name)”?", detail: "Its tabs close. Link rules pointing here, bookmarks, history and saved passwords are deleted. Its sites and extensions are removed from this Space. Downloaded files stay in their folder.", confirm: "Delete") {
            self.deleteSpace(id)
        }
    }

    /// A space, its tabs, and its cookies and sign-ins, gone. The first one
    /// stays: it is where everything was before there were spaces.
    func deleteSpace(_ id: UUID) {
        // A keychain write already in flight must finish before its Space can
        // be erased; otherwise a late add could resurrect a deleted identity.
        guard !(migration.applying && migration.migration.plan?.destination == id) else {
            announce("Stop the import before deleting this Space")
            return
        }
        guard id != Space.firstID, let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        if spaceID == id { switchSpace(to: Space.firstID) }
        downloads.cancel(in: id)
        ExtensionAuth.cancel(in: id)
        for tab in parked.removeValue(forKey: id)?.tabs ?? [] {
            if floating == tab.id { land() }
            tab.close()
        }
        eraseClosedTabs(in: id)
        linkRoutes.remove(space: id)
        spaces.remove(at: at)
        Spaces.write(spaces)
        Session.erase(space: id)
        // Visits and their suggestions belong to this space (see History.swift).
        histories[id]?.flush()
        histories[id] = nil
        historyWatches[id] = nil
        History.erase(space: id)
        // Its GitHub cache, set-aside files and authorization (GitHubSpaces.swift).
        github.erase(id)
        habitsBySpace[id] = nil
        Habits.erase(space: id)
        loots[id] = nil
        Loot.erase(space: id)
        curtains[id]?.flush()
        curtains[id] = nil
        Curtain.erase(space: id)
        Shield.shared.erase(space: id)
        forgetCaptureChoices(in: id)
        Store.eraseZoom(space: id)
        // Passwords in another space use another keychain label (see Vault.swift).
        Vault.erase(space: id)
        logins.erase(id)
        // Installed code, permissions and WebKit contexts belong here.
        if #available(macOS 15.4, *) { Extensions.erase(space: id) }
        // Its bookmarks go with it (see Shelf.swift).
        Bookmarks.erase(space: id)
        shelves[id] = nil
        localhost.forget(space: id)
        Spaces.erase(id)
    }

    /// Spaces turned off: back to the first one. The others are kept, in
    /// case they are turned on again.
    func leaveSpaces() {
        enter(Space.firstID)
        // What changed in the others meanwhile is there when they come back.
        for space in unsaved { writeSession(of: space, now: true) }
        for (_, row) in parked {
            for tab in row.tabs {
                if floating == tab.id { land() }
                tab.close()
            }
        }
        parked = [:]
    }
}

// MARK: - the rail

/// Every space has a direct door in the sidebar's rail. The rail stays visible
/// while the tab column folds away, so the current workspace remains legible
/// without keeping the column's width. Its frames give tab and bookmark drags
/// exact targets without a polling loop.
///
/// The doors start under the title line, where the page frame starts when the
/// address bar is on: the first door's top is the page's top, and the
/// column's title is centred on it (SideBar.spaceTitle).
struct SpaceRail: View {
    @ObservedObject var browser: Browser
    @ObservedObject var hover: HoverDwell
    /// Redraws the doors when a Space starts or stops playing or listening.
    @ObservedObject var presences: Presences
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    /// An icon, or the new-space button: the same square as every door.
    static let icon: CGFloat = Metrics.spaceRailIcon
    static let gap: CGFloat = 4
    /// New-space and tool symbols share one font size; named Spaces use an
    /// optically smaller size inside the same door.
    static let glyph: CGFloat = Metrics.spaceRailGlyph

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: metrics.length(SpaceRail.gap)) {
                    ForEach(browser.spaces) { space in spaceDoor(space) }
                    // The next space's place, right after the last one: a
                    // door as large as theirs, so it reads as part of the
                    // list.
                    Door(icon: "plus", help: browser.prefs.keyHelp(.newSpace), box: SpaceRail.icon, glyph: SpaceRail.glyph) {
                        browser.askForSpace()
                    }
                    .accessibilityLabel("New Space")
                }
            }
            .frame(maxHeight: .infinity)

            // Settings belongs to the whole browser, so it sits last below
            // the space tools and remains available while the column folds.
            VStack(spacing: metrics.length(SpaceRail.gap)) {
                Tools(browser: browser, box: SpaceRail.icon, glyph: SpaceRail.glyph)
                Door(icon: "gearshape", on: browser.tuning, help: browser.prefs.keyHelp(.settings),
                     box: SpaceRail.icon, glyph: SpaceRail.glyph) { browser.tuning = true }
                    .accessibilityLabel("Settings")
                // An update on its way or in place, last: the one door in ink.
                GateDoor(browser: browser, box: SpaceRail.icon, glyph: SpaceRail.glyph)
            }
            .padding(.bottom, metrics.spaceRailInset)
        }
        .padding(.top, browser.corner)
        .frame(width: metrics.spaceRailWidth)
        .frame(maxHeight: .infinity)
    }

    private func spaceDoor(_ space: Space) -> some View {
        let presence = browser.presence(in: space.id)
        return Button { browser.switchSpace(to: space.id) } label: {
            // SF Symbols for places read larger than the thin rail tools at
            // the same font size; the door and its hit target stay unchanged.
            Image(systemName: space.symbol)
                .font(.system(size: metrics.length(Metrics.spaceIconGlyph), weight: .medium))
                .foregroundStyle(space.id == browser.spaceID ? Palette.ink : Palette.muted)
                .frame(width: metrics.length(SpaceRail.icon), height: metrics.length(SpaceRail.icon))
                .background {
                    if space.id == hover.target {
                        RoundedRectangle(cornerRadius: metrics.length(8), style: .continuous).fill(Palette.hover)
                    } else if space.id == browser.spaceID {
                        Chosen(radius: metrics.length(8))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let presence { SpaceMark(presence: presence) }
                }
                .scaleEffect(hover.pulsing && hover.target == space.id ? 1.08 : 1)
                .animation(Motion.bookmarkPulse, value: hover.pulsing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(spaceHelp(space) + (presence.map { " — " + $0.spoken } ?? ""))
        .accessibilityLabel(space.name)
        .accessibilityValue(presence?.spoken ?? "")
        .contextMenu { SpaceActions(browser: browser, space: space) }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: SpaceIconFrames.self, value: [space.id: proxy.frame(in: .global)])
        })
    }
    private func spaceHelp(_ space: Space) -> String {
        guard let index = browser.spaces.firstIndex(where: { $0.id == space.id }),
              let action = KeyAction(rawValue: "space\(index + 1)") else { return space.name }
        return browser.prefs.keyHelp(action, space.name)
    }
}

struct SpaceIconFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The space on screen, as its icon before the tabs in the top row. A click
/// opens the menu. In the sidebar the rail above shows every space directly.
/// Here the icon turns over the way the spaces went.
struct SpaceDot: View {
    @ObservedObject var browser: Browser
    @State private var hovering = false
    /// What is drawn, a step behind the browser: the space changes in a
    /// frame with nothing animated (see SpaceSwipe.slide), and the icon
    /// turns over just after, on a change of its own.
    @State private var shown: (key: String, symbol: String)?

    static let width: CGFloat = 26

    private var symbol: String { browser.makingSpace ? "plus" : browser.space.symbol }
    private var key: String { browser.makingSpace ? "new" : "\(browser.spaceID.uuidString)-\(browser.space.symbol)" }

    var body: some View {
        Button { SpaceMenu.show(for: browser) } label: {
            ZStack {
                Image(systemName: shown?.symbol ?? symbol)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                    .id(shown?.key ?? key)
                    .transition(.push(from: browser.spaceStep > 0 ? .trailing : .leading))
            }
            .frame(width: SpaceDot.width, height: 26)
            .clipped()
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Palette.hover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(browser.space.name) — choose a Space or swipe to switch")
        .onChange(of: key) { _, now in
            let symbol = symbol
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.22)) { shown = (now, symbol) }
            }
        }
        .animation(Motion.quick, value: hovering)
    }
}

/// The dot's menu: the spaces, then what can be done to the one on screen.
@MainActor
enum SpaceMenu {
    /// Menu items call back into Swift through this.
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    private static var actions: [Action] = []

    private static func item(_ title: String, key: String = "", checked: Bool = false, _ run: @escaping () -> Void) -> NSMenuItem {
        let action = Action(run)
        actions.append(action)
        let item = NSMenuItem(title: title, action: #selector(Action.fire), keyEquivalent: key)
        item.target = action
        item.keyEquivalentModifierMask = key.isEmpty ? [] : .control
        item.state = checked ? .on : .off
        return item
    }

    static func show(for browser: Browser) {
        actions = []
        let menu = NSMenu()
        for (index, space) in browser.spaces.enumerated() {
            let entry = item(space.name, key: index < 9 ? "\(index + 1)" : "", checked: space.id == browser.spaceID) {
                browser.switchSpace(to: space.id)
            }
            if let action = KeyAction(rawValue: "space\(index + 1)") {
                let binding = browser.prefs.keyBindings.keys(action).first
                entry.keyEquivalent = binding?.menuKey ?? ""
                entry.keyEquivalentModifierMask = binding?.flags ?? []
            }
            entry.image = NSImage(systemSymbolName: space.symbol, accessibilityDescription: nil)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item("New Space…") { browser.askForSpace() })
        menu.addItem(.separator())
        let here = browser.space
        menu.addItem(item("Rename “\(here.name)”…") { browser.askToRenameSpace(here.id) })
        // The copy workflow owns its own value snapshot and dialogue (see SpaceCopy.swift).
        menu.addItem(item("Duplicate “\(here.name)”…") { browser.askToDuplicateSpace(here.id) })
        let icons = NSMenu()
        for (symbol, name) in zip(Spaces.icons, Spaces.iconNames) {
            let choice = item(name, checked: here.symbol == symbol) { browser.setSpaceIcon(here.id, to: symbol) }
            choice.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
            icons.addItem(choice)
        }
        let icon = NSMenuItem(title: "Icon", action: nil, keyEquivalent: "")
        icon.submenu = icons
        menu.addItem(icon)
        // The order is the rail's, the swipe's, and ⌃1–⌃9's.
        if let at = browser.spaces.firstIndex(where: { $0.id == here.id }) {
            if at > 0 { menu.addItem(item("Move Up") { browser.moveSpace(here.id, by: -1) }) }
            if at < browser.spaces.count - 1 { menu.addItem(item("Move Down") { browser.moveSpace(here.id, by: 1) }) }
        }
        let folder = here.downloads.map { URL(fileURLWithPath: $0).lastPathComponent }
        menu.addItem(item(folder.map { "Downloads to “\($0)”…" } ?? "Downloads Folder…") {
            Ask.folder { browser.setSpaceDownloads(here.id, to: $0) }
        })
        if folder != nil {
            menu.addItem(item("Downloads to the Folder in Settings") { browser.setSpaceDownloads(here.id, to: nil) })
        }
        if !here.isFirst {
            menu.addItem(.separator())
            menu.addItem(item("Delete “\(here.name)”…") { browser.askToDeleteSpace(here.id) })
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// A right-click on a rail icon: that Space's actions, in the order of the
/// dot's menu, without the list of Spaces the rail already shows.
struct SpaceActions: View {
    @ObservedObject var browser: Browser
    let space: Space

    var body: some View {
        let at = browser.spaces.firstIndex { $0.id == space.id } ?? 0
        Button("Rename “\(space.name)”…") { browser.askToRenameSpace(space.id) }
        Button("Duplicate “\(space.name)”…") { browser.askToDuplicateSpace(space.id) }
        Picker("Icon", selection: Binding(get: { space.symbol }, set: { browser.setSpaceIcon(space.id, to: $0) })) {
            ForEach(Array(zip(Spaces.icons, Spaces.iconNames)), id: \.0) { symbol, name in
                Label(name, systemImage: symbol).tag(symbol)
            }
        }
        if at > 0 { Button("Move Up") { browser.moveSpace(space.id, by: -1) } }
        if at < browser.spaces.count - 1 { Button("Move Down") { browser.moveSpace(space.id, by: 1) } }
        let folder = space.downloads.map { URL(fileURLWithPath: $0).lastPathComponent }
        Button(folder.map { "Downloads to “\($0)”…" } ?? "Downloads Folder…") {
            Ask.folder { browser.setSpaceDownloads(space.id, to: $0) }
        }
        if folder != nil {
            Button("Downloads to the Folder in Settings") { browser.setSpaceDownloads(space.id, to: nil) }
        }
        if !space.isFirst {
            Divider()
            Button("Delete “\(space.name)”…") { browser.askToDeleteSpace(space.id) }
        }
    }
}

/// The few questions a space's menu asks, as sheets on the window.
@MainActor
enum Ask {
    static func name(_ title: String, placeholder: String, initial: String = "", confirm: String, then: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        show(alert) { ok in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if ok, !name.isEmpty { then(name) }
        }
    }

    /// A new space's name when the column cannot hold its card.
    static func newSpace(then: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "New Space"
        alert.informativeText = "A fresh workspace. You may need to sign in to sites again here."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Work"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        show(alert) { ok in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if ok, !name.isEmpty { then(name) }
        }
    }

    static func sure(_ title: String, detail: String, confirm: String, then: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: confirm).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        show(alert) { ok in if ok { then() } }
    }

    static func folder(then: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use for This Space"
        panel.message = "Downloads in this space go here. Cancel keeps the folder it has."
        guard let window = Links.window else { return }
        panel.beginSheetModal(for: window) { answer in
            if answer == .OK, let url = panel.url { then(url) }
        }
    }

    private static func show(_ alert: NSAlert, _ done: @escaping (Bool) -> Void) {
        guard let window = Links.window else {
            done(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: window) { done($0 == .alertFirstButtonReturn) }
    }
}
