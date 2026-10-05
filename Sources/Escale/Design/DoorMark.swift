// The small round mark at the corner of a rail door: the symbol a Space wears
// for sound or a camera in use, the number Localhost wears for its pages. The
// disc, its size, its border and its place are drawn here once, so the two
// never drift apart; what differs is only what sits inside. The size and the
// lettering come from `Metrics.spaceMark`, which scales with the interface.
import SwiftUI

struct DoorMark<Content: View>: View {
    @ViewBuilder let content: Content
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        content
            .font(.system(size: metrics.length(Metrics.spaceMarkGlyph), weight: .bold))
            .foregroundStyle(Palette.ink)
            .frame(width: metrics.length(Metrics.spaceMark), height: metrics.length(Metrics.spaceMark))
            .background(Circle().fill(Palette.raised))
            .overlay(Circle().stroke(Palette.hairline, lineWidth: 1))
            .offset(x: metrics.length(2), y: metrics.length(2))
            .accessibilityHidden(true)
    }
}
