// The active badge averages files, not bytes, and never assigns an exact
// global percentage to a set containing an indeterminate transfer.
import Testing
@testable import Escale

@Suite struct DownloadsTests {
    @Test func knownTransfersHaveEqualWeight() {
        #expect(Downloads.fraction([0.25]) == 0.25)
        #expect(Downloads.fraction([0.25, 0.75]) == 0.5)
        #expect(Downloads.fraction([0, 0.5, 1]) == 0.5)
        #expect(Downloads.fraction([-1, 2]) == 0.5)
    }
    @Test func unknownAndEmptyHaveNoPercentage() {
        #expect(Downloads.fraction([]) == nil)
        #expect(Downloads.fraction([nil]) == nil)
        #expect(Downloads.fraction([0.5, nil]) == nil)
        #expect(Downloads.fraction([.nan]) == nil)
        #expect(Downloads.fraction([.infinity]) == nil)
    }
}
