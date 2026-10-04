<div align="center">
  <img src="Natives/Assets.xcassets/AppIcon-Light.appiconset/1024x1024.png" alt="Air Icon" width="120" style="border-radius: 24px;">
</div>

<h1 align="center">Air</h1>
<p align="center"><sub>Amethyst iOS リマスター版</sub></p>

<div align="center">
  <img alt="Build Status" src="https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/actions/workflows/development.yml/badge.svg?branch=main">
  <img alt="Downloads" src="https://img.shields.io/github/downloads/herbrine8403/Amethyst-iOS-MyRemastered/total?label=Downloads&style=flat">
  <img alt="Release" src="https://img.shields.io/github/v/release/herbrine8403/Amethyst-iOS-MyRemastered?style=flat">
  <img alt="License" src="https://img.shields.io/github/license/herbrine8403/Amethyst-iOS-MyRemastered?style=flat">
  <a title="Crowdin" target="_blank" href="https://crowdin.com/project/amethyst-ios-remastered"><img alt="Crowdin" src="https://badges.crowdin.net/amethyst-ios-remastered/localized.svg">
</div>

<p align="center">
  <a href="./README.md">English</a> | <a href="./README_CN.md">Chinese</a> | <a href="./README_JA.md">Japanese</a>
</p>

> [!IMPORTANT]
> **これは唯一の公式 Air リポジトリです：** [herbrine8403/Amethyst-iOS-MyRemastered](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered)。
> 「Air」という名前を使用する非公式のフォークやミラーリポジトリには注意してください。常にリポジトリの所有者が [@herbrine8403](https://github.com/herbrine8403) であることを確認し、URL が上記のリンクと一致していることを確認してください。

---

A premium Minecraft: Java Edition launcher for iOS and iPadOS, rebuilt from the ground up on the official Amethyst project. It delivers a refined mobile experience with comprehensive mod management, intelligent renderer selection, and deep platform integration.

---

## 目次

- [コア機能](#core-features)
- [クイックスタート](#quick-start)
  - [デバイス要件](#device-requirements)
  - [サideload準備](#sideload-preparation)
  - [インストール](#installation)
  - [JITの有効化](#enabling-jit)
- [貢献者](#contributors)
- [サードパーティコンポーネント](#third-party-components)
- [スポンサー](#sponsor)

## コア機能

- **モダンUIデザイン** -- インターフェイスは現代的で洗練された視覚スタイルに深く洗練されています。
- **リソース管理とダウンロード** -- Mod、シェーダーパック、リソースパック、その他のアセットを閲覧、有効化、無効化、削除し、ModrinthとCurseForgeのダウンロードサポートを統合します。
- **Modpack インポート** -- ZIP形式のModpackをランチャーインターフェースから直接インポートします。
- **スマートダウンロードソース** -- 最適なダウンロード速度のために、Mojang公式、BMCLAPIミラー、その他のソースの間をその場で切り替えます。
- **完全な日本語ローカライズ** -- インターフェースはネイティブ品質の日本語言語サポートで完全に翻訳されています。
- **制限のないアカウント** -- ローカルアカウント、デモモード、およびサードパーティ認証すべてサポート；Microsoftアカウントはダウンロードとプレイに必要ありません。
- **マルチアカウント** -- Microsoft、ローカル、およびサードパーティ認証アカウント間をシームレスに切り替えます。
- **自動レンダラー選択** -- Autoに設定されている場合、最適なレンダリングバックエンド（MobileGlues、MoltenVKなど）を自動的に選択します。
- **自動JVM選択** -- ゲームバージョンに基づいて正しいJVMバージョン（Java 8、17、21、または25）を自動的に選択します。
- **Minecraft 26.X サポート** -- Minecraft 26.xの実験的サポート。
- **カスタムマウスポインター** -- 設定で仮想マウスポインターのスキンをカスタマイズします。
- **カスタムニュースURL** -- ランチャーホームスクリーン用のカスタムニュースフィードURLを設定します。
- **TouchControllerサポート** -- UDPローカルプロキシとXCFrameworkの両方を介してTouchControllerモッドと通信し、iOSで完全なタッチスクリーンコントロールを提供します。
- **AI統合** -- （開発中）目標は、ランチャーのリソースダウンロードとインスタンス管理を含むランチャーを完全に管理するAIを有効にすることです。
- **カスタムアプリアイコン** -- （開発中）

そしてさらに多くの探索ポイントがあります！

> [!NOTE]
> このリマスター版をAndroidに移植する計画はありません。Androidエコシステムには、[Zalith Launcher](https://github.com/ZalithLauncher/ZalithLauncher)、[Fold Craft Launcher](https://github.com/FCL-Team/FoldCraftLauncher)、[ShardLauncher](https://github.com/ShardLauncher/ShardLauncher)などの優れたランチャーが既に存在します。公式のAndroidバージョンについては、[Amethyst-Android](https://github.com/AngelAuraMC/Amethyst-Android)をご覧ください。

## クイックスタート

完全なドキュメントについては、[Amethyst公式Wiki](https://wiki.angelauramc.dev/wiki/getting_started/INSTALL.html#ios)または[Bilibiliチュートリアル](https://b23.tv/KyxZr12)を参照してください。以下は condensated ガイドです。

### デバイス要件

| 層 | iOSバージョン | サポートされているデバイス |
|------|-------------|-------------------|
| **最小** | iOS 14.0+ | iPhone 6s+、iPad 5th gen+、iPad Air 2+、iPad mini 4+、すべてのiPad Pro、iPod touch 7th gen |
| **推奨** | iOS 14.5+ | iPhone XS+（XR/SE 2nd genを除く）、iPad 10th gen+、iPad Air 4th gen+、iPad mini 6th gen+、iPad Pro（9.7インチを除く） |

> [!CAUTION]
> iOS 14.0--14.4.2 には既知の重大な互換性問題があります。**iOS 14.5 以降へのアップグレードを強くお勧めします。** iOS 17.x と 18.x はサポートされていますが、初期の JIT 設定のためにコンピュータが必要です（[公式 JIT ガイド](https://wiki.angelauramc.dev/wiki/faq/ios/JIT.html#what-are-the-methods-to-enable-jit) を参照）。iOS 26.x はインストール可能ですが、専用の適応は行われていないため、予測不能な動作が発生する可能性があります。

### Sideload準備

永続署名と自動JIT有効化をサポートするツールを優先してください：

1. **TrollStore** *(推奨)* -- 永久署名、自動JIT、メモリ制限の増加。特定のiOSバージョンと互換性があります。[公式リポジトリからダウンロード](https://github.com/opa334/TrollStore)
2. **AltStore / SideStore** *(代替)* -- 定期的な再署名が必要；初期設定にはコンピュータとWi-Fiが必要です。開発証明書のみと互換性があります（JITのために `com.apple.security.get-task-allow` エンタイトルメントを含む必要があります）。配布証明書署名サービスはサポートされません。

> [!WARNING]
> サideloadingツールとIPAファイルは、公式または信頼できるソースからのみダウンロードしてください。非公式ソフトウェアによるデバイスの問題については、作者は責任を負いません。ジャイルブレイクされたデバイスは永久署名をサポートしますが、日常使用のためのジャイルブレイクはお勧めしません。

### インストール

<details>
<summary><b>正式リリース (TrollStore)</b></summary>

1. [Releases](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/releases) から `.tipa` パッケージをダウンロードします。
2. システムの共有メニューを通じて TrollStore でファイルを開き、インストールを完了します。
</details>

<details>
<summary><b>正式リリース (AltStore / SideStore)</b></summary>

1. [Releases](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/releases) から `.ipa` パッケージをダウンロードします。
2. サideloading ツールの標準的な手順に従って IPA をインポートします。
</details>

<details>
<summary><b>Nightly Builds (開発テスト)</b></summary>

> [!CAUTION]
> Nightly builds にはクラッシュや起動失敗などの重大なバグが含まれる可能性があります。開発とテスト目的のみで使用してください。

1. [GitHub Actions](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/actions) ページに移動し、最新の IPA アーティファクトをダウンロードします。
2. AltStore、SideStoreなどのサideloading ツールに IPA をインポートしてインストールします。
</details>

### JITの有効化

JIT (Just-In-Time コンパイル) はスムーズなゲームプレイのために不可欠です。環境に合ったアプローチを選択してください：

| ツール | 外部デバイス | Wi-Fi 必要 | 自動有効化 | 備考 |
|------|:---:|:---:|:---:|-------|
| TrollStore | なし | なし | はい | 推奨；追加の操作は不要 |
| AltStore | あり | あり | はい | ローカルネットワークで AltServer が実行されている必要があります |
| SideStore | 初回のみ | 初回のみ | いいえ | 初期設定後はデバイス/ネットワークフリー |
| StikDebug | 初回のみ | 初回のみ | はい | 初期設定後はデバイス/ネットワークフリー |
| Jitterbug | はい（VPNなし） | はい | いいえ | 手動トリガーが必要 |
| Jailbroken | なし | なし | はい | システムレベルの自動サポート |

## 貢献者

- [@yitenchen123](https://github.com/yitenchen123) -- プロジェクトメンテナー
- [@EternityQwQ](https://github.com/EternityQwQ) -- Metal ユニバーサル MOD サポートを追加し、ランチャーが Minecraft のレンダリングに Metal を使用できるようにしました
- [@LanRhyme](https://github.com/LanRhyme) -- ShardLauncher の作者；iOS 26 互換性とログ改善
- [@WeiErLiTeo](https://github.com/WeiErLiTeo) -- Mod ダウンロード統合、TouchController 最適化、および二本指長押しキーボードトリガー
- [@Li2548](https://github.com/Li2548) -- アップストリーム同期
- [@Gsjsjzhznsz](https://github.com/Gsjsjzhznsz) -- SDL3 プレゼンテーション適応、Minecraft 26.3 ブラックスクリーン (FBO0 heal blit) および自己回復解像度の修正、MobileGlues デッドロック修正、Zink OpenGL ブリッジ

## サードパーティコンポーネント

| コンポーネント | 目的 | ライセンス | ソース |
|-----------|---------|---------|--------|
| Caciocavallo | AWT ランタイムフレームワーク | GPL-2.0 | [GitHub](https://github.com/PojavLauncherTeam/caciocavallo) |
| jsr305 | コードアノテーションサポート | BSD-3 | [Google Code](https://code.google.com/p/jsr-305) |
| Boardwalk | コア機能適応 | Apache-2.0 | [GitHub](https://github.com/zhuowei/Boardwalk) |
| GL4ES | OpenGL-to-GLES 翻訳 | MIT | [GitHub](https://github.com/ptitSeb/gl4es) |
| Mesa 3D | 3D グラフィックスライブラリ | MIT | [GitLab](https://gitlab.freedesktop.org/mesa/mesa) |
| MetalANGLE | Metal-to-OpenGL ES 翻訳 | BSD-2 | [GitHub](https://github.com/khanhduytran0/metalangle) |
| MoltenVK | Vulkan-to-Metal 翻訳 | Apache-2.0 | [GitHub](https://github.com/KhronosGroup/MoltenVK) |
| openal-soft | クロスプラットフォーム 3D オーディオ | LGPL-2.0 | [GitHub](https://github.com/kcat/openal-soft) |
| Azul Zulu JDK | Java ランタイム (8/17/21/25) | GPL-2.0 | [Website](https://www.azul.com/downloads/?package=jdk) |
| LWJGL3 | Java ゲーム開発ライブラリ | BSD-3 | [GitHub](https://github.com/PojavLauncherTeam/lwjgl3) |
| LWJGLX | LWJGL2 互換性レイヤー | -- | [GitHub](https://github.com/PojavLauncherTeam/lwjglx) |
| DBNumberedSlider | UI スライダー コントロール | Apache-2.0 | [GitHub](https://github.com/khanhduytran0/DBNumberedSlider) |
| fishhook | 動的ライブラリ再結合 | BSD-3 | [GitHub](https://github.com/khanhduytran0/fishhook) |
| shaderc | Vulkan シェーダー コンパイル | Apache-2.0 | [GitHub](https://github.com/khanhduytran0/shaderc) |
| NRFileManager | ファイル管理ユーティリティ | MPL-2.0 | [GitHub](https://github.com/mozilla-mobile/firefox-ios) |
| AltKit | AltStore 統合 | -- | [GitHub](https://github.com/rileytestut/AltKit) |
| UnzipKit | ZIP アーカイブ処理 | BSD-2 | [GitHub](https://github.com/abbeycode/UnzipKit) |
| DyldDeNeuralyzer | ライブラリ検証バイパス | -- | [GitHub](https://github.com/xpn/DyldDeNeuralyzer) |
| MobileGlues | サードパーティレンダラー | LGPL-2.1 | [GitHub](https://github.com/MobileGL-Dev/MobileGlues) |
| LTW | OpenGL Core-to-ES ラッパー | LGPL-3.0 | [GitHub](https://github.com/MojoLauncher/LTW) |
| authlib-injector | サードパーティ認証 | AGPL-3.0 | [GitHub](https://github.com/yushijinhun/authlib-injector) |

さらに、Minecraft アバター サービスの [MCHeads](https://mc-heads.net)、Mod 配布の [Modrinth](https://modrinth.com)、および Minecraft ダウンロード ミラーリングの [BMCLAPI](https://bmclapidoc.bangbang93.com) に感謝します。

## スポンサー

このプロジェクトが貴重だと感じた場合は、[Ko-Fi](https://ko-fi.com/herbrine8403)、[Afdian](https://afdian.com/a/herbrine8403)、または [WeChat Reward Code](donate.png) を通じて開発をサポートすることをご検討ください。

## Star History

<a href="https://www.star-history.com/?type=date&repos=herbrine8403%2FAmethyst-iOS-MyRemastered">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=herbrine8403/Amethyst-iOS-MyRemastered&type=date&theme=dark&legend=top-left&sealed_token=q1uFKbS7fO8owrcjy_kYTkCnnl8PNgHAgBSrWop8Y3ULDdvwOwDfORslSVVXABSTwrsdu14OM3fshRaNbXouxMU5IenXF0T5r5L6rxKIN2n29T6Fv4UYyA" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=herbrine8403/Amethyst-iOS-MyRemastered&type=date&legend=top-left&sealed_token=q1uFKbS7fO8owrcjy_kYTkCnnl8PNgHAgBSrWop8Y3ULDdvwOwDfORslSVVXABSTwrsdu14OM3fshRaNbXouxMU5IenXF0T5r5L6rxKIN2n29T6Fv4UYyA" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=herbrine8403/Amethyst-iOS-MyRemastered&type=date&legend=top-left&sealed_token=q1uFKbS7fO8owrcjy_kYTkCnnl8PNgHAgBSrWop8Y3ULDdvwOwDfORslSVVXABSTwrsdu14OM3fshRaNbXouxMU5IenXF0T5r5L6rxKIN2n29T6Fv4UYyA" />
 </picture>
</a>