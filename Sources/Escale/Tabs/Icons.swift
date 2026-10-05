import SwiftUI
import WebKit

// A site's own icon, for the tabs that are set to wear one.
//
// WebKit doesn't hand these over, so the page is asked what it declares and
// the best of those is fetched once and kept as a small PNG next to the
// history. A tab brought back from yesterday's session has its icon before it
// has a page; a tab on a site never seen before shows a letter until the icon
// arrives, which is a second or so.
//
// Everything here is a cache, and each part has a bound. An icon is
// kept at the size it is drawn — 16 points everywhere, tab, list or menu:
// 32 × 32 pixels, 4 KiB in memory. At most 1,000 are held, the least
// recently used let go first — 4 MiB at worst; a tab keeps the one it wears
// whatever happens here. On disk, at most 1,000 files too (1 to 2 KB each),
// the ones fetched longest ago removed first; a bookmark whose icon went
// shows its letter until the site is visited again. The two caps are the
// same on purpose: every icon on disk fits in memory, so a list of more sites
// than one screen — the shelf, drawn again at each change of the window —
// reads each from disk once in a run, never at every drawing. Hosts given
// up on are remembered 500 at a time.
//
// A list never reads the disk while it is drawn. `shown` answers from
// memory alone and queues what is missing: the files are read on a utility
// queue, in batches of at most 64 and no more than 1,000 waiting, and the
// lists hear of them through `arrivals`, once the queue is drained or every
// 0.25 s, so a long shelf draws its letters first and its icons a moment later
// instead of stopping on each file. A key with no file is remembered (as many
// as the icons held: in the dark every site asks for its dark variant too) so
// it is not looked for at every drawing. A tab, which wears one icon and has no
// list to hold up, still reads its own through `cached`.
//
// Fetching: two icons at a time, sixteen more waiting at most; one whose tab
// has moved on to another site before its turn is dropped, not fetched. A
// body is read as it arrives and cut past 2 MB, refused at once if it says
// it is bigger, and a fetch gives up after 15 s altogether — a server that
// trickles a byte now and then never holds a place for good. Critical memory
// pressure lets every icon held in memory go (see Browser.pressed).
// The PNG carries a raster version: old 32-pixel files drew only their
// lower-left quarter, recovered on read without refetching or rewriting them.

@MainActor
final class Favicons: ObservableObject {
    static let shared = Favicons()

    /// Counts the batches of icons that reached memory, for the lists drawing
    /// them (`SiteMark`): the number itself means nothing.
    @Published private(set) var arrivals = 0

    /// Called with a host and its icon whenever one arrives, so every tab on
    /// that host can put it on at once.
    var arrived: ((String, NSImage) -> Void)?

    /// The bounds. `icons.memory` and `icons.files` change the first two for
    /// the bench, the way `sleep.after` does the half hour.
    static var memoryCap: Int { Store.settings.integer(forKey: "icons.memory").nonZero ?? 1_000 }
    static var filesCap: Int { Store.settings.integer(forKey: "icons.files").nonZero ?? 1_000 }
    static let missingCap = 500
    static let atOnce = 2
    static let waitingCap = 16
    /// The most files read before the lists are told.
    static let batch = 64
    /// The most a body may weigh, and the most places asked per site.
    nonisolated static let limit = 2_000_000
    static let tries = 4

    private var memory = Recent<NSImage>(cap: Favicons.memoryCap)
    private var busy: Set<String> = []
    private var missing = Recent<Bool>(cap: Favicons.missingCap)
    /// Keys whose file was looked for and not found, and the keys waiting to
    /// be read (`queued` holds the same, to ask once).
    private var absent = Recent<Bool>(cap: Favicons.memoryCap)
    private var unread: [String] = []
    private var queued: Set<String> = []
    private var reading = false
    private var pending = false
    private var signalled = Date.distantPast

    /// A fetch waiting for its turn. The tab is held weakly and asked again
    /// when the turn comes: gone, or on another site, and it is dropped.
    private struct Job {
        let host: String
        let key: String
        let candidates: [URL]
        let shy: Bool
        weak var tab: Tab?

        @MainActor var wanted: Bool { tab?.address?.host()?.lowercased() == host }
    }
    private var waiting: [Job] = []
    private var fetching = 0

    /// One session for every fetch, holding nothing between them: no cache,
    /// no cookies. (A session made per fetch and never invalidated was
    /// never let go either.)
    nonisolated private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.urlCache = nil
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    /// Writes and the trimming of the folder, in order, off the main thread.
    private let disk = Drawer(folder: Favicons.folder)

    /// What is held, for `bench caches`: icons in memory, hosts given up
    /// on, hosts being fetched or waiting, and the files and bytes on disk.
    var counts: [String: Int] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Favicons.folder, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return ["memory": memory.count, "missing": missing.count, "absent": absent.count, "unread": unread.count,
                "busy": busy.count,
                "fetching": fetching, "waiting": waiting.count,
                "files": files.count, "fileBytes": bytes]
    }

    /// Critical memory pressure: the icons held here go. Tabs keep theirs.
    func shed() {
        memory.removeAll()
    }

    private static var folder: URL { Store.folder.appendingPathComponent("icons", isDirectory: true) }
    private static func file(_ key: String) -> URL { folder.appendingPathComponent(key + ".png") }

    /// Whether the chrome is dark right now. A site that declares an icon
    /// for `prefers-color-scheme: dark` is asked for that one, and it is
    /// kept apart from the light one, so switching looks switches icons.
    static var dark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The name an icon is kept under: the host, with a suffix for the dark
    /// variant a site offered. Sites without one keep one file for both.
    private static func key(_ host: String, dark: Bool) -> String { dark ? host + "@dark" : host }

    /// What is already known, and nothing fetched. In the dark, the dark
    /// variant when there is one, the ordinary icon otherwise.
    func cached(_ host: String) -> NSImage? {
        if Favicons.dark, let hit = known(Favicons.key(host, dark: true)) { return hit }
        return known(host)
    }

    private func known(_ key: String) -> NSImage? {
        if let hit = memory.get(key) { return hit }
        guard let image = Favicons.read(Favicons.file(key)) else { return nil }
        remember(key, image)
        return image
    }

    /// What is in memory now, for a list drawing its rows: never the disk. A
    /// key that is neither held nor known to have no file is queued to be read,
    /// and `arrivals` changes when it has been.
    func shown(_ host: String) -> NSImage? {
        for key in Favicons.dark ? [Favicons.key(host, dark: true), host] : [host] {
            if let hit = memory.get(key) { return hit }
            ask(key)
        }
        return nil
    }

    private func remember(_ key: String, _ image: NSImage) {
        memory.set(key, image)
        absent.remove(key)
    }

    private func ask(_ key: String) {
        guard !absent.contains(key), !queued.contains(key), unread.count < Favicons.memoryCap else { return }
        queued.insert(key)
        unread.append(key)
        guard !reading else { return }
        reading = true
        // After the drawing that asked, so nothing here changes what it draws.
        DispatchQueue.main.async { [self] in readNext() }
    }

    private func readNext() {
        let batch = Array(unread.prefix(Favicons.batch))
        unread.removeFirst(batch.count)
        let files = batch.map { ($0, Favicons.file($0)) }
        DispatchQueue.global(qos: .utility).async {
            let found = files.map { ($0.0, Favicons.read($0.1)) }
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated { land(found) }
            }
        }
    }

    private func land(_ found: [(String, NSImage?)]) {
        var gained = false
        for (key, image) in found {
            queued.remove(key)
            // A fetch may have brought a newer one meanwhile.
            if memory.contains(key) { continue }
            if let image { remember(key, image); gained = true } else { absent.set(key, true) }
        }
        pending = pending || gained
        // One signal when the queue is drained, or every 0.25 s while it is
        // long: each one draws every list again.
        if pending, unread.isEmpty || Date().timeIntervalSince(signalled) > 0.25 {
            arrivals += 1
            pending = false
            signalled = Date()
        }
        if unread.isEmpty { reading = false } else { readNext() }
    }

    /// The size an icon is drawn at, and the pixels kept for it.
    nonisolated static let points: CGFloat = 16
    nonisolated static let pixels = 32
    nonisolated private static let rasterVersion = "Escale favicon 2"

    /// A kept icon, decoded at the size it is drawn — a file written before
    /// icons were kept this small is 128 pixels, and would hold 64 KiB.
    nonisolated static func read(_ file: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: pixels,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary)
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let png = properties?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        // The old 32-pixel writer drew in 16-pixel coordinates: its complete
        // canvas is the lower-left quarter. Recover that canvas, not the
        // artwork's alpha bounds, so intentional padding remains intact.
        // Older 128-pixel files used lockFocus and were already centered.
        if properties?[kCGImagePropertyPixelWidth] as? Int == pixels,
           properties?[kCGImagePropertyPixelHeight] as? Int == pixels,
           png?[kCGImagePropertyPNGSoftware] as? String != rasterVersion,
           let canvas = image.cropping(to: CGRect(x: 0, y: pixels / 2,
                                                  width: pixels / 2, height: pixels / 2)) {
            return NSImage(cgImage: canvas, size: NSSize(width: points, height: points))
        }
        return NSImage(cgImage: image, size: NSSize(width: points, height: points))
    }

    private static func fresh(_ key: String) -> Bool {
        guard let stamp = try? file(key).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return false }
        return Date().timeIntervalSince(stamp) < 7 * 86_400
    }

    /// The look changed: every tab puts on the icon that goes with it, and
    /// asks again for one where the site may have a variant not yet seen.
    func relook(_ tabs: [Tab]) {
        missing.removeAll()
        absent.removeAll()
        for tab in tabs {
            guard let host = tab.address?.host()?.lowercased() else { continue }
            tab.icon = cached(host)
            fetch(for: tab)
        }
    }

    /// An icon from somewhere else — another browser's cache, at import —
    /// kept as if the site had handed it over, unless one is already here.
    func adopt(_ data: Data, for host: String) async {
        guard cached(host) == nil, let image = await Favicons.square(data) else { return }
        remember(host, image)
        keep(image, for: host)
        arrived?(host, image)
        arrivals += 1
    }

    /// Asks the page which icon it wants to be known by, fetches it, and keeps
    /// it. Nothing happens if a fresh one is already on disk.
    func fetch(for tab: Tab) {
        // The page is asked, so only a page that exists: never built for this.
        guard let web = tab.built, let url = tab.address, let host = url.host()?.lowercased(),
              url.scheme?.hasPrefix("http") == true
        else { return }

        let dark = Favicons.dark
        // Fresh and right for this look: nothing to do. In the dark, a fresh
        // light icon is not enough on its own — the site may offer a dark
        // one that has never been asked for — so the page is asked.
        if Favicons.fresh(Favicons.key(host, dark: dark)), let known = known(Favicons.key(host, dark: dark)) {
            tab.icon = known
            return
        }
        guard !busy.contains(host), !missing.contains(host) else { return }
        busy.insert(host)

        web.evaluateJavaScript(Favicons.probe) { [weak self, weak tab] answer, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let declared = (answer as? [[String: String]]) ?? []
                let offersDark = declared.contains { Favicons.media($0["media"]) == .dark }
                let wantDark = dark && offersDark
                let key = Favicons.key(host, dark: wantDark)
                // No dark variant here after all, and the ordinary one is
                // fresh: it is the one to wear.
                if !wantDark, Favicons.fresh(key), let known = self.known(key) {
                    tab?.icon = known
                    self.busy.remove(host)
                    return
                }
                let candidates = Array(Favicons.rank(declared, page: url, dark: wantDark).prefix(Favicons.tries))
                self.line(Job(host: host, key: key, candidates: candidates, shy: tab?.shy ?? false, tab: tab))
            }
        }
    }

    /// Into the line. Past sixteen waiting, the one waiting longest goes:
    /// its site will be asked again the next time a page there finishes.
    private func line(_ job: Job) {
        waiting.append(job)
        while waiting.count > Favicons.waitingCap {
            busy.remove(waiting.removeFirst().host)
        }
        next()
    }

    /// Starts what waits while fewer than two fetches are under way.
    private func next() {
        while fetching < Favicons.atOnce, !waiting.isEmpty {
            let job = waiting.removeFirst()
            guard job.wanted else {
                busy.remove(job.host)
                continue
            }
            fetching += 1
            Task {
                await download(job)
                fetching -= 1
                next()
            }
        }
    }

    private enum Scheme { case any, light, dark }

    /// What a `media` attribute says about the scheme, if anything.
    private static func media(_ value: String?) -> Scheme {
        let text = (value ?? "").lowercased()
        if text.contains("prefers-color-scheme") {
            if text.contains("dark") { return .dark }
            if text.contains("light") { return .light }
        }
        return .any
    }

    private func download(_ job: Job) async {
        defer { busy.remove(job.host) }
        for candidate in job.candidates {
            // The tab went elsewhere meanwhile: the rest can wait for a visit.
            guard job.wanted else { return }
            guard let data = await Favicons.body(candidate),
                  let image = await Favicons.square(data)
            else { continue }
            remember(job.key, image)
            if !job.shy { keep(image, for: job.key) }
            arrived?(job.host, image)
            arrivals += 1
            return
        }
        // Not asked again this session: hammering a site for an icon it
        // doesn't have is exactly the kind of thing a quiet browser doesn't do.
        missing.set(job.host, true)
    }

    /// The body at `url`, read as it comes, or nil: an error status, a
    /// length announced past the limit, a body that runs past it (cut there,
    /// not read to its end), too small to be an icon, or no answer in time.
    /// Off the main thread, which it would otherwise hold a byte at a time.
    nonisolated private static func body(_ url: URL) async -> Data? {
        guard let (bytes, response) = try? await session.bytes(from: url) else { return nil }
        let expected = response.expectedContentLength
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) || expected > limit {
            bytes.task.cancel()
            return nil
        }
        var data = Data()
        data.reserveCapacity(expected > 0 ? Int(expected) : 16_384)
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit {
                    bytes.task.cancel()
                    return nil
                }
            }
        } catch {
            return nil
        }
        return data.count > 60 ? data : nil
    }

    /// Decoded and drawn into a square off the main thread — an .ico can hold
    /// a dozen sizes and take a moment to unpack. Into a bitmap of its own,
    /// 32 pixels a side, rather than one at whatever the screen's scale is.
    static func square(_ data: Data) async -> NSImage? {
        await Task.detached(priority: .utility) { () -> NSImage? in
            guard let image = NSImage(data: data), image.isValid,
                  image.size.width > 0, image.size.height > 0,
                  let bitmap = NSBitmapImageRep(
                      bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                  ),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap)
            else { return nil }
            // A bitmap context draws in pixels; changing bitmap.size does
            // not scale its coordinates. Set the point size after drawing.
            let side = CGFloat(pixels)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            let scale = min(side / image.size.width, side / image.size.height)
            let w = image.size.width * scale
            let h = image.size.height * scale
            image.draw(
                in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            NSGraphicsContext.restoreGraphicsState()
            bitmap.size = NSSize(width: points, height: points)
            let out = NSImage(size: bitmap.size)
            out.addRepresentation(bitmap)
            return out
        }.value
    }

    private func keep(_ image: NSImage, for key: String) {
        guard let png = Favicons.png(image) else { return }
        disk.write(png, to: Favicons.file(key), cap: Favicons.filesCap)
    }

    /// The per-file version distinguishes corrected pixels from old cache entries.
    static func png(_ image: NSImage) -> Data? {
        guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, bitmap, [
            kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGSoftware: rasterVersion],
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Best first. A crisp icon around 32–64 pixels is what a tab wants; the
    /// touch icon is a fine second; the file at the root is the fallback every
    /// site has had since 1999.
    private static func rank(_ declared: [[String: String]], page: URL, dark: Bool) -> [URL] {
        var scored: [(URL, Int)] = []
        for entry in declared {
            guard let href = entry["href"], let url = URL(string: href),
                  url.scheme?.hasPrefix("http") == true
            else { continue }
            let rel = entry["rel"] ?? ""
            let sizes = entry["sizes"] ?? ""
            let type = entry["type"] ?? ""
            // An icon meant for the other scheme is the last resort; one
            // meant for this scheme comes first whatever its size.
            let scheme = media(entry["media"])
            if scheme == (dark ? .light : .dark) { continue }
            var score = 25
            if rel.contains("apple-touch") { score = 40 }
            if let px = sizes.split(separator: " ").compactMap({ Int($0.split(separator: "x").first ?? "") }).max() {
                switch px {
                case ..<24: score = 10
                case 24..<48: score = 45
                case 48..<128: score = 50
                case 128..<260: score = 42
                default: score = 20
                }
            }
            if sizes == "any" || type.contains("svg") || url.pathExtension.lowercased() == "svg" { score = 35 }
            if scheme != .any { score += 40 }
            scored.append((url, score))
        }
        var list = scored.sorted { $0.1 > $1.1 }.map(\.0)
        if let host = page.host(), let root = URL(string: "\(page.scheme ?? "https")://\(host)/favicon.ico") {
            list.append(root)
        }
        // The same address twice is a wasted request.
        var seen = Set<String>()
        return list.filter { seen.insert($0.absoluteString).inserted }
    }

    private static let probe = Bundled.script("favicon-probe.js")
}

/// A few values by key, at most `cap`: past it, the one used longest ago
/// goes. Exact, and linear in `cap` when full — a few hundred at most here.
struct Recent<Value> {
    let cap: Int
    private var values: [String: (value: Value, used: Int)] = [:]
    private var clock = 0

    init(cap: Int) { self.cap = max(1, cap) }

    var count: Int { values.count }

    func contains(_ key: String) -> Bool { values[key] != nil }

    /// The value, now the most recently used.
    mutating func get(_ key: String) -> Value? {
        guard let hit = values[key] else { return nil }
        clock += 1
        values[key] = (hit.value, clock)
        return hit.value
    }

    mutating func set(_ key: String, _ value: Value) {
        clock += 1
        values[key] = (value, clock)
        while values.count > cap, let oldest = values.min(by: { $0.value.used < $1.value.used })?.key {
            values[oldest] = nil
        }
    }

    mutating func remove(_ key: String) { values[key] = nil }

    mutating func removeAll() { values = [:] }
}

/// The icons folder: writes in the order they were asked for, and the
/// oldest files removed once there are more than the cap. The count is
/// taken from the folder once, at the first write of a run, and kept up by
/// the writes after it; the folder is listed again only to trim, down to
/// nine tenths of the cap, so a trim is paid once per hundred new sites.
final class Drawer {
    private let folder: URL
    private let queue = DispatchQueue(label: "escale.icons", qos: .utility)
    /// Files in the folder, once known. Only touched on `queue`.
    private var files: Int?

    init(folder: URL) { self.folder = folder }

    func write(_ png: Data, to file: URL, cap: Int) {
        queue.async { [self] in
            let manager = FileManager.default
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let known = files ?? ((try? manager.contentsOfDirectory(atPath: folder.path).count) ?? 0)
            let new = !manager.fileExists(atPath: file.path)
            guard (try? png.write(to: file, options: .atomic)) != nil else {
                files = known
                return
            }
            files = known + (new ? 1 : 0)
            if let count = files, count > cap { files = trim(to: cap) }
        }
    }

    /// Removes the files fetched longest ago and says how many are left.
    private func trim(to cap: Int) -> Int {
        let manager = FileManager.default
        let listed = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dated = listed.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        let old = Drawer.overflow(dated, cap: cap)
        var removed = 0
        for file in old where (try? manager.removeItem(at: file)) != nil { removed += 1 }
        return listed.count - removed
    }

    /// Which files go when `files` holds more than `cap`: the oldest, down
    /// to nine tenths of it. None while within the cap.
    static func overflow(_ files: [(URL, Date)], cap: Int) -> [URL] {
        guard files.count > cap else { return [] }
        let keep = cap * 9 / 10
        return files.sorted { $0.1 < $1.1 }.prefix(files.count - keep).map(\.0)
    }
}

private extension Int {
    /// Nil for zero: a setting that was never written.
    var nonZero: Int? { self > 0 ? self : nil }
}

/// What stands for a page when there is no room for its title: the site's
/// icon if there is one, and a letter in a faint square until there is.
/// A site's icon in a list: what memory holds now, and a letter until the
/// rest has been read (see `Favicons.shown`).
struct SiteMark: View {
    let host: String
    let letter: String
    var size: CGFloat = 16
    var dim = false

    @ObservedObject private var favicons = Favicons.shared

    var body: some View {
        Mark(icon: favicons.shown(host), letter: letter, size: size, dim: dim)
    }
}

struct Mark: View {
    let icon: NSImage?
    let letter: String
    var size: CGFloat = 16
    var dim = false

    var body: some View {
        let artwork = size * Metrics.faviconScale
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: artwork, height: artwork)
                    .clipShape(RoundedRectangle(cornerRadius: artwork * 0.22, style: .continuous))
                    .frame(width: size, height: size)
            } else {
                Text(letter)
                    .font(.system(size: size * 0.56, weight: .regular))
                    .foregroundStyle(Palette.muted)
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                            .fill(Palette.ink.opacity(0.06))
                    )
            }
        }
        .opacity(dim ? 0.45 : 1)
        .transition(.opacity)
        .animation(Motion.quick, value: icon == nil)
    }
}
