// Browser commands use one dispatch path from both menu and keyboard. The local
// monitor remains in App because WebKit can keep the first responder. Native
// editing gestures pass through; only the current search walk keeps modifier state.
import AppKit
import SwiftUI

@MainActor enum KeyRouting {
    static var searchModifiers: NSEvent.ModifierFlags?

    static func released(_ event: NSEvent, browser: Browser) {
        guard let held = searchModifiers,
              !event.modifierFlags.intersection(KeyStroke.mask).isSuperset(of: held) else { return }
        searchModifiers = nil
        browser.landSummon()
    }

    static func take(_ event: NSEvent, browser: Browser) -> Bool {
        guard !event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let stroke = KeyStroke(event) else { return false }
        let typing = browser.active?.typing == true || browser.active?.built?.inputContext != nil
            || browser.editing || event.window?.firstResponder is NSTextView
        // Contextual editing is not a browser binding, even if Paste and Go
        // is moved elsewhere. Keep plain paste and the text edge gestures intact.
        if typing, stroke == KeyStroke("v", [.command, .shift]) {
            _ = event.window?.firstResponder?.tryToPerform(#selector(NSTextView.pasteAsPlainText(_:)), with: nil)
            return true
        }
        if browser.veiling, stroke == KeyStroke("z", .command) { browser.undoHiding(); return true }
        if typing, stroke.flags == .command, ["left", "right"].contains(stroke.key) { return false }
        guard let action = browser.prefs.keyBindings.action(for: stroke) else {
            if #available(macOS 15.4, *), !stroke.flags.intersection([.command, .control, .option]).isEmpty {
                if Extensions.shared.take(event) { return true }
            }
            // WebKit/AppKit can still route the standard window-close key
            // after its menu item is replaced. A removed browser binding must
            // not fall through and close the entire window instead.
            if stroke.key == "w", stroke.flags == .command || stroke.flags == [.command, .shift] { return true }
            return false
        }
        // Browser bindings win consistently over extension commands. The recorder
        // names any loaded extension using the proposed key before saving it.
        if browser.keyAvailable(action) { browser.performKeyAction(action, event: event) }
        return true
    }
}

extension Browser {
    func keyAvailable(_ action: KeyAction) -> Bool {
        if action.rawValue.hasPrefix("space"), let index = action.index { return prefs.usesSpaces && spaces.indices.contains(index - 1) }
        if action.rawValue.hasPrefix("tab"), let index = action.index { return tabEntries.indices.contains(index - 1) }
        switch action {
        case .previousSpace, .nextSpace: return prefs.usesSpaces && spaces.count > 1
        case .newSpace, .renameSpace, .duplicateSpace: return prefs.usesSpaces
        case .moveSpaceUp, .moveSpaceDown:
            let at = spaces.firstIndex { $0.id == spaceID } ?? 0
            return prefs.usesSpaces && spaces.indices.contains(at + (action == .moveSpaceUp ? -1 : 1))
        case .deleteSpace: return prefs.usesSpaces && !space.isFirst
        case .reopenTab: return !ghosts.isEmpty
        case .back: return active?.canGoBack == true
        case .forward: return active?.canGoForward == true
        case .stopLoading: return active?.loading == true
        case .findNext, .findPrevious: return finding
        case .pinTab, .duplicateTab, .copyAddress, .copyMarkdown, .addBookmark, .print, .find: return active?.isBlank == false
        case .renameTab: return active != nil
        case .changeLetter: return active?.pin != nil
        case .closeOthers: return tabs.count > 1
        case .clearTabs: return !clearableTabs().isEmpty
        case .resetSite: return ["http", "https"].contains(active?.address?.scheme?.lowercased() ?? "")
        default: return true
        }
    }

    func performKeyAction(_ action: KeyAction, event: NSEvent? = nil) {
        guard keyAvailable(action) else { return }
        if action.rawValue.hasPrefix("space"), let index = action.index { makingSpace = false; switchSpace(index: index - 1); return }
        if action.rawValue.hasPrefix("tab"), let index = action.index { select(index: index - 1); return }
        switch action {
        case .closeWindow: NSApp.keyWindow?.performClose(nil)
        case .newTab: newTab()
        case .privateTab: newShyTab()
        case .reopenTab: reopen()
        case .closeTab: closeTabCommand()
        case .searchGitHub: beginGitHub()
        case .searchTabs:
            if let event {
                KeyRouting.searchModifiers = event.modifierFlags.intersection([.command, .control, .option])
                if editing, field.github == nil, !field.offers.isEmpty { field.stepSummon() } else { summon() }
            } else { summon() }
        case .nextTab: step(1)
        case .previousTab: step(-1)
        case .lastTab: select(index: tabEntries.count - 1)
        case .duplicateTab: duplicate()
        case .renameTab: if let tab = active { beginTabRename(tab) }
        case .pinTab: if let tab = active { if tab.pin == nil { pin(tab) } else { unpin(tab) } }
        case .changeLetter: if let tab = active { editLetter(tab) }
        case .closeOthers: if let tab = active { closeOthers(but: tab) }
        case .clearTabs: clearTabs()
        case .splitRight: chooseSplit(.right)
        case .splitLeft: chooseSplit(.left)
        case .splitTop: chooseSplit(.top)
        case .splitBottom: chooseSplit(.bottom)
        case .openAddress: edit()
        case .back: back()
        case .forward: forward()
        case .reload: reload()
        case .stopLoading: active?.stop()
        case .copyAddress: copyAddress()
        case .copyMarkdown: copyMarkdownLink()
        case .pasteGo: pasteAndGo()
        case .history: recalling.toggle()
        case .clearHistory:
            Ask.sure("Clear this Space’s history?", detail: "Visited pages and learned search choices will be removed.", confirm: "Clear History") { self.clearHistory() }
        case .addBookmark: bookmarkCurrent()
        case .bookmarks: bookmarking.toggle()
        case .previousSpace, .nextSpace:
            guard let index = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
            makingSpace = false
            switchSpace(index: (index + (action == .nextSpace ? 1 : -1) + spaces.count) % spaces.count)
        case .newSpace: askForSpace()
        case .renameSpace: askToRenameSpace(spaceID)
        case .duplicateSpace: askToDuplicateSpace(spaceID)
        case .moveSpaceUp: moveSpace(spaceID, by: -1)
        case .moveSpaceDown: moveSpace(spaceID, by: 1)
        case .deleteSpace: askToDeleteSpace(spaceID)
        case .find: openFind()
        case .findNext: find.look(forward: true)
        case .findPrevious: find.look(forward: false)
        case .zoomIn: zoom(by: 1.1)
        case .zoomOut: zoom(by: 1 / 1.1)
        case .resetZoom: resetZoom()
        case .print: printPage()
        case .reader: toggleReader()
        case .floatVideo: toggleFloat()
        case .stopSound: pauseMedia()
        case .hideElements: toggleHiding()
        case .hiddenElements: reviewing.toggle()
        case .resetSite: resetSite()
        case .siteData: showSiteData()
        case .inspector: toggleInspector()
        case .console: showConsole()
        case .inspectElement: inspectElement()
        case .visual: pickVisual()
        case .capture: capturePage(.visible)
        case .captureArea: pickArea()
        case .captureFull: capturePage(.full)
        case .developer: toggleCalls()
        case .localhost: localhostOpen.toggle()
        case .settings: tuning.toggle()
        case .fold: toggleFold()
        case .focus: toggleFocus()
        case .sidebar: toggleSidebar()
        case .downloads: hoarding.toggle()
        case .passwords: managing.toggle()
        case .welcome: welcoming = true
        case .feedback: Links.writeFeedback()
        default: break // Numbered destinations were handled above.
        }
    }
}
