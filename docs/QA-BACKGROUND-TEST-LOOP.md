# ShotX 团队后台测试闭环清单（BRA-35/37 修订版）

> 团队侧只执行不依赖操控桌面的后台验证。本清单为每次 feature 交付的标准闭环，顺序执行并记录结果；任何依赖真实桌面/硬件的验证（权限弹窗、摄像头、多显示器、设备热插拔、真实录制/滚动拼接）一律不在此执行，改由包体附件 + 用户手测清单（见 `QA-MANUAL-TEST-CHECKLIST-template.md`）交付用户。

## 前置要求

- macOS 开发机（Apple Silicon 或 Intel）、Xcode Command Line Tools（`swift`、`codesign` 可用）。
- 检出最新代码并 `swift package clean`，确保无增量缓存干扰。

## 1. 单元 / 逻辑测试

```bash
swift test
```

期望结果：全部测试通过（当前基线 10 个用例，0 failures）。失败即阻断交付。

当前覆盖：设置默认值 round-trip、快捷键冲突回滚、恢复默认不动权限/素材、磁盘/长截图阈值、标注样式持久化、裁剪边界、点击坐标映射、录屏输出尺寸、覆盖层状态、截图状态机。

BRA-54 起新增：工具样式拖拽范围/离散档位/默认值（`testToolStyleRangesMatchFRCAP16`，覆盖 FR-CAP-16）。固定工具区（FR-CAP-14）与工具选项浮层（FR-CAP-15）的可视/交互行为属桌面验证，不在本清单自动执行，归用户手测清单覆盖。

## 2. Release 构建（产出包体）

```bash
make app
```

期望结果：生成签名后的 `ShotX.app`（`ShotX.app/Contents/MacOS/ShotX` + `Support/Info.plist`），无编译错误。

## 3. 签名校验

```bash
codesign --verify --deep --strict --verbose=2 ShotX.app
```

期望结果：输出 `ShotX.app: valid on disk` 与 `satisfies its Designated Requirement`。

## 4. 静默冒烟启动

```bash
open ShotX.app
sleep 2
pgrep -x ShotX && echo OK
# 退出：
osascript -e 'tell application "ShotX" to quit'   # 或 pkill -x ShotX
```

期望结果：进程在启动 2 秒后仍存活且可正常退出。仅验证可启动、不崩溃，不做任何桌面操作。

## 5. 静态检查

```bash
# 确认无网络调用（本地优先承诺）
rg -n -i "urlsession|urlrequest|nwconnection|http://|https://" Sources || echo "no network code"
# 确认无未提交/未跟踪文件（若使用 git）
git status --porcelain
```

期望结果：无网络相关源码；工作区干净（或已说明的变更集合）。

## 6. 包体打包（供附件交付）

```bash
ditto -c -k --sequesterRsrc --keepParent ShotX.app ShotX.app.zip
ditto -c -k --keepParent Sources ShotX-source.zip   # 视交付要求
```

期望结果：生成 `ShotX.app.zip`、`ShotX-source.zip` 作为 issue 附件交付，并附手测清单。

## 结果记录模板

| 步骤 | 命令 | 结果（通过/失败） | 证据（关键输出） |
| --- | --- | --- | --- |
| 1 单元测试 | `swift test` | | |
| 2 构建 | `make app` | | |
| 3 签名 | `codesign --verify --deep --strict --verbose=2 ShotX.app` | | |
| 4 冒烟启动 | `open` + `pgrep` | | |
| 5 静态检查 | `rg` 网络检索 | | |
| 6 打包 | `ditto ...` | | |

任一步失败 → 阻断交付，修复后从第 1 步重跑。全部通过 → 包体 + 手测清单交付用户；QA 在验收矩阵（`QA-ACCEPTANCE-MATRIX.md`）中以「团队后台自动验证」标记对应条目为已后台验证，桌面/硬件条目保持「待用户手动验证」。
