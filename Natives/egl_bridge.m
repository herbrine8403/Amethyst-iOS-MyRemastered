#import "SurfaceViewController.h"

#include "jni.h"
#include <assert.h>
#include <dlfcn.h>
#include <string.h>

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

// 默认 GL 路径，pojavInit() 会重新设置
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

// SDL3 路径下由 sdl3_hook.m 提供：MC 是否创建了带 SDL_WINDOW_VULKAN 的窗口。
// SDL3 下 MC 不调用 glfwWindowHint，clientAPI 恒为默认 GLFW_OPENGL_API，
// 必须靠建窗标志才能判定纯 Vulkan 运行（否则 Vulkan 模式 FPS 恒为 0）。
extern bool ame_sdlVulkanWindowActive(void);

// SDL3 路径下把 SDL 嵌入视图改为透明（SurfaceViewController.m 实现）。
// 它位于最前接收触摸，但不透明的 CAMetalLayer 会整块遮住画面层 → 全黑。
extern BOOL Amethyst_MakeSDLRenderTransparent(void);
// Air Task 32 / Task 52：SDL3 呈现层不变量执法（主线程调用）。
// 隐藏 SDL 自有 UIWindow + 揭开 GameSurfaceView + SDL 视图透明 + z 序钉扎。
extern BOOL Amethyst_EnforceSDL3Presentation(void);

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

    // SDL3 模式（26.2+）：MC 不调用 glfwWindowHint，clientAPI 永远停在
    // GLFW_OPENGL_API，纯 Vulkan 运行时上面的判定恒为 false，导致
    // FPS 的 CADisplayLink fallback 不启用（Vulkan 模式 FPS 恒为 0）。
    // 改以「MC 是否创建了 Vulkan 窗口」为信号：
    //   26.3 主窗口 flags=0x10002020（含 SDL_WINDOW_VULKAN）。
    // 若 MC 随后又真的建起 GL 上下文（OpenGL 回退），sdl3_hook 会清除该标志，
    // 退回由 pojavSwapBuffers 计数，不会双重计数。
    if (ame_sdlVulkanWindowActive()) return true;

    return false;
}

/// 把 "libXxx.dylib" 形式的磁盘文件名转成 LWJGL 期望的"裸名"（"Xxx"）。
///
/// 与 JavaLauncher.m 的 lwjglBareLibName() 规则一致，但这里必须单独再剥一层：
/// JNI_LWJGL_changeRenderer 是在**运行时**用 System.setProperty 写
/// org.lwjgl.opengl.libname 的，会覆盖 JavaLauncher.m 通过 -D 传进去的裸名。
/// 若此处传完整文件名，LWJGL 的
///     Pattern DYLIB = Pattern.compile("(?:^|/)lib\\w+(?:[.]\\d+)*[.]dylib$")
/// 因为 \\w 不含连字符，对 "libMobileGL-gles.dylib" 会判定为"不是 dylib 文件名"，
/// 转交 System.mapLibraryName 再补一层前缀后缀 ->
///     "liblibMobileGL-gles.dylib.dylib"
/// 磁盘上没有这个文件，于是 GL.create() 抛
///     UnsatisfiedLinkError: Failed to locate library: liblibMobileGL-gles.dylib.dylib
/// 名字里没有连字符的库（mobileglues / gl4es_114 / tinygl4angle / MobileGL /
/// OSMesa.8）恰好都能匹配该正则，所以长期只有 GLES 这一个库受影响。
///
/// 在入口统一剥壳，四个调用点（pojavInitOpenGLInternal 的统一分支与
/// mobileglues 分支、pojavSetWindowHint 的 gl4es / mobileglues 分支）一并受保护。
static NSString *lwjglBareLibNameForProperty(const char *fileName) {
    if (fileName == NULL) return nil;
    NSString *name = [NSString stringWithUTF8String:fileName];
    // "lib".length == 3，".dylib".length == 6，合计 9。
    if (name.length > 9 && [name hasPrefix:@"lib"] && [name hasSuffix:@".dylib"]) {
        return [name substringWithRange:NSMakeRange(3, name.length - 9)];
    }
    // 不是标准命名（例如别名或已带路径）就原样返回，保持原有行为。
    return name;
}

void JNI_LWJGL_changeRenderer(const char* value_c) {
    if (value_c == NULL) return;

    // 必须传裸名，不能传完整文件名：完整名会被 LWJGL 二次包装成
    // "liblibXxx.dylib.dylib"（详见 lwjglBareLibNameForProperty 的注释）。
    NSString *bareName = lwjglBareLibNameForProperty(value_c);
    const char *bare_c = bareName == nil ? NULL : bareName.UTF8String;
    if (bare_c == NULL) return;
    if (strcmp(bare_c, value_c) != 0) {
        NSLog(@"[egl_bridge] opengl.libname: '%s' -> bare name '%s' (avoid LWJGL double-wrap)",
              value_c, bare_c);
    }

    // 原实现直接 (*runtimeJavaVMPtr)->GetEnv(...) 且不检查返回值。
    // 在非 JVM 线程上（SDL 的视频/事件线程，SDL3 路径的 SDL_GL_LoadLibrary 就发生在
    // 这类线程上）GetEnv 返回 JNI_EDETACHED 并且**不会写 env**，env 保持为未初始化的
    // 栈垃圾，紧接着 (*env)->NewStringUTF(...) 立刻段错误（崩溃点就是本函数 +0x1c）。
    // 这里补齐：VM 判空 -> GetEnv 结果判空 -> AttachCurrentThread 兜底 -> 用完 detach。
    JavaVM *vm = runtimeJavaVMPtr;
    if (vm == NULL) {
        NSLog(@"[egl_bridge] JNI_LWJGL_changeRenderer('%s') skipped: runtimeJavaVMPtr is NULL", bare_c);
        return;
    }

    JNIEnv *env = NULL;
    BOOL attached = NO;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_4) != JNI_OK || env == NULL) {
        if ((*vm)->AttachCurrentThread(vm, (void **)&env, NULL) != JNI_OK || env == NULL) {
            NSLog(@"[egl_bridge] JNI_LWJGL_changeRenderer('%s') skipped: cannot obtain JNIEnv", bare_c);
            return;
        }
        attached = YES;
    }

    jstring key = (*env)->NewStringUTF(env, "org.lwjgl.opengl.libname");
    jstring value = (*env)->NewStringUTF(env, bare_c);
    if (key != NULL && value != NULL) {
        jclass clazz = (*env)->FindClass(env, "java/lang/System");
        if (clazz != NULL) {
            jmethodID method = (*env)->GetStaticMethodID(env, clazz, "setProperty",
                "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
            if (method != NULL) {
                (*env)->CallStaticObjectMethod(env, clazz, method, key, value);
            }
            (*env)->DeleteLocalRef(env, clazz);
        }
        (*env)->DeleteLocalRef(env, key);
        (*env)->DeleteLocalRef(env, value);
    }

    if (attached) (*vm)->DetachCurrentThread(vm);
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

/// OpenGL 子系统是否已初始化成功（渲染器 bridge + br_init()）。
///
/// 必须是全局的而不是 pojavCreateContext 里的局部 static：SDL3 路径下
/// SDL_GL_LoadLibrary 已经调过 pojavInitOpenGLForSDL3() 完成初始化，
/// 若 pojavCreateContext 再凭自己的局部 static 判定"未初始化"，就会再调一次
/// 完整的 pojavInitOpenGL()——那会在 SDL 的原生线程上执行 JNI 调用
/// （JNI_LWJGL_changeRenderer），正是 fc0d838 上报的
/// `C [AngelAuraAmethyst+0x220df8] JNI_LWJGL_changeRenderer+0x1c` 崩溃。
static BOOL s_openGLInited = NO;

BOOL pojavIsOpenGLInited(void) {
    return s_openGLInited;
}

/// 统一收口初始化结果，成功后置位幂等标志。
static int pojavFinishOpenGLInit(int result) {
    if (result == 0) {
        s_openGLInited = YES;
    } else {
        NSLog(@"[egl_bridge] pojavInitOpenGL failed (br_init() returned %d); "
              @"not marking as initialised", result);
    }
    return result;
}

static int pojavInitOpenGLInternal(BOOL setLwjglProperty) {
    if (s_openGLInited) {
        // 幂等：重复初始化会二次 dlopen 渲染器、二次 br_init()（eglInitialize），
        // 且在 SDL3 路径上会触发无意义的 JNI 调用。
        NSDebugLog(@"[egl_bridge] pojavInitOpenGL skipped: already initialised");
        return 0;
    }
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
    } else if ([renderer isEqualToString:@ RENDERER_NAME_SFPEW]) {
        // SimpleFPEWrapper（MobileGL-Dev，LGPL-3.0）—— GL 1.x 固定管线仿真层。
        // 与 LTW 完全同构：SFPEW 只导出 eglGetProcAddress / eglCreateContext /
        // eglDestroyContext / eglMakeCurrent / eglSwapBuffers(WithDamage)，
        // eglGetDisplay / eglInitialize / eglChooseConfig / eglCreateWindowSurface
        // 等基础设施一概不导出，必须由 host EGL 提供。
        //
        // 所以它不能进 isSelfEglRenderer()：那条路会让 gl_bridge.m 的
        // dlsym_EGL() 直接去 SFPEW 里 dlsym eglGetDisplay，取不到就返回 false，
        // 初始化失败。EGL 基础设施仍走 ANGLE，仅生命周期三个 wrapper +
        // eglSwapBuffers 改从 libSimpleFPEWrapper.dylib 解析（见 gl_bridge.m）。
        //
        // set_gl_bridge_tbl() 是必需的：bridge_tbl.h 里 br_init 等函数指针没有
        // 初始值（C 全局零初始化 = NULL），缺这一步 pojavInitOpenGL 末尾的
        // !br_init() 就是空指针调用。
        NSLog(@"[egl_bridge] SFPEW renderer: FPE shim over host EGL, SFPEW_EGL=%s",
              getenv("SFPEW_EGL") ?: "<unset>");
        set_gl_bridge_tbl();
    } else if ([renderer isEqualToString:@ RENDERER_NAME_MITHRIL]) {
        // Mithril 渲染器：EGL 1.5 + GL 3.3 Core 全部由 libmithril.dylib 提供
        // （Vulkan backend，经 MoltenVK 到 Metal）。
        // gl_bridge.m 的 dlsym_EGL() 会从 libmithril.dylib 解析 EGL 符号，
        // gl_init_context 用 EGL_OPENGL_BIT + EGL_OPENGL_API 创建 desktop GL 上下文。
        // 下方的统一逻辑会把它设为 LWJGL 的 opengl.libname 并 RTLD_GLOBAL 预加载。
        NSLog(@"[egl_bridge] Mithril renderer: EGL/GL provided by libmithril.dylib (Vulkan backend)");
        set_gl_bridge_tbl();
    } else if (isMobileGLRenderer(renderer.UTF8String)) {
        // MobileGL 渲染器：EGL + GL 由 libMobileGL.dylib 提供。
        // 两个变体共用同一个二进制，用 MOBILEGL_BACKEND_TYPE 选择后端：
        //   libMobileGL.dylib      -> DirectVulkan (GL -> Vulkan -> MoltenVK -> Metal)
        //   libMobileGL-gles.dylib -> DirectGLES   (GL -> OpenGL ES)
        setenv("MOBILEGL_BACKEND_TYPE",
            [renderer isEqualToString:@ RENDERER_NAME_MOBILEGL_GLES] ? "DirectGLES" : "DirectVulkan",
            1);
        NSLog(@"[egl_bridge] MobileGL renderer: backend=%s",
            getenv("MOBILEGL_BACKEND_TYPE") ?: "<unset>");
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
        // 注意：JavaLauncher.m 已在 Vulkan 模式下设置 org.lwjgl.opengl.libname=mobileglues（裸名），
        // 所以 LWJGL 加载的 GL 库是 MobileGlues（GL→Vulkan 翻译层），能通过 Vulkan 后端路由 GL 调用。
        // 这就是用户说的"用 OpenGL 渲染游戏加用 MoltenVK，帧率才能达到 120"的实现原理：
        // MC 走 GL 路径 → EGL 上下文（ANGLE Metal）→ MobileGlues 翻译 → Vulkan → MoltenVK → Metal
        // MobileGlues 的 Vulkan 后端使用 IMMEDIATE present mode，可超过屏幕刷新率。
        NSLog(@"[egl_bridge] Vulkan renderer: initializing GL bridge for OpenGL path fallback (graphicsApi linkage)");
        set_gl_bridge_tbl();
        // 预加载 libMoltenVK.dylib（Vulkan 路径需要，GL 路径不影响）
        dlopen("@rpath/" RENDERER_NAME_VULKAN, RTLD_GLOBAL);
        // Vulkan 模式下 LWJGL OpenGL 库使用 MobileGlues（由 JavaLauncher.m 设置）
        // 不再调用 JNI_LWJGL_changeRenderer(RENDERER_NAME_MTL_ANGLE)，
        // 因为 JavaLauncher.m 已通过 -Dorg.lwjgl.opengl.libname=mobileglues（裸名）设置
        if (setLwjglProperty) JNI_LWJGL_changeRenderer(RENDERER_NAME_MOBILEGLUES);
        // 跳过下方的统一 JNI_LWJGL_changeRenderer 和 dlopen（已处理）
        return pojavFinishOpenGLInit(!br_init());
    }
    // SFPEW 叠加在 MobileGL(-gles) 上时 AMETHYST_RENDERER 是 SFPEW，但真后端仍是
    // MobileGL —— MOBILEGL_BACKEND_TYPE 必须保留，否则后端选成默认的 DirectVulkan。
    const char *sfpewBackend = getenv("AMETHYST_SFPEW_BACKEND");
    BOOL mobileGLActive = isMobileGLRenderer(renderer.UTF8String) ||
        (isSFPEWRenderer(renderer.UTF8String) && sfpewBackend != NULL &&
         isMobileGLRenderer(sfpewBackend));
    if (!mobileGLActive) {
        // 切换渲染器后清掉 MobileGL 专用环境变量，避免残留影响下一次启动
        unsetenv("MOBILEGL_BACKEND_TYPE");
        unsetenv("MOBILEGL_LOG_FILE_PATH");
    }
    if (setLwjglProperty && strcmp(renderer.UTF8String, RENDERER_NAME_VULKAN) != 0) {
        JNI_LWJGL_changeRenderer(renderer.UTF8String);
    }
    // Preload renderer library
    //
    // 符号隔离（仅 SDL3 路径）：
    // 部分渲染器镜像内静态链接了一份 glslang。以 RTLD_GLOBAL 载入时，其中大量
    // N_WEAK_DEF 符号会被提升进全局符号空间；随后 LWJGL 加载 libshaderc.dylib
    // 时，dyld 把 shaderc 那份 glslang 合并到渲染器这份上，二者共用线程局部的
    // AST 内存池 —— 渲染器销毁自己的 TShader 时会连带回收 shaderc 仍在使用的
    // AST 节点，TGlslangToSpvTraverser::visitAggregate 随即解引用到已释放内存
    // （SIGSEGV；26.3 上崩溃地址固定在 +0x155820）。
    //
    // 最初只对 MobileGL 启用，但 MobileGlues 同样内嵌 glslang（26.3 + mobileglues
    // 崩在同一个 visitAggregate），白名单式判断漏掉了它。故改为按种类判断。
    //
    // 判定模型参照 ZL2 sdlGlesCompatEnabled()：默认启用 + 显式排除，
    // 而不是"只对已知的这一个渲染器启用"。
    //
    // 显式排除（必须保持 RTLD_GLOBAL）：
    //   - ANGLE：多个渲染器共享的 EGL host。LTW 的 constructor 靠全局 dlsym 找
    //     eglGetProcAddress，降级为 RTLD_LOCAL 会让 LTW 初始化失败。
    //   - OSMesa 系（gallium/zink，对应 ZL2 的 gallium_* / custom_gallium）：
    //     Mesa 内部组件之间靠全局符号互相解析。
    //
    // GLFW 路径（setLwjglProperty == YES，1.21.1 / 26.2 等）行为完全不变。
    // 逃生开关：AMETHYST_RENDERER_RTLD_GLOBAL=1 恢复旧行为，无需重新构建
    // （旧名 AMETHYST_MOBILEGL_RTLD_GLOBAL 仍兼容）。
    {
        const char *forceGlobal = getenv("AMETHYST_RENDERER_RTLD_GLOBAL");
        if (forceGlobal == NULL) forceGlobal = getenv("AMETHYST_MOBILEGL_RTLD_GLOBAL");
        const BOOL isSDL3Path = (setLwjglProperty == NO);
        const char *r = renderer.UTF8String;
        // 需要向其他镜像暴露符号的渲染器，保持 RTLD_GLOBAL
        const BOOL needsGlobalSymbols =
            strcmp(r, RENDERER_NAME_MTL_ANGLE) == 0 ||   // 共享 EGL host（LTW 依赖）
            strncmp(r, "libOSMesa", 9) == 0;             // Mesa / gallium 内部互解析
        bool useLocal = isSDL3Path && !needsGlobalSymbols &&
                        !(forceGlobal && forceGlobal[0] == '1');
        int dlFlags = useLocal ? RTLD_LOCAL : RTLD_GLOBAL;
        NSString *rpath = [NSString stringWithFormat:@"@rpath/%@", renderer];

        // RTLD_NOLOAD 探测：若 LWJGL 已先于此处加载过该库（26.3 上常见，它经
        // -Dorg.lwjgl.opengl.libname 在 bootstrap 阶段就 dlopen 了），本次
        // dlopen 的 RTLD_LOCAL 不会再改变其可见性，隔离将不生效。这种情况单独
        // 打日志，避免"看着改了其实没生效"。
        void *pre = dlopen(rpath.UTF8String, RTLD_NOLOAD);
        if (pre != NULL) {
            NSDebugLog(@"[egl_bridge] %@ already loaded before preload "
                       @"(LWJGL loaded it first; RTLD_LOCAL isolation will not apply)", renderer);
        }

        NSDebugLog(@"[egl_bridge] preloading %@ with %s (sdl3Path=%d)",
                   renderer, useLocal ? "RTLD_LOCAL" : "RTLD_GLOBAL", isSDL3Path);
        if (useLocal) {
            NSLog(@"[egl_bridge] %@ loaded with RTLD_LOCAL "
                  @"(glslang symbols isolated from libshaderc.dylib)", renderer);
        }
        dlopen(rpath.UTF8String, dlFlags);
    }

    return pojavFinishOpenGLInit(!br_init());
    //return 0;
}

int pojavInitOpenGL(void) {
    return pojavInitOpenGLInternal(YES);
}

/// SDL3 路径专用入口：不写 org.lwjgl.opengl.libname。
///
/// 该属性由 JavaLauncher 在 JVM 启动时以 -D 传入，LWJGL 在 bootstrap 阶段就已读取
/// 并 dlopen 了渲染器库（这正是 MC 26.3 报 "OpenGL library already loaded" 的来源）。
/// 等到 SDL_GL_LoadLibrary 再设这个属性既无效果（LWJGL 的 System property 只在类
/// 初始化时读一次），又要为此把非 JVM 线程 attach 到 VM，属于纯粹的收益为负的操作。
int pojavInitOpenGLForSDL3(void) {
    return pojavInitOpenGLInternal(NO);
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


// —— 取 EGL surface 的像素尺寸 ——
// 与 sdl3_hook 的 ame_eglSurfacePixelSize 同逻辑：优先 CAMetalLayer.drawableSize
// （gl_bridge 建 surface 用的就是它），回落 bounds x contentsScale，再回落主屏。
static bool pojavEglSurfacePixelSize(int *outW, int *outH) {
    if (outW == NULL || outH == NULL) return false;
    *outW = 0; *outH = 0;

    UIView *gsv = nil;
    Class svc = NSClassFromString(@"SurfaceViewController");
    if (svc != nil && [svc respondsToSelector:NSSelectorFromString(@"surface")]) {
        id obj = [svc performSelector:NSSelectorFromString(@"surface")];
        if ([obj isKindOfClass:[UIView class]]) gsv = (UIView *)obj;
    }
    if (gsv == nil) return false;
    CALayer *layer = gsv.layer;
    if (layer == nil) return false;

    SEL sel = NSSelectorFromString(@"drawableSize");
    if ([layer respondsToSelector:sel]) {
        NSMethodSignature *sig = [layer methodSignatureForSelector:sel];
        if (sig != nil && strcmp([sig methodReturnType], @encode(CGSize)) == 0) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.selector = sel;
            [inv invokeWithTarget:layer];
            CGSize size = CGSizeZero;
            [inv getReturnValue:&size];
            if (size.width > 1.0 && size.height > 1.0) {
                *outW = (int)round(size.width);
                *outH = (int)round(size.height);
                return true;
            }
        }
    }
    CGFloat scale = layer.contentsScale;
    CGSize bs = layer.bounds.size;
    if (scale > 0.0 && bs.width > 1.0 && bs.height > 1.0) {
        *outW = (int)round(bs.width * scale);
        *outH = (int)round(bs.height * scale);
        return true;
    }
    UIScreen *screen = [UIScreen mainScreen];
    CGSize sb = screen.bounds.size;
    CGFloat sc = screen.scale;
    if (sb.width > 0.0 && sb.height > 0.0 && sc > 0.0) {
        *outW = (int)round(sb.width * sc);
        *outH = (int)round(sb.height * sc);
        return true;
    }
    return false;
}

// —— swap 前强制 viewport 对齐 EGL surface ——
//
// 根因（日志与代码双向确认）：26.3 的 RenderPearl 先建一个隐藏工具窗口
// （320x480）并在其上建 GL context，初始 viewport 即被设为 320x480；主窗口随后
// 复用同一个 window 指针，MC 查询得到的是 EGL surface 的真实尺寸 —— 与它期望的
// 完全一致，于是不触发任何 resize 逻辑，viewport 从此再无重设机会，画面永久缩在
// 320x480 的一角。手动改一次分辨率能恢复，正因为那才真正触发了一次重设。
//
// 修正点选在 pojavSwapBuffers：GL 路径每一帧都必须经此交换缓冲；Vulkan 走
// MoltenVK 的 vkQueuePresentKHR，根本不进入本函数（见本文件上方注释），故天然
// 不受影响。这是唯一不依赖 MC 究竟调用 SDL_GL_SwapWindow 还是别的入口、必定
// 命中的落地点 —— 此前把兜底挂在 ame_SDL_GL_SwapWindow 上，日志零输出已证明
// MC 并未走那条路。
//
// GL 函数指针优先经 eglGetProcAddress 取得：渲染器多为 RTLD_LOCAL 加载（隔离
// glslang 符号所需），dlsym(RTLD_DEFAULT) 取不到，而 eglGetProcAddress 由当前
// EGL context 提供，不受库可见性影响。
//
// —— 符号可信性（关键修复）——
// 只有 eglGetProcAddress 这一条路是「按当前上下文」解析的，其余两条都有风险：
//   * dlsym(RTLD_DEFAULT, ...)：渲染器以 RTLD_LOCAL 载入时全局符号表里没有它的
//     gl* 符号，此处会命中 iOS 系统 OpenGLES.framework 的桩。该桩不属于我们的
//     EGL 上下文 —— 用它读 viewport 得到的是无关值（恒 0），用它写 viewport
//     完全无效，画面依旧缩在角落；更糟的是那正是「守护一直报 corrected、画面
//     仍缩在左上角」的成因：纠正动作确实执行了，只是执行在错误的实现上。
//   * eglGetProcAddress 也可能被某份 EGL host（如 ANGLE）转交给自身未匹配的镜像。
// 故与 sdl3_hook.m 的既定策略保持一致（凡要真正执行的 GL 入口点，先用 dladdr
// 验明镜像，拒绝系统框架的桩），对解析结果一律校验后再缓存。
// 渲染器句柄（AMETHYST_RENDERER → dlopen RTLD_NOLOAD）是首选来源：它必然属于当前
// 上下文，且不受 RTLD_DEFAULT 的可见性限制。
// 注意变量名必须是 AMETHYST_RENDERER（本工程约定，见 JavaLauncher.m 的 setenv）；
// ZL2 用的是 POJAV_RENDERER，且 JavaLauncher.m 会主动 unsetenv 掉后者，故务必不要
// 混用 —— 用错名字会让本函数恒返回 NULL，守护静默失效。

// 与 sdl3_hook.m 中同名函数等价。此处不复用后者是因为它是该文件的 static 函数，
// 跨编译单元不可见；此处独立实现以保持 egl_bridge.m 自包含。
static bool pojavGlSymbolTrusted(const void *sym) {
    if (sym == NULL) return false;
    Dl_info info;
    if (dladdr(sym, &info) == 0 || info.dli_fname == NULL) return false;
    const char *img = info.dli_fname;
    return (strstr(img, "OpenGLES.framework") == NULL &&
            strstr(img, "OpenGL.framework") == NULL);
}

// 渲染器 dylib 句柄。用 RTLD_NOLOAD 只「查」不「加载」：若渲染器尚未载入则返回
// NULL，绝不在渲染线程上触发一次真实的 dlopen（那会在 dyld 持锁时死锁）。
//
// 注意不要永久缓存失败结果：swap 会在上下文就绪后立即被调用，那一刻渲染器可能
// 尚未 dlopen（预载失败或时机偏晚）。若把 NULL 一并缓存，重试就永远拿不到句柄。
// 故只在成功时缓存，失败按一定间隔重试（每 16 帧一次，开销可忽略）。
static void *pojavRendererHandle(void) {
    static void *handle = NULL;
    static int missCount = 0;
    if (handle != NULL) return handle;

    const char *renderer = getenv("AMETHYST_RENDERER");
    if (renderer == NULL || renderer[0] == '\0') return NULL;

    missCount++;
    if (missCount > 1 && (missCount % 16) != 0) return NULL;

    NSString *path = [NSString stringWithFormat:@"@rpath/%s", renderer];
    handle = dlopen(path.UTF8String, RTLD_NOW | RTLD_NOLOAD);
    if (handle == NULL && missCount == 1) {
        NSLog(@"[egl_bridge] viewport guard: renderer not loaded yet (%s), will retry",
              renderer);
    }
    return handle;
}

// 解析一个 GL 入口点，仅接受来自渲染器自身（或至少非系统框架）的实现。
// 顺序：渲染器句柄 → eglGetProcAddress → dlsym(RTLD_DEFAULT) 兜底但同样要过校验。
static void *pojavResolveTrustedGl(const char *name) {
    if (name == NULL) return NULL;

    void *rh = pojavRendererHandle();
    if (rh != NULL) {
        void *p = dlsym(rh, name);
        if (pojavGlSymbolTrusted(p)) return p;
    }

    void *eglGPA = dlsym(RTLD_DEFAULT, "eglGetProcAddress");
    if (eglGPA != NULL) {
        typedef void *(*fn_gpa_t)(const char *);
        void *p = ((fn_gpa_t)eglGPA)(name);
        if (pojavGlSymbolTrusted(p)) return p;
    }

    // 兜底：全局符号。系统框架的桩会在这里被拒，故只在渲染器确实以 GLOBAL 载入
    // （egl_bridge 预载被绕过）时才会命中 —— 那种情况下它是正确且唯一的选择。
    void *p = dlsym(RTLD_DEFAULT, name);
    return pojavGlSymbolTrusted(p) ? p : NULL;
}

// 判定保守：只精确匹配已知错误候选（隐藏工具窗口 320x480、SDL points 812x375），
// 不做比例推断。swap 当下渲染目标恒为主 framebuffer，其 viewport 本就应等于 EGL
// surface；渲染到 FBO 的小 viewport 不会在 swap 这一刻生效，故不会误伤。
static void pojavEnforceViewportAtSwap(void) {
    static void *fnGetIv = NULL;
    static void *fnViewport = NULL;
    static int resolved = 0;
    static int probed = 0;
    static int logBudget = 8;

    // 只在两者都拿到时才算解析完成。任一为 NULL 都允许后续帧重试（首次调用可能
    // 早于渲染器 dlopen 完成）。重试本身开销极小：resolved 为 0 时才走这一步。
    if (!resolved) {
        fnGetIv = pojavResolveTrustedGl("glGetIntegerv");
        fnViewport = pojavResolveTrustedGl("glViewport");
        if (fnGetIv != NULL && fnViewport != NULL) {
            resolved = 1;
            NSLog(@"[egl_bridge] viewport guard: glGetIntegerv=%p glViewport=%p",
                  fnGetIv, fnViewport);
        } else if (probed++ == 0) {
            NSLog(@"[egl_bridge] viewport guard: resolve incomplete "
                  @"(glGetIntegerv=%p glViewport=%p), will retry",
                  fnGetIv, fnViewport);
        }
    }
    // 没有可信的读取手段就无法判定，只能安静放行；没有可信的写入手段则最多
    // 「只观测不纠正」，仍保留诊断价值。
    if (fnGetIv == NULL) return;

    int eglW = 0, eglH = 0;
    if (!pojavEglSurfacePixelSize(&eglW, &eglH)) return;
    if (eglW <= 0 || eglH <= 0) return;

    typedef void (*fn_getiv_t)(uint32_t, int32_t *);
    typedef void (*fn_vp_t)(int32_t, int32_t, int32_t, int32_t);
    // 先看当前绑定的 framebuffer。这是判定能否安全纠正的依据：
    // 只有渲染目标是默认 framebuffer(0) 时，viewport 才「必须」等于 EGL surface
    // 尺寸；若绑定的是 FBO，小 viewport 属于合法的离屏/后处理渲染，纠正会破坏它。
    int32_t fb = -1;
    ((fn_getiv_t)fnGetIv)(0x8CA6 /* GL_FRAMEBUFFER_BINDING */, &fb);

    int32_t v[4] = {0, 0, 0, 0};
    ((fn_getiv_t)fnGetIv)(0x0BA2 /* GL_VIEWPORT */, v);
    int32_t vw = v[2], vh = v[3];

    int matches = (vw == eglW && vh == eglH);

    // 无条件记录：无论正确、已纠正、还是因绑定 FBO 而跳过，都必须留痕。
    // 若少了这一档，viewport 是第三种值时代码会静默返回，一轮实测下来仍然
    // 一无所知 —— 那正是此前反复空转的成因。
    if (logBudget > 0) {
        logBudget--;
        // 判定文案必须与实际动作一致：拿不到可信的 glViewport 时只是「观测到不匹配」
        // 而没有纠正，若仍打印 corrected，会让人误以为修复已生效而继续往别处找
        // 原因 —— 这正是此前反复空转的一个成因。
        const char *verdict = matches ? "ok"
                            : (fb != 0 ? "MISMATCH-fbo-bound,skipped"
                                       : (fnViewport != NULL
                                              ? "MISMATCH->corrected"
                                              : "MISMATCH-but-no-trusted-glViewport"));
        NSLog(@"[egl_bridge] viewport guard: vp=%dx%d egl=%dx%d fb=%d %s (glViewport=%p)",
              vw, vh, eglW, eglH, fb, verdict, fnViewport);
    }

    if (matches) return;
    if (fb != 0) return;   // 离屏渲染，不干预
    if (fnViewport == NULL) return;

    ((fn_vp_t)fnViewport)(0, 0, (int32_t)eglW, (int32_t)eglH);
}

// ====================================================================
// SDL3（MC 26.3+）OpenGL 后端「渲染全绿 + 黑屏」卫兵
//
// 根因（Air 启动器 Task 52 的反汇编实锤）：供应商 libSDL3.dylib 的 Zalith
// 同源嵌入补丁，在每次真实 SDL_CreateWindow / SDL_Metal_CreateView 时按类名
// 查找并 [GameSurfaceView setHidden:YES]。GL 帧全部呈现进这个被隐藏的 layer
// → 输入、声音、资源加载全部正常，唯独画面全黑。
//
// gl_init_context() 里的一次性恢复（Amethyst_RestoreGameSurfaceVisibility）
// 挡不住后续复发：嵌入逻辑会重跑，宿主 updateSavedResolution 也会周期性写回
// drawableSize。因此必须在每帧必经的 swap 路径上持续执法：
//   1) 渲染 layer 可见（hidden == NO）—— 黑屏主因
//   2) present 几何：drawableSize == EGL surface 尺寸
//   3) z 序：仅记录相对次序供诊断（重排条件见代码内注释）
//
// 首帧 + 其后每 50 帧一次、主线程异步执行，不阻塞渲染线程。
// ====================================================================
static unsigned long g_ame52_swapIndex = 0;
static BOOL g_ame52_dumped = NO;

static void ame_enforceRenderLayerInvariants(void) {
    // EGL surface 尺寸：拿不到就说明不是 GL 路径（Vulkan 不经此函数），直接返回。
    int sw = 0, sh = 0;
    if (!pojavEglSurfacePixelSize(&sw, &sh)) return;
    if (sw <= 0 || sh <= 0) return;

    unsigned long idx = g_ame52_swapIndex;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIView *gs = [SurfaceViewController surface];
            if (gs == nil) return;

            // 一次性层级快照：黑屏时靠它确认到底是哪一条不变量失守。
            if (!g_ame52_dumped) {
                g_ame52_dumped = YES;
                UIView *sdlv = Amethyst_FindEmbeddedSDLView();
                NSLog(@"[Amethyst] Task52 dump: gs=%p hidden=%d layerHidden=%d "
                      @"frame=%@ bounds=%@ scale=%.2f superview=%p | sdl=%p "
                      @"sdlHidden=%d sdlSuperview=%p | surface=%dx%d",
                      gs, (int)gs.hidden, (int)gs.layer.hidden,
                      NSStringFromCGRect(gs.frame), NSStringFromCGRect(gs.bounds),
                      (double)gs.layer.contentsScale, gs.superview,
                      sdlv, sdlv ? (int)sdlv.hidden : -1, sdlv ? sdlv.superview : nil,
                      sw, sh);
            }

            // 1) 揭开渲染层
            if (gs.hidden || gs.layer.hidden) {
                gs.hidden = NO;
                gs.layer.hidden = NO;
                NSLog(@"[Amethyst] Task52 guard #%lu: render layer was HIDDEN by "
                      @"external code -- UN-HIDDEN (surface=%dx%d)", idx, sw, sh);
            }

            // 2) z 序：只诊断，不重排。
            //    Air（Task 52）把画面层钉在 SDL 触摸视图「之下」，前提是它自己
            //    把 SDL 视图设成了透明（opaque=NO / backgroundColor=nil）。本仓库
            //    的嵌入逻辑在预编译的 libSDL3.dylib 内、无法改写，而日志显示其
            //    CAMetalLayer 为 opaque=1 —— 照搬「置于其下」会被不透明层整块
            //    遮住，反而更黑。同理，周期性 bringSubviewToFront 又会盖住虚拟
            //    鼠标指针与控制按钮。故此处只记录相对次序，交给日志判断。
            UIView *sdl = Amethyst_FindEmbeddedSDLView();

            // 2b  让 SDL 视图透明 —— 黑屏的真正遮挡源。
            //     SDL3 每次建窗都把自己 re-front 到最前（"ShowWindow:
            //     re-fronting embedded view"），而其 CAMetalLayer 默认
            //     opaque=1，于是不透明黑层盖住 GameSurfaceView。保持在最前
            //     （输入依赖它）但改为透明即可看穿，无需重排 z 序。
            if (sdl != nil) {
                static BOOL s_ame52_transparentLogged = NO;
                // Air Task 32/52 统一执法：隐藏 SDL 自有 UIWindow（空窗黑盖子）、
                // 揭开被供应商嵌入补丁藏起来的 GameSurfaceView、SDL 视图透明、
                // 并把画面层钉在 SDL 触摸视图之下。内部已做变更检测，高频调用无害。
                BOOL did = Amethyst_EnforceSDL3Presentation();
                if (did && !s_ame52_transparentLogged) {
                    s_ame52_transparentLogged = YES;
                    NSLog(@"[Amethyst] Task52 guard #%lu: presentation invariants "
                          @"enforced (SDL UIWindow hidden / render layer un-hidden)", idx);
                }
            }

            if (sdl != nil && gs.superview != nil && sdl.superview == gs.superview) {
                NSArray *subs = gs.superview.subviews;
                NSUInteger gi = [subs indexOfObjectIdenticalTo:gs];
                NSUInteger si = [subs indexOfObjectIdenticalTo:sdl];
                if (gi != NSNotFound && si != NSNotFound && idx <= 1) {
                    NSLog(@"[Amethyst] Task52 z-order: GameSurfaceView idx=%lu, "
                          @"SDL view idx=%lu (%@), subviews=%lu",
                          (unsigned long)gi, (unsigned long)si,
                          (gi > si) ? @"GS above SDL" : @"GS below SDL",
                          (unsigned long)subs.count);
                }
            }

            // 3) present 几何：drawableSize 必须等于 EGL surface 尺寸。
            //    宿主 updateSavedResolution 会周期性写回物理像素值，与 1x 对齐
            //    后的 surface 失配 → present 自洽被破坏 → 黑屏。
            CALayer *l = gs.layer;
            if ([l isKindOfClass:CAMetalLayer.class]) {
                CAMetalLayer *ml = (CAMetalLayer *)l;
                CGSize old = ml.drawableSize;
                if (fabs(old.width - (CGFloat)sw) > 0.5 ||
                    fabs(old.height - (CGFloat)sh) > 0.5) {
                    ml.drawableSize = CGSizeMake((CGFloat)sw, (CGFloat)sh);
                    NSLog(@"[Amethyst] Task52 guard #%lu: present-align drawable "
                          @"%.0fx%.0f -> %dx%d (== EGL surface)",
                          idx, old.width, old.height, sw, sh);
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[Amethyst] Task52 guard exception: %@", e);
        }
    });
}

// ====================================================================
// first-present 编译风暴静默门（对齐 Air Task 39）
//
// 问题：MC 26.3 + RenderPearl 在首帧之前会集中编译成百上千个着色器
// （libshaderc 逐条 SPIR-V 编译）。这段窗口内 swap 被反复调用但还没进入
// 稳定呈现，若此时对每帧都做呈现层执法（揭层 / 去遮挡 / 几何对齐）与
// viewport 读写，等于在编译风暴上再叠一层主线程往返，首帧被显著推迟，
// 最坏情况是宿主判定「渲染已死」而触发额外的几何变更（iPad 窗口化下
// 更是直接踩 SDL_EVENT_WINDOW_MINIMIZED）。
//
// 修法：从第一次 swap 起计时，2 秒内的「重活」全部静默跳过（只计数、
// 只累计第一帧通知）；2 秒后恢复常规执法。15 秒为硬上限 —— 超过则无条件
// 恢复，避免极端慢设备上静默门因计时异常而永不解除。
// ====================================================================
static NSTimeInterval g_ame39_firstSwapTime = 0.0;
static BOOL g_ame39_gateClosed = NO;

static void ame39_swapGateTick(void) {
    if (g_ame39_firstSwapTime <= 0.0) {
        g_ame39_firstSwapTime = [NSDate date].timeIntervalSince1970;
        g_ame39_gateClosed = YES;
        NSLog(@"[egl_bridge] first-present gate closed (2s compile-storm silence, "
              @"hard cap 15s)");
    }
    if (!g_ame39_gateClosed) return;

    NSTimeInterval elapsed = [NSDate date].timeIntervalSince1970 - g_ame39_firstSwapTime;
    if (elapsed >= 2.0 || elapsed >= 15.0) {
        g_ame39_gateClosed = NO;
        NSLog(@"[egl_bridge] first-present gate opened after %.2fs (frame %lu)",
              elapsed, g_ame52_swapIndex);
    }
}

void pojavSwapBuffers() {
    // first-present 静默门：判定当前这一帧是否值得做重活。
    ame39_swapGateTick();
    const BOOL heavyWorkAllowed = !g_ame39_gateClosed;

    // viewport 守护：GL 路径每帧必经此处，Vulkan 不经（见函数上方注释）
    // 编译风暴期间跳过：此时 MC 还在探测/建立管线，改写 viewport 会打断它。
    if (heavyWorkAllowed) {
        pojavEnforceViewportAtSwap();
    }

    // 呈现层卫兵：第 1 帧立执法一次（首帧前嵌入已跑完），其后每 50 帧一次。
    // 编译风暴期间完全不执法 —— 这段时间画面本就还没稳定，执法收益为零，
    // 代价却是在主线程往返上排队。
    g_ame52_swapIndex++;
    if (heavyWorkAllowed &&
        (g_ame52_swapIndex == 1 || (g_ame52_swapIndex % 50) == 0)) {
        ame_enforceRenderLayerInvariants();
    }

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

// pojavCreateContext 在 Vulkan 路径（clientAPI == GLFW_NO_API）下返回的是
// CAMetalLayer 指针，不是 basic_render_window_t。
// GLFW 规范规定窗口创建后上下文自动 current，因此 glfwCreateWindow 会紧接着调用
// glfwMakeContextCurrent(ptr) -> pojavMakeCurrent(ptr)。
// 若此处不加区分地把 CAMetalLayer 当作 render_window_t 交给 gl_make_current，
// 后者解引用 bundle->surface / bundle->context 会直接段错误。
// 用该标志拦住 Vulkan 路径：Vulkan 由 MC/LWJGL 经 libMoltenVK 自管，本就无需 EGL current。
static BOOL g_pojavContextIsVulkanLayer = NO;

/// 清空当前上下文遗留的 GL 错误码。
///
/// 因果链（26.3 + MobileGlues 实测日志）：
///   MobileGlues 的 constructor 在 JVM 启动前建临时 ES3 pbuffer 并 makeCurrent，
///   随后 init_target_gles() 与 multidraw 能力探测在该临时上下文上执行并留下
///   错误码（日志中 "EGL initialized successfully (temp context ES 3)" 与
///   "Not Detected GL_EXT_multi_draw_indirect!" 正是这段）。
///   MC 26.3 的 RenderPearl 在 GlBackend.loadLibrary() 里直接调 glGetError()
///   判定上下文可用性，且不预先清空 —— 读到残留码即抛 "glGetError mismatch"，
///   OpenGL 后端创建失败；MC 随即回退 Vulkan，libshaderc.dylib 编译着色器时
///   SIGSEGV 于 TGlslangToSpvTraverser::visitAggregate。
///   即：shaderc 崩溃是次生的，真正的起点是残留错误码。
///   26.2 的 LWJGL 3.4.1 GL.createCapabilities() 同样是先 GetError 再判
///   （GL.java:455 `if (callI(GetError) == GL_NO_ERROR && ...)`），
///   残留码会把它踢进 else 分支，因此一并受益。
///
/// 渲染器以 RTLD_LOCAL 载入（隔离其内嵌 glslang 所需），glGetError 必须用显式
/// 句柄取：dlsym(RTLD_DEFAULT) 会命中 iOS 系统 OpenGLES.framework 的桩，那份
/// 实现与我们的 EGL 上下文无关（诊断日志已坐实 glGetString(GL_VERSION)=(NULL)）。
/// 取到后以 dladdr 验明镜像，拒绝系统框架；拿不到可信实现则直接返回 ——
/// 宁可不清空，也不调用一份会崩的指针。
static void pojavClearGLErrors(void) {
    NSString *renderer = NSProcessInfo.processInfo.environment[@"AMETHYST_RENDERER"];
    if (renderer.length == 0) return;

    NSString *rpath = [NSString stringWithFormat:@"@rpath/%@", renderer];
    void *handle = dlopen(rpath.UTF8String, RTLD_NOLOAD);
    if (handle == NULL) {
        NSDebugLog(@"[egl_bridge] clearGLErrors: %@ not mapped, skipped", renderer);
        return;
    }
    void *sym = dlsym(handle, "glGetError");
    if (sym == NULL) {
        NSDebugLog(@"[egl_bridge] clearGLErrors: glGetError not exported by %@", renderer);
        return;
    }
    Dl_info info;
    if (dladdr(sym, &info) == 0 || info.dli_fname == NULL) return;
    if (strstr(info.dli_fname, "OpenGLES.framework") != NULL ||
        strstr(info.dli_fname, "OpenGL.framework") != NULL) {
        NSLog(@"[egl_bridge] clearGLErrors: rejecting system stub (%s)", info.dli_fname);
        return;
    }

    // 不依赖 GL 头文件：glGetError 的返回类型即 GLenum(unsigned int)，
    // GL_NO_ERROR 为 0。
    typedef unsigned int (*glGetError_fn)(void);
    glGetError_fn getError = (glGetError_fn)sym;

    // 上限防御：即便实现异常（恒返回非 0）也不至于死循环。
    const int kMaxDrain = 32;
    int drained = 0;
    while (getError() != 0 && drained < kMaxDrain) drained++;

    NSLog(@"[egl_bridge] clearGLErrors: drained %d pending GL error(s) (via %s)",
          drained, info.dli_fname);
}

void pojavMakeCurrent(basic_render_window_t* window) {
    if (g_pojavContextIsVulkanLayer) {
        NSLog(@"[egl_bridge] pojavMakeCurrent ignored: Vulkan path (CAMetalLayer), no EGL context to make current");
        return;
    }
    if (!br_make_current) {
        NSLog(@"[egl_bridge] pojavMakeCurrent skipped: br_make_current is NULL");
        return;
    }
    NSLog(@"[egl_bridge] pojavMakeCurrent: window=%p", window);
    br_make_current(window);
}

void* pojavCreateContext(basic_render_window_t* contextSrc) {
    // 用全局幂等标志而非局部 static：SDL3 路径下 SDL_GL_LoadLibrary 已通过
    // pojavInitOpenGLForSDL3() 完成初始化，此处若用局部 static 判定为"未初始化"，
    // 会再调一次完整的 pojavInitOpenGL()，在 SDL 的原生线程上触发 JNI 调用。
    if (!pojavIsOpenGLInited()) {
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
        g_pojavContextIsVulkanLayer = YES;
        return (__bridge void *)SurfaceViewController.surface.layer;
    }

    // GL 路径（clientAPI == GLFW_OPENGL_API 或 GLFW_OPENGL_ES_API）
    // MC 26.2+ graphicsApi=prefer_opengl 或 default（OpenGL 路径）会走这里
    // 调用 br_init_context 创建真实 EGL/GL 上下文
    // 即使 renderer=libMoltenVK.dylib，pojavInitOpenGL 已设置 GL bridge（set_gl_bridge_tbl），
    // 所以这里会调用 gl_init_context 创建 ANGLE Metal EGL 上下文
    NSLog(@"[egl_bridge] OpenGL path: creating EGL/GL context via br_init_context");
    basic_render_window_t* bundle = (basic_render_window_t*)br_init_context(contextSrc);
    // EGL 的 current context 是线程级的。MobileGlues 的 constructor 在 JVM 启动前于
    // 启动器线程建了一个 32x32 的 ES 2.0 pbuffer 并 makeCurrent，而 MC 的 Render thread
    // 上根本没有 current context —— 于是 LWJGL 的 GL.createCapabilities() 探测
    // GL_MAJOR_VERSION 失败，抛 "There is no OpenGL context current"。
    // 本函数由 Render thread 调用，因此在此处立即 makeCurrent 即可覆盖那条残留。
    // SDL3 路径随后调用的 SDL_GL_MakeCurrent 会重复设置一次，幂等无害。
    if (bundle != NULL) {
        NSLog(@"[egl_bridge] pojavCreateContext: making bundle=%p current on this thread", bundle);
        pojavMakeCurrent(bundle);
        // 上下文刚在本线程 current，此时清空 MobileGlues constructor 阶段遗留的
        // 错误码，避免 MC 的 glGetError() 可用性判定读到残留而被迫回退 Vulkan。
        pojavClearGLErrors();
    } else {
        NSLog(@"[egl_bridge] pojavCreateContext: br_init_context returned NULL, skipping makeCurrent");
    }
    return bundle;
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

