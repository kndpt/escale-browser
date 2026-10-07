import Foundation
import Testing
@testable import Escale

// The JavaScript Escale injects, read from the files it ships rather than
// from Swift strings. `swift test` finds them where
// `swift build` puts them, beside the build; the assembled app is checked by
// the extension scenarios, which need its Contents/Resources.

@Suite struct BundledTests {
    @Test func aShippedScriptIsFoundWithoutItsLastNewline() throws {
        let shim = try Bundled.text("shim.js")
        #expect(shim.hasPrefix("(() => {"))
        #expect(shim.hasSuffix("})();"))
        let chrome = try Bundled.text("user-script-chrome.js")
        #expect(chrome.hasPrefix("  const chrome = (() => {"))
        #expect(chrome.hasSuffix("const browser = chrome;"))
    }

    @Test func aMissingFileIsAnErrorNotACrash() {
        #expect(throws: Bundled.Missing.self) { try Bundled.text("nothing-shipped.js") }
    }

    @Test func configuredValuesAreJSONNotJavaScriptInterpolation() throws {
        let body = "(function (values) { return values; })"
        let values = ["empty": "", "punctuation": "a \\\"quote\\\", a \\\\ slash, and a\nline"]
        let script = Bundled.configured(body, with: values)
        #expect(script.hasPrefix(body + "("))
        #expect(script.hasSuffix(");"))
        let json = String(script.dropFirst(body.count + 1).dropLast(2))
        let data = try #require(json.data(using: .utf8))
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(decoded == values)
    }

    /// A missing page script is the empty script, so a renamed file or a
    /// `Scripts/` folder left out of Package.swift would only show in pages.
    @MainActor
    @Test func everyScriptPagesAreGivenIsFound() {
        var scripts = [
            Veiling.picker, Reader.script, AutoScroll.script, Swipe.calm, Swipe.watch,
            Isolate.on, Isolate.where_, Isolate.toggle, Isolate.off, HoveredLink.script,
            SelectionWatch.script,
            ImageRelay.watch, StoreRelay.script,
            FormRelay.withoutPasskeys, FormRelay.script, MiddleRelay.watch, PageView.selected,
            PasskeyRelay.script, ScrollRelay.script,
            Veiling.style("a[data-value='`$\\\n']"),
            PageView.smart(x: 12, y: 20, scale: 1.5, width: 800), Isolate.skip(-5),
            Bundled.script("favicon-probe.js"),
            Bundled.script("visual-pick.js"), Bundled.script("capture-bounds.js"),
            Bundled.script("json-response.js"), Bundled.script("site-storage.js"),
        ]
        // Extension popups need macOS 15.4, as extensions do.
        if #available(macOS 15.4, *) {
            scripts += [ExtensionPopup.preferred, ExtensionPopup.reach]
        }
        for script in scripts {
            #expect(script.hasPrefix("(") && !script.hasSuffix("\n"))
        }
        #expect(Bundled.script("nothing-shipped.js").isEmpty)
    }
}

// Extensions need macOS 15.4; before it there is no shim to check.
@MainActor
@Suite struct ShimTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("escale-shim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func theShimAnExtensionGetsHasEveryBlankFilledIn() throws {
        guard #available(macOS 15.4, *) else { return }
        let url = try folder()
        defer { try? FileManager.default.removeItem(at: url) }
        try "chrome.tabs.onUpdated.addListener(() => {});".write(to: url.appendingPathComponent("worker.js"), atomically: true, encoding: .utf8)
        let shim = try ExtensionShims.shim(for: url)
        #expect(!shim.contains("__ESCALE_"))
        #expect(shim.contains(#"["tabs.onUpdated"]"#))
        #expect(try ExtensionShims.version.get().count >= 16)
    }

    @Test func onlyTheUserScriptWorldGetsItsOwnChrome() throws {
        guard #available(macOS 15.4, *) else { return }
        let url = try folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let own = try ExtensionShims.userScriptFile(["js": [["code": "run()"]]], in: url)
        let main = try ExtensionShims.userScriptFile(["js": [["code": "run()"]], "world": "MAIN"], in: url)
        let ownText = try String(contentsOf: url.appendingPathComponent(own), encoding: .utf8)
        let mainText = try String(contentsOf: url.appendingPathComponent(main), encoding: .utf8)
        #expect(ownText.contains(try Bundled.text("user-script-chrome.js")))
        #expect(!mainText.contains("const chrome"))
        #expect(ownText.contains("run()") && mainText.contains("run()"))
    }

    @Test func userScriptGlobsAndCodeKeepTheirOwnValues() throws {
        guard #available(macOS 15.4, *) else { return }
        let url = try folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = "window.marker = '__ESCALE_INCLUDE__\\n\\\"';"
        let file = try ExtensionShims.userScriptFile([
            "world": "MAIN", "js": [["code": source]],
            "includeGlobs": ["https://example.com/a?b=\"quoted\""], "excludeGlobs": [],
        ], in: url)
        let text = try String(contentsOf: url.appendingPathComponent(file), encoding: .utf8)
        #expect(text.contains(source))
        let start = try #require(text.range(of: "const __escaleIn = "))
        let end = try #require(text.range(of: ", __escaleOut", range: start.upperBound..<text.endIndex))
        let json = String(text[start.upperBound..<end.lowerBound])
        let globs = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String])
        #expect(globs == ["https://example.com/a?b=\"quoted\""])
        #expect(!text.contains("__ESCALE_CODE__"))
    }

    @Test func userScriptFilesStayInTheirPackage() throws {
        guard #available(macOS 15.4, *) else { return }
        let outer = try folder()
        defer { try? FileManager.default.removeItem(at: outer) }
        let url = outer.appendingPathComponent("extension")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let secret = outer.appendingPathComponent("secret.txt")
        try "outside-canary".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("link.js"), withDestinationURL: secret)
        try "inside-canary".write(to: url.appendingPathComponent("own.js"), atomically: true, encoding: .utf8)
        let file = try ExtensionShims.userScriptFile(["world": "MAIN", "js": [
            ["file": "../secret.txt"], ["file": secret.path], ["file": "link.js"], ["file": "/own.js"],
        ]], in: url)
        let text = try String(contentsOf: url.appendingPathComponent(file), encoding: .utf8)
        #expect(!text.contains("outside-canary"))
        #expect(text.contains("inside-canary"))
    }
}
