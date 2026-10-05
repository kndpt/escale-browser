// Value-only regression cases keep membership and corrupt restoration apart
// from app globals and WebKit. The bench exercises real views and stores.
import Foundation
import Testing
@testable import Escale

@Suite @MainActor struct PanelsTests {
    @Test func fourEdgesAndInvalidCentre() {
        let frame = CGRect(x: 100, y: 50, width: 800, height: 600)
        #expect(PanelEdge.at(CGPoint(x: 110, y: 350), in: frame) == .left)
        #expect(PanelEdge.at(CGPoint(x: 890, y: 350), in: frame) == .right)
        #expect(PanelEdge.at(CGPoint(x: 500, y: 60), in: frame) == .top)
        #expect(PanelEdge.at(CGPoint(x: 500, y: 640), in: frame) == .bottom)
        #expect(PanelEdge.at(CGPoint(x: 500, y: 350), in: frame) == nil)
        #expect(PanelEdge.at(CGPoint(x: 0, y: 0), in: frame) == nil)
        #expect(PanelEdge.at(.zero, in: .zero) == nil)
    }
    @Test func membershipLimitAndSeparation() {
        let panels = Panels()
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        #expect(!panels.add(a, to: a, edge: .right))
        #expect(panels.add(b, to: a, edge: .left))
        #expect(panels.group(a)?.members == [b, a])
        #expect(panels.add(c, to: a, edge: .bottom))
        #expect(panels.group(a)?.members == [b, a, c])
        #expect(panels.group(a)?.horizontal == false)
        let snapshot = panels.groups
        #expect(!panels.add(d, to: a, edge: .right))
        #expect(panels.plan(d, beside: a, edge: .right) == nil)
        #expect(panels.groups == snapshot)
        // A page already in the composition moves to the edge it is dropped on.
        #expect(panels.plan(b, beside: a, edge: .right) == [a, c, b])
        #expect(panels.add(b, to: a, edge: .right))
        #expect(panels.group(a)?.members == [a, c, b])
        #expect(panels.group(a)?.horizontal == true)
        #expect(panels.groups.count == 1)
        panels.focus(a); panels.reverse(a)
        #expect(panels.group(a)?.members == [b, c, a])
        #expect(panels.group(a)?.active == a)
        panels.remove(c)
        #expect(panels.group(a)?.members == [b, a])
        panels.remove(a)
        #expect(panels.groups.isEmpty)
        #expect(panels.add(b, to: a, edge: .right))
        panels.separate(b)
        #expect(panels.groups.isEmpty)
    }
    @Test func cancellationStaysCancelledUntilRelease() {
        let panels = Panels(), a = UUID()
        panels.aim(a, edge: .left); panels.cancel(); panels.aim(a, edge: .right)
        #expect(panels.preview == nil)
        panels.finish(); panels.aim(a, edge: .right)
        #expect(panels.preview == .right)
    }
    @Test func removingOnePanelKeepsTheRest() {
        let panels = Panels(), a = UUID(), b = UUID(), c = UUID()
        #expect(panels.add(b, to: a, edge: .right))
        #expect(panels.add(c, to: a, edge: .right))
        panels.remove(b)
        #expect(panels.group(a)?.members == [a, c])
        #expect(panels.group(b) == nil)
    }
    @Test func movingBetweenGroupsAndResizingPreserveMembership() {
        let panels = Panels(), a = UUID(), b = UUID(), c = UUID(), d = UUID()
        #expect(panels.add(b, to: a, edge: .right))
        #expect(panels.add(d, to: c, edge: .bottom))
        #expect(panels.add(b, to: c, edge: .top))
        #expect(panels.group(a) == nil)
        #expect(panels.group(c)?.members == [b, c, d])
        guard let group = panels.group(c) else { Issue.record("Missing destination group"); return }
        panels.resize(group.id, weights: [2, 3, 5])
        #expect(panels.group(c)?.weights == [0.2, 0.3, 0.5])
        panels.resize(group.id, weights: [Double.infinity, 1, 1])
        #expect(panels.group(c)?.weights == [0.2, 0.3, 0.5])
        panels.move(b, by: 1)
        #expect(panels.group(c)?.members == [c, b, d])
        #expect(panels.group(c)?.weights == [0.3, 0.2, 0.5])
        panels.turn(c)
        #expect(panels.group(c)?.horizontal == true)
        panels.remove(b)
        #expect(panels.group(c)?.active == c)
    }
    @Test func backwardReadingAndInvalidGroups() throws {
        let legacy = Data(#"{"tabs":[{"url":"https://example.invalid","title":"A"}],"active":0}"#.utf8)
        let old = try JSONDecoder().decode(Session.Shape.self, from: legacy)
        #expect(Session.valid(old)); #expect(old.panels == nil)
        // The pre-group reader filters bad addresses and clamps selection.
        // Adding groups must not quarantine otherwise recoverable old rows.
        var partial = old
        partial.active = 20
        partial.tabs.append(Session.Entry(url: "not an address", title: "Old entry"))
        #expect(Session.valid(partial))
        var shape = Session.Shape(tabs: (0..<3).map { Session.Entry(url: "https://example.invalid/\($0)", title: "\($0)") }, active: 1)
        let group = Session.SavedPanels(members: [2, 0, 1], active: 0, horizontal: false, weights: [0.2, 0.5, 0.3])
        shape.panels = [group]
        #expect(Session.valid(shape))
        let roundTrip = try JSONDecoder().decode(Session.Shape.self, from: JSONEncoder().encode(shape))
        #expect(roundTrip.panels?.first?.members == [2, 0, 1])
        #expect(roundTrip.panels?.first?.weights == [0.2, 0.5, 0.3])
        shape.panels?[0].members = [2, 0, 0]
        #expect(!Session.valid(shape))
        shape.panels = [group, group]
        #expect(!Session.valid(shape))
        shape.panels = [group]; shape.panels?[0].active = 9
        #expect(!Session.valid(shape))
        shape.panels = [group]; shape.panels?[0].weights = [0, 0.5, 0.5]
        #expect(!Session.valid(shape))
        shape.panels = [group]; shape.panels?[0].members = [1, 2, 9]
        #expect(!Session.valid(shape))
        shape.panels = [group]; shape.tabs[0].url = "not an address"
        #expect(!Session.valid(shape))
    }
}
