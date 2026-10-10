import AppKit

// The popover that is open, such as the bookmarks dropdown: its size, and a
// click at a point of it sent through the app's own event dispatch, which
// SwiftUI's buttons need. The real pointer is never moved and the app is not
// brought forward, so a scenario run behind other windows can use it. SwiftUI
// keeps its controls out of the app's own accessibility tree until an
// assistive app asks, so a point is the way in. Test worlds only.

@MainActor
enum PopoverBench {
    static func run(_ request: [String: Any], answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "popover needs a test world"]); return }
        guard let window = NSApp.windows.first(where: { $0.isVisible && "\(type(of: $0))".contains("Popover") }) else {
            answer(["open": false]); return
        }
        let size = [Int(window.frame.width), Int(window.frame.height)]
        guard let x = request["x"] as? Double, let y = request["y"] as? Double else {
            answer(["open": true, "size": size]); return
        }
        guard x >= 0, y >= 0, x <= window.frame.width, y <= window.frame.height else {
            answer(["error": "that point is outside the popover"]); return
        }
        // Points from the top left, as `hit` takes them.
        let point = NSPoint(x: x, y: window.frame.height - y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            ) else { continue }
            NSApp.sendEvent(event)
        }
        Bench.afterRests(2) { answer(["open": window.isVisible, "size": size]) }
    }
}
