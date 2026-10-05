import AppKit
import Testing
@testable import Escale

// The icon cache's two bounds: what memory lets go of first, and which
// files leave the folder. Pixel assertions also protect the artwork inside
// that allocation: a 32-pixel bitmap alone did not catch a half-size drawing.
// The folder's own writes and fetches run in Tests/Bench/icon_cache.py.

@Suite struct RecentTests {
    @Test func holdsNoMoreThanItsCap() {
        var recent = Recent<Int>(cap: 3)
        for i in 0..<10 { recent.set("h\(i)", i) }
        #expect(recent.count == 3)
        #expect(recent.contains("h9") && recent.contains("h8") && recent.contains("h7"))
        #expect(!recent.contains("h0"))
    }

    @Test func aValueUsedIsKeptOverOnesUsedLongerAgo() {
        var recent = Recent<Int>(cap: 3)
        recent.set("a", 1)
        recent.set("b", 2)
        recent.set("c", 3)
        #expect(recent.get("a") == 1)
        recent.set("d", 4)
        #expect(recent.contains("a"))
        #expect(!recent.contains("b"))
        #expect(recent.contains("c") && recent.contains("d"))
    }

    @Test func setAgainReplacesWithoutGrowing() {
        var recent = Recent<Int>(cap: 2)
        recent.set("a", 1)
        recent.set("a", 2)
        #expect(recent.count == 1)
        #expect(recent.get("a") == 2)
    }

    @Test func aMissIsNil() {
        var recent = Recent<Int>(cap: 2)
        #expect(recent.get("nothing") == nil)
        recent.set("a", 1)
        recent.removeAll()
        #expect(recent.count == 0)
        #expect(recent.get("a") == nil)
    }

    @Test(arguments: [0, -5])
    func aCapBelowOneStillHoldsOne(cap: Int) {
        var recent = Recent<Int>(cap: cap)
        recent.set("a", 1)
        recent.set("b", 2)
        #expect(recent.count == 1)
        #expect(recent.contains("b"))
    }
}

@Suite struct DrawerTests {
    private func files(_ n: Int) -> [(URL, Date)] {
        // Newest first, as a folder listing might return them.
        (0..<n).reversed().map { i in
            (URL(fileURLWithPath: "/icons/h\(i).png"), Date(timeIntervalSince1970: TimeInterval(i * 60)))
        }
    }

    @Test(arguments: [0, 1, 99, 100])
    func nothingGoesWithinTheCap(count: Int) {
        #expect(Drawer.overflow(files(count), cap: 100).isEmpty)
    }

    @Test func pastTheCapTheOldestGoDownToNineTenths() {
        let gone = Drawer.overflow(files(101), cap: 100)
        #expect(gone.count == 11)
        #expect(Set(gone.map(\.lastPathComponent)) == Set((0..<11).map { "h\($0).png" }))
    }

    @Test func farPastTheCapStillEndsAtNineTenths() {
        #expect(Drawer.overflow(files(500), cap: 48).count == 500 - 43)
    }
}

// An icon is kept at the size it is drawn, so that every icon on disk fits
// within the memory cap (4 KiB each, not the 64 KiB of a 128-pixel one).
@Suite @MainActor struct IconSizeTests {
    /// A synthetic canvas with explicit transparent padding when requested.
    private func png(_ side: Int, height: Int? = nil, paint: CGRect? = nil) -> Data? {
        let height = height ?? side
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        let colour = NSColor(deviceRed: 0.2, green: 0.6, blue: 0.8, alpha: 1)
        let clear = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0)
        for y in 0..<height {
            for x in 0..<side {
                let filled = paint?.contains(CGPoint(x: x, y: y)) ?? true
                bitmap.setColor(filled ? colour : clear, atX: x, y: y)
            }
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func pixels(_ image: NSImage?) -> [Int] {
        image?.representations.map { $0.pixelsWide } ?? []
    }

    @Test(arguments: [16, 128, 512])
    func aFetchedIconIsDrawnInto32Pixels(side: Int) async throws {
        let data = try #require(png(side))
        let image = await Favicons.square(data)
        #expect(image?.size == NSSize(width: 16, height: 16))
        #expect(pixels(image) == [32])
    }

    @Test func notAnImageIsNothing() async {
        #expect(await Favicons.square(Data(repeating: 7, count: 4096)) == nil)
    }

    @Test func aSolidIconFillsTheCanvas() async throws {
        let data = try #require(png(32))
        let image = try #require(await Favicons.square(data))
        let bitmap = try #require(image.representations.first as? NSBitmapImageRep)
        var opaque = 0
        for y in 0..<32 {
            for x in 0..<32 {
                if try #require(bitmap.colorAt(x: x, y: y)).alphaComponent > 0.99 { opaque += 1 }
            }
        }
        #expect(opaque == 32 * 32)
    }

    private func bounds(_ image: NSImage) throws -> CGRect {
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cg)
        var xs: [Int] = [], ys: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if try #require(bitmap.colorAt(x: x, y: y)).alphaComponent > 0.5 {
                    xs.append(x); ys.append(y)
                }
            }
        }
        let left = try #require(xs.min()), top = try #require(ys.min())
        let right = try #require(xs.max()), bottom = try #require(ys.max())
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }

    @Test(arguments: [true, false])
    func rectangularArtworkStaysCentered(wide: Bool) async throws {
        let data = try #require(png(wide ? 64 : 32, height: wide ? 32 : 64))
        let image = try #require(await Favicons.square(data))
        #expect(try bounds(image) == (wide
            ? CGRect(x: 0, y: 8, width: 32, height: 16)
            : CGRect(x: 8, y: 0, width: 16, height: 32)))
    }

    @Test func correctedCachePreservesIntentionalPaddingOnRepeatedReads() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("escale-icon-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let corner = CGRect(x: 0, y: 16, width: 16, height: 16)
        let data = try #require(png(32, paint: corner))
        let image = try #require(await Favicons.square(data))
        let encoded = try #require(Favicons.png(image))
        try encoded.write(to: file)
        for _ in 0..<2 {
            let read = try #require(Favicons.read(file))
            #expect(try bounds(read) == corner)
            #expect(read.size == NSSize(width: 16, height: 16))
        }
    }

    @Test func legacyCacheRecoversItsCanvasWithoutRemovingArtworkPadding() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("escale-icon-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        // A centered 8×8 drawing inside the old lower-left 16×16 canvas.
        let data = try #require(png(32, paint: CGRect(x: 4, y: 20, width: 8, height: 8)))
        try data.write(to: file)
        let image = try #require(Favicons.read(file))
        #expect(try bounds(image) == CGRect(x: 4, y: 4, width: 8, height: 8))
        #expect(image.size == NSSize(width: 16, height: 16))
        #expect(try Data(contentsOf: file) == data)
    }

    @Test func aFileKeptAt128PixelsIsReadBackAt32() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("escale-icon-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try #require(png(128)).write(to: file)
        let image = Favicons.read(file)
        #expect(image?.size == NSSize(width: 16, height: 16))
        #expect(image.flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }?.width == 32)
    }

    @Test func noFileIsNothing() {
        #expect(Favicons.read(URL(fileURLWithPath: "/nonexistent/escale-icon.png")) == nil)
    }
}

// A list asks for icons while it is drawn: it must get what memory holds and
// nothing from the disk, then hear when the rest has been read.
@Suite @MainActor struct IconListTests {
    private func png() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<32 { for x in 0..<32 { bitmap.setColor(.systemBlue, atX: x, y: y) } }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func settle(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
        #expect(condition(), Comment(rawValue: what))
    }

    @Test func aFileOnDiskIsNotReadWhileDrawing() async throws {
        _ = NSApplication.shared
        let favicons = Favicons.shared
        let host = "list-\(UUID().uuidString.lowercased()).localhost"
        let folder = Store.folder.appendingPathComponent("icons", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(host + ".png")
        try png().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let before = favicons.arrivals
        #expect(favicons.shown(host) == nil)
        try await settle("the icon is read in the background") { favicons.shown(host) != nil }
        #expect(favicons.arrivals > before)
        #expect(favicons.shown(host)?.size == NSSize(width: 16, height: 16))
    }

    @Test func aSiteWithNoFileIsNotLookedForAtEveryDrawing() async throws {
        _ = NSApplication.shared
        let favicons = Favicons.shared
        let host = "none-\(UUID().uuidString.lowercased()).localhost"
        let before = favicons.counts["absent"] ?? 0
        #expect(favicons.shown(host) == nil)
        try await settle("the miss is remembered") { (favicons.counts["absent"] ?? 0) > before }
        let known = favicons.counts["absent"] ?? 0
        for _ in 0..<20 { #expect(favicons.shown(host) == nil) }
        #expect(favicons.counts["unread"] == 0)
        #expect(favicons.counts["absent"] == known)
    }
}
