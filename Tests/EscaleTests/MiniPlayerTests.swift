// When the mini player shows its full set of commands. Hover reveals them for a
// pointer; VoiceOver and keyboard-only use have none, so they need them drawn.
// What the accessibility tree then holds is checked against the real app.

import Testing
@testable import Escale

struct MiniPlayerTests {
    @Test func aPointerExpandsTheCardByHoverOrByTheOpenChooser() {
        #expect(!MiniPlayer.expands(hovered: false, choosingSource: false, assistive: false))
        #expect(MiniPlayer.expands(hovered: true, choosingSource: false, assistive: false))
        #expect(MiniPlayer.expands(hovered: false, choosingSource: true, assistive: false))
    }

    @Test func voiceOverAndKeyboardOnlyUseKeepEveryCommandReachable() {
        #expect(MiniPlayer.expands(hovered: false, choosingSource: false, assistive: true))
    }
}
