// The connection of the Space on screen, in Settings › GitHub, drawn with the
// arrival's controls so both places read as one feature. Connecting is always
// a person's explicit act: Escale asks GitHub for a code, the person enters it
// on github.com/login/device, and only then may visible rows be refreshed.
// The code polling goes on if Settings closes, so the code can be typed in a
// tab; it ends at Cancel, on success, or when GitHub expires it.
// Disconnecting removes the local secret; revoking stays a GitHub action.
import AppKit
import SwiftUI

struct GitHubSignIn: View {
    @ObservedObject var access: GitHubAccess
    @Binding var mode: GitHubSpecimen.Mode
    /// Opens GitHub's page in a tab of this window.
    let visit: (URL) -> Void
    /// Opens Bearings on its GitHub mode.
    let search: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        switch access.connection {
        case .connecting:
            waiting("Asking GitHub for a code…") { access.cancelConnection() }
        case .disconnecting:
            waiting("Disconnecting…", cancel: nil)
        case .authorizing(let code, _):
            GitHubCode(code: code)
            GitHubButtons {
                Button("Copy Code and Open GitHub") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    if let url = GitHubAccess.verificationURL { visit(url) }
                }
                .buttonStyle(MigrationButton())
                Button("Cancel") { access.cancelConnection() }
                    .buttonStyle(MigrationButton(kind: .secondary))
            }
        case .connected(let account):
            VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalLine)) {
                HStack(spacing: metrics.length(Metrics.arrivalDetailGap)) {
                    Image(systemName: "checkmark")
                        .font(.system(size: metrics.length(Metrics.arrivalText), weight: .medium))
                        .accessibilityHidden(true)
                    Text("Connected as \(account.login)")
                }
                ArrivalNote(text: "Disconnecting forgets the connection on this Mac. Revoking it is done on GitHub.")
            }
            GitHubButtons {
                Button("Search GitHub", action: search)
                    .buttonStyle(MigrationButton())
                Button("Disconnect") { Task { await access.disconnect() } }
                    .buttonStyle(MigrationButton(kind: .secondary))
                if let url = GitHubAccess.revocationURL {
                    Button("Manage on GitHub…") { visit(url) }
                        .buttonStyle(MigrationButton(kind: .quiet))
                }
            }
        case .local, .unavailable:
            if access.canConnect {
                if case .unavailable(let failure) = access.connection {
                    ArrivalNote(text: Self.explain(failure))
                }
                GitHubButtons {
                    Button("Connect GitHub") {
                        mode = .github
                        Task { await access.connect() }
                    }
                    .buttonStyle(MigrationButton())
                    Button("Search GitHub", action: search)
                        .buttonStyle(MigrationButton(kind: .secondary))
                }
            } else {
                ArrivalNote(text: Self.explain(.configuration))
                Button("Search GitHub", action: search)
                    .buttonStyle(MigrationButton())
            }
        }
    }

    private func waiting(_ text: String, cancel: (() -> Void)?) -> some View {
        HStack(spacing: metrics.length(Metrics.arrivalDetailGap)) {
            MigrationSpinner()
            ArrivalNote(text: text)
            Spacer(minLength: 0)
            if let cancel {
                Button("Cancel", action: cancel)
                    .buttonStyle(MigrationButton(kind: .secondary))
            }
        }
    }

    static func explain(_ failure: GitHubFailure) -> String {
        switch failure {
        case .configuration: return "This build of Escale has no GitHub App, so Bearings searches GitHub pages locally."
        case .denied: return "Access was declined on GitHub."
        case .expired: return "The code or the connection expired. Connect again."
        case .rateLimited: return "GitHub asked Escale to wait. Try again in a few minutes."
        case .offline, .unavailable: return "GitHub couldn't be reached."
        case .storage: return "The keychain couldn't keep the connection."
        case .unauthorized, .forbidden: return "GitHub no longer accepts this connection. Connect again."
        case .notFound, .invalidResponse, .cancelled: return "Connecting didn't work. Try again."
        }
    }
}
