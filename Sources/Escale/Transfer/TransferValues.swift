// What a transfer file holds once opened, and the checks that stand between it
// and the destination. Nothing in it is a path of the source Mac, a live page
// or a grant: Spaces carry their organisation (bookmarks, tabs, history, what
// was learned, hidden elements, zoom, blocker pauses) and, only when asked,
// their saved passwords; the window carries its link rules and the portable
// preferences. `checked()` refuses what is structurally wrong (bounds, repeated
// identities, references to what is not in the file) and quietly drops what is
// merely not portable (an address that is not http or https), counting it, so
// nothing reaches a writer before the whole file has passed.
import Foundation

/// A preference as written: a preference is a flag, a number or a word.
enum TransferScalar: Codable, Equatable {
    case flag(Bool), number(Double), word(String)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let flag = try? value.decode(Bool.self) { self = .flag(flag) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else { self = .word(try value.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .flag(let flag): try value.encode(flag)
        case .number(let number): try value.encode(number)
        case .word(let word): try value.encode(word)
        }
    }
}

struct TransferLogin: Codable, Equatable {
    var host: String
    var user: String
    var password: String
    var used: Date?
}

struct TransferSpace: Codable {
    var id: UUID
    var name: String
    var colour: Int
    var icon: String?
    /// Extensions to install again here: names and store identities only.
    var extensions: [PlannedExtension]
    var session: Session.Shape
    var bookmarks: [Bookmark]
    var history: [Visit]
    var habits: [String: [Habits.Pick]]
    var hidden: [String: [Veil]]
    var zoom: [String: Double]
    var paused: [String]
    var never: [String]
    /// Present only when the passwords were asked for.
    var logins: [TransferLogin]?
}

struct TransferPayload: Codable {
    static let schema = 1

    var schema: Int = TransferPayload.schema
    /// Names this export: importing the same file again finds its Spaces.
    var id: UUID
    var created: Date
    var app: String
    var spaces: [TransferSpace]
    var preferences: [String: TransferScalar]
    var linkRules: [LinkRule]
    var includesPasswords: Bool
}

/// One line of the summary shown before anything is applied.
struct TransferLine: Equatable {
    var name: String
    var tabs: Int
    var bookmarks: Int
    var history: Int
    var passwords: Int
    var extensions: Int
}

struct TransferSummary: Equatable {
    var created: Date
    var app: String
    var lines: [TransferLine]
    var linkRules: Int
    var preferences: Int
    var includesPasswords: Bool
    /// Items left out because they are not portable, counted, not listed.
    var skipped: Int
}

enum TransferLimits {
    static let spaces = 64
    static let tabs = 20_000
    static let nodes = 50_000
    static let depth = 32
    static let hosts = 10_000
    static let veils = 20_000
    static let logins = 20_000
    static let extensions = 500
    static let field = 4_096
    static let name = 200
}

@MainActor
extension TransferPayload {
    /// The file as it will be applied: sanitised, or the reason it can't be.
    /// Pure: nothing is written, nothing on this Mac is read.
    func checked() throws -> (payload: TransferPayload, summary: TransferSummary) {
        guard schema == Self.schema else { throw TransferError.unsupported(schema) }
        guard (1...TransferLimits.spaces).contains(spaces.count) else { throw TransferError.invalid("the number of Spaces") }
        guard Set(spaces.map(\.id)).count == spaces.count else { throw TransferError.invalid("a Space appears twice") }
        guard linkRules.count <= LinkRule.limit, LinkRule.validation(linkRules) == nil else { throw TransferError.invalid("the link rules") }
        let known = Set(spaces.map(\.id))
        guard linkRules.allSatisfy({ known.contains($0.destination) }) else {
            throw TransferError.invalid("a link rule points to a Space that isn't in the file")
        }
        var skipped = 0
        var clean: [TransferSpace] = []
        for space in spaces {
            clean.append(try space.checked(includesPasswords: includesPasswords, skipped: &skipped))
        }
        var made = self
        made.spaces = clean
        let lines = clean.map {
            TransferLine(name: $0.name, tabs: $0.session.tabs.count, bookmarks: Bookmarks.count($0.bookmarks),
                         history: $0.history.count, passwords: $0.logins?.count ?? 0, extensions: $0.extensions.count)
        }
        return (made, TransferSummary(created: created, app: app, lines: lines, linkRules: linkRules.count,
                                      preferences: preferences.count, includesPasswords: includesPasswords, skipped: skipped))
    }
}

@MainActor
extension TransferSpace {
    fileprivate func checked(includesPasswords: Bool, skipped: inout Int) throws -> TransferSpace {
        var made = self
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        made.name = String((title.isEmpty ? "Space" : title).prefix(TransferLimits.name))
        if !(0..<Spaces.colours.count).contains(colour) { made.colour = 0 }
        if let icon, !Spaces.icons.contains(icon) { made.icon = nil }
        guard extensions.count <= TransferLimits.extensions else { throw TransferError.invalid("the extensions of “\(made.name)”") }
        made.extensions = extensions.filter { $0.name.utf8.count <= TransferLimits.field && ($0.storeID?.utf8.count ?? 0) <= TransferLimits.field }

        // Bookmarks: bounded, each identity once, folders without an address.
        var identities = Set<UUID>(), count = 0
        func walk(_ nodes: [Bookmark], depth: Int) throws -> [Bookmark] {
            guard depth <= TransferLimits.depth else { throw TransferError.invalid("bookmarks nested too deeply in “\(made.name)”") }
            var kept: [Bookmark] = []
            for node in nodes {
                count += 1
                guard count <= TransferLimits.nodes, node.title.utf8.count <= TransferLimits.field,
                      identities.insert(node.id).inserted else { throw TransferError.invalid("the bookmarks of “\(made.name)”") }
                var item = node
                if node.isFolder {
                    guard node.url == nil else { throw TransferError.invalid("the bookmarks of “\(made.name)”") }
                    item.children = try walk(node.children ?? [], depth: depth + 1)
                } else {
                    guard let address = node.url, MigrationLimits.url(address) != nil else { skipped += 1; continue }
                    guard node.children == nil else { throw TransferError.invalid("the bookmarks of “\(made.name)”") }
                }
                guard BookmarkEnvironment.valid(item.environments ?? []) else { throw TransferError.invalid("the environments of “\(made.name)”") }
                kept.append(item)
            }
            return kept
        }
        made.bookmarks = try walk(bookmarks, depth: 0)

        // Tabs: a tab without an address is left out unless a split names its
        // position, in which case the whole row must be whole (Session.valid).
        guard session.tabs.count <= TransferLimits.tabs else { throw TransferError.invalid("the tabs of “\(made.name)”") }
        guard Session.valid(session) else { throw TransferError.invalid("the tabs of “\(made.name)”") }
        for entry in session.tabs {
            if let link = entry.bookmark, !identities.contains(link) {
                throw TransferError.invalid("a tab of “\(made.name)” points to a bookmark that isn't in the file")
            }
        }
        // A split names tab positions, so its row stays whole and every address
        // must pass; without one, tabs that are not web pages are dropped.
        if !(session.panels?.isEmpty ?? true) {
            guard session.tabs.allSatisfy({ MigrationLimits.url($0.url) != nil }) else {
                throw TransferError.invalid("the tabs of “\(made.name)”")
            }
        } else {
            let kept = session.tabs.filter { MigrationLimits.url($0.url) != nil }
            skipped += session.tabs.count - kept.count
            made.session = Session.Shape(tabs: kept, active: min(max(session.active, 0), max(kept.count - 1, 0)))
        }

        guard history.count <= History.room, Set(history.map(\.key)).count == history.count else {
            throw TransferError.invalid("the history of “\(made.name)”")
        }
        made.history = history.filter { MigrationLimits.url($0.url) != nil && $0.count >= 0 && !$0.key.isEmpty }
        skipped += history.count - made.history.count

        guard habits.count <= Habits.queries else { throw TransferError.invalid("what “\(made.name)” learned") }
        made.habits = habits.filter { query, picks in
            Habits.query(query) == query && !picks.isEmpty && picks.count <= Habits.places
                && picks.allSatisfy { $0.count.isFinite && $0.count > 0 && $0.count <= Habits.most && !$0.to.isEmpty && $0.to.count <= Habits.longestPlace }
        }

        guard hidden.count <= TransferLimits.hosts, hidden.values.reduce(0, { $0 + $1.count }) <= TransferLimits.veils else {
            throw TransferError.invalid("the hidden elements of “\(made.name)”")
        }
        made.hidden = hidden.compactMapValues { veils in
            let kept = veils.filter { !$0.selector.isEmpty && $0.selector.utf8.count <= TransferLimits.field }
            return kept.isEmpty ? nil : kept
        }
        guard zoom.count <= TransferLimits.hosts, paused.count <= TransferLimits.hosts, never.count <= TransferLimits.hosts else {
            throw TransferError.invalid("the site settings of “\(made.name)”")
        }
        func host(_ text: String) -> Bool {
            !text.isEmpty && text.utf8.count <= 253 && !text.contains(where: { $0.isWhitespace || $0 == "/" })
        }
        made.zoom = zoom.filter { host($0.key) && $0.value.isFinite && (0.1...10).contains($0.value) }
        made.paused = paused.filter(host)
        made.never = never.filter(host)

        if includesPasswords {
            let found = logins ?? []
            guard found.count <= TransferLimits.logins else { throw TransferError.invalid("the passwords of “\(made.name)”") }
            made.logins = found.filter {
                host($0.host) && !$0.password.isEmpty && $0.user.utf8.count <= TransferLimits.field && $0.password.utf8.count <= TransferLimits.field
            }
            skipped += found.count - (made.logins?.count ?? 0)
        } else {
            made.logins = nil
        }
        return made
    }
}
