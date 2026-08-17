import AppKit
import AVFoundation
import Combine
import CoreMedia
import CoreImage
import ScreenCaptureKit
import SwiftUI

enum DiskGuard {
    static let minimumToStart: Int64 = 2_000_000_000
    static let warning: Int64 = 1_000_000_000
    static let stop: Int64 = 500_000_000

    enum State: Equatable { case ready, warning, stop }
    static func state(bytes: Int64) -> State { bytes < stop ? .stop : bytes < warning ? .warning : .ready }
}

struct CaptureGeometry {
    let screenFrame: CGRect
    let sourceRect: CGRect
    let outputSize: CGSize
    func outputPoint(for global: CGPoint) -> CGPoint? {
        let local = CGPoint(x: global.x - screenFrame.minX, y: global.y - screenFrame.minY)
        guard sourceRect.contains(local) else { return nil }
        return CGPoint(x: (local.x - sourceRect.minX) / sourceRect.width * outputSize.width, y: (local.y - sourceRect.minY) / sourceRect.height * outputSize.height)
    }
}

/// Live selection geometry shared between the interactive selection layer and the setup panel.
/// Updated on every selection move/resize so the read-only "原始尺寸" stays in sync before locking.
@MainActor
private final class RecordingSetupGeometry: ObservableObject {
    @Published var selection: CGRect
    @Published var cameraHint: String?
    let scale: CGFloat
    init(selection: CGRect, scale: CGFloat) {
        self.selection = selection
        self.scale = scale
    }
}

enum RecordingOverlayState: Equatable {
    case setup
    case countdown(Int)
    case recording

    var maskAlpha: CGFloat {
        switch self { case .setup, .countdown: 0.28; case .recording: 0.45 }
    }
    var label: String {
        switch self {
        case .setup, .countdown: "录制区域"
        case .recording: "● REC · 录制区域"
        }
    }
}

enum RecordingOutputSize {
    static func pixels(source: CGSize, scale: CGFloat) -> CGSize {
        rounded(CGSize(width: source.width * scale, height: source.height * scale))
    }

    static func displayText(source: CGSize, scale: CGFloat) -> String {
        let px = pixels(source: source, scale: scale)
        return "\(Int(px.width)) × \(Int(px.height)) px"
    }

    private static func rounded(_ size: CGSize) -> CGSize {
        CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded()))
    }
}

enum CameraOverlaySize: String, Codable, CaseIterable, Identifiable {
    case small, large
    var id: String { rawValue }
    var side: CGFloat { self == .small ? 96 : 192 }
    var displayName: String { self == .small ? "小" : "大" }
}

enum CameraOverlayLayout {
    static let margin: CGFloat = 12
    static let cornerRadius: CGFloat = 12
    static let minimumSide: CGFloat = 64

    /// 圆角正方形画中画矩形，锚定在选区左下角、带 margin（BRA102-04）。
    /// `scale` 把设计点值换算到调用方坐标系：预览窗为 1（点），成片合成为 backingScaleFactor（像素），
    /// 两处调用同一布局函数保证设置态预览与成片逐像素一致（BRA102-07）。
    /// 选区过小（最小档 + margin 放不下）时返回 nil，调用方应隐藏画中画并提示。
    static func rect(in bounds: CGRect, size: CameraOverlaySize, scale: CGFloat = 1) -> CGRect? {
        let margin = margin * scale
        let available = min(bounds.width, bounds.height) - margin * 2
        let minimum = minimumSide * scale
        guard available >= minimum else { return nil }
        let side = min(size.side * scale, available)
        return CGRect(x: bounds.minX + margin, y: bounds.minY + margin, width: side, height: side)
    }
}

/// 摄像头会话。设置态开启摄像头开关即启动（BRA102-03），录制前就绪，录制期间持续供帧；
/// 同时服务画中画预览层与成片合成帧，保证预览与成片一致（BRA102-07）。
final class CameraSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static func hasAvailableDevice() -> Bool { AVCaptureDevice.default(for: .video) != nil }
    static func device(for settings: AppSettings) -> AVCaptureDevice? {
        settings.selectedCameraID.isEmpty ? AVCaptureDevice.default(for: .video) : AVCaptureDevice(uniqueID: settings.selectedCameraID)
    }

    /// 模糊背景能力检测：仅当系统人像效果支持时展示对应开关（BRA102-06，不支持不显示、不冒充）。
    static func supportsBackgroundBlur() -> Bool {
        guard let device = AVCaptureDevice.default(for: .video) else { return false }
        return device.activeFormat.isPortraitEffectSupported
    }

    private let queue = DispatchQueue(label: "ShotX.camera")
    private let lock = NSLock()
    private var latest: CIImage?
    private var output: AVCaptureVideoDataOutput?
    private var disconnectObserver: NSObjectProtocol?
    private var started = false

    private(set) var session: AVCaptureSession?
    private(set) var device: AVCaptureDevice?
    var onDisconnect: (() -> Void)?

    /// 最新摄像头帧；成片合成时读取（nil 表示暂无帧，录屏不含画中画）。
    var latestFrame: CIImage? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    @discardableResult
    func start(settings: AppSettings) -> Bool {
        guard !started, let device = Self.device(for: settings) else { return false }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            let session = AVCaptureSession()
            session.beginConfiguration()
            session.sessionPreset = .medium
            guard session.canAddInput(input) else { return false }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { return false }
            session.addOutput(output)
            session.commitConfiguration()
            self.session = session
            self.output = output
            self.device = device
            session.startRunning()
            started = true
            installDisconnectObserver()
            applyBackgroundBlur(settings.cameraBackgroundBlur)
            return true
        } catch {
            self.session = nil
            self.output = nil
            self.device = nil
            return false
        }
    }

    func stop() {
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
        disconnectObserver = nil
        output = nil
        session?.stopRunning()
        session = nil
        device = nil
        started = false
        lock.lock()
        latest = nil
        lock.unlock()
    }

    /// 模糊背景仅当系统人像效果当前处于活动态才真实生效（macOS 由「控制中心」人像效果控制，
    /// 应用无法编程强制）；返回是否实际生效，调用方据此提示/回退，杜绝假实现。
    @discardableResult
    func applyBackgroundBlur(_ enabled: Bool) -> Bool {
        guard let device else { return false }
        guard enabled, device.activeFormat.isPortraitEffectSupported else { return false }
        return device.isPortraitEffectActive
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output === self.output, let pixel = sampleBuffer.imageBuffer else { return }
        lock.lock()
        latest = CIImage(cvPixelBuffer: pixel)
        lock.unlock()
    }

    private func installDisconnectObserver() {
        disconnectObserver = NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let self, let device = notification.object as? AVCaptureDevice, device.hasMediaType(.video), device == self.device else { return }
            self.stop()
            DispatchQueue.main.async { self.onDisconnect?() }
        }
    }
}

enum RecoveryStore {
    static func directory(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let url = support.appendingPathComponent("ShotX/Recovery", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func newURL() throws -> URL {
        try directory().appendingPathComponent(ShotXOutputName.make(extension: "mp4"))
    }

    static func recoverableVideos(fileManager: FileManager = .default) -> [URL] {
        guard let directory = try? directory(fileManager: fileManager) else { return [] }
        return (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]))?.filter {
            $0.pathExtension == "mp4" && ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
        } ?? []
    }
}

@MainActor
final class RecordingCoordinator: NSObject {
    static let shared = RecordingCoordinator()
    private var recorder: ScreenRecorder?
    private weak var model: AppModel?
    private var status: RecordingStatusWindowController?
    private var setup: RecordingSetupWindowController?
    private var overlay: RecordingRegionOverlayController?
    private var cameraPreview: CameraPreviewWindowController?
    private var cameraSession: CameraSession?
    private var geometry: RecordingSetupGeometry?
    private weak var selection: SelectionWindowController?
    private var countdownTask: Task<Void, Never>?
    private var escapeMonitor: Any?
    private var activationObserver: Any?
    private var menuTrackingObservers: [NSObjectProtocol] = []
    private var menuTracking = false
    private var permissionPromptActive = false
    private var pending: (display: SCDisplay, screen: NSScreen, rect: CGRect, mode: CaptureMode)?

    func prepare(display: SCDisplay, screen: NSScreen, localRect: CGRect, mode: CaptureMode, model: AppModel, selection: SelectionWindowController? = nil) async {
        cancelUI()
        self.model = model
        pending = (display, screen, localRect, mode)
        if let selection {
            self.selection = selection
            selection.enterRecordingSetup(onChanged: { [weak self] rect in self?.updateSetupGeometry(rect) }, onExit: { [weak self] in self?.returnToSelection() })
        } else {
            overlay = RecordingRegionOverlayController(screen: screen, selection: localRect)
            overlay?.show(state: .setup)
        }
        openSetupPanel()
        restoreSetupOnActivation()
        installMenuTrackingObserver()
        installEscapeMonitor { [weak self] in self?.returnToSelection() }
    }

    private func openSetupPanel() {
        guard let pending, let model else { return }
        let rect = selection?.selectionRect ?? pending.rect
        let geometry = RecordingSetupGeometry(selection: rect, scale: pending.screen.backingScaleFactor)
        self.geometry = geometry
        setup = RecordingSetupWindowController(model: model, screen: pending.screen, geometry: geometry, onStart: { [weak self] in self?.beginCountdown() }, onReturn: { [weak self] in self?.returnToSelection() }, onCameraChanged: { [weak self] enabled in self?.setCamera(enabled) }, onCameraPermissionChanged: { [weak self] state in self?.cameraPermissionChanged(state) }, onCameraSettingsChanged: { [weak self] in self?.updateCameraSettings() }, onPermissionRequest: { [weak self] kind in self?.requestRecordingPermission(kind) }, onPermissionRequestFinished: { [weak self] in self?.resumeSetupAfterPermission() })
        setup?.showWindow(nil)
        setup?.window?.makeKeyAndOrderFront(nil)
        syncCamera()
    }

    private func updateSetupGeometry(_ rect: CGRect) {
        geometry?.selection = rect
        setup?.reposition()
        updateCameraPreview()
    }

    /// 摄像头开启/关闭（BRA102-03）：开启即按需申请权限并启动会话，无需等录制开始。
    /// BRA-116：权限未就绪时先不落定 `cameraEnabled`（避免假开启态），授权回调后再启用并启动会话。
    private func setCamera(_ enabled: Bool) {
        guard let model else { return }
        if !enabled {
            model.setCameraEnableIntent(false)
            model.settings.cameraEnabled = false
            stopCameraSession()
            return
        }
        switch model.permissions[.camera] {
        case .allowed:
            model.settings.cameraEnabled = true
            startCameraSession()
        case .notDetermined:
            // 授权回调刷新权限后由 cameraPermissionChanged 落定开关并启动会话。
            model.setCameraEnableIntent(true)
            requestRecordingPermission(.camera)
        default:
            model.settings.cameraEnabled = false
            model.showError("摄像头不可用。你仍可继续无摄像头录制。")
        }
    }

    /// 摄像头权限状态变化（授权回调刷新后），权限就绪且开关仍开启时启动会话。
    /// BRA-116：`setCamera` 不再预置开关，授权后在此落定 `cameraEnabled` 并启动会话。
    private func cameraPermissionChanged(_ state: PermissionState?) {
        guard let model else { return }
        guard state == .allowed else { return }
        if model.settings.cameraEnabled, model.permissions[.camera] == .allowed {
            startCameraSession()
        }
    }

    /// 打开设置面板/权限就绪后调用：若开关开启且已授权则启动会话 + 显示预览。
    private func syncCamera() {
        guard model?.settings.cameraEnabled == true, model?.permissions[.camera] == .allowed else { return }
        startCameraSession()
    }

    /// 系统权限窗口的层级由 macOS 管理；请求前隐藏 ShotX 的 screenSaver 浮层，避免挡住系统窗口。
    private func requestRecordingPermission(_ kind: PermissionKind) {
        guard let model else { return }
        permissionPromptActive = true
        setup?.window?.orderOut(nil)
        selection?.hideForCountdown()
        overlay?.hide()
        cameraPreview?.hide()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
        model.request(kind)
    }

    private func resumeSetupAfterPermission() {
        guard permissionPromptActive else { return }
        permissionPromptActive = false
        selection?.showForSetup()
        overlay?.show(state: .setup)
        setup?.showWindow(nil)
        setup?.window?.makeKeyAndOrderFront(nil)
        cameraPreview?.show()
        installEscapeMonitor { [weak self] in self?.returnToSelection() }
    }

    private func startCameraSession() {
        guard let model, cameraSession == nil, model.settings.cameraEnabled, model.permissions[.camera] == .allowed else { return }
        guard CameraSession.hasAvailableDevice() else {
            model.settings.cameraEnabled = false
            model.persist()
            model.showError("未找到摄像头")
            return
        }
        let session = CameraSession()
        session.onDisconnect = { [weak self] in self?.cameraDisconnected() }
        guard session.start(settings: model.settings) else {
            model.settings.cameraEnabled = false
            model.persist()
            model.showError("无法启动摄像头。你仍可继续无摄像头录制。")
            return
        }
        cameraSession = session
        if model.settings.cameraBackgroundBlur, !session.applyBackgroundBlur(true) {
            model.settings.cameraBackgroundBlur = false
            model.showError("背景模糊需要系统「人像效果」支持。请在控制中心开启后重试。")
        }
        updateCameraPreview()
    }

    private func stopCameraSession() {
        cameraSession?.onDisconnect = nil
        cameraSession?.stop()
        cameraSession = nil
        cameraPreview?.close()
        cameraPreview = nil
        geometry?.cameraHint = nil
    }

    /// 摄像头设备断开（录制中/设置态）：关闭画中画并明确提示，录屏其余轨不受影响。
    private func cameraDisconnected() {
        cameraSession = nil
        cameraPreview?.close()
        cameraPreview = nil
        geometry?.cameraHint = nil
        model?.showError("摄像头已断开，其他来源仍在录制。")
    }

    /// 尺寸/设置变化后同步预览与提示（BRA102-05/06/07），选区过小则隐藏并提示。
    private func updateCameraSettings() {
        if let model, let device = cameraSession?.device, device.uniqueID != CameraSession.device(for: model.settings)?.uniqueID {
            stopCameraSession()
            startCameraSession()
            return
        }
        if let session = cameraSession {
            if model?.settings.cameraBackgroundBlur == true, !session.applyBackgroundBlur(true) {
                model?.settings.cameraBackgroundBlur = false
                model?.showError("背景模糊需要系统「人像效果」支持。请在控制中心开启后重试。")
            } else {
                session.applyBackgroundBlur(model?.settings.cameraBackgroundBlur == true)
            }
        }
        updateCameraPreview()
    }

    /// 画中画预览窗随选区/尺寸实时更新；选区过小时隐藏并提示（CAM-too-small）。
    private func updateCameraPreview() {
        guard cameraSession != nil, let model, let pending else { return }
        let selection = geometry?.selection ?? pending.rect
        guard CameraOverlayLayout.rect(in: CGRect(origin: .zero, size: selection.size), size: model.settings.cameraSize) != nil else {
            geometry?.cameraHint = "选区过小，无法显示摄像头画面"
            cameraPreview?.close()
            cameraPreview = nil
            return
        }
        geometry?.cameraHint = nil
        if let cameraPreview {
            cameraPreview.update(selection: selection, size: model.settings.cameraSize, mirror: model.settings.cameraMirror)
        } else if let session = cameraSession?.session {
            let preview = CameraPreviewWindowController(session: session, screen: pending.screen, selection: selection, size: model.settings.cameraSize, mirror: model.settings.cameraMirror)
            preview.show()
            cameraPreview = preview
        }
    }

    /// Skips the settings panel and starts recording with the current selection + default settings,
    /// used by the 空格 quick-start in the recording region selection.
    func startImmediately(display: SCDisplay, screen: NSScreen, localRect: CGRect, mode: CaptureMode, model: AppModel) async {
        cancelUI()
        self.model = model
        pending = (display, screen, localRect, mode)
        overlay = RecordingRegionOverlayController(screen: screen, selection: localRect)
        overlay?.show(state: .setup)
        syncCamera()
        beginCountdown()
    }

    private func beginCountdown() {
        guard freeBytes() >= DiskGuard.minimumToStart else {
            model?.showError("可用空间不足 2 GB，无法开始录制。请释放空间后重试。")
            return
        }
        guard let pending, let model else { return }
        let locked = selection?.selectionRect ?? pending.rect
        self.pending = (display: pending.display, screen: pending.screen, rect: locked, mode: pending.mode)
        setup?.close()
        setup = nil
        geometry = nil
        selection?.hideForCountdown()
        overlay?.close()
        overlay = RecordingRegionOverlayController(screen: pending.screen, selection: locked)
        var settings = model.settings
        if settings.microphone && (model.permissions[.microphone] != .allowed || !RecordingDeviceAvailability.hasMicrophoneDevice()) {
            settings.microphone = false
            model.showError("麦克风不可用。你仍可继续无麦克风录制。")
        }
        if settings.cameraEnabled && (model.permissions[.camera] != .allowed || !RecordingDeviceAvailability.hasCameraDevice()) {
            settings.cameraEnabled = false
            model.showError("摄像头不可用。你仍可继续无摄像头录制。")
        }
        let delay = settings.countdown
        status = RecordingStatusWindowController(screen: pending.screen, selection: locked, onStop: { [weak self] in self?.cancelCountdown() })
        overlay?.show(state: .countdown(delay))
        status?.showCountdown(delay)
        installEscapeMonitor { [weak self] in self?.cancelCountdown() }
        countdownTask = Task { [weak self] in
            if delay > 0 {
                for value in stride(from: delay, through: 1, by: -1) {
                    guard !Task.isCancelled else { return }
                    self?.overlay?.show(state: .countdown(value))
                    self?.status?.showCountdown(value)
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            guard !Task.isCancelled, let self else { return }
            if let escapeMonitor = self.escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
            await self.start(display: pending.display, screen: pending.screen, localRect: locked, settings: settings)
        }
    }

    func stop() {
        countdownTask?.cancel()
        countdownTask = nil
        guard let recorder else { cancelCountdown(); return }
        status?.showProcessing()
        Task { await recorder.stop() }
    }

    private func start(display: SCDisplay, screen: NSScreen, localRect: CGRect, settings: AppSettings) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let scale = screen.backingScaleFactor
            let source = CGRect(x: max(0, localRect.minX), y: max(0, screen.frame.height - localRect.maxY), width: localRect.width, height: localRect.height).integral
            let output = RecordingOutputSize.pixels(source: source.size, scale: scale)
            let url = try RecoveryStore.newURL()
            let recorder = try ScreenRecorder(url: url, filter: filter, screenFrame: screen.frame, sourceRect: source, width: Int(output.width), height: Int(output.height), settings: settings, cameraFeed: cameraSession, onNotice: { [weak model] message in
                Task { @MainActor in model?.showError(message) }
            }, onMicrophoneLost: { [weak model] in
                Task { @MainActor in model?.showError("麦克风已断开，录屏将继续保留其他声音来源。") }
            }) { [weak self] result in
                Task { @MainActor in self?.finished(result) }
            }
            self.recorder = recorder
            model?.setRecording(true)
            CaptureCoordinator.shared.cancel()
            selection = nil
            overlay?.show(state: .recording)
            status?.setOnStop { [weak self] in self?.stop() }
            status?.showRecording(started: Date())
            try await recorder.start()
        } catch {
            recorder = nil
            model?.setRecording(false)
            cancelUI()
            model?.showError("无法开始录屏：\(error.localizedDescription)")
        }
    }

    private func finished(_ result: Result<URL, Error>) {
        recorder = nil
        model?.setRecording(false)
        status?.close()
        status = nil
        overlay?.close()
        overlay = nil
        stopCameraSession()
        selection = nil
        pending = nil
        switch result {
        case .success(let url): model?.acceptVideo(url)
        case .failure(let error): model?.showError("录屏处理失败。恢复文件仍保留：\(error.localizedDescription)")
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
        status?.close()
        status = nil
        overlay?.close()
        overlay = nil
        guard recorder == nil, let pending, let model else { return }
        if let selection {
            // 倒计时 Esc 返回设置态：画中画预览保持显示，选区/尺寸可继续调整（UX 标注 §2.5）。
            selection.showForSetup()
            openSetupPanel()
            installMenuTrackingObserver()
            installEscapeMonitor { [weak self] in self?.returnToSelection() }
        } else {
            stopCameraSession()
            Task { await CaptureCoordinator.shared.begin(mode: pending.mode, model: model, targetScreen: pending.screen) }
        }
    }

    private func returnToSelection() {
        guard let pending, let model else { return }
        let mode = pending.mode
        let screen = pending.screen
        if let selection {
            setup?.close()
            setup = nil
            geometry = nil
            stopCameraSession()
            selection.exitRecordingSetup()
            self.selection = nil
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
            self.pending = nil
        } else {
            cancelUI()
            Task { await CaptureCoordinator.shared.begin(mode: mode, model: model, targetScreen: screen) }
        }
    }

    private func restoreSetupOnActivation() {
        if activationObserver != nil { return }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restoreSetup() }
        }
    }

    private func installMenuTrackingObserver() {
        guard menuTrackingObservers.isEmpty else { return }
        let center = NotificationCenter.default
        menuTrackingObservers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.menuTracking = true } })
        menuTrackingObservers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.menuTracking = false } })
    }

    private func installEscapeMonitor(_ handler: @escaping () -> Void) {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            if self?.menuTracking == true { return event }
            handler()
            return nil
        }
    }

    private func restoreSetup() {
        guard !permissionPromptActive, pending != nil, recorder == nil, countdownTask == nil else { return }
        if let setup {
            if setup.window?.isVisible != true {
                setup.showWindow(nil)
                setup.window?.makeKeyAndOrderFront(nil)
            }
        } else {
            openSetupPanel()
        }
        installMenuTrackingObserver()
        installEscapeMonitor { [weak self] in self?.returnToSelection() }
    }

    private func cancelUI() {
        countdownTask?.cancel()
        countdownTask = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver); self.activationObserver = nil }
        menuTrackingObservers.forEach { NotificationCenter.default.removeObserver($0) }
        menuTrackingObservers = []
        menuTracking = false
        permissionPromptActive = false
        setup?.close()
        setup = nil
        status?.close()
        status = nil
        overlay?.close()
        overlay = nil
        stopCameraSession()
        geometry = nil
        selection = nil
        pending = nil
    }

    private func freeBytes() -> Int64 {
        let values = try? RecoveryStore.directory().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

private final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let url: URL
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let videoAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audio: AVAssetWriterInput?
    private let mixer: RecordingAudioMixer?
    private var pendingAudio: [CMSampleBuffer] = []
    private let stream: SCStream
    private let queue = DispatchQueue(label: "ShotX.recording")
    private let completion: (Result<URL, Error>) -> Void
    private var started = false
    private var finishing = false
    private var diskTimer: DispatchSourceTimer?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let width: Int
    private let height: Int
    private let screenFrame: CGRect
    private let sourceRect: CGRect
    private let showsClicks: Bool
    private var lastClick: (CGPoint, Date)?
    private var clickMonitor: Any?
    private var sourceSession: AVCaptureSession?
    private var microphoneOutput: AVCaptureAudioDataOutput?
    private var cameraFeed: CameraSession?
    private let cameraSize: CameraOverlaySize
    private let cameraMirror: Bool
    private let cameraScale: CGFloat
    private var disconnectObserver: NSObjectProtocol?
    private let onNotice: (String) -> Void
    private let onMicrophoneLost: () -> Void
    private var warnedDisk = false

    init(url: URL, filter: SCContentFilter, screenFrame: CGRect, sourceRect: CGRect, width: Int, height: Int, settings: AppSettings, cameraFeed: CameraSession?, onNotice: @escaping (String) -> Void, onMicrophoneLost: @escaping () -> Void = {}, completion: @escaping (Result<URL, Error>) -> Void) throws {
        self.url = url
        self.completion = completion
        self.onNotice = onNotice
        self.onMicrophoneLost = onMicrophoneLost
        self.cameraFeed = cameraFeed
        cameraSize = settings.cameraSize
        cameraMirror = settings.cameraMirror
        cameraScale = sourceRect.width > 0 ? CGFloat(width) / sourceRect.width : 1
        self.width = width; self.height = height; self.screenFrame = screenFrame; self.sourceRect = sourceRect; showsClicks = settings.showsClicks
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000, AVVideoMaxKeyFrameIntervalKey: 60]
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        func audioInput(_ writer: AVAssetWriter) -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            return input
        }
        let wantsAudio = settings.systemAudio || settings.microphone
        if wantsAudio {
            let input = audioInput(writer)
            let mixer = RecordingAudioMixer()
            // 麦克风会话尚未创建；此处先按系统声音配置，makeSourceSession 后再据设备是否可用刷新。
            mixer.configure(system: settings.systemAudio, microphoneConfigured: false)
            self.audio = input
            self.mixer = mixer
        } else {
            self.audio = nil
            self.mixer = nil
        }

        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = settings.showsCursor
        config.capturesAudio = settings.systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        super.init()
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if settings.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if settings.microphone { sourceSession = try makeSourceSession(settings: settings) }
        // 麦克风会话是否真实存在（有输入输出）决定混音器是否等它；无设备则当作未启用，不阻塞系统声音。
        mixer?.configure(system: settings.systemAudio, microphoneConfigured: settings.microphone && microphoneOutput != nil)
        disconnectObserver = NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let self, let device = notification.object as? AVCaptureDevice else { return }
            self.queue.async {
                if device.hasMediaType(.audio) {
                    self.mixer?.finishMicrophone()
                    self.flushAudio()
                    self.onMicrophoneLost()
                    self.onNotice("麦克风已断开，录屏将继续并从断开点静音。")
                }
            }
        }
    }

    func start() async throws {
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        sourceSession?.startRunning()
        if showsClicks {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in self?.queue.async { self?.lastClick = (NSEvent.mouseLocation, Date()) } }
        }
        try await stream.startCapture()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.checkDisk() }
        timer.resume()
        diskTimer = timer
    }

    func stop() async {
        // 与回调同队列同步置位 finishing：已入队的回调先跑完（正常 append），之后的新回调因 finishing 短路。
        queue.sync { if !finishing { finishing = true } }
        try? await stream.stopCapture()
        diskTimer?.cancel()
        sourceSession?.stopRunning()
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        video.markAsFinished()
        // 在串行队列上结束两路音频源并冲刷剩余混音，避免与回调并发读写 pendingAudio/mixer。
        queue.sync {
            mixer?.finishSystem()
            mixer?.finishMicrophone()
            flushAudio()
        }
        audio?.markAsFinished()
        await writer.finishWriting()
        completion(writer.status == .completed ? .success(url) : .failure(writer.error ?? CocoaError(.fileWriteUnknown)))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { completion(.failure(error)) }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer), !finishing else { return }
        if !started {
            guard type == .screen else { return }
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            mixer?.setAnchor(sampleBuffer.presentationTimeStamp)
            started = true
        }
        if type == .screen, video.isReadyForMoreMediaData { appendVideo(sampleBuffer) }
        else if type == .audio {
            mixer?.appendSystem(sampleBuffer)
            flushAudio()
        }
    }

    /// 从混音器取出混合后的 PCM 缓冲并写入单一音频输入；输入未就绪时先暂存，待下一回调续写。
    private func flushAudio() {
        guard let audio else { return }
        if let mixer { pendingAudio.append(contentsOf: mixer.drain()) }
        while !pendingAudio.isEmpty, audio.isReadyForMoreMediaData {
            audio.append(pendingAudio.removeFirst())
        }
    }

    private func appendVideo(_ sample: CMSampleBuffer) {
        guard let source = sample.imageBuffer, let pool = videoAdaptor.pixelBufferPool else { return }
        var target: CVPixelBuffer?; guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &target) == kCVReturnSuccess, let target else { return }
        var image = CIImage(cvPixelBuffer: source)
        if let camera = cameraFeed?.latestFrame { image = composite(camera: camera, over: image) }
        if let (point, date) = lastClick, Date().timeIntervalSince(date) < 0.3, let ring = clickRing(at: point) { image = ring.composited(over: image) }
        ciContext.render(image, to: target, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: CGColorSpaceCreateDeviceRGB())
        videoAdaptor.append(target, withPresentationTime: sample.presentationTimeStamp)
    }

    private func makeSourceSession(settings: AppSettings) throws -> AVCaptureSession {
        let session = AVCaptureSession(); session.beginConfiguration(); session.sessionPreset = .medium
        if settings.microphone, let device = Self.device(mediaType: .audio, id: settings.selectedMicrophoneID) {
            try session.addInput(AVCaptureDeviceInput(device: device)); let output = AVCaptureAudioDataOutput(); output.setSampleBufferDelegate(self, queue: queue); session.addOutput(output); microphoneOutput = output
        }
        session.commitConfiguration(); return session
    }

    private static func device(mediaType: AVMediaType, id: String) -> AVCaptureDevice? { id.isEmpty ? AVCaptureDevice.default(for: mediaType) : AVCaptureDevice(uniqueID: id) }

    private func composite(camera: CIImage, over screen: CIImage) -> CIImage {
        guard let rect = CameraOverlayLayout.rect(in: CGRect(x: 0, y: 0, width: width, height: height), size: cameraSize, scale: cameraScale) else { return screen }
        let normalized = camera.transformed(by: CGAffineTransform(translationX: -camera.extent.minX, y: -camera.extent.minY))
        let oriented = cameraMirror ? normalized.transformed(by: CGAffineTransform(translationX: normalized.extent.width, y: 0).scaledBy(x: -1, y: 1)) : normalized
        let scale = max(rect.width / oriented.extent.width, rect.height / oriented.extent.height)
        let scaled = oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let positioned = scaled.transformed(by: CGAffineTransform(translationX: rect.midX - scaled.extent.midX, y: rect.midY - scaled.extent.midY)).cropped(to: rect)
        guard let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: ["inputExtent": CIVector(cgRect: rect), "inputRadius": CameraOverlayLayout.cornerRadius * cameraScale, "inputColor": CIColor.white])?.outputImage else { return positioned.composited(over: screen) }
        let clear = CIImage(color: .clear).cropped(to: rect)
        let rounded = positioned.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: mask])
        return rounded.composited(over: screen)
    }

    private func clickRing(at global: CGPoint) -> CIImage? {
        guard let point = CaptureGeometry(screenFrame: screenFrame, sourceRect: sourceRect, outputSize: CGSize(width: width, height: height)).outputPoint(for: global) else { return nil }
        let size: CGFloat = 28; let image = NSImage(size: NSSize(width: size, height: size)); image.lockFocus(); NSColor.systemRed.setStroke(); let path = NSBezierPath(ovalIn: CGRect(x: 2, y: 2, width: size - 4, height: size - 4)); path.lineWidth = 4; path.stroke(); image.unlockFocus()
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data), let cg = bitmap.cgImage else { return nil }
        return CIImage(cgImage: cg).transformed(by: .init(translationX: point.x - size / 2, y: point.y - size / 2))
    }

    private func checkDisk() {
        let bytes = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        switch DiskGuard.state(bytes: bytes) {
        case .warning where !warnedDisk: warnedDisk = true; onNotice("磁盘空间不足 1 GB，ShotX 将提前停止以保护录屏。")
        case .stop: onNotice("空间不足，录制已安全停止。正在保留可播放内容。"); Task { await stop() }
        default: break
        }
    }
}

extension ScreenRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output === microphoneOutput, started else { return }
        mixer?.appendMicrophone(sampleBuffer)
        flushAudio()
    }
}

@MainActor
private final class CameraPreviewWindowController {
    private let window: NSPanel
    private let preview: AVCaptureVideoPreviewLayer
    private let screen: NSScreen

    init(session: AVCaptureSession, screen: NSScreen, selection: CGRect, size: CameraOverlaySize, mirror: Bool) {
        self.screen = screen
        preview = AVCaptureVideoPreviewLayer(session: session)
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(frame: .zero); view.wantsLayer = true
        preview.videoGravity = .resizeAspectFill
        preview.cornerRadius = CameraOverlayLayout.cornerRadius
        preview.masksToBounds = true
        view.layer?.addSublayer(preview)
        window.contentView = view
        update(selection: selection, size: size, mirror: mirror)
    }

    /// 随选区/尺寸/镜像实时更新预览位置、形态与镜像（BRA102-05/06/07）。
    func update(selection: CGRect, size: CameraOverlaySize, mirror: Bool) {
        guard let local = CameraOverlayLayout.rect(in: CGRect(origin: .zero, size: selection.size), size: size) else { return }
        let frame = local.offsetBy(dx: screen.frame.minX + selection.minX, dy: screen.frame.minY + selection.minY)
        window.setFrame(frame, display: true)
        let content = window.contentView ?? NSView(frame: CGRect(origin: .zero, size: frame.size))
        content.frame = CGRect(origin: .zero, size: frame.size)
        preview.frame = content.bounds
        if let connection = preview.connection {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirror
        }
    }

    func show() { window.orderFrontRegardless() }
    func hide() { window.orderOut(nil) }
    func close() { window.close() }
}

@MainActor
private final class RecordingSetupWindowController: NSWindowController {
    private let screen: NSScreen
    private let geometry: RecordingSetupGeometry
    private let hosting: NSHostingView<RecordingSetupView>
    private var hintObserver: Any?

    init(model: AppModel, screen: NSScreen, geometry: RecordingSetupGeometry, onStart: @escaping () -> Void, onReturn: @escaping () -> Void, onCameraChanged: @escaping (Bool) -> Void, onCameraPermissionChanged: @escaping (PermissionState?) -> Void, onCameraSettingsChanged: @escaping () -> Void, onPermissionRequest: @escaping (PermissionKind) -> Void, onPermissionRequestFinished: @escaping () -> Void) {
        self.screen = screen
        self.geometry = geometry
        let view = RecordingSetupView(model: model, geometry: geometry, onStart: onStart, onReturn: onReturn, onCameraChanged: onCameraChanged, onCameraPermissionChanged: onCameraPermissionChanged, onCameraSettingsChanged: onCameraSettingsChanged, onPermissionRequest: onPermissionRequest, onPermissionRequestFinished: onPermissionRequestFinished)
        hosting = NSHostingView(rootView: view)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 256, height: 140), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        super.init(window: panel)
        hintObserver = geometry.$cameraHint.sink { [weak self] _ in
            Task { @MainActor in self?.resizeToFit() }
        }
        resizeToFit()
        reposition()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func resizeToFit() {
        guard let window else { return }
        let fitting = hosting.fittingSize
        let size = CGSize(width: max(256, fitting.width.rounded()), height: max(140, fitting.height.rounded()))
        window.setContentSize(size)
        reposition()
    }

    func reposition() {
        guard let window else { return }
        let selection = geometry.selection
        if selection.width >= window.frame.width, selection.height >= window.frame.height {
            window.setFrameOrigin(NSPoint(x: screen.frame.minX + selection.midX - window.frame.width / 2, y: screen.frame.minY + selection.midY - window.frame.height / 2))
            return
        }
        let below = screen.frame.minY + selection.minY - window.frame.height - 8
        let above = screen.frame.minY + selection.maxY + 8
        let y = below >= screen.visibleFrame.minY ? below : min(above, screen.visibleFrame.maxY - window.frame.height)
        let x = min(max(screen.frame.minX + selection.midX - window.frame.width / 2, screen.visibleFrame.minX), screen.visibleFrame.maxX - window.frame.width)
        window.setFrameOrigin(NSPoint(x: x, y: max(screen.visibleFrame.minY, y)))
    }
}

private struct RecordingSetupView: View {
    private enum PickDrop { case microphone, camera, mouse }

    @ObservedObject var model: AppModel
    @ObservedObject var geometry: RecordingSetupGeometry
    let onStart: () -> Void
    let onReturn: () -> Void
    let onCameraChanged: (Bool) -> Void
    let onCameraPermissionChanged: (PermissionState?) -> Void
    let onCameraSettingsChanged: () -> Void
    let onPermissionRequest: (PermissionKind) -> Void
    let onPermissionRequestFinished: () -> Void
    @FocusState private var speakerFocused: Bool
    @State private var pickDrop: PickDrop?

    var body: some View {
        ZStack(alignment: .topLeading) {
            mainMenu
            if let pickDrop {
                pickDropMenu(pickDrop)
                    .offset(x: dropOffset(for: pickDrop), y: 111)
                    .transition(.opacity)
            }
        }
        .frame(width: menuWidth, height: menuHeight, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.2), value: pickDrop)
        .onChange(of: model.settings) { model.persist(); onCameraSettingsChanged() }
        .onChange(of: model.permissions[.camera]) { _, newValue in onCameraPermissionChanged(newValue) }
        .onChange(of: model.requesting) { oldValue, newValue in
            if oldValue != nil, newValue == nil { onPermissionRequestFinished() }
        }
        .onAppear { speakerFocused = true }
    }

    private var mainMenu: some View {
        VStack(spacing: 16) {
            Button(action: onStart) {
                Image(nsImage: recordingAsset("record-start", size: NSSize(width: 208, height: 40))).resizable().frame(width: 208, height: 40)
            }
                .keyboardShortcut(.defaultAction)
                .frame(width: 208, height: 40)
                .buttonStyle(.plain)
            Rectangle().fill(Color(red: 217/255, green: 217/255, blue: 217/255).opacity(0.6)).frame(width: 208, height: 1)
            HStack(spacing: 16) {
                sourceButton("record-speaker", isOn: speakerOn, pending: false, label: "扬声器", value: speakerOn ? "已开启" : "已关闭", action: toggleSpeaker)
                    .focused($speakerFocused)
                microphoneGroup
                cameraGroup
                mouseSourceGroup
            }
            if let hint = geometry.cameraHint {
                Text(hint).font(.caption).foregroundStyle(.white.opacity(0.85)).frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .frame(width: 256)
        .background(Color(red: 51/255, green: 51/255, blue: 51/255), in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.16), radius: 4, x: 0, y: 4)
    }

    // MARK: - 状态解析（BRA-116：视觉 = 开关 + 权限 + 设备真值表，禁止用本地缓存导致漂移）

    private var speakerOn: Bool {
        RecordingSourceState.isOn(.speaker, settings: model.settings, permission: nil, deviceAvailable: RecordingDeviceAvailability.hasAudioOutputDevice())
    }
    private var microphoneOn: Bool {
        RecordingSourceState.isOn(.microphone, settings: model.settings, permission: model.permissions[.microphone], deviceAvailable: RecordingDeviceAvailability.hasMicrophoneDevice())
    }
    private var cameraOn: Bool {
        RecordingSourceState.isOn(.camera, settings: model.settings, permission: model.permissions[.camera], deviceAvailable: RecordingDeviceAvailability.hasCameraDevice())
    }
    private var mouseOn: Bool {
        RecordingSourceState.isOn(.mouse, settings: model.settings, permission: nil, deviceAvailable: true)
    }
    private var microphoneAccessibilityValue: String {
        guard model.settings.microphone else { return "已关闭" }
        let name = RecordingDeviceAvailability.defaultMicrophoneName()
        return name.isEmpty ? "已开启" : "已开启，\(name)"
    }

    // MARK: - 切换行为（失败回退 off + 提示，不出现假开启态）

    private func toggleSpeaker() {
        if model.settings.systemAudio {
            model.settings.systemAudio = false
        } else if RecordingDeviceAvailability.hasAudioOutputDevice() {
            model.settings.systemAudio = true
        } else {
            model.showError("未找到音频输出设备")
        }
    }

    private func toggleMicrophone() {
        if model.settings.microphone {
            model.setMicrophoneEnableIntent(false)
            model.settings.microphone = false
            if pickDrop == .microphone { pickDrop = nil }
            return
        }
        switch model.permissions[.microphone] {
        case .allowed:
            if RecordingDeviceAvailability.hasMicrophoneDevice() { model.settings.microphone = true }
            else { model.showError("未找到麦克风") }
        case .notDetermined:
            // BRA-116：无设备时不发起权限请求，直接提示（避免无意义弹窗与假开启态）。
            if RecordingDeviceAvailability.hasMicrophoneDevice() {
                model.setMicrophoneEnableIntent(true)
                onPermissionRequest(.microphone)
            } else { model.showError("未找到麦克风") }
        default:
            model.showError("麦克风不可用。你仍可继续无麦克风录制。")
        }
    }

    private func sourceButton(_ asset: String, isOn: Bool, pending: Bool, label: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(nsImage: recordingAsset("\(asset)-\(isOn ? "on" : "off")", size: NSSize(width: 40, height: 36))).resizable().frame(width: 40, height: 36)
                .overlay(alignment: .topTrailing) {
                    if pending { ProgressView().controlSize(.mini).offset(x: -6, y: 6) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    private var microphoneGroup: some View {
        ZStack(alignment: .topLeading) {
            sourceButton("record-microphone", isOn: microphoneOn, pending: model.requesting == .microphone, label: "麦克风", value: microphoneAccessibilityValue, action: toggleMicrophone)
            recordDrop(.microphone, enabled: microphoneOn)
        }.frame(width: 40, height: 36)
    }

    private var cameraGroup: some View {
        ZStack(alignment: .topLeading) {
            sourceButton("record-camera", isOn: cameraOn, pending: model.requesting == .camera, label: "摄像头", value: cameraOn ? "已开启" : "已关闭") {
                if model.settings.cameraEnabled, pickDrop == .camera { pickDrop = nil }
                onCameraChanged(!model.settings.cameraEnabled)
            }
            recordDrop(.camera, enabled: cameraOn)
        }.frame(width: 40, height: 36)
    }

    private var mouseSourceGroup: some View {
        ZStack(alignment: .topLeading) {
            sourceButton("record-cursor", isOn: mouseOn, pending: false, label: "鼠标设置", value: mouseOn ? "已开启" : "已关闭") {
                if mouseOn {
                    model.settings.showsCursor = false
                    model.settings.showsClicks = false
                    if pickDrop == .mouse { pickDrop = nil }
                } else {
                    model.settings.showsCursor = true
                }
            }
            recordDrop(.mouse, enabled: mouseOn)
        }.frame(width: 40, height: 36)
    }

    private func recordDrop(_ drop: PickDrop, enabled: Bool) -> some View {
        Button {
            guard enabled else { return }
            pickDrop = pickDrop == drop ? nil : drop
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color(red: 217/255, green: 217/255, blue: 217/255))
                .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
        .position(x: 39, y: 12.5)
        .accessibilityLabel("打开设置")
    }

    @ViewBuilder private func pickDropMenu(_ drop: PickDrop) -> some View {
        switch drop {
        case .microphone:
            deviceMenu(title: "选择设备", devices: microphoneDevices, selectedID: selectedMicrophoneID) { model.settings.selectedMicrophoneID = $0 }
        case .camera:
            deviceMenu(title: "选择设备", devices: cameraDevices, selectedID: selectedCameraID) { model.settings.selectedCameraID = $0 }
        case .mouse:
            VStack(alignment: .leading, spacing: 8) {
                dropTitle("鼠标设置")
                checkRow("高亮鼠标", checked: model.settings.showsCursor) { model.settings.showsCursor.toggle() }
                checkRow("增加点击效果", checked: model.settings.showsClicks) { model.settings.showsClicks.toggle() }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(width: 103)
            .dropMenuStyle()
        }
    }

    private func deviceMenu(title: String, devices: [AVCaptureDevice], selectedID: String, select: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            dropTitle(title)
            if devices.isEmpty {
                Text("未找到设备").font(Font(AppFonts.annotationFont(size: 10))).foregroundStyle(Color(red: 217/255, green: 217/255, blue: 217/255).opacity(0.4)).frame(height: 22)
            } else {
                ForEach(devices, id: \.uniqueID) { device in
                    Button { select(device.uniqueID) } label: {
                        HStack(spacing: 4) {
                            Text(device.localizedName).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "checkmark").opacity(device.uniqueID == selectedID ? 1 : 0)
                        }
                        .font(Font(AppFonts.annotationFont(size: 10)))
                        .foregroundStyle(Color(red: 217/255, green: 217/255, blue: 217/255))
                        .frame(height: 22)
                        .padding(.horizontal, 3)
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(width: 115)
        .dropMenuStyle()
    }

    private func dropTitle(_ title: String) -> some View {
        Text(title).font(Font(AppFonts.annotationFont(size: 10))).foregroundStyle(Color(red: 217/255, green: 217/255, blue: 217/255).opacity(0.3)).frame(height: 12)
    }

    private func checkRow(_ title: String, checked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: checked ? "checkmark.square" : "square").foregroundStyle(Color(red: 16/255, green: 174/255, blue: 1))
            }
            .font(Font(AppFonts.annotationFont(size: 10)))
            .foregroundStyle(Color(red: 217/255, green: 217/255, blue: 217/255))
            .frame(height: 22)
            .padding(.horizontal, 3)
        }.buttonStyle(.plain)
    }

    private var microphoneDevices: [AVCaptureDevice] { audioDevices() }
    private var cameraDevices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices
    }
    private var selectedMicrophoneID: String {
        let saved = model.settings.selectedMicrophoneID
        return microphoneDevices.contains(where: { $0.uniqueID == saved }) ? saved : (AVCaptureDevice.default(for: .audio)?.uniqueID ?? microphoneDevices.first?.uniqueID ?? "")
    }
    private var selectedCameraID: String {
        let saved = model.settings.selectedCameraID
        return cameraDevices.contains(where: { $0.uniqueID == saved }) ? saved : (AVCaptureDevice.default(for: .video)?.uniqueID ?? cameraDevices.first?.uniqueID ?? "")
    }
    private func dropOffset(for drop: PickDrop) -> CGFloat { switch drop { case .microphone: 107; case .camera: 163; case .mouse: 219 } }
    private var menuWidth: CGFloat { switch pickDrop { case .camera: 278; case .mouse: 322; default: 256 } }
    private var menuHeight: CGFloat {
        guard let pickDrop else { return 140 }
        let rows = pickDrop == .microphone ? max(1, microphoneDevices.count) : pickDrop == .camera ? max(1, cameraDevices.count) : 2
        return 111 + 26 + CGFloat(rows * 30)
    }

    private func recordingAsset(_ name: String, size: NSSize) -> NSImage {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("ShotX_ShotX.bundle")
        let bundle = packaged.flatMap(Bundle.init(url:)) ?? Bundle.module
        return (bundle.url(forResource: name, withExtension: "svg").flatMap(NSImage.init(contentsOf:)) ?? NSImage()).shotXSized(size)
    }

    private var header: some View {
        HStack {
            Text("录制设置").font(.title3.bold())
            Text("MP4").font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 3).background(.secondary.opacity(0.14), in: Capsule())
            Spacer()
        }
        .frame(height: 36)
        .padding(.horizontal, 12)
    }

    private var soundGroup: some View {
        GroupBox("声音") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("系统声音", isOn: binding(\.systemAudio, permission: .systemAudio))
                if model.settings.systemAudio { LabeledContent("输出设备", value: "当前系统输出") }
                Toggle("麦克风", isOn: binding(\.microphone, permission: .microphone))
                if model.settings.microphone {
                    Picker("麦克风", selection: plain(\.selectedMicrophoneID)) { Text("系统默认").tag(""); ForEach(audioDevices(), id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) } }
                }
            }.padding(6)
        }
    }

    private var mouseGroup: some View {
        GroupBox("鼠标") {
            HStack { Toggle("显示指针", isOn: plain(\.showsCursor)); Toggle("点击反馈", isOn: plain(\.showsClicks)) }.padding(6)
        }
    }

    private var originalSizeGroup: some View {
        GroupBox("原始尺寸") {
            Text(RecordingOutputSize.displayText(source: geometry.selection.size, scale: geometry.scale))
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        }
    }

    private var countdownGroup: some View {
        GroupBox("倒计时") {
            Picker("", selection: plain(\.countdown)) { Text("关闭").tag(0); Text("3 秒").tag(3) }
                .labelsHidden()
                .pickerStyle(.segmented)
                .padding(6)
        }
    }

    private var footer: some View {
        HStack {
            Button("返回选区", action: onReturn).keyboardShortcut(.escape)
            Spacer()
            Button("开始录制", action: onStart).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
        }
        .frame(height: 48)
        .padding(.horizontal, 12)
    }

    private func plain<T>(_ path: WritableKeyPath<AppSettings, T>) -> Binding<T> { Binding(get: { model.settings[keyPath: path] }, set: { model.settings[keyPath: path] = $0 }) }
    private func binding(_ path: WritableKeyPath<AppSettings, Bool>, permission: PermissionKind) -> Binding<Bool> {
        Binding(get: { model.settings[keyPath: path] }, set: { model.settings[keyPath: path] = $0; if $0 { model.request(permission) } })
    }
    private func audioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }
}

private extension View {
    func dropMenuStyle() -> some View {
        background(Color(red: 51/255, green: 51/255, blue: 51/255), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 87/255, green: 87/255, blue: 87/255), lineWidth: 1))
            .shadow(color: .black.opacity(0.16), radius: 4, x: 0, y: 4)
    }
}

@MainActor
private final class RecordingRegionOverlayController {
    private let screen: NSScreen
    private let selection: CGRect
    private var masks: [NSWindow] = []
    private let border: NSWindow
    private let view: RecordingRegionBorderView

    init(screen: NSScreen, selection: CGRect) {
        self.screen = screen
        self.selection = selection
        view = RecordingRegionBorderView(frame: CGRect(origin: .zero, size: selection.size))
        border = Self.window(frame: selection.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY), screen: screen, opaque: false)
        border.contentView = view
    }

    func show(state: RecordingOverlayState) {
        masks.forEach { $0.close() }
        masks = maskFrames.map { frame in
            let window = Self.window(frame: frame, screen: screen, opaque: false)
            window.backgroundColor = .black.withAlphaComponent(state.maskAlpha)
            window.orderFrontRegardless()
            return window
        }
        view.state = state
        view.needsDisplay = true
        border.orderFrontRegardless()
    }

    func hide() { masks.forEach { $0.orderOut(nil) }; border.orderOut(nil) }

    func close() { masks.forEach { $0.close() }; masks.removeAll(); border.close() }

    private var maskFrames: [CGRect] {
        let hole = selection.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY).intersection(screen.frame)
        return [
            CGRect(x: screen.frame.minX, y: hole.maxY, width: screen.frame.width, height: screen.frame.maxY - hole.maxY),
            CGRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: hole.minY - screen.frame.minY),
            CGRect(x: screen.frame.minX, y: hole.minY, width: hole.minX - screen.frame.minX, height: hole.height),
            CGRect(x: hole.maxX, y: hole.minY, width: screen.frame.maxX - hole.maxX, height: hole.height)
        ].filter { $0.width > 0 && $0.height > 0 }
    }

    private static func window(frame: CGRect, screen: NSScreen, opaque: Bool) -> NSWindow {
        let localFrame = frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let window = NSWindow(contentRect: localFrame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.isOpaque = opaque
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return window
    }
}

private final class RecordingRegionBorderView: NSView {
    var state: RecordingOverlayState = .setup
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let border = NSColor(hex: state == .recording ? "#FA5151" : "#07C160")!
        border.setStroke()
        let rect = bounds.insetBy(dx: 3, dy: 3)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8); path.lineWidth = 1; path.stroke()
        drawAccents(around: rect, color: border)
    }

    private func drawAccents(around rect: CGRect, color: NSColor) {
        color.setStroke()
        for (x, y, sx, sy) in [(rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1.0, 1.0), (rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0)] {
            let p = NSBezierPath(); p.move(to: CGPoint(x: x + 26 * sx, y: y)); p.line(to: CGPoint(x: x + 8 * sx, y: y)); p.curve(to: CGPoint(x: x, y: y + 8 * sy), controlPoint1: CGPoint(x: x + 3 * sx, y: y), controlPoint2: CGPoint(x: x, y: y + 3 * sy)); p.line(to: CGPoint(x: x, y: y + 29 * sy)); p.lineWidth = 3; p.lineCapStyle = .round; p.stroke()
        }
        for (a, b) in [(CGPoint(x: rect.midX - 11, y: rect.minY), CGPoint(x: rect.midX + 11, y: rect.minY)), (CGPoint(x: rect.midX - 11, y: rect.maxY), CGPoint(x: rect.midX + 11, y: rect.maxY)), (CGPoint(x: rect.minX, y: rect.midY - 12), CGPoint(x: rect.minX, y: rect.midY + 12)), (CGPoint(x: rect.maxX, y: rect.midY - 12), CGPoint(x: rect.maxX, y: rect.midY + 12))] { let p = NSBezierPath(); p.move(to: a); p.line(to: b); p.lineWidth = 3; p.lineCapStyle = .round; p.stroke() }
    }
}

@MainActor
private final class RecordingStatusWindowController: NSWindowController {
    private let label = NSTextField(labelWithString: "")
    private let stopButton = NSButton(title: "停止", target: nil, action: nil)
    private let stopBackground = NSImageView()
    private var timer: Timer?
    private var started = Date()
    private var onStop: () -> Void
    private let screen: NSScreen
    private let selection: CGRect

    init(screen: NSScreen, selection: CGRect, onStop: @escaping () -> Void) {
        self.onStop = onStop
        self.screen = screen
        self.selection = selection
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 72), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        super.init(window: panel)
        label.font = .monospacedDigitSystemFont(ofSize: 16, weight: .bold); label.textColor = .white
        stopButton.target = self
        stopButton.action = #selector(stopPressed)
        stopButton.isBordered = false; stopButton.font = .systemFont(ofSize: 18, weight: .bold); stopButton.wantsLayer = true; stopButton.layer?.backgroundColor = NSColor(hex: "#FA5151")?.cgColor; stopButton.layer?.cornerRadius = 12; stopButton.contentTintColor = .white
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 72)); root.wantsLayer = true; root.layer?.backgroundColor = NSColor(hex: "#333333")?.cgColor; root.layer?.cornerRadius = 12; root.addSubview(stopButton); panel.contentView = root
        let visible = screen.visibleFrame
        let x = min(max(visible.minX, screen.frame.minX + selection.midX - 120), visible.maxX - 240)
        let below = screen.frame.minY + selection.minY - 80
        let y = below >= visible.minY ? below : min(visible.maxY - 72, screen.frame.minY + selection.maxY + 8)
        panel.setFrameOrigin(CGPoint(x: x, y: y))
    }

    required init?(coder: NSCoder) { fatalError() }
    func setOnStop(_ action: @escaping () -> Void) { onStop = action }
    func showCountdown(_ value: Int) {
        guard value > 0 else { return }
        timer?.invalidate()
        let name = "record-countdown-\(value)"
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 120)); root.wantsLayer = true; root.layer?.cornerRadius = 60; root.layer?.masksToBounds = true; root.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        let number = NSImageView(image: recordingImage(name, size: NSSize(width: 40, height: 77))); number.imageScaling = .scaleProportionallyUpOrDown; number.frame = NSRect(x: 40, y: 21.5, width: 40, height: 77); root.addSubview(number)
        window?.setContentSize(NSSize(width: 120, height: 120)); window?.contentView = root
        window?.setFrameOrigin(CGPoint(x: screen.frame.minX + selection.midX - 60, y: screen.frame.minY + selection.midY - 60))
        showWindow(nil)
    }
    func showRecording(started: Date) {
        self.started = started
        makeRecordingContent()
        stopButton.title = ""
        label.stringValue = "00:00"
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    func showProcessing() { timer?.invalidate(); label.stringValue = "正在保留可播放内容…"; stopButton.isEnabled = false }
    override func close() { timer?.invalidate(); super.close() }
    @objc private func stopPressed() { onStop() }
    private func tick() {
        let seconds = Int(Date().timeIntervalSince(started))
        if seconds >= 3_600 { timer?.invalidate(); onStop(); return }
        label.stringValue = String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func makeRecordingContent() {
        window?.setContentSize(NSSize(width: 240, height: 72))
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 72)); root.wantsLayer = true; root.layer?.backgroundColor = NSColor(hex: "#333333")?.cgColor; root.layer?.cornerRadius = 12; root.layer?.masksToBounds = true
        stopBackground.image = recordingImage("record-stop", size: NSSize(width: 208, height: 40)); stopBackground.imageScaling = .scaleAxesIndependently; stopBackground.frame = NSRect(x: 16, y: 16, width: 208, height: 40); root.addSubview(stopBackground)
        stopButton.frame = stopBackground.frame; stopButton.title = ""; stopButton.layer?.backgroundColor = NSColor.clear.cgColor; root.addSubview(stopButton)
        label.frame = NSRect(x: 144, y: 26, width: 54, height: 20); label.alignment = .center; root.addSubview(label)
        window?.contentView = root
        let visible = screen.visibleFrame; let x = min(max(visible.minX, screen.frame.minX + selection.midX - 120), visible.maxX - 240); let below = screen.frame.minY + selection.minY - 80; let y = below >= visible.minY ? below : min(visible.maxY - 72, screen.frame.minY + selection.maxY + 8); window?.setFrameOrigin(CGPoint(x: x, y: y))
    }

    private func recordingImage(_ name: String, size: NSSize) -> NSImage {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("ShotX_ShotX.bundle")
        let bundle = packaged.flatMap(Bundle.init(url:)) ?? Bundle.module
        return (bundle.url(forResource: name, withExtension: "svg").flatMap(NSImage.init(contentsOf:)) ?? NSImage()).shotXSized(size)
    }
}
