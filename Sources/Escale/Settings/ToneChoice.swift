import SwiftUI

// The Colours choice as two small browsers, one per tone, rather than two
// words: Neutral and Escale differ in temperature, which a name cannot show.
// Each is drawn in its own tone's colours whatever the window wears
// (Palette.sample), so both can be compared side by side. With the theme on
// System it is cut on the diagonal, light to the top left and dark to the
// bottom right, as macOS
// draws its own appearance choice: one glance shows both looks of a tone.
//
// The sample is a handful of shapes in the palette's roles — rail, column,
// the tab you are on, a page with a title and an ink button — not a picture,
// so it follows the palette when a value there changes, and costs two small
// view trees that exist only while Settings › Appearance is open.

/// Neutral or Escale, each shown as a browser in its colours.
struct ToneChoice: View {
    @Binding var selection: Tone
    /// The theme chosen beside it: one look, or both cut on the diagonal.
    let look: Look
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.cardDensity) private var density

    @State private var hovered: Tone?

    var body: some View {
        HStack(spacing: metrics.length(18)) {
            ForEach(Tone.allCases) { tone in
                Button {
                    selection = tone
                } label: {
                    VStack(spacing: metrics.length(6)) {
                        sample(tone)
                            .padding(metrics.length(2.5))
                            .overlay(
                                RoundedRectangle(cornerRadius: metrics.length(Metrics.toneRadius + 2.5), style: .continuous)
                                    .strokeBorder(ring(tone), lineWidth: metrics.length(2))
                            )
                        Text(tone.title)
                            .font(.system(size: metrics.length(density.detail), weight: tone == selection ? .medium : .regular))
                            .foregroundStyle(tone == selection ? Palette.ink : Palette.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? tone : (hovered == tone ? nil : hovered) }
                .accessibilityLabel("\(tone.title) colours")
                .accessibilityAddTraits(tone == selection ? .isSelected : [])
            }
        }
        .animation(Motion.quick, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Colours")
        .padding(.horizontal, metrics.length(density.inset))
        .padding(.bottom, metrics.length(density.pad * 1.5))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func sample(_ tone: Tone) -> some View {
        let shape = RoundedRectangle(cornerRadius: metrics.length(Metrics.toneRadius), style: .continuous)
        Group {
            switch look {
            case .light: ToneSample(tone: tone, dark: false)
            case .dark: ToneSample(tone: tone, dark: true)
            case .system:
                ZStack {
                    ToneSample(tone: tone, dark: false)
                    ToneSample(tone: tone, dark: true).clipShape(Diagonal())
                }
            }
        }
        // At its size where there is room, smaller at the same proportions
        // where there is not: compact Settings beside an open column leave
        // less than the two samples' width, and a fixed one widened the
        // whole page past its frame.
        .aspectRatio(Metrics.toneWidth / Metrics.toneHeight, contentMode: .fit)
        .frame(maxWidth: metrics.length(Metrics.toneWidth))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Palette.edge, lineWidth: 1))
    }

    /// Ink round the one chosen, a fine edge round the one under the pointer.
    private func ring(_ tone: Tone) -> Color {
        if tone == selection { return Palette.ink }
        return hovered == tone ? Palette.edge : .clear
    }
}

/// A browser at a glance, in one tone and one look: the rail with its
/// space, the column with the tab you are on, and the page beside them.
private struct ToneSample: View {
    let tone: Tone
    let dark: Bool

    var body: some View {
        GeometryReader { box in
            let w = box.size.width, h = box.size.height
            let page = CGRect(x: 0.39 * w, y: 0.07 * h, width: 0.57 * w, height: 0.86 * h)
            ZStack(alignment: .topLeading) {
                colour(Palette.NS.envelope)
                // The rail: the space you are in, and another.
                bar(0.05 * w, 0.09 * h, 0.05 * w, 0.07 * h, colour(Palette.NS.selection), radius: 2)
                Circle().fill(colour(Palette.NS.faint))
                    .frame(width: 0.026 * w, height: 0.026 * w)
                    .offset(x: 0.062 * w, y: 0.24 * h)
                // The column: its space's name, then the tab you are on among others.
                bar(0.15 * w, 0.10 * h, 0.14 * w, 0.04 * h, colour(Palette.NS.ink))
                bar(0.15 * w, 0.22 * h, 0.10 * w, 0.03 * h, colour(Palette.NS.muted))
                bar(0.13 * w, 0.30 * h, 0.23 * w, 0.11 * h, colour(Palette.NS.selection), radius: 3)
                bar(0.15 * w, 0.345 * h, 0.15 * w, 0.03 * h, colour(Palette.NS.ink))
                bar(0.15 * w, 0.46 * h, 0.17 * w, 0.03 * h, colour(Palette.NS.muted))
                bar(0.15 * w, 0.55 * h, 0.12 * w, 0.03 * h, colour(Palette.NS.muted))
                // The page: a title, a few lines and its one ink button.
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(colour(Palette.NS.ground))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(colour(Palette.NS.edge), lineWidth: 0.5))
                    .frame(width: page.width, height: page.height)
                    .offset(x: page.minX, y: page.minY)
                bar(page.minX + 0.09 * page.width, page.minY + 0.13 * page.height, 0.38 * page.width, 0.06 * page.height, colour(Palette.NS.ink))
                ForEach(Array([(0.29, 0.76), (0.39, 0.64), (0.49, 0.70)].enumerated()), id: \.offset) { _, line in
                    bar(page.minX + 0.09 * page.width, page.minY + line.0 * page.height, line.1 * page.width, 0.04 * page.height,
                        colour(Palette.NS.wash))
                }
                Capsule().fill(colour(Palette.NS.ink))
                    .frame(width: 0.24 * page.width, height: 0.11 * page.height)
                    .offset(x: page.minX + 0.09 * page.width, y: page.minY + 0.75 * page.height)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func colour(_ role: NSColor) -> Color { Palette.sample(role, tone: tone, dark: dark) }

    private func bar(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ fill: Color, radius: CGFloat = 1.5) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(fill)
            .frame(width: width, height: height)
            .offset(x: x, y: y)
    }
}

/// The lower right half of a rectangle, cut from its top right corner to
/// its bottom left: where the dark look goes in a System sample.
private struct Diagonal: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
