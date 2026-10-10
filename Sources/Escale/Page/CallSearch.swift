// The API Calls panel's search in response bodies (Calls.swift, calls.js).
// Bodies stay in WebKit until a call is opened, so the words typed in the
// list's field are looked for where they are: calls.js reads each response
// of the calls listed from WebKit's backend, in the inspector frontend's
// process, and sends back only the calls that match, each with a short
// excerpt around its first occurrence. Nothing is replayed or sent anywhere.
//
// It works only while a search of two characters or more is typed. Typing
// waits a quarter of a second before searching; the frontend keeps what it
// read, within `perBody` characters of each response and `held` in all
// (oldest read let go first), so the next keystroke reads only what it has
// not read yet, and lets it go when the field is emptied. New responses while a search stands are searched once the
// current pass ends, never two passes at once. A newer search, clearing or
// stopping ends an older one, whose late answer is dropped. What could not
// be searched in full (binary, unavailable, still loading, longer than the
// limit) is counted so the panel does not claim more than it looked at.
import SwiftUI
import WebKit

@MainActor
final class CallSearch: ObservableObject {
    /// Characters of a response searched and kept; a longer one is searched
    /// in its first part only, and said to be.
    nonisolated static let perBody = 512 * 1024
    /// Characters kept by the frontend across searches, all responses together.
    static let held = 8 * 1024 * 1024
    /// Responses read from WebKit at once.
    static let readers = 4
    /// A single character would match nearly every response.
    nonisolated static let shortest = 2
    /// Characters of excerpt before the occurrence (twice as many after).
    static let around = 20
    static let delay = 0.25

    struct Match: Equatable {
        var before = ""
        var hit = ""
        var after = ""
        /// The excerpt starts at the response's start, or ends at its end.
        var head = false
        var tail = false
    }

    /// What a finished pass looked at, by what became of each response.
    struct Coverage: Equatable {
        var searched = 0
        /// Searched in their first `perBody` characters only.
        var cut = 0
        var binary = 0
        /// No body exists: failed, canceled, beacon, WebSocket.
        var none = 0
        var unavailable = 0
        var loading = 0
        /// Why WebKit gave no body, with how many calls each.
        var reasons: [String: Int] = [:]
        /// Characters the frontend holds for the next search.
        var held = 0

        /// Responses the search did not read in full although they exist.
        var missed: Int { cut + unavailable + loading }

        init() {}

        init(_ reply: [String: Any]) {
            let counts = reply["counts"] as? [String: Any] ?? [:]
            func count(_ key: String) -> Int { (counts[key] as? NSNumber)?.intValue ?? 0 }
            searched = count("text")
            cut = count("cut")
            binary = count("binary")
            none = count("none")
            unavailable = count("unavailable")
            loading = count("loading")
            reasons = (reply["reasons"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue }
            held = (reply["held"] as? NSNumber)?.intValue ?? 0
        }

        /// The detail behind the panel's one line, for its tooltip.
        var words: String {
            var parts = ["\(searched + cut) \(searched + cut == 1 ? "response" : "responses") searched"]
            if cut > 0 { parts.append("\(cut) only in \(cut == 1 ? "its" : "their") first \(CallSearch.perBody / 1024) KB") }
            if loading > 0 { parts.append("\(loading) still loading") }
            for (reason, count) in reasons.sorted(by: { $0.key < $1.key }) { parts.append("\(count) unavailable: \(reason)") }
            let other = unavailable - reasons.values.reduce(0, +)
            if other > 0 { parts.append("\(other) unavailable") }
            if binary > 0 { parts.append("\(binary) binary, not searched") }
            if none > 0 { parts.append("\(none) without a body (failed, canceled or beacon)") }
            return parts.joined(separator: "\n")
        }
    }

    /// The text the matches are for; they are stale for any other.
    @Published private(set) var needle = ""
    @Published private(set) var matches: [String: Match] = [:]
    /// A pass is waiting for typing to rest, or reading.
    @Published private(set) var running = false
    /// The last finished pass; nil before one, or when none could run.
    @Published private(set) var coverage: Coverage?
    /// Why no pass can run: the collection has stopped.
    @Published private(set) var halted: String?

    private weak var calls: Calls?
    private var wait: DispatchWorkItem?
    private var revision = 0
    /// Responses arrived while a pass was running: search again after it.
    private var again = false
    /// The calls in scope and how many had finished, at the last pass.
    private var looked: (count: Int, finished: Int) = (0, 0)

    init(_ calls: Calls) {
        self.calls = calls
    }

    nonisolated static func wanted(_ text: String) -> String {
        let needle = text.trimmingCharacters(in: .whitespaces)
        return needle.count >= shortest ? needle : ""
    }

    /// The matches for `text` as typed now; none while they are stale.
    func current(_ text: String) -> [String: Match] {
        let asked = Self.wanted(text)
        return !asked.isEmpty && asked == needle ? matches : [:]
    }

    /// The field or the filter changed: search again once typing rests.
    func typed() {
        guard let calls else { return }
        let asked = Self.wanted(calls.search)
        wait?.cancel()
        wait = nil
        if asked.isEmpty {
            // No search stands: the frontend lets go of what it read.
            if !needle.isEmpty || running {
                calls.searchFrontend?.evaluateJavaScript("window.__escaleCalls && window.__escaleCalls.drop()")
            }
            end()
            return
        }
        if asked != needle { matches = [:]; coverage = nil }
        schedule()
    }

    /// Rows arrived: a standing search looks at responses that finished
    /// since its last pass, after the pass under way if there is one.
    func arrived() {
        guard let calls, !Self.wanted(calls.search).isEmpty else { return }
        let scope = calls.list.shown(calls.filter, kind: calls.kind)
        let finished = scope.filter { $0.finished || $0.failed || $0.canceled }.count
        guard scope.count != looked.count || finished != looked.finished else { return }
        if running { again = true } else if wait == nil { schedule() }
    }

    /// Cleared or stopped: no pass, no matches; the frontend drops what it
    /// held on its own side.
    func end() {
        wait?.cancel()
        wait = nil
        revision += 1
        again = false
        running = false
        needle = ""
        matches = [:]
        coverage = nil
        halted = nil
        looked = (0, 0)
    }

    /// Waiting for typing to rest counts as searching: the matches shown
    /// are not yet those of the text or the list as they stand.
    private func schedule() {
        let work = DispatchWorkItem { [weak self] in self?.pass() }
        wait = work
        running = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    private func pass() {
        wait = nil
        guard let calls else { return }
        let asked = Self.wanted(calls.search)
        guard !asked.isEmpty else { end(); return }
        guard let frontend = calls.searchFrontend else {
            revision += 1
            running = false
            needle = asked
            matches = [:]
            coverage = nil
            halted = "The collection has stopped; responses are no longer read from WebKit."
            return
        }
        halted = nil
        revision += 1
        let token = revision
        let scope = calls.list.shown(calls.filter, kind: calls.kind)
        looked = (scope.count, scope.filter { $0.finished || $0.failed || $0.canceled }.count)
        again = false
        running = true
        let ids = scope.reversed().map(\.id)
        frontend.callAsyncJavaScript(
            "return window.__escaleCalls ? await window.__escaleCalls.search(needle, ids, per, total, readers, around) : null",
            arguments: ["needle": asked, "ids": ids, "per": Self.perBody, "total": Self.held,
                        "readers": Self.readers, "around": Self.around],
            in: nil, in: .page) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.revision == token else { return }
                self.running = false
                if case .success(let value) = result, let reply = value as? [String: Any], reply["superseded"] == nil {
                    self.needle = asked
                    self.matches = Self.matches(reply)
                    self.coverage = Coverage(reply)
                } else if case .failure(let error) = result {
                    self.needle = asked
                    self.matches = [:]
                    self.coverage = nil
                    self.halted = error.localizedDescription
                }
                if self.again { self.again = false; self.schedule() }
            }
        }
    }

    nonisolated static func matches(_ reply: [String: Any]) -> [String: Match] {
        var found: [String: Match] = [:]
        for item in reply["matches"] as? [[String: Any]] ?? [] {
            guard let id = item["id"] as? String, let hit = item["hit"] as? String else { continue }
            found[id] = Match(before: item["before"] as? String ?? "", hit: hit, after: item["after"] as? String ?? "",
                              head: item["head"] as? Bool ?? false, tail: item["tail"] as? Bool ?? false)
        }
        return found
    }
}
