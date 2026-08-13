# ShotX 用户手测清单（BRA-71，标注对象与录屏菜单）

> 覆盖 PRD v1.8 §1.1 `FR-BRA71-01…06` 及相关回归。团队后台自动验证部分已由 QA 独立复核（本文件 §1）；依赖真实桌面的交互由用户按 §2 实测，结果填「通过 / 未通过 / 无法测试」。

## 0. 交付信息

| 项 | 内容 |
| --- | --- |
| 交付版本 | ShotX 0.1.2（BRA-71 变更单 + BRA-76 修复） |
| 交付基线 | 分支 `agent/bra-71-annotations`（PR #4 更新后 head，BRA-76 B1–B8 已修复） |
| 包体附件 | BRA-76 重新打包（`releases/ShotX-0.1.2.app.zip` / `ShotX-0.1.2-source.zip`） |
| 覆盖需求 | FR-BRA71-01…06（马赛克矩形对象、平滑自由画笔、对象就地选择移动、就地文字编辑、移除分享、录屏设置菜单中心锚定） |
| 交付日期 | 2026-08-13 |
| 手测用时预估 | 约 15 分钟 |

## 1. 团队后台验证证据（QA 独立复核，2026-08-13）

### 1.0 二次独立复核（BRA-75 代码审查，2026-08-13，本仓库）

> 复核对象：分支 `agent/bra-71-annotations` @ `47b3fc3`（对基线 `integrate/bra-55-0.1.2` @ `8cda734` 的三点 diff）。下表命令均在干净检出分支后执行。

| 步骤 | 命令 | 结果 |
| --- | --- | --- |
| 干净检出编译 | `git worktree add <tmp> 47b3fc3 && swift build`（工作树内） | ❌ **失败**：`error: type 'Bundle' has no member 'module'`（CaptureCoordinator.swift:376）；分支提交不含 `Sources/ShotX/Assets/Figma/*.svg`（15 个）与 `Package.swift` 的 `resources: [.process("Assets")]` 声明，属**阻断项 B1** |
| 补齐 Assets+resources 后编译 | 复制工作树 Assets、`resources: [.process("Assets")]` 后 `swift build` | ✅ 编译通过（仅预存 main-actor 闭包警告） |
| 冷缓存单测 | `swift package clean && swift test` | ✅ **55/55 通过**（含 `BRA71AnnotationTests` 17 例；新增 `.ellipse`/`.line` 用例） |
| 无分享静态检查 | `rg -i "NSSharingServicePicker|sharePressed|shareImage|pendingShareImage" Sources Tests` | ✅ 无残留（FR-BRA71-05 代码层达成） |
| 死代码静态检查 | `rg "makeMemoryRow|makeColorSection|makeSizeSection|BrushSlider|updateColorButtons|toolChanged" Sources/ShotX/CaptureCoordinator.swift` | ⚠️ 全部仍在定义，但新 `makeOptionsContent`（144/192 pt 迷你面板）不再调用 → 旧 300 pt 选项面板代码（含取色器、可拖拽滑杆、12 色）为**死代码**（阻断项 B4） |

**复核新增发现（未在执行前变更文档）：**

- **B6（逻辑偏离，FR-BRA71-01）**：`AnnotationView.mouseUp` 丢弃马赛克对象时用 `shape.width < 4 || shape.height < 4`（ResultWindow.swift:261），而 UX 标注 §3.1 要求「两个轴向**均** < 4 pt 才无效」——即单轴 < 4 pt（如 3×50 细条）按 `||` 被错误丢弃；现有 `testMosaicTinyDragIsDiscarded` 只测两轴均小，未覆盖此分支。
- **B7（可访问性，低）**：`makeOptionsContent` 中大小圆点 `setAccessibilityLabel` 字符串为 `"\(tool.styleLabel) (Int(currentSize(for: tool))) (tool.styleRange.unit)"`，`Int(...)` 与 `unit` 未加插值括号，读出为字面文本。
- **B8（范围外改动）**：新增 `.ellipse`/`.line` 两个工具、`#10AEFF` 圆角选区边框与角标、12→6 预设色、暗色图标工具栏/选项胶囊——PRD §1.1 未要求，属范围扩张（UX §2.1 对象表含椭圆/直线，但无对应 FR/GT 验收）。

> ⚠️ **B1（阻断项）**：PR #4 提交内容不含 `Sources/ShotX/Assets/Figma/*.svg`（14 个）与 `Package.swift` 的 `resources: [.process("Assets")]` 声明，而 `CaptureCoordinator.figmaImage` 通过 `Bundle.module` 加载它们——**干净检出该分支直接编译失败**（`error: type 'Bundle' has no member 'module'`）。下表结果是在补齐这两个文件（即工作树中未提交内容）后的重建结果，**不作为分支可交付证据**。

| 步骤 | 命令 | 结果 |
| --- | --- | --- |
| 冷缓存单测 | `swift package clean && swift test` | ✅ 55/55 通过（含新增 `BRA71AnnotationTests` 17 例） |
| Release 构建 | `make app` | ✅ 成功，Info.plist 写入 0.1.2 |
| 签名校验 | `codesign --verify --deep --strict --verbose=2 ShotX.app` | ✅ `valid on disk`，满足 Designated Requirement |
| 静默冒烟启动 | `open ShotX.app` + `pgrep` + 正常退出 | ✅ 进程存活并干净退出 |
| 静态检查（无网络） | `rg -i "urlsession|urlrequest|nwconnection" Sources` | ✅ 无网络调用（仅 SVG 资源内的 xmlns 命名空间，非网络代码） |
| 静态检查（无分享） | `rg -i "NSSharingServicePicker|sharePressed|shareImage|pendingShareImage|分享" Sources Tests` | ✅ 源码与测试无残留 |
| 静态检查（无模态文字输入） | `rg "NSAlert" Sources` | ✅ 无 `NSAlert` 文字输入路径（仅存放弃/保存确认框） |

### 1.1 后台新增/更新用例（BRA71AnnotationTests）

- `testMosaicDragCreatesRectangularObject` / `testMosaicTinyDragIsDiscarded` / `testMosaicStyleLabelUsesBlockSize`（FR-BRA71-01 逻辑）
- `testPenFollowsMouseWithSmoothPath` / `testPenClickBecomesDot` / `testSmoothPathUsesBezierCurvesNotStraightLines` / `testPathHitTestUsesDistanceNotBoundingBox` / `testSelectedPathMovesWithDrag` / `testClickFarFromStrokeDoesNotMoveIt`（FR-BRA71-02/03 逻辑）
- `testTextCommitsInlineWithoutModalAndIsSelectable` / `testDoubleClickReentersTextEditing` / `testEmptyTextCommitCreatesNothingAndEmptyEditDeletes` / `testTextObjectDragMovesWithoutEnteringEdit`（FR-BRA71-04 逻辑）
- `testRecordingSetupPanelCentersOnLargeSelection` / `testRecordingSetupPanelAvoidsTinySelectionBelow` / `testRecordingSetupPanelTallSelectionKeepsHorizontalCenter` / `testRecordingSetupPanelFallsBackInsideVisibleFrame`（FR-BRA71-06 逻辑）

## 2. 手测用例

### 2.1 马赛克矩形对象（FR-BRA71-01）

- **TC-BRA71-01-01**：选择「马赛克」，在选区内按住拖出矩形后松开。期望：生成一块矩形马赛克对象并就地保留，内部按当前块大小像素化；两个轴向 < 4 pt 的拖拽不生成对象。结果：
- **TC-BRA71-01-02**：以曲线轨迹连续拖拽。期望：只生成一个由轨迹起终点定义的矩形对象，无沿轨迹的连续马赛克笔迹。结果：
- **TC-BRA71-01-03**：切到选择工具点击马赛克矩形内部。期望：对象被选中（accent 描边包围盒外扩 4 pt），可拖动移动。结果：
- **TC-BRA71-01-04**：选中马赛克对象后按 `Delete`。期望：对象删除，`Cmd+Z` 恢复。结果：
- **TC-BRA71-01-05**：含马赛克对象时复制到剪贴板并另存 PNG。期望：输出中矩形区域为像素化块，无法通过移除标注恢复底图。结果：
- **TC-BRA71-01-06**：在样式区把块大小 16→24 后再新建一个马赛克。期望：已创建对象不变，新对象用 24 px。结果：

### 2.2 平滑自由画笔（FR-BRA71-02）

- **TC-BRA71-02-01**：选择「画笔」，按住鼠标沿曲线移动后松开。期望：生成一条跟随轨迹的连续平滑路径，拐点无折线突变，非起终点直线。结果：
- **TC-BRA71-02-02**：选择工具下点击路径中部（距路径 ≤ 8 pt）。期望：路径被选中高亮。结果：
- **TC-BRA71-02-03**：路径已选中并拖动。期望：整条路径移动、形状不变。结果：
- **TC-BRA71-02-04**：路径已选中按 `Delete`。期望：删除，`Cmd+Z` 恢复。结果：
- **TC-BRA71-02-05**：点击位于路径包围盒内但距路径 > 8 pt 的空白处。期望：不选中该路径。结果：
- **TC-BRA71-02-06**：单击（无拖动）。期望：生成一个圆点笔迹。结果：

### 2.3 对象就地选择移动（FR-BRA71-03）

> ⚠️ **B2（阻断项）**：新工具栏为 8 个图标按钮，对应 `AnnotationTool.allCases[1…8]`（矩形/椭圆/直线/箭头/画笔/马赛克/文字/裁剪），**不含「选择」工具按钮**；`AnnotationView` 的选择/移动逻辑仅 `tool == .select` 生效。进入标注态默认是选择工具，但一旦切到任一绘制工具后**无法通过工具栏回到选择态**，导致绘制完成后对象不可再选中/移动/删除。下述用例在补齐「选择」入口前无法通过。

- **TC-BRA71-03-01**：依次用箭头、矩形、画笔、马赛克、文字各创建一个对象。期望：对象全部就地保留在画布，不弹出独立结果窗口。结果：
- **TC-BRA71-03-02**：选择工具下单击对象再拖动。期望：对象随鼠标移动；重复点击其他对象转移选中；点击空白取消选中。结果：
- **TC-BRA71-03-03**：选中对象后按方向键 / Shift+方向键。期望：分别移动 1 px / 10 px。结果：
- **TC-BRA71-03-04**：连续创建/移动/删除对象后用 `Cmd+Z` / `Cmd+Shift+Z`。期望：撤销/重做栈 ≥ 20 步正常回退。结果：

### 2.4 画布内就地文字编辑（FR-BRA71-04）

- **TC-BRA71-04-01**：选择「文字」后在选区内单击。期望：点击点出现就地文本框并进入编辑，光标闪烁；无 `NSAlert` 或模态窗口。结果：
- **TC-BRA71-04-02**：输入文字后按 `Return`。期望：提交为文字对象，保留当前颜色/字号，可选中可拖动。结果：
- **TC-BRA71-04-03**：选择工具下双击已有文字对象。期望：重新进入就地编辑，内容/颜色/字号保持。结果：
- **TC-BRA71-04-04**：编辑中在浮层更改字号。期望：输入框内文字字号即时更新。结果：
- **TC-BRA71-04-05**：编辑中按 `Esc`。期望：结束编辑并保留当前文字，不删除对象。结果：
- **TC-BRA71-04-06**：编辑中清空文字后按 `Return` 或点击外部。期望：空文字对象被删除。结果：
- **TC-BRA71-04-07**：编辑中按 `Delete`。期望：只删除光标前字符，不删除对象。结果：

> ⚠️ **B3（阻断项，样式反馈部分）**：FR-BRA71-04 要求「字体颜色、字号及 Figma 已提供的样式控件在画布内即时反映」，但新选项浮层对文字工具仅提供「大小圆点 + T 按钮」，其中 `textStylePressed()` 为 `NSSound.beep()` 空实现；且浮层颜色点仅对非文字、非马赛克工具展示——**文字颜色无法在浮层内更改**。TC-BRA71-04-04 仅字号部分可测；颜色即时反馈用例缺失，需补齐颜色控件后复测。

### 2.5 移除系统分享（FR-BRA71-05）

- **TC-BRA71-05-01**：进入标注态查看工具栏与结果窗口。期望：无「分享」按钮，输出行为为 复制/保存/贴图/关闭。结果：
- **TC-BRA71-05-02**：检查菜单栏与右键菜单。期望：无分享入口。结果：
- **TC-BRA71-05-03**：分别执行复制、保存 PNG、贴图。期望：三者流程与结果正常，语义不变。结果：

### 2.6 录屏设置菜单中心锚定（FR-BRA71-06）

- **TC-BRA71-06-01**：区域录屏框选 1600 × 1000 pt（两方向均大于面板）。期望：设置面板中心与选区中心重合，完整位于显示器可见区；开始录制前可见可操作。结果：
- **TC-BRA71-06-02**：拖动选区边/角调整尺寸。期望：面板中心实时跟随新选区中心（未触发避让时）；原始尺寸 `W × H` 同步刷新。结果：
- **TC-BRA71-06-03**：把选区缩到 240 × 200 pt。期望：面板不覆盖选区，移到选区外（下→上→侧边）且间隔 ≥ 8 pt；「开始录制」始终可见。结果：
- **TC-BRA71-06-04**：中心锚定中手动拖动面板到别处，再移动选区。期望：面板按新选区中心重新锚定。结果：
- **TC-BRA71-06-05**：面板可见时点击「开始录制」。期望：菜单隐藏、选区锁定并进入倒计时；成片画面不含设置菜单。结果：
- **TC-BRA71-06-06**：选区 200 × 1600 pt（仅高度方向小于面板）。期望：水平方向中心对齐，高度方向按避让链偏移，至少一个角把手不被面板遮挡。结果：

### 2.7 回归

- **TC-BRA71-REG-01**：执行区域截图、标注、撤销/重做、复制、保存、贴图、Esc。期望：流程与最近结果语义不变，输出中不含工具栏/浮层/编辑框。结果：
- **TC-BRA71-REG-02**：Retina 与双显示器分别截图。期望：输出物理像素、方向、边界不变；浮层与录屏面板使用当前显示器工作区避让。结果：

## 3. 阻断项与开放问题（QA 记录）

> 2026-08-13 BRA-76 修复：B1–B8 已在 PR #5（`agent/bra-76-fixes @ 704478e`）关闭，见下方逐项标注；桌面交互仍待用户手测（§2）。

- **B1（交付阻断）**：分支提交缺 `Assets/Figma/*.svg` 与 `Package.swift` resources 声明，干净检出无法编译；须将二者纳入 PR 后再交付。**BRA-75 复核已复现（`type 'Bundle' has no member 'module'`）。** → **BRA-76 已修复**：Assets + resources 入提交；`make app` 拷入 `ShotX_ShotX.bundle`。
- **B2（功能阻断，FR-BRA71-03）**：新工具栏无「选择」工具入口，绘制工具使用后无法回到选择态，对象不可选中/移动/删除。**BRA-75 复核确认**：工具栏 8 按钮 tag 0–7 映射 `AnnotationTool.allCases[1…8]`，无 `.select`；`toolChanged(_:)` 分段控件处理器随旧控件删除成死代码。 → **BRA-76 已修复**：工具栏首按钮恢复「选择」；`toolChanged` 死代码已删。
- **B3（功能阻断，FR-BRA71-04 样式部分）**：文字样式「T」按钮为空实现（beep），文字颜色无浮层控件，无法满足「颜色/样式即时反映」。**BRA-75 复核确认**：`textStylePressed() { NSSound.beep() }`；色点在 `!isText && tool != .mosaic` 分支构建，文字工具无颜色入口；GT-71-04-4 无法通过。另：`commitTextEditing()` 对双击重入对象以当前 live 样式覆写存储样式，GT-71-04-3「颜色/字号保持」在样式已变时可能不成立。 → **BRA-76 已修复**：恢复 300pt 样式浮层（文字含颜色与字号滑杆，即时反映）；`commitTextEditing` 改用编辑器当前样式，重入保留原色/字号（`testDoubleClickReentryPreservesStoredColorAndSize`）。
- **B4（回归，FR-CAP-15/16 与旧选项面板）**：BRA-71 分支将旧 300 pt 选项面板（记忆行 + 12 色 + 取色器 + 可拖拽滑杆）替换为 144/192 pt 迷你面板（大小圆点 + 6 预设色），`makeMemoryRow/makeColorSection/makeSizeSection`、`BrushSlider` 及取色器 UI 均成死代码；PRD §1.1 声明「现有 CAP-04/05/07/09/15/16 与本节共同适用」，与 UX 标注 §3.2「拖拽条为默认入口（FR-CAP-16 机制不变）」冲突，需产品确认或恢复。**BRA-75 复核确认死代码范围（含 `toolChanged` 与取色器全套）。** → **BRA-76 已修复**：恢复 300pt 面板 + `BrushSlider` 可拖拽滑杆 + 12 色 + 取色器；马赛克标签为「块大小」。
- **B5（文档，FR-BRA71-05）**：`docs/QA-ACCEPTANCE-MATRIX.md`（CAP-06、§15-3）与旧手测清单仍含「分享」表述，按 FR-BRA71-05「文档不再展示分享」口径需一并清理。**BRA-75 复核确认**：`QA-ACCEPTANCE-MATRIX.md:36`（CAP-06）、`:70`（第 3 行）仍含「分享」；`RELEASE-NOTES.md:21`、`QA-MANUAL-TEST-CHECKLIST-BRA-38.md:56`、`BRA-55:28,56` 亦残留。 → **BRA-76 已修复**：上述文档「分享」已移除，仅保留「已移除（FR-BRA71-05）」说明。
- **B6（逻辑偏离，FR-BRA71-01）**：马赛克丢弃条件用 `||` 而非「两轴均 < 4 pt」的 `&&`，单轴细条被误丢；用例未覆盖。修复：改 `&&` 并加单轴测试。 → **BRA-76 已修复**：改 `&&`，新增 `testMosaicThinStripIsKept`。
- **B7（可访问性，低）**：`sizeDotPressed` 的 `setAccessibilityLabel` 插值缺 `\(`，读出为字面文本。 → **BRA-76 已修复**：迷你面板代码删除，恢复面板用规范插值。
- **B8（范围外）**：`.ellipse`/`.line` 工具、选区边框重绘、12→6 色、暗色工具栏均非 PRD §1.1 内容，需产品确认是否保留。 → **BRA-76 已修复**：撤回 `.ellipse`/`.line` 与视觉重绘，恢复原有工具集、`controlAccentColor` 边框与 12 色。

## 4. 反馈字段

- 通过数 / 总数：/ 34（**需人工实测**：马赛克渲染不可逆、画笔手感、文字就地编辑手感、录屏菜单中心跟随/避让与成片排除——见 §2 各 TC；后台可自动验证部分见 §1/§1.0）
- 未通过用例（TC ID、期望、实际、截图/录屏）：
  - TC-BRA71-03-02/03/04（无选择工具，B2）、TC-BRA71-04-04（颜色即时反馈，B3）、TC-BRA71-01-02 细条情形（`||` 误丢，B6）在修复前无法通过
- 无法测试及原因：全部 §2 手测用例依赖真实桌面交互，本环境无法执行；未执行的手测一律不标记「通过」
- 其他问题与建议：见 §3 B1–B8；先修 B1（交付）→ B2/B3/B6（功能）→ B4/B5（回归/文档）→ B8（产品决策）
