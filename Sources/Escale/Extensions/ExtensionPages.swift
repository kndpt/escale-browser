import AppKit
import WebKit

// What an extension shows or reaches in the window: the side panel as a
// tab, offscreen documents, its button's popup, tabs by their place in the
// row, tab groups (there are none) and search.

@available(macOS 15.4, *)
extension ExtensionShims {
    static func pages(_ asked: Asked) async throws -> Any? {
        let api = asked.api
        let args = asked.args
        let first = asked.first
        let scope = asked.scope
        let browser = asked.browser
        let context = asked.context
        let owner = asked.owner
        switch api {
        // MARK: side panel — a tab of its own, since this window has one column
        case "sidePanel.setOptions":
            if let path = (first as? [String: Any])?["path"] as? String { panelPath[scope] = path }
            return nil
        case "sidePanel.getOptions":
            return ["enabled": true, "path": panelPath[scope] ?? defaultPanel(context) ?? ""]
        case "sidePanel.setPanelBehavior":
            if let on = (first as? [String: Any])?["openPanelOnActionClick"] as? Bool {
                if on { panelOnClick.insert(scope) } else { panelOnClick.remove(scope) }
            }
            return nil
        case "sidePanel.getPanelBehavior":
            return ["openPanelOnActionClick": panelOnClick.contains(scope)]
        case "sidePanel.open":
            openPanel(context, owner: owner)
            return nil

        // MARK: offscreen — a page with a DOM for a worker that has none
        case "offscreen.createDocument":
            guard offscreen[scope] == nil else { throw Unsupported(what: "Only a single offscreen document may be created.") }
            guard let path = (first as? [String: Any])?["url"] as? String,
                  let configuration = context.webViewConfiguration
            else { throw Unsupported(what: "No page for the offscreen document") }
            let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            page.load(URLRequest(url: context.baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))))
            offscreen[scope] = page
            // Answered once the page has loaded, as Chrome does: the worker's
            // next line is a message to it, and a page still loading has no
            // one listening yet.
            for _ in 0..<250 where page.isLoading || page.url == nil {
                try? await Task.sleep(for: .milliseconds(20))
            }
            return nil
        case "offscreen.closeDocument":
            offscreen[scope] = nil
            return nil
        case "offscreen.hasDocument":
            return offscreen[scope] != nil

        // MARK: the button's popup
        case "action.popup":
            let path = first as? String ?? ""
            let index = args.dropFirst().first as? Int ?? -1
            if index >= 0, owner.visibleTabs.indices.contains(index) {
                popups[scope, default: [:]][owner.visibleTabs[index].id.uuidString] = path
            } else {
                popups[scope, default: [:]]["*"] = path
                popups[scope] = popups[scope]?.filter { $0.key == "*" }
            }
            return nil

        // MARK: tabs, by where they are in the row
        case "tabs.describe":
            let visible = owner.visibleTabs
            return ((first as? [Int]) ?? []).map { index -> Any in
                guard visible.indices.contains(index) else { return NSNull() }
                return ["url": visible[index].address?.absoluteString ?? "", "title": visible[index].title]
            }
        case "tabs.move", "tabs.discard", "tabs.activate":
            guard browser.spaceID == owner.here else { throw Unsupported(what: "This space is parked") }
            let visible = owner.visibleTabs
            guard let from = first as? Int, visible.indices.contains(from) else { throw Unsupported(what: "No tab there") }
            let tab = visible[from]
            switch api {
            case "tabs.move":
                let wanted = args.dropFirst().first as? Int ?? -1
                let target = visible[wanted < 0 || wanted >= visible.count ? visible.count - 1 : wanted]
                if let index = browser.tabs.firstIndex(where: { $0.id == target.id }) { browser.move(tab, to: index) }
            case "tabs.discard":
                if tab.id != browser.activeID { browser.sleep(tab) }
            default:
                browser.select(tab)
            }
            return nil

        // MARK: search
        case "search.query":
            guard browser.spaceID == owner.here else { throw Unsupported(what: "This space is parked") }
            let spec = first as? [String: Any] ?? [:]
            // Chrome sends it to the default engine: a person's keywords are for what they type.
            let text = spec["text"] as? String ?? ""
            guard let url = Address.url(from: text) ?? browser.searchURL(for: text) else { return nil }
            switch spec["disposition"] as? String {
            case "NEW_TAB", "NEW_WINDOW": browser.open(url, foreground: true)
            default: browser.visit(url)
            }
            return nil

        // MARK: tab groups — there are none
        case "tabGroups.query":
            return []
        case "tabGroups.get", "tabGroups.update", "tabGroups.move":
            throw Unsupported(what: "Escale has no tab groups")

        default:
            throw unknown(api)
        }
    }

    static func defaultPanel(_ context: WKWebExtensionContext) -> String? {
        (context.webExtension.manifest["side_panel"] as? [String: Any])?["default_path"] as? String
    }

    static func openPanel(_ context: WKWebExtensionContext, owner: Extensions) {
        guard owner.browser?.spaceID == owner.here else { return }
        guard let path = panelPath[owner.scope(context.uniqueIdentifier)] ?? defaultPanel(context) else { return }
        let url = context.baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        owner.browser?.open(url, foreground: true)
    }
}
