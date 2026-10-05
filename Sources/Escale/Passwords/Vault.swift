import Foundation
import Security
import LocalAuthentication

// Where passwords live: the macOS keychain, under this app's own name, as
// internet passwords keyed by site and account. Nothing is written to disk by
// this app in any other form, and nothing is ever logged.
//
// This is the same coffer Safari's are in, but not the same drawer: Apple keeps
// Safari's behind an entitlement no other browser gets. So these are
// Escale's — in the system's vault, unlocked with the Mac, shown with Touch ID.

struct Login: Identifiable, Equatable, Hashable {
    var host: String
    var user: String
    var password: String
    /// When it was last used to sign in, if known. Newest first in lists.
    var used: Date?
    /// The space that owns this keychain item; the first keeps its old label.
    var space: UUID = Space.firstID

    var id: String { host + "\u{1}" + user }
}

enum Vault {
    /// What every item of ours is tagged with. A test run tags its own, so a
    /// password saved while trying something never sits among the real ones.
    private static func label(for space: UUID) -> String {
        let root = Store.world.map { "Escale (\($0))" } ?? "Escale"
        return space == Space.firstID ? root : "\(root) · \(space.uuidString)"
    }

    /// Keychain uniqueness for internet passwords includes path, but excludes
    /// label. The first space keeps its historical item identity; other spaces
    /// use a path so the same site/account can exist independently in each.
    private static func scope(_ query: inout [String: Any], space: UUID) {
        if space != Space.firstID { query[kSecAttrPath as String] = "/escale-space/\(space.uuidString)" }
    }

    // MARK: - reading

    /// The keychain will list many items, or hand over one secret — not
    /// both in one call. Asked for every item's data at once it answers
    /// errSecParam, and it did so quietly enough that for a while this app
    /// saved passwords it could never read back. So: the list first, without
    /// secrets, then each secret on its own.

    /// What is kept for a host, exactly.
    static func logins(for host: String, space: UUID = Space.firstID) -> [Login] {
        rows(where: [kSecAttrServer as String: host], space: space).compactMap { login(from: $0, space: space) }
    }

    /// Passwords follow the exact host. Sharing a registrable domain is not a
    /// trust boundary because public and private suffixes can have unrelated
    /// owners, so a sibling host must never receive this host's secret.
    static func logins(matching host: String, space: UUID = Space.firstID) -> [Login] {
        logins(for: host, space: space)
            .filter { credentialHost($0.host, matches: host) }
            .sorted { ($0.used ?? .distantPast) > ($1.used ?? .distantPast) }
    }

    /// Host comparison remains explicit at the credential boundary even when
    /// the keychain query has already narrowed its server attribute.
    static func credentialHost(_ saved: String, matches current: String) -> Bool {
        saved.compare(current, options: .caseInsensitive) == .orderedSame
    }

    /// Everything this app holds, for the list. Read on demand and never kept
    /// in a property.
    static func all(space: UUID = Space.firstID) -> [Login] {
        rows(where: [:], space: space).compactMap { login(from: $0, space: space) }
            .sorted { $0.host == $1.host ? $0.user < $1.user : $0.host < $1.host }
    }

    /// The items' attributes — no secrets — narrowed by whatever is given.
    private static func rows(where extra: [String: Any], space: UUID) -> [[String: Any]] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: label(for: space),
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        scope(&query, space: space)
        extra.forEach { query[$0] = $1 }
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let rows = out as? [[String: Any]] else {
            // Nothing kept reads as "not found"; anything else is worth a
            // line in the log, because the panel will only say "nothing".
            if status != errSecItemNotFound { NSLog("Vault: keychain list failed (%d)", status) }
            return []
        }
        return rows
    }

    /// One item's secret, by the two things that name it.
    private static func secret(host: String, user: String, space: UUID) -> String? {
        var out: CFTypeRef?
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: label(for: space),
            kSecAttrServer as String: host,
            kSecAttrAccount as String: user,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        scope(&query, space: space)
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            if status != errSecItemNotFound { NSLog("Vault: keychain read failed (%d)", status) }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func login(from row: [String: Any], space: UUID) -> Login? {
        guard let host = row[kSecAttrServer as String] as? String,
              let user = row[kSecAttrAccount as String] as? String,
              let password = secret(host: host, user: user, space: space)
        else { return nil }
        // The keychain has no "last used" of its own; it rides in the comment.
        let used = (row[kSecAttrComment as String] as? String)
            .flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        return Login(host: host, user: user, password: password, used: used, space: space)
    }

    // MARK: - writing

    @discardableResult
    static func save(host: String, user: String, password: String, used: Date? = nil, space: UUID = Space.firstID) -> Bool {
        guard !host.isEmpty, !password.isEmpty,
              let data = password.data(using: .utf8)
        else { return false }

        var identity: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: user,
            kSecAttrLabel as String: label(for: space),
        ]
        scope(&identity, space: space)
        var fields: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: label(for: space),
        ]
        if let used { fields[kSecAttrComment as String] = String(used.timeIntervalSince1970) }

        let status = SecItemUpdate(identity as CFDictionary, fields as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }

        var fresh = identity.merging(fields) { _, new in new }
        fresh[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(fresh as CFDictionary, nil) == errSecSuccess
    }

    enum ImportResult { case added, kept, failed }

    /// Add-only is atomic at the keychain boundary: a competing save or an
    /// unreadable existing secret must never become implicit replacement.
    static func importPassword(_ login: MigrationPassword, space: UUID) -> ImportResult {
        guard !login.host.isEmpty, !login.password.isEmpty else { return .failed }
        var item: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: login.host,
            kSecAttrAccount as String: login.user,
            kSecAttrLabel as String: label(for: space),
            kSecValueData as String: Data(login.password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        scope(&item, space: space)
        switch SecItemAdd(item as CFDictionary, nil) {
        case errSecSuccess: return .added
        case errSecDuplicateItem:
            // Internet-password uniqueness excludes label. A foreign item
            // can collide, but our label-filtered reads cannot use it. Check
            // attributes only: do not request or decrypt its secret.
            var owned = item
            owned.removeValue(forKey: kSecValueData as String)
            owned.removeValue(forKey: kSecAttrAccessible as String)
            owned[kSecReturnAttributes as String] = true
            owned[kSecMatchLimit as String] = kSecMatchLimitOne
            return SecItemCopyMatching(owned as CFDictionary, nil) == errSecSuccess ? .kept : .failed
        default: return .failed
        }
    }

    /// It was just used to sign in. Lists put it first from now on.
    static func touch(_ login: Login) {
        save(host: login.host, user: login.user, password: login.password, used: Date(), space: login.space)
    }

    static func forget(host: String, user: String, space: UUID = Space.firstID) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: user,
            kSecAttrLabel as String: label(for: space),
        ]
        scope(&query, space: space)
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - sites that asked not to be asked

    private static func neverKey(_ space: UUID) -> String {
        space == Space.firstID ? "passwords.never" : "passwords.never.\(space.uuidString)"
    }

    static func never(in space: UUID) -> Set<String> {
        Set(Store.settings.stringArray(forKey: neverKey(space)) ?? [])
    }

    static func setNever(_ hosts: Set<String>, in space: UUID) {
        Store.settings.set(Array(hosts).sorted(), forKey: neverKey(space))
    }

    @MainActor
    static var never: Set<String> {
        get { never(in: Spaces.current) }
        set { setNever(newValue, in: Spaces.current) }
    }

    static func never(_ host: String, space: UUID) {
        var hosts = never(in: space)
        hosts.insert(host)
        setNever(hosts, in: space)
    }
    static func isNever(_ host: String, space: UUID) -> Bool {
        let hosts = never(in: space)
        return hosts.contains(host) || hosts.contains(registrable(host))
    }

    static func erase(space: UUID) {
        guard space != Space.firstID else { return }
        SecItemDelete([
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: label(for: space),
        ] as CFDictionary)
        Store.settings.removeObject(forKey: neverKey(space))
    }

    // MARK: - showing one

    /// A password is shown only to the person the Mac belongs to. Touch ID,
    /// the watch, or the account password — whatever the Mac itself takes.
    static func prove(_ reason: String, _ done: @escaping (Bool) -> Void) {
        let context = LAContext()
        var trouble: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &trouble) else {
            // No way to ask at all — a Mac with no password set. Then there is
            // nothing to prove.
            done(true)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { done(ok) }
        }
    }

    // MARK: - the site behind a host

    /// example.com for www.example.com and accounts.example.com; bbc.co.uk
    /// stays bbc.co.uk. The handful of two-part endings that matter here are
    /// listed; a full public suffix list would be a library for a corner.
    static func registrable(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let seconds: Set<String> = ["co", "com", "org", "net", "gov", "gouv", "ac", "edu", "asso", "or", "ne"]
        if seconds.contains(labels[labels.count - 2]), labels[labels.count - 1].count == 2 {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }

    static func host(of text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        if !value.contains("://") { value = "https://" + value }
        guard let host = URL(string: value)?.host()?.lowercased() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

}
