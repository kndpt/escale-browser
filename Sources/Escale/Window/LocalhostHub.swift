import SwiftUI

// A quiet return door for local pages already visited in this space. It opens
// only on request among the tools (Tools, at the rail's foot); the same entries appear in the
// menu bar for a top-tab window. "Visited" is deliberate: a past visit does
// not prove that the development server is still running. Opening the panel
// reads the listening ports once, and an entry nothing listens for, or one
// from before the Mac last started, is dimmed and says so. It stays in the
// list and clickable: a server may be started again. The panel changes what
// it says, not what it keeps (Localhost.Availability).

struct LocalhostHub: View {
    @ObservedObject var browser: Browser
    @ObservedObject var localhost: Localhost

    var body: some View {
        let entries = localhost.entries(in: browser.spaceID)
        VStack(alignment: .leading, spacing: 0) {
            Text("Localhost")
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 7)
            if entries.isEmpty {
                Text("Local pages you visit will appear here.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(entries) { entry in
                            let state = localhost.availability(of: entry)
                            Button { browser.openLocalhost(entry) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "network")
                                        .foregroundStyle(Palette.muted)
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.title.isEmpty ? entry.origin : entry.title)
                                            .font(.system(size: 12.5))
                                            .foregroundStyle(state.counts ? Palette.ink : Palette.muted)
                                            .lineLimit(1)
                                        Text(entry.origin + " · " + state.said(visited: entry.visited))
                                            .font(.system(size: 11))
                                            .foregroundStyle(Palette.muted)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8)
                                .frame(height: 42)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Remove from Localhost") {
                                    localhost.forget(entry.origin, in: browser.spaceID)
                                }
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 340)
            }
        }
        .frame(width: 290)
        // The popover's own material shows through (Glass.swift).
        .popoverGround()
        .onAppear { localhost.check() }
    }
}

/// The same recent endpoints in the menu bar when the tabs are across the top.
struct LocalhostChoices: View {
    @ObservedObject var browser: Browser
    @ObservedObject var localhost: Localhost

    var body: some View {
        let entries = localhost.entries(in: browser.spaceID)
        if entries.isEmpty {
            Button("No local pages yet") {}
                .disabled(true)
        } else {
            ForEach(entries) { entry in
                let state = localhost.availability(of: entry)
                Button(entry.origin + (entry.title.isEmpty ? "" : " — " + entry.title) + state.suffix) {
                    browser.openLocalhost(entry)
                }
            }
        }
    }
}

extension Localhost.Availability {
    /// The line under an entry: the visit, told with what is known about its server.
    func said(visited: Date) -> String {
        switch self {
        case .running, .unconfirmed: return When.said(visited)
        case .stopped: return "Not listening · " + When.said(visited)
        case .restarted: return "Before this Mac restarted · " + When.said(visited)
        }
    }

    /// The same, shortened for a menu row.
    var suffix: String {
        switch self {
        case .running, .unconfirmed: return ""
        case .stopped: return " (not listening)"
        case .restarted: return " (before restart)"
        }
    }
}

extension Browser {
    /// Back to a page that already shows this endpoint; else to the tab of the
    /// bookmark that owns it, on the destination that is local; else a new tab.
    func openLocalhost(_ entry: Localhost.Entry) {
        guard let url = entry.address else { return }
        let showing = tabs.filter { Localhost.reuses(shy: $0.shy, address: $0.address, origin: entry.origin) }
        if let tab = showing.first(where: { $0.id == activeID }) ?? showing.first {
            select(tab)
        } else if let (tab, destination) = bookmarkedTab(for: entry) {
            if let environment = destination.environment {
                openEnvironment(environment, bookmark: destination.bookmark, space: spaceID, shy: false)
            } else {
                tab.go(to: destination.url)
                select(tab)
            }
        } else {
            open(url, foreground: true)
        }
        localhostOpen = false
    }

    /// The open tab of the bookmark that owns the endpoint, in an ordinary
    /// context. With several bookmarks on one origin the active tab's wins,
    /// then the only one that is open; otherwise none, so no tab is hijacked.
    private func bookmarkedTab(for entry: Localhost.Entry) -> (Tab, Localhost.Destination)? {
        let open = Localhost.destinations(for: entry, in: bookmarks.roots).compactMap { destination in
            tabs.first { shelfTabs[$0.id] == destination.bookmark && $0.pin == nil && !$0.shy }
                .map { ($0, destination) }
        }
        if let active = open.first(where: { $0.0.id == activeID }) { return active }
        return open.count == 1 ? open.first : nil
    }
}
