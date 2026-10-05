import SwiftUI

// The column of tabs, folded away with ⌘S or its door.
//
// The column is two hundred and some points the page never gets back, even
// while all you do is read. Folded, the page takes the whole window but the
// rail: the rail says where you are, and the column's door (FoldDoor) — on
// the column's title line while it is out, at the head of the line over the
// page once it is folded — brings the tabs back, as ⌘S does.
//
// The column does not come out when the pointer pushes against the window's
// edge. With the rail there, that edge is the rail's, and a column springing
// out of the page beside it on a passing hand reads as a glitch rather than a
// gesture. A door and a shortcut are the whole of it: nothing watches the
// pointer for the column.
//
// In sidebar mode the traffic lights remain in the global title bar while the
// rail stays visible. In top-strip mode they still travel with the strip, so a
// folded page does not leave native controls floating over page content.
//
// Folding lasts the session. A browser opening with no tabs anywhere on
// screen, for a reason set days ago, reads as a broken one — unless that is
// the reason: Settings can keep the column folded, and then the fold is where
// it rests, at launch and after every change of layout.
//
// The strip across the top folds up out of the window, the page taking the
// full height, and comes back down over the page when the pointer rests
// against the top edge. There the edge is crossed on every trip to the menu
// bar just above, so the strip waits for the pointer to settle, and goes back
// a short grace after the pointer leaves it, so a hand that overshoots on the
// way back in doesn't lose it. While a tab's address is being typed into it,
// the strip stays out.

extension Browser {
    /// ⌘S. The column, or the strip across the top, out of the way, or back.
    func toggleFold() {
        peeking = false
        withAnimation(prefs.sidebar ? Motion.fade : Motion.glide) { folded.toggle() }
    }

    /// The folded strip out over the page, or back up.
    func peek(_ out: Bool) {
        withAnimation(Motion.glide) { peeking = out }
    }
}

/// ⌘S as a door, drawn as the column it stands for: on the column's title line
/// while the column is out, at the head of the line over the page once it is
/// folded (see Side.swift and Bar.swift).
struct FoldDoor: View {
    let browser: Browser
    let folded: Bool

    var body: some View {
        Door(icon: "sidebar.left", help: browser.prefs.keyHelp(.fold, folded ? "Show Sidebar" : "Hide Sidebar")) {
            browser.toggleFold()
        }
        .accessibilityLabel(folded ? "Show Sidebar" : "Hide Sidebar")
    }
}

/// Over the window: the title band along the top of the page in the column's
/// mode, and, while the strip is folded, the strip itself when the pointer
/// brings it down from the window's top edge.
struct Fold: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    /// The strip going back up, a moment after the pointer left it.
    @State private var leaving: DispatchWorkItem?
    /// The strip coming down, once the pointer has settled on the edge.
    @State private var arriving: DispatchWorkItem?
    /// The pointer is over the strip.
    @State private var inside = false
    @State private var pointer = Pointer()

    /// How near the edge the pointer has to be.
    private static let edge: CGFloat = 6
    /// The grace before the strip goes back up.
    private static let grace: TimeInterval = 0.3
    /// The band along the top that is the title bar over the page.
    private static let top: CGFloat = 8
    /// How long the pointer rests on the edge before the strip comes down.
    /// Long enough to cross it on the way to the menu bar, short enough not
    /// to be waited for.
    private static let dwell: TimeInterval = 0.15

    var body: some View {
        ZStack(alignment: .topLeading) {
            // In the column's mode the page reaches the window's top edge —
            // beside the column, and everywhere once it is folded away — and
            // there was nowhere there to drag the window from, or to
            // double-click to fill the screen: only the column's own corner,
            // gone when folded. A band too thin to be in a page's way stands
            // in for the title bar along the whole top; the column lies over
            // it with its own.
            if prefs.sidebar, browser.active?.immersed != true {
                DragStrip()
                    .frame(height: Fold.top)
                    .frame(maxWidth: .infinity)
            }
            if folding, browser.peeking {
                // Over the page, so glass of its own rather than the
                // envelope's (Glass.swift).
                TabBar(browser: browser)
                    .frame(height: metrics.strip)
                    .glass(.panel, in: Rectangle())
                    .transition(.move(edge: .top))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .onAppear {
            hideLights()
            watch()
        }
        .onDisappear { pointer.stop() }
        // A column folded for good is folded before there is a window to
        // hide the lights of; they go once there is one.
        .background(WindowSetup { window in
            window.standardWindowButton(.closeButton)?.superview?.isHidden = lightsOff
            pointer.window = window
            watch()
        })
        .onChange(of: lightsOff) { _, _ in hideLights() }
        .onChange(of: folding) { _, _ in watch() }
        // Back to the strip and then to the column again: the column comes
        // back as it rests — whole, not folded from a time nobody remembers,
        // unless Settings says it rests folded.
        .onChange(of: prefs.sidebar) { _, _ in
            browser.folded = prefs.sidebar && prefs.sideHides
            browser.peeking = false
        }
        .onChange(of: prefs.sideHides) { _, hides in
            guard prefs.sidebar else { return }
            withAnimation(Motion.fade) { browser.folded = hides }
        }
        .onChange(of: prefs.interfaceSize) { _, _ in hideLights() }
        // The address typed into a tab is done with, and the pointer went
        // elsewhere while it was: the strip goes the way it would have.
        .onChange(of: browser.editingTab) { _, editing in
            if editing == nil, !inside, browser.peeking { peek(false) }
        }
    }

    /// The strip folded, and not taken over by a page filling the screen:
    /// the only fold the pointer brings out.
    private var folding: Bool {
        !prefs.sidebar && browser.folded && browser.active?.immersed != true
    }

    private var lightsOff: Bool {
        !prefs.sidebar && browser.folded && !browser.peeking
    }

    /// The pointer is watched only while there is something folded for it
    /// to bring out; the rest of the time no move of it costs anything.
    private func watch() {
        if folding {
            pointer.start { follow() }
        } else {
            pointer.stop()
        }
    }

    /// Brings the strip down or sends it back from the pointer's actual
    /// position, on every move. Hover events weren't enough: a view that
    /// appears under a still pointer never gets "entered", so it never gets
    /// "exited" either, and after a few quick opens and closes the strip
    /// stayed out, or the edge stopped bringing it.
    private func follow() {
        guard folding, let window = pointer.window, window.isVisible else { return pass() }
        let screen = NSEvent.mouseLocation
        let point = window.convertPoint(fromScreen: screen)
        let size = window.frame.size
        let inWindow = point.x >= 0 && point.x < size.width && point.y >= 0 && point.y < size.height
        let distance = size.height - point.y
        if browser.peeking {
            pass()
            // Only this window counts, not another app's window over it. One
            // of this app's own windows, such as a popover opened from the
            // strip, counts as the strip.
            let top = NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0)
            let onWindow = top == window.windowNumber
            let onOwnPanel = !onWindow && NSApp.windows.contains { $0.windowNumber == top }
            let over = onOwnPanel || (onWindow && inWindow && distance < metrics.strip)
            if over != inside { inside = over }
            peek(over)
        } else if inWindow, distance < Fold.edge {
            // Which window is under the pointer is asked only here, at the
            // edge: another app's window over it doesn't bring the strip down.
            guard NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0) == window.windowNumber
            else { return pass() }
            if arriving == nil { arrive() }
        } else {
            pass()
        }
    }

    /// The pointer on the edge: the strip comes once it has rested there.
    private func arrive() {
        pass()
        let coming = DispatchWorkItem {
            arriving = nil
            peek(true)
        }
        arriving = coming
        DispatchQueue.main.asyncAfter(deadline: .now() + Fold.dwell, execute: coming)
    }

    /// The pointer crossed the edge without stopping.
    private func pass() {
        guard let arriving else { return }
        arriving.cancel()
        self.arriving = nil
    }

    /// Out at once; in only once the pointer has stayed away for the grace,
    /// counted from when it left rather than from its latest move.
    private func peek(_ out: Bool) {
        if out {
            if let leaving {
                leaving.cancel()
                self.leaving = nil
            }
            guard !browser.peeking else { return }
            browser.peek(true)
        } else {
            guard leaving == nil else { return }
            let going = DispatchWorkItem {
                leaving = nil
                guard browser.editingTab == nil else { return }
                browser.peek(false)
            }
            leaving = going
            DispatchQueue.main.asyncAfter(deadline: .now() + Fold.grace, execute: going)
        }
    }

    /// The title bar's own view holds the three buttons, so hiding it hides
    /// them, and hidden buttons take no clicks.
    private func hideLights() {
        guard let bar = Fold.titlebar else { return }
        if prefs.sidebar {
            // The rail/column never owns the native title bar. Keeping the
            // translation at zero also resets it when switching from strip
            // mode after a folded strip.
            Fold.slide(bar, off: false, by: 0)
        } else {
            Fold.slide(bar, off: lightsOff, by: metrics.strip, up: true)
        }
    }

    private var metrics: ChromeMetrics { ChromeMetrics(size: prefs.interfaceSize) }

    static var titlebar: NSView? {
        Links.window?.standardWindowButton(.closeButton)?.superview
    }

    /// Bumped by every slide, so one that was overtaken doesn't hide the
    /// lights on its way out.
    private static var slides = 0

    /// The lights ride with the column, as everything else in its corner
    /// does. Shown or hidden at once, they stood in their place while the
    /// column was still sliding in under them, and vanished before it had
    /// gone. So they come in from the left edge and go back off it, on the
    /// column's own spring (Motion.glide, in Core Animation's terms) — from
    /// wherever they are, when the pointer turns back halfway. `up`: off the
    /// top edge with the strip rather than off the left edge with the column.
    static func slide(_ bar: NSView, off: Bool, by width: CGFloat, up: Bool = false) {
        slides += 1
        let turn = slides
        guard let layer = bar.layer else {
            bar.isHidden = off
            return
        }
        // Up is +y in a superview that isn't flipped, -y in one that is.
        let path = up ? "transform.translation.y" : "transform.translation.x"
        let gone: CGFloat = up ? ((bar.superview?.isFlipped ?? false) ? -width : width) : -width
        let other = up ? "transform.translation.x" : "transform.translation.y"
        let moving = layer.animation(forKey: "fold") != nil
        // A slide still running on the other axis — the layout was switched
        // halfway — is simply let go.
        if moving, (layer.animation(forKey: "fold") as? CABasicAnimation)?.keyPath == other {
            layer.removeAnimation(forKey: "fold")
        }
        let still = layer.animation(forKey: "fold") != nil
        let from = still
            ? (layer.presentation()?.value(forKeyPath: path) as? CGFloat ?? 0)
            : (bar.isHidden ? gone : 0)
        let to: CGFloat = off ? gone : 0
        guard from != to else {
            layer.removeAnimation(forKey: "fold")
            bar.isHidden = off
            return
        }
        let spring = CASpringAnimation(keyPath: path)
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / 0.34, 2)
        spring.damping = 4 * .pi * 0.82 / 0.34
        spring.fromValue = from
        spring.toValue = to
        spring.duration = spring.settlingDuration
        spring.fillMode = .forwards
        spring.isRemovedOnCompletion = false
        bar.isHidden = false
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                guard turn == slides else { return }
                layer.removeAnimation(forKey: "fold")
                bar.isHidden = off
            }
        }
        layer.add(spring, forKey: "fold")
        CATransaction.commit()
    }
}

/// The pointer's moves, wherever it goes, while something is folded: over
/// this app's windows, and over everything else while another app is in
/// front, since the edge is still the edge with Escale behind.
@MainActor
private final class Pointer {
    weak var window: NSWindow?
    private var local: Any?
    private var global: Any?
    /// The window's own say on mouse-moved events, given back when the
    /// watch ends.
    private var accepted = false

    func start(_ moved: @escaping @MainActor () -> Void) {
        guard local == nil, let window else { return }
        // The pointer's moves reach the monitor wherever it is over the
        // window, not only over what tracks it — for as long as the watch
        // lasts, and no longer.
        accepted = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true
        local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            MainActor.assumeIsolated { moved() }
            return event
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { _ in
            MainActor.assumeIsolated { moved() }
        }
    }

    func stop() {
        guard local != nil || global != nil else { return }
        if let local { NSEvent.removeMonitor(local) }
        if let global { NSEvent.removeMonitor(global) }
        local = nil
        global = nil
        window?.acceptsMouseMovedEvents = accepted
    }
}
