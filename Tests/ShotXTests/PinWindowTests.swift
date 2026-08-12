import XCTest
@testable import ShotX

final class PinWindowTests: XCTestCase {
    func testPinZoomClampsTo10To400Percent() {
        XCTAssertEqual(PinZoom.clamp(0.01), 0.1)
        XCTAssertEqual(PinZoom.clamp(10), 4.0)
        XCTAssertEqual(PinZoom.clamp(1.5), 1.5)
        XCTAssertEqual(PinZoom.clamp(-0.5), 0.1)
    }

    func testPinInitialScaleCapsAt100PercentAnd60PercentOfScreen() {
        let small = PinZoom.initialScale(imageSize: CGSize(width: 100, height: 100), visibleSize: CGSize(width: 2000, height: 1200))
        XCTAssertEqual(small, 1)
        let large = PinZoom.initialScale(imageSize: CGSize(width: 4000, height: 2000), visibleSize: CGSize(width: 2000, height: 1200))
        XCTAssertEqual(large, 0.3)
        let zeroSize = PinZoom.initialScale(imageSize: .zero, visibleSize: CGSize(width: 2000, height: 1200))
        XCTAssertEqual(zeroSize, 1)
    }

    func testPinZoomFactorDirectionAndMagnitude() {
        XCTAssertGreaterThan(PinZoom.zoomFactor(deltaY: 1, precise: false), 1)
        XCTAssertLessThan(PinZoom.zoomFactor(deltaY: -1, precise: false), 1)
        XCTAssertEqual(PinZoom.zoomFactor(deltaY: 0, precise: false), 1)
        XCTAssertGreaterThan(PinZoom.zoomFactor(deltaY: 10, precise: false), PinZoom.zoomFactor(deltaY: 1, precise: false))
    }

    func testPinZoomScaleFromClampedFactorStaysInRange() {
        let scale = PinZoom.clamp(1 * PinZoom.zoomFactor(deltaY: 50, precise: false))
        XCTAssertEqual(scale, 4.0)
        let shrunk = PinZoom.clamp(1 * PinZoom.zoomFactor(deltaY: -50, precise: false))
        XCTAssertEqual(shrunk, 0.1)
    }
}
