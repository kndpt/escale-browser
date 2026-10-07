// Tests assert observable assignments and saved snapshots: a stolen combination
// must leave exactly one destination, and a removed default must not return after
// decoding. Event cases include AZERTY numbers and punctuation with Shift.
import AppKit
import Testing
@testable import Escale

@Suite struct KeyBindingsTests {
    @Test func catalogueCoversEveryActionWithoutDuplicateDefaults() {
        #expect(Set(KeyCommand.all.map(\.action)) == Set(KeyAction.allCases))
        #expect(KeyCommand.all.count == KeyAction.allCases.count)
        let defaults = KeyCommand.all.flatMap(\.defaults)
        #expect(defaults.count == Set(defaults).count)
        for command in KeyCommand.all {
            #expect(!command.title.isEmpty)
            #expect(command.defaults.allSatisfy { $0.shortcut != nil })
        }
    }
    @Test func spaceOrderAndDeleteCommandsStartUnbound() {
        for action in [KeyAction.moveSpaceUp, .moveSpaceDown, .deleteSpace] {
            #expect(action.command.group == .spaces)
            #expect(action.command.defaults.isEmpty)
            #expect(action.index == nil)
            #expect(KeyBindings().keys(action).isEmpty)
        }
        #expect(KeyBindings().matches(KeyAction.moveSpaceDown.command, query: "move space down"))
    }
    @Test func reassignmentAndRemovalSurviveReload() {
        var bindings = KeyBindings()
        let custom = KeyStroke("t", [.command, .option])
        let assigned1 = bindings.set([custom], for: .newTab)
        #expect(assigned1)
        #expect(bindings.action(for: KeyStroke("t", .command)) == nil)
        #expect(bindings.action(for: custom) == .newTab)
        let loaded = KeyBindings.read(bindings.data)
        #expect(loaded == bindings)
        let assigned2 = bindings.set([], for: .newTab)
        #expect(assigned2)
        #expect(KeyBindings.read(bindings.data).keys(.newTab).isEmpty)
        bindings.reset()
        #expect(bindings.keys(.newTab) == [KeyStroke("t", .command)])
    }
    @Test func collisionRequiresConsentAndKeepsUnrelatedAlternative() {
        var bindings = KeyBindings()
        let next = KeyStroke("]", [.command, .shift])
        let assigned3 = bindings.set([next], for: .nextSpace)
        #expect(!assigned3)
        #expect(!bindings.changed(.nextSpace))
        let assigned4 = bindings.set([next], for: .nextSpace, replacing: true)
        #expect(assigned4)
        #expect(bindings.keys(.nextTab) == [KeyStroke("tab", .control)])
        #expect(bindings.action(for: next) == .nextSpace)
        #expect(KeyBindings.read(bindings.data) == bindings)
        let assigned5 = bindings.set(KeyAction.nextTab.command.defaults, for: .nextTab)
        #expect(!assigned5)
        let assigned6 = bindings.set(KeyAction.nextTab.command.defaults, for: .nextTab, replacing: true)
        #expect(assigned6)
        #expect(bindings.keys(.nextSpace).isEmpty)
        #expect(!bindings.changed(.nextTab))
    }
    @Test func unknownAndMalformedSnapshotsAreBounded() {
        #expect(KeyBindings.read(Data("not JSON".utf8)) == KeyBindings())
        #expect(KeyBindings.read(Data(repeating: 0, count: 65537)) == KeyBindings())
        let invalid = Data(#"{"overrides":{"newTab":[{"key":"q","modifiers":1048576}],"unknown":[]}}"#.utf8)
        #expect(KeyBindings.read(invalid) == KeyBindings())
    }
    @Test(arguments: [KeyStroke("left", .option), KeyStroke("right", [.option, .shift]), KeyStroke("c", .command), KeyStroke("left", .control), KeyStroke("left", [.control, .option]), KeyStroke("q", .command), KeyStroke("#3", [.shift, .command]), KeyStroke("x", [])])
    func protectsNativeGestures(stroke: KeyStroke) {
        #expect(stroke.refusal != nil)
        var bindings = KeyBindings()
        let assigned7 = bindings.set([stroke], for: .newTab, replacing: true)
        #expect(!assigned7)
    }
    @Test(arguments: ["b", "i", "u"])
    func formattingKeysCannotBecomeBrowserCommands(key: String) throws {
        let stroke = KeyStroke(key, .command)
        #expect(stroke.refusal != nil)
        var bindings = KeyBindings()
        let assigned = bindings.set([stroke], for: .duplicateTab, replacing: true)
        #expect(!assigned)
        #expect(bindings == KeyBindings())
        // Old profiles must not keep an assignment that the recorder now refuses.
        let snapshot = try JSONSerialization.data(withJSONObject: ["overrides": [
            "duplicateTab": [["key": key, "modifiers": NSEvent.ModifierFlags.command.rawValue]],
            "downloads": [],
        ]])
        let loaded = KeyBindings.read(snapshot)
        #expect(loaded.action(for: stroke) == nil)
        #expect(loaded.keys(.duplicateTab) == KeyAction.duplicateTab.command.defaults)
        #expect(loaded.keys(.downloads).isEmpty)
        #expect(KeyStroke(key, [.command, .shift]).refusal == nil)
    }
    @Test(arguments: [KeyStroke("a", .control), KeyStroke("k", .control), KeyStroke("e", [.control, .shift]), KeyStroke("e", .option), KeyStroke("e", [.option, .shift]), KeyStroke("#2", .option), KeyStroke("delete", .option), KeyStroke("[", .option)])
    func textInputKeysCannotBecomeBrowserCommands(stroke: KeyStroke) throws {
        var bindings = KeyBindings()
        let assigned = bindings.set([stroke], for: .duplicateTab, replacing: true)
        #expect(!assigned)
        let snapshot = try JSONSerialization.data(withJSONObject: ["overrides": [
            "duplicateTab": [["key": stroke.key, "modifiers": stroke.modifiers]],
        ]])
        #expect(KeyBindings.read(snapshot) == KeyBindings())
        #expect(KeyStroke("#2", .control).refusal == nil)
        #expect(KeyStroke("tab", .control).refusal == nil)
        #expect(KeyStroke("tab", [.control, .shift]).refusal == nil)
        #expect(KeyStroke("e", [.option, .command]).refusal == nil)
    }
    @Test func controlNumbersWarnWithoutBeingLocked() {
        let key = KeyStroke("#2", .control)
        #expect(key.refusal == nil)
        #expect(key.caution != nil)
    }
    @Test(arguments: [(UInt16(18), "&", "#1"), (19, "é", "#2"), (20, "\"", "#3"), (25, "ç", "#9"), (30, "}", "]"), (33, "{", "["), (24, "+", "=")])
    func normalizesLayoutAndShift(code: UInt16, text: String, expected: String) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        let stroke = try #require(KeyStroke(event))
        #expect(stroke.key == expected)
        #expect(stroke.flags == [.command, .shift])
    }
    @Test func findsByWordsAndKeys() {
        let bindings = KeyBindings()
        #expect(bindings.matches(KeyAction.reopenTab.command, query: "cmd shift t"))
        #expect(!bindings.matches(KeyAction.privateTab.command, query: "cmd shift t"))
        #expect(!bindings.matches(KeyAction.nextTab.command, query: "cmd shift t"))
        #expect(!bindings.matches(KeyAction.reopenTab.command, query: "⌘T"))
        #expect(bindings.matches(KeyAction.nextSpace.command, query: "⌥⌘↓"))
        #expect(bindings.matches(KeyAction.nextSpace.command, query: "space next"))
        #expect(bindings.matches(KeyAction.newTab.command, query: "⌘T"))
        #expect(!bindings.matches(KeyAction.newTab.command, query: "zoom"))
    }
}
