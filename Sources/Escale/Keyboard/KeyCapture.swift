// Recording exists only while a Keyboard row is open. App's existing monitor
// offers events here first, including application shortcuts: pressing a candidate
// must never execute it. A weak pointer cannot keep a dismissed Settings page alive.
import AppKit
import SwiftUI

@MainActor final class KeyCapture: ObservableObject {
    static weak var current: KeyCapture?
    @Published var action: KeyAction?
    @Published var candidate: KeyStroke?
    @Published var message: String?
    @Published var extensionName: String?
    @Published var commitRequest = 0
    var restoring = false

    func begin(_ action: KeyAction) {
        Self.current?.cancel()
        self.action = action
        candidate = nil; message = nil; extensionName = nil; restoring = false
        Self.current = self
    }
    func cancel() {
        if Self.current === self { Self.current = nil }
        action = nil; candidate = nil; message = nil; extensionName = nil; restoring = false
    }
    func take(_ event: NSEvent) -> Bool {
        guard action != nil, event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(KeyStroke.mask)
        if flags.isEmpty, event.keyCode == 53 { cancel(); return true }
        if flags.subtracting(.shift).isEmpty, event.keyCode == 48 { cancel(); return false }
        if flags.isEmpty, event.keyCode == 36 { commitRequest += 1; return true }
        guard let stroke = KeyStroke(event) else { message = "Try a letter, number or navigation key with a modifier."; return true }
        candidate = stroke; restoring = false
        message = action?.command.defaults.contains(stroke) == true ? nil : stroke.refusal
        extensionName = nil
        if #available(macOS 15.4, *) {
            if let context = Extensions.shared.contexts.values.first(where: { $0.command(for: event) != nil }) {
                extensionName = context.webExtension.displayName ?? "an extension"
            }
        }
        return true
    }
}
