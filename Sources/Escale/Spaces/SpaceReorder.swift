// A Space's icon carried along the rail to another place. The list of Spaces
// does not change until the drop: the held icon follows the hand and the
// others only shift on screen to show where it will land. So Escape, or a
// release beyond the rail, simply forgets the hold and nothing is written.
// Escape reaches it through App's key monitor (current), as the tab drags'
// does through Panels; an idle rail installs nothing.
import SwiftUI

@MainActor
final class SpaceReorder: ObservableObject {
    static weak var current: SpaceReorder?

    @Published private(set) var held: UUID?
    @Published private(set) var travel: CGFloat = 0
    /// Escape ended the hold while the button is still down.
    private var dropped = false

    func carry(_ id: UUID, travel: CGFloat) {
        guard !dropped else { return }
        held = id
        self.travel = travel
        Self.current = self
    }

    /// The hand let go: how far the icon travelled, or nil if Escape came first.
    func end() -> CGFloat? {
        defer { dropped = false; forget() }
        return dropped ? nil : held.map { _ in travel }
    }

    /// Escape: true if there was a hold to cancel.
    func cancel() -> Bool {
        guard held != nil else { return false }
        dropped = true
        forget()
        return true
    }

    private func forget() {
        held = nil
        travel = 0
        if Self.current === self { Self.current = nil }
    }

    /// The place an icon lands after travelling this far, one door per step.
    static func landing(from: Int, travel: CGFloat, step: CGFloat, count: Int) -> Int {
        guard count > 0, step > 0 else { return from }
        return min(max(0, from + Int((travel / step).rounded())), count - 1)
    }

    /// Doors between the held one and its landing step aside by one place.
    static func shift(_ index: Int, from: Int, to: Int) -> Int {
        if from < index && index <= to { return -1 }
        if to <= index && index < from { return 1 }
        return 0
    }
}
