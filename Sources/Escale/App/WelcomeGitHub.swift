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
    /// The Search GitHub shortcut as bound now, so a rebinding shows here too.
    let stroke: KeyStroke?
    /// Steps aside for the address in a tab when there is one, or moves on.
    let next: (URL?) -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mode = GitHubSpecimen.Mode.github

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalGap)) {
            GitHubSpecimen(access: access, mode: $mode, stroke: stroke)
            // The old controls leave at once and the new ones fade in, so two
            // sets of buttons never overlap while the column changes height.
            VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalGap)) { actions }
                .id(access.connection.stage)
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
                .padding(.top, metrics.length(Metrics.arrivalRowGap))
        }
        .animation(reduceMotion ? nil : Motion.arrival, value: access.connection)
    }

    @ViewBuilder private var actions: some View {
        switch access.connection {
        case .connecting, .disconnecting:
            HStack(spacing: metrics.length(Metrics.arrivalDetailGap)) {
                MigrationSpinner()
                ArrivalNote(text: "Asking GitHub for a code…")
                Spacer(minLength: 0)
                Button("Cancel") { access.cancelConnection() }
                    .buttonStyle(MigrationButton(kind: .secondary))
            }
        case .authorizing(let code, _):
            GitHubCode(code: code, note: "GitHub opens in a tab, where you paste the code. Setup comes back here once you approve.")
            GitHubButtons {
                Button("Copy Code and Open GitHub") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    next(GitHubAccess.verificationURL)
                }
                .buttonStyle(MigrationButton())
                .keyboardShortcut(.defaultAction)
                Button("Cancel") { access.cancelConnection() }
                    .buttonStyle(MigrationButton(kind: .secondary))
            }
        case .connected(let account):
            HStack(spacing: metrics.length(Metrics.arrivalDetailGap)) {
                Image(systemName: "checkmark")
                    .font(.system(size: metrics.length(Metrics.arrivalText), weight: .medium))
                    .accessibilityHidden(true)
                Text("Connected as \(account.login)")
            }
            Button("Continue") { next(nil) }
                .buttonStyle(MigrationButton())
                .keyboardShortcut(.defaultAction)
        case .local, .unavailable:
            if access.canConnect {
                if case .unavailable(let failure) = access.connection {
                    ArrivalNote(text: GitHubSignIn.explain(failure))
                }
                GitHubButtons {
                    Button("Connect GitHub") {
                        mode = .github
                        Task { await access.connect() }
                    }
                    .buttonStyle(MigrationButton())
                    .keyboardShortcut(.defaultAction)
                    Button("Stay local") { next(nil) }
                        .buttonStyle(MigrationButton(kind: .secondary))
                        .accessibilityHint("Continue without GitHub. Bearings still searches what you visit.")
                }
            } else {
                ArrivalNote(text: GitHubSignIn.explain(.configuration))
                Button("Continue") { next(nil) }
                    .buttonStyle(MigrationButton())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
