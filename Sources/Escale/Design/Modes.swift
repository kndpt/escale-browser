// The modes of one surface, side by side in a capsule. Each mode is a round
// symbol; the one in use stands on Escale's selection surface and unfolds with
// its name, so the capsule says where you are and what else is a click away
// without reading as a settings switch. The lifted capsule slides to the mode
// picked rather than appearing there; Reduce Motion makes it jump. The capsule
// keeps one width whichever mode is open, so what sits beside it stays put.
import SwiftUI

struct Modes<Option: Hashable>: View {
    struct Mode {
        enum Glyph { case symbol(String), image(Image) }
        let option: Option
        let glyph: Glyph
        let title: String
        /// The tooltip: the title, with its shortcut when there is one.
        var help: String
        var enabled = true
    }

    let modes: [Mode]
    let selection: Option
    let choose: (Option) -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var slide
    @State private var hovered: Option?

    var body: some View {
        HStack(spacing: metrics.length(Metrics.modeGap)) {
            ForEach(modes, id: \.option) { mode in
                let on = mode.option == selection
                Button { if !on { choose(mode.option) } } label: {
                    HStack(spacing: metrics.length(Metrics.modeLabelGap)) {
                        glyph(mode.glyph)
                        if on {
                            // Every name is laid out, only this one is drawn: the
                            // open mode is as wide as the longest name, so the
                            // capsule keeps one width and the field never moves.
                            ZStack {
                                ForEach(modes, id: \.option) { Text($0.title).hidden() }
                                Text(mode.title)
                            }
                            .font(.system(size: metrics.length(Metrics.modeLabel), weight: .medium))
                            .lineLimit(1)
                            .fixedSize()
                            .transition(.opacity)
                        }
                    }
                    .foregroundStyle(on || hovered == mode.option ? Palette.ink : Palette.muted)
                    .padding(.horizontal, on ? metrics.length(Metrics.modeOpen) : 0)
                    .frame(minWidth: metrics.length(Metrics.modeHeight), minHeight: metrics.length(Metrics.modeHeight))
                    .background {
                        if on {
                            Chosen(shape: Capsule(style: .continuous))
                                .matchedGeometryEffect(id: "chosen", in: slide)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!mode.enabled)
                .opacity(mode.enabled ? 1 : 0.4)
                .onHover { hovered = $0 ? mode.option : (hovered == mode.option ? nil : hovered) }
                .help(mode.help)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(metrics.length(Metrics.modeInset))
        .background(Palette.wash, in: Capsule(style: .continuous))
        .animation(reduceMotion ? nil : Motion.settle, value: selection)
        .animation(Motion.quick, value: hovered)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func glyph(_ glyph: Mode.Glyph) -> some View {
        switch glyph {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: metrics.length(Metrics.modeGlyph), weight: .medium))
                .accessibilityHidden(true)
        case .image(let image):
            image
                .resizable()
                .scaledToFit()
                .frame(width: metrics.length(Metrics.modeGlyph), height: metrics.length(Metrics.modeGlyph))
                .accessibilityHidden(true)
        }
    }
}
