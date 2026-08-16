# ShotX QA 验收报告（BRA-102）

- 验收对象：BRA102-01…07（权限弹窗置顶、首次隐私默认、摄像头画中画与设置）
- 验收依据：`docs/shotx-prd-BRA102.md`、`docs/shotx-ux-ui-spec-BRA102.md`
- 验收版本：本地工作树（`agent/bra-107-font` 分支未提交改动；`Makefile` VERSION=0.1.2，本次 `make app` 重建并签名）
- 验收日期：2026-08-16
- 验收方：独立 QA（与实现者分离；实现者自测为 `swift test`/构建，本报告为独立复跑 + 独立用例补充）
- 结论：**有条件通过**（后台可验证项全部通过；依赖真实摄像头/权限弹窗的交互由用户按手测清单验证）

## 1. 需求 → 测试追踪表

| ID | 验收标准（PRD） | 验证方式 | 后台验证证据（本次） | 用户实测（手测清单） |
| --- | --- | --- | --- | --- |
| BRA102-01 | 首次启动发起权限申请且弹窗置顶可点；与「开始录屏」不冲突、不阻断 | 逻辑：`AppModel.start`→`requestScreenPermissionOnFirstLaunch` 在无任何蒙层时发起；捕获命令权限前置（`begin` 未授权先拦截，不建蒙层）；`requestScreenPermission` 先 `CaptureCoordinator.cancel()` 再申请 | ✅ `PermissionFlowTests` 3 例（首次只问一次、已授权不再问、标记跨实例持久化） | TC-PERM-01/02/03 |
| BRA102-02 | 全新安装首次录屏摄像头/麦克风默认关闭，不自动弹权限 | 逻辑：`AppSettings` 默认 `microphone=false`、`cameraEnabled=false`；首次启动仅申请屏幕权限，不申请摄像头/麦克风 | ✅ `testFreshInstallRecordingDefaultsDisableCameraAndMicrophone` | TC-PERM-04 |
| BRA102-03 | 开启摄像头开关立即启动摄像头并预览，无需等录制 | 逻辑：`setCamera(true)`→ 权限就绪即 `startCameraSession()`（`.allowed` 直接启动；`.notDetermined` 授权回调 `cameraPermissionChanged` 后启动） | ✅ 代码走查；依赖真实摄像头，无头环境不可执行 | TC-CAM-01/08 |
| BRA102-04 | 圆角正方形、选区左下角、带 margin | 布局函数 `CameraOverlayLayout.rect`（左下角 12pt margin、正方形、圆角 12pt、夹紧不超选区） | ✅ `testCameraOverlayStaysInsideRecordedRegion` + QA 补充 5 例（任意宽高比锚定左下、margin、正方形） | TC-CAM-02 |
| BRA102-05 | 两档尺寸（小/大），选择后实时生效 | `CameraOverlaySize` 96/192 pt，夹紧规则（`min(w,h)−2×margin`，<64pt 隐藏并提示）；预览与成片共用同一布局函数，仅坐标系/缩放因子不同 | ✅ `testCameraOverlayTwoSizesPresetsAndClamping`、`testCameraOverlayPreviewAndOutputShareLayoutAtScale` + QA 补充（精确边界 88/87pt、@2x 192/384px） | TC-CAM-03/07 |
| BRA102-06 | 模糊背景/美颜/镜像开关（系统支持时显示并生效） | 模糊背景：`supportsBackgroundBlur()`（`isPortraitEffectSupported`）才显示，实际生效以系统「人像效果」为准（`isPortraitEffectActive`，不假实现）；美颜：macOS 无系统 API，本版不实现（隐藏）；镜像：始终可用、默认开 | ✅ 代码走查 + `testCameraSettingsDefaultsAndRoundTrip`（尺寸/镜像/模糊默认值与持久化） | TC-CAM-04/05/06 |
| BRA102-07 | 设置态预览与成片位置/尺寸/形态一致，不超出选区 | 预览窗与成片合成均调用 `CameraOverlayLayout.rect`（预览 scale=1 点坐标；成片 scale=backingScaleFactor 像素坐标），夹紧规则保证不超选区 | ✅ `testCameraOverlayPreviewAndOutputShareLayoutAtScale` + QA 补充（两种尺寸 @2x 逐像素等价） | TC-CAM-02/07/09 |

## 2. 团队后台测试闭环证据（独立复跑，未操控桌面）

执行环境：macOS（Apple Silicon arm64，Swift 6.3.3，Xcode CLT），本地工作树含 BRA-102 未提交改动。

| 步骤 | 命令 | 结果 | 证据 |
| --- | --- | --- | --- |
| 冷缓存单测 | `swift test` | ✅ | **85/85 通过，0 failures**（80 原有 + 新增 QA 5 例） |
| Release 构建 | `make app` | ✅ | Release build 完成，`ShotX.app` 已签名，Info.plist 写入 0.1.2 |
| 签名校验 | `codesign --verify --deep --strict --verbose=2 ShotX.app` | ✅ | `valid on disk`，`satisfies its Designated Requirement` |
| 静默冒烟启动 | `open ShotX.app` + `pgrep -x ShotX` + 退出 | ✅ | 进程存活并干净退出 |
| 静态检查（无网络） | `rg -i "urlsession\|urlrequest\|nwconnection" Sources/ShotX --glob '*.swift'` | ✅ | Swift 源码无网络代码（仅 SVG 资源 `xmlns` 命名空间，非网络） |
| 权限用途声明 | `plutil -p ShotX.app/Contents/Info.plist` | ✅ | `NSCameraUsageDescription` / `NSMicrophoneUsageDescription` 均已随包 |

### 2.1 独立补充用例（`Tests/ShotXTests/QACameraOverlayTests.swift`，本验收新增）

- `testQAOverlayAnchorsBottomLeftWithMarginForAnyAspectRatio`：5 种宽高比、两种尺寸，均锚定左下 12pt、正方形、不超选区（BRA102-04/07）
- `testQAOverlayClampBoundaryExactlyAtMinimum`：88×88 恰好容纳（64pt 档）、87×87 隐藏、宽扁选区按最小边夹紧（BRA102-05）
- `testQAOverlayPreviewAndOutputMatchForBothSizesAtScale2`：小/大两档在 scale=2 下预览与成片逐像素等价（BRA102-07）
- `testQAOverlayPixelSizesMatchPRDAt2x`：@2x 成片 192/384 px（BRA102-05 像素规格）
- `testQACameraSettingsDefaultsMatchSpec`：默认尺寸大、镜像开、模糊关、摄像头关（BRA102-02/06）

## 3. 缺陷 / 观察项

### D1（残余风险，需用户实测确认）— O-RSET 内开启摄像头触发的系统权限弹窗可能被面板遮挡

- **复现步骤**：首次启动进入区域录屏设置面板（O-RSET，`screenSaver+1` 级）→ 展开摄像头菜单 → 开启「启用摄像头」（此时摄像头权限为「未询问」）。
- **期望**：系统摄像头权限弹窗出现在最上层、可点击（UX 标注 §1.3 规则 3）。
- **实际**：代码在 `setCamera`→`model.request(.camera)` 时**未**对 `screenSaver+1` 级面板做降级/避让处理；系统弹窗层级若低于面板则可能被遮挡、无法点击（正是 BRA-102 要解决的原始问题类别，只是本次针对摄像头权限）。
- **影响**：首启首次开启摄像头时若弹窗被挡，用户无法授权 → 画中画功能受阻。中。
- **后台可验证部分**：无头环境无法触发真实 TCC 弹窗，此项必须由用户按 TC-CAM-01 实测确认。若实测可点，则关闭；若被挡，属阻断项，需在请求前降级面板层级。

### D2（观察项，设计取舍）— 模糊背景开关不主动开启系统效果

- **现象**：`applyBackgroundBlur` 仅读取 `device.isPortraitEffectActive`（系统「人像效果」只读状态），应用无法编程强制开启。用户开启「模糊背景」时，若系统人像效果未开启，代码会回退开关并提示「背景模糊需要系统『人像效果』支持。请在控制中心开启后重试。」。
- **评估**：符合 PRD §5「以系统能力为限，不得以假实现冒充」；属诚实呈现，非缺陷。用户体验上开关本身不直接生效，需用户手测确认提示与回退行为可接受（TC-CAM-05）。

### D3（观察项，低）— 摄像头画中画方向/旋转需真实设备确认

- **现象**：预览用 `AVCaptureVideoPreviewLayer`（自动适配设备方向），成片合成用原始 `AVCaptureVideoDataOutput` 帧（`resizeAspectFill` + 可选水平镜像）。两者方向口径可能不同（尤其非内建摄像头），需真实录制逐像素对比。
- **影响**：若不一致则 BRA102-07 未达成。低（内建摄像头通常一致）。由 TC-CAM-09 实测。

## 4. 结论

**有条件通过。** 后台可验证项全部通过：85/85 单测（含独立 QA 补充 5 例）、Release 构建、签名、冒烟、静态检查、权限用途声明齐全；BRA102-01/02/04/05/07 的逻辑部分已有明确后台证据，BRA102-03/06 逻辑走查成立。剩余项（真实权限弹窗可点性 D1、模糊背景实际效果 D2、成片方向一致性 D3）依赖真实摄像头与系统权限弹窗，由用户按 `QA-MANUAL-TEST-CHECKLIST-BRA-102.md` 实测；其中 D1 若实测弹窗被 O-RSET 面板遮挡，应升级为阻断项并修复。
