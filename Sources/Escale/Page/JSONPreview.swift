// One-line previews of a JSON value, as browsers' consoles draw them:
// `{id: 1, name: "Leanne", tags: […]}` and `(10) [{…}, {…}, …]`. A reader can
// then find a record without opening every level. Pure and bounded: the
// preview stops at a character budget and never walks below one level.
// Used by the API Calls panel's tree (CallsPanel.swift).
import Foundation

extension JSONDocument {
    /// What a piece of a preview is, for its tint.
    enum Tone: Equatable { case plain, key, string, number, literal, null }

    struct Piece: Equatable {
        let text: String
        let tone: Tone
    }

    func tone(_ id: Int) -> Tone {
        switch nodes[id].kind {
        case "string": return .string
        case "number": return .number
        case "boolean": return .literal
        case "null": return .null
        default: return .plain
        }
    }

    var root: Int? { nodes.isEmpty ? nil : 0 }

    /// A value that has no children, as written, cut at `limit` characters.
    func leaf(_ id: Int, limit: Int = 200) -> Piece {
        let text = value(id)
        guard text.count > limit else { return Piece(text: text, tone: tone(id)) }
        let cut = String(text.prefix(max(1, limit - 1))) + "…"
        return Piece(text: nodes[id].kind == "string" ? cut + "\"" : cut, tone: tone(id))
    }

    /// The value in one line: a leaf as written; an object or an array with
    /// its first members, until `budget` characters are used.
    func preview(_ id: Int, budget: Int = 90) -> [Piece] {
        let node = nodes[id]
        guard node.kind == "object" || node.kind == "array" else { return [leaf(id, limit: budget)] }
        let array = node.kind == "array"
        var pieces = [Piece(text: array ? "(\(node.children.count)) [" : "{", tone: .plain)]
        var used = 0
        for (index, child) in node.children.enumerated() {
            let inner = summary(child)
            // Keys are cut too, so no first member can exceed the budget.
            let label = nodes[child].label
            let key = array ? "" : label.count > 30 ? String(label.prefix(29)) + "…" : label
            let cost = key.count + 2 + inner.text.count + 2
            if index > 0 && used + cost > budget {
                pieces.append(Piece(text: ", …", tone: .plain))
                break
            }
            if index > 0 { pieces.append(Piece(text: ", ", tone: .plain)) }
            if !array {
                pieces.append(Piece(text: key, tone: .key))
                pieces.append(Piece(text: ": ", tone: .plain))
            }
            pieces.append(inner)
            used += cost
        }
        pieces.append(Piece(text: array ? "]" : "}", tone: .plain))
        return pieces
    }

    /// A member inside a preview: containers are only named.
    private func summary(_ id: Int) -> Piece {
        switch nodes[id].kind {
        case "object": return Piece(text: nodes[id].children.isEmpty ? "{}" : "{…}", tone: .plain)
        case "array": return Piece(text: nodes[id].children.isEmpty ? "[]" : "[…]", tone: .plain)
        default: return leaf(id, limit: 30)
        }
    }
}
