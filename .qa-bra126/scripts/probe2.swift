import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit

func log(_ s: String) { print(s) }

let mainID = CGMainDisplayID()
log("CGMainDisplayID=\(mainID) pixels=\(CGDisplayPixelsWide(mainID))x\(CGDisplayPixelsHigh(mainID)) bounds=\(CGDisplayBounds(mainID))")

log("frontmostApplication=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") bundle=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map { "\($0.localizedName ?? "?")(\($0.bundleIdentifier ?? "?"))" }
log("regular apps: \(apps.joined(separator: ", "))")

// Try to determine CGWindowList ordering convention: frontmost first or last?
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
log("onscreen list order (layer 0 only):")
for (i, w) in list.enumerated() {
    let layer = w[kCGWindowLayer as String] as? Int ?? -999
    guard layer == 0 else { continue }
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let num = w[kCGWindowNumber as String] as? Int ?? -1
    let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let x = bounds["X"] as? Double ?? 0, y = bounds["Y"] as? Double ?? 0
    let width = bounds["Width"] as? Double ?? 0, height = bounds["Height"] as? Double ?? 0
    log("  idx=\(i) num=\(num) owner=\(owner) bounds=\(x),\(y),\(width),\(height)")
}

// All windows in the global list (includes offscreen), to infer internal ordering
let allList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
log("all-windows order (layer 0, any screen state):")
for (i, w) in allList.enumerated() {
    let layer = w[kCGWindowLayer as String] as? Int ?? -999
    guard layer == 0 else { continue }
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let num = w[kCGWindowNumber as String] as? Int ?? -1
    let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
    log("  idx=\(i) num=\(num) owner=\(owner) onscreen=\(onscreen)")
}

exit(0)
