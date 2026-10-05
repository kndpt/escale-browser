import Testing
@testable import Escale

// Which relying party a page may name. A domain above the page's host
// is allowed only while it is not a public suffix, and the test for that is
// CFNetwork's private `_CFHostIsDomainTopLevel` (Passkeys.publicSuffix).
// Where this macOS lacks the symbol, a page's own host is the only relying
// party it gets: `aParentSiteFits` then fails, which is how a new macOS
// taking the symbol away shows up here before it shows up on a sign-in page.
// docs/COMPATIBILITY.md asks for ./test.sh, and so this, on every new macOS.

@MainActor
@Suite struct RelyingPartyTests {
    @Test func thePagesOwnHostFits() {
        #expect(Passkeys.fits("example.com", "example.com"))
        #expect(Passkeys.fits("localhost", "localhost"))
    }

    @Test(arguments: [("example.com", "login.example.com"), ("example.co.uk", "id.example.co.uk")])
    func aParentSiteFits(rp: String, host: String) {
        #expect(Passkeys.fits(rp, host))
    }

    @Test(arguments: [("co.uk", "example.co.uk"), ("github.io", "me.github.io"), ("com", "example.com")])
    func aPublicSuffixNeverFits(rp: String, host: String) {
        #expect(!Passkeys.fits(rp, host))
    }

    @Test(arguments: [("other.com", "example.com"), ("ample.com", "example.com"), ("login.example.com", "example.com")])
    func anotherSiteNeverFits(rp: String, host: String) {
        #expect(!Passkeys.fits(rp, host))
    }

    @Test(arguments: [("0.1", "10.0.0.1"), ("1", "::1")])
    func anAddressHasNoParent(rp: String, host: String) {
        #expect(!Passkeys.fits(rp, host))
    }
}
