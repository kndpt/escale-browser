// The same page stages stay keyed by tab identity while their frames change.
// A composition is drawn as the pages themselves: each keeps the rounded
// frame a single page has and the envelope shows between them. The address
// bar and the sidebar already name the pages, so the only chrome is a small
// capsule that appears when the pointer nears a page's top edge. Three panels keep
// comparison useful without making a mosaic. Below the minimum page
// dimensions the canvas scrolls rather than silently shrinking its pages.
import SwiftUI

struct PanelStage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var panels: Panels
    let corner: CGFloat
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var resizing: [Double]?
    @State private var focus: Any?
    @State private var grip: Int?

    var body: some View {
        GeometryReader { area in
            let group = panels.group(browser.activeID)
            let tabs = browser.panelTabs
            let horizontal = group?.horizontal ?? true
            let count = max(tabs.count, 1)
            let gap = group == nil ? 0 : metrics.pageInset
            let minimum = metrics.length(horizontal ? Metrics.panelWidth : Metrics.panelHeight)
            let available = horizontal ? area.size.width : area.size.height
            let length = group == nil ? available : max(available, CGFloat(count) * minimum + CGFloat(count - 1) * gap)
            let content = max(0, length - CGFloat(count - 1) * gap)
            let weights = group?.weights ?? [1]
            let sizes = weights.map { group == nil ? content : minimum + max(0, content - CGFloat(count) * minimum) * $0 }
            ScrollViewReader { scroll in
                ScrollView(horizontal ? .horizontal : .vertical) {
                    ZStack(alignment: .topLeading) {
                        let layout = horizontal ? AnyLayout(HStackLayout(spacing: gap))
                                                : AnyLayout(VStackLayout(spacing: gap))
                        layout {
                            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                                PanelPage(browser: browser, tab: tab, corner: corner)
                                    .simultaneousGesture(TapGesture().onEnded {
                                        if browser.activeID != tab.id { browser.select(tab) }
                                    })
                                    .frame(width: horizontal ? sizes[index] : area.size.width,
                                           height: horizontal ? area.size.height : sizes[index])
                                    .overlay {
                                        // Which page the keyboard and the address bar speak to,
                                        // traced in the envelope just outside it so it stays
                                        // visible against a white page.
                                        if group != nil {
                                            let ring = metrics.length(Metrics.panelRing)
                                            RoundedRectangle(cornerRadius: corner + ring, style: .continuous)
                                                .strokeBorder(Palette.ink.opacity(browser.activeID == tab.id ? 0.5 : 0), lineWidth: ring)
                                                .padding(-ring - metrics.length(1))
                                                .shortcutAnimation(Motion.quick, value: browser.activeID, enabled: browser.prefs.fasterShortcuts, reduced: reduceMotion)
                                                .allowsHitTesting(false)
                                        }
                                    }
                                    .overlay(alignment: .top) {
                                        if let group { PanelTools(browser: browser, panels: panels, tab: tab, group: group) }
                                    }
                                    .id(tab.id)
                            }
                        }
                        if let group {
                            ForEach(0..<max(0, count - 1), id: \.self) { index in
                                let offset = sizes.prefix(index + 1).reduce(0, +) + CGFloat(index) * gap
                                divider(group, index: index, horizontal: horizontal, content: content,
                                        minimum: minimum, count: count, across: horizontal ? area.size.height : area.size.width)
                                    .frame(width: horizontal ? gap : area.size.width,
                                           height: horizontal ? area.size.height : gap)
                                    .offset(x: horizontal ? offset : 0, y: horizontal ? 0 : offset)
                            }
                        }
                        if browser.finding, let index = tabs.firstIndex(where: { $0.id == browser.activeID }) {
                            let offset = sizes.prefix(index).reduce(0, +) + CGFloat(index) * gap
                            FindBar(browser: browser, find: browser.find)
                                .frame(width: horizontal ? sizes[index] : area.size.width,
                                       height: horizontal ? area.size.height : sizes[index], alignment: .topTrailing)
                                .offset(x: horizontal ? offset : 0, y: horizontal ? 0 : offset)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .frame(width: horizontal ? length : area.size.width,
                           height: horizontal ? area.size.height : length, alignment: .topLeading)
                }
                .scrollDisabled(group == nil)
                // The focus ring lies in the envelope around the pages; only a
                // canvas that has to scroll clips it, so no page crosses the chrome.
                .scrollClipDisabled(length <= available + 0.5)
                .overlay { PanelLanding(browser: browser, panels: panels, corner: corner, size: area.size) }
                .onAppear { panels.frame = area.frame(in: .global) }
                .onChange(of: area.frame(in: .global)) { _, frame in panels.frame = frame }
                .onChange(of: browser.activeID) { _, id in
                    if let id { scroll.scrollTo(id) }
                }
                .onChange(of: area.size) { _, _ in
                    if let id = browser.activeID { scroll.scrollTo(id) }
                }
                .onChange(of: group?.members) { _, _ in
                    if let id = browser.activeID { scroll.scrollTo(id) }
                }
                .onChange(of: group?.horizontal) { _, _ in
                    if let id = browser.activeID { scroll.scrollTo(id) }
                }
            }
        }
        .onAppear { watchFocus() }
        .onChange(of: panels.group(browser.activeID)?.id) { _, _ in watchFocus() }
        .onChange(of: browser.tuning) { _, _ in watchFocus() }
        .onChange(of: browser.welcoming) { _, _ in watchFocus() }
        .onDisappear { panels.frame = .zero; panels.finish(); stopFocus() }
        .transaction { if reduceMotion { $0.animation = nil } }
    }

    /// The envelope between two pages. Its grip shows only under the pointer
    /// or while it is held, so a resting composition has no extra lines.
    private func divider(_ group: PanelGroup, index: Int, horizontal: Bool, content: CGFloat,
                         minimum: CGFloat, count: Int, across: CGFloat) -> some View {
        let long = metrics.length(Metrics.panelGrip)
        let thin = metrics.length(Metrics.panelGripWidth)
        return ZStack {
            Capsule(style: .continuous)
                .fill(Palette.muted)
                .frame(width: horizontal ? thin : min(long, across), height: horizontal ? min(long, across) : thin)
                .opacity(grip == index || resizing != nil && grip == index ? 1 : 0)
                .scaleEffect(grip == index ? 1 : 0.6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : Motion.quick, value: grip)
        .onHover { inside in
            if inside { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() }
            else { NSCursor.pop() }
            if resizing == nil { grip = inside ? index : nil }
        }
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            if resizing == nil { resizing = group.weights; grip = index }
            guard var next = resizing else { return }
            let free = content - CGFloat(count) * minimum
            guard free > 0 else { return }
            let movement = (horizontal ? value.translation.width : value.translation.height) / free
            let delta = min(max(movement, -next[index] + 0.001), next[index + 1] - 0.001)
            next[index] += delta
            next[index + 1] -= delta
            panels.resize(group.id, weights: next)
        }.onEnded { _ in resizing = nil; grip = nil; browser.rememberSession() })
        .accessibilityLabel("Resize panels")
        .accessibilityAdjustableAction { direction in
            var next = group.weights
            let delta = direction == .increment ? 0.05 : -0.05
            next[index] = max(0.01, next[index] + delta)
            next[index + 1] = max(0.01, next[index + 1] - delta)
            panels.resize(group.id, weights: next)
            browser.rememberSession()
        }
    }

    private func stopFocus() {
        if let focus { NSEvent.removeMonitor(focus) }
        focus = nil
        panels.focusWatching = false
    }

    private func watchFocus() {
        stopFocus()
        guard !browser.tuning, !browser.welcoming, panels.group(browser.activeID) != nil else { return }
        // WKContentView, inside WKWebView, can receive the click itself. Select
        // before dispatch without consuming the original event or its focus.
        focus = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            guard !browser.tuning, event.window === Links.window,
                  let root = event.window?.contentView?.superview,
                  let hit = root.hitTest(root.convert(event.locationInWindow, from: nil)) else { return event }
            for tab in browser.panelTabs {
                guard let page = tab.built, hit === page || hit.isDescendant(of: page) else { continue }
                if browser.activeID != tab.id { browser.select(tab) }
                break
            }
            return event
        }
        panels.focusWatching = focus != nil
    }
}

/// The capsule over one page of a composition. Every action in it is about
/// that page alone: it trades places with its neighbour, leaves the split as
/// an ordinary tab, or closes. Turning the composition is the one shared act.
private struct PanelTools: View {
    @ObservedObject var browser: Browser
    @ObservedObject var panels: Panels
    let tab: Tab
    let group: PanelGroup
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var near = false

    var body: some View {
        ZStack(alignment: .top) {
            HoverBand { near = $0 }
                .frame(maxWidth: .infinity)
                .frame(height: metrics.length(Metrics.panelHoverBand))
            if near || panels.toolsShown == tab.id, !browser.tuning {
                capsule
                    .padding(.top, metrics.length(Metrics.panelToolsInset))
                    .transition(.opacity.combined(with: .offset(y: -metrics.length(4))))
            }
        }
        .animation(reduceMotion ? nil : Motion.quick, value: near)
    }

    private var capsule: some View {
        let last = group.members.last == tab.id
        return HStack(spacing: 0) {
            tool(group.horizontal ? "arrow.left.arrow.right" : "arrow.up.arrow.down", "Swap with the next panel") {
                browser.changePanels(tab) { $0.move(tab.id, by: last ? -1 : 1) }
            }
            tool(group.horizontal ? "rectangle.split.1x2" : "rectangle.split.2x1", "Change orientation") {
                browser.changePanels(tab) { $0.turn(tab.id) }
            }
            tool("rectangle.portrait.and.arrow.right", "Move out of split") {
                browser.changePanels(tab) { $0.remove(tab.id) }
            }
            tool("xmark", "Close this page") { browser.close(tab) }
        }
        .padding(.horizontal, metrics.length(3))
        .padding(.vertical, metrics.length(2))
        .glass(.chip, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Panel \(tab.label)")
    }

    private func tool(_ symbol: String, _ help: String, _ act: @escaping () -> Void) -> some View {
        PanelTool(symbol: symbol) { withAnimation(reduceMotion ? nil : Motion.settle) { act() } }
            .help(help)
            .accessibilityLabel(help)
    }
}

private struct PanelTool: View {
    let symbol: String
    let act: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Image(systemName: symbol)
                .font(.system(size: metrics.length(Metrics.panelToolSymbol), weight: .medium))
                .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                .frame(width: metrics.length(Metrics.panelTool), height: metrics.length(Metrics.panelTool))
                .background(Circle().fill(hovering ? Palette.hover : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Motion.quick, value: hovering)
    }
}

/// Tells when the pointer is over a strip of the page without taking a
/// single event from it. A tracking area reports by geometry, so a view that
/// refuses every hit still hears the pointer while WebKit keeps the clicks.
private struct HoverBand: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> Band { Band(changed) }
    func updateNSView(_ view: Band, context: Context) { view.changed = changed }

    final class Band: NSView {
        var changed: (Bool) -> Void
        init(_ changed: @escaping (Bool) -> Void) {
            self.changed = changed
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
        override func mouseEntered(with event: NSEvent) { changed(true) }
        override func mouseExited(with event: NSEvent) { changed(false) }
    }
}

/// Where the carried tab will land, drawn at the size it will have. It
/// slides between edges instead of redrawing, and the pages under it are not
/// resized until the drop: reflowing live sites on every hover would cost
/// layout work in each page for a preview.
private struct PanelLanding: View {
    @ObservedObject var browser: Browser
    @ObservedObject var panels: Panels
    let corner: CGFloat
    let size: CGSize
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let (tab, slot) = landing {
                PanelSlot(tab: tab, corner: corner)
                    .frame(width: slot.width, height: slot.height)
                    .position(x: slot.midX, y: slot.midY)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(reduceMotion ? nil : Motion.settle, value: panels.preview)
        .allowsHitTesting(false)
    }

    private var landing: (Tab, CGRect)? {
        guard let edge = panels.preview, let tab = panels.lift.tab,
              let target = browser.panelPartner(for: tab),
              let members = panels.plan(tab.id, beside: target.id, edge: edge),
              let index = members.firstIndex(of: tab.id) else { return nil }
        let count = CGFloat(members.count)
        let gap = metrics.pageInset
        let offset = CGFloat(index)
        if edge.horizontal {
            let width = (size.width - gap * (count - 1)) / count
            return (tab, CGRect(x: offset * (width + gap), y: 0, width: width, height: size.height))
        }
        let height = (size.height - gap * (count - 1)) / count
        return (tab, CGRect(x: 0, y: offset * (height + gap), width: size.width, height: height))
    }
}

private struct PanelSlot: View {
    @ObservedObject var tab: Tab
    let corner: CGFloat
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        VStack(spacing: metrics.length(8)) {
            Mark(icon: tab.icon, letter: tab.monogram, size: metrics.length(Metrics.panelSlotIcon))
            Text(tab.label)
                .font(.system(size: metrics.length(12.5), weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, metrics.length(16))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Unlifted, so the slot reads as a place on the page, not a card over it.
        .glass(.chip, in: RoundedRectangle(cornerRadius: corner, style: .continuous), lifted: false)
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Palette.ink.opacity(0.35), lineWidth: metrics.length(Metrics.panelRing))
        }
    }
}

/// The carried tab under the pointer while it crosses the pages, in every
/// tab layout. It observes only the pointer, never the stage.
struct PanelGhost: View {
    @ObservedObject var lift: PanelLift
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0

    var body: some View {
        GeometryReader { area in
            let origin = area.frame(in: .global).origin
            if let point = lift.point, let tab = lift.tab {
                // Centred on the pointer, but kept whole inside the window.
                let half = width / 2 + metrics.pageInset
                PanelGhostFace(tab: tab)
                    .fixedSize()
                    .background(GeometryReader { face in
                        Color.clear.onAppear { width = face.size.width }
                            .onChange(of: face.size.width) { _, next in width = next }
                    })
                    .position(x: min(max(point.x - origin.x, half), max(half, area.size.width - half)),
                              y: point.y - origin.y)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(reduceMotion ? nil : Motion.quick, value: lift.point == nil)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PanelGhostFace: View {
    @ObservedObject var tab: Tab
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.length(8)) {
            Mark(icon: tab.icon, letter: tab.monogram, size: metrics.length(Metrics.navigationIcon))
            Text(tab.label)
                .font(.system(size: metrics.length(12.5)))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, metrics.length(10))
        .frame(maxWidth: metrics.length(Metrics.panelGhostWidth))
        .frame(height: metrics.length(28))
        .glass(.chip, in: RoundedRectangle(cornerRadius: metrics.length(9), style: .continuous))
    }
}

/// Page-local tools measure from the targeted panel, including account fields
/// whose positions are returned by WebKit in that page's own coordinates.
private struct PanelPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    let corner: CGFloat
    var body: some View {
        Page(tab: tab, corner: corner)
            .overlay { SiteStoragePanel(storage: tab.siteStorage, reset: { SiteData.ask(tab, in: browser) }) }
            .overlay { VisualDetails(pick: tab.visual, again: { tab.visual.stop(); browser.pickVisual() }, capture: { browser.capturePage(.element, selection: $0) }) }
            .overlay { AreaSelection(pick: tab.area, capture: browser.captureArea) }
            .overlay { CapturePreview(capture: tab.capture) }
            .overlay {
                if browser.activeID == tab.id, browser.prefs.showsLinks { LinkBubble(status: browser.linkStatus) }
            }
            .overlay { SelectionOver(menu: browser.selectionMenu, tab: tab) }
            .overlay(alignment: .topLeading) { AccountsOver(logins: browser.logins, tab: tab.id) }
    }
}

/// A composition's one entry among the tabs: its pages side by side, the
/// page in focus on the chosen surface. Three titles in one row truncate to
/// a few letters each; with three, only the page last in focus keeps its title.
struct PanelEntry: View {
    @ObservedObject var browser: Browser
    @ObservedObject var panels: Panels
    let group: PanelGroup
    var row: [Tab]? = nil
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = group.members.contains { $0 == browser.activeID } && !browser.tuning
        HStack(spacing: metrics.length(2)) {
            ForEach(group.members, id: \.self) { id in
                if let tab = (row ?? browser.tabs).first(where: { $0.id == id }) {
                    PanelHalf(browser: browser, panels: panels, tab: tab, focused: shown && browser.activeID == id,
                              compact: group.members.count > 2 && group.active != id)
                }
            }
        }
        .padding(metrics.length(2))
        .frame(height: metrics.length(Metrics.panelEntryHeight))
        .background {
            RoundedRectangle(cornerRadius: metrics.length(Metrics.panelEntryRadius), style: .continuous)
                .fill(shown ? Palette.wash : .clear)
        }
        .shortcutAnimation(Motion.settle, value: browser.activeID, enabled: browser.prefs.fasterShortcuts, reduced: reduceMotion)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split group, \(group.members.count) panels")
        .contextMenu {
            if let tab = (row ?? browser.tabs).first(where: { $0.id == group.active }) {
                PanelMenu(browser: browser, panels: panels, tab: tab)
            }
        }
    }
}

private struct PanelHalf: View {
    @ObservedObject var browser: Browser
    @ObservedObject var panels: Panels
    @ObservedObject var tab: Tab
    let focused: Bool
    let compact: Bool
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @State private var hovering = false

    var body: some View {
        HStack(spacing: metrics.length(6)) {
            if compact || browser.prefs.glyph == .icons {
                Mark(icon: tab.icon, letter: tab.monogram, size: metrics.length(Metrics.navigationIcon))
            }
            if !compact {
                Text(tab.label)
                    .font(.system(size: metrics.length(12.5)))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(focused ? Palette.ink : Palette.muted)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, metrics.length(compact ? 0 : 7))
        .frame(width: compact ? metrics.length(Metrics.panelEntryHeight) : nil)
        .frame(maxWidth: compact ? nil : .infinity, maxHeight: .infinity)
        .background {
            let shape = RoundedRectangle(cornerRadius: metrics.length(Metrics.panelEntryRadius - 2), style: .continuous)
            if focused { Chosen(shape: shape) } else if hovering { shape.fill(Palette.hover) }
        }
        .contentShape(Rectangle())
        .onTapGesture { browser.select(tab) }
        .onHover { hovering = $0 }
        .help(tab.label)
        .contextMenu { PanelMenu(browser: browser, panels: panels, tab: tab) }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(tab.label)
        .accessibilityAction { browser.select(tab) }
    }
}

/// Layout-only observations for the bench, bounded by the mounted entries.
struct PanelEntryFrame: ViewModifier {
    let id: UUID
    func body(content: Content) -> some View {
        if Store.testing {
            content.background(GeometryReader { area in
                Color.clear.preference(key: PanelEntryFrames.self, value: [id: area.frame(in: .global)])
            })
        } else { content }
    }
}

struct PanelEntryFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct PanelMenu: View {
    @ObservedObject var browser: Browser
    @ObservedObject var panels: Panels
    let tab: Tab
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Menu {
            ForEach(PanelEdge.allCases, id: \.self) { edge in
                Menu("Add \(edge.title) Split") {
                    ForEach(browser.tabs.filter { browser.panelsMix($0, tab) && !(panels.group(tab.id)?.members.contains($0.id) ?? false) }) { source in
                        Button(source.label) { withAnimation(reduceMotion ? nil : Motion.settle) { _ = browser.split(source, with: tab, edge: edge) } }
                    }
                }
                .disabled(tab.isBlank || tab.bench || tab.floating || (panels.group(tab.id)?.members.count ?? 1) >= Panels.limit)
            }
            if let group = panels.group(tab.id) {
                Divider()
                Button { change { $0.turn(tab.id) } } label: { Label("Change Orientation", systemImage: group.horizontal ? "rectangle.split.1x2" : "rectangle.split.2x1") }
                Button { change { $0.move(tab.id, by: group.members.last == tab.id ? -1 : 1) } } label: { Label("Swap with Next Panel", systemImage: "arrow.left.arrow.right") }
                Button { change { $0.remove(tab.id) } } label: { Label("Move Out of Split", systemImage: "rectangle.portrait.and.arrow.right") }
                Button { change { $0.separate(tab.id) } } label: { Label("Separate All Pages", systemImage: "rectangle.on.rectangle") }
            }
        } label: { Label("Split View", systemImage: "rectangle.split.2x1") }
    }

    private func change(_ action: (Panels) -> Void) {
        withAnimation(reduceMotion ? nil : Motion.settle) { browser.changePanels(tab, action) }
    }
}
