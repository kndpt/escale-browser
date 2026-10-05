// How one destination of the environment sheet is recognised while browsing.
// People paste full addresses and never write patterns: the saved address is
// shown as its host and whole path segments, and choosing a segment reads as
// "this much identifies it, the rest is free". Domain stays the default, so a
// rule is only claimed when someone picks Domain + Path. The strip is an
// editing focus stop, reached by Tab like the text fields around it, and the
// arrow keys move the boundary. It keeps nothing beyond the draft value.
import SwiftUI

struct EnvironmentScope: View {
    @Binding var item: BookmarkEnvironment
    let url: URL
    /// The draft as Save would write it, suggested names included.
    let entries: [BookmarkEnvironment]
    let problem: String?
    @FocusState private var focused: Bool
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    private var gap: CGFloat { metrics.length(Metrics.environmentGap) }
    private var parts: [String] { BookmarkEnvironment.segments(url) }
    private var level: Int { min(item.depth ?? 0, parts.count) }
    /// The host as people read it, with a port only when it is not the default.
    private var place: String {
        guard let endpoint = BookmarkEnvironment.endpoint(url) else { return url.absoluteString }
        let usual = url.scheme?.lowercased() == "http" ? 80 : 443
        return endpoint.port == usual ? endpoint.host : "\(endpoint.host):\(endpoint.port)"
    }
    private var title: String { label(entries.first { $0.id == item.id } ?? item) ?? "This environment" }
    /// Other destinations on this host and port, the only ones that can compete.
    private var neighbours: [BookmarkEnvironment] {
        let own = BookmarkEnvironment.endpoint(url)
        return entries.filter { other in
            other.id != item.id && BookmarkEnvironment.address(other.url).flatMap(BookmarkEnvironment.endpoint) == own
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: gap / 2) {
            HStack(spacing: gap) {
                Picker("Recognise", selection: Binding(get: { item.depth != nil }, set: switchTo)) {
                    Text("Domain").tag(false)
                    Text("Domain + Path").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .disabled(parts.isEmpty && item.depth == nil)
                .help(parts.isEmpty ? "This address has no path to recognise." : "Choose what identifies this environment")
                if focused {
                    // The arrows act here; said where they act, like Tab in search.
                    Text("← →").foregroundStyle(Palette.muted).accessibilityHidden(true)
                }
            }
            if !parts.isEmpty { strip }
            if let problem {
                Text(problem).foregroundStyle(Palette.danger).fixedSize(horizontal: false, vertical: true)
            } else {
                let (text, warning) = preview
                Text(text).foregroundStyle(warning ? Palette.unsafe : Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var strip: some View {
        ScrollViewReader { scroll in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    HStack(spacing: 0) {
                        segment(place, at: 0)
                        ForEach(0..<level, id: \.self) { index in segment("/" + parts[index], at: index + 1) }
                    }
                    .padding(.horizontal, metrics.length(Metrics.environmentGap / 4))
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: metrics.length(Metrics.environmentGap / 2)))
                    ForEach(level..<parts.count, id: \.self) { index in segment("/" + parts[index], at: index + 1) }
                }
            }
            .onChange(of: level) { _, level in scroll.scrollTo(level, anchor: .center) }
        }
        .focusable(interactions: .edit)
        .focused($focused)
        .onKeyPress(.leftArrow) { choose(level - 1); return .handled }
        .onKeyPress(.rightArrow) { choose(level + 1); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recognised part of the address")
        .accessibilityValue(item.depth == nil ? "Domain, \(place)" : "Domain and path, \(claimed)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: choose(level + 1)
            case .decrement: choose(level - 1)
            @unknown default: break
            }
        }
    }

    private func segment(_ text: String, at index: Int) -> some View {
        Button { choose(index) } label: {
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: metrics.length(Metrics.environmentSegmentWidth))
                .fixedSize()
                .foregroundStyle(index <= level ? Palette.ink : Palette.muted)
                // Unpadded segments read as one address; only the claimed run is framed.
                .padding(.vertical, metrics.length(Metrics.environmentGap / 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(index == 0 ? "Recognise every page of \(place)" : "Recognise pages under \(prefix(index))")
        .id(index)
    }

    /// The claimed address as people read it, with its trailing slash: its pages follow.
    private var claimed: String { prefix(level) }
    private func prefix(_ depth: Int) -> String {
        place + "/" + parts.prefix(depth).map { $0 + "/" }.joined()
    }

    private var preview: (String, Bool) {
        if item.depth != nil {
            guard item.claim != nil else { return ("Choose the part of the path that identifies \(title).", false) }
            let inside = neighbours.filter { other in
                guard let theirs = other.claim, let mine = item.claim else { return false }
                return theirs.count > mine.count && theirs.starts(with: mine)
            }
            return ("\(title) recognised on \(claimed) and its pages" + except(inside) + ".", false)
        }
        let shared = neighbours.filter { $0.depth == nil }
        if !shared.isEmpty {
            return ("Shares \(place) with \(names(shared)): recognised only at this exact address. "
                    + "Choose Domain + Path to recognise its pages.", true)
        }
        return ("\(title) recognised on every page of \(place)" + except(neighbours.filter { $0.claim != nil }) + ".", false)
    }

    private func except(_ others: [BookmarkEnvironment]) -> String {
        others.isEmpty ? "" : ", except those of \(names(others))"
    }
    private func names(_ others: [BookmarkEnvironment]) -> String {
        // The app speaks English; a system list formatter would follow the Mac's language.
        let all = others.map { label($0) ?? "an unnamed environment" }
        guard let last = all.last, all.count > 1 else { return all.first ?? "" }
        return all.dropLast().joined(separator: ", ") + " and " + last
    }
    private func label(_ entry: BookmarkEnvironment) -> String? {
        let name = BookmarkEnvironment.normalName(entry.name)
        return name.isEmpty ? nil : name
    }

    private func switchTo(_ path: Bool) {
        item.depth = path ? BookmarkEnvironment.proposedDepth(for: item, among: entries) : nil
    }
    private func choose(_ depth: Int) {
        let depth = max(0, min(depth, parts.count))
        item.depth = depth == 0 ? nil : depth
    }
}
