// The official monochrome GitHub mark is a bundled vector, never a favicon.
// It is decoded once on first use; missing packaging leaves the word GitHub
// readable instead of requesting the network or crashing the browser.
import SwiftUI
import AppKit

struct GitHubMark: View {
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    private static let image: NSImage? = {
        guard let file = Bundled.file("github-invertocat.pdf"), let image = NSImage(contentsOf: file) else { return nil }
        image.isTemplate = true
        return image
    }()

    /// The mark alone, as a template image, for a place that draws its own label.
    static var glyph: Image? { image.map { Image(nsImage: $0) } }

    var body: some View {
        HStack(spacing: metrics.length(Metrics.searchGap)) {
            if let image = Self.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: metrics.length(Metrics.githubSymbol), height: metrics.length(Metrics.githubSymbol))
                    .accessibilityHidden(true)
            }
            Text("GitHub")
        }
        .foregroundStyle(Palette.ink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("GitHub")
    }
}
