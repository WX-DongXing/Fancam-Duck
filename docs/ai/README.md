# Fancam Duck AI 知识库

供开发助手和维护者理解当前实现、定位功能入口并验证修改。覆盖产品规则、状态流转、识别与渲染链路、多端布局、缓存和回归测试。最后核对日期：2026-10-19；当前工程名为 Fancam Duck，中文产品名为直拍鸭。更名范围及兼容规则见产品约束。

## 按任务阅读

| 任务 | 先读 | 再看代码 |
| --- | --- | --- |
| 理解产品或修改交互 | [产品约束](product.md) | `EditorView`、`ExportView` |
| 排查流程、取消或恢复 | [架构与状态](architecture.md) | `AppModel`、`ProjectStore` |
| 优化跟踪、构图或打码 | [媒体处理链路](pipeline.md) | `CoreMLTrackingPipeline`、`CropPlan`、`Redaction` |
| 修改手机、Duo、桌面布局 | [产品约束](product.md) | `WorkspaceLayout`、各 Features 视图 |
| App Store 标识与隐私申报 | [商店发布配置](app-store.md) | `PrivacyInfo.xcprivacy`、工程 Build Settings |
| 构建 macOS 发布产物 | [macOS 发布指南](macos-release.md) | `tools/release/release-macos.sh`、`.env.release.example` |
| 编译、测试和复现 | [验证指南](validation.md) | 单元与 UI 测试 |
| 提交代码与工程维护 | [提交规范](contributing.md) | 暂存区与提交信息 |
| 排查已知回归 | [问题索引](troubleshooting.md) | 对应测试与历史记录 |

根目录 [AGENTS.md](../../AGENTS.md) 是 AI 助手的自动发现入口；[项目 README](../../README.md) 面向首次使用项目的开发者。

## 信息优先级

用户最新明确要求优先。判断已实现行为时，先检查代码与可复现测试，再查日期明确的验证报告。历史截图和长篇产品方案用于解释背景，不能把其中的待办当成已实现能力。发现文档与代码冲突时，记录实际行为及影响，不静默推断代码一定正确。

## 维护方式

功能变化时更新对应主题，避免将新的迭代记录不断追加到索引。新增回归问题应写明触发条件、代码入口、测试和实际结果；完整日志、截图、样片指标放到 `docs/validation`，这里只保留链接。不要复制私人素材、本机临时路径或访问凭据。

当前知识库为仓库内 Markdown，可随代码检索与版本管理；没有引入向量数据库、云端索引或运行时 AI 服务。

设计素材遵循 [模拟素材规范](../design-assets/README.md)，后续新增设计截图时也需检查项目缩略图、时间轴和弹层背景。
