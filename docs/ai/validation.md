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

[2026-10-20 CR 与修复记录](../validation/code-review/2026-10-20.md)：FancamDuckTests 126 项（77 通过、49 跳过、0 失败），关键 UI 3 项通过，Mac Catalyst 构建通过。修复其他人物归属排除、临界候选竞争、重试 ID 冲突、末帧重试窗口和无效框选关闭；未做真实视频回补成功率与性能测量。

2026-10-20 缺失目标延后回补：iPhone 模拟器构建通过，DeferredTargetRecoveryTests 7 项、OcclusionBridgeTests 3 项、WorkflowStateTests 3 项、定向 AsyncStateTests 2 项，共 15 项通过，0 失败。覆盖待回补帧去重和保留、后续外观库恢复、相似身份拒绝、连续两帧重获、两侧位置检索参考、回补失败自动打开手动框选及确认后继续分析。生产管线先扫描、再缓存关联／局部重试，完整轨迹校验后才完成；分析缓存升级 deferred-v2。最终构建已安装；本轮未使用真实视频验证恢复成功率、耗时或 GPU 性能。

2026-10-20 手动框直接确认：iPhone 模拟器构建、异步状态 1 项与手动框选 UI 1 项通过，0 失败。使用无私人视频的注入管线验证确认框选不触发第二次候选检测、旧检测回调不覆盖手动区域、确认后可继续分析；UI 验证四边手柄、移动和确认操作。“确认区域并识别”改为“确认人物区域”；后续生产跟踪算法未修改，未据此测量真实性能。

2026-10-20 按钮热区检查：统一 StudioTextButton、StudioAction、PrimaryAction、StudioIcon 和 DesktopButtonStyle 的 label 内尺寸与 contentShape；修复重新选择／取消生成、返回修改／导出、手动框选／取消／重画、宽屏打码操作，以及导入、贴片、候选框等空白区域点击。iPhone 模拟器构建及 UI 3 项通过，0 失败；测试在“重新选择”宽度 8% 和共用确认按钮宽度 10% 的非文字区域点击，分别验证回到选人和完成框选，同时回归构图、打码与时间范围。Mac 分支仅静态检查，本轮未执行 Mac 构建。

2026-10-20 分析重新选择：iPhone 模拟器构建通过，WorkflowStateTests 3 项、UI 1 项通过，0 失败。验证取消后 editing、目标与轨迹清空、延迟后演示回调不恢复旧状态、未选人按钮禁用、重新点选后可开始；生成取消入口保持原行为。

2026-10-20 手柄跨线居中：四边矩形手柄改为以边框为中心、内外各一半，保留尺寸限制及框内拖动区域。iPhone 模拟器构建通过，已安装并启动；本轮未重跑 UI 自动化。此条替代先前沿内侧绘制的样式。

2026-10-20 细手柄与移动框体：iPhone 模拟器构建及手动框选 UI 1 项通过，0 失败。可见手柄限制为 18×3pt 且长度不超过边长 35%，沿内侧绘制；小框缩小手柄触摸区保留中央拖动区域。UI 验证边手柄调整、框内拖动移动位置且宽高不变。

2026-10-20 手动选人矩形框：iPhone 17 Pro／iOS 26.3.1 构建通过，CameraPlanTests 7 项、四边手柄 UI 1 项通过，0 失败。验证单边调整固定对边、忽略另一轴、最小尺寸与边界，UI 验证四边手柄可点、旧四角圆点移除以及右边手柄拖动；已复核绘制人物截图。

2026-10-20 设置页时间范围：iPhone 17 Pro／iOS 26.3.1 构建通过，WorkflowStateTests 2 项通过、CompositionTests 12 项（10 项通过、2 项因私人视频未配置跳过），UI 1 项通过，0 失败。验证设置页拖动终点后保留工具和分析、生成仍使用构图；状态用例验证缩短范围后重开、预览配置与导出配置、超出轨迹后要求分析以及缩回缓存范围恢复复用。已复核模拟人物范围截图；导出参数用替身验证，未测真实 MP4 时长与音轨。

2026-10-20 顶栏层级：手机与 Mac 顶栏提高 zIndex，sourceStage 在布局边界裁剪。iPhone 模拟器构建通过，已安装并打开；本轮未运行 UI 自动化。

2026-10-20 默认保存返回：首页返回确认已移除，手机与 Mac 均直接调用现有 goHome，保留构图提交、持久化与任务取消链路。iPhone 模拟器构建通过，已安装并打开；本轮未运行 UI 自动化。此条替代先前真实项目返回需确认的交互要求。

2026-10-20 扩展构图画布：iPhone 17 Pro／iOS 26.3.1 构建通过，CompositionTests 共 12 项（10 项通过、2 项因未配置私人视频跳过），定向 UI 1 项通过，0 失败。模拟人物素材验证画布覆盖视频预览宽度、框外拖动改变构图设置、原分段控件及生成保留构图；复核截图确认框外毛玻璃与框内清晰窗口。手势基于窗口原点和尺寸换算，未更改导出变换；未测真实视频 GPU 性能。

2026-10-20 进度百分比折行修复：iPhone 模拟器构建通过，已安装并打开；百分比设置单行、横向固有宽度与优先布局，收紧按钮内边距及间距。本轮未运行 UI 自动化或捕获瞬时 100% 截图。

2026-10-20 演示返回：iPhone 模拟器构建通过，已安装并打开；静态核对演示返回直接调用 goHome，真实项目仍使用保存确认。首页标题“直拍快剪”一并构建，本轮未运行 UI 自动化。

2026-10-20 iPhone 首次使用入口：模拟器构建通过，已安装并打开。静态核对“第一次使用？”直接调用 startDemo，原首页底部演示入口和说明已移除；本轮未运行 UI 自动化。

2026-10-20 iPhone 最近项目移除更多按钮：iPhone 17 Pro／iOS 26.3.1 模拟器构建通过，已安装并打开。静态核对紧凑列表仍保留侧滑删除与确认，宽屏及 Mac 菜单未改动；本轮未运行 UI 自动化。

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

## 恢复运镜配置（2026-10-20）

构图套件 13 项：11 通过、2 项缺少私人视频跳过、0 失败，包含新增的预览计算期间连续切换运镜、保留构图配置测试。iPhone 17 Pro／iOS 26.3.1 原生面板 UI 回归最终通过，覆盖运镜三档、比例拖动、打码及生成保持构图；首次执行比例拖动后意外切入运镜，未修改代码重跑通过，保留为交互测试偶发问题，不能视为已定位修复。Mac Catalyst 构建通过。没有测量真实视频性能。

## 首页设置（2026-10-20）

设置仅提供关于与系统评价。iPhone 17 Pro／iOS 26.3.1、iPhone Duo／iOS 27.1 各通过 1 项 UI 测试，覆盖首页入口、整行空白区打开关于、实际版本信息、返回及关闭；Mac Catalyst 构建通过。Duo 测试附件为黑色画面，未据此认定视觉验收通过。系统评分是否弹出由 StoreKit 控制，未验证正式商店评价流程。

## 隐私清单与商店标识（2026-10-20）

添加 PrivacyInfo.xcprivacy，声明无追踪、无开发者数据收集，以及应用容器文件时间戳 C617.1 用途。plist 格式检查通过。iOS Simulator 与 Mac Catalyst 构建通过，逐一读取实际产物 Info.plist，确认 Bundle ID 为 com.fancamduck.com，且应用包内隐私清单与源文件一致。工程 Debug／Release 主应用、单元测试、UI 测试标识均核对通过。未执行 Apple 分发签名、App Store Connect 注册、上传或后台隐私申报；构建验证不代表商店审核通过。

关于页开源入口（2026-10-20）：新增仓库与 AGPL-3.0-only LICENSE 链接，Mac Catalyst 构建通过。iPhone 设置 UI 回归通过，覆盖两个入口可点击、协议标识显示及原有返回流程；SwiftUI Link 在本机未以 XCTest Link 类型暴露，测试按实际标识查询后通过。未自动跳转外部浏览器。

## 隐私与支持静态网站（2026-10-20）

新增网站首页、隐私政策、支持页与 404 页；静态文件内部链接及资源存在性检查通过，根目录 Vercel 配置仅输出 website/public。部署脚本语法、生产／预览参数及非法参数拒绝使用模拟 CLI 验证通过，未实际上传。浏览器本地检查首页、隐私、支持路径及原生 FAQ 展开；检查约 710px 视口并补充中等宽度单栏样式，未完成真实手机浏览器或 Vercel 生产验证。Git 忽略规则检查排除本地发布凭据及模型，允许网站文件与部署配置。正式域名、匿名生产访问和应用内隐私链接仍待部署后确认。
