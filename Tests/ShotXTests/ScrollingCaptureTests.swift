import XCTest
import CoreGraphics
@testable import ShotX

// Regression coverage for the 0.1.12 "scrolling capture produces repeated content" bug (BRA-88/89).
// The overlap matcher previously locked onto a self-similar false valley and returned an overlap
// far smaller than the true scroll, so the cropped strip re-appended already-stitched rows.
final class ScrollingCaptureTests: XCTestCase {

    // MARK: - Synthetic scrolling document

    // A "text-like" page: rows of dense glyph bands with line-dependent content, so shifting the
    // viewport by a whole number of lines looks similar but never identical. This reproduces the
    // QA failure mode where the old matcher returned overlap 130-250px smaller than the truth.
    private static func textRow(_ y: Int, _ x: Int) -> UInt8 {
        let line = y / 18
        let inLine = y % 18
        let glyph = ((line * 73) ^ (x / 4) ^ (line &* 31)) & 0xff
        if inLine >= 3, inLine <= 13, glyph % 5 != 0, x % 13 != 0 { return UInt8(120 + (glyph % 60)) }
        if inLine == 1 || inLine == 15, x % 7 == 0 { return UInt8(80 + (x % 40)) }
        return UInt8(244 - (line & 7))
    }

    private static func frameBytes(doc: (Int, Int) -> UInt8, width: Int, height: Int, offset: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = doc(y + offset, x)
                let i = (y * width + x) * 4
                bytes[i] = v
                bytes[i + 1] = UInt8((Int(v) * 3) % 256)
                bytes[i + 2] = UInt8((Int(v) * 5) % 256)
                bytes[i + 3] = 255
            }
        }
        return bytes
    }

    private static func cgImage(_ bytes: [UInt8], width: Int, height: Int) -> CGImage {
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private static func rowsMatch(_ imageBytes: [UInt8], row: Int, doc: (Int, Int) -> UInt8, docY: Int, width: Int) -> Bool {
        for x in stride(from: 0, to: width, by: 4) {
            let p = (row * width + x) * 4
            let v = Int(doc(docY, x))
            if Int(imageBytes[p]) != v || Int(imageBytes[p + 1]) != v * 3 % 256 || Int(imageBytes[p + 2]) != v * 5 % 256 { return false }
        }
        return true
    }

    private static func feed(_ stitcher: inout ScrollingStitcher, frames: [(doc: (Int, Int) -> UInt8, offset: Int)]) {
        for frame in frames { _ = stitcher.ingest(cgImage(frameBytes(doc: frame.doc, width: 780, height: 800, offset: frame.offset), width: 780, height: 800)) }
    }

    // MARK: - Regression: similar-row content must not duplicate

    func testSimilarRowStitchingHasNoDuplicatedContent() throws {
        let width = 780, height = 800
        let deltas: [Int] = [55, 48, 70, 40, 62, 35, 66, 45, 58, 50, 72, 38, 53, 47, 60, 42]
        var positions: [Int] = []
        var acc = 0
        for d in deltas { acc += d; positions.append(acc) }

        var stitcher = ScrollingStitcher()
        Self.feed(&stitcher, frames: [(Self.textRow, 0)] + positions.map { (Self.textRow, $0) })
        XCTAssertEqual(stitcher.height, height + (positions.last ?? 0))

        let rendered = try XCTUnwrap(stitcher.render())
        XCTAssertEqual(rendered.width, width)
        XCTAssertEqual(rendered.height, height + (positions.last ?? 0))
        let bytes = [UInt8](try XCTUnwrap(rendered.dataProvider?.data as Data?))

        // Every rendered row must be exactly the document row at the same index. The pre-fix
        // matcher re-appended already-stitched strips, so most rows matched a *shifted* doc row.
        var mismatched = 0
        for row in 0..<rendered.height {
            if !Self.rowsMatch(bytes, row: row, doc: Self.textRow, docY: row, width: width) { mismatched += 1 }
        }
        XCTAssertLessThan(Double(mismatched) / Double(rendered.height), 0.03, "\(mismatched)/\(rendered.height) rows mismatch their expected document position")
    }

    // MARK: - Regression: sparse / low-texture content still stitches frames

    func testSparseContentStillStitchesFrames() throws {
        // Mostly-blank page with a narrow column of sparse text: low texture but still scrolled.
        func sparse(_ y: Int, _ x: Int) -> UInt8 {
            let line = y / 24
            let inLine = y % 24
            if x < 160, inLine >= 2, inLine <= 21, ((line &* 29) ^ (x / 3)) % 11 != 0 { return UInt8(100 + (line &* 7) % 40) }
            if inLine == 0 || inLine == 23, x % 5 == 0 { return UInt8(180) }
            return 252
        }
        let width = 780, height = 800
        let deltas = [48, 52, 45, 58, 50]
        var positions: [Int] = []
        var acc = 0
        for d in deltas { acc += d; positions.append(acc) }

        var stitcher = ScrollingStitcher()
        Self.feed(&stitcher, frames: [(sparse, 0)] + positions.map { (sparse, $0) })
        XCTAssertGreaterThan(stitcher.segments.count, 1, "low-texture content should still append strips")
        XCTAssertGreaterThan(stitcher.height, height, "stitched image should grow beyond the first frame")
    }

    // MARK: - Regression: render() output is top-to-bottom page order

    func testRenderKeepsPageTopToBottomOrder() throws {
        let width = 780, height = 800
        let delta = 64
        var stitcher = ScrollingStitcher()
        Self.feed(&stitcher, frames: [(Self.textRow, 0), (Self.textRow, delta)])
        let rendered = try XCTUnwrap(stitcher.render())
        let bytes = [UInt8](try XCTUnwrap(rendered.dataProvider?.data as Data?))
        // Row 0 is the top of the document; the last row is the bottom of the scrolled-in content.
        XCTAssertTrue(Self.rowsMatch(bytes, row: 0, doc: Self.textRow, docY: 0, width: width))
        XCTAssertTrue(Self.rowsMatch(bytes, row: rendered.height - 1, doc: Self.textRow, docY: height + delta - 1, width: width))
    }
}
