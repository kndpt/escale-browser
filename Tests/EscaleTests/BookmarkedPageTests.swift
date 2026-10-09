import Foundation
import Testing
@testable import Escale

// The page on screen is a bookmark when its exact address is kept in this
// Space's list, at any depth. Each Space keeps its own file, written in a
// temporary folder here, so one Space's bookmark never marks another's page.
@Suite @MainActor struct BookmarkedPageTests {
    private func site(_ title: String, _ address: String) -> Bookmark {
        Bookmark(title: title, url: address, children: nil)
    }

    @Test func aPageMatchesItsBookmarkInNestedFolders() throws {
        let deep = site("Deep", "https://deep.example.test/page")
        let inner = Bookmark.folder("Inner", [deep])
        let outer = Bookmark.folder("Outer", [site("Top", "https://top.example.test/"), inner])
        let index = Bookmarks.byAddress([outer])

        #expect(index["https://deep.example.test/page"]?.id == deep.id)
        #expect(index["https://top.example.test/"]?.title == "Top")
        #expect(index["https://deep.example.test/page/"] == nil)
        #expect(index["https://deep.example.test/"] == nil)
        #expect(index.count == 2, "folders are not pages")
        #expect(Bookmarks.path(to: deep.id, in: [outer]) == [outer.id, inner.id])
        #expect(Bookmarks.path(to: outer.id, in: [outer]) == [])
        #expect(Bookmarks.path(to: UUID(), in: [outer]) == nil)
    }

    @Test func aPageKeptTwiceIsTheFirstInTheList() {
        let first = site("First", "https://twice.example.test/")
        let nested = site("Nested", "https://twice.example.test/")
        let index = Bookmarks.byAddress([.folder("Folder", [first]), nested])
        #expect(index["https://twice.example.test/"]?.id == first.id)
    }

    @Test func onlyTheCurrentSpaceListMarksThePageAndItFollowsEdits() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookmarked-page-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let page = try #require(URL(string: "https://kept.example.test/docs"))
        let here = Bookmarks(space: UUID(), file: folder.appendingPathComponent("here.json"))
        let there = Bookmarks(space: UUID(), file: folder.appendingPathComponent("there.json"))

        #expect(here.bookmark(for: page) == nil)
        here.insert(.folder("Work", [site("Docs", page.absoluteString)]), into: nil)
        let kept = try #require(here.bookmark(for: page))
        #expect(kept.title == "Docs")
        #expect(there.bookmark(for: page) == nil)

        here.update(kept.id, title: "Renamed", url: nil)
        #expect(here.bookmark(for: page)?.title == "Renamed")
        here.remove(kept.id)
        #expect(here.bookmark(for: page) == nil)
        #expect(!here.contains(page))
        Writer.to(folder.appendingPathComponent("here.json")).flush()
    }
}
