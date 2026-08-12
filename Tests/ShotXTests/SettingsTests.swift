import Carbon.HIToolbox
import XCTest
@testable import ShotX

final class SettingsTests: XCTestCase {
    func testDefaultsRoundTripAndConflictRules() throws {
        let data = try JSONEncoder().encode(AppSettings.defaults)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), .defaults)

        let commandSpace = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey))
        XCTAssertTrue(HotKeyManager.isReserved(commandSpace))
        XCTAssertEqual(AppSettings.defaults.shortcut(for: .region).label, "⇧⌘4")
        XCTAssertNotEqual(AppSettings.defaults.shortcut(for: .region), AppSettings.defaults.shortcut(for: .window))
    }

    @MainActor
    func testRejectedDuplicateKeepsOldShortcut() {
        let suite = UserDefaults(suiteName: #function)!
        suite.removePersistentDomain(forName: #function)
        let model = AppModel(defaults: suite)
        let old = model.shortcut(for: .region)
        let result = model.updateShortcut(model.shortcut(for: .window), for: .region)
        XCTAssertEqual(model.shortcut(for: .region), old)
        guard case .failure(.duplicate(.window)) = result else { return XCTFail("Expected duplicate rejection") }
    }

    @MainActor
    func testRestoreDefaultsDoesNotTouchPermissionStateOrRecentResult() {
        let suite = UserDefaults(suiteName: #function)!
        suite.removePersistentDomain(forName: #function)
        let model = AppModel(defaults: suite)
        model.settings.windowShadow = false
        model.lastImage = NSImage(size: NSSize(width: 1, height: 1))
        model.restoreDefaults()
        XCTAssertEqual(model.settings, .defaults)
        XCTAssertNotNil(model.lastImage)
    }

    func testFrozenDiskAndLongCaptureThresholds() {
        XCTAssertEqual(DiskGuard.state(bytes: 2_000_000_000), .ready)
        XCTAssertEqual(DiskGuard.state(bytes: 999_999_999), .warning)
        XCTAssertEqual(DiskGuard.state(bytes: 499_999_999), .stop)
        XCTAssertTrue(LongCaptureLimits.isWarning(height: 48_000, bytes: 1))
        XCTAssertTrue(LongCaptureLimits.isMaximum(height: 60_000, bytes: 1))
        XCTAssertTrue(LongCaptureLimits.isMaximum(height: 1, bytes: 1_000_000_000))
    }

    func testAnnotationStylesPersistRoundTrip() throws {
        var settings = AppSettings.defaults
        settings.annotationColors[AnnotationTool.rectangle.rawValue] = "#00FF00"
        settings.annotationSizes[AnnotationTool.mosaic.rawValue] = 40
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.annotationColors[AnnotationTool.rectangle.rawValue], "#00FF00")
        XCTAssertEqual(decoded.annotationSizes[AnnotationTool.mosaic.rawValue], 40)
    }

    func testCaptureOverlayToolbarStaysInsideNarrowVisibleFrame() {
        XCTAssertTrue(CaptureOverlayLayout.toolbarUsesTwoLines(fixedWidth: 620, visibleWidth: 500))
        let visible = CGRect(x: 0, y: 0, width: 500, height: 300)
        let toolbar = CaptureOverlayLayout.toolbarFrame(size: CGSize(width: 546, height: 80), selection: CGRect(x: 420, y: 20, width: 60, height: 40), visibleFrame: visible)
        XCTAssertTrue(visible.insetBy(dx: 8, dy: 8).contains(toolbar))
    }

    @MainActor
    func testAccessibilityAnnouncementThrottle() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertTrue(AccessibilityAnnouncements.shouldPost(lastAnnouncementAt: nil, now: start))
        XCTAssertFalse(AccessibilityAnnouncements.shouldPost(lastAnnouncementAt: start, now: start.addingTimeInterval(0.49)))
        XCTAssertTrue(AccessibilityAnnouncements.shouldPost(lastAnnouncementAt: start, now: start.addingTimeInterval(0.5)))
        AccessibilityAnnouncements.post("样式，颜色和粗细", on: NSView())
    }

    @MainActor
    func testBrushSliderCommitsAfterMouseTrackingEnds() {
        let slider = BrushSlider(value: 2, minValue: 1, maxValue: 8, target: nil, action: nil)
        var commits = 0
        slider.onCommit = { commits += 1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 30), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(slider)
        slider.frame = NSRect(x: 0, y: 0, width: 100, height: 30)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 15), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 80, y: 15), modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        NSApp.postEvent(up, atStart: false)
        slider.mouseDown(with: down)
        XCTAssertEqual(commits, 1)
    }

    @MainActor
    func testLiveAnnotationStyleDrivesNextStrokeAndRestores() throws {
        let image = CGImage(width: 10, height: 10, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 40, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: Data(repeating: 255, count: 400) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let view = AnnotationView(image: image, settings: .defaults)
        view.tool = .pen
        view.applyStyleLive(color: .systemBlue, size: 7)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: CGPoint(x: 5, y: 5), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        view.mouseDown(with: down); view.mouseUp(with: up)
        guard case .line(_, _, _, _, let size)? = view.stateSnapshot.annotations.last else { return XCTFail("Expected stroke") }
        XCTAssertEqual(size, 7)

        var settings = AppSettings.defaults
        settings.annotationSizes[AnnotationTool.pen.rawValue] = 7
        let reopened = AnnotationView(image: image, settings: try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)))
        XCTAssertEqual(reopened.styleSize(for: .pen), 7)
    }

    func testVideoTrimFractionsRemainOrderedAndBounded() {
        XCTAssertEqual(VideoExporter.fractions(start: -1, end: 2).0, 0)
        XCTAssertEqual(VideoExporter.fractions(start: -1, end: 2).1, 1)
        let crossed = VideoExporter.fractions(start: 0.9, end: 0.1)
        XCTAssertLessThan(crossed.0, crossed.1)
        XCTAssertGreaterThanOrEqual(crossed.0, 0)
        XCTAssertLessThanOrEqual(crossed.1, 1)
    }

    func testClickCoordinatesMapIntoRecordedRegion() {
        let geometry = CaptureGeometry(screenFrame: CGRect(x: 100, y: 200, width: 1000, height: 800), sourceRect: CGRect(x: 50, y: 50, width: 400, height: 200), outputSize: CGSize(width: 800, height: 400))
        XCTAssertEqual(geometry.outputPoint(for: CGPoint(x: 350, y: 350)), CGPoint(x: 400, y: 200))
        XCTAssertNil(geometry.outputPoint(for: CGPoint(x: 120, y: 220)))
    }

    func testRecordingOutputSizeUsesPhysicalPixels() {
        XCTAssertEqual(RecordingOutputSize.pixels(source: CGSize(width: 501, height: 251), scale: 2), CGSize(width: 1002, height: 502))
        XCTAssertEqual(RecordingOutputSize.pixels(source: CGSize(width: 320, height: 240), scale: 1), CGSize(width: 320, height: 240))
        XCTAssertEqual(RecordingOutputSize.pixels(source: CGSize(width: 1000, height: 500), scale: 2), CGSize(width: 2000, height: 1000))
    }

    func testSetupOriginalSizeDisplayAlwaysMatchesVideoTrackPixels() {
        XCTAssertEqual(RecordingOutputSize.displayText(source: CGSize(width: 501, height: 251), scale: 2), "1002 × 502 px")
        XCTAssertEqual(RecordingOutputSize.displayText(source: CGSize(width: 501.8, height: 251.8), scale: 2), "1004 × 504 px")
        XCTAssertEqual(RecordingOutputSize.displayText(source: CGSize(width: 320, height: 240), scale: 1), "320 × 240 px")
        XCTAssertEqual(RecordingOutputSize.displayText(source: CGSize(width: 0, height: 0), scale: 1), "1 × 1 px")
    }

    func testRecordingOverlayStateTransitions() {
        XCTAssertEqual(RecordingOverlayState.setup.maskAlpha, 0.28)
        XCTAssertEqual(RecordingOverlayState.countdown(3).label, "录制区域")
        XCTAssertEqual(RecordingOverlayState.recording.maskAlpha, 1)
        XCTAssertEqual(RecordingOverlayState.recording.label, "● REC · 录制区域")
    }

    func testRegionCaptureOnlyCommitsFromEditing() {
        var phase = RegionCapturePhase.selecting
        phase.release(validSelection: true)
        XCTAssertEqual(phase, .editing)
        phase.commit()
        XCTAssertEqual(phase, .committed)

        phase = .selecting
        phase.release(validSelection: false)
        XCTAssertEqual(phase, .selecting)
        phase.discard()
        XCTAssertEqual(phase, .discarded)
    }

    func testRegionPixelRectMapsYUpSelectionToCGTopLeft() {
        // Screen 1000x800 points, retina 2x. Selection near the top of the screen (y-up coords).
        let sourceRect = CGRect(x: 100, y: 600, width: 300, height: 200)
        let screenPointSize = CGSize(width: 1000, height: 800)
        let pixelsPerPoint: CGFloat = 2
        let rect = AnnotationView.cgPixelRect(sourceRect: sourceRect, screenPointSize: screenPointSize, pixelsPerPoint: pixelsPerPoint)
        // y-up maxY=800 -> top of screen => pixel y = 0. Left edge x=100 -> pixel x=200.
        XCTAssertEqual(rect, CGRect(x: 200, y: 0, width: 600, height: 400))
    }

    @MainActor
    func testRegionRenderIsNotFlippedOrMirrored() {
        // 4x4 CGImage: rows R,G,B,Y (top->bottom), columns uniform. Selection = top half in y-up coords.
        var px = [UInt8]()
        let rows: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0)]
        for row in rows { for _ in 0..<4 { px.append(row.0); px.append(row.1); px.append(row.2); px.append(255) } }
        let data = Data(px)
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!

        let settings = AppSettings.defaults
        let selection = CGRect(x: 0, y: 2, width: 4, height: 2) // y-up top half -> should show R on top, G below
        let view = AnnotationView(image: image, screenPointSize: CGSize(width: 4, height: 4), sourceRect: selection, settings: settings)
        let output = view.render()
        XCTAssertNotNil(output)
        guard let rep = output?.representations.first as? NSBitmapImageRep else { return XCTFail("no bitmap rep") }
        XCTAssertEqual(rep.pixelsWide, 4)
        XCTAssertEqual(rep.pixelsHigh, 2)
        func pixelColor(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return (0, 0, 0) }
            return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        }
        // y=0 top row should be red (top of screen), y=1 green.
        let top = pixelColor(0, 0)
        XCTAssertGreaterThan(top.0, 200)
        XCTAssertLessThan(top.1, 50)
        XCTAssertLessThan(top.2, 50)
        let bottom = pixelColor(0, 1)
        XCTAssertLessThan(bottom.0, 50)
        XCTAssertGreaterThan(bottom.1, 200)
        XCTAssertLessThan(bottom.2, 50)
    }
}
