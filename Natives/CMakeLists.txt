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

# ★ 关键修正:从 CMAKE_OSX_SYSROOT 解析出 SDK 版本(如 .../iPhoneOS26.2.sdk -> 26.2),
#   并把 -target 补成 arm64-apple-ios<min>-ios<SDK>。
#   为什么必须这么做:原来只写 "-target arm64-apple-ios"(不带 SDK 版本),
#   clang 会把 SDK 记成默认值 ⇒ 产物主二进制 LC_BUILD_VERSION 的 sdk 字段不是实际 SDK
#   ⇒ 系统按 SDK 判定"该应用未用 iOS 26 SDK 构建" ⇒ 不采用 iOS 26 新外观(拿不到液态玻璃)。
#
#   注:iOS 的 target triple 里【不能】带 SDK 版本(clang 会报
#   "version 'ios26.2' in target triple ... is invalid"),SDK 由 -isysroot 指向的
#   SDK 决定。因此这里只写 minOS(ios14.0),并显式给出 -miphoneos-version-min=14.0,
#   让 clang 把 SDK 版本如实记录为 -isysroot 所指 SDK(CI 里已锁 Xcode 26.3 / iPhoneOS26.2)。
if(CMAKE_OSX_SYSROOT)
  get_filename_component(AME_SDK_NAME "${CMAKE_OSX_SYSROOT}" NAME)      # iPhoneOS26.2.sdk
  string(REGEX MATCH "iPhoneOS([0-9]+\.[0-9]+)" _m "${AME_SDK_NAME}")   # 取版本
  if(CMAKE_MATCH_1)
    set(AME_SDK_VERSION "${CMAKE_MATCH_1}")
  endif()
endif()
if(NOT AME_SDK_VERSION)
  set(AME_SDK_VERSION "26.2")   # 兜底(CI 已锁定 Xcode 26.3/iOS 26.2 SDK)
endif()
message(STATUS "★ AME_SDK_VERSION = ${AME_SDK_VERSION} (from ${CMAKE_OSX_SYSROOT})")

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -target arm64-apple-ios14.0 -miphoneos-version-min=14.0 -mcpu=apple-a8 -fcommon -fobjc-arc -ObjC -F'${CMAKE_OSX_SYSROOT}/System/Cryptexes/OS/System/Library/Frameworks'")
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

# ============================================================================
# ★ [SWIFT-BAR] SwiftUI 底部标签栏(Natives/AmeTabBar.swift)编译规则
# ----------------------------------------------------------------------------
#  为什么必须单开一条 swiftc 规则:本工程的 C/OBJC 都用 clang(CMake 的 C 编译器),
#  **clang 编不了 Swift**;而工程是纯 CMake(没有 Xcode 工程文件)⇒ 用
#  add_custom_command 调 swiftc 产出 AmeTabBar.o,再把该 .o 当外部对象加进
#  add_executable(AngelAuraAmethyst ...) 的源列表(只追加,不动既有 OBJC 顺序)。
#
#  target triple 按平台自动判定(设备 / 模拟器),与 C 侧 minOS 一致(ios14.0):
#    设备:   arm64-apple-ios14.0             (SDK = .../iPhoneOS*.sdk)
#    模拟器: <arch>-apple-ios14.0-simulator  (SDK = .../iPhoneSimulator*.sdk)
#
#  链接:Swift 运行时在 SDK 的 usr/lib/swift(SDK 里有 libswiftCore.tbd 等),
#  设备 iOS 12.2+ 的系统里也自带 /usr/lib/swift ⇒
#    ① 不用打包任何 Swift dylib;② 不改 CFBundle;③ 只是给链接器 -L + rpath。
#  若链接真报缺 libswift*,再按需补 -lswiftCore -lswiftFoundation -lswiftUIKit
#  -lswiftSwiftUI(见 _uibuild/SWIFT_BAR_REPORT.md「链接参数怎么定的」)。
# ============================================================================

set(AME_TABBAR_SWIFT_SRC "${CMAKE_CURRENT_LIST_DIR}/AmeTabBar.swift")

# 架构:C 侧统一走 CMAKE_OSX_ARCHITECTURES(Makefile 传 arm64);缺省退回宿主架构
set(AME_SWIFT_ARCH "${CMAKE_OSX_ARCHITECTURES}")
if(NOT AME_SWIFT_ARCH)
  set(AME_SWIFT_ARCH "${CMAKE_HOST_SYSTEM_PROCESSOR}")
endif()

# 设备 / 模拟器:看 -isysroot 指向的 SDK 路径里有没有 Simulator
set(AME_SWIFT_TRIPLE "${AME_SWIFT_ARCH}-apple-ios14.0")
if("${CMAKE_OSX_SYSROOT}" MATCHES "[Ss]imulator")
  set(AME_SWIFT_TRIPLE "${AME_SWIFT_ARCH}-apple-ios14.0-simulator")
endif()

# Swift 运行时目录(SDK 内)
set(AME_SWIFT_LIBDIR "${CMAKE_OSX_SYSROOT}/usr/lib/swift")
# ★ [SWIFT-BAR] 回退兼容库(swiftCompatibility56/Concurrency/Packs)不在 SDK 里,
#   只在【Xcode 工具链】的 usr/lib/swift/iphoneos 下 ⇒ 必须再给链接器一条 -L。
get_filename_component(AME_XCODE_DEVDIR "${CMAKE_OSX_SYSROOT}/../../../../.." ABSOLUTE)
set(AME_SWIFT_TOOLCHAIN_LIBDIR "${AME_XCODE_DEVDIR}/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/iphoneos")
if(NOT EXISTS "${AME_SWIFT_TOOLCHAIN_LIBDIR}")
  set(AME_SWIFT_TOOLCHAIN_LIBDIR "${AME_XCODE_DEVDIR}/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift")
endif()
message(STATUS "★ [SWIFT-BAR] toolchain swift libdir = ${AME_SWIFT_TOOLCHAIN_LIBDIR}")

# Release 加 -O(与 C 侧 CMAKE_BUILD_TYPE 对齐)
set(AME_SWIFT_OPT_FLAGS "")
if("${CMAKE_BUILD_TYPE}" STREQUAL "Release")
  set(AME_SWIFT_OPT_FLAGS "-O")
endif()

# swiftc:先找 PATH,再退回 xcrun(CI/无 PATH 的环境)
find_program(AME_SWIFTC NAMES swiftc)
if(NOT AME_SWIFTC)
  execute_process(COMMAND xcrun -f swiftc
                  OUTPUT_VARIABLE _ame_swiftc_hint
                  OUTPUT_STRIP_TRAILING_WHITESPACE
                  RESULT_VARIABLE _ame_swiftc_rc)
  if(_ame_swiftc_rc EQUAL 0)
    set(AME_SWIFTC "${_ame_swiftc_hint}")
  endif()
endif()

# 若 Makefile 的 `swift` 目标已经先编好 .o 并 -DAME_TABBAR_OBJ 传进来,就直接复用
if(AME_TABBAR_OBJ AND EXISTS "${AME_TABBAR_OBJ}")
  set(AME_TABBAR_NEEDS_BUILD FALSE)
else()
  set(AME_TABBAR_OBJ "${CMAKE_CURRENT_BINARY_DIR}/AmeTabBar.o")
  set(AME_TABBAR_NEEDS_BUILD TRUE)
endif()

# Swift 现在是底栏的唯一实现(LauncherMenuViewController.m 直接引用 AmeTabBarHost),
# 编不出来就会在链接期报 undefined symbol ⇒ 这里直接给出可读的失败原因。
if(AME_TABBAR_NEEDS_BUILD AND NOT AME_SWIFTC)
  message(FATAL_ERROR "★ [SWIFT-BAR] 找不到 swiftc。AmeTabBar.swift(底栏)必须用 Swift 编译;"
                      "请安装 Xcode / Command Line Tools,或确认 `xcrun -f swiftc` 可用。")
endif()

if(AME_TABBAR_NEEDS_BUILD)
  add_custom_command(
    OUTPUT  "${AME_TABBAR_OBJ}"
    COMMAND "${AME_SWIFTC}" -parse-as-library -emit-object
            -target "${AME_SWIFT_TRIPLE}"
            -sdk "${CMAKE_OSX_SYSROOT}"
            ${AME_SWIFT_OPT_FLAGS}
            -o "${AME_TABBAR_OBJ}"
            "${AME_TABBAR_SWIFT_SRC}"
    DEPENDS "${AME_TABBAR_SWIFT_SRC}"
    COMMENT "★ [SWIFT-BAR] swiftc ${AME_SWIFT_TRIPLE} -sdk ${CMAKE_OSX_SYSROOT} -> AmeTabBar.o"
    VERBATIM)
  add_custom_target(AmeTabBarSwift DEPENDS "${AME_TABBAR_OBJ}")
endif()

# 外部对象:CMake 只把它放进链接行,不去「编译」它
set_source_files_properties("${AME_TABBAR_OBJ}" PROPERTIES GENERATED TRUE EXTERNAL_OBJECT TRUE)
message(STATUS "★ [SWIFT-BAR] swiftc=${AME_SWIFTC} triple=${AME_SWIFT_TRIPLE} obj=${AME_TABBAR_OBJ} swiftlib=${AME_SWIFT_LIBDIR} build=${AME_TABBAR_NEEDS_BUILD}")

# Angel Aura Amethyst
add_executable(AngelAuraAmethyst
  dyld_bypass_validation.m
  dyld_patch_platform.m
  main.m
  main_hook.m
  # ★ [LINK511] 换底 5.1.0 时漏掉的 fork 独有源(上游 5.1.0 的 add_executable 里有):
  #   sdl3_hook.m 定义 ame_hook_getEmbeddedSDLView / ame_sdlVulkanWindowActive /
  #   amethyst_sdl3_hook_resolve(分别被 gl_bridge.m / egl_bridge.m / main_hook.m 引用);
  #   shaderc_include.c 为 Task 47 RenderPearl `#include <minecraft:...>` 展开器(上游 exe 列表成员)。
  sdl3_hook.m
  shaderc_include.c
  # ★ [SHADER-CAP] Metal 光影能力：GL 入口运行时探测 + 诚实扩展上报 + core→EXT 别名映射
  #   (只追加；被 sdl3_hook.m 引用，纯 C 编译为 ObjC 仅为用 NSLog)
  shader_cap_probe.m
  JavaLauncher.m
  external/fishhook/fishhook.c
  UIKit+hook.m
  UIViewController+AMEPanel.m   # 子面板原生基底样式(移植自 Gsjsjzhznsz 的 Air fork)
  NMToast.m                    # 应用内通知(移植自 Gsjsjzhznsz 的 Air fork)
  ScreenUtils.m

  authenticator/BaseAuthenticator.m
  authenticator/LocalAuthenticator.m
  authenticator/MicrosoftAuthenticator.m
  authenticator/ThirdPartyAuthenticator.m

  ctxbridges/gl_bridge.m
  ctxbridges/osm_bridge.m
  ctxbridges/vk_bridge.m
  # ★ [RENDERER-GAP] 新增渲染器运行时桥（纯追加）：gl4es 家族引导 + VirGL vtest 服务端。
  ctxbridges/gl4es_family_boot.m
  ctxbridges/virgl_server.m

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
  LauncherPreferencesViewController.m
  LauncherLanguageViewController.m   # ★ [LANG-SWITCH] 语言选择子页(跟随系统 + 枚举 .lproj)
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
  # ★ [LAUNCH-PROGRESS] 启动阶段上报 API(供 JavaLauncher / SurfaceViewController 调用)
  AmeLaunchProgress.m

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
  # ★ [LINK511] 换底 5.1.0 时漏掉(定义 UpdateDialogViewController,被 UpdateChecker.m 引用)
  UpdateDialogViewController.m

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

  # ★ [SWIFT-BAR] SwiftUI 底部标签栏目标文件(swiftc 产出;只追加,不动上面既有 OBJC 顺序)
  ${AME_TABBAR_OBJ}
  # ★ [ROOTTAB] 根标签栏控制器(真正的 UITabBarController;音乐/LiveContainer 同构)
  AmeRootTabController.m
)

# ★ [SWIFT-BAR] 保证 AmeTabBar.o 先于链接生成(独立 cmake 构建时走这条)
if(AME_TABBAR_NEEDS_BUILD)
  add_dependencies(AngelAuraAmethyst AmeTabBarSwift)
endif()

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
  # ★ [SWIFT-BAR] Swift 运行时:iOS 12.2+ 设备自带 /usr/lib/swift,SDK 里也有 .tbd
  #   ⇒ 只给链接器搜索路径 + rpath,不打包任何 Swift dylib、不改 CFBundle。
  "-L${AME_SWIFT_LIBDIR}"
  # ★ [SWIFT-BAR] 工具链里的回退兼容库(缺这条就报 Undefined _swift_FORCE_LOAD_$_swiftCompatibility56)
  "-L${AME_SWIFT_TOOLCHAIN_LIBDIR}"
  "-Wl,-rpath,/usr/lib/swift"
  ${TOUCHCONTROLLER_LIB}
  # Terracotta multiplayer 暂时移除：${TERRACOTTA_LIB} "-lc++" "-lresolv"
)
set_target_properties(AngelAuraAmethyst PROPERTIES
  MACOSX_BUNDLE TRUE
  MACOSX_FRAMEWORK_IDENTIFIER org.cmake.ExecutableTarget
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_LIST_DIR}/Info.plist")

# ============================================================================
# ★ [RENDERER-GAP] VGPU 渲染器（PojavLauncherTeam/VGPU，gl4es 分支）——可选目标。
#   来源：Gsjsjzhznsz/Air-Minecraft-iOS-Launcher 的 Natives/CMakeLists.txt（Task173）。
#   源码已 vendored 于 external/vgpu（含 Task173 的 iOS 移植补丁：pack/load.c 库名
#   指向 libGLESv2.framework、glx.c/printf_def.h 去 android/log.h）。
#   构建口径与 Android.mk 一致：-DNOX11 -DNO_GBM -DNOEGL -DDEFAULT_ES=3 -DSHAREDLIB。
#   双重 basename（pack/shader.c vs gl/shader.c）拆两个 OBJECT 库再链接，避免 .o 撞名。
#
#   默认【关闭】——不改变默认构建/现有渲染器。开启方式（任选其一）：
#     cmake -DAME_RENDERER_GAP_VGPU=ON ...      （native 目标透传见 Makefile RENDERER_GAP_EXTRAS）
#   产出 libvgpu.dylib，由 payload 的 "cp $(WORKINGDIR)/*.dylib" 自动带进 Frameworks。
# ============================================================================
option(AME_RENDERER_GAP_VGPU "Build the imported VGPU (gl4es fork) renderer dylib" OFF)
if(AME_RENDERER_GAP_VGPU)
  set(VGPU_DIR "${CMAKE_CURRENT_LIST_DIR}/external/vgpu")
  set(VGPU_PACK_SRC
    "${VGPU_DIR}/src/gl/pack/pack.c"
    "${VGPU_DIR}/src/gl/pack/load.c"
    "${VGPU_DIR}/src/gl/pack/Initialization.c"
    "${VGPU_DIR}/src/gl/pack/shaderconv.c"
    "${VGPU_DIR}/src/gl/pack/shader.c"
  )
  set(VGPU_CORE_SRC
    "${VGPU_DIR}/src/glx/hardext.c"
    "${VGPU_DIR}/src/glx/glx.c"
    "${VGPU_DIR}/src/glx/lookup.c"
    "${VGPU_DIR}/src/glx/gbm.c"
    "${VGPU_DIR}/src/glx/streaming.c"
    "${VGPU_DIR}/src/gl/arbconverter.c"
    "${VGPU_DIR}/src/gl/arbgenerator.c"
    "${VGPU_DIR}/src/gl/arbhelper.c"
    "${VGPU_DIR}/src/gl/arbparser.c"
    "${VGPU_DIR}/src/gl/array.c"
    "${VGPU_DIR}/src/gl/blend.c"
    "${VGPU_DIR}/src/gl/blit.c"
    "${VGPU_DIR}/src/gl/buffers.c"
    "${VGPU_DIR}/src/gl/build_info.c"
    "${VGPU_DIR}/src/gl/debug.c"
    "${VGPU_DIR}/src/gl/decompress.c"
    "${VGPU_DIR}/src/gl/depth.c"
    "${VGPU_DIR}/src/gl/directstate.c"
    "${VGPU_DIR}/src/gl/drawing.c"
    "${VGPU_DIR}/src/gl/enable.c"
    "${VGPU_DIR}/src/gl/envvars.c"
    "${VGPU_DIR}/src/gl/eval.c"
    "${VGPU_DIR}/src/gl/face.c"
    "${VGPU_DIR}/src/gl/fog.c"
    "${VGPU_DIR}/src/gl/fpe.c"
    "${VGPU_DIR}/src/gl/fpe_cache.c"
    "${VGPU_DIR}/src/gl/fpe_shader.c"
    "${VGPU_DIR}/src/gl/framebuffers.c"
    "${VGPU_DIR}/src/gl/gl_lookup.c"
    "${VGPU_DIR}/src/gl/getter.c"
    "${VGPU_DIR}/src/gl/gl4es.c"
    "${VGPU_DIR}/src/gl/glstate.c"
    "${VGPU_DIR}/src/gl/hint.c"
    "${VGPU_DIR}/src/gl/init.c"
    "${VGPU_DIR}/src/gl/light.c"
    "${VGPU_DIR}/src/gl/line.c"
    "${VGPU_DIR}/src/gl/list.c"
    "${VGPU_DIR}/src/gl/listdraw.c"
    "${VGPU_DIR}/src/gl/listrl.c"
    "${VGPU_DIR}/src/gl/loader.c"
    "${VGPU_DIR}/src/gl/logs.c"
    "${VGPU_DIR}/src/gl/matrix.c"
    "${VGPU_DIR}/src/gl/oldprogram.c"
    "${VGPU_DIR}/src/gl/pixel.c"
    "${VGPU_DIR}/src/gl/planes.c"
    "${VGPU_DIR}/src/gl/pointsprite.c"
    "${VGPU_DIR}/src/gl/preproc.c"
    "${VGPU_DIR}/src/gl/program.c"
    "${VGPU_DIR}/src/gl/queries.c"
    "${VGPU_DIR}/src/gl/raster.c"
    "${VGPU_DIR}/src/gl/render.c"
    "${VGPU_DIR}/src/gl/shader.c"
    "${VGPU_DIR}/src/gl/shaderconv.c"
    "${VGPU_DIR}/src/gl/shader_hacks.c"
    "${VGPU_DIR}/src/gl/stack.c"
    "${VGPU_DIR}/src/gl/stencil.c"
    "${VGPU_DIR}/src/gl/string_utils.c"
    "${VGPU_DIR}/src/gl/stubs.c"
    "${VGPU_DIR}/src/gl/texenv.c"
    "${VGPU_DIR}/src/gl/texgen.c"
    "${VGPU_DIR}/src/gl/texture.c"
    "${VGPU_DIR}/src/gl/texture_compressed.c"
    "${VGPU_DIR}/src/gl/texture_params.c"
    "${VGPU_DIR}/src/gl/texture_read.c"
    "${VGPU_DIR}/src/gl/texture_3d.c"
    "${VGPU_DIR}/src/gl/uniform.c"
    "${VGPU_DIR}/src/gl/vertexattrib.c"
    "${VGPU_DIR}/src/gl/wrap/gl4eswraps.c"
    "${VGPU_DIR}/src/gl/wrap/vgpu_darwin_aliases.c"
    "${VGPU_DIR}/src/gl/wrap/gles.c"
    "${VGPU_DIR}/src/gl/wrap/glstub.c"
    "${VGPU_DIR}/src/gl/math/matheval.c"
    "${VGPU_DIR}/src/gl/matvec.c"
  )
  add_library(vgpu_pack OBJECT ${VGPU_PACK_SRC})
  add_library(vgpu_core OBJECT ${VGPU_CORE_SRC})
  foreach(ame173_vgpu_tgt vgpu_pack vgpu_core)
    target_include_directories(${ame173_vgpu_tgt} PRIVATE "${VGPU_DIR}/include")
    target_compile_definitions(${ame173_vgpu_tgt} PRIVATE
      NOX11 NO_GBM NOEGL DEFAULT_ES=3 SHAREDLIB)
    target_link_libraries(${ame173_vgpu_tgt} "${GLOBAL_LDFLAGS}")
  endforeach()
  add_library(vgpu SHARED
    $<TARGET_OBJECTS:vgpu_pack>
    $<TARGET_OBJECTS:vgpu_core>
  )
  target_link_libraries(vgpu
    "${GLOBAL_LDFLAGS}"
    "-F'${CMAKE_CURRENT_LIST_DIR}/resources/Frameworks'"
    "-framework libEGL"
    "-framework libGLESv2"
  )
endif()
