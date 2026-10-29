import Cocoa
import UniformTypeIdentifiers

var appDelegate: AppDelegate!

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    var window: NSWindow!
    var main: MainView!
    var doc = PaintDocument()
    var docs: [PaintDocument] = []
    var currentTab = 0
    var canvas: CanvasView { main.canvas }
    private var fontToolbar: FontToolbar?
    private var previewWindow: NSWindow?

    // MARK: Launch

    func applicationWillFinishLaunching(_ n: Notification) {
        // First-launch defaults: Windows-style menus in the window
        UserDefaults.standard.register(defaults: ["MenusInWindow": true])
        NSApp.applicationIconImage = makeAppIcon(512)
        NSWindow.allowsAutomaticWindowTabbing = false   // we have our own tab bar
        buildMenu()
        main = MainView(frame: NSRect(x: 0, y: 0, width: 900, height: 660))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentView = main
        window.delegate = self
        window.minSize = NSSize(width: 460, height: 440)
        window.center()
        window.setFrameAutosaveName("ClassicPaintMainWindow")
        window.backgroundColor = W95.face
        docs = [doc]

        ps.onChange.append { [weak self] in
            guard let self = self else { return }
            self.main.toolbox.needsDisplay = true
            self.main.colorBox.needsDisplay = true
            self.canvas.stateChanged()
        }
        ps.onToolChange.append { [weak self] in self?.canvas.toolChanged() }
        ps.onStatus = { [weak self] in self?.main.statusBar.needsDisplay = true }
        updateTitle()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        canvas.updateSize()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard confirmAllTabs() else { return .terminateCancel }
        UserDefaults.standard.set(main.showMenuBar, forKey: "MenusInWindow")
        UserDefaults.standard.synchronize()
        return .terminateNow
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmAllTabs() }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        openURL(URL(fileURLWithPath: filename))
    }

    func updateTitle() {
        guard let w = window else { return }
        w.title = doc.title
        w.isDocumentEdited = docs.contains { $0.dirty }
        main?.tabBar.needsDisplay = true
    }

    // MARK: Menus

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                     _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil, useSelf: Bool = true) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        it.target = useSelf ? (target ?? self) : nil
        menu.addItem(it)
        return it
    }

    private func submenu(_ bar: NSMenu, _ title: String) -> NSMenu {
        let m = NSMenu(title: title)
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = m
        bar.addItem(it)
        return m
    }

    private func buildMenu() {
        let bar = NSMenu()

        let appM = submenu(bar, "ClassicPaint")
        add(appM, "About ClassicPaint", #selector(about(_:)))
        appM.addItem(.separator())
        add(appM, "Hide ClassicPaint", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        add(appM, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp)
        add(appM, "Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        appM.addItem(.separator())
        add(appM, "Quit ClassicPaint", #selector(NSApplication.terminate(_:)), "q", target: NSApp)

        let file = submenu(bar, "File")
        add(file, "New", #selector(newDoc(_:)), "n")
        add(file, "Open...", #selector(openDoc(_:)), "o")
        add(file, "Close Tab", #selector(closeCurrentTab(_:)), "w")
        add(file, "Save", #selector(saveDoc(_:)), "s")
        add(file, "Save As...", #selector(saveDocAs(_:)), "s", [.command, .shift])
        file.addItem(.separator())
        add(file, "Set As Desktop Background (Centered)", #selector(wallpaperCentered(_:)))
        add(file, "Set As Desktop Background (Stretched)", #selector(wallpaperStretched(_:)))
        file.addItem(.separator())
        add(file, "Exit", #selector(NSApplication.terminate(_:)), target: NSApp)

        let edit = submenu(bar, "Edit")
        add(edit, "Undo", #selector(paintUndo(_:)), "z")
        add(edit, "Repeat", #selector(paintRedo(_:)), "y")
        edit.addItem(.separator())
        add(edit, "Cut", #selector(cut(_:)), "x", useSelf: false)
        add(edit, "Copy", #selector(copy(_:)), "c", useSelf: false)
        add(edit, "Paste", #selector(paste(_:)), "v", useSelf: false)
        add(edit, "Clear Selection", #selector(delete(_:)), useSelf: false)
        add(edit, "Select All", #selector(selectAll(_:)), "a", useSelf: false)
        edit.addItem(.separator())
        add(edit, "Copy To...", #selector(copyTo(_:)))
        add(edit, "Paste From...", #selector(pasteFrom(_:)))

        let view = submenu(bar, "View")
        add(view, "Tool Box", #selector(toggleToolbox(_:)), "t")
        add(view, "Color Box", #selector(toggleColorbox(_:)), "l")
        add(view, "Status Bar", #selector(toggleStatus(_:)))
        add(view, "Text Toolbar", #selector(toggleTextToolbar(_:)))
        add(view, "Menus in Window (Windows Style)", #selector(toggleMenusInWindow(_:)), "m", [.command, .option])
        view.addItem(.separator())
        let zoomItem = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        let zoomM = NSMenu(title: "Zoom")
        zoomItem.submenu = zoomM
        view.addItem(zoomItem)
        add(zoomM, "Normal Size", #selector(zoomNormal(_:)), "0")
        add(zoomM, "Large Size", #selector(zoomLarge(_:)), "4")
        add(zoomM, "Custom...", #selector(zoomCustom(_:)))
        zoomM.addItem(.separator())
        add(zoomM, "Zoom In", #selector(zoomIn(_:)), "=")
        add(zoomM, "Zoom Out", #selector(zoomOut(_:)), "-")
        zoomM.addItem(.separator())
        add(zoomM, "Show Grid", #selector(toggleGrid(_:)), "g")
        add(view, "View Bitmap", #selector(viewBitmap(_:)), "f")
        view.addItem(.separator())
        add(view, "Show Tab Bar", #selector(toggleTabBar(_:)), "t", [.command, .shift])
        add(view, "Next Tab", #selector(nextTab(_:)), "}")
        add(view, "Previous Tab", #selector(previousTab(_:)), "{")

        let image = submenu(bar, "Image")
        add(image, "Flip/Rotate...", #selector(flipRotate(_:)), "r")
        add(image, "Stretch/Skew...", #selector(stretchSkew(_:)), "w", [.command, .option])
        add(image, "Invert Colors", #selector(invertColors(_:)), "i")
        add(image, "Crop", #selector(cropImage(_:)), "x", [.command, .shift])
        add(image, "Remove Background", #selector(removeBackground(_:)), "b", [.command, .shift])
        add(image, "Attributes...", #selector(attributes(_:)), "e")
        add(image, "Clear Image", #selector(clearImage(_:)), "n", [.command, .shift])
        add(image, "Draw Opaque", #selector(toggleOpaque(_:)))

        let colors = submenu(bar, "Colors")
        add(colors, "Edit Colors...", #selector(editColors(_:)))

        let help = submenu(bar, "Help")
        add(help, "Help Topics", #selector(helpTopics(_:)), "?")
        help.addItem(.separator())
        add(help, "About ClassicPaint", #selector(about(_:)))

        NSApp.mainMenu = bar
    }

    func validateMenuItem(_ m: NSMenuItem) -> Bool {
        switch m.action {
        case #selector(toggleToolbox(_:)): m.state = main.showToolbox ? .on : .off
        case #selector(toggleColorbox(_:)): m.state = main.showColors ? .on : .off
        case #selector(toggleStatus(_:)): m.state = main.showStatus ? .on : .off
        case #selector(toggleMenusInWindow(_:)): m.state = main.showMenuBar ? .on : .off
        case #selector(toggleTabBar(_:)): m.title = main.showTabBar ? "Hide Tab Bar" : "Show Tab Bar"
        case #selector(toggleGrid(_:)): m.state = ps.showGrid ? .on : .off
        case #selector(toggleOpaque(_:)): m.state = ps.transparentSelect ? .off : .on
        case #selector(toggleTextToolbar(_:)): m.state = (fontToolbar?.panel.isVisible ?? false) ? .on : .off
        default: break
        }
        return true
    }

    // MARK: File

    func confirmDiscard() -> Bool {
        guard doc.dirty else { return true }
        canvas.commitAll()
        let a = NSAlert()
        a.messageText = "Save changes to \(doc.name)?"
        a.addButton(withTitle: "Yes")
        a.addButton(withTitle: "No")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: doc.dirty = false; return true
        default: return false
        }
    }

    /// File ▸ New opens a blank picture in a new tab
    @objc func newDoc(_ s: Any?) { addTab(PaintDocument()) }

    @objc func openDoc(_ s: Any?) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = true
        if p.runModal() == .OK { for u in p.urls { openURL(u) } }
    }

    func loadCGImage(_ u: URL) -> CGImage? {
        guard let img = NSImage(contentsOf: u) else { return nil }
        if let rep = img.representations.first as? NSBitmapImageRep, let cg = rep.cgImage { return cg }
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    @discardableResult
    func openURL(_ u: URL) -> Bool {
        // already open? just switch to its tab
        if let i = docs.firstIndex(where: { $0.url?.standardizedFileURL == u.standardizedFileURL }) {
            switchToTab(i)
            return true
        }
        guard let cg = loadCGImage(u) else {
            message("ClassicPaint cannot read this file.", "This is not a valid bitmap file, or its format is not currently supported.")
            return false
        }
        let d = PaintDocument()
        let hasAlpha = [CGImageAlphaInfo.first, .last, .premultipliedFirst, .premultipliedLast].contains(cg.alphaInfo)
        let b = Bitmap(width: cg.width, height: cg.height, fill: hasAlpha ? nil : .white)
        b.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        d.bitmap = b
        d.url = u
        showInTab(d)
        NSDocumentController.shared.noteNewRecentDocumentURL(u)
        return true
    }

    @objc func saveDoc(_ s: Any?) { _ = save() }
    @objc func saveDocAs(_ s: Any?) { _ = saveAs() }

    func save() -> Bool {
        if let u = doc.url { return write(to: u) }
        return saveAs()
    }

    private let formats: [(String, UTType)] = [
        ("PNG (*.png)", .png), ("24-bit Bitmap (*.bmp;*.dib)", .bmp), ("JPEG (*.jpg;*.jpeg)", .jpeg),
        ("GIF (*.gif)", .gif), ("TIFF (*.tif;*.tiff)", .tiff),
    ]

    private func runSavePanel(defaultName: String, title: String) -> URL? {
        let p = NSSavePanel()
        p.title = title
        p.nameFieldStringValue = defaultName
        let ext = (defaultName as NSString).pathExtension.lowercased()
        var idx = formats.firstIndex { $0.1.preferredFilenameExtension == ext || ($0.1.tags[.filenameExtension] ?? []).contains(ext) } ?? 0
        if idx < 0 || idx >= formats.count { idx = 0 }
        p.allowedContentTypes = [formats[idx].1]

        let acc = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 40))
        let label = NSTextField(labelWithString: "Save as type:")
        label.frame = NSRect(x: 10, y: 11, width: 90, height: 18)
        let pop = NSPopUpButton(frame: NSRect(x: 100, y: 6, width: 250, height: 26), pullsDown: false)
        pop.addItems(withTitles: formats.map { $0.0 })
        pop.selectItem(at: idx)
        let chooser = FormatChooser(panel: p, types: formats.map { $0.1 })
        pop.target = chooser
        pop.action = #selector(FormatChooser.changed(_:))
        acc.addSubview(label); acc.addSubview(pop)
        p.accessoryView = acc
        let ok = p.runModal() == .OK
        _ = chooser   // keep alive during the modal session
        return ok ? p.url : nil
    }

    func saveAs() -> Bool {
        guard let u = runSavePanel(defaultName: doc.url?.lastPathComponent ?? "untitled.png", title: "Save As") else { return false }
        return write(to: u)
    }

    func encode(_ b: Bitmap, for u: URL) -> Data? {
        let ext = u.pathExtension.lowercased()
        let ft: NSBitmapImageRep.FileType
        switch ext {
        case "bmp", "dib": ft = .bmp
        case "jpg", "jpeg", "jpe", "jfif": ft = .jpeg
        case "gif": ft = .gif
        case "tif", "tiff": ft = .tiff
        default: ft = .png
        }
        // Keep transparency where the format supports it (PNG/TIFF); flatten onto white otherwise
        let transparent = b.hasTransparency
        let rep: NSBitmapImageRep
        if transparent && (ft == .png || ft == .tiff) { rep = b.rgbaRep() }
        else if transparent { rep = b.flattened(on: .white).rgbRep() }
        else { rep = b.rgbRep() }
        var props: [NSBitmapImageRep.PropertyKey: Any] = [:]
        if ft == .jpeg { props[.compressionFactor] = 0.9 }
        return rep.representation(using: ft, properties: props)
    }

    func write(to u: URL) -> Bool {
        canvas.commitAll()
        guard let data = encode(doc.bitmap, for: u) else {
            message("ClassicPaint could not save this file.")
            return false
        }
        do {
            try data.write(to: u)
            doc.url = u
            doc.dirty = false
            updateTitle()
            NSDocumentController.shared.noteNewRecentDocumentURL(u)
            return true
        } catch {
            message("ClassicPaint could not save this file.", error.localizedDescription)
            return false
        }
    }

    private func setWallpaper(stretched: Bool) {
        canvas.commitAll()
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = support.appendingPathComponent("ClassicPaint", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let old = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in old where f.lastPathComponent.hasPrefix("Wallpaper-") { try? fm.removeItem(at: f) }
        }
        let u = dir.appendingPathComponent("Wallpaper-\(Int(Date().timeIntervalSince1970)).png")
        guard let data = encode(doc.bitmap, for: u), (try? data.write(to: u)) != nil else { return }
        var opts: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        if stretched {
            opts[.imageScaling] = NSImageScaling.scaleAxesIndependently.rawValue
            opts[.allowClipping] = true
        } else {
            opts[.imageScaling] = NSImageScaling.scaleNone.rawValue
            opts[.allowClipping] = false
            opts[.fillColor] = W95.teal
        }
        for screen in NSScreen.screens {
            do { try NSWorkspace.shared.setDesktopImageURL(u, for: screen, options: opts) } catch {
                message("Could not set the desktop background.", error.localizedDescription); return
            }
        }
    }
    @objc func wallpaperCentered(_ s: Any?) { setWallpaper(stretched: false) }
    @objc func wallpaperStretched(_ s: Any?) { setWallpaper(stretched: true) }

    // MARK: Edit

    @objc func paintUndo(_ s: Any?) { canvas.undo() }
    @objc func paintRedo(_ s: Any?) { canvas.redo() }
    // These are reached through the responder chain (the app delegate is its last link),
    // so the text tool's NSTextView gets normal text editing for free.
    @objc func cut(_ s: Any?) { canvas.cutSel() }
    @objc func copy(_ s: Any?) { canvas.copySel() }
    @objc func paste(_ s: Any?) { canvas.pasteFromPasteboard() }
    @objc func delete(_ s: Any?) { canvas.deleteSel() }
    @objc func selectAll(_ s: Any?) { canvas.selectAll() }

    @objc func copyTo(_ s: Any?) {
        guard let img = canvas.selectionImage() else { NSSound.beep(); return }
        guard let u = runSavePanel(defaultName: "untitled.png", title: "Copy To") else { return }
        let b = Bitmap(width: img.width, height: img.height, fill: ps.secondary)
        b.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        if let data = encode(b, for: u) { try? data.write(to: u) }
    }

    @objc func pasteFrom(_ s: Any?) {
        let p = NSOpenPanel()
        p.title = "Paste From"
        p.allowedContentTypes = [.image]
        guard p.runModal() == .OK, let u = p.url, let cg = loadCGImage(u) else { return }
        canvas.pasteImage(cg)
    }

    // MARK: View

    @objc func toggleToolbox(_ s: Any?) { main.showToolbox.toggle() }
    @objc func toggleColorbox(_ s: Any?) { main.showColors.toggle() }
    @objc func toggleStatus(_ s: Any?) { main.showStatus.toggle() }
    @objc func toggleTabBar(_ s: Any?) { main.showTabBar.toggle() }
    @objc func toggleMenusInWindow(_ s: Any?) {
        main.showMenuBar.toggle()
        // keep the canvas from jumping when the bar appears/disappears
        var f = window.frame
        let dh = main.showMenuBar ? WindowMenuBar.height : -WindowMenuBar.height
        f.size.height += dh; f.origin.y -= dh
        window.setFrame(f, display: true, animate: false)
    }
    @objc func toggleGrid(_ s: Any?) { ps.showGrid.toggle(); canvas.needsDisplay = true }
    @objc func toggleTextToolbar(_ s: Any?) {
        if let f = fontToolbar, f.panel.isVisible { f.panel.orderOut(nil) } else { showFontToolbar() }
    }

    func showFontToolbar() {
        if fontToolbar == nil { fontToolbar = FontToolbar() }
        guard let f = fontToolbar else { return }
        if !f.panel.isVisible {
            let wf = window.frame
            f.panel.setFrameTopLeftPoint(NSPoint(x: wf.minX + 80, y: wf.maxY - 60))
        }
        f.panel.orderFront(nil)
    }

    private let zoomSteps: [CGFloat] = [1, 2, 3, 4, 6, 8]
    @objc func zoomNormal(_ s: Any?) { canvas.setZoom(1, center: nil) }
    @objc func zoomLarge(_ s: Any?) { canvas.setZoom(4, center: nil) }
    @objc func zoomIn(_ s: Any?) {
        if let z = zoomSteps.first(where: { $0 > canvas.zoom }) { canvas.setZoom(z, center: nil) }
    }
    @objc func zoomOut(_ s: Any?) {
        if let z = zoomSteps.last(where: { $0 < canvas.zoom }) { canvas.setZoom(z, center: nil) }
    }
    @objc func zoomCustom(_ s: Any?) {
        let levels = [1, 2, 4, 6, 8]
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 70))
        let cur = NSTextField(labelWithString: "Current zoom:   \(Int(canvas.zoom * 100))%")
        cur.frame = NSRect(x: 0, y: 48, width: 260, height: 18)
        v.addSubview(cur)
        var radios: [NSButton] = []
        for (i, l) in levels.enumerated() {
            let b = NSButton(radioButtonWithTitle: "\(l * 100)%", target: self, action: #selector(radioNoop(_:)))
            b.frame = NSRect(x: CGFloat(i % 3) * 85, y: 24 - CGFloat(i / 3) * 22, width: 80, height: 20)
            b.state = CGFloat(l) == canvas.zoom ? .on : .off
            v.addSubview(b); radios.append(b)
        }
        guard runDialog("Custom Zoom", v) else { return }
        if let i = radios.firstIndex(where: { $0.state == .on }) { canvas.setZoom(CGFloat(levels[i]), center: nil) }
    }

    @objc func viewBitmap(_ s: Any?) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let w = PreviewWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        let v = BitmapPreviewView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.image = canvas.selection == nil ? doc.bitmap.image() : snapshotWithSelection()
        v.onClose = { [weak self] in
            self?.previewWindow?.orderOut(nil)
            self?.previewWindow = nil
            self?.window.makeKeyAndOrderFront(nil)
        }
        w.contentView = v
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
        previewWindow = w
    }

    private func snapshotWithSelection() -> CGImage {
        let b = doc.bitmap.copy()
        if let s = canvas.selection, let img = canvas.selectionImage() { b.draw(img, in: s.rect) }
        return b.image()
    }

    // MARK: Image

    @objc func radioNoop(_ s: Any?) {}

    private func radio(_ title: String, _ x: CGFloat, _ y: CGFloat, in v: NSView) -> NSButton {
        let b = NSButton(radioButtonWithTitle: title, target: self, action: #selector(radioNoop(_:)))
        b.frame = NSRect(x: x, y: y, width: 200, height: 20)
        v.addSubview(b)
        return b
    }

    private func field(_ label: String, _ value: String, _ y: CGFloat, in v: NSView, unit: String = "") -> NSTextField {
        let l = NSTextField(labelWithString: label)
        l.frame = NSRect(x: 0, y: y + 2, width: 110, height: 18)
        let f = NSTextField(string: value)
        f.frame = NSRect(x: 112, y: y, width: 60, height: 22)
        let u = NSTextField(labelWithString: unit)
        u.frame = NSRect(x: 178, y: y + 2, width: 80, height: 18)
        v.addSubview(l); v.addSubview(f); v.addSubview(u)
        return f
    }

    private func runDialog(_ title: String, _ accessory: NSView) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.accessoryView = accessory
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    @objc func flipRotate(_ s: Any?) {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 136))
        let fh = radio("Flip horizontal", 0, 114, in: v)
        let fv = radio("Flip vertical", 0, 92, in: v)
        let rot = radio("Rotate by angle", 0, 70, in: v)
        let sub = NSView(frame: NSRect(x: 24, y: 0, width: 200, height: 66))
        v.addSubview(sub)
        let a90 = radio("90°", 0, 44, in: sub)
        let a180 = radio("180°", 0, 22, in: sub)
        _ = radio("270°", 0, 0, in: sub)
        fh.state = .on; a90.state = .on
        guard runDialog("Flip and Rotate", v) else { return }
        if fh.state == .on { canvas.transformImageOrSelection { $0.flippedH() } }
        else if fv.state == .on { canvas.transformImageOrSelection { $0.flippedV() } }
        else if rot.state == .on {
            if a90.state == .on { canvas.transformImageOrSelection { $0.rotated90() } }
            else if a180.state == .on { canvas.transformImageOrSelection { $0.flippedH().flippedV() } }
            else { canvas.transformImageOrSelection { $0.rotated90().rotated90().rotated90() } }
        }
    }

    @objc func stretchSkew(_ s: Any?) {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 150))
        let t1 = NSTextField(labelWithString: "Stretch"); t1.font = .boldSystemFont(ofSize: 12)
        t1.frame = NSRect(x: 0, y: 128, width: 200, height: 18); v.addSubview(t1)
        let sh = field("Horizontal:", "100", 104, in: v, unit: "%")
        let sv = field("Vertical:", "100", 78, in: v, unit: "%")
        let t2 = NSTextField(labelWithString: "Skew"); t2.font = .boldSystemFont(ofSize: 12)
        t2.frame = NSRect(x: 0, y: 52, width: 200, height: 18); v.addSubview(t2)
        let kh = field("Horizontal:", "0", 26, in: v, unit: "Degrees")
        let kv = field("Vertical:", "0", 0, in: v, unit: "Degrees")
        guard runDialog("Stretch and Skew", v) else { return }
        let px = min(500, max(1, sh.doubleValue)) / 100, py = min(500, max(1, sv.doubleValue)) / 100
        let dx = min(89, max(-89, kh.doubleValue)), dy = min(89, max(-89, kv.doubleValue))
        let isSel = canvas.selection != nil
        let fill: RGB? = isSel ? nil : ps.secondary
        canvas.transformImageOrSelection { b in
            var r = (px == 1 && py == 1) ? b : b.stretched(px, py)
            if dx != 0 { r = r.skewedH(dx, fill: fill) }
            if dy != 0 { r = r.skewedV(dy, fill: fill) }
            return r === b ? b.copy() : r
        }
    }

    @objc func removeBackground(_ s: Any?) { canvas.removeBackground() }
    @objc func cropImage(_ s: Any?) { canvas.cropToSelection() }

    @objc func invertColors(_ s: Any?) { canvas.transformImageOrSelection { $0.inverted() } }

    @objc func attributes(_ s: Any?) {
        canvas.commitAll()
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 100))
        var info = "File last saved:   Not Available\nSize on disk:        Not Available"
        if let u = doc.url, let attrs = try? FileManager.default.attributesOfItem(atPath: u.path) {
            let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
            let date = (attrs[.modificationDate] as? Date).map { df.string(from: $0) } ?? "Not Available"
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            info = "File last saved:   \(date)\nSize on disk:        \(size) bytes"
        }
        let l = NSTextField(wrappingLabelWithString: info)
        l.frame = NSRect(x: 0, y: 56, width: 280, height: 40); v.addSubview(l)
        let fw = field("Width:", "\(doc.bitmap.width)", 28, in: v, unit: "pixels")
        let fh = field("Height:", "\(doc.bitmap.height)", 0, in: v, unit: "pixels")
        guard runDialog("Attributes", v) else { return }
        let w = min(10000, max(1, fw.integerValue)), h = min(10000, max(1, fh.integerValue))
        canvas.resizeCanvas(w, h)
    }

    @objc func clearImage(_ s: Any?) {
        canvas.transformImage { b in Bitmap(width: b.width, height: b.height, fill: ps.secondary) }
    }

    @objc func toggleOpaque(_ s: Any?) { ps.transparentSelect.toggle(); ps.notify() }

    // MARK: Colors / Help

    @objc func editColors(_ s: Any?) {
        main.colorBox.editColor(ps.palette.firstIndex(of: ps.primary) ?? -1)
    }

    @objc func helpTopics(_ s: Any?) {
        message("ClassicPaint Help", """
        • Left-click draws with the foreground color, right-click (or Control-click) with the background color.
        • Shift constrains lines to 45° and shapes to squares/circles.
        • Curve: drag a line, then click/drag twice to bend it.
        • Polygon: drag the first side, click for more corners, double-click to close.
        • Select: drag to move. Option-drag copies, Shift-drag smears. Arrow keys nudge.
        • Eraser with right button = Color Eraser (replaces the foreground color only).
        • Drag the blue handles on the canvas edge to resize the picture.
        • ⌘Z Undo, ⌘Y Repeat, ⌘G Grid, ⌘F View Bitmap, ⌘R Flip/Rotate, ⌘E Attributes.
        • View ▸ Menus in Window (⌥⌘M) puts File/Edit/View/… inside the window, like Windows. Option+letter opens a menu.
        • Tabs: ⌘N new picture, ⌘O open (several at once), ⌘W close tab, ⌃⇥ or ⇧⌘] / ⇧⌘[ to switch.
        """)
    }

    @objc func about(_ s: Any?) {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3"
        message("ClassicPaint", "Version \(v)\nA native macOS tribute to the classic Windows paint program.\n\nNot affiliated with, endorsed by, or sponsored by Microsoft. Microsoft Paint is a trademark of Microsoft Corporation.\n\nReleased under the MIT License.")
    }

    func message(_ text: String, _ info: String = "") {
        let a = NSAlert()
        a.messageText = text
        a.informativeText = info
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}

// MARK: - Save panel format chooser

final class FormatChooser: NSObject {
    weak var panel: NSSavePanel?
    let types: [UTType]
    init(panel: NSSavePanel, types: [UTType]) { self.panel = panel; self.types = types }
    @objc func changed(_ sender: NSPopUpButton) {
        guard let p = panel else { return }
        let t = types[max(0, sender.indexOfSelectedItem)]
        p.allowedContentTypes = [t]
        let base = (p.nameFieldStringValue as NSString).deletingPathExtension
        p.nameFieldStringValue = base + "." + (t.preferredFilenameExtension ?? "png")
    }
}

// MARK: - Fonts toolbar (shown with the Text tool)

final class FontToolbar: NSObject, NSComboBoxDelegate {
    let panel: NSPanel
    private let family = NSPopUpButton(frame: NSRect(x: 8, y: 8, width: 190, height: 26), pullsDown: false)
    private let size = NSComboBox(frame: NSRect(x: 204, y: 9, width: 60, height: 24))
    private var bold: NSButton!
    private var italic: NSButton!
    private var underline: NSButton!

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 42),
                        styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        panel.title = "Fonts"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        let v = panel.contentView!

        family.addItems(withTitles: NSFontManager.shared.availableFontFamilies)
        family.selectItem(withTitle: ps.textFont.familyName ?? "Arial")
        family.target = self
        family.action = #selector(changed(_:))

        size.addItems(withObjectValues: [8, 9, 10, 11, 12, 14, 16, 18, 20, 22, 24, 26, 28, 36, 48, 72].map { "\($0)" })
        size.stringValue = "\(Int(ps.textFont.pointSize))"
        size.target = self
        size.action = #selector(changed(_:))
        size.delegate = self

        func toggle(_ t: String, _ x: CGFloat, _ font: NSFont) -> NSButton {
            let b = NSButton(title: t, target: self, action: #selector(changed(_:)))
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .smallSquare
            b.font = font
            b.frame = NSRect(x: x, y: 8, width: 30, height: 26)
            v.addSubview(b)
            return b
        }
        bold = toggle("B", 272, .boldSystemFont(ofSize: 13))
        italic = toggle("I", 306, NSFontManager.shared.convert(.systemFont(ofSize: 13), toHaveTrait: .italicFontMask))
        underline = toggle("U", 340, .systemFont(ofSize: 13))
        v.addSubview(family)
        v.addSubview(size)
    }

    @objc func changed(_ sender: Any?) { apply() }

    func comboBoxSelectionDidChange(_ n: Notification) {
        if let s = size.objectValueOfSelectedItem as? String { size.stringValue = s }
        apply()
    }

    private func apply() {
        let fam = family.titleOfSelectedItem ?? "Arial"
        let sz = CGFloat(max(1, min(400, size.doubleValue)))
        var traits: NSFontTraitMask = []
        if bold.state == .on { traits.insert(.boldFontMask) }
        if italic.state == .on { traits.insert(.italicFontMask) }
        let fm = NSFontManager.shared
        let f = fm.font(withFamily: fam, traits: traits, weight: 5, size: sz)
            ?? fm.font(withFamily: fam, traits: [], weight: 5, size: sz)
            ?? NSFont.systemFont(ofSize: sz)
        ps.textFont = f
        ps.textUnderline = underline.state == .on
        ps.notify()
    }
}

// MARK: - View Bitmap (full screen preview)

final class PreviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class BitmapPreviewView: NSView {
    var image: CGImage?
    var onClose: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        W95.teal.setFill(); bounds.fill()
        guard let img = image, let g = NSGraphicsContext.current?.cgContext else { return }
        g.interpolationQuality = .none
        let r = NSRect(x: 0, y: 0, width: img.width, height: img.height)
        g.saveGState()
        g.translateBy(x: r.minX, y: r.maxY)
        g.scaleBy(x: 1, y: -1)
        g.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        g.restoreGState()
    }
    override func mouseDown(with e: NSEvent) { onClose?() }
    override func rightMouseDown(with e: NSEvent) { onClose?() }
    override func keyDown(with e: NSEvent) { onClose?() }
}

// MARK: - App icon (drawn in code)

func makeAppIcon(_ s: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: s, height: s), flipped: true) { _ in
        let u = s / 32
        func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: NSColor) {
            c.setFill(); NSRect(x: x * u, y: y * u, width: w * u, height: h * u).fill()
        }
        NSGraphicsContext.current?.shouldAntialias = false
        // window frame
        R(3, 4, 26, 24, W95.black)
        R(3, 4, 25, 23, W95.white)
        R(4, 5, 24, 22, W95.shadow)
        R(4, 5, 23, 21, W95.face)
        R(5, 6, 22, 3, W95.navy)
        R(23, 7, 3, 1, W95.white)
        // canvas
        R(7, 10, 18, 15, W95.shadow)
        R(8, 11, 17, 14, W95.white)
        // a little painting
        R(10, 13, 6, 5, NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        R(14, 16, 7, 6, NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        R(18, 12, 5, 4, NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1))
        R(10, 20, 3, 3, NSColor(srgbRed: 0, green: 0.6, blue: 0, alpha: 1))
        // the brush
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 30 * u, y: 2 * u))
        p.line(to: NSPoint(x: 19 * u, y: 15 * u))
        p.lineWidth = 2.2 * u
        NSColor(srgbRed: 0.55, green: 0.3, blue: 0.1, alpha: 1).setStroke()
        NSGraphicsContext.current?.shouldAntialias = true
        p.stroke()
        R(17, 14, 3, 3, W95.shadow)
        let tip = NSBezierPath()
        tip.move(to: NSPoint(x: 17 * u, y: 16 * u))
        tip.line(to: NSPoint(x: 19.5 * u, y: 17.5 * u))
        tip.line(to: NSPoint(x: 15 * u, y: 21 * u))
        tip.close()
        W95.black.setFill(); tip.fill()
        return true
    }
}
