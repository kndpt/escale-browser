import Foundation
import Testing
@testable import Escale

// The selection in History, Downloads and Bookmarks moves by row id within
// the rows on show. Plain lists and a synthetic bookmark tree keep the rule
// apart from any window.
@Suite @MainActor struct WalkTests {
    @Test func stepsStayWithinTheList() {
        let rows = ["a", "b", "c"]
        #expect(Walk.step(rows, from: "a", by: 1) == "b")
        #expect(Walk.step(rows, from: "c", by: 1) == "c")
        #expect(Walk.step(rows, from: "a", by: -1) == "a")
        #expect(Walk.step(rows, from: "b", by: -1) == "a")
    }

    @Test func nothingChosenOrNoLongerListedStartsAtTheTop() {
        #expect(Walk.step(["a", "b"], from: nil, by: 1) == "a")
        #expect(Walk.step(["a", "b"], from: nil, by: -1) == "a")
        // A search filtered the chosen row out.
        #expect(Walk.step(["b", "c"], from: "a", by: 1) == "b")
    }

    @Test func anEmptyListHasNoSelection() {
        #expect(Walk.step([String](), from: nil, by: 1) == nil)
        #expect(Walk.step([String](), from: "a", by: -1) == nil)
        #expect(Walk.after([String](), removing: "a") == nil)
    }

    @Test func removingPassesTheSelectionOn() {
        #expect(Walk.after(["a", "b", "c"], removing: "b") == "c")
        #expect(Walk.after(["a", "b", "c"], removing: "c") == "b")
        #expect(Walk.after(["a"], removing: "a") == nil)
        #expect(Walk.after(["a", "b"], removing: "z") == nil)
    }

    @Test func onlyOpenFoldersShowTheirRows() {
        let inner = Bookmark.folder("Inner", [site("Deep")])
        let outer = Bookmark.folder("Outer", [site("Child"), inner])
        let roots = [site("First"), outer, site("Last")]
        let titles = { (open: Set<Bookmark.ID>) in BookmarkOutline.shown(roots, open: open).map(\.title) }

        #expect(titles([]) == ["First", "Outer", "Last"])
        #expect(titles([outer.id]) == ["First", "Outer", "Child", "Inner", "Last"])
        #expect(titles([outer.id, inner.id]) == ["First", "Outer", "Child", "Inner", "Deep", "Last"])
        // An open folder inside a closed one stays hidden.
        #expect(titles([inner.id]) == ["First", "Outer", "Last"])

        let ids = BookmarkOutline.shown(roots, open: [outer.id]).map(\.id)
        #expect(Walk.step(ids, from: outer.id, by: 1) == outer.children?.first?.id)
        #expect(Walk.step(ids, from: inner.id, by: 1) == roots[2].id)
        // A folder removed takes its rows along: counted shut, the selection
        // passes past them.
        let shut = BookmarkOutline.shown(roots, open: []).map(\.id)
        #expect(Walk.after(shut, removing: outer.id) == roots[2].id)
    }

    private func site(_ title: String) -> Bookmark {
        Bookmark(title: title, url: "https://\(title.lowercased()).example.test/", children: nil)
    }
}
