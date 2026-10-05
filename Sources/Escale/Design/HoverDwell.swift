import Foundation

// A deliberate drag target uses one short clock, whether it is another
// bookmark or a Space door. The target pulses at 480 ms and becomes ready at
// 720 ms. Changing targets, releasing, or removing the owning view cancels
// both callbacks, so ordinary passes do not act and idle chrome has no timer.
@MainActor
final class HoverDwell: ObservableObject {
    @Published private(set) var source: UUID?
    @Published private(set) var target: UUID?
    @Published private(set) var pulsing = false
    @Published private(set) var ready = false

    private var pulseWork: DispatchWorkItem?
    private var readyWork: DispatchWorkItem?

    func aim(source: UUID, at target: UUID?, onReady: (() -> Void)? = nil) {
        guard self.source != source || self.target != target else { return }
        cancel()
        guard let target, source != target else { return }
        self.source = source
        self.target = target
        let pulse = DispatchWorkItem { [weak self] in
            guard let self, self.source == source, self.target == target else { return }
            self.pulsing = true
        }
        let ready = DispatchWorkItem { [weak self] in
            guard let self, self.source == source, self.target == target else { return }
            self.pulsing = false
            self.ready = true
            onReady?()
        }
        pulseWork = pulse
        readyWork = ready
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.bookmarkPending, execute: pulse)
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.bookmarkReady, execute: ready)
    }

    func accepts(source: UUID, target: UUID) -> Bool {
        ready && self.source == source && self.target == target
    }

    func cancel() {
        pulseWork?.cancel()
        readyWork?.cancel()
        pulseWork = nil
        readyWork = nil
        source = nil
        target = nil
        pulsing = false
        ready = false
    }

    deinit {
        pulseWork?.cancel()
        readyWork?.cancel()
    }
}
