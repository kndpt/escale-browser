import AppKit
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
//
// The keys are watched on the window while the list is on screen, and only
// then, not through SwiftUI's focus: the page under the panel taking the
// keyboard back took that focus and every key with it (docs/ARCHITECTURE.md).
// The panel stands over the page, so here the page does not keep the arrows.

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
    /// its key to whoever has the keyboard: History's field keeps ⌫ and ← →
    /// for its text.
    func walking(move: @escaping (Int) -> Void, open: @escaping (_ apart: Bool) -> Void,
                 remove: (() -> Void)?, fold: ((_ open: Bool) -> Void)? = nil,
                 while on: @escaping () -> Bool) -> some View {
        background(WalkKeys(keys: WalkKeys.Keys(on: on, move: move, open: open, remove: remove, fold: fold)))
    }
}

private struct WalkKeys: NSViewRepresentable {
    struct Keys {
        let on: () -> Bool
        let move: (Int) -> Void
        let open: (_ apart: Bool) -> Void
        let remove: (() -> Void)?
        let fold: ((_ open: Bool) -> Void)?

        /// Whether the key was the list's. Held, only the arrows go on: a
        /// held Return or ⌫ acts once.
        func take(_ event: NSEvent) -> Bool {
            guard on() else { return false }
            let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
            let once = !event.isARepeat
            switch (event.keyCode, flags) {
            case (125, []): move(1)
            case (126, []): move(-1)
            case (36, []), (76, []), (36, .command), (76, .command):
                if once { open(flags == .command) }
            case (51, []):
                guard let remove else { return false }
                if once { remove() }
            case (123, []), (124, []):
                guard let fold else { return false }
                fold(event.keyCode == 124)
            default: return false
            }
            return true
        }
    }

    let keys: Keys

    func makeNSView(context: Context) -> Watch { Watch() }
    func updateNSView(_ view: Watch, context: Context) { view.keys = keys }
    static func dismantleNSView(_ view: Watch, coordinator: ()) { view.stop() }

    final class Watch: NSView {
        var keys: Keys?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      self.keys?.take(event) == true else { return event }
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
