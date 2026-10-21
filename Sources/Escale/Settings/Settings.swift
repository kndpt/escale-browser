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
    /// The row a search result opened, until its mark fades.
    @State private var found: Setting?
    @State private var shown: Set<Setting> = []
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduced

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
            case .general: return "gear default browser links search engine keywords downloads save folder files"
            case .appearance: return "theme light dark colours colors tone escale warm transparency contrast interface size faster shortcut animations motion"
            case .github: return "github bearings pull requests issues local search repository"
            case .routing: return "link routing route rules links open site host domain url space spaces meet routage liens"
            case .tabs: return "tabs spaces sidebar folded address bookmarks copy icons reading sleep delay idle"
            case .pages: return "web pages zoom default size links scroll middle button"
            case .migration: return "import migration bookmarks history passwords browser profiles safari firefox chrome arc zen orion aside"
            case .passwords: return "passwords passkeys keychain sign in import accounts"
            case .privacy: return "privacy ads trackers block camera microphone history cookies cache site data"
            case .extensions: return "extensions chrome web store add folder shared every space separate"
            case .developer: return "developer notifications alerts agents builds pull requests workflows script bench"
            case .keyboard: return "keyboard shortcuts keys commands bearings"
            case .about: return "about updates version feedback"
            }
        }

        func matches(_ query: String) -> Bool { Setting.words(query, in: title + " " + searchTerms) }

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
                    let settings = Setting.found(query)
                    if matches.isEmpty && settings.isEmpty {
                        Text("No settings found")
                            .font(.system(size: metrics.length(Metrics.settingsRowText)))
                            .foregroundStyle(Palette.muted)
                    } else {
                        pageGroup(matches)
                        foundGroup(settings)
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
                        let settings = Setting.found(query)
                        if matches.isEmpty && settings.isEmpty {
                            Text("No settings found")
                                .font(.system(size: metrics.length(Metrics.settingsRowText)))
                                .foregroundStyle(Palette.muted)
                                .padding(.horizontal, metrics.length(8))
                        } else {
                            pageGroup(matches)
                            if !settings.isEmpty {
                                Text("Settings")
                                    .font(.system(size: metrics.length(Metrics.settingsHeading), weight: .medium))
                                    .foregroundStyle(Palette.muted)
                                    .padding(.horizontal, metrics.length(8))
                                    .padding(.top, matches.isEmpty ? 0 : metrics.length(10))
                                    .padding(.bottom, metrics.length(3))
                                    .accessibilityAddTraits(.isHeader)
                                foundGroup(settings)
                            }
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

    private func foundGroup(_ items: [Setting]) -> some View {
        ForEach(items) { item in
            FoundRow(setting: item) { land(on: item) }
        }
    }

    /// Opens the row's page, brings the row into view and marks it a moment.
    private func land(on setting: Setting) {
        page = setting.page
        found = setting
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.foundHold) {
            guard found == setting else { return }
            withAnimation(reduced ? nil : Motion.foundFade) { found = nil }
        }
    }

    /// The row a search lands on: a hidden one's parent until it shows.
    private var landing: Setting? {
        found.map { shown.contains($0) ? $0 : $0.under ?? $0 }
    }

    /// A setting found by its words: what it is, then where it lives.
    private struct FoundRow: View {
        let setting: Setting
        let act: () -> Void
        @SwiftUI.Environment(\.chromeMetrics) private var metrics
        @State private var hovering = false

        var body: some View {
            Button(action: act) {
                VStack(alignment: .leading, spacing: metrics.length(1)) {
                    Text(setting.title)
                        .font(.system(size: metrics.length(Metrics.settingsRowText)))
                        .foregroundStyle(hovering ? Palette.ink : Palette.ink.opacity(0.85))
                        .lineLimit(2)
                    Text(setting.page.title)
                        .font(.system(size: metrics.length(Metrics.settingsHeading)))
                        .foregroundStyle(Palette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, metrics.length(8))
                .padding(.vertical, metrics.length(5))
                .background(
                    RoundedRectangle(cornerRadius: metrics.length(Metrics.settingsRowRadius), style: .continuous)
                        .fill(hovering ? Palette.hover : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: metrics.length(Metrics.settingsRowRadius), style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .accessibilityLabel("\(setting.title), in \(setting.page.title)")
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
                ScrollViewReader { proxy in
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
                    .environment(\.settingFound, landing)
                    .onPreferenceChange(SettingsShown.self) { shown = $0 }
                    .onChange(of: landing, initial: true) { _, target in
                        guard let target else { return }
                        // After the page that holds it has been laid out.
                        DispatchQueue.main.async {
                            withAnimation(reduced ? nil : Motion.settle) { proxy.scrollTo(target, anchor: .center) }
                        }
                    }
                }
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
                Line(.defaultBrowser, isDefault ? "Escale is the default browser on this Mac" : nil) {
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
                Line(.engine, searchDetail) {
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
                Rule()
                Line(.keywords, keywordDetail) { EmptyView() }
                // One per line, so the list is plain text to write, read and carry.
                ZStack(alignment: .topLeading) {
                    if prefs.searchKeywords.isEmpty {
                        Text("npm https://www.npmjs.com/search?q=%s")
                            .foregroundStyle(Palette.muted.opacity(0.8))
                            .padding(.leading, metrics.length(5))
                            .accessibilityHidden(true)
                    }
                    TextEditor(text: $prefs.searchKeywords)
                        .scrollContentBackground(.hidden)
                        .autocorrectionDisabled()
                        .foregroundStyle(Palette.ink)
                        .accessibilityLabel("Search keywords")
                }
                .font(.system(size: metrics.length(11.5)))
                .frame(height: metrics.length(Metrics.settingsKeywords))
                .padding(.horizontal, metrics.length(3))
                .padding(.vertical, metrics.length(5))
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: metrics.length(7), style: .continuous))
                .padding(.horizontal, metrics.length(CardDensity.settings.inset))
                .padding(.bottom, metrics.length(CardDensity.settings.pad))
            }
            Card {
                Line(.downloads, prefs.downloads.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    Pill("Change…") { chooseFolder() }
                }
                Rule()
                Line(.askWhere) {
                    Switch(on: $prefs.asksWhereToSave)
                }
            }
        }
    }

    // MARK: - web pages

    private var webPages: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.settingsGap)) {
            Card {
                Line(.defaultZoom) {
                    MigrationField(title: "Default zoom", options: PageZoom.defaults.map { ($0, "\($0)%") },
                                   selection: $prefs.defaultZoom, height: Metrics.settingsRow, showsTitle: false)
                        .frame(width: metrics.length(Metrics.settingsZoomWidth))
                        .accessibilityLabel("Default zoom")
                }
                Rule()
                Line(.showsLinks) {
                    Switch(on: $prefs.showsLinks)
                }
                Rule()
                Line(.selection) {
                    Switch(on: $prefs.selectionMenu)
                }
                Rule()
                Line(.autoScroll) {
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
            Line(.theme) {
                Segmented(options: Look.allCases.map { ($0, $0.title) }, selection: $prefs.look)
            }
            Rule()
            Line(.colours) {
                EmptyView()
            }
            ToneChoice(selection: $prefs.tone, look: prefs.look)
            Rule()
            Line(.transparency, transparencyDetail) {
                Segmented(options: Depth.allCases.map { ($0, $0.title) }, selection: $prefs.depth)
                    .opacity(reducing ? 0.45 : 1)
            }
            Rule()
            Line(.contrast, increasing ? "On in macOS's Accessibility settings, which Escale follows" : nil) {
                Switch(on: $prefs.increasesContrast)
                    .accessibilityLabel("Increase contrast")
            }
            Rule()
            Line(.fasterShortcuts) {
                Switch(on: $prefs.fasterShortcuts)
                    .accessibilityLabel("Faster shortcut animations")
            }
            Rule()
            Line(.interfaceSize) {
                SizeChoice(selection: $prefs.interfaceSize)
            }
        }
    }

    /// Says what overrides the level, so the choice never looks broken.
    private var transparencyDetail: String {
        if reducing {
            return "Solid while Reduce transparency is on in macOS"
        }
        return Setting.transparency.detail
    }


    private var searchDetail: String {
        guard prefs.engine == .custom else { return Setting.engine.detail }
        guard Engine.accepts(prefs.customEngine) else {
            return "An http or https address with %s where the words go. Until then, Google"
        }
        return "Words go to \(prefs.engine.name(custom: prefs.customEngine))"
    }

    private var keywordDetail: String {
        switch Keyword.refused(prefs.searchKeywords) {
        case 0: return Setting.keywords.detail
        case 1: return "One line isn't a keyword and an http or https address with %s, and is left out"
        case let count: return "\(count) lines aren't a keyword and an http or https address with %s, and are left out"
        }
    }

    // MARK: - tabs

    private var tabs: some View {
        Card {
            Line(.sidebar) {
                Switch(on: Binding(
                    get: { prefs.sidebar },
                    set: { on in withAnimation(Motion.glide) { prefs.sidebar = on } }
                ))
            }
            if prefs.sidebar {
                Rule()
                Line(.sideFolded) {
                    Switch(on: $prefs.sideHides)
                }
                Rule()
                // See Bar.swift.
                Line(.addressBar) {
                    Switch(on: Binding(
                        get: { prefs.addressBar },
                        set: { on in withAnimation(Motion.glide) { prefs.addressBar = on } }
                    ))
                }
                Rule()
                Line(.sideBookmarks) {
                    Switch(on: $prefs.sideBookmarks)
                }
            }
            Rule()
            Line(.copyDoor) {
                Switch(on: $prefs.copyDoor)
                    .accessibilityLabel("Copy address button")
            }
            Rule()
            Line(.glyph) {
                Segmented(options: Glyph.allCases.map { ($0, $0.title) }, selection: $prefs.glyph)
            }
            Rule()
            Line(.reading) {
                Switch(on: $prefs.showsReading)
            }
            Rule()
            Line(.sleep, "After \(prefs.sleepDelay.phrase) away they come back where you left them. Pinned tabs, sound, calls and anything typed stay awake.") {
                Switch(on: $prefs.sleepsTabs)
            }
            if prefs.sleepsTabs {
                Rule()
                Line(.sleepAfter) {
                    Segmented(options: SleepDelay.allCases.map { ($0, $0.title) }, selection: $prefs.sleepDelay)
                }
            }
            Rule()
            Line(.spaces) {
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
        return Setting.savePasswords.detail
    }

    private var passwords: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.settingsGap)) {
            Card {
                Line(.vault) {
                    Pill("Open…") {
                        browser.tuning = false
                        browser.managing = true
                    }
                }
                Rule()
                Line(.savePasswords, savingDetail) {
                    Switch(on: $prefs.savesPasswords)
                }
                Rule()
                Line(.fillPasswords) {
                    Switch(on: $prefs.fillsPasswords)
                }
                Rule()
                Line(
                    .passkeys,
                    !prefs.passkeysPossible
                        ? "Needs an Apple entitlement this build doesn't have — off keeps sites to the password"
                        : Passkeys.access == .denied
                        ? "macOS was told no — System Settings › Privacy & Security › Passkeys Access for Web Browsers"
                        : nil
                ) {
                    Switch(on: $prefs.passkeys)
                }
                if !Vault.never.isEmpty {
                    Rule()
                    Line(.neverAsked, "\(Vault.never.count) sites told to stop offering") {
                        Pill("Forget") {
                            Vault.never = []
                            browser.announce("Every site can ask again")
                        }
                    }
                }
            }
            Card {
                Line(.importPasswords) {
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
                Line(.alerts) {
                    Switch(on: $prefs.developerAlerts)
                }
                if prefs.developerAlerts {
                    Rule()
                    Line(.agents) {
                        Switch(on: $prefs.alertAgents)
                    }
                    Rule()
                    Line(.builds) {
                        Switch(on: $prefs.alertBuilds)
                    }
                    Rule()
                    Line(.pullRequests) {
                        Switch(on: $prefs.alertPRs)
                    }
                    Rule()
                    Line(.workflows) {
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
                Line(.bench) {
                    Switch(on: $prefs.bench)
                }
            }
        }
    }

    // MARK: - privacy

    private var privacy: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.settingsGap)) {
            Card {
                Line(.shield, shield.trouble) {
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
                Line(.capture) {
                    Pill("Forget choices") { browser.forgetCaptureChoices() }
                }
            }
            Card {
                Line(.history) {
                    Pill("Clear") { browser.clearHistory() }
                }
                Rule()
                Line(.cookies) {
                    Pill("Sign out of everything") { browser.clearSites() }
                }
                Rule()
                Line(.cache) {
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
                Line(.feedback) {
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
            return Updater.line(checked: updater.lastChecked, failed: updater.failed)
        case .fetching(let next):
            return next.notes ?? "Quietly, in the background — nothing you have set is touched"
        case .ready(let next):
            return next.notes ?? "It's there the next time you open Escale"
        case .offered(let next):
            return updater.refusal?.said ?? next.notes ?? "Open the disk image, the same as the first time"
        }
    }

    @ViewBuilder
    private var versionControl: some View {
        switch updater.stage {
        case .none:
            Pill(updater.checking ? "Checking…" : "Check now") { checkNow() }
                .disabled(updater.checking)
        case .fetching:
            Ring(size: 12)
        case .ready:
            Pill("Relaunch now", filled: true) { updater.relaunch() }
        case .offered(let next):
            if updater.refusal == .interrupted {
                Pill(updater.checking ? "Checking…" : "Try again", filled: true) { checkNow() }
                    .disabled(updater.checking)
            } else {
                Pill("Download", filled: true) {
                    browser.tuning = false
                    browser.open(next.dmg, foreground: true)
                }
            }
        }
    }

    private func checkNow() {
        updater.check { read in
            if let line = read.said { browser.announce(line) }
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
