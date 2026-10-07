import SwiftUI
import AppKit

// Escale's colours, as roles rather than as greys: the page's own ground, the
// envelope the window is made of, the panels that float, the ink on each, the
// edge and the shadow that set a surface apart, and the few states that mean
// something (docs/DESIGN.md). The page is the one opaque thing — everything
// the browser draws around it is glass (Glass.swift), and a colour here never
// carries the Transparency setting itself: the envelope and panel tints are
// made see-through by Glass, the ink on them never is.
//
// The base stays neutral in both themes unless Escale's own colours are
// chosen. No accent is chosen yet; the green and amber of a connection are
// the only tints, and each repeats its meaning in words.
//
// Every colour is a pair — one for a light window, one for a dark — and
// resolves itself against whatever appearance the window has. The window
// takes its appearance from the app, and the app from Settings › Appearance:
// light, dark, or whatever the Mac is doing. Nothing else in the code knows
// which it is. The edges and separators also answer Increase Contrast, which
// macOS expresses as an appearance of its own.
//
// Settings › Appearance › Colours swaps the neutral greys for Escale's own
// (Tone): the two halves of its landing page, arrival and departure. Light is
// sand, milk and a brown-black ink; dark is umber and night under a cream ink.
// The veils keep their alphas and change only what they are made of: warm
// ink instead of black, milk or champagne instead of white, so a line or a
// shadow stays as quiet as before and only its temperature changes. States
// borrow the landing's environment colours, softened only as far as their
// meaning allows. Like contrast, the choice is read when a colour resolves,
// and the window is rebuilt when it changes (App.swift).
enum Palette {
    static func inspectionCSS(alpha: CGFloat) -> String {
        let colour = (swatchColour(.blue, ink: true).usingColorSpace(.sRGB) ?? NSColor.labelColor.usingColorSpace(.sRGB))
        guard let colour else { return "currentColor" }
        return "rgba(\(colour.redComponent * 255),\(colour.greenComponent * 255),\(colour.blueComponent * 255),\(alpha))"
    }

    /// Settings › Appearance › Increase contrast, on top of the Mac's own
    /// (Prefs.swift). Read by the colours that answer contrast; the window
    /// is rebuilt when it changes, so every one of them is resolved again.
    static var contrast = false

    /// Settings › Appearance › Colours (Prefs.swift): neutral, or Escale's
    /// own. Read by every role that has an Escale variant, like contrast.
    static var tone = Tone.neutral

    /// The page's own ground: behind a page while it loads, an empty tab, a
    /// sentence where a page failed. Opaque, always.
    static let ground = Color(nsColor: NS.ground)
    /// The window's glass, behind the column and the bars (Glass.swift).
    static let envelope = Color(nsColor: NS.envelope)
    /// The colour the envelope's glass is stained with while something shows
    /// through it (Glass.swift): the envelope itself, except in Escale's tone.
    static let envelopeTint = Color(nsColor: NS.envelopeTint)
    /// What floats: plates, menus, suggestions, notices (Glass.swift).
    static let panel = Color(nsColor: NS.panel)
    /// The colour a floating surface's glass is stained with, as the
    /// envelope's is (Glass.swift).
    static let panelTint = Color(nsColor: NS.panelTint)
    /// Ink on an ink-filled button. Opaque, whatever surface it is on.
    static let inverse = Color(nsColor: NS.inverse)
    /// A fine line around a surface, and the separators inside one.
    static let edge = Color(nsColor: NS.edge)
    /// The tab you are on, the page of Settings you are on: a surface of its
    /// own, a little denser than the glass in light, a little lighter in dark.
    static let selection = Color(nsColor: NS.selection)
    /// A group of lines on a panel: a faint surface on the panel's glass,
    /// not an opaque card in it (Plate.swift).
    static let raised = Color(nsColor: NS.raised)
    /// The dim over a page while a panel stands on it.
    static let scrim = Color(nsColor: NS.scrim)
    /// A shadow under anything lifted over something else.
    static let shadow = Color(nsColor: NS.shadow)
    /// Refused, failed, removed: said in words as well, never in red alone.
    static let danger = Color(nsColor: NS.danger)
    /// GitHub states always have a distinct symbol and accessible name too.
    static let githubOpen = Color(nsColor: NS.githubOpen)
    static let githubFinished = Color(nsColor: NS.githubFinished)
    static let ink = Color(nsColor: NS.ink)             // neutral-900 · neutral-100
    static let muted = Color(nsColor: NS.muted)         // secondary ink, stronger with contrast
    static let sleeping = Color(nsColor: NS.sleeping)   // informational, quieter than disabled controls
    static let faint = Color(nsColor: NS.faint)         // disabled ink, still legible on glass
    static let hairline = Color(nsColor: NS.hairline)   // ink at 8% · 9%, stronger with contrast
    static let wash = Color(nsColor: NS.wash)           // a field or a chip on a panel
    static let hover = Color(nsColor: NS.hover)         // the one under the pointer
    /// Exchanged data in Developer mode's API Calls (CallsPanel.swift): keys, text,
    /// numbers and literals told apart by a light tint, as a code viewer does.
    /// Softer than state colours, and never their only meaning.
    static let codeKey = Color(nsColor: NS.codeKey)
    static let codeString = Color(nsColor: NS.codeString)
    static let codeNumber = Color(nsColor: NS.codeNumber)
    /// A searched word where it was found in exchanged data: a marker's
    /// yellow under the ink, pale enough for the ink to read in both looks.
    static let found = Color(nsColor: NS.found)
    /// The sidebar's reading line: ink that starts clear, holds a body colour
    /// through the stretch already read and ends in a brighter tip at the
    /// position reached. Neutral until the window has an accent to borrow
    /// (docs/DESIGN.md, Colour): only alpha changes between the three.
    static let readingBody = Color(nsColor: NS.readingBody)
    static let readingTip = Color(nsColor: NS.readingTip)
    /// The only two that aren't grey: a connection nobody can read on the
    /// way, and one anybody can (see Bar.swift).
    static let safe = Color(nsColor: NS.safe)           // green-700 · green-400
    static let unsafe = Color(nsColor: NS.unsafe)       // amber-700 · amber-400

    /// A role as it is in one tone and one look, whatever the window wears:
    /// for the Colours choice, which shows both tones side by side
    /// (ToneChoice.swift). The tone is lent to the role while it resolves,
    /// on the main thread where every view is drawn, and handed back.
    static func sample(_ role: NSColor, tone: Tone, dark: Bool) -> Color {
        Color(nsColor: NS.sample(role, tone: tone, dark: dark))
    }

    /// Shared user palette (Swatch.swift): soft dots, readable text on chrome.
    static func swatch(_ choice: Swatch) -> Color { Color(nsColor: swatchColour(choice, ink: false)) }
    static func swatchInk(_ choice: Swatch) -> Color { Color(nsColor: swatchColour(choice, ink: true)) }
    /// A chip's ground under `swatchInk`: the dot at a low alpha, so the glass
    /// still shows through. Neutral is `wash`.
    static func swatchWash(_ choice: Swatch?) -> Color {
        guard let choice else { return wash }
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dim = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            // The dot is one colour in both looks; only its alpha differs.
            let dot = swatchColour(choice, ink: false).usingColorSpace(.sRGB) ?? .gray
            return dot.withAlphaComponent(dim ? 0.22 : 0.45)
        })
    }

    static func swatchColour(_ choice: Swatch, ink: Bool) -> NSColor {
        let soft: (CGFloat, CGFloat, CGFloat)
        let darkInk: (CGFloat, CGFloat, CGFloat)
        switch choice {
        case .rose: soft = (0.94, 0.65, 0.72); darkInk = (0.52, 0.19, 0.29)
        case .peach: soft = (0.96, 0.73, 0.60); darkInk = (0.51, 0.26, 0.14)
        case .amber: soft = (0.92, 0.81, 0.53); darkInk = (0.43, 0.32, 0.08)
        case .mint: soft = (0.61, 0.83, 0.72); darkInk = (0.13, 0.38, 0.27)
        case .blue: soft = (0.62, 0.77, 0.94); darkInk = (0.19, 0.32, 0.54)
        case .violet: soft = (0.78, 0.69, 0.94); darkInk = (0.37, 0.24, 0.55)
        }
        return NS.tint(light: ink ? darkInk : soft, dark: soft)
    }

    /// A space's colour, stored as its index here: the order is data and
    /// never changes. Slate, blue, green, orange, red, violet — each a touch
    /// lighter in dark so it holds its weight on the smoked glass.
    static let spaces: [Color] = [
        Color(nsColor: NS.tint(light: (0.45, 0.47, 0.52), dark: (0.58, 0.60, 0.66))),
        Color(nsColor: NS.tint(light: (0.26, 0.52, 0.96), dark: (0.40, 0.62, 1.0))),
        Color(nsColor: NS.tint(light: (0.20, 0.66, 0.45), dark: (0.30, 0.76, 0.54))),
        Color(nsColor: NS.tint(light: (0.96, 0.62, 0.20), dark: (1.0, 0.70, 0.32))),
        Color(nsColor: NS.tint(light: (0.90, 0.33, 0.40), dark: (0.98, 0.45, 0.51))),
        Color(nsColor: NS.tint(light: (0.62, 0.40, 0.90), dark: (0.72, 0.54, 0.98))),
    ]

    /// Over a film, in the floating window (Float.swift), whatever the look:
    /// the film is under its own dark scrim in both, so these are not pairs.
    /// The black behind the film is the letterbox, part of the video — and
    /// the window's ground while a page is immersed in one (App.swift).
    enum Film {
        static let ground = NSColor.black
        static let ink = NSColor.white
        static let button = NSColor(white: 0.1, alpha: 0.55)
        static let edge = NSColor(white: 1, alpha: 0.14)
        static let track = NSColor(white: 1, alpha: 0.22)
        static let progress = NSColor(white: 1, alpha: 0.85)
        /// Leaving a meeting, and a microphone that is off.
        static let hangUp = NSColor(red: 0.82, green: 0.16, blue: 0.16, alpha: 0.92)
        static let scrimTop = NSColor(white: 0, alpha: 0.45)
        static let scrimBottom = NSColor(white: 0, alpha: 0.5)
        /// A meeting's toggle that is on (presenting, a raised hand): lit,
        /// with dark ink, since no accent is chosen.
        static let lit = NSColor(white: 0.92, alpha: 0.95)
        static let litInk = NSColor(white: 0.08, alpha: 1)
        /// A person's card in a meeting, the round place of a face that has
        /// no picture, and the quieter text on them.
        static let card = NSColor(white: 0.16, alpha: 1)
        static let face = NSColor(white: 0.32, alpha: 1)
        static let faint = NSColor(white: 1, alpha: 0.6)

        /// A film colour for the meeting the page draws (meeting.js).
        static func css(_ colour: NSColor) -> String {
            guard let rgb = colour.usingColorSpace(.sRGB) else { return "transparent" }
            let channel = { (value: CGFloat) in Int((value * 255).rounded()) }
            return "rgba(\(channel(rgb.redComponent)),\(channel(rgb.greenComponent)),"
                + "\(channel(rgb.blueComponent)),\(rgb.alphaComponent))"
        }
    }

    /// The same colours for the AppKit corners of the app — a text field's
    /// ink, a window's background — which want an NSColor and keep it.
    enum NS {
        /// Escale's own values are the landing page's, by their names there
        /// where they have one: milk, linen, umber, the ink and its muted.
        static let ground = pair(1.0, 0.11, escale: (0xFAF7F2, 0x1F1914))
        /// Milky in light, smoked in dark, and a step away from the page in
        /// both, so the page's edge reads even when nothing shows through.
        /// Escale's is linen against milk, and night against the umber page.
        static let envelope = pair(0.945, 0.075, escale: (0xECE4D9, 0x16120F))
        /// At Subtle the envelope is 14% tint over the system's blur, which
        /// measured 240 in light and about 40 in dark in an inactive window
        /// (macOS 27, plain desktop): linen at 14% left it grey, (239, 238,
        /// 237). Escale's glass is therefore stained, as coloured glass is,
        /// with what lands that blur on linen at 14% — a caramel in light,
        /// measured (235, 228, 219) inactive and (220, 214, 205) active. In
        /// dark a tint can warm a blur but not darken it: a burnt umber
        /// takes the 37 grey to about (47, 40, 35). Clear lets proportionally
        /// less of it through; Solid uses the envelope itself.
        static let envelopeTint = NSColor(name: nil) { appearance in
            guard Palette.tone == .escale else { return envelope }
            return hex(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0x5A2A08 : 0xD39A4C)
        }
        static let panel = pair(0.985, 0.15, escale: (0xF8F4EE, 0x2A221C))
        /// Over the in-window material (234 in light), Escale's panel at 42%
        /// came out a grey (240, 238, 236) under a milk page. A cream lands
        /// it on the landing's paper, about (241, 236, 228); in dark the
        /// umber is already warm enough over its material.
        static let panelTint = NSColor(name: nil) { appearance in
            guard Palette.tone == .escale, appearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua else { return panel }
            return hex(0xFBEFDC)
        }
        static let inverse = pair(1.0, 0.11, escale: (0xFAF7F2, 0x1F1914))
        static let ink = pair(0.09, 0.93, escale: (0x221B16, 0xF1E9DE))
        /// Secondary labels and symbols need to read on a milky envelope as
        /// well as on smoked glass. The previous 55% / 58% pair disappeared
        /// beside native controls in light and dark; this darker/lighter pair
        /// keeps it below ink while giving icons and text a usable contrast.
        /// Escale's keep at least the neutral contrast on their own envelope.
        static let muted = pair(0.40, 0.68, strong: (0.28, 0.82),
                                escale: (0x5F5043, 0xB3A699), escaleStrong: (0x45392F, 0xD8CDC0))
        /// Disabled is quieter than secondary, not a decorative ghost: it is
        /// still used for selectable window sizes and controls on translucent
        /// surfaces. The old 83% light and 32% dark values were too close to
        /// their respective grounds to communicate that state.
        static let faint = pair(0.54, 0.57, strong: (0.38, 0.74),
                                escale: (0x8F7D6B, 0x918476), escaleStrong: (0x6B5A4B, 0xBCB0A2))
        /// A secondary state, with stronger contrast when explicitly requested.
        static let sleeping = veil(light: (0, 0.26), dark: (1, 0.30), contrast: 0.55)
        /// Ink at a low alpha rather than a grey, so a line reads the same on
        /// glass as on the page's ground.
        static let hairline = veil(light: (0, 0.08), dark: (1, 0.09), contrast: 0.3)
        static let edge = veil(light: (0, 0.1), dark: (1, 0.11), contrast: 0.45)
        /// Read on the milky envelope in light and the smoked one in dark: the
        /// body stays quiet, the tip is the part that can be found at a glance.
        static let readingBody = veil(light: (0, 0.26), dark: (1, 0.30), contrast: 0.55)
        static let readingTip = veil(light: (0, 0.62), dark: (1, 0.88), contrast: 0.95)
        static let wash = veil(light: (0, 0.055), dark: (1, 0.08), contrast: 0.12)
        static let hover = veil(light: (0, 0.045), dark: (1, 0.06), contrast: 0.1)
        static let raised = veil(light: (1, 0.55), dark: (1, 0.035), contrast: nil)
        static let selection = veil(light: (1, 0.86), dark: (1, 0.11), contrast: nil)
        static let scrim = veil(light: (0, 0.1), dark: (0, 0.3), contrast: nil)
        static let shadow = veil(light: (0, 0.12), dark: (0, 0.42), contrast: nil)
        /// Escale's states: brick for danger, forest and ochre for a
        /// connection, at the weight of the landing's environment colours.
        static let danger = tint(light: (0.78, 0.16, 0.16), dark: (1.0, 0.45, 0.45), escale: (0xA3372B, 0xF0897A))
        /// GitHub's own meanings, kept in both tones.
        static let githubOpen = tint(light: (0.08, 0.43, 0.20), dark: (0.35, 0.83, 0.49))
        static let githubFinished = tint(light: (0.48, 0.24, 0.69), dark: (0.77, 0.61, 0.96))
        static let safe = tint(light: (0.08, 0.50, 0.24), dark: (0.29, 0.87, 0.50), escale: (0x3B6B3E, 0x9CCB8C))
        static let unsafe = tint(light: (0.71, 0.33, 0.04), dark: (0.98, 0.75, 0.14), escale: (0x9A5B12, 0xE7B75F))
        /// Escale's are the landing's three environments: prod's wine for
        /// keys, staging's ochre for text, dev's blue for numbers.
        static let codeKey = tint(light: (0.49, 0.26, 0.62), dark: (0.80, 0.66, 0.96), escale: (0x8E3044, 0xE3A0AD))
        static let codeString = tint(light: (0.66, 0.28, 0.16), dark: (0.96, 0.66, 0.52), escale: (0x7C5E12, 0xE0C07A))
        static let codeNumber = tint(light: (0.15, 0.36, 0.70), dark: (0.56, 0.73, 0.98), escale: (0x3D5A95, 0x9FB4E0))
        /// Escale's marker is the landing's champagne rather than yellow.
        static let found = NSColor(name: nil) { appearance in
            let dim = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if Palette.tone == .escale { return hex(0xEFD5AA, alpha: dim ? 0.3 : 0.8) }
            return dim
                ? NSColor(srgbRed: 0.98, green: 0.78, blue: 0.18, alpha: 0.34)
                : NSColor(srgbRed: 1.0, green: 0.84, blue: 0.2, alpha: 0.5)
        }

        /// One colour per look. A role with an Escale pair takes it in that
        /// tone; a user's colour (a swatch, a space) has none and never changes.
        static func tint(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat),
                         escale: (UInt32, UInt32)? = nil) -> NSColor {
            NSColor(name: nil) { appearance in
                let dim = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                if Palette.tone == .escale, let escale { return hex(dim ? escale.1 : escale.0) }
                let c = dim ? dark : light
                return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
            }
        }

        /// White or black at an alpha, per look. With Increase Contrast on,
        /// `contrast` replaces the alpha (in both looks) when given. macOS
        /// says so through the window's appearance; the workspace's flag is
        /// asked too, for a view resolved outside a high-contrast match.
        private static func veil(light: (CGFloat, CGFloat), dark: (CGFloat, CGFloat), contrast: CGFloat?) -> NSColor {
            NSColor(name: nil) { appearance in
                let match = appearance.bestMatch(from: [
                    .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
                ])
                let dim = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
                return shade(dim ? dark : light, contrast: contrast, strong: increased(match), tone: Palette.tone, dim: dim)
            }
        }

        /// Contrast is increased: by the Mac, through the window's appearance
        /// or its workspace flag, or by Escale's own setting.
        static func increased(_ match: NSAppearance.Name?) -> Bool {
            match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
                || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast || Palette.contrast
        }

        /// One veil, resolved: the look's white and alpha, or the contrast
        /// alpha when contrast is increased and the role has one. In
        /// Escale's tone the same alpha is laid in its own black and white:
        /// the ink, or a near-black umber in dark; milk, or champagne in dark.
        static func shade(_ look: (CGFloat, CGFloat), contrast: CGFloat?, strong: Bool,
                          tone: Tone = .neutral, dim: Bool = false) -> NSColor {
            let alpha = strong ? (contrast ?? look.1) : look.1
            switch tone {
            case .neutral:
                return NSColor(white: look.0, alpha: alpha)
            case .escale:
                let light = look.0 >= 0.5
                return hex(light ? (dim ? 0xF1E6D4 : 0xFAF7F2) : (dim ? 0x0B0806 : 0x221B16), alpha: alpha)
            }
        }

        private static func pair(_ light: CGFloat, _ dark: CGFloat, strong: (CGFloat, CGFloat)? = nil,
                                 escale: (UInt32, UInt32), escaleStrong: (UInt32, UInt32)? = nil) -> NSColor {
            NSColor(name: nil) { appearance in
                let match = appearance.bestMatch(from: [
                    .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
                ])
                let dim = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
                switch Palette.tone {
                case .neutral:
                    return NSColor(white: pick((light, dark), strong: strong, dim: dim, increased: increased(match)), alpha: 1)
                case .escale:
                    return hex(pick(escale, strong: escaleStrong, dim: dim, increased: increased(match)))
                }
            }
        }

        /// A pair, resolved: the contrast pair when contrast is increased
        /// and the role has one.
        static func pick<T>(_ look: (T, T), strong: (T, T)?, dim: Bool, increased: Bool) -> T {
            let chosen = increased ? (strong ?? look) : look
            return dim ? chosen.1 : chosen.0
        }

        /// A role resolved once in a tone and a look (Palette.sample).
        static func sample(_ role: NSColor, tone: Tone, dark: Bool) -> NSColor {
            let worn = Palette.tone
            Palette.tone = tone
            defer { Palette.tone = worn }
            var resolved = role
            NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                resolved = role.usingColorSpace(.sRGB) ?? role
            }
            return resolved
        }

        /// An sRGB colour written as the landing page writes it, 0xRRGGBB.
        static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                    blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
        }
    }
}

/// What the palette resolves against besides the window's appearance. A
/// window made again whenever it changes resolves every colour afresh.
struct PaletteChoice: Hashable {
    let tone: Tone
    let contrast: Bool
}

/// Neutral greys, or Escale's own warm colours — orthogonal to the look, so
/// each exists in light and in dark.
enum Tone: String, CaseIterable, Identifiable {
    case neutral, escale

    var id: String { rawValue }

    var title: String {
        switch self {
        case .neutral: return "Neutral"
        case .escale: return "Escale"
        }
    }

    /// Neutral when nothing, or something unknown, was stored: an
    /// unconfigured browser keeps the colours it always had.
    static func stored(_ raw: String?) -> Tone {
        raw.flatMap(Tone.init) ?? .neutral
    }
}

/// Light, dark, or the Mac's own — the one choice that colours everything.
enum Look: String, CaseIterable, Identifiable {
    case light, dark, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }

    /// What the app is told to be. Nothing, for "system": the app then
    /// follows the Mac, and changes with it.
    var appearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }

    /// Set on the app rather than on the window, so every panel, alert and
    /// sheet — and every page, which follows the window it is in — agrees.
    ///
    /// Never from inside whatever is happening when it is asked for: the
    /// switch in Settings changes it from within an animation, over a panel
    /// in transition, and re-skinning every window in the middle of that is
    /// how a window ends up with a layer that takes clicks and shows
    /// nothing. The next turn of the run loop is soon enough.
    func apply() {
        let wanted = appearance
        DispatchQueue.main.async {
            guard NSApp.appearance !== wanted, NSApp.appearance?.name != wanted?.name else { return }
            NSApp.appearance = wanted
        }
    }
}

/// Three sizes for Escale's own controls. Standard is the reference choice;
/// Compact and Large resolve their own final points in ChromeMetrics without
/// changing a web page's zoom.
enum InterfaceSize: String, CaseIterable, Identifiable {
    case compact, standard, large

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// One scale serves both the Settings preview and the final chrome size.
    /// Stored profiles keep their named choice when these values change.
    var factor: CGFloat {
        switch self {
        case .compact: return 0.9
        case .standard: return 1.125
        case .large: return 1.35
        }
    }

    static func stored(_ rawValue: String?) -> InterfaceSize {
        rawValue.flatMap(InterfaceSize.init) ?? .standard
    }
}

enum Metrics {
    static let panelEdgeFraction: CGFloat = 0.28
    static let panelWidth: CGFloat = 180
    static let panelHeight: CGFloat = 120
    static let panelGrip: CGFloat = 32
    static let panelRing: CGFloat = 1.5
    static let panelGripWidth: CGFloat = 3
    static let panelHoverBand: CGFloat = 40
    static let panelToolsInset: CGFloat = 8
    static let panelTool: CGFloat = 24
    static let panelToolSymbol: CGFloat = 10
    static let panelSlotIcon: CGFloat = 24
    static let panelGhostWidth: CGFloat = 220
    static let panelEntryHeight: CGFloat = 28
    static let panelEntryRadius: CGFloat = 9
    static let mediaGap: CGFloat = 6
    static let mediaInset: CGFloat = 8
    static let mediaRadius: CGFloat = 9
    static let mediaIcon: CGFloat = 16
    static let mediaCaption: CGFloat = 11
    static let mediaControl: CGFloat = 22
    static let mediaGlyph: CGFloat = 10
    static let mediaSourcesWidth: CGFloat = 260
    static let mediaSourcesHeight: CGFloat = 180

    static let sleepStatusTravel: CGFloat = 21
    /// The same, on a row that wears Copy beside its cross.
    static let sleepPastCopy: CGFloat = 21 + 23
    /// The copy button at the end of an open tab's row or bookmark row, and
    /// what the row keeps for it at all times so its title, badge and cross
    /// stay put when the pointer comes.
    static let rowCopy: CGFloat = 20
    static let rowCopyInset: CGFloat = 3
    /// Copy's distance from the row's end: the cross's place, then a gap.
    static let rowCopyBeside: CGFloat = 26
    static let rowCopySlot: CGFloat = 23
    static let sleepSymbol: CGFloat = 10
    static let sleepBadgeOffset: CGFloat = 4
    static let returnPreviewBlur: CGFloat = 3
    static let returnStatusText: CGFloat = 13
    // Link Routing shares Settings' density: a rule is one line of a card,
    // its editor aligns labels in one column and its fields match a choice.
    static let routeGap: CGFloat = 7
    static let routeInset: CGFloat = 12
    static let routeRadius: CGFloat = 7
    static let routeText: CGFloat = 12
    static let routeSmall: CGFloat = 10.5
    static let routeGlyph: CGFloat = 10
    static let routeRow: CGFloat = 38
    static let routeAdd: CGFloat = 30
    static let routeTrial: CGFloat = 32
    static let routeRank: CGFloat = 16
    static let routeLabel: CGFloat = 70
    static let routeField: CGFloat = 320
    static let routeFieldHeight: CGFloat = 24
    static let routeSpace: CGFloat = 160
    static let routeOrder: CGFloat = 18
    static let routeExample: CGFloat = 24
    static let downloadWidth: CGFloat = 280
    static let downloadListHeight: CGFloat = 240
    static let downloadRowHeight: CGFloat = 68
    static let downloadRing: CGFloat = 22
    static let downloadLine: CGFloat = 1.5
    static let downloadBadge: CGFloat = 9
    static let downloadBadgeInset: CGFloat = 3
    static let downloadFlightSize: CGFloat = 34
    static let downloadFlightRise: CGFloat = 100
    static let downloadFlightEdge: CGFloat = 1
    static let downloadFlightShadow: CGFloat = 8
    static let downloadFlightShadowY: CGFloat = 3
    static let inspectionBorder: CGFloat = 2
    static let capturePreviewHeight: CGFloat = 240
    /// The capture card in the page's corner (PageCapture.swift).
    static let captureCardWidth: CGFloat = 260
    static let toolGap: CGFloat = 10
    static let toolInset: CGFloat = 14
    static let toolIndent: CGFloat = 12
    static let toolFont: CGFloat = 12
    static let toolPanelWidth: CGFloat = 680
    static let toolListHeight: CGFloat = 240
    /// Developer mode beside the page (Developer.swift), in compact points.
    static let callsWidth: CGFloat = 360
    static let callsMinWidth: CGFloat = 280
    static let callsMaxWidth: CGFloat = 640
    static let callsInset: CGFloat = 12
    static let callsGap: CGFloat = 8
    static let callsRowRadius: CGFloat = 9
    static let callsMethod: CGFloat = 40
    static let callsText: CGFloat = 12
    static let callsSmall: CGFloat = 10.5
    static let callsMono: CGFloat = 11
    static let callsTitle: CGFloat = 13
    static let callsDot: CGFloat = 6
    static let callsIndent: CGFloat = 12
    /// A tool's tab above Developer mode (Developer.swift).
    static let devToolTab: CGFloat = 26
    /// The card beside an inspected element (VisualPick.swift), in compact points.
    static let visualCardWidth: CGFloat = 264
    static let visualNameWidth: CGFloat = 72
    static let visualGap: CGFloat = 8
    static let infoSymbol: CGFloat = 13
    static let infoTarget: CGFloat = 24
    static let infoText: CGFloat = 12
    static let infoInset: CGFloat = 12
    static let infoWidth: CGFloat = 280
    /// The arrival and import panel use compact points, like every chrome
    /// length. ChromeMetrics resolves them at the selected interface size.
    static let arrivalButtonRadius: CGFloat = 8
    static let arrivalButtonPad: CGFloat = 6.5
    static let arrivalWidth: CGFloat = 480
    static let migrationListHeight: CGFloat = 260
    static let migrationLabelWidth: CGFloat = 64
    static let migrationChoiceHeight: CGFloat = 28
    static let migrationChoiceWidth: CGFloat = 320
    static let migrationChoiceInset: CGFloat = 4
    static let migrationRowHeight: CGFloat = 38
    static let migrationActionWidth: CGFloat = 80
    static let migrationSuggestionWidth: CGFloat = 160
    static let migrationSuggestionIcon: CGFloat = 28
    /// The import passage: two ends and the arrow between them.
    static let migrationPassageGap: CGFloat = 60
    static let migrationPassageBadge: CGFloat = 28
    static let migrationPassageTile: CGFloat = 34
    static let migrationPassageTileRadius: CGFloat = 9
    static let migrationPassageArrow: CGFloat = 11
    static let migrationPassageDot: CGFloat = 4
    static let arrivalTravel: CGFloat = 16
    static let arrivalInset: CGFloat = 28
    static let arrivalGap: CGFloat = 18
    static let arrivalTitle: CGFloat = 20
    static let arrivalText: CGFloat = 11.5
    static let arrivalSmall: CGFloat = 10
    static let arrivalMark: CGFloat = 36
    static let arrivalRowGap: CGFloat = 7
    static let arrivalDetailGap: CGFloat = 8
    static let arrivalSubtitle: CGFloat = 14
    static let arrivalProgress: CGFloat = 16
    static let arrivalButtonInset: CGFloat = 12
    /// The arrival's large side-by-side choices (theme, where tabs go): tall
    /// enough for a symbol over its name, the radius of a card.
    static let arrivalChoiceHeight: CGFloat = 64
    static let arrivalChoiceGlyph: CGFloat = 17
    static let arrivalChoiceLabel: CGFloat = 11.5
    static let arrivalChoiceRadius: CGFloat = 11
    static let arrivalCardInset: CGFloat = 12
    static let arrivalFeature: CGFloat = 26
    static let arrivalLine: CGFloat = 2
    static let arrivalDot: CGFloat = 5
    static let arrivalDotWide: CGFloat = 16
    static let arrivalField: CGFloat = 27
    static let arrivalBadge: CGFloat = 8.5
    static let arrivalBadgeInset: CGFloat = 6
    static let arrivalBar: CGFloat = 4
    static let arrivalSpinner: CGFloat = 12
    static let arrivalSpinnerLine: CGFloat = 1.5
    /// The GitHub step: keycaps beside its title, the tiles of the device code.
    static let arrivalKey: CGFloat = 18
    static let arrivalKeyRadius: CGFloat = 4.5
    static let arrivalCodeTile: CGFloat = 28
    static let arrivalCodeFont: CGFloat = 15
    static let migrationOutline: CGFloat = 220
    static let migrationIndent: CGFloat = 12

    /// A Colours sample in Settings (ToneChoice.swift): a browser at the
    /// window's own proportions, large enough for its page to read as one.
    /// The largest it is drawn; narrower Settings shrink it to fit.
    static let toneWidth: CGFloat = 150
    static let toneHeight: CGFloat = 94
    static let toneRadius: CGFloat = 7

    static let swatchDot: CGFloat = 12
    static let swatchDoor: CGFloat = 22
    static let swatchChoice: CGFloat = 22
    static let swatchGap: CGFloat = 8
    static let swatchInset: CGFloat = 12
    static let environmentEditorWidth: CGFloat = 550
    static let environmentEditorHeight: CGFloat = 360
    static let environmentNameWidth: CGFloat = 140
    /// A long path segment keeps its ends readable; the whole one is in its help.
    static let environmentSegmentWidth: CGFloat = 140
    static let environmentDoorWidth: CGFloat = 22
    /// Short names need less reserved space beside their chevron.
    static let environmentBadgeWidth: CGFloat = 36
    static let environmentCompactWidth: CGFloat = 200
    static let environmentBadgeHeight: CGFloat = 18
    static let environmentGap: CGFloat = 8
    static let environmentInset: CGFloat = 18
    static let environmentFont: CGFloat = 12
    static let environmentBadgeFont: CGFloat = 9
    /// The page's environment in the address bar, before the host.
    static let environmentChipHeight: CGFloat = 18
    static let environmentChipInset: CGFloat = 6
    static let environmentChipRadius: CGFloat = 5
    static let environmentChipFont: CGFloat = 10

    /// The tab strip. The window's title bar is grown to match it so the
    /// traffic lights come down with the tabs — otherwise giving the row room
    /// up with. 36 at Compact, 40 at Standard: the height of one row of
    /// controls with a little air, as Arc and Dia keep it —
    /// the 52 inherited from Search read as a band, not a bar.
    static let strip: CGFloat = 36
    /// Where the first tab starts. The traffic lights run from 19 to 79 —
    /// measured, not guessed — so this leaves them the same air on their right
    /// that the window gives them on their left.
    static let lights: CGFloat = 100
    /// Back, forward and reload, at the far end of the row beside the
    /// bookmarks: three doors and the air before the next one.
    static let helm: CGFloat = 3 * 26 + 2 * 2 + 8
    /// The same three doors again, in the sidebar, where they sit right of
    /// the lights instead. The column already has 10 of horizontal padding
    /// of its own before this even starts, so this is the lights' own edge
    /// (79) less that padding, plus a sliver of air — not the full breathing
    /// room a tab row gets, because the sidebar's minimum width doesn't have
    /// it to give.
    static let sideLights: CGFloat = 72
    /// The address bar over the page, in the column's mode (see Bar.swift).
    /// Lower than the strip: it holds one line of text and the three doors,
    /// not a row of tabs; the strip's own 36 now that the strip is one row
    /// of controls too, so both modes put the lights on the same line.
    static let bar: CGFloat = 36
    /// The band left at the top when there is no strip: just enough for the
    /// traffic lights to sit in, and nothing else.
    static let bare: CGFloat = 34
    /// Tabs are a fixed width rather than the width of their titles, so the
    /// cross always lands in the same place and the row never rearranges
    /// itself while you read it. They give way when there are too many:
    /// narrower than tabTitled they show their site's mark alone, and they
    /// stop at tabMinWidth, the mark and its air. Past that the row scrolls,
    /// inside its own edges.
    static let tabWidth: CGFloat = 186
    static let tabTitled: CGFloat = 80
    static let tabMinWidth: CGFloat = 36
    static let tabGap: CGFloat = 2
    /// A pinned tab is a square the height of the row, holding one letter.
    static let pinWidth: CGFloat = 30
    /// Favicons, pins and bookmark marks share one optical box in both tab
    /// layouts; small status symbols use the next size down.
    static let navigationIcon: CGFloat = 17
    /// Site artwork sits smaller inside its mark without moving adjacent text.
    static let faviconScale: CGFloat = 2.5 / 3.0
    static let navigationSymbol: CGFloat = 11
    /// The square at the end of the row that opens a new page.
    static let plusWidth: CGFloat = 30
    static let tabSearchSide: CGFloat = 28
    /// The address field, in both the places it shows up.
    static let fieldWidth: CGFloat = 460
    static let searchFieldHeight: CGFloat = 38
    static let searchRowHeight: CGFloat = 32
    static let searchInset: CGFloat = 10
    static let searchGap: CGFloat = 6
    /// Expanded destinations stay in their result, with room for chips and the exact URL.
    static let searchEnvironmentHeight: CGFloat = 58
    static let searchBadgeInset: CGFloat = 2
    static let searchFont: CGFloat = 13
    static let searchDetail: CGFloat = 10
    static let searchIcon: CGFloat = 14
    static let searchRowRadius: CGFloat = 7
    static let searchLift: CGFloat = 30
    /// Bearings' field sits at this share of the page's height, top edge fixed:
    /// results grow below it (at most half the height), so it never jumps.
    static let searchTop: CGFloat = 0.28
    /// A folder's search (FolderSearch.swift): rows of a title and a line
    /// under it, eight in view before the list scrolls.
    static let folderSearchWidth: CGFloat = 280
    static let folderSearchRow: CGFloat = 38
    static let folderSearchRows = 8
    /// The mode capsule (Modes.swift): round symbols, the one in use unfolded with its name.
    static let modeHeight: CGFloat = 22
    static let modeGlyph: CGFloat = 11
    static let modeLabel: CGFloat = 10.5
    static let modeOpen: CGFloat = 8
    static let modeLabelGap: CGFloat = 4
    static let modeInset: CGFloat = 2
    static let modeGap: CGFloat = 1
    static let githubRowHeight: CGFloat = 46
    static let githubLineGap: CGFloat = 3
    static let githubSymbol: CGFloat = 16
    static let githubStroke: CGFloat = 1.5
    static let githubActionWidth: CGFloat = 84
    static let githubAgeWidth: CGFloat = 40
    static let githubPreviewChromeHeight: CGFloat = 190
    /// The vertical space selector, kept separate from the tab column.
    /// Its 48-point compact rail leaves an eight-point inset around a door.
    static let spaceRail: CGFloat = 48
    static let spaceRailIcon: CGFloat = 32
    /// The rail's tool symbols use the Localhost reference size. Space icons
    /// are optically larger at the same font size, so they use one point less.
    static let spaceRailGlyph: CGFloat = 13
    static let spaceIconGlyph: CGFloat = 12
    /// What a Space plays or listens with: one mark at its door's corner.
    static let spaceMark: CGFloat = 14
    static let spaceMarkGlyph: CGFloat = 7
    /// The rail and column share an edge; their common surface needs no
    /// additional air or divider between them.
    static let spaceRailGap: CGFloat = 0
    /// The column of titles down the left, in the way that has one.
    static let side: CGFloat = 232
    static let sideMin: CGFloat = 176
    static let sideMax: CGFloat = 440
    /// The envelope left showing round the page, and the page's own corner.
    /// Set together (docs/DESIGN.md): a margin this small only reads as a
    /// frame with a corner about its size, and a larger corner would clip
    /// what a page draws in its own corners. None beside the column, whose
    /// rows keep their own 10 of air; none at all while a page is immersed.
    static let pageInset: CGFloat = 8
    static let pageRadius: CGFloat = 10
    /// Panels (Plate, Settings), the field and its list, and a row's pill.
    static let plateRadius: CGFloat = 16
    static let fieldRadius: CGFloat = 14
    static let cardRadius: CGFloat = 11
    /// Settings live in the browser's content area, never in a floating plate.
    /// They sit beside the column's 12.5 point titles and are set to match
    /// them: at 13 to 17 points, with 34 point rows, the page read a size
    /// larger than the browser around it.
    static let settingsRail: CGFloat = 190
    static let settingsCompactBreakpoint: CGFloat = 720
    static let settingsContent: CGFloat = 580
    static let settingsTitle: CGFloat = 15
    static let settingsGap: CGFloat = 14
    static let settingsInset: CGFloat = 20
    static let settingsTop: CGFloat = 16
    static let settingsRow: CGFloat = 28
    static let settingsRowText: CGFloat = 12
    static let settingsRowSymbol: CGFloat = 12.5
    static let settingsRowIcon: CGFloat = 18
    static let settingsRowRadius: CGFloat = 7
    static let settingsHeading: CGFloat = 10.5
    static let settingsSearch: CGFloat = 26
    static let settingsSearchText: CGFloat = 11.5

    // Keyboard uses aligned command/key columns and room between groups.
    static let keyboardPinnedHeight: CGFloat = 440
    static let keyboardToolbarGap: CGFloat = 14
    static let keyboardFilterWidth: CGFloat = 180
    static let keyboardGap: CGFloat = 8
    static let keyboardSmallGap: CGFloat = 3
    static let keyboardSectionGap: CGFloat = 28
    static let keyboardDetail: CGFloat = 11
    static let keyboardRowPad: CGFloat = 12
    static let keyboardKeyPad: CGFloat = 5
    static let keyboardKeyRadius: CGFloat = 5
    /// The menu over selected text (SelectionMenu.swift): a round Copy, then
    /// Translate beside it at the same height and corner.
    static let selectionButton: CGFloat = 36
    static let selectionGap: CGFloat = 8
    /// Between the selected line and the menu, and the page's edge and the menu.
    static let selectionOffset: CGFloat = 6
    static let selectionMargin: CGFloat = 8
    /// The update's panel (GatePanel.swift): its width, the boarding pass
    /// across its top and the words beneath it.
    static let gateWidth: CGFloat = 480
    static let gateGap: CGFloat = 16
    static let gatePassInset: CGFloat = 16
    static let gatePassNotch: CGFloat = 8
    static let gatePassStub: CGFloat = 88
    static let gateLabel: CGFloat = 9.5
    static let gateVersion: CGFloat = 32
    static let gateRoute: CGFloat = 44
    static let gatePlane: CGFloat = 14
    static let gateIcon: CGFloat = 44
    static let gateHeadline: CGFloat = 20
    static let gateBody: CGFloat = 13
    static let gateNotesHeight: CGFloat = 220
}

// One spring for anything that moves between two places, one for anything that
// arrives or leaves. Using the same two everywhere is most of why a thing feels
// like a single piece of software rather than a pile of views.
/// How large a card's lines and small controls are drawn. Floating panels
/// (History, Passwords, Bookmarks) keep the room their plate was drawn for;
/// Settings, in the page frame beside the column, use the chrome's own text
/// size. Lengths are compact points, resolved through ChromeMetrics.
struct CardDensity {
    let title: CGFloat
    let detail: CGFloat
    let control: CGFloat
    let caption: CGFloat
    let inset: CGFloat
    let pad: CGFloat
    let gap: CGFloat
    let pillX: CGFloat
    let pillY: CGFloat
    let switchWidth: CGFloat
    let switchHeight: CGFloat
    let segmentX: CGFloat
    let segmentY: CGFloat

    static let panel = CardDensity(title: 13, detail: 11.5, control: 11.5, caption: 11.5, inset: 14, pad: 11, gap: 16,
                                   pillX: 10, pillY: 5, switchWidth: 30, switchHeight: 18, segmentX: 10, segmentY: 5)
    static let settings = CardDensity(title: 12, detail: 10.5, control: 11, caption: 10.5, inset: 12, pad: 8, gap: 14,
                                      pillX: 9, pillY: 4, switchWidth: 26, switchHeight: 15, segmentX: 9, segmentY: 4)
}

enum Motion {
    static let githubMode = Animation.easeOut(duration: 0.16)
    /// The GitHub arrival types its example query once, a letter at a time.
    static let arrivalKeystroke: TimeInterval = 0.05
    /// Frequent keyboard commands keep the curve but finish three times sooner.
    static let shortcutMultiplier = 3.0
    /// Keep the old page briefly; slow returns then show a neutral status.
    static let returnPreviewLifetime: TimeInterval = 4
    /// Fade the retained preview over an already opaque page, then release it.
    static let returnReveal = Animation.easeOut(duration: 0.22)
    static let pageRevealDuration: TimeInterval = 0.12
    /// The plane slows as it reaches the download door; no bounce or repeat.
    /// It once flew for 0.72 s, which read as too quick to follow.
    static let downloadFlightDuration: TimeInterval = 1.0
    static let downloadFlight = Animation.timingCurve(0.20, 0.72, 0.18, 1, duration: downloadFlightDuration)
    static let downloadFlightStartNanoseconds: UInt64 = 50_000_000
    /// The animation's length plus a frame, before the plane is removed.
    static let downloadFlightNanoseconds = UInt64((downloadFlightDuration + 0.04) * 1_000_000_000)
    static let downloadFlightFreshness: TimeInterval = 1
    /// One calm curve for arrival pages, disclosure and import state changes.
    static let arrival = Animation.smooth(duration: 0.34, extraBounce: 0)
    static let glide = Animation.spring(response: 0.34, dampingFraction: 0.82)
    static let settle = Animation.spring(response: 0.30, dampingFraction: 0.86)
    /// A short, bounded fade for column contents when the rail stays put.
    static let fadeDuration: TimeInterval = 0.5
    static let fade = Animation.easeInOut(duration: fadeDuration)
    static let quick = Animation.easeOut(duration: 0.14)
    /// Arrival's plane coming in once over the pass and slowing to land.
    static let gateFlight = Animation.timingCurve(0.20, 0.70, 0.20, 1, duration: 0.9)
    static let gateFlightDelay: TimeInterval = 0.12
    /// Welcome's last step: the mark's dots light up to the next stop once,
    /// and the summary's rows follow one after another.
    static let landing = Animation.timingCurve(0.35, 0.05, 0.25, 1, duration: 1.1).delay(0.15)
    static let landingRow: TimeInterval = 0.07
    /// The rows of a folder as it opens or shuts. They come in once the rows
    /// below have started to make room, so a new row is never drawn over a
    /// neighbour still on its way down, and they leave before the rest closes
    /// up. The animations live in the transition, so Reduce Motion has to
    /// swap the transition itself for none.
    static func unfold(reduced: Bool) -> AnyTransition {
        reduced ? .identity : .asymmetric(
            insertion: AnyTransition.opacity.combined(with: .offset(y: -4)).animation(settle.delay(0.06)),
            removal: AnyTransition.opacity.animation(quick))
    }
    /// One turn of the import's spinner, repeated only while it is shown.
    static let spin = Animation.linear(duration: 0.9).repeatForever(autoreverses: false)
    /// A bookmark must dwell on another site before its folder preview can
    /// commit; the short scale pulse finishes before release becomes valid.
    static let bookmarkPending: TimeInterval = 0.48
    static let bookmarkReady: TimeInterval = 0.72
    static let bookmarkPulse = Animation.easeInOut(duration: 0.12)
    /// A shut folder's search opens once the pointer has rested on it this
    /// long, and closes this long after the pointer has left both
    /// (FolderSearch.swift): a pass over the column opens nothing.
    static let folderSearchDwell: TimeInterval = 0.375
    static let folderSearchLeave: TimeInterval = 0.3
    /// How long a copied value keeps its check mark (CopyButton.swift).
    static let copiedHold: TimeInterval = 1.2
    /// The copy symbol's swap to that check, as a multiple of the system's
    /// own pace: the swap, not the hold, is what was found slow.
    static let copySwapSpeed = 2.2
    /// The menu over selected text (SelectionMenu.swift), tuned by eye on a
    /// prototype: Copy swells past its size and settles, Translate is drawn
    /// out of it a beat later. About 0.37 s in all, short enough to be seen
    /// dozens of times a day. Bounce runs from 0 (none) to 1 (the most).
    static let selectionPop: TimeInterval = 0.30
    static let selectionPopBounce = 0.55
    static let selectionPullDelay: TimeInterval = 0.07
    static let selectionPull: TimeInterval = 0.30
    static let selectionPullBounce = 0.35
    /// How far Copy's height trails its width, as a share of its pop: the
    /// wobble that makes it read as a bubble rather than a zoom.
    static let selectionWobble = 0.07
    /// The menu leaves faster than it came.
    static let selectionLeave = Animation.easeIn(duration: 0.09)
}

/// Escale's mark: the stop, and the flight on from it — the stopover the name
/// is. A capsule where you are, five dots arcing away from it, and the dot of
/// the next stop; every gap along the way is the same. docs/BRAND.md has its
/// construction and every other place the path lives.
/// Written as path data rather than loaded from a file, so it stays a crisp
/// vector at any size. No plate, no square behind it: the mark is a bare
/// shape, the way every other icon in this app is. The one exception is the
/// macOS app icon (`Icon/icon.swift`), which needs an opaque square whether
/// the mark wants one or not — that's the Dock's requirement, not the logo's.
struct Logomark: Shape {
    /// The mark's own canvas, 470 × 335, nothing outside it.
    static let canvas = CGSize(width: 470, height: 335)

    /// A capsule, the next stop, then the five dots between them. The same
    /// path as Icon/icon.swift.
    private static let data = "M90 155H170C219.71 155 260 195.29 260 245C260 294.71 219.71 335 170 335H90C40.29 335 0 294.71 0 245C0 195.29 40.29 155 90 155ZM410 5C443.14 5 470 31.86 470 65C470 98.14 443.14 125 410 125C376.86 125 350 98.14 350 65C350 31.86 376.86 5 410 5ZM129 98C137.28 98 144 104.72 144 113C144 121.28 137.28 128 129 128C120.72 128 114 121.28 114 113C114 104.72 120.72 98 129 98ZM167 56C175.28 56 182 62.72 182 71C182 79.28 175.28 86 167 86C158.72 86 152 79.28 152 71C152 62.72 158.72 56 167 56ZM211 21C219.28 21 226 27.72 226 36C226 44.28 219.28 51 211 51C202.72 51 196 44.28 196 36C196 27.72 202.72 21 211 21ZM264 0C272.28 0 279 6.72 279 15C279 23.28 272.28 30 264 30C255.72 30 249 23.28 249 15C249 6.72 255.72 0 264 0ZM320 1C328.28 1 335 7.72 335 16C335 24.28 328.28 31 320 31C311.72 31 305 24.28 305 16C305 7.72 311.72 1 320 1Z"

    func path(in rect: CGRect) -> Path {
        // Fit the canvas into whatever frame this is given, centred, at the
        // larger scale that still keeps it inside — an SVG viewBox's "meet".
        let scale = min(rect.width / Logomark.canvas.width, rect.height / Logomark.canvas.height)
        let ox = rect.midX - Logomark.canvas.width * scale / 2
        let oy = rect.midY - Logomark.canvas.height * scale / 2
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * scale, y: oy + y * scale) }
        var path = Path()
        var last = CGPoint.zero
        var start = CGPoint.zero
        for (c, n) in Logomark.commands {
            switch c {
            case "M": last = CGPoint(x: n[0], y: n[1]); start = last; path.move(to: pt(n[0], n[1]))
            case "L": last = CGPoint(x: n[0], y: n[1]); path.addLine(to: pt(n[0], n[1]))
            case "H": last.x = n[0]; path.addLine(to: pt(last.x, last.y))
            case "V": last.y = n[0]; path.addLine(to: pt(last.x, last.y))
            case "C":
                var k = 0
                while k + 5 < n.count {
                    path.addCurve(to: pt(n[k + 4], n[k + 5]), control1: pt(n[k], n[k + 1]), control2: pt(n[k + 2], n[k + 3]))
                    last = CGPoint(x: n[k + 4], y: n[k + 5])
                    k += 6
                }
            case "Z": path.closeSubpath(); last = start
            default: break
            }
        }
        return path
    }

    /// Read once. Absolute M, L, H, V, C, Z — what Figma writes for a
    /// flattened shape, and nothing else is needed.
    private static let commands: [(Character, [CGFloat])] = {
        var out: [(Character, [CGFloat])] = []
        var current: Character?
        var numbers: [CGFloat] = []
        var token = ""
        func flush() {
            if !token.isEmpty, let v = Double(token) { numbers.append(CGFloat(v)) }
            token = ""
        }
        for ch in data {
            if "MLHVCZ".contains(ch) {
                flush()
                if let current { out.append((current, numbers)) }
                current = ch
                numbers = []
            } else if ch == " " || ch == "," {
                flush()
            } else if ch == "-" && !token.isEmpty {
                flush()
                token = "-"
            } else {
                token.append(ch)
            }
        }
        flush()
        if let current { out.append((current, numbers)) }
        return out
    }()
}

/// Wrong address, said without a dialog: the field shivers and stops.
struct Shake: GeometryEffect {
    var travel: CGFloat

    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        // Three there-and-backs, tapering to nothing, so it settles rather than
        // stopping mid-swing.
        let decay = 1 - travel
        return ProjectionTransform(
            CGAffineTransform(translationX: sin(travel * .pi * 6) * 7 * decay, y: 0)
        )
    }
}
