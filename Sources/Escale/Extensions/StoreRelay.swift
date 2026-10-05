import Combine
import WebKit

// The Chrome Web Store, made to work for this browser.
//
// The store sees a browser that isn't Chrome and says so: a banner asking to
// "Switch to Chrome", and an "Add to Chrome" button that stays grey. Escale
// installs from the store on its own (Extensions.install, through Crx), so on
// the store's pages the banner goes and the grey button is replaced by an
// "Add to Escale" one — the button people already look for, rather than a bar
// at the bottom of the window they would have to notice. What gets installed
// is read from the tab's own address, never from anything the page says; the
// page only asks, and the usual confirmation still stands between the asking
// and the installing.

final class StoreRelay: NSObject, WKScriptMessageHandler {
    static let name = "escaleStore"

    weak var tab: Tab?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated {
            guard let tab else { return }
            if body["add"] != nil { tab.onStoreAdd?(tab) }
            if let placed = body["placed"] as? String { tab.storePlaced = placed }
        }
    }

    /// Main frame, every page, returning at once anywhere but the store. The
    /// store's markup is generated and its class names change between
    /// releases, so nothing here leans on them: the store's own button is the
    /// disabled one that names Chrome, and the banner is the small block
    /// around the one enabled button that does — only that block, since the
    /// store puts the banner and the extension's own header, button and all,
    /// in the same section.
    static let script = Bundled.script("store-relay.js")
}

extension Browser {
    /// Where "Chrome Web Store…" goes: its extensions, not its themes.
    static let webStore = URL(string: "https://chromewebstore.google.com/category/extensions")!

    /// The page's "Add to Escale" was pressed: the extension this tab is showing.
    func addFromStore(_ tab: Tab) {
        guard #available(macOS 15.4, *), let url = tab.address, StoreOffer.isStorePage(url) else { return }
        Extensions.forSpace(tab.space).install(from: url.absoluteString)
    }

    /// Tells a store page what is installed and what is on its way, so its
    /// button can say "Added to Escale" or "Adding…".
    func tellStore(_ tab: Tab) {
        guard #available(macOS 15.4, *), let url = tab.address, StoreOffer.isStorePage(url) else { return }
        let extensions = Extensions.forSpace(tab.space)
        tab.tellStore(installed: extensions.installed.map(\.id), busy: extensions.busy)
    }

    /// And tells every store page again whenever either changes.
    func followStore() {
        guard #available(macOS 15.4, *) else { return }
        let extensions = Extensions.shared
        storeWatch = extensions.$installed.map { _ in () }
            .merge(with: extensions.$busy.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                for tab in tabs + parkedTabs where tab.built != nil { tellStore(tab) }
            }
    }
}
