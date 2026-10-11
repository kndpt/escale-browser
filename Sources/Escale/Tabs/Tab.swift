import Combine
import ImageIO
import SwiftUI
import WebKit

// One web view per tab, kept alive for as long as the tab is. Switching tabs
// takes the old view out of the window and puts the new one in — the page does
// not reload, does not lose its scroll position, and does not forget what you
// typed into it. That is the whole trick behind switching feeling instant.
//
// Kept alive, that is, while it is worth what it costs. A tab nobody has
// looked at for half an hour gives its view back (see `sleep(picture:)`) and
// keeps what it takes to come back exactly where it was.

enum Web {
    /// What every view says it is after "AppleWebKit … (KHTML, like Gecko)"
    /// — web tabs and extension views alike (see Extensions.init).
    ///
    /// The version is the Safari this Mac has, since its WebKit is the one
    /// every tab runs on. A fixed number went out of date with every macOS:
    /// a page told "Safari 26" by an engine that is Safari 18 sends what the
    /// engine can't run.
    static let userAgentName = "Version/\(safariVersion) Safari/605.1.15"

    private static var safariVersion: String {
        for path in ["/System/Cryptexes/App/System/Applications/Safari.app", "/Applications/Safari.app"] {
            if let version = Bundle(path: path)?.infoDictionary?["CFBundleShortVersionString"] as? String {
                return version
            }
        }
        // Safari can't be read: say the Safari this macOS shipped with, the
        // oldest its WebKit can be. Under-claiming gets a page older code
        // that still runs; over-claiming is what this avoids.
        //
        // This hardly ever runs. Safari can't be removed from modern macOS,
        // so reading the installed Safari above should always work. The
        // formula only matters if that read fails.
        //
        // From macOS 26 Safari shares its number; before, it was 3 ahead (14 -> 17, 15 -> 18).
        let os = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return os >= 26 ? "\(os).0" : "\(os + 3).0"
    }

    /// One pool for every tab. The property is deprecated and said to do
    /// nothing now, but a configuration without it gets a pool of its own
    /// when its view is made — so every new tab started a web process from
    /// cold, fonts registered and all, on the main thread, before its page
    /// could begin: 41 to 59 ms from a bookmark or Return to the load
    /// starting, the window stuck meanwhile. Sharing one lets WebKit have
    /// the next process ready: 9 to 10 ms, for the same memory and the same
    /// number of processes (measured with ./bench bookmark URL new).
    /// Its deprecation warning is silenced here and in `share`, where the
    /// use is deliberate, not across the file; a toolchain before Swift 6.4
    /// has no `@diagnose` and still shows it.
    #if hasAttribute(diagnose)
    @diagnose(DeprecatedDeclaration, as: ignored)
    #endif
    static let pool = WKProcessPool()

    #if hasAttribute(diagnose)
    @diagnose(DeprecatedDeclaration, as: ignored)
    #endif
    private static func share(_ config: WKWebViewConfiguration) { config.processPool = pool }

    /// `space`: the space the tab belongs to, when it is not the one on
    /// screen — a parked row made ahead of time (see Spaces.swift).
    /// `store`: a shy tab's own, for one opened from it — a link followed
    /// out of a private page is still signed in to whatever that page was.
    static func configuration(shy: Bool = false, space: UUID? = nil, store: WKWebsiteDataStore? = nil) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        // The real store, not the ephemeral one: staying signed in between
        // launches is the difference between a browser and a preview pane. A
        // shy tab gets its own store, which exists only while it does — its own
        // cookies, its own sign-ins, and nothing left behind when it closes.
        // With spaces on, each space's tabs share a store of that space's.
        config.websiteDataStore = store ?? (shy ? .nonPersistent() : MainActor.assumeIsolated { Spaces.store(for: space ?? Spaces.current) })
        share(config)
        // Chrome extensions see every page but a private one, unless Settings
        // › Extensions says they may. The controller has to be there when the
        // view is made; it can't be added after.
        if #available(macOS 15.4, *), !shy || Store.settings.bool(forKey: "extensions.private") {
            MainActor.assumeIsolated { Extensions.attach(config, space: space ?? Spaces.current) }
        }
        // Left alone, WKWebView says only "AppleWebKit … (KHTML, like Gecko)" —
        // no browser, no version. Google reads that as something it doesn't
        // recognise and serves the stripped-back page from a decade ago:
        // no side panel, no dark mode, none of the modern tabs. Naming a
        // version turns it into the same string Safari sends, and the modern
        // page comes back.
        config.applicationNameForUserAgent = Web.userAgentName
        config.allowsAirPlayForMediaPlayback = true
        // Off by default on macOS, which is why a full-screen button on a video
        // did nothing at all: the page asks, and WebKit refuses without a word.
        config.preferences.isElementFullscreenEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = .audio
        if Store.testing, !Store.measuring { config.preferences.inactiveSchedulingPolicy = .none }
        inspector(config.preferences)
        if Store.testing { mockCapture(config.preferences) }
        return config
    }

    /// Every page view there is, for the bench.
    @MainActor static let pages = NSHashTable<PageView>.weakObjects()

    /// A test run's camera and microphone are WebKit's own synthetic ones: a
    /// scenario about calls gets real capture tracks without asking the Mac for
    /// access or opening a device. The name is outside the public framework,
    /// so it is asked first (see COMPATIBILITY.md).
    static func mockCapture(_ preferences: WKPreferences) {
        let set = NSSelectorFromString("_setMockCaptureDevicesEnabled:")
        guard preferences.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(preferences.method(for: set), to: Setter.self)(preferences, set, true)
    }

    /// WebKit's "developer extras": Inspect Element in a page's right-click
    /// menu, and the Web Inspector the View menu opens (see Inspector.swift).
    /// isInspectable alone only lets Safari's Develop menu reach the page.
    /// The name is outside the public framework, so it is asked first.
    static func inspector(_ preferences: WKPreferences, on: Bool = true) {
        let set = NSSelectorFromString("_setDeveloperExtrasEnabled:")
        guard preferences.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(preferences.method(for: set), to: Setter.self)(preferences, set, on)
    }
}

@MainActor
final class Tab: ObservableObject, Identifiable {
    let id = UUID()
    let media = Media() // Audible page lifetime; see Media.swift.
    let jsonReader = JSONReader()
    let siteStorage = SiteStorage()
    let visual = VisualPick()
    let area = AreaPick()
    let capture = PageCapture()
    /// The API Calls panel's collection, open by hand (Calls.swift).
    let calls = Calls()
    private(set) var dataRevision = 0
    func invalidatePageData(preservingMedia: Bool = false) {
        formsReady = false
        if !preservingMedia { media.reset() }
        dataRevision += 1; jsonReader.reset(); siteStorage.close(); visual.stop(); area.stop(); capture.close()
    }

    /// The page. Built the first time anyone asks for it, not when the tab
    /// is — a session of twenty tabs coming back is twenty objects, not
    /// twenty web views and their processes fighting the first frame.
    var web: PageView {
        if let built { return built }
        let view = build()
        built = view
        return view
    }
    /// The web view if there is one yet, for the callers that must not be
    /// the reason there is.
    private(set) var built: PageView?
    /// Counts what this tab has asked its page for: a load, a wake, a
    /// reload, back, forward, stop. Work scheduled for one of them — a retry, the check
    /// after a wake — does nothing once a later one has been asked for, or
    /// once the view it was for has gone (see `current`). A weak capture
    /// only keeps a closed tab from being kept alive; this keeps a tab that
    /// has moved on from being sent back, or given a view it let go.
    private var generation = 0

    private func advanceGeneration(preservingMedia: Bool = false) {
        generation += 1
        invalidatePageData(preservingMedia: preservingMedia)
    }
    /// The load a wake is holding back until the stage takes the view (see
    /// `load`), by its generation. Until it is handed over nothing loads,
    /// and the view has nothing in it — no page, no history.
    private var holding: Int?
    /// True from a wake, or a recovery, until its page has been handed what
    /// to show: up to about a second. Not a page to put to sleep yet — the
    /// history it would keep is the empty view's, not the one it was woken
    /// with, and every wake after that would come back white.
    var waking: Bool { built != nil && holding == generation }
    private let configuration: WKWebViewConfiguration

    /// Whether its page was made with the extension controller in it — every
    /// ordinary tab, and a private one only when extensions were allowed
    /// there as it was made (a controller can't be added to a page later).
    @available(macOS 15.4, *)
    var carriesExtensions: Bool { configuration.webExtensionController != nil }
    /// Where its cookies and sign-ins are kept.
    var store: WKWebsiteDataStore { configuration.websiteDataStore }
    /// Whoever handles navigation and windows for this page; applied when
    /// the page is built, whenever that is.
    weak var delegate: (WKNavigationDelegate & WKUIDelegate)? {
        didSet {
            built?.navigationDelegate = delegate
            built?.uiDelegate = delegate
        }
    }
    /// The stylesheet a page not yet built is to be armed with.
    private var veils = ""

    @Published private(set) var title = ""
    @Published private(set) var address: URL? {
        didSet { if oldValue != address { siteStorage.close(); visual.stop(); area.stop(); capture.close(); dataRevision += 1 } }
    }
    @Published private(set) var progress: Double = 0
    @Published private(set) var loading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// Set when the page never arrived — no host, no network, a refused
    /// connection. Shown in place of the page rather than in a dialog.
    @Published var failure: String? {
        didSet { if failure == nil { failedAddress = nil } }
    }
    /// Where the load that failed was going. WebKit's own `url` goes back to
    /// the page before it, which is still what the view holds; the tab keeps
    /// naming the place it was sent to, and Retry goes there.
    private(set) var failedAddress: URL?
    /// How far down the page you are, nought to one. The tab's own pill fills
    /// with it.
    @Published var reading: Double = 0

    /// True while the page has been stripped back to its article.
    @Published private(set) var reader = false

    /// Leaving reading mode reloads rather than putting the old markup back:
    /// restoring the HTML gives you a page that looks right and does nothing,
    /// because every listener the page had was thrown away with it.
    func toggleReader(_ done: @escaping (Bool) -> Void) {
        guard !isBlank else {
            done(false)
            return
        }
        guard !reader else {
            reader = false
            web.reload()
            done(true)
            return
        }
        web.evaluateJavaScript(Reader.script) { [weak self] answer, _ in
            let worked = (answer as? String) == "read"
            if worked { self?.reader = true }
            done(worked)
        }
    }

    /// The site's icon, for tabs set to wear one. From the cache the moment
    /// the tab has an address, and from the page a moment after it loads.
    @Published var icon: NSImage?

    /// The letter a pinned tab is reduced to, and what a tab shows in place of
    /// an icon it doesn't have yet.
    var monogram: String {
        let host = address?.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
        return host.first.map { String($0).uppercased() } ?? "•"
    }

    private func adoptIcon() {
        guard let host = address?.host()?.lowercased() else { return }
        icon = Favicons.shared.cached(host)
    }

    /// True while the caret is in something on the page that takes typing.
    @Published var typing = false
    /// True while the page has taken over the screen.
    @Published var immersed = false

    /// True while this tab's page is out in the little window.
    @Published var floating = false

    /// A sideways swipe in progress, for the disc that shows it.
    @Published var pull: Pull?

    /// Remembered for the site, not for the tab: setting a paper's type to
    /// 125% once should be the last time you think about it.
    func rememberZoom() {
        guard let host = address?.host(), !shy else { return }
        if abs(zoom - 1) < 0.01 {
            Store.settings.removeObject(forKey: Store.zoomKey(host, space: space))
        } else {
            Store.settings.set(Double(PageZoom.absolute(zoom)), forKey: Store.zoomKey(host, space: space))
        }
    }

    func applyRememberedZoom() {
        let value = rememberedZoom(for: built?.url ?? address)
        guard let web = built else { return }
        if abs(value - web.pageZoom) > 0.004 { web.pageZoom = value }
        zoom = PageZoom.relative(value)
    }

    private func rememberedZoom(for url: URL?) -> CGFloat {
        let kept = url?.host().flatMap { Store.settings.object(forKey: Store.zoomKey($0, space: space)) as? Double }
        return PageZoom.remembered(kept)
    }

    /// How much bigger the page is drawn, relative to Escale's reference.
    /// Not a magnifying glass over the rendered page — the page is laid out again at this size, so text
    /// stays as sharp at 200% as it was at 100%.
    @Published private(set) var zoom: CGFloat = 1

    /// Where the page is and which way it just went, for anything that wants
    /// to follow along.
    var onScroll: ((Tab, Double, Double) -> Void)?
    var onPanelFocus: ((Tab) -> Void)?
    var onPanelEnd: ((Tab) -> Void)?
    var onZoom: ((Tab, CGFloat) -> Void)?
    /// The resolved address under the pointer, or nil when it leaves a link.
    var onLink: ((Tab, String?) -> Void)?
    /// Text selected with the mouse, and where; nil when it goes (see SelectionMenu.swift).
    var onSelection: ((Tab, SelectionSpot?) -> Void)?

    /// True while something on the page is making noise, so the row can say
    /// which tab it is coming from.
    @Published var noisy = false {
        didSet { if noisy != oldValue { onPresence?() } }
    }
    /// Sound or capture started or stopped: the rail's mark for its Space may
    /// have changed (see Presence.swift).
    var onPresence: (() -> Void)?

    /// What the page hands back when you point at something and click it.
    var onPick: ((Tab, String, String, String) -> Void)?
    /// The caret has entered or left one of the sign-in boxes; where the box
    /// is, in the web view's points, or nil when it has left.
    var onField: ((Tab, CGRect?) -> Void)?
    /// The site the sign-in was sent from — not the one it landed on —
    /// then the name and the password.
    var onCredentials: ((Tab, String, String, String) -> Void)?
    var onPickEnd: ((Tab) -> Void)?
    var onPickTrouble: ((Tab, String) -> Void)?
    /// Right-click landed on an image. WebKit's own menu offers to copy or
    /// download it and then, on at least some sites, does neither — see
    /// ImageMenu.swift for why this is built rather than patched.
    var onImageMenu: ((Tab, URL) -> Void)?
    var searchName: (() -> String?)?
    var onSearch: ((Tab, String) -> Void)?
    /// "Add to Escale" was pressed on the Chrome Web Store page this tab shows.
    var onStoreAdd: ((Tab) -> Void)?
    /// The middle button was let go over a link. The browser opens it in a
    /// tab of its own beside this one, without leaving the page you are on.
    var onMiddleClick: ((Tab, URL) -> Void)?
    /// Sent where this tab's view can't go: from an extension's page to the
    /// web or another extension, or from the web to an extension's page.
    /// WebKit keeps each kind of view to its own pages, so the tab has to be
    /// swapped for one built for the address (see Browser.replace).
    var onCross: ((Tab, URL) -> Void)?
    /// What the browser keeps watching on this tab: its address for the
    /// session, its title for history (see Browser.prepare). Kept here rather
    /// than in the browser's own bag, which lives as long as the app and
    /// held two of them for every tab ever made: `close` cancels them, and a
    /// tab let go without being closed takes them along when it is freed.
    var followers: [AnyCancellable] = []
    /// The extension whose store page has its own "Add to Escale" button in
    /// place — so the bar at the bottom of the window doesn't offer it twice.
    @Published var storePlaced: String?

    private let relay = ScrollRelay()
    private let veils_ = VeilRelay()
    private let forms = FormRelay()
    /// Password messages and fills belong only to the document WebKit has
    /// committed. A provisional load can leave the previous document alive
    /// while the tab names its failed destination, so navigation closes this
    /// gate until another document commits.
    private var formsReady = false
    /// The host of the document that last committed. A load that ends
    /// without replacing that document gives it its forms back only while
    /// the view still names this host, never a destination it did not reach.
    private var committedHost: String?
    private let images = ImageRelay()
    private let shop = StoreRelay()
    private let middles = MiddleRelay()
    private let passkeyRelay = PasskeyRelay()
    private let hovered = HoveredLink()
    private let selected = SelectionWatch()
    private let ears = AudioWatch()
    private var lastY: Double = 0

    /// A tab that keeps nothing: its own cookies, no history, no place in the
    /// session. Signed in as nobody, and forgotten when it goes.
    let shy: Bool

    /// A tab a script opened through the bench, beside yours. Signed in as
    /// you, so it sees what you see — but never selected for you, never in
    /// the session or the history, and gone when the script is done.
    let bench: Bool

    /// The tab whose page opened this one, when a script did. Sign-in flows
    /// hand you back to it when they are done.
    var opener: Tab.ID?

    /// The tab whose page a link was opened from with ⌘-click or the middle
    /// button. Kept apart from `opener`, which also says who may answer a
    /// sign-in flow: a link opened beside a page has no such right. Closing
    /// this tab goes back to that page (see Browser.close). Not saved with
    /// the session, so a restored row falls back to the neighbour.
    var origin: Tab.ID?

    /// The space whose row it is in, fixed when it is made: its cookies, its
    /// session and its downloads folder are that space's, whichever space is
    /// on screen by the time its page calls back (see Spaces.swift).
    let space: UUID

    /// One letter, when the tab has been pinned. A pinned tab keeps its place
    /// at the head of the row and gives up its title for that letter — which
    /// is all you need for the five or six pages you keep open all day.
    /// Source identity of an imported address; no source page state is kept.
    var migration: UUID?
    @Published var pin: String?

    /// A name you gave it, in place of whatever the page calls itself. It
    /// stays through navigation: a tab you named is a tab you are keeping for
    /// a job, not for a page.
    @Published var name: String?

    /// When you last looked at it. The summon lists pages by this, because
    /// what you were just reading is what you are most likely to want back.
    private(set) var touched = Date()
    /// Creation/restoration alone is not a visit for New Tab suggestions.
    private(set) var visited = false

    /// Set on a tab brought back from the last session and not yet opened. It
    /// has a name and an address in the row, and costs nothing until you go to
    /// it — which is the difference between a browser that starts in half a
    /// second with twenty tabs and one that doesn't.
    private(set) var pending: URL?

    /// For a tab put to sleep for not being looked at: the page's own history
    /// — the back list, the page, where it was scrolled to — handed to the
    /// view built to wake it, so it opens exactly where this one was left.
    private var memory: Any?
    /// The last picture of that page, compressed, for the moment it wakes.
    private var picture: Data?
    /// What that picture weighs, for `bench caches` and the pictures' budget.
    var pictureBytes: Int { picture?.count ?? 0 }
    /// The picture let go while the tab sleeps on: it wakes without one
    /// (see Pictures.swift).
    func forgetPicture() { picture = nil }
    /// That picture, over the stage while the page is rebuilt underneath it:
    /// coming back to a tab that slept starts from what you left, not white.
    @Published private(set) var cover: NSImage?
    /// A wake or process recovery stays covered until WebKit can show content.
    @Published private(set) var returning = false

    private var watch: [NSKeyValueObservation] = []

    /// A tab that has never been anywhere shows the address field instead of a
    /// page. It still owns a web view — built now, warm by the time it's needed.
    var isBlank: Bool { address == nil }

    /// The title if the page has offered one, the address until it does. A tab
    /// that says nothing at all for the first second of every load is a tab you
    /// can't find your way back to.
    var label: String {
        if let name, !name.isEmpty { return name }
        if !title.isEmpty { return title }
        if let address { return Address.pretty(address) }
        return "New Tab"
    }

    /// `space`: the space it belongs to; the one on screen unless told.
    init(shy: Bool = false, bench: Bool = false, space: UUID? = nil, configuration: WKWebViewConfiguration? = nil) {
        self.shy = shy
        self.bench = bench
        let space = space ?? Spaces.current
        self.space = space
        self.configuration = configuration ?? Web.configuration(shy: shy, space: space)
    }

    private func build() -> PageView {
        let web = PageView(frame: .zero, configuration: configuration)
        web.pageZoom = rememberedZoom(for: address)
        zoom = PageZoom.relative(web.pageZoom)
        // The trackpad pinch is WebKit's own: it magnifies what is on screen
        // and lets you move around inside it, the way pinching does everywhere
        // else on a Mac. ⌘+ and ⌘- are the other thing — they lay the page out
        // again at a bigger size — and both are worth having.
        web.allowsMagnification = true
        // WebKit's own two-finger swipe stays off. It drags the page across
        // the window with a picture of the last one behind it; ours is in
        // PageView, and it moves nothing but a disc.
        web.allowsBackForwardNavigationGestures = false
        web.onPull = { [weak self] pull in self?.pull = pull }
        web.onTouch = { [weak self] in
            guard let self else { return }
            self.onPanelFocus?(self)
        }
        web.searchName = { [weak self] in self?.searchName?() }
        web.onSearch = { [weak self] text in
            guard let self else { return }
            self.onSearch?(self, text)
        }
        web.holdForFirstFrame()
        // Pages follow the appearance of the window they are drawn in, and the
        // window follows Settings › Appearance — so a site that honours
        // prefers-color-scheme goes dark with the frame, and not otherwise.
        // Safari's Develop menu can reach it, and so can the page's own
        // Inspect Element — a configuration handed over by an opener included.
        if #available(macOS 13.3, *) { web.isInspectable = true }
        Web.pages.add(web)
        Web.inspector(web.configuration.preferences)
        web.navigationDelegate = delegate
        web.uiDelegate = delegate

        // A tab opened by a link inherits its opener's configuration, handlers
        // included, so each name is cleared before being claimed — registering
        // one twice is a hard crash rather than an error.
        let controller = web.configuration.userContentController
        controller.removeScriptMessageHandler(forName: ScrollRelay.name)
        controller.removeScriptMessageHandler(forName: VeilRelay.name)
        controller.removeScriptMessageHandler(forName: FormRelay.name)
        controller.removeScriptMessageHandler(forName: ImageRelay.name)
        controller.removeScriptMessageHandler(forName: StoreRelay.name)
        controller.removeScriptMessageHandler(forName: PasskeyRelay.name)
        controller.removeScriptMessageHandler(forName: HoveredLink.name, contentWorld: .defaultClient)
        controller.removeScriptMessageHandler(forName: SelectionWatch.name, contentWorld: .defaultClient)
        controller.removeScriptMessageHandler(forName: MiddleRelay.name)
        controller.add(relay, name: ScrollRelay.name)
        controller.add(veils_, name: VeilRelay.name)
        controller.add(images, name: ImageRelay.name)
        controller.add(shop, name: StoreRelay.name)
        controller.add(forms, name: FormRelay.name)
        controller.addScriptMessageHandler(passkeyRelay, contentWorld: .page, name: PasskeyRelay.name)
        hovered.tab = self
        controller.add(hovered, contentWorld: .defaultClient, name: HoveredLink.name)
        selected.tab = self
        controller.add(selected, contentWorld: .defaultClient, name: SelectionWatch.name)
        controller.add(middles, name: MiddleRelay.name)
        Shield.shared.protect(controller)
        built = web
        arm(hiding: veils)

        watch = [
            web.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.title = self?.built?.title ?? "" }
            },
            web.observe(\.url, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let fresh = self.built?.url else { return }
                    // about:blank is never a destination. Putting a pinned tab
                    // to sleep loads it deliberately to make WebKit give the
                    // page back — and letting that overwrite the address is how
                    // a pinned tab lost the only thing that could bring it
                    // back, and vanished from the session altogether.
                    guard fresh.absoluteString != "about:blank" else { return }
                    self.adopt(fresh)
                }
            },
            web.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.progress = self?.built?.estimatedProgress ?? 0 }
            },
            web.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.loading = self?.built?.isLoading ?? false }
            },
            web.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.canGoBack = self?.built?.canGoBack ?? false }
            },
            web.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.canGoForward = self?.built?.canGoForward ?? false }
            },
        ] + watchPresence(web)

        relay.tab = self
        veils_.tab = self
        forms.tab = self
        passkeyRelay.tab = self
        images.tab = self
        shop.tab = self
        middles.tab = self
        ears.watch(web) { [weak self, weak web] on in
            guard let self, let web, self.built === web else { return }
            self.noisy = on
            self.media.sound(on, in: web)
        }
        return web
    }

    /// Keep the existing WebKit limits, including saved sites at either edge;
    /// changing the reference must not make Zoom In shrink an old 300% site.
    func magnify(to value: CGFloat) {
        let wanted = min(3, max(0.4, PageZoom.absolute(value)))
        if abs(wanted - web.pageZoom) > 0.004 { web.pageZoom = wanted }
        zoom = PageZoom.relative(wanted)
        rememberZoom()
        onZoom?(self, zoom)
    }

    func magnify(by factor: CGFloat) { magnify(to: PageZoom.relative(web.pageZoom) * factor) }

    /// ⌘0 undoes both kinds of zoom at once — whichever one you reached for.
    func resetZoom() {
        magnify(to: 1)
        guard web.magnification != 1 else { return }
        web.magnification = 1
        onZoom?(self, 1)
    }

    // MARK: - taking things off the page

    /// What gets injected into the *next* document: the scroll reporter, the
    /// pointing mode, and this site's stylesheet of things you have hidden. The
    /// stylesheet goes in before the document has a body, so nothing is ever
    /// seen arriving and then leaving again.
    func arm(hiding css: String) {
        veils = css
        guard let built else { return }
        let controller = built.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(ScreenShare.script)
        // Only while the reading bar is shown: it is all the scroll is told for.
        if ScrollRelay.on {
            controller.addUserScript(
                WKUserScript(source: ScrollRelay.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            )
        }
        controller.addUserScript(
            WKUserScript(source: Veiling.picker, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        controller.addUserScript(
            WKUserScript(source: FormRelay.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        if AutoScroll.on {
            controller.addUserScript(
                WKUserScript(source: AutoScroll.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            )
        }
        controller.addUserScript(
            WKUserScript(source: Swipe.calm, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        // Every frame: a swipe over an embedded map is the map's, and only the
        // map's own document can say so.
        controller.addUserScript(
            WKUserScript(source: Swipe.watch, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        controller.addUserScript(
            WKUserScript(source: ImageRelay.watch, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        // The store's "Add to Escale" only where Escale can add extensions.
        // Before macOS 15.4 it was drawn all the same, and pressing it did
        // nothing at all; Settings › Extensions says what they need instead.
        if #available(macOS 15.4, *) {
            controller.addUserScript(
                WKUserScript(source: StoreRelay.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            )
        }
        // Only while Settings says so: off, pages get nothing at all.
        if HoveredLink.on {
            controller.addUserScript(WKUserScript(
                source: HoveredLink.script, injectionTime: .atDocumentStart,
                forMainFrameOnly: false, in: .defaultClient
            ))
        }
        // Only while Settings says so, and the main frame only (see SelectionMenu.swift).
        if SelectionWatch.on {
            controller.addUserScript(WKUserScript(
                source: SelectionWatch.script, injectionTime: .atDocumentEnd,
                forMainFrameOnly: true, in: .defaultClient
            ))
        }
        // The main frame only: a middle-click on a link inside an ad iframe is
        // that frame's own business, and its link is not this tab's to open.
        controller.addUserScript(
            WKUserScript(source: MiddleRelay.watch, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        // macOS platform passkeys are scoped by relying party and app, not by
        // WebKit store. Until they can be partitioned, other spaces hide this
        // browser path so a passkey from the first cannot be offered there.
        if !FormRelay.passkeysOffered || space != Space.firstID {
            controller.addUserScript(
                WKUserScript(
                    source: FormRelay.withoutPasskeys,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                )
            )
        } else {
            // A site's passkey request is carried out by Escale itself: WebKit
            // only does that for an app's own domains (see Passkeys.swift).
            controller.addUserScript(
                WKUserScript(source: PasskeyRelay.script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        }
        guard !css.isEmpty else { return }
        controller.addUserScript(
            WKUserScript(source: Veiling.style(css), injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
    }

    /// The same stylesheet, for the page that is already up.
    func applyVeils(_ css: String) {
        built?.evaluateJavaScript(Veiling.style(css))
    }

    func startPicking() { web.evaluateJavaScript("window.__escaleVeil && window.__escaleVeil.on()") }
    func stopPicking() { web.evaluateJavaScript("window.__escaleVeil && window.__escaleVeil.off()") }

    /// From the page, in CSS pixels; passed on in points. Page zoom is the
    /// only scale between the two that matters here.
    func fieldFocused(_ rect: CGRect?) {
        guard let rect else {
            onField?(self, nil)
            return
        }
        let zoom = built?.pageZoom ?? 1
        onField?(self, CGRect(
            x: rect.minX * zoom, y: rect.minY * zoom,
            width: rect.width * zoom, height: rect.height * zoom
        ))
    }

    /// The committed page allowed to ask for or receive credentials: one
    /// that arrived over HTTPS, or a server on this Mac, which has no
    /// certificate to show. A plain HTTP page could be anyone's on the way.
    var formHost: String? {
        guard formsReady, let url = built?.url, let host = url.host()?.lowercased(),
              url.scheme == "https" || (url.scheme == "http" && Dialogs.isLoopback(host))
        else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Page-world messages cannot outlive or come from beside their committed
    /// main document, even while WebKit retains that document after a failure.
    func acceptsFormMessage(_ message: WKScriptMessage) -> Bool {
        guard formsReady, message.webView === built, message.frameInfo.isMainFrame,
              let pageHost = built?.url?.host()?.lowercased()
        else { return false }
        return message.frameInfo.securityOrigin.host.lowercased() == pageHost
    }

    /// A name and password the page has just sent — held, not yet offered.
    /// Whether the sign-in worked is only known afterwards: a page that
    /// comes back without a password box took it, one that still has the
    /// box refused it, and only the first is worth remembering.
    private var sent: (host: String, user: String, password: String, at: Date)?

    func sentSignIn(user: String, password: String) {
        // The host now, while the page is still the sign-in page: a moment
        // later it may be somewhere else entirely, and that is not where
        // the password belongs.
        guard let host = formHost else { return }
        sent = (host, user, password, Date())
    }

    /// The page has moved on — a new document has loaded, or the sign-in
    /// fields have gone. If a password went out recently and there is no
    /// longer a box for it, that is a sign-in that took.
    ///
    /// A new document is judged at once. Fields that a page removed by
    /// itself are given a moment first: a sign-in built into the page closes
    /// its form the instant you press the button and puts it back if the
    /// server says no — and offering in between is offering a password that
    /// may be wrong.
    func settleSignIn(navigated: Bool = true) {
        guard let sent else { return }
        guard Date().timeIntervalSince(sent.at) < 45 else {
            self.sent = nil
            return
        }
        guard navigated else {
            let stamp = sent.at
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                // Only if nothing newer went out in the meantime.
                guard let self, self.sent?.at == stamp else { return }
                self.settleSignIn(navigated: true)
            }
            return
        }
        // `built`, not `web`: a page let go in the meantime has no box to
        // look for, and asking must not build it another.
        built?.evaluateJavaScript("!!(window.__escaleForms && window.__escaleForms.hasPassword())") { [weak self] still, _ in
            MainActor.assumeIsolated {
                guard let self, let sent = self.sent else { return }
                // The box is still there: a refused sign-in, or the second
                // step of one. Kept for a moment longer, in case the page is
                // still on its way.
                if (still as? Bool) == true { return }
                self.sent = nil
                self.onCredentials?(self, sent.host, sent.user, sent.password)
            }
        }
    }

    /// Puts a remembered name and password where a person would have typed
    /// them. Nothing is echoed back and nothing is written down here.
    /// `done`, when given, hears back `false` when the sign-in fields or the
    /// committed site that offered them are gone by the time it runs.
    func fill(user: String, password: String, for host: String, done: ((Bool) -> Void)? = nil) {
        guard formHost == host.lowercased(), let built else {
            done?(false)
            return
        }
        built.evaluateJavaScript(
            "window.__escaleForms && window.__escaleForms.fill(`\(escape(user))`, `\(escape(password))`)"
        ) { result, _ in
            done?((result as? Bool) ?? false)
        }
    }

    func picked(selector: String, label: String, note: String) {
        onPick?(self, selector, label, note)
    }

    /// Show one hidden thing while the pointer rests on its row in the list.
    func peek(_ selector: String, keeping css: String) {
        web.evaluateJavaScript(
            "window.__escaleVeil && window.__escaleVeil.peek(`\(escape(css))`, `\(escape(selector))`)"
        )
    }

    func unpeek(_ css: String) {
        web.evaluateJavaScript("window.__escaleVeil && window.__escaleVeil.unpeek(`\(escape(css))`)")
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
    }
    func pickingEnded() { onPickEnd?(self) }
    func pickingFailed(_ reason: String) { onPickTrouble?(self, reason) }

    /// Called from the page, a few dozen times a second at most — the script
    /// already waits for a frame before it says anything.
    func scrolled(to y: Double, of ceiling: Double) {
        // Set only when the bar would move — every change redraws the tab's
        // row — and a thousandth of the bar is a fraction of a point on any
        // row: a long page otherwise redraws it for each frame of a scroll.
        let fraction = ceiling > 0 ? min(1, max(0, y / ceiling)) : 0
        let rounded = (fraction * 1000).rounded() / 1000
        if rounded != reading { reading = rounded }
        let delta = y - lastY
        lastY = y
        onScroll?(self, y, delta)
    }

    /// The address the view reports, unless a load failed and the tab is
    /// still naming the place it was sent to: the view has gone back to the
    /// page before it, and saying so would undo the navigation.
    private func adopt(_ fresh: URL) {
        guard failedAddress == nil else { return }
        let moved = fresh.host() != address?.host()
        address = fresh
        if moved { adoptIcon() }
    }

    /// The page the view shows committed: the address follows it again.
    func arrived() {
        failure = nil
        formsReady = true
        committedHost = built?.url?.host()?.lowercased()
        if let fresh = built?.url, fresh.absoluteString != "about:blank" { adopt(fresh) }
    }

    /// A load that ended without a document: cancelled, stopped, or turned
    /// into a download. The page on screen is still the committed one, so a
    /// sign-in form on it keeps its suggestions instead of waiting for a reload.
    func stayed() {
        guard failure == nil, let committedHost,
              built?.url?.host()?.lowercased() == committedHost
        else { return }
        formsReady = true
    }

    /// A load that never arrived. The tab keeps the address it was sent to,
    /// with the reason, instead of falling back to the page before it.
    func failed(_ message: String, at url: URL?) {
        formsReady = false
        failure = message
        guard let url else { return }
        failedAddress = url
        if address != url { address = url; adoptIcon() }
    }

    func go(to url: URL) {
        // Judged by the page it shows, not by how it was made: a tab an
        // extension's page opened with window.open is built from that
        // extension's configuration too. A tab with no page yet was just
        // built for where it is going, so it goes there.
        if let onCross, let here = built?.url ?? address,
           Browser.extensionHost(of: here) != Browser.extensionHost(of: url) {
            onCross(self, url)
            return
        }
        // Set straight away rather than waiting for the observer: the tab has to
        // stop being blank in the same frame the field disappears, or the empty
        // state flashes back for an instant on its way out.
        address = url
        title = ""
        failure = nil
        reading = 0
        lastY = 0
        reader = false
        typing = false
        immersed = false
        // Sent somewhere new, a sleeping tab is simply awake again — with
        // nothing of where it was before to bring back.
        pending = nil
        sleeping = false
        memory = nil
        picture = nil
        uncover()
        adoptIcon()
        advanceGeneration()
        web.pageZoom = rememberedZoom(for: url)
        zoom = PageZoom.relative(web.pageZoom)
        web.load(URLRequest(url: url))
    }

    /// Brought back from the last session: everything the row needs to draw it,
    /// and nothing fetched.
    func restore(url: URL, title: String, name: String? = nil) {
        address = url
        self.title = title
        self.name = name
        pending = url
        sleeping = false
        adoptIcon()
    }

    /// True for a tab that has a place and an address but is holding no page —
    /// brought back from the last session, or put down with ⌘W while pinned.
    var asleep: Bool { pending != nil }
    /// Only an actual discard through the sleep policy earns the Sleeping
    /// marker. Unopened session entries and closed pins have not slept.
    @Published private(set) var sleeping = false

    /// ⌘W on a pinned tab. The letter keeps its place in the row and the
    /// address is remembered; everything the page was holding is let go, so a
    /// pin you are not reading costs a line in a file and nothing else.
    func rest() {
        guard let url = address else { return }
        sleeping = false
        pending = url
        memory = nil
        picture = nil
        reading = 0
        lastY = 0
        noisy = false
        stale = false
        pull = nil
        // Loading about:blank here looked like letting the page go, and
        // wasn't: WebKit keeps the document it just left in the back-forward
        // cache — alive, suspended, and still counted by its own origin as an
        // open tab. Coming back then started a second x.com beside a first
        // that would never answer, and the second waited for it until you
        // gave up and reloaded by hand. Only tearing the view down ends the
        // page; the next wake() builds a fresh one, and a fresh one boots.
        discard()
    }

    /// Nobody has looked at this page for a while. Its view goes, as with a
    /// pin put down by hand, but its history and a picture of it stay: the
    /// view built to wake it opens the same page, at the same place, with
    /// Back still going back. What was typed and not sent is the one thing
    /// that can't come back, which is why the browser asks `unsaved` first.
    func sleep(picture: Data?) {
        guard let url = address, let built else { return }
        memory = built.interactionState
        self.picture = picture
        pending = url
        stale = false
        pull = nil
        discard()
        sleeping = true
    }

    /// Whether the page holds something typed and not yet sent — a draft, a
    /// half-filled form. Nil means the page could not answer; discarding it
    /// then could lose text that cannot be restored.
    func unsaved(_ done: @escaping (Bool?) -> Void) {
        guard let built else { return done(nil) }
        built.evaluateJavaScript(
            "(() => { const forms = window.__escaleForms; if (!forms || typeof forms.unsaved !== 'function') return null; const result = forms.unsaved(); return typeof result === 'boolean' ? result : null; })()"
        ) { value, error in
            MainActor.assumeIsolated { done(error == nil ? value as? Bool : nil) }
        }
    }

    /// The page as it looks right now, compressed. Drawn by the page's own
    /// process, so a view that is off screen — every tab but the one you are
    /// on — can still be pictured. Nil when there is nothing to draw.
    func snapshot(_ done: @escaping (Data?) -> Void) {
        guard let built else { return done(nil) }
        // One pixel per point, not the screen's two: a quarter of the pixels
        // to draw, encode and keep (see Pictures.swift).
        let config = WKSnapshotConfiguration()
        let scale = built.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        if built.bounds.width > 0 { config.snapshotWidth = NSNumber(value: Double(built.bounds.width / scale)) }
        built.takeSnapshot(with: config) { image, _ in
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return done(nil)
            }
            DispatchQueue.global(qos: .utility).async {
                let data = Tab.jpeg(cg)
                DispatchQueue.main.async { done(data) }
            }
        }
    }

    nonisolated private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.55] as CFDictionary)
        return CGImageDestinationFinalize(out) ? data as Data : nil
    }

    /// What the store page's own button should say: added, on its way, or
    /// free to add.
    func tellStore(installed: [String], busy: String?) {
        guard let built,
              let data = try? JSONSerialization.data(withJSONObject: ["installed": installed, "busy": busy.map { $0 as Any } ?? NSNull()]),
              let json = String(data: data, encoding: .utf8)
        else { return }
        built.evaluateJavaScript("window.__escaleStore && window.__escaleStore.state(\(json))")
    }

    /// Keep the preview intact until its removal has actually finished. A
    /// second WebKit signal must not release it halfway through that fade.
    func reveal() {
        guard returning, let view = built else { return }
        let asked = generation
        let animation = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : Motion.returnReveal
        withAnimation(animation, completionCriteria: .removed) {
            returning = false
        } completion: { [weak self, weak view] in
            guard let self, let view, self.current(view, asked), !self.returning else { return }
            self.cover = nil
        }
    }

    /// An error, discard or replacement load cancels the preview immediately.
    func uncover() {
        cover = nil
        returning = false
    }

    /// Set when WebKit said the page's process went away while nobody was
    /// looking at the tab. Coming back to it loads the page again rather
    /// than showing the white that is left.
    var stale = false

    /// The process behind this page just died while it was the one on
    /// screen. `reload()`/`reloadFromOrigin()` lean on state the dead
    /// process was keeping — asking for the address back instead is the
    /// same trick `revive()` and the hollow branch of `reload()` already
    /// use, and the one that doesn't depend on anything the crash took with
    /// it. Tried twice: right after a process dies, WebKit doesn't always
    /// accept the very next load, which is what a reload that looks like it
    /// did nothing actually was.
    func recoverFromCrash() {
        guard let address else { return }
        failure = nil
        uncover()
        loadAndVerify(address)
    }

    /// `web.load`, checked a moment later rather than trusted outright: a
    /// load handed to WebKit right after a process just died, or as the
    /// very first thing a freshly-built view is asked to do, doesn't always
    /// take — no error, no navigation, just a view that goes on sitting on
    /// about:blank with nothing left to say so. Still there, or still
    /// answering for a process that's already gone, is asked once more.
    private func loadAndVerify(_ url: URL, state: Any? = nil) {
        advanceGeneration()
        holding = generation
        returning = true
        let view = web
        view.holdForFirstFrame()
        let asked = generation
        // An obsolete picture must not masquerade as a live page indefinitely.
        // The neutral loading surface remains if the network is still waiting.
        if cover != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.returnPreviewLifetime) { [weak self, weak view] in
                guard let self, let view, self.current(view, asked), self.returning else { return }
                self.cover = nil
            }
        }
        load(url, state: state, into: view, for: generation, tries: 0)
    }

    /// Whether work begun for `generation` on `view` still has a say: the
    /// tab still shows that view, and has asked it for nothing since. A
    /// tab put to sleep, closed or replaced has let the view go; one sent
    /// somewhere else has moved on. Either way the work is dropped, and
    /// `web`, which would build a view, is never reached.
    private func current(_ view: PageView, _ generation: Int) -> Bool {
        built === view && self.generation == generation
    }

    private func load(_ url: URL, state: Any?, into view: PageView, for generation: Int, tries: Int) {
        // Wait for the stage to take the view back before loading into it. A
        // page loaded while its view is off any window boots as a hidden tab,
        // and a site that holds everything until it is shown — x.com does,
        // right down to making no request at all — can then miss being shown a
        // moment later and sit on its placeholder for good. Coming back to a
        // pinned tab after ⌘W is exactly that: select() asks for the view back
        // and wakes the page in the same breath, one synchronous step ahead of
        // SwiftUI actually putting the view on screen. Bounded at about a
        // second, so a wake with no stage waiting for it still loads rather
        // than hanging on one that will never come.
        if view.window == nil, tries < 50 {
            // The view weakly too: a view let go meanwhile is not kept for this.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self, weak view] in
                guard let self, let view, current(view, generation) else { return }
                load(url, state: state, into: view, for: generation, tries: tries + 1)
            }
            return
        }
        holding = nil
        // A tab that slept has its own history to go back to — the page, its
        // back list and its scroll position, in one. Anything else starts
        // from the address.
        if let state {
            view.interactionState = state
        } else {
            view.load(URLRequest(url: url))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak view] in
            guard let self, let view, current(view, generation) else { return }
            guard view.url?.absoluteString != "about:blank" else {
                view.load(URLRequest(url: url))
                return
            }
            view.evaluateJavaScript("document.readyState") { [weak self, weak view] _, error in
                MainActor.assumeIsolated {
                    guard let self, let view, self.current(view, generation),
                          let error = error as NSError? else { return }
                    guard error.domain == WKErrorDomain,
                          error.code == WKError.webContentProcessTerminated.rawValue
                    else { return }
                    view.load(URLRequest(url: url))
                }
            }
        }
    }

    /// Coming back to a tab. A page whose process was taken away out of sight
    /// — memory pressure, a long sleep — comes back as a white rectangle, and
    /// WebKit does not always say so for a view that was out of its window.
    /// Asked anything at all, the page answers with one particular error, and
    /// the answer to that is to load it again.
    func revive() {
        if stale {
            stale = false
            recoverFromCrash()
            return
        }
        guard !isBlank, pending == nil, !loading, failure == nil else { return }
        // A view with no document behind an address: whatever emptied it, the
        // address is what to show, and reload alone would have nothing to do.
        if hollow, address != nil {
            recoverFromCrash()
            return
        }
        let view = web
        let asked = generation
        view.evaluateJavaScript("document.readyState") { [weak self, weak view] _, error in
            MainActor.assumeIsolated {
                guard let self, let view, self.current(view, asked),
                      let error = error as NSError? else { return }
                guard error.domain == WKErrorDomain,
                      error.code == WKError.webContentProcessTerminated.rawValue
                else { return }
                self.recoverFromCrash()
            }
        }
    }

    /// Opened for the first time since the app started, or coming back from
    /// ⌘W while pinned. Answers whether there was anything to wake — the
    /// caller's own `revive()`, right after this, is for a tab that went
    /// quiet a different way, and firing it too here raced this very load
    /// with a second one of its own for the same address.
    @discardableResult
    func wake() -> Bool {
        guard let url = pending else { return false }
        pending = nil
        sleeping = false
        failure = nil
        reading = 0
        lastY = 0
        reader = false
        typing = false
        immersed = false
        let state = memory
        memory = nil
        if let picture, let image = NSImage(data: picture) {
            cover = image
        }
        picture = nil
        loadAndVerify(url, state: state)
        return true
    }

    /// A tab opened by a link is not blank, even though WebKit hasn't started
    /// loading it yet. Saying so now keeps the empty state from flashing up in
    /// the frame between the tab appearing and the page committing.
    func setAddressOptimistically(_ url: URL) {
        address = url
        failure = nil
        adoptIcon()
    }

    func touch() { touched = Date(); visited = true }

    /// True when the web view holds nothing — never loaded, or emptied —
    /// while the tab still names a page. The white page, in other words.
    var hollow: Bool {
        guard let built else { return address != nil }
        guard let there = built.url else { return address != nil }
        return there.absoluteString == "about:blank" && pending == nil && address != nil
    }

    /// Again from the network. A view that has lost its document is given
    /// the address back instead: there is nothing else for it to reload.
    func reload() {
        // A pin put down with ⌘W has no view left to reload; waking it is
        // the reload.
        guard !wake() else { return }
        uncover()
        advanceGeneration()
        if let retry = failedAddress {
            // The view still holds the page before it; Retry is for the
            // place that did not answer. It stays the target until a page
            // commits, so a second reload before then does not cancel it for
            // the page behind.
            failure = nil
            failedAddress = retry
            web.load(URLRequest(url: retry))
        } else if hollow, let address {
            web.load(URLRequest(url: address))
        } else {
            web.reloadFromOrigin()
        }
    }
    func stop() {
        uncover()
        built?.showFirstFrame("stopped", animated: false)
        // Stop cancels pending load work, but WebKit keeps this document's
        // audio playing. Keep its reader and the user's dismissal choice.
        advanceGeneration(preservingMedia: true)
        web.stopLoading()
        // Nothing may have been loading, and then WebKit says nothing back.
        stayed()
    }
    /// Straight through, every time. A page that has to be fetched again is
    /// fetched again — nothing is kept behind to make that look otherwise.
    func back() {
        uncover()
        advanceGeneration()
        web.goBack()
    }
    func forward() {
        uncover()
        advanceGeneration()
        web.goForward()
    }

    /// The nearest ten destinations of this tab's existing page, from closest
    /// to furthest. Sleeping tabs have released that page and its list.
    func recent(back: Bool) -> [WKBackForwardListItem] {
        guard let list = built?.backForwardList else { return [] }
        let ordered = back ? Array(list.backList.reversed()) : list.forwardList
        return Array(ordered.prefix(10))
    }

    /// A menu destination belongs to the current page's own history.
    func go(to item: WKBackForwardListItem) {
        guard let web = built,
              web.backForwardList.backList.contains(item) || web.backForwardList.forwardList.contains(item)
        else { return }
        uncover()
        advanceGeneration()
        web.go(to: item)
    }

    /// Thrown away for good (close). The stage still watching it for a frame
    /// built it a new view, which nothing ever let go of.
    private(set) var closed = false

    /// Called when the tab is thrown away. Without it the view keeps running
    /// whatever the page left behind — timers, video, sockets.
    func close() {
        closed = true
        onPanelEnd?(self)
        onPanelEnd = nil
        onPanelFocus = nil
        sleeping = false
        onScroll = nil
        onZoom = nil
        onLink = nil
        onSelection = nil
        onPick = nil
        onPickEnd = nil
        onField = nil
        onCredentials = nil
        followers = []
        discard()
    }

    /// The view and everything listening to it, gone — timers, video,
    /// sockets, and the document WebKit would otherwise keep in its
    /// back-forward cache. The tab keeps its address; `web` builds again the
    /// next time anyone asks for it.
    private func discard() {
        uncover()
        calls.stop()
        invalidatePageData()
        watch = []
        ears.stop()
        guard let web = built else { return }
        built = nil
        let controller = web.configuration.userContentController
        controller.removeScriptMessageHandler(forName: ScrollRelay.name)
        controller.removeScriptMessageHandler(forName: VeilRelay.name)
        controller.removeScriptMessageHandler(forName: FormRelay.name)
        controller.removeScriptMessageHandler(forName: ImageRelay.name)
        controller.removeScriptMessageHandler(forName: StoreRelay.name)
        controller.removeScriptMessageHandler(forName: PasskeyRelay.name)
        controller.removeScriptMessageHandler(forName: HoveredLink.name, contentWorld: .defaultClient)
        controller.removeScriptMessageHandler(forName: SelectionWatch.name, contentWorld: .defaultClient)
        controller.removeScriptMessageHandler(forName: MiddleRelay.name)
        controller.removeAllUserScripts()
        web.onPull = nil
        web.onTouch = nil
        web.searchName = nil
        web.onSearch = nil
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.removeFromSuperview()
    }
}


/// Whether the page is making noise.
///
/// WebKit knows, but only says so through a name that isn't part of the public
/// framework — so it is asked whether it answers to that name at all before
/// anyone listens, and the tab simply goes without the indicator if it doesn't.
final class AudioWatch: NSObject {
    private static let key = "_isPlayingAudio"

    private weak var web: WKWebView?
    private var tell: ((Bool) -> Void)?

    func watch(_ web: WKWebView, _ tell: @escaping (Bool) -> Void) {
        guard web.responds(to: NSSelectorFromString(AudioWatch.key)) else { return }
        self.web = web
        self.tell = tell
        web.addObserver(self, forKeyPath: AudioWatch.key, options: [.initial, .new], context: nil)
    }

    func stop() {
        guard let web, tell != nil else { return }
        web.removeObserver(self, forKeyPath: AudioWatch.key)
        tell = nil
        self.web = nil
    }

    override func observeValue(
        forKeyPath path: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard path == AudioWatch.key else { return }
        let on = (change?[.newKey] as? Bool) ?? false
        DispatchQueue.main.async { self.tell?(on) }
    }

    deinit { stop() }
}

/// The middle button on a link, as the page reports it.
///
/// A middle-click on a link opens it beside the tab you are on, in every
/// other browser, and WebKit leaves that to the browser: it tells the page
/// about the click and hands this app no navigation action for it at all, the
/// way it does for ⌘-click (and where it does report a button, it answers
/// with a mask — 1 left, 2 right, 4 middle — so a check for the middle button
/// as 2 would catch the right one). The page can see the click, though, so
/// the page is asked: its own `auxclick` for the middle button names the link
/// under the pointer, and from there it is an ordinary address to open.
///
/// Only the main frame, only a real link to somewhere this browser
/// would go, and only the middle button. A page's own handler runs as it
/// always did — this says where to, and changes nothing about the click.
///
/// Two things are checked before anything is opened. The event has to carry a
/// real click: a synthesized `auxclick` is not one, so a page that dispatches
/// its own does not get a tab per dispatch. And it has to be unclaimed — a
/// click a page has called `preventDefault` on is a click it has dealt with,
/// which is why this listens as the event comes back up rather than on the
/// way down, where nothing has answered yet.
final class MiddleRelay: NSObject, WKScriptMessageHandler {
    static let name = "escaleMiddle"

    weak var tab: Tab?

    static let watch = Bundled.script("middle-watch.js")

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              message.frameInfo.isMainFrame,
              let href = body["href"] as? String,
              let url = URL(string: href),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return }
        MainActor.assumeIsolated { [weak self] in
            guard let self, let tab else { return }
            tab.onMiddleClick?(tab, url)
        }
    }
}

/// A web view that reads the two-finger swipe for itself.
final class PageView: WKWebView {
    /// What extensions added to the right-click menu, at the end of it.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        if let item = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierSearchWeb" }),
           let name = searchName?() {
            webSearch = (item.target, item.action)
            selection = nil
            evaluateJavaScript(PageView.selected, in: nil, in: .defaultClient) { [weak self] result in
                self?.selection = (try? result.get()) as? String ?? ""
            }
            item.title = "Search with \(name)"
            item.target = self
            item.action = #selector(searchSelection(_:))
        }
        guard #available(macOS 15.4, *),
              let tab = Extensions.shared.browser?.tab(for: self)
        else { return }
        let items = Extensions.forSpace(tab.space).menuItems(for: tab)
        guard !items.isEmpty else { return }
        menu.addItem(.separator())
        items.forEach { menu.addItem($0) }
    }

    var searchName: (() -> String?)?
    var onSearch: ((String) -> Void)?
    private var selection: String?

    /// The words selected where the right-click was, read when the menu
    /// opens. The selection of a text field is its own, not the page's, so a
    /// field with the caret in it is asked first; a frame with the caret in it
    /// is looked into when it is of the same site. One of another site can't
    /// be, and gives nothing, so WebKit's own action takes the click, as it
    /// always did. A password field gives nothing either.
    static let selected = Bundled.script("page-selected.js")
    private var webSearch: (target: AnyObject?, action: Selector?) = (nil, nil)

    @objc private func searchSelection(_ item: NSMenuItem) {
        defer { selection = nil }
        guard let selection, !selection.isEmpty else {
            if let action = webSearch.action { NSApp.sendAction(action, to: webSearch.target, from: item) }
            return
        }
        let words = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { onSearch?(words) }
    }

    /// Told where a sideways swipe has got to, and nil when there is none.
    var onPull: ((Pull?) -> Void)?
    /// Told the moment the page is reached for — a click, a scroll — so the
    /// split group can give that pane the focus.
    var onTouch: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onTouch?()
        super.mouseDown(with: event)
    }
    /// The side buttons a mouse has for back and forward — button 3 and 4.
    /// No standard hands out that numbering; it's the X11 button order
    /// (0 left, 1 right, 2 middle, 3 back, 4 forward) that most mouse
    /// drivers settled on regardless, so it's what a mouse's own firmware
    /// is tuned to send.
    override func otherMouseDown(with event: NSEvent) {
        switch event.buttonNumber {
        case 3 where canGoBack: goBack()
        case 4 where canGoForward: goForward()
        default: super.otherMouseDown(with: event)
        }
    }

    // MARK: - keys the page didn't use

    /// The last key handed to the page. WebKit sends a key the page didn't
    /// use back up the responder chain — the same event, a second time —
    /// where nothing takes it and macOS plays its "can't do that" sound.
    /// Editors that put the text in themselves (X's reply box, anything built
    /// on Draft.js) leave WebKit thinking their keys unused, so typing into
    /// them beeped. Safari keeps those quiet, and so does this view. The
    /// app's own shortcuts never get this far: its key monitor takes them
    /// before the page sees the key.
    private var handed: NSEvent?
    /// How many came back unused and were kept quiet, for the bench.
    static var quieted = 0

    override func keyDown(with event: NSEvent) {
        if let handed, PageView.same(handed, event) {
            self.handed = nil
            PageView.quieted += 1
            return
        }
        handed = event
        super.keyDown(with: event)
    }

    /// The same key press: the event WebKit sends back is the one it was
    /// given, and no two presses share a timestamp.
    static func same(_ one: NSEvent, _ other: NSEvent) -> Bool {
        one === other || (one.timestamp == other.timestamp && one.keyCode == other.keyCode && one.type == other.type)
    }

    // MARK: - the first frame

    /// A web view that has never drawn is opaque white. In a dark window that
    /// is a flash of it between a link that opens a tab and the page arriving,
    /// so a fresh view starts unseen, over the window's own ground, and comes
    /// in once WebKit says there is something on it worth seeing.
    private(set) var unpainted = false

    /// WebKit says when the first frame is only through names outside the
    /// public framework, so it is asked whether it answers to them first. One
    /// that doesn't gets a view shown straight away, as before.
    func holdForFirstFrame() {
        let observe = NSSelectorFromString("_setObservedRenderingProgressEvents:")
        guard responds(to: observe) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(method(for: observe), to: Setter.self)(self, observe, PageView.firstFrame)
        unpainted = true
        alphaValue = 0
    }

    /// In, quickly: the page is there, and the fade only covers the frame
    /// between WebKit laying it out and putting it on screen.
    func showFirstFrame(_ source: String, animated: Bool = true) {
        guard unpainted else { return }
        unpainted = false
        if Store.measuring {
            firstVisibleAt = ProcessInfo.processInfo.systemUptime
            firstVisibleSource = source
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? Motion.pageRevealDuration : 0
            animator().alphaValue = 1
        }
    }

    /// The instant the hidden fresh page was revealed, and the WebKit event
    /// that caused it. Kept only during an explicit resource acquisition.
    private(set) var firstVisibleAt: TimeInterval?
    private(set) var firstVisibleSource: String?

    /// _WKRenderingProgressEventFirstVisuallyNonEmptyLayout — the moment
    /// Safari takes down the picture it shows while a page comes back.
    static let firstFrame: UInt = 1 << 1

    // MARK: - two fingers sideways

    private enum Axis { case across, down }

    private var sideways: CGFloat = 0
    private var gatheredX: CGFloat = 0
    private var gatheredY: CGFloat = 0
    private var axis: Axis?
    /// Which way the gesture set off, decided once and kept. Turning round
    /// mid-swipe pulls the disc back; it never becomes the other disc.
    private var back = true
    /// The page's word on whether this swipe is its own. Nil until it says.
    private var free: Bool?
    private var asked: Date?
    /// Already went somewhere, or was refused: nothing more this gesture.
    private var spent = false
    private var armedNow = false
    private var showing = false
    private var going = false
    private var pulls = 0

    /// How far the fingers travel before letting go means it.
    private static let arm: CGFloat = 110
    /// Less than this and there is nothing to show yet — or nothing left to.
    private static let show: CGFloat = 6

    // MARK: - two fingers together

    // The pinch itself is WebKit's own: during the gesture it scales the
    // rendered layers on the GPU around the fingers and only lays the page
    // out again once they lift. Doing the same from here — a real change of
    // scale on every event — was measured at a few frames a second, and the
    // public `setMagnification(_:centeredAt:)` ignores its point and resets
    // the scroll besides, so the pinch stays with WebKit. What is handled
    // here is the one-shot gesture WebKit does not do well on its own.

    /// Two fingers, tapped twice: the block under them fills the width, the
    /// way Safari's smart zoom does; tapped again, the page is back at its
    /// own size with the same spot still under the fingers. The page picks
    /// the block — it is the only one that knows where a column ends.
    override func smartMagnify(with event: NSEvent) {
        guard allowsMagnification else {
            super.smartMagnify(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let js = PageView.smart(x: point.x, y: point.y, scale: magnification, width: bounds.width)
        evaluateJavaScript(js) { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self, let text = value as? String, let data = text.data(using: .utf8),
                      let zoom = try? JSONDecoder().decode(SmartZoom.self, from: data)
                else { return }
                self.setMagnification(zoom.scale, centeredAt: point)
                self.evaluateJavaScript("window.scrollTo(\(zoom.x), \(zoom.y))")
            }
        }
    }

    private struct SmartZoom: Decodable {
        var scale: CGFloat
        var x: CGFloat
        var y: CGFloat
    }

    /// Where a smart zoom should land: the scale that fits the block under
    /// the fingers to the width, and the scroll that puts it there with the
    /// tapped spot at the same height. Zoomed in already, it is the way back.
    /// Scroll positions are CSS pixels of the whole page — `window.scrollTo`
    /// moves the magnified view here even on a page whose own overflow is
    /// hidden — and they are read before the scale changes, since the
    /// change itself sends the scroll to the corner.
    // (see Tabs/Scripts/smart-zoom.js)
    private static let zoom = Bundled.script("smart-zoom.js")
    static func smart(x: CGFloat, y: CGFloat, scale: CGFloat, width: CGFloat) -> String {
        Bundled.configured(zoom, with: ["x": x, "y": y, "scale": scale, "width": width])
    }

    override func scrollWheel(with event: NSEvent) {
        onTouch?()
        // The page gets every event first and scrolls as it always did. The
        // swipe is only read, never taken.
        super.scrollWheel(with: event)
        // Only a live trackpad gesture — not its glide afterwards, and not a
        // mouse wheel, which has no beginning or end to speak of.
        guard event.momentumPhase == [] else { return }

        switch event.phase {
        case .mayBegin, .began:
            sideways = 0
            gatheredX = 0
            gatheredY = 0
            axis = nil
            free = nil
            asked = nil
            spent = false
            armedNow = false
            showing = false
            // A disc still on its way out belongs to the last gesture. It is
            // already invisible; it is only taken off the stage so the next
            // one arrives fresh rather than fading back in.
            pulls += 1
            if going {
                going = false
                onPull?(nil)
            }
        case .changed:
            guard !spent else { return }
            if axis == nil {
                // A few points in, the gesture has shown which way it means
                // to go. Only a clearly sideways one is read further.
                gatheredX += abs(event.scrollingDeltaX)
                gatheredY += abs(event.scrollingDeltaY)
                sideways += event.scrollingDeltaX
                guard gatheredX + gatheredY > 6 else { return }
                axis = gatheredX > gatheredY * 1.3 ? .across : .down
                if axis == .down {
                    spent = true
                    return
                }
                back = sideways > 0
                // Nowhere to go that way: nothing to show, and nothing more
                // to read from this gesture.
                if back ? !canGoBack : !canGoForward {
                    spent = true
                    return
                }
                asked = Date()
                tell()
                return
            }
            sideways += event.scrollingDeltaX
            tell()
        case .ended:
            release()
        case .cancelled:
            spent = true
            settle(nil)
        default:
            break
        }
    }

    /// The page has said whether the swipe would scroll something.
    func answer(free yes: Bool) {
        guard axis != .down, !spent else { return }
        guard yes else {
            free = false
            spent = true
            settle(nil)
            return
        }
        guard free == nil else { return }
        free = true
        tell()
    }

    /// Only the distance in the direction it set off in. Past the origin the
    /// other way is just nought.
    private var travel: CGFloat { max(0, back ? sideways : -sideways) }

    private func tell() {
        if free == nil, let asked, Date().timeIntervalSince(asked) > 0.18 {
            // A page that never answers — a PDF, a page that failed to load —
            // still has to be leavable by hand.
            free = true
        }
        guard free == true else { return }

        let travel = travel
        // Drawn all the way back, the disc goes; drawn out again, it returns.
        // Nothing is decided until the fingers lift.
        guard travel >= PageView.show else {
            if showing { settle(nil) }
            return
        }

        let armed = travel >= PageView.arm
        if armed != armedNow {
            // Two different taps: one for reaching it, a lighter one for
            // stepping back from it, so you know without looking that
            // letting go now is safe.
            NSHapticFeedbackManager.defaultPerformer.perform(
                armed ? .levelChange : .alignment, performanceTime: .now
            )
        }
        armedNow = armed
        settle(Pull(back: back, travel: travel, armed: armed, going: false))
    }

    private func release() {
        defer { spent = true }
        guard !spent, free == true, armedNow else {
            settle(nil)
            return
        }
        going = true
        settle(Pull(back: back, travel: travel, armed: true, going: true))
        if back { goBack() } else { goForward() }
        pulls += 1
        let mine = pulls
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            guard let self, pulls == mine else { return }
            going = false
            settle(nil)
        }
    }

    private func settle(_ pull: Pull?) {
        showing = pull != nil
        onPull?(pull)
    }

}

/// Carries the page's scroll position back to its tab.
///
/// A content controller holds its handlers strongly, so this stands between the
/// two rather than the tab registering itself — otherwise a closed tab is kept
/// alive by the very page it was told to stop showing.
final class ScrollRelay: NSObject, WKScriptMessageHandler {
    static let name = "escaleScroll"

    weak var tab: Tab?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        if let side = body["side"] as? String {
            MainActor.assumeIsolated { tab?.web.answer(free: side == "free") }
            return
        }
        guard let y = body["y"] as? Double,
              let ceiling = body["max"] as? Double
        else { return }
        MainActor.assumeIsolated { tab?.scrolled(to: y, of: ceiling) }
    }

    /// Settings › "Show how far you've read": the grey the tab fills with,
    /// which is all the scroll is told for. Off, pages don't report it.
    @MainActor static var on = true

    /// For a page already up when the bar is turned off.
    static let off = "window.__escaleScroll && window.__escaleScroll();"

    /// Reports at most once a frame, and passively, so a page that scrolls
    /// smoothly without us keeps scrolling smoothly with us.
    // (see Tabs/Scripts/scroll-report.js)
    private static let page = Bundled.script("scroll-report.js")
    static let script = Bundled.configured(page, with: ["handler": name])
}
