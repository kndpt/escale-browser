// When the address bar shows ⌘L beside the title: until it has been used
// once, always; after that, under the pointer only; unbound, never. Drawing
// is left to the app journey.
import Testing
@testable import Escale

@Suite struct AddressHintTests {
    @Test func unboundShowsNothing() {
        #expect(AddressBar.hint("", learned: false, hovering: true) == nil)
        #expect(AddressBar.hint("", learned: true, hovering: true) == nil)
    }

    @Test func notYetUsedShowsAtRest() {
        #expect(AddressBar.hint("⌘L", learned: false, hovering: false) == "⌘L")
        #expect(AddressBar.hint("⌘L", learned: false, hovering: true) == "⌘L")
    }

    @Test func usedShowsOnHoverOnly() {
        #expect(AddressBar.hint("⌘L", learned: true, hovering: false) == nil)
        #expect(AddressBar.hint("⇧⌘L", learned: true, hovering: true) == "⇧⌘L")
    }
}
