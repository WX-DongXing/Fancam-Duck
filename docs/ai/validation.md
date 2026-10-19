# 开发验证指南

## 工具链

部署基线 iOS18。历史验证使用 Xcode27.1；2026-10-19 当前本机工具链为 Xcode27.0（27A266a）。Duo 原生分区布局需要含相应 API 的 SDK 及显式编译标志，默认使用自适应布局。使用 `xcodebuild -showdestinations -project 'Fancam Duck.xcodeproj' -scheme 'Fancam Duck'` 查看本机目标，不在文档固化模拟器 UUID。

Xcode 27.0 的 SwiftUI SDK 不含 `ArrangementView`，仅用 `#available(iOS 27.1, *)` 仍会编译失败。工程默认采用既有 `AnyLayout` 自适应布局，支持手机、宽屏与 Mac；只有确认所用 SDK 包含 ArrangementView 及相关修饰符时，才在 Swift Active Compilation Conditions 中追加 `FANCAM_DUCK_NATIVE_ARRANGEMENT` 启用原生分区分支。不要在旧 SDK 下设置该标志。

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

清理后重建（2026-10-19）：按用户要求移除本项目 `build` 和此前 fancamduck 临时构建目录，随后使用 `release-macos.sh --signed-only` 从零归档并导出 `0.1.0 (1)` Developer ID 包。arm64／x86_64、Developer ID 与 Hardened Runtime、严格签名、AppIcon／模型资源、ZIP 完整性及 SHA-256 校验通过。本轮不提交公证，产物状态为 `developer-id-signed (not notarized)`。

## 原生构图比例切换

2026-10-20，Xcode 27.1、iPhone 17 Pro／iOS 26.3.1：比例切换改用原生 segmented Picker，移除覆盖整个状态变更的显式动画及构图忙碌导致的面板禁用样式。新比例可取消并覆盖旧预览任务，保留 compositionID、项目 ID 和取消检查。构图／异步套件执行 28 项，12 项通过、16 项因未配置本地视频跳过，0 失败；新增快速连续切换回归通过。新增 UI 用例验证完成演示分析后原生分段控件可点击及按住横拖、选中项正确、其他构图按钮保持 enabled、手机无 ScrollView，1 项通过。此为模拟交互验证，不代表真实视频性能测量。

原生分段控件增高与统一（2026-10-20）：比例、工具、打码范围、打码样式采用同一 `NativeSegmentedControl`（系统 UISegmentedControl），真实控件高度 48pt，更新选中项时不重建所有分段。iPhone 17 Pro／iOS 26.3.1 的 UI 回归验证原生控件类型、实际高度、工具互切、范围／样式点击与横拖、构图选择保留及页面不滚动，1 项通过；构图套件 12 项中 10 项通过、2 项因缺少私人视频跳过。此轮不含真实视频性能测量。

图标与打码间距复核（2026-10-20）：原生工具分段恢复 SF Symbols 图标加文字，图像按视图 displayScale 绘制且保留分段辅助功能名称；打码行间距至少 8pt，底部操作等宽、间隔 12pt，手机面板预留 184pt。更新后的 iPhone UI 用例重新编译并通过，核对工具可访问名称、切换、拖动及两组打码控件实际间距，模拟人物截图确认图标显示正常。

底部控件对齐（2026-10-20）：构图／打码分段与生成视频按钮共用 56pt 高度，iPhone UI 回归新增实际 frame 高度和 midY 对齐断言，1 项通过。

Mac 控件统一（2026-10-20）：Mac Inspector 直接复用手机的 `processingAction`、原生工具／比例／打码分段，以及面板内边距和组间距，移除独立的桌面主按钮实现。Mac Catalyst Debug 构建通过并已打开模拟人物演示。新增 `MacNativeControlsTests` 专项用例，运行时临时排除既有 iPhone 手势 UI 文件；测试与 App 编译通过，但运行器在连接测试服务前被系统终止（bootstrapping 失败、signal kill），无用例实际执行。窗口控制也发生 ScreenCaptureKit 错误和超时，因此不能声称 Mac 窗口交互或高度实测已通过；手机同源控件的既有 UI 通过结果仍只代表 iPhone。

## 按改动选择测试

真实编辑链路专项：显式设置 `TEST_RUNNER_FANCAM_DUCK_REAL_EDITOR_VALIDATION=1` 和 `TEST_RUNNER_FANCAM_DUCK_TEST_VIDEO=<本地人物视频>`，执行 `RealEditorInteractionTests`。该用例使用生产 CoreMLTrackingPipeline、AppModel、ProjectStore、VideoExporter，以真实检测选出的主角完成全时长分析与导出，再修改打码并重新生成；没有使用替身检测或模拟人物。它覆盖真实媒体驱动的状态与设置操作，不等同于窗口点击、布局或性能验收。Mac 仅运行单元测试时，可用临时移除 UI Testable 的 Scheme 避开现有 UI 测试的 pinch 编译限制，验证后移除临时 Scheme。

2026-10-19：桌面本地真实视频（1280×720、42.733 秒）完整时长验证通过，1 项通过、0 跳过、0 失败。检测待完成时进入构图／打码／手动框选、构图与打码取消回滚、候选检测恢复、真实 MP4 生成及修改为人脸马赛克后重新生成均通过。为控制验证产物体积，输出设为 180×320；未据此推断默认输出分辨率性能。最终窗口点击仍因界面控制工具无法访问新应用标识而未验证。

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

## 本轮工作台验证

[2026-10-19 分析复用工作台记录](../validation/2026-10-19-workflow-reuse.md)：25 项测试通过、0 跳过、0 失败；包含桌面原片全时长的生产模型分析、重开项目和两次生成，恢复后新增 pose 调用为 0。Mac 原生窗口另行验证桌面导入、设置、生成与单击播放。iPhone 仅构建通过；最终窗口复核遇到系统锁屏，见记录中的限制。

## 最近验证基线

2026-10-20 打码开关位置动画：清理构建后 iPhone 17 Pro／iOS 26.3.1 构建与 1 项 UI 回归通过，0 失败；关闭时开关靠右，开启后右边缘左移 100pt，为 88pt 菜单和 12pt 间距让位，关闭后回到原位置。菜单交互、面板 184pt 上限及生成保留构图回归均通过。此条替代前述开关固定位置的界面规范。

2026-10-20 重新生成进度：iPhone 模拟器构建和 WorkflowStateTests 1 项通过，0 失败。注入 exporter 先报告 0%、10% 并挂起，断言新生成初始为 0%、复用分析时编码 10% 对应总进度约 9.9%（不再跳至 75%），随后验证取消和晚到完成不替换既有成片。未据此测量真实编码耗时。

2026-10-20 生成沿用当前构图：iPhone 17 Pro／iOS 26.3.1 构建通过，WorkflowStateTests 1 项、EditorFlowTests 定向 UI 回归 1 项通过，0 失败。验证生成输入设置与提交前一致、保留 compositionCrop、生成阶段展示构图预览、取消后保留设置，并复核模拟素材生成中截图。导出设置断言使用注入的 exporter 替身，本轮不代表真实 MP4 像素与性能验证。

2026-10-20 范围菜单过渡与人脸贴片放大：iPhone 17 Pro／iOS 26.3.1 构建通过；1 项 UI 回归通过，验证开关前后开关 frame 不变、关闭时范围不可点击、面板不超过 184pt；1 项贴片渲染回归通过，确认透明贴片无底板、填满遮挡区域且不越过原覆盖边界。人脸内容填充比例从 1.12 改为 1.32，预览和导出共用渲染器；本轮未测真实视频观感与性能。

2026-10-20 打码说明气泡：iPhone 17 Pro／iOS 26.3.1 构建及 1 项 UI 回归通过，0 失败；验证紧邻文字的问号、原生 popover（紧凑屏幕不转为 sheet）、无 alert、点击空白收起，面板与主操作按钮保持原位置，已复核截图。

2026-10-20 打码提示与贴片迭代：iPhone 17 Pro／iOS 26.3.1 构建通过，1 项 UI 测试通过；RedactionStateTests 共 5 项，其中 3 项通过、2 项因未配置私人视频跳过、0 失败。验证问号说明、关闭时隐藏范围、四种透明贴片选择、全身移除贴片并回退毛玻璃、PNG 项目持久化；已检查最终截图，面板仍不超过 184pt。未测真实视频效果或性能。

2026-10-20 iPhone 打码面板调整（基于 `b9c8529` 的工作区改动）：iPhone 17 Pro／iOS 26.3.1 模拟器构建及 `EditorFlowTests/testNativeAspectSegmentsSupportDraggingWithoutDisablingPanel` 通过，1 项、0 失败。使用绘制人物演示素材，验证自动打码开关、范围菜单、三种样式点选与滑动、强度滑块、图片 Logo 提示；面板不超过 184pt，样式控件及生成按钮位置稳定，编辑页无滚动。已复核测试截图；本轮不代表真实视频打码质量或性能验证。

[2026-10-19 CR 记录](../validation/code-review/2026-10-19.json)：完整单元／集成97项，其中6项跳过，0失败；最终异步回归13项、iPhone和Duo各2项UI通过，Mac构建通过。它是该轮记录，新增代码后需要按变更重新验证。

保存新结果时记录代码版本、测试范围、设备／系统、输入规格、跳过项和限制；性能比较注明是否含 UI 等待及人工纠正。不要提交私人视频和构建产物。

## 本地测试视频

仓库不分发视频夹具。需要人物视频的集成测试使用 `FANCAM_DUCK_TEST_VIDEO` 指向本地文件，未配置或文件缺失时跳过。xcodebuild 使用 `TEST_RUNNER_FANCAM_DUCK_TEST_VIDEO` 传入。该文件不应提交；模型识别断言对视频内容有要求，并非所有视频都适用。
