// The finite catalogue of browser commands is shared by Settings, menus and key routing.
// Stable IDs keep saved overrides meaningful as the list grows; contextual editing
// and macOS commands are references, with their actual owner explained.
import SwiftUI

enum KeyAction: String, CaseIterable, Codable {
    case closeWindow, newTab, privateTab, reopenTab, closeTab, searchTabs, searchGitHub, nextTab, previousTab, duplicateTab, renameTab, pinTab, changeLetter, closeOthers, clearTabs, tab1, tab2, tab3, tab4, tab5, tab6, tab7, tab8, lastTab, splitRight, splitLeft, splitTop, splitBottom, openAddress, back, forward, reload, stopLoading, copyAddress, copyMarkdown, pasteGo, history, clearHistory, addBookmark, bookmarks, previousSpace, nextSpace, newSpace, renameSpace, duplicateSpace, moveSpaceUp, moveSpaceDown, deleteSpace, find, findNext, findPrevious, zoomIn, zoomOut, resetZoom, print, reader, floatVideo, stopSound, hideElements, hiddenElements, resetSite, siteData, inspector, console, inspectElement, visual, capture, captureArea, captureFull, developer, network, localhost, settings, fold, focus, sidebar, downloads, passwords, welcome, feedback, space1, space2, space3, space4, space5, space6, space7, space8, space9

    var command: KeyCommand { KeyCommand.catalog[self] ?? KeyCommand(self, rawValue, .app) }
    var index: Int? { Int(rawValue.dropFirst(rawValue.hasPrefix("space") ? 5 : 3)) }
}

enum KeyGroup: String, CaseIterable, Identifiable {
    case tabs = "Tabs", navigation = "Navigation", spaces = "Spaces", page = "Page", tools = "Developer Tools", app = "Application", reference = "Editing & macOS"
    var id: String { rawValue }
}

struct KeyCommand: Identifiable {
    let action: KeyAction
    let title: String
    let group: KeyGroup
    var detail: String = ""
    var defaults: [KeyStroke] = []
    var id: String { action.rawValue }

    init(_ action: KeyAction, _ title: String, _ group: KeyGroup, _ detail: String = "", _ defaults: [KeyStroke] = []) {
        self.action = action; self.title = title; self.group = group; self.detail = detail; self.defaults = defaults
    }
    static let all: [KeyCommand] = [
        .init(.newTab, "New Tab", .tabs, "Open Bearings to go somewhere new.", [.init("t", [.command])]),
        .init(.privateTab, "New Private Tab", .tabs, "Browse without keeping a history.", [.init("n", [.command, .shift])]),
        .init(.reopenTab, "Reopen Closed Tab", .tabs, "", [.init("t", [.command, .shift])]),
        .init(.closeTab, "Close Tab", .tabs, "", [.init("w", [.command])]),
        .init(.searchGitHub, "Search GitHub", .tabs, "Find a visited pull request or issue in this Space.", [.init("k", [.command, .shift])]),
        .init(.searchTabs, "Search Tabs", .tabs, "Find an open tab in this Space.", [.init("k", [.command])]),
        .init(.nextTab, "Next Tab", .tabs, "", [.init("]", [.command, .shift]), .init("tab", [.control])]),
        .init(.previousTab, "Previous Tab", .tabs, "", [.init("[", [.command, .shift]), .init("tab", [.control, .shift])]),
        .init(.duplicateTab, "Duplicate Tab", .tabs, "", [.init("d", [.command])]),
        .init(.renameTab, "Rename Tab", .tabs, "", []),
        .init(.pinTab, "Pin or Unpin Tab", .tabs, "", []),
        .init(.changeLetter, "Change Pinned Letter", .tabs, "", []),
        .init(.closeOthers, "Close Other Tabs", .tabs, "", []),
        .init(.clearTabs, "Clear Ordinary Tabs", .tabs, "Keep pins and bookmarks.", []),
        .init(.tab1, "Go to Tab 1", .tabs, "By its position in the current Space.", [.init("#1", [.command])]),
        .init(.tab2, "Go to Tab 2", .tabs, "By its position in the current Space.", [.init("#2", [.command])]),
        .init(.tab3, "Go to Tab 3", .tabs, "By its position in the current Space.", [.init("#3", [.command])]),
        .init(.tab4, "Go to Tab 4", .tabs, "By its position in the current Space.", [.init("#4", [.command])]),
        .init(.tab5, "Go to Tab 5", .tabs, "By its position in the current Space.", [.init("#5", [.command])]),
        .init(.tab6, "Go to Tab 6", .tabs, "By its position in the current Space.", [.init("#6", [.command])]),
        .init(.tab7, "Go to Tab 7", .tabs, "By its position in the current Space.", [.init("#7", [.command])]),
        .init(.tab8, "Go to Tab 8", .tabs, "By its position in the current Space.", [.init("#8", [.command])]),
        .init(.lastTab, "Go to Last Tab", .tabs, "The last tab, even when there are more than nine.", [.init("#9", [.command])]),
        .init(.splitRight, "Add Right Split", .tabs, "", [.init("e", [.command, .shift])]),
        .init(.splitLeft, "Add Left Split", .tabs, "", []),
        .init(.splitTop, "Add Top Split", .tabs, "", []),
        .init(.splitBottom, "Add Bottom Split", .tabs, "", []),
        .init(.openAddress, "Open Address", .navigation, "Change the address of this page.", [.init("l", [.command])]),
        .init(.back, "Back", .navigation, "The arrow alternative belongs to text fields while typing.", [.init("[", [.command]), .init("left", [.command])]),
        .init(.forward, "Forward", .navigation, "The arrow alternative belongs to text fields while typing.", [.init("]", [.command]), .init("right", [.command])]),
        .init(.reload, "Reload Page", .navigation, "", [.init("r", [.command])]),
        .init(.stopLoading, "Stop Loading", .navigation, "", [.init(".", [.command])]),
        .init(.copyAddress, "Copy Address", .navigation, "", [.init("c", [.command, .shift])]),
        .init(.copyMarkdown, "Copy as Markdown Link", .navigation, "", []),
        .init(.pasteGo, "Paste and Go", .navigation, "The default pastes plain text while editing.", [.init("v", [.command, .shift])]),
        .init(.history, "Show History", .navigation, "", [.init("y", [.command])]),
        .init(.clearHistory, "Clear History", .navigation, "Asks before removing browsing history.", []),
        .init(.addBookmark, "Bookmark This Page", .navigation, "", [.init("b", [.command, .shift])]),
        .init(.bookmarks, "Show Bookmarks", .navigation, "", []),
        .init(.previousSpace, "Previous Space", .spaces, "Follow the displayed order; wrap at the ends.", [.init("up", [.command, .option])]),
        .init(.nextSpace, "Next Space", .spaces, "Follow the displayed order; wrap at the ends.", [.init("down", [.command, .option])]),
        .init(.newSpace, "New Space", .spaces, "", []),
        .init(.renameSpace, "Rename Space", .spaces, "", []),
        .init(.duplicateSpace, "Duplicate Space", .spaces, "", []),
        .init(.moveSpaceUp, "Move Space Up", .spaces, "One step up the rail; ⌃1–⌃9 follow.", []),
        .init(.moveSpaceDown, "Move Space Down", .spaces, "One step down the rail; ⌃1–⌃9 follow.", []),
        .init(.deleteSpace, "Delete Space…", .spaces, "Asks first. The first Space cannot be deleted.", []),
        .init(.find, "Find on Page", .page, "", [.init("f", [.command])]),
        .init(.findNext, "Find Next", .page, "", [.init("g", [.command])]),
        .init(.findPrevious, "Find Previous", .page, "", [.init("g", [.command, .shift])]),
        .init(.zoomIn, "Zoom In", .page, "", [.init("=", [.command]), .init("=", [.command, .shift])]),
        .init(.zoomOut, "Zoom Out", .page, "", [.init("-", [.command]), .init("-", [.command, .shift])]),
        .init(.resetZoom, "Actual Size", .page, "", [.init("#0", [.command])]),
        .init(.print, "Print Page", .page, "", [.init("p", [.command])]),
        .init(.reader, "Reading Mode", .page, "", [.init("r", [.command, .shift])]),
        .init(.floatVideo, "Float Video", .page, "", [.init("p", [.command, .shift])]),
        .init(.stopSound, "Stop Sound in Tab", .page, "", [.init("m", [.command, .shift])]),
        .init(.hideElements, "Hide Elements", .page, "", [.init("h", [.command, .shift])]),
        .init(.hiddenElements, "Hidden on This Site", .page, "", [.init("u", [.command, .shift])]),
        .init(.resetSite, "Reset Site Data", .page, "Asks before removing this site’s stored data.", []),
        .init(.siteData, "Site Data", .tools, "", []),
        .init(.inspector, "Web Inspector", .tools, "", [.init("i", [.command, .option])]),
        .init(.console, "JavaScript Console", .tools, "", [.init("j", [.command, .option])]),
        .init(.inspectElement, "Inspect Element", .tools, "", [.init("c", [.command, .option])]),
        .init(.visual, "Visual Inspection", .tools, "", [.init("v", [.command, .option])]),
        .init(.capture, "Capture Visible Page", .tools, "", [.init("s", [.command, .option])]),
        .init(.captureArea, "Select Area to Capture", .tools, "", []),
        .init(.captureFull, "Capture Full Page", .tools, "Subject to the page capture limits.", []),
        .init(.developer, "Developer Mode", .tools, "Capture, element selection and Network, in a dock at the window’s foot.", []),
        .init(.network, "Network", .tools, "Inspect the page’s API calls.", [.init("n", [.command, .option])]),
        .init(.localhost, "Show Localhost", .tools, "", []),
        .init(.closeWindow, "Close Window", .app, "Close the focused browser window.", [.init("w", [.command, .shift])]),
        .init(.settings, "Settings", .app, "", [.init(",", [.command])]),
        .init(.fold, "Show or Hide Tab Bar", .app, "Fold the sidebar or horizontal tab bar.", [.init("s", [.command])]),
        .init(.focus, "Focus Mode", .app, "Hide the sidebar, rail and address bar until it is chosen again.", []),
        .init(.sidebar, "Tabs in Sidebar", .app, "", [.init("s", [.command, .shift])]),
        .init(.downloads, "Downloads", .app, "", [.init("j", [.command, .shift])]),
        .init(.passwords, "Passwords", .app, "", [.init("l", [.command, .option])]),
        .init(.welcome, "Welcome", .app, "", []),
        .init(.feedback, "Send Feedback", .app, "", []),
        .init(.space1, "Go to Space 1", .spaces, "By its position in the rail. Mission Control may take this default first.", [.init("#1", [.control])]),
        .init(.space2, "Go to Space 2", .spaces, "By its position in the rail. Mission Control may take this default first.", [.init("#2", [.control])]),
        .init(.space3, "Go to Space 3", .spaces, "By its position in the rail. Mission Control may take this default first.", [.init("#3", [.control])]),
        .init(.space4, "Go to Space 4", .spaces, "By its position in the rail. Mission Control may take this default first.", [.init("#4", [.control])]),
        .init(.space5, "Go to Space 5", .spaces, "By its position in the rail. Mission Control may take this default first.", [.init("#5", [.control])]),
        .init(.space6, "Go to Space 6", .spaces, "By its position in the rail. Mission Control may take this default first.", [.init("#6", [.control])]),
        .init(.space7, "Go to Space 7", .spaces, "By its position in the rail. Mission Control may take this default first.", [.init("#7", [.control])]),
        .init(.space8, "Go to Space 8", .spaces, "By its position in the rail. Mission Control may take this default first.", [.init("#8", [.control])]),
        .init(.space9, "Go to Space 9", .spaces, "By its position in the rail. Mission Control may take this default first.", [.init("#9", [.control])]),
    ]
    static let catalog = Dictionary(uniqueKeysWithValues: all.map { ($0.action, $0) })
}
