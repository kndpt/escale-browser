// The last arrival step offers GitHub without making it a gate. Bearings
// GitHub works with no account, so the step first shows what both ways give
// (GitHubSpecimen.swift, the same view as Settings › GitHub). Connecting is one
// explicit act; the skip beside it is just as visible and never asks again.
//
// The device code is shown here, but it is typed on github.com in a tab, so
// "Copy code and open GitHub" ends the arrival and opens that tab. The code's
// note says so first, and where the connection shows once approved, since the
// panel that would have confirmed it is gone. The Space's GitHubAccess keeps polling after
// the panel closes, as it does for Settings.
import AppKit
import SwiftUI

struct WelcomeGitHub: View {
    @ObservedObject var access: GitHubAccess
    /// The Search GitHub shortcut as bound now, so a rebinding shows here too.
    let stroke: KeyStroke?
    /// Ends the arrival, then opens the address in a tab when there is one.
    let finish: (URL?) -> Void
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
            GitHubCode(code: code, note: "Setup ends here: GitHub opens in a tab, where you paste the code. Once you approve, Settings → GitHub shows you’re connected.")
            GitHubButtons {
                Button("Copy Code and Open GitHub") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    finish(GitHubAccess.verificationURL)
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
            Button("Start browsing") { finish(nil) }
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
                    Button("Stay local") { finish(nil) }
                        .buttonStyle(MigrationButton(kind: .secondary))
                        .accessibilityHint("Start browsing without GitHub. Bearings still searches what you visit.")
                }
            } else {
                ArrivalNote(text: GitHubSignIn.explain(.configuration))
                Button("Start browsing") { finish(nil) }
                    .buttonStyle(MigrationButton())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
