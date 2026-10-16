import Foundation
import Testing
@testable import Escale

// Which closed tabs ⌘⇧T can still bring back. Each Space keeps its own last
// few, so closing many tabs in one Space never erases another's. No Browser
// or WebKit: the rule is the list `remember` keeps.

@Suite struct ClosedTabsTests {
    private let here = UUID()
    private let there = UUID()

    private func ghost(_ n: Int, in space: UUID, name: String? = nil) throws -> Browser.Ghost {
        Browser.Ghost(url: try #require(URL(string: "https://page-\(n).example.test/")),
                      title: "Page \(n)", index: n, space: space, name: name)
    }

    @Test func eachSpaceKeepsItsOwnLimit() throws {
        var closed: [Browser.Ghost] = []
        let kept = try (1...3).map { try ghost($0, in: there) }
        for one in kept { closed = Browser.Ghost.adding(one, to: closed) }
        // Twice the limit closed here, after those three: only this Space's
        // oldest make room, and the other Space keeps all three.
        let mine = try (1...(2 * Browser.Ghost.kept)).map { try ghost($0, in: here) }
        for one in mine { closed = Browser.Ghost.adding(one, to: closed) }
        #expect(closed.filter { $0.space == there } == kept)
        #expect(closed.filter { $0.space == here } == Array(mine.suffix(Browser.Ghost.kept)))
        #expect(closed.count == Browser.Ghost.kept + kept.count)
    }

    @Test(arguments: [0, 1, 2, 3])
    func evictsTheOldestOfItsSpaceFirst(count: Int) throws {
        var closed: [Browser.Ghost] = []
        let all = try (0..<count).map { try ghost($0, in: here) }
        for one in all { closed = Browser.Ghost.adding(one, to: closed, limit: 2) }
        #expect(closed == Array(all.suffix(2)))
    }

    @Test func aNamedTabIsListedByItsName() throws {
        #expect(try ghost(1, in: here, name: "Review").label == "Review")
        #expect(try ghost(1, in: here, name: "").label == "Page 1")
        #expect(try ghost(1, in: here).label == "Page 1")
    }
}
