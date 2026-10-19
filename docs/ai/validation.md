# 开发验证指南

## 工具链

部署基线 iOS18，当前验证使用 Xcode27.1。Duo 的原生分区布局在 iOS27.1 SDK 路径下启用。使用 `xcodebuild -showdestinations -project 'Fancam Duck.xcodeproj' -scheme 'Fancam Duck'` 查看本机目标，不在文档固化模拟器 UUID。

```sh
# 单元与媒体集成
xcodebuild -project 'Fancam Duck.xcodeproj' -scheme 'Fancam Duck' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/fancamduck-build CODE_SIGNING_ALLOWED=NO \
  test -only-testing:FancamDuckTests

# 界面回归：使用同样参数，将最后一行替换为
# test -only-testing:FancamDuckUITests

# Mac Catalyst 构建
xcodebuild -project 'Fancam Duck.xcodeproj' -scheme 'Fancam Duck' \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /tmp/fancamduck-mac-build CODE_SIGNING_ALLOWED=NO build
```

## 按改动选择测试

| 修改范围 | 优先套件 |
| --- | --- |
| 状态、取消、后台 | `AsyncStateTests`、`OptimizationRoundThreeTests` |
| 坐标、范围、输出尺寸 | `DomainTests`、`MediaIntegrationTests`、`ExportValidationTests` |
| 构图手势、画幅、预览导出一致性 | `CompositionTests`、`CameraPlanTests`、`EditorFlowTests` |
| 检测、ReID、帧读取、遮挡恢复 | `RealTrackingTests`、`InferenceEfficiencyTests`、`AnalysisFrameReaderTests`、`OcclusionBridgeTests` |
| 打码 | `RedactionTests`、`RedactionStateTests`，必要时真实媒体验证 |
| 项目、输出缓存、删除 | `ProjectStoreTests`、`OptimizationRoundThreeTests`、`AsyncStateTests`、`HistoryDeletionTests` |
| Duo 和桌面布局 | `EditorFlowTests` 的旋转／自适应用例，以及 Mac 构建与实际窗口检查 |

指定单个测试可使用 `-only-testing:FancamDuckTests/AsyncStateTests/testBlockedRecoveryDoesNotPlayOrScrubPastConfirmationFrame`。UI 测试使用 `FancamDuckUITests` 前缀。

私人素材用例会检查 `FANCAM_DUCK_DESKTOP_VALIDATION`、`FANCAM_DUCK_OCCLUSION_VALIDATION`、`FANCAM_DUCK_REVERSE_VALIDATION` 等环境变量。通过 xcodebuild 传入测试 runner 时使用 `TEST_RUNNER_` 前缀，具体素材准备和项目 ID 以测试文件为准。仅设置开关不代表素材已准备好。

## 验证分层

1. 单元测试检查确定性数据与状态；必要时先复现旧实现失败。
2. 媒体集成检查真实解码、合成、尺寸、轨迹、音视频时间。
3. 模拟器检查点选、手势、暂停恢复、后台、多端尺寸和页面不滚动。
4. 完整真实视频比较分析／编码速度、身份连续性、遮挡稳定与运镜观感。

不要将演示流程测试当成真实模型跟踪测试，也不要把构建成功当成多端布局验收。修改文档可检查链接与 diff，无需重跑媒体套件。

## 最近验证基线

[2026-10-19 CR 记录](../validation/code-review/2026-10-19.json)：完整单元／集成97项，其中6项跳过，0失败；最终异步回归13项、iPhone和Duo各2项UI通过，Mac构建通过。它是该轮记录，新增代码后需要按变更重新验证。

保存新结果时记录代码版本、测试范围、设备／系统、输入规格、跳过项和限制；性能比较注明是否含 UI 等待及人工纠正。不要提交私人视频和构建产物。

## 本地测试视频

仓库不分发视频夹具。需要人物视频的集成测试使用 `FANCAM_DUCK_TEST_VIDEO` 指向本地文件，未配置或文件缺失时跳过。xcodebuild 使用 `TEST_RUNNER_FANCAM_DUCK_TEST_VIDEO` 传入。该文件不应提交；模型识别断言对视频内容有要求，并非所有视频都适用。
