// One exchange as WebKit's inspector collection reported it (calls.js), and
// the bounded list the API Calls panel shows. Values only: no WebKit, no body.
// A row is merged as its events arrive (added, response, finished, failed);
// the list keeps the 500 most recently first seen and says how many it let go,
// so a long session costs a fixed amount rather than a growing one. Pausing
// is calls.js's: it stops reporting exchanges it did not already know, so a
// row that reaches the list was known before the pause and keeps its events.
import Foundation

struct Call: Identifiable, Equatable {
    let id: String
    var url = ""
    var method = "GET"
    /// WebKit's resource type without its prefix: fetch, xhr, document, …
    var type = "other"
    var status: Int?
    var statusText = ""
    var mime = ""
    var finished = false
    var failed = false
    var canceled = false
    var failure = ""
    /// network, memory-cache, disk-cache, service-worker, …
    var source = ""
    /// page, worker, service-worker: who made the request.
    var target = ""
    var targetName = ""
    var frame = ""
    var mainFrame: Bool?
    var requestBytes: Int?
    /// WebKit's timestamps, in seconds on its own clock.
    var sent: Double?
    var received: Double?
    var ended: Double?
    var size: Double?
    var transfer: Double?
    var redirects = 0
    /// Known to WebKit before the collection began: its exchange was not seen.
    var early = false
    /// When Escale first heard of it.
    var seen: Date

    /// A row from calls.js; nil without an identifier.
    init?(_ row: [String: Any], seen: Date) {
        guard let id = row["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        self.seen = seen
        take(row)
    }

    init(id: String, seen: Date = Date()) {
        self.id = id
        self.seen = seen
    }

    /// A later event for the same exchange: every field it knows wins.
    mutating func take(_ row: [String: Any]) {
        func string(_ key: String) -> String? { row[key] as? String }
        func double(_ key: String) -> Double? { (row[key] as? NSNumber)?.doubleValue }
        if let value = string("url") { url = value }
        if let value = string("method") { method = value }
        if let value = string("type") { type = value }
        if let value = double("status") { status = Int(value) }
        if let value = string("statusText") { statusText = value }
        if let value = string("mime") { mime = value }
        if let value = row["finished"] as? Bool { finished = value }
        if let value = row["failed"] as? Bool { failed = value }
        if let value = row["canceled"] as? Bool { canceled = value }
        if let value = string("failure") { failure = value }
        if let value = string("source") { source = value }
        if let value = string("target") { target = value }
        if let value = string("targetName") { targetName = value }
        if let value = string("frame") { frame = value }
        if let value = row["mainFrame"] as? Bool { mainFrame = value }
        if let value = double("requestBytes") { requestBytes = Int(value) }
        if let value = double("sent") { sent = value }
        if let value = double("received") { received = value }
        if let value = double("ended") { ended = value }
        if let value = double("size") { size = value }
        if let value = double("transfer") { transfer = value }
        if let value = double("redirects") { redirects = Int(value) }
        // Stays marked until the collection sees it finish or fail.
        if row["early"] as? Bool == true { early = true }
    }

    /// Fetch and XHR: what the page's own code asked for.
    var isAPI: Bool { type == "fetch" || type == "xhr" }

    enum State: Equatable {
        case loading, done(Int), failed(String), canceled, earlier
    }

    var state: State {
        if canceled { return .canceled }
        // Known before the collection began: no exchange was seen.
        if early && !failed && (status == nil || !finished) { return .earlier }
        if failed { return .failed(failure.isEmpty ? "Failed" : failure) }
        if let status, finished || received != nil { return .done(status) }
        return .loading
    }

    /// Milliseconds from the request to its last event, once there is one.
    var duration: Double? {
        guard let sent else { return nil }
        let last = [received, ended].compactMap { $0 }.max()
        return last.map { max(0, ($0 - sent) * 1000) }
    }

    var address: URL? { URL(string: url) }
    var host: String {
        guard let address, let host = address.host else { return "" }
        return address.port.map { "\(host):\($0)" } ?? host
    }
    /// The path and query, which is what tells two calls to one host apart.
    var path: String {
        guard let address, address.host != nil else { return url }
        var path = address.path.isEmpty ? "/" : address.path
        if let query = address.query { path += "?" + query }
        return path
    }

    /// Who made the request, in words.
    var origin: String {
        switch target {
        case "worker": return targetName.isEmpty ? "Dedicated worker" : "Worker · " + targetName
        case "service-worker": return "Service worker"
        default:
            if mainFrame == false {
                let host = URL(string: frame)?.host
                return "Frame · " + (host ?? frame)
            }
            return "Page"
        }
    }

    static func bytes(_ count: Double?) -> String {
        guard let count, count >= 0 else { return "—" }
        if count < 1024 { return "\(Int(count)) B" }
        if count < 1024 * 1024 { return String(format: "%.1f KB", count / 1024) }
        return String(format: "%.1f MB", count / 1024 / 1024)
    }

    static func milliseconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value < 1000 { return "\(Int(value.rounded())) ms" }
        return String(format: "%.2f s", value / 1000)
    }
}

/// The rows the panel holds for one tab, in the order they were first seen.
struct CallList: Equatable {
    static let limit = 500

    private(set) var order: [String] = []
    private(set) var calls: [String: Call] = [:]
    /// How many older rows were let go to stay within the limit.
    private(set) var dropped = 0

    var count: Int { order.count }

    mutating func take(_ rows: [[String: Any]], at time: Date = Date()) {
        for row in rows {
            guard let id = row["id"] as? String else { continue }
            if var known = calls[id] {
                known.take(row)
                calls[id] = known
            } else if let call = Call(row, seen: time) {
                calls[id] = call
                order.append(id)
            }
        }
        let over = order.count - Self.limit
        if over > 0 {
            for id in order.prefix(over) { calls[id] = nil }
            order.removeFirst(over)
            dropped += over
        }
    }

    mutating func clear() {
        order = []
        calls = [:]
        dropped = 0
    }

    subscript(id: String) -> Call? { calls[id] }

    enum Filter: Hashable { case api, all }

    /// The calls of `filter` matching `text`, newest last, as the page made
    /// them. `bodies` are calls whose response matched the same text
    /// (CallSearch.swift): they are listed once, like any other match.
    func shown(_ filter: Filter, matching text: String = "", bodies: Set<String> = []) -> [Call] {
        let needle = text.trimmingCharacters(in: .whitespaces)
        return order.compactMap { calls[$0] }.filter { call in
            (filter == .all || call.isAPI) &&
                (needle.isEmpty || call.url.localizedCaseInsensitiveContains(needle) ||
                 call.method.localizedCaseInsensitiveContains(needle) ||
                 call.status.map { String($0).hasPrefix(needle) } == true ||
                 bodies.contains(call.id))
        }
    }

    /// The call `step` places away from `id` in `ids`, the list as shown;
    /// nil past either end, and nil for a call the list no longer shows.
    static func neighbour(of id: String, in ids: [String], step: Int) -> String? {
        guard let at = ids.firstIndex(of: id), ids.indices.contains(at + step) else { return nil }
        return ids[at + step]
    }
}

/// What calls.js reads for one call on request: headers and the sent body,
/// already cut. Held only while its call is the one shown.
struct CallDetail: Equatable {
    var requestHeaders: [Header] = []
    var responseHeaders: [Header] = []
    var requestType = ""
    /// The body the page sent, cut at `CallDetail.sentLimit` UTF-8 bytes.
    var requestBody: String?
    /// Its full length in UTF-16 code units, as WebKit counts it.
    var requestLength: Int?
    /// Whether `requestBody` is only the start of what was sent.
    var requestCut = false
    var redirects: [(url: String, status: Int?)] = []
    var initiator = ""

    static let sentLimit = 64 * 1024

    struct Header: Equatable, Hashable {
        let name: String
        let value: String
    }

    init() {}

    init(_ reply: [String: Any]) {
        func headers(_ key: String) -> [Header] {
            (reply[key] as? [[Any]] ?? []).compactMap { pair in
                guard pair.count == 2, let name = pair[0] as? String, let value = pair[1] as? String else { return nil }
                return Header(name: name, value: value)
            }
        }
        requestHeaders = headers("requestHeaders")
        responseHeaders = headers("responseHeaders")
        requestType = reply["requestType"] as? String ?? ""
        requestBody = reply["requestBody"] as? String
        requestLength = (reply["requestLength"] as? NSNumber)?.intValue
        requestCut = reply["requestCut"] as? Bool ?? false
        redirects = (reply["redirects"] as? [[String: Any]] ?? []).map {
            (url: $0["url"] as? String ?? "", status: ($0["status"] as? NSNumber)?.intValue)
        }
        initiator = reply["initiator"] as? String ?? ""
    }

    static func == (a: CallDetail, b: CallDetail) -> Bool {
        a.requestHeaders == b.requestHeaders && a.responseHeaders == b.responseHeaders &&
            a.requestType == b.requestType && a.requestBody == b.requestBody &&
            a.requestLength == b.requestLength && a.requestCut == b.requestCut && a.initiator == b.initiator &&
            a.redirects.map(\.url) == b.redirects.map(\.url) && a.redirects.map(\.status) == b.redirects.map(\.status)
    }
}

/// A response body as WebKit's backend gave it, or why there is none.
enum CallBody: Equatable {
    case reading
    /// Text, cut at `CallBody.limit`; `length` is WebKit's full length.
    case text(String, length: Int, cut: Bool)
    case binary(length: Int)
    case unavailable(String)

    /// The JSON reader's own limit in UTF-8 bytes (JSONDocument.byteLimit),
    /// applied by calls.js before the body leaves the frontend: a longer
    /// body could not be read structured anyway.
    static let limit = JSONDocument.byteLimit

    init(_ reply: [String: Any]) {
        if let reason = reply["unavailable"] as? String {
            self = .unavailable(reason)
        } else if let body = reply["body"] as? String {
            let length = (reply["length"] as? NSNumber)?.intValue ?? body.count
            if reply["base64"] as? Bool == true {
                // The decoded size from the frontend; else three bytes in four characters.
                self = .binary(length: (reply["decoded"] as? NSNumber)?.intValue ?? length / 4 * 3)
            } else {
                self = .text(body, length: length, cut: reply["cut"] as? Bool ?? false)
            }
        } else {
            self = .unavailable("WebKit gave no answer.")
        }
    }
}
