import Cocoa
import Vision

/// Per-pixel alpha mask (0 = background, 255 = subject)
struct AlphaMask {
    let width: Int
    let height: Int
    let a: [UInt8]
}

/// "Remove Background" like the modern Windows 11 Paint, using Apple's on-device
/// subject segmentation (the same engine as "Lift subject" in Photos / Preview).
enum BackgroundRemover {
    static var isAvailable: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    static func mask(for cg: CGImage) throws -> AlphaMask? {
        guard #available(macOS 14.0, *) else { return nil }
        let req = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try handler.perform([req])
        guard let obs = req.results?.first, !obs.allInstances.isEmpty else { return nil }
        let pb = try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let fmt = CVPixelBufferGetPixelFormatType(pb)

        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base + y * bpr
            for x in 0..<w {
                let v: Float
                if fmt == kCVPixelFormatType_OneComponent8 {
                    v = Float(row.load(fromByteOffset: x, as: UInt8.self)) / 255
                } else {
                    v = row.load(fromByteOffset: x * 4, as: Float.self)
                }
                out[y * w + x] = UInt8(max(0, min(255, (v * 255).rounded())))
            }
        }
        return AlphaMask(width: w, height: h, a: out)
    }
}

extension Bitmap {
    /// Multiplies the image's alpha by the mask (pixels stay premultiplied).
    func applyMask(_ m: AlphaMask) {
        for y in 0..<height {
            let my = min(m.height - 1, y * m.height / height)
            for x in 0..<width {
                let mx = min(m.width - 1, x * m.width / width)
                let a = UInt32(m.a[my * m.width + mx])
                if a == 255 { continue }
                let i = y * width + x
                let p = px[i]
                let r = (p & 0xFF) * a / 255
                let g = ((p >> 8) & 0xFF) * a / 255
                let b = ((p >> 16) & 0xFF) * a / 255
                let pa = (p >> 24) * a / 255
                px[i] = (pa << 24) | (b << 16) | (g << 8) | r
            }
        }
    }

    var hasTransparency: Bool {
        for i in 0..<(width * height) where (px[i] >> 24) != 0xFF { return true }
        return false
    }

    func flattened(on bg: RGB) -> Bitmap {
        let b = Bitmap(width: width, height: height, fill: bg)
        b.draw(image(), in: CGRect(x: 0, y: 0, width: width, height: height))
        return b
    }

    /// 32-bit RGBA representation (keeps transparency for PNG / TIFF)
    func rgbaRep() -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
        memcpy(rep.bitmapData!, px, width * height * 4)   // same layout: RGBA, premultiplied
        return rep.retagging(with: .sRGB) ?? rep
    }
}
