# ShotX QA 验收报告（BRA-113：录屏音频修复 + 录屏 UI 实现）

- 验收对象：BRA113-A1…A4（录屏音频）、BRA113-U1…U5（录屏 UI）、P1…P3（打包，本次仅登记构建证据，出包归 BRA-119）
- 验收依据：`docs/shotx-prd-BRA113.md`、`docs/shotx-ux-ui-spec-BRA113.md`（设计标注）、`docs/shotx-ux-ui-spec.md`（§10）、`docs/shotx-ux-ui-spec-BRA102.md` / `-BRA107.md`（回归）
- 验收版本：本地工作树（`agent/bra-107-font` 分支未提交改动；`Makefile` VERSION=0.1.16，本次 `make app` 重建并签名）
- 执行环境：macOS 26.5.2（arm64），Swift 6.3.3，Xcode CLT（`/Applications/Xcode.app`）
- 验收日期：2026-08-17
- 验收方：独立 QA（与实现者分离；本报告为独立复跑 + 独立逐条核对设计标注）
- 结论：**有条件通过**（后台可验证项全部通过；依赖真实麦克风/扬声器/权限弹窗/真机声画同步的项由用户按手测清单执行）

## 1. 需求 → 测试追踪表

| ID | 验收标准（PRD §6） | 验证方式 | 后台验证证据（本次） | 用户实测（手测清单） |
| --- | --- | --- | --- | --- |
| A1 | 麦克风开启时，麦克风声音真实写入成片（当前完全录不上） | 管线逻辑：`AVCaptureSession`→`AVCaptureAudioDataOutput`→`RecordingAudioMixer.appendMicrophone`→单一音轨写入（`RecordingCoordinator.swift` `ScreenRecorder`/`captureOutput`，`RecordingAudioMixer.swift`）；麦克风会话真实创建于 `makeSourceSession` | ✅ `RecordingAudioMixerTests` 12 例（含单路麦克风 passthrough `testSystemDisabledPassesMicrophoneThrough`、适配层单声道→立体声混入 `testAdapterConvertsMonoMicAndStereoSystemIntoOneTrack`） | TC-AUD-01（真实录制成片含麦克风） |
| A2 | 系统声音与麦克风**同时**开启时可同时录制两者 | 混音核心按 PTS 对齐求合成单路 PCM，单一 writer input 编码 AAC（修复双音轨只能听到一条的根因） | ✅ `testBothSourcesOverlapSumIntoSingleChunk`、`testBothSourcesArePresentInMixedOutputNotJustOne`、`testAdapterConvertsMonoMicAndStereoSystemIntoOneTrack`（输出单一混合缓冲 0.3+0.2=0.5） | TC-AUD-02/03（真机同时播放两者可听） |
| A3 | 声音与画面同步（§11.1 < 200 ms）；播放器能同时听到系统声与麦克风 | 混音输出 PTS 锚定首帧屏幕样本（`setAnchor`），系统声/麦克风均换算到同一绝对采样时间轴 | ✅ `testTimeAlignedMicOffsetProducesSystemOnlyThenSum`、`testMicArrivingLateDoesNotLoseSystemAudioLeadingEdge`、`testIncrementalAppendAndDrainIsMonotonicAndLossless`（时间对齐/单调推进） | TC-AUD-04（真机声画同步实测） |
| A4 | 权限/设备不可用时按钮呈禁用态并提示，不阻断无麦克风录制 | `beginCountdown` 权限降级（`RecordingCoordinator.swift:413-421`）；混音器 `microphoneConfigured=false` 时不等待麦克风；`toggleMicrophone` 无设备/拒权回退 off + 提示 | ✅ `testMicrophoneUnconfiguredNeverBlocksSystem`、`testMicrophoneDisabledPassesSystemAudioThrough`、`testActiveMicWithNoDataYieldsToSystemAfterGrace`、`testMicrophoneFinishedFlushesSystemRemainder`、`RecordingSourceStateTests.testMicrophoneOnRequiresTogglePermissionAndDevice` | TC-AUD-05/06（拒权/拔设备不阻断） |
| U1 | `O-RSET` 面板按设计标注实现（按钮两态切换，正确指示功能开关） | 四按钮视觉由 `RecordingSourceState.isOn` 真值表（开关+权限+设备）驱动，禁止本地缓存漂移；切换失败自动回退 off + 提示 | ✅ `RecordingSourceStateTests` 11 例（真值表全源、授权后才落定开关、拒权回退、意图防护、请求中 spinner） | TC-UI-01/02/03 |
| U2 | 扬声器/麦克风/摄像头/鼠标按钮明确 on/off 呈现（红斜线 off 资产） | 资产核对：4 枚 `record-*-off.svg` 均含 `#FA5151` 斜线 `M28 19`（摄像头另含 `M12 3`），`record-*-on.svg` 均无斜线；渲染按 `asset-on/off` 选择 | ✅ 资产静态核对（off 4/4 含斜线，on 0 含斜线）+ 状态单测 | TC-UI-02（视觉确认） |
| U3 | 第一次录屏麦克风、摄像头默认关闭；不自动请求其权限 | `AppSettings` 默认 `microphone=false`、`cameraEnabled=false`；首启仅申请屏幕权限，不申请麦克风/摄像头 | ✅ `testFreshInstallDefaultsShowMicCameraOff`、`testFreshInstallDefaultsDoNotRequestMicrophone`、`PermissionFlowTests.testDefaultsNeverRequestMicrophoneAutomatically` | TC-PERM-01（清除持久化后首录验证） |
| U4 | `O-REC` 录制浮动条与设计标注一致 | 实现核对：`● REC` 标识、时长、来源状态图标（扬声器/麦克风/摄像头 on 资产，断开斜线）、停止按钮；时长独立于停止按钮不重叠；菜单栏「停止录制 00:12」同步；录制中 `Esc` 不停止 | ✅ 代码走查（`RecordingStatusWindowController.makeRecordingContent`/`setSourceLost`；`ShotXApp.swift:53`；`beginCountdown` 后移除 escape monitor）；C1/C4 的「磁盘状态图标」未实现（设计 §7 标为待确认，见 O2） | TC-UI-04/05/06、TC-REC-02 |
| U5 | 首次权限流程、摄像头画中画（BRA-102）不被破坏 | 摄像头按需申请、授权后启动会话、画中画合成逻辑未回退；`QACameraOverlayTests` 5 例原样通过 | ✅ `QACameraOverlayTests` 5 例 + `testCameraGrantAfterRequestEnablesToggle`、`testCameraDeniedAfterRequestTurnsOffToggle` | TC-CAM-01/02（真机画中画） |
| P1/P2/P3 | 打包规则（新版本、替换根目录 ShotX.app、RELEASE-NOTES） | 属发布阶段，出包由 BRA-119 执行 | 本验收仅登记构建证据（`make app` 0.1.16、签名、冒烟通过）；版本递增/替换/RELEASE-NOTES 归 BRA-119 验收 | —（BRA-119 随包交付） |

## 2. 团队后台测试闭环证据（独立复跑）

| 步骤 | 命令 | 结果 | 证据 |
| --- | --- | --- | --- |
| 冷缓存单测 | `swift test` | ✅ | **115/115 通过，0 failures**（12 个套件；含 BRA-115 新增 `RecordingAudioMixerTests` 12 例、BRA-116 新增 `RecordingSourceStateTests` 11 例） |
| Release 构建 | `make app` | ✅ | Release 构建完成，`ShotX.app` 已签名，Info.plist 写入 0.1.16 |
| 签名校验 | `codesign --verify --deep --strict --verbose=2 ShotX.app` | ✅ | `valid on disk`，`satisfies its Designated Requirement` |
| 静默冒烟启动 | `open ShotX.app` + `pgrep -x ShotX` + 退出 | ✅ | 进程存活（PID 记录）并干净退出 |
| 静态检查（无网络） | `rg -i "urlsession\|urlrequest\|nwconnection\|https?://" Sources/ShotX --glob '*.swift'` | ✅ | Swift 源码无网络代码 |
| 权限用途声明 | `plutil -p ShotX.app/Contents/Info.plist` | ✅ | `NSCameraUsageDescription` / `NSMicrophoneUsageDescription` 随包；版本 0.1.16；LSUIElement |
| 字体（BRA-107 回归） | `AppFontsTests` 3 例 + 包内资源核对 | ✅ | `AppFontsTests` 通过；`ShotX.app/Contents/Resources/ShotX_ShotX.bundle/AlimamaFangYuanTiVF-Bold-sub.ttf` 已随包 |
| 资产核对 | `rg` 四枚 off/on 资产斜线、`record-start.svg #07C160`、`record-divider.svg #D9D9D9` | ✅ | off 含 `#FA5151` 斜线、on 无、开始按钮绿色、分割线按 `#D9D9D9` 0.6 实现 |

### 2.1 BRA-115 混音管线（`RecordingAudioMixer.swift`）独立核对结论

- 根因确认：旧实现 `systemAudio` / `microphone` 为**两个独立 `AVAssetWriterInput`**（`HEAD:RecordingCoordinator.swift:656-657,707-708,723,778`），MP4 内含两条音轨，不同播放器可能只播一条，且麦克风采集回调与 writer 就绪状态耦合，导致「完全录不上」。
- 修复为**单一音轨**：两路 PCM 经 `RecordingAudioMixer` 按 PTS 锚定（首帧屏幕样本）对齐、求和、限幅后写入唯一 AAC 输入，从根因上解决 A2/A3；麦克风设备不存在时 `microphoneConfigured=false` 视为未启用，不阻塞系统声（A4）。
- 12 例核心+适配层单测全部通过（求和、时间对齐、单路 passthrough、宽限、结束冲刷、增量单调、单声道→立体声转换）。

### 2.2 BRA-116 按钮状态（`RecordingSourceState.swift` / `RecordingSetupView`）独立核对结论

- 四按钮视觉统一由 `RecordingSourceState.isOn`（开关+权限+设备真值表）解析，无本地缓存状态；切换失败回退 off + 提示文案与设计 §2 一致（「麦克风不可用。你仍可继续无麦克风录制。」等）。
- 首次录屏默认：扬声器开、麦克风关、摄像头关、鼠标开（§3.1），且不自动弹麦克风/摄像头权限（§3.2）；授权成功后才落定开关（`microphoneEnableIntent`/`cameraEnableIntent`，防假开启态）。
- 三枚按钮补齐 `accessibilityLabel`/`accessibilityValue`（§5.2）；初始焦点=扬声器（§5.1）。
- `O-RSET` 面板：256 pt 宽、`#333333`、圆角 12、开始按钮绿色 `record-start.svg`、分割线 `#D9D9D9` 0.6、无标题行、按钮行 40×36×4 + 16 pt 间距（§6 R1-R7/R12 符合）。

## 3. 缺陷 / 观察项

### D1（残余风险，需用户实测确认）— 真实音频硬件的采集与同步必须真机验证

- 背景：混音核心与适配层可注入合成 PCM 验证，但真实 `SCStream` 系统声音、`AVCaptureSession` 麦克风的格式/时钟差异（两路可能不同时钟域，麦克风 PTS 与视频 PTS 非同源）只能在真机录制中确认。
- 影响：若真机系统声/麦克风 PTS 存在相对漂移，长录制（≥数分钟）声画同步误差可能超过 §11.1 的 200 ms 目标；短录制通常无感。
- 后台可验证部分：核心对齐逻辑单测通过；真机同步由 TC-AUD-04 实测。若实测同步误差持续 > 200 ms，属缺陷需修复（如引入跨时钟域对齐）。

### D2（观察项，设计待确认）— `O-REC` 磁盘状态图标未实现

- 现象：设计 §10.4/§7 C1 列出的「磁盘状态」在 `O-REC` 浮动条内未呈现；磁盘保护仍经 `DiskGuard` → 模态 alert（阈值 <1 GB 警告 / <500 MB 安全停止，文案与 §10.4 一致）。
- 评估：设计标注 §7 C1/C4、§8 已把磁盘状态图标与「横幅 vs 模态 alert」形态列为**待确认项**（§9.2 待确认 3/5），本变更验收以「提示出现、文案正确、不阻断继续录制」为准，故不构成阻塞；`O-REC` 的 REC 标识、来源图标、时长不重叠、菜单栏「停止录制 00:12」均已实现，C1/C3 其余差异闭合。
- 建议：用户若要求 `O-REC` 内显示磁盘状态，需产品决策后补实现。

### D3（观察项，低）— 提示形态仍为模态 alert 而非横幅

- 现象：`AppModel.showError` → SwiftUI `.alert`（`ShotXApp.swift:67-69`），仅「好」按钮，无「打开系统设置」「停止」动作按钮，非 live region 一次性公告。
- 评估：与设计 §8 的横幅口径不符，但设计标注已明确该形态为**待确认 5**，本变更验收不以此为准；文案与触发时机已核对一致。
- 建议：若产品确定横幅形态，作为后续变更统一处理。

## 4. 结论

**有条件通过。**

- 后台可验证项全部通过：115/115 单测（含独立复跑 BRA-115 混音 12 例、BRA-116 按钮状态 11 例）、Release 构建（0.1.16）、`codesign --verify --deep --strict`、静默冒烟、无网络静态检查、权限用途声明齐全、BRA-107 字体回归通过、BRA-102 摄像头画中画 `QACameraOverlayTests` 回归通过。
- 需求覆盖：A1–A4、U1–U5 均有后台逻辑验证或真机手测项对应；无阻塞项。D1（真机声画同步）、D2（O-REC 磁盘状态）、D3（提示形态）为残余风险/待确认项，均不阻断本次验收。
- 手测清单 `docs/QA-MANUAL-TEST-CHECKLIST-BRA-113.md` 随构建包交付，由用户在真实 Mac 上执行；若 TC-AUD-04 实测同步误差持续 > 200 ms，应升级为缺陷并修复。
