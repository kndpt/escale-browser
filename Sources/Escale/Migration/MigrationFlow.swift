// The window's import interaction owns selection and permission lifetimes.
// Neither welcome nor Settings discovers profiles while rendering. One serial
// discovery worker hands chosen sources to Migration's read/apply state machine;
// a generation invalidates late discovery results when the surface is closed.
// A security-scoped grant travels with the reader until its work has stopped.
import Foundation
import Combine

final class MigrationAccess {
    let url: URL
    private let scoped: Bool
    init(_ url: URL) { self.url = url; scoped = url.startAccessingSecurityScopedResource() }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

private struct MigrationGrantedReader: MigrationReader {
    let access: MigrationAccess
    let reader: any MigrationReader
    func read(_ source: MigrationSource, categories: Set<MigrationCategory>, cancellation: MigrationCancellation) throws -> MigrationValues {
        try withExtendedLifetime(access) { try reader.read(source, categories: categories, cancellation: cancellation) }
    }
}

@MainActor
final class MigrationFlow: ObservableObject {
    let migration: Migration
    @Published var browser: MigrationBrowser? = nil {
        didSet {
            guard oldValue != browser, !busy else { return }
            sources = []; selected = nil; categories = []; access = nil; message = nil
            clearSteps()
            migration.reset()
        }
    }
    @Published private(set) var sources: [MigrationSource] = []
    @Published private(set) var selected: String?
    @Published var categories: Set<MigrationCategory> = []
    @Published var destination = Space.firstID {
        didSet {
            if oldValue != destination, !busy { clearSteps(); migration.reset() }
        }
    }
    @Published private(set) var activeStep: MigrationCategory?
    @Published private(set) var stepResults: [MigrationCategory: String] = [:]
    @Published private(set) var stepNotices: [MigrationCategory: String] = [:]
    @Published private(set) var discovering = false
    @Published private(set) var message: String?
    @Published var request = 0
    /// Set when macOS refused a brand's folder: the file picker on it is the
    /// only way in, so the view opens it at once. It stays set until the view
    /// takes it, since a quick refusal can land before that view is mounted.
    @Published private(set) var folderWanted = false
    private let worker = DispatchQueue(label: "escale.migration.discovery", qos: .userInitiated)
    private let scratch: URL
    private var generation = 0
    private var access: MigrationAccess?
    private var discoveryCancellation = MigrationCancellation()
    /// Each automatic brand's starting folder; injected or test roots are
    /// fixed, while an interactive choice can point at the installed home.
    private let homes: [MigrationBrowser: URL]
    private let specified: Set<MigrationBrowser>
    private var chosenRoots: [MigrationBrowser: URL] = [:]
    private var preferred: [MigrationBrowser: String] = [:]
    private var stepObservation: AnyCancellable?
    private var passwordAccess: MigrationAccess?
    private var passwordSource: MigrationSource?

    init(journal: URL, scratch: URL, homes: [MigrationBrowser: URL] = [:]) {
        migration = Migration(journal: journal); self.scratch = scratch
        var roots: [MigrationBrowser: URL] = [:], given = Set<MigrationBrowser>()
        for brand in MigrationBrowser.allCases where brand.automatic {
            // An interactive demo may explicitly select a real source while its
            // destination stays isolated. Unconfigured tests never fall back to it.
            let demo = ProcessInfo.processInfo.environment["ESCALE_\(brand.slug.uppercased())_SOURCE"]
                .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            if let root = homes[brand] ?? (Store.testing ? demo : nil) {
                roots[brand] = root; given.insert(brand)
            } else {
                roots[brand] = brand.location(user: FileManager.default.homeDirectoryForCurrentUser,
                                              testRoot: Store.testing ? Store.file("migration-\(brand.slug)") : nil)
            }
        }
        self.homes = roots; specified = given
        stepObservation = migration.$phase.sink { [weak self] phase in self?.recordStep(phase) }
    }
    var source: MigrationSource? { sources.first { $0.id == selected } }
    var busy: Bool { discovering || migration.busy }
    var applying: Bool { if case .applying = migration.phase { return true }; return false }
    var choosingLocked: Bool { busy || migration.phase == .preview }

    func useBrowser(_ value: MigrationBrowser) {
        guard !choosingLocked, value.route != .unavailable else { return }
        browser = value
        if value.automatic { findHome() }
    }

    /// Selecting a browser in the UI is the user's request to discover it,
    /// including in an interactive test copy. Bench calls useBrowser instead.
    func useInstalledBrowser(_ value: MigrationBrowser) {
        guard !choosingLocked else { return }
        if value.automatic, chosenRoots[value] == nil, !specified.contains(value) {
            chosenRoots[value] = value.location(user: FileManager.default.homeDirectoryForCurrentUser, testRoot: nil)
        }
        useBrowser(value)
    }

    /// A brand's known folder is read only after choosing it or pressing retry.
    func findHome() {
        guard let browser, browser.automatic, !choosingLocked,
              let root = chosenRoots[browser] ?? homes[browser] else { return }
        choose(root, folder: true)
    }

    func begin(in space: UUID) {
        if browser?.automatic == true, sources.isEmpty, !busy {
            destination = space
            findHome()
            return
        }
        if migration.phase == .choosing, sources.isEmpty {
            destination = space
            migration.restoreReceipt()
        }
    }

    func select(_ id: String?) {
        guard !busy else { return }
        if selected != id { clearSteps(); migration.reset() }
        selected = id
        if let browser, browser.automatic { preferred[browser] = id }
        categories = source?.categories ?? []
    }

    func choose(_ url: URL, folder: Bool, ready: (() -> Void)? = nil) {
        guard !busy else { return }
        let automatic = browser?.automatic == true ? browser : nil
        let refreshing = automatic != nil && folder && source != nil
            && automatic.flatMap { chosenRoots[$0] }?.standardizedFileURL == url.standardizedFileURL
        if let automatic, folder { chosenRoots[automatic] = url }
        let previousSelection = selected, previousResults = stepResults, previousNotices = stepNotices
        migration.reset(); message = nil; folderWanted = false
        // Refresh keeps the visible profile and checklist in place while the
        // worker scans. A missing or unreadable result still clears the source.
        if !refreshing { sources = []; selected = nil; categories = []; clearSteps() }
        generation += 1
        let current = generation, chosen = MigrationAccess(url), browser = browser ?? .other
        access = chosen; discovering = true
        discoveryCancellation = MigrationCancellation()
        let token = discoveryCancellation, temporaryRoot = scratch
        worker.async(execute: DispatchWorkItem {
            let result = Result { () throws -> [MigrationSource] in
                try token.check()
                return try withExtendedLifetime(chosen) {
                    if folder {
                        if browser.automatic { return try browser.discover(in: url, cancellation: token, temporaryRoot: temporaryRoot) }
                        guard let family = browser.family else { throw MigrationFailure.unsupported }
                        return try MigrationProfiles.discover(in: url, browser: browser.rawValue, family: family, cancellation: token)
                    }
                    let extensionName = url.pathExtension.lowercased()
                    if extensionName == "zip" { return try MigrationSafari.discover(url, cancellation: token) }
                    let format: String
                    switch extensionName {
                    case "html", "htm": format = "html"
                    case "csv": format = "csv"
                    case "txt", "md": format = "links"
                    default: throw MigrationFailure.unsupported
                    }
                    return [MigrationSource(id: MigrationLimits.identity(format, url.standardizedFileURL.path).uuidString,
                                            browser: browser.rawValue, profile: url.lastPathComponent, location: url, format: format,
                                            categories: format == "csv" ? [.passwords] : [.bookmarks])]
                }
            }
            DispatchQueue.main.async {
                guard current == self.generation else { return }
                self.discovering = false
                switch result {
                case .success(let sources):
                    self.sources = sources
                    let preferred = browser.automatic ? self.preferred[browser] : nil
                    self.select(sources.first(where: { $0.id == preferred })?.id ?? sources.first?.id)
                    if self.selected == previousSelection {
                        self.stepResults = previousResults; self.stepNotices = previousNotices
                    }
                    if !sources.isEmpty { ready?() }
                    if sources.isEmpty {
                        self.message = browser.automatic ? browser.nothingFound : "No readable profiles found. Choose the browser's data folder or an export instead."
                    }
                case .failure(let error):
                    self.sources = []; self.selected = nil; self.categories = []; self.clearSteps()
                    let missing = (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSFileReadNoSuchFileError
                    let failure = error as? MigrationFailure ?? .unreadable
                    if browser.automatic, MigrationFailure.refused(error) { self.folderWanted = true }
                    self.message = !browser.automatic ? failure.localizedDescription
                        : missing ? browser.nothingFound
                        : MigrationFailure.refused(error) ? browser.refused
                        : failure == .unsupported ? "This \(browser.rawValue) version is not supported yet. Use an export from Other options."
                        : "\(browser.rawValue) \(browser.sourceName.lowercased())s could not be read."
                }
            }
        })
    }

    /// The view has opened the picker; a later refusal asks again.
    func folderOffered() { folderWanted = false }

    func selectionFailed(_ error: Error) {
        guard (error as NSError).code != NSUserCancelledError else { return }
        message = "The selection could not be opened. Try choosing the file or folder again."
    }

    func preview(in browser: Browser) {
        guard !busy, let source, !categories.isEmpty, let access else { return }
        guard browser.spaces.contains(where: { $0.id == destination }) else { message = MigrationFailure.destinationGone.localizedDescription; return }
        migration.prepare(source: source, destination: destination, categories: categories,
                          keeping: browser.bookmarks(of: destination).roots,
                          reader: MigrationGrantedReader(access: access, reader: reader(for: source.format)))
    }

    private func reader(for format: String) -> any MigrationReader {
        switch format {
        case "chromium": return MigrationChromium(temporaryRoot: scratch)
        case "gecko": return MigrationGecko(temporaryRoot: scratch)
        case "arc": return MigrationArc(temporaryRoot: scratch)
        case "orion": return MigrationOrion(temporaryRoot: scratch)
        case "zen": return MigrationZen(temporaryRoot: scratch)
        case "safari": return MigrationSafari()
        default: return MigrationExchange()
        }
    }

    func confirm(in browser: Browser) {
        guard let plan = migration.plan,
              browser.spaces.contains(where: { $0.id == plan.destination }) else { migration.cancel(); return }
        let space = plan.destination
        migration.confirm(destination: .init(bookmarks: browser.bookmarks(of: space), history: browser.history(for: space),
                                            exists: { [weak browser] in browser?.spaces.contains(where: { $0.id == space }) == true },
                                            tabs: { [weak browser] plan in
                                                guard let browser else { throw MigrationFailure.destinationGone }
                                                return try MigrationTabs.apply(plan, in: browser)
                                            }))
    }

    /// Import authorizes one category; validation precedes the acknowledged write.
    func startStep(_ category: MigrationCategory, in browser: Browser) {
        guard self.browser?.checklist == true, !choosingLocked else { return }
        let fromPasswordFile = category == .passwords && passwordSource != nil
        let chosenSource = fromPasswordFile ? passwordSource : source
        let chosenAccess = fromPasswordFile ? passwordAccess : access
        guard let chosenSource, let chosenAccess, chosenSource.categories.contains(category),
              browser.spaces.contains(where: { $0.id == destination }) else { return }
        migration.reset(); message = nil; activeStep = category
        stepResults[category] = nil; stepNotices[category] = nil
        categories = [category]
        let current = generation
        migration.prepare(source: chosenSource, destination: destination, categories: [category],
                          keeping: browser.bookmarks(of: destination).roots,
                          reader: MigrationGrantedReader(access: chosenAccess, reader: reader(for: chosenSource.format)),
                          ready: { [weak self, weak browser] in
            guard let self, let browser, self.generation == current else { return }
            let notices = self.migration.plan?.values.notices ?? []
            if !notices.isEmpty { self.stepNotices[category] = notices.joined(separator: "\n\n") }
            self.confirm(in: browser)
        })
    }

    func chooseStepExport(_ url: URL, category: MigrationCategory, in browser: Browser) {
        guard self.browser?.checklist == true, !choosingLocked else { return }
        if category == .passwords {
            guard url.pathExtension.lowercased() == "csv" else { message = MigrationFailure.unsupported.localizedDescription; return }
            passwordAccess = MigrationAccess(url)
            passwordSource = MigrationSource(id: MigrationLimits.identity("csv", url.standardizedFileURL.path).uuidString,
                                             browser: "Password manager export", profile: url.lastPathComponent,
                                             location: url, format: "csv", categories: [.passwords])
            startStep(category, in: browser)
        } else {
            choose(url, folder: false) { [weak self, weak browser] in
                guard let self, let browser else { return }
                self.startStep(category, in: browser)
            }
        }
    }

    private func clearSteps() {
        activeStep = nil; stepResults = [:]; stepNotices = [:]; passwordAccess = nil; passwordSource = nil
    }

    private func recordStep(_ phase: Migration.Phase) {
        if phase == .finished || phase == .stopped, let receipt = migration.receipt {
            if let category = activeStep, receipt.completed.contains(category) {
                switch category {
                case .bookmarks:
                    stepResults[category] = receipt.addedBookmarks == 0
                        ? "\(receipt.keptBookmarks.formatted()) already here"
                        : "\(receipt.addedBookmarks.formatted()) added · \(receipt.keptBookmarks.formatted()) already here"
                case .history:
                    stepResults[category] = receipt.historyPlaces.map {
                        $0 == 1 ? "1 place in this Space" : "\($0.formatted()) places in this Space"
                    } ?? "History imported"
                case .tabs: stepResults[category] = "\(receipt.addedTabs ?? 0) added · \(receipt.keptTabs ?? 0) already here"
                case .passwords: stepResults[category] = "\(receipt.passwordAdds) added · \(receipt.passwordKeeps) kept"
                }
            }
        }
        // Never retain a grant or parsed password source after an attempt.
        if activeStep == .passwords, phase == .finished || phase == .stopped {
            passwordAccess = nil; passwordSource = nil
        }
    }

    func again() { guard !busy else { return }; migration.reset(); message = nil }
    func cancel() {
        generation += 1; discoveryCancellation.cancel(); discovering = false
        migration.cancel()
    }
    /// Back within welcome keeps the profile and acknowledged results, not a
    /// password preview. Full dismissal still releases everything in leave().
    func pause() {
        guard !busy else { return }
        if migration.phase == .preview { migration.cancel() }
        passwordAccess = nil; passwordSource = nil
    }
    func leave() {
        generation += 1; discoveryCancellation.cancel(); discovering = false
        if migration.busy || migration.phase == .preview { migration.cancel() }
        access = nil; sources = []; selected = nil; categories = []
        clearSteps()
    }
}

extension Browser {
    /// Every legacy entry point now opens the same preview-first flow.
    func showMigration() {
        managing = false; bookmarking = false; bookmarksOpen = false
        Store.settings.set("migration", forKey: "settings.page")
        migration.request += 1
        tuning = true
    }
}
