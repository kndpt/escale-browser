// ⌘/ lays every key Escale answers over the window, grouped as Settings ›
// Keyboard groups them, so a shortcut can be looked up without leaving the
// page. It reads the saved bindings each time it is built: a key moved or
// removed there is what it shows. Nothing is built until it opens.
import SwiftUI

struct KeyChart: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.chromePanelBounds) private var bounds

    struct Row: Hashable { let title: String; let keys: String }
    struct Section: Identifiable { let group: KeyGroup; let rows: [Row]; var id: String { group.id } }

    /// Each group's commands that have a key, then the keys Escale doesn't own.
    static func sections(_ bindings: KeyBindings) -> [Section] {
        KeyGroup.allCases.filter { $0 != .reference }.compactMap { group in
            let commands = KeyCommand.all.filter { $0.group == group }
            // Go to Tab 1–8 is one line while each number still has its own
            // digit under the same modifiers; once one moves, each is listed.
            let numbers = commands.filter { $0.action.index != nil }
            let first = bindings.keys(numbers.first?.action ?? .newTab).first
            let together = numbers.count > 1 && numbers.allSatisfy {
                bindings.keys($0.action) == [KeyStroke("#\($0.action.index ?? 0)", first?.flags ?? [])]
            }
            var rows: [Row] = []
            for command in commands {
                if together, command.action.index != nil {
                    if command.action == numbers.first?.action, let first, let last = numbers.last?.action.index {
                        rows.append(Row(title: command.title + "–\(last)", keys: first.label + "–\(last)"))
                    }
                    continue
                }
                let keys = bindings.keys(command.action)
                if !keys.isEmpty { rows.append(Row(title: command.title, keys: keys.map(\.label).joined(separator: " · "))) }
            }
            return rows.isEmpty ? nil : Section(group: group, rows: rows)
        } + [Section(group: .reference, rows: KeyReference.all.map { Row(title: $0.title, keys: $0.keys) })]
    }

    var body: some View {
        Plate("Keyboard Shortcuts", width: Metrics.keyChartWidth, close: { browser.listingKeys = false }) {
            ScrollView(showsIndicators: false) {
                HStack(alignment: .top, spacing: metrics.length(Metrics.keyChartGap)) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        VStack(alignment: .leading, spacing: metrics.length(Metrics.keyChartGap)) {
                            ForEach(column) { section($0) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.bottom, metrics.length(2))
            }
        } foot: {
            HStack {
                Text("esc or ⌘/ to close")
                    .font(.system(size: metrics.length(Metrics.keyboardDetail)))
                    .foregroundStyle(Palette.muted)
                Spacer()
                Pill("Change Shortcuts…") {
                    browser.listingKeys = false
                    Store.settings.set("keyboard", forKey: "settings.page")
                    browser.tuning = true
                }
            }
        }
        .environment(\.cardDensity, .settings)
    }

    /// As many columns as fit, each section going to the shortest so far.
    private var columns: [[Section]] {
        let width = metrics.length(Metrics.keyChartWidth)
        let room = (bounds.width > 0 ? min(width, bounds.width) : width) - metrics.length(44)
        let count = max(1, Int(room / metrics.length(Metrics.keyChartColumn)))
        var columns = Array(repeating: [Section](), count: count)
        var heights = Array(repeating: 0, count: count)
        for section in Self.sections(prefs.keyBindings) {
            let shortest = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            columns[shortest].append(section)
            heights[shortest] += section.rows.count + 2
        }
        return columns.filter { !$0.isEmpty }
    }

    private func section(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: metrics.length(6)) {
            Caption(section.group.rawValue).accessibilityAddTraits(.isHeader)
            Card {
                ForEach(section.rows, id: \.self) { row in
                    if row != section.rows.first { Rule() }
                    Line(row.title) {
                        Text(row.keys)
                            .font(.system(size: metrics.length(Metrics.keyboardDetail), weight: .medium, design: .monospaced))
                            .foregroundStyle(Palette.ink)
                            .fixedSize()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
