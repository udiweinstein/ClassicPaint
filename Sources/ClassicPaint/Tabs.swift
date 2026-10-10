import Cocoa

// MARK: - Tab bar (one tab per open picture), drawn in the Windows 9x style

final class TabBarView: NSView {
    override var isFlipped: Bool { true }
    static let height: CGFloat = 26

    private struct TabGeom { let rect: NSRect; let close: NSRect }

    private let titleFont = W95.font
    private let boldFont = NSFontManager.shared.convert(W95.font, toHaveTrait: .boldFontMask)

    private func title(_ d: PaintDocument) -> String { d.name + (d.dirty ? " *" : "") }

    private func geometry() -> [TabGeom] {
        let docs = appDelegate.docs
        let avail = max(60, bounds.width - 8 - 30)
        let natural: [CGFloat] = docs.map {
            let w = (title($0) as NSString).size(withAttributes: [.font: boldFont]).width
            return min(190, max(96, ceil(w) + 40))
        }
        let total = natural.reduce(0, +)
        let scale = total > avail ? avail / total : 1
        var x: CGFloat = 4
        var out: [TabGeom] = []
        for (i, w0) in natural.enumerated() {
            let w = max(44, floor(w0 * scale))
            let sel = i == appDelegate.currentTab
            let r = NSRect(x: x, y: sel ? 2 : 4, width: w, height: bounds.height - (sel ? 2 : 4))
            let c = NSRect(x: r.maxX - 19, y: (r.midY - 7).rounded(), width: 14, height: 14)
            out.append(TabGeom(rect: r, close: c))
            x += w
        }
        return out
    }

    private func plusRect(_ g: [TabGeom]) -> NSRect {
        NSRect(x: (g.last?.rect.maxX ?? 4) + 6, y: 5, width: 20, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.shouldAntialias = false
        W95.fill(bounds, W95.face)
        // baseline the tabs sit on
        W95.fill(NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1), W95.white)

        let g = geometry()
        let cur = appDelegate.currentTab
        for (i, t) in g.enumerated() where i != cur { drawTab(t, appDelegate.docs[i], selected: false) }
        if cur < g.count { drawTab(g[cur], appDelegate.docs[cur], selected: true) }

        let p = plusRect(g)
        W95.bevel(p, raised: true)
        W95.fill(NSRect(x: p.midX - 4, y: p.midY - 0.5, width: 9, height: 1.5), .black)
        W95.fill(NSRect(x: p.midX - 0.5, y: p.midY - 4, width: 1.5, height: 9), .black)
    }

    private func drawTab(_ t: TabGeom, _ d: PaintDocument, selected: Bool) {
        let r = t.rect
        W95.fill(r, W95.face)
        // left + top highlight with clipped corners, right shadow
        W95.fill(NSRect(x: r.minX, y: r.minY + 2, width: 1, height: r.height - 2), W95.white)
        W95.fill(NSRect(x: r.minX + 1, y: r.minY + 1, width: 1, height: 1), W95.white)
        W95.fill(NSRect(x: r.minX + 2, y: r.minY, width: r.width - 4, height: 1), W95.white)
        W95.fill(NSRect(x: r.maxX - 2, y: r.minY + 1, width: 1, height: 1), W95.black)
        W95.fill(NSRect(x: r.maxX - 1, y: r.minY + 2, width: 1, height: r.height - 2), W95.black)
        W95.fill(NSRect(x: r.maxX - 2, y: r.minY + 2, width: 1, height: r.height - 2), W95.shadow)
        if selected {
            // open the bottom so the tab merges with the page below it
            W95.fill(NSRect(x: r.minX + 1, y: bounds.height - 1, width: r.width - 3, height: 1), W95.face)
        }

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: selected ? boldFont : titleFont,
                                                    .foregroundColor: NSColor.black, .paragraphStyle: para]
        let s = title(d) as NSString
        let h = s.size(withAttributes: attrs).height
        s.draw(in: NSRect(x: r.minX + 8, y: r.midY - h / 2, width: t.close.minX - r.minX - 10, height: h),
               withAttributes: attrs)

        // close "×"
        let c = t.close.insetBy(dx: 3.5, dy: 3.5)
        let x = NSBezierPath()
        x.move(to: NSPoint(x: c.minX, y: c.minY)); x.line(to: NSPoint(x: c.maxX, y: c.maxY))
        x.move(to: NSPoint(x: c.maxX, y: c.minY)); x.line(to: NSPoint(x: c.minX, y: c.maxY))
        x.lineWidth = 1.5
        NSColor.black.setStroke()
        NSGraphicsContext.current?.shouldAntialias = true
        x.stroke()
        NSGraphicsContext.current?.shouldAntialias = false
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let g = geometry()
        if plusRect(g).contains(p) { appDelegate.newDoc(nil); return }
        for (i, t) in g.enumerated() where t.rect.contains(p) {
            if t.close.insetBy(dx: -2, dy: -2).contains(p) { appDelegate.closeTab(i) } else { appDelegate.switchToTab(i) }
            return
        }
        if e.clickCount == 2 { appDelegate.newDoc(nil) }   // double-click empty space = new tab
    }

    // Middle-click closes a tab, like in browsers
    override func otherMouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        for (i, t) in geometry().enumerated() where t.rect.contains(p) { appDelegate.closeTab(i); return }
    }
}

// MARK: - Tab management

extension AppDelegate {
    private func saveViewState() {
        doc.zoom = canvas.zoom
        doc.scrollOrigin = canvas.enclosingScrollView?.contentView.bounds.origin ?? .zero
    }

    func switchToTab(_ i: Int) {
        guard i >= 0, i < docs.count, docs[i] !== doc else { return }
        canvas.commitAll()
        saveViewState()
        currentTab = i
        doc = docs[i]
        canvas.showDocument()
        updateTitle()
    }

    func addTab(_ d: PaintDocument) {
        canvas.commitAll()
        saveViewState()
        docs.append(d)
        currentTab = docs.count - 1
        doc = d
        canvas.showDocument()
        updateTitle()
    }

    /// Puts `d` in the current tab when that tab is an untouched blank picture, otherwise opens a new tab.
    func showInTab(_ d: PaintDocument) {
        if doc.isPristine {
            canvas.cancelInteraction()
            docs[currentTab] = d
            doc = d
            canvas.showDocument()
            updateTitle()
        } else {
            addTab(d)
        }
    }

    func closeTab(_ i: Int) {
        guard i >= 0, i < docs.count else { return }
        switchToTab(i)
        guard confirmDiscard() else { return }
        canvas.cancelInteraction()
        docs.remove(at: i)
        if docs.isEmpty { docs = [PaintDocument()] }
        currentTab = min(i, docs.count - 1)
        doc = docs[currentTab]
        canvas.showDocument()
        updateTitle()
    }

    /// Asks about every picture with unsaved changes. Returns false if the user cancels.
    func confirmAllTabs() -> Bool {
        for i in docs.indices where docs[i].dirty {
            switchToTab(i)
            if !confirmDiscard() { return false }
        }
        return true
    }

    @objc func closeCurrentTab(_ s: Any?) { closeTab(currentTab) }
    @objc func nextTab(_ s: Any?) { if docs.count > 1 { switchToTab((currentTab + 1) % docs.count) } }
    @objc func previousTab(_ s: Any?) { if docs.count > 1 { switchToTab((currentTab - 1 + docs.count) % docs.count) } }
}
