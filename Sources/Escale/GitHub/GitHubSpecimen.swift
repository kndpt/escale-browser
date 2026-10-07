// What Bearings GitHub gives, shown the same way in the arrival and in
// Settings › GitHub, so the two places cannot drift apart. A small specimen of
// the real bar (its field with the New Tab · GitHub capsule, the real result
// rows) types its example query once; a switch under it between "On this Mac"
// and "With GitHub" changes only the specimen's status marks and the two
// lines under it: locally, only the row open in a tab knows its state;
// connected, every row is coloured. The specimen is fixed text: it never
// touches history, the cache or the network.
//
// Each place keeps its own actions (the arrival ends itself, Settings stays
// open), but the device code and the button row are drawn here once.
import AppKit
import SwiftUI

struct GitHubSpecimen: View {
    enum Mode: Hashable { case local, github }

    @ObservedObject var access: GitHubAccess
    @Binding var mode: Mode
    /// The Search GitHub shortcut as bound now, so a rebinding shows here too.
    let stroke: KeyStroke?
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var typed = ""

    private static let query = "refresh token"

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalGap)) {
            specimen
            VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalDetailGap)) {
                Segmented(options: [(Mode.local, "On this Mac"), (Mode.github, "With GitHub")], selection: $mode)
                    .padding(.bottom, metrics.length(Metrics.arrivalLine))
                if mode == .github {
                    ArrivalFeature(symbol: "arrow.triangle.2.circlepath", title: "Live status on every row",
                                   detail: "Open, draft, merged or closed, checked when the row is on screen")
                    ArrivalFeature(symbol: "eye", title: "Read-only, one Space at a time",
                                   detail: "What you type stays on this Mac. Disconnect at any time")
                } else {
                    ArrivalFeature(symbol: "clock.arrow.circlepath", title: "Everything you have visited",
                                   detail: "History and tabs of this Space, by a few words or a number")
                    ArrivalFeature(symbol: "lock", title: "No account, nothing sent",
                                   detail: "Status comes from the pages you already have open")
                }
            }
            // Two lines of text crossfading read as a smudge: they swap at once,
            // while the specimen's status marks carry the change.
            .transaction { $0.animation = nil }
        }
        .animation(reduceMotion ? nil : Motion.arrival, value: mode)
        .onAppear { follow() }
        .onChange(of: access.connection) { _, _ in follow() }
        .task(id: reduceMotion) { await type() }
    }

    /// A connected Space shows what it has; a build that cannot connect shows what it can do.
    private func follow() {
        if case .connected = access.connection { mode = .github }
        else if !access.canConnect { mode = .local }
    }

    /// A Bearings GitHub surface at its real size, with the real result rows.
    private var specimen: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.fieldRadius, style: .continuous)
        return VStack(spacing: 0) {
            Group {
                // The real field: GitHub is a mode of Bearings, beside New Tab.
                HStack(spacing: metrics.length(Metrics.searchInset)) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Palette.muted)
                    Text(typed.isEmpty ? " " : typed)
                        .foregroundStyle(Palette.ink)
                    Spacer(minLength: 0)
                    Modes(modes: .pair(.newTab, shy: false) { title, _ in title }, selection: Bearing.github) { _ in }
                }
                .font(.system(size: metrics.length(Metrics.searchFont)))
                .padding(.horizontal, metrics.length(Metrics.searchInset))
                .frame(height: metrics.length(Metrics.searchFieldHeight))
                Divider().overlay(Palette.hairline)
                VStack(spacing: 0) {
                    ForEach(Array(Self.examples.enumerated()), id: \.offset) { index, example in
                        GitHubResult(title: example.title, repository: example.repository, number: example.number,
                                     symbol: mode == .github ? example.state : example.local,
                                     old: false, age: "",
                                     observation: "", open: index == 0, selected: index == 0, take: {})
                    }
                }
                .padding([.horizontal, .top], metrics.length(Metrics.searchGap))
                .opacity(typed == Self.query ? 1 : 0)
                .animation(reduceMotion ? nil : Motion.arrival, value: typed == Self.query)
                // The shortcut as bound, where the footer has room: one keystroke away.
                HStack {
                    Text("This Space · Local search")
                        .font(.system(size: metrics.length(Metrics.searchDetail)))
                        .foregroundStyle(Palette.muted)
                    Spacer(minLength: metrics.length(Metrics.searchGap))
                    keycaps
                }
                .padding(.horizontal, metrics.length(Metrics.searchInset))
                .padding(.vertical, metrics.length(Metrics.searchGap))
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(mode == .github
                ? "Example: searching refresh token finds an open, a merged and a closed pull request, each with its current status."
                : "Example: searching refresh token finds three pull requests. The one open in a tab shows its status.")
        }
        .glass(.panel, in: shape)
        .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1).allowsHitTesting(false))
    }

    /// The shortcut drawn as keys, one cap per modifier and one for the key.
    @ViewBuilder private var keycaps: some View {
        if let stroke {
            let flags = stroke.flags
            let caps = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
                .filter { flags.contains($0.0) }.map(\.1) + [stroke.glyph]
            HStack(spacing: metrics.length(Metrics.arrivalLine)) {
                ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                    Text(cap)
                        .font(.system(size: metrics.length(Metrics.arrivalSmall), weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .frame(minWidth: metrics.length(Metrics.arrivalKey), minHeight: metrics.length(Metrics.arrivalKey))
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: metrics.length(Metrics.arrivalKeyRadius), style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: metrics.length(Metrics.arrivalKeyRadius), style: .continuous)
                            .strokeBorder(Palette.hairline, lineWidth: 1))
                }
            }
        }
    }

    /// Types the example once; with Reduce Motion it is simply there.
    private func type() async {
        guard !reduceMotion else { typed = Self.query; return }
        guard typed != Self.query else { return }
        typed = ""
        for letter in Self.query {
            try? await Task.sleep(nanoseconds: UInt64(Motion.arrivalKeystroke * 1_000_000_000))
            if Task.isCancelled { typed = Self.query; return }
            typed.append(letter)
        }
    }

    // Illustrations only: not GitHub identities, never stored or requested.
    private static let examples: [(title: String, repository: String, number: String, state: GitHubSymbol, local: GitHubSymbol)] = [
        ("Rotate refresh tokens on every use", "acme/api", "#482", .pullOpen, .pullOpen),
        ("Move token refresh to the gateway", "acme/web", "#1290", .pullMerged, .pullUnknown),
        ("Keep the refresh token in localStorage", "acme/web", "#1251", .pullClosed, .pullUnknown),
    ]
}

extension GitHubConnection {
    /// Which set of controls the connection calls for; a new code is a new set.
    var stage: String {
        switch self {
        case .local, .unavailable: return "offer"
        case .connecting, .disconnecting: return "waiting"
        case .authorizing(let code, _): return "code " + code
        case .connected: return "connected"
        }
    }
}

/// The device code as separate tiles, with where it is typed.
struct GitHubCode: View {
    let code: String
    var note = "Escale opens github.com/login/device in a tab and waits there. Status appears in Bearings once you approve."
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalDetailGap)) {
            Text("Enter this code on GitHub")
            tiles
            ArrivalNote(text: note)
        }
    }

    /// Read as one value by VoiceOver.
    private var tiles: some View {
        HStack(spacing: metrics.length(Metrics.arrivalLine * 2)) {
            ForEach(Array(code.enumerated()), id: \.offset) { _, character in
                if character == "-" {
                    Text("–").foregroundStyle(Palette.muted)
                } else {
                    Text(String(character))
                        .font(.system(size: metrics.length(Metrics.arrivalCodeFont), weight: .semibold, design: .monospaced))
                        .frame(width: metrics.length(Metrics.arrivalCodeTile), height: metrics.length(Metrics.arrivalCodeTile * 1.2))
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: metrics.length(Metrics.arrivalButtonRadius), style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: metrics.length(Metrics.arrivalButtonRadius), style: .continuous)
                            .strokeBorder(Palette.hairline, lineWidth: 1))
                }
            }
        }
        .foregroundStyle(Palette.ink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Code \(code)")
    }
}

/// Buttons side by side, stacked when the column is too narrow for them.
struct GitHubButtons<Content: View>: View {
    @ViewBuilder let content: Content
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: metrics.length(Metrics.arrivalRowGap)) { content }
            VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalRowGap)) { content }
        }
    }
}
