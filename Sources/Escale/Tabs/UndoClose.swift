import SwiftUI

// A closed tab is offered back for a few seconds, the way a mail app holds a
// message just sent. The ring empties over that time, so how long is left is
// seen, not counted. The tab itself is gone at once — its page stops, its
// memory goes — and what comes back is its history (Tab.kept): Back still
// goes back and the page opens where it was scrolled. ⌘⇧T does the same later.

/// The line at the bottom of the window just after a tab is closed.
struct UndoClose: View {
    let ghost: Browser.Ghost
    let undo: () -> Void
    @State private var left = 1.0

    var body: some View {
        Button(action: undo) {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .stroke(Palette.hairline, lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: left)
                        .stroke(Palette.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                }
                .frame(width: 18, height: 18)
                Text(ghost.label)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260)
                    .fixedSize(horizontal: true, vertical: false)
                Text("Undo")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink)
            }
            .padding(.leading, 9)
            .padding(.trailing, 15)
            .padding(.vertical, 7)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glass(.chip, in: Capsule())
        .help("Reopen the closed tab")
        .onAppear {
            withAnimation(.linear(duration: Motion.undoClose)) { left = 0 }
        }
    }
}
