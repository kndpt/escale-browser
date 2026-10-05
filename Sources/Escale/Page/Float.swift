import AppKit
import WebKit

// A video that keeps playing after you have gone somewhere else, in a small
// window that stays above everything — other tabs, and other apps.
//
// WebKit will not hand a video to the system's picture-in-picture without a
// real click on the page, and nothing the app does counts as one. Chromium is
// looser, which is why this works elsewhere and refused here.
//
// So the engine is not asked. The page itself is moved: everything but the
// video is made invisible, the video is stretched to fill the viewport, and the
// whole web view is lifted out of the window and into a small floating one. The
// video never stops, because it is the same page it always was — it has only
// changed windows.
//
// A meeting is moved the same way, and for the same reason: a second page would
// be a second connection. What it shows and offers is its own (Meeting.swift):
// the people and the shared screen, with the meeting's commands beneath. This
// file keeps what both windows share — the panel, where it was, and moving and
// sizing it by hand.

@MainActor
final class Float {
    private var panel: NSPanel?
    private var controls: Controls?
    private var meeting: Meeting.Controls?
    private weak var page: NSView?

    /// Asked to go away. The browser does the bookkeeping and calls back into
    /// `drop` — there is one way this window closes, and it is not this class
    /// quietly tidying up behind everyone's back. Two paths to closing is how
    /// it stayed on screen after the page had already gone home.
    var onClose: (() -> Void)?
    /// Bring the window forward and go to the tab it came from.
    var onReturn: (() -> Void)?
    /// Reduce the video into the sidebar without selecting its page.
    var onMinimize: (() -> Void)?
    /// Press one of the meeting page's own buttons, by its name in meeting.js.
    var onPress: ((String) -> Void)?
    /// Asked every half second in a meeting: what the page has and how it stands.
    var onMeeting: ((@escaping (Meeting.State) -> Void) -> Void)?
    /// Stop or start the video. Answers with whether it is playing now.
    var onPlayPause: ((@escaping (Bool) -> Void) -> Void)?
    /// Step over the bit you missed, or back to it.
    var onSkip: ((Double) -> Void)?
    /// Asked every half second while the window is up, for the line along the
    /// bottom edge.
    var onProgress: ((@escaping (Double, Bool) -> Void) -> Void)?

    private var ticker: Timer?

    var showing: Bool { panel != nil }
    /// Whether what it holds is a meeting, which has no film to play or skip.
    private(set) var call = false
    /// The buttons on offer, by name, for the bench.
    var offered: [String] { meeting?.offered ?? controls?.offered ?? [] }
    /// What each of a meeting's commands says it will do, for the bench.
    var looks: [String: String] { meeting?.looks ?? [:] }
    /// Half-second beats in a row with the meeting over.
    private var empty = 0
    /// A meeting whose page says it is over for this long has ended, rather
    /// than rebuilding itself between two layouts.
    private static let emptyBeats = 6

    func lift(_ page: NSView, call: Bool = false) {
        guard panel == nil else { return }
        self.page = page
        self.call = call
        empty = 0

        let size = call ? Meeting.size : NSSize(width: 440, height: 247)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        // Where it was last, at the size it was, if a screen still shows it;
        // otherwise the bottom right of this one. A meeting's window has a
        // shape of its own and remembers its own place.
        let key = call ? "float.meeting.frame" : "float.frame"
        let spot = Float.remembered(key) ?? NSRect(
            x: screen.maxX - size.width - 24,
            y: screen.minY + 24,
            width: size.width,
            height: size.height
        )

        let panel = Panel(
            contentRect: spot,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Above every ordinary window, this app's and everyone else's, and
        // present on whichever desktop you happen to be looking at.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // No shadow. A window with one is composited by WindowServer on every
        // frame of the video; without it the video can go straight to the
        // display, as it does in a tab. Measured on 1080p and 4K YouTube:
        // WindowServer's GPU time 28% with the shadow, 16–20% without, 22%
        // playing in the tab.
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        // A film keeps its shape; a meeting's people and screen fit any.
        if !call { panel.aspectRatio = size }
        // Kept once a move or a resize is over, not on each step of one: at
        // the end of a resize by its edges, as it closes (see drop), and as
        // the app quits with it open, which closes nothing.
        let keep: (Notification.Name, AnyObject) -> NSObjectProtocol = { [weak panel] name, object in
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { _ in
                MainActor.assumeIsolated {
                    if let panel { Float.remember(panel.frame, key) }
                }
            }
        }
        keeping = [
            keep(NSWindow.didEndLiveResizeNotification, panel),
            keep(NSApplication.willTerminateNotification, NSApp),
        ]
        panel.minSize = call ? Meeting.smallest : NSSize(width: 260, height: 146)
        keyed = key

        let ground = NSView(frame: NSRect(origin: .zero, size: size))
        ground.wantsLayer = true
        ground.layer?.backgroundColor = Palette.Film.ground.cgColor
        ground.layer?.cornerRadius = 14
        ground.layer?.masksToBounds = true

        // WebKit puts its own pinch recogniser on a web view, and a gesture
        // recogniser is consulted before the responder chain is. With it left
        // on, every pinch aimed at this window went into zooming the page
        // inside it instead of sizing the window. It comes back on landing.
        (page as? WKWebView)?.allowsMagnification = false

        page.removeFromSuperview()
        page.autoresizingMask = [.width, .height]
        ground.addSubview(page)

        if call {
            // The meeting's commands take a band along the bottom; the page is
            // what is above it, laid out as a window of an ordinary size.
            page.frame = NSRect(x: 0, y: Meeting.band, width: size.width, height: size.height - Meeting.band)
            // Its own zoom comes back from its tab on landing (Browser.land).
            (page as? WKWebView)?.pageZoom = Meeting.zoom
            let meeting = Meeting.Controls(frame: ground.bounds)
            meeting.autoresizingMask = [.width, .height]
            meeting.onReturn = { [weak self] in self?.onReturn?() }
            meeting.onMinimize = { [weak self] in self?.onMinimize?() }
            meeting.onPress = { [weak self] name in self?.onPress?(name) }
            ground.addSubview(meeting)
            self.meeting = meeting
        } else {
            page.frame = ground.bounds
            let controls = Controls(frame: ground.bounds)
            controls.autoresizingMask = [.width, .height]
            controls.onClose = { [weak self] in self?.onClose?() }
            controls.onReturn = { [weak self] in self?.onReturn?() }
            controls.onMinimize = { [weak self] in self?.onMinimize?() }
            controls.onPlayPause = { [weak self] in
                self?.onPlayPause? { playing in
                    self?.controls?.playing = playing
                }
            }
            controls.onSkip = { [weak self] seconds in self?.onSkip?(seconds) }
            ground.addSubview(controls)
            self.controls = controls
        }

        panel.contentView = ground
        panel.orderFrontRegardless()
        self.panel = panel

        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }

                // A window that no longer holds the page has nothing to show
                // and no reason to exist. Something else took the page back —
                // and rather than hunt every path that could, this makes it
                // impossible for the empty black rectangle to outlive it by
                // more than half a second.
                if self.page?.superview !== ground {
                    self.onClose?()
                    return
                }

                if self.call {
                    self.onMeeting? { state in
                        self.meeting?.show(state)
                        // The window lasts as long as the meeting, not as long
                        // as someone's camera: cameras off, the people are
                        // still there, and a window that closed on them put the
                        // meeting back in a tab nobody was looking at. A moment
                        // without a way to leave is the page rebuilding; a long
                        // one means the meeting is over.
                        self.empty = state.live ? 0 : self.empty + 1
                        if self.empty >= Float.emptyBeats { self.onClose?() }
                    }
                    return
                }
                self.onProgress? { through, playing in
                    self.controls?.progress = through
                    self.controls?.playing = playing
                }
            }
        }
    }

    /// The window's last place and size, kept across closing it and quitting,
    /// and given back only while a screen still shows most of it.
    private static func remembered(_ key: String) -> NSRect? {
        guard let text = Store.settings.string(forKey: key) else { return nil }
        let frame = NSRectFromString(text)
        let shown = NSScreen.screens.contains {
            let seen = $0.visibleFrame.intersection(frame)
            return seen.width * seen.height > 0.6 * frame.width * frame.height
        }
        return frame.width > 100 && shown ? frame : nil
    }

    private static func remember(_ frame: NSRect, _ key: String) {
        Store.settings.set(NSStringFromRect(frame), forKey: key)
    }

    private var keeping: [NSObjectProtocol] = []
    private var keyed = "float.frame"

    /// Puts the page down and closes. Whoever owns the page takes it back on
    /// their next layout.
    func drop() {
        guard let panel else { return }
        Float.remember(panel.frame, keyed)
        keeping.forEach(NotificationCenter.default.removeObserver)
        keeping = []
        ticker?.invalidate()
        ticker = nil
        (page as? WKWebView)?.allowsMagnification = true
        page?.removeFromSuperview()
        page = nil
        controls = nil
        meeting = nil
        call = false
        panel.orderOut(nil)
        panel.close()
        self.panel = nil
    }

    /// What a small window of video needs, and nothing else: a way out, a way
    /// back, a way to stop it, and a way to step over the bit you missed.
    ///
    /// Out of sight until the pointer is over the window — the whole point of
    /// this window is the picture.
    private final class Controls: Grip {
        var onClose: (() -> Void)?
        var onReturn: (() -> Void)?
        var onMinimize: (() -> Void)?
        var onPlayPause: (() -> Void)?
        var onSkip: ((Double) -> Void)?

        var playing = true {
            didSet { pause.image = Grip.glyph(playing ? "pause.fill" : "play.fill", 17) }
        }

        /// Nought to one. Drawn as a hairline along the bottom edge.
        var progress: Double = 0 {
            didSet { line.through = progress }
        }

        private let close = NSButton()
        private let back = NSButton()
        private let minimize = NSButton()
        private let pause = NSButton()
        private let rewind = NSButton()
        private let forward = NSButton()
        private let scrim = CAGradientLayer()
        private let line = Line()
        private var near = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true

            // A wash at the top and bottom, so white buttons hold against a
            // bright frame of film without covering it.
            scrim.colors = [
                Palette.Film.scrimTop.cgColor,
                NSColor.clear.cgColor,
                NSColor.clear.cgColor,
                Palette.Film.scrimBottom.cgColor,
            ]
            scrim.locations = [0, 0.28, 0.66, 1]
            scrim.opacity = 0
            layer?.addSublayer(scrim)

            dress(close, "xmark", 11, round: 15, action: #selector(pressedClose))
            dress(back, "arrow.up.forward", 12, round: 15, action: #selector(pressedReturn))
            dress(minimize, "pip.exit", 12, round: 15, action: #selector(pressedMinimize))
            minimize.toolTip = "Return to mini player"
            minimize.setAccessibilityLabel("Return to mini player")
            dress(rewind, "gobackward.15", 15, round: 19, action: #selector(pressedRewind))
            dress(pause, "pause.fill", 17, round: 25, action: #selector(pressedPause))
            dress(forward, "goforward.15", 15, round: 19, action: #selector(pressedForward))

            line.alphaValue = 0
            addSubview(line)
            buttons.forEach { $0.alphaValue = 0 }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        private var buttons: [NSButton] { [close, back, minimize, rewind, pause, forward] }

        override var pressable: [NSButton] { near ? buttons : [] }

        var offered: [String] {
            let names = [(close, "close"), (back, "return"), (minimize, "mini player"),
                         (rewind, "rewind"), (pause, "play/pause"), (forward, "forward")]
            return names.filter { !$0.0.isHidden }.map(\.1)
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scrim.frame = bounds
            CATransaction.commit()

            close.frame = NSRect(x: 14, y: bounds.height - 44, width: 30, height: 30)
            back.frame = NSRect(x: bounds.width - 44, y: bounds.height - 44, width: 30, height: 30)
            minimize.frame = back.frame.offsetBy(dx: -(back.frame.width + Metrics.mediaGap), dy: 0)

            let middle = bounds.midY - 25
            pause.frame = NSRect(x: bounds.midX - 25, y: middle, width: 50, height: 50)
            rewind.frame = NSRect(x: bounds.midX - 25 - 54, y: middle + 6, width: 38, height: 38)
            forward.frame = NSRect(x: bounds.midX + 25 + 16, y: middle + 6, width: 38, height: 38)

            line.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 3)
        }

        override func mouseEntered(with event: NSEvent) { fade(to: 1) }
        override func mouseExited(with event: NSEvent) { fade(to: 0) }

        private func fade(to value: CGFloat) {
            near = value > 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                buttons.forEach { $0.animator().alphaValue = value }
                line.animator().alphaValue = value
            }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.16)
            scrim.opacity = Swift.Float(value)
            CATransaction.commit()
        }

        @objc private func pressedClose() { onClose?() }
        @objc private func pressedReturn() { onReturn?() }
        @objc private func pressedMinimize() { onMinimize?() }
        @objc private func pressedRewind() { onSkip?(-15) }
        @objc private func pressedForward() { onSkip?(15) }
        @objc private func pressedPause() {
            playing.toggle()
            onPlayPause?()
        }

        /// How far through, along the bottom edge. Quiet enough to ignore.
        final class Line: NSView {
            var through: Double = 0 {
                didSet { needsDisplay = true }
            }

            override func draw(_ dirty: NSRect) {
                Palette.Film.track.setFill()
                bounds.fill()
                Palette.Film.progress.setFill()
                NSRect(x: 0, y: 0, width: bounds.width * through, height: bounds.height).fill()
            }

            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
    }
}

/// The surface over a floating window's page, which takes every gesture: a
/// drag moves the window, the bottom right corner sizes it, two fingers move
/// it and a pinch sizes it. Only the buttons a subclass names answer clicks.
///
/// isMovableByWindowBackground never worked here: the window's whole
/// background is a web view, and a web view swallows every drag before the
/// window sees it. So every gesture is taken here, above it.
class Grip: NSView {
    /// The buttons that answer a click at this moment.
    var pressable: [NSButton] { [] }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let inside = convert(point, from: superview)
        for button in pressable where !button.isHidden && button.frame.contains(inside) {
            return button
        }
        return self
    }

    /// A round button in the film's colours, added to this surface.
    func dress(_ button: NSButton, _ symbol: String, _ size: CGFloat, round: CGFloat, action: Selector) {
        button.image = Grip.glyph(symbol, size)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.wantsLayer = true
        button.layer?.backgroundColor = Palette.Film.button.cgColor
        button.layer?.cornerRadius = round
        // The same fine edge as Escale's glass elsewhere, so the buttons
        // hold on a dark frame of film as well as on a bright one.
        button.layer?.borderWidth = 1
        button.layer?.borderColor = Palette.Film.edge.cgColor
        addSubview(button)
    }

    static func glyph(_ name: String, _ size: CGFloat, ink: NSColor = Palette.Film.ink) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        let look = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(.init(paletteColors: [ink]))
        return image?.withSymbolConfiguration(look)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
        )
    }

    // MARK: - moving and sizing

    private var grab = NSPoint.zero
    private var origin = NSRect.zero
    private var stretching = false

    private func atCorner(_ point: NSPoint) -> Bool {
        point.x > bounds.maxX - 22 && point.y < bounds.minY + 22
    }

    override func resetCursorRects() {
        addCursorRect(
            NSRect(x: bounds.maxX - 22, y: bounds.minY, width: 22, height: 22),
            cursor: .crosshair
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        grab = NSEvent.mouseLocation
        origin = window.frame
        stretching = atCorner(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - grab.x
        let dy = now.y - grab.y

        guard stretching else {
            window.setFrameOrigin(NSPoint(x: origin.minX + dx, y: origin.minY + dy))
            return
        }
        // A window without a shape of its own (a meeting's) follows the corner
        // both ways; the top edge stays where it was.
        guard window.aspectRatio == .zero else {
            resize(to: origin.width + dx, from: origin)
            return
        }
        let limit = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1600, height: 1000)
        window.setFrame(Grip.stretched(origin, by: NSPoint(x: dx, y: dy), smallest: window.minSize, limit: limit),
                        display: false)
    }

    /// Where the bottom right corner of `was`, dragged by `delta` in screen
    /// coordinates (up is positive), leaves a window of any shape: no smaller
    /// than `smallest`, no larger than most of `limit`, its top left kept.
    static func stretched(_ was: NSRect, by delta: NSPoint, smallest: NSSize, limit: NSSize) -> NSRect {
        let wide = min(max(smallest.width, was.width + delta.x), limit.width * 0.85)
        let tall = min(max(smallest.height, was.height - delta.y), limit.height * 0.85)
        return NSRect(x: was.minX, y: was.maxY - tall, width: wide, height: tall)
    }

    /// Two fingers on the trackpad move the window. There is nothing to
    /// scroll here — the window holds one picture — so the gesture is free
    /// to mean the thing you actually want it to mean.
    ///
    /// And the pointer travels with it. Moving the window alone leaves the
    /// cursor behind: it drifts towards the edge, falls out, and the window
    /// stops answering mid-gesture. Carrying it keeps it at the same place
    /// in the frame, so the window can be pushed as far as the screen goes.
    override func scrollWheel(with event: NSEvent) {
        guard let window else { return }
        // Only while fingers are actually down. Letting the glide continue
        // would fling the pointer across the screen after them.
        guard event.momentumPhase == [] else { return }

        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        guard dx != 0 || dy != 0 else { return }

        let spot = window.frame.origin
        window.setFrameOrigin(NSPoint(x: spot.x + dx, y: spot.y - dy))

        // Screen coordinates run up from the bottom, the cursor's run down
        // from the top of the first display.
        guard let ground = NSScreen.screens.first else { return }
        let mouse = NSEvent.mouseLocation
        CGWarpMouseCursorPosition(
            CGPoint(
                x: mouse.x + dx,
                y: ground.frame.height - (mouse.y - dy)
            )
        )
        // Without this the pointer and the physical trackpad stay parted
        // for a moment, and the next flick arrives from the wrong place.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// A pinch sizes it about the pointer: whatever is under your fingers
    /// stays under your fingers, and the rest grows away from it. Sizing
    /// about the centre instead makes the picture slide sideways under a
    /// hand that never moved, which is what felt wrong.
    private var pinching: CGFloat = 0

    override func magnify(with event: NSEvent) {
        guard let window else { return }
        if event.phase == .began { pinching = 0 }
        pinching += event.magnification

        // Every event would mean a window resize, a web view relayout and a
        // video re-fit sixty times a second, which is the stutter. Moving
        // in steps of a fiftieth is below what an eye reads as a jump and
        // an order of magnitude less work.
        guard abs(pinching) > 0.02 else { return }
        let by = pinching
        pinching = 0
        resize(
            to: window.frame.width * (1 + by),
            from: window.frame,
            around: NSEvent.mouseLocation
        )
    }

    private func resize(to width: CGFloat, from was: NSRect, around anchor: NSPoint? = nil) {
        guard let window, was.width > 0 else { return }
        let limit = NSScreen.main?.visibleFrame.width ?? 1600
        // Keeps the shape: a video window that can be squashed is a video
        // window showing bars. A pinch keeps a meeting's shape too; its corner
        // does not (see mouseDragged).
        let wide = min(max(window.minSize.width, width), limit * 0.85)
        let tall = wide * was.height / was.width

        let spot: NSPoint
        if let anchor {
            // Where the pointer sits within the window, as a fraction, kept
            // at the same fraction of the new one.
            let across = (anchor.x - was.minX) / was.width
            let up = (anchor.y - was.minY) / was.height
            spot = NSPoint(x: anchor.x - across * wide, y: anchor.y - up * tall)
        } else {
            spot = NSPoint(x: was.minX, y: was.maxY - tall)
        }
        // Not display: true — asking for an immediate redraw on every step
        // is what makes a live resize stutter. The next frame is soon
        // enough.
        window.setFrame(
            NSRect(x: spot.x, y: spot.y, width: wide, height: tall),
            display: false
        )
    }
}

/// Sites with a player worth following into the little window.
///
/// Anywhere else, a playing video is as likely to be a background as a film,
/// and the difference isn't something a script can tell from the outside. So
/// the list is of places people go to watch, and the shortcut covers the rest.
enum Players {
    /// A host suffix, and for a few shops that also stream, the path that
    /// separates the film from the product page.
    private static let known: [(host: String, path: String?)] = [
        ("youtube.com", nil), ("youtu.be", nil), ("netflix.com", nil),
        ("primevideo.com", nil), ("amazon.com", "/gp/video"), ("amazon.fr", "/gp/video"),
        ("amazon.co.uk", "/gp/video"), ("amazon.de", "/gp/video"),
        ("disneyplus.com", nil), ("tv.apple.com", nil), ("twitch.tv", nil),
        ("vimeo.com", nil), ("dailymotion.com", nil), ("max.com", nil), ("hbomax.com", nil),
        ("canalplus.com", nil), ("mycanal.fr", nil), ("arte.tv", nil), ("france.tv", nil),
        ("tf1.fr", nil), ("6play.fr", nil), ("crunchyroll.com", nil), ("plex.tv", nil),
        ("peacocktv.com", nil), ("hulu.com", nil), ("paramountplus.com", nil),
        ("molotov.tv", nil), ("ocs.fr", nil), ("mubi.com", nil), ("criterionchannel.com", nil),
        ("ted.com", nil), ("nebula.tv", nil), ("curiositystream.com", nil),
    ]

    /// A meeting, whose pictures are people rather than a film: it has its own
    /// window (Meeting.swift), with none of a video's controls.
    static func isCall(_ url: URL?) -> Bool {
        guard let url, let host = url.host()?.lowercased(), host == "meet.google.com" else { return false }
        // The landing page has no meeting; a meeting's code is its path.
        let path = url.path().lowercased()
        return path.count > 1 && path != "/landing"
    }

    static func knows(_ url: URL?) -> Bool {
        if isCall(url) { return true }
        guard let url, let host = url.host()?.lowercased() else { return false }
        let path = url.path().lowercased()
        return known.contains { entry in
            guard host == entry.host || host.hasSuffix("." + entry.host) else { return false }
            guard let needle = entry.path else { return true }
            return path.hasPrefix(needle)
        }
    }
}

/// A panel that takes key status without bringing the whole app forward.
///
/// Borderless windows refuse to become key by default, and a window that never
/// becomes key is a window the system stops routing gestures to.
private final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum Isolate {
    /// Everything but the video, out of the way. Visibility is inherited, so
    /// hiding the body and turning it back on for the video alone leaves the
    /// player's own machinery running untouched — which is what keeps the
    /// stream alive where cutting the DOM about would kill it.
    private static let isolatePage = Bundled.script("isolate-on.js")
    static let on = Bundled.configured(isolatePage, with: ["media": false])
    static let media = Bundled.configured(isolatePage, with: ["media": true])

    /// Stop or start it, and say which it is now.
    /// Step over the bit you missed, or back to it.
    // (see Page/Scripts/isolate-skip.js)
    private static let skipPage = Bundled.script("isolate-skip.js")
    static func skip(_ seconds: Double) -> String {
        Bundled.configured(skipPage, with: ["seconds": seconds])
    }

    /// How far through, and whether it is running.
    static let where_ = Bundled.script("isolate-where.js")

    static let toggle = Bundled.script("isolate-toggle.js")

    static let off = Bundled.script("isolate-off.js")
}

extension Tab {
    /// Whether its page has something to put in the floating window: a video,
    /// or a meeting, whose people are its pictures. The mini player's button
    /// and the lifting share this, so no site has a way of its own.
    var liftable: Bool { media.state?.video == true || Players.isCall(address) }
}
