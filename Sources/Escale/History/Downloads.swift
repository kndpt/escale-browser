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
//
// A transfer that fails, not one the person cancels, stays as a row for the
// session with WebKit's resume data when it offers some, otherwise the address
// to ask again, and the file it was writing: Resume or Retry lands in the same
// folder of the same Space. Nothing of it is saved. At most `failureLimit`
// rows are kept, the oldest let go first, and resume data over `resumeLimit`
// is dropped for a plain Retry, so half a megabyte at most stays in memory,
// under memory pressure too.

@MainActor
final class Downloads: NSObject, ObservableObject, WKDownloadDelegate {
    private let loot: (UUID) -> Loot?
    private let asksWhere: () -> Bool
    private let folder: (UUID) -> URL?
    private let announce: (String) -> Void
    private let page: (UUID) -> WKWebView?

    struct Transfer: Identifiable, Equatable {
        let id: ObjectIdentifier
        let space: UUID
        var name: String
        var fraction: Double?
    }

    struct Failure: Identifiable {
        let id = UUID()
        let space: UUID
        let name: String
        /// Where the file was being written; a retry goes to its folder.
        let file: URL?
        let resume: Data?
        /// Only a GET with a host: a data: address can carry the whole file,
        /// and a blob: one means nothing once its page is gone.
        let source: URL?

        /// What taking it up again does, as its button says; none without either.
        var action: String? { resume != nil ? "Resume" : source != nil ? "Retry" : nil }
    }

    static let failureLimit = 8
    static let resumeLimit = 64 * 1024

    // Session-only visibility survives completion, cancellation and Space changes.
    @Published private(set) var hasStarted = false
    @Published private(set) var transfers: [Transfer] = []
    @Published private(set) var failures: [Failure] = []
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

    /// RFC 6266: `Content-Disposition: attachment` asks for the file to be
    /// kept, even one WebKit could show, as Safari, Chrome and Firefox do.
    nonisolated static func isAttachment(_ response: URLResponse) -> Bool {
        guard let value = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") else { return false }
        return value.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces).lowercased() == "attachment"
    }

    var fraction: Double? { Self.fraction(transfers.map(\.fraction)) }
    var observationCount: Int { progress.count }
    private var spaces: [ObjectIdentifier: UUID] = [:]
    private var names: [URL: String] = [:]
    /// The file each transfer writes, once known; set ahead for a retry.
    private var files: [ObjectIdentifier: URL] = [:]

    /// On-demand test/resource evidence; reading it starts no work.
    var count: Int { active.count }

    init(
        loot: @escaping (UUID) -> Loot?,
        asksWhere: @escaping () -> Bool,
        folder: @escaping (UUID) -> URL?,
        announce: @escaping (String) -> Void,
        page: @escaping (UUID) -> WKWebView?
    ) {
        self.loot = loot
        self.asksWhere = asksWhere
        self.folder = folder
        self.announce = announce
        self.page = page
    }

    /// An extension may choose the filename, but never the folders it carries.
    func name(_ name: String, for url: URL) {
        names[url] = (name as NSString).lastPathComponent
    }

    /// Retained until WebKit reports success or failure, independently of the
    /// initiating page's lifetime. A failure taken up again keeps its name and file.
    func keep(_ download: WKDownload, in space: UUID, again failure: Failure? = nil) {
        guard !active.contains(where: { $0 === download }) else { return }
        download.delegate = self
        active.append(download)
        hasStarted = true
        let id = ObjectIdentifier(download)
        spaces[id] = space
        files[id] = failure?.file
        transfers.append(Transfer(id: id, space: space,
                                  name: failure?.name ?? download.originalRequest?.url?.lastPathComponent ?? "Download",
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
        failures.removeAll { $0.space == space }
    }

    func cancel(_ id: ObjectIdentifier) {
        guard let download = active.first(where: { ObjectIdentifier($0) == id }) else { return }
        // WebKit does not promise a failure delegate call for explicit cancel.
        download.cancel { _ in }
        stop(download)
    }

    /// Resume with WebKit's data, otherwise ask the address again, through a
    /// page of the failure's own Space for its cookies and website store.
    func retry(_ id: UUID) {
        guard let failure = failures.first(where: { $0.id == id }), failure.action != nil else { return }
        guard let web = page(failure.space) else {
            announce("Open a page in this Space to download \(failure.name) again")
            return
        }
        failures.removeAll { $0.id == id }
        if let data = failure.resume {
            web.resumeDownload(fromResumeData: data) { [weak self] in self?.keep($0, in: failure.space, again: failure) }
        } else if let source = failure.source {
            // WebKit leaves the half it wrote; the retry takes its place
            // rather than landing beside it under a second name. The Trash,
            // not deletion: a file chosen to be replaced in the save panel
            // stands there too.
            if let file = failure.file { try? FileManager.default.trashItem(at: file, resultingItemURL: nil) }
            web.startDownload(using: URLRequest(url: source)) { [weak self] in self?.keep($0, in: failure.space, again: failure) }
        }
    }

    func remove(_ id: UUID) {
        failures.removeAll { $0.id == id }
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
        let id = ObjectIdentifier(download)
        let asked = response.url.flatMap { names.removeValue(forKey: $0) }
        let name = asked ?? (suggestedFilename.isEmpty ? "download" : suggestedFilename)
        if let index = transfers.firstIndex(where: { $0.id == id }) {
            transfers[index].name = name
        }
        guard let space = spaces[id], let folder = folder(space) else {
            stop(download)
            completionHandler(nil)
            return
        }

        // A retry goes where the failed transfer was going, without asking again.
        if let earlier = files[id] {
            let file = Self.free(name, in: earlier.deletingLastPathComponent())
            files[id] = file
            completionHandler(file)
            announce("Downloading \(file.lastPathComponent)")
            return
        }

        guard !asksWhere() else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.directoryURL = folder
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url,
                  spaces[id] != nil else {
                stop(download)
                completionHandler(nil)
                return
            }
            files[id] = url
            completionHandler(url)
            announce("Downloading \(url.lastPathComponent)")
            return
        }

        let file = Self.free(name, in: folder)
        files[id] = file
        completionHandler(file)
        announce("Downloading \(name)")
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let space = spaces[ObjectIdentifier(download)] else { return }
        let written = files[ObjectIdentifier(download)]
        stop(download)
        guard let file = download.progress.fileURL ?? written else {
            announce("Download finished")
            return
        }
        let source = download.originalRequest?.url
        loot(space)?.add(
            Keep(
                name: file.lastPathComponent,
                from: source?.host() ?? "",
                path: file.path,
                date: Date(),
                size: (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init),
                // Only an address with a host: a data: URL can carry the whole
                // file, and a blob: one means nothing once its page is gone.
                address: source?.host() == nil ? nil : source?.absoluteString
            )
        )
        announce("Saved \(file.lastPathComponent)")
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        let id = ObjectIdentifier(download)
        guard let space = spaces[id] else { return }
        let name = transfers.first(where: { $0.id == id })?.name ?? "Download"
        let request = download.originalRequest
        let source = request?.url.flatMap { url in
            url.host() != nil && (request?.httpMethod ?? "GET") == "GET" ? url : nil
        }
        let failure = Failure(space: space, name: name, file: files[id],
                              resume: resumeData.flatMap { $0.count <= Self.resumeLimit ? $0 : nil },
                              source: source)
        stop(download)
        failures.append(failure)
        failures.removeFirst(max(0, failures.count - Self.failureLimit))
        announce("Couldn’t download \(name)")
    }

    private func stop(_ download: WKDownload) {
        let id = ObjectIdentifier(download)
        progress.removeValue(forKey: id)?.cancel()
        transfers.removeAll { $0.id == id }
        active.removeAll { $0 === download }
        spaces[id] = nil
        files[id] = nil
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

    /// A page already built in that Space, parked or not; none is built for it.
    func page(in space: UUID) -> WKWebView? {
        (tabs + parkedTabs).lazy.filter { $0.space == space }.compactMap(\.built).first
    }
}
