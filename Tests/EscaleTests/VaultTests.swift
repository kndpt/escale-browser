// Credential host tests keep password lookup on an origin boundary without
// reading or writing the macOS keychain, including shared-hosting suffixes.

import Testing
@testable import Escale

@Test func credentialHostsDoNotCrossTenantBoundaries() {
    #expect(Vault.credentialHost("alice.github.io", matches: "alice.github.io"))
    #expect(Vault.credentialHost("ALICE.github.io", matches: "alice.github.io"))
    #expect(!Vault.credentialHost("alice.github.io", matches: "evil.github.io"))
    #expect(!Vault.credentialHost("alice.appspot.com", matches: "evil.appspot.com"))
    #expect(!Vault.credentialHost("alice.pages.dev", matches: "evil.pages.dev"))
    #expect(!Vault.credentialHost("alice.vercel.app", matches: "evil.vercel.app"))
    #expect(!Vault.credentialHost("127.0.0.1", matches: "127.0.0.2"))
}
