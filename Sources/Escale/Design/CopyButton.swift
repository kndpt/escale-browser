// One copy button for every surface that has one: the address bar, the menu
// over selected text, Network and the sidebar's open tabs. They had drifted
// (a check that came back after 1.4 s in one, a toast alone in another), so the
// look, the swap to a green check and the way back live here and callers give
// only what to copy and how to name it. Sizes are the one thing a caller sets,
// because each sits in a different composition.
import SwiftUI

/// How long the check stays. A press while it shows starts the hold over, and
/// leaving the screen drops it, so no late timer flips a button that is gone.
@MainActor
final class CopyCycle: ObservableObject {
    @Published private(set) var done = false
    private var hold: Task<Void, Never>?
    /// How the hold is waited out; a test stands in for the clock.
    private let wait: (TimeInterval) async -> Void

    init(wait: @escaping (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }) {
        self.wait = wait
    }

    func press(hold seconds: TimeInterval = Motion.copiedHold) {
        done = true
        hold?.cancel()
        hold = Task { [weak self, wait] in
            await wait(seconds)
            guard !Task.isCancelled else { return }
            self?.done = false
        }
    }

    func cancel() {
        hold?.cancel()
        hold = nil
        if done { done = false }
    }
}

struct CopyButton: View {
    /// The tooltip, which may carry a shortcut.
    let help: String
    /// What VoiceOver says, when it should leave the shortcut out.
    var label: String?
    /// The square and its symbol, in compact points.
    var box: CGFloat = 20
    var glyph: CGFloat = 10
    /// The pointer's surface: rounded, or a circle with nil.
    var radius: CGFloat? = 5
    /// Rest colour; the pointer and the check have their own.
    var tint = Palette.muted
    /// Compact points to scale with the interface, or final points as they are.
    var scaled = true
    let action: () -> Void

    @StateObject private var cycle = CopyCycle()
    @State private var hovering = false
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let side = scaled ? metrics.length(box) : box
        let shape: AnyShape = radius.map { AnyShape(RoundedRectangle(cornerRadius: scaled ? metrics.length($0) : $0, style: .continuous)) }
            ?? AnyShape(Circle())
        Button {
            action()
            cycle.press()
        } label: {
            Image(systemName: cycle.done ? "checkmark" : "doc.on.doc")
                .font(.system(size: scaled ? metrics.length(glyph) : glyph, weight: .medium))
                .foregroundStyle(cycle.done ? Palette.safe : hovering ? Palette.ink : tint)
                // Reduce Motion swaps the symbol without the effect.
                .contentTransition(reduceMotion ? .identity
                                   : .symbolEffect(.replace, options: .speed(Motion.copySwapSpeed)))
                .frame(width: side, height: side)
                .background(shape.fill(hovering ? Palette.wash : .clear))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onDisappear { cycle.cancel() }
        .help(cycle.done ? "Copied" : help)
        .accessibilityLabel(cycle.done ? "Copied" : (label ?? help))
    }
}
