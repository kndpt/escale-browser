// A tab's audible session is discovered by its existing WebKit audio observer.
// Only that page receives the event-driven reader; one snapshot and one command
// are retained, never artwork or another web view. Navigation, sleep, close and
// dismissal remove its handler, DOM listeners and pending work. A UUID rejects
// replies from an earlier document even when WebKit reuses the same view.
import WebKit
import Combine

struct MediaState: Equatable {
    var key = ""
    var title = ""
    var playing = false
    var muted = false
    var video = false
    var volume: Double?
    var actions: Set<String> = []
}

@MainActor
final class Media: NSObject, ObservableObject, WKScriptMessageHandler {
    private let name = "escaleMedia_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private static let script = Bundled.script("media.js")
    @Published private(set) var state: MediaState?
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    private(set) var dismissed = false
    private(set) var listening = false
    private weak var web: WKWebView?
    private var token = UUID().uuidString
    private var audible = false
    private var dismissedElement = false
    private var revision = 0
    var changed: (() -> Void)?

    func sound(_ on: Bool, in web: WKWebView) {
        let started = on && !audible
        audible = on
        if started { dismissed = false; dismissedElement = false }
        if on && !dismissed {
            // A new audible session may come from another element or frame.
            if started && listening && state?.playing == false { stop() }
            start(web)
        }
        if listening, state?.key.hasPrefix("spotify:") == true {
            // Spotify may have no document media element. Keep its visible
            // controls through pause instead of clearing them on WebKit .none.
            web.callAsyncJavaScript("window.__escaleMedia?.sound(token, playing)",
                                    arguments: ["token": token, "playing": on], in: nil, in: .page, completionHandler: nil)
            return
        }
        if !on && !listening && !dismissed { publish(nil) }
        if !on && listening && state == nil { reset(); return }
        if !on && listening {
            let asked = token
            web.requestMediaPlaybackState { [weak self, weak web] playback in
                guard let self, self.token == asked, self.web === web, !self.audible else { return }
                if playback == .none { self.reset() }
                else if var state = self.state, state.key.isEmpty, playback != .playing {
                    state.playing = false; state.actions = []; self.publish(state)
                }
            }
        }
    }

    /// Public fallback on leaving a page, never a timer over all open tabs.
    func leaving(_ web: WKWebView?) {
        guard let web else { return }
        if audible || dismissed {
            let paused = dismissed && !audible && dismissedElement
            dismissed = false; dismissedElement = false
            start(web, allowPaused: paused); changed?(); return
        }
        guard !web.responds(to: NSSelectorFromString("_isPlayingAudio")) else { return }
        let asked = token
        web.requestMediaPlaybackState { [weak self, weak web] playback in
            guard let self, let web, self.token == asked, playback == .playing else { return }
            self.dismissed = false; self.start(web)
        }
    }

    private func start(_ web: WKWebView, allowPaused: Bool = false) {
        guard !listening else { return }
        self.web = web
        error = nil
        listening = true
        revision = 0
        token = UUID().uuidString
        let asked = token
        let controller = web.configuration.userContentController
        controller.removeScriptMessageHandler(forName: name)
        controller.add(self, name: name)
        publish(MediaState(playing: audible))
        web.callAsyncJavaScript(Self.script, arguments: ["token": asked, "handler": name, "allowPaused": allowPaused, "nativeAudio": audible], in: nil, in: .page) { [weak self] result in
            guard let self, self.token == asked else { return }
            if case .failure = result {
                self.error = "Open the source for more controls."
                if let web = self.web { self.fallback(in: web) }
            }
        }
    }

    /// An explicit PiP reduction can reveal even a silent or paused video.
    func reveal(_ web: WKWebView) {
        dismissed = false; dismissedElement = false
        start(web, allowPaused: true)
        changed?()
    }

    func dismiss() {
        dismissedElement = state?.key.isEmpty == false
        dismissed = true
        stop()
        publish(nil)
    }

    func reset() {
        stop(); audible = false; dismissed = false; dismissedElement = false; error = nil
        publish(nil)
    }

    private func stop() {
        let old = token
        token = UUID().uuidString
        if listening, let web {
            web.configuration.userContentController.removeScriptMessageHandler(forName: name)
            web.callAsyncJavaScript("window.__escaleMedia?.stop(token)", arguments: ["token": old], in: nil, in: .page, completionHandler: nil)
        }
        listening = false; busy = false; web = nil
    }

    private func publish(_ next: MediaState?) {
        if state != next { state = next }
        changed?()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard listening, message.webView === web, message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any], body["token"] as? String == token,
              let serial = body["revision"] as? Int, serial > revision else { return }
        revision = serial
        if body["ended"] as? Bool == true {
            publish(nil)
            if !audible { reset() }
            return
        }
        guard let playing = body["playing"] as? Bool else { return }
        if body["key"] as? String == "", let web {
            publish(MediaState(playing: audible))
            fallback(in: web)
            return
        }
        let allowed: Set<String> = ["play", "pause", "previous", "next", "volume"]
        let actions = Set((body["actions"] as? [String] ?? []).prefix(5)).intersection(allowed)
        let volume = (body["volume"] as? Double).flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
        publish(MediaState(key: String((body["key"] as? String ?? "").prefix(1024)),
                           title: String((body["title"] as? String ?? "").prefix(256)),
                           playing: playing, muted: body["muted"] as? Bool ?? false,
                           video: body["video"] as? Bool ?? false, volume: volume, actions: actions))
    }

    // An audible frame may expose public pause; Web Audio may expose no
    // playback state at all. Query only on discovery or a requested pause.
    private func fallback(in web: WKWebView, afterPause: Bool = false) {
        let asked = token
        web.requestMediaPlaybackState { [weak self, weak web] playback in
            guard let self, self.token == asked, self.web === web else { return }
            if afterPause { self.busy = false }
            guard self.state?.key.isEmpty == true else { return }
            let playing = playback == .playing || (playback == .none && self.audible)
            if afterPause && playing { self.error = "This control could not complete. Open the source." }
            self.publish(MediaState(playing: playing, actions: playback == .playing && !afterPause ? ["pause"] : []))
        }
    }

    func command(_ action: String, value: Double? = nil) {
        guard !busy, let web, let state, state.actions.contains(action) else { return }
        error = nil
        busy = true
        let asked = token
        if action == "pause", state.key.isEmpty {
            web.pauseAllMediaPlayback { [weak self, weak web] in
                guard let self, let web, self.token == asked else { return }
                self.fallback(in: web, afterPause: true)
            }
            return
        }
        web.callAsyncJavaScript("return await window.__escaleMedia?.command(token, action, key, value)",
                                arguments: ["token": asked, "action": action, "key": state.key, "value": value ?? 0],
                                in: nil, in: .page) { [weak self] result in
            guard let self, self.token == asked else { return }
            self.busy = false
            if case .success(let value) = result, value as? Bool == true { return }
            guard self.state?.key == state.key else { return }
            self.error = "This control could not complete. Open the source."
            if var state = self.state { state.actions.remove(action); self.publish(state) }
        }
    }
}
