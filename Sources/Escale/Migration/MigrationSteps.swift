// An automatic browser's import stays on one checklist: a row owns no work, it renders the
// shared flow's actual read/write phase. Only the active row animates;
// completed results remain visible until the source or destination changes.
// Compact rows show one action; source recovery precedes the checklist and
// alternative exports stay behind a disclosure until requested. The source
// itself is chosen, refreshed and shown finding in MigrationPassage.
import SwiftUI
import UniformTypeIdentifiers

struct MigrationSteps: View {
    @ObservedObject var browser: Browser
    @ObservedObject var flow: MigrationFlow
    @ObservedObject var migration: Migration
    let brand: MigrationBrowser
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var export: MigrationCategory?
    @State private var choosingExport = false
    @State private var choosingFolder = false
    @State private var alternatives = false

    init(browser: Browser, flow: MigrationFlow, brand: MigrationBrowser) {
        self.browser = browser; self.flow = flow; migration = flow.migration; self.brand = brand
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalDetailGap)) {
            if !flow.discovering, flow.source == nil {
                VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalDetailGap)) {
                    Label(flow.message ?? brand.nothingFound,
                          systemImage: "exclamationmark.circle")
                        .foregroundStyle(Palette.unsafe)
                    HStack(spacing: metrics.length(Metrics.arrivalRowGap)) {
                        Button("Choose \(brand.rawValue) data folder…") { choosingFolder = true }
                            .buttonStyle(MigrationButton(kind: .secondary))
                        InfoTip(label: "Which \(brand.rawValue) folder to choose", explanation: brand.folderHelp)
                    }
                }
            } else if let message = flow.message, flow.source != nil {
                note(message)
            }

            if flow.source != nil || flow.activeStep == .passwords {
                VStack(alignment: .leading, spacing: 0) {
                    if flow.source != nil {
                        row(.bookmarks)
                        Divider().overlay(Palette.hairline)
                        row(.history)
                        Divider().overlay(Palette.hairline)
                    }
                    if flow.source?.categories.contains(.tabs) == true {
                        row(.tabs)
                        Divider().overlay(Palette.hairline)
                    }
                    row(.passwords)
                    Divider().overlay(Palette.hairline)
                    ForEach(Array(brand.unavailable.filter { flow.source?.categories.contains(.tabs) != true || $0.title != "Tabs & workspaces" }.enumerated()), id: \.offset) { index, item in
                        unavailable(item.title, symbol: item.symbol, reason: item.reason)
                            .padding(.top, index == 0 ? metrics.length(Metrics.arrivalDetailGap) : 0)
                    }
                }
                .padding(.top, metrics.length(Metrics.arrivalDetailGap))
                .transition(.opacity)
            }

            Button { alternatives.toggle() } label: {
                HStack(spacing: metrics.length(Metrics.arrivalRowGap)) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(alternatives ? 90 : 0))
                    Text("Other options")
                    Spacer(minLength: 0)
                }
                .frame(minHeight: metrics.length(Metrics.migrationChoiceHeight))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.system(size: metrics.length(Metrics.arrivalSmall)))
            .foregroundStyle(Palette.muted)
            .accessibilityValue(alternatives ? "Expanded" : "Collapsed")
            .disabled(flow.choosingLocked)
            if alternatives {
                VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalRowGap)) {
                    HStack(spacing: metrics.length(Metrics.arrivalLine)) {
                        Button(brand.bookmarkExports.contains("txt") ? "Import links or bookmarks from a file…" : "Import bookmarks from a file…") {
                            export = .bookmarks; choosingExport = true
                        }
                        if let help = brand.exportHelp { InfoTip(label: "Which file to choose", explanation: help) }
                    }
                    if flow.source == nil {
                        Button("Import passwords from a file…") { export = .passwords; choosingExport = true }
                    }
                    if brand.automatic, flow.source != nil { Button("Choose another data folder…") { choosingFolder = true } }
                }
                .buttonStyle(MigrationButton(kind: .quiet))
                .padding(.top, metrics.length(Metrics.arrivalRowGap))
                .disabled(flow.choosingLocked)
            }
        }
        .animation(reduceMotion ? nil : Motion.arrival, value: flow.discovering)
        .animation(reduceMotion ? nil : Motion.arrival, value: flow.selected)
        .animation(reduceMotion ? nil : Motion.arrival, value: alternatives)
        .onChange(of: flow.folderWanted, initial: true) { _, wanted in
            if wanted { flow.folderOffered(); choosingFolder = true }
        }
        .fileImporter(isPresented: $choosingExport, allowedContentTypes: export == .passwords ? [.commaSeparatedText]
                      : brand.bookmarkExports.compactMap { UTType(filenameExtension: $0) }) { result in
            switch result {
            case .success(let url): if let export { flow.chooseStepExport(url, category: export, in: browser) }
            case .failure(let error): flow.selectionFailed(error)
            }
        }
        // Apart from the export picker above, which has no folder to start from.
        .background {
            Color.clear
                .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                    switch result {
                    case .success(let url): flow.choose(url, folder: true)
                    case .failure(let error): flow.selectionFailed(error)
                    }
                }
                .fileDialogMessage("macOS lets Escale read \(brand.rawValue) only from a folder you choose. Press Open to allow it.")
                .fileDialogDefaultDirectory(brand.location(user: FileManager.default.homeDirectoryForCurrentUser, testRoot: nil))
        }
    }

    /// An export chosen from Other options replaces the automatic source.
    private var exported: Bool { ["html", "links", "csv", "safari"].contains(flow.source?.format ?? "") }

    private func stepStatus(_ category: MigrationCategory) -> String {
        switch migration.phase {
        case .reading: return "Reading…"
        case .applying(let current):
            if current == category {
                if category == .passwords, let plan = migration.plan {
                    return "Saving \(migration.completedPasswords) of \(plan.values.passwords.count)…"
                }
                return "Saving…"
            }
            return "Waiting…"
        default: return "Preparing…"
        }
    }

    private func row(_ category: MigrationCategory) -> some View {
        let active = flow.activeStep == category
        let completed = active && migration.receipt?.completed.contains(category) == true
        let spinning = active && (migration.busy || migration.phase == .preview)
        let result = flow.stepResults[category]
        let route: MigrationRoute = category == .passwords || exported ? .export : .automatic
        let ready = category == .passwords || flow.source?.categories.contains(category) == true
        return VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalRowGap)) {
            HStack(spacing: metrics.length(Metrics.arrivalDetailGap)) {
                Image(systemName: category.symbol)
                    .foregroundStyle(Palette.muted)
                    .frame(width: metrics.length(Metrics.infoTarget))
                VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalLine)) {
                    HStack(spacing: metrics.length(Metrics.arrivalLine)) {
                        Text(category.rawValue.capitalized)
                        if let notice = flow.stepNotices[category] {
                            InfoTip(label: "Import details for \(category.rawValue)", explanation: notice)
                        } else if category == .bookmarks, result == nil, !exported, let help = brand.bookmarkHelp {
                            InfoTip(label: "About importing bookmarks", explanation: help)
                        } else if category == .bookmarks, result != nil {
                            InfoTip(label: "About the bookmark count", explanation: "Counts include bookmarks and folders. Already here means these items were imported before and have been kept without creating duplicates.")
                        } else if category == .history {
                            InfoTip(label: "About history import", explanation: "This Space keeps up to 2,000 places. Existing visits are kept; invalid dates and unsupported URLs are skipped.")
                        } else if category == .tabs {
                            InfoTip(label: "About importing tabs", explanation: brand.tabHelp)
                        } else if category == .passwords {
                            InfoTip(label: "Import passwords from a CSV", explanation: brand.passwordHelp)
                        }
                    }
                    .frame(minHeight: metrics.length(Metrics.infoTarget), alignment: .leading)
                    ZStack(alignment: .leading) {
                        if let result {
                            Label(result, systemImage: "checkmark.circle.fill")
                                .font(.system(size: metrics.length(Metrics.arrivalSmall)))
                                .foregroundStyle(Palette.safe)
                        } else if spinning { note(stepStatus(category)) }
                        else if completed { note("Saved") }
                        else { note(ready ? route.rawValue : "Not available in this \(brand.sourceName.lowercased())") }
                    }
                    .contentTransition(.opacity)
                }
                Spacer(minLength: 0)
                ZStack(alignment: .trailing) {
                    if spinning {
                        HStack(spacing: metrics.length(Metrics.arrivalRowGap)) {
                            MigrationSpinner()
                            Button("Stop") { flow.cancel() }.buttonStyle(MigrationButton(kind: .quiet))
                        }
                    } else if !ready {
                        InfoTip(label: "About importing \(category.rawValue)",
                                explanation: "This \(brand.sourceName.lowercased()) has no \(category.rawValue) to import. Choose another \(brand.sourceName.lowercased()) or use an export from Other options.")
                    } else {
                        Button("Import") {
                            if category == .passwords && flow.source?.categories.contains(.passwords) != true { export = category; choosingExport = true }
                            else { flow.startStep(category, in: browser) }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: metrics.length(Metrics.arrivalText), weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, metrics.length(Metrics.arrivalRowGap))
                        .disabled(flow.choosingLocked)
                        .opacity(flow.choosingLocked ? 0.4 : 1)
                        .accessibilityLabel("Import \(category.rawValue)")
                    }
                }
                .frame(width: metrics.length(Metrics.migrationActionWidth), alignment: .trailing)
            }
            .frame(minHeight: metrics.length(Metrics.migrationRowHeight))
            if active, migration.phase == .stopped {
                note(migration.message ?? "Import stopped.")
                if let receipt = migration.receipt, receipt.passwordAdds > 0 {
                    note("\(receipt.passwordAdds) passwords already saved remain in this Space.")
                }
            }
        }
        .padding(.vertical, metrics.length(Metrics.migrationChoiceInset))
        .opacity(ready ? 1 : 0.65)
        .animation(reduceMotion ? nil : Motion.arrival, value: spinning)
        .animation(reduceMotion ? nil : Motion.arrival, value: result)
        .animation(reduceMotion ? nil : Motion.arrival, value: migration.phase == .stopped)
    }

    private func unavailable(_ title: String, symbol: String, reason: String) -> some View {
        HStack(spacing: metrics.length(Metrics.arrivalDetailGap)) {
            Image(systemName: symbol).frame(width: metrics.length(Metrics.infoTarget))
            Text(title)
            Spacer()
            InfoTip(label: "Why \(title) is unavailable", explanation: reason)
        }
        .foregroundStyle(Palette.muted)
        .frame(minHeight: metrics.length(Metrics.migrationChoiceHeight))
        .accessibilityValue("Unavailable")
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: metrics.length(Metrics.arrivalSmall)))
            .foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
    }
}
