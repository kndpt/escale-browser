// A reference change must preserve existing site sizes without repeatedly
// rewriting storage, and a default zoom must move only the sites that never
// chose their own. Invalid saved data falls back to the default.
import Foundation
import Testing
@testable import Escale

@Suite struct PageZoomTests {
    @Test func defaultAndResetMatchTheOldSingleStep() {
        #expect(abs(PageZoom.remembered(nil, standard: 1) - 1 / 1.1) < 1e-12)
        #expect(abs(PageZoom.absolute(1) - 1 / 1.1) < 1e-12)
        #expect(PageZoom.relative(PageZoom.remembered(nil, standard: 1)) == 1)
        #expect(PageZoom.kept(1, standard: 1) == nil)
    }
    @Test(arguments: [0.4, 0.91, 1, 1.21, 3])
    func existingSitesKeepTheirVisualSize(_ saved: Double) {
        for standard: CGFloat in [1, 1.25] {
            let actual = PageZoom.remembered(saved, standard: standard)
            #expect(Double(actual) == saved)
            #expect(abs(PageZoom.absolute(PageZoom.relative(actual)) - actual) < 1e-12)
        }
    }
    @Test func invalidValuesAndRelativeSteps() {
        for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, 0, -1, 0.1, 4] {
            #expect(PageZoom.remembered(value, standard: 1) == PageZoom.reference)
            #expect(PageZoom.remembered(value, standard: 1.5) == PageZoom.absolute(1.5))
        }
        #expect(abs(PageZoom.absolute(1.1) - 1) < 1e-12)
        #expect(abs(PageZoom.relative(1.21) - 1.331) < 1e-12)
    }
    @Test func aSiteWithNothingSavedOpensAtTheDefault() {
        #expect(abs(PageZoom.relative(PageZoom.remembered(nil, standard: 1.25)) - 1.25) < 1e-12)
    }
    @Test func resetToTheDefaultClearsTheSite() {
        #expect(PageZoom.kept(1.25, standard: 1.25) == nil)
        #expect(PageZoom.kept(1.25 * 1.001, standard: 1.25) == nil)
    }
    @Test func aSiteAtAHundredUnderAnotherDefaultIsKept() {
        let kept = PageZoom.kept(1, standard: 1.25)
        #expect(kept.map { abs($0 - 1 / 1.1) < 1e-12 } == true)
        #expect(kept.map { abs(PageZoom.relative(PageZoom.remembered($0, standard: 1.25)) - 1) < 1e-12 } == true)
    }
    @Test func onlyListedDefaultsAreRead() {
        #expect(PageZoom.defaults.contains(100))
        #expect(PageZoom.standard(nil) == 100)
        #expect(PageZoom.standard(125) == 125)
        for stored in [0, -100, 99, 1000] { #expect(PageZoom.standard(stored) == 100) }
    }
}
