import XCTest
@testable import ShotX

final class PermissionFlowTests: XCTestCase {
    @MainActor
    func testAppStartDoesNotProactivelyRequestScreenPermission() async {
        let suite = UserDefaults(suiteName: #function)!
        suite.removePersistentDomain(forName: #function)
        let model = AppModel(defaults: suite)
        var requests = 0
        model.requestScreenAccess = { requests += 1; return .denied }

        model.start()
        await Self.drainMainActor()
        XCTAssertEqual(requests, 0)
    }

    func testFreshInstallRecordingDefaultsDisableCameraAndMicrophone() throws {
        XCTAssertFalse(AppSettings.defaults.microphone)
        XCTAssertFalse(AppSettings.defaults.cameraEnabled)
        XCTAssertEqual(AppSettings.defaults.cameraSize, .large)
        XCTAssertTrue(AppSettings.defaults.cameraMirror)
        XCTAssertFalse(AppSettings.defaults.cameraBackgroundBlur)
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings.defaults))
        XCTAssertFalse(roundTrip.microphone)
        XCTAssertFalse(roundTrip.cameraEnabled)
        XCTAssertEqual(roundTrip.cameraSize, .large)
        XCTAssertTrue(roundTrip.cameraMirror)
        XCTAssertFalse(roundTrip.cameraBackgroundBlur)
    }

    @MainActor
    func testDefaultSystemRequestIsRetriedAfterPreviousAttempt() {
        let suite = UserDefaults(suiteName: #function)!
        suite.removePersistentDomain(forName: #function)
        let first = AppModel(defaults: suite)
        first.requestScreenAccess = { .denied }
        first.requestScreenPermission()
        XCTAssertTrue(first.screenPermissionAsked)

        let second = AppModel(defaults: suite)
        var requests = 0
        second.requestScreenAccess = { requests += 1; return .denied }
        second.requestScreenPermission()
        XCTAssertEqual(requests, 1)
    }

    /// BRA-120: flag 仅在系统请求真实发出（授权或拒绝）后置位，不得提前烧毁。
    @MainActor
    func testFlagIsSetOnlyAfterGenuinePromptDecision() {
        let suite = UserDefaults(suiteName: #function)!
        suite.removePersistentDomain(forName: #function)
        let model = AppModel(defaults: suite)
        var requests = 0
        model.requestScreenAccess = { requests += 1; return .denied }

        XCTAssertFalse(model.screenPermissionAsked)
        model.requestScreenPermission()
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(model.screenPermissionAsked)
    }

    /// BRA-120: 请求被系统静默抑制（未弹窗）时不得烧毁 flag，保证后续仍可再次真实申请。
    @MainActor
    func testSuppressedRequestDoesNotBurnFlagAndAllowsReRequest() {
        let suite = UserDefaults(suiteName: #function)!
        suite.removePersistentDomain(forName: #function)
        let model = AppModel(defaults: suite)
        var requests = 0
        model.requestScreenAccess = { requests += 1; return .suppressed }

        model.requestScreenPermission()
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(model.screenPermissionAsked)

        model.requestScreenPermission()
        XCTAssertEqual(requests, 2)
        XCTAssertFalse(model.screenPermissionAsked)
    }

    /// BRA-120: 麦克风保持按需申请——开启开关才发起请求；拒绝后开关自动关闭并提示。
    @MainActor
    func testMicrophoneOnDemandRequestDeniedTurnsOffToggleAndShowsError() async {
        let suite = UserDefaults(suiteName: #function)!
        suite.removePersistentDomain(forName: #function)
        let model = AppModel(defaults: suite)
        var requests = 0
        model.requestAudioAccess = { completion in
            requests += 1
            completion(false)
        }
        model.settings.microphone = true

        model.request(.microphone)
        await Self.drainMainActor()

        XCTAssertEqual(requests, 1)
        XCTAssertFalse(model.settings.microphone)
        XCTAssertNotNil(model.errorMessage)
    }

    /// BRA-120/BRA-102: 麦克风授权成功时开关保持开启、不提示错误。
    @MainActor
    func testMicrophoneOnDemandRequestGrantedKeepsToggle() async {
        let suite = UserDefaults(suiteName: #function)!
        suite.removePersistentDomain(forName: #function)
        let model = AppModel(defaults: suite)
        var requests = 0
        model.requestAudioAccess = { completion in
            requests += 1
            completion(true)
        }
        model.settings.microphone = true

        model.request(.microphone)
        await Self.drainMainActor()

        XCTAssertEqual(requests, 1)
        XCTAssertTrue(model.settings.microphone)
        XCTAssertNil(model.errorMessage)
    }

    /// BRA-102 回归: 默认 settings 不开启麦克风/摄像头，首次启动不自动发起麦克风申请。
    @MainActor
    func testDefaultsNeverRequestMicrophoneAutomatically() {
        let suite = UserDefaults(suiteName: #function)!
        suite.removePersistentDomain(forName: #function)
        let model = AppModel(defaults: suite)
        var audioRequests = 0
        model.requestScreenAccess = { .denied }
        model.requestAudioAccess = { completion in audioRequests += 1; completion(true) }

        XCTAssertEqual(audioRequests, 0)
        XCTAssertFalse(model.settings.microphone)
    }

    @MainActor
    private static func drainMainActor() async {
        for _ in 0..<20 { await Task.yield() }
    }
}
