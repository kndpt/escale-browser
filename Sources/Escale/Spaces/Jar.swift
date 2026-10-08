import CryptoKit
import Foundation
import LocalAuthentication
import Security
import WebKit

// Session cookies, kept with the session they belong to.
//
// A sign-in through SSO often lives in a cookie with no expiry, which WebKit
// keeps in memory only: it ended with the process while the tabs it belonged
// to came back signed out. The tabs are the session, so its cookies come back
// too, as in Firefox, Chrome or Arc continuing where they left off.
//
// On quit each space's session cookies are read from its store and sealed in
// a file whose key, new each time, waits in the keychain. At launch they go
// back into the stores before any page may load, and the file and the key are
// deleted: nothing is restored twice, and no token stays on disk while the
// app runs. Private tabs have no store here, a deleted space's are dropped,
// and a crash or a SIGTERM has no quit to save them on, as before.

enum Jar {
    /// Each space's cookies, by its id, as their string properties.
    typealias Kept = [String: [[String: String]]]

    private static var file: URL { Store.file("cookies.sealed") }

    /// The key's keychain item, apart in each test world (fresh.sh wipes it).
    private static var service: String {
        "com.kndpt.escale.cookies.\(Store.world.map { "test-" + $0 } ?? "production")"
    }

    /// Navigation decisions waiting for the cookies to be back; nil when
    /// nothing is being put back.
    @MainActor private static var held: [() -> Void]?

    /// Holds `then` until last session's cookies are back. False when there
    /// is nothing to wait for.
    @MainActor static func hold(_ then: @escaping () -> Void) -> Bool {
        guard held != nil else { return false }
        held?.append(then)
        return true
    }

    // MARK: - quitting

    /// Reads every store's session cookies and seals them, then `done`. A
    /// second at most: a quit doesn't wait on a store that doesn't answer.
    ///
    /// Nothing here waits on the main queue: a quit asked from a block on it
    /// (the updater's relaunch, a bench command) runs AppKit's wait inside
    /// that block, where the queue can't run another, and never ended.
    @MainActor static func keep(_ stores: [UUID: WKWebsiteDataStore], then done: @escaping () -> Void) {
        var kept: Kept = [:]
        var left = stores.count
        var finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            seal(kept)
            done()
        }
        for (space, store) in stores {
            store.httpCookieStore.getAllCookies { cookies in
                let session = entries(cookies)
                if !session.isEmpty { kept[space.uuidString] = session }
                left -= 1
                if left == 0 { finish() }
            }
        }
        RunLoop.main.add(Timer(timeInterval: 1, repeats: false) { _ in finish() }, forMode: .common)
    }

    /// The cookies that end with the process; WebKit keeps the others.
    static func entries(_ cookies: [HTTPCookie]) -> [[String: String]] {
        cookies.filter(\.isSessionOnly).compactMap { cookie in
            cookie.properties.map { properties in
                Dictionary(uniqueKeysWithValues: properties.compactMap { key, value in
                    (value as? String).map { (key.rawValue, $0) }
                })
            }
        }
    }

    private static func seal(_ kept: Kept) {
        guard !kept.isEmpty else { return }
        let key = SymmetricKey(size: .bits256)
        guard let box = sealed(kept, key: key), save(key) else { return }
        do {
            try FileManager.default.createDirectory(at: Store.folder, withIntermediateDirectories: true)
            try box.write(to: file, options: .atomic)
        } catch {
            NSLog("Jar: couldn't save session cookies: %@", String(describing: error))
        }
    }

    static func sealed(_ kept: Kept, key: SymmetricKey) -> Data? {
        guard let plain = try? JSONEncoder().encode(kept) else { return nil }
        return try? AES.GCM.seal(plain, using: key).combined
    }

    // MARK: - launching

    /// Last session's cookies back into the stores of the spaces still there.
    /// Pages wait for them (`hold`), two seconds at most.
    @MainActor static func restore(into spaces: [UUID]) {
        guard let box = try? Data(contentsOf: file) else { return }
        try? FileManager.default.removeItem(at: file)
        guard let key = takeKey(), let kept = opened(box, key: key) else { return }
        let group = DispatchGroup()
        held = []
        for (space, list) in cookies(kept, in: spaces) {
            let store = Spaces.store(for: space).httpCookieStore
            for cookie in list {
                group.enter()
                store.setCookie(cookie) { group.leave() }
            }
        }
        group.notify(queue: .main, execute: release)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { release() }
    }

    @MainActor private static func release() {
        let waiting = held ?? []
        held = nil
        for then in waiting { then() }
    }

    static func opened(_ box: Data, key: SymmetricKey) -> Kept? {
        guard let sealed = try? AES.GCM.SealedBox(combined: box),
              let plain = try? AES.GCM.open(sealed, using: key) else { return nil }
        return try? JSONDecoder().decode(Kept.self, from: plain)
    }

    /// The cookies of the spaces given, and of no other.
    static func cookies(_ kept: Kept, in spaces: [UUID]) -> [UUID: [HTTPCookie]] {
        var found: [UUID: [HTTPCookie]] = [:]
        for (text, list) in kept {
            guard let space = UUID(uuidString: text), spaces.contains(space) else { continue }
            found[space] = list.compactMap { properties in
                HTTPCookie(properties: Dictionary(uniqueKeysWithValues: properties.map {
                    (HTTPCookiePropertyKey($0.key), $0.value as Any)
                }))
            }
        }
        return found
    }

    // MARK: - the key

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrSynchronizable as String: false]
    }

    private static func save(_ key: SymmetricKey) -> Bool {
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { NSLog("Jar: keychain write failed (%d)", status) }
        return status == errSecSuccess
    }

    /// Read once, then gone. Never a prompt: a key the keychain won't hand
    /// over quietly is a session signed out, as it used to be.
    private static func takeKey() -> SymmetricKey? {
        let context = LAContext()
        context.interactionNotAllowed = true
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        read[kSecUseAuthenticationContext as String] = context
        var out: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &out)
        SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess, let data = out as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }
}
