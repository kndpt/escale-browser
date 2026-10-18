// The Transparency setting's rules and the colours it must never touch.
// No window is made: stored values, accessibility overrides and appearance
// resolution are all plain values.
import AppKit
import Testing
@testable import Escale

// Serialized: cases turn Escale's own Increase Contrast and its tone on and off.
@Suite(.serialized) struct GlassTests {
    @Test(arguments: [
        (nil, Depth.subtle),
        ("", Depth.subtle),
        ("frosted", Depth.subtle),
        ("SOLID", Depth.subtle),
        ("solid", Depth.solid),
        ("subtle", Depth.subtle),
        ("clear", Depth.clear),
    ] as [(String?, Depth)])
    func reads(stored: String?, depth: Depth) {
        #expect(Depth.stored(stored) == depth)
    }

    @Test(arguments: Depth.allCases)
    func reduceTransparencyWins(depth: Depth) {
        #expect(depth.drawn(reducing: true) == .solid)
        #expect(depth.drawn(reducing: false) == depth)
        #expect(!depth.drawn(reducing: true).sees)
    }

    @Test func onlySolidHidesWhatIsBehind() {
        #expect(!Depth.solid.sees)
        #expect(Depth.subtle.sees)
        #expect(Depth.clear.sees)
    }

    /// Every tint is an opacity, Solid is opaque everywhere, each level lets
    /// more through than the one before, and what floats over a page is
    /// always denser than the envelope.
    @Test func tintsAreBoundedAndOrdered() {
        let roles: [Glass.Role] = [.envelope, .panel, .chip]
        for depth in Depth.allCases {
            for role in roles {
                #expect((0...1).contains(depth.tint(role)))
            }
            #expect(depth.tint(.envelope) <= depth.tint(.panel))
            #expect(depth.tint(.panel) <= depth.tint(.chip))
        }
        for role in roles {
            #expect(Depth.solid.tint(role) == 1)
            #expect(Depth.subtle.tint(role) > Depth.clear.tint(role))
        }
        #expect(Depth.subtle.tint(.envelope) == 0.14)
        #expect(Depth.subtle.tint(.panel) == 0.42)
        #expect(Depth.subtle.tint(.chip) == 0.56)
        #expect(Depth.clear.tint(.envelope) == 0.02)
        #expect(Depth.clear.tint(.panel) == 0.12)
        #expect(Depth.clear.tint(.chip) == 0.24)
    }

    /// The page's ground and the ink on an ink button are opaque in both
    /// looks: the setting and the glass never fade them.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func opaqueRolesStayOpaque(look: NSAppearance.Name) throws {
        let appearance = try #require(NSAppearance(named: look))
        for colour in [Palette.NS.ground, Palette.NS.inverse, Palette.NS.ink, Palette.NS.envelope, Palette.NS.panel] {
            #expect(alpha(colour, in: appearance) == 1)
        }
    }

    /// Increase Contrast strengthens a veil that has a contrast alpha, in
    /// both looks, and leaves one without (a selection, a shadow) alone.
    @Test(arguments: [(CGFloat(0), CGFloat(0.1)), (1, 0.11)])
    func contrastStrengthensEdges(white: CGFloat, alpha: CGFloat) {
        let plain = Palette.NS.shade((white, alpha), contrast: 0.45, strong: false)
        let strong = Palette.NS.shade((white, alpha), contrast: 0.45, strong: true)
        #expect(plain.alphaComponent == alpha)
        #expect(strong.alphaComponent == 0.45)
        #expect(strong.whiteComponent == white)
        let untouched = Palette.NS.shade((white, alpha), contrast: nil, strong: true)
        #expect(untouched.alphaComponent == alpha)
    }

    /// Secondary text takes its contrast pair when contrast is increased,
    /// darker in light and lighter in dark; a role without one is unchanged.
    @Test func contrastStrengthensSecondaryText() {
        let look: (CGFloat, CGFloat) = (0.40, 0.68)
        let strong: (CGFloat, CGFloat) = (0.28, 0.82)
        #expect(Palette.NS.pick(look, strong: strong, dim: false, increased: false) == 0.40)
        #expect(Palette.NS.pick(look, strong: strong, dim: false, increased: true) == 0.28)
        #expect(Palette.NS.pick(look, strong: strong, dim: true, increased: true) == 0.82)
        #expect(Palette.NS.pick(look, strong: nil, dim: true, increased: true) == 0.68)
    }

    /// Faint controls remain distinguishable from their surface in both
    /// looks, while muted text keeps the stronger of the two roles.
    @Test func secondaryAndDisabledInkStayVisible() {
        let muted: (CGFloat, CGFloat) = (0.40, 0.68)
        let faint: (CGFloat, CGFloat) = (0.54, 0.57)
        #expect(muted.0 < faint.0)
        #expect(muted.1 > faint.1)
        #expect(Palette.NS.pick(faint, strong: nil, dim: false, increased: false) == 0.54)
        #expect(Palette.NS.pick(faint, strong: nil, dim: true, increased: false) == 0.57)
    }

    /// Escale's own setting raises contrast like the Mac's does, and only
    /// while it is on.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func ownSettingRaisesContrast(look: NSAppearance.Name) throws {
        let appearance = try #require(NSAppearance(named: look))
        guard !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast else { return }
        let before = alpha(Palette.NS.edge, in: appearance)
        Palette.contrast = true
        defer { Palette.contrast = false }
        #expect(alpha(Palette.NS.edge, in: appearance) == 0.45)
        #expect(alpha(Palette.NS.edge, in: appearance) > before)
        #expect(Palette.NS.increased(.aqua))
    }

    /// Neutral unless Escale was asked for by name.
    @Test(arguments: [(nil, Tone.neutral), ("", .neutral), ("ESCALE", .neutral), ("warm", .neutral),
                      ("neutral", .neutral), ("escale", .escale)] as [(String?, Tone)])
    func toneReads(stored: String?, tone: Tone) {
        #expect(Tone.stored(stored) == tone)
    }

    /// Escale's tone changes what the opaque roles are, never that they are
    /// opaque, and lays every veil at the neutral alpha.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func escaleKeepsOpacityAndAlphas(look: NSAppearance.Name) throws {
        let appearance = try #require(NSAppearance(named: look))
        let veils = [Palette.NS.edge, Palette.NS.hairline, Palette.NS.hover, Palette.NS.selection, Palette.NS.shadow]
        let neutral = veils.map { alpha($0, in: appearance) }
        let ground = rgb(Palette.NS.ground, in: appearance)
        Palette.tone = .escale
        defer { Palette.tone = .neutral }
        for colour in [Palette.NS.ground, Palette.NS.inverse, Palette.NS.ink, Palette.NS.envelope, Palette.NS.panel] {
            #expect(alpha(colour, in: appearance) == 1)
        }
        #expect(veils.map { alpha($0, in: appearance) } == neutral)
        #expect(rgb(Palette.NS.ground, in: appearance) != ground)
    }

    /// Escale's ground is the landing's milk in light, and its envelope linen.
    @Test func escaleIsTheLandingsColours() throws {
        let light = try #require(NSAppearance(named: .aqua))
        Palette.tone = .escale
        defer { Palette.tone = .neutral }
        #expect(rgb(Palette.NS.ground, in: light) == [0xFA, 0xF7, 0xF2])
        #expect(rgb(Palette.NS.envelope, in: light) == [0xEC, 0xE4, 0xD9])
        #expect(rgb(Palette.NS.ink, in: light) == [0x22, 0x1B, 0x16])
    }

    /// The stained glass is Escale's alone: in the neutral tone a glass
    /// tint is its surface's own colour.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func neutralGlassIsItsSurface(look: NSAppearance.Name) throws {
        let appearance = try #require(NSAppearance(named: look))
        #expect(rgb(Palette.NS.envelopeTint, in: appearance) == rgb(Palette.NS.envelope, in: appearance))
        #expect(rgb(Palette.NS.panelTint, in: appearance) == rgb(Palette.NS.panel, in: appearance))
    }

    /// A Colours sample resolves in the tone and look it was asked for,
    /// whatever the window wears, and hands the worn tone back.
    @Test func sampleLendsItsToneAndHandsItBack() {
        let light = Palette.NS.sample(Palette.NS.envelope, tone: .escale, dark: false)
        let dark = Palette.NS.sample(Palette.NS.envelope, tone: .escale, dark: true)
        #expect(Palette.tone == .neutral)
        #expect(srgb(light) == [0xEC, 0xE4, 0xD9])
        #expect(srgb(dark) == [0x16, 0x12, 0x0F])
        #expect(srgb(Palette.NS.sample(Palette.NS.ground, tone: .neutral, dark: false)) == [255, 255, 255])
    }

    /// A user's colour is theirs: a swatch or a space never changes with the tone.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func userColoursIgnoreTone(look: NSAppearance.Name) throws {
        let appearance = try #require(NSAppearance(named: look))
        let swatch = Palette.swatchColour(.blue, ink: true)
        let before = rgb(swatch, in: appearance)
        Palette.tone = .escale
        defer { Palette.tone = .neutral }
        #expect(rgb(swatch, in: appearance) == before)
    }

    /// Unconfigured and light, reading mode draws the greys it always drew.
    @Test func readerKeepsItsLightGreys() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast else { return }
        let dress = Reader.dress(look: .system, dark: false, width: .normal, size: 18)
        let old = ["ground": 255, "ink": 0x17, "quote": 0x55, "caption": 0xA3, "code": 0xF5, "rule": 0xE8]
        for (role, grey) in old {
            #expect(laid(dress[role], on: 255) == [grey, grey, grey], "\(role)")
        }
    }

    /// The bar's look wins over the window's; System follows it.
    @Test func readerFollowsTheChosenLook() {
        let colours = { (dress: [String: String]) in dress.filter { $0.key != "width" && $0.key != "scale" } }
        let light = colours(Reader.dress(look: .system, dark: false, width: .normal, size: 18))
        let dark = colours(Reader.dress(look: .system, dark: true, width: .normal, size: 18))
        #expect(light != dark)
        #expect(colours(Reader.dress(look: .light, dark: true, width: .normal, size: 18)) == light)
        #expect(colours(Reader.dress(look: .dark, dark: false, width: .normal, size: 18)) == dark)
    }

    /// Text, quotes and captions read on their ground in dark, and in both
    /// looks once contrast is increased.
    @Test(arguments: [(true, false), (true, true), (false, true)])
    func readerInksRead(dark: Bool, strong: Bool) {
        Palette.contrast = strong
        defer { Palette.contrast = false }
        let dress = Reader.dress(look: .system, dark: dark, width: .normal, size: 18)
        let ground = laid(dress["ground"], on: 0)
        for role in ["ink", "quote", "caption"] {
            let ink = laid(dress[role], on: ground.first ?? 0)
            #expect(contrast(ink, ground) >= (role == "ink" ? 7 : 4.5), "\(role)")
        }
    }

    /// A page colour (`rgba(r,g,b,a)`) laid on a grey, as the page draws it.
    private func laid(_ css: String?, on grey: Int) -> [Int] {
        let parts = (css ?? "").dropFirst(5).dropLast().split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return [] }
        return parts.prefix(3).map { Int(($0 * parts[3] + Double(grey) * (1 - parts[3])).rounded()) }
    }

    /// WCAG's contrast ratio between two sRGB colours.
    private func contrast(_ a: [Int], _ b: [Int]) -> Double {
        let luminance = { (rgb: [Int]) -> Double in
            let linear = rgb.map { (value: Int) -> Double in
                let c = Double(value) / 255
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            guard linear.count == 3 else { return 0 }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private func srgb(_ colour: NSColor) -> [Int] {
        guard let c = colour.usingColorSpace(.sRGB) else { return [] }
        return [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
    }

    /// Channels as 0–255 integers, so a hex value can be compared exactly.
    private func rgb(_ colour: NSColor, in appearance: NSAppearance) -> [Int] {
        var value: [Int] = []
        appearance.performAsCurrentDrawingAppearance {
            guard let c = colour.usingColorSpace(.sRGB) else { return }
            value = [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
        }
        return value
    }

    private func alpha(_ colour: NSColor, in appearance: NSAppearance) -> CGFloat {
        var value: CGFloat = -1
        appearance.performAsCurrentDrawingAppearance {
            value = colour.usingColorSpace(.sRGB)?.alphaComponent ?? -1
        }
        return value
    }
}
