// Imported sessions are addresses, never engine state. Provenance travels in
// Session.Entry and Tab so a replay after restart keeps user edits and does
// not duplicate a still-present tab. Closing one deliberately permits a later
// reimport. At most 2,000 imported tabs per selection; no page is constructed.
// The destination's ordered session writer acknowledges the combined snapshot
// before the visible/parked row receives the new metadata.
import Foundation

enum MigrationTabs {
    static func merge(_ plan: MigrationPlan, into shape: Session.Shape) -> (shape: Session.Shape, added: [Session.Entry], kept: Int) {
        let known = Set(shape.tabs.compactMap(\.migration))
        var added: [Session.Entry] = [], kept = 0
        for tab in plan.values.tabs {
            let id = MigrationLimits.identity(plan.source.id, "tab", tab.id)
            if known.contains(id) { kept += 1; continue }
            added.append(Session.Entry(url: tab.url.absoluteString, title: tab.title,
                                       pin: tab.pinned ? (tab.url.host?.replacingOccurrences(of: "www.", with: "").first.map { String($0).uppercased() } ?? "•") : nil,
                                       migration: id))
        }
        var result = shape
        let pins = added.filter { $0.pin != nil }, loose = added.filter { $0.pin == nil }
        let boundary = shape.tabs.prefix { $0.pin != nil }.count
        result.tabs.insert(contentsOf: pins, at: boundary)
        result.tabs += loose
        // Saved compositions use row indices; inserting pins must keep their
        // members and the selected existing tab attached to the same address.
        if !shape.tabs.isEmpty, result.active >= boundary { result.active += pins.count }
        result.panels = shape.panels?.map { group in
            var shifted = group
            shifted.members = group.members.map { $0 >= boundary ? $0 + pins.count : $0 }
            if group.active >= boundary { shifted.active += pins.count }
            return shifted
        }
        return (result, added, kept)
    }

    @MainActor static func apply(_ plan: MigrationPlan, in browser: Browser) throws -> (added: Int, kept: Int) {
        let space = plan.destination
        guard browser.spaces.contains(where: { $0.id == space }) else { throw MigrationFailure.destinationGone }
        browser.writeSession(of: space, now: true)
        guard Session.saved(space: space) else { throw MigrationFailure.storage }
        let existing = Session.read(space: space)
        let result = merge(plan, into: existing)
        if !result.added.isEmpty {
            Session.write(now: true, space: space, result.shape)
            guard Session.saved(space: space) else { throw MigrationFailure.storage }
            browser.attachImportedTabs(result.added, to: space)
        }
        return (result.added.count, result.kept)
    }
}
