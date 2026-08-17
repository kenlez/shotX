import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ScreenCaptureKit
import ServiceManagement

enum CaptureMode: String, CaseIterable, Identifiable {
    case region = "区域截图"
    case window = "窗口截图"
    case display = "全屏截图"
    case scrolling = "滚动截图"
    case regionRecording = "区域录屏"
    case displayRecording = "显示器录屏"

    var id: String { rawValue }
    var displayName: String { self == .region ? "截图" : rawValue }
    static let activeShortcutCases: [CaptureMode] = [.region, .regionRecording, .displayRecording]
    var isRegion: Bool { self == .region || self == .scrolling || self == .regionRecording }
    var isDisplay: Bool { self == .display || self == .displayRecording }
    var isFoundationOnly: Bool { self == .scrolling || self == .regionRecording || self == .displayRecording }
}

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let none = Shortcut(keyCode: .max, modifiers: 0)
    static let legacyDefaults: [CaptureMode: Shortcut] = [
        .region: .init(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey)),
        .window: .init(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey | optionKey)),
        .display: .init(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey)),
        .scrolling: .init(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey | shiftKey)),
        .regionRecording: .init(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | shiftKey)),
        .displayRecording: .init(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | shiftKey | controlKey))
    ]
    static let defaults = Dictionary(uniqueKeysWithValues: CaptureMode.allCases.map { ($0, Shortcut.none) })
    var isEmpty: Bool { modifiers == 0 }

    var label: String {
        let flags: [(UInt32, String)] = [(UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"), (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘")]
        guard !isEmpty else { return "未设置" }
        let names: [UInt32: String] = [
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9", UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B",
            UInt32(kVK_ANSI_C): "C", UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E",
            UInt32(kVK_ANSI_F): "F", UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H",
            UInt32(kVK_ANSI_I): "I", UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K",
            UInt32(kVK_ANSI_L): "L", UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N",
            UInt32(kVK_ANSI_O): "O", UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q",
            UInt32(kVK_ANSI_R): "R", UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T",
            UInt32(kVK_ANSI_U): "U", UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W",
            UInt32(kVK_ANSI_X): "X", UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z"
        ]
        return flags.filter { modifiers & $0.0 != 0 }.map(\.1).joined() + (names[keyCode] ?? "?")
    }

    var carbonModifiers: UInt32 { modifiers }
}

enum ShortcutValidation: Error, Equatable {
    case duplicate(CaptureMode)
    case reserved
    case registrationFailed

    var message: String {
        switch self {
        case .duplicate(let mode): "此快捷键已用于「\(mode.rawValue)」。"
        case .reserved: "此快捷键由 macOS 保留，请选择其他组合。"
        case .registrationFailed: "无法注册此快捷键，可能已被其他应用使用。原快捷键未更改。"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var windowShadow = true
    var systemAudio = true
    var microphone = false
    // Optional keeps settings written by older ShotX builds decodable.
    private var camera: Bool? = false
    private var cameraSizeValue: CameraOverlaySize?
    private var cameraMirrorValue: Bool?
    private var cameraBackgroundBlurValue: Bool?
    var selectedMicrophoneID = ""
    var showsCursor = true
    var showsClicks = true
    var countdown = 3
    var annotationColors = Dictionary(uniqueKeysWithValues: AnnotationTool.styledCases.map { ($0.rawValue, "#FF3B30") })
    var annotationSizes = Dictionary(uniqueKeysWithValues: AnnotationTool.styledCases.map { ($0.rawValue, AnnotationTool.defaultSize(for: $0)) })
    var lastSaveDirectory: String?
    var shortcuts = Dictionary(uniqueKeysWithValues: CaptureMode.allCases.map { ($0.rawValue, Shortcut.none) })

    static let defaults = AppSettings()
    var cameraEnabled: Bool {
        get { camera ?? false }
        set { camera = newValue }
    }
    /// 画中画尺寸档位（BRA102-05，大/小两档）。
    var cameraSize: CameraOverlaySize {
        get { cameraSizeValue ?? .large }
        set { cameraSizeValue = newValue }
    }
    /// 摄像头镜像（BRA102-06，默认开：自拍镜像习惯）。
    var cameraMirror: Bool {
        get { cameraMirrorValue ?? true }
        set { cameraMirrorValue = newValue }
    }
    /// 摄像头模糊背景（BRA102-06，仅系统支持时展示并生效）。
    var cameraBackgroundBlur: Bool {
        get { cameraBackgroundBlurValue ?? false }
        set { cameraBackgroundBlurValue = newValue }
    }
    func shortcut(for mode: CaptureMode) -> Shortcut { shortcuts[mode.rawValue] ?? .none }
}

enum AnnotationTool: String, CaseIterable, Identifiable {
    case move = "移动", rectangle = "矩形", ellipse = "椭圆", line = "直线", arrow = "箭头", pen = "画笔", mosaic = "马赛克", text = "文字", crop = "标注"
    var id: String { rawValue }
    static let styledCases: [AnnotationTool] = [.rectangle, .ellipse, .line, .arrow, .pen, .mosaic, .text]

    /// Continuous draggable brush range and discrete preset values for the tool options popover (FR-CAP-15/16).
    var styleRange: (min: Double, max: Double, presets: [Double], unit: String) {
        switch self {
        case .text: (6, 96, [6, 10, 16, 32, 64, 96], "pt")
        case .mosaic: (8, 40, [8, 16, 24, 40], "px")
        case .move, .crop: (0, 0, [], "")
        default: (1, 8, [1, 2, 4, 8], "pt")
        }
    }

    var styleLabel: String {
        switch self {
        case .text: "字号"
        case .mosaic: "笔刷大小"
        default: "粗细"
        }
    }

    var styleAccessibilityLabel: String { "\(styleLabel)（\(styleRange.unit)）" }
    func styleAccessibilityValue(_ value: Double) -> String { "\(Int(value)) \(styleRange.unit)" }
    static func defaultSize(for tool: AnnotationTool) -> Double {
        let presets = tool.styleRange.presets
        return presets.isEmpty ? 0 : presets[presets.count / 2]
    }
}

enum AnnotationTextStyle: Int, CaseIterable {
    case normal, outlined, inverseOutlined, highlight
}

enum RecentResult {
    case image(NSImage)
    case video(URL, saved: Bool)
}

enum PermissionKind: String, CaseIterable, Identifiable {
    case screen = "屏幕录制"
    case systemAudio = "系统音频"
    case microphone = "麦克风"
    case camera = "摄像头"
    var id: String { rawValue }
    var purpose: String {
        switch self {
        case .screen: "截取或录制屏幕；内容只在这台 Mac 上处理。"
        case .systemAudio: "仅在录屏时写入电脑声音。"
        case .microphone: "仅在你启用麦克风录制时申请。"
        case .camera: "仅在你启用摄像头画面录制时申请。"
        }
    }
}

enum PermissionState: String {
    case notDetermined = "使用时询问"
    case allowed = "已允许"
    case unavailable = "不可用"
    case checking = "正在检查…"
}

/// 屏幕录制权限请求结果。`suppressed` 表示请求被系统静默抑制（未弹窗、未注册 TCC），
/// 此时不得置位 `screenPermissionAsked`，否则后续将永远不再真实申请。
enum ScreenPermissionPromptOutcome: Equatable {
    case granted
    case denied
    case suppressed
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings
    @Published private(set) var permissions = Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, PermissionState.checking) })
    @Published var errorMessage: String?
    @Published var recentResult: RecentResult?
    @Published private(set) var recording = false
    /// 正在等待系统弹窗决定的权限（O-RSET 行内 spinner，BRA-116）。nil 表示无进行中的请求。
    @Published private(set) var requesting: PermissionKind?
    /// 录制开始时刻与菜单栏「停止录制 00:12」同步文本（O-REC 联动，BRA-116）。
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var recordingElapsedText: String?
    @Published private(set) var launchAtLogin = [SMAppService.Status.enabled, .requiresApproval].contains(SMAppService.mainApp.status)

    private let defaults: UserDefaults
    private let settingsKey = "settings.v1"
    private let screenPermissionAskedKey = "screenPermissionAsked.v1"
    private let hotKeys = HotKeyManager()
    private var started = false
    private var elapsedTimer: Timer?

    /// Injectable screen-permission request for tests; production uses the system prompt.
    /// 生产实现临时把 LSUIElement accessory 应用切到 `.regular` 并激活后再请求，
    /// 否则系统权限弹窗会被 macOS 静默抑制（不弹窗、不注册 TCC、直接返回 false）。
    var requestScreenAccess: () -> ScreenPermissionPromptOutcome = {
        let original = NSApp?.activationPolicy()
        if let original { NSApp?.setActivationPolicy(.regular) }
        NSApp?.activate(ignoringOtherApps: true)
        let granted = CGRequestScreenCaptureAccess()
        if let original { NSApp?.setActivationPolicy(original) }
        return granted ? .granted : .denied
    }

    /// Injectable audio-permission request for tests; production uses `AVCaptureDevice.requestAccess`.
    var requestAudioAccess: (@escaping (Bool) -> Void) -> Void = { completion in
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }

    /// Injectable camera-permission request for tests; production uses `AVCaptureDevice.requestAccess`.
    var requestVideoAccess: (@escaping (Bool) -> Void) -> Void = { completion in
        AVCaptureDevice.requestAccess(for: .video, completionHandler: completion)
    }

    /// True once the user has gone through a screen-recording permission decision.
    private(set) var screenPermissionAsked: Bool {
        get { defaults.bool(forKey: screenPermissionAskedKey) }
        set { defaults.set(newValue, forKey: screenPermissionAskedKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded = defaults.data(forKey: settingsKey).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? .defaults
        for mode in CaptureMode.allCases where loaded.shortcuts[mode.rawValue] == Shortcut.legacyDefaults[mode] { loaded.shortcuts[mode.rawValue] = Shortcut.none }
        for mode in CaptureMode.allCases where !CaptureMode.activeShortcutCases.contains(mode) { loaded.shortcuts[mode.rawValue] = Shortcut.none }
        settings = loaded
    }

    func start() {
        guard !started else { return }
        started = true
        hotKeys.onTrigger = { [weak self] mode in self?.begin(mode) }
        do { try hotKeys.register(settings.shortcuts.compactMap { entry in CaptureMode(rawValue: entry.key).map { mode in (mode, entry.value) } }) }
        catch { errorMessage = ShortcutValidation.registrationFailed.message }
        if ProcessInfo.processInfo.environment["SHOTX_DEBUG_SETUP"] == "1" {
            NSLog("SHOTX-DEBUG debug setup trigger armed")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                NSLog("SHOTX-DEBUG calling begin regionRecording")
                await refreshPermissions()
                NSLog("SHOTX-DEBUG screen permission = \(permissions[.screen]?.rawValue ?? "?")")
                if ProcessInfo.processInfo.environment["SHOTX_DEBUG_PREPARE"] == "1", let main = NSScreen.screens.first {
                    let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    if let display = content?.displays.first {
                        NSLog("SHOTX-DEBUG direct prepare")
                        await RecordingCoordinator.shared.prepare(display: display, screen: main, localRect: CGRect(x: 200, y: 300, width: 400, height: 300), mode: .regionRecording, model: self)
                    } else {
                        await CaptureCoordinator.shared.begin(mode: .regionRecording, model: self)
                    }
                } else {
                    await CaptureCoordinator.shared.begin(mode: .regionRecording, model: self)
                }
            }
        }
        if recentResult == nil, let recovery = RecoveryStore.recoverableVideos().sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first {
            recentResult = .video(recovery, saved: false)
            errorMessage = "发现可恢复的录屏。可从“最近一次结果”预览、复制或另存。"
        }
        Task {
            await refreshPermissions()
            requestScreenPermissionOnFirstLaunch()
        }
    }

    /// BRA102-01: 全新安装首次启动即发起屏幕录制权限申请。此时不存在任何截图/录屏蒙层，
    /// 且 App 被激活，系统权限弹窗自然位于最高层、可点击；非首次启动不自动弹窗。
    func requestScreenPermissionOnFirstLaunch(currentStatus: PermissionState? = nil) {
        guard !screenPermissionAsked else { return }
        let status = currentStatus ?? permissions[.screen]
        if status == .allowed {
            screenPermissionAsked = true
            return
        }
        requestScreenPermission()
    }

    func shortcut(for mode: CaptureMode) -> Shortcut { settings.shortcut(for: mode) }

    func updateShortcut(_ shortcut: Shortcut, for mode: CaptureMode) -> Result<Void, ShortcutValidation> {
        if !shortcut.isEmpty, let duplicate = CaptureMode.activeShortcutCases.first(where: { $0 != mode && settings.shortcut(for: $0) == shortcut }) {
            return .failure(.duplicate(duplicate))
        }
        if !shortcut.isEmpty, HotKeyManager.isReserved(shortcut) { return .failure(.reserved) }
        let old = settings.shortcut(for: mode)
        var candidate = settings.shortcuts
        candidate[mode.rawValue] = shortcut
        do {
            try hotKeys.register(candidate.compactMap { entry in CaptureMode(rawValue: entry.key).map { candidateMode in (candidateMode, entry.value) } })
            settings.shortcuts = candidate
            persist()
            return .success(())
        } catch {
            try? hotKeys.register(settings.shortcuts.compactMap { entry in CaptureMode(rawValue: entry.key).map { currentMode in (currentMode, entry.value) } })
            settings.shortcuts[mode.rawValue] = old
            return .failure(.registrationFailed)
        }
    }

    func clearShortcut(for mode: CaptureMode) { _ = updateShortcut(.none, for: mode) }

    func setLaunchAtLogin(_ enabled: Bool) {
        Task {
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch { errorMessage = enabled ? "无法启用开机启动：\(error.localizedDescription)" : "无法关闭开机启动：\(error.localizedDescription)" }
            launchAtLogin = [SMAppService.Status.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
        }
    }

    func persist() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: settingsKey) }
    }

    func restoreDefaults() {
        let previous = settings
        do {
            try hotKeys.register(AppSettings.defaults.shortcuts.compactMap { entry in CaptureMode(rawValue: entry.key).map { mode in (mode, entry.value) } })
            settings = .defaults
            persist()
        } catch {
            settings = previous
            try? hotKeys.register(previous.shortcuts.compactMap { entry in CaptureMode(rawValue: entry.key).map { mode in (mode, entry.value) } })
            errorMessage = ShortcutValidation.registrationFailed.message
        }
    }

    func begin(_ mode: CaptureMode) {
        if recording {
            if mode == .regionRecording || mode == .displayRecording { RecordingCoordinator.shared.stop() }
            return
        }
        Task {
            await refreshPermissions()
            guard permissions[.screen] == .allowed else {
                // BRA102-01: 权限申请先于任何选区/蒙层。已询问过（拒绝/忽略）时进入权限拦截说明，
                // 绝不先创建选区蒙层再弹系统权限弹窗（现状缺陷根因）。
                if screenPermissionAsked { presentScreenPermissionInterception() }
                else { requestScreenPermission() }
                return
            }
            await CaptureCoordinator.shared.begin(mode: mode, model: self)
        }
    }

    func refreshPermissions() async {
        permissions[.screen] = .checking
        permissions[.systemAudio] = .checking
        permissions[.microphone] = .checking
        permissions[.camera] = .checking

        let screenAllowed = CGPreflightScreenCaptureAccess()
        permissions[.screen] = screenAllowed ? .allowed : .unavailable
        permissions[.systemAudio] = screenAllowed ? .allowed : .notDetermined
        permissions[.microphone] = Self.state(for: AVCaptureDevice.authorizationStatus(for: .audio))
        permissions[.camera] = Self.state(for: AVCaptureDevice.authorizationStatus(for: .video))
        NSLog("SHOTX-DEBUG permissions mic=\(permissions[.microphone]?.rawValue ?? "?") screen=\(permissions[.screen]?.rawValue ?? "?")")
    }

    private static func state(for status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: .allowed
        case .notDetermined: .notDetermined
        default: .unavailable
        }
    }

    func requestScreenPermission() {
        // BRA102-01: 任何系统权限请求发起时不得存在 .screenSaver 级蒙层。先清掉捕获浮层再申请，
        // 避免系统权限弹窗被蒙层盖住无法点击。
        CaptureCoordinator.shared.cancel()
        let firstAsk = !screenPermissionAsked
        let outcome = requestScreenAccess()
        switch outcome {
        case .granted, .denied:
            // BRA120-02: flag 仅在系统弹窗真实发出（无论授权/拒绝）后置位。
            // 请求被抑制时保持未询问，保证之后仍可再次真实申请。
            screenPermissionAsked = true
        case .suppressed:
            break
        }
        // 首次弹出被点「不允许」时不要紧接着强拉系统设置；之后再次请求才引导打开系统设置。
        if outcome == .denied, !firstAsk { openPrivacySettings(.screen) }
        Task { await refreshPermissions() }
    }

    private func presentScreenPermissionInterception() {
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "ShotX 需要屏幕录制权限才能截取或录制屏幕。内容只在这台 Mac 上处理。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { openPrivacySettings(.screen) }
    }

    func request(_ kind: PermissionKind) {
        switch kind {
        case .screen: requestScreenPermission()
        case .systemAudio: openPrivacySettings(.screen)
        case .microphone: requestMicrophoneAccess()
        case .camera: requestCameraAccess()
        }
    }

    /// 与屏幕权限同理：LSUIElement accessory 应用需先转正激活，系统权限弹窗才能真实弹出并注册 shotX。
    /// 保持激活策略直到用户在系统弹窗做出决定（回调），再恢复原策略。
    /// BRA-116：开启仅按需申请（不预置开关），授权成功且用户仍想开启才落定 `settings.microphone`。
    private func requestMicrophoneAccess() {
        let original = NSApp?.activationPolicy()
        if original != nil { NSApp?.setActivationPolicy(.regular) }
        NSApp?.activate(ignoringOtherApps: true)
        requesting = .microphone
        requestAudioAccess { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if let original { NSApp?.setActivationPolicy(original) }
                self.requesting = nil
                if granted {
                    if self.microphoneEnableIntent {
                        self.settings.microphone = true
                        self.persist()
                    }
                } else {
                    // BRA102-02/UX 标注：拒绝后对应开关自动关闭，不保留开启的假状态。
                    self.settings.microphone = false
                    self.persist()
                    self.showError("麦克风不可用。你仍可继续无麦克风录制。")
                }
                self.microphoneEnableIntent = false
                await self.refreshPermissions()
            }
        }
    }

    private func requestCameraAccess() {
        let original = NSApp?.activationPolicy()
        if original != nil { NSApp?.setActivationPolicy(.regular) }
        NSApp?.activate(ignoringOtherApps: true)
        requesting = .camera
        requestVideoAccess { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if let original { NSApp?.setActivationPolicy(original) }
                self.requesting = nil
                if granted {
                    if self.cameraEnableIntent {
                        self.settings.cameraEnabled = true
                        self.persist()
                    }
                } else {
                    self.settings.cameraEnabled = false
                    self.persist()
                    self.showError("摄像头不可用。你仍可继续无摄像头录制。")
                }
                self.cameraEnableIntent = false
                await self.refreshPermissions()
            }
        }
    }

    /// 按需申请期间记录用户「仍想开启」的意图；用户在弹窗期间关闭开关则授权回调不重新置开（BRA-116）。
    private(set) var microphoneEnableIntent = false
    private(set) var cameraEnableIntent = false
    func setMicrophoneEnableIntent(_ wants: Bool) { microphoneEnableIntent = wants }
    func setCameraEnableIntent(_ wants: Bool) { cameraEnableIntent = wants }

    func openPrivacySettings(_ kind: PermissionKind) {
        let pane = switch kind {
        case .microphone: "Privacy_Microphone"
        case .camera: "Privacy_Camera"
        case .screen, .systemAudio: "Privacy_ScreenCapture"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    func accept(_ image: CGImage) {
        recentResult = .image(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
        ResultWindowController.shared.show(image: image, model: self)
    }

    func acceptVideo(_ url: URL, saved: Bool = false) {
        recentResult = .video(url, saved: saved)
        VideoResultWindowController.shared.show(url: url, model: self)
    }

    func discardUnsavedVideoIfConfirmed() -> Bool {
        guard case .video(let url, let saved) = recentResult, !saved else { return true }
        let alert = NSAlert(); alert.messageText = "要保存这段录屏吗？"; alert.informativeText = "先从“最近一次结果”保存，或确认丢弃恢复文件。"; alert.addButton(withTitle: "返回"); alert.addButton(withTitle: "丢弃")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        do { try FileManager.default.removeItem(at: url); recentResult = nil; return true }
        catch { showError("无法丢弃恢复文件。文件仍保留，可在访达中处理。"); return false }
    }

    func setRecording(_ value: Bool) {
        recording = value
        if value {
            recordingStartedAt = Date()
            tickRecordingElapsed()
            elapsedTimer?.invalidate()
            elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tickRecordingElapsed() }
            }
        } else {
            elapsedTimer?.invalidate()
            elapsedTimer = nil
            recordingStartedAt = nil
            recordingElapsedText = nil
        }
    }

    private func tickRecordingElapsed() {
        guard let started = recordingStartedAt else { return }
        let total = Int(Date().timeIntervalSince(started))
        recordingElapsedText = String(format: "%02d:%02d", total / 60, total % 60)
    }

    var lastImage: NSImage? {
        get { if case .image(let image) = recentResult { image } else { nil } }
        set { recentResult = newValue.map(RecentResult.image) }
    }

    func showError(_ message: String) { errorMessage = message }
}

enum ShotXOutputName {
    static func make(extension pathExtension: String, date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd-HH:mm:ss"
        return "ShotX_\(formatter.string(from: date)).\(pathExtension)"
    }
}

final class HotKeyManager {
    var onTrigger: ((CaptureMode) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let manager = Unmanaged<HotKeyManager>.fromOpaque(context).takeUnretainedValue()
            if let mode = CaptureMode.allCases.indices.contains(Int(id.id)) ? CaptureMode.allCases[Int(id.id)] : nil { manager.onTrigger?(mode) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    deinit { refs.forEach { _ = UnregisterEventHotKey($0) }; if let handler { RemoveEventHandler(handler) } }

    func register(_ shortcuts: [(CaptureMode, Shortcut)]) throws {
        let old = refs
        refs = []
        old.forEach { _ = UnregisterEventHotKey($0) }
        do {
            for (mode, shortcut) in shortcuts where !shortcut.isEmpty {
                var ref: EventHotKeyRef?
                let id = EventHotKeyID(signature: OSType(0x53485458), id: UInt32(CaptureMode.allCases.firstIndex(of: mode)!))
                guard RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref else { throw ShortcutValidation.registrationFailed }
                refs.append(ref)
            }
        } catch {
            refs.forEach { _ = UnregisterEventHotKey($0) }
            refs = []
            throw error
        }
    }

    static func isReserved(_ shortcut: Shortcut) -> Bool {
        let commandSpace = shortcut.keyCode == UInt32(kVK_Space) && shortcut.modifiers & UInt32(cmdKey) != 0
        let commandTab = shortcut.keyCode == UInt32(kVK_Tab) && shortcut.modifiers & UInt32(cmdKey) != 0
        return commandSpace || commandTab || shortcut.modifiers == 0
    }
}
