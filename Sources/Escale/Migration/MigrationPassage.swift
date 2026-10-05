// The import's first question drawn as a passage, so who gives and who
// receives reads at a glance: the Escale Space that receives on the left, the
// browser profile or Arc Space that gives on the right, and an arrow running
// right to left between them. Both
// ends reuse MigrationField's drawn list; the owners stay in MigrationFlow.
// The arrow is still at rest. Dots flow along it only while an import reads or
// writes, and never with Reduce Motion, so an open import page draws nothing
// between imports. It appears only once a browser is chosen, so the first
// screen has a single thing to do. App icons come from the local bundle, looked up once per
// chosen browser, never downloaded.
import SwiftUI
import AppKit

struct MigrationPassage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var flow: MigrationFlow
    @ObservedObject var migration: Migration
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var icon: NSImage?

    init(browser: Browser, flow: MigrationFlow) {
        self.browser = browser; self.flow = flow; migration = flow.migration
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            receiving
            MigrationArrow(moving: flow.busy && !reduceMotion)
                .frame(width: metrics.length(Metrics.migrationPassageGap))
                .frame(maxHeight: .infinity)
            giving
        }
        .fixedSize(horizontal: false, vertical: true)
        .task(id: flow.browser) {
            icon = flow.browser?.applicationIDs
                .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Import from \(flow.browser?.rawValue ?? "a browser") into \(space?.name ?? "a Space")")
    }

    private var space: Space? { browser.spaces.first { $0.id == flow.destination } }

    private var receiving: some View {
        let tint = space.flatMap { Spaces.colours.indices.contains($0.colour) ? Spaces.colours[$0.colour] : nil } ?? Palette.muted
        return end(caption: "Into Escale", tint: tint) {
            tile { Image(systemName: space?.symbol ?? "square.dashed").foregroundStyle(tint) }
                .background(tint.opacity(0.14), in: tileShape)
        } content: {
            MigrationField(title: "Destination Space", options: browser.spaces.map { ($0.id, $0.name) },
                           selection: $flow.destination, showsTitle: false)
                .disabled(flow.choosingLocked)
        }
    }

    @ViewBuilder private var giving: some View {
        if let brand = flow.browser {
            end(caption: brand == .other ? "From a file" : "From \(brand.rawValue)", tint: nil) {
                tile {
                    if let icon { Image(nsImage: icon).resizable().scaledToFit() }
                    else { Image(systemName: "globe").foregroundStyle(Palette.muted) }
                }
                .background(icon == nil ? Palette.wash : .clear, in: tileShape)
            } content: {
                if !flow.sources.isEmpty {
                    HStack(spacing: metrics.length(Metrics.arrivalLine)) {
                        MigrationField(title: exported ? "File" : brand.sourceField,
                                       options: flow.sources.map { (Optional($0.id), $0.profile) },
                                       selection: Binding(get: { flow.selected }, set: { flow.select($0) }), showsTitle: false)
                            .disabled(flow.choosingLocked)
                        if brand.automatic { refresh(brand) }
                    }
                } else if flow.discovering {
                    HStack(spacing: metrics.length(Metrics.arrivalRowGap)) {
                        MigrationSpinner()
                        note("Finding \(brand.sourceName.lowercased())s…")
                    }
                    .frame(height: metrics.length(Metrics.migrationChoiceHeight))
                } else {
                    HStack(spacing: metrics.length(Metrics.arrivalLine)) {
                        note(brand.automatic ? brand.nothingFound : "Choose a folder or an export below.")
                        Spacer(minLength: 0)
                        if brand.automatic { refresh(brand) }
                    }
                    .frame(height: metrics.length(Metrics.migrationChoiceHeight))
                }
            }
        }
    }

    /// An export chosen from Other options replaces the automatic source.
    private var exported: Bool { ["html", "links"].contains(flow.source?.format ?? "") }

    private func refresh(_ brand: MigrationBrowser) -> some View {
        Button { flow.findHome() } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: metrics.length(Metrics.arrivalText)))
                .foregroundStyle(Palette.muted)
                .frame(width: metrics.length(Metrics.infoTarget), height: metrics.length(Metrics.migrationChoiceHeight))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(flow.choosingLocked)
        .help("Refresh \(brand.sourceName.lowercased())s")
        .accessibilityLabel("Refresh \(brand.rawValue) \(brand.sourceName.lowercased())s")
    }

    private var tileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: metrics.length(Metrics.migrationPassageTileRadius), style: .continuous)
    }

    private func tile<Glyph: View>(@ViewBuilder _ glyph: () -> Glyph) -> some View {
        glyph()
            .font(.system(size: metrics.length(Metrics.arrivalChoiceGlyph)))
            .frame(width: metrics.length(Metrics.migrationPassageTile), height: metrics.length(Metrics.migrationPassageTile))
    }

    /// One end of the passage: its mark, a caption saying its role, its choice.
    private func end<Mark: View, Content: View>(caption: String, tint: Color?,
                                                @ViewBuilder mark: () -> Mark,
                                                @ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: metrics.length(Metrics.arrivalChoiceRadius), style: .continuous)
        return VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalDetailGap)) {
            HStack(spacing: metrics.length(Metrics.arrivalDetailGap)) {
                mark()
                Text(caption.uppercased())
                    .font(.system(size: metrics.length(Metrics.arrivalBadge), weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            content()
        }
        .padding(metrics.length(Metrics.arrivalCardInset))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack {
                shape.fill(Palette.raised)
                if let tint {
                    shape.fill(LinearGradient(colors: [tint.opacity(0.12), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .shadow(color: Palette.shadow.opacity(0.5), radius: 6, y: 2)
            .overlay(shape.strokeBorder(Palette.edge, lineWidth: 1))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: metrics.length(Metrics.arrivalSmall))).foregroundStyle(Palette.muted)
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
    }
}

/// The arrow from the giving end to the receiving one: a dotted line through
/// a round badge holding a left arrow. While an import works the badge turns
/// to ink and dots travel along the line toward the Escale Space.
private struct MigrationArrow: View {
    let moving: Bool
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dot = metrics.length(Metrics.migrationPassageDot), badge = metrics.length(Metrics.migrationPassageBadge)
        GeometryReader { box in
            let width = box.size.width, middle = box.size.height / 2
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: width, y: middle))
                    path.addLine(to: CGPoint(x: 0, y: middle))
                }
                .stroke(Palette.muted.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.1, dot * 1.5]))
                if moving {
                    TimelineView(.animation) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                        ZStack {
                            ForEach(0..<4, id: \.self) { index in
                                let travel = (phase + Double(index) / 4).truncatingRemainder(dividingBy: 1)
                                Circle().fill(Palette.ink)
                                    .frame(width: dot, height: dot)
                                    .opacity(sin(travel * .pi))
                                    .position(x: width * (1 - travel), y: middle)
                            }
                        }
                    }
                }
                Circle()
                    .fill(moving ? Palette.ink : Palette.raised)
                    .overlay(Circle().strokeBorder(Palette.edge, lineWidth: 1))
                    .shadow(color: Palette.shadow.opacity(0.5), radius: 4, y: 1)
                    .frame(width: badge, height: badge)
                    .overlay {
                        Image(systemName: "arrow.left")
                            .font(.system(size: metrics.length(Metrics.migrationPassageArrow), weight: .semibold))
                            .foregroundStyle(moving ? Palette.inverse : Palette.ink)
                    }
                    .position(x: width / 2, y: middle)
            }
        }
        .animation(reduceMotion ? nil : Motion.arrival, value: moving)
        .accessibilityHidden(true)
    }
}
