import AppKit
import Carbon.HIToolbox
import CoreGraphics
import ScreenCaptureKit

enum CaptureOverlayLayout {
    static let edgeInset: CGFloat = 8
    static let optionsWidth: CGFloat = 300

    static func toolbarUsesTwoLines(fixedWidth: CGFloat, visibleWidth: CGFloat) -> Bool {
        fixedWidth + edgeInset * 2 > visibleWidth
    }

    static func toolbarSize(_ size: CGSize, visibleFrame: CGRect) -> CGSize {
        let bounds = visibleFrame.insetBy(dx: edgeInset, dy: edgeInset)
        return CGSize(width: min(size.width, bounds.width), height: min(size.height, bounds.height))
    }

    static func toolbarFrame(size: CGSize, selection: CGRect, visibleFrame: CGRect) -> CGRect {
        let bounds = visibleFrame.insetBy(dx: edgeInset, dy: edgeInset)
        let size = toolbarSize(size, visibleFrame: visibleFrame)
        let below = selection.minY - size.height - edgeInset
        let y = below >= bounds.minY ? below : min(bounds.maxY - size.height, max(bounds.minY, selection.maxY + edgeInset))
        let x = min(max(bounds.minX, selection.midX - size.width / 2), bounds.maxX - size.width)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    static func optionsPanelSize(contentHeight: CGFloat, visibleFrame: CGRect) -> CGSize {
        CGSize(width: optionsWidth, height: min(max(120, contentHeight), max(1, visibleFrame.height - edgeInset * 2)))
    }

    static func optionsPanelFrame(contentHeight: CGFloat, visibleFrame: CGRect, toolbarFrame: CGRect) -> CGRect {
        let size = optionsPanelSize(contentHeight: contentHeight, visibleFrame: visibleFrame)
        let bounds = visibleFrame.insetBy(dx: edgeInset, dy: edgeInset)
        var origin = CGPoint(x: toolbarFrame.minX, y: toolbarFrame.minY - size.height - 6)
        if origin.y < bounds.minY { origin.y = toolbarFrame.maxY + 6 }
        origin.x = min(max(bounds.minX, origin.x), max(bounds.minX, bounds.maxX - size.width))
        origin.y = min(max(bounds.minY, origin.y), max(bounds.minY, bounds.maxY - size.height))
        return CGRect(origin: origin, size: size)
    }
}

enum CaptureFocusChain {
    static let minimumSelectionSide: CGFloat = 20

    static func isTiny(_ selection: CGRect) -> Bool {
        selection.width < minimumSelectionSide || selection.height < minimumSelectionSide
    }

    static func views(selection: NSView, handles: [NSView], toolbar: [NSView], options: [NSView], outputs: [NSView]) -> [NSView] {
        [selection] + handles + toolbar + options + outputs
    }

    /// Links views into a cyclic Tab/Shift+Tab chain (previousKeyView is derived by AppKit).
    static func link(_ views: [NSView]) {
        guard !views.isEmpty else { return }
        for (index, view) in views.enumerated() { view.nextKeyView = views[(index + 1) % views.count] }
    }

    /// Window-aware focus bridge. The options panel is a separate `NSPanel` window, so the
    /// overlay window chain (selection → eight handles → toolbar → outputs) and the panel
    /// chain are linked independently and bridged across windows: Tab/Shift+Tab flows into
    /// the panel and wraps back to the selection target.
    static func linkWindowAware(overlayViews: [NSView], panelViews: [NSView]) {
        link(overlayViews)
        guard !panelViews.isEmpty else { return }
        link(panelViews)
        overlayViews.last?.nextKeyView = panelViews.first
        panelViews.last?.nextKeyView = overlayViews.first
    }
}

enum AccessibilityAnnouncements {
    static let interval: TimeInterval = 0.5

    static func shouldPost(lastAnnouncementAt: Date?, now: Date = .now) -> Bool {
        lastAnnouncementAt.map { now.timeIntervalSince($0) >= interval } ?? true
    }

    static func post(_ announcement: String, on element: Any) {
        NSAccessibility.post(element: element, notification: .announcementRequested, userInfo: [
            .announcement: announcement,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
    }
}

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

private final class SelectionFocusTarget: NSView {
    var onArrowKey: ((NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func keyDown(with event: NSEvent) {
        if [123, 124, 125, 126].contains(event.keyCode) { onArrowKey?(event) }
        else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard (window?.firstResponder as? SelectionFocusTarget) === self else { return }
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
        path.lineWidth = 2
        path.stroke()
    }
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
    private var optionsContentHeight: CGFloat = 120
    private var lastToolIndex = 0
    private let styleButton = NSButton(frame: .zero)
    private var optionsPanel: NSPanel?
    private var optionsMonitor: Any?
    private var optionsKeyMonitor: Any?
    private var memoryLabel: NSTextField?
    private var swatchButtons: [NSButton] = []
    private var brushSlider: BrushSlider?
    private var sizeValueLabel: NSTextField?
    private var optionsControls: [NSView] = []
    private var toolbarControls: [NSView] = []
    private var outputControls: [NSView] = []
    private var selectionFocusTarget: SelectionFocusTarget?
    private var handleFocusTargets: [(SelectionHandle, SelectionFocusTarget)] = []
    private var lastStyleAnnouncementAt: Date?
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
            if optionsPanel?.isVisible == true {
                hideOptionsPanel()
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
        let showSize = !focus.isEmpty && !CaptureFocusChain.isTiny(selection)
        let size = showSize ? "  ·  \(Int((focus.width * scale).rounded())) × \(Int((focus.height * scale).rounded())) px" : ""
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
            if self.optionsPanel?.isVisible == true { self.hideOptionsPanel(); return }
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
        makeSelectionFocusTargets()
        makeToolbar()
        window?.makeFirstResponder(selectionFocusTarget)
        NSCursor.pop(); NSCursor.arrow.push()
        needsDisplay = true
    }

    private func makeToolbar() {
        let tools = NSSegmentedControl(labels: AnnotationTool.allCases.map(\.rawValue), trackingMode: .selectOne, target: self, action: #selector(toolChanged(_:)))
        tools.selectedSegment = 0
        tools.controlSize = .small
        for index in 0..<tools.segmentCount { tools.setWidth(32, forSegment: index) }
        toolControl = tools
        styleButton.target = self; styleButton.action = #selector(stylePressed); styleButton.setAccessibilityLabel("样式"); styleButton.toolTip = "样式"
        styleButton.controlSize = .small
        styleButton.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let undo = button("撤销", #selector(undoPressed)); undo.controlSize = .small
        let redo = button("重做", #selector(redoPressed)); redo.controlSize = .small
        let editButtons = [tools, undo, redo, styleButton]
        let outputButtons = [button("复制", #selector(copyPressed)), button("保存…", #selector(savePressed)), button("分享…", #selector(sharePressed)), button("贴图", #selector(pinPressed)), button("关闭", #selector(closePressed))]
        toolbarControls = [tools, undo, redo, styleButton]
        outputControls = outputButtons
        outputButtons.forEach { $0.controlSize = .small }
        let toolRow = NSStackView(views: editButtons); toolRow.orientation = .horizontal; toolRow.spacing = 4; toolRow.alignment = .centerY
        let outputRow = NSStackView(views: outputButtons); outputRow.orientation = .horizontal; outputRow.spacing = 4; outputRow.alignment = .centerY
        let toolbar = NSVisualEffectView(frame: .zero); toolbar.material = .hudWindow; toolbar.state = .active; toolbar.wantsLayer = true; toolbar.layer?.cornerRadius = 10
        let content = NSStackView(views: [toolRow, outputRow])
        content.spacing = 4; content.alignment = .centerY
        let twoLines = CaptureOverlayLayout.toolbarUsesTwoLines(fixedWidth: toolRow.fittingSize.width + outputRow.fittingSize.width + 7 + 20, visibleWidth: targetScreen.visibleFrame.width)
        content.orientation = twoLines ? .vertical : .horizontal
        toolbar.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 10), content.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -10), content.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 4), content.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -4)])
        toolbar.layoutSubtreeIfNeeded()
        updateStyleControls(for: .select)
        toolbar.layoutSubtreeIfNeeded()
        let visible = targetScreen.visibleFrame.offsetBy(dx: -targetScreen.frame.minX, dy: -targetScreen.frame.minY)
        toolbarFixedSize = CaptureOverlayLayout.toolbarSize(toolbar.fittingSize, visibleFrame: visible)
        toolbarFixedSize.height = twoLines ? 80 : 40
        addSubview(toolbar); self.toolbar = toolbar
        positionToolbar()
        updateFocusChain()
    }

    private func makeSelectionFocusTargets() {
        let selectionTarget = SelectionFocusTarget(frame: selection)
        selectionTarget.setAccessibilityLabel("截图区域")
        selectionTarget.onArrowKey = { [weak self] event in self?.nudgeSelectionFocus(nil, with: event) }
        addSubview(selectionTarget)
        selectionFocusTarget = selectionTarget

        let handles: [(SelectionHandle, String)] = [(.southWest, "截图区域左下角"), (.south, "截图区域下边"), (.southEast, "截图区域右下角"), (.west, "截图区域左边"), (.east, "截图区域右边"), (.northWest, "截图区域左上角"), (.north, "截图区域上边"), (.northEast, "截图区域右上角")]
        handleFocusTargets = handles.map { handle, label in
            let target = SelectionFocusTarget(frame: .zero)
            target.setAccessibilityLabel(label)
            target.onArrowKey = { [weak self] event in self?.nudgeSelectionFocus(handle, with: event) }
            addSubview(target)
            return (handle, target)
        }
        updateSelectionFocusTargets()
    }

    private func updateFocusChain() {
        guard let selectionFocusTarget else { return }
        let tiny = CaptureFocusChain.isTiny(selection)
        let toolbarViews = tiny ? [] : toolbarControls
        let outputViews = tiny ? [] : outputControls
        let optionsVisible = optionsPanel?.isVisible == true && !tiny
        CaptureFocusChain.linkWindowAware(
            overlayViews: [selectionFocusTarget] + handleFocusTargets.map(\.1) + toolbarViews + outputViews,
            panelViews: optionsVisible ? optionsControls : []
        )
    }

    private func updateSelectionFocusTargets() {
        selectionFocusTarget?.frame = selection
        for (handle, target) in handleFocusTargets {
            let point = handlePoint(handle)
            target.frame = NSRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20)
        }
    }

    private func handlePoint(_ handle: SelectionHandle) -> CGPoint {
        switch handle {
        case .southWest: CGPoint(x: selection.minX, y: selection.minY)
        case .south: CGPoint(x: selection.midX, y: selection.minY)
        case .southEast: CGPoint(x: selection.maxX, y: selection.minY)
        case .west: CGPoint(x: selection.minX, y: selection.midY)
        case .east: CGPoint(x: selection.maxX, y: selection.midY)
        case .northWest: CGPoint(x: selection.minX, y: selection.maxY)
        case .north: CGPoint(x: selection.midX, y: selection.maxY)
        case .northEast: CGPoint(x: selection.maxX, y: selection.maxY)
        case .move: CGPoint(x: selection.midX, y: selection.midY)
        }
    }

    private func nudgeSelectionFocus(_ handle: SelectionHandle?, with event: NSEvent) {
        let amount = (event.modifierFlags.contains(.shift) ? 10 : 1) / targetScreen.backingScaleFactor
        let delta = event.keyCode == 123 ? (-amount, 0) : event.keyCode == 124 ? (amount, 0) : event.keyCode == 125 ? (0, -amount) : (0, amount)
        guard let handle else { nudgeSelection(dx: delta.0, dy: delta.1); return }
        remember()
        let minimum = 1 / targetScreen.backingScaleFactor
        var rect = selection
        switch handle {
        case .west, .northWest, .southWest:
            let x = min(max(bounds.minX, rect.minX + delta.0), rect.maxX - minimum)
            rect.size.width += rect.minX - x; rect.origin.x = x
        default: break
        }
        switch handle {
        case .east, .northEast, .southEast:
            rect.size.width = max(minimum, min(bounds.maxX, rect.maxX + delta.0) - rect.minX)
        default: break
        }
        switch handle {
        case .south, .southWest, .southEast:
            let y = min(max(bounds.minY, rect.minY + delta.1), rect.maxY - minimum)
            rect.size.height += rect.minY - y; rect.origin.y = y
        default: break
        }
        switch handle {
        case .north, .northWest, .northEast:
            rect.size.height = max(minimum, min(bounds.maxY, rect.maxY + delta.1) - rect.minY)
        default: break
        }
        selection = rect
        updateEditorFrame(); needsDisplay = true; notifySelectionChanged()
    }

    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        let tool = AnnotationTool.allCases[index]
        if index == lastToolIndex, AnnotationTool.styledCases.contains(tool), optionsPanel?.isVisible == true {
            hideOptionsPanel()
            return
        }
        lastToolIndex = index
        editor?.tool = tool
        updateStyleControls(for: tool)
        if AnnotationTool.styledCases.contains(tool) {
            if optionsPanel?.isVisible == true { rebuildOptionsPanel() } else { showOptionsPanel() }
        } else {
            hideOptionsPanel()
        }
        if optionsPanel?.isVisible != true { window?.makeFirstResponder(editor) }
    }

    @objc private func stylePressed() {
        guard let editor, AnnotationTool.styledCases.contains(editor.tool) else { return }
        if optionsPanel?.isVisible == true { hideOptionsPanel() } else { showOptionsPanel() }
    }

    private func showOptionsPanel() {
        hideOptionsPanel()
        let panel = OptionsPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 220), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = makeOptionsContent()
        panel.contentView = content
        panel.setContentSize(CaptureOverlayLayout.optionsPanelSize(contentHeight: optionsContentHeight, visibleFrame: targetScreen.visibleFrame))
        optionsPanel = panel
        positionOptionsPanel()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(optionsControls.first)
        updateFocusChain()
        AccessibilityAnnouncements.post("样式，颜色和粗细", on: panel)
        installOptionsMonitors()
    }

    private func rebuildOptionsPanel() {
        guard let panel = optionsPanel else { return }
        let content = makeOptionsContent()
        panel.contentView = content
        panel.setContentSize(CaptureOverlayLayout.optionsPanelSize(contentHeight: optionsContentHeight, visibleFrame: targetScreen.visibleFrame))
        positionOptionsPanel()
        updateFocusChain()
    }

    private func hideOptionsPanel() {
        if let monitor = optionsMonitor { NSEvent.removeMonitor(monitor) }
        optionsMonitor = nil
        if let monitor = optionsKeyMonitor { NSEvent.removeMonitor(monitor) }
        optionsKeyMonitor = nil
        optionsPanel?.orderOut(nil)
        optionsPanel = nil
        updateFocusChain()
        window?.makeKey()
        window?.makeFirstResponder(styleButton)
    }

    private func installOptionsMonitors() {
        optionsMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let panel = self.optionsPanel, panel.isVisible else { return event }
            let point = event.window?.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin ?? NSEvent.mouseLocation
            if panel.frame.contains(point) { return event }
            if self.toolbar.map({ self.window?.convertToScreen($0.convert($0.bounds, to: nil)) ?? .zero })?.contains(point) == true { return event }
            self.hideOptionsPanel()
            return event
        }
        optionsKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.optionsPanel?.isVisible == true else { return event }
            self.hideOptionsPanel()
            return nil
        }
    }

    private func makeOptionsContent() -> NSView {
        guard let tool = editor?.tool else { return NSView() }
        optionsControls = []
        let content = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 300, height: 220))
        content.material = .hudWindow; content.state = .active; content.wantsLayer = true; content.layer?.cornerRadius = 10
        var sections: [NSView] = [makeMemoryRow(for: tool)]
        if tool != .mosaic { sections.append(makeColorSection()) }
        sections.append(makeSizeSection(for: tool))
        let root = NSStackView(views: sections)
        root.orientation = .vertical; root.spacing = 8; root.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        root.layoutSubtreeIfNeeded()
        root.frame = NSRect(origin: .zero, size: NSSize(width: CaptureOverlayLayout.optionsWidth - 20, height: root.fittingSize.height))
        optionsContentHeight = root.frame.height + 20
        let scroll = NSScrollView()
        scroll.documentView = root; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10), scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 10), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)])
        return content
    }

    private func makeMemoryRow(for tool: AnnotationTool) -> NSView {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.setAccessibilityLabel("当前工具样式")
        memoryLabel = label
        updateMemoryLabel(for: tool)
        return label
    }

    private func updateMemoryLabel(for tool: AnnotationTool) {
        let size = currentSize(for: tool)
        let text = tool == .mosaic ? "马赛克 · \(Int(size)) px" : "\(tool.rawValue) · 颜色 \(currentAnnotationColor.hex) · \(Int(size)) \(tool.styleRange.unit)"
        memoryLabel?.stringValue = text
    }

    private func makeColorSection() -> NSView {
        var swatches: [NSButton] = []
        for (index, color) in Self.presetColors.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(presetPicked(_:)))
            b.setButtonType(.momentaryChange)
            b.bezelStyle = .regularSquare
            let selected = color.hex == currentAnnotationColor.hex
            b.image = Self.swatchImage(color, size: NSSize(width: 20, height: 16), selected: selected)
            b.imagePosition = .imageOnly
            b.tag = index
            b.setAccessibilityLabel("预设颜色 \(color.hex)\(selected ? "，已选中" : "")")
            b.setAccessibilityValue(selected ? "已选中" : "未选中")
            b.toolTip = color.hex
            swatches.append(b)
        }
        swatchButtons = swatches
        optionsControls.append(contentsOf: swatches)
        let row1 = NSStackView(views: Array(swatches[0..<6])); row1.orientation = .horizontal; row1.spacing = 6; row1.alignment = .centerY
        let row2 = NSStackView(views: Array(swatches[6..<12])); row2.orientation = .horizontal; row2.spacing = 6; row2.alignment = .centerY
        let grid = NSStackView(views: [row1, row2]); grid.orientation = .vertical; grid.spacing = 6
        let eyedrop = NSButton(title: "取色器", target: self, action: #selector(eyedropperPressed))
        eyedrop.bezelStyle = .rounded
        eyedrop.setAccessibilityLabel("从屏幕取色")
        optionsControls.append(eyedrop)
        let bottom = NSStackView(views: [eyedrop, NSView()])
        bottom.orientation = .horizontal; bottom.spacing = 8
        let root = NSStackView(views: [grid, bottom])
        root.orientation = .vertical; root.spacing = 8
        return root
    }

    private func makeSizeSection(for tool: AnnotationTool) -> NSView {
        let range = tool.styleRange
        let current = currentSize(for: tool)
        let slider = BrushSlider(value: current, minValue: range.min, maxValue: range.max, target: self, action: #selector(brushChanged(_:)))
        slider.isContinuous = true
        slider.onBegin = { [weak self] in self?.remember() }
        slider.onCommit = { [weak self] in self?.commitBrushSize() }
        slider.setAccessibilityLabel(tool.styleAccessibilityLabel)
        slider.setAccessibilityValue(tool.styleAccessibilityValue(current))
        brushSlider = slider
        optionsControls.append(slider)
        let valueLabel = NSTextField(labelWithString: "\(Int(current)) \(range.unit)")
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        valueLabel.setAccessibilityLabel("当前值")
        sizeValueLabel = valueLabel
        let title = NSTextField(labelWithString: tool.styleLabel)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let sliderRow = NSStackView(views: [title, slider, valueLabel])
        sliderRow.orientation = .horizontal; sliderRow.spacing = 8; sliderRow.alignment = .centerY
        let presets = range.presets.map { value -> NSButton in
            let b = NSButton(title: "\(Int(value))", target: self, action: #selector(sizePresetPressed(_:)))
            b.bezelStyle = .rounded
            b.tag = Int(value)
            b.setAccessibilityLabel("\(tool.styleLabel) \(Int(value)) \(range.unit)")
            b.toolTip = "\(Int(value)) \(range.unit)"
            return b
        }
        optionsControls.append(contentsOf: presets)
        let presetRow = NSStackView(views: presets + [NSView()])
        presetRow.orientation = .horizontal; presetRow.spacing = 6; presetRow.alignment = .centerY
        let root = NSStackView(views: [sliderRow, presetRow])
        root.orientation = .vertical; root.spacing = 6
        return root
    }

    @objc private func presetPicked(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < Self.presetColors.count else { return }
        applyPickedColor(Self.presetColors[sender.tag])
    }

    private func applyPickedColor(_ color: NSColor) {
        guard let editor, let model else { return }
        let tool = editor.tool
        let size = currentSize(for: tool)
        editor.applyStyle(color: color, size: size)
        model.settings.annotationColors[tool.rawValue] = color.hex
        model.settings.annotationSizes[tool.rawValue] = size
        model.persist()
        currentAnnotationColor = color
        updateColorButtons()
        updateMemoryLabel(for: tool)
        updateStyleButton()
    }

    @objc private func eyedropperPressed() {
        hideOptionsPanel()
        startEyeDropper()
    }

    private func startEyeDropper() {
        guard window != nil, frozenCG != nil else { return }
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

    @objc private func brushChanged(_ sender: BrushSlider) {
        guard let editor else { return }
        let tool = editor.tool
        let value = sender.doubleValue
        editor.applyStyleLive(color: currentAnnotationColor, size: value)
        updateMemoryLabel(for: tool)
        updateSizeValue(value, for: tool)
        updateStyleButton()
        let now = Date.now
        guard AccessibilityAnnouncements.shouldPost(lastAnnouncementAt: lastStyleAnnouncementAt, now: now) else { return }
        lastStyleAnnouncementAt = now
        AccessibilityAnnouncements.post("\(tool.styleLabel) \(Int(value)) \(tool.styleRange.unit == "pt" ? "点" : "像素")", on: sender)
    }

    private func commitBrushSize() {
        guard let model, let slider = brushSlider else { return }
        let tool = editor?.tool ?? .pen
        let value = slider.doubleValue
        model.settings.annotationSizes[tool.rawValue] = value
        model.persist()
        updateMemoryLabel(for: tool)
        updateSizeValue(value, for: tool)
        updateStyleButton()
    }

    @objc private func sizePresetPressed(_ sender: NSButton) {
        guard let editor, let model else { return }
        let tool = editor.tool
        let value = Double(sender.tag)
        brushSlider?.doubleValue = value
        editor.applyStyle(color: currentAnnotationColor, size: value)
        model.settings.annotationSizes[tool.rawValue] = value
        model.persist()
        updateMemoryLabel(for: tool)
        updateSizeValue(value, for: tool)
        updateStyleButton()
    }

    @objc private func closePressed() {
        hideOptionsPanel()
        phase.discard(); onCancel?()
    }
    @objc private func undoPressed() { undo() }
    @objc private func redoPressed() { redo() }
    @objc private func copyPressed() {
        guard let image = renderOutput() else { return }
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
        guard let image = renderOutput(), let data = image.pngData, let window else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "ShotX-\(Self.timestamp()).png"
        if let path = model?.settings.lastSaveDirectory { panel.directoryURL = URL(fileURLWithPath: path) }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic); model?.settings.lastSaveDirectory = url.deletingLastPathComponent().path; model?.persist(); commit(image) }
            catch { model?.showError("保存失败。结果仍保留，请重试或另存为。") }
        }
    }
    @objc private func sharePressed() {
        guard let image = renderOutput(), let toolbar else { return }
        pendingShareImage = image
        let picker = NSSharingServicePicker(items: [image]); picker.delegate = self; picker.show(relativeTo: toolbar.bounds, of: toolbar, preferredEdge: .minY)
    }
    @objc private func pinPressed() { guard let image = renderOutput() else { return }; PinWindowController.show(image); commit(image) }
    private func renderOutput() -> NSImage? { hideOptionsPanel(); return editor?.render() }
    private func commit(_ image: NSImage) { phase.commit(); onCommit?(image) }

    private func updateStyleControls(for tool: AnnotationTool) {
        currentAnnotationColor = NSColor(hex: model?.settings.annotationColors[tool.rawValue] ?? "#FF3B30") ?? .systemRed
        updateStyleButton()
        updateColorButtons()
        updateMemoryLabel(for: tool)
    }
    private func updateStyleButton() {
        guard let tool = editor?.tool else { return }
        let styled = AnnotationTool.styledCases.contains(tool)
        styleButton.isEnabled = styled
        if styled {
            let size = currentSize(for: tool)
            let summary = tool == .mosaic ? "\(Int(size)) px" : "\(Int(size)) pt"
            styleButton.image = tool == .mosaic ? nil : Self.swatchImage(currentAnnotationColor, size: NSSize(width: 18, height: 13))
            styleButton.imagePosition = tool == .mosaic ? .noImage : .imageLeading
            styleButton.title = summary
            styleButton.toolTip = "样式 · \(summary)"
        } else {
            styleButton.image = nil
            styleButton.imagePosition = .noImage
            styleButton.title = "样式"
            styleButton.toolTip = "该工具无样式选项"
        }
        styleButton.setAccessibilityLabel("样式 \(styleButton.title)")
    }
    private func updateColorButtons() {
        for (index, button) in swatchButtons.enumerated() where index < Self.presetColors.count {
            let color = Self.presetColors[index]
            let selected = color.hex == currentAnnotationColor.hex
            button.image = Self.swatchImage(color, size: NSSize(width: 20, height: 16), selected: selected)
            button.setAccessibilityLabel("预设颜色 \(color.hex)\(selected ? "，已选中" : "")")
            button.setAccessibilityValue(selected ? "已选中" : "未选中")
        }
    }
    private func updateSizeValue(_ value: Double, for tool: AnnotationTool) {
        let accessibilityValue = tool.styleAccessibilityValue(value)
        sizeValueLabel?.stringValue = accessibilityValue
        brushSlider?.setAccessibilityLabel(tool.styleAccessibilityLabel)
        brushSlider?.setAccessibilityValue(accessibilityValue)
    }
    private func currentSize(for tool: AnnotationTool) -> Double {
        let range = tool.styleRange
        let raw = editor?.styleSize(for: tool) ?? model?.settings.annotationSizes[tool.rawValue] ?? AnnotationTool.defaultSize(for: tool)
        return min(max(range.min, raw), max(range.min, range.max))
    }
    private static let presetColors: [NSColor] = ["#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#5AC8FA", "#007AFF", "#AF52DE", "#FF2D55", "#A2845E", "#8E8E93", "#FFFFFF", "#000000"].compactMap { NSColor(hex: $0) }
    private static func swatchImage(_ color: NSColor, size: NSSize, selected: Bool = false) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        color.setFill(); path.fill()
        if selected {
            NSColor.controlAccentColor.setStroke(); path.lineWidth = 2; path.stroke()
            let check = NSBezierPath(); check.lineWidth = 1.5; check.lineCapStyle = .round
            check.move(to: NSPoint(x: rect.minX + 4, y: rect.midY))
            check.line(to: NSPoint(x: rect.midX, y: rect.minY + 3))
            check.line(to: NSPoint(x: rect.maxX - 3, y: rect.maxY - 4))
            NSColor.white.setStroke(); check.stroke()
        } else {
            NSColor.white.withAlphaComponent(0.4).setStroke(); path.lineWidth = 1; path.stroke()
        }
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
    private func updateEditorFrame() { editor?.update(sourceRect: selection); editor?.frame.origin = selection.origin; updateSelectionFocusTargets(); positionToolbar() }
    private func positionToolbar() {
        guard let toolbar else { return }
        let tiny = CaptureFocusChain.isTiny(selection)
        toolbar.isHidden = tiny
        if tiny {
            if optionsPanel?.isVisible == true { hideOptionsPanel() }
            updateFocusChain()
            return
        }
        let size = toolbarFixedSize.width > 0 ? toolbarFixedSize : toolbar.fittingSize
        let visible = targetScreen.visibleFrame.offsetBy(dx: -targetScreen.frame.minX, dy: -targetScreen.frame.minY)
        toolbar.frame = CaptureOverlayLayout.toolbarFrame(size: size, selection: selection, visibleFrame: visible)
        positionOptionsPanel()
        updateFocusChain()
    }

    private func positionOptionsPanel() {
        guard let optionsPanel, let toolbar else { return }
        let visible = targetScreen.visibleFrame
        let toolbarScreen = window.map { $0.convertToScreen(toolbar.convert(toolbar.bounds, to: nil)) } ?? toolbar.frame
        optionsPanel.setFrame(CaptureOverlayLayout.optionsPanelFrame(contentHeight: optionsContentHeight, visibleFrame: visible, toolbarFrame: toolbarScreen), display: false)
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

private final class OptionsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class BrushSlider: NSSlider {
    var onBegin: (() -> Void)?
    var onCommit: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onBegin?(); super.mouseDown(with: event); onCommit?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 123 || event.keyCode == 124 {
            let step = event.modifierFlags.contains(.shift) ? 5.0 : 1.0
            onBegin?()
            doubleValue = min(maxValue, max(minValue, doubleValue + (event.keyCode == 124 ? step : -step)))
            sendAction(action, to: target)
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }
}
