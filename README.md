# Air-Metal (Amethyst iOS Remastered + Metal Universal)

**本 fork 基于官方 [Amethyst-iOS-MyRemastered](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered) `48a0202`,集成 Metal Universal 原生 Metal 渲染(Minecraft **26.2**,vanilla / Fabric / Forge 三形态实测可玩)。**

## 改版内容

1. **启动器渲染器新增 "Metal (metallum)" 选项**(设置 → 游戏设置 → 渲染器)
   - `Natives/utils.h` / `Natives/LauncherPreferences.m`: 渲染器列表加 Metal
   - `Natives/JavaLauncher.m`: 选 Metal 时设 `AMETHYST_METAL=1`,EGL 渲染器回落 auto 提供 surface;选择该渲染器时弹出一次性注意事项(已知限制)
2. **Metallum agent 注入(`-javaagent:metallum_agent.jar`)**
   - premain 提前加载完整版 libspvc + `ensureSpvcLibraryConfigured`(防止 MoltenVK 阉割版符号 → -4)
   - ASM 注入 `PreferredGraphicsApi.getBackendsToTry` → 返回 `[Metal, Vulkan, GL]`
   - Fabric/Quilt 实例自动跳过 agent(避免与 fabric-loader 的 classpath 校验冲突),改由预置的 Metal mod 接管
   - Forge 兼容: `ForgeLoadingOverlay.<init>` 注入(GOTO 跳过 logo 纹理强转)—— Forge 自带加载界面会被跳过,直接进入主菜单,属预期行为
3. **预置 Metal 渲染 mod**
   - bundle 内 `mods_preload/MetalUniversal-1.0.4.jar` 首次启动拷入实例 `mods/`(仅 Metal mod 自动预置,其他 mod 不受影响)
   - Fabric/Quilt 实例自动生效(vanilla / Forge 不加载该 mod,无害)
4. **Forge 模块冲突修复**: `com.apple.ios.audio` 从 `libs/lwjgl.jar` 移除(仅保留在 `launcher.jar`),修复 Forge 26.2 的 JPMS 双模块导出 `ResolutionException`

## 支持矩阵(渲染后端 = Metal)

| MC 版本 | vanilla | Fabric/Quilt | Forge |
|---------|---------|--------------|-------|
| **26.2** | ✅ 实测可玩 | ✅ 实测可玩 | ✅ 实测可玩 |

## 已知限制

- 光影包(Iris / OptiFine 风格)不支持(Metal 路径与 GL 架构差异)
- 部分 mod 可能不兼容(如 Sodium 等性能优化 mod);游戏崩溃时先移除 mod 再试
- Forge 实例的启动遮罩偶需手动关闭(听到音乐即已进入游戏);Forge 自带加载界面会被跳过
- 首次选择 Metal 渲染器时,启动器会弹出一次性注意事项说明上述限制
- 后端由 `metallum` 提供(上游 [MetalUniversal](https://github.com/EternityQwQ/MetalUniversal));shader 经 SPIRV-Cross 交叉编译至 Metal

## 使用

- 安装后: 启动器 → 游戏设置 → 渲染器 → **Metal (metallum)**
- JIT: StikDebug 附加 + 调试设置两个开关(Use Universal StikDebug Script / Keep attached to StikDebug)
- 实测环境: iPhone 17 Pro (A19 Pro) / iOS 27.0
- 详细说明见 `METAL_TUTORIAL.txt`

## 构建

```bash
# 研究机(Xcode 26.3): pip 装 cmake + gmake 软链 + BOOTJDK=JDK8, 然后
cd Natives && cmake .. && make
```

---

<div align="center">
  <img src="Natives/Assets.xcassets/AppIcon-Light.appiconset/1024x1024.png" alt="Air Icon" width="120" style="border-radius: 24px;">
</div>

<h1 align="center">Air</h1>
<p align="center"><sub>Amethyst iOS Remastered</sub></p>

<div align="center">
  <img alt="Build Status" src="https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/actions/workflows/development.yml/badge.svg?branch=main">
  <img alt="Downloads" src="https://img.shields.io/github/downloads/herbrine8403/Amethyst-iOS-MyRemastered/total?label=Downloads&style=flat">
  <img alt="Release" src="https://img.shields.io/github/v/release/herbrine8403/Amethyst-iOS-MyRemastered?style=flat">
  <img alt="License" src="https://img.shields.io/github/license/herbrine8403/Amethyst-iOS-MyRemastered?style=flat">
  <a title="Crowdin" target="_blank" href="https://crowdin.com/project/amethyst-ios-remastered"><img alt="Crowdin" src="https://badges.crowdin.net/amethyst-ios-remastered/localized.svg">
</div>

<p align="center">
  <a href="./README.md">English</a> | <a href="./README_CN.md">Chinese</a>
</p>

---

A premium Minecraft: Java Edition launcher for iOS and iPadOS, rebuilt from the ground up on the official Amethyst project. It delivers a refined mobile experience with comprehensive mod management, intelligent renderer selection, and deep platform integration.

---

## Table of Contents

- [Core Features](#core-features)
- [Quick Start](#quick-start)
  - [Device Requirements](#device-requirements)
  - [Sideload Preparation](#sideload-preparation)
  - [Installation](#installation)
  - [Enabling JIT](#enabling-jit)
- [Contributors](#contributors)
- [Third-Party Components](#third-party-components)
- [Sponsor](#sponsor)

## Core Features

- **Modern UI Redesign** -- The interface has been deeply refined for a contemporary, polished visual style.
- **Resource Management & Downloads** -- Browse, enable, disable, and delete mods, shader packs, resource packs, and other assets, with integrated Modrinth and CurseForge download support.
- **Modpack Import** -- Import ZIP-format modpacks directly from the launcher interface.
- **Smart Download Sources** -- Switch between Mojang Official, BMCLAPI mirror, and other sources on the fly for optimal download speeds.
- **Complete Chinese Localization** -- Fully translated interface with native-quality Chinese language support.
- **Unrestricted Accounts** -- Local accounts, demo mode, and third-party authentication all supported; no Microsoft account required to download and play.
- **Multi-Account** -- Seamlessly switch between Microsoft, local, and third-party authentication accounts.
- **Auto Renderer Selection** -- Automatically chooses the optimal rendering backend (including MobileGlues, MoltenVK, and more) when set to Auto.
- **Auto JVM Selection** -- Automatically selects the correct JVM version (Java 8, 17, 21, or 25) based on the game version.
- **Minecraft 26.X Support** -- Experimental support for Minecraft 26.x.
- **Custom Mouse Pointer** -- Customize the virtual mouse pointer skin in settings.
- **Custom News URL** -- Configure a custom news feed URL for the launcher home screen.
- **TouchController Support** -- Communicates with the TouchController mod via both UDP local proxy and XCFramework, delivering full touchscreen control on iOS.
- **AI Integration** -- (In development) The goal is to enable AI to fully manage the launcher, including resource downloads and instance management.
- **Custom App Icons** -- (In development)

... and much more to explore!

> [!NOTE]
> There are no plans to port this remastered version to Android. The Android ecosystem already has excellent launchers such as [Zalith Launcher](https://github.com/ZalithLauncher/ZalithLauncher), [Fold Craft Launcher](https://github.com/FCL-Team/FoldCraftLauncher), and ShardLauncher. For the official Android version, visit [Amethyst-Android](https://github.com/AngelAuraMC/Amethyst-Android).

## Quick Start

For complete documentation, refer to the [Amethyst Official Wiki](https://wiki.angelauramc.dev/wiki/getting_started/INSTALL.html#ios) or the [Bilibili tutorial](https://b23.tv/KyxZr12). Below is a condensed guide.

### Device Requirements

| Tier | iOS Version | Supported Devices |
|------|-------------|-------------------|
| **Minimum** | iOS 14.0+ | iPhone 6s+, iPad 5th gen+, iPad Air 2+, iPad mini 4+, all iPad Pro, iPod touch 7th gen |
| **Recommended** | iOS 14.5+ | iPhone XS+ (excl. XR/SE 2nd gen), iPad 10th gen+, iPad Air 4th gen+, iPad mini 6th gen+, iPad Pro (excl. 9.7-inch) |

> [!CAUTION]
> iOS 14.0--14.4.2 has known critical compatibility issues. **Upgrading to iOS 14.5 or later is strongly recommended.** iOS 17.x and 18.x are supported but require a companion computer for initial JIT configuration (see the [Official JIT Guide](https://wiki.angelauramc.dev/wiki/faq/ios/JIT.html#what-are-the-methods-to-enable-jit)). iOS 26.x is installable but has not undergone dedicated adaptation; expect unpredictable behavior.

### Sideload Preparation

Prioritize tools that support permanent signing and automatic JIT enablement:

1. **TrollStore** *(Recommended)* -- Permanent signing, automatic JIT, increased memory limits. Compatible with select iOS versions. [Download from official repo](https://github.com/opa334/TrollStore)
2. **AltStore / SideStore** *(Alternative)* -- Requires periodic re-signing; initial setup needs a computer and Wi-Fi. Only compatible with **development certificates** (must include `com.apple.security.get-task-allow` entitlement for JIT). Distribution certificate signing services are not supported.

> [!WARNING]
> Only download sideloading tools and IPA files from official or trusted sources. The author is not responsible for device issues caused by unofficial software. Jailbroken devices support permanent signing, but daily-driver jailbreaking is not recommended.

### Installation

<details>
<summary><b>Official Release (TrollStore)</b></summary>

1. Download the `.tipa` package from [Releases](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/releases).
2. Open the file with TrollStore via the system share menu to complete installation.
</details>

<details>
<summary><b>Official Release (AltStore / SideStore)</b></summary>

1. Download the `.ipa` package from [Releases](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/releases).
2. Import the IPA into your sideloading tool following its standard installation procedure.
</details>

<details>
<summary><b>Nightly Builds (Development Testing)</b></summary>

> [!CAUTION]
> Nightly builds may contain critical bugs including crashes and startup failures. Use only for development and testing purposes.

1. Navigate to the [GitHub Actions](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/actions) page and download the latest IPA artifact.
2. Import the IPA into your sideloading tool (AltStore, SideStore, etc.) to install.
</details>

### Enabling JIT

JIT (Just-In-Time compilation) is essential for smooth gameplay. Choose the approach that matches your environment:

| Tool | External Device | Wi-Fi Required | Auto-Enable | Notes |
|------|:---:|:---:|:---:|-------|
| TrollStore | No | No | Yes | Preferred; no additional action needed |
| AltStore | Yes | Yes | Yes | Requires AltServer running on local network |
| SideStore | First time only | First time only | No | Device/network-free after initial setup |
| StikDebug | First time only | First time only | Yes | Device/network-free after initial setup |
| Jitterbug | Yes (without VPN) | Yes | No | Manual trigger required |
| Jailbroken | No | No | Yes | System-level automatic support |

## Contributors

- [@yitenchen123](https://github.com/yitenchen123) -- Project Maintainer
- [@EternityQwQ](https://github.com/EternityQwQ) -- Add Metal Universal Mod support, allowing the launcher to use Metal for rendering Minecraft
- [@LanRhyme](https://github.com/LanRhyme) -- ShardLauncher author; iOS 26 compatibility and logging improvements
- [@WeiErLiTeo](https://github.com/WeiErLiTeo) -- Mod download integration, TouchController optimizations, and two-finger long-press keyboard trigger
- [@Li2548](https://github.com/Li2548) -- Upstream synchronization

## About Translations

If you would like to contribute translations for this project, please go to [Crowdin](https://crowdin.com/project/amethyst-ios-remastered).

## Third-Party Components

| Component | Purpose | License | Source |
|-----------|---------|---------|--------|
| Caciocavallo | AWT runtime framework | GPL-2.0 | [GitHub](https://github.com/PojavLauncherTeam/caciocavallo) |
| jsr305 | Code annotation support | BSD-3 | [Google Code](https://code.google.com/p/jsr-305) |
| Boardwalk | Core functionality adaptation | Apache-2.0 | [GitHub](https://github.com/zhuowei/Boardwalk) |
| GL4ES | OpenGL-to-GLES translation | MIT | [GitHub](https://github.com/ptitSeb/gl4es) |
| Mesa 3D | 3D graphics library | MIT | [GitLab](https://gitlab.freedesktop.org/mesa/mesa) |
| MetalANGLE | Metal-to-OpenGL ES translation | BSD-2 | [GitHub](https://github.com/khanhduytran0/metalangle) |
| MoltenVK | Vulkan-to-Metal translation | Apache-2.0 | [GitHub](https://github.com/KhronosGroup/MoltenVK) |
| openal-soft | Cross-platform 3D audio | LGPL-2.0 | [GitHub](https://github.com/kcat/openal-soft) |
| Azul Zulu JDK | Java runtime (8/17/21/25) | GPL-2.0 | [Website](https://www.azul.com/downloads/?package=jdk) |
| LWJGL3 | Java game development library | BSD-3 | [GitHub](https://github.com/PojavLauncherTeam/lwjgl3) |
| LWJGLX | LWJGL2 compatibility layer | -- | [GitHub](https://github.com/PojavLauncherTeam/lwjglx) |
| DBNumberedSlider | UI slider control | Apache-2.0 | [GitHub](https://github.com/khanhduytran0/DBNumberedSlider) |
| fishhook | Dynamic library rebinding | BSD-3 | [GitHub](https://github.com/khanhduytran0/fishhook) |
| shaderc | Vulkan shader compilation | Apache-2.0 | [GitHub](https://github.com/khanhduytran0/shaderc) |
| NRFileManager | File management utilities | MPL-2.0 | [GitHub](https://github.com/mozilla-mobile/firefox-ios) |
| AltKit | AltStore integration | -- | [GitHub](https://github.com/rileytestut/AltKit) |
| UnzipKit | ZIP archive handling | BSD-2 | [GitHub](https://github.com/abbeycode/UnzipKit) |
| DyldDeNeuralyzer | Library verification bypass | -- | [GitHub](https://github.com/xpn/DyldDeNeuralyzer) |
| MobileGlues | Third-party renderer | LGPL-2.1 | [GitHub](https://github.com/MobileGL-Dev/MobileGlues) |
| LTW | OpenGL Core-to-ES wrapper | LGPL-3.0 | [GitHub](https://github.com/MojoLauncher/LTW) |
| authlib-injector | Third-party authentication | AGPL-3.0 | [GitHub](https://github.com/yushijinhun/authlib-injector) |

Additional thanks to [MCHeads](https://mc-heads.net) for Minecraft avatar services, [Modrinth](https://modrinth.com) for mod distribution, and [BMCLAPI](https://bmclapidoc.bangbang93.com) for Minecraft download mirroring.

## Sponsor

If you find this project valuable, consider supporting development through [Ko-Fi](https://ko-fi.com/herbrine8403), [Afdian](https://afdian.com/a/herbrine8403), or [WeChat Reward Code](donate.png).

## Star History

<a href="https://www.star-history.com/?type=date&repos=herbrine8403%2FAmethyst-iOS-MyRemastered">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=herbrine8403/Amethyst-iOS-MyRemastered&type=date&theme=dark&legend=top-left&sealed_token=q1uFKbS7fO8owrcjy_kYTkCnnl8PNgHAgBSrWop8Y3ULDdvwOwDfORslSVVXABSTwrsdu14OM3fshRaNbXouxMU5IenXF0T5r5L6rxKIN2n29T6Fv4UYyA" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=herbrine8403/Amethyst-iOS-MyRemastered&type=date&legend=top-left&sealed_token=q1uFKbS7fO8owrcjy_kYTkCnnl8PNgHAgBSrWop8Y3ULDdvwOwDfORslSVVXABSTwrsdu14OM3fshRaNbXouxMU5IenXF0T5r5L6rxKIN2n29T6Fv4UYyA" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=herbrine8403/Amethyst-iOS-MyRemastered&type=date&legend=top-left&sealed_token=q1uFKbS7fO8owrcjy_kYTkCnnl8PNgHAgBSrWop8Y3ULDdvwOwDfORslSVVXABSTwrsdu14OM3fshRaNbXouxMU5IenXF0T5r5L6rxKIN2n29T6Fv4UYyA" />
 </picture>
</a>
