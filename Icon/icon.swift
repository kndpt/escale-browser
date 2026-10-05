// The app's icon, drawn rather than exported: the mark is read from its own
// path data rather than loaded as an image, so it stays a crisp vector at
// every size instead of a raster scaled up. The icon puts it on a plate — a
// Dock icon has to be an opaque square whether the logo itself wants a
// background or not.
//
//   swift Icon/icon.swift [dir]          the Dock's iconset (build.sh)
//   swift Icon/icon.swift --kit [dir]    the brand kit, docs/brand by default:
//                                        every file docs/BRAND.md lists

import AppKit

/// Escale's mark: the stop, and the flight on from it, on its own 470 × 335
/// canvas. The same path is in Design.swift's `Logomark` — one shape, two
/// places (docs/BRAND.md lists the others, outside this repository).
let canvas = (width: 470.0, height: 335.0)
let markData = "M90 155H170C219.71 155 260 195.29 260 245C260 294.71 219.71 335 170 335H90C40.29 335 0 294.71 0 245C0 195.29 40.29 155 90 155ZM410 5C443.14 5 470 31.86 470 65C470 98.14 443.14 125 410 125C376.86 125 350 98.14 350 65C350 31.86 376.86 5 410 5ZM129 98C137.28 98 144 104.72 144 113C144 121.28 137.28 128 129 128C120.72 128 114 121.28 114 113C114 104.72 120.72 98 129 98ZM167 56C175.28 56 182 62.72 182 71C182 79.28 175.28 86 167 86C158.72 86 152 79.28 152 71C152 62.72 158.72 56 167 56ZM211 21C219.28 21 226 27.72 226 36C226 44.28 219.28 51 211 51C202.72 51 196 44.28 196 36C196 27.72 202.72 21 211 21ZM264 0C272.28 0 279 6.72 279 15C279 23.28 272.28 30 264 30C255.72 30 249 23.28 249 15C249 6.72 255.72 0 264 0ZM320 1C328.28 1 335 7.72 335 16C335 24.28 328.28 31 320 31C311.72 31 305 24.28 305 16C305 7.72 311.72 1 320 1Z"

/// The mark's width on any plate, as a share of the plate's: wide enough to
/// read at 16 points, with a margin the Dock's other icons also keep.
let markShare = 0.70

/// The brand's colours (docs/BRAND.md). The Dock icon is the app's own
/// neutral: a white plate and near-black ink. Everything outside the app —
/// the site, favicons, avatars — is the warm pair, espresso and cream.
let white = "#ffffff", ink = "#171717"
let espresso = "#221b16", cream = "#efe7dc", sand = "#e7ddd0"

func color(_ hex: String) -> NSColor {
    let v = Int(hex.dropFirst(), radix: 16)!
    return NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
}

/// A tiny reader for the one path the mark is: absolute M, L, H, V, C, Z —
/// what Figma writes for a flattened shape, and nothing else.
func svgCommands(_ d: String) -> [(Character, [CGFloat])] {
    var out: [(Character, [CGFloat])] = []
    var current: Character?
    var numbers: [CGFloat] = []
    var token = ""
    func flushNumber() {
        if !token.isEmpty, let v = Double(token) { numbers.append(CGFloat(v)) }
        token = ""
    }
    for ch in d {
        if "MLHVCZmlhvcz".contains(ch) {
            flushNumber()
            if let current { out.append((current, numbers)) }
            current = ch
            numbers = []
        } else if ch == " " || ch == "," {
            flushNumber()
        } else if ch == "-" && !token.isEmpty && !token.hasSuffix("e") {
            flushNumber()
            token = "-"
        } else {
            token.append(ch)
        }
    }
    flushNumber()
    if let current { out.append((current, numbers)) }
    return out
}

/// The mark, `width` wide and centred on `center`. SVG's y grows downward
/// and AppKit's upward, so every y is flipped on the way in; the path is
/// filled even-odd, so a mark with a hole in it would keep it.
func markPath(width: CGFloat, center: NSPoint) -> NSBezierPath {
    let scale = width / canvas.width
    let ox = center.x - canvas.width * scale / 2
    let oy = center.y - canvas.height * scale / 2
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: ox + x * scale, y: oy + (canvas.height - y) * scale)
    }
    let path = NSBezierPath()
    path.windingRule = .evenOdd
    var last = NSPoint.zero
    var start = NSPoint.zero
    for (c, n) in svgCommands(markData) {
        switch c {
        case "M": last = NSPoint(x: n[0], y: n[1]); start = last; path.move(to: pt(n[0], n[1]))
        case "L": last = NSPoint(x: n[0], y: n[1]); path.line(to: pt(n[0], n[1]))
        case "H": last.x = n[0]; path.line(to: pt(last.x, last.y))
        case "V": last.y = n[0]; path.line(to: pt(last.x, last.y))
        case "C":
            var k = 0
            while k + 5 < n.count {
                path.curve(to: pt(n[k + 4], n[k + 5]), controlPoint1: pt(n[k], n[k + 1]), controlPoint2: pt(n[k + 2], n[k + 3]))
                last = NSPoint(x: n[k + 4], y: n[k + 5])
                k += 6
            }
        case "Z": path.close(); last = start
        default: break
        }
    }
    return path
}

// MARK: - drawings, in pixels

/// The Dock icon on Apple's grid: the shape takes 824 of 1024, its corners
/// are 22.37%, and a soft shadow sits under it as under every Dock icon.
func drawIcon(_ size: CGFloat) {
    let s = size / 1024
    let plate = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let radius = 824 * 0.2237 * s
    let shape = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    color(white).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    color(ink).setFill()
    markPath(width: plate.width * markShare, center: NSPoint(x: plate.midX, y: plate.midY)).fill()
}

/// The espresso plate the site and its favicons use: full bleed, rounded
/// 22.5%, or square (`radius` 0) for places that round it themselves —
/// Apple's touch icon, an avatar.
func drawPlate(_ size: CGFloat, radius: CGFloat = 0.225) {
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    color(espresso).setFill()
    NSBezierPath(roundedRect: rect, xRadius: size * radius, yRadius: size * radius).fill()
    color(cream).setFill()
    markPath(width: size * markShare, center: NSPoint(x: size / 2, y: size / 2)).fill()
}

/// A square avatar is cropped to a circle almost everywhere: the mark keeps
/// inside it.
func drawAvatar(_ size: CGFloat) {
    color(espresso).setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    color(cream).setFill()
    markPath(width: size * 0.56, center: NSPoint(x: size / 2, y: size / 2)).fill()
}

/// The bare mark on nothing, `size` wide.
func drawMark(_ size: CGFloat, _ hex: String) {
    color(hex).setFill()
    let height = size * canvas.height / canvas.width
    markPath(width: size, center: NSPoint(x: size / 2, y: height / 2)).fill()
}

/// A repository's social preview: the mark on the site's sand.
func drawSocial(_ w: CGFloat, _ h: CGFloat) {
    color(sand).setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    color(espresso).setFill()
    markPath(width: h * 0.56, center: NSPoint(x: w / 2, y: h / 2)).fill()
}

/// Draws straight into a bitmap of exactly `w` × `h` pixels, whatever the
/// screen's scale, and returns it as PNG.
func png(_ w: Int, _ h: Int, _ draw: () -> Void) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
}

/// Every size macOS asks an iconset for.
func iconset(_ out: URL) {
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = points * scale
            let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            write(png(pixels, pixels) { drawIcon(CGFloat(pixels)) }, out.appendingPathComponent(name))
        }
    }
}

// MARK: - the brand kit

/// The mark as SVG, `width` wide and centred on (`cx`, `cy`).
func svgMark(width: Double, cx: Double, cy: Double, fill: String) -> String {
    let s = width / canvas.width
    let tx = cx - canvas.width * s / 2, ty = cy - canvas.height * s / 2
    func r(_ v: Double) -> String { String(format: "%.4g", v) }
    return "<path transform=\"translate(\(r(tx)) \(r(ty))) scale(\(r(s)))\" fill=\"\(fill)\" d=\"\(markData)\"/>"
}

func svg(_ w: Int, _ h: Int, _ body: String) -> Data {
    Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(w) \(h)\">\(body)</svg>\n".utf8)
}

/// An .ico holding PNGs, as every browser reads them.
func ico(_ sizes: [Int], _ draw: (CGFloat) -> Void) -> Data {
    let images = sizes.map { size in png(size, size) { draw(CGFloat(size)) } }
    var out = Data()
    func u16(_ v: Int) { out.append(contentsOf: [UInt8(v & 255), UInt8(v >> 8 & 255)]) }
    func u32(_ v: Int) { u16(v & 0xffff); u16(v >> 16) }
    u16(0); u16(1); u16(images.count)
    var offset = 6 + 16 * images.count
    for (size, image) in zip(sizes, images) {
        out.append(contentsOf: [UInt8(size >= 256 ? 0 : size), UInt8(size >= 256 ? 0 : size), 0, 0])
        u16(1); u16(32); u32(image.count); u32(offset)
        offset += image.count
    }
    images.forEach { out.append($0) }
    return out
}

func kit(_ out: URL) {
    let file = { (name: String) in out.appendingPathComponent(name) }

    // Vectors: the bare mark in both inks, the Dock icon, and the espresso
    // plate rounded and square.
    write(svg(470, 335, svgMark(width: 470, cx: 235, cy: 167.5, fill: espresso)), file("mark.svg"))
    write(svg(470, 335, svgMark(width: 470, cx: 235, cy: 167.5, fill: cream)), file("mark-cream.svg"))
    write(svg(1024, 1024, "<rect x=\"100\" y=\"100\" width=\"824\" height=\"824\" rx=\"184.33\" fill=\"\(white)\"/>"
        + svgMark(width: 824 * markShare, cx: 512, cy: 512, fill: ink)), file("icon.svg"))
    write(svg(64, 64, "<rect width=\"64\" height=\"64\" rx=\"14.4\" fill=\"\(espresso)\"/>"
        + svgMark(width: 64 * markShare, cx: 32, cy: 32, fill: cream)), file("plate.svg"))
    write(svg(64, 64, "<rect width=\"64\" height=\"64\" fill=\"\(espresso)\"/>"
        + svgMark(width: 64 * markShare, cx: 32, cy: 32, fill: cream)), file("tile.svg"))

    // Pictures, at the sizes the places that take them ask for.
    for size in [16, 32, 64, 128, 256, 512, 1024] {
        write(png(size, size) { drawIcon(CGFloat(size)) }, file("png/icon-\(size).png"))
    }
    for size in [16, 32, 48, 64, 128, 256, 512, 1024] {
        write(png(size, size) { drawPlate(CGFloat(size)) }, file("png/plate-\(size).png"))
    }
    for size in [180, 512, 1024] {
        write(png(size, size) { drawPlate(CGFloat(size), radius: 0) }, file("png/tile-\(size).png"))
    }
    write(png(800, 800) { drawAvatar(800) }, file("png/avatar-800.png"))
    for size in [256, 512, 1024] {
        let height = Int((Double(size) * canvas.height / canvas.width).rounded())
        write(png(size, height) { drawMark(CGFloat(size), espresso) }, file("png/mark-\(size).png"))
        write(png(size, height) { drawMark(CGFloat(size), cream) }, file("png/mark-cream-\(size).png"))
    }
    write(png(1280, 640) { drawSocial(1280, 640) }, file("png/social-1280x640.png"))
    write(ico([16, 32, 48]) { drawPlate($0) }, file("favicon.ico"))

    // The app icon as macOS stores it.
    let set = FileManager.default.temporaryDirectory.appendingPathComponent("Escale-\(UUID().uuidString).iconset")
    iconset(set)
    let run = Process()
    run.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    run.arguments = ["-c", "icns", set.path, "-o", file("AppIcon.icns").path]
    try! run.run()
    run.waitUntilExit()
    try? FileManager.default.removeItem(at: set)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--kit" {
    let out = URL(fileURLWithPath: args.dropFirst().first ?? "docs/brand")
    kit(out)
    print("drew: \(out.path)")
} else {
    let out = URL(fileURLWithPath: args.first ?? "AppIcon.iconset")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    iconset(out)
    print("drew: \(out.path)")
}
