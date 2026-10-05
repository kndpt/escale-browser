// The list observes search membership separately from status observations.
// Neither a late reading nor a failure asks the search to rank again, and the
// same stable identity drives the pointer, selection highlight and Return.
// When GitHub refuses a row to a connected Space, as it does for a private
// repository not shared with the app, the foot of the list leads to sharing it.
import SwiftUI

struct GitHubResults: View {
    let browser: Browser
    @ObservedObject var search: GitHubSearch
    let maxHeight: CGFloat
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if search.results.isEmpty {
                Text(browser.field.typed.isEmpty
                     ? (search.shy ? "Open a pull request or issue in a private tab to find it here." : "Visit a pull request or issue to find it here.")
                     : "No local pull requests or issues match this search.")
                    .font(.system(size: metrics.length(Metrics.searchFont)))
                    .foregroundStyle(Palette.muted)
                    .padding(metrics.length(Metrics.searchInset))
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(search.results) { result in
                                if let memory = search.memory {
                                    ObservedResult(memory: memory, result: result, selected: search.picked == result.id) {
                                        browser.takeGitHub(result.id)
                                    }
                                } else {
                                    row(result, reading: GitHubReading(observation: nil, failure: nil), selected: search.picked == result.id) {
                                        browser.takeGitHub(result.id)
                                    }
                                }
                            }
                        }
                        .padding([.horizontal, .top], metrics.length(Metrics.searchGap))
                    }
                    .frame(height: min(maxHeight, metrics.length(CGFloat(search.results.count) * Metrics.githubRowHeight + Metrics.searchGap)))
                    .onChange(of: search.picked) { _, id in if let id { scroll.scrollTo(id) } }
                }
            }
            HStack(spacing: metrics.length(Metrics.searchGap)) {
                if let owner = search.shy ? nil : browser.github.made(search.space), owner.memory === search.memory,
                   let install = owner.access.installURL {
                    Refusals(memory: owner.memory, access: owner.access, rows: search.results.map(\.id)) {
                        owner.shares.sharing()
                        browser.shareGitHub(install)
                    }
                } else {
                    Text(search.shy ? "Private tabs only · Local search" : "This Space · Local search")
                }
            }
            .font(.system(size: metrics.length(Metrics.searchDetail)))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, metrics.length(Metrics.searchInset))
            // The gap stays outside the scroll view, so a clipped list
            // never runs into this line.
            .padding(.vertical, metrics.length(Metrics.searchGap))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The usual foot, or a way to share what GitHub refused to this connection.
    private struct Refusals: View {
        @ObservedObject var memory: GitHubMemory
        @ObservedObject var access: GitHubAccess
        let rows: [GitHubItem.ID]
        let share: () -> Void

        var body: some View {
            if case .connected = access.connection, rows.contains(where: { memory.reading($0).failure?.refused == true }) {
                Text("Some private repositories aren’t shared with Escale.")
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Add Repositories…", action: share)
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.ink)
                    .underline()
            } else {
                Text("This Space · Local search")
            }
        }
    }

    private struct ObservedResult: View {
        @ObservedObject var memory: GitHubMemory
        let result: GitHubSearch.Result
        let selected: Bool
        let take: () -> Void
        var body: some View { row(result, reading: memory.reading(result.id), selected: selected, take: take) }
    }

    private static func row(_ result: GitHubSearch.Result, reading: GitHubReading, selected: Bool,
                            take: @escaping () -> Void) -> some View {
        let observation = reading.observation
        let current = reading.current(at: Date())
        let symbol = GitHubSymbol(kind: result.id.kind, state: current ?? observation?.state ?? .unknown)
        var detail: String
        if let observation {
            let source: String
            switch observation.source { case .page: source = "Visited page"; case .api: source = "GitHub" }
            detail = "\(source) · \(observation.state.rawValue) · \(observation.observedAt.formatted(date: .abbreviated, time: .shortened))"
                + (current == nil ? " · Needs refresh" : "")
        } else { detail = "State not observed" }
        if let failure = reading.failure {
            detail += " · " + (failure.refused ? "Not shared with Escale" : failure == .rateLimited ? "GitHub asked Escale to wait" : "Couldn’t refresh")
        }
        let age = observation.map { When.said($0.observedAt) } ?? ""
        return GitHubResult(title: result.item.destination.title.isEmpty ? "#\(result.id.number)" : result.item.destination.title,
                            repository: result.repository, number: "#\(result.id.number)",
                            symbol: symbol, old: observation != nil && current == nil, age: current == nil ? age : "",
                            observation: detail, open: result.isOpen, selected: selected, take: take)
            .id(result.id)
    }

    private func row(_ result: GitHubSearch.Result, reading: GitHubReading, selected: Bool,
                     take: @escaping () -> Void) -> some View {
        Self.row(result, reading: reading, selected: selected, take: take)
    }
}

extension GitHubSymbol {
    init(kind: GitHubItem.ID.Kind, state: GitHubState) {
        switch (kind, state) {
        case (.pull, .open): self = .pullOpen
        case (.pull, .draft): self = .pullDraft
        case (.pull, .merged): self = .pullMerged
        case (.pull, .closed): self = .pullClosed
        case (.issue, .open): self = .issueOpen
        case (.issue, .closed): self = .issueClosed
        case (.issue, _): self = .issueUnknown
        default: self = .pullUnknown
        }
    }
}
