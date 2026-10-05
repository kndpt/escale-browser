import SwiftUI

// The pieces of Escale's settings and floating panels. History, Downloads,
// Passwords and Bookmarks share one plate, while full-window Settings use
// its cards, lines and rules directly on the window's envelope. Their
// controls still read as one family without a second plate around Settings.
//
// The plate is glass (Glass.swift); what sits on it is not another layer of
// blur. A card is a faint surface on the plate's own material, so the
// material still reads through the list instead of stopping at an opaque
// box inside the panel.

/// The plate: a rounded card with a title, a cross, whatever the panel is
/// about, and — when there is one — a foot below a hairline.
struct Plate<Content: View, Foot: View>: View {
    let title: String
    var width: CGFloat = 560
    let close: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let foot: () -> Foot
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.chromePanelBounds) private var chromePanelBounds

    init(
        _ title: String,
        width: CGFloat = 560,
        close: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder foot: @escaping () -> Foot
    ) {
        self.title = title
        self.width = width
        self.close = close
        self.content = content
        self.foot = foot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: metrics.length(10)) {
                Text(title)
                    .font(.system(size: metrics.length(17), weight: .medium))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                Door(icon: "xmark", help: "Done   esc", act: close)
            }
            .padding(.horizontal, metrics.length(22))
            .padding(.top, metrics.length(18))
            .padding(.bottom, metrics.length(14))

            content()
                .padding(.horizontal, metrics.length(22))

            if Foot.self != EmptyView.self {
                Rectangle().fill(Palette.hairline).frame(height: metrics.length(1))
                    .padding(.top, metrics.length(18))
                foot()
                    .padding(.horizontal, metrics.length(22))
                    .padding(.vertical, metrics.length(14))
            } else {
                Color.clear.frame(height: metrics.length(20))
            }
        }
        .frame(
            width: chromePanelBounds.width > 0 ? min(metrics.length(width), chromePanelBounds.width) : metrics.length(width),
            alignment: .leading
        )
        .clipShape(RoundedRectangle(cornerRadius: metrics.plateRadius, style: .continuous))
        .glass(.panel, in: RoundedRectangle(cornerRadius: metrics.plateRadius, style: .continuous))
    }
}

extension Plate where Foot == EmptyView {
    init(
        _ title: String,
        width: CGFloat = 560,
        close: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(title, width: width, close: close, content: content, foot: { EmptyView() })
    }
}

private struct CardDensityKey: EnvironmentKey {
    static let defaultValue = CardDensity.panel
}

extension EnvironmentValues {
    /// Set by Settings for everything inside them (see CardDensity).
    var cardDensity: CardDensity {
        get { self[CardDensityKey.self] }
        set { self[CardDensityKey.self] = newValue }
    }
}

/// A group of lines in one hairline box.
struct Card<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(Palette.raised)
            .clipShape(RoundedRectangle(cornerRadius: metrics.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: metrics.cardRadius, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
    }
}

/// One line of a card, for a list too long to build whole: side by side in a
/// lazy stack, the slices draw the box a Card draws around all its lines, so
/// only the lines in view need to exist. `top` and `bottom` say where the
/// card starts and ends; a line between two others is a Rule and its content.
struct Slice<Content: View>: View {
    let top: Bool
    let bottom: Bool
    @ViewBuilder let content: () -> Content
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        let outline = SliceOutline(radius: metrics.cardRadius, top: top, bottom: bottom)
        VStack(spacing: 0) {
            if !top { Rule() }
            content()
        }
        .background(Palette.raised)
        .clipShape(outline)
        .overlay(outline.strokeBorder(Palette.hairline, lineWidth: 1))
        .clipped()
    }
}

/// The card's own outline, carried on past a slice's edges where the card
/// goes on, so that clipped to the slice only its sides are left there.
private struct SliceOutline: InsettableShape {
    let radius: CGFloat
    let top: Bool
    let bottom: Bool
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        // Past the whole continuous corner, which curves over more than its radius.
        let reach = radius * 2
        var frame = rect
        if !top {
            frame.origin.y -= reach
            frame.size.height += reach
        }
        if !bottom { frame.size.height += reach }
        return RoundedRectangle(cornerRadius: max(0, radius - inset), style: .continuous)
            .path(in: frame.insetBy(dx: inset, dy: inset))
    }

    func inset(by amount: CGFloat) -> SliceOutline {
        var shape = self
        shape.inset += amount
        return shape
    }
}

/// The hairline between two lines of a card, inset like the text.
struct Rule: View {
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.cardDensity) private var density
    var body: some View {
        Rectangle().fill(Palette.hairline).frame(height: metrics.length(1)).padding(.leading, metrics.length(density.inset))
    }
}

/// One thing to set or do: what it is on the left, the control on the right.
struct Line<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let control: () -> Control
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.cardDensity) private var density

    init(_ title: String, _ detail: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: metrics.length(density.gap)) {
            VStack(alignment: .leading, spacing: metrics.length(3)) {
                Text(title)
                    .font(.system(size: metrics.length(density.title)))
                    .foregroundStyle(Palette.ink)
                if let detail {
                    Text(detail)
                        .font(.system(size: metrics.length(density.detail)))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: metrics.length(8))
            control()
        }
        .padding(.horizontal, metrics.length(density.inset))
        .padding(.vertical, metrics.length(density.pad))
    }
}

/// A small heading over a card, for when a panel has more than one.
struct Caption: View {
    let text: String
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.cardDensity) private var density
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: metrics.length(density.caption), weight: .regular))
            .foregroundStyle(Palette.muted)
            .padding(.leading, metrics.length(2))
    }
}

/// The field for narrowing a list. The wash, the glass, the caret.
struct Hunt: View {
    @Binding var text: String
    var prompt = "Search"
    var focus: FocusState<Bool>.Binding
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.length(8)) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: metrics.length(11), weight: .regular))
                .foregroundStyle(Palette.muted)
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    // One line whatever the width: a narrow field cuts its
                    // prompt rather than growing taller.
                    Text(prompt)
                        .foregroundStyle(Palette.muted.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.ink)
                    .focused(focus)
            }
            .font(.system(size: metrics.length(13)))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: metrics.length(11)))
                        .foregroundStyle(Palette.faint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, metrics.length(12))
        .padding(.vertical, metrics.length(8))
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: metrics.length(10), style: .continuous))
    }
}

/// What a panel says when its list is empty.
struct Nothing: View {
    let text: String
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.cardDensity) private var density
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: metrics.length(density.title)))
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, metrics.length(density.inset))
            .padding(.vertical, metrics.length(18))
    }
}

/// A small text action inside a row — Show, Copy, Remove.
struct Quick: View {
    let title: String
    var tint: Color = Palette.ink
    let act: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.cardDensity) private var density

    init(_ title: String, tint: Color = Palette.ink, act: @escaping () -> Void) {
        self.title = title
        self.tint = tint
        self.act = act
    }

    var body: some View {
        Button(action: act) {
            Text(title)
                .font(.system(size: metrics.length(density.control)))
                .foregroundStyle(tint)
                .padding(.horizontal, metrics.length(8))
                .padding(.vertical, metrics.length(4))
                .background(Palette.wash, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
