# ShotX BRA-107 字体替换标注（Alimama FangYuanTi VF 应用范围与回退）

版本：v1.0
平台：macOS 14+，菜单栏应用
需求来源：BRA-107（父工单，用户请求）；设计任务：BRA-108（本工单）
交付对象：macOS 客户端（Stage 2 实现）、QA
范围：只做设计标注，不改 Swift 代码

## 1. 结论摘要

把 Alimama 字体应用到**截图文字标注工具（O-ANN 文字工具）**这一处用户生成内容，其余全部界面文字保留系统/等宽字体。原因是该字体是 **109 字形子集**（未覆盖绝大多数 UI 文案所需汉字，如「中/文/截/图/屏」），无法作为全局 UI 字体。是否换用完整字体文件、是否扩大应用范围，见 §8 待确认，交回 PM/用户决策。

## 2. 字体文件事实（已用 fontTools 复核）

| 项 | 值 | 备注 |
| --- | --- | --- |
| 文件 | `Sources/ShotX/font/AlimamaFangYuanTiVF-Bold-sub.ttf` | 未纳入 git（untracked），Stage 2 负责随包分发 |
| 字族名（nameID 1/4） | `Alimama FangYuanTi VF` | 代码注册/按族名引用时使用 |
| PostScript 名（nameID 6） | `AlimamaFangYuanTiVF-Thin` | `NSFont(name:)` 引用时建议使用 PS 名 |
| 子族（nameID 2） | `Regular`；无 16/17 风格族名 | 单静态实例 |
| fvar | 无 | 名为 VF 但为静态实例，无可变轴 |
| usWeightClass | 700（Bold） | 不可再叠加合成粗体 |
| unitsPerEm / asc / desc | 1000 / 850 / −150 | — |
| glyphs / cmap | 123 / 109 | — |

**cmap 覆盖（109 字形，全量清单）**：

- 62 ASCII 字母数字：`A–Z a–z 0–9` 全覆盖。
- 36 汉字：`像克制化器声大头始小平度开录扬摄放明景智标水缩置美翻背能虚设转透颜风麦鼠`。
- 11 标点/符号：`（空格） * - : = · 、 。 ， ： ～`。

**未覆盖的关键字（QA 写用例依据）**：`中 文 截 图 屏 区 域 画 面 时 间 尺 寸 复 制 保 存 分 享 标 注 撤 销 重 做 确 认 取 消 停 止 指 针 关 闭 返 回 进 入 导 出 像 素 颜 色 宽 度 高 度 字 号 粗 细 声 音 滚 轮 暂 停 继 续 完 成 预 览`。

> 口径更正：BRA-108 任务描述称「少量标点与个别汉字（如『录』）」。实测为 **36 个汉字 + 11 个标点/符号**，上表为全量，实现/QA 以本表为准。

## 3. 替换 / 保留 / 回退决策矩阵

| # | 界面 / 元素 | 当前字体（已核实） | 决策 | 实现级标注 |
| --- | --- | --- | --- | --- |
| 1 | **O-ANN 文字标注**（用户输入的文字对象） | `systemFont(ofSize:weight:.semibold)` | **替换为 Alimama** | 单一字体工厂，替换 `ResultWindow.swift` 6 处调用，见 §4 |
| 2 | O-ANN 工具栏工具/输出按钮 | SVG 图标，无文字 | 不适用 | — |
| 3 | O-ANN 记忆值回显「箭头 · 颜色 红 · 2 pt」 | `systemFont(13, .semibold)`（CaptureCoordinator.swift:1000） | 保留系统 | 浮层控件文案，字形覆盖不足 |
| 4 | O-ANN 浮层尺寸区标题 / 数值 | `systemFont(12, .semibold)` / `monospacedDigitSystemFont(12, .medium)`（:1060 / :1056） | 保留 | 数值等宽保证对齐 |
| 5 | O-SEL 顶部模式/尺寸/快捷键提示条 | `monospacedSystemFont(13, .medium)`（CaptureCoordinator.swift:675） | 保留 | 尺寸数字等宽优先 |
| 6 | 取色器放大镜 RGB / HEX | `monospacedDigitSystemFont(11)`（:1468/:1470） | 保留 | HEX 必须等宽 |
| 7 | O-RSET 标题「录制设置」/「MP4」标签 | SwiftUI `.title3.bold()` / `.caption.bold()`（RecordingCoordinator.swift:692–693） | 保留 | 「录制设置」两字均未覆盖 |
| 8 | O-RSET 声音/鼠标/原始尺寸/倒计时 分组 | SwiftUI 默认系统字体 | 保留 | 面板正文 |
| 9 | O-COUNT 倒计时数字 3/2/1 | SVG 资产 `record-countdown-{1,2,3}.svg` | 保留（资产） | 如需 Alimama 数字须重制 SVG，见 §8 待确认 3 |
| 10 | O-REC 时长 `00:00` | `monospacedDigitSystemFont(16, .bold)`（RecordingCoordinator.swift:858） | 保留等宽 | 计时跳动对齐 |
| 11 | O-REC 停止按钮 | `systemFont(18, .bold)`（:861），背景为 SVG | 保留 | 按钮背景为资产图 |
| 12 | W-SET 设置窗口 | SwiftUI 默认系统字体（SettingsView.swift） | 保留 | — |
| 13 | W-PROC / W-TRIM / D-DISCARD / W-RECOVERY | 原生控件默认 | 保留 | — |
| 14 | P-PIN 控制条「透明度/缩放」标签与数值 | `systemFont(10, .bold)`（ResultWindow.swift:632–633） | 保留 | 图上小字需易读，圆体 10 pt 辨识度低 |
| 15 | 滚动截图预览尺寸标签 | `monospacedSystemFont(11, .medium)`（ScrollingCaptureCoordinator.swift:382） | 保留等宽 | 拼接尺寸数字 |
| 16 | 菜单栏 M-BAR | 原生 NSMenu | 保留 | 系统菜单不改字体 |

## 4. 文字标注字体替换（唯一替换点）详细标注

### 4.1 替换对象

`O-ANN` 文字工具创建、编辑、渲染的文字对象（`AnnotationTextStyle` 的四种样式：normal / outlined / inverseOutlined / highlight 均同字）。

### 4.2 字体工厂

新增单一工厂，全部替换点共用（实现不得在别处再直接写字体）：

```swift
static func annotationFont(size: CGFloat) -> NSFont {
    NSFont(name: "AlimamaFangYuanTiVF-Thin", size: size)
        ?? NSFont.systemFont(ofSize: size, weight: .semibold)
}
```

- 使用 **PostScript 名** `AlimamaFangYuanTiVF-Thin`（nameID 6）注册后按名取用；族名 `Alimama FangYuanTi VF` 亦可，实现须在真机上确认解析结果一致（元数据不一致见 §8 待确认 2）。
- **不加合成粗体**：字体本身为 Bold 权重（usWeightClass 700），替换后把原 `.semibold` 去掉，不调用 `NSFontManager.convert(.bold)`。

### 4.3 替换点清单（`Sources/ShotX/ResultWindow.swift`）

| 行 | 用途 | 替换要求 |
| --- | --- | --- |
| :240 | 文字编辑框 `NSTextField.font` | 用 `annotationFont(size:)` |
| :252 | 编辑态宽度测量 `text.size(withAttributes:)` | 同字体工厂 |
| :255 | 编辑框 `NSTextField.font`（重入编辑） | 同字体工厂 |
| :310 | 样式实时变更时重测量（`applyStyleLive`） | 同字体工厂 |
| :406 | 渲染 `drawText` 的 `NSFont` | 同字体工厂（四种样式共用） |
| :467 | 命中/边界 `bounds(of:)` 测量 | 同字体工厂 |

> 六处必须同一工厂，保证**编辑框宽度、命中 bounds、绘制字形三者一致**，避免输入框与落盘文字宽度漂移（QA 用例见 §7 T-3）。

### 4.4 字号与字重

- 字号范围与档位**不变**：11–13–16–24–32 pt，可拖拽连续 11–32，默认 16（FR-CAP-15/16 沿用）。
- 字重不暴露给用户；Alimama 以自身 Bold 面貌呈现，视觉略重于原 `.semibold`，属预期。

### 4.5 文本样式

四种 `AnnotationTextStyle` 的描边/高亮逻辑不变，只是底字换字体。高亮样式（highlight）背景矩形测量同样走 :406/:467 的同一字体，无需单独改动。

## 5. 缺失字形回退规则

1. **回退方式**：Alimama 仅用于文字标注；渲染时依赖 AppKit **逐字形级联回退**（`NSFont(name:)` 构造 + `NSAttributedString`/`draw`），**不做**代码级按字符手工切换字体。
2. **预期渲染结果**（QA 按此写用例）：
   - 全覆盖串（`123`、`abc`、`录`、`Alimama 2026`）→ 全部 Alimama 圆体。
   - 未覆盖汉字（`截图`、`区域`）→ 全部回退系统字体，视觉等同现状。
   - **混合串**（`录屏`：`录` 有字形、`屏` 无）→ 「录」圆体 + 「屏」系统字体混排。这是子集字体的固有限制，**默认接受**；若不可接受，须换完整字体（§8 待确认 1）。
3. **对齐/度量**：回退不改变字号与基线；不要为回退字形额外设置不同 font 或 size。
4. **无障碍**：字体替换不影响 VoiceOver 标签、焦点与对比度，无新增 a11y 工作。

## 6. 排版令牌更新（`docs/shotx-ux-ui-spec.md` §12.1）

在既有令牌表新增一行并补充备注（不改动既有行值）：

| 令牌 | 值 | 用途 |
| --- | --- | --- |
| `font-annotation` | Alimama FangYuanTi VF（Bold 静态实例），11–32 pt，不加合成粗体 | 截图文字标注工具（O-ANN 文字工具） |

- `font-countdown` 保持 `SF Pro Display 72/80 bold`，但**备注口径**：`O-COUNT` 实际渲染为 SVG 资产 `record-countdown-{1,2,3}.svg`，该令牌仅在未来改为运行时文字渲染时生效；本阶段不适用。
- `font-mono`（SF Mono）保持，覆盖像素尺寸、HEX、时长等全部等宽场景。
- 资源清单 §12.3 新增第 5 项：`AlimamaFangYuanTiVF-Bold-sub.ttf`（app 内嵌字体资源，见 §7）。
- 口径说明：BRA-108 任务描述称字体令牌位于规范「§4」，实际令牌表位于 `shotx-ux-ui-spec.md` **§12.1 设计令牌**；更新以此为准，§4 无字体令牌。

## 7. 打包说明（Stage 2 客户端据此实现）

1. **SwiftPM 资源**：`Package.swift` 的 `ShotX` target 增加 `resources: [.process("Assets"), .process("font")]`，`font` 目录下 ttf 进入 `ShotX_ShotX.bundle`，产物名 `AlimamaFangYuanTiVF-Bold-sub.ttf`。
2. **运行期注册**：App 启动时用 `CTFontManagerRegisterFontsForURL(url, .process, nil)` 注册一次。加载路径沿用现有资产代码的双保险模式（`Bundle.main.resourceURL?.../ShotX_ShotX.bundle` 兜底 `Bundle.module`），即 `RecordingCoordinator.recordingImage` / `CaptureCoordinator.figmaIcon` 同款路径逻辑。
3. **打包产物**：`ShotX.app/Contents/Resources/ShotX_ShotX.bundle/` 内含该 ttf；QA 验证产物而非源码目录。
4. **git**：ttf 当前未被 git 跟踪；Stage 2 需 `git add` 该文件，否则 CI/打包环境缺失资源。

## 8. 待确认（交回 PM/用户决策，不改需求）

1. **完整字体文件**：是否提供完整版 `Alimama FangYuanTi`（非 109 字形子集）？若提供，混合字形问题消除，且可评估扩大应用范围（如 P-PIN 标签、O-COUNT 数字、浮层控件）。
2. **字体元数据不一致**：文件名带「Bold」，内部 usWeightClass=700（Bold），但 PostScript 名为 `...Thin`、子族为 `Regular`。需确认注册引用名与文件重命名方案；在确认前实现按 §4.2 的 PS 名 + 兜底系统字体执行。
3. **O-COUNT 数字是否要 Alimama**：默认否（保留 SVG 资产）；如需，改为用 Alimama 面重制 `record-countdown-{1,2,3}.svg`（数字 0–9 均在字形覆盖内，属资产重做任务，不属本次字体替换）。
4. **混合字形接受度**：文字标注中出现「录屏」这类混合渲染是否可接受。默认接受，等待待确认 1 的完整字体。

## 9. QA 验收用例（对应验收标准逐条可测）

| ID | 步骤 | 期望 |
| --- | --- | --- |
| T-1 | 文字标注输入 `123 abc 录` | 全部 Alimama 圆体渲染 |
| T-2 | 文字标注输入 `截图` | 全部回退系统字体，无崩溃、无框错位 |
| T-3 | 文字标注输入 `录屏` 后拖拽/重入编辑 | 编辑框宽度 = 落盘字形宽度（测量/绘制同字体，无漂移） |
| T-4 | 切换四种文字样式（描边/反描/高亮） | 底字为 Alimama，描边高亮逻辑不变 |
| T-5 | 改变字号 11→32 | 档位与连续拖拽沿用现有规则，仅字形换 |
| T-6 | 倒计时 3/2/1、O-REC 时长、尺寸/HEX/拼接尺寸 | 全部保持等宽/系统字体，无回归（对照 §3 矩阵保留项） |
| T-7 | 打包产物检查 | `ShotX_ShotX.bundle` 内含 ttf；App 启动字体注册成功 |
| T-8 | 重启 App 后文字标注 | 字体仍生效（启动注册幂等） |

## 10. 假设与未覆盖

- 假设：用户请求的「换成字体」以**能正确渲染为前提**，在字形子集受限时只替换用户生成内容，不强行替换系统 UI。
- 假设：`NSFont(name:)` 按 PostScript 名可解析（注册成功后）。若解析失败，工厂兜底系统字体，功能不回退。
- 未覆盖：菜单栏、设置窗口、分享面板等原生 UI 的字体；P1 需求；iOS 平台。
- 未覆盖：替换后重新生成任何 SVG 资产（除 §8 待确认 3 的倒计时数字外）。
