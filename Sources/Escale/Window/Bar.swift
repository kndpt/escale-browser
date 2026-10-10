import SecurityInterface
import SwiftUI

// The address above the page, while the tabs are down the left — what Arc
// called developer mode.
//
// The column says which tabs there are; it says little about where the one on
// screen is. A title in a column two hundred points wide is cut off before it
// gets interesting, and the address only shows behind ⌘L. Someone working on
// a site reads the host all day, so here it sits in a bar across the top of
// the page: back, forward and reload, moved out of the column's corner to the
// head of the bar, then the site — led by its environment when the tab came
// from a bookmark that has one — then the page's own title.
//
// The bar is lower than the strip (Metrics.bar): one line of text and three
// doors, not a row of tabs. The traffic lights come up to its line, and the
// column's corner shrinks to its height, so the lights, the doors and the site
// read as one row across the window, as in Arc. It still costs the page that
// much height, which is why it is a switch in Settings › Tabs & Spaces and off unless
// asked for.
//
// The site opens a card with what there is to know and do about it: whether
// the connection is private — and, a step further in, why, with the
// certificate behind it — the address, printing, the page's zoom. It is the
// system's own popover, glass and all, rather than one of our opaque panels:
// it hangs off the bar for a moment over the page, and the page showing
// through says it is about that page. The title opens the address field, the
// same one ⌘L raises. No field of its own in the bar: two places to type an
// address would be two lists of suggestions to keep in step. Copying the
// address comes in beside the title while the pointer is over it, rather than
// waiting at the far end of the bar: it is the address being read that you
// want, and a door that is only there when asked for costs the bar nothing.
//
// Only in the column's mode. Across the top the strip already has the doors,
// and the tab being typed into is the address field.

extension Browser {
    /// The bar is on the window: the column's mode, the switch on, and no
    /// page holding the whole screen or the window (Focus Mode).
    var showsBar: Bool {
        prefs.sidebar && prefs.addressBar && !focusing && active?.immersed != true
    }

    /// The column's corner, where the lights sit: the strip's height, or the
    /// bar's while there is one.
    var corner: CGFloat {
        let metrics = ChromeMetrics(size: prefs.interfaceSize)
        return showsBar ? metrics.bar : metrics.strip
    }
}

extension Lights {
    /// How far down the window the lights' centre sits: the strip's line,
    /// or the bar's while there is one.
    static var line = centre.y

    /// The lights onto the line the window has now.
    static func follow(_ browser: Browser) {
        let metrics = ChromeMetrics(size: browser.prefs.interfaceSize)
        Lights.strip = metrics.strip
        let height = browser.showsBar ? metrics.bar : metrics.strip
        let wanted = height / 2
        guard wanted != line else {
            if let window = Links.window { again(window) }
            return
        }
        line = wanted
        if let window = Links.window { again(window) }
    }
}

/// Back, forward, reload, the site and the title, over the page.
///
/// With the column folded, the line also leads with the column's door, where
/// the column's far end was, and steps clear of the traffic lights, which no
/// longer have the column under them: back would otherwise sit behind them.
/// Folded without the bar, the line is still there with only its head — the
/// column's door and back, forward and reload — since the column that held
/// those three is gone.
struct AddressBar: View {
    @ObservedObject var browser: Browser
    /// How far the line's doors step right to clear the lights.
    var clearance: CGFloat = 0
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: clearance)
            if browser.folded {
                FoldDoor(browser: browser, folded: true)
                TabSearchDoor(prefs: browser.prefs) { browser.summon() }
            }
            Helm(browser: browser)
            if browser.showsBar, browser.tuning {
                // Settings in the page's frame: the bar names them where the
                // site would be, and has nothing of a page to offer.
                Text("Settings")
                    .font(.system(size: metrics.length(12.5), weight: .regular))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .padding(.horizontal, metrics.length(8))
                    .padding(.leading, metrics.length(8))
                    .fixedSize()
            } else if browser.showsBar, let tab = browser.active {
                // Its width before the drag area gets any, down to nothing:
                // the doors and the site are what must stay whole.
                // A pinned tab keeps its link but is never the one a destination
                // opens in (Browser.openEnvironment), so it offers none.
                Where(browser: browser, tab: tab, bookmark: tab.pin == nil ? browser.shelfTabs[tab.id] : nil)
                    .layoutPriority(1)
            }
            // What is left is title bar: the window is dragged by it, and a
            // double-click fills the screen with it. Beside the doors rather
            // than under them, where it would take their clicks.
            DragStrip()
                .frame(minWidth: metrics.length(40), maxWidth: .infinity)
            if browser.showsBar {
                DownloadDoor(downloads: browser.downloads) { browser.hoarding = true }
                ExtensionSlot(space: browser.spaceID)
                VisualDoor(browser: browser)
                CaptureDoor(browser: browser)
                DeveloperDoor(browser: browser)
            }
        }
        .padding(.horizontal, AddressBar.inset(metrics))
        .frame(height: metrics.bar)
        // On the envelope, like the column beside it: the page's own frame
        // below is the line between them (docs/DESIGN.md).
    }
}

/// Copy the page's address, from the right end of the tab row. Over the page,
/// in the column's mode, the same door comes beside the title instead (see
/// `Where`). The same action as the site card's Copy Address and ⇧⌘C, which
/// stay whatever Settings says (Tabs & Spaces › Copy address button). Watched
/// here, as `Where` is, so it comes when a blank tab gets an address; nothing
/// to copy, no button.
struct CopyDoor: View {
    let browser: Browser
    @ObservedObject var tab: Tab

    var body: some View {
        if tab.address != nil {
            CopyButton(help: browser.prefs.keyHelp(.copyAddress), label: "Copy Address", box: 26, glyph: 11, radius: 8) {
                browser.copyAddress()
            }
        }
    }
}

/// The page's environment, the site and the page's title. Watched here, not
/// from the bar: a tab is a class, and a title arriving changes nothing the
/// bar can see (see Page).
///
/// With the pointer over the title's side, Copy Address comes in at its head,
/// between the rule and the title, and the title steps right to make room.
private struct Where: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    /// The bookmark the tab was opened from, whose environment leads the line.
    let bookmark: Bookmark.ID?

    @State private var open = false
    @State private var onSite = false
    @State private var onTitle = false
    /// Anywhere over the title's side, the copy door included.
    @State private var onTitleSide = false
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        HStack(spacing: 0) {
            if let url = tab.address {
                // The chip's smaller capitals sit on the host's baseline, so
                // they read as one line rather than two centred boxes.
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    if let bookmark {
                        EnvironmentChip(bookmarks: browser.bookmarks, tab: tab, bookmark: bookmark) {
                            browser.openEnvironment($0, bookmark: bookmark, space: browser.spaceID)
                        }
                    }
                    Button { open.toggle() } label: {
                        Text(AddressBar.site(url))
                            .font(.system(size: metrics.length(12.5), weight: .regular))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                            .padding(.horizontal, metrics.length(8))
                            .frame(height: metrics.length(26))
                            .background(
                                RoundedRectangle(cornerRadius: metrics.length(8), style: .continuous)
                                    .fill(open ? Palette.wash : (onSite ? Palette.hover : .clear))
                            )
                            .contentShape(RoundedRectangle(cornerRadius: metrics.length(8), style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .onHover { onSite = $0 }
                    .help("About this site")
                    .popover(isPresented: $open, arrowEdge: .bottom) {
                        SiteCard(browser: browser, tab: tab) { open = false }
                    }
                    .fixedSize()
                }

                Rectangle()
                    .fill(Palette.hairline)
                    .frame(width: metrics.length(1), height: metrics.length(14))
                    .padding(.horizontal, metrics.length(4))

                HStack(spacing: 0) {
                    if onTitleSide, browser.prefs.copyDoor {
                        CopyButton(help: browser.prefs.keyHelp(.copyAddress), label: "Copy Address", box: 22, glyph: 11, radius: 8) {
                            browser.copyAddress()
                        }
                        .transition(.opacity)
                    }
                    Button { browser.edit() } label: {
                        Text(tab.title.isEmpty ? Address.pretty(url) : tab.title)
                            .font(.system(size: metrics.length(12.5)))
                            .foregroundStyle(onTitle ? Palette.ink.opacity(0.7) : Palette.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, metrics.length(6))
                            .frame(height: metrics.length(26))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { onTitle = $0 }
                    .help(browser.prefs.keyHelp(.openAddress))
                }
                .onHover { onTitleSide = $0 }
            }
        }
        .padding(.leading, metrics.length(8))
        .animation(Motion.quick, value: onSite)
        .animation(Motion.quick, value: onTitle)
        .animation(Motion.quick, value: onTitleSide)
        .animation(Motion.quick, value: open)
    }
}

extension AddressBar {
    /// The air at either end of the line.
    static func inset(_ metrics: ChromeMetrics) -> CGFloat { metrics.length(10) }

    /// The host as a person says it, without the www. A page with no host —
    /// a file, about:blank — is named by what it is.
    static func site(_ url: URL) -> String {
        if let host = url.host(), !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        if url.isFileURL { return "File" }
        return url.scheme ?? url.absoluteString
    }
}

/// What the site's name opens: how private the connection is, and the few
/// things that belong to this page rather than to the browser. The
/// connection's line goes a step further in, to what it means and the
/// certificate behind it.
struct SiteCard: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    let close: () -> Void

    /// One step in: the connection, said in full.
    @State private var deeper: Bool
    /// Whether this Mac trusts the site's certificate. Unknown until it has
    /// been asked, off the main thread: asking can go to the network.
    @State private var certified: Bool?

    init(browser: Browser, tab: Tab, deeper: Bool = false, close: @escaping () -> Void) {
        self.browser = browser
        self.tab = tab
        self.close = close
        _deeper = State(initialValue: deeper)
    }

    var body: some View {
        Group {
            if deeper, let safety {
                security(safety)
            } else {
                front
            }
        }
        .frame(width: 300)
        // The popover's own material shows through (Glass.swift).
        .popoverGround()
        .transition(.opacity)
        .animation(Motion.quick, value: deeper)
        .onAppear(perform: certify)
    }

    // MARK: - the card

    private var front: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let url = tab.address {
                Text(AddressBar.site(url))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
            }
            VStack(spacing: 1) {
                if let safety {
                    Entry(safety.symbol, safety.title, mark: "chevron.right", tint: safety.tint) {
                        deeper = true
                    }
                }
                Entry("doc.on.doc", "Copy Address", keys: browser.prefs.keys(.copyAddress)) {
                    after { browser.copyAddress() }
                }
                if let scheme = tab.address?.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                    Entry("externaldrive", "Site Data…") {
                        after { browser.showSiteData() }
                    }
                    Entry("trash", "Reset Site Data…") {
                        after { SiteData.ask(tab, in: browser) }
                    }
                }
            }
            .padding(6)
            Divider().overlay(Palette.hairline)
            VStack(spacing: 1) {
                Entry("printer", "Print…", keys: browser.prefs.keys(.print)) {
                    after { browser.printPage() }
                }
                zoom
            }
            .padding(6)
        }
    }

    /// The page's size, remembered for the site (see Tab.rememberZoom). The
    /// number puts it back to 100%.
    private var zoom: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .frame(width: 14)
            Text("Zoom")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 0)
            Door(icon: "minus", help: browser.prefs.keyHelp(.zoomOut)) { browser.zoom(by: 1 / 1.1) }
            Button { browser.resetZoom() } label: {
                Text("\(Int((tab.zoom * 100).rounded()))%")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
                    .frame(width: 40)
            }
            .buttonStyle(.plain)
            .help(browser.prefs.keyHelp(.resetZoom))
            Door(icon: "plus", help: browser.prefs.keyHelp(.zoomIn)) { browser.zoom(by: 1.1) }
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(height: 30)
    }

    // MARK: - one step in

    private func security(_ safety: Safety) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Door(icon: "arrow.left", help: "Back") { deeper = false }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Security")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Palette.ink)
                    if let url = tab.address {
                        Text(AddressBar.site(url))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                    }
                }
                Spacer(minLength: 0)
                Door(icon: "xmark", help: "Close") { close() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)

            Divider().overlay(Palette.hairline)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: safety.symbol)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(safety.tint)
                    .frame(width: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(safety.title)
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(Palette.ink)
                    Text(safety.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, safety.trust == nil ? 14 : 6)

            if let trust = safety.trust {
                Entry(
                    certified == false ? "xmark.rectangle" : "checkmark.rectangle",
                    certified == false ? "Certificate is not valid" : "Certificate is valid",
                    mark: "arrow.up.forward.square"
                ) {
                    after { SiteCard.show(trust) }
                }
                .padding(6)
            }
        }
    }

    // MARK: - the connection

    /// What there is to say about the connection, from a page's own address
    /// and what WebKit knows of how it came.
    private struct Safety {
        let symbol: String
        let title: String
        let detail: String
        let tint: Color
        /// The certificate the page came with, for an https page.
        let trust: SecTrust?
    }

    /// Asked when the card opens: a page that pulls in something over plain
    /// http after that is not worth a card that changes under you.
    private var safety: Safety? {
        switch tab.address?.scheme {
        case "https":
            let trust = tab.built?.serverTrust
            // Only a certificate this Mac refused and you let through anyway
            // (see Dialogs.trust) gets this far untrusted.
            if certified == false {
                return Safety(
                    symbol: "lock.open", title: "Connection is not secure",
                    detail: "This site's certificate isn't trusted by this Mac. Someone could be reading what you send.",
                    tint: Palette.unsafe, trust: trust
                )
            }
            if tab.built?.hasOnlySecureContent == false {
                return Safety(
                    symbol: "lock.trianglebadge.exclamationmark", title: "Parts of this page are not secure",
                    detail: "The page came privately, but some of what it shows was fetched over plain http, where anyone on the network could read or change it.",
                    tint: Palette.unsafe, trust: trust
                )
            }
            return Safety(
                symbol: "lock", title: "Connection is secure",
                detail: "Your information (for example, passwords or credit card numbers) is private when it is sent to this site.",
                tint: Palette.safe, trust: trust
            )
        case "http":
            return Safety(
                symbol: "lock.open", title: "Connection is not secure",
                detail: "Don't enter passwords or credit card numbers here: anything sent to this site can be read on the way.",
                tint: Palette.unsafe, trust: nil
            )
        default:
            return nil
        }
    }

    /// Asks whether this Mac trusts the certificate, the way it would for
    /// any app. Off the main thread: the answer can need a revocation check.
    private func certify() {
        guard certified == nil, let trust = tab.built?.serverTrust else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = SecTrustEvaluateWithError(trust, nil)
            DispatchQueue.main.async { certified = ok }
        }
    }

    /// The system's own certificate sheet, over the window.
    private static func show(_ trust: SecTrust) {
        guard let window = Links.window else { return }
        SFCertificatePanel.shared().beginSheet(
            for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil, trust: trust, showGroup: false
        )
    }

    /// The card goes first, then the thing is done: a print panel or a sheet
    /// coming up under a popover still on its way out lands behind it.
    private func after(_ act: @escaping () -> Void) {
        close()
        DispatchQueue.main.async(execute: act)
    }

    /// One line of the card. Without an action it only says something; with
    /// a tint it says it in colour, on a wash of the same. A mark at the end
    /// says where it leads.
    private struct Entry: View {
        let symbol: String
        let title: String
        var keys = ""
        var mark: String?
        var tint: Color?
        var act: (() -> Void)?

        @State private var hovering = false

        init(_ symbol: String, _ title: String, keys: String = "", mark: String? = nil, tint: Color? = nil, act: (() -> Void)? = nil) {
            self.symbol = symbol
            self.title = title
            self.keys = keys
            self.mark = mark
            self.tint = tint
            self.act = act
        }

        /// Over glass, a shade of the ink rather than an opaque grey, so the
        /// page still shows through the line under the pointer.
        private var ground: Color {
            if let tint { return tint.opacity(hovering ? 0.2 : 0.14) }
            return hovering && act != nil ? Palette.ink.opacity(0.07) : .clear
        }

        var body: some View {
            Button { act?() } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(tint ?? Palette.muted)
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(tint ?? Palette.ink)
                Spacer(minLength: 0)
                if !keys.isEmpty {
                    Text(keys)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                }
                if let mark {
                    Image(systemName: mark)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(tint ?? Palette.muted)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ground))
            .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(act == nil)
            .onHover { hovering = $0 }
        }
    }
}
