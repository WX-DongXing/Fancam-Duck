# 架构与状态流转

## 模块职责

| 模块 | 入口 | 责任 |
| --- | --- | --- |
| 状态协调 | `Fancam Duck/App/AppModel.swift` | `@MainActor @Observable`，项目、任务、播放和路由 |
| 领域数据 | `Fancam Duck/Domain/Project.swift` | 设置、画幅、时间范围、坐标、处理阶段 |
| 界面 | `Fancam Duck/Features/` | 首页、编辑、构图、时间轴、导出 |
| 自适应布局 | `Fancam Duck/Design/WorkspaceLayout.swift` | ArrangementView 与 AnyLayout 回退、Mac 布局 |
| 识别跟踪 | `Fancam Duck/Tracking/` | 模型推理、身份关联、遮挡恢复、裁剪 |
| 打码 | `Fancam Duck/Redaction/` | 非主角轨迹、覆盖规则、合成 |
| 基础服务 | `Fancam Duck/Services/` | 媒体、存储、跟踪协议与编码 |

`TargetTracking`、`VideoExporting` 和 `PhotoSaving` 支持注入替身，流程回归不应全部依赖完整模型和私人视频。

## 路由与处理阶段

`Route` 为 `home`、`editor`、`export`。`ProcessingPhase` 独立表示业务阶段；不要用页面是否显示来替代流程判断。

```text
editing（选人／选段）→ processing（分析）→ editing（已分析，构图／打码）
                                ↕ paused
                                ↓ blocked → 确认同一主角 → processing
editing（已分析）→ processing（准备打码／生成）→ completed（预览／导出）
                                               ↓ 返回修改
                                        editing（复用分析）
```

图示为主要业务路径，不是所有方法的调用表。`ProcessingGate.canContinue` 校验目标与明确选择；`AppModel.canConfirm` 还校验检测、恢复、构图手势等忙状态。新工作台通过 `advanceWorkflow` 区分首次分析与已有分析后的生成。首次分析完成留在 editor；生成实际 MP4 后使用 completed 状态，仍留在 editor，导出仅保存文件。`readyToExport` 与独立 export 路由保留给现有兼容调用，不作为新工作台的首次分析完成态。

`togglePreview` 和普通 `scrub` 仅在 editing 允许。`seek` 仍用于阻塞纠正中的明确帧检查。不能为了禁用普通时间轴把全部纠正寻帧也禁掉。

编辑期候选检测不应阻止已有主角的构图、打码设置。进入构图或手动框选会使旧候选检测失效；检测任务退出时仅清理同项目、同 detectionID 的忙碌状态，避免旧任务清掉新任务状态。项目恢复、构图预览准备及图片准备期间通过 `editorActivityText` 和主按钮说明等待原因。构图取消不随面板计算禁用；处理／导出／身份阻塞的业务限制保持独立。

## 异步任务

AppModel 保存多个 Task，并以 operationID、detectionID、compositionID、restorationID 等代次标识过滤旧结果。更新前还需核对 projectID。取消 Task 后不能假设底层服务立即停止，晚到进度、错误与完成回调仍可能发生。

改动时检查：切到首页、快速暂停恢复、导入另一项目、删除项目、应用后台、取消导出。持久化和删除需要考虑正在进行的保存，避免删除后的项目被旧任务重新写回。

## 持久化与复用

`ProjectStore` 是 actor，默认目录为 Application Support 下的 `Fancam Duck`。新目录不存在时原位迁移旧 `AICut` 目录；如果两者已存在，保留两份数据并使用新目录。

- `projects.json`：项目和编辑设置，原子写入。
- `trajectory-<UUID>.json`：完整主角轨迹及人群观测批次（人物框、姿态、外观特征），带分析版本、源 SHA256、元数据及目标锚点。读取时验证轨迹覆盖当前范围；恢复后寻帧及打码构建复用观测，设置变化不重复推理。旧缓存缺少人群批次时可能需要补充检测，不伪称其已有完整人群结果。
- `artifacts-<UUID>/output.json` 及 MP4：成片记录，匹配源摘要、设置与目标后才复用；保存相册状态记录在清单中。
- 源视频为应用管理副本；删除项目清理其轨迹、输出及不再被其他项目引用的副本，不触及相册原片。

完整轨迹和有效输出可跨重启复用，不能把它们描述为仅在内存中缓存。处理中的部分会话／检查点则不等于可跨重启完整恢复的任务。

`GenerationRecipe`、`lastGeneratedRecipe` 和 `hasReusableOutput` 用于当前会话判断旧结果是否可复用。更改模型或分析语义时评估 `ProjectStore.analysisVersion` 是否需要变更。

## 构图和打码即时设置

新工作台仅在完整分析后显示构图／打码工具，不再常驻选人、面板取消或完成按钮。工具切换提交当前配置，构图手势结束和比例切换会持久化，打码范围、样式和强度独立更新。重新进入打码面板不能重新开启用户关闭的打码。图片样式直接使用内置 BrandLogo。

生成前提交构图设置后会退出编辑态，但构图预览展示不再依赖 `compositionEditing`：已有完整分析且保留 `compositionCrop` 时，生成期间继续使用同一裁剪视窗；身份阻塞仍回到问题帧。构图手势仅在可编辑且处于构图编辑态时开放。

构图与打码继续复用既有计算和 GPU 合成链路。若完整打码计划尚未覆盖新范围，允许静态编辑，不允许播放未覆盖的动态预览。身份不确定仍停在问题帧；手动区域必须经过检测成为有效人物候选。生成取消保留主角分析与设置，旧成片保留至新文件成功写入。任务 ID、项目 ID 和取消后回调校验不可移除。

手机设置展开与收起使用短动画，紧凑状态不为设置预留大块空白；工作台保持同一 editor 路由。视频时间轴在分析前及分析后的设置阶段均可修改起止点；运行中的分析／生成及身份阻塞时禁用。裁短且轨迹仍覆盖时复用分析并重建区间预览；扩大到轨迹未覆盖部分时退出设置、要求重新分析，不使用旧预览。修改画幅、打码不更改时间范围。

重新生成的进度按本次实际工作分配：复用分析时不计入分析权重，已有有效打码计划时不计入打码准备权重；新生成从 0% 开始，编码完成前最多显示 99%。断点分析仍沿用原恢复机制，取消与晚到回调继续校验任务和项目 ID。
