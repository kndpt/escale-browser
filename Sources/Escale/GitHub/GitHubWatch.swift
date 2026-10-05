// While a GitHub search is on screen, its visible rows are what the data side
// may enrich: the API refreshes them (an ordinary search in a connected Space)
// and a page already shown reads its own state once. Only observations change;
// the rows' order and selection stay the search's. The API follows the set of
// visible objects, not each key. A page is read once per load of its tab: a
// row whose tab was still loading, or asleep, is read when the search next
// publishes after that tab is ready, without rereading pages on every key.
// The watch lives as long as its search and then stops the Space's refresh
// and drops a private cache (GitHubSpaces.leave). The first search after
// launch usually publishes before the keychain read has restored the Space's
// connection, so its refused batch is asked again once the connection arrives.
import Combine
import Foundation

@MainActor
final class GitHubWatch {
    private var rows: AnyCancellable?
    private var end: AnyCancellable?
    private var connection: AnyCancellable?
    private var visible: [GitHubItem.ID] = []
    /// Tab loads already read, by tab and page-data revision.
    private var read = Set<String>()

    /// Retained by its own subscriptions until `ending` shows another search or none.
    @discardableResult
    static func start(_ search: GitHubSearch, ending: Published<GitHubSearch?>.Publisher,
                      github: GitHubSpaces, tabs: @escaping () -> [Tab]) -> GitHubWatch {
        let watch = GitHubWatch()
        guard let memory = search.memory else { return watch }
        let space = search.space
        watch.rows = search.$results.sink { results in
            let ids = results.map(\.id)
            if ids != watch.visible {
                watch.visible = ids
                if memory.isPrivate {
                    memory.reconcile(history: [], visible: ids)
                } else if let owner = github.made(space), owner.memory === memory {
                    owner.refresh.update(history: github.history(of: space), visible: ids)
                }
            }
            let open = tabs()
            for result in results where memory.reading(result.id).current(at: Date()) == nil {
                guard case .tab(let tabID) = result.item.destination.source,
                      let tab = open.first(where: { $0.id == tabID }),
                      tab.built?.isLoading == false,
                      watch.read.insert("\(tabID.uuidString)#\(tab.dataRevision)").inserted else { continue }
                GitHubPage.read(tab, as: result.id, into: memory)
            }
        }
        if !memory.isPrivate, let owner = github.made(space), owner.memory === memory {
            // Delivered after the change, once GitHubRefresh has taken the new authority.
            watch.connection = owner.access.$connection.dropFirst().receive(on: DispatchQueue.main).sink { state in
                guard case .connected = state, !watch.visible.isEmpty else { return }
                owner.refresh.update(history: github.history(of: space), visible: watch.visible)
            }
        }
        watch.end = ending.sink { current in
            guard current !== search else { return }
            github.leave(space)
            watch.rows = nil
            watch.connection = nil
            watch.end = nil
        }
        return watch
    }
}
