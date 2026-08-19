import XCTest
@testable import ShotX

// Independent QA coverage for BRA102-04/05/07 (camera PiP geometry invariants).
// Complements developer SettingsTests with the exact clamp boundary, arbitrary
// aspect ratios, and preview<->output pixel-scale equivalence for BOTH sizes.
final class QACameraOverlayTests: XCTestCase {

    // MARK: - BRA102-04: bottom-left anchored rounded square, never outside the region

    func testQAOverlayAnchorsBottomLeftWithMarginForAnyAspectRatio() {
        let selections: [CGSize] = [
            CGSize(width: 1280, height: 720),
            CGSize(width: 720, height: 1280),
            CGSize(width: 200, height: 200),
            CGSize(width: 300, height: 100),
            CGSize(width: 640, height: 480)
        ]
        for size in selections {
            let bounds = CGRect(origin: .zero, size: size)
            for preset in CameraOverlaySize.allCases {
                guard let rect = CameraOverlayLayout.rect(in: bounds, size: preset) else {
                    XCTFail("expected non-nil for \(size) / \(preset)")
                    continue
                }
                XCTAssertTrue(bounds.contains(rect), "PiP \(rect) exceeds region \(bounds)")
                XCTAssertEqual(rect.width, rect.height, "PiP must be a square for \(preset)")
                XCTAssertEqual(rect.minX, bounds.minX + CameraOverlayLayout.margin, "left margin violated")
                XCTAssertEqual(rect.minY, bounds.minY + CameraOverlayLayout.margin, "bottom margin violated")
            }
        }
    }

    // MARK: - BRA102-05 clamp boundary: available = min(w,h) - 2*margin must be >= minimumSide

    func testQAOverlayClampBoundaryExactlyAtMinimum() {
        // available = 88 - 24 = 64 == minimumSide -> fits, side clamped to 64
        let exact = CameraOverlayLayout.rect(in: CGRect(x: 0, y: 0, width: 88, height: 88), size: .large)
        XCTAssertNotNil(exact)
        XCTAssertEqual(exact?.size, CGSize(width: 64, height: 64))

        // available = 87 - 24 = 63 < 64 -> hidden (nil)
        let below = CameraOverlayLayout.rect(in: CGRect(x: 0, y: 0, width: 87, height: 87), size: .small)
        XCTAssertNil(below)

        // wide region: min dimension decides
        let wide = CameraOverlayLayout.rect(in: CGRect(x: 0, y: 0, width: 2000, height: 88), size: .large)
        XCTAssertNotNil(wide)
        XCTAssertEqual(wide?.size, CGSize(width: 64, height: 64))

        // 96-pt small preset fits at exactly 96 when available allows
        let smallFull = CameraOverlayLayout.rect(in: CGRect(x: 0, y: 0, width: 120, height: 120), size: .small)
        XCTAssertEqual(smallFull?.size, CGSize(width: 96, height: 96))
    }

    // MARK: - BRA102-07: preview (points, scale 1) and output (pixels, scale = backing) equivalence

    func testQAOverlayPreviewAndOutputMatchForBothSizesAtScale2() {
        let points = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let pixels = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        for preset in CameraOverlaySize.allCases {
            let preview = try! XCTUnwrap(CameraOverlayLayout.rect(in: points, size: preset, scale: 1))
            let output = try! XCTUnwrap(CameraOverlayLayout.rect(in: pixels, size: preset, scale: 2))
            XCTAssertEqual(output.minX, preview.minX * 2, accuracy: 0.001)
            XCTAssertEqual(output.minY, preview.minY * 2, accuracy: 0.001)
            XCTAssertEqual(output.width, preview.width * 2, accuracy: 0.001)
            XCTAssertEqual(output.height, preview.height * 2, accuracy: 0.001)
        }
    }

    func testQAOverlayPixelSizesMatchPRDAt2x() {
        // PRD/UX spec: small 96pt -> 192px, large 192pt -> 384px at @2x
        let pixels = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        XCTAssertEqual(CameraOverlayLayout.rect(in: pixels, size: .small, scale: 2)?.size, CGSize(width: 192, height: 192))
        XCTAssertEqual(CameraOverlayLayout.rect(in: pixels, size: .large, scale: 2)?.size, CGSize(width: 384, height: 384))
    }

    // MARK: - BRA102-06: mirror default + persistence round-trip

    func testQACameraSettingsDefaultsMatchSpec() {
        XCTAssertEqual(AppSettings.defaults.cameraSize, .large)
        XCTAssertTrue(AppSettings.defaults.cameraMirror)
        XCTAssertFalse(AppSettings.defaults.cameraBackgroundBlur)
        XCTAssertFalse(AppSettings.defaults.cameraEnabled)
    }
}
