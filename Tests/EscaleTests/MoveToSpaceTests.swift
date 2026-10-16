import Foundation
import Testing
@testable import Escale

// Where a tab can be sent: the other Spaces in rail order, and one step along
// the rail for the keys, wrapping at both ends. With Spaces off or only one
// Space there is nowhere, so the menus draw nothing and the keys stay idle.
@Suite struct MoveToSpaceTests {
    let one = Space(id: Space.firstID, name: "Personal", colour: 0)
    let two = Space(id: UUID(), name: "Two", colour: 0)
    let three = Space(id: UUID(), name: "Three", colour: 0)

    @Test func theOtherSpacesInRailOrder() {
        let spaces = [three, one, two]
        #expect(Spaces.destinations(spaces, from: one.id, on: true).map(\.id) == [three.id, two.id])
        #expect(Spaces.destinations(spaces, from: three.id, on: true).map(\.id) == [one.id, two.id])
    }

    @Test func nowhereWithSpacesOffOrAlone() {
        #expect(Spaces.destinations([one, two], from: one.id, on: false).isEmpty)
        #expect(Spaces.destinations([one], from: one.id, on: true).isEmpty)
        #expect(Spaces.neighbour([one, two], of: one.id, by: 1, on: false) == nil)
        #expect(Spaces.neighbour([one], of: one.id, by: 1, on: true) == nil)
        #expect(Spaces.neighbour([one], of: one.id, by: -1, on: true) == nil)
        #expect(Spaces.neighbour([one, two], of: three.id, by: 1, on: true) == nil)
    }

    @Test func oneStepWrapsAtBothEnds() {
        let spaces = [one, two, three]
        #expect(Spaces.neighbour(spaces, of: one.id, by: 1, on: true) == two.id)
        #expect(Spaces.neighbour(spaces, of: two.id, by: -1, on: true) == one.id)
        #expect(Spaces.neighbour(spaces, of: three.id, by: 1, on: true) == one.id)
        #expect(Spaces.neighbour(spaces, of: one.id, by: -1, on: true) == three.id)
        #expect(Spaces.neighbour([one, two], of: two.id, by: 1, on: true) == one.id)
        #expect(Spaces.neighbour([one, two], of: two.id, by: -1, on: true) == one.id)
    }
}
