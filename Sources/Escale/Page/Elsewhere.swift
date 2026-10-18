import AppKit
import SwiftUI

// Open Page In: the address handed to another browser on this Mac.
//
// The list is macOS's own: the apps that say they open web addresses
// (`urlsForApplications(toOpen:)`). It answers by scheme, so one question
// serves every page, and it is asked only as a menu opens — the page's, or
// the menu bar as it starts to be used — a millisecond or two, nothing in
// between. Every copy of Escale is left out, this one, the installed one
// and the test worlds alike: handing the page to itself is no handoff.
//
// Only the address goes. The other browser opens it with its own cookies
// and sessions; nothing of Escale's is passed along.
//
// On a link, the link goes instead. WebKit knows which link was clicked but
// tells no one, so its own Open Link in New Window is asked, and the window
// it then wants is taken as an address before any view is made (Browser,
// `createWebViewWith`).

@MainActor
final class Elsewhere: ObservableObject {
    static let shared = Elsewhere()

    struct Choice: Equatable {
        let app: URL
        let name: String
    }

    /// For the menu bar, asked again each time it starts to be used.
    @Published private(set) var choices: [Choice] = []
    /// Each app's icon, made once: about 2 ms apiece to make.
    private var icons: [URL: NSImage] = [:]
    private var watch: Any?

    private init() {
        // SwiftUI brings the menu bar up to date as it starts to be tracked;
        // the list is asked first, so that update has it.
        watch = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                guard (note.object as? NSMenu) === NSApp.mainMenu else { return }
                Elsewhere.shared.refresh()
            }
        }
    }

    private func refresh() {
        let fresh = Elsewhere.lookup()
        if fresh != choices { choices = fresh }
    }

    /// Every app but Escale, once each, by name.
    nonisolated static func pick(_ apps: [(app: URL, id: String?)], own: String?) -> [Choice] {
        var seen = Set<String>()
        return apps.compactMap { app, id in
            guard let id = id?.lowercased(), !isEscale(id, own: own?.lowercased()), seen.insert(id).inserted else { return nil }
            return Choice(app: app, name: app.deletingPathExtension().lastPathComponent)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated static func isEscale(_ id: String, own: String?) -> Bool {
        id == own || id == "com.kndpt.escale" || id.hasPrefix("com.kndpt.escale.")
    }

    nonisolated static func opens(_ url: URL?) -> Bool {
        url?.scheme == "http" || url?.scheme == "https"
    }

    private static func lookup() -> [Choice] {
        guard let web = URL(string: "https:") else { return [] }
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: web)
        return pick(apps.map { ($0, Bundle(url: $0)?.bundleIdentifier) }, own: Bundle.main.bundleIdentifier)
    }

    static func open(_ url: URL, in app: URL) {
        guard opens(url) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func icon(_ app: URL) -> NSImage {
        if let icon = icons[app] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: Metrics.menuIcon, height: Metrics.menuIcon)
        icons[app] = icon
        return icon
    }

    // MARK: The page's menu

    /// Put after WebKit's Open Link in New Window on a link, after Reload on
    /// the page; anywhere else, as on selected text, the menu has no address.
    func offer(in menu: NSMenu, page: PageView) {
        let ids = menu.items.map { $0.identifier?.rawValue }
        if let index = ids.firstIndex(of: "WKMenuItemIdentifierOpenLinkInNewWindow") {
            let source = menu.items[index]
            add("Open Link In", to: menu, at: index + 1) { [weak page] app in
                guard let page, let action = source.action else { return }
                page.takeLink = { Elsewhere.open($0, in: app) }
                NSApp.sendAction(action, to: source.target, from: source)
                // WebKit answers within moments; a link it never asks about
                // must not take the page's next window.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak page] in page?.takeLink = nil }
            }
        } else if let index = ids.firstIndex(of: "WKMenuItemIdentifierReload"), let url = page.url, Elsewhere.opens(url) {
            add("Open Page In", to: menu, at: index + 1) { Elsewhere.open(url, in: $0) }
        }
    }

    private func add(_ title: String, to menu: NSMenu, at index: Int, take: @escaping (URL) -> Void) {
        refresh()
        guard !choices.isEmpty else { return }
        let sub = NSMenu(title: title)
        for choice in choices {
            let action = Action { take(choice.app) }
            let item = NSMenuItem(title: choice.name, action: #selector(Action.fire), keyEquivalent: "")
            item.target = action
            item.representedObject = action
            item.image = icon(choice.app)
            sub.addItem(item)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        menu.insertItem(item, at: index)
    }

    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }
}

/// Open Page In, in the menu bar's Tabs menu: absent with no web page or no
/// other browser.
struct ElsewhereMenu: View {
    let address: URL?
    @ObservedObject private var elsewhere = Elsewhere.shared

    var body: some View {
        if let address, Elsewhere.opens(address), !elsewhere.choices.isEmpty {
            Menu("Open Page In") {
                ForEach(elsewhere.choices, id: \.app) { choice in
                    Button { Elsewhere.open(address, in: choice.app) } label: {
                        Label { Text(choice.name) } icon: { Image(nsImage: elsewhere.icon(choice.app)) }
                    }
                }
            }
        }
    }
}
