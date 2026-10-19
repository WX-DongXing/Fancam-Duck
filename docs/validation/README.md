# 历史验证记录

这里保留各轮测试结果、复现上下文、媒体输出元数据及性能比较。记录只代表当轮代码、设备和素材，不表示当前版本已重新通过；当前验证方法见 [验证指南](../ai/validation.md)。

## 主要入口

| 范围 | 记录 |
| --- | --- |
| 最近综合回归 | [2026-10-19 代码评审验证](code-review/2026-10-19.json) |
| 跟踪、构图与性能比较 | `composition`、`composition-anchor`、`speed-smooth`、`steady`、`optimization-rounds` |
| 遮挡与打码 | [自动恢复](occlusion/automatic-recovery.json)、[打码评审](redaction/review.html)、`redaction` 中的计划与指标 |
| 多端布局 | [自适应布局](adaptive-workspace/review.html)、[Duo](duo-redesign/review.html)、[Mac](desktop-redesign/review.html) |
| 编辑流程与界面回归 | 各轮目录中的 README、`*-summary.json`、`validation.json` 及专项记录 |

## 素材清理规则

2026-10-19 清理了未被引用的早期布局截图（原位编辑、内联进度、构图比例、操作区重排、时间轴等迭代），以及 `docs/design` 中未被引用的旧三方案比较页和选人框示意图。保留所有验证 JSON、日志、轨迹、构图参数和性能前后对比，不因记录较早而删除。

仍被文档引用的截图，以及较新界面的手动框选、大字号、暂停恢复等专项截图保留。展示素材已替换为模拟人物图片，不能作为历史真实视频逐帧证据，详见 [素材说明](../design-assets/README.md)。历史记录中的本地视频、xcresult 和临时路径可能不随仓库分发。
