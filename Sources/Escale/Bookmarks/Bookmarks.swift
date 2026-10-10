import AppKit
import SwiftUI

// Bookmarks: folders and sites, kept in a small file.
//
// Shown as the app's own kind of list rather than a system menu, on purpose:
// a menu can't be dragged into, and can't be asked a second thing by
// right-clicking it. A folder you actually keep things in wants both.

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    /// Nil for a folder.
    var url: String?
    var children: [Bookmark]?
    /// Absent in older files and ordinary bookmarks (see Environments.swift).
    var environments: [BookmarkEnvironment]?

    var isFolder: Bool { url == nil }

    var host: String? {
        url.flatMap { URL(string: $0)?.host()?.lowercased() }
    }

    static func site(_ title: String, _ url: URL) -> Bookmark {
        Bookmark(title: title.isEmpty ? Address.pretty(url) : title, url: url.absoluteString, children: nil)
    }

    static func folder(_ title: String, _ children: [Bookmark]) -> Bookmark {
        Bookmark(title: title, url: nil, children: children)
    }
}

@MainActor
final class Bookmarks: ObservableObject {
    @Published private(set) var roots: [Bookmark] = []
    let space: UUID

    /// The file it lives in: its space's (see Shelf.swift).
    private let file: URL

    init(space: UUID = Space.firstID, file: URL? = nil) {
        self.space = space
        self.file = file ?? Bookmarks.file(space)
        load()
    }

    var isEmpty: Bool { roots.isEmpty }

    /// How many sites, folders included.
    var count: Int { Bookmarks.count(roots) }

    static func count(_ nodes: [Bookmark]) -> Int {
        nodes.reduce(0) { $0 + ($1.isFolder ? count($1.children ?? []) : 1) }
    }

    /// Every site in the list, in order, folders opened.
    static func urls(_ nodes: [Bookmark]) -> [URL] {
        nodes.flatMap { node -> [URL] in
            if node.isFolder { return urls(node.children ?? []) }
            return node.url.flatMap(URL.init(string:)).map { [$0] } ?? []
        }
    }

    /// Every folder in the tree, each with how deep it sits — for "move to
    /// folder" lists, where a folder three deep should look like it.
    static func folders(_ nodes: [Bookmark], depth: Int = 0) -> [(node: Bookmark, depth: Int)] {
        nodes.flatMap { node -> [(Bookmark, Int)] in
            guard node.isFolder else { return [] }
            return [(node, depth)] + folders(node.children ?? [], depth: depth + 1)
        }
    }

    // MARK: - changing

    /// The page, at the end of the list. Nothing is asked: the title is the
    /// page's, and filing it into a folder is a drag or a right-click away.
    func add(_ url: URL, title: String) {
        guard !contains(url) else { return }
        roots.append(.site(title, url))
        save()
    }

    func contains(_ url: URL) -> Bool {
        func walk(_ nodes: [Bookmark]) -> Bool {
            nodes.contains { $0.url == url.absoluteString || walk($0.children ?? []) }
        }
        return walk(roots)
    }

    func remove(_ id: Bookmark.ID) {
        roots = Bookmarks.prune(id, from: roots)
        save()
    }

    /// Move one saved subtree between Spaces with its IDs intact. The
    /// destination accepts it before the source forgets it, so an invalid
    /// folder target cannot discard the original.
    @discardableResult
    func move(_ id: Bookmark.ID, to destination: Bookmarks, into folderID: Bookmark.ID? = nil,
              before sibling: Bookmark.ID? = nil) -> Bookmark? {
        guard destination !== self, let node = find(id), destination.find(id) == nil else { return nil }
        var placed = destination.roots
        if let folderID {
            guard Bookmarks.insert(node, into: folderID, before: sibling, nodes: &placed) else { return nil }
        } else {
            placed.insert(node, at: Bookmarks.place(of: sibling, in: placed))
        }
        destination.roots = placed
        destination.save()
        remove(id)
        return node
    }

    func find(_ id: Bookmark.ID) -> Bookmark? {
        func walk(_ nodes: [Bookmark]) -> Bookmark? {
            for node in nodes {
                if node.id == id { return node }
                if let found = walk(node.children ?? []) { return found }
            }
            return nil
        }
        return walk(roots)
    }

    private static func prune(_ id: Bookmark.ID, from nodes: [Bookmark]) -> [Bookmark] {
        nodes.compactMap { node in
            if node.id == id { return nil }
            var copy = node
            if let kids = node.children { copy.children = prune(id, from: kids) }
            return copy
        }
    }

    /// Takes a bookmark or a whole folder out of wherever it currently sits
    /// and puts it at the end of another folder's children — or back at the
    /// top level when `folderID` is nil. Moving a folder into its own
    /// children is refused rather than allowed to erase it by looping it
    /// inside itself; moving it onto itself is simply nothing to do.
    /// `sibling` puts it just before that one instead of at the end, for a
    /// drag in the column (see Shelf.swift).
    func move(_ id: Bookmark.ID, into folderID: Bookmark.ID?, before sibling: Bookmark.ID? = nil) {
        guard id != folderID else { return }
        var working = roots
        guard let node = Bookmarks.detach(id, from: &working) else { return }
        if let folderID {
            guard !Bookmarks.holds(folderID, node) else { return }
            guard Bookmarks.insert(node, into: folderID, before: sibling, nodes: &working) else { return }
        } else {
            working.insert(node, at: Bookmarks.place(of: sibling, in: working))
        }
        roots = working
        save()
    }

    /// Replace the target site with a folder in its original place. Both
    /// removals and the replacement happen in one snapshot, so a stale drag
    /// cannot lose either bookmark or leave a half-created folder on disk.
    @discardableResult
    func merge(_ source: Bookmark.ID, with target: Bookmark.ID) -> Bookmark? {
        guard let merged = Bookmarks.merged(roots, source: source, target: target) else { return nil }
        roots = merged.nodes
        save()
        return merged.folder
    }

    static func merged(_ nodes: [Bookmark], source: Bookmark.ID, target: Bookmark.ID) -> (nodes: [Bookmark], folder: Bookmark)? {
        guard source != target else { return nil }
        var working = nodes
        guard let carried = detach(source, from: &working), !carried.isFolder,
              let folder = wrap(target, with: carried, in: &working)
        else { return nil }
        return (working, folder)
    }

    private static func wrap(_ id: Bookmark.ID, with carried: Bookmark, in nodes: inout [Bookmark]) -> Bookmark? {
        for index in nodes.indices {
            if nodes[index].id == id {
                guard !nodes[index].isFolder else { return nil }
                let folder = Bookmark.folder("New Folder", [nodes[index], carried])
                nodes[index] = folder
                return folder
            }
            guard var children = nodes[index].children else { continue }
            if let folder = wrap(id, with: carried, in: &children) {
                nodes[index].children = children
                return folder
            }
        }
        return nil
    }

    private static func detach(_ id: Bookmark.ID, from nodes: inout [Bookmark]) -> Bookmark? {
        for i in nodes.indices {
            if nodes[i].id == id { return nodes.remove(at: i) }
            guard nodes[i].children != nil else { continue }
            var kids = nodes[i].children!
            if let found = detach(id, from: &kids) {
                nodes[i].children = kids
                return found
            }
        }
        return nil
    }

    @discardableResult
    private static func insert(_ node: Bookmark, into id: Bookmark.ID, before sibling: Bookmark.ID? = nil, nodes: inout [Bookmark]) -> Bool {
        for i in nodes.indices {
            if nodes[i].id == id, nodes[i].isFolder {
                var kids = nodes[i].children ?? []
                kids.insert(node, at: place(of: sibling, in: kids))
                nodes[i].children = kids
                return true
            }
            guard nodes[i].children != nil else { continue }
            var kids = nodes[i].children!
            if insert(node, into: id, before: sibling, nodes: &kids) {
                nodes[i].children = kids
                return true
            }
        }
        return false
    }

    /// Where `sibling` sits among `nodes`, or their end when it isn't one of them.
    private static func place(of sibling: Bookmark.ID?, in nodes: [Bookmark]) -> Int {
        sibling.flatMap { id in nodes.firstIndex { $0.id == id } } ?? nodes.count
    }

    /// `id` is `node` itself, or somewhere inside it — also used by the
    /// outline to keep a folder out of its own "move to" list.
    fileprivate static func holds(_ id: Bookmark.ID, _ node: Bookmark) -> Bool {
        node.id == id || (node.children ?? []).contains { holds(id, $0) }
    }

    /// The existing shelf bench seeds synthetic rows only in isolated worlds.
    func take(_ nodes: [Bookmark], from name: String) {
        guard Store.testing, !nodes.isEmpty else { return }
        if roots.isEmpty { roots = nodes }
        else {
            roots.removeAll { $0.isFolder && $0.title == name }
            roots.append(.folder(name, nodes))
        }
        save()
    }

    /// The migration plan preserves existing identities, folders and edits.
    func importPlanned(_ nodes: [Bookmark], done: @escaping (Bool) -> Void) {
        roots = nodes
        let writer = Writer.to(file)
        writer.save(nodes)
        writer.acknowledge(done)
    }

    // MARK: - the file

    /// The first space's is the file there always was; each other space
    /// keeps its own beside it, as its session does.
    private static func file(_ space: UUID) -> URL {
        Store.file(space == Space.firstID ? "bookmarks.json" : "bookmarks-\(space.uuidString).json")
    }

    /// In turn with its saves (see Writer.swift): a snapshot still waiting
    /// can't put a deleted space's bookmarks back.
    static func erase(space: UUID) {
        guard space != Space.firstID else { return }
        Writer.to(file(space)).remove()
    }

    /// New bookmark identities keep the copy independent of its source even
    /// when an extension remembers a bookmark ID.
    static func copy(_ roots: [Bookmark], to space: UUID, identities: [UUID: UUID] = [:]) -> Bool {
        guard space != Space.firstID else { return false }
        func fresh(_ nodes: [Bookmark]) -> [Bookmark] {
            nodes.map { node in
                var made = node
                made.id = identities[node.id] ?? UUID()
                if let children = node.children { made.children = fresh(children) }
                return made
            }
        }
        let writer = Writer.to(file(space))
        writer.save(fresh(roots))
        writer.flush()
        return writer.failure == nil
    }

    // MARK: - for extensions

    /// A page or a folder filed under `parent`, or at the top level for nil
    /// or a folder that isn't there. What chrome.bookmarks.create does.
    @discardableResult
    func insert(_ node: Bookmark, into parent: Bookmark.ID?) -> Bookmark {
        if let parent {
            var nodes = roots
            if Bookmarks.insert(node, into: parent, nodes: &nodes) {
                roots = nodes
                save()
                return node
            }
        }
        roots.append(node)
        save()
        return node
    }

    /// A new title or address for one that is kept. chrome.bookmarks.update.
    func update(_ id: Bookmark.ID, title: String?, url: String?) {
        func walk(_ nodes: inout [Bookmark]) -> Bool {
            for i in nodes.indices {
                if nodes[i].id == id {
                    if let title { nodes[i].title = title }
                    if let url, !nodes[i].isFolder { nodes[i].url = url }
                    return true
                }
                guard var kids = nodes[i].children else { continue }
                if walk(&kids) {
                    nodes[i].children = kids
                    return true
                }
            }
            return false
        }
        var nodes = roots
        if walk(&nodes) {
            roots = nodes
            save()
        }
    }

    /// An address typed for a bookmark, read as the address field reads one:
    /// nil when it is empty or not a place, or a web address with no host.
    static func address(_ typed: String) -> URL? {
        guard let url = Address.url(from: typed) else { return nil }
        if let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
           url.host()?.isEmpty ?? true { return nil }
        return url
    }

    /// "Edit…" on a site: its title and address together, or nothing when the
    /// address is refused. An address left as it was is kept even when it is
    /// one the field would not take, an extension's page say; an empty title
    /// keeps the old one.
    @discardableResult
    func edit(_ id: Bookmark.ID, title: String, address: String) -> Bool {
        guard let node = find(id), let old = node.url else { return false }
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = typed == old ? old : Bookmarks.address(typed)?.absoluteString else { return false }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id, title: title.isEmpty ? nil : title, url: url)
        return true
    }

    /// "New Folder": an empty one inside `parent`, or at the top level, just
    /// after `sibling` when it is there and at the end otherwise.
    @discardableResult
    func newFolder(in parent: Bookmark.ID?, after sibling: Bookmark.ID? = nil) -> Bookmark {
        let folder = Bookmark.folder("New Folder", [])
        let level = parent.flatMap { find($0)?.children } ?? roots
        let next = sibling.flatMap { id in level.firstIndex { $0.id == id } }.map { $0 + 1 }
        let before = next.flatMap { level.indices.contains($0) ? level[$0].id : nil }
        var nodes = roots
        if let parent, Bookmarks.insert(folder, into: parent, before: before, nodes: &nodes) {
            roots = nodes
        } else {
            roots.insert(folder, at: parent == nil ? Bookmarks.place(of: before, in: roots) : roots.count)
        }
        save()
        return folder
    }

    /// Associations are one atomic bookmark edit; an abandoned draft never reaches here.
    @discardableResult
    func setEnvironments(_ entries: [BookmarkEnvironment], for id: Bookmark.ID) -> Bool {
        guard BookmarkEnvironment.valid(entries) else { return false }
        func walk(_ nodes: inout [Bookmark]) -> Bool {
            for i in nodes.indices {
                if nodes[i].id == id {
                    guard !nodes[i].isFolder else { return false }
                    nodes[i].environments = entries.isEmpty ? nil : entries.map {
                        var item = $0
                        item.name = BookmarkEnvironment.normalName(item.name)
                        item.url = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
                        return item
                    }
                    return true
                }
                if var children = nodes[i].children, walk(&children) {
                    nodes[i].children = children
                    return true
                }
            }
            return false
        }
        var nodes = roots
        guard walk(&nodes) else { return false }
        roots = nodes
        save()
        return true
    }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        guard let list = try? JSONDecoder().decode([Bookmark].self, from: data) else {
            Store.quarantine(file)
            return
        }
        func valid(_ nodes: [Bookmark]) -> Bool {
            nodes.allSatisfy { BookmarkEnvironment.valid($0.destinations)
                && (!$0.isFolder || $0.destinations.isEmpty) && valid($0.children ?? []) }
        }
        guard valid(list) else { Store.quarantine(file); return }
        roots = list
    }

    /// Written in the order it changed, off the main thread (see Writer.swift).
    private func save() {
        Writer.to(file).save(roots)
    }
}

// MARK: - the tree, drawn

/// The list itself: folders that open in place rather than to the side, each
/// row draggable into another folder or back out to the top, each row good
/// for a right-click too. Used both in the small dropdown off the button and
/// in the full manager — the interaction is the same size either way, the
/// keyboard's included (Walk.swift).
struct BookmarkOutline: View {
    let browser: Browser
    @ObservedObject var bookmarks: Bookmarks
    /// The scroll view it is in, to keep the chosen row in sight.
    let list: ScrollViewProxy
    let open: (URL) -> Void

    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded: Set<Bookmark.ID> = []
    @State private var dragging: Bookmark.ID?
    @State private var overRoot = false
    @StateObject private var mergeHover = HoverDwell()
    @State private var naming: Bookmark.ID?
    @State private var folderName = ""
    /// None until the arrows choose one.
    @State private var chosen: Bookmark.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            rows(bookmarks.roots, depth: 0, parent: nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(overRoot ? Palette.wash : .clear)
        .onDrop(of: [.text], isTargeted: $overRoot) { providers in drop(providers, into: nil) }
        .onDisappear { mergeHover.cancel() }
        .onChange(of: chosen) { _, id in if let id { list.scrollTo(id) } }
        // A name being typed keeps every key.
        .walking(move: move, open: { _ in chosenNode.map(act) }, remove: { chosenNode.map(remove) },
                 fold: { open in
                     guard let node = chosenNode, node.isFolder, expanded.contains(node.id) != open else { return }
                     toggle(node.id)
                 }, while: { naming == nil && !browser.tuning })
    }

    /// The rows on show, top to bottom: a folder's own only while it is open.
    static func shown(_ nodes: [Bookmark], open: Set<Bookmark.ID>) -> [Bookmark] {
        nodes.flatMap { node in
            [node] + (node.isFolder && open.contains(node.id) ? shown(node.children ?? [], open: open) : [])
        }
    }

    private var chosenNode: Bookmark? {
        chosen.flatMap { id in Self.shown(bookmarks.roots, open: expanded).first { $0.id == id } }
    }

    private func move(_ by: Int) {
        let rows = Self.shown(bookmarks.roots, open: expanded)
        chosen = Walk.step(rows.map(\.id), from: chosen, by: by)
        if let node = rows.first(where: { $0.id == chosen }) { Walk.say(node.title) }
    }

    /// Return does what a click does: a folder opens or closes, a site opens
    /// — apart with ⌘ held, which `Browser.visit` reads from the key as it
    /// does from a click.
    private func act(_ node: Bookmark) {
        if node.isFolder { toggle(node.id) } else if let url = node.url.flatMap(URL.init(string:)) { open(url) }
    }

    private func remove(_ node: Bookmark) {
        // A folder's own rows go with it: the next row is the one after them.
        chosen = Walk.after(Self.shown(bookmarks.roots, open: expanded.subtracting([node.id])).map(\.id), removing: node.id)
        bookmarks.remove(node.id)
    }

    @ViewBuilder
    private func rows(_ nodes: [Bookmark], depth: Int, parent: Bookmark.ID?) -> some View {
        ForEach(nodes) { node in
            Row(
                node: node,
                browser: browser, bookmarks: bookmarks,
                depth: depth,
                open: node.url.flatMap(URL.init(string:)).map { url in { open(url) } },
                isOpen: expanded.contains(node.id),
                chosen: chosen == node.id,
                dragging: dragging == node.id,
                merging: mergeHover.target == node.id,
                pulsing: mergeHover.pulsing && (mergeHover.source == node.id || mergeHover.target == node.id),
                mergeReady: mergeHover.ready && mergeHover.target == node.id,
                naming: naming == node.id, folderName: $folderName,
                finishName: finishNaming, rename: { startNaming(node) },
                newFolder: { newFolder(beside: node, in: parent) },
                toggle: node.isFolder ? { toggle(node.id) } : nil,
                moveTargets: Bookmarks.folders(bookmarks.roots).filter { !Bookmarks.holds($0.node.id, node) },
                moveTo: { bookmarks.move(node.id, into: $0) },
                remove: { bookmarks.remove(node.id) }
            )
            .onDrag {
                dragging = node.id
                return NSItemProvider(object: node.id.uuidString as NSString)
            }
            .modifier(DropOnto(targetChanged: { targeted in
                                   guard !node.isFolder else { return }
                                   if targeted, let dragging, let carried = bookmarks.find(dragging), !carried.isFolder {
                                       mergeHover.aim(source: dragging, at: node.id)
                                   }
                                   else if mergeHover.target == node.id { mergeHover.cancel() }
                               }, action: { providers in drop(providers, onto: node) }))
            .transition(depth > 0 ? Motion.unfold(reduced: reduceMotion) : .opacity)

            if node.isFolder, expanded.contains(node.id) {
                if let kids = node.children, !kids.isEmpty {
                    // Type-erased: a view that calls itself can't let Swift
                    // infer its own opaque return type from its own body.
                    AnyView(rows(kids, depth: depth + 1, parent: node.id))
                } else {
                    Text("Empty")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.faint)
                        .padding(.leading, indent(depth + 1) + 26)
                        .padding(.vertical, 5)
                        .transition(Motion.unfold(reduced: reduceMotion))
                }
            }
        }
    }

    private func toggle(_ id: Bookmark.ID) {
        withAnimation(reduceMotion ? nil : Motion.settle) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    private func startNaming(_ folder: Bookmark) {
        folderName = folder.title
        naming = folder.id
    }

    /// Inside a folder, or beside a site; named where it appears.
    private func newFolder(beside node: Bookmark, in parent: Bookmark.ID?) {
        let folder = withAnimation(Motion.settle) {
            node.isFolder ? bookmarks.newFolder(in: node.id) : bookmarks.newFolder(in: parent, after: node.id)
        }
        if node.isFolder { withAnimation(Motion.settle) { _ = expanded.insert(node.id) } }
        startNaming(folder)
    }

    private func finishNaming() {
        guard let naming else { return }
        let title = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { bookmarks.update(naming, title: title, url: nil) }
        self.naming = nil
    }

    private func drop(_ providers: [NSItemProvider], onto node: Bookmark) -> Bool {
        if node.isFolder { return drop(providers, into: node.id) }
        guard let dragging, let provider = providers.first(where: { $0.canLoadObject(ofClass: String.self) }) else { return false }
        let accepted = mergeHover.accepts(source: dragging, target: node.id)
        mergeHover.cancel()
        self.dragging = nil
        guard accepted else { return true }
        _ = provider.loadObject(ofClass: String.self) { text, _ in
            guard let text, UUID(uuidString: text) == dragging else { return }
            DispatchQueue.main.async {
                guard let folder = withAnimation(Motion.settle, { self.bookmarks.merge(dragging, with: node.id) }) else { return }
                withAnimation(Motion.settle) { _ = self.expanded.insert(folder.id) }
                self.startNaming(folder)
            }
        }
        return true
    }

    private func drop(_ providers: [NSItemProvider], into folderID: Bookmark.ID?) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: String.self) }) else { return false }
        _ = provider.loadObject(ofClass: String.self) { text, _ in
            guard let text, let id = UUID(uuidString: text) else { return }
            DispatchQueue.main.async {
                self.bookmarks.move(id, into: folderID)
                if let folderID { withAnimation(Motion.settle) { _ = self.expanded.insert(folderID) } }
                self.dragging = nil
            }
        }
        return true
    }

    private func indent(_ depth: Int) -> CGFloat { CGFloat(depth) * 18 }

    /// Folder rows accept drops immediately; site rows accept a local
    /// bookmark drag only after the shared hover clock is ready.
    private struct DropOnto: ViewModifier {
        let targetChanged: (Bool) -> Void
        let action: ([NSItemProvider]) -> Bool
        @State private var targeted = false

        func body(content: Content) -> some View {
            content
                .background(targeted ? Palette.hover : .clear)
                .onDrop(of: [.text], isTargeted: $targeted, perform: action)
                .onChange(of: targeted) { _, value in targetChanged(value) }
        }
    }

    private struct Row: View {
        let node: Bookmark
        let browser: Browser
        let bookmarks: Bookmarks
        let depth: Int
        /// Nil for a folder — folders open in place, not out to a page.
        let open: (() -> Void)?
        let isOpen: Bool
        let chosen: Bool
        let dragging: Bool
        let merging: Bool
        let pulsing: Bool
        let mergeReady: Bool
        let naming: Bool
        @Binding var folderName: String
        let finishName: () -> Void
        let rename: () -> Void
        let newFolder: () -> Void
        let toggle: (() -> Void)?
        let moveTargets: [(node: Bookmark, depth: Int)]
        let moveTo: (Bookmark.ID?) -> Void
        let remove: () -> Void

        @State private var hovering = false
        @FocusState private var nameFocused: Bool

        var body: some View {
            HStack(spacing: 8) {
                if node.isFolder {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Palette.faint)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 10)
                    Mark(icon: nil, letter: "", size: 15)
                        .overlay(
                            Image(systemName: "folder.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Palette.muted)
                        )
                } else {
                    Spacer().frame(width: 10)
                    SiteMark(host: node.host ?? "", letter: String((node.host ?? "•").prefix(1)).uppercased(), size: 15)
                }
                if naming {
                    TextField("Folder name", text: $folderName)
                        .font(.system(size: 12.5))
                        .textFieldStyle(.plain)
                        .focused($nameFocused)
                        .onSubmit(finishName)
                        .onAppear { DispatchQueue.main.async { nameFocused = true } }
                        .onChange(of: nameFocused) { _, focused in if !focused { finishName() } }
                } else {
                    Text(node.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if mergeReady {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
                if !node.destinations.isEmpty {
                    if let tab = browser.tabs.first(where: { browser.shelfTabs[$0.id] == node.id && $0.pin == nil }) {
                        OpenEnvironmentPicker(node: node, tab: tab) {
                            browser.openEnvironment($0, bookmark: node.id, space: bookmarks.space)
                        }
                    } else {
                        EnvironmentPicker(node: node) {
                            browser.openEnvironment($0, bookmark: node.id, space: bookmarks.space)
                        }
                    }
                }
                if node.isFolder, let kids = node.children, !kids.isEmpty {
                    Text("\(Bookmarks.count(kids))")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                }
            }
            .padding(.leading, CGFloat(depth) * 18 + 10)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(merging || chosen ? Palette.wash : (hovering ? Palette.hover : .clear)))
            .contentShape(Rectangle())
            .opacity(dragging ? (pulsing ? 0.7 : 0.35) : 1)
            .scaleEffect(pulsing ? 1.035 : 1)
            .onTapGesture { if !naming { open?() ?? toggle?() } }
            .onHover { hovering = $0 }
            .contextMenu {
                if let open {
                    Button(action: open) { Label("Open", systemImage: "arrow.up.forward") }
                    Button { browser.openInNewTab(node) } label: { Label("Open in New Tab", systemImage: "plus.square.on.square") }
                    Divider()
                }
                if node.isFolder {
                    Button { browser.openAll(node) } label: { Label("Open All in Tabs", systemImage: "square.stack") }
                        .disabled(Bookmarks.count(node.children ?? []) == 0)
                    Divider()
                } else {
                    Button { browser.copyLink(node) } label: { Label("Copy Link", systemImage: "link") }
                    Button { browser.pinBookmark(node) } label: { Label("Pin as Tab", systemImage: "pin") }
                    LinkRouteMenu(browser: browser, address: node.url.flatMap(URL.init(string:)), space: bookmarks.space)
                    Button { browser.editEnvironments(node, in: bookmarks) } label: {
                        Label("Associate Environments…", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                }
                Menu {
                    Button { moveTo(nil) } label: { Label("Top Level", systemImage: "tray") }
                    if !moveTargets.isEmpty {
                        Divider()
                        ForEach(moveTargets, id: \.node.id) { target in
                            Button { moveTo(target.node.id) } label: {
                                Label(String(repeating: "   ", count: target.depth) + target.node.title, systemImage: "folder.fill")
                            }
                        }
                    }
                } label: { Label("Move to", systemImage: "folder.fill") }
                if node.isFolder {
                    Button(action: rename) { Label("Rename", systemImage: "pencil") }
                } else {
                    Button { browser.editBookmark(node, in: bookmarks) } label: { Label("Edit…", systemImage: "pencil") }
                }
                Button(action: newFolder) { Label("New Folder", systemImage: "folder.badge.plus") }
                Divider()
                Button(role: .destructive, action: remove) { Label("Remove", systemImage: "trash") }
            }
            .animation(Motion.quick, value: hovering)
            .animation(Motion.quick, value: dragging)
            .animation(Motion.quick, value: merging)
            .animation(Motion.quick, value: mergeReady)
            .animation(Motion.bookmarkPulse, value: pulsing)
        }
    }
}

/// The button's dropdown: the tree, and the two things that aren't in it.
struct BookmarksDropdown: View {
    @ObservedObject var browser: Browser
    @ObservedObject var bookmarks: Bookmarks

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if bookmarks.isEmpty {
                Text("No bookmarks yet")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .padding(14)
            } else {
                ScrollViewReader { list in
                    ScrollView {
                        BookmarkOutline(browser: browser, bookmarks: bookmarks, list: list) { url in
                            browser.pickBookmark(url)
                        }
                        .padding(6)
                    }
                }
                .frame(maxHeight: 360)
            }
            Divider().overlay(Palette.hairline)
            VStack(spacing: 1) {
                Foot("bookmark", "Add This Page") { browser.bookmarkCurrent() }
                Foot(nil, "Manage Bookmarks…") { browser.bookmarking = true }
            }
            .padding(6)
        }
        .frame(width: 280)
        // The popover's own material shows through (Glass.swift).
        .popoverGround()
    }

    private struct Foot: View {
        let symbol: String?
        let title: String
        let act: () -> Void
        @State private var hovering = false

        init(_ symbol: String?, _ title: String, act: @escaping () -> Void) {
            self.symbol = symbol
            self.title = title
            self.act = act
        }

        var body: some View {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Palette.muted).frame(width: 14)
                } else {
                    Spacer().frame(width: 14)
                }
                Text(title).font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.wash : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: act)
            .onHover { hovering = $0 }
        }
    }
}

/// The full list, for taking things out of it or bringing more in.
struct BookmarksPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var bookmarks: Bookmarks

    var body: some View {
        Plate("Bookmarks", width: 600, close: { browser.bookmarking = false }) {
            if bookmarks.isEmpty {
                Card { Nothing("Nothing kept yet. Add this page from the Bookmarks menu, or bring yours in below.") }
            } else {
                ScrollViewReader { list in
                    ScrollView(showsIndicators: false) {
                        Card {
                            BookmarkOutline(browser: browser, bookmarks: bookmarks, list: list) { url in
                                browser.pickBookmark(url)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 6)
                        }
                        .padding(.bottom, 2)
                    }
                }
                .frame(maxHeight: 440)
            }
        } foot: {
            HStack(spacing: 8) {
                Pill("Import bookmarks…") { browser.showMigration() }
                Spacer()
                Text(bookmarks.count == 1 ? "1 bookmark" : "\(bookmarks.count) bookmarks")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
        }
    }
}

/// The bookmarks in the menu bar's Bookmarks menu, made by AppKit rather
/// than SwiftUI. SwiftUI makes a menu bar's items all at once, folders
/// and all, before the app has finished launching: 1,500 bookmarks, as a
/// Chrome import brings, held the window back by 230 ms at every launch.
/// Here the top of the list is made as the menu opens, and a folder's
/// items as that folder opens.
///
/// SwiftUI keeps its own two items, and its own delegate, which lays the
/// menu out afresh each time it opens — anything added beside them was
/// gone by then. So its delegate is wrapped: SwiftUI does its update,
/// then the bookmarks go in after it. SwiftUI puts its delegate back on
/// every update, so the wrapping is put back too (see `start`).
@MainActor
final class BookmarkMenu: NSObject, NSMenuDelegate {
    static let shared = BookmarkMenu()

    private weak var browser: Browser?
    private var watch: [Any] = []
    private let relay = Relay()
    /// What each folder's submenu holds, until it opens.
    private var folders: [ObjectIdentifier: [Bookmark]] = [:]
    /// The items put in here, among SwiftUI's own.
    fileprivate static let mark = 0x5EAC

    func start(for browser: Browser) {
        guard self.browser == nil else { return }
        self.browser = browser
        relay.after = { [weak self] menu in self?.fill(menu) }
        // SwiftUI puts its own delegate back whenever it updates the menu
        // bar, which is whenever anything in the window changes. So: after
        // each event, and as the menu bar starts to be used, before any of
        // its menus opens.
        let centre = NotificationCenter.default
        watch = [
            centre.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.wrap() }
            },
            centre.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] note in
                MainActor.assumeIsolated {
                    guard (note.object as? NSMenu) === NSApp.mainMenu else { return }
                    self?.wrap()
                }
            },
        ]
        wrap()
    }

    private func wrap() {
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Bookmarks" })?.submenu,
              menu.delegate !== relay
        else { return }
        relay.inner = menu.delegate
        menu.delegate = relay
    }

    /// How many items this has put in the menu, for the bench.
    var count: Int {
        NSApp.mainMenu?.items.first(where: { $0.title == "Bookmarks" })?.submenu?.items.filter { $0.tag == Self.mark }.count ?? 0
    }

    /// The top of the list, after SwiftUI's items, in place of any left
    /// from the last time.
    private func fill(_ menu: NSMenu) {
        for item in menu.items where item.tag == Self.mark { menu.removeItem(item) }
        folders = [:]
        guard let roots = browser?.bookmarks.roots, !roots.isEmpty else { return }
        let line = NSMenuItem.separator()
        line.tag = Self.mark
        menu.addItem(line)
        for item in items(for: roots) { menu.addItem(item) }
    }

    private func items(for nodes: [Bookmark]) -> [NSMenuItem] {
        nodes.compactMap { node in
            let item: NSMenuItem
            if node.isFolder {
                item = NSMenuItem(title: node.title, action: nil, keyEquivalent: "")
                let sub = NSMenu(title: node.title)
                sub.delegate = self
                folders[ObjectIdentifier(sub)] = node.children ?? []
                item.submenu = sub
            } else if let text = node.url, let url = URL(string: text) {
                item = NSMenuItem(title: node.title, action: #selector(open(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
            } else {
                return nil
            }
            item.tag = Self.mark
            return item
        }
    }

    /// A folder, opening.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let kids = folders[ObjectIdentifier(menu)] else { return }
        menu.removeAllItems()
        let made = items(for: kids)
        if made.isEmpty {
            let empty = NSMenuItem(title: "Empty", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for item in made { menu.addItem(item) }
    }

    @objc private func open(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        browser?.visit(url)
    }

    /// SwiftUI's delegate, with the bookmarks put in after its update.
    /// Everything else it answers goes straight to it.
    private final class Relay: NSObject, NSMenuDelegate {
        weak var inner: NSMenuDelegate?
        var after: ((NSMenu) -> Void)?

        func menuNeedsUpdate(_ menu: NSMenu) {
            inner?.menuNeedsUpdate?(menu)
            MainActor.assumeIsolated { after?(menu) }
        }

        func menuDidClose(_ menu: NSMenu) { inner?.menuDidClose?(menu) }

        /// Only for its own items: the bookmarks aren't SwiftUI's to know.
        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            guard item?.tag != BookmarkMenu.mark else { return }
            inner?.menu?(menu, willHighlight: item)
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (inner?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? { inner }
    }
}
