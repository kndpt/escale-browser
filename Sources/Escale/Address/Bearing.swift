// What Bearings is doing, as a pair with GitHub. ⌘K finds an open tab and ⌘T
// opens a page; each has GitHub beside it and nothing else, because whoever
// pressed ⌘T has no use for ⌘K's question. ⌘L changes this page's address and
// has no modes. The capsule at the end of the field (Omnibox) and Tab (App)
// both switch through here, so they can never disagree about the partner.
import Foundation

enum Bearing: Hashable { case tabs, newTab, github }

extension Browser {
    /// GitHub keeps the New Tab it was opened over; otherwise it pairs with
    /// tab search, its ⇧⌘K sibling.
    private var opensPage: Bool { field.opening != nil || active?.isBlank == true }

    /// The mode on screen, or nil while ⌘L edits this page's address.
    var bearing: Bearing? {
        if field.github != nil { return .github }
        if field.summoning { return .tabs }
        return opensPage ? .newTab : nil
    }

    /// The mode GitHub sits beside right now.
    var bearingPartner: Bearing? {
        switch bearing {
        case .tabs: return .tabs
        case .newTab: return .newTab
        case .github: return opensPage ? .newTab : .tabs
        case nil: return nil
        }
    }

    func choose(_ next: Bearing) {
        guard next != bearing else { return }
        switch next {
        case .tabs:
            summon()
        case .newTab:
            // Back from GitHub to the New Tab it was opened over keeps the words typed.
            if field.github != nil, opensPage { leaveGitHub() }
            else { beginNewTab(shy: searchIsPrivate) }
        case .github:
            beginGitHub()
        }
    }

    /// Tab: the other mode of the pair, whatever row is selected. False when
    /// there is no pair, so ⌘L keeps Tab for walking its list.
    @discardableResult func switchBearing() -> Bool {
        guard let bearing, let partner = bearingPartner else { return false }
        choose(bearing == .github ? partner : .github)
        return true
    }
}
