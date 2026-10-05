// Groups use indices into the filtered session, never today's live row. Private
// pages and bench tabs cannot leak membership or shift an ordinary selection.
// Bookmark-owned pages in a group retain their explicit bookmark identity;
// their restored views remain lazy until their group is selected.
import Foundation

extension Browser {
    func savedPanels(row: [Tab], entries: [Session.Entry?]) -> [Session.SavedPanels]? {
        let kept = zip(row, entries).compactMap { tab, entry in entry == nil ? nil : tab.id }
        let result = panels.groups.compactMap { group -> Session.SavedPanels? in
            let members = group.members.compactMap { kept.firstIndex(of: $0) }
            guard members.count == group.members.count,
                  let active = kept.firstIndex(of: group.active) else { return nil }
            return Session.SavedPanels(members: members, active: active,
                                       horizontal: group.horizontal, weights: group.weights)
        }
        return result.isEmpty ? nil : result
    }

    func restorePanels(_ shape: Session.Shape, row: [Tab]) {
        guard Session.valid(shape), row.count == shape.tabs.count else { return }
        for group in shape.panels ?? [] {
            panels.restore(PanelGroup(id: UUID(), members: group.members.map { row[$0].id },
                                      active: row[group.active].id, horizontal: group.horizontal,
                                      weights: group.weights))
        }
    }

    func selectEntry(_ tab: Tab) {
        if let group = panels.group(tab.id), let selected = tabs.first(where: { $0.id == group.active }) {
            select(selected)
        } else { select(tab) }
    }
}
