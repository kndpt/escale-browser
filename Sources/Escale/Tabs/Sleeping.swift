// Sleeping is a status, not another action beside Close. It uses the space
// already reserved for a tab's status, or a badge on an icon-only tab. Each
// open bookmark observes its tab here, so automatic sleep updates its marker
// and native help without relaying page changes through the whole browser.
import SwiftUI

enum SleepLabel {
    static let name = "Sleeping"
    static let explanation = "This tab saves resources until you open it again."
    static let help = "Sleeping. This tab saves resources until you open it again."
}

struct SleepMark: View {
    @ObservedObject var tab: Tab
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        if tab.sleeping {
            Image(systemName: "zzz")
                .font(.system(size: metrics.length(Metrics.sleepSymbol), weight: .medium))
                // Fainter than a label: it informs, it is not a control.
                .foregroundStyle(Palette.sleeping)
                .allowsHitTesting(false)
                // The row announces its state once; its mark is decorative.
                .accessibilityHidden(true)
        }
    }
}

/// A saved bookmark without an open page has no sleeping state to announce.
struct SleepHint: ViewModifier {
    let tab: Tab?
    var ordinary = ""
    var label: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let tab {
            content.modifier(OpenSleepHint(tab: tab, ordinary: ordinary, label: label))
        } else {
            content.help(ordinary)
        }
    }
}

private struct OpenSleepHint: ViewModifier {
    @ObservedObject var tab: Tab
    let ordinary: String
    let label: String?

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label ?? tab.label)
            .help(tab.sleeping ? SleepLabel.help : ordinary)
            .accessibilityValue(tab.sleeping ? SleepLabel.name : "")
            .accessibilityHint(tab.sleeping ? SleepLabel.explanation : "")
    }
}

/// The open bookmark observes its page without refreshing the whole shelf.
struct BookmarkSleepMark: View {
    @ObservedObject var tab: Tab
    let hovering: Bool
    let rowHeight: CGFloat
    var travel: CGFloat = Metrics.sleepStatusTravel
    var reserved: CGFloat = 0
    let close: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        ZStack {
            SleepMark(tab: tab)
                .offset(x: hovering ? -metrics.length(travel) : 0)
            if hovering {
                Image(systemName: "xmark")
                    .font(.system(size: metrics.length(8), weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: metrics.length(15), height: metrics.length(15))
                    .background(Palette.ink.opacity(0.07), in: Circle())
                    .transition(.opacity)
            } else if !tab.sleeping {
                Circle()
                    .fill(Palette.muted)
                    .frame(width: metrics.length(5), height: metrics.length(5))
            }
        }
        .frame(width: metrics.length(15), height: metrics.length(15))
        .overlay {
            Color.clear
                .frame(width: metrics.length(30), height: rowHeight)
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
        }
        // The hover actions share this reservation with the travelling mark.
        .padding(.leading, metrics.length(max(reserved, tab.sleeping ? travel : 0)))
    }
}
