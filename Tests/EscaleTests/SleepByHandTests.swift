// Putting tabs to sleep by hand: both commands start with no key, and what is
// said afterwards counts the tabs that went and names, once each, what kept
// the others awake, so a refusal is never silent.
import Testing
@testable import Escale

@Suite struct SleepByHandTests {
    @Test func commandsAreListedWithoutAKey() {
        for action in [KeyAction.sleepTab, .sleepOthers] {
            #expect(action.command.group == .tabs)
            #expect(action.command.defaults.isEmpty)
            #expect(action.index == nil)
            #expect(KeyBindings().keys(action).isEmpty)
        }
        #expect(KeyBindings().matches(KeyAction.sleepOthers.command, query: "sleep other"))
    }

    @MainActor @Test func oneTabSaysWhetherItWent() {
        #expect(Browser.slept(["asleep"]) == "Tab asleep")
        #expect(Browser.slept(["pinned"]) == "Kept awake: pinned")
        #expect(Browser.slept(["holding something typed"]) == "Kept awake: holding something typed")
    }

    @MainActor @Test func severalTabsCountAndNameEachReasonOnce() {
        #expect(Browser.slept(["asleep", "asleep"]) == "2 tabs asleep")
        #expect(Browser.slept(["asleep", "pinned", "playing sound", "pinned"])
                == "1 tab asleep, 3 kept awake: pinned, playing sound")
        #expect(Browser.slept(["downloading", "on a call"]) == "No tab asleep, 2 kept awake: downloading, on a call")
    }
}
