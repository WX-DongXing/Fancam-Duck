# Fancam Duck AI 开发入口

开始修改前阅读 [知识库索引](docs/ai/README.md)，再按任务查阅架构、产品约束和验证指南。知识库更新时间为 2026-10-19，代码变化后应同步维护。

## 开发约定

- 以当前代码、可复现测试和用户最新确认的行为为依据。历史设计截图及旧产品文档可能已过时。
- 主角跟踪使用 YOLO26s-pose、OSNet 和 TrackTrack。复用现有链路，不擅自引入 Apple Vision 检测。
- 保持手机编辑页不滚动、初次导入显示完整原片。身份不确定时阻塞，不能越过问题帧继续生成。
- 构图预览与导出共用变换；打码默认作用于主角以外所有人，三种样式互斥，不能遮挡主角。
- 修改异步任务时同时检查取消、晚到回调、项目切换、后台和删除。保留任务 ID 与项目 ID 的有效性校验。
- 根据改动选择有意义的测试，见 [验证指南](docs/ai/validation.md)。区分构建通过、模拟器验证和真实视频性能测量。
- 设计文档只使用绘制的模拟人物或纯模拟素材截图，包含项目缩略图、时间轴和视频替代图；不能重新引入真实人物照片。素材入口见 `docs/design-assets/README.md`。
- 不提交私人视频、模型转换环境和构建产物；不为验证结果编造性能结论。文档中的测试数量是历史记录，不是当前运行结果。
- 不自动提交或推送，除非用户要求。不要覆盖与任务无关的本地改动。
- 提交信息遵循 [提交规范](docs/ai/contributing.md)，使用 `feat: 简短说明`、`refactor: 简短说明` 等格式。

## 常用入口

- 状态协调：`Fancam Duck/App/AppModel.swift`
- 模型与跟踪：`Fancam Duck/Tracking/CoreMLTrackingPipeline.swift`
- 构图：`Fancam Duck/Tracking/CropPlan.swift`
- 打码：`Fancam Duck/Redaction/`
- 导出：`Fancam Duck/Services/VideoExporter.swift`
- 持久化：`Fancam Duck/Services/ProjectStore.swift`
