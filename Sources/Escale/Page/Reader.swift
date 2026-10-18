import SwiftUI

// Reading mode: the article, and nothing that was arranged around it.
//
// The hard part is deciding what the article is. The heuristic here is the old
// one and it holds up: the piece of the page carrying the most prose, punished
// for every link inside it — because navigation, related-articles rails and
// comment threads are all made of links, and prose is not.
//
// The article wears Escale's colours, not the site's: Palette's roles resolved
// in light or dark and handed to the page as CSS variables (its "dress"), with
// the column's width and the text's scale. A bar over the page, Escale's own
// glass, changes them; it lives only while reading mode is on screen, and
// dresses the page again when it appears and whenever a choice or the window's
// look changes. Nothing runs for a page that isn't being read.

enum Reader {
    static let script = Bundled.script("reader.js")

    /// Text sizes the bar steps through, in CSS pixels. 18 is the size
    /// reading mode always had.
    static let sizes = [14, 16, 18, 20, 22, 25, 28]
    static let size = 18

    /// A stored size, or 18 when nothing or something unknown is stored.
    static func size(_ stored: Int?) -> Int {
        guard let stored, sizes.contains(stored) else { return size }
        return stored
    }

    /// The next size up or down, held at either end.
    static func step(_ size: Int, by offset: Int) -> Int {
        let index = sizes.firstIndex(of: Self.size(size)) ?? 0
        return sizes[min(sizes.count - 1, max(0, index + offset))]
    }

    /// The page's CSS variables: Palette's roles in light or dark, the
    /// column's width in ems of the text, and the text's scale from 18 px.
    /// `.system` follows the window (`dark`).
    static func dress(look: Look, dark: Bool, width: ReaderWidth, size: Int) -> [String: String] {
        let night = look == .dark || (look == .system && dark)
        var dress = ["width": "\(width.ems)em", "scale": "\(Double(Self.size(size)) / Double(Self.size))"]
        NSAppearance(named: night ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            let roles: [String: NSColor] = [
                "ground": Palette.NS.ground, "ink": Palette.NS.ink, "quote": Palette.NS.readerQuote,
                "caption": Palette.NS.readerCaption, "code": Palette.NS.readerCode, "rule": Palette.NS.readerRule,
            ]
            for (name, role) in roles { dress[name] = Palette.Film.css(role) }
        }
        return dress
    }

    /// The article built from the page (`build`), or only dressed again.
    static func run(_ dress: [String: String], build: Bool) -> String {
        Bundled.configured(script, with: ["dress": dress, "build": build])
    }
}

/// How wide the column is, in ems of its text: normal is the width reading
/// mode always had.
enum ReaderWidth: String, CaseIterable, Identifiable {
    case narrow, normal, wide

    var id: String { rawValue }

    var ems: Int {
        switch self {
        case .narrow: return 32
        case .normal: return 38
        case .wide: return 46
        }
    }

    var title: String {
        switch self {
        case .narrow: return "Narrow"
        case .normal: return "Normal"
        case .wide: return "Wide"
        }
    }
}

/// The bar at the foot of a page in reading mode: its look, its column and
/// its text size. The choices are Preferences', so every page read after
/// wears them too.
struct ReaderBar: View {
    let tab: Tab
    @ObservedObject var prefs: Preferences
    @SwiftUI.Environment(\.colorScheme) private var scheme
    @SwiftUI.Environment(\.colorSchemeContrast) private var contrast
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    private var dress: [String: String] {
        Reader.dress(look: prefs.readerLook, dark: scheme == .dark, width: prefs.readerWidth, size: prefs.readerSize)
    }

    var body: some View {
        // A narrow split panel keeps only the size, rather than spill the
        // bar over its neighbours.
        ViewThatFits(in: .horizontal) {
            bar(full: true)
            bar(full: false)
        }
        .padding(.bottom, metrics.length(14))
        .onAppear { tab.dressReader(dress) }
        .onChange(of: dress) { _, dress in tab.dressReader(dress) }
        // The Mac's Increase Contrast changes no input above, only how the
        // roles resolve.
        .onChange(of: contrast) { _, _ in tab.dressReader(dress) }
    }

    private func bar(full: Bool) -> some View {
        HStack(spacing: metrics.length(8)) {
            if full {
                Segmented(options: Look.allCases.map { ($0, $0.title) }, selection: $prefs.readerLook)
                Segmented(options: ReaderWidth.allCases.map { ($0, $0.title) }, selection: $prefs.readerWidth)
            }
            HStack(spacing: 0) {
                step("textformat.size.smaller", "Smaller text", by: -1)
                step("textformat.size.larger", "Larger text", by: 1)
            }
        }
        .padding(metrics.length(5))
        .glass(.chip, in: Capsule())
    }

    private func step(_ symbol: String, _ label: String, by offset: Int) -> some View {
        let next = Reader.step(prefs.readerSize, by: offset)
        return Button { prefs.readerSize = next } label: {
            Image(systemName: symbol)
                .font(.system(size: metrics.length(12), weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: metrics.length(28), height: metrics.length(24))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(next == prefs.readerSize)
        .opacity(next == prefs.readerSize ? 0.4 : 1)
        .accessibilityLabel(label)
    }
}
