## 目标

依据 `attachments/image.png`、`attachments/IMG_8368大.jpeg`、`attachments/f0efc2ac-d0ca-40e9-a045-2cc106229cd1.jpeg` 及现有 `Sources/ShotX/Assets/Figma`，完成 BRA-82 的实现标注。不得修改 Swift。

## 交付

将结果写入 `docs/shotx-ux-ui-spec-BRA82.md`，并在工单评论中覆盖：

- 截图工具栏最终顺序、矩形/椭圆/长截图的准确语义、移除的移动工具；逐项 SVG 映射、需要重新导出的资产、分割线尺寸/颜色/间距。
- 各工具 `drop_over_normal` 样式；文字工具与其余工具的差异（颜色、字号、控件/状态）。
- 录屏设置态和录制中控制条的逐元素 SVG 清单、尺寸、状态和不入成片规则。
- 截图编辑和贴图拖动的命中/坐标约束；滚动自动捕获的 UX 状态（采集中、暂停、撤销、完成、上限）。
- 每项至少一个 Given/When/Then 验收条件，以及与 `docs/shotx-prd-BRA82.md` 的冲突或未决项。

## 约束

只按已确认的用户请求和设计图输出；看不清或缺少的视觉数值须明确标为待确认，不能臆造。复用现有 SVG 时核验实际内容和文件名是否一致。
