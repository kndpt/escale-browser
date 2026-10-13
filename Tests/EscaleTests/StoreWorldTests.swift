import Foundation
import Testing
@testable import Escale

// The unit tests write icons, settings and files through Store: they must
// land in a test world, never in the folder of the browser somebody uses.
@Suite struct StoreWorldTests {
    @Test func theTestsRunInATestWorld() {
        #expect(Store.testing)
        #expect(Store.world != nil)
        #expect(Store.folder.lastPathComponent != "Escale")
        #expect(Store.settings != UserDefaults.standard)
    }
}
