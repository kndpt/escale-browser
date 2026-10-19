// Screens' face (Screens.swift): a line of readings and a ruler above the
// page, on the envelope, and the page's frame narrowed to the width asked for,
// centred under them. The ruler is the page's own scale, centred on it: a
// breakpoint's ticks sit where the page's edges will be at that width, the
// devices' dots below where theirs will. Nothing is drawn over the page; the
// overflow outline, when asked for, is drawn by the page (screens.js).
//
// The page's edges are the handle: held, they move apart or together and
// catch on each side of a breakpoint (767, 768) and on a device's width,
// with the trackpad's alignment tap. The width is also typed, or stepped
// with ↑ ↓ in its field (⇧ by 10, ⌥ to the next side of a breakpoint).
//
// The page's size changes without animation: each step is a real size the
// page is told about.
import SwiftUI

/// The page in its cell, narrowed and measured while Screens is on, as it
/// always is otherwise. The same tree either way, so the page is never
/// mounted again.
struct Screened<Content: View>: View {
    @ObservedObject var tab: Tab
    @ObservedObject var screen: Screen
    @ViewBuilder let content: Content
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SwiftUI.Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { area in
            let head = screen.on ? metrics.length(Metrics.screenBar + Metrics.screenRuler) + metrics.pageInset : 0
            let room = CGSize(width: area.size.width, height: max(0, area.size.height - head))
            let zoom = PageZoom.absolute(tab.zoom)
            let pixel = 1 / max(displayScale, 1)
            // The page's width on whole device pixels, so its edges are
            // sharp, and the scale it is drawn at taken from that width, a
            // hair under: the page reads its width as the frame over the
            // scale, rounded down, and a quotient a hair short read a pixel
            // short.
            let wide = max(pixel, (CGFloat(screen.width) * zoom * fit(room, zoom: zoom) / pixel).rounded() * pixel)
            let drawn = screen.on ? wide / CGFloat(screen.width) * (1 - 1e-6) : 1
            let free = screen.on ? Int((room.height / drawn).rounded(.down)) : 0
            let live = screen.on
                ? CGSize(width: wide, height: screen.height.map { (CGFloat($0) * drawn / pixel).rounded(.up) * pixel } ?? room.height)
                : area.size
            let middle = (((area.size.width - live.width) / 2 / pixel).rounded(.down) * pixel) + live.width / 2
            // The lineup takes the page's place, the size of the room; the
            // page beneath it takes each picture's size in turn.
            let lined = screen.lineup != nil
            let size = screen.posing ?? live
            let left = ((area.size.width - size.width) / 2 / pixel).rounded(.down) * pixel
            VStack(alignment: .leading, spacing: 0) {
                if screen.on {
                    VStack(spacing: 0) {
                        ScreenBar(screen: screen, tab: tab, cssHeight: screen.height ?? free)
                            .frame(height: metrics.length(Metrics.screenBar))
                        ScreenRuler(screen: screen, perPixel: drawn, page: live.width, middle: middle)
                            .frame(height: metrics.length(Metrics.screenRuler))
                    }
                    .padding(.bottom, metrics.pageInset)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
                ZStack(alignment: .topLeading) {
                    content
                        .frame(width: size.width, height: size.height)
                        .overlay(alignment: .leading) { if screen.on, !lined { ScreenGrip(screen: screen, perPixel: drawn, side: -1) } }
                        .overlay(alignment: .trailing) { if screen.on, !lined { ScreenGrip(screen: screen, perPixel: drawn, side: 1) } }
                        .padding(.leading, left)
                        // Only the readings arrive: the page takes its size at
                        // once, so it never sees the ones in between. Its own
                        // fades are left alone.
                        .animation(nil, value: size)
                    if let lineup = screen.lineup {
                        LineupSheet(screen: screen, lineup: lineup)
                            .frame(width: room.width, height: room.height)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: area.size.width, height: area.size.height)
            .onChange(of: ScreenFit(drawn: drawn, free: free, room: room), initial: true) { _, next in screen.fit(next) }
        }
        .animation(reduceMotion ? nil : Motion.settle, value: screen.on)
    }

    /// Below 1 when the width, or a device's height, is more than the room:
    /// the page is laid out whole and drawn smaller.
    private func fit(_ room: CGSize, zoom: CGFloat) -> CGFloat {
        guard screen.on, zoom > 0, room.width > 0, room.height > 0 else { return 1 }
        var scale = min(1, room.width / (CGFloat(screen.width) * zoom))
        if let height = screen.height { scale = min(scale, room.height / (CGFloat(height) * zoom)) }
        return max(scale, 0.05)
    }
}

/// The readings: the size, the device, the layout's range from the page's
/// breakpoints, the overflow, and the ways out to a real device.
private struct ScreenBar: View {
    @ObservedObject var screen: Screen
    @ObservedObject var tab: Tab
    let cssHeight: Int
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @State private var choosing = false
    @State private var coding = false

    var body: some View {
        HStack(spacing: metrics.length(10)) {
            HStack(spacing: metrics.length(3)) {
                WidthField(screen: screen)
                Text(verbatim: "× \(cssHeight)")
                    .font(.system(size: metrics.length(Metrics.screenText)).monospacedDigit())
                    .foregroundStyle(screen.height == nil ? Palette.muted : Palette.ink)
            }
            deviceChoice
            Text(verbatim: screen.note ?? range)
                .font(.system(size: metrics.length(Metrics.screenText)).monospacedDigit())
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .help(screen.unread > 0 ? "\(screen.unread) stylesheets from other origins can’t be read." : "")
            if screen.overflow > 0 { overflow }
            Spacer(minLength: 0)
            if screen.height != nil {
                Door(icon: "rectangle.portrait.rotate", help: "Rotate") { screen.turn() }
            }
            Door(icon: "rectangle.split.3x1", on: screen.lineup != nil, help: "Every Layout") { screen.line() }
            if screen.simulator, let url = tab.address {
                Door(icon: "iphone", help: "Open in Simulator") {
                    ScreenPhone.simulate(url) { opened in
                        if !opened { screen.say("No booted simulator") }
                    }
                }
            }
            if let url = tab.address {
                Door(icon: "qrcode", on: coding, help: "Open on a Phone") { coding.toggle() }
                    .popover(isPresented: $coding, arrowEdge: .bottom) { PhoneCode(page: url) }
            }
        }
        .padding(.horizontal, metrics.length(4))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Screens")
    }

    private var range: String {
        Screen.range(of: screen.width, in: screen.edges) ?? (screen.unread > 0 ? "Breakpoints unreadable" : "No breakpoints")
    }

    private var deviceChoice: some View {
        Button { choosing.toggle() } label: {
            HStack(spacing: metrics.length(4)) {
                Text(screen.device?.name ?? "Free Width")
                    .font(.system(size: metrics.length(Metrics.screenText), weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: metrics.length(8), weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, metrics.length(7))
            .frame(height: metrics.length(Metrics.screenBar - 4))
            .background { if choosing { Chosen(shape: Capsule(style: .continuous)) } }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $choosing, arrowEdge: .bottom) {
            DeviceList(screen: screen) { choosing = false }
        }
        .accessibilityLabel("Device, \(screen.device?.name ?? "Free Width")")
    }

    private var overflow: some View {
        Button { screen.outline() } label: {
            HStack(spacing: metrics.length(4)) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: metrics.length(10), weight: .medium))
                Text(verbatim: "\(screen.overflow) overflowing")
                    .font(.system(size: metrics.length(Metrics.screenText)).monospacedDigit())
            }
            .foregroundStyle(Palette.danger)
            .padding(.horizontal, metrics.length(7))
            .frame(height: metrics.length(Metrics.screenBar - 4))
            .background { if screen.outlined { Chosen(shape: Capsule(style: .continuous)) } }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(screen.outlined ? "Hide the outlines" : "Outline what sticks out past the sides")
    }
}

/// The width, typed or stepped. Its own text while it has the keys, the
/// screen's otherwise.
private struct WidthField: View {
    @ObservedObject var screen: Screen
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @FocusState private var focused: Bool
    @State private var text = ""
    @State private var hovering = false

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: metrics.length(Metrics.screenText), weight: .medium).monospacedDigit())
            .foregroundStyle(Palette.ink)
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .frame(width: metrics.length(34))
            .padding(.horizontal, metrics.length(3))
            .frame(height: metrics.length(Metrics.screenBar - 4))
            .background(RoundedRectangle(cornerRadius: metrics.length(5), style: .continuous)
                .fill(focused ? Palette.wash : hovering ? Palette.hover : .clear))
            .onHover { hovering = $0 }
            .onAppear { text = "\(screen.width)" }
            .onChange(of: screen.width) { _, width in text = "\(width)" }
            .onChange(of: focused) { _, now in if !now { text = "\(screen.width)" } }
            .onSubmit { if let typed = Int(text.trimmingCharacters(in: .whitespaces)) { screen.resize(typed) } else { text = "\(screen.width)" } }
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                let up = press.key == .upArrow
                if press.modifiers.contains(.option) {
                    if let next = ScreenStep.edge(from: screen.width, up: up, in: screen.edges) { screen.resize(next) }
                } else {
                    screen.resize(screen.width + (up ? 1 : -1) * (press.modifiers.contains(.shift) ? 10 : 1))
                }
                return .handled
            }
            .onExitCommand { focused = false }
            .help("Width in CSS pixels. ↑ ↓ to step, ⇧ by 10, ⌥ across a breakpoint.")
            .accessibilityLabel("Width")
    }
}

@MainActor
enum ScreenStep {
    /// The next width up or down that sits on one side of a breakpoint.
    static func edge(from width: Int, up: Bool, in edges: [Int]) -> Int? {
        let sides = edges.flatMap { [$0 - 1, $0] }.sorted()
        return up ? sides.first { $0 > width } : sides.last { $0 < width }
    }

    /// A width near a breakpoint's sides or a device's caught there, within
    /// a few points on screen.
    static func caught(_ width: CGFloat, perPixel: CGFloat, edges: [Int]) -> Int? {
        let catches = edges.flatMap { [$0 - 1, $0] } + Screen.devices.map(\.width)
        let reach = 4 / max(perPixel, 0.01)
        return catches.min { abs(CGFloat($0) - width) < abs(CGFloat($1) - width) }
            .flatMap { abs(CGFloat($0) - width) <= reach ? $0 : nil }
    }
}

/// The devices, drawn in the popover, the one in use chosen.
private struct DeviceList: View {
    @ObservedObject var screen: Screen
    let done: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        VStack(spacing: metrics.length(1)) {
            row("Free Width", detail: "", chosen: screen.device == nil) { screen.pick(nil) }
            ForEach(Screen.devices) { device in
                row(device.name, detail: "\(device.width) × \(device.height)", chosen: screen.device == device) { screen.pick(device) }
            }
        }
        .padding(metrics.length(6))
        .frame(width: metrics.length(Metrics.screenListWidth))
        .popoverGround()
    }

    private func row(_ name: String, detail: String, chosen: Bool, act: @escaping () -> Void) -> some View {
        DeviceRow(name: name, detail: detail, chosen: chosen) { act(); done() }
    }
}

private struct DeviceRow: View {
    let name: String
    let detail: String
    let chosen: Bool
    let act: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.length(6), style: .continuous)
        Button(action: act) {
            HStack {
                Text(name)
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: metrics.length(8))
                Text(verbatim: detail)
                    .foregroundStyle(Palette.muted)
                    .monospacedDigit()
            }
            .font(.system(size: metrics.length(Metrics.screenText)))
            .padding(.horizontal, metrics.length(8))
            .frame(height: metrics.length(26))
            .background { if chosen { Chosen(shape: shape) } else if hovering { shape.fill(Palette.hover) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// The ruler, to the page's scale and centred on it: the page's span in the
/// mode's blue, the breakpoints' ticks on both sides with their width on the
/// right, the devices' dots below. A tick takes the page to that width, and
/// to its other side when it is there already.
private struct ScreenRuler: View {
    @ObservedObject var screen: Screen
    /// Points on screen for one CSS pixel.
    let perPixel: CGFloat
    /// The page's width on screen, and its middle from the ruler's start.
    let page: CGFloat
    let middle: CGFloat
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        GeometryReader { area in
            let line = metrics.length(Metrics.screenRuler - 9)
            let tick = metrics.length(6)
            let shown = screen.edges.filter { CGFloat($0) * perPixel / 2 <= min(middle, area.size.width - middle) - 1 }
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Palette.edge)
                    .frame(width: area.size.width, height: 1)
                    .offset(y: line)
                Capsule()
                    .fill(Palette.developing)
                    .frame(width: page, height: 2)
                    .offset(x: middle - page / 2, y: line - 0.5)
                ForEach(shown, id: \.self) { edge in
                    let half = CGFloat(edge) * perPixel / 2
                    let current = edge <= screen.width && screen.edges.last(where: { $0 <= screen.width }) == edge
                    ForEach([-1.0, 1.0], id: \.self) { side in
                        Rectangle()
                            .fill(current ? Palette.ink : Palette.muted)
                            .frame(width: 1, height: tick)
                            .offset(x: middle + side * half, y: line - tick)
                    }
                    if labelled(edge, in: shown) {
                        Text(verbatim: "\(edge)")
                            .font(.system(size: metrics.length(Metrics.screenSmall)).monospacedDigit())
                            .foregroundStyle(current ? Palette.ink : Palette.muted)
                            .fixedSize()
                            .offset(x: middle + half + metrics.length(3), y: line - tick - metrics.length(Metrics.screenSmall) + metrics.length(2))
                    }
                    // The whole height of the ruler takes the click.
                    ForEach([-1.0, 1.0], id: \.self) { side in
                        Color.clear
                            .frame(width: metrics.length(14), height: area.size.height)
                            .contentShape(Rectangle())
                            .offset(x: middle + side * half - metrics.length(7))
                            .onTapGesture { screen.resize(screen.width == edge ? edge - 1 : edge) }
                            .help(screen.width == edge ? "Go to \(edge - 1)" : "Go to \(edge)")
                    }
                }
                ForEach(Screen.devices.filter { CGFloat($0.width) * perPixel / 2 <= min(middle, area.size.width - middle) - 1 }) { device in
                    ForEach([-1.0, 1.0], id: \.self) { side in
                        DeviceDot(device: device, chosen: screen.device == device) { screen.pick(device) }
                            .offset(x: middle + side * CGFloat(device.width) * perPixel / 2 - metrics.length(5), y: line + metrics.length(2))
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ruler")
        .accessibilityValue(screen.edges.isEmpty ? "No breakpoints" : "Breakpoints \(screen.edges.map(String.init).joined(separator: ", "))")
    }

    /// A width is written unless it would run into the last one written.
    private func labelled(_ edge: Int, in shown: [Int]) -> Bool {
        var last: CGFloat = -.infinity
        let room = metrics.length(30)
        for each in shown {
            let x = CGFloat(each) * perPixel / 2
            if x - last >= room { last = x; if each == edge { return true } } else if each == edge { return false }
        }
        return false
    }
}

private struct DeviceDot: View {
    let device: Screen.Device
    let chosen: Bool
    let act: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @State private var hovering = false

    var body: some View {
        let dot = metrics.length(chosen || hovering ? 5 : 3)
        Circle()
            .fill(chosen ? Palette.developing : hovering ? Palette.ink : Palette.faint)
            .frame(width: dot, height: dot)
            .frame(width: metrics.length(10), height: metrics.length(8))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: act)
            .help("\(device.name), \(device.width) × \(device.height)")
            .animation(Motion.quick, value: hovering)
    }
}

/// One edge of the page, held to change its width: both edges move, as the
/// page is centred. The grip shows under the pointer or while held, as the
/// gap between split pages does (PanelStage.swift).
private struct ScreenGrip: View {
    @ObservedObject var screen: Screen
    let perPixel: CGFloat
    /// -1 for the leading edge, 1 for the trailing one.
    let side: CGFloat
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @State private var start: Int?
    @State private var caught: Int?
    @State private var gripping = false

    var body: some View {
        Capsule(style: .continuous)
            .fill(Palette.muted)
            .frame(width: metrics.length(Metrics.panelGripWidth), height: metrics.length(Metrics.panelGrip))
            .opacity(gripping ? 1 : 0)
            .scaleEffect(gripping ? 1 : 0.6)
            .frame(width: metrics.pageInset * 2)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .offset(x: side * metrics.pageInset)
            .animation(Motion.quick, value: gripping)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                if start == nil { gripping = inside }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { drag in
                        let from = start ?? screen.width
                        start = from
                        gripping = true
                        let wanted = CGFloat(from) + side * 2 * drag.translation.width / max(perPixel, 0.01)
                        let held = ScreenStep.caught(wanted, perPixel: perPixel, edges: screen.edges)
                        if let held, held != caught {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                        }
                        caught = held
                        let width = held ?? Int(wanted.rounded())
                        if let device = Screen.devices.first(where: { $0.width == held }), screen.device != device {
                            screen.pick(device)
                        } else if held == nil || Screen.devices.first(where: { $0.width == held }) == nil {
                            screen.resize(width)
                        }
                    }
                    .onEnded { _ in start = nil; caught = nil; gripping = false }
            )
            .accessibilityLabel("Page width")
            .accessibilityValue("\(screen.width) pixels")
            .accessibilityAdjustableAction { direction in
                screen.resize(screen.width + (direction == .increment ? 10 : -10))
            }
    }
}
