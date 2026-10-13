// Developer mode: the hammer at the end of the bar, or Page Tools › Developer
// Mode, brings a small dock of page tools up from the window's foot —
// Select, Capture and Network. Network's ⌥⌘N brings it up too, so the tool
// opened from the keyboard is shown on, with its way out. The bar keeps what
// is about the browser (downloads, extensions) and the hammer; what is about
// the page lives here, so the next tool joins the dock instead of widening
// the bar.
//
// The dock is centred on the window, at its foot, not on the page: the page's
// frame moves when the column folds or Network opens, and a dock that slid
// with it was a target that would not stay put. A grip at its head moves it
// anywhere in the window for the session, kept inside the window as it
// changes size. It is chip glass, like everything Escale lays
// over a page: a page can be any colour, and a thinner glass let a black one
// turn the dock to grey mud under grey symbols. It follows light, dark, the
// tone and Transparency with no colour of its own.
//
// A tool that is off is a symbol; one that is on wears the chosen surface and
// says its name, arriving as the menu over selected text does (Bubble.swift).
// Reduce Motion keeps the states and drops the movement.
//
// While the mode is on, the window says so without touching the page: a fine
// line of the landing's dev blue runs round the page's frame, outside it, with
// a soft glow behind, and the envelope takes a breath of the same blue from
// the foot up. A light sweeps once round the line as the mode comes on, then
// nothing moves: at rest it is two static layers and costs no frames.
//
// Turning the mode off closes its tools: nothing goes on recording a page
// whose inspection can no longer be seen.
import SwiftUI

extension Browser {
    func toggleWorkbench() {
        developing.toggle()
        guard !developing else { return }
        for tab in tabs + parkedTabs where tab.calls.open { tab.calls.stop() }
        active?.visual.stop()
        active?.area.stop()
    }

    /// Network from the keyboard: the dock comes up with it on.
    func toggleNetwork() {
        developing = true
        toggleCalls()
    }

    /// The mode shows: not over Settings, Welcome or a page holding the screen.
    var showsWorkbench: Bool {
        developing && !tuning && !welcoming && active?.immersed != true
    }
}

/// The dock of page tools, laid over the whole window.
struct Workbench: View {
    @ObservedObject var browser: Browser
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the grip has put the dock, from its place at the window's foot.
    @State private var offset = CGSize.zero
    @State private var dragStart: CGSize?
    @State private var size = CGSize.zero

    /// What the dock takes from the window's foot, for the notices that rise
    /// from there (App.swift).
    static func height(_ metrics: ChromeMetrics) -> CGFloat {
        metrics.length(Metrics.dockTool + 2 * Metrics.dockPad + Metrics.dockFoot)
    }

    var body: some View {
        GeometryReader { area in
            ZStack(alignment: .bottom) {
                if browser.showsWorkbench {
                    dock(in: area.size)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                        .offset(kept(offset, in: area.size))
                        .padding(.bottom, metrics.length(Metrics.dockFoot))
                        .transition(reduceMotion ? .opacity : .rise)
                }
            }
            .frame(width: area.size.width, height: area.size.height, alignment: .bottom)
        }
        .animation(reduceMotion ? Motion.quick : Motion.dock, value: browser.showsWorkbench)
    }

    private func dock(in area: CGSize) -> some View {
        HStack(spacing: metrics.length(Metrics.dockGap)) {
            grip(in: area)
            VisualTool(browser: browser)
            CaptureTool(browser: browser)
            NetworkTool(browser: browser)
        }
        .padding(metrics.length(Metrics.dockPad))
        .glass(.chip, in: Capsule(style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Developer tools")
    }

    /// Six dots at the dock's head: hold and move.
    private func grip(in area: CGSize) -> some View {
        // Drawn: SF Symbols has no two-by-three grid of dots. Whole points
        // at every interface size: the grid's height stays even, so it
        // centres on the tools' line without rounding off it.
        let dot = metrics.length(2).rounded(.down)
        let gap = dot
        let row = HStack(spacing: gap) { Circle().frame(width: dot, height: dot); Circle().frame(width: dot, height: dot) }
        // Half a point up: six small dots weigh less than the symbols beside
        // them, and centred on the box they read low against the row.
        return VStack(spacing: gap) { row; row; row }
            .offset(y: -metrics.length(0.5))
            .foregroundStyle(Palette.faint)
            .frame(width: metrics.length(Metrics.dockGrip), height: metrics.length(Metrics.dockTool))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = dragStart ?? offset
                        dragStart = start
                        offset = kept(CGSize(width: start.width + drag.translation.width,
                                             height: start.height + drag.translation.height), in: area)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .help("Move")
            .accessibilityHidden(true)
    }

    /// The offset asked for, held inside the window with the foot's margin
    /// on every side, and never below the foot.
    private func kept(_ wanted: CGSize, in area: CGSize) -> CGSize {
        let margin = metrics.length(Metrics.dockFoot)
        let sideways = max(0, (area.width - size.width) / 2 - margin)
        let upward = max(0, area.height - size.height - 2 * margin)
        return CGSize(width: min(max(wanted.width, -sideways), sideways),
                      height: min(max(wanted.height, -upward), 0))
    }
}

/// One tool of the dock: a symbol, and while it is on, the chosen surface
/// under it and its name beside it.
///
/// Turning on is the selection menu's arrival (Bubble.swift): the surface
/// pops round the symbol, then the name's capsule is pulled out of it to the
/// right, the two one drop while they touch. The symbol never moves; the
/// tools beside it make room on the same spring. Turning off draws the
/// capsule back in as it fades, faster than it came.
struct WorkbenchTool: View {
    let icon: String
    let title: String
    var on = false
    var help = ""
    /// How far up the symbol is drawn, in compact points, for one whose
    /// weight sits below the middle of its box.
    var lift: CGFloat = 0
    let act: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SwiftUI.Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    /// When it last came on or went off. The clock runs from here, and only
    /// until the change has played out.
    @State private var changed = Date.distantPast
    @State private var playing = false
    /// The name's width and the symbol's, as laid out: symbols differ in
    /// width, and the capsule's spacing is measured from the ink.
    @State private var named: CGFloat = 0
    @State private var glyph: CGFloat = 0

    /// Going off: the capsule drawn back in.
    private static let leave: TimeInterval = 0.16
    /// Room round the surface for its blur, overshoot and shadow.
    private static let pad: CGFloat = 12

    /// The surface and the name at one moment of a change.
    private struct Frame {
        /// The round surface's scale.
        var round = CGSize(width: 1, height: 1)
        /// How far the capsule is out, from 0 to 1, past 1 on the bounce.
        var out = 0.0
        var label = 0.0
        var surface = 0.0
    }

    var body: some View {
        Button(action: act) {
            TimelineView(.animation(paused: !playing)) { context in
                drawn(frame(context.date.timeIntervalSince(changed)))
            }
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .onChange(of: on) { _, _ in
            guard !reduceMotion else { return }
            changed = Date()
            playing = true
        }
        .task(id: changed) {
            try? await Task.sleep(nanoseconds: UInt64((on ? Bubble.total : Self.leave) * 1_000_000_000))
            playing = false
        }
        .help(help)
        .animation(Motion.quick, value: hovering)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func frame(_ elapsed: TimeInterval) -> Frame {
        if on {
            guard elapsed < Bubble.total, !reduceMotion else { return Frame(out: 1, label: 1, surface: 1) }
            return Frame(round: Bubble.pop(elapsed), out: Bubble.pull(elapsed), label: Bubble.label(elapsed), surface: 1)
        }
        guard elapsed < Self.leave, !reduceMotion else { return Frame() }
        let gone = Bubble.clamp(elapsed / Self.leave)
        let eased = gone * gone
        return Frame(out: 1 - eased, label: 1 - Bubble.clamp(gone * 2), surface: 1 - eased)
    }

    private func drawn(_ frame: Frame) -> some View {
        let box = metrics.length(Metrics.dockTool)
        // On, the capsule holds the same air before the symbol, between it
        // and the name, and after the name, whatever the symbol's width. A
        // wide symbol needs more room before it than its round surface gives:
        // it steps right by that much as the capsule is pulled out.
        let inside = (box - glyph) / 2
        let shift = max(0, metrics.length(Metrics.dockLead) - inside) * frame.out
        let start = shift + inside + glyph + metrics.length(Metrics.dockLabelGap)
        let full = max(0, metrics.length(Metrics.dockLead) - inside) + inside + glyph
            + metrics.length(Metrics.dockLabelGap) + named + metrics.length(Metrics.dockTrail)
        let pad = Self.pad
        let round = CGRect(
            x: pad + shift + box / 2 * (1 - frame.round.width), y: pad + box / 2 * (1 - frame.round.height),
            width: box * frame.round.width, height: box * frame.round.height
        )
        // The capsule starts as the round surface, as big as it is so far,
        // and is pulled out to the right to the name's width.
        let base = min(1, frame.round.width)
        let startLeft = box / 2 * (1 - base), startSize = box * base
        let height = startSize + (box - startSize) * frame.out
        let pill = CGRect(
            x: pad + startLeft * (1 - frame.out), y: pad + (box - height) / 2,
            width: startSize + (full - startSize) * frame.out, height: height
        )
        let width = max(box, box + (full - box) * frame.out)

        return ZStack(alignment: .leading) {
            Image(systemName: icon)
                .font(.system(size: metrics.length(Metrics.dockGlyph), weight: .medium))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { glyph = $0 }
                .offset(y: -metrics.length(lift))
                .scaleEffect(max(1, frame.round.width))
                .frame(width: box, height: box)
                .offset(x: shift)
            Text(title)
                .font(.system(size: metrics.length(Metrics.dockText), weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { named = $0 }
                .opacity(frame.label)
                // Inside the capsule as it is pulled out, never past its end.
                .mask(alignment: .leading) {
                    Rectangle().frame(width: max(0, pill.maxX - pad - start))
                }
                .offset(x: start)
                .accessibilityHidden(true)
        }
        // Under the symbol and the name, and out of the layout: the surface
        // reaches past the tool for its blur and bounce.
        .background(alignment: .topLeading) {
            if frame.surface > 0 {
                // The chosen surface (Chosen in Glass.swift), cut to the drop.
                Palette.selection
                    .frame(width: full * 1.2 + pad * 2, height: box + pad * 2)
                    .mask(alignment: .topLeading) { BubbleMask(round: round, pill: pill) }
                    .compositingGroup()
                    .shadow(color: Palette.shadow.opacity(0.4), radius: 1.5, y: 0.5)
                    .opacity(frame.surface)
                    .offset(x: -pad, y: -pad)
                    .allowsHitTesting(false)
            } else if hovering, enabled {
                Circle().fill(Palette.hover).frame(width: box, height: box)
            }
        }
        .foregroundStyle(on ? Palette.ink : (hovering && enabled ? Palette.ink.opacity(0.7) : Palette.muted))
        .frame(width: width, height: box, alignment: .leading)
        .contentShape(Capsule())
    }
}

/// Developer mode's line round the page, drawn behind its frame so only what
/// lies outside the page shows: the glow never falls on the page itself.
struct DevelopingRing: View {
    let corner: CGFloat
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The sweep's turn, once, as the mode comes on.
    @State private var turn = 0.0
    @State private var sweeping = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner + 1.5, style: .continuous)
        ZStack {
            shape
                .stroke(Palette.developing.opacity(0.85), lineWidth: 1.5)
                .shadow(color: Palette.developing.opacity(0.5), radius: 12)
            if !reduceMotion {
                GeometryReader { box in
                    let side = hypot(box.size.width, box.size.height)
                    AngularGradient(colors: [.clear, .clear, Palette.developing, .white.opacity(0.9), .clear],
                                    center: .center)
                        .frame(width: side, height: side)
                        .rotationEffect(.degrees(turn))
                        .position(x: box.size.width / 2, y: box.size.height / 2)
                }
                .mask(shape.stroke(lineWidth: 3))
                .opacity(sweeping ? 1 : 0)
            }
        }
        .padding(-1.5)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1)) { turn = 360 } completion: {
                withAnimation(Motion.quick) { sweeping = false }
            }
        }
    }
}

/// A breath of Developer mode's blue on the envelope, rising from the foot
/// where the dock is.
struct DevelopingWash: View {
    var body: some View {
        LinearGradient(colors: [Palette.developing.opacity(0.12), Palette.developing.opacity(0.02)],
                       startPoint: .bottom, endPoint: .top)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct Blurred: ViewModifier {
    let radius: CGFloat
    let lift: CGFloat
    func body(content: Content) -> some View {
        content.blur(radius: radius).offset(y: lift)
    }
}

private extension AnyTransition {
    /// The dock rising from the window's foot, coming into focus as it lands.
    static var rise: AnyTransition {
        .modifier(active: Blurred(radius: 8, lift: 28), identity: Blurred(radius: 0, lift: 0))
            .combined(with: .opacity)
            .combined(with: .scale(scale: 0.86, anchor: .bottom))
    }
}
