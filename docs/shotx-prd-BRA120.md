# BRA-120 PRD：修复首次操作未真正发起录屏/系统录音权限申请

版本：v1.0
交付对象：macOS 客户端（本地应用，无服务端任务）

## 1. 用户问题

首次操作时，ShotX 会弹出权限设置窗口，但并未真正发起 macOS 的「屏幕录制（Screen Recording）」与「系统录音（Microphone）」权限申请。打开系统设置后，在「录屏与系统录音」权限列表中看不到 shotX，用户无法在系统层面授权。

期望：应用能真正触发 macOS 的系统录屏与录音权限申请，使 shotX 出现在系统设置的权限列表中，从而可被用户授权。

## 2. 现状与根因分析（供开发核实，非结论）

### 2.1 现状代码路径

- `AppModel.start()` → `requestScreenPermissionOnFirstLaunch()` → `requestScreenPermission()` → `requestScreenAccess()`（生产实现 = `CGRequestScreenCaptureAccess()`）。
- 麦克风权限按 BRA-102 口径为「按需申请」：仅在用户于 `O-RSET`/`W-SET` 主动开启麦克风开关时调用 `AVCaptureDevice.requestAccess(for: .audio)`（`AppModel.request(.microphone)`）。
- 权限状态：`CGPreflightScreenCaptureAccess()` 判定屏幕权限（`refreshPermissions()`）；麦克风用 `AVCaptureDevice.authorizationStatus(for: .audio)`。

### 2.2 主要嫌疑（开发须在真机复现并确认）

1. **激活/前台时机**：`requestScreenPermission()` 先 `NSApp.activate(ignoringOtherApps:)` 再同步调用 `CGRequestScreenCaptureAccess()`。ShotX 是 `LSUIElement` 菜单栏应用（`Support/Info.plist` 中 `LSUIElement=true`），accessory 应用默认不能成为前台激活应用；激活是异步生效的，紧随其后的系统权限请求可能被 macOS 静默抑制——**不弹系统弹窗、不注册 TCC 条目**，`CGRequestScreenCaptureAccess()` 直接返回 false。已知菜单栏应用常见处理：请求前临时将激活策略切到 `.regular` 或确保激活完成后再请求。
2. **`screenPermissionAsked` 过早置位（flag 烧毁）**：`requestScreenPermission()` 在真正发起系统请求**之前**就无条件 `screenPermissionAsked = true`。若首次请求被抑制，该 flag 已落盘，之后：
   - 再次启动 `requestScreenPermissionOnFirstLaunch()` 因 `screenPermissionAsked == true` 直接 return，**再也不会自动触发真实系统请求**；
   - 用户触发捕获时进入 `presentScreenPermissionInterception()`，看到的是**应用自建弹窗**「需要屏幕录制权限 / 打开系统设置」（用户描述的"权限设置窗口"），点击后打开系统设置，但 shotX 因从未注册而不在列表中——与反馈完全吻合。
3. **无重新申请兜底**：`PermissionsPane` 的「允许…」按钮会再次调用 `requestScreenPermission()`（`SettingsView.swift:137`），但用户无从得知该入口，且首次被抑制后 flag 已烧毁，体验上等同"没有任何真实申请发生过"。

### 2.3 麦克风

按 BRA-102 口径保持「按需申请」（全新安装默认关闭，开启开关才请求）。需验证开关开启时 `AVCaptureDevice.requestAccess(for: .audio)` 在激活状态下能正常弹出系统弹窗并注册 shotX 到「麦克风」列表。若同样存在激活/前台问题，一并修复。

## 3. 范围

- 修复屏幕录制权限申请未真正触发的问题：首次启动或首次捕获时，shotX 必须真实出现在系统设置「录屏与系统录音」权限列表中并可授权。
- 修复 `screenPermissionAsked` 过早置位导致的"永不再真实申请"问题，保证系统权限弹窗真正弹出。
- 验证并（如有问题）修复麦克风按需申请路径：开启开关时系统弹窗正常出现、shotX 注册到「麦克风」列表。
- 保留 BRA-102 的既有决策：麦克风/摄像头默认关闭、按需申请；权限请求不得被 `.screenSaver` 级蒙层遮挡。
- 每次交付按长期约定打包：重新构建并覆盖项目根目录 `ShotX.app`。

## 4. 非目标

- 不改变「麦克风/摄像头按需申请、首次不自动请求」的 BRA-102 设计决策。
- 不改动截图/滚动截图流程；不引入账号、云端、网络服务；不新增第三方依赖。
- 不做服务端任务（纯本地 macOS 应用）。

## 5. 用户流程

首次启动 ShotX → 发起屏幕录制权限申请（系统弹窗真实出现、置顶可点）→ 用户授权/拒绝 → 打开系统设置可见 shotX 已在「录屏与系统录音」列表 → 首次录屏：开启麦克风开关时出现麦克风系统弹窗并注册 → 正常录屏。

## 6. 关键状态

| 状态 | 说明 |
| --- | --- |
| `screen-not-registered` | 首次申请被抑制，shotX 未进入系统权限列表（本次要消除的缺陷状态） |
| `screen-asked` | 系统弹窗已真实弹出（用户已做出授权/拒绝决策或至少已看到弹窗），flag 在请求真正发出后才置位 |
| `screen-allowed` | 已授权，可正常截图/录屏 |
| `screen-denied` | 拒绝/受限：捕获命令显示拦截说明 + 「打开系统设置」，不静默失败 |
| `mic-on-demand` | 麦克风开关开启才申请；授权后可录，拒绝后自动关闭开关并提示 |

## 7. 功能要求

| ID | 要求 |
| --- | --- |
| A1 | 首次启动发起屏幕录制权限申请时，系统弹窗真实弹出；授权后 shotX 出现在系统设置「录屏与系统录音」列表且为已允许 |
| A2 | `screenPermissionAsked` 仅在系统请求真实发出后置位；不得在请求被抑制时提前烧毁，保证后续可再次真实申请 |
| A3 | 屏幕权限未授权时，捕获命令显示拦截说明（复用现有文案），按钮「打开系统设置」「取消」，不静默失败 |
| A4 | 麦克风开关开启时，系统麦克风权限弹窗真实出现，shotX 注册到「麦克风」列表；拒绝后开关自动关闭并提示（沿用 BRA-102 文案） |
| A5 | 权限请求不得被 `.screenSaver` 级蒙层遮挡（回归 BRA-102 弹窗置顶行为） |
| A6 | 回归：BRA-102 首次录屏麦克风/摄像头默认关闭、按需申请不被破坏 |

## 8. 验收标准

1. 全新安装（或清除 shotX 权限记录）首次启动，系统屏幕录制权限弹窗真实弹出；授权后系统设置「录屏与系统录音」列表出现 shotX（真机手测，自动化无法覆盖 TCC 弹窗）。
2. 未授权时捕获命令显示拦截说明，可打开系统设置，不静默失败。
3. 首次录屏开启麦克风开关时，系统麦克风弹窗出现并注册 shotX 到「麦克风」列表；拒绝后开关自动关闭并提示。
4. `swift test` 全绿；自动化测试覆盖：flag 仅在真实请求后置位、请求被抑制时可再次申请、麦克风按需申请路径不回归。
5. QA 独立验收报告给出通过/有条件通过及手测清单。
6. 新版本已打包并覆盖项目根目录 `ShotX.app`，版本号合法且与 `releases/` 不重复。

## 9. 分解与分派

- **Stage 1**：客户端排查并修复首次权限申请未真正触发（屏幕录制 TCC 注册 + `screenPermissionAsked` 时机 + 麦克风按需申请验证）。→ 客户端/前端开发
- **Stage 2**：QA 独立验收（权限列表可见性、授权/拒绝路径、麦克风按需申请、回归 BRA-102/BRA-113），输出验收报告与手测清单。→ QA
- **Stage 3**：发布门禁代码审查（BRA-120 全部改动）。→ 条件代码审查
- **Stage 4**：打包新版本并替换项目根目录 `ShotX.app`（长期打包约定），更新 RELEASE-NOTES。→ leader 与客户端协作

## 10. 仓库/分支上下文

- 仓库：`/Users/brad/Documents/shotX`（本地目录资源）。
- 当前工作树包含 BRA-113 未提交改动（`RecordingCoordinator.swift`、`ScrollingCaptureCoordinator.swift`、`RecordingAudioMixer.swift`、字体资源、录屏 UI 相关文档）。实现须**保留并兼容**这些未提交改动，不得回退。
- 相关文件：`Sources/ShotX/AppModel.swift`（`requestScreenPermission`/`requestScreenPermissionOnFirstLaunch`/`request`/`begin`）、`Sources/ShotX/SettingsView.swift`（`PermissionsPane`）、`Sources/ShotX/RecordingCoordinator.swift`（麦克风开关路径）、`Tests/ShotXTests/PermissionFlowTests.swift`（现有测试编码了当前行为，需随修复更新）、`Support/Info.plist`（`LSUIElement`、`NSMicrophoneUsageDescription`）。
- 与 BRA-113 共享同一本地工作树：客户端任务按目录锁串行执行，勿并行改动冲突文件；如依赖 BRA-113 改动，注明前置关系。

## 11. 决策记录

- D1：麦克风/摄像头保持「按需申请、首次默认关闭」（BRA-102 已确认口径）；本次只修复"申请被抑制/flag 提前烧毁导致从未真实申请"的问题，不改为首次自动请求全部权限。
- D2：屏幕录制权限是录屏（含系统声音）的前提，优先保证其在首次启动即可被真实申请与授权。
