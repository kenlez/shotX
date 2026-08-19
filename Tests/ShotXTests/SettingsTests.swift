import Carbon.HIToolbox
import XCTest
@testable import ShotX

final class SettingsTests: XCTestCase {
    func testDefaultsRoundTripAndConflictRules() throws {
        let data = try JSONEncoder().encode(AppSettings.defaults)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), .defaults)

        let commandSpace = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey))
        XCTAssertTrue(HotKeyManager.isReserved(commandSpace))
        XCTAssertTrue(CaptureMode.allCases.allSatisfy { AppSettings.defaults.shortcut(for: $0).isEmpty })
        XCTAssertEqual(AppSettings.defaults.shortcut(for: .region).label, "未设置")
        XCTAssertEqual(Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey)).label, "⌘A")
        XCTAssertFalse(AppSettings.defaults.cameraEnabled)
    }

    @MainActor
    func testRejectedDuplicateKeepsOldShortcut() {
        let suite = UserDefaults(suiteName: #function)!
        suite.removePersistentDomain(forName: #function)
        var settings = AppSettings.defaults
        settings.shortcuts[CaptureMode.region.rawValue] = Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | shiftKey))
        settings.shortcuts[CaptureMode.regionRecording.rawValue] = Shortcut(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey | shiftKey))
        suite.set(try! JSONEncoder().encode(settings), forKey: "settings.v1")
        let model = AppModel(defaults: suite)
        let old = model.shortcut(for: .region)
        let result = model.updateShortcut(model.shortcut(for: .regionRecording), for: .region)
        XCTAssertEqual(model.shortcut(for: .region), old)
        guard case .failure(.duplicate(.regionRecording)) = result else { return XCTFail("Expected duplicate rejection") }
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

    func testTextSizeRangeSupportsSmallAndLargeLabels() {
        XCTAssertEqual(AnnotationTool.text.styleRange.min, 6)
        XCTAssertEqual(AnnotationTool.text.styleRange.max, 96)
        XCTAssertEqual(AnnotationTool.defaultSize(for: .rectangle), 4)
        XCTAssertEqual(AnnotationTool.defaultSize(for: .mosaic), 24)
        XCTAssertEqual(AnnotationTool.defaultSize(for: .text), 32)
    }

    @MainActor
    func testChangingTextSizeKeepsItsActualCenterFixed() throws {
        let image = CGImage(width: 300, height: 160, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 1200, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: Data(repeating: 255, count: 192_000) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let view = AnnotationView(image: image, settings: .defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 160), styleMask: .borderless, backing: .buffered, defer: false); window.contentView = view
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent { NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)! }
        view.tool = .text; view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 40, y: 40))); view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 40, y: 40)))
        let field = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextField }.first); field.stringValue = "Center anchor"; field.sendAction(field.action, to: field.target)
        guard case .text(let text, let oldPoint, _, let oldSize, _)? = view.stateSnapshot.annotations.last else { return XCTFail("Expected text") }
        let oldMeasured = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: oldSize, weight: .semibold)])
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: oldPoint.x + 2, y: oldPoint.y + 2))); view.mouseUp(with: event(.leftMouseUp, CGPoint(x: oldPoint.x + 2, y: oldPoint.y + 2))); view.applyStyle(color: .systemRed, size: 64)
        guard case .text(_, let newPoint, _, let newSize, _)? = view.stateSnapshot.annotations.last else { return XCTFail("Expected resized text") }
        let newMeasured = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: newSize, weight: .semibold)])
        XCTAssertEqual(oldPoint.x + oldMeasured.width / 2, newPoint.x + newMeasured.width / 2, accuracy: 0.01)
        XCTAssertEqual(oldPoint.y + oldMeasured.height / 2, newPoint.y + newMeasured.height / 2, accuracy: 0.01)
    }

    func testScrollingCaptureLayoutMatchesFigmaRules() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900), region = CGRect(x: 100, y: 300, width: 304, height: 164)
        let toolbar = ScrollingCaptureLayout.toolbarFrame(region: region, visible: visible)
        XCTAssertEqual(toolbar.maxX, region.maxX); XCTAssertEqual(region.minY - toolbar.maxY, 16)
        XCTAssertGreaterThan(CaptureOverlayLayout.optionsPanelLevel.rawValue, NSWindow.Level.screenSaver.rawValue)
        let normal = ScrollingCaptureLayout.previewFrame(imageSize: CGSize(width: 624, height: 1000), region: region, visible: visible)
        XCTAssertEqual(normal.size, CGSize(width: 312, height: 500))
        let tall = ScrollingCaptureLayout.previewFrame(imageSize: CGSize(width: 250, height: 1000), region: region, visible: visible)
        XCTAssertEqual(tall.height, 520); XCTAssertEqual(tall.width, 130)
    }

    func testScrollingOverlapIgnoresStationarySidebar() {
        let width = 100, height = 120, scroll = 27
        func frame(offset: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0..<height { for x in 0..<width {
                let value = x < 32 ? (x * 7 + y * 3) % 256 : (x * 11 + (y + offset) * 17 + (y + offset) * (y + offset)) % 256
                let index = (y * width + x) * 4
                bytes[index] = UInt8(value); bytes[index + 1] = UInt8((value * 3) % 256); bytes[index + 2] = UInt8((value * 5) % 256); bytes[index + 3] = 255
            } }
            return bytes
        }
        let old = frame(offset: 0), new = frame(offset: scroll)
        let match = ScrollingOverlapMatcher.overlap(oldBytes: old, newBytes: new, width: width, height: height)
        XCTAssertEqual(match?.overlap, height - scroll)
        XCTAssertGreaterThan(match?.contentRange.lowerBound ?? 0, 0)
        XCTAssertEqual(ScrollingOverlapMatcher.overlap(oldBytes: old, newBytes: old, width: width, height: height)?.overlap, height)
    }

    func testScrollingOverlapExcludesFixedHeaderAndFooter() {
        let width = 96, height = 120, header = 14, footer = 12, scroll = 24
        func frame(offset: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height { for x in 0..<width {
                let value: Int
                if y < header || y >= height - footer { value = (x * 9 + y * 3) % 256 }
                else { let sourceY = y - header + offset; value = (x * 13 + sourceY * 17 + sourceY * sourceY) % 256 }
                let i = (y * width + x) * 4; bytes[i] = UInt8(value); bytes[i + 1] = UInt8((value * 3) % 256); bytes[i + 2] = UInt8((value * 5) % 256); bytes[i + 3] = 255
            } }
            return bytes
        }
        let match = ScrollingOverlapMatcher.overlap(oldBytes: frame(offset: 0), newBytes: frame(offset: scroll), width: width, height: height)
        XCTAssertEqual(match?.contentRows, header..<(height - footer))
        XCTAssertEqual(match?.overlap, height - header - footer - scroll)
    }

    @MainActor
    func testLineEndpointsCanBeDraggedIndependently() {
        let image = CGImage(width: 120, height: 80, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 480, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: Data(repeating: 255, count: 38_400) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let view = AnnotationView(image: image, settings: .defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), styleMask: .borderless, backing: .buffered, defer: false); window.contentView = view
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent { NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)! }
        view.tool = .line
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 20, y: 20))); view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 80, y: 60))); view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 80, y: 60)))
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 20, y: 20))); view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 32, y: 30))); view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 32, y: 30)))
        guard case .line(.line, let start, let end, _, _)? = view.stateSnapshot.annotations.last else { return XCTFail("Expected line") }
        XCTAssertEqual(start, CGPoint(x: 32, y: 50)); XCTAssertEqual(end, CGPoint(x: 80, y: 20))
    }

    @MainActor
    func testDropoverFollowsStyledToolsAndSurvivesDrawing() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let pixels = Data(repeating: 240, count: 640 * 480 * 4)
        let image = CGImage(width: 640, height: 480, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 640 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: pixels as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let selection = CGRect(x: screen.frame.width / 2 - 240, y: screen.frame.height / 2 - 160, width: 480, height: 320)
        let model = AppModel(defaults: UserDefaults(suiteName: #function)!)
        let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), mode: .region, screen: screen, windows: [], frozenImage: image, model: model, initialSelection: selection)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: screen.frame.size), styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.contentView = view; window.makeKeyAndOrderFront(nil); view.beginPresetEditing()
        defer { NSApp.windows.filter { $0.level == CaptureOverlayLayout.optionsPanelLevel }.forEach { $0.close() }; window.close() }
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        func descendants(_ root: NSView) -> [NSView] { root.subviews + root.subviews.flatMap(descendants) }
        func button(_ label: String) throws -> NSButton { try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first { $0.toolTip == label }) }
        let rectangleButton = try button("矩形"), arrowButton = try button("箭头")
        rectangleButton.performClick(nil)
        let panel = try XCTUnwrap(NSApp.windows.first { !existingWindows.contains(ObjectIdentifier($0)) && $0.level == CaptureOverlayLayout.optionsPanelLevel && $0.frame.height == 72 })
        let rectangleX = panel.frame.minX
        arrowButton.performClick(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        let rectangleScreen = window.convertToScreen(rectangleButton.convert(rectangleButton.bounds, to: nil))
        let arrowScreen = window.convertToScreen(arrowButton.convert(arrowButton.bounds, to: nil))
        XCTAssertNotEqual(panel.frame.minX, rectangleX, "rectangle=\(rectangleButton.frame)/\(rectangleScreen), arrow=\(arrowButton.frame)/\(arrowScreen), panel=\(panel.frame)")
        let editor = try XCTUnwrap(descendants(view).compactMap { $0 as? AnnotationView }.first)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: editor.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        editor.mouseDown(with: event(.leftMouseDown, CGPoint(x: 40, y: 40))); editor.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 160, y: 100))); editor.mouseUp(with: event(.leftMouseUp, CGPoint(x: 160, y: 100)))
        XCTAssertTrue(panel.isVisible)
        try button("移动").performClick(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor
    func testMosaicIsStoredAsMovableRectangle() {
        let image = CGImage(width: 32, height: 32, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: Data(repeating: 255, count: 4096) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let view = AnnotationView(image: image, settings: .defaults)
        view.tool = .mosaic
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 4, y: 4), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: CGPoint(x: 24, y: 18), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: CGPoint(x: 24, y: 18), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        view.mouseDown(with: down); view.mouseDragged(with: drag); view.mouseUp(with: up)
        guard case .line(.mosaic, let start, let end, _, _)? = view.stateSnapshot.annotations.last else { return XCTFail("Expected rectangular mosaic") }
        XCTAssertEqual(abs(end.x - start.x), 20)
        XCTAssertEqual(abs(end.y - start.y), 14)
    }

    @MainActor
    func testNewlyDrawnAnnotationIsAutoSelectedSoStyleAppliesImmediately() {
        let image = CGImage(width: 40, height: 40, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 160, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: Data(repeating: 255, count: 6_400) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let view = AnnotationView(image: image, settings: .defaults)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent { NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)! }
        for tool in [AnnotationTool.mosaic, .pen, .arrow] {
            view.tool = tool
            view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 4, y: 4)))
            view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 24, y: 18)))
            view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 24, y: 18)))
            view.applyStyleLive(color: .systemBlue, size: 5)
            guard let last = view.stateSnapshot.annotations.last else { return XCTFail("Expected a drawn \(tool.rawValue) annotation") }
            switch last {
            case .path(_, _, let width): XCTAssertEqual(width, 5, "\(tool.rawValue) should be auto-selected so size applies")
            case .line(_, _, _, _, let width): XCTAssertEqual(width, 5, "\(tool.rawValue) should be auto-selected so size applies")
            case .text: XCTFail("Unexpected text annotation for \(tool.rawValue)")
            }
        }
    }

    @MainActor
    func testClickingExistingShapeWithAnotherToolDoesNotCreateAnotherShape() {
        let image = CGImage(width: 40, height: 40, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 160, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: Data(repeating: 255, count: 6_400) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let view = AnnotationView(image: image, settings: .defaults)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent { NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)! }
        view.tool = .rectangle
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 5, y: 5)))
        view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 30, y: 30)))
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 30, y: 30)))
        view.tool = .arrow
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 5, y: 5)))
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 5, y: 5)))
        XCTAssertEqual(view.stateSnapshot.annotations.count, 1)
    }

    @MainActor
    func testDoubleClickExistingTextEditsInsteadOfCompletingScreenshot() {
        let image = CGImage(width: 120, height: 80, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 480, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: Data(repeating: 255, count: 38_400) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let view = AnnotationView(image: image, settings: .defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.tool = .text
        let point = CGPoint(x: 12, y: 60)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        view.mouseDown(with: down); view.mouseUp(with: up)
        let field = try! XCTUnwrap(view.subviews.compactMap { $0 as? NSTextField }.first)
        field.stringValue = "Edit me"; field.sendAction(field.action, to: field.target)
        var completed = false; view.onDoubleClick = { completed = true }
        let double = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 1)!
        view.mouseDown(with: double)
        XCTAssertTrue(view.isEditingText)
        XCTAssertFalse(completed)
    }

    @MainActor
    func testUpdatedScreenshotToolsAndTextStatesStayComplete() {
        XCTAssertEqual(AnnotationTool.allCases, [.move, .rectangle, .ellipse, .line, .arrow, .pen, .mosaic, .text, .crop])
        XCTAssertEqual(AnnotationTextStyle.allCases.count, 4)
        XCTAssertFalse(AnnotationTool.styledCases.contains(.move))
    }

    @MainActor
    func testCaptureOverlayRoutesMouseToExternalScreenFrames() {
        let frames = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: -1920, y: -120, width: 1920, height: 1080)]
        XCTAssertEqual(CaptureCoordinator.overlayIndex(at: CGPoint(x: -900, y: 300), frames: frames), 1)
        XCTAssertEqual(CaptureCoordinator.overlayIndex(at: CGPoint(x: 700, y: 300), frames: frames), 0)
    }

    func testExternalWindowFrameMapsIntoThatScreensLocalCoordinates() {
        let screen = CGRect(x: -1920, y: -120, width: 1920, height: 1080)
        let cgWindow = CGRect(x: -1700, y: 180, width: 800, height: 500)
        XCTAssertEqual(CaptureCoordinator.localRect(windowFrame: cgWindow, screenFrame: screen, primaryHeight: 900), CGRect(x: 220, y: 340, width: 800, height: 500))
    }

    func testCameraOverlayStaysInsideRecordedRegion() {
        let bounds = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let camera = CameraOverlayLayout.rect(in: bounds, size: .large, scale: 1)
        XCTAssertNotNil(camera)
        XCTAssertTrue(bounds.contains(camera!))
        XCTAssertEqual(camera!.width, camera!.height)
        XCTAssertEqual(camera!.minX, bounds.minX + 12)
        XCTAssertEqual(camera!.minY, bounds.minY + 12)
    }

    func testCameraOverlayTwoSizesPresetsAndClamping() {
        XCTAssertEqual(CameraOverlaySize.small.side, 96)
        XCTAssertEqual(CameraOverlaySize.large.side, 192)
        let large = CameraOverlayLayout.rect(in: CGRect(x: 0, y: 0, width: 1280, height: 720), size: .large)
        XCTAssertEqual(large?.size, CGSize(width: 192, height: 192))
        let clamped = CameraOverlayLayout.rect(in: CGRect(x: 0, y: 0, width: 200, height: 200), size: .large)
        XCTAssertEqual(clamped?.size, CGSize(width: 176, height: 176))
        XCTAssertEqual(clamped?.minX, 12)
        XCTAssertEqual(clamped?.minY, 12)
        XCTAssertNil(CameraOverlayLayout.rect(in: CGRect(x: 0, y: 0, width: 80, height: 80), size: .small))
        XCTAssertEqual(CameraOverlayLayout.rect(in: CGRect(x: 0, y: 0, width: 100, height: 100), size: .large)?.size, CGSize(width: 76, height: 76))
    }

    func testCameraOverlayPreviewAndOutputShareLayoutAtScale() throws {
        let points = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let pixels = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let preview = try XCTUnwrap(CameraOverlayLayout.rect(in: points, size: .large, scale: 1))
        let output = try XCTUnwrap(CameraOverlayLayout.rect(in: pixels, size: .large, scale: 2))
        XCTAssertEqual(preview.origin.x, output.origin.x / 2)
        XCTAssertEqual(preview.origin.y, output.origin.y / 2)
        XCTAssertEqual(preview.size.width, output.size.width / 2)
        XCTAssertEqual(preview.size.height, output.size.height / 2)
    }

    func testCameraSettingsDefaultsAndRoundTrip() throws {
        XCTAssertEqual(AppSettings.defaults.cameraSize, .large)
        XCTAssertTrue(AppSettings.defaults.cameraMirror)
        XCTAssertFalse(AppSettings.defaults.cameraBackgroundBlur)
        var settings = AppSettings.defaults
        settings.cameraSize = .small
        settings.cameraMirror = false
        settings.cameraBackgroundBlur = true
        settings.selectedCameraID = "camera-2"
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.cameraSize, .small)
        XCTAssertFalse(decoded.cameraMirror)
        XCTAssertTrue(decoded.cameraBackgroundBlur)
        XCTAssertEqual(decoded.selectedCameraID, "camera-2")
    }

    func testCameraSettingsFallbackWhenDecodingPreCameraBuilds() throws {
        let encoded = try JSONEncoder().encode(AppSettings.defaults)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var legacy = object
        legacy.removeValue(forKey: "cameraSizeValue")
        legacy.removeValue(forKey: "cameraMirrorValue")
        legacy.removeValue(forKey: "cameraBackgroundBlurValue")
        legacy.removeValue(forKey: "selectedCameraIDValue")
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.cameraSize, .large)
        XCTAssertTrue(decoded.cameraMirror)
        XCTAssertFalse(decoded.cameraBackgroundBlur)
        XCTAssertEqual(decoded.selectedCameraID, "")
    }

    func testOutputFilenameUsesRequestedStablePrefixAndTimestampShape() {
        XCTAssertNotNil(ShotXOutputName.make(extension: "png").range(of: #"^ShotX_\d{2}-\d{2}-\d{2}:\d{2}:\d{2}\.png$"#, options: .regularExpression))
    }

    func testCaptureOverlayToolbarStaysInsideNarrowVisibleFrame() {
        XCTAssertTrue(CaptureOverlayLayout.toolbarUsesTwoLines(fixedWidth: 620, visibleWidth: 500))
        let visible = CGRect(x: 0, y: 0, width: 500, height: 300)
        let toolbar = CaptureOverlayLayout.toolbarFrame(size: CGSize(width: 546, height: 80), selection: CGRect(x: 420, y: 20, width: 60, height: 40), visibleFrame: visible)
        XCTAssertTrue(visible.insetBy(dx: 8, dy: 8).contains(toolbar))
    }

    func testCaptureOverlayOptionsPanelStaysInsideVeryNarrowVisibleFrame() {
        let veryNarrowVisible = CGRect(x: 0, y: 0, width: 315, height: 300)
        let veryNarrowFrame = CaptureOverlayLayout.optionsPanelFrame(contentHeight: 480, visibleFrame: veryNarrowVisible, toolbarFrame: CGRect(x: 270, y: 100, width: 40, height: 40))
        XCTAssertEqual(veryNarrowFrame.width, 299)
        XCTAssertTrue(veryNarrowVisible.insetBy(dx: 8, dy: 8).contains(veryNarrowFrame))
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
        guard case .path(_, _, let size)? = view.stateSnapshot.annotations.last else { return XCTFail("Expected stroke") }
        XCTAssertEqual(size, 7)

        var settings = AppSettings.defaults
        settings.annotationSizes[AnnotationTool.pen.rawValue] = 7
        let reopened = AnnotationView(image: image, settings: try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)))
        XCTAssertEqual(reopened.styleSize(for: .pen), 7)
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
        XCTAssertEqual(RecordingOverlayState.recording.maskAlpha, 0.45)
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

    @MainActor
    func testUnifiedScreenshotClickSelectsFullScreenWhileDragStillSelectsRegion() {
        let screen = NSScreen.main!
        let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), mode: .region, screen: screen, windows: [])
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false); window.contentView = view
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 20, y: 20)))
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 20, y: 20)))
        XCTAssertEqual(view.selectionRect, view.bounds)

        let dragged = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), mode: .region, screen: screen, windows: [])
        window.contentView = dragged
        dragged.mouseDown(with: event(.leftMouseDown, CGPoint(x: 20, y: 20)))
        dragged.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 120, y: 80)))
        dragged.mouseUp(with: event(.leftMouseUp, CGPoint(x: 120, y: 80)))
        XCTAssertEqual(dragged.selectionRect, CGRect(x: 20, y: 20, width: 100, height: 60))
    }

    @MainActor
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
