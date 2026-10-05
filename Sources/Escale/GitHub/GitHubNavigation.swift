// Navigation is committed only after a local GitHub result is confirmed. An
// existing tab is selected intact, including its panel group and subpage; a
// historical destination opens in the search's Space without link routing.
// This is the small Browser hook; the search owns ordering and selection.
import Foundation

extension Browser {
    func beginGitHub(memory: GitHubMemory? = nil) {
        let shy = searchIsPrivate
        // Asking again for the search already open keeps it: replacing it would
        // end the old search, and with it the private cache the new one borrows.
        if memory == nil, let open = field.github, open.space == spaceID, open.shy == shy {
            editing = true
            field.askFocus(selectAll: false)
            return
        }
        let typed = fieldShowing ? field.typed : ""
        reviewing = false
        cancelTabEdit()
        closeFind()
        let context = spaceID
        // The mode GitHub sits beside (Bearing.swift) decides which open tabs lead.
        let lead: GitHubSearch.Lead = field.opening != nil || active?.isBlank == true ? .newTab : .tabs
        // The Space's own cache, or one for this private search only (GitHubSpaces).
        let memory = memory ?? (shy ? github.privateMemory(for: context) : github.owner(for: context).memory)
        let search = GitHubSearch(space: context, shy: shy, memory: memory, lead: lead, sources: { [weak self] in
            guard let self, self.spaceID == context else { return [] }
            return self.githubSources(shy: shy)
        }, active: { [weak self] in self?.activeID }, lifts: { [weak self] query in
            guard let self, !shy, self.spaceID == context else { return [:] }
            return self.habits(for: context).lifts(for: query)
        })
        search.watch(history: shy ? nil : history, tabs: tabs.filter { $0.shy == shy && !$0.bench })
        field.startGitHub(search, typed: typed)
        GitHubWatch.start(search, ending: field.$github, github: github, tabs: { [weak self] in self?.tabs ?? [] })
        editing = true
        field.askFocus(selectAll: typed.isEmpty)
    }

    /// A mode change keeps the pending New Tab and the words already typed.
    func leaveGitHub() {
        field.stopGitHub()
        field.refresh()
        field.askFocus(selectAll: false)
    }

    func takeGitHub(_ id: GitHubItem.ID) {
        guard let search = field.github, search.space == spaceID else { return }
        let typed = field.typed
        search.refresh()
        guard let row = search.results.first(where: { $0.id == id }) else { return }
        if case .tab(let tabID) = row.item.destination.source {
            guard let tab = tabs.first(where: { $0.id == tabID && $0.shy == search.shy && !$0.bench }) else { return }
            select(tab)
        } else {
            guard !search.shy else { return }
            openGitHub(row.item.destination.url)
        }
        if !search.shy { habits(for: search.space).learn(typed, chose: GitHubSearch.destination(id)) }
        field.stopGitHub()
        editing = false
        field.typed = ""
    }

    /// GitHub's page for sharing repositories opens in a tab; the search ends.
    func shareGitHub(_ url: URL) {
        field.stopGitHub()
        editing = false
        field.typed = ""
        _ = open(url, foreground: true, atEnd: true)
    }

    /// A GitHub destination loads in the blank tab on screen instead of
    /// leaving it behind; any other page under the search stays as it was.
    func openGitHub(_ url: URL) {
        if let blank = active, blank.isBlank, !blank.shy { blank.go(to: url) }
        else { _ = open(url, foreground: true, atEnd: true) }
    }

    func githubSources(shy: Bool) -> [GitHubSearch.Candidate] {
        var values: [GitHubSearch.Candidate] = []
        for tab in tabs where tab.shy == shy && !tab.bench {
            guard let url = tab.address,
                  let destination = GitHubItem.Destination(url: url, title: tab.label, source: .tab(tab.id), visitedAt: tab.touched),
                  let item = GitHubItem(space: spaceID, destination: destination) else { continue }
            values.append(.init(item, recent: tab.visited))
        }
        if !shy {
            for trace in history.everything() {
                guard let destination = GitHubItem.Destination(url: trace.url, title: trace.title, source: .history, visitedAt: trace.last),
                      let item = GitHubItem(space: spaceID, destination: destination) else { continue }
                values.append(.init(item, count: trace.count))
            }
        }
        return values
    }
}
