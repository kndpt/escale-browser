import AppKit
import WebKit

// chrome.history, sessions, topSites, readingList and browsingData,
// answered from what Escale and WebKit keep for the Space.

@available(macOS 15.4, *)
extension ExtensionShims {
    static func history(_ asked: Asked) async throws -> Any? {
        let api = asked.api
        let args = asked.args
        let first = asked.first
        let browser = asked.browser
        let owner = asked.owner
        switch api {
        // MARK: history
        case "history.search":
            let spec = first as? [String: Any] ?? [:]
            let text = spec["text"] as? String ?? ""
            let start = (spec["startTime"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                ?? Date().addingTimeInterval(-24 * 3600)
            let end = (spec["endTime"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantFuture
            let limit = spec["maxResults"] as? Int ?? 100
            return browser.history(for: owner.here).everything(matching: text)
                .filter { $0.last >= start && $0.last <= end }
                .sorted { $0.last > $1.last }
                .prefix(limit)
                .map(visit)
        case "history.getVisits":
            let url = (first as? [String: Any])?["url"] as? String ?? ""
            return browser.history(for: owner.here).everything().filter { $0.url.absoluteString == url }.map { trace in
                ["id": trace.key, "visitId": "1", "visitTime": trace.last.timeIntervalSince1970 * 1000,
                 "referringVisitId": "0", "transition": "link"]
            }
        case "history.addUrl":
            if let url = ((first as? [String: Any])?["url"] as? String).flatMap(URL.init(string:)) {
                browser.history(for: owner.here).record(url, title: "")
            }
            return nil
        case "history.deleteUrl":
            let url = (first as? [String: Any])?["url"] as? String ?? ""
            for trace in browser.history(for: owner.here).everything() where trace.url.absoluteString == url {
                browser.history(for: owner.here).forget(trace.key)
            }
            if let address = URL(string: url) { browser.localhost.forget(url: address, in: owner.here) }
            return nil
        case "history.deleteRange":
            let spec = first as? [String: Any] ?? [:]
            let start = Date(timeIntervalSince1970: (spec["startTime"] as? Double ?? 0) / 1000)
            let end = Date(timeIntervalSince1970: (spec["endTime"] as? Double ?? 0) / 1000)
            for trace in browser.history(for: owner.here).everything() where trace.last >= start && trace.last <= end {
                browser.history(for: owner.here).forget(trace.key)
            }
            browser.localhost.forget(from: start, through: end, in: owner.here)
            return nil
        case "history.deleteAll":
            browser.history(for: owner.here).forget()
            browser.localhost.forget(space: owner.here)
            return nil

        // MARK: browsing data
        case "browsingData.settings":
            return ["options": ["since": 0], "dataToRemove": [:], "dataRemovalPermitted": [
                "cache": true, "cookies": true, "history": true, "downloads": true, "localStorage": true,
                "indexedDB": true, "serviceWorkers": true, "cacheStorage": true, "fileSystems": true, "webSQL": true,
            ]]
        case let api where api.hasPrefix("browsingData."):
            let options = first as? [String: Any] ?? [:]
            let what: [String: Bool]
            if api == "browsingData.remove" {
                what = (args.dropFirst().first as? [String: Any] ?? [:]).compactMapValues { $0 as? Bool }
            } else {
                let key = String(api.dropFirst("browsingData.remove".count))
                what = [key.prefix(1).lowercased() + key.dropFirst(): true]
            }
            try await clear(what, options: options, browser: browser, owner: owner)
            return nil

        // MARK: sessions — the tabs you closed
        case "sessions.getRecentlyClosed":
            let limit = (first as? [String: Any])?["maxResults"] as? Int ?? 25
            return browser.ghosts(in: owner.here).reversed().prefix(limit).map { ghost in
                ["lastModified": Int(Date().timeIntervalSince1970),
                 "tab": ["sessionId": ghost.id.uuidString, "url": ghost.url.absoluteString, "title": ghost.title,
                         "index": ghost.index, "windowId": 1, "active": false, "pinned": false, "highlighted": false,
                         "incognito": false, "selected": false, "discarded": false, "autoDiscardable": true, "groupId": -1]] as [String: Any]
            }
        case "sessions.getDevices":
            return []
        case "sessions.restore":
            guard browser.spaceID == owner.here else { throw Unsupported(what: "This space is parked") }
            let ghost = (first as? String).flatMap { key in browser.ghosts(in: owner.here).first { $0.id.uuidString == key } } ?? browser.ghosts(in: owner.here).last
            guard let ghost else { throw Unsupported(what: "Nothing to restore") }
            browser.reopen(ghost)
            return ["lastModified": Int(Date().timeIntervalSince1970),
                    "tab": ["url": ghost.url.absoluteString, "title": ghost.title, "index": ghost.index, "windowId": 1]]

        // MARK: top sites — the most visited in history
        case "topSites.get":
            var visits: [String: (url: URL, title: String, count: Int)] = [:]
            for trace in browser.history(for: owner.here).everything() {
                guard let host = trace.url.host() else { continue }
                visits[host, default: (trace.url, trace.title, 0)].count += 1
            }
            return visits.values.sorted { $0.count > $1.count }.prefix(10).map {
                ["url": $0.url.absoluteString, "title": $0.title]
            }

        // MARK: reading list — none kept
        case "readingList.query":
            return []
        case "readingList.addEntry", "readingList.removeEntry", "readingList.updateEntry":
            throw Unsupported(what: "Escale has no reading list")

        default:
            throw unknown(api)
        }
    }

    /// chrome.browsingData, from what WebKit and Escale keep.
    static func clear(_ what: [String: Bool], options: [String: Any], browser: Browser, owner: Extensions) async throws {
        let since = Date(timeIntervalSince1970: (options["since"] as? Double ?? 0) / 1000)
        let origins = (options["origins"] as? [String])?.compactMap { URL(string: $0)?.host() }
        var types = Set<String>()
        let map: [String: [String]] = [
            "cache": [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache],
            "cacheStorage": [WKWebsiteDataTypeFetchCache], "appcache": [WKWebsiteDataTypeOfflineWebApplicationCache],
            "cookies": [WKWebsiteDataTypeCookies], "localStorage": [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage],
            "indexedDB": [WKWebsiteDataTypeIndexedDBDatabases], "serviceWorkers": [WKWebsiteDataTypeServiceWorkerRegistrations],
            "webSQL": [WKWebsiteDataTypeWebSQLDatabases], "fileSystems": [WKWebsiteDataTypeFileSystem],
        ]
        for (key, on) in what where on { types.formUnion(map[key] ?? []) }
        let store = Spaces.store(for: owner.here)
        if !types.isEmpty {
            if let origins {
                let records = await store.dataRecords(ofTypes: types)
                let hit = records.filter { record in origins.contains { $0 == record.displayName || $0.hasSuffix("." + record.displayName) } }
                await store.removeData(ofTypes: types, for: hit)
            } else {
                await store.removeData(ofTypes: types, modifiedSince: since)
            }
        }
        if what["history"] == true, origins == nil {
            for trace in browser.history(for: owner.here).everything() where trace.last >= since { browser.history(for: owner.here).forget(trace.key) }
            browser.localhost.forget(from: since, in: owner.here)
        }
    }

    static func visit(_ trace: History.Trace) -> [String: Any] {
        ["id": trace.key, "url": trace.url.absoluteString, "title": trace.title,
         "lastVisitTime": trace.last.timeIntervalSince1970 * 1000, "visitCount": trace.count, "typedCount": 0]
    }
}
