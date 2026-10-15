// A floating window's round buttons answer the pointer: every colour they wear,
// a lit toggle's included, has a hover a visible step from rest, and held down
// is darker still.

import AppKit
import Testing
@testable import Escale

@MainActor
struct KnobTests {
    private let tints = [Palette.Film.button, Palette.Film.hangUp, Palette.Film.lit]

    /// How bright a colour reads over the film's black ground.
    private func seen(_ colour: NSColor) -> CGFloat {
        guard let rgb = colour.usingColorSpace(.sRGB) else { return 0 }
        let light = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return light * rgb.alphaComponent
    }

    @Test func everyTintHasAHoverThatShows() {
        for tint in tints {
            #expect(abs(seen(Palette.Film.hovered(tint)) - seen(tint)) > 0.05)
        }
    }

    @Test func heldIsDarker() {
        for tint in tints {
            #expect(seen(Palette.Film.held(tint)) < seen(tint))
        }
    }

    @Test func wearsItsTintAndDarkensWhileHeld() {
        let knob = Knob()
        knob.wantsLayer = true
        knob.tint = Palette.Film.hangUp
        #expect(knob.layer?.backgroundColor == Palette.Film.hangUp.cgColor)
        knob.highlight(true)
        #expect(knob.layer?.backgroundColor == Palette.Film.held(Palette.Film.hangUp).cgColor)
        knob.highlight(false)
        #expect(knob.layer?.backgroundColor == Palette.Film.hangUp.cgColor)
    }
}
