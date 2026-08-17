import XCTest
@testable import ShotX

/// BRA-116 回归：录制按钮 on/off 两态与禁用态（`docs/shotx-ux-ui-spec-BRA113.md` §1.2 真值表）。
final class RecordingSourceStateTests: XCTestCase {
    /// 扬声器：仅开关且输出设备存在才显示 on。
    func testSpeakerOnRequiresToggleAndOutputDevice() {
        var settings = AppSettings.defaults
        settings.systemAudio = true
        XCTAssertTrue(RecordingSourceState.isOn(.speaker, settings: settings, permission: nil, deviceAvailable: true))
        settings.systemAudio = false
        XCTAssertFalse(RecordingSourceState.isOn(.speaker, settings: settings, permission: nil, deviceAvailable: true))
        XCTAssertFalse(RecordingSourceState.isOn(.speaker, settings: settings, permission: nil, deviceAvailable: false))
    }

    /// 麦克风：开关 + 权限 + 设备三者缺一即 off（禁用/关闭态），不得出现「开了却录不上」。
    func testMicrophoneOnRequiresTogglePermissionAndDevice() {
        var settings = AppSettings.defaults
        settings.microphone = true
        XCTAssertTrue(RecordingSourceState.isOn(.microphone, settings: settings, permission: .allowed, deviceAvailable: true))
        XCTAssertFalse(RecordingSourceState.isOn(.microphone, settings: settings, permission: .notDetermined, deviceAvailable: true))
        XCTAssertFalse(RecordingSourceState.isOn(.microphone, settings: settings, permission: .unavailable, deviceAvailable: true))
        XCTAssertFalse(RecordingSourceState.isOn(.microphone, settings: settings, permission: .allowed, deviceAvailable: false))
        settings.microphone = false
        XCTAssertFalse(RecordingSourceState.isOn(.microphone, settings: settings, permission: .allowed, deviceAvailable: true))
    }

    /// 摄像头：开关 + 权限 + 设备缺一即 off。
    func testCameraOnRequiresTogglePermissionAndDevice() {
        var settings = AppSettings.defaults
        settings.cameraEnabled = true
        XCTAssertTrue(RecordingSourceState.isOn(.camera, settings: settings, permission: .allowed, deviceAvailable: true))
        XCTAssertFalse(RecordingSourceState.isOn(.camera, settings: settings, permission: .notDetermined, deviceAvailable: true))
        XCTAssertFalse(RecordingSourceState.isOn(.camera, settings: settings, permission: .unavailable, deviceAvailable: true))
        XCTAssertFalse(RecordingSourceState.isOn(.camera, settings: settings, permission: .allowed, deviceAvailable: false))
        settings.cameraEnabled = false
        XCTAssertFalse(RecordingSourceState.isOn(.camera, settings: settings, permission: .allowed, deviceAvailable: true))
    }

    /// 鼠标设置：无权限/设备维度，任一开关开即 on。
    func testMouseOnWhenEitherCursorOrClicksEnabled() {
        var settings = AppSettings.defaults
        settings.showsCursor = true
        settings.showsClicks = false
        XCTAssertTrue(RecordingSourceState.isOn(.mouse, settings: settings, permission: nil, deviceAvailable: true))
        settings.showsCursor = false
        settings.showsClicks = true
        XCTAssertTrue(RecordingSourceState.isOn(.mouse, settings: settings, permission: nil, deviceAvailable: false))
        settings.showsCursor = false
        settings.showsClicks = false
        XCTAssertFalse(RecordingSourceState.isOn(.mouse, settings: settings, permission: nil, deviceAvailable: true))
    }

    /// 首次录屏（全新安装默认设置）：麦克风/摄像头默认关，扬声器/鼠标默认开（§3.1）。
    func testFreshInstallDefaultsShowMicCameraOff() {
        let settings = AppSettings.defaults
        XCTAssertFalse(RecordingSourceState.isOn(.microphone, settings: settings, permission: .notDetermined, deviceAvailable: true))
        XCTAssertFalse(RecordingSourceState.isOn(.camera, settings: settings, permission: .notDetermined, deviceAvailable: true))
        XCTAssertTrue(RecordingSourceState.isOn(.speaker, settings: settings, permission: nil, deviceAvailable: true))
        XCTAssertTrue(RecordingSourceState.isOn(.mouse, settings: settings, permission: nil, deviceAvailable: true))
    }

    /// 首次录屏不自动弹权限请求（BRA-102 口径回归）：默认状态不请求麦克风。
    @MainActor
    func testFreshInstallDefaultsDoNotRequestMicrophone() {
        let suite = UserDefaults(suiteName: #function)!
        suite.removePersistentDomain(forName: #function)
        let model = AppModel(defaults: suite)
        var audioRequests = 0
        model.requestScreenAccess = { .denied }
        model.requestAudioAccess = { completion in audioRequests += 1; completion(true) }
        model.requestVideoAccess = { completion in audioRequests += 1; completion(true) }

        XCTAssertEqual(audioRequests, 0)
        XCTAssertFalse(model.settings.microphone)
        XCTAssertFalse(model.settings.cameraEnabled)
    }

    /// 授权成功后才落定开关（BRA-116：权限未就绪不置 on，避免假开启态）。
    @MainActor
    func testMicrophoneGrantAfterRequestEnablesToggle() async {
        let suite = UserDefaults(suiteName: #function)!
        suite.removePersistentDomain(forName: #function)
        let model = AppModel(defaults: suite)
        var requestStarted = false
        model.requestAudioAccess = { completion in requestStarted = true; completion(true) }
        model.setMicrophoneEnableIntent(true)
        model.request(.microphone)
        XCTAssertFalse(model.settings.microphone)
        XCTAssertTrue(requestStarted)
        await Self.drainMainActor()
        XCTAssertTrue(model.settings.microphone)
        XCTAssertNil(model.errorMessage)
    }

    /// 授权成功后才落定摄像头开关（BRA-116）。
    @MainActor
    func testCameraGrantAfterRequestEnablesToggle() async {
        let suite = UserDefaults(suiteName: #function)!
        suite.removePersistentDomain(forName: #function)
        let model = AppModel(defaults: suite)
        var requestStarted = false
        model.requestVideoAccess = { completion in requestStarted = true; completion(true) }
        model.setCameraEnableIntent(true)
        model.request(.camera)
        XCTAssertFalse(model.settings.cameraEnabled)
        XCTAssertTrue(requestStarted)
        await Self.drainMainActor()
        XCTAssertTrue(model.settings.cameraEnabled)
        XCTAssertNil(model.errorMessage)
    }

    /// 授权成功但用户在弹窗期间关闭了开关：不重新置开（BRA-116 意图防护）。
    @MainActor
    func testMicrophoneGrantDoesNotEnableWhenUserTurnedOffDuringRequest() async {
        let suite = UserDefaults(suiteName: #function)!
        suite.removePersistentDomain(forName: #function)
        let model = AppModel(defaults: suite)
        model.requestAudioAccess = { completion in completion(true) }
        model.setMicrophoneEnableIntent(true)
        model.request(.microphone)
        model.setMicrophoneEnableIntent(false)
        model.settings.microphone = false
        await Self.drainMainActor()
        XCTAssertFalse(model.settings.microphone)
    }

    /// 拒绝授权：开关回落关闭态并提示（BRA-116 假状态防护）。
    @MainActor
    func testCameraDeniedAfterRequestTurnsOffToggle() async {
        let suite = UserDefaults(suiteName: #function)!
        suite.removePersistentDomain(forName: #function)
        let model = AppModel(defaults: suite)
        model.requestVideoAccess = { completion in completion(false) }
        model.request(.camera)
        await Self.drainMainActor()
        XCTAssertFalse(model.settings.cameraEnabled)
        XCTAssertNotNil(model.errorMessage)
    }

    /// 权限请求中 `requesting` 有值（O-RSET 行内 spinner 依据）。
    @MainActor
    func testRequestingTracksInFlightMicRequest() async {
        let suite = UserDefaults(suiteName: #function)!
        suite.removePersistentDomain(forName: #function)
        let model = AppModel(defaults: suite)
        model.requestAudioAccess = { completion in
            XCTAssertEqual(model.requesting, .microphone)
            completion(true)
        }
        model.request(.microphone)
        await Self.drainMainActor()
        XCTAssertNil(model.requesting)
    }

    @MainActor
    private static func drainMainActor() async {
        for _ in 0..<20 { await Task.yield() }
    }
}
