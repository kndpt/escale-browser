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

    @Test func whatChromeGatesIsGatedHereToo() {
        guard #available(macOS 15.4, *) else { return }
        for family in ["notifications", "idle", "power", "identity", "offscreen", "tts", "search", "fontSettings", "sidePanel"] {
            #expect(ExtensionShims.needs(family + ".anything") == [family])
        }
        #expect(ExtensionShims.needs("system.cpu.getInfo") == ["system.cpu"])
        #expect(ExtensionShims.needs("system.display.getInfo") == ["system.display"])
        #expect(ExtensionShims.needs("management.getAll") == ["management"])
        #expect(ExtensionShims.needs("management.getSelf").isEmpty)
        #expect(ExtensionShims.needs("i18n.detectLanguage").isEmpty)
        #expect(ExtensionShims.needs("runtime.getContexts").isEmpty)
        #expect(ExtensionShims.needs("background.wake").isEmpty)
    }

    @Test func settingsNeedTheirFamily() {
        guard #available(macOS 15.4, *) else { return }
        #expect(ExtensionShims.needs("setting.set:privacy.services.passwordSavingEnabled") == ["privacy"])
        #expect(ExtensionShims.needs("setting.get:proxy.settings") == ["proxy"])
    }

    @Test func onlyOptionalPermissionsAreGrantedAtRunTime() {
        guard #available(macOS 15.4, *) else { return }
        let manifest: [String: Any] = ["permissions": ["storage"], "optional_permissions": ["history", "idle"]]
        #expect(ExtensionShims.requestable(["history", "idle"], manifest: manifest))
        #expect(!ExtensionShims.requestable(["power"], manifest: manifest))
        #expect(!ExtensionShims.requestable(["history", "power"], manifest: manifest))
        #expect(!ExtensionShims.requestable(["power"], manifest: [:]))
    }

    @Test func userScriptsNeedTheirPermission() {
        guard #available(macOS 15.4, *) else { return }
        #expect(ExtensionShims.needs("userScripts.file") == ["userScripts"])
        #expect(ExtensionShims.needs("userScripts.save") == ["userScripts"])
    }
}
