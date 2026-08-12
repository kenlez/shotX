import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum CaptureMode: String, CaseIterable, Identifiable {
    case region = "区域截图"
    case window = "窗口截图"
    case display = "全屏截图"
    case scrolling = "滚动截图"
    case regionRecording = "区域录屏"
    case displayRecording = "显示器录屏"

    var id: String { rawValue }
    var isRegion: Bool { self == .region || self == .scrolling || self == .regionRecording }
    var isDisplay: Bool { self == .display || self == .displayRecording }
    var isFoundationOnly: Bool { self == .scrolling || self == .regionRecording || self == .displayRecording }
}

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let defaults: [CaptureMode: Shortcut] = [
        .region: .init(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey)),
        .window: .init(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey | optionKey)),
        .display: .init(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey)),
        .scrolling: .init(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey | shiftKey)),
        .regionRecording: .init(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | shiftKey)),
        .displayRecording: .init(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | shiftKey | controlKey))
    ]

    var label: String {
        let flags: [(UInt32, String)] = [(UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"), (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘")]
        let names: [UInt32: String] = [
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9", UInt32(kVK_ANSI_R): "R"
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
    var selectedMicrophoneID = ""
    var showsCursor = true
    var showsClicks = true
    var countdown = 3
    var annotationColors = Dictionary(uniqueKeysWithValues: AnnotationTool.styledCases.map { ($0.rawValue, "#FF3B30") })
    var annotationSizes = Dictionary(uniqueKeysWithValues: AnnotationTool.styledCases.map { ($0.rawValue, $0 == .text ? 16.0 : $0 == .mosaic ? 16.0 : 2.0) })
    var lastSaveDirectory: String?
    var shortcuts = Dictionary(uniqueKeysWithValues: CaptureMode.allCases.map { ($0.rawValue, Shortcut.defaults[$0]!) })

    static let defaults = AppSettings()
    func shortcut(for mode: CaptureMode) -> Shortcut { shortcuts[mode.rawValue] ?? Shortcut.defaults[mode]! }
}

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select = "选择", arrow = "箭头", rectangle = "矩形", pen = "画笔", text = "文字", mosaic = "马赛克", crop = "裁剪"
    var id: String { rawValue }
    static let styledCases: [AnnotationTool] = [.arrow, .rectangle, .pen, .text, .mosaic]

    /// Continuous draggable brush range and discrete preset values for the tool options popover (FR-CAP-15/16).
    var styleRange: (min: Double, max: Double, presets: [Double], unit: String) {
        switch self {
        case .text: (11, 32, [11, 13, 16, 24, 32], "pt")
        case .mosaic: (8, 40, [8, 16, 24, 40], "px")
        case .select, .crop: (0, 0, [], "")
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

    static func defaultSize(for tool: AnnotationTool) -> Double { tool == .text ? 16 : tool == .mosaic ? 16 : 2 }
}

enum RecentResult {
    case image(NSImage)
    case video(URL, saved: Bool)
}

enum PermissionKind: String, CaseIterable, Identifiable {
    case screen = "屏幕录制"
    case systemAudio = "系统音频"
    case microphone = "麦克风"
    var id: String { rawValue }
    var purpose: String {
        switch self {
        case .screen: "截取或录制屏幕；内容只在这台 Mac 上处理。"
        case .systemAudio: "仅在录屏时写入电脑声音。"
        case .microphone: "仅在你启用麦克风录制时申请。"
        }
    }
}

enum PermissionState: String {
    case notDetermined = "使用时询问"
    case allowed = "已允许"
    case unavailable = "不可用"
    case checking = "正在检查…"
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings
    @Published private(set) var permissions = Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, PermissionState.checking) })
    @Published var errorMessage: String?
    @Published var recentResult: RecentResult?
    @Published private(set) var recording = false

    private let defaults: UserDefaults
    private let settingsKey = "settings.v1"
    private let hotKeys = HotKeyManager()
    private var started = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.data(forKey: settingsKey).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? .defaults
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
        Task { await refreshPermissions() }
    }

    func shortcut(for mode: CaptureMode) -> Shortcut { settings.shortcut(for: mode) }

    func updateShortcut(_ shortcut: Shortcut, for mode: CaptureMode) -> Result<Void, ShortcutValidation> {
        if let duplicate = CaptureMode.allCases.first(where: { $0 != mode && settings.shortcut(for: $0) == shortcut }) {
            return .failure(.duplicate(duplicate))
        }
        if HotKeyManager.isReserved(shortcut) { return .failure(.reserved) }
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
                requestScreenPermission()
                return
            }
            await CaptureCoordinator.shared.begin(mode: mode, model: self)
        }
    }

    func refreshPermissions() async {
        permissions[.screen] = .checking
        permissions[.systemAudio] = .checking
        permissions[.microphone] = .checking

        let screenAllowed = CGPreflightScreenCaptureAccess()
        permissions[.screen] = screenAllowed ? .allowed : .unavailable
        permissions[.systemAudio] = screenAllowed ? .allowed : .notDetermined
        permissions[.microphone] = Self.state(for: AVCaptureDevice.authorizationStatus(for: .audio))
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
        if !CGRequestScreenCaptureAccess() { openPrivacySettings(.screen) }
        Task { await refreshPermissions() }
    }

    func request(_ kind: PermissionKind) {
        switch kind {
        case .screen: requestScreenPermission()
        case .systemAudio: openPrivacySettings(.screen)
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in Task { await self?.refreshPermissions() } }
        }
    }

    func openPrivacySettings(_ kind: PermissionKind) {
        let pane = kind == .microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
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

    func setRecording(_ value: Bool) { recording = value }

    var lastImage: NSImage? {
        get { if case .image(let image) = recentResult { image } else { nil } }
        set { recentResult = newValue.map(RecentResult.image) }
    }

    func showError(_ message: String) { errorMessage = message }
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
            for (mode, shortcut) in shortcuts {
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
