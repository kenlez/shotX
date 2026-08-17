import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit

func log(_ s: String) { print(s); FileHandle.standardError.write(("LOG: " + s + "\n").data(using: .utf8)!) }

log("=== probe start ===")

// Screen info
for (i, screen) in NSScreen.screens.enumerated() {
    let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    log("screen[\(i)] frame=\(screen.frame) scale=\(screen.backingScaleFactor) device=\(n?.uint32Value ?? 0)")
}
let main = NSScreen.main
log("main screen frame=\(main?.frame) scale=\(main?.backingScaleFactor)")

// SCShareableContent
do {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    log("SCShareableContent OK: windows=\(content.windows.count) displays=\(content.displays.count)")
    for (i, w) in content.windows.enumerated() {
        let app = w.owningApplication?.bundleIdentifier ?? "?"
        let title = w.title ?? ""
        log("  SC[\(i)] frame=\(w.frame) layer=\(w.windowLayer) onScreen=\(w.isOnScreen) app=\(app) title=\(title)")
    }
} catch {
    log("SCShareableContent FAILED: \(error)")
}

// CGWindowList
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? []
log("CGWindowList count=\(list.count)")
for (i, w) in list.enumerated() {
    let num = w[kCGWindowNumber as String] as? Int ?? -1
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let x = bounds["X"] as? Double ?? 0, y = bounds["Y"] as? Double ?? 0
    let width = bounds["Width"] as? Double ?? 0, height = bounds["Height"] as? Double ?? 0
    let layer = w[kCGWindowLayer as String] as? Int ?? -999
    let alpha = w[kCGWindowAlpha as String] as? Double ?? -1
    let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
    log("  CG[\(i)] num=\(num) owner=\(owner) layer=\(layer) alpha=\(alpha) onscreen=\(onscreen) bounds=\(x),\(y),\(width),\(height)")
}

// Accessibility check for this process
let trusted = AXIsProcessTrusted()
log("AXIsProcessTrusted=\(trusted)")

exit(0)
