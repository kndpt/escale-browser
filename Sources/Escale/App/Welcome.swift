// Arrival is four short steps, not a prerequisite. First the choices that
// change what the very next window looks like — theme, where tabs go, which
// browser opens links — because they are seen at once and cost nothing to
// undo. On a first arrival with no extension yet, a fifth step asks how
// extensions are kept (WelcomeExtensions.swift): the one choice that lasts,
// so never beside the free ones. Then the offer to bring bookmarks, history
// and passwords along, which can be skipped and done later from Settings. Choosing to import embeds the
// same interaction as Settings. No profile discovery runs before selection.
// Then Bearings GitHub (WelcomeGitHub.swift): it works without an account, so
// connecting and staying local are offered side by side. It comes late because
// the device code is typed on github.com, in a tab Welcome steps aside for
// (WelcomeReturn.swift). Last, every path lands on what is now set up
// (WelcomeDone.swift), and only its button ends the arrival.
//
// Every control here is drawn by Escale (MigrationButton, ArrivalChoice) rather
// than taken from AppKit, so the first screen already looks like the browser
// it opens onto. The column has one height at every step: the mark and the
// progress stay at its top, Back and the step's actions on one row at its
// bottom, and only the step between them changes, scrolling if it must. What
// is pressed to move on is never somewhere else on the next step.
import SwiftUI

struct WelcomePanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject private var migration: MigrationFlow
    @ObservedObject private var importWork: Migration
    @ObservedObject private var transfer: TransferFlow
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var advancing = true
    @State private var step: Step
    @State private var isDefault = Links.isDefault
    @State private var defaultResult: String?
    @State private var importedDuringSetup: Bool
    @State private var confirmingSkip = false
    @State private var githubMode = GitHubSpecimen.Mode.github
    /// Whether this arrival asks how extensions are kept, settled as it
    /// opens so the steps it counts don't change under it.
    @State private var asksExtensions: Bool
    @State private var sharesExtensions: Bool

    enum Step: Int { case personalise, extensions, bring, importing, github, done }

    init(browser: Browser, prefs: Preferences) {
        self.browser = browser
        self.prefs = prefs
        migration = browser.migration
        importWork = browser.migration.migration
        transfer = browser.transfer
        _step = State(initialValue: browser.welcomeReturn.step ?? .personalise)
        _importedDuringSetup = State(initialValue: browser.welcomeReturn.imported)
        _asksExtensions = State(initialValue: WelcomePanel.asksForExtensions(
            welcomed: prefs.welcomed,
            decided: prefs.sharedExtensions != nil && !browser.welcomeReturn.choseExtensions,
            installed: browser.hasExtensions))
        // The first answer is preselected, as on a first arrival.
        _sharesExtensions = State(initialValue: prefs.sharedExtensions ?? true)
    }

    var body: some View {
        ZStack {
            Envelope()
            GeometryReader { window in
                let inset = metrics.length(Metrics.arrivalInset)
                VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalGap)) {
                    header
                    ScrollView {
                        ZStack(alignment: .topLeading) {
                            Group {
                                switch step {
                                case .personalise: personalise
                                case .extensions: extensions
                                case .bring: bring
                                case .importing: importing
                                case .github: github
                                case .done: done
                                }
                            }
                            .id(step)
                            .transition(pageTransition)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ZStack { footer.id(step).transition(.opacity) }
                }
                .font(.system(size: metrics.length(Metrics.arrivalText)))
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: metrics.length(Metrics.arrivalWidth), alignment: .leading)
                .frame(height: min(window.size.height - inset * 2, metrics.length(Metrics.arrivalHeight)))
                .padding(inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: recommend)
        .onChange(of: importWork.phase) { previous, phase in
            // Retain successful/partial imports across source changes and Back.
            // A preview or an old receipt alone must never count as importing.
            if case .applying = previous,
               phase == .finished || phase == .stopped,
               let receipt = importWork.receipt,
               !receipt.completed.isEmpty || receipt.passwordAdds > 0 {
                importedDuringSetup = true
            }
        }
        .onChange(of: transfer.bringing) { _, state in
            // An Escale file counts too: it is imported by its own flow.
            if case .finished(let report) = state, report.changed { importedDuringSetup = true }
        }
        .alert("Continue without importing?", isPresented: $confirmingSkip) {
            Button("Cancel", role: .cancel) {}
            Button("Continue without importing") { browser.migration.pause(); go(.github) }
        } message: {
            Text("Nothing has been imported during this setup. You can import later in Settings → Import Data.")
        }
    }

    /// A first arrival starts from the sidebar, the layout Escale is designed
    /// around. Only then: reopening Welcome from the menu keeps what was chosen.
    private func recommend() {
        if !prefs.welcomed { prefs.sidebar = true }
    }

    // MARK: - header

    private var header: some View {
        HStack(alignment: .center) {
            Group {
                if step == .done { LandingMark() }
                else { Logomark().fill(Palette.ink, style: FillStyle(eoFill: true)) }
            }
                .aspectRatio(Logomark.canvas.width / Logomark.canvas.height, contentMode: .fit)
                .frame(height: metrics.length(Metrics.arrivalMark))
                .accessibilityHidden(true)
            Spacer()
            progress
        }
    }

    /// Where you are in the four steps, five with extensions: the current
    /// one drawn long, those done in ink, those ahead faint.
    private var progress: some View {
        let extra = asksExtensions ? 1 : 0
        let count = 4 + extra
        let position = switch step {
        case .personalise: 0
        case .extensions: 1
        case .bring, .importing: 1 + extra
        case .github: 2 + extra
        case .done: 3 + extra
        }
        return HStack(spacing: metrics.length(Metrics.arrivalDot)) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index <= position ? Palette.ink : Palette.faint)
                    .frame(width: metrics.length(index == position ? Metrics.arrivalDotWide : Metrics.arrivalDot),
                           height: metrics.length(Metrics.arrivalDot))
            }
        }
        .animation(reduceMotion ? nil : Motion.arrival, value: position)
        .accessibilityElement()
        .accessibilityLabel("Step \(position + 1) of \(count)")
    }

    // MARK: - step one: make it yours

    private var personalise: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalGap)) {
            heading("Make room for your projects.",
                    "Your code, its docs and its pull requests, one Space per project. A native Mac browser, with no account required.")
            section("Appearance") {
                HStack(spacing: metrics.length(Metrics.arrivalRowGap)) {
                    ForEach([Look.system, .light, .dark]) { look in
                        ArrivalChoice(title: look.title, symbol: look.symbol, chosen: prefs.look == look) {
                            prefs.look = look
                        }
                    }
                }
            }
            section("Tabs") {
                HStack(spacing: metrics.length(Metrics.arrivalRowGap)) {
                    ArrivalChoice(title: "In the sidebar", symbol: "sidebar.left", chosen: prefs.sidebar, badge: "Recommended") {
                        prefs.sidebar = true
                    }
                    ArrivalChoice(title: "Along the top", symbol: "rectangle.topthird.inset.filled", chosen: !prefs.sidebar) {
                        prefs.sidebar = false
                    }
                }
                note("Escale is built around the sidebar: Spaces, bookmarks and tabs in one column.")
            }
            defaultBrowser
        }
    }

    private var defaultBrowser: some View {
        HStack(spacing: metrics.length(Metrics.arrivalDetailGap)) {
            VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalLine)) {
                Text("Open links in Escale")
                note(defaultResult ?? (isDefault ? "Escale is the default browser on this Mac." : "Links you click in other apps open here. You can change it later in Settings."))
            }
            Spacer(minLength: metrics.length(Metrics.arrivalDetailGap))
            if isDefault {
                Image(systemName: "checkmark")
                    .font(.system(size: metrics.length(Metrics.arrivalText), weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .accessibilityLabel("Escale is the default browser")
            } else {
                Button("Make default") {
                    Links.becomeDefault { _ in
                        isDefault = Links.isDefault
                        defaultResult = isDefault ? "Links now open in Escale." : "The default browser has not changed. You can choose it later in Settings."
                    }
                }
                .buttonStyle(MigrationButton(kind: .secondary))
            }
        }
        .padding(metrics.length(Metrics.arrivalCardInset))
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: metrics.length(Metrics.arrivalChoiceRadius), style: .continuous))
    }

    // MARK: - extensions, on a first arrival

    private var extensions: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalGap)) {
            heading("How should your extensions work?",
                    "Each Space keeps its own sites, sign-ins and history. Choose whether extensions follow you into every Space.")
            HStack(alignment: .top, spacing: metrics.length(Metrics.arrivalRowGap)) {
                ExtensionModeChoice(shared: true, chosen: sharesExtensions, badge: "Recommended") { sharesExtensions = true }
                ExtensionModeChoice(shared: false, chosen: !sharesExtensions) { sharesExtensions = false }
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: metrics.length(Metrics.arrivalLine) * 2) {
                Image(systemName: "info.circle")
                    .font(.system(size: metrics.length(Metrics.arrivalSmall)))
                    .foregroundStyle(Palette.muted)
                    .accessibilityHidden(true)
                note("You choose this once. Sites and sign-ins stay separate in every Space either way.")
            }
        }
    }

    // MARK: - step two: bring your browsing

    private var bring: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalGap)) {
            heading("Bring your browsing with you.",
                    "From Safari, Chrome, Arc, Firefox and others. Choose what to import into your Space.")
            VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalDetailGap)) {
                feature("bookmark", "Bookmarks and history", "From a browser profile or an exported file")
                feature("key", "Passwords", "Added to your Mac's keychain, never shown here")
                feature("lock", "Stays on this Mac", "Your other browser and its files are left as they are")
            }
            note("You can import later in Settings → Import Data.")
        }
    }

    // MARK: - step three: the import itself

    private var importing: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalGap)) {
            MigrationPanel(browser: browser, flow: browser.migration, showsDone: false) { go(.github) }
        }
    }

    // MARK: - step four: GitHub, connected or local

    private var github: some View {
        let access = browser.github.owner(for: browser.spaceID).access
        return VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalGap)) {
            heading("Your pull requests, one keystroke away.",
                    "Bearings finds the pull requests and issues you visit, by a few words or a number, and takes you back to their tab.")
            WelcomeGitHub(access: access, mode: $githubMode,
                          stroke: prefs.keyBindings.keys(.searchGitHub).first)
            if access.canConnect { note("You can connect later in Settings → GitHub.") }
        }
    }

    /// Where GitHub's answer, or no GitHub at all, leads.
    private func leaveGitHub(_ address: URL?) {
        guard let address else { go(.done); return }
        let access = browser.github.owner(for: browser.spaceID).access
        browser.welcomeReturn.imported = importedDuringSetup
        browser.welcomeReturn.pause(browser, for: access, at: address)
    }

    // MARK: - step five: all set

    private var done: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalGap)) {
            heading("You’re all set.",
                    "Escale is ready, the way you chose. All of it can change in Settings.")
            WelcomeDone(prefs: prefs, access: browser.github.owner(for: browser.spaceID).access,
                        imported: importedDuringSetup, isDefault: isDefault,
                        stroke: prefs.keyBindings.keys(.searchGitHub).first)
            note("Welcome stays in the Escale menu.")
        }
    }

    // MARK: - the row at the bottom

    /// Back on the left, the step's actions on the right with the one that
    /// moves on last, at the same place on every step.
    private var footer: some View {
        HStack(spacing: metrics.length(Metrics.arrivalRowGap)) {
            if let back {
                Button(action: back) { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(MigrationButton(kind: .quiet))
                    .padding(.leading, -metrics.length(Metrics.arrivalRowGap))
                    .disabled(step == .importing && (migration.busy || transfer.bringingBusy))
            }
            Spacer(minLength: 0)
            actions
        }
    }

    private var back: (() -> Void)? {
        switch step {
        case .personalise: return nil
        case .extensions: return { go(.personalise) }
        case .bring: return { go(asksExtensions ? .extensions : .personalise) }
        case .importing: return { browser.migration.pause(); go(.bring) }
        case .github: return { go(.bring) }
        case .done: return { go(.github) }
        }
    }

    @ViewBuilder private var actions: some View {
        switch step {
        case .personalise:
            Button("Continue") { go(asksExtensions ? .extensions : .bring) }
                .buttonStyle(MigrationButton())
                .keyboardShortcut(.defaultAction)
        case .extensions:
            Button("Continue") {
                browser.chooseExtensions(shared: sharesExtensions)
                go(.bring)
            }
            .buttonStyle(MigrationButton())
            .keyboardShortcut(.defaultAction)
        case .bring:
            Button("Continue without importing") { go(.github) }
                .buttonStyle(MigrationButton(kind: .secondary))
            Button("Import from another browser") { go(.importing) }
                .buttonStyle(MigrationButton())
                .keyboardShortcut(.defaultAction)
        case .importing:
            Button(importedDuringSetup ? "Continue" : "Continue without importing…") {
                if importedDuringSetup { browser.migration.pause(); go(.github) }
                else { confirmingSkip = true }
            }
            .buttonStyle(MigrationButton(kind: importedDuringSetup ? .primary : .secondary))
            .disabled(migration.busy || transfer.bringingBusy)
            .animation(reduceMotion ? nil : Motion.arrival, value: importedDuringSetup)
        case .github:
            WelcomeGitHubActions(access: browser.github.owner(for: browser.spaceID).access,
                                 mode: $githubMode, next: leaveGitHub)
        case .done:
            Button("Start Browsing") { finish() }
                .buttonStyle(MigrationButton())
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - pieces

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalDetailGap)) {
            Text(title)
                .font(.system(size: metrics.length(Metrics.arrivalTitle), weight: .regular))
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalRowGap)) {
            Text(title)
                .font(.system(size: metrics.length(Metrics.arrivalSmall), weight: .medium))
                .foregroundStyle(Palette.muted)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        ArrivalFeature(symbol: symbol, title: title, detail: detail)
    }

    private func note(_ text: String) -> some View { ArrivalNote(text: text) }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let travel = metrics.length(Metrics.arrivalTravel) * (advancing ? 1 : -1)
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: travel)),
                           removal: .opacity.combined(with: .offset(x: -travel)))
    }

    private func go(_ next: Step) {
        advancing = next.rawValue > step.rawValue
        withAnimation(reduceMotion ? nil : Motion.arrival) { step = next }
    }

    private func finish() {
        browser.welcomeReturn.end()
        browser.migration.leave()
        prefs.welcomed = true
        browser.welcoming = false
    }
}

/// A symbol on its grey tile beside a title and a muted detail: what a step offers.
struct ArrivalFeature: View {
    let symbol: String
    let title: String
    let detail: String
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.length(Metrics.arrivalDetailGap)) {
            Image(systemName: symbol)
                .font(.system(size: metrics.length(Metrics.arrivalText)))
                .frame(width: metrics.length(Metrics.arrivalFeature), height: metrics.length(Metrics.arrivalFeature))
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: metrics.length(Metrics.arrivalButtonRadius), style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalLine)) {
                Text(title)
                ArrivalNote(text: detail)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Small muted text that wraps: a hint, a consequence, where to find it later.
struct ArrivalNote: View {
    let text: String
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        Text(text)
            .font(.system(size: metrics.length(Metrics.arrivalSmall)))
            .foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One of a few large choices laid side by side: a symbol over its name. The
/// chosen one stands on Escale's selection surface with its ink at full
/// strength; the others stay on the grey wash, muted until the pointer is on
/// them. The same language as the Settings segments, at a size meant to be
/// read at a glance on a first screen. A badge in the corner names the one
/// Escale recommends; the import uses the same cards for its categories.
struct ArrivalChoice: View {
    let title: String
    let symbol: String
    let chosen: Bool
    var badge: String? = nil
    let action: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.isEnabled) private var enabled
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.length(Metrics.arrivalChoiceRadius), style: .continuous)
        Button(action: action) {
            VStack(spacing: metrics.length(Metrics.arrivalDetailGap)) {
                Image(systemName: symbol)
                    .font(.system(size: metrics.length(Metrics.arrivalChoiceGlyph)))
                    .frame(height: metrics.length(Metrics.arrivalChoiceGlyph))
                Text(title)
                    .font(.system(size: metrics.length(Metrics.arrivalChoiceLabel), weight: chosen ? .medium : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(chosen || hovering ? Palette.ink : Palette.muted)
            .frame(maxWidth: .infinity)
            .frame(height: metrics.length(Metrics.arrivalChoiceHeight))
            .background {
                if chosen { Chosen(shape: shape) } else { shape.fill(hovering ? Palette.hover : Palette.wash) }
            }
            .overlay(shape.strokeBorder(chosen ? Palette.edge : Palette.hairline, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text(badge)
                        .font(.system(size: metrics.length(Metrics.arrivalBadge), weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, metrics.length(Metrics.arrivalBadgeInset))
                        .padding(.vertical, metrics.length(Metrics.arrivalLine))
                        .background(Palette.wash, in: Capsule())
                        .padding(metrics.length(Metrics.arrivalRowGap))
                }
            }
            .contentShape(shape)
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 && enabled }
        .animation(Motion.quick, value: hovering)
        .animation(reduceMotion ? nil : Motion.arrival, value: chosen)
        .accessibilityLabel(badge.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

extension Look {
    /// The symbol on its arrival choice: the Mac's half-and-half for System.
    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}
