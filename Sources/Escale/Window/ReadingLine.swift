// The page reports one bounded reading fraction to Tab (see ScrollRelay in
// Tab.swift). The sidebar has no wide tab pill to fill, so this thin line
// stands just above the page. It observes only the active tab and adds no
// script, timer or second scroll calculation.
//
// The line is drawn over the top of the page's own frame, lifted by its
// height and inset by the page's corner on both sides. Sized by the page
// rather than by the window, it stops at the page's edges instead of running
// above the Developer column, and neither end shows inside the rounded
// corners. The strip it stands in is a plain gap of the same height in the
// window's column (see App.swift), so the page and the Developer column keep
// their top edges aligned. The width follows the page whenever the column is
// dragged, with no measurement handed back up.
//
// The gradient is laid out once over that width and scaled from the left by
// the fraction, so the clear start stays at the edge and the tip lands on
// the position reached, at 100% at the far end. A scale is a transform: a
// scroll step moves no layout.
import SwiftUI

struct ReadingLine: View {
    @ObservedObject var tab: Tab
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    /// The height of the line, and of the gap kept for it above the page.
    static func height(_ metrics: ChromeMetrics) -> CGFloat { metrics.length(2) }

    var body: some View {
        Rectangle()
            .fill(LinearGradient(
                stops: [
                    .init(color: Palette.readingBody.opacity(0), location: 0),
                    .init(color: Palette.readingBody, location: 0.6),
                    .init(color: Palette.readingTip, location: 1),
                ],
                startPoint: .leading, endPoint: .trailing))
            .scaleEffect(x: tab.reading, y: 1, anchor: .leading)
            .frame(height: Self.height(metrics))
            .animation(.easeOut(duration: 0.15), value: tab.reading)
            .accessibilityLabel("Reading progress")
            .accessibilityValue("\(Int((tab.reading * 100).rounded())) percent")
    }
}
