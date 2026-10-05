// Saved link routes belong to the window, across Spaces. One ordered Writer
// persists value snapshots and flushes at quit. A bounded file is read once;
// Settings observes this owner directly. Matching never constructs a WebKit
// page; the destination is decided before Browser opens the new tab.
import Foundation
import Combine

@MainActor
final class LinkRoutes: ObservableObject {
    @Published private(set) var rules: [LinkRule] = []
    @Published private(set) var problem: String?
    lazy var draft = LinkDraft(rules: rules)
    private let writer: Writer

    init(file: URL) {
        writer = Writer.to(file)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 2_000_000 else { throw CocoaError(.fileReadCorruptFile) }
            let loaded = try JSONDecoder().decode([LinkRule].self, from: Data(contentsOf: file))
            guard LinkRule.validation(loaded) == nil else { throw CocoaError(.fileReadCorruptFile) }
            rules = loaded
        } catch {
            Store.quarantine(file)
            problem = "Link rules could not be read. The original file was kept for recovery."
        }
    }

    @discardableResult
    func save(_ draft: [LinkRule], spaces: Set<UUID>) -> Bool {
        if let error = LinkRule.validation(draft) { problem = error; return false }
        guard draft.allSatisfy({ spaces.contains($0.destination) }) else {
            problem = "Choose an existing Space for every rule."
            return false
        }
        self.draft.follow(rules, with: draft)
        rules = draft
        problem = nil
        writer.save(draft)
        writer.acknowledge { [weak self] saved in
            guard !saved else { return }
            DispatchQueue.main.async { self?.problem = "Link rules could not be saved. Try Save again." }
        }
        return true
    }

    func remove(space: UUID) {
        let remaining = rules.filter { $0.destination != space }
        guard remaining != rules else { return }
        draft.follow(rules, with: remaining)
        rules = remaining
        writer.save(remaining)
    }
}

extension Browser {
    /// Shared entry for an intentional HTTP link, including future app tools.
    /// True means a matching rule consumed the opening. Call before loading;
    /// never call for redirects, reload, restore, history or a typed address.
    @discardableResult
    func routeLink(_ url: URL, from source: Tab? = nil) -> Bool {
        guard prefs.usesSpaces, !(source?.shy ?? false),
              let rule = LinkRule.winner(in: linkRoutes.rules, for: url, spaces: Set(spaces.map(\.id))) else { return false }
        // A page already in the chosen Space keeps WebKit's own navigation,
        // opener, request and back stack. An external opening still selects it.
        if let source, source.space == rule.destination { return false }
        switchSpace(to: rule.destination, focus: false, waking: false)
        open(url, foreground: true)
        return true
    }

    func openPageLink(_ url: URL, from source: Tab, foreground: Bool) {
        if !routeLink(url, from: source) { open(url, foreground: foreground, from: source).origin = source.id }
    }
}
