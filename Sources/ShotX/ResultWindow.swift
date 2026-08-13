import AppKit
import AVKit
import UniformTypeIdentifiers

@MainActor
final class ResultWindowController: NSWindowController {
    static let shared = ResultWindowController()
    private var editor: AnnotationView?
    private weak var model: AppModel?
    private var outputCompleted = false
    private let colorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 28))
    private let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 660), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "ShotX 截图标注"
        window.minSize = NSSize(width: 640, height: 440)
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(image: CGImage, model: AppModel) {
        self.model = model
        outputCompleted = false
        let editor = AnnotationView(image: image, settings: model.settings)
        self.editor = editor
        let tools = NSSegmentedControl(labels: AnnotationTool.allCases.map(\.rawValue), trackingMode: .selectOne, target: self, action: #selector(toolChanged(_:)))
        tools.selectedSegment = 0
        colorWell.target = self; colorWell.action = #selector(styleChanged); colorWell.setAccessibilityLabel("标注颜色")
        sizePopup.target = self; sizePopup.action = #selector(styleChanged); sizePopup.setAccessibilityLabel("标注粗细或字号")
        let undo = button("撤销", action: #selector(undo), key: "z")
        let redo = button("重做", action: #selector(redo), key: "Z")
        let copy = button("复制", action: #selector(copyImage), key: "\r")
        let save = button("保存…", action: #selector(saveImage))
        let pin = button("贴图", action: #selector(pinImage))
        let toolbar = NSStackView(views: [tools, colorWell, sizePopup, undo, redo, NSView(), save, pin, copy])
        toolbar.orientation = .horizontal; toolbar.spacing = 8; toolbar.alignment = .centerY
        let scroll = NSScrollView(); scroll.documentView = editor; scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let root = NSStackView(views: [scroll, toolbar]); root.orientation = .vertical; root.spacing = 10; root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        window?.contentView = root
        updateStyleControls(for: .select)
        window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    private func button(_ title: String, action: Selector, key: String = "") -> NSButton { let button = NSButton(title: title, target: self, action: action); button.keyEquivalent = key; return button }
    @objc private func toolChanged(_ sender: NSSegmentedControl) { let tool = AnnotationTool.allCases[sender.selectedSegment]; editor?.tool = tool; updateStyleControls(for: tool) }
    @objc private func styleChanged() {
        guard let editor else { return }; let tool = editor.tool; let size = Double(sizePopup.titleOfSelectedItem ?? "2") ?? 2
        editor.applyStyle(color: colorWell.color, size: size)
        model?.settings.annotationColors[tool.rawValue] = colorWell.color.hex
        model?.settings.annotationSizes[tool.rawValue] = size; model?.persist()
    }
    @objc private func undo() { editor?.undo() }
    @objc private func redo() { editor?.redo() }

    @objc private func copyImage() {
        guard let image = editor?.render() else { return }
        let pasteboard = NSPasteboard.general; pasteboard.clearContents()
        if pasteboard.writeObjects([image]) { outputCompleted = true; model?.recentResult = .image(image); window?.close() }
        else { model?.showError("无法复制。结果仍保留，请重试或保存图片。") }
    }

    @objc private func saveImage() {
        guard let image = editor?.render(), let data = image.pngData else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "ShotX-\(Self.timestamp()).png"
        if let path = model?.settings.lastSaveDirectory { panel.directoryURL = URL(fileURLWithPath: path) }
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic); outputCompleted = true; model?.settings.lastSaveDirectory = url.deletingLastPathComponent().path; model?.persist(); model?.recentResult = .image(image) }
            catch { model?.showError("保存失败。结果仍保留，请重试或另存为。") }
        }
    }

    @objc private func pinImage() { guard let image = editor?.render() else { return }; outputCompleted = true; model?.recentResult = .image(image); PinWindowController.show(image) }
    private func updateStyleControls(for tool: AnnotationTool) {
        let styled = AnnotationTool.styledCases.contains(tool); colorWell.isHidden = !styled || tool == .mosaic; sizePopup.isHidden = !styled
        colorWell.color = NSColor(hex: model?.settings.annotationColors[tool.rawValue] ?? "#FF3B30") ?? .systemRed
        let values: [Double] = tool == .text ? [11, 13, 16, 24, 32] : tool == .mosaic ? [8, 16, 24, 40] : [1, 2, 4, 8]
        sizePopup.removeAllItems(); sizePopup.addItems(withTitles: values.map { String(Int($0)) }); let selected = model?.settings.annotationSizes[tool.rawValue] ?? values.first ?? 2; sizePopup.selectItem(withTitle: String(Int(selected)))
    }
    private static func timestamp() -> String { let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd-HHmmss"; return formatter.string(from: Date()) }
}

extension ResultWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !outputCompleted, editor?.hasEdits == true else { return true }
        let alert = NSAlert(); alert.messageText = "放弃这张截图？"; alert.informativeText = "未输出的标注和裁剪将丢失。"; alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "放弃")
        return alert.runModal() == .alertSecondButtonReturn
    }
}

enum Annotation: Equatable {
    case line(AnnotationTool, CGPoint, CGPoint, NSColor, CGFloat)
    case path([CGPoint], NSColor, CGFloat)
    case text(String, CGPoint, NSColor, CGFloat)
}

enum AnnotationMath {
    /// Perpendicular distance from `point` to the segment `a`–`b` (used for line/arrow/path hit tests).
    static func distance(toSegment point: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        let px = a.x + t * dx, py = a.y + t * dy
        return hypot(point.x - px, point.y - py)
    }

    static func distance(toPath point: CGPoint, points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return points.first.map { hypot(point.x - $0.x, point.y - $0.y) } ?? .greatestFiniteMagnitude }
        return (0..<(points.count - 1)).reduce(CGFloat.greatestFiniteMagnitude) { min($0, distance(toSegment: point, a: points[$1], b: points[$1 + 1])) }
    }

    static func pathLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return 0 }
        var length: CGFloat = 0
        for i in 0..<(points.count - 1) {
            length += hypot(points[i + 1].x - points[i].x, points[i + 1].y - points[i].y)
        }
        return length
    }

    /// Catmull-Rom → cubic Bézier smoothing that passes near every sampled point (FR-BRA71-02).
    static func smoothPath(_ points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard points.count >= 2 else { return path }
        path.move(to: points[0])
        for i in 0..<(points.count - 1) {
            let p0 = points[max(0, i - 1)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(points.count - 1, i + 2)]
            let cp1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let cp2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.curve(to: p2, controlPoint1: cp1, controlPoint2: cp2)
        }
        return path
    }
}

struct EditorState {
    var annotations: [Annotation]
    var crop: CGRect?
}

final class AnnotationView: NSView {
    var tool = AnnotationTool.select {
        didSet { commitTextEditingIfActive() }
    }
    private let original: NSImage
    private let originalCG: CGImage?
    private let pixelsPerPoint: CGFloat
    private let screenPointSize: CGSize
    private var sourceRect: CGRect
    private var annotations: [Annotation] = []
    private var undoStack: [EditorState] = []
    private var redoStack: [EditorState] = []
    private var selected: Int?
    private var moving = false
    private var start: CGPoint?
    private var draft: CGPoint?
    private var strokePoints: [CGPoint] = []
    private var cropRect: CGRect?
    private var textEditor: InlineTextView?
    private var textEditorAnchor = CGPoint.zero
    private var textEditingIndex: Int?
    private var liveColors: [String: NSColor]
    private var liveSizes: [String: CGFloat]
    var managesOwnHistory = true
    var onWillChange: (() -> Void)?
    var onEscape: (() -> Void)?
    var onNudgeSelection: ((CGFloat, CGFloat) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onSelectionDragBegan: ((NSEvent) -> Void)?
    var onSelectionDragged: ((NSEvent) -> Void)?
    var onSelectionDragEnded: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var hasEdits: Bool { !annotations.isEmpty || cropRect != nil }

    init(image: CGImage, settings: AppSettings) {
        let size = NSSize(width: image.width, height: image.height)
        original = NSImage(cgImage: image, size: size)
        originalCG = nil
        pixelsPerPoint = 1
        screenPointSize = size
        sourceRect = CGRect(origin: .zero, size: size)
        liveColors = settings.annotationColors.mapValues { NSColor(hex: $0) ?? .systemRed }
        liveSizes = settings.annotationSizes.mapValues { CGFloat($0) }
        super.init(frame: NSRect(origin: .zero, size: size)); wantsLayer = true
    }
    init(image: CGImage, screenPointSize: CGSize, sourceRect: CGRect, settings: AppSettings) {
        original = NSImage(cgImage: image, size: screenPointSize)
        originalCG = image
        pixelsPerPoint = screenPointSize.width > 0 ? CGFloat(image.width) / screenPointSize.width : 1
        self.screenPointSize = screenPointSize
        self.sourceRect = sourceRect
        liveColors = settings.annotationColors.mapValues { NSColor(hex: $0) ?? .systemRed }
        liveSizes = settings.annotationSizes.mapValues { CGFloat($0) }
        super.init(frame: NSRect(origin: .zero, size: sourceRect.size)); wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = bounded(convert(event.locationInWindow, from: nil))
        commitTextEditingIfActive()
        if tool == .select, let hit = annotations.indices.reversed().first(where: { hitTest(point, annotation: annotations[$0]) }) {
            if event.clickCount >= 2, case .text = annotations[hit] {
                beginTextEditing(existingIndex: hit)
                return
            }
            selected = hit
            moving = true
            remember()
            start = point; draft = point; needsDisplay = true
            return
        }
        if tool == .select {
            if event.clickCount >= 2, onDoubleClick != nil { onDoubleClick?(); return }
            selected = nil
            moving = false
            onSelectionDragBegan?(event)
            start = point; draft = point; needsDisplay = true
            return
        }
        if tool == .text {
            selected = nil
            moving = false
            beginTextEditing(at: point)
            return
        }
        selected = nil
        moving = false
        start = point; draft = point; strokePoints = [point]; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        let point = bounded(convert(event.locationInWindow, from: nil))
        if moving, let selected, let draft { annotations[selected] = offset(annotations[selected], dx: point.x - draft.x, dy: point.y - draft.y) }
        else if tool == .select { onSelectionDragged?(event) }
        else if tool == .pen { if strokePoints.last != point { strokePoints.append(point) } }
        draft = point; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let start, let end = draft else { return }
        defer { self.start = nil; draft = nil; needsDisplay = true }
        if tool == .select, !moving { onSelectionDragEnded?() }
        if tool == .crop { remember(); cropRect = rect(start, end).intersection(bounds) }
        else if tool == .pen {
            if AnnotationMath.pathLength(strokePoints) < 2 {
                remember(); annotations.append(.path([start], color(for: tool), size(for: tool)))
            } else {
                remember(); annotations.append(.path(strokePoints, color(for: tool), size(for: tool)))
            }
        }
        else if tool != .select {
            let shape = rect(start, end)
            if tool == .mosaic && (shape.width < 4 || shape.height < 4) {
                // Tiny drags (both axes < 4 pt) do not create a mosaic object.
            } else {
                remember(); annotations.append(.line(tool, start, end, color(for: tool), size(for: tool)))
            }
        }
        moving = false
        strokePoints = []
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() }
        else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            if managesOwnHistory { event.modifierFlags.contains(.shift) ? redo() : undo() }
            else { event.modifierFlags.contains(.shift) ? onRedo?() : onUndo?() }
        }
        else if event.keyCode == 51, let selected { remember(); annotations.remove(at: selected); self.selected = nil; needsDisplay = true }
        else if let selected, [123, 124, 125, 126].contains(event.keyCode) {
            remember(); let amount: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let delta: (CGFloat, CGFloat) = event.keyCode == 123 ? (-amount, 0) : event.keyCode == 124 ? (amount, 0) : event.keyCode == 125 ? (0, amount) : (0, -amount)
            annotations[selected] = offset(annotations[selected], dx: delta.0, dy: delta.1); needsDisplay = true
        }
        else if [123, 124, 125, 126].contains(event.keyCode) {
            let amount: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let delta: (CGFloat, CGFloat) = event.keyCode == 123 ? (-amount, 0) : event.keyCode == 124 ? (amount, 0) : event.keyCode == 125 ? (0, -amount) : (0, amount)
            onNudgeSelection?(delta.0, delta.1)
        }
        else { super.keyDown(with: event) }
    }
    func undo() { guard let state = undoStack.popLast() else { return }; redoStack.append(stateSnapshot); restore(state) }
    func redo() { guard let state = redoStack.popLast() else { return }; undoStack.append(stateSnapshot); restore(state) }
    func applyStyle(color: NSColor, size: Double) {
        if selected != nil { remember() }
        applyStyleLive(color: color, size: size)
    }
    func applyStyleLive(color: NSColor, size: Double) {
        liveColors[tool.rawValue] = color
        liveSizes[tool.rawValue] = CGFloat(size)
        if let textEditor {
            textEditor.font = NSFont.systemFont(ofSize: CGFloat(size), weight: .semibold)
            textEditor.textColor = color
            resizeTextEditor()
            needsDisplay = true
        }
        guard let selected else { return }
        switch annotations[selected] {
        case .line(let tool, let a, let b, _, _): annotations[selected] = .line(tool, a, b, color, size)
        case .path(let points, _, _): annotations[selected] = .path(points, color, size)
        case .text(let text, let point, _, _): annotations[selected] = .text(text, point, color, size)
        }
        needsDisplay = true
    }
    func styleSize(for tool: AnnotationTool) -> Double { Double(liveSizes[tool.rawValue] ?? CGFloat(AnnotationTool.defaultSize(for: tool))) }

    override func draw(_ dirtyRect: NSRect) {
        drawBaseImage()
        for annotation in annotations { draw(annotation) }
        if let selected { NSColor.controlAccentColor.setStroke(); let path = NSBezierPath(rect: bounds(of: annotations[selected]).insetBy(dx: -4, dy: -4)); path.lineWidth = 1; path.stroke() }
        if tool == .pen, !strokePoints.isEmpty { draw(.path(strokePoints, color(for: tool), size(for: tool))) }
        else if let start, let draft, tool != .select && tool != .text { draw(.line(tool, start, draft, color(for: tool), size(for: tool))) }
        if let cropRect { NSColor.white.withAlphaComponent(0.75).setStroke(); let path = NSBezierPath(rect: cropRect); path.lineWidth = 2; path.stroke() }
        if let textEditor {
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(roundedRect: textEditor.frame.insetBy(dx: -2, dy: -2), xRadius: 4, yRadius: 4)
            border.lineWidth = 1
            border.setLineDash([3, 2], count: 2, phase: 0)
            border.stroke()
        }
    }

    private func drawBaseImage() {
        guard let cg = originalCG else {
            original.draw(in: bounds, from: sourceRect, operation: .copy, fraction: 1)
            return
        }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let pixelRect = Self.cgPixelRect(sourceRect: sourceRect, screenPointSize: screenPointSize, pixelsPerPoint: pixelsPerPoint)
        guard let crop = Self.clampedCrop(cg, pixelRect) else { return }
        let cropped = NSImage(cgImage: crop, size: bounds.size)
        context.saveGState()
        context.clip(to: bounds)
        NSGraphicsContext.current?.imageInterpolation = .high
        cropped.draw(in: bounds)
        context.restoreGState()
    }

    /// Maps a source rect expressed in SelectionView (y-up) coordinates to the frozen CGImage's
    /// native pixel space (top-left origin, y-down), so cropping yields an upright, non-mirrored region.
    static func cgPixelRect(sourceRect: CGRect, screenPointSize: CGSize, pixelsPerPoint: CGFloat) -> CGRect {
        CGRect(x: sourceRect.minX * pixelsPerPoint,
               y: (screenPointSize.height - sourceRect.maxY) * pixelsPerPoint,
               width: sourceRect.width * pixelsPerPoint,
               height: sourceRect.height * pixelsPerPoint)
    }

    static func clampedCrop(_ image: CGImage, _ rect: CGRect) -> CGImage? {
        let boundsRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let r = rect.integral.intersection(boundsRect)
        guard r.width >= 1, r.height >= 1 else { return nil }
        return image.cropping(to: r)
    }

    func render() -> NSImage? {
        commitTextEditingIfActive()
        let target = (cropRect ?? bounds).intersection(bounds)
        guard !target.isEmpty, let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((target.width * pixelsPerPoint).rounded()), pixelsHigh: Int((target.height * pixelsPerPoint).rounded()), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = target.size
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context?.imageInterpolation = .high
        if let cg = originalCG {
            let pixelRect = CGRect(x: (sourceRect.minX + target.minX) * pixelsPerPoint,
                                   y: (screenPointSize.height - sourceRect.maxY + target.minY) * pixelsPerPoint,
                                   width: target.width * pixelsPerPoint,
                                   height: target.height * pixelsPerPoint)
            if let crop = Self.clampedCrop(cg, pixelRect) {
                let cropped = NSImage(cgImage: crop, size: target.size)
                cropped.draw(in: NSRect(origin: .zero, size: target.size))
            }
        } else {
            original.draw(in: bounds, from: sourceRect, operation: .copy, fraction: 1)
        }
        context?.cgContext.translateBy(x: -target.minX, y: target.maxY)
        context?.cgContext.scaleBy(x: 1, y: -1)
        annotations.forEach(draw)
        NSGraphicsContext.restoreGraphicsState()
        let output = NSImage(size: target.size)
        output.addRepresentation(bitmap)
        return output
    }

    private func draw(_ annotation: Annotation) {
        switch annotation {
        case .text(let text, let point, let color, let size): text.draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: color])
        case .path(let points, let color, let width):
            if points.count == 1 {
                color.setFill()
                NSBezierPath(ovalIn: CGRect(x: points[0].x - width / 2, y: points[0].y - width / 2, width: width, height: width)).fill()
                return
            }
            let path = AnnotationMath.smoothPath(points)
            color.setStroke()
            path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.stroke()
        case .line(let tool, let start, let end, let color, let width):
            if tool == .mosaic { mosaic(rect: rect(start, end), size: width); return }
            color.setStroke(); let path = NSBezierPath(); path.lineWidth = width; path.lineCapStyle = .round
            if tool == .rectangle { path.appendRect(rect(start, end)) }
            else if tool == .ellipse { path.appendOval(in: rect(start, end)) }
            else { path.move(to: start); path.line(to: end) }
            path.stroke()
            if tool == .arrow {
                let angle = atan2(end.y - start.y, end.x - start.x); let length = max(10, width * 4)
                let head = NSBezierPath(); head.lineWidth = width; head.move(to: end); head.line(to: CGPoint(x: end.x - length * cos(angle - .pi / 6), y: end.y - length * sin(angle - .pi / 6))); head.move(to: end); head.line(to: CGPoint(x: end.x - length * cos(angle + .pi / 6), y: end.y - length * sin(angle + .pi / 6))); head.stroke()
            }
        }
    }
    /// Pixelates the whole rectangle (FR-BRA71-01: mosaic is a rectangular object, not a brush trail).
    private func mosaic(rect: CGRect, size: CGFloat) {
        let block = max(4, size)
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX
            while x < rect.maxX {
                let tile = CGRect(x: x, y: y, width: min(block, rect.maxX - x), height: min(block, rect.maxY - y)).intersection(bounds)
                if tile.width <= 0 || tile.height <= 0 { x += block; continue }
                if let cg = originalCG {
                    let pixelRect = CGRect(x: (sourceRect.minX + tile.minX) * pixelsPerPoint,
                                           y: (screenPointSize.height - sourceRect.maxY + tile.minY) * pixelsPerPoint,
                                           width: tile.width * pixelsPerPoint,
                                           height: tile.height * pixelsPerPoint)
                    guard let sub = Self.clampedCrop(cg, pixelRect) else { x += block; continue }
                    let tiny = NSImage(size: NSSize(width: 4, height: 4)); tiny.lockFocus(); NSImage(cgImage: sub, size: NSSize(width: 4, height: 4)).draw(in: CGRect(x: 0, y: 0, width: 4, height: 4)); tiny.unlockFocus()
                    NSGraphicsContext.current?.imageInterpolation = .none; tiny.draw(in: tile, from: .zero, operation: .copy, fraction: 1)
                } else {
                    let sourceTile = tile.offsetBy(dx: sourceRect.minX, dy: sourceRect.minY)
                    let tiny = NSImage(size: NSSize(width: 4, height: 4)); tiny.lockFocus(); original.draw(in: CGRect(x: 0, y: 0, width: 4, height: 4), from: sourceTile, operation: .copy, fraction: 1); tiny.unlockFocus()
                    NSGraphicsContext.current?.imageInterpolation = .none; tiny.draw(in: tile, from: .zero, operation: .copy, fraction: 1)
                }
                x += block
            }
            y += block
        }
    }
    var stateSnapshot: EditorState { EditorState(annotations: annotations, crop: cropRect) }
    func update(sourceRect: CGRect) { self.sourceRect = sourceRect; frame.size = sourceRect.size; needsDisplay = true }
    func restore(_ state: EditorState) { annotations = state.annotations; cropRect = state.crop; selected = nil; textEditor?.removeFromSuperview(); textEditor = nil; textEditingIndex = nil; needsDisplay = true }
    private func remember() {
        onWillChange?()
        guard managesOwnHistory else { return }
        undoStack.append(stateSnapshot); if undoStack.count > 20 { undoStack.removeFirst() }; redoStack.removeAll()
    }
    private func offset(_ item: Annotation, dx: CGFloat, dy: CGFloat) -> Annotation {
        switch item {
        case .line(let tool, let a, let b, let color, let width): .line(tool, CGPoint(x: a.x + dx, y: a.y + dy), CGPoint(x: b.x + dx, y: b.y + dy), color, width)
        case .path(let points, let color, let width): .path(points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }, color, width)
        case .text(let text, let point, let color, let size): .text(text, CGPoint(x: point.x + dx, y: point.y + dy), color, size)
        }
    }
    private func bounds(of item: Annotation) -> CGRect {
        switch item {
        case .line(let tool, let a, let b, _, let width):
            if tool == .rectangle || tool == .ellipse || tool == .mosaic { return rect(a, b) }
            return rect(a, b).insetBy(dx: -max(4, width), dy: -max(4, width))
        case .path(let points, _, let width):
            guard let first = points.first else { return .zero }
            let xs = points.map(\.x), ys = points.map(\.y)
            return CGRect(x: xs.min() ?? first.x, y: ys.min() ?? first.y, width: (xs.max() ?? first.x) - (xs.min() ?? first.x), height: (ys.max() ?? first.y) - (ys.min() ?? first.y)).insetBy(dx: -max(4, width), dy: -max(4, width))
        case .text(let text, let point, _, let size): return CGRect(origin: point, size: text.size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold)]))
        }
    }
    private func hitTest(_ point: CGPoint, annotation: Annotation) -> Bool {
        switch annotation {
        case .line(let tool, let a, let b, _, let width):
            if tool == .rectangle || tool == .ellipse || tool == .mosaic { return rect(a, b).insetBy(dx: -4, dy: -4).contains(point) }
            return AnnotationMath.distance(toSegment: point, a: a, b: b) <= max(width / 2, 8)
        case .path(let points, _, let width):
            return AnnotationMath.distance(toPath: point, points: points) <= max(width / 2, 8)
        case .text:
            return bounds(of: annotation).insetBy(dx: -4, dy: -4).contains(point)
        }
    }
    private func color(for tool: AnnotationTool) -> NSColor { liveColors[tool.rawValue] ?? .systemRed }
    private func size(for tool: AnnotationTool) -> CGFloat { liveSizes[tool.rawValue] ?? CGFloat(AnnotationTool.defaultSize(for: tool)) }
    private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect { CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)) }
    private func bounded(_ point: CGPoint) -> CGPoint { CGPoint(x: min(max(0, point.x), bounds.width), y: min(max(0, point.y), bounds.height)) }

    // MARK: In-place text editing (FR-BRA71-04)

    func commitTextEditingIfActive() {
        guard textEditor != nil else { return }
        commitTextEditing()
    }

    private func beginTextEditing(at point: CGPoint? = nil, existingIndex: Int? = nil) {
        commitTextEditingIfActive()
        let color = color(for: .text)
        let size = size(for: .text)
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        let existing = existingIndex.flatMap { index in annotations.indices.contains(index) ? annotations[index] : nil }
        let text = { if case .text(let string, _, _, _)? = existing { string } else { "" } }()
        let origin = { if case .text(_, let origin, _, _)? = existing { origin } else { point ?? .zero } }()

        selected = existingIndex
        textEditingIndex = existingIndex
        textEditorAnchor = origin

        let editor = InlineTextView(frame: .zero)
        editor.font = font
        editor.textColor = color
        editor.string = text
        editor.isRichText = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.drawsBackground = false
        editor.allowsUndo = false
        editor.isHorizontallyResizable = true
        editor.isVerticallyResizable = false
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.maximumNumberOfLines = 1
        editor.textContainer?.lineBreakMode = .byClipping
        editor.onTextChange = { [weak self] in self?.resizeTextEditor() }
        editor.onCommit = { [weak self] in self?.commitTextEditing() }
        editor.onCancel = { [weak self] in self?.commitTextEditing() }
        textEditor = editor
        addSubview(editor)
        resizeTextEditor()
        window?.makeFirstResponder(editor)
        needsDisplay = true
    }

    private func commitTextEditing() {
        guard let editor = textEditor else { return }
        let color = color(for: .text)
        let size = size(for: .text)
        let point = textEditorAnchor
        let string = editor.string
        let index = textEditingIndex
        textEditor = nil
        textEditingIndex = nil
        editor.removeFromSuperview()
        if let index, annotations.indices.contains(index), case .text = annotations[index] {
            if string.isEmpty {
                remember()
                annotations.remove(at: index)
                selected = nil
            } else {
                remember()
                annotations[index] = .text(string, point, color, size)
                selected = index
            }
        } else if !string.isEmpty {
            remember()
            let newIndex = annotations.count
            annotations.append(.text(string, point, color, size))
            selected = newIndex
        }
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    private func resizeTextEditor() {
        guard let textEditor else { return }
        let font = textEditor.font ?? NSFont.systemFont(ofSize: size(for: .text), weight: .semibold)
        let width = max(24, (textEditor.string as NSString).size(withAttributes: [.font: font]).width + 8)
        let height = max(20, font.ascender - font.descender + 6)
        let frame = NSRect(x: textEditorAnchor.x, y: textEditorAnchor.y, width: min(width, bounds.width - textEditorAnchor.x), height: height)
        textEditor.frame = frame
        needsDisplay = true
    }
}

private final class InlineTextView: NSTextView {
    var onTextChange: (() -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func didChangeText() {
        super.didChangeText()
        onTextChange?()
    }
    override func insertNewline(_ sender: Any?) { onCommit?() }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

enum PinZoom {
    static let minScale: CGFloat = 0.1
    static let maxScale: CGFloat = 4.0
    static func clamp(_ scale: CGFloat) -> CGFloat { min(maxScale, max(minScale, scale)) }
    static func initialScale(imageSize: CGSize, visibleSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0, visibleSize.width > 0, visibleSize.height > 0 else { return 1 }
        return min(1, visibleSize.width * 0.6 / imageSize.width, visibleSize.height * 0.6 / imageSize.height)
    }
    static func zoomFactor(deltaY: CGFloat, precise: Bool) -> CGFloat {
        var delta = deltaY
        if precise { delta *= 0.1 }
        guard delta != 0 else { return 1 }
        return pow(1.1, delta)
    }
}

@MainActor
final class PinWindowController: NSWindowController {
    private static var controllers: [PinWindowController] = []
    private let baseImage: NSImage
    private let imageView: PinImageView
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private var controls: NSView?
    private var scale: CGFloat
    private let insets: CGFloat = 8
    private let controlBarHeight: CGFloat = 40

    static func show(_ image: NSImage) { let controller = PinWindowController(image: image); controllers.append(controller); controller.showWindow(nil) }

    init(image: NSImage) {
        baseImage = image
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 800, height: 600)
        scale = PinZoom.initialScale(imageSize: image.size, visibleSize: visible)
        let imageArea = NSSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: imageArea.width + insets * 2, height: imageArea.height + controlBarHeight + insets)), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        imageView = PinImageView(image: image); imageView.imageScaling = .scaleProportionallyUpOrDown; imageView.imageAlignment = .alignCenter
        imageView.setAccessibilityLabel("贴图，置顶窗口")
        window.level = .floating; window.isMovableByWindowBackground = true; window.hasShadow = true; window.setAccessibilityLabel("贴图，置顶窗口")
        super.init(window: window)
        imageView.onScrollZoom = { [weak self] delta, precise in self?.scrollZoom(delta, precise: precise) }
        window.contentView = NSView()
        let opacity = NSSlider(value: 1, minValue: 0.2, maxValue: 1, target: self, action: #selector(changeOpacity(_:))); opacity.setAccessibilityLabel("贴图透明度")
        let closeCopy = NSButton(title: "关闭并复制", target: self, action: #selector(closeAndCopy)); closeCopy.setAccessibilityLabel("关闭并复制")
        let close = NSButton(title: "关闭", target: self, action: #selector(closePin)); close.setAccessibilityLabel("关闭")
        let bar = NSStackView(views: [NSTextField(labelWithString: "透明度"), opacity, zoomLabel, NSView(), closeCopy, close]); bar.orientation = .horizontal; bar.spacing = 8; bar.alignment = .centerY
        controls = bar
        zoomLabel.setAccessibilityLabel("缩放比例")
        if let content = window.contentView {
            content.addSubview(imageView)
            content.addSubview(bar)
        }
        layout()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func layout() {
        guard let window, let content = window.contentView else { return }
        let size = content.bounds.size
        imageView.frame = NSRect(x: insets, y: controlBarHeight, width: max(1, size.width - insets * 2), height: max(1, size.height - controlBarHeight - insets))
        controls?.frame = NSRect(x: 0, y: 0, width: size.width, height: controlBarHeight)
    }

    private func scrollZoom(_ delta: CGFloat, precise: Bool) {
        let next = PinZoom.clamp(scale * PinZoom.zoomFactor(deltaY: delta, precise: precise))
        guard next != scale else { return }
        scale = next
        guard let window else { return }
        let imageArea = NSSize(width: max(1, baseImage.size.width * scale), height: max(1, baseImage.size.height * scale))
        let newSize = NSSize(width: imageArea.width + insets * 2, height: imageArea.height + controlBarHeight + insets)
        let frame = window.frame
        window.setFrame(NSRect(x: frame.midX - newSize.width / 2, y: frame.midY - newSize.height / 2, width: newSize.width, height: newSize.height), display: true, animate: false)
        zoomLabel.stringValue = "\(Int((scale * 100).rounded()))%"
        layout()
    }

    @objc private func changeOpacity(_ sender: NSSlider) { window?.alphaValue = sender.doubleValue }
    @objc private func closeAndCopy() {
        let pasteboard = NSPasteboard.general; pasteboard.clearContents()
        if pasteboard.writeObjects([baseImage]) { close() }
        else { NSSound.beep() }
    }
    @objc private func closePin() { close() }
}

/// Draggable, scroll-to-zoom image view backing the pinned window.
final class PinImageView: NSImageView {
    var onScrollZoom: ((CGFloat, Bool) -> Void)?
    private var dragStart: CGPoint?
    private var dragOrigin: CGPoint?

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        dragOrigin = window?.frame.origin
    }
    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let dragOrigin, let window else { return }
        let current = event.locationInWindow
        window.setFrameOrigin(NSPoint(x: dragOrigin.x + current.x - dragStart.x, y: dragOrigin.y + current.y - dragStart.y))
    }
    override func mouseUp(with event: NSEvent) { dragStart = nil; dragOrigin = nil }
    override func scrollWheel(with event: NSEvent) {
        guard onScrollZoom != nil else { super.scrollWheel(with: event); return }
        onScrollZoom?(event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
    }
}

@MainActor
final class VideoResultWindowController: NSWindowController {
    static let shared = VideoResultWindowController()
    private let player = AVPlayerView()
    private weak var model: AppModel?
    private var source: URL?
    private var saved = false
    private var duration = 0.0
    private var allowClose = false
    private let startSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let endSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false); window.title = "ShotX 录屏预览"; window.minSize = NSSize(width: 600, height: 440)
        super.init(window: window)
        window.delegate = self
        let trim = NSStackView(views: [NSTextField(labelWithString: "起点"), startSlider, NSTextField(labelWithString: "终点"), endSlider]); trim.orientation = .horizontal; trim.spacing = 8
        let actions = NSStackView(views: [NSView(), button("在访达中显示", #selector(reveal)), button("复制", #selector(copyVideo)), button("保存或另存…", #selector(save))]); actions.orientation = .horizontal; actions.spacing = 8
        let root = NSStackView(views: [player, trim, actions]); root.orientation = .vertical; root.spacing = 12; root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12); window.contentView = root
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(url: URL, model: AppModel) {
        source = url; self.model = model
        if case .video(_, let isSaved) = model.recentResult { saved = isSaved } else { saved = false }
        allowClose = false; startSlider.doubleValue = 0; endSlider.doubleValue = 1
        let asset = AVURLAsset(url: url); player.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        Task { duration = (try? await asset.load(.duration).seconds) ?? 0 }
        window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    @objc private func reveal() { if let source { NSWorkspace.shared.activateFileViewerSelecting([source]) } }
    @objc private func copyVideo() { guard let source else { return }; NSPasteboard.general.clearContents(); if !NSPasteboard.general.writeObjects([source as NSURL]) { model?.showError("无法复制视频。恢复文件仍保留，可重试或保存。") } }
    @objc private func save() {
        guard let source else { return }; let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]; panel.nameFieldStringValue = "ShotX-\(Int(Date().timeIntervalSince1970)).mp4"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let target = panel.url else { return }
            Task {
                do {
                    try await VideoExporter.export(source: source, target: target, startFraction: self.startSlider.doubleValue, endFraction: self.endSlider.doubleValue, duration: self.duration)
                    self.saved = true; self.model?.recentResult = .video(target, saved: true); NSWorkspace.shared.activateFileViewerSelecting([target])
                } catch { self.model?.showError("保存失败。恢复文件仍保留，请重试或另存为。") }
            }
        }
    }
}

extension VideoResultWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !allowClose, !saved, let source else { return true }
        let alert = NSAlert(); alert.messageText = "要保存这段录屏吗？"; alert.informativeText = "如果丢弃，将删除这段未保存的录屏和恢复文件。"; alert.addButton(withTitle: "保存…"); alert.addButton(withTitle: "丢弃"); alert.addButton(withTitle: "返回")
        switch alert.runModal() {
        case .alertFirstButtonReturn: save()
        case .alertSecondButtonReturn:
            do { try FileManager.default.removeItem(at: source); model?.recentResult = nil; allowClose = true; return true }
            catch { model?.showError("无法丢弃恢复文件。文件仍保留，可在访达中处理。") }
        default: break
        }
        return false
    }
}

enum VideoExporter {
    static func fractions(start: Double, end: Double) -> (Double, Double) { (min(max(0, start), max(0, end - 0.01)), max(min(1, end), min(1, start + 0.01))) }

    static func export(source: URL, target: URL, startFraction: Double, endFraction: Double, duration: Double) async throws {
        let range = fractions(start: startFraction, end: endFraction)
        if range.0 <= 0.001, range.1 >= 0.999 { try FileManager.default.copyItem(at: source, to: target); return }
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw CocoaError(.fileWriteUnknown) }
        session.outputURL = target; session.outputFileType = .mp4; session.timeRange = CMTimeRange(start: CMTime(seconds: duration * range.0, preferredTimescale: 600), end: CMTime(seconds: duration * range.1, preferredTimescale: 600))
        await session.export()
        guard session.status == .completed else { throw session.error ?? CocoaError(.fileWriteUnknown) }
    }
}

extension NSImage {
    var pngData: Data? { guard let tiff = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }; return bitmap.representation(using: .png, properties: [:]) }
}

extension NSColor {
    convenience init?(hex: String) { let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")); guard value.count == 6, let rgb = Int(value, radix: 16) else { return nil }; self.init(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1) }
    var hex: String { guard let color = usingColorSpace(.deviceRGB) else { return "#FF3B30" }; return String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255)) }
}
