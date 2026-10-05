// A new download sends a plane off the visible page to its door: Escale is a
// stopover, and the plane is the mark's own gesture. Anchors come from the
// laid-out page and door, so the same curve works with either tab layout and
// every chrome size. The plane's nose follows the curve, and it is mirrored
// rather than turned upside down when the door lies to the left. Only one
// flight can exist at once; there is no display link, particle trail or work
// between download starts.
import SwiftUI

struct DownloadFlightFrames: PreferenceKey {
    var page: Anchor<CGRect>?
    var door: Anchor<CGRect>?

    static var defaultValue = DownloadFlightFrames()

    static func reduce(value: inout DownloadFlightFrames, nextValue: () -> DownloadFlightFrames) {
        let next = nextValue()
        value.page = next.page ?? value.page
        value.door = next.door ?? value.door
    }
}

struct DownloadFlight: View {
    @ObservedObject var downloads: Downloads
    let page: CGRect?
    let door: CGRect?
    let enabled: Bool
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @State private var seen: Set<ObjectIdentifier> = []
    @State private var pending: Date?
    @State private var flight: Flight?

    fileprivate struct Flight: Identifiable {
        let id = UUID()
        let start: CGPoint
        let end: CGPoint
    }

    private var ready: Bool { page != nil && door != nil && enabled }

    var body: some View {
        GeometryReader { _ in
            if let flight, enabled, !reduceMotion {
                FileInFlight(flight: flight,
                             size: metrics.length(Metrics.downloadFlightSize),
                             rise: metrics.length(Metrics.downloadFlightRise)) {
                    if self.flight?.id == flight.id { self.flight = nil; arrive() }
                }
                .id(flight.id)
            }
        }
        .onChange(of: downloads.transfers.map(\.id)) { _, ids in
            let current = Set(ids)
            if !current.subtracting(seen).isEmpty { pending = Date() }
            seen = current
            if current.isEmpty { pending = nil }
            arrive()
        }
        .onChange(of: ready) { _, _ in arrive() }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { flight = nil; pending = nil }
        }
        .onChange(of: enabled) { _, allowed in
            if !allowed { flight = nil; pending = nil }
        }
    }

    private func arrive() {
        guard let pending, Date().timeIntervalSince(pending) < Motion.downloadFlightFreshness,
              ready, !reduceMotion, flight == nil,
              let page, let door else { return }
        self.pending = nil
        flight = Flight(start: CGPoint(x: page.midX, y: page.midY),
                        end: CGPoint(x: door.midX, y: door.midY))
    }
}

private struct FileInFlight: View {
    let flight: DownloadFlight.Flight
    let size: CGFloat
    let rise: CGFloat
    let finished: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @State private var progress: CGFloat = 0

    private var path: FlightPath { FlightPath(start: flight.start, end: flight.end, rise: rise) }

    var body: some View {
        Image(systemName: "airplane")
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(Palette.ink)
            .modifier(FlightHeading(path: path, progress: progress))
            .frame(width: size, height: size)
            .background(Palette.ground, in: Circle())
            .overlay { Circle().stroke(Palette.edge, lineWidth: metrics.length(Metrics.downloadFlightEdge)) }
            .shadow(color: Palette.shadow,
                    radius: metrics.length(Metrics.downloadFlightShadow),
                    y: metrics.length(Metrics.downloadFlightShadowY))
            .scaleEffect(1 - progress * 0.45)
            .opacity(1 - max(0, progress - 0.88) / 0.12)
            .modifier(FlightCurve(path: path, progress: progress))
            .task {
                do {
                    // Give SwiftUI one frame at the page centre before moving.
                    try await Task.sleep(nanoseconds: Motion.downloadFlightStartNanoseconds)
                    withAnimation(Motion.downloadFlight) { progress = 1 }
                    try await Task.sleep(nanoseconds: Motion.downloadFlightNanoseconds)
                }
                catch { return }
                finished()
            }
    }
}

/// The cubic Bézier the plane follows: it climbs first, then comes down onto
/// the door. Both the position and the heading are read off the same curve.
private struct FlightPath {
    let start: CGPoint
    let end: CGPoint
    let rise: CGFloat

    private var controls: (CGPoint, CGPoint) {
        let dx = end.x - start.x
        let lift = max(rise * 0.42, min(rise, start.y - end.y))
        return (CGPoint(x: start.x + dx * 0.22, y: start.y - lift),
                CGPoint(x: end.x - dx * 0.24, y: end.y + lift * 0.55))
    }

    func point(_ t: CGFloat) -> CGPoint {
        let (first, last) = controls
        let u = 1 - t
        return CGPoint(
            x: u * u * u * start.x + 3 * u * u * t * first.x + 3 * u * t * t * last.x + t * t * t * end.x,
            y: u * u * u * start.y + 3 * u * u * t * first.y + 3 * u * t * t * last.y + t * t * t * end.y)
    }

    /// The curve's direction at `t`, with the x axis towards the door so the
    /// plane never flies backwards.
    func heading(_ t: CGFloat) -> CGFloat {
        let (first, last) = controls
        let u = 1 - t
        let dx = 3 * u * u * (first.x - start.x) + 6 * u * t * (last.x - first.x) + 3 * t * t * (end.x - last.x)
        let dy = 3 * u * u * (first.y - start.y) + 6 * u * t * (last.y - first.y) + 3 * t * t * (end.y - last.y)
        return atan2(dy, mirrored ? -dx : dx)
    }

    /// The symbol points right; a door on the left gets it mirrored.
    var mirrored: Bool { end.x < start.x }
}

/// Animatable geometry keeps the intermediate frames on a real curved path.
private struct FlightCurve: GeometryEffect {
    let path: FlightPath
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let p = path.point(progress)
        return ProjectionTransform(CGAffineTransform(translationX: p.x - size.width / 2,
                                                      y: p.y - size.height / 2))
    }
}

/// Turns the plane about its own centre as `progress` runs, so its nose
/// follows the curve at every frame rather than only at the two ends.
private struct FlightHeading: GeometryEffect {
    let path: FlightPath
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let flip: CGFloat = path.mirrored ? -1 : 1
        var turn = CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
        turn = turn.scaledBy(x: flip, y: 1).rotated(by: path.heading(progress))
        turn = turn.translatedBy(x: -size.width / 2, y: -size.height / 2)
        return ProjectionTransform(turn)
    }
}
