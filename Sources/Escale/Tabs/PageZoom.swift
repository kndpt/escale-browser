// Escale's 100% is one existing 1.1 zoom step below WebKit's native size.
// Saved site values remain absolute WebKit factors: an old 1.21 stays 1.21
// visually (now 133%). Keeping that representation avoids a destructive
// migration or drift on repeated launches, and leaves Space keys and private
// writes unchanged.
//
// The default zoom is relative, like the percentages a person picks. A site
// without a valid saved value opens at it, and a site is saved only while it
// differs from it: a deliberate 100% under a 125% default is kept, and a new
// default moves every site that never chose its own.
import Foundation

enum PageZoom {
    static let reference: CGFloat = 1 / 1.1
    /// The default's choices, in percent; anything else stored reads as 100.
    static let defaults = [75, 90, 100, 110, 125, 150, 175, 200]

    static func absolute(_ relative: CGFloat) -> CGFloat { relative * reference }
    static func relative(_ absolute: CGFloat) -> CGFloat { absolute / reference }

    static func standard(_ percent: Int?) -> Int {
        guard let percent, defaults.contains(percent) else { return 100 }
        return percent
    }

    /// The absolute factor a site opens at, given the relative default.
    static func remembered(_ value: Double?, standard: CGFloat) -> CGFloat {
        guard let value, value.isFinite, (0.4...3).contains(value) else { return absolute(standard) }
        return CGFloat(value)
    }

    /// What a site at `relative` saves; nil removes its key.
    static func kept(_ relative: CGFloat, standard: CGFloat) -> Double? {
        abs(relative - standard) < 0.01 ? nil : Double(absolute(relative))
    }
}
