import Foundation

// The files Escale ships beside its code: for now the JavaScript it injects,
// kept in `.js` files next to the Swift that injects it (`Scripts/` in a
// domain's folder) so it can be read, diffed and checked as JavaScript
// rather than as a Swift string.
//
// SwiftPM gathers them into one bundle, `Escale_Escale.bundle`, declared in
// Package.swift. Its own accessor, `Bundle.module`, stops the app
// (`fatalError`) when that bundle isn't where it looks; a browser missing one
// script should refuse the feature that needs it and say why, not crash. So
// the bundle is looked for here, in the places each way of running puts it:
//
// - the assembled app: `Contents/Resources`, where build.sh copies it, so a
//   copy of the app anywhere carries its scripts with it;
// - `swift build`: beside the executable in `.build/<config>/`;
// - `swift test`: beside the test bundle, in the same folder.
//
// A missing file is an error the caller passes on (an extension that can't
// be prepared says so) and a line in the log. No text is kept here: each
// caller keeps what it read for as long as it needs it (see ExtensionShims).

enum Bundled {
    /// A file the app should have shipped with and doesn't.
    struct Missing: LocalizedError {
        let name: String
        var errorDescription: String? { "Escale is missing a file it ships with (\(name)). Reinstalling Escale should bring it back." }
    }

    /// A packaged asset, without Bundle.module's fatal fallback.
    static func file(_ name: String) -> URL? {
        bundle?.url(forResource: name, withExtension: nil)
    }

    /// The text of a shipped file, by its name (`shim.js`). The file ends
    /// with a newline, as a text file does; that last newline is not part of
    /// the text, as it never was in the Swift string the script came from.
    static func text(_ name: String) throws -> String {
        guard let url = bundle?.url(forResource: name, withExtension: nil),
              var text = try? String(contentsOf: url, encoding: .utf8)
        else {
            NSLog("Escale: %@ is missing from %@", name, bundle?.bundlePath ?? "the app (no Escale_Escale.bundle)")
            throw Missing(name: name)
        }
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    /// A script a feature gives pages, by its name. A missing one is the
    /// empty script, which does nothing: the feature is gone from pages,
    /// with the line `text` writes in the log, and the rest of the browser
    /// goes on. Callers keep it in a `static let`, so it is read once, the
    /// first time a page needs it. A prose header stays in the source file,
    /// not in the page: removing it preserves the original injected bytes.
    static func script(_ name: String) -> String {
        guard let source = try? text(name) else { return "" }
        guard source.hasPrefix("/*\n"),
              let end = source.range(of: "\n*/\n")
        else { return source }
        return String(source[end.upperBound...])
    }

    /// Invokes a shipped function expression with values encoded as JSON.
    /// The caller keeps the shipped source in a `static let`, so a changing
    /// configuration rebuilds only the short value suffix and never rereads
    /// the file. JSON keeps empty strings, quotes and line breaks out of the
    /// JavaScript source itself instead of escaping them by hand.
    static func configured(_ source: String, with values: [String: Any]) -> String {
        guard !source.isEmpty else { return "" }
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else {
            NSLog("Escale: couldn't encode the values for a shipped script")
            return ""
        }
        return "\(source)(\(json));"
    }

    private final class Finder {}

    /// Found once, the first time a file is asked for.
    private static let bundle: Bundle? = {
        let name = "Escale_Escale.bundle"
        let places = [
            Bundle.main.resourceURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
            Bundle(for: Finder.self).bundleURL.deletingLastPathComponent(),
        ]
        return places.lazy.compactMap { $0.flatMap { Bundle(url: $0.appendingPathComponent(name)) } }.first
    }()
}
