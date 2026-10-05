// GitHub credentials are generic keychain passwords, never site Login values.
// The service includes the test world, Space and fixed host; account identity
// is part of the real keychain key. An access/refresh pair is one atomic value.
// A single serial lane orders reads, rotation and deletion off the main thread.
// Tests must use an explicit fixture world or an in-memory store, never Store's
// runtime heuristics inside XCTest.

import Foundation
import Security
import LocalAuthentication

struct GitHubToken: Codable, CustomStringConvertible, CustomDebugStringConvertible {
    let access: String
    let refresh: String?
    let expiresAt: Date?
    let refreshExpiresAt: Date?

    var description: String { "GitHubToken(<redacted>)" }
    var debugDescription: String { description }
    static func validSecret(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4_096 && value.utf8.allSatisfy { (33...126).contains($0) }
    }
    var valid: Bool {
        Self.validSecret(access) && (refresh.map(Self.validSecret) ?? true)
            && (expiresAt?.timeIntervalSince1970.isFinite ?? true)
            && (refreshExpiresAt?.timeIntervalSince1970.isFinite ?? true)
            && ((refresh == nil && refreshExpiresAt == nil) || (refresh != nil && refreshExpiresAt != nil))
    }
}

struct GitHubCredential: Codable, CustomStringConvertible, CustomDebugStringConvertible {
    let clientID: String
    let authority: GitHubAuthority
    let token: GitHubToken
    var description: String { "GitHubCredential(<redacted>)" }
    var debugDescription: String { description }
    var valid: Bool { !clientID.isEmpty && clientID.utf8.count <= 128 && authority.account.valid && token.valid }
}

@MainActor
protocol GitHubCredentialStore {
    func load() async throws -> GitHubCredential?
    func save(_ credential: GitHubCredential) async throws
    func erase() -> Task<Void, Error>
}

@MainActor
final class GitHubSecrets: GitHubCredentialStore {
    private static let queue = DispatchQueue(label: "escale.github.secrets", qos: .utility)
    let service: String

    private init(service: String) { self.service = service }

    static func live(space: UUID) -> GitHubSecrets {
        GitHubSecrets(service: name(world: Store.world, space: space))
    }

    static func fixture(world: UUID, space: UUID) -> GitHubSecrets {
        GitHubSecrets(service: name(world: "github-fixture-\(world.uuidString)", space: space))
    }

    private static func name(world: String?, space: UUID) -> String {
        "com.kndpt.escale.github.\(world.map { "test-" + $0 } ?? "production").\(space.uuidString).github.com"
    }

    private var query: [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrSynchronizable as String: false,
                kSecUseAuthenticationContext as String: context]
    }

    func load() async throws -> GitHubCredential? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                if status == errSecItemNotFound { continuation.resume(returning: nil); return }
                guard status == errSecSuccess, let row = result as? [String: Any],
                      let data = row[kSecValueData as String] as? Data, data.count <= 16_384,
                      let credential = try? JSONDecoder().decode(GitHubCredential.self, from: data), credential.valid,
                      row[kSecAttrAccount as String] as? String == String(credential.authority.account.id) else {
                    continuation.resume(throwing: GitHubFailure.storage); return
                }
                continuation.resume(returning: credential)
            }
        }
    }

    func save(_ credential: GitHubCredential) async throws {
        guard credential.valid else { throw GitHubFailure.storage }
        var query = query
        query[kSecAttrAccount as String] = String(credential.authority.account.id)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.queue.async {
                do {
                    let data = try JSONEncoder().encode(credential)
                    guard data.count <= 16_384 else { throw GitHubFailure.storage }
                    let values = [kSecValueData as String: data]
                    var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
                    if status == errSecItemNotFound {
                        var insertion = query
                        insertion.removeValue(forKey: kSecUseAuthenticationContext as String)
                        insertion[kSecValueData as String] = data
                        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                        status = SecItemAdd(insertion as CFDictionary, nil)
                    }
                    guard status == errSecSuccess else { throw GitHubFailure.storage }
                    continuation.resume()
                } catch { continuation.resume(throwing: GitHubFailure.storage) }
            }
        }
    }

    /// Enqueue synchronously so cancelling a suspended save puts deletion after it,
    /// before any newer authorization can enqueue its own credential.
    func erase() -> Task<Void, Error> {
        let query = query
        let completion = AsyncThrowingStream<Void, Error> { continuation in
            Self.queue.async {
                let status = SecItemDelete(query as CFDictionary)
                if status == errSecSuccess || status == errSecItemNotFound { continuation.finish() }
                else { continuation.finish(throwing: GitHubFailure.storage) }
            }
        }
        return Task { for try await _ in completion {} }
    }
}
