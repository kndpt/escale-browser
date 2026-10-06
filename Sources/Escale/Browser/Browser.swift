import SwiftUI
import WebKit
import Combine

// Everything the window knows: which tabs exist, which one is showing, and
// whether the address field is up. Small enough to read in one sitting, which
// is the point of a browser with no features.

@MainActor
final class Browser: NSObject, ObservableObject {
    /// WebKit's inspector session has its own short interaction lifetime
    /// (Inspector.swift); tab selection only hands it the new target.
    let inspection = InspectorSession()
    let panels = Panels()
    let playback = Playback() // Directly observed by MiniPlayer.
    let presences = Presences() // Directly observed by the Space rail.
    @Published private(set) var tabs: [Tab] = []
    /// The overflow scroll is deferred until layout; keep this selection's input.
    private(set) var selectionFromKeyboard = false
    @Published var activeID: Tab.ID? {
        willSet { selectionFromKeyboard = Motion.fromKeyboard }
        didSet {
            panels.focus(activeID)
            playback.active = activeID
            inspection.follow(browser: self, from: oldValue)
            // Settings stand in for the page on screen (App.swift); another
            // page on screen puts them away.
            if oldValue != activeID { tuning = false; field.stopOpening() }
            // The tab just left is the tab just looked at. Whether a tab has
            // gone unwatched long enough to sleep is counted from here, not
            // from when it was first picked.
            guard oldValue != activeID, let old = oldValue else { return }
            let previous = (tabs + parkedTabs).first { $0.id == old }
            previous?.media.leaving(previous?.built)
            previous?.siteStorage.close()
            previous?.jsonReader.raw()
            previous?.visual.stop()
            previous?.area.stop()
            previous?.capture.close()
            linkStatus.dismiss()
            selectionMenu.dismiss()
            touchPanels(containing: old)
        }
    }

    /// The tab whose page is currently out in the little window. Nothing
    /// floating means no window: the two are checked against each other rather
    /// than trusted to stay in step.
    @Published private(set) var floating: Tab.ID? {
        didSet {
            playback.floating = floating
            guard floating == nil, floater.showing else { return }
            floater.drop()
        }
    }
    /// Whether what is out is a meeting, as it was when lifted: the page is
    /// put back the way it was taken out, whatever its address says by then.
    private var floatingMeeting = false

    /// Everything there is to set. Held here so the whole window redraws when
    /// one of them changes.
    let prefs = Preferences()
    let linkStatus = LinkStatus()
    let selectionMenu = SelectionMenu()
    let localhost = Localhost()
    let linkRoutes = LinkRoutes(file: Store.file("link-rules.json"))
    @Published var localhostOpen = false
    /// Settings, standing in for the page on screen (App.swift).
    @Published var tuning = false {
        didSet {
            if tuning { active?.visual.stop(); active?.area.stop(); active?.capture.close(); active?.siteStorage.close(); active?.jsonReader.raw() }
            if tuning && !oldValue && welcoming { welcoming = false }
            if oldValue && !tuning { migration.leave(); transfer.leave() }
        }
    }
    /// The first-launch walk-through, over everything. Also from the menu.
    @Published var welcoming = false {
        didSet {
            if welcoming && !oldValue { tuning = false }
            if oldValue && !welcoming { migration.leave(); transfer.leave() }
        }
    }

    // MARK: - bookmarks

    /// Each space's own bookmarks, read when first asked for, and what
    /// passes their changes on; `bookmarks` is the space on screen's (see
    /// Shelf.swift).
    var shelves: [UUID: (list: Bookmarks, watch: AnyCancellable)] = [:]
    /// The environment sheet observes its window-owned request directly.
    let environmentEditor = EnvironmentEditor()
    /// Selection, permission and import lifetime shared by welcome and Settings.
    let migration = MigrationFlow(journal: Store.file("migration.json"), scratch: Store.file("migration-snapshots"))
    /// Saving Escale to one file and bringing such a file in (Transfer/).
    let transfer = TransferFlow()
    /// The full list, for taking things out.
    @Published var bookmarking = false
    /// The dropdown off the button.
    @Published var bookmarksOpen = false
    /// The folders open in the column's bookmarks (see Shelf.swift).
    @Published var shelfOpen: Set<Bookmark.ID> = []
    @Published var shelfNaming: Bookmark.ID?
    /// Where a tab held over the column's bookmarks would land (see Shelf.swift).
    @Published var shelfAim: Shelf.Drop?
    /// The tabs that are bookmarks' own, and whose (see Shelf.swift).
    @Published var shelfTabs: [Tab.ID: Bookmark.ID] = [:]

    /// ⇧⌘B. The page you are on, at the end of the list.
    func bookmarkCurrent() {
        guard let tab = active, let url = tab.address else { return }
        guard !bookmarks.contains(url) else {
            announce("Already a bookmark")
            return
        }
        bookmarks.add(url, title: tab.title)
        announce("Bookmarked")
    }

    /// ⇧⌘S. The same tabs, down the left or across the top.
    func toggleSidebar() {
        withAnimation(Motion.shortcutAnimation(Motion.glide, keyboard: Motion.fromKeyboard,
            enabled: prefs.fasterShortcuts, reduced: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { prefs.sidebar.toggle() }
    }

    func searchURL(for text: String) -> URL? {
        Engine.url(for: text, template: prefs.engine.template(custom: prefs.customEngine))
    }

    func destination(for typed: String) -> URL? {
        Address.url(from: typed) ?? searchURL(for: typed)
    }

    /// ⌘S: the column folded away, and slid out over the page for a look
    /// while it is (see Fold.swift).
    @Published var folded = false
    @Published var peeking = false

    /// The address field, raised over a page by ⌘L or a pending New Tab. A blank tab shows it
    /// without being asked — there is nothing else for that tab to show.
    @Published var editing = false {
        // Typing an address asks for a page, which Settings stand in for.
        didSet {
            if editing { tuning = false }
            else { field.stopOpening() }
        }
    }

    // Each space owns its own bounded history (see History.swift). Old visits
    // remain in the first space's original file.
    var histories: [UUID: History] = [:]
    var historyWatches: [UUID: AnyCancellable] = [:]
    var history: History { history(for: spaceID) }
    /// What each Space's Bearings has learned from the rows taken (Habits.swift).
    var habitsBySpace: [UUID: Habits] = [:]
    /// Each Space's GitHub cache and authorization, made when Bearings' GitHub
    /// mode first asks (GitHubSpaces.swift).
    private(set) lazy var github = GitHubSpaces(history: { [weak self] in self?.history(for: $0) })

    func history(for id: UUID) -> History {
        if let known = histories[id] { return known }
        let made = History(space: id)
        made.forgotten = { [weak self] key in
            guard let self else { return }
            if let key { self.habits(for: id).forget(visit: key, space: id) } else { self.habits(for: id).forget() }
            self.github.forget(key, in: id)
        }
        historyWatches[id] = made.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
        histories[id] = made
        return made
    }
    /// What is typed into the field and what it offers, which change with
    /// every key: observed by the field alone, not the window (see Field.swift).
    private(set) lazy var field: Field = Field(
        history: { [weak self] in self?.history ?? History() },
        search: { [weak self] in self?.searchURL(for: $0) },
        engine: { [weak self] in self.map { $0.prefs.engine.name(custom: $0.prefs.customEngine) } ?? "" },
        others: { [weak self] in self.map { browser in browser.tabs.filter { ($0.id != browser.activeID || browser.field.opening != nil) && !$0.bench && $0.shy == browser.searchIsPrivate } } ?? [] },
        newTab: { [weak self] in self?.searchingNewTab == true },
        bookmarks: { [weak self] in self?.bookmarks.roots ?? [] },
        bookmarkForTab: { [weak self] tab in
            guard let self, let id = self.shelfTabs[tab] else { return nil }
            return self.bookmarks.find(id)
        },
        habits: { [weak self] in self.map { $0.habits(for: $0.spaceID) } }
    )
    /// Bumped when an address typed into a tab can't be gone to (see
    /// commitTabEdit); the address field has its own (see Field.refusals).
    @Published private(set) var refusals = 0

    var active: Tab? { tabs.first { $0.id == activeID } }
    var fieldShowing: Bool { editing || active?.isBlank ?? true }

    // MARK: - looking for something on the page

    /// The find bar, up or not; what it looks for is `find`'s (see Find.swift).
    @Published var finding = false
    /// The page on screen as it is: a blank tab's is never built to be
    /// searched, or to hear an answer (see Find.page).
    private(set) lazy var find = Find(page: { [weak self] in self?.active?.built })

    func openFind() {
        guard field.opening == nil, active?.isBlank == false else { return }
        finding = true
        find.askFocus()
    }

    func closeFind() {
        guard finding else { return }
        finding = false
        find.clear()
        // There is no public way to call off a find, but letting go of the
        // selection is what taking the highlight away amounts to. A tab with
        // no page has no selection, and is not given a page to lose one.
        active?.built?.evaluateJavaScript("window.getSelection().removeAllRanges()")
    }

    /// ⌘⇧M. Whatever is making noise in this tab stops making noise.
    func pauseMedia() {
        guard let tab = active else { return }
        tab.web.pauseAllMediaPlayback()
        announce("Paused")
    }

    // MARK: - taking things off pages

    var curtains: [UUID: Curtain] = [:]
    var curtain: Curtain { curtain(for: spaceID) }
    func curtain(for id: UUID) -> Curtain {
        if let known = curtains[id] { return known }
        let made = Curtain(space: id)
        curtains[id] = made
        return made
    }
    // Download history follows the originating space (see Loot.swift).
    var loots: [UUID: Loot] = [:]
    var loot: Loot { loot(for: spaceID) }
    func loot(for id: UUID) -> Loot {
        if let known = loots[id] { return known }
        let made = Loot(space: id)
        loots[id] = made
        return made
    }
    /// Active transfers own their WebKit lifetime and originating space (see
    /// Downloads.swift).
    private(set) lazy var downloads = Downloads(
        loot: { [weak self] space in
            guard let self, self.spaces.contains(where: { $0.id == space }) else { return nil }
            return self.loot(for: space)
        },
        asksWhere: { [weak self] in self?.prefs.asksWhereToSave ?? true },
        folder: { [weak self] space in
            guard let self, self.spaces.contains(where: { $0.id == space }) else { return nil }
            return self.downloadsFolder(for: space)
        },
        announce: { [weak self] line in self?.announce(line) }
    )
    let floater = Float()
    /// True while the pointer is picking things to hide.
    @Published private(set) var veiling = false
    /// True while the list of what is hidden here is up.
    @Published var reviewing = false {
        didSet { if !reviewing { stopPeeking() } }
    }

    var hereHost: String? { curtain.host(of: active?.address) }
    var hereVeils: [Veil] { curtain.veils(on: hereHost) }

    /// ⌘⇧H. Point at anything on the page and it goes, for good, on this site.
    func toggleHiding() {
        guard let tab = active, !tab.isBlank else { return }
        if veiling {
            veiling = false
            tab.stopPicking()
        } else {
            reviewing = false
            veiling = true
            tab.startPicking()
        }
    }

    /// ⌘Z, while pointing: the last thing you took off comes back.
    func undoHiding() {
        guard let host = hereHost, let back = curtain.undo(on: host) else { return }
        redress()
        announce("\(back.label) is back")
    }

    /// The pointer resting on a row in the list brings that one thing back,
    /// outlined, and scrolls the page to it.
    func peek(_ veil: Veil) {
        guard let tab = active else { return }
        tab.peek(veil.selector, keeping: curtain.css(on: hereHost, without: veil.selector))
    }

    func stopPeeking() {
        active?.unpeek(curtain.css(on: hereHost))
    }

    func restore(_ veil: Veil) {
        guard let host = hereHost else { return }
        curtain.restore(veil, on: host)
        redress()
    }

    func restoreAll() {
        guard let host = hereHost else { return }
        curtain.restoreAll(on: host)
        redress()
        reviewing = false
        announce("Everything is back")
    }

    /// Both the page in front of you and the one that loads next time.
    private func redress() {
        guard let tab = active else { return }
        let css = curtain.css(on: hereHost)
        tab.arm(hiding: css)
        tab.applyVeils(css)
    }

    // MARK: - passwords

    /// The offer to keep a password, the accounts under a sign-in box and the
    /// panel's list, each observed on its own (see Logins.swift).
    private(set) lazy var logins = Logins(
        say: { [weak self] in self?.announce($0) },
        tab: { [weak self] id in
            guard let self else { return nil }
            return tabs.first { $0.id == id } ?? active
        },
        read: { [weak self] in Vault.all(space: self?.spaceID ?? Space.firstID) }
    )

    /// The Passwords panel. The keychain's list is read while it is up, and
    /// let go of when it closes (see Logins.show).
    @Published var managing = false {
        didSet {
            guard managing != oldValue else { return }
            if managing { logins.show() } else { logins.hide() }
        }
    }

    // MARK: - what is kept, and getting rid of it

    @Published var recalling = false
    @Published var hoarding = false
    /// The update's panel: boarding a waiting build, or what one brought (Gate.swift).
    @Published var gate: Gate?
    @Published var recallHunt = ""

    /// Cookies, caches, local storage — everything a site left on this Mac,
    /// in every space. Clearing it signs you out of everything, which is
    /// the point.
    func clearSites() {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        for space in spaces {
            Spaces.store(for: space.id).removeData(ofTypes: types, modifiedSince: .distantPast) {}
        }
        announce("Signed out of everything")
    }

    /// Only what was fetched to draw pages, not what identifies you.
    func clearCache() {
        let types: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
        ]
        for space in spaces {
            Spaces.store(for: space.id).removeData(ofTypes: types, modifiedSince: .distantPast) {}
        }
        announce("Cache cleared")
    }

    func clearHistory() {
        history.forget()
        localhost.forget(space: spaceID)
        announce("History cleared")
    }

    func forgetHistory(_ trace: History.Trace) {
        history.forget(trace.key)
        localhost.forget(url: trace.url, in: spaceID)
    }

    /// The last few places, for the History menu.
    var recentlyVisited: [History.Trace] {
        history.recent()
    }

    // MARK: - the camera and the microphone

    /// A page asking to see or hear you, waiting for an answer. WebKit hands
    /// over a decision handler and holds the page until it is called — so this
    /// keeps the handler and the question together, and never drops either.
    struct CaptureAsk: Equatable, Identifiable {
        let host: String
        let wants: String
        let space: UUID
        var id: String { space.uuidString + host + wants }
    }

    @Published private(set) var asking: CaptureAsk?
    private var decide: ((WKPermissionDecision) -> Void)?
    private var askedAbout = ""

    func allowCapture() { answerCapture(.grant) }
    func denyCapture() { answerCapture(.deny) }

    private static func capturePrefix(_ space: UUID) -> String {
        space == Space.firstID ? "capture." : "capture.@\(space.uuidString)."
    }

    static func captureKey(host: String, type: Int, space: UUID) -> String {
        capturePrefix(space) + "\(host)|\(type)"
    }

    func captureChoice(host: String, type: Int, space: UUID) -> Bool? {
        Store.settings.object(forKey: Self.captureKey(host: host, type: type, space: space)) as? Bool
    }

    func rememberCapture(_ allowed: Bool, host: String, type: Int, space: UUID) {
        Store.settings.set(allowed, forKey: Self.captureKey(host: host, type: type, space: space))
    }

    private func answerCapture(_ decision: WKPermissionDecision, remember: Bool = true) {
        guard let decide else { return }
        // A change of Space refuses the pending request without remembering a
        // decision in either Space; an explicit answer belongs to its asker.
        if remember { Store.settings.set(decision == .grant, forKey: askedAbout) }
        decide(decision)
        self.decide = nil
        askedAbout = ""
        asking = nil
    }

    func cancelCapture() { answerCapture(.deny, remember: false) }

    /// Everything a site has been allowed or refused, for the day you want to
    /// change your mind.
    func forgetCaptureChoices() {
        forgetCaptureChoices(in: spaceID)
        announce("Camera and microphone choices forgotten")
    }

    func forgetCaptureChoices(in space: UUID) {
        let prefix = Self.capturePrefix(space)
        for key in Store.settings.dictionaryRepresentation().keys
        where key.hasPrefix(prefix) && (space != Space.firstID || !key.hasPrefix("capture.@")) {
            Store.settings.removeObject(forKey: key)
        }
    }

    // MARK: - pinning

    /// The pinned tab whose letter is being typed over, in place. There is no
    /// dialog: pinning happens at once, with a letter guessed from the address,
    /// and that letter arrives selected so the next keystroke replaces it.
    @Published var editingPin: Tab.ID?

    var pinnedCount: Int { tabs.filter { $0.pin != nil }.count }

    func pin(_ tab: Tab) {
        if tab.pin == nil {
            // The array may not move (notably for its only tab), yet both tab
            // bars derive their pinned section from this tab's value.
            objectWillChange.send()
            tab.pin = tab.monogram
            // Pinned tabs live at the head of the row, in the order they were
            // pinned, so their letters never move under your hand.
            if let here = tabs.firstIndex(where: { $0.id == tab.id }) {
                let home = max(0, pinnedCount - 1)
                if here != home {
                    tabs.move(
                        fromOffsets: IndexSet(integer: here),
                        toOffset: home > here ? home + 1 : home
                    )
                }
            }
        }
        // No dialog and no waiting cursor: the letter is taken from the
        // address and applied. Changing it is a separate act, for the day it
        // matters — which is why it is not folded into this one.
        writeSession(now: true)
    }

    /// Change Letter, or a double-click on the square itself.
    func editLetter(_ tab: Tab) {
        guard tab.pin != nil else { return }
        editingPin = tab.id
    }

    /// Typed into the square. Empty leaves the letter as it was — a pinned tab
    /// with nothing on it would be a blank square you could never identify.
    func letter(_ typed: String, for tab: Tab) {
        guard let first = typed.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return
        }
        tab.pin = String(first).uppercased()
    }

    func endPinEdit() {
        guard editingPin != nil else { return }
        editingPin = nil
        writeSession(now: true)
    }

    func unpin(_ tab: Tab) {
        if editingPin == tab.id { editingPin = nil }
        // Changing an element does not publish a change to the tabs array.
        objectWillChange.send()
        tab.pin = nil
        defer { writeSession(now: true) }
        // Back out of the pinned block, to the head of the loose tabs.
        if let here = tabs.firstIndex(where: { $0.id == tab.id }) {
            let home = pinnedCount
            if here != home {
                tabs.move(fromOffsets: IndexSet(integer: here), toOffset: home > here ? home + 1 : home)
            }
        }
        rememberSession()
    }

    // MARK: - the address, in the tab itself

    /// Clicking the tab you are already on turns it into the address, short
    /// form, ready to be changed.
    @Published private(set) var editingTab: Tab.ID?
    @Published var tabDraft = ""
    /// Set while that field is being used to name the tab rather than to go
    /// somewhere: the same field, the same keys, a different thing at the end.
    @Published private(set) var renamingTab = false

    func beginTabEdit(_ tab: Tab) {
        guard let url = tab.address else {
            edit()
            return
        }
        renamingTab = false
        tabDraft = Address.pretty(url)
        editingTab = tab.id
    }

    /// Rename. The name the tab is wearing arrives selected, so typing
    /// replaces it; emptying the field gives the page its own title back.
    func beginTabRename(_ tab: Tab) {
        renamingTab = true
        tabDraft = tab.label
        editingTab = tab.id
    }

    func commitTabEdit() {
        guard let id = editingTab, let tab = tabs.first(where: { $0.id == id }) else { return }
        if renamingTab {
            let typed = tabDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            tab.name = typed.isEmpty ? nil : typed
            cancelTabEdit()
            writeSession(now: true)
            return
        }
        guard let url = destination(for: tabDraft) else {
            // Stay put and say so, rather than quietly throwing the edit away.
            refusals += 1
            return
        }
        editingTab = nil
        tab.go(to: url)
    }

    func cancelTabEdit() {
        editingTab = nil
        renamingTab = false
        tabDraft = ""
    }

    /// A click somewhere else — the page, the column below, the rest of the
    /// strip — while a tab's address or name is being edited in the tab: what
    /// was typed is kept, as Return keeps it. An address left as it was loads
    /// nothing again, and a field left empty is let go.
    func finishTabEdit() {
        guard let id = editingTab, let tab = tabs.first(where: { $0.id == id }) else { return }
        if renamingTab {
            commitTabEdit()
            return
        }
        let draft = tabDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.isEmpty || tab.address.map({ Address.pretty($0) == draft }) == true
            || destination(for: draft) == nil {
            cancelTabEdit()
            return
        }
        commitTabEdit()
    }

    // MARK: - saying so

    /// A line that rises from the bottom, says one thing, and leaves.
    @Published private(set) var announcement: String?
    /// The symbol at the head of that line, when it has one.
    @Published private(set) var announcementSymbol: String?

    /// ⌘⇧C. The address, in the clipboard, and a line that says as much.
    func copyAddress() {
        guard let active else { return }
        copyAddress(of: active)
    }

    /// The address a tab is at now, not the one it was opened from: for a
    /// bookmark, the environment that is really open. The tab stays as it was.
    func copyAddress(of tab: Tab) {
        guard let url = tab.address else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        // The address itself, so what went onto the clipboard is seen, not
        // taken on trust.
        announce("Link copied: \(url.absoluteString)", symbol: "doc.on.doc")
    }

    /// For pasting into notes and messages that read Markdown: a title that
    /// links, not a bare address to explain in your own words.
    func copyMarkdownLink() {
        guard let tab = active, let url = tab.address else { return }
        // A backslash first, so the ones added next aren't doubled; then both
        // brackets, either of which would end or break the link's text.
        let title = tab.label
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("[\(title)](\(url.absoluteString))", forType: .string)
        announce("Link copied")
    }

    func announce(_ text: String, symbol: String? = nil) {
        announcementSymbol = symbol
        announcement = text
        hush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.announcement = nil
            self?.announcementSymbol = nil
        }
        hush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7, execute: work)
    }

    /// Tabs you closed, newest last, so ⌘⇧T can put them back where they were
    /// and the History menu can offer them by name.
    @Published private(set) var closedTabs: [Ghost] = []
    var ghosts: [Ghost] { ghosts(in: spaceID) }
    func ghosts(in space: UUID) -> [Ghost] { closedTabs.filter { $0.space == space } }
    func eraseClosedTabs(in space: UUID) { closedTabs.removeAll { $0.space == space } }

    struct Ghost: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let title: String
        let index: Int
        let space: UUID

        var label: String { title.isEmpty ? Address.pretty(url) : title }
    }

    /// Observations that last as long as the browser. A tab's own go with
    /// the tab (see Tab.followers).
    private var bag = Set<AnyCancellable>()
    /// The minute-by-minute look for tabs to put to sleep, and the ear for
    /// macOS saying memory is short. See Sleep.swift.
    var dozing: Timer?
    var pressure: DispatchSourceMemoryPressure?
    /// The pictures sleeping tabs keep, taken one at a time. See Pictures.swift.
    let pictures = Pictures()
    /// The Chrome Web Store's pages, told when installs come and go. See StoreRelay.swift.
    var storeWatch: AnyCancellable?
    private var hush: DispatchWorkItem?
    private var zoomShown = 100
    private var remembering = false
    /// The spaces whose rows changed since they were last written, the one
    /// on screen or parked ones (see rememberSession).
    private(set) var unsaved: Set<UUID> = []
    /// Spaces (see Spaces.swift): every one, the one on screen, and the
    /// rows of tabs of the others.
    @Published var spaces = Spaces.read()
    @Published var spaceID = Space.firstID
    var parked: [UUID: Parked] = [:]
    /// How far the column's rows have followed two fingers sideways, and
    /// whether the card for a new space stands in for them (see SpaceSwipe).
    @Published var spaceSwipe: CGFloat = 0
    @Published var makingSpace = false
    /// Which way the last change of space went: 1 to the next, -1 back.
    @Published var spaceStep = 1

    // MARK: - beginning and ending

    override init() {
        super.init()
        Shield.shared.enabled = prefs.shielded
        Shield.shared.compile()
        if prefs.bench { Bench.shared.start(for: self) }
        if prefs.developerAlerts { DeveloperAlerts.shared.start(for: prefs) }
        welcoming = !prefs.welcomed
        // The first launch of a newer build says what it brought, once.
        gate = Arrival.take(returning: prefs.welcomed).map(Gate.arrived)
        // Asked to stay out of the way: it starts that way (see Fold.swift).
        folded = prefs.sidebar && prefs.sideHides
        // Once a day, quietly: is there a newer one?
        Updater.shared.checkIfDue { [weak self] line in self?.announce(line) }
        FormRelay.passkeysOffered = prefs.passkeys
        ScrollRelay.on = prefs.showsReading
        FormRelay.saving = prefs.savesPasswords
        FormRelay.filling = prefs.fillsPasswords

        // An icon that arrives is put on every tab showing that site, not only
        // the one that happened to ask for it.
        Favicons.shared.arrived = { [weak self] host, image in
            guard let self else { return }
            for tab in tabs + parkedTabs where tab.address?.host()?.lowercased() == host {
                tab.icon = image
            }
        }
        // The floating window routes every exit through the same landing path.
        floater.onReturn = { [weak self] in
            guard let self else { return }
            // The window closes first, and unconditionally. Hanging that on
            // finding the tab again is how a little window survives the button
            // meant to dismiss it.
            let came = self.floating
            self.land()
            if let came, let tab = (self.tabs + self.parkedTabs).first(where: { $0.id == came }) {
                if tab.space != self.spaceID { self.switchSpace(to: tab.space) }
                self.playback.minimized = nil
                self.select(tab)
            }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.contentView != nil }?.makeKeyAndOrderFront(nil)
        }
        floater.onSkip = { [weak self] seconds in
            guard let self, let id = self.floating,
                  let tab = (self.tabs + self.parkedTabs).first(where: { $0.id == id })
            else { return }
            tab.web.evaluateJavaScript(Isolate.skip(seconds))
        }
        floater.onProgress = { [weak self] answer in
            guard let self, let id = self.floating,
                  let tab = (self.tabs + self.parkedTabs).first(where: { $0.id == id })
            else { return }
            tab.web.evaluateJavaScript(Isolate.where_) { found, _ in
                MainActor.assumeIsolated {
                    guard let pair = found as? [Any], pair.count == 2,
                          let through = pair[0] as? Double,
                          let playing = pair[1] as? Bool
                    else { return }
                    answer(through, playing)
                }
            }
        }
        floater.onPlayPause = { [weak self] answer in
            guard let self, let id = self.floating,
                  let tab = (self.tabs + self.parkedTabs).first(where: { $0.id == id })
            else { return }
            tab.web.evaluateJavaScript(Isolate.toggle) { playing, _ in
                MainActor.assumeIsolated { answer((playing as? Bool) ?? true) }
            }
        }
        floater.onMeeting = { [weak self] answer in
            guard let self, let id = self.floating,
                  let tab = (self.tabs + self.parkedTabs).first(where: { $0.id == id })
            else { return }
            tab.web.evaluateJavaScript(Meeting.state) { found, _ in
                MainActor.assumeIsolated {
                    guard let state = found as? [String: Any] else { return }
                    answer(Meeting.State(state))
                }
            }
        }
        floater.onPress = { [weak self] name in
            guard let self, let id = self.floating,
                  let tab = (self.tabs + self.parkedTabs).first(where: { $0.id == id })
            else { return }
            // Pressed from the app, which WebKit counts as a gesture of the
            // person: presenting asks for a screen, which a page may do only
            // in answer to one.
            tab.web.evaluateJavaScript(Meeting.press(name)) { pressed, _ in
                // A page that no longer offers its leave button is still in the
                // meeting, and the window stays.
                MainActor.assumeIsolated {
                    if name == "leave", (pressed as? Bool) == true { self.hangingUp(tab, beats: 16) }
                }
            }
        }
        floater.onClose = { [weak self] in self?.land() }
        floater.onMinimize = { [weak self] in self?.minimizeMedia() }

        // Yesterday's tabs, or one empty one. Either way a web view is built
        // now, which starts a content process while the window is still being
        // drawn — so the first address you type navigates instead of waiting
        // for WebKit to get up.
        defer {
            follow()
            watchForSleep()
        }

        // A file that stopped saving is said out loud, once (see Writer.swift).
        Writer.trouble = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.announce("Couldn't save to disk — is it full?") }
            }
        }

        // What a deleted space left behind, if WebKit wouldn't let it go then.
        Spaces.sweep()
        // The space you were in, when there are spaces (see Spaces.swift).
        if prefs.usesSpaces, let last = Store.settings.string(forKey: "space.current").flatMap(UUID.init),
           spaces.contains(where: { $0.id == last }) {
            spaceID = last
            Spaces.current = last
        }
        // An extension controller is tied to this space's WebKit store.
        if #available(macOS 15.4, *) { Extensions.forSpace(spaceID).start(for: self) }
        restoreSession()
        if prefs.usesSpaces { preloadSpaces() }
    }

    /// The row of tabs the space on screen had last time, or one empty tab.
    func restoreSession() {
        let saved = Session.read(space: spaceID)
        guard !saved.tabs.isEmpty else {
            // A blank tab costs nothing until it is asked for its page. Its
            // web view — and with it WebKit's helper processes — is built a
            // moment after the window is up, so that the first address typed
            // finds everything already running, and the first frame never
            // had to share the CPU with it.
            let tab = Tab()
            adopt(tab)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak tab] in
                guard let tab, tab.isBlank else { return }
                _ = tab.web
            }
            return
        }
        for entry in saved.tabs {
            guard let url = URL(string: entry.url) else { continue }
            let tab = Tab()
            prepare(tab)
            tab.restore(url: url, title: entry.title, name: entry.name)
            tab.pin = entry.pin
            tab.migration = entry.migration
            tabs.append(tab)
            if let bookmark = entry.bookmark, Shelf.holds(bookmark, bookmarks.roots) { shelfTabs[tab.id] = bookmark }
        }
        guard !tabs.isEmpty else {
            adopt(Tab())
            return
        }
        let here = min(max(0, saved.active), tabs.count - 1)
        restorePanels(saved, row: tabs)
        activeID = tabs[here].id
        // Only the visible entry loads: one page or its selected composition.
        wakePanels()
    }

    /// The few settings that something else has to be told about. The rest are
    /// read where they are used.
    private func follow() {
        followStore()
        // Spaces turned off: back to the first, whose tabs are the ones there
        // were before (see Spaces.swift).
        prefs.$usesSpaces
            .dropFirst()
            .sink { [weak self] on in if on { self?.preloadSpaces() } else { self?.leaveSpaces() } }
            .store(in: &bag)
        prefs.$shielded
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                Shield.shared.enabled = on
                Shield.shared.apply(to: (tabs + parkedTabs).compactMap { $0.built?.configuration.userContentController })
                announce(on ? "Ads and trackers blocked" : "Blocking off — reload to see the difference")
            }
            .store(in: &bag)

        // The look changes — from Settings, or from the Mac while set to
        // System — and the icons a site keeps for each scheme change with it.
        // A beat after, so the appearance has actually turned over.
        prefs.$look
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.relook() }
            }
            .store(in: &bag)
        DistributedNotificationCenter.default().publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self?.prefs.look == .system else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.relook() }
            }
            .store(in: &bag)

        prefs.$bench
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                if on { Bench.shared.start(for: self) } else { Bench.shared.stop() }
                announce(on ? "Scripts can drive Escale — see ./bench" : "The bench is closed")
            }
            .store(in: &bag)

        prefs.$developerAlerts
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                if on { DeveloperAlerts.shared.start(for: prefs) } else { DeveloperAlerts.shared.stop() }
                announce(on ? "Developer alerts on" : "Developer alerts off")
            }
            .store(in: &bag)

        // Every tab's next page, and the page each is showing now (see AutoScroll.swift).
        prefs.$autoScroll
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                for tab in tabs + parkedTabs {
                    tab.arm(hiding: curtain(for: tab.space).css(on: curtain.host(of: tab.address)))
                    tab.built?.evaluateJavaScript(on ? AutoScroll.script : AutoScroll.off)
                }
            }
            .store(in: &bag)

        // Settings › Passwords: what pages do about sign-ins follows it, on
        // every tab's next page and the page each is showing now — with
        // neither saving nor filling, nothing (see FormRelay.saving).
        prefs.$savesPasswords
            .combineLatest(prefs.$fillsPasswords)
            .dropFirst()
            .sink { [weak self] saving, filling in
                guard let self else { return }
                FormRelay.saving = saving
                FormRelay.filling = filling
                // A list of accounts already hanging from a box goes too: it
                // would stay where it was and still fill in what was picked.
                if !filling { logins.dropChoice() }
                for tab in tabs + parkedTabs {
                    tab.arm(hiding: curtain(for: tab.space).css(on: curtain.host(of: tab.address)))
                    tab.built?.evaluateJavaScript(FormRelay.signIns)
                }
            }
            .store(in: &bag)

        // The reading bar: every tab's next page, and the page each is showing
        // now, report their scroll only while it is shown (see ScrollRelay).
        prefs.$showsReading
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                ScrollRelay.on = on
                for tab in tabs + parkedTabs {
                    tab.arm(hiding: curtain(for: tab.space).css(on: curtain.host(of: tab.address)))
                    tab.built?.evaluateJavaScript(on ? ScrollRelay.script : ScrollRelay.off)
                }
            }
            .store(in: &bag)

        // Every tab's next page, and the page each is showing now.
        prefs.$showsLinks
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                if !on { linkStatus.dismiss() }
                for tab in tabs + parkedTabs {
                    tab.arm(hiding: curtain(for: tab.space).css(on: curtain.host(of: tab.address)))
                    tab.built?.evaluateJavaScript(on ? HoveredLink.script : HoveredLink.off, in: nil, in: .defaultClient)
                }
            }
            .store(in: &bag)

        // The same for the menu over selected text (SelectionMenu.swift).
        prefs.$selectionMenu
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                if !on { selectionMenu.dismiss() }
                for tab in tabs + parkedTabs {
                    tab.arm(hiding: curtain(for: tab.space).css(on: curtain.host(of: tab.address)))
                    tab.built?.evaluateJavaScript(on ? SelectionWatch.script : SelectionWatch.off, in: nil, in: .defaultClient)
                }
            }
            .store(in: &bag)

        prefs.$passkeys
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                FormRelay.passkeysOffered = on
                // Each tab keeps whatever is hidden on the site it is showing:
                // re-arming with nothing would quietly restore every element
                // this person had taken off, everywhere.
                for tab in tabs + parkedTabs {
                    tab.arm(hiding: curtain(for: tab.space).css(on: curtain.host(of: tab.address)))
                }
                announce(on ? "Passkeys offered again — reload the page" : "Sites will ask for a password instead")
            }
            .store(in: &bag)

        // The window and the menus are drawn from this object; a setting that
        // changes what they show has to be heard here.
        prefs.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)

    }

    private func relook() {
        Favicons.shared.relook((tabs + parkedTabs).filter { !$0.asleep })
    }

    func writeSession(now: Bool = false) {
        writeSession(of: spaceID, now: now)
    }

    /// A space's row as it stands, on screen or parked, to that space's own
    /// file. A space with no row — deleted, or put away with spaces turned
    /// off — is not written: an empty row would erase what its file keeps.
    func writeSession(of space: UUID, now: Bool = false) {
        unsaved.remove(space)
        let row: [Tab], active: Tab.ID?
        if space == spaceID {
            (row, active) = (tabs, activeID)
        } else if let parked = parked[space] {
            (row, active) = (parked.tabs, parked.active)
        } else {
            return
        }
        let entries = row.map { tab -> Session.Entry? in
            // A bookmark's own tab comes back as its bookmark (see Shelf.swift).
            guard !tab.shy, !tab.bench, !onShelf(tab, in: space) || panels.group(tab.id) != nil else { return nil }
            // A sleeping tab holds its address in `pending`; asking for
            // it there too means a pin can never be written out of
            // existence by whatever its web view happens to be showing.
            guard let url = tab.pending ?? tab.address,
                  url.scheme?.hasPrefix("http") == true
            else { return nil }
            return Session.Entry(
                url: url.absoluteString, title: tab.title, pin: tab.pin, name: tab.name,
                bookmark: shelfTabs[tab.id], migration: tab.migration
            )
        }
        // The one looked at, counted among the tabs kept (see Session.shape).
        var shape = Session.shape(entries, active: row.firstIndex { $0.id == active })
        shape.panels = savedPanels(row: row, entries: entries)
        Session.write(now: now, space: space, shape)
    }

    /// A change to a space's row — the one on screen unless told — written a
    /// beat later, with every other space's that changed meanwhile: a parked
    /// space's pages go on moving while another is on screen.
    func rememberSession(_ space: UUID? = nil) {
        unsaved.insert(space ?? spaceID)
        guard !remembering else { return }
        remembering = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            remembering = false
            for space in unsaved { writeSession(of: space) }
        }
    }

    /// The app is quitting. Whatever the debounces were waiting out — the
    /// session's above, the history's, the hidden elements' — they stop
    /// waiting: this writes straight to disk, on the thread asking to quit,
    /// before there is a process left to finish the wait on its behalf.
    func flush() {
        writeSession(now: true)
        // And every parked space with a change still waiting, or with a page
        // still at work, which may have been retitled since it was written.
        // One whose tabs have no page has nothing newer than its file.
        for (space, row) in parked where unsaved.contains(space) || row.tabs.contains(where: { $0.built != nil }) {
            writeSession(of: space, now: true)
        }
        for history in histories.values { history.flush() }
        for habits in habitsBySpace.values { habits.flush() }
        for curtain in curtains.values { curtain.flush() }
        github.flush()
    }

    // MARK: - tabs

    func newTab() {
        if searchIsPrivate {
            newShyTab()
            return
        }
        // An explicitly approved extension still owns its New Tab page.
        if #available(macOS 15.4, *), let page = Extensions.shared.newTabPage {
            open(page, foreground: true)
            field.stopSummoning()
            rememberSession()
            return
        }
        beginNewTab(shy: false)
        if #available(macOS 15.4, *) { Extensions.shared.offerNewTabPage() }
    }

    /// A blank tab given an extension's new tab page: the page needs a view
    /// built from that extension's configuration, so it is a new tab in the
    /// blank one's place.
    func replaceBlank(_ tab: Tab, with url: URL) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let url = Browser.page(url)
        let page = Tab(configuration: Browser.extensionConfiguration(for: url))
        prepare(page)
        tabs[index] = page
        page.go(to: url)
        if activeID == tab.id { activeID = page.id; editing = false }
        // Out of the row for good, like any tab replaced (see replace(_:going:)).
        tab.close()
    }

    func select(_ tab: Tab) {
        defer { if panels.group(activeID) != nil { wakePanels(except: activeID) } }
        // The tab already on screen, picked again, comes back from Settings.
        tuning = false
        cancelTabEdit()
        field.stopSummoning()
        logins.dropChoice()
        if tab.id == activeID {
            editing = false
            field.typed = ""
            // Closing the last awake pin leaves search over that sleeping pin.
            if tab.asleep { _ = tab.wake() }
            return
        }
        // Coming back to the tab whose video is out brings it home first, so
        // it is never lifted and landed in the same breath.
        if floating == tab.id { land() }
        if panels.group(activeID)?.members.contains(tab.id) != true { leaving() }
        activeID = tab.id
        tab.touch()
        // A tab brought back from last time, or waking from ⌘W while pinned,
        // opens the moment you look at it — and only if there was nothing to
        // wake is this the other case, one whose page quietly died while you
        // were elsewhere, which revive() checks for on its own.
        if !tab.wake() { tab.revive() }
        rememberSession()
        editing = false
        field.typed = ""
    }

    /// ⌘W, or the cross on the tab. Closing the last one leaves a blank tab
    /// behind; closing that blank tab closes the window.
    func close(_ tab: Tab) {
        let sibling = panels.group(tab.id)?.members.first { $0 != tab.id }
        panels.remove(tab.id)
        if activeID == tab.id, let sibling, let next = tabs.first(where: { $0.id == sibling }) { select(next) }
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else {
            // Only a page can close a tab of a space not on screen.
            closeParked(tab)
            return
        }

        // A tab whose page is out in the little window takes the window with
        // it. Left alone, the window would go on holding a page belonging to a
        // tab that no longer exists.
        if floating == tab.id { land() }

        // A pinned tab is not closed by ⌘W — it is put down. The letter keeps
        // its place, the page is let go, and you land on whatever you were
        // looking at before. Only Unpin takes it out of the row.
        if tab.pin != nil {
            tab.rest()
            // Ordinary tabs first. Falling back to the most recent tab of any
            // kind meant closing one pin landed you on another pin, and ⌘W
            // bounced between the two instead of getting you out of them.
            let others = tabs.filter { $0.id != tab.id && !$0.asleep }
            let loose = others.filter { $0.pin == nil }
            if let sibling, let next = tabs.first(where: { $0.id == sibling }) {
                select(next)
            } else if let back = (loose.isEmpty ? others : loose).max(by: { $0.touched < $1.touched }) {
                select(back)
            } else if let asleepPin = tabs.first(where: { $0.id != tab.id }) {
                select(asleepPin)
            } else {
                newTab()
            }
            writeSession(now: true)
            return
        }

        if tabs.count == 1 {
            if tab.isBlank {
                NSApp.keyWindow?.performClose(nil)
            } else {
                let fresh = Tab()
                remember(tab, at: 0)
                tab.close()
                adopt(fresh)
                tabs = [fresh]
                activeID = fresh.id
                field.typed = ""
            }
            return
        }

        remember(tab, at: index)
        tab.close()
        tabs.remove(at: index)
        if activeID == tab.id {
            // The page a link was opened from, when it is still in the row:
            // closing what you followed brings you back to where you were,
            // not to whatever sits next to it. Otherwise the neighbour on
            // the right, or the last one if there is no right — through
            // select(), same as everywhere else you land on a tab, so one
            // that was never built yet actually wakes up instead of sitting
            // there blank until a manual reload.
            let source = (tab.origin ?? tab.opener).flatMap { id in tabs.first { $0.id == id } }
            select(source ?? tabs[min(index, tabs.count - 1)])
        }
        rememberSession()
    }

    /// Everything but this one. Pinned tabs are put down rather than removed —
    /// they are not open pages so much as places kept.
    func closeOthers(but keep: Tab) {
        select(keep)
        let kept = Set(panels.group(keep.id)?.members ?? [keep.id])
        // The list is read once: closing walks the row and can add to it.
        for tab in tabs.filter({ !kept.contains($0.id) }) {
            close(tab)
        }
        select(keep)
    }

    /// What the Tabs heading's Clear closes: the ordinary tabs of a space, the
    /// ones listed under that heading. Pins and a bookmark's own tab keep their
    /// sections (see Shelf.swift). `space` is nil for the one on screen. A
    /// blank tab that is the whole row is already what Clear would leave.
    func clearableTabs(in space: UUID? = nil) -> [Tab] {
        let row = space == nil || space == spaceID ? tabs : parked[space ?? spaceID]?.tabs ?? []
        let loose = row.filter { $0.pin == nil && !onShelf($0, in: space) }
        return row.count == 1 && loose.first?.isBlank == true ? [] : loose
    }

    /// Clear, at the Tabs heading. Every ordinary tab is closed as ⌘W closes
    /// it (each can be reopened with ⌘⇧T; history and site data are not
    /// touched). Landing first, on the tab looked at last among those that
    /// stay, keeps the walk from waking pages that are about to go; with none
    /// awake, a blank tab stands in so the window is never left without one.
    func clearTabs() {
        let doomed = clearableTabs()
        guard !doomed.isEmpty else { return }
        let gone = Set(doomed.map(\.id))
        if let activeID, gone.contains(activeID) {
            if let back = tabs.filter({ !gone.contains($0.id) && !$0.asleep }).max(by: { $0.touched < $1.touched }) {
                select(back)
            } else {
                let fresh = Tab()
                adopt(fresh)
                select(fresh)
            }
        }
        for tab in doomed { close(tab) }
        announce(doomed.count == 1 ? "Closed 1 tab" : "Closed \(doomed.count) tabs")
    }

    /// A link let go of over the tabs becomes a tab among them.
    func take(_ providers: [NSItemProvider]) -> Bool {
        var took = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                took = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { self.open(url, foreground: true) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                took = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text, let url = Address.url(from: text) else { return }
                    DispatchQueue.main.async { self.open(url, foreground: true) }
                }
            }
        }
        return took
    }

    /// ⌘⇧T. Back into the row at the place it left.
    func reopen() {
        guard let ghost = ghosts.last else { return }
        reopen(ghost)
    }

    /// One of them by name, from the History menu.
    func reopen(_ ghost: Ghost) {
        guard ghost.space == spaceID else { return }
        closedTabs.removeAll { $0.id == ghost.id }
        let tab = Tab()
        prepare(tab)
        leaving()
        tabs.insert(tab, at: min(ghost.index, tabs.count))
        activeID = tab.id
        editing = false
        field.typed = ""
        tab.go(to: ghost.url)
    }

    private func remember(_ tab: Tab, at index: Int) {
        guard !tab.shy, let url = tab.address else { return }
        closedTabs.append(Ghost(url: url, title: tab.title, index: index, space: tab.space))
        if closedTabs.count > 12 { closedTabs.removeFirst() }
    }

    /// Dragged from one place in the row to another.
    func move(_ tab: Tab, to index: Int) {
        guard let here = tabs.firstIndex(where: { $0.id == tab.id }),
              index != here, tabs.indices.contains(index)
        else { return }
        // The pinned block and the loose one don't mix: a letter that wandered
        // into the middle of the titles would stop meaning anything.
        let pinned = pinnedCount
        if tab.pin != nil, index >= pinned { return }
        if tab.pin == nil, index < pinned { return }
        tabs.move(fromOffsets: IndexSet(integer: here), toOffset: index > here ? index + 1 : index)
        rememberSession()
    }

    /// A regular tab moved to another space needs that space's WebKit store;
    /// a private tab keeps its temporary store and sign-ins. A new tab takes
    /// the address, name and pin because its configuration cannot change.
    /// This is the drop after a rail hover has shown the destination. A blank
    /// tab's draft is captured before that hover switches the visible Space.
    @discardableResult
    func transfer(_ tab: Tab, to destination: UUID, draft: String? = nil) -> Tab? {
        guard prefs.usesSpaces, destination != tab.space,
              spaces.contains(where: { $0.id == destination }),
              !tab.bench else { return nil }
        let url = tab.address
        let draft = draft ?? (tab.id == activeID && url == nil ? field.typed : nil)
        // Extension pages need their context's WebKit configuration to load.
        // Each space owns its extensions, so the page is resolved in the
        // destination before closing the source: an extension not loaded
        // there cannot be moved, while ordinary pages use its store.
        let extensionPage = url.flatMap { Browser.extensionConfiguration(for: $0, space: destination) }
        if url?.scheme == "chrome-extension", extensionPage == nil { return nil }
        let configuration = extensionPage ?? (tab.shy
            ? Web.configuration(shy: true, space: destination, store: tab.store.isPersistent ? nil : tab.store) : nil)
        if tab.space == spaceID {
            guard let at = tabs.firstIndex(where: { $0.id == tab.id }) else { return nil }
            panels.remove(tab.id)
            tabs.remove(at: at)
            if activeID == tab.id { activeID = tabs.first?.id }
            rememberSession()
        } else {
            guard var row = parked[tab.space], let at = row.tabs.firstIndex(where: { $0.id == tab.id }) else { return nil }
            panels.remove(tab.id)
            row.tabs.remove(at: at)
            if row.active == tab.id { row.active = row.tabs.first?.id }
            parked[tab.space] = row
            rememberSession(tab.space)
        }
        shelfTabs[tab.id] = nil
        tab.close()
        switchSpace(to: destination)
        let moved = Tab(shy: tab.shy, space: destination, configuration: configuration)
        moved.pin = tab.pin
        moved.migration = tab.migration
        moved.name = tab.name
        prepare(moved)
        if moved.pin != nil {
            tabs.insert(moved, at: pinnedCount)
        } else {
            tabs.append(moved)
        }
        activeID = moved.id
        if let url {
            editing = false
            moved.go(to: url)
        } else {
            editing = true
            field.typed = draft ?? ""
            field.askFocus()
        }
        writeSession(now: true)
        return moved
    }

    func step(_ direction: Int) {
        let entries = tabEntries
        guard entries.count > 1, let activeID,
              let here = entries.firstIndex(where: { $0.id == activeID || panels.group($0.id)?.members.contains(activeID) == true }) else { return }
        selectEntry(entries[(here + direction + entries.count) % entries.count])
    }

    func select(index: Int) {
        guard tabEntries.indices.contains(index) else { return }
        selectEntry(tabEntries[index])
    }

    /// A link opened from a page lands next to the page it came from, not at
    /// the far end of the row — unless it is one of a batch, which keeps the
    /// order it came in.
    ///
    /// `from`: the tab it was opened out of. A private one's opens private,
    /// in the same store, as a link that asks for a new window already does.
    @discardableResult
    func open(_ url: URL, foreground: Bool, atEnd: Bool = false, from source: Tab? = nil, shy: Bool = false) -> Tab {
        // An extension's own page is served only to a view built from that
        // extension's configuration.
        let url = Browser.page(url)
        let page = Browser.extensionConfiguration(for: url)
        let tab = if let source, source.shy, page == nil {
            Tab(shy: true, configuration: Web.configuration(shy: true, store: source.store))
        } else {
            Tab(shy: shy, configuration: page)
        }
        prepare(tab)
        let here = atEnd ? nil : tabs.firstIndex { $0.id == activeID }
        tabs.insert(tab, at: here.map { $0 + 1 } ?? tabs.count)
        tab.go(to: url)
        if foreground {
            leaving()
            activeID = tab.id
            editing = false
            field.typed = ""
        }
        return tab
    }

    /// An extension's page sending its own tab to a website — 1Password's
    /// "Sign in" does, when its Mac app isn't connected. The page's view was
    /// built from the extension's configuration, which WebKit keeps to that
    /// extension's own pages, so the load went nowhere and the button did
    /// nothing. The tab is swapped where it stands for an ordinary one on
    /// the site: to the eye, the page went there. The other way round too:
    /// an extension sending a website's tab to one of its own pages.
    func replace(_ tab: Tab, going url: URL) {
        // The row it is in, on screen or parked (see Spaces.swift).
        let here = tabs.firstIndex { $0.id == tab.id }
        let there = parked[tab.space]?.tabs.firstIndex { $0.id == tab.id }
        guard here != nil || there != nil else { return }
        // A private tab stays private, and keeps its own sign-ins when it
        // had them; an extension's page it showed was in that extension's
        // store, so going back to the web takes a new private one.
        let page = Browser.extensionConfiguration(for: url)
        let fresh = if tab.shy {
            Tab(shy: true, bench: tab.bench, space: tab.space, configuration: page
                ?? Web.configuration(shy: true, store: tab.store.isPersistent ? nil : tab.store))
        } else {
            Tab(bench: tab.bench, space: tab.space, configuration: page)
        }
        prepare(fresh)
        if let here {
            let wasActive = activeID == tab.id
            tabs[here] = fresh
            if wasActive { activeID = fresh.id }
        } else if let there {
            parked[tab.space]?.tabs[there] = fresh
            if parked[tab.space]?.active == tab.id { parked[tab.space]?.active = fresh.id }
        }
        fresh.go(to: url)
        tab.close()
        rememberSession(tab.space)
    }

    /// An address from before extensions moved to chrome-extension://, as
    /// it is now; any other, as it is.
    static func page(_ url: URL) -> URL {
        if #available(macOS 15.4, *) { return Extensions.current(url) }
        return url
    }

    /// The extension an address belongs to, or nil for the web.
    static func extensionHost(of url: URL) -> String? {
        guard #available(macOS 15.4, *) else { return nil }
        let url = Extensions.current(url)
        return url.scheme == Extensions.scheme ? url.host : nil
    }

    /// The configuration for an extension's page, or nil for anything else.
    /// `space`: whose extensions to ask, when it is not the one on screen.
    static func extensionConfiguration(for url: URL, space: UUID? = nil) -> WKWebViewConfiguration? {
        guard #available(macOS 15.4, *) else { return nil }
        let url = Extensions.current(url)
        guard url.scheme == Extensions.scheme else { return nil }
        let owner = space.map(Extensions.forSpace) ?? Extensions.shared
        return owner.controller.extensionContext(for: url)?.webViewConfiguration
    }

    /// A page for the bench: at the end of the row, behind whatever you are
    /// looking at, and marked as not yours.
    @discardableResult
    func benchOpen(_ url: URL) -> Tab {
        let url = Browser.page(url)
        let tab = Tab(bench: true, configuration: Browser.extensionConfiguration(for: url))
        prepare(tab)
        tabs.append(tab)
        tab.go(to: url)
        return tab
    }

    /// A link from another app. A blank tab with nothing typed in it takes
    /// the page rather than staying behind as an empty one; otherwise the
    /// page gets a tab of its own, in front.
    func arrive(_ url: URL, foreground: Bool = true, atEnd: Bool = false) {
        // External links and app tools share the routing boundary (LinkRoutes.swift).
        if routeLink(url, from: active?.shy == true ? active : nil) { return }
        if !foreground { open(url, foreground: false, atEnd: atEnd); return }
        if let active, active.isBlank, field.typed.isEmpty, !active.floating {
            active.go(to: url)
            editing = false
        } else {
            open(url, foreground: true)
        }
    }

    /// A bookmark, or a page from a list of them: into the tab you are on,
    /// the way every bookmarks bar has ever worked — into a new one with ⌘
    /// held, or when the one you are on is busy playing in the float.
    func visit(_ url: URL) {
        if field.opening != nil {
            navigateFromField(url)
            return
        }
        let apart = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        if let active, !apart, !active.floating {
            active.go(to: url)
            editing = false
            field.typed = ""
        } else {
            open(url, foreground: true, from: active)
        }
    }

    /// A bookmark picked from the button's list or the full one. Either
    /// goes as the page starts: the list off the button used to stay open
    /// over the page it had just sent you to.
    func pickBookmark(_ url: URL) {
        bookmarking = false
        bookmarksOpen = false
        visit(url)
    }

    /// ⌘⇧N. A tab that keeps nothing — its own cookies, its own sign-ins, no
    /// history, and no place in tomorrow's session.
    func newShyTab() {
        beginNewTab(shy: true)
        announce("Private search")
    }

    /// ⌘D. The same page, beside itself.
    func duplicate() {
        guard let url = active?.address else { return }
        open(url, foreground: true, from: active)
    }

    /// ⌘⇧V, when nothing is being typed. What is in the clipboard, if it is a
    /// place — or a search — in the tab you're on.
    func pasteAndGo() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let url = destination(for: text.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            field.refuse()
            return
        }
        navigateFromField(url)
        editing = false
        field.typed = ""
    }

    /// ⌘P. The system's own sheet, which is also where "save as PDF" lives.
    func printPage() {
        guard let tab = active, !tab.isBlank, let window = NSApp.keyWindow else { return }
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.isHorizontallyCentered = false
        let job = tab.web.printOperation(with: info)
        job.view?.frame = tab.web.bounds
        job.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// A space's row as its session left it, made without touching the one
    /// on screen: tabs with an address and no page yet, which cost next to
    /// nothing until one is looked at (see Spaces.swift).
    func loadRow(_ space: UUID) -> Parked {
        let saved = Session.read(space: space)
        var row: [Tab] = []
        for entry in saved.tabs {
            guard let url = URL(string: entry.url) else { continue }
            let tab = Tab(space: space)
            prepare(tab)
            tab.restore(url: url, title: entry.title, name: entry.name)
            tab.pin = entry.pin
            tab.migration = entry.migration
            row.append(tab)
            if let bookmark = entry.bookmark, Shelf.holds(bookmark, bookmarks(of: space).roots) { shelfTabs[tab.id] = bookmark }
        }
        restorePanels(saved, row: row)
        let active = row.indices.contains(saved.active) ? row[saved.active].id : row.first?.id
        return Parked(tabs: row, active: active)
    }

    /// Attach only acknowledged imported addresses, without selecting or waking them.
    /// MigrationTabs owns the merge and its persistence (see MigrationTabs.swift).
    func attachImportedTabs(_ entries: [Session.Entry], to space: UUID) {
        guard space == spaceID || parked[space] != nil else { return }
        var pins: [Tab] = [], loose: [Tab] = []
        for entry in entries {
            guard let url = MigrationLimits.url(entry.url) else { continue }
            let tab = Tab(space: space)
            tab.restore(url: url, title: entry.title)
            tab.pin = entry.pin; tab.migration = entry.migration
            // Initial metadata is not navigation: avoid scheduling another
            // session write or retitling existing history during a tabs import.
            prepare(tab)
            if tab.pin != nil { pins.append(tab) } else { loose.append(tab) }
        }
        // Publish once: rebuilding observers for every appended tab makes a
        // large import quadratic even though none of its pages are awake.
        if space == spaceID {
            var row = tabs
            row.insert(contentsOf: pins, at: row.prefix { $0.pin != nil }.count)
            row += loose
            tabs = row
        } else if var row = parked[space] {
            row.tabs.insert(contentsOf: pins, at: row.tabs.prefix { $0.pin != nil }.count)
            row.tabs += loose
            parked[space] = row
        }
    }

    /// Another space's row put on screen in place of this one (see
    /// Spaces.swift) — empty, for one that restores its own.
    func showRow(_ row: [Tab], active: Tab.ID?) {
        tabs = row
        activeID = active ?? row.first?.id
    }

    private func adopt(_ tab: Tab) {
        prepare(tab)
        tabs.append(tab)
        if activeID == nil { activeID = tab.id }
    }

    /// Stepping away from a tab. A video you were watching does not stop
    /// existing because you went to look something up.
    func leaving() {
        // Audible video uses the sidebar player. Explicit Picture in Picture
        // still wins; silently lifting here would hide every YouTube source.
        // A meeting is always audible and is not a source to play or pause:
        // stepping away from it keeps the people in view.
        guard Players.isCall(active?.address) || !prefs.sidebar || active?.noisy != true else { return }
        lift(active, quietly: true)
    }

    /// ⌘⇧P, for lifting one out by hand.
    func toggleFloat() {
        if floater.showing {
            land()
            return
        }
        lift(active, quietly: false)
    }

    func floatMedia(_ id: UUID) {
        guard let tab = (tabs + parkedTabs).first(where: { $0.id == id }), tab.liftable else { return }
        lift(tab, quietly: false, fromMedia: true)
    }

    func minimizeMedia() {
        guard let id = floating, let tab = (tabs + parkedTabs).first(where: { $0.id == id }) else { return }
        land()
        if let web = tab.built { tab.media.reveal(web) }
        playback.selected = id
        playback.minimized = id
        prefs.sidebar = true
        folded = false
    }

    /// Everything but the video goes out of the way, and the page it lives in
    /// moves house — into a small window that stays above everything.
    private func lift(_ tab: Tab?, quietly: Bool, fromMedia: Bool = false) {
        // A tab just put down with ⌘W has no page to lift a video out of, and
        // asking it would only build an empty view to ask.
        guard let tab, !tab.isBlank, !tab.asleep, !floater.showing else { return }
        // On its own, only from a site whose video is the point of the site.
        // A hero background on a studio's home page is a video too, and it
        // followed people around the desktop. ⌘⇧P still lifts from anywhere.
        if quietly, !Players.knows(tab.address) { return }
        // A meeting has a window of its own (Meeting.swift), and opens it only
        // once there is a meeting: a page before joining opens nothing.
        let call = Players.isCall(tab.address)
        let script = call ? Meeting.on : fromMedia ? Isolate.media : Isolate.on
        tab.web.evaluateJavaScript(script) { [weak self] answer, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard (answer as? String) == "floating" else {
                    if !quietly { self.announce("Nothing is playing here") }
                    return
                }
                // Leaving asked before the tab was left; if it was returned to
                // while the page answered, the page belongs in the tab, not out.
                // Its answer already marked the page, so the marks come off.
                if quietly, self.active?.id == tab.id {
                    tab.web.evaluateJavaScript(call ? Meeting.off : Isolate.off)
                    return
                }
                self.floating = tab.id
                self.floatingMeeting = call
                tab.floating = true
                self.floater.lift(tab.web, call: call)
            }
        }
    }

    /// After the window's hang-up, until the meeting is really left. A host is
    /// asked whether to leave or to end the call for everyone, in a dialog the
    /// floating page does not show: it is answered with leave, as the button
    /// says. The page goes home once there is nothing left to leave. Still in
    /// the meeting after four seconds, it asks something else: the meeting's
    /// tab is brought forward to show it, rather than the window closing on a
    /// call that goes on.
    private func hangingUp(_ tab: Tab, beats: Int) {
        guard floating == tab.id else { return }
        tab.web.evaluateJavaScript(Meeting.state) { [weak self] found, _ in
            MainActor.assumeIsolated {
                guard let self, self.floating == tab.id else { return }
                if let answer = found as? [String: Any] {
                    let state = Meeting.State(answer)
                    if !state.leave, !state.asking { return self.land() }
                    if state.asking { tab.web.evaluateJavaScript(Meeting.press("leave")) }
                }
                guard beats > 0 else { return self.floater.onReturn?() ?? () }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.hangingUp(tab, beats: beats - 1)
                }
            }
        }
    }

    /// Back into its tab. The stage takes the page again on its next layout,
    /// which is what the self-healing there is for.
    func land() {
        // The window closes whatever else is true. Tying that to the bookkeeping
        // is how a little window outlives the thing that opened it.
        if floater.showing { floater.drop() }
        guard let id = floating, let tab = (tabs + parkedTabs).first(where: { $0.id == id }) else { return }
        floating = nil
        tab.floating = false
        // A meeting that has ended may have moved its page off the meeting's
        // address without a new document, and would stay drawn over it.
        tab.web.evaluateJavaScript(floatingMeeting ? Meeting.off : Isolate.off)
        // The zoom a meeting floated at gives way to the one kept for wherever
        // the page is now: it may have gone to another site meanwhile.
        if floatingMeeting { tab.applyRememberedZoom() }
    }

    private func prepare(_ tab: Tab) {
        tab.onPanelFocus = { [weak self] tab in
            guard let self, self.panels.group(tab.id) != nil, self.activeID != tab.id,
                  self.tabs.contains(where: { $0 === tab }) else { return }
            self.select(tab)
        }
        tab.onPanelEnd = { [weak self] tab in self?.panels.remove(tab.id) }
        tab.media.changed = { [weak self, weak tab] in
            if let tab { self?.playback.update(tab) }
            // A page turns out to be a video a beat after it turns audible.
            self?.presences.changed()
        }
        tab.delegate = self
        tab.onPresence = { [weak self] in self?.presences.changed() }
        tab.onLink = { [weak self] tab, address in
            guard let self, prefs.showsLinks, tab.id == activeID else { return }
            linkStatus.show(address, over: tab.built)
        }
        tab.onSelection = { [weak self] tab, spot in
            guard let self, prefs.selectionMenu, tab.id == activeID else { return }
            selectionMenu.show(spot, in: tab.id, page: tab.built?.bounds.size ?? .zero)
        }
        tab.onPick = { [weak self] tab, selector, label, note in
            guard let self, let host = curtain.host(of: tab.address) else { return }
            curtain(for: tab.space).hide(selector, label: label, note: note, on: host)
            let css = curtain(for: tab.space).css(on: host)
            tab.arm(hiding: css)
            tab.applyVeils(css)
            announce("Hidden — ⌘Z puts it back")
        }
        tab.onPickEnd = { [weak self] _ in self?.veiling = false }
        tab.onImageMenu = { [weak self] tab, url in self?.showImageMenu(for: tab, at: url) }
        tab.searchName = { [weak self] in self.map { $0.prefs.engine.name(custom: $0.prefs.customEngine) } }
        tab.onSearch = { [weak self] tab, text in
            guard let self, let url = self.searchURL(for: text) else { return }
            // From a private tab, the search is private too (see open(_:foreground:atEnd:from:)).
            self.open(url, foreground: true, from: tab)
        }
        tab.onStoreAdd = { [weak self] tab in self?.addFromStore(tab) }
        // The middle button on a link opens it beside the tab you are on, as
        // it does in every other browser (see MiddleRelay).
        // From a private tab, the new one is private too, as for ⌘-click.
        tab.onMiddleClick = { [weak self] tab, url in self?.openPageLink(url, from: tab, foreground: false) }
        tab.onCross = { [weak self] tab, url in self?.replace(tab, going: url) }

        // The caret in a sign-in box: the accounts kept for this site hang
        // from the box, and go when the caret does. Nothing is filled on
        // its own — the way Safari does it, and what a person expects.
        tab.onField = { [weak self] tab, spot in
            guard let self else { return }
            logins.caret(
                in: tab.id, at: spot, host: tab.formHost,
                filling: prefs.fillsPasswords && tab.id == activeID
            )
        }

        tab.onCredentials = { [weak self] tab, host, user, password in
            guard let self, prefs.savesPasswords, !password.isEmpty, !tab.shy,
                  !Vault.isNever(host, space: tab.space)
            else { return }
            // A password manager extension that asked Chrome's way to do the
            // saving itself.
            if #available(macOS 15.4, *), Extensions.forSpace(tab.space).passwordSavingTakenBy != nil { return }
            logins.sent(host: host, user: user, password: password, space: tab.space)
        }
        tab.onPickTrouble = { [weak self] _, reason in
            self?.announce("Couldn't hide that — \(reason)")
        }

        // The line at the bottom doubles as the zoom read-out: it keeps being
        // rewritten while you pinch and fades a moment after you stop.
        tab.onZoom = { [weak self] tab, value in
            guard let self else { return }
            // The selection has moved under the menu.
            if selectionMenu.shown?.tab == tab.id { selectionMenu.dismiss() }
            let percent = Int((value * 100).rounded())
            guard percent != zoomShown else { return }
            zoomShown = percent
            announce("\(percent)%")
        }

        // A page's title lands a beat after the page itself, and a history
        // entry that only ever holds an address is half a memory.
        // Anywhere a tab lands is worth remembering for next launch, in the
        // session of its own space.
        // Both are the tab's to hold, and go when it closes (see Tab.followers).
        let space = tab.space
        tab.$address
            .dropFirst()
            .sink { [weak self] _ in self?.rememberSession(space) }
            .store(in: &tab.followers)

        tab.$title
            .dropFirst()
            .sink { [weak self, weak tab] title in
                guard let tab, !tab.shy, !tab.bench, let url = tab.address else { return }
                self?.history(for: tab.space).retitle(url, title)
                self?.localhost.retitle(url, title: title, in: tab.space)
            }
            .store(in: &tab.followers)
    }

    // MARK: - guessing

    /// ⌘ let go of: take whatever the walk landed on.
    func landSummon() {
        guard field.cycling else { return }
        field.cycling = false
        guard field.picked != nil else { return }
        submit()
    }

    /// ⌘K. Only what is open, nothing else.
    func summon() {
        reviewing = false
        cancelTabEdit()
        field.startSummoning()
        editing = true
        field.askFocus()
    }

    /// A row clicked in the list, taken directly rather than through the
    /// keyboard's selection. The pointer and the arrow keys are answering the
    /// same question but must not share an answer: a list that appears under a
    /// resting cursor would otherwise rewrite the field before you had moved.
    func take(_ offer: Suggestion) {
        let choice = Choice(of: self)
        if let bookmark = offer.bookmark, offer.tab == nil || (field.selected?.id == offer.id && field.selectedEnvironment != nil) {
            if takeSearchBookmark(bookmark, environment: field.selected?.id == offer.id ? field.selectedEnvironment : nil) {
                learn(offer, choice)
            }
            return
        }
        field.stopSummoning()
        if let id = offer.tab {
            guard let tab = tabs.first(where: { $0.id == id }) else { field.refresh(); return }
            select(tab)
        } else {
            navigateFromField(offer.url)
        }
        learn(offer, choice)
        editing = false
        field.typed = ""
        field.picked = nil
    }

    // MARK: - the address field

    /// ⌘L. The current address comes up selected, so typing over it replaces it
    /// and Escape puts it back.
    func edit() {
        field.stopOpening()
        field.stopSummoning()
        field.typed = active?.address?.absoluteString ?? ""
        editing = true
        field.askFocus()
    }

    func dismiss() {
        field.stopOpening()
        field.stopSummoning()
        field.cycling = false
        // A blank tab has nothing behind the field to go back to.
        guard active?.isBlank == false else { field.refresh(); return }
        editing = false
        field.typed = ""
    }

    /// Return. A row picked from the list wins; otherwise what the field was
    /// finishing for you wins; otherwise what you actually typed. If none of
    /// those is a place, nothing happens and the field says so.
    func submit() {
        if let github = field.github {
            if let picked = github.picked { takeGitHub(picked) } else { field.refuse() }
            return
        }
        let offers = field.offers
        let choice = Choice(of: self)
        if let selected = field.selected, selected.tab != nil || selected.bookmark != nil {
            take(selected)
            return
        }

        // The switcher proposes nothing but pages you have open. It still has
        // to accept an address typed into it, though — the two fields look
        // alike, and a Return that quietly does nothing is the worst answer
        // either of them could give.
        if field.summoning {
            field.stopSummoning()
            guard !field.typed.trimmingCharacters(in: .whitespaces).isEmpty else {
                editing = false
                return
            }
        }

        let target: URL?
        var chosen: Suggestion?
        if let picked = field.picked, offers.indices.contains(picked) {
            chosen = offers[picked]
            target = offers[picked].url
        } else if field.ending != nil {
            target = Address.url(from: field.completed)
        } else {
            target = destination(for: field.typed)
        }

        guard let url = target else {
            field.refuse()
            return
        }
        navigateFromField(url)
        if let chosen { learn(chosen, choice) }
        editing = false
        field.typed = ""
    }

    // MARK: - the page

    func zoom(by factor: CGFloat) { active?.magnify(by: factor) }
    func resetZoom() { active?.resetZoom() }

    /// ⌘⇧R. The article, and nothing that was arranged around it.
    func toggleReader() {
        guard let tab = active else { return }
        tab.toggleReader { [weak self] worked in
            guard !worked else { return }
            self?.announce("Nothing to read on this page")
        }
    }

    func reload() { active?.reload() }
    func back() { active?.back() }
    func forward() { active?.forward() }
}

// MARK: - WebKit

extension Browser: WKNavigationDelegate, WKUIDelegate {
    /// Links the window has no business showing — mail, calls, an app's own
    /// scheme — are handed to whoever does own them.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // "Download Image", "Download Linked File" from the page's own
        // context menu, and a link with the `download` attribute all arrive
        // as an ordinary-looking action with this one flag set. Answered
        // with `.allow`, as anything else here was, WebKit tries to load it
        // as if it were the next page — nowhere for that to go, so nothing
        // happens and nothing says why. `.download` is what turns it into
        // the `WKDownload` that `didBecome download:` below already knows
        // what to do with.
        guard !action.shouldPerformDownload else {
            decisionHandler(.download)
            return
        }
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }

        // An extension's OAuth sign-in coming back: the address is the
        // answer, handed to the extension, and never loaded.
        if ExtensionAuth.intercept(url, browser: self, from: webView) {
            decisionHandler(.cancel)
            return
        }

        // Only a user-activated, top-level GET can cross stores. Redirects,
        // forms and subframe loads retain the page's context (LinkRoutes.swift).
        if action.navigationType == .linkActivated, action.buttonNumber != 4,
           action.targetFrame?.isMainFrame ?? true,
           action.request.httpMethod == "GET", let source = tab(for: webView),
           routeLink(url, from: source) {
            decisionHandler(.cancel)
            return
        }

        // An extension's page sending its own tab to a website (see
        // replace(_:going:)).
        if #available(macOS 15.4, *), ["http", "https"].contains(scheme),
           action.targetFrame?.isMainFrame ?? true,
           webView.url?.scheme == Extensions.scheme,
           let tab = tab(for: webView) {
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self] in self?.replace(tab, going: url) }
            return
        }

        // ⌘-click opens beside this tab and leaves you where you are; ⌘⇧-click
        // takes you with it.
        //
        // The middle button is not judged here. WebKit hands the browser a
        // navigation action for a ⌘-click and none at all for a middle one,
        // and where it does report a button it answers with a mask — 1 left,
        // 2 right, 4 middle — so a check for 2 here would have meant the right
        // button, not the middle (see MiddleRelay, which is where the middle
        // button is answered).
        //
        // Should a WebKit ever hand one over for the middle button after all,
        // it is cancelled: MiddleRelay has already opened the link in a tab of
        // its own, and letting this one through would take the page there too.
        if action.navigationType == .linkActivated, action.buttonNumber == 4 {
            decisionHandler(.cancel)
            return
        }
        if action.navigationType == .linkActivated,
           ["http", "https"].contains(scheme),
           action.modifierFlags.contains(.command) {
            let source = tab(for: webView)
            open(url, foreground: action.modifierFlags.contains(.shift), from: source).origin = source?.id
            decisionHandler(.cancel)
            return
        }

        // The next document gets this site's stylesheet of hidden things,
        // decided here because here is the last moment before it loads.
        if action.targetFrame?.isMainFrame ?? true, let tab = tab(for: webView) {
            let host = curtain.host(of: url)
            tab.arm(hiding: curtain(for: tab.space).css(on: host))
            // And the blocker, on or off for where it is going.
            Shield.shared.tune(webView.configuration.userContentController, for: host, in: tab.space)
        }

        // chrome-extension: an extension's own pages — options, a side
        // panel, a tab it opened. WebKit serves them; nothing else here does.
        if ["http", "https", "file", "about", "data", "blob", "chrome-extension", "webkit-extension"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    /// A link that asks for a new window gets a new tab. The configuration
    /// WebKit hands over has to be the one the new view is built with, or the
    /// opener and the opened can't talk to each other.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let opener = tab(for: webView)
        if action.navigationType == .linkActivated, action.request.httpMethod == "GET",
           !action.shouldPerformDownload, let url = action.request.url, let opener,
           routeLink(url, from: opener) { return nil }
        let tab = Tab(shy: opener?.shy ?? false, space: opener?.space, configuration: configuration)
        tab.opener = opener?.id ?? activeID
        if let space = opener?.space, space != spaceID, parked[space] != nil {
            // Opened by a page in a space not on screen: the window joins
            // that space's row, in front there, and this one is left alone.
            prepare(tab)
            parked[space]?.tabs.append(tab)
            parked[space]?.active = tab.id
        } else {
            adopt(tab)
            activeID = tab.id
            editing = false
        }
        // Returning the view is what makes it the target. WebKit loads the
        // request into it itself when the action carries one.
        if let url = action.request.url { tab.setAddressOptimistically(url) }
        return tab.web
    }

    /// Anything the window can't show is something to keep instead.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // A redirect (3xx) has nowhere to be shown and carries no content of
        // its own, but must be followed rather than downloaded — even if its
        // headers say `application/binary` or `application/octet-stream`, as
        // youtube.com and some servers do on their redirects.
        if let http = response.response as? HTTPURLResponse, (300...399).contains(http.statusCode) {
            decisionHandler(.allow)
            return
        }
        if response.isForMainFrame && response.canShowMIMEType { tab(for: webView)?.jsonReader.detect(response.response) }
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        keep(download)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        keep(download)
    }

    /// Without this WebKit refuses every request out of hand, and a page that
    /// asks for the camera simply never gets an answer.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        guard let tab = tab(for: webView) else { decisionHandler(.deny); return }
        let host = origin.host.isEmpty ? (tab.address?.host() ?? "This page") : origin.host
        let key = Self.captureKey(host: host, type: type.rawValue, space: tab.space)

        if let remembered = captureChoice(host: host, type: type.rawValue, space: tab.space) {
            decisionHandler(remembered ? .grant : .deny)
            return
        }
        // One question at a time. A second page asking while the first is still
        // waiting is refused rather than queued behind it.
        guard decide == nil else {
            decisionHandler(.deny)
            return
        }

        decide = decisionHandler
        askedAbout = key
        asking = CaptureAsk(host: host, wants: Browser.name(for: type), space: tab.space)
    }

    private static func name(for type: WKMediaCaptureType) -> String {
        switch type {
        case .camera: return "camera"
        case .microphone: return "microphone"
        case .cameraAndMicrophone: return "camera and microphone"
        @unknown default: return "camera and microphone"
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(webView, error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        fail(webView, error)
    }

    /// A page asking to close itself.
    ///
    /// Signing in with Google — or with anything using OAuth — happens in a
    /// window the page opens, and that window calls close() when it is done.
    /// With nobody listening for it, what is left behind is a tab holding the
    /// blank page the flow ended on: nothing to look at, and nothing for
    /// reload to fetch, because there is no longer an address to fetch.
    func webViewDidClose(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        // Back to whoever opened it, so you land where you started the sign-in
        // rather than wherever the row happens to put you.
        if let opener = tab.opener, let home = tabs.first(where: { $0.id == opener }) {
            select(home)
        }
        tab.pin = nil
        close(tab)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        tab.invalidatePageData()
        logins.dropChoice(in: tab.id)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        if tab.id == activeID { linkStatus.dismiss() }
        if selectionMenu.shown?.tab == tab.id { selectionMenu.dismiss() }
        tab.arrived()
        tab.typing = false
        // Whatever you last set this site to, before it draws a single frame
        // at the wrong size.
        tab.applyRememberedZoom()
    }

    /// The page has drawn something: a view kept out of sight until now, so
    /// as not to show the white it starts as, comes in. WebKit calls this only
    /// on a view asked to — see `PageView.holdForFirstFrame()`.
    @objc(_webView:renderingProgressDidChange:)
    func webView(_ webView: WKWebView, renderingProgressDidChange events: UInt) {
        guard events & PageView.firstFrame != 0 else { return }
        let tab = tab(for: webView)
        // Make the page opaque before fading its cover: two simultaneous
        // fades would expose the empty ground between them.
        (webView as? PageView)?.showFirstFrame("rendering-progress", animated: tab?.returning != true)
        tab?.reveal()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A page with nothing to lay out never has a first frame. Done is
        // done, and it is shown.
        (webView as? PageView)?.showFirstFrame("navigation-finished", animated: tab(for: webView)?.returning != true)
        guard let tab = tab(for: webView), let url = tab.address else { return }
        tab.reveal()
        tellStore(tab)
        // A page that arrived after a password went out: did the sign-in take?
        tab.settleSignIn()
        // The icon is asked for whether or not the tab is showing one: it may
        // be turned on a moment later, and a tab that then has to wait for a
        // fetch looks broken.
        Favicons.shared.fetch(for: tab)
        guard !tab.shy, !tab.bench else { return }
        history(for: tab.space).record(url, title: tab.title)
        localhost.record(url, title: tab.title, in: tab.space)
    }

    private func fail(_ webView: WKWebView, _ error: Error) {
        let nsError = error as NSError
        let code = nsError.code
        // Cancelled is not a failure: it's what a redirect, a stopped load, or
        // a second Return in quick succession looks like from here.
        guard code != NSURLErrorCancelled else {
            tab(for: webView)?.stayed()
            return
        }
        // Nor is a page that turned into a download: WebKit ends that
        // navigation with "frame load interrupted" (102) while the file goes
        // on arriving. Answered as a failure, it covered the page with "The
        // page didn't load" over a download that had worked — clicked again,
        // it downloaded again.
        if nsError.domain == "WebKitErrorDomain" && code == 102 {
            (webView as? PageView)?.showFirstFrame("download", animated: false)
            tab(for: webView)?.uncover()
            tab(for: webView)?.stayed()
            return
        }
        // A video or sound opened on its own goes to WebKit's player, which
        // ends the navigation with "plug-in handled load" (204) a moment
        // after it starts playing. The page arrived: it is a finish.
        if nsError.domain == "WebKitErrorDomain" && code == 204 {
            self.webView(webView, didFinish: nil)
            return
        }
        tab(for: webView)?.uncover()
        tab(for: webView)?.failed(message(for: code), at: nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
    }

    private func message(for code: Int) -> String {
        switch code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "No site at that address."
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "No connection."
        case NSURLErrorTimedOut:
            return "The site took too long to answer."
        case NSURLErrorCannotConnectToHost:
            return "The site refused the connection."
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "The connection isn't secure."
        default:
            return "The page didn't load."
        }
    }

    /// The tab a page belongs to, in whichever space: a parked space's pages
    /// go on loading, redirecting and failing while another is on screen.
    func tab(for webView: WKWebView) -> Tab? {
        tabs.first { $0.built === webView } ?? parkedTabs.first { $0.built === webView }
    }
}
