# macOS 产物构建与发布

当前桌面端为 Mac Catalyst。入口：`tools/release/build-macos.sh`，可从任意工作目录调用。使用本机 Xcode、macOS 自带打包／签名工具；产物不纳入 Git。

## 一键配置入口

本地 `.env.release` 已创建并被 Git 忽略，权限为 600。仓库只维护不含凭据的 `.env.release.example`，换机器时先执行 `cp .env.release.example .env.release`。配置文件是可信的 Bash 文件，不要复制未知来源的命令；脚本不输出文件内容。

关键值：

| 变量 | 用途 |
| --- | --- |
| `RELEASE_MODE` | `developer-id` 正式签名或 `local` 本地签名 |
| `APPLE_TEAM_ID` | 十位开发者团队 ID |
| `APPLE_SIGNING_CERTIFICATE` | 导出证书名称或 SHA-1，默认 Developer ID Application |
| `RELEASE_NOTARIZE` | `true` 上传 Apple 公证并装订；`false` 仅签名 |
| `APPLE_NOTARY_PROFILE` | 已存入钥匙串的 notarytool profile 名称 |
| `FANCAM_DUCK_VERSION` / `FANCAM_DUCK_BUILD_NUMBER` | 可选版本／构建号，留空沿用工程 |
| `FANCAM_DUCK_RELEASE_ROOT` / `FANCAM_DUCK_MAC_DERIVED_DATA` | 产物与缓存目录 |

密码、私钥和 API 密钥使用钥匙串存储，配置中仅填写 profile 名称。所有相对路径相对于仓库根目录。`.env.release` 的值覆盖同名进程环境变量；命令行 `--local` 或 `--signed-only` 再覆盖模式／公证设置。

```sh
# 填好配置后：构建 → 签名 → 按配置公证 → 装订 → 打包和校验
tools/release/release-macos.sh

# 只检查配置格式，不验证证书或凭据，不构建、不上传
tools/release/release-macos.sh --check

# 临时只生成本地试用包
tools/release/release-macos.sh --local

# 临时只进行 Developer ID 签名，不上传 Apple
tools/release/release-macos.sh --signed-only
```

模板默认正式签名并公证，但团队 ID 与 profile 留空。未填写会在构建前明确失败，不会自动降级为本地包。`local` 模式始终不上传，即使配置里公证开关为 true。底层 `build-macos.sh` 仍可直接通过环境变量调用，不会自行加载配置。

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
