// A round button over a floating window's picture (Grip.dress). It answers the
// pointer before it is pressed: a step lighter under it, a step darker while
// held, and a pointing hand. A window that floats over someone's work, holding a
// meeting they are in, has to show what takes a click before it takes one; a
// flat disc that does nothing under the pointer reads as a picture, or as
// something that might break the call.
//
// The window is a non-activating panel, so cursor rectangles, which follow the
// key window, do nothing, and a hand set once on entering is put back to an
// arrow at the next move. It is set again at each move over the button, which
// holds while Escale is in front. Behind another app, macOS keeps that app's
// pointer, and the step lighter says it alone.

import AppKit

final class Knob: NSButton {
    /// Its colour at rest; under the pointer and held down are worked out from it.
    var tint = Palette.Film.button {
        didSet { paint() }
    }

    private var over = false
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Only its own: the button keeps the ones its tooltip needs.
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) {
        over = true
        paint()
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        over = false
        paint()
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) { NSCursor.pointingHand.set() }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        paint()
    }

    // Hidden under the pointer, it has no exit to hear: it comes back at rest.
    override func viewDidHide() {
        super.viewDidHide()
        over = false
        paint()
    }

    private func paint() {
        let colour = isHighlighted ? Palette.Film.held(tint) : over ? Palette.Film.hovered(tint) : tint
        layer?.backgroundColor = colour.cgColor
    }
}
