// A navigation door has two speeds: a click visits the nearest page, while a
// hold opens this tab's recent WebKit destinations. WebKit owns the list and
// the jump; reading at most ten entries when the menu opens keeps no second
// history in memory or in sync with a sleeping tab.
import AppKit
import SwiftUI

struct HistoryDoor: View {
    @ObservedObject var tab: Tab
    @ObservedObject var prefs: Preferences
    let back: Bool
    let open: (URL) -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    private var available: Bool { !tab.isBlank && (back ? tab.canGoBack : tab.canGoForward) }

    var body: some View {
        Menu {
            ForEach(tab.recent(back: back), id: \.self) { item in
                Button {
                    tab.go(to: item)
                } label: {
                    let label = HistoryLabel(title: item.title, url: item.url)
                    Text(label.title)
                    Text(label.place)
                }
            }
        } label: {
            Image(systemName: back ? "chevron.left" : "chevron.right")
                .font(.system(size: metrics.length(Metrics.navigationSymbol), weight: .regular))
                .foregroundStyle(Palette.muted)
                .frame(width: metrics.length(26), height: metrics.length(26))
                .contentShape(RoundedRectangle(cornerRadius: metrics.length(8), style: .continuous))
        } primaryAction: {
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                if let destination = tab.recent(back: back).first { open(destination.url) }
            } else if back {
                tab.back()
            } else {
                tab.forward()
            }
        }
        // SwiftUI's native Menu can retain its destination actions. A position
        // change must replace that menu, even when both availability flags stay
        // true or two history entries have the same URL. Row indices are not
        // destination identities either: keep WebKit's objects as their keys.
        .id(tab.built?.backForwardList.currentItem)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: metrics.length(26), height: metrics.length(26))
        .disabled(!available)
        .opacity(available ? 1 : 0.3)
        .help(prefs.keyHelp(back ? .back : .forward) + " — ⌘-click opens in a tab; hold for history")
    }
}

// Labels are presentation only. The menu action retains the WebKit item, whose
// URL includes its query and fragment. No metadata is fetched from old pages.
struct HistoryLabel {
    let title: String
    let place: String

    init(title: String?, url: URL) {
        let place: String
        if let host = url.host, !host.isEmpty {
            let port = url.port.map { ":\($0)" } ?? ""
            place = host + port + (url.path.isEmpty || url.path == "/" ? "" : url.path)
        } else if url.isFileURL {
            place = url.lastPathComponent.isEmpty ? "Local file" : url.lastPathComponent
        } else {
            place = url.scheme == "data" ? "Data document" : (url.scheme ?? "Page") + ":" + url.path
        }
        // A path has no length limit; a menu row does.
        self.place = String(place.prefix(80))
        let name = (title ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        // WebKit can use the raw URL as a missing page title.
        let fallback = name.isEmpty || name == url.absoluteString
        self.title = String((fallback ? place : name).prefix(80))
    }
}
