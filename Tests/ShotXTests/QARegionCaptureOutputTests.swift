import AppKit
import XCTest
@testable import ShotX

final class QARegionCaptureOutputTests: XCTestCase {
    @MainActor func testCaptureFocusChainCyclesThroughSelectionHandlesToolbarOptionsAndOutputs() {
        let selection = NSView()
        let handles = (0..<8).map { _ in NSView() }
        let toolbar = (0..<4).map { _ in NSView() }
        let options = (0..<3).map { _ in NSView() }
        let outputs = (0..<5).map { _ in NSView() }
        let chain = CaptureFocusChain.views(selection: selection, handles: handles, toolbar: toolbar, options: options, outputs: outputs)

        CaptureFocusChain.link(chain)

        XCTAssertEqual(chain.count, 21)
        for (index, view) in chain.enumerated() {
            XCTAssertTrue(view.nextKeyView === chain[(index + 1) % chain.count])
            XCTAssertTrue(view.previousKeyView === chain[(index + chain.count - 1) % chain.count])
        }
    }

    @MainActor func testCaptureFocusChainWindowAwareBridgeSpansOverlayAndPanel() {
        let selection = NSView()
        let handles = (0..<8).map { _ in NSView() }
        let toolbar = (0..<4).map { _ in NSView() }
        let outputs = (0..<5).map { _ in NSView() }
        let overlay = [selection] + handles + toolbar + outputs
        let panel = (0..<3).map { _ in NSView() }

        CaptureFocusChain.linkWindowAware(overlayViews: overlay, panelViews: panel)

        XCTAssertEqual(overlay.count, 18)
        for (index, view) in overlay.enumerated() where index < overlay.count - 1 {
            XCTAssertTrue(view.nextKeyView === overlay[index + 1])
        }
        XCTAssertTrue(overlay.last?.nextKeyView === panel.first)
        XCTAssertTrue(panel.last?.nextKeyView === overlay.first)
        XCTAssertTrue(overlay.first?.previousKeyView === panel.last)
        XCTAssertTrue(panel.first?.previousKeyView === overlay.last)
    }

    @MainActor func testCaptureFocusChainTinySelectionThresholdHidesToolbarAndPanel() {
        XCTAssertTrue(CaptureFocusChain.isTiny(CGRect(x: 0, y: 0, width: 19, height: 200)))
        XCTAssertTrue(CaptureFocusChain.isTiny(CGRect(x: 0, y: 0, width: 200, height: 19)))
        XCTAssertFalse(CaptureFocusChain.isTiny(CGRect(x: 0, y: 0, width: 20, height: 20)))
        XCTAssertFalse(CaptureFocusChain.isTiny(CGRect(x: 0, y: 0, width: 40, height: 40)))
    }

    private func makeImage(width: Int, height: Int, rows: [(UInt8, UInt8, UInt8)]) -> CGImage {
        var px = [UInt8]()
        for y in 0..<height {
            let row = rows[min(y, rows.count - 1)]
            for _ in 0..<width { px.append(row.0); px.append(row.1); px.append(row.2); px.append(255) }
        }
        let data = Data(px)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func rgb(at x: Int, _ y: Int, in rep: NSBitmapImageRep) -> (Int, Int, Int) {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return (0, 0, 0) }
        return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    func testRegionRenderOutputIsRetinaPhysicalPixelSize() {
        // 2x Retina: CGImage 400x200 px on a 200x100 point screen.
        let image = makeImage(width: 400, height: 200, rows: [(0, 255, 0)])
        let selection = CGRect(x: 40, y: 30, width: 120, height: 60) // 2x -> 240x120 physical
        let view = AnnotationView(image: image, screenPointSize: CGSize(width: 200, height: 100), sourceRect: selection, settings: .defaults)
        let output = view.render()
        XCTAssertNotNil(output)
        guard let rep = output?.representations.first as? NSBitmapImageRep else { return XCTFail("no bitmap rep") }
        XCTAssertEqual(rep.pixelsWide, 240)
        XCTAssertEqual(rep.pixelsHigh, 120)
    }

    func testRegionRenderBottomHalfIsUprightNotFlipped() {
        // 4x4: CG rows top->bottom are R,G,B,Y. In y-up screen coords the bottom half is y 0..2.
        let image = makeImage(width: 4, height: 4, rows: [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0)])
        let selection = CGRect(x: 0, y: 0, width: 4, height: 2) // y-up bottom half -> B then Y
        let view = AnnotationView(image: image, screenPointSize: CGSize(width: 4, height: 4), sourceRect: selection, settings: .defaults)
        let output = view.render()
        XCTAssertNotNil(output)
        guard let rep = output?.representations.first as? NSBitmapImageRep else { return XCTFail("no bitmap rep") }
        XCTAssertEqual(rep.pixelsWide, 4)
        XCTAssertEqual(rep.pixelsHigh, 2)
        let top = rgb(at: 0, 0, in: rep)   // screen bottom edge
        let bottom = rgb(at: 0, 1, in: rep) // screen upper of the two rows
        XCTAssertGreaterThan(top.2, 200)       // B
        XCTAssertLessThan(top.0, 50)
        let yellow = bottom.0 > 200 && bottom.1 > 200 && bottom.2 < 50
        XCTAssertTrue(yellow, "expected yellow got \(bottom)")
    }

    func testRegionRenderOffOriginSelectionNotMirrored() {
        // 4x4 two-color split: left 2 cols red, right 2 cols green, full height.
        var px = [UInt8]()
        for _ in 0..<4 {
            for x in 0..<4 {
                if x < 2 { px.append(255); px.append(0); px.append(0) } else { px.append(0); px.append(255); px.append(0) }
                px.append(255)
            }
        }
        let data = Data(px)
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        // Select right half: x 2..4 -> output should be green on the left of the output.
        let selection = CGRect(x: 2, y: 0, width: 2, height: 4)
        let view = AnnotationView(image: image, screenPointSize: CGSize(width: 4, height: 4), sourceRect: selection, settings: .defaults)
        let output = view.render()
        XCTAssertNotNil(output)
        guard let rep = output?.representations.first as? NSBitmapImageRep else { return XCTFail("no bitmap rep") }
        let left = rgb(at: 0, 0, in: rep)
        XCTAssertGreaterThan(left.1, 200)
        XCTAssertLessThan(left.0, 50)
    }
}
