import XCTest
@testable import ShotX

final class PermissionFlowTests: XCTestCase {
    @MainActor
    func testFirstLaunchRequestsScreenPermissionOnceAndMarksAsked() {
        let suite = UserDefaults(suiteName: #function)!
        suite.removePersistentDomain(forName: #function)
        let model = AppModel(defaults: suite)
        var requests = 0
        model.requestScreenAccess = { requests += 1; return false }

        model.requestScreenPermissionOnFirstLaunch(currentStatus: .unavailable)
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(model.screenPermissionAsked)

        model.requestScreenPermissionOnFirstLaunch(currentStatus: .unavailable)
        XCTAssertEqual(requests, 1)
    }

    @MainActor
    func testFirstLaunchWithScreenAlreadyAllowedAsksNothing() {
        let suite = UserDefaults(suiteName: #function)!
        suite.removePersistentDomain(forName: #function)
        let model = AppModel(defaults: suite)
        var requests = 0
        model.requestScreenAccess = { requests += 1; return true }

        model.requestScreenPermissionOnFirstLaunch(currentStatus: .allowed)
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(model.screenPermissionAsked)
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
    func testScreenPermissionAskedFlagPersistsAcrossModelInstances() {
        let suite = UserDefaults(suiteName: #function)!
        suite.removePersistentDomain(forName: #function)
        let first = AppModel(defaults: suite)
        first.requestScreenAccess = { false }
        first.requestScreenPermissionOnFirstLaunch(currentStatus: .unavailable)
        XCTAssertTrue(first.screenPermissionAsked)

        let second = AppModel(defaults: suite)
        var requests = 0
        second.requestScreenAccess = { requests += 1; return false }
        second.requestScreenPermissionOnFirstLaunch(currentStatus: .unavailable)
        XCTAssertEqual(requests, 0)
    }
}
