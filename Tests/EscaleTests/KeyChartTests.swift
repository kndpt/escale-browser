// The ⌘/ chart must show the keys in use, not the catalogue's defaults: a key
// someone moved appears where they put it, and a removed one is gone.
import Testing
@testable import Escale

@Suite struct KeyChartTests {
    private func row(_ title: String, in bindings: KeyBindings) -> KeyChart.Row? {
        KeyChart.sections(bindings).flatMap(\.rows).first { $0.title == title }
    }

    @Test func groupsFollowSettingsAndEndWithTheKeysEscaleDoesNotOwn() {
        let groups = KeyChart.sections(KeyBindings()).map(\.group)
        #expect(groups == KeyGroup.allCases)
        #expect(row("Keyboard Shortcuts", in: KeyBindings())?.keys == "⌘/")
        #expect(row("Copy, Cut, Paste", in: KeyBindings())?.keys == "⌘C · ⌘X · ⌘V")
        #expect(row("Next Tab", in: KeyBindings())?.keys == "⇧⌘] · ⌃⇥")
    }

    @Test func numberedDestinationsShareALineUntilOneMoves() {
        #expect(row("Go to Tab 1–8", in: KeyBindings())?.keys == "⌘1–8")
        #expect(row("Go to Space 1–9", in: KeyBindings())?.keys == "⌃1–9")
        #expect(row("Go to Tab 1", in: KeyBindings()) == nil)
        var bindings = KeyBindings()
        bindings.set([KeyStroke("#3", [.command, .option])], for: .tab3)
        #expect(row("Go to Tab 1–8", in: bindings) == nil)
        #expect(row("Go to Tab 1", in: bindings)?.keys == "⌘1")
        #expect(row("Go to Tab 3", in: bindings)?.keys == "⌥⌘3")
        #expect(row("Go to Space 1–9", in: bindings)?.keys == "⌃1–9")
    }

    @Test func showsCustomKeysAndLeavesOutRemovedOnes() {
        var bindings = KeyBindings()
        bindings.set([KeyStroke("t", [.command, .option])], for: .newTab)
        bindings.set([], for: .history)
        #expect(row("New Tab", in: bindings)?.keys == "⌥⌘T")
        #expect(row("Show History", in: bindings) == nil)
        #expect(row("Show History", in: KeyBindings())?.keys == "⌘Y")
        // A command without a key has nothing to show, and neither has its group.
        #expect(row("Rename Tab", in: bindings) == nil)
        for space in KeyAction.allCases where space.command.group == .spaces { bindings.set([], for: space) }
        #expect(!KeyChart.sections(bindings).map(\.group).contains(.spaces))
    }
}
