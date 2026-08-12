# ShotX 打包与测试规范（RELEASE & TEST POLICY）

> 本文档是 ShotX 仓库打包、测试与目录管理的正式规范。所有仓库改动、打包产物与测试记录都须遵循本规范。本规范自 **BRA-51（V0.1）** 起生效。

## 1. 版本号规则

- 版本采用语义化版本号 **`MAJOR.MINOR.PATCH`**，当前版本为 **V0.1**，工程内表示为 `0.1.0`。
- 版本号唯一权威来源：`Makefile` 顶部的 `VERSION` 变量。`make app` / `make package` 会把该值写入构建产物的 `CFBundleShortVersionString` 与 `CFBundleVersion`。
- **每次打包必须更新版本号**：无论功能还是修复，只要出包，就提升 PATCH（或按语义化版本规则提升 MINOR/MAJOR），并确保新版本号不与仓库 `releases/` 中任何已有包重复。
- **压缩包名必须包含版本号**，格式固定为：

  ```
  releases/ShotX-<VERSION>.app.zip
  releases/ShotX-<VERSION>-source.zip
  ```

  例如 `releases/ShotX-0.1.0.app.zip`。包内 `Info.plist` 的版本字段亦须与包名一致。
- 每个版本的变更说明写入 `docs/RELEASE-NOTES.md`（若不存在则新建），记录该版本相对上一版本的用户可见变化。

## 2. 打包时机

- **不随问题修复即打包**：修复 bug、合并代码后**不**自动出包。
- 只有在**用户的正式打包要求**（issue 或评论中明确要求出包）到达后才执行 `make package`。
- 打包前必须：代码已 review 并合并到主干、`swift test` 全部通过、`make app` + 签名校验通过。
- 打包命令：`make package VERSION=x.y.z`，产物统一输出到 `releases/`。

## 3. Bug 处理与合并流程

- **bug 一个一个地改**：一次只处理一个 bug，改完立即验证（单元测试 + 构建），随后发起 review。
- review 通过后**才合并**到主干；禁止未经 review 直接合并或直接打包。
- 每个修复对应独立的提交（或成对的小提交），提交信息写明所修复的问题。
- 合并后不打包（见第 2 节），等待下一批用户测试与正式出包要求。

## 4. 测试原则

测试分两层，均须在交付中留下证据：

### 4.1 团队后台自测（每次交付前必跑）
- `swift test`：全部用例通过，失败即阻断交付。
- `make app`：release 构建成功，`ShotX.app` 已签名。
- `codesign --verify --deep --strict --verbose=2 ShotX.app`：输出 `valid on disk` 且满足 Designated Requirement。
- 静默冒烟启动：进程启动后存活且可正常退出（不进行任何桌面操控）。
- 静态检查：`Sources/` 无网络代码；无未提交/未跟踪文件（`git status --porcelain` 干净）。
- 结果记录见 `docs/QA-BACKGROUND-TEST-LOOP.md`。

### 4.2 用户手测（随包体附件交付）
- 依赖真实桌面/硬件的交互（权限弹窗、选区拖动、多显示器、真实录制/滚动拼接等）由用户按手测清单执行。
- 手测清单见 `docs/QA-MANUAL-TEST-CHECKLIST-*.md`，每次交付包体必须附对应手测清单。

## 5. 目录管理规范

仓库顶层目录固定分工如下：

| 目录/文件 | 用途 |
| --- | --- |
| `Sources/` | 应用源码（Swift） |
| `Tests/` | 单元/功能测试 |
| `Support/` | 打包支撑文件（`Info.plist` 等） |
| `icon/` | APP 图标源文件（`icon/shotx.png` 为唯一权威来源） |
| `docs/` | 所有文档：PRD、UX/UI 规范、IMPLEMENTATION、QA 清单/报告、本规范、发布说明 |
| `releases/` | 打包产物（必须带版本号，见第 1 节） |
| `attachments/` | issue/评论的原始附件备份 |
| `Makefile` | 构建/打包入口（`build`/`test`/`app`/`icons`/`verify`/`package`/`clean`） |
| `Package.swift` | SwiftPM 工程定义 |
| `README.md` | 仓库总览与快速开始 |

## 6. APP 图标规则

- **`icon/shotx.png` 是 APP 图标的唯一权威来源**（1024×1024 PNG）。
- 打包时 `make app` 会先执行 `make icons`，用 `sips` + `iconutil` 从该 PNG 生成 `ShotX.icns`，放入 `ShotX.app/Contents/Resources/`，并在 `Info.plist` 的 `CFBundleIconFile` 引用。
- 禁止直接改动 `ShotX.icns` 或应用内散落的图标副本；需要换图标时只替换 `icon/shotx.png`。

## 7. 例外与修订

- 任何需要偏离本规范的场景（例如紧急出包），须在 issue 评论中说明理由并取得用户确认。
- 本规范本身随仓库演进可修订，修订须更新本文件并在 `docs/RELEASE-NOTES.md` 登记。
