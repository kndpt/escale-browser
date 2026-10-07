import AppKit
import SwiftUI

/// The only chrome there is. Titles, one of them in a grey pill, and the pill
/// slides from the tab you left to the tab you picked rather than blinking out
/// of one and into the other.
struct TabBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var panels: Panels
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Namespace private var pill
    /// The neighbouring spaces' own grey, apart from this one's.
    @Namespace private var above
    @Namespace private var below

    /// Which tab is under the hand, where it started, and how far it has come.
    @State private var dragging: Tab.ID?
    @State private var from = 0
    @State private var travel: CGFloat = 0
    @State private var landing = false
    /// The plus only comes out when the pointer is in the row.
    @State private var nearby = false
    @State private var plussed = false
    /// How wide the doors at the far end are, extension buttons included.
    @State private var doors: CGFloat = 0
    @StateObject private var panelDrag = SpaceDrag()
    /// In full screen the traffic lights leave the strip for the title bar
    /// macOS slides down over it, so their corner goes to the row.
    @State private var window: NSWindow?
    @State private var fullScreen = false

    init(browser: Browser) { self.browser = browser; self.panels = browser.panels }

    var body: some View {
        // A GeometryReader is only here to measure the width. Its content is
        // put in a stack of its own and told to fill it: left to itself a
        // reader pins whatever it holds to the top corner, which is the row
        // riding at the very top of the strip while the traffic lights centre
        // themselves halfway down it.
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // The empty half of the strip is what you grab to move the
                // window; the tabs keep the run they sit on.
                DragStrip(reserved: lead + helm + dot + (making ? min(metrics.length(540), room(in: geo.size.width)) : run(in: geo.size.width)) + metrics.tabGap + metrics.plusWidth + searchWidth, trailing: max(metrics.length(26), doors) + metrics.length(24))
                // And the corner the lights sit in, which is title bar too —
                // the one stretch left to take hold of when tabs fill the row.
                DragStrip()
                    .frame(width: lead)

                HStack(spacing: metrics.tabGap) {
                    // Back, forward, reload, first after the lights — where
                    // the sidebar puts them too (Side.swift, Bar.swift).
                    Helm(browser: browser)
                        .padding(.trailing, metrics.length(8))

                    // The space on screen, next, when there are spaces.
                    if browser.prefs.usesSpaces { SpaceDot(browser: browser) }

                    // The tabs, in a run of their own. While they fit, it is
                    // exactly as wide as they are and nothing about the row
                    // changes. Past what the window holds at their narrowest
                    // it takes the room there is and scrolls inside its own
                    // edges — never under the lights, never over the doors —
                    // keeping the tab you are on in view.
                    // The spaces, one above the other: up or down over the bar
                    // and the next one's tabs come in as these go, with nothing
                    // between them (see SpaceSwipe). Past the last, a new one.
                    ZStack(alignment: .leading) {
                        if making {
                            NewSpaceCard(browser: browser, inline: true)
                                .fixedSize()
                                .offset(y: browser.spaceSwipe)
                        } else {
                            ScrollViewReader { reader in
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: metrics.tabGap) {
                                        ForEach(Array(browser.tabEntries.enumerated()), id: \.element.id) { index, tab in
                                            // A pinned square moves among pinned squares, a title
                                            // among titles: each has its own stride.
                                            let step = (tab.pin != nil && panels.group(tab.id) == nil ? metrics.pinWidth : width(in: geo.size.width)) + metrics.tabGap
                                            let held = dragging == tab.id
                                            let carried = panels.carrying == tab.id
                                            Group {
                                            if let group = panels.group(tab.id) {
                                                PanelEntry(browser: browser, panels: panels, group: group)
                                                    .frame(width: width(in: geo.size.width))
                                            } else {
                                            TabPill(
                                                browser: browser,
                                                prefs: browser.prefs,
                                                tab: tab,
                                                live: tab.id == browser.activeID && !browser.tuning,
                                                width: width(in: geo.size.width),
                                                room: geo.size.width - lead - metrics.length(12),
                                                pill: pill,
                                                close: { browser.close(tab) }
                                            )
                                            }
                                            }
                                            // The row reflows around it while the pill itself keeps
                                            // up with the hand: what it has travelled, less the
                                            // ground its new place has already given it.
                                            .offset(x: held && !carried ? travel - CGFloat(index - from) * step : 0)
                                            // Under the hand exactly. Its place in the row springs when it
                                            // passes another tab, and the offset springs back the same way —
                                            // until the next move of the hand cuts the offset's spring short
                                            // and leaves the place's running: the tab jumped a whole slot and
                                            // drifted back each time it passed one. Only the others glide.
                                            .transaction { if held && !carried { $0.animation = nil } }
                                            // Over the pages it travels as a carried face; the
                                            // pill waits in its place, stepped back.
                                            .opacity(carried ? 0.4 : 1)
                                            .animation(reduceMotion ? nil : Motion.settle, value: carried)
                                            .zIndex(held ? 1 : 0)
                                            .shadow(color: held && !carried ? Palette.shadow : .clear, radius: 12, y: 4)
                                            .gesture(reorder(tab: tab, index: index, step: step))
                                            .modifier(PanelEntryFrame(id: tab.id))
                                            .id(tab.id)
                                        }
                                    }
                                    .frame(height: metrics.strip)
                                }
                                .scrollDisabled(!overflowing(in: geo.size.width))
                                .frame(width: run(in: geo.size.width))
                                .onAppear { reveal(reader, in: geo.size.width) }
                                .onChange(of: overflowing(in: geo.size.width)) { _, _ in reveal(reader, in: geo.size.width) }
                                .onChange(of: browser.activeID) { _, _ in reveal(reader, in: geo.size.width, gliding: true) }
                            }
                                .offset(y: browser.spaceSwipe)
                        }
                        if browser.spaceSwipe > 0, spaceAt > 0 {
                            page(spaceAt - 1, in: geo.size.width, pill: above)
                                .offset(y: browser.spaceSwipe - metrics.strip)
                        }
                        if browser.spaceSwipe < 0, spaceAt < browser.spaces.count {
                            page(spaceAt + 1, in: geo.size.width, pill: below)
                                .offset(y: browser.spaceSwipe + metrics.strip)
                        }
                    }
                    .frame(width: making ? min(metrics.length(540), room(in: geo.size.width)) : run(in: geo.size.width), height: metrics.strip, alignment: .leading)
                    // Only up and down: a neighbour's row may run wider than this one.
                    .mask(Rectangle().frame(width: metrics.length(4000), height: metrics.strip))

                    // The way to a new page, right after the tabs rather than
                    // at the end of their run, so it is there however far the
                    // run has scrolled. Out of sight until the pointer is up here.
                    Button { browser.newTab() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: metrics.length(10), weight: .regular))
                            .foregroundStyle(Palette.muted)
                            .frame(width: metrics.length(15), height: metrics.length(15))
                            .padding(.horizontal, metrics.length(7))
                            .padding(.vertical, metrics.length(6))
                            .contentShape(RoundedRectangle(cornerRadius: metrics.length(9), style: .continuous))
                            .background(
                                RoundedRectangle(cornerRadius: metrics.length(9), style: .continuous)
                                    .fill(plussed ? Palette.hover : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { plussed = $0 }
                    .opacity(nearby ? 1 : 0)
                    .allowsHitTesting(nearby)
                    .animation(Motion.settle, value: nearby)

                    TabSearchDoor(prefs: browser.prefs) { browser.summon() }

                    Spacer(minLength: 0)

                    // The page's doors and the bookmarks, at the far end of
                    // the row. The dropdown hangs from the bookmarks.
                    HStack(spacing: metrics.tabGap) {
                        // Without the rail, a waiting update leads the row.
                        GateDoor(browser: browser)
                        DownloadDoor(downloads: browser.downloads) { browser.hoarding = true }
                        ExtensionSlot(space: browser.spaceID)
                        VisualDoor(browser: browser)
                        CaptureDoor(browser: browser)
                        DeveloperDoor(browser: browser)
                        Door(icon: "bookmark", help: "Bookmarks") { browser.bookmarksOpen.toggle() }
                            .popover(isPresented: $browser.bookmarksOpen, arrowEdge: .bottom) {
                                BookmarksDropdown(browser: browser, bookmarks: browser.bookmarks)
                            }
                        // Last, at the far right, as over the page (Bar.swift).
                        if browser.prefs.copyDoor, let tab = browser.active {
                            CopyDoor(browser: browser, tab: tab)
                        }
                    }
                    .background {
                        GeometryReader { box in
                            Color.clear
                                .onAppear { doors = box.size.width }
                                .onChange(of: box.size.width) { _, width in doors = width }
                        }
                    }
                }
                // The traffic lights are the system's. In a window the row
                // starts after them and stays there — nothing here moves to
                // get out of their way, because nothing here was ever in it.
                .padding(.leading, lead)
                .padding(.trailing, metrics.length(12))
                .coordinateSpace(name: "strip")
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: metrics.strip)
        .onHover { nearby = $0 }
        .onAppear { SpaceSwipe.shared.start(for: browser) }
        .onDisappear { panelDrag.cancel() }
        .background(WindowSetup { window in
            self.window = window
            fullScreen = window.styleMask.contains(.fullScreen)
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { note in
            if note.object as? NSWindow === window { fullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { note in
            if note.object as? NSWindow === window { fullScreen = false }
        }
        // A link dragged onto the row opens there.
        .onDrop(of: [.url, .text], isTargeted: $landing) { providers in
            browser.take(providers)
        }
        .background(landing ? Palette.hover : .clear)
        .animation(Motion.quick, value: landing)
        .shortcutAnimation(Motion.glide, value: browser.activeID, enabled: browser.prefs.fasterShortcuts, reduced: reduceMotion)
        // The row makes room for the field on the same spring as everything
        // else. Without this the widths changed between one frame and the next
        // and the tabs appeared to jump aside.
        .shortcutAnimation(Motion.glide, value: browser.editingTab, enabled: browser.prefs.fasterShortcuts, reduced: reduceMotion)
        .shortcutAnimation(Motion.settle, value: browser.tabs.map(\.id), enabled: browser.prefs.fasterShortcuts, reduced: reduceMotion)
    }

    // MARK: - the spaces, one above the other

    private var making: Bool { browser.prefs.usesSpaces && browser.makingSpace }

    /// Where the space on screen sits among them: one past the last while
    /// the row for a new one is up.
    private var spaceAt: Int {
        browser.makingSpace ? browser.spaces.count : (browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0)
    }

    /// Another space's row, drawn with the same pills as this one's so the
    /// two read as one bar while they pass — nothing to press until it is
    /// the one on screen. Past the last, the row for a new space.
    @ViewBuilder
    private func page(_ index: Int, in strip: CGFloat, pill: Namespace.ID) -> some View {
        if index == browser.spaces.count {
            NewSpaceCard(browser: browser, inline: true)
                .fixedSize()
                .allowsHitTesting(false)
        } else {
            let space = browser.spaces[index]
            let row = space.id == browser.spaceID
                ? Parked(tabs: browser.tabs, active: browser.activeID)
                : browser.parked[space.id] ?? Parked(tabs: [], active: nil)
            let each = width(in: strip, pinned: row.tabs.filter { $0.pin != nil }.count, count: row.tabs.count)
            HStack(spacing: metrics.tabGap) {
                ForEach(panels.representatives(row.tabs)) { tab in
                    if let group = panels.group(tab.id) {
                        PanelEntry(browser: browser, panels: panels, group: group, row: row.tabs).frame(width: each)
                    } else {
                    TabPill(
                        browser: browser,
                        prefs: browser.prefs,
                        tab: tab,
                        live: tab.id == row.active,
                        width: each,
                        room: strip - lead - metrics.length(12),
                        pill: pill,
                        close: {}
                    )
                    }
                }
            }
            .frame(height: metrics.strip)
            .allowsHitTesting(false)
        }
    }

    /// Pick a tab up and the others get out of its way as it passes them.
    private func reorder(tab: Tab, index: Int, step: CGFloat) -> some Gesture {
        // In the row's space, not the pill's — see the sidebar's grid for why.
        DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .onChanged { value in
                if dragging != tab.id {
                    dragging = tab.id
                    from = index
                }
                panelDrag.begin(tab.id, origin: tab.space, title: tab.label, symbol: "square.on.square", at: value.location,
                                move: { point in _ = browser.aimPanel(tab, at: point) },
                                release: { point in finishReorder(tab, at: point) },
                                abort: { panels.finish(); dragging = nil; travel = 0 })
                travel = value.translation.width
                // Over the strip the others make way; below it the tab is
                // carried toward the pages instead.
                let entries = browser.tabEntries
                if browser.aimPanel(tab, at: value.location) || value.location.y >= metrics.strip {
                    // Carried off to the pages, the pill goes back to its own place.
                    if index != from { withAnimation(Motion.settle) { browser.move(tab, to: browser.place(of: from, among: entries)) } }
                    return
                }
                let target = min(max(0, from + Int((travel / step).rounded())), entries.count - 1)
                if target != index {
                    withAnimation(Motion.settle) { browser.move(tab, to: browser.place(of: target, among: entries)) }
                }
            }
            .onEnded { value in
                panelDrag.end(at: value.location)
            }
    }

    private func finishReorder(_ tab: Tab, at point: CGPoint) {
        if !panels.cancelled { _ = browser.dropPanel(tab, at: point) }
        panels.finish()
        withAnimation(Motion.settle) {
            dragging = nil
            travel = 0
        }
    }

    /// Brings the tab you are on into view once the run scrolls: at once
    /// when the window first shows it, on the strip's spring when you pick
    /// another. A turn of the run loop later, so the run has been laid out.
    private func reveal(_ reader: ScrollViewProxy, in strip: CGFloat, gliding: Bool = false) {
        guard overflowing(in: strip), let id = browser.entryID(for: browser.activeID) else { return }
        let animation = Motion.shortcutAnimation(Motion.glide, keyboard: browser.selectionFromKeyboard,
            enabled: browser.prefs.fasterShortcuts, reduced: reduceMotion)
        DispatchQueue.main.async {
            guard browser.entryID(for: browser.activeID) == id else { return }
            if gliding {
                withAnimation(animation) { reader.scrollTo(id) }
            } else {
                reader.scrollTo(id)
            }
        }
    }

    /// How wide the run of tabs is: as wide as the tabs while they fit, as
    /// wide as the room there is once they don't.
    private func run(in strip: CGFloat) -> CGFloat {
        min(content(in: strip), room(in: strip))
    }

    private func overflowing(in strip: CGFloat) -> Bool {
        content(in: strip) > room(in: strip) + 0.5
    }

    /// Everything in the run at the width the tabs get — and the address
    /// field's width for a tab being edited, which grows to take it.
    private func content(in strip: CGFloat) -> CGFloat {
        let each = width(in: strip)
        let pinned = CGFloat(browser.tabEntries.filter { $0.pin != nil && panels.group($0.id) == nil }.count)
        let loose = CGFloat(browser.tabEntries.count) - pinned
        var total = pinned * metrics.pinWidth + loose * each
            + CGFloat(max(0, browser.tabEntries.count - 1)) * metrics.tabGap
        if let id = browser.editingTab, let tab = browser.tabs.first(where: { $0.id == id }) {
            total += min(metrics.length(340), strip - lead - metrics.length(12)) - (tab.pin != nil ? metrics.pinWidth : each)
        }
        return total
    }

    /// The strip, less the lights, the helm, the plus, the doors at the far
    /// end and the air around them. The doors are measured; until they have
    /// been, the bookmarks stand in for them.
    private func room(in strip: CGFloat) -> CGFloat {
        let far = doors > 0 ? doors : metrics.length(26)
        return max(0, strip - lead - helm - dot - metrics.length(12) - metrics.plusWidth - searchWidth - far - 3 * metrics.tabGap)
    }

    /// Where the row starts: past the traffic lights in a window, at the same
    /// air as its far end in full screen.
    private var lead: CGFloat { fullScreen ? metrics.length(12) : metrics.lights }

    private var searchWidth: CGFloat { metrics.length(Metrics.tabSearchSide) + metrics.tabGap }

    /// What back, forward and reload take before the tabs, air included.
    private var helm: CGFloat { metrics.helm + metrics.tabGap }

    /// What the space's dot takes before the tabs, when there are spaces.
    private var dot: CGFloat { browser.prefs.usesSpaces ? metrics.length(SpaceDot.width) + metrics.tabGap : 0 }

    /// Every loose tab is the same width, so the cross is always in the same
    /// place. Past a dozen or so they start giving ground; too narrow for a
    /// title they show their mark alone (ChromeMetrics.tabTitled), down to the
    /// mark and its air. Past that, the run scrolls. The pinned squares take
    /// their room off the top.
    private func width(in strip: CGFloat) -> CGFloat {
        width(in: strip, pinned: browser.tabEntries.filter { $0.pin != nil && panels.group($0.id) == nil }.count, count: browser.tabEntries.count)
    }

    private func width(in strip: CGFloat, pinned pins: Int, count: Int) -> CGFloat {
        let pinned = CGFloat(pins)
        let loose = CGFloat(count) - pinned
        guard loose > 0 else { return metrics.tabWidth }
        let spent = pinned * metrics.pinWidth
            + CGFloat(max(0, count - 1)) * metrics.tabGap
        return max(metrics.tabMinWidth, min(metrics.tabWidth, (room(in: strip) - spent) / loose))
    }
}

/// Back, forward, reload. They watch the live tab, not the window: whether
/// there is anywhere to go back to is the tab's to say, and it changes with
/// every page. Beside the traffic lights, here as in the sidebar.
struct Helm: View {
    @ObservedObject var browser: Browser
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        if let tab = browser.active, !browser.tuning {
            Wheel(browser: browser, tab: tab)
        } else {
            // Nowhere to go and nothing to reload: the doors stay in place,
            // greyed, so the row doesn't shift when a tab arrives or
            // Settings leave the page's frame.
            HStack(spacing: metrics.tabGap) {
                Door(icon: "chevron.left") {}
                Door(icon: "chevron.right") {}
                Door(icon: "arrow.clockwise") {}
            }
            .opacity(0.3)
            .allowsHitTesting(false)
        }
    }

    private struct Wheel: View {
        let browser: Browser
        @ObservedObject var tab: Tab
        @SwiftUI.Environment(\.chromeMetrics) private var metrics

        var body: some View {
            let back = !tab.isBlank && tab.canGoBack
            let forward = !tab.isBlank && tab.canGoForward
            HStack(spacing: metrics.tabGap) {
                HistoryDoor(tab: tab, prefs: browser.prefs, back: true) { browser.open($0, foreground: false, from: tab) }
                HistoryDoor(tab: tab, prefs: browser.prefs, back: false) { browser.open($0, foreground: false, from: tab) }
                // Reload, or stop while it is still coming.
                Door(
                    icon: tab.loading ? "xmark" : "arrow.clockwise",
                    help: tab.loading ? browser.prefs.keyHelp(.stopLoading) : browser.prefs.keyHelp(.reload) + " — ⌘-click opens in a tab"
                ) {
                    if tab.loading {
                        tab.stop()
                    } else if NSApp.currentEvent?.modifierFlags.contains(.command) == true, let url = tab.address {
                        browser.open(url, foreground: false, from: tab)
                    } else {
                        browser.reload()
                    }
                }
                .disabled(tab.isBlank)
                .opacity(tab.isBlank ? 0.3 : 1)
            }
            .animation(Motion.quick, value: back)
            .animation(Motion.quick, value: forward)
            .animation(Motion.quick, value: tab.loading)
        }
    }
}

private struct TabPill: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    let width: CGFloat
    /// How much of the strip there is, for the field that grows over it.
    let room: CGFloat
    let pill: Namespace.ID
    let close: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    @State private var hovering = false
    @State private var shake: CGFloat = 0

    private var editing: Bool { browser.editingTab == tab.id }
    private var pinned: Bool { tab.pin != nil && !editing }
    /// Too narrow for a title: the site's mark alone, the title in the
    /// tooltip, and ⌘W or the menu to close it — a cross on something this
    /// small would be what a click to pick the tab lands on.
    private var compact: Bool { !editing && !pinned && width < metrics.tabTitled }
    /// The right-hand end holds the cross, the ring or the sleep mark.
    private var marked: Bool { !editing && (hovering || tab.loading || tab.sleeping) }

    /// A pinned tab is a square, an edited one is a field, everything else is
    /// its share of what is left.
    private var span: CGFloat {
        if editing { return min(metrics.length(340), room) }
        return pinned ? metrics.pinWidth : width
    }

    var body: some View {
        Group {
            if pinned {
                Group {
                    if browser.editingPin == tab.id {
                        PinField(browser: browser, tab: tab)
                    } else if prefs.glyph == .icons, let icon = tab.icon {
                        Mark(icon: icon, letter: tab.pin ?? "", size: metrics.length(Metrics.navigationIcon), dim: tab.asleep)
                    } else {
                        Text(tab.pin ?? "")
                            .font(.system(size: metrics.length(12), weight: .regular))
                            // A pin holding no page is still there and still
                            // yours; it just isn't costing anything.
                            .foregroundStyle(colour.opacity(tab.asleep ? 0.45 : 1))
                    }
                }
                .frame(width: metrics.length(Metrics.navigationIcon), height: metrics.length(Metrics.navigationIcon))
                .overlay(alignment: .bottomTrailing) {
                    SleepMark(tab: tab)
                        .offset(x: metrics.length(Metrics.sleepBadgeOffset), y: metrics.length(Metrics.sleepBadgeOffset))
                }
                .padding(.horizontal, metrics.length(7))
                .padding(.vertical, metrics.length(6))
                .frame(width: span)
            } else {
                loose
            }
        }
        .background { ground }
        .modifier(Shake(travel: shake))
        .contentShape(RoundedRectangle(cornerRadius: metrics.length(9), style: .continuous))
        // Never both at once.
        //
        // A view carrying a single tap *and* a double tap has to wait out the
        // system's double-click delay before it can conclude that a click was
        // single — and that delay is a preference, adjustable up to a second.
        // Which is exactly how long a tab took to come forward.
        //
        // So each tab carries one gesture. The pinned square you are already
        // on has nothing to do on a single click, so it takes the double one
        // and edits its letter; everything else answers the first click at
        // once.
        .modifier(OneClick(double: live && pinned) {
            if live && pinned {
                browser.editLetter(tab)
            } else if live && !pinned {
                browser.beginTabEdit(tab)
            } else {
                browser.select(tab)
            }
        })
        .overlay { MiddleClick(act: close) }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(browser: browser, tab: tab) }
        .modifier(SleepHint(tab: tab, ordinary: pinned || compact ? tab.label : ""))
        .animation(Motion.quick, value: hovering)
        .animation(Motion.glide, value: editing)
        .animation(Motion.glide, value: tab.pin)
        .onChange(of: browser.refusals) { _, _ in
            guard editing else { return }
            shake = 0
            withAnimation(.easeOut(duration: 0.5)) { shake = 1 }
        }
        // Arriving and leaving from the strip rather than from nowhere.
        .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
    }

    @ViewBuilder
    private var loose: some View {
        if compact {
            ZStack {
                if tab.loading {
                    Ring()
                } else {
                    Mark(icon: prefs.glyph == .icons ? tab.icon : nil, letter: tab.monogram, size: metrics.length(Metrics.navigationIcon), dim: tab.asleep)
                }
            }
            .frame(width: metrics.length(Metrics.navigationIcon), height: metrics.length(Metrics.navigationIcon))
            .overlay(alignment: .bottomTrailing) {
                SleepMark(tab: tab)
                    .offset(x: metrics.length(Metrics.sleepBadgeOffset), y: metrics.length(Metrics.sleepBadgeOffset))
            }
            .padding(.vertical, metrics.length(6))
            .frame(width: span)
        } else {
            titled
        }
    }

    private var titled: some View {
        HStack(spacing: metrics.length(6)) {
            if editing {
                TabAddressField(browser: browser)
                .frame(height: metrics.length(16))
            } else {
                if prefs.glyph == .icons, !tab.isBlank {
                    Mark(icon: tab.icon, letter: tab.monogram, size: metrics.length(Metrics.navigationIcon))
                }
                // Which tab the sound comes from, at the start of the row where
                // the eye begins to read it. ⌘⇧M stops it.
                if tab.noisy {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: metrics.length(8)))
                        .foregroundStyle(Palette.muted)
                        .transition(.opacity)
                }
                if tab.bench {
                    // A script's tab, not yours.
                    Image(systemName: "flask")
                        .font(.system(size: metrics.length(Metrics.navigationSymbol)))
                        .foregroundStyle(colour.opacity(0.7))
                }
                if tab.shy {
                    // Quiet, and only on the tabs that keep nothing.
                    Image(systemName: "eye.slash")
                        .font(.system(size: metrics.length(Metrics.navigationSymbol)))
                        .foregroundStyle(colour.opacity(0.7))
                }
                Text(tab.label)
                    .font(.system(size: metrics.length(Metrics.tabTitle)))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(colour)
            }

            Spacer(minLength: metrics.length(2))

            // Pinned to the right-hand end of the pill, not trailing the title,
            // and there only while it holds something: the title runs to the
            // end of an awake tab, to the mark of a sleeping one, and gives
            // way to the cross when the pointer comes.
            if marked {
                ZStack {
                    SleepMark(tab: tab)
                        .offset(x: hovering ? -metrics.length(Metrics.sleepStatusTravel) : 0)
                    if hovering {
                        Image(systemName: "xmark")
                            .font(.system(size: metrics.length(8), weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .frame(width: metrics.length(15), height: metrics.length(15))
                            .background(Palette.ink.opacity(0.07), in: Circle())
                            .transition(.opacity)
                    } else if tab.loading {
                        Ring().transition(.opacity)
                    }
                }
                .frame(width: metrics.length(15), height: metrics.length(15))
                // The cross is 15 points across because that is how big it should
                // look. What you have to hit is the whole right-hand end of the
                // tab: an overlay is not laid out, so it can reach past its own
                // frame without moving anything that is.
                .overlay {
                    Color.clear
                        .frame(width: metrics.length(30), height: metrics.length(28))
                        .contentShape(Rectangle())
                        .onTapGesture { if hovering { close() } }
                }
                .padding(.leading, hovering && tab.sleeping ? metrics.length(Metrics.sleepStatusTravel) : 0)
                .transition(.opacity)
            }
        }
        .animation(Motion.quick, value: tab.loading)
        .padding(.leading, metrics.length(11))
        .padding(.trailing, metrics.length(editing ? 11 : 7))
        .padding(.vertical, metrics.length(6))
        .frame(width: span, alignment: .leading)
    }

    @ViewBuilder
    private var ground: some View {
        if live {
            // The grey fills from the left as you read down the page. It is
            // the one thing in the window that says how far in you are, and
            // it says it without adding anything to the window.
            Chosen(radius: metrics.length(9))
                .overlay(alignment: .leading) {
                    // Not on a pinned square, nor a tab down to its mark. Thirty
                    // points of grey filling from the left behind a single letter
                    // says nothing about anything — it needs the width of a title
                    // to read as progress at all.
                    if !pinned && !compact && prefs.showsReading {
                        Rectangle()
                            .fill(Palette.ink.opacity(0.055))
                            .frame(width: span * tab.reading)
                            .animation(.easeOut(duration: 0.15), value: tab.reading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: metrics.length(9), style: .continuous))
                    }
                }
                .matchedGeometryEffect(id: "live", in: pill)
        } else if hovering {
            RoundedRectangle(cornerRadius: metrics.length(9), style: .continuous)
                .fill(Palette.hover)
        } else if pinned {
            // A letter with nothing behind it reads as debris. A pinned tab
            // keeps a faint ground of its own so the block of them reads as
            // one thing.
            RoundedRectangle(cornerRadius: metrics.length(9), style: .continuous)
                .fill(Palette.wash.opacity(0.55))
        }
    }

    private var colour: Color {
        if live { return Palette.ink }
        return hovering ? Palette.ink.opacity(0.7) : Palette.muted
    }
}

/// The address, inside its own tab.
///
/// A field of its own rather than SwiftUI's, for one reason: the system paints
/// selected text as a solid block of accent colour, which over a pale grey pill
/// this size is the loudest thing in the window. Here it is a tenth of the ink.
struct TabAddressField: NSViewRepresentable {
    @ObservedObject var browser: Browser

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12.5)
        field.textColor = Palette.NS.ink
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.stringValue = browser.tabDraft
        context.coordinator.watch(field)
        return field
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.unwatch()
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.browser = browser
        if !coordinator.typing, field.stringValue != browser.tabDraft {
            field.stringValue = browser.tabDraft
        }
        guard !coordinator.claimed else { return }
        coordinator.claimed = true
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.11)),
                .foregroundColor: Palette.NS.ink,
            ]
            editor.selectAll(nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var browser: Browser
        var claimed = false
        var typing = false

        init(browser: Browser) { self.browser = browser }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            typing = true
            browser.tabDraft = field.stringValue
            typing = false
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy command: Selector
        ) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                // Returning true keeps the field editing, which is what lets a
                // refused address stay on screen instead of being thrown away.
                browser.commitTabEdit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                browser.cancelTabEdit()
                return true
            default:
                return false
            }
        }

        /// Clicking anywhere else keeps what was typed, as Return does.
        func controlTextDidEndEditing(_ note: Notification) {
            let browser = browser
            DispatchQueue.main.async { browser.finishTabEdit() }
        }

        /// A press on something that takes no focus — the strip's empty
        /// stretch, the column below the rows — leaves the field focused and
        /// editing, so presses are watched for while it is there: one anywhere
        /// but in the field ends the edit the same way. The press itself goes
        /// on to what it was for.
        private var watcher: Any?

        func watch(_ field: NSTextField) {
            guard watcher == nil else { return }
            watcher = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self, weak field] event in
                guard let self, let field, event.window === field.window,
                      !field.bounds.contains(field.convert(event.locationInWindow, from: nil))
                else { return event }
                let browser = self.browser
                DispatchQueue.main.async { browser.finishTabEdit() }
                return event
            }
        }

        func unwatch() {
            if let watcher { NSEvent.removeMonitor(watcher) }
            watcher = nil
        }
    }
}

/// What a right-click on any tab offers, wherever the tab is drawn.
struct TabMenu: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab

    var body: some View {
        PanelMenu(browser: browser, panels: browser.panels, tab: tab)
        Divider()
        if tab.pin == nil {
            Button { browser.pin(tab) } label: { Label("Pin", systemImage: "pin") }
                .disabled(tab.isBlank)
        } else {
            Button { browser.unpin(tab) } label: { Label("Unpin", systemImage: "pin.slash") }
        }
        Divider()
        Button {
            browser.select(tab)
            browser.duplicate()
        } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        .disabled(tab.isBlank)
        Button {
            browser.select(tab)
            browser.copyAddress()
        } label: { Label("Copy Link", systemImage: "link") }
        .disabled(tab.isBlank)
        LinkRouteMenu(browser: browser, address: tab.address, space: tab.space)
        Divider()
        if tab.pin != nil {
            Button { browser.close(tab) } label: { Label("Close Tab", systemImage: "xmark") }
        }
        Button { browser.closeOthers(but: tab) } label: { Label("Close Other Tabs", systemImage: "xmark.square") }
            .disabled(browser.tabs.count < 2)
    }
}

/// One gesture or the other, never the two together.
struct OneClick: ViewModifier {
    let double: Bool
    let act: () -> Void

    func body(content: Content) -> some View {
        if double {
            content.onTapGesture(count: 2, perform: act)
        } else {
            content.onTapGesture(perform: act)
        }
    }
}

/// The middle button on a tab closes it, as it does in every other browser.
///
/// SwiftUI has no gesture for that button, so this is a real view laid over
/// the tab — and a real view is asked first (see DragStrip). It says yes for
/// the middle button and nothing else: to a left click, a drag or a right
/// click it isn't there, and the tab's own gestures and menu go on as before.
struct MiddleClick: NSViewRepresentable {
    let act: () -> Void

    func makeNSView(context: Context) -> NSView { Catch() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? Catch)?.act = act
    }

    private final class Catch: NSView {
        var act: () -> Void = {}
        private var pressed = false

        /// Asked about every event that lands on the tab, the pointer moving
        /// over it included; the one being delivered is the one to judge by.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .otherMouseDown || event.type == .otherMouseUp,
                  event.buttonNumber == 2
            else { return nil }
            return super.hitTest(point)
        }

        override func otherMouseDown(with event: NSEvent) {
            pressed = true
        }

        /// On the release, not the press, and only if it is still over the
        /// tab: a middle button pressed by mistake can be taken back the way
        /// a click on the cross can, by moving off before letting go.
        override func otherMouseUp(with event: NSEvent) {
            guard pressed else { return }
            pressed = false
            if bounds.contains(convert(event.locationInWindow, from: nil)) { act() }
        }
    }
}

/// An almost-closed ring, turning — the same one the canvas app uses, small
/// enough to sit inside a tab without becoming the loudest thing in it.
struct Ring: View {
    var size: CGFloat = 10
    @State private var angle: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.78)
            .stroke(
                Palette.muted.opacity(0.7),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
            )
            .frame(width: size, height: size)
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}


/// The letter of a pinned tab, typed in the square itself.
///
/// A field of its own rather than SwiftUI's, for the same reason as the address
/// in a tab: the system paints selected text as a solid block of accent colour,
/// and over a thirty-point grey square that is the loudest thing on screen.
struct PinField: NSViewRepresentable {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser, tab: tab) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.font = .systemFont(ofSize: 12, weight: .regular)
        field.textColor = Palette.NS.ink
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.stringValue = tab.pin ?? ""
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.browser = browser
        coordinator.tab = tab
        if !coordinator.typing, field.stringValue != tab.pin ?? "" {
            field.stringValue = tab.pin ?? ""
        }
        guard !coordinator.claimed else { return }
        coordinator.claimed = true
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.12)),
                .foregroundColor: Palette.NS.ink,
            ]
            // The guessed letter arrives selected, so one keystroke replaces it
            // and doing nothing keeps it.
            editor.selectAll(nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var browser: Browser
        var tab: Tab
        var claimed = false
        var typing = false

        init(browser: Browser, tab: Tab) {
            self.browser = browser
            self.tab = tab
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            typing = true
            browser.letter(field.stringValue, for: tab)
            // One character only, and shown as it will be worn.
            field.stringValue = tab.pin ?? ""
            typing = false
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy command: Selector
        ) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.cancelOperation(_:)),
                 #selector(NSResponder.insertTab(_:)):
                browser.endPinEdit()
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ note: Notification) {
            let browser = browser
            DispatchQueue.main.async { browser.endPinEdit() }
        }
    }
}
