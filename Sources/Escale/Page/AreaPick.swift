// Select Area, for a capture: a rectangle dragged over the visible page, in the
// web view's own points, captured the moment it is let go. Points, not CSS
// pixels, because the snapshot is taken in points too: page zoom and screen
// scale then agree with the rectangle on screen without any conversion. The
// gesture belongs to a native layer over the page, so the page never sees the
// press, the drag or a text selection starting, and nothing is injected into
// it. A rectangle holds four numbers and lives until the release, Escape,
// another tab or another page.
import SwiftUI

@MainActor
final class AreaPick: ObservableObject {
    /// Smaller than this is a click, not an area.
    static let least: CGFloat = 8
    @Published private(set) var active = false
    @Published private(set) var rect: CGRect?
    /// The page's size when last drawn, so a resize keeps the rectangle in it.
    private var page = CGSize.zero

    /// Something worth capturing has been drawn.
    var ready: Bool { rect.map { $0.width >= Self.least && $0.height >= Self.least } ?? false }

    func start() {
        rect = nil
        active = true
    }

    func stop() {
        guard active || rect != nil else { return }
        active = false
        rect = nil
    }

    func draw(_ next: CGRect?) {
        rect = next.map { Self.inside($0, of: page) }
    }

    /// The page changed size under the rectangle: keep it in.
    func fit(to size: CGSize) {
        page = size
        if let rect { self.rect = Self.inside(rect, of: size) }
    }

    /// The part of a rectangle that is on the page.
    nonisolated static func inside(_ rect: CGRect, of size: CGSize) -> CGRect {
        let x1 = min(max(rect.minX, 0), size.width), x2 = min(max(rect.maxX, 0), size.width)
        let y1 = min(max(rect.minY, 0), size.height), y2 = min(max(rect.maxY, 0), size.height)
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }
}

/// The layer over the page while an area is being chosen.
struct AreaSelection: View {
    @ObservedObject var pick: AreaPick
    let capture: () -> Void

    var body: some View {
        if pick.active { Surface(pick: pick, capture: capture) }
    }

    private struct Surface: View {
        @ObservedObject var pick: AreaPick
        let capture: () -> Void
        @State private var origin: CGPoint?
        @SwiftUI.Environment(\.chromeMetrics) private var metrics

        private var blue: Color { Palette.swatchInk(.blue) }

        var body: some View {
            GeometryReader { box in
                ZStack(alignment: .top) {
                    dim(in: box.size)
                    if let rect = pick.rect { frame(rect) }
                    hint
                }
                .frame(width: box.size.width, height: box.size.height)
                .contentShape(Rectangle())
                .gesture(drag(in: box.size))
                .onContinuousHover { phase in if case .active = phase { NSCursor.crosshair.set() } }
                .onAppear { pick.fit(to: box.size) }
                .onChange(of: box.size) { _, size in pick.fit(to: size) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Select area to capture")
        }

        /// The page dimmed but for the rectangle.
        private func dim(in size: CGSize) -> some View {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                if let rect = pick.rect { path.addRect(rect) }
            }
            .fill(Palette.scrim, style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
        }

        private func frame(_ rect: CGRect) -> some View {
            ZStack {
                Rectangle().fill(blue.opacity(0.08))
                Rectangle().strokeBorder(blue, lineWidth: metrics.length(Metrics.inspectionBorder))
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
        }

        private func drag(in size: CGSize) -> some Gesture {
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    let start = origin ?? value.startLocation
                    origin = start
                    let end = CGPoint(x: min(max(value.location.x, 0), size.width), y: min(max(value.location.y, 0), size.height))
                    pick.draw(CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                     width: abs(end.x - start.x), height: abs(end.y - start.y)))
                }
                .onEnded { _ in
                    origin = nil
                    // Let go: captured. A click, or a sliver, chose nothing.
                    if pick.ready { capture() } else { pick.draw(nil) }
                }
        }

        /// How to draw and how to leave; while drawing, the size.
        private var hint: some View {
            HStack(spacing: metrics.length(8)) {
                if let rect = pick.rect {
                    Text("\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))")
                        .monospacedDigit()
                        .foregroundStyle(Palette.ink)
                } else {
                    Text("Drag to select an area")
                        .foregroundStyle(Palette.ink)
                }
                Text("esc")
                    .foregroundStyle(Palette.muted)
                Door(icon: "xmark", help: "Cancel   esc", box: 20, glyph: 9, act: pick.stop)
            }
            .font(.system(size: metrics.length(12)))
            .padding(.leading, metrics.length(14)).padding(.trailing, metrics.length(5)).padding(.vertical, metrics.length(4))
            .glass(.chip, in: Capsule())
            .padding(.top, Metrics.toolInset)
        }
    }
}

extension Browser {
    /// Camera menu › Select Area…: the page waits for a rectangle. Another
    /// tool's result on this page gives way to it, as in pickVisual.
    func pickArea() {
        guard let tab = active, tab.built != nil else { return }
        tuning = false
        tab.jsonReader.raw(); tab.siteStorage.close(); tab.capture.close(); tab.visual.stop()
        tab.area.start()
    }

    /// The drawn rectangle, captured like the visible page.
    func captureArea() {
        guard let tab = active, tab.area.ready, let region = tab.area.rect else { return }
        tab.area.stop()
        capturePage(.area, region: region)
    }
}
