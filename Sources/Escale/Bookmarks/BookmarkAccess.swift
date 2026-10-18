// A bookmark is drawn as a line that answers a tap, in the column's shelf as
// in the Bookmarks menu and panel, so VoiceOver and Full Keyboard Access found
// no button and no name on it. Each row is given to them as one button, as a
// tab is (TabAccess.swift): named by its title, a folder saying whether it is
// open and an open bookmark whether it is on screen or sleeping, its press
// doing what a click does. Its environment menu becomes one action per
// destination, since the row now stands for what is drawn inside it. Nothing
// is drawn for them, so the pointer sees the same row. While a folder's name
// is typed, the field inside is what they reach. A row applies it before its
// context menu, so the menu is the button's own.
import SwiftUI

struct BookmarkAccess: ViewModifier {
    let node: Bookmark
    /// The folder is open.
    let isOpen: Bool
    /// The folder's name being typed.
    let naming: Bool
    /// The bookmark's own tab while it is open, and whether it is on screen.
    var tab: Tab? = nil
    var live = false
    /// The tooltip while its tab is awake.
    var ordinary = ""
    let press: () -> Void
    let environment: (BookmarkEnvironment) -> Void

    // Its tab is watched only while there is one, so automatic sleep updates
    // the row without the whole shelf redrawing.
    @ViewBuilder
    func body(content: Content) -> some View {
        if let tab { content.modifier(Watched(access: self, tab: tab)) } else { button(content, sleeping: false) }
    }

    private func button(_ content: some View, sleeping: Bool) -> some View {
        content
            .help(sleeping ? SleepLabel.help : ordinary)
            .accessibilityElement(children: naming ? .contain : .ignore)
            .accessibilityAddTraits(naming ? [] : .isButton)
            .accessibilityLabel(node.title)
            .accessibilityValue(value(sleeping: sleeping))
            .accessibilityHint(sleeping ? SleepLabel.explanation : "")
            .accessibilityAction { press() }
            .accessibilityActions {
                ForEach(node.destinations) { item in Button("Open \(item.name)") { environment(item) } }
            }
    }

    private func value(sleeping: Bool) -> String {
        node.isFolder ? Self.shown(isOpen) : Self.state(open: tab != nil, live: live, sleeping: sleeping)
    }

    private struct Watched: ViewModifier {
        let access: BookmarkAccess
        @ObservedObject var tab: Tab

        func body(content: Content) -> some View { access.button(content, sleeping: tab.sleeping) }
    }

    /// What VoiceOver reads after a folder's title, or the shelf's heading.
    static func shown(_ open: Bool) -> String { open ? "Expanded" : "Collapsed" }

    /// What VoiceOver reads after a site's title: its page on screen, or open
    /// elsewhere, and let go to save resources. Empty for a shut bookmark.
    static func state(open: Bool, live: Bool, sleeping: Bool) -> String {
        [live ? "Active" : open ? "Open" : nil, sleeping ? SleepLabel.name : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}
