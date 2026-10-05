// A capture owns one bounded raster and PNG until its preview closes. One
// global slot covers WebKit plus a serial raster worker, including cancelled
// requests still finishing in WebKit. Visible captures, and a drawn area of
// them (AreaPick.swift), use the snapshot API; offscreen page/element captures rasterize a bounded public WebKit PDF. The
// live page is never scrolled or resized. PDF bytes are rejected above 16 MiB
// after WebKit returns them (its internal allocation cannot be pre-capped).
import SwiftUI
import WebKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class PageCapture: ObservableObject {
    enum Mode: String { case visible, element, full, area }
    @Published private(set) var shown = false
    @Published private(set) var busy = false
    @Published private(set) var image: NSImage?
    @Published private(set) var png: Data?
    @Published private(set) var error: String?
    @Published private(set) var notice = ""
    @Published private(set) var address = ""
    @Published private(set) var environment = ""
    @Published private(set) var dimensions = ""
    @Published var includeURL = true
    @Published var includeEnvironment = true
    @Published var includeDimensions = true
    @Published var includeVersion = false
    /// Counts finished saves, so the card can say "Saved" for a moment.
    @Published private(set) var savedCount = 0
    private var revision = 0
    private static var taking = false
    private static let worker = DispatchQueue(label: "Escale.capture", qos: .userInitiated)
    private static let script = Bundled.script("capture-bounds.js")
    nonisolated static let byteLimit = 16 * 1024 * 1024
    private var savePanel: NSSavePanel?
    var context: String {
        var lines: [String] = []
        if includeURL { lines.append("URL: " + address) }
        if includeEnvironment && !environment.isEmpty { lines.append("Environment (unverified label): " + environment) }
        if includeDimensions { lines.append(dimensions) }
        if includeVersion { lines.append("Escale " + (Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "development")) }
        return lines.joined(separator:"\n")
    }
    func close() {
        savePanel?.cancel(nil); savePanel = nil
        revision += 1; shown = false; busy = false; image = nil; png = nil
        error = nil; notice = ""; address = ""; environment = ""; dimensions = ""
    }
    func take(_ web: WKWebView, mode: Mode, selection: VisualPick.Selection?, region: CGRect? = nil, environment: String, afterRead: @escaping () -> Void) {
        close()
        shown = true
        guard !Self.taking else { error = "Another capture is finishing. Try again in a moment."; afterRead(); return }
        guard !web.isLoading, let url = web.url else { error = "Wait for the page to load."; afterRead(); return }
        Self.taking = true; busy = true
        address = url.absoluteString; self.environment = environment
        let asked = revision
        let args: [String: Any] = ["mode":mode.rawValue, "url":url.absoluteString, "token":selection?.token ?? ""]
        web.evaluateJavaScript(Bundled.configured(Self.script, with: args), in:nil, in:.defaultClient) { [weak self, weak web] result in
            afterRead()
            guard let self, let web, self.revision == asked, self.shown, web.url == url, !web.isLoading else { Self.taking = false; return }
            do {
                let value = try result.get()
                guard let body = value as? [String:Any], let r = body["rect"] as? [String:Double], let viewport = body["viewport"] as? [String:Double],
                      let x=r["x"], let y=r["y"], let width=r["width"], let height=r["height"],
                      let vw=viewport["width"], let vh=viewport["height"], vw.isFinite, vh.isFinite, vw > 0, vh > 0, vw < 10_000_000, vh < 10_000_000 else { throw Failure("The page did not return capture dimensions.") }
                let scale = web.bounds.width / vw
                // The visible page and a chosen area are read in the view's points,
                // as the snapshot is; the area is kept on the page it was drawn on.
                let proposed: CGRect
                switch mode {
                case .visible: proposed = web.bounds
                case .area: proposed = (region ?? .null).intersection(web.bounds)
                case .element, .full: proposed = CGRect(x:x*scale,y:y*scale,width:width*scale,height:height*scale)
                }
                guard let bounds = CaptureBounds(proposed) else { throw Failure("This region is empty or too large to capture safely.") }
                let area = mode == .area ? "\nArea: \(Int((proposed.width/scale).rounded())) × \(Int((proposed.height/scale).rounded())) CSS px" : ""
                self.dimensions = "Web viewport: \(Int(vw)) × \(Int(vh)) CSS px · zoom \(Int((PageZoom.relative(web.pageZoom)*100).rounded()))%\(area)\nImage: \(bounds.width) × \(bounds.height) px"
                self.notice = (bounds.clipped ? "Limited capture: first 16,384 points of the region. " : "") +
                    (mode == .visible ? "Visible page as rendered by WebKit." : mode == .area ? "Selected area of the visible page as rendered by WebKit." : "WebKit document rendering. Fixed/sticky elements and video may differ from the visible page. No scrolling or lazy loading is triggered.")
                if mode == .visible || mode == .area {
                    let config = WKSnapshotConfiguration()
                    config.rect = bounds.rect
                    let backing = max(1,web.window?.backingScaleFactor ?? 2)
                    config.snapshotWidth = NSNumber(value:Double(bounds.width)/backing)
                    web.takeSnapshot(with:config) { [weak self] image,error in
                        guard let self, self.revision == asked, self.shown else { Self.taking = false; return }
                        guard let cg = image?.cgImage(forProposedRect:nil,context:nil,hints:nil) else { self.finish(asked, result:.failure(error ?? Failure("WebKit could not capture this page."))); return }
                        self.raster(asked, bounds:bounds, image:cg, pdf:nil)
                    }
                } else {
                    let config = WKPDFConfiguration(); config.rect = bounds.rect
                    web.createPDF(configuration:config) { [weak self] result in
                        guard let self, self.revision == asked, self.shown else { Self.taking = false; return }
                        switch result {
                        case .failure(let error): self.finish(asked,result:.failure(error))
                        case .success(let data):
                            guard data.count <= Self.byteLimit else { self.finish(asked,result:.failure(Failure("Document rendering exceeds 16 MiB. Capture a smaller region."))); return }
                            self.raster(asked,bounds:bounds,image:nil,pdf:data)
                        }
                    }
                }
            } catch { self.finish(asked,result:.failure(error)) }
        }
    }
    private func raster(_ asked: Int, bounds: CaptureBounds, image: CGImage?, pdf: Data?) {
        Self.worker.async { [weak self] in
            let result = Result { try Self.render(bounds, image:image, pdf:pdf) }
            DispatchQueue.main.async { self?.finish(asked,result:result); if self == nil { Self.taking = false } }
        }
    }
    nonisolated private static func render(_ bounds: CaptureBounds, image: CGImage?, pdf: Data?) throws -> (CGImage, Data) {
        guard let context = CGContext(data:nil,width:bounds.width,height:bounds.height,bitsPerComponent:8,bytesPerRow:bounds.width*4,
                                      space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure("Could not allocate the bounded capture.") }
        let target = CGRect(x:0,y:0,width:bounds.width,height:bounds.height)
        if let image { context.draw(image,in:target) }
        else if let pdf, let provider = CGDataProvider(data:pdf as CFData), let document = CGPDFDocument(provider), let page = document.page(at:1) {
            context.concatenate(page.getDrawingTransform(.mediaBox,rect:target,rotate:0,preserveAspectRatio:true))
            context.drawPDFPage(page)
        } else { throw Failure("WebKit did not return a readable document rendering.") }
        guard let image = context.makeImage() else { throw Failure("Could not make the capture image.") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else { throw Failure("PNG encoding is unavailable.") }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination), data.length <= byteLimit else { throw Failure("The encoded capture exceeds 16 MiB. Use a smaller region.") }
        return (image,data as Data)
    }
    private func finish(_ asked: Int, result: Result<(CGImage,Data),Error>) {
        Self.taking = false
        guard revision == asked, shown else { return }
        busy = false
        switch result {
        case .success(let value): image = NSImage(cgImage:value.0,size:CGSize(width:value.0.width,height:value.0.height)); png = value.1
        case .failure(let failure): error = (failure as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? failure.localizedDescription
        }
    }
    func copyImage() {
        guard let png else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setData(png,forType:.png)
    }
    func save() {
        guard let png else { return }
        let asked = revision
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "Escale-capture.png"
        savePanel = panel
        panel.begin { [weak self] response in
            self?.savePanel = nil
            guard response == .OK, let url = panel.url, let self, self.revision == asked, self.shown else { return }
            Self.worker.async { [weak self] in
                do {
                    try Store.export(png,to:url)
                    DispatchQueue.main.async { [weak self] in if self?.revision == asked { self?.savedCount += 1 } }
                }
                catch { DispatchQueue.main.async { [weak self] in if self?.revision == asked { self?.error = error.localizedDescription } } }
            }
        }
    }
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

/// The result of a capture: a card in the page's lower right corner, in the
/// manner of a floating video, with the image and the two things to do with
/// it. It stays until closed (its cross, Escape, or the next capture).
struct CapturePreview: View {
    @ObservedObject var capture: PageCapture
    var body: some View {
        Group {
            if capture.shown {
                CaptureCard(capture: capture)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(Metrics.toolInset)
                    .transition(.scale(scale: 0.94, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        .animation(Motion.settle, value: capture.shown)
    }
}

private struct CaptureCard: View {
    @ObservedObject var capture: PageCapture
    @State private var copied = false
    @State private var saved = false
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.length(14), style: .continuous)
        VStack(spacing: 0) {
            picture
            // A clipped capture says so: the image alone would pass for the whole page.
            if capture.notice.hasPrefix("Limited capture") {
                Text(capture.notice.components(separatedBy: ". ").first ?? "")
                    .font(.system(size: metrics.length(11)))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, metrics.length(10)).padding(.vertical, metrics.length(6))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: 0) {
                action(copied ? "Copied" : "Copy", copied ? "checkmark" : "doc.on.doc", label: "Copy image") {
                    capture.copyImage()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + Motion.copiedHold) { copied = false }
                }
                Rectangle().fill(Palette.hairline).frame(width: 1)
                action(saved ? "Saved" : "Save", saved ? "checkmark" : "square.and.arrow.down", label: "Save image", capture.save)
            }
            .frame(height: metrics.length(34))
        }
        .frame(width: metrics.length(Metrics.captureCardWidth))
        .clipShape(shape)
        .glass(.panel, in: shape)
        .onChange(of: capture.savedCount) { _, _ in
            saved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.copiedHold) { saved = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page capture")
    }

    /// The image, or what stands in for it while it is made or when it failed.
    private var picture: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = capture.image {
                    // An exact height: a flexible frame would take the whole allowance.
                    let width = metrics.length(Metrics.captureCardWidth)
                    let height = min(metrics.length(Metrics.capturePreviewHeight), width * image.size.height / max(1, image.size.width))
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(height: height)
                        .accessibilityLabel("Captured page preview")
                } else if let error = capture.error {
                    Text(error).font(.system(size: metrics.length(12))).foregroundStyle(Palette.danger)
                        .padding(metrics.length(12)).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity).frame(height: metrics.length(Metrics.captureCardWidth * 9 / 16))
                }
            }
            .frame(maxWidth: .infinity)
            .background(Palette.wash)
            Button(action: capture.close) {
                Image(systemName: "xmark")
                    .font(.system(size: metrics.length(9), weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: metrics.length(20), height: metrics.length(20))
                    .background(Circle().fill(Palette.panel))
                    .overlay(Circle().strokeBorder(Palette.edge, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(metrics.length(6))
            .help("Close   esc")
            .accessibilityLabel("Close capture")
        }
    }

    /// Square-cornered and edge to edge: the card's own corners round its foot.
    private func action(_ title: String, _ symbol: String, label: String, _ act: @escaping () -> Void) -> some View {
        Action(title: title, symbol: symbol, label: label, ready: capture.png != nil, act: act)
    }

    private struct Action: View {
        let title: String
        let symbol: String
        let label: String
        let ready: Bool
        let act: () -> Void
        @State private var hovering = false
        @SwiftUI.Environment(\.chromeMetrics) private var metrics

        var body: some View {
            Button(action: act) {
                HStack(spacing: metrics.length(6)) {
                    Image(systemName: symbol).font(.system(size: metrics.length(12), weight: .medium))
                    Text(title).font(.system(size: metrics.length(13)))
                }
                .foregroundStyle(ready ? Palette.ink : Palette.faint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(hovering && ready ? Palette.hover : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!ready)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .accessibilityLabel(label)
        }
    }
}

/// The same Door as its neighbours, opening an AppKit menu below itself. A
/// SwiftUI Menu was tried first: AppKit draws its label as a template in the
/// control colour, so the camera came out darker than the doors beside it.
struct CaptureDoor: View {
    @ObservedObject var browser: Browser
    @State private var hook = Hook()

    var body: some View {
        Door(icon: "camera", help: browser.prefs.keyHelp(.capture, "Capture Page"), act: open)
            .background(HookView(hook: hook))
            .accessibilityLabel("Capture Page")
            .disabled(browser.active?.built == nil)
    }

    private func open() {
        guard let view = hook.view else { return }
        let menu = NSMenu()
        menu.addItem(Self.item("Visible Page", "rectangle") { browser.capturePage(.visible) })
        menu.addItem(Self.item("Select Area…", "rectangle.dashed") { browser.pickArea() })
        menu.addItem(Self.item("Choose Element…", VisualDoor.icon) { browser.pickVisual(forCapture: true) })
        menu.addItem(Self.item("Full Page (Limited)…", "rectangle.expand.vertical") { browser.capturePage(.full) })
        // Hung from the door's lower-left corner, a little below, like a pull-down.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 4 : -4), in: view)
    }

    /// Menu items call back into Swift through this; the item keeps it alive.
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    private static func item(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let action = Action(run)
        let item = NSMenuItem(title: title, action: #selector(Action.fire), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    /// The AppKit view behind the door, so the menu knows where the door is.
    private final class Hook { weak var view: NSView? }
    private struct HookView: NSViewRepresentable {
        let hook: Hook
        func makeNSView(context: Context) -> NSView { let view = NSView(); hook.view = view; return view }
        func updateNSView(_ view: NSView, context: Context) { hook.view = view }
    }
}

extension Browser {
    func capturePage(_ mode: PageCapture.Mode, selection: VisualPick.Selection? = nil, region: CGRect? = nil) {
        guard let tab = active, let web = tab.built else { return }
        tuning = false; tab.area.stop(); tab.jsonReader.raw(); tab.siteStorage.close()
        let label = shelfTabs[tab.id].flatMap { bookmarks.find($0) }.flatMap { BookmarkEnvironment.current(in: $0.destinations, at: tab.address) }?.name ?? ""
        if mode != .element { tab.visual.stop() }
        tab.capture.take(web,mode:mode,selection:selection,region:region,environment:label) { [weak tab] in
            if let selection, tab?.visual.selection?.token == selection.token { tab?.visual.stop() }
        }
    }
}
