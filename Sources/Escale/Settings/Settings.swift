import SwiftUI

// Settings stand in for the page on screen, in its rounded frame: the column,
// the rail and the bars stay put, so Settings read as a place in the browser
// rather than a second window over it (as Aside and Arc show theirs). A panel
// laid over the whole window hid the tabs and cost the column's room for
// nothing. The growing list of choices still needs its own navigation rail
// and room for descriptions, inside the frame. The WebKit page underneath
// stays intact, and picking a tab or typing an address returns to a page.
// Categories follow the thing a person is changing rather than the feature's
// age; stored preference keys and their defaults are unaffected by this
// presentation. Features, a named group at the head of the rail, gives a
// developer workflow worth finding its own page rather than a line at the
// foot of the category it touches. The frame supplies the edge an empty tab has;
// Clear exposes the window's envelope, while Subtle and Solid keep its opaque
// ground. Settings add no plate of their own.
struct SettingsPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject private var migration: MigrationFlow
    @ObservedObject private var linkDraft: LinkDraft
    let availableWidth: CGFloat
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var shield = Shield.shared
    @ObservedObject private var alerts = DeveloperAlerts.shared
    @State private var isDefault = Links.isDefault
    @SwiftUI.Environment(\.accessibilityReduceTransparency) private var reducing
    @SwiftUI.Environment(\.colorSchemeContrast) private var contrast
    private var increasing: Bool { contrast == .increased }
    @State private var page: Page = Page.restored(Store.settings.string(forKey: "settings.page"))
    @State private var query = ""

    init(browser: Browser, prefs: Preferences, availableWidth: CGFloat) {
        self.browser = browser; self.prefs = prefs; self.availableWidth = availableWidth
        migration = browser.migration
        linkDraft = browser.linkRoutes.draft
    }

    /// At the window's minimum width, navigation moves above the controls.
    private var compact: Bool {
        availableWidth < metrics.length(Metrics.settingsCompactBreakpoint)
    }

    enum Page: String, CaseIterable, Identifiable {
        case github, routing, general, appearance, tabs, pages, migration, passwords, privacy, extensions, developer, keyboard, about
        var id: String { rawValue }
        static let features: [Page] = [.routing, .github]
        static let browsing: [Page] = [.general, .appearance, .tabs, .pages]
        static let personal: [Page] = [.migration, .passwords, .privacy, .extensions]
        static let tools: [Page] = [.developer, .keyboard]

        /// The former one-purpose pages land beside the settings they now accompany.
        static func restored(_ raw: String?) -> Page {
            switch raw {
            case "downloads": return .general
            case "notifications": return .developer
            default: return raw.flatMap(Page.init(rawValue:)) ?? .general
            }
        }

        /// Words people look for, including the former category names.
        var searchTerms: String {
            switch self {
            case .general: return "gear default browser links search engine downloads save folder files"
            case .appearance: return "theme light dark colours colors tone escale warm transparency contrast interface size faster shortcut animations motion"
            case .github: return "github bearings pull requests issues local search repository"
            case .routing: return "link routing route rules links open site host domain url space spaces meet routage liens"
            case .tabs: return "tabs spaces sidebar folded address bookmarks copy icons reading sleep"
            case .pages: return "web pages links scroll middle button"
            case .migration: return "import migration bookmarks history passwords browser profiles safari firefox chrome arc zen orion aside"
            case .passwords: return "passwords passkeys keychain sign in import accounts"
            case .privacy: return "privacy ads trackers block camera microphone history cookies cache site data"
            case .extensions: return "extensions chrome web store add folder"
            case .developer: return "developer notifications alerts agents builds pull requests workflows script bench"
            case .keyboard: return "keyboard shortcuts keys commands bearings"
            case .about: return "about updates version feedback"
            }
        }

        func matches(_ query: String) -> Bool {
            title.localizedCaseInsensitiveContains(query) || searchTerms.localizedCaseInsensitiveContains(query)
        }

        var title: String {
            switch self {
            case .github: return "GitHub"
            case .routing: return "Link Routing"
            case .general: return "General"
            case .appearance: return "Appearance"
            case .tabs: return "Tabs & Spaces"
            case .pages: return "Web Pages"
            case .extensions: return "Extensions"
            case .migration: return "Import Data"
            case .passwords: return "Passwords"
            case .privacy: return "Privacy"
            case .developer: return "Developer"
            case .keyboard: return "Keyboard"
            case .about: return "About"
            }
        }
        var icon: String {
            switch self {
            case .github: return "point.3.connected.trianglepath.dotted"
            case .routing: return "arrow.triangle.branch"
            case .general: return "gearshape"
            case .appearance: return "circle.lefthalf.filled"
            case .tabs: return "square.on.square"
            case .pages: return "doc.text"
            case .extensions: return "puzzlepiece.extension"
            case .migration: return "square.and.arrow.down"
            case .passwords: return "key"
            case .privacy: return "hand.raised"
            case .developer: return "chevron.left.forwardslash.chevron.right"
            case .keyboard: return "keyboard"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        Group {
            if compact {
                VStack(spacing: 0) {
                    compactPages
                    Rectangle().fill(Palette.hairline).frame(height: metrics.length(1))
                    content
                }
            } else {
                HStack(spacing: 0) {
                    pages
                    Rectangle().fill(Palette.hairline).frame(width: metrics.length(1))
                    content
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .environment(\.cardDensity, .settings)
        .onChange(of: linkDraft.request) { _, _ in page = .routing; query = "" }
        .onChange(of: migration.request) { _, _ in page = .migration }
        .onChange(of: page) { old, page in
            if old == .migration { migration.leave() }
            Store.settings.set(page.rawValue, forKey: "settings.page")
        }
    }

    // MARK: - the rail

    private var searchField: some View {
        HStack(spacing: metrics.length(6)) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: metrics.length(Metrics.settingsSearchText)))
                .foregroundStyle(Palette.muted)
            TextField("Find a setting", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: metrics.length(Metrics.settingsSearchText)))
                .accessibilityLabel("Find a setting")
        }
        .padding(.horizontal, metrics.length(8))
        .frame(height: metrics.length(Metrics.settingsSearch))
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: metrics.length(Metrics.settingsRowRadius), style: .continuous))
    }

    private var compactPages: some View {
        VStack(alignment: .leading, spacing: metrics.length(8)) {
            HStack(spacing: metrics.length(12)) {
                Text("Settings")
                    .font(.system(size: metrics.length(Metrics.settingsTitle), weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
                // Beside the column, the frame can be narrower than the
                // window's minimum: the field gives way before the title.
                searchField.frame(maxWidth: metrics.length(176))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: metrics.length(4)) {
                    let matches = Page.allCases.filter { query.isEmpty || $0.matches(query) }
                    if matches.isEmpty {
                        Text("No settings found")
                            .font(.system(size: metrics.length(Metrics.settingsRowText)))
                            .foregroundStyle(Palette.muted)
                    } else {
                        pageGroup(matches)
                    }
                }
            }
        }
        .padding(.horizontal, metrics.length(14))
        .padding(.top, metrics.length(Metrics.settingsTop))
        .padding(.bottom, metrics.length(8))
    }

    private var pages: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.system(size: metrics.length(Metrics.settingsTitle), weight: .medium))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, metrics.length(10))
                .padding(.top, metrics.length(Metrics.settingsTop))
                .padding(.bottom, metrics.length(10))
            searchField.padding(.bottom, metrics.length(12))
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: metrics.length(2)) {
                    if query.isEmpty {
                        Text("Features")
                            .font(.system(size: metrics.length(Metrics.settingsHeading), weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, metrics.length(8))
                            .padding(.bottom, metrics.length(3))
                            .accessibilityAddTraits(.isHeader)
                        pageGroup(Page.features)
                        Rectangle().fill(Palette.hairline)
                            .frame(height: metrics.length(1))
                            .padding(.vertical, metrics.length(8))
                        pageGroup(Page.browsing)
                        Rectangle().fill(Palette.hairline)
                            .frame(height: metrics.length(1))
                            .padding(.vertical, metrics.length(8))
                        pageGroup(Page.personal)
                        Rectangle().fill(Palette.hairline)
                            .frame(height: metrics.length(1))
                            .padding(.vertical, metrics.length(8))
                        pageGroup(Page.tools)
                    } else {
                        let matches = Page.allCases.filter { $0.matches(query) }
                        if matches.isEmpty {
                            Text("No settings found")
                                .font(.system(size: metrics.length(Metrics.settingsRowText)))
                                .foregroundStyle(Palette.muted)
                                .padding(.horizontal, metrics.length(8))
                        } else {
                            pageGroup(matches)
                        }
                    }
                }
            }
            if query.isEmpty {
                PageRow(page: .about, on: page == .about) { page = .about }
                    .padding(.top, metrics.length(8))
            }
        }
        .padding(.horizontal, metrics.length(8))
        .padding(.bottom, metrics.length(8))
        .frame(width: metrics.length(Metrics.settingsRail), alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func pageGroup(_ items: [Page]) -> some View {
        ForEach(items) { item in
            PageRow(page: item, on: page == item) { page = item }
        }
    }

    private struct PageRow: View {
        let page: Page
        let on: Bool
        let act: () -> Void
        @SwiftUI.Environment(\.chromeMetrics) private var metrics
        @State private var hovering = false

        var body: some View {
            Button(action: act) {
                HStack(spacing: metrics.length(7)) {
                    Image(systemName: page.icon)
                        .font(.system(size: metrics.length(Metrics.settingsRowSymbol), weight: .regular))
                        .symbolRenderingMode(.monochrome)
                        .frame(width: metrics.length(Metrics.settingsRowIcon), height: metrics.length(Metrics.settingsRowIcon))
                    Text(page.title)
                        .font(.system(size: metrics.length(Metrics.settingsRowText), weight: .regular))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(on ? Palette.ink : (hovering ? Palette.ink.opacity(0.75) : Palette.muted))
                .padding(.horizontal, metrics.length(8))
                .frame(height: metrics.length(Metrics.settingsRow))
                .background {
                    if on {
                        Chosen(radius: metrics.length(Metrics.settingsRowRadius))
                    } else {
                        RoundedRectangle(cornerRadius: metrics.length(Metrics.settingsRowRadius), style: .continuous)
                            .fill(hovering ? Palette.hover : .clear)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: metrics.length(Metrics.settingsRowRadius), style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }

    // MARK: - the page

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(page.title)
                    .font(.system(size: metrics.length(Metrics.settingsTitle), weight: .medium))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Door(icon: "xmark", help: "Done   esc") { browser.tuning = false }
            }
            .padding(.bottom, metrics.length(10))

            if page == .routing {
                // Its own scroll view, so Save stays in sight under a long list.
                LinkRulesView(routes: browser.linkRoutes, spaces: browser.spaces, enabled: prefs.usesSpaces, draft: linkDraft) {
                    prefs.usesSpaces = true
                }
            } else if page == .keyboard {
                KeyboardSettings(prefs: prefs)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: metrics.length(Metrics.settingsGap)) {
                        switch page {
                        case .github:
                            GitHubSettings(access: browser.github.owner(for: browser.spaceID).access,
                                           shares: browser.github.owner(for: browser.spaceID).shares,
                                           stroke: prefs.keyBindings.keys(.searchGitHub).first,
                                           visit: { browser.tuning = false; _ = browser.open($0, foreground: true) }) {
                                browser.tuning = false; browser.beginGitHub()
                            }
                        case .routing: EmptyView()
                        case .general: general
                        case .appearance: appearance
                        case .tabs: tabs
                        case .pages: webPages
                        case .migration:
                            MigrationPanel(browser: browser, flow: migration) { browser.tuning = false }
                            TransferSavePanel(browser: browser, transfer: browser.transfer)
                                .padding(.top, metrics.length(Metrics.settingsGap))
                        case .passwords: passwords
                        case .privacy: privacy
                        case .extensions: ExtensionsPage(browser: browser)
                        case .developer: developer
                        case .keyboard: EmptyView()
                        case .about: about
                        }
                    }
                    .padding(.bottom, metrics.length(4))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // A scroll view clips at its edge: it takes the page's side
                    // margins and gives them back inside, so a floating card's
                    // shadow (GitHub's specimen) is not cut where the column starts.
                    .padding(.horizontal, metrics.length(Metrics.settingsInset))
                }
                .padding(.horizontal, -metrics.length(Metrics.settingsInset))
                .id(page)
            }
        }
        .frame(maxWidth: metrics.length(Metrics.settingsContent))
        .padding(.horizontal, metrics.length(Metrics.settingsInset))
        .padding(.top, metrics.length(Metrics.settingsTop) - metrics.length(4))
        .padding(.bottom, metrics.length(Metrics.settingsInset))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - general

    private var general: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.settingsGap)) {
            Card {
                Line(
                    "Open links from other apps",
                    isDefault ? "Escale is the default browser on this Mac" : "Mail, Slack and the rest still send links elsewhere"
                ) {
                    if isDefault {
                        Image(systemName: "checkmark")
                            .font(.system(size: metrics.length(11), weight: .regular))
                            .foregroundStyle(Palette.ink)
                            .frame(width: metrics.length(22))
                    } else {
                        Pill("Make default", filled: true) {
                            Links.becomeDefault { worked in
                                isDefault = Links.isDefault
                                browser.announce(worked && isDefault ? "Links now open here" : "macOS didn't change it")
                            }
                        }
                    }
                }
                Rule()
                Line("Search with", searchDetail) {
                    Picker("", selection: $prefs.engine) {
                        ForEach(Engine.allCases) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                }
                if prefs.engine == .custom {
                    ZStack(alignment: .leading) {
                        if prefs.customEngine.isEmpty {
                            Text("https://example.com/search?q=%s")
                                .foregroundStyle(Palette.muted.opacity(0.8))
                        }
                        TextField("", text: $prefs.customEngine)
                            .textFieldStyle(.plain)
                            .foregroundStyle(Palette.ink)
                    }
                    .font(.system(size: metrics.length(11.5)))
                    .padding(.horizontal, metrics.length(8))
                    .padding(.vertical, metrics.length(5))
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: metrics.length(7), style: .continuous))
                    .padding(.horizontal, metrics.length(CardDensity.settings.inset))
                    .padding(.bottom, metrics.length(CardDensity.settings.pad))
                }
            }
            Card {
                Line("Save downloads to", prefs.downloads.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    Pill("Change…") { chooseFolder() }
                }
                Rule()
                Line("Ask where to save each file") {
                    Switch(on: $prefs.asksWhereToSave)
                }
            }
        }
    }

    // MARK: - web pages

    private var webPages: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.settingsGap)) {
            Card {
                Line("Show where links go", "Point at a link and its address shows at the bottom of the page") {
                    Switch(on: $prefs.showsLinks)
                }
                Rule()
                Line("Copy or translate selected text", "Select text on a page with the mouse and Copy and Translate appear beside it") {
                    Switch(on: $prefs.selectionMenu)
                }
                Rule()
                Line("Scroll with the middle button", "Click the wheel on a page, then move the mouse up or down to scroll, as on Windows. Click again to stop") {
                    Switch(on: $prefs.autoScroll)
                }
            }
        }
    }

    // MARK: - appearance

    /// Everything about how Escale itself looks: the theme, its glass, its
    /// contrast and its size. None of it touches a page's own look or zoom.
    private var appearance: some View {
        Card {
            Line("Theme", "Light, dark, or whatever the Mac is doing — pages follow it too") {
                Segmented(options: Look.allCases.map { ($0, $0.title) }, selection: $prefs.look)
            }
            Rule()
            Line("Colours", "Neutral greys, or Escale's own warm sand and umber, in light and dark") {
                EmptyView()
            }
            ToneChoice(selection: $prefs.tone, look: prefs.look)
            Rule()
            Line("Transparency", transparencyDetail) {
                Segmented(options: Depth.allCases.map { ($0, $0.title) }, selection: $prefs.depth)
                    .opacity(reducing ? 0.45 : 1)
            }
            Rule()
            Line("Increase contrast", increasing
                 ? "On in macOS's Accessibility settings, which Escale follows"
                 : "Stronger edges, separators and secondary text in Escale's own surfaces") {
                Switch(on: $prefs.increasesContrast)
                    .accessibilityLabel("Increase contrast")
            }
            Rule()
            Line("Faster shortcut animations", "Tab and layout changes finish sooner from the keyboard. macOS Reduce Motion takes priority.") {
                Switch(on: $prefs.fasterShortcuts)
                    .accessibilityLabel("Faster shortcut animations")
            }
            Rule()
            Line("Interface size", "Changes Escale's controls, not the zoom of web pages") {
                SizeChoice(selection: $prefs.interfaceSize)
            }
        }
    }

    /// Says what overrides the level, so the choice never looks broken.
    private var transparencyDetail: String {
        if reducing {
            return "Solid while Reduce transparency is on in macOS"
        }
        return "How much shows through Escale's own surfaces — never through pages"
    }


    private var searchDetail: String {
        guard prefs.engine == .custom else { return "Where words that aren't an address go" }
        guard Engine.accepts(prefs.customEngine) else {
            return "An http or https address with %s where the words go. Until then, Google"
        }
        return "Words go to \(prefs.engine.name(custom: prefs.customEngine))"
    }

    // MARK: - tabs

    private var tabs: some View {
        Card {
            Line("Tabs in a sidebar", "Down the left instead of across the top. Pull its edge to make it wider; double-click the edge to reset.") {
                Switch(on: Binding(
                    get: { prefs.sidebar },
                    set: { on in withAnimation(Motion.glide) { prefs.sidebar = on } }
                ))
            }
            if prefs.sidebar {
                Rule()
                Line("Keep the sidebar folded", "Folded from launch, the page takes the tabs' room. Use its button or your Keyboard shortcut to bring it back.") {
                    Switch(on: $prefs.sideHides)
                }
                Rule()
                // See Bar.swift.
                Line("Address bar above the page", "Back, forward, reload, the site and the page's title across the top, as in Arc's developer mode. Click the site for its details, the title to go somewhere else.") {
                    Switch(on: Binding(
                        get: { prefs.addressBar },
                        set: { on in withAnimation(Motion.glide) { prefs.addressBar = on } }
                    ))
                }
                Rule()
                Line("Bookmarks in the sidebar", "Above the tabs, folders opening in place. Bookmark This Page adds the page you're on.") {
                    Switch(on: $prefs.sideBookmarks)
                }
            }
            Rule()
            Line("Copy address button", "Beside the page's title while the pointer is on it in the address bar, at the right end of the tab row. Off, Copy Address stays in the site's card and in the Tabs menu") {
                Switch(on: $prefs.copyDoor)
                    .accessibilityLabel("Copy address button")
            }
            Rule()
            Line("Tabs show", "Beside the title, and on a pinned square") {
                Segmented(options: Glyph.allCases.map { ($0, $0.title) }, selection: $prefs.glyph)
            }
            Rule()
            Line("Show how far you've read", "The tab you're on fills with grey as you scroll down the page") {
                Switch(on: $prefs.showsReading)
            }
            Rule()
            Line("Sleep tabs you aren't using", "After half an hour away they come back where you left them. Pinned tabs, sound, calls and anything typed stay awake.") {
                Switch(on: $prefs.sleepsTabs)
            }
            Rule()
            Line("Spaces", "Independent workspaces with their own sites and accounts. Switch from the Spaces menu, the rail or a swipe. Set your shortcuts in Keyboard.") {
                Switch(on: $prefs.usesSpaces)
            }
        }
    }

    // MARK: - passwords

    /// Says so when a password manager extension has taken the saving over.
    private var savingDetail: String {
        if #available(macOS 15.4, *), let name = Extensions.shared.passwordSavingTakenBy {
            return "\(name) does the saving — it asked Escale not to offer"
        }
        return "Asked once per site, never again for a site you refuse"
    }

    private var passwords: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.settingsGap)) {
            Card {
                Line("Your passwords", "In the macOS keychain, shown with Touch ID") {
                    Pill("Open…") {
                        browser.tuning = false
                        browser.managing = true
                    }
                }
                Rule()
                Line("Offer to save passwords", savingDetail) {
                    Switch(on: $prefs.savesPasswords)
                }
                Rule()
                Line("Fill in sign-ins", "Click a sign-in box and the accounts kept for the site hang from it") {
                    Switch(on: $prefs.fillsPasswords)
                }
                Rule()
                Line(
                    "Offer passkeys",
                    !prefs.passkeysPossible
                        ? "Needs an Apple entitlement this build doesn't have — off keeps sites to the password"
                        : Passkeys.access == .denied
                        ? "macOS was told no — System Settings › Privacy & Security › Passkeys Access for Web Browsers"
                        : "Touch ID or an iCloud passkey, on sites that offer one"
                ) {
                    Switch(on: $prefs.passkeys)
                }
                if !Vault.never.isEmpty {
                    Rule()
                    Line("Sites never asked", "\(Vault.never.count) sites told to stop offering") {
                        Pill("Forget") {
                            Vault.never = []
                            browser.announce("Every site can ask again")
                        }
                    }
                }
            }
            Card {
                Line("Bring yours in", "From Dia, Chrome, Arc, Brave or Edge on this Mac — nothing leaves it") {
                    Pill("Import…") {
                        browser.tuning = false
                        browser.managing = true
                    }
                }
            }
        }
    }

    // MARK: - developer

    private var developer: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.settingsGap)) {
            Card {
                Line("Alerts from local tools", "An agent or script on this Mac can send a short event to macOS. Nothing is checked online.") {
                    Switch(on: $prefs.developerAlerts)
                }
                if prefs.developerAlerts {
                    Rule()
                    Line("Agent sessions", "Completion and other events from coding agents") {
                        Switch(on: $prefs.alertAgents)
                    }
                    Rule()
                    Line("Builds", "Results from local build tools") {
                        Switch(on: $prefs.alertBuilds)
                    }
                    Rule()
                    Line("Pull requests", "Events sent by a local PR tool") {
                        Switch(on: $prefs.alertPRs)
                    }
                    Rule()
                    Line("Workflows", "Events sent by a local workflow tool") {
                        Switch(on: $prefs.alertWorkflows)
                    }
                }
            }
            Text("Local tools can send events through Escale's notification socket. Setup is in the README; GitHub is not connected automatically.")
                .font(.system(size: metrics.length(CardDensity.settings.detail)))
                .foregroundStyle(Palette.muted)
            if prefs.developerAlerts, let trouble = alerts.trouble {
                Text(trouble)
                    .font(.system(size: metrics.length(CardDensity.settings.detail)))
                    .foregroundStyle(Palette.unsafe)
            }
            Card {
                Line("Let a script drive Escale", "A local socket for testing. Its tabs open beside yours with a flask on them and never take over — see ./bench") {
                    Switch(on: $prefs.bench)
                }
            }
        }
    }

    // MARK: - privacy

    private var privacy: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.settingsGap)) {
            Card {
                Line("Block ads and trackers", shield.trouble ?? "Third parties whose only job is to watch") {
                    Switch(on: $prefs.shielded)
                }
                if let trouble = shield.trouble {
                    Rule()
                    Line(trouble, "Nothing is being blocked until this clears — try again, or restart Escale") {
                        Pill("Try again") { shield.compile() }
                    }
                }
                if let host = browser.hereHost, prefs.shielded, shield.trouble == nil {
                    Rule()
                    Line("Block on \(host)", "Turn off here if the site breaks — the page reloads") {
                        Switch(on: Binding(
                            get: { !Shield.shared.isPaused(on: host) },
                            set: { on in
                                Shield.shared.pause(host, !on)
                                browser.reload()
                            }
                        ))
                    }
                }
                Rule()
                Line("Camera and microphone", "What sites in this Space were allowed or refused") {
                    Pill("Forget choices") { browser.forgetCaptureChoices() }
                }
            }
            Card {
                Line("History", "Every address you have been to") {
                    Pill("Clear") { browser.clearHistory() }
                }
                Rule()
                Line("Cookies and sign-ins", "Signs you out of every site") {
                    Pill("Sign out of everything") { browser.clearSites() }
                }
                Rule()
                Line("Cache", "Only what was fetched to draw pages") {
                    Pill("Clear") { browser.clearCache() }
                }
            }
        }
    }

    // MARK: - about

    private var about: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.settingsGap)) {
            HStack(spacing: metrics.length(12)) {
                Logomark()
                    .fill(Palette.ink, style: FillStyle(eoFill: true))
                    .aspectRatio(Logomark.canvas.width / Logomark.canvas.height, contentMode: .fit)
                    .frame(height: metrics.length(32))
                VStack(alignment: .leading, spacing: metrics.length(2)) {
                    Text("Escale")
                        .font(.system(size: metrics.length(13.5), weight: .medium))
                        .foregroundStyle(Palette.ink)
                    Text("version \(Updater.version) · built on Search by Office Commun")
                        .font(.system(size: metrics.length(CardDensity.settings.detail)))
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.bottom, 2)

            Card {
                Line(versionTitle, versionDetail) { versionControl }
                Rule()
                Line("Found something wrong?", "Opens a draft with the version already in it") {
                    Pill("Send Feedback") { Links.writeFeedback() }
                }
            }

        }
    }

    /// The version line follows the newer build from found to fetched to
    /// in place; with none, it is simply this one.
    private var versionTitle: String {
        switch updater.stage {
        case .none: return "Updates"
        case .fetching(let next): return "Escale \(next.version) is downloading…"
        case .ready(let next): return "Escale \(next.version) is ready"
        case .offered(let next): return "Escale \(next.version) is out"
        }
    }

    private var versionDetail: String {
        switch updater.stage {
        case .none:
            return updater.lastChecked.map { "Checked \($0.formatted(.relative(presentation: .named))) — every 2 hours on its own" }
                ?? "Checked every 2 hours on its own"
        case .fetching(let next):
            return next.notes ?? "Quietly, in the background — nothing you have set is touched"
        case .ready(let next):
            return next.notes ?? "It's there the next time you open Escale"
        case .offered(let next):
            return next.notes ?? "Open the disk image, the same as the first time"
        }
    }

    @ViewBuilder
    private var versionControl: some View {
        switch updater.stage {
        case .none:
            Pill(updater.checking ? "Checking…" : "Check now") {
                updater.check { found in
                    if found == nil { browser.announce("This is the latest one") }
                }
            }
            .disabled(updater.checking)
        case .fetching:
            Ring(size: 12)
        case .ready:
            Pill("Relaunch now", filled: true) { updater.relaunch() }
        case .offered(let next):
            Pill("Download", filled: true) {
                browser.tuning = false
                browser.open(next.dmg, foreground: true)
            }
        }
    }

    // MARK: - doing

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = prefs.downloads
        panel.prompt = "Use this folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prefs.downloads = url
    }

    // MARK: - pieces

    /// A keystroke and what it does.

}

/// A row of choices in a grey track, one of them lifted out in white. The
/// white slides to the one you pick rather than appearing there.
struct Segmented<Option: Hashable>: View {
    let options: [(Option, String)]
    @Binding var selection: Option
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.cardDensity) private var density
    /// True when the control has the whole width to itself, so the choices
    /// share it evenly instead of each taking only what its word needs.
    var wide = false

    @Namespace private var slide

    var body: some View {
        HStack(spacing: metrics.length(2)) {
            ForEach(options, id: \.0) { option, title in
                Text(title)
                    .font(.system(size: metrics.length(density.control), weight: .regular))
                    .foregroundStyle(option == selection ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                    .fixedSize(horizontal: !wide, vertical: false)
                    .frame(maxWidth: wide ? .infinity : nil)
                    .padding(.horizontal, metrics.length(wide ? 4 : density.segmentX))
                    .padding(.vertical, metrics.length(density.segmentY))
                    .background {
                        if option == selection {
                            Chosen(radius: metrics.length(7))
                                .matchedGeometryEffect(id: "chosen", in: slide)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: metrics.length(7), style: .continuous))
                    .onTapGesture {
                        withAnimation(Motion.settle) { selection = option }
                    }
            }
        }
        .padding(metrics.length(2))
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: metrics.length(9), style: .continuous))
        .animation(Motion.settle, value: selection)
    }
}

/// The interface size as one window drawn at three sizes: the size in use
/// in ink, the others greyed, so the choice reads at a glance. Buttons
/// rather than a slider, because this panel grows with the size it sets: a
/// control uses the surrounding final geometry and stays aligned at every
/// interface size.
struct SizeChoice: View {
    @Binding var selection: InterfaceSize
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    @State private var hovered: InterfaceSize?

    var body: some View {
        HStack(spacing: metrics.length(2)) {
            ForEach(InterfaceSize.allCases) { size in
                Button {
                    withAnimation(Motion.settle) { selection = size }
                } label: {
                    Image(systemName: "macwindow")
                        .font(.system(size: 15 * size.factor / InterfaceSize.standard.factor))
                        .foregroundStyle(tint(size))
                        .frame(width: metrics.length(32), height: metrics.length(28))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? size : (hovered == size ? nil : hovered) }
                .help(size.title)
                .accessibilityLabel(size.title)
                .accessibilityAddTraits(size == selection ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Interface size")
    }

    private func tint(_ size: InterfaceSize) -> Color {
        if size == selection { return Palette.ink }
        return hovered == size ? Palette.muted : Palette.faint
    }
}

/// On or off, in ink rather than in blue.
struct Switch: View {
    @Binding var on: Bool
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.cardDensity) private var density

    var body: some View {
        Capsule()
            .fill(on ? Palette.ink : Palette.faint)
            .frame(width: metrics.length(density.switchWidth), height: metrics.length(density.switchHeight))
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(Palette.inverse)
                    .shadow(color: Palette.shadow, radius: metrics.length(1.5), y: metrics.length(1))
                    .padding(metrics.length(2))
            }
            .contentShape(Capsule())
            .onTapGesture { withAnimation(Motion.settle) { on.toggle() } }
            .animation(Motion.settle, value: on)
    }
}

/// A small capsule that does one thing. Outlined by default; filled in ink
/// when it is the thing you came here to press.
struct Pill: View {
    let title: String
    var filled = false
    var tint: Color = Palette.ink
    let action: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.cardDensity) private var density

    @State private var hovering = false

    init(_ title: String, filled: Bool = false, tint: Color = Palette.ink, action: @escaping () -> Void) {
        self.title = title
        self.filled = filled
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: metrics.length(density.control)))
                .foregroundStyle(filled ? Palette.inverse : tint)
                .padding(.horizontal, metrics.length(density.pillX))
                .padding(.vertical, metrics.length(density.pillY))
                .background(filled ? Palette.ink : (hovering ? Palette.hover : Palette.raised), in: Capsule())
                .overlay(Capsule().strokeBorder(filled ? .clear : Palette.hairline, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}
