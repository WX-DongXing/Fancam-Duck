# 回归问题与排查入口

## 编译提示找不到 ArrangementView

`#available` 只控制运行时分支，旧 SDK 仍会检查分支中的类型。Xcode27.0 的 SwiftUI 不含 ArrangementView，默认使用已有 AnyLayout；含该 API 的 SDK 才可通过 `FANCAM_DUCK_NATIVE_ARRANGEMENT` 启用原生分区。2026-10-19 使用 Xcode27.0 验证 iOS 模拟器及 iOS 设备目标未签名构建均通过；不代表描述文件配置或真机安装已完成。签名报错需单独核对当前 Bundle ID 与开发团队。

## 生成结果与手动构图不一致

检查 `compositionAnchor` 是否保留，以及 `CropPlan` 是否同时应用于静态示意、动态预览与编码。不要仅在视图上改变缩放。优先执行 `CompositionTests` 中预分析构图、完整轨迹与参考帧一致性用例；真实桌面验证见 `DesktopCompositionParityTests`。

## 更改打码后进入构图报错

已完成跟踪不代表新打码计划有效。检查 `AppModel.refreshComposition` 是否在 `redactionPlan.covers` 不成立时保留静态预览、清除旧动态播放器，确认时复用主角分析并重新生成遮挡轨迹。

回归：`RedactionStateTests.testChangingMasksAfterAnalysisKeepsCompositionUsableAndRebuildsMasksOnConfirm`。

## 修改打码后重新生成提示轨迹不完整

自动打码的旁观者跟踪器会短时保留漏检预测。人物离开画面后，预测框与画面求交可能为空；不能把这类已出画预测当成实际检测框损坏，进而拒绝整段视频。`AutomaticRedaction.build` 在预测分支跳过完全出画的框，保留已有可见轨迹分段；实际检测框、主角排除与计划覆盖校验保持不变。

2026-10-19 在本地真实 42.7 秒视频上复现：32.1 秒处，missed=5 的旁观者预测框已完全出画，裁切后坐标为无穷、尺寸为零，触发 incomplete。新增 `RedactionTests.testAutomaticMasksAllowBystanderPredictionToLeaveFrame`，修复前失败；修复后 Mac Catalyst 的 RedactionTests／RedactionStateTests 共 14 项通过、3 项按条件跳过、0 失败。为避开既有 UI 测试的 Mac pinch 编译问题，使用临时仅单元测试 Scheme，验证后移除。

真实 Mac 窗口验证：同一报错项目完成整人毛玻璃分析并导出，再返回调整为人脸马赛克，点击“重新生成”成功回到“视频已生成”；实际播放画面前进且可暂停。验证使用桌面真实素材，成片为 404×718、42.7 秒；私人视频和画面未加入仓库。本轮不代表逐帧遮挡质量、iPhone／Duo 或性能验收。

## 身份阻塞期间还能播放或拖走问题帧

检查 `togglePreview`、普通 `scrub` 和各端时间轴可用性。需要保留明确的纠正帧检查，不要简单禁止所有 seek。

回归：`AsyncStateTests.testBlockedRecoveryDoesNotPlayOrScrubPastConfirmationFrame` 和 `EditorFlowTests.testSingleScreenDemoAndBlockingRecovery`。

## 取消或返回后页面被旧任务改变

检查 Task 取消之外的 operationID／projectID 校验。特别注意 preview 创建、导入、检测、恢复、导出完成和错误回调。删除项目还需等待已开始的持久化，避免项目重现。

回归集中在 `AsyncStateTests`；取消导出和保留分析结果另见 `OptimizationRoundThreeTests`。

## 编辑设置灰掉或点击无反馈

候选检测仅影响新人物选择与开始处理，不应禁用已选主角的构图／打码入口。进入构图、手动框选时取消过时检测；检测结果因当前帧变化而丢弃时，也必须清理同 detectionID 的 detecting，防止主按钮一直灰掉。Mac 构图不能在整个面板上统一 disabled，否则计算期间连取消也不可用。

项目恢复、构图预览及图片准备期间，主按钮显示具体等待原因，Mac 设置区另显示活动提示；播放期间提示先暂停，缺少新打码计划时说明生成后可播放。图片准备期间暂禁用确认，取消仍可用。处理、导出、身份阻塞以及直接拖动手势期间的必要限制保留。

2026-10-19：旧帧检测退出与检测中进入构图两项回归修复前失败；新增手动框选晚到检测回归。使用本地真实视频作为媒体输入，Mac Catalyst AsyncStateTests／RedactionStateTests／CompositionTests 共 31 项通过、0 跳过、0 失败；Mac 构建通过。临时单元测试 Scheme 已移除。本轮新应用标识未获界面控制工具访问许可，最终窗口交互未实测；未验证手机／Duo 布局及性能收益。

## 视频已暂停但按钮还显示暂停

检查 `ExportView` 中本地 playing 状态、scenePhase 以及当前 AVPlayerItem 的播放结束通知。过滤旧播放项通知，主线程同步按钮。

回归：`EditorFlowTests.testOutputPlaybackResetsAfterBackgrounding`。该测试覆盖后台恢复；不能据此声称单独验证了真实片尾通知。

## 成片播放需要点击多次

先区分图标是否切换：`ExportView` 在调用播放器前切换本地 playing 状态；图标未变化时优先检查按钮命中和窗口状态，不能直接归因为解码卡顿。`StudioIcon` 的 44×44 标签内部声明圆形 contentShape，确保图标周围的空白也参与点击。

2026-10-19：Mac Catalyst 临时 Debug 构建通过，使用本地真实舞蹈视频（1280×720、42.7 秒）新建项目，完成分析与 MP4 导出（404×718）。成片页验证左侧边缘播放、右侧边缘暂停、右侧恢复、中心暂停四次单击均响应；观察到播放画面变化、暂停后画面保持。原偶发问题未稳定复现，本轮不能证明其唯一根因。私人视频及截图未加入仓库。

`EditorFlowTests.testOutputPlaybackResetsAfterBackgrounding` 已补充左右边缘单击检查；本轮模拟器测试构建因当前 SDK 找不到既有 `ArrangementView` 而失败，测试未执行。桌面手动验证不替代模拟器后台回归或播放性能测量。

## Duo 折叠后空白或设置挤压视频

检查 `WorkspaceArrangement` 的分区理想尺寸，避免给内容设置无法满足的硬最小尺寸。回退路径使用 `AnyLayout` 保持状态，依据可用窗口大小选择列布局。Mac 还应验证最小窗口尺寸。

回归：`EditorFlowTests.testAdaptiveWorkspaceKeepsSelectionAndCompositionAcrossRotation`。截图索引见 [Duo评审](../validation/duo-redesign/review.html)。

## 项目重开耗时或成片无法复用

检查 `ProjectStore.trajectory` 的版本、源摘要、目标锚点与覆盖校验；再检查 output 清单与当前设置是否匹配。完整轨迹与成片支持持久化复用，处理中会话则不是完整的跨重启任务恢复机制。不能为提速绕过源校验或复用旧配置的成片。

## 真实视频很晕或处理太慢

区分取帧、推理、打码、编码与 UI 等待。对同一输入和配置比较；先确认目标身份、构图与平滑轨迹，再评估采样或缓存。历史比较数据位于 `docs/validation/speed-smooth`、`steady`、`optimization-rounds`，这些是特定样片观察，不是全场景指标。

## 尚未解决的能力边界

整人矩形遮挡的复杂交叠、移动机位、真机长时热稳定、HDR／VFR及长视频压力仍需专项处理。过去测试通过不代表这些能力已经完成。
