// Each browser in the import chooser and what Escale knows about it. A brand
// has an explicit identity, home and structurally checked reader. Public format
// evidence and synthetic fixtures are recorded separately from real-browser
// qualification in docs/MIGRATION.md.
// Chromium brands share discovery and reading: becoming automatic only adds
// the brand's identity, home and wording here. Chrome means Stable; Beta, Dev
// and Canary keep their own identity and folder and are chosen by hand.
// The home is read only after the user chooses that browser, never at launch
// or while a view renders. Tests use their own root under Store, never this one.
import Foundation

enum MigrationRoute: String {
    case automatic = "Automatic", export = "Via export", transfer = "Escale file", unavailable = "Unavailable"
    var symbol: String {
        switch self {
        case .transfer: return "doc.badge.gearshape"
        case .automatic: return "bolt"
        case .export: return "doc.badge.arrow.up"
        case .unavailable: return "minus.circle"
        }
    }
}

enum MigrationBrowser: String, CaseIterable, Identifiable {
    /// Another Mac's Escale, through the one file it saved (Transfer/).
    case escale = "Escale"
    case chrome = "Chrome", chromium = "Chromium", edge = "Edge", brave = "Brave"
    case vivaldi = "Vivaldi", opera = "Opera", operaGX = "Opera GX", dia = "Dia", arc = "Arc"
    case firefox = "Firefox / ESR / Developer / Beta / Nightly", zen = "Zen"
    case safari = "Safari", orion = "Orion", aside = "Aside", other = "Another browser"
    var id: String { rawValue }
    var family: String? {
        switch self {
        case .chrome, .chromium, .edge, .brave, .vivaldi, .opera, .operaGX, .dia, .arc, .aside: return "chromium"
        case .firefox, .zen: return "gecko"
        default: return nil
        }
    }
    var guidance: String {
        switch self {
        case .escale: return "Choose the file saved with Export Escale… on the other Mac."
        case .safari: return "In Safari, choose File → Export Browsing Data to File. You can also use a bookmarks HTML or passwords CSV file. Shared data and each profile's history are separate choices."
        case .zen: return "Choose a named profile for bookmarks and history, or one of its workspaces for pinned folders, essentials and sleeping tabs. Containers and sign-ins do not transfer."
        case .firefox: return "Choose the named profile from profiles.ini, or its folder shown in about:support. ESR, Beta, Developer Edition and Nightly keep separate profiles. Bookmarks, history and saved web tabs can be imported; containers and sign-ins do not transfer."
        case .orion: return "Choose an Orion profile or its data folder. Bookmarks and history use Orion’s own formats; passwords use a CSV from your password manager."
        case .other: return "Choose a bookmarks HTML file, passwords CSV file or a plain text list of links. Only the categories present in that file will be offered."
        default: return "Choose one profile folder (shown on the browser's version page), its parent folder, or an HTML/CSV export. Bookmarks, history and supported cleartext saved tabs can be imported; passwords use CSV. Browser-specific organisation and sign-ins do not transfer."
        }
    }

    /// Known app identities are added only alongside an automatic reader.
    var applicationID: String? {
        switch self {
        case .aside: return "at.studio.AsideBrowser"
        case .arc: return "company.thebrowser.Browser"
        case .chrome: return "com.google.Chrome"
        case .chromium: return "org.chromium.Chromium"
        case .edge: return "com.microsoft.edgemac"
        case .brave: return "com.brave.Browser"
        case .vivaldi: return "com.vivaldi.Vivaldi"
        case .opera: return "com.operasoftware.Opera"
        case .operaGX: return "com.operasoftware.OperaGX"
        case .dia: return "company.thebrowser.dia"
        case .firefox: return "org.mozilla.firefox"
        case .zen: return "app.zen-browser.zen"
        case .orion: return "com.kagi.kagimacOS"
        default: return nil
        }
    }

    /// Automatic describes the route, not a promise of every released version.
    var route: MigrationRoute {
        switch self {
        case .escale: return .transfer
        case .aside, .arc, .chrome, .chromium, .edge, .brave, .vivaldi, .opera, .operaGX, .dia, .firefox, .zen, .orion: return .automatic
        default: return .export
        }
    }
    var automatic: Bool { route == .automatic }
    var checklist: Bool { automatic || self == .safari }
    var routeDetail: String {
        switch self {
        case .escale: return "Bring the file saved on another Mac: every Space, its bookmarks, tabs and history, and optionally its passwords."
        case .aside, .chrome, .chromium, .edge, .brave, .vivaldi, .opera, .operaGX, .dia, .firefox, .zen, .orion: return "Find local profiles; import supported local data without an export."
        case .arc: return "Find local Spaces; import pinned tabs, Favorites and history without an export."
        default: return "Bring an exported file. Existing profile-folder readers remain available where supported."
        }
    }

    /// ESR and Beta use Firefox's identity and registry. Developer and Nightly
    /// have different identities but name their profiles in the same registry.
    var applicationIDs: [String] {
        if self == .firefox { return ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"] }
        return applicationID.map { [$0] } ?? []
    }

    /// The data folder under Application Support that discovery starts from.
    var home: String? {
        switch self {
        case .aside: return "Aside"
        case .arc: return "Arc"
        case .chrome: return "Google/Chrome"
        case .chromium: return "Chromium"
        case .edge: return "Microsoft Edge"
        case .brave: return "BraveSoftware/Brave-Browser"
        case .vivaldi: return "Vivaldi"
        case .opera: return "com.operasoftware.Opera"
        case .operaGX: return "com.operasoftware.OperaGX"
        case .dia: return "Dia"
        case .firefox: return "Firefox"
        case .zen: return "Zen"
        case .orion: return "Orion"
        default: return nil
        }
    }

    /// Names the test root (`migration-NAME`) and the demo variable
    /// `ESCALE_NAME_SOURCE`, so each automatic brand has its own isolated input.
    var slug: String { rawValue.lowercased().filter { $0.isLetter || $0.isNumber } }

    func location(user: URL, testRoot: URL?) -> URL? {
        guard let home else { return nil }
        return testRoot ?? user.appendingPathComponent("Library/Application Support/\(home)", isDirectory: true)
    }

    /// Finds sources in the chosen home; the folder is the user's selection.
    func discover(in root: URL, cancellation: MigrationCancellation, temporaryRoot: URL? = nil) throws -> [MigrationSource] {
        switch self {
        case .arc: return try MigrationArc.discover(in: root, cancellation: cancellation)
        case .firefox: return try MigrationProfiles.discover(in: root, browser: rawValue, family: "gecko", cancellation: cancellation)
        case .zen: return try MigrationZen.discover(MigrationProfiles.discover(in: root, browser: rawValue, family: "gecko", cancellation: cancellation), temporaryRoot: temporaryRoot, cancellation: cancellation)
        case .orion: return try MigrationOrion.discover(in: root, cancellation: cancellation)
        default: return try MigrationProfiles.chromium(in: root, browser: rawValue, cancellation: cancellation)
        }
    }

    /// What one source is called: a Chromium profile, or one of Arc's Spaces.
    var sourceName: String { self == .arc ? "Space" : "Profile" }
    /// The source field's label; Arc's names its brand so it is never read as
    /// the Escale Space chosen above it.
    var sourceField: String { self == .arc ? "Arc Space" : sourceName }
    var nothingFound: String { "No \(rawValue) \(sourceName.lowercased())s found." }

    /// Shown when macOS refuses the brand's folder: it opens only to a choice
    /// made in the file picker, which is why the button is the way forward.
    var refused: String { "macOS does not let Escale open \(rawValue)'s data on its own. Choose its folder once." }

    var folderHelp: String {
        let channels = self == .chrome ? " Chrome Beta, Dev and Canary keep their own folder beside it." : ""
        return "macOS lets Escale read \(rawValue)'s \(sourceName.lowercased())s only when you choose their folder. The file picker opens on ~/Library/Application Support/\(home ?? rawValue): press Open.\(channels) Escale can then read bookmarks and history; you choose what to import next. No export file is needed."
    }

    var bookmarkHelp: String? {
        switch self {
        case .arc: return "Pinned tabs keep their folders and order. Favorites arrive in a Favorites folder at the top. Today tabs are not imported."
        case .zen: return "A profile imports Places bookmarks; a workspace imports its pinned tabs and folders, including shared essentials. Workspace and container sign-ins do not travel. Choose the destination Space explicitly."
        case .edge: return "Bookmark folders are kept. Edge Collections are separate and are not imported."
        case .brave: return "Bookmark folders are kept. Wallets, Rewards and Brave-specific private data are not imported."
        case .vivaldi: return "Bookmark folders are kept. Speed Dial folders remain ordinary folders; workspaces, stacks, notes and trash are not imported."
        case .opera, .operaGX: return "Speed Dial entries in the bookmark tree remain ordinary bookmarks and folders. Workspaces and GX-specific data are not imported."
        case .dia: return "Chromium-format bookmarks are kept. Dia-specific groups, chats and skills are not imported."
        case .orion: return "Orion bookmark folders and their order are kept. Named windows, pinned tabs and reading lists are not imported."
        default: return nil
        }
    }

    var tabHelp: String {
        "Only web addresses, titles, order and pins are restored, without loading pages. Windows are combined in the chosen Escale Space; groups, split views, containers, forms and sign-ins do not travel. Existing imported tabs are kept. Close the source browser first for its latest saved session."
    }

    var passwordHelp: String {
        let export = self == .chrome ? "In Chrome, open Google Password Manager, then Settings → Export passwords" : "Choose a CSV exported by your password manager"
        return "\(export). Escale imports it immediately and keeps existing accounts. \(rawValue)'s saved passwords are not read directly."
    }

    /// Bookmark exports accepted from Other options.
    var bookmarkExports: [String] { self == .arc ? ["html", "htm", "txt", "md"] : ["html", "htm"] }
    var exportHelp: String? {
        switch self {
        case .arc: return "When Arc's sidebar cannot be read, use Copy All Links in Arc and save the list as a text file. Links keep their order; folders, Spaces and pins are not preserved."
        case .chrome: return "When a profile cannot be read, open Chrome's Bookmark Manager (⌥⌘B), choose ⋮ → Export bookmarks and select the saved HTML file. Folders and order are kept."
        default: return nil
        }
    }

    var unavailable: [(title: String, symbol: String, reason: String)] {
        let tabs: String
        switch self {
        case .arc: tabs = "Today tabs, Easels, Boosts and split views stay in Arc. Pinned tabs and Favorites arrive as bookmarks."
        case .chrome: tabs = "No saved session was found in this selection. Supported cleartext sessions can restore sleeping tabs; encrypted sessions, tab groups and workspaces cannot."
        default: tabs = "No supported saved tabs are available in this selection. Browser-specific workspaces and sign-ins are not transferred."
        }
        return [
            ("Cookies & sessions", "lock.shield", "Escale does not transfer cookies or signed-in sessions. Sign in again in the destination Space."),
            ("Tabs & workspaces", "rectangle.on.rectangle", tabs),
            ("Extensions", "puzzlepiece.extension", "Extensions are not copied during import. Install supported extensions separately in Escale."),
            ("Passkeys", "person.badge.key", "Passkeys are not part of this import. Their availability depends on macOS or your password manager."),
        ]
    }
}
