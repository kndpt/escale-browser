// Escale's 100% is one existing 1.1 zoom step below WebKit's native size.
// Saved site values remain absolute WebKit factors: an old 1.21 stays 1.21
// visually (now 133%). Missing/invalid values use 1 / 1.1; reset removes the
// key. Keeping that representation avoids a destructive migration or drift
// on repeated launches, and leaves Space keys and private writes unchanged.
import Foundation

enum PageZoom {
    static let reference: CGFloat = 1 / 1.1
    static func absolute(_ relative: CGFloat) -> CGFloat { relative * reference }
    static func relative(_ absolute: CGFloat) -> CGFloat { absolute / reference }
    static func remembered(_ value: Double?) -> CGFloat {
        guard let value, value.isFinite, (0.4...3).contains(value) else { return reference }
        return CGFloat(value)
    }
}
