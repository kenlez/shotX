import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

enum LongCaptureLimits {
    static let warningHeight = 48_000
    static let maximumHeight = 60_000
    static let warningBytes = 800_000_000
    static let maximumBytes = 1_000_000_000

    static func isWarning(height: Int, bytes: Int) -> Bool { height >= warningHeight || bytes >= warningBytes }
    static func isMaximum(height: Int, bytes: Int) -> Bool { height >= maximumHeight || bytes >= maximumBytes }
}

enum ScrollingOverlapMatcher {
    struct Match: Equatable { let overlap: Int; let score: Int; let contentRange: Range<Int>; let contentRows: Range<Int> }
    private struct Pixels { let bytes: [UInt8]; let width: Int; let height: Int }

    static func overlap(old: CGImage, new: CGImage) -> Match? {
        guard old.width == new.width, old.height == new.height,
              let oldPixels = sampledRGBA(old), let newPixels = sampledRGBA(new),
              let match = overlap(oldBytes: oldPixels.bytes, newBytes: newPixels.bytes, width: oldPixels.width, height: oldPixels.height) else { return nil }
        let overlap = Int((CGFloat(match.overlap) * CGFloat(old.height) / CGFloat(oldPixels.height)).rounded())
        let lower = Int((CGFloat(match.contentRange.lowerBound) * CGFloat(old.width) / CGFloat(oldPixels.width)).rounded(.down))
        let upper = Int((CGFloat(match.contentRange.upperBound) * CGFloat(old.width) / CGFloat(oldPixels.width)).rounded(.up))
        let top = Int((CGFloat(match.contentRows.lowerBound) * CGFloat(old.height) / CGFloat(oldPixels.height)).rounded(.down))
        let bottom = Int((CGFloat(match.contentRows.upperBound) * CGFloat(old.height) / CGFloat(oldPixels.height)).rounded(.up))
        return Match(overlap: min(bottom - top, overlap), score: match.score, contentRange: max(0, lower)..<min(old.width, upper), contentRows: max(0, top)..<min(old.height, bottom))
    }

    static func overlap(oldBytes: [UInt8], newBytes: [UInt8], width: Int, height: Int) -> Match? {
        guard width > 0, height > 2, oldBytes.count == width * height * 4, newBytes.count == oldBytes.count else { return nil }
        let allColumns = Array(stride(from: min(4, width - 1), to: max(1, width - 4), by: max(1, width / 64)))
        guard !allColumns.isEmpty else { return nil }
        if samePositionScore(oldBytes, newBytes, width: width, rows: 0..<height, columns: allColumns) <= 2 {
            return Match(overlap: height, score: 0, contentRange: 0..<width, contentRows: 0..<height)
        }

        // Ignore stationary sidebars/toolbars: they otherwise dominate the match and create repeated strips.
        let activeColumns = allColumns.filter {
            samePositionScore(oldBytes, newBytes, width: width, rows: 0..<height, columns: [$0]) > 5
        }
        guard activeColumns.count >= min(4, allColumns.count) else { return nil }
        let edgeThreshold = max(24, width * 15 / 100)
        let padding = max(8, width / 32)
        let firstActive = activeColumns.first ?? 0
        let lastActive = activeColumns.last ?? (width - 1)
        let contentRange = (firstActive > edgeThreshold ? max(0, firstActive - padding) : 0)..<(width - lastActive > edgeThreshold ? min(width, lastActive + padding + 1) : width)
        let contentRows = movingRows(oldBytes, newBytes, width: width, height: height, columns: activeColumns)
        let contentHeight = contentRows.count

        // A larger jump is indistinguishable from a repeated list; capture more often instead of guessing.
        let minimum = max(1, contentHeight / 2)
        let maximum = contentHeight - 2
        let step = max(1, contentHeight / 80)
        var candidates = stride(from: minimum, through: maximum, by: step).map {
            Match(overlap: $0, score: score(oldBytes, newBytes, width: width, overlap: $0, columns: activeColumns, rows: contentRows), contentRange: contentRange, contentRows: contentRows)
        }
        guard let coarse = candidates.min(by: { $0.score < $1.score }) else { return nil }
        let lower = max(minimum, coarse.overlap - step)
        let upper = min(maximum, coarse.overlap + step)
        candidates.append(contentsOf: (lower...upper).map {
            Match(overlap: $0, score: score(oldBytes, newBytes, width: width, overlap: $0, columns: activeColumns, rows: contentRows), contentRange: contentRange, contentRows: contentRows)
        })
        guard let best = candidates.min(by: { $0.score < $1.score }), best.score <= 28 else { return nil }
        let ambiguous = candidates.contains { abs($0.overlap - best.overlap) > max(4, step) && $0.score <= best.score + 2 }
        return ambiguous ? nil : best
    }

    private static func score(_ old: [UInt8], _ new: [UInt8], width: Int, overlap: Int, columns: [Int], rows: Range<Int>) -> Int {
        var difference = 0
        var samples = 0
        for row in stride(from: 0, to: overlap, by: max(1, overlap / 64)) {
            for x in columns {
                let oldY = rows.upperBound - overlap + row, newY = rows.lowerBound + row
                let oldIndex = (oldY * width + x) * 4, newIndex = (newY * width + x) * 4
                let oldNeighbor = (min(rows.upperBound - 1, oldY + 1) * width + x) * 4
                let newNeighbor = (min(rows.upperBound - 1, newY + 1) * width + x) * 4
                let texture = (0..<3).reduce(0) { $0 + abs(Int(old[$1 + oldIndex]) - Int(old[$1 + oldNeighbor])) + abs(Int(new[$1 + newIndex]) - Int(new[$1 + newNeighbor])) }
                guard texture >= 18 else { continue }
                difference += abs(Int(old[oldIndex]) - Int(new[newIndex]))
                difference += abs(Int(old[oldIndex + 1]) - Int(new[newIndex + 1]))
                difference += abs(Int(old[oldIndex + 2]) - Int(new[newIndex + 2]))
                samples += 3
            }
        }
        return samples == 0 ? 256 : difference / samples
    }

    private static func samePositionScore(_ old: [UInt8], _ new: [UInt8], width: Int, rows: Range<Int>, columns: [Int]) -> Int {
        var difference = 0, samples = 0
        for y in stride(from: rows.lowerBound, to: rows.upperBound, by: max(1, rows.count / 64)) {
            for x in columns {
                let index = (y * width + x) * 4
                difference += (0..<3).reduce(0) { $0 + abs(Int(old[index + $1]) - Int(new[index + $1])) }
                samples += 3
            }
        }
        return samples == 0 ? 256 : difference / samples
    }

    private static func movingRows(_ old: [UInt8], _ new: [UInt8], width: Int, height: Int, columns: [Int]) -> Range<Int> {
        let limit = max(1, height / 4)
        func changed(_ y: Int) -> Bool { samePositionScore(old, new, width: width, rows: y..<(y + 1), columns: columns) > 5 }
        let top = (0..<limit).first(where: changed) ?? 0
        let bottom = stride(from: height - 1, through: height - limit, by: -1).first(where: changed).map { $0 + 1 } ?? height
        return bottom - top >= height / 2 ? top..<bottom : 0..<height
    }

    private static func sampledRGBA(_ image: CGImage) -> Pixels? {
        let scale = min(1, 900 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let row = width * 4
        var bytes = [UInt8](repeating: 0, count: row * height)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: row, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Pixels(bytes: bytes, width: width, height: height)
    }
}

@MainActor
final class ScrollingCaptureCoordinator {
    static let shared = ScrollingCaptureCoordinator()
    private var session: ScrollingSession?
    private var panel: ScrollingPanelController?
    private var scrollMonitors: [Any] = []
    private var pendingCapture: Task<Void, Never>?
    private var captureRequested = false
    private var captureRegion = CGRect.zero

    func start(display: SCDisplay, screen: NSScreen, localRect: CGRect, model: AppModel) async {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = screen.backingScaleFactor
        let source = CGRect(x: max(0, localRect.minX), y: max(0, screen.frame.height - localRect.maxY), width: localRect.width, height: localRect.height).integral
        let session = ScrollingSession(filter: filter, source: source, width: Int((source.width * scale).rounded()), height: Int((source.height * scale).rounded()))
        self.session = session
        captureRegion = localRect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        let panel = ScrollingPanelController(
            onCancel: { [weak self] in self?.cancel() },
            onPin: { [weak self] in self?.pin(model: model) },
            onSave: { [weak self] in self?.save(model: model) },
            onCopy: { [weak self] in self?.copy(model: model) }
        )
        self.panel = panel
        panel.show(screen: screen, region: captureRegion)
        await capture(model: model)
        installScrollCapture(model: model)
    }

    private func capture(model: AppModel) async {
        guard let session else { return }
        do {
            let outcome = try await session.capture()
            updatePanel(message: outcome)
            if session.atMaximum { updatePanel(message: "已达到长图上限，已保留当前结果") }
        } catch { updatePanel(message: "已暂停：无法读取连续内容。当前内容仍可保存") }
    }

    private func outputImage() -> NSImage? { session?.render().map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) } }

    private func pin(model: AppModel) {
        guard let image = outputImage() else { return }
        model.recentResult = .image(image); cancel(); PinWindowController.show(image)
    }

    private func copy(model: AppModel) {
        guard let image = outputImage() else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.writeObjects([image]) { model.recentResult = .image(image); cancel() }
        else { model.showError("无法复制长图。当前结果仍保留，请重试或保存。") }
    }

    private func save(model: AppModel) {
        guard let image = outputImage(), let data = image.pngData else { return }
        let save = NSSavePanel(); save.allowedContentTypes = [.png]; save.nameFieldStringValue = ShotXOutputName.make(extension: "png")
        if let path = model.settings.lastSaveDirectory { save.directoryURL = URL(fileURLWithPath: path) }
        model.recentResult = .image(image)
        cancel()
        NSApp.activate(ignoringOtherApps: true)
        save.level = .screenSaver
        save.begin { [weak model] response in
            guard let model, response == .OK, let url = save.url else { return }
            do { try data.write(to: url, options: .atomic); model.settings.lastSaveDirectory = url.deletingLastPathComponent().path; model.persist() }
            catch { model.showError("保存长图失败。当前结果仍保留，请重试或另存为。") }
        }
        save.orderFrontRegardless()
    }

    private func installScrollCapture(model: AppModel) {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self, self.captureRegion.contains(NSEvent.mouseLocation), abs(event.scrollingDeltaY) > 0 else { return }
            self.queueCapture(model: model)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: handler) { scrollMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { event in handler(event); return event }) { scrollMonitors.append(monitor) }
    }

    private func queueCapture(model: AppModel) {
        captureRequested = true
        guard pendingCapture == nil else { return }
        pendingCapture = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.captureRequested, !Task.isCancelled {
                self.captureRequested = false
                try? await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled else { break }
                await self.capture(model: model)
            }
            self.pendingCapture = nil
        }
    }

    private func cancel() {
        pendingCapture?.cancel(); pendingCapture = nil; captureRequested = false
        scrollMonitors.forEach(NSEvent.removeMonitor); scrollMonitors.removeAll()
        let closingPanel = panel; panel = nil
        closingPanel?.close(); session = nil
    }
    private func updatePanel(message: String? = nil) { panel?.update(image: session?.preview(), width: session?.width ?? 0, height: session?.height ?? 0, warning: session?.warning ?? false, maximum: session?.atMaximum ?? false, message: message) }
}

private final class ScrollingSession {
    private let filter: SCContentFilter
    private let config = SCStreamConfiguration()
    private(set) var segments: [CGImage] = []
    private var frames: [CGImage] = []
    private var contentRange: Range<Int>?
    private var contentRows: Range<Int>?
    private(set) var warning = false
    private(set) var atMaximum = false

    var height: Int { segments.reduce(0) { $0 + $1.height } }
    var width: Int { segments.first?.width ?? config.width }

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
            guard let match = ScrollingOverlapMatcher.overlap(old: lastFrame, new: image) else { return "已暂停：无法找到连续内容" }
            if match.overlap < match.contentRows.count / 2 { return "已暂停：滚动过快，请慢一些" }
            if match.contentRows.count - match.overlap < max(8, match.contentRows.count / 200) { return "未检测到足够滚动；继续向下滚动即可" }
            if contentRange == nil {
                contentRange = match.contentRange
                contentRows = match.contentRows
                if let first = segments.first?.cropping(to: CGRect(x: match.contentRange.lowerBound, y: match.contentRows.lowerBound, width: match.contentRange.count, height: match.contentRows.count)) { segments[0] = first }
            }
            let range = contentRange ?? 0..<image.width
            let rows = contentRows ?? 0..<image.height
            guard let cropped = image.cropping(to: CGRect(x: range.lowerBound, y: rows.lowerBound + match.overlap, width: range.count, height: rows.count - match.overlap)) else { return "已暂停：无法读取连续内容" }
            segment = cropped
        } else { segment = image }
        let newHeight = height + segment.height
        let bytes = segment.width * newHeight * 4
        warning = LongCaptureLimits.isWarning(height: newHeight, bytes: bytes)
        atMaximum = LongCaptureLimits.isMaximum(height: newHeight, bytes: bytes)
        guard !atMaximum else { return "已达到长图上限，已保留当前结果" }
        segments.append(segment)
        frames.append(image)
        return warning ? "接近长图上限，建议现在结束" : "已自动采集并拼接一段"
    }

    func render() -> CGImage? {
        guard let first = segments.first else { return nil }
        let total = height
        guard let context = CGContext(data: nil, width: first.width, height: total, bitsPerComponent: 8, bytesPerRow: first.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var y = total
        for image in segments { y -= image.height; context.draw(image, in: CGRect(x: 0, y: y, width: image.width, height: image.height)) }
        return context.makeImage()
    }

    func preview() -> CGImage? {
        guard let first = segments.first else { return nil }
        let scale = min(1, 312 / CGFloat(first.width), 520 / CGFloat(max(1, height)))
        let width = max(1, Int((CGFloat(first.width) * scale).rounded()))
        let previewHeight = max(1, Int((CGFloat(height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: previewHeight, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var consumed = 0
        for image in segments {
            let top = Int((CGFloat(consumed) * scale).rounded())
            consumed += image.height
            let bottom = Int((CGFloat(consumed) * scale).rounded())
            context.draw(image, in: CGRect(x: 0, y: previewHeight - bottom, width: width, height: max(1, bottom - top)))
        }
        return context.makeImage()
    }

}

enum ScrollingCaptureLayout {
    static let toolbarSize = NSSize(width: 172, height: 46)
    static let gap: CGFloat = 16

    static func toolbarFrame(region: CGRect, visible: CGRect) -> CGRect {
        let bounds = visible.insetBy(dx: 8, dy: 8)
        let x = min(max(bounds.minX, region.maxX - toolbarSize.width), bounds.maxX - toolbarSize.width)
        let below = region.minY - gap - toolbarSize.height
        let y = below >= bounds.minY ? below : min(bounds.maxY - toolbarSize.height, region.maxY + gap)
        return CGRect(origin: CGPoint(x: x, y: y), size: toolbarSize)
    }

    static func previewFrame(imageSize: CGSize, region: CGRect, visible: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let ratio = imageSize.width / imageSize.height
        let fixedWidth = min(312, visible.width - gap * 2)
        let availableHeight = min(520, max(1, visible.maxY - max(visible.minY, region.minY)))
        let fixedWidthHeight = fixedWidth / ratio
        let size = ratio >= 0.624 && fixedWidthHeight <= availableHeight
            ? CGSize(width: fixedWidth, height: fixedWidthHeight)
            : CGSize(width: availableHeight * ratio, height: availableHeight)
        var x = region.maxX + gap
        if x + size.width > visible.maxX { x = region.minX - gap - size.width }
        x = min(max(visible.minX, x), visible.maxX - size.width)
        let y = min(max(visible.minY, region.minY), visible.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

@MainActor
private final class ScrollingPanelController: NSWindowController {
    private let preview = NSImageView()
    private let previewRoot = NSView()
    private let dimensions = NSTextField(labelWithString: "")
    private var selectionWindow: NSPanel?
    private var previewWindow: NSPanel?
    private weak var screen: NSScreen?
    private var region = CGRect.zero
    private let onCancel: () -> Void
    private let onPin: () -> Void
    private let onSave: () -> Void
    private let onCopy: () -> Void

    init(onCancel: @escaping () -> Void, onPin: @escaping () -> Void, onSave: @escaping () -> Void, onCopy: @escaping () -> Void) {
        self.onCancel = onCancel; self.onPin = onPin; self.onSave = onSave; self.onCopy = onCopy
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: ScrollingCaptureLayout.toolbarSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .screenSaver; window.backgroundColor = .clear; window.isOpaque = false; window.hasShadow = true; window.becomesKeyOnlyIfNeeded = true; window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false; window.sharingType = .none; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: window)
        let root = NSView(frame: NSRect(origin: .zero, size: ScrollingCaptureLayout.toolbarSize)); root.wantsLayer = true; root.layer?.backgroundColor = NSColor(hex: "#333333")?.cgColor; root.layer?.cornerRadius = 12; root.layer?.masksToBounds = true
        let buttons = [iconButton("close", "取消滚动截图", #selector(cancelPressed)), iconButton("pin", "贴图", #selector(pinPressed)), iconButton("save", "保存", #selector(savePressed)), iconButton("copy", "复制", #selector(copyPressed))]
        let row = NSStackView(views: buttons); row.orientation = .horizontal; row.spacing = 16; row.frame = NSRect(x: 18, y: 12, width: 136, height: 22); root.addSubview(row); window.contentView = root

        let previewWindow = overlayWindow(frame: .zero, ignoresMouse: true); previewWindow.contentView = previewRoot; previewRoot.addSubview(preview); previewRoot.addSubview(dimensions); preview.imageScaling = .scaleProportionallyUpOrDown; preview.alphaValue = 0.4; preview.wantsLayer = true; preview.layer?.cornerRadius = 8; preview.layer?.masksToBounds = true; preview.setAccessibilityLabel("滚动截图实时预览"); dimensions.font = .monospacedSystemFont(ofSize: 11, weight: .medium); dimensions.textColor = .white; dimensions.alignment = .center; dimensions.wantsLayer = true; dimensions.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor; dimensions.layer?.cornerRadius = 6; self.previewWindow = previewWindow
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(screen: NSScreen, region: CGRect) {
        self.screen = screen; self.region = region
        let selectionWindow = overlayWindow(frame: region, ignoresMouse: true); selectionWindow.contentView = ScrollingSelectionView(frame: NSRect(origin: .zero, size: region.size)); self.selectionWindow = selectionWindow; selectionWindow.orderFrontRegardless()
        window?.setFrame(ScrollingCaptureLayout.toolbarFrame(region: region, visible: screen.visibleFrame), display: true); window?.orderFrontRegardless()
    }

    func update(image: CGImage?, width: Int, height: Int, warning: Bool, maximum: Bool, message: String?) {
        guard let image, let screen, let previewWindow else { return }
        preview.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        let frame = ScrollingCaptureLayout.previewFrame(imageSize: CGSize(width: image.width, height: image.height), region: region, visible: screen.visibleFrame)
        previewRoot.frame = NSRect(origin: .zero, size: frame.size); preview.frame = previewRoot.bounds
        dimensions.stringValue = "\(width) × \(height) px"; dimensions.sizeToFit(); dimensions.frame = NSRect(x: 8, y: max(8, frame.height - 28), width: dimensions.frame.width + 16, height: 20)
        previewWindow.setFrame(frame, display: true); previewWindow.orderFrontRegardless()
        window?.setAccessibilityValue(message ?? "已保留 \(height) px\(maximum ? "，已达到上限" : warning ? "，接近上限" : "")")
    }

    override func close() { selectionWindow?.close(); previewWindow?.close(); selectionWindow = nil; previewWindow = nil; super.close() }
    @objc private func cancelPressed() { onCancel() }
    @objc private func pinPressed() { onPin() }
    @objc private func savePressed() { onSave() }
    @objc private func copyPressed() { onCopy() }

    private func iconButton(_ asset: String, _ label: String, _ action: Selector) -> NSButton {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("ShotX_ShotX.bundle")
        let bundle = packaged.flatMap(Bundle.init(url:)) ?? Bundle.module
        let image = (bundle.url(forResource: asset, withExtension: "svg").flatMap(NSImage.init(contentsOf:)) ?? NSImage()).shotXSized(NSSize(width: 22, height: 22))
        let button = NSButton(image: image, target: self, action: action); button.isBordered = false; button.imagePosition = .imageOnly; button.frame.size = NSSize(width: 22, height: 22); button.setAccessibilityLabel(label); button.toolTip = label; return button
    }

    private func overlayWindow(frame: CGRect, ignoresMouse: Bool) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false); panel.level = .screenSaver; panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false; panel.isMovable = false; panel.isMovableByWindowBackground = false; panel.ignoresMouseEvents = ignoresMouse; panel.isReleasedWhenClosed = false; panel.sharingType = .none; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; return panel
    }
}

private final class ScrollingSelectionView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let color = NSColor(hex: "#10AEFF")!
        let rect = bounds.insetBy(dx: 2, dy: 2)
        color.setStroke(); let frame = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8); frame.lineWidth = 2; frame.stroke()
        for (x, y, sx, sy) in [(rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1.0, 1.0), (rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0)] {
            let path = NSBezierPath(); path.move(to: CGPoint(x: x + 26 * sx, y: y)); path.line(to: CGPoint(x: x + 8 * sx, y: y)); path.curve(to: CGPoint(x: x, y: y + 8 * sy), controlPoint1: CGPoint(x: x + 3 * sx, y: y), controlPoint2: CGPoint(x: x, y: y + 3 * sy)); path.line(to: CGPoint(x: x, y: y + 26 * sy)); path.lineWidth = 3; path.lineCapStyle = .round; path.stroke()
        }
        for (a, b) in [(CGPoint(x: rect.midX - 11, y: rect.minY), CGPoint(x: rect.midX + 11, y: rect.minY)), (CGPoint(x: rect.midX - 11, y: rect.maxY), CGPoint(x: rect.midX + 11, y: rect.maxY)), (CGPoint(x: rect.minX, y: rect.midY - 11), CGPoint(x: rect.minX, y: rect.midY + 11)), (CGPoint(x: rect.maxX, y: rect.midY - 11), CGPoint(x: rect.maxX, y: rect.midY + 11))] { let path = NSBezierPath(); path.move(to: a); path.line(to: b); path.lineWidth = 3; path.lineCapStyle = .round; path.stroke() }
    }
}
