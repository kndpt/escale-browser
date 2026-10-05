import Foundation
import WebKit

// Taking things off a page and keeping them off.
//
// Point at a cookie bar, a newsletter overlay, a sidebar of related nonsense —
// it goes, and it is still gone next time. Everything is remembered by site, as
// a list of selectors, and put back on by a stylesheet injected before the page
// has drawn a single frame, so nothing is ever seen appearing and vanishing.

struct Veil: Codable, Identifiable, Equatable {
    var selector: String
    /// What it was, in words, so the list of what you have hidden reads like
    /// something rather than like a stylesheet.
    var label: String
    /// How big it was and where it sat — measured when you hid it, because a
    /// hidden thing has no size to measure later. Two elements can easily read
    /// the same; they rarely have the same shape in the same corner.
    var note: String?
    var date: Date

    var id: String { selector }
}

@MainActor
final class Curtain: ObservableObject {
    @Published private(set) var byHost: [String: [Veil]] = [:]
    private var saving = false
    private let file: URL

    init(space: UUID = Space.firstID) {
        file = Curtain.file(for: space)
        load()
    }

    func host(of url: URL?) -> String? {
        guard let host = url?.host()?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func veils(on host: String?) -> [Veil] {
        guard let host else { return [] }
        return byHost[host] ?? []
    }

    func hide(_ selector: String, label: String, note: String, on host: String) {
        var list = byHost[host] ?? []
        guard !list.contains(where: { $0.selector == selector }) else { return }
        list.append(Veil(selector: selector, label: label, note: note, date: Date()))
        byHost[host] = list
        save()
    }

    /// Put one back.
    func restore(_ veil: Veil, on host: String) {
        byHost[host] = (byHost[host] ?? []).filter { $0.selector != veil.selector }
        if byHost[host]?.isEmpty == true { byHost[host] = nil }
        save()
    }

    /// Put the last one back — ⌘Z, while you are still pointing at things.
    @discardableResult
    func undo(on host: String) -> Veil? {
        guard var list = byHost[host], let last = list.popLast() else { return nil }
        byHost[host] = list.isEmpty ? nil : list
        save()
        return last
    }

    func restoreAll(on host: String) {
        byHost[host] = nil
        save()
    }

    /// The stylesheet for a site. Each selector stands alone in its own rule:
    /// one selector the browser can't parse would otherwise take the whole
    /// list down with it.
    /// One selector may be left out — that is how a row in the list shows you
    /// what it is offering to bring back, without bringing it back.
    func css(on host: String?, without spared: String? = nil) -> String {
        veils(on: host)
            .filter { $0.selector != spared }
            .map { "\($0.selector) { display: none !important; }" }
            .joined(separator: "\n")
    }

    // MARK: - the file

    private static func file(for space: UUID) -> URL {
        Store.file(space == Space.firstID ? "hidden.json" : "hidden-\(space.uuidString).json")
    }

    static func copy(_ values: [String: [Veil]], to space: UUID) -> Bool {
        let writer = Writer.to(file(for: space))
        writer.save(values)
        writer.flush()
        return writer.failure == nil
    }

    static func erase(space: UUID) {
        guard space != Space.firstID else { return }
        Writer.to(file(for: space)).remove()
    }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode([String: [Veil]].self, from: data)
        else { return }
        byHost = stored
    }

    /// A moment's changes, written once and in the order they came (see
    /// Writer.swift).
    private func save() {
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.hand()
        }
    }

    /// What the moment above is waiting out, handed to the writer now.
    private func hand() {
        guard saving else { return }
        saving = false
        Writer.to(file).save(byHost)
    }

    /// Quitting doesn't wait out the moment: whatever was hidden last is
    /// written before this returns (see Browser.flush).
    func flush() {
        hand()
        Writer.to(file).flush()
    }
}

/// Carries a chosen element back from the page.
final class VeilRelay: NSObject, WKScriptMessageHandler {
    static let name = "escaleVeil"

    weak var tab: Tab?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated {
            if let trouble = body["trouble"] as? String {
                tab?.pickingFailed(trouble)
            } else if body["off"] as? Bool == true {
                tab?.pickingEnded()
            } else if let selector = body["selector"] as? String {
                tab?.picked(
                    selector: selector,
                    label: body["label"] as? String ?? selector,
                    note: body["note"] as? String ?? ""
                )
            }
        }
    }
}

enum Veiling {
    /// A stylesheet put in before the document has a body, so nothing is ever
    /// seen arriving and then leaving.
    // (see Blocking/Scripts/veil-style.js)
    private static let stylesheet = Bundled.script("veil-style.js")
    static func style(_ css: String) -> String {
        Bundled.configured(stylesheet, with: ["css": css])
    }

    /// The pointing mode. Loaded on every page but asleep: it costs one closure
    /// and a few functions until somebody actually asks for it.
    static let picker = Bundled.script("veil-picker.js")
}
