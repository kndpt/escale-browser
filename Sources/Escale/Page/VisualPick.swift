// A targeting interaction owns its script relay while armed or pinned. The
// page coalesces input into one pending frame and reads a short summary only
// when the element under the pointer changes (a card beside it, not a panel
// to read through), then the full list once, at selection. Swift retains one
// summary of bounded strings, at most sixteen 512-character values and one
// rectangle. Pinned, only the outline's position still moves with scroll: the
// values are frozen, not a live inspector, and invalidated with their page.
import SwiftUI
import WebKit

@MainActor
final class VisualPick: ObservableObject {
    struct Style: Identifiable {
        let name: String
        let value: String
        var id: String { name }
    }
    struct Selection {
        let token: String
        let label: String
        let rect: CGRect
        let scroll: CGPoint
        let viewport: CGSize
        let styles: [Style]
        let frame: Bool
        let shadow: Bool
        var text: String {
            ([label, "Bounds: \(rect.width) × \(rect.height) CSS px"] + styles.map { "\($0.name): \($0.value)" }).joined(separator: "\n")
        }
    }
    /// The few values a developer reaches for first, shown beside the
    /// element: read at hover and again at selection, never polled.
    struct Glance: Equatable {
        struct Paint: Equatable {
            let text: String
            /// sRGB components from the page, when it gave rgb()/rgba().
            let rgba: [Double]?
            init?(_ value: Any?) {
                guard let body = value as? [String: Any], let text = body["text"] as? String else { return nil }
                self.text = String(text.prefix(64))
                let rgba = (body["rgba"] as? [Double]).flatMap { $0.count == 4 && $0.allSatisfy(\.isFinite) ? $0 : nil }
                self.rgba = rgba
            }
            /// The page's own colour, shown as data: not an Escale colour, so not in Palette.
            var colour: Color? { rgba.map { Color(.sRGB, red: $0[0], green: $0[1], blue: $0[2], opacity: $0[3]) } }
        }
        let label: String
        let size: CGSize
        let family: String
        let fontSize: String
        let line: String
        let weight: String
        let ink: Paint
        let fill: Paint?
        let padding: String?
        init?(_ value: Any?) {
            guard let body = value as? [String: Any], let label = body["label"] as? String,
                  let width = body["width"] as? Double, let height = body["height"] as? Double, width.isFinite, height.isFinite,
                  let family = body["family"] as? String, let fontSize = body["size"] as? String,
                  let line = body["line"] as? String, let weight = body["weight"] as? String,
                  let ink = Paint(body["colour"]) else { return nil }
            self.label = String(label.prefix(64)); size = CGSize(width: width, height: height)
            self.family = String(family.prefix(64)); self.fontSize = String(fontSize.prefix(32))
            self.line = String(line.prefix(32)); self.weight = String(weight.prefix(8))
            self.ink = ink; fill = Paint(body["background"])
            padding = (body["padding"] as? String).map { String($0.prefix(64)) }
        }
    }
    /// Targeting: the page is covered and the pointer shows what it is over.
    @Published private(set) var active = false
    /// Pinned: the page has its input back and the card stays by the element.
    @Published private(set) var selection: Selection?
    @Published private(set) var error: String?
    @Published private(set) var glance: Glance?
    /// The element's box in the web view's points, following scroll.
    @Published private(set) var anchor: CGRect?
    /// The full list (the plate) instead of the card beside the element.
    @Published var detailed = false
    private weak var web: WKWebView?
    private var token = UUID().uuidString
    private var relay: Relay?
    private var picked: ((Selection) -> Void)?
    /// Picking for a capture rather than to inspect (Browser.pickVisual).
    var capturing: Bool { picked != nil }
    private static let script = Bundled.script("visual-pick.js")
    private static let name = "escaleVisualPick"

    func start(_ web: WKWebView?, picked: ((Selection) -> Void)? = nil) {
        stop()
        guard let web, !web.isLoading else { return }
        self.web = web; self.picked = picked
        active = true
        token = UUID().uuidString
        let asked = token
        let relay = Relay(self)
        self.relay = relay
        web.configuration.userContentController.add(relay, contentWorld: .defaultClient, name: Self.name)
        let args: [String: Any] = ["action":"start", "token":token, "colour":Palette.inspectionCSS(alpha: 1),
                                  "wash":Palette.inspectionCSS(alpha: 0.08), "border":Metrics.inspectionBorder]
        web.evaluateJavaScript(Bundled.configured(Self.script, with: args), in: nil, in: .defaultClient) { [weak self] result in
            guard let self, self.token == asked, self.active else { return }
            if case .failure(let error) = result { self.stop(); self.error = error.localizedDescription }
        }
    }
    func stop() {
        if let web {
            web.evaluateJavaScript(Bundled.configured(Self.script, with: ["action":"stop", "token":token]), in: nil, in: .defaultClient, completionHandler: nil)
            web.configuration.userContentController.removeScriptMessageHandler(forName: Self.name, contentWorld: .defaultClient)
        }
        token = UUID().uuidString; relay = nil; web = nil; picked = nil
        active = false; selection = nil; error = nil; glance = nil; anchor = nil; detailed = false
    }
    /// CSS pixels to the web view's points: the page's zoom and magnification
    /// both show up as the ratio of its width to the viewport's.
    private func anchor(_ body: [String: Any]) -> CGRect? {
        guard let web, let rect = body["rect"] as? [String: Double], let viewport = body["viewport"] as? [String: Double],
              let x = rect["x"], let y = rect["y"], let width = rect["width"], let height = rect["height"], let vw = viewport["width"],
              [x,y,width,height,vw].allSatisfy(\.isFinite), vw > 0 else { return nil }
        let scale = web.bounds.width / vw
        return CGRect(x: x * scale, y: y * scale, width: width * scale, height: height * scale)
    }
    private func receive(_ message: WKScriptMessage) {
        guard active || selection != nil, message.frameInfo.isMainFrame, message.webView === web,
              let body = message.body as? [String: Any], body["token"] as? String == token else { return }
        switch body["kind"] as? String {
        case "hover":
            guard active, let glance = Glance(body["glance"]), let anchor = anchor(body) else { return }
            self.glance = glance; self.anchor = anchor
        case "moved":
            if let anchor = anchor(body) { self.anchor = anchor }
        case "selected" where active:
            select(body)
        default:
            stop()
        }
    }
    private func select(_ body: [String: Any]) {
        guard let rect = body["rect"] as? [String: Double], let viewport = body["viewport"] as? [String: Double],
              let scroll = body["scroll"] as? [String: Double], let rows = body["styles"] as? [[String: String]],
              let x = rect["x"], let y = rect["y"], let width = rect["width"], let height = rect["height"],
              let vw = viewport["width"], let vh = viewport["height"], let sx = scroll["x"], let sy = scroll["y"],
              [x,y,width,height,vw,vh,sx,sy].allSatisfy(\.isFinite), width > 0, height > 0, vw > 0, vh > 0 else { stop(); return }
        let result = Selection(token: token, label: String((body["label"] as? String ?? "Element").prefix(512)),
                               rect: CGRect(x:x,y:y,width:width,height:height), scroll: CGPoint(x:sx,y:sy), viewport: CGSize(width:vw,height:vh),
                               styles: rows.prefix(16).compactMap { row in
                                   guard let name = row["name"], let value = row["value"] else { return nil }
                                   return Style(name: String(name.prefix(64)), value: String(value.prefix(512)))
                               }, frame: body["frame"] as? Bool == true, shadow: body["shadow"] as? Bool == true)
        let callback = picked
        picked = nil; active = false
        // Picked for a capture: no card, the capture preview takes over.
        glance = callback == nil ? Glance(body["glance"]) : nil
        anchor = callback == nil ? anchor(body) : nil
        selection = result
        callback?(result)
    }
    private final class Relay: NSObject, WKScriptMessageHandler {
        weak var owner: VisualPick?
        init(_ owner: VisualPick) { self.owner = owner }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            owner?.receive(message)
        }
    }
}

struct VisualDetails: View {
    @ObservedObject var pick: VisualPick
    let again: () -> Void
    let capture: (VisualPick.Selection) -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        ZStack(alignment: .top) {
            if pick.active {
                if let glance = pick.glance, let anchor = pick.anchor {
                    Beside(anchor: anchor) { VisualCard(glance: glance) }
                        .allowsHitTesting(false)
                }
                hint
            } else if let selection = pick.selection {
                if pick.detailed {
                    plate(selection).padding(Metrics.toolInset)
                } else if let glance = pick.glance, let anchor = pick.anchor {
                    Beside(anchor: anchor) {
                        VisualCard(glance: glance, pinned: .init(again: again, capture: { capture(selection) },
                                                                 more: { pick.detailed = true }, close: pick.stop))
                    }
                }
            } else if let error = pick.error {
                HStack { Text(error); Button("Close", action: pick.stop) }
                    .padding(Metrics.toolInset).glass(.chip, in: Capsule()).padding(Metrics.toolInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// While targeting: how to pin and how to leave, and nothing else.
    private var hint: some View {
        HStack(spacing: metrics.length(8)) {
            Text("Click an element to pin it")
                .foregroundStyle(Palette.ink)
            Text("esc")
                .foregroundStyle(Palette.muted)
            Door(icon: "xmark", help: "Stop Inspecting   esc", box: 20, glyph: 9, act: pick.stop)
        }
        .font(.system(size: metrics.length(12)))
        .padding(.leading, metrics.length(14)).padding(.trailing, metrics.length(5)).padding(.vertical, metrics.length(4))
        .glass(.chip, in: Capsule())
        .padding(.top, Metrics.toolInset)
    }

    private func plate(_ selection: VisualPick.Selection) -> some View {
        Plate("Visual Inspection", width: Metrics.toolPanelWidth, close: pick.stop) {
            VStack(alignment: .leading, spacing: Metrics.toolGap) {
                Text(selection.label).font(.headline).textSelection(.enabled)
                Text(String(format: "%.1f × %.1f CSS px · frozen selection", selection.rect.width, selection.rect.height))
                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.toolGap) {
                        ForEach(selection.styles) { style in
                            HStack(alignment: .top) {
                                Text(style.name).foregroundStyle(Palette.muted)
                                Spacer()
                                Text(style.value).textSelection(.enabled)
                                Button("Copy") { JSONSurface.copy(style.value) }
                            }
                        }
                    }.font(.system(size: Metrics.toolFont, design: .monospaced))
                }.frame(height: Metrics.toolListHeight)
                Text("CSS families are not proof of the font used for each glyph. The declared family is the inline style only; pseudo-elements and layered backgrounds are not resolved. Iframes are selected as frames; closed shadow roots as hosts. Values are limited to 512 characters.")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
        } foot: {
            HStack {
                Button("Pick Again", action: again)
                Button("Copy Details") { JSONSurface.copy(selection.text) }
                Button("Capture Element") { capture(selection) }
            }
        }
    }
}

/// Places its content against an element's box: below it when it fits, above
/// otherwise, and always inside the page's edges (a box taller than the page,
/// or scrolled away). Hidden until measured, so it never flashes at the corner.
private struct Beside<Content: View>: View {
    let anchor: CGRect
    @ViewBuilder let content: () -> Content
    @State private var size = CGSize.zero
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        GeometryReader { box in
            content()
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                .offset(origin(in: box.size))
                .opacity(size == .zero ? 0 : 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func origin(in bounds: CGSize) -> CGSize {
        let gap = metrics.length(Metrics.visualGap), edge = metrics.length(Metrics.visualGap)
        let x = max(edge, min(anchor.minX, bounds.width - size.width - edge))
        let below = anchor.maxY + gap, above = anchor.minY - gap - size.height
        let y: CGFloat
        if below + size.height <= bounds.height - edge { y = below }
        else if above >= edge { y = above }
        else { y = anchor.minY + gap }
        // A pinned element scrolled away leaves its card at the nearest edge.
        return CGSize(width: x, height: max(edge, min(y, bounds.height - size.height - edge)))
    }
}

/// The card beside an element: what it is, its type and its colours. While
/// targeting it only reads; pinned, each value copies on click and the foot
/// leads to the full list, another pick or a capture.
struct VisualCard: View {
    struct Pinned {
        let again: () -> Void
        let capture: () -> Void
        let more: () -> Void
        let close: () -> Void
    }
    let glance: VisualPick.Glance
    var pinned: Pinned?
    @State private var copied: String?
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: metrics.length(8)) {
                Text(glance.label)
                    .font(.system(size: metrics.length(12), weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Text("\(Self.number(glance.size.width)) × \(Self.number(glance.size.height))")
                    .font(.system(size: metrics.length(11)).monospacedDigit())
                    .foregroundStyle(Palette.muted)
                if let pinned {
                    Door(icon: "xmark", help: "Done   esc", box: 20, glyph: 9, act: pinned.close)
                }
            }
            .padding(.leading, metrics.length(12)).padding(.trailing, metrics.length(pinned == nil ? 12 : 6))
            .frame(height: metrics.length(34))

            Rectangle().fill(Palette.hairline).frame(height: 1)

            VStack(spacing: 0) {
                row("Font", glance.family)
                row("Size", glance.fontSize, note: glance.line == "normal" ? nil : "line \(glance.line)")
                row("Weight", glance.weight, note: Self.weightName(glance.weight))
                row("Color", glance.ink.text, swatch: glance.ink)
                if let fill = glance.fill { row("Background", fill.text, swatch: fill) }
                if let padding = glance.padding { row("Padding", padding) }
            }
            .padding(metrics.length(4))

            if let pinned {
                Rectangle().fill(Palette.hairline).frame(height: 1)
                HStack(spacing: metrics.length(2)) {
                    Door(icon: VisualTool.icon, help: "Pick Another Element", box: 24, glyph: 11, act: pinned.again)
                    Door(icon: "camera", help: "Capture Element", box: 24, glyph: 11, act: pinned.capture)
                    Spacer(minLength: 0)
                    Button(action: pinned.more) {
                        HStack(spacing: metrics.length(3)) {
                            Text("All Styles")
                            Image(systemName: "chevron.right").font(.system(size: metrics.length(9), weight: .semibold))
                        }
                        .font(.system(size: metrics.length(12)))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, metrics.length(8)).frame(height: metrics.length(24))
                        .background(Capsule().fill(Palette.wash))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, metrics.length(6)).padding(.vertical, metrics.length(5))
            }
        }
        .frame(width: metrics.length(Metrics.visualCardWidth))
        .glass(.chip, in: RoundedRectangle(cornerRadius: metrics.length(12), style: .continuous))
    }

    private func row(_ name: String, _ value: String, note: String? = nil, swatch: VisualPick.Glance.Paint? = nil) -> some View {
        VisualValue(name: name, value: value, note: note, swatch: swatch?.colour, copyable: pinned != nil,
                    copied: copied == name) {
            JSONSurface.copy(value)
            copied = name
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.copiedHold) { if copied == name { copied = nil } }
        }
    }

    static func number(_ value: CGFloat) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// The CSS keyword a numeric weight stands for, to read "700" at a glance.
    static func weightName(_ weight: String) -> String? {
        switch Int(weight) {
        case 100: return "Thin"
        case 200: return "Extra Light"
        case 300: return "Light"
        case 400: return "Regular"
        case 500: return "Medium"
        case 600: return "Semibold"
        case 700: return "Bold"
        case 800: return "Extra Bold"
        case 900: return "Black"
        default: return nil
        }
    }
}

/// One line of the card: a name, its value, and when pinned a click to copy.
private struct VisualValue: View {
    let name: String
    let value: String
    let note: String?
    let swatch: Color?
    let copyable: Bool
    let copied: Bool
    let copy: () -> Void
    @State private var hovering = false
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        // Read-only while targeting: a disabled button would dim the values.
        if copyable {
            Button(action: copy) { line }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help("Copy \(value)")
        } else {
            line
        }
    }

    private var line: some View {
        HStack(spacing: metrics.length(8)) {
            Text(name)
                .foregroundStyle(Palette.muted)
                .frame(width: metrics.length(Metrics.visualNameWidth), alignment: .leading)
            if let swatch {
                Circle().fill(swatch)
                    .overlay(Circle().strokeBorder(Palette.edge, lineWidth: 1))
                    .frame(width: metrics.length(Metrics.swatchDot), height: metrics.length(Metrics.swatchDot))
            }
            Text(value)
                .foregroundStyle(Palette.ink)
                .font(.system(size: metrics.length(12), design: swatch == nil ? .default : .monospaced).monospacedDigit())
                .lineLimit(1).truncationMode(.tail)
            if let note {
                Text(note).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            if copyable && (hovering || copied) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: metrics.length(10)))
                    .foregroundStyle(copied ? Palette.ink : Palette.muted)
            }
        }
        .font(.system(size: metrics.length(12)))
        .padding(.horizontal, metrics.length(8))
        .frame(height: metrics.length(26))
        .background(RoundedRectangle(cornerRadius: metrics.length(7), style: .continuous)
            .fill(copyable && hovering ? Palette.hover : .clear))
        .contentShape(Rectangle())
    }
}

/// Select in Developer mode's dock: pick an element with the pointer.
struct VisualTool: View {
    /// The bare pointer: pick with the mouse. Doubled dashed squares were
    /// tried first; they read heavier than the camera and DevTools symbols,
    /// off-centre, and like "copy".
    static let icon = "cursorarrow"
    @ObservedObject var browser: Browser
    var body: some View {
        if let tab = browser.active {
            Lit(pick: tab.visual, ready: tab.built != nil, help: browser.prefs.keyHelp(.visual)) { browser.pickVisual() }
        } else {
            WorkbenchTool(icon: Self.icon, title: "Select", help: browser.prefs.keyHelp(.visual)) {}.disabled(true)
        }
    }
    /// On while targeting or pinned, so the way out is where the way in was.
    /// Picking an element to capture is Capture's, not this one's.
    private struct Lit: View {
        @ObservedObject var pick: VisualPick
        let ready: Bool
        let help: String
        let act: () -> Void
        var body: some View {
            WorkbenchTool(icon: VisualTool.icon, title: "Select", on: (pick.active && !pick.capturing) || pick.selection != nil, help: help, act: act)
                .disabled(!ready)
        }
    }
}

extension Browser {
    func pickVisual(forCapture: Bool = false) {
        guard let tab = active, let web = tab.built else { return }
        tuning = false
        tab.jsonReader.raw(); tab.siteStorage.close(); tab.capture.close(); tab.area.stop()
        if tab.visual.active || tab.visual.selection != nil { tab.visual.stop(); if !forCapture { return } }
        tab.visual.start(web, picked: forCapture ? { [weak self, weak tab] selection in
            guard let self, let tab, self.active === tab else { return }
            self.capturePage(.element, selection: selection)
        } : nil)
    }
}
