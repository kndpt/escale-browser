// A real keychain regression runs only in an admitted test world, with a
// random host/account/path and exact deferred cleanup. It tests foreign-label
// collisions without querying any existing user's item or returning a secret.
import Foundation
import Security

@MainActor
enum MigrationKeychainBench {
    static func run() -> [String: Any] {
        guard Store.testing, let world = Store.world else { return ["error": "test world required"] }
        let space = UUID(), user = UUID().uuidString
        let host = "migration-\(user.lowercased()).invalid"
        let identity: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host, kSecAttrAccount as String: user,
            kSecAttrPath as String: "/escale-space/\(space.uuidString)",
            kSecAttrLabel as String: "Escale (\(world)) · foreign fixture",
        ]
        var item = identity
        item[kSecValueData as String] = Data("synthetic-existing".utf8)
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { return ["error": "fixture creation failed"] }
        defer { SecItemDelete(identity as CFDictionary) }
        let imported = MigrationPassword(host: host, user: user, password: "synthetic-new")
        let result = Vault.importPassword(imported, space: space)
        var query = identity
        query[kSecReturnData as String] = true
        var data: CFTypeRef?
        let read = SecItemCopyMatching(query as CFDictionary, &data)
        let unchanged = read == errSecSuccess && (data as? Data) == Data("synthetic-existing".utf8)
        return ["foreignCollisionFailed": result == .failed, "foreignItemUnchanged": unchanged]
    }
}
