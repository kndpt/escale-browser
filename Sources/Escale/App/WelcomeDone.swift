// Welcome's last step says what is now set up: the look, links, what came
// along from another browser and GitHub, each where it can change. Every path
// ends here, connected or local, so setup always closes on the same page and
// with one button, rather than on a GitHub tab or a skip.
//
// The arrival is marked once: the mark's dots light up from the capsule to the
// next stop, the stopover the name is, the rows follow one after another and
// their ticks land as the mark does.
// Nothing moves at rest, and with Reduce Motion everything is simply there.
import SwiftUI

struct WelcomeDone: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var access: GitHubAccess
    let imported: Bool
    let isDefault: Bool
    /// The Search GitHub shortcut as bound now.
    let stroke: KeyStroke?
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    private struct Row {
        let symbol: Image
        let title: String
        let detail: String
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.length(Metrics.arrivalChoiceRadius), style: .continuous)
        let rows = self.rows
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                if index > 0 {
                    Divider().overlay(Palette.hairline)
                        .padding(.leading, metrics.length(Metrics.arrivalCardInset + Metrics.arrivalFeature + Metrics.arrivalDetailGap))
                }
                row(rows[index], ticked: shown, delay: 0.75 + Motion.landingRow * Double(index))
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown || reduceMotion ? 0 : metrics.length(Metrics.arrivalRowGap))
                    .animation(reduceMotion ? nil : Motion.arrival.delay(0.2 + Motion.landingRow * Double(index)), value: shown)
            }
        }
        .background(Palette.wash, in: shape)
        .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1))
        .onAppear { shown = true }
    }

    private var rows: [Row] {
        let search = stroke.map { " · \($0.label) to search" } ?? ""
        let github: String
        if case .connected(let account) = access.connection {
            github = "Connected as \(account.login)" + search
        } else {
            github = "Found from what you visit" + search + (access.canConnect ? ". Connect in Settings → GitHub." : "")
        }
        return [
            Row(symbol: Image(systemName: prefs.look.symbol), title: "Appearance",
                detail: "\(prefs.look.title), tabs \(prefs.sidebar ? "in the sidebar" : "along the top")"),
            Row(symbol: Image(systemName: "link"), title: "Links",
                detail: isDefault ? "Links from other apps open in Escale" : "Your other browser still opens links. Settings can change it."),
            Row(symbol: Image(systemName: "tray.and.arrow.down"), title: "Your browsing",
                detail: imported ? "Brought into this Space" : "A fresh start. Import any time in Settings → Import Data."),
            Row(symbol: GitHubMark.glyph ?? Image(systemName: "arrow.triangle.pull"), title: "Pull requests", detail: github),
        ]
    }

    /// A row, its tick landing a moment after it once the mark has.
    private func row(_ row: Row, ticked: Bool, delay: TimeInterval) -> some View {
        HStack(spacing: metrics.length(Metrics.arrivalDetailGap)) {
            row.symbol
                .resizable()
                .scaledToFit()
                .frame(width: metrics.length(Metrics.arrivalText), height: metrics.length(Metrics.arrivalText))
                .frame(width: metrics.length(Metrics.arrivalFeature), height: metrics.length(Metrics.arrivalFeature))
                .background(Palette.raised, in: RoundedRectangle(cornerRadius: metrics.length(Metrics.arrivalButtonRadius), style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: metrics.length(Metrics.arrivalLine)) {
                Text(row.title)
                ArrivalNote(text: row.detail)
            }
            Spacer(minLength: metrics.length(Metrics.arrivalDetailGap))
            Image(systemName: "checkmark")
                .font(.system(size: metrics.length(Metrics.arrivalSmall), weight: .semibold))
                .foregroundStyle(Palette.muted)
                .scaleEffect(ticked || reduceMotion ? 1 : 0.4)
                .opacity(ticked ? 1 : 0)
                .animation(reduceMotion ? nil : Motion.settle.delay(delay), value: ticked)
                .accessibilityHidden(true)
        }
        .padding(metrics.length(Metrics.arrivalCardInset))
        .accessibilityElement(children: .combine)
    }
}

/// The mark as it lands: the capsule first, then each dot, then the next stop,
/// in ink over its own faint outline. Played once when it appears.
struct LandingMark: View {
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            Logomark().fill(Palette.faint, style: FillStyle(eoFill: true))
            Landing(progress: reduceMotion ? 1 : progress).fill(Palette.ink, style: FillStyle(eoFill: true))
        }
        .onAppear { withAnimation(Motion.landing) { progress = 1 } }
    }
}

/// The mark's parts drawn up to `progress`: each dot, then the stop, grows
/// from its own centre in turn.
private struct Landing: Shape {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        // Logomark's subpaths, in its order: capsule, next stop, five dots.
        var parts: [Path] = []
        Logomark().path(in: rect).forEach { element in
            if case .move(let to) = element { parts.append(Path()); parts[parts.count - 1].move(to: to); return }
            guard !parts.isEmpty else { return }
            switch element {
            case .line(let to): parts[parts.count - 1].addLine(to: to)
            case .quadCurve(let to, let control): parts[parts.count - 1].addQuadCurve(to: to, control: control)
            case .curve(let to, let one, let two): parts[parts.count - 1].addCurve(to: to, control1: one, control2: two)
            case .closeSubpath: parts[parts.count - 1].closeSubpath()
            case .move: break
            }
        }
        guard parts.count == 7 else { return Logomark().path(in: rect) }
        var path = parts[0]
        let journey = Array(parts[2...]) + [parts[1]]
        for (index, part) in journey.enumerated() {
            let grown = min(max(progress * CGFloat(journey.count) - CGFloat(index), 0), 1)
            guard grown > 0 else { continue }
            let centre = CGPoint(x: part.boundingRect.midX, y: part.boundingRect.midY)
            path.addPath(part.applying(CGAffineTransform(translationX: centre.x, y: centre.y)
                .scaledBy(x: grown, y: grown)
                .translatedBy(x: -centre.x, y: -centre.y)))
        }
        return path
    }
}
