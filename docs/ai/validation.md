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

## 应用图标与多平台构建

A1 图标覆盖 iPhone、iPad／Duo 和 Mac Catalyst；素材及重建步骤见 [Logo 资源说明](../design-assets/logo-a1/README.md)。运行 `tools/validation/build-platforms.sh` 顺序验证 iOS 设备、iOS 模拟器和 Mac Catalyst 的未签名 Release 构建。日志与 DerivedData 默认保存在 `/tmp/fancamduck-platform-builds`，可通过 `FANCAM_DUCK_BUILD_ROOT` 指定目录。

2026-10-19 本轮验证：Xcode 27.1（27A9275），工作区包含本次未提交图标变更；iOS 设备、iOS 模拟器、Mac Catalyst 三个平台 Release 构建全部通过（`CODE_SIGNING_ALLOWED=NO`）。11 个图标槽位尺寸检查通过，iOS 1024 PNG 无 alpha；iOS 产物包含 iPhone／iPad 主图标元数据，Mac 产物包含有效 `AppIcon.icns` 及引用。`git diff --check` 通过。构建仍有既有 `RedactionCompositor` sendability 与 AppIntents 元数据提示，无图标编译错误。

脚本验证资源编译和应用构建，不代表签名、商店上传、启动器显示或实际设备 UI 验收。页面 Logo 替换后再次通过上述三平台 Release 构建；已覆盖安装并启动 iPhone 17 Pro（iOS 26.3.1）与 Duo（iOS 27.1），实际检查手机和宽屏首页 Logo 显示正常。Mac 页面仅完成构建验证。未运行单元或真实视频性能测试。

## macOS 发布脚本

入口和签名／公证参数见 [macOS 发布指南](macos-release.md)。2026-10-19 在 `058e324` 基础的工作区中使用 Xcode 27.1 验证 `tools/release/build-macos.sh --local`：Release 通用架构构建、ad-hoc 签名、严格签名校验、AppIcon 与两个模型资源检查、ZIP 完整性及 SHA-256 校验均通过。帮助信息及未知参数、缺失公证 profile、local 模式请求公证、缺失团队 ID 的拒绝路径通过。Developer ID 归档／导出与 Apple 公证未实际运行，不能据此认定正式发布链路已通过。

`.env.release` 一键入口追加验证（2026-10-19）：`release-macos.sh --local` 实际读取本地配置并完成双架构构建、ad-hoc 签名与 ZIP 打包，ZIP 完整性和 SHA-256 校验通过。隔离配置测试覆盖默认公证参数传递、带空格 profile、local／signed-only 覆盖、非法模式／布尔值／版本／构建号拒绝；缺失团队 ID 在构建前失败。实际配置已被 Git 忽略且权限为 600。正式 Developer ID 签名及公证仍未实测。

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
