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
| FR-CAP-08 | `PinWindowController` move/resize/opacity/close | release build | M |
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

## BRA-71 交付（FR-BRA71-01…06）

| FR | Implementation | Development evidence |
| --- | --- | --- |
| FR-BRA71-01 | 马赛克改为矩形对象：`AnnotationView.mosaic(rect:size:)` 填充整块矩形像素化；样式标签「笔刷大小」→「块大小」；两轴 < 4 pt 拖拽丢弃；对象就地保留、可选择/拖动/删除/撤销 | `testMosaicDragCreatesRectangularObject`、`testMosaicTinyDragIsDiscarded`、`testMosaicStyleLabelUsesBlockSize` |
| FR-BRA71-02 | 画笔新增 `Annotation.path` 对象：拖动期间逐事件采样点，`AnnotationMath.smoothPath`（Catmull-Rom→三次贝塞尔）渲染平滑曲线；总长 < 2 pt 提交圆点；命中测试按到路径距离 ≤ max(粗细/2, 8) pt，不退化包围盒 | `testPenFollowsMouseWithSmoothPath`、`testPenClickBecomesDot`、`testSmoothPathUsesBezierCurvesNotStraightLines`、`testPathHitTestUsesDistanceNotBoundingBox` |
| FR-BRA71-03 | 所有对象就地呈现并复用选择/移动/方向键/Delete/历史栈；直线/箭头/路径按距离命中 | `testSelectedPathMovesWithDrag`、`testClickFarFromStrokeDoesNotMoveIt` |
| FR-BRA71-04 | 文字改为画布内就地编辑：单击创建 `InlineTextView`（无 `NSAlert`），Return/Esc/点击外部提交，双击文字重入编辑，空文字提交删除，编辑中样式即时反映 | `testTextCommitsInlineWithoutModalAndIsSelectable`、`testDoubleClickReentersTextEditing`、`testEmptyTextCommitCreatesNothingAndEmptyEditDeletes`、`testTextObjectDragMovesWithoutEnteringEdit` |
| FR-BRA71-05 | 移除系统分享：`ResultWindow` 分享按钮与 `NSSharingServicePicker` 调用、`CaptureCoordinator` `sharePressed`/`pendingShareImage`/picker delegate 全部删除；菜单栏无分享入口；工具栏输出行为 复制/保存/贴图/关闭 | 静态检查无 `NSSharingServicePicker`/分享引用；`swift test` 通过 |
| FR-BRA71-06 | 录屏设置菜单中心锚定：`RecordingSetupLayout.frame` 默认菜单中心 = 选区中心并随选区变化重锚定；选区任一向小于面板或溢出可见区时按 下→上→侧边 避让链，最后贴边钳制；「开始录制」后面板隐藏且不进入成片 | `testRecordingSetupPanelCentersOnLargeSelection`、`testRecordingSetupPanelAvoidsTinySelectionBelow`、`testRecordingSetupPanelTallSelectionKeepsHorizontalCenter`、`testRecordingSetupPanelFallsBackInsideVisibleFrame` |

后台自测闭环（BRA-73 交付运行结果）：

- `swift test`（clean）→ 55/55 通过，0 failures（新增 `BRA71AnnotationTests` 17 例；`testLiveAnnotationStyleDrivesNextStrokeAndRestores` 随画笔对象模型更新为 `.path` 断言）
- 静态检查 → 源码无 `NSSharingServicePicker`、`sharePressed`、`shareImage`、`pendingShareImage` 残留
- 桌面交互（马赛克矩形预览、自由画笔手感、文字就地编辑、双击重入、录屏菜单中心跟随）归用户手测，随 `ShotX.app.zip` + 手测清单交付
