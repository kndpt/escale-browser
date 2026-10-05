// Controlled GitHub fixtures use only an admitted disposable world. A failed
// navigation's metadata can name GitHub while the built page stays on the
// loopback server; this tests tab reuse without fetching GitHub or pretending
// to qualify page extraction/authentication. Observations use the real shared
// memory and ticket contract, with an explicitly isolated fixture path.
import Foundation

@MainActor
enum GitHubBench {
    static func state(_ browser: Browser) -> [String: Any] {
        guard let search = browser.field.github else { return ["open": false, "rows": []] }
        return ["open": true, "private": search.shy,
                "picked": search.picked.map(GitHubSearch.destination) ?? "",
                "rows": search.results.map { result -> [String: Any] in
                    let reading = search.memory?.reading(result.id)
                    return ["id": GitHubSearch.destination(result.id), "number": result.id.number,
                            "url": result.item.destination.url.absoluteString, "title": result.item.destination.title,
                            "tab": result.isOpen, "state": reading?.current(at: Date())?.rawValue ?? "unknown"]
                }]
    }

    static func run(_ request: [String: Any], browser: Browser) -> [String: Any] {
        guard Store.testing else { return ["error": "github needs an isolated test world"] }
        switch request["action"] as? String ?? "state" {
        case "state": break
        case "history":
            guard !browser.searchIsPrivate, let entries = request["entries"] as? [[String: Any]], entries.count <= History.room else {
                return ["error": "history needs at most 2000 entries in an ordinary context"]
            }
            for entry in entries {
                guard let text = entry["url"] as? String, let url = URL(string: text),
                      GitHubItem.ID(url: url, space: browser.spaceID) != nil else { return ["error": "invalid fixture URL"] }
                browser.history.take(url, title: entry["title"] as? String ?? "Fixture",
                                     count: 1, last: Date().addingTimeInterval(entry["age"] as? Double ?? 0))
            }
            browser.history.settle()
            browser.field.refresh()
        case "tab":
            guard let text = request["url"] as? String, let url = URL(string: text),
                  GitHubItem.ID(url: url, space: browser.spaceID) != nil,
                  let tab = browser.active, let host = tab.built?.url?.host(),
                  ["localhost", "127.0.0.1"].contains(host) else { return ["error": "tab fixture requires a built loopback page"] }
            tab.failed("Local GitHub test fixture", at: url)
            browser.field.refresh()
        case "observe":
            guard let search = browser.field.github, let memory = search.memory,
                  let number = request["number"] as? Int,
                  let id = search.results.first(where: { $0.id.number == number })?.id,
                  let text = request["state"] as? String, let status = GitHubState(rawValue: text),
                  let ticket = memory.request(id, api: false) else { return ["error": "no admitted observation"] }
            let age = max(0, request["age"] as? Double ?? 0)
            _ = memory.receive(status, at: Date().addingTimeInterval(-age), for: ticket)
        case "memory":
            let memory = GitHubMemory(space: browser.spaceID, isPrivate: browser.searchIsPrivate,
                                      file: Store.file("github-bench-\(UUID()).json"))
            browser.beginGitHub(memory: memory)
            if let search = browser.field.github {
                let ids = search.results.map(\.id)
                memory.reconcile(history: search.shy ? [] : ids, visible: ids)
            }
        case "back": browser.leaveGitHub()
        default: return ["error": "unknown GitHub action"]
        }
        return state(browser)
    }
}
