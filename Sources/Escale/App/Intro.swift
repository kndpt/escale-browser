// The first launch opens on Welcome in a window of its own, and the browser
// arrives only once Welcome is done. Each change is a relay between windows:
// a borderless overlay above everything draws the motion, and on its last
// frame the real window is put at exactly the overlay card's frame, corner
// and ground, and the card fades off it. The eye follows one surface.
//
// The opening is a moment of its own, once: the screen dims a little, a tile
// rises and stands up while the mark draws itself on it, dot by dot to the
// next stop (Landing), then the tile opens into Welcome and the screen
// lights up again. At the end, Welcome grows into the browser.
//
// A real window, not the overlay, holds Welcome because it has to take the
// keyboard, move and stay behind other apps like any window. The overlay
// ignores the pointer and lives only for the length of a flight. Nothing here
// runs again after the first arrival, and both windows are let go; the
// object itself is a few empty references for the rest of the run.
import AppKit
import Combine
import SwiftUI

@MainActor
final class Intro {
    static let shared = Intro()

    private var played = false
    private var overlay: NSWindow?
    private var welcome: NSWindow?
    private weak var browserWindow: NSWindow?
    private var ending: AnyCancellable?

    /// Takes over the browser's first window on a first arrival only, and
    /// keeps it unseen until Welcome is done.
    func begin(_ browser: Browser, window: NSWindow) {
        // The bench drives the browser's own window from its first frame.
        guard !played, browser.welcoming, !browser.prefs.welcomed, !browser.prefs.bench,
              let screen = window.screen ?? NSScreen.main else { return }
        played = true
        browserWindow = window
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        // Welcome ends however it ends: its last button, or stepping aside.
        ending = browser.$welcoming.dropFirst().filter { !$0 }.first()
            .receive(on: RunLoop.main)
            .sink { _ in self.finish(browser) }
        // The window is still being put together; the flight waits a turn.
        DispatchQueue.main.async { self.depart(browser, on: screen) }
    }

    private func depart(_ browser: Browser, on screen: NSScreen) {
        guard ending != nil else { return }
        let area = screen.visibleFrame
        let size = Metrics.introSize
        let target = NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                            width: size.width, height: size.height).integral
        let tile = NSRect(x: area.midX - Metrics.introTile / 2, y: area.midY - Metrics.introTile / 2,
                          width: Metrics.introTile, height: Metrics.introTile)
        if still { return open(browser, at: target) }
        let flight = Flight(frame: tile.offsetBy(dx: 0, dy: -Metrics.introRise), corner: Metrics.introTileCorner, on: screen)
        flight.marked = true
        flight.scale = Metrics.introSeed
        flight.tilt = Metrics.introTilt
        fly(flight, depth: browser.prefs.depth) {
            withAnimation(Motion.landing) { flight.drawn = 1 }
            flight.arrive(Motion.introPop) {
                flight.frame = tile
                flight.scale = 1
                flight.tilt = 0
                flight.shown = 1
                flight.scrim = 1
            } then: {
                DispatchQueue.main.asyncAfter(deadline: .now() + Motion.introHold) {
                    guard self.ending != nil else { return }
                    flight.arrive(Motion.introGrow) {
                        flight.frame = target
                        flight.corner = Metrics.introCorner
                        flight.mark = 0
                        flight.markScale = Metrics.introMarkExit
                    } then: {
                        self.open(browser, at: target)
                    }
                }
            }
        }
    }

    /// Reduce Motion: the windows change places without flying.
    private var still: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: - the relay

    /// Shows the overlay for one flight, then starts it.
    private func fly(_ flight: Flight, depth: Depth, start: () -> Void) {
        let window = NSWindow(contentRect: flight.screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.animationBehavior = .none
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: FlightView(flight: flight).environment(\.depth, depth))
        host.sizingOptions = []
        window.contentView = host
        window.orderFrontRegardless()
        window.displayIfNeeded()
        overlay = window
        start()
    }

    /// The card has landed on the window it stood for: it fades off it, and
    /// the overlay goes.
    private func land() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.introHand
            overlay?.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.introHand) {
            self.overlay?.orderOut(nil)
            self.overlay = nil
        }
    }

    private func open(_ browser: Browser, at frame: NSRect) {
        // Welcome may have ended while its tile was flying (Settings, ⌘,).
        guard ending != nil else { return }
        let window = Sheet(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // AppKit would grow a new window in from a little smaller; this one
        // has to start exactly where the card stopped.
        window.animationBehavior = .none
        let host = NSHostingView(rootView: WelcomePanel(browser: browser, prefs: browser.prefs)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.introCorner, style: .continuous))
            .environment(\.depth, browser.prefs.depth)
            .environment(\.chromeMetrics, ChromeMetrics(size: browser.prefs.interfaceSize)))
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        welcome = window
        land()
    }

    private func finish(_ browser: Browser) {
        ending = nil
        guard let browserWindow else { return }
        // Ended before Welcome had a window: none opens, the browser comes.
        guard let welcome else { return reveal(browserWindow) }
        self.welcome = nil
        guard !still, let screen = welcome.screen ?? NSScreen.main else {
            welcome.orderOut(nil)
            return reveal(browserWindow)
        }
        let flight = Flight(frame: welcome.frame, corner: Metrics.introCorner, on: screen)
        flight.shown = 1
        fly(flight, depth: browser.prefs.depth) {
            welcome.orderOut(nil)
            flight.arrive(Motion.introGrow) { flight.frame = browserWindow.frame } then: {
                self.reveal(browserWindow)
            }
        }
    }

    /// The browser fades in under the card.
    private func reveal(_ window: NSWindow) {
        window.ignoresMouseEvents = false
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.introHand
            window.animator().alphaValue = 1
        }
        land()
    }
}

/// Hands the browser's window to Intro as soon as it has one, before it is
/// first drawn. WindowSetup answers a turn later, after a frame has shown.
struct IntroVeil: NSViewRepresentable {
    let browser: Browser

    func makeNSView(context: Context) -> NSView { Probe(browser: browser) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Probe: NSView {
        let browser: Browser

        init(browser: Browser) {
            self.browser = browser
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { Intro.shared.begin(browser, window: window) }
        }
    }
}

/// A borderless window still takes the keyboard: Welcome has fields and a
/// default button.
private final class Sheet: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The card in flight, in screen coordinates; the view turns them into the
/// overlay's own, which start at the top.
@MainActor
private final class Flight: ObservableObject {
    let screen: NSScreen
    @Published var frame: NSRect
    @Published var corner: CGFloat
    @Published var shown: Double = 0
    @Published var scale: CGFloat = 1
    /// Degrees the card is tipped back, top away.
    @Published var tilt: Double = 0
    /// How dim the screen around the card is.
    @Published var scrim: Double = 0
    /// Whether the card carries the mark, how much of it is drawn, how much
    /// shows and at what size.
    var marked = false
    @Published var drawn: CGFloat = 0
    @Published var mark: Double = 1
    @Published var markScale: CGFloat = 1

    init(frame: NSRect, corner: CGFloat, on screen: NSScreen) {
        self.frame = frame
        self.corner = corner
        self.screen = screen
    }

    /// One leg; `then` runs once the card has stopped, not when the curve
    /// is merely close.
    func arrive(_ animation: Animation, _ change: () -> Void, then: @escaping () -> Void) {
        withAnimation(animation, completionCriteria: .removed, change) { then() }
    }
}

private struct FlightView: View {
    @ObservedObject var flight: Flight

    var body: some View {
        let screen = flight.screen.frame
        let shape = RoundedRectangle(cornerRadius: flight.corner, style: .continuous)
        Palette.scrim.opacity(flight.scrim).overlay(alignment: .topLeading) {
            ZStack {
                Envelope()
                if flight.marked {
                    Landing(progress: flight.drawn)
                        .fill(Palette.ink, style: FillStyle(eoFill: true))
                        .aspectRatio(Logomark.canvas.width / Logomark.canvas.height, contentMode: .fit)
                        .frame(width: Metrics.introMark)
                        .scaleEffect(flight.markScale)
                        .opacity(flight.mark)
                }
            }
            .frame(width: flight.frame.width, height: flight.frame.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Palette.edge, lineWidth: 0.5))
            .shadow(color: Palette.shadow, radius: 24, y: 12)
            .rotation3DEffect(.degrees(flight.tilt), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.6)
            .scaleEffect(flight.scale)
            .opacity(flight.shown)
            .offset(x: flight.frame.minX - screen.minX, y: screen.maxY - flight.frame.maxY)
        }
        .ignoresSafeArea()
    }
}
