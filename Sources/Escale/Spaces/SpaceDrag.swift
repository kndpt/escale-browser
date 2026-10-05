// Switching Spaces replaces the row that began a SwiftUI drag. AppKit can then
// finish the mouse gesture without sending that row its onEnded callback. Keep
// one release observer at the stable sidebar level while a row is held, so the
// drop and visual cleanup survive the change. It is removed on release, focus
// loss or when the sidebar leaves the window; idle chrome has no observer.
import AppKit
import SwiftUI

@MainActor
final class SpaceDrag: ObservableObject {
    struct Carried {
        let origin: UUID
        let title: String
        let symbol: String
        var point: CGPoint
    }

    @Published private(set) var carried: Carried?
    /// Bench checks that a release reached this stable observer after a view swap.
    private(set) static var releasedByMonitor = false
    private var source: UUID?
    private var release: ((CGPoint) -> Void)?
    private var abort: (() -> Void)?
    private var move: ((CGPoint) -> Void)?
    private var mouseUp: Any?
    private var mouseMoved: Any?
    private var resigned: NSObjectProtocol?

    func begin(_ source: UUID, origin: UUID, title: String, symbol: String, at point: CGPoint,
               move: @escaping (CGPoint) -> Void, release: @escaping (CGPoint) -> Void,
               abort: @escaping () -> Void) {
        if self.source != source { cancel() }
        if self.source == nil {
            Self.releasedByMonitor = false
            carried = Carried(origin: origin, title: title, symbol: symbol, point: point)
        } else {
            carried?.point = point
        }
        self.source = source
        self.release = release
        self.abort = abort
        self.move = move
        guard mouseUp == nil else { return }
        mouseMoved = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            guard let self, self.source != nil, let window = Links.window,
                  event.windowNumber == window.windowNumber else { return event }
            let point = CGPoint(x: event.locationInWindow.x,
                                y: window.frame.height - event.locationInWindow.y)
            self.carried?.point = point
            self.move?(point)
            return event
        }
        mouseUp = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self, self.source != nil else { return event }
            if let window = Links.window, event.windowNumber == window.windowNumber {
                Self.releasedByMonitor = true
                self.end(at: CGPoint(x: event.locationInWindow.x,
                                     y: window.frame.height - event.locationInWindow.y))
            } else {
                self.cancel()
            }
            return event
        }
        resigned = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }
    }

    func end(at point: CGPoint) {
        guard let release else { return }
        clear()
        release(point)
    }

    func cancel() {
        guard let abort else { return }
        clear()
        abort()
    }

    private func clear() {
        source = nil
        release = nil
        abort = nil
        move = nil
        carried = nil
        if let mouseUp { NSEvent.removeMonitor(mouseUp) }
        mouseUp = nil
        if let mouseMoved { NSEvent.removeMonitor(mouseMoved) }
        mouseMoved = nil
        if let resigned { NotificationCenter.default.removeObserver(resigned) }
        resigned = nil
    }

    deinit {
        if let mouseUp { NSEvent.removeMonitor(mouseUp) }
        if let mouseMoved { NSEvent.removeMonitor(mouseMoved) }
        if let resigned { NotificationCenter.default.removeObserver(resigned) }
    }
}

/// The source row is no longer in the destination's tab tree. Its small
/// carried face stays with the pointer until the stable observer ends the drag.
struct SpaceDragFace: View {
    let carried: SpaceDrag.Carried
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.length(8)) {
            Image(systemName: carried.symbol)
                .font(.system(size: metrics.length(12)))
            Text(carried.title)
                .font(.system(size: metrics.length(12.5)))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, metrics.length(10))
        .frame(height: metrics.length(28))
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: metrics.length(9)))
        .overlay {
            RoundedRectangle(cornerRadius: metrics.length(9))
                .strokeBorder(Palette.edge, lineWidth: 1)
        }
        .shadow(color: Palette.shadow, radius: 12, y: 4)
    }
}
