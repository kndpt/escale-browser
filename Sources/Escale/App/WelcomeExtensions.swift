// Welcome's one lasting choice, so a step of its own: whether one set of
// extensions serves every Space or each Space keeps its own (see
// Extensions.swift). It is asked only on a first arrival with nothing
// installed, since changing it later moves what extensions keep and takes a
// relaunch (ExtensionSwitch.swift, from Settings), and it is written as the
// step is left. Each card draws its answer from Palette and Metrics, with no
// image: three Spaces under one band of extensions, or three Spaces each
// under its own.
import SwiftUI

extension WelcomePanel {
    /// Whether the arrival asks how extensions are kept: not once Welcome
    /// was finished, nor once a mode is settled outside this arrival, nor
    /// with an extension installed.
    static func asksForExtensions(welcomed: Bool, decided: Bool, installed: Bool) -> Bool {
        !welcomed && !decided && !installed
    }
}

extension Browser {
    /// Whether any Space has an extension installed, read without waking
    /// a Space; true below macOS 15.4, where there are none to choose about.
    var hasExtensions: Bool {
        guard #available(macOS 15.4, *) else { return true }
        return spaces.contains { !Extensions.saved(space: $0.id).isEmpty }
    }

    /// The step's answer, as it is left. The owners made at launch for the
    /// mode stored then are made again, and so is every tab made with one,
    /// so the next page opened carries the chosen set.
    func chooseExtensions(shared: Bool) {
        guard #available(macOS 15.4, *), !hasExtensions else { return }
        prefs.sharedExtensions = shared
        welcomeReturn.choseExtensions = true
        Extensions.adopt()
        // The owner serving this Space may be one made but never started:
        // shared, the first Space's, when the launch opened another Space.
        Extensions.forSpace(spaceID).start(for: self)
        for tab in tabs + parkedTabs {
            guard let controller = tab.extensionController,
                  controller !== Extensions.forSpace(tab.space).controller,
                  let fresh = replace(tab, going: tab.address) else { continue }
            // Welcome may come back after browsing: the tab keeps what it was,
            // as one moved to another Space does.
            fresh.pin = tab.pin
            fresh.name = tab.name
            fresh.migration = tab.migration
            shelfTabs[fresh.id] = shelfTabs.removeValue(forKey: tab.id)
            rememberSession(tab.space)
        }
    }
}

/// One answer: its picture, its name and what it means, on the arrival's
/// card, chosen as `ArrivalChoice` is; Settings › Extensions shows the same
/// two.
struct ExtensionModeChoice: View {
    let shared: Bool
    let chosen: Bool
    var badge: String? = nil
    let action: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var title: String { shared ? "Same in every Space" : "Different in each Space" }
    private var detail: String {
        shared ? "Install once, sign in once. Your password manager and ad blocker are everywhere."
            : "Each Space installs and signs in to its own. For separate clients or testing an extension."
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.length(Metrics.arrivalChoiceRadius), style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalDetailGap)) {
                ExtensionModePicture(shared: shared, lit: chosen || hovering)
                    .padding(.bottom, metrics.length(Metrics.arrivalLine))
                Text(title)
                    .font(.system(size: metrics.length(Metrics.arrivalChoiceLabel), weight: chosen ? .medium : .regular))
                    .foregroundStyle(Palette.ink)
                ArrivalNote(text: detail)
            }
            .padding(metrics.length(Metrics.arrivalCardInset))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                if chosen { Chosen(shape: shape) } else { shape.fill(hovering ? Palette.hover : Palette.wash) }
            }
            .overlay(shape.strokeBorder(chosen ? Palette.edge : Palette.hairline, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text(badge)
                        .font(.system(size: metrics.length(Metrics.arrivalBadge), weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, metrics.length(Metrics.arrivalBadgeInset))
                        .padding(.vertical, metrics.length(Metrics.arrivalLine))
                        .background(Palette.wash, in: Capsule())
                        .padding(metrics.length(Metrics.arrivalRowGap))
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(reduceMotion ? nil : Motion.arrival, value: chosen)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, badge].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(detail)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }
}

/// Three Spaces, each a tile with its symbol, under extensions drawn as
/// marks on a band: one band joined to every tile, or a band of its own,
/// with other marks, over each. Ink while its card is chosen or under the
/// pointer, muted otherwise.
private struct ExtensionModePicture: View {
    let shared: Bool
    let lit: Bool
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    private static let spaces = ["house", "briefcase", "person.2"]
    /// A password manager, an ad blocker, a dev tool, a reader: what one set
    /// holds, and what each Space would hold on its own.
    private static let together = ["key.fill", "shield.fill", "hammer.fill", "book.fill"]
    private static let apart = [["key.fill", "shield.fill"], ["hammer.fill"], ["key.fill", "book.fill"]]

    var body: some View {
        let tile = metrics.length(Metrics.arrivalModeTile)
        let gap = metrics.length(Metrics.arrivalModeGap)
        let ink = lit ? Palette.ink : Palette.muted
        VStack(spacing: 0) {
            if shared {
                band(Self.together, ink: ink, width: tile * 3 + gap * 2)
                HStack(spacing: gap) {
                    ForEach(0..<3, id: \.self) { _ in link(dashed: true, ink: ink).frame(width: tile) }
                }
                HStack(spacing: gap) {
                    ForEach(Self.spaces, id: \.self) { space(symbol: $0, ink: ink) }
                }
            } else {
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(0..<3, id: \.self) { index in
                        VStack(spacing: 0) {
                            band(Self.apart[index], ink: ink)
                            link(dashed: false, ink: ink)
                            space(symbol: Self.spaces[index], ink: ink)
                        }
                        .frame(width: tile)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func band(_ marks: [String], ink: Color, width: CGFloat? = nil) -> some View {
        HStack(spacing: metrics.length(Metrics.arrivalLine) * 2) {
            ForEach(marks, id: \.self) { mark in
                Image(systemName: mark)
                    .font(.system(size: metrics.length(Metrics.arrivalModeMark)))
                    .foregroundStyle(ink)
            }
        }
        .padding(.horizontal, metrics.length(Metrics.arrivalBadgeInset))
        .frame(width: width, height: metrics.length(Metrics.arrivalModeBand))
        .background(Palette.wash, in: Capsule())
        .overlay(Capsule().strokeBorder(lit ? Palette.edge : Palette.hairline, lineWidth: 1))
    }

    private func link(dashed: Bool, ink: Color) -> some View {
        Upright()
            .stroke(ink.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: dashed ? [2, 2] : []))
            .frame(width: 1, height: metrics.length(Metrics.arrivalModeLink))
    }

    private func space(symbol: String, ink: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: metrics.length(Metrics.arrivalButtonRadius), style: .continuous)
        return Image(systemName: symbol)
            .font(.system(size: metrics.length(Metrics.arrivalModeSymbol)))
            .foregroundStyle(ink)
            .frame(width: metrics.length(Metrics.arrivalModeTile), height: metrics.length(Metrics.arrivalModeTile))
            .background(Palette.wash, in: shape)
            .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1))
    }

    /// A line straight down the middle, for a link from a band to a Space.
    private struct Upright: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            }
        }
    }
}
