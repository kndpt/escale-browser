// A GitHub result renders supplied text and one action. It owns no identity,
// sorting or observation cache: the search owner resolves a stable object and
// its destination. Fixed status/action columns keep late observations from
// moving the title or changing the keyboard selection; a long localized age
// only shortens the title's truncation width.
import SwiftUI

struct GitHubResult: View {
    let title: String
    let repository: String
    let number: String
    let symbol: GitHubSymbol
    let old: Bool
    let age: String
    let observation: String
    let open: Bool
    let selected: Bool
    let take: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @State private var hovering = false

    var body: some View {
        Button(action: take) {
            content
        }
        .buttonStyle(.plain)
        .background {
            if selected { Chosen(radius: metrics.length(Metrics.searchRowRadius)) }
            else if hovering {
                RoundedRectangle(cornerRadius: metrics.length(Metrics.searchRowRadius)).fill(Palette.hover)
            }
        }
        .onHover { hovering = $0 }
        .help([title, observation].filter { !$0.isEmpty }.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { take() }
        .accessibilityLabel([title, repository, number, symbol.label, observation].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityHint(open ? "Switch to tab" : "Open")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var content: some View {
        HStack(spacing: metrics.length(Metrics.searchInset)) {
            GitHubStateMark(symbol: symbol, old: old)
                .help(observation.isEmpty ? symbol.label : observation)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: metrics.length(Metrics.githubLineGap)) {
                HStack(spacing: metrics.length(Metrics.searchGap)) {
                    Text(title)
                        .font(.system(size: metrics.length(Metrics.searchFont)))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(age)
                        .font(.system(size: metrics.length(Metrics.searchDetail)))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        // Localized ages vary in length ("vor 1 Monat"); the title truncates instead.
                        .fixedSize()
                        .frame(minWidth: metrics.length(Metrics.githubAgeWidth), alignment: .trailing)
                        .help(observation)
                }
                HStack(spacing: metrics.length(Metrics.searchGap)) {
                    Text(repository).truncationMode(.middle)
                    Text(number).fixedSize()
                    Spacer(minLength: 0)
                    HStack(spacing: metrics.length(Metrics.githubLineGap)) {
                        Image(systemName: "return")
                        Text(open ? "Switch to tab" : "Open")
                    }
                    .opacity(selected ? 1 : 0)
                    .frame(width: metrics.length(Metrics.githubActionWidth), alignment: .trailing)
                    .accessibilityHidden(true)
                }
                .font(.system(size: metrics.length(Metrics.searchDetail)))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, metrics.length(Metrics.searchInset))
        .frame(height: metrics.length(Metrics.githubRowHeight))
        .contentShape(Rectangle())
    }
}
