// A Site Data interaction belongs to one tab and one loaded document. Reads
// happen on opening/refresh only; snapshots cap each list at 2,000 entries and
// 1 MiB. Cookies retain their full identity and attributes, localStorage writes
// compare the old value in the main frame's isolated client world. There is no
// automatic reload, observer, persistent copy or network request.
import SwiftUI
import WebKit

@MainActor
final class SiteStorage: ObservableObject {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    struct Entry: Identifiable {
        let id: String
        let key: String
        let value: String
        let scope: String
        let cookie: HTTPCookie?
    }
    @Published private(set) var shown = false
    @Published private(set) var cookies: [Entry] = []
    @Published private(set) var local: [Entry] = []
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var context = ""
    @Published private(set) var origin = ""
    private weak var tab: Tab?
    private weak var web: WKWebView?
    private var url: URL?
    private var token = UUID().uuidString
    private var revision = 0
    private static let script = Bundled.script("site-storage.js")
    static let limit = 2000
    static let bytes = 1024 * 1024
    static func matches(_ cookie: HTTPCookie, host: String) -> Bool {
        let domain = cookie.domain.lowercased()
        return domain.hasPrefix(".") ? host == String(domain.dropFirst()) || host.hasSuffix(domain) : host == domain
    }
    func close() {
        revision += 1; token = UUID().uuidString
        shown = false; busy = false; cookies = []; local = []; error = nil
        tab = nil; web = nil; url = nil; context = ""; origin = ""
    }
    func open(_ tab: Tab, spaceName: String) {
        tab.visual.stop(); tab.area.stop(); tab.capture.close()
        close()
        guard let web = tab.built, !web.isLoading, let url = web.url,
              ["http", "https"].contains(url.scheme ?? ""), let host = url.host else { return }
        self.tab = tab; self.web = web; self.url = url
        origin = "\(url.scheme ?? "")://\(host)" + (url.port.map { ":\($0)" } ?? "")
        context = "\(spaceName)\(tab.shy ? " · Private tab" : "") · \(origin)"
        shown = true
        refresh()
    }
    private func current(_ revision: Int) -> Bool {
        shown && self.revision == revision && tab?.built === web && web != nil && web?.url == url && web?.isLoading == false
    }
    static func message(_ error: Error) -> String {
        (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
    }
    func refresh() {
        guard !busy else { return }
        run { [self] in
            let asked = revision
            try await readCookies()
            guard current(asked) else { return }
            let result = try await storage("read")
            if current(asked) { local = result }
        }
    }
    private func run(_ action: @escaping () async throws -> Void) {
        guard !busy, current(revision) else { return }
        busy = true; error = nil
        let asked = revision
        Task {
            guard current(asked) else { return }
            do { try await action() }
            catch { if current(asked) { self.error = Self.message(error) } }
            if current(asked) { busy = false }
        }
    }
    private func readCookies() async throws {
        guard let tab, let host = url?.host?.lowercased() else { return }
        let asked = revision
        let all = await tab.store.httpCookieStore.allCookies()
        guard current(asked) else { return }
        let matches = all.filter { Self.matches($0, host: host) }
        guard matches.count <= Self.limit, matches.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count + $1.path.utf8.count + $1.domain.utf8.count }) <= Self.bytes else {
            cookies = []
            throw Failure(message: "Cookies exceed 2,000 entries or 1 MiB. Use Web Inspector.")
        }
        cookies = matches.sorted { ($0.name, $0.domain, $0.path) < ($1.name, $1.domain, $1.path) }.map {
            Entry(id: "\($0.domain)\n\($0.path)\n\($0.name)", key: $0.name, value: $0.value,
                  scope: "\($0.domain) · \($0.path)\($0.isSecure ? " · Secure" : "")\($0.isHTTPOnly ? " · HttpOnly" : "")", cookie: $0)
        }
    }
    private func storage(_ action: String, extra: [String: Any] = [:]) async throws -> [Entry] {
        guard current(revision), let web, let url else { return [] }
        let asked = revision
        var args: [String: Any] = ["action": action, "url": url.absoluteString, "token": token]
        extra.forEach { args[$0.key] = $0.value }
        let script = Bundled.configured(Self.script, with: args)
        let result: Any = try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(script, in: nil, in: .defaultClient) { continuation.resume(with: $0) }
        }
        guard current(asked) else { return [] }
        guard let rows = result as? [[String: String]] else { throw Failure(message: "localStorage could not be read.") }
        return rows.compactMap { row in
            guard let key = row["key"], let value = row["value"] else { return nil }
            return Entry(id: key, key: key, value: value, scope: origin, cookie: nil)
        }
    }
    func save(_ entry: Entry?, key: String, value: String, cookie: Bool) {
        let key = entry?.key ?? key
        guard key.utf8.count + value.utf8.count <= Self.bytes else { error = "Entry exceeds 1 MiB."; return }
        if cookie && (key.isEmpty || key.contains(where: { $0.isWhitespace || "=;,\r\n".contains($0) }) || value.contains(where: { ";\r\n".contains($0) })) {
            error = "Use a valid cookie name and value."; return
        }
        run { [self] in
            let asked = revision
            if cookie {
                guard let tab, let host = url?.host else { return }
                let all = await tab.store.httpCookieStore.allCookies()
                guard current(asked) else { return }
                if let old = entry?.cookie {
                    guard all.contains(where: { $0.name == old.name && $0.domain == old.domain && $0.path == old.path && ($0.properties as NSDictionary?) == (old.properties as NSDictionary?) }) else {
                        throw Failure(message: "Cookie changed. Refresh before editing.")
                    }
                } else if all.contains(where: { $0.name == key && $0.domain == host && $0.path == "/" }) {
                    throw Failure(message: "That cookie already exists. Select it to edit.")
                }
                var properties = entry?.cookie?.properties ?? [.name: key, .domain: host, .path: "/"]
                if entry == nil, url?.scheme == "https" { properties[.secure] = "TRUE" }
                if let old = entry?.cookie {
                    properties.removeValue(forKey: .maximumAge)
                    if let expiry = old.expiresDate { properties[.expires] = expiry }
                }
                properties[.value] = value
                guard let replacement = HTTPCookie(properties: properties) else { throw Failure(message: "WebKit cannot create this cookie.") }
                await tab.store.httpCookieStore.setCookie(replacement)
                guard current(asked) else { return }
                try await readCookies()
            } else {
                let result = try await storage("set", extra: ["key": entry?.key ?? key, "value": value, "expected": entry.map { $0.value as Any } ?? NSNull()])
                if current(asked) { local = result }
            }
        }
    }
    func remove(_ entries: [Entry], cookie: Bool) {
        guard !entries.isEmpty else { return }
        let asked = revision
        let scope = entries.map { "\($0.key) · \($0.scope)" }.joined(separator: "; ")
        Ask.sure("Delete \(entries.count) \(cookie ? "cookie(s)" : "localStorage entry/entries")?",
                 detail: "\(context)\n\(String(scope.prefix(1500)))\nOnly these entries are affected. The page will not reload.", confirm: "Delete") { [weak self] in
            guard let self, self.current(asked) else { return }
            self.run {
                if cookie {
                    guard let tab = self.tab else { return }
                    let all = await tab.store.httpCookieStore.allCookies()
                    guard self.current(asked) else { return }
                    guard entries.allSatisfy({ entry in all.contains { ($0.properties as NSDictionary?) == (entry.cookie?.properties as NSDictionary?) } }) else {
                        throw Failure(message: "Cookies changed. Refresh before deleting.")
                    }
                    for entry in entries {
                        guard self.current(asked), let cookie = entry.cookie else { return }
                        await tab.store.httpCookieStore.deleteCookie(cookie)
                    }
                    guard self.current(asked) else { return }
                    try await self.readCookies()
                } else {
                    let result = try await self.storage("clear", extra: ["entries": entries.map { ["key": $0.key, "value": $0.value] }])
                    if self.current(asked) { self.local = result }
                }
            }
        }
    }
    func clearCache() {
        guard !busy, let tab else { return }
        let asked = revision
        run { [self] in
            guard let scope = await SiteData.scope(for: tab), current(asked) else { return }
            Ask.sure("Clear cached resources?", detail: "\(context)\nWebKit domains: \((scope.names.isEmpty ? scope.host : scope.names.joined(separator: ", "))). Includes their subdomains and other ports. Cookies and localStorage are kept. The page will not reload.", confirm: "Clear Cache") { [weak self] in
                guard let self, self.current(asked) else { return }
                self.run {
                    await tab.store.removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache], for: scope.records)
                }
            }
        }
    }
}

struct SiteStoragePanel: View {
    @ObservedObject var storage: SiteStorage
    let reset: () -> Void
    @State private var cookie = true
    @State private var query = ""
    @State private var selected: SiteStorage.Entry?
    @State private var key = ""
    @State private var value = ""
    @State private var editing = false
    private var entries: [SiteStorage.Entry] { cookie ? storage.cookies : storage.local }
    private var filtered: [SiteStorage.Entry] { entries.filter { query.isEmpty || ($0.key + $0.value + $0.scope).localizedCaseInsensitiveContains(query) } }
    var body: some View {
        if storage.shown {
            Plate("Site Data", width: Metrics.toolPanelWidth, close: storage.close) {
                VStack(alignment: .leading, spacing: Metrics.toolGap) {
                    Text(storage.context).font(.caption).textSelection(.enabled)
                    Text("Cookies include matching parent domains and all paths. localStorage is limited to this origin. Changes do not reload the page.")
                        .font(.caption).foregroundStyle(Palette.muted)
                    Segmented(options: [(true, "Cookies"), (false, "localStorage")], selection: $cookie)
                        .accessibilityLabel("Category")
                        .onChange(of: cookie) { _, _ in editing = false; selected = nil }
                    TextField("Search names, values or scope", text: $query).textFieldStyle(.roundedBorder)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Metrics.toolGap) {
                            ForEach(filtered) { entry in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(entry.key).lineLimit(1)
                                        Text(entry.scope).font(.caption).foregroundStyle(Palette.muted).lineLimit(2)
                                        Text(String(entry.value.prefix(200))).font(.system(size: Metrics.toolFont, design: .monospaced)).lineLimit(2)
                                    }
                                    Spacer()
                                    Button("Copy") { JSONSurface.copy(entry.value) }
                                    Button("Edit") { selected = entry; key = entry.key; value = entry.value; editing = true }
                                    Button("Delete") { storage.remove([entry], cookie: cookie) }
                                }
                                Divider()
                            }
                        }
                    }.frame(height: Metrics.toolListHeight)
                    if editing {
                        TextField("Name", text: $key).disabled(selected != nil)
                        TextField("Value", text: $value)
                        HStack {
                            Button("Cancel") { editing = false }
                            Button("Save") { storage.save(selected, key: key, value: value, cookie: cookie); editing = false }
                        }
                        if cookie && selected == nil { Text("New session cookie · current host · path / · Secure on HTTPS").font(.caption) }
                    }
                    if let error = storage.error { Text(error).foregroundStyle(Palette.danger).font(.caption).textSelection(.enabled) }
                    if storage.busy { ProgressView() }
                }.disabled(storage.busy)
            } foot: {
                HStack {
                    Button("New Entry") { selected = nil; key = ""; value = ""; editing = true }
                    Button("Refresh", action: storage.refresh)
                    Menu("Clear…") {
                        Button("Listed \(cookie ? "Cookies" : "localStorage")…") { storage.remove(filtered, cookie: cookie) }
                        Button("Cached Resources…", action: storage.clearCache)
                        Button("Reset All Site Data…", action: reset)
                    }.fixedSize()
                    Spacer()
                }.disabled(storage.busy)
            }
            .onExitCommand(perform: storage.close)
            // The panel's view outlives a close and the switch to another
            // tab's storage: a draft left open must not reappear, or be
            // saved, in the next site's panel.
            .onDisappear { editing = false; selected = nil; key = ""; value = ""; query = "" }
        }
    }
}

extension Browser {
    func showSiteData() {
        guard let active else { return }
        active.siteStorage.open(active, spaceName: spaces.first { $0.id == active.space }?.name ?? "Space")
    }
}
