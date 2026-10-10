import Cocoa

struct IPoint: Equatable { var x: Int; var y: Int }

enum Tool: Int, CaseIterable {
    case freeSelect, select, eraser, fill, picker, magnifier, pencil, brush,
         airbrush, text, line, curve, rectangle, polygon, ellipse, roundRect

    var title: String {
        switch self {
        case .freeSelect: return "Free-Form Select"
        case .select: return "Select"
        case .eraser: return "Eraser/Color Eraser"
        case .fill: return "Fill With Color"
        case .picker: return "Pick Color"
        case .magnifier: return "Magnifier"
        case .pencil: return "Pencil"
        case .brush: return "Brush"
        case .airbrush: return "Airbrush"
        case .text: return "Text"
        case .line: return "Line"
        case .curve: return "Curve"
        case .rectangle: return "Rectangle"
        case .polygon: return "Polygon"
        case .ellipse: return "Ellipse"
        case .roundRect: return "Rounded Rectangle"
        }
    }

    var help: String {
        switch self {
        case .freeSelect: return "Selects a free-form part of the picture to move, copy, or edit."
        case .select: return "Selects a rectangular part of the picture to move, copy, or edit."
        case .eraser: return "Erases a portion of the picture, using the selected eraser shape."
        case .fill: return "Fills an area with the current drawing color."
        case .picker: return "Picks up a color from the picture for drawing."
        case .magnifier: return "Changes the magnification."
        case .pencil: return "Draws a free-form line one pixel wide."
        case .brush: return "Draws using a brush with the selected shape and size."
        case .airbrush: return "Draws using an airbrush of the selected size."
        case .text: return "Inserts text into the picture."
        case .line: return "Draws a straight line with the selected line width."
        case .curve: return "Draws a curved line with the selected line width."
        case .rectangle: return "Draws a rectangle with the selected fill style."
        case .polygon: return "Draws a polygon with the selected fill style."
        case .ellipse: return "Draws an ellipse with the selected fill style."
        case .roundRect: return "Draws a rounded rectangle with the selected fill style."
        }
    }
}

final class PaintState {
    private(set) var tool: Tool = .pencil
    var prevTool: Tool = .pencil

    var primary = RGB.black { didSet { notify() } }
    var secondary = RGB.white { didSet { notify() } }

    /// The classic 28-color Paint palette
    var palette: [RGB] = [
        0x000000, 0x808080, 0x800000, 0x808000, 0x008000, 0x008080, 0x000080,
        0x800080, 0x808040, 0x004040, 0x0080FF, 0x004080, 0x8000FF, 0x804000,
        0xFFFFFF, 0xC0C0C0, 0xFF0000, 0xFFFF00, 0x00FF00, 0x00FFFF, 0x0000FF,
        0xFF00FF, 0xFFFF80, 0x00FF80, 0x80FFFF, 0x8080FF, 0xFF0080, 0xFF8040,
    ].map { RGB(hex: $0) }

    var brushIndex = 1
    var eraserIndex = 1
    var airIndex = 0
    var lineWidthIndex = 0
    var shapeStyle = 0              // 0 outline, 1 outline+fill, 2 fill only
    var transparentSelect = false   // "Draw Opaque" unchecked
    var showGrid = false

    var textFont: NSFont = NSFont(name: "Arial", size: 14) ?? NSFont.systemFont(ofSize: 14)
    var textUnderline = false

    var statusText = "For Help, click Help Topics on the Help Menu."
    var coordText = ""
    var sizeText = ""

    var onChange: [() -> Void] = []
    var onToolChange: [() -> Void] = []
    var onStatus: (() -> Void)?

    var lineWidth: Int { lineWidthIndex + 1 }
    var lineStamp: [(Int, Int)] { Stamp.round(lineWidth) }
    var brushStamp: [(Int, Int)] { Stamp.brushes[brushIndex] }
    var eraserSize: Int { Stamp.eraserSizes[eraserIndex] }

    func setTool(_ t: Tool) {
        guard t != tool else { return }
        if (t == .picker || t == .magnifier) && tool != .picker && tool != .magnifier { prevTool = tool }
        tool = t
        statusText = t.help
        onToolChange.forEach { $0() }
        notify()
        onStatus?()
    }

    func notify() { onChange.forEach { $0() } }

    func setStatus(coord: String? = nil, size: String? = nil) {
        if let c = coord { coordText = c }
        if let s = size { sizeText = s }
        onStatus?()
    }
}

let ps = PaintState()

final class PaintDocument {
    var bitmap: Bitmap
    var undoStack: [Bitmap] = []
    var redoStack: [Bitmap] = []
    var url: URL?
    var dirty = false

    // per-tab view state
    var zoom: CGFloat = 1
    var scrollOrigin = NSPoint.zero

    init(width: Int = 640, height: Int = 480) { bitmap = Bitmap(width: width, height: height) }

    /// A blank, unsaved, untouched picture (can be replaced when opening a file)
    var isPristine: Bool { url == nil && !dirty && undoStack.isEmpty }

    private static var untitledCounter = 0
    private let untitledNumber: Int = {
        PaintDocument.untitledCounter += 1
        return PaintDocument.untitledCounter
    }()
    var name: String { url?.lastPathComponent ?? (untitledNumber == 1 ? "untitled" : "untitled \(untitledNumber)") }
    var title: String { "\(name) - ClassicPaint" }

    func pushUndo() {
        undoStack.append(bitmap.copy())
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        dirty = true
        appDelegate?.updateTitle()
    }
    func dropLastUndo() { _ = undoStack.popLast() }

    func undo() -> Bool {
        guard let b = undoStack.popLast() else { return false }
        redoStack.append(bitmap); bitmap = b; dirty = true
        return true
    }
    func redo() -> Bool {
        guard let b = redoStack.popLast() else { return false }
        undoStack.append(bitmap); bitmap = b; dirty = true
        return true
    }
}
