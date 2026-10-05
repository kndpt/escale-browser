// Input and accessibility choose a pace independently of SwiftUI's rendering
// time. A mouse action must never inherit the previous keyboard command.
import SwiftUI
import Testing
@testable import Escale

@Suite struct ShortcutMotionTests {
    @Test(arguments: [false, true], [false, true])
    func pace(keyboard: Bool, enabled: Bool) {
        #expect(Motion.shortcutSpeed(keyboard: keyboard, enabled: enabled, reduced: false) == (keyboard && enabled ? 3 : 1))
        #expect(Motion.shortcutSpeed(keyboard: keyboard, enabled: enabled, reduced: true) == nil)
        #expect(Motion.shortcutAnimation(Motion.glide, keyboard: keyboard, enabled: enabled, reduced: true) == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func accessibilityCancelsInheritedMotion(enabled: Bool, alreadyDisabled: Bool) {
        var transaction = Transaction(animation: Motion.settle)
        transaction[Motion.Shortcut.self] = true
        transaction.disablesAnimations = alreadyDisabled
        Motion.applyShortcut(Motion.glide, to: &transaction, enabled: enabled, reduced: true)
        #expect(transaction.animation == nil)
        #expect(transaction.disablesAnimations)
    }

    @Test func ordinaryTransactionsDoNotInheritShortcuts() {
        var keyboard = Transaction()
        keyboard[Motion.Shortcut.self] = true
        #expect(keyboard[Motion.Shortcut.self])
        #expect(!Transaction()[Motion.Shortcut.self])
        #expect(Motion.shortcutAnimation(Motion.glide, keyboard: true, enabled: true, reduced: false) == Motion.glide.speed(3))
        #expect(Motion.shortcutAnimation(Motion.glide, keyboard: false, enabled: true, reduced: false) == Motion.glide.speed(1))
    }
}
