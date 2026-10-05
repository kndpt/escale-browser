// The API Calls panel's collection for one tab, held by the
// tab. WebKit already records every exchange of a page for Web Inspector;
// this reads that record through the page's own inspector frontend, loaded
// but not shown, rather than instrumenting the page. The session is
// InspectorSession's, shared with Web Inspector; this owner holds only the
// script, its message handler, the bounded rows and the one call looked at.
//
// Nothing runs until the panel is opened for a tab. It stays open, and keeps
// collecting, while other tabs or Spaces are on screen: it is put away by
// hand, or when the tab closes or its page's process ends. A tab that
// collects does not sleep. At most `limit` tabs collect at once, each paying
// for its own frontend; opening one more stops the one looked at least
// recently. When WebKit closes the session under a collection (Web
// Inspector's own close button), it connects again and keeps its rows.
// Requests made before the opening are not reconstructed. Response bodies stay in WebKit's backend and are
// read by identifier when a call is opened, cut before they reach Swift; only
// the call on screen holds one, and one is read at a time, so stepping
// through calls with the arrows reads the one reached rather than each one
// passed. The search reads them in the frontend (CallSearch.swift). The cost
// is the frontend's process, about 80 MiB, the same as Web Inspector's:
// not lighter, only nearer the work.
//
// Recording can be paused without ending the collection: the rows kept stay
// readable and searchable, calls already under way finish, and calls made
// meanwhile are never listed, even after resuming. Clearing empties the list
// and leaves recording as it was; calls.js forgets the cleared exchanges and
// numbers what it sends after (the epoch), so none of them comes back.
import SwiftUI
import WebKit

@MainActor
final class Calls: NSObject, ObservableObject, WKScriptMessageHandler {
    static let handler = "escaleCalls"
    /// Tabs collecting at once: each holds an inspector frontend (~80 MiB).
    static let limit = 3
    private static let source = Bundled.script("calls.js")

    enum Phase: Equatable {
        case closed
        case connecting
        case collecting
        /// The collection could not start or was cut; the reason is shown.
        case stopped(String)
    }

    @Published private(set) var phase: Phase = .closed
    /// The tab the panel was opened for; nil while closed.
    @Published private(set) var tab: Tab.ID?
    @Published private(set) var list = CallList()
    @Published var filter: CallList.Filter = .api { didSet { if filter != oldValue { found.typed() } } }
    @Published var search = "" { didSet { if search != oldValue { found.typed() } } }
    /// Off while paused by hand: new calls are not listed.
    @Published private(set) var recording = true
    /// The search in response bodies, for `search`.
    private(set) lazy var found = CallSearch(self)
    /// The call being looked at, its headers and its response.
    @Published private(set) var selected: String?
    @Published private(set) var detail: CallDetail?
    @Published private(set) var body: CallBody?
    /// Readers of their own for the response and the sent body, so the
    /// page's reader is untouched.
    let reader = JSONReader()
    let sentReader = JSONReader()

    private weak var session: InspectorSession?
    private weak var page: Tab?
    /// Reconnections since the panel was opened by hand.
    private var reconnects = 0
    private weak var frontend: WKWebView?
    /// Advances on every start, stop and selection: a late reply for an
    /// earlier one is dropped.
    private var revision = 0
    /// The selected call was still loading when its response was asked for.
    private var awaiting: String?
    /// A response is being read; the call on screen is read after it.
    private var bodyBusy = false
    /// Responses asked of WebKit since the panel opened, for bench.
    private(set) var bodyReads = 0
    /// Advances on every Clear; rows sent before it are dropped.
    private var epoch = 0
    /// Cleared since the panel was opened: a reconnection does not list
    /// again what WebKit already knew, which the list has let go.
    private var cleared = false

    var open: Bool { phase != .closed }
    /// Holding an inspector session: what `limit` counts. A stopped panel
    /// has let its session go.
    var collects: Bool { phase == .connecting || phase == .collecting }

    // MARK: - Lifetime

    /// Opens the collection for `tab`. `keeping` reconnects and keeps the
    /// rows already seen; their bodies belong to the earlier session.
    func start(_ tab: Tab, session: InspectorSession, keeping: Bool = false) {
        if keeping { detach() } else { stop(); reconnects = 0 }
        self.session = session
        self.page = tab
        self.tab = tab.id
        phase = .connecting
        revision += 1
        let asked = revision
        session.collect(tab, ready: { [weak self] frontend, reason in
            guard let self, self.revision == asked else { return }
            guard let frontend else { self.halt(reason ?? "WebKit's inspector is unavailable."); return }
            self.install(frontend, asked: asked)
        }, ended: { [weak self] reason in
            guard let self, self.revision == asked else { return }
            self.reconnect(after: reason)
        })
    }

    /// WebKit closed the session under the collection: connect again, a few
    /// times at most, keeping what was seen.
    private func reconnect(after reason: String) {
        guard phase == .collecting, reconnects < 3, let page, let session, page.built != nil else { halt(reason); return }
        reconnects += 1
        detach()
        phase = .connecting
        DispatchQueue.main.async { [weak self, weak page, weak session] in
            guard let self, let page, let session, self.phase == .connecting, self.tab == page.id else { return }
            self.start(page, session: session, keeping: true)
        }
    }

    private func install(_ frontend: WKWebView, asked: Int) {
        let source = Self.source
        guard !source.isEmpty else { halt("calls.js is missing from Escale's resources."); return }
        let contents = frontend.configuration.userContentController
        contents.removeScriptMessageHandler(forName: Self.handler)
        contents.add(self, name: Self.handler)
        self.frontend = frontend
        // A reconnection starts paused if recording was, in the same epoch,
        // and after a Clear without listing what WebKit knew before it.
        let setup = "window.__escaleCallsSetup = {epoch: \(epoch), paused: \(!recording), cleared: \(cleared)};\n"
        frontend.evaluateJavaScript(setup + source) { [weak self] result, error in
            MainActor.assumeIsolated {
                guard let self, self.revision == asked else { return }
                let answer = result as? [String: Any]
                if let error {
                    self.halt("The collection script failed: " + error.localizedDescription)
                } else if answer?["installed"] as? Bool != true || (answer?["listeners"] as? Int ?? 0) < 6 {
                    self.halt((answer?["reason"] as? String).map { "WebKit's inspector changed: " + $0 }
                              ?? "WebKit's inspector no longer reports network events.")
                } else {
                    self.phase = .collecting
                    self.found.typed()
                }
            }
        }
    }

    /// The collection ends and says why; the rows seen stay readable.
    private func halt(_ reason: String) {
        detach()
        phase = .stopped(reason)
        found.typed()
    }

    /// Everything stops: listeners, handler, session. The panel closes.
    func stop() {
        guard phase != .closed || tab != nil else { return }
        detach()
        phase = .closed
        tab = nil
        page = nil
        list.clear()
        search = ""
        recording = true
        cleared = false
        deselect()
    }

    private func detach() {
        revision += 1
        if let frontend {
            frontend.evaluateJavaScript("window.__escaleCalls && window.__escaleCalls.stop()")
            frontend.configuration.userContentController.removeScriptMessageHandler(forName: Self.handler)
        }
        frontend = nil
        bodyBusy = false
        found.end()
        if let tab { session?.release(tab) }
        // A detail being read can no longer be.
        if body == .reading { body = .unavailable("The collection stopped before the response was read.") }
    }

    /// The tab's page process ended: WebKit's record went with it.
    func lost(reason: String) {
        if phase == .collecting || phase == .connecting { halt(reason) }
    }

    /// Empties the list, whether recording or paused, and leaves recording
    /// as it was.
    func clear() {
        list.clear()
        deselect()
        epoch += 1
        cleared = true
        frontend?.evaluateJavaScript("window.__escaleCalls && window.__escaleCalls.clear(\(epoch))")
        found.end()
        found.typed()
    }

    /// Pauses or resumes recording. Paused, the rows kept stay readable and
    /// calls under way finish; calls made meanwhile are never listed.
    func record(_ on: Bool) {
        guard recording != on, collects else { return }
        recording = on
        frontend?.evaluateJavaScript("window.__escaleCalls && window.__escaleCalls.record(\(on))")
    }

    // MARK: - What the list shows

    /// The list as shown, newest first: the filter, then the search in
    /// addresses, methods and statuses, or in responses.
    var shown: [Call] {
        Array(list.shown(filter, matching: search, bodies: Set(found.current(search).keys)).reversed())
    }

    /// The call `step` rows below the one open in the list as shown (up is
    /// newer); nil at either end.
    func neighbour(_ step: Int) -> String? {
        guard let selected else { return nil }
        return CallList.neighbour(of: selected, in: shown.map(\.id), step: step)
    }

    /// Opens the call `step` rows away, keeping the part of it looked at.
    func step(_ step: Int) {
        guard let id = neighbour(step) else { return }
        select(id)
    }

    /// The typed text, when the open call is listed for its response.
    var mark: String? {
        guard let selected, found.current(search)[selected] != nil else { return nil }
        return found.needle
    }

    /// The frontend the search reads from, while collecting.
    var searchFrontend: WKWebView? { phase == .collecting ? frontend : nil }

    // MARK: - Rows

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard message.webView === frontend, phase == .collecting || phase == .connecting,
                  let body = message.body as? [String: Any], let rows = body["rows"] as? [[String: Any]],
                  (body["epoch"] as? NSNumber)?.intValue == epoch else { return }
            // calls.js decides what a pause lets go: a row sent before it
            // reached the script, even one arriving after, was already known.
            list.take(rows)
            found.arrived()
            // The open call let go by the list takes its body with it.
            if let selected, list[selected] == nil { deselect() }
            // An open call that finished while shown gets its response now.
            if let awaiting, awaiting == selected, let call = list[awaiting], call.finished || call.failed || call.canceled {
                self.awaiting = nil
                read(awaiting)
            }
        }
    }

    // MARK: - One call

    func select(_ id: String?) {
        deselect()
        guard let id, list[id] != nil else { return }
        selected = id
        read(id)
    }

    private func deselect() {
        awaiting = nil
        selected = nil
        detail = nil
        body = nil
        reader.raw()
        sentReader.raw()
    }

    /// Headers, sent body and response, asked for by identifier. Replies for
    /// a call no longer shown are dropped, and so is their body.
    private func read(_ id: String) {
        guard let frontend, phase == .collecting else {
            detail = nil
            body = .unavailable("The collection has stopped; WebKit's record of this call is no longer read.")
            return
        }
        body = .reading
        frontend.callAsyncJavaScript("return window.__escaleCalls ? window.__escaleCalls.detail(id, max) : null",
                                     arguments: ["id": id, "max": CallDetail.sentLimit], in: nil, in: .page) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.selected == id else { return }
                if case .success(let value) = result, let reply = value as? [String: Any] {
                    if let row = reply["row"] as? [String: Any] { self.list.take([row]) }
                    self.detail = reply["error"] == nil ? CallDetail(reply) : nil
                    // A whole sent body that reads as JSON is shown structured.
                    if let detail = self.detail, let sent = detail.requestBody, !detail.requestCut,
                       detail.requestType.contains("json") || Self.looksJSON(sent) {
                        self.sentReader.show(sent)
                    }
                }
            }
        }
        readBody(id, frontend)
    }

    /// One response at a time: a call opened meanwhile is read once this
    /// one answers, and the calls passed over are not read at all.
    private func readBody(_ id: String, _ frontend: WKWebView) {
        guard !bodyBusy else { return }
        bodyBusy = true
        bodyReads += 1
        frontend.callAsyncJavaScript("return window.__escaleCalls ? await window.__escaleCalls.body(id, max) : null",
                                     arguments: ["id": id, "max": CallBody.limit], in: nil, in: .page) { [weak self, weak frontend] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                if frontend === self.frontend { self.bodyBusy = false }
                guard self.selected == id else {
                    if let selected = self.selected, self.body == .reading, self.awaiting != selected,
                       let frontend = self.frontend, frontend === self.frontend, self.phase == .collecting {
                        self.readBody(selected, frontend)
                    }
                    return
                }
                switch result {
                case .success(let value):
                    let answer = (value as? [String: Any]).map(CallBody.init) ?? .unavailable("The collection stopped.")
                    // Still loading: asked again when its row finishes.
                    if answer == .unavailable("loading") { self.awaiting = id; self.body = .reading; return }
                    self.body = answer
                    // A cut body is not valid JSON: raw only, and said so.
                    if case .text(let text, _, false) = answer, self.list[id]?.mime.contains("json") == true || Self.looksJSON(text) {
                        self.reader.show(text)
                        // Opened for its response: the tree shows where.
                        if let mark = self.mark { self.reader.query = mark }
                    }
                case .failure(let error):
                    self.body = .unavailable(error.localizedDescription)
                }
            }
        }
    }

    static func looksJSON(_ text: String) -> Bool {
        guard let first = text.first(where: { !$0.isWhitespace }) else { return false }
        return first == "{" || first == "["
    }

    // MARK: - Bench

    /// The frontend's process and the collection's state, for bench.
    var frontendPage: WKWebView? { frontend }
}

extension Browser {
    /// The door, the menu and ⌥⌘N: open the panel for the tab on screen, or
    /// close it. One more than `Calls.limit` open panels stops the one of
    /// the tab looked at least recently.
    func toggleCalls() {
        guard let tab = active else { return }
        if tab.calls.open { tab.calls.stop(); return }
        guard !tab.isBlank, tab.built != nil else { return }
        let others = (tabs + parkedTabs).filter { $0.id != tab.id && $0.calls.collects }
        if others.count >= Calls.limit, let oldest = others.min(by: { $0.touched < $1.touched }) {
            oldest.calls.stop()
        }
        tab.calls.start(tab, session: inspection)
    }

    /// The Markdown report of the call on screen in `tab` (CallReport.swift).
    func callReport(_ tab: Tab) -> String? {
        let calls = tab.calls
        guard let id = calls.selected, let call = calls.list[id] else { return nil }
        let environment = shelfTabs[tab.id].flatMap { bookmarks.find($0) }
            .flatMap { BookmarkEnvironment.current(in: $0.destinations, at: tab.address) }?.name ?? ""
        let info = ProcessInfo.processInfo
        let context = CallReport.Context(
            page: tab.address?.absoluteString ?? "",
            title: tab.title,
            environment: environment,
            space: spaces.first { $0.id == tab.space }?.name ?? space.name,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            system: "macOS " + info.operatingSystemVersionString
                .replacingOccurrences(of: "Version ", with: "").replacingOccurrences(of: "Build ", with: ""))
        return CallReport(call: call, detail: calls.detail, body: calls.body, context: context).text
    }
}
