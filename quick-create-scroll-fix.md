## User request

首先，我自己对项目代码进行了一系列加工，请检查项目文件后再定位问题。

其次，现在 0.1.12 版本的滚动截屏，截出来的图是有高度的，但内容是不断的重复，根本没法用，帮我修复一下。

## Context

- 仓库当前 HEAD 为 commit `f15a926`（版本 0.1.12），工作区干净。
- 滚动截屏实现在 `Sources/ShotX/ScrollingCaptureCoordinator.swift`：自动监听选区内的滚轮事件、节流采样，用 `ScrollingOverlapMatcher.overlap(old:new:)` 做重叠匹配后裁剪拼接（`ScrollingSession.capture()`，`ScrollingCaptureCoordinator.swift:224`）。
- 症状为"有高度但内容重复"，指向重叠匹配/裁剪拼接阶段输出重复段；现有 `Tests/ShotXTests` 中尚无针对滚动截屏的自动化测试。
