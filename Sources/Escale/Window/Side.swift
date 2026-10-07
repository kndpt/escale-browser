import SwiftUI

/// The rail and the tab column, down the left instead of across the top.
///
/// Both start under the window's title line, where the traffic lights are, so
/// the first space door and the column's title share their top with the page
/// frame beside them. The layout is drawn from the window's own top edge, not
/// from AppKit's title-bar safe area, whose height is not one of ours.
///
/// Open or folded (⌘S, FoldDoor) is one state, and every piece is derived
/// from it on the caller's animation (Motion.fade): the footprint the page
/// makes room for (ContentView), and here the column's contents sliding back
/// under the rail while they fade. The column's frame clips that travel at
/// the rail, so nothing draws over the rail or the page.
struct SidebarChrome: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    @State private var spaceFrames: [UUID: CGRect] = [:]
    @StateObject private var spaceHover = HoverDwell()
    @StateObject private var spaceDrag = SpaceDrag()

    var body: some View {
        let open = !browser.folded
        let column = metrics.sidebarWidth(prefs.sideWidth)
        return HStack(spacing: 0) {
            if prefs.usesSpaces {
                SpaceRail(browser: browser, hover: spaceHover, presences: browser.presences)
                    .zIndex(1)
            }
            SideBar(
                browser: browser,
                prefs: prefs,
                spaceFrames: $spaceFrames,
                spaceHover: spaceHover,
                spaceDrag: spaceDrag
            )
            .opacity(open ? 1 : 0)
            .offset(x: open ? 0 : -column)
            .allowsHitTesting(open)
            .frame(width: column)
            // The travel ends under the rail, never over it.
            .clipped()
        }
        .frame(width: metrics.sidebarFootprint(prefs.sideWidth, rail: prefs.usesSpaces, folded: !open),
               alignment: .leading)
        .frame(maxHeight: .infinity)
        .clipped()
        .overlay {
            GeometryReader { geometry in
                if let carried = spaceDrag.carried, carried.origin != browser.spaceID {
                    let bounds = geometry.frame(in: .global)
                    let faceWidth = min(metrics.length(170), column - metrics.length(20))
                    SpaceDragFace(carried: carried)
                        .frame(width: faceWidth)
                        .position(x: min(max(carried.point.x - bounds.minX,
                                             metrics.spaceRailWidth + metrics.spaceRailInset + faceWidth / 2),
                                         bounds.width - faceWidth / 2 - metrics.spaceRailInset),
                                  y: carried.point.y - bounds.minY)
                }
            }
            .allowsHitTesting(false)
        }
        // The band above the rail is the title bar: the window is dragged
        // from it. The lights, in AppKit's own title bar view, stay above it
        // and keep their clicks; the column's band has its own (SideBar).
        .background(alignment: .top) {
            DragStrip().frame(height: browser.corner)
        }
        .onPreferenceChange(SpaceIconFrames.self) { spaceFrames = $0 }
        .onDisappear {
            spaceDrag.cancel()
            spaceHover.cancel()
        }
        .ignoresSafeArea()
    }
}

/// The tabs, down the left instead of across the top.
///
/// The same pieces as the strip — the grey that slides to the tab you picked,
/// the pinned squares, the cross that appears under the pointer — laid out the
/// other way. The global title bar keeps the traffic lights; the column starts
/// under that line and the page takes the whole height beside it.
struct SideBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var panels: Panels
    @ObservedObject var prefs: Preferences
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Namespace private var pill

    @State private var dragging: Tab.ID?
    @State private var from = 0
    @State private var travel: CGFloat = 0
    @State private var landing = false
    /// The width the column had when the edge was picked up.
    @State private var grabbed: CGFloat?
    @State private var onEdge = false
    @Binding private var spaceFrames: [UUID: CGRect]
    @ObservedObject private var spaceHover: HoverDwell
    @ObservedObject private var spaceDrag: SpaceDrag
    @State private var looseFrame: CGRect = .zero
    @State private var activeShelfFrame: CGRect = .zero
    @State private var dragDraft: String?
    @StateObject private var mergeHover = HoverDwell()

    /// A pin, picked up out of the grid — a separate state from the loose
    /// rows above, since the two gestures never happen at once but move on
    /// two different axes.
    /// The neighbouring spaces' own grey, apart from this one's.
    @Namespace private var before
    @Namespace private var after

    @State private var pinDragging: Tab.ID?
    @State private var pinFrom = 0
    @State private var pinTravel: CGSize = .zero

    init(
        browser: Browser,
        prefs: Preferences,
        spaceFrames: Binding<[UUID: CGRect]>,
        spaceHover: HoverDwell,
        spaceDrag: SpaceDrag
    ) {
        self.browser = browser
        self.panels = browser.panels
        self.prefs = prefs
        self._spaceFrames = spaceFrames
        self.spaceHover = spaceHover
        self.spaceDrag = spaceDrag
    }

    private var row: CGFloat { metrics.length(28) }
    private var gap: CGFloat { metrics.length(2) }
    private var square: CGFloat { metrics.length(34) }
    private var pinGap: CGFloat { metrics.length(4) }

    /// Tab drags are read in window points, the same points in which rows and
    /// grids are laid out. There is no transformed coordinate space to undo.
    static func layout(_ distance: CGSize) -> CGSize {
        distance
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Not under the card for a new space: it isn't made of views that
            // would take the click first.
            DragStrip(reserved: 0, below: browser.makingSpace ? .greatestFiniteMagnitude : rowsEnd,
                      swipe: browser)

            VStack(alignment: .leading, spacing: 0) {
                titleLine
                if separateNavigation {
                    Helm(browser: browser)
                        .frame(height: browser.corner)
                }
                if prefs.usesSpaces { spaceTitle }

                // The spaces side by side, as pages: two fingers sideways move
                // the one on screen and the next one together, the next one
                // coming in as this one goes, with nothing between them.
                pages

                Spacer(minLength: 0)
                MiniPlayer(playback: browser.playback, returnToSource: browser.returnToMedia, floatSource: browser.floatMedia,
                           spaceName: { id in browser.spaces.first { $0.id == id }?.name ?? "Space" })
            }
            .padding(.horizontal, metrics.spaceRailInset)
            // Clear of the foot, which sits over the column's bottom edge.
            .padding(.bottom, footHeight)

            // With the spaces on, the tools live at the rail's foot.
            if !prefs.usesSpaces {
                VStack {
                    Spacer()
                    foot
                }
            }
        }
        .frame(width: metrics.sidebarWidth(prefs.sideWidth))
        .frame(maxHeight: .infinity)
        // Rows on their way to or from another space stay in the column.
        .clipped()
        .onAppear { SpaceSwipe.shared.start(for: browser) }
        // Part of the window's envelope, not a card of its own: no ground and
        // no rule down its edge — the page's frame is the edge (docs/DESIGN.md).
        // Drawn over a page when it peeks out, Fold gives it glass.
        .background(landing ? Palette.hover : Color.clear)
        .overlay(alignment: .trailing) { edge }
        .onDrop(of: [.url, .text], isTargeted: $landing) { providers in
            browser.take(providers)
        }
        .animation(Motion.quick, value: landing)
        .shortcutAnimation(Motion.glide, value: browser.activeID, enabled: browser.prefs.fasterShortcuts, reduced: reduceMotion)
        .shortcutAnimation(Motion.glide, value: browser.editingTab, enabled: browser.prefs.fasterShortcuts, reduced: reduceMotion)
        .shortcutAnimation(Motion.settle, value: browser.tabs.map(\.id), enabled: browser.prefs.fasterShortcuts, reduced: reduceMotion)
        .animation(Motion.settle, value: browser.pinnedCount)
        .onDisappear { mergeHover.cancel() }
    }

    /// The column's part of the window's title line, the lights' line: clear
    /// of the lights where they reach over it, then back, forward and reload
    /// when there is no bar over the page to hold them, and the column's own
    /// door at its far end. What is left is title bar, dragged by and
    /// double-clicked like one; the doors take their own clicks.
    private var titleLine: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: metrics.clearingLights(from: railWidth + metrics.spaceRailInset))
            if !prefs.usesSpaces {
                TabSearchDoor(prefs: prefs) { browser.summon() }
            }
            if !browser.showsBar && !separateNavigation { Helm(browser: browser) }
            DragStrip()
            FoldDoor(browser: browser, folded: false)
        }
        .frame(height: browser.corner)
    }

    /// Without the rail, the lights consume most of a narrow title line.
    /// Keep search and folding on that line; navigation gets its own row
    /// only when all five doors cannot fit without clipping the column.
    private var separateNavigation: Bool {
        guard !prefs.usesSpaces, !browser.showsBar else { return false }
        let clearance = metrics.clearingLights(from: metrics.spaceRailInset)
        let needed = clearance + metrics.length(Metrics.tabSearchSide) + metrics.helm + metrics.length(26)
        return metrics.sidebarWidth(prefs.sideWidth) - 2 * metrics.spaceRailInset < needed
    }

    /// The rail's width, where the column starts from the window's edge.
    private var railWidth: CGFloat { prefs.usesSpaces ? metrics.spaceRailWidth : 0 }

    /// The current space is named where the tab column begins, on the row of
    /// the rail's first door. Its menu keeps the existing rename, duplicate,
    /// icon and ordering actions reachable without spending another permanent
    /// control in the rail. Search sits beside this title so it stays reachable
    /// above the scrolling tabs without sharing the creation row.
    private var spaceTitle: some View {
        HStack(spacing: gap) {
            Button { SpaceMenu.show(for: browser) } label: {
                HStack(spacing: metrics.length(6)) {
                    Text(browser.space.name)
                        .font(.system(size: metrics.length(13), weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.system(size: metrics.length(9), weight: .medium))
                        .foregroundStyle(Palette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: titleHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Space Options…")
            .accessibilityLabel("Space: \(browser.space.name)")
            TabSearchDoor(prefs: prefs) { browser.summon() }
        }
    }


    /// The column's edge: pull it to make the column wider or narrower,
    /// double-click it to put it back. The hairline darkens under the pointer
    /// so the edge says it can be taken before it is.
    private var edge: some View {
        Rectangle()
            .fill(Palette.ink.opacity(onEdge || grabbed != nil ? 0.18 : 0))
            .frame(width: onEdge || grabbed != nil ? metrics.length(2) : metrics.length(1))
            .frame(width: metrics.length(9))
            .contentShape(Rectangle())
            .onHover { over in
                onEdge = over
                if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if grabbed == nil { grabbed = prefs.sideWidth }
                        // Global drag distance is in window points; the stored
                        // width is kept in the compact layout's points.
                        let wanted = (grabbed ?? prefs.sideWidth)
                            + metrics.layout(value.translation.width)
                        prefs.sideWidth = min(Metrics.sideMax, max(Metrics.sideMin, wanted))
                    }
                    .onEnded { _ in grabbed = nil }
            )
            .modifier(OneClick(double: true) {
                withAnimation(Motion.settle) { prefs.sideWidth = Metrics.side }
            })
            .animation(Motion.quick, value: onEdge)
    }

    // MARK: - the spaces, as pages

    /// Where the space on screen sits among them: one past the last while
    /// the card for a new one is up.
    private var spaceAt: Int {
        browser.makingSpace ? browser.spaces.count : (browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0)
    }

    private var pages: some View {
        let width = metrics.sidebarWidth(prefs.sideWidth)
        let swipe = browser.spaceSwipe
        let at = spaceAt
        return ZStack(alignment: .topLeading) {
            page(at, pill: pill)
                .offset(x: swipe)
            // Only while the fingers are bringing one in: the one they are
            // bringing, a page's width away.
            if swipe > 0, at > 0 {
                page(at - 1, pill: before)
                    .offset(x: swipe - width)
            }
            if swipe < 0, at < browser.spaces.count {
                page(at + 1, pill: after)
                    .offset(x: swipe + width)
            }
        }
        // The pages are the column's whole width, each with its own margin.
        .padding(.horizontal, -10)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// One space's page: the rows on screen, another space's rows as they
    /// were left, or past the last the card for a new one.
    @ViewBuilder
    private func page(_ index: Int, pill: Namespace.ID) -> some View {
        Group {
            if index == browser.spaces.count {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    NewSpaceCard(browser: browser)
                    Spacer(minLength: 0)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
            } else if browser.spaces[index].id == browser.spaceID {
                VStack(alignment: .leading, spacing: 0) {
                    if !pinnedTabs.isEmpty {
                        pinned
                            .padding(.bottom, 10)
                    }
                    // A row too long for the window scrolls between the pins
                    // and the foot, rather than running under the lights at one
                    // end and the foot at the other. While it fits it stays a
                    // plain stack, and the space under it is still the
                    // window's to be dragged by. Inside the page: the swipe
                    // between spaces moves the page, scroll and all.
                    ViewThatFits(in: .vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            rows
                            newTab
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            ScrollViewReader { proxy in
                                // The scroll view reaches into the margin on
                                // the right and the rows keep it inside, so the
                                // system's bar lands in the margin beside them
                                // rather than over the cross on the tab under the
                                // pointer. The column's edge lies over that margin
                                // and answers first, so the bar never fights the
                                // resize; the wheel and the trackpad still scroll.
                                ScrollView(.vertical) {
                                    rows.padding(.trailing, 10)
                                }
                                .padding(.trailing, -10)
                                // The tab you go to is the tab you see — ⌘1–⌘9,
                                // ⇧⌘], a link opening beside the one on screen.
                                .onChange(of: browser.activeID) { _, id in
                                    guard let id = browser.entryID(for: id) else { return }
                                    withAnimation(Motion.glide) { proxy.scrollTo(id) }
                                }
                                .onAppear {
                                    if let id = browser.entryID(for: browser.activeID) { proxy.scrollTo(id, anchor: .center) }
                                }
                            }
                            // Creation stays reachable when the list
                            // overflows, without taking width from any tab title.
                            newTab
                        }
                    }
                }
            } else {
                preview(browser.parked[browser.spaces[index].id] ?? Parked(tabs: [], active: nil),
                        space: browser.spaces[index].id, pill: pill)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: metrics.sidebarWidth(prefs.sideWidth), alignment: .topLeading)
    }

    /// Another space's rows, drawn with the same pieces as this one's so the
    /// two read as one column while they pass — and nothing to press until
    /// it is the one on screen.
    private func preview(_ row: Parked, space: UUID, pill: Namespace.ID) -> some View {
        let pins = row.tabs.filter { $0.pin != nil && panels.group($0.id) == nil }
        // A bookmark's own tab is under its bookmark (see Shelf.swift).
        let rest = panels.representatives(row.tabs).filter { panels.group($0.id) != nil || ($0.pin == nil && !browser.onShelf($0, in: space)) }
        let cols = SideBar.pinColumns(pins.count)
        let width = pinWidth(for: pins.count)
        let height = min(square, width)
        return VStack(alignment: .leading, spacing: 0) {
            if !pins.isEmpty {
                VStack(spacing: 0) {
                    PinGrid(columns: cols, width: width, height: height, spacing: pinGap) {
                        ForEach(pins) { tab in
                            PinSquare(browser: browser, prefs: prefs, tab: tab, live: tab.id == row.active,
                                      pill: pill, width: width, height: height)
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            // That space's own bookmarks (see Shelf.swift).
            if prefs.sideBookmarks { Shelf(browser: browser, bookmarks: browser.bookmarks(of: space), mergeHover: mergeHover) }
            VStack(spacing: gap) {
                ForEach(rest) { tab in
                    if let group = panels.group(tab.id) {
                        PanelEntry(browser: browser, panels: panels, group: group, row: row.tabs)
                    } else {
                    SideRow(browser: browser, prefs: prefs, tab: tab, live: tab.id == row.active, pill: pill, close: {})
                    }
                }
            }
            newTab
        }
        .allowsHitTesting(false)
    }

    /// Where the rows stop and the window's own drag area starts. Added up
    /// from what was drawn rather than measured: a measurement would arrive a
    /// frame late, and for one frame the whole column would drag the window.
    private var rowsEnd: CGFloat {
        let pins = pinnedTabs.count
        let cols = SideBar.pinColumns(pins)
        let pinRows = pins == 0 ? 0 : (pins + cols - 1) / cols
        let pinBlock = pinRows == 0 ? 0
            : CGFloat(pinRows) * pinHeight + CGFloat(pinRows - 1) * pinGap + metrics.length(10)
        let loose = CGFloat(looseTabs.count) * (row + gap)
        // The bookmarks above the rows, added up the same way (see Shelf.swift).
        let shelf = prefs.sideBookmarks ? Shelf.height(for: browser) : 0
        let title = prefs.usesSpaces ? titleHeight : 0
        let navigation = separateNavigation ? browser.corner : 0
        return browser.corner + navigation + title + pinBlock + shelf + loose + row + metrics.length(8)
    }

    /// The space's name is as tall as a rail door, so the two share a line.
    private var titleHeight: CGFloat { metrics.length(SpaceRail.icon) }

    // MARK: - the pinned squares

    private var pinnedTabs: [Tab] { browser.tabs.filter { $0.pin != nil && panels.group($0.id) == nil } }
    /// Not a bookmark's own tab, which is under its bookmark (see Shelf.swift).
    private var looseTabs: [Tab] { browser.tabEntries.filter { panels.group($0.id) != nil || ($0.pin == nil && !browser.onShelf($0)) } }

    /// Three columns is the block's own shape — up to six pins, that's two
    /// full rows, and one or two is just those same three places with a
    /// couple of them empty rather than a lonely row of its own width. Only
    /// past six does the block widen, one column at a time, to stay at two
    /// rows for as long as that's a reasonable shape at all.
    private static func pinColumns(_ count: Int) -> Int {
        max(3, (count + 1) / 2)
    }

    /// However many columns the count calls for, they split the row's own
    /// width between them — the row is what fills edge to edge, not each
    /// cell on its own, so this grows past 34 just as readily as it shrinks
    /// below it.
    private var pinWidth: CGFloat { pinWidth(for: pinnedTabs.count) }

    private func pinWidth(for count: Int) -> CGFloat {
        let cols = SideBar.pinColumns(count)
        guard cols > 0 else { return square }
        let available = metrics.sidebarWidth(prefs.sideWidth) - metrics.length(20) - CGFloat(cols - 1) * pinGap
        return max(metrics.length(20), available / CGFloat(cols))
    }

    /// The one dimension that doesn't chase the sidebar's width: past three
    /// columns' worth of room a cell would otherwise turn into a big square
    /// rather than the wide, short button pinned tabs actually look like
    /// everywhere else in this app. It only shrinks below 34 alongside the
    /// width, once a narrow column leaves no other choice.
    private var pinHeight: CGFloat {
        min(square, pinWidth)
    }

    /// The grid itself: fixed-size cells, left-aligned, so a half-empty last
    /// row holds its ground rather than stretching to fill it.
    private var pinned: some View {
        let tabs = pinnedTabs
        let cols = SideBar.pinColumns(tabs.count)
        let width = pinWidth
        let height = pinHeight
        // Measured in the grid's own space, not the square's: a square that
        // has just been moved to a new cell would otherwise report the drag
        // from where it now is, the target would jump back, and the square
        // would shuttle between two cells for as long as the finger stayed.
        return VStack(spacing: 0) { PinGrid(columns: cols, width: width, height: height, spacing: pinGap) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                let held = pinDragging == tab.id
                let carried = panels.carrying == tab.id
                PinSquare(
                    browser: browser,
                    prefs: prefs,
                    tab: tab,
                    live: tab.id == browser.activeID && !browser.tuning,
                    pill: pill,
                    width: width,
                    height: height
                )
                .offset(carried ? .zero : pinOffset(held: held, index: index, columns: cols))
                // Under the hand exactly, as a row is (see the rows below).
                .transaction { if held && !carried { $0.animation = nil } }
                .opacity(carried ? 0.4 : 1)
                .animation(reduceMotion ? nil : Motion.settle, value: carried)
                .zIndex(held ? 1 : 0)
                .shadow(color: held && !carried ? Palette.shadow : .clear, radius: 10, y: 3)
                .gesture(pinReorder(tab: tab, index: index, columns: cols, width: width, height: height))
                .modifier(PanelEntryFrame(id: tab.id))
            }
        } }
        .coordinateSpace(name: "pins")
    }

    /// The one square actually held stays glued to the fingers; every other
    /// square is already exactly where it belongs, because `browser.move`
    /// put it there — this only cancels out the bit of that same movement
    /// the held square already got for free by changing index underneath
    /// its own drag.
    private func pinOffset(held: Bool, index: Int, columns: Int) -> CGSize {
        guard held else { return .zero }
        let stepX = pinWidth + pinGap
        let stepY = pinHeight + pinGap
        let from = (row: pinFrom / columns, col: pinFrom % columns)
        let now = (row: index / columns, col: index % columns)
        return CGSize(
            width: pinTravel.width - CGFloat(now.col - from.col) * stepX,
            height: pinTravel.height - CGFloat(now.row - from.row) * stepY
        )
    }

    /// How many cells the drag has moved, in the grid's own row-major order
    /// — a straight line through the array a column-major offset would get
    /// wrong the moment it crossed a row. Row and column travel each measure
    /// themselves against that axis's own step now that a cell's width and
    /// height aren't the same number.
    private func pinDelta(columns: Int, stepX: CGFloat, stepY: CGFloat) -> Int {
        let col = Int((pinTravel.width / stepX).rounded())
        let row = Int((pinTravel.height / stepY).rounded())
        return row * columns + col
    }

    private func pinTarget(from: Int, moved: Int) -> Int {
        min(max(0, from + moved), max(0, pinnedTabs.count - 1))
    }

    /// Pick a square up and the others make way — across a row, and down
    /// into the next, exactly as far as the fingers actually moved.
    private func pinReorder(tab: Tab, index: Int, columns: Int, width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .onChanged { value in
                if pinDragging != tab.id {
                    pinDragging = tab.id
                    pinFrom = index
                    dragDraft = tab.id == browser.activeID && tab.address == nil ? browser.field.typed : nil
                }
                spaceDrag.begin(tab.id, origin: tab.space, title: tab.label, symbol: "pin.fill", at: value.location,
                                move: { point in
                    if browser.aimPanel(tab, at: point) { return }
                    guard browser.spaceID != tab.space else { return }
                    spaceHover.cancel()
                    _ = browser.aimShelf(at: metrics.layout(point.y - looseFrame.minY))
                },
                                release: { point in
                    finishTab(tab, at: point)
                    withAnimation(Motion.settle) { pinDragging = nil; pinTravel = .zero; dragDraft = nil }
                }, abort: {
                    panels.finish()
                    spaceHover.cancel()
                    browser.shelfAim = nil
                    withAnimation(Motion.settle) { pinDragging = nil; pinTravel = .zero; dragDraft = nil }
                })
                pinTravel = SideBar.layout(value.translation)
                if browser.aimPanel(tab, at: value.location) {
                    // Carried off to the pages, the square goes back to its own cell.
                    if index != pinFrom { withAnimation(Motion.settle) { browser.move(tab, to: browser.place(of: pinFrom, among: pinnedTabs)) } }
                    spaceHover.cancel(); browser.shelfAim = nil; return
                }
                aimSpace(tab.id, at: value.location)
                if spaceHover.target != nil {
                    browser.shelfAim = nil
                    return
                }
                if browser.aimShelf(at: metrics.layout(value.location.y - looseFrame.minY)) { return }
                // The squares make way while the hand stays over the column;
                // heading for the pages carries the square instead.
                guard value.location.x <= looseFrame.maxX else { return }
                let target = pinTarget(from: pinFrom, moved: pinDelta(columns: columns, stepX: width + pinGap, stepY: height + pinGap))
                if target != index {
                    withAnimation(Motion.settle) { browser.move(tab, to: browser.place(of: target, among: pinnedTabs)) }
                }
            }
            .onEnded { value in
                spaceDrag.end(at: value.location)
            }
    }

    // MARK: - the rows

    private var loose: some View {
        VStack(spacing: gap) {
            // See the grid: the drag is measured in the column's space, not
            // the row's, so a row that has just moved keeps its bearings.
            ForEach(Array(looseTabs.enumerated()), id: \.element.id) { index, tab in
                let step = row + gap
                let held = dragging == tab.id
                let carried = panels.carrying == tab.id
                Group {
                if let group = panels.group(tab.id) {
                    PanelEntry(browser: browser, panels: panels, group: group)
                } else {
                SideRow(
                    browser: browser,
                    prefs: prefs,
                    tab: tab,
                    live: tab.id == browser.activeID && !browser.tuning,
                    pill: pill,
                    close: { browser.close(tab) }
                )
                }
                }
                .offset(y: held && !carried ? travel - CGFloat(index - from) * step : 0)
                // Under the hand exactly. Its place in the row springs when it
                // passes another tab, and the offset springs back the same way —
                // until the next move of the hand cuts the offset's spring short
                // and leaves the place's running: the tab jumped a whole slot and
                // drifted back each time it passed one. Only the others glide.
                .transaction { if held && !carried { $0.animation = nil } }
                // Over the pages the tab travels as a carried face; its row
                // waits at home, stepped back, until the drop.
                .opacity(carried ? 0.4 : 1)
                .animation(reduceMotion ? nil : Motion.settle, value: carried)
                .zIndex(held ? 1 : 0)
                .shadow(color: held && !carried ? Palette.shadow : .clear, radius: 12, y: 4)
                .gesture(reorder(tab: tab, index: index, step: step))
                .modifier(PanelEntryFrame(id: tab.id))
            }
        }
        .background(GeometryReader { proxy in
            Color.clear.onAppear { looseFrame = proxy.frame(in: .global) }
                .onChange(of: proxy.frame(in: .global)) { _, frame in looseFrame = frame }
        })
        .coordinateSpace(name: "rows")
    }

    /// Pick a row up and the others make way as it passes them.
    private func reorder(tab: Tab, index: Int, step: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .onChanged { value in
                if dragging != tab.id {
                    dragging = tab.id
                    from = index
                    dragDraft = tab.id == browser.activeID && tab.address == nil ? browser.field.typed : nil
                }
                spaceDrag.begin(tab.id, origin: tab.space, title: tab.label, symbol: "square.on.square", at: value.location,
                                move: { point in
                    if browser.aimPanel(tab, at: point) { return }
                    guard browser.spaceID != tab.space else { return }
                    spaceHover.cancel()
                    _ = browser.aimShelf(at: metrics.layout(point.y - looseFrame.minY))
                },
                                release: { point in
                    finishTab(tab, at: point)
                    withAnimation(Motion.settle) { dragging = nil; travel = 0; dragDraft = nil }
                }, abort: {
                    panels.finish()
                    spaceHover.cancel()
                    browser.shelfAim = nil
                    withAnimation(Motion.settle) { dragging = nil; travel = 0; dragDraft = nil }
                })
                travel = SideBar.layout(value.translation).height
                if browser.aimPanel(tab, at: value.location) {
                    // Carried off to the pages, the row goes back to its own place.
                    if index != from { withAnimation(Motion.settle) { browser.move(tab, to: browser.place(of: from, among: looseTabs)) } }
                    spaceHover.cancel(); browser.shelfAim = nil; return
                }
                aimSpace(tab.id, at: value.location)
                if spaceHover.target != nil {
                    browser.shelfAim = nil
                    return
                }
                // Held over the bookmarks, it is aimed at them rather than at
                // a place in the row, and the row keeps it where it was (see
                // Shelf.swift).
                let shelfY = metrics.layout(value.location.y - looseFrame.minY)
                if browser.aimShelf(at: shelfY) {
                    if index != from { withAnimation(Motion.settle) { browser.move(tab, to: browser.place(of: from, among: looseTabs)) } }
                    return
                }
                // The rows make way while the hand stays over the column;
                // heading for the pages carries the tab instead.
                guard value.location.x <= looseFrame.maxX else { return }
                let moved = Int((travel / step).rounded())
                let target = min(max(0, from + moved), looseTabs.count - 1)
                if target != index {
                    // Positions here are among the loose rows; the pinned
                    // block sits in front of them in the real list, and
                    // bookmarks' tabs among them (see Shelf.swift).
                    withAnimation(Motion.settle) {
                        browser.move(tab, to: browser.place(of: target, among: looseTabs))
                    }
                }
            }
            .onEnded { value in
                spaceDrag.end(at: value.location)
            }
    }

    /// A Space changes only after the pointer has stayed on its door through
    /// the same pulse and hold used for a bookmark merge.
    private func aimSpace(_ source: UUID, at point: CGPoint) {
        guard prefs.usesSpaces else { spaceHover.cancel(); return }
        let target = spaceFrames.first { $0.value.contains(point) && $0.key != browser.spaceID }?.key
        spaceHover.aim(source: source, at: target) { [weak browser] in
            if let target { browser?.switchSpace(to: target, focus: false) }
        }
    }

    private func finishTab(_ tab: Tab, at point: CGPoint) {
        defer { browser.shelfAim = nil }
        if panels.cancelled { panels.finish(); spaceHover.cancel(); return }
        if browser.dropPanel(tab, at: point) { spaceHover.cancel(); return }
        if browser.spaceID == tab.space, spaceHover.target == nil,
           point.x < looseFrame.minX || point.x > looseFrame.maxX { return }
        let overDoor = spaceHover.target.flatMap { spaceFrames[$0]?.contains(point) == true ? $0 : nil }
        let destination = browser.spaceID
        let switched = destination != tab.space
        let ready = overDoor.map { spaceHover.accepts(source: tab.id, target: $0) } ?? false
        spaceHover.cancel()
        if switched || ready {
            guard let moved = browser.transfer(tab, to: destination, draft: dragDraft) else { return }
            if overDoor == nil {
                let shelfY = metrics.layout(point.y - looseFrame.minY)
                if browser.aimShelf(at: shelfY) {
                    if moved.pin != nil { browser.unpin(moved) }
                    browser.dropOnShelf(moved)
                }
            }
        } else if overDoor == nil {
            if browser.shelfAim != nil && tab.pin != nil { browser.unpin(tab) }
            browser.dropOnShelf(tab)
        }
    }

    /// Bookmarks and loose tabs scroll; their actions stay within reach below.
    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The bookmarks above them, when asked for (see Shelf.swift).
            if prefs.sideBookmarks {
                Shelf(browser: browser, bookmarks: browser.bookmarks,
                      spaceHover: spaceHover, spaceFrames: spaceFrames,
                      activeFrame: $activeShelfFrame, spaceDrag: spaceDrag, mergeHover: mergeHover)
            }
            loose
        }
    }

    /// The foot's action row and its margin beneath, only while there is no
    /// rail to hold the tools (see Tools).
    private var footHeight: CGFloat { prefs.usesSpaces ? 0 : metrics.length(26 + 10) }

    private var newTab: some View {
        Quiet(icon: "plus", title: "New tab", shortcut: prefs.keys(.newTab),
              height: row) { browser.newTab() }
            .help(prefs.keyHelp(.newTab))
            .padding(.top, gap)
    }

    /// The tools in a row at the bottom, out of the page's way, when the
    /// spaces are off and there is no rail.
    private var foot: some View {
        HStack(spacing: metrics.length(2)) {
            Tools(browser: browser)
            GateDoor(browser: browser)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, metrics.length(10))
        .padding(.bottom, metrics.length(10))
    }

}

/// The pinned squares' grid, every cell laid out at once. A lazy grid makes
/// its cells only once the column is on screen, where the column's slide
/// can't take them along: folded with ⌘S and brought back, the squares stood
/// in place while the column came in beneath them. A dozen squares need no
/// laziness.
private struct PinGrid: Layout {
    let columns: Int
    let width: CGFloat
    let height: CGFloat
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = (subviews.count + columns - 1) / columns
        return CGSize(
            width: CGFloat(columns) * width + CGFloat(max(0, columns - 1)) * spacing,
            height: CGFloat(rows) * height + CGFloat(max(0, rows - 1)) * spacing
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(
                    x: bounds.minX + CGFloat(index % columns) * (width + spacing),
                    y: bounds.minY + CGFloat(index / columns) * (height + spacing)
                ),
                proposal: ProposedViewSize(width: width, height: height)
            )
        }
    }
}

/// A pinned tab as a cell in the block at the top of the column — as wide as
/// its row asks for, but never taller than the classic square, so a row with
/// room to spare turns into a wide, short button rather than a bigger icon.
private struct PinSquare: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    let pill: Namespace.ID
    var width: CGFloat = 34
    var height: CGFloat = 34

    @State private var hovering = false

    /// Everything drawn inside scales off the shorter edge — the one that
    /// stays put — so the glyph sits at its usual size, centred, rather than
    /// stretching to chase the width.
    private var scale: CGFloat { min(width, height) }

    var body: some View {
        Group {
            if browser.editingPin == tab.id {
                PinField(browser: browser, tab: tab)
            } else if prefs.glyph == .icons, let icon = tab.icon {
                Mark(icon: icon, letter: tab.pin ?? "", size: scale * Metrics.navigationIcon / 34, dim: tab.asleep)
            } else {
                Text(tab.pin ?? "")
                    .font(.system(size: scale * 12 / 34, weight: .regular))
                    .foregroundStyle((live ? Palette.ink : Palette.muted).opacity(tab.asleep ? 0.45 : 1))
            }
        }
        .frame(width: scale * Metrics.navigationIcon / 34, height: scale * Metrics.navigationIcon / 34)
        .frame(width: width, height: height)
        .overlay(alignment: .bottomTrailing) {
            SleepMark(tab: tab).padding(scale * Metrics.sleepBadgeOffset / 34)
        }
        .background {
            if live {
                Chosen(radius: scale * 9 / 34)
                    .matchedGeometryEffect(id: "live", in: pill)
            } else {
                RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous)
                    .fill(hovering ? Palette.hover : Palette.wash.opacity(0.55))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous))
        .modifier(OneClick(double: live) {
            if live { browser.editLetter(tab) } else { browser.select(tab) }
        })
        // Put down, like ⌘W: close() is what knows a pin isn't removed.
        .overlay { MiddleClick { browser.close(tab) } }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(browser: browser, tab: tab) }
        .modifier(SleepHint(tab: tab, ordinary: tab.label))
        .animation(Motion.quick, value: hovering)
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

/// One tab, as a line in the column.
private struct SideRow: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    let pill: Namespace.ID
    let close: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    @State private var hovering = false
    @State private var shake: CGFloat = 0

    private var editing: Bool { browser.editingTab == tab.id }

    /// The ring, which stays for as long as the page loads and so keeps a
    /// place of its own at the end of the row. The speaker is at the start
    /// (see body); the cross is only there under the pointer, and takes none.
    private var status: Bool { !editing && tab.loading }

    var body: some View {
        HStack(spacing: metrics.length(8)) {
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
                    Image(systemName: "eye.slash")
                        .font(.system(size: metrics.length(Metrics.navigationSymbol)))
                        .foregroundStyle(colour.opacity(0.7))
                }
                Text(tab.label)
                    .font(.system(size: metrics.length(12.5)))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(colour)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ZStack {
                    if status && tab.loading {
                        Ring().transition(.opacity)
                    } else if tab.sleeping {
                        SleepMark(tab: tab)
                            .offset(x: hovering ? -metrics.length(Metrics.sleepPastCopy) : 0)
                    }
                }
                .frame(width: metrics.length(15), height: metrics.length(15))
                // Sleeping moves beside Copy; its title keeps the same width.
                .opacity(hovering && !tab.sleeping ? 0 : 1)
                // Copy already fits inside Sleeping's travel; reserve it once.
                .padding(.leading, metrics.length(tab.sleeping ? Metrics.sleepPastCopy : Metrics.rowCopySlot))
            }
        }
        .padding(.leading, metrics.length(10))
        .padding(.trailing, metrics.length(editing ? 10 : 7))
        .frame(height: metrics.length(28))
        .frame(maxWidth: .infinity, alignment: .leading)
        // Keep a close slot even without loading or audio, so the badge
        // stays beside the cross and the title does not shift on hover.
        .overlay(alignment: .trailing) {
            if !editing {
                ZStack {
                    if hovering {
                        Image(systemName: "xmark")
                            .font(.system(size: metrics.length(8), weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .frame(width: metrics.length(15), height: metrics.length(15))
                            .background(Palette.ink.opacity(0.07), in: Circle())
                            .transition(.opacity)
                    }
                }
                .frame(width: metrics.length(15), height: metrics.length(15))
                .overlay {
                    Color.clear
                        .frame(width: metrics.length(30), height: metrics.length(28))
                        .contentShape(Rectangle())
                        .onTapGesture { if hovering { close() } }
                }
                .padding(.trailing, metrics.length(7))
            }
        }
        // The address the tab is at now, left of the cross, which keeps the
        // row's end; the place is kept whether or not it shows.
        .overlay(alignment: .trailing) {
            if !editing, hovering {
                RowCopy(browser: browser, tab: tab).transition(.opacity)
            }
        }
        .animation(Motion.quick, value: tab.loading)
        .animation(Motion.quick, value: tab.noisy)
        .background { ground }
        .modifier(Shake(travel: shake))
        .contentShape(RoundedRectangle(cornerRadius: metrics.cardRadius - metrics.length(2), style: .continuous))
        .modifier(OneClick(double: false) {
            if live { browser.beginTabEdit(tab) } else { browser.select(tab) }
        })
        .overlay { MiddleClick(act: close) }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(browser: browser, tab: tab) }
        .modifier(SleepHint(tab: tab))
        .animation(Motion.quick, value: hovering)
        .animation(Motion.glide, value: editing)
        .onChange(of: browser.refusals) { _, _ in
            guard editing else { return }
            shake = 0
            withAnimation(.easeOut(duration: 0.5)) { shake = 1 }
        }
        // A fade, not a scale as well: the row holds the grey that slides to the
        // tab you picked (matchedGeometryEffect), and ViewThatFits swaps the
        // plain and scrolling copies of the rows as an opening folder tips the
        // column over its height. A folder opened and shut in quick turns swaps
        // them while their springs still run, and the selected row, scaled and
        // matched at once, left its slot by twenty points over its neighbour
        // Tests/Bench/sidebar_row_slots.py holds it.
        .transition(.opacity)
    }

    @ViewBuilder
    private var ground: some View {
        if live {
            Chosen(radius: metrics.length(9))
                .overlay(alignment: .leading) {
                    if prefs.showsReading {
                        GeometryReader { geo in
                            Rectangle()
                                .fill(Palette.ink.opacity(0.055))
                                .frame(width: geo.size.width * tab.reading)
                                .animation(.easeOut(duration: 0.15), value: tab.reading)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: metrics.length(9), style: .continuous))
                    }
                }
                .matchedGeometryEffect(id: "live", in: pill)
        } else if hovering {
            RoundedRectangle(cornerRadius: metrics.length(9), style: .continuous)
                .fill(Palette.hover)
        }
    }

    private var colour: Color {
        if live { return Palette.ink }
        return hovering ? Palette.ink.opacity(0.7) : Palette.muted
    }
}

/// The copy button on an open tab's row, left of its cross (bookmarks' rows
/// wear it too, Shelf.swift). It copies where the tab is now, which for a
/// bookmark is the environment that is open, and leaves the tab alone. Watched
/// here so it comes with the address of a tab that had none.
struct RowCopy: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        if tab.address != nil {
            CopyButton(help: "Copy Link", box: Metrics.rowCopy) { browser.copyAddress(of: tab) }
                .padding(.trailing, metrics.length(Metrics.rowCopyBeside))
        }
    }
}

/// A row that is an action rather than a page. Quiet until the pointer is on it.
struct Quiet: View {
    let icon: String
    let title: String
    var shortcut: String? = nil
    var height: CGFloat = 28
    let act: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            HStack(spacing: metrics.length(8)) {
                Image(systemName: icon)
                    .font(.system(size: metrics.length(10), weight: .regular))
                    .frame(width: metrics.length(15))
                Text(title)
                    .font(.system(size: metrics.length(12.5)))
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: metrics.length(10.5)))
                        .padding(.trailing, metrics.length(10))
                }
            }
            // Muted, as the section names are: faint is a hairline's grey,
            // and on the envelope a label in it could not be read.
            .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : Palette.muted)
            .padding(.leading, metrics.length(10))
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: metrics.cardRadius - metrics.length(2), style: .continuous)
                    .fill(hovering ? Palette.hover : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: metrics.cardRadius - metrics.length(2), style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

/// The browser's tools: what acts on the space you are in rather than on a
/// tab. At the rail's foot, beneath the spaces they serve, or at the column's
/// foot when the spaces are off. Localhost is the first; later tools join it
/// here, so the page's surroundings don't grow a new corner for each.
struct Tools: View {
    @ObservedObject var browser: Browser
    /// The door's square and symbol, in compact points (see Door).
    var box: CGFloat = 26
    var glyph: CGFloat = 11

    var body: some View {
        LocalhostDoor(browser: browser, localhost: browser.localhost, box: box, glyph: glyph)
    }
}

/// Localhost's door, which wears the number of endpoints that may still load,
/// not the number visited (Localhost.Availability). It watches the list
/// itself, so the tools do not redraw for every visit.
private struct LocalhostDoor: View {
    @ObservedObject var browser: Browser
    @ObservedObject var localhost: Localhost
    let box: CGFloat
    let glyph: CGFloat

    var body: some View {
        let count = localhost.reachable(in: browser.spaceID)
        let name = count == 0 ? "Localhost" : "Localhost, \(count) local \(count == 1 ? "page" : "pages")"
        Door(icon: "network", help: browser.prefs.keyHelp(.localhost, name), box: box, glyph: glyph, count: count) { browser.localhostOpen.toggle() }
            .accessibilityLabel(name)
            .popover(isPresented: $browser.localhostOpen, arrowEdge: .trailing) {
                LocalhostHub(browser: browser, localhost: localhost)
            }
    }
}

/// A small square holding one symbol. Lit when what it opens is open.
struct Door: View {
    let icon: String
    var on = false
    var help = ""
    /// The square and its symbol, in compact points: a tool's by default.
    var box: CGFloat = 26
    var glyph: CGFloat = 11
    /// A number worn at the corner while it is above zero.
    var count = 0
    let act: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Image(systemName: icon)
                .font(.system(size: metrics.length(glyph), weight: .medium))
                .foregroundStyle(on ? Palette.ink : (hovering ? Palette.ink.opacity(0.7) : Palette.muted))
                .frame(width: metrics.length(box), height: metrics.length(box))
                .background(
                    RoundedRectangle(cornerRadius: metrics.length(8), style: .continuous)
                        .fill(on ? Palette.wash : (hovering ? Palette.hover : .clear))
                )
                .overlay(alignment: .bottomTrailing) {
                    if count > 0 { DoorMark { Text("\(count)").monospacedDigit() } }
                }
                .contentShape(RoundedRectangle(cornerRadius: metrics.length(8), style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: on)
    }
}
