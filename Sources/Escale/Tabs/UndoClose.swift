import SwiftUI

// A closed tab is offered back for a few seconds, the way a mail app holds a
// message just sent. The ring empties over that time, so how long is left is
// seen, not counted; with Reduce Motion it steps down once a second instead
// of sliding. The tab itself is gone at once — its page stops, its memory
// goes — and what comes back is its history (Tab.carried): Back still goes
// back and the page opens where it was scrolled. ⌘⇧T does the same later.
// Clear and Close Other Tabs are offered back the same way, all at once: only
// the tab that was looked at loads, the others wait until shown.

/// The line at the bottom of the window just after a tab is closed.
struct UndoClose: View {
    let closing: Browser.Closing
    let undo: () -> Void
    @State private var left = 1.0
    @State private var shown = Date()
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: undo) {
            HStack(spacing: metrics.length(8)) {
                if reduceMotion {
                    TimelineView(.periodic(from: shown, by: 1)) { context in
                        ring(1 - context.date.timeIntervalSince(shown) / Motion.undoClose)
                    }
                } else {
                    ring(left)
                }
                Text(closing.label)
                    .font(.system(size: metrics.length(10.5)))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: metrics.length(230))
                    .fixedSize(horizontal: true, vertical: false)
                Text("Undo")
                    .font(.system(size: metrics.length(10.5), weight: .medium))
                    .foregroundStyle(Palette.ink)
            }
            .padding(.leading, metrics.length(8))
            .padding(.trailing, metrics.length(13.5))
            .padding(.vertical, metrics.length(6))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Read as "Undo", then what it brings back: the ring is only time.
        .accessibilityLabel("Undo")
        .accessibilityValue(closing.label)
        .glass(.chip, in: Capsule())
        .help(closing.ghosts.count == 1 ? "Reopen the closed tab (⇧⌘T)" : "Reopen the closed tabs (⇧⌘T)")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: Motion.undoClose)) { left = 0 }
        }
    }

    private func ring(_ left: Double) -> some View {
        let line = metrics.length(1.75)
        return ZStack {
            Circle()
                .stroke(Palette.hairline, lineWidth: line)
            Circle()
                .trim(from: 0, to: max(0, left))
                .stroke(Palette.ink, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: metrics.length(6.5), weight: .semibold))
                .foregroundStyle(Palette.ink)
        }
        .frame(width: metrics.length(16), height: metrics.length(16))
    }
}
