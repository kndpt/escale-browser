// WebKit owns the inspector for each live page. Escale asks for the active
// page's inspector only on an explicit action, then uses WebKit's own dock
// request to put it at the right of that page. The frontend-loaded callback
// is the first point at which that request can be made. A tab switch puts
// the old inspector away and opens the new page's after it wakes; no
// recurring polling or extra page is kept alive by this owner (only a
// bounded readiness query while an API Calls collection connects, below).
// A split pane, or a page narrowed by the API Calls panel, can be too narrow
// for WebKit's dock. In those cases only, keep WebKit's separate inspector
// window instead of separating the group or ending a collection.
//
// The same sessions serve the API Calls panel (Calls.swift): one collection
// per tab whose panel is open, each on that page's own inspector, loaded but
// unseen, and kept while another tab is on screen. This owner stays the only
// one to connect, show, hide or close an inspector: showing a frontend
// already loaded docks it at once (WebKit does not announce a frontend
// twice), and putting Web Inspector away from a page that collects hides it
// instead of closing the collection with it. A session closes when neither
// Web Inspector nor a collection wants it.
//
// These inspector selectors and the frontend host are outside the public
// WebKit API. Each is checked before use; failure closes the panel when none
// of the permitted docks is available (see COMPATIBILITY.md).
import Combine
import SwiftUI
import WebKit

@MainActor
final class InspectorSession: NSObject, ObservableObject {
    @Published private(set) var visibleTab: Tab.ID?
    private(set) var failure = ""
    /// Web Inspector's page: on screen, or on its way.
    private weak var currentInspector: NSObject?
    private var openingTab: Tab.ID?
    private var following = false
    private var allowsDetached = false
    /// Inspectors whose frontend has announced itself loaded. An entry goes
    /// when its inspector is closed, so an identity is never reused stale.
    private var loaded = Set<ObjectIdentifier>()
    /// The API Calls collections, by tab (at most `Calls.limit`).
    private var collectors: [Tab.ID: Collector] = [:]

    private final class Collector {
        weak var inspector: NSObject?
        /// Called once: the frontend's page, or why there is none.
        var ready: ((WKWebView?, String?) -> Void)?
        /// Called when the session ends under the collection.
        let ended: (String) -> Void
        /// A leftover session being closed before this one connects.
        var reopening = false
        /// Connections begun, and how many a late close made start again.
        var connection = 0
        var reconnects = 0

        init(_ inspector: NSObject, ready: @escaping (WKWebView?, String?) -> Void, ended: @escaping (String) -> Void) {
            self.inspector = inspector
            self.ready = ready
            self.ended = ended
        }
    }

    func toggle(tab: Tab?, split: Bool = false) {
        guard let tab else { return }
        allowsDetached = split
        if visibleTab == tab.id || openingTab == tab.id {
            close()
        } else {
            open(tab)
        }
    }

    func showConsole(tab: Tab?, split: Bool = false) {
        guard let tab else { return }
        allowsDetached = split
        if visibleTab != tab.id && openingTab != tab.id { open(tab) }
        if let inspector = currentInspector { send(inspector, "showConsole") }
    }

    func inspectElement(tab: Tab?, split: Bool = false) {
        guard let tab else { return }
        allowsDetached = split
        if visibleTab != tab.id && openingTab != tab.id { open(tab) }
        if let inspector = currentInspector { send(inspector, "toggleElementSelection") }
    }

    func follow(browser: Browser, from old: Tab.ID?) {
        guard old != browser.activeID, following else { return }
        allowsDetached = browser.panels.group(browser.activeID) != nil
        close(keepFollowing: true)
        let next = browser.activeID
        DispatchQueue.main.async { [weak browser, weak self] in
            guard let browser, browser.activeID == next else { return }
            self?.open(browser.active)
        }
    }

    /// WebKit closed an inspector, from its own panel or under a page.
    func closed(_ inspector: NSObject) {
        let shown = inspector === currentInspector && (visibleTab != nil || openingTab != nil)
        if let (tab, collector) = holder(of: inspector) {
            // A close WebKit finishes while a collection is still connecting
            // ends an earlier session, not this one: connect again once that
            // close has returned, at most three times.
            if collector.ready != nil, !shown, collector.reconnects < 3 {
                collector.reconnects += 1
                collector.reopening = false
                loaded.remove(ObjectIdentifier(inspector))
                DispatchQueue.main.async { [weak self] in self?.begin(tab) }
                return
            }
            end(tab, "Web Inspector closed its session.")
        }
        loaded.remove(ObjectIdentifier(inspector))
        guard inspector === currentInspector else { return }
        currentInspector = nil
        openingTab = nil
        visibleTab = nil
        following = false
    }

    /// An API Calls panel asks for its tab's inspector frontend, loaded and
    /// connected but not shown. `ready` answers once; `ended` says the
    /// session went away under it.
    func collect(_ tab: Tab, ready: @escaping (WKWebView?, String?) -> Void, ended: @escaping (String) -> Void) {
        end(tab.id, "Another collection started.")
        guard !tab.isBlank, let web = tab.built, let inspector = inspector(for: web) else {
            ready(nil, "This page has no inspector to collect from.")
            return
        }
        let missing = ["connect", "hide", "close", "isConnected", "inspectorWebView", "setDelegate:"]
            .filter { !inspector.responds(to: NSSelectorFromString($0)) }
        guard missing.isEmpty else {
            ready(nil, "This version of WebKit lacks " + missing.joined(separator: ", ") + ".")
            return
        }
        let collector = Collector(inspector, ready: ready, ended: ended)
        collectors[tab.id] = collector
        if inspector === currentInspector, loaded.contains(ObjectIdentifier(inspector)) {
            deliver(tab.id)
            return
        }
        // A connected session no one here holds is WebKit's leftover, for
        // instance after the page's process ended under a collection: its
        // frontend no longer hears the page. It is closed first, and the new
        // one waits for WebKit to say so (at most a second).
        if inspector !== currentInspector, inspector.value(forKey: "isConnected") as? Bool == true {
            collector.reopening = true
            loaded.remove(ObjectIdentifier(inspector))
            send(inspector, "close")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak collector] in
                guard let self, let collector, collector.reopening else { return }
                collector.reopening = false
                self.begin(tab.id)
            }
            return
        }
        begin(tab.id)
    }

    private func begin(_ tab: Tab.ID) {
        guard let collector = collectors[tab], collector.ready != nil, let inspector = collector.inspector else { return }
        collector.connection += 1
        adopt(inspector)
        send(inspector, "connect")
        // The frontend announces itself through the delegate in about half a
        // second. A frontend WebKit reuses after a close is not
        // always announced again, so its readiness is also asked, a few
        // times a second, until the delegate answers or 10 seconds pass.
        settle(tab, attempts: 40, connection: collector.connection)
    }

    private func settle(_ tab: Tab.ID, attempts: Int, connection: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, let collector = self.collectors[tab], collector.connection == connection,
                  collector.ready != nil, let inspector = collector.inspector,
                  !self.loaded.contains(ObjectIdentifier(inspector)) else { return }
            guard attempts > 0 else { self.fail(tab, "WebKit's inspector did not load within 10 seconds."); return }
            let getter = NSSelectorFromString("inspectorWebView")
            guard let frontend = inspector.perform(getter)?.takeUnretainedValue() as? WKWebView, !frontend.isLoading else {
                self.settle(tab, attempts: attempts - 1, connection: connection)
                return
            }
            frontend.evaluateJavaScript("typeof WI !== 'undefined' && !!WI.networkManager && !!WI.mainTarget && document.readyState === 'complete'") { [weak self] value, _ in
                MainActor.assumeIsolated {
                    guard let self, let collector = self.collectors[tab], collector.connection == connection,
                          let inspector = collector.inspector, !self.loaded.contains(ObjectIdentifier(inspector)) else { return }
                    if value as? Bool == true {
                        self.loaded.insert(ObjectIdentifier(inspector))
                        self.deliver(tab)
                    } else {
                        self.settle(tab, attempts: attempts - 1, connection: connection)
                    }
                }
            }
        }
    }

    /// The tab's panel is done with its session; it closes unless Web
    /// Inspector is on screen for that page or on its way.
    func release(_ tab: Tab.ID) {
        guard let collector = collectors.removeValue(forKey: tab), let inspector = collector.inspector else { return }
        if inspector === currentInspector, visibleTab != nil || openingTab != nil { return }
        if inspector === currentInspector { currentInspector = nil }
        loaded.remove(ObjectIdentifier(inspector))
        send(inspector, "close")
    }

    /// For bench: what WebKit says of a tab's inspector and who holds it.
    func flags(_ tab: Tab) -> [String: Any] {
        let inspector = tab.built.flatMap(inspector(for:))
        func flag(_ name: String) -> Any {
            guard let inspector, inspector.responds(to: NSSelectorFromString(name)) else { return NSNull() }
            return inspector.value(forKey: name) as? Bool ?? NSNull()
        }
        let held = collectors[tab.id] != nil || (inspector != nil && inspector === currentInspector)
        return ["session": held, "loaded": inspector.map { loaded.contains(ObjectIdentifier($0)) } ?? false,
                "collecting": collectors[tab.id] != nil, "collections": collectors.count,
                "connected": flag("isConnected"), "visible": flag("isVisible")]
    }

    private func holder(of inspector: NSObject) -> (Tab.ID, Collector)? {
        collectors.first { $0.value.inspector === inspector }.map { ($0.key, $0.value) }
    }

    private func deliver(_ tab: Tab.ID) {
        guard let collector = collectors[tab], let ready = collector.ready, let inspector = collector.inspector else { return }
        collector.ready = nil
        let getter = NSSelectorFromString("inspectorWebView")
        if let frontend = inspector.perform(getter)?.takeUnretainedValue() as? WKWebView {
            ready(frontend, nil)
        } else {
            fail(tab, "WebKit's inspector has no page.", answering: ready)
        }
    }

    private func fail(_ tab: Tab.ID, _ reason: String, answering ready: ((WKWebView?, String?) -> Void)? = nil) {
        guard let collector = collectors.removeValue(forKey: tab) else { ready?(nil, reason); return }
        let answer = ready ?? collector.ready
        if let inspector = collector.inspector, !(inspector === currentInspector && (visibleTab != nil || openingTab != nil)) {
            if inspector === currentInspector { currentInspector = nil }
            loaded.remove(ObjectIdentifier(inspector))
            send(inspector, "close")
        }
        answer?(nil, reason)
    }

    /// A collection loses its session: told once, then forgotten.
    private func end(_ tab: Tab.ID, _ reason: String) {
        guard let collector = collectors.removeValue(forKey: tab) else { return }
        if let ready = collector.ready { ready(nil, reason) } else { collector.ended(reason) }
    }

    /// This owner hears what WebKit says of the inspector.
    private func adopt(_ inspector: NSObject) {
        let setter = NSSelectorFromString("setDelegate:")
        if inspector.responds(to: setter) { inspector.perform(setter, with: self) }
    }

    /// Web Inspector leaves this page: hidden while its tab collects,
    /// closed otherwise.
    private func putAway(_ inspector: NSObject) {
        if holder(of: inspector) != nil, inspector.responds(to: NSSelectorFromString("hide")) {
            send(inspector, "hide")
        } else {
            loaded.remove(ObjectIdentifier(inspector))
            send(inspector, "close")
        }
    }

    private func open(_ tab: Tab?) {
        failure = ""
        guard let tab, !tab.isBlank, let web = tab.built,
              let inspector = inspector(for: web) else { failure = "Inspector unavailable"; return }
        if let previous = currentInspector, previous !== inspector { putAway(previous) }
        // Already loaded for a collection: WebKit will not announce it again.
        let warm = loaded.contains(ObjectIdentifier(inspector))
        currentInspector = inspector
        adopt(inspector)
        openingTab = tab.id
        visibleTab = nil
        following = true
        send(inspector, "show")
        if warm { dock(inspector, tab: tab.id, attempts: 10) }
    }

    private func close(keepFollowing: Bool = false) {
        let inspector = currentInspector
        currentInspector = nil
        openingTab = nil
        visibleTab = nil
        following = keepFollowing
        if let inspector { putAway(inspector) }
    }

    /// WebKit notifies its delegate once the inspector's own page can accept
    /// a dock request. The request resizes the inspected page beside it.
    @objc(inspectorFrontendLoaded:)
    func frontendLoaded(_ inspector: NSObject) {
        loaded.insert(ObjectIdentifier(inspector))
        if let (tab, _) = holder(of: inspector) { deliver(tab) }
        guard inspector === currentInspector, let openingTab else { return }
        dock(inspector, tab: openingTab, attempts: 10)
    }

    private func dock(_ inspector: NSObject, tab: Tab.ID, attempts: Int) {
        guard inspector === currentInspector, openingTab == tab else { return }
        let getter = NSSelectorFromString("webView")
        let inspected = inspector.responds(to: getter)
            ? inspector.perform(getter)?.takeUnretainedValue() as? WKWebView : nil
        let inspectorFrontend: WKWebView?
        if let inspected, let root = inspected.superview {
            inspectorFrontend = frontend(in: root, depth: 0)
        } else {
            inspectorFrontend = nil
        }
        guard let inspectorFrontend else {
            guard attempts > 0 else {
                let visible = NSSelectorFromString("isVisible")
                // Beside the API Calls panel too, the page can be narrower
                // than WebKit docks against: its own window then stays.
                if allowsDetached || holder(of: inspector) != nil, inspector.responds(to: visible),
                   inspector.value(forKey: "visible") as? Bool == true {
                    openingTab = nil
                    visibleTab = tab
                } else {
                    failure = "Inspector frontend not mounted"
                    close()
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak inspector] in
                guard let self, let inspector else { return }
                self.dock(inspector, tab: tab, attempts: attempts - 1)
            }
            return
        }
        inspectorFrontend.evaluateJavaScript("InspectorFrontendHost.supportsDockSide('right') && (InspectorFrontendHost.requestSetDockSide('right'), true)") { [weak self, weak inspector] (result: Any?, error: Error?) in
            MainActor.assumeIsolated {
                guard let self, let inspector, inspector === self.currentInspector,
                      self.openingTab == tab else { return }
                guard error == nil, result as? Bool == true else {
                    self.failure = error?.localizedDescription ?? "Requested dock unavailable"
                    self.close()
                    return
                }
                self.openingTab = nil
                self.visibleTab = tab
            }
        }
    }

    /// The inspector frontend is WebKit's own WKWebView attached beside the
    /// inspected page. Its concrete class keeps us from mistaking another
    /// page in the window for a developer tool.
    private func frontend(in view: NSView, depth: Int) -> WKWebView? {
        guard depth < 20 else { return nil }
        if let kind = NSClassFromString("WKInspectorWKWebView"), view.isKind(of: kind) {
            return view as? WKWebView
        }
        for child in view.subviews {
            if let found = frontend(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private func inspector(for web: WKWebView) -> NSObject? {
        let getter = NSSelectorFromString("_inspector")
        guard web.responds(to: getter) else { return nil }
        return web.perform(getter)?.takeUnretainedValue() as? NSObject
    }

    private func send(_ inspector: NSObject, _ name: String) {
        let selector = NSSelectorFromString(name)
        if inspector.responds(to: selector) { inspector.perform(selector) }
    }
}

extension Browser {
    /// The View menu and ⌥⌘I share the same tab-aware action. Escale shows
    /// no door for it: the API Calls panel is the tool it puts forward.
    func toggleInspector() { inspection.toggle(tab: active, split: panels.group(activeID) != nil) }
    func showConsole() { inspection.showConsole(tab: active, split: panels.group(activeID) != nil) }
    func inspectElement() { inspection.inspectElement(tab: active, split: panels.group(activeID) != nil) }

    /// WebKit can also close the inspector from inside its own panel.
    @objc(_webView:willCloseLocalInspector:)
    func webView(_ webView: WKWebView, willCloseLocalInspector inspector: NSObject) {
        inspection.closed(inspector)
    }
}
