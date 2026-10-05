// A routing draft belongs to the window, not to the Settings view: fetching
// a link from a tab must not destroy unfinished work. Only Save or Discard
// settles it. It holds at most the rule limit, never a page or an observer;
// raw addresses and explicit scope choices last until the draft is settled.
import Foundation
import Combine

@MainActor
final class LinkDraft: ObservableObject {
    @Published var rules: [LinkRule]
    @Published var editing: UUID?
    @Published var trial = ""
    @Published var saved = false
    @Published private(set) var request = 0
    @Published private var addresses: [UUID: String] = [:]
    private var chosenScopes: Set<UUID> = []

    init(rules: [LinkRule]) { self.rules = rules }

    func changed(from stored: [LinkRule]) -> Bool {
        rules != stored || rules.contains { rule in
            addresses[rule.id].map { $0 != LinkAddress.text(for: rule) } ?? false
        }
    }

    func address(for rule: LinkRule) -> String { addresses[rule.id] ?? LinkAddress.text(for: rule) }

    func enter(_ text: String, for id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        // An existing rule keeps its scope; a new rule follows the address
        // until the person explicitly chooses a scope.
        if addresses[id] == nil, !rules[index].blank { chosenScopes.insert(id) }
        addresses[id] = text
        rules[index] = LinkAddress.rule(text, basedOn: rules[index], infer: !chosenScopes.contains(id))
        saved = false
    }

    func scope(_ scope: LinkRule.Scope, for id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        let text = address(for: rules[index])
        chosenScopes.insert(id)
        rules[index].scope = scope
        rules[index] = LinkAddress.rule(text, basedOn: rules[index], infer: false)
        saved = false
    }

    @discardableResult
    func add(destination: UUID, address: String = "") -> Bool {
        guard rules.count < LinkRule.limit else { return false }
        var rule = LinkRule(destination: destination)
        rule = LinkAddress.rule(address, basedOn: rule, infer: true)
        rules.append(rule)
        addresses[rule.id] = address
        editing = rule.id
        saved = false
        request += 1
        return true
    }

    func remove(_ id: UUID) {
        rules.removeAll { $0.id == id }
        addresses[id] = nil
        chosenScopes.remove(id)
        if editing == id { editing = nil }
        saved = false
    }

    func reset(to stored: [LinkRule]) {
        rules = stored
        addresses = [:]
        chosenScopes = []
        editing = nil
        saved = false
    }

    func follow(_ old: [LinkRule], with new: [LinkRule]) {
        if !changed(from: old) { reset(to: new) }
    }

    func error(spaces: Set<UUID>) -> String? {
        for (index, rule) in rules.enumerated() {
            if let error = LinkAddress.error(address(for: rule)) ?? rule.error {
                return "Rule \(index + 1): \(error)"
            }
            if !spaces.contains(rule.destination) {
                return "Rule \(index + 1): choose an existing Space."
            }
        }
        return LinkRule.validation(rules)
    }
}
