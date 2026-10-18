import AppKit
import WebKit

// Escale's own entries in a link's right-click menu: Open Link in Split View
// and Copy Link as Markdown.
//
// WebKit names the link under the pointer to its own menu items only; no
// public API tells the app. The page knows, and its contextmenu event comes
// before WebKit asks for the menu, so a listener in Escale's script world, in
// every frame, names the link (or none) on each right-click, and the view
// keeps it until its menu opens. A page can't read that world or post to it,
// and nothing is sent but on a right-click.

enum LinkChoice: Int { case split = 1, markdown }

/// The link under the last right-click, as the page named it.
struct MenuLink {
    let url: URL
    let text: String
}

final class LinkRelay: NSObject, WKScriptMessageHandler {
    static let name = "escaleLinkMenu"
    static let watch = Bundled.script("link-watch.js")
    /// It keeps nothing of its own: what it hears goes to the view it came from.
    static let shared = LinkRelay()

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any]
        let link = (body?["href"] as? String).flatMap(URL.init(string:)).map {
            MenuLink(url: $0, text: body?["text"] as? String ?? "")
        }
        MainActor.assumeIsolated { (message.webView as? PageView)?.rightClicked = link }
    }
}

extension PageView {
    /// After WebKit's entries and before the extensions', so Escale's stay together.
    func addLinkItems(to menu: NSMenu) {
        guard let link = rightClicked else { return }
        // Taken, so a menu opened with nothing named for it never shows the last link.
        rightClicked = nil
        menu.addItem(.separator())
        // A split holds web pages, as a middle-click opens only those.
        if ["http", "https"].contains(link.url.scheme?.lowercased() ?? "") {
            menu.addItem(linkItem("Open Link in Split View", .split, link))
        }
        menu.addItem(linkItem("Copy Link as Markdown", .markdown, link))
    }

    private func linkItem(_ title: String, _ choice: LinkChoice, _ link: MenuLink) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(chooseLink(_:)), keyEquivalent: "")
        item.target = self
        item.tag = choice.rawValue
        item.representedObject = link
        return item
    }

    @objc private func chooseLink(_ item: NSMenuItem) {
        guard let link = item.representedObject as? MenuLink, let choice = LinkChoice(rawValue: item.tag) else { return }
        onLinkChoice?(choice, link)
    }
}

extension Browser {
    func chose(_ choice: LinkChoice, _ link: MenuLink, on page: Tab) {
        switch choice {
        case .split: openInSplit(link.url, beside: page)
        case .markdown:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Browser.markdownLink(link.text, to: link.url), forType: .string)
            announce("Link copied")
        }
    }
}
