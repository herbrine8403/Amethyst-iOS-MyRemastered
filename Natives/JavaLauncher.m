#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <libgen.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <mach/mach.h>
#include "utils.h"
#include "ZinkConfig.h"

// god knows why Copilot was trying to add this.
#import "authenticator/BaseAuthenticator.h"
#import "authenticator/ThirdPartyAuthenticator.h"
// 鬼知道为什么copilot要把这玩意加里头……

#import "ios_uikit_bridge.h"
#import "JavaLauncher.h"
#import "LauncherPreferences.h"
#import "PLLogOutputView.h"
#import "PLProfiles.h"

#define fm NSFileManager.defaultManager

extern char **environ;

BOOL validateVirtualMemorySpace(size_t size) {
    size <<= 20; // convert to MB
    void *map = mmap(0, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    // check if process successfully maps and unmaps a contiguous range
    if(map == MAP_FAILED || munmap(map, size) != 0)
        return NO;
    return YES;
}

void init_loadDefaultEnv() {
    /* Define default env */

    // Silent Caciocavallo NPE error in locating Android-only lib
    setenv("LD_LIBRARY_PATH", "", 1);

    // Ignore mipmap for performance(?) seems does not affect iOS
    //setenv("LIBGL_MIPMAP", "3", 1);

    // Disable overloaded functions hack for Minecraft 1.17+
    setenv("LIBGL_NOINTOVLHACK", "1", 1);

    // Fix white color on banner and sheep, since GL4ES 1.1.5
    setenv("LIBGL_NORMALIZE", "1", 1);

    // Override OpenGL version to 4.1 for Zink
    setenv("MESA_GL_VERSION_OVERRIDE", "4.1", 1);

    // Suppress [mvk-info] log spam (swapchain creation, etc.)
    // 对齐 Ynnyny 仓库：抑制 MoltenVK 日志刷屏，便于诊断启动问题
    // 但当帧率解锁开启时，临时启用性能跟踪以诊断 present mode 问题
    if (getPrefBool(@"video.disable_game_vsync")) {
        // 帧率解锁诊断：启用 MoltenVK 性能跟踪，输出帧率和 swapchain 信息
        // 有助于确认 Vulkan 模式下 present mode 是否为 IMMEDIATE
        setenv("MVK_CONFIG_PERFORMANCE_TRACKING", "1", 1);
        setenv("MVK_CONFIG_LOG_LEVEL", "2", 1); // 仍然抑制 info 级别，但 performance log 会输出
        // 尝试强制 present mode 为 IMMEDIATE（不等 vsync）。
        // MoltenVK 1.2.5+ 支持 MVK_CONFIG_SWAPCHAIN_PRESENT_MODE 环境变量：
        //   0 = VK_PRESENT_MODE_IMMEDIATE_KHR（不等 vsync，帧率可超屏幕刷新率）
        //   1 = VK_PRESENT_MODE_MAILBOX_KHR
        //   2 = VK_PRESENT_MODE_FIFO_KHR（默认，等 vsync）
        // 实际运行的 MoltenVK 版本为 1.2.9（从 libMoltenVK.dylib 二进制确认），
        // 支持此环境变量。仓库中的 vk_mvk_moltenvk.h 头文件是旧版本（1.1.2），
        // 但实际 dylib 已是 1.2.9，环境变量会生效。
        // 这是 Vulkan 模式帧率解锁的关键：present mode 完全由 vkCreateSwapchainKHR
        // 选择，而 MC 26.2 的 Vulkan 渲染器可能未正确响应 enableVsync=false。
        // MoltenVK 1.2.9 在 vkCreateSwapchainKHR 时会读取此环境变量覆盖应用的 presentMode。
        setenv("MVK_CONFIG_SWAPCHAIN_PRESENT_MODE", "0", 1);
        NSLog(@"[JavaLauncher] MoltenVK performance tracking + IMMEDIATE present mode requested for VSync diagnosis");
    } else {
        setenv("MVK_CONFIG_LOG_LEVEL", "2", 1);
    }

    // Runs JVM in a separate thread
    setenv("HACK_IGNORE_START_ON_FIRST_THREAD", "1", 1);

    // 解锁帧率（关闭垂直同步）：读取启动器偏好，通过环境变量传递给 Java 层和 native 桥接层。
    //
    // 帧率解锁的三层机制（各层独立生效，互为兜底）：
    //
    // 1. Java 层（PojavLauncher.java）读取 POJAV_DISABLE_VSYNC=1 后：
    //    a) 强制写 enableVsync=false → MC 不再调用 glfwSwapInterval(1)
    //    b) 强制写 maxFps=260 → MC 1.16+ 源码中 maxFps>=260 视为"无限制"
    //       （之前用 maxFps=0 会被 MC 当作无效值忽略，导致帧率仍被 maxFps=120 限制）
    //
    // 2. native 桥接层（egl_bridge.m pojavSwapInterval）读取 POJAV_DISABLE_VSYNC=1 后：
    //    拦截 MC 的 glfwSwapInterval(1) 请求，强制改为 interval=0
    //    （会记录每次拦截，帮助诊断 mod 运行时重新启用 VSync 的情况）
    //
    // 3. EGL 初始化层（gl_bridge.m gl_make_current）读取 POJAV_DISABLE_VSYNC=1 后：
    //    在 eglMakeCurrent 成功后立即调用 eglSwapInterval(0)。
    //    这是 zink 渲染器帧率解锁的关键——Mesa 21.0 的 zink 在延迟创建 Vulkan swapchain
    //    时根据当前 eglSwapInterval 选择 present mode：
    //      interval=0 → VK_PRESENT_MODE_IMMEDIATE_KHR（不等 vsync，帧率可超 60）
    //      interval=1 → VK_PRESENT_MODE_FIFO_KHR（等 vsync，锁在屏幕刷新率）
    //    如果等 MC 调用 glfwSwapInterval 时才设置，swapchain 可能已用 FIFO 创建，
    //    Mesa 21.0 的 zink 不会动态重建 swapchain，导致帧率锁死在屏幕刷新率。
    //
    // 关于 MoltenVK 配置与 Vulkan 帧率解锁研究：
    //   实际运行的 MoltenVK 版本为 1.2.9（从 libMoltenVK.dylib 二进制确认）。
    //   仓库中的 vk_mvk_moltenvk.h 头文件是旧版本（1.1.2, spec 30），
    //   但实际 dylib 已是 1.2.9，支持 MVK_CONFIG_SWAPCHAIN_PRESENT_MODE 环境变量。
    //   MoltenVK 1.2.9 在 vkCreateSwapchainKHR 时会读取此环境变量覆盖应用的 presentMode，
    //   这是 Vulkan 模式帧率解锁的关键机制。
    //   设备是否支持 IMMEDIATE present mode 由 MVKPhysicalDeviceMetalFeatures.presentModeImmediate
    //   自动检测（大多数 iOS 设备支持）。
    //
    //   Vulkan 模式帧率解锁的多层机制：
    //   1. MC 选项层：enableVsync=false + maxFps=260（MC 1.16+ 视 260 为 unlimited）
    //   2. MoltenVK 配置层：MVK_CONFIG_SWAPCHAIN_PRESENT_MODE=0 → IMMEDIATE present mode
    //      （MoltenVK 1.2.9 支持，覆盖应用在 vkCreateSwapchainKHR 选择的 presentMode）
    //   3. MC 26.2 兼容：同时写入 maxFps/maxFramerate/framerateLimit 多种选项名
    //
    // 各渲染器的帧率解锁效果：
    // - zink（GL→Vulkan）：通过 eglSwapInterval(0) → IMMEDIATE present mode 完全解锁
    // - Vulkan（LWJGL3）：MVK_CONFIG_SWAPCHAIN_PRESENT_MODE=0 → IMMEDIATE present mode 完全解锁
    // - ANGLE Metal：eglSwapInterval(0) 让 ANGLE 不等 vsync，渲染线程不阻塞
    // - ProMotion 设备：通过 CADisableMinimumFrameDurationOnPhone + preferredFrameRateRange 启用 120Hz
    setenv("POJAV_DISABLE_VSYNC", getPrefBool(@"video.disable_game_vsync") ? "1" : "0", 1);

    // 帧率解锁诊断日志：记录关键环境变量和偏好设置
    NSLog(@"[JavaLauncher] Framerate unlock configuration:");
    NSLog(@"[JavaLauncher]   video.disable_game_vsync=%d", getPrefBool(@"video.disable_game_vsync"));
    NSLog(@"[JavaLauncher]   POJAV_DISABLE_VSYNC=%s", getenv("POJAV_DISABLE_VSYNC"));
    NSLog(@"[JavaLauncher]   UIScreen.maximumFramesPerSecond=%d", (int)UIScreen.mainScreen.maximumFramesPerSecond);
}

void init_loadCustomEnv() {
    NSString *envvars = getPrefObject(@"java.env_variables");
    if (envvars == nil) return;
    NSLog(@"[JavaLauncher] Reading custom environment variables");
    for (NSString *line in [envvars componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (![line containsString:@"="]) {
            NSLog(@"[JavaLauncher] Warning: skipped empty value custom env variable: %@", line);
            continue;
        }
        NSRange range = [line rangeOfString:@"="];
        NSString *key = [line substringToIndex:range.location];
        NSString *value = [line substringFromIndex:range.location+range.length];
        setenv(key.UTF8String, value.UTF8String, 1);
        NSLog(@"[JavaLauncher] Added custom env variable: %@", line);
    }
}

/// 加载 MobileGlues 配置并写入 config.json
///
/// 将用户偏好设置写入 <POJAV_HOME>/MG/config.json，供 MobileGlues 渲染器读取。
///
/// 渲染器与 MobileGlues 的关系（重要）：
/// - MobileGlues 渲染器（libmobileglues.dylib）：直接加载 MobileGlues，config.json 生效。
/// - Auto 渲染器：由 PLResolveRendererKey 解析为 ANGLE（libtinygl4angle.dylib），
///   MobileGlues 不会被加载。用户需显式选择 MobileGlues 才能让这些设置生效。
/// - Vulkan 渲染器：Vulkan 模式下 OpenGL 回退库使用 MobileGlues（对齐 Ynnyny 仓库），
///   config.json 会被 MobileGlues 读取并生效。
void init_loadMobileGluesConfig() {
    NSString *renderer = PLResolveRendererKey([PLProfiles resolveKeyForCurrentProfile:@"renderer"]);
    NSLog(@"[JavaLauncher] init_loadMobileGluesConfig: renderer=%@", renderer);

    BOOL usesMobileGlues = [renderer isEqualToString:@ RENDERER_NAME_MOBILEGLUES] ||
        [renderer isEqualToString:@ RENDERER_NAME_VULKAN];

    if (!usesMobileGlues) {
        NSLog(@"[JavaLauncher] MobileGlues config not written (renderer is not mobileglues/auto/vulkan)");
        return;
    }

    if ([renderer isEqualToString:@ RENDERER_NAME_VULKAN]) {
        NSLog(@"[JavaLauncher] Vulkan renderer detected, MobileGlues used as GL fallback. Config will take effect.");
    } else {
        NSLog(@"[JavaLauncher] MobileGlues renderer detected, config will take effect.");
    }

    NSString *mgDirPath = [NSString stringWithFormat:@"%s/MG", getenv("POJAV_HOME")];
    setenv("MG_DIR_PATH", mgDirPath.UTF8String, 1);

    NSMutableDictionary *config = [NSMutableDictionary dictionary];

    // 安全默认值
    // 注意：MobileGlues 的 Version(int code) 构造函数把数字转为字符串后取前 3 位
    // 作为 Major.Minor.Patch（settings.h 第 102-116 行）。例如 40 → "40" → 4.0.0。
    // customGLVersion 约束（settings.cpp 第 71-79 行）：>46 截断为 46，<32 且非 0 截断为 32，
    // 33-39 截断为 33，0 使用默认值 40。
    // 因此必须写入十进制数（40, 41, 42, ..., 46），不能写入十六进制 0x040000。
    config[@"enableExtGL43"] = @1;
    config[@"enableExtDirectStateAccess"] = @1;
    config[@"maxGlslCacheSize"] = @128;
    config[@"customGLVersion"] = @40;  // 十进制 40 = GL 4.0

    id enableAngle = getPrefObject(@"mobileglues.enable_angle");
    if (enableAngle) {
        // MobileGlues AngleConfig 枚举（settings.h）：
        //   0 = DisableIfPossible
        //   1 = EnableIfPossible  ← iOS 上 hasVulkan12() 永远返回 0（#ifndef __APPLE__
        //                            块被跳过），导致 checkIfANGLESupported 返回 false，
        //                            ANGLE 被禁用。不能使用此值。
        //   2 = ForceDisable
        //   3 = ForceEnable       ← 强制启用，绕过 GPU 检测
        // 用户启用 enable_angle 时写入 3 (ForceEnable)，禁用时写入 0 (DisableIfPossible)
        config[@"enableANGLE"] = [enableAngle boolValue] ? @3 : @0;
        NSLog(@"[JavaLauncher]   mobileglues.enable_angle = %@ -> enableANGLE = %@ (3=ForceEnable, 0=DisableIfPossible)",
              enableAngle, config[@"enableANGLE"]);
    }

    id enableNoError = getPrefObject(@"mobileglues.enable_no_error");
    if (enableNoError) {
        config[@"enableNoError"] = @([enableNoError intValue]);
        NSLog(@"[JavaLauncher]   mobileglues.enable_no_error = %@ -> enableNoError = %@", enableNoError, config[@"enableNoError"]);
    }

    id enableExtTimerQuery = getPrefObject(@"mobileglues.enable_ext_timer_query");
    if (enableExtTimerQuery) {
        config[@"enableExtTimerQuery"] = [enableExtTimerQuery boolValue] ? @1 : @0;
        NSLog(@"[JavaLauncher]   mobileglues.enable_ext_timer_query = %@ -> enableExtTimerQuery = %@", enableExtTimerQuery, config[@"enableExtTimerQuery"]);
    }

    id enableExtComputeShader = getPrefObject(@"mobileglues.enable_ext_compute_shader");
    if (enableExtComputeShader) {
        config[@"enableExtComputeShader"] = [enableExtComputeShader boolValue] ? @1 : @0;
        NSLog(@"[JavaLauncher]   mobileglues.enable_ext_compute_shader = %@ -> enableExtComputeShader = %@", enableExtComputeShader, config[@"enableExtComputeShader"]);
    }

    id enableExtDirectStateAccess = getPrefObject(@"mobileglues.enable_ext_direct_state_access");
    if (enableExtDirectStateAccess) {
        config[@"enableExtDirectStateAccess"] = [enableExtDirectStateAccess boolValue] ? @1 : @0;
        NSLog(@"[JavaLauncher]   mobileglues.enable_ext_direct_state_access = %@ -> enableExtDirectStateAccess = %@", enableExtDirectStateAccess, config[@"enableExtDirectStateAccess"]);
    }

    id maxGlslCacheSize = getPrefObject(@"mobileglues.max_glsl_cache_size");
    if (maxGlslCacheSize) {
        config[@"maxGlslCacheSize"] = @([maxGlslCacheSize intValue]);
        NSLog(@"[JavaLauncher]   mobileglues.max_glsl_cache_size = %@ -> maxGlslCacheSize = %@", maxGlslCacheSize, config[@"maxGlslCacheSize"]);
    }

    id multidrawMode = getPrefObject(@"mobileglues.multidraw_mode");
    if (multidrawMode) {
        config[@"multidrawMode"] = @([multidrawMode intValue]);
        NSLog(@"[JavaLauncher]   mobileglues.multidraw_mode = %@ -> multidrawMode = %@", multidrawMode, config[@"multidrawMode"]);
    }

    id angleDepthClearFixMode = getPrefObject(@"mobileglues.angle_depth_clear_fix_mode");
    if (angleDepthClearFixMode) {
        config[@"angleDepthClearFixMode"] = [angleDepthClearFixMode boolValue] ? @1 : @0;
        NSLog(@"[JavaLauncher]   mobileglues.angle_depth_clear_fix_mode = %@ -> angleDepthClearFixMode = %@", angleDepthClearFixMode, config[@"angleDepthClearFixMode"]);
    }

    id customGlVersion = getPrefObject(@"mobileglues.custom_gl_version");
    if (customGlVersion) {
        NSString *verStr = [customGlVersion description];
        NSLog(@"[JavaLauncher]   mobileglues.custom_gl_version = %@ (raw)", customGlVersion);
        // MobileGlues 期望十进制数：Version(int code) 把 code 转字符串后取前 3 位作为
        // Major.Minor.Patch。例如 40 → "40" → 4.0.0，46 → "46" → 4.6.0。
        // 不能用十六进制 0x040000（=262144），会被截断为 46（4.6.0）。
        if ([verStr isEqualToString:@"3.0"]) config[@"customGLVersion"] = @30;
        else if ([verStr isEqualToString:@"3.1"]) config[@"customGLVersion"] = @31;
        else if ([verStr isEqualToString:@"3.2"]) config[@"customGLVersion"] = @32;
        else if ([verStr isEqualToString:@"3.3"]) config[@"customGLVersion"] = @33;
        else if ([verStr isEqualToString:@"4.0"]) config[@"customGLVersion"] = @40;
        else if ([verStr isEqualToString:@"4.1"]) config[@"customGLVersion"] = @41;
        else if ([verStr isEqualToString:@"4.2"]) config[@"customGLVersion"] = @42;
        else if ([verStr isEqualToString:@"4.3"]) config[@"customGLVersion"] = @43;
        else if ([verStr isEqualToString:@"4.4"]) config[@"customGLVersion"] = @44;
        else if ([verStr isEqualToString:@"4.5"]) config[@"customGLVersion"] = @45;
        else if ([verStr isEqualToString:@"4.6"]) config[@"customGLVersion"] = @46;
        // verStr == @"0" 时不匹配任何条件，保留默认值 @40（即 GL 4.0）
        NSLog(@"[JavaLauncher]   -> customGLVersion = %d (decimal, MobileGlues Version(int) format)",
              [config[@"customGLVersion"] intValue]);
    }

    id fsr1Setting = getPrefObject(@"mobileglues.fsr1_setting");
    if (fsr1Setting) {
        config[@"fsr1Setting"] = @([fsr1Setting intValue]);
        NSLog(@"[JavaLauncher]   mobileglues.fsr1_setting = %@ -> fsr1Setting = %@", fsr1Setting, config[@"fsr1Setting"]);
    }

    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:&error];
    if (jsonData) {
        NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        [fm createDirectoryAtPath:mgDirPath withIntermediateDirectories:YES attributes:nil error:nil];
        [jsonString writeToFile:[mgDirPath stringByAppendingPathComponent:@"config.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"[JavaLauncher] MobileGlues config written to %@/config.json", mgDirPath);
        NSLog(@"[JavaLauncher] config.json content:\n%@", jsonString);
    } else {
        NSLog(@"[JavaLauncher] Failed to serialize MobileGlues config: %@", error);
    }
}

void init_loadCustomJvmFlags(int* argc, const char** argv) {
    NSString *jvmargs = [PLProfiles resolveKeyForCurrentProfile:@"javaArgs"];
    if (jvmargs == nil) return;
    // Make the separator happy
    jvmargs = [jvmargs stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    jvmargs = [@" " stringByAppendingString:jvmargs];

    // 关键修复（N3+N4）：retainedCustomFlags 强引用所有自定义 JVM flag 字符串，
    // 防止 [@"-" stringByAppendingString:jvmarg].UTF8String 返回的 C 字符串悬垂。
    //
    // 之前 argv[*argc] = [@"-" stringByAppendingString:jvmarg].UTF8String 直接取临时
    // NSString 的 UTF8String，autoreleased NSString 在 runloop drain 后会释放，
    // 导致 argv 中的指针悬垂。虽然 launchJava 通常在 JVM 启动前不会 drain autoreleasepool，
    // 但这是脆弱的隐式依赖。retainedCustomFlags 作为静态变量，生命周期覆盖整个进程，
    // 保证字符串在 pJLI_Launch 调用期间有效。
    static NSMutableArray<NSString *> *retainedCustomFlags = nil;
    if (retainedCustomFlags == nil) {
        retainedCustomFlags = [NSMutableArray array];
    }
    // 注意：不清空 retainedCustomFlags，因为 launchJava 在进程生命周期内只调用一次。
    // 如果未来变为可多次调用，需要在调用前清空。

    NSLog(@"[JavaLauncher] Reading custom JVM flags");
    NSArray *argsToPurge = @[@"Xms", @"Xmx", @"d32", @"d64"];
    for (NSString *arg in [jvmargs componentsSeparatedByString:@" -"]) {
        NSString *jvmarg = [arg stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (jvmarg.length == 0) continue;
        BOOL ignore = NO;
        for (NSString *argToPurge in argsToPurge) {
            if ([jvmarg hasPrefix:argToPurge]) {
                NSLog(@"[JavaLauncher] Ignored JVM flag: -%@", jvmarg);
                ignore = YES;
                break;
            }
        }
        if (ignore) continue;

        // N3 边界检查：argv 数组大小由调用方决定（margv[1000]），这里做防御性检查
        if (*argc + 1 >= 1000) {
            NSLog(@"[JavaLauncher] Warning: margv reached limit (1000), discarding custom JVM flag: -%@", jvmarg);
            continue;
        }
        NSString *flagStr = [@"-" stringByAppendingString:jvmarg];
        [retainedCustomFlags addObject:flagStr];
        ++*argc;
        argv[*argc] = flagStr.UTF8String;

        NSLog(@"[JavaLauncher] Added custom JVM flag: %s", argv[*argc]);
    }
}

// 进程内 JVM 只能创建一次（第二次 JLI_Launch 会崩溃）。
// launchJVM 与 launchHeadlessJVM 在调用 JLI_Launch 前都会置位；
// launchJVM 检测到该标记时拒绝再次创建 JVM 并引导用户重启 app。
static BOOL gJvmUsedInProcess = NO;

BOOL JVMUsedInProcess(void) {
    return gJvmUsedInProcess;
}

int launchJVM(NSString *accountId, id launchTarget, int width, int height, int minVersion) {
    NSLog(@"[JavaLauncher] Beginning JVM launch");

    // 防御检查：headless JVM（Forge/NeoForge 直装 processors 阶段）已在当前进程
    // 创建过 JVM。进程内 JVM 只能创建一次，再次 JLI_Launch 必然崩溃。
    // 提示用户重启 app 后再启动游戏。
    if (gJvmUsedInProcess) {
        UIKit_returnToSplitView();
        showDialog(localize(@"Error", nil),
            @"A Java runtime was used by the mod installer in this session. "
            @"Please restart the launcher, then launch the game again.");
        return 1;
    }

    init_loadDefaultEnv();
    init_loadCustomEnv();

    // 同步自 catsruledogs：刷新 JIT flags，决定是否需要 Debug JIT Mapping
    // 使用 DeviceNeedsDebugJITMapping() 基于 JIT_FLAG_IS_IOS_26 | JIT_FLAG_FORCE_MIRRORED
    // 而非 TXM 固件检测，确保 iOS 26+ 无 TXM 设备也能正确设置 JIT 脚本
    DeviceGetJITFlags(YES);
    BOOL requiresDebugJITMapping = DeviceNeedsDebugJITMapping();
    BOOL jit26AlwaysAttached = getPrefBool(@"debug.debug_always_attached_jit");
    if (requiresDebugJITMapping) {
        // 检测是否在使用 legacy JIT script（brk #0x69 由 UniversalJIT26.js 处理）
        static void *result;
        if(!result) result = JIT26CreateRegionLegacy(getpagesize());
        if ((uint32_t)result != 0x690000E0) {
            munmap(result, getpagesize());
            // legacy script 只允许调用一次 breakpoint，必须切换到 UniversalJIT26
            NSString *inBundleScriptPath = [NSBundle.mainBundle pathForResource:@"UniversalJIT26" ofType:@"js"];
            NSString *lcAppInfoPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"LCAppInfo.plist"];
            NSMutableDictionary *lcAppInfo = [NSMutableDictionary dictionaryWithContentsOfFile:lcAppInfoPath];
            if(lcAppInfo) {
                // LiveContainer 内：自动分配 script 并提示用户重启
                lcAppInfo[@"jitLaunchScriptJs"] = [[NSData dataWithContentsOfFile:inBundleScriptPath] base64EncodedStringWithOptions:0];
                if([lcAppInfo writeToFile:lcAppInfoPath atomically:YES]) {
                    showDialog(localize(@"Error", nil), @"Amethyst was launched with a legacy script. We have updated the script to Universal, please restart LiveContainer to continue.");
                    [PLLogOutputView handleExitCode:1];
                    return 1;
                }
            }
            [NSFileManager.defaultManager copyItemAtPath:inBundleScriptPath toPath:[NSString stringWithFormat:@"%s/UniversalJIT26.js", getenv("POJAV_HOME")] error:nil];
            showDialog(localize(@"Error", nil), @"Support for legacy script has been removed. Please switch to Universal JIT script. To import it, long-press on Amethyst when enabling JIT in StikDebug and tap \"Assign Script\", then go to Amethyst's Documents directory and pick it. (on sideloaded StikDebug, the builtin script is named Amethyst-MeloNX.js)");
            [PLLogOutputView handleExitCode:1];
            return 1;
        }
        JIT26SendJITScript([NSString stringWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"UniversalJIT26Extension" ofType:@"js"]]);
        JIT26SetDetachAfterFirstBr(!jit26AlwaysAttached);
        // make sure we don't get stuck in EXC_BAD_ACCESS
        task_set_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, 0, EXCEPTION_DEFAULT, MACHINE_THREAD_STATE);
    }

    if (!requiresDebugJITMapping || jit26AlwaysAttached) {
        if (jit26AlwaysAttached) {
            // Only allow StikDebug to catch our breakpoints to prevent any stutters
            task_set_exception_ports(mach_task_self(), EXC_MASK_ALL & ~EXC_MASK_BREAKPOINT, 0,
                EXCEPTION_DEFAULT, THREAD_STATE_NONE);
        }
        // Activate Library Validation bypass for external runtime and dylibs (JNA, etc)
        init_bypassDyldLibValidation();
    } else {
        NSLog(@"[DyldLVBypass] Hook disabled! Loading unsigned dylib will cause code signature error.");
    }

    // 加载 MobileGlues 配置（仅当用户手动选择 MobileGlues 渲染器时生效）
    init_loadMobileGluesConfig();

    // --- [更新] TouchController 通信方式支持 ---
    // 检查是否启用了 TouchController 以及选择的通信方式
    if (getPrefBool(@"control.mod_touch_enable")) {
        NSInteger mode = [getPrefObject(@"control.mod_touch_mode") integerValue];
        if (mode == 1) { // UDP 模式
            setenv("TOUCH_CONTROLLER_PROXY", "12450", 1);
            NSLog(@"[JavaLauncher] Enabled TouchController with UDP mode");
        } else if (mode == 2) { // 静态库模式
            // 设置 Unix Domain Socket 路径
            setenv("TOUCH_CONTROLLER_PROXY_SOCKET", "/tmp/touchcontroller.sock", 1);
            NSLog(@"[JavaLauncher] Enabled TouchController with Static Library mode");
        }
    }
    // ------------------------------------------

    BOOL launchJar = NO;
    NSString *gameDir;
    NSString *defaultJRETag;
    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        // Get preferred Java version from current profile
        // 26.x 官方强制要求 Java 25（Mojang 自 26.x 起将 javaVersion.majorVersion 设为 25），
        // 不再对 preferredJavaVersion 做任何钳制，直接采纳 Profile 指定的 Java 版本。
        // caciocavallo 三路切换会根据实际 Java 版本选择对应 jar（三个独立文件夹）：
        // - Java 8     → libs_caciocavallo（1.10-SNAPSHOT）
        // - Java 17/21 → libs_caciocavallo17（1.18-SNAPSHOT 纯 Java 17 编译）
        // - Java 25    → libs_caciocavallo25（1.18-SNAPSHOT 含 Java 24 class，catsruledogs iOS）
        int preferredJavaVersion = [PLProfiles resolveKeyForCurrentProfile:@"javaVersion"].intValue;
        if (preferredJavaVersion > 0) {
            if (minVersion > preferredJavaVersion) {
                NSLog(@"[JavaLauncher] Profile's preferred Java version (%d) does not meet the minimum version (%d), dropping request", preferredJavaVersion, minVersion);
            } else {
                NSDebugLog(@"[PLProfiles] Applying javaVersion (%d)", preferredJavaVersion);
                minVersion = preferredJavaVersion;
            }
        }
        if (minVersion <= 8) {
            defaultJRETag = @"1_16_5_older";
        } else {
            defaultJRETag = @"1_17_newer";
        }

        // Setup AMETHYST_RENDERER
        NSString *selectedRenderer = [PLProfiles resolveKeyForCurrentProfile:@"renderer"];
        NSString *renderer = PLResolveRendererKey(selectedRenderer);
        NSLog(@"[JavaLauncher] RENDERER '%@' resolved to '%@'\n", selectedRenderer, renderer);
        setenv("AMETHYST_RENDERER", renderer.UTF8String, 1);

        // Apply Zink-specific environment variables if Zink renderer is selected
        // Mesa 25.0.7 zink 升级配套：根据设备 GPU 代际自动调优 MESA_GL_VERSION_OVERRIDE、
        // MESA_GLSL_VERSION_OVERRIDE、MESA_EXTENSION_OVERRIDE、mesa_glthread、shader cache 等。
        // ZinkConfig 默认 Auto 级别会保留所有光影所需的 GL 扩展（compute/tessellation/geometry
        // shader 等），仅禁用 MoltenVK 支持不佳的 Transform Feedback，不影响 Iris/OptiFine。
        if ([renderer hasPrefix:@"libOSMesa"]) {
            [ZinkConfig applyZinkEnvironmentFromPreferences];
            NSString *configSummary = [ZinkConfig activeConfigSummary];
            NSLog(@"[ZinkConfig] ========== Zink Renderer Active (Mesa 25) ==========");
            NSLog(@"[ZinkConfig] %@", configSummary);
            setenv("ZINK_ACTIVE_CONFIG", configSummary.UTF8String, 1);

            // 安装 zink vertex stride 4 字节对齐 fix
            // 修复 Mesa 25.0.7 zink + MoltenVK 在启用光影时因 stride 未 4 字节对齐
            // 导致 vkCreateGraphicsPipelines 失败 → SIGSEGV 的崩溃（详见 main_hook.m）
            // 必须在 libOSMesa 被 dlopen 之前调用，确保 fishhook 能拦截后续符号引用
            installZinkStrideFix();
        }

        // Apply LTW-specific environment variables if LTW renderer is selected
        // LTW (Large Thin Wrapper) OpenGL Core 3.3 → ES 3 转译层
        // 不设置 LTW_* 环境变量，使用 LTW main.c constructor 的默认值（与 Android 端一致）
        //   - LIBGL_ES：LTW 自动检测 ES 版本
        //   - LTW_NEVER_FLUSH_BUFFERS：默认 true
        //   - LTW_COHERENT_DYNAMIC_STORAGE：默认 true
        // 仅设置 POJAVEXEC_EGL 标识 EGL 由 LTW 提供（对齐 Android 端语义）
        if ([renderer isEqualToString:@ RENDERER_NAME_LTW]) {
            setenv("POJAVEXEC_EGL", RENDERER_NAME_LTW, 1);
            NSLog(@"[JavaLauncher] LTW renderer active: using LTW defaults (same as Android)");
        }
        // Setup AMETHYST_GRAPHICS_API（MC 26.2+ Graphics API：default/vulkan/opengl）
        // 仅 MC 26.2+ 识别此选项，旧版本 MC 会忽略 options.txt 中的 graphicsApi 字段。
        //
        // 关键修复（更改图形 API 无效）：
        //   之前仅当 graphicsApi 非空时才设置环境变量，导致：
        //   1. 用户从未设置过 graphicsApi 时环境变量缺失，Java 端无法清除旧值
        //   2. 环境变量缺失时 Java 端完全跳过 graphicsApi 处理逻辑
        //   现在始终设置环境变量（缺省为 "default"），让 Java 端每次启动都能正确处理：
        //   - "default"：清除 options.txt 中的 graphicsApi 行
        //   - prefer_vulkan/prefer_opengl：写入对应值
        NSString *graphicsApi = [PLProfiles resolveKeyForCurrentProfile:@"graphicsApi"];
        if (!graphicsApi || graphicsApi.length == 0) {
            graphicsApi = @"default";
        }
        setenv("AMETHYST_GRAPHICS_API", graphicsApi.UTF8String, 1);
        NSLog(@"[JavaLauncher] GRAPHICS_API is set to %@\n", graphicsApi);

        // Setup gameDir
        gameDir = [NSString stringWithFormat:@"%s/instances/%@/%@",
            getenv("POJAV_HOME"), getPrefObject(@"general.game_directory"),
            [PLProfiles resolveKeyForCurrentProfile:@"gameDir"]]
            .stringByStandardizingPath;
    } else {
        defaultJRETag = @"execute_jar";
        gameDir = @(getenv("POJAV_GAME_DIR"));
        launchJar = YES;
        // execute_jar 路径（如 OptiFine 安装器）的 caciocavallo 由三路切换自动处理：
        // 实际选中的 Java 运行时是哪个版本，就用对应目录的 caciocavallo jar。
        // 不再在此处对 minVersion 做任何强制提升或钳制。
    }

    // 26.x 版本官方强制要求 Java 25（Mojang 自 26.x 起将 javaVersion.majorVersion 设为 25）。
    // 不再钳制 Profile 的 javaVersion，26.x 必须使用 Java 25 启动。
    // caciocavallo 三路切换（参照 FCL/ZalithLauncher2 二元思路，扩展为三路以兼容 Java 25）：
    // 三个独立的平级文件夹，按实际 Java 版本选择：
    // - Java 8     → libs_caciocavallo（1.10-SNAPSHOT，包名 net.java.openjdk.cacio，bootclasspath/p）
    // - Java 17/21 → libs_caciocavallo17（1.18-SNAPSHOT 纯 Java 17 编译，包名 com.github.caciocavallosilano.cacio，bootclasspath/a）
    // - Java 25    → libs_caciocavallo25（1.18-SNAPSHOT 含 Java 24 class，包名 com.github.caciocavallosilano.cacio，bootclasspath/a）
    //   来自 catsruledogs/Amethyst-iOS-25。其 CTCGraphicsEnvironment 是 Java 24 class（class version 68），
    //   含 Java 25 兼容修复，纯 Java 17 编译版本会在 get_method_id 阶段 SIGSEGV。
    //   class version 68 仅 Java 24+ 可加载，故 Java 17/21 不能共用，需用 caciocavallo17 目录的纯 Java 17 jar。

    NSLog(@"[JavaLauncher] Looking for Java %d or later", minVersion);
    NSString *javaHome = getSelectedJavaHome(defaultJRETag, minVersion);

    if (javaHome == nil) {
        UIKit_returnToSplitView();
        BOOL isExecuteJar = [defaultJRETag isEqualToString:@"execute_jar"];
        showDialog(localize(@"Error", nil), [NSString stringWithFormat:localize(@"java.error.missing_runtime", nil),
            isExecuteJar ? [launchTarget lastPathComponent] : PLProfiles.current.selectedProfile[@"lastVersionId"], minVersion]);
        return 1;
    } else if ([javaHome hasPrefix:@(getenv("POJAV_HOME"))]) {
        // Symlink libawt_xawt.dylib
        NSString *dest = [NSString stringWithFormat:@"%@/lib/libawt_xawt.dylib", javaHome];
        NSString *source = [NSString stringWithFormat:@"%@/Frameworks/libawt_xawt.dylib", NSBundle.mainBundle.bundlePath];
        NSError *error;
        [fm createSymbolicLinkAtPath:dest withDestinationPath:source error:&error];
        if (error) {
            NSLog(@"[JavaLauncher] Symlink libawt_xawt.dylib failed: %@", error.localizedDescription);
        }
    }

    setenv("JAVA_HOME", javaHome.UTF8String, 1);
    NSLog(@"[JavaLauncher] JAVA_HOME has been set to %@", javaHome);

    int allocmem;
    if (getPrefBool(@"java.auto_ram")) {
        CGFloat autoRatio = getEntitlementValue(@"com.apple.private.memorystatus") ? 0.4 : 0.25;
        allocmem = roundf((NSProcessInfo.processInfo.physicalMemory >> 20) * autoRatio);
    } else {
        allocmem = getPrefInt(@"java.allocated_memory");
    }
    NSLog(@"[JavaLauncher] Max RAM allocation is set to %d MB", allocmem);
    if (!validateVirtualMemorySpace(allocmem)) {
        UIKit_returnToSplitView();
        if (getEntitlementValue(@"com.apple.developer.kernel.increased-memory-limit")) {
            showDialog(localize(@"Error", nil), @"Insufficient contiguous virtual memory space. Lower memory allocation and try again.");
        } else {
            showDialog(localize(@"Error", nil), @"Insufficient contiguous virtual memory space. Increased Memory Limit entitlement is missing, please add it via GetMoreRam app.");
        }
        return 1;
    }

    int margc = -1;
    const char *margv[1000];

    // 关键修复（N3+N4）：margv 边界检查 + 字符串生命周期管理
    //
    // N3（边界检查）：
    //   margv[1000] 是固定大小数组，每次 margv[++margc] = ... 都没有检查 margc 是否越界。
    //   如果未来扩展参数可能造成栈缓冲区溢出。这里通过 PUSH_MARGV_* 宏做防御性边界检查。
    //
    // N4（悬垂指针）：
    //   [NSString stringWithFormat:...].UTF8String 返回的 C 字符串指针依赖 autoreleased NSString
    //   的生命周期。当前 launchJVM 函数没有显式 @autoreleasepool 包裹整个函数体，autoreleased
    //   对象进入当前线程的 autorelease pool，到下一次 runloop drain 时才释放。由于函数末尾立即
    //   调用 pJLI_Launch(margc, margv, ...)，期间没有显式 drain，所以暂时安全。
    //   但这是脆弱的隐式依赖：如果将来有人在中间插入 @autoreleasepool 块或调用 drain，
    //   所有 margv 中由 stringWithFormat: 生成的指针会立即悬垂，导致 JVM 启动崩溃。
    //
    //   修复方案：用 retainedStrings 数组强引用所有通过 stringWithFormat: 创建的 NSString，
    //   确保其生命周期覆盖 pJLI_Launch 调用。retainedStrings 是局部 strong 引用，随函数
    //   退出自动释放，无需手动管理。
    NSMutableArray<NSString *> *retainedStrings = [NSMutableArray array];

    // 宏：安全地添加一个字面量参数到 margv
    // 字符串字面量（如 "-XstartOnFirstThread"）是静态存储期的 const char*，永不失效
    // 边界检查：margc 达到上限时停止添加，避免栈溢出
    #define PUSH_MARGV_LITERAL(literal) do { \
        if (margc + 1 < 1000) { \
            margv[++margc] = (literal); \
        } else { \
            NSLog(@"[JavaLauncher] Warning: margv reached limit (1000), discarding literal argument %s", (literal)); \
        } \
    } while (0)

    // 宏：通过 stringWithFormat: 构造参数并添加到 margv
    // 创建的 NSString 会被 retainedStrings 强引用，直到函数返回才释放，
    // 保证 margv 中保存的 UTF8String 指针在 pJLI_Launch 调用期间有效。
    // 注意：NSLog 警告消息不直接用 fmt 作为格式串（避免 % 被错误解析），仅打印字面量提示。
    #define PUSH_MARGV_FORMAT(ns_fmt, ...) do { \
        if (margc + 1 < 1000) { \
            NSString *_tmpStr = [NSString stringWithFormat:(ns_fmt), ##__VA_ARGS__]; \
            [retainedStrings addObject:_tmpStr]; \
            margv[++margc] = _tmpStr.UTF8String; \
        } else { \
            NSLog(@"[JavaLauncher] Warning: margv reached limit (1000), discarding formatted argument"); \
        } \
    } while (0)

    PUSH_MARGV_FORMAT(@"%@/bin/java", javaHome);
    PUSH_MARGV_LITERAL("-XstartOnFirstThread");
    if (!launchJar) {
        PUSH_MARGV_LITERAL("-Djava.system.class.loader=net.kdt.pojavlaunch.PojavClassLoader");
    }
    PUSH_MARGV_LITERAL("-Xms128M");
    PUSH_MARGV_FORMAT(@"-Xmx%dM", allocmem);
    // library.path: 单一 Frameworks 路径（对齐 Ynnyny 仓库）
    //
    // 关键修复（26.2 启动崩溃）：之前 workspace 将 LWJGL dylib 分裂为 lwjgl33/ 和 lwjgl34/ 子目录，
    // 并通过扫描版本 JSON 的 LWJGL 声明来选择路径。但 Ynnyny 仓库用单一 Frameworks 路径就能正常
    // 启动 26.2，证明分裂路径是多余的，且若 dylib 未按子目录正确摆放会导致加载错误版本 native 库。
    //
    // 现对齐 Ynnyny：所有 native dylib（含 LWJGL 专属和共享库）统一放在 Frameworks/ 根目录，
    // library.path = Frameworks。定制版 root lwjgl.jar（含 iOS 专用 LWJGL 补丁）通过 JavaApp/Makefile
    // 合并进最终 lwjgl.jar，确保 LWJGL 在 iOS 上能正确加载 GL 实现。
    NSString *frameworksPath = [NSString stringWithFormat:@"%@/Frameworks", NSBundle.mainBundle.bundlePath];
    PUSH_MARGV_FORMAT(@"-Djava.library.path=%@", frameworksPath);
    NSLog(@"[JavaLauncher] library.path = %@", frameworksPath);
    PUSH_MARGV_FORMAT(@"-Duser.dir=%@", gameDir);
    PUSH_MARGV_FORMAT(@"-Duser.home=%s", getenv("POJAV_HOME"));
    PUSH_MARGV_FORMAT(@"-Duser.timezone=%@", NSTimeZone.localTimeZone.name);
    PUSH_MARGV_FORMAT(@"-DUIScreen.maximumFramesPerSecond=%d", (int)UIScreen.mainScreen.maximumFramesPerSecond);

    // 发布 GameSurfaceView 指针，供 Metallum Metal 后端使用
    // +[SurfaceViewController surface] 返回静态变量 pojavWindow，该变量在
    // -[SurfaceViewController viewDidLoad] 中被赋值（早于 launchMinecraft 派发到本后台线程）。
    // 通过系统属性传递指针，可避免 JVM 渲染线程通过 ObjC runtime 查找 UIView 的不确定性。
    Class surfaceVCClass = NSClassFromString(@"SurfaceViewController");
    if (surfaceVCClass && [surfaceVCClass respondsToSelector:@selector(surface)]) {
        id surfaceView = [surfaceVCClass performSelector:@selector(surface)];
        if (surfaceView) {
            PUSH_MARGV_FORMAT(@"-Dmetallum.ios.view.pointer=%p", surfaceView);
            PUSH_MARGV_FORMAT(@"-Dmetallum.ios.screen.scale=%g", (double)UIScreen.mainScreen.scale);
            NSLog(@"[JavaLauncher] Published Metallum surface view: %p (scale=%g)", surfaceView, (double)UIScreen.mainScreen.scale);
        } else {
            NSLog(@"[JavaLauncher] Warning: +[SurfaceViewController surface] returned nil, Metallum will fall back to ObjC runtime lookup");
        }
    } else {
        NSLog(@"[JavaLauncher] Warning: SurfaceViewController class unavailable, Metallum will fall back to ObjC runtime lookup");
    }

    PUSH_MARGV_LITERAL("-Dorg.lwjgl.glfw.checkThread0=false");
    PUSH_MARGV_LITERAL("-Dorg.lwjgl.system.allocator=system");
    //PUSH_MARGV_LITERAL("-Dorg.lwjgl.util.NoChecks=true");
    PUSH_MARGV_LITERAL("-Dlog4j2.formatMsgNoLookups=true");

    // ============================================================================
    // JNA 加载路径
    // ============================================================================
    // JNA 5.13.0 的 darwin-aarch64 libjnidispatch 从 JAR 中提取后能正常加载。
    // Tools.java / MinecraftResourceUtils.m 已强制将 JNA 替换为 5.13.0
    // （MC 26.3+ 要求的 5.17.0 在 iOS 上会导致 native crash）。
    // 保留 boot.library.path 以便未来内置 iOS arm64 版 libjnidispatch。
    PUSH_MARGV_FORMAT(@"-Djna.boot.library.path=%@", frameworksPath);

    // ============================================================================
    // 帧率解锁第四层：JVM 系统属性
    // ============================================================================
    // 某些 MC 版本/mod 可能通过 System.getProperty 读取帧率限制。
    // 设置 -Dmax.fps=260 作为 options.txt 之外的额外兜底层。
    // 不影响不读取此属性的版本。
    if (getPrefBool(@"video.disable_game_vsync")) {
        PUSH_MARGV_LITERAL("-Dmax.fps=260");
        NSLog(@"[JavaLauncher] Added JVM property -Dmax.fps=260 (frame rate unlock layer 4)");
    }

    // ============================================================================
    // ZeroTier 联机 SOCKS5 代理注入 —— 暂时移除（排查启动崩溃）
    // ============================================================================
    // 原逻辑：检测 AMETHYST_SOCKS5_PROXY 环境变量，注入 -DsocksProxyHost/-DsocksProxyPort
    // ZeroTier 暂时移除后，MultiplayerManager 不再设置该环境变量，此块代码注释掉
    // ============================================================================
    // const char *socks5ProxyEnv = getenv("AMETHYST_SOCKS5_PROXY");
    // if (socks5ProxyEnv && socks5ProxyEnv[0] != '\0') {
    //     NSString *proxyStr = [NSString stringWithUTF8String:socks5ProxyEnv];
    //     NSRange colonRange = [proxyStr rangeOfString:@":"];
    //     if (colonRange.location != NSNotFound && colonRange.location > 0 &&
    //         colonRange.location + 1 < proxyStr.length) {
    //         NSString *proxyHost = [proxyStr substringToIndex:colonRange.location];
    //         NSString *proxyPortStr = [proxyStr substringFromIndex:colonRange.location + 1];
    //         NSInteger portValue = [proxyPortStr integerValue];
    //         if (portValue > 0 && portValue <= 65535) {
    //             PUSH_MARGV_FORMAT(@"-DsocksProxyHost=%@", proxyHost);
    //             PUSH_MARGV_FORMAT(@"-DsocksProxyPort=%@", proxyPortStr);
    //             NSString *nonProxyHosts = @"localhost|127.*|[::1]|"
    //                                       @"*.minecraft.net|*.mojang.com|"
    //                                       @"*.microsoft.com|*.microsoftonline.com|"
    //                                       @"*.xboxlive.com|*.modrinth.com|"
    //                                       @"*.curseforge.com|*.githubusercontent.com|"
    //                                       @"*.github.com|*.amazonaws.com|"
    //                                       @"*.cloudfront.net|*.akamaihd.net|"
    //                                       @"10.*|192.168.*|172.16.*|172.17.*|172.18.*|"
    //                                       @"172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|"
    //                                       @"172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|"
    //                                       @"172.29.*|172.30.*|172.31.*";
    //             PUSH_MARGV_FORMAT(@"-DsocksNonProxyHosts=%@", nonProxyHosts);
    //             NSLog(@"[JavaLauncher] Injected ZeroTier SOCKS5 proxy: %@:%@", proxyHost, proxyPortStr);
    //         }
    //     }
    // }

    // Preset OpenGL libname
    const char *glLibName = getenv("AMETHYST_RENDERER");
    if (glLibName) {
        if (strcmp(glLibName, RENDERER_NAME_VULKAN) == 0) {
            // 对齐 Ynnyny 仓库：Vulkan 模式下 OpenGL 回退库使用 MobileGlues
            //
            // libMoltenVK 是 Vulkan loader，不是 GL 实现；绑定它为 opengl.libname 会导致
            // LWJGL 查找 GL 符号失败。但 MC 26.2 的 NativeLibrariesBootstrap.loadOpenGL()
            // 在启动时会初始化 org.lwjgl.opengl.GL（无论游戏最终用哪个渲染器）。
            // 若 opengl.libname 未设置，LWJGL 回退到 MacOSXLibraryBundle.getWithIdentifier
            // ("com.apple.opengl")，iOS 上无系统 OpenGL framework 会失败 →
            //   UnsatisfiedLinkError: Failed to retrieve bundle with identifier: com.apple.opengl
            // 指向 libmobileglues.dylib：MobileGlues 专为 GL-on-Metal/Vulkan 设计，
            // 已使用 shipped libspirv-cross.dylib 做着色器翻译。GL.create() 能找到 GL 函数指针；
            // 若 MC 调用 GL 入口（compat 代码、着色器构建等），MobileGlues 能通过 Vulkan 路由，
            // 而非像无上下文的 gl4es 那样崩溃。
            //
            // 注意：vulkan.libname 不在此设置（对齐 Ynnyny），由 PojavLauncher.java 通过
            // System.setProperty("org.lwjgl.vulkan.libname", "MoltenVK") 设置。
            // 若在此用 -D 传 "libMoltenVK.dylib"，LWJGL Library.loadNative 会加 "lib" 前缀和
            // ".dylib" 后缀，得到 "liblibMoltenVK.dylib.dylib"（错误文件名）。
            //
            // MoltenVK 配置（对齐 Ynnyny）：
            // - RESUME_LOST_DEVICE=1：设备丢失后自动恢复
            // - SYNCHRONOUS_QUEUE_SUBMITS=1：同步队列提交（更稳定，避免竞争）
            // - PREFILL_METAL_COMMAND_BUFFERS=1：预填充 Metal 命令缓冲区（减少 GPU 等待，性能优化）
            setenv("MVK_CONFIG_RESUME_LOST_DEVICE", "1", 1);
            setenv("MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS", "1", 1);
            setenv("MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS", "1", 1);
        }
        // 对齐 Ynnyny：使用独立变量 openglLibName，不修改 glLibName（保持原值用于后续判断）
        const char *openglLibName = (strcmp(glLibName, RENDERER_NAME_VULKAN) == 0)
            ? RENDERER_NAME_MOBILEGLUES
            : glLibName;

        PUSH_MARGV_FORMAT(@"-Dorg.lwjgl.opengl.libname=%s", openglLibName);

        // 关键修复（参照 FCL，阶段4：26.2 图形 API 切换无效）：
        // 之前仅在 renderer=libMoltenVK.dylib 时由 PojavLauncher.java 通过 System.setProperty 设置
        // org.lwjgl.vulkan.libname，导致用户保留默认 renderer=auto（解析为 ANGLE）并切换
        // graphicsApi=prefer_vulkan 时，LWJGL 找不到 Vulkan 库 → MC 静默回退 OpenGL。
        //
        // FCL 做法：在 JVM 启动前通过 -D 系统属性同时确定 OpenGL 和 Vulkan 两条路径的 native 库，
        // 无论 MC 最终选哪条路都能找到对应的库。
        //
        // 传裸名 "MoltenVK"，LWJGL Library.loadNative 会自动加 "lib" 前缀和 ".dylib" 后缀，
        // 得到 "libMoltenVK.dylib"（正确文件名）。若传 "libMoltenVK.dylib" 会被包装成
        // "liblibMoltenVK.dylib.dylib"（错误文件名）。
        //
        // 安全性：即使 MC 最终走 GL 路径，加载 MoltenVK 也无副作用（GL 路径不调用 Vulkan 入口）。
        PUSH_MARGV_LITERAL("-Dorg.lwjgl.vulkan.libname=MoltenVK");

        // 显式指定 spirv-cross 库名（参照 catsruledogs/Amethyst-iOS-25）：
        // LWJGL spvc 模块默认查找 "spirv-cross" -> 加载 libspirv-cross.dylib（macOS 标准名），
        // 但实际文件名为 libspirv-cross-c-shared.0.dylib（带版本后缀的 SO 名）。
        // 显式设置 -Dorg.lwjgl.spvc.libname=spirv-cross-c-shared.0，LWJGL 的 Library.loadNative
        // 会对 libname 加 "lib" 前缀和 ".dylib" 后缀，得到 "libspirv-cross-c-shared.0.dylib"，
        // 从 library.path（Frameworks）找到该文件。
        PUSH_MARGV_LITERAL("-Dorg.lwjgl.spvc.libname=spirv-cross-c-shared.0");
    }

      // 添加authlib-injector参数以支持第三方认证账户的皮肤显示
    if ([accountId length] > 0 && [BaseAuthenticator.current isKindOfClass:[ThirdPartyAuthenticator class]]) {
        BaseAuthenticator *currentAuth = BaseAuthenticator.current;
        if (currentAuth.authData[@"authserver"] != nil) {
            NSLog(@"[JavaLauncher] Adding authlib-injector arguments for third party account");
            NSArray *authlibArgs = [(ThirdPartyAuthenticator *)currentAuth getJvmArgsForAuthlib];
            if (authlibArgs.count > 0) {
                for (NSString *arg in authlibArgs) {
                    // arg 来自 authlibArgs 数组，是 strong 引用；但数组本身可能在循环外
                    // 被释放，为防止悬垂，通过 PUSH_MARGV_FORMAT 持久化
                    PUSH_MARGV_FORMAT(@"%@", arg);
                    NSLog(@"[JavaLauncher] Added authlib-injector arg: %s", arg.UTF8String);
                }     
            } else {
                NSLog(@"[JavaLauncher] Warning: No authlib-injector arguments available");
            }
        }
    }
  
    NSString *librariesPath = [NSString stringWithFormat:@"%@/libs", NSBundle.mainBundle.bundlePath];
    PUSH_MARGV_FORMAT(@"-javaagent:%@/patchjna_agent.jar=", librariesPath);
    if(getPrefBool(@"general.cosmetica")) {
        PUSH_MARGV_FORMAT(@"-javaagent:%@/arc_dns_injector.jar=23.95.137.176", librariesPath);
    }
    if(getPrefBool(@"video.fix_simple_voice_chat_mod")) {
        PUSH_MARGV_FORMAT(@"-javaagent:%@/patchsvc.jar=", librariesPath);
    }

    // Workaround random stack guard allocation crashes
    PUSH_MARGV_LITERAL("-XX:+UnlockExperimentalVMOptions");
    PUSH_MARGV_LITERAL("-XX:+DisablePrimordialThreadGuardPages");

    // 关键修复（liblwjgl_stb SIGILL 崩溃，CodeCache 满）：
    //   崩溃日志显示 "CodeCache is full. Compiler has been disabled." 紧接 SIGILL
    //   at liblwjgl_stb.dylib+0x4d26c。复现路径包括：
    //   - 1.16.5 + libOSMesa + zink + MoltenVK（Java 8）
    //   - 1.20.1 + Forge + mobileglues（Java 17）
    //   说明根因与渲染器无关，是 CodeCache 容量不足。
    //
    //   项目从未设置 CodeCache 参数，完全依赖 JVM 默认值：
    //   - Java 8 默认 ReservedCodeCacheSize=48MB
    //   - Java 17+ 默认 240MB（仍可能在大量 native 加载下紧张）
    //
    //   CodeCache 满后 JIT 编译中的方法被部分无效化，CPU 执行到损坏的指令序列
    //   → SIGILL（崩溃点落在 liblwjgl_stb 是因为 stb_truetype 字体光栅化是首个
    //   大量 JIT 的 native wrapper，与渲染器无关）。
    //
    //   修复：设置为 64m，对 Java 8/17/21/25 全部生效。
    //   - 64m 仍比 Java 8 默认值（48MB）大 33%，足够避免 CodeCache 满导致的 SIGILL
    //   - InitialCodeCacheSize=16m 避免启动时立即触发 CodeCache 扩容（默认 2.25m
    //     会多次扩容，每次扩容都触发全局锁）
    //   - CodeCacheExpansionSize=4m 减少扩容次数（默认 64K 太小）
    //   - +UnlockExperimentalVMOptions 已在上一行启用，无需重复
    //
    //   iOS 27 SIGBUS fix (non-TXM devices, e.g. A15):
    //   On iOS 26+, -XX:+MirrorMappedCodeCache maps JIT code into RX memory
    //   allocated by the StikDebug debugger. With 256m, the mirrored region
    //   extends into pages whose executability is unreliable, causing intermittent
    //   SIGBUS when JIT-compiled code lands on those pages. The crash is
    //   intermittent because it depends on how much JIT code the JVM generates
    //   at runtime - if it stays within the safe region, the app exits normally.
    //   Reducing to 64m constrains the mirror mapping within the debugger's
    //   reliably allocated RX region, eliminating the SIGBUS.
    //   Repro: iOS 27 + A15 (no TXM) + StikDebug + Java 21 (MC 1.21.1).
    //   Java 25 (MC 26.2+) is unaffected - its JIT handles mirror mapping
    //   more robustly and doesn't trigger the crash even with 256m.
    PUSH_MARGV_LITERAL("-XX:ReservedCodeCacheSize=64m");
    PUSH_MARGV_LITERAL("-XX:InitialCodeCacheSize=16m");
    PUSH_MARGV_LITERAL("-XX:CodeCacheExpansionSize=4m");

    // On iOS 26, use mirror mapped JIT by default
    if (@available(iOS 26.0, *)) {
        PUSH_MARGV_LITERAL("-XX:+MirrorMappedCodeCache");
    }

    // Disable Forge 1.16.x early progress window
    PUSH_MARGV_LITERAL("-Dfml.earlyprogresswindow=false");

    // Load java
    NSString *libjlipath8 = [NSString stringWithFormat:@"%@/lib/jli/libjli.dylib", javaHome]; // java 8
    NSString *libjlipath11 = [NSString stringWithFormat:@"%@/lib/libjli.dylib", javaHome]; // java 11+
    BOOL isJava8 = [fm fileExistsAtPath:libjlipath8];

    // ============================================================================
    // JVM 性能优化（保守参数，不影响启动稳定性）
    // ============================================================================
    // 仅对 Java 17+ 启用 G1GC 调优。Java 8 的 G1GC 不够成熟，保持默认 SerialGC。
    // 不添加 -XX:+AlwaysPreTouch（延长启动时间）、-XX:TieredStopAtLevel=1（降低 JIT 性能）、
    // -XX:CICompilerCount=1（减少编译线程）等可能影响游戏体验的参数。
    // -XX:+UnlockExperimentalVMOptions 已在上方添加，UseStringDeduplication 需要实验模式。
    if (!isJava8) {
        // G1GC：Java 9+ 默认 GC，显式启用确保一致性。
        // 适合大堆内存（MC 通常分配 2-4GB），减少 Full GC 停顿。
        PUSH_MARGV_LITERAL("-XX:+UseG1GC");
        // 目标 GC 停顿 50ms（默认 200ms）。
        // 这是一个软目标，JVM 会尽量满足但不强制，不会导致 OOM。
        // 对 MC 的实时渲染有益，减少 GC 引起的卡顿。
        PUSH_MARGV_LITERAL("-XX:MaxGCPauseMillis=50");
        // 字符串去重：G1GC 特性，自动去重老年代中相同值的 String 对象。
        // MC 有大量重复字符串（方块名、物品名、I18N key 等），可节省 5-10% 堆内存。
        // 仅在 G1GC 下生效，开销极小。
        PUSH_MARGV_LITERAL("-XX:+UseStringDeduplication");
        NSLog(@"[JavaLauncher] JVM GC optimization: G1GC + MaxGCPauseMillis=50 + StringDeduplication (Java 17+)");
    } else {
        NSLog(@"[JavaLauncher] Java 8 detected, skipping G1GC tuning (using default GC)");
    }

    setenv("INTERNAL_JLI_PATH", (isJava8 ? libjlipath8 : libjlipath11).UTF8String, 1);
    void* libjli = dlopen(getenv("INTERNAL_JLI_PATH"), RTLD_GLOBAL);

    if (!libjli) {
        const char *error = dlerror();
        NSLog(@"[Init] JLI lib = NULL: %s", error);
        UIKit_returnToSplitView();
        showDialog(localize(@"Error", nil), @(error));
        return 1;
    }

    // Setup Caciocavallo
    PUSH_MARGV_LITERAL("-Djava.awt.headless=false");
    PUSH_MARGV_LITERAL("-Dcacio.font.fontmanager=sun.awt.X11FontManager");
    PUSH_MARGV_LITERAL("-Dcacio.font.fontscaler=sun.font.FreetypeFontScaler");
    PUSH_MARGV_FORMAT(@"-Dcacio.managed.screensize=%dx%d", width, height);
    PUSH_MARGV_LITERAL("-Dswing.defaultlaf=javax.swing.plaf.metal.MetalLookAndFeel");
    if (isJava8) {
        // Setup Caciocavallo
        PUSH_MARGV_LITERAL("-Dawt.toolkit=net.java.openjdk.cacio.ctc.CTCToolkit");
        PUSH_MARGV_LITERAL("-Djava.awt.graphicsenv=net.java.openjdk.cacio.ctc.CTCGraphicsEnvironment");
    } else {
        // 启用 native access（Java 17+ 支持，Java 25 强制要求）。
        // 参照 catsruledogs/Amethyst-iOS-25：Java 25 对受限方法（@Restricted，含 JNI、
        // sun.misc.Unsafe、Foreign API）的限制更严格，缺失此参数会导致 caciocavallo/LWJGL/JNA
        // 的 native access 触发警告路径，在 bootclasspath/a 未命名模块类上可能引发
        // get_method_id 访问不一致的类元数据导致 SIGSEGV（26.2 启动崩溃的根因）。
        // 日志中 "WARNING: Use --enable-native-access=ALL-UNNAMED to avoid a warning"
        // 也明确提示需要此参数。Java 17/21 添加此参数无副作用，统一在非 Java 8 分支添加。
        // 关键修复（26.2 启动崩溃）：删除 --enable-native-access=ALL-UNNAMED（对齐 Ynnyny 仓库）
        // Ynnyny 仓库不添加此参数也能正常启动 26.2，证明之前的诊断（Java 25 必需）是错误的。
        // 该参数会改变未命名模块的受限方法警告路径，可能干扰 bootclasspath/a 上 caciocavallo
        // 类的初始化顺序。

        // Required by Cosmetica to inject DNS
        PUSH_MARGV_LITERAL("--add-opens=java.base/java.net=ALL-UNNAMED");

        // Setup Caciocavallo
        PUSH_MARGV_LITERAL("-Dawt.toolkit=com.github.caciocavallosilano.cacio.ctc.CTCToolkit");
        PUSH_MARGV_LITERAL("-Djava.awt.graphicsenv=com.github.caciocavallosilano.cacio.ctc.CTCGraphicsEnvironment");

        // Required by Caciocavallo17 to access internal API
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/java.awt=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/java.awt.peer=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/sun.awt.image=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/sun.java2d=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/java.awt.dnd.peer=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/sun.awt=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/sun.awt.event=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/sun.awt.datatransfer=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/sun.font=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.base/sun.security.action=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-opens=java.base/java.util=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-opens=java.desktop/java.awt=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-opens=java.desktop/sun.font=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-opens=java.desktop/sun.java2d=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-opens=java.base/java.lang.reflect=ALL-UNNAMED");
        // 参照 catsruledogs/Amethyst-iOS-25：不添加 sun.awt / sun.awt.image / java.awt.peer 的
        // add-opens。catsruledogs 不加这些 opens 也能正常启动 26.2 + Java 25。
        // workspace 之前多加这 3 条 opens 会导致 Java 25 上 GE 提前初始化，
        // 在 caciocavallo25 的 CTCGraphicsEnvironment 注册完成前触发 get_method_id → SIGSEGV。
        // 纯 Java 17 编译版 caciocavallo17（Java 17/21 用）不依赖这些 opens，
        // 其 CTCGraphicsEnvironment 通过 --add-exports（上方已添加）即可访问所需内部 API。

        // cpw.mods.bootstraplauncher 模块导出：所有 Java 版本均添加（参照 catsruledogs/Amethyst-iOS-25）。
        // 之前仅对 Java 17/21 添加、Java 25 跳过，导致 26.2 + Java 25 启动时类加载混乱，
        // 最终在 get_method_id 阶段 SIGSEGV。catsruledogs 对所有版本统一添加此导出且能正常启动 26.2。
        // TODO: workaround, will be removed once the startup part works without PLaunchApp
        PUSH_MARGV_LITERAL("--add-exports=cpw.mods.bootstraplauncher/cpw.mods.bootstraplauncher=ALL-UNNAMED");
    }

    // Add Caciocavallo bootclasspath
    // 关键修复（26.2 启动崩溃）：caciocavallo 二元切换（对齐 Ynnyny 仓库）
    //
    // 之前 workspace 误判"纯 Java 17 编译版会在 Java 25 上 get_method_id SIGSEGV"，
    // 引入了 caciocavallo25（catsruledogs Java 24 class jar）三路切换。
    // 但 Ynnyny 仓库用纯 Java 17 编译版 caciocavallo17 启动 26.2 完全正常，
    // 证明该诊断是错误的。catsruledogs jar 的 Java 24 class 反而可能是真正的崩溃源。
    //
    // 现对齐 Ynnyny：二元切换
    //   - Java 8     → libs_caciocavallo（1.10-SNAPSHOT，bootclasspath/p）
    //   - Java 17/21/25 → libs_caciocavallo17（1.18-SNAPSHOT 纯 Java 17 编译，bootclasspath/a）
    const char *cacio_bootclasspath_mode;
    NSString *cacio_libs_path;
    if (isJava8) {
        // Java 8: 1.10-SNAPSHOT，bootclasspath/p（前置，覆盖 java.awt 实现）
        cacio_bootclasspath_mode = "p";
        cacio_libs_path = [NSString stringWithFormat:@"%@/libs_caciocavallo", NSBundle.mainBundle.bundlePath];
    } else {
        // Java 17/21/25: 1.18-SNAPSHOT 纯 Java 17 编译（class version 61），bootclasspath/a
        cacio_bootclasspath_mode = "a";
        cacio_libs_path = [NSString stringWithFormat:@"%@/libs_caciocavallo17", NSBundle.mainBundle.bundlePath];
    }
    NSLog(@"[JavaLauncher] Caciocavallo: isJava8=%d libs=%@ mode=/%s",
          isJava8, cacio_libs_path.lastPathComponent, cacio_bootclasspath_mode);

    NSString *cacio_classpath = [NSString stringWithFormat:@"-Xbootclasspath/%s", cacio_bootclasspath_mode];
    NSArray *files = [fm contentsOfDirectoryAtPath:cacio_libs_path error:nil];
    for(NSString *file in files) {
        // 所有 cacio jar 均放入 -Xbootclasspath/a（或 /p for Java 8）。
        // 参照 catsruledogs/Amethyst-iOS-25：不使用 --patch-module，不使用 stub-surface-manager.jar。
        // 之前用 --patch-module 或 stub jar 注入 sun.java2d.SurfaceManagerFactory，
        // 会破坏 java.desktop 模块封装，导致 get_method_id SIGSEGV。
        if ([file hasSuffix:@".jar"]) {
            cacio_classpath = [NSString stringWithFormat:@"%@:%@/%@", cacio_classpath, cacio_libs_path, file];
        }
    }
    PUSH_MARGV_FORMAT(@"%@", cacio_classpath);

    // stub-surface-manager.jar 已删除（见上方注释）。不再使用 --patch-module。
    // CTCPreloadClassLoader.<clinit> 抛出的 ClassNotFoundException 被吞掉，不影响启动。

    if (!getEntitlementValue(@"com.apple.developer.kernel.extended-virtual-addressing")) {
        // In jailed environment, where extended virtual addressing entitlement isn't
        // present (for free dev account), allocating compressed space fails.
        // FIXME: does extended VA allow allocating compressed class space?
        PUSH_MARGV_LITERAL("-XX:-UseCompressedClassPointers");
    }

    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        for (NSString *arg in launchTarget[@"arguments"][@"jvm_processed"]) {
            // arg 来自 launchTarget[@"arguments"][@"jvm_processed"] 数组，是 strong 引用；
            // 但 launchTarget 可能在循环结束后被释放，为防止悬垂，通过 PUSH_MARGV_FORMAT 持久化
            PUSH_MARGV_FORMAT(@"%@", arg);
        }
    }

    init_loadCustomJvmFlags(&margc, (const char **)margv);
    NSLog(@"[Init] Found JLI lib");

    // 关键修复（26.2 启动崩溃）：单一 lwjgl.jar（对齐 Ynnyny 仓库）
    // 之前 workspace 分裂为 lwjgl.jar 和 lwjgl33.jar，现对齐 Ynnyny 用单一合并 jar。
    // 定制版 root lwjgl.jar（含 iOS 专用 LWJGL 补丁）已通过 JavaApp/Makefile 合并进 lwjgl.jar。
    NSString *lwjglJar = [NSString stringWithFormat:@"%@/lwjgl.jar", librariesPath];
    NSLog(@"[JavaLauncher] Using LWJGL jar at %@", lwjglJar);

    // 校验目标 LWJGL jar 是否存在，避免静默崩溃
    if (![fm fileExistsAtPath:lwjglJar]) {
        UIKit_returnToSplitView();
        showDialog(localize(@"Error", nil), [NSString stringWithFormat:@"LWJGL jar missing: %@", [lwjglJar lastPathComponent]]);
        return 1;
    }

    NSMutableString *classpathBuilder = [NSMutableString string];
    NSArray *libFiles = [fm contentsOfDirectoryAtPath:librariesPath error:nil];
    for (NSString *libFile in libFiles) {
        // 精确排除合并后的 LWJGL jar，避免重复；保留其他以 lwjgl 开头的依赖 jar
        if ([libFile hasSuffix:@".jar"] &&
            ![libFile isEqualToString:@"lwjgl.jar"]) {
            [classpathBuilder appendFormat:@"%@/%@:", librariesPath, libFile];
        }
    }
    [classpathBuilder appendString:lwjglJar];
    NSString *classpath = classpathBuilder;
    if (launchJar) {
        // JAR 放在 classpath 最前面，避免 bundle libs 中的同名类（gson/guava/kotlin-stdlib 等）
        // 优先加载，导致 installer 自带依赖被遮蔽引发 NoSuchMethodError/LinkageError
        // 标准 `java -jar` 语义下 JAR 本应是唯一 classpath，此处保留 bundle libs 仅因 PojavLauncher
        // 与 UIKit bridge 类需要加载，但 installer 自身依赖应优先
        classpath = [NSString stringWithFormat:@"%@:%@", launchTarget, classpath];
    }
    PUSH_MARGV_LITERAL("-cp");
    PUSH_MARGV_FORMAT(@"%@", classpath);
    PUSH_MARGV_LITERAL("net.kdt.pojavlaunch.PojavLauncher");

    if (launchJar) {
        PUSH_MARGV_LITERAL("-jar");
    } else {
        PUSH_MARGV_FORMAT(@"%@", accountId);
    }

    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        PUSH_MARGV_FORMAT(@"%@", launchTarget[@"id"]);
        // 传递服务器地址给 PojavLauncher（FCL 风格）：
        // 留空传 @"", Java 端据此判断不追加任何参数；非空则由 Java 端按 MC 版本
        // 解析为 --server/--port 或 --quickPlayMultiplayer
        NSString *serverIp = [PLProfiles.current serverIpForCurrentProfile] ?: @"";
        PUSH_MARGV_FORMAT(@"%@", serverIp);
    } else {
        PUSH_MARGV_FORMAT(@"%@", launchTarget);
    }
    //PUSH_MARGV_LITERAL("ghidra.GhidraRun");

    pJLI_Launch = (JLI_Launch_func *)dlsym(libjli, "JLI_Launch");

    if (NULL == pJLI_Launch) {
        NSLog(@"[Init] JLI_Launch = NULL");
        return -2;
    }

    NSLog(@"[Init] Calling JLI_Launch");

    // Cr4shed known issue: exit after crash dump,
    // reset signal handler so that JVM can catch them
    signal(SIGSEGV, SIG_DFL);
    signal(SIGPIPE, SIG_DFL);
    signal(SIGBUS, SIG_DFL);
    signal(SIGILL, SIG_DFL);
    signal(SIGFPE, SIG_DFL);

    // Free split VC
    tmpRootVC = nil;

    // 标记进程内 JVM 已创建（此后任何 JLI_Launch 都会崩溃，需重启 app）
    gJvmUsedInProcess = YES;

    return pJLI_Launch(++margc, margv,
                   0, NULL, // sizeof(const_jargs) / sizeof(char *), const_jargs,
                   0, NULL, // sizeof(const_appclasspath) / sizeof(char *), const_appclasspath,
                   // These values are ignored in Java 17, so keep it anyways
                   "1.8.0-internal",
                   "1.8",

                   "java", "openjdk",
                   /* (const_jargs != NULL) ? JNI_TRUE : */ JNI_FALSE,
                   JNI_TRUE, JNI_FALSE, JNI_TRUE);
}

// ============================================================================
// Headless JVM（Forge/NeoForge 直装 processors 执行）
// ============================================================================
// 参照 launchJVM 的环境初始化与 JIT 前置，但 JVM 参数最小化：
// - 无 caciocavallo / LWJGL / 渲染相关参数
// - -Djava.awt.headless=true（processor 不需要图形环境）
// - -cp 仅含 bundle libs（launcher.jar 内含 ForgeProcessorRunner，gson 等依赖也在其中）
//
// iOS 禁止 fork/exec，无法像 ZL2 那样为每个 processor spawn 子 JVM，
// 但官方 Forge/NeoForge installer 本身就是在单个 JVM 内以 IsolatedClassLoader
// 逐个执行 processor 的（ForgeProcessorRunner 复刻该行为）。
//
// 注意：调用后进程内 JVM 已创建，游戏启动必须重启 app（见 gJvmUsedInProcess）。
int launchHeadlessJVM(NSString *mainClass, NSArray<NSString *> *args, int minJavaVersion) {
    NSLog(@"[JavaLauncher] Beginning headless JVM launch: %@ (minJava=%d)", mainClass, minJavaVersion);

    if (!mainClass.length) {
        NSLog(@"[JavaLauncher] launchHeadlessJVM: mainClass is empty");
        return -6;
    }

    // 进程内 JVM 只能创建一次
    if (gJvmUsedInProcess) {
        NSLog(@"[JavaLauncher] launchHeadlessJVM: JVM already created in this process, restart required");
        return -5;
    }

    // JIT 前置检查：processor 执行与游戏一样依赖 JIT（HotSpot 始终 JIT 编译，
    // 无 JIT 时必然 SIGILL 崩溃）。提前给出明确错误而不是让 JVM 莫名崩溃。
    if (!isJITEnabled(NO)) {
        NSLog(@"[JavaLauncher] launchHeadlessJVM: JIT is not enabled, cannot run processors");
        showDialog(localize(@"Error", nil),
            @"Java JIT is not enabled. Forge/NeoForge installation requires JIT.\n"
            @"Please enable JIT (e.g. via StikDebug) and try again.");
        return -1;
    }

    init_loadDefaultEnv();
    init_loadCustomEnv();

    // 与 launchJVM 相同的 JIT26 处理（iOS 26+ 无 TXM 设备需要 Debug JIT Mapping）
    DeviceGetJITFlags(YES);
    BOOL requiresDebugJITMapping = DeviceNeedsDebugJITMapping();
    BOOL jit26AlwaysAttached = getPrefBool(@"debug.debug_always_attached_jit");
    if (requiresDebugJITMapping) {
        static void *result;
        if (!result) result = JIT26CreateRegionLegacy(getpagesize());
        if ((uint32_t)result != 0x690000E0) {
            munmap(result, getpagesize());
            NSString *inBundleScriptPath = [NSBundle.mainBundle pathForResource:@"UniversalJIT26" ofType:@"js"];
            NSString *lcAppInfoPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"LCAppInfo.plist"];
            NSMutableDictionary *lcAppInfo = [NSMutableDictionary dictionaryWithContentsOfFile:lcAppInfoPath];
            if (lcAppInfo) {
                lcAppInfo[@"jitLaunchScriptJs"] = [[NSData dataWithContentsOfFile:inBundleScriptPath] base64EncodedStringWithOptions:0];
                if ([lcAppInfo writeToFile:lcAppInfoPath atomically:YES]) {
                    showDialog(localize(@"Error", nil), @"Amethyst was launched with a legacy script. We have updated the script to Universal, please restart LiveContainer to continue.");
                    return -1;
                }
            }
            [NSFileManager.defaultManager copyItemAtPath:inBundleScriptPath toPath:[NSString stringWithFormat:@"%s/UniversalJIT26.js", getenv("POJAV_HOME")] error:nil];
            showDialog(localize(@"Error", nil), @"Support for legacy script has been removed. Please switch to Universal JIT script. To import it, long-press on Amethyst when enabling JIT in StikDebug and tap \"Assign Script\", then go to Amethyst's Documents directory and pick it. (on sideloaded StikDebug, the builtin script is named Amethyst-MeloNX.js)");
            return -1;
        }
        JIT26SendJITScript([NSString stringWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"UniversalJIT26Extension" ofType:@"js"]]);
        JIT26SetDetachAfterFirstBr(!jit26AlwaysAttached);
        task_set_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, 0, EXCEPTION_DEFAULT, MACHINE_THREAD_STATE);
    }

    if (!requiresDebugJITMapping || jit26AlwaysAttached) {
        if (jit26AlwaysAttached) {
            task_set_exception_ports(mach_task_self(), EXC_MASK_ALL & ~EXC_MASK_BREAKPOINT, 0,
                EXCEPTION_DEFAULT, THREAD_STATE_NONE);
        }
        init_bypassDyldLibValidation();
    } else {
        NSLog(@"[DyldLVBypass] Hook disabled! Loading unsigned dylib will cause code signature error.");
    }

    // JRE 选择：按 minJavaVersion 推断 runtime tag（≥17 用 1_17_newer，否则 1_16_5_older），
    // 失败回退 execute_jar。getSelectedJavaHome 内部会在 tag 槽位不满足 minVersion 时
    // 搜索任意满足版本要求的 runtime。
    NSString *defaultJRETag = (minJavaVersion >= 17) ? @"1_17_newer" : @"1_16_5_older";
    NSString *javaHome = getSelectedJavaHome(defaultJRETag, minJavaVersion);
    if (javaHome == nil) {
        javaHome = getSelectedJavaHome(@"execute_jar", minJavaVersion);
    }
    if (javaHome == nil) {
        NSLog(@"[JavaLauncher] launchHeadlessJVM: no Java runtime >= %d available", minJavaVersion);
        showDialog(localize(@"Error", nil), [NSString stringWithFormat:localize(@"java.error.missing_runtime", nil),
            @"Forge/NeoForge installer", minJavaVersion]);
        return -3;
    }
    setenv("JAVA_HOME", javaHome.UTF8String, 1);
    NSLog(@"[JavaLauncher] Headless JAVA_HOME set to %@", javaHome);

    // user.home 指向独立临时目录，避免 processor 向主目录写入缓存
    NSString *gameDir = @(getenv("POJAV_GAME_DIR"));
    NSString *procHome = [gameDir stringByAppendingPathComponent:@".temp/forge_processor_home"];
    [[NSFileManager defaultManager] createDirectoryAtPath:procHome
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    // dlopen libjli（Java 8 与 Java 11+ 双路径，对齐 launchJVM）
    NSString *libjlipath8 = [NSString stringWithFormat:@"%@/lib/jli/libjli.dylib", javaHome];
    NSString *libjlipath11 = [NSString stringWithFormat:@"%@/lib/libjli.dylib", javaHome];
    BOOL isJava8 = [fm fileExistsAtPath:libjlipath8];
    setenv("INTERNAL_JLI_PATH", (isJava8 ? libjlipath8 : libjlipath11).UTF8String, 1);
    void *libjli = dlopen(getenv("INTERNAL_JLI_PATH"), RTLD_GLOBAL);
    if (!libjli) {
        const char *error = dlerror();
        NSLog(@"[JavaLauncher] launchHeadlessJVM: JLI lib = NULL: %s", error ?: "unknown");
        return -4;
    }
    pJLI_Launch = (JLI_Launch_func *)dlsym(libjli, "JLI_Launch");
    if (pJLI_Launch == NULL) {
        NSLog(@"[JavaLauncher] launchHeadlessJVM: JLI_Launch = NULL");
        return -2;
    }

    // 构造最小化 JVM 参数
    int margc = -1;
    const char *margv[256];
    NSMutableArray<NSString *> *retainedStrings = [NSMutableArray array];

    #define PUSH_HARGV_LITERAL(literal) do { \
        if (margc + 1 < 256) { \
            margv[++margc] = (literal); \
        } else { \
            NSLog(@"[JavaLauncher] launchHeadlessJVM: margv limit reached, discarding %s", (literal)); \
        } \
    } while (0)

    #define PUSH_HARGV_FORMAT(ns_fmt, ...) do { \
        if (margc + 1 < 256) { \
            NSString *_tmpStr = [NSString stringWithFormat:(ns_fmt), ##__VA_ARGS__]; \
            [retainedStrings addObject:_tmpStr]; \
            margv[++margc] = _tmpStr.UTF8String; \
        } else { \
            NSLog(@"[JavaLauncher] launchHeadlessJVM: margv limit reached, discarding formatted argument"); \
        } \
    } while (0)

    PUSH_HARGV_FORMAT(@"%@/bin/java", javaHome);
    PUSH_HARGV_LITERAL("-XstartOnFirstThread");
    // headless：无 AWT/Swing 图形环境
    PUSH_HARGV_LITERAL("-Djava.awt.headless=true");
    PUSH_HARGV_LITERAL("-Xms64M");
    PUSH_HARGV_LITERAL("-Xmx1G");
    PUSH_HARGV_FORMAT(@"-Djava.library.path=%@/Frameworks", NSBundle.mainBundle.bundlePath);
    PUSH_HARGV_FORMAT(@"-Duser.dir=%@", gameDir);
    PUSH_HARGV_FORMAT(@"-Duser.home=%@", procHome);
    PUSH_HARGV_FORMAT(@"-Duser.timezone=%@", NSTimeZone.localTimeZone.name);
    PUSH_HARGV_LITERAL("-Dlog4j2.formatMsgNoLookups=true");
    // Workaround random stack guard allocation crashes（对齐 launchJVM）
    PUSH_HARGV_LITERAL("-XX:+UnlockExperimentalVMOptions");
    PUSH_HARGV_LITERAL("-XX:+DisablePrimordialThreadGuardPages");
    // CodeCache 参数（对齐 launchJVM：避免 CodeCache 满导致 SIGILL；
    // iOS 26+ mirror mapped JIT 需要 64m 以内避免 SIGBUS）
    PUSH_HARGV_LITERAL("-XX:ReservedCodeCacheSize=64m");
    PUSH_HARGV_LITERAL("-XX:InitialCodeCacheSize=16m");
    PUSH_HARGV_LITERAL("-XX:CodeCacheExpansionSize=4m");
    if (@available(iOS 26.0, *)) {
        PUSH_HARGV_LITERAL("-XX:+MirrorMappedCodeCache");
    }
    if (!getEntitlementValue(@"com.apple.developer.kernel.extended-virtual-addressing")) {
        PUSH_HARGV_LITERAL("-XX:-UseCompressedClassPointers");
    }

    // classpath：bundle libs 下全部 jar（launcher.jar 含 ForgeProcessorRunner，gson 等也在其中）
    NSString *librariesPath = [NSString stringWithFormat:@"%@/libs", NSBundle.mainBundle.bundlePath];
    NSMutableString *classpathBuilder = [NSMutableString string];
    NSArray *libFiles = [fm contentsOfDirectoryAtPath:librariesPath error:nil];
    for (NSString *libFile in libFiles) {
        if ([libFile hasSuffix:@".jar"]) {
            [classpathBuilder appendFormat:@"%@/%@:", librariesPath, libFile];
        }
    }
    if (classpathBuilder.length > 0 && [classpathBuilder hasSuffix:@":"]) {
        [classpathBuilder deleteCharactersInRange:NSMakeRange(classpathBuilder.length - 1, 1)];
    }
    PUSH_HARGV_LITERAL("-cp");
    PUSH_HARGV_FORMAT(@"%@", classpathBuilder);

    // main class 与其参数
    PUSH_HARGV_FORMAT(@"%@", mainClass);
    for (NSString *arg in args) {
        if (margc + 1 < 256) {
            [retainedStrings addObject:arg];
            margv[++margc] = arg.UTF8String;
        } else {
            NSLog(@"[JavaLauncher] launchHeadlessJVM: margv limit reached, discarding extra argument");
        }
    }

    // Cr4shed known issue（对齐 launchJVM）：重置信号处理器让 JVM 能捕获崩溃信号
    signal(SIGSEGV, SIG_DFL);
    signal(SIGPIPE, SIG_DFL);
    signal(SIGBUS, SIG_DFL);
    signal(SIGILL, SIG_DFL);
    signal(SIGFPE, SIG_DFL);

    NSLog(@"[JavaLauncher] Calling JLI_Launch (headless, %d args)", margc + 1);

    // 标记进程内 JVM 已创建（此后任何 JLI_Launch 都会崩溃，需重启 app）
    gJvmUsedInProcess = YES;

    int ret = pJLI_Launch(++margc, margv,
                   0, NULL,
                   0, NULL,
                   "1.8.0-internal",
                   "1.8",
                   "java", "openjdk",
                   JNI_FALSE,
                   JNI_TRUE, JNI_FALSE, JNI_TRUE);
    NSLog(@"[JavaLauncher] Headless JLI_Launch returned %d", ret);
    return ret;
}
