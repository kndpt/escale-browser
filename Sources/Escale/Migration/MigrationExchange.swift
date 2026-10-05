// Official exports are the common fallback when private profile formats are
// unknown. These readers keep hierarchy and quoted CSV fields without WebKit,
// network access, source writes or a keychain query. The 32 MiB input, 50,000
// records and 32-folder depth caps are explicit rejection limits, not eviction.
import Foundation

struct MigrationExchange: MigrationReader {
    func read(_ source: MigrationSource, categories: Set<MigrationCategory>,
              cancellation: MigrationCancellation) throws -> MigrationValues {
        try cancellation.check()
        let text = try MigrationLimits.text(source.location)
        let result: MigrationValues
        switch source.format {
        case "html" where categories.contains(.bookmarks): result = try Self.html(text)
        case "links" where categories.contains(.bookmarks): result = try Self.links(text)
        case "csv" where categories.contains(.passwords): result = try Self.csv(text)
        default: throw MigrationFailure.unsupported
        }
        try cancellation.check()
        return result
    }

    /// Arc's Copy All Links can be saved as plain text. No Space or folder
    /// structure can be recovered from a list of links, and none is invented.
    static func links(_ text: String) throws -> MigrationValues {
        guard text.utf8.count <= MigrationLimits.bytes else { throw MigrationFailure.tooLarge }
        var nodes: [MigrationBookmark] = [], seen: [String: Int] = [:], skipped = 0
        let markdown = try NSRegularExpression(pattern: #"^[-*]?\s*\[([^\]]*)\]\((https?://[^\s]+)\)$"#)
        for line in text.components(separatedBy: .newlines) {
            var raw = line.trimmingCharacters(in: .whitespaces), title = ""
            if raw.isEmpty { continue }
            guard raw.utf8.count <= MigrationLimits.field else { throw MigrationFailure.tooLarge }
            if let match = markdown.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
               let label = Range(match.range(at: 1), in: raw), let link = Range(match.range(at: 2), in: raw) {
                title = String(raw[label]); raw = String(raw[link])
            }
            guard let url = MigrationLimits.url(raw) else { skipped += 1; continue }
            let occurrence = seen[raw, default: 0]; seen[raw] = occurrence + 1
            nodes.append(MigrationBookmark(id: MigrationLimits.identity(raw, String(occurrence)).uuidString,
                                           title: title.isEmpty ? raw : title, url: url))
            guard nodes.count <= MigrationLimits.records else { throw MigrationFailure.tooLarge }
        }
        guard !nodes.isEmpty else { throw MigrationFailure.unsupported }
        return MigrationValues(bookmarks: nodes, notices: [
            "Links become bookmarks in their listed order. Folders, Spaces, pins, split views and sign-ins are not preserved.",
            "\(skipped) lines without a supported link omitted."
        ])
    }

    static func csv(_ text: String) throws -> MigrationValues {
        guard text.utf8.count <= MigrationLimits.bytes else { throw MigrationFailure.tooLarge }
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, closed = false
        var index = text.startIndex
        func finishField() throws {
            guard row.count < 64 else { throw MigrationFailure.tooLarge }
            row.append(field); field = ""; closed = false
        }
        func finishRow() throws {
            try finishField()
            if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
            row = []
            guard rows.count <= MigrationLimits.records + 1 else { throw MigrationFailure.tooLarge }
        }
        while index < text.endIndex {
            let c = text[index]
            if quoted {
                if c == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" { field.append("\""); index = next }
                    else { quoted = false; closed = true }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"":
                    guard field.isEmpty, !closed else { throw MigrationFailure.malformed }
                    quoted = true
                case ",": try finishField()
                case "\n", "\r", "\r\n": try finishRow()
                default:
                    guard !closed else { throw MigrationFailure.malformed }
                    field.append(c)
                }
            }
            guard field.utf8.count <= MigrationLimits.field else { throw MigrationFailure.tooLarge }
            index = text.index(after: index)
        }
        guard !quoted else { throw MigrationFailure.malformed }
        if !row.isEmpty || !field.isEmpty || closed { try finishRow() }
        guard let first = rows.first else { throw MigrationFailure.malformed }
        let header = first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard Set(header).count == header.count else { throw MigrationFailure.malformed }
        func column(_ names: [String]) -> Int? { header.firstIndex { names.contains($0) } }
        guard let urlAt = column(["url", "website", "login_uri", "site"]),
              let userAt = column(["username", "user", "email", "login_username"]),
              let passwordAt = column(["password", "login_password"]) else { throw MigrationFailure.unsupported }
        let extra = header.indices.filter { ["note", "notes", "otpauth", "totp", "login_totp"].contains(header[$0]) }
        var values = MigrationValues(), skipped = 0, omitted = 0
        for row in rows.dropFirst() {
            guard row.count == header.count else { throw MigrationFailure.malformed }
            guard let url = MigrationLimits.url(row[urlAt]), let host = url.host?.lowercased(),
                  !row[passwordAt].isEmpty else { skipped += 1; continue }
            values.passwords.append(MigrationPassword(host: host.hasPrefix("www.") ? String(host.dropFirst(4)) : host,
                                                       user: row[userAt], password: row[passwordAt]))
            if extra.contains(where: { !row[$0].isEmpty }) { omitted += 1 }
        }
        if skipped > 0 { values.notices.append("\(skipped) invalid password rows omitted.") }
        if omitted > 0 { values.notices.append("Notes or one-time-password fields in \(omitted) rows are not imported.") }
        return values
    }

    static func html(_ text: String) throws -> MigrationValues {
        guard text.utf8.count <= MigrationLimits.bytes else { throw MigrationFailure.tooLarge }
        guard text.range(of: "NETSCAPE-Bookmark-file", options: .caseInsensitive) != nil else {
            throw MigrationFailure.unsupported
        }
        let tokens = try NSRegularExpression(pattern: #"<!--[\s\S]*?-->|<(?:[^>\"']|\"[^\"]*\"|'[^']*')*>|[^<]+"#)
        let attributes = try NSRegularExpression(pattern: #"(?i)\bhref\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#)
        struct Frame { var title: String?; var nodes: [MigrationBookmark] = [] }
        var stack: [Frame] = [], roots: [MigrationBookmark] = []
        var pending: String?, capture: String?, label = "", link: URL?
        var count = 0, skipped = 0, sawList = false
        func append(_ node: MigrationBookmark) throws {
            count += 1
            guard count <= MigrationLimits.records else { throw MigrationFailure.tooLarge }
            guard !stack.isEmpty else { throw MigrationFailure.malformed }
            stack[stack.count - 1].nodes.append(node)
        }
        var failure: Error?
        tokens.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, stop in
            do {
                guard let match, let range = Range(match.range, in: text) else { return }
                let token = String(text[range])
                if token.hasPrefix("<!--") { return }
                guard token.hasPrefix("<") else {
                    if capture != nil { label += token }
                    guard label.utf8.count <= MigrationLimits.field else { throw MigrationFailure.tooLarge }
                    return
                }
                let tag = token.dropFirst().prefix { !$0.isWhitespace && $0 != ">" }.lowercased()
                switch tag {
                case "h3", "a":
                    guard capture == nil else { throw MigrationFailure.malformed }
                    capture = tag; label = ""; link = nil
                    if tag == "a", let attr = attributes.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)) {
                        for i in 1...3 where attr.range(at: i).location != NSNotFound {
                            if let r = Range(attr.range(at: i), in: token) { link = MigrationLimits.url(Self.entities(String(token[r]))) }
                        }
                    }
                case "/h3":
                    guard capture == "h3" else { throw MigrationFailure.malformed }
                    pending = Self.entities(label); capture = nil
                case "/a":
                    guard capture == "a" else { throw MigrationFailure.malformed }
                    if let link { try append(MigrationBookmark(id: "", title: Self.entities(label), url: link)) }
                    else { skipped += 1 }
                    capture = nil
                case "dl":
                    guard stack.count < MigrationLimits.depth, capture == nil else { throw MigrationFailure.tooLarge }
                    if !stack.isEmpty, pending == nil { throw MigrationFailure.malformed }
                    stack.append(Frame(title: pending)); pending = nil; sawList = true
                case "/dl":
                    guard capture == nil, let frame = stack.popLast() else { throw MigrationFailure.malformed }
                    if let title = frame.title { try append(MigrationBookmark(id: "", title: title, children: frame.nodes)) }
                    else {
                        guard stack.isEmpty, roots.isEmpty else { throw MigrationFailure.malformed }
                        roots = frame.nodes
                    }
                default: break
                }
            } catch { failure = error; stop.pointee = true }
        }
        if let failure { throw failure }
        guard sawList, stack.isEmpty, capture == nil, pending == nil else { throw MigrationFailure.malformed }
        // HTML carries no persistent source IDs. A path of names/URLs plus a
        // sibling occurrence preserves legitimate repeats without index shifts.
        func identified(_ nodes: [MigrationBookmark], parent: String) -> [MigrationBookmark] {
            var occurrences: [String: Int] = [:]
            return nodes.map { node in
                let key = node.url?.absoluteString ?? "folder:\(node.title)"
                let occurrence = occurrences[key, default: 0]; occurrences[key] = occurrence + 1
                let id = MigrationLimits.identity(parent, key, String(occurrence)).uuidString
                return MigrationBookmark(id: id, title: node.title, url: node.url,
                                         children: identified(node.children, parent: id))
            }
        }
        return MigrationValues(bookmarks: identified(roots, parent: "html"),
                               notices: skipped > 0 ? ["\(skipped) bookmarks with unsupported URLs omitted."] : [])
    }

    private static func entities(_ text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos|nbsp);"#) else { return text }
        var out = text
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: out), let nameRange = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[nameRange])
            let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
            var value = named[name]
            if name.hasPrefix("#") {
                let hex = name.hasPrefix("#x")
                if let number = UInt32(name.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), let scalar = UnicodeScalar(number) {
                    value = String(scalar)
                }
            }
            if let value { out.replaceSubrange(range, with: value) }
        }
        return out
    }
}
