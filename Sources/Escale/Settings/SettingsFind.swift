// Find a setting reads the same titles the rows show: each Settings row is
// drawn from this catalogue, so a new row is found without a keyword list to
// keep beside it. A description that changes with state is searched by its
// usual wording. A row shown only once another is on (Agent sessions under
// Alerts) names that one, which is what a search lands on while it is off.
import SwiftUI

enum Setting: String, CaseIterable, Identifiable {
    case defaultBrowser, engine, keywords, downloads, askWhere
    case defaultZoom, showsLinks, selection, autoScroll
    case theme, colours, transparency, contrast, fasterShortcuts, interfaceSize
    case sidebar, sideFolded, addressBar, sideBookmarks, copyDoor, glyph, reading, sleep, sleepAfter, spaces
    case vault, savePasswords, fillPasswords, passkeys, neverAsked, importPasswords
    case alerts, agents, builds, pullRequests, workflows, bench
    case shield, capture, history, cookies, cache
    case feedback

    var id: String { rawValue }

    var page: SettingsPanel.Page {
        switch self {
        case .defaultBrowser, .engine, .keywords, .downloads, .askWhere: return .general
        case .defaultZoom, .showsLinks, .selection, .autoScroll: return .pages
        case .theme, .colours, .transparency, .contrast, .fasterShortcuts, .interfaceSize: return .appearance
        case .sidebar, .sideFolded, .addressBar, .sideBookmarks, .copyDoor, .glyph, .reading, .sleep, .sleepAfter, .spaces: return .tabs
        case .vault, .savePasswords, .fillPasswords, .passkeys, .neverAsked, .importPasswords: return .passwords
        case .alerts, .agents, .builds, .pullRequests, .workflows, .bench: return .developer
        case .shield, .capture, .history, .cookies, .cache: return .privacy
        case .feedback: return .about
        }
    }

    /// The row that shows this one while it is on.
    var under: Setting? {
        switch self {
        case .sideFolded, .addressBar, .sideBookmarks: return .sidebar
        case .sleepAfter: return .sleep
        // Listed only once a site was told to stop offering.
        case .neverAsked: return .savePasswords
        case .agents, .builds, .pullRequests, .workflows: return .alerts
        default: return nil
        }
    }

    var title: String { words.title }
    var detail: String { words.detail }

    private var words: (title: String, detail: String) {
        switch self {
        case .defaultBrowser: return ("Open links from other apps", "Mail, Slack and the rest still send links elsewhere")
        case .engine: return ("Search with", "Where words that aren't an address go")
        case .keywords: return ("Search a site by keyword", "A keyword, then an address with %s, on each line. Type “npm react” to search npm")
        case .downloads: return ("Save downloads to", "The folder new downloads go to")
        case .askWhere: return ("Ask where to save each file", "")
        case .defaultZoom: return ("Default zoom", "For every site you haven't zoomed. Actual Size returns a site to it")
        case .showsLinks: return ("Show where links go", "Point at a link and its address shows at the bottom of the page")
        case .selection: return ("Copy or translate selected text", "Select text on a page with the mouse and Copy and Translate appear beside it")
        case .autoScroll: return ("Scroll with the middle button", "Click the wheel on a page, then move the mouse up or down to scroll, as on Windows. Click again to stop")
        case .theme: return ("Theme", "Light, dark, or whatever the Mac is doing — pages follow it too")
        case .colours: return ("Colours", "Neutral greys, or Escale's own warm sand and umber, in light and dark")
        case .transparency: return ("Transparency", "How much shows through Escale's own surfaces — never through pages")
        case .contrast: return ("Increase contrast", "Stronger edges, separators and secondary text in Escale's own surfaces")
        case .fasterShortcuts: return ("Faster shortcut animations", "Tab and layout changes finish sooner from the keyboard. macOS Reduce Motion takes priority.")
        case .interfaceSize: return ("Interface size", "Changes Escale's controls, not the zoom of web pages")
        case .sidebar: return ("Tabs in a sidebar", "Down the left instead of across the top. Pull its edge to make it wider; double-click the edge to reset.")
        case .sideFolded: return ("Keep the sidebar folded", "Folded from launch, the page takes the tabs' room. Use its button or your Keyboard shortcut to bring it back.")
        case .addressBar: return ("Address bar above the page", "Back, forward, reload, the site and the page's title across the top, as in Arc's developer mode. Click the site for its details, the title to go somewhere else.")
        case .sideBookmarks: return ("Bookmarks in the sidebar", "Above the tabs, folders opening in place. Bookmark This Page adds the page you're on.")
        case .copyDoor: return ("Copy address button", "Beside the page's title while the pointer is on it in the address bar, at the right end of the tab row. Off, Copy Address stays in the site's card and in the Tabs menu")
        case .glyph: return ("Tabs show", "Beside the title, and on a pinned square")
        case .reading: return ("Show how far you've read", "The tab you're on fills with grey as you scroll down the page")
        case .sleep: return ("Sleep tabs you aren't using", "A while away, they come back where you left them. Pinned tabs, sound, calls and anything typed stay awake.")
        case .sleepAfter: return ("Sleep after", "How long a tab waits once you leave it")
        case .spaces: return ("Spaces", "Independent workspaces with their own sites and accounts. Switch from the Spaces menu, the rail or a swipe. Set your shortcuts in Keyboard.")
        case .vault: return ("Your passwords", "In the macOS keychain, shown with Touch ID")
        case .savePasswords: return ("Offer to save passwords", "Asked once per site, never again for a site you refuse")
        case .fillPasswords: return ("Fill in sign-ins", "Click a sign-in box and the accounts kept for the site hang from it")
        case .passkeys: return ("Offer passkeys", "Touch ID or an iCloud passkey, on sites that offer one")
        case .neverAsked: return ("Sites never asked", "Sites told to stop offering")
        case .importPasswords: return ("Bring yours in", "From Dia, Chrome, Arc, Brave or Edge on this Mac — nothing leaves it")
        case .alerts: return ("Alerts from local tools", "An agent or script on this Mac can send a short event to macOS. Nothing is checked online.")
        case .agents: return ("Agent sessions", "Completion and other events from coding agents")
        case .builds: return ("Builds", "Results from local build tools")
        case .pullRequests: return ("Pull requests", "Events sent by a local PR tool")
        case .workflows: return ("Workflows", "Events sent by a local workflow tool")
        case .bench: return ("Let a script drive Escale", "A local socket for testing. Its tabs open beside yours with a flask on them and never take over — see ./bench")
        case .shield: return ("Block ads and trackers", "Third parties whose only job is to watch")
        case .capture: return ("Camera and microphone", "What sites in this Space were allowed or refused")
        case .history: return ("History", "Pages visited in this Space")
        case .cookies: return ("Cookies and sign-ins", "Signs you out of every site, in every Space")
        case .cache: return ("Cache", "Only what was fetched to draw pages, in every Space")
        case .feedback: return ("Found something wrong?", "Opens a draft with the version already in it")
        }
    }

    /// Every word of the query, in any order, in the title or the description.
    func matches(_ query: String) -> Bool { Setting.words(query, in: title + " " + detail) }

    static func found(_ query: String) -> [Setting] {
        Setting.words(query).isEmpty ? [] : allCases.filter { $0.matches(query) }
    }

    static func words(_ query: String) -> [String] { query.split(whereSeparator: \.isWhitespace).map(String.init) }
    static func words(_ query: String, in text: String) -> Bool {
        let words = words(query)
        return !words.isEmpty && words.allSatisfy { text.localizedStandardContains($0) }
    }
}

/// The rows a page draws, so a search lands on a hidden row's parent.
struct SettingsShown: PreferenceKey {
    static let defaultValue: Set<Setting> = []
    static func reduce(value: inout Set<Setting>, nextValue: () -> Set<Setting>) { value.formUnion(nextValue()) }
}

private struct SettingFoundKey: EnvironmentKey {
    static let defaultValue: Setting? = nil
}

extension EnvironmentValues {
    /// The row a search just opened, marked for a moment (Line).
    var settingFound: Setting? {
        get { self[SettingFoundKey.self] }
        set { self[SettingFoundKey.self] = newValue }
    }
}
