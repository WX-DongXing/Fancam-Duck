# 直拍鸭 · Fancam Duck

将多人舞蹈视频转换为跟随主角的成片。使用 SwiftUI、Core ML 和 AVFoundation 在本地完成选人、身份跟踪、平滑运镜、自动裁剪及非主角遮挡，支持 iPhone、iPhone Duo、大屏工作台和 Mac Catalyst。

## 功能与流程

1. **导入视频**：从相册导入；桌面端支持文件导入。创建本地项目并自动保存编辑配置。
2. **全览选人**：显示完整原片，在画面上点选主角；漏检时可手动框选区域重新识别。拖动同一条时间轴两端调整处理范围。
3. **调整构图**：切换画幅，拖动位置、双指缩放，或分别水平／垂直居中。预览与导出共用裁剪变换。
4. **可选打码**：自动遮挡主角以外的人物，可选择人脸或整人范围；毛玻璃、马赛克、图片三种样式互斥。图片不添加额外黑色阴影。
5. **原位处理**：设置区动画收起，视频实时显示主角跟踪框；底部按钮显示进度，支持暂停、继续和暂停后返回调整。
6. **异常纠正**：短时遮挡优先自动恢复；身份无法可靠确认时阻塞处理，直接在问题帧重新选人并确认继续。
7. **预览与导出**：处理完成后进入预览，保留原音，支持保存相册及系统分享；桌面端可保存至文件。返回编辑修改配置后需要重新生成，不能直接复用旧成片。

手机编辑页保持不滚动；大屏使用视频与设置分区布局，Mac 使用桌面工作台。界面采用玻璃材质控件和 SF Symbols。运镜默认柔和，不单独占用底部工具入口。

> 当前产品中的画幅标签按高宽顺序定义：`16:9` 对应竖向 9×16，`4:3` 对应竖向 3×4，`1:1` 对应正方形。几何计算使用宽／高比，详见 `OutputAspectRatio`。输出分辨率依据源视频和当前画幅生成，按小到大排列。

## 开发与运行

工程与 Scheme 名称为 `Fancam Duck`，Swift 模块为 `FancamDuck`。中文应用名为「直拍鸭」，英文应用名为「Fancam Duck」。旧安装的签名标识保持兼容，历史项目目录在首次打开时迁移。

- 部署基线：iOS 18；Mac 版本使用 Mac Catalyst。
- 当前验证工具链：Xcode 27.1。iPhone Duo 的布局使用相应 SDK 的适配能力，建议使用同版本工具链。
- 模型已包含在 `Fancam Duck/Models`，由 Xcode 编译，无需运行时下载；正常构建不需要 Python 环境。

打开工程：

```sh
open 'Fancam Duck.xcodeproj'
```

选择 `Fancam Duck` scheme 和可用的 iPhone 模拟器运行。Mac 选择 Mac Catalyst 目标；真机运行需在 Signing & Capabilities 配置自己的开发团队。

启动参数 `--demo-editor` 可直接进入演示编辑流程。演示使用程序绘制素材，不生成真实视频，也不请求相册保存权限。

模拟器构建：

```sh
xcodebuild -project 'Fancam Duck.xcodeproj' -scheme 'Fancam Duck' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/fancamduck-build CODE_SIGNING_ALLOWED=NO build
```

Mac Catalyst 构建：

```sh
xcodebuild -project 'Fancam Duck.xcodeproj' -scheme 'Fancam Duck' \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /tmp/fancamduck-mac-build CODE_SIGNING_ALLOWED=NO build
```

## 识别、跟踪与渲染

```text
视频解码 → YOLO26s-pose 人物与姿态检测 → OSNet 外观特征
         → TrackTrack 身份关联 → 遮挡恢复／必要时人工确认
         → 平滑裁剪轨迹 → 可选非主角遮挡 → 预览／MP4 导出
```

- **YOLO26s-pose**：FP16 Core ML，640×640 输入，原始姿态输出，应用侧执行 NMS。
- **OSNet x0.25 MSMT17**：128×256 人物裁块，输出 512 维归一化 ReID 特征。
- **TrackTrack**：基于固定版本移植的 Swift 实现，包含 TPA／TAI 关联和 Kalman 状态。当前相机运动补偿为恒等变换，主要适配固定机位。
- **打码**：复用现有人物检测、姿态和身份关联能力，不使用 Apple Vision 检测；对遮挡轨迹进行时序稳定处理。
- **裁剪与导出**：AVFoundation 顺序取帧，使用稳定轨迹生成裁剪变换；音频截取相同时间范围，输出 MP4。

模型来源、权重哈希、工具版本及输入输出约定见 [模型清单](<Fancam Duck/Models/manifest.json>) 和 [模型来源说明](<Fancam Duck/Models/README.txt>)。重新转换模型的依赖和脚本位于 [tools/model_export](tools/model_export)。转换可能下载权重，属于开发步骤。

## 代码结构

| 目录 | 职责 |
| --- | --- |
| `Fancam Duck/App` | 应用入口、状态流转、异步任务与生命周期 |
| `Fancam Duck/Design` | 玻璃材质、主题与自适应布局 |
| `Fancam Duck/Domain` | 项目、时间范围、坐标和输出配置 |
| `Fancam Duck/Features` | 项目列表、选人、构图、时间轴与导出界面 |
| `Fancam Duck/Tracking` | 检测、身份关联、遮挡恢复与运镜 |
| `Fancam Duck/Redaction` | 非主角遮挡计划、跟踪与合成 |
| `Fancam Duck/Services` | 媒体读取、存储、模型服务、编码和保存 |
| `FancamDuckTests` / `FancamDuckUITests` | 单元、媒体集成和界面回归测试 |
| `tools` | 模型转换、参考实现与验证工具 |
| `docs` | 产品方案、评估、截图与验证记录 |

## 测试与验证

运行单元及媒体集成测试：

```sh
xcodebuild -project 'Fancam Duck.xcodeproj' -scheme 'Fancam Duck' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/fancamduck-build CODE_SIGNING_ALLOWED=NO \
  test -only-testing:FancamDuckTests
```

运行界面回归，将最后一行改为 `test -only-testing:FancamDuckUITests`。模拟器名称需与本机已安装设备一致。

普通媒体测试现场生成所需片段，仓库不包含测试视频。依赖人物视频的用例需通过 `FANCAM_DUCK_TEST_VIDEO` 指定本地文件，否则明确跳过；通过 xcodebuild 传入时使用 `TEST_RUNNER_FANCAM_DUCK_TEST_VIDEO`。人物识别用例要求视频中有可识别的多个人物，任意视频不保证满足断言。依赖桌面私人视频的完整流程、遮挡和性能用例需要显式启用并准备素材，默认跳过；不要将私人视频提交到仓库。历史验证成片部分被 Git 忽略，新检出仓库可能只有报告和截图。

最近一轮流程与功能 CR（2026-10-19）：

- 完整单元／集成套件：97 项，6 项按需跳过，0 失败。
- 最终异步状态回归：13 项通过；iPhone、Duo 各 2 项 UI 回归通过；Mac Catalyst 构建通过。
- 修复异常确认期间播放／拖动越过问题帧、修改打码配置后构图报错，以及成片播放状态未跟随后台暂停同步的问题。
- 本轮未重跑桌面完整视频的性能基准。详细范围见 [CR 验证记录](docs/validation/code-review/2026-10-19.json)。

## 已知限制

- 整人遮挡仍基于矩形包络，复杂交叠时可能影响主角边缘，尚未使用实例分割实现像素级避让。
- 快速动作、相似服装、长时遮挡和移动机位仍可能需要人工确认；不保证所有场景连续自动跟踪。
- 完整跟踪轨迹与成片支持校验后持久化复用；处理中的部分检查点不等同于可跨应用重启恢复的完整任务。缓存失效时需重新分析。
- 暂未实现多片段拼接、背景补画布和云端增强。源画面边界限制了可用构图范围。
- 真机 ANE 吞吐、热稳定性、长视频内存及 HDR／VFR 尚需专项验证。模拟器数据不代表真机性能。

## 文档与界面预览

设计展示统一使用模拟人物图片和演示截图。历史验证数据保留，替换后的示例图不再对应原测试帧；详见 [设计素材说明](docs/design-assets/README.md)。

- [AI 开发知识库](docs/ai/README.md) · [AI 助手入口](AGENTS.md)

- [产品与技术方案](<docs/Fancam Duck产品与技术方案.md>)
- [iOS 可行性与性能评估](docs/iOS可行性与性能评估.md)
- [iPhone Duo 布局评审](docs/validation/duo-redesign/review.html)
- [Mac 桌面布局评审](docs/validation/desktop-redesign/review.html)
- [打码功能评审](docs/validation/redaction/review.html)

评审页包含不同阶段的截图，部分属于历史迭代；当前行为以代码和最新验证记录为准。

## 第三方模型与许可

TrackTrack 和 OSNet 参考源码许可位于 `tools/reference`。Ultralytics 模型／软件、预训练权重及数据集的使用条件需分别核查，不能仅凭参考源码许可认定全部模型可商用；发布前需完成相应授权确认。模型来源说明中保留了相关链接。

## macOS 安装包

本地 `.env.release` 配置团队 ID、证书、公证 profile、版本号和输出路径后，运行 `tools/release/release-macos.sh` 一键构建签名发布包；临时本地试用可运行 `tools/release/release-macos.sh --local`。配置模板为 `.env.release.example`，实际配置不提交。Developer ID 签名及 Apple 公证参数见 [macOS 发布指南](docs/ai/macos-release.md)。产物默认保存在已忽略的 `build/macos/`。
