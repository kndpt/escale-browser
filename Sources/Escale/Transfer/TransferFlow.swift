// One owner for the two short walks a person takes: saving Escale to a file,
// and bringing a file in. It holds what a walk needs between its steps and
// nothing more: the opened file while its summary is shown (dropped the moment
// the walk ends, leaves or is cancelled), never the passphrase, which each
// step takes as an argument and the view forgets. Key stretching, sealing and
// reading run off the main actor; every owner of Escale's data is touched on
// it, once, by `Browser.transferSnapshot` and `Browser.applyTransfer`. No walk
// starts by itself, reads the network or opens a page.
import AppKit
import UniformTypeIdentifiers

@MainActor
final class TransferFlow: ObservableObject {
    enum Saving: Equatable {
        case idle
        case working
        case saved(String, Int)
        case failed(String)
    }

    enum Bringing: Equatable {
        case idle
        /// A file is chosen and waits for its passphrase.
        case locked(String)
        case opening
        case summary(TransferSummary)
        case applying(String)
        case finished(TransferReport)
        case failed(String)
    }

    @Published private(set) var saving: Saving = .idle
    @Published private(set) var bringing: Bringing = .idle
    /// Whether the summary offers this Escale's settings to be replaced: on
    /// for an Escale with nothing of its own yet, off otherwise.
    @Published var takesPreferences = false
    @Published private(set) var pristine = false
    /// The last reason an unlock was refused, shown beside the passphrase.
    @Published var mistake: String?

    private var file: Data?
    private var name = ""
    private var payload: TransferPayload?
    private var task: Task<Void, Never>?
    /// Bumped whenever the walk is dropped, so a read or unlock that finishes
    /// afterwards is ignored instead of bringing the file back.
    private var generation = 0

    var busy: Bool {
        if saving == .working { return true }
        switch bringing {
        case .opening, .applying: return true
        default: return false
        }
    }

    // MARK: - saving

    /// Sealed to `url`. The snapshot is taken here, now; everything after it
    /// works on a value.
    func save(to url: URL, passphrase: String, withPasswords: Bool, browser: Browser) {
        guard !busy else { return }
        guard !passphrase.isEmpty else { saving = .failed(TransferError.emptyPassphrase.localizedDescription); return }
        saving = .working
        var snapshot = browser.transferSnapshot()
        let ids = snapshot.spaces.map(\.id)
        task = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) { () -> Int in
                    if withPasswords {
                        let found = TransferExport.logins(of: ids)
                        snapshot.includesPasswords = true
                        for index in snapshot.spaces.indices { snapshot.spaces[index].logins = found[snapshot.spaces[index].id] ?? [] }
                    }
                    try TransferExport.write(snapshot, passphrase: passphrase, to: url)
                    return snapshot.spaces.count
                }.value
                self?.saving = .saved(url.lastPathComponent, result)
            } catch {
                self?.saving = .failed(error.localizedDescription)
            }
        }
    }

    /// Asks where, then saves.
    /// `started` runs only when the person confirmed a place, so the fields a
    /// cancelled panel left behind are still filled.
    func chooseDestination(passphrase: String, withPasswords: Bool, browser: Browser, started: @escaping () -> Void = {}) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.type]
        panel.nameFieldStringValue = TransferExport.suggestedName()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak browser] response in
            guard response == .OK, let url = panel.url, let browser else { return }
            started()
            self?.save(to: url, passphrase: passphrase, withPasswords: withPasswords, browser: browser)
        }
        if let window = Links.window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(panel.runModal()) }
    }

    static var type: UTType { UTType(filenameExtension: "escale") ?? .data }

    // MARK: - bringing

    /// Reads the chosen file, bounded, and waits for its passphrase. Only the
    /// checks that need no passphrase happen here.
    func choose(_ url: URL) {
        guard !busy else { return }
        forget()
        let label = url.lastPathComponent
        bringing = .opening
        let turn = generation
        task = Task { [weak self] in
            do {
                let data = try await Task.detached(priority: .userInitiated) { () -> Data in
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= TransferFile.largest else { throw TransferError.tooLarge }
                    guard let data = try? Data(contentsOf: url) else { throw TransferError.unavailable("Escale couldn't read that file.") }
                    _ = try TransferFile.inspect(data)
                    return data
                }.value
                guard let self, self.generation == turn else { return }
                self.file = data
                self.name = label
                self.bringing = .locked(label)
            } catch {
                guard let self, self.generation == turn else { return }
                self.bringing = .failed(error.localizedDescription)
            }
        }
    }

    /// Opens, decodes and checks the chosen file. Nothing on this Mac changes.
    func unlock(passphrase: String, browser: Browser) {
        guard case .locked = bringing, let data = file, !busy else { return }
        bringing = .opening
        let turn = generation
        task = Task { [weak self] in
            do {
                let decoded = try await Task.detached(priority: .userInitiated) { () -> TransferPayload in
                    let opened = try TransferFile.open(data, passphrase: passphrase)
                    do { return try JSONDecoder().decode(TransferPayload.self, from: opened) }
                    catch { throw TransferError.invalid("it isn't an Escale export") }
                }.value
                guard let self, self.generation == turn else { return }
                let (payload, summary) = try decoded.checked()
                self.payload = payload
                self.mistake = nil
                self.pristine = browser.isPristine
                self.takesPreferences = self.pristine
                self.bringing = .summary(summary)
            } catch {
                guard let self, self.generation == turn else { return }
                // A wrong passphrase leaves the file chosen, to try again.
                if case TransferError.cannotOpen = error {
                    self.mistake = error.localizedDescription
                    self.bringing = .locked(self.name)
                } else {
                    self.mistake = nil
                    self.bringing = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// One action applies everything the summary listed.
    func apply(browser: Browser) {
        guard case .summary = bringing, let payload, !busy else { return }
        bringing = .applying("Starting…")
        let preferences = takesPreferences
        task = Task { [weak self] in
            let report = await browser.applyTransfer(payload, preferences: preferences) { text in
                Task { @MainActor in if case .applying = self?.bringing { self?.bringing = .applying(text) } }
            }
            guard let self else { return }
            self.payload = nil; self.file = nil
            self.bringing = .finished(report)
            browser.announce(report.imported.isEmpty ? "Nothing new to import" : "Imported \(report.imported.count) Space\(report.imported.count == 1 ? "" : "s")")
        }
    }

    func cancel() { task?.cancel() }

    /// A refusal from outside the flow: the file picker's.
    func fail(_ message: String) { if !busy { bringing = .failed(message) } }

    /// Back to the start, and what was held dropped.
    func forget() {
        task?.cancel()
        generation += 1
        file = nil; payload = nil; name = ""; mistake = nil
        // An import under way finishes its Space and reports; anything else is dropped.
        if case .applying = bringing {} else { bringing = .idle }
    }

    func leave() {
        forget()
        if saving != .working { saving = .idle }
    }
}
