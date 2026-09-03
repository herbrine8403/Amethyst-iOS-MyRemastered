cmake_minimum_required(VERSION 3.6)
project(AngelAuraAmethyst)

# 从环境变量读取 CurseForge API Key
# 不能通过 Makefile 的 -D 参数传递，因为 Make 会对环境变量值进行递归展开，
# 导致 bcrypt 哈希格式（$2a$10$...）中的 $2、$1、$Q 被 Make 解释为变量引用并替换为空，
# 最终生成损坏的 Key（如 a06bVFEP... 而非 $2a$10$Q6bVFEP...）
if(DEFINED ENV{CONFIG_CURSEFORGE_API_KEY})
    set(CONFIG_CURSEFORGE_API_KEY "$ENV{CONFIG_CURSEFORGE_API_KEY}")
endif()

configure_file(${CMAKE_CURRENT_LIST_DIR}/config.h.in ${CMAKE_CURRENT_LIST_DIR}/config.h)

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -target arm64-apple-ios -mcpu=apple-a8 -fcommon -fobjc-arc -ObjC -F'${CMAKE_OSX_SYSROOT}/System/Cryptexes/OS/System/Library/Frameworks'")
set(CMAKE_C_FLAGS_DEBUG "-funwind-tables -g")

if("${CMAKE_HOST_SYSTEM_NAME}" MATCHES "Linux|^GNU$|Android")
  set(GLOBAL_LDFLAGS "-isysroot ${CMAKE_OSX_SYSROOT} -Wl,-syslibroot,${CMAKE_OSX_SYSROOT} -fuse-ld=lld")
  set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} ${GLOBAL_LDFLAGS}")
  set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} ${GLOBAL_LDFLAGS}")
endif()

include_directories(
  "."
  "external/AFNetworking/AFNetworking"
  "external/AFNetworking/UIKit+AFNetworking"
  "external/DBNumberedSlider/Classes"
  "external/NRFileManager"
  "external/UnzipKit"
  "external/fishhook"
  "external/lzma"
  "external/mesa"
  "external/AltKit"
  "external/Apple"
  "external/ballpa1n"
  "external/ballpa1n/wrapped"
  "external/mach"
  # "external/ZeroTierFramework/ios-example-app/zt.framework/Headers"  # ZeroTier 暂时移除
)

# ============================================================================
# ZeroTier Apple Framework 集成 —— 暂时移除（注释掉以排查启动崩溃）
# ============================================================================
# set(ZT_FRAMEWORK_DIR "${CMAKE_CURRENT_LIST_DIR}/external/ZeroTierFramework/ios-example-app")
# set(ZT_FRAMEWORK_LIB "${ZT_FRAMEWORK_DIR}/zt.framework/zt")
# if(EXISTS "${ZT_FRAMEWORK_LIB}")
#   message(STATUS "Found ZeroTier framework binary: ${ZT_FRAMEWORK_LIB}")
#   set(ZT_FRAMEWORK_SEARCH_PATH "-F'${ZT_FRAMEWORK_DIR}'")
#   set(ZT_FRAMEWORK_LINK "-framework zt")
#   set(ZT_CXX_LIB "-lc++")
# else()
#   message(FATAL_ERROR "ZeroTier framework not found at ${ZT_FRAMEWORK_LIB}. Please run: git submodule update --init --recursive")
# endif()
set(ZT_FRAMEWORK_SEARCH_PATH "")
set(ZT_FRAMEWORK_LINK "")
set(ZT_CXX_LIB "")

# ============================================================================
# libterracotta.xcframework 集成（陶瓦联机）—— 暂时移除（注释掉以排查启动崩溃）
# ============================================================================
# set(TERRACOTTA_LIB_DIR "${CMAKE_CURRENT_LIST_DIR}/terracotta")
# set(TERRACOTTA_XCFW "${TERRACOTTA_LIB_DIR}/libterracotta.xcframework")
# set(TERRACOTTA_LIB "")
# set(TERRACOTTA_AVAILABLE OFF)
# if(EXISTS "${TERRACOTTA_XCFW}/ios-arm64/libterracotta.a")
#   set(_TC_LIB_PATH "${TERRACOTTA_XCFW}/ios-arm64/libterracotta.a")
#   set(TERRACOTTA_LIB "-Wl,-force_load,${_TC_LIB_PATH}")
#   set(TERRACOTTA_AVAILABLE ON)
# elseif(EXISTS "${TERRACOTTA_LIB_DIR}/libterracotta.a")
#   set(_TC_LIB_PATH "${TERRACOTTA_LIB_DIR}/libterracotta.a")
#   set(TERRACOTTA_LIB "-Wl,-force_load,${_TC_LIB_PATH}")
#   set(TERRACOTTA_AVAILABLE ON)
# endif()
set(TERRACOTTA_LIB "")
set(TERRACOTTA_AVAILABLE OFF)

# For cacio support library
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -rpath @loader_path -rpath @executable_path/java_runtimes/java-8-openjdk/lib -rpath /usr/lib/jvm/java-8-openjdk/lib")

# EXT: stub library, delete after compile awt_xawt
add_library(awt_headless SHARED
  awt_xawt/empty.m
)
target_link_libraries(awt_headless)

# EXT: cacio support library
add_library(awt_xawt SHARED
  awt_xawt/xawt_fake.m
)
target_link_libraries(awt_xawt
  "-L'${CMAKE_CURRENT_LIST_DIR}/build'"
  awt_headless
)

# TouchController iOS native library
# Provides JNI / C API for touch control communication between Minecraft mod and launcher
#
# 三级回退检测逻辑（按优先级从高到低）：
#   Level 1 — 预编译 XCFramework：检测 TouchController.xcframework/，从 ios-arm64
#             子目录提取设备静态库链接（由 build_xcframework.sh 生成）
#   Level 2 — 预编译独立 .a：检测 libproxy_server_ios.a (device) 或
#             libproxy_server_ios_simulator.a (simulator)，保持向后兼容
#   Level 3 — 源码编译回退：检测 ios_transport.c 源文件，CMake 直接编译为对象库
#   禁用   — 以上都不存在时，TOUCHCONTROLLER_LIB 置空并打印警告
#
# 重要：TouchControllerBridge.m 通过 dlsym(RTLD_DEFAULT, "touchcontroller_ios_*")
# 运行时查找符号，编译期没有任何直接引用。Apple ld 处理静态库（.a）时按需加载，
# 只提取被直接引用的对象文件——未被引用的对象文件会被丢弃，导致 dlsym 找不到符号。
# 因此：
#   - Level 1/2（预编译 .a）：必须用 -Wl,-force_load,<path> 强制加载整个静态库
#   - Level 3（源码编译）：改用 OBJECT 库，对象文件直接链接到可执行文件，
#     所有符号自动保留，无需 -force_load
set(TOUCHCONTROLLER_LIB_DIR "${CMAKE_CURRENT_LIST_DIR}/TouchController")
set(TOUCHCONTROLLER_XCFW "${TOUCHCONTROLLER_LIB_DIR}/TouchController.xcframework")
set(TOUCHCONTROLLER_LIB "")

# Level 1: 预编译 XCFramework（最高优先级）
if(EXISTS "${TOUCHCONTROLLER_XCFW}/ios-arm64/libproxy_server_ios.a")
  set(_TC_LIB_PATH "${TOUCHCONTROLLER_XCFW}/ios-arm64/libproxy_server_ios.a")
  message(STATUS "Found TouchController XCFramework (Level 1: prebuilt xcframework) at ${_TC_LIB_PATH}")
  # 强制加载整个静态库，确保 dlsym 能找到所有 touchcontroller_ios_* 符号
  set(TOUCHCONTROLLER_LIB "-Wl,-force_load,${_TC_LIB_PATH}")
# Level 2: 预编译独立 .a（保持兼容）
elseif(EXISTS "${TOUCHCONTROLLER_LIB_DIR}/libproxy_server_ios.a")
  set(_TC_LIB_PATH "${TOUCHCONTROLLER_LIB_DIR}/libproxy_server_ios.a")
  message(STATUS "Found TouchController device library (Level 2: prebuilt .a) at ${_TC_LIB_PATH}")
  set(TOUCHCONTROLLER_LIB "-Wl,-force_load,${_TC_LIB_PATH}")
elseif(EXISTS "${TOUCHCONTROLLER_LIB_DIR}/libproxy_server_ios_simulator.a")
  set(_TC_LIB_PATH "${TOUCHCONTROLLER_LIB_DIR}/libproxy_server_ios_simulator.a")
  message(STATUS "Found TouchController simulator library (Level 2: prebuilt .a) at ${_TC_LIB_PATH}")
  set(TOUCHCONTROLLER_LIB "-Wl,-force_load,${_TC_LIB_PATH}")
# Level 3: 源码编译回退（使用 OBJECT 库确保所有符号被保留）
elseif(EXISTS "${TOUCHCONTROLLER_LIB_DIR}/ios_transport.c")
  message(STATUS "Building TouchController from source (Level 3: source compilation)")
  # 使用 OBJECT 库而非 STATIC 库：对象文件直接链接到可执行文件，
  # 所有符号自动保留，避免 dlsym 找不到符号的问题
  add_library(proxy_server_ios OBJECT
    ${TOUCHCONTROLLER_LIB_DIR}/ios_transport.c
    ${TOUCHCONTROLLER_LIB_DIR}/ring_buffer.c
  )
  target_include_directories(proxy_server_ios PRIVATE ${TOUCHCONTROLLER_LIB_DIR})
  set(TOUCHCONTROLLER_LIB proxy_server_ios)
# 全部未命中：禁用 TouchController 支持
else()
  message(STATUS "TouchController library not found, TouchController support will be disabled")
  set(TOUCHCONTROLLER_LIB "")
endif()

set(CMAKE_FRAMEWORK_PATH "${CMAKE_CURRENT_LIST_DIR}/resources/Frameworks")

set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -rpath @executable_path/Frameworks -rpath @loader_path/Frameworks")
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -rpath @executable_path/Frameworks -rpath @loader_path/Frameworks")

# ANGLE wrapper for 1.17+
add_library(tinygl4angle SHARED
  external/gl4es/string_utils.c
  external/gl4es/tinygl4angle.c
)
target_link_libraries(tinygl4angle
  "${GLOBAL_LDFLAGS}"
  "-F'${CMAKE_CURRENT_LIST_DIR}/resources/Frameworks'"
  "-framework libEGL"
  "-framework libGLESv2"
)

# LTW (Large Thin Wrapper) - OpenGL Core 3.3 → OpenGL ES 3 转译层
# 复刻自官方 MojoLauncher/LTW 仓库（master 分支），iOS 移植修改：
#   - proc.c: 从 libtinygl4angle.dylib 加载 eglGetProcAddress（替代 libEGL.so）
#   - egl.c/egl.h: thread_local → pthread_key_t（更可靠的 TLS）
#   - shader_wrapper.c: 修复 offset 未递增 bug（count > 1 时 shader 源码损坏）
#   - ltw_compat/threads.h: 提供 C11 <threads.h> 兼容（iOS SDK 不提供）
# 功能：
#   - 伪装成 OpenGL 3.3 Core Profile 让 MC 1.17+ 正常运行
#   - 主动声明 GL_ARB_buffer_storage / GL_ARB_texture_buffer_object 等 ARB 扩展
#     让 Sodium 的 persistent mapped buffers / texture buffers 正常工作
#   - 主动声明 GL_ARB_draw_buffers_blend（Iris 必需）
#   - 主动声明 GL_ARB_timer_query（Blaze3D TimerQuery）
#   - Fragment shader 编译失败时忽略错误（shader_wrapper.c HACK），
#     让 BSL/Mellow Shader 等光影包能在 ES 上运行
set(LTW_DIR "${CMAKE_CURRENT_LIST_DIR}/external/LTW/ltw/src/main/tinywrapper")
set(LTW_INCLUDES
  "${LTW_DIR}"
  "${LTW_DIR}/GL"
  "${CMAKE_CURRENT_LIST_DIR}/cmake/ltw_compat"
  "${LTW_DIR}/glsl_optimizer/include"
  "${LTW_DIR}/glsl_optimizer/src"
  "${LTW_DIR}/vgpu_shaderconv"
  "${LTW_DIR}/unordered_map"
  "${CMAKE_CURRENT_LIST_DIR}/external/MobileGlues/src/main/cpp/include"
)

include(cmake/ltw_sources.cmake)

add_library(glsl_optimizer STATIC ${GLSL_OPTIMIZER_SRC})
target_include_directories(glsl_optimizer PRIVATE ${LTW_INCLUDES})
set_target_properties(glsl_optimizer PROPERTIES
  POSITION_INDEPENDENT_CODE ON
  CXX_STANDARD 17
  C_STANDARD 11
)
target_compile_definitions(glsl_optimizer PRIVATE
  _LIB NOMINMAX _USE_MATH_DEFINES __STDC_NO_THREADS__
  __STDC_LIMIT_MACROS __STDC_FORMAT_MACROS __STDC_CONSTANT_MACROS
  UTL_ARCH_LITTLE_ENDIAN UNIX
  HAVE_OPENGL HAVE_OPENGL_ES_1 HAVE_OPENGL_ES_2
  HAVE_TIMESPEC_GET HAVE_STRUCT_TIMESPEC
  VK_DESCRIPTOR_TYPE_INLINE_UNIFORM_BLOCK=VK_DESCRIPTOR_TYPE_INLINE_UNIFORM_BLOCK_EXT
)

add_library(ltw SHARED ${LTW_CORE_SRC})
target_include_directories(ltw PRIVATE ${LTW_INCLUDES})
target_link_libraries(ltw
  "${GLOBAL_LDFLAGS}"
  glsl_optimizer
  "-F'${CMAKE_CURRENT_LIST_DIR}/resources/Frameworks'"
  "-framework libEGL"
  "-framework libGLESv2"
)
set_target_properties(ltw PROPERTIES
  C_STANDARD 11
  C_STANDARD_REQUIRED ON
)
target_compile_definitions(ltw PRIVATE
  _LIB NOMINMAX _USE_MATH_DEFINES __STDC_NO_THREADS__
  __STDC_LIMIT_MACROS __STDC_FORMAT_MACROS __STDC_CONSTANT_MACROS
  UTL_ARCH_LITTLE_ENDIAN UNIX
  HAVE_OPENGL HAVE_OPENGL_ES_1 HAVE_OPENGL_ES_2
  HAVE_TIMESPEC_GET HAVE_STRUCT_TIMESPEC
)

# AFNetworking
add_library(AFNetworking SHARED
  external/AFNetworking/AFNetworking/AFSecurityPolicy.m
  external/AFNetworking/AFNetworking/AFHTTPSessionManager.m
  external/AFNetworking/AFNetworking/AFURLRequestSerialization.m
  external/AFNetworking/AFNetworking/AFURLSessionManager.m
  external/AFNetworking/AFNetworking/AFNetworkReachabilityManager.m
  external/AFNetworking/AFNetworking/AFURLResponseSerialization.m
  external/AFNetworking/UIKit+AFNetworking/AFNetworkActivityIndicatorManager.m
  external/AFNetworking/UIKit+AFNetworking/AFAutoPurgingImageCache.m
  external/AFNetworking/UIKit+AFNetworking/AFImageDownloader.m
  external/AFNetworking/UIKit+AFNetworking/UIButton+AFNetworking.m
  external/AFNetworking/UIKit+AFNetworking/UIImageView+AFNetworking.m
)
target_link_libraries(AFNetworking
  "-framework CoreGraphics"
  "-framework CoreServices"
  "-framework Security"
  "-framework SystemConfiguration"
  "-framework UIKit"
)

# MinecraftAccount JNI
add_library(AmethystAccountJNI SHARED
  authenticator/MinecraftAccountJNI.m
)
target_link_libraries(AmethystAccountJNI)

# Audio capture JNI bridge (SimpleVoiceChat Mod support)
add_library(audio_capture SHARED
  audio_capture_bridge.m
)
target_link_libraries(audio_capture
  "-framework AVFoundation"
)

# Angel Aura Amethyst
add_executable(AngelAuraAmethyst
  dyld_bypass_validation.m
  dyld_patch_platform.m
  main.m
  main_hook.m
  JavaLauncher.m
  external/fishhook/fishhook.c
  UIKit+hook.m
  ScreenUtils.m

  authenticator/BaseAuthenticator.m
  authenticator/LocalAuthenticator.m
  authenticator/MicrosoftAuthenticator.m
  authenticator/ThirdPartyAuthenticator.m

  ctxbridges/gl_bridge.m
  ctxbridges/osm_bridge.m
  ctxbridges/vk_bridge.m

  customcontrols/ControlButton.m
  customcontrols/ControlDrawer.m
  customcontrols/ControlJoystick.m
  customcontrols/ControlLayout.m
  customcontrols/ControlSubButton.m
  customcontrols/CustomControlsUtils.m
  customcontrols/NSPredicateUtilitiesExternal.m

  external/DBNumberedSlider/Classes/DBNumberedSlider.m
  external/NRFileManager/NSFileManager+NRFileManager.m
  external/ballpa1n/HostManager.c
  external/ballpa1n/wrapped/HostManagerBridge.m
  external/mach/mach_excServer.c

  installer/FabricInstallViewController.m
  installer/ForgeInstallViewController.m
  installer/ForgeInstallSchemeViewController.m
  installer/ForgeDirectInstaller.m
  installer/NeoForgeDirectInstaller.m
  installer/ForgeProcessorExecutor.m
  installer/ModpackInstallViewController.m
  installer/ModLoaderInstallViewController.m
  installer/FabricUtils.m
  installer/NeoForgeVersionFetcher.m
  installer/modpack/ModpackUtils.m
  installer/modpack/ModpackConfiguration.m
  installer/modpack/ModpackAPI.m
  installer/modpack/ModrinthAPI.m
	installer/modpack/CurseForgeAPI.m

  input/ControllerInput.m
  input/GyroInput.m
  input/KeyboardInput.m

  AccountListViewController.m
  AccountLoginViewController.m
  ThirdPartyLoginViewController.m
  GameMenuOverlayView.m
  InlineMessageView.m
  DownloadTaskItem.m
  DownloadTaskManager.m
  PLTaskStage.m
  PLTaskProgressViewController.m
  DownloadTasksViewController.m
  DownloadHistoryViewController.m
  DownloadHistoryStore.m
  PLDownloadClient.m
  PLMirrorCenter.m
  AppDelegate.m
  CustomControlsViewController.m
  CustomControlsViewController+UndoManager.m
  FileListViewController.m
  GameSurfaceView.m
  JavaGUIViewController.m
  # ZeroTier 联机暂时移除（排查启动崩溃）
  # MultiplayerManager.m
  # MultiplayerViewController.m
  # LanPortDetector.m
  # ZeroTierBridge.m
  # SOCKS5Proxy.m
  # PortForwarder.m
  LauncherMenuViewController.m
  LauncherNavigationController.m
  LauncherNewsViewController.m
  HomeCustomizeViewController.m
  LauncherRootViewController.m
  LauncherCardLayoutViewController.m
  LauncherRightPanelViewController.m
  VersionManagerViewController.m
  ProfileSettingsViewController.m
  DownloadViewController.m
  LauncherPreferences.m
  PLThemeManager.m
  LauncherPreferencesViewController.m
  LauncherPrefContCfgViewController.m
  LauncherPrefGameDirViewController.m
  LauncherPrefManageJREViewController.m
  LauncherProfileEditorViewController.m
  LauncherSplitViewController.m
  MinecraftResourceDownloadTask.m
  MinecraftResourceUtils.m
  PickTextField.m
  PLLogOutputView.m
  PLCrashView.m
  PLPickerView.m
  PLPreferences.m
  PLPrefTableViewController.m
  PLProfiles.m
  SceneDelegate.m
  SceneExternalDelegate.m
  SurfaceViewController.m
  SurfaceViewController+ExternalDisplay.m
  SurfaceViewController+LogView.m
  SurfaceViewController+Navigation.m
  TrackedTextField.m
  egl_bridge.m
  ZinkConfig.m
  input_bridge_v3.m
  ios_uikit_bridge.m
  utils.m

  # Version card cell (used by DownloadViewController)
  VersionCardCell.m

  # Resource management shared base classes (card cell + list VC, shared by the 6 resource managers)
  ResourceCardTableViewCell.m
  ResourceListViewController.m

  # Mod-related sources (ensure implementations are compiled and linked)
  MarqueeLabel.m
  ModItem.m
  ModService.m
  ModTableViewCell.m
  ModTableViewController.m
  ModsManagerViewController.m
  ModVersion.m
  ModVersionViewController.m
  ModVersionTableViewCell.m

  # 通用资源详情页头部视图（Mod/Shader/Asset 版本页共用，展示项目封面图/信息/标签/描述）
  AssetDetailHeaderView.m

  # 模组加载器图标统一工具类（优先 bundle PNG，回退 SF Symbol，统一全项目加载器品牌色与图标）
  ModLoaderIconHelper.m

  # 统一的项目图标加载器（双层缓存+降采样+并发控制+CDN镜像，参照 FCL Glide + ZL2 Coil）
  IconLoader.m

  # Shader-related sources
  ShaderItem.m
  ShaderService.m
  ShaderVersion.m
  ShaderVersionTableViewCell.m
  ShaderVersionViewController.m
  ShadersManagerViewController.m

  # Modpack import/export sources
  ModpackImportViewController.m
  ModpackImportService.m
  ModpackExportService.m
  ModpackExportViewController.m

  # CurseForge MurmurHash2 fingerprint tool
  MurmurHash2.m
  # CurseForge MurmurHash2 指纹便捷计算（mod 检测更新反查用，过滤空白字节后计算）
  CurseForgeMurmurHash.m

  # Resource Pack / Data Pack / World management (services, items, version VC, manager VCs)
  ResourcePackItem.m
  DataPackItem.m
  WorldItem.m
  ResourcePackService.m
  DataPackService.m
  WorldService.m
  AssetVersionViewController.m
  ResourcePacksManagerViewController.m
  DataPacksManagerViewController.m
  WorldsManagerViewController.m

  # Server projects (Modrinth Server Projects + CurseForge server packs)
  ServerItem.m
  ServerService.m
  ServerListViewController.m
  ServerDetailViewController.m

  # CurseForge API Key settings page
  installer/CurseForgeAPIKeyViewController.m

  # Mod update service (dual-source SHA1/MurmurHash2 reverse lookup)
  ModUpdateService.m

  # Custom icon management sources
  CustomIconManager.m
  ImageCropperViewController.m

  # Account custom avatar management sources
  AvatarManager.m

  # Background wallpaper sources
  BackgroundManager.m
  BackgroundSettingsViewController.m

  # FCL-style interface is implemented in LauncherMenuViewController.m

  # TouchController bridge and preferences
  TouchControllerBridge.m
  TouchControllerPreferencesViewController.m

  # Terracotta multiplayer（陶瓦联机）—— 暂时移除（排查启动崩溃）
  # TerracottaBridge.m
  # TerracottaManager.m
  # SilentAudioPlayer.m
  # TerracottaViewController.m

  # Update checker（参考 FCL/ZL2，使用 GitHub Releases API 检查正式版更新）
  UpdateChecker.m

  # Minecraft 新闻（参考 PCL-CE，调用 minecraft-services.net 官方新闻 API）
  MinecraftNewsItem.m
  MinecraftNewsService.m
  MinecraftNewsViewController.m

  # 公告系统（从官网拉取 JSON，支持 Markdown 渲染）
  AnnouncementItem.m
  AnnouncementService.m
  MarkdownParser.m
  AnnouncementListViewController.m
  AnnouncementDetailViewController.m

  # Air AI Agent（OpenAI 兼容聊天助手）
  AI/AiProvider.m
  AI/AiProviderStore.m
  AI/AiMessage.m
  AI/AiSession.m
  AI/AiSessionStore.m
  AI/AiSettings.m
  AI/AiAPIClient.m
  AI/AiAgent.m
  AI/AIMessageCell.m
  AI/AIInputBarView.m
  AI/AIViewController.m
  AI/AISessionListViewController.m
  AI/AIProviderConfigViewController.m
  AI/AISystemPromptEditorViewController.m

  # Air AI Agent 工具基础层（3a：注册表 / 安全机制 / 实例 / 日志 / 崩溃 / 文件 / 问答）
  AI/AiToolRegistry.m
  AI/AiSafetyManager.m
  AI/AiToolBootstrapper.m
  AI/AiInstancesTool.m
  AI/AiLogReader.m
  AI/AiCrashAnalyzer.m
  AI/AiFileTools.m
  AI/AiAskTool.m

  # Air AI Agent 资源/网络工具（3b：Modrinth 搜索 + 资源安装/引导）
  AI/AiAssetTools.m

  # Air AI Agent 第二轮增强（enhance-ai-agent：设置 / to-do / sleep / 下载查询 / 实例创建）
  AI/AiSettingsTools.m
  AI/AiTodoTool.m
  AI/AiSleepTool.m
  AI/AiDownloadProbe.m
  AI/AiInstanceCreator.m
)

# Add ModLoaderIcons PNG files into the app bundle Resources/ModLoaderIcons so they are available at runtime.
# This will copy all *.png under Natives/ModLoaderIcons into the bundle at Resources/ModLoaderIcons/<name>.png
set(MODLOADER_ICONS_DIR "${CMAKE_CURRENT_LIST_DIR}/ModLoaderIcons")
if(EXISTS "${MODLOADER_ICONS_DIR}")
  file(GLOB MODLOADER_ICON_FILES "${MODLOADER_ICONS_DIR}/*.png")
  if(MODLOADER_ICON_FILES)
    foreach(_icon ${MODLOADER_ICON_FILES})
      get_filename_component(_name ${_icon} NAME)
      message(STATUS "Including mod loader icon in bundle: ${_name}")
      # Place into Resources/ModLoaderIcons inside the .app bundle so your code can find resourcePath/ModLoaderIcons/...
      set_source_files_properties(${_icon} PROPERTIES MACOSX_PACKAGE_LOCATION "Resources/ModLoaderIcons")
    endforeach()
    # Attach the resource files to the main executable target so CMake copies them into the bundle
    target_sources(AngelAuraAmethyst PRIVATE ${MODLOADER_ICON_FILES})
  endif()
else()
  message(STATUS "ModLoaderIcons directory not found: ${MODLOADER_ICONS_DIR}")
endif()

if("${CMAKE_HOST_SYSTEM_NAME}" MATCHES "Linux|^GNU$|Android")
  target_sources(AngelAuraAmethyst PUBLIC non_darwin_utils.m)
endif()

target_link_libraries(AngelAuraAmethyst
  PUBLIC AFNetworking
  lzma
  "-F'${CMAKE_CURRENT_LIST_DIR}/build'"
  "-F'${CMAKE_CURRENT_LIST_DIR}/resources/Frameworks'"
  # ZeroTier 暂时移除："${ZT_FRAMEWORK_SEARCH_PATH}" "${ZT_FRAMEWORK_LINK}" "${ZT_CXX_LIB}"
  "-framework AltKit"
  "-framework AuthenticationServices"
  "-framework AVFoundation"
  "-framework CAltKit"
  "-framework CoreFoundation"
  "-framework CoreGraphics"
  "-framework CoreImage"
  "-framework CoreMedia"
  "-framework ImageIO"
  "-framework CoreMotion"
  "-framework GameController"
  "-framework IOKit"
  "-framework QuartzCore"
  "-framework UIKit"
  "-framework UniformTypeIdentifiers"
  "-framework UnzipKit"
  "-framework WebKit"
  "-weak_framework SafariServices"
  ${TOUCHCONTROLLER_LIB}
  # Terracotta multiplayer 暂时移除：${TERRACOTTA_LIB} "-lc++" "-lresolv"
)
set_target_properties(AngelAuraAmethyst PROPERTIES
  MACOSX_BUNDLE TRUE
  MACOSX_FRAMEWORK_IDENTIFIER org.cmake.ExecutableTarget
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_LIST_DIR}/Info.plist")
