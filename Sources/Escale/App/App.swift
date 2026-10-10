import SwiftUI
import AppKit

// A window, a row of titles, and a field. Typing an address gets you a page;
// there is nothing else to learn and nothing else to press.

@main
struct EscaleApp: App {
    @StateObject private var browser = Browser()
    /// Links from other apps, and the Dock icon.
    @NSApplicationDelegateAdaptor(Links.self) private var links

    init() {
        // Whose browser this is, before anything is written: a test run
        // under an identity that isn't its world's stops here (see Store.admit).
        _ = Store.world
    }

    var body: some Scene {
        Window("Escale", id: "browser") {
            ContentView(browser: browser)
                .frame(minWidth: 640, minHeight: 420)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands { KeyMenus(browser: browser, prefs: browser.prefs) }
    }
}

/// A page, as a line in a menu: its icon if one is known, and its name.
struct MenuLine: View {
    let title: String
    let url: URL

    /// Observed so the line is drawn again when the icons it queued arrive.
    @ObservedObject private var favicons = Favicons.shared

    var body: some View {
        if let host = url.host()?.lowercased(),
           let icon = favicons.shown(host) {
            Label {
                Text(title)
            } icon: {
                Image(nsImage: MenuLine.small(icon))
            }
        } else {
            Text(title)
        }
    }

    /// The cached icon is sixty-four points across; a menu wants sixteen.
    private static func small(_ icon: NSImage) -> NSImage {
        let copy = icon.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

/// The base a sheet draws on, and the reason a panel is legible over a page
/// that has hidden its own cursor.
///
/// WebKit turns `cursor: none` into an AppKit cursor rect over the whole web
/// view. SwiftUI panels layered on top add no rect of their own, so when the
/// pointer crosses from the page into a sheet the invisible rect still wins,
/// and the sheet reads as empty air. This gives the sheet one arrow-sized
/// rect to win with, frontmost because its NSView sits above the web view
/// (a sheet is drawn by `.overlay { panels }` on `ContentView.body`).
private struct CursorGround: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CursorGroundView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class CursorGroundView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    // Re-arm the rect each time this view joins a window or changes size, so
    // AppKit notices it even if the pointer has not moved since the sheet
    // appeared. Without this the arrow only shows after a twitch.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }
}

struct ContentView: View {
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var browser: Browser

    @State private var keys: Any?
    @State private var window: NSWindow?


    /// The window: room at the top, one stage for the page, and the row when
    /// there is one.
    private var window_: some View {
        ZStack(alignment: .top) {
            // The envelope the column and the bars stand on (Glass.swift).
            // Black while a page has the screen, so the frame of our own window
            // that survives the transition is not a band across the top.
            if browser.active?.immersed == true && !browser.tuning { Color(nsColor: Palette.Film.ground) } else { Envelope() }
            // Developer mode, said by the envelope (Workbench.swift).
            if browser.showsWorkbench { DevelopingWash().transition(.opacity) }

            HStack(spacing: 0) {
                // The room the rail and the column take, drawn over it by
                // SidebarChrome below.
                Color.clear.frame(width: sideFootprint)

                VStack(spacing: 0) {
                    // Room for the traffic lights, and for the strip when there
                    // is one. The page starts under it, not behind it — a page
                    // sliding beneath floating chrome is a browser showing off,
                    // and it costs a compositing pass.
                    Color.clear.frame(height: band)

                    // The address over the page, in the column's mode, when
                    // Settings asks for it, and its head while the column is
                    // folded (see Bar.swift).
                    if browser.showsBar || foldedLine {
                        AddressBar(browser: browser, clearance: metrics.clearingLights(from: sideFootprint + AddressBar.inset(metrics)))
                            .frame(height: metrics.bar)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // The room of the sidebar's reading mark. The mark itself
                    // is drawn on the page's frame below, so it spans the
                    // page and no wider (ReadingLine.swift). The room stays
                    // while Settings stand in for the page.
                    if readingTab != nil {
                        Color.clear.frame(height: ReadingLine.height(metrics))
                    }

                    // One stage, always, in its own rounded frame. The
                    // overlays are the page's neighbours rather than its
                    // content: laid out on the frame, so the accounts and find
                    // still measure from the page's corner, but never clipped
                    // by its rounding.
                    HStack(spacing: metrics.pageInset) {
                    Group {
                        if browser.active != nil {
                            PanelStage(browser: browser, panels: browser.panels, corner: pageCorner)
                        } else {
                            PageGround(corner: pageCorner)
                        }
                    }
                    // Settings stand in for the page, in its frame. The page
                    // stays mounted underneath, unpainted and out of reach,
                    // and comes back unchanged when they close.
                    .opacity(browser.tuning ? 0 : 1)
                    .allowsHitTesting(!browser.tuning)
                    .accessibilityHidden(browser.tuning)
                    .overlay { if browser.tuning { settingsSurface } }
                    // Developer mode's line, behind the frame so it never
                    // falls on the page (Workbench.swift).
                    .background {
                        if browser.showsWorkbench { DevelopingRing(corner: pageCorner).transition(.opacity) }
                    }
                    .overlay(alignment: .top) {
                        if let tab = readingTab {
                            ReadingLine(tab: tab)
                                .padding(.horizontal, pageCorner)
                                .offset(y: -ReadingLine.height(metrics))
                                .opacity(browser.tuning ? 0 : 1)
                        }
                    }
                    .anchorPreference(key: PageFrame.self, value: .bounds) { $0 }
                    .anchorPreference(key: DownloadFlightFrames.self, value: .bounds) {
                        DownloadFlightFrames(page: $0)
                    }
                    // Developer mode stands beside the page's frame, on the
                    // envelope (Developer.swift).
                    DeveloperColumn(browser: browser)
                    }
                    .padding(pageInsets)
                }
            }

            // Extensions stay in the top bar even when the optional address
            // bar is disabled. This is the same top-right action slot used by
            // the strip layout.
            if browser.prefs.sidebar, !browser.showsBar, !browser.focusing, browser.active?.immersed != true {
                HStack {
                    Spacer(minLength: 0)
                    DownloadDoor(downloads: browser.downloads) { browser.hoarding = true }
                    ExtensionSlot(space: browser.spaceID)
                    DeveloperDoor(browser: browser)
                }
                .frame(height: metrics.strip)
                .padding(.horizontal, metrics.length(10))
            }

            if !browser.prefs.sidebar, !browser.folded, browser.active?.immersed != true {
                TabBar(browser: browser)
                    .frame(height: metrics.strip)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
        .shortcutAnimation(Motion.glide, value: browser.prefs.sidebar, enabled: browser.prefs.fasterShortcuts, reduced: reduceMotion)
        .animation(Motion.settle, value: browser.prefs.interfaceSize)
        .animation(.easeOut(duration: 0.12), value: browser.active?.immersed)
        .animation(reduceMotion ? Motion.quick : Motion.dock, value: browser.showsWorkbench)
    }

    /// Settings in the page's own frame, letting the envelope through in Clear:
    /// the column, the rail and the bars stay where they are, as they do for
    /// any page, so Settings read as a place in the browser rather than a
    /// second window laid over it.
    private var settingsSurface: some View {
        GeometryReader { area in
            ZStack {
                // A page may hide the pointer with cursor: none. The same
                // AppKit cursor ground used by floating sheets restores the
                // arrow over Settings without changing the page's cursor.
                CursorGround()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                SettingsPanel(browser: browser, prefs: browser.prefs, availableWidth: area.size.width)
            }
            .frame(width: area.size.width, height: area.size.height)
            .clipShape(RoundedRectangle(cornerRadius: pageCorner, style: .continuous))
        }
        .background(SettingsGround(corner: pageCorner))
        .transition(.opacity)
    }

    /// Everything that rises from the bottom edge to say one thing.
    private var bars: some View {
        VStack(spacing: 8) {
            announcement
            if let ask = browser.asking {
                captureAsking(ask)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // The offer to keep a password (see Logins.swift).
            KeepAsking(logins: browser.logins)
            StoreOffer(browser: browser)
            if browser.veiling {
                hint("Click anything to hide it   ⌘Z undo   esc done")
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Above Developer mode's dock while it is up.
        .padding(.bottom, 30 + (browser.showsWorkbench ? Workbench.height(metrics) : 0))
        .animation(Motion.settle, value: browser.veiling)
        .animation(Motion.settle, value: browser.asking)
    }

    /// The address field: raised over a page by ⌘T, ⌘L or ⌘K, and standing on its
    /// own whenever a tab has nowhere to be yet.
    @ViewBuilder
    private var field: some View {
        if browser.fieldShowing {
            Omnibox(browser: browser, input: browser.field, over: !(browser.active?.isBlank ?? true), corner: pageCorner)
                // The stage supplies the exact page bounds, including its
                // inset and corner at every chrome size and layout.
                .transition(.opacity)
        }
    }

    /// The panels. All the same kind of thing, so they are built the same way.
    @ViewBuilder
    private var panels: some View {
        if browser.recalling {
            sheet { HistoryPanel(browser: browser) } close: { browser.recalling = false }
        }
        if browser.hoarding {
            sheet { DownloadsPanel(browser: browser, loot: browser.loot) }
                close: { browser.hoarding = false }
        }
        if let gate = browser.gate {
            sheet { GatePanel(browser: browser, gate: gate) } close: { browser.gate = nil }
        }
        if browser.bookmarking {
            sheet { BookmarksPanel(browser: browser, bookmarks: browser.bookmarks) }
                close: { browser.bookmarking = false }
        }
        if browser.welcoming {
            WelcomePanel(browser: browser, prefs: browser.prefs)
                .ignoresSafeArea()
                .transition(.opacity)
        }
        if browser.managing {
            sheet { PasswordsPanel(browser: browser, logins: browser.logins) } close: { browser.managing = false }
        }
        if browser.reviewing {
            // No dimming for this one: the whole point is to keep looking at
            // the page while the list offers to put things back on it.
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { browser.reviewing = false }
                HiddenPanel(browser: browser)
                    .padding(.top, metrics.strip + metrics.length(8))
                    .padding(.trailing, 14)
                    .transition(.scale(scale: 0.97, anchor: .topTrailing).combined(with: .opacity))
            }
            .ignoresSafeArea()
            .transition(.opacity)
        }
    }

    var body: some View {
        window_
            // The rail remains anchored to the left while the column slides
            // over the page when folded (see Side.swift and Fold.swift).
            .overlay(alignment: .leading) {
                if browser.prefs.sidebar, !browser.focusing, browser.active?.immersed != true {
                    SidebarChrome(browser: browser, prefs: browser.prefs)
                }
            }
            // The column folded away, and out again at the edge (see Fold.swift).
            .overlay(alignment: .leading) {
                Fold(browser: browser, prefs: browser.prefs)
            }
            // Bottom notices use the same final points as the surrounding
            // chrome, so their hit targets stay aligned at every size.
            .overlay {
                if !browser.tuning {
                    bars.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
            // Developer mode's dock, centred on the window (Workbench.swift).
            .overlay { Workbench(browser: browser) }
            .overlayPreferenceValue(DownloadFlightFrames.self) { anchors in
                GeometryReader { bounds in
                    DownloadFlight(
                        downloads: browser.downloads,
                        page: anchors.page.map { bounds[$0] },
                        door: anchors.door.map { bounds[$0] },
                        enabled: !browser.tuning && !browser.welcoming && browser.active?.immersed != true
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .overlayPreferenceValue(PageFrame.self) { anchor in
                if !browser.tuning && !browser.welcoming, browser.fieldShowing, let anchor {
                    GeometryReader { bounds in
                        let frame = bounds[anchor]
                        field
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
            }
            // Welcome is modal to the browser chrome: hidden address fields
            // must neither receive Return nor enter the accessibility order.
            .disabled(browser.welcoming)
            .accessibilityHidden(browser.welcoming)
            .overlay {
                // A floating panel keeps its state while Settings are on
                // top, but its scrim and controls must not cover them.
                panels
                    .opacity(browser.tuning ? 0 : 1)
                    .allowsHitTesting(!browser.tuning)
                    .accessibilityHidden(browser.tuning)
            }
            // A tab carried over the pages, above everything it can land on.
            .overlay { PanelGhost(lift: browser.panels.lift) }
            // Increase Contrast and the Colours choice change what the
            // palette's colours resolve to, not any value a view holds: the
            // window's views are made again so each resolves afresh. Pages
            // are not — the stage hands the same web view to the new stage,
            // as the floating window does.
            .id(PaletteChoice(tone: browser.prefs.tone, contrast: browser.prefs.increasesContrast))
            .onPreferenceChange(PanelEntryFrames.self) { browser.panels.entries = $0 }
            .shortcutAnimation(Motion.settle, value: browser.fieldShowing, enabled: browser.prefs.fasterShortcuts, reduced: reduceMotion)
            .modifier(EnvironmentPresentation(editor: browser.environmentEditor))
            // The Transparency setting also reaches the environment sheet.
            .environment(\.depth, browser.prefs.depth)
            .environment(\.chromeMetrics, metrics)
            .background(WindowSetup { window = $0; dress($0) })
            .onChange(of: seesThrough) { _, sees in
                if let window { Glass.dress(window, sees: sees) }
            }
            // The lights up to the address bar's line, and back (see Bar.swift).
            .onChange(of: browser.showsBar, initial: true) { _, _ in Lights.follow(browser) }
            .onChange(of: browser.prefs.interfaceSize) { _, _ in Lights.follow(browser) }
            .onChange(of: browser.fieldShowing) { _, showing in
                if showing {
                    DispatchQueue.main.async { browser.field.askFocus() }
                } else {
                    handBack()
                }
            }
            .onChange(of: browser.activeID) { _, _ in handBack() }
            .onChange(of: browser.welcoming) { _, showing in
                if showing { window?.makeFirstResponder(nil) }
                else { browser.field.askFocus() }
            }
            .animation(Motion.settle, value: browser.recalling)
            .animation(Motion.settle, value: browser.hoarding)
            .animation(Motion.settle, value: browser.gate)
            .animation(Motion.settle, value: browser.tuning)
            .animation(reduceMotion ? nil : Motion.arrival, value: browser.welcoming)
            .animation(Motion.settle, value: browser.bookmarking)
            .animation(Motion.settle, value: browser.managing)
            .animation(Motion.settle, value: browser.reviewing)
        .onAppear {
            watchKeys()
            browser.field.askFocus()
            // Addresses from other apps have somewhere to go from here on.
            Links.hand(to: browser)
            BookmarkMenu.shared.start(for: browser)
        }
    }

    /// Give the keyboard back to the page once the field is done with it.
    ///
    /// Nothing did this before, so after typing an address the window's first
    /// responder was a text field that no longer existed: typing went nowhere
    /// until you clicked the page. It also mattered more than it looked —
    /// WebAuthn refuses to run on a document that isn't focused, and so do a
    /// number of paste and shortcut handlers pages install for themselves.
    private func handBack() {
        guard !browser.welcoming, !browser.tuning, !browser.fieldShowing,
              !browser.finding, browser.editingTab == nil else { return }
        DispatchQueue.main.async {
            // A panel selection and Find can open in the same layout turn.
            // A queued handoff must not take the keyboard from the new field.
            guard !browser.welcoming, !browser.tuning, !browser.fieldShowing,
                  !browser.finding, browser.editingTab == nil,
                  let web = browser.active?.built, let window = web.window else { return }
            window.makeFirstResponder(web)
        }
    }

    // MARK: - the window

    /// A line that rises from the bottom, says one thing, and leaves.
    @ViewBuilder
    private var announcement: some View {
        if let text = browser.announcement {
            let symbol = browser.announcementSymbol
            HStack(spacing: 7) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
                // One with a symbol names a thing, an address most often:
                // one line, giving up its middle, since where it goes and
                // what it ends with say the most.
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(symbol == nil ? nil : 1)
                    .truncationMode(.middle)
                    // As wide as the line needs, up to the cap: a bare
                    // maxWidth would stretch every line to it.
                    .frame(maxWidth: symbol == nil ? nil : 480)
                    .fixedSize(horizontal: symbol != nil, vertical: false)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .glass(.chip, in: Capsule())
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(Motion.settle, value: browser.announcement)
        }
    }

    /// A page asking to see or hear you. Named by the site, in its own words,
    /// with the answer remembered so it is asked once and not every call.
    private func captureAsking(_ ask: Browser.CaptureAsk) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ask.wants == "microphone" ? "mic" : "video")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Palette.muted)
            Text("\(ask.host) wants to use your \(ask.wants)")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
            Button { browser.allowCapture() } label: {
                Text("Allow")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.inverse)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Palette.ink, in: Capsule())
            }
            .buttonStyle(.plain)
            Button { browser.denyCapture() } label: {
                Text("Don't allow")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .glass(.chip, in: Capsule())
    }

    /// A dark pill, for the one mode this browser has. It stays up for as long
    /// as the mode does, which is how you know you are still in it.
    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.inverse)
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(Palette.ink.opacity(0.92), in: Capsule())
            .shadow(color: Palette.shadow, radius: 18, y: 6)
    }

    /// The same dimmed ground and spring for every panel that floats over a
    /// page, so they read as one kind of thing.
    @ViewBuilder
    private func sheet<Panel: View>(
        @ViewBuilder _ panel: @escaping () -> Panel,
        close: @escaping () -> Void
    ) -> some View {
        GeometryReader { area in
            // Floating panels stay inside a small inset.
            ZStack {
                // The floor owns the cursor; see CursorGround.
                CursorGround()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                Palette.scrim
                    .ignoresSafeArea()
                    .onTapGesture(perform: close)
                panel()
                    .frame(maxWidth: area.size.width - 32, maxHeight: area.size.height - 32)
                    .environment(\.chromePanelBounds, CGSize(width: max(0, area.size.width - 32), height: max(0, area.size.height - 32)))
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .transition(.opacity)
    }

    /// How much of the window's left the rail and the column take from the
    /// page: the rail alone while the column is folded, nothing once the
    /// spaces are off too, or in Focus Mode (see Fold.swift).
    private var sideFootprint: CGFloat {
        guard browser.prefs.sidebar, !browser.focusing, browser.active?.immersed != true else { return 0 }
        return metrics.sidebarFootprint(
            browser.prefs.sideWidth,
            rail: browser.prefs.usesSpaces,
            folded: browser.folded
        )
    }

    /// The column folded without the bar over the page: the line over the
    /// page still holds the column's door, and back, forward and reload.
    private var foldedLine: Bool {
        browser.prefs.sidebar && browser.folded && !browser.focusing && !browser.showsBar && browser.active?.immersed != true
    }

    private var metrics: ChromeMetrics { ChromeMetrics(size: browser.prefs.interfaceSize) }

    /// Whether the window lets the desktop through: not at Solid, not with
    /// the Mac's Reduce Transparency, and not while a page is immersed in
    /// black.
    private var seesThrough: Bool {
        browser.prefs.depth.drawn(reducing: reducing).sees && (browser.tuning || browser.active?.immersed != true)
    }

    @SwiftUI.Environment(\.accessibilityReduceTransparency) private var reducing

    /// The tab whose reading fraction the sidebar's line shows, if it shows one.
    private var readingTab: Tab? {
        guard browser.prefs.sidebar, browser.prefs.showsReading,
              let tab = browser.active, tab.address != nil, !tab.immersed
        else { return nil }
        return tab
    }

    /// The page's corner, grown with the chrome; square while it is immersed.
    private var pageCorner: CGFloat {
        browser.active?.immersed == true ? 0 : metrics.pageRadius
    }

    /// The envelope showing round the page. Nothing beside the column, which
    /// keeps its own air, nor above the page when a bar or the strip already
    /// stands there; nothing at all while the page has the screen.
    private var pageInsets: EdgeInsets {
        guard browser.active?.immersed != true else { return EdgeInsets() }
        let inset = metrics.pageInset
        let topBand = browser.showsBar || foldedLine || band > 0
        // Against the rail or the column, their own inset is the page's air;
        // against the window's edge, the page is set in from it.
        return EdgeInsets(top: topBand ? 0 : inset, leading: sideFootprint > 0 ? 0 : inset, bottom: inset, trailing: inset)
    }

    /// Without an address bar, the trailing action row still needs its own
    /// envelope above the page. Otherwise its buttons sit over web content
    /// and a correctly page-clipped search backdrop also dims those buttons.
    private var band: CGFloat {
        guard browser.active?.immersed != true, !browser.focusing else { return 0 }
        if browser.prefs.sidebar { return browser.showsBar || foldedLine ? 0 : metrics.strip }
        return browser.folded ? 0 : metrics.strip
    }


    private func dress(_ window: NSWindow) {
        Links.window = window
        // Light or dark is the app's to say (Settings › Appearance); the
        // window only has to let the envelope be seen.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Clear where the envelope lets the desktop through (Glass.swift).
        Glass.dress(window, sees: seesThrough)
        // The strip does the dragging, so the page underneath can't be grabbed
        // by accident while selecting text.
        window.isMovableByWindowBackground = false
        // Nor by its title bar, which the strip is all the way down: AppKit
        // would move the window on any drag there, a tab picked up to take
        // it elsewhere in the row included. DragStrip moves it instead.
        window.isMovable = false
        // Where you left it, at the size you left it. A test run keeps its
        // own: the name lives in the app's standard defaults, which every
        // copy shares, and a probe resized for a test once changed the size
        // the real window came back at.
        window.setFrameAutosaveName(Store.world.map { "escale (\($0))" } ?? "escale")

        // The traffic lights set in from the corner and centred in the strip's
        // height, in both modes, without a toolbar's rounder corners — see
        // Lights.swift. The column's first row is the strip's height too, so
        // its three doors sit on the lights' line.
        Lights.keep(window) {}

        // The traffic lights are drawn — measured, they paint themselves — but
        // the window shows white where they are. The content view fills the
        // whole window, title bar included, and its layer was compositing over
        // the title bar's own. AppKit's subview order said otherwise; Core
        // Animation is the one actually deciding, so it is told directly.
        DispatchQueue.main.async {
            guard let close = window.standardWindowButton(.closeButton),
                  let container = close.superview?.superview,
                  let content = window.contentView,
                  let frame = content.superview
            else { return }
            frame.addSubview(container, positioned: .above, relativeTo: content)
            container.wantsLayer = true
            container.layer?.zPosition = 10
        }
    }

    // MARK: - keys

    /// A web view takes first responder and keeps most of the keyboard, so the
    /// shortcuts are caught before the event ever reaches it. The menu carries
    /// the same commands for anyone looking for them, and never sees these
    /// keystrokes because this runs first.
    private func watchKeys() {
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            // A scripted test world types only what its script presses.
            if BenchKeys.foreign(event) { return nil }
            guard event.type == .keyDown else {
                // Releasing the configured modifier ends the tab-search walk.
                KeyRouting.released(event, browser: browser)
                return event
            }
            if KeyCapture.current?.take(event) == true { return nil }
            return Motion.command { take(event) } ? nil : event
        }
    }

    /// The keys of the top row, by where they sit rather than what they type.
    static let digits: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 0,
    ]

    private func take(_ event: NSEvent) -> Bool {
        // The native sheet owns editing keys, including Escape and Return.
        if browser.environmentEditor.request != nil || Links.window?.attachedSheet != nil || NSApp.modalWindow != nil { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // A Space icon held in the rail lets go first, whatever else is open.
        if event.keyCode == 53, SpaceReorder.current?.cancel() == true { return true }

        // An area being chosen keeps Escape for itself.
        if flags.isEmpty, event.keyCode == 53, let area = browser.active?.area, area.active {
            area.stop()
            return true
        }

        // Escape puts the page back. On a blank tab there is no page to put
        // back, so it belongs to whatever else wants it.
        if event.keyCode == 53 {
            if browser.panels.source != nil { browser.panels.cancel(); return true }
            if InfoTip.dismiss() { return true }
            if browser.editingTab != nil {
                browser.cancelTabEdit()
                return true
            }
            if browser.makingSpace {
                withAnimation(Motion.glide) { browser.makingSpace = false }
                return true
            }
            if browser.tuning {
                browser.tuning = false
                return true
            }
            if browser.bookmarking {
                browser.bookmarking = false
                return true
            }
            if browser.managing {
                browser.managing = false
                return true
            }
            if browser.gate != nil {
                browser.gate = nil
                return true
            }
            if browser.recalling {
                browser.recalling = false
                return true
            }
            if browser.hoarding {
                browser.hoarding = false
                return true
            }
            if browser.logins.suggesting != nil {
                browser.logins.dropChoice()
                return true
            }
            if browser.veiling {
                browser.toggleHiding()
                return true
            }
            if browser.reviewing {
                browser.reviewing = false
                return true
            }
            if let pick = browser.active?.visual, pick.active || pick.selection != nil || pick.error != nil { pick.stop(); return true }
            if let capture = browser.active?.capture, capture.shown { capture.close(); return true }
            if let storage = browser.active?.siteStorage, storage.shown { storage.close(); return true }
            if let reader = browser.active?.jsonReader, reader.shown { reader.raw(); return true }
            if browser.finding {
                browser.closeFind()
                return true
            }
            if browser.field.github != nil {
                browser.dismiss()
                return true
            }
            // One step at a time: environment, result, then the field. A ring
            // the walk put on the current environment is no step of its own.
            if browser.field.environmentFocused, browser.field.environmentChosen {
                browser.field.leaveEnvironments(cancel: true)
                return true
            }
            if browser.field.picked != nil {
                browser.field.picked = nil
                return true
            }
            guard browser.editing, browser.active?.isBlank == false else { return false }
            browser.dismiss()
            return true
        }

        if KeyRouting.take(event, browser: browser) { return true }

        // Tab is the page's: it moves between a form's fields and a page's
        // links, as in every browser. It used to walk the row of tabs, which
        // took it from anyone filling in a form. ⌃Tab walks the row and comes
        // round to the first again, ⌃⇧Tab the other way — the keys every
        // other browser uses for that.
        //
        // In Bearings, Tab switches between its search and GitHub, whatever
        // row is selected (Bearing.swift); bookmark environments take the
        // arrows. ⌘L has no modes: there the list under the field is what
        // there is to move through, and Return takes whatever the walk landed on.
        if event.keyCode == 48, flags.intersection([.command, .control, .option]).isEmpty {
            if browser.editingTab != nil { return true }
            guard browser.fieldShowing else { return false }
            if browser.switchBearing() { return true }
            guard !browser.field.offers.isEmpty else { return false }
            browser.field.walk(flags.contains(.shift) ? -1 : 1)
            return true
        }

        return false
    }
}
