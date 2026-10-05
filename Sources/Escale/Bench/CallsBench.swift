// The API Calls panel from the bench socket, in test worlds only. Actions go
// through the production owner (Calls.swift); observations read its values
// and, for teardown checks, the tab's inspector frontend as WebKit keeps it.
// Nothing here opens an inspector or builds a page on its own: `frontend` and
// `pids` answer from what already exists. Scenarios decide pass or fail.
import WebKit

@MainActor
enum CallsBench {
    /// `tab` is the one named by `id`, or the tab on screen for `-`.
    static func run(_ request: [String: Any], browser: Browser, tab named: Tab?, answer: @escaping ([String: Any]) -> Void) {
        guard let tab = named ?? browser.active else { answer(["error": "no tab"]); return }
        let calls = tab.calls
        switch request["action"] as? String ?? "state" {
        case "open":
            // The door's own path for the tab on screen; another tab named
            // by the scenario starts its own collection.
            if !calls.open {
                if tab.id == browser.activeID { browser.toggleCalls() } else { calls.start(tab, session: browser.inspection) }
            }
        case "close":
            calls.stop()
        case "clear":
            calls.clear()
        case "filter":
            calls.filter = request["all"] as? Bool == true ? .all : .api
            if let search = request["search"] as? String { calls.search = search }
        case "select":
            calls.select(request["call"] as? String)
        case "record":
            // The toolbar's pause and resume, which keep the list.
            calls.record(request["on"] as? Bool ?? true)
        case "step":
            // The arrows at the sheet's foot: -1 newer, 1 older; `times`
            // in one turn of the main loop, faster than any key repeat.
            for _ in 0..<max(1, request["times"] as? Int ?? 1) { calls.step(request["by"] as? Int ?? 1) }
        case "resume":
            calls.start(tab, session: browser.inspection)
        case "curl":
            // What Copy as › cURL puts on the pasteboard for the call shown.
            guard let id = calls.selected, let call = calls.list[id] else { answer(["error": "no call shown"]); return }
            if let missing = Curl.missing(call, calls.detail) { answer(["missing": missing]); return }
            answer(["curl": calls.detail.map { Curl.command(call, $0) } ?? ""])
            return
        case "report":
            answer(["report": browser.callReport(tab) ?? NSNull()])
            return
        case "frontend":
            // A script in the tab's inspector frontend, if WebKit still has
            // one: whether the collection left anything behind.
            guard let page = frontend(of: tab) else { answer(["frontend": false]); return }
            page.evaluateJavaScript(request["js"] as? String ?? "true") { value, error in
                MainActor.assumeIsolated {
                    answer(["frontend": true, "value": value.map(plain) ?? NSNull(), "failure": error?.localizedDescription ?? ""])
                }
            }
            return
        case "pids":
            answer(["page": pid(tab.built), "frontend": pid(frontend(of: tab))])
            return
        default:
            break
        }
        answer(state(browser, tab: tab, full: request["full"] as? Bool ?? false))
    }

    /// `full` returns a text body whole, for comparison with the page.
    static func state(_ browser: Browser, tab: Tab, full: Bool = false) -> [String: Any] {
        let calls = tab.calls
        var phase: [String: Any] = ["name": "closed"]
        switch calls.phase {
        case .closed: phase = ["name": "closed"]
        case .connecting: phase = ["name": "connecting"]
        case .collecting: phase = ["name": "collecting"]
        case .stopped(let reason): phase = ["name": "stopped", "reason": reason]
        }
        let limit = 256
        var out: [String: Any] = [
            "phase": phase, "tab": calls.tab?.uuidString ?? "", "count": calls.list.count, "dropped": calls.list.dropped,
            // As the list shows them: newest first, body matches included.
            "shown": calls.shown.map(\.id),
            "recording": calls.recording,
            "neighbours": [calls.neighbour(-1) ?? "", calls.neighbour(1) ?? ""],
            "reads": calls.bodyReads,
            "search": search(calls),
            "inspection": browser.inspection.flags(tab),
            "open": (browser.tabs + browser.parkedTabs).filter { $0.calls.open }.map { Bench.short($0) },
            "inspector": browser.inspection.visibleTab?.uuidString ?? "",
            "selected": calls.selected ?? "",
            "rows": calls.list.order.compactMap { calls.list[$0] }.map(row)
        ]
        if let detail = calls.detail {
            out["detail"] = ["requestHeaders": detail.requestHeaders.map { [$0.name, $0.value] },
                             "responseHeaders": detail.responseHeaders.map { [$0.name, $0.value] },
                             "requestType": detail.requestType, "requestBody": detail.requestBody ?? NSNull(),
                             "requestLength": detail.requestLength ?? NSNull(), "redirects": detail.redirects.count]
            out["sentReader"] = ["shown": calls.sentReader.shown, "nodes": calls.sentReader.document?.nodes.count ?? 0]
        }
        switch calls.body {
        case .reading?: out["body"] = ["kind": "reading"]
        case .text(let text, let length, let cut)?:
            // The whole text only on request (`full`): large bodies stay in the app.
            let whole = full || text.count <= limit
            out["body"] = ["kind": "text", "length": length, "cut": cut, "count": text.count,
                           "text": whole ? text : String(text.prefix(limit))]
        case .binary(let length)?: out["body"] = ["kind": "binary", "length": length]
        case .unavailable(let reason)?: out["body"] = ["kind": "unavailable", "reason": reason]
        case nil: out["body"] = NSNull()
        }
        out["reader"] = ["shown": calls.reader.shown, "nodes": calls.reader.document?.nodes.count ?? 0,
                         "failure": calls.reader.error ?? ""]
        return out
    }

    /// The search in responses: what it matched, and what it looked at.
    private static func search(_ calls: Calls) -> [String: Any] {
        let found = calls.found
        var out: [String: Any] = [
            "needle": found.needle, "running": found.running, "halted": found.halted ?? NSNull(),
            "mark": calls.mark ?? NSNull(), "treeQuery": calls.reader.query,
            "matches": found.current(calls.search).mapValues { ["before": $0.before, "hit": $0.hit, "after": $0.after] }
        ]
        if let coverage = found.coverage {
            out["coverage"] = ["searched": coverage.searched, "cut": coverage.cut, "binary": coverage.binary,
                               "none": coverage.none, "unavailable": coverage.unavailable, "loading": coverage.loading,
                               "missed": coverage.missed, "held": coverage.held, "words": coverage.words]
        }
        return out
    }

    private static func row(_ call: Call) -> [String: Any] {
        let state: String
        switch call.state {
        case .loading: state = "loading"
        case .done: state = "done"
        case .failed: state = "failed"
        case .canceled: state = "canceled"
        case .earlier: state = "earlier"
        }
        return ["id": call.id, "url": call.url, "method": call.method, "type": call.type,
                "status": call.status ?? NSNull(), "state": state, "failure": call.failure,
                "target": call.target, "source": call.source, "size": call.size ?? NSNull(),
                "redirects": call.redirects, "duration": call.duration ?? NSNull(), "api": call.isAPI,
                "mainFrame": call.mainFrame ?? NSNull()]
    }

    private static func frontend(of tab: Tab) -> WKWebView? {
        let getter = NSSelectorFromString("_inspector")
        guard let page = tab.built, page.responds(to: getter),
              let inspector = page.perform(getter)?.takeUnretainedValue() as? NSObject else { return nil }
        let view = NSSelectorFromString("inspectorWebView")
        guard inspector.responds(to: view) else { return nil }
        return inspector.perform(view)?.takeUnretainedValue() as? WKWebView
    }

    private static func pid(_ web: WKWebView?) -> Int {
        let named = NSSelectorFromString("_webProcessIdentifier")
        guard let web, web.responds(to: named) else { return 0 }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Int32
        return Int(unsafeBitCast(web.method(for: named), to: Getter.self)(web, named))
    }

    private static func plain(_ value: Any) -> Any {
        JSONSerialization.isValidJSONObject(["v": value]) ? value : String(describing: value)
    }
}
