// Suggestions inspect registered app identities once when the empty chooser
// appears. Only supported automatic routes qualify; no profile, history or
// password is read until the user selects a browser. Icons come from the local
// application bundle, with no downloads or background polling.
import SwiftUI
import AppKit

struct MigrationSuggestions: View {
    let select: (MigrationBrowser) -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var installed: [Suggestion] = []

    private struct Suggestion: Identifiable {
        let browser: MigrationBrowser
        let icon: NSImage
        var id: MigrationBrowser { browser }
    }

    var body: some View {
        // A concrete container must exist before results arrive: attaching
        // task to an empty Group gives SwiftUI no rendered child to start it.
        VStack(alignment: .leading, spacing: 0) {
            if !installed.isEmpty {
                VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalDetailGap)) {
                    Text("Detected on this Mac")
                        .font(.system(size: metrics.length(Metrics.arrivalSmall)))
                        .foregroundStyle(Palette.muted)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.length(Metrics.migrationSuggestionWidth)),
                                                 spacing: metrics.length(Metrics.arrivalRowGap))],
                              alignment: .leading, spacing: metrics.length(Metrics.arrivalRowGap)) {
                        ForEach(installed) { suggestion in
                            Button { select(suggestion.browser) } label: {
                                HStack(spacing: metrics.length(Metrics.arrivalDetailGap)) {
                                    Image(nsImage: suggestion.icon)
                                        .resizable().scaledToFit()
                                        .frame(width: metrics.length(Metrics.migrationSuggestionIcon),
                                               height: metrics.length(Metrics.migrationSuggestionIcon))
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalLine)) {
                                        Text(suggestion.browser.rawValue)
                                        Text("Automatic")
                                            .font(.system(size: metrics.length(Metrics.arrivalSmall)))
                                            .foregroundStyle(Palette.muted)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: metrics.length(Metrics.arrivalSmall)))
                                        .foregroundStyle(Palette.muted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(MigrationButton(kind: .secondary))
                            .accessibilityLabel("Choose \(suggestion.browser.rawValue), automatic import")
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Motion.arrival, value: installed.map(\.id))
        .task {
            installed = MigrationBrowser.allCases.compactMap { browser in
                guard browser.route == .automatic, let app = browser.applicationIDs.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first else { return nil }
                return Suggestion(browser: browser, icon: NSWorkspace.shared.icon(forFile: app.path))
            }
        }
    }
}
