## Bug 快速通道 · Stage 1：QA 固化复现

父 issue BRA-126：窗口截图识别不准确——被完全遮挡的窗口被识别、窗口重叠时选错层级。

背景：`Sources/ShotX/CaptureCoordinator.swift` 中 `captureWindows(in:)`（:278）与 `mouseMoved`（:597-604）存在识别缺陷：`isOnScreen` 不排除遮挡；`windows.first` 依赖不保证的数组顺序导致大窗口抢占小窗口。

任务：

1. 依据父 issue 的 FR-WIN-01/02 编写可执行复现与验收清单，写入 `docs/QA-MANUAL-TEST-CHECKLIST-BRA-126.md`（参考模板 `docs/QA-MANUAL-TEST-CHECKLIST-template.md`）。
2. 在真实桌面构造三类场景并记录证据：
   - 大窗口在下、小窗口在上且重叠：悬停重叠区应选上层小窗口；
   - A 完全盖住 B：B 不得被高亮、不得出现在候选/兜底；
   - 部分遮挡：悬停 B 可见区域仍可识别 B。
3. 记录环境（macOS 版本、显示器/缩放）、操作步骤、期望 vs 实际、截图证据。
4. 若本机无法执行某场景，明确写为"需人工实测"并保留可执行步骤，不写成通过。

交付：复现结论 + 验收清单文件路径 + 未执行项清单。
