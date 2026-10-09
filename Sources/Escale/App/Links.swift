import AppKit

// Links from elsewhere. A click in Mail, in Slack, in a PDF — macOS hands the
// address to whichever app owns http, and this is how that app takes it.
//
// The bundle says it owns http and https (build.sh writes that into the
// plist); this is the other half. Addresses can arrive before the window has
// been built, so they wait here until the browser says it is ready for them.

final class Links: NSObject, NSApplicationDelegate {
    /// Where an address goes once there is somewhere for it to go.
    private static var deliver: ((URL) -> Void)?
    /// Addresses that arrived first.
    private static var waiting: [URL] = []
    /// The browser's window, once there is one.
    static weak var window: NSWindow?
    /// Whether the window has been asked for on a link's behalf (summon).
    private static var summoned = false
    /// The session and the rest, written now rather than whenever their
    /// debounces were going to get to them (see Browser.flush). ⌘Q, the Dock's
    /// Quit and an update's relaunch all end the process the same way, and
    /// none of them owed the last 1.2 seconds of typing anywhere to finish
    /// writing it down on their own.
    private static var flush: (() -> Void)?

    /// Session cookies go with the session (see Jar.swift). WebKit hands them
    /// over asynchronously, so the quit waits for them, a second at most.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Jar.keep(Spaces.made) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        ExtensionSpeech.shared.stop() // Audio must end before the process (see ExtensionSpeech.swift).
        Links.flush?()
        // Then every file still waiting to be written, parked spaces'
        // sessions among them (see Writer.swift).
        Writer.flushAll()
    }

    /// The nearest thing to a crash reporter a browser with no server can
    /// have: nothing is sent anywhere, but a beta with no record of what
    /// went wrong is a beta nobody can fix. One line, appended, so it
    /// survives the crash that is about to end the process.
    static func watchForTrouble() {
        NSSetUncaughtExceptionHandler { exception in
            let line = "\(Date()) — \(exception.name.rawValue): \(exception.reason ?? "?")\n"
                + exception.callStackSymbols.joined(separator: "\n") + "\n\n"
            let file = Store.file("crash.log")
            if let handle = FileHandle(forWritingAtPath: file.path) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8) ?? Data())
                handle.closeFile()
            } else {
                try? FileManager.default.createDirectory(at: Store.folder, withIntermediateDirectories: true)
                try? line.write(to: file, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Addresses come in as Apple Events, one each. Taking them straight
    /// from the event manager keeps them out of SwiftUI's hands: left to it,
    /// every address handed at launch had the window presented afresh, and
    /// five of them meant five rebuilds of the content before the window
    /// had shown once.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // A binary run straight from .build/ has no bundle, and macOS takes it
        // for a background process: its window shows but never becomes key,
        // so it takes neither typing nor a drag. The .app is never touched.
        if Bundle.main.bundleIdentifier == nil {
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.async { NSApp.activate() }
        }
        Links.watchForTrouble()
        // A test world's script is the only one typing into it while the
        // bench listens (BenchKeys.swift).
        BenchKeys.install()
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handle(getURL:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )
    }

    /// A launch macOS doesn't call a plain one — started hidden, as `open -j`
    /// or anything asking for a hidden launch does — SwiftUI treats like the
    /// launch a link makes below: it leaves its window to whatever the launch
    /// came for, and nothing comes. The app ran with no window at all. The
    /// window is asked for here instead; started hidden, it stays hidden
    /// with the app until the app is shown.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let plain = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        guard !plain else { return }
        DispatchQueue.main.async {
            guard !NSApp.windows.contains(where: { $0.contentView != nil && !($0 is NSPanel) }) else { return }
            Links.summon()
        }
    }

    @objc private func handle(getURL event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text), url.scheme?.lowercased().hasPrefix("http") == true
        else { return }
        Links.take(url)
    }

    /// Files and anything else the system opens with the app.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased().hasPrefix("http") == true {
            Links.take(url)
        }
    }

    /// Closing the window closes the window, as in Safari or Chrome: the app
    /// stays. Left to SwiftUI, an app whose one scene is a `Window` quits
    /// with it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The Dock icon clicked with the window closed: bring the window back
    /// rather than doing nothing, which is what a hidden-title-bar SwiftUI
    /// window does by default.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let window = NSApp.windows.first(where: { $0.contentView != nil }) {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    /// The browser, once it has a window. Anything that came earlier is
    /// handed over now — but none of it before the window is on screen.
    ///
    /// Five addresses at launch used to mean five web views built before the
    /// first frame, and a window that took a second to appear instead of a
    /// third of one. Now the window comes first; the first page goes into
    /// the blank tab that is already there, and the others fill in behind
    /// it, a few frames apart, in the order they came.
    @MainActor
    static func hand(to browser: Browser) {
        deliver = { [weak browser] url in
            browser?.arrive(url)
            // The window closed with the app still running: the link brings
            // it back, rather than landing in a tab nobody can see.
            if let window {
                if !window.isVisible { window.makeKeyAndOrderFront(nil) }
            } else {
                _ = NSApp.delegate?.applicationOpenUntitledFile?(NSApp)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
        flush = { [weak browser] in browser?.flush() }
        let early = waiting
        waiting = []
        guard let first = early.first else { return }
        onceShown { [weak browser] in
            browser?.arrive(first)
            for (n, url) in early.dropFirst().enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 * Double(n + 1)) { [weak browser] in
                    browser?.arrive(url, foreground: false, atEnd: true)
                }
            }
        }
    }

    /// Runs once a window is actually showing, and one turn of the run loop
    /// after that, so the frame is on the screen before the work starts.
    /// Gives up waiting after a second or so and runs anyway — a launch
    /// started hidden has a window nobody can see yet.
    @MainActor
    static func onceShown(_ then: @escaping () -> Void, tries: Int = 0) {
        let shown = NSApp.windows.contains { $0.isVisible && $0.contentView != nil }
        if shown || tries > 40 {
            DispatchQueue.main.async { then() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { onceShown(then, tries: tries + 1) }
        }
    }

    private static func take(_ url: URL) {
        if let deliver {
            deliver(url)
        } else {
            waiting.append(url)
            DispatchQueue.main.async { summon() }
        }
    }

    /// A link that launches the app arrives as an Apple Event, taken above,
    /// and SwiftUI — seeing a launch that came to open something rather than
    /// a plain one — leaves its window for that event to open. It never sees
    /// the event, so nothing opened it: every link clicked in another app
    /// while Escale was closed launched it with no window and the page
    /// nowhere. SwiftUI's delegate is asked instead for what a plain launch
    /// gets, its window; a single window, so asking twice can't make two.
    @MainActor
    private static func summon() {
        guard deliver == nil, window == nil, !summoned else { return }
        summoned = true
        _ = NSApp.delegate?.applicationOpenUntitledFile?(NSApp)
    }

    /// The Help menu and the About page both come here: a new issue on the
    /// public repository, through its Feedback form
    /// (.github/ISSUE_TEMPLATE/feedback.yml), with the version, build and macOS
    /// already in its fields. A form only takes values in fields it names, so
    /// the keys below follow that file's ids. The person still reads it and
    /// submits it themselves — nothing here sends anything.
    static func writeFeedback() {
        guard var text = URLComponents(string: "https://github.com/\(repository)/issues/new") else { return }
        text.queryItems = [
            URLQueryItem(name: "template", value: "feedback.yml"),
            URLQueryItem(name: "title", value: "Escale feedback — \(Updater.version) (\(Updater.build))"),
            URLQueryItem(name: "escale", value: "\(Updater.version) (\(Updater.build))"),
            URLQueryItem(name: "macos", value: ProcessInfo.processInfo.operatingSystemVersionString),
        ]
        guard let url = text.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// A version's release on the public repository: the same summary, then
    /// its highlights and everything that changed. Opened only when asked.
    static func release(_ version: String) -> URL? {
        guard let tag = version.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://github.com/\(repository)/releases/tag/v\(tag)")
    }

    /// Escale's public repository: its source, its releases and its issues.
    /// build.sh and publish.sh name it too.
    static let repository = "kndpt/escale-browser"

    // MARK: - being the browser

    private static let probe = URL(string: "https://example.com")!

    /// True when this app is where links from other apps go.
    static var isDefault: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// Asks macOS to send http and https here. The system puts up its own
    /// confirmation; the answer arrives through `done`, on the main thread.
    static func becomeDefault(_ done: @escaping (Bool) -> Void) {
        let app = Bundle.main.bundleURL
        let group = DispatchGroup()
        var worked = true
        for scheme in ["http", "https"] {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) { error in
                if error != nil { worked = false }
                group.leave()
            }
        }
        group.notify(queue: .main) { done(worked) }
    }
}
