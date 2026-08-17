## 任务背景

父工单 BRA-102 三个 Stage 均已交付（设计 BRA-103、实现 BRA-104/BRA-105、QA BRA-106「有条件通过」）。本次为**发布流程**：按仓库规范 `docs/RELEASE-AND-TEST-POLICY.md`，发布前对 BRA-102 改动做代码审查（发布门禁）。

先读：`docs/shotx-prd-BRA102.md`（BRA102-01…07）、`docs/shotx-ux-ui-spec-BRA102.md`（设计标注）、QA 报告 `docs/QA-ACCEPTANCE-REPORT-BRA-102.md`、仓库规范 `docs/RELEASE-AND-TEST-POLICY.md`。

## 范围

- 审查 BRA-102 相关改动（`Sources/ShotX/AppModel.swift`、`RecordingCoordinator.swift`、`SettingsView.swift` 及新增测试 `PermissionFlowTests`/`QACameraOverlayTests` 等）相对基准的 diff。
- 双轴核对：①仓库编码规范；②原始需求（PRD/UX 标注）。
- 给出可定位、可执行的问题报告（文件、位置、影响、最小修复建议）；不修改代码。

## 验收标准

- 报告区分「规范」与「需求」两类问题，只报有实际 diff、仓库规则与需求证据支撑的问题。
- 明确给出通过 / 需修复项清单，作为打包前的发布门禁输入。
