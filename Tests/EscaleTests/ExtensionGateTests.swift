// Which permissions a call through the extension bridge needs. The gate is
// the native side's: the shim runs beside the extension's own code, so only
// what is checked here stops an extension that skips its own wrapper.
import Testing
@testable import Escale

@Suite struct ExtensionGateTests {
    @Test func openingADownloadNeedsItsOwnPermission() {
        guard #available(macOS 15.4, *) else { return }
        #expect(ExtensionShims.needs("downloads.open") == ["downloads", "downloads.open"])
        #expect(ExtensionShims.needs("downloads.search") == ["downloads"])
        #expect(ExtensionShims.needs("downloads.show") == ["downloads"])
    }

    @Test func familiesWebKitOwnsNeedNothingHere() {
        guard #available(macOS 15.4, *) else { return }
        #expect(ExtensionShims.needs("history.search") == ["history"])
        #expect(ExtensionShims.needs("tabGroups.get").isEmpty)
    }
}
