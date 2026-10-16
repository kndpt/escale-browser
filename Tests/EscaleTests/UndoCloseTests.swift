import Foundation
import Testing
@testable import Escale

// Where Undo puts back what Clear or Close Other Tabs closed. Each tab is
// closed from the row as it is at that moment, and remembers the index it
// left from; Undo must give back the row as it was, however many there are.
// Rows are letters; no Browser, Tab or WebKit is needed.

@Suite struct UndoCloseTests {
    private let space = UUID()

    /// `names` closed one after another from `row`, as `Browser.close` does.
    private func close(_ names: [String], from row: [String]) throws -> (left: [String], ghosts: [Browser.Ghost]) {
        var row = row
        var ghosts: [Browser.Ghost] = []
        for name in names {
            let index = try #require(row.firstIndex(of: name))
            row.remove(at: index)
            ghosts.append(Browser.Ghost(url: try #require(URL(string: "https://\(name.lowercased()).example.test/")),
                                        title: name, index: index, space: space))
        }
        return (row, ghosts)
    }

    @Test(arguments: [
        // Clear: the loose tabs in row order, a pin kept at the head.
        (["P", "A", "B", "C"], ["A", "B", "C"]),
        // Clear with nothing awake left: a blank tab stood in at the end.
        (["A", "B", "C", "S"], ["A", "B", "C"]),
        // Close Other Tabs on C: those before it, then those after.
        (["A", "B", "C", "D", "E"], ["A", "B", "D", "E"]),
        // Fifteen at once, and closes in no particular order.
        ((1...15).map { "T\($0)" }, (1...15).map { "T\($0)" }),
        (["A", "B", "C", "D", "E"], ["D", "A", "E", "B"]),
    ])
    func undoPutsEveryTabBackInItsPlace(row: [String], closed: [String]) throws {
        let (left, ghosts) = try close(closed, from: row)
        #expect(Browser.Closing.reopening(ghosts, into: left) { $0.title } == row)
    }

    @Test func aRowThatShrankSinceStillTakesThemAll() throws {
        let (_, ghosts) = try close(["B", "D"], from: ["A", "B", "C", "D"])
        // A and C closed by hand since: B and D come back, in their order.
        #expect(Browser.Closing.reopening(ghosts, into: []) { $0.title } == ["B", "D"])
    }
}
