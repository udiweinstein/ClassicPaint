import Cocoa

// MARK: - Windows 9x look

enum W95 {
    static func rgb(_ v: CGFloat) -> NSColor { NSColor(srgbRed: v / 255, green: v / 255, blue: v / 255, alpha: 1) }
    static let face = rgb(192)
    static let light = rgb(223)
    static let shadow = rgb(128)
    static let white = NSColor.white
    static let black = NSColor.black
    static let navy = NSColor(srgbRed: 0, green: 0, blue: 128 / 255, alpha: 1)
    static let teal = NSColor(srgbRed: 0, green: 128 / 255, blue: 128 / 255, alpha: 1)
    static let font = NSFont(name: "Tahoma", size: 11) ?? NSFont.systemFont(ofSize: 11)

    static func fill(_ r: NSRect, _ c: NSColor) { c.setFill(); r.fill() }

    static func edge(_ r: NSRect, _ tl: NSColor, _ br: NSColor) {
        fill(NSRect(x: r.minX, y: r.minY, width: r.width - 1, height: 1), tl)
        fill(NSRect(x: r.minX, y: r.minY, width: 1, height: r.height - 1), tl)
        fill(NSRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1), br)
        fill(NSRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height), br)
    }

    /// Draws a classic 3D bevel. Views using it must be flipped.
    static func bevel(_ r: NSRect, raised: Bool, thin: Bool = false) {
        if thin {
            edge(r, raised ? white : shadow, raised ? shadow : white)
            return
        }
        edge(r, raised ? white : shadow, raised ? black : white)
        edge(r.insetBy(dx: 1, dy: 1), raised ? light : black, raised ? shadow : light)
    }

    /// The checkered pattern of a pressed toolbar button
    static func dither(_ r: NSRect) {
        fill(r, face)
        white.setFill()
        var y = r.minY, row = 0
        while y < r.maxY {
            var x = r.minX + CGFloat(row % 2)
            while x < r.maxX { NSRect(x: x, y: y, width: 1, height: 1).fill(); x += 2 }
            y += 1; row += 1
        }
    }

    static func text(_ s: String, in r: NSRect, color: NSColor = .black, center: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (s as NSString).size(withAttributes: attrs)
        let x = center ? r.midX - size.width / 2 : r.minX
        (s as NSString).draw(at: NSPoint(x: x, y: r.midY - size.height / 2), withAttributes: attrs)
    }
}

// MARK: - Tool icons (16x16, drawn in a flipped context)

func drawToolIcon(_ t: Tool, at o: NSPoint) {
    NSGraphicsContext.current?.shouldAntialias = false
    func P(_ pts: [(CGFloat, CGFloat)], close: Bool = false) -> NSBezierPath {
        let p = NSBezierPath()
        for (i, q) in pts.enumerated() {
            let pt = NSPoint(x: o.x + q.0 + 0.5, y: o.y + q.1 + 0.5)
            if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
        }
        if close { p.close() }
        p.lineWidth = 1
        return p
    }
    func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: NSColor) {
        c.setFill(); NSRect(x: o.x + x, y: o.y + y, width: w, height: h).fill()
    }
    func dashed(_ p: NSBezierPath) {
        NSColor.white.setStroke(); p.stroke()
        var pat: [CGFloat] = [2, 2]
        p.setLineDash(&pat, count: 2, phase: 0)
        NSColor.black.setStroke(); p.stroke()
    }
    let k = NSColor.black
    let blue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
    switch t {
    case .freeSelect:
        dashed(P([(3, 1), (9, 3), (14, 1), (12, 8), (14, 14), (7, 11), (1, 14), (3, 7)], close: true))
    case .select:
        dashed(NSBezierPath(rect: NSRect(x: o.x + 1.5, y: o.y + 2.5, width: 13, height: 11)))
    case .eraser:
        let top = P([(2, 9), (8, 3), (14, 3), (8, 9)], close: true)
        let front = P([(2, 9), (8, 9), (8, 14), (2, 14)], close: true)
        let side = P([(8, 9), (14, 3), (14, 8), (8, 14)], close: true)
        NSColor.white.setFill(); top.fill()
        NSColor(srgbRed: 1, green: 0.75, blue: 0.8, alpha: 1).setFill(); front.fill()
        W95.shadow.setFill(); side.fill()
        k.setStroke(); top.stroke(); front.stroke(); side.stroke()
    case .fill:
        let bucket = P([(1, 7), (6, 2), (12, 8), (7, 13)], close: true)
        NSColor.white.setFill(); bucket.fill(); k.setStroke(); bucket.stroke()
        P([(6, 2), (4, 0), (2, 2), (4, 4)]).stroke()
        R(12, 9, 2, 5, blue); R(13, 8, 2, 1, blue); R(11, 7, 2, 2, blue)
    case .picker:
        let tube = P([(2, 14), (1, 13), (8, 6), (10, 8), (3, 15)], close: true)
        NSColor.white.setFill(); tube.fill(); k.setStroke(); tube.stroke()
        R(9, 3, 4, 4, k); R(11, 1, 4, 4, k); R(8, 5, 3, 3, k)
    case .magnifier:
        let lens = NSBezierPath(ovalIn: NSRect(x: o.x + 2.5, y: o.y + 1.5, width: 8, height: 8))
        NSColor(srgbRed: 0.8, green: 0.9, blue: 1, alpha: 1).setFill(); lens.fill()
        k.setStroke(); lens.stroke()
        let h = P([(9, 9), (14, 14)]); h.lineWidth = 2.5; h.stroke()
    case .pencil:
        let body = P([(3, 10), (11, 2), (14, 5), (6, 13)], close: true)
        NSColor(srgbRed: 1, green: 0.85, blue: 0.2, alpha: 1).setFill(); body.fill()
        k.setStroke(); body.stroke()
        let tip = P([(3, 10), (6, 13), (1, 15)], close: true)
        NSColor(srgbRed: 0.95, green: 0.8, blue: 0.6, alpha: 1).setFill(); tip.fill(); tip.stroke()
        R(1, 14, 2, 2, k)
    case .brush:
        let handle = P([(15, 0), (9, 6)]); handle.lineWidth = 2; k.setStroke(); handle.stroke()
        R(7, 6, 3, 3, W95.shadow)
        let tip = P([(7, 8), (9, 10), (4, 15), (1, 15), (2, 12)], close: true)
        k.setFill(); tip.fill()
    case .airbrush:
        let can = NSRect(x: o.x + 8.5, y: o.y + 5.5, width: 5, height: 9)
        NSColor.white.setFill(); NSBezierPath(rect: can).fill()
        k.setStroke(); NSBezierPath(rect: can).stroke()
        R(10, 3, 2, 2, k); R(7, 3, 3, 1, k)
        for (x, y) in [(1, 1), (3, 2), (2, 4), (5, 3), (1, 6), (4, 6), (3, 8), (0, 3)] { R(CGFloat(x), CGFloat(y), 1, 1, blue) }
    case .text:
        let f = NSFont(name: "Times New Roman Bold", size: 16) ?? NSFont.boldSystemFont(ofSize: 15)
        ("A" as NSString).draw(at: NSPoint(x: o.x + 2, y: o.y - 2), withAttributes: [.font: f, .foregroundColor: k])
    case .line:
        k.setStroke(); P([(2, 13), (13, 2)]).stroke()
    case .curve:
        let p = NSBezierPath()
        p.move(to: NSPoint(x: o.x + 1.5, y: o.y + 13.5))
        p.curve(to: NSPoint(x: o.x + 14.5, y: o.y + 2.5),
                controlPoint1: NSPoint(x: o.x + 1.5, y: o.y - 2), controlPoint2: NSPoint(x: o.x + 14.5, y: o.y + 18))
        p.lineWidth = 1; k.setStroke(); p.stroke()
    case .rectangle:
        k.setStroke(); NSBezierPath(rect: NSRect(x: o.x + 1.5, y: o.y + 3.5, width: 13, height: 9)).stroke()
    case .polygon:
        k.setStroke(); P([(1, 2), (8, 2), (8, 7), (14, 7), (14, 13), (1, 13)], close: true).stroke()
    case .ellipse:
        k.setStroke(); NSBezierPath(ovalIn: NSRect(x: o.x + 1.5, y: o.y + 3.5, width: 13, height: 9)).stroke()
    case .roundRect:
        k.setStroke()
        NSBezierPath(roundedRect: NSRect(x: o.x + 1.5, y: o.y + 3.5, width: 13, height: 9), xRadius: 3, yRadius: 3).stroke()
    }
}

// MARK: - Action button icons

func drawCropIcon(at o: NSPoint, enabled: Bool) {
    NSGraphicsContext.current?.shouldAntialias = false
    let c = enabled ? NSColor.black : W95.shadow
    func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ col: NSColor) {
        col.setFill(); NSRect(x: o.x + x, y: o.y + y, width: w, height: h).fill()
    }
    if !enabled { R(4, 1, 2, 11, .white); R(4, 11, 11, 2, .white); R(1, 4, 11, 2, .white); R(11, 4, 2, 11, .white) }
    R(3, 0, 2, 12, c); R(3, 10, 12, 2, c)       // ┗ corner
    R(0, 3, 12, 2, c); R(10, 3, 2, 12, c)       // ┓ corner
    if enabled { R(5, 5, 5, 5, NSColor(srgbRed: 0.3, green: 0.6, blue: 1, alpha: 1)) }
}

func drawRemoveBgIcon(at o: NSPoint) {
    NSGraphicsContext.current?.shouldAntialias = false
    for y in 0..<4 { for x in 0..<4 {
        ((x + y) % 2 == 0 ? NSColor.white : NSColor(white: 0.7, alpha: 1)).setFill()
        NSRect(x: o.x + CGFloat(x * 4), y: o.y + CGFloat(y * 4), width: 4, height: 4).fill()
    } }
    NSColor.black.setStroke()
    NSBezierPath(rect: NSRect(x: o.x + 0.5, y: o.y + 0.5, width: 15, height: 15)).stroke()
    // a little "subject": head and shoulders
    let body = NSColor(srgbRed: 0.85, green: 0.2, blue: 0.2, alpha: 1)
    body.setFill()
    NSBezierPath(ovalIn: NSRect(x: o.x + 5, y: o.y + 2, width: 6, height: 6)).fill()
    NSBezierPath(roundedRect: NSRect(x: o.x + 3, y: o.y + 9, width: 10, height: 7), xRadius: 3, yRadius: 3).fill()
}

// MARK: - Tool Box

final class ToolboxView: NSView, NSViewToolTipOwner {
    override var isFlipped: Bool { true }
    static let width: CGFloat = 56

    struct Opt {
        let rect: NSRect
        let selected: Bool
        let draw: (NSRect, NSColor) -> Void
        let act: () -> Void
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for i in 0..<Tool.allCases.count { addToolTip(toolRect(i), owner: self, userData: nil) }
        for i in 0..<2 { addToolTip(actionRect(i), owner: self, userData: nil) }
    }
    required init?(coder: NSCoder) { fatalError() }

    func toolRect(_ i: Int) -> NSRect {
        NSRect(x: 3 + CGFloat(i % 2) * 25, y: 4 + CGFloat(i / 2) * 25, width: 25, height: 25)
    }
    /// Action buttons (not tools): 0 = Crop, 1 = Remove Background
    func actionRect(_ i: Int) -> NSRect {
        NSRect(x: 3 + CGFloat(i) * 25, y: 4 + 8 * 25 + 6, width: 25, height: 25)
    }
    static let actionTitles = ["Crop to Selection", "Remove Background"]
    private var pressedAction = -1

    var optionsRect: NSRect { NSRect(x: 6, y: 4 + 9 * 25 + 12, width: 44, height: 66) }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        for t in Tool.allCases where toolRect(t.rawValue).contains(point) { return t.title }
        for i in 0..<2 where actionRect(i).contains(point) { return ToolboxView.actionTitles[i] }
        return ""
    }

    override func draw(_ dirtyRect: NSRect) {
        W95.fill(bounds, W95.face)
        W95.fill(NSRect(x: 0, y: 0, width: bounds.width, height: 1), W95.white)
        for t in Tool.allCases {
            let r = toolRect(t.rawValue)
            let sel = t == ps.tool
            if sel { W95.dither(r.insetBy(dx: 2, dy: 2)); W95.bevel(r, raised: false) } else { W95.bevel(r, raised: true) }
            drawToolIcon(t, at: NSPoint(x: r.minX + 4 + (sel ? 1 : 0), y: r.minY + 4 + (sel ? 1 : 0)))
        }
        // etched separator + action buttons
        let sepY = 4 + 8 * 25 + 2
        W95.fill(NSRect(x: 3, y: CGFloat(sepY), width: 50, height: 1), W95.shadow)
        W95.fill(NSRect(x: 3, y: CGFloat(sepY + 1), width: 50, height: 1), W95.white)
        let canCrop = appDelegate.canvas.selection != nil
        for i in 0..<2 {
            let r = actionRect(i)
            let down = pressedAction == i
            W95.bevel(r, raised: !down)
            let o = NSPoint(x: r.minX + 4 + (down ? 1 : 0), y: r.minY + 4 + (down ? 1 : 0))
            if i == 0 { drawCropIcon(at: o, enabled: canCrop) } else { drawRemoveBgIcon(at: o) }
        }
        W95.bevel(optionsRect, raised: false)
        for it in optionItems() {
            if it.selected { W95.fill(it.rect, W95.navy) }
            it.draw(it.rect, it.selected ? .white : .black)
        }
    }

    func optionItems() -> [Opt] {
        let o = optionsRect.insetBy(dx: 3, dy: 3)
        var items: [Opt] = []
        switch ps.tool {
        case .select, .freeSelect, .text:
            for i in 0..<2 {
                let r = NSRect(x: o.minX, y: o.minY + 2 + CGFloat(i) * 29, width: o.width, height: 26)
                items.append(Opt(rect: r, selected: ps.transparentSelect == (i == 1), draw: { r, _ in
                    let box = NSRect(x: r.midX - 13, y: r.midY - 9, width: 26, height: 18)
                    if i == 0 { W95.fill(box, .white) }
                    NSColor.black.setStroke(); NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5)).stroke()
                    NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
                    NSBezierPath(ovalIn: NSRect(x: box.minX + 3, y: box.minY + 4, width: 10, height: 10)).fill()
                    NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1).setFill()
                    let tri = NSBezierPath()
                    tri.move(to: NSPoint(x: box.minX + 12, y: box.maxY - 3))
                    tri.line(to: NSPoint(x: box.minX + 18, y: box.minY + 3))
                    tri.line(to: NSPoint(x: box.minX + 24, y: box.maxY - 3))
                    tri.close(); tri.fill()
                }, act: { ps.transparentSelect = (i == 1) }))
            }
        case .eraser:
            for (i, n) in Stamp.eraserSizes.enumerated() {
                let r = NSRect(x: o.minX, y: o.minY + 3 + CGFloat(i) * 14, width: o.width, height: 13)
                items.append(Opt(rect: r, selected: ps.eraserIndex == i, draw: { r, c in
                    c.setFill()
                    NSRect(x: (r.midX - CGFloat(n) / 2).rounded(), y: (r.midY - CGFloat(n) / 2).rounded(),
                           width: CGFloat(n), height: CGFloat(n)).fill()
                }, act: { ps.eraserIndex = i }))
            }
        case .magnifier:
            for (i, z) in [1, 2, 6, 8].enumerated() {
                let r = NSRect(x: o.minX, y: o.minY + 3 + CGFloat(i) * 14, width: o.width, height: 13)
                let current = Int(appDelegate.canvas.zoom) == z
                items.append(Opt(rect: r, selected: current, draw: { r, c in
                    W95.text("\(z)x", in: r, color: c, center: true)
                }, act: {
                    appDelegate.canvas.setZoom(CGFloat(z), center: nil)
                    ps.setTool(ps.prevTool)
                }))
            }
        case .brush:
            for i in 0..<12 {
                let col = i % 3, row = i / 3
                let r = NSRect(x: o.minX + 1 + CGFloat(col) * 12, y: o.minY + 3 + CGFloat(row) * 14, width: 12, height: 13)
                items.append(Opt(rect: r, selected: ps.brushIndex == i, draw: { r, c in
                    c.setFill()
                    let cx = r.minX + 6, cy = r.minY + 6
                    for p in Stamp.brushes[i] {
                        NSRect(x: cx + CGFloat(p.0), y: cy + CGFloat(p.1), width: 1, height: 1).fill()
                    }
                }, act: { ps.brushIndex = i }))
            }
        case .airbrush:
            let rects = [NSRect(x: o.minX, y: o.minY + 2, width: 19, height: 24),
                         NSRect(x: o.minX + 19, y: o.minY + 2, width: 19, height: 24),
                         NSRect(x: o.minX + 7, y: o.minY + 28, width: 26, height: 30)]
            for i in 0..<3 {
                items.append(Opt(rect: rects[i], selected: ps.airIndex == i, draw: { r, c in
                    var seed: UInt32 = 12345
                    func rnd(_ n: Int) -> Int {
                        seed = seed &* 1_103_515_245 &+ 12345
                        return Int((seed >> 16) & 0x7FFF) % n
                    }
                    let rad = [4, 6, 9][i]
                    c.setFill()
                    for _ in 0..<(rad * rad) {
                        let dx = rnd(2 * rad + 1) - rad, dy = rnd(2 * rad + 1) - rad
                        if dx * dx + dy * dy <= rad * rad {
                            NSRect(x: r.midX.rounded() + CGFloat(dx), y: r.midY.rounded() + CGFloat(dy), width: 1, height: 1).fill()
                        }
                    }
                }, act: { ps.airIndex = i }))
            }
        case .line, .curve:
            for i in 0..<5 {
                let r = NSRect(x: o.minX, y: o.minY + 3 + CGFloat(i) * 11, width: o.width, height: 10)
                items.append(Opt(rect: r, selected: ps.lineWidthIndex == i, draw: { r, c in
                    c.setFill()
                    NSRect(x: r.minX + 4, y: (r.midY - CGFloat(i + 1) / 2).rounded(), width: r.width - 8, height: CGFloat(i + 1)).fill()
                }, act: { ps.lineWidthIndex = i }))
            }
        case .rectangle, .polygon, .ellipse, .roundRect:
            for i in 0..<3 {
                let r = NSRect(x: o.minX, y: o.minY + 2 + CGFloat(i) * 19, width: o.width, height: 18)
                items.append(Opt(rect: r, selected: ps.shapeStyle == i, draw: { r, c in
                    let s = r.insetBy(dx: 5, dy: 4)
                    if i >= 1 { W95.fill(s, W95.shadow) }
                    if i <= 1 { c.setStroke(); NSBezierPath(rect: s.insetBy(dx: 0.5, dy: 0.5)).stroke() }
                }, act: { ps.shapeStyle = i }))
            }
        default:
            break
        }
        return items
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        for t in Tool.allCases where toolRect(t.rawValue).contains(p) {
            ps.setTool(t); needsDisplay = true; return
        }
        for i in 0..<2 where actionRect(i).contains(p) {
            pressedAction = i; display()
            pressedAction = -1; needsDisplay = true
            if i == 0 { appDelegate.canvas.cropToSelection() } else { appDelegate.canvas.removeBackground() }
            return
        }
        for it in optionItems() where it.rect.contains(p) {
            it.act(); ps.notify(); needsDisplay = true; return
        }
    }
}

// MARK: - Color Box

final class ColorBoxView: NSView {
    override var isFlipped: Bool { true }
    static let height: CGFloat = 46
    private var editingIndex = -1

    var curRect: NSRect { NSRect(x: 4, y: 6, width: 32, height: 34) }
    func cellRect(_ i: Int) -> NSRect {
        NSRect(x: 38 + CGFloat(i % 14) * 16, y: 6 + CGFloat(i / 14) * 17, width: 16, height: 17)
    }
    func hit(_ e: NSEvent) -> Int {
        let p = convert(e.locationInWindow, from: nil)
        for i in 0..<ps.palette.count where cellRect(i).contains(p) { return i }
        return -1
    }

    override func draw(_ dirtyRect: NSRect) {
        W95.fill(bounds, W95.face)
        W95.fill(NSRect(x: 0, y: 0, width: bounds.width, height: 1), W95.white)
        let c = curRect
        W95.bevel(c, raised: false)
        W95.dither(c.insetBy(dx: 2, dy: 2))
        let sec = NSRect(x: c.minX + 13, y: c.minY + 14, width: 15, height: 15)
        let pri = NSRect(x: c.minX + 5, y: c.minY + 5, width: 15, height: 15)
        for (r, col) in [(sec, ps.secondary), (pri, ps.primary)] {
            W95.bevel(r, raised: true, thin: true)
            W95.fill(r.insetBy(dx: 1, dy: 1), col.ns)
        }
        for i in 0..<ps.palette.count {
            let r = cellRect(i)
            W95.bevel(r, raised: false)
            W95.fill(r.insetBy(dx: 2, dy: 2), ps.palette[i].ns)
        }
    }

    override func mouseDown(with e: NSEvent) {
        let i = hit(e)
        guard i >= 0 else { return }
        if e.modifierFlags.contains(.control) { ps.secondary = ps.palette[i]; return }
        if e.clickCount >= 2 { editColor(i); return }
        ps.primary = ps.palette[i]
    }
    override func rightMouseDown(with e: NSEvent) {
        let i = hit(e)
        if i >= 0 { ps.secondary = ps.palette[i] }
    }

    /// "Edit Colors..." — uses the system color panel
    func editColor(_ i: Int) {
        editingIndex = i
        let p = NSColorPanel.shared
        p.setTarget(nil); p.setAction(nil)
        p.color = (i >= 0 ? ps.palette[i] : ps.primary).ns
        p.setTarget(self)
        p.setAction(#selector(colorPanelChanged(_:)))
        p.orderFront(nil)
    }
    @objc func colorPanelChanged(_ sender: NSColorPanel) {
        let c = RGB(ns: sender.color)
        if editingIndex >= 0 && editingIndex < ps.palette.count { ps.palette[editingIndex] = c }
        ps.primary = c
        needsDisplay = true
    }
}

// MARK: - Status Bar

final class StatusBarView: NSView {
    override var isFlipped: Bool { true }
    static let height: CGFloat = 22

    override func draw(_ dirtyRect: NSRect) {
        W95.fill(bounds, W95.face)
        let w = bounds.width
        let sizeR = NSRect(x: w - 16 - 100, y: 3, width: 100, height: 17)
        let coordR = NSRect(x: sizeR.minX - 104, y: 3, width: 100, height: 17)
        let textR = NSRect(x: 2, y: 3, width: max(10, coordR.minX - 6), height: 17)
        for (r, s) in [(textR, ps.statusText), (coordR, ps.coordText), (sizeR, ps.sizeText)] {
            W95.bevel(r, raised: false, thin: true)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: r.insetBy(dx: 1, dy: 1)).addClip()
            W95.text(s, in: r.insetBy(dx: 4, dy: 0))
            NSGraphicsContext.restoreGraphicsState()
        }
        // size grip
        for i in 0..<3 {
            let off = CGFloat(i * 4)
            let p = NSBezierPath()
            p.move(to: NSPoint(x: w - 3 - off, y: bounds.height - 2))
            p.line(to: NSPoint(x: w - 2, y: bounds.height - 3 - off))
            W95.shadow.setStroke(); p.lineWidth = 1; p.stroke()
        }
    }
}

// MARK: - Main layout

final class MainView: NSView {
    override var isFlipped: Bool { true }
    let toolbox = ToolboxView(frame: .zero)
    let colorBox = ColorBoxView(frame: .zero)
    let statusBar = StatusBarView(frame: .zero)
    let scroll = NSScrollView(frame: .zero)
    let canvas = CanvasView(frame: .zero)
    let tabBar = TabBarView(frame: .zero)

    var showToolbox = true { didSet { needsLayout = true } }
    var showColors = true { didSet { needsLayout = true } }
    var showStatus = true { didSet { needsLayout = true } }
    /// Tab bar is hidden by default; the choice is remembered between launches
    var showTabBar = UserDefaults.standard.bool(forKey: "ShowTabBar") {
        didSet { UserDefaults.standard.set(showTabBar, forKey: "ShowTabBar"); needsLayout = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .legacy
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = W95.shadow
        scroll.documentView = canvas
        for v in [toolbox, colorBox, statusBar, tabBar, scroll] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) { W95.fill(bounds, W95.face) }

    override func layout() {
        super.layout()
        let b = bounds
        let sbH = showStatus ? StatusBarView.height : 0
        let cbH = showColors ? ColorBoxView.height : 0
        let tbW = showToolbox ? ToolboxView.width : 0
        statusBar.isHidden = !showStatus
        colorBox.isHidden = !showColors
        toolbox.isHidden = !showToolbox
        statusBar.frame = NSRect(x: 0, y: b.height - sbH, width: b.width, height: sbH)
        colorBox.frame = NSRect(x: 0, y: b.height - sbH - cbH, width: b.width, height: cbH)
        toolbox.frame = NSRect(x: 0, y: 0, width: tbW, height: max(0, b.height - sbH - cbH))
        let tH = showTabBar ? TabBarView.height : 0
        tabBar.isHidden = !showTabBar
        tabBar.frame = NSRect(x: tbW, y: 0, width: max(0, b.width - tbW), height: tH)
        scroll.frame = NSRect(x: tbW, y: tH, width: max(0, b.width - tbW), height: max(0, b.height - sbH - cbH - tH))
        canvas.updateSize()
    }
}
