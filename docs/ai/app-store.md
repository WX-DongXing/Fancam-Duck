# App Store 发布配置

核对日期：2026-10-20。应用版本 0.1.0，构建号 1。

## 应用标识

- iOS／Mac Catalyst：`com.fancamduck.com`。
- 单元测试：`com.fancamduck.com.tests`；UI 测试：`com.fancamduck.com.uitests`。
- Debug 与 Release 一致；Mac Catalyst 不派生另一套 Bundle ID。
- Apple Developer 和 App Store Connect 中需使用这个标识；本地工程修改不代表已在 Apple 后台注册或取得分发描述文件。
- 新标识使用独立应用容器，不自动迁移旧标识安装内的私人项目；保留旧安装直到完成需要的数据导出。

## 隐私清单与 App Privacy

`Fancam Duck/PrivacyInfo.xcprivacy` 随主应用资源打包，iOS 与 Mac Catalyst 共用。

| 声明 | 当前依据 |
| --- | --- |
| NSPrivacyTracking = false | 无广告追踪、跨应用追踪或追踪 SDK |
| NSPrivacyTrackingDomains = [] | 无追踪域名 |
| NSPrivacyCollectedDataTypes = [] | 当前应用未将视频、人体／人脸分析结果、标识符或统计信息发送给开发者或第三方服务 |
| FileTimestamp / C617.1 | ProjectStore.digest 读取应用容器内视频的 modificationDate 与大小，判断本地摘要缓存是否失效；不离开设备 |

本轮检查应用 Swift 代码及工程依赖，未发现 UserDefaults／AppStorage、系统启动时间、磁盘容量或键盘列表的直接访问，不为未使用的类别添加理由。Date／CFAbsoluteTimeGetCurrent 的墙钟时间不作为系统启动时间声明。

App Store Connect 的 App Privacy 建议依据当前行为填写「不收集数据」；这仍需在后台实际填报，清单不会自动代填。本地视频、分析与缓存不等同于向开发者收集数据；用户主动保存照片或调用系统分享由相应系统流程处理。系统评分由 StoreKit 管理。新增遥测、云端分析、广告或 SDK 后必须重新核对。

清单不替代隐私政策网页及应用内入口，也不等同于 Apple 审核已通过。

Apple 参考：[隐私清单](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)、[必需原因 API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)。

## 开源许可状态

项目已经开源并采用 AGPL-3.0-only，完整声明、对应源码及第三方模型来源见根目录 LICENSE、README 与模型清单。当前采用开源分发路径，不以闭源或购买企业授权作为既定前提。发布包应保留适用的许可／版权声明并提供对应版本源码入口；已开源的事实本身不代表已经取得 Apple 对商店分发兼容性的确认。

## 商店分发

现有 Developer ID／公证脚本用于商店外分发。App Store 上传使用独立的 App Store Connect 归档、分发签名及描述文件，不上传 DMG 代替商店构建。

## 隐私与支持网站

仓库 `website/public` 提供首页、`/privacy` 与 `/support`，根目录 vercel.json 配置只输出该静态目录。Vercel 部署按钮与 CLI 脚本、本地预览方法见 [网站说明](../../website/README.md)。当前支持联系人为 GitHub Issues，未虚构邮箱。正式生产域名尚未确定，App 尚未添加隐私链接，后台链接也未填报；部署后需验证匿名可访问再接入。
