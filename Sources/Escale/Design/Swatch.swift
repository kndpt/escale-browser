// User-chosen colours share six stable names across Escale. A missing choice
// stays neutral; persisted values never depend on display order or RGB values.
// The small popover exists only during a choice and edits its caller's binding,
// so an enclosing editor can cancel its draft without writing anything.
import SwiftUI

enum Swatch: String, CaseIterable, Codable, Identifiable {
    case rose, peach, amber, mint, blue, violet

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var fill: Color { Palette.swatch(self) }
    var ink: Color { Palette.swatchInk(self) }
}

struct SwatchPicker: View {
    @Binding var selection: Swatch?
    @State private var choosing = false
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        Button { choosing.toggle() } label: {
            Circle().fill(selection?.fill ?? Palette.muted)
                .frame(width: metrics.length(Metrics.swatchDot), height: metrics.length(Metrics.swatchDot))
                .overlay(Circle().strokeBorder(Palette.edge))
                .frame(width: metrics.length(Metrics.swatchDoor), height: metrics.length(Metrics.swatchDoor))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Colour: \(selection?.title ?? "Neutral")")
        .accessibilityLabel("Choose colour")
        .accessibilityValue(selection?.title ?? "Neutral")
        .popover(isPresented: $choosing) {
            VStack(alignment: .leading, spacing: metrics.length(Metrics.swatchGap)) {
                HStack(spacing: metrics.length(Metrics.swatchGap)) {
                    ForEach(Swatch.allCases) { colour in
                        Button {
                            selection = colour
                            choosing = false
                        } label: {
                            Circle().fill(colour.fill)
                                .frame(width: metrics.length(Metrics.swatchChoice), height: metrics.length(Metrics.swatchChoice))
                                .overlay(Circle().strokeBorder(selection == colour ? Palette.ink : Palette.edge,
                                                               lineWidth: selection == colour ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                        .help(colour.title)
                        .accessibilityLabel(colour.title)
                        .accessibilityAddTraits(selection == colour ? .isSelected : [])
                    }
                }
                Button("Neutral") {
                    selection = nil
                    choosing = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.muted)
            }
            .padding(metrics.length(Metrics.swatchInset))
            .popoverGround()
        }
    }
}
