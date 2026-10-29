import Cocoa

// MARK: - Windows-style menu bar inside the window (File  Edit  View  Image  Colors  Help)
//
// Mirrors the app's real menus (NSApp.mainMenu), so every command, shortcut and checkmark
// stays in one place. Clicking a title pops up that menu right under it, like on Windows.

final class WindowMenuBar: NSView {
    override var isFlipped: Bool { true }
    static let height: CGFloat = 20
    static let gap: CGFloat = 5          // space between the menu bar and the tool box / canvas

    private var pressed = -1
    private var pendingOpen = -1          // menu to open next, when the mouse moves to another title
    private var hover = -1
    private var tracking: NSTrackingArea?

    /// Top-level menus to show (everything except the macOS application menu)
    private var menus: [NSMenuItem] {
        Array((NSApp.mainMenu?.items ?? []).dropFirst()).filter { $0.submenu != nil && !$0.isHidden }
    }

    private let font = W95.font

    private func itemRects() -> [NSRect] {
        var x: CGFloat = 4
        return menus.map { it in
            let w = ceil((it.title as NSString).size(withAttributes: [.font: font]).width) + 14
            defer { x += w }
            return NSRect(x: x, y: 1, width: w, height: WindowMenuBar.height - 2)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        W95.fill(bounds, W95.face)
        // thin etched line under the menu bar, like Windows 9x
        W95.fill(NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 1), W95.shadow)
        W95.fill(NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1), W95.white)

        for (i, (it, r)) in zip(menus, itemRects()).enumerated() {
            if i == pressed { W95.bevel(r, raised: false, thin: true) }
            else if i == hover && pressed < 0 { W95.bevel(r, raised: true, thin: true) }
            let off: CGFloat = i == pressed ? 1 : 0
            let s = NSMutableAttributedString(string: it.title, attributes: [.font: font, .foregroundColor: NSColor.black])
            // underline the first letter as the "access key", like Windows
            if s.length > 0 { s.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: 1)) }
            let size = s.size()
            s.draw(at: NSPoint(x: r.minX + 7 + off, y: r.midY - size.height / 2 + off))
        }
    }

    private func index(at p: NSPoint) -> Int {
        for (i, r) in itemRects().enumerated() where r.contains(p) { return i }
        return -1
    }

    override func mouseDown(with e: NSEvent) {
        let i = index(at: convert(e.locationInWindow, from: nil))
        guard i >= 0 else { return }
        open(i)
    }

    /// Pops up menu `i` under its title. While it's open, moving the mouse onto another
    /// title switches to that menu, like on Windows.
    func open(_ first: Int) {
        var i = first
        while true {
            let items = menus
            guard i >= 0, i < items.count, let sub = items[i].submenu else { break }
            let r = itemRects()[i]
            pressed = i; hover = -1; pendingOpen = -1
            display()
            // A copy, so the menu keeps its place in the real macOS menu bar
            let m = (sub.copy() as? NSMenu) ?? sub
            m.font = NSFont.menuFont(ofSize: 13)

            // Watch the mouse while the menu is tracking (menus run their own event loop)
            let current = i
            let watcher = Timer(timeInterval: 0.03, repeats: true) { [weak self, weak m] _ in
                guard let self = self, let m = m, let w = self.window else { return }
                let p = self.convert(w.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
                let j = self.index(at: p)
                if j >= 0 && j != current {
                    self.pendingOpen = j
                    m.cancelTrackingWithoutAnimation()
                }
            }
            RunLoop.main.add(watcher, forMode: .eventTracking)
            RunLoop.main.add(watcher, forMode: .common)

            // Place the menu's top edge just under the menu bar, not over the title
            // (modern macOS draws the menu a few points above the requested point)
            m.popUp(positioning: nil, at: NSPoint(x: r.minX, y: bounds.maxY + 5), in: self)
            watcher.invalidate()

            if pendingOpen >= 0 { i = pendingOpen; continue }
            break
        }
        pressed = -1
        pendingOpen = -1
        needsDisplay = true
    }

    /// Option+letter (Alt+letter on Windows) opens the menu whose title starts with that letter
    func openMenu(forKey e: NSEvent) -> Bool {
        guard let ch = e.charactersIgnoringModifiers?.lowercased().first else { return false }
        guard let i = menus.firstIndex(where: { $0.title.lowercased().first == ch }) else { return false }
        open(i)
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if tracking == nil {
            let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                   owner: self, userInfo: nil)
            addTrackingArea(t); tracking = t
        }
    }
    override func mouseMoved(with e: NSEvent) {
        let i = index(at: convert(e.locationInWindow, from: nil))
        if i != hover { hover = i; needsDisplay = true }
    }
    override func mouseExited(with e: NSEvent) { hover = -1; needsDisplay = true }
}
