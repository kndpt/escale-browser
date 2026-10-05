// Welcome and Settings render the same import interaction. Source access and
// mutations stay in MigrationFlow/Migration. The outline is capped at 200
// preview rows (all validated bookmarks still import); long names wrap.
// Every control is drawn by Escale — fields, category choices, buttons, the
// progress bar and expanding lists — so the import reads as part of the browser.
// Automatic browsers keep their category rows visible through preview, progress and results.
import SwiftUI
import UniformTypeIdentifiers

struct MigrationPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var flow: MigrationFlow
    @ObservedObject var migration: Migration
    let done: () -> Void
    let showsDone: Bool
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var choosingFile = false
    @State private var choosingFolder = false
    @State private var outline = false

    init(browser: Browser, flow: MigrationFlow, showsDone: Bool = true, done: @escaping () -> Void) {
        self.browser = browser; self.flow = flow; migration = flow.migration; self.done = done
        self.showsDone = showsDone
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if flow.browser?.checklist == true {
                choices
            } else {
                switch migration.phase {
                case .choosing: choices
                case .reading: progress("Reading your selected source…")
                case .preview: preview
                case .applying(let category): progress(category.map { "Saving \($0.rawValue)…" } ?? "Saving the import receipt…")
                case .finished, .stopped: result
                }
            }
        }
        .animation(reduceMotion ? nil : Motion.arrival, value: flow.browser)
        .animation(reduceMotion ? nil : Motion.arrival, value: migration.phase)
        .font(.system(size: metrics.length(Metrics.arrivalText)))
        .foregroundStyle(Palette.ink)
        .frame(maxWidth: metrics.length(Metrics.arrivalWidth), alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.html, .commaSeparatedText, .zip, .plainText, UTType(filenameExtension: "md") ?? .plainText]) { result in
            switch result {
            case .success(let url): flow.choose(url, folder: false)
            case .failure(let error): flow.selectionFailed(error)
            }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): flow.choose(url, folder: true)
            case .failure(let error): flow.selectionFailed(error)
            }
        }
        .onAppear { flow.begin(in: browser.spaceID) }
        .onChange(of: migration.phase) { _, phase in
            if phase == .finished || phase == .stopped { browser.logins.relist() }
        }
        .onExitCommand {
            if flow.busy { flow.cancel() }
            else { done() }
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalGap)) {
            if let receipt = migration.receipt, !receipt.finished {
                note("A previous import stopped after \(receipt.completed.count) saved categories. Reselect its source and destination to continue safely; existing data will be kept.")
            }
            if flow.browser == nil {
                MigrationSuggestions { flow.useInstalledBrowser($0) }
                    .transition(.opacity)
            }
            MigrationField(title: "Browser", options: MigrationBrowser.allCases.map { (Optional($0), $0.rawValue) },
                           selection: Binding(get: { flow.browser }, set: { if let value = $0 { flow.useInstalledBrowser(value) } }),
                           detail: { $0?.route.rawValue }, explanation: { $0?.routeDetail ?? "" },
                           available: { $0?.route != .unavailable })
                .disabled(flow.choosingLocked)
            if flow.browser == .escale {
                // A file of another Escale carries its own Spaces: it has no
                // source profile, destination Space or categories to choose.
                TransferImportPanel(browser: browser, transfer: browser.transfer, showsDone: showsDone, done: done)
            }
            // The passage appears once there is a source to show: before that,
            // the browser choice above is the only thing to do.
            if flow.browser != nil, flow.browser != .escale {
                MigrationPassage(browser: browser, flow: flow)
                    .transition(.opacity)
            }
            if let selectedBrowser = flow.browser, !selectedBrowser.automatic, selectedBrowser != .escale {
                note(selectedBrowser.guidance)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: metrics.length(Metrics.arrivalRowGap)) { sourceButtons }
                    VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalRowGap)) { sourceButtons }
                }
            }
            if let brand = flow.browser, brand.checklist, brand.automatic || flow.source != nil {
                MigrationSteps(browser: browser, flow: flow, brand: brand)
                if showsDone {
                    Button("Done") { done() }.buttonStyle(MigrationButton())
                        .disabled(flow.busy)
                }
            } else if flow.browser != nil, flow.browser != .escale, flow.browser?.checklist != true {
                if let message = flow.message { note(message) }
                if !flow.sources.isEmpty {
                    if let source = flow.source {
                        section("What to bring") {
                            HStack(spacing: metrics.length(Metrics.arrivalRowGap)) {
                                ForEach(MigrationCategory.allCases, id: \.self) { category in
                                    ArrivalChoice(title: category.rawValue.capitalized, symbol: category.symbol,
                                                  chosen: flow.categories.contains(category)) {
                                        if flow.categories.contains(category) { flow.categories.remove(category) }
                                        else { flow.categories.insert(category) }
                                    }
                                    .disabled(!source.categories.contains(category))
                                }
                            }
                            note(source.format == "csv" ? "Passwords stay hidden here and are added to Escale's keychain. Existing accounts are kept. You control the original export file."
                                 : "Only the categories available in this source can be selected. Sign-ins, cookies and passkeys are not transferred.")
                        }
                    }
                    Button("Preview import") { flow.preview(in: browser) }
                        .buttonStyle(MigrationButton())
                        .keyboardShortcut(.defaultAction)
                        .disabled(flow.categories.isEmpty || flow.busy)
                        .padding(.top, metrics.length(Metrics.arrivalRowGap))
                }
            }
        }
    }

    @ViewBuilder private var sourceButtons: some View {
        if flow.browser?.family != nil {
            Button { choosingFolder = true } label: { Label("Choose profile folder…", systemImage: "folder") }
                .buttonStyle(MigrationButton(kind: .secondary))
                .disabled(flow.busy)
        }
        Button { choosingFile = true } label: { Label("Choose export file…", systemImage: "doc") }
            .buttonStyle(MigrationButton(kind: .secondary))
            .disabled(flow.busy)
    }

    @ViewBuilder private var preview: some View {
        if let plan = migration.plan {
            let total = plan.bookmarkCount + plan.values.history.count + plan.values.passwords.count + plan.values.tabs.count
            heading("Ready to bring these over.",
                    "\(plan.source.browser) · \(plan.source.profile) → \(browser.spaces.first { $0.id == plan.destination }?.name ?? "Deleted Space")")
            VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalDetailGap)) {
                if plan.categories.contains(.bookmarks), let marks = migration.bookmarkPreview {
                    summary(.bookmarks, "Bookmarks and folders", "\(marks.added) to add · \(marks.kept) kept")
                    if marks.conflicts > 0 { note("\(marks.conflicts) source changes will keep your existing bookmark edits.") }
                }
                if plan.categories.contains(.history) { summary(.history, "History", "\(plan.values.history.count) places to consider") }
                if plan.categories.contains(.tabs) { summary(.tabs, "Tabs", "\(plan.values.tabs.count) sleeping addresses") }
                if plan.categories.contains(.passwords) { summary(.passwords, "Passwords", "\(plan.values.passwords.count) rows · values hidden") }
            }
            .padding(metrics.length(Metrics.arrivalCardInset))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: metrics.length(Metrics.arrivalChoiceRadius), style: .continuous))
            note("Existing data is kept. History uses the highest known visit count and retains up to 2,000 places overall. Existing password accounts are checked and kept during import.")
            if !plan.outline.isEmpty {
                VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalRowGap)) {
                    Button { withAnimation(Motion.settle) { outline.toggle() } } label: {
                        Label { Text("Bookmark outline") } icon: {
                            Image(systemName: "chevron.right").rotationEffect(.degrees(outline ? 90 : 0))
                        }
                    }
                    .buttonStyle(MigrationButton(kind: .quiet))
                    .padding(.leading, -metrics.length(Metrics.arrivalRowGap))
                    .accessibilityValue(outline ? "Expanded" : "Collapsed")
                    if outline { bookmarkOutline(plan) }
                }
            }
            ForEach(Array(plan.values.notices.enumerated()), id: \.offset) { _, text in note(text) }
            HStack(spacing: metrics.length(Metrics.arrivalRowGap)) {
                Button("Confirm import") { flow.confirm(in: browser) }
                    .buttonStyle(MigrationButton())
                    .keyboardShortcut(.defaultAction)
                    .disabled(total == 0)
                Button("Back to choices") { flow.again() }
                    .buttonStyle(MigrationButton(kind: .secondary))
            }
            if total == 0 {
                note("This selection contains no supported data. Choose another source or start without importing.")
            }
        }
    }

    private func bookmarkOutline(_ plan: MigrationPlan) -> some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalRowGap)) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalRowGap)) {
                    ForEach(plan.outline) { row in
                        HStack(alignment: .top, spacing: metrics.length(Metrics.arrivalRowGap)) {
                            Image(systemName: row.url == nil ? "folder" : "bookmark")
                                .foregroundStyle(Palette.muted)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading) {
                                Text(row.title.isEmpty ? (row.url?.absoluteString ?? "Untitled folder") : row.title)
                                    .lineLimit(2)
                                if let url = row.url { Text(url.absoluteString).foregroundStyle(Palette.muted).lineLimit(1) }
                            }
                        }
                        .padding(.leading, metrics.length(CGFloat(min(row.depth, 8)) * Metrics.migrationIndent))
                    }
                }
                .font(.system(size: metrics.length(Metrics.arrivalSmall)))
                .padding(metrics.length(Metrics.arrivalCardInset))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: metrics.length(Metrics.migrationOutline))
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: metrics.length(Metrics.arrivalChoiceRadius), style: .continuous))
            if plan.bookmarkCount > plan.outline.count { note("Showing the first \(plan.outline.count) entries. All \(plan.bookmarkCount) entries remain in the import.") }
        }
    }

    private func progress(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalDetailGap)) {
            HStack(spacing: metrics.length(Metrics.arrivalDetailGap)) {
                if !applying { MigrationSpinner() }
                Text(title).font(.system(size: metrics.length(Metrics.arrivalProgress)))
            }
            if applying, let plan = migration.plan {
                let saved = migration.receipt?.completed.count ?? 0
                MigrationBar(fraction: Double(saved) / Double(max(1, plan.categories.count)))
                note("\(saved) of \(plan.categories.count) categories saved")
                if case .applying(.passwords) = migration.phase {
                    note("\(migration.completedPasswords) of \(plan.values.passwords.count) password rows processed")
                }
            }
            note("Stop leaves completed work in place. You can reselect the source later without duplicating it.")
            Button("Stop import") { flow.cancel() }
                .buttonStyle(MigrationButton(kind: .secondary))
                .padding(.top, metrics.length(Metrics.arrivalLine))
        }
        .accessibilityElement(children: .contain)
    }

    private var applying: Bool {
        if case .applying = migration.phase { return true }
        return false
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalGap)) {
            heading(migration.phase == .finished ? "Your import is saved." : "Import stopped.",
                    migration.message ?? "Your original files are unchanged. Open your Space when you're ready.")
            if let receipt = migration.receipt {
                VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalDetailGap)) {
                    ForEach(receipt.completed, id: \.self) { category in
                        Label(category.rawValue.capitalized + " saved", systemImage: "checkmark")
                    }
                    if receipt.completed.contains(.bookmarks) { note("\(receipt.addedBookmarks) bookmarks and folders added · \(receipt.keptBookmarks) existing entries kept") }
                    if receipt.passwordAdds + receipt.passwordKeeps + receipt.passwordFailures > 0 {
                        note("Passwords: \(receipt.passwordAdds) added · \(receipt.passwordKeeps) kept · \(receipt.passwordFailures) failed")
                    }
                }
                if !receipt.finished { note("Saved categories and passwords already added remain. Choose the source again to retry the rest safely.") }
            }
            HStack(spacing: metrics.length(Metrics.arrivalRowGap)) {
                if showsDone {
                    Button("Open Space") {
                        if let id = migration.receipt?.destination, browser.spaces.contains(where: { $0.id == id }) { browser.switchSpace(to: id) }
                        done()
                    }
                    .buttonStyle(MigrationButton())
                    .keyboardShortcut(.defaultAction)
                }
                Button("Choose source again") { flow.again() }
                    .buttonStyle(MigrationButton(kind: .secondary))
            }
        }
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalDetailGap)) {
            Text(title).font(.system(size: metrics.length(Metrics.arrivalTitle), weight: .regular))
                .accessibilityAddTraits(.isHeader)
            Text(subtitle).foregroundStyle(Palette.muted)
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
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: metrics.length(Metrics.arrivalSmall))).foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func summary(_ category: MigrationCategory, _ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.length(Metrics.arrivalRowGap)) {
            Image(systemName: category.symbol).foregroundStyle(Palette.muted).accessibilityHidden(true)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(Palette.muted)
        }
    }
}

extension MigrationCategory {
    /// The symbol on its choice and in the preview.
    var symbol: String {
        switch self {
        case .bookmarks: return "bookmark"
        case .history: return "clock"
        case .passwords: return "key"
        case .tabs: return "rectangle.on.rectangle"
        }
    }
}

/// How far the import has come, in ink over the wash.
struct MigrationBar: View {
    let fraction: Double
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        Capsule().fill(Palette.wash)
            .frame(height: metrics.length(Metrics.arrivalBar))
            .overlay(alignment: .leading) {
                GeometryReader { track in
                    Capsule().fill(Palette.ink)
                        .frame(width: track.size.width * min(1, max(0, fraction)))
                }
            }
            .animation(reduceMotion ? nil : Motion.arrival, value: fraction)
            .accessibilityElement()
            .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

/// Work without a known end, such as reading a source: a thin arc turning.
/// It exists only while that work does, then stops with it.
struct MigrationSpinner: View {
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(Palette.ink, style: StrokeStyle(lineWidth: metrics.length(Metrics.arrivalSpinnerLine), lineCap: .round))
            .frame(width: metrics.length(Metrics.arrivalSpinner), height: metrics.length(Metrics.arrivalSpinner))
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(reduceMotion ? nil : Motion.spin, value: turning)
            .onAppear { turning = !reduceMotion }
            .onChange(of: reduceMotion) { _, reduced in turning = !reduced }
            .accessibilityHidden(true)
    }
}

/// The arrival's buttons, drawn by Escale rather than by AppKit. Ink for the
/// one thing a step is for; a raised plate with a fine edge for the
/// alternative beside it; bare muted text for a way back or out.
struct MigrationButton: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    var kind = Kind.primary

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, kind: kind)
    }

    /// A view of its own so the button can know the pointer is on it.
    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        @SwiftUI.Environment(\.chromeMetrics) private var metrics
        @SwiftUI.Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: metrics.length(Metrics.arrivalButtonRadius), style: .continuous)
            configuration.label
                .font(.system(size: metrics.length(Metrics.arrivalText), weight: kind == .quiet ? .regular : .medium))
                .lineLimit(1)
                .padding(.horizontal, metrics.length(kind == .quiet ? Metrics.arrivalRowGap : Metrics.arrivalButtonInset))
                .padding(.vertical, metrics.length(Metrics.arrivalButtonPad))
                .foregroundStyle(ink)
                .background { ground(shape) }
                .overlay { if kind == .secondary { shape.strokeBorder(Palette.edge, lineWidth: 1) } }
                .contentShape(shape)
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovering = $0 && enabled }
                .animation(Motion.quick, value: hovering)
        }

        private var ink: Color {
            switch kind {
            case .primary: return Palette.inverse
            case .secondary: return Palette.ink
            case .quiet: return hovering || configuration.isPressed ? Palette.ink : Palette.muted
            }
        }

        @ViewBuilder private func ground(_ shape: RoundedRectangle) -> some View {
            switch kind {
            case .primary:
                shape.fill(Palette.ink.opacity(configuration.isPressed ? 0.8 : hovering ? 0.88 : 1))
            case .secondary:
                ZStack {
                    shape.fill(Palette.raised)
                    shape.fill(configuration.isPressed ? Palette.wash : hovering ? Palette.hover : .clear)
                }
                .shadow(color: Palette.shadow.opacity(0.4), radius: 1.5, y: 0.5)
            case .quiet:
                shape.fill(configuration.isPressed ? Palette.wash : hovering ? Palette.hover : .clear)
            }
        }
    }
}
