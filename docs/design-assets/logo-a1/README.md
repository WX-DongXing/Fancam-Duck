# 直拍鸭 Logo：A1

2026-10-19，用户最终选择 A1：暖黄色背景、奶油白歪头鸭、橘色宽嘴、深色轮廓。取消其余设计方向，包括取景角、聚光、姿态、配色及比例变体。

`app-icon-a1.png` 为选型展示稿，保留不覆盖。`app-icon-master.png` 是通过内置 imagegen 以 A1 为编辑目标生成的满版位图母图，已移除白色外边和预绘圆角；不是矢量母版。

生成提示词：保留 A1 奶油白歪头鸭、橘色宽嘴、深棕轮廓、眼睛和暖黄色配色，将黄色背景延伸至四边四角；无白边、无圆角、无文字、无新增元素，输出不透明正方形应用图标。

## 各端资源

工程 `Fancam Duck/Assets.xcassets/AppIcon.appiconset`：

- iPhone、iPad／Duo：共用 1024×1024 不透明 iOS universal 图标，由系统裁切圆角并派生尺寸。
- Mac Catalyst：16、32、128、256、512 pt 的 1x／2x 共 10 个槽位，复用 7 个 PNG 尺寸。桌面图标有 10% 透明外留白和圆角。
- 页面 `BrandLogo.imageset`：同源不透明图片，用于手机／宽屏首页标题和 Mac 侧栏，由 `BrandLogo` 视图按尺寸裁切圆角。
- Debug 与 Release 均使用 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`。

在仓库根目录运行以下命令重建资源（仅依赖 macOS 自带框架）：

```sh
swift -module-cache-path /tmp/fancamduck-swift-cache tools/branding/generate-app-icons.swift
```

母图决定鸭子造型，脚本仅做缩放与 Mac 外形遮罩。无需重新调用 imagegen。构建验证见 `docs/ai/validation.md`。
