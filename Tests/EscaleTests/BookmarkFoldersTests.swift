import Foundation
import Testing
@testable import Escale

// Folder creation is one tree edit, and the sidebar derives visible rows from
// stored bookmarks plus open tab identities. Synthetic trees keep these rules
// independent of a browser window or a person's bookmark file.
@Suite @MainActor struct BookmarkFoldersTests {
    private func site(_ title: String) -> Bookmark {
        Bookmark(title: title, url: "https://\(title.lowercased()).example.test/", children: nil)
    }

    @Test func mergingAcrossFoldersKeepsBothSitesAndTheTargetPlace() throws {
        let carried = site("Carried")
        let target = site("Target")
        let neighbour = site("Neighbour")
        let roots = [Bookmark.folder("Source", [carried]), neighbour,
                     Bookmark.folder("Destination", [target])]

        let result = try #require(Bookmarks.merged(roots, source: carried.id, target: target.id))
        #expect(result.nodes[0].children?.isEmpty == true)
        #expect(result.nodes[1] == neighbour)
        #expect(result.nodes[2].children?.first?.id == result.folder.id)
        #expect(result.folder.children?.map(\.id) == [target.id, carried.id])

        let restored = try JSONDecoder().decode([Bookmark].self,
            from: JSONEncoder().encode(result.nodes))
        #expect(restored == result.nodes)
    }

    @Test func invalidMergesPreserveTheOriginalTree() {
        let first = site("First")
        let second = site("Second")
        let folder = Bookmark.folder("Folder", [second])
        let roots = [first, folder]
        #expect(Bookmarks.merged(roots, source: first.id, target: first.id) == nil)
        #expect(Bookmarks.merged(roots, source: folder.id, target: first.id) == nil)
        #expect(Bookmarks.merged(roots, source: first.id, target: folder.id) == nil)
        #expect(Bookmarks.merged(roots, source: UUID(), target: second.id) == nil)
        #expect(roots[0] == first && roots[1] == folder)
    }

    @Test func aClosedFolderShowsOnlyItsOpenPagesAndTheirPath() {
        let asleep = site("Asleep")
        let open = site("Open")
        let nested = Bookmark.folder("Nested", [asleep, open])
        let outer = Bookmark.folder("Outer", [site("Shut"), nested])

        let closed = Shelf.lines([outer], open: [], active: [open.id])
        #expect(closed.map(\.node.id) == [outer.id, nested.id, open.id])
        #expect(closed.map(\.depth) == [0, 1, 2])
        let expanded = Shelf.lines([outer], open: [outer.id, nested.id], active: [open.id])
        #expect(expanded.count == 5)
        #expect(expanded.contains { $0.node.id == asleep.id })
    }

    @Test func theCentreMergesBookmarksButTheEdgesReorderAndTabsCannotMerge() {
        let source = site("Source")
        let target = site("Target")
        let folder = Bookmark.folder("Folder", [])
        let lines = Shelf.lines([source, target, folder], open: [])
        let measure = Shelf.Measure(ChromeMetrics(size: .standard))
        let targetTop = measure.heading + measure.gap + measure.row + measure.gap
        let middle = Shelf.drop(at: targetTop + measure.row / 2,
                                lines: lines, carrying: source.id, measure: measure)
        #expect(middle?.merge == target.id)
        #expect(middle?.into == nil)
        let before = Shelf.drop(at: targetTop + measure.row * 0.1,
                                lines: lines, carrying: source.id, measure: measure)
        #expect(before?.before == target.id)
        #expect(before?.merge == nil)
        let tab = Shelf.drop(at: targetTop + measure.row / 2,
                             lines: lines, carrying: nil, measure: measure)
        #expect(tab?.merge == nil)
        let distant = Shelf.drop(at: targetTop + measure.row / 2,
                                 lines: lines, carrying: nil, measure: measure, carriedSite: true)
        #expect(distant?.merge == target.id)
        let carriedFolder = Shelf.drop(at: targetTop + measure.row / 2,
                                       lines: lines, carrying: folder.id, measure: measure)
        #expect(carriedFolder?.merge == nil)
        let folderTop = targetTop + measure.row + measure.gap
        let into = Shelf.drop(at: folderTop + measure.row / 2,
                              lines: lines, carrying: source.id, measure: measure)
        #expect(into?.into == folder.id)
    }

    @Test func leavingAHoverInvalidatesItsDelayedCommit() async throws {
        let hover = HoverDwell()
        let source = UUID()
        let target = UUID()
        var commits = 0
        hover.aim(source: source, at: target) { commits += 1 }
        hover.cancel()
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(!hover.accepts(source: source, target: target))
        #expect(hover.target == nil)
        #expect(commits == 0)

        hover.aim(source: source, at: target) { commits += 1 }
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(hover.accepts(source: source, target: target))
        #expect(commits == 1)
        hover.cancel()
    }
}
