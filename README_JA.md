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
> **これはAirの唯一の公式リポジトリです:** [herbrine8403/Amethyst-iOS-MyRemastered](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered)。
> "Air"という名前を使用する非公式のフォークやミラーリポジトリには注意してください。リポジトリの所有者が[@herbrine8403](https://github.com/herbrine8403)であることを確認し、URLが上記のリンクと一致していることを確認してください。

---

プレミアムなMinecraft: Java Edition用iOSおよびiPadOSランチャーで、公式Amethystプロジェクトを基にゼロから再構築されています。包括的なMod管理、インテリジェントなレンダラー選択、そして深いプラットフォーム統合により、洗練されたモバイル体験を提供します。

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

- **UIのモダンな redesign** -- インターフェースは現代的で洗練された視覚スタイルのために深く改良されています。
- **リソース管理とダウンロード** -- Mod、シェーダーパック、リソースパック、その他のアセットを参照、有効/無効、削除し、ModrinthとCurseForgeからのダウンロードサポートを統合。
- **Modpackインポート** -- ZIP形式のModpackをランチャーインターフェースから直接インポート。
- **スマートダウンロードソース** -- Mojang公式、BMCLAPIミラー、その他のソース間を切り替えて最適なダウンロード速度を実現。
- **完全な中国語ローカライズ** -- インターフェースを完全に日本語に訳し、ネイティブ品質の日本語言語サポートを提供。
- **制限のないアカウント** -- ローカルアカウント、デモモード、サードパーティ認証をすべてサポートし、マイクロソフトアカウントは必要ありません。
- **マルチアカウント** -- マイクロソフト、ローカル、サードパーティ認証アカウント間をシームレスに切り替え可能。
- **自動レンダラー選択** -- Autoに設定されている場合、MobileGlues、MoltenVKなどを含む最適なレンダリングバックエンドを自動的に選択。
- **自動JVM選択** -- ゲームバージョンに基づいてJava 8、17、21、または25の正しいJVMバージョンを自動的に選択。
- **Minecraft 26.Xサポート** -- Minecraft 26.xの実験的サポート。
- **カスタムマウスポインタ** -- 設定で仮想マウスポインタのスキンをカスタマイズ可能。
- **カスタムニュースURL** -- ランチャーホームスクリーンのカスタムニュースフィードURLを設定可能。
- **TouchControllerサポート** -- TouchController modとUDPローカルプロキシおよびXCFrameworkを介して通信し、iOSでフルタッチスクリーンコントロールを提供。
- **AI統合** -- （開発中）AIがランチャーを完全に管理し、リソースダウンロードとインスタンス管理を行うことを目指しています。
- **カスタムアプリアイコン** -- （開発中）

そしてさらに多くの機能を探求できます！

> [!NOTE]
> このリマスター版をAndroidに移植する予定はありません。Androidエコシステムには[Zalith Launcher](https://github.com/ZalithLauncher/ZalithLauncher)、[Fold Craft Launcher](https://github.com/FCL-Team/FoldCraftLauncher)、ShardLauncherなど優れたランチャーが既に存在します。公式のAndroidバージョンについては[Amethyst-Android](https://github.com/AngelAuraMC/Amethyst-Android)をご覧ください。

## クイックスタート

完全なドキュメントについては、[Amethyst Official Wiki](https://wiki.angelauramc.dev/wiki/getting_started/INSTALL.html#ios)または[Bilibiliチュートリアル](https://b23.tv/KyxZr12)を参照してください。以下は簡易ガイドです。

### デバイス要件

| Tier | iOS Version | サポートデバイス |
|------|-------------|------------------|
| **最低** | iOS 14.0+ | iPhone 6s+, iPad 5th gen+, iPad Air 2+, iPad mini 4+, すべてのiPad Pro, iPod touch 7th gen |
| **推奨** | iOS 14.5+ | iPhone XS+ (XR/SE 2nd genを除く)、iPad 10th gen+, iPad Air 4th gen+, iPad mini 6th gen+, iPad Pro (9.7インチを除く) |

> [!CAUTION]
> iOS 14.0--14.4.2には既知の重大な互換性問題があります。**iOS 14.5以降へのアップグレードを強く推奨します。** iOS 17.xと18.xはサポートされていますが、初期JIT設定にはコンピュータが必要です（[公式JITガイド](https://wiki.angelauramc.dev/wiki/faq/ios/JIT.html#what-are-the-methods-to-enable-jit)を参照）。iOS 26.xはインストール可能ですが、専用の適応は行われていないため、予測不能な動作が発生する可能性があります。

### Sideload準備

永久署名と自動JIT有効化をサポートするツールを優先してください：

1. **TrollStore** *(推奨)* -- 永久署名、自動JIT、メモリ制限の増加。特定のiOSバージョンと互換性があります。[公式リポジトリからダウンロード](https://github.com/opa334/TrollStore)。
2. **AltStore / SideStore** *(代替)* -- 定期的な再署名が必要で、初期設定にはコンピュータとWi-Fiが必要です。ただし、**開発証明書**（`com.apple.security.get-task-allow`エンタイトルメントを含む必要がある）のみをサポートします。配信証明書による署名サービスはサポートされません。

> [!WARNING]
> サideloadingツールとIPAファイルは公式または信頼できるソースからのみダウンロードしてください。非公式ソフトウェアによって引き起こされるデバイスの問題については、作者は責任を負いません。ジャイルブレイクされたデバイスは永久署名をサポートしますが、日常的なジャイルブレイクは推奨されません。

### インストール

<details>
<summary><b>公式リリース (TrollStore)</b></summary>

1. [リリース](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/releases)から`.tipa`パッケージをダウンロード。
2. システムの共有メニューを介してTrollStoreでファイルを開き、インストールを完了。

</details>

<details>
<summary><b>公式リリース (AltStore / SideStore)</b></summary>

1. [リリース](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/releases)から`.ipa`パッケージをダウンロード。
2. サideloadingツールの標準手順に従ってIPAをインポート。

</details>

<details>
<summary><b>ナイトリービルド (開発テスト)</b></summary>

> [!CAUTION]
> ナイトリービルドには重大なバグ（クラッシュや起動失敗など）が含まれる可能性があります。開発およびテスト目的のみで使用してください。

1. [GitHub Actions](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/actions)ページに移動し、最新のIPAアーティファクトをダウンロード。
2. サideloadingツール（AltStore、SideStoreなど）にIPAをインポートしてインストール。

</details>

### JITの有効化

JIT（Just-In-Timeコンパイル）はスムーズなゲームプレイに不可欠です。環境に合ったアプローチを選択してください：

| ツール | 外部デバイス | Wi-Fi必要 | 自動有効化 | 備考 |
|------|:---:|:---:|:---:|-------|
| TrollStore | なし | なし | はい | 推奨；追加の操作は不要 |
| AltStore | あり | はい | はい | ローカルネットワークでAltServerを実行する必要あり |
| SideStore | 初回のみ | 初回のみ | いいえ | 初期設定後はデバイス/ネットワークフリー |
| StikDebug | 初回のみ | 初回のみ | はい | 初期設定後はデバイス/ネットワークフリー |
| Jitterbug | あり（VPNなし） | はい | いいえ | 手動トリガーが必要 |
| Jailbroken | なし | なし | はい | システムレベルでの自動サポート |

## 貢献者

- [@yitenchen123](https://github.com/yitenchen123) -- プロジェクトメンテナー
- [@EternityQwQ](https://github.com/EternityQwQ) -- MetalユニバーサルModサポートを追加し、ランチャーがMetalを使用してMinecraftをレンダリング可能に
- [@LanRhyme](https://github.com/LanRhyme) -- ShardLauncherの作者；iOS 26互換性とロギング改善を追加
- [@WeiErLiTeo](https://github.com/WeiErLiTeo) -- Modダウンロード統合、TouchController最適化、および2本指長押しキーボードトリガーを追加
- [@Li2548](https://github.com/Li2548) -- アップストリーム同期
- [@Gsjsjzhznsz](https://github.com/Gsjsjzhznsz) -- SDL3プレゼンテーション適応、Minecraft 26.3ブラックスクリーン（FBO0ヒールブリット）と自己修復解像度修正、MobileGluesデッドロック修正、Zink OpenGLブリッジを追加

## 翻訳について

このプロジェクトに翻訳を貢献したい場合は、[Crowdin](https://crowdin.com/project/amethyst-ios-remastered)からお願いします。

## サードパーティコンポーネント

| コンポーネント | 目的 | ライセンス | ソース |
|-----------|---------|---------|--------|
| Caciocavallo | AWTランタイムフレームワーク | GPL-2.0 | [GitHub](https://github.com/PojavLauncherTeam/caciocavallo) |
| jsr305 | コードアノテーションサポート | BSD-3 | [Google Code](https://code.google.com/p/jsr-305) |
| Boardwalk | コア機能適応 | Apache-2.0 | [GitHub](https://github.com/zhuowei/Boardwalk) |
| GL4ES | OpenGL-to-GLES翻訳 | MIT | [GitHub](https://github.com/ptitSeb/gl4es) |
| Mesa 3D | 3Dグラフィックスライブラリ | MIT | [GitLab](https://gitlab.freedesktop.org/mesa/mesa) |
| MetalANGLE | Metal-to-OpenGL ES翻訳 | BSD-2 | [GitHub](https://github.com/khanhduytran0/metalangle) |
| MoltenVK | Vulkan-to-Metal翻訳 | Apache-2.0 | [GitHub](https://github.com/KhronosGroup/MoltenVK) |
| openal-soft | クロスプラットフォーム3Dオーディオ | LGPL-2.0 | [GitHub](https://github.com/kcat/openal-soft) |
| Azul Zulu JDK | Javaランタイム (8/17/21/25) | GPL-2.0 | [Website](https://www.azul.com/downloads/?package=jdk) |
| LWJGL3 | Javaゲーム開発ライブラリ | BSD-3 | [GitHub](https://github.com/PojavLauncherTeam/lwjgl3) |
| LWJGLX | LWJGL2互換性レイヤー | -- | [GitHub](https://github.com/PojavLauncherTeam/lwjglx) |
| DBNumberedSlider | UIスライダーコントロール | Apache-2.0 | [GitHub](https://github.com/khanhduytran0/DBNumberedSlider) |
| fishhook | 動的ライブラリ rebinding | BSD-3 | [GitHub](https://github.com/khanhduytran0/fishhook) |
| shaderc | Vulkanシェーダーコンパイル | Apache-2.0 | [GitHub](https://github.com/khanhduytran0/shaderc) |
| NRFileManager | ファイル管理ユーティリティ | MPL-2.0 | [GitHub](https://github.com/mozilla-mobile/firefox-ios) |
| AltKit | AltStore統合 | -- | [GitHub](https://github.com/rileytestut/AltKit) |
| UnzipKit | ZIPアーカイブ処理 | BSD-2 | [GitHub](https://github.com/abbeycode/UnzipKit) |
| DyldDeNeuralyzer | ライブラリ検証バイパス | -- | [GitHub](https://github.com/xpn/DyldDeNeuralyzer) |
| MobileGlues | サードパーティレンダラー | LGPL-2.1 | [GitHub](https://github.com/MobileGL-Dev/MobileGlues) |
| LTW | OpenGL Core-to-ESラッパー | LGPL-3.0 | [GitHub](https://github.com/MojoLauncher/LTW) |
| authlib-injector | サードパーティ認証 | AGPL-3.0 | [GitHub](https://github.com/yushijinhun/authlib-injector) |

さらに、Minecraftアバターサービスのために[MCHeads](https://mc-heads.net)、Mod配信のために[Modrinth](https://modrinth.com)、およびMinecraftダウンロードミラーリングのために[BMCLAPI](https://bmclapidoc.bangbang93.com)に感謝します。

## スポンサー

このプロジェクトが価値があると感じた場合は、[Ko-Fi](https://ko-fi.com/herbrine8403)、[Afdian](https://afdian.com/a/herbrine8403)、または[WeChatリワードコード](donate.png)を通じて開発をサポートすることを検討してください。

## スターヒストリー

<a href="https://www.star-history.com/?type=date&repos=herbrine8403%2FAmethyst-iOS-MyRemastered">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=herbrine8403/Amethyst-iOS-MyRemastered&type=date&theme=dark&legend=top-left&sealed_token=q1uFKbS7fO8owrcjy_kYTkCnnl8PNgHAgBSrWop8Y3ULDdvwOwDfORslSVVXABSTwrsdu14OM3fshRaNbXouxMU5IenXF0T5r5L6rxKIN2n29T6Fv4UYyA" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=herbrine8403/Amethyst-iOS-MyRemastered&type=date&legend=top-left&sealed_token=q1uFKbS7fO8owrcjy_kYTkCnnl8PNgHAgBSrWop8Y3ULDdvwOwDfORslSVVXABSTwrsdu14OM3fshRaNbXouxMU5IenXF0T5r5L6rxKIN2n29T6Fv4UYyA" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=herbrine8403/Amethyst-iOS-MyRemastered&type=date&legend=top-left&sealed_token=q1uFKbS7fO8owrcjy_kYTkCnnl8PNgHAgBSrWop8Y3ULDdvwOwDfORslSVVXABSTwrsdu14OM3fshRaNbXouxMU5IenXF0T5r5L6rxKIN2n29T6Fv4UYyA" />
 </picture>
</a>