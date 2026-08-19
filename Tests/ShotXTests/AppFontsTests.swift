import AppKit
import CoreText
import XCTest
@testable import ShotX

final class AppFontsTests: XCTestCase {
    func testAnnotationFontFactoryFallsBackToSystemFontWhenNotRegistered() {
        let fallback = AppFonts.annotationFont(size: 16)
        XCTAssertEqual(fallback.pointSize, 16)
        XCTAssertNotNil(fallback)
    }

    func testAnnotationFontFactoryResolvesAlimamaAfterRegistration() throws {
        let bundle = AppFonts.resourceBundle
        let url = try XCTUnwrap(bundle.url(forResource: "AlimamaFangYuanTiVF-Bold-sub", withExtension: "ttf"))
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        if !ok {
            throw XCTSkip("Alimama font not registered in this environment")
        }
        let font = AppFonts.annotationFont(size: 16)
        XCTAssertEqual(font.fontName, "AlimamaFangYuanTiVF-Thin")
        XCTAssertEqual(font.familyName, "Alimama FangYuanTi VF")
    }

    func testBundledFontResourceIsPackaged() {
        let url = AppFonts.resourceBundle.url(forResource: "AlimamaFangYuanTiVF-Bold-sub", withExtension: "ttf")
        XCTAssertNotNil(url, "font should be packaged into the app bundle")
    }
}
