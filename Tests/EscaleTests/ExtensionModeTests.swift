// One set of extensions for every Space, or a set per Space. Absent means
// per Space, what every Escale did before the choice, and one owner then
// serves every Space under the first Space's identity.
import Foundation
import Testing
@testable import Escale

@Suite(.serialized) @MainActor struct ExtensionModeTests {
    @Test func perSpaceEachSpaceHasItsOwnOwner() {
        guard #available(macOS 15.4, *) else { return }
        let other = UUID()
        #expect(Extensions.owner(of: other, sharing: false) == other)
        #expect(Extensions.owner(of: Space.firstID, sharing: false) == Space.firstID)
    }

    @Test func sharedTheFirstSpaceServesEvery() {
        guard #available(macOS 15.4, *) else { return }
        #expect(Extensions.owner(of: UUID(), sharing: true) == Space.firstID)
        #expect(Extensions.owner(of: Space.firstID, sharing: true) == Space.firstID)
    }

    @Test func absentIsPerSpace() {
        guard #available(macOS 15.4, *) else { return }
        let key = "extensions.shared"
        let before = Store.settings.object(forKey: key)
        defer { Store.settings.set(before, forKey: key) }
        Store.settings.removeObject(forKey: key)
        #expect(!Extensions.sharesOne)
        Store.settings.set(true, forKey: key)
        #expect(Extensions.sharesOne)
        Store.settings.set(false, forKey: key)
        #expect(!Extensions.sharesOne)
    }
}
