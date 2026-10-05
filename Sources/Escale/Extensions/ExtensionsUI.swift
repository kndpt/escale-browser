import SwiftUI
import WebKit

/// Settings › Extensions: what is installed, and the two ways in — a Chrome
/// Web Store link, or a folder.
struct ExtensionsPage: View {
    @ObservedObject var browser: Browser

    var body: some View {
        if #available(macOS 15.4, *) {
            Installer(browser: browser, extensions: .shared)
        } else {
            Card {
                Line("Chrome extensions", "Need macOS 15.4 or later — the version whose WebKit can run them.") { EmptyView() }
            }
        }
    }

    @available(macOS 15.4, *)
    private struct Installer: View {
        @ObservedObject var browser: Browser
        @ObservedObject var extensions: Extensions
        @State private var link = ""
        @SwiftUI.Environment(\.chromeMetrics) private var metrics
        @SwiftUI.Environment(\.cardDensity) private var density

        var body: some View {
            VStack(alignment: .leading, spacing: metrics.length(Metrics.settingsGap)) {
                Card {
                    VStack(alignment: .leading, spacing: metrics.length(8)) {
                        HStack(spacing: metrics.length(8)) {
                            Text("Add from the Chrome Web Store")
                                .font(.system(size: metrics.length(density.title)))
                                .foregroundStyle(Palette.ink)
                            Spacer(minLength: 8)
                            Pill("Open the Store") {
                                browser.tuning = false
                                browser.open(Browser.webStore, foreground: true)
                            }
                        }
                        HStack(spacing: metrics.length(8)) {
                            ZStack(alignment: .leading) {
                                if link.isEmpty {
                                    Text("Paste a link to an extension, or its id")
                                        .foregroundStyle(Palette.muted.opacity(0.8))
                                }
                                TextField("", text: $link)
                                    .textFieldStyle(.plain)
                                    .foregroundStyle(Palette.ink)
                                    .onSubmit(add)
                            }
                            .font(.system(size: metrics.length(density.detail + 1)))
                            .padding(.horizontal, metrics.length(8))
                            .padding(.vertical, metrics.length(5))
                            .background(Palette.wash, in: RoundedRectangle(cornerRadius: metrics.length(7), style: .continuous))
                            if extensions.busy != nil {
                                Ring(size: 12)
                            } else {
                                Pill("Add", filled: true, action: add)
                                    .disabled(Crx.id(in: link) == nil)
                            }
                        }
                        Text("Or find it in the store and press Add to Escale on its page.")
                            .font(.system(size: metrics.length(density.detail)))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(metrics.length(density.inset))
                }

                Card {
                    Line("Allow on private tabs", "Off by default - a private tab keeps nothing, extensions included") {
                        Switch(on: Binding(
                            get: { browser.prefs.extensionsInPrivate },
                            set: { browser.prefs.extensionsInPrivate = $0 }
                        ))
                    }
                }

                if extensions.installed.isEmpty {
                    Card { Nothing("No extensions yet.") }
                } else {
                    Card {
                        ForEach(Array(extensions.installed.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Rule() }
                            Row(item: item, extensions: extensions)
                        }
                    }
                }

                if let planned = browser.space.plannedExtensions, !planned.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: metrics.length(8)) {
                            Text("Extensions to reinstall")
                                .font(.system(size: metrics.length(density.title), weight: .medium))
                                .foregroundStyle(Palette.ink)
                            Text("The copy has no extension data, accounts or permissions. Each installation asks again.")
                                .font(.system(size: metrics.length(density.detail)))
                                .foregroundStyle(Palette.muted)
                            ForEach(Array(planned.enumerated()), id: \.offset) { _, item in
                                HStack {
                                    Text(item.name).font(.system(size: metrics.length(density.detail + 1)))
                                    Spacer()
                                    if let id = item.storeID {
                                        Pill("Install") { extensions.install(from: id) }
                                    } else {
                                        Pill("Choose folder…") { extensions.installFolder() }
                                    }
                                }
                            }
                        }
                        .padding(metrics.length(density.inset))
                    }
                }

                Card {
                    Line("Load an unpacked extension", "A folder with a manifest.json — your own, or one exported from another browser. Reload picks up what you've changed in it since.") {
                        Pill("Choose…") { extensions.installFolder() }
                    }
                }
            }
        }

        private func add() {
            guard Crx.id(in: link) != nil else { return }
            extensions.install(from: link)
            link = ""
        }
    }

    @available(macOS 15.4, *)
    private struct Row: View {
        let item: Installed
        @ObservedObject var extensions: Extensions
        @State private var hovering = false
        @SwiftUI.Environment(\.chromeMetrics) private var metrics
        @SwiftUI.Environment(\.cardDensity) private var density

        var body: some View {
            let context = extensions.contexts[item.id]
            HStack(spacing: metrics.length(10)) {
                Group {
                    if let icon = context?.webExtension.icon(for: CGSize(width: 32, height: 32)) {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "puzzlepiece.extension").foregroundStyle(Palette.muted)
                    }
                }
                .frame(width: metrics.length(18), height: metrics.length(18))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: metrics.length(density.title)))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(detail(context))
                        .font(.system(size: metrics.length(density.detail)))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .help(item.source ?? "")
                }
                Spacer(minLength: 8)
                if hovering {
                    Quick(item.pinned == true ? "Unpin" : "Pin to Toolbar") {
                        extensions.setPinned(item.id, !(item.pinned ?? false))
                    }
                    if context?.overrideNewTabPageURL != nil {
                        let on = Store.settings.object(forKey: extensions.settingKey("newtab", item.id)) as? Bool == true
                        Quick(on ? "Stop in New Tabs" : "Show in New Tabs") {
                            Store.settings.set(!on, forKey: extensions.settingKey("newtab", item.id))
                            extensions.objectWillChange.send()
                        }
                    }
                    if item.source != nil || !item.fromStore {
                        Quick("Reload") { extensions.reload(item.id) }
                    }
                    if context?.optionsPageURL != nil {
                        Quick("Options") { extensions.openOptions(item.id) }
                    }
                    Quick("Remove", tint: Palette.danger) { extensions.remove(item.id) }
                }
                Switch(on: Binding(get: { item.enabled }, set: { extensions.setEnabled(item.id, $0) }))
            }
            .padding(.horizontal, metrics.length(density.inset))
            .padding(.vertical, metrics.length(density.pad))
            .background(hovering ? Palette.hover : .clear)
            .onHover { hovering = $0 }
        }

        /// Where it was loaded from, by the folder's name — the whole path
        /// is in the tooltip.
        private var folder: String {
            item.source.map { "From “\(URL(fileURLWithPath: $0).lastPathComponent)”" } ?? "From a folder"
        }

        private func detail(_ context: WKWebExtensionContext?) -> String {
            var parts = ["Version \(item.version)", item.fromStore ? "Chrome Web Store" : folder]
            if item.enabled, context == nil { parts.append("couldn't start") }
            if context?.overrideNewTabPageURL != nil, Store.settings.object(forKey: extensions.settingKey("newtab", item.id)) as? Bool == true {
                parts.append("shows in new tabs")
            }
            if let errors = context?.errors, !errors.isEmpty { parts.append("\(errors.count) warning\(errors.count == 1 ? "" : "s")") }
            return parts.joined(separator: " · ")
        }
    }
}

/// On an extension's page in the Chrome Web Store, the offer to add it —
/// where the store's own button only says "Switch to Chrome".
struct StoreOffer: View {
    @ObservedObject var browser: Browser

    var body: some View {
        if #available(macOS 15.4, *), let tab = browser.active {
            Watch(tab: tab, extensions: .shared)
        }
    }

    @available(macOS 15.4, *)
    private struct Watch: View {
        @ObservedObject var tab: Tab
        @ObservedObject var extensions: Extensions

        var body: some View {
            // Only where the page's own "Add to Escale" isn't in place — a
            // store that has changed its markup still gets a way in.
            if let url = tab.address, StoreOffer.isStorePage(url), let id = Crx.id(in: url.absoluteString),
               tab.storePlaced != id, !extensions.installed.contains(where: { $0.id == id }) {
                HStack(spacing: 12) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Palette.muted)
                    Text(extensions.busy == id ? "Adding…" : "Add this extension to Escale")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                    if extensions.busy == id {
                        Ring(size: 10)
                    } else {
                        Button("Add") { extensions.install(from: id) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.inverse)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(Palette.ink, in: Capsule())
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 10)
                .padding(.vertical, 9)
                .glass(.chip, in: Capsule())
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    static func isStorePage(_ url: URL) -> Bool {
        let host = url.host()?.lowercased() ?? ""
        return host == "chromewebstore.google.com"
            || (host == "chrome.google.com" && url.path.hasPrefix("/webstore"))
    }
}
