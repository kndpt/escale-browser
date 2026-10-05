import SwiftUI

// Escale's interface sizes are final layout values, not a transform applied
// after a compact drawing has been rasterised. Standard is the reference
// density; Compact and Large derive their points from the same tokens. Keeping
// those values in the environment lets nested controls use the same geometry,
// while the WebKit stage remains an ordinary, untransformed view.
struct ChromeMetrics: Equatable {
    let size: InterfaceSize

    /// The three final densities follow the 12 / 15 / 18 point previews in
    /// Settings. Input tokens stay in compact coordinates, so saved sidebar
    /// widths keep their meaning when a person changes size.
    private var density: CGFloat { size.factor }

    func length(_ compact: CGFloat) -> CGFloat {
        // Retina displays resolve half points cleanly; keep layout edges on
        // stable final coordinates rather than transform a rasterised view.
        (compact * density * 2).rounded() / 2
    }

    func layout(_ visible: CGFloat) -> CGFloat {
        visible / density
    }

    var strip: CGFloat { length(36) }
    var bar: CGFloat { length(36) }
    var lights: CGFloat { length(100) }
    var sideLights: CGFloat { length(72) }
    /// Where the title line's own doors may start in the column's mode,
    /// from the window's left edge: past the lights, with the air a door
    /// keeps from them. The lights stay put whether the column is out or
    /// folded, so what starts under them has to step aside by this much.
    /// The traffic lights are AppKit's physical controls: Compact must still
    /// clear their measured 79-point end even when Escale's own dimensions
    /// shrink around them.
    var lightsClear: CGFloat { max(80, length(10) + sideLights) }

    /// How far a title line whose doors would start `origin` points from the
    /// window's left edge has to step right to clear the lights.
    func clearingLights(from origin: CGFloat) -> CGFloat { max(0, lightsClear - origin) }
    var helm: CGFloat { length(3 * 26 + 2 * 2 + 8) }
    var bare: CGFloat { length(34) }
    var tabWidth: CGFloat { length(186) }
    var tabTitled: CGFloat { length(80) }
    var tabMinWidth: CGFloat { length(36) }
    var tabGap: CGFloat { length(2) }
    var pinWidth: CGFloat { length(30) }
    var plusWidth: CGFloat { length(30) }
    var fieldWidth: CGFloat { length(Metrics.fieldWidth) }
    /// The fixed strip that keeps spaces separate from the tab column. It is
    /// narrow enough to leave the column readable, but wide enough for a
    /// door with equal air on either side.
    var spaceRailWidth: CGFloat { length(Metrics.spaceRail) }
    /// The rail's door has the same inset on its left and right.
    var spaceRailInset: CGFloat { (spaceRailWidth - length(Metrics.spaceRailIcon)) / 2 }
    /// The rail and column share an edge without inventing a border between
    /// them.
    var spaceRailGap: CGFloat { length(Metrics.spaceRailGap) }
    var pageInset: CGFloat { length(8) }
    var pageRadius: CGFloat { length(10) }
    var plateRadius: CGFloat { length(16) }
    var fieldRadius: CGFloat { length(14) }
    var cardRadius: CGFloat { length(11) }

    /// A persisted sidebar width is kept in the compact layout's coordinates
    /// so changing the interface size does not overwrite the user's choice.
    func sidebarWidth(_ stored: CGFloat) -> CGFloat { length(stored) }

    /// The left footprint is the rail alone while folded, and the rail plus
    /// its gap and the user's column width while open. Spaces off keeps the
    /// old column geometry.
    func sidebarFootprint(_ stored: CGFloat, rail: Bool, folded: Bool) -> CGFloat {
        guard rail else { return folded ? 0 : sidebarWidth(stored) }
        return folded ? spaceRailWidth : spaceRailWidth + spaceRailGap + sidebarWidth(stored)
    }
}

private struct ChromeMetricsKey: EnvironmentKey {
    static let defaultValue = ChromeMetrics(size: .standard)
}

extension EnvironmentValues {
    var chromeMetrics: ChromeMetrics {
        get { self[ChromeMetricsKey.self] }
        set { self[ChromeMetricsKey.self] = newValue }
    }

    /// The space a floating panel may occupy. A zero size means that the view
    /// is not inside a sheet and should use its design width.
    var chromePanelBounds: CGSize {
        get { self[ChromePanelBoundsKey.self] }
        set { self[ChromePanelBoundsKey.self] = newValue }
    }
}

private struct ChromePanelBoundsKey: EnvironmentKey {
    static let defaultValue = CGSize.zero
}
