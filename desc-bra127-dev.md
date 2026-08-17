## 任务

按 BRA-125 PRD（`docs/shotx-prd-BRA125.md`）与 Stage 1 设计标注，实现颜色改动：

- 截屏、录屏**开始之前**的矩形框与锚点 → 统一为蓝色
- 录屏中的框 → 保持红色
- 录屏开始按钮（开始之前的状态）→ 由绿改蓝

## 范围（具体改动点）

1. `Sources/ShotX/CaptureCoordinator.swift` `drawSetupBorder`（约 :652-657）：边框与锚点颜色 `#07C160` 绿 → 蓝（默认 `#10AEFF`，以 Stage 1 设计标注为准）。
2. `Sources/ShotX/RecordingCoordinator.swift` `RecordingRegionBorderView.draw`（约 :1134）：`state == .recording ? "#FA5151" : "#07C160"` → 非录制态（`.setup`/`.countdown`）改蓝，`.recording` 保持 `#FA5151` 红。
3. `Sources/ShotX/Assets/Figma/record-start.svg`（:6）：背景 `#07C160` 绿 → 蓝。

非目标：不改 `ResultWindow.swift` 保存按钮绿色；不改截图选区既有蓝色（已是 `#10AEFF`）。

## 验收标准

1. 录屏设置态（开始前）选区框与锚点为蓝，与截图选区蓝色一致。
2. 录屏中边框为红色（未回归）。
3. 录屏开始按钮为蓝色。
4. `swift test` 全绿；新增/更新最小回归检查覆盖设置态边框颜色与录制态颜色分支（有可行测试方式时）。

## 仓库上下文与协作注意

- 仓库 `/Users/brad/Documents/shotX`，分支 `agent/bra-107-font`。
- **与 BRA-116（录屏 UI 实现）并行**，共享同一工作树；`RecordingCoordinator.swift`、`record-start.svg` 与 BRA-116 存在文件重叠。提交前 `git status` 确认未互相覆盖；如 BRA-116 已改同一行，以最小冲突方式合入（不覆盖对方已落地改动）。
- 保留现有未提交的 BRA-102（摄像头/权限）、BRA-107（字体）、BRA-115（音频）、BRA-116（录屏 UI）改动，不得回退。
