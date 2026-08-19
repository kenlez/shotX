import XCTest
import AppKit
@testable import ShotX

/// Independent QA retest for BRA-98 (§8.7 keyboard paths).
///
/// Unlike the dev regression tests (which invoke `performKeyEquivalent` /
/// `keyDown` directly), these route a real NSEvent through `NSApp.sendEvent`,
/// exercising the AppKit dispatch path: key window selection -> keyDown /
/// performKeyEquivalent. This closes the gap between "handler logic works"
/// and "the key window actually receives the keystroke".
@MainActor
final class QAPinKeyboardRoutingTests: XCTestCase {

    private func makeWindow(imageSize: NSSize) -> (controller: PinWindowController, window: NSPanel) {
        let image = NSImage(size: imageSize)
        let controller = PinWindowController(image: image)
        return (controller, controller.window as! NSPanel)
    }

    private func controlsStack(in content: NSView) -> NSStackView? {
        content.subviews.compactMap { $0 as? NSStackView }.first { $0.orientation == .vertical }
    }

    private func makeKeyEvent(_ keyCode: UInt16, chars: String, modifier: NSEvent.ModifierFlags, window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifier, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
    }

    func testCommandWRoutedThroughKeyWindowCloses() throws {
        let app = NSApplication.shared
        let (controller, window) = makeWindow(imageSize: NSSize(width: 200, height: 100))
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.isKeyWindow, "precondition: pin window must be key to receive the event")
        XCTAssertTrue(window.isVisible, "precondition: pin window visible")

        NSPasteboard.general.clearContents()
        let event = makeKeyEvent(13, chars: "w", modifier: [.command], window: window)
        app.sendEvent(event)

        XCTAssertFalse(window.isVisible, "Cmd+W routed through NSApp must close the pin window")
        XCTAssertTrue(NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.isEmpty ?? true,
                      "Cmd+W must not write to clipboard")
    }

    func testEscapeRoutedThroughKeyWindowHidesControlsKeepsWindowOpen() throws {
        let app = NSApplication.shared
        let (controller, window) = makeWindow(imageSize: NSSize(width: 200, height: 100))
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        guard let content = window.contentView else { return XCTFail("content missing") }
        guard let controls = controlsStack(in: content) else { return XCTFail("controls stack missing") }

        let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           trackingNumber: 0, userData: nil)!
        content.mouseEntered(with: enter)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(controls.alphaValue, 1, accuracy: 0.01, "hover must reveal control bars")

        let esc = makeKeyEvent(53, chars: "\u{1B}", modifier: [], window: window)
        app.sendEvent(esc)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertTrue(window.isVisible, "Esc must not close the pin window")
        XCTAssertEqual(controls.alphaValue, 0, accuracy: 0.01, "Esc must hide the control bars")
    }

    func testWindowBecomesKeyWhenFocused() throws {
        let (controller, window) = makeWindow(imageSize: NSSize(width: 200, height: 100))
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.isKeyWindow, "focused pin window must become key to receive keyboard events")
    }

    func testMouseExitAutoHidesControlsRegression() throws {
        let (controller, window) = makeWindow(imageSize: NSSize(width: 200, height: 100))
        controller.showWindow(nil)
        guard let content = window.contentView else { return XCTFail("content missing") }
        guard let controls = controlsStack(in: content) else { return XCTFail("controls stack missing") }

        let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           trackingNumber: 0, userData: nil)!
        content.mouseEntered(with: enter)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(controls.alphaValue, 1, accuracy: 0.01, "hover must reveal control bars")

        let exit = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                          trackingNumber: 0, userData: nil)!
        content.mouseExited(with: exit)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(controls.alphaValue, 0, accuracy: 0.01, "mouse exit must auto-hide the control bars")
    }
}
