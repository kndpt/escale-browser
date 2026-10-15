import AppKit
import WebKit

// chrome.downloads, answered by Escale's own downloads.

@available(macOS 15.4, *)
extension ExtensionShims {
    static func downloads(_ asked: Asked) async throws -> Any? {
        let api = asked.api
        let first = asked.first
        let browser = asked.browser
        let context = asked.context
        let owner = asked.owner
        switch api {
        // MARK: downloads
        case "downloads.download":
            guard browser.spaceID == owner.here else { throw Unsupported(what: "Switch to this space to start a download") }
            let spec = first as? [String: Any] ?? [:]
            guard let url = (spec["url"] as? String).flatMap(URL.init(string:)) else { throw Unsupported(what: "No url to download") }
            guard let web = browser.active?.built ?? browser.tabs.lazy.compactMap(\.built).first else {
                throw Unsupported(what: "No page to download through")
            }
            let download = await web.startDownload(using: URLRequest(url: url))
            if let name = spec["filename"] as? String, !name.isEmpty {
                browser.downloads.name(name, for: url)
            }
            browser.keep(download)
            return browser.loot(for: owner.here).kept.count + 1
        case "downloads.search":
            return browser.loot(for: owner.here).kept.enumerated().map { index, keep in
                ["id": index + 1, "url": keep.url.absoluteString, "finalUrl": keep.url.absoluteString,
                 "filename": keep.path, "state": "complete", "exists": keep.stillThere,
                 "startTime": ISO8601DateFormatter().string(from: keep.date), "mime": ""] as [String: Any]
            }
        case "downloads.open", "downloads.show":
            guard let index = first as? Int, browser.loot(for: owner.here).kept.indices.contains(index - 1) else { return nil }
            let keep = browser.loot(for: owner.here).kept[index - 1]
            guard api == "downloads.open" else { browser.loot(for: owner.here).reveal(keep); return nil }
            // Chrome wants a click for this; a call through the bridge carries
            // none, so the person is asked instead.
            guard await owner.ask(open: keep.name, context: context) else {
                throw Unsupported(what: "Opening \u{201C}\(keep.name)\u{201D} wasn't allowed")
            }
            browser.loot(for: owner.here).open(keep)
            return nil
        case "downloads.showDefaultFolder":
            NSWorkspace.shared.open(browser.downloadsFolder(for: owner.here))
            return nil
        case "downloads.erase":
            return []
        case "downloads.pause", "downloads.resume", "downloads.cancel", "downloads.removeFile", "downloads.getFileIcon":
            throw Unsupported(what: "\(api) isn't available in Escale yet")

        default:
            throw unknown(api)
        }
    }
}
