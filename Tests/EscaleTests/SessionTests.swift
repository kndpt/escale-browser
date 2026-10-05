import Testing
@testable import Escale

// Which tab a saved session selects, once the tabs it doesn't keep are gone.
// Rows are written as words: a letter is a tab kept under that name,
// `x` one left out (private, the bench's, a bookmark's, no web address), and
// `*` marks the one being looked at. Each case names the row and the
// selection it must come back with; the expected index is written by hand.

private func row(_ words: String) -> (entries: [Session.Entry?], active: Int?) {
    let parts = words.split(separator: " ").map(String.init)
    let entries = parts.map { word -> Session.Entry? in
        let name = word.replacingOccurrences(of: "*", with: "")
        return name == "x" ? nil : Session.Entry(url: "https://\(name.lowercased()).test/", title: name)
    }
    return (entries, parts.firstIndex { $0.hasSuffix("*") })
}

@Suite struct SessionSelection {
    @Test(arguments: [
        // The one looked at is kept: it comes back, whatever was left out around it.
        ("A* B", ["A", "B"], "A"),
        ("A B*", ["A", "B"], "B"),
        ("x A* B", ["A", "B"], "A"),   // the reported case: B came back
        ("A x B*", ["A", "B"], "B"),   // an index past the end
        ("x x A*", ["A"], "A"),        // one entry and active 2, as observed
        ("A* x B", ["A", "B"], "A"),
        ("A B* x", ["A", "B"], "B"),
        ("x x A x B* x", ["A", "B"], "B"),
        ("A x B x C* x D", ["A", "B", "C", "D"], "C"),
        // The one looked at is left out: its nearest kept neighbour before
        // it, or the first after it when there is none before.
        ("A B x*", ["A", "B"], "B"),
        ("A x* B", ["A", "B"], "A"),
        ("A x x* B", ["A", "B"], "A"),
        ("x* A B", ["A", "B"], "A"),
        ("x x* A B", ["A", "B"], "A"),
        ("A x B x* x C", ["A", "B", "C"], "B"),
    ])
    func selects(words: String, kept: [String], selected: String) {
        let (entries, active) = row(words)
        let shape = Session.shape(entries, active: active)
        #expect(shape.tabs.map(\.title) == kept)
        #expect(shape.tabs.indices.contains(shape.active) && shape.tabs[shape.active].title == selected)
    }

    @Test(arguments: ["", "x*", "x x* x"])
    func nothingKept(words: String) {
        let (entries, active) = row(words)
        let shape = Session.shape(entries, active: active)
        #expect(shape.tabs.isEmpty)
        #expect(shape.active == 0)
    }

    /// No tab looked at in the row (none selected, or one no longer in it):
    /// the first kept one, as before.
    @Test(arguments: [nil, -1, 3, 9] as [Int?])
    func noSelectionInTheRow(active: Int?) {
        let (entries, _) = row("x A B")
        let shape = Session.shape(entries, active: active)
        #expect(shape.tabs.map(\.title) == ["A", "B"])
        #expect(shape.active == 0)
    }
}
