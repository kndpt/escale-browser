// The two surfaces of a transfer, drawn like the rest of the import. Bringing a
// file in is what the import's own browser field calls "Escale": choose the
// file, unlock it, read one short summary, press one button. Saving is a short
// section under it in Settings › Import: a passphrase twice, one optional
// switch for passwords, then the save panel. Neither offers a category-by-
// category choice: everything the file holds comes in, and what it leaves out
// is said plainly. Fields are Escale's own, and every state has words, so a
// keyboard or VoiceOver walk reads the same as a pointer's.
import SwiftUI
import UniformTypeIdentifiers

struct TransferImportPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var transfer: TransferFlow
    let showsDone: Bool
    let done: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @State private var choosing = false
    @State private var passphrase = ""

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalGap)) {
            switch transfer.bringing {
            case .idle: idle
            case .locked(let name): locked(name)
            case .opening: busy("Opening the file…", stoppable: false)
            case .summary(let found): review(found)
            case .applying(let text): busy(text, stoppable: true)
            case .finished(let report): finished(report)
            case .failed(let message): failed(message)
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [TransferFlow.type, .data]) { result in
            switch result {
            case .success(let url): transfer.choose(url)
            case .failure(let error): transfer.fail(error.localizedDescription)
            }
        }
        .onChange(of: transfer.bringing) { _, state in
            if case .locked = state {} else { passphrase = "" }
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalRowGap)) {
            note("Choose the file made with Export Escale… on the other Mac. Every Space in it is added as a new Space; nothing you have here is replaced or merged.")
            note("Sign-ins, cookies and passkeys aren't in the file: you'll sign in to sites again.")
            Button { choosing = true } label: { Label("Choose Escale file…", systemImage: "doc") }
                .buttonStyle(MigrationButton(kind: .secondary))
                .keyboardShortcut(.defaultAction)
        }
    }

    private func locked(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalRowGap)) {
            heading(name, "Enter the passphrase it was saved with.")
            PassphraseField(title: "Passphrase", text: $passphrase) { unlock() }
            if let mistake = transfer.mistake { note(mistake).foregroundStyle(Palette.ink) }
            HStack(spacing: metrics.length(Metrics.arrivalRowGap)) {
                Button("Unlock") { unlock() }
                    .buttonStyle(MigrationButton())
                    .keyboardShortcut(.defaultAction)
                    .disabled(passphrase.isEmpty)
                Button("Choose another file") { transfer.forget(); choosing = true }
                    .buttonStyle(MigrationButton(kind: .secondary))
            }
        }
    }

    private func unlock() {
        let typed = passphrase
        passphrase = ""
        transfer.unlock(passphrase: typed, browser: browser)
    }

    private func review(_ summary: TransferSummary) -> some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalGap)) {
            heading("Ready to bring these over.",
                    "Saved \(summary.created.formatted(date: .abbreviated, time: .shortened)) · Escale \(summary.app)")
            VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalDetailGap)) {
                ForEach(Array(summary.lines.enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.name)
                        Text(detail(line)).foregroundStyle(Palette.muted)
                            .font(.system(size: metrics.length(Metrics.arrivalSmall)))
                    }
                    .accessibilityElement(children: .combine)
                }
                if summary.linkRules > 0 { Text("\(summary.linkRules) link rule\(summary.linkRules == 1 ? "" : "s")").foregroundStyle(Palette.muted) }
            }
            .padding(metrics.length(Metrics.arrivalCardInset))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: metrics.length(Metrics.arrivalChoiceRadius), style: .continuous))
            if summary.preferences > 0 {
                Card {
                    Line("Use this file's settings",
                         transfer.pristine ? "Look, layout, search and switches. This Escale is new, so they're taken by default."
                                           : "Look, layout, search and switches. Your current settings are kept unless you switch this on.") {
                        Switch(on: $transfer.takesPreferences)
                    }
                }
            }
            VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalRowGap)) {
                note(summary.includesPasswords ? "Saved passwords come in too, added to each Space; accounts you already have are kept."
                     : "Passwords weren't saved in this file.")
                if summary.skipped > 0 { note("\(summary.skipped) item\(summary.skipped == 1 ? "" : "s") that can't be brought over were left out.") }
                note("Opening this file again later won't make the Spaces twice.")
            }
            HStack(spacing: metrics.length(Metrics.arrivalRowGap)) {
                Button("Import") { transfer.apply(browser: browser) }
                    .buttonStyle(MigrationButton())
                    .keyboardShortcut(.defaultAction)
                Button("Back") { transfer.forget() }
                    .buttonStyle(MigrationButton(kind: .secondary))
            }
        }
    }

    private func detail(_ line: TransferLine) -> String {
        var parts = ["\(line.tabs) tab\(line.tabs == 1 ? "" : "s")", "\(line.bookmarks) bookmark\(line.bookmarks == 1 ? "" : "s")",
                     "\(line.history) page\(line.history == 1 ? "" : "s") of history"]
        if line.passwords > 0 { parts.append("\(line.passwords) password\(line.passwords == 1 ? "" : "s")") }
        if line.extensions > 0 { parts.append("\(line.extensions) extension\(line.extensions == 1 ? "" : "s") to reinstall") }
        return parts.joined(separator: " · ")
    }

    private func busy(_ text: String, stoppable: Bool) -> some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalDetailGap)) {
            HStack(spacing: metrics.length(Metrics.arrivalDetailGap)) {
                MigrationSpinner()
                Text(text).font(.system(size: metrics.length(Metrics.arrivalProgress)))
            }
            if stoppable {
                note("Stop leaves the Spaces already saved in place; open the file again to finish.")
                Button("Stop") { transfer.cancel() }
                    .buttonStyle(MigrationButton(kind: .secondary))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func finished(_ report: TransferReport) -> some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalGap)) {
            heading(report.stopped ? "Import stopped." : report.failed.isEmpty ? "Your import is saved." : "Your import is partly saved.",
                    report.changed ? "The file itself is unchanged." : "There was nothing new to add.")
            VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalDetailGap)) {
                if !report.imported.isEmpty { Label("Added: " + report.imported.joined(separator: ", "), systemImage: "checkmark") }
                if !report.already.isEmpty { Label("Already here: " + report.already.joined(separator: ", "), systemImage: "equal") }
                if !report.failed.isEmpty { Label("Couldn't save: " + report.failed.joined(separator: ", "), systemImage: "exclamationmark.triangle") }
                if report.passwordsAdded + report.passwordsKept + report.passwordsFailed > 0 {
                    note("Passwords: \(report.passwordsAdded) added · \(report.passwordsKept) kept · \(report.passwordsFailed) failed")
                }
                if report.linkRules > 0 { note("\(report.linkRules) link rule\(report.linkRules == 1 ? "" : "s") added.") }
                if report.preferences > 0 { note("Settings from the file applied.") }
                ForEach(report.notes, id: \.self) { note($0) }
                if !report.failed.isEmpty || report.passwordsFailed > 0 || report.stopped {
                    note("Open the file again to finish: what is already here is recognised and left alone.")
                }
            }
            HStack(spacing: metrics.length(Metrics.arrivalRowGap)) {
                if showsDone {
                    Button("Done") { transfer.forget(); done() }
                        .buttonStyle(MigrationButton())
                        .keyboardShortcut(.defaultAction)
                }
                Button("Import another file") { transfer.forget() }
                    .buttonStyle(MigrationButton(kind: .secondary))
            }
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalRowGap)) {
            note(message).foregroundStyle(Palette.ink)
            note("Nothing on this Mac was changed.")
            Button { transfer.forget(); choosing = true } label: { Label("Choose another file…", systemImage: "doc") }
                .buttonStyle(MigrationButton(kind: .secondary))
        }
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalDetailGap)) {
            Text(title).font(.system(size: metrics.length(Metrics.arrivalTitle), weight: .regular))
                .accessibilityAddTraits(.isHeader)
            Text(subtitle).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func note(_ text: String) -> Text {
        Text(text).font(.system(size: metrics.length(Metrics.arrivalSmall))).foregroundStyle(Palette.muted)
    }
}

/// Saving Escale to one file, under the import in Settings.
struct TransferSavePanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var transfer: TransferFlow
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @State private var passphrase = ""
    @State private var again = ""
    @State private var withPasswords = false

    private var ready: Bool { passphrase.count >= 8 && passphrase == again && !transfer.busy }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalRowGap)) {
            Text("Export Escale")
                .font(.system(size: metrics.length(Metrics.arrivalText), weight: .medium))
                .accessibilityAddTraits(.isHeader)
            Text("Saves every Space — bookmarks, tabs, history, settings — in one protected file you can open in Escale on another Mac. It isn't a sync: later changes aren't in it. Sign-ins and passkeys aren't included.")
                .font(.system(size: metrics.length(Metrics.arrivalSmall))).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            PassphraseField(title: "Passphrase", text: $passphrase) {}
            PassphraseField(title: "Repeat it", text: $again) { if ready { save() } }
            Card {
                Line("Include saved passwords", "Stored in the file under the passphrase, and added to each Space on the other Mac.") {
                    Switch(on: $withPasswords)
                }
            }
            Text("A lost passphrase can't be recovered: the file can't be opened without it. At least 8 characters.")
                .font(.system(size: metrics.length(Metrics.arrivalSmall))).foregroundStyle(Palette.muted)
            HStack(spacing: metrics.length(Metrics.arrivalRowGap)) {
                Button("Export Escale…") { save() }
                    .buttonStyle(MigrationButton())
                    .disabled(!ready)
                switch transfer.saving {
                case .working: MigrationSpinner()
                case .saved(let name, let count):
                    Label("Saved \(name) · \(count) Space\(count == 1 ? "" : "s")", systemImage: "checkmark")
                        .font(.system(size: metrics.length(Metrics.arrivalSmall)))
                case .failed(let message):
                    Text(message).font(.system(size: metrics.length(Metrics.arrivalSmall))).foregroundStyle(Palette.ink)
                case .idle: EmptyView()
                }
            }
        }
        .frame(maxWidth: metrics.length(Metrics.arrivalWidth), alignment: .leading)
    }

    private func save() {
        transfer.chooseDestination(passphrase: passphrase, withPasswords: withPasswords, browser: browser) {
            passphrase = ""; again = ""
        }
    }
}

/// A secret field in Escale's own field style.
struct PassphraseField: View {
    let title: String
    @Binding var text: String
    let submit: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        SecureField(title, text: $text)
            .textFieldStyle(.plain)
            .onSubmit(submit)
            .padding(.horizontal, metrics.length(Metrics.arrivalDetailGap))
            .frame(height: metrics.length(Metrics.migrationChoiceHeight))
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: metrics.length(Metrics.arrivalButtonRadius)))
            .overlay(RoundedRectangle(cornerRadius: metrics.length(Metrics.arrivalButtonRadius)).strokeBorder(Palette.hairline))
            .accessibilityLabel(title)
    }
}
