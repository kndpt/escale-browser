// Raster output is capped before WebKit work begins: four million pixels,
// 2,048 pixels on either axis, and a 16,384-point source extent. Long/infinite
// documents are clipped explicitly, not resized by changing the live page.
// Non-finite, empty and overflowing geometry is refused before allocation.
import Foundation

struct CaptureBounds {
    static let pixels = 4_194_304
    static let edge = 2048
    static let sourceEdge: CGFloat = 16_384
    let rect: CGRect
    let width: Int
    let height: Int
    let clipped: Bool
    init?(_ proposed: CGRect) {
        guard [proposed.minX,proposed.minY,proposed.width,proposed.height].allSatisfy(\.isFinite),
              proposed.width > 0, proposed.height > 0,
              abs(proposed.minX) <= 10_000_000, abs(proposed.minY) <= 10_000_000 else { return nil }
        let width = min(Self.sourceEdge, proposed.width), height = min(Self.sourceEdge, proposed.height)
        rect = CGRect(x:proposed.minX,y:proposed.minY,width:width,height:height)
        clipped = width < proposed.width || height < proposed.height
        let scale = min(1, CGFloat(Self.edge) / max(width,height), sqrt(CGFloat(Self.pixels) / (width * height)))
        self.width = max(1, Int(floor(width * scale)))
        self.height = max(1, Int(floor(height * scale)))
    }
}
