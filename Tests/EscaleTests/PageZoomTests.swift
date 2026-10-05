// A reference change must preserve existing site sizes without repeatedly
// rewriting storage. Invalid saved data falls back to the new default.
import Foundation
import Testing
@testable import Escale

@Suite struct PageZoomTests {
    @Test func defaultAndResetMatchTheOldSingleStep() {
        #expect(abs(PageZoom.remembered(nil) - 1 / 1.1) < 1e-12)
        #expect(abs(PageZoom.absolute(1) - 1 / 1.1) < 1e-12)
        #expect(PageZoom.relative(PageZoom.remembered(nil)) == 1)
    }
    @Test(arguments: [0.4, 0.91, 1, 1.21, 3])
    func existingSitesKeepTheirVisualSize(_ saved: Double) {
        let actual = PageZoom.remembered(saved)
        #expect(Double(actual) == saved)
        #expect(abs(PageZoom.absolute(PageZoom.relative(actual)) - actual) < 1e-12)
    }
    @Test func invalidValuesAndRelativeSteps() {
        for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, 0, -1, 0.1, 4] {
            #expect(PageZoom.remembered(value) == PageZoom.reference)
        }
        #expect(abs(PageZoom.absolute(1.1) - 1) < 1e-12)
        #expect(abs(PageZoom.relative(1.21) - 1.331) < 1e-12)
    }
}
