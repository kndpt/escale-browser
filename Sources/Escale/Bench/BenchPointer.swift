// Native control regressions need the event queue: calling a view's mouseDown
// directly does not reproduce an NSMenu's tracking loop. This test-only driver
// posts pointer events to this process and observes the actual tracking menu.
// Nothing is installed until a test asks, and stop releases its observers.
import AppKit

@MainActor
enum BenchPointer {
    private static weak var menu: NSMenu?
    private static var observers: [NSObjectProtocol] = []
    /// The view under the last press, for a press that opened nothing.
    private static var pressed = ""

    static func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        menu = nil
    }

    static func perform(_ request: [String: Any], answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing, let window = Links.window else {
            answer(["error": "pointer only works in a test world"]); return
        }
        if observers.isEmpty {
            observers = [
                NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
                    MainActor.assumeIsolated { menu = note.object as? NSMenu }
                },
                NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { note in
                    MainActor.assumeIsolated {
                        if let ended = note.object as? NSMenu, ended === menu { menu = nil }
                    }
                }
            ]
        }
        let action = request["action"] as? String ?? "state"
        if action == "state" { answer(state()); return }
        if action == "choose" {
            guard let menu, let index = request["index"] as? Int, menu.items.indices.contains(index), menu.items[index].isEnabled else {
                answer(["error": "no enabled native menu item at that index"]); return
            }
            menu.performActionForItem(at: index)
            menu.cancelTracking()
            closed(answer)
            return
        }
        if action == "cancel" {
            menu?.cancelTracking()
            closed(answer)
            return
        }
        guard ["click", "hold", "move"].contains(action),
              let x = request["x"] as? Double, let y = request["y"] as? Double,
              x.isFinite, y.isFinite, x >= 0, y >= 0,
              x <= window.frame.width, y <= window.frame.height,
              let screen = NSScreen.screens.first else { answer(["error": "pointer needs action and X Y"]); return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // CG coordinates start at the top left of the main display.
        let point = CGPoint(x: window.frame.minX + x, y: screen.frame.maxY - window.frame.maxY + y)
        CGWarpMouseCursorPosition(point)
        func post(_ type: NSEvent.EventType) {
            let local = NSPoint(x: point.x - window.frame.minX,
                y: screen.frame.maxY - point.y - window.frame.minY)
            guard let event = NSEvent.mouseEvent(with: type, location: local, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1) else { return }
            NSApp.postEvent(event, atStart: false)
        }
        post(.mouseMoved)
        // Each answer comes once its events have been through the app and
        // the run loop has rested: a state, not a guess at how long that takes.
        let settled = { Bench.afterQueue { Bench.afterRests(2) { answer(state()) } } }
        // Only arrive: for a control drawn under the pointer, before its press.
        // Hover comes from the window server, not from the event posted here,
        // and nothing in the app says it has come: this one keeps its 0.3 s.
        if action == "move" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled() }
            return
        }
        // The press comes once the arrival has been through the app, as a
        // hand's does: pressed in the same turn, after a layout change (a new
        // appearance, a folded column), it could reach the view that was
        // under the point before, and a held button opened no menu.
        Bench.afterQueue { Bench.afterRests(2) { press() } }
        func press() {
            // A menu chosen from or cancelled a moment ago can still be named
            // here until its end of tracking arrives; only one this press opens counts.
            menu = nil
            let frame = window.contentView?.superview
            let local = NSPoint(x: x, y: window.frame.height - y)
            pressed = frame.flatMap { $0.hitTest($0.convert(local, from: nil)) }.map { String("\(type(of: $0))".prefix(60)) } ?? ""
            post(.leftMouseDown)
            guard action == "hold" else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { post(.leftMouseUp); settled() }
                return
            }
            // A hold outlasts SwiftUI's long-press threshold, so the menu opens;
            // the hand lets go once it has, or after 1.5 s if it never does (a
            // busy Mac can open it late; a disabled button never does).
            let limit = CACurrentMediaTime() + 1.5
            func held() {
                guard menu == nil, CACurrentMediaTime() < limit else {
                    post(.leftMouseUp)
                    // An open menu's tracking loop takes the release itself and
                    // leaves the marker queued behind it until the menu closes.
                    if menu != nil { Bench.afterRests(2) { answer(state()) } } else { settled() }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { held() }
            }
            held()
        }
    }

    /// The answer once the menu's tracking has ended: a press sent while it
    /// is still closing goes to it, and never opens the next one.
    private static func closed(_ answer: @escaping ([String: Any]) -> Void) {
        Bench.within(1, until: { menu == nil }) { Bench.afterRests(2) { answer(state()) } }
    }

    private static func state() -> [String: Any] {
        ["active": NSApp.isActive, "pressed": pressed,
         "windowNumber": Links.window?.windowNumber ?? 0,
         "tracking": menu != nil, "items": menu?.items.map {
            var row: [String: Any] = ["title": $0.title, "enabled": $0.isEnabled]
            if #available(macOS 14.4, *) { row["subtitle"] = $0.subtitle ?? "" }
            return row
        } ?? []]
    }
}
