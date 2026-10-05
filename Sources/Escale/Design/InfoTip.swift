// Explanations stay beside the control that prompted them. Every info icon
// shares macOS's hover help and a native click/keyboard popover; the system
// owns placement and dismissal, without a second overlay or hover timer.
import SwiftUI

struct InfoTip: View {
    let label: String
    let explanation: String
    @State private var open = false
    @State private var identity = UUID()
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    // The browser intercepts Escape before SwiftUI receives it. Hand just
    // that key to the visible bubble; release the callback when its row leaves.
    private static var presented: (id: UUID, close: () -> Void)?

    @discardableResult
    static func dismiss() -> Bool {
        guard let current = presented else { return false }
        presented = nil
        current.close()
        return true
    }

    var body: some View {
        Button {
            if open { open = false }
            else {
                Self.dismiss()
                Self.presented = (identity, { open = false })
                open = true
            }
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: metrics.length(Metrics.infoSymbol)))
                .foregroundStyle(Palette.muted)
                .frame(width: metrics.length(Metrics.infoTarget), height: metrics.length(Metrics.infoTarget))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(explanation)
        .accessibilityLabel(label)
        .accessibilityHint(explanation)
        .onChange(of: open) { _, value in
            if !value, Self.presented?.id == identity { Self.presented = nil }
        }
        .onDisappear {
            if Self.presented?.id == identity { Self.dismiss() }
        }
        .popover(isPresented: $open) {
            Text(explanation)
                .font(.system(size: metrics.length(Metrics.infoText)))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(metrics.length(Metrics.infoInset))
                .frame(width: metrics.length(Metrics.infoWidth), alignment: .leading)
                .popoverGround()
                .onExitCommand { open = false }
        }
    }
}
