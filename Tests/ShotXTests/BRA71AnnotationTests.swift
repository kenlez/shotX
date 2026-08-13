import XCTest
@testable import ShotX

final class BRA71AnnotationTests: XCTestCase {
    private func makeImage(width: Int = 200, height: Int = 120) -> CGImage {
        let bytesPerRow = width * 4
        let data = Data(repeating: 255, count: bytesPerRow * height)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func mouseEvent(_ type: NSEvent.EventType, at viewPoint: CGPoint, in view: NSView, clickCount: Int = 1) -> NSEvent {
        let windowPoint = view.convert(viewPoint, to: nil)
        return NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)!
    }

    // MARK: FR-BRA71-01 Mosaic rectangle object

    @MainActor
    func testMosaicDragCreatesRectangularObject() {
        let view = AnnotationView(image: makeImage(), settings: .defaults)
        view.tool = .mosaic
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 10, y: 10), in: view))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 60, y: 40), in: view))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 60, y: 40), in: view))
        guard case .line(.mosaic, let a, let b, _, _)? = view.stateSnapshot.annotations.first else { return XCTFail("expected mosaic rectangle") }
        XCTAssertEqual(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)), CGRect(x: 10, y: 10, width: 50, height: 30))
        XCTAssertEqual(view.stateSnapshot.annotations.count, 1)
    }

    @MainActor
    func testMosaicTinyDragIsDiscarded() {
        let view = AnnotationView(image: makeImage(), settings: .defaults)
        view.tool = .mosaic
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 10, y: 10), in: view))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 11, y: 11), in: view))
        XCTAssertTrue(view.stateSnapshot.annotations.isEmpty)
    }

    @MainActor
    func testMosaicThinStripIsKept() {
        let view = AnnotationView(image: makeImage(), settings: .defaults)
        view.tool = .mosaic
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 10, y: 10), in: view))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 13, y: 60), in: view))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 13, y: 60), in: view))
        guard case .line(.mosaic, let a, let b, _, _)? = view.stateSnapshot.annotations.first else { return XCTFail("expected thin mosaic strip preserved") }
        XCTAssertEqual(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)), CGRect(x: 10, y: 10, width: 3, height: 50))
    }

    func testMosaicStyleLabelUsesBlockSize() {
        XCTAssertEqual(AnnotationTool.mosaic.styleLabel, "块大小")
        XCTAssertEqual(AnnotationTool.mosaic.styleRange.presets, [8, 16, 24, 40])
    }

    // MARK: FR-BRA71-02 Smooth freehand path

    @MainActor
    func testPenFollowsMouseWithSmoothPath() {
        let view = AnnotationView(image: makeImage(), settings: .defaults)
        view.tool = .pen
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 10, y: 10), in: view))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 30, y: 10), in: view))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 50, y: 40), in: view))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 70, y: 10), in: view))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 70, y: 10), in: view))
        guard case .path(let points, _, let size)? = view.stateSnapshot.annotations.first else { return XCTFail("expected smooth path") }
        XCTAssertGreaterThanOrEqual(points.count, 4)
        XCTAssertEqual(size, AnnotationTool.defaultSize(for: .pen))
        XCTAssertEqual(view.stateSnapshot.annotations.count, 1)
    }

    @MainActor
    func testPenClickBecomesDot() {
        let view = AnnotationView(image: makeImage(), settings: .defaults)
        view.tool = .pen
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 10, y: 10), in: view))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 10, y: 10), in: view))
        guard case .path(let points, _, _)? = view.stateSnapshot.annotations.first else { return XCTFail("expected dot path") }
        XCTAssertEqual(points.count, 1)
    }

    func testSmoothPathUsesBezierCurvesNotStraightLines() {
        let path = AnnotationMath.smoothPath([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 10), CGPoint(x: 30, y: 0), CGPoint(x: 40, y: 10)])
        XCTAssertGreaterThan(path.elementCount, 2)
        XCTAssertEqual(path.element(at: 1), .curveTo)
    }

    // MARK: FR-BRA71-03 Object hit testing by distance

    func testPathHitTestUsesDistanceNotBoundingBox() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 100), CGPoint(x: 100, y: 100)]
        // (50, 50) lies inside the bounding box but far from the L-shaped stroke.
        XCTAssertGreaterThan(AnnotationMath.distance(toPath: CGPoint(x: 50, y: 50), points: points), 8)
        XCTAssertLessThanOrEqual(AnnotationMath.distance(toPath: CGPoint(x: 0, y: 50), points: points), 8)
        XCTAssertLessThanOrEqual(AnnotationMath.distance(toPath: CGPoint(x: 50, y: 100), points: points), 8)
    }

    @MainActor
    func testSelectedPathMovesWithDrag() {
        let view = AnnotationView(image: makeImage(), settings: .defaults)
        view.tool = .pen
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 10, y: 10), in: view))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 10, y: 60), in: view))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 10, y: 60), in: view))
        view.tool = .select
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 10, y: 30), in: view))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 20, y: 30), in: view))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 20, y: 30), in: view))
        guard case .path(let points, _, _)? = view.stateSnapshot.annotations.first else { return XCTFail("expected path") }
        XCTAssertEqual(points.first, CGPoint(x: 20, y: 10))
    }

    @MainActor
    func testClickFarFromStrokeDoesNotMoveIt() {
        let view = AnnotationView(image: makeImage(), settings: .defaults)
        view.tool = .pen
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 10, y: 10), in: view))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 10, y: 60), in: view))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 10, y: 60), in: view))
        view.tool = .select
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 45, y: 45), in: view))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 55, y: 45), in: view))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 55, y: 45), in: view))
        guard case .path(let points, _, _)? = view.stateSnapshot.annotations.first else { return XCTFail("expected path") }
        XCTAssertEqual(points.first, CGPoint(x: 10, y: 10))
    }

    // MARK: FR-BRA71-04 In-place text editing (no modal input)

    @MainActor
    func testTextCommitsInlineWithoutModalAndIsSelectable() {
        let view = AnnotationView(image: makeImage(), settings: .defaults)
        view.tool = .text
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 20, y: 20), in: view))
        guard let editor = view.subviews.compactMap({ $0 as? NSTextView }).first else { return XCTFail("expected inline text editor, no NSAlert") }
        editor.string = "注意"
        view.commitTextEditingIfActive()
        guard case .text(let text, let origin, _, let size)? = view.stateSnapshot.annotations.first else { return XCTFail("expected text annotation") }
        XCTAssertEqual(text, "注意")
        XCTAssertEqual(origin, CGPoint(x: 20, y: 20))
        XCTAssertEqual(size, AnnotationTool.defaultSize(for: .text))
    }

    @MainActor
    func testEmptyTextCommitCreatesNothingAndEmptyEditDeletes() {
        let view = AnnotationView(image: makeImage(), settings: .defaults)
        view.tool = .text
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 20, y: 20), in: view))
        guard let editor = view.subviews.compactMap({ $0 as? NSTextView }).first else { return XCTFail("expected inline text editor") }
        editor.string = ""
        view.commitTextEditingIfActive()
        XCTAssertTrue(view.stateSnapshot.annotations.isEmpty)

        view.tool = .text
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 30, y: 30), in: view))
        guard let editor2 = view.subviews.compactMap({ $0 as? NSTextView }).first else { return XCTFail("expected inline text editor") }
        editor2.string = "A"
        view.commitTextEditingIfActive()
        XCTAssertEqual(view.stateSnapshot.annotations.count, 1)
        view.tool = .select
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 30, y: 30), in: view, clickCount: 2))
        guard let editor3 = view.subviews.compactMap({ $0 as? NSTextView }).first else { return XCTFail("expected re-entered editor") }
        editor3.string = ""
        view.commitTextEditingIfActive()
        XCTAssertTrue(view.stateSnapshot.annotations.isEmpty)
    }

    @MainActor
    func testDoubleClickReentersTextEditing() {
        let view = AnnotationView(image: makeImage(), settings: .defaults)
        view.tool = .text
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 20, y: 20), in: view))
        guard let editor = view.subviews.compactMap({ $0 as? NSTextView }).first else { return XCTFail("expected inline text editor") }
        editor.string = "初稿"
        view.commitTextEditingIfActive()

        view.tool = .select
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 20, y: 20), in: view, clickCount: 2))
        guard let re = view.subviews.compactMap({ $0 as? NSTextView }).first else { return XCTFail("expected re-entered editor") }
        XCTAssertEqual(re.string, "初稿")
        re.string = "终稿"
        view.commitTextEditingIfActive()
        guard case .text(let text, _, _, _)? = view.stateSnapshot.annotations.first else { return XCTFail("expected text annotation") }
        XCTAssertEqual(text, "终稿")
    }

    @MainActor
    func testDoubleClickReentryPreservesStoredColorAndSize() {
        let view = AnnotationView(image: makeImage(), settings: .defaults)
        view.tool = .text
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 20, y: 20), in: view))
        guard let editor = view.subviews.compactMap({ $0 as? NSTextView }).first else { return XCTFail("expected inline text editor") }
        editor.string = "保持"
        view.commitTextEditingIfActive()

        view.tool = .select
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 150, y: 100), in: view))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 150, y: 100), in: view))
        view.applyStyleLive(color: .systemBlue, size: 24)

        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 20, y: 20), in: view, clickCount: 2))
        guard let re = view.subviews.compactMap({ $0 as? NSTextView }).first else { return XCTFail("expected re-entered editor") }
        XCTAssertEqual(re.string, "保持")
        XCTAssertEqual(re.textColor?.hex, "#FF3B30")
        XCTAssertEqual(re.font?.pointSize, 16)
        re.string = "保持二"
        view.commitTextEditingIfActive()
        guard case .text(_, _, let color, let size)? = view.stateSnapshot.annotations.first else { return XCTFail("expected text annotation") }
        XCTAssertEqual(color.hex, "#FF3B30")
        XCTAssertEqual(size, 16)
    }

    @MainActor
    func testTextObjectDragMovesWithoutEnteringEdit() {
        let view = AnnotationView(image: makeImage(), settings: .defaults)
        view.tool = .text
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 20, y: 20), in: view))
        guard let editor = view.subviews.compactMap({ $0 as? NSTextView }).first else { return XCTFail("expected inline text editor") }
        editor.string = "拖动我"
        view.commitTextEditingIfActive()
        view.tool = .select
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 22, y: 22), in: view))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 42, y: 32), in: view))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 42, y: 32), in: view))
        guard case .text(_, let origin, _, _)? = view.stateSnapshot.annotations.first else { return XCTFail("expected text annotation") }
        XCTAssertEqual(origin, CGPoint(x: 40, y: 30))
        XCTAssertNil(view.subviews.compactMap { $0 as? NSTextView }.first)
    }

    // MARK: FR-BRA71-06 Recording setup panel centering

    func testRecordingSetupPanelCentersOnLargeSelection() {
        let panel = CGSize(width: 300, height: 320)
        let selection = CGRect(x: 100, y: 100, width: 1600, height: 1000)
        let visible = CGRect(x: 0, y: 0, width: 2000, height: 1200)
        let frame = RecordingSetupLayout.frame(panelSize: panel, selection: selection, visibleFrame: visible)
        XCTAssertEqual(frame.midX, selection.midX)
        XCTAssertEqual(frame.midY, selection.midY)
        XCTAssertTrue(visible.contains(frame))
    }

    func testRecordingSetupPanelAvoidsTinySelectionBelow() {
        let panel = CGSize(width: 300, height: 320)
        let selection = CGRect(x: 500, y: 500, width: 240, height: 200)
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = RecordingSetupLayout.frame(panelSize: panel, selection: selection, visibleFrame: visible)
        XCTAssertFalse(frame.intersects(selection))
        XCTAssertEqual(frame.maxY, selection.minY - RecordingSetupLayout.edge)
        XCTAssertEqual(frame.midX, selection.midX)
        XCTAssertTrue(visible.contains(frame))
    }

    func testRecordingSetupPanelTallSelectionKeepsHorizontalCenter() {
        let panel = CGSize(width: 300, height: 320)
        let selection = CGRect(x: 500, y: 500, width: 200, height: 1600)
        let visible = CGRect(x: 0, y: 0, width: 2000, height: 2200)
        let frame = RecordingSetupLayout.frame(panelSize: panel, selection: selection, visibleFrame: visible)
        XCTAssertEqual(frame.midX, selection.midX)
        XCTAssertEqual(frame.maxY, selection.minY - RecordingSetupLayout.edge)
        XCTAssertFalse(frame.intersects(selection))
    }

    func testRecordingSetupPanelFallsBackInsideVisibleFrame() {
        let panel = CGSize(width: 300, height: 320)
        let visible = CGRect(x: 0, y: 0, width: 360, height: 360)
        let selection = CGRect(x: 0, y: 0, width: 360, height: 360)
        let frame = RecordingSetupLayout.frame(panelSize: panel, selection: selection, visibleFrame: visible)
        XCTAssertTrue(visible.insetBy(dx: RecordingSetupLayout.edge, dy: RecordingSetupLayout.edge).contains(frame))
    }
}
