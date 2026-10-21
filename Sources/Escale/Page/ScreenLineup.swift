// Screens' lineup (Screens.swift): every layout of the page side by side, at
// the first width of each, drawn at one scale so a phone's picture is
// narrower than a desktop's by as much as the widths differ. A picture takes
// the page back to that width, live.
//
// The pictures come from the one web view the tab already has: behind the
// sheet, the page is laid out at each width in turn, given two frames to
// draw, and photographed (`takeSnapshot`) at the size it is shown; then it
// goes back to the width it was at. No second page, process or timer; the
// pictures go when the sheet closes. The page sees each width, as it would
// if someone dragged the window there, and is told its own once more after.
import SwiftUI
import WebKit

@MainActor
final class Lineup: ObservableObject {
    struct Shot: Identifiable {
        let width: Int
        var picture: NSImage?
        var id: Int { width }
    }

    @Published fileprivate(set) var shots: [Shot]
    /// Every picture's height, in CSS pixels: the live page's.
    let height: Int
    /// The pictures' height on screen, in points, set by the sheet that
    /// shows them: taken at the size they are shown.
    fileprivate var tall: CGFloat = 0
    static let limit = 8

    init(widths: [Int], height: Int) {
        shots = widths.map { Shot(width: $0) }
        self.height = height
    }

    /// The smallest phone, then the first width of each layout after it; a
    /// page whose breakpoints can't be read gets the usual ones.
    static func widths(_ edges: [Int]) -> [Int] {
        let smallest = Screen.devices[0].width
        guard !edges.isEmpty else { return [smallest, 768, 1024, 1440] }
        let firsts = edges.filter { $0 > smallest && Screen.widths.contains($0) }
        return Array(([smallest] + firsts).prefix(limit))
    }

    /// The pictures' height that fits the whole row in `room`, `gap` between
    /// and around them and `caption` under them; never below `least`, where
    /// the row scrolls instead.
    static func pictureHeight(widths: [Int], height: Int, room: CGSize, gap: CGFloat, caption: CGFloat, least: CGFloat) -> CGFloat {
        guard !widths.isEmpty, height > 0 else { return least }
        let across = (room.width - gap * CGFloat(widths.count + 1)) / CGFloat(widths.reduce(0, +)) * CGFloat(height)
        let down = room.height - 2 * gap - caption
        return max(least, min(across, down)).rounded(.down)
    }
}

extension Screen {
    /// The lineup, or the live page again.
    func line() {
        if lineup != nil { lineup = nil; return }
        guard on, let web = tab?.built, fitted.room.height > 0 else { return }
        let taken = Lineup(widths: Lineup.widths(edges), height: height ?? fitted.free)
        lineup = taken
        Task { await shoot(taken, in: web) }
    }

    private static let drawn = "await new Promise(r => { requestAnimationFrame(() => requestAnimationFrame(r)); setTimeout(r, 250); })"

    private func shoot(_ taken: Lineup, in web: WKWebView) async {
        shooting = true
        defer {
            shooting = false
            posing = nil
            apply()
            later()
        }
        let room = fitted.room
        let pixel = 1 / (web.window?.backingScaleFactor ?? 2)
        let height = CGFloat(taken.height)
        // The sheet says how tall it shows the pictures once it is laid out.
        for _ in 0..<30 where taken.tall == 0 { try? await Task.sleep(nanoseconds: 16_000_000) }
        for index in taken.shots.indices {
            guard on, lineup === taken else { return }
            let width = CGFloat(taken.shots[index].width)
            // The page's frame at this width, under the sheet, so the page
            // reads it as the live page does (Screened).
            let wide = max(pixel, (width * min(room.width / width, room.height / height) / pixel).rounded() * pixel)
            let scale = wide / width * (1 - 1e-6)
            posing = CGSize(width: wide, height: (height * scale / pixel).rounded(.up) * pixel)
            Self.lay(web, out: Self.fixed, size: CGSize(width: width, height: height))
            Self.set(web, "_setViewScale:", scale)
            for _ in 0..<30 where abs(web.frame.width - wide) > 0.5 {
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            // Laid out and drawn: two frames of the page's own, or a moment
            // when it draws none, hidden behind another window.
            _ = try? await web.callAsyncJavaScript(Self.drawn, contentWorld: .defaultClient)
            guard on, lineup === taken else { return }
            let shot = WKSnapshotConfiguration()
            shot.rect = CGRect(origin: .zero, size: web.bounds.size)
            shot.snapshotWidth = NSNumber(value: Double(width * max(taken.tall, 40) / height))
            // Drawn already: waiting for the screen would wait for ever on a
            // window nobody sees.
            shot.afterScreenUpdates = false
            taken.shots[index].picture = try? await web.takeSnapshot(configuration: shot)
        }
    }
}

/// The lineup in the page's place: its pictures in a row on the page's
/// ground, scrolling sideways when they are wider than the room.
struct LineupSheet: View {
    @ObservedObject var screen: Screen
    @ObservedObject var lineup: Lineup
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        GeometryReader { area in
            let gap = metrics.length(Metrics.lineupGap)
            let tall = Lineup.pictureHeight(widths: lineup.shots.map(\.width), height: lineup.height, room: area.size, gap: gap,
                                            caption: metrics.length(Metrics.screenBar + 4), least: metrics.length(Metrics.lineupLeast))
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: gap) {
                    ForEach(lineup.shots) { shot in
                        ShotCard(shot: shot, size: CGSize(width: CGFloat(shot.width) * tall / CGFloat(lineup.height), height: tall),
                                 range: Screen.range(of: shot.width, in: screen.edges) ?? "",
                                 live: Screen.range(of: shot.width, in: screen.edges) == Screen.range(of: screen.width, in: screen.edges)) {
                            screen.resize(shot.width)
                            screen.lineup = nil
                        }
                    }
                }
                .padding(gap)
                .frame(minWidth: area.size.width, minHeight: area.size.height)
            }
            .scrollIndicators(.automatic)
            .onChange(of: tall, initial: true) { _, next in lineup.tall = next }
        }
        .background(Palette.ground)
        .clipShape(RoundedRectangle(cornerRadius: metrics.pageRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Every layout")
    }
}

/// One layout: its picture, its width and range. The one the live page is
/// in wears the chosen surface under its caption.
private struct ShotCard: View {
    let shot: Lineup.Shot
    let size: CGSize
    let range: String
    let live: Bool
    let act: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @State private var hovering = false

    var body: some View {
        let frame = RoundedRectangle(cornerRadius: metrics.length(6), style: .continuous)
        Button(action: act) {
            VStack(alignment: .leading, spacing: metrics.length(8)) {
                Group {
                    if let picture = shot.picture {
                        Image(nsImage: picture).resizable()
                    } else {
                        Palette.wash
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(frame)
                .overlay(frame.strokeBorder(hovering ? Palette.ink.opacity(0.35) : Palette.edge, lineWidth: 1))
                HStack(spacing: metrics.length(6)) {
                    Text(verbatim: "\(shot.width)")
                        .font(.system(size: metrics.length(Metrics.screenText), weight: .medium).monospacedDigit())
                        .foregroundStyle(Palette.ink)
                    Text(verbatim: range)
                        .font(.system(size: metrics.length(Metrics.screenText)).monospacedDigit())
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                .padding(.horizontal, metrics.length(7))
                .frame(height: metrics.length(Metrics.screenBar - 4))
                .background { if live { Chosen(shape: Capsule(style: .continuous)) } }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help("Go to \(shot.width)")
        .accessibilityLabel("\(shot.width) pixels, \(range)")
    }
}
