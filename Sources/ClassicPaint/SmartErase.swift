import Foundation

// MARK: - Smart Erase ("content-aware fill")
//
// Fills a hole in the picture from its surroundings, so a removed object is replaced by
// matching texture instead of a flat color. Multi-scale exemplar-based inpainting
// (Wexler et al. / PatchMatch, Barnes et al.): at each scale, every patch touching the hole
// finds its best-matching patch outside the hole, and the hole pixels become a weighted
// vote of those matches. Coarse scales get the overall structure, fine scales the detail.

final class InpaintLevel {
    let w: Int, h: Int
    let img: UnsafeMutablePointer<Float>      // w*h*4 (premultiplied RGBA, 0…255)
    var hole: [Bool]

    init(w: Int, h: Int) {
        self.w = w; self.h = h
        img = .allocate(capacity: w * h * 4)
        img.initialize(repeating: 0, count: w * h * 4)
        hole = [Bool](repeating: false, count: w * h)
    }
    deinit { img.deallocate() }
}

enum SmartErase {
    static let R = 3                              // patch radius → 7×7 patches

    enum Failure: Error { case empty, tooLarge, noSurroundings }

    /// Fills the pixels where `mask` is true. `px` is the whole picture (RGBA premultiplied,
    /// memory order R,G,B,A). Only masked pixels are changed.
    static func fill(_ px: UnsafeMutablePointer<UInt32>, width W: Int, height H: Int, mask: [Bool]) -> Failure? {
        var minX = W, minY = H, maxX = -1, maxY = -1, count = 0
        for y in 0..<H {
            for x in 0..<W where mask[y * W + x] {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y); count += 1
            }
        }
        guard count > 0 else { return .empty }
        guard count <= 1_500_000, count * 10 <= W * H * 7 else { return .tooLarge }

        // Work on the hole plus a margin about as wide as the hole: "the surroundings"
        let bw = maxX - minX + 1, bh = maxY - minY + 1
        let margin = max(6 * R, max(bw, bh))
        let rx0 = max(0, minX - margin), ry0 = max(0, minY - margin)
        let rx1 = min(W - 1, maxX + margin), ry1 = min(H - 1, maxY + margin)
        let L = InpaintLevel(w: rx1 - rx0 + 1, h: ry1 - ry0 + 1)
        var known = 0
        for y in 0..<L.h {
            for x in 0..<L.w {
                let p = px[(y + ry0) * W + x + rx0], i = y * L.w + x
                L.img[i * 4] = Float(p & 0xFF)
                L.img[i * 4 + 1] = Float((p >> 8) & 0xFF)
                L.img[i * 4 + 2] = Float((p >> 16) & 0xFF)
                L.img[i * 4 + 3] = Float(p >> 24)
                L.hole[i] = mask[(y + ry0) * W + x + rx0]
                if !L.hole[i] { known += 1 }
            }
        }
        guard known > (2 * R + 1) * (2 * R + 1) else { return .noSurroundings }

        inpaint(L)

        for y in 0..<L.h {
            for x in 0..<L.w where L.hole[y * L.w + x] {
                let i = (y * L.w + x) * 4
                let a = UInt32(max(0, min(255, L.img[i + 3].rounded())))
                func ch(_ v: Float) -> UInt32 { min(a, UInt32(max(0, min(255, v.rounded())))) }
                px[(y + ry0) * W + x + rx0] = (a << 24) | (ch(L.img[i + 2]) << 16) | (ch(L.img[i + 1]) << 8) | ch(L.img[i])
            }
        }
        return nil
    }

    // MARK: Pyramid

    private static func holeExtent(_ L: InpaintLevel) -> Int {
        var minX = L.w, minY = L.h, maxX = -1, maxY = -1
        for y in 0..<L.h { for x in 0..<L.w where L.hole[y * L.w + x] {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        return maxX < 0 ? 0 : max(maxX - minX + 1, maxY - minY + 1)
    }

    /// Half size. A coarse pixel is a hole if any of its 4 pixels is; its color is the
    /// average of the known ones.
    private static func downsample(_ c: InpaintLevel) -> InpaintLevel {
        let L = InpaintLevel(w: (c.w + 1) / 2, h: (c.h + 1) / 2)
        for y in 0..<L.h {
            for x in 0..<L.w {
                var s0: Float = 0, s1: Float = 0, s2: Float = 0, s3: Float = 0, n: Float = 0
                var anyHole = false
                for dy in 0...1 { for dx in 0...1 {
                    let cx = 2 * x + dx, cy = 2 * y + dy
                    if cx >= c.w || cy >= c.h { continue }
                    let i = cy * c.w + cx
                    if c.hole[i] { anyHole = true; continue }
                    s0 += c.img[i * 4]; s1 += c.img[i * 4 + 1]; s2 += c.img[i * 4 + 2]; s3 += c.img[i * 4 + 3]; n += 1
                } }
                let o = (y * L.w + x) * 4
                if n > 0 { L.img[o] = s0 / n; L.img[o + 1] = s1 / n; L.img[o + 2] = s2 / n; L.img[o + 3] = s3 / n }
                L.hole[y * L.w + x] = anyHole
            }
        }
        return L
    }

    /// First guess at the coarsest scale: grow the known colors inward, ring by ring.
    private static func onionInit(_ L: InpaintLevel) {
        var known = L.hole.map { !$0 }
        var remaining = known.filter { !$0 }.count
        while remaining > 0 {
            var updates: [(Int, Float, Float, Float, Float)] = []
            for y in 0..<L.h {
                for x in 0..<L.w where !known[y * L.w + x] {
                    var s0: Float = 0, s1: Float = 0, s2: Float = 0, s3: Float = 0, n: Float = 0
                    for dy in -1...1 { for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        if nx < 0 || ny < 0 || nx >= L.w || ny >= L.h { continue }
                        let j = ny * L.w + nx
                        if !known[j] { continue }
                        s0 += L.img[j * 4]; s1 += L.img[j * 4 + 1]; s2 += L.img[j * 4 + 2]; s3 += L.img[j * 4 + 3]; n += 1
                    } }
                    if n > 0 { updates.append((y * L.w + x, s0 / n, s1 / n, s2 / n, s3 / n)) }
                }
            }
            if updates.isEmpty { break }
            for u in updates {
                L.img[u.0 * 4] = u.1; L.img[u.0 * 4 + 1] = u.2; L.img[u.0 * 4 + 2] = u.3; L.img[u.0 * 4 + 3] = u.4
                known[u.0] = true
            }
            remaining -= updates.count
        }
    }

    /// First guess at a finer scale: the coarser scale's result, enlarged.
    private static func upsampleInit(_ L: InpaintLevel, from C: InpaintLevel) {
        for y in 0..<L.h {
            for x in 0..<L.w where L.hole[y * L.w + x] {
                let c = (min(y / 2, C.h - 1) * C.w + min(x / 2, C.w - 1)) * 4, o = (y * L.w + x) * 4
                for k in 0..<4 { L.img[o + k] = C.img[c + k] }
            }
        }
    }

    private static func inpaint(_ L0: InpaintLevel) {
        var levels = [L0]
        while levels.count < 10 {
            let c = levels.last!
            if holeExtent(c) <= 2 * R + 2 { break }                 // hole is small at this scale
            if min(c.w, c.h) / 2 < 4 * R + 4 { break }              // too small to shrink further
            levels.append(downsample(c))
        }
        var prev: PatchMatch?
        for li in stride(from: levels.count - 1, through: 0, by: -1) {
            let L = levels[li]
            let coarsest = li == levels.count - 1
            if coarsest { onionInit(L) } else { upsampleInit(L, from: levels[li + 1]) }
            let pm = PatchMatch(L)
            guard !pm.sources.isEmpty, !pm.targets.isEmpty else { prev = nil; continue }
            pm.initNNF(from: prev, coarse: coarsest ? nil : levels[li + 1])
            let emIterations = coarsest ? 8 : (li == 0 ? 2 : 4)
            let searchIterations = li == 0 ? 3 : 5
            for it in 0..<emIterations {
                pm.search(searchIterations)
                // last pass at full size: take each pixel from its single best patch (keeps edges sharp)
                pm.vote(sharp: li == 0 && it == emIterations - 1)
            }
            prev = pm
        }
    }
}

// MARK: - PatchMatch nearest-neighbour field for one scale

final class PatchMatch {
    let L: InpaintLevel
    let w: Int, h: Int
    let R = SmartErase.R
    var targets: [Int32] = []        // patch centers whose patch touches the hole
    var tIndex: [Int32] = []         // pixel → index in `targets`, or -1
    var valid: [Bool] = []           // pixel is the center of a patch fully outside the hole
    var sources: [Int32] = []
    var nnf: [Int32] = []            // best source center for each target
    var nnd: [Float] = []            // its distance
    private var seed: UInt64 = 0x9E37_79B9_7F4A_7C15

    @inline(__always) private func rnd(_ n: Int) -> Int {
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
        return Int(seed % UInt64(n))
    }

    init(_ L: InpaintLevel) {
        self.L = L
        let W = L.w, H = L.h
        w = W; h = H
        // integral image of the hole mask
        var integ = [Int32](repeating: 0, count: (W + 1) * (H + 1))
        for y in 0..<H {
            var row: Int32 = 0
            for x in 0..<W {
                row += L.hole[y * W + x] ? 1 : 0
                integ[(y + 1) * (W + 1) + x + 1] = integ[y * (W + 1) + x + 1] + row
            }
        }
        func holes(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int32 {   // [x0,x1) × [y0,y1)
            integ[y1 * (W + 1) + x1] - integ[y0 * (W + 1) + x1] - integ[y1 * (W + 1) + x0] + integ[y0 * (W + 1) + x0]
        }
        let r = SmartErase.R
        var v = [Bool](repeating: false, count: W * H)
        var ti = [Int32](repeating: -1, count: W * H)
        var src: [Int32] = [], tg: [Int32] = []
        for y in 0..<H {
            for x in 0..<W {
                let i = y * W + x
                if x >= r && y >= r && x < W - r && y < H - r && holes(x - r, y - r, x + r + 1, y + r + 1) == 0 {
                    v[i] = true
                    src.append(Int32(i))
                }
                if holes(max(0, x - r), max(0, y - r), min(W, x + r + 1), min(H, y + r + 1)) > 0 {
                    ti[i] = Int32(tg.count)
                    tg.append(Int32(i))
                }
            }
        }
        valid = v; tIndex = ti; sources = src; targets = tg
    }

    /// Sum of squared differences between the patch at target `t` and source `s`
    /// (stops early once it exceeds `cutoff`).
    @inline(__always) func distance(_ t: Int, _ s: Int, _ cutoff: Float) -> Float {
        let tx = t % w, ty = t / w, sx = s % w, sy = s / w
        let img = L.img
        var d: Float = 0
        for dy in -R...R {
            let ty2 = ty + dy
            if ty2 < 0 || ty2 >= h { continue }
            let trow = ty2 * w, srow = (sy + dy) * w
            for dx in -R...R {
                let tx2 = tx + dx
                if tx2 < 0 || tx2 >= w { continue }
                let a = (trow + tx2) * 4, b = (srow + sx + dx) * 4
                let d0 = img[a] - img[b], d1 = img[a + 1] - img[b + 1]
                let d2 = img[a + 2] - img[b + 2], d3 = img[a + 3] - img[b + 3]
                d += d0 * d0 + d1 * d1 + d2 * d2 + d3 * d3
            }
            if d >= cutoff { return d }
        }
        return d
    }

    func initNNF(from prev: PatchMatch?, coarse C: InpaintLevel?) {
        nnf = [Int32](repeating: 0, count: targets.count)
        nnd = [Float](repeating: 0, count: targets.count)
        for k in targets.indices {
            let t = Int(targets[k])
            var s = -1
            if let p = prev, let C = C {
                // reuse the coarser scale's match, scaled up
                let x = t % w, y = t / w
                let cx = min(x / 2, C.w - 1), cy = min(y / 2, C.h - 1)
                let ck = p.tIndex[cy * C.w + cx]
                if ck >= 0 {
                    let cs = Int(p.nnf[Int(ck)])
                    let sx = (cs % C.w) * 2 + (x & 1), sy = (cs / C.w) * 2 + (y & 1)
                    if sx < w && sy < h && valid[sy * w + sx] { s = sy * w + sx }
                }
            }
            if s < 0 { s = Int(sources[rnd(sources.count)]) }
            nnf[k] = Int32(s)
            nnd[k] = distance(t, s, .infinity)
        }
    }

    @inline(__always) private func tryCandidate(_ t: Int, _ cx: Int, _ cy: Int, _ best: inout Int, _ bestD: inout Float) {
        if cx < 0 || cy < 0 || cx >= w || cy >= h { return }
        let c = cy * w + cx
        if c == best || !valid[c] { return }
        let d = distance(t, c, bestD)
        if d < bestD { best = c; bestD = d }
    }

    /// PatchMatch: propagate good matches from neighbours, then random search around the best.
    func search(_ iterations: Int) {
        let n = targets.count
        for it in 0..<iterations {
            let forward = it % 2 == 0
            let step = forward ? 1 : -1
            var k = forward ? 0 : n - 1
            while forward ? k < n : k >= 0 {
                let t = Int(targets[k])
                let x = t % w, y = t / w
                var best = Int(nnf[k]), bestD = nnd[k]
                // propagation: the neighbour before us (left / above, or right / below on reverse passes)
                let nx = x - step, ny = y - step
                if nx >= 0 && nx < w {
                    let ni = tIndex[y * w + nx]
                    if ni >= 0 { let ns = Int(nnf[Int(ni)]); tryCandidate(t, ns % w + step, ns / w, &best, &bestD) }
                }
                if ny >= 0 && ny < h {
                    let ni = tIndex[ny * w + x]
                    if ni >= 0 { let ns = Int(nnf[Int(ni)]); tryCandidate(t, ns % w, ns / w + step, &best, &bestD) }
                }
                // random search in shrinking windows around the current best
                var rad = max(w, h)
                while rad >= 1 {
                    let bx = best % w, by = best / w
                    tryCandidate(t, bx + rnd(2 * rad + 1) - rad, by + rnd(2 * rad + 1) - rad, &best, &bestD)
                    rad /= 2
                }
                nnf[k] = Int32(best); nnd[k] = bestD
                k += step
            }
        }
    }

    /// Each hole pixel becomes the weighted average of what all overlapping matched patches say
    /// (or, when `sharp`, the value from the best-matching patch that covers it).
    func vote(sharp: Bool = false) {
        let n = targets.count
        let area = Float((2 * R + 1) * (2 * R + 1) * 4)
        var md = nnd.map { $0 / area }
        let sorted = md.sorted()
        let sigma2 = max(sorted[min(sorted.count - 1, sorted.count * 3 / 4)], 1)
        for k in 0..<n { md[k] = expf(-md[k] / (2 * sigma2)) }

        let img = L.img
        if sharp {
            var bestW = [Float](repeating: -1, count: w * h)
            var bestSrc = [Int32](repeating: -1, count: w * h)
            for k in 0..<n {
                let t = Int(targets[k]), s = Int(nnf[k])
                let tx = t % w, ty = t / w, sx = s % w, sy = s / w
                let wt = md[k]
                for dy in -R...R {
                    let qy = ty + dy
                    if qy < 0 || qy >= h { continue }
                    for dx in -R...R {
                        let qx = tx + dx
                        if qx < 0 || qx >= w { continue }
                        let q = qy * w + qx
                        if !L.hole[q] || wt <= bestW[q] { continue }
                        bestW[q] = wt
                        bestSrc[q] = Int32((sy + dy) * w + sx + dx)
                    }
                }
            }
            for q in 0..<(w * h) where L.hole[q] && bestSrc[q] >= 0 {
                let src = Int(bestSrc[q]) * 4
                for c in 0..<4 { img[q * 4 + c] = img[src + c] }
            }
            return
        }
        var acc = [Float](repeating: 0, count: w * h * 4)
        var wsum = [Float](repeating: 0, count: w * h)
        for k in 0..<n {
            let t = Int(targets[k]), s = Int(nnf[k])
            let tx = t % w, ty = t / w, sx = s % w, sy = s / w
            let wt = md[k]
            for dy in -R...R {
                let qy = ty + dy
                if qy < 0 || qy >= h { continue }
                for dx in -R...R {
                    let qx = tx + dx
                    if qx < 0 || qx >= w { continue }
                    let q = qy * w + qx
                    if !L.hole[q] { continue }
                    let src = ((sy + dy) * w + sx + dx) * 4
                    acc[q * 4] += wt * img[src]; acc[q * 4 + 1] += wt * img[src + 1]
                    acc[q * 4 + 2] += wt * img[src + 2]; acc[q * 4 + 3] += wt * img[src + 3]
                    wsum[q] += wt
                }
            }
        }
        for q in 0..<(w * h) where L.hole[q] && wsum[q] > 0 {
            let inv = 1 / wsum[q]
            for c in 0..<4 { img[q * 4 + c] = acc[q * 4 + c] * inv }
        }
    }
}
