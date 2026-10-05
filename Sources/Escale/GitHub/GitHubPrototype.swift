// A design-only, in-window specimen of Bearings' GitHub results and their
// connection states. It is mounted solely in an explicitly opted-in isolated
// test world. The examples never enter history, networking, navigation or the
// future GitHub cache; closing the surface drops all state. It exercises the actual SwiftUI result components at app density.
import SwiftUI

struct GitHubPrototype: View {
    let maxResultsHeight: CGFloat
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduced
    @State private var typed = ""
    @State private var selected = 0
    @State private var notice = ""
    @State private var state = Connection.local
    @State private var updated = false
    @FocusState private var focused: Bool

    private enum Connection: String, CaseIterable, Identifiable {
        case local = "Local", empty = "First use", connecting = "Connecting"
        case cancelled = "Cancelled", refused = "Access refused", connected = "Connected"
        case denied = "Repository access", offline = "Offline", quota = "Rate limit", expired = "Expired", privateTabs = "Private"
        var id: String { rawValue }
        var message: String {
            switch self {
            case .local, .empty: return "From this Space"
            case .connecting: return "Waiting for GitHub…"
            case .cancelled: return "Connection cancelled. Local results are still available."
            case .refused: return "GitHub access was not granted."
            case .connected: return "Connected as octo-developer"
            case .denied: return "No access to this repository."
            case .offline: return "Offline. Showing saved information."
            case .quota: return "GitHub limit reached. Try again later."
            case .expired: return "Connect GitHub again to update states."
            case .privateTabs: return "From private tabs"
            }
        }
        var action: String? {
            switch self {
            case .connecting: return "Cancel"
            case .connected: return "Refresh"
            case .refused: return "Try again"
            case .denied: return "Manage access"
            case .offline: return "Retry"
            case .expired: return "Reconnect"
            case .quota, .privateTabs: return nil
            default: return "Connect GitHub"
            }
        }
    }

    // Opaque demo indices are not GitHub identities or a second domain model.
    private let examples: [(title: String, repo: String, number: String, symbol: GitHubSymbol)] = [
        ("Keep the search selection while states update", "octo-team/browser", "#248", .pullOpen),
        ("Restore the page without losing the draft", "octo-team/browser", "#231", .pullMerged),
        ("Investigate a stale tab title", "octo-team/desktop", "#92", .issueOpen),
        ("A quieter transition between projects", "octo-team/browser", "#256", .pullDraft),
        ("Replace the legacy navigation route", "octo-team/desktop", "#88", .pullClosed),
        ("A visited issue with no observed state", "octo-team/tools", "#17", .issueUnknown),
    ]

    private var rows: [Int] {
        guard state != .empty else { return [] }
        let terms = Terms(typed)
        return examples.indices.filter {
            terms.isEmpty || terms.match([examples[$0].title, examples[$0].repo, examples[$0].number]) != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: metrics.length(Metrics.searchInset)) {
                Text("Bearings").foregroundStyle(Palette.muted)
                GitHubMark()
                Spacer(minLength: 0)
                Text("Design preview").foregroundStyle(Palette.muted)
            }
            .font(.system(size: metrics.length(Metrics.searchDetail), weight: .medium))
            .padding(.horizontal, metrics.length(Metrics.searchInset))
            .frame(height: metrics.length(Metrics.searchRowHeight))

            HStack(spacing: metrics.length(Metrics.searchInset)) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField("", text: $typed, prompt: Text("Repository, number or title").foregroundColor(Palette.muted))
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.ink)
                    .focused($focused)
                    .accessibilityLabel("Bearings GitHub design preview")
                    .onSubmit { choose() }
                    .onKeyPress(.downArrow) { walk(1); return .handled }
                    .onKeyPress(.upArrow) { walk(-1); return .handled }
            }
            .font(.system(size: metrics.length(Metrics.searchFont)))
            .padding(.horizontal, metrics.length(Metrics.searchInset))
            .frame(height: metrics.length(Metrics.searchFieldHeight))
            Divider().overlay(Palette.hairline)

            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 0) {
                        if rows.isEmpty {
                            Text(state == .empty && typed.isEmpty
                                 ? "Your visited pull requests and issues appear here."
                                 : "No matching pull requests or issues in this Space.")
                                .font(.system(size: metrics.length(Metrics.searchFont)))
                                .foregroundStyle(Palette.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(metrics.length(Metrics.searchInset))
                        }
                        ForEach(rows, id: \.self) { index in
                            let example = examples[index]
                            GitHubResult(title: example.title, repository: example.repo, number: example.number,
                                         symbol: index == 0 && updated ? .pullMerged : example.symbol,
                                         old: index == 1, age: index == 1 ? "2d ago" : "",
                                         observation: index == 1
                                            ? "Older information. Merged pull request, observed on the page on 30 September 2026 at 09:41."
                                            : "Example observation for design review.",
                                         open: index == 0, selected: selected == index) { selected = index; choose() }
                                .id(index)
                        }
                    }
                    .padding(metrics.length(Metrics.searchGap))
                }
                .frame(height: min(maxResultsHeight, CGFloat(max(1, rows.count)) * metrics.length(Metrics.githubRowHeight)
                                       + metrics.length(Metrics.searchGap * 2)))
                .onChange(of: selected) { _, value in scroll.scrollTo(value) }
            }

            Divider().overlay(Palette.hairline)
            HStack(spacing: metrics.length(Metrics.searchInset)) {
                Text(state.message).frame(maxWidth: .infinity, alignment: .leading)
                if let action = state.action {
                    Button(action) {
                        if state == .connecting { state = .cancelled }
                        else if state == .connected { updated.toggle() }
                        else if state == .denied { notice = "Preview: open GitHub access settings" }
                        else if state == .offline { state = .connected }
                        else { state = .connecting }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.ink)
                }
            }
            .foregroundStyle(Palette.muted)
            .font(.system(size: metrics.length(Metrics.searchDetail)))
            .padding(metrics.length(Metrics.searchInset))

            HStack {
                Menu("Example data · \(state.rawValue)") {
                    ForEach(Connection.allCases) { choice in
                        Button(choice.rawValue) { state = choice }
                    }
                }
                .menuStyle(.borderlessButton)
                .lineLimit(1)
                Spacer()
                Button("Simulate state reply") { updated.toggle() }
                    .buttonStyle(.plain)
                    .lineLimit(1)
            }
            .font(.system(size: metrics.length(Metrics.searchDetail)))
            .foregroundStyle(Palette.muted)
            .padding(metrics.length(Metrics.searchInset))
            if !notice.isEmpty {
                Text(notice)
                    .font(.system(size: metrics.length(Metrics.searchDetail)))
                    .foregroundStyle(Palette.muted)
                    .padding(metrics.length(Metrics.searchGap))
            }
        }
        .onAppear { focused = true }
        .onChange(of: typed) { _, _ in selected = rows.first ?? 0; notice = "" }
        .onChange(of: state) { _, _ in if !rows.contains(selected) { selected = rows.first ?? 0 } }
        .animation(reduced ? nil : Motion.githubMode, value: state)
    }

    private func walk(_ step: Int) {
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex(of: selected) ?? 0
        selected = rows[(current + step + rows.count) % rows.count]
    }

    private func choose() {
        guard let target = rows.contains(selected) ? selected : rows.first else { return }
        notice = "Preview: \(target == 0 ? "switch to tab" : "open") \(examples[target].repo) \(examples[target].number)"
    }
}
