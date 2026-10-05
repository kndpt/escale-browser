// A split is organisation, never another owner of a WebKit page. Keep at most
// three tab identities per group; closing a tab removes its identity and a
// singleton dissolves. The space's existing session writer saves these values.
// Unused splits install no timer, script, observer or additional page.
import SwiftUI

enum PanelEdge: String, CaseIterable, Codable {
    case left, right, top, bottom
    var horizontal: Bool { self == .left || self == .right }
    var first: Bool { self == .left || self == .top }
    var title: String { rawValue.capitalized }
    var symbol: String { horizontal ? "rectangle.split.2x1" : "rectangle.split.1x2" }

    static func at(_ point: CGPoint, in frame: CGRect) -> PanelEdge? {
        guard frame.width > 0, frame.height > 0, frame.contains(point) else { return nil }
        let x = (point.x - frame.minX) / frame.width
        let y = (point.y - frame.minY) / frame.height
        // The centre is deliberately not a target; leaving the four edges cancels.
        guard min(x, 1 - x, y, 1 - y) < Metrics.panelEdgeFraction else { return nil }
        if min(x, 1 - x) < min(y, 1 - y) { return x < 0.5 ? .left : .right }
        return y < 0.5 ? .top : .bottom
    }
}

struct PanelGroup: Identifiable, Equatable {
    let id: UUID
    var members: [UUID]
    var active: UUID
    var horizontal: Bool
    var weights: [Double]
}

@MainActor
final class Panels: ObservableObject {
    static let limit = 3
    @Published private(set) var groups: [PanelGroup] = []
    @Published var preview: PanelEdge?
    /// The tab being carried over the pages, so its own row can step back.
    @Published private(set) var carrying: UUID?
    let lift = PanelLift()
    /// A page whose capsule the bench shows without a pointer (test runs only).
    @Published var toolsShown: UUID?
    var frame: CGRect = .zero
    var entries: [UUID: CGRect] = [:]
    var focusWatching = false
    private(set) var source: UUID?
    private(set) var cancelled = false

    func group(_ tab: UUID?) -> PanelGroup? {
        guard let tab else { return nil }
        return groups.first { $0.members.contains(tab) }
    }

    func representatives(_ tabs: [Tab]) -> [Tab] {
        var seen = Set<UUID>()
        return tabs.filter { tab in
            guard let group = group(tab.id) else { return true }
            return seen.insert(group.id).inserted
        }
    }

    func focus(_ id: UUID?) {
        guard let id, let index = groups.firstIndex(where: { $0.members.contains(id) }),
              groups[index].active != id else { return }
        groups[index].active = id
    }

    /// A page already in the target's group moves to the new edge; any
    /// other page joins it while there is room.
    func add(_ source: UUID, to target: UUID, edge: PanelEdge) -> Bool {
        guard let plan = plan(source, beside: target, edge: edge) else { return false }
        if group(target)?.members.contains(source) != true { remove(source) }
        var group = group(target) ?? PanelGroup(id: UUID(), members: [target], active: target,
                                                horizontal: edge.horizontal, weights: [1])
        group.members = plan
        group.horizontal = edge.horizontal
        group.weights = Array(repeating: 1 / Double(group.members.count), count: group.members.count)
        group.active = source
        groups.removeAll { $0.id == group.id }
        groups.append(group)
        return true
    }

    /// The members as they would be after the drop, or nil if it is refused.
    func plan(_ source: UUID, beside target: UUID, edge: PanelEdge) -> [UUID]? {
        guard source != target else { return nil }
        var members = (group(target)?.members ?? [target]).filter { $0 != source }
        guard members.count < Self.limit else { return nil }
        members.insert(source, at: edge.first ? 0 : members.count)
        return members
    }

    func remove(_ id: UUID) {
        guard let index = groups.firstIndex(where: { $0.members.contains(id) }) else { return }
        var group = groups[index]
        group.members.removeAll { $0 == id }
        guard group.members.count > 1 else { groups.remove(at: index); return }
        if group.active == id { group.active = group.members[0] }
        group.weights = Array(repeating: 1 / Double(group.members.count), count: group.members.count)
        groups[index] = group
    }

    func separate(_ id: UUID) { groups.removeAll { $0.members.contains(id) } }
    func turn(_ id: UUID) {
        guard let i = groups.firstIndex(where: { $0.members.contains(id) }) else { return }
        groups[i].horizontal.toggle()
    }
    func reverse(_ id: UUID) {
        guard let i = groups.firstIndex(where: { $0.members.contains(id) }) else { return }
        groups[i].members.reverse()
        groups[i].weights.reverse()
    }
    func move(_ id: UUID, by step: Int) {
        guard let i = groups.firstIndex(where: { $0.members.contains(id) }),
              let from = groups[i].members.firstIndex(of: id),
              groups[i].members.indices.contains(from + step) else { return }
        groups[i].members.swapAt(from, from + step)
        groups[i].weights.swapAt(from, from + step)
    }
    func resize(_ id: UUID, weights: [Double]) {
        guard let i = groups.firstIndex(where: { $0.id == id }),
              weights.count == groups[i].members.count, weights.allSatisfy({ $0.isFinite && $0 > 0 }) else { return }
        let sum = weights.reduce(0, +)
        guard sum.isFinite, sum > 0 else { return }
        groups[i].weights = weights.map { $0 / sum }
    }
    func restore(_ group: PanelGroup) { groups.append(group) }

    func aim(_ tab: UUID, edge: PanelEdge?) {
        if source != tab { source = tab; cancelled = false }
        let next = cancelled ? nil : edge
        if preview != next { preview = next }
    }
    func cancel() { preview = nil; cancelled = true; carry(nil) }
    func finish() { source = nil; preview = nil; cancelled = false; carry(nil) }

    /// Only the carried face follows each pointer move; the stage and the
    /// rows are told when the tab crosses onto or off the pages.
    func carry(_ tab: Tab?, at point: CGPoint = .zero) {
        let id = cancelled ? nil : tab?.id
        if carrying != id { carrying = id }
        if let tab, id != nil { lift.show(tab, at: point) } else { lift.hide() }
    }
}

/// Where a carried tab is while it crosses the pages. Kept apart from Panels
/// so each pointer move redraws the small carried face, not the stage.
@MainActor
final class PanelLift: ObservableObject {
    @Published private(set) var point: CGPoint?
    private(set) weak var tab: Tab?

    func show(_ tab: Tab, at point: CGPoint) {
        self.tab = tab
        self.point = point
    }

    func hide() {
        tab = nil
        if point != nil { point = nil }
    }
}

extension Browser {
    var panelTabs: [Tab] {
        guard let group = panels.group(activeID) else { return active.map { [$0] } ?? [] }
        return group.members.compactMap { id in tabs.first { $0.id == id } }
    }
    var tabEntries: [Tab] { panels.representatives(tabs) }

    func entryID(for id: UUID?) -> UUID? {
        guard let group = panels.group(id) else { return id }
        return tabs.first { group.members.contains($0.id) }?.id
    }

    func wakePanels(except selected: UUID? = nil) {
        for tab in panelTabs where tab.id != selected {
            if !tab.wake() { tab.revive() }
            tab.touch()
        }
    }

    func touchPanels(containing id: UUID) {
        // All visible pages were watched until the composition was left,
        // even when one kept keyboard focus for longer than the idle period.
        let visible = Set(panels.group(id)?.members ?? [id])
        for tab in tabs + parkedTabs where visible.contains(tab.id) { tab.touch() }
    }

    /// Pages of one Space and one website store, real pages rather than
    /// blank, bench or floating ones.
    func panelsMix(_ source: Tab, _ target: Tab) -> Bool {
        source.id != target.id && source.space == target.space && source.space == spaceID
            && source.shy == target.shy && source.store === target.store
            && !source.isBlank && !target.isBlank
            && !source.bench && !target.bench && !source.floating && !target.floating
    }

    /// The page a carried tab joins: the one on screen, or, for the tab on
    /// screen itself, the one looked at before it, so every loose tab can be
    /// carried.
    func panelPartner(for source: Tab) -> Tab? {
        guard source === active else { return active }
        return tabs.filter { $0 !== source && panelsMix(source, $0) }.max { $0.touched < $1.touched }
    }

    @discardableResult
    func split(_ source: Tab, with target: Tab, edge: PanelEdge) -> Bool {
        let watched = panelTabs
        guard tabs.contains(where: { $0 === source }), tabs.contains(where: { $0 === target }),
              panelsMix(source, target), panelFits(source, beside: target, edge: edge),
              panels.add(source.id, to: target.id, edge: edge) else { return false }
        for tab in watched { tab.touch() }
        select(source)
        rememberSession()
        return true
    }

    func panelFits(_ source: Tab, beside target: Tab, edge: PanelEdge) -> Bool {
        guard let count = panels.plan(source.id, beside: target.id, edge: edge)?.count else { return false }
        let metrics = ChromeMetrics(size: prefs.interfaceSize)
        let length = edge.horizontal ? panels.frame.width : panels.frame.height
        let minimum = metrics.length(edge.horizontal ? Metrics.panelWidth : Metrics.panelHeight)
        return length >= CGFloat(count) * minimum + CGFloat(count - 1) * metrics.pageInset
    }

    /// Returns true throughout the page region, including its invalid centre.
    /// A release there must never fall through to bookmark/tab reordering.
    func aimPanel(_ tab: Tab, at point: CGPoint) -> Bool {
        let inside = panels.frame.contains(point)
        // A composition's entry stands for several pages; only a loose tab
        // is carried onto the pages, so the face shown is the page moved.
        let carried = inside && tab.space == spaceID && panels.group(tab.id) == nil
        let target = carried ? panelPartner(for: tab) : nil
        let edge = target.flatMap { target in
            PanelEdge.at(point, in: panels.frame).flatMap { edge in
                panelsMix(tab, target) && panelFits(tab, beside: target, edge: edge) ? edge : nil
            }
        }
        panels.aim(tab.id, edge: edge)
        panels.carry(carried ? tab : nil, at: point)
        return inside
    }

    @discardableResult
    func dropPanel(_ tab: Tab, at point: CGPoint) -> Bool {
        if let window = Links.window,
           !CGRect(origin: .zero, size: window.frame.size).contains(point) {
            panels.finish()
            return true
        }
        let inside = panels.frame.contains(point)
        _ = aimPanel(tab, at: point)
        defer { panels.finish() }
        if inside, let edge = panels.preview, let target = panelPartner(for: tab) {
            let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            withAnimation(reduced ? nil : Motion.settle) { _ = split(tab, with: target, edge: edge) }
        }
        return inside
    }

    func changePanels(_ tab: Tab, _ action: (Panels) -> Void) {
        let watched = panelTabs
        action(panels)
        for tab in watched { tab.touch() }
        rememberSession(tab.space)
    }

    func chooseSplit(_ edge: PanelEdge) {
        guard let target = active else { return }
        let candidates = tabs.filter { source in
            panelsMix(source, target) && !(panels.group(target.id)?.members.contains(source.id) ?? false)
        }
        PanelChoice.show(candidates, edge: edge) { [weak self, weak target] source in
            guard let self, let target else { return }
            if !split(source, with: target, edge: edge) { announce("Up to 3 panels in one Space and website store — enlarge the window if needed") }
        }
    }
}

@MainActor
private enum PanelChoice {
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }
    static func show(_ tabs: [Tab], edge: PanelEdge, take: @escaping (Tab) -> Void) {
        let menu = NSMenu(title: "Add \(edge.title) Split")
        var actions: [Action] = []
        for tab in tabs {
            let action = Action { take(tab) }
            actions.append(action)
            let item = NSMenuItem(title: tab.label, action: #selector(Action.fire), keyEquivalent: "")
            item.target = action
            menu.addItem(item)
        }
        if tabs.isEmpty { menu.addItem(withTitle: "Open another page in this Space first", action: nil, keyEquivalent: "") }
        _ = withExtendedLifetime(actions) { menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
    }
}
