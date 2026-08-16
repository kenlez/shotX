# P0 implementation trace

验证标记（BRA-35/38 修订版）：`B` = 已后台自动验证（`swift test` / `make app` / 签名校验 / 静默冒烟）；`M` = 待用户包体验证（依赖真实桌面/硬件，随 `ShotX.app.zip` + 手测清单交付）；`B+M` = 后台可验证部分已验，桌面交互部分待用户实测。

| Requirement | Implementation | Development evidence | 验证 |
| --- | --- | --- | --- |
| FR-BASE-01 | `ShotXApp.swift` menu bar and capture entries | Signed app smoke launch | B+M |
| FR-BASE-02 | `AppModel.swift` `HotKeyManager` and rollback | `testRejectedDuplicateKeepsOldShortcut` | B+M |
| FR-BASE-03/04 | `AppModel.swift` permission state/request; `SettingsView.swift` permission rows | Settings/permission code build | M |
| FR-BASE-05 | `AppSettings`, persistence and restore | round-trip, style persistence and restore tests | B |
| FR-CAP-01/02/03 | `CaptureCoordinator.swift` display/window selection, shadow and physical pixels | release build; physics-pixel output-size tests | B+M |
| FR-CAP-04/05 | `ResultWindow.swift` `AnnotationView` tools, selection/move/delete and 20-state history | release build; style persistence tests | B+M |
| FR-CAP-06/07 | `ResultWindow.swift` flattened render, clipboard, PNG, share and pixelated mosaic | release build | M |
| FR-CAP-08 | `PinWindowController` move/resize/opacity/close; BRA-94: capsule slider (23 pt track/knob), live % readout (opacity/zoom), mouseUp 100% snap; BRA-98: `PinPanel` key-capable borderless `NSPanel`, Cmd+W closes window / Esc hides controls (§8.7, no file/result deletion) | `testPercentReadoutFormatsIntegerPercent`, `testSnapOnlyWithinTenPercentOfTarget`, `testSliderStyleMatchesDesignAnnotation`, `testZoomReadoutUpdatesInRealTimeOnWheelZoom`, `testOpacityReadoutUpdatesInRealTimeOnSliderChange`, `testPinPanelCanBecomeKey`, `testCommandWClosesWindowWithoutTouchingFileOrRecentResult`, `testEscapeHidesControlsButKeepsWindowOpen`, `testEscapeKeyDownHidesControlsButKeepsWindowOpen`, `testEscapeAfterHoverShowsThenHidesControls`; release build | B+M |
| FR-CAP-09 | `CaptureCoordinator.swift` frozen full-screen selecting/editing/committed state; reused `AnnotationView` with point-sized preview and native-pixel output | `testRegionCaptureOnlyCommitsFromEditing`; release build | B+M |
| FR-CAP-10 | region selection geometry ↔ frozen CGImage pixel space unified in `AnnotationView.cgPixelRect`/`clampedCrop` and `render()`; upright crop instead of `draw(in:from:)` coordinate guessing; mosaic samples CG pixel rect | `testRegionPixelRectMapsYUpSelectionToCGTopLeft`, `testRegionRenderIsNotFlippedOrMirrored`; release build | B+M |
| FR-CAP-11/12 | fixed-size toolbar (`toolbarFixedSize`); color button opens floating `NSPanel` below toolbar with preset swatches + eyedropper that samples the frozen screen CGImage pixels (no overlay interception), anchored at cursor | release build; build passes; interaction is user-verified | B+M |
| FR-CAP-13 | `SelectionView` double-click / Space = `quickCopy` (copy+exit); Space in region-recording selection = `onQuickRecord` → `RecordingCoordinator.startImmediately`; Return keeps settings flow | release build; interaction is user-verified | B+M |
| FR-CAP-14/15/16 | fixed element set toolbar (7 tools + undo/redo + fixed 84 pt "样式" button + copy/save/share/pin/close), `toolbarFixedSize` computed once, `updateStyleControls` only updates the "样式" summary and options panel (no inline hide/show); options panel = 300 pt `NSPanel` (`OptionsPanel`, key-capable) anchored below toolbar with down→up→edge avoidance, containing memory echo + 12 preset swatches w/ accent+checkmark selected state + eyedropper + `BrushSlider` (continuous 1–8/11–32/8–40) with preset buttons; drag live-applies (`applyStyleLive`, no history pollution), `mouseUp`/preset/keyboard commit to `annotationSizes` and persist | `testToolStyleRangesMatchFRCAP16`; release build; interaction is user-verified | B+M |
| FR-LONG-01/02 | `ScrollingCaptureCoordinator.swift` overlap matching and live preview | release build; fixture corpus remains user validation | M |
| FR-LONG-03/04 | match/fast/horizontal pause, undo and frozen limits | `testFrozenDiskAndLongCaptureThresholds` | B+M |
| FR-REC-01 | `CaptureCoordinator` selection; `ScreenRecorder` excludes ShotX application | release build; hardware case remains user validation | M |
| FR-REC-02 | separate system/microphone AAC inputs and device picker | release build; A/V sync remains user validation | M |
| FR-REC-03 | removed: no camera entries/preview/composition/permission requests anywhere (BRA-40) | `RecordingSetupView`/`ScreenRecorder`/`AppSettings`/`PermissionKind` camera branches removed; build+test pass | B |
| FR-REC-04 | ScreenCaptureKit cursor and composed 300 ms click ring | `testClickCoordinatesMapIntoRecordedRegion` | B+M |
| FR-REC-05/06 | countdown, status window, menu/status stop | signed app smoke launch | M |
| FR-REC-11 | compact 300×320 three-section menu (fixed title/scrollable body/fixed footer); sound/mouse/original-size/countdown only; start button always visible; output locked to selection physical pixels, no resolution options; setup panel keeps the interactive `SelectionView` alive so the selection stays movable/resizable and "原始尺寸" refreshes live until 开始录制 | `testRecordingOutputSizeUsesPhysicalPixels`, `testSetupOriginalSizeDisplayAlwaysMatchesVideoTrackPixels`; release build; panel interaction remains user validation. QA 复测（BRA-48）通过：`swift test` 29/29（含 BRA-45 新增用例）、`make app`+签名校验、冒烟启动、静态检查（无摄像头残留/无网络新增）均通过；桌面交互归用户手测 `QA-MANUAL-TEST-CHECKLIST-BRA-45.md` | B+M |
| FR-REC-12 | `RecordingRegionOverlayController` created only when 开始录制 locks the live geometry (selection released via `CaptureCoordinator.cancel()`); four click-through mask windows and textual high-contrast region state excluded with the ShotX process | `testRecordingOverlayStateTransitions`; multi-display hardware remains user validation | B+M |
| FR-REC-07 | AVPlayer preview and AVFoundation head/tail export | `testVideoTrimFractionsRemainOrderedAndBounded` | B+M |
| FR-REC-08 | copy/save/Finder plus close/app-quit unsaved confirmation | release build | M |
| FR-REC-09 | 2 GB start, 1 GB warning, 500 MB stop, Recovery source | `testFrozenDiskAndLongCaptureThresholds` | B+M |
| FR-REC-10 | AV device disconnect observer; microphone silence | release build; hot-unplug remains user validation | M |
| BRA-107 (字体) | `Package.swift` 将 `font` 目录 `.process` 进 target resources；`AppFonts.register()`（`CTFontManagerRegisterFontsForURL`）启动注册内嵌 Alimama 字体；`AppFonts.annotationFont(size:)` 单一工厂替换 `ResultWindow.swift` 文字标注 6 处调用（编辑框/测量/绘制/命中 bounds 同一字体）；其余界面按设计矩阵保留系统/等宽字体，缺失字形 AppKit 逐字形回退 | `testAnnotationFontFactoryFallsBackToSystemFontWhenNotRegistered`、`testAnnotationFontFactoryResolvesAlimamaAfterRegistration`、`testBundledFontResourceIsPackaged`；release build；bundle/app 内含 `AlimamaFangYuanTiVF-Bold-sub.ttf` | B+M |

后台自测闭环（本次 BRA-43 交付运行结果，见 `QA-BACKGROUND-TEST-LOOP.md`）：

- `swift test` → 12/12 通过，0 failures（新增 `testRegionPixelRectMapsYUpSelectionToCGTopLeft`、`testRegionRenderIsNotFlippedOrMirrored`）
- `make app` → release 构建成功，`ShotX.app` 已签名
- `codesign --verify --deep --strict --verbose=2 ShotX.app` → valid on disk，satisfies its Designated Requirement
- 静默冒烟启动 → 进程存活并正常退出
- `make package` → 产出 `ShotX.app.zip`、`ShotX-source.zip` 作为分发附件

QA 复测闭环（BRA-48，2026-08-12）：

- `swift test`（clean）→ 29/29 通过，0 failures（含 BRA-45 新增 `testSetupOriginalSizeDisplayAlwaysMatchesVideoTrackPixels`，13/13 SettingsTests）
- `make app` → release 构建成功（存在 1 条非阻断并发警告：`menuTracking` 从 Sendable closure 变更，主线程队列观察者，功能不受影响）
- `codesign --verify --deep --strict --verbose=2 ShotX.app` → valid on disk，satisfies its Designated Requirement
- 静默冒烟启动 → 进程启动后存活、退出干净
- 静态检查 → 无网络代码；无摄像头捕获残留（AVCaptureDevice/Session 仅限音频媒体类型，`mediaType: .audio`）
- 桌面交互（选区拖动/缩放、原始尺寸实时刷新、开始后锁定、Esc 返回）归用户手测，由 `QA-MANUAL-TEST-CHECKLIST-BRA-45.md` 8 条 TC 覆盖，本机不执行桌面操控

后台自测闭环（本次 BRA-54 交付运行结果）：

- `swift test`（clean）→ 30/30 通过，0 failures（新增 `testToolStyleRangesMatchFRCAP16`，覆盖 FR-CAP-16 各工具拖拽范围/离散档位/默认值）
- `make app` → release 构建成功；仅剩 1 条 BRA-48 已记录的并发警告（`menuTracking`），无新增编译告警
- `codesign --verify --deep --strict --verbose=2 ShotX.app` → valid on disk，satisfies its Designated Requirement
- 静默冒烟启动 → 进程启动后存活、退出干净
- 静态检查 → 无网络代码；无摄像头捕获残留
- 桌面交互（固定元素集、工具选项浮层展开/避让/关闭、可拖拽笔刷大小实时生效与记忆、VoiceOver/键盘可达）归用户手测，随 `ShotX.app.zip` + 手测清单交付
