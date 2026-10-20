# 直拍鸭支持网站

无构建依赖的静态网站，内容在 `public/`，发布目录只包含 HTML、CSS、站内 JavaScript 与应用 Logo。

- `/`：产品介绍。
- `/privacy`：隐私政策（可填入 App Store Connect 的 Privacy Policy URL）。
- `/support`：使用帮助与 GitHub Issues 联系入口（可填入 Support URL）。

## 一键部署到 Vercel

先将本次网站文件和根目录 `vercel.json` 提交并推送到 GitHub，再点击：

[![Deploy with Vercel](https://vercel.com/button)](https://vercel.com/new/clone?repository-url=https%3A%2F%2Fgithub.com%2FWX-DongXing%2FFancam-Duck&project-name=fancam-duck&repository-name=fancam-duck-site)

该按钮使用 Vercel 官方的克隆部署流程，会创建新项目并可能克隆仓库。如需持续跟随本仓库的更新，建议在 Vercel 的 Add New → Project 中导入原仓库，保留 Root Directory 为根目录。根目录配置已指定 Framework 为 Other（null）、无需安装和构建、Output Directory 为 `website/public`；不要把整个仓库设为静态输出目录。

部署需要你登录 Vercel 并选择账户。确认生产域名后，确保页面不要求访客登录 Vercel；必要时调整该项目的生产部署保护。验证 `/privacy`、`/support` 可匿名访问后，再填写商店链接并将正式地址接入 App 关于页。

已有 Vercel CLI 时，也可以在仓库根目录执行：

```sh
tools/release/deploy-website.sh
```

首次执行会进入 Vercel 的项目关联流程，可能要求登录；默认生产部署，传 `--preview` 则仅创建预览部署。脚本不安装 CLI、不保存令牌。`.vercelignore` 对 CLI 上传仅保留网站与部署配置，排除原视频、模型、凭据和其他工程文件；Vercel 只发布 `website/public`。

官方说明：[Deploy Button](https://vercel.com/docs/deploy-button)、[静态站点构建配置](https://vercel.com/docs/builds/configure-a-build)、[CLI 部署](https://vercel.com/docs/cli/deploy)。

## 本地预览

```sh
python3 website/preview.py
```

访问 `http://127.0.0.1:8765`，支持与生产一致的无扩展名页面路径。

## 内容维护

政策基于当前 App 行为：本机处理、无开发者数据收集、无追踪。网站没有分析脚本、外部字体或 Cookie；托管方可能处理访问日志，政策单独说明。新增服务或更改部署商后重新核对。

支持渠道目前使用公开 GitHub Issues，不填写虚构邮箱。可后续替换为维护者确认的邮箱。没有虚构 App Store 下载链接、域名或版权持有人信息。发布前应确认维护者接受该支持渠道，并按实际运营主体、地区及服务情况校对政策。

## 落地页设计

首页采用深色舞台与暖黄品牌色，结构为首屏交互示意 → 三步使用流程 → 本机处理说明 → 六项 FAQ → 体验入口。主要操作为“体验直拍效果”；没有确认的商店地址前，保留 GitHub 项目入口。

`landing.css` 提供全站基础样式，`landing.js` 仅用于首页交互。隐私、帮助与 404 页面复用首页品牌、导航、按钮与页脚样式，并通过 `style.css` 补充长文、目录、FAQ 与错误页布局。动效参考 React Bits 的 [Split Text](https://reactbits.dev/text-animations/split-text)、[Magnet](https://reactbits.dev/animations/magnet)、[Spotlight Card](https://reactbits.dev/components/spotlight-card)，以原生 CSS/JS 实现，没有引入 React 或复制组件源代码。支持减少动态效果设置与键盘操作；演示人物为 SVG 绘制，模式切换是概念示意，不是真实视频处理输出。

保持常青内容可索引；首页 title 与 description 围绕群舞转个人直拍，FAQ 使用可读取的正文。没有虚构评价、处理速度或准确率。设计来源：[MengTo landing-page](https://github.com/MengTo/Skills/tree/main/agent-skills/web-design/landing-page)。
