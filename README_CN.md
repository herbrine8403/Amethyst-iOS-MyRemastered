<div align="center">
  <img src="Natives/Assets.xcassets/AppIcon-Light.appiconset/1024x1024.png" alt="Air 图标" width="120" style="border-radius: 24px;">
</div>

<h1 align="center">Air</h1>
<p align="center"><sub>Amethyst iOS 重制版</sub></p>

<div align="center">
  <img alt="构建状态" src="https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/actions/workflows/development.yml/badge.svg?branch=main">
  <img alt="下载量" src="https://img.shields.io/github/downloads/herbrine8403/Amethyst-iOS-MyRemastered/total?label=Downloads&style=flat">
  <img alt="版本" src="https://img.shields.io/github/v/release/herbrine8403/Amethyst-iOS-MyRemastered?style=flat">
  <img alt="许可证" src="https://img.shields.io/github/license/herbrine8403/Amethyst-iOS-MyRemastered?style=flat">
  <img alt="最后提交" src="https://img.shields.io/github/last-commit/herbrine8403/Amethyst-iOS-MyRemastered?color=c78aff&label=last%20commit&style=flat">
</div>

<p align="center">
  <a href="./README.md">English</a> | <a href="./README_CN.md">Chinese</a>
</p>

---

一款面向 iOS 和 iPadOS 平台的 Minecraft: Java Edition 高端启动器，基于官方 Amethyst 项目深度重构。提供了精致的移动端体验，集成了全面的 Mod 管理、智能渲染器选择以及深度的平台适配能力。

---

## 目录

- [核心特性](#核心特性)
- [快速上手](#快速上手)
  - [设备要求](#设备要求)
  - [侧载准备](#侧载准备)
  - [安装步骤](#安装步骤)
  - [启用 JIT](#启用-jit)
- [贡献者](#贡献者)
- [第三方组件](#第三方组件)
- [捐赠](#捐赠)

## 核心特性

- **全新的现代化 UI** -- UI 界面深度美化，更符合现代设计风格
- **资源管理/下载** -- 浏览、启用、禁用和删除 Mod、光影包、资源包等各种资源，集成 Modrinth/CurseForge 下载支持。
- **整合包导入** -- 直接在启动器内导入 ZIP 格式的整合包。
- **下载源切换** -- 用户可在 Mojang 官方源、BMCLAPI 镜像源等之间切换，获得最佳下载速度。
- **完整中文本地化** -- 界面完整汉化，提供原生级中文语言体验。
- **账户限制解除** -- 支持本地账户、演示模式和第三方认证，无需 Microsoft 账户即可下载和游玩。
- **多账户支持** -- 在 Microsoft 账户、本地账户和第三方认证账户之间无缝切换。
- **安全的自动渲染器** -- Auto 当前固定解析为 ANGLE，以兼容 Minecraft 26.2+；如需 MobileGlues、GL4ES、Zink 或 MoltenVK，请手动明确选择。
- **适配 Minecraft 26.X** -- 添加 Minecraft 26.X 支持（实验性）
- **自定义鼠标指针** -- 在设置中自定义虚拟鼠标指针皮肤。
- **TouchController 支持** -- 通过 UDP 和 XCFramework 两种通信方式与 TouchController Mod 通信，为 iOS 提供完整的触屏控制。
- **AI 深度集成** -- (开发中，目标为实现 AI 完全管理启动器，包括资源下载、实例管理等功能)
- ... 还有更多功能等着您探索！


> [!NOTE]
> 暂无计划将重制版移植至 Android 平台。Android 生态已有诸多优秀启动器，如 [ZalithLauncher2](https://github.com/ZalithLauncher/ZalithLauncher2)、[Fold Craft Launcher](https://github.com/FCL-Team/FoldCraftLauncher)。如需官方 Android 版本，请前往 [Amethyst-Android](https://github.com/AngelAuraMC/Amethyst-Android)。
> (朕的 ShardLauncher 怎么中道崩殂了...？)

## 快速上手

完整文档请参阅 [Amethyst 官方 Wiki](https://wiki.angelauramc.dev/wiki/getting_started/INSTALL.html#ios) 或 [B站教程视频](https://b23.tv/KyxZr12)。以下为精简指南。

### 设备要求

| 级别 | iOS 版本 | 支持机型 |
|------|----------|----------|
| **最低配置** | iOS 14.0+ | iPhone 6s+、iPad 5 代+、iPad Air 2+、iPad mini 4+、全部 iPad Pro、iPod touch 7 代 |
| **推荐配置** | iOS 14.5+ | iPhone XS+（不含 XR/SE 2 代）、iPad 10 代+、iPad Air 4 代+、iPad mini 6 代+、iPad Pro（不含 9.7 英寸） |

> [!CAUTION]
> iOS 14.0--14.4.2 存在已知的严重兼容性问题，**强烈建议升级至 iOS 14.5 或更高版本。** iOS 17.x 和 18.x 受支持，但首次配置 JIT 需要电脑辅助（参见[官方 JIT 指南](https://wiki.angelauramc.dev/wiki/faq/ios/JIT.html#what-are-the-methods-to-enable-jit)）。iOS 26.x 可安装使用，但未经过专项适配，可能出现不可预测的问题。

### 侧载准备

优先选择支持「永久签名 + 自动 JIT」的工具：

1. **TrollStore** *(推荐)* -- 永久签名、自动启用 JIT、提升内存上限。兼容部分 iOS 版本。[从官方仓库下载](https://github.com/opa334/TrollStore)
2. **AltStore / SideStore** *(替代方案)* -- 需定期重签；首次设置需要电脑和 Wi-Fi。仅兼容**开发证书**（必须含 `com.apple.security.get-task-allow` 权限才能启用 JIT）。不支持分发证书签名服务。

> [!WARNING]
> 仅从官方或可信来源下载侧载工具和 IPA 文件。因使用非官方软件导致的设备问题，作者不承担责任。越狱设备支持永久签名，但不建议在日常设备上越狱。

### 安装步骤

<details>
<summary><b>正式版（TrollStore 渠道）</b></summary>

1. 前往 [Releases](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/releases) 下载 `.tipa` 安装包。
2. 通过系统分享菜单，选择用 TrollStore 打开，即可自动完成安装。
</details>

<details>
<summary><b>正式版（AltStore / SideStore 渠道）</b></summary>

1. 前往 [Releases](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/releases) 下载 `.ipa` 安装包。
2. 按照侧载工具的标准流程导入 IPA 完成安装。
</details>

<details>
<summary><b>Nightly 测试版（每日构建）</b></summary>

> [!CAUTION]
> 测试版可能包含崩溃、无法启动等严重缺陷，仅限开发测试使用。

1. 前往 [GitHub Actions](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/actions) 页面下载最新 IPA 构建产物。
2. 在侧载工具（AltStore、SideStore 等）中导入 IPA 完成安装。
</details>

### 启用 JIT

JIT（即时编译）是流畅运行游戏的关键。请根据自身环境选择合适的方案：

| 工具 | 需外部设备 | 需 Wi-Fi | 自动启用 | 备注 |
|------|:---:|:---:|:---:|-------|
| TrollStore | 否 | 否 | 是 | 首选方案，无需额外操作 |
| AltStore | 是 | 是 | 是 | 需本地网络运行 AltServer |
| SideStore | 仅首次 | 仅首次 | 否 | 初始设置后无需设备/网络 |
| StikDebug | 仅首次 | 仅首次 | 是 | 初始设置后无需设备/网络 |
| Jitterbug | 是（无 VPN 时） | 是 | 否 | 需手动触发 |
| 已越狱设备 | 否 | 否 | 是 | 系统级自动支持 |

## 贡献者

- [@yitenchen123](https://github.com/yitenchen123) -- 项目维护者
- [EternityQwQ](https://github.com/EternityQwQ) -- 添加 Metal Universal Mod 支持，允许启动器使用 Metal 渲染 Minecraft
- [@LanRhyme](https://github.com/LanRhyme) -- iOS 26 兼容性适配及日志改进
- [@WeiErLiTeo](https://github.com/WeiErLiTeo) -- Mod 下载功能集成、TouchController 优化、双指长按唤出键盘
- [@Li2548](https://github.com/Li2548) -- 上游同步维护

## 第三方组件

| 组件 | 用途 | 许可证 | 来源 |
|------|------|--------|------|
| Caciocavallo | AWT 运行时框架 | GPL-2.0 | [GitHub](https://github.com/PojavLauncherTeam/caciocavallo) |
| jsr305 | 代码注解支持 | BSD-3 | [Google Code](https://code.google.com/p/jsr-305) |
| Boardwalk | 核心功能适配 | Apache-2.0 | [GitHub](https://github.com/zhuowei/Boardwalk) |
| GL4ES | OpenGL 到 GLES 转译 | MIT | [GitHub](https://github.com/ptitSeb/gl4es) |
| Mesa 3D | 3D 图形库 | MIT | [GitLab](https://gitlab.freedesktop.org/mesa/mesa) |
| MetalANGLE | Metal 到 OpenGL ES 转译 | BSD-2 | [GitHub](https://github.com/khanhduytran0/metalangle) |
| MoltenVK | Vulkan 到 Metal 转译 | Apache-2.0 | [GitHub](https://github.com/KhronosGroup/MoltenVK) |
| openal-soft | 跨平台 3D 音频 | LGPL-2.0 | [GitHub](https://github.com/kcat/openal-soft) |
| Azul Zulu JDK | Java 运行时（8/17/21/25） | GPL-2.0 | [官网](https://www.azul.com/downloads/?package=jdk) |
| LWJGL3 | Java 游戏开发库 | BSD-3 | [GitHub](https://github.com/PojavLauncherTeam/lwjgl3) |
| LWJGLX | LWJGL2 兼容层 | -- | [GitHub](https://github.com/PojavLauncherTeam/lwjglx) |
| DBNumberedSlider | UI 滑块控件 | Apache-2.0 | [GitHub](https://github.com/khanhduytran0/DBNumberedSlider) |
| fishhook | 动态库重绑定 | BSD-3 | [GitHub](https://github.com/khanhduytran0/fishhook) |
| shaderc | Vulkan 着色器编译 | Apache-2.0 | [GitHub](https://github.com/khanhduytran0/shaderc) |
| NRFileManager | 文件管理工具 | MPL-2.0 | [GitHub](https://github.com/mozilla-mobile/firefox-ios) |
| AltKit | AltStore 集成 | -- | [GitHub](https://github.com/rileytestut/AltKit) |
| UnzipKit | ZIP 解压处理 | BSD-2 | [GitHub](https://github.com/abbeycode/UnzipKit) |
| DyldDeNeuralyzer | 库验证绕过 | -- | [GitHub](https://github.com/xpn/DyldDeNeuralyzer) |
| MobileGlues | 第三方渲染器 | LGPL-2.1 | [GitHub](https://github.com/MobileGL-Dev/MobileGlues) |
| LTW | OpenGL Core 到 ES 封装 | LGPL-3.0 | [GitHub](https://github.com/MojoLauncher/LTW) |
| authlib-injector | 第三方认证支持 | AGPL-3.0 | [GitHub](https://github.com/yushijinhun/authlib-injector) |

额外感谢 [MCHeads](https://mc-heads.net) 提供 Minecraft 头像服务、[Modrinth](https://modrinth.com) 提供资源分发服务，以及 [BMCLAPI](https://bmclapidoc.bangbang93.com) 提供 Minecraft 下载镜像服务。

## 捐赠

如果您觉得这个项目对您有价值，欢迎通过 [Ko-Fi](https://ko-fi.com/herbrine8403)、[爱发电](https://afdian.com/a/herbrine8403) 或[微信赞赏码](donate.png) 进行捐赠支持。

## Star History

<a href="https://star-history.com/#herbrine8403/Amethyst-iOS-MyRemastered&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=herbrine8403/Amethyst-iOS-MyRemastered&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=herbrine8403/Amethyst-iOS-MyRemastered&type=Date" />
   <img alt="Star history" src="https://api.star-history.com/svg?repos=herbrine8403/Amethyst-iOS-MyRemastered&type=Date" />
 </picture>
</a>
