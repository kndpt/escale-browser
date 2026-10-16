// A tab is drawn as a sidebar row, a pill or a pinned square that answers a
// tap, and its cross and Copy Link button appear only under the pointer.
// VoiceOver and Full Keyboard Access never hover, so each tab is given to them
// as one button: named by its title, its state as the value, and Close Tab and
// Copy Link as actions of its own. Nothing is drawn for them, so the pointer
// sees the same tab and the loading ring keeps the slot the cross would take.
// While its address or letter is typed, the field inside is what they reach.
// A tab applies it before its context menu, so the menu is the button's own.
import SwiftUI

struct TabAccess: ViewModifier {
    /// Not watched, as in SideRow.
    let browser: Browser
    @ObservedObject var tab: Tab
    let live: Bool
    let pinned: Bool
    /// Its address or its letter being typed.
    let editing: Bool
    /// Only a tab of the space on screen closes.
    let closes: Bool
    /// The tooltip while it is awake.
    var ordinary = ""

    func body(content: Content) -> some View {
        content
            .help(tab.sleeping ? SleepLabel.help : ordinary)
            .accessibilityElement(children: editing ? .contain : .ignore)
            .accessibilityAddTraits(editing ? [] : .isButton)
            .accessibilityLabel(tab.label)
            .accessibilityValue(Self.state(live: live, pinned: pinned, sleeping: tab.sleeping))
            .accessibilityHint(tab.sleeping ? SleepLabel.explanation : "")
            .accessibilityAction { browser.select(tab) }
            // Offered only where they do something, as the cross and the copy
            // button are shown only where they do.
            .accessibilityActions {
                if closes { Button("Close Tab") { browser.close(tab) } }
                if tab.address != nil { Button("Copy Link") { browser.copyAddress(of: tab) } }
            }
    }

    /// What VoiceOver reads after the title: the tab on screen, a pin, a page
    /// let go to save resources. Empty for an ordinary tab.
    static func state(live: Bool, pinned: Bool, sleeping: Bool) -> String {
        [live ? "Active" : nil, pinned ? "Pinned" : nil, sleeping ? SleepLabel.name : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}
