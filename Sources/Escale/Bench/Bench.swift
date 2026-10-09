import AppKit
import AuthenticationServices
import SwiftUI
import WebKit

// A way for a script on this Mac to drive the browser you already have open,
// in tabs of its own, without ever taking the window from you.
//
// Off unless switched on in Settings › Developer. On, the app listens on a Unix
// socket in its own folder — readable by this user and nobody else, and the
// other end is checked for the same uid before a word is read. One JSON
// object per line in, one per line out, one request per connection. The
// tabs it opens sit at the end of your row with a flask on them, are never
// selected on your behalf, never enter the session or the history, and go
// when the script says so. `./bench` at the root of the repository speaks
// this protocol from the shell.
//
// Pages a script has opened but you are not looking at live in a window of
// their own, off every screen: WebKit lays out and paints a page only when
// it has a size and a window, and a snapshot of a page that has neither is
// a snapshot of nothing.

@MainActor
final class Bench {
    static let shared = Bench()
    private var awake: NSObjectProtocol?

    private weak var browser: Browser?
    private var listener: Int32 = -1
    private var accepting: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]

    /// Where the socket is. Beside the session file, so a test run's bench is
    /// as separate from the real one as everything else it keeps.
    static var socket: URL { Store.file("bench.sock") }

    /// True while something is listening.
    private(set) var running = false

    /// The key code of a letter on a US keyboard, which is what WebKit reads
    /// alongside the characters; anything else goes as the space bar's.
    static func keyCode(for character: Character) -> UInt16 {
        let codes: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
            "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        ]
        return codes[Character(character.lowercased())] ?? 49
    }

    /// Where the traffic lights are: each one's left edge and its centre's
    /// height from the top, in the window's points.
    static func lights(of window: NSWindow) -> [[Int]] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { type in
            guard let button = window.standardWindowButton(type) else { return nil }
            let frame = button.convert(button.bounds, to: nil)
            return [Int(frame.minX.rounded()), Int((window.frame.height - frame.midY).rounded())]
        }
    }

    // MARK: - starting and stopping

    func start(for browser: Browser) {
        guard !running else { return }
        self.browser = browser
        // Nor App Nap, which a test run behind other windows falls into.
        if Store.testing, !Store.measuring, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Bench")
        }
        let path = Bench.socket.path
        try? FileManager.default.createDirectory(
            at: Bench.socket.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        unlink(path)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let room = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < room else { close(fd); return }
        withUnsafeMutablePointer(to: &address.sun_path) { sun in
            sun.withMemoryRebound(to: CChar.self, capacity: room) { bytes in
                _ = strlcpy(bytes, path, room)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd)
            unlink(path)
            return
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        accepting = source
        listener = fd
        running = true
    }

    func stop() {
        guard running else { return }
        accepting?.cancel()
        accepting = nil
        close(listener)
        listener = -1
        unlink(Bench.socket.path)
        clients.values.forEach { $0.drop() }
        clients = [:]
        running = false
        BenchPointer.stop()
        Bench.releaseQueue()
        // The tabs a script left open go with it.
        if let browser {
            for tab in browser.tabs where tab.bench { browser.close(tab) }
        }
    }

    private func accept() {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        // Only this user. The file mode already says so; this says it again,
        // for the day the folder's permissions are not what they were.
        var uid = uid_t(0)
        var gid = gid_t(0)
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            close(fd)
            return
        }
        let client = Client(fd: fd) { [weak self] request, answer in
            self?.handle(request, answer)
        } gone: { [weak self] fd in
            self?.clients[fd] = nil
        }
        clients[fd] = client
    }

    // MARK: - one connection

    /// Reads until a newline, hands the line up, writes the answer, closes.
    private final class Client {
        let fd: Int32
        private var bytes = Data()
        private let source: DispatchSourceRead
        private let handle: ([String: Any], @escaping ([String: Any]) -> Void) -> Void
        private let gone: (Int32) -> Void
        private var answered = false

        init(
            fd: Int32,
            handle: @escaping ([String: Any], @escaping ([String: Any]) -> Void) -> Void,
            gone: @escaping (Int32) -> Void
        ) {
            self.fd = fd
            self.handle = handle
            self.gone = gone
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self] in self?.read() }
            source.resume()
        }

        private func read() {
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count <= 0 {
                if count == 0 || errno != EAGAIN { drop() }
                return
            }
            bytes.append(contentsOf: chunk[0..<count])
            // A line that never ends is not a request.
            if bytes.count > 4_000_000 {
                say(["error": "request too long"])
                return
            }
            guard let newline = bytes.firstIndex(of: 0x0A) else { return }
            let line = bytes[bytes.startIndex..<newline]
            bytes = Data()
            source.cancel()
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                say(["error": "not a JSON object"])
                return
            }
            handle(json) { [weak self] answer in self?.say(answer) }
        }

        private func say(_ answer: [String: Any]) {
            guard !answered else { return }
            answered = true
            var out = (try? JSONSerialization.data(withJSONObject: answer)) ?? Data("{\"error\":\"unwritable answer\"}".utf8)
            out.append(0x0A)
            out.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                    if n <= 0 {
                        if errno == EAGAIN { usleep(2000); continue }
                        break
                    }
                    sent += n
                }
            }
            drop()
        }

        func drop() {
            if !source.isCancelled { source.cancel() }
            close(fd)
            gone(fd)
        }
    }

    // MARK: - the commands

    private func handle(_ request: [String: Any], _ given: @escaping ([String: Any]) -> Void) {
        // One answer, and always one: a page that never replies to a script
        // would otherwise hold the bench — every later command waits behind it.
        var answered = false
        let answer: ([String: Any]) -> Void = { reply in
            guard !answered else { return }
            answered = true
            given(reply)
        }
        let patience = (request["do"] as? String) == "wait" ? (request["seconds"] as? Double ?? 30) + 5 : 25
        DispatchQueue.main.asyncAfter(deadline: .now() + patience) { answer(["error": "no answer within \(Int(patience)) s"]) }
        guard let browser else {
            answer(["error": "no browser"])
            return
        }
        let verb = request["do"] as? String ?? ""

        switch verb {
        case "github":
            answer(GitHubBench.run(request, browser: browser))
        case "panels":
            answer(PanelBench.run(request, browser: browser))
        case "update":
            // The update's door and panels (UpdateBench.swift).
            answer(UpdateBench.run(request, browser: browser))
        case "calls":
            // The API Calls panel (CallsBench.swift).
            guard Store.testing else { answer(["error": "calls needs a test world"]); return }
            CallsBench.run(request, browser: browser, tab: find(request, in: browser), answer: answer)
        case "github-data":
            // Bearings' GitHub owners, files and page reading (GitHubDataBench.swift).
            guard Store.testing else { answer(["error": "github-data needs a test world"]); return }
            GitHubDataBench.run(request, browser: browser, tab: find(request, in: browser), answer: answer)
        case "tabs":
            answer(["tabs": browser.tabs.map(describe)])

        case "media":
            guard Store.testing else { answer(["error": "only in a test run"]); return }
            if let id = request["id"] as? String,
               let tab = (browser.tabs + browser.parkedTabs).first(where: { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) }) {
                let action = request["action"] as? String ?? "state"
                if action == "fixture", let html = request["html"] as? String,
                   let base = (request["base"] as? String).flatMap(URL.init(string:)) {
                    // Synthetic site controls keep their real origin without
                    // loading an account, a network document or a media file.
                    tab.web.loadHTMLString(html, baseURL: base)
                }
                else if action == "dismiss" { tab.media.dismiss() }
                else if action == "return" { browser.returnToMedia(tab.id) }
                else if action == "float" { browser.floatMedia(tab.id) }
                else if action == "minimize" { browser.floater.onMinimize?() }
                // The window's own buttons, by the callbacks they press.
                else if action == "close" { browser.floater.onClose?() }
                else if action == "back" { browser.floater.onReturn?() }
                else if action == "mute" { browser.floater.onPress?("microphone") }
                else if action == "hangup" { browser.floater.onPress?("leave") }
                else if ["camera", "present", "hand"].contains(action) { browser.floater.onPress?(action) }
                else if action != "state" { tab.media.command(action, value: request["value"] as? Double) }
            }
            answer(["sources": (browser.tabs + browser.parkedTabs).filter { $0.media.state != nil }.map { tab -> [String: Any] in
                let state = tab.media.state
                return ["id": tab.id.uuidString, "space": tab.space.uuidString, "noisy": tab.noisy,
                        "title": state?.title ?? "", "key": state?.key ?? "", "playing": state?.playing ?? false,
                        "muted": state?.muted ?? false, "video": state?.video ?? false, "actions": Array(state?.actions ?? []).sorted(),
                        "volume": state?.volume as Any? ?? NSNull(), "listening": tab.media.listening,
                        "busy": tab.media.busy, "error": tab.media.error as Any? ?? NSNull()]
            }, "visible": browser.playback.visible.map { $0.id.uuidString },
                    "floating": browser.floating?.uuidString as Any? ?? NSNull(),
                    "floatCall": browser.floater.call, "floatControls": browser.floater.offered,
                    "floatLooks": browser.floater.looks,
                    "marks": browser.spaces.map { browser.presence(in: $0.id)?.symbol ?? "" },
                    "selected": browser.playback.source?.id.uuidString as Any? ?? NSNull(),
                    "listeners": (browser.tabs + browser.parkedTabs).filter { $0.media.listening }.count])

        case "migration":
            answer(browser.migration.bench(request, browser: browser))

        case "transfer":
            answer(browser.transfer.bench(request, browser: browser))

        case "localhost":
            // `open` takes an origin and acts as a click on its entry.
            if Store.testing, let origin = request["open"] as? String,
               let entry = browser.localhost.entries(in: browser.spaceID).first(where: { $0.origin == origin }) {
                browser.openLocalhost(entry)
            }
            // `check` reads the listening ports as opening the panel does,
            // and `reading` tells when its answer has landed.
            if Store.testing, request["check"] as? Bool == true { browser.localhost.check() }
            let hub = browser.localhost
            answer(["count": hub.entries(in: browser.spaceID).count, "reachable": hub.reachable(in: browser.spaceID),
                    "reading": hub.reading, "read": hub.listening != nil, "entries": hub.entries(in: browser.spaceID).map {
                ["origin": $0.origin, "url": $0.url, "title": $0.title, "visited": $0.visited.timeIntervalSince1970,
                 "state": "\(hub.availability(of: $0))"]
            }])
        case "alerts":
            let alerts = DeveloperAlerts.shared
            answer(["running": alerts.running, "delegate": alerts.delegateActive, "received": alerts.received,
                    "filtered": alerts.filtered, "posted": alerts.posted,
                    "trouble": alerts.trouble ?? ""])

        case "open":
            guard let url = (request["url"] as? String).flatMap(Address.url(from:)) else {
                answer(["error": "open needs a url"])
                return
            }
            let tab = browser.benchOpen(url)
            house(tab)
            answer(describe(tab))

        case "go":
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            guard let url = (request["url"] as? String).flatMap(Address.url(from:)) else {
                answer(["error": "go needs a url"])
                return
            }
            tab.go(to: url)
            answer(describe(tab))

        case "history":
            // Exercise the bounded list and direct jump used by HistoryDoor.
            guard Store.testing else { answer(["error": "history only works on a --test run"]); return }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            let pages = tab.recent(back: request["back"] as? Bool ?? true)
            if let index = request["index"] as? Int {
                guard pages.indices.contains(index - 1) else { answer(["error": "no history entry at index \(index)"]); return }
                tab.go(to: pages[index - 1])
            }
            answer(["items": pages.map { ["title": $0.title ?? "", "url": $0.url.absoluteString] },
                    "chosen": request["index"] as? Int ?? 0])

        case "visual-pick", "page-capture":
            guard Store.testing else { answer(["error": "page tools need a test world"]); return }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            let action = request["action"] as? String ?? "state"
            if request["do"] as? String == "visual-pick" {
                if action == "start" { browser.pickVisual(forCapture: request["capture"] as? Bool == true) }
                if action == "stop" { tab.visual.stop() }
                if action == "more", tab.visual.selection != nil { tab.visual.detailed = true }
                var state: [String: Any] = ["active":tab.visual.active, "failure":tab.visual.error ?? "", "selected":tab.visual.selection != nil]
                if let selected = tab.visual.selection {
                    state["label"] = selected.label
                    state["width"] = selected.rect.width; state["height"] = selected.rect.height
                    state["styles"] = selected.styles.map { ["name":$0.name,"value":$0.value] }
                    state["shadow"] = selected.shadow; state["frame"] = selected.frame
                }
                if let glance = tab.visual.glance {
                    state["glance"] = ["label":glance.label, "family":glance.family, "size":glance.fontSize, "line":glance.line,
                                       "weight":glance.weight, "colour":glance.ink.text, "background":glance.fill?.text ?? "",
                                       "padding":glance.padding ?? ""]
                }
                if let anchor = tab.visual.anchor {
                    state["anchor"] = ["x":anchor.minX, "y":anchor.minY, "width":anchor.width, "height":anchor.height]
                }
                state["detailed"] = tab.visual.detailed
                answer(state)
            } else {
                if action == "take", let mode = PageCapture.Mode(rawValue: request["mode"] as? String ?? "visible") {
                    browser.capturePage(mode, selection:tab.visual.selection)
                }
                if action == "close" { tab.capture.close() }
                // Select Area: start it or cancel it; a ./bench drag draws and captures it.
                if action == "area" {
                    switch request["step"] as? String {
                    case "start": browser.pickArea()
                    case "stop": tab.area.stop()
                    default: break
                    }
                }
                if let include = request["url"] as? Bool { tab.capture.includeURL = include }
                if let include = request["version"] as? Bool { tab.capture.includeVersion = include }
                if let path = request["path"] as? String, let png = tab.capture.png {
                    let url = URL(fileURLWithPath:path).standardizedFileURL
                    guard url.path.hasPrefix("/tmp/escale-") || url.path.hasPrefix("/private/tmp/escale-") else { answer(["error":"test captures need /tmp/escale- destination"]); return }
                    do { try Store.export(png,to:url) } catch { answer(["error":error.localizedDescription]); return }
                }
                let area = tab.area.rect.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? []
                answer(["area":["active":tab.area.active,"ready":tab.area.ready,"rect":area],
                        "shown":tab.capture.shown,"busy":tab.capture.busy,"bytes":tab.capture.png?.count ?? 0,
                        "failure":tab.capture.error ?? "","notice":tab.capture.notice,"context":tab.capture.context])
            }

        case "json-reader", "site-storage":
            guard Store.testing else { answer(["error": "page tools need a test world"]); return }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            let action = request["action"] as? String ?? "state"
            if request["do"] as? String == "json-reader" {
                let reader = tab.jsonReader
                if action == "open" { reader.open(tab.built) }
                if action == "raw" { reader.raw() }
                if let query = request["query"] as? String { reader.query = query }
                var state: [String: Any] = ["available": reader.available, "shown": reader.shown,
                    "count": reader.document?.nodes.count ?? 0, "visible": reader.visible.count, "failure": reader.error ?? ""]
                if let id = request["node"] as? Int, let document = reader.document, document.nodes.indices.contains(id) {
                    state["value"] = document.value(id); state["path"] = document.path(id)
                }
                answer(state)
            } else {
                let storage = tab.siteStorage
                if action == "open" { storage.open(tab, spaceName: browser.spaces.first { $0.id == tab.space }?.name ?? "Space") }
                if action == "close" { storage.close() }
                if action == "refresh" { storage.refresh() }
                let cookie = request["cookie"] as? Bool ?? false
                let entries = cookie ? storage.cookies : storage.local
                let selected = entries.first { $0.id == request["entry"] as? String }
                if action == "save" {
                    guard request["entry"] == nil || selected != nil else { answer(["error": "entry not found"]); return }
                    storage.save(selected, key: request["key"] as? String ?? "", value: request["value"] as? String ?? "", cookie: cookie)
                }
                if action == "delete", let selected { storage.remove([selected], cookie: cookie) }
                answer(["shown": storage.shown, "busy": storage.busy, "failure": storage.error ?? "", "context": storage.context,
                    "cookies": storage.cookies.map { ["id": $0.id, "key": $0.key, "value": $0.value, "scope": $0.scope] },
                    "local": storage.local.map { ["id": $0.id, "key": $0.key, "value": $0.value, "scope": $0.scope] }])
            }

        case "site-data":
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            // `closed` closes the tab before the removal, as a page closing
            // itself behind the confirmation would.
            let closed = request["closed"] as? Bool == true
            let clear = closed || request["clear"] as? Bool == true
            guard !clear || Store.testing else { answer(["error": "site-data clear needs a test world"]); return }
            guard !closed || tab.bench else { answer(["error": "site-data closed needs a bench tab"]); return }
            Task { @MainActor in
                guard let scope = await SiteData.scope(for: tab) else {
                    answer(["error": "site-data needs an http or https page"])
                    return
                }
                let details: [String: Any] = [
                    "host": scope.host,
                    "domains": scope.names,
                    "records": scope.records.map { ["name": $0.displayName, "types": $0.dataTypes.sorted()] },
                ]
                if closed { browser.close(tab) }
                let removed = clear ? await SiteData.clear(scope, from: tab, in: browser) : false
                answer(details.merging(["cleared": removed, "page": tab.built != nil]) { a, _ in a })
            }

        case "close":
            if (request["id"] as? String) == "all" {
                let mine = browser.tabs.filter { $0.bench }
                mine.forEach { browser.close($0) }
                answer(["closed": mine.count])
                return
            }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            guard tab.bench else {
                answer(["error": "not a bench tab — only tabs the bench opened can be closed from here"])
                return
            }
            browser.close(tab)
            answer(["closed": 1])

        case "wait":
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            let limit = Date().addingTimeInterval(request["seconds"] as? Double ?? 20)
            wait(for: tab, until: limit, answer)

        case "sleep":
            // Now rather than after half an hour, but past every other check
            // a tab has to clear — the answer says which one kept it awake.
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            browser.sleep(tab) { said in answer(["said": said, "asleep": tab.asleep]) }

        case "idle":
            // The pass that puts idle tabs to sleep, now: as the timer runs it
            // (`seconds`, how long a tab has to have gone unlooked at), or as
            // a memory pressure warning or critical event runs it. Only on a
            // test run: a real browser's tabs are left to their own clock.
            guard Store.testing else { answer(["error": "idle only works on a --test run"]); return }
            switch request["level"] as? String {
            case "warning": browser.pressed(critical: false)
            case "critical": browser.pressed(critical: true)
            default: browser.sleepIdle(within: request["seconds"] as? Double ?? 0)
            }
            answer(["tabs": (browser.tabs + browser.parkedTabs).map(describe)])

        case "pin":
            guard Store.testing else { answer(["error": "pin only works on a --test run"]); return }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            if request["on"] as? Bool ?? true { browser.pin(tab) } else { browser.unpin(tab) }
            answer(describe(tab))

        case "caches":
            // What the icon cache and the pictures of sleeping tabs hold now.
            let all = browser.tabs + browser.parkedTabs
            let pictured = all.filter { $0.pictureBytes > 0 }
            answer(["icons": Favicons.shared.counts,
                    "pictures": browser.pictures.counts.merging([
                        "count": pictured.count, "bytes": pictured.reduce(0) { $0 + $1.pictureBytes },
                        "asleep": all.filter(\.asleep).count,
                    ]) { $1 }])

        case "select":
            // Picking a tab takes the window over, which the bench never does
            // to someone using it: only on an ESCALE_PROBE run.
            guard Store.testing else {
                answer(["error": "select only works on a --test run — it would take your window over"])
                return
            }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            browser.select(tab)
            // Once its page is in the window, when it has one: the stage puts
            // it there in SwiftUI's next update, and a click sent before that
            // finds a page with no window to be clicked in.
            Bench.within(2, until: { tab.built.map { $0.window != nil } ?? true }) { [weak self] in
                guard let self else { return }
                answer(describe(tab))
            }

        case "crash":
            // The page's process ended the way the system ends one under
            // memory pressure, for what the tab does next: only on a test
            // run, and only the process WebKit names for this tab's view.
            guard Store.testing else {
                answer(["error": "crash only works on a --test run"])
                return
            }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            guard let view = tab.built else { answer(["error": "no page to crash — the tab has no view"]); return }
            let named = NSSelectorFromString("_webProcessIdentifier")
            guard view.responds(to: named) else { answer(["error": "this WebKit doesn't say which process is the page's"]); return }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Int32
            let pid = unsafeBitCast(view.method(for: named), to: Getter.self)(view, named)
            guard pid > 0, kill(pid, SIGKILL) == 0 else { answer(["error": "no process to end (\(pid))"]); return }
            answer(["crashed": Int(pid)])

        case "text":
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            house(tab)
            tab.web.evaluateJavaScript("document.body ? document.body.innerText : ''") { value, error in
                MainActor.assumeIsolated {
                    if let error { answer(["error": error.localizedDescription]); return }
                    var text = (value as? String) ?? ""
                    var cut = false
                    if text.count > 120_000 { text = String(text.prefix(120_000)); cut = true }
                    answer(["text": text, "truncated": cut, "url": tab.address?.absoluteString ?? "", "title": tab.title])
                }
            }

        case "eval":
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            guard let js = request["js"] as? String else { answer(["error": "eval needs js"]); return }
            house(tab)
            tab.web.evaluateJavaScript(js) { value, error in
                MainActor.assumeIsolated {
                    if let error { answer(["error": error.localizedDescription]); return }
                    answer(["value": Bench.plain(value)])
                }
            }

        case "tap":
            // A real click on an element, delivered to the view as mouse
            // events — trusted, as a hand's is — where `click` only runs
            // element.click() in the page, which a password manager, for one,
            // is right to ignore. `text=Sign in` picks a button or link by its
            // words. Only on an ESCALE_PROBE run.
            guard Store.testing else { answer(["error": "tap only works on a --test run — it would click in your page"]); return }
            guard let tab = find(request, in: browser), let selector = request["selector"] as? String else { answer(missing(request)); return }
            house(tab)
            let view = tab.web
            // A page just put on screen may not be in its window yet.
            Bench.within(2, until: { view.window != nil }) {
                view.evaluateJavaScript(Bench.locate(selector)) { value, error in
                    MainActor.assumeIsolated {
                        guard let point = value as? [Double], point.count == 2, let window = view.window else {
                            answer(["error": error?.localizedDescription ?? "nothing matches \(selector)"])
                            return
                        }
                        // DOM rectangles are CSS pixels; page zoom changes their
                        // position in AppKit points, including Escale's default zoom.
                        let x = point[0] * view.pageZoom, y = point[1] * view.pageZoom
                        let local = NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y)
                        let spot = view.convert(local, to: nil)
                        let mods = request["mods"] as? [String] ?? []
                        var flags: NSEvent.ModifierFlags = []
                        if mods.contains("cmd") { flags.insert(.command) }
                        if mods.contains("shift") { flags.insert(.shift) }
                        let middle = mods.contains("middle")
                        let down: NSEvent.EventType = middle ? .otherMouseDown : .leftMouseDown
                        let up: NSEvent.EventType = middle ? .otherMouseUp : .leftMouseUp
                        // A double-click selects the word under it, as a hand's does.
                        let presses: [(NSEvent.EventType, Int)] = mods.contains("double")
                            ? [(down, 1), (up, 1), (down, 2), (up, 2)] : [(down, 1), (up, 1)]
                        for (type, clicks) in presses {
                            guard let event = NSEvent.mouseEvent(
                                with: type, location: spot, modifierFlags: flags,
                                timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: window.windowNumber, context: nil,
                                eventNumber: 0, clickCount: clicks, pressure: type == down ? 1 : 0
                            ) else { continue }
                            if middle {
                                if type == down { view.otherMouseDown(with: event) } else { view.otherMouseUp(with: event) }
                            } else {
                                if type == down { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
                            }
                        }
                        answer(["ok": true, "at": point.map { Int($0) }])
                    }
                }
            }

        case "click", "type", "submit":
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            guard let selector = request["selector"] as? String else {
                answer(["error": "\(verb) needs a selector"])
                return
            }
            house(tab)
            let text = request["text"] as? String ?? ""
            tab.web.evaluateJavaScript(Bench.act(verb, selector: selector, text: text)) { value, error in
                MainActor.assumeIsolated {
                    if let error { answer(["error": error.localizedDescription]); return }
                    let said = (value as? String) ?? "?"
                    answer(said == "ok" ? ["ok": true] : ["error": said])
                }
            }

        case "shot":
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            house(tab)
            let path = (request["path"] as? String)
                ?? NSTemporaryDirectory() + "escale-bench-\(Bench.short(tab)).png"
            let width = request["width"] as? Double
            shoot(tab, to: URL(fileURLWithPath: path), width: width, answer)

        case "probe":
            // The state of the window itself, for the bug that is not in a
            // page: which panels are up, whether something modal has the
            // app, and every window the app owns.
            var out: [String: Any] = [
                "settings": browser.tuning,
                "fasterShortcuts": browser.prefs.fasterShortcuts,
                "selectionFromKeyboard": browser.selectionFromKeyboard,
                "autoScroll": browser.prefs.autoScroll,
                "showsLinks": browser.prefs.showsLinks,
                "linkDestination": browser.linkStatus.destination ?? "",
                "selectionMenu": browser.prefs.selectionMenu,
                "selectionTranslating": browser.selectionMenu.translating?.count ?? -1,
                "welcome": browser.welcoming,
                "passwords": browser.managing,
                "history": browser.recalling,
                "downloads": browser.hoarding,
                "keptDownloads": browser.loot.kept.map(\.name),
                "handedDownloads": Loot.handed,
                "bookmarks": browser.bookmarking,
                "field": browser.editing,
                "suggesting": browser.logins.suggesting != nil,
                "offering": browser.logins.offering != nil,
                "activeDownloads": browser.downloads.count,
                "downloadDoorVisible": browser.downloads.hasStarted,
                "downloadObservers": browser.downloads.observationCount,
                "downloadFraction": browser.downloads.fraction as Any? ?? NSNull(),
                "transfers": browser.downloads.transfers.map { transfer -> [String: Any] in
                    ["name": transfer.name, "space": transfer.space.uuidString,
                     "fraction": transfer.fraction as Any? ?? NSNull()]
                },
                "modal": NSApp.modalWindow.map { "\(type(of: $0)) “\($0.title)”" } ?? "",
                "look": browser.prefs.look.rawValue,
                "tone": browser.prefs.tone.rawValue,
                "interfaceSize": browser.prefs.interfaceSize.rawValue,
                "depth": browser.prefs.depth.rawValue,
                "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                "increaseContrast": NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
                "increasesContrast": browser.prefs.increasesContrast,
                "appearance": NSApp.appearance?.name.rawValue ?? "system",
                "key": NSApp.keyWindow.map { "\(type(of: $0)) “\($0.title)”" } ?? "",
                // Whether the app has the keyboard: scenarios run behind
                // others don't, and a failure says which one it was.
                "appActive": NSApp.isActive,
            ]
            out["windows"] = NSApp.windows.map { window -> [String: Any] in
                [
                    "kind": "\(type(of: window))",
                    "title": window.title,
                    "visible": window.isVisible,
                    "level": window.level.rawValue,
                    "frame": [Int(window.frame.minX), Int(window.frame.minY), Int(window.frame.width), Int(window.frame.height)],
                    "number": window.windowNumber,
                    "opaque": window.isOpaque,
                    // Covered entirely: WebKit then holds back timers and frames.
                    "occluded": !window.occlusionState.contains(.visible),
                ]
            }
            if let window = Links.window {
                out["lights"] = Bench.lights(of: window)
                if let web = browser.active?.built, web.window === window {
                    let rect = web.convert(web.bounds, to: nil)
                    out["pageFrame"] = [rect.minX, window.frame.height - rect.maxY, rect.width, rect.height]
                    // The menu over selected text, where it stands in the window (see SelectionMenu.swift).
                    if let shown = browser.selectionMenu.shown, shown.tab == browser.active?.id {
                        let at = shown.origin
                        out["selection"] = [rect.minX + at.x, window.frame.height - rect.maxY + at.y,
                                            SelectionMenu.size.width, SelectionMenu.size.height]
                    }
                }
            }
            if Store.measuring,
               let field = Bench.addressField(in: Links.window?.contentView) as? AddressField.Box,
               let firstFocusedAt = field.firstFocusedAt {
                out["fieldUsableAt"] = firstFocusedAt
            }
            out["keysQuieted"] = PageView.quieted
            // View › Web Inspector, as each page's WebKit has it.
            let asked = NSSelectorFromString("_developerExtrasEnabled")
            out["inspector"] = browser.tabs.compactMap { tab -> Bool? in
                guard let preferences = tab.built?.configuration.preferences, preferences.responds(to: asked) else { return nil }
                return preferences.value(forKey: "developerExtrasEnabled") as? Bool
            }
            // The column folded away, out for a look, and the lights with it (see Fold.swift).
            out["folded"] = browser.folded
            out["peeking"] = browser.peeking
            out["sideHides"] = browser.prefs.sideHides
            // The bar over the page, and what it says (see Bar.swift).
            out["bar"] = browser.showsBar
            if browser.showsBar, let url = browser.active?.address { out["barSite"] = AddressBar.site(url) }
            out["lightsHidden"] = Fold.titlebar?.isHidden ?? false
            // The address field as its owner holds it, and whether the
            // keyboard is actually in it (see Field.swift).
            out["fieldShowing"] = browser.fieldShowing
            out["github"] = GitHubBench.state(browser)
            out["openingTab"] = browser.field.opening != nil
            out["searchPrivate"] = browser.searchIsPrivate
            out["typed"] = browser.field.typed
            out["offers"] = browser.field.offers.map(\.key)
            out["picked"] = browser.field.picked ?? -1
            out["environmentFocused"] = browser.field.environmentFocused
            out["environment"] = browser.field.selectedEnvironment?.name ?? ""
            out["offerDetails"] = browser.field.offers.map {
                ["id": $0.id, "kind": String(describing: $0.kind), "url": $0.url.absoluteString,
                 "environments": $0.environments.map(\.name),
                 "bookmark": $0.bookmark?.uuidString ?? "",
                 "activeEnvironment": $0.activeEnvironment?.name ?? ""] as [String: Any]
            }
            out["summoning"] = browser.field.summoning
            out["foreignKeys"] = BenchKeys.ignored
            out["refusals"] = browser.field.refusals
            let box = Bench.addressField(in: Links.window?.contentView)
            out["fieldFocused"] = box?.currentEditor().map { $0 === box?.window?.firstResponder } ?? false
            // The find bar, and what its owner holds (see Find.swift).
            out["finding"] = browser.finding
            out["needle"] = browser.find.needle
            out["missed"] = browser.find.missed
            // Whether this Mac lets the browser use its passkeys at all — the
            // one-time permission macOS asks a browser other than Safari for.
            switch ASAuthorizationWebBrowserPublicKeyCredentialManager().authorizationStateForPlatformCredentials {
            case .authorized: out["passkeyAccess"] = "authorized"
            case .denied: out["passkeyAccess"] = "denied"
            default: out["passkeyAccess"] = "notDetermined"
            }
            out["passkeyAsks"] = Passkeys.asked
            out["passkeyLast"] = Passkeys.last
            answer(out)

        case "press":
            // A key pressed on the app as a whole, through its event queue —
            // so its own shortcuts see it first, as they do a real press;
            // `key` goes straight to a page instead. Only on an ESCALE_PROBE run.
            guard Store.testing else { answer(["error": "press only works on a --test run — it would press keys in your browser"]); return }
            guard let code = request["code"] as? Int, let chars = request["chars"] as? String
            else { answer(["error": "press needs a key code and the characters it types"]); return }
            // The modifiers held around it, each with the key code a hand
            // sends as it goes down and comes back up.
            var held: [(flag: NSEvent.ModifierFlags, code: UInt16)] = []
            for name in request["mods"] as? [String] ?? [] {
                switch name {
                case "cmd": held.append((.command, 55))
                case "shift": held.append((.shift, 56))
                case "ctrl": held.append((.control, 59))
                case "opt": held.append((.option, 58))
                default: break
                }
            }
            let flags = held.reduce(into: NSEvent.ModifierFlags()) { $0.insert($1.flag) }
            // "repeat": the press a key held down sends again and again.
            let repeats = (request["mods"] as? [String] ?? []).contains("repeat")
            // "outside": made as the keyboard makes it, by no process (BenchKeys.swift).
            let outside = (request["mods"] as? [String] ?? []).contains("outside")
            func post(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags, _ chars: String, _ code: UInt16) {
                guard let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: NSApp.keyWindow?.windowNumber ?? Links.window?.windowNumber ?? 0, context: nil,
                    characters: chars, charactersIgnoringModifiers: chars,
                    isARepeat: repeats && type == .keyDown, keyCode: code
                ) else { return }
                guard outside else { NSApp.postEvent(event, atStart: false); return }
                guard let made = event.cgEvent else { return }
                made.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
                if let foreign = NSEvent(cgEvent: made) { NSApp.postEvent(foreign, atStart: false) }
            }
            // The modifiers go down before the key and come back up after
            // it, as on a keyboard. Without the release, the last event the
            // app had seen still held ⌘, and what reads it later took the
            // next bookmark picked for a ⌘-click (Browser.visit): after ⌘T or
            // ⌘W it opened a tab of its own instead of going where it was
            // asked. A ⌘K walk lands on the release, as it does
            // for a hand.
            var down: NSEvent.ModifierFlags = []
            for key in held {
                down.insert(key.flag)
                post(.flagsChanged, down, "", key.code)
            }
            post(.keyDown, flags, chars, UInt16(code))
            post(.keyUp, flags, chars, UInt16(code))
            for key in held.reversed() {
                down.remove(key.flag)
                post(.flagsChanged, down, "", key.code)
            }
            // The answer once the press has been through the app and the
            // run loop has rested twice: what it changed, SwiftUI's update
            // and the work it queued for the next turn included. A fixed
            // 0.4 s used to stand for that, and was most of a keyboard
            // scenario's time. A burst can still ask for an acknowledgement
            // after a set time, to sample layout between presses.
            let reply = { answer(["active": browser.active.map { String($0.id.uuidString.prefix(8)).lowercased() } ?? ""]) }
            if let settle = request["settle"] as? Double {
                DispatchQueue.main.asyncAfter(deadline: .now() + min(0.4, max(0, settle))) { reply() }
            } else {
                Bench.afterQueue { Bench.afterRests(2) { reply() } }
            }

        case "key":
            // Keys pressed on a tab, as real key events handed to its view —
            // for what the page does with them, and what comes back unused.
            // Only on an ESCALE_PROBE run: it types into a page.
            guard Store.testing else { answer(["error": "key only works on a --test run — it would type into your page"]); return }
            guard let tab = find(request, in: browser), let text = request["text"] as? String else { answer(missing(request)); return }
            house(tab)
            let view = tab.web
            view.window?.makeFirstResponder(view)
            let before = PageView.quieted
            // What WebKit sends back through the app because the page didn't
            // use it: a key press seen here again after it was handed over.
            var pressed: [NSEvent] = []
            var resent = 0
            let watch = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if pressed.contains(where: { PageView.same($0, event) }) { resent += 1 }
                return event
            }
            for character in text {
                let chars = String(character)
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    guard let event = NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: view.window?.windowNumber ?? 0, context: nil,
                        characters: chars, charactersIgnoringModifiers: chars,
                        isARepeat: false, keyCode: Bench.keyCode(for: character)
                    ) else { continue }
                    if type == .keyDown { pressed.append(event); view.keyDown(with: event) } else { view.keyUp(with: event) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let watch { NSEvent.removeMonitor(watch) }
                answer(["typed": text, "sentBackUnused": resent, "quieted": PageView.quieted - before])
            }

        case "resize":
            // The window taken to another size in steps, a frame apart, the
            // way a hand drags its corner — for what that does to the title
            // bar. It moves the window, so only on an ESCALE_PROBE run.
            guard Store.testing else {
                answer(["error": "resize only works on a --test run — it would move your window"])
                return
            }
            guard let window = Links.window,
                  let width = request["width"] as? Double, let height = request["height"] as? Double
            else { answer(["error": "resize needs a width and a height"]); return }
            let steps = max(1, request["steps"] as? Int ?? 12)
            let from = window.frame
            func step(_ n: Int) {
                let t = CGFloat(n) / CGFloat(steps)
                var frame = from
                frame.size.width = from.width + (CGFloat(width) - from.width) * t
                frame.size.height = from.height + (CGFloat(height) - from.height) * t
                frame.origin.y = from.maxY - frame.height
                window.setFrame(frame, display: true)
                if n < steps {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { step(n + 1) }
                } else {
                    Bench.afterRests(2) {
                        answer(["size": [Int(window.frame.width), Int(window.frame.height)], "lights": Bench.lights(of: window)])
                    }
                }
            }
            step(1)

        case "hit":
            // What a press at a point of the window lands on, and whether
            // AppKit would carry the window off on a drag from there — the
            // question behind a tab that moved the window instead of itself.
            // Only looked at, unless asked for a double-click.
            guard let window = Links.window, let x = request["x"] as? Double, let y = request["y"] as? Double,
                  let frame = window.contentView?.superview
            else { answer(["error": "hit needs an x and a y"]); return }
            let point = NSPoint(x: x, y: Double(window.frame.height) - y)
            let hit = frame.hitTest(frame.convert(point, from: nil))
            if request["middle"] as? Bool == true {
                // The middle button pressed and let go there. A probe's window
                // is hidden and takes no events through the app, so they are
                // handed to the view that catches the middle button over the
                // tabs (MiddleClick in TabBar.swift), the topmost one there.
                guard Store.testing else { answer(["error": "hit … middle only works on a --test run"]); return }
                func catcher(in view: NSView) -> NSView? {
                    for sub in view.subviews.reversed() { if let found = catcher(in: sub) { return found } }
                    guard String(describing: type(of: view)).contains("Catch") else { return nil }
                    return view.convert(view.bounds, to: nil).contains(point) ? view : nil
                }
                guard let target = catcher(in: frame) else { answer(["error": "nothing catches the middle button there"]); return }
                let before = browser.tabs.count
                for type in [NSEvent.EventType.otherMouseDown, .otherMouseUp] {
                    guard let event = NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                        pressure: type == .otherMouseUp ? 0 : 1
                    ) else { continue }
                    if type == .otherMouseDown { target.otherMouseDown(with: event) } else { target.otherMouseUp(with: event) }
                }
                Bench.afterRests(2) {
                    answer(["tabsBefore": before, "tabsAfter": browser.tabs.count])
                }
                return
            }
            let double = request["double"] as? Bool == true
            // A single click, for a door in the bar over the page (see Bar.swift).
            if double || request["click"] as? Bool == true || request["command"] as? Bool == true {
                // A double-click there, handed to the view under it — through
                // the window it would never arrive, the probe being in the
                // back. On a test run only, and meant for a probe started
                // hidden, where the window changing size shows on no screen.
                guard Store.testing else { answer(["error": "hit … double|click only works on a --test run"]); return }
                let before = window.frame
                let modifiers: NSEvent.ModifierFlags = request["command"] as? Bool == true ? [.command] : []
                func event(_ type: NSEvent.EventType, _ clicks: Int) -> NSEvent? {
                    NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                                       pressure: type == .leftMouseUp ? 0 : 1)
                }
                let live = request["live"] as? Bool == true
                if live {
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
                for clicks in double ? [1, 2] : [1] {
                    if let down = event(.leftMouseDown, clicks) {
                        if request["command"] as? Bool == true { NSApp.postEvent(down, atStart: false) }
                        else if live { NSApp.sendEvent(down) } else { hit?.mouseDown(with: down) }
                    }
                    if let up = event(.leftMouseUp, clicks) {
                        if request["command"] as? Bool == true { NSApp.postEvent(up, atStart: false) }
                        else if live { NSApp.sendEvent(up) } else { hit?.mouseUp(with: up) }
                    }
                }
                let reply = {
                    let after = window.frame
                    answer(["view": hit.map { String("\(type(of: $0))".prefix(60)) } ?? "",
                            "before": [Int(before.width), Int(before.height)], "after": [Int(after.width), Int(after.height)],
                            "zoomed": window.isZoomed])
                }
                // A double-click may zoom the window, which animates: it
                // keeps its time. A click is answered once it has been
                // through the app and the run loop has rested.
                if double {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { reply() }
                } else {
                    Bench.afterQueue { Bench.afterRests(2) { reply() } }
                }
                return
            }
            answer([
                "view": hit.map { String("\(type(of: $0))".prefix(60)) } ?? "",
                "canMoveWindow": hit?.mouseDownCanMoveWindow ?? false,
                "windowMovable": window.isMovable,
                "titleBar": y <= Double(window.frame.height - window.contentLayoutRect.height),
            ])

        case "pointer":
            BenchPointer.perform(request, answer: answer)

        case "drag":
            // A press at one point of the window, carried to another in small
            // steps and let go there — what a hand does to a row it picks up.
            // `live` delivers every event through AppKit, press included, so a
            // Space switch can replace the view that began the gesture and
            // SwiftUI's gestures see what a hand would send. Events handed to
            // the hit view directly never began one on macOS 26.5.1.
            guard Store.testing else { answer(["error": "drag only works on a --test run"]); return }
            guard let window = Links.window, let frame = window.contentView?.superview,
                  let x = request["x"] as? Double, let y = request["y"] as? Double,
                  let toX = request["toX"] as? Double, let toY = request["toY"] as? Double
            else { answer(["error": "drag needs two points"]); return }
            let hold = min(max(request["holdMS"] as? Int ?? 0, 0), 3_000)
            let dropPause = min(max(request["dropPauseMS"] as? Int ?? 0, 0), 3_000)
            let live = request["live"] as? Bool ?? false
            func point(_ x: Double, _ y: Double) -> NSPoint { NSPoint(x: x, y: Double(window.frame.height) - y) }
            let end = point(request["endX"] as? Double ?? toX, request["endY"] as? Double ?? toY)
            func event(_ type: NSEvent.EventType, _ at: NSPoint) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                   pressure: type == .leftMouseUp ? 0 : 1)
            }
            let start = point(x, y)
            guard let target = frame.hitTest(frame.convert(start, from: nil)) else { answer(["error": "nothing there"]); return }
            if live {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            var inputMS: [Double] = []
            func deliver(_ type: NSEvent.EventType, _ at: NSPoint, routed: Bool = false) {
                guard let event = event(type, at) else { return }
                let began = CACurrentMediaTime()
                if routed { NSApp.sendEvent(event) }
                else {
                    switch type {
                    case .leftMouseDown: target.mouseDown(with: event)
                    case .leftMouseDragged: target.mouseDragged(with: event)
                    case .leftMouseUp: target.mouseUp(with: event)
                    default: break
                    }
                }
                if type == .leftMouseDragged {
                    Bench.whenResting(since: began) { inputMS.append($0) }
                }
            }
            deliver(.leftMouseDown, start, routed: live)
            let steps = 16
            func step(_ n: Int) {
                let along = Double(n) / Double(steps)
                let at = point(x + (toX - x) * along, y + (toY - y) * along)
                if n < steps {
                    deliver(.leftMouseDragged, at, routed: live)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { step(n + 1) }
                } else {
                    // Moved onto the point, then let go there, as a hand does.
                    deliver(.leftMouseDragged, at, routed: live)
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(hold)) {
                        let heldSpace = browser.spaceID.uuidString
                        let heldPanels = PanelBench.state(browser)
                        if end != at { deliver(.leftMouseDragged, end, routed: live) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(dropPause)) {
                            deliver(.leftMouseUp, end, routed: live)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                answer(["view": String("\(type(of: target))".prefix(60)),
                                        "heldSpace": heldSpace,
                                        "heldPanels": heldPanels,
                                        "inputMS": inputMS,
                                        "releaseMonitor": SpaceDrag.releasedByMonitor])
                            }
                        }
                    }
                }
            }
            step(1)

        case "recall":
            // The History panel opened or closed, or its search changed, as
            // the menu and the panel's field do it, timed until the run loop
            // rests. Three rests in a row, so the list read on appear and any
            // pass it leaves for the next turn are counted too; the last one
            // is the panel settled. Only on an ESCALE_PROBE run.
            guard Store.testing else { answer(["error": "recall only works on a --test run"]); return }
            if let turns = request["scroll"] as? Int {
                // The list under X Y turned down by the wheel, 40 points a
                // turn, one turn of the run loop apart as a trackpad sends
                // them: lines further down brought into view. Not timed, the
                // scroll view draws on its own clock after the event.
                guard let window = Links.window, let frame = window.contentView?.superview,
                      let x = request["x"] as? Double, let y = request["y"] as? Double
                else { answer(["error": "recall scroll needs a point"]); return }
                let at = NSPoint(x: x, y: Double(window.frame.height) - y)
                guard let target = frame.hitTest(frame.convert(at, from: nil)) else { answer(["error": "nothing there"]); return }
                let screen = window.convertPoint(toScreen: at)
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                @MainActor func turn(_ left: Int) {
                    guard left > 0 else { answer(["turned": turns, "view": String("\(type(of: target))".prefix(60))]); return }
                    guard let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0)
                    else { answer(["error": "no wheel event"]); return }
                    wheel.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                    wheel.location = CGPoint(x: screen.x, y: top - screen.y)
                    guard let event = NSEvent(cgEvent: wheel) else { answer(["error": "no wheel event"]); return }
                    target.scrollWheel(with: event)
                    DispatchQueue.main.async { turn(left - 1) }
                }
                turn(turns)
                return
            }
            let start = CACurrentMediaTime()
            if let hunt = request["hunt"] as? String {
                browser.recallHunt = hunt
            } else {
                browser.recalling = request["open"] as? Bool ?? true
            }
            var rests: [Double] = []
            @MainActor func rest() {
                Bench.whenResting(since: start) { rested in
                    rests.append(rested)
                    guard rests.count == 3 else { DispatchQueue.main.async { rest() }; return }
                    answer(["ms": rests, "open": browser.recalling, "hunt": browser.recallHunt])
                }
            }
            rest()

        case "field":
            // Text put into the address field the way a paste puts it — the
            // whole of it replacing what is selected — or typed a character
            // at a time, each timed from the moment it goes in to the moment
            // the run loop next rests: the list worked out, SwiftUI's update
            // and Core Animation's commit included. Only on an ESCALE_PROBE run.
            guard Store.testing else { answer(["error": "field only works on a --test run — it would type into your browser"]); return }
            guard let text = request["text"] as? String, !text.isEmpty else { answer(["error": "field needs some text"]); return }
            let pieces = request["type"] as? Bool == true ? text.map(String.init) : [text]
            if browser.fieldShowing { browser.field.askFocus() } else { browser.edit() }
            Bench.addressEditor(for: browser.field, within: 2) { found in
                guard let (field, editor) = found
                else { answer(["error": "the address field has no editor"]); return }
                var times: [[Double]] = []
                @MainActor func next(_ index: Int) {
                    guard index < pieces.count else {
                        var out: [String: Any] = ["field": field.stringValue, "typed": browser.field.typed, "offers": browser.field.offers.map(\.key), "ms": times]
                        guard request["go"] as? Bool == true, let tab = browser.active else { answer(out); return }
                        // Then Return, as the field's own delegate takes it:
                        // how long until WebKit is loading the page.
                        out["viewWasBuilt"] = tab.built != nil
                        let start = CACurrentMediaTime()
                        var loading: Double?
                        let watch = tab.$loading.first(where: { $0 }).sink { _ in loading = (CACurrentMediaTime() - start) * 1000 }
                        browser.submit()
                        out["returned"] = (CACurrentMediaTime() - start) * 1000
                        Bench.whenResting(since: start) { rested in
                            out["rested"] = rested
                            Bench.within(1, until: { loading != nil }) {
                                watch.cancel()
                                out["loading"] = loading ?? -1
                                answer(out)
                            }
                        }
                        return
                    }
                    let start = CACurrentMediaTime()
                    editor.insertText(pieces[index], replacementRange: NSRange(location: NSNotFound, length: 0))
                    let inserted = (CACurrentMediaTime() - start) * 1000
                    Bench.whenResting(since: start) { rested in
                        times.append([inserted, rested])
                        DispatchQueue.main.async { next(index + 1) }
                    }
                }
                next(0)
            }

        case "row":
            // A row of Bearings taken as a click on it takes it: its own
            // action (Omnibox.Row), not a pointer event, which the bench's
            // hidden window does not route to SwiftUI's gestures.
            guard Store.testing else { answer(["error": "row only works on a --test run — it would go somewhere in your window"]); return }
            guard let index = request["index"] as? Int, browser.field.offers.indices.contains(index)
            else { answer(["error": "no row at that index"]); return }
            let offer = browser.field.offers[index]
            browser.take(offer)
            answer(["taken": offer.url.absoluteString, "kind": String(describing: offer.kind)])

        case "bookmark":
            // A bookmark picked from the button's list, through the same
            // call the list makes: how long until WebKit is loading it, and
            // until the run loop rests. Only on an ESCALE_PROBE run.
            guard Store.testing else { answer(["error": "bookmark only works on a --test run — it would load a page in your tab"]); return }
            guard let url = (request["url"] as? String).flatMap(Address.url(from:)) else { answer(["error": "bookmark needs a url"]); return }
            // "new": into a new tab, whose page has yet to be built.
            if request["new"] as? Bool == true { browser.newTab() }
            guard let tab = browser.active else { answer(["error": "no tab to open it in"]); return }
            browser.bookmarksOpen = true
            let built = tab.built != nil
            var loading: Double?
            let start = CACurrentMediaTime()
            let watch = tab.$loading.first(where: { $0 }).sink { _ in loading = (CACurrentMediaTime() - start) * 1000 }
            browser.pickBookmark(url)
            let returned = (CACurrentMediaTime() - start) * 1000
            Bench.whenResting(since: start) { rested in
                Bench.within(1, until: { loading != nil }) {
                    watch.cancel()
                    answer(["returned": returned, "loading": loading ?? -1, "rested": rested,
                            "viewWasBuilt": built, "listStillOpen": browser.bookmarksOpen, "sameTab": browser.active?.id == tab.id])
                }
            }

        case "menu":
            // The Bookmarks menu as it is about to open: the menu bar
            // told it is being tracked, SwiftUI's own update run on it, its
            // first folder opened — then what each holds. Only on a
            // ESCALE_PROBE run; nothing is drawn.
            guard Store.testing else { answer(["error": "menu only works on a --test run"]); return }
            guard let main = NSApp.mainMenu, let menu = main.items.first(where: { $0.title == "Bookmarks" })?.submenu
            else { answer(["error": "no Bookmarks menu"]); return }
            let before = menu.items.count
            let wrapped = menu.delegate.map { "\(type(of: $0))" } ?? "none"
            let start = CACurrentMediaTime()
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: main)
            let filled = (CACurrentMediaTime() - start) * 1000
            menu.delegate?.menuNeedsUpdate?(menu)
            let folder = menu.items.first { $0.submenu != nil && $0.tag != 0 }?.submenu
            if let folder { folder.delegate?.menuNeedsUpdate?(folder) }
            // "open": the first bookmark in that folder picked, as a click would.
            if request["open"] as? Bool == true, let folder,
               let index = folder.items.firstIndex(where: { $0.representedObject is URL }) {
                folder.performActionForItem(at: index)
            }
            answer(["delegate": wrapped, "before": before, "after": menu.items.count, "ours": BookmarkMenu.shared.count, "fillMs": filled,
                    "titles": menu.items.prefix(8).map { $0.isSeparatorItem ? "—" : $0.title },
                    "firstFolder": folder?.items.prefix(4).map(\.title) ?? [],
                    "active": browser.active?.address?.absoluteString ?? ""])

        case "place":
            // A tab put at another place in the row, as a drag would.
            guard let id = request["id"] as? String, let to = request["to"] as? Int,
                  let tab = browser.tabs.first(where: { Bench.short($0) == id })
            else { answer(["error": "place needs a tab id and an index"]); return }
            browser.move(tab, to: to)
            answer(["at": browser.tabs.firstIndex { $0.id == tab.id } ?? -1])

        case "window":
            // The browser's window, when a probe started hidden came up
            // without one: the Window menu's own item for it.
            guard Store.testing else { answer(["error": "window only works on a --test run"]); return }
            if Links.window?.contentView != nil, NSApp.windows.contains(where: { $0 === Links.window }) {
                answer(["window": "there"])
                return
            }
            let items = NSApp.mainMenu?.items.first { $0.submenu?.title == "Window" }?.submenu?.items ?? []
            guard let item = items.first(where: { $0.title == "Escale" }), let action = item.action else {
                answer(["error": "no Escale item in the Window menu", "items": items.map(\.title)])
                return
            }
            NSApp.sendAction(action, to: item.target, from: item)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                answer(["window": NSApp.windows.map { "\(type(of: $0))" }, "hidden": NSApp.isHidden])
            }

        case "pages":
            // Pages that WebKit will paint, for `picture`, from a probe started
            // hidden: the app shown again without coming forward, but only
            // once its windows are all off the screen — the browser's own put
            // away, the bench's room far off every screen. Anything of the
            // app's that would show on a screen and the app is hidden again.
            guard Store.testing, let window = Links.window else { answer(["error": "pages only works on a --test run"]); return }
            func onScreen(_ w: NSWindow) -> Bool { NSScreen.screens.contains { $0.frame.intersects(w.frame) } }
            if request["on"] as? Bool == true {
                _ = room ?? makeRoom()
                window.orderOut(nil)
                for other in NSApp.windows where other !== room && onScreen(other) { other.orderOut(nil) }
                NSApp.unhideWithoutActivation()
                let showing = NSApp.windows.filter { $0.isVisible && onScreen($0) }
                if !showing.isEmpty {
                    NSApp.hide(nil)
                    answer(["error": "a window would have shown: \(showing.map { "\(type(of: $0))" })"])
                    return
                }
                answer(["pages": true])
            } else {
                NSApp.hide(nil)
                window.orderFront(nil)
                answer(["pages": false])
            }

        case "picture":
            // The whole window as a picture — the app's own drawing, with each
            // page on screen put in as WebKit pictures it — from a probe
            // started hidden, so nothing shows on anybody's screen. For the
            // images on the site.
            guard Store.testing else { answer(["error": "picture only works on a --test run"]); return }
            guard let window = (request["sheet"] as? Bool == true ? Links.window?.attachedSheet : Links.window),
                  let frame = window.contentView?.superview,
                  let path = request["path"] as? String, !path.isEmpty
            else { answer(["error": "picture needs a path"]); return }
            func pages(in view: NSView) -> [WKWebView] {
                if let web = view as? WKWebView { return [web] }
                return view.subviews.flatMap(pages)
            }
            // The page, when WebKit paints (see `pages`): the tab's address
            // loaded afresh in a view of its own in the bench's room, sized
            // as the page is, and pictured there.
            if !NSApp.isHidden, request["page"] as? Bool != false, let tab = browser.active, let address = tab.address,
               let live = tab.built, live.window === window {
                let rect = live.convert(live.bounds, to: nil)
                guard let chrome = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { answer(["error": "nothing drawn"]); return }
                frame.cacheDisplay(in: frame.bounds, to: chrome)
                let stand = room ?? makeRoom()
                // The tab's own page by default — as it is, reader view or
                // things hidden included — lent to the room for the picture
                // and handed back; or, with `fresh`, the address loaded anew.
                let fresh = request["fresh"] as? Bool == true
                let home = live.superview
                let homeFrame = live.frame
                let page = fresh ? WKWebView(frame: NSRect(origin: .zero, size: rect.size), configuration: Web.configuration()) : live
                if !fresh {
                    live.removeFromSuperview()
                    live.frame = NSRect(origin: .zero, size: rect.size)
                    live.alphaValue = 1
                }
                func giveBack() {
                    guard !fresh else { page.removeFromSuperview(); return }
                    live.removeFromSuperview()
                    live.frame = homeFrame
                    home?.addSubview(live)
                }
                // A window off every screen counts as covered, and WebKit
                // paints nothing it thinks nobody sees; this one is told to
                // paint regardless.
                let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
                if page.responds(to: occlusion) {
                    typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
                    unsafeBitCast(page.method(for: occlusion), to: Setter.self)(page, occlusion, false)
                }
                stand.contentView?.addSubview(page)
                if fresh { page.load(URLRequest(url: address)) }
                let settle = request["settle"] as? Double ?? 3
                func whenLoaded(_ tries: Int) {
                    guard page.isLoading, tries > 0 else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                            page.takeSnapshot(with: nil) { image, _ in
                                MainActor.assumeIsolated {
                                    giveBack()
                                    let drawn = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: chrome.pixelsWide, pixelsHigh: chrome.pixelsHigh,
                                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                                    guard let drawn else { answer(["error": "nothing drawn"]); return }
                                    drawn.size = frame.bounds.size
                                    NSGraphicsContext.saveGraphicsState()
                                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: drawn)
                                    chrome.draw(in: frame.bounds)
                                    image?.draw(in: rect)
                                    NSGraphicsContext.restoreGraphicsState()
                                    do {
                                        try drawn.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                                        answer(["saved": path, "pixels": [drawn.pixelsWide, drawn.pixelsHigh], "page": [Int(rect.minX), Int(frame.bounds.height - rect.maxY), Int(rect.width), Int(rect.height)],
                                                "points": [Int(frame.bounds.width), Int(frame.bounds.height)], "lights": Bench.lights(of: window)])
                                    } catch { answer(["error": error.localizedDescription]) }
                                }
                            }
                        }
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { whenLoaded(tries - 1) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { whenLoaded(80) }
                return
            }
            let shown = pages(in: frame).filter { !$0.isHidden && $0.alphaValue > 0 && !$0.frame.isEmpty }
            var taken: [(WKWebView, NSImage)] = []
            var left = shown.count
            func draw() {
                // Each page's picture where the page is, the page itself put
                // aside for the one drawing.
                var covers: [NSImageView] = []
                for (web, image) in taken {
                    let cover = NSImageView(frame: web.frame)
                    cover.image = image
                    cover.imageScaling = .scaleAxesIndependently
                    cover.autoresizingMask = web.autoresizingMask
                    web.superview?.addSubview(cover, positioned: .above, relativeTo: web)
                    web.isHidden = true
                    covers.append(cover)
                }
                frame.layoutSubtreeIfNeeded()
                defer {
                    covers.forEach { $0.removeFromSuperview() }
                    taken.forEach { $0.0.isHidden = false }
                }
                guard let picture = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else {
                    answer(["error": "nothing drawn"])
                    return
                }
                frame.cacheDisplay(in: frame.bounds, to: picture)
                do {
                    try picture.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    answer(["saved": path, "pixels": [picture.pixelsWide, picture.pixelsHigh],
                            "points": [Int(frame.bounds.width), Int(frame.bounds.height)], "lights": Bench.lights(of: window)])
                } catch { answer(["error": error.localizedDescription]) }
            }
            guard left > 0 else { draw(); return }
            for web in shown {
                web.takeSnapshot(with: nil) { image, _ in
                    MainActor.assumeIsolated {
                        if let image { taken.append((web, image)) }
                        left -= 1
                        if left == 0 { draw() }
                    }
                }
            }

        case "film":
            // The whole window, title bar and lights included, drawn every few
            // hundredths of a second while something animates — what a person
            // would see of it, from a probe started hidden that nobody sees.
            // The lights' own slide is a Core Animation one, which a drawing
            // doesn't show: where they are is reported beside each frame.
            guard Store.testing else { answer(["error": "film only works on a --test run"]); return }
            guard let window = Links.window, let frame = window.contentView?.superview,
                  let path = request["path"] as? String, !path.isEmpty
            else { answer(["error": "film needs something to do and a path"]); return }
            let count = min(60, max(1, request["frames"] as? Int ?? 14))
            let every = min(0.5, max(0.01, request["every"] as? Double ?? 0.03))
            // The column's corner — the lights, the pins, the first rows — is
            // what moves; the whole window would take longer to draw than a
            // frame lasts. Written out once the filming is over.
            let corner = NSRect(x: 0, y: frame.bounds.height - 460, width: min(380, frame.bounds.width), height: 460)
            // The pages under it take a third of a second each to draw into a
            // picture, longer than the whole animation: they sit the filming
            // out, and come back after.
            func pages(in view: NSView) -> [NSView] { view is WKWebView ? [view] : view.subviews.flatMap(pages) }
            let resting = pages(in: frame).filter { !$0.isHidden }
            resting.forEach { $0.isHidden = true }
            var shots: [[String: Any]] = []
            var pictures: [NSBitmapImageRep] = []
            let started = CACurrentMediaTime()
            func take(_ index: Int) {
                guard index < count else {
                    resting.forEach { $0.isHidden = false }
                    for (index, picture) in pictures.enumerated() {
                        let file = path + String(format: "-%02d.png", index)
                        if let data = picture.representation(using: .png, properties: [:]),
                           (try? data.write(to: URL(fileURLWithPath: file))) != nil { shots[index]["file"] = file }
                    }
                    answer(["frames": shots])
                    return
                }
                var shot: [String: Any] = ["t": Int((CACurrentMediaTime() - started) * 1000)]
                if let picture = frame.bitmapImageRepForCachingDisplay(in: corner) {
                    frame.cacheDisplay(in: corner, to: picture)
                    pictures.append(picture)
                }
                if let bar = Fold.titlebar {
                    let moved = bar.layer?.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0
                    let lifted = bar.layer?.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat ?? 0
                    shot["lights"] = ["hidden": bar.isHidden, "x": Int(moved.rounded()), "y": Int(lifted.rounded()),
                                      "flipped": bar.superview?.isFlipped ?? false]
                }
                shots.append(shot)
                DispatchQueue.main.asyncAfter(deadline: .now() + every) { take(index + 1) }
            }
            take(0)
            switch request["action"] as? String {
            case "peek": browser.peek(true)
            case "unpeek": browser.peek(false)
            case "fold": browser.toggleFold()
            default: break
            }

        case "strip":
            // The row of tabs across the top, drawn off screen at a width,
            // with what the browser has now — for what the row looks like
            // without a window on anybody's screen.
            guard let path = request["path"] as? String else { answer(["error": "strip needs a path"]); return }
            let width = request["width"] as? Double ?? 1100
            let host = NSHostingView(rootView: TabBar(browser: browser).frame(width: width, height: Metrics.strip).background(Palette.ground))
            host.frame = NSRect(x: 0, y: 0, width: width, height: Double(Metrics.strip))
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSApp.effectiveAppearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { answer(["error": "nothing drawn"]); return }
                host.cacheDisplay(in: host.bounds, to: picture)
                do {
                    try picture.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    answer(["saved": path])
                } catch { answer(["error": error.localizedDescription]) }
                window.contentView = nil
            }

        case "column":
            // The rail and column, drawn off screen with what the browser has
            // now — the rows, the new-space door and every space icon.
            guard let path = request["path"] as? String else { answer(["error": "column needs a path"]); return }
            let height = request["height"] as? Double ?? 600
            let metrics = ChromeMetrics(size: browser.prefs.interfaceSize)
            let width = metrics.sidebarFootprint(
                browser.prefs.sideWidth,
                rail: browser.prefs.usesSpaces,
                folded: false
            )
            let host = NSHostingView(rootView: SidebarChrome(browser: browser, prefs: browser.prefs)
                .environment(\.chromeMetrics, metrics)
                .frame(width: width, height: height))
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSApp.effectiveAppearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { answer(["error": "nothing drawn"]); return }
                host.cacheDisplay(in: host.bounds, to: picture)
                do {
                    try picture.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    answer(["saved": path])
                } catch { answer(["error": error.localizedDescription]) }
                window.contentView = nil
            }

        case "bar":
            // The bar over the page, the card its site opens, or the card a
            // step in on the connection, drawn off screen with the tab on
            // screen now (see Bar.swift).
            guard let path = request["path"] as? String else { answer(["error": "bar needs a path"]); return }
            let deeper = request["security"] as? Bool == true
            let card = deeper || request["card"] as? Bool == true
            let width = card ? 270 : request["width"] as? Double ?? 900
            let view: AnyView
            if card {
                guard let tab = browser.active, !tab.isBlank else { answer(["error": "no page on screen"]); return }
                // On the ground: off screen there is no glass to stand on.
                view = AnyView(SiteCard(browser: browser, tab: tab, deeper: deeper) {}.fixedSize().background(Palette.ground))
            } else {
                view = AnyView(AddressBar(browser: browser).frame(width: width))
            }
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSApp.effectiveAppearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { answer(["error": "nothing drawn"]); return }
                host.cacheDisplay(in: host.bounds, to: picture)
                do {
                    try picture.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    answer(["saved": path])
                } catch { answer(["error": error.localizedDescription]) }
                window.contentView = nil
            }

        case "environments":
            answer(BookmarkEnvironment.bench(request, browser: browser))

        case "shelf":
            // The bookmarks in the column (see Shelf.swift).
            // "rest": answered once the run loop rests, with the milliseconds
            // the change took to be on screen.
            let start = CACurrentMediaTime()
            let reply = Shelf.bench(request, browser: browser)
            if request["rest"] as? Bool == true {
                Bench.whenResting(since: start) { rested in answer(reply.merging(["rested": rested]) { $1 }) }
            } else {
                answer(reply)
            }

        case "migration-keychain":
            answer(MigrationKeychainBench.run())

        case "routes":
            answer(LinkRoutesBench.run(request, browser: browser))

        case "space":
            // The spaces, and switching between them, for a test of what a
            // space keeps apart. Test runs only: it moves your tabs about.
            guard Store.testing else { answer(["error": "space only works on a --test run"]); return }
            if request["action"] as? String == "credentials" {
                var result: [String: Any] = [:]
                if let user = request["user"] as? String {
                    result["saved"] = Vault.save(host: "issue40.invalid", user: user, password: "synthetic-test-secret", space: browser.spaceID)
                }
                result["users"] = Vault.logins(for: "issue40.invalid", space: browser.spaceID).map(\.user)
                answer(result)
                return
            }
            if request["action"] as? String == "capture" {
                let host = request["host"] as? String ?? "issue40.invalid"
                let type = request["type"] as? Int ?? 0
                switch request["choice"] as? String {
                case "allow": browser.rememberCapture(true, host: host, type: type, space: browser.spaceID)
                case "deny": browser.rememberCapture(false, host: host, type: type, space: browser.spaceID)
                case "clear": browser.forgetCaptureChoices()
                default: break
                }
                answer(["choice": browser.captureChoice(host: host, type: type, space: browser.spaceID) as Any? ?? NSNull()])
                return
            }
            if request["action"] as? String == "glide" {
                // Two fingers DX along in STEPS moves, one a turn of the run
                // loop as a trackpad sends them, each timed until the window
                // rests: what a frame of the swipe costs. Let go of as
                // cancelled, so no space changes.
                let steps = max(1, request["steps"] as? Int ?? 30)
                let dx = request["dx"] as? Double ?? -120
                SpaceSwipe.shared.start(for: browser)
                SpaceSwipe.shared.began()
                var times: [Double] = []
                @MainActor func step(_ index: Int) {
                    guard index < steps else {
                        SpaceSwipe.shared.ended(cancelled: true)
                        answer(["ms": times])
                        return
                    }
                    let start = CACurrentMediaTime()
                    SpaceSwipe.shared.moved(along: dx / Double(steps))
                    Bench.whenResting(since: start) { rested in
                        times.append(rested)
                        DispatchQueue.main.async { step(index + 1) }
                    }
                }
                step(0)
                return
            }
            switch request["action"] as? String ?? "" {
            case "new": browser.addSpace(named: request["name"] as? String ?? "Test")
            case "oauth":
                if let url = (request["url"] as? String).flatMap(URL.init(string:)) {
                    Task { _ = try? await ExtensionAuth.run(url, extension: "bench-auth", browser: browser) }
                }
            case "duplicate":
                browser.duplicateSpace(browser.spaceID, named: request["name"] as? String ?? "Copy",
                                       identifier: (request["identifier"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID())
            case "go": browser.switchSpace(index: (request["index"] as? Int ?? 1) - 1)
            case "delete": browser.deleteSpace(browser.spaceID)
            case "swipe":
                // Two fingers sideways over the column, as the swipe reads
                // them — the trackpad's own events can't reach a probe in the back.
                let dx = request["dx"] as? Double ?? -120
                SpaceSwipe.shared.start(for: browser)
                SpaceSwipe.shared.began()
                for _ in 0..<12 { SpaceSwipe.shared.moved(along: dx / 12) }
                SpaceSwipe.shared.ended()
            case "hold":
                // The fingers down and DX along, not yet let go — for a look
                // at the column mid-swipe.
                let dx = request["dx"] as? Double ?? -120
                SpaceSwipe.shared.start(for: browser)
                SpaceSwipe.shared.began()
                for _ in 0..<12 { SpaceSwipe.shared.moved(along: dx / 12) }
            case "release":
                SpaceSwipe.shared.ended()
            case "move":
                if let index = request["index"] as? Int { browser.moveSpace(browser.spaceID, to: index - 1) }
            case "transfer":
                if let index = request["index"] as? Int, browser.spaces.indices.contains(index - 1),
                   let tab = find(request, in: browser) {
                    browser.transfer(tab, to: browser.spaces[index - 1].id)
                }
            default: break
            }
            let out: [String: Any] = [
                "on": browser.prefs.usesSpaces,
                "current": browser.space.name,
                "spaces": browser.spaces.map { ["name": $0.name, "id": $0.id.uuidString, "downloads": $0.downloads ?? "", "planned": $0.plannedExtensions?.count ?? 0] },
                "parked": browser.parked.map { [$0.key.uuidString: $0.value.tabs.count] },
                "tabs": browser.tabs.count,
                "history": browser.history.count,
                "keptDownloads": browser.loot.kept.count,
                "pendingAuth": ExtensionAuth.pending,
                "making": browser.makingSpace,
                "swipe": Double(browser.spaceSwipe),
                "pages": Web.pages.allObjects.map { $0.configuration.websiteDataStore.identifier?.uuidString ?? "default" },
            ]
            // And the stores WebKit keeps by identifier: a moment after a
            // deletion, what the deleted space should have taken with it;
            // otherwise once the change has been through the run loop.
            let after: (@escaping @MainActor () -> Void) -> Void = request["action"] as? String == "delete"
                ? { then in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { then() } }
                : { then in Bench.afterRests(2, then) }
            after {
                WKWebsiteDataStore.fetchAllDataStoreIdentifiers { ids in
                    MainActor.assumeIsolated {
                        // What is still in the stores of deleted spaces — none, if deleting emptied them.
                        let erasing = (Store.settings.stringArray(forKey: "spaces.erasing") ?? []).compactMap(UUID.init)
                        guard request["records"] as? Bool == true, !erasing.isEmpty else {
                            answer(out.merging(["stores": ids.map(\.uuidString)]) { a, _ in a })
                            return
                        }
                        Task { @MainActor in
                            var left: [String: [String]] = [:]
                            for id in erasing where ids.contains(id) {
                                let records = await WKWebsiteDataStore(forIdentifier: id)
                                    .dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
                                left[id.uuidString] = records.map { "\($0.displayName): \($0.dataTypes.sorted().joined(separator: ","))" }
                            }
                            answer(out.merging(["stores": ids.map(\.uuidString), "erasingRecords": left]) { a, _ in a })
                        }
                    }
                }
            }

        case "ui":
            // Open or close the app's own panels, to reproduce what a person
            // did without a person.
            if let on = request["settings"] as? Bool { browser.tuning = on }
            if let on = request["passwords"] as? Bool { browser.managing = on }
            if let on = request["welcome"] as? Bool { browser.welcoming = on }
            if let on = request["history"] as? Bool { browser.recalling = on }
            if request["clearHistory"] as? Bool == true { browser.clearHistory() }
            if let on = request["downloads"] as? Bool { browser.hoarding = on }
            if let on = request["bookmarks"] as? Bool { browser.bookmarking = on }
            if let on = request["hidden"] as? Bool { browser.reviewing = on }
            if let look = (request["look"] as? String).flatMap(Look.init) { browser.prefs.look = look }
            if let tone = (request["tone"] as? String).flatMap(Tone.init) { browser.prefs.tone = tone }
            if let size = (request["size"] as? String).flatMap(InterfaceSize.init) { browser.prefs.interfaceSize = size }
            if let depth = (request["depth"] as? String).flatMap(Depth.init) { browser.prefs.depth = depth }
            if Store.testing, let on = request["fasterShortcuts"] as? Bool { browser.prefs.fasterShortcuts = on }
            if let on = request["contrast"] as? Bool { browser.prefs.increasesContrast = on }
            if let on = request["copy"] as? Bool { browser.prefs.copyDoor = on }
            if let on = request["sidebar"] as? Bool { browser.prefs.sidebar = on }
            if let on = request["spaces"] as? Bool { browser.prefs.usesSpaces = on }
            if let on = request["hides"] as? Bool { browser.prefs.sideHides = on }
            if let on = request["bar"] as? Bool { browser.prefs.addressBar = on }
            if let on = request["shelf"] as? Bool { browser.prefs.sideBookmarks = on }
            if let on = request["folded"] as? Bool { browser.folded = on }
            if let on = request["peek"] as? Bool { browser.peeking = on }
            if let on = request["alerts"] as? Bool { browser.prefs.developerAlerts = on }
            if let on = request["alertAgents"] as? Bool { browser.prefs.alertAgents = on }
            if let on = request["alertBuilds"] as? Bool { browser.prefs.alertBuilds = on }
            if let on = request["alertPRs"] as? Bool { browser.prefs.alertPRs = on }
            if let on = request["alertWorkflows"] as? Bool { browser.prefs.alertWorkflows = on }
            // Settings whose work lives in the pages, turned while a page is
            // up — for what stops and starts there, not only in the next one.
            if let on = request["links"] as? Bool { browser.prefs.showsLinks = on }
            if let on = request["autoscroll"] as? Bool { browser.prefs.autoScroll = on }
            if let on = request["reading"] as? Bool { browser.prefs.showsReading = on }
            if let on = request["saving"] as? Bool { browser.prefs.savesPasswords = on }
            if let on = request["filling"] as? Bool { browser.prefs.fillsPasswords = on }
            // The address of the tab on screen being edited in the tab, with
            // this typed, and that edit let go of by a click elsewhere.
            if let text = request["edittab"] as? String, let tab = browser.active {
                browser.beginTabEdit(tab)
                browser.tabDraft = text
            }
            if request["finishedit"] as? Bool == true { browser.finishTabEdit() }
            if #available(macOS 15.4, *), let on = request["extensions"] as? Bool { Extensions.shared.menuOpen = on }
            answer(["ok": true])

        case "extensions", "ext-add", "ext-folder", "ext-press", "ext-remove", "ext-reload", "ext-page", "ext-popup", "ext-menu", "ext-pin", "ext-shot", "ext-answer", "ext-enable":
            guard #available(macOS 15.4, *) else {
                answer(["error": "extensions need macOS 15.4"])
                return
            }
            extensionCommand(verb, request, browser: browser, answer)

        default:
            answer(["error": "unknown command “\(verb)”", "commands": [
                "calls", "update", "tabs", "alerts", "transfer", "open", "go", "close", "wait", "sleep", "idle", "pin", "caches", "select", "crash", "text", "eval", "click", "type", "submit", "shot", "probe", "key", "resize", "hit", "pointer", "drag", "film", "window", "pages", "picture", "place", "field", "recall", "bookmark", "menu", "space", "routes", "shelf", "environments", "strip", "column", "bar", "ui",
            ]])
        }
    }

    /// The extension buttons the window holds, with the Space each belongs
    /// to. An anchor exists only under a button the bar drew, so this is
    /// what is on screen rather than what the list says should be.
    private func extensionBar() -> [[String: Any]] {
        guard let root = Links.window?.contentView?.superview else { return [] }
        var found: [[String: Any]] = []
        func walk(_ view: NSView) {
            if let anchor = view as? ExtensionAnchor, !anchor.isHiddenOrHasHiddenAncestor {
                let frame = anchor.convert(anchor.bounds, to: nil)
                found.append(["id": anchor.id, "space": anchor.space?.uuidString ?? "",
                              "frame": [frame.minX, frame.minY, frame.width, frame.height].map { Int($0) }])
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    /// Extensions, from the shell. Installing asks as it always does, except
    /// in a test run given `yes` — a real browser can't be made to skip it.
    @available(macOS 15.4, *)
    private func extensionCommand(_ verb: String, _ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        let extensions = Extensions.shared
        let skip = Store.testing && (request["yes"] as? Bool ?? false)
        switch verb {
        case "extensions":
            answer(["speech": ExtensionSpeech.shared.state, "busy": extensions.busy ?? "", "bar": extensionBar(), "extensions": extensions.installed.map { item -> [String: Any] in
                let context = extensions.contexts[item.id]
                let action = context?.action(for: extensions.activeAdapter)
                return [
                    "id": item.id, "name": item.name, "version": item.version, "enabled": item.enabled,
                    "loaded": context != nil,
                    "base": context?.baseURL.absoluteString ?? "",
                    "errors": (context?.errors ?? []).map { error in
                        let e = error as NSError
                        let under = (e.userInfo[NSUnderlyingErrorKey] as? NSError).map { " ← \($0.localizedDescription) \($0.userInfo)" } ?? ""
                        return e.localizedDescription + under + (e.userInfo.isEmpty ? "" : " \(e.userInfo.filter { $0.key != NSLocalizedDescriptionKey && $0.key != NSUnderlyingErrorKey })")
                    },
                    "reported": extensions.errors[item.id] ?? [],
                    "action": action?.label ?? "", "badge": action?.badgeText ?? "",
                    "popup": action?.presentsPopup ?? false,
                    "pinned": item.pinned ?? false, "source": item.source ?? "",
                ]
            }])
        case "ext-add":
            guard let text = request["id"] as? String else { answer(["error": "ext-add needs an id or link"]); return }
            extensions.install(from: text, confirm: !skip)
            answer(["started": true])
        case "ext-folder":
            guard let path = request["path"] as? String else { answer(["error": "ext-folder needs a path"]); return }
            extensions.installFolder(at: URL(fileURLWithPath: path), confirm: !skip)
            answer(["started": true])
        case "ext-press":
            guard let id = request["id"] as? String else { answer(["error": "ext-press needs an id"]); return }
            extensions.press(id)
            answer(["pressed": true])
        case "ext-enable":
            guard let id = request["id"] as? String else { answer(["error": "ext-enable needs an id"]); return }
            extensions.setEnabled(id, request["on"] as? Bool ?? true)
            answer(["enabled": request["on"] as? Bool ?? true])
        case "ext-answer":
            // In a test run: answer every extension's question yes or no
            // without asking, or go back to asking.
            guard Store.testing else { answer(["error": "only in a test run"]); return }
            switch request["answer"] as? String {
            case "yes": extensions.answerForTests = true
            case "no": extensions.answerForTests = false
            default: extensions.answerForTests = nil
            }
            answer(["answer": request["answer"] as? String ?? "ask", "asked": extensions.asked])
        case "ext-shot":
            // A picture of the extension's popup, while it is open.
            guard let id = request["id"] as? String, ExtensionPopup.shared.extensionID == id,
                  let web = ExtensionPopup.shared.view, let path = request["path"] as? String
            else { answer(["error": "no popup open for that extension"]); return }
            shoot(web, to: URL(fileURLWithPath: path), width: nil, answer)
        case "ext-menu":
            // The list behind the puzzle button, as a picture.
            guard let path = request["path"] as? String, let data = extensionMenuPicture()?.representation(using: .png, properties: [:]) else {
                answer(["error": "ext-menu needs a path"])
                return
            }
            do { try data.write(to: URL(fileURLWithPath: path)); answer(["saved": path]) }
            catch { answer(["error": error.localizedDescription]) }
        case "ext-pin":
            guard let id = request["id"] as? String else { answer(["error": "ext-pin needs an id"]); return }
            extensions.setPinned(id, request["on"] as? Bool ?? true)
            answer(["pinned": request["on"] as? Bool ?? true])
        case "ext-reload":
            guard let id = request["id"] as? String else { answer(["error": "ext-reload needs an id"]); return }
            extensions.reload(id)
            answer(["reloading": true])
        case "ext-remove":
            guard let id = request["id"] as? String else { answer(["error": "ext-remove needs an id"]); return }
            extensions.remove(id)
            answer(["removed": true])
        case "ext-popup":
            // JavaScript in the extension's popup, while it is open.
            guard let id = request["id"] as? String, ExtensionPopup.shared.extensionID == id,
                  let web = ExtensionPopup.shared.view
            else { answer(["error": "no popup open for that extension"]); return }
            web.evaluateJavaScript(request["js"] as? String ?? "document.title") { value, error in
                MainActor.assumeIsolated {
                    if let error { answer(["error": error.localizedDescription]); return }
                    answer(["value": Bench.plain(value)])
                }
            }
        case "ext-page":
            // One of the extension's own pages in a bench tab, where `eval`
            // runs with the extension's APIs.
            guard let id = request["id"] as? String, let context = extensions.contexts[id] else {
                answer(["error": "no such extension loaded"])
                return
            }
            let path = (request["path"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let url = context.baseURL.appendingPathComponent(path)
            let ordinary = request["ordinary"] as? Bool == true
            guard !ordinary || Store.testing else { answer(["error": "ordinary extension tabs require a test world"]); return }
            let tab = ordinary ? browser.open(url, foreground: true) : browser.benchOpen(url)
            if !ordinary { house(tab) }
            answer(describe(tab))
        default:
            answer(["error": "unknown"])
        }
    }

    /// The tab a request names, among the ones the bench opened itself. The
    /// bench is how this browser is driven while somebody is using it, and
    /// reading, clicking or sleeping in one of their tabs is not part of
    /// that: a script here is meant for tabs marked with the flask. A
    /// ESCALE_PROBE run has nobody's tabs in it, so there any tab answers,
    /// as for `tap` and `select`: a popup a bench page opened with
    /// `window.open` carries no flask and would be out of reach otherwise.
    private func find(_ request: [String: Any], in browser: Browser) -> Tab? {
        guard let ref = (request["id"] as? String)?.lowercased(), !ref.isEmpty else { return nil }
        return (browser.tabs + browser.parkedTabs).first {
            (Store.testing || $0.bench) && $0.id.uuidString.lowercased().hasPrefix(ref)
        }
    }

    private func missing(_ request: [String: Any]) -> [String: Any] {
        ["error": "no tab “\(request["id"] as? String ?? "")” — see tabs"]
    }

    private func describe(_ tab: Tab) -> [String: Any] {
        var out: [String: Any] = [
            "id": Bench.short(tab),
            "url": tab.address?.absoluteString ?? "",
            "title": tab.title,
            "name": tab.name ?? "",
            "loading": tab.loading,
            "hollow": tab.hollow,
            "view": tab.built?.url?.absoluteString ?? "",
            "pageZoom": Double(tab.built?.pageZoom ?? 1),
            "zoom": Double(tab.zoom),
            "noisy": tab.noisy,
            "audioAvailable": tab.built?.responds(to: NSSelectorFromString("_isPlayingAudio")) ?? false,
            "audioValue": tab.built.flatMap { $0.responds(to: NSSelectorFromString("_isPlayingAudio")) ? $0.value(forKey: "_isPlayingAudio") as? Bool : nil } as Any? ?? NSNull(),
            "camera": Bench.name(of: tab.built?.cameraCaptureState),
            "microphone": Bench.name(of: tab.built?.microphoneCaptureState),
            "bench": tab.bench,
            "active": tab.id == browser?.activeID,
            "asleep": tab.asleep,
            "sleeping": tab.sleeping,
            "pin": tab.pin ?? "",
            "picture": tab.pictureBytes,
            "covered": tab.cover != nil,
            "returning": tab.returning,
            "unpainted": tab.built?.unpainted ?? false,
            "shy": tab.shy,
            "space": tab.space.uuidString,
            "store": tab.store.identifier?.uuidString ?? "default",
            "extensions": { if #available(macOS 15.4, *) { return tab.carriesExtensions } else { return false } }(),
        ]
        if Store.measuring, let page = tab.built, let firstVisibleAt = page.firstVisibleAt {
            out["firstVisibleAt"] = firstVisibleAt
            out["firstVisibleSource"] = page.firstVisibleSource ?? "unknown"
        }
        if let failure = tab.failure { out["failure"] = failure }
        return out
    }

    /// What a page's camera or microphone is doing, for scenarios about calls.
    private static func name(of state: WKMediaCaptureState?) -> String {
        switch state {
        case .active: "active"
        case .muted: "muted"
        default: "none"
        }
    }

    static func short(_ tab: Tab) -> String {
        String(tab.id.uuidString.prefix(8)).lowercased()
    }

    /// The address field, wherever it is in the window.
    static func addressField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.delegate is AddressField.Coordinator { return field }
        for sub in view.subviews { if let found = addressField(in: sub) { return found } }
        return nil
    }

    /// When `condition` holds, checked at each rest of the run loop, and
    /// then once more rested; or after `seconds` regardless.
    static func within(_ seconds: Double, until condition: @escaping @MainActor () -> Bool, _ then: @escaping @MainActor () -> Void) {
        let limit = CACurrentMediaTime() + seconds
        @MainActor func check() {
            if condition() { afterRests(1, then); return }
            guard CACurrentMediaTime() < limit else { then(); return }
            // Each turn, or every 10 ms when the run loop has nothing to do.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { check() }
        }
        check()
    }

    /// The address field and its editor once the focus last asked for has
    /// been given, or nil after `seconds`. The field answers a request in
    /// SwiftUI's next update, selecting all it holds: a key typed before
    /// that would be replaced by the next one.
    static func addressEditor(for input: Field, within seconds: Double, _ then: @escaping @MainActor ((NSTextField, NSTextView)?) -> Void) {
        func found() -> (NSTextField, NSTextView)? {
            guard let field = addressField(in: Links.window?.contentView),
                  let editor = field.currentEditor() as? NSTextView else { return nil }
            return (field, editor)
        }
        within(seconds, until: { input.focusGiven == input.focusRequest && found() != nil }) { then(found()) }
    }

    /// Milliseconds from `start` to the run loop's next rest — after every
    /// observer that runs before it sleeps, Core Animation's commit included.
    static func whenResting(since start: CFTimeInterval, _ then: @escaping @MainActor (Double) -> Void) {
        var observer: CFRunLoopObserver?
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            let rested = (CACurrentMediaTime() - start) * 1000
            MainActor.assumeIsolated { then(rested) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// Once the run loop has rested `times` turns in a row: what a change
    /// set off, SwiftUI's update, Core Animation's commit and what they left
    /// for the next turn. A state, where a fixed delay only guessed one.
    static func afterRests(_ times: Int = 2, _ then: @escaping @MainActor () -> Void) {
        whenResting(since: CACurrentMediaTime()) { _ in
            if times <= 1 { then() } else { DispatchQueue.main.async { afterRests(times - 1, then) } }
        }
    }

    private static var mark = 0
    private static var waiting: [Int: @MainActor () -> Void] = [:]
    private static var marker: Any?

    /// Once the events posted to the app before now have been through it: a
    /// marker posted behind them comes out of the queue after they do. A
    /// tracking loop (a menu held open) keeps the marker waiting, so after
    /// `limit` the answer goes anyway, as the fixed delay it replaced did.
    /// One monitor serves every marker, installed on first use and released
    /// with the bench: adding and removing one around each command, from its
    /// own callback, let a key slip past the monitors added before it.
    static func afterQueue(limit: Double = 0.4, _ then: @escaping @MainActor () -> Void) {
        if marker == nil {
            marker = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { event in
                guard event.subtype.rawValue == 0x4265 else { return event }
                let mine = event.data1
                // Answered after the monitor returns, never from inside it.
                DispatchQueue.main.async { MainActor.assumeIsolated { waiting.removeValue(forKey: mine)?() } }
                return nil
            }
        }
        mark += 1
        let mine = mark
        waiting[mine] = then
        guard let event = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, subtype: 0x4265, data1: mine, data2: 0
        ) else { waiting.removeValue(forKey: mine)?(); return }
        NSApp.postEvent(event, atStart: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { waiting.removeValue(forKey: mine)?() }
    }

    /// The markers' monitor and whatever still waits on one, with the bench.
    static func releaseQueue() {
        if let marker { NSEvent.removeMonitor(marker) }
        marker = nil
        waiting = [:]
    }

    /// Once the page has stopped loading, or the time is up.
    private func wait(for tab: Tab, until limit: Date, _ answer: @escaping ([String: Any]) -> Void) {
        if !tab.loading, tab.address != nil, tab.failure == nil || true {
            // A beat for the document's own scripts to settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                var out = describe(tab)
                if let failure = tab.failure { out["failure"] = failure }
                answer(out)
            }
            return
        }
        guard Date() < limit else {
            var out = describe(tab)
            out["timeout"] = true
            answer(out)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.wait(for: tab, until: limit, answer)
        }
    }

    // MARK: - the room off screen

    private var room: NSWindow?

    /// A page nobody is looking at has to be somewhere to be laid out at all.
    /// The stage takes it back the moment you pick its tab, and it comes
    /// here again when the bench next needs it.
    private func house(_ tab: Tab) {
        guard tab.bench, tab.web.window == nil else { return }
        let window = room ?? makeRoom()
        tab.web.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        tab.web.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(tab.web)
    }

    private func makeRoom() -> NSWindow {
        // Off every screen, and never key or main: it exists so that a web
        // view has a window, and for nothing else.
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.hasShadow = false
        window.orderBack(nil)
        room = window
        return window
    }

    private func shoot(_ tab: Tab, to file: URL, width: Double?, _ answer: @escaping ([String: Any]) -> Void) {
        shoot(tab.web, to: file, width: width, answer)
    }

    private func shoot(_ web: WKWebView, to file: URL, width: Double?, _ answer: @escaping ([String: Any]) -> Void) {
        let shot = WKSnapshotConfiguration()
        shot.afterScreenUpdates = true
        if let width { shot.snapshotWidth = NSNumber(value: width) }
        web.takeSnapshot(with: shot) { image, error in
            MainActor.assumeIsolated {
                guard let image, let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:])
                else {
                    answer(["error": error?.localizedDescription ?? "no picture"])
                    return
                }
                do {
                    try png.write(to: file)
                    answer(["path": file.path, "width": rep.pixelsWide, "height": rep.pixelsHigh])
                } catch {
                    answer(["error": error.localizedDescription])
                }
            }
        }
    }

    // MARK: - page-side helpers

    /// A JavaScript value the way JSON can carry it.
    private static func plain(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        if JSONSerialization.isValidJSONObject(["v": value]) { return value }
        return String(describing: value)
    }

    /// Where an element's middle is, in the page's own points, scrolled
    /// into view first. A selector, or `text=…` for a button or link by its
    /// words.
    private static func locate(_ selector: String) -> String {
        let sel = (try? JSONSerialization.data(withJSONObject: [selector])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        return """
        (function () {
          var s = \(sel), el = null;
          if (s.indexOf('text=') === 0) {
            var want = s.slice(5).trim().toLowerCase();
            el = Array.prototype.find.call(document.querySelectorAll('button, a, [role=button], input[type=submit]'), function (e) {
              return ((e.innerText || e.value || '').trim().toLowerCase()) === want;
            }) || null;
          } else {
            el = document.querySelector(s);
          }
          if (!el) return null;
          el.scrollIntoView({ block: 'center', inline: 'nearest' });
          var r = el.getBoundingClientRect();
          return [r.left + r.width / 2, r.top + r.height / 2];
        })()
        """
    }

    /// Click, type into, or submit the element a selector names. Typing goes
    /// through the field's own setter and fires the events a keystroke
    /// would, the same as the password filler, so frameworks notice.
    private static func act(_ verb: String, selector: String, text: String) -> String {
        let sel = (try? JSONSerialization.data(withJSONObject: [selector])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        let txt = (try? JSONSerialization.data(withJSONObject: [text])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        return """
        (function () {
          var el = document.querySelector(\(sel));
          if (!el) return 'nothing matches ' + \(sel);
          if (el.scrollIntoView) el.scrollIntoView({ block: 'center', inline: 'nearest' });
          var verb = '\(verb)';
          if (verb === 'click') { el.focus && el.focus(); el.click(); return 'ok'; }
          if (verb === 'submit') {
            var form = el.tagName === 'FORM' ? el : el.form || el.closest('form');
            if (!form) return 'no form around ' + \(sel);
            if (form.requestSubmit) form.requestSubmit(); else form.submit();
            return 'ok';
          }
          el.focus && el.focus();
          var value = \(txt);
          if (el.isContentEditable) {
            el.textContent = value;
            el.dispatchEvent(new InputEvent('input', { bubbles: true, data: value, inputType: 'insertText' }));
            return 'ok';
          }
          var proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
          var setter = Object.getOwnPropertyDescriptor(proto, 'value');
          if (setter && setter.set) setter.set.call(el, value); else el.value = value;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return 'ok';
        })();
        """
    }
}
