// A suggested name comes only from words in an entered HTTP address.
// Host labels and path segments are bounded by punctuation, so a short word
// such as "dev" cannot match "developer". Queries and fragments often carry
// unrelated addresses and are excluded. Conflicting hints yield no suggestion:
// this is only an editable creation suggestion, never a badge or server claim.
import Foundation

enum Environment: Hashable {
    case local, dev(Int?), sit(Int?), uat(Int?), staging, preprod, prod

    static func from(_ url: URL) -> Environment? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.absoluteString.utf8.prefix(4097).count <= 4096,
              let host = url.host(), !host.isEmpty else { return nil }

        var found = Set<Environment>()
        if host == "127.0.0.1" || host == "::1" || host == "[::1]" {
            found.insert(.local)
        }
        for part in (host + "/" + url.path).lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if let hint = matching(String(part)) { found.insert(hint) }
        }
        return found.count == 1 ? found.first : nil
    }

    private static func matching(_ word: String) -> Environment? {
        switch word {
        case "local", "localhost": return .local
        case "staging", "stage": return .staging
        case "preprod": return .preprod
        case "prod": return .prod
        default: break
        }
        for (stem, make) in [
            ("dev", Environment.dev), ("sit", Environment.sit), ("uat", Environment.uat)
        ] {
            if word == stem { return make(nil) }
            guard word.hasPrefix(stem) else { continue }
            let suffix = word.dropFirst(stem.count)
            if suffix.count <= 2, suffix.first != "0", let number = Int(suffix), (1...99).contains(number) {
                return make(number)
            }
        }
        return nil
    }

    var label: String {
        switch self {
        case .local: return "LOCAL"
        case .dev(let n): return "DEV" + (n.map { " \($0)" } ?? "")
        case .sit(let n): return "SIT" + (n.map { " \($0)" } ?? "")
        case .uat(let n): return "UAT" + (n.map { " \($0)" } ?? "")
        case .staging: return "STAGING"
        case .preprod: return "PREPROD"
        case .prod: return "PROD"
        }
    }

}
