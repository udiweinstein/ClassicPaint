import Cocoa

// MARK: - Color

struct RGB: Equatable {
    var r: UInt8, g: UInt8, b: UInt8

    init(_ r: Int, _ g: Int, _ b: Int) {
        self.r = UInt8(clamping: r); self.g = UInt8(clamping: g); self.b = UInt8(clamping: b)
    }
    init(hex: UInt32) { self.init(Int((hex >> 16) & 0xFF), Int((hex >> 8) & 0xFF), Int(hex & 0xFF)) }
    /// Pixel layout in memory is R,G,B,A (read as little-endian UInt32 => 0xAABBGGRR)
    init(packed p: UInt32) {
        r = UInt8(p & 0xFF); g = UInt8((p >> 8) & 0xFF); b = UInt8((p >> 16) & 0xFF)
    }
    init(ns: NSColor) {
        let c = ns.usingColorSpace(.sRGB) ?? NSColor.black
        self.init(Int((c.redComponent * 255).rounded()),
                  Int((c.greenComponent * 255).rounded()),
                  Int((c.blueComponent * 255).rounded()))
    }
    var packed: UInt32 { 0xFF00_0000 | (UInt32(b) << 16) | (UInt32(g) << 8) | UInt32(r) }
    var cg: CGColor { CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
    var ns: NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }

    static let black = RGB(0, 0, 0)
    static let white = RGB(255, 255, 255)
}

// MARK: - Bitmap (top-left origin, aliased drawing like the real Paint)

final class Bitmap {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    let width: Int
    let height: Int
    let ctx: CGContext
    let px: UnsafeMutablePointer<UInt32>

    init(width w: Int, height h: Int, fill: RGB? = .white) {
        let W = max(1, w), H = max(1, h)
        let buf = UnsafeMutablePointer<UInt32>.allocate(capacity: W * H)
        buf.initialize(repeating: fill?.packed ?? 0, count: W * H)
        let c = CGContext(data: buf, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                          space: Bitmap.space, bitmapInfo: Bitmap.info)!
        width = W
        height = H
        ctx = c
        px = buf
        c.translateBy(x: 0, y: CGFloat(H))
        c.scaleBy(x: 1, y: -1)
        c.setShouldAntialias(false)
        c.setAllowsAntialiasing(false)
        c.interpolationQuality = .none
    }

    deinit { px.deallocate() }

    static let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

    func copy() -> Bitmap {
        let b = Bitmap(width: width, height: height, fill: nil)
        memcpy(b.px, px, width * height * 4)
        return b
    }

    func restore(from o: Bitmap) {
        guard o.width == width, o.height == height else { return }
        memcpy(px, o.px, width * height * 4)
    }

    /// Snapshot of the current pixels (always a fresh copy, so direct pixel writes are never stale)
    func image() -> CGImage {
        let data = Data(bytes: px, count: width * height * 4) as CFData
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: Bitmap.space, bitmapInfo: CGBitmapInfo(rawValue: Bitmap.info),
                       provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    @inline(__always) func inside(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < width && y < height }
    @inline(__always) func get(_ x: Int, _ y: Int) -> UInt32 { px[y * width + x] }
    @inline(__always) func set(_ x: Int, _ y: Int, _ c: UInt32) { if inside(x, y) { px[y * width + x] = c } }

    func fillRect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: UInt32) {
        let x0 = max(0, x), y0 = max(0, y), x1 = min(width, x + w), y1 = min(height, y + h)
        if x0 >= x1 || y0 >= y1 { return }
        for yy in y0..<y1 {
            let row = yy * width
            for xx in x0..<x1 { px[row + xx] = c }
        }
    }

    /// Draw a CGImage with its top-left at r.origin (top-left coordinate system).
    func draw(_ img: CGImage, in r: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    func strokePath(_ path: CGPath, _ color: RGB, _ lw: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cg)
        ctx.setLineWidth(lw)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    func fillPath(_ path: CGPath, _ color: RGB, evenOdd: Bool = false) {
        ctx.saveGState()
        ctx.setFillColor(color.cg)
        ctx.addPath(path)
        ctx.fillPath(using: evenOdd ? .evenOdd : .winding)
        ctx.restoreGState()
    }

    func stampLine(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ offsets: [(Int, Int)], _ c: UInt32) {
        bresenham(x0, y0, x1, y1) { x, y in
            for o in offsets { self.set(x + o.0, y + o.1, c) }
        }
    }

    // MARK: Flood fill (exact color match, like Paint)
    func floodFill(_ sx: Int, _ sy: Int, _ c: UInt32) {
        guard inside(sx, sy) else { return }
        let target = get(sx, sy)
        if target == c { return }
        var stack: [(Int, Int)] = [(sx, sy)]
        while let p = stack.popLast() {
            let x = p.0, y = p.1
            if px[y * width + x] != target { continue }
            var lx = x, rx = x
            while lx > 0 && px[y * width + lx - 1] == target { lx -= 1 }
            while rx < width - 1 && px[y * width + rx + 1] == target { rx += 1 }
            for xx in lx...rx { px[y * width + xx] = c }
            for ny in [y - 1, y + 1] where ny >= 0 && ny < height {
                var inRun = false
                for xx in lx...rx {
                    if px[ny * width + xx] == target {
                        if !inRun { stack.append((xx, ny)); inRun = true }
                    } else { inRun = false }
                }
            }
        }
    }

    // MARK: Transforms
    func flippedH() -> Bitmap {
        let b = Bitmap(width: width, height: height, fill: nil)
        for y in 0..<height { for x in 0..<width { b.px[y * width + x] = px[y * width + (width - 1 - x)] } }
        return b
    }
    func flippedV() -> Bitmap {
        let b = Bitmap(width: width, height: height, fill: nil)
        for y in 0..<height { memcpy(b.px + y * width, px + (height - 1 - y) * width, width * 4) }
        return b
    }
    /// 90° clockwise
    func rotated90() -> Bitmap {
        let b = Bitmap(width: height, height: width, fill: nil)
        for y in 0..<height { for x in 0..<width { b.px[x * height + (height - 1 - y)] = px[y * width + x] } }
        return b
    }
    func inverted() -> Bitmap {
        let b = copy()
        for i in 0..<(width * height) where (b.px[i] >> 24) == 0xFF { b.px[i] ^= 0x00FF_FFFF }
        return b
    }
    func scaled(to w: Int, _ h: Int) -> Bitmap {
        let b = Bitmap(width: w, height: h, fill: nil)
        b.draw(image(), in: CGRect(x: 0, y: 0, width: b.width, height: b.height))
        return b
    }
    func stretched(_ sx: Double, _ sy: Double) -> Bitmap {
        let nw = max(1, Int((Double(width) * sx).rounded())), nh = max(1, Int((Double(height) * sy).rounded()))
        let b = Bitmap(width: nw, height: nh, fill: nil)
        b.draw(image(), in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return b
    }
    func skewedH(_ deg: Double, fill: RGB?) -> Bitmap {
        if deg == 0 { return copy() }
        let t = tan(deg * .pi / 180)
        let extra = Int((abs(t) * Double(height - 1)).rounded())
        let b = Bitmap(width: width + extra, height: height, fill: fill)
        for y in 0..<height {
            let shift = t >= 0 ? Int((t * Double(height - 1 - y)).rounded()) : Int((-t * Double(y)).rounded())
            for x in 0..<width { b.px[y * b.width + x + shift] = px[y * width + x] }
        }
        return b
    }
    func skewedV(_ deg: Double, fill: RGB?) -> Bitmap {
        if deg == 0 { return copy() }
        let t = tan(deg * .pi / 180)
        let extra = Int((abs(t) * Double(width - 1)).rounded())
        let b = Bitmap(width: width, height: height + extra, fill: fill)
        for x in 0..<width {
            let shift = t >= 0 ? Int((t * Double(width - 1 - x)).rounded()) : Int((-t * Double(x)).rounded())
            for y in 0..<height { b.px[(y + shift) * width + x] = px[y * width + x] }
        }
        return b
    }
    func resizedCanvas(_ w: Int, _ h: Int, fill: RGB) -> Bitmap {
        let b = Bitmap(width: w, height: h, fill: fill)
        b.draw(image(), in: CGRect(x: 0, y: 0, width: width, height: height))
        return b
    }

    /// 24-bit RGB representation for saving (no alpha, like a real .bmp)
    func rgbRep() -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: width * 3, bitsPerPixel: 24)!
        let d = rep.bitmapData!
        for i in 0..<(width * height) {
            let p = px[i]
            d[i * 3] = UInt8(p & 0xFF)
            d[i * 3 + 1] = UInt8((p >> 8) & 0xFF)
            d[i * 3 + 2] = UInt8((p >> 16) & 0xFF)
        }
        return rep.retagging(with: .sRGB) ?? rep
    }
}

// MARK: - Raster helpers

func bresenham(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ plot: (Int, Int) -> Void) {
    var x = x0, y = y0
    let dx = abs(x1 - x0), dy = -abs(y1 - y0)
    let sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1
    var err = dx + dy
    while true {
        plot(x, y)
        if x == x1 && y == y1 { break }
        let e2 = 2 * err
        if e2 >= dy { err += dy; x += sx }
        if e2 <= dx { err += dx; y += sy }
    }
}

enum Stamp {
    static func square(_ n: Int) -> [(Int, Int)] {
        let h = n / 2
        var a: [(Int, Int)] = []
        for y in 0..<n { for x in 0..<n { a.append((x - h, y - h)) } }
        return a
    }
    static func round(_ n: Int) -> [(Int, Int)] {
        if n <= 1 { return [(0, 0)] }
        let r = Double(n) / 2
        var a: [(Int, Int)] = []
        for y in 0..<n {
            for x in 0..<n {
                let dx = Double(x) + 0.5 - r, dy = Double(y) + 0.5 - r
                if dx * dx + dy * dy <= r * r + 0.5 { a.append((x - n / 2, y - n / 2)) }
            }
        }
        return a
    }
    static func diag(_ n: Int, back: Bool) -> [(Int, Int)] {
        (0..<n).map { i in back ? (i - n / 2, i - n / 2) : (n / 2 - i, i - n / 2) }
    }

    /// Brush shapes in the same order as the Paint options box (4 rows x 3 sizes)
    static let brushes: [[(Int, Int)]] = [
        round(7), round(4), round(1),
        square(8), square(5), square(2),
        diag(8, back: false), diag(5, back: false), diag(3, back: false),
        diag(8, back: true), diag(5, back: true), diag(3, back: true),
    ]
    static let eraserSizes = [4, 6, 8, 10]
    static let airRadius = [4, 8, 12]
}
