// A shortcut stores its key and four modifiers, never a keyboard-layout-specific
// character for the number row. One normalization serves recording, collision
// checks and dispatch so a displayed binding cannot differ from the one taken.
import AppKit
import SwiftUI

struct KeyStroke: Hashable, Codable {
    let key: String
    let modifiers: UInt
    static let mask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    static let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 0]
    static let special: [UInt16: String] = [48: "tab", 36: "return", 76: "return", 53: "escape", 51: "delete", 117: "forwardDelete", 123: "left", 124: "right", 125: "down", 126: "up", 49: "space", 115: "home", 119: "end", 116: "pageUp", 121: "pageDown"]

    init(_ key: String, _ flags: NSEvent.ModifierFlags) {
        self.key = key
        modifiers = flags.intersection(Self.mask).rawValue
    }

    init?(_ event: NSEvent) {
        let key: String
        if let digit = Self.digits[event.keyCode] { key = "#\(digit)" }
        else if let special = Self.special[event.keyCode] { key = special }
        else if let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1 {
            // Shift changes these characters even in charactersIgnoringModifiers.
            key = ["+": "=", "{": "[", "}": "]", "_": "-" ][chars] ?? chars
        } else { return nil }
        self.init(key, event.modifierFlags)
    }

    var flags: NSEvent.ModifierFlags { .init(rawValue: modifiers) }
    var glyph: String {
        if key.hasPrefix("#") { return String(key.dropFirst()) }
        return ["tab": "⇥", "return": "↩", "escape": "⎋", "delete": "⌫", "forwardDelete": "⌦", "left": "←", "right": "→", "up": "↑", "down": "↓", "space": "Space", "home": "↖", "end": "↘", "pageUp": "⇞", "pageDown": "⇟"][key] ?? key.uppercased()
    }
    var label: String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + glyph
    }
    var searchText: String {
        label + " " + (flags.contains(.control) ? "control ctrl " : "") + (flags.contains(.option) ? "option alt " : "") + (flags.contains(.shift) ? "shift " : "") + (flags.contains(.command) ? "command cmd " : "") + key.replacingOccurrences(of: "#", with: "")
    }
    var menuKey: String {
        if key.hasPrefix("#") { return String(key.dropFirst()) }
        let codes: [String: UInt32] = ["left": 0xF702, "right": 0xF703, "up": 0xF700, "down": 0xF701, "home": 0xF729, "end": 0xF72B, "pageUp": 0xF72C, "pageDown": 0xF72D, "forwardDelete": 0xF728]
        if let code = codes[key], let scalar = UnicodeScalar(code) { return String(scalar) }
        return ["tab": "\t", "return": "\r", "escape": "\u{1b}", "delete": "\u{7f}", "space": " "][key] ?? key
    }
    var shortcut: KeyboardShortcut? {
        guard let character = menuKey.first else { return nil }
        var mods: EventModifiers = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.shift) { mods.insert(.shift) }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: mods)
    }

    /// These commands belong to the responder or the OS. A browser command
    /// must never turn copying, formatting, text selection or app switching into navigation.
    var refusal: String? {
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return "Include Command, Control or Option to keep typing available." }
        guard menuKey.count == 1, modifiers == flags.intersection(Self.mask).rawValue else { return "This key cannot be used as a shortcut." }
        if key == "escape" { return "Escape is reserved for cancelling the current interaction." }
        if flags.contains(.control), flags.contains(.option) { return "Control–Option is used by VoiceOver. Choose another combination." }
        if flags == .command, ["c", "x", "v", "a", "z", "b", "i", "u", "q", "h", "m", "tab", "`", "space", "left", "right", "up", "down"].contains(key) { return "This combination belongs to editing or macOS. Choose another shortcut." }
        if flags == .option || flags == [.option, .shift] {
            return "Option keys type characters or edit text. Include Command for a browser shortcut."
        }
        if (flags == .control || flags == [.control, .shift]), key.count == 1 {
            return "Control–character keys belong to text editing. Choose another shortcut."
        }
        if flags == [.command, .shift], ["z", "v", "left", "right", "up", "down", "#3", "#4", "#5"].contains(key) { return "This combination belongs to editing or macOS. Choose another shortcut." }
        if flags == [.command, .option], ["h", "escape", "space", "left", "right"].contains(key) { return "This combination belongs to macOS or text editing." }
        if flags == [.control, .command], ["f", "space", "q", "left", "right", "down"].contains(key) { return "This combination belongs to macOS or text editing." }
        if flags == .control, ["left", "right", "up", "down", "space"].contains(key) { return "Mission Control or input switching uses this shortcut." }
        return nil
    }
    var caution: String? {
        if flags == .control, key.hasPrefix("#") { return "Mission Control can take this shortcut first. You can change its assignment in macOS Keyboard Settings." }
        return nil
    }
}

struct KeyReference: Identifiable {
    let id: String
    let title: String
    let keys: String
    let owner: String
    let detail: String
    static let all = [
        KeyReference(id: "copy", title: "Copy, Cut, Paste", keys: "⌘C · ⌘X · ⌘V", owner: "Editing", detail: "Handled by the focused text field or web page."),
        KeyReference(id: "undo", title: "Undo and Redo", keys: "⌘Z · ⇧⌘Z", owner: "Editing", detail: "Handled by the editor. While hiding elements, Undo restores the last hidden element."),
        KeyReference(id: "select", title: "Select All", keys: "⌘A", owner: "Editing", detail: "Select content in the focused field or page."),
        KeyReference(id: "plainPaste", title: "Paste without Formatting", keys: "⇧⌘V", owner: "Editing", detail: "While typing. Outside an editor, Escale can use this for Paste and Go."),
        KeyReference(id: "text", title: "Move and Select Text", keys: "⌥ / ⌘ + arrows", owner: "Editing", detail: "Option moves by word; Command moves to an edge. Add Shift to select."),
        KeyReference(id: "focus", title: "Move Focus", keys: "⇥ · ⇧⇥", owner: "Context", detail: "Move between controls. In Bearings, Tab switches between its search and GitHub."),
        KeyReference(id: "environments", title: "Choose a Bookmark Environment", keys: "← · →", owner: "Context", detail: "In Bearings, on a bookmark row: the current environment is ringed when you reach it, and both arrows move between them."),
        KeyReference(id: "escape", title: "Cancel or Close", keys: "⎋", owner: "Context", detail: "Dismiss the current editor, popover or panel, one level at a time."),
        KeyReference(id: "choose", title: "Choose and Open a Result", keys: "↑ · ↓ · ↩", owner: "Context", detail: "Navigate suggestions or lists, then open the selection."),
        KeyReference(id: "quit", title: "Quit Escale", keys: "⌘Q", owner: "macOS", detail: "Application menu command, managed by macOS."),
        KeyReference(id: "hide", title: "Hide and Minimize", keys: "⌘H · ⌘M", owner: "macOS", detail: "Application and window commands, managed by macOS."),
        KeyReference(id: "apps", title: "Switch Applications", keys: "⌘⇥", owner: "macOS", detail: "Global shortcut. Escale cannot override it."),
        KeyReference(id: "desktops", title: "Switch macOS Desktops", keys: "⌃← · ⌃→", owner: "macOS", detail: "Mission Control’s desktops, separate from Escale Spaces. Configure in macOS Keyboard Settings."),
        KeyReference(id: "spotlight", title: "Spotlight", keys: "⌘Space", owner: "macOS", detail: "Global shortcut, configured in macOS Keyboard Settings."),
        KeyReference(id: "screenshots", title: "macOS Screenshots", keys: "⇧⌘3 / 4 / 5", owner: "macOS", detail: "System capture tools, configured in macOS Keyboard Settings."),
        KeyReference(id: "fullscreen", title: "Full Screen", keys: "⌃⌘F", owner: "macOS", detail: "Window command, managed by macOS."),
    ]
}
