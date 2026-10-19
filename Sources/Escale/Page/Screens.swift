// Screens, in Developer mode's dock or ⌥⌘R: the page at another width,
// measured against its own breakpoints rather than a list of phones. The
// page's frame narrows to the width asked for and a ruler above it draws
// that width to the page's scale, so a breakpoint's mark is where the page's
// edge will be at that width (ScreenRuler.swift). Devices are marks on the
// same ruler; one also sets its height and pixel density.
//
// It costs nothing at rest: the page is read (screens.js) when the tool
// opens, after a load and once a new width has settled, never polled, and no
// second web view is made. WebKit lays the page out at the size asked for
// and draws it at the page's zoom, smaller still when it is more than the
// room (`_setLayoutMode:`, `_setFixedLayoutSize:`, `_setViewScale:`); a
// device's density is `_setOverrideDeviceScaleFactor:` (COMPATIBILITY.md).
// Hover and pointer stay a Mac's: for touch, the page goes to the Simulator
// or a phone (ScreenPhone.swift).
//
// It belongs to the tab it was opened for and is let go with Developer mode.
import SwiftUI
import WebKit

@MainActor
final class Screen: ObservableObject {
    struct Device: Identifiable, Equatable {
        let name: String
        let width: Int
        let height: Int
        /// Its pixel density; none keeps the Mac's.
        let density: CGFloat?
        var id: String { name }
    }

    /// The sizes that differ, from small phone to desktop, in CSS pixels.
    static let devices = [
        Device(name: "iPhone SE", width: 375, height: 667, density: 2),
        Device(name: "iPhone 17", width: 402, height: 874, density: 3),
        Device(name: "Android", width: 412, height: 915, density: 2.625),
        Device(name: "iPhone 17 Pro Max", width: 440, height: 956, density: 3),
        Device(name: "iPad mini", width: 744, height: 1133, density: 2),
        Device(name: "iPad Air", width: 820, height: 1180, density: 2),
        Device(name: "iPad Pro 13″", width: 1032, height: 1376, density: 2),
        Device(name: "Laptop", width: 1280, height: 800, density: nil),
        Device(name: "Desktop", width: 1440, height: 900, density: nil),
    ]
    static let widths = 240...3840

    @Published private(set) var on = false
    /// In CSS pixels.
    @Published private(set) var width = 402
    /// None: the page keeps the height of the room it has.
    @Published private(set) var height: Int? = 874
    @Published private(set) var device: Device? = devices[1]
    /// The first widths of the page's layouts, from its CSS.
    @Published private(set) var edges: [Int] = []
    /// Stylesheets from another origin, whose breakpoints can't be read.
    @Published private(set) var unread = 0
    /// Elements past the viewport's sides at this width.
    @Published private(set) var overflow = 0
    /// The overflowing elements outlined in the page.
    @Published private(set) var outlined = false
    /// A Simulator is running to take the page (ScreenPhone.swift).
    @Published private(set) var simulator = false
    /// One line in place of the layout's range, for a moment.
    @Published private(set) var note: String?
    /// Every layout side by side, while it is shown (ScreenLineup.swift),
    /// and the page's frame under it while a picture is taken.
    @Published var lineup: Lineup?
    @Published var posing: CGSize?

    private(set) weak var tab: Tab?
    private(set) var fitted = ScreenFit(drawn: 1, free: 0, room: .zero)
    /// The lineup is being taken: the page is the lineup's until it is.
    var shooting = false
    private var settle: DispatchWorkItem?
    private var asked = 0
    private var watchers: [NSObjectProtocol] = []
    private static let script = Bundled.script("screens.js")

    func open(_ tab: Tab) {
        self.tab = tab
        on = true
        watchSimulator()
        apply()
        later()
    }

    func close() {
        guard on else { return }
        if let tab, let web = tab.built {
            web.evaluateJavaScript(Bundled.configured(Self.script, with: ["action": "clear"]), in: nil, in: .defaultClient, completionHandler: nil)
            Self.set(web, "_setViewScale:", 1)
            Self.set(web, "_setOverrideDeviceScaleFactor:", 0)
            Self.lay(web, out: Self.viewSize, size: nil)
            web.pageZoom = PageZoom.absolute(tab.zoom)
        }
        for watcher in watchers { NSWorkspace.shared.notificationCenter.removeObserver(watcher) }
        watchers = []
        settle?.cancel()
        asked += 1
        on = false; outlined = false; overflow = 0; edges = []; unread = 0; note = nil; lineup = nil; posing = nil
        fitted = ScreenFit(drawn: 1, free: 0, room: .zero)
    }

    /// A width from the ruler, a key or the field: free of any device, the
    /// height kept only while it is a device's.
    func resize(_ wanted: Int) {
        let next = min(max(wanted, Self.widths.lowerBound), Self.widths.upperBound)
        guard next != width || device != nil else { return }
        device = nil; height = nil
        width = next
        apply()
        later()
    }

    func pick(_ chosen: Device?) {
        device = chosen
        if let chosen { width = chosen.width; height = chosen.height } else { height = nil }
        apply()
        later()
    }

    /// Portrait to landscape and back: the device stays, turned.
    func turn() {
        guard let height else { return }
        (width, self.height) = (height, width)
        apply()
        later()
    }

    /// How the stage draws the page (ScreenRuler.swift).
    func fit(_ next: ScreenFit) {
        guard on, next != fitted else { return }
        fitted = next
        apply()
        later()
    }

    func outline() {
        outlined.toggle()
        measure(reveal: outlined)
    }

    /// After a load: the page's sheets and its layout are new.
    func loaded() {
        guard on else { return }
        apply()
        measure()
    }

    func say(_ line: String) {
        note = line
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.note == line { self?.note = nil }
        }
    }

    func apply() {
        guard on, !shooting, let web = tab?.built else { return }
        // Laid out at the size asked for, exactly, whatever the frame: the
        // viewport and its media queries are that width. That layout leaves
        // the page zoom out and draws it on top, so the zoom moves into the
        // view scale while Screens is on.
        guard fitted.free > 0 else { return }
        let drawn = max(fitted.drawn, 0.01)
        Self.lay(web, out: Self.fixed, size: CGSize(width: width, height: height ?? fitted.free))
        if web.pageZoom != 1 { web.pageZoom = 1 }
        Self.set(web, "_setViewScale:", drawn)
        // The page reads the factor times the view scale; a device's own is
        // what it should read. Its pixels are then the device's, whatever
        // the size the page is drawn at.
        Self.set(web, "_setOverrideDeviceScaleFactor:", device?.density.map { Self.factor($0, over: drawn) } ?? 0)
    }

    /// Reads the page once the width has stopped changing and the page has
    /// been laid out at it: a drag is many widths, and only the last is
    /// worth a look.
    func later() {
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.measure() }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func measure(reveal: Bool = false) {
        guard on, let web = tab?.built, !web.isLoading else { return }
        asked += 1
        let token = asked
        let args: [String: Any] = ["action": "measure", "show": outlined, "reveal": reveal, "colour": Palette.dangerCSS]
        web.evaluateJavaScript(Bundled.configured(Self.script, with: args), in: nil, in: .defaultClient) { [weak self] result in
            guard let self, self.asked == token, case .success(let value) = result,
                  let body = value as? [String: Any] else { return }
            self.edges = (body["edges"] as? [Int]) ?? []
            self.unread = (body["unread"] as? Int) ?? 0
            self.overflow = (body["overflow"] as? Int) ?? 0
            if self.overflow == 0 { self.outlined = false }
        }
    }

    /// Whether a Simulator is running, told by the Mac as apps come and go
    /// rather than asked on every frame.
    private func watchSimulator() {
        simulator = ScreenPhone.simulatorRunning
        guard watchers.isEmpty else { return }
        let centre = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            watchers.append(centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.simulator = ScreenPhone.simulatorRunning }
            })
        }
    }

    /// The range of widths of the layout `width` is in, from the breakpoints
    /// around it; none without breakpoints.
    static func range(of width: Int, in edges: [Int]) -> String? {
        let below = edges.last { $0 <= width }
        let above = edges.first { $0 > width }
        switch (below, above) {
        case let (low?, high?): return "\(low) – \(high - 1)"
        case let (low?, nil): return "≥ \(low)"
        case let (nil, high?): return "< \(high)"
        default: return nil
        }
    }

    /// The factor that, times the view scale, is the density exactly. WebKit
    /// multiplies in single precision, and a quotient a hair off left a
    /// page reading 2.9999998, which `>= 3` refuses.
    static func factor(_ density: CGFloat, over drawn: CGFloat) -> CGFloat {
        let wanted = Swift.Float(density), scale = Swift.Float(drawn)
        var guess = wanted / scale
        for _ in 0..<8 where guess * scale != wanted {
            guess = guess * scale < wanted ? guess.nextUp : guess.nextDown
        }
        return CGFloat(guess)
    }

    /// `_WKLayoutMode`: the view's size, or a size of its own.
    static let viewSize: UInt = 0
    static let fixed: UInt = 1

    static func lay(_ web: WKWebView, out mode: UInt, size: CGSize?) {
        let layout = NSSelectorFromString("_setLayoutMode:")
        let sized = NSSelectorFromString("_setFixedLayoutSize:")
        guard web.responds(to: layout), web.responds(to: sized) else { return }
        if let size {
            typealias Sizer = @convention(c) (AnyObject, Selector, CGSize) -> Void
            unsafeBitCast(web.method(for: sized), to: Sizer.self)(web, sized, size)
        }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(web.method(for: layout), to: Setter.self)(web, layout, mode)
    }

    /// Outside the public framework, so asked first (COMPATIBILITY.md).
    static func set(_ web: WKWebView, _ name: String, _ value: CGFloat) {
        let set = NSSelectorFromString(name)
        guard web.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        unsafeBitCast(web.method(for: set), to: Setter.self)(web, set, value)
    }
}

/// How the stage draws the page: points on screen for a CSS pixel, the
/// page's zoom and any shrink to the room in one, the height in CSS pixels
/// of a page that keeps the room's, and the room itself.
struct ScreenFit: Equatable {
    let drawn: CGFloat
    let free: Int
    let room: CGSize
}

extension Browser {
    /// Screens from the dock or the keyboard: the dock comes up with it on.
    func toggleScreens() {
        guard let tab = active else { return }
        if tab.screen.on { tab.screen.close(); return }
        guard !tab.isBlank, tab.built != nil else { return }
        developing = true
        tab.screen.open(tab)
    }
}

/// Screens in the dock. On while the tab on screen has it open.
struct ScreensTool: View {
    @ObservedObject var browser: Browser

    var body: some View {
        if let tab = browser.active {
            Lit(browser: browser, tab: tab, screen: tab.screen)
        } else {
            WorkbenchTool(icon: "ipad.and.iphone", title: "Screens", help: browser.prefs.keyHelp(.screens)) {}
                .disabled(true)
        }
    }

    private struct Lit: View {
        let browser: Browser
        @ObservedObject var tab: Tab
        @ObservedObject var screen: Screen

        var body: some View {
            WorkbenchTool(icon: "ipad.and.iphone", title: "Screens", on: screen.on, help: browser.prefs.keyHelp(.screens)) { browser.toggleScreens() }
                .disabled(tab.built == nil || tab.isBlank ? !screen.on : false)
        }
    }
}
