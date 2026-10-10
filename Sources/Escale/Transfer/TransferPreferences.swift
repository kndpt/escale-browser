// Which preferences travel. A preference travels when its meaning is the same
// on any Mac: look, layout, search, tabs, blocker and password switches. What
// names this Mac stays: the bench switch and local alerts socket (opt-in
// sockets), the downloads folder (a path), passkeys (an entitlement), the first
// launch mark. The list is closed on purpose: an unknown key in a file is never
// written, and a value of the wrong kind or outside an enum is skipped.
import SwiftUI

@MainActor
enum TransferPreferences {
    private struct Entry {
        let key: String
        let read: (Preferences) -> TransferScalar
        let write: (Preferences, TransferScalar) -> Bool
    }

    private static func flag(_ key: String, _ path: ReferenceWritableKeyPath<Preferences, Bool>) -> Entry {
        Entry(key: key, read: { .flag($0[keyPath: path]) }, write: { prefs, value in
            guard case .flag(let on) = value else { return false }
            // Only what differs is set: setting a preference runs its side effects.
            if prefs[keyPath: path] != on { prefs[keyPath: path] = on }
            return true
        })
    }

    private static func choice<T: RawRepresentable & Equatable>(_ key: String, _ path: ReferenceWritableKeyPath<Preferences, T>) -> Entry where T.RawValue == String {
        Entry(key: key, read: { .word($0[keyPath: path].rawValue) }, write: { prefs, value in
            guard case .word(let word) = value, let chosen = T(rawValue: word) else { return false }
            if prefs[keyPath: path] != chosen { prefs[keyPath: path] = chosen }
            return true
        })
    }

    private static let entries: [Entry] = [
        choice("look", \.look), choice("tone", \.tone), choice("depth", \.depth), flag("glass.contrast", \.increasesContrast),
        flag("bar.copy", \.copyDoor), choice("interface.size", \.interfaceSize),
        flag("sidebar", \.sidebar), flag("sidebar.hides", \.sideHides), flag("sidebar.bar", \.addressBar),
        flag("sidebar.bookmarks", \.sideBookmarks), flag("sidebar.bookmarks.folded", \.sideBookmarksFolded),
        Entry(key: "sidebar.width", read: { .number(Double($0.sideWidth)) }, write: { prefs, value in
            guard case .number(let width) = value, width.isFinite, width >= 100, width <= 1_000 else { return false }
            if prefs.sideWidth != CGFloat(width) { prefs.sideWidth = CGFloat(width) }
            return true
        }),
        choice("glyph", \.glyph), choice("search.engine", \.engine),
        Entry(key: "search.custom", read: { .word($0.customEngine) }, write: { prefs, value in
            guard case .word(let text) = value, text.utf8.count <= TransferLimits.field else { return false }
            if prefs.customEngine != text { prefs.customEngine = text }
            return true
        }),
        Entry(key: "search.keywords", read: { .word($0.searchKeywords) }, write: { prefs, value in
            guard case .word(let text) = value, text.utf8.count <= TransferLimits.field else { return false }
            if prefs.searchKeywords != text { prefs.searchKeywords = text }
            return true
        }),
        flag("tabs.sleep", \.sleepsTabs),
        Entry(key: "tabs.sleep.after", read: { .number(Double($0.sleepDelay.rawValue)) }, write: { prefs, value in
            guard case .number(let minutes) = value, let chosen = Int(exactly: minutes).flatMap(SleepDelay.init) else { return false }
            if prefs.sleepDelay != chosen { prefs.sleepDelay = chosen }
            return true
        }),
        flag("tabs.reading", \.showsReading), flag("shield", \.shielded),
        flag("extensions.private", \.extensionsInPrivate), flag("downloads.ask", \.asksWhereToSave),
        flag("passwords.save", \.savesPasswords), flag("passwords.fill", \.fillsPasswords),
        flag("autoscroll", \.autoScroll), flag("links.show", \.showsLinks), flag("selection.menu", \.selectionMenu),
        flag("spaces", \.usesSpaces),
        flag("alerts.agents", \.alertAgents), flag("alerts.builds", \.alertBuilds),
        flag("alerts.prs", \.alertPRs), flag("alerts.workflows", \.alertWorkflows),
    ]

    /// Whether the person has set any portable preference here: one persisted
    /// under its own key, however it got there. A new Escale has none.
    static func touched() -> Bool {
        entries.contains { Store.settings.object(forKey: $0.key) != nil }
    }

    static func snapshot(_ prefs: Preferences) -> [String: TransferScalar] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.read(prefs)) })
    }

    /// How many of the file's preferences are ones this Escale knows.
    static func known(_ values: [String: TransferScalar]) -> Int {
        let names = Set(entries.map(\.key))
        return values.keys.filter(names.contains).count
    }

    /// Applies what is valid and known; returns how many were applied.
    static func apply(_ values: [String: TransferScalar], to prefs: Preferences) -> Int {
        var applied = 0
        for entry in entries {
            guard let value = values[entry.key], entry.write(prefs, value) else { continue }
            applied += 1
        }
        return applied
    }
}
