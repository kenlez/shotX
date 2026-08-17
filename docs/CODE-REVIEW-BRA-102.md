# ShotX 代码审查报告（BRA-102 发布门禁）

- 审查对象：BRA-102 发布前改动（commit `1971bea`，含 `Sources/ShotX/AppModel.swift`、`RecordingCoordinator.swift`、`SettingsView.swift`、新增 `PermissionFlowTests`/`QACameraOverlayTests` 与 SettingsTests 摄像头用例）
- 审查依据：`docs/shotx-prd-BRA102.md`（BRA102-01…07）、`docs/shotx-ux-ui-spec-BRA102.md`（UX 标注）、仓库规范 `docs/RELEASE-AND-TEST-POLICY.md`、QA 报告 `docs/QA-ACCEPTANCE-REPORT-BRA-102.md`
- 审查日期：2026-08-16
- 结论：**通过**（发布门禁放行；残余风险均为依赖真实摄像头/系统弹窗的用户手测项）

## 1. 规范符合性

| 项 | 检查 | 结果 |
| --- | --- | --- |
| 无第三方依赖 / 无网络代码 | `rg -i "urlsession\|urlrequest\|nwconnection" Sources/ShotX` | ✅ 无匹配 |
| 仅用现有系统 API | AVCaptureSession / ScreenCaptureKit / AppKit | ✅ |
| 测试覆盖新增行为 | PermissionFlowTests 4 例 + QACameraOverlayTests 5 例 + SettingsTests 摄像头 5 例 | ✅ |
| 权限用途声明 | `NSCameraUsageDescription` / `NSMicrophoneUsageDescription` 已随包 | ✅ |
| 无 .screenSaver 级蒙层时发起权限申请 | `requestScreenPermission` 先 `CaptureCoordinator.cancel()` 再申请 | ✅ |
| 不造假实现 | 模糊背景以 `isPortraitEffectActive` 真实生效为准，美颜无系统 API 则隐藏 | ✅ |

## 2. 需求对齐（PRD/UX）

| PRD ID | 实现证据 | 结果 |
| --- | --- | --- |
| BRA102-01 首次启动权限置顶 | `AppModel.start` → `requestScreenPermissionOnFirstLaunch`；捕获命令未授权先拦截不建蒙层；`requestScreenPermission` 先 cancel 蒙层 | ✅ |
| BRA102-02 首次录屏默认禁用 | `AppSettings.defaults` microphone/cameraEnabled 均 false；首次仅申请屏幕权限 | ✅ |
| BRA102-03 开启即启动摄像头 | `setCamera(true)` → `.allowed` 直接启动 / `.notDetermined` 授权回调后启动 | ✅ |
| BRA102-04 左下角圆角正方形+margin | `CameraOverlayLayout.rect` 锚定左下 12pt、正方形、圆角 12pt、夹紧不超选区 | ✅ |
| BRA102-05 两档尺寸 | `CameraOverlaySize` 96/192pt，夹紧规则（min(w,h)−2×margin，<64pt 隐藏+提示） | ✅ |
| BRA102-06 设置开关 | 模糊背景仅系统支持时显示；美颜隐藏；镜像默认开 | ✅ |
| BRA102-07 预览与成片一致 | 预览（scale=1 点）与成片（scale=backingScaleFactor 像素）共用同一布局函数 | ✅ |

## 3. 观察项（非阻断，交用户手测）

- **D1**：O-RSET 面板内开启摄像头触发系统弹窗时面板为 `screenSaver+1` 级，弹窗可点性依赖真实 TCC 行为，需用户按 TC-CAM-01 实测（QA 报告 D1）。
- **D2**：模糊背景开关不主动开启系统「人像效果」，属诚实呈现，需 TC-CAM-05 实测接受度。
- **D3**：画中画方向/旋转口径（预览 vs 成片）需真实录制逐像素对比（TC-CAM-09）。

以上与 `docs/QA-ACCEPTANCE-REPORT-BRA-102.md` 的 D1/D2/D3 一致，均为「后台不可验证、需用户实测」项，不阻断本发布。
