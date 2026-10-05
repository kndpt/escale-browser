// Only departures from the finite command catalogue are saved. An empty list
// means deliberately unassigned. Replacing a collision keeps the other command's
// unrelated alternatives; reset uses the same collision check as recording.
import AppKit

struct KeyBindings: Codable, Equatable {
    private(set) var overrides: [String: [KeyStroke]] = [:]
    func keys(_ action: KeyAction) -> [KeyStroke] { overrides[action.rawValue] ?? action.command.defaults }
    func changed(_ action: KeyAction) -> Bool { overrides[action.rawValue] != nil }
    func conflicts(_ strokes: [KeyStroke], excluding action: KeyAction) -> [KeyAction] {
        KeyAction.allCases.filter { $0 != action && keys($0).contains(where: strokes.contains) }
    }
    func action(for stroke: KeyStroke) -> KeyAction? { KeyAction.allCases.first { keys($0).contains(stroke) } }

    @discardableResult mutating func set(_ strokes: [KeyStroke], for action: KeyAction, replacing: Bool = false) -> Bool {
        guard strokes.count <= 2, Set(strokes).count == strokes.count,
              strokes.allSatisfy({ $0.refusal == nil || action.command.defaults.contains($0) }) else { return false }
        let collisions = conflicts(strokes, excluding: action)
        guard replacing || collisions.isEmpty else { return false }
        for other in collisions { assign(keys(other).filter { !strokes.contains($0) }, to: other) }
        assign(strokes, to: action)
        return true
    }
    private mutating func assign(_ strokes: [KeyStroke], to action: KeyAction) {
        overrides[action.rawValue] = strokes == action.command.defaults ? nil : strokes
    }
    mutating func reset() { overrides = [:] }

    static func read(_ data: Data?) -> KeyBindings {
        guard let data, data.count <= 65536, let decoded = try? JSONDecoder().decode(KeyBindings.self, from: data) else { return KeyBindings() }
        // Validate the whole snapshot before publishing it. Overrides that clear a
        // collision must all be present before the effective assignments are checked.
        var clean = KeyBindings()
        for action in KeyAction.allCases {
            if let strokes = decoded.overrides[action.rawValue], strokes.count <= 2,
               Set(strokes).count == strokes.count,
               strokes.allSatisfy({ $0.refusal == nil || action.command.defaults.contains($0) }) {
                clean.assign(strokes, to: action)
            }
        }
        var used = Set<KeyStroke>()
        for action in KeyAction.allCases {
            let strokes = clean.keys(action).filter { used.insert($0).inserted }
            clean.assign(strokes, to: action)
        }
        return clean
    }
    var data: Data? { try? JSONEncoder().encode(self) }

    func matches(_ command: KeyCommand, query: String) -> Bool {
        let haystack = command.title + " " + command.detail + " " + command.group.rawValue
        let words = Self.words(query)
        let modifiers: [String: NSEvent.ModifierFlags] = ["command": .command, "cmd": .command, "control": .control, "ctrl": .control, "option": .option, "alt": .option, "shift": .shift]
        let required = words.reduce(into: NSEvent.ModifierFlags()) { if let flag = modifiers[$1] { $0.insert(flag) } }
        let remaining = words.filter { modifiers[$0] == nil }
        if !required.isEmpty {
            // A complete chord searches keys, not letters in titles (the T in
            // “Tabs” must not make every Command–Shift command match ⌘⇧T).
            if remaining.count == 1, let key = remaining.first,
               key.count == 1 || KeyStroke.special.values.map({ $0.lowercased() }).contains(key) {
                return keys(command.action).contains {
                    $0.flags == required && ($0.key.replacingOccurrences(of: "#", with: "").lowercased() == key || $0.glyph.lowercased() == key)
                }
            }
            guard keys(command.action).contains(where: { $0.flags.isSuperset(of: required) }) else { return false }
        }
        return remaining.allSatisfy { word in haystack.localizedStandardContains(word) || keys(command.action).contains(where: { $0.searchText.localizedStandardContains(word) }) }
    }

    static func words(_ query: String) -> [String] {
        query.lowercased().replacingOccurrences(of: "+", with: " ")
            .replacingOccurrences(of: "⌘", with: " command ")
            .replacingOccurrences(of: "⌥", with: " option ")
            .replacingOccurrences(of: "⌃", with: " control ")
            .replacingOccurrences(of: "⇧", with: " shift ")
            .split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
