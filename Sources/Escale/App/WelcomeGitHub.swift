// The last arrival step offers GitHub without making it a gate. Bearings
// GitHub works with no account, so the step first shows what both ways give
// (GitHubSpecimen.swift, the same view as Settings › GitHub). Connecting is one
// explicit act; the skip beside it is just as visible and never asks again.
//
// The device code is shown here, but it is typed on github.com in a tab, so
// "Copy code and open GitHub" steps aside for that tab and comes back once
// GitHub answers (WelcomeReturn.swift). Every way out of this step leads to
// the last one, which says what is set up.
import AppKit
import SwiftUI

struct WelcomeGitHub: View {
    @ObservedObject var access: GitHubAccess
    @Binding var mode: GitHubSpecimen.Mode
    /// The Search GitHub shortcut as bound now, so a rebinding shows here too.
    let stroke: KeyStroke?
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalGap)) {
            GitHubSpecimen(access: access, mode: $mode, stroke: stroke)
            // The old state leaves at once and the new one fades in, so two
            // never overlap while the column changes height.
            VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalGap)) { state }
                .id(access.connection.stage)
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
        }
        .animation(reduceMotion ? nil : Motion.arrival, value: access.connection)
    }

    /// Where the connection stands; its buttons are in Welcome's bottom row
    /// (WelcomeGitHubActions).
    @ViewBuilder private var state: some View {
        switch access.connection {
        case .connecting, .disconnecting:
            HStack(spacing: metrics.length(Metrics.arrivalDetailGap)) {
                MigrationSpinner()
                ArrivalNote(text: "Asking GitHub for a code…")
            }
        case .authorizing(let code, _):
            GitHubCode(code: code, note: "GitHub opens in a tab, where you paste the code. Setup comes back here once you approve.")
        case .connected(let account):
            HStack(spacing: metrics.length(Metrics.arrivalDetailGap)) {
                Image(systemName: "checkmark")
                    .font(.system(size: metrics.length(Metrics.arrivalText), weight: .medium))
                    .accessibilityHidden(true)
                Text("Connected as \(account.login)")
            }
        case .unavailable(let failure) where access.canConnect:
            ArrivalNote(text: GitHubSignIn.explain(failure))
        case .local, .unavailable:
            if !access.canConnect { ArrivalNote(text: GitHubSignIn.explain(.configuration)) }
        }
    }
}

/// The GitHub step's buttons, the one that moves on last.
struct WelcomeGitHubActions: View {
    @ObservedObject var access: GitHubAccess
    @Binding var mode: GitHubSpecimen.Mode
    /// Steps aside for the address in a tab when there is one, or moves on.
    let next: (URL?) -> Void

    var body: some View {
        switch access.connection {
        case .connecting, .disconnecting:
            // Connect stays where it was, unpressable, so the second click
            // of a double click on it does not land on Cancel.
            Button("Cancel") { access.cancelConnection() }
                .buttonStyle(MigrationButton(kind: .secondary))
            Button("Connect GitHub") {}
                .buttonStyle(MigrationButton())
                .disabled(true)
        case .authorizing(let code, _):
            Button("Cancel") { access.cancelConnection() }
                .buttonStyle(MigrationButton(kind: .secondary))
            Button("Copy Code and Open GitHub") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                next(GitHubAccess.verificationURL)
            }
            .buttonStyle(MigrationButton())
            .keyboardShortcut(.defaultAction)
        case .connected:
            continueButton
        case .local, .unavailable:
            if access.canConnect {
                Button("Stay local") { next(nil) }
                    .buttonStyle(MigrationButton(kind: .secondary))
                    .accessibilityHint("Continue without GitHub. Bearings still searches what you visit.")
                Button("Connect GitHub") {
                    mode = .github
                    Task { await access.connect() }
                }
                .buttonStyle(MigrationButton())
                .keyboardShortcut(.defaultAction)
            } else {
                continueButton
            }
        }
    }

    private var continueButton: some View {
        Button("Continue") { next(nil) }
            .buttonStyle(MigrationButton())
            .keyboardShortcut(.defaultAction)
    }
}
