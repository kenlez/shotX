import AppKit
import Carbon.HIToolbox
import CoreGraphics
import ScreenCaptureKit

@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()
    private var overlays: [SelectionWindowController] = []

    func begin(mode: CaptureMode, model: AppModel, targetScreen: NSScreen? = nil) async {
        cancel()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !content.displays.isEmpty else { throw CaptureError.noContent }
            if mode == .region {
                try await showRegionSelection(content: content, model: model, targetScreen: targetScreen)
            } else if mode == .window {
                showWindowSelection(content: content, model: model)
            } else {
                showScreenSelection(mode: mode, content: content, model: model, targetScreen: targetScreen)
            }
        } catch {
            NSLog("SHOTX-DEBUG begin failed for \(mode.rawValue): \(error)")
            model.showError("无法读取可捕获内容。请检查屏幕录制权限后重试。")
        }
    }

    private func showRegionSelection(content: SCShareableContent, model: AppModel, targetScreen: NSScreen?) async throws {
        for screen in targetScreen.map({ [$0] }) ?? NSScreen.screens {
            guard let display = display(for: screen, in: content) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = max(1, Int((screen.frame.width * screen.backingScaleFactor).rounded()))
            config.height = max(1, Int((screen.frame.height * screen.backingScaleFactor).rounded()))
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let controller = SelectionWindowController(screen: screen, mode: .region, frozenImage: image, model: model)
            controller.onCancel = { [weak self] in self?.cancel() }
            controller.onEditing = { [weak self, weak controller] in
                guard let self, let controller else { return }
                overlays.filter { $0 !== controller }.forEach { $0.close() }
                overlays = [controller]
            }
            controller.onCommit = { [weak self, weak model] image in
                guard let self, let model else { return }
                model.recentResult = .image(image)
                self.cancel()
            }
            overlays.append(controller)
            controller.showWindow(nil)
        }
        NSCursor.crosshair.push()
    }

    private func showScreenSelection(mode: CaptureMode, content: SCShareableContent, model: AppModel, targetScreen: NSScreen? = nil) {
        for screen in targetScreen.map({ [$0] }) ?? NSScreen.screens {
            guard let display = display(for: screen, in: content) else { continue }
            let controller = SelectionWindowController(screen: screen, mode: mode)
            controller.onCancel = { [weak self] in self?.cancel() }
            controller.onQuickRecord = { [weak self, weak model] localRect in
                guard let self, let model, mode == .regionRecording else { return }
                self.cancel()
                Task { await RecordingCoordinator.shared.startImmediately(display: display, screen: screen, localRect: localRect, mode: mode, model: model) }
            }
            controller.onSelection = { [weak self, weak model, weak controller] localRect in
                guard let self, let model else { return }
                let rect = mode.isDisplay ? screen.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) : localRect
                if mode == .scrolling {
                    self.cancel()
                    Task { await ScrollingCaptureCoordinator.shared.start(display: display, screen: screen, localRect: rect, model: model) }
                } else if mode == .regionRecording, let controller {
                    self.prepareRecordingSetup(controller: controller, display: display, screen: screen, localRect: rect, model: model)
                } else if mode == .displayRecording {
                    self.cancel()
                    Task { await RecordingCoordinator.shared.prepare(display: display, screen: screen, localRect: rect, mode: mode, model: model) }
                } else {
                    self.cancel()
                    Task { await self.capture(display: display, screen: screen, localRect: rect, model: model) }
                }
            }
            overlays.append(controller)
            controller.showWindow(nil)
        }
        NSCursor.crosshair.push()
    }

    private func showWindowSelection(content: SCShareableContent, model: AppModel) {
        let candidates = content.windows.filter { window in
            window.isOnScreen && window.windowLayer == 0 && window.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier && window.frame.width > 40 && window.frame.height > 40
        }
        for screen in NSScreen.screens {
            let controller = SelectionWindowController(screen: screen, mode: .window, windows: candidates)
            controller.onCancel = { [weak self] in self?.cancel() }
            controller.onWindow = { [weak self, weak model] window in
                guard let self, let model else { return }
                self.cancel()
                Task { await self.capture(window: window, model: model) }
            }
            overlays.append(controller)
            controller.showWindow(nil)
        }
        NSCursor.pointingHand.push()
    }

    func cancel() {
        if !overlays.isEmpty { NSCursor.pop() }
        overlays.forEach { $0.close() }
        overlays.removeAll()
    }

    private func prepareRecordingSetup(controller: SelectionWindowController, display: SCDisplay, screen: NSScreen, localRect: CGRect, model: AppModel) {
        overlays.filter { $0 !== controller }.forEach { $0.close() }
        overlays = [controller]
        Task { await RecordingCoordinator.shared.prepare(display: display, screen: screen, localRect: localRect, mode: .regionRecording, model: model, selection: controller) }
    }

    private func capture(display: SCDisplay, screen: NSScreen, localRect: CGRect, model: AppModel) async {
        let scale = screen.backingScaleFactor
        let source = CGRect(x: max(0, localRect.minX), y: max(0, screen.frame.height - localRect.maxY), width: min(localRect.width, screen.frame.width), height: min(localRect.height, screen.frame.height)).integral
        guard source.width >= 1, source.height >= 1 else { return }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = source
        config.width = max(1, Int((source.width * scale).rounded()))
        config.height = max(1, Int((source.height * scale).rounded()))
        config.showsCursor = false
        config.captureResolution = .best
        do { model.accept(try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)) }
        catch { model.showError("截图失败。结果未创建，请重新选择。") }
    }

    private func capture(window: SCWindow, model: AppModel) async {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.ignoreShadowsSingleWindow = !model.settings.windowShadow
        config.captureResolution = .best
        config.showsCursor = false
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        config.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        do { model.accept(try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)) }
        catch { model.showError("窗口截图失败。结果未创建，请重试。") }
    }

    private func display(for screen: NSScreen, in content: SCShareableContent) -> SCDisplay? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return content.displays.first { $0.displayID == number.uint32Value }
    }
}

private enum CaptureError: Error { case noContent }

@MainActor
final class SelectionWindowController: NSWindowController {
    var onCancel: (() -> Void)?
    var onSelection: ((CGRect) -> Void)?
    var onQuickRecord: ((CGRect) -> Void)?
    var onWindow: ((SCWindow) -> Void)?
    var onCommit: ((NSImage) -> Void)?
    var onEditing: (() -> Void)?

    private let view: SelectionView

    init(screen: NSScreen, mode: CaptureMode, windows: [SCWindow] = [], frozenImage: CGImage? = nil, model: AppModel? = nil) {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = false
        view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), mode: mode, screen: screen, windows: windows, frozenImage: frozenImage, model: model)
        super.init(window: window)
        view.onCancel = { [weak self] in self?.onCancel?() }
        view.onSelection = { [weak self] in self?.onSelection?($0) }
        view.onQuickRecord = { [weak self] in self?.onQuickRecord?($0) }
        view.onWindow = { [weak self] in self?.onWindow?($0) }
        view.onCommit = { [weak self] in self?.onCommit?($0) }
        view.onEditing = { [weak self] in self?.onEditing?() }
        window.contentView = view
        window.makeFirstResponder(view)
    }

    required init?(coder: NSCoder) { fatalError() }

    var selectionRect: CGRect { view.selectionRect }

    func enterRecordingSetup(onChanged: @escaping (CGRect) -> Void, onExit: @escaping () -> Void) {
        view.onSelectionChanged = onChanged
        view.onExitSetup = onExit
        view.enterRecordingSetup()
    }

    func exitRecordingSetup() {
        view.onSelectionChanged = nil
        view.onExitSetup = nil
        view.exitRecordingSetup()
    }

    func hideForCountdown() { window?.orderOut(nil) }
    func showForSetup() { window?.orderFrontRegardless() }
}

enum RegionCapturePhase: Equatable {
    case selecting, editing, committed, discarded

    mutating func release(validSelection: Bool) { if self == .selecting, validSelection { self = .editing } }
    mutating func commit() { if self == .editing { self = .committed } }
    mutating func discard() { if self != .committed { self = .discarded } }
}

private struct RegionEditSnapshot {
    let selection: CGRect
    let editor: EditorState
}

private enum SelectionHandle {
    case move, north, south, east, west, northEast, northWest, southEast, southWest
}

final class SelectionView: NSView {
    var onCancel: (() -> Void)?
    var onSelection: ((CGRect) -> Void)?
    var onWindow: ((SCWindow) -> Void)?
    var onCommit: ((NSImage) -> Void)?
    var onEditing: (() -> Void)?
    var onQuickRecord: ((CGRect) -> Void)?
    var onSelectionChanged: ((CGRect) -> Void)?
    var onExitSetup: (() -> Void)?
    private(set) var setupActive = false
    private let mode: CaptureMode
    private let targetScreen: NSScreen
    private let windows: [SCWindow]
    private var start: CGPoint?
    private var selection = CGRect.zero
    private var hoveredWindow: SCWindow?
    private var phase = RegionCapturePhase.selecting
    private let frozenImage: NSImage?
    private let frozenCG: CGImage?
    private weak var model: AppModel?
    private var editor: AnnotationView?
    private var toolbar: NSVisualEffectView?
    private var toolControl: NSSegmentedControl?
    private var toolbarFixedSize = NSSize.zero
    private let colorButton = NSButton(frame: NSRect(x: 0, y: 0, width: 40, height: 26))
    private let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var colorPanel: NSPanel?
    private var eyedropperMonitor: Any?
    private var eyedropperClickMonitor: Any?
    private var eyedropperKeyMonitor: Any?
    private var eyedropperWindow: NSPanel?
    private var currentAnnotationColor = NSColor.systemRed
    private var movingSelection = false
    private var activeHandle: SelectionHandle?
    private var initialSelection = CGRect.zero
    private var dragOrigin = CGPoint.zero
    private var undoStack: [RegionEditSnapshot] = []
    private var redoStack: [RegionEditSnapshot] = []
    private var pendingShareImage: NSImage?

    init(frame: CGRect, mode: CaptureMode, screen: NSScreen, windows: [SCWindow], frozenImage: CGImage? = nil, model: AppModel? = nil) {
        self.mode = mode
        targetScreen = screen
        self.windows = windows
        self.model = model
        self.frozenCG = frozenImage
        self.frozenImage = frozenImage.map { NSImage(cgImage: $0, size: screen.frame.size) }
        super.init(frame: frame)
        wantsLayer = true
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    var selectionRect: CGRect { selection }

    func enterRecordingSetup() {
        setupActive = true
        needsDisplay = true
    }

    func exitRecordingSetup() {
        setupActive = false
        needsDisplay = true
    }

    private func notifySelectionChanged() { onSelectionChanged?(selection) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            if setupActive { onExitSetup?(); return }
            if eyedropperWindow != nil {
                stopEyeDropper()
                return
            }
            if colorPanel?.isVisible == true {
                hideColorPanel()
                return
            }
            phase.discard(); onCancel?()
        }
        else if event.keyCode == UInt16(kVK_Space), mode == .region, phase == .editing {
            quickCopy()
        }
        else if event.keyCode == UInt16(kVK_Space), mode == .regionRecording, phase == .editing, !setupActive {
            quickRecord()
        }
        else if mode == .region, phase == .editing, event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" { event.modifierFlags.contains(.shift) ? redo() : undo() }
        else if event.keyCode == UInt16(kVK_Return), mode.isDisplay { onSelection?(bounds) }
        else if event.keyCode == UInt16(kVK_Return), mode == .regionRecording, phase == .editing, !setupActive { onSelection?(selection) }
        else if event.keyCode == UInt16(kVK_Return), let hoveredWindow { onWindow?(hoveredWindow) }
        else { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        if mode == .window { if let hoveredWindow { onWindow?(hoveredWindow) }; return }
        if mode.isDisplay { onSelection?(bounds); return }
        let point = convert(event.locationInWindow, from: nil)
        if (mode == .region || mode == .regionRecording), phase == .editing {
            if event.clickCount >= 2, mode == .region, editor?.tool == .select, selection.contains(point) {
                quickCopy()
                return
            }
            activeHandle = handle(at: point)
            guard activeHandle != nil else { return }
            remember()
            movingSelection = true
            dragOrigin = point
            initialSelection = selection
            return
        }
        start = point
        selection = CGRect(origin: start!, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if movingSelection, let activeHandle {
            resizeSelection(handle: activeHandle, to: bounded(convert(event.locationInWindow, from: nil)))
            updateEditorFrame()
            needsDisplay = true
            notifySelectionChanged()
            return
        }
        guard let start else { return }
        let point = bounded(convert(event.locationInWindow, from: nil))
        selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y)).integral
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if movingSelection {
            movingSelection = false
            activeHandle = nil
            notifySelectionChanged()
            return
        }
        guard start != nil else { return }
        start = nil
        if mode == .region || mode == .regionRecording {
            phase.release(validSelection: selection.width >= 1 && selection.height >= 1)
            if phase == .editing {
                onEditing?()
                if mode == .region { beginRegionEditing() }
                else { window?.makeFirstResponder(self) }
            }
        } else if selection.width >= 1, selection.height >= 1 { onSelection?(selection) }
    }

    override func mouseMoved(with event: NSEvent) {
        guard mode == .window else { return }
        let local = convert(event.locationInWindow, from: nil)
        let appKitGlobal = CGPoint(x: targetScreen.frame.minX + local.x, y: targetScreen.frame.minY + local.y)
        let cgPoint = CGPoint(x: appKitGlobal.x, y: NSScreen.screens[0].frame.height - appKitGlobal.y)
        hoveredWindow = windows.first { $0.frame.contains(cgPoint) }
        needsDisplay = true
    }

    private func bounded(_ point: CGPoint) -> CGPoint { CGPoint(x: min(max(0, point.x), bounds.maxX), y: min(max(0, point.y), bounds.maxY)) }

    override func draw(_ dirtyRect: NSRect) {
        frozenImage?.draw(in: bounds)
        NSColor.black.withAlphaComponent(setupActive ? 0.28 : 0.45).setFill()
        let shade = NSBezierPath(rect: bounds)
        let focus: CGRect
        if mode == .window, let hoveredWindow {
            let global = hoveredWindow.frame
            focus = CGRect(x: global.minX - targetScreen.frame.minX, y: NSScreen.screens[0].frame.height - global.maxY - targetScreen.frame.minY, width: global.width, height: global.height).intersection(bounds)
        } else if mode.isDisplay { focus = bounds.insetBy(dx: 4, dy: 4) }
        else { focus = selection }
        if !focus.isEmpty {
            shade.appendRect(focus); shade.windingRule = .evenOdd
        }
        shade.fill()
        if !focus.isEmpty {
            if setupActive {
                drawSetupBorder(around: focus)
            } else {
                NSColor.controlAccentColor.setStroke()
                let path = NSBezierPath(rect: focus)
                path.lineWidth = mode.isDisplay ? 3 : 2
                path.stroke()
            }
            if (mode == .region || mode == .regionRecording), phase == .editing { drawHandles(around: focus) }
        }
        drawLabel(focus: focus)
    }

    private func drawSetupBorder(around rect: CGRect) {
        NSColor.black.setStroke()
        let outer = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)); outer.lineWidth = 3; outer.stroke()
        NSColor.white.setStroke()
        let inner = NSBezierPath(rect: rect.insetBy(dx: 2, dy: 2)); inner.lineWidth = 2; inner.stroke()
        for (x, y, sx, sy) in [(3.0, 3.0, 1.0, 1.0), (rect.maxX - 3, rect.minY + 3, -1, 1), (rect.minX + 3, rect.maxY - 3, 1, -1), (rect.maxX - 3, rect.maxY - 3, -1, -1)] {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: x + 16 * sx, y: y))
            path.line(to: CGPoint(x: x, y: y))
            path.line(to: CGPoint(x: x, y: y + 16 * sy))
            path.lineWidth = 3
            path.stroke()
        }
    }

    private func drawLabel(focus: CGRect) {
        let scale = targetScreen.backingScaleFactor
        let size = focus.isEmpty ? "" : "  ·  \(Int((focus.width * scale).rounded())) × \(Int((focus.height * scale).rounded())) px"
        let hint: String
        if setupActive {
            hint = ""
        } else if mode == .regionRecording, phase == .editing {
            hint = "  ·  空格 开始录制  ·  回车 录制设置  ·  Esc 取消"
        } else if mode == .region && phase == .editing {
            hint = "  ·  拖动选区或边角  ·  空格/双击 复制  ·  Esc 取消"
        } else {
            hint = "  ·  Esc 取消"
        }
        let text = "\(setupActive ? "录制区域" : mode.rawValue)\(size)\(hint)"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let rect = CGRect(x: (bounds.width - textSize.width) / 2 - 12, y: bounds.height - 54, width: textSize.width + 24, height: 32)
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        string.draw(at: CGPoint(x: rect.minX + 12, y: rect.minY + 8))
    }

    private func beginRegionEditing() {
        guard let frozenImage, let cgImage = frozenImage.cgImage(forProposedRect: nil, context: nil, hints: nil), let model else { return }
        let editor = AnnotationView(image: cgImage, screenPointSize: bounds.size, sourceRect: selection, settings: model.settings)
        editor.managesOwnHistory = false
        editor.onWillChange = { [weak self] in self?.remember() }
        editor.onEscape = { [weak self] in
            guard let self else { return }
            if self.eyedropperWindow != nil { self.stopEyeDropper(); return }
            if self.colorPanel?.isVisible == true { self.hideColorPanel(); return }
            self.phase.discard(); self.onCancel?()
        }
        editor.onUndo = { [weak self] in self?.undo() }
        editor.onRedo = { [weak self] in self?.redo() }
        editor.onNudgeSelection = { [weak self] dx, dy in self?.nudgeSelection(dx: dx, dy: dy) }
        editor.onSelectionDragBegan = { [weak self] event in self?.beginSelectionMove(with: event) }
        editor.onSelectionDragged = { [weak self] event in self?.continueSelectionMove(with: event) }
        editor.onSelectionDragEnded = { [weak self] in self?.endSelectionMove() }
        editor.onDoubleClick = { [weak self] in self?.quickCopy() }
        self.editor = editor
        addSubview(editor)
        updateEditorFrame()
        makeToolbar()
        window?.makeFirstResponder(editor)
        NSCursor.pop(); NSCursor.arrow.push()
        needsDisplay = true
    }

    private func makeToolbar() {
        let tools = NSSegmentedControl(labels: AnnotationTool.allCases.map(\.rawValue), trackingMode: .selectOne, target: self, action: #selector(toolChanged(_:)))
        tools.selectedSegment = 0
        toolControl = tools
        colorButton.target = self; colorButton.action = #selector(colorPressed); colorButton.setAccessibilityLabel("标注颜色"); colorButton.toolTip = "标注颜色"
        sizePopup.target = self; sizePopup.action = #selector(styleChanged); sizePopup.setAccessibilityLabel("标注粗细或字号")
        let stack = NSStackView(views: [tools, colorButton, sizePopup, button("撤销", #selector(undoPressed)), button("重做", #selector(redoPressed)), button("分享…", #selector(sharePressed)), button("保存…", #selector(savePressed)), button("贴图", #selector(pinPressed)), button("复制", #selector(copyPressed))])
        stack.orientation = .horizontal; stack.spacing = 7; stack.alignment = .centerY
        let toolbar = NSVisualEffectView(frame: .zero); toolbar.material = .hudWindow; toolbar.state = .active; toolbar.wantsLayer = true; toolbar.layer?.cornerRadius = 10; toolbar.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 10), stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -10), stack.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 7), stack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -7)])
        toolbar.layoutSubtreeIfNeeded()
        updateStyleControls(for: .select)
        toolbar.layoutSubtreeIfNeeded()
        toolbarFixedSize = toolbar.fittingSize
        addSubview(toolbar); self.toolbar = toolbar
        positionToolbar()
    }

    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    @objc private func toolChanged(_ sender: NSSegmentedControl) { let tool = AnnotationTool.allCases[sender.selectedSegment]; editor?.tool = tool; updateStyleControls(for: tool); window?.makeFirstResponder(editor) }

    @objc private func colorPressed() {
        if colorPanel?.isVisible == true {
            hideColorPanel()
        } else {
            showColorPanel()
        }
    }

    private func showColorPanel() {
        guard let window else { return }
        hideColorPanel()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 296, height: 108), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = makeColorPanelContent()
        colorPanel = panel
        positionColorPanel()
        panel.orderFrontRegardless()
    }

    private func hideColorPanel() {
        colorPanel?.orderOut(nil)
        colorPanel = nil
    }

    private func makeColorPanelContent() -> NSView {
        let content = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 296, height: 108))
        content.material = .hudWindow; content.state = .active; content.wantsLayer = true; content.layer?.cornerRadius = 10
        let presets: [NSColor] = ["#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#5AC8FA", "#007AFF", "#AF52DE", "#FF2D55", "#A2845E", "#8E8E93", "#FFFFFF", "#000000"].compactMap { NSColor(hex: $0) }
        var swatches: [NSButton] = []
        for (index, color) in presets.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(presetPicked(_:)))
            b.setButtonType(.momentaryChange)
            b.bezelStyle = .regularSquare
            b.image = Self.swatchImage(color, size: NSSize(width: 20, height: 16))
            b.imagePosition = .imageOnly
            b.tag = index
            b.setAccessibilityLabel("预设颜色 \(color.hex)")
            swatches.append(b)
        }
        let row1 = NSStackView(views: Array(swatches[0..<6])); row1.orientation = .horizontal; row1.spacing = 6; row1.alignment = .centerY
        let row2 = NSStackView(views: Array(swatches[6..<12])); row2.orientation = .horizontal; row2.spacing = 6; row2.alignment = .centerY
        let grid = NSStackView(views: [row1, row2]); grid.orientation = .vertical; grid.spacing = 6
        let eyedrop = NSButton(title: "取色器", target: self, action: #selector(eyedropperPressed))
        eyedrop.bezelStyle = .rounded
        eyedrop.setAccessibilityLabel("从屏幕取色")
        let bottom = NSStackView(views: [eyedrop, NSView()])
        bottom.orientation = .horizontal; bottom.spacing = 8
        let root = NSStackView(views: [grid, bottom])
        root.orientation = .vertical; root.spacing = 10; root.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor), root.trailingAnchor.constraint(equalTo: content.trailingAnchor), root.topAnchor.constraint(equalTo: content.topAnchor), root.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        return content
    }

    @objc private func presetPicked(_ sender: NSButton) {
        let presets: [NSColor] = ["#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#5AC8FA", "#007AFF", "#AF52DE", "#FF2D55", "#A2845E", "#8E8E93", "#FFFFFF", "#000000"].compactMap { NSColor(hex: $0) }
        guard sender.tag >= 0, sender.tag < presets.count else { return }
        applyPickedColor(presets[sender.tag])
    }

    private func applyPickedColor(_ color: NSColor) {
        guard let editor, let model else { return }
        let tool = editor.tool
        let size = Double(sizePopup.titleOfSelectedItem ?? "2") ?? 2
        editor.applyStyle(color: color, size: size)
        model.settings.annotationColors[tool.rawValue] = color.hex
        model.settings.annotationSizes[tool.rawValue] = size
        model.persist()
        currentAnnotationColor = color
        updateColorButton()
    }

    @objc private func eyedropperPressed() {
        hideColorPanel()
        startEyeDropper()
    }

    private func startEyeDropper() {
        guard let window, frozenCG != nil else { return }
        NSCursor.crosshair.push()
        let size = NSSize(width: 168, height: 168)
        let origin = CGPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y + size.height)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = EyeDropperPreviewView(frame: NSRect(origin: .zero, size: size))
        eyedropperWindow = panel
        panel.orderFrontRegardless()
        positionEyeDropper()
        updateEyeDropper()
        eyedropperMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            guard let self else { return event }
            self.positionEyeDropper()
            self.updateEyeDropper()
            return event
        }
        eyedropperClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            let color = self.samplePixel(at: NSEvent.mouseLocation)
            self.stopEyeDropper()
            if let color { self.applyPickedColor(color) }
            return nil
        }
        eyedropperKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }
            self.stopEyeDropper()
            return nil
        }
    }

    private func stopEyeDropper() {
        if let monitor = eyedropperMonitor { NSEvent.removeMonitor(monitor) }
        eyedropperMonitor = nil
        if let monitor = eyedropperClickMonitor { NSEvent.removeMonitor(monitor) }
        eyedropperClickMonitor = nil
        if let monitor = eyedropperKeyMonitor { NSEvent.removeMonitor(monitor) }
        eyedropperKeyMonitor = nil
        eyedropperWindow?.orderOut(nil)
        eyedropperWindow = nil
        NSCursor.pop()
        window?.makeFirstResponder(editor)
    }

    private func positionEyeDropper() {
        guard let eyedropperWindow else { return }
        let size = eyedropperWindow.frame.size
        let mouse = NSEvent.mouseLocation
        // Keep the preview above the cursor so it never occludes the pixel being sampled.
        var x = mouse.x - size.width / 2
        var y = mouse.y + size.height + 16
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            x = min(max(screen.frame.minX + 8, x), screen.frame.maxX - size.width - 8)
            y = min(max(screen.frame.minY + 8, y), screen.frame.maxY - 8)
            if y > mouse.y + 8 { y = mouse.y + size.height + 16 }
        }
        eyedropperWindow.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func updateEyeDropper() {
        guard let view = eyedropperWindow?.contentView as? EyeDropperPreviewView, frozenCG != nil else { return }
        let mouse = NSEvent.mouseLocation
        if let image = sampleRegion(at: mouse, spanPoints: 24) {
            let center = Self.pixelColor(in: image, at: CGPoint(x: image.width / 2, y: image.height / 2))
            view.show(image: image, color: center, magnification: 6)
        }
    }

    /// Samples a square region of the frozen screen image around a screen point (AppKit y-up coords).
    /// The frozen CGImage is the true screen content captured at selection time, so this reads real
    /// pixels under the selection without being intercepted by any overlay.
    private func sampleRegion(at location: CGPoint, spanPoints: CGFloat) -> CGImage? {
        guard let frozenCG, targetScreen.frame.width > 0 else { return nil }
        let scale = CGFloat(frozenCG.width) / targetScreen.frame.width
        let localX = location.x - targetScreen.frame.minX
        let localY = location.y - targetScreen.frame.minY
        let centerX = localX * scale
        let centerY = (targetScreen.frame.height - localY) * scale
        let half = spanPoints * scale / 2
        let rect = CGRect(x: centerX - half, y: centerY - half, width: spanPoints * scale, height: spanPoints * scale)
        let bounds = CGRect(x: 0, y: 0, width: frozenCG.width, height: frozenCG.height)
        let r = rect.integral.intersection(bounds)
        guard r.width >= 1, r.height >= 1 else { return nil }
        return frozenCG.cropping(to: r)
    }

    private func samplePixel(at location: CGPoint) -> NSColor? {
        guard let image = sampleRegion(at: location, spanPoints: 2) else { return nil }
        return Self.pixelColor(in: image, at: CGPoint(x: image.width / 2, y: image.height / 2))
    }

    private static func pixelColor(in image: CGImage, at point: CGPoint) -> NSColor? {
        let x = min(max(0, Int(point.x)), image.width - 1)
        let y = min(max(0, Int(point.y)), image.height - 1)
        let row = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let bpp = image.bitsPerPixel / 8
        guard bpp >= 3 else { return nil }
        let red = CGFloat(bytes[row]) / 255
        let green = CGFloat(bytes[row + 1]) / 255
        let blue = CGFloat(bytes[row + 2]) / 255
        return NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
    }

    @objc private func styleChanged() {
        guard let editor, let model else { return }
        let tool = editor.tool; let size = Double(sizePopup.titleOfSelectedItem ?? "2") ?? 2
        editor.applyStyle(color: currentAnnotationColor, size: size)
        model.settings.annotationColors[tool.rawValue] = currentAnnotationColor.hex; model.settings.annotationSizes[tool.rawValue] = size; model.persist()
    }
    @objc private func undoPressed() { undo() }
    @objc private func redoPressed() { redo() }
    @objc private func copyPressed() {
        guard let image = editor?.render() else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.writeObjects([image]) { commit(image) } else { model?.showError("无法复制。结果仍保留，请重试或保存图片。") }
    }
    private func quickCopy() {
        guard let image = editor?.render() else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.writeObjects([image]) { commit(image) } else { model?.showError("无法复制。结果仍保留，请重试或保存图片。") }
    }
    private func quickRecord() {
        guard phase == .editing, selection.width >= 1, selection.height >= 1 else { return }
        onQuickRecord?(selection)
    }
    @objc private func savePressed() {
        guard let image = editor?.render(), let data = image.pngData, let window else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "ShotX-\(Self.timestamp()).png"
        if let path = model?.settings.lastSaveDirectory { panel.directoryURL = URL(fileURLWithPath: path) }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic); model?.settings.lastSaveDirectory = url.deletingLastPathComponent().path; model?.persist(); commit(image) }
            catch { model?.showError("保存失败。结果仍保留，请重试或另存为。") }
        }
    }
    @objc private func sharePressed() {
        guard let image = editor?.render(), let toolbar else { return }
        pendingShareImage = image
        let picker = NSSharingServicePicker(items: [image]); picker.delegate = self; picker.show(relativeTo: toolbar.bounds, of: toolbar, preferredEdge: .minY)
    }
    @objc private func pinPressed() { guard let image = editor?.render() else { return }; PinWindowController.show(image); commit(image) }
    private func commit(_ image: NSImage) { phase.commit(); onCommit?(image) }

    private func updateStyleControls(for tool: AnnotationTool) {
        let styled = AnnotationTool.styledCases.contains(tool); colorButton.isHidden = !styled || tool == .mosaic; sizePopup.isHidden = !styled
        currentAnnotationColor = NSColor(hex: model?.settings.annotationColors[tool.rawValue] ?? "#FF3B30") ?? .systemRed
        updateColorButton()
        let values: [Double] = tool == .text ? [11, 13, 16, 24, 32] : tool == .mosaic ? [8, 16, 24, 40] : [1, 2, 4, 8]
        sizePopup.removeAllItems(); sizePopup.addItems(withTitles: values.map { String(Int($0)) }); sizePopup.selectItem(withTitle: String(Int(model?.settings.annotationSizes[tool.rawValue] ?? values.first ?? 2)))
    }
    private func updateColorButton() {
        colorButton.image = Self.swatchImage(currentAnnotationColor, size: NSSize(width: 22, height: 16))
        colorButton.imagePosition = .imageOnly
        colorButton.toolTip = "标注颜色 · \(currentAnnotationColor.hex)"
    }
    private static func swatchImage(_ color: NSColor, size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
        color.setFill(); path.fill()
        NSColor.white.withAlphaComponent(0.4).setStroke(); path.lineWidth = 1; path.stroke()
        image.unlockFocus()
        return image
    }
    private static func timestamp() -> String { let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd-HHmmss"; return formatter.string(from: Date()) }

    private func remember() {
        guard let editor else { return }
        undoStack.append(RegionEditSnapshot(selection: selection, editor: editor.stateSnapshot)); if undoStack.count > 20 { undoStack.removeFirst() }; redoStack.removeAll()
    }
    private func undo() { guard let editor, let state = undoStack.popLast() else { return }; redoStack.append(RegionEditSnapshot(selection: selection, editor: editor.stateSnapshot)); restore(state) }
    private func redo() { guard let editor, let state = redoStack.popLast() else { return }; undoStack.append(RegionEditSnapshot(selection: selection, editor: editor.stateSnapshot)); restore(state) }
    private func restore(_ state: RegionEditSnapshot) { selection = state.selection; editor?.restore(state.editor); updateEditorFrame(); needsDisplay = true }
    private func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        remember(); selection.origin.x = min(max(0, selection.minX + dx), bounds.width - selection.width); selection.origin.y = min(max(0, selection.minY + dy), bounds.height - selection.height); updateEditorFrame(); needsDisplay = true
    }
    private func beginSelectionMove(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        remember(); movingSelection = true; activeHandle = handle(at: point) ?? .move; dragOrigin = point; initialSelection = selection
    }
    private func continueSelectionMove(with event: NSEvent) { guard movingSelection, let activeHandle else { return }; resizeSelection(handle: activeHandle, to: convert(event.locationInWindow, from: nil)); updateEditorFrame(); needsDisplay = true }
    private func endSelectionMove() { movingSelection = false; activeHandle = nil }
    private func updateEditorFrame() { editor?.update(sourceRect: selection); editor?.frame.origin = selection.origin; positionToolbar() }
    private func positionToolbar() {
        guard let toolbar else { return }
        if toolbarFixedSize.width > 0 { toolbar.frame.size = toolbarFixedSize }
        else { toolbar.frame.size = toolbar.fittingSize }
        let below = selection.minY - toolbar.frame.height - 10
        let y = below >= 8 ? below : min(bounds.maxY - toolbar.frame.height - 8, selection.maxY + 10)
        toolbar.frame.origin = CGPoint(x: min(max(8, selection.midX - toolbar.frame.width / 2), bounds.maxX - toolbar.frame.width - 8), y: y)
        positionColorPanel()
    }

    private func positionColorPanel() {
        guard let colorPanel, let toolbar, let window else { return }
        let panelSize = colorPanel.frame.size
        let localOrigin = CGPoint(x: toolbar.frame.minX, y: toolbar.frame.minY - panelSize.height - 6)
        let windowPoint = convert(localOrigin, to: nil)
        colorPanel.setFrameOrigin(NSPoint(x: windowPoint.x, y: windowPoint.y))
    }

    private func handle(at point: CGPoint) -> SelectionHandle? {
        let radius: CGFloat = 10
        let handles: [(SelectionHandle, CGPoint)] = [(.southWest, CGPoint(x: selection.minX, y: selection.minY)), (.south, CGPoint(x: selection.midX, y: selection.minY)), (.southEast, CGPoint(x: selection.maxX, y: selection.minY)), (.west, CGPoint(x: selection.minX, y: selection.midY)), (.east, CGPoint(x: selection.maxX, y: selection.midY)), (.northWest, CGPoint(x: selection.minX, y: selection.maxY)), (.north, CGPoint(x: selection.midX, y: selection.maxY)), (.northEast, CGPoint(x: selection.maxX, y: selection.maxY))]
        return handles.first { hypot($0.1.x - point.x, $0.1.y - point.y) <= radius }?.0 ?? (selection.contains(point) && (editor?.tool == .select || (mode == .regionRecording && phase == .editing)) ? .move : nil)
    }
    private func resizeSelection(handle: SelectionHandle, to point: CGPoint) {
        let dx = point.x - dragOrigin.x, dy = point.y - dragOrigin.y
        if handle == .move { selection = initialSelection.offsetBy(dx: dx, dy: dy); selection.origin.x = min(max(0, selection.minX), bounds.width - selection.width); selection.origin.y = min(max(0, selection.minY), bounds.height - selection.height); return }
        var minX = initialSelection.minX, maxX = initialSelection.maxX, minY = initialSelection.minY, maxY = initialSelection.maxY
        if [.west, .northWest, .southWest].contains(handle) { minX = min(point.x, maxX - 1) }
        if [.east, .northEast, .southEast].contains(handle) { maxX = max(point.x, minX + 1) }
        if [.south, .southWest, .southEast].contains(handle) { minY = min(point.y, maxY - 1) }
        if [.north, .northWest, .northEast].contains(handle) { maxY = max(point.y, minY + 1) }
        selection = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).integral.intersection(bounds)
    }
    private func drawHandles(around rect: CGRect) {
        NSColor.white.setFill()
        for point in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] { NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill() }
    }
}

private final class EyeDropperPreviewView: NSView {
    private let zoom: Int
    private let imageView = NSImageView()
    private let colorLabel = NSTextField(labelWithString: "")
    private let hexLabel = NSTextField(labelWithString: "")

    init(frame: NSRect, zoom: Int = 6) {
        self.zoom = zoom
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        imageView.imageScaling = .scaleAxesIndependently
        colorLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        colorLabel.textColor = .white
        hexLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        hexLabel.textColor = .white
        let labels = NSStackView(views: [colorLabel, NSView(), hexLabel])
        labels.orientation = .horizontal; labels.spacing = 6
        let root = NSStackView(views: [imageView, labels])
        root.orientation = .vertical; root.spacing = 6; root.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        root.frame = bounds
        addSubview(root)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(image: CGImage, color: NSColor?, magnification: Int) {
        let side = CGFloat(image.width * magnification)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: image.width * magnification, pixelsHigh: image.height * magnification, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        if let rep, let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .none
            NSImage(cgImage: image, size: NSSize(width: side, height: side)).draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            NSGraphicsContext.restoreGraphicsState()
            imageView.image = NSImage(size: NSSize(width: side, height: side))
            imageView.image?.addRepresentation(rep)
        }
        if let color, let device = color.usingColorSpace(.deviceRGB) {
            colorLabel.textColor = color
            colorLabel.stringValue = "■"
            hexLabel.stringValue = String(format: "#%02X%02X%02X", Int(device.redComponent * 255), Int(device.greenComponent * 255), Int(device.blueComponent * 255))
        }
    }
}

extension SelectionView: NSSharingServicePickerDelegate {
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        guard service != nil, let image = pendingShareImage else { pendingShareImage = nil; return }
        pendingShareImage = nil; commit(image)
    }
}
