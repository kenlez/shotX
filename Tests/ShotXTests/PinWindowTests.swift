import XCTest
@testable import ShotX

final class PinWindowTests: XCTestCase {
    func testPinZoomClampsTo10To300Percent() {
        XCTAssertEqual(PinZoom.clamp(0.01), 0.1)
        XCTAssertEqual(PinZoom.clamp(10), 3.0)
        XCTAssertEqual(PinZoom.clamp(1.5), 1.5)
        XCTAssertEqual(PinZoom.clamp(-0.5), 0.1)
    }

    func testPinInitialScaleCapsAt100PercentAndScreenBounds() {
        let small = PinZoom.initialScale(imageSize: CGSize(width: 100, height: 100), visibleSize: CGSize(width: 2000, height: 1200))
        XCTAssertEqual(small, 1)
        let large = PinZoom.initialScale(imageSize: CGSize(width: 4000, height: 2000), visibleSize: CGSize(width: 2000, height: 1200))
        XCTAssertEqual(large, 0.5)
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
        XCTAssertEqual(scale, 3.0)
        let shrunk = PinZoom.clamp(1 * PinZoom.zoomFactor(deltaY: -50, precise: false))
        XCTAssertEqual(shrunk, 0.1)
    }

    func testPercentReadoutFormatsIntegerPercent() {
        XCTAssertEqual(PinZoom.percent(1.0), "100%")
        XCTAssertEqual(PinZoom.percent(0.4), "40%")
        XCTAssertEqual(PinZoom.percent(0.375), "38%")
        XCTAssertEqual(PinZoom.percent(0.2), "20%")
        XCTAssertEqual(PinZoom.percent(3.0), "300%")
        XCTAssertEqual(PinZoom.percent(0.995), "100%")
    }

    func testSnapOnlyWithinTenPercentOfTarget() {
        XCTAssertEqual(PinZoom.snapValue(0.95, to: 1), 1.0)
        XCTAssertEqual(PinZoom.snapValue(1.08, to: 1), 1.0)
        XCTAssertNil(PinZoom.snapValue(0.89, to: 1))
        XCTAssertNil(PinZoom.snapValue(1.12, to: 1))
        XCTAssertEqual(PinZoom.snapValue(1.0, to: 1), 1.0)
        XCTAssertNil(PinZoom.snapValue(0.5, to: 1))
    }

    func testSnapValueIsIdempotent() {
        let first = PinZoom.snapValue(0.95, to: 1)
        let second = first.flatMap { PinZoom.snapValue($0, to: 1) }
        XCTAssertEqual(first, second)
    }

    func testSliderStyleMatchesDesignAnnotation() {
        XCTAssertEqual(PinSliderStyle.trackHeight, 23)
        XCTAssertEqual(PinSliderStyle.knobDiameter, 23)
        XCTAssertEqual(PinSliderStyle.trackFillAlpha, 0.2, accuracy: 0.0001)
        XCTAssertEqual(PinSliderStyle.trackStrokeAlpha, 0.2, accuracy: 0.0001)
        XCTAssertEqual(PinSliderStyle.unityMarkAlpha, 0.5, accuracy: 0.0001)
        XCTAssertEqual(PinSliderStyle.knobRingHex, "#CCCCCC")
    }
}
