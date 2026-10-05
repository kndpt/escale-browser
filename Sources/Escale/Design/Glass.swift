import SwiftUI
import AppKit

// The material Escale's own surfaces are made of (docs/DESIGN.md): one
// translucent envelope behind the sidebar and the bars, a denser family for
// what floats — panels, menus, the address field — and never the page.
//
// Each surface is a blur with a tint over it. The blur is the system's: an
// NSVisualEffectView behind the window for the envelope, so the desktop shows
// through, and SwiftUI's material inside the window for what floats over a
// page. The tint is ours, a light/dark pair from Palette, and its opacity is
// adjusted along with the material by Transparency. Clear uses lighter
// materials so reducing the tint is not hidden by a dense system blur.
// Escale's tone stains the
// glass with a richer colour than its opaque one (Palette.NS.envelopeTint),
// so its warmth survives a 14% tint. Text, symbols and targets are drawn
// over the tint at full strength: the setting never fades ink.
//
// Solid draws no blur at all — no effect view, an opaque window — which is
// also what Reduce Transparency gets, whatever was chosen. Increase Contrast
// strengthens the edges instead (see Palette.NS.edge). The web page is never
// in this: its frame is opaque (Page in Stage.swift) and nothing here samples,
// filters or pictures it.
//
// Cost: a behind-window effect view is composited by the window server, which
// redraws it when what is behind the window changes; the in-window materials
// only exist while their panel is open. Measured on the design migration's
// fixtures; not free, and not assumed to be.

/// How much of what lies behind shows through Escale's own surfaces.
enum Depth: String, CaseIterable, Identifiable {
    case solid, subtle, clear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .solid: return "Solid"
        case .subtle: return "Subtle"
        case .clear: return "Clear"
        }
    }

    /// Subtle, as the design direction asks of the everyday look.
    static let standard: Depth = .subtle

    /// What a stored value means: the default when there is none, or when it
    /// is something this version doesn't know.
    static func stored(_ raw: String?) -> Depth {
        raw.flatMap(Depth.init) ?? .standard
    }

    /// What is drawn. The Mac's Reduce Transparency wins over any choice.
    func drawn(reducing: Bool) -> Depth {
        reducing ? .solid : self
    }

    /// Whether anything behind is let through at all.
    var sees: Bool { self != .solid }

    /// How opaque a role's tint is over its blur, from 0 to 1. Floating
    /// surfaces stay denser than the envelope at every level: they stand
    /// over pages whose detail would otherwise compete with their text.
    func tint(_ role: Glass.Role) -> Double {
        switch (self, role) {
        case (.solid, _): return 1
        case (.subtle, .envelope): return 0.14
        case (.subtle, .panel): return 0.42
        case (.subtle, .chip): return 0.56
        case (.clear, .envelope): return 0.02
        case (.clear, .panel): return 0.12
        case (.clear, .chip): return 0.24
        }
    }
}

enum Glass {
    /// What a surface is for, which decides its tint and density.
    enum Role {
        /// The window's own ground, behind the sidebar and the bars.
        case envelope
        /// Plates, menus, suggestions and the field: a panel with room.
        case panel
        /// A single line over a page: a notice, find, a link's address.
        case chip
    }

    /// The window the envelope is drawn in: clear where the desktop may show
    /// through, opaque and the envelope's colour otherwise.
    static func dress(_ window: NSWindow, sees: Bool) {
        window.isOpaque = !sees
        window.backgroundColor = sees ? .clear : Palette.NS.envelope
    }
}

/// Settings share the page's frame, but Clear lets the existing envelope
/// show through instead of covering it with an opaque page ground. One
/// behind-window blur serves the whole window; no second material is added.
struct SettingsGround: View {
    let corner: CGFloat
    @SwiftUI.Environment(\.depth) private var depth
    @SwiftUI.Environment(\.accessibilityReduceTransparency) private var reducing

    var body: some View {
        if depth.drawn(reducing: reducing) == .clear {
            RoundedRectangle(cornerRadius: corner + 1, style: .continuous)
                .strokeBorder(Palette.edge, lineWidth: 1)
                .padding(-1)
                .allowsHitTesting(false)
        } else {
            PageGround(corner: corner)
        }
    }
}

private struct DepthKey: EnvironmentKey {
    static let defaultValue = Depth.standard
}

extension EnvironmentValues {
    /// The Transparency setting, handed down from the window (App.swift).
    var depth: Depth {
        get { self[DepthKey.self] }
        set { self[DepthKey.self] = newValue }
    }
}

/// The window's ground: the desktop, blurred, under the envelope's tint.
struct Envelope: View {
    @SwiftUI.Environment(\.depth) private var depth
    @SwiftUI.Environment(\.accessibilityReduceTransparency) private var reducing

    var body: some View {
        let drawn = depth.drawn(reducing: reducing)
        ZStack {
            if drawn.sees { Backdrop(depth: drawn) }
            (drawn.sees ? Palette.envelopeTint : Palette.envelope).opacity(drawn.tint(.envelope))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The system's blur of what is behind the window. It follows the window's
/// active state as every Mac window does: flatter while another app is in
/// front.
private struct Backdrop: NSViewRepresentable {
    let depth: Depth

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = depth == .clear ? .sidebar : .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = depth == .clear ? .sidebar : .underWindowBackground
    }
}

/// A floating surface: blur, tint, a fine edge and a diffuse shadow, all
/// behind the content so none of it dims the ink.
struct GlassSurface<S: InsettableShape>: ViewModifier {
    let role: Glass.Role
    let shape: S
    var lifted = true
    /// The fine edge just outside the shape, as the page's frame has it
    /// (PageGround in Stage.swift), for a surface standing beside the page:
    /// both outlines then meet the same lines.
    var edgeOutside = false

    @SwiftUI.Environment(\.depth) private var depth
    @SwiftUI.Environment(\.accessibilityReduceTransparency) private var reducing

    func body(content: Content) -> some View {
        let drawn = depth.drawn(reducing: reducing)
        content
            .background {
                ZStack {
                    if drawn.sees {
                        shape.fill(drawn == .clear
                                   ? (role == .chip ? Material.regularMaterial : Material.thinMaterial)
                                   : (role == .chip ? Material.thickMaterial : Material.regularMaterial))
                    }
                    shape.fill((drawn.sees ? Palette.panelTint : Palette.panel).opacity(drawn.tint(role)))
                }
                .shadow(color: lifted ? Palette.shadow : .clear, radius: role == .chip ? 16 : 28, y: role == .chip ? 5 : 10)
            }
            .overlay {
                if edgeOutside {
                    shape.inset(by: -0.5).stroke(Palette.edge, lineWidth: 1).allowsHitTesting(false)
                } else {
                    shape.strokeBorder(Palette.edge, lineWidth: 1).allowsHitTesting(false)
                }
            }
    }
}

/// The surface under what you are on: the tab, the pinned square, the open
/// bookmark, the space, the page of Settings, the chosen segment. One
/// surface everywhere, so a thing chosen reads the same wherever it is —
/// denser than the glass in light, lighter in dark (Palette.selection) —
/// lifted by a hair of shadow rather than outlined.
struct Chosen<S: Shape>: View {
    let shape: S

    var body: some View {
        shape
            .fill(Palette.selection)
            .shadow(color: Palette.shadow.opacity(0.4), radius: 1.5, y: 0.5)
    }
}

extension Chosen where S == RoundedRectangle {
    init(radius: CGFloat) {
        self.init(shape: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// The ground under a SwiftUI popover. macOS already gives a popover its own
/// translucent material, drawn by the system and not by Escale; this leaves
/// it showing and fills it only when Escale is asked to be solid.
struct PopoverGround: ViewModifier {
    @SwiftUI.Environment(\.depth) private var depth
    @SwiftUI.Environment(\.accessibilityReduceTransparency) private var reducing

    func body(content: Content) -> some View {
        content.background(depth.drawn(reducing: reducing).sees ? Color.clear : Palette.panel)
    }
}

extension View {
    /// Made of Escale's glass, in the given shape.
    func glass<S: InsettableShape>(_ role: Glass.Role, in shape: S, lifted: Bool = true, edgeOutside: Bool = false) -> some View {
        modifier(GlassSurface(role: role, shape: shape, lifted: lifted, edgeOutside: edgeOutside))
    }

    /// Inside a popover: the system's material, or solid (see PopoverGround).
    func popoverGround() -> some View {
        modifier(PopoverGround())
    }
}
