# ShotX QA 复验报告（BRA-55）

- 验收对象：FR-CAP-14/15/16 与 BRA-56～67 修复集合
- 固定基线：`6a5a92f2f04d217955689ad26d66f5f63e6a9d2f`（PRD v1.7）
- 验收版本：**0.1.2** 集成分支（`integrate/bra-55-0.1.2`，基于 `origin/main=28c2eab`）
- 验收日期：2026-08-12
- 验收方：代码审查（独立于实现者）
- 结论：**通过（后台自动验证部分）；桌面交互留待用户手测**

## 1. 交付形态

原不可合成的 PR #1（Draft，BRA-64/65）与 PR #2（BRA-66 拆分）已由本分支的唯一整合 PR 取代：以 PR #2 的小提交为依赖基线，rebase PR #1 仅保留 BRA-64/65 内容，并合入 BRA-67；版本权威统一为 0.1.2，QA 文档在最终无冲突 head 统一更新。

| 对象 | 状态 | 结论 |
| --- | --- | --- |
| 整合 PR（含 `BRA-55`） | 非 Draft、从 `origin/main=28c2eab` 独立检出、无 merge-tree 冲突 | ✅ |
| 版本权威 | `Makefile:1` 为 0.1.2；release notes / Info.plist 一致 0.1.2 | ✅ |
| BRA-64 | 滑块拖动后立即提交笔刷大小（`BrushSlider`） | ✅ 已闭环 |
| BRA-65 | window-aware 焦点桥接：选区/八把手/工具栏/浮层/输出按钮真实 Tab/Shift+Tab 链；选区 < 20×20 pt 隐藏工具栏与尺寸标签并从焦点链移除 | ✅ 已闭环 |
| BRA-67 | 极窄工作区浮层宽度收敛至 `visibleFrame.width - 16`，保留滚动容器 | ✅ 已闭环 |
| 打包 | 不生成发布包体 | ⏭️ 按任务边界跳过 |

## 2. 团队后台验证证据

按 `docs/QA-BACKGROUND-TEST-LOOP.md` 从 clean build cache 执行；未操控用户桌面。

| 步骤 | 命令 | 结果 | 关键证据 |
| --- | --- | --- | --- |
| 固定点 / diff | `git diff 6a5a92f...HEAD` | ✅ | 集成范围可解析 |
| 冷缓存单元测试 | `swift package clean && swift test` | ✅ | 37/37 通过（含 BRA-64/65/67 新增用例） |
| Release 构建 | `make app` | ✅ | Release build 完成，Info.plist 写入 0.1.2 |
| 签名 | `codesign --verify --deep --strict --verbose=2 ShotX.app` | ✅ | `valid on disk`，满足 designated requirement |
| 静态检查 | `rg` 网络 API | ✅ | 无 `URLSession` 等网络代码 |
| merge-tree | `git merge-tree origin/main...HEAD` | ✅ | 无冲突 |

## 3. 后台新增用例

- `QARegionCaptureOutputTests.testCaptureFocusChainCyclesThroughSelectionHandlesToolbarOptionsAndOutputs`：单窗链 21 节点双向循环。
- `QARegionCaptureOutputTests.testCaptureFocusChainWindowAwareBridgeSpansOverlayAndPanel`：跨覆盖层窗口与浮层面板的焦点桥接。
- `QARegionCaptureOutputTests.testCaptureFocusChainTinySelectionThresholdHidesToolbarAndPanel`：20×20 pt 阈值判定。
- `SettingsTests.testCaptureOverlayOptionsPanelStaysInsideVeryNarrowVisibleFrame`：315 pt 可见区浮层宽 299 pt 且含于 8 pt 内边距。

## 4. 遗留事项

- 桌面交互（固定工具区、浮层避让、拖拽笔刷手感、完整 Tab 遍历）由用户按 `QA-MANUAL-TEST-CHECKLIST-BRA-54.md` / `QA-MANUAL-TEST-CHECKLIST-BRA-55.md` 在真实 Mac 上实测。
- 正式 0.1.2 包体待独立审查并合入后按发布门生成。

## 5. 结论

**通过。** 后台可自动验证的部分（单测、构建、签名、静态检查、无 merge 冲突、版本权威 0.1.2）全部通过，BRA-64/65/67 已闭环；桌面交互按既有手测清单交由用户实测。
