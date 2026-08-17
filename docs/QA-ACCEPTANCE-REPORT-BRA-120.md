# ShotX QA 验收报告（BRA-120）

- 验收对象：BRA-120「首次操作未真正发起录屏/系统录音权限申请」修复（A1…A6）
- 验收依据：`docs/shotx-prd-BRA120.md`（§7 功能要求、§8 验收标准）
- 验收版本：本地工作树（分支 `agent/bra-107-font`，含未提交的 BRA-120 + BRA-113 + BRA-102 改动；改动集中在 `Sources/ShotX/AppModel.swift`、`Sources/ShotX/RecordingCoordinator.swift`、`Tests/ShotXTests/PermissionFlowTests.swift`）
- 验收日期：2026-08-17
- 验收方：独立 QA（BRA-122；与实现者分离；独立复跑 `swift test` + 独立代码走查）
- 结论：**有条件通过**（后台可验证项全部通过；真实 TCC 弹窗与系统设置列表注册由用户按手测清单实测）

## 1. 需求 → 测试追踪表

| ID | 验收标准（PRD） | 验证方式 | 后台验证证据（本次） | 用户实测（手测清单） |
| --- | --- | --- | --- | --- |
| A1 | 首次启动发起屏幕录制权限申请时系统弹窗真实弹出；授权后 shotX 出现在系统设置「录屏与系统录音」列表且为已允许 | 真机 TCC；后台仅验证申请被真实发起的前置条件：请求前临时转正激活策略 + `CGRequestScreenCaptureAccess()` | ✅ 代码走查：`requestScreenAccess` 先 `setActivationPolicy(.regular)` + `activate(ignoringOtherApps:)` 再请求（`AppModel.swift:208-215`）；`start()`→`requestScreenPermissionOnFirstLaunch()`（`AppModel.swift:271-274`） | TC-120-S-01/02 |
| A2 | `screenPermissionAsked` 仅在系统请求真实发出后置位；被抑制不得烧毁 flag | 逻辑：`requestScreenPermission` 按请求结果（granted/denied/suppressed）决定置位 | ✅ `testFlagIsSetOnlyAfterGenuinePromptDecision`、`testSuppressedRequestDoesNotBurnFlagAndAllowsReRequest`（suppressed 不烧 flag、可再次申请） | TC-120-S-03 |
| A3 | 未授权时捕获命令显示拦截说明（「打开系统设置」「取消」），不静默失败；不创建选区蒙层 | 逻辑：`begin()` 权限前置拦截，先拦截/申请再建蒙层 | ✅ 代码走查：`begin()` 在 `permissions[.screen] != .allowed` 时走拦截/申请，绝不先 `CaptureCoordinator.begin`（`AppModel.swift:340-356`）；拦截说明含「打开系统设置」「取消」（`AppModel.swift:399-406`） | TC-120-S-04 |
| A4 | 麦克风按需申请：默认关；开启开关时系统弹窗真实出现并注册；拒绝后开关自动关闭并提示 | 逻辑：默认值 + 开关绑定 + 拒绝回调 | ✅ 代码走查 + `testMicrophoneOnDemandRequestDeniedTurnsOffToggleAndShowsError`、`testMicrophoneOnDemandRequestGrantedKeepsToggle`、`testDefaultsNeverRequestMicrophoneAutomatically`（拒绝关开关+提示「麦克风不可用。你仍可继续无麦克风录制。」；授权保持开启；默认关且首启不自动申请） | TC-120-M-01/02 |
| A5 | 权限请求不得被 `.screenSaver` 级蒙层遮挡（回归 BRA-102 弹窗置顶） | 逻辑：申请前清除捕获蒙层 + 转正激活 | ✅ 代码走查：`requestScreenPermission` 先 `CaptureCoordinator.shared.cancel()`（`AppModel.swift:383`）；麦克风/摄像头申请同样转正激活 | TC-120-M-01（弹窗可点性） |
| A6 | 回归 BRA-102：首次录屏麦克风/摄像头默认关闭、按需申请不被破坏 | 逻辑 + 既有用例复跑 | ✅ `testFreshInstallRecordingDefaultsDisableCameraAndMicrophone`、`testDefaultsNeverRequestMicrophoneAutomatically` 通过；`QACameraOverlayTests` 5 例全绿（摄像头画中画不回归） | TC-120-M-03 |
| 回归 BRA-113 | 录屏音频（系统声+麦克风）、录屏 UI 不受影响 | 逻辑 + 既有用例复跑 | ✅ `RecordingAudioMixerTests` 12 例全绿（混音、麦克风/系统声同时存在、断连冲刷）；`ScrollingCaptureTests` 3 例全绿 | TC-120-A-01 |

## 2. 自动化测试证据（独立复跑）

执行环境：macOS（Apple Silicon arm64，Swift 6.3.3，Xcode CLT）。

| 步骤 | 命令 | 结果 | 证据 |
| --- | --- | --- | --- |
| 全量单测 | `swift test` | ✅ | **102/102 通过，0 failures** |
| 权限流程用例 | `swift test --filter PermissionFlowTests` | ✅ | **9/9 通过，0 failures**（含 BRA-120 新增/更新 4 例 + 回归 5 例） |

### 2.1 BRA-120 相关用例清单

`Tests/ShotXTests/PermissionFlowTests.swift`（9 例）：

| 用例 | 覆盖 |
| --- | --- |
| `testFlagIsSetOnlyAfterGenuinePromptDecision` | A2：真实决策（拒绝）后才置位 flag |
| `testSuppressedRequestDoesNotBurnFlagAndAllowsReRequest` | A2：请求被抑制不烧 flag，可再次申请 |
| `testMicrophoneOnDemandRequestDeniedTurnsOffToggleAndShowsError` | A4：麦克风拒绝 → 开关关闭 + 错误提示 |
| `testMicrophoneOnDemandRequestGrantedKeepsToggle` | A4：麦克风授权 → 开关保持开启、无错误 |
| `testDefaultsNeverRequestMicrophoneAutomatically` | A4/A6：默认关、首启不自动申请麦克风 |
| `testFirstLaunchRequestsScreenPermissionOnceAndMarksAsked` | A1：首启发起一次屏幕权限申请 |
| `testFirstLaunchWithScreenAlreadyAllowedAsksNothing` | A1：已授权不重复申请 |
| `testScreenPermissionAskedFlagPersistsAcrossModelInstances` | A2：flag 跨实例持久化 |
| `testFreshInstallRecordingDefaultsDisableCameraAndMicrophone` | A6：全新安装默认关闭摄像头/麦克风 |

回归用例（BRA-102/BRA-113，全绿）：`QACameraOverlayTests` 5 例、`RecordingAudioMixerTests` 12 例、`ScrollingCaptureTests` 3 例。

## 3. 代码走查结论（A1/A3/A5 逻辑路径）

- **A1 申请触发前置条件**：`requestScreenAccess` 生产实现（`AppModel.swift:208-215`）在 `CGRequestScreenCaptureAccess()` 前将 LSUIElement accessory 应用临时切到 `.regular` 并激活，请求后恢复原策略——这是对「accessory 应用默认不能成为前台、系统权限弹窗被静默抑制」根因的标准修复。首次启动路径 `start()`→`requestScreenPermissionOnFirstLaunch()`→`requestScreenPermission()` 成立。
- **A2 flag 时机**：`requestScreenPermission` 仅在结果 `.granted`/`.denied` 时置位 flag；`.suppressed` 保持未询问（`AppModel.swift:385-393`），后续可再次真实申请。
- **A3 拒绝路径**：`begin()` 权限前置（`AppModel.swift:340-356`），未授权时先拦截/申请，不创建选区蒙层；拦截 NSAlert 含「打开系统设置」「取消」（`AppModel.swift:399-406`），「打开系统设置」跳 `Privacy_ScreenCapture`。
- **A5 弹窗置顶**：所有权限申请路径均先 `CaptureCoordinator.cancel()` 清蒙层（`AppModel.swift:383`）且转正激活，符合 BRA-102 弹窗置顶约定。
- **A4/A6 麦克风/摄像头按需申请**：默认值 `microphone=false`、`cameraEnabled=false`（`AppModel.swift:81,83,97`）；开关绑定开启时触发 `model.request(permission)`（`RecordingCoordinator.swift:1066-1068`）；麦克风申请与屏幕权限同样转正激活（`AppModel.swift:419-431`）。

## 4. 缺陷 / 残余风险 / 观察项

### R1（残余风险，需真机确认）— 生产实现无法区分「被抑制」与「被拒绝」

- **现象**：`requestScreenAccess` 生产实现把 `CGRequestScreenCaptureAccess()` 的 `false` 统一映射为 `.denied`，`ScreenPermissionPromptOutcome.suppressed` 仅在测试注入中可达；`CGRequestScreenCaptureAccess()` 返回值本身无法区分「系统静默抑制」与「用户拒绝」。
- **评估**：A2 的「抑制不烧 flag」保护在生产路径只能依赖「转正激活」这一前置修复保证请求不被抑制，而无法对抑制做二次兜底。若在个别 macOS 版本上激活策略工作无效、请求仍被抑制，flag 仍会被当作 `.denied` 烧毁——即 BRA-120 原始问题再现。
- **影响**：低-中。TC-120-S-01 真机实测弹窗真实出现即证明抑制路径不触发，R1 关闭；若实测仍未弹窗，属阻断项，需在请求前后对比 `CGPreflightScreenCaptureAccess()` 状态以检测抑制。

### R2（观察项，低）— 根目录 `ShotX.app` 尚未按 BRA-120 代码重建

- **现象**：项目根目录 `ShotX.app` 为 0.1.14（对应上一打包），当前工作树含未提交的 BRA-120/BRA-113 改动，尚未 `make app` 重建替换。
- **评估**：PRD §8 标准 6（打包并覆盖根目录 `ShotX.app`）属 Stage 4 发布门禁（BRA-119/打包），不在本次 QA（Stage 2）范围内；此处仅提示交付版本为工作树状态，打包由发布流程跟进。

### R3（观察项）— 共享工作树未提交改动

- BRA-120 与 BRA-113 改动同处未提交工作树（分支 `agent/bra-107-font`），本报告验收的是当前工作树状态。提交/分支归属由发布流程处理。

## 5. 结论

**有条件通过。** 后台可验证项全部通过：`swift test` 102/102（含 BRA-120 新增权限流程用例 4 例及 BRA-102/BRA-113 回归 17 例）、代码走查确认 A1/A2/A3/A4/A5/A6 逻辑路径成立。剩余项依赖真实 TCC 系统弹窗与系统设置「录屏与系统录音」/「麦克风」列表注册，由用户按 `QA-MANUAL-TEST-CHECKLIST-BRA-120.md` 实测；其中 **R1** 若实测首次启动弹窗未真实出现（被抑制），应升级为阻断项并返工。
