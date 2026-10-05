// New Tab reads the Space's existing bookmark destinations, never a second
// environment catalogue. A single traversal keeps up to `limit` matches in
// each tier, environments before ordinary bookmarks and, within each, the
// closer match first (`Terms`), then returns `limit` saved results. This
// lets a later bookmark outrank early weaker matches without retaining the
// whole catalogue. Bookmarks in `keeping` (Habits.swift) follow when they
// match but do not make it, so Field weighs what was learned before it cuts.
// The field owns the transient choice; no page is built.
import SwiftUI

enum SearchEnvironments {
    static func matches(_ roots: [Bookmark], query: String, limit: Int,
                        keeping: Set<UUID> = []) -> [Suggestion] {
        let terms = Terms(query)
        guard !terms.isEmpty else { return [] }
        // Environments by closeness (`Terms.Match`), then ordinary bookmarks.
        let closeness = Terms.Match.allCases.count
        var tiers: [[Suggestion]] = Array(repeating: [], count: 2 * closeness)
        var kept: [Suggestion] = []
        /// Learned bookmarks not met yet: once none is, the early exit holds again.
        var outstanding = keeping
        /// Whether a match in `tier` could still reach the returned few.
        func wanted(_ tier: Int) -> Bool { tiers[...tier].reduce(0) { $0 + $1.count } < limit }
        func visit(_ nodes: [Bookmark]) {
            for node in nodes {
                guard tiers[0].count < limit || !outstanding.isEmpty else { return }
                if node.isFolder { visit(node.children ?? []); continue }
                outstanding.remove(node.id)
                let base = node.destinations.isEmpty ? closeness : 0
                // Its best possible tier decides whether matching is worth it.
                guard wanted(base) || keeping.contains(node.id), let text = node.url, let url = URL(string: text),
                      let match = terms.match([node.title, text] + node.destinations.flatMap { [$0.name, $0.url] })
                else { continue }
                let tier = base + match.rawValue
                let offer = Suggestion(key: node.title, title: Address.pretty(url), url: url, kind: .bookmark,
                                       bookmark: node.id, environments: node.destinations, match: match)
                if wanted(tier) { tiers[tier].append(offer) }
                else if keeping.contains(node.id) { kept.append(offer) }
            }
        }
        visit(roots)
        let found = Array(tiers.joined())
        return Array(found.prefix(limit)) + found.dropFirst(limit).filter { $0.bookmark.map(keeping.contains) == true } + kept
    }
}

extension Browser {
    /// Resolve again at activation, so stale results cannot recreate removed
    /// data. True when the bookmark was gone to.
    @discardableResult
    func takeSearchBookmark(_ id: UUID, environment: BookmarkEnvironment?) -> Bool {
        guard let node = bookmarks.find(id) else { field.refresh(); return false }
        let url: URL?
        if let environment {
            guard node.destinations.contains(environment) else { field.refresh(); return false }
            url = BookmarkEnvironment.address(environment.url)
        } else {
            url = node.url.flatMap(URL.init(string:))
        }
        guard let url else { return false }
        if let existing = tabs.first(where: {
            $0.shy == searchIsPrivate && !$0.bench
                && $0.address.map { BookmarkEnvironment.key($0) == BookmarkEnvironment.key(url) } == true
        }) {
            select(existing)
        } else if searchIsPrivate {
            // A private New Tab must never reuse the ordinary bookmark's page.
            navigateFromField(url)
        } else if let environment {
            openEnvironment(environment, bookmark: id, space: spaceID, shy: false)
        } else if let linked = tabs.first(where: { shelfTabs[$0.id] == id && $0.pin == nil && !$0.shy }) {
            linked.go(to: url)
            select(linked)
        } else {
            if let tab = navigateFromField(url) {
                shelfTabs = shelfTabs.filter { $0.value != id }
                shelfTabs[tab.id] = id
            }
        }
        field.stopSummoning()
        editing = false
        field.typed = ""
        return true
    }
}

/// Destinations expand inside their result; the focused chip, not a second panel, takes the ring.
struct SearchEnvironmentChoices: View {
    @ObservedObject var input: Field
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        if let offer = input.selected, offer.environments.count > 1 {
            VStack(alignment: .leading, spacing: metrics.length(Metrics.searchGap)) {
                HStack(spacing: metrics.length(Metrics.searchGap)) {
                    ScrollViewReader { scroll in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: metrics.length(Metrics.searchGap)) {
                                ForEach(Array(offer.environments.enumerated()), id: \.element.id) { index, item in
                                    Button {
                                        _ = input.focusEnvironments()
                                        if let current = input.environmentIndex { input.moveEnvironment(index - current) }
                                    } label: {
                                        HStack(spacing: metrics.length(Metrics.searchGap)) {
                                            if input.environmentIndex == index { Image(systemName: "checkmark") }
                                            Text(item.name).lineLimit(1)
                                        }
                                        .font(.system(size: metrics.length(Metrics.searchDetail), weight: .medium))
                                        .foregroundStyle(item.colour.map(Palette.swatchInk) ?? Palette.ink)
                                        .padding(metrics.length(Metrics.searchGap))
                                        .background(input.environmentIndex == index ? Palette.wash : Palette.hover,
                                                    in: RoundedRectangle(cornerRadius: metrics.length(Metrics.searchRowRadius)))
                                        .overlay {
                                            if input.environmentFocused, input.environmentIndex == index {
                                                RoundedRectangle(cornerRadius: metrics.length(Metrics.searchRowRadius))
                                                    .strokeBorder(Palette.ink, lineWidth: 1)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .help(item.url)
                                    .accessibilityLabel("\(item.name), \(item.url)")
                                    .accessibilityAddTraits(input.environmentIndex == index ? .isSelected : [])
                                    .id(index)
                                }
                            }
                        }
                        .onChange(of: input.environmentIndex) { _, index in
                            if let index { scroll.scrollTo(index, anchor: .center) }
                        }
                    }
                    // The arrows step from one chip to the next; said here, where they act.
                    Text("← →")
                        .font(.system(size: metrics.length(Metrics.searchDetail)))
                        .foregroundStyle(Palette.muted)
                        .accessibilityHidden(true)
                }
                Text(input.selectedEnvironment?.url ?? offer.url.absoluteString)
                    .font(.system(size: metrics.length(Metrics.searchDetail)))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.leading, metrics.length(Metrics.searchInset * 2 + Metrics.searchIcon))
            .padding(.trailing, metrics.length(Metrics.searchInset))
            .padding(.bottom, metrics.length(Metrics.searchGap))
            .accessibilityLabel("Environments for \(offer.key)")
            .accessibilityHint("Press the left and right arrow keys to move between environments")
        }
    }
}
