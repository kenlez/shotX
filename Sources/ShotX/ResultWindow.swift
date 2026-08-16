import AppKit
import AVKit
import UniformTypeIdentifiers

@MainActor
final class ResultWindowController: NSWindowController, NSSharingServicePickerDelegate {
    static let shared = ResultWindowController()
    private var editor: AnnotationView?
    private weak var model: AppModel?
    private var shareButton: NSButton?
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
        editor.tool = .move
        self.editor = editor
        let tools = NSSegmentedControl(labels: AnnotationTool.allCases.map(\.rawValue), trackingMode: .selectOne, target: self, action: #selector(toolChanged(_:)))
        tools.selectedSegment = 0
        colorWell.target = self; colorWell.action = #selector(styleChanged); colorWell.setAccessibilityLabel("标注颜色")
        sizePopup.target = self; sizePopup.action = #selector(styleChanged); sizePopup.setAccessibilityLabel("标注粗细或字号")
        let undo = button("撤销", action: #selector(undo), key: "z")
        let redo = button("重做", action: #selector(redo), key: "Z")
        let copy = button("复制", action: #selector(copyImage), key: "\r")
        let save = button("保存…", action: #selector(saveImage))
        let share = button("分享…", action: #selector(shareImage)); shareButton = share
        let pin = button("贴图", action: #selector(pinImage))
        let toolbar = NSStackView(views: [tools, colorWell, sizePopup, undo, redo, NSView(), share, save, pin, copy])
        toolbar.orientation = .horizontal; toolbar.spacing = 8; toolbar.alignment = .centerY
        let scroll = NSScrollView(); scroll.documentView = editor; scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let root = NSStackView(views: [scroll, toolbar]); root.orientation = .vertical; root.spacing = 10; root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        window?.contentView = root
        updateStyleControls(for: .move)
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
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = ShotXOutputName.make(extension: "png")
        if let path = model?.settings.lastSaveDirectory { panel.directoryURL = URL(fileURLWithPath: path) }
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic); outputCompleted = true; model?.settings.lastSaveDirectory = url.deletingLastPathComponent().path; model?.persist(); model?.recentResult = .image(image) }
            catch { model?.showError("保存失败。结果仍保留，请重试或另存为。") }
        }
    }

    @objc private func shareImage() { guard let image = editor?.render(), let shareButton else { return }; NSSharingServicePicker(items: [image]).show(relativeTo: shareButton.bounds, of: shareButton, preferredEdge: .minY) }
    @objc private func pinImage() { guard let image = editor?.render() else { return }; outputCompleted = true; model?.recentResult = .image(image); PinWindowController.show(image) }
    private func updateStyleControls(for tool: AnnotationTool) {
        let styled = AnnotationTool.styledCases.contains(tool); colorWell.isHidden = !styled || tool == .mosaic; sizePopup.isHidden = !styled
        colorWell.color = NSColor(hex: model?.settings.annotationColors[tool.rawValue] ?? "#FF3B30") ?? .systemRed
        let values = tool.styleRange.presets
        sizePopup.removeAllItems(); sizePopup.addItems(withTitles: values.map { String(Int($0)) }); let selected = editor?.styleSize(for: tool) ?? AnnotationTool.defaultSize(for: tool); sizePopup.selectItem(withTitle: String(Int(selected)))
    }
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
    case text(String, CGPoint, NSColor, CGFloat, AnnotationTextStyle)
}

struct EditorState {
    var annotations: [Annotation]
    var crop: CGRect?
}

final class AnnotationView: NSView {
    private enum LineEndpoint { case start, end }
    var tool = AnnotationTool.rectangle { didSet { if tool != oldValue { selected = nil; if AnnotationTool.styledCases.contains(tool) { liveSizes[tool.rawValue] = CGFloat(AnnotationTool.defaultSize(for: tool)) }; needsDisplay = true } } }
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
    private var draggingEndpoint: LineEndpoint?
    private var start: CGPoint?
    private var draft: CGPoint?
    private var draftPath: [CGPoint] = []
    private var cropRect: CGRect?
    private var liveColors: [String: NSColor]
    private var liveSizes: [String: CGFloat]
    private(set) var textStyle = AnnotationTextStyle.normal
    private var textEditor: NSTextField?
    private var editingTextIndex: Int?
    private var isRendering = false
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
    var isEditingText: Bool { textEditor != nil }

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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        moving = false; draggingEndpoint = nil; start = nil; draft = nil; draftPath.removeAll()
        let point = bounded(convert(event.locationInWindow, from: nil))
        if event.clickCount >= 2,
           let index = annotations.indices.reversed().first(where: { index in
               if case .text = annotations[index] { return bounds(of: annotations[index]).insetBy(dx: -8, dy: -8).contains(point) }
               return false
           }) {
            beginTextEntry(editing: index)
            return
        }
        if event.clickCount >= 2, onDoubleClick != nil {
            onDoubleClick?()
            return
        }
        if let endpoint = endpoint(at: point) {
            draggingEndpoint = endpoint
            remember()
            draft = point
            needsDisplay = true
            return
        }
        if let hit = annotations.indices.reversed().first(where: { bounds(of: annotations[$0]).insetBy(dx: -8, dy: -8).contains(point) }) {
            selected = hit
            moving = true
            remember()
            start = point; draft = point; needsDisplay = true
            return
        }
        selected = nil
        moving = false
        if tool == .move { onSelectionDragBegan?(event) }
        if tool == .pen { draftPath = [point] }
        if tool == .crop { onSelectionDragBegan?(event) }
        start = point; draft = point; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        let point = bounded(convert(event.locationInWindow, from: nil))
        if let draggingEndpoint, let selected, case .line(let tool, let start, let end, let color, let width) = annotations[selected] {
            annotations[selected] = .line(tool, draggingEndpoint == .start ? point : start, draggingEndpoint == .end ? point : end, color, width)
        }
        else if moving, let selected, let draft { annotations[selected] = offset(annotations[selected], dx: point.x - draft.x, dy: point.y - draft.y) }
        else if tool == .pen { draftPath.append(point) }
        else if tool == .move || tool == .crop { onSelectionDragged?(event) }
        draft = point; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if draggingEndpoint != nil { draggingEndpoint = nil; draft = nil; needsDisplay = true; return }
        guard let start, let end = draft else { return }
        defer { self.start = nil; draft = nil; draftPath = []; needsDisplay = true }
        if (tool == .move || tool == .crop), !moving { onSelectionDragEnded?() }
        if moving { moving = false; return }
        if tool == .move {
            return
        } else if tool == .text {
            beginTextEntry(at: start)
        } else if tool == .crop { remember(); cropRect = rect(start, end).intersection(bounds) }
        else if tool == .pen { remember(); annotations.append(.path(draftPath.count > 1 ? draftPath : [start, end], color(for: tool), size(for: tool))) }
        else {
            remember(); annotations.append(.line(tool, start, end, color(for: tool), size(for: tool)))
            if tool == .line || tool == .arrow { selected = annotations.count - 1 }
        }
        moving = false
    }

    private func beginTextEntry(at point: CGPoint) {
        finishTextEntry(commit: true)
        let field = NSTextField(frame: CGRect(x: point.x, y: point.y, width: min(280, max(80, bounds.width - point.x)), height: max(28, size(for: .text) + 12)))
        field.placeholderString = "输入文字"
        field.font = AppFonts.annotationFont(size: size(for: .text))
        field.textColor = color(for: .text); field.backgroundColor = NSColor.black.withAlphaComponent(0.72); field.drawsBackground = true
        field.isBordered = true; field.focusRingType = .default; field.target = self; field.action = #selector(commitTextEntry(_:))
        addSubview(field); textEditor = field; window?.makeFirstResponder(field)
    }

    private func beginTextEntry(editing index: Int) {
        finishTextEntry(commit: true)
        guard annotations.indices.contains(index), case .text(let text, let point, let color, let size, let style) = annotations[index] else { return }
        editingTextIndex = index
        selected = index
        textStyle = style
        let textSize = text.size(withAttributes: [.font: AppFonts.annotationFont(size: size)])
        let field = NSTextField(frame: CGRect(x: point.x, y: point.y, width: min(max(80, textSize.width + 28), max(80, bounds.width - point.x)), height: max(28, size + 12)))
        field.stringValue = text
        field.font = AppFonts.annotationFont(size: size)
        field.textColor = color; field.backgroundColor = NSColor.black.withAlphaComponent(0.72); field.drawsBackground = true
        field.isBordered = true; field.focusRingType = .default; field.target = self; field.action = #selector(commitTextEntry(_:))
        addSubview(field); textEditor = field; window?.makeFirstResponder(field); needsDisplay = true
    }

    @objc private func commitTextEntry(_ sender: NSTextField) { finishTextEntry(commit: true) }
    func cancelTextEntry() { finishTextEntry(commit: false) }
    private func finishTextEntry(commit: Bool) {
        guard let field = textEditor else { return }
        if commit, !field.stringValue.isEmpty {
            if let index = editingTextIndex, annotations.indices.contains(index), case .text(_, _, let color, let size, let style) = annotations[index] {
                remember()
                annotations[index] = .text(field.stringValue, field.frame.origin, color, size, style)
            } else {
                remember(); annotations.append(.text(field.stringValue, field.frame.origin, color(for: .text), size(for: .text), textStyle))
            }
        }
        field.removeFromSuperview(); textEditor = nil; window?.makeFirstResponder(self); needsDisplay = true
        editingTextIndex = nil
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { if textEditor != nil { finishTextEntry(commit: false) } else { onEscape?() } }
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
        guard let selected else { return }
        switch annotations[selected] {
        case .line(let tool, let a, let b, _, _): annotations[selected] = .line(tool, a, b, color, size)
        case .path(let points, _, _): annotations[selected] = .path(points, color, size)
        case .text(let text, _, _, _, let style):
            let oldBounds = bounds(of: annotations[selected])
            let measured = text.size(withAttributes: [.font: AppFonts.annotationFont(size: size)])
            annotations[selected] = .text(text, CGPoint(x: oldBounds.midX - measured.width / 2, y: oldBounds.midY - measured.height / 2), color, size, style)
        }
        needsDisplay = true
    }
    func styleSize(for tool: AnnotationTool) -> Double { Double(liveSizes[tool.rawValue] ?? CGFloat(AnnotationTool.defaultSize(for: tool))) }
    func setTextStyle(_ style: AnnotationTextStyle) {
        textStyle = style
        guard let selected, case .text(let text, let point, let color, let size, _) = annotations[selected] else { needsDisplay = true; return }
        remember(); annotations[selected] = .text(text, point, color, size, style); needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        drawBaseImage()
        for (index, annotation) in annotations.enumerated() where index != editingTextIndex { draw(annotation) }
        if !isRendering, let selected {
            NSColor.controlAccentColor.setStroke(); let path = NSBezierPath(rect: bounds(of: annotations[selected]).insetBy(dx: -4, dy: -4)); path.lineWidth = 1; path.stroke()
            if case .line(let tool, let start, let end, _, _) = annotations[selected], tool == .line || tool == .arrow {
                drawEndpoint(at: start); drawEndpoint(at: end)
            }
        }
        guard !isRendering else { return }
        if !moving, tool == .pen, draftPath.count > 1 { draw(.path(draftPath, color(for: tool), size(for: tool))) }
        else if !moving, let start, let draft, tool != .move && tool != .text && tool != .crop { draw(.line(tool, start, draft, color(for: tool), size(for: tool))) }
        if let cropRect { NSColor.white.withAlphaComponent(0.75).setStroke(); let path = NSBezierPath(rect: cropRect); path.lineWidth = 2; path.stroke() }
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
        finishTextEntry(commit: true)
        let target = (cropRect ?? bounds).intersection(bounds)
        guard !target.isEmpty, let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((target.width * pixelsPerPoint).rounded()), pixelsHigh: Int((target.height * pixelsPerPoint).rounded()), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = target.size
        isRendering = true
        let borderWidth = layer?.borderWidth
        layer?.borderWidth = 0
        cacheDisplay(in: target, to: bitmap)
        layer?.borderWidth = borderWidth ?? 0
        isRendering = false
        let output = NSImage(size: target.size)
        output.addRepresentation(bitmap)
        return output
    }

    private func draw(_ annotation: Annotation) {
        switch annotation {
        case .text(let text, let point, let color, let size, let style): drawText(text, at: point, color: color, size: size, style: style)
        case .path(let points, let color, let width):
            guard let first = points.first else { return }
            color.setStroke(); let path = NSBezierPath(); path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.move(to: first); points.dropFirst().forEach { path.line(to: $0) }; path.stroke()
        case .line(let tool, let start, let end, let color, let width):
            if tool == .mosaic { mosaic(in: rect(start, end), size: width); return }
            color.setStroke(); let path = NSBezierPath(); path.lineWidth = width; path.lineCapStyle = .round
            if tool == .rectangle { path.appendRoundedRect(rect(start, end), xRadius: 3, yRadius: 3) }
            else if tool == .ellipse { path.appendOval(in: rect(start, end)) }
            else { path.move(to: start); path.line(to: end) }
            path.stroke()
            if tool == .arrow {
                let angle = atan2(end.y - start.y, end.x - start.x); let length = max(10, width * 4)
                let head = NSBezierPath(); head.lineWidth = width; head.move(to: end); head.line(to: CGPoint(x: end.x - length * cos(angle - .pi / 6), y: end.y - length * sin(angle - .pi / 6))); head.move(to: end); head.line(to: CGPoint(x: end.x - length * cos(angle + .pi / 6), y: end.y - length * sin(angle + .pi / 6))); head.stroke()
            }
        }
    }
    private func drawText(_ text: String, at point: CGPoint, color: NSColor, size: CGFloat, style: AnnotationTextStyle) {
        let font = AppFonts.annotationFont(size: size)
        let outline = Self.focusedStroke(for: color)
        switch style {
        case .normal:
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]).draw(at: point)
        case .outlined:
            drawOutlinedText(text, at: point, font: font, fill: color, outline: outline)
        case .inverseOutlined:
            drawOutlinedText(text, at: point, font: font, fill: outline, outline: color)
        case .highlight:
            let size = text.size(withAttributes: [.font: font]); color.setFill(); NSBezierPath(roundedRect: CGRect(x: point.x - 5, y: point.y - 3, width: size.width + 10, height: size.height + 6), xRadius: 5, yRadius: 5).fill()
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white]).draw(at: point)
        }
    }

    private func drawOutlinedText(_ text: String, at point: CGPoint, font: NSFont, fill: NSColor, outline: NSColor) {
        NSAttributedString(string: text, attributes: [.font: font, .strokeColor: outline, .strokeWidth: 8]).draw(at: point)
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: fill]).draw(at: point)
    }

    static func focusedStroke(for color: NSColor) -> NSColor {
        switch color.hex.uppercased() {
        case "#FA5151": NSColor(hex: "#9F1414")!
        case "#000000": .white
        case "#FFFFFF": .black
        case "#10AEFF": NSColor(hex: "#0075B1")!
        case "#34A853": NSColor(hex: "#00711E")!
        case "#FFC300": NSColor(hex: "#AF8704")!
        default: color.shadow(withLevel: 0.35) ?? .black
        }
    }
    private func mosaic(in area: CGRect, size: CGFloat) {
        let area = area.intersection(bounds).integral
        guard area.width >= 1, area.height >= 1 else { return }
        let source: NSImage
        if let cg = originalCG {
            let pixelRect = CGRect(x: (sourceRect.minX + area.minX) * pixelsPerPoint,
                                   y: (screenPointSize.height - sourceRect.maxY + area.minY) * pixelsPerPoint,
                                   width: area.width * pixelsPerPoint,
                                   height: area.height * pixelsPerPoint)
            guard let sub = Self.clampedCrop(cg, pixelRect) else { return }
            source = NSImage(cgImage: sub, size: area.size)
        } else {
            source = NSImage(size: area.size)
            source.lockFocus(); original.draw(in: NSRect(origin: .zero, size: area.size), from: area.offsetBy(dx: sourceRect.minX, dy: sourceRect.minY), operation: .copy, fraction: 1); source.unlockFocus()
        }
        let tinySize = NSSize(width: max(1, (area.width / size).rounded(.down)), height: max(1, (area.height / size).rounded(.down)))
        let tiny = NSImage(size: tinySize)
        tiny.lockFocus(); NSGraphicsContext.current?.imageInterpolation = .low; source.draw(in: NSRect(origin: .zero, size: tinySize)); tiny.unlockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        tiny.draw(in: area, from: NSRect(origin: .zero, size: tinySize), operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    }
    var stateSnapshot: EditorState { EditorState(annotations: annotations, crop: cropRect) }
    func update(sourceRect: CGRect) { self.sourceRect = sourceRect; frame.size = sourceRect.size; needsDisplay = true }
    func restore(_ state: EditorState) { annotations = state.annotations; cropRect = state.crop; selected = nil; needsDisplay = true }
    private func remember() {
        onWillChange?()
        guard managesOwnHistory else { return }
        undoStack.append(stateSnapshot); if undoStack.count > 20 { undoStack.removeFirst() }; redoStack.removeAll()
    }
    private func offset(_ item: Annotation, dx: CGFloat, dy: CGFloat) -> Annotation { switch item { case .line(let tool, let a, let b, let color, let width): .line(tool, CGPoint(x: a.x + dx, y: a.y + dy), CGPoint(x: b.x + dx, y: b.y + dy), color, width); case .path(let points, let color, let width): .path(points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }, color, width); case .text(let text, let point, let color, let size, let style): .text(text, CGPoint(x: point.x + dx, y: point.y + dy), color, size, style) } }
    private func bounds(of item: Annotation) -> CGRect { switch item { case .line(let tool, let a, let b, _, let width): tool == .mosaic ? rect(a, b) : rect(a, b).insetBy(dx: -max(4, width), dy: -max(4, width)); case .path(let points, _, let width): points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }.insetBy(dx: -max(4, width), dy: -max(4, width)); case .text(let text, let point, _, let size, _): CGRect(origin: point, size: text.size(withAttributes: [.font: AppFonts.annotationFont(size: size)])) } }
    private func endpoint(at point: CGPoint) -> LineEndpoint? {
        guard let selected, case .line(let tool, let start, let end, _, _) = annotations[selected], tool == .line || tool == .arrow else { return nil }
        if hypot(point.x - start.x, point.y - start.y) <= 10 { return .start }
        if hypot(point.x - end.x, point.y - end.y) <= 10 { return .end }
        return nil
    }
    private func drawEndpoint(at point: CGPoint) {
        let rect = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
        NSColor.white.setFill(); NSBezierPath(ovalIn: rect).fill()
        NSColor.controlAccentColor.setStroke(); let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)); ring.lineWidth = 1; ring.stroke()
    }
    private func color(for tool: AnnotationTool) -> NSColor { liveColors[tool.rawValue] ?? .systemRed }
    private func size(for tool: AnnotationTool) -> CGFloat { liveSizes[tool.rawValue] ?? CGFloat(AnnotationTool.defaultSize(for: tool)) }
    private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect { CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)) }
    private func bounded(_ point: CGPoint) -> CGPoint { CGPoint(x: min(max(0, point.x), bounds.width), y: min(max(0, point.y), bounds.height)) }
}

enum PinZoom {
    static let minScale: CGFloat = 0.1
    static let maxScale: CGFloat = 3.0
    static func clamp(_ scale: CGFloat) -> CGFloat { min(maxScale, max(minScale, scale)) }
    static func initialScale(imageSize: CGSize, visibleSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0, visibleSize.width > 0, visibleSize.height > 0 else { return 1 }
        return min(1, visibleSize.width / imageSize.width, visibleSize.height / imageSize.height)
    }
    static func zoomFactor(deltaY: CGFloat, precise: Bool) -> CGFloat {
        var delta = deltaY
        if precise { delta *= 0.1 }
        guard delta != 0 else { return 1 }
        return pow(1.1, delta)
    }
    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
    static func voiceOverValue(_ value: Double) -> String { "当前 \(Int((value * 100).rounded())) 百分比" }
    static func snapValue(_ value: Double, to target: Double, tolerance: Double = 0.1) -> Double? {
        abs(value - target) <= tolerance ? target : nil
    }
}

/// BRA-94 design-mandated slider visuals (sampled from the pin board, @2x: 46 px = 23 pt).
enum PinSliderStyle {
    static let trackHeight: CGFloat = 23
    static let knobDiameter: CGFloat = 23
    static let trackFillAlpha: CGFloat = 0.2
    static let trackStrokeAlpha: CGFloat = 0.2
    static let unityMarkAlpha: CGFloat = 0.5
    static let knobRingHex = "#CCCCCC"
}

/// Borderless pin window that can become key so Cmd+W / Esc work (§8.7).
private final class PinPanel: NSPanel {
    var onCommandW: (() -> Void)?
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "w" {
            onCommandW?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
final class PinWindowController: NSWindowController {
    private static var controllers: [PinWindowController] = []
    private let baseImage: NSImage
    private let imageView: PinImageView
    private let controls = NSStackView()
    private let closeButton = NSButton()
    private let opacitySlider = PinSlider(value: 1, minValue: 0.2, maxValue: 1, target: nil, action: nil)
    private let zoomSlider = PinSlider(value: 1, minValue: Double(PinZoom.minScale), maxValue: Double(PinZoom.maxScale), target: nil, action: nil)
    private let opacityValueLabel = NSTextField(labelWithString: "100%")
    private let zoomValueLabel = NSTextField(labelWithString: "100%")
    private var scale: CGFloat

    static func show(_ image: NSImage) { let controller = PinWindowController(image: image); controllers.append(controller); controller.showWindow(nil) }

    init(image: NSImage) {
        baseImage = image
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame.size ?? NSSize(width: 800, height: 600)
        scale = PinZoom.initialScale(imageSize: image.size, visibleSize: visible)
        let imageArea = NSSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let window = PinPanel(contentRect: NSRect(origin: .zero, size: imageArea), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        imageView = PinImageView(image: image); imageView.imageScaling = .scaleProportionallyUpOrDown; imageView.imageAlignment = .alignCenter
        imageView.setAccessibilityLabel("贴图，置顶窗口")
        window.level = .floating; window.isMovableByWindowBackground = true; window.hasShadow = true; window.setAccessibilityLabel("贴图，置顶窗口")
        window.backgroundColor = .clear; window.isOpaque = false
        super.init(window: window)
        window.onCommandW = { [weak self] in self?.closePin() }
        window.onCancel = { [weak self] in self?.setControlsVisible(false) }
        imageView.onScrollZoom = { [weak self] delta, precise in self?.scrollZoom(delta, precise: precise) }
        let content = PinContainerView(frame: NSRect(origin: .zero, size: imageArea)); content.wantsLayer = true; content.layer?.cornerRadius = 8; content.layer?.masksToBounds = true
        content.onHoverChanged = { [weak self] visible in self?.setControlsVisible(visible) }
        window.contentView = content
        imageView.wantsLayer = true; content.addSubview(imageView)
        closeButton.image = Self.closeImage(); closeButton.imagePosition = .imageOnly; closeButton.isBordered = false; closeButton.target = self; closeButton.action = #selector(closePin); closeButton.setAccessibilityLabel("关闭"); closeButton.alphaValue = 0; content.addSubview(closeButton)
        opacitySlider.configureAppearance(unityMark: false)
        zoomSlider.configureAppearance(unityMark: true)
        opacitySlider.target = self; opacitySlider.action = #selector(changeOpacity(_:)); opacitySlider.isContinuous = true; opacitySlider.setAccessibilityLabel("透明度"); opacitySlider.setAccessibilityValue(PinZoom.voiceOverValue(opacitySlider.doubleValue))
        zoomSlider.target = self; zoomSlider.action = #selector(changeZoom(_:)); zoomSlider.isContinuous = true; zoomSlider.snapValue = 1; zoomSlider.setAccessibilityLabel("缩放"); zoomSlider.setAccessibilityValue(PinZoom.voiceOverValue(zoomSlider.doubleValue))
        controls.orientation = .vertical; controls.spacing = 8; controls.alphaValue = 0
        controls.addArrangedSubview(Self.controlRow(label: "透明度", slider: opacitySlider, valueLabel: opacityValueLabel))
        controls.addArrangedSubview(Self.controlRow(label: "缩  放", slider: zoomSlider, valueLabel: zoomValueLabel))
        content.addSubview(controls)
        zoomSlider.doubleValue = Double(scale)
        zoomValueLabel.stringValue = PinZoom.percent(Double(scale))
        layout()
        if let screen { window.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - imageArea.width / 2, y: screen.visibleFrame.midY - imageArea.height / 2)) } else { window.center() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func layout() {
        guard let window, let content = window.contentView else { return }
        let size = content.bounds.size
        imageView.frame = content.bounds
        closeButton.frame = NSRect(x: max(0, size.width - 26), y: max(0, size.height - 28), width: 22, height: 22)
        let controlWidth = min(300, max(98, size.width - 60))
        controls.frame = NSRect(x: (size.width - controlWidth) / 2, y: min(12, max(0, size.height - 60)), width: controlWidth, height: 60)
    }

    private func scrollZoom(_ delta: CGFloat, precise: Bool) {
        setScale(scale * PinZoom.zoomFactor(deltaY: delta, precise: precise))
    }

    private func setScale(_ proposed: CGFloat) {
        guard let window else { return }
        let visible = window.screen?.visibleFrame.size ?? NSScreen.main?.visibleFrame.size ?? NSSize(width: 800, height: 600)
        let minimum = max(PinZoom.minScale, 100 / max(1, baseImage.size.width), 100 / max(1, baseImage.size.height))
        let maximum = min(PinZoom.maxScale, visible.width / max(1, baseImage.size.width), visible.height / max(1, baseImage.size.height))
        let next = min(maximum, max(min(minimum, maximum), proposed))
        guard next != scale else { return }
        scale = next
        let imageArea = NSSize(width: max(1, baseImage.size.width * scale), height: max(1, baseImage.size.height * scale))
        let frame = window.frame
        window.setFrame(NSRect(x: frame.midX - imageArea.width / 2, y: frame.midY - imageArea.height / 2, width: imageArea.width, height: imageArea.height), display: true, animate: false)
        zoomSlider.maxValue = Double(maximum)
        zoomSlider.doubleValue = Double(scale)
        zoomValueLabel.stringValue = PinZoom.percent(Double(scale))
        zoomSlider.setAccessibilityValue(PinZoom.voiceOverValue(Double(scale)))
        layout()
    }

    @objc private func changeOpacity(_ sender: NSSlider) {
        window?.alphaValue = sender.doubleValue
        opacityValueLabel.stringValue = PinZoom.percent(sender.doubleValue)
        sender.setAccessibilityValue(PinZoom.voiceOverValue(sender.doubleValue))
    }
    @objc private func changeZoom(_ sender: NSSlider) { setScale(sender.doubleValue) }
    @objc private func closePin() { close() }

    private func setControlsVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.2; controls.animator().alphaValue = visible ? 1 : 0; closeButton.animator().alphaValue = visible ? 1 : 0 }
    }

    private static func controlRow(label: String, slider: NSSlider, valueLabel: NSTextField) -> NSView {
        let text = NSTextField(labelWithString: label); text.font = .systemFont(ofSize: 10, weight: .bold); text.textColor = NSColor(hex: "#D9D9D9"); text.alignment = .center; text.widthAnchor.constraint(equalToConstant: 30).isActive = true
        valueLabel.font = .systemFont(ofSize: 10, weight: .bold); valueLabel.textColor = NSColor(hex: "#D9D9D9"); valueLabel.alignment = .left; valueLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let row = NSStackView(views: [text, slider, valueLabel]); row.orientation = .horizontal; row.spacing = 6; row.alignment = .centerY; row.heightAnchor.constraint(equalToConstant: 26).isActive = true
        slider.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return row
    }

    private static func closeImage() -> NSImage {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("ShotX_ShotX.bundle")
        let bundle = packaged.flatMap(Bundle.init(url:)) ?? Bundle.module
        if let url = bundle.url(forResource: "close-pin", withExtension: "svg"), let image = NSImage(contentsOf: url) { return image.shotXSized(NSSize(width: 22, height: 22)) }
        return NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭") ?? NSImage()
    }
}

private final class PinContainerView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private let border = CAShapeLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        border.fillColor = NSColor.clear.cgColor
        border.strokeColor = NSColor.black.withAlphaComponent(0.2).cgColor
        border.lineWidth = 1
        border.zPosition = 1000
        layer?.addSublayer(border)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        border.frame = bounds
        border.contentsScale = window?.backingScaleFactor ?? 2
        border.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 7.5, cornerHeight: 7.5, transform: nil)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
}

private final class PinSlider: NSSlider {
    var snapValue: Double?
    func configureAppearance(unityMark: Bool) {
        let values = (minValue, maxValue, doubleValue)
        let custom = PinSliderCell(); custom.showsUnityMark = unityMark; cell = custom
        minValue = values.0; maxValue = values.1; doubleValue = values.2
    }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        applySnapIfNeeded()
    }
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        applySnapIfNeeded()
    }
    private func applySnapIfNeeded() {
        guard let snapValue, let target = PinZoom.snapValue(doubleValue, to: snapValue) else { return }
        doubleValue = target
        sendAction(action, to: target)
    }
}

private final class PinSliderCell: NSSliderCell {
    var showsUnityMark = false
    private func trackRect() -> NSRect {
        guard let controlView else { return .zero }
        return controlView.bounds.insetBy(dx: 1, dy: 0)
    }
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let height = PinSliderStyle.trackHeight
        let track = NSRect(x: rect.minX + 1, y: rect.midY - height / 2, width: rect.width - 2, height: height)
        let radius = track.height / 2
        NSColor.black.withAlphaComponent(PinSliderStyle.trackFillAlpha).setFill(); NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        NSColor.white.withAlphaComponent(PinSliderStyle.trackStrokeAlpha).setStroke(); let outline = NSBezierPath(roundedRect: track.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5); outline.lineWidth = 1; outline.stroke()
        if showsUnityMark, minValue < 1, maxValue > 1 {
            let x = track.minX + CGFloat((1 - minValue) / (maxValue - minValue)) * track.width
            NSColor.white.withAlphaComponent(PinSliderStyle.unityMarkAlpha).setStroke(); let marker = NSBezierPath(); marker.move(to: CGPoint(x: x, y: track.minY)); marker.line(to: CGPoint(x: x, y: track.maxY)); marker.lineWidth = 1; marker.stroke()
        }
    }
    override func knobRect(flipped: Bool) -> NSRect {
        let bar = trackRect()
        let t = maxValue > minValue ? CGFloat((doubleValue - minValue) / (maxValue - minValue)) : 0
        let centerX = bar.minX + t * bar.width
        let d = PinSliderStyle.knobDiameter
        return NSRect(x: centerX - d / 2, y: bar.midY - d / 2, width: d, height: d)
    }
    override func drawKnob(_ knobRect: NSRect) {
        let d = PinSliderStyle.knobDiameter
        let knob = NSRect(x: knobRect.midX - d / 2, y: knobRect.midY - d / 2, width: d, height: d)
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.3); shadow.shadowBlurRadius = 3; shadow.shadowOffset = NSSize(width: 0, height: -1)
        NSGraphicsContext.saveGraphicsState(); shadow.set()
        NSColor.white.setFill(); NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(hex: PinSliderStyle.knobRingHex)?.setStroke(); let ring = NSBezierPath(ovalIn: knob.insetBy(dx: 0.5, dy: 0.5)); ring.lineWidth = 1; ring.stroke()
    }
}

/// Draggable, scroll-to-zoom image view backing the pinned window.
final class PinImageView: NSImageView {
    var onScrollZoom: ((CGFloat, Bool) -> Void)?
    private var dragStart: CGPoint?
    private var dragOrigin: CGPoint?

    override func mouseDown(with event: NSEvent) {
        dragStart = window?.convertPoint(toScreen: event.locationInWindow)
        dragOrigin = window?.frame.origin
    }
    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let dragOrigin, let window else { return }
        let current = window.convertPoint(toScreen: event.locationInWindow)
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
    private var allowClose = false

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false); window.title = "ShotX 录屏预览"; window.minSize = NSSize(width: 640, height: 460)
        super.init(window: window)
        window.delegate = self
        window.backgroundColor = NSColor(hex: "#202124")
        player.controlsStyle = .floating
        player.wantsLayer = true; player.layer?.cornerRadius = 12; player.layer?.masksToBounds = true
        let saveButton = button("保存或另存…", #selector(save)); saveButton.bezelColor = NSColor(hex: "#07C160")
        let actions = NSStackView(views: [NSView(), button("在访达中显示", #selector(reveal)), button("复制", #selector(copyVideo)), saveButton]); actions.orientation = .horizontal; actions.spacing = 10
        let root = NSStackView(views: [player, actions]); root.orientation = .vertical; root.spacing = 14; root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16); window.contentView = root
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(url: URL, model: AppModel) {
        source = url; self.model = model
        if case .video(_, let isSaved) = model.recentResult { saved = isSaved } else { saved = false }
        allowClose = false
        let asset = AVURLAsset(url: url); player.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    @objc private func reveal() { if let source { NSWorkspace.shared.activateFileViewerSelecting([source]) } }
    @objc private func copyVideo() { guard let source else { return }; NSPasteboard.general.clearContents(); if !NSPasteboard.general.writeObjects([source as NSURL]) { model?.showError("无法复制视频。恢复文件仍保留，可重试或保存。") } }
    @objc private func save() {
        guard let source else { return }; let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]; panel.nameFieldStringValue = ShotXOutputName.make(extension: "mp4")
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let target = panel.url else { return }
            Task {
                do {
                    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                    try FileManager.default.copyItem(at: source, to: target)
                    self.saved = true; self.model?.recentResult = .video(target, saved: true); NSWorkspace.shared.activateFileViewerSelecting([target])
                } catch { self.model?.showError("保存失败。恢复文件仍保留，请重试或另存为。") }
            }
        }
    }
}

extension VideoResultWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !allowClose, !saved, let source else { return true }
        guard FileManager.default.fileExists(atPath: source.path) else {
            player.player = nil
            model?.recentResult = nil
            allowClose = true
            return true
        }
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

    func windowWillClose(_ notification: Notification) { player.player = nil }
}

extension NSImage {
    var pngData: Data? { guard let tiff = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }; return bitmap.representation(using: .png, properties: [:]) }

    func shotXSized(_ size: NSSize) -> NSImage { self.size = size; isTemplate = false; return self }
}

extension NSColor {
    convenience init?(hex: String) { let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")); guard value.count == 6, let rgb = Int(value, radix: 16) else { return nil }; self.init(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1) }
    var hex: String { guard let color = usingColorSpace(.deviceRGB) else { return "#FF3B30" }; return String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255)) }
}
