// A rule reads as address → Space. Its editor keeps the address and scope
// together, accepting a copied URL without asking people to split its parts.
// The visible explanation states what is included before the destination is
// chosen; the existing order controls keep first-match priority accessible.
import SwiftUI

struct LinkRuleRow: View {
    @Binding var rule: LinkRule
    let number: Int
    let count: Int
    let spaces: [Space]
    let open: Bool
    /// The rule that wins for the link being tried.
    let wins: Bool
    let narrow: Bool
    var focus: FocusState<UUID?>.Binding
    let toggle: () -> Void
    /// To this index in the order.
    let move: (Int) -> Void
    let remove: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @State private var hovering = false
    @Binding var address: String
    let setScope: (LinkRule.Scope) -> Void

    init(rule: Binding<LinkRule>, number: Int, count: Int, spaces: [Space], open: Bool, wins: Bool, narrow: Bool,
         focus: FocusState<UUID?>.Binding, address: Binding<String>, setScope: @escaping (LinkRule.Scope) -> Void, toggle: @escaping () -> Void,
         move: @escaping (Int) -> Void, remove: @escaping () -> Void) {
        _rule = rule
        self.number = number; self.count = count; self.spaces = spaces
        self.open = open; self.wins = wins; self.narrow = narrow; self.focus = focus
        self.toggle = toggle; self.move = move; self.remove = remove
        _address = address; self.setScope = setScope
    }

    private var space: Space? { spaces.first { $0.id == rule.destination } }
    private var index: Int { number - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: metrics.length(6)) {
                Button(action: toggle) {
                    HStack(spacing: metrics.length(10)) {
                        Rank(number: number, wins: wins)
                        VStack(alignment: .leading, spacing: metrics.length(2)) {
                            Text(rule.site)
                                .foregroundStyle(rule.blank ? Palette.muted : Palette.ink)
                                .lineLimit(1).truncationMode(.middle)
                            reach
                        }
                        Spacer(minLength: metrics.length(Metrics.routeGap))
                        Image(systemName: "arrow.right")
                            .font(.system(size: metrics.length(Metrics.routeGlyph)))
                            .foregroundStyle(Palette.muted)
                        SpaceTag(symbol: space?.symbol ?? "exclamationmark.triangle", name: space?.name ?? "Choose a Space",
                                 missing: space == nil)
                            .frame(maxWidth: metrics.length(Metrics.routeSpace), alignment: .leading)
                    }
                    .frame(minHeight: metrics.length(Metrics.routeRow))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rule \(number): \(rule.site), \(rule.reach), opens in \(space?.name ?? "a missing Space")")
                .accessibilityHint(open ? "Closes its editor" : "Opens its editor")
                .accessibilityAddTraits(open ? .isSelected : [])
                order
            }
            .padding(.leading, metrics.length(Metrics.routeInset))
            .padding(.trailing, metrics.length(Metrics.routeGap))
            if open { editor }
        }
        .background(open ? Palette.wash : hovering ? Palette.hover : .clear)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .contextMenu {
            Button("Move to Top") { move(0) }.disabled(index == 0)
            Button("Move Up") { move(index - 1) }.disabled(index == 0)
            Button("Move Down") { move(index + 1) }.disabled(index == count - 1)
            Button("Move to Bottom") { move(count - 1) }.disabled(index == count - 1)
            Divider()
            Button("Remove Rule", action: remove)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Move up") { if index > 0 { move(index - 1) } }
        .accessibilityAction(named: "Move down") { if index < count - 1 { move(index + 1) } }
        .accessibilityAction(named: "Remove rule", remove)
    }

    /// How much of the site it takes, or that the editor has a fix to ask for.
    @ViewBuilder private var reach: some View {
        if !rule.blank, rule.error != nil {
            HStack(spacing: metrics.length(4)) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Not valid yet")
            }
            .font(.system(size: metrics.length(Metrics.routeSmall)))
            .foregroundStyle(Palette.danger)
        } else {
            Text(rule.blank ? "Paste an address to get started" : rule.reach)
                .font(.system(size: metrics.length(Metrics.routeSmall)))
                .foregroundStyle(Palette.muted)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    /// Up and down, stacked where the row keeps room for them.
    private var order: some View {
        VStack(spacing: 0) {
            Arrow(symbol: "chevron.up", label: "Move rule \(number) up") { move(index - 1) }
                .disabled(index == 0)
            Arrow(symbol: "chevron.down", label: "Move rule \(number) down") { move(index + 1) }
                .disabled(index == count - 1)
        }
        .frame(width: metrics.length(Metrics.routeOrder))
        .opacity(hovering || open ? 1 : 0)
        .allowsHitTesting(hovering || open)
    }

    // MARK: - editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.routeGap)) {
            Text("When a link goes to")
                .fontWeight(.medium)
            input($address, "Paste a URL or type github.com/acme", label: "Address to match", leads: true)
            note(rule.scope == .exact ? "Paste a full URL. HTTPS is used if omitted." : "Full URLs work too. Add :3000 for a specific port; leave it out for any port.")

            if narrow {
                // In a narrow page at Large size, stacking keeps every scope
                // readable instead of forcing Settings beyond the page frame.
                VStack(alignment: .leading, spacing: metrics.length(2)) {
                    ForEach(scopeOptions, id: \.0) { scope, title in
                        Button { setScope(scope) } label: {
                            Text(title).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(MigrationButton(kind: .quiet))
                        .background { if rule.scope == scope { Chosen(radius: metrics.length(Metrics.routeRadius)) } }
                        .accessibilityAddTraits(rule.scope == scope ? .isSelected : [])
                    }
                }
            } else {
                Segmented(options: scopeOptions, selection: Binding(get: { rule.scope }, set: setScope))
                    .accessibilityRepresentation { HStack { accessibleScopes } }
            }
            if !address.isEmpty, let error = LinkAddress.error(address) ?? rule.error {
                Text(error)
                    .font(.system(size: metrics.length(Metrics.routeSmall)))
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                note(explanation)
            }
            if rule.scope != .exact {
                HStack(spacing: metrics.length(Metrics.routeGap)) {
                    Switch(on: $rule.subdomains)
                        .accessibilityLabel("Include subdomains")
                        .accessibilityValue(rule.subdomains ? "On" : "Off")
                    Text("Include subdomains")
                        .font(.system(size: metrics.length(Metrics.routeSmall)))
                    InfoTip(label: "About subdomains", explanation: "For github.com, also match links to subdomains such as docs.github.com.")
                }
            }
            HStack(spacing: metrics.length(Metrics.routeGap)) {
                Text("Open in")
                    .fontWeight(.medium)
                MigrationField(title: "Space", options: spaces.map { ($0.id, $0.name) }, selection: $rule.destination,
                               symbol: { id in spaces.first { $0.id == id }?.symbol },
                               height: Metrics.routeFieldHeight, showsTitle: false)
                    .accessibilityLabel("Destination Space")
            }
            .padding(.top, metrics.length(Metrics.routeGap))
            Button("Remove rule", action: remove)
                .buttonStyle(MigrationButton(kind: .quiet))
                .padding(.leading, -metrics.length(Metrics.arrivalRowGap))
        }
        .padding(.leading, metrics.length(Metrics.routeInset + Metrics.routeRank + 10))
        .padding(.trailing, metrics.length(Metrics.routeInset + Metrics.routeOrder))
        .padding(.bottom, metrics.length(12))
    }

    private var scopeOptions: [(LinkRule.Scope, String)] {
        [(.host, "Whole site"), (.path, "Path & subpages"), (.exact, "Exact URL")]
    }

    private var accessibleScopes: some View {
        ForEach(scopeOptions, id: \.0) { scope, title in
            Button(title) { setScope(scope) }
                .accessibilityAddTraits(rule.scope == scope ? .isSelected : [])
        }
    }

    private var explanation: String {
        guard !address.isEmpty else { return "Paste a link: its address suggests a scope. You can change it here." }
        let site = rule.host + (rule.port.isEmpty ? "" : ":" + rule.port)
        switch rule.scope {
        case .host:
            return "Every page on \(site). Paths, query parameters and #fragments are ignored. HTTP and HTTPS both match."
        case .path:
            return "\(site)\(rule.path) and its subpages. Paths are case sensitive; query parameters and #fragments are ignored. HTTP and HTTPS both match."
        case .exact:
            return "Only this URL, including HTTP/HTTPS, port, path, query parameters and #fragment. HTTPS is used if omitted."
        }
    }

    /// `leads` marks the field a new rule starts in.
    private func input(_ text: Binding<String>, _ prompt: String, label: String, leads: Bool = false) -> some View {
        let field = RouteField(text: text, prompt: prompt)
            .font(.system(size: metrics.length(Metrics.routeSmall)))
            .accessibilityLabel(label)
        return Group {
            if leads { field.focused(focus, equals: rule.id) } else { field }
        }
            .padding(.horizontal, metrics.length(Metrics.routeGap))
            .frame(height: metrics.length(Metrics.routeFieldHeight))
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: metrics.length(Metrics.routeRadius), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: metrics.length(Metrics.routeRadius), style: .continuous).strokeBorder(Palette.hairline))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: metrics.length(Metrics.routeSmall)))
            .foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A plain field whose prompt reads as a prompt: grey under the ink the
/// Settings page sets, where the system prompt would take that ink.
struct RouteField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(prompt)
                    .foregroundStyle(Palette.muted.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityHidden(true)
            }
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(Palette.ink)
        }
    }
}

/// A rule's place in the order; filled in ink when it is the one that wins
/// for the link being tried, so the list and the trial point at each other.
struct Rank: View {
    let number: Int
    let wins: Bool
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        Text("\(number)")
            .font(.system(size: metrics.length(Metrics.routeSmall), weight: wins ? .semibold : .regular).monospacedDigit())
            .foregroundStyle(wins ? Palette.inverse : Palette.muted)
            .frame(width: metrics.length(Metrics.routeRank), height: metrics.length(Metrics.routeRank))
            .background { if wins { Circle().fill(Palette.ink) } }
            .accessibilityHidden(true)
    }
}

/// A Space as a destination: its icon and its name, or what is missing.
struct SpaceTag: View {
    let symbol: String
    let name: String
    var missing = false
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.length(5)) {
            Image(systemName: symbol)
                .font(.system(size: metrics.length(Metrics.routeGlyph), weight: .medium))
                .foregroundStyle(missing ? Palette.danger : Palette.muted)
            Text(name).lineLimit(1).truncationMode(.tail)
        }
        .foregroundStyle(missing ? Palette.danger : Palette.ink)
    }
}

/// One of a rule's order arrows, quiet until the pointer is on it.
private struct Arrow: View {
    let symbol: String
    let label: String
    let act: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Image(systemName: symbol)
                .font(.system(size: metrics.length(Metrics.routeGlyph) - 1, weight: .semibold))
                .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                .frame(width: metrics.length(Metrics.routeOrder), height: metrics.length(Metrics.routeRow) / 2)
                .background(hovering ? Palette.hover : .clear,
                            in: RoundedRectangle(cornerRadius: metrics.length(Metrics.routeRadius) / 2, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 && enabled }
        .help(label)
        .accessibilityLabel(label)
    }
}

extension LinkRule {
    /// Nothing to match on yet: a rule just added.
    var blank: Bool { (scope == .exact ? exact : host).isEmpty }

    /// Criteria beyond a whole site, which keep the editor's details open.
    var precise: Bool { scope != .host || subdomains || !port.isEmpty }

    /// What the rule is about, as the list names it: the site or the address.
    var site: String { blank ? "New rule" : (scope == .exact ? exact : host) }

    /// How much of the site the rule takes, in words.
    var reach: String {
        var text: String
        switch scope {
        case .exact: return "This exact address"
        case .host: text = subdomains ? "Site and subdomains" : "Whole site"
        case .path: text = "Pages under \(path.isEmpty ? "a path" : path)" + (subdomains ? ", subdomains too" : "")
        }
        if !port.isEmpty { text += " · port \(port)" }
        return text
    }
}
