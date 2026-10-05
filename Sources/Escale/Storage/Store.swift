import Foundation
import WebKit

// Where everything this browser keeps is kept.
//
// One place, and one rule: a run started for testing never touches the folder
// or the settings of the browser somebody is actually using. Sharing them once
// cost a person their pinned tabs, which is not a mistake worth being able to
// make twice.

enum Store {
    /// The bundle id of the browser somebody uses. Its standard defaults and
    /// its WebKit container are that browser's, whatever the run says it is.
    static let product = "com.kndpt.escale"

    /// The bundle id of a test world's own copy of the app, which fresh.sh
    /// makes: com.kndpt.escale.probe.<world>.
    static func probeBundle(_ world: String) -> String { "\(product).probe.\(world)" }

    /// A run is a test run if it says so, if it is a test world's copy, or
    /// if it is being run straight out of the build folder rather than from
    /// an installed app. The last is not belt and braces: a development build
    /// launched from a terminal once wrote over somebody's real session, and
    /// asking a person to remember a flag is not a safeguard. Nor is it for a
    /// test copy opened from the Finder, without the flag.
    static var testing: Bool {
        if ProcessInfo.processInfo.environment["ESCALE_PROBE"] != nil { return true }
        if Bundle.main.bundleIdentifier?.hasPrefix(probeBundle("")) == true { return true }
        return Bundle.main.executablePath?.contains("/.build/") == true
    }

    /// Which test world a test run lives in. ESCALE_PROBE=1, or a run from
    /// the build folder, is the test world, "Escale (test)". ESCALE_PROBE=
    /// <name> is a world of its own, "Escale (<name>)", with settings and
    /// WebKit stores of its own: two sessions testing at once, or a
    /// measurement that needs a browser nobody has installed anything in,
    /// never borrow each other's. A world's copy without the flag is that
    /// world. Nil for the browser somebody is using.
    ///
    /// Settled once, before anything is written (see EscaleApp.init), and a
    /// test run under an identity that isn't its own stops here (`admit`).
    static let world: String? = {
        guard testing else { return nil }
        let bundle = Bundle.main.bundleIdentifier ?? ""
        let named = ProcessInfo.processInfo.environment["ESCALE_PROBE"]
            ?? (bundle.hasPrefix(probeBundle("")) ? String(bundle.dropFirst(probeBundle("").count)) : "")
        let asked = named.lowercased()
            .filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
        let world = asked.isEmpty || asked == "1" || asked == "test" ? "test" : asked
        admit(world)
        return world
    }()

    /// The settings suite keeps Escale's own settings apart, but not what
    /// WebKit and AppKit write to the app's standard defaults by themselves —
    /// the text checker's switches (Preferences.configurePageText), window frames —
    /// nor WebKit's container, which goes by bundle id. A test run shares
    /// those with whatever else runs under its bundle id, so it runs under
    /// one nobody else does: its world's copy, or a bare binary from
    /// .build/, whose defaults and container are named after the executable
    /// ("Escale", shared by the worlds run that way but never the real
    /// browser's). Under any other id — the real one above all — it stops
    /// before writing anything rather than share.
    private static func admit(_ world: String) {
        guard let bundle = Bundle.main.bundleIdentifier, bundle != probeBundle(world) else { return }
        refuse("a test run of world \"\(world)\" runs as \(probeBundle(world)), not \(bundle) — "
            + "ESCALE_PROBE=\(world) ./fresh.sh makes that copy")
    }

    /// Stop a test run that can't be kept apart, saying why on stderr and in
    /// the system log. Exit status 78 is EX_CONFIG.
    static func refuse(_ why: String) -> Never {
        FileHandle.standardError.write(Data("Escale: \(why)\n".utf8))
        NSLog("Escale: %@", why)
        exit(78)
    }

    /// A test run there to be weighed and timed rather than driven
    /// (ESCALE_MEASURE beside ESCALE_PROBE). It keeps what the shipped
    /// browser does where test runs otherwise differ — hidden pages slowed
    /// the way WebKit slows them, App Nap left to macOS — so what gets
    /// measured is what people get.
    static var measuring: Bool {
        testing && ProcessInfo.processInfo.environment["ESCALE_MEASURE"] != nil
    }

    /// Cookies, sign-ins, caches. WebKit keeps its default store per bundle,
    /// not per folder, so a test run got every site already signed in — and
    /// "sign out of everything" in a test run signed the real browser out.
    /// A test run gets a store of its own, under a fixed name so it persists
    /// between probes the way the real one does. Wiping the test store is
    /// then as safe as wiping its folder.
    static var websites: WKWebsiteDataStore {
        guard testing, !ownContainer else { return .default() }
        return WKWebsiteDataStore(forIdentifier: probeStore(1))
    }

    /// A world's copy of the app has a WebKit container of its own too, so
    /// it can use WebKit's default store and extension configuration — the
    /// ones the real browser uses, which differ from stores made by
    /// identifier in how long extension workers are let live. A bare binary
    /// shares its container with the other worlds run from .build/, so it
    /// keeps its world's stores by identifier.
    static var ownContainer: Bool {
        world.map { Bundle.main.bundleIdentifier == probeBundle($0) } ?? false
    }

    /// The fixed identifiers of a test world's WebKit stores when it has no
    /// container of its own: 1 for websites, 2 for extensions. The test
    /// world's are 5E4C0000-0000-4000-8000-00000000000k; a named world puts a
    /// hash of its name (FNV-1a, 32 bits) in place of the second and third
    /// groups of zeros, so each keeps its own from one run to the next.
    static func probeStore(_ kind: UInt32) -> UUID {
        var hash: UInt32 = 0
        if let world, world != "test" {
            hash = 2_166_136_261
            for byte in world.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        }
        let text = String(format: "5E4C%04X-%04X-4000-8000-%012X", hash >> 16, hash & 0xFFFF, kind)
        return UUID(uuidString: text)!
    }

    /// Escale's own folder, apart from the Search it grew out of: nothing is
    /// read from or moved out of Search's, so both can run side by side.
    static let folder: URL = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(world.map { "Escale (\($0))" } ?? "Escale", isDirectory: true)
    }()

    /// Explicit exports use the destination chosen by the user.
    static func export(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    static func file(_ name: String) -> URL {
        folder.appendingPathComponent(name)
    }

    /// Site zoom from before Spaces stays with the first. Other keys carry
    /// the space ID, so visiting the same host in two projects stays separate.
    static func zoomKey(_ host: String, space: UUID) -> String {
        space == Space.firstID ? "zoom.\(host)" : "zoom.\(space.uuidString).\(host)"
    }

    static func zooms(in space: UUID) -> [String: Double] {
        let prefix = space == Space.firstID ? "zoom." : "zoom.\(space.uuidString)."
        var found: [String: Double] = [:]
        for (key, value) in settings.dictionaryRepresentation() where key.hasPrefix(prefix) {
            let host = String(key.dropFirst(prefix.count))
            if space == Space.firstID, let dot = host.firstIndex(of: "."),
               UUID(uuidString: String(host[..<dot])) != nil { continue }
            if let zoom = value as? Double { found[host] = zoom }
        }
        return found
    }

    static func eraseZoom(space: UUID) {
        guard space != Space.firstID else { return }
        for host in zooms(in: space).keys { settings.removeObject(forKey: zoomKey(host, space: space)) }
    }

    /// A file that didn't decode is set aside rather than overwritten the
    /// next time something is saved over it — bookmarks, history and a
    /// session are the kind of thing nobody wants to lose to a bad read with
    /// no trace of what was there. Failing to move it is fine: the read
    /// already came back empty either way, and there's nothing further to
    /// do about a folder that won't take a rename.
    static func quarantine(_ file: URL) {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = file.deletingLastPathComponent()
            .appendingPathComponent("\(file.deletingPathExtension().lastPathComponent).unreadable-\(stamp).json")
        try? FileManager.default.moveItem(at: file, to: aside)
    }

    /// Settings live apart too: a test that changes what the tabs wear or
    /// where the tabs go must not change yours. Never the standard defaults
    /// in their place, whoever those belong to: a suite that can't be opened
    /// stops the run.
    static let settings: UserDefaults = {
        guard let world else { return .standard }
        let suite = world == "test" ? "\(product).test" : "\(product).test.\(world)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            refuse("the settings of world \"\(world)\", \(suite), can't be opened")
        }
        return defaults
    }()
}
