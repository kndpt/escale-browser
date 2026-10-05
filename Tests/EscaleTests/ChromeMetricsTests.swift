import Foundation
import Testing
@testable import Escale

// Interface sizes resolve geometry before SwiftUI lays it out. These tests
// keep the three Settings-preview proportions, profile semantics and stored
// sidebar widths from drifting while the chrome evolves.
@Suite struct ChromeMetricsTests {
    @Test func finalSizesMatchTheSettingsPreviews() {
        #expect(ChromeMetrics(size: .compact).strip == 32.5)
        #expect(ChromeMetrics(size: .standard).strip == 40.5)
        #expect(ChromeMetrics(size: .large).strip == 48.5)
        #expect(15 * InterfaceSize.compact.factor / InterfaceSize.standard.factor == 12)
        #expect(15 * InterfaceSize.standard.factor / InterfaceSize.standard.factor == 15)
        #expect(15 * InterfaceSize.large.factor / InterfaceSize.standard.factor == 18)
    }

    @Test func sizesUseOrderedFinalGeometry() {
        let compact = ChromeMetrics(size: .compact)
        let standard = ChromeMetrics(size: .standard)
        let large = ChromeMetrics(size: .large)

        #expect(compact.strip < standard.strip)
        #expect(standard.strip < large.strip)
        #expect(compact.fieldWidth < standard.fieldWidth)
        #expect(standard.fieldWidth < large.fieldWidth)
        #expect(compact.sidebarWidth(232) < standard.sidebarWidth(232))
        #expect(standard.sidebarWidth(232) < large.sidebarWidth(232))
        #expect(compact.spaceRailWidth < standard.spaceRailWidth)
        #expect(standard.spaceRailWidth < large.spaceRailWidth)
    }

    @Test func profilesKeepTheirNamedSizeThroughCalibration() {
        #expect(InterfaceSize.stored(nil) == .standard)
        #expect(InterfaceSize.stored("compact") == .compact)
        #expect(InterfaceSize.stored("standard") == .standard)
        #expect(InterfaceSize.stored("large") == .large)
        #expect(InterfaceSize.stored("unrecognised") == .standard)
    }

    @Test func persistedSidebarWidthKeepsItsLayoutCoordinate() {
        let width: CGFloat = 286
        let compact = ChromeMetrics(size: .compact)
        let standard = ChromeMetrics(size: .standard)

        // Final layout edges snap to half points; converting the rounded edge
        // back to its stored coordinate can be off by less than one source
        // point at the compact density.
        #expect(abs(compact.layout(compact.sidebarWidth(width)) - width) < 0.3)
        #expect(abs(standard.layout(standard.sidebarWidth(width)) - width) < 0.3)
    }

    @Test func theRailGapIsNotAColumnBorder() {
        let metrics = ChromeMetrics(size: .standard)
        let open = metrics.sidebarFootprint(232, rail: true, folded: false)
        #expect(open == metrics.spaceRailWidth + metrics.spaceRailGap + metrics.sidebarWidth(232))
    }
}
