import AppKit
import AVFoundation
import Carbon.HIToolbox
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var tab = Tab.shortcuts
    @State private var resetConfirmation = false

    enum Tab: String, CaseIterable, Identifiable {
        case shortcuts = "快捷键", screenshot = "截图", recording = "录屏", permissions = "权限"
        var id: String { rawValue }
        var symbol: String {
            switch self { case .shortcuts: "keyboard"; case .screenshot: "camera.viewfinder"; case .recording: "video"; case .permissions: "lock.shield" }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: $tab) { item in Label(item.rawValue, systemImage: item.symbol).tag(item) }
                .navigationSplitViewColumnWidth(min: 150, ideal: 170)
        } detail: {
            Group {
                switch tab {
                case .shortcuts: ShortcutsPane(model: model)
                case .screenshot: ScreenshotPane(model: model)
                case .recording: RecordingPane(model: model)
                case .permissions: PermissionsPane(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { Button("恢复默认…") { resetConfirmation = true } }
            }
        }
        .frame(minWidth: 680, minHeight: 460)
        .confirmationDialog("恢复截图与录屏默认设置？", isPresented: $resetConfirmation) {
            Button("恢复默认", role: .destructive) { model.restoreDefaults() }
            Button("取消", role: .cancel) {}
        } message: { Text("不更改系统权限，不删除素材或最近结果。") }
    }
}

private struct PaneTitle: View {
    let title: String
    let detail: String
    var body: some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.title2.bold()); Text(detail).foregroundStyle(.secondary) }.padding(.bottom, 14) }
}

private struct ShortcutsPane: View {
    @ObservedObject var model: AppModel
    @State private var errors: [CaptureMode: String] = [:]

    var body: some View {
        VStack(alignment: .leading) {
            PaneTitle(title: "快捷键", detail: "点击快捷键后按下新组合；保存失败会保留旧值。")
            Form {
                ForEach(CaptureMode.allCases) { mode in
                    LabeledContent(mode.rawValue) {
                        VStack(alignment: .trailing, spacing: 3) {
                            ShortcutRecorder(shortcut: model.shortcut(for: mode)) { candidate in
                                switch model.updateShortcut(candidate, for: mode) {
                                case .success: errors[mode] = nil
                                case .failure(let error): errors[mode] = error.message
                                }
                            }
                            if let error = errors[mode] { Text(error).font(.caption).foregroundStyle(.red) }
                        }
                    }
                }
            }
        }
    }
}

private struct ScreenshotPane: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading) {
            PaneTitle(title: "截图", detail: "PNG 始终使用目标显示器的物理像素。")
            Toggle("窗口截图保留阴影", isOn: binding(\.windowShadow))
            LabeledContent("默认完成动作", value: "复制")
            LabeledContent("最近保存目录", value: model.settings.lastSaveDirectory ?? "首次保存时选择")
        }.onChange(of: model.settings) { model.persist() }
    }
    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> { Binding(get: { model.settings[keyPath: keyPath] }, set: { model.settings[keyPath: keyPath] = $0 }) }
}

private struct RecordingPane: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading) {
            PaneTitle(title: "录屏", detail: "MP4 输出选区原始物理像素尺寸；来源只在你开启时申请权限。")
            Toggle("系统声音", isOn: toggle(\.systemAudio, permission: .systemAudio))
            Toggle("麦克风", isOn: toggle(\.microphone, permission: .microphone))
            Picker("麦克风设备", selection: plain(\.selectedMicrophoneID)) { Text("系统默认").tag(""); ForEach(Self.audioDevices(), id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) } }.disabled(!model.settings.microphone)
            Toggle("显示指针", isOn: plain(\.showsCursor))
            Toggle("显示点击反馈", isOn: plain(\.showsClicks))
            Stepper("倒计时：\(model.settings.countdown) 秒", value: plain(\.countdown), in: 0...5)
        }.onChange(of: model.settings) { model.persist() }
    }
    private func plain<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> { Binding(get: { model.settings[keyPath: keyPath] }, set: { model.settings[keyPath: keyPath] = $0 }) }
    private func toggle(_ keyPath: WritableKeyPath<AppSettings, Bool>, permission: PermissionKind) -> Binding<Bool> {
        Binding(get: { model.settings[keyPath: keyPath] }, set: { value in model.settings[keyPath: keyPath] = value; if value { model.request(permission) } })
    }
    private static func audioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }
}

private struct PermissionsPane: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading) {
            PaneTitle(title: "权限", detail: "屏幕权限阻断捕获；其他来源未启用前不会请求。")
            ForEach(PermissionKind.allCases) { kind in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon(kind)).frame(width: 24).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) { Text(kind.rawValue).fontWeight(.medium); Text(kind.purpose).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text(model.permissions[kind]?.rawValue ?? "正在检查…").foregroundStyle(model.permissions[kind] == .allowed ? .green : .secondary)
                    Button(model.permissions[kind] == .allowed ? "重新检测" : actionTitle(kind)) { if model.permissions[kind] == .allowed { Task { await model.refreshPermissions() } } else { model.request(kind) } }
                }.padding(.vertical, 10)
                Divider()
            }
        }
    }
    private func icon(_ kind: PermissionKind) -> String { switch kind { case .screen: "display"; case .systemAudio: "speaker.wave.2"; case .microphone: "mic" } }
    private func actionTitle(_ kind: PermissionKind) -> String { model.permissions[kind] == .notDetermined ? "允许…" : "打开系统设置" }
}

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: Shortcut
    let onChange: (Shortcut) -> Void
    func makeNSView(context: Context) -> ShortcutButton { let view = ShortcutButton(); view.onChange = onChange; view.shortcut = shortcut; return view }
    func updateNSView(_ view: ShortcutButton, context: Context) { if !view.recording { view.shortcut = shortcut } }
}

final class ShortcutButton: NSButton {
    var onChange: ((Shortcut) -> Void)?
    var shortcut = Shortcut.defaults[.region]! { didSet { title = shortcut.label } }
    fileprivate var recording = false
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); bezelStyle = .rounded; setButtonType(.momentaryPushIn); target = self; action = #selector(beginRecording); toolTip = "点击后按下包含修饰键的快捷键" }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func beginRecording() { recording = true; title = "请按快捷键…"; window?.makeFirstResponder(self) }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { carbon |= UInt32(shiftKey) }
        if modifiers.contains(.option) { carbon |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbon |= UInt32(controlKey) }
        guard carbon != 0, event.keyCode != UInt16(kVK_Escape) else { recording = false; title = shortcut.label; return }
        recording = false
        let candidate = Shortcut(keyCode: UInt32(event.keyCode), modifiers: carbon)
        title = shortcut.label
        onChange?(candidate)
    }
}
