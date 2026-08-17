## Bug 快速通道 · Stage 2：前端开发修复

父 issue BRA-126：窗口截图识别不准确——被完全遮挡的窗口被识别、窗口重叠时选错层级。

前置：QA 已固化复现（Stage 1 完成后本任务提升）。

## 根因（已由产品负责人定位，需验证后修复全部调用者）

1. `Sources/ShotX/CaptureCoordinator.swift:278` `captureWindows(in:)` 仅按 `isOnScreen && windowLayer == 0 && 非自身 bundle && >40×40` 过滤；`isOnScreen` 不排除完全遮挡窗口。
2. `Sources/ShotX/CaptureCoordinator.swift:597-604` `mouseMoved` 用 `windows.first { $0.frame.contains(cgPoint) }`；`SCShareableContent.windows` 顺序不保证 z-order，导致大窗口/后方窗口被优先命中。

## 修复要求（覆盖 FR-WIN-01/02）

- **可见性**：候选窗口只保留屏幕上可见的（存在未被遮挡的可见区域）。完全被遮挡的窗口不得进入候选列表。
- **层级优先**：候选按 z-order（从前到后）排序；悬停命中取重叠区域内最上层可见窗口，不得依赖 `SCShareableContent.windows` 数组顺序。
- **部分遮挡可识别**：有任意可见区域即可识别；悬停可见部分高亮该窗口。
- 获取 z-order / bounds：优先 `CGWindowListCopyWindowInfo`（`kCGWindowListOptionOnScreenOnly`），与 `SCWindow.windowID`/`frame` 匹配换算；不新增第三方依赖。注意多显示器与 Retina 坐标口径沿用现有 `localRect` / `mouseMoved`。
- 保留现有过滤：`windowLayer == 0`、非 ShotX 自身、尺寸阈值；"这里没有可截取的窗口"兜底沿用。
- 检查全部调用者：候选列表与 `hoveredWindow` 的所有使用处（悬停高亮、`suggestedSelection`、窗口模式点击/Return、兜底、Tab 切换若实现）统一走新逻辑。

## 验证与交付

- 新增/更新 XCTest 覆盖：z-order 排序、完全遮挡剔除、部分遮挡保留、现有过滤保持。纯逻辑函数需可直接单测（不要依赖真实多窗口桌面）。
- 执行 `swift package clean && swift build && swift test`；报告覆盖的 FR、变更文件、测试结果。
- 更新 `docs/shotx-ux-ui-spec.md` §6.3 与 FR 追踪表（FR-CAP-02 或新增 FR-WIN 行），更新 `docs/IMPLEMENTATION.md` 证据行。
- 真实桌面重叠窗口手测由 QA Stage 3 执行，不要自行宣称通过；如需打包说明阻碍。
