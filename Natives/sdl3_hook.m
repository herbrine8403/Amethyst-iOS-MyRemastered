// sdl3_hook.m — SDL3 兼容层，移植自 ZalithLauncher2 的
// ZalithLauncher/src/main/jni/sdl_hook.c（Android 端，基于 bytehook）。
//
// iOS 上没有 bytehook，等价机制是 main_hook.m 里 fishhook 住的 dlsym
// （hooked_dlsym）。LWJGL 通过 dlsym 取 SDL 函数指针后直接调用，不走
// __la_symbol_ptr，所以必须在 dlsym 层拦 —— 这和 SDL_SetWindowMouseGrab
// 用的是同一条路子。SDL 内部调用自己的函数不经过 dlsym，因此不会被误伤。
//
// 解决的问题（均与 MC 26.x 的 RenderPearl 相关）：
//
// 1. 移动渲染器都是 OpenGL ES 实现，而 MC 按桌面 GL 惯例初始化 SDL，
//    非 ES 的 profile 请求会被宿主拒绝。建窗前强制切到 ES profile。
//
// 2. MC 26.3 ss9+ 在设备初始化时先建一个隐藏工具窗口（GL 上下文依附其上），
//    随后主窗口创建被拒；销毁工具窗口又会使其上的 GL surface 失效。
//    故把后续建窗请求重定向到首个窗口。
//
// 3. MC 26.3 要求 SDL 与 LWJGL 使用同一 Vulkan 加载器实例（校验
//    vkGetInstanceProcAddr 指针一致），而 SDL 只能按路径加载。若启动器已
//    持有句柄（记录在环境变量里），SDL 加载 libvulkan 时把该句柄还回去。
//
// 4. EGL 代理：eglChooseConfig / eglCreateContext 首选请求失败后做兼容
//    重试（RENDERABLE_TYPE 归一化、剔除 KHR 版本属性、CV=2 兜底）。
//
// 全部行为可用环境变量关闭，默认只在对移动 ES 渲染器时生效：
//   AMETHYST_SDL_GLES_COMPAT=0    关闭 ES profile 强制与 EGL 代理
//   AMETHYST_SDL_REUSE_WINDOW=0   关闭主窗口复用
//   AMETHYST_VULKAN_PTR=<hex>     启用 SDL_LoadObject 句柄共享

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "utils.h"
extern CALayer *Amethyst_SDL3RenderLayer(void);
static void ame_applyLauncherResolutionToSDLLayer(void);

#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdatomic.h>   // Task 56：丢弃计数（多线程安全）
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>   // strcasecmp
#include <sys/types.h>

#pragma mark - SDL3 常量（与 SDL_video.h 对齐，避免依赖 SDL 头文件）

// SDL_GLAttr：从 0 开始顺序计数，CONTEXT_PROFILE_MASK 是第 21 个
#define AME_SDL_GL_CONTEXT_PROFILE_MASK 20
// SDL_GLProfile
#define AME_SDL_GL_CONTEXT_PROFILE_ES 0x0004

#pragma mark - EGL 常量（自给自足，不依赖 EGL 头文件是否存在）

#define AME_EGL_NONE 0x3038
#define AME_EGL_RENDERABLE_TYPE 0x3040
#define AME_EGL_OPENGL_ES_BIT 0x0001
#define AME_EGL_OPENGL_ES2_BIT 0x0004
#define AME_EGL_OPENGL_ES3_BIT 0x0040
#define AME_EGL_OPENGL_BIT 0x0008
// 注意：EGL_CONTEXT_MAJOR_VERSION 与 EGL_CONTEXT_CLIENT_VERSION 同为 0x3098，
// 这是 EGL 的历史遗留（ZL2 代码里也是这个值）。
#define AME_EGL_CONTEXT_CLIENT_VERSION 0x3098
#define AME_EGL_CONTEXT_MAJOR_VERSION_KHR 0x3098
#define AME_EGL_CONTEXT_MINOR_VERSION_KHR 0x30FB

#pragma mark - 真实 SDL 函数指针

// SDL3 里 bool 就是 C99 _Bool（1 字节），这里用 int 做 ABI 安全的返回类型，
// 只取其"非零即成功"的语义，避免与 Objective-C 的 BOOL 混淆。
typedef bool (*ame_fn_SDL_GL_SetAttribute)(int attr, int value);
typedef void *(*ame_fn_SDL_CreateWindow)(const char *title, int w, int h, uint32_t flags);
typedef void *(*ame_fn_SDL_CreateWindowWithProperties)(uint32_t props);
typedef void (*ame_fn_SDL_DestroyWindow)(void *window);
typedef bool (*ame_fn_SDL_SetWindowSize)(void *window, int w, int h);
// Air Task 32/51/67 移植：窗口生命周期与键盘态轮询钩子签名
typedef bool (*ame_fn_SDL_HideWindow)(void *window);
typedef bool (*ame_fn_SDL_SetWindowPosition)(void *window, int x, int y);
typedef bool (*ame_fn_SDL_SetWindowFullscreen)(void *window, bool fullscreen);
typedef const bool *(*ame_fn_SDL_GetKeyboardState)(int *numkeys);
typedef bool (*ame_fn_SDL_GetWindowSize)(void *window, int *w, int *h);
typedef long long (*ame_fn_SDL_GetNumberProperty)(uint32_t props, const char *name,
                                                  long long default_value);
typedef void *(*ame_fn_SDL_LoadFunction)(void *handle, const char *name);
typedef void *(*ame_fn_SDL_EGL_GetProcAddress)(const char *proc);
typedef void *(*ame_fn_SDL_LoadObject)(const char *path);
typedef void (*ame_fn_SDL_UnloadObject)(void *handle);

// SDL3 GL 入口（被接管后转交启动器 EGL bridge）
typedef bool (*ame_fn_SDL_GL_LoadLibrary)(const char *path);
typedef void *(*ame_fn_SDL_GL_CreateContext)(void *window);
typedef bool (*ame_fn_SDL_GL_MakeCurrent)(void *window, void *context);
typedef bool (*ame_fn_SDL_GL_SwapWindow)(void *window);
typedef void *(*ame_fn_SDL_GL_GetProcAddress)(const char *proc);
typedef bool (*ame_fn_SDL_GL_SetSwapInterval)(int interval);
typedef bool (*ame_fn_SDL_GL_DestroyContext)(void *context);
typedef void *(*ame_fn_SDL_GL_GetCurrentContext)(void);

// 尺寸查询（见 ame_SDL_GetWindowSizeInPixels 处的说明）
typedef bool (*ame_fn_SDL_GetWindowSizeInPixels)(void *window, int *w, int *h);
typedef bool (*ame_fn_SDL_GL_GetDrawableSize)(void *window, int *w, int *h);
// 像素密度：MC 用它把我们从 SDL_GetWindowSizeInPixels 回报的像素换算成
// 「逻辑尺寸」，再拿逻辑尺寸去设 viewport —— 于是 2436x1125 / 3.0 =
// 812x375，画面缩在左上角。ZL2/FCL/GLFW 路径下 points 恒等于 pixels
// （scale 事实上为 1），故从不出这个偏差。这里对齐它们。
typedef float (*ame_fn_SDL_GetWindowDisplayScale)(void *window);
typedef float (*ame_fn_SDL_GetDisplayContentScale)(uint32_t displayID);
typedef float (*ame_fn_SDL_GetWindowPixelDensity)(void *window);

// 事件窗口解析回落（见 ame_SDL_GetWindowFromEvent 处的说明）
typedef void *(*ame_fn_SDL_GetWindowFromEvent)(const void *event);
typedef void *(*ame_fn_SDL_GetWindowFromID)(uint32_t id);

// 文本输入：必须在主线程调用（见 ame_SDL_StartTextInputWithProperties 处的说明）
typedef bool (*ame_fn_SDL_StartTextInput)(void *window);
typedef bool (*ame_fn_SDL_StartTextInputWithProperties)(void *window,
                                                        unsigned long long props);
typedef bool (*ame_fn_SDL_StopTextInput)(void *window);
typedef bool (*ame_fn_SDL_SetTextInputArea)(void *window, const void *rect, int cursor);

// 子系统初始化：SDL hint 必须在 SDL_Init 之前设置才生效（见 ame_SDL_InitSubSystem）
typedef bool (*ame_fn_SDL_InitSubSystem)(uint32_t flags);
typedef bool (*ame_fn_SDL_SetHint)(const char *name, const char *value);

// 前向声明：ame_SDL_InitSubSystem 需要它，而其定义在文件后面的"渲染器分类"区
static bool ame_glBridgeEnabled(void);

static ame_fn_SDL_GL_SetAttribute ame_real_GL_SetAttribute = NULL;
static ame_fn_SDL_CreateWindow ame_real_CreateWindow = NULL;
static ame_fn_SDL_CreateWindowWithProperties ame_real_CreateWindowWithProperties = NULL;
static ame_fn_SDL_DestroyWindow ame_real_DestroyWindow = NULL;
static ame_fn_SDL_SetWindowSize ame_real_SetWindowSize = NULL;
static ame_fn_SDL_HideWindow ame_real_HideWindow = NULL;
static ame_fn_SDL_SetWindowPosition ame_real_SetWindowPosition = NULL;
static ame_fn_SDL_SetWindowFullscreen ame_real_SetWindowFullscreen = NULL;
static ame_fn_SDL_GetKeyboardState ame_real_GetKeyboardState = NULL;
static ame_fn_SDL_GetWindowSize ame_real_GetWindowSize = NULL;
static ame_fn_SDL_GetNumberProperty ame_real_GetNumberProperty = NULL;
static ame_fn_SDL_LoadFunction ame_real_LoadFunction = NULL;
static ame_fn_SDL_EGL_GetProcAddress ame_real_EGL_GetProcAddress = NULL;
static ame_fn_SDL_LoadObject ame_real_LoadObject = NULL;
static ame_fn_SDL_UnloadObject ame_real_UnloadObject = NULL;

static ame_fn_SDL_GL_LoadLibrary ame_real_GL_LoadLibrary = NULL;
static ame_fn_SDL_GL_CreateContext ame_real_GL_CreateContext = NULL;
static ame_fn_SDL_GL_MakeCurrent ame_real_GL_MakeCurrent = NULL;
static ame_fn_SDL_GL_SwapWindow ame_real_GL_SwapWindow = NULL;
static ame_fn_SDL_GL_GetProcAddress ame_real_GL_GetProcAddress = NULL;
static ame_fn_SDL_GL_SetSwapInterval ame_real_GL_SetSwapInterval = NULL;
static ame_fn_SDL_GL_DestroyContext ame_real_GL_DestroyContext = NULL;
static ame_fn_SDL_GL_GetCurrentContext ame_real_GL_GetCurrentContext = NULL;
static ame_fn_SDL_GetWindowSizeInPixels ame_real_GetWindowSizeInPixels = NULL;
static ame_fn_SDL_GL_GetDrawableSize ame_real_GL_GetDrawableSize = NULL;
static ame_fn_SDL_GetWindowDisplayScale ame_real_GetWindowDisplayScale = NULL;
static ame_fn_SDL_GetDisplayContentScale ame_real_GetDisplayContentScale = NULL;
static ame_fn_SDL_GetWindowPixelDensity ame_real_GetWindowPixelDensity = NULL;
static int ame_scaleOverrideLogBudget = 4;

static ame_fn_SDL_GetWindowFromEvent ame_real_GetWindowFromEvent = NULL;
static ame_fn_SDL_GetWindowFromID ame_real_GetWindowFromID = NULL;
static ame_fn_SDL_StartTextInput ame_real_StartTextInput = NULL;
static ame_fn_SDL_StartTextInputWithProperties ame_real_StartTextInputWithProperties = NULL;
static ame_fn_SDL_StopTextInput ame_real_StopTextInput = NULL;
static ame_fn_SDL_SetTextInputArea ame_real_SetTextInputArea = NULL;
static ame_fn_SDL_InitSubSystem ame_real_InitSubSystem = NULL;
static ame_fn_SDL_SetHint ame_real_SetHint = NULL;

// SDL3 的 SDL_Rect：{ float x, float y, float w, float h; }
typedef struct { float x, y, w, h; } ame_SDLRect;

#pragma mark - EGL 真实函数（首次解析后固定，避免跨 loader 调用）

typedef int (*ame_fn_eglChooseConfig)(void *dpy, const int *attrib_list, void **configs,
                                      int config_size, int *num_config);
typedef void *(*ame_fn_eglCreateContext)(void *dpy, void *config, void *share,
                                         const int *attrib_list);
typedef int (*ame_fn_eglSwapBuffers)(void *dpy, void *surface);

static ame_fn_eglChooseConfig ame_orig_eglChooseConfig = NULL;
static ame_fn_eglCreateContext ame_orig_eglCreateContext = NULL;
static ame_fn_eglSwapBuffers ame_orig_eglSwapBuffers = NULL;

#pragma mark - 外部依赖

// main_hook.m 提供的"绕过 hook"的 dlsym，避免本文件内解析 SDL 符号时
// 又绕回 hooked_dlsym 造成递归。
extern void *amethyst_orig_dlsym(void *handle, const char *name);

// SurfaceViewController.m 提供：SDL3 呈现层不变量执法（主线程调用）。
// 隐藏 SDL 自有 UIWindow（空窗黑盖子）+ 揭开被供应商嵌入补丁隐藏的
// GameSurfaceView + SDL 嵌入视图透明 + z 序钉扎。
// NOTE: 必须声明在使用点之前，否则 clang 判 implicit declaration 并报错。
extern BOOL Amethyst_EnforceSDL3Presentation(void);

static void *ame_real_dlsym(const char *name) {
    if (amethyst_orig_dlsym) {
        void *p = amethyst_orig_dlsym(RTLD_DEFAULT, name);
        if (p != NULL) return p;
    }
    return dlsym(RTLD_DEFAULT, name);
}

#pragma mark - 渲染器分类

static bool ame_envFlagOn(const char *name, bool defaultValue) {
    const char *v = getenv(name);
    if (v == NULL || v[0] == '\0') return defaultValue;
    return !(strcmp(v, "0") == 0 || strcasecmp(v, "false") == 0 ||
             strcasecmp(v, "no") == 0 || strcasecmp(v, "off") == 0);
}

// 启动器把 EGL 库路径放在 POJAVEXEC_EGL（Android 传统），iOS 侧沿用
// AMETHYST_RENDERER。两个都查，保持与 ZL2 语义一致。
//
// iOS 上必须额外查 AMETHYST_RENDERER（Air 662d6e24 的修复）：
// iOS 的 MobileGlues dylib 是全小写的 libmobileglues.dylib
// （RENDERER_NAME_MOBILEGLUES），而 **POJAVEXEC_EGL 对 MG 从不设置** ——
// 那个变量只有 LTW 会设。于是本函数在 iOS 上对 MG 恒返回 false，
// ame_sdlGlesCompatEnabled() 因此失去对 MG 的识别。
static bool ame_isMobileGluesEgl(void) {
    const char *egl = getenv("POJAVEXEC_EGL");
    if (egl != NULL) {
        const char *base = strrchr(egl, '/');
        base = (base != NULL) ? base + 1 : egl;
        if (strstr(base, "mobileglues") != NULL) return true;
    }
    // 大小写必须匹配 iOS 的实际文件名：libmobileglues.dylib 全小写。
    // 这里刻意用 strstr 而非 strcmp，与同文件 ame_glBridgeEnabled() 的
    // 'mobileglues' 检查保持同一口径（后者本就是对的，GL 桥因此一直可用；
    // 本门控此前漏了同样的检查）。
    const char *renderer = getenv("AMETHYST_RENDERER");
    if (renderer != NULL && strstr(renderer, "mobileglues") != NULL) return true;
    return false;
}

// GLES 兼容层（强制 ES profile、EGL 重试）只对移动 ES 渲染器生效，
// 桌面 / OSMesa 路径不得被 ES 化 —— 否则 zink 会被错误处理。
static bool ame_sdlGlesCompatEnabled(void) {
    if (!ame_envFlagOn("AMETHYST_SDL_GLES_COMPAT", true)) return false;

    const char *renderer = getenv("AMETHYST_RENDERER");
    if (renderer == NULL || renderer[0] == '\0') return ame_isMobileGluesEgl();

    if (strstr(renderer, "desktopgl") != NULL) return false;
    if (strncmp(renderer, "gallium_", 8) == 0) return false;      // OSMesa 系
    if (strncmp(renderer, "libOSMesa", 9) == 0) return false;     // zink（含版本号）
    if (strcmp(renderer, "vulkan_zink") == 0) return false;       // zink
    if (strstr(renderer, "libMoltenVK") != NULL) return false;    // 原生 Vulkan
    if (strncmp(renderer, "opengles", 8) == 0) return true;       // 内置 GL4ES
    if (strstr(renderer, "libMobileGL") != NULL) {
        // MobileGL 的两个变体都不走 ES 强制。
        //
        // 这里原先按 "-gles" 分流，把 libMobileGL-gles.dylib 当成「ES 实现
        // → 强制 ES」，注释也是这么写的。那个判断是错的，代价是 26.3 OpenGL
        // 全黑。
        //
        // utils.h（本仓库自己的权威定义）写得很清楚：
        //   libMobileGL.dylib      -> DirectVulkan（GL -> Vulkan -> MoltenVK）
        //   libMobileGL-gles.dylib -> DirectGLES  （GL -> OpenGL ES）
        // 而 isDesktopGLRenderer() 把两者一并归为 desktop GL，理由也写在
        // gl_bridge.m：MobileGL 对外导出的是 desktop OpenGL，必须配
        // EGL_OPENGL_BIT + eglBindAPI(EGL_OPENGL_API)。
        //
        // 关键在 DirectGLES 这个名字的含义：它是「内部把 GL 翻译到 OpenGL ES」，
        // 也就是它的**后端**是 ES，而不是说它对外提供 ES 上下文。对外它仍然是
        // desktop GL —— 正因如此 MC 才会发桌面 GLSL 给它翻译。
        //
        // 强制 ES 之后，config 声明 EGL_OPENGL_ES3_BIT、eglBindAPI 绑 ES、
        // 上下文按 ES3 建，而渲染器导出的是 desktop GL 入口，两边对不上：
        // 渲染循环照跑、eglSwapBuffers 全部成功、零 GL 错误，屏幕全黑。
        //
        // Air 启动器（同源渲染栈）的对应函数里根本没有 MobileGL 这一支 ——
        // 它只识别 mobileglues / mithril / POJAVEXEC_EGL，MobileGL 一律按
        // desktop GL 处理，这与其 gl_init_context 的 isDesktopGLRenderer()
        // 完全一致。此处回归同一行为。
        return false;
    }
    if (strstr(renderer, "libmithril") != NULL) return true;      // Mithril
    return ame_isMobileGluesEgl();                                // MobileGlues
}

#pragma mark - 1) 强制 ES profile

static bool ame_forcedEsProfile = false;

// SDL3 路径下"最终想要的"上下文语义，供 EGL bridge 决策（见文件末尾的
// amethyst_sdl3_wants_gles_context()）。
//
// 为什么需要它：ZL2 的 forceEglProfileEs() 只调 SDL_GL_SetAttribute(ES)，
// 随后由 SDL 自己的 EGL 后端按该属性建上下文，因此"强制"天然生效。
// 而 iOS 侧 SDL_GL_CreateContext 被本模块接管并转交 EGL bridge（见 5)），
// SDL 内部的属性状态对最终上下文不再有任何影响 —— 这正是此前
// "forced ... = ES" 打了日志、桥却照旧打印 "Binding to desktop OpenGL" 的原因。
// 故在此记下强制结果，让 gl_bridge.m 能按它选择 ES / desktop。
static bool ame_sdl3WantsGles = false;

static void ame_forceEglProfileEs(void) {
    if (!ame_sdlGlesCompatEnabled()) return;
    if (ame_real_GL_SetAttribute == NULL) {
        ame_real_GL_SetAttribute = (ame_fn_SDL_GL_SetAttribute)ame_real_dlsym("SDL_GL_SetAttribute");
    }
    if (ame_real_GL_SetAttribute != NULL) {
        ame_real_GL_SetAttribute(AME_SDL_GL_CONTEXT_PROFILE_MASK, AME_SDL_GL_CONTEXT_PROFILE_ES);
        ame_forcedEsProfile = true;
        ame_sdl3WantsGles = true;
        NSDebugLog(@"[SDLHook] forced SDL_GL_CONTEXT_PROFILE_MASK = ES");
    } else {
        NSDebugLog(@"[SDLHook] SDL_GL_SetAttribute unresolved, cannot force ES profile");
    }
}

#pragma mark - 2) 主窗口复用

static void *ame_primaryWindow = NULL;
static unsigned int ame_primaryWindowRefs = 0;
static int ame_primaryWindowW = 0;
static int ame_primaryWindowH = 0;

static bool ame_shouldReusePrimaryWindow(void) {
    // 判定必须与 ame_sdlGlesCompatEnabled() 解耦 —— 这是从 ZL2 对齐来的关键差异，
    // ZL2 的 shouldReusePrimaryWindow() 只看环境变量，不看 sdlGlesCompatEnabled()。
    //
    // 若沿用耦合写法，一旦把 DirectVulkan（libMobileGL.dylib）移出 ES 强制，
    // 复用会连带被关闭；而 iOS 的 UIKit_CreateWindow 硬性限制每 display 只允许
    // 一个窗口（"Only one window allowed per display."），主窗口创建随即返回 NULL，
    // MC 抛 "Failed to create window"（实测 AMETHYST_SDL_REUSE_WINDOW=0 即此结果）。
    // 即"是否复用"取决于平台单窗口约束，"是否强制 ES"取决于渲染器实现，两回事。
    if (!ame_envFlagOn("AMETHYST_SDL_REUSE_WINDOW", true)) return false;

    // Task 80：GL bridge 接管的渲染器（zink / libOSMesa / gallium_* / vulkan_zink，
    // 以及 gl4es / ltw 等 EGL 转译层）同样必须复用主窗口。
    //
    // 设备证据（0441401，用户上报“zink 在 26.3 仍回退”）：Task 79 的 provider-mirror
    // 让 LoadLibrary / CreateContext / MakeCurrent 全部通过（log 实锤 zink 上下文
    // 创建成功、MoltenVK 1.4.2 Vulkan 1.4.357 初始化），但 26.3 renderpearl 的
    // GlDevice 构造器随后创建第二个 "Hidden Test Window" 探针（创建后立即销毁，
    // 仅用于验证 GL 环境健康）——iOS UIKit 后端每个显示器只允许一个窗口，
    // 真实 SDL_CreateWindow 返回 NULL → BackendCreationException: "Failed to
    // create window for OpenGL after creating context" → 回退原生 Vulkan，
    // ZinkConfig / stride fix / shaderc 缓存全部空转。
    //
    // MobileGlues 路径早已靠复用迈过这道门（0cc265f 实证：reusing primary
    // window, refs=2 → DestroyWindow skipped, refs=1 → Using graphics backend
    // OpenGL）。zink 呈现走 osm_swap_buffers → SurfaceViewController.surface.layer，
    // 不依赖任何 SDL 窗口，复用无副作用；引用计数（refs）天然消化探针窗口的
    // 立即销毁。逃生阀不变：AMETHYST_ZINK_GL_BRIDGE=0 → glBridgeEnabled 对 zink
    // 返回 false → 复用同步关闭，回到 Task 79 之前的旧行为。
    if (ame_glBridgeEnabled()) {
        return ame_envFlagOn("AMETHYST_SDL_REUSE_WINDOW", true);
    }

    // 仍排除桌面 / OSMesa 系：它们不经本文件的 EGL 兼容逻辑，改动无益且可能
    // 波及已验证路径。
    const char *renderer = getenv("AMETHYST_RENDERER");
    if (renderer != NULL && renderer[0] != '\0') {
        if (strstr(renderer, "desktopgl") != NULL) return false;
        if (strncmp(renderer, "gallium_", 8) == 0) return false;
        if (strncmp(renderer, "libOSMesa", 9) == 0) return false;
        if (strcmp(renderer, "vulkan_zink") == 0) return false;
        if (strstr(renderer, "libMoltenVK") != NULL) return false;
    }
    return true;
}

// iOS 专有：ZL2 明确注释了"尺寸无需额外处理，由 Android Surface 决定（创建时即
// 取 Surface 尺寸，与请求值无关）"。iOS 没有这个前提 —— SDL 的 UIKit 后端按
// 请求值建窗口，于是 RenderPearl 那个隐藏工具窗口就是实打实的 320x480。
//
// 主窗口复用后 MC 拿到的仍是 320x480 这个尺寸，会按它设置 viewport / GUI scale；
// 而 EGL surface 由 SurfaceViewController 的 layer 独立创建（实测 1826x844），
// 两者对不上 → 画面全黑（输入正常，因为控制层是启动器自己的 view）。
// 故复用时必须把窗口尺寸同步成当前请求值。
// 在视图层级中定位 SDL 的 SDL_uikitview。
// 不走 SDL 属性 API（SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER 的字符串值随版本可能
// 变动），改为直接遍历层级匹配类名 —— SDL 的视图已被启动器嵌进宿主 view，
// 一定在同一棵树上，不依赖任何 SDL 符号。
// Air Task52 对齐：嵌入宿主后的 SDL 视图引用（供 gl_bridge 的可见性/z 序
// 守卫做同一性比较）。只保存不持有（__bridge 裸指针语义由访问器提供）。
static UIView *ame_embeddedSDLView = NULL;

static UIView *ame_findSDLView(UIView *from) {
    Class sdlClass = NSClassFromString(@"SDL_uikitview");
    if (sdlClass == nil || from == nil) return nil;

    UIView *root = from;
    while (root.superview != nil) root = root.superview;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count > 0) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ([v isKindOfClass:sdlClass]) return v;
        [stack addObjectsFromArray:v.subviews];
    }
    return nil;
}

// iOS 专有：ZL2 明确注释了"尺寸无需额外处理，由 Android Surface 决定（创建时即
// 取 Surface 尺寸，与请求值无关）"。iOS 没有这个前提 —— SDL 的 UIKit 后端按
// 请求值建窗口，于是 RenderPearl 那个隐藏工具窗口就是实打实的 320x480。
#pragma mark - EGL surface 真实像素尺寸

// —— 尺寸兜底：绝不能回落到 SDL 内部记录的 320x480 ——
//
// MC 26.3 先建一个 320x480 的隐藏工具窗口（日志里是
// "RenderPearl OpenGL Hidden Utility Window 320x480"），主窗口随后被重定向到它
// （主窗口复用，见 ame_SDL_CreateWindow）。若此刻 EGL surface 尚未建立、
// drawableSize 仍为 0，尺寸查询便会回落 SDL 自身记录的值 —— 也就是 320x480。
//
// MC 一旦把该值用于 viewport / GUI 布局，画面就只占屏幕左上角一小块，且必须
// 手动改一次分辨率（触发重建 drawableSize 与重新查询）才恢复 —— 正是观察到的
// 症状：「默认 100% 黑屏，先调 75% 画面才出现，再调回 100% 才正常」。
//
// 因此兜底必须给出「合理的全屏像素」，而不是把 SDL 的内部值交回去。

// 尺寸查询日志限流：MC 每帧会多次查询，全量打印会淹没日志。
// 只保留前若干次，足以看清 MC 实际拿到的是什么值。
static int ame_sizeLogBudget = 16;
#define AME_SIZE_LOG(fmt, ...)                                  \
    do {                                                        \
        if (ame_sizeLogBudget > 0) {                            \
            ame_sizeLogBudget--;                                \
            NSDebugLog((fmt), ##__VA_ARGS__);                   \
        }                                                       \
    } while (0)

static bool ame_screenFallbackPixelSize(int *outW, int *outH) {
    if (outW == NULL || outH == NULL) return false;
    UIScreen *screen = [UIScreen mainScreen];
    if (screen == nil) return false;
    CGRect b = screen.bounds;
    CGFloat s = screen.scale;
    if (s > 0.0 && b.size.width > 1.0 && b.size.height > 1.0) {
        *outW = (int)round(b.size.width * s);
        *outH = (int)round(b.size.height * s);
        return true;
    }
    return false;
}

// 取 EGL surface 的真实像素尺寸 —— 即 CAMetalLayer.drawableSize，由启动器配成
// physicalSize x resolutionScale。这是 ANGLE 实际渲染的分辨率。
// —— 尺寸缓存：为什么必须有 ——
// 本函数读取 UIKit 视图层级（UIView -> CALayer -> drawableSize），只能在主线程
// 调用。而 SDL_GL_SwapWindow 由 Render thread 每帧调用，若在此读取，等于每秒
// 60 次跨线程访问 UIKit，与主线程布局/呈现竞争 —— 这正是接入 swap 前观测后
// 开始闪退的原因（同样代码放在 glViewport 里没事，因为那不是每帧路径）。
//
// 因此：真实读取只在主线程进行，结果缓存下来；非主线程一律只读缓存，
// 绝不触碰 UIKit。缓存未建立时用 UIScreen 物理分辨率兜底（读的是屏幕属性，
// 不是视图层级，且与 drawableSize 至多差 1 像素的取整）。
#define AME_SURF_CACHE_MAX_AGE 120  // 约 2 秒 @60fps 后允许主线程刷新一次

static int  ame_surfCacheW = 0;
static int  ame_surfCacheH = 0;
static bool ame_surfCacheValid = false;
static int  ame_surfCacheAge = 0;

static void ame_surfCacheInvalidate(void) {
    ame_surfCacheValid = false;
    ame_surfCacheAge = 0;
}

// SDL 窗口的 points 尺寸（建窗后固定）。viewport 判定要用它，但在每帧路径上
// 反复调用 SDL 去问并不划算，故缓存；窗口尺寸变更时显式置零重取。
static int ame_sdlPointW = 0;
static int ame_sdlPointH = 0;
static void ame_sdlPointCacheInvalidate(void) { ame_sdlPointW = 0; ame_sdlPointH = 0; }

static bool ame_eglSurfacePixelSizeFromUIKit(int *outW, int *outH) {
    if (outW == NULL || outH == NULL) return false;

    UIView *gsv = nil;
    Class svc = NSClassFromString(@"SurfaceViewController");
    if (svc != nil && [svc respondsToSelector:NSSelectorFromString(@"surface")]) {
        id obj = [svc performSelector:NSSelectorFromString(@"surface")];
        if ([obj isKindOfClass:[UIView class]]) gsv = (UIView *)obj;
    }
    if (gsv == nil) return false;
    CALayer *layer = gsv.layer;
    if (layer == nil) return false;

    // 优先取 CAMetalLayer.drawableSize（gl_bridge 建 surface 用的就是它）
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
    // 回退：bounds x contentsScale（启动器配置两者一致，最多差 1 像素的取整）
    CGFloat scale = layer.contentsScale;
    CGSize bs = layer.bounds.size;
    if (scale > 0.0 && bs.width > 1.0 && bs.height > 1.0) {
        *outW = (int)round(bs.width * scale);
        *outH = (int)round(bs.height * scale);
        return true;
    }
    return ame_screenFallbackPixelSize(outW, outH);
}

// —— 从 EGL 本身问尺寸 ——
// 这是最干净的一路：eglQuerySurface 问的是 surface 对象，不涉及 UIView /
// CAMetalLayer，因此可以在渲染线程安全调用；而且它返回的正是建 surface 时用的
// 真实像素尺寸，天然反映启动器的 resolutionScale（100% -> 2436x1124，
// 75% -> 1827x843），不像 UIScreen 兜底那样恒为全屏分辨率。
// 有了它，渲染线程再也不必为拿一个尺寸而去读 UIKit。
// ame_rendererHandle 的实现在文件后部（约第 1400 行），此处提前声明以便本节使用。
static void *ame_rendererHandle(void);

// ame_glSymbolTrusted 的实现在文件后部（GL 入口点解析节）。本节在 460 行附近
// 就要用它校验 EGL 符号镜像，缺少前向声明会被 clang 判为隐式函数声明
// （-Wimplicit-function-declaration 在 C99 下是 error，CI 因此 exit code 2）。
static bool ame_glSymbolTrusted(const void *sym);

#define AME_EGL_DRAW     0x3059
// Air Task 58 同类根因修正：官方 egl.h 定义为 EGL_HEIGHT=0x3056、
// EGL_WIDTH=0x3057。旧代码误用 0x305D/0x305E —— 这两个是 EGL_TEXTURE_RGB /
// EGL_TEXTURE_RGBA（pbuffer 纹理格式取值 1/2），不是表面尺寸属性。
// eglQuerySurface 传入非法属性恒返回 EGL_FALSE -> ame_surfaceSizeFromEGL 从未
// 成功过，ame_eglSurfacePixelSize 全程退回 UIKit 缓存/屏幕物理尺寸，"反映
// resolutionScale" 落空：非 100% 分辨率下 viewport 与真实 surface 失配，
// 且 SDL 尺寸查询与 0x206/0x207/0x208 改写全部基于错误基准。改用官方宏。
#define AME_EGL_WIDTH    0x3057
#define AME_EGL_HEIGHT   0x3056

typedef void *(*ame_fn_eglGetCurrentDisplay)(void);
typedef void *(*ame_fn_eglGetCurrentSurface)(int readdraw);
typedef int   (*ame_fn_eglQuerySurface)(void *dpy, void *surf, int attribute, int *value);

static bool ame_surfaceSizeFromEGL(int *outW, int *outH) {
    // 默认关闭；AMETHYST_EGL_SIZE_QUERY=1 才启用。
    //
    // eglGetCurrentDisplay 是 EGL 1.5 入口，而 MobileGlues 的后端（iOS 上的
    // EGL 1.4 实现）并不导出它。MG 的 MobileGlues-cpp/egl/egl.cpp 里是：
    //     EGL_API EGLDisplay eglGetCurrentDisplay(void) {
    //         LOG_D("eglGetCurrentDisplay");
    //         LOAD_EGL(eglGetCurrentDisplay)      // 后端没有 -> 指针为 NULL
    //         return egl_eglGetCurrentDisplay();  // 直接跳转 0x0
    //     }
    // LOAD_EGL 宏（gles/loader.h）解析失败时只打一行日志、随后照样返回 NULL，
    // 调用方无从感知，于是首次调用即 SIGSEGV(pc=0x0)：
    //     C [libmobileglues.dylib+0xd8238]  eglGetCurrentDisplay+0x7c
    // 本函数正是那个调用方：它在 SDL_GL_LoadLibrary 之前被首次尺寸查询触发，
    // 崩溃点因此恰好落在「最后一个 hook 安装之后、任何渲染日志之前」。
    //
    // 关闭后由 ame_eglSurfacePixelSize 走 UIKit 路径 —— CAMetalLayer.drawableSize
    // 正是 gl_bridge 建 surface 时使用的尺寸（同样反映 resolutionScale），
    // 与 egl_bridge 的 pojavEglSurfacePixelSize 同源：返回值不变，零风险。
    if (!ame_envFlagOn("AMETHYST_EGL_SIZE_QUERY", false)) return false;

    void *rh = ame_rendererHandle();
    if (rh == NULL) return false;

    static ame_fn_eglGetCurrentDisplay  gcd = NULL;
    static ame_fn_eglGetCurrentSurface  gcs = NULL;
    static ame_fn_eglQuerySurface       qs  = NULL;
    static bool resolved = false;

    // 不做一次性锁死，且必须校验镜像可信性。
    //
    // 原实现在首次调用时把 resolved 永久置 true，之后即使指针落在不可信镜像
    // （另一份 EGL 实现）也不再重新解析。eglGetCurrentDisplay 取自镜像 A、
    // eglQuerySurface 取自镜像 B 时，qs(dpy, ...) 就是跨 EGL 实现调用 ——
    // 两份实现各自维护上下文状态，一经调用即 SIGSEGV。
    //
    // 这正是 26.3 在 SDL_GL_MakeCurrent 之后崩溃的原因：本函数原先只在 swap 前
    // 调用，加到 MakeCurrent 路径后，首次解析刚好发生在 EGL 上下文刚建立的时刻，
    // 解析结果锁死为不可用的一份，随后的 qs() 直接崩。
    //
    // 改为每次校验：不可信就重新解析；拿不到可信实现则放弃 EGL 查询，
    // 由 ame_eglSurfacePixelSize 退回缓存/兜底尺寸（最坏是兜底不生效，不崩）。
    bool trusted = resolved &&
                   ame_glSymbolTrusted((const void *)gcd) &&
                   ame_glSymbolTrusted((const void *)gcs) &&
                   ame_glSymbolTrusted((const void *)qs);
    if (!trusted) {
        gcd = (ame_fn_eglGetCurrentDisplay)dlsym(rh, "eglGetCurrentDisplay");
        gcs = (ame_fn_eglGetCurrentSurface)dlsym(rh, "eglGetCurrentSurface");
        qs  = (ame_fn_eglQuerySurface)dlsym(rh, "eglQuerySurface");
        trusted = ame_glSymbolTrusted((const void *)gcd) &&
                  ame_glSymbolTrusted((const void *)gcs) &&
                  ame_glSymbolTrusted((const void *)qs);
        resolved = trusted;
        if (!trusted) {
            gcd = NULL; gcs = NULL; qs = NULL;
            return false;
        }
    }

    void *dpy = gcd();
    void *surf = gcs(AME_EGL_DRAW);
    if (dpy == NULL || surf == NULL) return false;

    int w = 0, h = 0;
    if (qs(dpy, surf, AME_EGL_WIDTH, &w) && qs(dpy, surf, AME_EGL_HEIGHT, &h) &&
        w > 0 && h > 0) {
        *outW = w;
        *outH = h;
        return true;
    }
    return false;
}

// 对外仍是 ame_eglSurfacePixelSize：全部调用点自动获得缓存语义，无需逐个改动。
static bool ame_eglSurfacePixelSize(int *outW, int *outH) {
    if (outW == NULL || outH == NULL) return false;

    // 首选 EGL 查询：线程安全、且反映 resolutionScale。拿不到再退回 UIKit 缓存。
    if (ame_surfaceSizeFromEGL(outW, outH)) return true;

    bool onMain = [NSThread isMainThread];

    if (ame_surfCacheValid) {
        // 非主线程：只读缓存，绝不触碰 UIKit。
        if (!onMain) {
            *outW = ame_surfCacheW;
            *outH = ame_surfCacheH;
            return true;
        }
        if (ame_surfCacheAge < AME_SURF_CACHE_MAX_AGE) {
            ame_surfCacheAge++;
            *outW = ame_surfCacheW;
            *outH = ame_surfCacheH;
            return true;
        }
    }

    if (!onMain) {
        // 缓存尚未建立又在渲染线程：用屏幕物理分辨率兜底，不读视图层级。
        return ame_screenFallbackPixelSize(outW, outH);
    }

    int w = 0, h = 0;
    if (ame_eglSurfacePixelSizeFromUIKit(&w, &h) && w > 0 && h > 0) {
        ame_surfCacheW = w;
        ame_surfCacheH = h;
        ame_surfCacheValid = true;
        ame_surfCacheAge = 0;
        *outW = w;
        *outH = h;
        return true;
    }
    return false;
}

// —— 窗口尺寸(points 语义)也必须回报 EGL surface 的像素尺寸 ——
// GLFW 路径下 glfwGetWindowSize() 与 glfwGetFramebufferSize() 返回同一个值：
// 两者都取 internalGetWindow(window).width，而该字段来自
// glfw.windowSize / cacio.managed.screensize，即启动器传入的物理像素。
// 于是 MC 用于 GUI 布局的「窗口尺寸」与用于渲染的「framebuffer 尺寸」恒等，
// 无论分辨率设成多少都不会错位 —— 这正是 GLFW 路径一切正常的原因。
//
// SDL3 路径下若放任 SDL 回报 points(812x375)，则
//     window size = 812x375      （GUI 布局 / 鼠标坐标空间）
//     framebuffer = EGL surface  （随 resolutionScale 变化）
// 两者不等，画面便会缩在角落或超出屏幕：25% 时 GUI 按 2436 的宽度布局、却
// 只渲染进 609 宽的区域，于是按钮「过大超出屏幕」。
// 这里因此与 GetWindowSizeInPixels 回报同一个值，对齐 GLFW 语义。
// 只改查询返回值，不触碰 SDL 内部状态，SDL 自身仍然自洽。
// ============================================================================
// Task 61（与 Air 同口径）：启动器像素尺寸单一事实源
//
// windowWidth/windowHeight 由 SurfaceViewController::updateSavedResolution 在
// 主线程写入（= physical x resolutionScale），与 CAMetalLayer.drawableSize、
// launchJVM 告知 MC 的值、MC 的输入归一化基准四者同源。
//
// 此前此处以 ame_eglSurfacePixelSize()（EGL 查询 / UIKit 缓存）为准：
//   * EGL 查询在 MobileGlues 上恒失败（EGL 1.4 无 eglGetCurrentDisplay）；
//   * UIKit 缓存存在跨线程陈旧窗口，分辨率改变后读到旧值；
// 两者都可能回报「未被 resolutionScale 缩放」的尺寸，于是
// MC viewport(全尺寸) != drawableSize(已缩放) —— 渲染内容只有左下角落进
// 呈现缓冲，表现为「调到 75/50/25% 后全屏只显示左下角」。
// 直接读全局 windowWidth/windowHeight 无缓存、无查询、恒为当前值。
// ============================================================================
static bool ame_launcherPixelSize(int *outW, int *outH) {
    if (windowWidth > 0 && windowHeight > 0) {
        if (outW != NULL) *outW = windowWidth;
        if (outH != NULL) *outH = windowHeight;
        return true;
    }
    return false;
}

static bool ame_SDL_GetWindowSize(void *window, int *w, int *h) {
    int sw = 0, sh = 0;
    if (ame_launcherPixelSize(&sw, &sh)) {
        if (w != NULL) *w = sw;
        if (h != NULL) *h = sh;
        AME_SIZE_LOG(@"[SDLHook] GetWindowSize -> %dx%d (launcher px)", sw, sh);
        return true;
    }
    if (ame_eglSurfacePixelSize(&sw, &sh)) {
        if (w != NULL) *w = sw;
        if (h != NULL) *h = sh;
        AME_SIZE_LOG(@"[SDLHook] GetWindowSize -> %dx%d (EGL surface)", sw, sh);
        return true;
    }
    // 先按主屏物理分辨率兜底：直接交回 SDL 原函数会拿到隐藏工具窗口的
    // 320x480（见 ame_screenFallbackPixelSize 处注释），MC 缓存后画面缩在角落。
    if (ame_screenFallbackPixelSize(&sw, &sh)) {
        if (w != NULL) *w = sw;
        if (h != NULL) *h = sh;
        return true;
    }
    if (ame_real_GetWindowSize != NULL) {
        return ame_real_GetWindowSize(window, w, h);
    }
    return false;
}

// —— 为什么要接管这两个查询 ——
// MC 的 viewport / framebuffer 尺寸来自它们。SDL 内部把「像素密度」固定为
// UIScreen.scale（本设备 3.0），完全不知道启动器的 resolutionScale，
// 于是无论用户设 25% 还是 100%，SDL 一律回报
// points(812x375) x 3.0 = 2436x1125。而 EGL surface 是
// physicalSize x resolutionScale，两者只在 100% 时相等：
//   100% -> 2436 vs 2436  正常
//    75% -> 2436 vs 1826  viewport 大 1.33 倍，画面被裁到左下角
//    25% -> 2436 vs  609  viewport 大 4 倍，画面严重超出屏幕
// 接管后回报 EGL surface 的真实尺寸，viewport 与 surface 严格一致；
// 而 points 仍恒为全屏逻辑尺寸（供输入坐标与 GUI 布局），两者解耦，
// 行为与 GLFW 路径一致：改分辨率只改渲染像素，画面布局不变。
static bool ame_SDL_GetWindowSizeInPixels(void *window, int *w, int *h) {
    int sw = 0, sh = 0;
    if (ame_launcherPixelSize(&sw, &sh)) {
        if (w != NULL) *w = sw;
        if (h != NULL) *h = sh;
        AME_SIZE_LOG(@"[SDLHook] GetWindowSizeInPixels -> %dx%d (launcher px)",
                     sw, sh);
        return true;
    }
    if (ame_eglSurfacePixelSize(&sw, &sh)) {
        if (w != NULL) *w = sw;
        if (h != NULL) *h = sh;
        AME_SIZE_LOG(@"[SDLHook] GetWindowSizeInPixels -> %dx%d (EGL surface)",
                     sw, sh);
        return true;
    }
    // 先按主屏物理分辨率兜底：直接交回 SDL 原函数会拿到隐藏工具窗口的
    // 320x480（见 ame_screenFallbackPixelSize 处注释），MC 缓存后画面缩在角落。
    if (ame_screenFallbackPixelSize(&sw, &sh)) {
        if (w != NULL) *w = sw;
        if (h != NULL) *h = sh;
        return true;
    }
    if (ame_real_GetWindowSizeInPixels != NULL) {
        return ame_real_GetWindowSizeInPixels(window, w, h);
    }
    return false;
}

// —— 像素密度必须回报 1.0：小窗的根因修复 ——
//
// 日志算术坐实了机制（26.3 + MobileGL 实测）：
//     EGL surface（我们回报的像素）  = 2436 x 1125
//     MC 实际设置的 viewport        =  812 x  375
//     2436/812 = 3.0     1125/375 = 3.0
// 即 MC 把像素尺寸除以设备 scale(3.0) 得到「逻辑尺寸」，再用逻辑尺寸设
// viewport —— 这正是「points 被当成像素」。此前所有补丁都试图在出口处把
// 812x375 改写回去，但改写发生在 swap（绘制之后），永远晚一帧，故无效。
//
// 根因是 SDL 的 uikit 后端把 scale 固定为 UIScreen.nativeScale：
//     UIKit_GetWindowSizeInPixels():  scale = screen.nativeScale (3.0)
// 而 GLFW 路径下 glfwGetWindowSize() 与 glfwGetFramebufferSize() 取同一个
// 字段，points 与 pixels 恒等；Android(ZL2/FCL) 后端同样如此。这三条路径
// 因此都不会出现换算偏差 —— 这就是它们没有小窗的原因。
//
// 修法是把 scale 对齐为 1.0，让 points == pixels，与上述三条路径一致。
// 渲染分辨率不受影响：画面始终绘制进 EGL surface(2436x1125)，scale 只参与
// MC 侧的换算。输入坐标由启动器按物理像素注入，不经 SDL 换算，亦不受影响。
static float ame_SDL_GetWindowDisplayScale(void *window) {
    if (ame_scaleOverrideLogBudget > 0) {
        ame_scaleOverrideLogBudget--;
        NSDebugLog(@"[SDLHook] GetWindowDisplayScale -> 1.00 (forced; points == pixels)");
    }
    return 1.0f;
}

static float ame_SDL_GetDisplayContentScale(uint32_t displayID) {
    return 1.0f;
}

// SDL3 还有第三个像素密度入口：SDL_GetWindowPixelDensity()。若放任它回报
// 3.0，MC 仍能把像素除回 points(812x375)。与上面两个一并对齐为 1.0。
static float ame_SDL_GetWindowPixelDensity(void *window) {
    if (ame_scaleOverrideLogBudget > 0) {
        ame_scaleOverrideLogBudget--;
        NSDebugLog(@"[SDLHook] GetWindowPixelDensity -> 1.00 (forced; points == pixels)");
    }
    return 1.0f;
}

// —— 显示模式：全屏窗口尺寸的真正来源 ——
//
// 上面三个 scale 入口已统一为 1.0（points == pixels），但 MC 26.3 的窗口仍是
// 全屏窗口：全屏窗口的尺寸不来自 SDL_SetWindowSize()，而来自当前显示模式
// （SDL_GetCurrentDisplayMode / GetDesktopDisplayMode）。uikit 后端给出的显示
// 模式是 812x375（屏幕 points），于是：
//     viewport  = 812x375          -> 小窗（OpenGL 与 Vulkan 同样）
//     guiScale  = 由 812x375 推算  -> 1（物品栏只有 20px 高，点不中）
//     改分辨率  = 只改 EGL surface -> MC 侧尺寸不变，表现为"调整分辨率无效"
// 这三点与实测日志逐条吻合，且解释了"手动调一次分辨率才恢复"：手动调整会让
// MC 重新走一次非全屏尺寸，才暂时拿到正确值。
//
// 因此把显示模式也对齐到像素，与 points == pixels 的既定约定一致。
typedef struct AME_DisplayMode {
    uint32_t displayID;
    int format;
    int w;
    int h;
    float pixel_density;
    float refresh_rate;
    void *internal;
} AME_DisplayMode;

typedef const AME_DisplayMode *(*ame_fn_GetCurrentDisplayMode)(uint32_t);
typedef const AME_DisplayMode *(*ame_fn_GetDesktopDisplayMode)(uint32_t);
typedef bool (*ame_fn_GetClosestFullscreenDisplayMode)(uint32_t, int, int,
                                                       float, bool,
                                                       AME_DisplayMode *);

static ame_fn_GetCurrentDisplayMode ame_real_GetCurrentDisplayMode = NULL;
static ame_fn_GetDesktopDisplayMode ame_real_GetDesktopDisplayMode = NULL;
static ame_fn_GetClosestFullscreenDisplayMode
    ame_real_GetClosestFullscreenDisplayMode = NULL;

static AME_DisplayMode ame_modeCurrent;
static AME_DisplayMode ame_modeDesktop;
static int ame_modeLogBudget = 6;

static void ame_modeToPixels(AME_DisplayMode *dst, const AME_DisplayMode *src) {
    if (dst == NULL || src == NULL) return;
    *dst = *src;
    int pw = 0, ph = 0;
    if (ame_eglSurfacePixelSize(&pw, &ph) ||
        ame_screenFallbackPixelSize(&pw, &ph)) {
        if (pw > 0 && ph > 0) {
            dst->w = pw;
            dst->h = ph;
        }
    }
    dst->pixel_density = 1.0f;
}

static const AME_DisplayMode *ame_SDL_GetCurrentDisplayMode(uint32_t id) {
    const AME_DisplayMode *m = ame_real_GetCurrentDisplayMode
                                   ? ame_real_GetCurrentDisplayMode(id)
                                   : NULL;
    if (m == NULL) return m;
    ame_modeToPixels(&ame_modeCurrent, m);
    if (ame_modeLogBudget > 0) {
        ame_modeLogBudget--;
        NSDebugLog(@"[SDLHook] GetCurrentDisplayMode -> %dx%d (points==pixels)",
                   ame_modeCurrent.w, ame_modeCurrent.h);
    }
    return &ame_modeCurrent;
}

static const AME_DisplayMode *ame_SDL_GetDesktopDisplayMode(uint32_t id) {
    const AME_DisplayMode *m = ame_real_GetDesktopDisplayMode
                                   ? ame_real_GetDesktopDisplayMode(id)
                                   : NULL;
    if (m == NULL) return m;
    ame_modeToPixels(&ame_modeDesktop, m);
    if (ame_modeLogBudget > 0) {
        ame_modeLogBudget--;
        NSDebugLog(@"[SDLHook] GetDesktopDisplayMode -> %dx%d (points==pixels)",
                   ame_modeDesktop.w, ame_modeDesktop.h);
    }
    return &ame_modeDesktop;
}

static bool ame_SDL_GetClosestFullscreenDisplayMode(uint32_t id, int w, int h,
                                                    float refresh_rate,
                                                    bool include_hd,
                                                    AME_DisplayMode *closest) {
    bool ok = ame_real_GetClosestFullscreenDisplayMode
                  ? ame_real_GetClosestFullscreenDisplayMode(
                        id, w, h, refresh_rate, include_hd, closest)
                  : false;
    if (!ok || closest == NULL) return ok;
    AME_DisplayMode fixed;
    ame_modeToPixels(&fixed, closest);
    *closest = fixed;
    if (ame_modeLogBudget > 0) {
        ame_modeLogBudget--;
        NSDebugLog(@"[SDLHook] GetClosestFullscreenDisplayMode -> %dx%d "
                   @"(points==pixels)",
                   closest->w, closest->h);
    }
    return true;
}

static bool ame_SDL_GL_GetDrawableSize(void *window, int *w, int *h) {
    int sw = 0, sh = 0;
    if (ame_eglSurfacePixelSize(&sw, &sh)) {
        if (w != NULL) *w = sw;
        if (h != NULL) *h = sh;
        AME_SIZE_LOG(@"[SDLHook] GL_GetDrawableSize -> %dx%d (EGL surface)",
                     sw, sh);
        return true;
    }
    // 先按主屏物理分辨率兜底：直接交回 SDL 原函数会拿到隐藏工具窗口的
    // 320x480（见 ame_screenFallbackPixelSize 处注释），MC 缓存后画面缩在角落。
    if (ame_screenFallbackPixelSize(&sw, &sh)) {
        if (w != NULL) *w = sw;
        if (h != NULL) *h = sh;
        return true;
    }
    if (ame_real_GL_GetDrawableSize != NULL) {
        return ame_real_GL_GetDrawableSize(window, w, h);
    }
    return false;
}

// —— 补发窗口尺寸事件（思路来自 FCL 93bba5a）——
//
// FCL 那个提交修的不是"算出正确尺寸"，而是"补发通知"：初始化时 SDL 原生侧
// 从未收到过 surface 就绪通知，故必须显式补发一次 surfaceChanged/nativeResize。
//
// 这里是同一问题的另一种形态：主窗口复用后，正确尺寸是在 SDL_GL_CreateContext
// 之后才由 ame_syncReusedWindowSize() 设上的，而 MC 可能在此之前已经查询并
// 缓存了旧值。指望 SDL_SetWindowSize 自动派发事件并不可靠 ——
// SDL_SendWindowEvent() 里有 `if (data1 == window->w && data2 == window->h)
// { ...; return 0; }`，尺寸与 SDL 内部记录一致时事件根本不会产生。
//
// 事件类型常量取自 SDL 3.4.0 include/SDL3/SDL_events.h：
//   SDL_EVENT_WINDOW_SHOWN   = 0x202（= SDL_EVENT_WINDOW_FIRST）
//   SDL_EVENT_WINDOW_HIDDEN  = 0x203
//   SDL_EVENT_WINDOW_EXPOSED = 0x204
//   SDL_EVENT_WINDOW_MOVED   = 0x205
//   SDL_EVENT_WINDOW_RESIZED = 0x206   ← 只用这一个
// 0x207 被 sdl2-compat 保留（原 SDL_EVENT_WINDOW_SIZE_CHANGED），
// PIXEL_SIZE_CHANGED 排在其后、版本间不保证稳定，故不硬编码它：
// 补 RESIZED 足以让 MC 重新查询，而查询 hook 已统一回报 EGL surface 尺寸。
#define AME_SDL_EVENT_WINDOW_RESIZED 0x206u
// Air Task 61（e8731fad40）定案：尺寸语义必须三路同值收敛到启动器像素口径。
// 除 RESIZED 外，uikit/SDL3 还会派发下面两类尺寸事件；Air 实测其会话内
// 「唯一的尺寸事件」携带的正是点尺寸，MC 26.3 按像素语义消费 -> 分辨率被压半。
// 三者一并改写成 EGL surface 像素，任何 SDL 版本/任何一条路径都不会漏。
#define AME_SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED 0x207u
#define AME_SDL_EVENT_WINDOW_METAL_VIEW_RESIZED 0x208u

typedef struct ame_SDL_WindowEvent {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    uint32_t windowID;
    int32_t data1;
    int32_t data2;
} ame_SDL_WindowEvent;

typedef union ame_SDL_Event {
    uint32_t type;
    ame_SDL_WindowEvent window;
    uint8_t padding[128];
} ame_SDL_Event;

typedef bool (*ame_fn_SDL_PushEvent)(void *event);
typedef uint32_t (*ame_fn_SDL_GetWindowID)(void *window);

// SDL_SendWindowEvent 属 SDL 内部函数（SDL_internal.h），不在公开 dynapi 表里，
// 但是否导出取决于构建配置，故运行时探测。它比 SDL_PushEvent 多做的那一步
// 正是我们缺的：函数内部会执行 `window->w = data1; window->h = data2;`，
// 并连锁触发 SDL_OnWindowResized / SDL_CheckWindowPixelSizeChanged，
// 使 SDL 内部状态与派发出去的事件保持一致。PushEvent 只入队，不修正状态。
typedef bool (*ame_fn_SDL_SendWindowEvent)(void *window, uint32_t event,
                                           int32_t data1, int32_t data2);

static ame_fn_SDL_PushEvent ame_real_PushEvent = NULL;
static ame_fn_SDL_GetWindowID ame_real_GetWindowID = NULL;

// data1/data2 传 EGL surface 的像素尺寸：查询 hook 回报的同样是像素，
// 两者一致 —— MC 无论直接取 data 还是重新查询，得到的都是同一个值。
static bool ame_pushWindowResized(void *window) {
    if (window == NULL) return false;
    if (ame_real_PushEvent == NULL) {
        ame_real_PushEvent =
            (ame_fn_SDL_PushEvent)ame_real_dlsym("SDL_PushEvent");
    }
    if (ame_real_PushEvent == NULL) return false;
    if (ame_real_GetWindowID == NULL) {
        ame_real_GetWindowID =
            (ame_fn_SDL_GetWindowID)ame_real_dlsym("SDL_GetWindowID");
    }

    int pw = 0, ph = 0;
    // Task 61 单一事实源：启动器像素口径（windowWidth/windowHeight = 物理像素
    // x resolutionScale）优先。ame_eglSurfacePixelSize() 走 EGL 查询 / UIKit
    // 缓存：EGL 查询在 MobileGlues 上恒失败（EGL 1.4 无 eglGetCurrentDisplay），
    // UIKit 缓存还会回报未被 resolutionScale 缩放的旧值 —— 判据一旦失真，
    // 本函数就永远拿不到正确尺寸，补发的事件也跟着错。
    if (!ame_launcherPixelSize(&pw, &ph)) {
        if (!ame_eglSurfacePixelSize(&pw, &ph)) return false;
    }

    uint32_t wid = (ame_real_GetWindowID != NULL)
                       ? ame_real_GetWindowID(window) : 0u;

    static int ame_sendWindowEventProbed = 0;
    static ame_fn_SDL_SendWindowEvent ame_real_SendWindowEvent = NULL;
    if (!ame_sendWindowEventProbed) {
        ame_sendWindowEventProbed = 1;
        ame_real_SendWindowEvent =
            (ame_fn_SDL_SendWindowEvent)ame_real_dlsym("SDL_SendWindowEvent");
        NSDebugLog(@"[SDLHook] SDL_SendWindowEvent %s",
                   ame_real_SendWindowEvent != NULL
                       ? "available"
                       : "not exported (fallback: PushEvent)");
    }
    if (ame_real_SendWindowEvent != NULL) {
        bool sent = ame_real_SendWindowEvent(
            window, AME_SDL_EVENT_WINDOW_RESIZED, (int32_t)pw, (int32_t)ph);
        NSDebugLog(@"[SDLHook] SendWindowEvent RESIZED %dx%d px "
                   @"(windowID=%u, %s)", pw, ph, wid,
                   sent ? "sent" : "rejected");
        if (sent) return true;
    }

    ame_SDL_Event ev;
    memset(&ev, 0, sizeof(ev));
    ev.window.type = AME_SDL_EVENT_WINDOW_RESIZED;
    ev.window.windowID = wid;
    ev.window.data1 = (int32_t)pw;
    ev.window.data2 = (int32_t)ph;

    bool pushed = ame_real_PushEvent(&ev);
    NSDebugLog(@"[SDLHook] posted WINDOW_RESIZED %dx%d px (windowID=%u, %s)",
               pw, ph, ev.window.windowID, pushed ? "pushed" : "rejected");
    return pushed;
}

// —— 自动补发尺寸事件：取代「手动改一次分辨率才恢复」——
//
// 三个尺寸查询（SDL_GetWindowSize / GetWindowSizeInPixels / GL_GetDrawableSize）
// 早已统一回报 EGL surface 像素，事件出口也已统一改写，但 MC 仍可能沿用启动
// 时缓存的旧值来建 framebuffer —— 那是 glViewport 改写不到的地方，于是画面
// 仍缩在角落。用户侧的 workaround 是「手动改一次分辨率」，其本质就是让 MC
// 收到一个新的 WINDOW_RESIZED 从而重新查询尺寸。
//
// 这里把这一步自动化：启动后若 GL_VIEWPORT 仍与 EGL surface 不符，就补发一条
// 携带正确像素尺寸的 WINDOW_RESIZED，让 MC 走与手动改分辨率完全相同的重建
// 路径。MC 一旦对了就立即停止，正常启动最多只多一次重建开销。
//
// —— 对齐 ZL2 的「就绪后立即同步」——
// ZL2 的 e9bd6dc9（fix: 修复 SDL 首帧分辨率同步）是在 SDL 初始化完成的回调里
// 立刻调 surfaceChanged() + nativeResize(w, h)，抢在首帧之前把尺寸同步完，而不是
// 等若干帧后再补救。此举值得照搬：首帧就已经画错的画面，事后矫正必然留下闪烁，
// 且期间玩家看到的就是小窗。
// 原实现要等到第 10 帧才开始检查，且此后每 15 帧才看一次 —— 在 60fps 下意味着
// 最坏要 0.25 秒才纠正。现改为：从第 2 帧起逐帧检查，命中即补发，最多 4 次；
// 一旦发现已正确立即永久停用（正常启动几乎零开销，因为 MC 自己设对了）。
// 保留起始帧判定（跳过第 1 帧）：此刻 MC 的渲染管线尚未跑完首轮，viewport 可能
// 还是上下文默认值，据此补发会产生一次无谓的窗口重建。
static int ame_resizeNudgeBudget = 12;
static int ame_swapFrames = 0;
typedef void (*ame_fn_glGetIntegerv)(uint32_t pname, int32_t *params);
static ame_fn_glGetIntegerv ame_nudge_glGetIntegerv = NULL;

// 实现在文件后部（viewport/scissor 包装节，依赖 ame_rendererHandle 等后部符号）。
// C 要求静态函数先用后定义时必须前置声明。
static int32_t ame_currentFramebufferBinding(void);

static void ame_maybeNudgeWindowResize(void) {
    // Air Task 50：1x 点数对齐生效期间，surface==drawable==MC viewport 已是
    // 单一事实源（MC 以「点」渲染，surface 就是点尺寸）。本 nudge 以物理像素
    // 为判据，与之直接冲突——它会持续把 MC 的 viewport 往 2436x1125 推，而
    // 1x 对齐要求保持 812x375，二者每帧拉锯。Air 没有此机制，对齐期间停用。
    // Air Task 60（664f58a3）定案：1x 点数对齐（Task 50）已退役，
    // Amethyst_SDL3SurfaceWantsPoints() 恒为 NO —— 本守卫随之成为死代码，
    // 与 Air 的 sdl3_hook 对齐后一并移除（Air 侧无此调用点）。
    if (ame_resizeNudgeBudget <= 0) return;
    ame_swapFrames++;
    // 第 1 帧放行（管线首轮未完成），此后逐帧检查。
    if (ame_swapFrames < 2) return;

    int pw = 0, ph = 0;
    // 同 ame_pushWindowResized：判据取启动器像素口径。EGL 查询在
    // MobileGlues 上恒失败，若以此为准，本 nudge 会永远认为"尺寸已正确"
    // 而从不补发 —— 于是 MC 的 viewport 长期停在 SDL 自报的未缩放尺寸，
    // 与已缩放的 drawable/EGL surface 不符：100% 时两者恰好相等看不出
    // 问题，25/50/75% 时渲染内容只有左下角落进呈现缓冲（"全屏只显示
    // 左下角"），且只能靠手动改一次分辨率触发重建才恢复。
    if (!ame_launcherPixelSize(&pw, &ph)) {
        if (!ame_eglSurfacePixelSize(&pw, &ph)) return;
    }
    if (pw <= 0 || ph <= 0) return;

    if (ame_nudge_glGetIntegerv == NULL) {
        void *rh = ame_rendererHandle();
        if (rh == NULL) return;
        void *fp = dlsym(rh, "glGetIntegerv");
        if (fp == NULL || !ame_glSymbolTrusted((const void *)fp)) return;
        ame_nudge_glGetIntegerv = (ame_fn_glGetIntegerv)fp;
    }

    int32_t vp[4] = {0, 0, 0, 0};
    ame_nudge_glGetIntegerv(0x0BA2, vp);  // GL_VIEWPORT
    if (vp[2] == (int32_t)pw && vp[3] == (int32_t)ph) {
        ame_resizeNudgeBudget = 0;  // 已经正确，无需再补发
        return;
    }

    // 绑定 FBO 时 viewport 与 surface 不等是正常的（离屏渲染），不能据此补发尺寸
    // 事件 —— 否则会把一次合法的离屏渲染误判成「尺寸没同步」，触发无谓的窗口重建。
    if (ame_currentFramebufferBinding() != 0) return;

    ame_resizeNudgeBudget--;
    NSDebugLog(@"[SDLHook] auto resize nudge: viewport %dx%d -> %dx%d (launcher px)",
               vp[2], vp[3], pw, ph);
    ame_pushWindowResized(ame_primaryWindow);
}

#pragma mark - 窗口尺寸事件出口统一（小窗根本修复）

// —— 为什么必须接管事件出口 ——
//
// 此前所有补丁都打在「查询」上：SDL_GetWindowSize / GetWindowSizeInPixels /
// GL_GetDrawableSize 早已接管，回报 EGL surface 的真实像素。但 MC 依然设出了
// 812x375 的 viewport —— 日志里 ame_viewportIsBad 命中「SDL window points used
// as pixels」，而该判定比对的正是 SDL 真实查询返回的 812x375。
//
// 这说明 MC 那一帧用的值不是查来的，而是**事件给的**：SDL 内部窗口状态停在
// 812x375（uikit 后端把传入值当 points、再 clamp 到屏幕），布局变化时它自行
// 派发 WINDOW_RESIZED，data1/data2 就是 812x375。该事件由 SDL 内部直接入队，
// 不走公开入口，我们补发的那一条 2436x1125 无法取代它 —— 补发只是多了一条，
// 坏的那条照样会被 MC 消费。这也解释了「必须手动改一次分辨率才恢复」：
// 手动改才会让 SDL 发出一个尺寸不同的事件。
//
// ZL2/FCL 没有这个问题，是因为它们的后端（Android）window 尺寸与像素恒等，
// SDL 内部状态本身就是对的，派发的事件自然也是对的。我们在 iOS 上无法把内部
// 状态变成像素，唯一等价的做法是**统一出口**：查询已统一，事件也统一。
//
// 于是 hook SDL_PollEvent，在事件交给 MC 之前把窗口尺寸改写为 EGL surface 像素。
// MC 无论直接取 data1/data2、还是收到后重新查询，拿到的都是同一个值 ——
// 这正是 ZL2 那种「内部自洽」在外部可见行为上的等价物。
//
// 只改 WINDOW_RESIZED(0x206)：PIXEL_SIZE_CHANGED 的类型号版本间不保证稳定，
// 且 MC 收到它会触发重新查询，而查询已统一，无需改写。
typedef bool (*ame_fn_SDL_PollEvent)(void *event);
typedef bool (*ame_fn_SDL_WaitEventTimeout)(void *event, int32_t timeoutMS);
// SDL3 另有这两个取事件入口。漏掉它们，SDL 内部派发的 WINDOW_RESIZED 就会
// 绕过改写、原样带着 points(812x375) 交给 MC。
typedef int (*ame_fn_SDL_PeepEvents)(void *events, int numevents, int action,
                                     uint32_t minType, uint32_t maxType);
typedef bool (*ame_fn_SDL_WaitEventTimeoutNS)(void *event, int64_t timeoutNS);
// Task 50 移植：窗口 flags 查询（用于剥离 MINIMIZED 位）
typedef unsigned int (*ame_fn_SDL_GetWindowFlags)(void *window);
// Air Task 32 移植：SDL_ShowWindow（黑屏根治的触发点）
typedef bool (*ame_fn_SDL_ShowWindow)(void *window);

static ame_fn_SDL_PollEvent ame_real_PollEvent = NULL;
static ame_fn_SDL_PollEvent ame_real_WaitEvent = NULL;
static ame_fn_SDL_WaitEventTimeout ame_real_WaitEventTimeout = NULL;
static ame_fn_SDL_PeepEvents ame_real_PeepEvents = NULL;
static ame_fn_SDL_WaitEventTimeoutNS ame_real_WaitEventTimeoutNS = NULL;
static ame_fn_SDL_GetWindowFlags ame_real_GetWindowFlags = NULL;
static ame_fn_SDL_ShowWindow ame_real_ShowWindow = NULL;
static int ame_eventRewriteLogBudget = 8;

static void ame_rewriteWindowSizeEvent(void *event) {
    if (event == NULL) return;
    ame_SDL_Event *ev = (ame_SDL_Event *)event;
    // Task 61：RESIZED / PIXEL_SIZE_CHANGED / METAL_VIEW_RESIZED 都携带窗口
    // 尺寸（点），全部改写为 EGL surface 像素口径。
    if (ev->window.type != AME_SDL_EVENT_WINDOW_RESIZED &&
        ev->window.type != AME_SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED &&
        ev->window.type != AME_SDL_EVENT_WINDOW_METAL_VIEW_RESIZED) return;

    // 先判类型再查尺寸：PollEvent 每帧多次调用，非窗口事件零开销。
    int pw = 0, ph = 0;
    if (!ame_launcherPixelSize(&pw, &ph)) {
        if (!ame_eglSurfacePixelSize(&pw, &ph)) return;
    }
    if (pw <= 0 || ph <= 0) return;
    if (ev->window.data1 == (int32_t)pw && ev->window.data2 == (int32_t)ph) return;

    if (ame_eventRewriteLogBudget > 0) {
        ame_eventRewriteLogBudget--;
        NSDebugLog(@"[SDLHook] WINDOW_RESIZED event %dx%d -> %dx%d px (launcher px)",
                   ev->window.data1, ev->window.data2, pw, ph);
    }
    ev->window.data1 = (int32_t)pw;
    ev->window.data2 = (int32_t)ph;
}

#pragma mark - Task 50/56 移植：minimized 谎言（黑屏根治）

// 参考仓库（Air）经 client.jar 反编译定案的黑屏主因之一：
//   MC 26.3 经 LWJGL 3.4.1（SDL 3.4.x 枚举）把 SDL_EVENT_WINDOW_MINIMIZED(0x209)
//   交给 Window.handleEvent → onIconified(true) → Minecraft.createSurface 传给
//   renderpearl 的 BooleanSupplier 就是 window::isIconified →
//   GlSurface.acquireNextTexture 见 iconified 即抛 SurfaceException
//   ("Cannot acquire minimized window")，并置 surfaceIsInvalid=true +
//   windowSurfaceNeedsReconfiguring=true。随后 configure() 在同一 CAMetalLayer
//   上二次建 EGL window surface 必败（EGL_BAD_ALLOC）→ 表面永久失效 → 黑屏。
//
// 本启动器真正的呈现面是宿主 GameSurfaceView 的 CAMetalLayer；SDL 窗口在 embed
//   后必然被隐藏（日志：RenderPearl OpenGL Hidden Utility Window），只是个"事件
//   壳"——它的"最小化"纯属谎言：画面根本不在那个窗口里，呈现面始终有效。
//
// 两处拦截：
//   1) 事件出口掐断 0x209（源头，MC 永不进入 iconified）；
//   2) SDL_GetWindowFlags 剥离 SDL_WINDOW_MINIMIZED(0x40)（查询路径兜底）。
// MAXIMIZED(0x20a)/RESTORED(0x20b) 一律放行：它们调 onIconified(false)，
// 是纵深防御，掐掉反而有害。
#define AME_SDL_EVENT_WINDOW_MINIMIZED 0x209u
#define AME_SDL_WINDOW_MINIMIZED       0x40u

static bool ame_eventIsWindowMinimized(const void *event) {
    if (event == NULL) return false;
    return *(const uint32_t *)event == AME_SDL_EVENT_WINDOW_MINIMIZED;
}

static void ame_noteDroppedMinimized(void) {
    static _Atomic unsigned long s_minDropCount = 0;
    unsigned long dn = atomic_fetch_add(&s_minDropCount, 1) + 1;
    if (dn <= 10 || dn % 50 == 0) {
        NSDebugLog(@"[SDLHook] Task56 drop SDL_EVENT_WINDOW_MINIMIZED #%lu "
                   @"(iconified 源头掐断：宿主 CAMetalLayer 仍可呈现)", dn);
    }
}

/// 对 MC 撒一个无害的谎：窗口永不 minimized。
/// 真正的后台切换由 SDL_APP_WILL_ENTER_BACKGROUND 等事件表达，语义完整。
static unsigned int ame_SDL_GetWindowFlags(void *window) {
    unsigned int f = ame_real_GetWindowFlags ? ame_real_GetWindowFlags(window) : 0;
    // Amethyst Task 110（对齐 Air Gsjsjz）：
    // 0x200 = SDL_WINDOW_INPUT_FOCUS 置 1；0x40 = MINIMIZED、0x4 = HIDDEN 剥离。
    // 根因：dynamic_fps 3.11.10（26.3 整合包自带）的 WindowObserver 构造函数直接查
    // SDL_GetWindowFlags & SDL_WINDOW_INPUT_FOCUS，不走 vanilla 的 Window.focused。
    // 我们的嵌入模式里隐藏的 SDL UIWindow 既无输入焦点（0x200=0）、也无鼠标焦点、
    // 还被标记 HIDDEN，于是模组判定窗口未聚焦进入限帧档（观测到的 30fps）。
    // Task 50 只剥离了 MINIMIZED，焦点位是漏网之鱼。
    // 安全性：vanilla 唯一的 flag 消费点是 Window.isFullscreen（& 1 FULLSCREEN），
    // 不受影响；renderpearl 依赖的 MINIMIZED 剥离保留。iOS 在后台会冻结 App，
    // 所以"前台恒有焦点"这个无害的谎言始终成立。
    return (f | 0x200u) & ~AME_SDL_WINDOW_MINIMIZED & ~0x4u;
}

/// Air Task 32 移植：嵌入后绝不让 SDL 自己的 UIWindow 保持可见。
///
/// 原生 SDL3 的 UIKit_ShowWindow 会直接 makeKeyAndVisible —— 那个空窗口是
/// 一个独立 UIWindow，浮在整个宿主窗口之上，整块盖住 GameSurfaceView = 黑屏
/// （Air 原话：“空窗黑盖子”）。它每次真实建窗都会重演，所以必须在这里拦截。
///
/// 仍然调用真实函数（补上 SDL 内部状态：鼠标焦点等），随后立即中和覆盖。
/// 原生实现是在调用线程 makeKeyAndVisible，而调用方是 JVM 渲染线程；iOS 16+
/// 离主线程调 UIKit 会被线程保护命中，故整体放到主线程同步执行。
static bool ame_SDL_ShowWindow(void *window) {
    if (ame_real_ShowWindow == NULL) {
        ame_real_ShowWindow = (ame_fn_SDL_ShowWindow)ame_real_dlsym("SDL_ShowWindow");
    }
    if (ame_real_ShowWindow == NULL) return false;

    __block bool r = false;
    void (^showAndEnforce)(void) = ^{
        r = ame_real_ShowWindow(window);
        Amethyst_EnforceSDL3Presentation();
    };
    if ([NSThread isMainThread]) {
        showAndEnforce();
    } else {
        dispatch_sync(dispatch_get_main_queue(), showAndEnforce);
    }
    NSDebugLog(@"[SDLHook] SDL_ShowWindow(%p) -> %d (embedded path: SDL UIWindow "
               @"re-hidden, presentation invariants enforced)", window, (int)r);
    return r;
}

#pragma mark - Air Task 32/51/67 移植：窗口生命周期钩子（尺寸钳制 + 取证）

// Air Task51 Fix E：Pojav/Java 侧以"像素"语义调 SDL_SetWindowSize（如 2436x1125），
// 而 SDL3-on-iOS 是"点"语义（iPhone X 横屏 812x375 点）。超屏的 SDL 窗口会把
// 嵌入的 SDL_uikitview 拉成像素量级并带负偏移，ANGLE 表面随之被锁死成错误尺寸，
// present 纹理与 drawable 失配 —— 表现为黑屏 / 画面缩在角落 / 必须手动改一次
// 分辨率才恢复。钳制规则：宽或高超过屏幕点数则折半（像素→点），仍超则硬钳屏幕点数。
static CGSize ame51_display_pts(void) {
    static CGSize pts = {0, 0};
    if (pts.width <= 0 || pts.height <= 0) {
        CGFloat w = 0, h = 0;
        @try {
            CGRect b = [UIScreen mainScreen].bounds;   // 线程安全属性
            w = b.size.width; h = b.size.height;
        } @catch (NSException *e) {
            NSLog(@"[SDLHook] Task51 mainScreen bounds exception: %@", e);
        }
        if (w <= 0 || h <= 0) {            // 异常兜底
            w = 1180; h = 820;
        }
        // UIScreen 返回竖屏口径时翻成横屏口径（Info.plist 已锁横屏）
        if (w < h) { CGFloat t = w; w = h; h = t; }
        pts = CGSizeMake(w, h);
        NSLog(@"[SDLHook] Task51 display pts cached: %.0fx%.0f", pts.width, pts.height);
    }
    return pts;
}

static bool ame_SDL_SetWindowSize(void *window, int w, int h) {
    int cw = w, ch = h;
    if (w > 0 && h > 0) {
        CGSize pts = ame51_display_pts();
        int maxW = (int)pts.width, maxH = (int)pts.height;
        if (maxW > 0 && maxH > 0 && (w > maxW || h > maxH)) {
            cw = (w > maxW) ? (w / 2) : w;   // 像素语义折半 = 点语义
            ch = (h > maxH) ? (h / 2) : h;
            if (cw > maxW) cw = maxW;
            if (ch > maxH) ch = maxH;
            NSLog(@"[SDLHook] Task51 SetWindowSize pixel->point clamp: %dx%d -> %dx%d (display %dx%d pts)",
                  w, h, cw, ch, maxW, maxH);
        }
    }
    if (ame_real_SetWindowSize == NULL) {
        ame_real_SetWindowSize =
            (ame_fn_SDL_SetWindowSize)ame_real_dlsym("SDL_SetWindowSize");
    }
    bool r = ame_real_SetWindowSize ? ame_real_SetWindowSize(window, cw, ch) : false;
    // 尺寸已变：SDL 内部 points 与缓存的 EGL surface 尺寸都可能过期
    ame_sdlPointCacheInvalidate();
    ame_surfCacheInvalidate();
    NSDebugLog(@"[SDLHook] SDL_SetWindowSize(%p, %d, %d) -> %d", window, cw, ch, (int)r);
    return r;
}

static bool ame_SDL_SetWindowPosition(void *window, int x, int y) {
    int cx = x, cy = y;
    if (x < 0 || y < 0) {
        // Air Task51：超屏窗口（像素语义）居中产生的负偏移会把嵌入的 SDL 视图
        // 坐标系拖离屏幕原点 → 触摸命中区域错位。钳回 (0,0)。
        if (cx < 0) cx = 0;
        if (cy < 0) cy = 0;
        NSLog(@"[SDLHook] Task51 SetWindowPosition clamp: %d,%d -> %d,%d", x, y, cx, cy);
    }
    bool r = ame_real_SetWindowPosition ? ame_real_SetWindowPosition(window, cx, cy) : false;
    NSDebugLog(@"[SDLHook] SDL_SetWindowPosition(%p, %d, %d) -> %d", window, cx, cy, (int)r);
    return r;
}

static bool ame_SDL_HideWindow(void *window) {
    bool r = ame_real_HideWindow ? ame_real_HideWindow(window) : false;
    NSDebugLog(@"[SDLHook] SDL_HideWindow(%p) -> %d", window, (int)r);
    return r;
}

static bool ame_SDL_SetWindowFullscreen(void *window, bool fullscreen) {
    bool r = ame_real_SetWindowFullscreen ? ame_real_SetWindowFullscreen(window, fullscreen) : false;
    NSDebugLog(@"[SDLHook] SDL_SetWindowFullscreen(%p, %d) -> %d", window, (int)fullscreen, (int)r);
    return r;
}

static const bool *ame_SDL_GetKeyboardState(int *numkeys) {
    const bool *r = ame_real_GetKeyboardState ? ame_real_GetKeyboardState(numkeys) : NULL;
    return r;
}

// Air Task 32：当 MC 通过 SDL_LoadFunction（而非 dlsym）解析符号时，同样把
// 窗口生命周期钩子装上（防御性双路覆盖）。
static void ame_maybeWrapWindowHook(const char *name, void **out) {
    if (name == NULL || out == NULL || *out == NULL) return;
    if (strcmp(name, "SDL_HideWindow") == 0) {
        if (ame_real_HideWindow == NULL)
            ame_real_HideWindow = (ame_fn_SDL_HideWindow)*out;
        *out = (void *)ame_SDL_HideWindow;
    } else if (strcmp(name, "SDL_SetWindowSize") == 0) {
        if (ame_real_SetWindowSize == NULL)
            ame_real_SetWindowSize = (ame_fn_SDL_SetWindowSize)*out;
        *out = (void *)ame_SDL_SetWindowSize;
    } else if (strcmp(name, "SDL_SetWindowPosition") == 0) {
        if (ame_real_SetWindowPosition == NULL)
            ame_real_SetWindowPosition = (ame_fn_SDL_SetWindowPosition)*out;
        *out = (void *)ame_SDL_SetWindowPosition;
    } else if (strcmp(name, "SDL_SetWindowFullscreen") == 0) {
        if (ame_real_SetWindowFullscreen == NULL)
            ame_real_SetWindowFullscreen = (ame_fn_SDL_SetWindowFullscreen)*out;
        *out = (void *)ame_SDL_SetWindowFullscreen;
    } else if (strcmp(name, "SDL_GetKeyboardState") == 0) {
        if (ame_real_GetKeyboardState == NULL)
            ame_real_GetKeyboardState = (ame_fn_SDL_GetKeyboardState)*out;
        *out = (void *)ame_SDL_GetKeyboardState;
    }
}

static bool ame_SDL_PollEvent(void *event) {
    if (ame_real_PollEvent == NULL) {
        ame_real_PollEvent =
            (ame_fn_SDL_PollEvent)ame_real_dlsym("SDL_PollEvent");
    }
    // Vulkan 路径的分辨率同步（幂等，命中一次后自锁）。
    ame_applyLauncherResolutionToSDLLayer();
    // Task 56：丢弃 MINIMIZED 后取下一条（单事件出口，循环即可）。
    for (;;) {
        bool got = (ame_real_PollEvent != NULL) ? ame_real_PollEvent(event) : false;
        if (!got) return false;
        if (ame_eventIsWindowMinimized(event)) {
            ame_noteDroppedMinimized();
            continue;
        }
        ame_rewriteWindowSizeEvent(event);
        return true;
    }
}

static bool ame_SDL_WaitEvent(void *event) {
    if (ame_real_WaitEvent == NULL) {
        ame_real_WaitEvent =
            (ame_fn_SDL_PollEvent)ame_real_dlsym("SDL_WaitEvent");
    }
    for (;;) {
        bool got = (ame_real_WaitEvent != NULL) ? ame_real_WaitEvent(event) : false;
        if (!got) return false;
        if (ame_eventIsWindowMinimized(event)) {
            ame_noteDroppedMinimized();
            continue;
        }
        ame_rewriteWindowSizeEvent(event);
        return true;
    }
}

static bool ame_SDL_WaitEventTimeout(void *event, int32_t timeoutMS) {
    if (ame_real_WaitEventTimeout == NULL) {
        ame_real_WaitEventTimeout =
            (ame_fn_SDL_WaitEventTimeout)ame_real_dlsym("SDL_WaitEventTimeout");
    }
    for (;;) {
        bool got = (ame_real_WaitEventTimeout != NULL)
                       ? ame_real_WaitEventTimeout(event, timeoutMS) : false;
        if (!got) return false;
        if (ame_eventIsWindowMinimized(event)) {
            ame_noteDroppedMinimized();
            continue;
        }
        ame_rewriteWindowSizeEvent(event);
        return true;
    }
}

static int ame_SDL_PeepEvents(void *events, int numevents, int action,
                              uint32_t minType, uint32_t maxType) {
    if (ame_real_PeepEvents == NULL) {
        ame_real_PeepEvents =
            (ame_fn_SDL_PeepEvents)ame_real_dlsym("SDL_PeepEvents");
    }
    int n = (ame_real_PeepEvents != NULL)
                ? ame_real_PeepEvents(events, numevents, action, minType, maxType)
                : 0;
    // 事件在 SDL3 里是定长 128 字节的联合体，按 128 步进即可遍历。
    // Task 56：MINIMIZED 事件就地剔除（保留其余事件的相对次序）。
    if (n > 0 && events != NULL && action != 0) {
        uint8_t *base = (uint8_t *)events;
        int keep = 0;
        for (int i = 0; i < n; i++) {
            uint8_t *e = base + (size_t)i * 128;
            if (ame_eventIsWindowMinimized(e)) {
                ame_noteDroppedMinimized();
                continue;
            }
            if (keep != i) memmove(base + (size_t)keep * 128, e, 128);
            ame_rewriteWindowSizeEvent(base + (size_t)keep * 128);
            keep++;
        }
        n = keep;
    }
    return n;
}

static bool ame_SDL_WaitEventTimeoutNS(void *event, int64_t timeoutNS) {
    if (ame_real_WaitEventTimeoutNS == NULL) {
        ame_real_WaitEventTimeoutNS =
            (ame_fn_SDL_WaitEventTimeoutNS)ame_real_dlsym("SDL_WaitEventTimeoutNS");
    }
    for (;;) {
        bool got = (ame_real_WaitEventTimeoutNS != NULL)
                       ? ame_real_WaitEventTimeoutNS(event, timeoutNS) : false;
        if (!got) return false;
        if (ame_eventIsWindowMinimized(event)) {
            ame_noteDroppedMinimized();
            continue;
        }
        ame_rewriteWindowSizeEvent(event);
        return true;
    }
}

#pragma mark - 事件窗口解析回落（对齐 ZL2）

// SDL 的鼠标焦点（mouse->focus）会被 SDL_UpdateMouseFocus 的坐标越界判定清除：
// 虚拟鼠标坐标经分辨率缩放后可超过 SDL window 尺寸。这一点对我们尤其致命 ——
// 我们把 SDL window 尺寸设成了物理像素（2436x1124），而输入桥上报的坐标是
// 按 points 换算来的，越界概率比 ZL2 更高，表现为鼠标/触摸时灵时不灵。
//
// iOS 同样只有一个窗口，故解析失败时回落到上次成功解析出的窗口（ZL2 的
// sdlLastEventWindow 等价物）。
static void *ame_sdlLastEventWindow = NULL;

static void *ame_SDL_GetWindowFromEvent(const void *event) {
    void *window = ame_real_GetWindowFromEvent != NULL
                       ? ame_real_GetWindowFromEvent(event)
                       : NULL;
    if (window != NULL) {
        ame_sdlLastEventWindow = window;
        return window;
    }
    if (ame_sdlLastEventWindow != NULL) {
        NSDebugLog(@"[SDLHook] GetWindowFromEvent: NULL -> fallback %p",
                   ame_sdlLastEventWindow);
        return ame_sdlLastEventWindow;
    }
    return NULL;
}

static void *ame_SDL_GetWindowFromID(uint32_t id) {
    void *window = ame_real_GetWindowFromID != NULL
                       ? ame_real_GetWindowFromID(id)
                       : NULL;
    if (window != NULL) {
        ame_sdlLastEventWindow = window;
        return window;
    }
    if (ame_sdlLastEventWindow != NULL) {
        NSDebugLog(@"[SDLHook] GetWindowFromID(%u): NULL -> fallback %p",
                   (unsigned)id, ame_sdlLastEventWindow);
        return ame_sdlLastEventWindow;
    }
    return NULL;
}

#pragma mark - 文本输入主线程化

// SDL 的 iOS 后端在 SDL_StartTextInputWithProperties 里直接操作 UIKit
// （-[SDL_uikitviewcontroller setTextFieldProperties:]）。MC 从渲染线程调用它，
// 于是出现：
//     "modifying the autolayout engine from a background thread"
// 异常虽被 SDL 侧 catch，但布局未能完成，软键盘行为不可预期。
//
// 修法：这类入口若不在主线程，就 dispatch 到主线程执行。文本输入是低频操作，
// 用 async 避免阻塞渲染线程（也避免主线程同步等待造成死锁）。
static bool ame_dispatchTextInputToMain(void (^work)(void)) {
    if (work == nil) return false;
    if ([NSThread isMainThread]) {
        work();
        return true;
    }
    dispatch_async(dispatch_get_main_queue(), work);
    return true;
}

static bool ame_SDL_StartTextInput(void *window) {
    return ame_dispatchTextInputToMain(^{
        if (ame_real_StartTextInput != NULL) ame_real_StartTextInput(window);
    });
}

static bool ame_SDL_StartTextInputWithProperties(void *window,
                                                 unsigned long long props) {
    return ame_dispatchTextInputToMain(^{
        if (ame_real_StartTextInputWithProperties != NULL) {
            ame_real_StartTextInputWithProperties(window, props);
        }
    });
}

static bool ame_SDL_StopTextInput(void *window) {
    return ame_dispatchTextInputToMain(^{
        if (ame_real_StopTextInput != NULL) ame_real_StopTextInput(window);
    });
}

static bool ame_SDL_SetTextInputArea(void *window, const void *rect, int cursor) {
    // rect 由调用方栈上持有，且 block 是异步执行的 —— 不能把局部变量的地址
    // 传进 block（函数返回后失效）。改堆分配，由 block 在使用后释放。
    ame_SDLRect *heapRect = NULL;
    if (rect != NULL) {
        heapRect = (ame_SDLRect *)malloc(sizeof(ame_SDLRect));
        if (heapRect != NULL) memcpy(heapRect, rect, sizeof(ame_SDLRect));
    }

    if ([NSThread isMainThread]) {
        bool r = ame_real_SetTextInputArea != NULL
                     ? ame_real_SetTextInputArea(window, heapRect, cursor)
                     : false;
        free(heapRect);
        return r;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (ame_real_SetTextInputArea != NULL) {
            ame_real_SetTextInputArea(window, heapRect, cursor);
        }
        free(heapRect);
    });
    return true;
}

#pragma mark - SDL hint（对齐 ZL2 的 SDL_InitSubSystem hook）

// hint 必须在 SDL_Init 之前设置才生效，因此挂在 InitSubSystem 上、在调用
// 原函数之前设置 —— 这与 ZL2 custom_SDL_InitSubSystem_Func 的做法一致。
//
//   SDL_RETURN_KEY_HIDES_IME       ZL2 注释：启动器的正常行为，SDL 默认 false
//   SDL_ENABLE_SCREEN_KEYBOARD=1   MC 按桌面惯例设成 0 以禁用平台软键盘（改用
//                                  自绘 IME UI），但移动端依赖 SDL 唤起输入法；
//                                  MC 在 SDL_Init 之前设值，此处覆盖回启用
//   SDL_OPENGL_FORCE_SRGB_FRAMEBUFFER=0
//                                  ZL2：MobileGlues 无法传入正确的 EGL 参数来
//                                  支持这个；对所有走 EGL bridge 的移动转译型
//                                  渲染器同样适用
static bool ame_SDL_InitSubSystem(uint32_t flags) {
    if (ame_real_SetHint == NULL) {
        ame_real_SetHint = (ame_fn_SDL_SetHint)ame_real_dlsym("SDL_SetHint");
    }
    if (ame_real_SetHint != NULL) {
        ame_real_SetHint("SDL_RETURN_KEY_HIDES_IME", "true");
        if (ame_glBridgeEnabled()) {
            ame_real_SetHint("SDL_OPENGL_FORCE_SRGB_FRAMEBUFFER", "0");
        }
        ame_real_SetHint("SDL_ENABLE_SCREEN_KEYBOARD", "1");
        NSDebugLog(@"[SDLHook] SDL hint set (screenKeyboard=1, srgb=%s)",
                   ame_glBridgeEnabled() ? "off" : "default");
    }
    if (ame_real_InitSubSystem != NULL) {
        return ame_real_InitSubSystem(flags);
    }
    return false;
}

//
// 主窗口复用后 MC 拿到的仍是 320x480 这个尺寸，会按它设置 viewport / GUI scale，
// 而 EGL surface 由 SurfaceViewController 的 layer 独立创建，两者对不上 → 黑屏。
//
// —— 窗口尺寸直接取 EGL surface 的像素尺寸，使三者回到同一坐标系 ——
// GLFW 路径一切正常的根源：glfwGetWindowSize() 与 glfwGetFramebufferSize()
// 返回同一个值（同取 internalGetWindow(window).width，即物理像素），于是
// GUI 布局、渲染区域、输入坐标共处同一坐标系。
//
// SDL3 路径此前把窗口设成视图 bounds（812x375 points，见日志
// "reused window resize 320x480 -> 812x375"），而查询 hook 回报的是 EGL
// surface（2436x1124）、输入桥又按物理像素上报（日志中 HotbarDiag 的
// x=2129 远超 812）—— 三个坐标系互相分裂。
//
// 这里改为直接采用 EGL surface 的像素尺寸。视图仍会被强制拉回全屏逻辑尺寸
// （见下方 sdlView.frame），故不影响显示铺满；渲染区域由 EGL surface 决定。
static void ame_syncReusedWindowSize(void *window, int w, int h, bool pushEvent) {
    if (window == NULL || w <= 0 || h <= 0) return;

    // 取启动器的 GameSurfaceView —— EGL surface 就绑在它的 layer 上
    UIView *gsv = nil;
    Class svc = NSClassFromString(@"SurfaceViewController");
    if (svc != nil && [svc respondsToSelector:NSSelectorFromString(@"surface")]) {
        id obj = [svc performSelector:NSSelectorFromString(@"surface")];
        if ([obj isKindOfClass:[UIView class]]) gsv = (UIView *)obj;
    }

    // 窗口尺寸 = 全屏逻辑尺寸(points)。真实的像素语义由
    // SDL_GetWindowSize / SDL_GetWindowSizeInPixels 的接管统一给出（= EGL surface）。
    // 窗口尺寸必须等于 EGL surface 的像素尺寸 —— 这正是 GLFW 路径一切正常的
    // 根源：window size 与 framebuffer size 恒等，于是 GUI 布局、渲染区域、
    // 输入坐标三者共处同一个坐标系。此前这里用的是视图 bounds（812x375 points），
    // 而查询 hook 回报的是 EGL surface（2436x1124）、输入桥又按物理像素上报，
    // 三个坐标系分裂 —— 同时表现为「画面缩在左上角」与「鼠标越界 REJECT」。
    //
    // 不可用全屏逻辑尺寸代替：分辨率 75% 时 EGL surface 只有 1827x843，
    // 若窗口仍按 2436x1124 布局，GUI 会超出可视区（即早前「25% 过大」的现象）。
    int targetW = w, targetH = h;
    int surfW = 0, surfH = 0;
    if (ame_eglSurfacePixelSize(&surfW, &surfH) && surfW > 0 && surfH > 0) {
        targetW = surfW;
        targetH = surfH;
    } else if (gsv != nil && gsv.bounds.size.width > 0.0 &&
               gsv.bounds.size.height > 0.0) {
        CGFloat sc = [UIScreen mainScreen].scale;
        if (sc <= 0.0) sc = 1.0;
        targetW = (int)round(gsv.bounds.size.width  * sc);
        targetH = (int)round(gsv.bounds.size.height * sc);
    }

    if (ame_real_SetWindowSize == NULL) {
        ame_real_SetWindowSize =
            (ame_fn_SDL_SetWindowSize)ame_real_dlsym("SDL_SetWindowSize");
    }
    bool ok = false;
    if (ame_real_SetWindowSize != NULL) {
        ok = ame_real_SetWindowSize(window, targetW, targetH);
    }
    // 窗口尺寸已变：SDL 内部的 points 与已缓存的 EGL surface 尺寸都可能过期，
    // 令其失效，下次查询重新取值（否则 75%/100% 切换后会沿用旧的 surface 尺寸）。
    ame_sdlPointCacheInvalidate();
    ame_surfCacheInvalidate();

    // SetWindowSize 之后 SDL 会按自身换算调整视图；这里把视图强制回全屏逻辑尺寸，
    // 使显示铺满屏幕（真正的渲染尺寸由 EGL surface 决定，与此处无关）。
    //
    // 注意：不要把 contentScaleFactor 强行归一为 1.0。窗口尺寸既已按 points 传入，
    // 归一只会让 SDL 内部的像素空间从 2436x1124 缩到 812x375，输入坐标（其空间为
    // EGL surface 的像素尺寸）更容易被判为越界，进而触发 SDL 清除 mouse->focus
    // —— 即 ZL2 注释里提到的「虚拟鼠标坐标超过 SDL window 尺寸」问题。
    UIView *sdlView = ame_findSDLView(gsv);
    if (sdlView != nil) ame_embeddedSDLView = sdlView;
    if (sdlView != nil) {
        if (gsv != nil && gsv.bounds.size.width > 0.0) {
            CGRect full = CGRectMake(0.0, 0.0,
                                     gsv.bounds.size.width,
                                     gsv.bounds.size.height);
            CGSize cur = sdlView.frame.size;
            if (fabs((double)cur.width  - (double)full.size.width)  > 0.5 ||
                fabs((double)cur.height - (double)full.size.height) > 0.5) {
                NSDebugLog(@"[SDLHook] SDL view frame %.0fx%.0f -> %.0fx%.0f "
                           @"(fullscreen points)",
                           cur.width, cur.height,
                           full.size.width, full.size.height);
                sdlView.frame = full;
                [sdlView setNeedsLayout];
            }
        }
    }

    NSDebugLog(@"[SDLHook] reused window resize %dx%d -> %dx%d px "
               @"(req px %dx%d) (%s)",
               ame_primaryWindowW, ame_primaryWindowH, targetW, targetH, w, h,
               ok ? "ok" : (ame_real_SetWindowSize ? "rejected"
                                                   : "no SDL_SetWindowSize"));
    ame_primaryWindowW = targetW;
    ame_primaryWindowH = targetH;

    // 补发一次尺寸事件：MC 可能已在本函数之前查询并缓存了旧值（隐藏工具窗口
    // 的 320x480），而 SDL_SetWindowSize 在尺寸未变时不产生事件。显式补发
    // 确保 MC 一定会重新查询，从而拿到 EGL surface 的真实尺寸。
    //
    // 首次建窗（隐藏工具窗口）时 MC 的事件循环尚未就绪，此时 PushEvent 无意义
    // 且不安全，由调用方传入 false 跳过 —— 首次建窗本就把尺寸设成了正确值，
    // MC 从第一次查询起拿到的就是全屏尺寸，无需再靠事件纠正。
    if (pushEvent) ame_pushWindowResized(window);
}

#pragma mark - 3) EGL 兼容重试

// RENDERABLE_TYPE 归一化为 ES2_BIT：宿主若不支持请求的 ES3/桌面 GL 位，
// 退回 ES2 至少能拿到一个可用 config。
static int ame_normalizeEglChooseConfigList(const int *attrib_list, int *fixed, int cap) {
    if (attrib_list == NULL) return 0;
    int n = 0;
    for (int i = 0; n < cap - 2; i += 2) {
        int attr = attrib_list[i];
        int val = attrib_list[i + 1];
        if (attr == AME_EGL_NONE) {
            fixed[n] = AME_EGL_NONE;
            fixed[n + 1] = 0;
            n += 2;
            break;
        }
        if (attr == AME_EGL_RENDERABLE_TYPE) {
            if ((val & (AME_EGL_OPENGL_ES3_BIT | AME_EGL_OPENGL_BIT)) != 0 &&
                (val & AME_EGL_OPENGL_ES2_BIT) == 0) {
                val = (val & ~(AME_EGL_OPENGL_ES3_BIT | AME_EGL_OPENGL_BIT)) |
                      AME_EGL_OPENGL_ES2_BIT;
            }
        }
        fixed[n] = attr;
        fixed[n + 1] = val;
        n += 2;
    }
    return n > 0;
}

// 剔除宿主不识别的 KHR 版本属性，生成兼容重试表；返回请求的主版本号（无则 0）
static int ame_normalizeEglContextAttribs(const int *attrib_list, int *fixed, int cap,
                                          bool esSemantics) {
    int version = 0;
    bool hasClientVersion = false;
    if (attrib_list == NULL) return 0;
    int n = 0;
    for (int i = 0; n < cap - 2; i += 2) {
        int attr = attrib_list[i];
        int val = attrib_list[i + 1];
        if (attr == AME_EGL_NONE) break;
        if (attr == AME_EGL_CONTEXT_MAJOR_VERSION_KHR) {  // 记录主版本后剔除
            if (version == 0) version = val;
            continue;
        }
        if (attr == AME_EGL_CONTEXT_MINOR_VERSION_KHR) continue;
        if (attr == AME_EGL_CONTEXT_CLIENT_VERSION) {
            hasClientVersion = true;
            if (version == 0) version = val;
        }
        if (n >= cap - 2) return 0;
        fixed[n++] = attr;
        fixed[n++] = val;
    }
    // 仅 ES 语义下补写 CLIENT_VERSION（避免退化成驱动默认版本）；
    // desktop 语义不补写 —— 桌面 context 不使用 CLIENT_VERSION
    if (esSemantics && version > 0 && !hasClientVersion) {
        if (n >= cap - 2) return 0;
        fixed[n++] = AME_EGL_CONTEXT_CLIENT_VERSION;
        fixed[n++] = version;
    }
    if (n >= cap - 2) return 0;
    fixed[n++] = AME_EGL_NONE;
    fixed[n++] = 0;
    return version;
}

static void *ame_proxyEglCreateContext(void *dpy, void *config, void *share,
                                       const int *attrib_list) {
    if (ame_orig_eglCreateContext == NULL) {
        NSDebugLog(@"[SDLHook] eglCreateContext was not resolved");
        return NULL;
    }

    void *ctx = ame_orig_eglCreateContext(dpy, config, share, attrib_list);
    if (ctx != NULL || !ame_sdlGlesCompatEnabled()) return ctx;

    bool esSemantics = ame_forcedEsProfile;
    int fixed[64];
    int version = ame_normalizeEglContextAttribs(attrib_list, fixed, 64, esSemantics);
    if (version == 0) return ctx;

    NSDebugLog(@"[SDLHook] retrying eglCreateContext without KHR version attrs (CV=%d)", version);
    ctx = ame_orig_eglCreateContext(dpy, config, share, fixed);
    if (ctx != NULL || !esSemantics || version <= 2) return ctx;  // CV=2 为移动端最后兜底

    NSDebugLog(@"[SDLHook] retrying eglCreateContext with CV=2 after CV=%d failed", version);
    int es2[3] = {AME_EGL_CONTEXT_CLIENT_VERSION, 2, AME_EGL_NONE};
    return ame_orig_eglCreateContext(dpy, config, share, es2);
}

static int ame_proxyEglChooseConfig(void *dpy, const int *attrib_list, void **configs,
                                    int config_size, int *num_config) {
    if (ame_orig_eglChooseConfig == NULL) {
        NSDebugLog(@"[SDLHook] eglChooseConfig was not resolved");
        return 0;
    }

    int result = ame_orig_eglChooseConfig(dpy, attrib_list, configs, config_size, num_config);
    if (result && num_config != NULL && *num_config > 0) return result;
    if (!ame_sdlGlesCompatEnabled()) return result;  // 兼容 fallback 仅限移动 ES 渲染器

    int fixed[64];
    if (!ame_normalizeEglChooseConfigList(attrib_list, fixed, 64)) return result;
    int fallbackCount = 0;
    int fallbackResult = ame_orig_eglChooseConfig(dpy, fixed, configs, config_size, &fallbackCount);
    if (fallbackResult && num_config != NULL) *num_config = fallbackCount;
    NSDebugLog(@"[SDLHook] eglChooseConfig fallback result=%d count=%d",
               fallbackResult, fallbackCount);
    return fallbackResult;
}

static int ame_proxyEglSwapBuffers(void *dpy, void *surface) {
    if (ame_orig_eglSwapBuffers == NULL) {
        NSDebugLog(@"[SDLHook] eglSwapBuffers was not resolved");
        return 0;
    }
    return ame_orig_eglSwapBuffers(dpy, surface);
}

// —— glViewport 兜底：类型与实现分离 ——
//
// 类型、真实指针、日志预算声明在此，实现（ame_glViewport）留在文件后部：
// 它依赖 ame_primaryWindow / ame_real_GetWindowSizeInPixels 等后部符号，
// 直接前移会引入大量重复声明。C 允许先声明后定义，故用前向声明桥接，
// 让 ame_maybeWrapGl 能在文件前部就把包装挂上 GL 函数指针。
// ame_rendererHandle 定义在文件更靠后处（渲染器句柄解析），这里需要用，
// 故先声明。C 要求静态函数先用后定义时必须前置声明，否则编译报错。
static void *ame_rendererHandle(void);

typedef void (*ame_fn_glViewport)(int32_t x, int32_t y,
                                  int32_t width, int32_t height);

static ame_fn_glViewport ame_real_glViewport = NULL;
static int ame_glViewportLogBudget = 24;
static void ame_glViewport(int32_t x, int32_t y, int32_t width, int32_t height);

// 渲染器构造期结束后，显式句柄查询也必须接管。
// LWJGL 在 opengl.libname 指向渲染器时，直接用 dlsym(渲染器句柄, "glViewport")
// 取 GL 入口，绕开了 RTLD_DEFAULT 与 SDL_GL_GetProcAddress 这两条已挂钩的路。
// 表现是日志里只有 swap 处守护纠正后的调用、看不到 MC 自己的 glViewport：
// MC 每帧把 viewport 设成 points(812x375)，而 swap 的纠正发生在绘制之后，
// 下一帧又被覆盖 —— 这正是「守护一直报 corrected，画面仍缩在左上角」的原因。
// 构造期（dlopen 期间 dyld 持锁）绝不介入，故用开关控制；开关在 GL 上下文
// 创建时打开，此时渲染器 constructor 早已跑完，dladdr 不再有死锁风险。
static bool ame_glWrapExplicitHandle = false;
// 本模块内部解析真实 GL 入口时的旁路计数：避免把包装版本当成真实实现缓存，
// 造成 wrapper -> wrapper 的无限递归。
static int ame_dlsymBypassDepth = 0;

// glScissor 必须与 glViewport 同步修正：两者是彼此独立的 GL 状态。
// 仅修正 viewport 而放任 GL_SCISSOR_BOX 停在 points(812x375)，绘制会被裁剪到
// 一个远小于 surface 的矩形里 —— 表现为「画面缩在左上角」，且无论 viewport
// 改得多么正确都不见效。这与日志中「viewport 已 corrected，画面仍在左上角」
// 的现象完全吻合。
typedef void (*ame_fn_glScissor)(int32_t x, int32_t y,
                                 int32_t width, int32_t height);

static ame_fn_glScissor ame_real_glScissor = NULL;
static int ame_glScissorLogBudget = 8;
static void ame_glScissor(int32_t x, int32_t y, int32_t width, int32_t height);

// 判断某个 viewport 是否为「已知的错误候选」。只做精确匹配，不做比例推断，
// 以免误伤渲染到 FBO 时的合法小 viewport（阴影贴图、GUI 元素、缩略图等）。
//
// 注意：调用方（ame_glViewport / ame_glScissor / ame_fixStaleScissor）已各自在
// 调用前判定过「当前绑定的是默认 framebuffer」，故此处不再重复查询 fb —— 那会
// 给每帧路径多加一次 GL 状态查询。此函数的职责严格限定为「候选值匹配」。
static bool ame_viewportIsBad(int32_t width, int32_t height,
                              int eglW, int eglH, const char **why) {
    *why = NULL;
    if (eglW <= 0 || eglH <= 0 || width <= 0 || height <= 0) return false;
    if (width == eglW && height == eglH) return false;

    // 候选一：建窗阶段缓存的隐藏工具窗口尺寸
    if ((width == 320 && height == 480) || (width == 480 && height == 320)) {
        *why = "hidden utility window size";
        return true;
    }
    // 候选二：MC 把 SDL 内部的 points 当成了像素。
    // points 在建窗后即固定，缓存一次足够，免得在每帧路径上反复调用 SDL。
    // 窗口尺寸变更时由 ame_sdlPointCacheInvalidate 置零重取。
    if (ame_sdlPointW <= 0 || ame_sdlPointH <= 0) {
        int pw = 0, ph = 0;
        if (ame_primaryWindow != NULL && ame_real_GetWindowSize != NULL &&
            ame_real_GetWindowSize(ame_primaryWindow, &pw, &ph) &&
            pw > 0 && ph > 0) {
            ame_sdlPointW = pw;
            ame_sdlPointH = ph;
        }
    }
    if (ame_sdlPointW > 0 && ame_sdlPointH > 0 &&
        width == ame_sdlPointW && height == ame_sdlPointH) {
        *why = "SDL window points used as pixels";
        return true;
    }
    // 候选三：SDL 自己换算的像素尺寸（points x UIScreen.scale）。
    // SDL 不知道启动器的 resolutionScale，故只有 100% 时才与 surface 相等。
    int pxW = 0, pxH = 0;
    if (ame_primaryWindow != NULL && ame_real_GetWindowSizeInPixels != NULL &&
        ame_real_GetWindowSizeInPixels(ame_primaryWindow, &pxW, &pxH) &&
        pxW > 0 && pxH > 0 && width == pxW && height == pxH) {
        *why = "SDL pixel size (ignores resolutionScale)";
        return true;
    }
    return false;
}

// 主动解析真实 glViewport。MC 可能从未走过我们的包装路径（见 swap 处注释），
// 那时 ame_real_glViewport 仍是 NULL，需自行 dlsym。
// 渲染器以 RTLD_LOCAL 加载，故 dlsym(RTLD_DEFAULT) 可能取不到，
// 必须优先从渲染器句柄取。
// —— 校验 GL 入口点确实来自渲染器本身 ——
// 渲染器以 RTLD_LOCAL 载入，dlsym(RTLD_DEFAULT) 取不到它，退而拿到的便是
// 系统 OpenGLES.framework 的桩实现（诊断日志已坐实：
//   dlsym(RTLD_DEFAULT,"glGetString")
//     -> /System/Library/Frameworks/OpenGLES.framework/OpenGLES
//   glGetString(GL_VERSION)=(NULL)   glGetIntegerv(GL_MAJOR_VERSION)=-1 ）。
// 那份实现与我们的 EGL/ANGLE 上下文毫无关系：它既没有 current context，
// 其 glViewport 也不会作用于我们的 framebuffer。后果是双重的 ——
//   1) 拿它去纠正 viewport 完全无效，画面依旧缩在角落（小窗不消失的真正原因）；
//   2) 在渲染线程执行与上下文不匹配的实现，是闪退的直接来源。
// 因此凡是要真正执行的 GL 入口点，都用 dladdr 验明镜像，拒绝系统框架的桩。
static bool ame_glSymbolTrusted(const void *sym) {
    if (sym == NULL) return false;
    Dl_info info;
    if (dladdr(sym, &info) == 0 || info.dli_fname == NULL) return false;
    const char *img = info.dli_fname;
    return (strstr(img, "OpenGLES.framework") == NULL &&
            strstr(img, "OpenGL.framework") == NULL);
}

static ame_fn_glViewport ame_resolve_glViewport(void) {
    // 若已缓存的是系统桩（例如被 dlsym 路径的 RTLD_DEFAULT 回退污染），丢弃重解析。
    if (ame_real_glViewport != NULL &&
        ame_glSymbolTrusted((const void *)ame_real_glViewport)) {
        return ame_real_glViewport;
    }
    ame_real_glViewport = NULL;
    void *rh = ame_rendererHandle();
    if (rh != NULL) {
        void *p = NULL;
        ame_dlsymBypassDepth++;
        p = dlsym(rh, "glViewport");
        ame_dlsymBypassDepth--;
        if (ame_glSymbolTrusted(p)) ame_real_glViewport = (ame_fn_glViewport)p;
    }
    // 刻意不回退 dlsym(RTLD_DEFAULT)：渲染器以 RTLD_LOCAL 载入时，全局符号表里
    // 的 glViewport 可能来自别的 GL 实现（系统 GLES / EAGL / 被 GLOBAL 加载的
    // ANGLE）。那与当前 EGL 上下文不匹配，一经调用即崩 —— 这正是本文件在
    // ame_SDL_GL_GetProcAddress 处注明的风险。取不到就不调用，最坏是兜底不生效，
    // 远优于引入崩溃。
    return ame_real_glViewport;
}

// 与 ame_maybeWrapEgl 平行，处理 gl* 入口。
// 关键补充：SDL_EGL_GetProcAddress / SDL_LoadFunction 此前只包装 egl* 符号，
// 而 LWJGL 的 EGL 后端正是从这两条路取 GL 函数 —— glViewport 从那里漏出，
// 导致后部的包装从未被调用（日志里 glViewport 零输出即此证据）。
static void ame_maybeWrapGl(const char *name, void **out) {
    if (name == NULL || out == NULL || *out == NULL) return;
    // glScissor 与 glViewport 是彼此独立的 GL 状态，必须一并修正，否则绘制
    // 会被残留的 scissor box 裁掉（详见 ame_glScissor 处注释）。
    if (strcmp(name, "glScissor") == 0) {
        if (ame_real_glScissor == NULL && ame_glSymbolTrusted(*out))
            ame_real_glScissor = (ame_fn_glScissor)*out;
        if (ame_real_glScissor != NULL) *out = (void *)ame_glScissor;
        return;
    }
    if (strcmp(name, "glViewport") != 0) return;
    if (ame_real_glViewport == NULL && ame_glSymbolTrusted(*out))
        ame_real_glViewport = (ame_fn_glViewport)*out;
    // 仅在真实指针可信时才换上包装；否则原样放行，绝不包装一份系统桩。
    if (ame_real_glViewport != NULL) *out = (void *)ame_glViewport;
}

// 把原始指针换成代理。orig 为 NULL 时不覆盖（ZL2 语义：首次解析后固定）。
static void ame_maybeWrapEgl(const char *name, void **out) {
    if (name == NULL || *out == NULL) return;
    if (strcmp(name, "eglChooseConfig") == 0) {
        if (ame_orig_eglChooseConfig == NULL) ame_orig_eglChooseConfig = (ame_fn_eglChooseConfig)*out;
        if (*out != (void *)ame_proxyEglChooseConfig) *out = (void *)ame_proxyEglChooseConfig;
    } else if (strcmp(name, "eglCreateContext") == 0) {
        if (ame_orig_eglCreateContext == NULL) ame_orig_eglCreateContext = (ame_fn_eglCreateContext)*out;
        if (*out != (void *)ame_proxyEglCreateContext) *out = (void *)ame_proxyEglCreateContext;
    } else if (strcmp(name, "eglSwapBuffers") == 0) {
        if (ame_orig_eglSwapBuffers == NULL) ame_orig_eglSwapBuffers = (ame_fn_eglSwapBuffers)*out;
        if (*out != (void *)ame_proxyEglSwapBuffers) *out = (void *)ame_proxyEglSwapBuffers;
    }
}

#pragma mark - SDL 函数包装

// Vulkan 路径信号的两个辅助函数在文件后部定义（与 EGL 代理同段落），
// 这里先声明：Clang 下静态函数先用后定义属隐式声明，是 error 不是 warning。
static void ame_noteVulkanWindowFlags(uint32_t flags);
static void ame_clearVulkanPathForGl(void);

static void *ame_SDL_CreateWindow(const char *title, int w, int h, uint32_t flags) {
    ame_forceEglProfileEs();
    NSDebugLog(@"[SDLHook] SDL_CreateWindow title=%s %dx%d flags=0x%x",
               title ? title : "(null)", w, h, flags);
    ame_noteVulkanWindowFlags(flags);
    bool reuse = ame_shouldReusePrimaryWindow();
    if (reuse && ame_primaryWindow != NULL) {
        ame_primaryWindowRefs++;
        NSDebugLog(@"[SDLHook] reusing primary window %p, refs=%u",
                   ame_primaryWindow, ame_primaryWindowRefs);
        ame_syncReusedWindowSize(ame_primaryWindow, w, h, true);
        return ame_primaryWindow;
    }
    void *wnd = ame_real_CreateWindow ? ame_real_CreateWindow(title, w, h, flags) : NULL;
    if (reuse && wnd != NULL) {
        ame_primaryWindow = wnd;
        ame_primaryWindowRefs = 1;
        ame_primaryWindowW = w;
        ame_primaryWindowH = h;
        // 首次建窗（26.3 的 "RenderPearl OpenGL Hidden Utility Window" 320x480）
        // 立刻把 SDL 窗口尺寸同步到 EGL surface 的真实像素尺寸。
        //
        // 这是「画面缩在左上角」的根因：MC 在紧接着的 SDL_GL_CreateContext /
        // 能力探测阶段就把窗口尺寸缓存下来了，而后续主窗口是复用本窗口
        // （reuse，refs=2）——届时再改尺寸、补发事件都已太晚，MC 认知里的
        // 尺寸早已定死为 320x480。Vulkan 不受影响正是因为它不经 SDL 取尺寸，
        // 而是直接查 metalview 的 swapchain extent。
        //
        // 此处不补发事件（pushEvent=false）：MC 事件循环此刻尚未就绪，而且
        // 尺寸从第一刻起就是对的，无需事后纠正。
        ame_syncReusedWindowSize(wnd, w, h, false);
    }
    NSDebugLog(@"[SDLHook] SDL_CreateWindow -> %p", wnd);
    return wnd;
}

static void *ame_SDL_CreateWindowWithProperties(uint32_t props) {
    ame_forceEglProfileEs();
    NSDebugLog(@"[SDLHook] SDL_CreateWindowWithProperties props=%u", props);
    if (ame_real_GetNumberProperty == NULL) {
        ame_real_GetNumberProperty =
            (ame_fn_SDL_GetNumberProperty)ame_real_dlsym("SDL_GetNumberProperty");
    }
    if (ame_real_GetNumberProperty != NULL) {
        uint32_t pflags = (uint32_t)ame_real_GetNumberProperty(
            props, "SDL.window.create.flags", 0);
        ame_noteVulkanWindowFlags(pflags);
    }
    bool reuse = ame_shouldReusePrimaryWindow();
    if (reuse && ame_primaryWindow != NULL) {
        ame_primaryWindowRefs++;
        NSDebugLog(@"[SDLHook] reusing primary window %p, refs=%u",
                   ame_primaryWindow, ame_primaryWindowRefs);
        // properties 版本的宽高需从 props 里取（SDL_PROP_WINDOW_CREATE_WIDTH/
        // HEIGHT_NUMBER）。取不到就不改尺寸，行为与改动前一致。
        if (ame_real_GetNumberProperty == NULL) {
            ame_real_GetNumberProperty =
                (ame_fn_SDL_GetNumberProperty)ame_real_dlsym("SDL_GetNumberProperty");
        }
        if (ame_real_GetNumberProperty != NULL) {
            int pw = (int)ame_real_GetNumberProperty(props, "SDL.window.create.width", 0);
            int ph = (int)ame_real_GetNumberProperty(props, "SDL.window.create.height", 0);
            ame_syncReusedWindowSize(ame_primaryWindow, pw, ph, true);
        }
        return ame_primaryWindow;
    }
    void *wnd = ame_real_CreateWindowWithProperties
                    ? ame_real_CreateWindowWithProperties(props)
                    : NULL;
    if (reuse && wnd != NULL) {
        ame_primaryWindow = wnd;
        ame_primaryWindowRefs = 1;
        ame_primaryWindowW = 0;
        ame_primaryWindowH = 0;
    }
    NSDebugLog(@"[SDLHook] SDL_CreateWindowWithProperties -> %p", wnd);
    return wnd;
}

static void ame_SDL_DestroyWindow(void *window) {
    if (window != NULL && window == ame_primaryWindow) {
        if (ame_primaryWindowRefs > 0) ame_primaryWindowRefs--;
        if (ame_primaryWindowRefs > 0) {
            NSDebugLog(@"[SDLHook] DestroyWindow %p skipped, refs=%u",
                       window, ame_primaryWindowRefs);
            return;
        }
        ame_primaryWindow = NULL;
        ame_primaryWindowRefs = 0;
        ame_primaryWindowW = 0;
        ame_primaryWindowH = 0;
        // 窗口已销毁，事件解析回落缓存必须一并失效，否则会返回悬垂指针
        ame_sdlLastEventWindow = NULL;
    }
    if (ame_real_DestroyWindow) ame_real_DestroyWindow(window);
}

static void *ame_SDL_LoadFunction(void *handle, const char *name) {
    void *r = ame_real_LoadFunction ? ame_real_LoadFunction(handle, name) : NULL;
    ame_maybeWrapEgl(name, &r);
    ame_maybeWrapGl(name, &r);
    ame_maybeWrapWindowHook(name, &r);
    return r;
}

// SDL 公共 EGL 解析入口，可绕过 SDL_LoadFunction；补齐同样的代理
static void *ame_SDL_EGL_GetProcAddress(const char *proc) {
    void *r = ame_real_EGL_GetProcAddress ? ame_real_EGL_GetProcAddress(proc) : NULL;
    if (proc == NULL || r == NULL) return r;
    ame_maybeWrapEgl(proc, &r);
    ame_maybeWrapGl(proc, &r);
    return r;
}

// Vulkan 加载器一致性：MC 26.3 起 RenderPearl 要求 SDL 与 LWJGL 使用同一
// 加载器实例（校验 vkGetInstanceProcAddr 指针一致），而 SDL 仅能按路径加载。
// 启动器若已持有句柄（十六进制记录在 AMETHYST_VULKAN_PTR），此处直接还回。
// 对应句柄的引用计数由启动器持有，故忽略 SDL 侧的卸载。
static void *ame_SDL_LoadObject(const char *path) {
    if (path != NULL && (strstr(path, "vulkan") != NULL || strstr(path, "MoltenVK") != NULL)) {
        const char *vkptr = getenv("AMETHYST_VULKAN_PTR");
        if (vkptr != NULL && vkptr[0] != '\0') {
            void *handle = (void *)(uintptr_t)strtoull(vkptr, NULL, 16);
            if (handle != NULL) {
                NSDebugLog(@"[SDLHook] SDL_LoadObject('%s') -> shared handle %p", path, handle);
                return handle;
            }
        }
    }
    return ame_real_LoadObject ? ame_real_LoadObject(path) : NULL;
}

static void ame_SDL_UnloadObject(void *handle) {
    const char *vkptr = getenv("AMETHYST_VULKAN_PTR");
    if (vkptr != NULL && vkptr[0] != '\0') {
        void *vulkan_handle = (void *)(uintptr_t)strtoull(vkptr, NULL, 16);
        if (handle == vulkan_handle) {
            NSDebugLog(@"[SDLHook] SDL_UnloadObject(%p) ignored (shared handle)", handle);
            return;
        }
    }
    if (ame_real_UnloadObject) ame_real_UnloadObject(handle);
}

// —— Vulkan 路径运行时信号（供 FPS 计数判定） ——
//
// pojavIsActualVulkanPath() 此前只看 clientAPI，而 clientAPI 是 GLFW 专用信号：
// MC 走 GLFW 时用 glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API) 声明 Vulkan 路径。
// SDL3 路径（26.2+）下 MC 从不调用 glfwWindowHint，clientAPI 停留在 pojavInit()
// 的默认值 GLFW_OPENGL_API，于是**纯 Vulkan 运行时**该函数恒为 false，
// FPS 计数器的 CADisplayLink fallback 永不启用 —— 即「Vulkan 模式 FPS 恒为 0」。
//
// 这里用建窗标志补上该信号：MC 创建带 SDL_WINDOW_VULKAN 的窗口，即说明其真实
// 走 Vulkan 路径（日志中主窗口 flags=0x10002020 正是如此）。
// 若随后又成功建立 GL 上下文（OpenGL 回退），则清除标志，避免与
// pojavSwapBuffers 的 FPS 计数重复。
#define AME_SDL_WINDOW_VULKAN 0x10000000u

static bool ame_vulkanWindowActive = false;

bool ame_sdlVulkanWindowActive(void) {
    return ame_vulkanWindowActive;
}

static void ame_noteVulkanWindowFlags(uint32_t flags) {
    if ((flags & AME_SDL_WINDOW_VULKAN) == 0) return;
    if (!ame_vulkanWindowActive) {
        // 诊断（release 可见，限一次）：MC 26.3 建了 Vulkan 窗口 = 它没有接受
        // OpenGL 后端（被 mismatch/函数解析拒绝）→ 回落 MoltenVK。注意 MoltenVK
        // 1.2.9 转译不了 26.3 的 SPIR-V（非法 MSL），此路径必然黑屏/异常。
        // 与「GL backend accepted」日志互补：两者都不出现 = 检查还没走到。
        static int ame_vkDiagBudget = 1;
        if (ame_vkDiagBudget > 0) {
            ame_vkDiagBudget--;
            NSLog(@"[SDLHook][diag] Vulkan window flags 0x%x -> MC did NOT take the "
                  @"OpenGL backend (MoltenVK fallback; renderer=%s)",
                  flags, getenv("AMETHYST_RENDERER") ?: "<unset>");
        }
        NSDebugLog(@"[SDLHook] Vulkan window flags 0x%x -> Vulkan path active", flags);
    }
    ame_vulkanWindowActive = true;
}

// —— Vulkan 路径：把启动器的分辨率缩放同步到 SDL 的呈现层 ——
//
// MC 26.3 在 Vulkan 下**不经 SDL 取窗口尺寸**，而是直接查 metalview 的
// swapchain extent（见 ame_SDL_CreateWindow 处注释「Vulkan 不受影响正是因为
// 它不经 SDL 取尺寸，而是直接查 metalview 的 swapchain extent」）。
// 而 SDL 以 UIScreen.scale（本设备 3.0）全分辨率建层 —— iPhone X 上恒为
// 2436x1125 —— 完全不知道启动器的 video.resolution。于是「切换分辨率」对
// Vulkan 无效：设 25% 与设 100% 渲染出来的像素完全一样。
//
// 这里把启动器算好的目标像素尺寸写回 SDL 的呈现层。目标尺寸直接取自
// GameSurfaceView.layer.drawableSize（即 updateSavedResolution 里
// physicalSize x resolutionScale 的结果），不新增跨模块接口。
//
// 安全阀（确保不引入新问题）：
//   - 仅在 Vulkan 路径动作；GL 路径由 EGL surface / 1x 对齐负责，一律不碰
//   - 差值 <= 2px 视为已一致，不动：100% 分辨率下两者只差 1px（奇偶取整），
//     因此默认分辨率时本函数恒为空操作
//   - 命中或确认一致后即自锁，不再重复执行
static void ame_applyLauncherResolutionToSDLLayer(void) {
    static int budget = 900;   // 约十几秒的事件轮询；命中即停
    if (budget <= 0) return;
    if (!ame_vulkanWindowActive) return;

    // 本函数要读 UIView / CALayer，只能在主线程执行。
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ame_applyLauncherResolutionToSDLLayer();
        });
        return;
    }
    budget--;

    int tw = 0, th = 0;
    if (!ame_eglSurfacePixelSizeFromUIKit(&tw, &th) || tw <= 0 || th <= 0) return;

    CALayer *layer = Amethyst_SDL3RenderLayer();
    if (layer == nil) return;
    if (![layer respondsToSelector:NSSelectorFromString(@"drawableSize")]) return;

    CGSize cur = [[layer valueForKey:@"drawableSize"] CGSizeValue];
    if (fabs(cur.width - (CGFloat)tw) <= 2.0 && fabs(cur.height - (CGFloat)th) <= 2.0) {
        budget = 0;   // 已一致（含 100% 分辨率下的 1px 取整差），收工
        return;
    }
    [layer setValue:[NSValue valueWithCGSize:CGSizeMake((CGFloat)tw, (CGFloat)th)]
             forKey:@"drawableSize"];
    budget = 0;
    NSLog(@"[SDLHook] Vulkan resolution: SDL render layer %.0fx%.0f -> %dx%d "
          @"(launcher video.resolution)", cur.width, cur.height, tw, th);
}

// GL 上下文成功建立 => MC 实际走 GL，撤销 Vulkan 判定，避免 FPS 双重计数
static void ame_clearVulkanPathForGl(void) {
    if (ame_vulkanWindowActive) {
        ame_vulkanWindowActive = false;
        NSDebugLog(@"[SDLHook] GL context in use -> Vulkan path flag cleared");
    }
}

#pragma mark - 5) SDL GL 入口 → 启动器 EGL bridge

// 为什么需要接管：
//   SDL 的 UIKit 后端走的是 EAGL / CAEAGLLayer（iOS 系统 OpenGLES 框架），
//   而 MobileGL / Mithril / MobileGlues 提供的是 **EGL + GL** 符号。两者不是
//   同一套 ABI，SDL 自己建的上下文拿不到渲染器的 GL 函数，MC 26.3 的
//   GlBackend 因此判定 OpenGL 不可用并回落到原生 Vulkan。
//
//   启动器的 EGL bridge（gl_bridge.m）早已在 GLFW 路径（26.2 及以下）验证可用，
//   且 gl_init_context() 直接从 SurfaceViewController 的 layer 建 EGL surface，
//   不依赖 SDL 建了哪个 view —— 所以可以整条搬到 SDL3 路径上复用。
//
// 判定复用 ame_sdlGlesCompatEnabled() 那套渲染器名单，但语义相反：ES 化豁免
// ≠ GL bridge 豁免。Task 79 起 zink（libOSMesa/gallium_/vulkan_zink）也走
// bridge——见下方函数内的 Task 79 注释；ES 强制化（ame_sdlGlesCompatEnabled）
// 依然排除 zink，两套判定互不牵连。
//
// 默认开启（2026-09-05 实测结论）：
//
// 此前默认关闭的理由是"接管后桌面 GLSL 经 shaderc/glslang 编译稳定崩溃"。该
// 崩溃根因已定位并修复 —— MobileGL 静态嵌入 glslang/SPIRV-Tools，其 C++ 符号
// 与 shaderc 内嵌的副本在 dyld 层 interpose，同一 Module 对象被两套布局解析，
// 崩于 spvtools::opt::Module::ForEachInst。上游 MobileGL 早已为 macOS 用
// exported_symbols_list 修过（只导出 _CGL*/_egl*/_gl[A-Z0-9]*），唯独 iOS 分支
// 被条件排除；补齐后重编的 dylib 实测不再崩溃。
//
// 另需说明：崩溃与"是否接管"无关。曾实测 BRIDGE=0 + NO_PRELOAD_RENDERER=1 同样
// 崩在同一地址 —— 真正的变量是 MobileGL 以 RTLD_GLOBAL 还是 RTLD_LOCAL 载入。
//
// 实测（874b9e8，接管 + DirectGLES）：MC 完整走通 OpenGL 后端，资源全部加载、
// 首帧渲染成功、无崩溃，仅画面全黑。黑屏系主窗口复用后未同步尺寸所致，已由
// ame_syncReusedWindowSize() 修复（iOS 无 ZL2 依赖的 Android Surface 前提）。
//
// 回落路径的风险已不再是默认关闭的理由：MoltenVK 1.2.9（为修 A11 上 1.21.1
// 草方块而降级）转译不了 MC 26.3 的 SPIR-V，会生成非法 MSL
// （float3 vertex(thread const int& index)），故 26.3 现在更不能依赖回落。
//
// 如需回到"不接管 -> 回落 Vulkan"，用 AMETHYST_SDL_GL_BRIDGE=0。
static bool ame_glBridgeEnabled(void) {
    if (!ame_envFlagOn("AMETHYST_SDL_GL_BRIDGE", true)) return false;

    const char *renderer = getenv("AMETHYST_RENDERER");
    if (renderer == NULL || renderer[0] == '\0') return false;

    // Task 79：zink（libOSMesa/gallium_/vulkan_zink）从【绝不接管】改为【接管】。
    //
    // 旧排除（c71dcfa，2026-09-01）的语境：当时 renderpearl 的
    // GlBackend.loadLibrary 指针一致性检查还没被 provider-mirror 机制攻克
    // （那正是 c71dcfa 为 MobileGlues 引入 ame_SDL_GL_GetProcAddress 镜像链的
    // 缘由），zink 过不了检查 → 回落 Vulkan 是彼时唯一能进世界的路径，
    // “一个字节都不能动”是对那个未修复状态的保护，不是 zink 不能用 GL。
    //
    // 现在的设备证据（8a31d1b，用户上报“zink 在 26.3 的启动回退”）：
    //   [SDLGL] SDL_GL_LoadLibrary(.../libOSMesa.8.dylib) -> failed: OpenGL
    //           library already loaded（main_hook 兑装成功，但真实 SDL 拒载）
    //   [Render thread/ERROR]: Failed to create backend OpenGL
    //           BackendCreationException: glGetError mismatch
    //   → Using graphics backend Vulkan (MoltenVK 1.4.2) —— ZinkConfig 全部
    //     空转，用户选的 zink 实际跑的是 MC 原生 Vulkan 后端。
    //
    // 修法与 MobileGlues 同构：bridge 接管 SDL_GL_LoadLibrary（真实 SDL 从不被
    // 调 → “already loaded” 无从谈起）+ SDL_GL_GetProcAddress 镜像 LWJGL 解析链
    // （同一 NOLOAD 句柄 + 同一 eglGetProcAddress/OSMesaGetProcAddress 链 →
    // 指针一致性按构造成立）→ GL backend 被接受 → 上下文/呈现走与 ≤26.2 完全
    // 相同的 OSMesa bridge（osm_init_context / osm_make_current / osm_swap_buffers）。
    // MG 侧已验证的对照日志（2d321fa）：hooked SDL_GL_LoadLibrary -> EGL bridge →
    // “Using graphics backend OpenGL, using drivers: 4.0.0 MobileGlues 2.0.17”。
    //
    // 逃生阀：AMETHYST_ZINK_GL_BRIDGE=0 一行环境变量即回退到旧行为（不接管 →
    // 回落 Vulkan），供设备上 A/B 对照或万一 GL 路径出问题时应急处置。
    if (strncmp(renderer, "libOSMesa", 9) == 0) {    // zink（带版本号）
        return ame_envFlagOn("AMETHYST_ZINK_GL_BRIDGE", true);
    }
    if (strncmp(renderer, "gallium_", 8) == 0) {     // OSMesa 系
        return ame_envFlagOn("AMETHYST_ZINK_GL_BRIDGE", true);
    }
    if (strcmp(renderer, "vulkan_zink") == 0) {      // zink
        return ame_envFlagOn("AMETHYST_ZINK_GL_BRIDGE", true);
    }
    // 原生 Vulkan 自身走 Vulkan 路径，不需要 GL bridge
    if (strstr(renderer, "libMoltenVK") != NULL) return false;

    // 需要 EGL bridge 的转译型渲染器：它们提供 EGL + GL 符号，SDL 的 EAGL
    // 后端无法对接，必须由 bridge 建上下文并供给 GL 函数指针。
    if (strstr(renderer, "libMobileGL") != NULL) return true;    // MobileGL 双后端
    if (strstr(renderer, "libmithril") != NULL) return true;     // Mithril
    if (strstr(renderer, "mobileglues") != NULL) return true;    // MobileGlues
    if (strstr(renderer, "gl4es") != NULL) return true;          // GL4ES
    if (strstr(renderer, "libltw") != NULL) return true;         // LTW
    if (strncmp(renderer, "opengles", 8) == 0) return true;      // 内置 GLES

    return ame_isMobileGluesEgl();
}

// egl_bridge.m 的上下文入口。这些函数没有公开头文件，故在此 extern 声明。
// 参数用 void* 以避开 basic_render_window_t 的类型依赖。
// SDL3 路径用 ForSDL3 变体：不写 org.lwjgl.opengl.libname（该属性由 JavaLauncher
// 在 JVM 启动时以 -D 传入，LWJGL 早已读取；此处再设无效且需 attach 非 JVM 线程）。
extern int   pojavInitOpenGLForSDL3(void);
extern void *pojavCreateContext(void *contextSrc);
extern void  pojavMakeCurrent(void *window);
extern void  pojavSwapBuffers(void);
extern void  pojavSwapInterval(int interval);
// Air Task 32 / Task 52：SDL3 呈现层不变量执法（主线程调用）
extern BOOL  Amethyst_EnforceSDL3Presentation(void);

static bool   g_glBridgeInited = false;
static void  *g_glContext = NULL;      // 充当 SDL_GLContext
static void  *g_rendererHandle = NULL; // 渲染器 dylib 句柄（缓存，避免重复 dlopen）

// LWJGL OpenGL FunctionProvider 所用库的确切路径（SDL_GL_LoadLibrary 的入参
// = GL.getFunctionProvider().getPath()）。ame_rendererHandle 优先按它 NOLOAD
// 取回 LWJGL 正在使用的同一镜像，保证钩子的 dlsym 落点与 LWJGL 完全一致。
//
// 非 static：ame_SDL_GL_LoadLibrary（本文件更靠后的 ame_SDL_GL_LoadLibrary
// 处）会写入它，两处直接共享同一个全局符号。
char g_lwjglGLLibPath[1024] = {0};

static void *ame_rendererHandle(void) {
    if (g_rendererHandle != NULL) return g_rendererHandle;

    // 首选：LWJGL provider 的确切路径（由 ame_SDL_GL_LoadLibrary 捕获）。
    // NOLOAD 只查询既有映射、不改变可见性 —— 对 RTLD_LOCAL 载入的渲染器
    // 依然有效（本仓库对渲染器**刻意**不用 RTLD_GLOBAL，理由见下方注释）。
    if (g_lwjglGLLibPath[0] != '\0') {
        void *h = dlopen(g_lwjglGLLibPath, RTLD_NOW | RTLD_NOLOAD);
        if (h != NULL) {
            g_rendererHandle = h;
            NSDebugLog(@"[SDLHook] renderer handle <- LWJGL provider path (NOLOAD): %s",
                       g_lwjglGLLibPath);
            return g_rendererHandle;
        }
        NSDebugLog(@"[SDLHook] NOLOAD dlopen('%s') failed: %s -- falling back to @rpath",
                   g_lwjglGLLibPath, dlerror() ?: "unknown");
    }

    const char *renderer = getenv("AMETHYST_RENDERER");
    if (renderer == NULL || renderer[0] == '\0') return NULL;
    NSString *path = [NSString stringWithFormat:@"@rpath/%s", renderer];

    // 必须用 RTLD_NOLOAD：绝不可带 RTLD_GLOBAL，也不可退回"普通"dlopen。
    //
    // 渲染器由 pojavInitOpenGL 以 RTLD_LOCAL 载入，目的就是把它内嵌的 glslang
    // 关在自己的镜像里 —— 一旦进入全局符号空间，便会与 libshaderc.dylib 中那份
    // glslang 合并、共用线程局部的 AST 内存池，随后在
    // TGlslangToSpvTraverser::visitAggregate 解引用到已释放内存而 SIGSEGV
    // （26.3 上崩溃地址固定为 libshaderc.dylib+0x155820）。
    //
    // 而 dlopen 一个已加载的镜像时若带上 RTLD_GLOBAL，会把原本 RTLD_LOCAL 的
    // 镜像提升为全局可见 —— 隔离被静默解除，既无报错也无日志。这正是 MobileGL
    // 原本安全、接入 viewport 解析之后反而崩溃的原因：新代码首次调用到本函数，
    // 触发了这次提升。
    //
    // RTLD_NOLOAD 只查询既有映射、不改变其可见性。dlsym 用显式句柄取符号，对
    // RTLD_LOCAL 镜像同样有效，故功能完全不受影响。@rpath + RTLD_NOLOAD 在本
    // 仓库已有先例（egl_bridge 的预载探测即用此组合）。
    void *h = dlopen(path.UTF8String, RTLD_NOW | RTLD_NOLOAD);
    if (h == NULL) {
        // 渲染器尚未载入。此处刻意不退化为不带 RTLD_NOLOAD 的 dlopen —— 那会
        // 以默认可见性重新加载，同样绕过隔离。返回 NULL，让调用方安全跳过。
        NSDebugLog(@"[SDLHook] renderer not loaded yet (RTLD_NOLOAD): %s",
                   dlerror() ?: "unknown");
        return NULL;
    }
    g_rendererHandle = h;
    return g_rendererHandle;
}

// 库已由启动器预加载，这里只负责初始化 bridge
static bool ame_SDL_GL_LoadLibrary(const char *path) {
    // 记录 LWJGL provider 的确切路径（= GL.getFunctionProvider().getPath()），
    // ame_rendererHandle 据此用 RTLD_NOLOAD 取回**同一个** Loader 的句柄 ——
    // 本钩子的 dlsym 落点与 LWJGL 完全一致，也不会重复映射镜像。
    // （Air c71dcfa0：仅靠 @rpath/<renderer> 兜底可能因 @rpath 展开差异失手，
    //  届时 ame_rendererHandle 返回 NULL，GetProcAddress 退到 RTLD_DEFAULT，
    //  GL$1 镜像链随之失效 —— mismatch 复发。）
    //
    // 顺序保证：GlBackend.loadLibrary 在任何 SDL_GL_GetProcAddress 之前
    // 必然先调本函数，所以这里捕获的路径一定先于查询可用。
    if (path != NULL && path[0] != '\0') {
        if (g_lwjglGLLibPath[0] == '\0') {
            strlcpy(g_lwjglGLLibPath, path, sizeof(g_lwjglGLLibPath));
            NSDebugLog(@"[SDLHook] captured LWJGL GL provider path: %s", g_lwjglGLLibPath);
        }
    }
    if (!g_glBridgeInited) {
        g_glBridgeInited = true;
        int r = pojavInitOpenGLForSDL3();
        NSDebugLog(@"[SDLHook] SDL_GL_LoadLibrary('%s') -> pojavInitOpenGLForSDL3()=%d (EGL bridge)",
                   path ?: "<null>", r);
    }
    return true;
}

static void *ame_SDL_GL_CreateContext(void *window) {
    // 渲染器 constructor（含其自解析 GL 符号）在 dlopen 期间即已跑完，此刻打开
    // 显式句柄接管不会再撞上 dyld 加载锁。
    ame_glWrapExplicitHandle = true;
    // MC 26.3 ss9+ 在设备初始化时先建一个隐藏工具窗口（flags 含 SDL_WINDOW_HIDDEN），
    // 随后再建主窗口。而 EGL bridge 的上下文生命周期与进程一致
    // （SDL_GL_DestroyContext 不真正销毁，见下），若每次调用都新建，就会在同一个
    // CALayer 上叠加第二个 EGLSurface —— 部分 EGL 实现（含 MobileGL）会直接失败，
    // 即便成功也会让 eglMakeCurrent 在两个 surface 间反复切换。
    // 故复用首个上下文，与 ZL2 的 shouldReusePrimaryWindow() 同一思路。
    if (g_glContext != NULL) {
        NSDebugLog(@"[SDLHook] SDL_GL_CreateContext(%p) -> reuse existing %p", window, g_glContext);
        // 复用时也要保证它处于 current 状态：MC 建完上下文后必然调 MakeCurrent，
        // 这里不额外处理。
        return g_glContext;
    }
    void *ctx = pojavCreateContext(NULL);
    if (ctx != NULL) {
        g_glContext = ctx;
        ame_clearVulkanPathForGl();
        // 诊断（release 可见，限一次）：此日志在场 = MC 26.3 接受了 OpenGL 后端，
        // 黑屏与「glGetError mismatch → 回退 MoltenVK」无关，问题在呈现层。
        // 此日志缺席 + 出现「Vulkan window flags」= MC 拒绝了 GL，走了 MoltenVK。
        static BOOL ame_loggedGlBackend = NO;
        if (!ame_loggedGlBackend) {
            ame_loggedGlBackend = YES;
            NSLog(@"[SDLHook][diag] GL backend accepted: SDL_GL_CreateContext -> %p "
                  @"(renderer=%s, GL$1 mirror active)", ctx,
                  getenv("AMETHYST_RENDERER") ?: "<unset>");
        }
    }
    NSDebugLog(@"[SDLHook] SDL_GL_CreateContext(%p) -> %p (EGL bridge)", window, ctx);
    return ctx;
}

static ame_fn_glViewport ame_resolve_glViewport(void);

static bool ame_SDL_GL_MakeCurrent(void *window, void *context) {
    ame_glWrapExplicitHandle = true;
    if (context != NULL) {
        g_glContext = context;
        ame_clearVulkanPathForGl();
    }
    pojavMakeCurrent(context);
    NSDebugLog(@"[SDLHook] SDL_GL_MakeCurrent(%p, %p) -> EGL bridge", window, context);
    return true;
}

static bool ame_SDL_GL_SwapWindow(void *window) {
    // 每帧必经。放在交换之前：补发的事件由 MC 在下一帧消费，不影响本帧绘制。
    ame_maybeNudgeWindowResize();
    pojavSwapBuffers();
    return true;
}

// —— viewport 兜底：在尺寸交给 GL 的最后一步修正 ——
//
// 三个尺寸查询（SDL_GetWindowSize / GetWindowSizeInPixels /
// GL_GetDrawableSize）都已接管，回报 EGL surface 的真实像素。但 MC 未必在
// 正确的时机重新查询：它可能沿用建窗阶段缓存的值，也可能取窗口事件里的
// data1/data2。一旦拿到的是 SDL 内部的 points(812x375) 或隐藏工具窗口的
// 320x480，画面就只占屏幕左上角一小块，且必须手动改一次分辨率才恢复。
//
// 与其继续猜测 MC 从哪条路径取尺寸，不如在落地点兜底：glViewport 是 MC
// 把尺寸交给 GL 的最后一步，在这里改写即可保证渲染区域恒等于 EGL surface。
//
// 判定刻意保守 —— 只精确匹配「已知的错误候选」，不做比例推断，以免误伤
// 渲染到 FBO 时的合法小 viewport（阴影贴图、GUI 元素、缩略图等）。
// —— 小窗定位用的一次性 GL 状态快照 ——
// 两处守护都把 viewport 改写成了 EGL surface 尺寸（日志里 MISMATCH->corrected
// 反复出现），画面却仍缩在左上角 —— 说明瓶颈不在 viewport。剩下两种可能：
//   a) GL_SCISSOR_BOX 仍停在 points(812x375) 且开了 scissor test，把绘制裁掉；
//   b) MC 渲染进了自建 FBO，其尺寸来自初始化时缓存的错误窗口尺寸。
// 这里在 glViewport 入口顺带读一次，用一条日志把两者区分开。只读，不改写。
static int ame_glStateLogBudget = 3;
static void ame_logGLStateOnce(const char *tag) {
    if (ame_glStateLogBudget <= 0) return;
    void *rh = ame_rendererHandle();
    if (rh == NULL) return;
    void *p = dlsym(rh, "glGetIntegerv");
    if (p == NULL || !ame_glSymbolTrusted((const void *)p)) return;
    ame_fn_glGetIntegerv giv = (ame_fn_glGetIntegerv)p;
    int32_t vp[4] = {0, 0, 0, 0};
    int32_t sc[4] = {0, 0, 0, 0};
    int32_t st = 0, fb = 0;
    giv(0x0BA2, vp);   // GL_VIEWPORT
    giv(0x0C10, sc);   // GL_SCISSOR_BOX
    giv(0x0C11, &st);  // GL_SCISSOR_TEST
    giv(0x8CA6, &fb);  // GL_FRAMEBUFFER_BINDING
    ame_glStateLogBudget--;
    NSDebugLog(@"[SDLHook][glstate] %s viewport=%dx%d scissor=%dx%d scissorTest=%d fb=%d",
               tag, vp[2], vp[3], sc[2], sc[3], st, fb);
}

static ame_fn_glScissor ame_resolve_glScissor(void) {
    if (ame_real_glScissor != NULL &&
        ame_glSymbolTrusted((const void *)ame_real_glScissor)) {
        return ame_real_glScissor;
    }
    ame_real_glScissor = NULL;
    void *rh = ame_rendererHandle();
    if (rh != NULL) {
        void *p = NULL;
        ame_dlsymBypassDepth++;
        p = dlsym(rh, "glScissor");
        ame_dlsymBypassDepth--;
        if (ame_glSymbolTrusted(p)) ame_real_glScissor = (ame_fn_glScissor)p;
    }
    // 同 ame_resolve_glViewport：绝不回退 RTLD_DEFAULT。
    return ame_real_glScissor;
}

// —— 当前是否渲染到默认 framebuffer ——
//
// 只有渲染目标是默认 framebuffer(0) 时，viewport / scissor 才「必须」等于 EGL
// surface 尺寸。若绑定的是 FBO，小 viewport 是合法的离屏/后处理渲染（阴影贴图、
// 后处理中间态），改动它会破坏画面。egl_bridge.m 的 swap 守护早已有这道判定
// （`if (fb != 0) return;`），此处的包装此前缺失 —— 仅靠 ame_viewportIsBad 的
// 「精确匹配已知错误候选」并不足够：某个 FBO 恰好是 320x480 或恰好等于 points
// 尺寸时会误判。补上这道判定，使两处策略一致。
//
// 返回 -1 表示无法判定（拿不到可信的 glGetIntegerv），此时调用方应保守放行
// 原始值 —— 宁可漏修，不可误伤。
static int32_t ame_currentFramebufferBinding(void) {
    void *rh = ame_rendererHandle();
    if (rh == NULL) return -1;
    void *p = dlsym(rh, "glGetIntegerv");
    if (p == NULL || !ame_glSymbolTrusted((const void *)p)) return -1;
    int32_t fb = -1;
    ((ame_fn_glGetIntegerv)p)(0x8CA6 /* GL_FRAMEBUFFER_BINDING */, &fb);
    return fb;
}

// MC 可能只在初始化阶段调用一次 glScissor，之后再也不调。于是即使我们接管了
// glScissor，残留的旧 box 仍会一直裁剪下去。这里在修正 viewport 的同一时刻
// 顺带校正一次：若当前 box 命中已知的错误候选，直接用 EGL surface 尺寸覆盖。
// 只读一次 GL_SCISSOR_BOX，且仅在判定为坏值时才写，正常帧零额外开销。
static int ame_scissorFixBudget = 8;
// 现在每次 glViewport 都会调用本函数（不再只在 viewport 为坏值时触发），
// 必须限制 glGetIntegerv 查询次数，否则等于给每次 viewport 设置都加一次
// GL 状态查询。判定仍只在命中坏值时才写。
static int ame_scissorProbeBudget = 24;
static void ame_fixStaleScissor(int eglW, int eglH) {
    if (ame_scissorFixBudget <= 0) return;
    if (ame_scissorProbeBudget <= 0) return;
    // 绑定 FBO 时不介入：scissor box 的「陈旧」判定同样依赖它应等于 surface 这一
    // 前提，而在离屏渲染下该前提不成立。先判 fb 可以省掉下面这次 GL 状态查询。
    if (ame_currentFramebufferBinding() != 0) return;
    ame_scissorProbeBudget--;
    if (ame_real_glScissor == NULL) (void)ame_resolve_glScissor();
    if (ame_real_glScissor == NULL) return;
    void *rh = ame_rendererHandle();
    if (rh == NULL) return;
    void *p = dlsym(rh, "glGetIntegerv");
    if (p == NULL || !ame_glSymbolTrusted((const void *)p)) return;
    ame_fn_glGetIntegerv giv = (ame_fn_glGetIntegerv)p;
    int32_t sc[4] = {0, 0, 0, 0};
    giv(0x0C10, sc);  // GL_SCISSOR_BOX
    const char *why = NULL;
    if (sc[2] > 0 && sc[3] > 0 &&
        ame_viewportIsBad(sc[2], sc[3], eglW, eglH, &why)) {
        ame_scissorFixBudget--;
        NSDebugLog(@"[SDLHook] scissor box %dx%d stale -> %dx%d (EGL surface)",
                   sc[2], sc[3], eglW, eglH);
        ame_real_glScissor(sc[0], sc[1], (int32_t)eglW, (int32_t)eglH);
    }
}

static void ame_glScissor(int32_t x, int32_t y, int32_t width, int32_t height) {
    if (ame_real_glScissor == NULL) {
        (void)ame_resolve_glScissor();
        if (ame_real_glScissor == NULL) return;  // 拿不到可信实现则原样放行
    }
    // 绑定 FBO 时不介入：离屏渲染里的 scissor 尺寸由渲染目标自身决定，与 EGL
    // surface 无关，不适用「应等于 surface」这一前提（见
    // ame_currentFramebufferBinding 处注释）。
    int32_t fb = ame_currentFramebufferBinding();
    int eglW = 0, eglH = 0;
    bool haveSurface = (fb == 0) && ame_eglSurfacePixelSize(&eglW, &eglH);
    const char *why = NULL;
    bool bad = haveSurface ? ame_viewportIsBad(width, height, eglW, eglH, &why) : false;
    if (ame_glScissorLogBudget > 0) {
        ame_glScissorLogBudget--;
        NSDebugLog(@"[SDLHook] glScissor %dx%d (egl surface %dx%d, %s)",
                   width, height, eglW, eglH,
                   fb != 0 ? "fbo-bound, skipped"
                           : (!haveSurface ? "no surface"
                                           : (bad ? (why != NULL ? why : "bad") : "ok")));
    }
    if (bad) {
        width = (int32_t)eglW;
        height = (int32_t)eglH;
    }
    ame_real_glScissor(x, y, width, height);
}

static void ame_glViewport(int32_t x, int32_t y, int32_t width, int32_t height) {
    // 无条件记录入口参数，且必须早于任何提前返回：此前日志放在「解析到真实
    // 实现」之后，于是「拿不到实现而被静默丢弃」的情况一个字都不留，无法区分
    // 是 MC 没调用、还是调用被悄悄丢掉了。
    if (ame_glViewportLogBudget > 0) {
        ame_glViewportLogBudget--;
        NSDebugLog(@"[SDLHook] glViewport in %dx%d (x=%d y=%d)", width, height, x, y);
    }
    ame_logGLStateOnce("glViewport");
    if (ame_real_glViewport == NULL) {
        // 接管时可能还没拿到渲染器句柄，这里再解析一次。
        (void)ame_resolve_glViewport();
        if (ame_real_glViewport == NULL) {
            if (ame_glViewportLogBudget > 0) {
                ame_glViewportLogBudget--;
                NSDebugLog(@"[SDLHook] glViewport DROPPED: no trusted impl");
            }
            return;  // 仍拿不到则不接管，安全放行
        }
    }

    // 绑定 FBO 时不介入：离屏渲染的 viewport 尺寸由渲染目标自身决定，与 EGL
    // surface 无关。注意这道判定必须早于 ame_viewportIsBad —— 后者的三个候选
    // 都是「精确匹配已知错误值」，若某个 FBO 恰好是 320x480 之类的尺寸，仅靠
    // 候选匹配会误伤。egl_bridge.m 的 swap 守护一直有此判定，此处补齐以保持一致。
    int32_t fb = ame_currentFramebufferBinding();
    int eglW = 0, eglH = 0;
    bool haveSurface = (fb == 0) && ame_eglSurfacePixelSize(&eglW, &eglH);

    // 判定统一由 ame_viewportIsBad 承担：swap 前的观测走同一套候选，
    // 判定集中在此，避免多处逻辑各自漂移。
    const char *why = NULL;
    bool bad = haveSurface ? ame_viewportIsBad(width, height, eglW, eglH, &why) : false;

    // 无条件记录前若干次：MC 实际设置的 viewport 是什么，是判断「小窗」成因的
    // 唯一直接证据。若这里打印的值已等于 EGL surface，问题就不在 viewport，
    // 而在呈现环节（layer 尺寸 / 视图层级），需换方向查。
    if (ame_glViewportLogBudget > 0) {
        ame_glViewportLogBudget--;
        NSDebugLog(@"[SDLHook] glViewport %dx%d (egl surface %dx%d, %s)",
                   width, height, eglW, eglH,
                   fb != 0 ? "fbo-bound, skipped"
                           : (!haveSurface ? "no surface"
                                           : (bad ? (why != NULL ? why : "bad") : "ok")));
    }
    if (bad) {
        width = (int32_t)eglW;
        height = (int32_t)eglH;
    }
    // scissor 与 viewport 是彼此独立的 GL 状态，修正逻辑不该耦合。挂在 bad
    // 分支下时，只要 viewport 进到这里已经是对的（例如上游 egl_bridge 的
    // viewport guard 先纠正过），bad == false，修正就永远不执行——而这恰好
    // 是「viewport 已是全屏、画面仍缩在左上角」的组合。
    if (haveSurface) ame_fixStaleScissor(eglW, eglH);

    ame_real_glViewport(x, y, width, height);
}

// —— 当前渲染器是否为 OSMesa 系（zink / gallium / Mesa 软栈）——
//
// 判定与 egl_bridge.m 的 bridge 选择同源（AMETHYST_RENDERER 以 "libOSMesa"
// 开头 → set_osm_bridge_tbl）。OSMesa 路径没有 EGL surface，凡是以「EGL
// surface 像素尺寸」为前提的 GL 状态纠正都不适用于它。
static BOOL ame_isOsmesaRendererName(void) {
    const char *r = getenv("AMETHYST_RENDERER");
    if (r == NULL || r[0] == '\0') return NO;
    return strncmp(r, "libOSMesa", 9) == 0;
}

// GL 函数必须来自渲染器自身。若误返回系统 GLES / EAGL 的实现，
// LWJGL 拿到的函数指针与 EGL 上下文不匹配，会直接崩。
static void *ame_SDL_GL_GetProcAddress(const char *proc) {
    if (proc == NULL) return NULL;
    // MobileGlues 的 egl* 包装一律不外发。原因同上（见 ame_surfaceSizeFromEGL
    // 处注释）：MG 内部对 EGL 1.5 入口用 LOAD_EGL 解析，后端为 EGL 1.4 时拿到
    // NULL 却照常返回，任何调用方一跳转即 SIGSEGV(pc=0x0) —— eglGetCurrentDisplay
    // 已实测于 libmobileglues.dylib+0xd8238。
    // SDL_GL_GetProcAddress 语义上是 **GL** 入口查询，EGL 入口本就该来自 SDL /
    // 系统 EGL。此处宁可让调用方拿到 NULL 走降级，也绝不交出一个会跳 0x0 的指针。
    // 仅对 MobileGlues 生效，MobileGL / gl4es / Mithril 行为完全不变。
    if (ame_isMobileGluesEgl() && proc[0] == 'e' && proc[1] == 'g' && proc[2] == 'l') {
        return ame_real_GL_GetProcAddress ? ame_real_GL_GetProcAddress(proc) : NULL;
    }
    // glViewport 走我们的包装：它是 MC 把窗口尺寸交给 GL 的最后一步，
    // 在此兜底可确保渲染区域恒等于 EGL surface（见 ame_glViewport 处注释）。
    // —— OSMesa 系（zink / gallium）不接管 viewport / scissor ——
    //
    // 这套包装的设计前提是「渲染目标是 EGL surface，viewport 必须等于 surface
    // 像素尺寸」。OSMesa/zink 路径根本没有 EGL surface：ame_eglSurfacePixelSize
    // 在此只能退回 CAMetalLayer.drawableSize（呈现层尺寸），而 MC 真正渲染的是
    // OSMesa 的 client buffer（尺寸由 windowWidth/windowHeight 决定，两者常常
    // 不等）。拿呈现层尺寸去改写 OSMesa 渲染的 viewport，会把绘制推出 buffer
    // 边界 —— buffer 内无内容，上屏即全黑（26.3 + sodium + zink 进世界后
    // 方块/生物全黑的统一解释）。
    //
    // 参考仓库（Air）的 sdl3_hook 从未引入这套包装，故不存在该问题；此处对齐
    // 其行为：OSMesa 下不包装，MC 拿到的就是本路径原生的 glViewport/glScissor。
    //
    // 逃生阀：AMETHYST_VIEWPORT_GUARD_OSMESA=1 可在 OSMesa 下强制恢复接管。
    BOOL osmesaGuardOff = ame_isOsmesaRendererName() &&
                          !ame_envFlagOn("AMETHYST_VIEWPORT_GUARD_OSMESA", false);
    if (osmesaGuardOff) {
        static BOOL s_osmGuardLogged = NO;
        if (!s_osmGuardLogged) {
            s_osmGuardLogged = YES;
            NSLog(@"[SDLHook] OSMesa/zink path: glViewport/glScissor guard disabled "
                  @"(no EGL surface; presenting buffer size != drawableSize)");
        }
    }
    if (!osmesaGuardOff && strcmp(proc, "glViewport") == 0) {
        if (ame_real_glViewport == NULL) {
            void *rh = ame_rendererHandle();
            if (rh != NULL)
                ame_real_glViewport = (ame_fn_glViewport)dlsym(rh, proc);
            // 同 ame_resolve_glViewport：不回退 RTLD_DEFAULT。取不到就原样放行，
            // 让 MC 拿到本路径本会给出的结果 —— 宁可不包装，也不包装一份可能
            // 与当前上下文不匹配的实现。
        }
        if (ame_real_glViewport != NULL) return (void *)ame_glViewport;
    }
    if (!osmesaGuardOff && strcmp(proc, "glScissor") == 0) {
        // 与 dlsym 路径保持一致：必须校验镜像可信性，否则可能包装一份与当前
        // EGL 上下文不匹配的实现（系统 GLES 桩），一调用就崩。
        if (ame_real_glScissor == NULL ||
            !ame_glSymbolTrusted((const void *)ame_real_glScissor)) {
            ame_real_glScissor = NULL;
            void *rh = ame_rendererHandle();
            if (rh != NULL) {
                void *p = dlsym(rh, proc);
                if (ame_glSymbolTrusted(p))
                    ame_real_glScissor = (ame_fn_glScissor)p;
            }
        }
        if (ame_real_glScissor != NULL) return (void *)ame_glScissor;
        // 拿不到可信实现则不接管，交由调用方回落原路径。
    }
    void *h = ame_rendererHandle();
    if (h != NULL) {
        // 镜像 LWJGL 3.4.1 的 GL$1（macOS 分支）解析链 —— 修复 26.3 的
        // "glGetError mismatch"（Air c71dcfa0）。
        //
        // MC 26.3 的 renderpearl GlBackend.loadLibrary 硬性要求：
        //     addr1 = GL.getFunctionProvider().getFunctionAddress("glGetError")
        //     addr2 = SDLVideo.SDL_GL_GetProcAddress("glGetError")
        //     if (addr1 != addr2) throw "glGetError mismatch"
        // 不满足就拒绝 OpenGL 后端、回退 MoltenVK（启动遮罩还会卡住）。
        //
        // LWJGL 的 macOS FunctionProvider 构造是：
        //     GetProcAddress = dlsym(lib, "eglGetProcAddress")，
        //                      否则 dlsym(lib, "OSMesaGetProcAddress")；
        //     查询时        GetProcAddress(name) 非空则取结果，
        //                      否则 dlsym(lib, name)。
        // 本钩子此前只做最后那条 dlsym(lib, name)，与 LWJGL 走的是两条不同的
        // 链 —— 对 MG 这种「自己实现 eglGetProcAddress 分发」的渲染器，
        // 两条链会给出不同地址，于是 mismatch。
        //
        // 修法：按构造对齐 —— 先走 eglGetProcAddress / OSMesaGetProcAddress，
        // 再回落到 dlsym(lib, name)。两条腿由此执行同一条链、调用同一个函数
        // 对象，指针一致性按构造成立，不依赖 dyld 的 caller-image 语义
        // （启动器的全局 dlsym 重绑定会让 RTLD_SELF/RTLD_NEXT 判定失准，
        // 任何依赖镜像顺序的方案都不可靠）。
        static void *g_mirrorGPA = NULL;
        static bool  g_mirrorGPATried = false;
        if (!g_mirrorGPATried) {
            g_mirrorGPATried = true;
            g_mirrorGPA = dlsym(h, "eglGetProcAddress");
            if (g_mirrorGPA == NULL) g_mirrorGPA = dlsym(h, "OSMesaGetProcAddress");
            // 诊断（release 可见）：provider 取不到 = GL$1 镜像链失效 =
            // mismatch 会复发（MC 拒绝 GL 后端回退 MoltenVK）。正常应非 NULL。
            NSLog(@"[SDLHook][diag] GL$1 mirror provider = %p (eglGetProcAddress/OSMesaGetProcAddress from %s)",
                  g_mirrorGPA, getenv("AMETHYST_RENDERER") ?: "<unset>");
        }
        if (g_mirrorGPA != NULL) {
            void *p = ((void *(*)(const char *))g_mirrorGPA)(proc);
            if (p != NULL) return p;
        }
        // 对齐 GL$1 的回退：dlsym(lib, name)
        void *p = dlsym(h, proc);
        if (p != NULL) return p;
    }
    void *r = ame_real_GL_GetProcAddress ? ame_real_GL_GetProcAddress(proc) : NULL;
    if (r == NULL) r = dlsym(RTLD_DEFAULT, proc);
    return r;
}

static bool ame_SDL_GL_SetSwapInterval(int interval) {
    pojavSwapInterval(interval);
    return true;
}

// 上下文由 EGL bridge 持有，生命周期与进程一致。这里不真正销毁，
// 只摘掉引用 —— 否则 SDL 会用 EAGL 的语义去释放一个 EGL 对象而崩溃。
static bool ame_SDL_GL_DestroyContext(void *context) {
    NSDebugLog(@"[SDLHook] SDL_GL_DestroyContext(%p) ignored (owned by EGL bridge)", context);
    if (g_glContext == context) g_glContext = NULL;
    return true;
}

static void *ame_SDL_GL_GetCurrentContext(void) {
    return g_glContext;
}

#pragma mark - 对 main_hook.m 的接入点

/// GL 入口点符号名判定：gl + 大写字母（glGetString / glGetIntegerv / glViewport ...）。
/// 刻意不匹配 C++ mangled 名（_ZN...）与小写开头的内部符号，避免误伤渲染器内嵌的 glslang。
static bool ame_isGlEntryName(const char *name) {
    if (name == NULL) return false;
    if (name[0] != 'g' || name[1] != 'l') return false;
    unsigned char c = (unsigned char)name[2];
    return (c >= 'A' && c <= 'Z');
}

static int ame_glRedirectLogBudget = 12;

// —— GL 入口点重定向：26.2 "no OpenGL context current" 的根因修复 ——
//
// LWJGL 3.4.x 的 MacOSXLibraryDL 以 dlsym(RTLD_DEFAULT, name) 取 GL 入口点
// （Pojav 改过的 GLFW.java:587：new MacOSXLibraryDL(..., RTLD_DEFAULT)）。
// 渲染器以 RTLD_LOCAL 载入时，全局符号表里并不存在它的 gl* 符号，dlsym 于是命中
// iOS 系统 OpenGLES.framework 的桩 —— 该桩不属于我们的 EGL 上下文，
// glGetString(GL_VERSION) 恒返回 NULL、glGetIntegerv(GL_MAJOR_VERSION) 恒返回 -1。
// GL.createCapabilities() 据此判定"无上下文"并抛 IllegalStateException
// （GL.java:456），即 26.2 的崩溃。
//
// 诊断佐证（gl_bridge 探针，26.2 + mobileglues 实测）：
//   dlsym(RTLD_DEFAULT,"glGetString") image=.../OpenGLES.framework/OpenGLES
//   glGetString(GL_VERSION)=(NULL)   glGetIntegerv(GL_MAJOR_VERSION)=-1
// 而同一时刻 eglGetCurrentContext=0x1 —— EGL 层上下文是有的，错在符号解析这一层。
//
// 修法：默认解析结果不可信（系统框架桩或空）时，改从渲染器句柄取同名符号。默认
// 结果可信时一律不干预 —— 对原本正常的渲染器（MobileGL、gl4es、zink 等）行为完全
// 不变，这是本改动的安全边界。
/// 决定 LWJGL 能否探测到上下文的几个入口点。对它们无条件打印来源镜像，
/// 这样即便本次修复没能生效，一次日志也足以看出 26.2 到底解析到了谁的实现
/// （是系统桩、还是渲染器本身 —— 两者的后续修法完全不同）。
static bool ame_isCriticalGlProbe(const char *name) {
    return strcmp(name, "glGetString") == 0 ||
           strcmp(name, "glGetIntegerv") == 0 ||
           strcmp(name, "glGetError") == 0 ||
           strcmp(name, "glGetStringi") == 0;
}

// 是否应当介入本次 GL 入口点查询。
//
// 只介入全局查找 dlsym(RTLD_DEFAULT/NULL, ...)。LWJGL 3.4.x 正是这样取 GL
// 入口点（GLFW.java:587 的 MacOSXLibraryDL 用 RTLD_DEFAULT），这是 26.2
// "no OpenGL context current" 需要纠正的那条路。
//
// 而渲染器自己查自己的 GLES 符号时用的是显式句柄（MobileGlues 的
// proc_address(gles, name) == dlsym(gles_handle, name)）：调用方已明确指定
// 镜像，无需我们纠正。介入它有害 —— 每次查询都会走到 ame_glSymbolTrusted()
// 的 dladdr()，而这段解析发生在渲染器 dylib 的 constructor 期间，此时 dyld
// 正持有加载锁；反复 dladdr 与之争用即死锁，表现为初始化卡死（26.2 +
// mobileglues 黑屏 45s、无声音、无崩溃堆栈）。
static bool ame_shouldMeddleGlEntry(void *handle) {
    return handle == RTLD_DEFAULT || handle == NULL;
}

static int ame_glProbeLogBudget = 16;

static void ame_logGlProbe(const char *name, void *def, void *rh) {
    if (!ame_isCriticalGlProbe(name)) return;
    if (ame_glProbeLogBudget <= 0) return;
    ame_glProbeLogBudget--;

    const char *img = "(unresolved)";
    Dl_info di;
    if (def != NULL && dladdr(def, &di) != 0 && di.dli_fname != NULL) {
        img = di.dli_fname;
    }
    NSDebugLog(@"[SDLHook] GL probe '%s': default=%p trusted=%d image=%s renderer=%p",
               name, def, (int)ame_glSymbolTrusted(def), img, rh);
}

static void *ame_resolveGlEntry(void *handle, const char *name) {
    // glViewport 由调用方上方的分支单独处理（返回包装版本），此处不再介入。
    if (strcmp(name, "glViewport") == 0) return NULL;

    // 显式句柄查询（渲染器自解析）一律放行，理由见 ame_shouldMeddleGlEntry。
    if (!ame_shouldMeddleGlEntry(handle)) return NULL;

    void *def = (amethyst_orig_dlsym != NULL)
                    ? amethyst_orig_dlsym(handle, name)
                    : dlsym(RTLD_DEFAULT, name);

    void *rh = ame_rendererHandle();
    ame_logGlProbe(name, def, rh);

    if (ame_glSymbolTrusted(def)) return NULL;   // 原路径可用，不接管

    if (rh != NULL) {
        void *p = dlsym(rh, name);
        if (ame_glSymbolTrusted(p)) {
            if (ame_glRedirectLogBudget > 0) {
                ame_glRedirectLogBudget--;
                NSDebugLog(@"[SDLHook] GL entry '%s': RTLD_DEFAULT stub rejected, "
                            "using renderer impl %p", name, p);
            }
            return p;
        }
    }
    if (ame_glRedirectLogBudget > 0) {
        ame_glRedirectLogBudget--;
        NSDebugLog(@"[SDLHook] GL entry '%s': no trusted impl (default=%p, renderer=%p)",
                    name, def, rh);
    }
    return NULL;
}

/// 由 hooked_dlsym 在返回 orig_dlsym 之前调用。
/// 返回非 NULL 表示本模块接管了该符号；否则返回 NULL 让调用方走原路径。
void *amethyst_sdl3_hook_resolve(void *handle, const char *name) {
    if (name == NULL) return NULL;
    // 本模块自身解析真实 GL 入口时不接管，否则会把包装版本当成真实实现缓存。
    if (ame_dlsymBypassDepth > 0) return NULL;

    // glViewport 兜底：LWJGL 既可能走 SDL_GL_GetProcAddress（已在那里接管），
    // 也可能直接 dlsym 取 GL 入口。这里双保险，确保两条路都拿到包装版本。
    // 拿不到真实指针时返回 NULL（= 不接管），由调用方回落原始 dlsym 结果。
    if (strcmp(name, "glViewport") == 0) {
        // 构造期（dlopen 中，dyld 持锁）放行显式句柄；上下文创建之后必须接管，
        // 否则 LWJGL 从渲染器句柄直接取走真实实现，每帧把 viewport 设回 points。
        if (!ame_shouldMeddleGlEntry(handle) && !ame_glWrapExplicitHandle)
            return NULL;
        // 只认渲染器镜像里的实现。绝不回退 RTLD_DEFAULT：渲染器是 RTLD_LOCAL，
        // 全局表里那一份属于系统 OpenGLES 框架，拿它纠正 viewport 无效且会崩。
        if (ame_real_glViewport == NULL ||
            !ame_glSymbolTrusted((const void *)ame_real_glViewport)) {
            ame_real_glViewport = NULL;
            void *rh = ame_rendererHandle();
            if (rh != NULL) {
                void *p = NULL;
                ame_dlsymBypassDepth++;
                p = dlsym(rh, name);
                ame_dlsymBypassDepth--;
                if (ame_glSymbolTrusted(p))
                    ame_real_glViewport = (ame_fn_glViewport)p;
            }
        }
        // 拿不到可信实现就不接管：宁可让 MC 用它原本会拿到的指针，
        // 也不包装一份一调用就崩的桩。
        if (ame_real_glViewport != NULL) return (void *)ame_glViewport;
        return NULL;
    }
    if (strcmp(name, "glScissor") == 0) {
        // 与上方 glViewport 分支同理：渲染器用显式句柄自解析时必须放行。
        // 少了这道判定，MobileGlues 在 constructor 里 dlsym(gles_handle,
        // "glScissor") 会被接管并走进 ame_glSymbolTrusted() 的 dladdr()，
        // 与 dyld 加载锁争用死锁（26.2 + mobileglues 卡死 45s、黑屏无声音）。
        if (!ame_shouldMeddleGlEntry(handle) && !ame_glWrapExplicitHandle)
            return NULL;
        if (ame_real_glScissor == NULL ||
            !ame_glSymbolTrusted((const void *)ame_real_glScissor)) {
            ame_real_glScissor = NULL;
            void *rh = ame_rendererHandle();
            if (rh != NULL) {
                void *p = NULL;
                ame_dlsymBypassDepth++;
                p = dlsym(rh, name);
                ame_dlsymBypassDepth--;
                if (ame_glSymbolTrusted(p)) ame_real_glScissor = (ame_fn_glScissor)p;
            }
        }
        if (ame_real_glScissor != NULL) return (void *)ame_glScissor;
        return NULL;
    }

    // LWJGL 3.4.x 取 GL 入口点时命中系统 OpenGLES 桩，导致 26.2 判定"无上下文"
    // （详见 ame_resolveGlEntry 处注释）。仅在原路径不可用时才接管。
    if (ame_isGlEntryName(name)) {
        void *glsym = ame_resolveGlEntry(handle, name);
        if (glsym != NULL) return glsym;
        // 拿不到可信实现则不接管，交由调用方回落原始 dlsym 结果。
        return NULL;
    }

    // 先记下真实指针（无论本次是否接管，后续包装都要用到）
    if (strcmp(name, "SDL_CreateWindow") == 0) {
        if (ame_real_CreateWindow == NULL) {
            ame_real_CreateWindow = (ame_fn_SDL_CreateWindow)amethyst_orig_dlsym(handle, name);
        }
        NSDebugLog(@"[SDLHook] hooked SDL_CreateWindow (real=%p)", (void *)ame_real_CreateWindow);
        return (void *)ame_SDL_CreateWindow;
    }
    if (strcmp(name, "SDL_CreateWindowWithProperties") == 0) {
        if (ame_real_CreateWindowWithProperties == NULL) {
            ame_real_CreateWindowWithProperties =
                (ame_fn_SDL_CreateWindowWithProperties)amethyst_orig_dlsym(handle, name);
        }
        NSDebugLog(@"[SDLHook] hooked SDL_CreateWindowWithProperties (real=%p)",
                   (void *)ame_real_CreateWindowWithProperties);
        return (void *)ame_SDL_CreateWindowWithProperties;
    }
    if (strcmp(name, "SDL_DestroyWindow") == 0) {
        if (ame_real_DestroyWindow == NULL) {
            ame_real_DestroyWindow = (ame_fn_SDL_DestroyWindow)amethyst_orig_dlsym(handle, name);
        }
        return (void *)ame_SDL_DestroyWindow;
    }
    if (strcmp(name, "SDL_LoadFunction") == 0) {
        if (ame_real_LoadFunction == NULL) {
            ame_real_LoadFunction = (ame_fn_SDL_LoadFunction)amethyst_orig_dlsym(handle, name);
        }
        return (void *)ame_SDL_LoadFunction;
    }
    if (strcmp(name, "SDL_EGL_GetProcAddress") == 0) {
        if (ame_real_EGL_GetProcAddress == NULL) {
            ame_real_EGL_GetProcAddress =
                (ame_fn_SDL_EGL_GetProcAddress)amethyst_orig_dlsym(handle, name);
        }
        return (void *)ame_SDL_EGL_GetProcAddress;
    }
    if (strcmp(name, "SDL_LoadObject") == 0) {
        if (ame_real_LoadObject == NULL) {
            ame_real_LoadObject = (ame_fn_SDL_LoadObject)amethyst_orig_dlsym(handle, name);
        }
        return (void *)ame_SDL_LoadObject;
    }
    if (strcmp(name, "SDL_UnloadObject") == 0) {
        if (ame_real_UnloadObject == NULL) {
            ame_real_UnloadObject = (ame_fn_SDL_UnloadObject)amethyst_orig_dlsym(handle, name);
        }
        return (void *)ame_SDL_UnloadObject;
    }
    // 窗口尺寸(points 语义)：同样无条件接管。GLFW 路径下窗口尺寸与
    // framebuffer 尺寸恒等，这里回报同一个值以对齐该语义（见函数处注释）。
    if (strcmp(name, "SDL_GetWindowSize") == 0) {
        if (ame_real_GetWindowSize == NULL) {
            ame_real_GetWindowSize =
                (ame_fn_SDL_GetWindowSize)amethyst_orig_dlsym(handle, name);
        }
        NSDebugLog(@"[SDLHook] hooked SDL_GetWindowSize -> EGL surface size");
        return (void *)ame_SDL_GetWindowSize;
    }
    // 尺寸查询：与 GL 后端无关，无条件接管（见函数处注释）
    if (strcmp(name, "SDL_GetWindowSizeInPixels") == 0) {
        if (ame_real_GetWindowSizeInPixels == NULL) {
            ame_real_GetWindowSizeInPixels =
                (ame_fn_SDL_GetWindowSizeInPixels)amethyst_orig_dlsym(handle, name);
        }
        NSDebugLog(@"[SDLHook] hooked SDL_GetWindowSizeInPixels -> EGL surface size");
        return (void *)ame_SDL_GetWindowSizeInPixels;
    }
    // Task 50 移植：剥离 SDL_WINDOW_MINIMIZED(0x40)。
    // embed 必然隐藏 SDL 自有 UIWindow，UIKit 后端随即把该窗口标为 minimized；
    // renderpearl 的 GlSurface.acquireNextTexture 查到 MINIMIZED 就抛
    // "Cannot acquire minimized window" 并跳过整帧 → 黑屏。谎报"未最小化"
    // 对画面/输入无副作用（真正的呈现面是宿主 CAMetalLayer）。
    if (strcmp(name, "SDL_GetWindowFlags") == 0) {
        if (ame_real_GetWindowFlags == NULL) {
            ame_real_GetWindowFlags =
                (ame_fn_SDL_GetWindowFlags)amethyst_orig_dlsym(handle, name);
        }
        NSDebugLog(@"[SDLHook] hooked SDL_GetWindowFlags -> strip MINIMIZED(0x40)");
        return (void *)ame_SDL_GetWindowFlags;
    }
    // Air Task 32 移植：SDL_ShowWindow 无条件接管。
    // 嵌入后必须阻止 SDL 自有 UIWindow 变成 key+visible（空窗黑盖子 = 黑屏）。
    if (strcmp(name, "SDL_ShowWindow") == 0) {
        if (ame_real_ShowWindow == NULL) {
            ame_real_ShowWindow =
                (ame_fn_SDL_ShowWindow)amethyst_orig_dlsym(handle, name);
        }
        NSDebugLog(@"[SDLHook] hooked SDL_ShowWindow -> enforce SDL3 presentation "
                   @"invariants (hide SDL's own UIWindow)");
        return (void *)ame_SDL_ShowWindow;
    }
    // Air Task 32/51/67 移植：窗口生命周期钩子安装。
    // SDL_SetWindowSize / SDL_SetWindowPosition 的钳制是「必须手动改一次分辨率
    // 才恢复」与「画面缩在角落」的根治点（Task51 Fix E，注释见函数处）。
    if (strcmp(name, "SDL_SetWindowSize") == 0) {
        if (ame_real_SetWindowSize == NULL) {
            ame_real_SetWindowSize =
                (ame_fn_SDL_SetWindowSize)amethyst_orig_dlsym(handle, name);
        }
        NSDebugLog(@"[SDLHook] hooked SDL_SetWindowSize -> Task51 pixel->point clamp");
        return (void *)ame_SDL_SetWindowSize;
    }
    if (strcmp(name, "SDL_SetWindowPosition") == 0) {
        if (ame_real_SetWindowPosition == NULL) {
            ame_real_SetWindowPosition =
                (ame_fn_SDL_SetWindowPosition)amethyst_orig_dlsym(handle, name);
        }
        NSDebugLog(@"[SDLHook] hooked SDL_SetWindowPosition -> Task51 negative-offset clamp");
        return (void *)ame_SDL_SetWindowPosition;
    }
    if (strcmp(name, "SDL_HideWindow") == 0) {
        if (ame_real_HideWindow == NULL) {
            ame_real_HideWindow =
                (ame_fn_SDL_HideWindow)amethyst_orig_dlsym(handle, name);
        }
        NSDebugLog(@"[SDLHook] hooked SDL_HideWindow");
        return (void *)ame_SDL_HideWindow;
    }
    if (strcmp(name, "SDL_SetWindowFullscreen") == 0) {
        if (ame_real_SetWindowFullscreen == NULL) {
            ame_real_SetWindowFullscreen =
                (ame_fn_SDL_SetWindowFullscreen)amethyst_orig_dlsym(handle, name);
        }
        NSDebugLog(@"[SDLHook] hooked SDL_SetWindowFullscreen");
        return (void *)ame_SDL_SetWindowFullscreen;
    }
    if (strcmp(name, "SDL_GetKeyboardState") == 0) {
        if (ame_real_GetKeyboardState == NULL) {
            ame_real_GetKeyboardState =
                (ame_fn_SDL_GetKeyboardState)amethyst_orig_dlsym(handle, name);
        }
        NSDebugLog(@"[SDLHook] hooked SDL_GetKeyboardState");
        return (void *)ame_SDL_GetKeyboardState;
    }
    // SDL_GL_SetAttribute 不接管：MC 自己调用它设属性是合法行为，我们只在
    // 建窗前主动调用同一个函数来强制 ES profile（见 ame_forceEglProfileEs）。
    // SDL GL 上下文接管（MobileGL / Mithril / MobileGlues / gl4es / LTW）
    if (ame_glBridgeEnabled()) {
        if (strcmp(name, "SDL_GL_LoadLibrary") == 0) {
            if (ame_real_GL_LoadLibrary == NULL)
                ame_real_GL_LoadLibrary = (ame_fn_SDL_GL_LoadLibrary)amethyst_orig_dlsym(handle, name);
            NSDebugLog(@"[SDLHook] hooked SDL_GL_LoadLibrary -> EGL bridge");
            return (void *)ame_SDL_GL_LoadLibrary;
        }
        if (strcmp(name, "SDL_GL_CreateContext") == 0) {
            if (ame_real_GL_CreateContext == NULL)
                ame_real_GL_CreateContext = (ame_fn_SDL_GL_CreateContext)amethyst_orig_dlsym(handle, name);
            NSDebugLog(@"[SDLHook] hooked SDL_GL_CreateContext -> EGL bridge");
            return (void *)ame_SDL_GL_CreateContext;
        }
        if (strcmp(name, "SDL_GL_MakeCurrent") == 0) {
            if (ame_real_GL_MakeCurrent == NULL)
                ame_real_GL_MakeCurrent = (ame_fn_SDL_GL_MakeCurrent)amethyst_orig_dlsym(handle, name);
            NSDebugLog(@"[SDLHook] hooked SDL_GL_MakeCurrent -> EGL bridge");
            return (void *)ame_SDL_GL_MakeCurrent;
        }
        if (strcmp(name, "SDL_GL_SwapWindow") == 0) {
            if (ame_real_GL_SwapWindow == NULL)
                ame_real_GL_SwapWindow = (ame_fn_SDL_GL_SwapWindow)amethyst_orig_dlsym(handle, name);
            NSDebugLog(@"[SDLHook] hooked SDL_GL_SwapWindow -> EGL bridge");
            return (void *)ame_SDL_GL_SwapWindow;
        }
        if (strcmp(name, "SDL_GL_GetProcAddress") == 0) {
            if (ame_real_GL_GetProcAddress == NULL)
                ame_real_GL_GetProcAddress = (ame_fn_SDL_GL_GetProcAddress)amethyst_orig_dlsym(handle, name);
            NSDebugLog(@"[SDLHook] hooked SDL_GL_GetProcAddress -> renderer dlsym");
            return (void *)ame_SDL_GL_GetProcAddress;
        }
        if (strcmp(name, "SDL_GL_SetSwapInterval") == 0) {
            if (ame_real_GL_SetSwapInterval == NULL)
                ame_real_GL_SetSwapInterval = (ame_fn_SDL_GL_SetSwapInterval)amethyst_orig_dlsym(handle, name);
            NSDebugLog(@"[SDLHook] hooked SDL_GL_SetSwapInterval -> EGL bridge");
            return (void *)ame_SDL_GL_SetSwapInterval;
        }
        if (strcmp(name, "SDL_GL_DestroyContext") == 0) {
            if (ame_real_GL_DestroyContext == NULL)
                ame_real_GL_DestroyContext = (ame_fn_SDL_GL_DestroyContext)amethyst_orig_dlsym(handle, name);
            return (void *)ame_SDL_GL_DestroyContext;
        }
        if (strcmp(name, "SDL_GL_GetCurrentContext") == 0) {
            if (ame_real_GL_GetCurrentContext == NULL)
                ame_real_GL_GetCurrentContext = (ame_fn_SDL_GL_GetCurrentContext)amethyst_orig_dlsym(handle, name);
            return (void *)ame_SDL_GL_GetCurrentContext;
        }
        if (strcmp(name, "SDL_GL_GetDrawableSize") == 0) {
            if (ame_real_GL_GetDrawableSize == NULL)
                ame_real_GL_GetDrawableSize = (ame_fn_SDL_GL_GetDrawableSize)amethyst_orig_dlsym(handle, name);
            NSDebugLog(@"[SDLHook] hooked SDL_GL_GetDrawableSize -> EGL surface size");
            return (void *)ame_SDL_GL_GetDrawableSize;
        }
        if (strcmp(name, "SDL_GetCurrentDisplayMode") == 0) {
            if (ame_real_GetCurrentDisplayMode == NULL)
                ame_real_GetCurrentDisplayMode = (ame_fn_GetCurrentDisplayMode)amethyst_orig_dlsym(handle, name);
            NSDebugLog(@"[SDLHook] hooked SDL_GetCurrentDisplayMode -> EGL pixels");
            return (void *)ame_SDL_GetCurrentDisplayMode;
        }
        if (strcmp(name, "SDL_GetDesktopDisplayMode") == 0) {
            if (ame_real_GetDesktopDisplayMode == NULL)
                ame_real_GetDesktopDisplayMode = (ame_fn_GetDesktopDisplayMode)amethyst_orig_dlsym(handle, name);
            NSDebugLog(@"[SDLHook] hooked SDL_GetDesktopDisplayMode -> EGL pixels");
            return (void *)ame_SDL_GetDesktopDisplayMode;
        }
        if (strcmp(name, "SDL_GetClosestFullscreenDisplayMode") == 0) {
            if (ame_real_GetClosestFullscreenDisplayMode == NULL)
                ame_real_GetClosestFullscreenDisplayMode = (ame_fn_GetClosestFullscreenDisplayMode)amethyst_orig_dlsym(handle, name);
            NSDebugLog(@"[SDLHook] hooked SDL_GetClosestFullscreenDisplayMode -> EGL pixels");
            return (void *)ame_SDL_GetClosestFullscreenDisplayMode;
        }
                            }

    // 【对齐 Air（Task61 定案）：不再接管像素密度】
    // Air 的 sdl3_hook.m 对 SDL_GetWindowDisplayScale / SDL_GetDisplayContentScale /
    // SDL_GetWindowPixelDensity **一个都不 hook**（全文零命中）。本文件旧版把三者
    // 全部强制回报 1.0，于是：
    //   * MC 26.3 由「像素 / 密度」反推点空间 -> 2436/1.0 = 2436，
    //     而 SDL 真实点空间是 812x375（UIKit 触摸坐标也在这个空间）；
    //   * 输入坐标与窗口点空间差 3 倍 -> 点击落点整体偏移，热键栏（屏幕
    //     底部中央）永远点不中；分辨率调到 25% 时点空间变成 609，偏差更大。
    // Air 保持密度原生（iPhone X = 3.0 / iPad = 2.0），MC 反推
    // 2436/3.0 = 812 == 真实点空间，输入与渲染各自归一，故无此问题。
    // 这里完全移除三个接管，交还 SDL 原生实现，与参考仓库逐字一致。
    // —— 以下与渲染后端无关，无条件接管 ——
    // GLFW 老路径不加载 libSDL3，根本不会查询这些符号，因此不受影响。
    // 窗口尺寸事件出口统一：SDL 内部状态停在 points(812x375)，它自行派发的
    // WINDOW_RESIZED 会把这个错误值交给 MC，必须在此改写为 EGL surface 像素。
    if (strcmp(name, "SDL_PollEvent") == 0) {
        if (ame_real_PollEvent == NULL)
            ame_real_PollEvent =
                (ame_fn_SDL_PollEvent)amethyst_orig_dlsym(handle, name);
        NSDebugLog(@"[SDLHook] hooked SDL_PollEvent -> window size in EGL pixels");
        return (void *)ame_SDL_PollEvent;
    }
    if (strcmp(name, "SDL_WaitEvent") == 0) {
        if (ame_real_WaitEvent == NULL)
            ame_real_WaitEvent =
                (ame_fn_SDL_PollEvent)amethyst_orig_dlsym(handle, name);
        NSDebugLog(@"[SDLHook] hooked SDL_WaitEvent -> window size in EGL pixels");
        return (void *)ame_SDL_WaitEvent;
    }
    if (strcmp(name, "SDL_WaitEventTimeout") == 0) {
        if (ame_real_WaitEventTimeout == NULL)
            ame_real_WaitEventTimeout =
                (ame_fn_SDL_WaitEventTimeout)amethyst_orig_dlsym(handle, name);
        NSDebugLog(@"[SDLHook] hooked SDL_WaitEventTimeout -> window size in EGL pixels");
        return (void *)ame_SDL_WaitEventTimeout;
    }
    if (strcmp(name, "SDL_PeepEvents") == 0) {
        if (ame_real_PeepEvents == NULL)
            ame_real_PeepEvents =
                (ame_fn_SDL_PeepEvents)amethyst_orig_dlsym(handle, name);
        NSDebugLog(@"[SDLHook] hooked SDL_PeepEvents -> window size in EGL pixels");
        return (void *)ame_SDL_PeepEvents;
    }
    if (strcmp(name, "SDL_WaitEventTimeoutNS") == 0) {
        if (ame_real_WaitEventTimeoutNS == NULL)
            ame_real_WaitEventTimeoutNS =
                (ame_fn_SDL_WaitEventTimeoutNS)amethyst_orig_dlsym(handle, name);
        NSDebugLog(@"[SDLHook] hooked SDL_WaitEventTimeoutNS -> window size in EGL pixels");
        return (void *)ame_SDL_WaitEventTimeoutNS;
    }
    if (strcmp(name, "SDL_GetWindowFromEvent") == 0) {
        if (ame_real_GetWindowFromEvent == NULL)
            ame_real_GetWindowFromEvent =
                (ame_fn_SDL_GetWindowFromEvent)amethyst_orig_dlsym(handle, name);
        NSDebugLog(@"[SDLHook] hooked SDL_GetWindowFromEvent -> last-window fallback");
        return (void *)ame_SDL_GetWindowFromEvent;
    }
    if (strcmp(name, "SDL_GetWindowFromID") == 0) {
        if (ame_real_GetWindowFromID == NULL)
            ame_real_GetWindowFromID =
                (ame_fn_SDL_GetWindowFromID)amethyst_orig_dlsym(handle, name);
        NSDebugLog(@"[SDLHook] hooked SDL_GetWindowFromID -> last-window fallback");
        return (void *)ame_SDL_GetWindowFromID;
    }
    if (strcmp(name, "SDL_StartTextInput") == 0) {
        if (ame_real_StartTextInput == NULL)
            ame_real_StartTextInput =
                (ame_fn_SDL_StartTextInput)amethyst_orig_dlsym(handle, name);
        NSDebugLog(@"[SDLHook] hooked SDL_StartTextInput -> main thread");
        return (void *)ame_SDL_StartTextInput;
    }
    if (strcmp(name, "SDL_StartTextInputWithProperties") == 0) {
        if (ame_real_StartTextInputWithProperties == NULL)
            ame_real_StartTextInputWithProperties =
                (ame_fn_SDL_StartTextInputWithProperties)amethyst_orig_dlsym(handle, name);
        NSDebugLog(@"[SDLHook] hooked SDL_StartTextInputWithProperties -> main thread");
        return (void *)ame_SDL_StartTextInputWithProperties;
    }
    if (strcmp(name, "SDL_StopTextInput") == 0) {
        if (ame_real_StopTextInput == NULL)
            ame_real_StopTextInput =
                (ame_fn_SDL_StopTextInput)amethyst_orig_dlsym(handle, name);
        NSDebugLog(@"[SDLHook] hooked SDL_StopTextInput -> main thread");
        return (void *)ame_SDL_StopTextInput;
    }
    if (strcmp(name, "SDL_SetTextInputArea") == 0) {
        if (ame_real_SetTextInputArea == NULL)
            ame_real_SetTextInputArea =
                (ame_fn_SDL_SetTextInputArea)amethyst_orig_dlsym(handle, name);
        NSDebugLog(@"[SDLHook] hooked SDL_SetTextInputArea -> main thread");
        return (void *)ame_SDL_SetTextInputArea;
    }
    if (strcmp(name, "SDL_InitSubSystem") == 0) {
        if (ame_real_InitSubSystem == NULL)
            ame_real_InitSubSystem =
                (ame_fn_SDL_InitSubSystem)amethyst_orig_dlsym(handle, name);
        NSDebugLog(@"[SDLHook] hooked SDL_InitSubSystem -> launcher hints");
        return (void *)ame_SDL_InitSubSystem;
    }

    return NULL;
}

#pragma mark - 供 EGL bridge 查询的上下文语义

/// SDL3 路径下，建窗前是否已把 GL profile 强制为 ES（ZL2 的 forceEglProfileEs
/// 在 iOS 上的等价物，见本文件 1)）。
///
/// 仅当本模块接管了 SDL GL 入口（即走 EGL bridge 的转译型渲染器）时才可能为
/// true；GLFW 老路径（MC 26.2 及以下）根本不经过这里，恒为 false，因此
/// MobileGL 在老路径上仍走已验证可用的 desktop GL 3.3 Core 上下文。
bool amethyst_sdl3_wants_gles_context(void) {
    return ame_sdl3WantsGles && ame_glBridgeEnabled();
}

// Air Task52 对齐：向 gl_bridge.m 暴露嵌入的 SDL 视图（同一性比较用，
// 不得解引用为 ARC 对象持有）。
void *ame_hook_getEmbeddedSDLView(void) {
    return (__bridge void *)ame_embeddedSDLView;
}
