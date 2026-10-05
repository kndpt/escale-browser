import SwiftUI

// Bookmarks in the column, above the tabs, the way Arc keeps them. Off unless
// asked for in Settings › Tabs & Spaces; the button at the column's foot stays either
// way, for adding a page and for the full list.
//
// A site is a row of a tab's size, 28 points with 2 between. A folder opens
// in place, its sites 14 points further in.
//
// A bookmark is a tab that has a place of its own, as in Arc: shut, it is
// only its address; opened with a click, it has a tab of its own, which is
// under the bookmark rather than among the tabs, and a second click comes
// back to it. A small dot says it is open; under the pointer the dot is a
// cross that shuts it. A tab dragged here becomes a bookmark the same way:
// it leaves the tabs and stays open, under the bookmark it now is, at the
// place it was let go. With nothing kept yet the section still stands, one
// quiet row inviting a tab. The other way, a bookmark dragged down among the
// tabs stops being one: its tab, or a new one when it was shut, joins the
// tabs where it is let go. A shut folder keeps its open bookmarks visible
// and hides only inactive sites; its dot signals that one is open. The whole
// section folds under its heading, whose chevron shows under the pointer;
// folded, the heading takes a dropped tab at the end of the bookmarks, and
// wears the dot when one of them is open.
//
// The tabs' own heading ends with Clear while the space has ordinary tabs:
// one press closes those, as ⌘W would (Browser.clearTabs). The pins, the
// bookmarks' tabs and the other spaces' tabs are not among them.
//
// That tab is still one of the browser's tabs, so everything a tab does —
// sleep, ⌘W, spaces — it does. The browser only remembers which bookmark it
// belongs to (Browser.shelfTabs); the column leaves it out of the tabs and
// the session leaves it out of tomorrow, when the bookmark is there, shut,
// in its place. A bookmark taken away gives its tab back to the tabs.
//
// A row is picked up the way a tab is, with the same gesture rather than the
// system's drag: a system drag carries text, and the column takes any text
// dropped on it as an address to open. A folder is carried with what is open
// under it. Nothing moves in the list until the row is let go — a line shows
// where it will land, or the folder it will go into lights up — so the list
// keeps its shape under the pointer while it is being aimed.
//
// Every piece has a fixed height, on purpose. The column works out where its
// rows stop by adding up what it drew (SideBar.rowsEnd) — the window's drag
// area under them is a real view, and it would take their clicks otherwise —
// so `Shelf.height` adds the shelf up the same way, from the same numbers,
// and `Shelf.drop` finds the row under the pointer with them too.
//
// Bookmarks are each space's own, as its pinned tabs are: a file per space
// beside its session, the first space's the file there always was, so with
// spaces off nothing changes. The button's list, the manager, ⇧⌘B, importing
// and extensions all see the space on screen's (Browser.bookmarks).
//
// Which folders are open is kept on the browser (Browser.shelfOpen), not in
// the view. The column is drawn twice, once plain and once scrolling, and
// ViewThatFits swaps one for the other as an opening folder makes the rows
// longer than the window: a folder open in one copy would be shut in the
// other the moment it took over.

struct Shelf: View {
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var browser: Browser
    @ObservedObject var bookmarks: Bookmarks
    var spaceHover: HoverDwell? = nil
    var spaceFrames: [UUID: CGRect] = [:]
    var activeFrame: Binding<CGRect>? = nil
    var spaceDrag: SpaceDrag? = nil
    @ObservedObject var mergeHover: HoverDwell

    @State private var dragging: Bookmark.ID?
    @State private var travel: CGFloat = 0
    @State private var landing: Drop?
    @State private var folderName = ""
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    /// The shelf's lengths at the interface size. A bookmark's row is a
    /// tab's row, to the point (SideBar.row, SideRow): the two lists read
    /// as one column, and a row dragged from one to the other keeps its size.
    struct Measure {
        let row: CGFloat
        let gap: CGFloat
        let heading: CGFloat
        let indent: CGFloat

        init(_ metrics: ChromeMetrics) {
            row = metrics.length(28)
            gap = metrics.length(2)
            heading = metrics.length(26)
            indent = metrics.length(14)
        }
    }

    private var measure: Measure { Measure(metrics) }

    /// One row as it is drawn: a site or a folder, the folder it is in, and
    /// how deep that is.
    struct Line {
        let node: Bookmark
        let parent: Bookmark.ID?
        let depth: Int
    }

    /// The tree as rows, top to bottom. A shut folder keeps the path to each
    /// open tab, while its inactive sites wait for expansion.
    static func lines(_ nodes: [Bookmark], open: Set<Bookmark.ID>, active: Set<Bookmark.ID> = [], parent: Bookmark.ID? = nil, depth: Int = 0) -> [Line] {
        nodes.flatMap { node -> [Line] in
            let line = Line(node: node, parent: parent, depth: depth)
            guard node.isFolder else { return [line] }
            let children = node.children ?? []
            if open.contains(node.id) {
                return [line] + lines(children, open: open, active: active, parent: node.id, depth: depth + 1)
            }
            return [line] + activeLines(children, active: active, parent: node.id, depth: depth + 1)
        }
    }

    /// A closed folder still shows each open page, with the folder path that
    /// explains where it lives. Shut bookmarks have no row until expanded.
    private static func activeLines(_ nodes: [Bookmark], active: Set<Bookmark.ID>, parent: Bookmark.ID?, depth: Int) -> [Line] {
        nodes.flatMap { node -> [Line] in
            let line = Line(node: node, parent: parent, depth: depth)
            if !node.isFolder { return active.contains(node.id) ? [line] : [] }
            let children = activeLines(node.children ?? [], active: active, parent: node.id, depth: depth + 1)
            return children.isEmpty ? [] : [line] + children
        }
    }

    static func activeIDs(_ browser: Browser) -> Set<Bookmark.ID> {
        Set(browser.tabs.filter { $0.pin == nil }.compactMap { browser.shelfTabs[$0.id] })
    }

    /// What the shelf takes of the column: its two headings and its rows,
    /// with a gap under each — one row when empty, the one inviting a tab.
    /// Folded, the two headings alone.
    static func height(for browser: Browser) -> CGFloat {
        let m = Measure(ChromeMetrics(size: browser.prefs.interfaceSize))
        let rows = browser.prefs.sideBookmarksFolded
            ? 0 : CGFloat(max(1, lines(browser.bookmarks.roots, open: browser.shelfOpen,
                                      active: activeIDs(browser)).count))
        return 2 * m.heading + rows * m.row + (rows + 1) * m.gap
    }

    /// Something under the tabs' heading for Clear to close, in the space this
    /// shelf belongs to.
    private var clearable: Bool { !browser.clearableTabs(in: bookmarks.space).isEmpty }

    /// Where the row or tab being held would land.
    private var aim: Drop? { landing ?? browser.shelfAim }

    var body: some View {
        let active = Shelf.activeIDs(browser)
        let lines = Shelf.lines(bookmarks.roots, open: browser.shelfOpen, active: active)
        let carried = Shelf.carried(dragging, in: lines)
        let folded = browser.prefs.sideBookmarksFolded
        VStack(alignment: .leading, spacing: measure.gap) {
            Top(folded: folded, lit: folded && aim != nil, holdsOpen: folded && Shelf.holds(any: active, bookmarks.roots)) {
                withAnimation(Motion.settle) { browser.prefs.sideBookmarksFolded.toggle() }
            }
            if !folded {
                if lines.isEmpty { Empty(lit: aim != nil) }
                ForEach(Array(lines.enumerated()), id: \.element.node.id) { index, line in
                    let held = carried.contains(index)
                    let tab = browser.shelfTab(for: line.node.id)
                    ShelfRow(browser: browser, node: line.node, depth: line.depth,
                             isOpen: browser.shelfOpen.contains(line.node.id),
                             target: aim?.into == line.node.id,
                             merging: mergeHover.target == line.node.id,
                             pulsing: mergeHover.pulsing && (dragging == line.node.id || mergeHover.target == line.node.id),
                             mergeReady: mergeHover.ready && mergeHover.target == line.node.id,
                             naming: browser.shelfNaming == line.node.id, folderName: $folderName,
                             finishName: finishNaming, rename: { startNaming(line.node) },
                             tab: tab, live: tab != nil && tab?.id == browser.activeID && !browser.tuning,
                             hides: line.node.isFolder && !browser.shelfOpen.contains(line.node.id)
                                && Shelf.holds(any: active, line.node.children ?? []))
                        .offset(y: held ? travel : 0)
                        // Under the hand exactly, as a tab is (see SideBar.loose).
                        .transaction { if held { $0.animation = nil } }
                        .zIndex(held ? 1 : 0)
                        .shadow(color: held && index == carried.lowerBound ? Palette.shadow : .clear, radius: 12, y: 4)
                        .gesture(pick(line, lines: lines), including: browser.shelfNaming == line.node.id ? .none : .all)
                        .modifier(PanelEntryFrame(id: line.node.id))
                        .transition(line.depth > 0 ? Motion.unfold(reduced: reduceMotion) : .opacity)
                }
            }
            // The tabs' own heading, so the two lists read as two.
            Heading(title: "Tabs", clear: clearable ? { withAnimation(Motion.settle) { browser.clearTabs() } } : nil)
                .overlay(alignment: .top) {
                    Rectangle().fill(Palette.hairline).frame(height: 1).padding(.horizontal, metrics.length(10))
                }
        }
        .overlay(alignment: .topLeading) { if !lines.isEmpty, !folded { mark(rows: lines.count) } }
        .coordinateSpace(name: "shelf")
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { activeFrame?.wrappedValue = proxy.frame(in: .global) }
                .onChange(of: proxy.frame(in: .global)) { _, frame in activeFrame?.wrappedValue = frame }
        })
        .onAppear { if let id = browser.shelfNaming { folderName = browser.bookmarks.find(id)?.title ?? "New Folder" } }
        .onChange(of: browser.shelfNaming) { _, id in
            if let id { folderName = browser.bookmarks.find(id)?.title ?? "New Folder" }
        }
    }

    /// The line between two rows where the one held will land — the
    /// bookmarks' rows, or the tabs' under them.
    @ViewBuilder
    private func mark(rows: Int) -> some View {
        if let landing = aim, landing.into == nil {
            let m = measure
            let slot = m.row + m.gap
            let y = landing.tabs.map { m.heading * 2 + m.gap + CGFloat(rows + $0) * slot - 1 }
                ?? m.heading + CGFloat(landing.line) * slot
            Capsule()
                .fill(Palette.muted)
                .frame(height: 2)
                .padding(.leading, metrics.length(10) + CGFloat(landing.depth) * m.indent)
                .padding(.trailing, metrics.length(10))
                // Across the gap above that row, which is the line's own height.
                .offset(y: y)
                .allowsHitTesting(false)
        }
    }

    private func pick(_ line: Line, lines: [Line]) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .onChanged { [browser] value in
                if dragging != line.node.id { dragging = line.node.id }
                spaceDrag?.begin(line.node.id, origin: bookmarks.space, title: line.node.title,
                                 symbol: line.node.isFolder ? "folder.fill" : "bookmark", at: value.location,
                                 move: { point in
                    if let tab = browser.shelfTab(for: line.node.id), browser.aimPanel(tab, at: point) { return }
                    guard browser.spaceID != bookmarks.space else { return }
                    spaceHover?.cancel()
                    let lines = Shelf.lines(browser.bookmarks.roots, open: browser.shelfOpen,
                                            active: Shelf.activeIDs(browser))
                    let y = point.y - (activeFrame?.wrappedValue.minY ?? 0)
                    let next = Shelf.drop(at: y, lines: lines, carrying: nil, measure: measure,
                                          carriedSite: !line.node.isFolder)
                    mergeHover.aim(source: line.node.id, at: next?.merge)
                    browser.shelfAim = next
                },
                                 release: { point in
                    finishPick(line, lines: lines, at: point)
                }, abort: { cancelPick() })
                travel = value.translation.height
                if let tab = browser.shelfTab(for: line.node.id), browser.aimPanel(tab, at: value.location) {
                    spaceHover?.cancel(); mergeHover.cancel(); landing = nil; browser.shelfAim = nil
                    return
                }
                let target = browser.prefs.usesSpaces ? spaceFrames.first {
                    $0.value.contains(value.location) && $0.key != browser.spaceID
                }?.key : nil
                spaceHover?.aim(source: line.node.id, at: target) { [weak browser] in
                    if let target { browser?.switchSpace(to: target, focus: false) }
                }
                if target != nil {
                    mergeHover.cancel()
                    landing = nil
                    browser.shelfAim = nil
                    return
                }
                let inDestination = browser.spaceID != bookmarks.space
                let currentLines = inDestination
                    ? Shelf.lines(browser.bookmarks.roots, open: browser.shelfOpen, active: Shelf.activeIDs(browser)) : lines
                let y = value.location.y - (activeFrame?.wrappedValue.minY ?? 0)
                let next = Shelf.drop(at: y, lines: currentLines,
                                      carrying: inDestination ? nil : line.node.id, measure: measure,
                                      carriedSite: inDestination && !line.node.isFolder)
                if next?.merge != landing?.merge { mergeHover.aim(source: line.node.id, at: next?.merge) }
                landing = next
                if inDestination { browser.shelfAim = next }
            }
            .onEnded { value in
                if let spaceDrag { spaceDrag.end(at: value.location) }
                else { finishPick(line, lines: lines, at: value.location) }
            }
    }

    private func finishPick(_ line: Line, lines: [Line], at point: CGPoint) {
        if browser.panels.cancelled { browser.panels.finish(); cancelPick(); return }
        if let tab = browser.shelfTab(for: line.node.id), browser.dropPanel(tab, at: point) { cancelPick(); return }
        if browser.panels.frame.contains(point) { cancelPick(); return }
        if browser.spaceID == bookmarks.space, spaceHover?.target == nil,
           let frame = activeFrame?.wrappedValue,
           point.x < frame.minX || point.x > frame.maxX { cancelPick(); return }
        let overDoor = spaceHover?.target.flatMap {
            spaceFrames[$0]?.contains(point) == true ? $0 : nil
        }
        let inDestination = browser.spaceID != bookmarks.space
        let currentLines = inDestination
            ? Shelf.lines(browser.bookmarks.roots, open: browser.shelfOpen, active: Shelf.activeIDs(browser)) : lines
        let y = point.y - (activeFrame?.wrappedValue.minY ?? 0)
        let drop = overDoor == nil
            ? Shelf.drop(at: y, lines: currentLines,
                         carrying: inDestination ? nil : line.node.id, measure: measure,
                         carriedSite: inDestination && !line.node.isFolder) : nil
        if inDestination {
            let merge = drop?.merge.map { mergeHover.accepts(source: line.node.id, target: $0) } ?? false
            if drop?.merge == nil || merge { browser.moveShelf(line.node, from: bookmarks, to: drop, merge: merge) }
        } else if overDoor == nil, let landing = drop {
            if let target = landing.merge {
                if mergeHover.accepts(source: line.node.id, target: target), self.landing?.merge == target,
                   let folder = withAnimation(Motion.settle, { bookmarks.merge(line.node.id, with: target) }) {
                    withAnimation(Motion.settle) { _ = browser.shelfOpen.insert(folder.id) }
                    startNaming(folder)
                }
            } else {
                browser.land(line.node, landing)
            }
        }
        cancelPick()
    }

    private func cancelPick() {
        browser.panels.finish()
        spaceHover?.cancel()
        mergeHover.cancel()
        browser.shelfAim = nil
        withAnimation(Motion.settle) {
            dragging = nil
            travel = 0
            landing = nil
        }
    }

    private func startNaming(_ folder: Bookmark) {
        folderName = folder.title
        browser.shelfNaming = folder.id
    }

    private func finishNaming() {
        guard let naming = browser.shelfNaming else { return }
        let title = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { bookmarks.update(naming, title: title, url: nil) }
        browser.shelfNaming = nil
    }

    // MARK: - where a row lands

    /// Where a row let go lands: in a folder (`parent`, nil for the top),
    /// just before one of its rows or at its end; and where to draw that.
    struct Drop: Equatable {
        var parent: Bookmark.ID?
        var before: Bookmark.ID?
        /// A folder the row goes into, lit rather than marked with a line.
        var into: Bookmark.ID?
        /// A site under a held bookmark; it becomes a folder only after the
        /// dwell finishes. Tabs never carry a bookmark ID into this branch.
        var merge: Bookmark.ID?
        /// The row the line is drawn above, and how far in.
        var line = 0
        var depth = 0
        /// Down among the tabs instead, before the one at this place.
        var tabs: Int?
    }

    /// `id` is somewhere in `nodes`, however deep.
    static func holds(_ id: Bookmark.ID, _ nodes: [Bookmark]) -> Bool {
        nodes.contains { $0.id == id || holds(id, $0.children ?? []) }
    }

    /// One of `ids` is somewhere in `nodes`, however deep.
    static func holds(any ids: Set<Bookmark.ID>, _ nodes: [Bookmark]) -> Bool {
        nodes.contains { ids.contains($0.id) || holds(any: ids, $0.children ?? []) }
    }

    /// The rows a held one takes along: itself, and what is open under it.
    static func carried(_ id: Bookmark.ID?, in lines: [Line]) -> Range<Int> {
        guard let id, let first = lines.firstIndex(where: { $0.node.id == id }) else { return 0..<0 }
        var end = first + 1
        while end < lines.count, lines[end].depth > lines[first].depth { end += 1 }
        return first..<end
    }

    /// The pointer at `y`, in the shelf's own space: the middle half of a
    /// folder is that folder; the middle of a site is a pending merge only
    /// when another bookmark is carried. Its edges reorder. Past the last row is the end of
    /// the list. Nil over the rows being carried, which can't go inside
    /// themselves.
    static func drop(at y: CGFloat, lines: [Line], carrying id: Bookmark.ID?, measure m: Measure,
                     carriedSite: Bool = false) -> Drop? {
        let (row, gap, heading) = (m.row, m.gap, m.heading)
        let slot = row + gap
        let span = carried(id, in: lines)
        let at = y - heading - gap
        // Past the tabs' heading is the tabs: a site dropped there leaves the
        // bookmarks, a folder has nowhere to go. The tabs' rows are a tab's
        // size, the same as a bookmark's (see SideBar.row).
        let tabsTop = heading + CGFloat(lines.count) * slot + heading + gap
        if y >= tabsTop {
            guard carriedSite || (id != nil && lines.contains { $0.node.id == id && !$0.node.isFolder }) else { return nil }
            return Drop(tabs: max(0, Int(((y - tabsTop) / slot).rounded())))
        }
        guard !lines.isEmpty else { return Drop() }
        if at >= CGFloat(lines.count) * slot {
            return Drop(parent: nil, before: nil, line: lines.count, depth: 0)
        }
        let index = max(0, Int(at / slot))
        guard !span.contains(index) else { return nil }
        let line = lines[index]
        let part = (at - CGFloat(index) * slot) / row
        if line.node.isFolder, part > 0.25, part < 0.75 {
            return Drop(parent: line.node.id, into: line.node.id, line: index, depth: line.depth + 1)
        }
        if carriedSite || (id != nil && lines.contains { $0.node.id == id && !$0.node.isFolder }),
           !line.node.isFolder, part > 0.25, part < 0.75 {
            return Drop(merge: line.node.id, line: index, depth: line.depth)
        }
        if part < 0.5 {
            return Drop(parent: line.parent, before: line.node.id, line: index, depth: line.depth)
        }
        // Below an open folder is the top of what is in it.
        if index + 1 < lines.count, lines[index + 1].parent == line.node.id {
            let first = lines[index + 1].node.id
            return first == id ? nil
                : Drop(parent: line.node.id, before: first, line: index + 1, depth: line.depth + 1)
        }
        let next = lines[(index + 1)...].first { $0.depth <= line.depth }
        let sibling = next?.parent == line.parent ? next?.node.id : nil
        // Just before itself is where it already is.
        if let sibling, sibling == id { return nil }
        return Drop(parent: line.parent, before: sibling, line: index + 1, depth: line.depth)
    }

    /// The one row of an empty shelf, lit while a tab is held over it.
    private struct Empty: View {
        let lit: Bool
        @SwiftUI.Environment(\.chromeMetrics) private var metrics

        var body: some View {
            HStack(spacing: metrics.length(8)) {
                Image(systemName: "bookmark")
                    .font(.system(size: metrics.length(10), weight: .regular))
                    .frame(width: metrics.length(15))
                Text("Drag a tab here")
                    .font(.system(size: metrics.length(12.5)))
                Spacer(minLength: 0)
            }
            // Muted like the section names: in faint it could not be read.
            .foregroundStyle(Palette.muted)
            .padding(.leading, metrics.length(10))
            .frame(height: Measure(metrics).row)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: metrics.length(9), style: .continuous)
                    .fill(lit ? Palette.wash : .clear)
            )
            .animation(Motion.quick, value: lit)
        }
    }

    /// The bookmarks' heading, which folds them: its chevron shows under the
    /// pointer, the dot while folded over an open bookmark.
    private struct Top: View {
        let folded: Bool
        let lit: Bool
        let holdsOpen: Bool
        let toggle: () -> Void

        @State private var hovering = false
        @SwiftUI.Environment(\.chromeMetrics) private var metrics

        var body: some View {
            // Set as the tabs' heading is, so the two read alike; what folds
            // it sits over its end.
            Text("Bookmarks")
                .font(.system(size: metrics.length(11), weight: .regular))
                .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : Palette.muted)
                .padding(.leading, metrics.length(10))
                .padding(.bottom, metrics.length(4))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .frame(height: Measure(metrics).heading)
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: metrics.length(8)) {
                        if holdsOpen {
                            Circle()
                                .fill(Palette.muted)
                                .frame(width: metrics.length(5), height: metrics.length(5))
                                .frame(width: metrics.length(15), height: metrics.length(15))
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: metrics.length(9), weight: .medium))
                            .foregroundStyle(Palette.faint)
                            .rotationEffect(.degrees(folded ? -90 : 0))
                            .frame(width: metrics.length(15), height: metrics.length(15))
                            .opacity(hovering ? 1 : 0)
                    }
                    .padding(.trailing, metrics.length(7))
                    .padding(.bottom, metrics.length(3))
                }
                .background(
                    RoundedRectangle(cornerRadius: metrics.length(9), style: .continuous)
                        .fill(lit ? Palette.wash : .clear)
                )
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)
                .onHover { hovering = $0 }
                .animation(Motion.quick, value: hovering)
                .animation(Motion.quick, value: lit)
        }
    }

    /// The tabs' heading. Clear, when there is something for it to close,
    /// stands at its end as a bin icon that opens onto its word under the
    /// pointer, set as the heading is (the bookmarks' chevron sits in the same
    /// place); it takes no height of its own. The bin is drawn only while the
    /// pointer is anywhere on the heading, or while the keyboard is on it, and
    /// its place is kept, so nothing moves when it comes. Hidden it takes no
    /// press, and VoiceOver still finds it.
    private struct Heading: View {
        let title: String
        var clear: (() -> Void)? = nil
        @State private var hovering = false
        @State private var onHeading = false
        @FocusState private var focused: Bool
        @SwiftUI.Environment(\.chromeMetrics) private var metrics

        private var shown: Bool { onHeading || hovering || focused }

        var body: some View {
            Text(title)
                .font(.system(size: metrics.length(11), weight: .regular))
                .foregroundStyle(Palette.muted)
                .padding(.leading, metrics.length(10))
                .padding(.bottom, metrics.length(4))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .frame(height: Shelf.Measure(metrics).heading)
                .overlay(alignment: .bottomTrailing) {
                    if let clear {
                        Button(action: clear) {
                            // A bin at rest, in the place of a tab's cross so the two
                            // line up; the pointer opens it, leftwards, onto its word.
                            HStack(spacing: metrics.length(3)) {
                                if hovering {
                                    Text("Clear")
                                        .font(.system(size: metrics.length(11), weight: .regular))
                                        .fixedSize()
                                        .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .trailing)))
                                }
                                Image(systemName: "trash")
                                    .font(.system(size: metrics.length(11), weight: .regular))
                                    .frame(width: metrics.length(15), height: metrics.length(15))
                            }
                            .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : Palette.muted)
                            .padding(.horizontal, metrics.length(3))
                            .frame(minHeight: metrics.length(20))
                            .background(RoundedRectangle(cornerRadius: metrics.length(6), style: .continuous)
                                .fill(hovering ? Palette.hover : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focused($focused)
                        .onHover { hovering = $0 }
                        .animation(Motion.settle, value: hovering)
                        .help("Close every tab in this list. Pins, bookmarks and other Spaces stay.")
                        .accessibilityLabel("Clear Tabs")
                        // 4 + the 3 inside: the icon's centre is a tab cross's.
                        .padding(.trailing, metrics.length(4))
                        .padding(.bottom, metrics.length(1))
                        .opacity(shown ? 1 : 0)
                        .transition(.opacity)
                    }
                }
                .contentShape(Rectangle())
                .onHover { onHeading = $0 }
                .animation(Motion.quick, value: shown)
        }
    }
}

/// One bookmark, as a line in the column.
private struct ShelfRow: View {
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var browser: Browser
    let node: Bookmark
    let depth: Int
    let isOpen: Bool
    /// A row being carried will go into this folder if let go now.
    let target: Bool
    let merging: Bool
    let pulsing: Bool
    let mergeReady: Bool
    let naming: Bool
    @Binding var folderName: String
    let finishName: () -> Void
    let rename: () -> Void
    /// The bookmark's own tab, while it is open; `live` while it is on screen.
    let tab: Tab?
    let live: Bool
    /// A shut folder with an open bookmark somewhere in it.
    let hides: Bool

    @State private var hovering = false
    @FocusState private var nameFocused: Bool
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.length(8)) {
            if node.isFolder {
                Image(systemName: "folder.fill")
                    .font(.system(size: metrics.length(Metrics.navigationSymbol)))
                    .foregroundStyle(Palette.muted)
                    .frame(width: metrics.length(Metrics.navigationIcon), height: metrics.length(Metrics.navigationIcon))
            } else {
                SiteMark(host: node.host ?? "",
                     letter: String((node.host ?? "•").prefix(1)).uppercased(), size: metrics.length(Metrics.navigationIcon))
            }
            if naming {
                TextField(node.isFolder ? "Folder name" : "Bookmark name", text: $folderName)
                    .font(.system(size: metrics.length(12.5)))
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .onSubmit(finishName)
                    .onAppear { DispatchQueue.main.async { nameFocused = true } }
                    .onChange(of: nameFocused) { _, focused in if !focused { finishName() } }
            } else {
                Text(node.title)
                    .font(.system(size: metrics.length(12.5)))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(live ? Palette.ink : (hovering ? Palette.ink.opacity(0.7) : Palette.muted))
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .clipped()
            }
            if mergeReady {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: metrics.length(11)))
                    .foregroundStyle(Palette.muted)
                    .transition(.opacity)
            }
            if !node.destinations.isEmpty {
                if let tab {
                    OpenEnvironmentPicker(node: node, tab: tab, compact: compactEnvironment) {
                        browser.openEnvironment($0, bookmark: node.id, space: browser.spaceID)
                    }
                } else {
                    EnvironmentPicker(node: node, compact: compactEnvironment) {
                        browser.openEnvironment($0, bookmark: node.id, space: browser.spaceID)
                    }
                }
            }
            if let tab {
                dot(tab)
            }
            if hides {
                Circle()
                    .fill(Palette.muted)
                    .frame(width: metrics.length(5), height: metrics.length(5))
                    .frame(width: metrics.length(15), height: metrics.length(15))
            }
            if node.isFolder {
                Image(systemName: "chevron.down")
                    .font(.system(size: metrics.length(9), weight: .medium))
                    .foregroundStyle(Palette.faint)
                    .rotationEffect(.degrees(isOpen ? 0 : -90))
                    .frame(width: metrics.length(15), height: metrics.length(15))
            }
        }
        .padding(.leading, metrics.length(10) + CGFloat(depth) * measure.indent)
        .padding(.trailing, metrics.length(7))
        .frame(height: measure.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            if hovering, !naming, let tab { RowCopy(browser: browser, tab: tab).transition(.opacity) }
        }
        // The open bookmark's page on screen is chosen like any tab; a row
        // a drag would land on is only marked.
        .background {
            if live {
                Chosen(radius: metrics.length(9))
            } else {
                RoundedRectangle(cornerRadius: metrics.length(9), style: .continuous)
                    .fill(target || merging ? Palette.wash : (hovering ? Palette.hover : .clear))
            }
        }
        .scaleEffect(pulsing ? 1.035 : 1)
        .contentShape(RoundedRectangle(cornerRadius: metrics.length(9), style: .continuous))
        .onTapGesture { if !naming { press() } }
        .onHover { hovering = $0 }
        .contextMenu {
            if let tab {
                Button { browser.close(tab) } label: { Label("Close Tab", systemImage: "xmark") }
                Divider()
            }
            if !node.isFolder {
                Button { browser.pinBookmark(node) } label: { Label("Pin as Tab", systemImage: "pin") }
                LinkRouteMenu(browser: browser, address: node.url.flatMap(URL.init(string:)), space: browser.bookmarks.space)
                Button { browser.editEnvironments(node, in: browser.bookmarks) } label: {
                    Label("Associate Environments…", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
            Button { browser.bookmarking = true } label: { Label("Manage Bookmarks…", systemImage: "bookmark") }
            Button(action: rename) { Label("Rename", systemImage: "pencil") }
            Divider()
            Button(role: .destructive) { browser.bookmarks.remove(node.id) } label: { Label("Remove", systemImage: "trash") }
        }
        .modifier(SleepHint(tab: tab, ordinary: node.destinations.isEmpty ? (node.url ?? node.title) : "Choose an environment", label: node.title))
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: target)
        .animation(Motion.quick, value: merging)
        .animation(Motion.quick, value: mergeReady)
        .animation(Motion.bookmarkPulse, value: pulsing)
    }

    private var measure: Shelf.Measure { Shelf.Measure(metrics) }

    // Keep the actions within a narrow, indented row. The same menu remains
    // available through its symbol, help and accessible environment name.
    private var compactEnvironment: Bool {
        metrics.sidebarWidth(browser.prefs.sideWidth) - CGFloat(depth) * measure.indent
            < metrics.length(Metrics.environmentCompactWidth)
    }

    private func press() {
        if node.isFolder {
            withAnimation(reduceMotion ? nil : Motion.settle) {
                if isOpen { browser.shelfOpen.remove(node.id) } else { browser.shelfOpen.insert(node.id) }
            }
        } else {
            browser.openShelf(node)
        }
    }

    /// The dot of an open bookmark, a cross under the pointer that shuts it.
    private func dot(_ tab: Tab) -> some View {
        BookmarkSleepMark(tab: tab, hovering: hovering, rowHeight: measure.row, travel: Metrics.sleepPastCopy, reserved: Metrics.rowCopySlot) {
            if hovering { browser.close(tab) } else { press() }
        }
    }

}

extension Browser {
    /// A saved row follows its drag to the visible Space. Open pages in the
    /// carried subtree follow through the normal tab transfer, so their new
    /// WebKit store and bookmark association agree with the destination.
    func moveShelf(_ node: Bookmark, from source: Bookmarks, to drop: Shelf.Drop?, merge: Bool) {
        guard spaceID != source.space else { return }
        let destination = bookmarks
        let linked = (tabs + parkedTabs).compactMap { tab -> (Tab, Bookmark.ID)? in
            guard let id = shelfTabs[tab.id], Shelf.holds(id, [node]), tab.space == source.space else { return nil }
            return (tab, id)
        }
        // The tree must stay at its source if a linked page cannot follow it.
        guard linked.allSatisfy({ tab, _ in
            guard !tab.bench else { return false }
            guard let url = tab.address, url.scheme == "chrome-extension" else { return true }
            return Browser.extensionConfiguration(for: url, space: spaceID) != nil
        }) else { return }
        let parent = merge ? nil : drop?.parent
        let before = merge ? nil : drop?.before
        guard source.move(node.id, to: destination, into: parent, before: before) != nil else { return }
        if let folder = drop?.into { withAnimation(Motion.settle) { _ = shelfOpen.insert(folder) } }
        for (tab, id) in linked {
            if let moved = transfer(tab, to: spaceID) { shelfTabs[moved.id] = id }
        }
        if merge, let target = drop?.merge,
           let folder = destination.merge(node.id, with: target) {
            withAnimation(Motion.settle) { _ = shelfOpen.insert(folder.id) }
            shelfNaming = folder.id
        } else if let drop, drop.tabs != nil {
            land(node, drop)
        }
    }

    /// A tab held `y` points down the column's rows, negative above them
    /// (see SideBar.reorder). Over the bookmarks it is aimed at them, and
    /// this says so; anywhere else it is aimed at nothing here.
    func aimShelf(at y: CGFloat) -> Bool {
        let lines = Shelf.lines(bookmarks.roots, open: shelfOpen, active: Shelf.activeIDs(self))
        let m = Shelf.Measure(ChromeMetrics(size: prefs.interfaceSize))
        // The shelf sits right above the rows, so its bottom is their top.
        let at = Shelf.height(for: self) + y
        let folded = prefs.sideBookmarksFolded
        let bottom = m.heading + (folded ? 0 : CGFloat(max(1, lines.count)) * (m.row + m.gap))
        guard prefs.sideBookmarks, at < bottom else {
            if shelfAim != nil { shelfAim = nil }
            return false
        }
        // Folded, the heading takes it at the end of the bookmarks.
        let aim = folded ? Shelf.Drop() : Shelf.drop(at: at, lines: lines, carrying: nil, measure: m)
        if shelfAim != aim { shelfAim = aim }
        return true
    }

    /// The tab let go: if it was aimed here, a bookmark where it was aimed,
    /// and that bookmark's own tab from now on. A new bookmark every time,
    /// even for an address kept already: each tab has a row of its own to
    /// be found under, never one it would share and be lost behind.
    func dropOnShelf(_ tab: Tab) {
        guard let aim = shelfAim else { return }
        shelfAim = nil
        guard let url = tab.address else { return }
        let node = bookmarks.insert(.site(tab.title, url), into: aim.parent)
        bookmarks.move(node.id, into: aim.parent, before: aim.before)
        shelfTabs[tab.id] = node.id
        if let folder = aim.into { withAnimation(Motion.settle) { _ = shelfOpen.insert(folder) } }
    }

    /// A bookmark let go where it was aimed: somewhere else among the
    /// bookmarks, or down among the tabs, where it stops being one.
    func land(_ node: Bookmark, _ drop: Shelf.Drop) {
        guard drop.merge == nil else { return }
        guard let place = drop.tabs else {
            bookmarks.move(node.id, into: drop.parent, before: drop.before)
            if let folder = drop.into { withAnimation(Motion.settle) { _ = shelfOpen.insert(folder) } }
            return
        }
        // The tabs as the column shows them, before this one joins them.
        let loose = tabs.filter { $0.pin == nil && !onShelf($0) }
        let tab: Tab
        if let open = shelfTab(for: node.id) {
            tab = open
        } else if let url = node.url.flatMap(URL.init(string:)) {
            tab = open(url, foreground: true)
        } else {
            return
        }
        shelfTabs[tab.id] = nil
        bookmarks.remove(node.id)
        // Before the tab at that place, or after the last; `move` wants the
        // index the tab ends up at, counted with the tab still where it is.
        guard let here = tabs.firstIndex(where: { $0.id == tab.id }), let last = loose.last,
              let anchor = tabs.firstIndex(where: { $0.id == (place < loose.count ? loose[place] : last).id })
        else { return }
        let after = place >= loose.count
        move(tab, to: here < anchor ? (after ? anchor : anchor - 1) : (after ? anchor + 1 : anchor))
    }

    /// The space on screen's bookmarks.
    var bookmarks: Bookmarks { bookmarks(of: spaceID) }

    /// A space's bookmarks, read from its file the first time they are
    /// asked for; their changes redraw the window as the history's do.
    func bookmarks(of space: UUID) -> Bookmarks {
        if let kept = shelves[space] { return kept.list }
        let list = Bookmarks(space: space)
        let watch = list.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        shelves[space] = (list, watch)
        return list
    }

    /// A bookmark's own tab, in the space on screen, while it is open.
    func shelfTab(for id: Bookmark.ID) -> Tab? {
        tabs.first { shelfTabs[$0.id] == id && onShelf($0) }
    }

    /// A tab that is a bookmark's own, and so shown under it rather than
    /// among the tabs — while the bookmarks are in the column, that bookmark
    /// is still kept, and the tab hasn't been pinned. Anywhere else it is
    /// drawn as a tab, and so it is saved as one.
    /// `space` is the tab's, for a space not on screen.
    func onShelf(_ tab: Tab, in space: UUID? = nil) -> Bool {
        guard prefs.sidebar, prefs.sideBookmarks, tab.pin == nil, let id = shelfTabs[tab.id] else { return false }
        return Shelf.holds(id, bookmarks(of: space ?? spaceID).roots)
    }

    /// A click on a bookmark: back to its tab, or into a new one of its own.
    func openShelf(_ node: Bookmark) {
        if let tab = shelfTab(for: node.id) {
            select(tab)
            return
        }
        guard let url = node.url.flatMap(URL.init(string:)) else { return }
        // A tab it had before, since pinned, stays pinned: this one is its tab now.
        shelfTabs = shelfTabs.filter { $0.value != node.id }
        let tab = open(url, foreground: true)
        shelfTabs[tab.id] = node.id
    }

    /// A saved site can become a pinned tab without losing the bookmark or
    /// its environments. Reuse its open page, or an existing pin for the same
    /// address, so repeating the action does not create another copy.
    func pinBookmark(_ node: Bookmark) {
        guard let url = node.url.flatMap(URL.init(string:)) else { return }
        if let pinned = tabs.first(where: { $0.pin != nil && $0.address == url }) {
            select(pinned)
            return
        }
        if let open = tabs.first(where: { shelfTabs[$0.id] == node.id && $0.pin == nil }) {
            pin(open)
            select(open)
            return
        }
        let tab = open(url, foreground: true)
        shelfTabs[tab.id] = node.id
        pin(tab)
    }

    /// Where the `index`th of the tabs shown in the column sits in `tabs`,
    /// with the pinned ones before them and bookmarks' own among them.
    func place(of index: Int, among loose: [Tab]) -> Int {
        guard loose.indices.contains(index), let at = tabs.firstIndex(where: { $0.id == loose[index].id })
        else { return pinnedCount + index }
        return at
    }
}

extension Shelf {
    /// `./bench shelf`: the rows as drawn, after filling the list with a few
    /// sites and a folder (`seed`, test runs only), keeping the active tab
    /// there (`keep`, test runs only), opening or shutting a folder by its
    /// title, or letting a row go at a height in the shelf
    /// (`drop`, the same reckoning as a drag's).
    static func bench(_ request: [String: Any], browser: Browser) -> [String: Any] {
        if request["keep"] as? Bool == true {
            guard Store.testing, browser.prefs.sidebar, browser.prefs.sideBookmarks, let tab = browser.active
            else { return ["error": "shelf keep needs an active test tab and visible shelf"] }
            // Reuse the drop's production action without a coordinate-dependent drag.
            browser.shelfAim = Shelf.Drop()
            browser.dropOnShelf(tab)
        }
        if request["clear"] as? Bool == true {
            guard Store.testing else { return ["error": "shelf clear only works on a --test run"] }
            browser.clearTabs()
        }
        // "many": N synthetic sites, `siteK.localhost`, for measuring a long shelf.
        if let many = request["many"] as? Int, many > 0 {
            guard Store.testing else { return ["error": "shelf many only works on a --test run"] }
            browser.bookmarks.take((0..<many).map {
                Bookmark(title: "Site \($0)", url: "http://site\($0).localhost/", children: nil)
            }, from: "Bench")
        }
        if request["seed"] as? Bool == true {
            guard Store.testing else { return ["error": "shelf seed only works on a --test run"] }
            func site(_ title: String, _ address: String) -> Bookmark {
                Bookmark(title: title, url: address, children: nil)
            }
            browser.bookmarks.take([
                site("WebKit", "https://webkit.org/"),
                site("Swift", "https://www.swift.org/"),
                .folder("Reading", [
                    site("Example", "https://example.com/"),
                    .folder("Deeper", [site("Apple", "https://www.apple.com/")]),
                ]),
            ], from: "Bench")
        }
        let folders = Bookmarks.folders(browser.bookmarks.roots).map(\.node)
        if let title = request["open"] as? String, let folder = folders.first(where: { $0.title == title }) {
            withAnimation(Motion.settle) { _ = browser.shelfOpen.insert(folder.id) }
        }
        if let title = request["close"] as? String, let folder = folders.first(where: { $0.title == title }) {
            withAnimation(Motion.settle) { _ = browser.shelfOpen.remove(folder.id) }
        }
        if let fold = request["fold"] as? Bool { browser.prefs.sideBookmarksFolded = fold }
        var landed: [String: Any] = [:]
        if let title = request["drop"] as? String, let y = request["y"] as? Double {
            guard Store.testing else { return ["error": "shelf drop only works on a --test run"] }
            let before = lines(browser.bookmarks.roots, open: browser.shelfOpen)
            guard let line = before.first(where: { $0.node.title == title }) else { return ["error": "no row called \(title)"] }
            let measure = Measure(ChromeMetrics(size: browser.prefs.interfaceSize))
            if let drop = drop(at: y, lines: before, carrying: line.node.id, measure: measure) {
                browser.land(line.node, drop)
                landed = ["line": drop.line, "depth": drop.depth, "into": drop.into != nil,
                          "pendingMerge": drop.merge != nil, "tabs": drop.tabs ?? -1]
            } else {
                landed = ["nowhere": true]
            }
        }
        let rows = lines(browser.bookmarks.roots, open: browser.shelfOpen, active: activeIDs(browser)).map { line -> [String: Any] in
            ["title": line.node.title, "depth": line.depth, "folder": line.node.isFolder,
             "open": browser.shelfOpen.contains(line.node.id),
             "tab": browser.shelfTab(for: line.node.id) != nil,
             "live": browser.shelfTab(for: line.node.id)?.id == browser.activeID]
        }
        return ["on": browser.prefs.sideBookmarks, "folded": browser.prefs.sideBookmarksFolded, "clearable": browser.clearableTabs().count, "rows": rows, "height": Double(height(for: browser)), "landed": landed]
    }
}
