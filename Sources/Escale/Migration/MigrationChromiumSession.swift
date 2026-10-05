// Chromium's SNSS journal stores commands, not a list of URLs. Replaying the
// qualified commands preserves the last selected navigation, tab order, pins
// and closures. Only cleartext versions 1 and 3 are accepted (v3 needs its
// initial-state marker). Version 5 and encrypted directories are refused;
// no source key is requested and an older plaintext file is not a fallback.
// Windows/groups become a flat sleeping row; engine page state is never kept.
import Foundation

enum MigrationChromiumSession {
    static func files(in root: URL) throws -> [String] {
        var names = ["Current Session", "Last Session"].filter { MigrationInput.exists($0, in: root) }
        for directory in ["Sessions", "Sessions_Encrypted"] where MigrationInput.exists(directory, in: root) {
            let children = try FileManager.default.contentsOfDirectory(at: MigrationInput.file(directory, in: root), includingPropertiesForKeys: nil)
            guard children.count <= 2_000 else { throw MigrationFailure.tooLarge }
            names += children.filter { $0.lastPathComponent.hasPrefix("Session_") }.map { directory + "/" + $0.lastPathComponent }
        }
        return names
    }

    static func read(in root: URL, cancellation: MigrationCancellation) throws -> MigrationValues {
        try cancellation.check()
        let candidates = try files(in: root).map { name -> (String, Date) in
            let file = try MigrationInput.file(name, in: root)
            return (name, try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast)
        }.sorted { $0.1 == $1.1 ? $0.0 > $1.0 : $0.1 > $1.1 }
        guard let file = candidates.first?.0 else { throw MigrationFailure.unreadable }
        // Even an old encrypted journal proves that encryption is in use;
        // exposing a stale plaintext session as current would be misleading.
        guard !candidates.contains(where: { $0.0.hasPrefix("Sessions_Encrypted/") }) else { throw MigrationFailure.encryptedSession }
        return try decode(MigrationInput.data(file, in: root, cancellation: cancellation), identity: file, cancellation: cancellation)
    }

    private struct Bytes {
        let data: Data
        var offset = 0
        mutating func int() throws -> Int {
            guard offset + 4 <= data.count else { throw MigrationFailure.malformed }
            let raw = (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[offset + $1]) << (8 * $1)) }
            offset += 4
            return Int(Int32(bitPattern: raw))
        }
        mutating func string(wide: Bool = false, discard: Bool = false) throws -> String {
            let units = try int()
            guard units >= 0, units <= 65_536 else { throw MigrationFailure.malformed }
            let length = units * (wide ? 2 : 1), padded = (length + 3) & ~3
            guard padded <= data.count - offset else { throw MigrationFailure.malformed }
            defer { offset += padded }
            if discard { return "" }
            guard let text = String(data: data.subdata(in: offset..<offset + length), encoding: wide ? .utf16LittleEndian : .utf8) else { throw MigrationFailure.malformed }
            return try MigrationInput.text(text)
        }
        mutating func pickle() throws {
            let length = try int()
            guard length == data.count - 4 else { throw MigrationFailure.malformed }
        }
    }
    private struct TabState {
        var window: Int?
        var position = 0
        var selected = 0
        var pinned = false
        var guid: String?
        var entries: [Int: MigrationTab] = [:]
    }

    static func decode(_ data: Data, identity: String, cancellation: MigrationCancellation) throws -> MigrationValues {
        guard data.count <= MigrationLimits.bytes else { throw MigrationFailure.tooLarge }
        guard data.count >= 8, data.prefix(4) == Data("SNSS".utf8) else { throw MigrationFailure.malformed }
        var header = Bytes(data: data, offset: 4)
        let version = try header.int()
        if [2, 4, 5].contains(version) { throw MigrationFailure.encryptedSession }
        guard [1, 3].contains(version) else { throw MigrationFailure.unsupported }
        var cursor = 8, commands = 0, tabs: [Int: TabState] = [:], marker = version == 1
        var windows = Set<Int>(), omitted = 0, navigations = 0, guidIDs = Set<String>()
        var windowTypes: [Int: Int] = [:]
        while cursor < data.count {
            try cancellation.check()
            commands += 1
            guard commands <= 200_000 else { throw MigrationFailure.tooLarge }
            guard cursor + 3 <= data.count else { throw MigrationFailure.malformed }
            let length = Int(data[cursor]) | (Int(data[cursor + 1]) << 8), command = Int(data[cursor + 2])
            cursor += 2
            guard length >= 1, length <= data.count - cursor else { throw MigrationFailure.malformed }
            var payload = Bytes(data: data.subdata(in: cursor + 1..<cursor + length))
            cursor += length
            switch command {
            case 255:
                guard length == 1 else { throw MigrationFailure.malformed }
                marker = true
            case 0:
                let window = try payload.int(), tab = try payload.int()
                guard window > 0, tab > 0 else { throw MigrationFailure.malformed }
                tabs[tab, default: TabState()].window = window; windows.insert(window)
            case 2, 7, 12:
                let id = try payload.int()
                guard id > 0 else { throw MigrationFailure.malformed }
                let value = try payload.int()
                if command == 2 { guard value >= 0 else { throw MigrationFailure.malformed }; tabs[id, default: TabState()].position = value }
                if command == 7 { tabs[id, default: TabState()].selected = value }
                if command == 12 { tabs[id, default: TabState()].pinned = (value & 255) != 0 }
            case 6:
                try payload.pickle()
                let id = try payload.int(), index = try payload.int()
                guard id > 0, index >= 0 else { throw MigrationFailure.malformed }
                let urlText = try payload.string(), title = try payload.string(wide: true)
                _ = try payload.string(discard: true) // Never retain serialized engine state.
                _ = try payload.int() // Transition type.
                let mask = payload.offset < payload.data.count ? try payload.int() : 0
                navigations += 1
                guard navigations <= MigrationLimits.records else { throw MigrationFailure.tooLarge }
                // A later unsupported navigation must remove the earlier URL
                // at this index, rather than resurrecting it as the current tab.
                if let url = MigrationLimits.url(urlText), mask & 1 == 0 {
                    tabs[id, default: TabState()].entries[index] = MigrationTab(id: "", url: url, title: title)
                } else { tabs[id, default: TabState()].entries.removeValue(forKey: index); omitted += 1 }
            case 9:
                let id = try payload.int(), type = try payload.int()
                guard (0...4).contains(type) else { throw MigrationFailure.unsupported }
                windowTypes[id] = type
            case 16:
                tabs.removeValue(forKey: try payload.int())
            case 17:
                let id = try payload.int(); windows.remove(id)
                tabs = tabs.filter { $0.value.window != id }
            case 5, 11, 24:
                let id = try payload.int(), at = try payload.int()
                guard at >= 0 else { throw MigrationFailure.malformed }
                var state = tabs[id] ?? TabState()
                if command == 5 { state.entries = state.entries.filter { $0.key < at } }
                else {
                    let start = command == 11 ? 0 : at, count = command == 11 ? at : try payload.int()
                    guard count > 0 else { throw MigrationFailure.malformed }
                    let end = start + count
                    state.entries = Dictionary(uniqueKeysWithValues: state.entries.compactMap { index, entry in
                        if index >= start && index < end { return nil }
                        return (index >= end ? index - count : index, entry)
                    })
                    if state.selected >= end { state.selected -= count }
                    else if state.selected >= start { state.selected = start - 1 }
                }
                tabs[id] = state
            case 28:
                try payload.pickle()
                let id = try payload.int(), guid = try payload.string()
                guard id > 0, UUID(uuidString: guid) != nil else { throw MigrationFailure.malformed }
                tabs[id, default: TabState()].guid = guid.lowercased()
            case 1, 8, 10, 13, 14, 15, 18, 19, 20, 21, 22, 23, 25, 26, 27, 29, 30, 31, 32, 33, 34, 35, 36, 37:
                break // Known appearance, grouping, engine or extension metadata.
            default: throw MigrationFailure.unsupported
            }
            guard tabs.count <= 2_000, windows.count <= 200 else { throw MigrationFailure.tooLarge }
        }
        guard marker else { throw MigrationFailure.malformed }
        var values = MigrationValues()
        let ordered = tabs.sorted {
            let lhs = ($0.value.window ?? 0, $0.value.position, $0.key), rhs = ($1.value.window ?? 0, $1.value.position, $1.key)
            return lhs < rhs
        }
        for (id, state) in ordered {
            guard let window = state.window, (windowTypes[window] ?? 0) == 0, windows.contains(window), let entry = state.entries[state.selected] else { omitted += 1; continue }
            let sourceID = state.guid ?? MigrationLimits.identity(identity, String(id)).uuidString
            guard guidIDs.insert(sourceID).inserted else { throw MigrationFailure.malformed }
            values.tabs.append(MigrationTab(id: sourceID, url: entry.url, title: entry.title, pinned: state.pinned))
        }
        values.notices = ["Only cleartext SNSS sessions are supported. Windows are combined; groups, workspaces, split views, extension state, forms and sign-ins are not transferred. Tabs stay asleep.",
                          "Tabs without a persistent source GUID use their journal identity. A new source session file can add those tabs again."]
        if omitted > 0 { values.notices.append("\(omitted) unsupported navigation records or tabs without a current web address omitted.") }
        return values
    }
}
