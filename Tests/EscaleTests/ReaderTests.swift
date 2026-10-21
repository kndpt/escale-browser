// Reading mode's text size and column: what is stored, what the bar steps
// to, and what an unconfigured browser shows. Its colours are tested with
// the palette's (GlassTests), which turns the palette's globals on and off.
import Testing
@testable import Escale

@Suite struct ReaderTests {
    /// Nothing, or something the bar never offers, reads as 18 px.
    @Test(arguments: [(nil, 18), (18, 18), (14, 14), (28, 28), (0, 18), (17, 18), (99, 18), (-4, 18)] as [(Int?, Int)])
    func sizeReads(stored: Int?, size: Int) {
        #expect(Reader.size(stored) == size)
    }

    /// One step at a time, held at either end.
    @Test func sizeSteps() {
        #expect(Reader.step(18, by: 1) == 20)
        #expect(Reader.step(18, by: -1) == 16)
        #expect(Reader.step(14, by: -1) == 14)
        #expect(Reader.step(28, by: 1) == 28)
        #expect(Reader.step(17, by: 1) == 20)
    }

    /// Unconfigured, the column and text are what reading mode always had.
    @Test func defaultsKeepTheOldColumn() {
        let dress = Reader.dress(look: .system, dark: false, width: .normal, size: Reader.size(nil))
        #expect(dress["width"] == "38em")
        #expect(dress["scale"] == "1.0")
        #expect(ReaderWidth.narrow.ems < ReaderWidth.normal.ems)
        #expect(ReaderWidth.normal.ems < ReaderWidth.wide.ems)
        #expect(Reader.dress(look: .system, dark: false, width: .wide, size: 22)["scale"] == "\(22.0 / 18)")
    }
}
