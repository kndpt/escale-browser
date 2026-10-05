// Capture geometry is checked before WebKit or bitmap allocation. These cases
// cover hostile/empty dimensions, extreme pages and the actual raster budget.
import Foundation
import Testing
@testable import Escale

@Suite struct CaptureBoundsTests {
    @Test func invalidGeometryDoesNotAllocate() {
        for rect in [CGRect.zero, CGRect(x:0,y:0,width:0,height:20), CGRect(x:0,y:0,width:CGFloat.infinity,height:20),
                     CGRect(x:CGFloat.nan,y:0,width:20,height:20), CGRect(x:10_000_001,y:0,width:20,height:20)] {
            #expect(CaptureBounds(rect) == nil)
        }
    }
    @Test func ordinaryElementKeepsItsSize() throws {
        let result = try #require(CaptureBounds(CGRect(x:45,y:80,width:300,height:125)))
        #expect(result.width == 300 && result.height == 125 && !result.clipped)
        #expect(result.rect.origin == CGPoint(x:45,y:80))
    }
    @Test func longPagesAndWideRegionsStayBounded() throws {
        for size in [CGSize(width:1200,height:1000000), CGSize(width:1000000,height:1000000), CGSize(width:1,height:1000000)] {
            let result = try #require(CaptureBounds(CGRect(origin:.zero,size:size)))
            #expect(result.clipped)
            #expect(result.width > 0 && result.height > 0)
            #expect(result.width <= 2048 && result.height <= 2048)
            #expect(result.width * result.height <= CaptureBounds.pixels)
            #expect(result.rect.height == CaptureBounds.sourceEdge)
        }
    }
}
