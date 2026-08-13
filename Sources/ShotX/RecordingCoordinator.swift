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

    var maskAlpha: CGFloat { self == .setup ? 0.28 : 1 }
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

/// FR-BRA71-06: anchors the recording setup panel to the selection center and follows selection
/// changes; when centering would cover every corner handle (or overflow the visible frame) the
/// panel falls back to the avoidance chain below → above → sides, then edge-clamping.
/// Coordinates are in the same space as `selection` (screen-local, y-up); `visibleFrame` is the
/// screen's visible frame in the same space.
enum RecordingSetupLayout {
    static let edge: CGFloat = 8
    static let cornerHotspot: CGFloat = 20

    static func frame(panelSize: CGSize, selection: CGRect, visibleFrame: CGRect) -> CGRect {
        func fits(_ rect: CGRect) -> Bool { visibleFrame.contains(rect) }
        func coversAllCorners(_ rect: CGRect) -> Bool {
            let half = cornerHotspot / 2
            let corners = [
                CGPoint(x: selection.minX, y: selection.minY),
                CGPoint(x: selection.maxX, y: selection.minY),
                CGPoint(x: selection.minX, y: selection.maxY),
                CGPoint(x: selection.maxX, y: selection.maxY)
            ]
            return corners.allSatisfy { rect.insetBy(dx: -half, dy: -half).contains($0) }
        }
        func clamped(_ rect: CGRect) -> CGRect {
            let x = min(max(visibleFrame.minX, rect.minX), max(visibleFrame.minX, visibleFrame.maxX - rect.width))
            let y = min(max(visibleFrame.minY, rect.minY), max(visibleFrame.minY, visibleFrame.maxY - rect.height))
            return CGRect(x: x, y: y, width: rect.width, height: rect.height)
        }
        guard panelSize.width > 0, panelSize.height > 0 else { return clamped(CGRect(origin: selection.origin, size: panelSize)) }

        let centered = CGRect(x: selection.midX - panelSize.width / 2, y: selection.midY - panelSize.height / 2, width: panelSize.width, height: panelSize.height)
        // Center only when the selection is strictly larger than the panel on both axes, the
        // centered frame fits the visible work area, and no corner handle is fully covered.
        let largeEnough = selection.width > panelSize.width && selection.height > panelSize.height
        if largeEnough, fits(centered), !coversAllCorners(centered) { return centered }

        let candidates = [
            CGRect(x: selection.midX - panelSize.width / 2, y: selection.minY - edge - panelSize.height, width: panelSize.width, height: panelSize.height),
            CGRect(x: selection.midX - panelSize.width / 2, y: selection.maxY + edge, width: panelSize.width, height: panelSize.height),
            CGRect(x: selection.maxX + edge, y: selection.midY - panelSize.height / 2, width: panelSize.width, height: panelSize.height),
            CGRect(x: selection.minX - edge - panelSize.width, y: selection.midY - panelSize.height / 2, width: panelSize.width, height: panelSize.height)
        ]
        if let fit = candidates.first(where: fits) { return fit }
        return clamped(centered)
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
        try directory().appendingPathComponent("ShotX-Recovery-\(Int(Date().timeIntervalSince1970)).mp4")
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
        setup?.reposition()
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
        let delay = settings.countdown
        let sources = [settings.systemAudio ? "系统声" : nil, settings.microphone ? "麦克风" : nil].compactMap { $0 }.joined(separator: "+")
        status = RecordingStatusWindowController(sources: sources.isEmpty ? "静音" : sources, onStop: { [weak self] in self?.cancelCountdown() })
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
        menuTrackingObservers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in self?.menuTracking = true })
        menuTrackingObservers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in self?.menuTracking = false })
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
    private var disconnectObserver: NSObjectProtocol?
    private let onNotice: (String) -> Void
    private var warnedDisk = false

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
        if settings.microphone { sourceSession = try makeSourceSession(settings: settings) }
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
        if output === microphoneOutput, started, let microphone, microphone.isReadyForMoreMediaData { microphone.append(sampleBuffer) }
    }
}

@MainActor
private final class RecordingSetupWindowController: NSWindowController {
    private let screen: NSScreen
    private let geometry: RecordingSetupGeometry

    init(model: AppModel, screen: NSScreen, geometry: RecordingSetupGeometry, onStart: @escaping () -> Void, onReturn: @escaping () -> Void) {
        self.screen = screen
        self.geometry = geometry
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 320), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: RecordingSetupView(model: model, geometry: geometry, onStart: onStart, onReturn: onReturn))
        super.init(window: panel)
        reposition()
    }

    required init?(coder: NSCoder) { fatalError() }

    func reposition() {
        guard let window else { return }
        let selection = geometry.selection
        let visible = screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let frame = RecordingSetupLayout.frame(panelSize: window.frame.size, selection: selection, visibleFrame: visible)
        window.setFrameOrigin(NSPoint(x: screen.frame.minX + frame.minX, y: screen.frame.minY + frame.minY))
    }
}

private struct RecordingSetupView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var geometry: RecordingSetupGeometry
    let onStart: () -> Void
    let onReturn: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    soundGroup
                    mouseGroup
                    originalSizeGroup
                    countdownGroup
                }
                .padding(12)
            }
            Divider()
            footer
        }
        .frame(width: 300, height: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.settings) { model.persist() }
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
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
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
        NSColor.black.setStroke()
        let outer = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)); outer.lineWidth = 3; outer.stroke()
        NSColor.white.setStroke()
        let inner = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2)); inner.lineWidth = 2; inner.stroke()
        drawCorners()
        let label = NSAttributedString(string: state.label, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.white])
        let size = label.size()
        let rect = CGRect(x: 4, y: max(4, bounds.height - size.height - 10), width: size.width + 14, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.88).setFill(); NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill(); label.draw(at: CGPoint(x: rect.minX + 7, y: rect.minY + 4))
    }

    private func drawCorners() {
        NSColor.white.setStroke()
        for (x, y, sx, sy) in [(3.0, 3.0, 1.0, 1.0), (bounds.maxX - 3, 3, -1, 1), (3, bounds.maxY - 3, 1, -1), (bounds.maxX - 3, bounds.maxY - 3, -1, -1)] {
            let path = NSBezierPath(); path.move(to: CGPoint(x: x + 16 * sx, y: y)); path.line(to: CGPoint(x: x, y: y)); path.line(to: CGPoint(x: x, y: y + 16 * sy)); path.lineWidth = 3; path.stroke()
        }
    }
}

@MainActor
private final class RecordingStatusWindowController: NSWindowController {
    private let label = NSTextField(labelWithString: "")
    private let stopButton = NSButton(title: "停止", target: nil, action: nil)
    private var timer: Timer?
    private var started = Date()
    private let sources: String
    private var onStop: () -> Void

    init(sources: String, onStop: @escaping () -> Void) {
        self.sources = sources
        self.onStop = onStop
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 48), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.backgroundColor = .windowBackgroundColor.withAlphaComponent(0.95)
        panel.isOpaque = false
        panel.hasShadow = true
        super.init(window: panel)
        label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        stopButton.target = self
        stopButton.action = #selector(stopPressed)
        let stack = NSStackView(views: [label, NSView(), stopButton])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 8)
        panel.contentView = stack
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError() }
    func setOnStop(_ action: @escaping () -> Void) { onStop = action }
    func showCountdown(_ value: Int) { label.stringValue = value > 0 ? "录制倒计时  \(value)" : "正在开始…"; stopButton.title = "取消"; showWindow(nil) }
    func showRecording(started: Date) {
        self.started = started
        stopButton.title = "停止"
        label.stringValue = "● REC  00:00  ·  \(sources)"
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    func showProcessing() { timer?.invalidate(); label.stringValue = "正在保留可播放内容…"; stopButton.isEnabled = false }
    override func close() { timer?.invalidate(); super.close() }
    @objc private func stopPressed() { onStop() }
    private func tick() { let seconds = Int(Date().timeIntervalSince(started)); label.stringValue = String(format: "● REC  %02d:%02d  ·  %@", seconds / 60, seconds % 60, sources) }
}
