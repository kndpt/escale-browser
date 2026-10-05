import SwiftUI

// What the update's door opens, and what the first launch of a new build
// shows: one plate (Plate.swift), the one History and Downloads use, so an
// update reads as part of the browser rather than a system alert.
//
// Across its top, a boarding pass: from this version to the next, the route
// drawn between them, the app's icon on the stub. Escale is a stopover, and
// an update is the one trip the browser itself takes, so the pass says in a
// glance what the words then say in full. It is drawn, not an image: the
// palette's roles in both themes and at every interface size, and nothing to
// ship. Boarding leaves the plane at the gate; arrival flies it in once and
// lands it, with no loop, and not at all with Reduce Motion.
//
// Beneath the pass, the release's summary: the first paragraph of NOTES.md,
// from the appcast before the relaunch and from the bundle after it.

struct GatePanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var updater = Updater.shared
    let gate: Gate
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    /// The gate and the updater's stage, read together.
    private enum Kind {
        case fetching(Updater.Release)
        case ready(Updater.Release)
        case offered(Updater.Release)
        case arrived(Arrival)
    }

    private var kind: Kind? {
        switch gate {
        case .arrived(let arrival): return .arrived(arrival)
        case .boarding:
            switch updater.stage {
            case .fetching(let release): return .fetching(release)
            case .ready(let release): return .ready(release)
            case .offered(let release): return .offered(release)
            case .none: return nil
            }
        }
    }

    var body: some View {
        Group {
            if let kind { plate(kind) }
        }
        // A build that goes away takes its panel with it; one that lands
        // turns the same panel from its download to its relaunch.
        .onChange(of: updater.stage) { _, stage in
            if gate == .boarding, stage.shown == nil { close() }
        }
    }

    private func plate(_ kind: Kind) -> some View {
        Plate(title(kind), width: Metrics.gateWidth, close: close) {
            VStack(alignment: .leading, spacing: metrics.length(Metrics.gateGap)) {
                pass(kind)
                VStack(alignment: .leading, spacing: metrics.length(8)) {
                    Text(headline(kind))
                        .font(.system(size: metrics.length(Metrics.gateHeadline), weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    summary(notes(kind))
                }
                if case .fetching = kind { progress }
                HStack(alignment: .firstTextBaseline, spacing: metrics.length(7)) {
                    Image(systemName: symbol(kind))
                        .font(.system(size: metrics.length(11), weight: .medium))
                    Text(reassurance(kind))
                        .font(.system(size: metrics.length(11.5)))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Palette.muted)
            }
        } foot: {
            HStack(spacing: metrics.length(8)) {
                Button(primaryTitle(kind)) { primary(kind) }
                    .buttonStyle(MigrationButton(kind: .primary))
                    .disabled({ if case .fetching = kind { return true } else { return false } }())
                if case .arrived = kind {} else {
                    Button("Later", action: close)
                        .buttonStyle(MigrationButton(kind: .quiet))
                }
                Spacer(minLength: 0)
                if let url = Links.release(version(kind)) {
                    Button {
                        close()
                        browser.open(url, foreground: true)
                    } label: {
                        HStack(spacing: metrics.length(4)) {
                            Text("What changed")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: metrics.length(9), weight: .medium))
                        }
                    }
                    .buttonStyle(MigrationButton(kind: .quiet))
                    .help("The full list, on the release page")
                }
            }
        }
    }

    // MARK: - what it says

    private func title(_ kind: Kind) -> String {
        if case .arrived = kind { return "What's new" }
        return "Update"
    }

    private func version(_ kind: Kind) -> String {
        switch kind {
        case .fetching(let release), .ready(let release), .offered(let release): return release.version
        case .arrived(let arrival): return arrival.version
        }
    }

    private func headline(_ kind: Kind) -> String {
        switch kind {
        case .fetching(let release): return "Escale \(release.version) is on its way."
        case .ready(let release): return "Escale \(release.version) is at the gate."
        case .offered(let release): return "Escale \(release.version) is out."
        case .arrived(let arrival): return "Escale \(arrival.version) has landed."
        }
    }

    private func notes(_ kind: Kind) -> String {
        switch kind {
        case .fetching(let release): return release.notes ?? "A new version is downloading."
        case .ready(let release): return release.notes ?? "Downloaded, checked and in place, ready for the next launch."
        case .offered(let release): return release.notes ?? "A new version is ready to download."
        case .arrived(let arrival): return arrival.notes
        }
    }

    private func symbol(_ kind: Kind) -> String {
        switch kind {
        case .fetching: return "clock"
        case .ready: return "arrow.clockwise"
        case .offered: return "externaldrive"
        case .arrived: return "suitcase"
        }
    }

    private func reassurance(_ kind: Kind) -> String {
        switch kind {
        case .fetching:
            return "It downloads and checks itself in the background, without stopping anything you are doing. Once it is in place, it is one relaunch away."
        case .ready:
            return "Relaunching takes a moment and brings back your tabs, Spaces and passwords. Or it waits for the next time you open Escale."
        case .offered:
            return "This copy can't update itself where it is, so the new one comes as a disk image. Your tabs, Spaces and passwords stay as they are."
        case .arrived:
            return "Your tabs, Spaces and passwords came along."
        }
    }

    private func primaryTitle(_ kind: Kind) -> String {
        switch kind {
        case .fetching, .ready: return "Relaunch now"
        case .offered(let release): return "Download \(release.version)"
        case .arrived: return "Carry on"
        }
    }

    private func primary(_ kind: Kind) {
        switch kind {
        case .fetching:
            break
        case .ready:
            updater.relaunch()
        case .offered(let release):
            close()
            browser.open(release.dmg, foreground: true)
        case .arrived:
            close()
        }
    }

    private func close() { browser.gate = nil }

    // MARK: - how it looks

    private func pass(_ kind: Kind) -> some View {
        switch kind {
        case .fetching(let release):
            return BoardingPass(label: "BOARDING", from: Updater.version, fromNote: "This copy",
                                to: release.version, toNote: "Downloading", landed: false)
        case .ready(let release):
            return BoardingPass(label: "BOARDING", from: Updater.version, fromNote: "This copy",
                                to: release.version, toNote: "Ready", landed: false)
        case .offered(let release):
            return BoardingPass(label: "BOARDING", from: Updater.version, fromNote: "This copy",
                                to: release.version, toNote: "Disk image", landed: false)
        case .arrived(let arrival):
            return BoardingPass(label: "ARRIVED", from: arrival.from ?? "—", fromNote: "Departed",
                                to: arrival.version, toNote: "Arrived", landed: true)
        }
    }

    /// How far the download is, from the updater's own count: a bar and its
    /// percent, or only the word until the first percent has arrived.
    private var progress: some View {
        VStack(alignment: .leading, spacing: metrics.length(6)) {
            MigrationBar(fraction: updater.fraction ?? 0)
            Text(updater.fraction.map { "Downloading · \(Int(($0 * 100).rounded()))%" } ?? "Downloading…")
                .font(.system(size: metrics.length(11.5)))
                .monospacedDigit()
                .foregroundStyle(Palette.muted)
        }
    }

    /// A long summary scrolls within the plate rather than pushing its foot
    /// out of a small window.
    private func summary(_ text: String) -> some View {
        let words = Text(text)
            .font(.system(size: metrics.length(Metrics.gateBody)))
            .foregroundStyle(Palette.ink)
            .lineSpacing(metrics.length(3))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        return ViewThatFits(in: .vertical) {
            words
            ScrollView(showsIndicators: false) { words }
                .frame(maxHeight: metrics.length(Metrics.gateNotesHeight))
        }
    }
}

/// From one version to the next, on a pass with a torn-off stub.
private struct BoardingPass: View {
    let label: String
    let from: String
    let fromNote: String
    let to: String
    let toNote: String
    /// Arrival: the plane flies in and lands. Boarding: it waits at the gate.
    let landed: Bool
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flown = 0.0

    /// Where the plane waits before boarding, and where arrival picks it up.
    private static let gate = 0.16
    private static let approach = 0.55

    var body: some View {
        let notch = metrics.length(Metrics.gatePassNotch)
        let stub = metrics.length(Metrics.gatePassStub)
        let shape = PassShape(radius: metrics.cardRadius, notch: notch, tear: stub)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: metrics.length(10)) {
                HStack {
                    Text("ESCALE").kerning(metrics.length(2))
                    Spacer(minLength: 0)
                    Text(label).kerning(metrics.length(1.4))
                }
                .font(.system(size: metrics.length(Metrics.gateLabel), weight: .semibold))
                .foregroundStyle(Palette.muted)
                HStack(alignment: .center, spacing: metrics.length(12)) {
                    end("FROM", from, fromNote, alignment: .leading)
                    Route(progress: flown, landed: landed)
                        .frame(height: metrics.length(Metrics.gateRoute))
                    end("TO", to, toNote, alignment: .trailing)
                }
            }
            .padding(metrics.length(Metrics.gatePassInset))
            .frame(maxWidth: .infinity)

            Tear()
                .stroke(Palette.edge, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: 1)
                .padding(.vertical, notch + metrics.length(3))

            VStack(spacing: metrics.length(6)) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: metrics.length(Metrics.gateIcon), height: metrics.length(Metrics.gateIcon))
                Text("N° \(to)")
                    .font(.system(size: metrics.length(Metrics.gateLabel), weight: .semibold))
                    .kerning(metrics.length(0.6))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            .frame(width: max(0, stub - 1))
        }
        // As tall as its words: the tear is a shape, and would take any height.
        .fixedSize(horizontal: false, vertical: true)
        .background(shape.fill(Palette.raised))
        .overlay(shape.stroke(Palette.hairline, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(landed ? "Arrived at Escale \(to)" : "From Escale \(from) to \(to)")
        .onAppear {
            guard landed else {
                flown = Self.gate
                return
            }
            guard !reduceMotion else {
                flown = 1
                return
            }
            flown = Self.approach
            withAnimation(Motion.gateFlight.delay(Motion.gateFlightDelay)) { flown = 1 }
        }
    }

    private func end(_ caption: String, _ value: String, _ note: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: metrics.length(3)) {
            Text(caption)
                .font(.system(size: metrics.length(Metrics.gateLabel), weight: .semibold))
                .kerning(metrics.length(1.4))
                .foregroundStyle(Palette.muted)
            Text(value)
                .font(.system(size: metrics.length(Metrics.gateVersion), weight: .light))
                .monospacedDigit()
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Text(note)
                .font(.system(size: metrics.length(11)))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
        }
        .fixedSize()
    }
}

/// The route between the two versions: a dashed arc, the part flown drawn
/// solid, and the plane along it, nose on the curve until it levels to land.
private struct Route: View, Animatable {
    var progress: Double
    let landed: Bool
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        GeometryReader { area in
            let size = area.size
            let start = CGPoint(x: 0, y: size.height * 0.78)
            let finish = CGPoint(x: size.width, y: size.height * 0.78)
            let control = CGPoint(x: size.width / 2, y: -size.height * 0.3)
            let arc = Path { path in
                path.move(to: start)
                path.addQuadCurve(to: finish, control: control)
            }
            let t = min(max(progress, 0), 1)
            let dot = metrics.length(5)
            ZStack(alignment: .topLeading) {
                arc.stroke(Palette.edge, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [2, 4]))
                arc.trimmedPath(from: 0, to: t)
                    .stroke(Palette.muted, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                Circle().fill(Palette.muted)
                    .frame(width: dot, height: dot)
                    .position(start)
                Circle()
                    .fill(landed && t >= 1 ? Palette.ink : Palette.raised)
                    .overlay(Circle().stroke(Palette.muted, lineWidth: 1))
                    .frame(width: dot, height: dot)
                    .position(finish)
                Image(systemName: "airplane")
                    .font(.system(size: metrics.length(Metrics.gatePlane), weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .rotationEffect(heading(t, start: start, control: control, finish: finish))
                    .position(point(t, start: start, control: control, finish: finish))
            }
        }
    }

    private func point(_ t: Double, start: CGPoint, control: CGPoint, finish: CGPoint) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * start.x + 2 * u * t * control.x + t * t * finish.x,
            y: u * u * start.y + 2 * u * t * control.y + t * t * finish.y
        )
    }

    /// Along the curve, levelling over the last stretch of an arrival.
    private func heading(_ t: Double, start: CGPoint, control: CGPoint, finish: CGPoint) -> Angle {
        let dx = 2 * (1 - t) * (control.x - start.x) + 2 * t * (finish.x - control.x)
        let dy = 2 * (1 - t) * (control.y - start.y) + 2 * t * (finish.y - control.y)
        let along = atan2(dy, dx)
        let level = landed ? min(max((1 - t) / (1 - 0.55), 0), 1) : 1
        return .radians(along * level)
    }
}

/// A pass: a rounded card with a bite out of each edge where the stub tears.
private struct PassShape: Shape {
    let radius: CGFloat
    let notch: CGFloat
    /// The stub's width, from the right edge to the tear.
    let tear: CGFloat

    func path(in rect: CGRect) -> Path {
        let card = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
        let x = rect.maxX - tear
        var bites = Path()
        bites.addEllipse(in: CGRect(x: x - notch, y: rect.minY - notch, width: notch * 2, height: notch * 2))
        bites.addEllipse(in: CGRect(x: x - notch, y: rect.maxY - notch, width: notch * 2, height: notch * 2))
        return card.subtracting(bites)
    }
}

/// The tear between the pass and its stub.
private struct Tear: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
    }
}
