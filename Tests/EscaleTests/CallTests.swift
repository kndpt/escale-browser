// The API Calls panel's values without WebKit: rows merged as their events
// arrive, the 500-row bound, filters, outcomes and the copied report's
// redaction, cuts and unavailable bodies.
import Foundation
import Testing
@testable import Escale

@Suite struct CallTests {
    private func row(_ id: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        ["id": id, "url": "http://127.0.0.1:8080/api/items?q=1", "method": "GET", "type": "fetch"].merging(fields) { $1 }
    }

    @Test func eventsMergeIntoOneRow() {
        var list = CallList()
        list.take([row("1", ["sent": 1.0])])
        list.take([row("1", ["status": 200, "statusText": "OK", "received": 1.012, "finished": true, "size": 58])])
        #expect(list.count == 1)
        let call = list["1"]
        #expect(call?.state == .done(200))
        #expect(call?.duration.map { Int($0.rounded()) } == 12)
        #expect(call?.host == "127.0.0.1:8080")
        #expect(call?.path == "/api/items?q=1")
        #expect(call?.sent == 1.0)
    }

    @Test func rowsWithoutIdentifierAreIgnoredAndNullsKeepValues() {
        var list = CallList()
        list.take([["url": "x"], row("1", ["status": 200])])
        list.take([row("1", ["status": NSNull()])])
        #expect(list.count == 1)
        #expect(list["1"]?.status == 200)
    }

    @Test func listKeepsTheLatestFiveHundred() {
        var list = CallList()
        list.take((0..<520).map { row("\($0)") })
        #expect(list.count == CallList.limit)
        #expect(list.dropped == 20)
        #expect(list["19"] == nil)
        #expect(list["20"] != nil)
        #expect(list.order.first == "20")
        list.clear()
        #expect(list.count == 0 && list.dropped == 0)
    }

    @Test func filtersApiByDefaultAndMatchesText() {
        var list = CallList()
        list.take([row("a"), row("b", ["type": "xhr", "method": "POST"]), row("c", ["type": "document", "url": "http://h/"]),
                   row("d", ["type": "fetch", "status": 404, "url": "http://h/missing"])])
        #expect(list.shown(.api).map(\.id) == ["a", "b", "d"])
        #expect(list.shown(.all).count == 4)
        #expect(list.shown(.api, matching: "post").map(\.id) == ["b"])
        #expect(list.shown(.api, matching: "missing").map(\.id) == ["d"])
        #expect(list.shown(.api, matching: "40").map(\.id) == ["d"])
    }

    @Test func errorsKeepFailuresAnd4xx5xxOnly() {
        var list = CallList()
        list.take([row("ok", ["status": 200, "finished": true]), row("missing", ["status": 404, "finished": true, "url": "http://h/missing"]),
                   row("boom", ["status": 500, "finished": true, "type": "document"]), row("refused", ["failed": true]),
                   row("aborted", ["canceled": true]), row("pending"), row("redirect", ["status": 302, "finished": true])])
        #expect(list.shown(.errors).map(\.id) == ["missing", "boom", "refused", "aborted"])
        // Combined with search: "5" is a status prefix, not any 5 in the address.
        #expect(list.shown(.errors, matching: "5").map(\.id) == ["boom"])
        #expect(list.shown(.errors, matching: "missing").map(\.id) == ["missing"])
    }

    @Test func kindsNarrowAllOnly() {
        var list = CallList()
        list.take([row("doc", ["type": "document"]), row("js", ["type": "script"]), row("css", ["type": "stylesheet"]),
                   row("png", ["type": "image", "url": "http://h/logo.png"]), row("woff", ["type": "font"]),
                   row("beacon", ["type": "beacon"]), row("other", ["type": "other"]), row("api")])
        #expect(list.shown(.all, kind: .document).map(\.id) == ["doc"])
        #expect(list.shown(.all, kind: .script).map(\.id) == ["js"])
        #expect(list.shown(.all, kind: .stylesheet).map(\.id) == ["css"])
        #expect(list.shown(.all, kind: .font).map(\.id) == ["woff"])
        // Other: what no choice names, Fetch and XHR left to their filter.
        #expect(list.shown(.all, kind: .other).map(\.id) == ["beacon", "other"])
        #expect(list.shown(.all, kind: .image, matching: "logo").map(\.id) == ["png"])
        #expect(list.shown(.all, kind: .image, matching: "api").isEmpty)
        // A kind left chosen does nothing outside All.
        #expect(list.shown(.api, kind: .document).map(\.id) == ["api"])
    }

    @Test func bodyMatchesAreListedOnceWithinTheFilter() {
        var list = CallList()
        list.take([row("a", ["url": "http://h/users"]), row("b", ["url": "http://h/orders"]),
                   row("c", ["url": "http://h/users/page", "type": "document"]), row("d", ["url": "http://h/stock"])])
        // "users" in b's response; a matches its address and its response.
        #expect(list.shown(.api, matching: "users", bodies: ["a", "b"]).map(\.id) == ["a", "b"])
        // A document matched in its response stays out of Fetch/XHR.
        #expect(list.shown(.api, matching: "users", bodies: ["c"]).map(\.id) == ["a"])
        #expect(list.shown(.all, matching: "users", bodies: ["c"]).map(\.id) == ["a", "c"])
        #expect(list.shown(.api, bodies: ["b"]).count == 3)
    }

    @Test func neighboursFollowTheListAsShownAndStopAtItsEnds() {
        // Newest first, as the panel shows them.
        let shown = ["d", "b", "a"]
        #expect(CallList.neighbour(of: "b", in: shown, step: -1) == "d")
        #expect(CallList.neighbour(of: "b", in: shown, step: 1) == "a")
        #expect(CallList.neighbour(of: "d", in: shown, step: -1) == nil)
        #expect(CallList.neighbour(of: "a", in: shown, step: 1) == nil)
        // A call the filter hides has no place to step from.
        #expect(CallList.neighbour(of: "c", in: shown, step: 1) == nil)
        #expect(CallList.neighbour(of: "a", in: ["a"], step: -1) == nil)
    }

    @Test func searchRepliesFromTheFrontend() {
        let reply: [String: Any] = [
            "matches": [["id": "7", "before": "\"name\": \"", "hit": "Été", "after": "\", \"n\": 1", "head": false, "tail": true],
                        ["hit": "no id"]],
            "counts": ["text": 5, "cut": 1, "binary": 2, "none": 1, "unavailable": 2, "loading": 1],
            "reasons": ["WebKit does not expose response bodies of dedicated worker requests.": 1],
            "held": 4096]
        let matches = CallSearch.matches(reply)
        #expect(matches.count == 1)
        #expect(matches["7"] == CallSearch.Match(before: "\"name\": \"", hit: "Été", after: "\", \"n\": 1", head: false, tail: true))
        let coverage = CallSearch.Coverage(reply)
        #expect(coverage.searched == 5 && coverage.cut == 1 && coverage.held == 4096)
        // Binary and bodiless calls are not a gap in the search; the others are.
        #expect(coverage.missed == 4)
        #expect(coverage.words.contains("6 responses searched"))
        #expect(coverage.words.contains("1 only in its first 512 KB"))
        #expect(coverage.words.contains("1 unavailable: WebKit does not expose"))
        #expect(coverage.words.contains("\n1 unavailable\n"))
        #expect(coverage.words.contains("2 binary, not searched"))
        #expect(CallSearch.wanted(" a ") == "")
        #expect(CallSearch.wanted(" ab ") == "ab")
    }

    @Test func outcomesAreNamed() {
        func state(_ fields: [String: Any]) -> Call.State? { Call(row("x", fields), seen: Date())?.state }
        #expect(state([:]) == .loading)
        #expect(state(["failed": true, "failure": "Could not connect to the server."]) == .failed("Could not connect to the server."))
        #expect(state(["failed": true, "canceled": true]) == .canceled)
        #expect(state(["early": true, "type": "document"]) == .earlier)
        #expect(state(["early": true, "finished": true, "status": 200]) == .done(200))
        // Seen finishing by the collection, it is no longer earlier.
        var call = Call(row("x", ["early": true]), seen: Date())
        call?.take(row("x", ["finished": true, "status": 204]))
        #expect(call?.state == .done(204))
    }

    @Test func originSaysWhoAsked() {
        #expect(Call(row("1", ["target": "page", "mainFrame": true]), seen: Date())?.origin == "Page")
        #expect(Call(row("1", ["target": "page", "mainFrame": false, "frame": "http://localhost:9/frame"]), seen: Date())?.origin == "Frame · localhost")
        #expect(Call(row("1", ["target": "worker", "targetName": "worker.js"]), seen: Date())?.origin == "Worker · worker.js")
    }

    @Test func bodiesFromTheCollection() {
        #expect(CallBody(["unavailable": "The request failed."]) == .unavailable("The request failed."))
        #expect(CallBody(["body": "{}", "length": 2, "cut": false]) == .text("{}", length: 2, cut: false))
        #expect(CallBody(["body": "AAAA", "length": 4, "base64": true]) == .binary(length: 3))
        #expect(CallBody(["body": "YQ==", "length": 4, "base64": true, "decoded": 1]) == .binary(length: 1))
        #expect(CallBody([:]) == .unavailable("WebKit gave no answer."))
    }

    @Test func detailReadsPairsAndRedirects() {
        let detail = CallDetail(["requestHeaders": [["Accept", "*/*"], ["broken"]], "responseHeaders": [["Content-Type", "application/json"]],
                                 "requestBody": "{\"a\":1}", "requestLength": 7, "requestType": "application/json",
                                 "redirects": [["url": "http://h/old", "status": 302]]])
        #expect(detail.requestHeaders == [CallDetail.Header(name: "Accept", value: "*/*")])
        #expect(detail.responseHeaders.count == 1)
        #expect(detail.requestLength == 7)
        #expect(detail.redirects.first?.status == 302)
    }

    private func report(detail: CallDetail?, body: CallBody?, fields: [String: Any] = [:]) -> String {
        let call = Call(row("1", ["status": 200, "statusText": "OK", "finished": true, "sent": 1.0, "received": 1.01, "mime": "application/json"].merging(fields) { $1 }), seen: Date())!
        let context = CallReport.Context(page: "http://127.0.0.1:8080/", title: "App", environment: "STAGING",
                                         space: "Work", version: "0.1", system: "macOS 27.2")
        return CallReport(call: call, detail: detail, body: body, context: context).text
    }

    @Test func reportRedactsCredentialsButKeepsOrdinaryHeaders() {
        var detail = CallDetail()
        detail.requestHeaders = [.init(name: "Authorization", value: "Bearer secret-1"), .init(name: "Cookie", value: "sid=2"),
                                 .init(name: "X-API-Key", value: "k3"), .init(name: "Accept", value: "application/json")]
        detail.responseHeaders = [.init(name: "Set-Cookie", value: "sid=4"), .init(name: "Content-Type", value: "application/json")]
        let text = report(detail: detail, body: .text("{}", length: 2, cut: false))
        for secret in ["secret-1", "sid=2", "k3", "sid=4"] { #expect(!text.contains(secret)) }
        #expect(text.contains("Authorization: [redacted]"))
        #expect(text.contains("Accept: application/json"))
        #expect(text.contains("Environment (bookmark label): STAGING"))
        #expect(text.contains("## GET /api/items?q=1 → 200 OK"))
        #expect(text.contains("Space: Work"))
    }

    @Test func reportCutsBodiesAndSaysSo() {
        var detail = CallDetail()
        detail.requestBody = String(repeating: "a", count: CallReport.bodyLimit + 10)
        detail.requestLength = CallReport.bodyLimit + 10
        let long = String(repeating: "b", count: CallReport.bodyLimit + 5)
        let text = report(detail: detail, body: .text(long, length: 3_000_000, cut: true))
        #expect(text.contains("first \(CallReport.bodyLimit) shown"))
        #expect(text.contains("3000000 characters"))
        #expect(!text.contains(long))
    }

    @Test func reportNamesMissingBodiesInsteadOfLeavingThemEmpty() {
        let failed = report(detail: CallDetail(), body: .unavailable("The request failed; WebKit keeps no response body."),
                            fields: ["failed": true, "failure": "Could not connect to the server.", "status": NSNull()])
        #expect(failed.contains("Unavailable: The request failed"))
        #expect(failed.contains("Failure (WebKit): Could not connect to the server."))
        #expect(failed.contains("→ failed (Could not connect to the server.)"))
        let earlier = report(detail: nil, body: nil)
        #expect(earlier.contains("Headers: unavailable"))
        #expect(earlier.contains("Not read."))
    }

    @Test func reportFencesOutlastBackticksInBodies() {
        let text = report(detail: CallDetail(), body: .text("a ```` b", length: 8, cut: false))
        #expect(text.contains("`````json"))
    }

    @Test func secretNames() {
        for name in ["authorization", "Proxy-Authorization", "cookie", "set-cookie", "x-auth-token", "X-Api-Key", "session-id"] {
            #expect(CallReport.secret(name))
        }
        for name in ["accept", "content-type", "user-agent", "referer"] { #expect(!CallReport.secret(name)) }
    }
}

// Console-style previews of the JSON tree (JSONPreview.swift).
@Suite struct JSONPreviewTests {
    private func text(_ pieces: [JSONDocument.Piece]) -> String { pieces.map(\.text).joined() }

    @Test func arraysShowTheirCountAndMembers() throws {
        let document = try JSONDocument(#"[{"id":1,"name":"Leanne"},{"id":2},[3]]"#)
        #expect(text(document.preview(0)) == "(3) [{…}, {…}, […]]")
    }

    @Test func objectsShowKeysAndShortValues() throws {
        let document = try JSONDocument(#"{"id":1,"name":"Leanne","ok":true,"none":null,"tags":[1,2],"empty":{}}"#)
        let pieces = document.preview(0)
        #expect(text(pieces) == #"{id: 1, name: "Leanne", ok: true, none: null, tags: […], empty: {}}"#)
        #expect(pieces.first { $0.text == "name" }?.tone == .key)
        #expect(pieces.first { $0.text == "\"Leanne\"" }?.tone == .string)
        #expect(pieces.first { $0.text == "1" }?.tone == .number)
        #expect(pieces.first { $0.text == "true" }?.tone == .literal)
        #expect(pieces.first { $0.text == "null" }?.tone == .null)
    }

    @Test func previewsStopAtTheirBudget() throws {
        let members = (0..<40).map { "\"key\($0)\":\"value \($0)\"" }.joined(separator: ",")
        let document = try JSONDocument("{" + members + "}")
        let line = text(document.preview(0, budget: 60))
        #expect(line.hasSuffix(", …}"))
        #expect(line.count < 90)
    }

    @Test func aLongFirstKeyStaysWithinTheBudget() throws {
        let document = try JSONDocument("{\"" + String(repeating: "k", count: 5000) + "\": 1, \"b\": 2}")
        let line = text(document.preview(0, budget: 60))
        #expect(line.count < 90)
        #expect(line.hasPrefix("{kkkk") && line.contains("…"))
    }

    @Test func longLeavesAreCutAndStayQuoted() throws {
        let document = try JSONDocument("[\"" + String(repeating: "a", count: 300) + "\", 12345]")
        let leaf = document.leaf(1, limit: 20)
        #expect(leaf.text.count == 21 && leaf.text.hasSuffix("…\""))
        #expect(document.leaf(2).text == "12345")
        #expect(text(document.preview(0)).contains("…\""))
    }
}

// Copy as › cURL (Curl.swift).
@Suite struct CurlTests {
    private func call(_ method: String, url: String = "https://api.example.test/v1/items?q=1") -> Call {
        var call = Call(id: "1")
        call.method = method
        call.url = url
        return call
    }

    private func detail(_ headers: [(String, String)], body: String? = nil) -> CallDetail {
        var detail = CallDetail()
        detail.requestHeaders = headers.map { CallDetail.Header(name: $0.0, value: $0.1) }
        detail.requestBody = body
        detail.requestLength = body?.count
        return detail
    }

    @Test func aGetIsItsAddressAndHeaders() {
        let text = Curl.command(call("GET"), detail([("Accept", "application/json"), ("Host", "api.example.test"), ("Accept-Encoding", "gzip, br")]))
        #expect(text == "curl 'https://api.example.test/v1/items?q=1' \\\n  -H 'Accept: application/json' \\\n  --compressed")
    }

    @Test func aPostSendsItsBodyWithoutRepeatingTheMethod() {
        let text = Curl.command(call("POST"), detail([("Content-Type", "application/json"), ("Content-Length", "13"), ("Authorization", "Bearer t")], body: #"{"a":"it's"}"#))
        #expect(text.contains("-H 'Authorization: Bearer t'"))
        #expect(!text.contains("Content-Length") && !text.contains("-X"))
        #expect(text.hasSuffix(#"--data-raw '{"a":"it'\''s"}'"#))
    }

    @Test func otherMethodsAreNamed() {
        #expect(Curl.command(call("PUT"), detail([], body: "x")).contains("-X 'PUT'"))
        #expect(Curl.command(call("DELETE"), detail([])).contains("-X 'DELETE'"))
        #expect(Curl.command(call("POST"), detail([])).contains("-X 'POST'"))
        #expect(Curl.command(call("HEAD"), detail([])).contains("--head"))
    }

    @Test func quotingIsLiteral() {
        #expect(Curl.quote("a'b $HOME `x` !") == #"'a'\''b $HOME `x` !'"#)
    }

    @Test func noCommandWithoutHeadersOrWithACutBody() {
        #expect(Curl.missing(call("GET"), nil) == "Headers unavailable")
        var cut = detail([], body: "abc")
        cut.requestCut = true
        #expect(Curl.missing(call("POST"), cut) == "Body too long to copy")
        #expect(Curl.missing(call("GET"), detail([])) == nil)
        // WebKit counts UTF-16 units: an emoji body is longer there, not cut.
        var emoji = detail([], body: "👋🏽 ok")
        emoji.requestLength = 7
        #expect(Curl.missing(call("POST"), emoji) == nil)
    }
}
