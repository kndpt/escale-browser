import CryptoKit
import Foundation
import Testing
@testable import Escale

// Session cookies saved on quit (Jar.swift): only the ones WebKit would lose,
// sealed so the file says nothing without its key, and back only in the
// spaces still there, with the attributes they were set with.

private let site = URL(string: "https://sso.example.test/login")!

private func cookie(_ header: String) -> HTTPCookie {
    HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: site)[0]
}

@Suite struct JarCookies {
    let session = cookie("sess=token-123; Path=/; Secure; HttpOnly; SameSite=Lax")
    let kept = cookie("kept=1; Path=/; Max-Age=3600")

    @Test func keepsOnlySessionCookies() {
        let entries = Jar.entries([session, kept])
        #expect(entries.map { $0["Name"] } == ["sess"])
    }

    @Test func comesBackAsItWasSet() throws {
        let space = UUID()
        let key = SymmetricKey(size: .bits256)
        let box = try #require(Jar.sealed([space.uuidString: Jar.entries([session])], key: key))
        let opened = try #require(Jar.opened(box, key: key))
        let back = try #require(Jar.cookies(opened, in: [space])[space]?.first)
        #expect(back.name == "sess" && back.value == "token-123")
        #expect(back.domain == "sso.example.test" && back.path == "/")
        #expect(back.isSecure && back.isHTTPOnly && back.isSessionOnly)
        #expect(back.sameSitePolicy == .sameSiteLax)
    }

    @Test func sealedSaysNothingWithoutItsKey() throws {
        let box = try #require(Jar.sealed([UUID().uuidString: Jar.entries([session])], key: SymmetricKey(size: .bits256)))
        #expect(box.range(of: Data("token-123".utf8)) == nil)
        #expect(Jar.opened(box, key: SymmetricKey(size: .bits256)) == nil)
    }

    @Test func aDeletedSpaceGetsNothing() {
        let (here, gone) = (UUID(), UUID())
        let entries = Jar.entries([session])
        let found = Jar.cookies([here.uuidString: entries, gone.uuidString: entries, "not-a-space": entries], in: [here])
        #expect(Array(found.keys) == [here])
    }
}
