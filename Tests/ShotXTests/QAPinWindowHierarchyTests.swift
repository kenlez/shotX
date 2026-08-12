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
        let hasCloseButton = all.contains { ($0 as? NSButton)?.title == "关闭" }
        let hasCloseCopyButton = all.contains { ($0 as? NSButton)?.title == "关闭并复制" }
        let hasZoomLabel = all.contains { $0 is NSTextField }

        XCTAssertTrue(hasImageView, "image view must be a subview of the content view")
        XCTAssertTrue(hasSlider, "opacity slider must be a subview")
        XCTAssertTrue(hasCloseButton, "关闭 button must be a subview")
        XCTAssertTrue(hasCloseCopyButton, "关闭并复制 button must be a subview")
        XCTAssertTrue(hasZoomLabel, "zoom label must be a subview")
    }
}
