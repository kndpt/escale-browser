// A command carries its input through SwiftUI's transaction: rendering can
// happen after AppKit has moved on to keyUp or a mouse event. Only the named
// tab/layout transitions use this pace; hover and drag keep their own curves.
import AppKit
import SwiftUI

extension Motion {
    struct Shortcut: TransactionKey {
        static let defaultValue = false
    }

    /// Read at the action, never when a view happens to redraw.
    @MainActor static var fromKeyboard: Bool { NSApp.currentEvent?.type == .keyDown }

    static func shortcutSpeed(keyboard: Bool, enabled: Bool, reduced: Bool) -> Double? {
        reduced ? nil : (keyboard && enabled ? shortcutMultiplier : 1)
    }

    static func shortcutAnimation(_ animation: Animation, keyboard: Bool,
                                  enabled: Bool, reduced: Bool) -> Animation? {
        shortcutSpeed(keyboard: keyboard, enabled: enabled, reduced: reduced).map { animation.speed($0) }
    }

    static func applyShortcut(_ animation: Animation, to transaction: inout Transaction,
                              enabled: Bool, reduced: Bool) {
        // Accessibility also cancels an inherited explicit animation; merely
        // refusing new implicit animations would leave that one running.
        if reduced {
            transaction.animation = nil
            transaction.disablesAnimations = true
        } else if !transaction.disablesAnimations {
            transaction.animation = shortcutAnimation(animation,
                keyboard: transaction[Shortcut.self], enabled: enabled, reduced: false)
        }
    }

    @MainActor static func command<Result>(_ action: () -> Result) -> Result {
        var transaction = Transaction()
        transaction[Shortcut.self] = fromKeyboard
        return withTransaction(transaction, action)
    }
}

extension View {
    /// Like animation(value:), with the command's input kept until rendering.
    func shortcutAnimation<Value: Equatable>(_ animation: Animation, value: Value,
                                             enabled: Bool, reduced: Bool) -> some View {
        transaction(value: value) { transaction in
            Motion.applyShortcut(animation, to: &transaction, enabled: enabled, reduced: reduced)
        }
    }
}
