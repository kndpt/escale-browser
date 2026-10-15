import AppKit
import WebKit

// Escale's tabs and window, as WebKit's extension engine sees them.
//
// Tab is a Swift class and the protocols are Objective-C ones, so each tab is
// represented to WebKit by a small adapter that Extensions keeps. A tab can
// be in the row with no web view at all — asleep, or put down — and is
// reported with none; `built` is read, never `web`, which would make one.

@available(macOS 15.4, *)
@MainActor
final class ExtensionTab: NSObject, WKWebExtensionTab {
    weak var tab: Tab?
    unowned let owner: Extensions

    init(tab: Tab, owner: Extensions) {
        self.tab = tab
        self.owner = owner
    }

    private var browser: Browser? { owner.browser }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        tab.map { owner.window($0.space) }
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let tab else { return NSNotFound }
        return owner.visibleTabs(in: tab.space).firstIndex { $0.id == tab.id } ?? NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { tab?.built }
    func title(for context: WKWebExtensionContext) -> String? { tab?.title }
    func url(for context: WKWebExtensionContext) -> URL? { tab?.address }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(tab?.loading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { tab.map { $0.id == owner.activeID(in: $0.space) } ?? false }
    func isPinned(for context: WKWebExtensionContext) -> Bool { tab?.pin != nil }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { tab?.noisy ?? false }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(tab?.built?.pageZoom ?? 1) }
    func size(for context: WKWebExtensionContext) -> CGSize { tab?.built?.bounds.size ?? .zero }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext) async throws {
        guard let tab, let browser, browser.spaceID == tab.space else { return }
        if pinned, tab.pin == nil { browser.pin(tab) }
        if !pinned, tab.pin != nil { browser.unpin(tab) }
    }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext) async throws {
        tab?.magnify(to: PageZoom.relative(CGFloat(zoomFactor)))
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws {
        guard let tab, browser?.spaceID == tab.space else { return }
        // A website's tab sent to one of an extension's own pages — 1Password
        // does, once a sign-in in its tab has added the account. The page
        // can only be served to a view built from that extension's
        // configuration, so the tab is swapped for one that is, as an
        // extension's page sent to a website is (see Browser.replace).
        let url = Extensions.current(url)
        let here = tab.built?.url ?? tab.address
        if url.scheme == Extensions.scheme, here?.scheme != Extensions.scheme || here?.host != url.host, let browser {
            browser.replace(tab, going: url)
            return
        }
        tab.go(to: url)
    }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws { tab?.reload() }
    func goBack(for context: WKWebExtensionContext) async throws { tab?.back() }
    func goForward(for context: WKWebExtensionContext) async throws { tab?.forward() }

    /// Selected where it is: a parked Space's tab, when one owner serves
    /// every Space, becomes that Space's selected tab without bringing it in.
    func activate(for context: WKWebExtensionContext) async throws {
        guard let tab, let browser else { return }
        if browser.spaceID == tab.space { return browser.select(tab) }
        guard owner.shared, let row = browser.parked[tab.space], row.active != tab.id else { return }
        browser.parked[tab.space]?.active = tab.id
        browser.rememberSession(tab.space)
        let before = row.tabs.first { $0.id == row.active }.map(owner.adapter(for:))
        owner.controller.didActivateTab(self, previousActiveTab: before)
    }

    func close(for context: WKWebExtensionContext) async throws {
        guard let tab else { return }
        browser?.close(tab)
    }

    func takeSnapshot(using configuration: WKSnapshotConfiguration, for context: WKWebExtensionContext) async throws -> NSImage? {
        guard let web = tab?.built else { return nil }
        return try await web.takeSnapshot(configuration: configuration)
    }
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    unowned let owner: Extensions
    /// The Space whose row it holds.
    let space: UUID
    init(owner: Extensions, space: UUID) {
        self.owner = owner
        self.space = space
    }

    private var nsWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.frameAutosaveName == "escale" }
            ?? NSApp.mainWindow
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        owner.visibleTabs(in: space).map(owner.adapter(for:))
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { owner.activeAdapter(in: space) }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = nsWindow else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isZoomed ? .maximized : .normal
    }

    func frame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.screen?.frame ?? NSScreen.main?.frame ?? .null }

    /// Serving every Space, a window focused is its Space brought in.
    func focus(for context: WKWebExtensionContext) async throws {
        if owner.shared, let browser = owner.browser, browser.spaceID != space { browser.switchSpace(to: space) }
        NSApp.activate(ignoringOtherApps: true)
        nsWindow?.makeKeyAndOrderFront(nil)
    }
}
