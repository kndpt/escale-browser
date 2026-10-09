import SwiftUI

// The keyboard in a panel's list: History, Downloads and Bookmarks. ↑ and ↓
// move one selection, Return opens it as a click does and ⌘Return apart, ⌫
// takes it off the list; a bookmark folder opens with → and closes with ←.
// Escape stays the window's (App.swift), which closes the panel.
//
// The selection is a row's id, not its place, so it stays on its row while
// the list changes around it, and goes back to the top once its row is no
// longer listed. VoiceOver is told each row it lands on: History's keyboard
// stays in its search field, where nothing else would say it.

enum Walk {
    /// The row `by` steps from `from`, held within the list: the top when
    /// nothing listed was chosen, nil for an empty list.
    static func step<ID: Equatable>(_ ids: [ID], from: ID?, by: Int) -> ID? {
        guard let first = ids.first else { return nil }
        guard let from, let at = ids.firstIndex(of: from) else { return first }
        return ids[min(max(at + by, 0), ids.count - 1)]
    }

    /// The row that takes `gone`'s place once it is removed: the next one,
    /// or the one before at the end of the list.
    static func after<ID: Equatable>(_ ids: [ID], removing gone: ID) -> ID? {
        guard let at = ids.firstIndex(of: gone) else { return nil }
        if at + 1 < ids.count { return ids[at + 1] }
        return at > 0 ? ids[at - 1] : nil
    }

    static func say(_ row: String) {
        AccessibilityNotification.Announcement(row).post()
    }
}

extension View {
    /// The keys of a panel's list, `while` it wants them. A nil action leaves
    /// its key to the view that has the focus: History's field keeps ⌫ and
    /// ← → for its text.
    func walking(move: @escaping (Int) -> Void, open: @escaping (_ apart: Bool) -> Void,
                 remove: (() -> Void)?, fold: ((_ open: Bool) -> Void)? = nil, while on: Bool = true) -> some View {
        onKeyPress(phases: [.down, .repeat]) { press in
            guard on else { return .ignored }
            // Held, only the arrows go on: a held Return or ⌫ acts once.
            let once = press.phase == .down
            switch press.key {
            case .downArrow: move(1)
            case .upArrow: move(-1)
            case .return: if once { open(press.modifiers.contains(.command)) }
            // ⌫ types U+007F on a Mac; SwiftUI's `.delete` is U+0008.
            case KeyEquivalent("\u{7F}"):
                guard let remove else { return .ignored }
                if once { remove() }
            case .rightArrow, .leftArrow:
                guard let fold else { return .ignored }
                fold(press.key == .rightArrow)
            default: return .ignored
            }
            return .handled
        }
    }
}
