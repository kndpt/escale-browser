// The GitHub owners of each Space, made only when Bearings' GitHub mode asks:
// a browser that never opens it reads no cache file, touches no keychain item
// and starts no connection. Browser's hooks stay one line each; the order
// between owners lives here. The authorization is restored before the cache is
// read, because a snapshot written under another authorization brings nothing
// back (GitHubMemory.restore).
//
// A private search gets its own cache for one Bearings opening only. It holds
// at most six page observations in memory, with no file, secret or API access,
// and is erased when the surface closes: nothing it saw outlives the look.
// Duplication and transfer copy closed lists of files (SpaceCopy, Transfer)
// that name none of these, so a copied Space starts signed out and empty.

import Combine
import Foundation

@MainActor
final class GitHubSpaces {
    struct Owner {
        let memory: GitHubMemory
        let access: GitHubAccess
        let refresh: GitHubRefresh
        let shares: GitHubShares
    }

    private var owners: [UUID: Owner] = [:]
    /// Spaces whose authorization has been read; only then may their cache be.
    private var ready = Set<UUID>()
    private var privates: [UUID: GitHubMemory] = [:]
    private var identities: [UUID: [GitHubItem.ID]] = [:]
    private var watches: [UUID: AnyCancellable] = [:]
    private let history: (UUID) -> History?
    private let configuration: GitHubAccess.Configuration
    private let secrets: (UUID) -> GitHubCredentialStore
    private let file: (UUID) -> URL
    private let http: GitHubHTTP

    /// Nil seams are the browser's own: its client, keychain and Store files.
    init(history: @escaping (UUID) -> History?,
         configuration: GitHubAccess.Configuration? = nil,
         secrets: ((UUID) -> GitHubCredentialStore)? = nil,
         file: ((UUID) -> URL)? = nil,
         http: GitHubHTTP = GitHubHTTP()) {
        self.history = history
        self.configuration = configuration ?? Self.configuration
        self.secrets = secrets ?? { GitHubSecrets.live(space: $0) }
        self.file = file ?? { GitHubMemory.file(for: $0) }
        self.http = http
    }

    /// The GitHub App a build was given (build.sh writes its public client ID
    /// into Info.plist); a test run may name its development client instead.
    /// Without either, connecting reports a configuration failure.
    static var configuration: GitHubAccess.Configuration {
        let environment = Store.testing ? ProcessInfo.processInfo.environment : [:]
        let info = Bundle.main.infoDictionary ?? [:]
        let named = environment["ESCALE_GITHUB_CLIENT_ID"] ?? info["EscaleGitHubClientID"] as? String
        // A test run naming its client names that app's address too, never production's.
        let slug = environment["ESCALE_GITHUB_CLIENT_ID"] != nil
            ? environment["ESCALE_GITHUB_APP_SLUG"] : info["EscaleGitHubAppSlug"] as? String
        return GitHubAccess.Configuration(clientID: named ?? "", slug: slug ?? "")
    }

    /// Every GitHub object in a Space's history, worked out again only after
    /// that history changes, and never from a page.
    func history(of space: UUID) -> [GitHubItem.ID] {
        if let known = identities[space] { return known }
        guard let source = history(space) else { return [] }
        if watches[space] == nil {
            watches[space] = source.objectWillChange.sink { [weak self] in self?.identities[space] = nil }
        }
        var seen = Set<GitHubItem.ID>()
        let found = source.everything().compactMap { trace -> GitHubItem.ID? in
            guard let id = GitHubItem.ID(url: trace.url, space: space), seen.insert(id).inserted else { return nil }
            return id
        }
        identities[space] = found
        return found
    }

    /// The owners of one Space, with its cache read once its authorization is known.
    func owner(for space: UUID) -> Owner {
        if let known = owners[space] {
            if ready.contains(space), !known.memory.loaded { known.memory.restore { _ in } }
            return known
        }
        let memory = GitHubMemory(space: space, file: file(space))
        memory.reconcile(history: history(of: space), visible: [])
        let access = GitHubAccess(space: space, configuration: configuration, secrets: secrets(space), http: http)
        let refresh = GitHubRefresh(memory: memory, access: access, http: http)
        let made = Owner(memory: memory, access: access, refresh: refresh,
                         shares: GitHubShares(memory: memory, access: access, http: http))
        owners[space] = made
        Task { [weak self] in
            await access.restore()
            guard let self, self.owners[space]?.memory === memory else { return }
            self.ready.insert(space)
            memory.restore { _ in }
        }
        return made
    }

    /// The owners already made for a Space, without making them.
    func made(_ space: UUID) -> Owner? { owners[space] }

    /// The cache of a private search in this Space, until `leave`.
    func privateMemory(for space: UUID) -> GitHubMemory {
        if let known = privates[space] { return known }
        let made = GitHubMemory(space: space, isPrivate: true)
        privates[space] = made
        return made
    }

    /// History forgot one place (its key, as History keeps it) or everything (nil).
    /// A Space whose owners were never made loses its cache file instead, and
    /// forgetting everything also removes the files a bad read set aside.
    func forget(_ key: String?, in space: UUID) {
        identities[space] = nil
        let item = key.flatMap { URL(string: "https://\($0)") }.flatMap { GitHubItem.ID(url: $0, space: space) }
        guard key == nil || item != nil else { return }
        privates[space]?.forget(item)
        let path = file(space)
        if let owner = owners[space] { owner.memory.forget(item) }
        else { Writer.to(path).remove() }
        if key == nil { Writer.to(path).acknowledge { _ in Self.removeSetAside(path) } }
    }

    /// The surface closed, or the window left the Space: no refresh goes on for
    /// it. A device authorization shown in Settings carries on; Settings ends it.
    func leave(_ space: UUID) {
        owners[space]?.refresh.stop(cancelAccess: false)
        privates.removeValue(forKey: space)?.erase()
    }

    /// The Space is deleted: its cache, set-aside files and secrets go, made or not.
    func erase(_ space: UUID) {
        leave(space)
        let path = file(space)
        if let owner = owners.removeValue(forKey: space) {
            owner.shares.stop()
            owner.memory.erase()
            Task { await owner.access.erase() }
        } else {
            Writer.to(path).remove()
            let deletion = secrets(space).erase()
            Task { _ = try? await deletion.value }
        }
        ready.remove(space)
        identities[space] = nil
        watches[space] = nil
        // Behind the removal on the file's own lane, where a bad read sets files aside.
        Writer.to(path).acknowledge { _ in Self.removeSetAside(path) }
    }

    /// Store.quarantine names a set-aside file after the one it replaced.
    nonisolated static func removeSetAside(_ file: URL) {
        let folder = file.deletingLastPathComponent()
        let prefix = file.deletingPathExtension().lastPathComponent + ".unreadable-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".json") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Memory is short: observations go, files stay for the next opening.
    func relieve() {
        for owner in owners.values { owner.memory.relieve() }
        for memory in privates.values { memory.relieve() }
        identities = [:]
    }

    /// Quitting, or a transfer file being made (Browser.flush): whatever the
    /// caches were waiting to write is written now. Work in flight goes on.
    func flush() {
        for owner in owners.values { owner.memory.flush() }
    }
}
