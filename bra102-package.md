## 任务背景

父工单 BRA-102 三个 Stage 均已交付，QA 已出「有条件通过」结论（后台可验证项全部通过，D1/D3 等依赖真实摄像头/权限弹窗项待用户手测）。用户明确要求：**任务完成后打一个新版本的包**（评论：「任务完成记得打一个新版本的包」）。

本次为发布流程，按仓库规范 `docs/RELEASE-AND-TEST-POLICY.md` 执行。先读该规范、`docs/shotx-prd-BRA102.md`、`docs/shotx-ux-ui-spec-BRA102.md` 与 QA 报告 `docs/QA-ACCEPTANCE-REPORT-BRA-102.md`。

## 现状（已核实）

- BRA-102 相关改动（`Sources/ShotX/AppModel.swift`、`RecordingCoordinator.swift`、`SettingsView.swift`、新增 `PermissionFlowTests`/`QACameraOverlayTests` 等）目前**未提交**，工作树处于 `agent/bra-107-font` 分支。
- `Makefile` 顶部 `VERSION ?= 0.1.2`，但 `git ls-files releases/` 已存在 0.1.10/0.1.11/0.1.12 压缩包，且 BRA-93 曾将 `ShotX.app` 直接更新为 0.1.13。**新版本号必须与 `releases/` 及 git 历史中所有已存在包不重复**，需先核对真实最新版本再递增。

## 要求

1. **提交并合并**：将 BRA-102 全部改动提交并合并到主干（`main`），确保 `swift test` 全绿（QA 复跑为 85/85）。
2. **代码审查（发布门禁）**：发布前对 BRA-102 改动做代码审查，确认与需求（PRD/UX 标注）一致且符合仓库规范；审查结论作为发布门禁。
3. **确定并递增版本号**：核对 `releases/` 与 git 历史中的真实最新版本，按语义化版本递增 PATCH（若歧义，以仓库 `RELEASE-AND-TEST-POLICY.md` §1 为准），更新 `Makefile` 顶部 `VERSION`。
4. **打包**：`make app` + `codesign --verify` 通过后 `make package`，产出 `releases/ShotX-<新版本>.app.zip` 与 `ShotX-<新版本>-source.zip`；包内 `Info.plist` 版本与包名一致。
5. **发布说明**：在 `docs/RELEASE-NOTES.md` 记录该版本相对上一版本的用户可见变更（权限申请置顶、首次录屏默认禁用摄像头/麦克风、摄像头圆角画中画与设置）。

## 验收标准

- BRA-102 改动已合并到 `main` 且有 commit；`swift test` 通过。
- 代码审查通过（或已说明处理方式）。
- `releases/ShotX-<新版本>.app.zip` 与 `-source.zip` 已产出，`codesign --verify --deep --strict` 通过，版本号与现有包不重复。
- `docs/RELEASE-NOTES.md` 已更新。
- 交付评论给出：新版本号、产物路径、测试与签名证据、未验证项。
