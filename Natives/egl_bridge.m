#import "SurfaceViewController.h"

#include "jni.h"
#include <assert.h>
#include <dlfcn.h>

#include <pthread.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>

#include "EGL/egl.h"
#include "EGL/eglext.h"
#include "GL/osmesa.h"

#include "glfw_keycodes.h"
#include "ctxbridges/bridge_tbl.h"
#include "ctxbridges/osmesa_internal.h"
#include "utils.h"

// 默认 GL 路径（GLFW_OPENGL_API）而非 0（=GLFW_NO_API）。
// 关键修复（SDL3 模式 FPS/首帧误报）：
//   MC 26.3-snapshot-4+ 切换到 SDL3 后不再调用 glfwWindowHint(GLFW_CLIENT_API, ...)，
//   pojavInit() 也从不被执行（它是 GLFW 入口）。若 clientAPI 默认 0（=GLFW_NO_API），
//   pojavIsActualVulkanPath() 会错误返回 true，导致 displayLink 走 Vulkan fallback
//   路径，在游戏真正渲染前就发送 "First frame rendered" 通知，启动器提前移除启动遮罩
//   显示黑屏。默认 GLFW_OPENGL_API 对所有 GL 渲染器（MobileGlues/ANGLE/gl4es/zink）
//   正确；SDL3 + Vulkan 渲染器的情况在 pojavIsActualVulkanPath() 中单独判定。
int clientAPI = GLFW_OPENGL_API;

// FPS 计数器（参照 FCL egl_bridge.c 的 atomic_uint 实现）
// 在 pojavSwapBuffers() 中累加，在 SurfaceViewController 读取时重置
static atomic_uint _pojavFpsCounter = 0;

// 阶段13：首帧渲染检测标志（参照 FCL 的 game_ready 回调）
// pojavSwapBuffers() 首次调用时置为 YES 并发送通知，SurfaceViewController 据此移除启动遮罩
static BOOL s_firstFrameRendered = NO;

unsigned int pojavGetAndResetFps() {
    return atomic_exchange(&_pojavFpsCounter, 0);
}

/// 显式递增 FPS 计数器（供 Vulkan 模式使用）
///
/// Vulkan 渲染器不经过 EGL 的 pojavSwapBuffers 路径，而是通过 MoltenVK 的
/// vkQueuePresentKHR 直接 present。因此 pojavSwapBuffers 中的 FPS 计数逻辑
/// 不会触发。SurfaceViewController 在 Vulkan 模式下使用 CADisplayLink 作为
/// 帧率检测 fallback，每帧通过此函数递增计数器。
void pojavIncrementFpsCounter() {
    atomic_fetch_add(&_pojavFpsCounter, 1);

    // 首帧渲染检测（与 pojavSwapBuffers 中的逻辑一致）
    if (!s_firstFrameRendered) {
        s_firstFrameRendered = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"PojavFirstFrameRendered" object:nil];
            NSLog(@"[egl_bridge] First frame rendered (Vulkan displayLink path), game is ready");
        });
    }
}

/// 运行时判定 MC 真实渲染路径是否为 Vulkan。
///
/// 修复 FPS 显示错误的根本问题：
/// 之前 SurfaceViewController 在 viewDidLoad 时通过 graphicsApi 字符串静态推断
/// 是否启用 CADisplayLink fallback 递增 FPS 计数器。但：
///   - graphicsApi=default 时由 MC 内部决定，无法预判（保守起见启用 fallback）
///   - 但若 MC 实际选了 GL 路径，pojavSwapBuffers 也会计数，导致双重计数
///   - 反之若 graphicsApi=prefer_vulkan 但 MC 启动失败回退到 GL，fallback 会错误递增
///
/// 通过 clientAPI 运行时信号（由 MC 调用 glfwWindowHint(GLFW_CLIENT_API, ...) 写入）
/// 可以准确判定 MC 当前实际走的渲染路径：
///   - GLFW_NO_API（0）→ Vulkan 路径，pojavSwapBuffers 不被调用，需要 fallback
///   - 其他值（GLFW_OPENGL_API 等）→ GL 路径，pojavSwapBuffers 会计数，禁用 fallback
///
/// PLDisplayLinkTarget.displayLinkTick: 每帧动态查询此函数，确保 fallback 启用状态
/// 与 MC 实际渲染路径一致，避免双重计数或漏计数。
bool pojavIsActualVulkanPath() {
    // GLFW 模式：clientAPI 由 pojavSetWindowHint(GLFW_CLIENT_API, ...) 写入，
    // pojavInit() 初始化为 GLFW_OPENGL_API。MC 调用 glfwWindowHint(GLFW_NO_API)
    // 切换到 Vulkan 路径。
    if (clientAPI == GLFW_NO_API) return true;

    // SDL3 模式（MC 26.3-snapshot-4+）：MC 不调用 glfwWindowHint，pojavInit() 也
    // 从不执行，clientAPI 保持默认值 GLFW_OPENGL_API。对于 Vulkan 渲染器
    // （libMoltenVK.dylib），需要通过渲染器选择判定为 Vulkan 路径。
    // 注意：这会把 "Vulkan 渲染器 + prefer_opengl" 也判为 Vulkan，但 SDL3 模式下
    // 无法精确区分（MC 不经过 GLFW clientAPI 信号）。此误判仅影响 FPS 计数器
    // fallback 路径选择，不影响实际渲染（pojavCreateContext 在 SDL3 模式不被调用）。
    const char *windowingBackend = getenv("AMETHYST_WINDOWING_BACKEND");
    if (windowingBackend && strcmp(windowingBackend, "sdl") == 0) {
        const char *renderer = getenv("AMETHYST_RENDERER");
        if (renderer && strcmp(renderer, RENDERER_NAME_VULKAN) == 0) {
            return true;
        }
    }
    return false;
}

void JNI_LWJGL_changeRenderer(const char* value_c) {
    JNIEnv *env;
    (*runtimeJavaVMPtr)->GetEnv(runtimeJavaVMPtr, (void **)&env, JNI_VERSION_1_4);
    jstring key = (*env)->NewStringUTF(env, "org.lwjgl.opengl.libname");
    jstring value = (*env)->NewStringUTF(env, value_c);
    jclass clazz = (*env)->FindClass(env, "java/lang/System");
    jmethodID method = (*env)->GetStaticMethodID(env, clazz, "setProperty", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
    (*env)->CallStaticObjectMethod(env, clazz, method, key, value);
}

void pojavTerminate() {
    CallbackBridge_nativeSetInputReady(NO);
    if (!br_terminate) return;
    br_terminate();
}

void* pojavGetCurrentContext() {
    return br_get_current();
}

int pojavInit(BOOL useStackQueue) {
    clientAPI = GLFW_OPENGL_API;
    isInputReady = 1;
    isUseStackQueueCall = useStackQueue;
    return JNI_TRUE;
}

int pojavInitOpenGL() {
    NSString *renderer = NSProcessInfo.processInfo.environment[@"AMETHYST_RENDERER"];
    BOOL isAuto = [renderer isEqualToString:@"auto"];
    if (isAuto || [renderer isEqualToString:@ RENDERER_NAME_GL4ES]) {
        // At this point, if renderer is still auto (unspecified major version), pick gl4es
        renderer = @ RENDERER_NAME_GL4ES;
        setenv("AMETHYST_RENDERER", renderer.UTF8String, 1);
        set_gl_bridge_tbl();
    } else if ([renderer isEqualToString:@ RENDERER_NAME_MOBILEGLUES]) {
        renderer = @ RENDERER_NAME_MOBILEGLUES;
        setenv("AMETHYST_RENDERER", renderer.UTF8String, 1);
        set_gl_bridge_tbl();
    } else if ([renderer isEqualToString:@ RENDERER_NAME_MITHRIL]) {
        // Mithril-Wapper - OpenGL 3.3 Core Profile → Metal 翻译层
        // 与 MobileGlues 同属纯 GL 翻译层 dylib（导出 EGL/GL 符号，内部走
        // glslang + SPIRV-Cross 做 GLSL → SPIR-V → MSL 即时转译，落到原生
        // Metal 后端），因此集成方式与 MobileGlues 完全一致：复用 GL bridge。
        // 区别：Mithril 目标是桌面 OpenGL 3.3 Core Profile（glGetString 返回
        // 3.3.0），而 MobileGlues 走 GLSL ES 路线。
        renderer = @ RENDERER_NAME_MITHRIL;
        setenv("AMETHYST_RENDERER", renderer.UTF8String, 1);
        set_gl_bridge_tbl();
    } else if ([renderer isEqualToString:@ RENDERER_NAME_MTL_ANGLE]) {
        set_gl_bridge_tbl();
    } else if ([renderer isEqualToString:@ RENDERER_NAME_LTW]) {
        // LTW (Large Thin Wrapper) - OpenGL Core 3.3 → OpenGL ES 3 转译层
        // 复刻自官方 MojoLauncher/LTW 仓库，完美支持 Sodium + Iris 光影。
        //
        // 关键：LTW 的 constructor（proc.c）需要通过 dlsym 找到 eglGetProcAddress
        // 等 EGL 函数符号。LTW 自身只导出 eglCreateContext / eglDestroyContext /
        // eglMakeCurrent 三个 wrapper，其他 EGL 函数直接转发给 host EGL（ANGLE）。
        // 所以必须先 dlopen ANGLE（RTLD_GLOBAL）让 ANGLE 的 EGL 符号进入全局符号表，
        // LTW constructor 才能成功初始化。
        //
        // gl_bridge.m 的 dlsym_EGL() 在 LTW 模式下会从 libltw.dylib 直接 dlsym
        // 这三个 wrapper 函数，其余 EGL 函数仍从 ANGLE 解析。
        NSLog(@"[egl_bridge] LTW renderer: preloading ANGLE as host EGL before LTW init");
        dlopen("@rpath/" RENDERER_NAME_MTL_ANGLE, RTLD_GLOBAL);
        set_gl_bridge_tbl();
    } else if ([renderer hasPrefix:@"libOSMesa"]) {
        setenv("GALLIUM_DRIVER","zink",1);
        set_osm_bridge_tbl();
    } else if ([renderer isEqualToString:@ RENDERER_NAME_VULKAN]) {
        // 关键修复（MoltenVK + OpenGL 黑屏 + 图形 API 切换无效）：
        //
        // 之前 Vulkan 渲染器单向调用 set_vk_bridge_tbl()，一旦设置所有 GL 调用都走
        // vk_bridge 的 stub（vk_init_context 返回 dummy，vk_make_current 空实现）。
        // 当 MC 26.2+ 选 prefer_opengl 时仍走 GL 路径（clientAPI != GLFW_NO_API），
        // 但 bridge 已是 vk stub → 无真实 GL 上下文 → 黑屏。
        //
        // 修复策略（参照 FCL/HMCL 的 renderer + graphicsApi 联动逻辑）：
        //   1. 始终初始化 GL bridge（set_gl_bridge_tbl），让 GL 路径有真实上下文
        //   2. 同时预加载 libMoltenVK.dylib（Vulkan 路径需要）
        //   3. pojavCreateContext 根据 clientAPI 动态决定返回值：
        //      - GLFW_NO_API（Vulkan 路径）→ 返回 CAMetalLayer，MC/LWJGL 自管 Vulkan
        //      - 其他（GL 路径）→ 调用 br_init_context 创建真实 EGL/GL 上下文
        //
        // 这样无论 MC 选 OpenGL 还是 Vulkan 路径都能正常工作：
        //   - prefer_vulkan：MC 走 Vulkan 路径，glfwWindowHint(GLFW_NO_API) → CAMetalLayer
        //   - prefer_opengl：MC 走 GL 路径，glfwWindowHint(GLFW_OPENGL_API) → EGL 上下文
        //   - default：MC 内部决定，两种路径都能处理
        //
        // 注意：JavaLauncher.m 已在 Vulkan 模式下设置 org.lwjgl.opengl.libname=libmobileglues.dylib，
        // 所以 LWJGL 加载的 GL 库是 MobileGlues（GL→Vulkan 翻译层），能通过 Vulkan 后端路由 GL 调用。
        // 这就是用户说的"用 OpenGL 渲染游戏加用 MoltenVK，帧率才能达到 120"的实现原理：
        // MC 走 GL 路径 → EGL 上下文（ANGLE Metal）→ MobileGlues 翻译 → Vulkan → MoltenVK → Metal
        // MobileGlues 的 Vulkan 后端使用 IMMEDIATE present mode，可超过屏幕刷新率。
        NSLog(@"[egl_bridge] Vulkan renderer: initializing GL bridge for OpenGL path fallback (graphicsApi联动)");
        set_gl_bridge_tbl();
        // 预加载 libMoltenVK.dylib（Vulkan 路径需要，GL 路径不影响）
        dlopen("@rpath/" RENDERER_NAME_VULKAN, RTLD_GLOBAL);
        // Vulkan 模式下 LWJGL OpenGL 库使用 MobileGlues（由 JavaLauncher.m 设置）
        // 不再调用 JNI_LWJGL_changeRenderer(RENDERER_NAME_MTL_ANGLE)，
        // 因为 JavaLauncher.m 已通过 -Dorg.lwjgl.opengl.libname=libmobileglues.dylib 设置
        JNI_LWJGL_changeRenderer(RENDERER_NAME_MOBILEGLUES);
        // 跳过下方的统一 JNI_LWJGL_changeRenderer 和 dlopen（已处理）
        return !br_init();
    }
    if (strcmp(renderer.UTF8String, RENDERER_NAME_VULKAN) != 0) {
        JNI_LWJGL_changeRenderer(renderer.UTF8String);
    }
    // Preload renderer library
    dlopen([NSString stringWithFormat:@"@rpath/%@", renderer].UTF8String, RTLD_GLOBAL);

    // ============================================================================
    // SDL3 GL/EGL 库重定向说明
    // ============================================================================
    // 此函数（pojavInitOpenGL）仅在 GLFW 路径下被调用（glfwCreateWindow →
    // pojavCreateContext → pojavInitOpenGL）。GLFW 模式下 MC 不走 SDL3 路径，
    // 不需要设置 SDL_OPENGL_LIBRARY / SDL_EGL_LIBRARY 环境变量。
    //
    // SDL3 模式（MC 26.3-snapshot-4+）下 MC 不调用 glfwCreateWindow，此函数不执行，
    // SDL3 环境变量由 JavaLauncher.m 在 JVM 启动前设置（早于 SDL_GL_CreateContext）。
    //
    // 历史代码曾在此处设置 SDL3 环境变量作为"冗余兜底"，但这会导致 GLFW 模式下
    // 也设置 SDL3 环境变量，干扰 LWJGL 的 GLFW 加载路径。已移除。

    return !br_init();
    //return 0;
}

void pojavSetWindowHint(int hint, int value) {
    if (hint == GLFW_CLIENT_API) {
        clientAPI = value;
    } else if (strcmp(getenv("AMETHYST_RENDERER"), "auto")==0 && hint == GLFW_CONTEXT_VERSION_MAJOR) {
        switch (value) {
            case 1:
            case 2:
                setenv("AMETHYST_RENDERER", RENDERER_NAME_GL4ES, 1);
                JNI_LWJGL_changeRenderer(RENDERER_NAME_GL4ES);
                break;
            // case 4: use Zink?
            default:
                setenv("AMETHYST_RENDERER", RENDERER_NAME_MOBILEGLUES, 1);
                JNI_LWJGL_changeRenderer(RENDERER_NAME_MOBILEGLUES);
                break;
        }
    }
}

void pojavSwapBuffers() {
    // FPS 计数（参照 FCL/ZL2 在 native swap buffer 入口计数，反映真实渲染帧率）
    atomic_fetch_add(&_pojavFpsCounter, 1);

    // 阶段13：首帧渲染检测（参照 FCL 的 game_ready 回调）
    // 首次调用 pojavSwapBuffers 表示游戏已渲染第一帧，发送通知移除启动遮罩
    if (!s_firstFrameRendered) {
        s_firstFrameRendered = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"PojavFirstFrameRendered" object:nil];
            NSLog(@"[egl_bridge] First frame rendered, game is ready");
        });
    }

    if (!br_swap_buffers) return;
    br_swap_buffers();
}

void pojavMakeCurrent(basic_render_window_t* window) {
    if (!br_make_current) return;
    br_make_current(window);
}

void* pojavCreateContext(basic_render_window_t* contextSrc) {
    static BOOL inited = NO;
    if (!inited) {
        inited = YES;
        pojavInitOpenGL();
    }

    const char *renderer = getenv("AMETHYST_RENDERER");
    const char *graphicsApi = getenv("AMETHYST_GRAPHICS_API");
    NSLog(@"[egl_bridge] pojavCreateContext: clientAPI=%d (GLFW_NO_API=%d), renderer=%s, graphicsApi=%s",
          clientAPI, GLFW_NO_API, renderer ?: "<unset>", graphicsApi ?: "<unset>");

    if (clientAPI == GLFW_NO_API) {
        // Game has selected Vulkan API to render
        // MC 26.2+ graphicsApi=prefer_vulkan 或 default（Vulkan 路径）会走这里
        // 返回 CAMetalLayer 作为 Vulkan surface，MC/LWJGL 通过 libMoltenVK.dylib 自管 Vulkan
        NSLog(@"[egl_bridge] Vulkan path: returning CAMetalLayer as Vulkan surface");
        return (__bridge void *)SurfaceViewController.surface.layer;
    }

    // GL 路径（clientAPI == GLFW_OPENGL_API 或 GLFW_OPENGL_ES_API）
    // MC 26.2+ graphicsApi=prefer_opengl 或 default（OpenGL 路径）会走这里
    // 调用 br_init_context 创建真实 EGL/GL 上下文
    // 即使 renderer=libMoltenVK.dylib，pojavInitOpenGL 已设置 GL bridge（set_gl_bridge_tbl），
    // 所以这里会调用 gl_init_context 创建 ANGLE Metal EGL 上下文
    NSLog(@"[egl_bridge] OpenGL path: creating EGL/GL context via br_init_context");
    return br_init_context(contextSrc);
}

void pojavSwapInterval(int interval) {
    // Vulkan 模式诊断：即使 br_swap_interval 为 NULL（Vulkan 不使用 EGL swap interval），
    // 也记录调用以帮助诊断帧率解锁问题
    if (!br_swap_interval) {
        const char* vsyncEnv = getenv("POJAV_DISABLE_VSYNC");
        NSLog(@"[egl_bridge] pojavSwapInterval(%d) called but br_swap_interval is NULL "
              @"(likely Vulkan mode). POJAV_DISABLE_VSYNC=%s. "
              @"Vulkan present mode is controlled by vkCreateSwapchainKHR, not eglSwapInterval.",
              interval, vsyncEnv ?: "<unset>");
        return;
    }
    // 解锁帧率（关闭垂直同步）：当启动器偏好 video.disable_game_vsync 开启时
    // （POJAV_DISABLE_VSYNC=1，由 JavaLauncher.m 设置），强制 swap interval=0，
    // 覆盖游戏 glfwSwapInterval(1) 的垂直同步请求。
    //
    // 这是 GL 类渲染器（gl4es/ANGLE/MobileGlues）真正生效 VSync 的落点
    // （gl_bridge.m gl_swap_interval → eglSwapInterval）。
    //
    // ANGLE Metal 后端对 eglSwapInterval 的处理：
    // - interval=0：eglSwapBuffers 不等待 vblank，渲染线程可立即继续下一帧渲染。
    //   虽然 Core Animation 仍按屏幕刷新率合成（60/120Hz），但渲染线程不被阻塞，
    //   可保持高吞吐量。多余的帧会被 Core Animation 丢弃，但 FPS 计数器反映渲染帧率。
    // - interval=1：eglSwapBuffers 等待 vblank，渲染线程被锁在屏幕刷新率。
    //
    // 与 PojavLauncher.java 写 enableVsync=false 互为兜底：即便游戏在运行时再次请求
    // VSync（某些 mod/版本会重设），native 层也会拦截。
    //
    // 与 Vulkan 渲染器的区别：
    // - GL 类渲染器（含 zink）：VSync 通过 eglSwapInterval 控制（此处生效）
    //   zink 创建 swapchain 时根据 eglSwapInterval 选择 present mode：
    //   interval=0 → IMMEDIATE（不等 vsync），interval=1 → FIFO（等 vsync）
    // - Vulkan 渲染器：VSync 通过 vkCreateSwapchainKHR 的 presentMode 控制
    //   （由 LWJGL 根据 glfwSwapInterval 选择，设备能力由 MoltenVK 自动检测）

    const char* vsyncEnv = getenv("POJAV_DISABLE_VSYNC");
    const char* renderer = getenv("AMETHYST_RENDERER");

    if (vsyncEnv && strcmp(vsyncEnv, "1") == 0) {
        if (interval != 0) {
            // 关键修复（FPS 解锁无效问题）：记录每次 VSync 拦截
            // 某些 mod（如 OptiFine、Sodium）或 MC 版本会在运行时反复调用 glfwSwapInterval(1)
            // 重新启用 VSync。记录每次拦截帮助诊断"帧率被重新锁定"的问题。
            // 之前只记录前几次，无法发现运行中被 mod 重新启用的情况。
            NSLog(@"[egl_bridge] pojavSwapInterval: intercepted VSync request interval=%d -> 0 (POJAV_DISABLE_VSYNC=1, renderer=%s)", interval, renderer ?: "<unset>");
        }
        interval = 0;
    } else {
        // 仅记录前几次调用，帮助诊断
        static int s_logCount = 0;
        if (s_logCount < 3) {
            s_logCount++;
            NSLog(@"[egl_bridge] pojavSwapInterval(%d) called (POJAV_DISABLE_VSYNC=%s, renderer=%s, count=%d)",
                  interval, vsyncEnv ?: "<unset>", renderer ?: "<unset>", s_logCount);
        }
    }

    br_swap_interval(interval);
}

// ============================================================================
// SDL3 UIKit 窗口创建桥接（MC 26.3-snapshot-4+ 使用 SDL3 替代 GLFW）
// ============================================================================
// 背景：
//   SDL3 UIKit 后端默认会创建新的 UIWindowScene，与启动器已有的
//   GameSurfaceView（含 CAMetalLayer）冲突，导致 SDL_CreateWindow 阻塞。
//
// 解决方案：
//   拦截 MC 的 SDL_CreateWindow 调用（通过 SDLVideo.java 覆盖类），
//   转而调用 SDL_CreateWindowWithProperties，通过 Properties API 把
//   启动器的 UIWindowScene 指针传给 SDL3，让 SDL3 复用启动器的窗口场景。
//
// 调用链：
//   MC -> SDLVideo.SDL_CreateWindow (Java 覆盖类)
//       -> UIKit.sdlCreateWindowWithScene (本函数)
//          1. 遍历 connectedScenes 找到应用类型的 UIWindowScene
//          2. dlopen libSDL3.dylib (RTLD_NOLOAD 获取已加载句柄)
//          3. dlsym 获取 SDL3 Properties API 函数指针
//          4. 创建 properties，设置 windowscene/metal/flags 属性
//          5. 调用 SDL_CreateWindowWithProperties
//          6. 失败回退到标准 SDL_CreateWindow
//
// 线程安全：
//   UIApplication.sharedApplication 理论上应在主线程访问，但此处仅读取
//   connectedScenes 集合（不做修改），且指针值稳定，实践中可从任意线程调用。
//   SDL3 内部会通过 SDL_RunOnMainThread 调度 UIKit 操作到主线程。

// SDL3 类型定义（避免依赖 SDL3 头文件）
typedef unsigned int SDL_PropertiesID;      // SDL_PropertiesID = Uint32
typedef int SDL_bool;                        // SDL_bool = int
typedef long long SDL_Sint64;                // Sint64 = int64_t
typedef struct SDL_Window SDL_Window;        // 不透明指针

// SDL3 Properties API 函数指针类型
typedef SDL_PropertiesID (*SDL_CreateProperties_t)(void);
typedef SDL_bool (*SDL_SetPointerProperty_t)(SDL_PropertiesID, const char *, void *);
typedef SDL_bool (*SDL_SetBooleanProperty_t)(SDL_PropertiesID, const char *, SDL_bool);
typedef SDL_bool (*SDL_SetNumberProperty_t)(SDL_PropertiesID, const char *, SDL_Sint64);
typedef SDL_Window *(*SDL_CreateWindowWithProperties_t)(SDL_PropertiesID);
typedef void (*SDL_DestroyProperties_t)(SDL_PropertiesID);
typedef SDL_Window *(*SDL_CreateWindow_t)(const char *, int, int, unsigned int);

// SDL_WINDOW_METAL = 0x20000000（iOS 上必须用 Metal 渲染）
#define SDL3_WINDOW_METAL_FLAG 0x20000000u

/// SDL3 Properties API 函数指针（缓存，避免每次创建窗口都 dlsym）
static SDL_CreateProperties_t g_pCreateProperties = NULL;
static SDL_SetPointerProperty_t g_pSetPointerProperty = NULL;
static SDL_SetBooleanProperty_t g_pSetBooleanProperty = NULL;
static SDL_SetNumberProperty_t g_pSetNumberProperty = NULL;
static SDL_CreateWindowWithProperties_t g_pCreateWindowWithProperties = NULL;
static SDL_DestroyProperties_t g_pDestroyProperties = NULL;
static SDL_CreateWindow_t g_pCreateWindow = NULL;
static SDL_CreateWindow_t g_origSDL_CreateWindow = NULL;  // 原始 SDL_CreateWindow（hook 兜底用）
static BOOL g_sdl3_funcs_loaded = NO;

/// 加载 SDL3 Properties API 函数指针（只加载一次）
static BOOL amethyst_sdl3_load_functions(void) {
    if (g_sdl3_funcs_loaded) return YES;

    void *sdl_lib = dlopen("@rpath/libSDL3.dylib", RTLD_NOLOAD | RTLD_GLOBAL);
    if (!sdl_lib) {
        sdl_lib = dlopen("libSDL3.dylib", RTLD_NOLOAD | RTLD_GLOBAL);
    }
    if (!sdl_lib) {
        NSLog(@"[SDL3 Bridge] FATAL: libSDL3.dylib not loaded. dlopen error: %s", dlerror());
        return NO;
    }
    NSLog(@"[SDL3 Bridge] libSDL3.dylib handle: %p", sdl_lib);

    // 重要：必须用 amethyst_orig_dlsym 而非 dlsym 获取 SDL3 函数指针。
    // 因为 main_hook.m 的 hooked_dlsym 会拦截 "SDL_CreateWindow" 请求，
    // 返回我们的 hook 函数，导致 g_origSDL_CreateWindow 指向 hook 函数自身，
    // 形成无限递归。amethyst_orig_dlsym 直接调用 orig_dlsym，绕过 hook。
    extern void *amethyst_orig_dlsym(void *handle, const char *name);
    g_pCreateProperties = (SDL_CreateProperties_t)amethyst_orig_dlsym(sdl_lib, "SDL_CreateProperties");
    g_pSetPointerProperty = (SDL_SetPointerProperty_t)amethyst_orig_dlsym(sdl_lib, "SDL_SetPointerProperty");
    g_pSetBooleanProperty = (SDL_SetBooleanProperty_t)amethyst_orig_dlsym(sdl_lib, "SDL_SetBooleanProperty");
    g_pSetNumberProperty = (SDL_SetNumberProperty_t)amethyst_orig_dlsym(sdl_lib, "SDL_SetNumberProperty");
    g_pCreateWindowWithProperties = (SDL_CreateWindowWithProperties_t)amethyst_orig_dlsym(sdl_lib, "SDL_CreateWindowWithProperties");
    g_pDestroyProperties = (SDL_DestroyProperties_t)amethyst_orig_dlsym(sdl_lib, "SDL_DestroyProperties");
    g_pCreateWindow = (SDL_CreateWindow_t)amethyst_orig_dlsym(sdl_lib, "SDL_CreateWindow");
    g_origSDL_CreateWindow = g_pCreateWindow;

    NSLog(@"[SDL3 Bridge] Function pointers: CreateProperties=%p SetPointer=%p SetBoolean=%p SetNumber=%p CreateWindowWithProps=%p DestroyProps=%p CreateWindow=%p",
          (void*)g_pCreateProperties, (void*)g_pSetPointerProperty, (void*)g_pSetBooleanProperty,
          (void*)g_pSetNumberProperty, (void*)g_pCreateWindowWithProperties,
          (void*)g_pDestroyProperties, (void*)g_pCreateWindow);

    g_sdl3_funcs_loaded = YES;
    return YES;
}

/// 查找启动器的 UIWindowScene
static UIWindowScene *amethyst_find_launcher_window_scene(void) {
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes.allObjects) {
        if (scene.session.role == UIWindowSceneSessionRoleApplication) {
            return scene;
        }
    }
    return nil;
}

/// 创建 SDL3 窗口，复用启动器的 UIWindowScene（C 接口，供 native hook 和 JNI 调用）
///
/// 优先用 Properties API 传入 UIWindowScene，让 SDL3 UIKit 后端复用启动器的窗口场景，
/// 避免创建新的 UIWindowScene 导致冲突/阻塞。失败回退到标准 SDL_CreateWindow。
///
/// @param w 窗口宽度
/// @param h 窗口高度
/// @param flags 窗口 flags（会自动添加 SDL_WINDOW_METAL）
/// @return SDL_Window 指针（成功）或 NULL（失败）
SDL_Window *amethyst_sdl_create_window_with_scene(int w, int h, unsigned int flags) {
    NSLog(@"[SDL3 Bridge] amethyst_sdl_create_window_with_scene: w=%d h=%d flags=0x%x", w, h, flags);

    if (!amethyst_sdl3_load_functions()) {
        return NULL;
    }

    UIWindowScene *launcherScene = amethyst_find_launcher_window_scene();
    if (!launcherScene) {
        NSLog(@"[SDL3 Bridge] WARNING: No UIWindowScene found, falling back to standard SDL_CreateWindow");
    } else {
        NSLog(@"[SDL3 Bridge] Found UIWindowScene: %@", launcherScene);
    }

    // 优先尝试：用 Properties API 传入 UIWindowScene 创建窗口
    if (launcherScene && g_pCreateProperties && g_pSetPointerProperty && g_pSetBooleanProperty &&
        g_pSetNumberProperty && g_pCreateWindowWithProperties && g_pDestroyProperties) {

        NSLog(@"[SDL3 Bridge] Attempting SDL_CreateWindowWithProperties with UIWindowScene...");
        SDL_PropertiesID props = g_pCreateProperties();
        NSLog(@"[SDL3 Bridge] Created properties: %u", props);

        // 设置 UIWindowScene 指针（关键属性，让 SDL3 复用启动器的窗口场景）
        g_pSetPointerProperty(props, "SDL.window.create.uikit.windowscene", (__bridge void *)launcherScene);
        // 强制启用 Metal 渲染（iOS 上必须）
        g_pSetBooleanProperty(props, "SDL.window.create.metal", 1);
        // 设置窗口 flags，自动添加 SDL_WINDOW_METAL
        unsigned int finalFlags = flags | SDL3_WINDOW_METAL_FLAG;
        g_pSetNumberProperty(props, "SDL.window.create.flags", (SDL_Sint64)finalFlags);

        NSLog(@"[SDL3 Bridge] Calling SDL_CreateWindowWithProperties(props=%u, finalFlags=0x%x)...", props, finalFlags);
        SDL_Window *window = g_pCreateWindowWithProperties(props);
        NSLog(@"[SDL3 Bridge] SDL_CreateWindowWithProperties returned: %p", window);

        g_pDestroyProperties(props);

        if (window) {
            NSLog(@"[SDL3 Bridge] SUCCESS: Window created with launcher UIWindowScene");
            return window;
        }
        NSLog(@"[SDL3 Bridge] SDL_CreateWindowWithProperties returned NULL, falling back to standard SDL_CreateWindow");
    } else if (launcherScene) {
        NSLog(@"[SDL3 Bridge] Missing some Properties API functions, falling back to standard SDL_CreateWindow");
    }

    // 回退：标准 SDL_CreateWindow（让 SDL3 自己创建窗口场景）
    if (!g_origSDL_CreateWindow) {
        NSLog(@"[SDL3 Bridge] FATAL: SDL_CreateWindow function not found in libSDL3.dylib");
        return NULL;
    }

    unsigned int finalFlags = flags | SDL3_WINDOW_METAL_FLAG;
    NSLog(@"[SDL3 Bridge] Calling standard SDL_CreateWindow(w=%d, h=%d, flags=0x%x)...", w, h, finalFlags);
    SDL_Window *window = g_origSDL_CreateWindow(NULL, w, h, finalFlags);
    NSLog(@"[SDL3 Bridge] SDL_CreateWindow returned: %p", window);

    return window;
}

/// JNI 入口（保留供 SDLVideo.java 覆盖类调用，也供 dlsym hook 复用）
JNIEXPORT jlong JNICALL Java_net_kdt_pojavlaunch_uikit_UIKit_sdlCreateWindowWithScene(JNIEnv* env, jclass clazz, jint w, jint h, jlong flags) {
    SDL_Window *window = amethyst_sdl_create_window_with_scene((int)w, (int)h, (unsigned int)flags);
    return (jlong)window;
}
