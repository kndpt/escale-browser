// Settings › GitHub is the arrival's GitHub step kept within reach: the same
// heading, specimen and switch (GitHubSpecimen.swift), so a person who skipped
// it finds the same offer again, and a connected Space finds its account. Only
// the actions differ (GitHubSignIn.swift): Settings stays open and can open
// Bearings, where the arrival ends itself. A connected Space also lists who
// has shared private repositories with Escale, and leads to GitHub's page to
// share more (GitHubShares.swift).
import SwiftUI

struct GitHubSettings: View {
    /// The connection of the Space on screen (GitHubSignIn.swift).
    @ObservedObject var access: GitHubAccess
    let shares: GitHubShares
    /// The Search GitHub shortcut as bound now.
    let stroke: KeyStroke?
    let visit: (URL) -> Void
    let open: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mode = GitHubSpecimen.Mode.github

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalGap)) {
            VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalDetailGap)) {
                Text("Your pull requests, one keystroke away.")
                    .font(.system(size: metrics.length(Metrics.arrivalTitle), weight: .regular))
                    .accessibilityAddTraits(.isHeader)
                Text("Bearings finds the pull requests and issues you visit, by a few words or a number, and takes you back to their tab.")
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GitHubSpecimen(access: access, mode: $mode, stroke: stroke)
            // The old controls leave at once and the new ones fade in, so two
            // sets of buttons never overlap while the column changes height.
            VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalGap)) {
                GitHubSignIn(access: access, mode: $mode, visit: visit, search: open)
                if case .connected = access.connection {
                    GitHubSharing(shares: shares, install: access.installURL, visit: visit)
                }
            }
            .id(access.connection.stage)
            .transition(.asymmetric(insertion: .opacity, removal: .identity))
            .padding(.top, metrics.length(Metrics.arrivalRowGap))
        }
        .animation(reduceMotion ? nil : Motion.arrival, value: access.connection)
        .font(.system(size: metrics.length(Metrics.arrivalText)))
        .foregroundStyle(Palette.ink)
        .frame(maxWidth: metrics.length(Metrics.arrivalWidth), alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Private repositories answer only once shared with the app on GitHub, by
/// the person or an organization; this says so and leads there.
private struct GitHubSharing: View {
    @ObservedObject var shares: GitHubShares
    let install: URL?
    let visit: (URL) -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalLine)) {
            Text("Private repositories")
                .fontWeight(.medium)
                .accessibilityAddTraits(.isHeader)
            ArrivalNote(text: "Public repositories need nothing more. Share private ones with Escale on GitHub, from your account or an organization.")
            ForEach(shares.shares ?? []) { share in
                HStack(spacing: metrics.length(Metrics.arrivalDetailGap)) {
                    Text(share.account)
                    Text(share.all ? "All repositories" : "Selected repositories")
                        .foregroundStyle(Palette.muted)
                    Spacer(minLength: 0)
                    if let page = share.page {
                        Button("Change…") { shares.sharing(); visit(page) }
                            .buttonStyle(MigrationButton(kind: .quiet))
                            .accessibilityLabel("Change the repositories \(share.account) shares")
                    }
                }
            }
            if let install {
                Button("Add Private Repositories…") { shares.sharing(); visit(install) }
                    .buttonStyle(MigrationButton(kind: .secondary))
                    .padding(.top, metrics.length(Metrics.arrivalLine))
            }
        }
        .onAppear { shares.load() }
    }
}
