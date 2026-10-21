# 预览设置开启打码后无法播放

日期：2026-10-22。状态：代码及受控视频回归通过，用户 iPhone 私人素材尚未直接复验。

## 现象与根因

用户确认真实视频在 iPhone 预览设置中开启打码后点击播放无反应，关闭打码后恢复。播放按钮和 togglePreview 都要求项目持有完整 redactionPlan；但设置页的静帧打码使用临时轨迹，不把它写为导出轨迹。因此已有完整人物缓存仍被禁用播放，只有生成阶段写入计划后才满足条件。

新增 testRedactedSettingsCanPlayFromCachedAnalysisBeforeGeneration 使用实际写入的合成 MP4、已确认主角与旁人缓存复现：修复前 previewPlayer.currentItem 为空，断言失败，日志 /tmp/fancam-playback-before-ios.log。

## 修复

- 播放进入当前构图会话，沿用排队等待最新预览的逻辑，不用项目导出计划是否存在来禁用按钮。
- 从已确认的人物检测缓存构建临时打码轨迹；覆盖范围检查及既有 VideoExporter 主角冲突检查通过后，才创建移动预览。
- 临时计划放在预览专用项目副本中，不回写 project.redactionPlan，不记录生成成功，不重新跑人物检测。
- 修改设置时暂停旧预览并撤销 ready 状态；最新任务完成后才允许播放。保留项目 ID、任务 ID、取消、切项目与删除防护，缺失或过期计划不能继续播放。
- 无有效预览时通过现有错误入口提示。活动手势期间不启动播放。
- 完整回归还发现零位移调用会把平滑微差写回构图目标，已将零位移设为无操作，避免无意偏移。

同时完成本轮界面要求：三个卡片共用测量与动画，顶部外边距 10pt、底部 12pt；移除打码问号及浮层，开关开启为主题色。

## 验证

- 新媒体回归修复前失败、修复后通过。检查实际 AVPlayer 时钟前进、旁人遮挡轨迹存在并覆盖片段、临时计划不回写项目；切换马赛克后立即请求播放，等待最新预览并检查实际新样式。
- /tmp/fancam-settings-playback-regressions-ios.log：FancamDuckTests 共 196 项，142 通过、54 条件性私人素材等用例跳过、0 失败；SubjectCompositionFlowTests 1 项通过。该次 xcodebuild 在用例完成后的收尾阶段停滞，已停止进程，依据为上述完整用例日志，不将未完成的 xcresult 记为可用报告。
- Mac Catalyst arm64 构建通过，日志 /tmp/fancam-settings-final-build-mac.log。
- 本轮未在用户 iPhone 私人片段、真机性能或 Mac 实际窗口验证，受控素材不能代替该验收。

最终界面回归：/tmp/fancam-settings-final-ui.xcresult 的 1 项 UI 通过（TEST SUCCEEDED）。截图已更新为顶部 10pt、无问号及说明浮层的最终样式，开启打码的菜单行保持完整高度；三卡片上下间距断言通过。
