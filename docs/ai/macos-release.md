# macOS 产物构建与发布

当前桌面端为 Mac Catalyst。入口：`tools/release/build-macos.sh`，可从任意工作目录调用。使用本机 Xcode、macOS 自带打包／签名工具；产物不纳入 Git。

## 本地试用包

```sh
tools/release/build-macos.sh --local
```

生成 Release 通用架构（arm64 + x86_64）`.app`、ZIP、SHA-256 校验文件、构建日志和 `BUILD-INFO.txt`。默认输出在 `build/macos/日期-local.随机后缀/`；每次创建新目录，不覆盖旧包。`build/macos/DerivedData` 是可复用缓存。

本地包使用 ad-hoc 签名，适合本机试用，不是通过 Gatekeeper 验证的公开发布包。解压后打开 `Fancam Duck.app`。脚本不修改系统安全设置。

可选环境变量：

- `FANCAM_DUCK_RELEASE_ROOT`：产物目录，默认仓库 `build/macos`。
- `FANCAM_DUCK_MAC_DERIVED_DATA`：构建缓存目录，默认产物目录下 `DerivedData`。

## 网站直接分发：Developer ID

前提：Apple Developer 团队、包含私钥的 Developer ID Application 证书，以及 Xcode 可使用的归档签名配置。先在 Xcode 中为团队完成 Signing 配置；脚本不创建证书、不注册设备、不自动修改账号配置。

```sh
APPLE_TEAM_ID=你的十位团队ID tools/release/build-macos.sh --developer-id
```

脚本归档并用 `developer-id` 方式导出，启用 Hardened Runtime，检查导出证书类型、签名、双架构、Logo 和两个 Core ML 模型。此步骤不上传产物，也不代表已完成 Apple 公证。归档、导出 plist 和日志保留在本次产物目录，便于检查签名问题。

公开分发建议使用 Apple 公证。先通过 `xcrun notarytool store-credentials` 将凭据存入钥匙串；不要在仓库中保存账号、密码或密钥。使用已经配置的 profile：

```sh
APPLE_TEAM_ID=你的十位团队ID tools/release/build-macos.sh \
  --developer-id --notarize 你的钥匙串Profile名称
```

`--notarize` 会将 ZIP 上传至 Apple，等待 `Accepted`，再装订和验证票据、检查 Gatekeeper，重新打包并生成校验文件。公证失败时脚本失败退出，保留原产物和结果；只有输出状态为 `developer-id-signed and notarized` 的 ZIP 才完成这条发布链路。脚本不上传网站或创建 GitHub Release。

## Mac App Store

本脚本的 Developer ID 包用于站外分发，不能直接作为 Mac App Store 上传包。商店发布还需单独配置 App Store Connect 应用、商店签名／描述文件、沙盒权限及元数据后验证归档上传流程。

## 验证范围

记录实际运行结果见 [验证指南](validation.md)。本地打包通过不能代替 Developer ID 签名、公证或下载后启动验证。发布前还应在目标 Mac 上检查导入、跟踪、构图、打码、导出和项目持久化，并完成仓库 README 中记录的模型授权确认。
