# 回归问题与排查入口

## 生成结果与手动构图不一致

检查 `compositionAnchor` 是否保留，以及 `CropPlan` 是否同时应用于静态示意、动态预览与编码。不要仅在视图上改变缩放。优先执行 `CompositionTests` 中预分析构图、完整轨迹与参考帧一致性用例；真实桌面验证见 `DesktopCompositionParityTests`。

## 更改打码后进入构图报错

已完成跟踪不代表新打码计划有效。检查 `AppModel.refreshComposition` 是否在 `redactionPlan.covers` 不成立时保留静态预览、清除旧动态播放器，确认时复用主角分析并重新生成遮挡轨迹。

回归：`RedactionStateTests.testChangingMasksAfterAnalysisKeepsCompositionUsableAndRebuildsMasksOnConfirm`。

## 身份阻塞期间还能播放或拖走问题帧

检查 `togglePreview`、普通 `scrub` 和各端时间轴可用性。需要保留明确的纠正帧检查，不要简单禁止所有 seek。

回归：`AsyncStateTests.testBlockedRecoveryDoesNotPlayOrScrubPastConfirmationFrame` 和 `EditorFlowTests.testSingleScreenDemoAndBlockingRecovery`。

## 取消或返回后页面被旧任务改变

检查 Task 取消之外的 operationID／projectID 校验。特别注意 preview 创建、导入、检测、恢复、导出完成和错误回调。删除项目还需等待已开始的持久化，避免项目重现。

回归集中在 `AsyncStateTests`；取消导出和保留分析结果另见 `OptimizationRoundThreeTests`。

## 视频已暂停但按钮还显示暂停

检查 `ExportView` 中本地 playing 状态、scenePhase 以及当前 AVPlayerItem 的播放结束通知。过滤旧播放项通知，主线程同步按钮。

回归：`EditorFlowTests.testOutputPlaybackResetsAfterBackgrounding`。该测试覆盖后台恢复；不能据此声称单独验证了真实片尾通知。

## Duo 折叠后空白或设置挤压视频

检查 `WorkspaceArrangement` 的分区理想尺寸，避免给内容设置无法满足的硬最小尺寸。回退路径使用 `AnyLayout` 保持状态，依据可用窗口大小选择列布局。Mac 还应验证最小窗口尺寸。

回归：`EditorFlowTests.testAdaptiveWorkspaceKeepsSelectionAndCompositionAcrossRotation`。截图索引见 [Duo评审](../validation/duo-redesign/review.html)。

## 项目重开耗时或成片无法复用

检查 `ProjectStore.trajectory` 的版本、源摘要、目标锚点与覆盖校验；再检查 output 清单与当前设置是否匹配。完整轨迹与成片支持持久化复用，处理中会话则不是完整的跨重启任务恢复机制。不能为提速绕过源校验或复用旧配置的成片。

## 真实视频很晕或处理太慢

区分取帧、推理、打码、编码与 UI 等待。对同一输入和配置比较；先确认目标身份、构图与平滑轨迹，再评估采样或缓存。历史比较数据位于 `docs/validation/speed-smooth`、`steady`、`optimization-rounds`，这些是特定样片观察，不是全场景指标。

## 尚未解决的能力边界

整人矩形遮挡的复杂交叠、移动机位、真机长时热稳定、HDR／VFR及长视频压力仍需专项处理。过去测试通过不代表这些能力已经完成。
