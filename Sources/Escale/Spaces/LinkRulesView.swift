// Link Routing has a page of its own in Settings, under Features, so the rules
// are found by name rather than at the foot of Tabs & Spaces. The page leads
// with what routing does, lists each rule as site → Space so the list says
// where links go without opening an editor, and keeps one place to try a
// link. Settings edits a value draft: trying a link neither loads it nor
// changes a Space, and the numbered list is the order of matching, unsaved
// edits included. Save commits the whole draft; leaving the page keeps it in
// LinkDraft, owned by the window, so fetching a link never loses an edit.
// A draft left untouched follows the stored rules, so deleting a Space or a
// bench edit shows at once instead of being overwritten by a later Save.
import SwiftUI

struct LinkRulesView: View {
    @ObservedObject var routes: LinkRoutes
    let spaces: [Space]
    let enabled: Bool
    @ObservedObject var draft: LinkDraft
    let enable: () -> Void
    @FocusState private var focus: UUID?
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    private var ids: Set<UUID> { Set(spaces.map(\.id)) }
    private var changed: Bool { draft.changed(from: routes.rules) }
    private var outcome: LinkTrial { LinkTrial(draft.trial, in: draft.rules, spaces: ids) }

    private var error: String? {
        draft.error(spaces: ids)
    }

    var body: some View {
        GeometryReader { area in
            VStack(spacing: 0) {
                ScrollViewReader { scroll in
                    ScrollView(showsIndicators: false) {
                        page(narrow: area.size.width < metrics.length(Metrics.routeField + Metrics.routeRank + 2 * Metrics.routeInset))
                            .padding(.bottom, metrics.length(4))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onAppear { if let id = draft.editing { scroll.scrollTo(id, anchor: .top) } }
                    .onChange(of: draft.request) { _, _ in
                        if let id = draft.editing { scroll.scrollTo(id, anchor: .top) }
                    }
                }
                // Keep the footer in the layout: an initially empty safe-area
                // inset on ScrollViewReader did not appear on the first edit.
                if changed || draft.saved {
                    changes
                        .padding(.top, metrics.length(12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(alignment: .top) {
                            Palette.ground.overlay(alignment: .top) {
                                Rectangle().fill(Palette.hairline).frame(height: metrics.length(1))
                            }
                        }
                }
            }
            .font(.system(size: metrics.length(Metrics.routeText)))
            .foregroundStyle(Palette.ink)
            .onAppear { focus = draft.editing }
            .onChange(of: draft.request) { _, _ in focus = draft.editing }
            .onChange(of: draft.rules) { _, _ in draft.saved = false }
        }
    }

    private func page(narrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: metrics.length(18)) {
            lead
            if !enabled {
                Card {
                    Line("Paused while Spaces are off", "Your rules are kept and apply again once Spaces are on.") {
                        Pill("Turn on Spaces", action: enable)
                    }
                }
            }
            if let problem = routes.problem { warning(problem) }
            if draft.rules.isEmpty { empty } else { list(narrow: narrow) }
            tryLink
        }
    }

    // MARK: - parts

    private var lead: some View {
        HStack(spacing: metrics.length(2)) {
            Text("Open a site's links in the Space it belongs to.")
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            InfoTip(label: "How link routing works",
                    explanation: "Links you open from a page or from another app go to the Space of the first matching rule. Typed addresses, reloads, redirects, forms and private pages stay where they are.")
        }
    }

    private var empty: some View {
        Card {
            VStack(alignment: .leading, spacing: metrics.length(12)) {
                VStack(alignment: .leading, spacing: metrics.length(3)) {
                    Text("No rules yet").fontWeight(.medium)
                    Text("Without a rule, links open in the Space you are in. A rule sends a site to its own Space every time, for example:")
                        .font(.system(size: metrics.length(Metrics.routeSmall)))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: metrics.length(Metrics.routeGap)) {
                    Text("meet.google.com")
                    Image(systemName: "arrow.right")
                        .font(.system(size: metrics.length(Metrics.routeGlyph)))
                        .foregroundStyle(Palette.muted)
                    SpaceTag(symbol: "briefcase", name: "Work")
                }
                .padding(.horizontal, metrics.length(10))
                .frame(height: metrics.length(Metrics.routeExample))
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: metrics.length(Metrics.routeRadius), style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Example: meet.google.com opens in Work")
                Button("Add your first rule") { add() }
                    .buttonStyle(MigrationButton(kind: changed ? .secondary : .primary))
                    .disabled(spaces.isEmpty)
            }
            .padding(metrics.length(Metrics.routeInset))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func list(narrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: metrics.length(6)) {
            Caption("Checked from the top — the first match wins")
            Card {
                ForEach(Array(draft.rules.enumerated()), id: \.element.id) { index, rule in
                    if index > 0 { Rule() }
                    LinkRuleRow(
                        rule: $draft.rules[index],
                        number: index + 1,
                        count: draft.rules.count,
                        spaces: spaces,
                        open: draft.editing == rule.id,
                        wins: outcome == .rule(index),
                        narrow: narrow,
                        focus: $focus,
                        address: Binding(get: { draft.address(for: rule) }, set: { draft.enter($0, for: rule.id) }),
                        setScope: { draft.scope($0, for: rule.id) },
                        toggle: { withAnimation(Motion.settle) { draft.editing = draft.editing == rule.id ? nil : rule.id } },
                        move: { move(rule.id, to: $0) },
                        remove: { remove(rule.id) }
                    )
                    .id(rule.id)
                }
                Rule()
                AddRow(full: draft.rules.count >= LinkRule.limit) { add() }
                    .disabled(draft.rules.count >= LinkRule.limit || spaces.isEmpty)
            }
        }
    }

    private var changes: some View {
        HStack(spacing: metrics.length(Metrics.routeGap)) {
            if changed {
                Button("Save rules") { save() }
                    .buttonStyle(MigrationButton(kind: .primary))
                    .disabled(error != nil)
                Button("Discard") { reset() }
                    .accessibilityLabel("Discard changes")
                    .buttonStyle(MigrationButton(kind: .quiet))
                if let error {
                    Text(error)
                        .font(.system(size: metrics.length(Metrics.routeSmall)))
                        .foregroundStyle(Palette.danger)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Draft kept while you browse")
                        .font(.system(size: metrics.length(Metrics.routeSmall)))
                        .foregroundStyle(Palette.muted)
                }
            } else {
                Label("Rules saved", systemImage: "checkmark")
                    .font(.system(size: metrics.length(Metrics.routeSmall)))
                    .foregroundStyle(Palette.muted)
            }
        }
    }

    private var tryLink: some View {
        VStack(alignment: .leading, spacing: metrics.length(6)) {
            HStack(spacing: 0) {
                Caption("Try a link")
                InfoTip(label: "About trying a link",
                        explanation: "Checks the rules above as they are now, unsaved changes included. Nothing is opened and nothing is saved.")
            }
            Card {
                HStack(spacing: metrics.length(Metrics.routeGap)) {
                    Image(systemName: "link")
                        .font(.system(size: metrics.length(Metrics.routeGlyph)))
                        .foregroundStyle(Palette.muted)
                    RouteField(text: $draft.trial, prompt: "https://meet.google.com/abc-defg-hij")
                        .accessibilityLabel("Link to try")
                }
                .padding(.horizontal, metrics.length(Metrics.routeInset))
                .frame(height: metrics.length(Metrics.routeTrial))
                Rule()
                verdict
                    .font(.system(size: metrics.length(Metrics.routeSmall)))
                    .padding(.horizontal, metrics.length(Metrics.routeInset))
                    .padding(.vertical, metrics.length(10))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private var verdict: some View {
        switch outcome {
        case .empty:
            Text("Paste a link to see which Space it opens in.")
                .foregroundStyle(Palette.muted)
        case .invalid:
            Text("Enter a complete http or https address, without a user name or password.")
                .foregroundStyle(Palette.muted)
        case .usual:
            HStack(spacing: metrics.length(6)) {
                Image(systemName: "equal").foregroundStyle(Palette.muted)
                Text("No rule matches — it opens where it usually would.")
            }
        case .rule(let index):
            let rule = draft.rules[index]
            let space = spaces.first { $0.id == rule.destination }
            HStack(spacing: metrics.length(Metrics.routeGap)) {
                Rank(number: index + 1, wins: true)
                Text(rule.site).lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.right")
                    .font(.system(size: metrics.length(Metrics.routeGlyph)))
                    .foregroundStyle(Palette.muted)
                SpaceTag(symbol: space?.symbol ?? "questionmark", name: space?.name ?? "Missing Space")
                if !enabled {
                    Text("· paused while Spaces are off").foregroundStyle(Palette.muted).lineLimit(1)
                }
            }
            .accessibilityLabel("Rule \(index + 1) wins: \(space?.name ?? "missing Space")")
        }
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.length(6)) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: metrics.length(Metrics.routeSmall)))
        .foregroundStyle(Palette.danger)
    }

    // MARK: - doing

    private func reset() { draft.reset(to: routes.rules) }

    private func add() {
        guard let space = spaces.first else { return }
        withAnimation(Motion.settle) { _ = draft.add(destination: space.id) }
        DispatchQueue.main.async { focus = draft.editing }
    }

    private func move(_ id: UUID, to target: Int) {
        guard let index = draft.rules.firstIndex(where: { $0.id == id }), draft.rules.indices.contains(target), index != target else { return }
        withAnimation(Motion.settle) {
            draft.rules.move(fromOffsets: IndexSet(integer: index), toOffset: target > index ? target + 1 : target)
        }
    }

    private func remove(_ id: UUID) {
        withAnimation(Motion.settle) { draft.remove(id) }
    }

    private func save() {
        guard error == nil, routes.save(draft.rules, spaces: ids) else { return }
        draft.reset(to: routes.rules)
        draft.saved = true
    }
}

/// Where a link would open under a draft, without loading it: nothing typed,
/// not an address a rule could match, no rule, or the index of the winner.
enum LinkTrial: Equatable {
    case empty, invalid, usual, rule(Int)

    init(_ text: String, in rules: [LinkRule], spaces: Set<UUID>) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { self = .empty; return }
        guard let url = LinkRule.address(text)?.url else { self = .invalid; return }
        guard let winner = LinkRule.winner(in: rules, for: url, spaces: spaces),
              let index = rules.firstIndex(where: { $0.id == winner.id }) else { self = .usual; return }
        self = .rule(index)
    }
}

/// The last line of the list: one more rule, until the list is full.
private struct AddRow: View {
    let full: Bool
    let act: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            HStack(spacing: metrics.length(10)) {
                Image(systemName: "plus")
                    .font(.system(size: metrics.length(Metrics.routeGlyph), weight: .medium))
                    .frame(width: metrics.length(Metrics.routeRank))
                Text("Add a rule")
                Spacer(minLength: metrics.length(Metrics.routeGap))
                if full {
                    Text("\(LinkRule.limit) rules at most")
                        .font(.system(size: metrics.length(Metrics.routeSmall)))
                }
            }
            .foregroundStyle(hovering ? Palette.ink : Palette.muted)
            .padding(.horizontal, metrics.length(Metrics.routeInset))
            .frame(height: metrics.length(Metrics.routeAdd))
            .background(hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 && enabled }
        .animation(Motion.quick, value: hovering)
    }
}
