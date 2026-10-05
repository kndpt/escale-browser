// Split observations read mounted views and value identities only. Mutations
// reuse the production actions and are admitted exclusively in disposable test
// worlds. Scenarios assert the results; the socket never decides a test passed.
import AppKit

@MainActor
enum PanelBench {
    static func state(_ browser: Browser) -> [String: Any] {
        let panels = browser.panels
        func rect(_ value: CGRect) -> [Double] { [value.minX, value.minY, value.width, value.height] }
        return [
            "foreground": NSApp.isActive,
            "firstResponder": Links.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "",
            "inspector": browser.inspection.visibleTab?.uuidString ?? "",
            "inspectorFailure": browser.inspection.failure,
            "groups": panels.groups.map { group -> [String: Any] in
                ["id": group.id.uuidString, "members": group.members.map(\.uuidString),
                 "active": group.active.uuidString, "horizontal": group.horizontal, "weights": group.weights]
            },
            "preview": panels.preview?.rawValue ?? "", "frame": rect(panels.frame),
            "carrying": panels.carrying?.uuidString ?? "", "lifted": panels.lift.point != nil,
            "tools": panels.toolsShown?.uuidString ?? "",
            "focusWatching": panels.focusWatching,
            "entries": panels.entries.map { ["id": $0.key.uuidString, "frame": rect($0.value)] },
            "visible": browser.panelTabs.map { $0.id.uuidString },
            "pages": browser.tabs.map { tab -> [String: Any] in
                var result: [String: Any] = ["id": tab.id.uuidString,
                    "lastViewed": tab.touched.timeIntervalSince1970,
                    "bookmark": browser.shelfTabs[tab.id]?.uuidString ?? "",
                    "page": tab.built.map { String(describing: ObjectIdentifier($0)) } ?? ""]
                if let page = tab.built, let window = page.window {
                    let frame = page.convert(page.bounds, to: nil)
                    result["frame"] = rect(CGRect(x: frame.minX, y: window.frame.height - frame.maxY,
                                                  width: frame.width, height: frame.height))
                }
                return result
            }
        ]
    }

    static func run(_ request: [String: Any], browser: Browser) -> [String: Any] {
        guard Store.testing else { return ["error": "panels needs an isolated test world"] }
        let action = request["action"] as? String ?? "state"
        guard action != "state" else { return state(browser) }
        guard let id = request["id"] as? String,
              let tab = (browser.tabs + browser.parkedTabs).first(where: { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) }) else { return ["error": "no panel tab"] }
        let panels = browser.panels
        switch action {
        case "add":
            guard let text = request["target"] as? String,
                  let target = browser.tabs.first(where: { $0.id.uuidString.lowercased().hasPrefix(text.lowercased()) }),
                  let edge = (request["edge"] as? String).flatMap(PanelEdge.init(rawValue:)) else { return ["error": "add needs target and edge"] }
            let accepted = browser.split(tab, with: target, edge: edge)
            return state(browser).merging(["accepted": accepted]) { _, new in new }
        case "separate": browser.changePanels(tab) { $0.separate(tab.id) }
        case "remove": browser.changePanels(tab) { $0.remove(tab.id) }
        case "turn": browser.changePanels(tab) { $0.turn(tab.id) }
        case "reverse": browser.changePanels(tab) { $0.reverse(tab.id) }
        case "close": browser.close(tab)
        case "tools": panels.toolsShown = panels.toolsShown == tab.id ? nil : tab.id
        default: return ["error": "unknown panel action"]
        }
        return state(browser)
    }
}
