// Opening search is an intention, not a page. Field keeps one short-lived
// request (including its privacy context); Escape, selection and Space changes
// discard it. Only a committed destination allocates a tab/WebKit page, so
// returning to an existing tab cannot accumulate empty tabs or session entries.
import Foundation

extension Browser {
    var searchingNewTab: Bool { field.opening != nil || active?.isBlank == true }
    var searchIsPrivate: Bool { field.github?.shy ?? field.opening?.shy ?? active?.shy ?? false }

    func beginNewTab(shy: Bool) {
        reviewing = false
        cancelTabEdit()
        closeFind()
        active?.touch()
        field.startOpening(shy: shy)
        editing = true
        field.askFocus()
    }

    /// New Tab commits into a new page; ⌘L still edits the current page.
    @discardableResult
    func navigateFromField(_ url: URL) -> Tab? {
        if let opening = field.opening,
           active?.isBlank != true || active?.shy != opening.shy {
            return open(url, foreground: true, atEnd: true, shy: opening.shy)
        }
        let tab = active ?? tabs.first
        tab?.go(to: url)
        editing = false
        field.typed = ""
        return tab
    }

    /// Closing an uncommitted New Tab leaves the page underneath in place.
    func closeTabCommand() {
        if field.opening != nil || field.github != nil { dismiss() }
        else if let tab = active { close(tab) }
    }
}
