# ShotX QA 复验报告（BRA-55）

- 验收对象：BRA-56～60 修复集合（FR-CAP-14/15/16）
- 固定基线：`6a5a92f2f04d217955689ad26d66f5f63e6a9d2f`（PRD v1.7）
- 复验版本：工作区实现 + 干净主干 `28c2eab`
- 验收日期：2026-08-12
- 验收方：代码审查（独立于实现者）
- 结论：**不通过，仍阻断发布**

## 1. 原五项缺陷复验

| 原缺陷 | 复验结论 | 证据 |
| --- | --- | --- |
| BRA-56 实时样式数据源 | ✅ 闭环 | `AnnotationView.applyStyleLive` 已成为拖动实时路径，新绘制读取 editor 的实时颜色/尺寸；`applyStyle` 复用该实现 |
| BRA-57 键盘与 VoiceOver | ❌ 部分闭环 | 焦点回路、AX value/state 已补；但 UX §14.2 要求的浮层展开公告与滑杆值节流公告仍未实现 |
| BRA-58 窄/矮屏响应式 | ❌ 部分闭环 | 300 pt 浮层与矮屏滚动已补；但两行布局的工具行仍约 546 pt，500 pt 工作区下无法保持 8 pt 边距且不越界 |
| BRA-59 版本与发布门 | ❌ 未闭环 | 旧 0.1.0 包已恢复，Makefile/release notes 已到 0.1.1；但此前已实际构建 0.1.1，下一唯一候选必须是 0.1.2，且修复尚未完整提交/review/合并 |
| BRA-60 输出前关闭浮层 | ✅ 闭环 | 复制、保存、分享、贴图统一先关闭选项浮层 |

## 2. 团队后台验证证据

按 `docs/QA-BACKGROUND-TEST-LOOP.md` 从 clean build cache 执行；未操控用户桌面。

| 步骤 | 命令 / 对象 | 结果 | 关键证据 |
| --- | --- | --- | --- |
| 固定点与 diff | `git diff 6a5a92f` | ✅ | fixed point 可解析，diff 非空；提交为 `360a112`、`28c2eab` |
| 工作区单元测试 | `swift package clean && swift test` | ✅ | 33/33，0 failures |
| 工作区 Release 构建 | `make app` | ✅ | Release build 完成；仅有既有 Swift actor-isolation warnings |
| 签名 | `codesign --verify --deep --strict --verbose=2 ShotX.app` | ✅ | `valid on disk`，满足 designated requirement |
| 版本字段 | `Info.plist` | ⚠️ | 当前 app 为 0.1.1；下一唯一候选应为 0.1.2 |
| 静默冒烟 | 后台启动、`pgrep -x ShotX`、终止 | ✅ | 进程存活并正常退出，无桌面交互 |
| 静态检查 | `rg` 网络 API | ✅ | 无网络调用 |
| 干净主干复现 | 从 `HEAD=28c2eab` 导出到独立目录后 `swift test` | ❌ | 编译失败：提交代码引用未提交的 `AnnotationTool.styleRange`、AX helper、`AnnotationView.applyStyleLive/styleSize` |
| 工作区/发布门 | `git status --short`、PR 关联 | ❌ | 8 个已修改、3 个未跟踪文件；BRA-55 无关联 PR，修复未完成独立 review/merge/clean gate |
| 正式打包 | 0.1.2 | ⏭️ 跳过 | 前置门失败，未生成不可追溯候选包 |

## 3. Standards 轴

1. **硬违反仍在：发布门未闭环。** `Makefile:1` 已为 0.1.1，`docs/RELEASE-NOTES.md` 已补 0.1.1，两份 0.1.0 发布物与 fixed point 一致，原版本权威分叉和旧包污染已修复。但 BRA-55 已实际构建过 0.1.1，依 `docs/RELEASE-AND-TEST-POLICY.md:8-9,18,24,30,38-44`，下一唯一候选应为 0.1.2。当前修复仍散落在未提交工作区，干净主干无法编译，也无关联 PR，不能出包。
2. 原重复代码问题已闭环：`ResultWindow.swift:214-226` 的 `applyStyle` 已委托 `applyStyleLive`，switch 仅保留一份。

Standards：1 项阻断 finding。

## 4. Spec 轴

1. **高：VoiceOver 公告仍缺失。** UX §14.2 `docs/shotx-ux-ui-spec.md:513` 要求浮层展开时公告“样式，颜色和粗细”，滑杆变化按不超过每 500 ms 一次公告；`CaptureCoordinator.swift:561-577,855-873` 仅设置焦点和 AX value，未发送 `NSAccessibility` announcement。最小修复：展开时公告一次，滑动时节流公告，并留最小 AX 通知检查。
2. **中：窄屏两行仍可能越界。** UX §7.1 `docs/shotx-ux-ui-spec.md:208` 要求工具栏在可用工作区内贴边；`CaptureCoordinator.swift:522-531` 的两行仍保留约 546 pt 工具行，`:1012-1019` 对 500 pt 工作区无法同时满足包含关系与 8 pt 边距。最小修复：压缩或进一步分排控件，使每行不超过 `visibleWidth - 16`，并断言最终 toolbar frame containment。

实时样式数据源、300 pt 浮层/矮屏滚动、输出前关闭浮层已闭环；无 scope creep。Spec：2 项 finding。

## 5. 候选版本与桌面手测

- 下一唯一版本：**0.1.2**。
- 本次因干净主干编译失败且 clean/review/merge gate 未满足，**没有生成 0.1.2 包体**；0.1.1 不得重复打包。
- `QA-MANUAL-TEST-CHECKLIST-BRA-55.md` 已切换为 0.1.2 待交付清单。桌面交互用例保持待用户手测，须在修复合入、工作区清洁并生成 0.1.2 后随包体交付。

## 6. 结论

**不通过。** 工作区 33/33 测试、Release 构建、签名、静默冒烟与无网络检查通过，但干净主干无法编译，发布门失败；同时仍有 1 个高优先级 VoiceOver 缺陷和 1 个中优先级窄屏越界缺陷。BRA-55 不能收口，也不能产出正式候选。
