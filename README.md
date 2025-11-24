# 我的Angel Aura Amethyst (iOS) 重制版
[![开发构建状态](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/actions/workflows/development.yml/badge.svg?branch=main)](.github/workflows/development.yml)
![总下载量](https://img.shields.io/github/downloads/herbrine8403/Amethyst-iOS-MyRemastered/total?style=flat-square&color=00a82a)
![发布版本](https://img.shields.io/github/v/release/herbrine8403/Amethyst-iOS-MyRemastered?style=flat-square&color=00a82a)

[English](README_EN.md) | **中文** 

## 🌟 重制版核心亮点
基于官方 Amethyst 优化适配，聚焦 iOS/iPadOS 体验升级，核心特性包括：
- **Mod管理**：复刻其他启动器的Mod管理功能，支持查看Mod基本信息，一键禁用/删除Mod
- **导入整合包**：支持导入 ZIP 和 MRPACK 格式的整合包（不稳定）
- **更改鼠标指针**：支持在设置界面自定义虚拟鼠标指针的皮肤
- **智能下载源切换**：自动识别网络环境，在 Mojang 官方源与 BMCLAPI 之间择优选择，下载更稳定
- **完整中文本地化**：界面完整汉化，更适合中国宝宝体质 awa
- **账户限制解除**：支持本地账户、演示账户（Demo Mode）和第三方账户直接下载游戏，无需登录 Microsoft 账号或 Test 账号
- **多账户登录**：兼容 Microsoft 账号、本地账号及第三方认证账户
- **更改新闻页面网址**：可自由更改新闻页面的网址
- **自动选择渲染器**：渲染器切换为 Auto 后将自动选择合适的渲染器，包括 MobileGlues
- **自动选择JVM**：将根据游戏版本自动选择 JVM 版本，包括 Java21
- **自定义图标**：（开发中，即将上线）

> ⚠️ 说明：暂不计划重置 Android 版本（Android 端的优秀启动器太多了,例如ZL、FCL），如需官方 Android 代码，可前往 [Amethyst-Android](https://github.com/AngelAuraMC/Amethyst-Android)。


## 🚀 快速上手指南
完整安装及设置文档可参考 [Amethyst 官方维基](https://wiki.angelauramc.dev/wiki/getting_started/INSTALL.html#ios)，或查看我的 [B站教程视频(很古早)](https://b23.tv/KyxZr12)。以下为精简步骤：


### 📱 设备要求
| 类型       | 系统版本要求                | 支持机型列表                                                                 |
|------------|-----------------------------|------------------------------------------------------------------------------|
| **最低配置** | iOS 14.0 及以上             | iPhone 6s+/iPad 5代+/iPad Air 2+/iPad mini 4+/所有 iPad Pro/iPod touch 7代 |
| **推荐配置** | iOS 14.5 及以上（体验更优） | iPhone XS+（不含 XR/SE 2代）、iPad 10代+/Air 4代+/mini 6代+/iPad Pro（不含9.7英寸） |

> ⚠️ 关键提醒：iOS 14.0~14.4.2 存在严重兼容性问题，**强烈建议升级至 iOS 14.5+**；支持 iOS 17.x/iOS 18.x，但需电脑辅助配置，详情见 [官方JIT指南](https://wiki.angelauramc.dev/wiki/faq/ios/JIT.html#what-are-the-methods-to-enable-jit);支持 iOS 26.x(源码里称其为iOS 19.x)，但是并没有对其进行特殊适配,可能会出现不可预测的问题。


### 🔧 侧载（Sideload）准备
优先选择支持「永久签名+自动JIT」的工具，按优先级推荐：
1. **TrollStore**（首选）：支持永久签名、自动启用 JIT、提升内存限制，适配部分 iOS 版本，下载见 [官方仓库](https://github.com/opa334/TrollStore)
2. **AltStore/SideStore**（替代）：需定期重签名，首次设置需电脑/Wi-Fi；不支持「分发证书签名服务」，仅兼容「开发证书」（需包含 `com.apple.security.get-task-allow` 权限以启用JIT）

> ⚠️ 安全提示：仅从官方/可信来源下载侧载工具及 IPA；非官方软件导致的设备问题，本人不承担责任；越狱设备虽支持永久签名，但不建议越狱日常设备。


### 📥 安装步骤
#### 1. 正式版（TrollStore 渠道）
1. 前往 [Releases](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/releases) 下载 TIPA 安装包
2. 通过系统「分享菜单」，选择用 TrollStore 打开，自动完成安装

#### 2. 正式版（AltStore/SideStore 渠道）
1. 前往 [Releases](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/releases) 下载 IPA 安装包
2. (正常的安装步骤)

#### 3. Nightly 测试版（每日构建）
> 🔴 风险提示：测试版可能包含崩溃、无法启动等严重漏洞，仅用于开发测试！
1. 前往 [GitHub Actions 标签页](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/actions) 下载最新 IPA 测试包
2. 在侧载工具（AltStore/SideStore 等）中导入 IPA 完成安装


### ⚡ 启用 JIT（必做！）
JIT（Just-In-Time）是流畅运行游戏的核心，iOS 需通过以下工具启用，按自身环境选择：

| 工具         | 需外部设备 | 需 Wi-Fi | 自动启用 | 备注                     |
|--------------|------------|----------|----------|--------------------------|
| TrollStore   | ❌         | ❌       | ✅       | 首选，无需额外操作       |
| AltStore     | ✅         | ✅       | ✅       | 需本地网络运行 AltServer |
| SideStore    | ✅（首次） | ✅（首次）| ❌       | 后续使用无需设备/网络    |
| StikDebug    | ✅（首次） | ✅（首次）| ✅       | 后续使用无需设备/网络    |
| Jitterbug    | ✅（VPN不可用时） | ✅ | ❌ | 需手动触发               |
| 已越狱设备   | ❌         | ❌       | ✅       | 系统级自动支持           |


## 🙏 贡献者
- @LanRhyme - ShardLauncher作者，更改News代码以允许iOS 26用户使用启动器
- @WeiErLiTeo - 为启动器添加Mod下载功能


## 📦 第三方组件及许可证
| 组件名称               | 用途                     | 许可证类型               | 项目链接                                                                 |
|------------------------|--------------------------|--------------------------|--------------------------------------------------------------------------|
| Caciocavallo           | 基础运行框架             | GNU GPLv2                | [GitHub](https://github.com/PojavLauncherTeam/caciocavallo)              |
| jsr305                 | 代码注解支持             | BSD 3-Clause             | [Google Code](https://code.google.com/p/jsr-305)                         |
| Boardwalk              | 核心功能适配             | Apache 2.0               | [GitHub](https://github.com/zhuowei/Boardwalk)                            |
| GL4ES                  | 图形渲染适配             | MIT                      | [GitHub](https://github.com/ptitSeb/gl4es)                                |
| Mesa 3D 图形库         | 3D图形渲染核心            | MIT                      | [GitLab](https://gitlab.freedesktop.org/mesa/mesa)                        |
| MetalANGLE             | Metal 图形接口适配        | BSD 2.0                  | [GitHub](https://github.com/khanhduytran0/metalangle)                     |
| MoltenVK               | Vulkan 接口转译          | Apache 2.0               | [GitHub](https://github.com/KhronosGroup/MoltenVK)                        |
| openal-soft            | 音频处理                 | LGPLv2                   | [GitHub](https://github.com/kcat/openal-soft)                            |
| Azul Zulu JDK          | Java 运行环境            | GNU GPLv2                | [官网](https://www.azul.com/downloads/?package=jdk)                       |
| LWJGL3                 | Java 游戏接口            | BSD-3                    | [GitHub](https://github.com/PojavLauncherTeam/lwjgl3)                     |
| LWJGLX                 | LWJGL2 兼容层            | 许可证未知               | [GitHub](https://github.com/PojavLauncherTeam/lwjglx)                     |
| DBNumberedSlider       | 界面滑动控件             | Apache 2.0               | [GitHub](https://github.com/khanhduytran0/DBNumberedSlider)               |
| fishhook               | 动态链接库适配           | BSD-3                    | [GitHub](https://github.com/khanhduytran0/fishhook)                       |
| shaderc                | Vulkan 着色器编译        | Apache 2.0               | [GitHub](https://github.com/khanhduytran0/shaderc)                        |
| NRFileManager          | 文件管理工具类           | MPL-2.0                  | [GitHub](https://github.com/mozilla-mobile/firefox-ios)                   |
| AltKit                 | AltStore 适配支持        | -                        | [GitHub](https://github.com/rileytestut/AltKit)                           |
| UnzipKit               | 解压工具                 | BSD-2                    | [GitHub](https://github.com/abbeycode/UnzipKit)                           |
| DyldDeNeuralyzer       | 库验证绕过工具           | -                        | [GitHub](https://github.com/xpn/DyldDeNeuralyzer)                         |
| MobileGlues            | 第三方渲染器             | LGPL-2.1                 | [GitHub](https://github.com/MobileGL-Dev/MobileGlues)                     |
| authlib-injector       | 第三方认证登录支持       | AGPL-3.0                 | [GitHub](https://github.com/yushijinhun/authlib-injector)                 |
> 额外感谢：<br> [MCHeads](https://mc-heads.net) 提供 Minecraft 头像服务; <br> [Modrinth](https://modrinth.com) 提供 Mod 下载服务；<br> [BMCLAPI](https://bmclapidoc.bangbang93.com) 提供 Minecraft 下载服务。


## 捐赠

本人是初中生，平时很少有时间更新启动器，并且我没有mac，每次构建后都必须在实体机上测试，甚至麻烦
如果您觉得这个项目对您有帮助，欢迎通过以下二维码进行捐赠支持，为我回回血：

<img src="/donate.png" width="400" height="400" />
