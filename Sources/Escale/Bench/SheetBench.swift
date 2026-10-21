import AppKit

// The sheet on the browser's window, such as a page's alert: what it says,
// its buttons and whether it offers to stop the page asking; or one of its
// buttons pressed, that box ticked first when asked. Both are pressed through
// their own action, as Space or Return would, so a scenario run behind other
// windows needs neither the pointer nor the keyboard. Test worlds only.

@MainActor
enum SheetBench {
    static func run(_ request: [String: Any], answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "sheet needs a test world"]); return }
        guard let content = Links.window?.attachedSheet?.contentView else { answer(["shown": false]); return }
        let views = all(in: content)
        let buttons = views.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
        let stop = buttons.first { $0.title == Dialogs.stopAsking }
        let pushes = buttons.filter { $0 !== stop }
        guard let press = request["press"] as? String else {
            let texts = views.compactMap { $0 as? NSTextField }.filter { !$0.isEditable && !$0.isHidden }.map(\.stringValue)
            answer(["shown": true, "texts": texts, "buttons": pushes.map(\.title), "stop": stop != nil])
            return
        }
        guard let button = pushes.first(where: { $0.title == press }) else {
            answer(["error": "no button “\(press)” on the sheet"]); return
        }
        if request["stop"] as? Bool == true {
            guard let stop else { answer(["error": "this sheet doesn't offer to stop the page"]); return }
            if stop.state != .on { stop.performClick(nil) }
        }
        button.performClick(nil)
        Bench.afterRests(2) { answer(["pressed": press]) }
    }

    private static func all(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + all(in: $0) }
    }
}
