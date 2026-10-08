// One window-owned interaction holds the original bookmark and Space identity.
// The native sheet keeps editing above either bookmark layout; only Save writes.
// Its bounded value draft has no page, timer, network request or subscription.
import SwiftUI

@MainActor
final class EnvironmentEditor: ObservableObject {
    struct Request: Identifiable {
        let node: Bookmark
        let bookmarks: Bookmarks
        var id: UUID { node.id }
    }
    @Published var request: Request?

    func begin(_ node: Bookmark, in bookmarks: Bookmarks) {
        request = Request(node: node, bookmarks: bookmarks)
    }
}

struct EnvironmentPresentation: ViewModifier {
    @ObservedObject var editor: EnvironmentEditor

    func body(content: Content) -> some View {
        content.sheet(item: $editor.request) { request in
            EnvironmentForm(request: request) { editor.request = nil }
                .interactiveDismissDisabled()
        }
    }
}

struct EnvironmentForm: View {
    let request: EnvironmentEditor.Request
    let close: () -> Void
    @State private var entries: [BookmarkEnvironment]
    private let initial: [BookmarkEnvironment]
    @State private var checked = false
    @State private var abandoning = false
    @State private var failure: String?
    @FocusState private var focused: UUID?
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    init(request: EnvironmentEditor.Request, close: @escaping () -> Void) {
        self.request = request
        self.close = close
        let entries = request.node.destinations.isEmpty
            ? [BookmarkEnvironment(name: "", url: request.node.url ?? "")]
            : request.node.destinations
        initial = entries
        _entries = State(initialValue: entries)
    }

    private var gap: CGFloat { metrics.length(Metrics.environmentGap) }
    private var problems: [UUID: BookmarkEnvironment.Problem] {
        // Placeholder suggestions only become chosen names on explicit Save.
        BookmarkEnvironment.problems(resolved)
    }
    private var resolved: [BookmarkEnvironment] {
        entries.map { item in
            var item = item
            if item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let suggestion = suggestion(item) { item.name = suggestion }
            return item
        }
    }
    private func suggestion(_ item: BookmarkEnvironment) -> String? {
        // Existing names may be cleared deliberately; only new entries get suggestions.
        guard !request.node.destinations.contains(where: { $0.id == item.id }),
              let url = BookmarkEnvironment.address(item.url) else { return nil }
        return Environment.from(url)?.label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            Text("Associate Environments")
                .font(.headline)
            Text(request.node.title).foregroundStyle(Palette.muted).lineLimit(1)
            Text("Choose a name and the exact address to open. Suggested names can be edited.")
                .foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: gap) {
                Color.clear.frame(width: metrics.length(Metrics.swatchDoor), height: 0)
                Text("Name").frame(width: metrics.length(Metrics.environmentNameWidth), alignment: .leading)
                Text("Address")
            }.foregroundStyle(Palette.muted)
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: gap) {
                        ForEach($entries) { $item in
                            HStack(alignment: .top, spacing: gap) {
                                SwatchPicker(selection: $item.colour)
                                VStack(alignment: .leading, spacing: gap) {
                                    TextField(suggestion(item).map { "\($0) (suggested)" } ?? "Name", text: Binding(get: { item.name }, set: { item.name = $0.uppercased() }))
                                        .focused($focused, equals: item.id)
                                        .accessibilityLabel("Environment name")
                                    if checked, let error = problems[item.id]?.name { errorText(error) }
                                }.frame(width: metrics.length(Metrics.environmentNameWidth))
                                VStack(alignment: .leading, spacing: gap) {
                                    TextField("https://…", text: $item.url)
                                        .accessibilityLabel("Environment address")
                                        .onSubmit(add)
                                    if checked, let error = problems[item.id]?.url { errorText(error) }
                                    if let url = BookmarkEnvironment.address(item.url) {
                                        EnvironmentScope(item: $item, url: url, entries: resolved,
                                                         problem: checked ? problems[item.id]?.path : nil)
                                    }
                                }
                                Button { entries.removeAll { $0.id == item.id } } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove environment")
                                .accessibilityLabel("Remove environment")
                            }.id(item.id)
                        }
                        if entries.isEmpty {
                            Text("No environments. Save to keep this as an ordinary bookmark.")
                                .foregroundStyle(Palette.muted)
                        }
                    }
                }
                .frame(maxHeight: metrics.length(Metrics.environmentEditorHeight))
                .onChange(of: focused) { _, id in
                    if let id { scroll.scrollTo(id) }
                }
            }
            Button("Add Environment", systemImage: "plus", action: add)
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(entries.count >= BookmarkEnvironment.limit)
            if let failure { errorText(failure) }
            HStack {
                Text("Names are labels, not server verification.").foregroundStyle(Palette.muted)
                Spacer(minLength: gap)
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut("s", modifiers: [.command])
            }
        }
        .font(.system(size: metrics.length(Metrics.environmentFont)))
        .foregroundStyle(Palette.ink)
        .textFieldStyle(.roundedBorder)
        .padding(metrics.length(Metrics.environmentInset))
        .frame(width: metrics.length(Metrics.environmentEditorWidth))
        .fixedSize(horizontal: false, vertical: true)
        .glass(.panel, in: RoundedRectangle(cornerRadius: metrics.plateRadius))
        .onAppear { focused = entries.first?.id }
        .confirmationDialog("Discard unsaved changes?", isPresented: $abandoning) {
            Button("Discard Changes", role: .destructive, action: close)
            Button("Keep Editing", role: .cancel) {}
        }
    }

    private func errorText(_ text: String) -> some View {
        Text(text).foregroundStyle(Palette.danger).fixedSize(horizontal: false, vertical: true)
    }
    private func add() {
        guard entries.count < BookmarkEnvironment.limit else { return }
        let item = BookmarkEnvironment(name: "", url: "")
        entries.append(item)
        focused = item.id
    }
    private func cancel() {
        if entries == initial { close() } else { abandoning = true }
    }
    private func save() {
        checked = true
        guard problems.isEmpty else { return }
        guard request.bookmarks.setEnvironments(resolved, for: request.node.id) else {
            failure = "This bookmark is no longer available. Your changes have not been saved."
            return
        }
        close()
    }
}

/// A single quiet door, labelled only when the linked destination is unambiguous.
struct EnvironmentPicker: View {
    let node: Bookmark
    var address: URL? = nil
    var compact = false
    let open: (BookmarkEnvironment) -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        let current = BookmarkEnvironment.current(in: node.destinations, at: address)
        Menu {
            ForEach(node.destinations) { item in
                Button("\(item.name) — \(item.url)") { open(item) }
            }
        } label: {
            // Native Menu flattens a styled label; the overlay keeps its text
            // aligned and coloured independently of the neutral arrow.
            Color.clear
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: metrics.length(current == nil || compact ? Metrics.environmentDoorWidth : Metrics.environmentBadgeWidth + Metrics.environmentGap),
               height: metrics.length(Metrics.environmentBadgeHeight))
        .overlay(alignment: .trailing) {
            HStack(spacing: metrics.length(Metrics.environmentGap / 2)) {
                if let current, !compact {
                    Text(current.badge)
                        .lineLimit(1)
                        .foregroundStyle(current.colour?.ink ?? Palette.muted)
                    Image(systemName: "chevron.down").foregroundStyle(Palette.muted)
                } else {
                    Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Palette.muted)
                }
            }
            .font(.system(size: metrics.length(Metrics.environmentBadgeFont), weight: .semibold))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .help(current.map { "\($0.name) — \($0.url)" } ?? "Open an environment")
        .accessibilityLabel(current.map { "Environment: \($0.name). Choose destination" } ?? "Choose environment for \(node.title)")
    }
}

/// The page's environment at the head of the address bar, in its colour, with
/// the column's menu. Watched here: an edit or a navigation changes the match.
struct EnvironmentChip: View {
    @ObservedObject var bookmarks: Bookmarks
    @ObservedObject var tab: Tab
    let bookmark: Bookmark.ID
    let open: (BookmarkEnvironment) -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        if let node = bookmarks.find(bookmark),
           let current = BookmarkEnvironment.current(in: node.destinations, at: tab.address) {
            Text(current.badge)
                .font(.system(size: metrics.length(Metrics.environmentChipFont), weight: .semibold))
                .foregroundStyle(current.colour?.ink ?? Palette.muted)
                .lineLimit(1)
                .padding(.horizontal, metrics.length(Metrics.environmentChipInset))
                .frame(height: metrics.length(Metrics.environmentChipHeight))
                .background(RoundedRectangle(cornerRadius: metrics.length(Metrics.environmentChipRadius), style: .continuous)
                    .fill(Palette.swatchWash(current.colour)))
                .fixedSize()
                // As in EnvironmentPicker: a native Menu flattens a styled label.
                .overlay {
                    Menu {
                        ForEach(node.destinations) { item in
                            Button("\(item.name) — \(item.url)") { open(item) }
                        }
                    } label: { Color.clear }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }
                .help("\(current.name) — \(current.url)")
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Environment: \(current.name). Choose destination")
        }
    }
}

struct OpenEnvironmentPicker: View {
    let node: Bookmark
    @ObservedObject var tab: Tab
    var compact = false
    let open: (BookmarkEnvironment) -> Void
    var body: some View { EnvironmentPicker(node: node, address: tab.address, compact: compact, open: open) }
}
