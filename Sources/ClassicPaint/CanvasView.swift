import Cocoa

final class Selection {
    var x: Int, y: Int
    var w: Int, h: Int
    var path: CGPath?          // free-form / ellipse outline, local coordinates
    var evenOdd = false        // path is "everything except a shape" (Invert Selection)
    var invertedFrom: Selection?   // the shape this inverted selection came from
    var content: Bitmap?       // non-nil once the selection is "floating"

    init(x: Int, y: Int, w: Int, h: Int, path: CGPath? = nil) {
        self.x = x; self.y = y; self.w = w; self.h = h; self.path = path
    }
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    func contains(_ p: IPoint) -> Bool { p.x >= x && p.y >= y && p.x < x + w && p.y < y + h }
}

final class PaintTextView: NSTextView {
    override func cancelOperation(_ sender: Any?) { appDelegate.canvas.commitText() }
}

final class CanvasView: NSView {
    let pad: CGFloat = 3
    var zoom: CGFloat = 1

    var doc: PaintDocument { appDelegate.doc }
    var bmp: Bitmap { appDelegate.doc.bitmap }

    private var btn = 0
    private var start = IPoint(x: 0, y: 0)
    private var last = IPoint(x: 0, y: 0)
    private var dragging = false
    private var base: Bitmap?
    private var airTimer: Timer?
    private var airPoint = IPoint(x: 0, y: 0)
    private var airColor = RGB.black

    private(set) var selection: Selection? {
        didSet { appDelegate?.main?.toolbox.needsDisplay = true }
    }
    private var marquee: CGRect?
    private var lasso: [IPoint] = []
    private var movingSel = false
    private var moveOff = IPoint(x: 0, y: 0)

    private var curveStage = 0
    private var curvePts: [IPoint] = []
    private var curveColor = RGB.black

    private var poly: [IPoint] = []
    private var polyActive = false
    private var polyFg = RGB.black
    private var polyBg = RGB.white

    private var textView: PaintTextView?
    private var textRect = CGRect.zero

    private var resizeMode = 0
    private var resizeSize = IPoint(x: 0, y: 0)
    private var hover: IPoint?
    private var tracking: NSTrackingArea?
    private var selHandle = -1                 // selection stretch handle being dragged (0..7)
    private var selOrig = (l: 0, t: 0, r: 0, b: 0)
    private var selOrigContent: Bitmap?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var fg: RGB { btn == 0 ? ps.primary : ps.secondary }
    private var bg: RGB { btn == 0 ? ps.secondary : ps.primary }

    // MARK: Geometry

    var imageFrame: NSRect {
        NSRect(x: pad, y: pad, width: CGFloat(bmp.width) * zoom, height: CGFloat(bmp.height) * zoom)
    }
    func viewRect(_ r: CGRect) -> NSRect {
        NSRect(x: pad + r.minX * zoom, y: pad + r.minY * zoom, width: r.width * zoom, height: r.height * zoom)
    }
    private func imagePoint(_ e: NSEvent) -> IPoint {
        let p = convert(e.locationInWindow, from: nil)
        return IPoint(x: Int(floor((p.x - pad) / zoom)), y: Int(floor((p.y - pad) / zoom)))
    }
    private func normRect(_ a: IPoint, _ b: IPoint, clamp: Bool) -> CGRect {
        var x0 = min(a.x, b.x), y0 = min(a.y, b.y), x1 = max(a.x, b.x), y1 = max(a.y, b.y)
        if clamp {
            x0 = max(0, x0); y0 = max(0, y0)
            x1 = min(bmp.width - 1, x1); y1 = min(bmp.height - 1, y1)
        }
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0 + 1), height: max(0, y1 - y0 + 1))
    }
    private func handleRects() -> [(Int, NSRect)] {
        let f = imageFrame, s: CGFloat = 4
        return [(1, NSRect(x: f.maxX, y: (f.midY - s / 2).rounded(), width: s, height: s)),
                (2, NSRect(x: (f.midX - s / 2).rounded(), y: f.maxY, width: s, height: s)),
                (3, NSRect(x: f.maxX, y: f.maxY, width: s, height: s))]
    }

    /// The 8 stretch handles around a selection, like Paint: TL, T, TR, R, BR, B, BL, L
    private func selectionHandleRects() -> [NSRect] {
        guard let s = selection, !dragging || selHandle >= 0 else { return [] }
        let r = viewRect(s.rect), k: CGFloat = 5
        let xs = [r.minX - k, r.midX - k / 2, r.maxX], ys = [r.minY - k, r.midY - k / 2, r.maxY]
        let idx = [(0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1)]
        return idx.map { NSRect(x: xs[$0.0].rounded(), y: ys[$0.1].rounded(), width: k, height: k) }
    }

    private func selectionHandleHit(_ vp: NSPoint) -> Int {
        for (i, r) in selectionHandleRects().enumerated() where r.insetBy(dx: -3, dy: -3).contains(vp) { return i }
        return -1
    }

    func updateSize() {
        let iw = max(bmp.width, resizeMode != 0 ? resizeSize.x : 0)
        let ih = max(bmp.height, resizeMode != 0 ? resizeSize.y : 0)
        let w = CGFloat(iw) * zoom + pad * 2 + 14
        let h = CGFloat(ih) * zoom + pad * 2 + 14
        let clip = enclosingScrollView?.contentSize ?? .zero
        let ns = NSSize(width: max(w, clip.width), height: max(h, clip.height))
        if frame.size != ns { setFrameSize(ns) }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: Cursors

    static let cursors: [Tool: NSCursor] = {
        func mk(_ t: Tool, _ hx: CGFloat, _ hy: CGFloat) -> NSCursor {
            let img = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
                drawToolIcon(t, at: .zero); return true
            }
            return NSCursor(image: img, hotSpot: NSPoint(x: hx, y: hy))
        }
        return [.pencil: mk(.pencil, 1, 15), .fill: mk(.fill, 13, 14),
                .picker: mk(.picker, 1, 14), .magnifier: mk(.magnifier, 6, 5),
                .brush: mk(.brush, 1, 15), .airbrush: mk(.airbrush, 1, 1)]
    }()

    override func resetCursorRects() {
        let cur = CanvasView.cursors[ps.tool] ?? .crosshair
        addCursorRect(imageFrame.intersection(visibleRect), cursor: cur)
        if let s = selection { addCursorRect(viewRect(s.rect), cursor: .openHand) }
        for (i, r) in selectionHandleRects().enumerated() {
            let c: NSCursor = (i == 1 || i == 5) ? .resizeUpDown : ((i == 3 || i == 7) ? .resizeLeftRight : .crosshair)
            addCursorRect(r.insetBy(dx: -3, dy: -3), cursor: c)
        }
        for (k, r) in handleRects() {
            addCursorRect(r.insetBy(dx: -2, dy: -2), cursor: k == 1 ? .resizeLeftRight : (k == 2 ? .resizeUpDown : .crosshair))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if tracking == nil {
            let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                   owner: self, userInfo: nil)
            addTrackingArea(t); tracking = t
        }
    }

    // MARK: Drawing

    private func drawImage(_ img: CGImage, _ r: NSRect, _ g: CGContext) {
        g.saveGState()
        g.translateBy(x: r.minX, y: r.maxY)
        g.scaleBy(x: 1, y: -1)
        g.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        g.restoreGState()
    }

    private func dashedRect(_ r: NSRect, _ g: CGContext) {
        let rr = r.insetBy(dx: 0.5, dy: 0.5)
        g.saveGState()
        g.setLineWidth(1)
        g.setStrokeColor(CGColor(gray: 1, alpha: 1)); g.stroke(rr)
        g.setStrokeColor(W95.navy.cgColor); g.setLineDash(phase: 0, lengths: [3, 3]); g.stroke(rr)
        g.restoreGState()
    }

    private func displayImage(_ s: Selection) -> CGImage? {
        guard let c = s.content else { return nil }
        if !ps.transparentSelect { return c.image() }
        let t = c.copy()
        let key = ps.secondary.packed
        for i in 0..<(t.width * t.height) where t.px[i] == key { t.px[i] = 0 }
        return t.image()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        NSGraphicsContext.current?.shouldAntialias = false
        W95.shadow.setFill(); dirtyRect.fill()
        // crisp pixels when zoomed in, smooth when zoomed out below 100%
        g.interpolationQuality = zoom < 1 ? .medium : .none
        let f = imageFrame
        CanvasView.checker.setFill(); f.fill()      // shows through transparent pixels
        drawImage(bmp.image(), f, g)
        if let s = selection, let img = displayImage(s) { drawImage(img, viewRect(s.rect), g) }

        if ps.showGrid && zoom >= 4 {
            NSColor(white: 0.55, alpha: 1).setFill()
            let d = dirtyRect.intersection(f)
            if !d.isEmpty {
                var x = f.minX + floor((d.minX - f.minX) / zoom) * zoom
                while x <= d.maxX { NSRect(x: x, y: d.minY, width: 1, height: d.height).fill(); x += zoom }
                var y = f.minY + floor((d.minY - f.minY) / zoom) * zoom
                while y <= d.maxY { NSRect(x: d.minX, y: y, width: d.width, height: 1).fill(); y += zoom }
            }
        }

        if let h = hover, ps.tool == .eraser {
            let n = ps.eraserSize
            let r = viewRect(CGRect(x: h.x - n / 2, y: h.y - n / 2, width: n, height: n))
            ps.secondary.ns.setFill(); r.fill()
            NSColor.black.setStroke(); NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }

        if let m = marquee {
            dashedRect(viewRect(m), g)
        }
        if lasso.count > 1 {
            g.saveGState()
            g.setLineWidth(1); g.setStrokeColor(W95.navy.cgColor); g.setLineDash(phase: 0, lengths: [3, 3])
            g.addLines(between: lasso.map { CGPoint(x: pad + (CGFloat($0.x) + 0.5) * zoom, y: pad + (CGFloat($0.y) + 0.5) * zoom) })
            g.strokePath()
            g.restoreGState()
        }
        if let s = selection {
            dashedRect(viewRect(s.rect), g)
            if let p = s.path, s.content == nil { dashedPath(p, at: s.rect.origin, g) }   // the actual shape
            for r in selectionHandleRects() {
                NSColor.white.setFill(); r.fill()
                W95.navy.setStroke(); NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
            }
        }
        if textView != nil { dashedRect(viewRect(textRect).insetBy(dx: -1, dy: -1), g) }

        for (_, r) in handleRects() { W95.navy.setFill(); r.fill() }
        if resizeMode != 0 {
            dashedRect(viewRect(CGRect(x: 0, y: 0, width: resizeSize.x, height: resizeSize.y)), g)
        }
    }

    // MARK: Status

    private func showCoord(_ p: IPoint?) {
        if let p = p, bmp.inside(p.x, p.y) { ps.setStatus(coord: "\(p.x),\(p.y)") } else { ps.setStatus(coord: "") }
    }

    override func mouseMoved(with e: NSEvent) {
        let p = imagePoint(e)
        hover = bmp.inside(p.x, p.y) ? p : nil
        showCoord(hover)
        if ps.tool == .eraser { needsDisplay = true }
    }
    override func mouseExited(with e: NSEvent) {
        hover = nil; showCoord(nil)
        if ps.tool == .eraser { needsDisplay = true }
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) { press(e, e.modifierFlags.contains(.control) ? 1 : 0) }
    override func rightMouseDown(with e: NSEvent) { press(e, 1) }
    override func mouseDragged(with e: NSEvent) { drag(e) }
    override func rightMouseDragged(with e: NSEvent) { drag(e) }
    override func mouseUp(with e: NSEvent) { release(e) }
    override func rightMouseUp(with e: NSEvent) { release(e) }

    private func constrainLine(_ a: IPoint, _ b: IPoint) -> IPoint {
        let dx = b.x - a.x, dy = b.y - a.y, adx = abs(dx), ady = abs(dy)
        if adx > 2 * ady { return IPoint(x: b.x, y: a.y) }
        if ady > 2 * adx { return IPoint(x: a.x, y: b.y) }
        let m = max(adx, ady)
        return IPoint(x: a.x + (dx < 0 ? -m : m), y: a.y + (dy < 0 ? -m : m))
    }
    private func constrainSquare(_ a: IPoint, _ b: IPoint) -> IPoint {
        let dx = b.x - a.x, dy = b.y - a.y, m = max(abs(dx), abs(dy))
        return IPoint(x: a.x + (dx < 0 ? -m : m), y: a.y + (dy < 0 ? -m : m))
    }

    private func press(_ e: NSEvent, _ b: Int) {
        if textView != nil { commitText(); return }
        window?.makeFirstResponder(self)
        if dragging { return }
        let vp = convert(e.locationInWindow, from: nil)
        if b == 0, (ps.tool == .select || ps.tool == .freeSelect), let s = selection {
            let hi = selectionHandleHit(vp)
            if hi >= 0 {
                if s.content == nil { liftSelection() }
                selHandle = hi
                selOrig = (s.x, s.y, s.x + s.w, s.y + s.h)
                selOrigContent = s.content
                s.path = nil
                btn = b
                dragging = true
                return
            }
        }
        if b == 0, let h = handleRects().first(where: { $0.1.insetBy(dx: -2, dy: -2).contains(vp) }) {
            commitAll()
            resizeMode = h.0
            resizeSize = IPoint(x: bmp.width, y: bmp.height)
            dragging = true
            return
        }

        btn = b
        let p = imagePoint(e)
        start = p; last = p
        dragging = true

        switch ps.tool {
        case .pencil:
            doc.pushUndo(); bmp.set(p.x, p.y, fg.packed)
        case .brush:
            doc.pushUndo(); bmp.stampLine(p.x, p.y, p.x, p.y, ps.brushStamp, fg.packed)
        case .eraser:
            doc.pushUndo(); erase(p, p)
        case .fill:
            doc.pushUndo(); bmp.floodFill(p.x, p.y, fg.packed); dragging = false
        case .picker:
            if bmp.inside(p.x, p.y) {
                let c = RGB(packed: bmp.get(p.x, p.y))
                if b == 0 { ps.primary = c } else { ps.secondary = c }
            }
            dragging = false
            ps.setTool(ps.prevTool)
        case .magnifier:
            dragging = false
            setZoom(zoom > 1 ? 1 : 4, center: p)
            ps.setTool(ps.prevTool)
        case .airbrush:
            doc.pushUndo()
            airPoint = p; airColor = fg
            spray()
            let t = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in self?.spray() }
            RunLoop.main.add(t, forMode: .common)
            airTimer = t
        case .line, .rectangle, .ellipse, .roundRect:
            doc.pushUndo(); base = bmp.copy()
            if ps.tool == .line { bmp.stampLine(p.x, p.y, p.x, p.y, ps.lineStamp, fg.packed) }
        case .curve:
            if curveStage == 0 {
                doc.pushUndo(); base = bmp.copy(); curveColor = fg
                curvePts = [p, p, p, p]
            } else if curveStage == 1 {
                curvePts[2] = p; curvePts[3] = p
            } else {
                curvePts[3] = p
            }
            renderCurve()
        case .polygon:
            if !polyActive {
                doc.pushUndo(); base = bmp.copy()
                polyActive = true; polyFg = fg; polyBg = bg
                poly = [p, p]
            } else {
                if e.clickCount >= 2 { dragging = false; finishPolygon(); return }
                poly.append(p)
            }
            renderPolygon()
        case .select, .freeSelect:
            if let s = selection, s.contains(p) {
                let copyMode = e.modifierFlags.contains(.option)
                if s.content == nil {
                    if copyMode { doc.pushUndo(); s.content = extract(s) } else { liftSelection() }
                } else if copyMode, let img = displayImage(s) {
                    bmp.draw(img, in: s.rect)
                }
                movingSel = true
                moveOff = IPoint(x: p.x - s.x, y: p.y - s.y)
            } else {
                commitSelection()
                movingSel = false
                if ps.tool == .select { marquee = normRect(p, p, clamp: false) } else { lasso = [clampPt(p)] }
            }
        case .text:
            commitSelection()
            marquee = normRect(p, p, clamp: false)
        }
        showCoord(p)
        needsDisplay = true
    }

    private func clampPt(_ p: IPoint) -> IPoint {
        IPoint(x: min(max(0, p.x), bmp.width - 1), y: min(max(0, p.y), bmp.height - 1))
    }

    private func drag(_ e: NSEvent) {
        guard dragging else { return }
        autoscroll(with: e)
        if resizeMode != 0 {
            let vp = convert(e.locationInWindow, from: nil)
            var w = bmp.width, h = bmp.height
            if resizeMode == 1 || resizeMode == 3 { w = max(1, Int(((vp.x - pad) / zoom).rounded())) }
            if resizeMode == 2 || resizeMode == 3 { h = max(1, Int(((vp.y - pad) / zoom).rounded())) }
            resizeSize = IPoint(x: w, y: h)
            ps.setStatus(size: "\(w)x\(h)")
            updateSize()
            return
        }
        if selHandle >= 0, let s = selection, let orig = selOrigContent {
            let vp = convert(e.locationInWindow, from: nil)
            let rx = Int(((vp.x - pad) / zoom).rounded()), ry = Int(((vp.y - pad) / zoom).rounded())
            var (l, t, r, b) = selOrig
            if [0, 6, 7].contains(selHandle) { l = min(rx, selOrig.r - 1) }
            if [2, 3, 4].contains(selHandle) { r = max(rx, selOrig.l + 1) }
            if [0, 1, 2].contains(selHandle) { t = min(ry, selOrig.b - 1) }
            if [4, 5, 6].contains(selHandle) { b = max(ry, selOrig.t + 1) }
            let w = r - l, h = b - t
            if w != s.w || h != s.h { s.content = orig.scaled(to: w, h) }
            s.x = l; s.y = t; s.w = w; s.h = h
            ps.setStatus(size: "\(w)x\(h)")
            needsDisplay = true
            return
        }
        let shift = e.modifierFlags.contains(.shift)
        let p = imagePoint(e)

        switch ps.tool {
        case .pencil:
            let c = fg.packed
            bresenham(last.x, last.y, p.x, p.y) { x, y in self.bmp.set(x, y, c) }
        case .brush:
            bmp.stampLine(last.x, last.y, p.x, p.y, ps.brushStamp, fg.packed)
        case .eraser:
            erase(last, p)
            hover = p
        case .airbrush:
            airPoint = p
            spray()
        case .line:
            if let b = base { bmp.restore(from: b) }
            let q = shift ? constrainLine(start, p) : p
            bmp.stampLine(start.x, start.y, q.x, q.y, ps.lineStamp, fg.packed)
            ps.setStatus(size: "\(abs(q.x - start.x) + 1)x\(abs(q.y - start.y) + 1)")
        case .rectangle, .ellipse, .roundRect:
            if let b = base { bmp.restore(from: b) }
            let q = shift ? constrainSquare(start, p) : p
            drawShape(start, q)
            ps.setStatus(size: "\(abs(q.x - start.x) + 1)x\(abs(q.y - start.y) + 1)")
        case .curve:
            if curveStage == 0 { curvePts[1] = p } else if curveStage == 1 { curvePts[2] = p; curvePts[3] = p } else { curvePts[3] = p }
            renderCurve()
        case .polygon:
            if poly.count >= 2 {
                poly[poly.count - 1] = shift ? constrainLine(poly[poly.count - 2], p) : p
            }
            renderPolygon()
        case .select, .freeSelect:
            if movingSel, let s = selection {
                if shift, let img = displayImage(s) { bmp.draw(img, in: s.rect) }   // "smear" like Paint
                s.x = p.x - moveOff.x; s.y = p.y - moveOff.y
            } else if ps.tool == .select {
                marquee = normRect(start, p, clamp: true)
                ps.setStatus(size: "\(Int(marquee!.width))x\(Int(marquee!.height))")
            } else {
                let q = clampPt(p)
                if lasso.last != q { lasso.append(q) }
            }
        case .text:
            marquee = normRect(start, p, clamp: true)
        case .fill, .picker, .magnifier:
            break
        }
        last = p
        showCoord(p)
        needsDisplay = true
    }

    private func release(_ e: NSEvent) {
        guard dragging else { return }
        dragging = false
        if selHandle >= 0 {
            selHandle = -1; selOrigContent = nil
            ps.setStatus(size: "")
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            return
        }
        if resizeMode != 0 {
            let s = resizeSize
            resizeMode = 0
            resizeCanvas(s.x, s.y)
            ps.setStatus(size: "")
            updateSize()
            return
        }
        switch ps.tool {
        case .airbrush:
            airTimer?.invalidate(); airTimer = nil
        case .line, .rectangle, .ellipse, .roundRect:
            base = nil
        case .curve:
            if curveStage == 0 { curvePts[2] = curvePts[0]; curvePts[3] = curvePts[1] }
            curveStage += 1
            if curveStage >= 3 { curveStage = 0; base = nil }
        case .polygon:
            if poly.count >= 3, let f = poly.first, let l = poly.last, abs(f.x - l.x) <= 2 && abs(f.y - l.y) <= 2 {
                poly.removeLast()
                finishPolygon()
            }
        case .select:
            if !movingSel, let m = marquee, m.width > 0, m.height > 0, start != last {
                selection = Selection(x: Int(m.minX), y: Int(m.minY), w: Int(m.width), h: Int(m.height))
            }
            marquee = nil
        case .freeSelect:
            if !movingSel && lasso.count >= 3 {
                let minX = lasso.map { $0.x }.min()!, maxX = lasso.map { $0.x }.max()!
                let minY = lasso.map { $0.y }.min()!, maxY = lasso.map { $0.y }.max()!
                if maxX > minX && maxY > minY {
                    let path = CGMutablePath()
                    path.addLines(between: lasso.map { CGPoint(x: CGFloat($0.x - minX) + 0.5, y: CGFloat($0.y - minY) + 0.5) })
                    path.closeSubpath()
                    selection = Selection(x: minX, y: minY, w: maxX - minX + 1, h: maxY - minY + 1, path: path)
                }
            }
            lasso = []
        case .text:
            if let m = marquee {
                var r = m
                if r.width < 20 || r.height < 12 {
                    r = CGRect(x: m.minX, y: m.minY,
                               width: min(160, CGFloat(bmp.width) - m.minX),
                               height: min(ceil(ps.textFont.pointSize * 1.5) + 2, CGFloat(bmp.height) - m.minY))
                }
                marquee = nil
                if r.width >= 4 && r.height >= 4 { beginText(r) }
            }
        default:
            break
        }
        movingSel = false
        ps.setStatus(size: "")
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: Tool helpers

    private func erase(_ a: IPoint, _ b: IPoint) {
        let offs = Stamp.square(ps.eraserSize)
        if btn == 0 {
            bmp.stampLine(a.x, a.y, b.x, b.y, offs, ps.secondary.packed)
        } else {
            // Color eraser: replaces only the foreground color with the background color
            let from = ps.primary.packed, to = ps.secondary.packed
            let m = bmp
            bresenham(a.x, a.y, b.x, b.y) { x, y in
                for o in offs {
                    let xx = x + o.0, yy = y + o.1
                    if m.inside(xx, yy) && m.get(xx, yy) == from { m.set(xx, yy, to) }
                }
            }
        }
    }

    private func spray() {
        let r = Stamp.airRadius[ps.airIndex]
        let c = airColor.packed
        for _ in 0..<(r * 3) {
            let dx = Int.random(in: -r...r), dy = Int.random(in: -r...r)
            if dx * dx + dy * dy <= r * r { bmp.set(airPoint.x + dx, airPoint.y + dy, c) }
        }
        needsDisplay = true
    }

    private func strokePolyline(_ pts: [IPoint], closed: Bool, color: RGB) {
        guard !pts.isEmpty else { return }
        let st = ps.lineStamp, c = color.packed
        var all = pts
        if closed, let f = pts.first { all.append(f) }
        if all.count == 1 { bmp.stampLine(all[0].x, all[0].y, all[0].x, all[0].y, st, c); return }
        for i in 1..<all.count { bmp.stampLine(all[i - 1].x, all[i - 1].y, all[i].x, all[i].y, st, c) }
    }

    private func drawShape(_ a: IPoint, _ b: IPoint) {
        let x0 = min(a.x, b.x), y0 = min(a.y, b.y), x1 = max(a.x, b.x), y1 = max(a.y, b.y)
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        let lw = ps.lineWidth
        let style = ps.shapeStyle
        let outline = style != 2
        let fillColor: RGB? = style == 0 ? nil : (style == 1 ? bg : fg)
        let m = bmp
        switch ps.tool {
        case .rectangle:
            if let f = fillColor { m.fillRect(x0, y0, w, h, f.packed) }
            if outline {
                let c = fg.packed, t = max(1, min(lw, min(w, h)))
                m.fillRect(x0, y0, w, t, c); m.fillRect(x0, y1 - t + 1, w, t, c)
                m.fillRect(x0, y0, t, h, c); m.fillRect(x1 - t + 1, y0, t, h, c)
            }
        case .ellipse, .roundRect:
            let r = CGRect(x: x0, y: y0, width: w, height: h)
            let inset = outline ? CGFloat(lw) / 2 : 0
            let rr = r.insetBy(dx: inset, dy: inset)
            guard rr.width > 0.5, rr.height > 0.5 else { m.fillRect(x0, y0, w, h, fg.packed); return }
            let path: CGPath
            if ps.tool == .ellipse {
                path = CGPath(ellipseIn: rr, transform: nil)
            } else {
                let rad = min(8, rr.width / 2, rr.height / 2)
                path = CGPath(roundedRect: rr, cornerWidth: rad, cornerHeight: rad, transform: nil)
            }
            if let f = fillColor { m.fillPath(path, f) }
            if outline { m.strokePath(path, fg, CGFloat(lw)) }
        default:
            break
        }
    }

    private func renderCurve() {
        guard let b = base, curvePts.count == 4 else { return }
        bmp.restore(from: b)
        if curveStage == 0 {
            strokePolyline([curvePts[0], curvePts[1]], closed: false, color: curveColor)
            return
        }
        let p0 = curvePts[0], p3 = curvePts[1], c1 = curvePts[2], c2 = curvePts[3]
        var pts: [IPoint] = []
        let n = 80
        for i in 0...n {
            let t = Double(i) / Double(n), mt = 1 - t
            let a = mt * mt * mt, bb = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
            let x = a * Double(p0.x) + bb * Double(c1.x) + c * Double(c2.x) + d * Double(p3.x)
            let y = a * Double(p0.y) + bb * Double(c1.y) + c * Double(c2.y) + d * Double(p3.y)
            let q = IPoint(x: Int(x.rounded()), y: Int(y.rounded()))
            if pts.last != q { pts.append(q) }
        }
        strokePolyline(pts, closed: false, color: curveColor)
    }

    private func renderPolygon() {
        guard let b = base else { return }
        bmp.restore(from: b)
        strokePolyline(poly, closed: false, color: polyFg)
    }

    private func finishPolygon() {
        guard polyActive else { return }
        if let b = base { bmp.restore(from: b) }
        var pts: [IPoint] = []
        for p in poly where pts.last != p { pts.append(p) }
        let style = ps.shapeStyle
        if style != 0 && pts.count >= 3 {
            let path = CGMutablePath()
            path.addLines(between: pts.map { CGPoint(x: CGFloat($0.x) + 0.5, y: CGFloat($0.y) + 0.5) })
            path.closeSubpath()
            bmp.fillPath(path, style == 1 ? polyBg : polyFg)
        }
        if style != 2 || pts.count < 3 { strokePolyline(pts, closed: true, color: polyFg) }
        polyActive = false; poly = []; base = nil
        needsDisplay = true
    }

    // MARK: Selection

    private func extract(_ s: Selection) -> Bitmap {
        let c = Bitmap(width: s.w, height: s.h, fill: nil)
        c.ctx.saveGState()
        if let p = s.path { c.ctx.addPath(p); c.ctx.clip(using: s.evenOdd ? .evenOdd : .winding) }
        c.draw(bmp.image(), in: CGRect(x: -s.x, y: -s.y, width: bmp.width, height: bmp.height))
        c.ctx.restoreGState()
        return c
    }

    private func liftSelection() {
        guard let s = selection, s.content == nil else { return }
        doc.pushUndo()
        s.content = extract(s)
        if let p = s.path {
            var t = CGAffineTransform(translationX: CGFloat(s.x), y: CGFloat(s.y))
            if let moved = p.copy(using: &t) { bmp.fillPath(moved, ps.secondary, evenOdd: s.evenOdd) }
        } else {
            bmp.fillRect(s.x, s.y, s.w, s.h, ps.secondary.packed)
        }
    }

    func commitSelection() {
        if let s = selection, let img = displayImage(s) { bmp.draw(img, in: s.rect) }
        selection = nil
        needsDisplay = true
    }

    /// Dashed outline of a selection shape (path in image coordinates relative to `origin`)
    private func dashedPath(_ p: CGPath, at origin: CGPoint, _ g: CGContext) {
        var t = CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom,
                                  tx: pad + origin.x * zoom, ty: pad + origin.y * zoom)
        guard let vp = p.copy(using: &t) else { return }
        g.saveGState()
        g.setLineWidth(1)
        g.addPath(vp); g.setStrokeColor(CGColor(gray: 1, alpha: 1)); g.strokePath()
        g.addPath(vp); g.setStrokeColor(W95.navy.cgColor); g.setLineDash(phase: 0, lengths: [3, 3]); g.strokePath()
        g.restoreGState()
    }

    /// Edit ▸ Invert Selection: select everything *except* the current shape
    /// (draw a circle, invert, Delete → keeps only the circle; or Crop → cut-out).
    func invertSelection() {
        commitText()
        guard let s = selection else { NSSound.beep(); return }
        if let inner = s.invertedFrom, s.content == nil {        // inverting twice → back to the shape
            selection = inner
            needsDisplay = true
            return
        }
        if s.content != nil {                                    // floating: drop it in place first
            let shape = Selection(x: s.x, y: s.y, w: s.w, h: s.h, path: s.path)
            commitSelection()
            selection = shape
        }
        guard let cur = selection else { return }
        let W = bmp.width, H = bmp.height
        let path = CGMutablePath()
        path.addRect(CGRect(x: 0, y: 0, width: W, height: H))
        var t = CGAffineTransform(translationX: CGFloat(cur.x), y: CGFloat(cur.y))
        if let p = cur.path, let moved = p.copy(using: &t) { path.addPath(moved) } else { path.addRect(cur.rect) }
        let inv = Selection(x: 0, y: 0, w: W, h: H, path: path)
        inv.evenOdd = true
        inv.invertedFrom = cur
        if ps.tool != .select && ps.tool != .freeSelect { ps.setTool(.select) }
        selection = inv
        needsDisplay = true
    }

    func selectionImage() -> CGImage? {
        guard let s = selection else { return nil }
        return (s.content ?? extract(s)).image()
    }

    func copySel() {
        guard let img = selectionImage() else { NSSound.beep(); return }
        let rep = NSBitmapImageRep(cgImage: img)
        let pb = NSPasteboard.general
        pb.clearContents()
        if let png = rep.representation(using: .png, properties: [:]) { pb.setData(png, forType: .png) }
        if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }

    func deleteSel() {
        guard let s = selection else { return }
        if s.content == nil { liftSelection() }
        selection = nil
        needsDisplay = true
    }

    func cutSel() { copySel(); deleteSel() }

    func selectAll() {
        commitAll()
        if ps.tool != .select { ps.setTool(.select) }
        selection = Selection(x: 0, y: 0, w: bmp.width, h: bmp.height)
        needsDisplay = true
    }

    func pasteImage(_ cg: CGImage) {
        commitAll()
        if ps.tool != .select && ps.tool != .freeSelect { ps.setTool(.select) }
        doc.pushUndo()
        let w = cg.width, h = cg.height
        if w > bmp.width || h > bmp.height {
            doc.bitmap = bmp.resizedCanvas(max(w, bmp.width), max(h, bmp.height), fill: ps.secondary)
            updateSize()
        }
        let c = Bitmap(width: w, height: h, fill: nil)
        c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let vr = visibleRect
        let sx = max(0, min(Int((vr.minX - pad) / zoom), bmp.width - w))
        let sy = max(0, min(Int((vr.minY - pad) / zoom), bmp.height - h))
        let s = Selection(x: sx, y: sy, w: w, h: h)
        s.content = c
        selection = s
        needsDisplay = true
    }

    func pasteFromPasteboard() {
        guard let img = NSImage(pasteboard: NSPasteboard.general),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { NSSound.beep(); return }
        pasteImage(cg)
    }

    // MARK: Text

    private func textAttrs(scale: CGFloat) -> [NSAttributedString.Key: Any] {
        let f = ps.textFont
        let sf = NSFont(descriptor: f.fontDescriptor, size: f.pointSize * scale) ?? f
        return [.font: sf, .foregroundColor: ps.primary.ns,
                .underlineStyle: ps.textUnderline ? NSUnderlineStyle.single.rawValue : 0]
    }

    private func beginText(_ r: CGRect) {
        let tv = PaintTextView(frame: viewRect(r))
        tv.isRichText = false
        tv.allowsUndo = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        textRect = r
        textView = tv
        styleTextView()
        addSubview(tv)
        window?.makeFirstResponder(tv)
        appDelegate.showFontToolbar()
    }

    func styleTextView() {
        guard let tv = textView else { return }
        let a = textAttrs(scale: zoom)
        tv.drawsBackground = !ps.transparentSelect
        tv.backgroundColor = ps.secondary.ns
        tv.insertionPointColor = ps.primary.ns
        tv.typingAttributes = a
        if let ts = tv.textStorage { ts.setAttributes(a, range: NSRange(location: 0, length: ts.length)) }
        tv.needsDisplay = true
    }

    func commitText() {
        guard let tv = textView else { return }
        let s = tv.string
        tv.removeFromSuperview()
        textView = nil
        if !s.isEmpty {
            doc.pushUndo()
            if !ps.transparentSelect {
                bmp.fillRect(Int(textRect.minX), Int(textRect.minY), Int(textRect.width), Int(textRect.height), ps.secondary.packed)
            }
            let m = bmp
            m.ctx.saveGState()
            m.ctx.clip(to: textRect)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: m.ctx, flipped: true)
            (s as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin], attributes: textAttrs(scale: 1))
            NSGraphicsContext.restoreGraphicsState()
            m.ctx.restoreGState()
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: Crop

    /// Crops the picture to the current selection (like modern Paint's Crop button).
    func cropToSelection() {
        commitText()
        guard let s = selection else {
            NSSound.beep()
            ps.statusText = "Select an area first, then click Crop."
            ps.setStatus()
            return
        }
        let content = s.content ?? extract(s)
        if s.content == nil { doc.pushUndo() }   // a floating selection already pushed undo when lifted
        let nb = Bitmap(width: content.width, height: content.height, fill: nil)
        nb.draw(content.image(), in: CGRect(x: 0, y: 0, width: content.width, height: content.height))
        selection = nil
        doc.bitmap = nb
        updateSize()
        scroll(.zero)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: Smart Erase

    private(set) var smartErasing = false

    /// Edit ▸ Smart Erase: fills the selected area from its surroundings instead of the
    /// background color (Delete keeps working as before).
    func smartErase() {
        commitText()
        guard !smartErasing else { return }
        guard let s0 = selection else {
            NSSound.beep()
            ps.statusText = "Select an area first, then use Smart Erase."
            ps.setStatus()
            return
        }
        // A moved (floating) selection is dropped where it is; the area under its outline is filled
        var shape = s0
        if s0.content != nil {
            let sh = Selection(x: s0.x, y: s0.y, w: s0.w, h: s0.h, path: s0.path)
            sh.evenOdd = s0.evenOdd
            commitSelection()
            shape = sh
        }
        let W = bmp.width, H = bmp.height

        // Rasterize the selection outline into a mask
        guard let mctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        mctx.translateBy(x: 0, y: CGFloat(H)); mctx.scaleBy(x: 1, y: -1)
        mctx.setShouldAntialias(false)
        mctx.setFillColor(gray: 1, alpha: 1)
        if let p = shape.path {
            var t = CGAffineTransform(translationX: CGFloat(shape.x), y: CGFloat(shape.y))
            if let moved = p.copy(using: &t) { mctx.addPath(moved); mctx.fillPath(using: shape.evenOdd ? .evenOdd : .winding) }
        } else {
            mctx.fill(shape.rect)
        }
        guard let mdata = mctx.data?.bindMemory(to: UInt8.self, capacity: W * H) else { return }
        var mask = [Bool](repeating: false, count: W * H)
        for i in 0..<(W * H) where mdata[i] > 127 { mask[i] = true }
        // grow by 2 px so soft edges of the removed object go too
        for _ in 0..<2 {
            var grown = mask
            for y in 0..<H { for x in 0..<W where mask[y * W + x] {
                if x > 0 { grown[y * W + x - 1] = true }
                if x < W - 1 { grown[y * W + x + 1] = true }
                if y > 0 { grown[(y - 1) * W + x] = true }
                if y < H - 1 { grown[(y + 1) * W + x] = true }
            } }
            mask = grown
        }

        selection = nil
        needsDisplay = true
        smartErasing = true
        let oldStatus = ps.statusText
        ps.statusText = "Smart Erase: filling from the surroundings…"
        ps.setStatus()
        let bitmap = bmp
        let pixels = Array(UnsafeBufferPointer(start: bitmap.px, count: W * H))
        DispatchQueue.global(qos: .userInitiated).async {
            var out = pixels
            let failure = out.withUnsafeMutableBufferPointer { SmartErase.fill($0.baseAddress!, width: W, height: H, mask: mask) }
            DispatchQueue.main.async {
                self.smartErasing = false
                ps.statusText = oldStatus
                ps.setStatus()
                switch failure {
                case .some(.tooLarge):
                    appDelegate.message("The selected area is too large for Smart Erase.", "Select a smaller area around the object you want to remove.")
                    return
                case .some(.noSurroundings):
                    appDelegate.message("There is not enough picture around the selection to fill it from.")
                    return
                case .some(.empty):
                    return
                case .none:
                    break
                }
                guard self.doc.bitmap === bitmap, bitmap.width == W, bitmap.height == H else { return }
                self.doc.pushUndo()
                for i in 0..<(W * H) where mask[i] { bitmap.px[i] = out[i] }
                self.needsDisplay = true
            }
        }
    }

    // MARK: Remove Background

    static let checker: NSColor = {
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 16, height: 16).fill()
            NSColor(white: 0.8, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 8, height: 8).fill(); NSRect(x: 8, y: 8, width: 8, height: 8).fill()
            return true
        }
        return NSColor(patternImage: img)
    }()

    /// Applies to the selection when there is one, otherwise to the whole picture.
    func removeBackground() {
        guard BackgroundRemover.isAvailable else {
            appDelegate.message("Remove Background requires macOS 14 (Sonoma) or later.")
            return
        }
        commitText()
        let target: Bitmap
        let onSelection: Bool
        if let s = selection {
            if s.content == nil { liftSelection() }
            guard let c = s.content else { return }
            target = c; onSelection = true
        } else {
            commitAll()
            target = bmp; onSelection = false
        }
        let img = target.image()
        let oldStatus = ps.statusText
        ps.statusText = "Removing background…"
        ps.setStatus()
        DispatchQueue.global(qos: .userInitiated).async {
            let mask = try? BackgroundRemover.mask(for: img)
            DispatchQueue.main.async {
                ps.statusText = oldStatus
                ps.setStatus()
                guard let mask = mask else {
                    appDelegate.message("ClassicPaint couldn't find a subject in the picture.",
                                        "Remove Background works best on photos with a clear foreground subject.")
                    return
                }
                if !onSelection { self.doc.pushUndo() }
                target.applyMask(mask)
                self.needsDisplay = true
            }
        }
    }

    // MARK: Whole-image operations

    func setZoom(_ z: CGFloat, center: IPoint?) {
        commitText()
        let v = visibleRect
        let c = center ?? IPoint(x: Int((v.midX - pad) / zoom), y: Int((v.midY - pad) / zoom))
        zoom = z
        updateSize()
        if let clip = enclosingScrollView?.contentView {
            let size = clip.bounds.size
            let x = pad + (CGFloat(c.x) + 0.5) * z - size.width / 2
            let y = pad + (CGFloat(c.y) + 0.5) * z - size.height / 2
            scroll(NSPoint(x: max(0, x), y: max(0, y)))
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        ps.notify()
    }

    // MARK: Zoom with keyboard / wheel / pinch

    static let zoomSteps: [CGFloat] = [0.125, 0.25, 1.0 / 3, 0.5, 2.0 / 3, 1, 2, 3, 4, 6, 8, 12, 16]
    private var wheelAccum: CGFloat = 0
    private var pinchAccum: CGFloat = 0

    /// One zoom step in (+1) or out (-1). With a point, that spot of the picture stays under it
    /// (mouse wheel / pinch); without one, the middle of the view stays put (keyboard).
    func zoomStep(_ dir: Int, at viewPoint: NSPoint? = nil) {
        let cur = zoom
        let next = dir > 0 ? CanvasView.zoomSteps.first { $0 > cur + 0.001 }
                           : CanvasView.zoomSteps.last { $0 < cur - 0.001 }
        guard let z = next else { return }
        let vr = visibleRect
        let vp = viewPoint ?? NSPoint(x: vr.midX, y: vr.midY)
        // picture coordinate under the anchor, and where the anchor sits inside the visible area
        let ix = (vp.x - pad) / zoom, iy = (vp.y - pad) / zoom
        let ox = vp.x - vr.minX, oy = vp.y - vr.minY
        commitText()
        zoom = z
        updateSize()
        scroll(NSPoint(x: max(0, pad + ix * z - ox), y: max(0, pad + iy * z - oy)))
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        ps.notify()
        ps.setStatus(size: "Zoom \(Int((z * 100).rounded()))%")
    }

    /// ⌘ or ⌃ + mouse wheel zooms (plain wheel scrolls as usual)
    override func scrollWheel(with e: NSEvent) {
        let f = e.modifierFlags.union(NSEvent.modifierFlags)   // also the keys held right now
        guard f.contains(.command) || f.contains(.control) else { super.scrollWheel(with: e); return }
        var d = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 12 : e.scrollingDeltaY
        if e.isDirectionInvertedFromDevice { d = -d }       // "natural scrolling": wheel up = zoom in either way
        wheelAccum += d
        let vp = convert(e.locationInWindow, from: nil)
        if wheelAccum >= 1 { wheelAccum = 0; zoomStep(+1, at: vp) }
        else if wheelAccum <= -1 { wheelAccum = 0; zoomStep(-1, at: vp) }
    }

    /// Trackpad pinch zooms around the fingers
    override func magnify(with e: NSEvent) {
        pinchAccum += e.magnification
        let vp = convert(e.locationInWindow, from: nil)
        if pinchAccum > 0.12 { pinchAccum = 0; zoomStep(+1, at: vp) }
        else if pinchAccum < -0.12 { pinchAccum = 0; zoomStep(-1, at: vp) }
        if e.phase == .ended || e.phase == .cancelled { pinchAccum = 0 }
    }

    func transformImage(_ f: (Bitmap) -> Bitmap) {
        commitAll()
        doc.pushUndo()
        doc.bitmap = f(bmp)
        updateSize()
        needsDisplay = true
    }

    /// Like Paint: Flip/Rotate/Stretch/Invert act on the selection when there is one.
    func transformImageOrSelection(_ f: (Bitmap) -> Bitmap) {
        commitText()
        if let s = selection {
            if s.content == nil { liftSelection() }
            guard let c = s.content else { return }
            let n = f(c)
            s.content = n; s.w = n.width; s.h = n.height; s.path = nil
            needsDisplay = true
        } else {
            transformImage(f)
        }
    }

    func resizeCanvas(_ w: Int, _ h: Int) {
        commitAll()
        guard w > 0, h > 0, w != bmp.width || h != bmp.height else { return }
        doc.pushUndo()
        doc.bitmap = bmp.resizedCanvas(w, h, fill: ps.secondary)
        updateSize()
    }

    func undo() {
        if textView != nil { cancelText(); return }
        cancelInteraction()
        if doc.undo() { updateSize() } else { NSSound.beep() }
        appDelegate.updateTitle()
        needsDisplay = true
    }

    func redo() {
        cancelInteraction()
        if doc.redo() { updateSize() } else { NSSound.beep() }
        appDelegate.updateTitle()
        needsDisplay = true
    }

    private func cancelText() {
        textView?.removeFromSuperview(); textView = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func cancelInteraction() {
        if textView != nil { cancelText() }
        airTimer?.invalidate(); airTimer = nil
        selection = nil; marquee = nil; lasso = []; movingSel = false; selHandle = -1; selOrigContent = nil
        polyActive = false; poly = []; curveStage = 0; base = nil
        dragging = false; resizeMode = 0
        needsDisplay = true
    }

    func commitAll() {
        commitText()
        if polyActive { finishPolygon() }
        if curveStage > 0 { curveStage = 0; base = nil }
        commitSelection()
        needsDisplay = true
    }

    /// Shows the current tab's picture, restoring its zoom and scroll position.
    func showDocument() {
        cancelInteraction()
        zoom = doc.zoom
        updateSize()
        scroll(doc.scrollOrigin)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        ps.notify()
    }

    func docChanged() {
        cancelInteraction()
        updateSize()
        scroll(.zero)
        needsDisplay = true
    }

    func toolChanged() {
        commitAll()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func stateChanged() {
        styleTextView()
        needsDisplay = true
    }

    // MARK: Keyboard

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case _ where (e.keyCode == 51 || e.keyCode == 117) && e.modifierFlags.contains(.option):
            smartErase()    // ⌥⌫: fill the selection from its surroundings
        case 51, 117:   // backspace / forward delete
            deleteSel()
        case 48 where e.modifierFlags.contains(.control):   // ⌃⇥ / ⌃⇧⇥ switch tabs
            if e.modifierFlags.contains(.shift) { appDelegate.previousTab(nil) } else { appDelegate.nextTab(nil) }
        case _ where e.modifierFlags.contains(.option) && !e.modifierFlags.contains(.command)
                        && appDelegate.main.showMenuBar && appDelegate.main.menuBar.openMenu(forKey: e):
            break
        case 53:        // escape
            if polyActive || curveStage > 0 {
                if let b = base { bmp.restore(from: b) }
                doc.dropLastUndo()
                polyActive = false; poly = []; curveStage = 0; base = nil
            } else {
                commitSelection()
            }
            needsDisplay = true
        case 123, 124, 125, 126:
            guard let s = selection else { super.keyDown(with: e); return }
            if s.content == nil { liftSelection() }
            switch e.keyCode {
            case 123: s.x -= 1
            case 124: s.x += 1
            case 125: s.y += 1
            default: s.y -= 1
            }
            needsDisplay = true
        default:
            super.keyDown(with: e)
        }
    }
}
