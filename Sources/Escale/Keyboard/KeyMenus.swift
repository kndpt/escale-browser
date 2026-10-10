// The menus observe bindings directly so saving a shortcut updates its visible
// equivalent immediately. Every browser item calls the same action as key routing;
// native app and editing menus retain their responder-chain behavior.
import SwiftUI

struct KeyMenus: Commands {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            items([.newTab, .privateTab, .reopenTab])
            Divider()
            items([.openAddress, .closeTab])
        }
        // Remove the stock ⌘W too: otherwise unassigning Close Tab would
        // unexpectedly close the window through the native fallback.
        Group {
            CommandGroup(replacing: .saveItem) { items([.closeWindow]) }
            CommandGroup(replacing: .printItem) { items([.print]) }
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            items([.find, .findNext, .findPrevious])
        }
        CommandGroup(replacing: .toolbar) {
            Toggle("Show Tabs in Sidebar", isOn: Binding(get: { prefs.sidebar }, set: { _ in Motion.command { browser.toggleSidebar() } }))
                .keyboardShortcut(prefs.keyBindings.keys(.sidebar).first?.shortcut)
            KeyMenuItem(action: .fold, browser: browser, prefs: prefs, title: browser.folded ? "Show Tab Bar" : "Hide Tab Bar")
            KeyMenuItem(action: .focus, browser: browser, prefs: prefs, title: browser.focusing ? "Exit Focus Mode" : "Enter Focus Mode")
            Picker("Tabs Wear", selection: $prefs.glyph) {
                ForEach(Glyph.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            items([.reload, .stopLoading, .reader, .floatVideo])
            Divider()
            items([.hideElements, .hiddenElements, .resetSite])
            Divider()
            items([.zoomIn, .zoomOut, .resetZoom])
            Divider()
            items([.siteData, .inspector, .console, .inspectElement])
        }
        CommandMenu("Tabs") {
            items([.splitRight, .splitLeft, .splitTop, .splitBottom])
            Divider()
            items([.back, .forward])
            Divider()
            items([.nextTab, .previousTab, .searchTabs, .searchGitHub])
            Menu("Go to Tab") { items([.tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .lastTab]) }
            Divider()
            KeyMenuItem(action: .pinTab, browser: browser, prefs: prefs, title: browser.active?.pin == nil ? "Pin Tab" : "Unpin Tab")
            if browser.active?.pin != nil { items([.changeLetter]) }
            items([.renameTab, .duplicateTab, .copyAddress, .copyMarkdown, .pasteGo])
            Divider()
            items([.closeOthers, .clearTabs, .stopSound])
        }
        CommandMenu("Spaces") {
            items([.previousSpace, .nextSpace])
            Divider()
            ForEach(Array(browser.spaces.enumerated()), id: \.element.id) { index, space in
                if let action = KeyAction(rawValue: "space\(index + 1)") {
                    KeyMenuItem(action: action, browser: browser, prefs: prefs, title: space.name)
                } else {
                    Button(space.name) { Motion.command { browser.switchSpace(to: space.id) } }.disabled(!prefs.usesSpaces)
                }
            }
            Divider()
            items([.newSpace, .renameSpace, .duplicateSpace, .moveSpaceUp, .moveSpaceDown])
            Divider()
            items([.deleteSpace])
        }
        CommandMenu("Bookmarks") { items([.addBookmark, .bookmarks]) }
        CommandMenu("Page Tools") { items([.visual, .capture, .captureArea, .captureFull, .developer]) }
        CommandMenu("Localhost") {
            items([.localhost])
            Divider()
            LocalhostChoices(browser: browser, localhost: browser.localhost)
        }
        Group {
            CommandMenu("History") {
                Section("Recently Visited") {
                    ForEach(browser.recentlyVisited) { trace in
                        Button { browser.open(trace.url, foreground: true) } label: {
                            MenuLine(title: trace.title.isEmpty ? trace.key : trace.title, url: trace.url)
                        }
                    }
                }
                if !browser.ghosts.isEmpty {
                    Section("Recently Closed") {
                        ForEach(browser.ghosts.reversed().prefix(10)) { ghost in
                            Button { browser.reopen(ghost) } label: { MenuLine(title: ghost.label, url: ghost.url) }
                        }
                    }
                }
                Divider()
                items([.history, .downloads])
                Divider()
                items([.clearHistory])
            }
            CommandGroup(after: .appSettings) { items([.settings, .welcome, .passwords]) }
            CommandGroup(replacing: .help) { items([.feedback]) }
        }
    }

    private func items(_ actions: [KeyAction]) -> some View {
        ForEach(actions, id: \.self) { KeyMenuItem(action: $0, browser: browser, prefs: prefs) }
    }
}

private struct KeyMenuItem: View {
    let action: KeyAction
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    var title: String? = nil
    var body: some View {
        Button(title ?? action.command.title) { Motion.command { browser.performKeyAction(action) } }
            .keyboardShortcut(prefs.keyBindings.keys(action).first?.shortcut)
            .disabled(!browser.keyAvailable(action))
    }
}
