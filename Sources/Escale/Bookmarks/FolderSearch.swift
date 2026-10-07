import SwiftUI

// A folder in the column can be searched without opening it, as in Arc.
// The pointer resting a moment on a shut folder that holds sites opens
// a popover beside it, with a field and every site in the folder, its
// subfolders' included, in the folder's own order. It closes when the
// pointer has left both the row and the popover, unless the keyboard has
// been used in it.
//
// The sites are taken from the folder once, when the popover opens, and
// nothing is kept once it closes. Each keystroke walks them with `Terms`, the
// address field's matcher, over the title and the address: the closest
// matches first, the folder's order within each. A row says when its page
// was last opened in this Space, from the history already in memory, or its
// address when it never was.
//
// A site opens as its row in the column does (Browser.openShelf): back to its
// own tab when that is open, or into a new one that belongs to it. The arrows
// walk the list, Return opens the chosen site, Escape closes.

struct FolderSearch: View {
    let browser: Browser
    let folder: Bookmark
    /// Keeps the popover open: the pointer is on it, or the keyboard has been.
    @Binding var held: Bool
    let close: () -> Void

    /// Taken once: the popover measures its first frame from them.
    private let sites: [Bookmark]
    @State private var found: [Bookmark]
    @State private var typed = ""
    @State private var chosen = 0
    @FocusState private var focused: Bool
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    /// Typed in or walked with the arrows: from then on only Escape, a click
    /// elsewhere or a site chosen closes it, wherever the pointer goes.
    @State private var engaged = false

    init(browser: Browser, folder: Bookmark, held: Binding<Bool>, close: @escaping () -> Void) {
        self.browser = browser
        self.folder = folder
        _held = held
        self.close = close
        sites = FolderSearch.sites(folder.children ?? [])
        _found = State(initialValue: sites)
    }

    /// Every site under `nodes`, depth first, as the folder lists them.
    static func sites(_ nodes: [Bookmark]) -> [Bookmark] {
        nodes.flatMap { $0.isFolder ? sites($0.children ?? []) : [$0] }
    }

    /// The sites that answer `typed`, closest first; the folder's order
    /// stands within one strength. All of them, in order, for nothing typed.
    static func matching(_ sites: [Bookmark], _ typed: String) -> [Bookmark] {
        let terms = Terms(typed)
        guard !terms.isEmpty else { return sites }
        return sites.enumerated()
            .compactMap { index, site in
                terms.match([site.title, site.url.flatMap(URL.init(string:)).map(Address.pretty) ?? ""])
                    .map { (site: site, match: $0, index: index) }
            }
            .sorted { ($0.match, $0.index) < ($1.match, $1.index) }
            .map(\.site)
    }

    var body: some View {
        let history = browser.history
        VStack(spacing: 0) {
            HStack(spacing: metrics.length(Metrics.searchInset)) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: metrics.length(11)))
                    .foregroundStyle(Palette.muted)
                TextField("", text: $typed, prompt: Text("Search \(folder.title)…").foregroundColor(Palette.muted))
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .foregroundStyle(Palette.ink)
                    .focused($focused)
                    .accessibilityLabel("Search \(folder.title)")
                    .onSubmit(openChosen)
                    .onKeyPress(.downArrow) { walk(1); return .handled }
                    .onKeyPress(.upArrow) { walk(-1); return .handled }
                    .onExitCommand(perform: close)
            }
            .font(.system(size: metrics.length(Metrics.searchFont)))
            .padding(.horizontal, metrics.length(Metrics.searchInset + 2))
            .frame(height: metrics.length(Metrics.searchFieldHeight))
            Rectangle().fill(Palette.hairline).frame(height: 1)

            if found.isEmpty {
                Text(sites.isEmpty ? "Nothing in this folder" : "No matches")
                    .font(.system(size: metrics.length(12.5)))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, metrics.length(Metrics.searchInset + 2))
                    .frame(height: metrics.length(Metrics.folderSearchRow))
            } else {
                let row = metrics.length(Metrics.folderSearchRow)
                let gap = metrics.length(Metrics.searchGap)
                ScrollViewReader { scroll in
                    ScrollView(showsIndicators: false) {
                        // Lazy, so a folder of hundreds builds only what is in view.
                        LazyVStack(spacing: 0) {
                            ForEach(Array(found.enumerated()), id: \.element.id) { index, site in
                                FolderSearchRow(site: site, history: history, chosen: index == chosen, height: row)
                                    .onHover { if $0 { chosen = index } }
                                    .onTapGesture { open(site) }
                            }
                        }
                        .padding(gap)
                    }
                    .frame(height: CGFloat(min(found.count, Metrics.folderSearchRows)) * row + 2 * gap)
                    .onChange(of: chosen) { _, index in
                        if found.indices.contains(index) { scroll.scrollTo(found[index].id) }
                    }
                }
            }
        }
        .frame(width: metrics.length(Metrics.folderSearchWidth))
        // The popover's own material shows through (Glass.swift).
        .popoverGround()
        // A turn later, once the popover is the key window: asked sooner,
        // the field's focus does not hold.
        .onAppear { DispatchQueue.main.async { focused = true } }
        // Once per keystroke, not per redraw: the pointer moving over the
        // rows redraws them too.
        .onChange(of: typed) { _, typed in
            found = FolderSearch.matching(sites, typed)
            chosen = 0
            engage()
        }
        .onHover { held = $0 || engaged }
    }

    private func engage() {
        engaged = true
        held = true
    }

    private func walk(_ step: Int) {
        engage()
        guard !found.isEmpty else { return }
        chosen = min(max(chosen + step, 0), found.count - 1)
    }

    private func openChosen() {
        if found.indices.contains(chosen) { open(found[chosen]) }
    }

    private func open(_ site: Bookmark) {
        close()
        browser.openShelf(site)
    }
}

/// One site of the folder: its mark, its title, and when it was last opened.
private struct FolderSearchRow: View {
    let site: Bookmark
    let history: History
    let chosen: Bool
    let height: CGFloat
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        let url = site.url.flatMap(URL.init(string:))
        HStack(spacing: metrics.length(Metrics.searchInset)) {
            SiteMark(host: site.host ?? "", letter: String((site.host ?? "•").prefix(1)).uppercased(),
                     size: metrics.length(Metrics.navigationIcon))
            VStack(alignment: .leading, spacing: metrics.length(1)) {
                Text(site.title)
                    .font(.system(size: metrics.length(12.5)))
                    .foregroundStyle(Palette.ink)
                Text(url.map(detail) ?? "")
                    .font(.system(size: metrics.length(11)))
                    .foregroundStyle(Palette.muted)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, metrics.length(6))
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: metrics.length(Metrics.searchRowRadius), style: .continuous)
                .fill(chosen ? Palette.wash : .clear)
        )
        .contentShape(Rectangle())
        .help(site.url ?? site.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }

    private func detail(_ url: URL) -> String {
        guard let last = history.last(url) else { return Address.pretty(url) }
        return Date().timeIntervalSince(last) < 60 ? "Just now" : last.formatted(.relative(presentation: .named))
    }
}
