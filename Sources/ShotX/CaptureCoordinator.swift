import AppKit
import Carbon.HIToolbox
import CoreGraphics
import ScreenCaptureKit

enum CaptureOverlayLayout {
    static let edgeInset: CGFloat = 8
    static let optionsWidth: CGFloat = 300
    static let optionsPanelLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

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
        CGSize(width: min(optionsWidth, max(1, visibleFrame.width - edgeInset * 2)), height: min(max(120, contentHeight), max(1, visibleFrame.height - edgeInset * 2)))
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
    private weak var activeOverlay: SelectionWindowController?
    private var screenTrackingTimer: Timer?

    private func presentOverlays() {
        NSApp.activate(ignoringOtherApps: true)
        overlays.forEach { $0.window?.orderFrontRegardless() }
        activateOverlay(at: NSEvent.mouseLocation)
        screenTrackingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.activateOverlay(at: NSEvent.mouseLocation) }
        }
    }

    private func activateOverlay(at point: CGPoint) {
        guard let index = Self.overlayIndex(at: point, frames: overlays.map { $0.window?.frame ?? .null }) else { return }
        let target = overlays[index]
        guard target !== activeOverlay else { return }
        activeOverlay = target
        overlays.forEach { $0.setActive($0 === target) }
    }

    static func overlayIndex(at point: CGPoint, frames: [CGRect]) -> Int? { frames.firstIndex { $0.contains(point) } }

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
        let windows = captureWindows(in: content)
        for screen in targetScreen.map({ [$0] }) ?? NSScreen.screens {
            guard let display = display(for: screen, in: content) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = max(1, Int((screen.frame.width * screen.backingScaleFactor).rounded()))
            config.height = max(1, Int((screen.frame.height * screen.backingScaleFactor).rounded()))
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let controller = SelectionWindowController(screen: screen, mode: .region, windows: windows, frozenImage: image, model: model)
            configureRegionController(controller, display: display, screen: screen, model: model)
            overlays.append(controller)
        }
        presentOverlays()
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
        }
        presentOverlays()
        NSCursor.crosshair.push()
    }

    private func showWindowSelection(content: SCShareableContent, model: AppModel) {
        let candidates = captureWindows(in: content)
        for screen in NSScreen.screens {
            guard let display = display(for: screen, in: content) else { continue }
            let controller = SelectionWindowController(screen: screen, mode: .window, windows: candidates)
            controller.onCancel = { [weak self] in self?.cancel() }
            controller.onWindow = { [weak self, weak model] window in
                guard let self, let model else { return }
                self.cancel()
                Task { await self.edit(window: window, display: display, screen: screen, model: model) }
            }
            overlays.append(controller)
        }
        presentOverlays()
        NSCursor.pointingHand.push()
    }

    func cancel() {
        screenTrackingTimer?.invalidate()
        screenTrackingTimer = nil
        activeOverlay = nil
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

    private func edit(window selectedWindow: SCWindow, display: SCDisplay, screen: NSScreen, model: AppModel) async {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = max(1, Int((screen.frame.width * screen.backingScaleFactor).rounded()))
        config.height = max(1, Int((screen.frame.height * screen.backingScaleFactor).rounded()))
        config.captureResolution = .best
        config.showsCursor = false
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let selection = Self.localRect(windowFrame: selectedWindow.frame, screenFrame: screen.frame).intersection(CGRect(origin: .zero, size: screen.frame.size))
            guard selection.width >= 1, selection.height >= 1 else { throw CaptureError.noContent }
            let controller = SelectionWindowController(screen: screen, mode: .region, frozenImage: image, model: model, initialSelection: selection)
            configureRegionController(controller, display: display, screen: screen, model: model)
            overlays = [controller]
            NSCursor.crosshair.push()
            presentOverlays()
        } catch { model.showError("窗口截图失败。结果未创建，请重试。") }
    }

    nonisolated static func localRect(windowFrame: CGRect, screenFrame: CGRect, primaryHeight: CGFloat = CGDisplayBounds(CGMainDisplayID()).height) -> CGRect {
        CGRect(x: windowFrame.minX - screenFrame.minX, y: primaryHeight - windowFrame.maxY - screenFrame.minY, width: windowFrame.width, height: windowFrame.height)
    }

    private func configureRegionController(_ controller: SelectionWindowController, display: SCDisplay, screen: NSScreen, model: AppModel) {
        controller.onCancel = { [weak self] in self?.cancel() }
        controller.onEditing = { [weak self, weak controller] in
            guard let self, let controller else { return }
            overlays.filter { $0 !== controller }.forEach { $0.close() }
            overlays = [controller]
        }
        controller.onScrolling = { [weak self, weak model] rect in
            guard let self, let model else { return }
            self.cancel()
            Task { await ScrollingCaptureCoordinator.shared.start(display: display, screen: screen, localRect: rect, model: model) }
        }
        controller.onCommit = { [weak self, weak model] image in
            guard let self, let model else { return }
            model.recentResult = .image(image)
            self.cancel()
        }
    }

    private func display(for screen: NSScreen, in content: SCShareableContent) -> SCDisplay? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return content.displays.first { $0.displayID == number.uint32Value }
    }

    private func captureWindows(in content: SCShareableContent) -> [SCWindow] {
        content.windows.filter {
            $0.isOnScreen && $0.windowLayer == 0 && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier && $0.frame.width > 40 && $0.frame.height > 40
        }
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
    var onScrolling: ((CGRect) -> Void)?

    private let view: SelectionView

    init(screen: NSScreen, mode: CaptureMode, windows: [SCWindow] = [], frozenImage: CGImage? = nil, model: AppModel? = nil, initialSelection: CGRect? = nil) {
        let window = SelectionWindow(contentRect: CGRect(origin: .zero, size: screen.frame.size), styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.sharingType = .none
        view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), mode: mode, screen: screen, windows: windows, frozenImage: frozenImage, model: model, initialSelection: initialSelection)
        super.init(window: window)
        view.onCancel = { [weak self] in self?.onCancel?() }
        view.onSelection = { [weak self] in self?.onSelection?($0) }
        view.onQuickRecord = { [weak self] in self?.onQuickRecord?($0) }
        view.onWindow = { [weak self] in self?.onWindow?($0) }
        view.onCommit = { [weak self] in self?.onCommit?($0) }
        view.onEditing = { [weak self] in self?.onEditing?() }
        view.onScrolling = { [weak self] in self?.onScrolling?($0) }
        window.contentView = view
        window.makeFirstResponder(view)
        if initialSelection != nil { DispatchQueue.main.async { [weak view] in view?.beginPresetEditing() } }
    }

    required init?(coder: NSCoder) { fatalError() }

    var selectionRect: CGRect { view.selectionRect }

    func setActive(_ active: Bool) {
        window?.ignoresMouseEvents = !active
        guard active else { return }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(view)
    }

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

private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
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
    var onScrolling: ((CGRect) -> Void)?
    private(set) var setupActive = false
    private let mode: CaptureMode
    private let targetScreen: NSScreen
    private let windows: [SCWindow]
    private var start: CGPoint?
    private var selectingByDrag = false
    private var selection = CGRect.zero
    private var hoveredWindow: SCWindow?
    private var phase = RegionCapturePhase.selecting
    private let frozenImage: NSImage?
    private let frozenCG: CGImage?
    private weak var model: AppModel?
    private var editor: AnnotationView?
    private var toolbar: NSView?
    private var toolButtons: [NSButton] = []
    private var toolbarFixedSize = NSSize.zero
    private var optionsContentHeight: CGFloat = 120
    private var lastToolIndex = 0
    private let styleButton = NSButton(frame: .zero)
    private var optionsPanel: NSPanel?
    private weak var optionsTailView: NSImageView?
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
    private var shortcutMonitor: Any?

    init(frame: CGRect, mode: CaptureMode, screen: NSScreen, windows: [SCWindow], frozenImage: CGImage? = nil, model: AppModel? = nil, initialSelection: CGRect? = nil) {
        self.mode = mode
        targetScreen = screen
        self.windows = windows
        self.model = model
        self.frozenCG = frozenImage
        self.frozenImage = frozenImage.map { NSImage(cgImage: $0, size: screen.frame.size) }
        super.init(frame: frame)
        if let initialSelection {
            selection = initialSelection
            phase = .editing
        }
        wantsLayer = true
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) } }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    var selectionRect: CGRect { selection }

    func beginPresetEditing() {
        guard mode == .region, phase == .editing, editor == nil else { return }
        onEditing?()
        beginRegionEditing()
    }

    func enterRecordingSetup() {
        setupActive = true
        needsDisplay = true
    }

    func exitRecordingSetup() {
        setupActive = false
        needsDisplay = true
    }

    private func notifySelectionChanged() { onSelectionChanged?(selection) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, shortcutMonitor == nil else { return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window || event.window === self.optionsPanel else { return event }
            if self.editor?.isEditingText == true {
                if event.keyCode == UInt16(kVK_Escape) { self.editor?.cancelTextEntry(); return nil }
                return event
            }
            if event.keyCode == UInt16(kVK_Escape) || event.keyCode == UInt16(kVK_Space) {
                self.keyDown(with: event)
                return nil
            }
            return event
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            if setupActive { onExitSetup?(); return }
            if eyedropperWindow != nil {
                stopEyeDropper()
                return
            }
            hideOptionsPanel()
            phase.discard(); onCancel?()
        }
        else if event.keyCode == UInt16(kVK_Space), mode == .region, phase == .editing {
            quickCopy()
        }
        else if event.keyCode == UInt16(kVK_Space), mode == .regionRecording, phase == .editing, !setupActive {
            quickRecord()
        }
        else if mode == .region, phase == .editing, event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" { event.modifierFlags.contains(.shift) ? redo() : undo() }
        else if event.keyCode == UInt16(kVK_Return), mode == .region, phase == .selecting { acceptSuggestedSelection() }
        else if event.keyCode == UInt16(kVK_Return), mode.isDisplay { onSelection?(bounds) }
        else if event.keyCode == UInt16(kVK_Return), mode == .regionRecording, phase == .editing, !setupActive { onSelection?(selection) }
        else if event.keyCode == UInt16(kVK_Return), let hoveredWindow { onWindow?(hoveredWindow) }
        else { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        if mode == .window { if let hoveredWindow { onWindow?(hoveredWindow) }; return }
        if mode.isDisplay { onSelection?(bounds); return }
        let point = convert(event.locationInWindow, from: nil)
        if (mode == .region || mode == .regionRecording), phase == .editing {
            if event.clickCount >= 2, mode == .region, selection.contains(point) {
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
        selectingByDrag = false
        if mode != .region { selection = CGRect(origin: start!, size: .zero) }
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
        if mode == .region, phase == .selecting, !selectingByDrag {
            selectingByDrag = hypot(point.x - start.x, point.y - start.y) >= 4
            guard selectingByDrag else { return }
        }
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
        if mode == .region, phase == .selecting, !selectingByDrag { selection = suggestedSelection }
        selectingByDrag = false
        if mode == .region || mode == .regionRecording {
            phase.release(validSelection: selection.width >= 1 && selection.height >= 1)
            if phase == .editing {
                onEditing?()
                if mode == .region { beginRegionEditing() }
                else {
                    window?.makeFirstResponder(self)
                    onSelection?(selection)
                }
            }
        } else if selection.width >= 1, selection.height >= 1 { onSelection?(selection) }
    }

    override func mouseMoved(with event: NSEvent) {
        guard mode == .window || (mode == .region && phase == .selecting && start == nil) else { return }
        let local = convert(event.locationInWindow, from: nil)
        let appKitGlobal = CGPoint(x: targetScreen.frame.minX + local.x, y: targetScreen.frame.minY + local.y)
        let cgPoint = CGPoint(x: appKitGlobal.x, y: CGDisplayBounds(CGMainDisplayID()).height - appKitGlobal.y)
        hoveredWindow = windows.first { $0.frame.contains(cgPoint) }
        needsDisplay = true
    }

    private var suggestedSelection: CGRect {
        guard let hoveredWindow else { return bounds }
        return CaptureCoordinator.localRect(windowFrame: hoveredWindow.frame, screenFrame: targetScreen.frame).intersection(bounds)
    }

    private func acceptSuggestedSelection() {
        selection = suggestedSelection
        phase.release(validSelection: selection.width >= 1 && selection.height >= 1)
        guard phase == .editing else { return }
        onEditing?()
        beginRegionEditing()
    }

    private func bounded(_ point: CGPoint) -> CGPoint { CGPoint(x: min(max(0, point.x), bounds.maxX), y: min(max(0, point.y), bounds.maxY)) }

    override func draw(_ dirtyRect: NSRect) {
        frozenImage?.draw(in: bounds)
        NSColor.black.withAlphaComponent(setupActive ? 0.28 : 0.45).setFill()
        let shade = NSBezierPath(rect: bounds)
        let focus: CGRect
        if mode == .region, phase == .selecting, !selectingByDrag {
            focus = suggestedSelection
        } else if mode == .window, let hoveredWindow {
            let global = hoveredWindow.frame
            focus = CaptureCoordinator.localRect(windowFrame: global, screenFrame: targetScreen.frame).intersection(bounds)
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
                NSColor(hex: "#10AEFF")!.setStroke()
                let styledFocus = focus.insetBy(dx: 3, dy: 3)
                let path = NSBezierPath(roundedRect: styledFocus, xRadius: 8, yRadius: 8)
                path.lineWidth = mode.isDisplay ? 3 : 2
                path.stroke()
            }
            if (mode == .region || mode == .regionRecording), phase == .editing { drawHandles(around: focus.insetBy(dx: 3, dy: 3)) }
        }
        drawLabel(focus: focus)
    }

    private func drawSetupBorder(around rect: CGRect) {
        NSColor(hex: "#07C160")!.setStroke()
        let styledRect = rect.insetBy(dx: 3, dy: 3)
        let border = NSBezierPath(roundedRect: styledRect, xRadius: 8, yRadius: 8); border.lineWidth = 1; border.stroke()
        drawSelectionAccents(around: styledRect, color: NSColor(hex: "#07C160")!)
    }

    private func drawLabel(focus: CGRect) {
        let scale = targetScreen.backingScaleFactor
        let showSize = !focus.isEmpty && !CaptureFocusChain.isTiny(focus)
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
        let title = mode == .region ? "截图" : mode.rawValue
        let text = "\(setupActive ? "录制区域" : title)\(size)\(hint)"
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
            self.hideOptionsPanel()
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
        editor.layer?.borderColor = NSColor(hex: "#10AEFF")?.cgColor
        editor.layer?.borderWidth = 2
        editor.layer?.cornerRadius = 8
        addSubview(editor)
        updateEditorFrame()
        makeSelectionFocusTargets()
        makeToolbar()
        window?.makeFirstResponder(selectionFocusTarget)
        NSCursor.pop(); NSCursor.arrow.push()
        needsDisplay = true
    }

    private func makeToolbar() {
        toolButtons = AnnotationTool.allCases.enumerated().map { index, tool in
            let button = NSButton(image: Self.figmaIcon(Self.toolbarIconName(for: tool), tint: NSColor(hex: index == 0 ? "#10AEFF" : "#D9D9D9")), target: self, action: #selector(toolChanged(_:)))
            button.tag = index; button.isBordered = false; button.imagePosition = .imageOnly; button.widthAnchor.constraint(equalToConstant: 22).isActive = true; button.heightAnchor.constraint(equalToConstant: 22).isActive = true; button.setAccessibilityLabel(tool.rawValue); button.toolTip = tool.rawValue
            return button
        }
        let tools = NSStackView(views: toolButtons); tools.orientation = .horizontal; tools.spacing = 16; tools.alignment = .centerY
        updateToolIcons(selected: 0)
        let undo = iconButton("undo", "撤销", #selector(undoPressed))
        let close = iconButton("close", "关闭", #selector(closePressed), tint: NSColor(hex: "#FA5151"))
        let longShot = iconButton("long-shot", "滚动截图", #selector(scrollingPressed))
        let pin = iconButton("pin", "贴图", #selector(pinPressed))
        let save = iconButton("save", "保存", #selector(savePressed))
        let copy = iconButton("copy", "复制", #selector(copyPressed))
        let divider1 = divider(), divider2 = divider(), divider3 = divider()
        let toolbarItems: [NSView] = toolButtons.map { $0 as NSView } + [divider1, undo, close, divider2, longShot, divider3, pin, save, copy]
        toolbarControls = toolButtons + [undo, close, longShot]
        outputControls = [pin, save, copy]
        let toolRow = NSStackView(views: toolbarItems); toolRow.orientation = .horizontal; toolRow.spacing = 16; toolRow.alignment = .centerY
        toolRow.setCustomSpacing(15, after: divider1); toolRow.setCustomSpacing(15, after: divider2); toolRow.setCustomSpacing(15, after: divider3)
        let toolbar = NSView(frame: .zero); toolbar.wantsLayer = true; toolbar.layer?.cornerRadius = 12; toolbar.layer?.backgroundColor = NSColor(hex: "#333333")?.cgColor; toolbar.layer?.shadowColor = NSColor.black.cgColor; toolbar.layer?.shadowOpacity = 0.16; toolbar.layer?.shadowRadius = 4; toolbar.layer?.shadowOffset = CGSize(width: 0, height: -4)
        let content = toolRow
        let twoLines = CaptureOverlayLayout.toolbarUsesTwoLines(fixedWidth: 638, visibleWidth: targetScreen.visibleFrame.width)
        toolbar.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 18), content.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -18), content.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 12), content.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -12)])
        toolbar.layoutSubtreeIfNeeded()
        editor?.tool = .move
        updateStyleControls(for: .move)
        toolbar.layoutSubtreeIfNeeded()
        let visible = targetScreen.visibleFrame.offsetBy(dx: -targetScreen.frame.minX, dy: -targetScreen.frame.minY)
        toolbarFixedSize = CaptureOverlayLayout.toolbarSize(NSSize(width: 638, height: twoLines ? 92 : 46), visibleFrame: visible)
        addSubview(toolbar); self.toolbar = toolbar
        positionToolbar()
        updateFocusChain()
    }

    private func iconButton(_ asset: String, _ label: String, _ action: Selector, tint: NSColor? = NSColor(hex: "#D9D9D9")) -> NSButton {
        let button = NSButton(image: Self.figmaIcon(asset), target: self, action: action)
        button.isBordered = false; button.imageScaling = .scaleProportionallyDown; button.contentTintColor = tint
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true; button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        button.setAccessibilityLabel(label); button.toolTip = label
        return button
    }

    private func divider() -> NSView {
        let view = NSView(); view.wantsLayer = true; view.layer?.backgroundColor = NSColor(hex: "#777777")?.cgColor
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true; view.heightAnchor.constraint(equalToConstant: 12).isActive = true
        return view
    }

    private static func figmaIcon(_ name: String, size: NSSize = NSSize(width: 22, height: 22), tint: NSColor? = nil) -> NSImage {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("ShotX_ShotX.bundle")
        let bundle = packaged.flatMap(Bundle.init(url:)) ?? Bundle.module
        guard let url = bundle.url(forResource: name, withExtension: "svg") else { return NSImage(size: size) }
        if let tint, let svg = try? String(contentsOf: url, encoding: .utf8), let data = svg.replacingOccurrences(of: "#D9D9D9", with: tint.hex).data(using: .utf8), let image = NSImage(data: data) { return image.shotXSized(size) }
        guard let image = NSImage(contentsOf: url) else { return NSImage(size: size) }
        return image.shotXSized(size)
    }

    private func updateToolIcons(selected: Int) {
        for (index, tool) in AnnotationTool.allCases.enumerated() {
            let tint = NSColor(hex: index == selected ? "#10AEFF" : "#D9D9D9")!
            toolButtons[index].image = Self.figmaIcon(Self.toolbarIconName(for: tool), tint: tint)
        }
    }

    private static func toolbarIconName(for tool: AnnotationTool) -> String {
        switch tool {
        case .move: "move"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line"
        case .arrow: "arrow"
        case .pen: "pen"
        case .mosaic: "mosaic"
        case .text: "text"
        case .crop: "annotation"
        }
    }

    @objc private func scrollingPressed() { guard selection.width >= 1, selection.height >= 1 else { return }; hideOptionsPanel(animated: true); onScrolling?(selection) }

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

    @objc private func toolChanged(_ sender: NSButton) {
        let index = sender.tag
        let tool = AnnotationTool.allCases[index]
        lastToolIndex = index
        updateToolIcons(selected: index)
        editor?.tool = tool
        updateStyleControls(for: tool)
        window?.makeKey()
        window?.makeFirstResponder(editor)
        if AnnotationTool.styledCases.contains(tool) {
            if optionsPanel?.isVisible == true { rebuildOptionsPanel() } else { showOptionsPanel() }
        } else {
            hideOptionsPanel(animated: true)
        }
    }

    @objc private func stylePressed() {
        guard let editor, AnnotationTool.styledCases.contains(editor.tool) else { return }
        if optionsPanel?.isVisible != true { showOptionsPanel() }
    }

    private func showOptionsPanel() {
        if optionsPanel != nil { rebuildOptionsPanel(); return }
        let width: CGFloat = editor?.tool == .text ? 200 : 152
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 72), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = CaptureOverlayLayout.optionsPanelLevel
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.sharingType = .none
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.alphaValue = 1
        let content = makeOptionsContent()
        panel.contentView = content
        panel.setContentSize(NSSize(width: width, height: 72))
        optionsPanel = panel
        positionOptionsPanel()
        panel.orderFrontRegardless()
        updateFocusChain()
        AccessibilityAnnouncements.post("样式，颜色和粗细", on: panel)
    }

    private func rebuildOptionsPanel() {
        guard let panel = optionsPanel else { showOptionsPanel(); return }
        let width: CGFloat = editor?.tool == .text ? 200 : 152
        panel.alphaValue = 1
        panel.contentView = makeOptionsContent()
        panel.setContentSize(NSSize(width: width, height: 72))
        positionOptionsPanel(animated: true)
        panel.orderFrontRegardless()
        updateFocusChain()
    }

    private func hideOptionsPanel(animated: Bool = false) {
        guard let panel = optionsPanel else { return }
        optionsPanel = nil
        updateFocusChain()
        window?.makeKey()
        window?.makeFirstResponder(editor)
        guard animated else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { panel.orderOut(nil) }
    }

    private func makeOptionsContent() -> NSView {
        guard let tool = editor?.tool else { return NSView() }
        optionsControls = []
        let width: CGFloat = tool == .text ? 200 : 152
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 72)); content.wantsLayer = true
        let body = CAShapeLayer(); body.fillColor = NSColor(hex: "#333333")?.cgColor; body.path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: 60), cornerWidth: 30, cornerHeight: 30, transform: nil); content.layer?.addSublayer(body)
        let tail = NSImageView(image: Self.figmaIcon("drop-over-tail", size: NSSize(width: 16, height: 9.59167))); tail.imageScaling = .scaleAxesIndependently; content.addSubview(tail); optionsTailView = tail; updateOptionsTail(anchorX: width / 2, width: width)
        let size = SizeDotControl(frame: NSRect(x: 16, y: 14, width: 32, height: 32)); size.minValue = tool.styleRange.min; size.maxValue = tool.styleRange.max; size.doubleValue = currentSize(for: tool); size.target = self; size.action = #selector(sizeDotChanged(_:)); size.setAccessibilityLabel(tool.styleLabel); content.addSubview(size); optionsControls.append(size)
        let firstDivider = divider(); firstDivider.frame = NSRect(x: 56, y: 24, width: 1, height: 12); content.addSubview(firstDivider)
        var colorsX: CGFloat = 64
        if tool == .text {
            let names = ["text-style-normal", "text-style-outline-1", "text-style-outline-2", "text-style-highlight"]
            let textStyle = NSButton(image: Self.figmaIcon(names[editor?.textStyle.rawValue ?? 0], size: NSSize(width: 32, height: 32)), target: self, action: #selector(cycleTextStyle(_:))); textStyle.isBordered = false; textStyle.imagePosition = .imageOnly; textStyle.frame = NSRect(x: 64, y: 14, width: 32, height: 32); textStyle.setAccessibilityLabel("字符样式"); content.addSubview(textStyle); optionsControls.append(textStyle)
            let secondDivider = divider(); secondDivider.frame = NSRect(x: 104, y: 24, width: 1, height: 12); content.addSubview(secondDivider); colorsX = 112
        }
        swatchButtons = []
        for (index, color) in Self.figmaColors.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(figmaPresetPicked(_:))); button.isBordered = false; button.tag = index
            button.image = Self.figmaSwatchImage(color, selected: color.hex == currentAnnotationColor.hex); button.imagePosition = .imageOnly
            button.frame = NSRect(x: colorsX + CGFloat(index % 3) * 25, y: index < 3 ? 30 : 8, width: 22, height: 22); content.addSubview(button); swatchButtons.append(button); optionsControls.append(button)
        }
        optionsContentHeight = 60
        return content
    }

    @objc private func sizeDotChanged(_ sender: SizeDotControl) {
        guard let tool = editor?.tool else { return }
        editor?.applyStyleLive(color: currentAnnotationColor, size: sender.doubleValue); model?.settings.annotationSizes[tool.rawValue] = sender.doubleValue; model?.persist(); updateStyleButton()
    }

    @objc private func cycleTextStyle(_ sender: NSButton) {
        guard let editor else { return }
        let next = AnnotationTextStyle(rawValue: (editor.textStyle.rawValue + 1) % AnnotationTextStyle.allCases.count) ?? .normal
        editor.setTextStyle(next)
        let names = ["text-style-normal", "text-style-outline-1", "text-style-outline-2", "text-style-highlight"]
        sender.image = Self.figmaIcon(names[next.rawValue], size: NSSize(width: 32, height: 32))
        sender.setAccessibilityValue(["正常字符", "描边字符", "颜色颠倒的描边", "高亮"][next.rawValue])
    }

    @objc private func figmaPresetPicked(_ sender: NSButton) { guard Self.figmaColors.indices.contains(sender.tag) else { return }; applyPickedColor(Self.figmaColors[sender.tag]) }

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
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = ShotXOutputName.make(extension: "png")
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
    private func renderOutput() -> NSImage? { editor?.render() }
    private func commit(_ image: NSImage) { hideOptionsPanel(); phase.commit(); onCommit?(image) }

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
        let colors = swatchButtons.count == Self.figmaColors.count ? Self.figmaColors : Self.presetColors
        for (index, button) in swatchButtons.enumerated() where index < colors.count {
            let color = colors[index]
            let selected = color.hex == currentAnnotationColor.hex
            button.image = colors.count == Self.figmaColors.count ? Self.figmaSwatchImage(color, selected: selected) : Self.swatchImage(color, size: NSSize(width: 20, height: 16), selected: selected)
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
    private static let figmaColors: [NSColor] = ["#FA5151", "#000000", "#FFFFFF", "#10AEFF", "#34A853", "#FFC300"].compactMap { NSColor(hex: $0) }
    private static func figmaSwatchImage(_ color: NSColor, selected: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 22)); image.lockFocus()
        color.setFill(); NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 16, height: 16)).fill()
        if selected { AnnotationView.focusedStroke(for: color).setStroke(); let ring = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 20, height: 20)); ring.lineWidth = 2; ring.stroke() }
        image.unlockFocus(); return image
    }
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
            updateFocusChain()
            return
        }
        let size = toolbarFixedSize.width > 0 ? toolbarFixedSize : toolbar.fittingSize
        let visible = targetScreen.visibleFrame.offsetBy(dx: -targetScreen.frame.minX, dy: -targetScreen.frame.minY)
        toolbar.frame = CaptureOverlayLayout.toolbarFrame(size: size, selection: selection, visibleFrame: visible)
        positionOptionsPanel()
        updateFocusChain()
    }

    private func positionOptionsPanel(animated: Bool = false) {
        guard let optionsPanel, let toolbar, toolButtons.indices.contains(lastToolIndex) else { return }
        let visible = targetScreen.visibleFrame
        let anchor = toolButtons[lastToolIndex]
        let anchorScreen = window.map { $0.convertToScreen(anchor.convert(anchor.bounds, to: nil)) } ?? anchor.frame
        let toolbarScreen = window.map { $0.convertToScreen(toolbar.convert(toolbar.bounds, to: nil)) } ?? toolbar.frame
        let size = optionsPanel.frame.size
        let bounds = visible.insetBy(dx: CaptureOverlayLayout.edgeInset, dy: CaptureOverlayLayout.edgeInset)
        let x = min(max(bounds.minX, anchorScreen.midX - size.width / 2), bounds.maxX - size.width)
        let gap: CGFloat = 8
        let below = toolbarScreen.minY - size.height - gap
        let y = below >= bounds.minY ? below : min(bounds.maxY - size.height, toolbarScreen.maxY + gap)
        let origin = CGPoint(x: x, y: y)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                updateOptionsTail(anchorX: anchorScreen.midX - x, width: size.width, animated: true)
            }
            optionsPanel.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
        } else {
            optionsPanel.setFrameOrigin(origin)
            updateOptionsTail(anchorX: anchorScreen.midX - x, width: size.width)
        }
        optionsPanel.orderFrontRegardless()
    }

    private func updateOptionsTail(anchorX: CGFloat, width: CGFloat, animated: Bool = false) {
        let x = min(max(10, anchorX), width - 10)
        let frame = NSRect(x: x - 8, y: 59, width: 16, height: 9.59167)
        if animated { optionsTailView?.animator().frame = frame } else { optionsTailView?.frame = frame }
    }

    private func handle(at point: CGPoint) -> SelectionHandle? {
        let radius: CGFloat = 10
        let handles: [(SelectionHandle, CGPoint)] = [(.southWest, CGPoint(x: selection.minX, y: selection.minY)), (.south, CGPoint(x: selection.midX, y: selection.minY)), (.southEast, CGPoint(x: selection.maxX, y: selection.minY)), (.west, CGPoint(x: selection.minX, y: selection.midY)), (.east, CGPoint(x: selection.maxX, y: selection.midY)), (.northWest, CGPoint(x: selection.minX, y: selection.maxY)), (.north, CGPoint(x: selection.midX, y: selection.maxY)), (.northEast, CGPoint(x: selection.maxX, y: selection.maxY))]
        return handles.first { hypot($0.1.x - point.x, $0.1.y - point.y) <= radius }?.0 ?? (selection.contains(point) && (editor == nil || mode == .regionRecording) ? .move : nil)
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
        drawSelectionAccents(around: rect, color: NSColor(hex: "#10AEFF")!)
    }

    private func drawSelectionAccents(around rect: CGRect, color: NSColor) {
        color.setStroke()
        for (x, y, sx, sy) in [(rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1.0, 1.0), (rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0)] {
            let p = NSBezierPath(); p.move(to: CGPoint(x: x + 26 * sx, y: y)); p.line(to: CGPoint(x: x + 8 * sx, y: y)); p.curve(to: CGPoint(x: x, y: y + 8 * sy), controlPoint1: CGPoint(x: x + 3 * sx, y: y), controlPoint2: CGPoint(x: x, y: y + 3 * sy)); p.line(to: CGPoint(x: x, y: y + 26 * sy)); p.lineWidth = 3; p.lineCapStyle = .round; p.stroke()
        }
        for (a, b) in [(CGPoint(x: rect.midX - 11, y: rect.minY), CGPoint(x: rect.midX + 11, y: rect.minY)), (CGPoint(x: rect.midX - 11, y: rect.maxY), CGPoint(x: rect.midX + 11, y: rect.maxY)), (CGPoint(x: rect.minX, y: rect.midY - 11), CGPoint(x: rect.minX, y: rect.midY + 11)), (CGPoint(x: rect.maxX, y: rect.midY - 11), CGPoint(x: rect.maxX, y: rect.midY + 11))] { let p = NSBezierPath(); p.move(to: a); p.line(to: b); p.lineWidth = 3; p.lineCapStyle = .round; p.stroke() }
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

final class SizeDotControl: NSControl {
    var minValue = 1.0
    var maxValue = 8.0
    override var doubleValue: Double { didSet { needsDisplay = true; setAccessibilityValue(String(Int(doubleValue))) } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        NSColor(hex: "#D9D9D9")!.setStroke()
        let ring = NSBezierPath(ovalIn: CGRect(x: center.x - 14.43, y: center.y - 14.43, width: 28.86, height: 28.86)); ring.lineWidth = 1.14; ring.stroke()
        let progress = maxValue > minValue ? (doubleValue - minValue) / (maxValue - minValue) : 0
        let radius = CGFloat(3 + progress * 8)
        NSColor(hex: "#D9D9D9")!.setFill(); NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let origin = event.locationInWindow.x, initial = doubleValue
        var next = event
        repeat {
            if next.type == .leftMouseDragged || next.type == .leftMouseDown {
                doubleValue = min(maxValue, max(minValue, initial + Double(next.locationInWindow.x - origin) / 32 * (maxValue - minValue)))
                sendAction(action, to: target)
            }
            guard next.type != .leftMouseUp, let event = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            next = event
        } while true
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 123 || event.keyCode == 124 else { super.keyDown(with: event); return }
        doubleValue = min(maxValue, max(minValue, doubleValue + (event.keyCode == 124 ? 1 : -1))); sendAction(action, to: target)
    }
}
