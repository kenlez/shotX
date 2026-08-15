# ShotX QA 复验报告（BRA-55）

- 验收对象：FR-CAP-14/15/16 与 BRA-56～67 修复集合
- 固定基线：`af9089e53348f9e8b80a8c39396fa3a4a0b6b945`（PR #3 合入后的远端 `main`，父 `28c2eab` + PR head `8cda734`）
- 验收版本：**0.1.2**（候选包 `releases/ShotX-0.1.2.app.zip`、`ShotX-0.1.2-source.zip`）
- 验收日期：2026-08-13
- 验收方：代码审查（独立于实现者，从远端主干干净检出）
- 结论：**通过（后台自动验证部分）；桌面交互留待用户手测**

## 1. 交付形态

PR #3（`integrate/bra-55-0.1.2`，非 Draft、独立 review 通过）已合入远端 `main`，merge commit = `af9089e`，工作树干净、无遗留开放 PR。本次从该远端主干 `git archive` 干净检出后独立重跑全量闭环；0.1.2 候选包已生成并随报告交付。

| 对象 | 状态 | 结论 |
| --- | --- | --- |
| 远端主干 | `origin/main = af9089e`（PR #3 MERGED），#1/#2 已关闭取代 | ✅ |
| 版本权威 | `Makefile:1` 为 0.1.2；release notes / 构建产物 Info.plist 一致 0.1.2 | ✅ |
| BRA-64 | 滑块拖动后立即提交笔刷大小（`BrushSlider`） | ✅ 已闭环 |
| BRA-65 | window-aware 焦点桥接：选区/八把手/工具栏/浮层/输出按钮真实 Tab/Shift+Tab 链；选区 < 20×20 pt 隐藏工具栏与尺寸标签并从焦点链移除 | ✅ 已闭环 |
| BRA-67 | 极窄工作区浮层宽度收敛至 `visibleFrame.width - 16`，保留滚动容器 | ✅ 已闭环 |
| 打包 | `make package` 产出 0.1.2 候选包（app + source） | ✅ 本次生成 |

## 2. 团队后台验证证据

从 `git archive origin/main`（= `af9089e`）干净检出，按 `docs/QA-BACKGROUND-TEST-LOOP.md` 冷缓存执行；未操控用户桌面。

| 步骤 | 命令 | 结果 | 关键证据 |
| --- | --- | --- | --- |
| 固定点 / diff | `git rev-parse origin/main` = `af9089e` | ✅ | 远端主干即 PR #3 合入结果 |
| 冷缓存单元测试 | `swift package clean && swift test` | ✅ | 37/37 通过（含 BRA-64/65/67 新增用例） |
| Release 构建 | `make app` | ✅ | Release build 完成，Info.plist 写入 0.1.2 |
| 签名 | `codesign --verify --deep --strict --verbose=2 ShotX.app` | ✅ | `valid on disk`，满足 designated requirement |
| 静默冒烟启动 | 启动 `ShotX.app` → 进程存活 → 退出 | ✅ | 进程存活 4s 后干净退出 |
| 静态检查 | `rg` 网络 API | ✅ | 无 `URLSession` 等网络代码 |
| 工作树 | `git status --porcelain` | ✅ | 远端 `main` 干净 |

## 3. 后台新增用例

- `QARegionCaptureOutputTests.testCaptureFocusChainCyclesThroughSelectionHandlesToolbarOptionsAndOutputs`：单窗链 21 节点双向循环。
- `QARegionCaptureOutputTests.testCaptureFocusChainWindowAwareBridgeSpansOverlayAndPanel`：跨覆盖层窗口与浮层面板的焦点桥接。
- `QARegionCaptureOutputTests.testCaptureFocusChainTinySelectionThresholdHidesToolbarAndPanel`：20×20 pt 阈值判定。
- `SettingsTests.testCaptureOverlayOptionsPanelStaysInsideVeryNarrowVisibleFrame`：315 pt 可见区浮层宽 299 pt 且含于 8 pt 内边距。

## 4. 遗留事项

- 桌面交互（固定工具区、浮层避让、拖拽笔刷手感、完整 Tab 遍历）由用户按 `QA-MANUAL-TEST-CHECKLIST-BRA-54.md` / `QA-MANUAL-TEST-CHECKLIST-BRA-55.md` 在真实 Mac 上对 0.1.2 候选包实测。
- 独立审查中记录的非阻断事项（IMPLEMENTATION 测试名引用 `testToolStyleRangesMatchFRCAP16` 与实际不符、84→72 pt 文档差异、BRA-54 陈旧标签、Tab 链顺序偏离 §7.1、极窄屏约 1 pt 内容裁剪）建议并入下一轮小修，不影响本候选发布。

## 5. 结论

**通过。** 从远端主干 `af9089e` 干净检出后，单测（37/37）、Release 构建、签名、静默冒烟、静态检查、版本权威 0.1.2 全部通过，BRA-64/65/67 已闭环；0.1.2 候选包（app + source）已生成并随本报告交付；桌面交互按既有手测清单交由用户实测。
