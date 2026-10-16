// One set of extensions for every Space, or a set per Space. Absent means
// per Space, what every Escale did before the choice, and one owner then
// serves every Space under the first Space's identity. Switching lists what
// a Space would lose sight of to reinstall, and deletes nothing.
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

    private func item(_ id: String, _ name: String, store: Bool = true) -> Installed {
        Installed(id: id, name: name, version: "1", enabled: true, fromStore: store, permissions: [])
    }

    private func plans(_ spaces: [Space]) -> [UUID: [PlannedExtension]] {
        Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0.plannedExtensions ?? []) })
    }

    @Test func sharingListsWhatOnlyOtherSpacesHad() {
        let first = Space(id: Space.firstID, name: "Personal", colour: 0)
        var work = Space(id: UUID(), name: "Work", colour: 0)
        let blocker = item("blocker", "Blocker"), keys = item("keys", "Keys"), local = item("local-1", "Mine", store: false)
        // A plan for what the shared set already holds is let go.
        work.plannedExtensions = [PlannedExtension(name: "Blocker", storeID: "blocker")]
        let made = plans(Browser.replanned([first, work], sharing: true,
                                           sets: [first.id: [blocker], work.id: [blocker, keys, local]]))
        #expect(made[first.id] == [])
        #expect(made[work.id] == [PlannedExtension(name: "Keys", storeID: "keys"), PlannedExtension(name: "Mine", storeID: nil)])
    }

    @Test func separatingListsTheSharedSetWhereASpaceLacksIt() {
        let first = Space(id: Space.firstID, name: "Personal", colour: 0)
        let work = Space(id: UUID(), name: "Work", colour: 0)
        var fresh = Space(id: UUID(), name: "New", colour: 0)
        let blocker = item("blocker", "Blocker"), keys = item("keys", "Keys")
        // Listed while shared, then found in its own set again.
        fresh.plannedExtensions = [PlannedExtension(name: "Old", storeID: "old")]
        let made = plans(Browser.replanned([first, work, fresh], sharing: false,
                                           sets: [first.id: [blocker, keys], work.id: [keys], fresh.id: [item("old", "Old")]]))
        #expect(made[first.id] == [])
        #expect(made[work.id] == [PlannedExtension(name: "Blocker", storeID: "blocker")])
        #expect(made[fresh.id] == [PlannedExtension(name: "Blocker", storeID: "blocker"), PlannedExtension(name: "Keys", storeID: "keys")])
    }

    @Test func switchingTwiceListsNothingTwice() {
        let first = Space(id: Space.firstID, name: "Personal", colour: 0)
        let work = Space(id: UUID(), name: "Work", colour: 0)
        let sets = [first.id: [item("blocker", "Blocker")], work.id: [item("keys", "Keys")]]
        let there = Browser.replanned([first, work], sharing: true, sets: sets)
        let back = plans(Browser.replanned(Browser.replanned(there, sharing: false, sets: sets), sharing: true, sets: sets))
        #expect(back[work.id] == [PlannedExtension(name: "Keys", storeID: "keys")])
        #expect(back[first.id] == [])
    }
}
