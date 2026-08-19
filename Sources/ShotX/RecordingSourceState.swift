import AVFoundation
import CoreAudio

/// 录制源按钮（O-RSET 紧凑面板四枚）on/off 视觉状态的纯解析。
/// 依据 `docs/shotx-ux-ui-spec-BRA113.md` §1.2 真值表：视觉状态必须等于该来源
/// 录制中的实际启用状态（开关 + 权限 + 设备三者共同决定），杜绝「显示开但实际未采集」的假状态。
enum RecordingSource: String, CaseIterable, Identifiable {
    case speaker, microphone, camera, mouse
    var id: String { rawValue }
    /// 对应用图资产基础名（`record-<base>-on.svg` / `record-<base>-off.svg`）。
    var assetBase: String { "record-\(rawValue)" }
}

enum RecordingSourceState {
    /// 解析按钮应呈现的视觉 on 状态。`permission` 为 nil 表示该源无独立权限维度（扬声器/鼠标）。
    static func isOn(_ source: RecordingSource, settings: AppSettings, permission: PermissionState?, deviceAvailable: Bool) -> Bool {
        switch source {
        case .speaker: settings.systemAudio && deviceAvailable
        case .microphone: settings.microphone && permission == .allowed && deviceAvailable
        case .camera: settings.cameraEnabled && permission == .allowed && deviceAvailable
        case .mouse: settings.showsCursor || settings.showsClicks
        }
    }
}

enum RecordingDeviceAvailability {
    /// 系统默认音频输出设备是否存在（扬声器来源前置；屏幕录制权限已授予才进入 O-RSET，视为已满足）。
    static func hasAudioOutputDevice() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != kAudioObjectUnknown
    }

    static func hasMicrophoneDevice() -> Bool { AVCaptureDevice.default(for: .audio) != nil }
    static func defaultMicrophoneName() -> String { AVCaptureDevice.default(for: .audio)?.localizedName ?? "" }
    static func hasCameraDevice() -> Bool { CameraSession.hasAvailableDevice() }
}
