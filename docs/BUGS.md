# ShotX 当前已知问题与缺陷清单（BUGS）

> 更新基准：仓库工作树 `agent/bra-107-font` @ `96d7399`（"1.19"），版本 **0.1.20**，`swift test` 114/114 通过。
> 整理日期：2026-08-17。
>
> 说明：本清单分三层——A. 代码中确认仍存在 / 尚未合入的缺陷；B. 需真机或用户实测的残余风险；C. 设计待确认或明确未实现项。每一项都标注证据位置，不推测、不编造。

## A. 代码中确认仍存在 / 尚未合入的缺陷

这些缺陷在工单追踪里可能已被标记"完成"，但**当前工作树代码中仍未包含修复**（修复只在其他 agent 分支上，未合入本分支），请在真机上按步骤复现确认。

### A1. 持续拖动选择矩形框仍可能崩溃（"No current point for line"）

- **复现**：截图（区域）或录屏（区域录制）时按住鼠标持续来回拖动选区，把选区压到极小（宽或高 < 6pt）后不松手。
- **根因**：`resizeSelection`（`Sources/ShotX/CaptureCoordinator.swift:1427` 附近）允许选区缩到 1×1；`SelectionView.draw`（`CaptureCoordinator.swift:642-647`）、`RecordingRegionBorderView.draw`（`RecordingCoordinator.swift:1366-1371`）、`ScrollingSelectionView.draw`（`ScrollingCaptureCoordinator.swift:421-431`）对 `< 2×inset` 的矩形执行 `insetBy(3,3)/(2,2)` 会得到 `CGRect.null`（坐标 ±inf），直接交给 `NSBezierPath.move/line` 抛 "No current point for line" 崩溃。
- **证据**：当前工作树三个文件均无 `isFinite`/`accentRect` 守卫（`rg "accentRect|isFinite"` 无结果）。含守卫的修复只存在于分支 `agent/agent/4990471f`，未合入当前分支。
- **对应工单**：BRA-133 / BRA-137 / BRA-139 / BRA-142（已 done，但修复未出现在当前代码）。

### A2. 窗口截图识别不准确（被遮挡窗口被识别、重叠时选错层级）

- **复现**：窗口截图模式下，A 窗口完全盖住 B 窗口时仍可能高亮/捕获 B；或大窗口在下、小窗口在上且重叠时，悬停重叠区选错目标。
- **根因**：`captureWindows(in:)`（`CaptureCoordinator.swift:278`）仅按 `isOnScreen && windowLayer == 0 && 非自身 && 尺寸>40×40` 过滤，`isOnScreen` 不排除被完全遮挡窗口；`mouseMoved`（`CaptureCoordinator.swift:602`）用 `windows.first { $0.frame.contains(...) }`，而 `SCShareableContent.windows` 顺序不保证 z-order。
- **证据**：当前工作树无 `CGWindowListCopyWindowInfo`、无遮挡/z-order 排序逻辑。修复（BRA-128）未合入当前分支。
- **对应工单**：BRA-126 / BRA-127 / BRA-128 / BRA-129（已 done，但修复未出现在当前代码）。

### A3. 「窗口截图保留阴影」设置无效

- **现象**：设置页有「窗口截图保留阴影」开关（`SettingsView.swift:92`，`AppModel.swift:79` `windowShadow`），但任何捕获路径都没有使用该值；勾不勾选对截图结果无影响。
- **证据**：`rg "windowShadow"` 仅命中设置项本身；捕获使用冻结整屏图像中窗口矩形，无独立阴影捕获。
- **来源**：`docs/FEATURE-AUDIT-2026-08-15.md` P0-3。

### A4. 滚动截图暂停原因对用户不可见

- **现象**：滚动拼接暂停时（无法匹配/滚动过快/到达上限），预览上没有可见的状态文字。
- **根因**：暂停消息只写入窗口辅助功能值 `window?.setAccessibilityValue(message...)`（`ScrollingCaptureCoordinator.swift:400`），未渲染为预览可见文字。
- **证据**：`updatePanel` → `panel.update(..., message:)` → 仅 `setAccessibilityValue`。
- **来源**：`FEATURE-AUDIT-2026-08-15.md` P0-2。

### A5. 滚动截图没有「撤销上一段 / 手动暂停」

- **现象**：滚动截图过程只有 取消 / 贴图 / 保存 / 复制，无撤销上一段或手动暂停。
- **证据**：`ScrollingCaptureCoordinator.swift` 无 undo/pause 相关实现。
- **来源**：`FEATURE-AUDIT-2026-08-15.md` P1-2。

### A6. 视频预览没有裁剪（去头尾）能力

- **现象**：录屏结果窗口只有 播放 / 保存 / 复制 / 访达，没有「只剪去开头和结尾」的导出能力。
- **证据**：`VideoResultWindowController`（`ResultWindow.swift:758`）无 `AVAssetExportSession`/裁剪代码；当前测试目录中也没有 `testVideoTrimFractionsRemainOrderedAndBounded` 用例。
- **来源**：`FEATURE-AUDIT-2026-08-15.md` P1-3；与 `IMPLEMENTATION.md` FR-REC-07 的描述存在出入（已无对应实现）。

### A7. 多显示器 / 声画同步 / 摄像头画中画仅有逻辑测试，无真机验收

- **现象**：坐标换算、混音对齐、画中画合成都有单测，但外接屏垂直排列/不同缩放、真机声画同步、摄像头方向/画中画旋转没有真实设备验收证据。
- **来源**：`FEATURE-AUDIT-2026-08-15.md` P0-6；`QA-ACCEPTANCE-REPORT-BRA-113.md` D1；`QA-ACCEPTANCE-REPORT-BRA-102.md` D3。

### A8. 滚动截图仍无真实桌面验收

- **现象**：滚动拼接基于「滚轮事件 + 每 140ms 采样 + 像素重叠匹配」，不是 macOS 原生长截图 API；动态广告、视频、虚拟列表、大面积重复纹理、过快滚动仍可能暂停。只做过逻辑测试，未用真实 Finder/浏览器/编辑器样本验收。
- **来源**：`FEATURE-AUDIT-2026-08-15.md` P0-1。

## B. 需真机 / 用户实测确认的残余风险

| 项 | 内容 | 来源 |
| --- | --- | --- |
| B1 | 录屏系统声 + 麦克风真机同步：若两路 PTS 存在时钟域漂移，长录制（≥数分钟）声画同步误差可能超过 200ms 目标 | `QA-ACCEPTANCE-REPORT-BRA-113.md` D1 |
| B2 | 摄像头权限弹窗可能在 O-RSET 设置面板（`screenSaver+1` 级）之下被遮挡，导致无法点击授权 | `QA-ACCEPTANCE-REPORT-BRA-102.md` D1 |
| B3 | 生产路径无法区分「权限被系统抑制」与「用户拒绝」：若激活策略在某 macOS 版本上失效，首次权限申请可能再次静默失败 | `QA-ACCEPTANCE-REPORT-BRA-120.md` R1 |
| B4 | 摄像头画中画的方向/旋转（预览层与合成帧口径）需真实摄像头逐像素对比 | `QA-ACCEPTANCE-REPORT-BRA-102.md` D3 |
| B5 | 持续拖动崩溃修复（A1）与窗口识别修复（A2）在真机上的效果需按复现步骤实测 | 本清单 A1/A2 |
| B6 | 模糊背景开关不会主动开启系统「人像效果」，未开启时开关回退并提示——属诚实降级，但需用户确认可接受 | `QA-ACCEPTANCE-REPORT-BRA-102.md` D2 |

## C. 设计待确认 / 明确未实现项

| 项 | 内容 | 状态 |
| --- | --- | --- |
| C1 | `O-REC` 录制浮动条内「磁盘状态图标」未实现，磁盘保护仍走模态 alert | 设计标注标为待确认；需产品决策 |
| C2 | 提示形态为模态 alert 而非设计中的横幅 | 设计标注待确认 5；需产品决策 |
| C3 | 字体仅覆盖 cmap 内 109 字形，未覆盖字符回退系统字体 | 属 BRA-107 既定验收口径，非缺陷 |
| C4 | 旧版独立截图结果窗口代码路径仍可被内部旧模式调到 | 建议后续收敛删除 |
| C5 | Dropover 与主工具栏只有行为测试，无像素级视觉回归 | 需用 Figma 对比图验收 |

## 追踪状态与当前代码差异提示

- 工单追踪里 A1（BRA-133 系列）与 A2（BRA-126 系列）均已标记 **done**，但**当前工作树未包含对应修复代码**（修复位于未合入的 agent 分支 `agent/agent/4990471f` 等）。请以"当前代码是否含修复"为准做真机验证，勿以工单状态替代。
- 若在真机上确认 A1/A2 仍可复现，应回到原工单补充合入，而不是另开新缺陷。

## 建议的处理优先级

1. 高：A1 崩溃（紧急）→ A2 窗口识别 → 将对应修复合入当前分支并回归。
2. 中：A3 阴影开关、A4 暂停原因可见、A5 撤销/暂停、A6 视频裁剪（若产品仍要求）。
3. 低/决策项：B 系列真机验收、C 系列设计确认。
