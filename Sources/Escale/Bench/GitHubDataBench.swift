// The data side of Bearings' GitHub mode from the bench socket, in test worlds
// only: the per-Space owners, their files and the one-shot page read. Actions
// go through the browser's own GitHubSpaces and GitHubPage; `state` reports
// without making an owner, so a scenario can tell a Space never opened in
// GitHub mode from one that was. The surface's own verb is `github`
// (GitHubBench.swift, with its rows and simulated answers). Scenarios decide.
import Foundation

@MainActor
enum GitHubDataBench {
    static func run(_ request: [String: Any], browser: Browser, tab named: Tab?, answer: @escaping ([String: Any]) -> Void) {
        let github = browser.github
        switch request["action"] as? String ?? "state" {
        case "read":
            // What Bearings does for a listed page: owners made, cache read,
            // the page's own label read once.
            guard let tab = named, let url = tab.built?.url ?? tab.address,
                  let item = GitHubItem.ID(url: url, space: tab.space) else { answer(["error": "no GitHub page in that tab"]); return }
            let memory = tab.shy ? github.privateMemory(for: tab.space) : github.owner(for: tab.space).memory
            let end = Date().addingTimeInterval(10)
            func poll(_ ready: @escaping () -> Bool, then: @escaping () -> Void) {
                if ready() || Date() > end { then(); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll(ready, then: then) }
            }
            poll({ memory.loaded }) {
                memory.reconcile(history: github.history(of: tab.space), visible: [item])
                let before = memory.reading(item).observation
                GitHubPage.read(tab, as: item, into: memory)
                poll({ memory.reading(item).observation != before }) {
                    var out = describe(memory.reading(item), item: item, memory: memory)
                    // What the cache held before this read, restored from disk or not.
                    out["before"] = before?.state.rawValue ?? NSNull()
                    answer(out)
                }
            }
        case "private":
            // A private tab, through the browser's own path, for a scenario
            // that cannot type into the address field.
            guard let url = (request["url"] as? String).flatMap(URL.init(string:)) else { answer(["error": "private needs a URL"]); return }
            answer(["id": Bench.short(browser.open(url, foreground: true, shy: true))])
        case "connect":
            // The device flow a person finishes on github.com/login/device:
            // the answer carries the code to type there, never a token.
            let access = github.owner(for: browser.spaceID).access
            Task { await access.connect() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { answer(["connection": String(describing: access.connection)]) }
        case "disconnect":
            let access = github.owner(for: browser.spaceID).access
            Task {
                await access.disconnect()
                answer(["connection": String(describing: access.connection)])
            }
        case "refresh":
            // One visible row refreshed through the API, as the surface asks after a search.
            guard let url = (request["url"] as? String).flatMap(URL.init(string:)),
                  let item = GitHubItem.ID(url: url, space: browser.spaceID) else { answer(["error": "refresh needs a GitHub URL"]); return }
            let owner = github.owner(for: browser.spaceID)
            // Only an answer to this request counts: a 304 still renews the date.
            let before = owner.memory.reading(item)
            owner.refresh.update(history: github.history(of: browser.spaceID), visible: [item], manual: true)
            let end = Date().addingTimeInterval(15)
            func poll() {
                let reading = owner.memory.reading(item)
                let answered = reading != before
                if answered || Date() > end {
                    var out = describe(reading, item: item, memory: owner.memory)
                    out["answered"] = answered
                    if let failure = owner.refresh.failure { out["refresh"] = failure.rawValue }
                    answer(out)
                } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() } }
            }
            poll()
        case "shares":
            // The accounts sharing repositories with the app, as Settings › GitHub reads them.
            let owner = github.owner(for: browser.spaceID)
            owner.shares.stop()
            owner.shares.load()
            let end = Date().addingTimeInterval(15)
            func poll() {
                if let shares = owner.shares.shares {
                    answer(["shares": shares.map { ["account": $0.account, "all": $0.all, "page": $0.page?.absoluteString ?? ""] },
                            "install": owner.access.installURL?.absoluteString ?? ""])
                } else if Date() > end {
                    answer(["shares": NSNull(), "install": owner.access.installURL?.absoluteString ?? "",
                            "connection": String(describing: owner.access.connection)])
                } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() } }
            }
            poll()
        case "leave":
            github.leave(browser.spaceID)
            answer(["ok": true])
        default:
            let space = (request["space"] as? String).flatMap(UUID.init(uuidString:)) ?? browser.spaceID
            let file = GitHubMemory.file(for: space)
            Writer.to(file).flush()
            let folder = file.deletingLastPathComponent()
            let prefix = file.deletingPathExtension().lastPathComponent + ".unreadable-"
            let aside = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(prefix) }
            var out: [String: Any] = [
                "space": space.uuidString, "file": FileManager.default.fileExists(atPath: file.path),
                "setAside": aside.count, "history": github.history(of: space).count
            ]
            if let owner = github.made(space) {
                out["owner"] = true
                out["loaded"] = owner.memory.loaded
                out["count"] = owner.memory.count
                out["persistent"] = owner.memory.persistentCount
                out["connection"] = String(describing: owner.access.connection)
            } else { out["owner"] = false }
            answer(out)
        }
    }

    private static func describe(_ reading: GitHubReading, item: GitHubItem.ID, memory: GitHubMemory) -> [String: Any] {
        var out: [String: Any] = ["item": "\(item.owner)/\(item.repository)/\(item.kind.rawValue)/\(item.number)",
                                  "private": memory.isPrivate, "persistent": memory.persistentCount]
        if let observation = reading.observation {
            out["state"] = observation.state.rawValue
            out["source"] = observation.source == .page ? "page" : "api"
        }
        if let failure = reading.failure { out["failure"] = failure.rawValue }
        return out
    }
}
