import AppKit
import SwiftUI

@main
struct ShotXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            CaptureMenu(model: model)
        } label: {
            Label("ShotX", systemImage: model.permissions[.screen] == .allowed ? "camera.viewfinder" : "exclamationmark.triangle")
                .onAppear { delegate.model = model; model.start() }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: model)
                .onAppear { delegate.model = model }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async { [weak self] in self?.model?.start() }
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func becameActive() { Task { await model?.refreshPermissions() } }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { model?.discardUnsavedVideoIfConfirmed() == false ? .terminateCancel : .terminateNow }
}

private struct CaptureMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
        ForEach(Array(CaptureMode.allCases.enumerated()), id: \.element) { index, mode in
            if index == 4 { Divider() }
            Button { model.begin(mode) } label: {
                HStack { Text(mode.rawValue); Spacer(); Text(model.shortcut(for: mode).label) }
            }
        }
        Divider()
        if model.recording {
            Button("停止录制") { RecordingCoordinator.shared.stop() }
            Divider()
        }
        Menu("最近一次结果") {
            Button("复制") { copyRecent() }
            Button("保存或另存…") { saveRecent() }
            if case .image(let image) = model.recentResult { Button("贴图") { PinRecent.show(image) } }
            if case .video(let url, _) = model.recentResult { Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
        }.disabled(model.recentResult == nil)
        Divider()
        SettingsLink { Text("设置…") }
        Button("退出 ShotX") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
        }
        .alert("ShotX", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private func copyRecent() {
        NSPasteboard.general.clearContents()
        switch model.recentResult {
        case .image(let image): _ = NSPasteboard.general.writeObjects([image])
        case .video(let url, _): _ = NSPasteboard.general.writeObjects([url as NSURL])
        case nil: break
        }
    }

    private func saveRecent() {
        switch model.recentResult {
        case .image(let image):
            guard let data = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]) else { return }
            let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "ShotX.png"
            if panel.runModal() == .OK, let url = panel.url {
                do { try data.write(to: url, options: .atomic) }
                catch { model.showError("保存失败。最近结果仍保留，请重试或另存为。") }
            }
        case .video(let source, _):
            let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]; panel.nameFieldStringValue = "ShotX.mp4"
            if panel.runModal() == .OK, let url = panel.url {
                do { try FileManager.default.copyItem(at: source, to: url); model.recentResult = .video(url, saved: true) }
                catch { model.showError("保存失败。恢复文件仍保留，请重试或另存为。") }
            }
        case nil: break
        }
    }
}

@MainActor
private enum PinRecent {
    private static var windows: [NSWindow] = []
    static func show(_ image: NSImage) {
        let size = NSSize(width: min(600, image.size.width), height: min(450, image.size.height))
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .floating; window.isMovableByWindowBackground = true; window.hasShadow = true; window.contentView = NSImageView(image: image); window.center(); window.orderFront(nil); windows.append(window)
    }
}
