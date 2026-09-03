# Angel Aura Amethyst (iOS) 重制版 - 项目概览

## 项目简介

这是一个针对 iOS/iPadOS 平台优化的 Minecraft 启动器，基于官方 Amethyst 项目进行二次开发。它旨在提供更流畅的游戏体验、更好的本地化支持以及增强的功能，例如 Mod 管理、Shader 管理、整合包导入和智能下载源切换。

## 技术栈与架构

*   **主要语言**: Objective-C (原生 iOS 组件), Java (游戏核心逻辑), C/C++ (部分底层库和图形适配)
*   **构建系统**: 使用 `Makefile` 和 `CMake` 进行项目构建。
*   **构建环境**: GitHub Actions (macOS 14)，Xcode 15.4/16，iPhoneOS 17.5 SDK
*   **最低系统支持**: iOS 14.0
*   **核心依赖**:
    *   **Java 运行时**: 包含 OpenJDK 8, 17, 21 的 iOS 移植版本。
    *   **图形适配**: MetalANGLE (Metal to OpenGL ES), GL4ES (OpenGL ES to OpenGL), Mesa 3D, MobileGlues。
    *   **AWT 支持**: Caciocavallo (用于 Java AWT 的纯 Java 实现)。
    *   **其他**: LWJGL (Java 游戏开发库), OpenAL (音频处理), TouchController (触屏控制支持)。

## 目录结构

*   `Natives/`: 包含所有 iOS 原生代码 (Objective-C, C, C++)，包括 UI 控制器、应用入口点、Java 虚拟机启动器等。
    *   `authenticator/`: 账户认证模块，支持 Microsoft、本地账户和第三方认证。
    *   `customcontrols/`: 自定义控制布局模块。
    *   `external/`: 第三方依赖库 (AFNetworking, AltKit, fishhook, MobileGlues 等)。
    *   `input/`: 输入处理模块 (手柄、陀螺仪、键盘)。
    *   `installer/`: 安装器模块 (Fabric, Forge, 整合包)。
*   `JavaApp/`: 包含 Java 端的应用逻辑和库文件。
*   `TouchController/`: TouchController 静态库，提供触屏控制通信支持。
*   `depends/`: 存放构建时依赖项，如 Java 运行时环境。
*   `artifacts/`: 构建输出目录，包含最终的 `.ipa` 安装包和中间文件。

## 构建与运行

### 构建环境要求

*   必须在 macOS 上构建 (推荐 macOS 14)。
*   Xcode 15.4 或更高版本。
*   Xcode command line tools。
*   CMake, ldid, wget, JDK 8。
*   对于 iOS 14.5 及以上版本，推荐使用 TrollStore 进行安装以获得最佳体验。

### 构建命令

1.  **初始化环境**: 确保所有依赖项已安装。
2.  **执行构建**:
    ```bash
    make all
    ```
    这将依次执行以下步骤：
    *   `make dep_mg`: 构建 MobileGlues 依赖。
    *   `make native`: 构建原生库。
    *   `make java`: 构建 Java 应用。
    *   `make jre`: 下载并解压 iOS JRE。
    *   `make assets`: 编译应用资源 (如图标)。
    *   `make payload`: 组装应用包 (AngelAuraAmethyst.app)。
    *   `make package`: 生成最终的 `.ipa` 或 `.tipa` 安装包。

3.  **可选构建参数**:
    *   `RELEASE=1`: 构建 Release 版本。
    *   `SLIMMED=1`: 构建精简版 (不包含 Java 运行时)。
    *   `TROLLSTORE_JIT_ENT=1`: 生成 TrollStore 专用 TIPA 包。
    *   `PLATFORM=<值>`: 指定目标平台 (2=iOS, 3=tvOS, 7=iOS模拟器, 11=visionOS 等)。

4.  **部署**:
    *   在越狱设备上: `make deploy` (需要在设备上运行)。
    *   通过 TrollStore: 使用生成的 `.tipa` 文件直接安装。
    *   通过 AltStore/SideStore: 使用生成的 `.ipa` 文件安装。

注意，构建使用的设备是 GitHub Actions 提供的 macOS 14，而不是这个设备。

### 启动流程

1.  应用启动 (`main.m`): 进行环境检查、日志重定向、目录设置等初始化工作。
2.  UI 初始化 (`AppDelegate.m`, `SceneDelegate.m`): 设置主窗口和初始视图控制器。
3.  JVM 启动 (`JavaLauncher.m`): 配置 Java 环境变量、JVM 参数，加载并启动 Java 虚拟机。
4.  Java 应用运行: JVM 加载 `PojavLauncher` 类，执行 Minecraft 的启动逻辑。

## 开发规范

*   **代码风格**: Objective-C 遵循 Apple 的编码规范，C/C++ 代码风格在项目中保持一致。
*   **分支管理**: 使用 Git 进行版本控制，功能开发在 `feature/` 分支进行。
*   **本地化**: 项目已完整汉化，后续开发需注意文本的本地化处理。
*   **Git Commit 规范**:
    
    ```
    <type>(<scope>): <subject>
    ```
    
    **type(必须)**
    用于说明 git commit 的类别，只允许使用下面的标识：
    - feat：新功能（feature）
    - fix/to：修复 bug，可以是 QA 发现的 BUG，也可以是研发自己发现的 BUG
      - fix：产生 diff 并自动修复此问题。适合于一次提交直接修复问题
      - to：只产生 diff 不自动修复此问题。适合于多次提交。最终修复问题提交时使用 fix
    - docs：文档（documentation）
    - style：格式（不影响代码运行的变动）
    - refactor：重构（即不是新增功能，也不是修改 bug 的代码变动）
    - perf：优化相关，比如提升性能、体验
    - test：增加测试
    - chore：构建过程或辅助工具的变动
    - revert：回滚到上一个版本
    - merge：代码合并
    - sync：同步主线或分支的 Bug
    
    **scope(可选)**
    scope 用于说明 commit 影响的范围，比如数据层、控制层、视图层等等，视项目不同而不同。
    如果你的修改影响了不止一个 scope，你可以使用 * 代替。
    
    **subject(必须)**
    subject 是 commit 目的的简短描述，不超过 50 个字符。
    建议使用中文，结尾不加句号或其他标点符号。
    
    **示例**：
    - fix(DAO): 用户查询缺少 username 属性
    - feat(Controller): 用户查询接口开发
    
    **好处**：
    - 便于程序员对提交历史进行追溯，了解发生了什么情况
    - 约束 commit message，意味着将慎重的进行每一次提交，不能再一股脑的把各种各样的改动都放在一个 git commit 里面
    - 格式化的 commit message 才可以用于自动化输出 Change log

## 关键功能模块

*   **Mod 管理** (`ModsManagerViewController`, `ModService`): 提供 Mod 的查看、启用/禁用、删除功能，支持通过搜索框快速查找 Mod。
*   **Mod 下载** (`ModVersionViewController`): 支持 Modrinth API 下载 Mod，可选择不同版本。
*   **Shader 管理** (`ShadersManagerViewController`, `ShaderService`): 提供光影包的查看、启用/禁用、删除功能。
*   **Shader 下载** (`ShaderVersionViewController`): 支持 Modrinth API 下载光影包，可选择不同版本。
*   **整合包导入** (`ModpackImportViewController`, `ModpackImportService`): 支持导入 ZIP 格式的整合包。
*   **账户系统** (`authenticator/`): 支持 Microsoft 账户、本地账户、演示账户和第三方认证账户。
*   **自定义控制** (`customcontrols/`): 允许用户自定义游戏控制布局。
*   **偏好设置** (`PLPreferences`, `PLProfiles`): 管理用户设置和游戏配置文件，支持卡片式设置布局。
*   **自定义图标** (`CustomIconManager`): 支持自定义应用图标（开发中）。
*   **背景壁纸** (`BackgroundManager`): 支持自定义启动器背景壁纸。
*   **TouchController 支持** (`TouchControllerBridge`): 通过 UDP 本地代理实现与 TouchController Mod 的通信，为 iOS 用户提供触屏控制支持。

## GitHub Actions 工作流

项目使用 GitHub Actions 进行自动化构建：

*   **development.yml**: 主构建工作流，在推送到非 l10n_main 分支或 PR 时触发。
*   **development_speedup.yml**: 快速构建工作流。

构建产物：
*   `org.angelauramc.amethyst-ios.ipa`: 标准 IPA 安装包
*   `org.angelauramc.amethyst-ios-trollstore.tipa`: TrollStore 专用安装包
*   `AngelAuraAmethyst.dSYM`: 调试符号文件

## 其他信息

1.  在每次更改完源代码后，需要将更改提交到 GitHub 远程分支以构建项目进行测试。
2.  如果在提交到 GitHub 过程中出现网络问题，请提醒用户关闭网络代理。
3.  此项目使用 Xcode 15.4/16，iPhoneOS 17.5 SDK 构建，且最低系统支持为 iOS 14.0。
4.  Git 提交时请使用 `herbrine8403` 用户名和 `weishixvn@outlook.com` 邮箱。
5.  项目支持多平台构建，包括 iOS、tvOS、iOS 模拟器和 visionOS，通过 `PLATFORM` 参数指定。
6.  渲染器设置为 Auto 时固定解析为 ANGLE；其他渲染后端需手动明确选择。
7.  JVM 版本将根据游戏版本自动选择 (Java 8/17/21)。
