import XCTest
@testable import ShotX

final class BRA79RecordingUITests: XCTestCase {

    // MARK: BRA-79 crash regression — Figma resource bundle resolution

    func testFigmaBundleResolvesFromPackagedAppResources() throws {
        // The shipped .app places the resource bundle under Contents/Resources, while the
        // SwiftPM-generated `Bundle.module` accessor only checks the app root and a build-machine
        // path — which crashed packaged apps with a fatalError (SIGTRAP) on first region capture.
        // `FigmaResourceBundle.resolve` must find the bundle at the packaged location.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let resources = tmp.appendingPathComponent("Contents").appendingPathComponent("Resources")
        let bundleDir = resources.appendingPathComponent("ShotX_ShotX.bundle")
        let figma = bundleDir.appendingPathComponent("Figma")
        try FileManager.default.createDirectory(at: figma, withIntermediateDirectories: true)
        try Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8).write(to: figma.appendingPathComponent("select.svg"))

        let main = Bundle(url: tmp)!
        XCTAssertNotNil(FigmaResourceBundle.resolve(mainBundle: main))
        let svg = FigmaResourceBundle.resolve(mainBundle: main)?.url(forResource: "select", withExtension: "svg", subdirectory: "Figma")
        XCTAssertNotNil(svg)
        XCTAssertTrue(FileManager.default.fileExists(atPath: svg!.path))
    }

    func testFigmaBundleResolvesFromBundleRootLayout() throws {
        // `swift build`/debug layout: bundle next to the main bundle URL (the accessor's mainPath).
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bundleDir = tmp.appendingPathComponent("ShotX_ShotX.bundle")
        let figma = bundleDir.appendingPathComponent("Figma")
        try FileManager.default.createDirectory(at: figma, withIntermediateDirectories: true)
        try Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8).write(to: figma.appendingPathComponent("pen.svg"))

        let main = Bundle(url: tmp)!
        XCTAssertNotNil(FigmaResourceBundle.resolve(mainBundle: main))
    }

    func testFigmaBundleResolveNeverCrashesWhenMissing() {
        // Regression guard: the old code path crashed via `Bundle.module` fatalError. The resolver
        // must return nil instead of trapping when no bundle is present.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let main = Bundle(url: tmp)!
        XCTAssertNil(FigmaResourceBundle.resolve(mainBundle: main))
    }

    // MARK: FR-BRA71-07 layout — 256 × 140 menu

    func testRecordingSetupPanelSizeIs256x140() {
        XCTAssertEqual(RecordingSetupLayout.panelSize, CGSize(width: 256, height: 140))
    }

    func testRecordingSetupLayoutCentersOnLargeSelectionWithNewSize() {
        let selection = CGRect(x: 100, y: 100, width: 1600, height: 1000)
        let visible = CGRect(x: 0, y: 0, width: 2000, height: 1200)
        let frame = RecordingSetupLayout.frame(panelSize: RecordingSetupLayout.panelSize, selection: selection, visibleFrame: visible)
        XCTAssertEqual(frame.size, RecordingSetupLayout.panelSize)
        XCTAssertEqual(frame.midX, selection.midX)
        XCTAssertEqual(frame.midY, selection.midY)
        XCTAssertTrue(visible.contains(frame))
    }

    func testRecordingSetupLayoutMenuSizedSmallerThanOldPanelStillFitsTinySelections() {
        // A 240 × 200 selection was smaller than the old 300 × 320 panel; with the 256 × 140 menu
        // it should center only if it no longer covers every corner handle.
        let selection = CGRect(x: 500, y: 500, width: 240, height: 200)
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = RecordingSetupLayout.frame(panelSize: RecordingSetupLayout.panelSize, selection: selection, visibleFrame: visible)
        XCTAssertEqual(frame.size, RecordingSetupLayout.panelSize)
        XCTAssertTrue(visible.contains(frame))
    }

    // MARK: FR-BRA71-07 config actions

    @MainActor
    func testToggleSystemAudioFlipsSetting() {
        let suite = UserDefaults(suiteName: #function)!
        suite.removePersistentDomain(forName: #function)
        let model = AppModel(defaults: suite)
        let initial = model.settings.systemAudio
        RecordingSetupActions.toggleSystemAudio(on: model)
        XCTAssertNotEqual(model.settings.systemAudio, initial)
        RecordingSetupActions.toggleSystemAudio(on: model)
        XCTAssertEqual(model.settings.systemAudio, initial)
    }

    @MainActor
    func testToggleMicrophoneFlipsSetting() {
        let suite = UserDefaults(suiteName: #function)!
        suite.removePersistentDomain(forName: #function)
        let model = AppModel(defaults: suite)
        XCTAssertFalse(model.settings.microphone)
        RecordingSetupActions.toggleMicrophone(on: model)
        XCTAssertTrue(model.settings.microphone)
        RecordingSetupActions.toggleMicrophone(on: model)
        XCTAssertFalse(model.settings.microphone)
    }

    @MainActor
    func testSettingsPersistAfterSetupConfigActions() {
        let suite = UserDefaults(suiteName: #function)!
        suite.removePersistentDomain(forName: #function)
        let model = AppModel(defaults: suite)
        model.settings.systemAudio = true
        model.settings.showsCursor = true
        model.persist()

        let reloaded = AppModel(defaults: suite)
        XCTAssertTrue(reloaded.settings.systemAudio)
        XCTAssertTrue(reloaded.settings.showsCursor)
    }
}
