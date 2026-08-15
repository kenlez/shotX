import XCTest
import AppKit
@testable import ShotX

@MainActor
final class QAPinWindowHierarchyTests: XCTestCase {

    private func makeController() -> (controller: PinWindowController, window: NSPanel) {
        let image = NSImage(size: NSSize(width: 400, height: 300))
        let controller = PinWindowController(image: image)
        return (controller, controller.window as! NSPanel)
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        var result: [NSView] = []
        for sub in view.subviews {
            result.append(sub)
            result.append(contentsOf: allSubviews(of: sub))
        }
        return result
    }

    func testContentViewHasImageAndControlsSubviews() {
        let (_, window) = makeController()
        guard let content = window.contentView else { return XCTFail("no content view") }
        let all = allSubviews(of: content)

        let hasImageView = all.contains { $0 is PinImageView }
        let hasSlider = all.contains { $0 is NSSlider }
        let hasCloseButton = all.contains { ($0 as? NSButton)?.accessibilityLabel() == "关闭" }
        let sliders = all.compactMap { $0 as? NSSlider }

        XCTAssertTrue(hasImageView, "image view must be a subview of the content view")
        XCTAssertTrue(hasSlider, "pin controls must include sliders")
        XCTAssertTrue(hasCloseButton, "关闭 button must be a subview")
        XCTAssertEqual(sliders.count, 2, "pin controls must include opacity and zoom")
    }
}
