import XCTest
import AppKit
@testable import ShotX

@MainActor
final class QAPinWindowFunctionalTests: XCTestCase {

    private func makeWindow(imageSize: NSSize) -> (controller: PinWindowController, window: NSPanel) {
        let image = NSImage(size: imageSize)
        let controller = PinWindowController(image: image)
        return (controller, controller.window as! NSPanel)
    }

    private func imageView(of controller: PinWindowController) -> PinImageView {
        guard let content = controller.window?.contentView,
              let found = content.subviews.compactMap({ $0 as? PinImageView }).first
        else { fatalError("no PinImageView in content view") }
        return found
    }

    private func button(named title: String, in content: NSView) -> NSButton? {
        for sub in content.subviews {
            if let b = sub as? NSButton, b.title == title { return b }
            if let found = button(named: title, in: sub) { return found }
        }
        return nil
    }

    private func zoomLabel(in content: NSView) -> NSTextField? {
        for sub in content.subviews {
            if let t = sub as? NSTextField, t.accessibilityLabel() == "缩放比例" { return t }
            if let found = zoomLabel(in: sub) { return found }
        }
        return nil
    }

    private func fireScroll(_ view: PinImageView, deltaY: CGFloat, precise: Bool) {
        view.onScrollZoom?(deltaY, precise)
    }

    /// Observed scale, derived from window width (image area = width - 2*insets).
    private func observedScale(of controller: PinWindowController, imageWidth: CGFloat) -> CGFloat {
        let w = controller.window!.frame.width
        return (w - 16) / imageWidth
    }

    // ── Acceptance point 1: wheel zoom + window sync resize, 10%–400% clamp ──
    func testZoomInResizesWindowAndImageViewProportionally() throws {
        let (controller, window) = makeWindow(imageSize: NSSize(width: 200, height: 100))
        let iv = imageView(of: controller)
        let initialW = window.frame.width

        fireScroll(iv, deltaY: 5, precise: false)

        let afterW = window.frame.width
        XCTAssertGreaterThan(afterW, initialW, "zoom in must grow window width")

        // The image view itself must keep the source image aspect ratio (2:1)
        let ivFrame = iv.frame
        XCTAssertEqual(ivFrame.width / ivFrame.height, 2.0, accuracy: 0.02,
                       "image view must scale proportionally with source aspect")

        // Zoom label must match the math-based scale (1.1^5 → 161%)
        let expectedScale = PinZoom.clamp(1 * PinZoom.zoomFactor(deltaY: 5, precise: false))
        let label = zoomLabel(in: window.contentView!)?.stringValue ?? "?"
        XCTAssertEqual(label, "\(Int((expectedScale * 100).rounded()))%", "zoom label must track scale")
    }

    func testZoomOutShrinksWindowAndClampsTo10Percent() throws {
        let (controller, window) = makeWindow(imageSize: NSSize(width: 200, height: 100))
        let iv = imageView(of: controller)

        for _ in 0..<50 { fireScroll(iv, deltaY: -10, precise: false) }

        let scale = observedScale(of: controller, imageWidth: 200)
        XCTAssertEqual(scale, 0.1, accuracy: 0.001, "scale must clamp at 10%")
        XCTAssertEqual(window.frame.width, 200 * 0.1 + 16, accuracy: 0.1, "window width must equal image at 10% + chrome")
    }

    func testZoomInClampsTo400Percent() throws {
        let (controller, window) = makeWindow(imageSize: NSSize(width: 200, height: 100))
        let iv = imageView(of: controller)

        for _ in 0..<50 { fireScroll(iv, deltaY: 10, precise: false) }

        let scale = observedScale(of: controller, imageWidth: 200)
        XCTAssertEqual(scale, 4.0, accuracy: 0.001, "scale must clamp at 400%")
        XCTAssertEqual(window.frame.width, 200 * 4.0 + 16, accuracy: 0.1, "window width must equal image at 400% + chrome")
    }

    func testZoomKeepsWindowCenteredAnchoredWithinSubPixel() throws {
        let (controller, window) = makeWindow(imageSize: NSSize(width: 200, height: 100))
        let iv = imageView(of: controller)
        let beforeMidX = window.frame.midX
        let beforeMidY = window.frame.midY

        fireScroll(iv, deltaY: 3, precise: false)

        // Sub-pixel rounding by AppKit's frame constraints is acceptable (<=1pt)
        XCTAssertEqual(window.frame.midX, beforeMidX, accuracy: 1.0, "zoom must keep window center X")
        XCTAssertEqual(window.frame.midY, beforeMidY, accuracy: 1.0, "zoom must keep window center Y")
    }

    func testTrackpadPreciseDeltasZoomSlowerButSameDirection() throws {
        let (controller, window) = makeWindow(imageSize: NSSize(width: 200, height: 100))
        let iv = imageView(of: controller)
        let initial = window.frame.width

        fireScroll(iv, deltaY: 5, precise: true)
        let preciseGain = window.frame.width - initial

        XCTAssertGreaterThan(window.frame.width, initial, "trackpad scroll up must zoom in")
        XCTAssertLessThan(preciseGain, 40, "trackpad precise delta should zoom less per unit than mouse wheel")
    }

    // ── Acceptance point 2: drag non-control area moves window ──
    func testDragOnImageMovesWindowByDelta() throws {
        let (controller, window) = makeWindow(imageSize: NSSize(width: 400, height: 300))
        let iv = imageView(of: controller)
        let origin = window.frame.origin

        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: 100), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 150, y: 130), modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 150, y: 130), modifierFlags: [], timestamp: 2, windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 0)!

        iv.mouseDown(with: down)
        iv.mouseDragged(with: drag)
        iv.mouseUp(with: up)

        XCTAssertEqual(window.frame.origin.x, origin.x + 50, accuracy: 0.01, "window must move +50 X")
        XCTAssertEqual(window.frame.origin.y, origin.y + 30, accuracy: 0.01, "window must move +30 Y")
    }

    // ── Acceptance point 3: 关闭并复制 writes clipboard then closes; 关闭 keeps ──
    func testCloseAndCopyWritesClipboardAndCloses() throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = NSImage(size: NSSize(width: 40, height: 30))
        image.addRepresentation(rep)
        let controller = PinWindowController(image: image)
        guard let content = controller.window?.contentView,
              let closeCopy = button(named: "关闭并复制", in: content)
        else { return XCTFail("关闭并复制 button missing") }

        NSPasteboard.general.clearContents()
        closeCopy.performClick(nil)

        let pbImage = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage
        XCTAssertNotNil(pbImage, "关闭并复制 must write image to clipboard before closing")
        XCTAssertFalse(controller.window?.isVisible ?? false, "window must close after clipboard write")
    }

    func testCloseDoesNotTouchClipboard() throws {
        let controller = PinWindowController(image: NSImage(size: NSSize(width: 40, height: 30)))
        guard let content = controller.window?.contentView,
              let closeButton = button(named: "关闭", in: content)
        else { return XCTFail("关闭 button missing") }

        NSPasteboard.general.clearContents()
        closeButton.performClick(nil)

        XCTAssertTrue(NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.isEmpty ?? true,
                      "关闭 must not write to clipboard")
        XCTAssertFalse(controller.window?.isVisible ?? false, "关闭 must close the window")
    }
}
