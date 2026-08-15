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

enum CameraOverlayLayout {
    static func rect(in bounds: CGRect) -> CGRect {
        let margin = min(12, bounds.width / 10, bounds.height / 10)
        let availableWidth = max(1, bounds.width - margin * 2)
        let availableHeight = max(1, bounds.height - margin * 2)
        let width = min(240, availableWidth, availableHeight * 4 / 3, max(80, bounds.width * 0.28))
        let height = width * 3 / 4
        return CGRect(x: bounds.maxX - margin - width, y: bounds.minY + margin, width: width, height: height)
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
    private var geometry: RecordingSetupGeometry?
    private weak var selection: SelectionWindowController?
    private var countdownTask: Task<Void, Never>?
    private var escapeMonitor: Any?
    private var activationObserver: Any?
    private var menuTrackingObservers: [NSObjectProtocol] = []
    private var menuTracking = false
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
        setup = RecordingSetupWindowController(model: model, screen: pending.screen, geometry: geometry, onStart: { [weak self] in self?.beginCountdown() }, onReturn: { [weak self] in self?.returnToSelection() })
        setup?.showWindow(nil)
        setup?.window?.makeKeyAndOrderFront(nil)
    }

    private func updateSetupGeometry(_ rect: CGRect) {
        geometry?.selection = rect
        setup?.reposition()
    }

    /// Skips the settings panel and starts recording with the current selection + default settings,
    /// used by the 空格 quick-start in the recording region selection.
    func startImmediately(display: SCDisplay, screen: NSScreen, localRect: CGRect, mode: CaptureMode, model: AppModel) async {
        cancelUI()
        self.model = model
        pending = (display, screen, localRect, mode)
        overlay = RecordingRegionOverlayController(screen: screen, selection: localRect)
        overlay?.show(state: .setup)
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
        if settings.microphone && model.permissions[.microphone] != .allowed {
            settings.microphone = false
            model.showError("麦克风不可用。你仍可继续无麦克风录制。")
        }
        if settings.cameraEnabled && model.permissions[.camera] != .allowed {
            settings.cameraEnabled = false
            model.showError("摄像头不可用。你仍可继续无摄像头录制。")
        }
        let delay = settings.countdown
        let sources = [settings.systemAudio ? "系统声" : nil, settings.microphone ? "麦克风" : nil, settings.cameraEnabled ? "摄像头" : nil].compactMap { $0 }.joined(separator: "+")
        status = RecordingStatusWindowController(screen: pending.screen, selection: locked, sources: sources.isEmpty ? "静音" : sources, onStop: { [weak self] in self?.cancelCountdown() })
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
            let recorder = try ScreenRecorder(url: url, filter: filter, screenFrame: screen.frame, sourceRect: source, width: Int(output.width), height: Int(output.height), settings: settings, onNotice: { [weak model] message in
                Task { @MainActor in model?.showError(message) }
            }) { [weak self] result in
                Task { @MainActor in self?.finished(result) }
            }
            self.recorder = recorder
            if let cameraSession = recorder.cameraSession {
                cameraPreview = CameraPreviewWindowController(session: cameraSession, screen: screen, selection: localRect)
                cameraPreview?.show()
            }
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
        cameraPreview?.close()
        cameraPreview = nil
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
        cameraPreview?.close()
        cameraPreview = nil
        guard recorder == nil, let pending, let model else { return }
        if let selection {
            selection.showForSetup()
            openSetupPanel()
            installMenuTrackingObserver()
            installEscapeMonitor { [weak self] in self?.returnToSelection() }
        } else {
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
        guard pending != nil, recorder == nil, countdownTask == nil else { return }
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
        setup?.close()
        setup = nil
        status?.close()
        status = nil
        overlay?.close()
        overlay = nil
        cameraPreview?.close()
        cameraPreview = nil
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
    private let systemAudio: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput?
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
    private var cameraOutput: AVCaptureVideoDataOutput?
    private var latestCameraFrame: CIImage?
    private var disconnectObserver: NSObjectProtocol?
    private let onNotice: (String) -> Void
    private var warnedDisk = false

    var cameraSession: AVCaptureSession? { cameraOutput == nil ? nil : sourceSession }

    init(url: URL, filter: SCContentFilter, screenFrame: CGRect, sourceRect: CGRect, width: Int, height: Int, settings: AppSettings, onNotice: @escaping (String) -> Void, completion: @escaping (Result<URL, Error>) -> Void) throws {
        self.url = url
        self.completion = completion
        self.onNotice = onNotice
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
        systemAudio = settings.systemAudio ? audioInput(writer) : nil
        microphone = settings.microphone ? audioInput(writer) : nil

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
        if settings.microphone || settings.cameraEnabled { sourceSession = try makeSourceSession(settings: settings) }
        disconnectObserver = NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let self, let device = notification.object as? AVCaptureDevice else { return }
            self.queue.async {
                if device.hasMediaType(.audio) { self.onNotice("麦克风已断开，录屏将继续并从断开点静音。") }
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
        guard !finishing else { return }
        finishing = true
        try? await stream.stopCapture()
        diskTimer?.cancel()
        sourceSession?.stopRunning()
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        video.markAsFinished()
        systemAudio?.markAsFinished()
        microphone?.markAsFinished()
        await writer.finishWriting()
        completion(writer.status == .completed ? .success(url) : .failure(writer.error ?? CocoaError(.fileWriteUnknown)))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { completion(.failure(error)) }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer), !finishing else { return }
        if !started {
            guard type == .screen else { return }
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            started = true
        }
        if type == .screen, video.isReadyForMoreMediaData { appendVideo(sampleBuffer) }
        else if type == .audio, let systemAudio, systemAudio.isReadyForMoreMediaData { systemAudio.append(sampleBuffer) }
    }

    private func appendVideo(_ sample: CMSampleBuffer) {
        guard let source = sample.imageBuffer, let pool = videoAdaptor.pixelBufferPool else { return }
        var target: CVPixelBuffer?; guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &target) == kCVReturnSuccess, let target else { return }
        var image = CIImage(cvPixelBuffer: source)
        if let camera = latestCameraFrame { image = composite(camera: camera, over: image) }
        if let (point, date) = lastClick, Date().timeIntervalSince(date) < 0.3, let ring = clickRing(at: point) { image = ring.composited(over: image) }
        ciContext.render(image, to: target, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: CGColorSpaceCreateDeviceRGB())
        videoAdaptor.append(target, withPresentationTime: sample.presentationTimeStamp)
    }

    private func makeSourceSession(settings: AppSettings) throws -> AVCaptureSession {
        let session = AVCaptureSession(); session.beginConfiguration(); session.sessionPreset = .medium
        if settings.microphone, let device = Self.device(mediaType: .audio, id: settings.selectedMicrophoneID) {
            try session.addInput(AVCaptureDeviceInput(device: device)); let output = AVCaptureAudioDataOutput(); output.setSampleBufferDelegate(self, queue: queue); session.addOutput(output); microphoneOutput = output
        }
        if settings.cameraEnabled, let device = AVCaptureDevice.default(for: .video) {
            try session.addInput(AVCaptureDeviceInput(device: device))
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(self, queue: queue)
            session.addOutput(output)
            cameraOutput = output
        }
        session.commitConfiguration(); return session
    }

    private static func device(mediaType: AVMediaType, id: String) -> AVCaptureDevice? { id.isEmpty ? AVCaptureDevice.default(for: mediaType) : AVCaptureDevice(uniqueID: id) }

    private func composite(camera: CIImage, over screen: CIImage) -> CIImage {
        let rect = CameraOverlayLayout.rect(in: CGRect(x: 0, y: 0, width: width, height: height))
        let normalized = camera.transformed(by: CGAffineTransform(translationX: -camera.extent.minX, y: -camera.extent.minY))
        let mirrored = normalized.transformed(by: CGAffineTransform(translationX: normalized.extent.width, y: 0).scaledBy(x: -1, y: 1))
        let scale = max(rect.width / mirrored.extent.width, rect.height / mirrored.extent.height)
        let scaled = mirrored.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let positioned = scaled.transformed(by: CGAffineTransform(translationX: rect.midX - scaled.extent.midX, y: rect.midY - scaled.extent.midY)).cropped(to: rect)
        guard let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: ["inputExtent": CIVector(cgRect: rect), "inputRadius": 12, "inputColor": CIColor.white])?.outputImage else { return positioned.composited(over: screen) }
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

extension ScreenRecorder: AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === microphoneOutput, started, let microphone, microphone.isReadyForMoreMediaData { microphone.append(sampleBuffer) }
        else if output === cameraOutput, let pixel = sampleBuffer.imageBuffer { latestCameraFrame = CIImage(cvPixelBuffer: pixel) }
    }
}

@MainActor
private final class CameraPreviewWindowController {
    private let window: NSPanel

    init(session: AVCaptureSession, screen: NSScreen, selection: CGRect) {
        let local = CameraOverlayLayout.rect(in: CGRect(origin: .zero, size: selection.size))
        let frame = local.offsetBy(dx: screen.frame.minX + selection.minX, dy: screen.frame.minY + selection.minY)
        window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size)); view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session); preview.frame = view.bounds; preview.videoGravity = .resizeAspectFill; preview.cornerRadius = 12; preview.masksToBounds = true
        view.layer?.addSublayer(preview)
        window.contentView = view
    }

    func show() { window.orderFrontRegardless() }
    func close() { window.close() }
}

@MainActor
private final class RecordingSetupWindowController: NSWindowController {
    private let screen: NSScreen
    private let geometry: RecordingSetupGeometry

    init(model: AppModel, screen: NSScreen, geometry: RecordingSetupGeometry, onStart: @escaping () -> Void, onReturn: @escaping () -> Void) {
        self.screen = screen
        self.geometry = geometry
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
        panel.contentView = NSHostingView(rootView: RecordingSetupView(model: model, geometry: geometry, onStart: onStart, onReturn: onReturn))
        super.init(window: panel)
        reposition()
    }

    required init?(coder: NSCoder) { fatalError() }

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
    @ObservedObject var model: AppModel
    @ObservedObject var geometry: RecordingSetupGeometry
    let onStart: () -> Void
    let onReturn: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Button(action: onStart) {
                Image(nsImage: recordingAsset("record-start", size: NSSize(width: 208, height: 40))).resizable().frame(width: 208, height: 40)
            }
                .keyboardShortcut(.defaultAction)
                .frame(width: 208, height: 40)
                .buttonStyle(.plain)
            Rectangle().fill(Color.white.opacity(0.32)).frame(width: 208, height: 1)
            HStack(spacing: 16) {
                recordToggle("record-speaker", menu: false, isOn: plain(\.systemAudio))
                recordToggle("record-microphone", isOn: binding(\.microphone, permission: .microphone))
                recordToggle("record-camera", isOn: binding(\.cameraEnabled, permission: .camera))
                mouseMenu
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .frame(width: 256, height: 140)
        .background(Color(red: 51/255, green: 51/255, blue: 51/255), in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.16), radius: 4, x: 0, y: 4)
        .onChange(of: model.settings) { model.persist() }
    }

    private func recordToggle(_ asset: String, menu: Bool = true, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Image(nsImage: recordingAsset("\(asset)-\(isOn.wrappedValue ? "on" : "off")", size: NSSize(width: 40, height: 36))).resizable().frame(width: 40, height: 36)
        }.buttonStyle(.plain)
    }

    private var mouseMenu: some View {
        Menu {
            Toggle("显示鼠标指针", isOn: plain(\.showsCursor))
            Toggle("显示点击反馈", isOn: plain(\.showsClicks))
        } label: {
            Image(nsImage: recordingAsset("record-cursor-\((model.settings.showsCursor || model.settings.showsClicks) ? "on" : "off")", size: NSSize(width: 40, height: 36))).resizable().frame(width: 40, height: 36)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 40, height: 36)
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
    private let sources: String
    private var onStop: () -> Void
    private let screen: NSScreen
    private let selection: CGRect

    init(screen: NSScreen, selection: CGRect, sources: String, onStop: @escaping () -> Void) {
        self.sources = sources
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
        let stack = NSStackView(views: [stopButton, label])
        stack.orientation = .horizontal
        stack.spacing = 10; stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 72)); root.wantsLayer = true; root.layer?.backgroundColor = NSColor(hex: "#333333")?.cgColor; root.layer?.cornerRadius = 12; root.addSubview(stack); stack.frame = root.bounds; panel.contentView = root
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
        label.frame = NSRect(x: 144, y: 26, width: 54, height: 20); label.alignment = .center; root.addSubview(label); window?.contentView = root
        let visible = screen.visibleFrame; let x = min(max(visible.minX, screen.frame.minX + selection.midX - 120), visible.maxX - 240); let below = screen.frame.minY + selection.minY - 80; let y = below >= visible.minY ? below : min(visible.maxY - 72, screen.frame.minY + selection.maxY + 8); window?.setFrameOrigin(CGPoint(x: x, y: y))
    }

    private func recordingImage(_ name: String, size: NSSize) -> NSImage {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("ShotX_ShotX.bundle")
        let bundle = packaged.flatMap(Bundle.init(url:)) ?? Bundle.module
        return (bundle.url(forResource: name, withExtension: "svg").flatMap(NSImage.init(contentsOf:)) ?? NSImage()).shotXSized(size)
    }
}
