// The bench can edit the same value snapshot as Settings and inspect its
// winning rule. Test worlds only: no hidden page, alternate routing algorithm
// or per-scenario assertions live in the application.
import Foundation

@MainActor
enum LinkRoutesBench {
    static func run(_ request: [String: Any], browser: Browser) -> [String: Any] {
        guard Store.testing else { return ["error": "routes only works in a test world"] }
        if let text = request["rules"] as? String {
            guard let data = text.data(using: .utf8),
                  let rules = try? JSONDecoder().decode([LinkRule].self, from: data),
                  browser.linkRoutes.save(rules, spaces: Set(browser.spaces.map(\.id))) else {
                return ["error": browser.linkRoutes.problem ?? "Invalid rules"]
            }
        }
        var result: [String: Any] = [:]
        if let data = try? JSONEncoder().encode(browser.linkRoutes.rules),
           let rules = try? JSONSerialization.jsonObject(with: data) { result["rules"] = rules }
        if let text = request["url"] as? String, let url = URL(string: text) {
            let winner = LinkRule.winner(in: browser.linkRoutes.rules, for: url, spaces: Set(browser.spaces.map(\.id)))
            result["winner"] = winner?.id.uuidString ?? ""
            result["destination"] = winner?.destination.uuidString ?? ""
        }
        let draft = browser.linkRoutes.draft
        if let data = try? JSONEncoder().encode(draft.rules),
           let rules = try? JSONSerialization.jsonObject(with: data) { result["draft"] = rules }
        result["editing"] = draft.editing?.uuidString ?? ""
        result["addresses"] = draft.rules.map { draft.address(for: $0) }
        result["trial"] = draft.trial
        result["changed"] = draft.changed(from: browser.linkRoutes.rules)
        result["draftError"] = draft.error(spaces: Set(browser.spaces.map(\.id))) ?? ""
        result["problem"] = browser.linkRoutes.problem ?? ""
        return result
    }
}
