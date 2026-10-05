import Foundation

// The update's door and panels, from the shell, in a test world only. A
// development build has no Team ID, so the updater never reaches `ready`
// there on its own: `ready`, `offered` and `fetching` (with a `fraction`)
// stand the stage there by hand, with a made-up release, for the door and the
// panel to be looked at and pressed.
// `forget` makes the next launch an arrival, which a test run shows only with
// ESCALE_FEED set (Gate.swift); `relaunch` goes through the updater's own
// relaunch, after the answer has left.

@MainActor
enum UpdateBench {
    static func run(_ request: [String: Any], browser: Browser) -> [String: Any] {
        guard Store.testing else { return ["error": "update needs a test world"] }
        let version = request["version"] as? String ?? "9.9"
        let notes = request["notes"] as? String
        switch request["action"] as? String ?? "state" {
        case "ready", "offered", "fetching":
            guard let archive = URL(string: "https://example.invalid/Escale.zip"),
                  let dmg = URL(string: "https://example.invalid/Escale.dmg")
            else { return ["error": "no address"] }
            let release = Updater.Release(
                version: version, build: Updater.build + 1, archive: archive, dmg: dmg,
                sha256: nil, notes: notes, minimumSystemVersion: nil
            )
            switch request["action"] as? String {
            case "ready": Updater.shared.rehearse(.ready(release))
            case "offered": Updater.shared.rehearse(.offered(release))
            default: Updater.shared.rehearse(.fetching(release), fraction: request["fraction"] as? Double)
            }
        case "none":
            Updater.shared.rehearse(.none)
        case "open":
            browser.gate = .boarding
        case "arrival":
            browser.gate = .arrived(Arrival(from: request["from"] as? String, version: version,
                                            notes: notes ?? Arrival.note ?? "What this build brings."))
        case "close":
            browser.gate = nil
        case "forget":
            Store.settings.set(1, forKey: Arrival.buildKey)
        case "relaunch":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Updater.shared.relaunch() }
        case "state":
            break
        default:
            return ["error": "update takes ready|offered|fetching|none|open|arrival|close|forget|relaunch|state"]
        }
        return state(browser)
    }

    private static func state(_ browser: Browser) -> [String: Any] {
        let gate: String
        switch browser.gate {
        case .none: gate = ""
        case .boarding: gate = "boarding"
        case .arrived: gate = "arrived"
        }
        let stage: String
        switch Updater.shared.stage {
        case .none: stage = "none"
        case .fetching: stage = "fetching"
        case .ready: stage = "ready"
        case .offered: stage = "offered"
        }
        return [
            "stage": stage,
            "door": Updater.shared.stage.shown != nil,
            "fraction": Updater.shared.fraction as Any? ?? NSNull(),
            "gate": gate,
            "version": Updater.version,
            "build": Updater.build,
            "lastBuild": Store.settings.integer(forKey: Arrival.buildKey),
            "note": Arrival.note != nil,
            "tabs": browser.tabs.count,
        ]
    }
}
