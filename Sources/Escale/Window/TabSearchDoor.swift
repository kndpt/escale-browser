// A visible entrance to the existing tab switcher, beside the Space title,
// at the column's top without Spaces, or by tab creation in the top strip.
// It sends the Tabs menu's action;
// search scope, ordering and focus remain owned by Browser and Field.
import SwiftUI

struct TabSearchDoor: View {
    @ObservedObject var prefs: Preferences
    let action: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: metrics.length(Metrics.navigationSymbol), weight: .medium))
                .frame(width: metrics.length(Metrics.tabSearchSide), height: metrics.length(Metrics.tabSearchSide))
                .contentShape(RoundedRectangle(cornerRadius: metrics.cardRadius - metrics.length(2)))
        }
        .buttonStyle(SearchStyle(hovering: hovering, focused: focused))
        .focused($focused)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .help(prefs.keyHelp(.searchTabs))
        .accessibilityLabel("Search Tabs")
        .accessibilityIdentifier("search-tabs")
    }

    private struct SearchStyle: ButtonStyle {
        let hovering: Bool
        let focused: Bool
        @SwiftUI.Environment(\.chromeMetrics) private var metrics

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(hovering || focused || configuration.isPressed ? Palette.ink : Palette.muted)
                .background(RoundedRectangle(cornerRadius: metrics.cardRadius - metrics.length(2))
                    .fill(configuration.isPressed ? Palette.wash : hovering ? Palette.hover : .clear))
                .overlay(RoundedRectangle(cornerRadius: metrics.cardRadius - metrics.length(2))
                    .strokeBorder(focused ? Palette.ink : .clear, lineWidth: metrics.length(1)))
        }
    }
}
