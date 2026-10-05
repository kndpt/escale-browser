import AppKit
import WebKit
import Combine

// Files pages and extensions are still sending to disk.
//
// A download outlives the page that started it: closing that tab, or parking
// its space, must not release WebKit's download or redirect its file into the
// space showing when the destination is chosen. One owner therefore retains
// every active download with its original space until WebKit reports success
// or failure. There is no polling or background queue; one entry exists only
// for each transfer WebKit is already doing.

@MainActor
final class Downloads: NSObject, ObservableObject, WKDownloadDelegate {
    private let loot: (UUID) -> Loot?
    private let asksWhere: () -> Bool
    private let folder: (UUID) -> URL?
    private let announce: (String) -> Void

    struct Transfer: Identifiable, Equatable {
        let id: ObjectIdentifier
        let space: UUID
        var name: String
        var fraction: Double?
    }

    // Session-only visibility survives completion, cancellation and Space changes.
    @Published private(set) var hasStarted = false
    @Published private(set) var transfers: [Transfer] = []
    private var progress: [ObjectIdentifier: AnyCancellable] = [:]
    private var active: [WKDownload] = []

    /// An unknown total makes a global percentage misleading. Otherwise every
    /// file contributes equally, regardless of byte size.
    nonisolated static func fraction(_ values: [Double?]) -> Double? {
        guard !values.isEmpty else { return nil }
        let known = values.compactMap { $0 }
        guard known.count == values.count, known.allSatisfy({ $0.isFinite }) else { return nil }
        return known.reduce(0) { $0 + min(1, max(0, $1)) } / Double(known.count)
    }

    var fraction: Double? { Self.fraction(transfers.map(\.fraction)) }
    var observationCount: Int { progress.count }
    private var spaces: [ObjectIdentifier: UUID] = [:]
    private var names: [URL: String] = [:]

    /// On-demand test/resource evidence; reading it starts no work.
    var count: Int { active.count }

    init(
        loot: @escaping (UUID) -> Loot?,
        asksWhere: @escaping () -> Bool,
        folder: @escaping (UUID) -> URL?,
        announce: @escaping (String) -> Void
    ) {
        self.loot = loot
        self.asksWhere = asksWhere
        self.folder = folder
        self.announce = announce
    }

    /// An extension may choose the filename, but never the folders it carries.
    func name(_ name: String, for url: URL) {
        names[url] = (name as NSString).lastPathComponent
    }

    /// Retained until WebKit reports success or failure, independently of the
    /// initiating page's lifetime.
    func keep(_ download: WKDownload, in space: UUID) {
        guard !active.contains(where: { $0 === download }) else { return }
        download.delegate = self
        active.append(download)
        hasStarted = true
        let id = ObjectIdentifier(download)
        spaces[id] = space
        transfers.append(Transfer(id: id, space: space,
                                  name: download.originalRequest?.url?.lastPathComponent ?? "Download",
                                  fraction: nil))
        // Two KVO inputs, one bounded publication per 100 ms per active file.
        // No idle timer. Cancelling the subscription drops pending updates;
        // the identity guard also rejects a callback already on the queue.
        progress[id] = download.progress.publisher(for: \.completedUnitCount)
            .combineLatest(download.progress.publisher(for: \.totalUnitCount))
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] completed, total in
                guard let self, let index = self.transfers.firstIndex(where: { $0.id == id }) else { return }
                let fraction = total > 0 ? min(1, max(0, Double(completed) / Double(total))) : nil
                if self.transfers[index].fraction != fraction { self.transfers[index].fraction = fraction }
            }
    }

    /// Deleting a Space cannot redirect a still-running transfer to the
    /// application's default download folder when its destination is chosen.
    func cancel(in space: UUID) {
        for download in active where spaces[ObjectIdentifier(download)] == space {
            cancel(ObjectIdentifier(download))
        }
    }

    func cancel(_ id: ObjectIdentifier) {
        guard let download = active.first(where: { ObjectIdentifier($0) == id }) else { return }
        // WebKit does not promise a failure delegate call for explicit cancel.
        download.cancel { _ in }
        stop(download)
    }

    /// A page sending a file cannot sleep until WebKit has finished with it.
    func isActive(on webView: WKWebView) -> Bool {
        active.contains { $0.webView === webView }
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let asked = response.url.flatMap { names.removeValue(forKey: $0) }
        let name = asked ?? (suggestedFilename.isEmpty ? "download" : suggestedFilename)
        if let index = transfers.firstIndex(where: { $0.id == ObjectIdentifier(download) }) {
            transfers[index].name = name
        }
        guard let space = spaces[ObjectIdentifier(download)], let folder = folder(space) else {
            stop(download)
            completionHandler(nil)
            return
        }

        guard !asksWhere() else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.directoryURL = folder
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url,
                  spaces[ObjectIdentifier(download)] != nil else {
                stop(download)
                completionHandler(nil)
                return
            }
            completionHandler(url)
            announce("Downloading \(url.lastPathComponent)")
            return
        }

        completionHandler(Self.free(name, in: folder))
        announce("Downloading \(name)")
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let space = spaces[ObjectIdentifier(download)] else { return }
        stop(download)
        guard let file = download.progress.fileURL else {
            announce("Download finished")
            return
        }
        loot(space)?.add(
            Keep(
                name: file.lastPathComponent,
                from: download.originalRequest?.url?.host() ?? "",
                path: file.path,
                date: Date()
            )
        )
        announce("Saved \(file.lastPathComponent)")
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        guard spaces[ObjectIdentifier(download)] != nil else { return }
        stop(download)
        announce("Download failed")
    }

    private func stop(_ download: WKDownload) {
        let id = ObjectIdentifier(download)
        progress.removeValue(forKey: id)?.cancel()
        transfers.removeAll { $0.id == id }
        active.removeAll { $0 === download }
        spaces[ObjectIdentifier(download)] = nil
        if let url = download.originalRequest?.url { names[url] = nil }
    }

    /// WebKit refuses to write over a file that is already there, so the name
    /// gains a number rather than the download quietly failing.
    private static func free(_ name: String, in folder: URL) -> URL {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            candidate = folder.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }
}

extension Browser {
    /// The browser knows which space the initiating page belongs to; the
    /// download owns that identity from here until it stops.
    func keep(_ download: WKDownload) {
        let space = download.webView.flatMap { tab(for: $0) }?.space ?? spaceID
        downloads.keep(download, in: space)
    }
}
