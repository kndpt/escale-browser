import AppKit
import SwiftUI
import WebKit
#if canImport(Translation)
import Translation
#endif

// Copy and Translate, over text just selected with the mouse.
//
// The right-click menu already has both, one click and a hunt further away;
// this puts them where the pointer let go. On unless turned off in Settings ›
// Web Pages. Off, not a line of it reaches a page: the listener is only put
// into pages while the switch is on, and a page already open is told to go
// quiet.
//
// What starts it: a mouse selection in a page's main frame that is not in a
// field or an editor, reported once on release (selection-watch.js). Nothing
// is watched while the pointer moves. What ends it: a click, a key, a scroll
// or a resize in the page, the selection going away, another tab, a new
// page, a zoom, or the switch. Only the rectangle crosses over; the selected
// words are read from the page when Translate is pressed, never before.
//
// Frames in the page are left out: their selections would need each frame's
// place in the page, and an ad or an embed is rarely text worth translating.
// Neither can a site's own menu over a selection be told apart from the rest
// of the page, so on the few sites that draw one both may show.
//
// Translation is Apple's own panel (the Translation framework), the same
// service as Translate in WebKit's right-click menu. Unless the Mac is set to
// translate offline, the panel says the words go to Apple and waits for
// Continue before sending anything: pressing Translate asks for it, nothing
// before does. Before macOS 14.4 there is no such panel and Copy stands alone.
//
// The arrival is drawn rather than animated by SwiftUI: Copy's pop and
// Translate being pulled out of it are two springs on one clock, and the two
// shapes are one piece of glass while they touch — blurred together, then
// cut at half their opacity, which is what makes the join stretch and snap
// like a drop. The clock runs for the arrival's 0.37 s and then stops; Reduce
// Motion skips it for a fade.

/// Reports a finished mouse selection in the main frame to the tab that owns
/// the page. WebKit retains this relay; the tab is weak so closing it
/// releases the page.
final class SelectionWatch: NSObject, WKScriptMessageHandler {
    static let name = "selection"
    /// Whether pages get the listener. Set from Settings.
    @MainActor static var on = false

    /// For a page already up when it is turned off: its listener goes quiet.
    static let off = "if (window.__escaleSelection) window.__escaleSelection.on = false;"

    // Listeners for release, click, key and scroll in the main frame, in the
    // isolated client world, so the page can neither see nor fake them.
    static let script = Bundled.script("selection-watch.js")

    weak var tab: Tab?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any]
        MainActor.assumeIsolated {
            guard let tab, let page = tab.built, message.webView === page,
                  message.frameInfo.isMainFrame else { return }
            tab.onSelection?(tab, body.flatMap { SelectionSpot($0, pageWidth: page.bounds.width) })
        }
    }
}

/// Where a selection is, in the page view's points: the line the pointer let
/// go on, and the whole selection's top and bottom.
struct SelectionSpot: Equatable {
    /// The pointer, kept within the line it let go on.
    var x: CGFloat
    var lineTop: CGFloat
    var lineBottom: CGFloat
    var top: CGFloat
    var bottom: CGFloat

    init(x: CGFloat, lineTop: CGFloat, lineBottom: CGFloat, top: CGFloat, bottom: CGFloat) {
        self.x = x
        self.lineTop = lineTop
        self.lineBottom = lineBottom
        self.top = top
        self.bottom = bottom
    }

    /// From the page, in CSS pixels; kept in points. Page zoom and a
    /// trackpad's magnification both show as the ratio of the view's width,
    /// `pageWidth`, to the viewport's (as in VisualPick.swift). Anything
    /// missing or out of order is no selection at all: any page can post to
    /// the handler.
    init?(_ body: [String: Any], pageWidth: CGFloat) {
        func number(_ key: String) -> CGFloat? {
            guard let number = (body[key] as? NSNumber)?.doubleValue, number.isFinite else { return nil }
            return CGFloat(number)
        }
        guard let viewport = number("viewport"), viewport > 0, pageWidth > 0 else { return nil }
        let scale = pageWidth / viewport
        func value(_ key: String) -> CGFloat? { number(key).map { $0 * scale } }
        guard let x = value("x"), let lineTop = value("lineTop"), let lineBottom = value("lineBottom"),
              let top = value("top"), let bottom = value("bottom"),
              lineTop <= lineBottom, top <= bottom
        else { return nil }
        self.init(x: x, lineTop: lineTop, lineBottom: lineBottom, top: top, bottom: bottom)
    }

    /// Let go on the first line of a selection that goes on below it — a
    /// selection made upwards: the menu goes above that line, where nothing
    /// is selected. Everywhere else, below the line.
    var above: Bool {
        lineTop <= top + 2 && lineBottom < bottom - 2
    }

    /// The menu's top-left corner in a page of `page` size. Copy is centred
    /// under the pointer and Translate opens to its right; the menu moves to
    /// the other side of the selection rather than leave the page, and
    /// covers the selection only when it fills the page.
    func origin(for size: CGSize, in page: CGSize) -> CGPoint {
        let margin = Metrics.selectionMargin, gap = Metrics.selectionOffset
        let maxX = max(margin, page.width - size.width - margin)
        let left = min(maxX, max(margin, x - Metrics.selectionButton / 2))
        var y = above ? lineTop - gap - size.height : lineBottom + gap
        if above, y < margin {
            y = bottom + gap
        } else if !above, y + size.height > page.height - margin {
            y = top - gap - size.height
        }
        let maxY = max(margin, page.height - size.height - margin)
        return CGPoint(x: left, y: min(maxY, max(margin, y)))
    }
}

/// The menu's shapes at one moment of its arrival, in the menu's points.
struct SelectionFrame: Equatable {
    /// Copy's scale, its height trailing its width.
    var copy: CGSize
    /// Translate's capsule; nil where there is no Translate.
    var pill: CGRect?
    /// Translate's words, from 0 to 1.
    var label: Double
    /// The fine outline, drawn once the two shapes have parted.
    var edge: Double
    /// The whole menu, from 0 to 1.
    var opacity: Double

    /// From the first frame to the last.
    static let total = max(Motion.selectionPop, Motion.selectionPullDelay + Motion.selectionPull)

    static func at(_ elapsed: TimeInterval, pill width: CGFloat?) -> SelectionFrame {
        let size = Metrics.selectionButton
        let popped = clamp(elapsed / Motion.selectionPop)
        let pop = spring(Motion.selectionPopBounce)
        let wide = pop(popped)
        let tall = popped >= 1 ? 1 : pop(max(0, popped - Motion.selectionWobble))
        var frame = SelectionFrame(
            copy: CGSize(width: wide, height: tall), pill: nil,
            label: 0, edge: popped, opacity: min(1, popped * 5)
        )
        guard let width else { return frame }

        // Translate starts as the copy button itself, as big as it is so far,
        // and is pulled out to the right to its own size.
        let pulled = clamp((elapsed - Motion.selectionPullDelay) / Motion.selectionPull)
        let out = spring(Motion.selectionPullBounce)(pulled)
        let base = min(1, wide)
        let startLeft = size / 2 * (1 - base), startSize = size * base
        let left = startLeft + (size + Metrics.selectionGap - startLeft) * out
        let height = startSize + (size - startSize) * out
        frame.pill = CGRect(
            x: left, y: (size - height) / 2,
            width: startSize + (width - startSize) * out, height: height
        )
        frame.label = clamp((pulled - 0.35) / 0.4)
        frame.edge = clamp((left - size) / (Metrics.selectionGap * 0.75))
        return frame
    }

    /// A damped spring from 0 to 1 over a unit of time, settled at its end.
    /// `bounce` 0 barely overshoots; 1 swings back and forth a few times.
    static func spring(_ bounce: Double) -> (Double) -> Double {
        let damping = max(0.3, min(0.99, 1 - bounce * 0.7))
        let natural = 4.6 / damping
        let damped = natural * (1 - damping * damping).squareRoot()
        return { t in
            guard t < 1 else { return 1 }
            let decay = exp(-damping * natural * t)
            return 1 - decay * (cos(damped * t) + damping * natural / damped * sin(damped * t))
        }
    }

    private static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : (value > 0 ? 1 : 0)
    }
}

/// The one menu there is, over the tab that asked for it. Only a page's
/// message or a button changes it: nothing here follows the pointer.
@MainActor
final class SelectionMenu: ObservableObject {
    struct Shown: Equatable {
        let tab: Tab.ID
        let spot: SelectionSpot
        /// The menu's top-left corner over the page. The page it was placed
        /// in doesn't change size while it shows: a resize closes it.
        let origin: CGPoint
        /// Each selection gets its own arrival, even in the same place.
        let serial: Int
    }

    @Published private(set) var shown: Shown?
    /// The words Translate was pressed for, while Apple's panel is open.
    @Published var translating: String?
    private var serial = 0

    /// Translate needs Apple's panel, which macOS 14.4 brought.
    static var translates: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    /// Translate's width at rest: its padding, symbol and word.
    static let pillWidth: CGFloat = {
        let word = ("Translate" as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium)
        ]).width
        let symbol = NSImage(systemSymbolName: "translate", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))?.size.width ?? 17
        return ceil(12 + symbol + 6 + word + 14)
    }()

    /// The menu at rest, as the page places it.
    static var size: CGSize {
        let button = Metrics.selectionButton
        let width = translates ? button + Metrics.selectionGap + pillWidth : button
        return CGSize(width: width, height: button)
    }

    /// A selection from `tab`, whose page is `page` in size, or its end.
    func show(_ spot: SelectionSpot?, in tab: Tab.ID, page: CGSize) {
        guard let spot else {
            if shown?.tab == tab { dismiss() }
            return
        }
        serial += 1
        release()
        shown = Shown(tab: tab, spot: spot, origin: spot.origin(for: Self.size, in: page), serial: serial)
    }

    func dismiss() {
        release()
        if shown != nil { shown = nil }
    }

    /// The page's own ⌘C, so what lands on the pasteboard is what WebKit
    /// would have put there: formatting and links included.
    func copy(in page: WKWebView?) {
        guard let page else { return }
        NSApp.sendAction(#selector(NSText.copy(_:)), to: page, from: nil)
    }

    /// The words are read from the page only now, and only if the menu they
    /// were asked from is still the one shown.
    func translate(in page: WKWebView?) {
        guard let page, let asked = shown?.serial else { return }
        page.evaluateJavaScript("getSelection().toString()", in: nil, in: .defaultClient) { [weak self] result in
            guard let self, shown?.serial == asked, case .success(let value) = result,
                  let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return }
            // Apple's panel is for a passage, not a book.
            translating = String(text.prefix(10_000))
        }
    }

    private func release() {
        if translating != nil { translating = nil }
    }
}

/// The menu over `tab`'s page, where its selection is. No reader of the
/// page's size here: a view filling the page would take its clicks.
struct SelectionOver: View {
    @ObservedObject var menu: SelectionMenu
    let tab: Tab
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let shown = menu.shown, shown.tab == tab.id {
                SelectionBubble(
                    menu: menu,
                    copy: { menu.copy(in: tab.built) },
                    translate: { menu.translate(in: tab.built) }
                )
                .offset(x: shown.origin.x - SelectionBubble.pad, y: shown.origin.y - SelectionBubble.pad)
                .id(shown.serial)
                .transition(.asymmetric(
                    insertion: reduced ? .opacity : .identity,
                    removal: .opacity.combined(with: .scale(scale: 0.94, anchor: .leading))
                ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(Motion.selectionLeave, value: menu.shown?.serial)
    }
}

/// Copy, and Translate drawn out of it, on one piece of glass.
private struct SelectionBubble: View {
    @ObservedObject var menu: SelectionMenu
    let copy: () -> Void
    let translate: () -> Void

    @State private var start = Date()
    @State private var settled = false
    @State private var overTranslate = false
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduced
    @SwiftUI.Environment(\.depth) private var depth
    @SwiftUI.Environment(\.accessibilityReduceTransparency) private var reducing

    /// Room around the shapes for their blur, overshoot and shadow.
    static let pad: CGFloat = 16

    var body: some View {
        let still = settled || reduced
        TimelineView(.animation(paused: still)) { context in
            let elapsed = still ? SelectionFrame.total : context.date.timeIntervalSince(start)
            drawn(SelectionFrame.at(elapsed, pill: SelectionMenu.translates ? SelectionMenu.pillWidth : nil))
        }
        .frame(width: SelectionMenu.size.width + Self.pad * 2, height: SelectionMenu.size.height + Self.pad * 2, alignment: .topLeading)
        .task {
            try? await Task.sleep(nanoseconds: UInt64(SelectionFrame.total * 1_000_000_000))
            settled = true
        }
    }

    private func drawn(_ frame: SelectionFrame) -> some View {
        let button = Metrics.selectionButton, pad = Self.pad
        let copyShape = CGRect(
            x: pad + button / 2 * (1 - frame.copy.width), y: pad + button / 2 * (1 - frame.copy.height),
            width: button * frame.copy.width, height: button * frame.copy.height
        )
        let pill = frame.pill.map { $0.offsetBy(dx: pad, dy: pad) }
        return ZStack(alignment: .topLeading) {
            ground
                .mask {
                    Canvas { context, _ in
                        context.addFilter(.alphaThreshold(min: 0.5, color: .black))
                        context.addFilter(.blur(radius: 4))
                        context.drawLayer { layer in
                            layer.fill(Path(ellipseIn: copyShape), with: .color(.black))
                            if let pill {
                                layer.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(.black))
                            }
                        }
                    }
                }
                .compositingGroup()
                .shadow(color: Palette.shadow, radius: 16, y: 5)
                .allowsHitTesting(false)

            Canvas { context, _ in
                let edge = GraphicsContext.Shading.color(Palette.edge.opacity(frame.edge))
                context.stroke(Path(ellipseIn: copyShape.insetBy(dx: 0.5, dy: 0.5)), with: edge, lineWidth: 1)
                if let pill {
                    let inner = pill.insetBy(dx: 0.5, dy: 0.5)
                    context.stroke(Path(roundedRect: inner, cornerRadius: inner.height / 2), with: edge, lineWidth: 1)
                }
            }
            .allowsHitTesting(false)

            CopyButton(help: "Copy", box: button, glyph: 14, radius: nil, tint: Palette.ink, scaled: false, action: copy)
                .scaleEffect(x: frame.copy.width, y: frame.copy.height)
            .offset(x: pad, y: pad)

            if let pill {
                Button(action: translate) {
                    HStack(spacing: 6) {
                        Image(systemName: "translate").font(.system(size: 14, weight: .medium))
                        Text("Translate").font(.system(size: 13, weight: .medium))
                    }
                    .fixedSize()
                    .foregroundStyle(Palette.ink)
                    .opacity(frame.label)
                    .padding(.leading, 12)
                    .frame(width: pill.width, height: pill.height, alignment: .leading)
                    .background(Capsule().fill(overTranslate ? Palette.hover : .clear))
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { overTranslate = $0 }
                .modifier(TranslationPanel(menu: menu))
                .offset(x: pill.minX, y: pill.minY)
            }
        }
        .opacity(frame.opacity)
    }

    /// The chip's glass (GlassSurface in Glass.swift), cut to the shapes
    /// instead of drawn in one: a blur only where the page may show through.
    private var ground: some View {
        let drawn = depth.drawn(reducing: reducing)
        return ZStack {
            if drawn.sees {
                Rectangle().fill(drawn == .clear ? Material.regularMaterial : Material.thickMaterial)
            }
            Rectangle().fill(Palette.panel.opacity(drawn.tint(.chip)))
        }
    }
}

/// Apple's translation panel, hanging from Translate while the menu holds
/// words for it.
private struct TranslationPanel: ViewModifier {
    @ObservedObject var menu: SelectionMenu

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(macOS 14.4, *) {
            content.translationPresentation(
                isPresented: Binding(
                    get: { menu.translating != nil },
                    set: { if !$0 { menu.translating = nil } }
                ),
                text: menu.translating ?? ""
            )
        } else {
            content
        }
        #else
        content
        #endif
    }
}
