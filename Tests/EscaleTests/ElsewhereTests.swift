// What Open Page In lists, from a synthetic answer of LaunchServices: every
// copy of Escale left out, each other browser once, and only web addresses.
import Foundation
import Testing
@testable import Escale

@Suite struct ElsewhereTests {
    private func app(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func leavesEscaleOutAndKeepsEachBrowserOnce() {
        let apps: [(app: URL, id: String?)] = [
            (app("/Applications/Safari.app"), "com.apple.Safari"),
            (app("/Applications/Escale.app"), "com.kndpt.escale"),
            (app("/tmp/probe/qa/Escale.app"), "com.kndpt.escale.probe.qa"),
            (app("/tmp/test/Escale.app"), "COM.KNDPT.ESCALE.TEST"),
            (app("/Applications/Google Chrome.app"), "com.google.Chrome"),
            (app("/Users/me/Applications/Google Chrome.app"), "com.google.chrome"),
            (app("/Applications/Arc.app"), "company.thebrowser.Browser"),
            (app("/Applications/Nameless.app"), nil),
            (app("/Applications/Other.app"), "org.other.browser"),
        ]
        let picked = Elsewhere.pick(apps, own: "org.other.browser")
        #expect(picked.map(\.name) == ["Arc", "Google Chrome", "Safari"])
        #expect(picked.first { $0.name == "Google Chrome" }?.app.path == "/Applications/Google Chrome.app")
    }

    @Test func aLookalikeIsNotEscale() {
        #expect(!Elsewhere.isEscale("com.kndpt.escalefork", own: nil))
        #expect(Elsewhere.isEscale("com.kndpt.escale.probe.qa-34", own: nil))
        #expect(Elsewhere.pick([(app("/Applications/Escale.app"), "com.kndpt.escale")], own: "com.kndpt.escale").isEmpty)
    }

    @Test func onlyWebAddresses() throws {
        for text in ["https://example.com/a?b#c", "http://localhost:3000", "HTTPS://example.com"] {
            #expect(Elsewhere.opens(try #require(URL(string: text))))
        }
        for text in ["file:///tmp/a.html", "about:blank", "data:text/html,x", "javascript:alert(1)", "mailto:a@b.c"] {
            #expect(!Elsewhere.opens(try #require(URL(string: text))))
        }
        #expect(!Elsewhere.opens(nil))
    }
}
