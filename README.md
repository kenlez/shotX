# ShotX

原生 macOS 14+ 菜单栏截屏 + MP4 录屏应用，Swift + AppKit + SwiftUI + ScreenCaptureKit + AVFoundation + Carbon 实现。无网络、无账号、无上传、无远程配置、无第三方依赖。

当前版本：**V0.1（0.1.0）**

```bash
swift test        # 单元/功能测试
make app          # release 构建 + 签名，生成 ShotX.app
open ShotX.app    # 运行
```

## 目录结构

- `Sources/` — 应用源码
- `Tests/` — 单元/功能测试
- `Support/` — 打包支撑文件（Info.plist）
- `icon/` — APP 图标源（`shotx.png`，打包时自动生成 icns）
- `docs/` — 全部文档（PRD、UX 规范、实现追踪、QA、打包与测试规范、发布说明）
- `releases/` — 打包产物（带版本号，如 `ShotX-0.1.0.app.zip`）
- `attachments/` — 原始附件备份

## 打包与测试规范

**正式规范见 `docs/RELEASE-AND-TEST-POLICY.md`**，要点：

- 每次打包更新版本号（`make package VERSION=x.y.z`），压缩包名必须含版本号（`releases/ShotX-<VERSION>.app.zip`）。
- 不随问题修复即打包；等正式打包要求才出包。
- Bug 一个一个改，review 通过后合并，合并后不打包。
- `icon/shotx.png` 是 APP 图标唯一权威来源。

## 功能现状

菜单栏截屏入口、可编辑全局快捷键、四类权限校验、单屏区域/窗口/全屏截屏、物理像素输出、标注（可移动/删除、裁剪、撤销/重做、马赛克、颜色选择器）、PNG 复制/保存/分享/置顶、长截图滚动拼接、本地 MP4 录制（倒计时/状态/停止、磁盘保护、Recovery 保留）、播放、头尾裁剪导出、复制/保存/Finder。

硬件验证缺口：摄像头叠加、点击光圈、长图拼接夹具、设备热拔插、低磁盘停止、30 分钟 A/V 同步，发布前仍需真机/夹具验证。
