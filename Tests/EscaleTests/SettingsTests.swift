import AppKit
import Testing
@testable import Escale

// The Settings reorganisation keeps the last visited page meaningful and
// makes common option names discoverable without knowing their category.
// SF Symbols are resolved by macOS at runtime, so checking every navigation
// symbol here catches a blank icon that the Swift compiler cannot detect.
@Suite struct SettingsTests {
    @Test(arguments: [
        ("downloads", SettingsPanel.Page.general),
        ("notifications", .developer),
        ("extensions", .extensions),
        ("unknown", .general),
        ("routing", .routing),
    ])
    func restoresPage(raw: String, page: SettingsPanel.Page) {
        #expect(SettingsPanel.Page.restored(raw) == page)
    }

    @Test(arguments: [
        ("gear", SettingsPanel.Page.general),
        ("download", .general),
        ("address", .tabs),
        ("middle button", .pages),
        ("notification", .developer),
        ("shortcut", .keyboard),
        ("animations", .appearance),
    ])
    func findsOption(query: String, page: SettingsPanel.Page) {
        #expect(page.matches(query))
    }

    /// Link Routing is found by the words the issue named, from one place only.
    @Test(arguments: ["Link Routing", "routing", "routage", "liens", "rules", "Space"])
    func findsLinkRouting(query: String) {
        #expect(SettingsPanel.Page.routing.matches(query))
    }

    @Test func linkRoutingLeadsTheFeatures() {
        #expect(SettingsPanel.Page.features.first == .routing)
        #expect(!SettingsPanel.Page.tabs.matches("routing"))
        let grouped = SettingsPanel.Page.features + SettingsPanel.Page.browsing + SettingsPanel.Page.personal + SettingsPanel.Page.tools
        #expect(grouped.filter { $0 == .routing }.count == 1)
    }

    /// Settings read at the column's size; floating panels keep theirs.
    @Test func settingsAreSetAtTheChromeSize() {
        #expect(CardDensity.settings.title <= 12.5 && Metrics.settingsRowText <= 12.5)
        #expect(CardDensity.settings.title < CardDensity.panel.title)
        #expect(CardDensity.settings.pad < CardDensity.panel.pad)
        #expect(CardDensity.panel.title == 13 && CardDensity.panel.inset == 14 && CardDensity.panel.pad == 11)
    }

    /// Find a setting reads each row's own title and description.
    @Test(arguments: [
        ("translate", Setting.selection),
        ("agent sessions", .agents),
        ("sessions agent", .agents),
        ("middle scroll", .autoScroll),
        ("keychain", .vault),
        ("TRACKERS", .shield),
    ])
    func findsASettingByItsWords(query: String, setting: Setting) {
        #expect(Setting.found(query).contains(setting))
    }

    @Test func pagesMatchWordsInAnyOrder() {
        #expect(SettingsPanel.Page.pages.matches("scroll middle"))
        #expect(SettingsPanel.Page.pages.matches("middle scroll"))
        #expect(!SettingsPanel.Page.pages.matches("middle sidebar"))
    }

    @Test func aHiddenRowLandsOnTheOneThatShowsIt() {
        #expect(Setting.agents.under == .alerts)
        #expect(Setting.neverAsked.under == .savePasswords)
        #expect(Setting.agents.page == .developer && Setting.alerts.page == .developer)
        #expect(Setting.allCases.allSatisfy { row in row.under.map { $0.page == row.page && $0.under == nil } ?? true })
    }

    @Test func theCatalogueIsWellFormed() {
        #expect(Set(Setting.allCases.map(\.title)).count == Setting.allCases.count)
        #expect(Setting.allCases.allSatisfy { !$0.title.isEmpty })
        #expect(Setting.found("").isEmpty && Setting.found("   ").isEmpty)
        #expect(Setting.found("nothing like this").isEmpty)
    }

    @Test func everyPageHasAnAvailableSymbol() {
        for page in SettingsPanel.Page.allCases {
            #expect(NSImage(systemSymbolName: page.icon, accessibilityDescription: nil) != nil)
        }
    }
}
