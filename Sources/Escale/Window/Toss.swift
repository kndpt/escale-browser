import SwiftUI

// Clear, pressed at the Tabs heading (Shelf.swift), makes a small show of
// it. The rows lift off as cards and gather in a loose pile; the bin comes
// forward, grows and opens its lid; the cards are tossed in one after another
// and the bin rocks as each lands; the lid claps shut, a flash goes round it,
// and the bin goes back to its place and its size. Under a second and a half.
//
// The tabs are closed at the press, at once and without the rows' own fade
// (Browser.clearTabs is unchanged, and ⌘⇧T still brings them back): what
// flies is a copy of each row drawn where it was, so the show never holds the
// browser up and has nothing to undo. Every piece is read off one clock in a
// TimelineView that exists only while the show runs. The rows' places come
// from the column's own sums (SideBar.clear), the bin's from the heading, and
// the bin is the heading's own glyph cut in two at the lid. The glyph is drawn
// at its biggest and scaled down, so it stays sharp while it grows. Reduce
// Motion closes the tabs as before, with no show.

struct Toss: Identifiable {
    /// A row, as it was when Clear was pressed.
    struct Card {
        let frame: CGRect
        let icon: NSImage?
        let letter: String
        let title: String
        let mark: Bool
        let live: Bool
    }

    let id = UUID()
    let start = Date()
    let cards: [Card]
    /// The heading's bin glyph, in window points.
    let bin: CGRect
    /// The flash's colour: the Space's own, or ink.
    let tint: Color
}

struct TossStage: View {
    let toss: Toss
    let finished: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        GeometryReader { proxy in
            let course = Course(toss, in: proxy.frame(in: .global), row: metrics.length(28))
            TimelineView(.animation) { context in
                TossFrame(toss: toss, course: course, t: context.date.timeIntervalSince(toss.start))
            }
            .task(id: toss.id) {
                let left = course.end - Date().timeIntervalSince(toss.start)
                try? await Task.sleep(nanoseconds: UInt64(max(0, left) * 1_000_000_000))
                if !Task.isCancelled { finished() }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The show's proportions; its timings are in `Motion` (`toss…`).
private enum Beat {
    /// The bin grows to this, the size it is drawn at.
    static let peak: CGFloat = 2.6
    /// Where the lid ends on the glyph, as a share of its box.
    static let lid: CGFloat = 0.34
    /// More cards than this and the rest are taken as read.
    static let most = 16
}

/// Where everything goes, worked out once from the press: points are the
/// stage's own, times are from the press.
private struct Course {
    var cards: [(card: Toss.Card, from: CGRect)] = []
    let home: CGPoint
    let stage: CGPoint
    let pile: CGPoint
    let mouth: CGPoint
    let rise: CGFloat
    let side: CGFloat
    var throwsAt: [Double] = []
    let landings: [Double]
    let shut: Double
    let clap: Double
    let back: Double
    let end: Double

    init(_ toss: Toss, in frame: CGRect, row: CGFloat) {
        let bounds = CGRect(origin: .zero, size: frame.size)
        let shown = toss.cards
            .map { (card: $0, from: $0.frame.offsetBy(dx: -frame.minX, dy: -frame.minY)) }
            .filter { $0.from.intersects(bounds) }
        cards = Array(shown.prefix(Beat.most))
        side = toss.bin.width
        home = CGPoint(x: toss.bin.midX - frame.minX, y: toss.bin.midY - frame.minY)
        let width = cards.first?.from.width ?? frame.width
        let middle = cards.first?.from.midX ?? frame.width / 2
        // In from the edge and a little down, over the pile that gathers
        // under it: the cards go up and over, and drop in from above.
        stage = CGPoint(x: home.x - width * 0.16, y: home.y + row * 0.2)
        pile = CGPoint(x: middle - width * 0.04, y: home.y + row * 2.1)
        mouth = CGPoint(x: stage.x, y: stage.y - side * Beat.peak * 0.22)
        rise = row * 2.6
        // The last card to land on the pile goes first.
        let count = cards.count
        let gap = count > 1 ? min(Motion.tossThrowGap, Motion.tossThrows / Double(count - 1)) : 0
        throwsAt = (0..<count).map { Motion.tossThrowAt + Double(count - 1 - $0) * gap }
        landings = throwsAt.map { $0 + Motion.tossFlight }.sorted()
        shut = (landings.last ?? Motion.tossThrowAt) + Motion.tossShutAfter
        clap = shut + Motion.tossClapAfter
        back = clap + Motion.tossHomeAfter
        end = back + Motion.tossHome + Motion.tossTail
    }
}

private struct TossFrame: View {
    let toss: Toss
    let course: Course
    let t: Double
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        ZStack {
            ForEach(course.cards.indices, id: \.self) { index in card(index) }
            if t > course.clap, t < course.clap + Motion.tossFlash { flash }
            bin
        }
    }

    // MARK: the cards

    @ViewBuilder
    private func card(_ index: Int) -> some View {
        let (card, from) = course.cards[index]
        let n = Double(index)
        let start = n * min(Motion.tossRippleGap, Motion.tossRipple / Double(course.cards.count))
        let lift = smooth((t - start) / Motion.tossLift)
        let gathered = overshoot((t - start) / Motion.tossGather, 1.3)
        // A loose pile: each card a little askew, the later ones on top.
        let rest = CGPoint(x: course.pile.x + CGFloat(sin(n * 2.3)) * 6,
                           y: course.pile.y - CGFloat(min(index, 6)) * 1.6)
        let tilt = sin(n * 1.7 + 0.5) * 7
        let flown = clamp((t - course.throwsAt[index]) / Motion.tossFlight)
        if flown < 1 {
            // A quadratic curve walked at an even pace is a thrown thing's arc.
            let control = CGPoint(x: (rest.x + course.mouth.x) / 2,
                                  y: min(rest.y, course.mouth.y) - course.rise)
            let centre = flown > 0 ? quad(rest, control, course.mouth, flown)
                                   : mix(CGPoint(x: from.midX, y: from.midY), rest, gathered)
            let spin = (index % 2 == 0 ? 1 : -1) * (90 + 30 * sin(n))
            // Small early in the flight, so a card reads as thrown, not swung.
            let shrink = 1 - pow(1 - flown, 2.4)
            TossCard(card: card, lift: lift)
                .frame(width: from.width, height: from.height)
                .scaleEffect(flown > 0 ? 0.84 - 0.74 * shrink : 1 - 0.16 * gathered)
                .rotationEffect(.degrees(tilt * min(gathered, 1) + spin * flown))
                .opacity(1 - clamp((flown - 0.78) / 0.22))
                .position(centre)
                .zIndex(n)
        }
    }

    // MARK: the bin

    private var bin: some View {
        // Grows and comes forward, then goes home with a little give.
        let out = overshoot((t - Motion.tossGrowAt) / Motion.tossGrow, 1.6)
        let home = overshoot((t - course.back) / Motion.tossHome, 1.2)
        let reach = out * (1 - home)
        // Each landing rocks it, one way then the other, and squashes it
        // onto its base for an instant.
        var rock = 0.0
        var squash = 0.0
        for (k, landed) in course.landings.enumerated() where t > landed {
            let d = t - landed
            rock += (k % 2 == 0 ? 1 : -1) * exp(-d * 9) * sin(d * 2 * .pi * 6)
            if d < Motion.tossHit { squash += sin(.pi * d / Motion.tossHit) }
        }
        squash = min(squash, 1)
        let pop = sin(.pi * clamp((t - course.clap) / Motion.tossPop))
        let open = smooth((t - Motion.tossLidAt) / Motion.tossLid) * (1 - overshoot((t - course.shut) / Motion.tossShut, 2.4))
        let size = 1 + (Beat.peak - 1) * reach
        return TossBin(side: course.side * Beat.peak, lid: 40 * open + 10 * squash,
                       ink: min(1, 0.7 + 0.3 * reach))
            .scaleEffect(x: 1 + 0.1 * squash, y: 1 - 0.14 * squash, anchor: .bottom)
            .rotationEffect(.degrees(max(-18, min(18, 14 * rock))), anchor: .bottom)
            .scaleEffect(size * (1 + 0.14 * pop) / Beat.peak)
            .opacity(1 - clamp((t - course.end + Motion.tossTail + Motion.tossFade) / Motion.tossFade))
            .position(mix(course.home, course.stage, reach))
    }

    // MARK: the flash

    private var flash: some View {
        let e = clamp((t - course.clap) / Motion.tossFlash)
        let spread = 1 - pow(1 - e, 3)
        let fade = 1 - e
        let reach = course.side * Beat.peak
        return ZStack {
            // A white light, added to what is under it: bright on the dark
            // column, gentle on the light one, where the sparks carry it.
            Circle()
                .fill(RadialGradient(colors: [Palette.flash, Palette.flash.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: reach))
                .frame(width: reach * 2, height: reach * 2)
                .scaleEffect(0.3 + spread)
                .opacity(fade * fade * 0.85)
                .blendMode(.plusLighter)
            Circle()
                .strokeBorder(toss.tint.opacity(fade * fade * 0.6), lineWidth: metrics.length(0.5 + 1.5 * fade))
                .frame(width: reach * (0.8 + 1.3 * spread), height: reach * (0.8 + 1.3 * spread))
            ForEach(0..<12, id: \.self) { j in
                let long = j % 2 == 0
                let length = metrics.length(long ? 8 : 3) * fade + metrics.length(1.5)
                Capsule()
                    .fill(toss.tint.opacity(long ? 1 : 0.7))
                    .frame(width: metrics.length(long ? 2 : 3), height: length)
                    .offset(y: -reach * (0.45 + (long ? 0.85 : 0.6) * spread))
                    .rotationEffect(.degrees(Double(j) * 30 + (long ? 0 : 8)))
                    .opacity(1 - e * e)
            }
        }
        .position(course.stage)
    }
}

/// A row in the air: the same mark and title as in the column, on a card
/// that comes up under it as it lifts.
private struct TossCard: View {
    let card: Toss.Card
    let lift: Double
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.length(9), style: .continuous)
        HStack(spacing: metrics.length(8)) {
            if card.mark { Mark(icon: card.icon, letter: card.letter, size: metrics.length(Metrics.navigationIcon)) }
            Text(card.title)
                .font(.system(size: metrics.length(12.5)))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(card.live ? Palette.ink : Palette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, metrics.length(10))
        .padding(.trailing, metrics.length(7))
        .background {
            if card.live {
                Chosen(radius: metrics.length(9))
            } else {
                shape.fill(Palette.selection).overlay(shape.strokeBorder(Palette.edge)).opacity(lift)
            }
        }
        .shadow(color: Palette.shadow.opacity(lift), radius: metrics.length(8), y: metrics.length(3))
    }
}

/// The heading's bin, its lid cut off along the glyph and hinged at the
/// lid's right end, so it opens towards the cards coming from the left.
private struct TossBin: View {
    let side: CGFloat
    let lid: Double
    let ink: Double
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        let glyph = Image(systemName: "trash")
            .font(.system(size: metrics.length(11) * Beat.peak, weight: .regular))
            .foregroundStyle(Palette.ink.opacity(ink))
            .frame(width: side, height: side)
        ZStack {
            glyph.mask(alignment: .top) { Rectangle().frame(height: side * Beat.lid) }
                .rotationEffect(.degrees(lid), anchor: UnitPoint(x: 0.84, y: Beat.lid))
            glyph.mask(alignment: .bottom) { Rectangle().frame(height: side * (1 - Beat.lid)) }
        }
        .frame(width: side, height: side)
    }
}

// MARK: - curves

private func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }

private func smooth(_ x: Double) -> Double {
    let x = clamp(x)
    return x * x * (3 - 2 * x)
}

/// Eases out past 1 and back: the larger `s`, the further past.
private func overshoot(_ x: Double, _ s: Double) -> Double {
    let x = clamp(x) - 1
    return 1 + (s + 1) * x * x * x + s * x * x
}

private func mix(_ a: CGPoint, _ b: CGPoint, _ k: Double) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
}

private func quad(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ k: Double) -> CGPoint {
    let u = 1 - k
    return CGPoint(x: u * u * a.x + 2 * u * k * c.x + k * k * b.x,
                   y: u * u * a.y + 2 * u * k * c.y + k * k * b.y)
}
