// The network column beside the page that holds Escale's API Calls tool,
// opened and closed by Network in Developer mode's dock (Workbench.swift) or
// ⌥⌘N. A light row of tabs on the envelope names the tools; the chosen one
// stands below in a frame of Escale's glass, the page's inset between them as
// between the column and the page, beside the page's frame and never over it.
// API Calls (Calls.swift) is the first tool; the next ones join the row rather
// than getting a door each.
//
// It belongs to the tab it was opened for. With one tool, being open is that
// tool's collection being open, and the column keeps no state of its own; a
// second tool will give the tab a choice to remember.
import SwiftUI

/// The tools Developer mode offers, in the order of its header.
enum DeveloperTool: CaseIterable, Identifiable {
    case calls

    var id: Self { self }
    var title: String {
        switch self {
        case .calls: return "Network"
        }
    }
}

/// Where Developer mode goes in the window: beside the stage while the tab on
/// screen has it open, and not while Settings or an immersed page have it.
struct DeveloperColumn: View {
    @ObservedObject var browser: Browser

    var body: some View {
        if let tab = browser.active, !browser.tuning, !tab.immersed {
            Slot(calls: tab.calls, browser: browser)
                .id(tab.id)
        }
    }

    private struct Slot: View {
        @ObservedObject var calls: Calls
        let browser: Browser
        @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            Group {
                if calls.open {
                    DeveloperPanel(calls: calls, browser: browser)
                        .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : Motion.settle, value: calls.open)
        }
    }
}

struct DeveloperPanel: View {
    @ObservedObject var calls: Calls
    let browser: Browser
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    /// Dragged by the leading edge, in final points; the window's session only.
    @State private var width: CGFloat?
    @State private var dragStart: CGFloat?
    @State private var gripping = false
    @State private var tool = DeveloperTool.calls

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.pageRadius, style: .continuous)
        // The tools on the envelope, then the chosen one in its own frame,
        // the page's inset between them as between the column and the page.
        VStack(alignment: .leading, spacing: metrics.pageInset) {
            HStack(spacing: metrics.length(2)) {
                ForEach(DeveloperTool.allCases) { each in
                    ToolTab(title: each.title, count: calls.list.shown(calls.filter).count, chosen: each == tool) { tool = each }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Developer tools")

            Group {
                switch tool {
                case .calls: CallsTool(calls: calls, browser: browser)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipShape(shape)
            // Its edge outside, like the page's, so the two outlines line up.
            .glass(.panel, in: shape, lifted: false, edgeOutside: true)
        }
        .frame(width: resolved)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .leading) { grip }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Developer mode")
    }

    private var resolved: CGFloat {
        let chosen = width ?? metrics.length(Metrics.callsWidth)
        return min(max(chosen, metrics.length(Metrics.callsMinWidth)), metrics.length(Metrics.callsMaxWidth))
    }

    /// The envelope between the page and the column widens or narrows it, as
    /// the gap between two split pages does (PanelStage.swift): the same
    /// grip, shown only under the pointer or while held.
    private var grip: some View {
        let long = metrics.length(Metrics.panelGrip)
        let thin = metrics.length(Metrics.panelGripWidth)
        return Capsule(style: .continuous)
            .fill(Palette.muted)
            .frame(width: thin, height: long)
            .opacity(gripping ? 1 : 0)
            .scaleEffect(gripping ? 1 : 0.6)
            .frame(width: metrics.pageInset)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .offset(x: -metrics.pageInset)
            .animation(Motion.quick, value: gripping)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                if dragStart == nil { gripping = inside }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = dragStart ?? resolved
                        dragStart = start
                        gripping = true
                        width = start - drag.translation.width
                    }
                    .onEnded { _ in dragStart = nil; gripping = false; width = resolved }
            )
            .accessibilityLabel("Resize Developer mode")
            .accessibilityAdjustableAction { direction in
                width = resolved + (direction == .increment ? 1 : -1) * metrics.length(24)
            }
    }
}

/// One tool, standing on the envelope as a tab of the tab row does: the
/// chosen surface under the one shown, the pointer's under the others.
private struct ToolTab: View {
    let title: String
    let count: Int
    let chosen: Bool
    let choose: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.length(Metrics.callsRowRadius), style: .continuous)
        Button(action: choose) {
            HStack(spacing: metrics.length(6)) {
                Text(title)
                    .font(.system(size: metrics.length(Metrics.callsText), weight: .medium))
                    .foregroundStyle(chosen ? Palette.ink : Palette.muted)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: metrics.length(Metrics.callsSmall), weight: .medium).monospacedDigit())
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, metrics.length(10))
            .frame(height: metrics.length(Metrics.devToolTab))
            .background {
                if chosen { Chosen(shape: shape) } else if hovering { shape.fill(Palette.hover) }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// The hammer, at the end of the bar: Developer mode, the dock of page tools
/// at the window's foot. Lit while the dock is up.
struct DeveloperDoor: View {
    @ObservedObject var browser: Browser

    var body: some View {
        Door(icon: "hammer", on: browser.developing, help: browser.prefs.keyHelp(.developer)) { browser.toggleWorkbench() }
            .accessibilityLabel("Developer Mode")
    }
}

/// Network in the dock: the API Calls column beside the page. On while the
/// tab on screen has it open.
struct NetworkTool: View {
    @ObservedObject var browser: Browser

    var body: some View {
        if let tab = browser.active {
            Lit(browser: browser, tab: tab, calls: tab.calls)
        } else {
            WorkbenchTool(icon: "network", title: "Network", help: browser.prefs.keyHelp(.network)) {}
                .disabled(true)
        }
    }

    private struct Lit: View {
        let browser: Browser
        @ObservedObject var tab: Tab
        @ObservedObject var calls: Calls

        var body: some View {
            WorkbenchTool(icon: "network", title: "Network", on: calls.open, help: browser.prefs.keyHelp(.network)) { browser.toggleCalls() }
                .disabled(tab.built == nil || tab.isBlank ? !calls.open : false)
        }
    }
}
