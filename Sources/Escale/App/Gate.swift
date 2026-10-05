import SwiftUI

// The two moments of an update a person sees: boarding, when a newer build is
// in place and one relaunch away, and arrival, the first launch of that build.
//
// Updater.swift fetches, checks and swaps quietly and never relaunches on its
// own: a page you are reading is not interrupted by a browser that wants to be
// newer. So the update does not ask with a window. It shows behind a door in
// ink among the rail's grey ones, from the first byte: a clock while the build
// arrives, a check once it is in place. The panel behind it (GatePanel.swift)
// says what the build brings, how far the download is, and offers the
// relaunch. A copy that cannot swap itself (a development build, a folder it
// cannot write) gets the same door, offering the disk image instead.
//
// Arrival needs what the new build brings without the network: build.sh puts
// the first paragraph of NOTES.md, the words the appcast carries, into the
// bundle as NOTES.txt. The last build that ran is kept in Store.settings, so a
// build newer than it shows that note once. A first launch shows the welcome
// instead; a profile from before this record counts as coming back. A test run
// shows it only when rehearsing an update against its own feed, so a world
// reopened on a fresh build is not covered by a panel its scenario never
// asked for.

/// Which of the update's panels is open.
enum Gate: Equatable {
    /// A newer build on its way, in place, or offered as a disk image.
    case boarding
    /// The first launch of a build newer than the last one that ran here.
    case arrived(Arrival)
}

/// What a newly arrived build brings, read once at launch.
struct Arrival: Equatable {
    /// The version that ran before, when this profile recorded it.
    let from: String?
    let version: String
    let notes: String

    static let buildKey = "update.lastBuild"
    static let versionKey = "update.lastVersion"

    /// This launch's arrival, if it is one, after recording this build as the
    /// last that ran. `returning` is whether the profile was here before, read
    /// before the welcome can change it.
    @MainActor
    static func take(returning: Bool) -> Arrival? {
        let settings = Store.settings
        let seen = settings.integer(forKey: buildKey)
        let before = settings.string(forKey: versionKey)
        let build = Updater.build
        if build > 0, build != seen {
            settings.set(build, forKey: buildKey)
            settings.set(Updater.version, forKey: versionKey)
        }
        guard due(build: build, seen: seen, returning: returning),
              !Store.testing || Updater.overridden,
              let notes = note
        else { return nil }
        return Arrival(from: before == Updater.version ? nil : before, version: Updater.version, notes: notes)
    }

    /// Whether a build is new to this profile. A development build has no
    /// number to compare. With no build recorded, the profile is either new,
    /// and gets the welcome, or older than this record, and has just updated.
    static func due(build: Int, seen: Int, returning: Bool) -> Bool {
        guard build > 0 else { return false }
        if seen == 0 { return returning }
        return build > seen
    }

    /// The note build.sh put in the bundle; none in a `swift build` binary.
    static var note: String? {
        guard let url = Bundle.main.url(forResource: "NOTES", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Updater.Stage {
    /// The build behind the door: on its way, in place, or offered as a disk image.
    var shown: Updater.Release? {
        switch self {
        case .fetching(let release), .ready(let release), .offered(let release): return release
        case .none: return nil
        }
    }
}

/// The update's door: last in the rail beneath Settings, at the end of the
/// column's tools without the rail, or among the page's doors with the tabs
/// on top. From the moment a build starts to arrive until it is taken.
struct GateDoor: View {
    @ObservedObject var browser: Browser
    @ObservedObject var updater = Updater.shared
    /// The square and its symbol, in compact points (see Door).
    var box: CGFloat = 26
    var glyph: CGFloat = 11
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @State private var hovering = false

    /// A symbol with a badge reads smaller than a plain one at the same size.
    private static let lift: CGFloat = 1.2

    var body: some View {
        Group {
            if let release = updater.stage.shown {
                let name = name(release)
                Button { browser.gate = .boarding } label: {
                    // In ink where the rail's other symbols are grey: the one
                    // door that has something to say.
                    Image(systemName: symbol)
                        .font(.system(size: metrics.length(glyph * Self.lift), weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .frame(width: metrics.length(box), height: metrics.length(box))
                        .background(
                            RoundedRectangle(cornerRadius: metrics.length(8), style: .continuous)
                                .fill(hovering ? Palette.hover : .clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: metrics.length(8), style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(name)
                .accessibilityLabel("Update: \(name)")
                .animation(Motion.quick, value: hovering)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(Motion.settle, value: updater.stage)
    }

    private func name(_ release: Updater.Release) -> String {
        switch updater.stage {
        case .fetching:
            let part = updater.fraction.map { ", \(Int(($0 * 100).rounded())) percent" } ?? ""
            return "Escale \(release.version) is downloading\(part)"
        case .ready: return "Escale \(release.version) is ready"
        case .offered, .none: return "Escale \(release.version) is out"
        }
    }

    /// The download symbol, badged with where the build is: a clock on its
    /// way, a check in place. The badged ones came with macOS 15.1; before
    /// it, a plain symbol that says the same.
    private var symbol: String {
        switch updater.stage {
        case .fetching: return Self.available("square.and.arrow.down.badge.clock", or: "clock")
        case .ready: return Self.available("square.and.arrow.down.badge.checkmark", or: "checkmark.circle")
        case .offered, .none: return "square.and.arrow.down"
        }
    }

    private static func available(_ name: String, or fallback: String) -> String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? fallback : name
    }
}
