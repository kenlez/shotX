import AppKit
import ScreenCaptureKit

enum LongCaptureLimits {
    static let warningHeight = 48_000
    static let maximumHeight = 60_000
    static let warningBytes = 800_000_000
    static let maximumBytes = 1_000_000_000

    static func isWarning(height: Int, bytes: Int) -> Bool { height >= warningHeight || bytes >= warningBytes }
    static func isMaximum(height: Int, bytes: Int) -> Bool { height >= maximumHeight || bytes >= maximumBytes }
}

@MainActor
final class ScrollingCaptureCoordinator {
    static let shared = ScrollingCaptureCoordinator()
    private var session: ScrollingSession?
    private var panel: ScrollingPanelController?

    func start(display: SCDisplay, screen: NSScreen, localRect: CGRect, model: AppModel) async {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = screen.backingScaleFactor
        let source = CGRect(x: max(0, localRect.minX), y: max(0, screen.frame.height - localRect.maxY), width: localRect.width, height: localRect.height).integral
        let session = ScrollingSession(filter: filter, source: source, width: Int((source.width * scale).rounded()), height: Int((source.height * scale).rounded()))
        self.session = session
        let panel = ScrollingPanelController(
            onCapture: { [weak self] in Task { await self?.capture(model: model) } },
            onUndo: { [weak self] in self?.session?.undo(); self?.updatePanel() },
            onFinish: { [weak self] in self?.finish(model: model) },
            onCancel: { [weak self] in self?.cancel() }
        )
        self.panel = panel
        panel.show()
        await capture(model: model)
    }

    private func capture(model: AppModel) async {
        guard let session else { return }
        do {
            let outcome = try await session.capture()
            updatePanel(message: outcome)
            if session.atMaximum { updatePanel(message: "已达到长图上限，已保留当前结果") }
        } catch { updatePanel(message: "已暂停：无法读取连续内容。当前内容仍可保存") }
    }

    private func finish(model: AppModel) {
        guard let image = session?.render() else { cancel(); return }
        cancel()
        model.accept(image)
    }

    private func cancel() { panel?.close(); panel = nil; session = nil }
    private func updatePanel(message: String? = nil) { panel?.update(image: session?.render(), height: session?.height ?? 0, canUndo: (session?.count ?? 0) > 1, warning: session?.warning ?? false, maximum: session?.atMaximum ?? false, message: message) }
}

private final class ScrollingSession {
    private let filter: SCContentFilter
    private let config = SCStreamConfiguration()
    private(set) var segments: [CGImage] = []
    private var frames: [CGImage] = []
    private(set) var warning = false
    private(set) var atMaximum = false

    var count: Int { segments.count }
    var height: Int { segments.reduce(0) { $0 + $1.height } }

    init(filter: SCContentFilter, source: CGRect, width: Int, height: Int) {
        self.filter = filter
        config.sourceRect = source
        config.width = max(1, width)
        config.height = max(1, height)
        config.showsCursor = false
        config.captureResolution = .best
    }

    func capture() async throws -> String {
        guard !atMaximum else { return "已达到长图上限" }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let segment: CGImage
        if let lastFrame = frames.last {
            guard let match = Self.overlap(old: lastFrame, new: image) else { return "已暂停：无法找到连续内容" }
            if abs(match.horizontalOffset) > 8 { return "已暂停：检测到横向移动" }
            if match.overlap < image.height / 5 { return "已暂停：滚动过快，请慢一些" }
            if match.overlap >= image.height - 2 { return "未检测到滚动；请向下滚动后采集下一段" }
            guard let cropped = image.cropping(to: CGRect(x: 0, y: match.overlap, width: image.width, height: image.height - match.overlap)) else { return "已暂停：无法读取连续内容" }
            segment = cropped
        } else { segment = image }
        let newHeight = height + segment.height
        let bytes = image.width * newHeight * 4
        warning = LongCaptureLimits.isWarning(height: newHeight, bytes: bytes)
        atMaximum = LongCaptureLimits.isMaximum(height: newHeight, bytes: bytes)
        guard !atMaximum else { return "已达到长图上限，已保留当前结果" }
        segments.append(segment)
        frames.append(image)
        return warning ? "接近长图上限，建议现在结束" : "已采集一段；滚动后点“采集下一段”"
    }

    func undo() { if segments.count > 1 { segments.removeLast(); frames.removeLast() }; warning = false; atMaximum = false }

    func render() -> CGImage? {
        guard let first = segments.first else { return nil }
        let total = height
        guard let context = CGContext(data: nil, width: first.width, height: total, bitsPerComponent: 8, bytesPerRow: first.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var y = total
        for image in segments { y -= image.height; context.draw(image, in: CGRect(x: 0, y: y, width: image.width, height: image.height)) }
        return context.makeImage()
    }

    private struct Match { let overlap: Int; let horizontalOffset: Int; let score: Int }

    private static func overlap(old: CGImage, new: CGImage) -> Match? {
        guard old.width == new.width, old.height == new.height,
              let oldBytes = rgba(old), let newBytes = rgba(new) else { return nil }
        var best: Match?
        let minimum = max(1, new.height / 5)
        let maximum = max(minimum, new.height * 9 / 10)
        let overlapStep = max(1, new.height / 80)
        for overlap in stride(from: minimum, through: maximum, by: overlapStep) {
            for dx in -12...12 {
                var difference = 0
                var samples = 0
                for row in stride(from: 0, to: overlap, by: max(1, overlap / 12)) {
                    for x in stride(from: 16, to: new.width - 16, by: max(1, new.width / 20)) {
                        let shifted = x + dx
                        guard shifted >= 0, shifted < new.width else { continue }
                        let oldIndex = ((old.height - overlap + row) * old.width + x) * 4
                        let newIndex = (row * new.width + shifted) * 4
                        difference += abs(Int(oldBytes[oldIndex]) - Int(newBytes[newIndex]))
                        difference += abs(Int(oldBytes[oldIndex + 1]) - Int(newBytes[newIndex + 1]))
                        difference += abs(Int(oldBytes[oldIndex + 2]) - Int(newBytes[newIndex + 2]))
                        samples += 3
                    }
                }
                guard samples > 0 else { continue }
                let match = Match(overlap: overlap, horizontalOffset: dx, score: difference / samples)
                if best == nil || match.score < best!.score { best = match }
            }
        }
        return (best?.score ?? 256) <= 30 ? best : nil
    }

    private static func rgba(_ image: CGImage) -> [UInt8]? {
        let row = image.width * 4
        var bytes = [UInt8](repeating: 0, count: row * image.height)
        guard let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: row, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }
}

@MainActor
private final class ScrollingPanelController: NSWindowController {
    private let status = NSTextField(wrappingLabelWithString: "只选择可滚动内容。请向下滚动，避免横向移动和动画。")
    private let heightLabel = NSTextField(labelWithString: "0 px")
    private let preview = NSImageView()
    private let capture = NSButton(title: "采集下一段", target: nil, action: nil)
    private let undo = NSButton(title: "撤销最后一段", target: nil, action: nil)
    private let finish = NSButton(title: "完成并标注", target: nil, action: nil)
    private let onCapture: () -> Void
    private let onUndo: () -> Void
    private let onFinish: () -> Void
    private let onCancel: () -> Void

    init(onCapture: @escaping () -> Void, onUndo: @escaping () -> Void, onFinish: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onCapture = onCapture; self.onUndo = onUndo; self.onFinish = onFinish; self.onCancel = onCancel
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 440), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        window.title = "滚动截图"
        window.level = .floating
        super.init(window: window)
        heightLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        preview.imageScaling = .scaleProportionallyUpOrDown; preview.setContentCompressionResistancePriority(.defaultLow, for: .vertical); preview.setAccessibilityLabel("滚动截图实时预览")
        capture.target = self; capture.action = #selector(capturePressed)
        undo.target = self; undo.action = #selector(undoPressed); undo.isEnabled = false
        finish.target = self; finish.action = #selector(finishPressed)
        let buttons = NSStackView(views: [undo, NSView(), finish, capture]); buttons.orientation = .horizontal; buttons.spacing = 8
        let root = NSStackView(views: [heightLabel, preview, status, buttons]); root.orientation = .vertical; root.spacing = 12; root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        window.contentView = root
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }
    func show() { window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func update(image: CGImage?, height: Int, canUndo: Bool, warning: Bool, maximum: Bool, message: String?) {
        heightLabel.stringValue = "已保留  \(height) px"
        if let image { preview.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)) }
        undo.isEnabled = canUndo
        capture.isEnabled = !maximum
        if let message { status.stringValue = message }
        status.textColor = maximum ? .systemRed : warning ? .systemOrange : .secondaryLabelColor
    }
    override func close() { super.close() }
    @objc private func capturePressed() { onCapture() }
    @objc private func undoPressed() { onUndo() }
    @objc private func finishPressed() { onFinish() }
}

extension ScrollingPanelController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) { Task { @MainActor in onCancel() } }
}
