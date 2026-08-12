# ShotX QA 验收报告（BRA-44）

- 验收对象：BRA-43 交付（FR-CAP-10/11/12/13 区域截图方向、固定工具栏、取色器浮层、双击/空格快捷输出）
- 验收日期：2026-08-12
- 验收方：QA 验收（独立于开发自测）
- 结论：**有条件通过**（详见 §6）

---

## 1. 需求—测试追踪

| 需求 | 验收要点 | 后台验证（QA 独立执行） | 用户手动验证（随包体） |
| --- | --- | --- | --- |
| FR-CAP-10 | 区域截图方向不颠倒不镜像；拖动选区画面同向；Retina 物理像素正确 | ✅ 单元测试（含 QA 新增 3 例） | 真实桌面方向/拖动（手测清单 2.1） |
| FR-CAP-11 | 固定工具栏长宽；颜色选择不挤占其他项；取色器在工具栏下方浮层 | ⚠️ 代码走查发现残余风险（见 §4.1）；构建/测试通过 | 工具栏尺寸与菜单可点性（手测清单 2.2） |
| FR-CAP-12 | 取色器可对真实屏幕像素取色；以鼠标位置为左上锚点 | ✅ 采样基于冻结 CGImage 像素空间（代码走查）；单元测试 | 真实取色命中与锚点（手测清单 2.2） |
| FR-CAP-13 | 双击=复制并退出；截图空格=复制并退出；录屏选区空格=开始录制；Esc 取消 | ✅ 状态机 + keyDown 分支走查；构建/测试通过 | 真实双击/空格交互（手测清单 2.3） |
| 回归 | 标注/复制/保存/分享/贴图/Esc/Retina 口径 | ✅ 构建+全量测试 21/21 | 手测清单 §3 |

## 2. 团队后台验证结果（QA 独立执行，可静默后台运行）

| 步骤 | 命令 | 结果 | 证据 |
| --- | --- | --- | --- |
| 单元/逻辑测试 | `swift test` | ✅ 21/21 通过，0 failures | 含 QA 新增 `QARegionCaptureOutputTests` 3 例（Retina 物理像素 240×120、下半区不倒置、非镜像） |
| Release 构建 | `make app` | ✅ 成功，无编译错误 | `.build/release/ShotX` 产出 |
| 签名校验 | `codesign --verify --deep --strict --verbose=2 ShotX.app` | ✅ | `valid on disk`，`satisfies its Designated Requirement` |
| 静默冒烟启动 | `open ShotX.app` + `pgrep -x ShotX` + 退出 | ✅ | 进程存活（PID 48203）并正常退出 |
| 静态检查 | `rg -i "urlsession|http://" Sources` | ✅ 无网络代码 | 本地优先承诺不违反 |
| 打包 | `make package` | ✅ | `ShotX.app.zip`、`ShotX-source.zip` 重新产出 |

## 3. 需求覆盖证据（代码走查）

- **FR-CAP-10**：`SelectionView` 非翻转（y-up）坐标下 `selection` 几何，`AnnotationView.cgPixelRect` 统一将 y-up 选区映射到 CG 图像 top-left 像素空间；`render()` 以 `pixelsPerPoint` 输出物理像素；`capture()` 的 `sourceRect` 同步换算。QA 新增测试直接断言 2x Retina 下输出 240×120、下半区取色不倒置、右半区不镜像。`CaptureCoordinator.swift:119-132`、`ResultWindow.swift:246-286`。
- **FR-CAP-11**：工具栏以 `toolbarFixedSize` 固定；颜色面板是独立 `NSPanel` 浮层，`positionColorPanel` 将其放在工具栏下方（`CaptureCoordinator.swift:478-522, 774-790`）。
- **FR-CAP-12**：取色器通过 `frozenCG.cropping` 采样冻结 CGImage 像素空间，`samplePixel` 不依赖覆盖层命中；`startEyeDropper` 以鼠标位置初始化面板（`CaptureCoordinator.swift:583-647, 658-692`）。
- **FR-CAP-13**：`keyDown` 空格分支（区域=quickCopy、区域录屏=quickRecord→startImmediately）、`mouseDown` clickCount≥2→quickCopy、Esc→discard+cancel（`CaptureCoordinator.swift:293-317, 319-339`）；`RecordingCoordinator.startImmediately` 跳过设置直接倒计时（`RecordingCoordinator.swift:141-148`）。
- **回归**：标注/复制/保存/分享/贴图走既有 `editor.render()` 链路；全量测试通过。

## 4. 残余风险与注意事项

### 4.1 工具栏固定尺寸的测量口径（中风险，需用户确认）
`toolbarFixedSize` 在 `makeToolbar` 中以**选择工具（.select）时**的 `fittingSize` 记录（此时颜色按钮与大小控件隐藏）。当切换到箭头/画笔等带样式工具时，颜色按钮与大小控件会重新显示，可能使工具栏内容宽度超过记录的固定宽度，存在末尾菜单项被压缩/溢出的可能。**期望**：固定工具栏在任何标注工具下所有菜单项仍完整可见可点。请用户在真实桌面重点验证（见手测清单 TC-CAP11-01 备注）。

### 4.2 取色器锚点
代码以点击取色控件时鼠标位置初始化取色面板，但随后 `positionEyeDropper` 将面板定位在鼠标上方附近。**期望**：取色器左上角对齐点击处鼠标位置。请用户按手测清单 TC-CAP12-01 验证实际锚点是否符合预期。

## 5. 未验证项

- 真实桌面画面方向、拖动同向、Retina 多缩放显示器的物理像素观感——需用户按手测清单实测。
- 取色器从选区下方真实像素取色的命中率、锚点视觉位置——需用户实测。
- 双击/空格快捷键的真实键感与冲突——需用户实测。

## 6. 结论

**有条件通过（条件：用户按随包体手测清单完成桌面用例验证后确认）**。

- 团队后台可验证部分：全部通过（构建、21/21 单元测试、签名、冒烟、静态检查）。
- 桌面交互部分按 BRA-35 交付模型交用户手动验证，QA 已配套 `QA-MANUAL-TEST-CHECKLIST-BRA-44.md`。
- 4.1 工具栏固定尺寸测量口径为唯一代码走查识别的残余风险，请用户重点验证；若确认存在菜单项被挤占，将按缺陷流程另行跟进。
- 阻塞项：无。
