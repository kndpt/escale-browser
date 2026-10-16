// A tab sent to another Space from its menu, the Tabs menu or a key, without
// the drag onto a rail icon. Every path ends in Browser.transfer, the drag's
// own move, so the WebKit store, pin, name and draft follow the same rules;
// only a refusal, which a drag shows by leaving the tab where it was, is said
// aloud here. With Spaces off or a single Space there is nowhere to go, so the
// entries are not drawn and the keys do nothing.
import SwiftUI

extension Spaces {
    /// Where a tab in `source` can go: every other Space, in rail order.
    static func destinations(_ spaces: [Space], from source: UUID, on: Bool) -> [Space] {
        guard on, spaces.count > 1 else { return [] }
        return spaces.filter { $0.id != source }
    }

    /// One step along the rail from `source`, wrapping at the ends as Next
    /// and Previous Space do.
    static func neighbour(_ spaces: [Space], of source: UUID, by step: Int, on: Bool) -> UUID? {
        guard on, spaces.count > 1, let at = spaces.firstIndex(where: { $0.id == source }) else { return nil }
        return spaces[((at + step) % spaces.count + spaces.count) % spaces.count].id
    }
}

extension Browser {
    func send(_ tab: Tab, to destination: UUID) {
        guard transfer(tab, to: destination) == nil else { return }
        let name = spaces.first { $0.id == destination }?.name ?? "that Space"
        announce("This tab can’t move to “\(name)”")
    }

    /// Where the shown tab's Next or Previous key sends it.
    func neighbourSpace(by step: Int) -> UUID? {
        active.flatMap { Spaces.neighbour(spaces, of: $0.space, by: step, on: prefs.usesSpaces) }
    }
}

/// "Move to Space ▸", in a tab's menu and the Tabs menu; `extra` closes the
/// list, for the menu bar's keyed commands.
struct MoveToSpaceMenu<Extra: View>: View {
    @ObservedObject var browser: Browser
    let tab: Tab
    @ViewBuilder var extra: Extra

    var body: some View {
        let choices = Spaces.destinations(browser.spaces, from: tab.space, on: browser.prefs.usesSpaces)
        if !choices.isEmpty {
            Menu {
                ForEach(choices) { space in
                    Button { browser.send(tab, to: space.id) } label: { Label(space.name, systemImage: space.symbol) }
                }
                extra
            } label: { Label("Move to Space", systemImage: "rectangle.portrait.and.arrow.right") }
        }
    }
}

extension MoveToSpaceMenu where Extra == EmptyView {
    init(browser: Browser, tab: Tab) { self.init(browser: browser, tab: tab) { EmptyView() } }
}
