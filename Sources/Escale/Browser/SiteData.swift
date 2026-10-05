import WebKit

// WebKit keeps website data by registrable domain, using the public suffix
// list. A page at app.example.com can therefore share one record with
// example.com and its other subdomains. Read the actual records only when the
// user asks to reset a site, name their scope before confirmation, and delete
// only those records from this tab's space. There is no timer or background
// scan; WebKit's record boundary is the one shown to the user.
//
// The records are read and removed across awaits, with a confirmation between
// them, and a tab can close meanwhile — a sign-in page closing itself. A closed
// tab keeps its address, so the host check alone would pass, and its reload
// would build a new page nobody owns. Each step first asks whether the window
// still holds the tab, in any space.

@MainActor
enum SiteData {
    struct Scope {
        weak var web: WKWebView?
        let url: URL
        let space: UUID
        let revision: Int
        let host: String
        let names: [String]
        let records: [WKWebsiteDataRecord]
    }

    static func scope(for tab: Tab) async -> Scope? {
        guard let url = tab.address,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let web = tab.built
        let revision = tab.dataRevision
        let space = tab.space
        let records = await tab.store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let selected = records.filter { record in
            let name = record.displayName.lowercased()
            return host == name || host.hasSuffix("." + name)
        }
        guard tab.built === web, tab.dataRevision == revision, tab.address == url, tab.space == space else { return nil }
        return Scope(web: web, url: url, space: space, revision: revision, host: host, names: Array(Set(selected.map(\.displayName))).sorted(), records: selected)
    }

    @discardableResult
    static func clear(_ scope: Scope, from tab: Tab, in browser: Browser) async -> Bool {
        guard held(tab, by: browser), tab.built != nil, tab.built === scope.web, tab.address == scope.url, tab.space == scope.space, tab.dataRevision == scope.revision else { return false }
        await tab.store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: scope.records)
        if held(tab, by: browser), tab.built === scope.web, tab.address == scope.url, tab.dataRevision == scope.revision { tab.reload() }
        return true
    }

    private static func held(_ tab: Tab, by browser: Browser) -> Bool {
        browser.tabs.contains { $0 === tab } || browser.parkedTabs.contains { $0 === tab }
    }

    static func ask(_ tab: Tab, in browser: Browser) {
        Task {
            guard let scope = await scope(for: tab), held(tab, by: browser),
                  tab.address?.host()?.lowercased() == scope.host else { return }
            let domain = scope.names.isEmpty ? scope.host : scope.names.joined(separator: ", ")
            let detail = "Remove cookies, local storage, databases and cached site data for \(domain) in \(browser.spaces.first { $0.id == scope.space }?.name ?? "Space")\(tab.shy ? " (Private tab)" : "")? WebKit groups subdomains under that domain. The page will reload and you may be signed out."
            Ask.sure("Reset data for \(domain)?", detail: detail, confirm: "Reset Site Data") {
                Task {
                    if await clear(scope, from: tab, in: browser) {
                        browser.announce("Site data reset for \(domain)")
                    }
                }
            }
        }
    }
}

extension Browser {
    func resetSite() {
        guard let active else { return }
        SiteData.ask(active, in: self)
    }
}
