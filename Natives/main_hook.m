#import <Foundation/Foundation.h>
#import "PLLogOutputView.h"
#import "SurfaceViewController.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "mach_excServer.h"

#include <dlfcn.h>
#include <execinfo.h>
#include <fcntl.h>
#include <libgen.h>
// ★ [SHADER-SIGBUS] 崩溃归属取证需要：task_threads/thread_get_state/ARM_THREAD_STATE64
// （取各线程 PC 做 dladdr 归属）与 uintptr_t/uint64_t。
#include <mach/mach.h>
#include <stdint.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "external/fishhook/fishhook.h"

// 硬件断点异常端口（同步自上游，用于非 TXM 的 iOS 26+ 设备 dlopen 重定向）
mach_port_t excPort;
void *hooked_dlopen_26_ppl(const char *path, int mode);

void (*orig_abort)();
void (*orig_exit)(int code);
void* (*orig_dlopen)(const char* path, int mode);
void* (*orig_dlsym)(void* handle, const char* name);

// ★ [SHADER-SIGBUS] ==========================================================
// 崩溃归属取证（native 侧）—— 让下一次真机日志直接给出答案，不用再猜。
//
// 背景：glslang 那一类崩溃是「dlopen 期静态初始化 SIGBUS → JVM os::abort →
// 被 hooked_abort 接管」。此时：
//   · hooked_abort 拿到的回溯是 *abort 自己的* 栈（信号处理上下文的帧指针链
//     在 sigtramp 处断开，真正的故障帧不在链上）⇒ 回溯里的 dylib 是 libjvm，
//     不是元凶；
//   · latestlog 里的 "35s THREAD DUMP" 只有标题、没有线程栈
//     ⇒「卡在哪个线程 / 归属哪个 dylib / 偏移多少」这份日志答不了。
// 本块补上三件事（全部只读旁路，不改变任何既有行为）：
//   ① 记录最后一个 dlopen/System.load 的目标路径
//      —— dlopen 期崩溃的元凶就是这个镜像（真机上就是被解包到 home 的那份）；
//   ② 记录 abort 线程的 名字 + 数值 id（与 JVM hs_err 的 tid 对齐）；
//   ③ 遍历所有线程取 PC/FP，用 dladdr 归属成「dylib + 偏移 + 符号」，并标注
//      该地址是否落在 JIT26 已 PrepareRegion 的匿名区（区分"JIT 区"与"真镜像"）。
// 全部 malloc-free（只用 mach 调用 + dladdr + snprintf），与既有的
// ame_write_fatal_trace 同一套纪律（heap 损坏场景下仍要能落盘）。
// ============================================================================

#define AME_DLOPEN_PATH_MAX 1024
// 仅由 hooked_dlopen / hooked_dlopen_26_ppl 在分发前写入（单写多读，长度有限）。
static char g_ame_lastDlopenPath[AME_DLOPEN_PATH_MAX];
static volatile sig_atomic_t g_ame_lastDlopenSet = 0;

void ame_record_dlopen_target(const char *path) {
    if (path == NULL) return;
    size_t n = strlen(path);
    if (n >= AME_DLOPEN_PATH_MAX) n = AME_DLOPEN_PATH_MAX - 1;
    memcpy(g_ame_lastDlopenPath, path, n);
    g_ame_lastDlopenPath[n] = '\0';
    g_ame_lastDlopenSet = 1;
}

static const char *ame_short_image_name(const char *full) {
    if (full == NULL) return "(?)";
    const char *s = strrchr(full, '/');
    return s ? s + 1 : full;
}

// 所有线程的 PC 快照 → 「归属 dylib + 偏移 + 符号」+ JIT 区标注。
// 返回写入字节数；任何一步失败都只是少几行，不抛不崩。
static size_t ame_snapshot_all_threads(char *out, size_t cap) {
    if (out == NULL || cap < 256) return 0;
    size_t len = 0;
#if defined(__arm64__) || defined(__aarch64__)
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS || threads == NULL) {
        return (size_t)snprintf(out, cap, "  (task_threads failed -- no thread snapshot)\n");
    }
    unsigned shown = 0;
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        if (shown >= 48 || len + 256 >= cap) break;
        arm_thread_state64_t st;
        mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
        memset(&st, 0, sizeof(st));
        if (thread_get_state(threads[i], ARM_THREAD_STATE64,
                             (thread_state_t)&st, &sc) != KERN_SUCCESS) {
            continue;
        }
        uint64_t pc = (uint64_t)arm_thread_state64_get_pc(st);
        uint64_t lr = (uint64_t)arm_thread_state64_get_lr(st);
        uint64_t tid = 0;
        char tname[64] = {0};
        pthread_t pt = pthread_from_mach_thread_np(threads[i]);
        if (pt != NULL) {
            pthread_threadid_np(pt, &tid);
            pthread_getname_np(pt, tname, sizeof(tname));
        }
        Dl_info info;
        memset(&info, 0, sizeof(info));
        int ok = (pc != 0) ? dladdr((void *)(uintptr_t)pc, &info) : 0;
        unsigned long long off = ok ? (unsigned long long)(pc - (uintptr_t)info.dli_fbase) : 0;
        len += (size_t)snprintf(out + len, cap - len,
            "  thread[%02u] id=%-10llu name=%-22s pc=%s+0x%llx sym=%s %s lr=0x%llx\n",
            shown, (unsigned long long)tid,
            tname[0] ? tname : "(unnamed)",
            ok ? ame_short_image_name(info.dli_fname) : "(unknown-image)",
            off,
            (ok && info.dli_sname) ? info.dli_sname : "?",
            JIT26AddressInPreparedRegion((const void *)(uintptr_t)pc) ? "[JIT-REGION]" : "",
            (unsigned long long)lr);
        shown++;
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads,
                  (vm_size_t)(count * sizeof(thread_t)));
#else
    len += (size_t)snprintf(out, cap, "  (thread PC snapshot unsupported on this arch)\n");
#endif
    return len;
}

// Task 144：headless JVM（Forge/NeoForge 直装的 processors）执行期 exit 抑制。
// 病历（装机 latestlog 20:42 会话，9aa15c8 构建）：Forge 处理器全部跑完、
// 进度 0.85 时，安装器 JVM 的 libjli 内部线程调用 exit(0) 结束自身 ——
// 但 JVM 与启动器同进程，整个 app 被带走（用户视角"forge安装闪退"，
// modpack 安装在 85% 处中断）。ForgeProcessorExecutor 在 launchHeadlessJVM
// 前后置位/清零本标志；hooked_exit 命中标志时改为 pthread_exit 仅终结
// 调用线程（JVM 自身线程），ObjC 侧继续读 status.json 判定成败。
// 游戏正常退出路径（标志未置位）不受影响。
atomic_int g_ame_suppressJvmExit = 0;
// Task 146：headless JVM 终结信号（语义与置位点见 JavaLauncher.h 注释）。
atomic_int g_ame_headlessJvmFinished = 0;

// MARK: - SDL3 grab 状态同步（MC 26.3）
//
// input_bridge_v3.m 提供统一的抓取状态同步入口。MC 26.3 改用 SDL3 后不再
// 调用 glfwSetInputMode，Amethyst 原先只能靠触摸事件轮询 SDL 的 relative
// mouse mode 来同步 isGrabbing，而这条链路实测失效（日志中 isGrabbing 恒为 0），
// 导致游戏内物品栏点不动。这里改为直接拦截 MC 的设置调用。
extern void CallbackBridge_syncGrabStateFromSDL(BOOL relMode, const char *source);

// MARK: - SDL3 兼容层（移植自 ZalithLauncher2）
//
// Android 端 ZL2 用 bytehook 注入 libSDL3.so；iOS 上没有 bytehook，等价位置
// 就是本文件的 hooked_dlsym —— LWJGL 通过 dlsym 取指针后直接调用，必须在
// dlsym 层拦截。返回非 NULL 表示该符号被兼容层接管。
extern void *amethyst_sdl3_hook_resolve(void *handle, const char *name);

// Task 132：hooked_dlopen 的 libjnidispatch _dlsym 槽位重绑定需要
// hooked_dlsym 的地址；其定义在本文件后部（JVM hook 区），此处前向声明
// （CI 35512461717 教训：415 行引用点先于定义点，缺声明即 undeclared）。
void *hooked_dlsym(void *handle, const char *name);

// Task 133：JVM 侧 dlopen 链重绑定（sdl3_hook.m）——libjli/libjvm 的
// _dlopen 槽改绑到 hooked_dlopen（此后 JVM 的一切 System.load 都可见），
// libjnidispatch（含 jna*.tmp 解包形态，按 install name 识别）的 _dlsym
// 槽改绑到 hooked_dlsym（Task131 守卫对 JNA 路径生效）。由本文件的
// hooked_dlopen（JVM/JNA 相关路径加载后）与 hooked_dlsym（入口）驱动。
void amethyst_task133_ensure_jvm_chain(void);

// Task 132/133 构建修复桩：b9b31590b 只移植了调用点与注释，
// amethyst_task132_rebind_jna_dlsym 与 amethyst_task133_ensure_jvm_chain
// 的真实实现从未进仓库（sdl3_hook.m 内无此二函数），导致 C99 隐式声明
// error 整停 native 编译。此处以 no-op 桩恢复构建，行为等同此前所有
// 成功构建（重绑定从未执行过）；hooked_dlsym 热路径调用的 133 桩保持
// 零开销（不打日志，避免高频刷屏）。
// TODO(port): 从 Air-Minecraft-iOS-Launcher 的 sdl3_hook.m 移植二者完整
// 实现时，删除下方桩函数（留声明），否则链接期 duplicate symbol。
void amethyst_task132_rebind_jna_dlsym(void *handle, void *hook) {
    (void)handle; (void)hook;
    NSLog(@"[Task132] stub: JNA dlsym rebind not yet ported, skipping");
}

void amethyst_task133_ensure_jvm_chain(void) {
    // no-op 桩，见上方说明。
}

static bool (*g_real_SDL_SetWindowRelativeMouseMode)(void *window, bool enabled) = NULL;

static bool amethyst_SDL_SetWindowRelativeMouseMode(void *window, bool enabled) {
    // 先让 Amethyst 侧同步（isGrabbing / guiScale / 光标显隐），再交给真正的 SDL。
    // 包装内部已有"状态未变化则跳过"的判断，重复调用无副作用。
    CallbackBridge_syncGrabStateFromSDL(enabled ? YES : NO, "SetWindowRelativeMouseMode");
    if (g_real_SDL_SetWindowRelativeMouseMode) {
        return g_real_SDL_SetWindowRelativeMouseMode(window, enabled);
    }
    return false;
}

// SDL3 有两套鼠标抓取 API，语义相近但入口不同：
//   SDL_SetWindowRelativeMouseMode —— 相对模式（指针锁定，FPS 游戏视角控制）
//   SDL_SetWindowMouseGrab         —— 窗口抓取（指针限制在窗口内）
// 原先只拦了前者。若 MC 走的是后者，就完全拦不到，isGrabbing 会一直保持 0。
// 两个都拦：同步函数内部有"状态未变化则跳过"的判断，重复调用无副作用。
static bool (*g_real_SDL_SetWindowMouseGrab)(void *window, bool grabbed) = NULL;

static bool amethyst_SDL_SetWindowMouseGrab(void *window, bool grabbed) {
    CallbackBridge_syncGrabStateFromSDL(grabbed ? YES : NO, "SetWindowMouseGrab");
    if (g_real_SDL_SetWindowMouseGrab) {
        return g_real_SDL_SetWindowMouseGrab(window, grabbed);
    }
    return false;
}

// --- SDL3 OpenGL 库装载兼容 ---
//
// MC 26.3 (RenderPearl) 在 GlBackend.loadLibrary() 中调用 SDL_GL_LoadLibrary()
// 自行装载 OpenGL 库。但启动器为了让 LWJGL 拿得到 GL 入口，会通过
// -Dorg.lwjgl.opengl.libname=<renderer> 让 LWJGL 在 JVM 启动阶段就 dlopen 了
// 渲染器（见 JavaLauncher.m：NativeLibrariesBootstrap.loadOpenGL() 会无条件
// 初始化 org.lwjgl.opengl.GL）。
//
// SDL3 语义：已有驱动装载且请求的 path 与之不同 -> 报错
// "OpenGL library already loaded"。于是 MC 判定 OpenGL 不可用，回落到原生
// Vulkan（MoltenVK），MobileGL / MobileGlues 这类 GL 转译渲染器完全失效，
// 最终撞上 RenderPearl 的 shaderc/glslang 路径而崩溃。
//
// Task 79 注：本包装器现在只是【兜底】——sdl3_hook.m 的 EGL bridge
// （ame_glBridgeEnabled，Task 79 起 zink 也包含在内）在 hooked_dlsym 里
// 优先接管 SDL_GL_LoadLibrary，真实 SDL 从不被调用。仅当 bridge 被禁用
// （AMETHYST_SDL_GL_BRIDGE=0 / AMETHYST_ZINK_GL_BRIDGE=0 诊断模式）时，
// MC 才会落到这里，走"真实 SDL 拒载 + 兑装成功"的旧路径。
//
// 该错误其实意味着"库已装载且正是我们选中的渲染器"，故视为成功；
// 其它错误（找不到库等）仍如实返回失败。
typedef bool (*PFN_SDL_GL_LoadLibrary)(const char *path);
typedef const char *(*PFN_SDL_GetError)(void);
typedef bool (*PFN_SDL_GL_SetAttribute)(int attr, int value);

static PFN_SDL_GL_LoadLibrary g_real_SDL_GL_LoadLibrary = NULL;
static PFN_SDL_GetError g_real_SDL_GetError = NULL;
static PFN_SDL_GL_SetAttribute g_real_SDL_GL_SetAttribute = NULL;

// SDL3 SDL_GLattr 中几个与上下文选择相关的取值（序号对齐 SDL3.4 头文件）
#define AME_SDL_GL_CONTEXT_MAJOR_VERSION 17
#define AME_SDL_GL_CONTEXT_MINOR_VERSION 18
#define AME_SDL_GL_CONTEXT_PROFILE_MASK  20

static const char *ame_gl_attr_name(int attr) {
    switch (attr) {
        case AME_SDL_GL_CONTEXT_MAJOR_VERSION: return "CONTEXT_MAJOR_VERSION";
        case AME_SDL_GL_CONTEXT_MINOR_VERSION: return "CONTEXT_MINOR_VERSION";
        case AME_SDL_GL_CONTEXT_PROFILE_MASK:  return "CONTEXT_PROFILE_MASK";
        default:                               return "other";
    }
}

// 仅记录 MC 请求的上下文属性，用于判断它走的是桌面 GL 还是 ES
static bool amethyst_SDL_GL_SetAttribute(int attr, int value) {
    NSLog(@"[SDLGL] SDL_GL_SetAttribute(%s=%d, value=%d)", ame_gl_attr_name(attr), attr, value);
    if (g_real_SDL_GL_SetAttribute) return g_real_SDL_GL_SetAttribute(attr, value);
    return false;
}

static bool amethyst_SDL_GL_LoadLibrary(const char *path) {
    if (!g_real_SDL_GL_LoadLibrary) return false;
    bool ok = g_real_SDL_GL_LoadLibrary(path);
    if (ok) {
        NSLog(@"[SDLGL] SDL_GL_LoadLibrary(%s) -> ok", path ? path : "(default)");
        return true;
    }
    const char *err = g_real_SDL_GetError ? g_real_SDL_GetError() : NULL;
    NSLog(@"[SDLGL] SDL_GL_LoadLibrary(%s) -> failed: %s",
          path ? path : "(default)", err ? err : "(no error)");
    if (getenv("AMETHYST_SDL_STRICT_GL_LOAD") != NULL) {
        return false;  // 诊断用：保留原始失败行为
    }
    if (err != NULL && strstr(err, "already loaded") != NULL) {
        NSLog(@"[SDLGL] treating 'already loaded' as success "
              @"(renderer preloaded via -Dorg.lwjgl.opengl.libname)");
        return true;
    }
    return false;
}
int (*orig_open)(const char *path, int oflag, ...);

/// 提供给 zink stride fix 使用的"绕过 hook"的 dlsym
/// amethyst_vkGetInstanceProcAddr / amethyst_vkGetDeviceProcAddr 内部查找
/// 真实 Vulkan 函数指针时必须调用此函数，否则会被 hooked_dlsym 拦截（返回
/// 我们的 wrapper），导致无限递归。
void *amethyst_orig_dlsym(void *handle, const char *name) {
    if (orig_dlsym) {
        return orig_dlsym(handle, name);
    }
    // fallback：如果 hook 尚未初始化（不应发生），用普通 dlsym
    return dlsym(handle, name);
}

// 前向声明：zink stride fix 状态变量（定义在文件后部 Vulkan stride fix 区域，
// 但 hooked_dlopen 在文件前部就需要引用它来检测 libOSMesa 加载）
static BOOL g_zinkStrideFixActive = NO;

// MARK: - fatal 通道取证（Task 27，26.3-pre-1 第四关）
//
// 背景：游戏死亡时 PLCrashView 弹出（= hooked_exit/hooked_abort 被某个非主线程
// 触发），但设备上既无 .ips 也无 hs_err：
//   - hooked_abort/hooked_exit 会 park 调用线程，orig_abort/orig_exit 永不执行，
//     所以 iOS 崩溃报告器永远收不到真实信号 -> .ips 必然不会生成（这是拦截
//     机制的固有属性，不是系统没记录）；
//   - 若死亡源自 JVM 的 SIGSEGV fatal handler，hs_err 文本只写进 stdout/stderr
//     管道，而 latestlog 尾部在多行突发 + 死亡竞争中会丢（Task 26：截断+NUL 空洞）。
// 因此取证改为绕过管道：O_APPEND 直写 $POJAV_HOME/fatal_trace.txt（malloc-free，
// 防 heap 损坏场景下的递归 abort），再 NSLog 到系统日志兜底（Console 可回捞）。
// 下一轮测试的 fatal_trace.txt 就是“谁调用了 abort/exit”的定位铁证。
void ame_write_fatal_trace(const char *reason) {
    // 防重入：若 abort 源于 heap 损坏，本函数内的任何分配都可能再次 abort。
    // 全程不用 malloc（静态缓冲 + snprintf），并用 CAS 拒绝并发/递归进入。
    static atomic_int busy;
    int expected = 0;
    if (!atomic_compare_exchange_strong(&busy, &expected, 1)) {
        return;
    }

    // 16384 → 32768：★ [SHADER-SIGBUS] 追加了各线程 PC 快照（最多 48 行），
    // 原容量在帧多时会截断归属块；单次 write(fd,…) 的写法不变。
    static char report[32768];
    size_t len = 0;
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    struct tm tmv;
    localtime_r(&ts.tv_sec, &tmv);
    len += (size_t)snprintf(report + len, sizeof(report) - len,
        "\n===== [Amethyst fatal trace] %04d-%02d-%02d %02d:%02d:%02d.%03d =====\n",
        tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
        tmv.tm_hour, tmv.tm_min, tmv.tm_sec, (int)(ts.tv_nsec / 1000000));

    char tname[64] = {0};
    pthread_getname_np(pthread_self(), tname, sizeof(tname));
    len += (size_t)snprintf(report + len, sizeof(report) - len,
        "reason: %s\nthread: %s\n",
        reason ? reason : "(null)", tname[0] ? tname : "(unnamed)");

    void *frames[64];
    int n = backtrace(frames, 64);
    for (int i = 0; i < n && len < sizeof(report) - 256; i++) {
        Dl_info info;
        memset(&info, 0, sizeof(info));
        if (dladdr(frames[i], &info) && info.dli_fname) {
            // ★ [SHADER-SIGBUS] 每帧标注归属 dylib + 偏移 + 符号 + 是否在 JIT 区
            len += (size_t)snprintf(report + len, sizeof(report) - len,
                "  #%02d %p  %s  %s + %llu %s\n", i, frames[i],
                info.dli_fname,
                info.dli_sname ? info.dli_sname : "?",
                (unsigned long long)((uintptr_t)frames[i] - (uintptr_t)info.dli_fbase),
                JIT26AddressInPreparedRegion(frames[i]) ? "[JIT-REGION]" : "");
        } else {
            len += (size_t)snprintf(report + len, sizeof(report) - len,
                "  #%02d %p  <anonymous/JIT?>\n", i, frames[i]);
        }
    }

    // ★ [SHADER-SIGBUS] 崩溃归属块：dlopen 目标 + 线程 id + 各线程 PC 归属。
    //   为什么必须加：上面这段回溯是 *abort 自己* 的栈（信号处理上下文里帧指针
    //   链在 sigtramp 处断开，真正的故障帧不在链上）；对 SIGBUS/dlopen 期静态
    //   初始化这类崩溃，回溯里的 dylib 只会是 libjvm，元凶要靠"最后一个 dlopen
    //   目标"和"各线程 PC 的 dladdr 归属"来指认。
    //   exit(0)/exit(n) 的正常退出取证不含本块（避免刷无关线程快照）。
    if (reason == NULL || strstr(reason, "exit(") == NULL) {
        if (g_ame_lastDlopenSet) {
            len += (size_t)snprintf(report + len, sizeof(report) - len,
                "★ attribution: last dlopen/System.load target = %s\n"
                "  (dlopen-time crash 的元凶通常就是这个镜像；home/tmp 下的就是"
                "被解包出来的副本)\n", g_ame_lastDlopenPath);
        } else {
            len += (size_t)snprintf(report + len, sizeof(report) - len,
                "★ attribution: no dlopen recorded before this abort\n");
        }
        uint64_t selfTid = 0;
        pthread_threadid_np(NULL, &selfTid);
        len += (size_t)snprintf(report + len, sizeof(report) - len,
            "★ aborting thread: name=%s id=%llu\n",
            tname[0] ? tname : "(unnamed)", (unsigned long long)selfTid);
        if (len + 1024 < sizeof(report)) {
            len += (size_t)snprintf(report + len, sizeof(report) - len,
                "-- all-thread PC snapshot (pc → image+offset, [JIT-REGION] = "
                "落在 JIT26 已 PrepareRegion 的匿名区) --\n");
            len += ame_snapshot_all_threads(report + len, sizeof(report) - len);
        }
    }

    // 先落盘（不经管道/stdio，O_APPEND 单次 write），后 NSLog（系统日志兑底）
    const char *home = getenv("POJAV_HOME");
    if (home) {
        char path[1024];
        snprintf(path, sizeof(path), "%s/fatal_trace.txt", home);
        int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            ssize_t wr = write(fd, report, len);
            (void)wr;
            close(fd);
        }
    }
    if (len < sizeof(report)) report[len] = '\0';
    NSLog(@"%s", report);

    atomic_store(&busy, 0);
}

void handle_fatal_exit(int code) {
    if (NSThread.isMainThread) {
        return;
    }

    // 注意：本仓库 PLLogOutputView.handleExitCode: 返回 void（项目自定义的
    // PLCrashView 集成），不能照搬上游的 if (![PLLogOutputView handleExitCode:code]) return;
    // 检查。这里直接调用，让 PLCrashView 内部决定是否展示崩溃界面。
    [PLLogOutputView handleExitCode:code];

    if (fatalExitGroup != nil) {
        // Likely other threads are crashing, put them to sleep
        sleep(INT_MAX);
    }
    fatalExitGroup = dispatch_group_create();
    dispatch_group_enter(fatalExitGroup);
    dispatch_group_wait(fatalExitGroup, DISPATCH_TIME_FOREVER);
}

void hooked_abort() {
    NSLog(@"abort() called");
    ame_write_fatal_trace("abort() called");
    handle_fatal_exit(SIGABRT);
    orig_abort();
}

void hooked___assert_rtn(const char* func, const char* file, int line, const char* failedexpr)
{
    // 断言消息也直写 fatal_trace：stderr 管道尾部在死亡竞争中不可靠（Task 26）
    char assertMsg[1024];
    if (func == NULL) {
        fprintf(stderr, "Assertion failed: (%s), file %s, line %d.\n", failedexpr, file, line);
        snprintf(assertMsg, sizeof(assertMsg), "assertion failed: (%s), file %s, line %d",
                 failedexpr ? failedexpr : "?", file ? file : "?", line);
    } else {
        fprintf(stderr, "Assertion failed: (%s), function %s, file %s, line %d.\n", failedexpr, func, file, line);
        snprintf(assertMsg, sizeof(assertMsg), "assertion failed: (%s), function %s, file %s, line %d",
                 failedexpr ? failedexpr : "?", func ? func : "?", file ? file : "?", line);
    }
    ame_write_fatal_trace(assertMsg);
    hooked_abort();
}

void hooked_exit(int code) {
    // Task 32 黑屏取证：exit 时刻的呈现路径快照。
    // MC 26.3 设备实测黑屏约 20 秒后干净退出（exit(0)）—— 退出时渲染循环
    // 是否还在交换帧、呈现路径是否健康，是判定"黑屏 = 渲染停了"还是
    // "黑屏 = 帧没上屏"的最后一块拼图（计数器由 gl_bridge.m 维护）。
    {
        unsigned long swapOK = 0, swapFail = 0;
        ame_egl_swap_stats(&swapOK, &swapFail);
        NSLog(@"[RenderDiag] exit(%d) snapshot: swapOK=%lu swapFail=%lu", code, swapOK, swapFail);
    }
    NSLog(@"exit(%d) called", code);
    // Task 144：headless JVM 执行期的 exit 抑制（Forge 安装"闪退"根治）。
    // 命中标志时：仅终结调用线程（libjli/JVM 内部线程），进程存活，
    // launchHeadlessJVM 的调用方继续读 status.json 判定安装成败。
    // 主线程豁免：主线程上若有极端路径 exit，走原逻辑（不能 pthread_exit
    // 主线程把 app 挂死）。
    if (atomic_load(&g_ame_suppressJvmExit) && !pthread_main_np()) {
        char supMsg[96];
        snprintf(supMsg, sizeof(supMsg), "Task144: exit(%d) suppressed during headless JVM (thread exits, process lives)", code);
        NSLog(@"[Amethyst] %s", supMsg);
        ame_write_fatal_trace(supMsg);
        // Task 146：exit 被拦截 = 安装器 JVM 已跑完（libjli 的 exit(0) 就是
        // 它的"正常收尾"）。先置终结信号再 pthread_exit，等待方据此继续
        // 读 status.json 判定安装成败（不再依赖 join —— libjli 的终止设计
        // 就是杀进程，JLI_Launch 永远不会返回，装机日志 0.85 (4/4) 刷屏实锤）。
        atomic_store(&g_ame_headlessJvmFinished, 1);
        pthread_exit(NULL);
    }
    // Task 48：exit(0) 也写回溯。此前只有非零退出才落 fatal_trace.txt；而
    // 实测黑屏约 20 秒后的静默 exit(0)（渲染循环仍在交换）来源不明——
    // MC 窗口可见性看门狗 / JVM 主线程 / 启动器超时都有可能。回溯写入
    // $POJAV_HOME/fatal_trace.txt（O_APPEND、malloc-free），下轮日志即可
    // 一锤定音定位调用者。code==0 的回溯不弹崩溃界面、不影响正常退出。
    if (code == 0) {
        ame_write_fatal_trace("exit(0) backtrace (Task 48, black-screen-era silent exit)");
    }
    if (code != 0) {
        char exitMsg[64];
        snprintf(exitMsg, sizeof(exitMsg), "exit(%d) called", code);
        ame_write_fatal_trace(exitMsg);
    }
    if (code == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIApplication.sharedApplication performSelector:@selector(suspend)];
        });
        usleep(100*1000);
        orig_exit(0);
        return;
    }
    handle_fatal_exit(code);

    orig_exit(code);
}

void* hooked_dlopen(const char* path, int mode) {
    // ------------------------------------------------------------------
    // Task 106（BMC2 创建存档闪退根治）：拦截 spark 的原生分析器。
    //
    // 41cdff0 装机日志（2e1ea09 构建）：BMC2 1.20.1 首次走到"创建新世界"，
    // server 线程 bootstrap 到 spark 的 "Starting background profiler..."，
    // spark 把 jar 内置的 spark/macos/libasyncProfiler.so（FAT: x86_64+arm64，
    // arm64 切片带 20960 字节 LC_CODE_SIGNATURE，platform=macOS）解包到
    // config/spark/tmp/spark-*.tmp 并 System.load——这是本设备历史上第一个
    // 走进 PLPatchMachOPlatformForFile 重标签路径的库（此前所有会话 0 次）。
    // 平台重标签改写了 mach header → 签名哈希不再匹配 → dyld 代码签名校验
    // 失败 → 进程被杀（SIGKILL，无 hs_err 无 fatal trace——日志最后一行
    // 正是 "[Amethyst] Patching ...libasyncProfiler.so.tmp"）。
    // 未签名库（本设备其余全部 home 目录库）重标签无害；已签名库重标签
    // 必死。spark 的 Java 侧对 UnsatisfiedLinkError 有完整降级（1.10.53
    // 字节码实证：AsyncProfilerAccess.load catch UnsatisfiedLinkError →
    // NativeLoadingException → getInstance catch Exception → 分析器禁用，
    // 游戏继续），拦截是零风险选择：spark 回退 Java 采样器，建档照常进行。
    //
    // Task107 修正（dyld_patch_platform.m 已改签名中和为 ad-hoc 重签名）：
    // 上述"未签名库重标签无害"的表述经 ce43a34 双会话证伪——本机 dyld4
    // 对"无签名 blob"的库一律拒载（JNA libjnidispatch 报 "missing code
    // signature"，26.3 因此崩在 MacosUtil→JNA 链）；历史能加载的库其实
    // 全部至少带 ad-hoc/linker 签名（哈希失效被容忍）。重签名后该拦截仅
    // 防御"team 签名 FAT 库无法原位重签"的残余场景 + 不让 macOS 分析器
    // 真的跑在 iOS 上，保留。
    if (path != NULL && strstr(path, "libasyncProfiler") != NULL) {
        static int s_ame106_blocked = 0;
        if (s_ame106_blocked < 3) {
            ++s_ame106_blocked;
            NSLog(@"[Amethyst] Task106: blocked dlopen of signed macOS profiler lib (%s) -- platform retag would invalidate its code signature and dyld would kill the process; spark falls back to its Java sampler (world creation proceeds)", path);
        }
        return NULL;
    }
    // ★ [SHADER-SIGBUS] 记录本次 dlopen/System.load 目标（崩溃归属用）。
    //   必须在所有分发分支（含 musttail 尾返回）之前写入 —— 尾返回没有回头路，
    //   只能在入口记。若随后在该 dlopen 内崩溃，fatal_trace 会直接点名这个镜像。
    ame_record_dlopen_target(path);
    if (path != NULL && strstr(path, "glslang") != NULL) {
        // ★ [SHADER-SIGBUS] 判据行：glslang 到底从哪加载。
        //   home/tmp 下的 libglslang_metallum.dylib = 从 jar 解包出的【未签名副本】
        //   （dlopen 期静态初始化 SIGBUS 的温床）；
        //   <app>/Frameworks/libglslang.dylib = 包里随 app 一起被 ad-hoc 签名的副本。
        //   修好后这两行只应出现 Frameworks 那条。
        NSLog(@"[Amethyst][SHADER-SIGBUS] dlopen(glslang) -> %s", path);
    }
    // 同步自上游：非 TXM 的 iOS 26+ 设备需要硬件断点重定向（hooked_dlopen_26_ppl）
    BOOL shouldUseDyldBypass26PPL = NO;
    if (DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED)) {
        shouldUseDyldBypass26PPL = hwRedirectOrig[0] && !DeviceHasJITFlags(JIT_FLAG_HAS_TXM);
    }
    // Only patch Mach-O and use dyld bypass dylib is in the home dir
    // or tmp dir: LiveContainer makes a symlink to its own tmp dir so checking home dir alone would fail
    const char *home = getenv("HOME");
    const char *tmp = getenv("TMPDIR");
    char fullpath[PATH_MAX];
    BOOL shouldUseDyldBypass = path && realpath(path, fullpath) && (strstr(fullpath, home) || (tmp && strstr(fullpath, tmp)));
    shouldUseDyldBypass26PPL &= shouldUseDyldBypass;

    // 同步自上游：在分支前统一调用 PLPatchMachOPlatformForFile
    // （原实现仅在 shouldUseDyldBypass 分支调用，遗漏了 26PPL 路径，
    //  会导致 iOS 26+ 非 TXM 设备的 dyld bypass 失败）
    if (shouldUseDyldBypass) {
        PLPatchMachOPlatformForFile(path);
    }

    // fork 自有特性：Zink stride fix——libOSMesa 加载后重新执行 fishhook，
    // 捕获其对 vkGetInstanceProcAddr / vkGetDeviceProcAddr 的符号引用
    // （installZinkStrideFix 在 libOSMesa 加载前调用，初次 rebind 无法
    //  捕获 libOSMesa image 内的引用；必须在其加载后再次 rebind）
    BOOL needsZinkRebind = path && strstr(path, "libOSMesa") && g_zinkStrideFixActive;
    // Task 132（26.1.2 整合包 controlify/JNA closure SIGBUS 补完）：
    // libjnidispatch（JNA 原生库）加载后重绑定其 _dlsym 指针槽为
    // hooked_dlsym——否则 JNA 经自己的 GOT 槽调真 dlsym，Task131 的
    // SDL_SetEventFilter/SDL_AddEventWatch 守卫对 JNA 路径不生效
    // （机制与实现见 sdl3_hook.m 的 Task 132 块）。
    // 注：JNA 5.13 从 jar 解包到临时文件（jna<随机>.tmp），路径里没有
    // "libjnidispatch" 字样——单靠这个 strstr 永远不会命中（b33e550/
    // 3bcf8c4 装机日志实证零 Task132 日志行）；真正的检测在 Task133 的
    // install-name 扫描里，此处保留作为显式命名加载形态的直通路径。
    BOOL needsJnaDlsymRebind = path != NULL && strstr(path, "libjnidispatch") != NULL;
    // Task 133：JVM/JNA 链路加载后跑镜像扫描——libjli/libjvm 的 _dlopen
    // 槽改绑（JVM 后续 System.load 全部进入本 hook），jna*.tmp 按
    // install name 检出并触发 Task132 重绑定。触发面：libjli/libjvm/
    // jna/.tmp/java 路径；漏网的由 hooked_dlsym 入口的同款扫描兜底。
    BOOL needsT133Scan = path != NULL && (strstr(path, "libjli") != NULL ||
                                          strstr(path, "libjvm") != NULL ||
                                          strstr(path, "jna") != NULL ||
                                          strstr(path, ".tmp") != NULL ||
                                          strstr(path, "java") != NULL);
    // Task 132/133 同样需要拿到真实句柄做后处理，与 zink 重绑同款非尾返路径
    BOOL needsPostLoadFixup = needsZinkRebind || needsJnaDlsymRebind || needsT133Scan;

    void *handle;
    if (shouldUseDyldBypass26PPL) {
        if (needsPostLoadFixup) {
            handle = hooked_dlopen_26_ppl(path, mode);
        } else {
            __attribute__((musttail)) return hooked_dlopen_26_ppl(path, mode);
        }
    } else if (shouldUseDyldBypass) {
        // Special case for LiveContainer multitask mode where it hooks dlopen to hook mmap,
        // which will break this dyld bypass, so we redirect calls to the original dlopen.
        static void *(*sys_dlopen)(const char *, int);
        if(!sys_dlopen) sys_dlopen = dlsym(RTLD_NEXT, "dlopen");
        if (needsPostLoadFixup) {
            handle = sys_dlopen(path, mode);
        } else {
            __attribute__((musttail)) return sys_dlopen(path, mode);
        }
    } else {
        if (needsPostLoadFixup) {
            handle = orig_dlopen(path, mode);
        } else {
            __attribute__((musttail)) return orig_dlopen(path, mode);
        }
    }

    // Zink stride fix rebind（仅在 needsZinkRebind 时执行）
    if (handle && needsZinkRebind) {
        NSLog(@"[ZinkStrideFix] libOSMesa loaded via dlopen, re-rebinding Vulkan symbols");
        rebindZinkStrideFixForNewImage();
    }
    // Task 132：libjnidispatch 的 _dlsym 槽位重绑定（实现待移植，当前为本文件桩）。
    // 幂等（重复加载安全）；失败仅记日志不阻断加载。
    if (handle && needsJnaDlsymRebind) {
        amethyst_task132_rebind_jna_dlsym(handle, (void *)hooked_dlsym);
    }
    // Task 133：镜像扫描（增量，无新镜像时一次计数调用即早退）——
    // libjli/libjvm 的 _dlopen 槽改绑 + libjnidispatch（任意文件名形态）
    // 的 _dlsym 槽改绑。加载失败（handle==NULL）也扫：镜像可能已部分
    // 注册或由其它线程并发加载完成，扫描本身幂等。
    if (needsT133Scan) {
        amethyst_task133_ensure_jvm_chain();
    }
    return handle;
}

// ============================================================================
// 硬件断点 dlopen 重定向（同步自上游，用于非 TXM 的 iOS 26+ 设备）
// 当 redirectFunctionHWBreakpoint 被选中时，dlopen 需要通过硬件断点 + Mach 异常
// 来重定向 dyld 内的 mmap/fcntl 调用，因为此时无法直接修改 dyld 代码段。
// ============================================================================
void *exception_handler(void *unused) {
    mach_msg_server(mach_exc_server, sizeof(union __RequestUnion__catch_mach_exc_subsystem), excPort, MACH_MSG_OPTION_NONE);
    abort();
}

void *hooked_dlopen_26_ppl(const char *path, int mode) {
    // ★ [SHADER-SIGBUS] 同 hooked_dlopen：记录目标（本分支只在非 TXM 的 iOS 26+ 走）。
    ame_record_dlopen_target(path);
    if (!excPort) {
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &excPort);
        mach_port_insert_right(mach_task_self(), excPort, excPort, MACH_MSG_TYPE_MAKE_SEND);
        pthread_t thread;
        pthread_create(&thread, NULL, exception_handler, NULL);
    }

    // save old thread states
    exception_mask_t mask = EXC_MASK_BREAKPOINT;
    mach_msg_type_number_t masksCnt = 1;
    exception_handler_t handler = excPort;
    exception_behavior_t behavior = EXCEPTION_STATE | MACH_EXCEPTION_CODES;
    thread_state_flavor_t flavor = ARM_THREAD_STATE64;
    arm_debug_state64_t origDebugState;
    mach_port_t thread = mach_thread_self();
    thread_get_state(thread, ARM_DEBUG_STATE64, (thread_state_t)&origDebugState, &(mach_msg_type_number_t){ARM_DEBUG_STATE64_COUNT});
    thread_swap_exception_ports(thread, mask, handler, behavior, flavor, &mask, &masksCnt, &handler, &behavior, &flavor);
    if (masksCnt != 1) {
        NSLog(@"main_hook: Expected 1 exception port, got %d. HW breakpoint hook may fail.", masksCnt);
    }

    // hook stuff. this will overwrite LiveContainer private container multitask's hook, we will load __TEXT using JIT inside
    arm_debug_state64_t hookDebugState = {0};
    for(int i = 0; i < 6 && hwRedirectOrig[i]; i++) {
        hookDebugState.__bvr[i] = (uint64_t)hwRedirectOrig[i];
        hookDebugState.__bcr[i] = 0x1e5;
    }
    thread_set_state(thread, ARM_DEBUG_STATE64, (thread_state_t)&hookDebugState, ARM_DEBUG_STATE64_COUNT);

    // fixup @loader_path since we cannot use musttail here
    void *result;
    void *callerAddr = __builtin_return_address(0);
    struct dl_info info;
    if (path && !strncmp(path, "@loader_path/", 13) && dladdr(callerAddr, &info)) {
        char resolvedPath[PATH_MAX];
        snprintf(resolvedPath, sizeof(resolvedPath), "%s/%s", dirname((char *)info.dli_fname), path + 13);
        result = orig_dlopen(resolvedPath, mode);
    } else {
        result = orig_dlopen(path, mode);
    }

    // restore old thread states
    thread_set_state(thread, ARM_DEBUG_STATE64, (thread_state_t)&origDebugState, ARM_DEBUG_STATE64_COUNT);
    thread_swap_exception_ports(thread, mask, handler, behavior, flavor, &mask, &masksCnt, &handler, &behavior, &flavor);

    return result;
}

kern_return_t catch_mach_exception_raise_state(mach_port_t exception_port, exception_type_t exception, const mach_exception_data_t code, mach_msg_type_number_t codeCnt, int *flavor, const thread_state_t old_state, mach_msg_type_number_t old_stateCnt, thread_state_t new_state, mach_msg_type_number_t *new_stateCnt) {
    arm_thread_state64_t *old = (arm_thread_state64_t *)old_state;
    arm_thread_state64_t *new = (arm_thread_state64_t *)new_state;
    uint64_t pc = arm_thread_state64_get_pc(*old);

    for(int i = 0; i < 6 && hwRedirectOrig[i]; i++) {
        if(pc == (uint64_t)hwRedirectOrig[i]) {
            *new = *old;
            *new_stateCnt = old_stateCnt;
            arm_thread_state64_set_pc_fptr(*new, hwRedirectTarget[i]);
            return KERN_SUCCESS;
        }
    }
    NSLog(@"[DyldLVBypass] Unknown breakpoint at pc: %p", (void*)pc);
    return KERN_FAILURE;
}

kern_return_t catch_mach_exception_raise(mach_port_t exception_port, mach_port_t thread, mach_port_t task, exception_type_t exception, mach_exception_data_t code, mach_msg_type_number_t codeCnt) {
    abort();
}

kern_return_t catch_mach_exception_raise_state_identity(mach_port_t exception_port, mach_port_t thread, mach_port_t task, exception_type_t exception, mach_exception_data_t code, mach_msg_type_number_t codeCnt, int *flavor, thread_state_t old_state, mach_msg_type_number_t old_stateCnt, thread_state_t new_state, mach_msg_type_number_t *new_stateCnt) {
    abort();
}

// ============================================================================
// Vulkan vertex stride alignment fix（zink + MoltenVK + Mesa 25.0.7）
// ============================================================================
// 问题：
//   Metal API 硬性要求 vertex attribute binding stride 必须 4 字节对齐。
//   Mesa 25.0.7 zink 移除了 Mesa 21.0.0 中存在的 stride 对齐 workaround。
//   当光影包（如 BSL）触发管线重建且 stride 非 4 对齐时，MoltenVK 返回
//   VK_ERROR_INITIALIZATION_FAILED，zink 的 update_gfx_pipeline 未处理该
//   错误，使用 NULL pipeline 句柄导致 SIGSEGV。
//
// 解决方案：
//   通过 dlsym 拦截 + fishhook 双重机制 hook vkGetInstanceProcAddr /
//   vkGetDeviceProcAddr。当 zink 请求 vkCreateGraphicsPipelines 时返回
//   我们的 wrapper。wrapper 在调用真实函数前将 vertex binding stride
//   向上对齐到 4 字节边界。
//
//   此 fix 仅在 zink 渲染器（libOSMesa）被选中时激活。

// 最小 Vulkan 类型定义（布局严格匹配 vulkan_core.h，64 位平台）
typedef int32_t VkZResult;
typedef struct VkZInstance_T* VkZInstance;
typedef struct VkZDevice_T* VkZDevice;
typedef struct VkZCommandBuffer_T* VkZCommandBuffer;
typedef struct VkZPipelineCache_T* VkZPipelineCache;
typedef struct VkZPipeline_T* VkZPipeline;
typedef struct VkZPipelineLayout_T* VkZPipelineLayout;
typedef struct VkZRenderPass_T* VkZRenderPass;

#define VK_Z_SUCCESS 0
#define VK_Z_ERROR_INITIALIZATION_FAILED (-3)

// VkPipelineBindPoint
typedef enum {
    VK_Z_PIPELINE_BIND_POINT_GRAPHICS = 0,
    VK_Z_PIPELINE_BIND_POINT_COMPUTE = 1,
} VkZPipelineBindPoint;

typedef enum {
    VK_Z_VERTEX_INPUT_RATE_VERTEX = 0,
    VK_Z_VERTEX_INPUT_RATE_INSTANCE = 1,
} VkZVertexInputRate;

typedef struct {
    uint32_t binding;
    uint32_t stride;
    VkZVertexInputRate inputRate;
} VkZVertexInputBindingDescription;

typedef struct {
    uint32_t location;
    uint32_t binding;
    int32_t format;
    uint32_t offset;
} VkZVertexInputAttributeDescription;

typedef struct {
    int32_t sType;                   // VkStructureType
    const void* pNext;
    uint32_t flags;
    uint32_t vertexBindingDescriptionCount;
    const VkZVertexInputBindingDescription* pVertexBindingDescriptions;
    uint32_t vertexAttributeDescriptionCount;
    const VkZVertexInputAttributeDescription* pVertexAttributeDescriptions;
} VkZPipelineVertexInputStateCreateInfo;

// VkGraphicsPipelineCreateInfo 完整布局（匹配 vulkan_core.h，64 位）
typedef struct {
    int32_t sType;                   // VkStructureType
    const void* pNext;
    uint32_t flags;
    uint32_t stageCount;
    const void* pStages;             // const VkPipelineShaderStageCreateInfo*
    const VkZPipelineVertexInputStateCreateInfo* pVertexInputState;
    const void* pInputAssemblyState;
    const void* pTessellationState;
    const void* pViewportState;
    const void* pRasterizationState;
    const void* pMultisampleState;
    const void* pDepthStencilState;
    const void* pColorBlendState;
    const void* pDynamicState;
    VkZPipelineLayout layout;
    VkZRenderPass renderPass;
    uint32_t subpass;
    VkZPipeline basePipelineHandle;
    int32_t basePipelineIndex;
} VkZGraphicsPipelineCreateInfo;

typedef VkZResult (*PFN_zkCreateGraphicsPipelines)(
    VkZDevice, VkZPipelineCache, uint32_t,
    const VkZGraphicsPipelineCreateInfo*, const void*, VkZPipeline*);
typedef void* (*PFN_zkGetInstanceProcAddr)(VkZInstance, const char*);
typedef void* (*PFN_zkGetDeviceProcAddr)(VkZDevice, const char*);

// vkCmd* 函数指针类型（用于 dummy pipeline skip draws）
// 参数数量严格匹配 Vulkan 标准签名（vulkan_core.h），避免与函数实现调用不一致
typedef void (*PFN_zkCmdBindPipeline)(VkZCommandBuffer, VkZPipelineBindPoint, VkZPipeline);
typedef void (*PFN_zkCmdDraw)(VkZCommandBuffer, uint32_t, uint32_t, uint32_t, uint32_t);
typedef void (*PFN_zkCmdDrawIndexed)(VkZCommandBuffer, uint32_t, uint32_t, uint32_t, int32_t, uint32_t);
// vkCmdDrawIndirect(cmd, buffer, offset, drawCount, stride) — 5 个参数
typedef void (*PFN_zkCmdDrawIndirect)(VkZCommandBuffer, uint64_t, uint64_t, uint32_t, uint32_t);
typedef void (*PFN_zkCmdDrawIndexedIndirect)(VkZCommandBuffer, uint64_t, uint64_t, uint32_t, uint32_t);
// vkCmdDrawIndirectCount(cmd, buffer, offset, countBuffer, countBufferOffset, maxDrawCount, stride) — 7 个参数
typedef void (*PFN_zkCmdDrawIndirectCount)(VkZCommandBuffer, uint64_t, uint64_t, uint64_t, uint64_t, uint32_t, uint32_t);
typedef void (*PFN_zkCmdDrawIndexedIndirectCount)(VkZCommandBuffer, uint64_t, uint64_t, uint64_t, uint64_t, uint32_t, uint32_t);
// vkDestroyPipeline(device, pipeline, pAllocator) — 3 个参数
// 必须 hook：zink 销毁 dummy pipeline 时，MoltenVK 解引用 magic handle 会崩溃
typedef void (*PFN_zkDestroyPipeline)(VkZDevice, VkZPipeline, const void*);

// Stride fix 状态（g_zinkStrideFixActive 已在文件前部前向声明）
static PFN_zkGetInstanceProcAddr g_real_vkGetInstanceProcAddr = NULL;
static PFN_zkGetDeviceProcAddr g_real_vkGetDeviceProcAddr = NULL;
static PFN_zkCreateGraphicsPipelines g_real_vkCreateGraphicsPipelines = NULL;

// vkCmd* 真实函数指针（dummy pipeline skip draws 需要）
static PFN_zkCmdBindPipeline g_real_vkCmdBindPipeline = NULL;
static PFN_zkCmdDraw g_real_vkCmdDraw = NULL;
static PFN_zkCmdDrawIndexed g_real_vkCmdDrawIndexed = NULL;
static PFN_zkCmdDrawIndirect g_real_vkCmdDrawIndirect = NULL;
static PFN_zkCmdDrawIndexedIndirect g_real_vkCmdDrawIndexedIndirect = NULL;
static PFN_zkCmdDrawIndirectCount g_real_vkCmdDrawIndirectCount = NULL;
static PFN_zkCmdDrawIndexedIndirectCount g_real_vkCmdDrawIndexedIndirectCount = NULL;
// vkDestroyPipeline 真实函数指针（dummy pipeline 销毁需要）
static PFN_zkDestroyPipeline g_real_vkDestroyPipeline = NULL;

// ============================================================================
// Dummy pipeline 机制（修复 zink + Mesa 25.0.7 光影 SIGSEGV）
// ============================================================================
// 问题：
//   Mesa 25.0.7 zink 比 21.0.0 更严格地校验 SPIR-V shader 接口。
//   当光影包（如 BSL、Mellow Shader）的 fragment shader 声明了 vertex shader
//   未写入的 input（如 user(locn1_2)），MoltenVK 在 vkCreateGraphicsPipelines
//   时返回 VK_ERROR_INITIALIZATION_FAILED。
//
//   zink 的 update_gfx_pipeline 未正确处理此失败：
//   Vulkan spec 规定 vkCreateGraphicsPipelines 失败时 pPipelines[i] 设为
//   VK_NULL_HANDLE，zink 后续使用 NULL pipeline 句柄导致 SIGSEGV。
//
// 解决方案（dummy pipeline + skip draws）：
//   1. 当 vkCreateGraphicsPipelines 失败时，不返回失败，而是返回 VK_SUCCESS
//      并为每个失败的 pipeline 分配一个 dummy 句柄（非 NULL 的 magic 值）。
//   2. 维护 dummy pipeline 集合。
//   3. Hook vkCmdBindPipeline：跟踪当前绑定的 pipeline，如果是 dummy 则跳过绑定。
//   4. Hook vkCmdDraw*：如果当前绑定的 pipeline 是 dummy，跳过绘制。
//
//   这样 zink 认为 pipeline 创建成功，不会 SIGSEGV；
//   失败的 pipeline 对应的几何体不会被绘制（黑屏/缺失，但不崩溃）。
//   成功的 pipeline 正常渲染，光影效果保留。

#define ZINK_DUMMY_PIPELINE_MAGIC 0xDEAD0000ULL
#define ZINK_DUMMY_PIPELINE_MAX 4096

// dummy pipeline 集合（使用简单数组，线性查找；dummy pipeline 数量通常很少）
static uintptr_t g_dummyPipelines[ZINK_DUMMY_PIPELINE_MAX];
static uint32_t g_dummyPipelineCount = 0;
// 当前绑定的 graphics pipeline（用于判断 draw 是否应该跳过）
// 注意：VkCommandBuffer 可能多个，但 zink 单线程渲染，用全局变量足够
static VkZPipeline g_currentBoundGraphicsPipeline = NULL;

/// 判断 pipeline 是否为 dummy
static BOOL isDummyPipeline(VkZPipeline pipeline) {
    if (!pipeline) return NO;
    uintptr_t val = (uintptr_t)pipeline;
    if ((val & 0xFFFF0000ULL) != ZINK_DUMMY_PIPELINE_MAGIC) return NO;
    // 二分查找或线性查找（dummy pipeline 数量通常 <100，线性查找足够）
    for (uint32_t i = 0; i < g_dummyPipelineCount; i++) {
        if (g_dummyPipelines[i] == val) return YES;
    }
    return NO;
}

/// 分配一个新的 dummy pipeline 句柄
static VkZPipeline allocDummyPipeline(void) {
    if (g_dummyPipelineCount >= ZINK_DUMMY_PIPELINE_MAX) {
        // 溢出：复用第一个（极端情况，几乎不会发生）
        NSLog(@"[ZinkStrideFix] WARNING: dummy pipeline pool exhausted, reusing slot 0");
        return (VkZPipeline)g_dummyPipelines[0];
    }
    uintptr_t handle = ZINK_DUMMY_PIPELINE_MAGIC | (g_dummyPipelineCount + 1);
    g_dummyPipelines[g_dummyPipelineCount++] = handle;
    return (VkZPipeline)handle;
}

// 前向声明（供 zinkStrideFixRebind 使用）
static void* amethyst_vkGetInstanceProcAddr(VkZInstance instance, const char* pName);
static void* amethyst_vkGetDeviceProcAddr(VkZDevice device, const char* pName);
static VkZResult amethyst_vkCreateGraphicsPipelines(
    VkZDevice device, VkZPipelineCache pipelineCache, uint32_t createInfoCount,
    const VkZGraphicsPipelineCreateInfo* pCreateInfos, const void* pAllocator,
    VkZPipeline* pPipelines);
static void amethyst_vkCmdBindPipeline(VkZCommandBuffer cmd, VkZPipelineBindPoint bp, VkZPipeline pipeline);
static void amethyst_vkCmdDraw(VkZCommandBuffer cmd, uint32_t vertexCount, uint32_t instanceCount, uint32_t firstVertex, uint32_t firstInstance);
static void amethyst_vkCmdDrawIndexed(VkZCommandBuffer cmd, uint32_t indexCount, uint32_t instanceCount, uint32_t firstIndex, int32_t vertexOffset, uint32_t firstInstance);
static void amethyst_vkCmdDrawIndirect(VkZCommandBuffer cmd, uint64_t buffer, uint64_t offset, uint32_t drawCount, uint32_t stride);
static void amethyst_vkCmdDrawIndexedIndirect(VkZCommandBuffer cmd, uint64_t buffer, uint64_t offset, uint32_t drawCount, uint32_t stride);
static void amethyst_vkCmdDrawIndirectCount(VkZCommandBuffer cmd, uint64_t buffer, uint64_t offset, uint64_t countBuffer, uint64_t countBufferOffset, uint32_t maxDrawCount, uint32_t stride);
static void amethyst_vkCmdDrawIndexedIndirectCount(VkZCommandBuffer cmd, uint64_t buffer, uint64_t offset, uint64_t countBuffer, uint64_t countBufferOffset, uint32_t maxDrawCount, uint32_t stride);
static void amethyst_vkDestroyPipeline(VkZDevice device, VkZPipeline pipeline, const void* pAllocator);

// ============================================================================
// UINT→SINT 顶点属性格式转换（修复 MTLAttributeFormatUShort3 转换失败）
// ============================================================================
// 问题：
//   MoltenVK 编译 pipeline 时，若 vertex attribute 使用 UINT 格式（如
//   VK_FORMAT_R16G16B16_UINT → MTLAttributeFormatUShort3），但 shader 声明的
//   input 是有符号整数类型（int/ivec3），Metal 无法自动转换格式，返回
//   VK_ERROR_INITIALIZATION_FAILED：
//   "Cannot convert attribute from MTLAttributeFormatUShort3 to a signed integer type."
//
//   此问题在 Iris 光影 + Mesa 25.0.7 zink 下频发，导致实体渲染 pipeline 创建
//   失败，被 dummy pipeline fallback 替换后实体不渲染（黑屏/缺失）。
//
// 解决方案：
//   当 pipeline 首次创建失败时，重试一次：将所有 UINT 格式的 vertex attribute
//   转换为对应的 SINT 格式（如 R16G16B16_UINT → R16G16B16_SINT）。
//   Metal 会以有符号方式解析字节，与 shader 期望匹配。
//   对于大多数顶点属性（骨骼索引、坐标等），值通常很小，signed/unsigned 解析
//   结果一致，不会引入渲染错误。

/// 判断 Vulkan 格式是否为 UINT 类型
/// Vulkan 格式枚举值参考 vulkan_core.h：
///   R8_UINT=9, R8G8_UINT=11, R8G8B8_UINT=13, R8G8B8A8_UINT=42
///   R16_UINT=76, R16G16_UINT=78, R16G16B16_UINT=80, R16G16B16A16_UINT=82
///   R32_UINT=96, R32G32_UINT=98, R32G32B32_UINT=100, R32G32B32A32_UINT=102
static BOOL isVkUIntFormat(int32_t format) {
    switch (format) {
        case 9:   // VK_FORMAT_R8_UINT
        case 11:  // VK_FORMAT_R8G8_UINT
        case 13:  // VK_FORMAT_R8G8B8_UINT
        case 42:  // VK_FORMAT_R8G8B8A8_UINT
        case 76:  // VK_FORMAT_R16_UINT
        case 78:  // VK_FORMAT_R16G16_UINT
        case 80:  // VK_FORMAT_R16G16B16_UINT
        case 82:  // VK_FORMAT_R16G16B16A16_UINT
        case 96:  // VK_FORMAT_R32_UINT
        case 98:  // VK_FORMAT_R32G32_UINT
        case 100: // VK_FORMAT_R32G32B32_UINT
        case 102: // VK_FORMAT_R32G32B32A32_UINT
            return YES;
        default:
            return NO;
    }
}

/// 将 UINT 格式转换为对应的 SINT 格式
/// Vulkan 格式枚举中，UINT 和 SINT 是连续的（UINT+1 = SINT）：
///   R8_UINT(9) → R8_SINT(10), R8G8_UINT(11) → R8G8_SINT(12), ...
static int32_t convertVkUIntToSIntFormat(int32_t format) {
    switch (format) {
        case 9:   return 10;   // R8_UINT → R8_SINT
        case 11:  return 12;   // R8G8_UINT → R8G8_SINT
        case 13:  return 14;   // R8G8B8_UINT → R8G8B8_SINT
        case 42:  return 43;   // R8G8B8A8_UINT → R8G8B8A8_SINT
        case 76:  return 77;   // R16_UINT → R16_SINT
        case 78:  return 79;   // R16G16_UINT → R16G16_SINT
        case 80:  return 81;   // R16G16B16_UINT → R16G16B16_SINT
        case 82:  return 83;   // R16G16B16A16_UINT → R16G16B16A16_SINT
        case 96:  return 97;   // R32_UINT → R32_SINT
        case 98:  return 99;   // R32G32_UINT → R32G32_SINT
        case 100: return 101;  // R32G32B32_UINT → R32G32B32_SINT
        case 102: return 103;  // R32G32B32A32_UINT → R32G32B32A32_SINT
        default:  return format;
    }
}

/// 检查 pipeline create infos 中是否存在 UINT 格式的 vertex attribute
static BOOL pipelineCreateInfosHaveUIntFormat(
    uint32_t createInfoCount,
    const VkZGraphicsPipelineCreateInfo* pCreateInfos)
{
    for (uint32_t i = 0; i < createInfoCount; i++) {
        const VkZPipelineVertexInputStateCreateInfo* vis = pCreateInfos[i].pVertexInputState;
        if (!vis || !vis->pVertexAttributeDescriptions) continue;
        for (uint32_t j = 0; j < vis->vertexAttributeDescriptionCount; j++) {
            if (isVkUIntFormat(vis->pVertexAttributeDescriptions[j].format)) {
                return YES;
            }
        }
    }
    return NO;
}

/// 重试 pipeline 创建：将 UINT 顶点属性格式转换为 SINT
/// 可选地对齐 stride（用于与 stride 对齐修复组合使用）
/// 返回真实函数的调用结果
static VkZResult retryPipelineWithSIntFormats(
    VkZDevice device, VkZPipelineCache pipelineCache, uint32_t createInfoCount,
    const VkZGraphicsPipelineCreateInfo* pCreateInfos, const void* pAllocator,
    VkZPipeline* pPipelines,
    BOOL alsoAlignStrides)
{
    if (!g_real_vkCreateGraphicsPipelines) {
        return VK_Z_ERROR_INITIALIZATION_FAILED;
    }

    // 如果没有 UINT 格式，重试无意义
    if (!pipelineCreateInfosHaveUIntFormat(createInfoCount, pCreateInfos)) {
        return VK_Z_ERROR_INITIALIZATION_FAILED;
    }

    NSLog(@"[ZinkStrideFix] Retrying pipeline creation with UINT→SINT format conversion%s",
          alsoAlignStrides ? " + stride alignment" : "");

    // 深拷贝并应用格式转换（可选 + stride 对齐）
    VkZGraphicsPipelineCreateInfo* newCreateInfos = malloc(sizeof(VkZGraphicsPipelineCreateInfo) * createInfoCount);
    VkZPipelineVertexInputStateCreateInfo* newVIS = malloc(sizeof(VkZPipelineVertexInputStateCreateInfo) * createInfoCount);
    VkZVertexInputBindingDescription** allocedBindings = calloc(createInfoCount, sizeof(VkZVertexInputBindingDescription*));
    VkZVertexInputAttributeDescription** allocedAttrs = calloc(createInfoCount, sizeof(VkZVertexInputAttributeDescription*));

    memcpy(newCreateInfos, pCreateInfos, sizeof(VkZGraphicsPipelineCreateInfo) * createInfoCount);

    for (uint32_t i = 0; i < createInfoCount; i++) {
        const VkZPipelineVertexInputStateCreateInfo* vis = pCreateInfos[i].pVertexInputState;
        if (!vis) continue;

        newVIS[i] = *vis;

        // 格式转换：UINT → SINT
        if (vis->pVertexAttributeDescriptions && vis->vertexAttributeDescriptionCount > 0) {
            uint32_t attrCount = vis->vertexAttributeDescriptionCount;
            VkZVertexInputAttributeDescription* newAttrs = malloc(sizeof(VkZVertexInputAttributeDescription) * attrCount);
            memcpy(newAttrs, vis->pVertexAttributeDescriptions, sizeof(VkZVertexInputAttributeDescription) * attrCount);
            for (uint32_t j = 0; j < attrCount; j++) {
                if (isVkUIntFormat(newAttrs[j].format)) {
                    int32_t oldFmt = newAttrs[j].format;
                    newAttrs[j].format = convertVkUIntToSIntFormat(newAttrs[j].format);
                    NSLog(@"[ZinkStrideFix] Pipeline %u attr %u: format %d -> %d (UINT→SINT)",
                          i, j, oldFmt, newAttrs[j].format);
                }
            }
            allocedAttrs[i] = newAttrs;
            newVIS[i].pVertexAttributeDescriptions = newAttrs;
        }

        // 可选：stride 对齐
        if (alsoAlignStrides && vis->pVertexBindingDescriptions) {
            BOOL pipelineNeedsAlignment = NO;
            for (uint32_t j = 0; j < vis->vertexBindingDescriptionCount; j++) {
                if (vis->pVertexBindingDescriptions[j].stride & 3) {
                    pipelineNeedsAlignment = YES;
                    break;
                }
            }
            if (pipelineNeedsAlignment) {
                uint32_t bindingCount = vis->vertexBindingDescriptionCount;
                VkZVertexInputBindingDescription* newBindings = malloc(sizeof(VkZVertexInputBindingDescription) * bindingCount);
                memcpy(newBindings, vis->pVertexBindingDescriptions, sizeof(VkZVertexInputBindingDescription) * bindingCount);
                for (uint32_t j = 0; j < bindingCount; j++) {
                    uint32_t oldStride = newBindings[j].stride;
                    uint32_t newStride = (oldStride + 3) & ~3u;
                    if (newStride != oldStride) {
                        NSLog(@"[ZinkStrideFix] Pipeline %u binding %u: stride %u -> %u",
                              i, j, oldStride, newStride);
                        newBindings[j].stride = newStride;
                    }
                }
                allocedBindings[i] = newBindings;
                newVIS[i].pVertexBindingDescriptions = newBindings;
            }
        }

        newCreateInfos[i].pVertexInputState = &newVIS[i];
    }

    VkZResult result = g_real_vkCreateGraphicsPipelines(device, pipelineCache, createInfoCount, newCreateInfos, pAllocator, pPipelines);

    for (uint32_t i = 0; i < createInfoCount; i++) {
        if (allocedBindings[i]) free(allocedBindings[i]);
        if (allocedAttrs[i]) free(allocedAttrs[i]);
    }
    free(allocedAttrs);
    free(allocedBindings);
    free(newVIS);
    free(newCreateInfos);

    return result;
}

/// 仅对齐 vertex binding stride 到 4 字节（不做格式转换），调用真实函数
/// 供 amethyst_vkCreateGraphicsPipelines 在策略 3 中使用
static VkZResult createPipelinesWithAlignedStrides(
    VkZDevice device, VkZPipelineCache pipelineCache, uint32_t createInfoCount,
    const VkZGraphicsPipelineCreateInfo* pCreateInfos, const void* pAllocator,
    VkZPipeline* pPipelines)
{
    if (!g_real_vkCreateGraphicsPipelines) {
        return VK_Z_ERROR_INITIALIZATION_FAILED;
    }

    NSLog(@"[ZinkStrideFix] Aligning vertex binding strides for %u pipelines", createInfoCount);

    VkZGraphicsPipelineCreateInfo* newCreateInfos = malloc(sizeof(VkZGraphicsPipelineCreateInfo) * createInfoCount);
    VkZPipelineVertexInputStateCreateInfo* newVIS = malloc(sizeof(VkZPipelineVertexInputStateCreateInfo) * createInfoCount);
    VkZVertexInputBindingDescription** allocedBindings = calloc(createInfoCount, sizeof(VkZVertexInputBindingDescription*));

    memcpy(newCreateInfos, pCreateInfos, sizeof(VkZGraphicsPipelineCreateInfo) * createInfoCount);

    for (uint32_t i = 0; i < createInfoCount; i++) {
        const VkZPipelineVertexInputStateCreateInfo* vis = pCreateInfos[i].pVertexInputState;
        if (!vis || !vis->pVertexBindingDescriptions) continue;

        BOOL pipelineNeedsAlignment = NO;
        for (uint32_t j = 0; j < vis->vertexBindingDescriptionCount; j++) {
            if (vis->pVertexBindingDescriptions[j].stride & 3) {
                pipelineNeedsAlignment = YES;
                break;
            }
        }
        if (!pipelineNeedsAlignment) continue;

        uint32_t bindingCount = vis->vertexBindingDescriptionCount;
        VkZVertexInputBindingDescription* newBindings = malloc(sizeof(VkZVertexInputBindingDescription) * bindingCount);
        memcpy(newBindings, vis->pVertexBindingDescriptions, sizeof(VkZVertexInputBindingDescription) * bindingCount);
        for (uint32_t j = 0; j < bindingCount; j++) {
            uint32_t oldStride = newBindings[j].stride;
            uint32_t newStride = (oldStride + 3) & ~3u;
            if (newStride != oldStride) {
                NSLog(@"[ZinkStrideFix] Pipeline %u binding %u: stride %u -> %u", i, j, oldStride, newStride);
                newBindings[j].stride = newStride;
            }
        }
        allocedBindings[i] = newBindings;

        newVIS[i] = *vis;
        newVIS[i].pVertexBindingDescriptions = newBindings;
        newCreateInfos[i].pVertexInputState = &newVIS[i];
    }

    VkZResult result = g_real_vkCreateGraphicsPipelines(device, pipelineCache, createInfoCount, newCreateInfos, pAllocator, pPipelines);

    for (uint32_t i = 0; i < createInfoCount; i++) {
        if (allocedBindings[i]) free(allocedBindings[i]);
    }
    free(allocedBindings);
    free(newVIS);
    free(newCreateInfos);

    return result;
}

/// vkCreateGraphicsPipelines wrapper：尝试多种修复策略确保 pipeline 创建成功
///
/// 修复策略（按顺序尝试）：
///   1. 原始 stride 直接创建（MoltenVK 1.2.9+ 可能已支持未对齐 stride）
///   2. UINT→SINT 格式转换 + 原始 stride（修复 MTLAttributeFormatUShort3 转换错误）
///   3. stride 4 字节对齐（修复 Metal API 硬性要求）
///   4. UINT→SINT 格式转换 + stride 对齐（组合修复）
///   5. dummy pipeline fallback（避免 NULL pipeline 导致 SIGSEGV）
///
/// 关键修复（实体渲染错乱）：
///   之前的实现总是先做 stride 对齐（54→56），但 vertex buffer 数据仍按原始
///   stride 54 排列，导致 MoltenVK 按对齐 stride 56 读取数据但数据布局不匹配，
///   造成实体渲染错乱。
///   新实现优先尝试原始 stride，只有当 MoltenVK 拒绝未对齐 stride 时才回退到
///   stride 对齐。这样在支持未对齐 stride 的 MoltenVK 版本上，stride 与数据
///   布局匹配，渲染正确。
static VkZResult amethyst_vkCreateGraphicsPipelines(
    VkZDevice device, VkZPipelineCache pipelineCache, uint32_t createInfoCount,
    const VkZGraphicsPipelineCreateInfo* pCreateInfos, const void* pAllocator,
    VkZPipeline* pPipelines)
{
    // 首次调用时解析真实函数指针
    if (!g_real_vkCreateGraphicsPipelines) {
        if (g_real_vkGetDeviceProcAddr) {
            g_real_vkCreateGraphicsPipelines = (PFN_zkCreateGraphicsPipelines)
                g_real_vkGetDeviceProcAddr(device, "vkCreateGraphicsPipelines");
        }
        if (!g_real_vkCreateGraphicsPipelines && g_real_vkGetInstanceProcAddr) {
            g_real_vkCreateGraphicsPipelines = (PFN_zkCreateGraphicsPipelines)
                g_real_vkGetInstanceProcAddr((VkZInstance)NULL, "vkCreateGraphicsPipelines");
        }
        if (!g_real_vkCreateGraphicsPipelines) {
            // 通过 amethyst_orig_dlsym 绕过 hook（虽然 hooked_dlsym 不拦截此函数名，
            // 但保持一致性，避免未来扩展 hook 列表时引入递归）
            g_real_vkCreateGraphicsPipelines = (PFN_zkCreateGraphicsPipelines)
                amethyst_orig_dlsym(RTLD_DEFAULT, "vkCreateGraphicsPipelines");
        }
        NSLog(@"[ZinkStrideFix] real vkCreateGraphicsPipelines = %p", (void*)g_real_vkCreateGraphicsPipelines);
    }

    if (!g_real_vkCreateGraphicsPipelines) {
        NSLog(@"[ZinkStrideFix] FATAL: real vkCreateGraphicsPipelines is NULL");
        return VK_Z_ERROR_INITIALIZATION_FAILED;
    }

    // 预检查：是否需要 stride 对齐 / 是否有 UINT 格式
    BOOL needsAlignment = NO;
    for (uint32_t i = 0; i < createInfoCount; i++) {
        const VkZPipelineVertexInputStateCreateInfo* vis = pCreateInfos[i].pVertexInputState;
        if (!vis || !vis->pVertexBindingDescriptions) continue;
        for (uint32_t j = 0; j < vis->vertexBindingDescriptionCount; j++) {
            if (vis->pVertexBindingDescriptions[j].stride & 3) {
                needsAlignment = YES;
                break;
            }
        }
        if (needsAlignment) break;
    }
    BOOL hasUIntFormat = pipelineCreateInfosHaveUIntFormat(createInfoCount, pCreateInfos);

    // ===== 策略 1：原始 stride 直接创建 =====
    // 优先尝试原始 stride，保持 stride 与 vertex buffer 数据布局匹配。
    // MoltenVK 1.2.9+ 可能通过 setVertexBuffer:offset:attributeStride:atIndex:
    // 或其他机制支持未对齐 stride。这是修复实体渲染错乱的关键。
    {
        VkZResult result = g_real_vkCreateGraphicsPipelines(device, pipelineCache, createInfoCount, pCreateInfos, pAllocator, pPipelines);
        if (result == VK_Z_SUCCESS) {
            if (needsAlignment) {
                NSLog(@"[ZinkStrideFix] Pipeline created with original (unaligned) stride - MoltenVK accepted");
            }
            return result;
        }
        NSLog(@"[ZinkStrideFix] Strategy 1 (original stride) failed: %d", result);
        // 清理 pPipelines（失败时 MoltenVK 可能已部分设置）
        for (uint32_t i = 0; i < createInfoCount; i++) pPipelines[i] = NULL;
    }

    // ===== 策略 2：UINT→SINT 格式转换 + 原始 stride =====
    // 修复 MTLAttributeFormatUShort3 转换错误，保持原始 stride
    if (hasUIntFormat) {
        NSLog(@"[ZinkStrideFix] Strategy 2: UINT→SINT format conversion (original stride)");
        VkZResult retryResult = retryPipelineWithSIntFormats(
            device, pipelineCache, createInfoCount, pCreateInfos, pAllocator, pPipelines, NO);
        if (retryResult == VK_Z_SUCCESS) {
            NSLog(@"[ZinkStrideFix] Strategy 2 succeeded (UINT→SINT, original stride)");
            return retryResult;
        }
        NSLog(@"[ZinkStrideFix] Strategy 2 failed: %d", retryResult);
        for (uint32_t i = 0; i < createInfoCount; i++) pPipelines[i] = NULL;
    }

    // ===== 策略 3：stride 4 字节对齐 =====
    // MoltenVK 拒绝未对齐 stride 时，回退到 stride 对齐。
    // 注意：这可能导致 stride 与 vertex buffer 数据布局不匹配，引发渲染错乱。
    // 但可以避免 pipeline 创建失败导致的 SIGSEGV。
    NSLog(@"[ZinkStrideFix] Strategy 3: stride 4-byte alignment");
    {
        VkZResult result = createPipelinesWithAlignedStrides(
            device, pipelineCache, createInfoCount, pCreateInfos, pAllocator, pPipelines);
        if (result == VK_Z_SUCCESS) {
            NSLog(@"[ZinkStrideFix] Strategy 3 succeeded (stride alignment)");
            return result;
        }
        NSLog(@"[ZinkStrideFix] Strategy 3 failed: %d", result);
        for (uint32_t i = 0; i < createInfoCount; i++) pPipelines[i] = NULL;
    }

    // ===== 策略 4：UINT→SINT 格式转换 + stride 对齐 =====
    if (hasUIntFormat) {
        NSLog(@"[ZinkStrideFix] Strategy 4: UINT→SINT + stride alignment");
        VkZResult retryResult = retryPipelineWithSIntFormats(
            device, pipelineCache, createInfoCount, pCreateInfos, pAllocator, pPipelines, YES);
        if (retryResult == VK_Z_SUCCESS) {
            NSLog(@"[ZinkStrideFix] Strategy 4 succeeded (UINT→SINT + stride alignment)");
            return retryResult;
        }
        NSLog(@"[ZinkStrideFix] Strategy 4 failed: %d", retryResult);
        for (uint32_t i = 0; i < createInfoCount; i++) pPipelines[i] = NULL;
    }

    // ===== 策略 5：dummy pipeline fallback =====
    // 所有修复策略都失败，分配 dummy pipeline 避免 NULL pipeline 导致 SIGSEGV。
    // dummy pipeline 的 draw 调用会被我们的 hook 跳过（实体不渲染，但不崩溃）。
    NSLog(@"[ZinkStrideFix] All strategies failed, applying dummy pipeline fallback");
    for (uint32_t i = 0; i < createInfoCount; i++) {
        if (!pPipelines[i]) {
            pPipelines[i] = allocDummyPipeline();
            NSLog(@"[ZinkStrideFix] Pipeline %u: allocated dummy handle %p", i, (void*)pPipelines[i]);
        }
    }
    return VK_Z_SUCCESS;
}

/// vkGetInstanceProcAddr wrapper
/// 拦截 vkGetDeviceProcAddr、vkCreateGraphicsPipelines、vkCmd* 请求，返回我们的 hook
static void* amethyst_vkGetInstanceProcAddr(VkZInstance instance, const char* pName) {
    if (pName) {
        if (strcmp(pName, "vkGetDeviceProcAddr") == 0) {
            if (!g_real_vkGetDeviceProcAddr && g_real_vkGetInstanceProcAddr) {
                g_real_vkGetDeviceProcAddr = (PFN_zkGetDeviceProcAddr)
                    g_real_vkGetInstanceProcAddr(instance, pName);
            }
            return (void*)amethyst_vkGetDeviceProcAddr;
        }
        if (strcmp(pName, "vkCreateGraphicsPipelines") == 0) {
            if (!g_real_vkCreateGraphicsPipelines && g_real_vkGetInstanceProcAddr) {
                g_real_vkCreateGraphicsPipelines = (PFN_zkCreateGraphicsPipelines)
                    g_real_vkGetInstanceProcAddr(instance, pName);
            }
            return (void*)amethyst_vkCreateGraphicsPipelines;
        }
        // vkCmd* hooks（dummy pipeline skip draws）
        if (strcmp(pName, "vkCmdBindPipeline") == 0) {
            if (!g_real_vkCmdBindPipeline && g_real_vkGetInstanceProcAddr) {
                g_real_vkCmdBindPipeline = (PFN_zkCmdBindPipeline)
                    g_real_vkGetInstanceProcAddr(instance, pName);
            }
            return (void*)amethyst_vkCmdBindPipeline;
        }
        if (strcmp(pName, "vkCmdDraw") == 0) {
            if (!g_real_vkCmdDraw && g_real_vkGetInstanceProcAddr) {
                g_real_vkCmdDraw = (PFN_zkCmdDraw)
                    g_real_vkGetInstanceProcAddr(instance, pName);
            }
            return (void*)amethyst_vkCmdDraw;
        }
        if (strcmp(pName, "vkCmdDrawIndexed") == 0) {
            if (!g_real_vkCmdDrawIndexed && g_real_vkGetInstanceProcAddr) {
                g_real_vkCmdDrawIndexed = (PFN_zkCmdDrawIndexed)
                    g_real_vkGetInstanceProcAddr(instance, pName);
            }
            return (void*)amethyst_vkCmdDrawIndexed;
        }
        if (strcmp(pName, "vkCmdDrawIndirect") == 0) {
            if (!g_real_vkCmdDrawIndirect && g_real_vkGetInstanceProcAddr) {
                g_real_vkCmdDrawIndirect = (PFN_zkCmdDrawIndirect)
                    g_real_vkGetInstanceProcAddr(instance, pName);
            }
            return (void*)amethyst_vkCmdDrawIndirect;
        }
        if (strcmp(pName, "vkCmdDrawIndexedIndirect") == 0) {
            if (!g_real_vkCmdDrawIndexedIndirect && g_real_vkGetInstanceProcAddr) {
                g_real_vkCmdDrawIndexedIndirect = (PFN_zkCmdDrawIndexedIndirect)
                    g_real_vkGetInstanceProcAddr(instance, pName);
            }
            return (void*)amethyst_vkCmdDrawIndexedIndirect;
        }
        if (strcmp(pName, "vkCmdDrawIndirectCount") == 0) {
            if (!g_real_vkCmdDrawIndirectCount && g_real_vkGetInstanceProcAddr) {
                g_real_vkCmdDrawIndirectCount = (PFN_zkCmdDrawIndirectCount)
                    g_real_vkGetInstanceProcAddr(instance, pName);
            }
            return (void*)amethyst_vkCmdDrawIndirectCount;
        }
        if (strcmp(pName, "vkCmdDrawIndexedIndirectCount") == 0) {
            if (!g_real_vkCmdDrawIndexedIndirectCount && g_real_vkGetInstanceProcAddr) {
                g_real_vkCmdDrawIndexedIndirectCount = (PFN_zkCmdDrawIndexedIndirectCount)
                    g_real_vkGetInstanceProcAddr(instance, pName);
            }
            return (void*)amethyst_vkCmdDrawIndexedIndirectCount;
        }
        // vkDestroyPipeline hook：dummy pipeline 销毁时跳过，避免 MoltenVK 崩溃
        if (strcmp(pName, "vkDestroyPipeline") == 0) {
            if (!g_real_vkDestroyPipeline && g_real_vkGetInstanceProcAddr) {
                g_real_vkDestroyPipeline = (PFN_zkDestroyPipeline)
                    g_real_vkGetInstanceProcAddr(instance, pName);
            }
            return (void*)amethyst_vkDestroyPipeline;
        }
    }
    if (!g_real_vkGetInstanceProcAddr) {
        // 关键：必须用 amethyst_orig_dlsym 绕过 hooked_dlsym，否则 pName
        // 恰好是 "vkGetInstanceProcAddr" 时会触发无限递归
        return amethyst_orig_dlsym(RTLD_DEFAULT, pName);
    }
    return g_real_vkGetInstanceProcAddr(instance, pName);
}

/// vkGetDeviceProcAddr wrapper
/// 拦截 vkCreateGraphicsPipelines、vkCmd* 请求，返回我们的 hook
static void* amethyst_vkGetDeviceProcAddr(VkZDevice device, const char* pName) {
    if (pName) {
        if (strcmp(pName, "vkCreateGraphicsPipelines") == 0) {
            if (!g_real_vkCreateGraphicsPipelines && g_real_vkGetDeviceProcAddr) {
                g_real_vkCreateGraphicsPipelines = (PFN_zkCreateGraphicsPipelines)
                    g_real_vkGetDeviceProcAddr(device, pName);
            }
            return (void*)amethyst_vkCreateGraphicsPipelines;
        }
        // vkCmd* hooks（dummy pipeline skip draws）
        if (strcmp(pName, "vkCmdBindPipeline") == 0) {
            if (!g_real_vkCmdBindPipeline && g_real_vkGetDeviceProcAddr) {
                g_real_vkCmdBindPipeline = (PFN_zkCmdBindPipeline)
                    g_real_vkGetDeviceProcAddr(device, pName);
            }
            return (void*)amethyst_vkCmdBindPipeline;
        }
        if (strcmp(pName, "vkCmdDraw") == 0) {
            if (!g_real_vkCmdDraw && g_real_vkGetDeviceProcAddr) {
                g_real_vkCmdDraw = (PFN_zkCmdDraw)
                    g_real_vkGetDeviceProcAddr(device, pName);
            }
            return (void*)amethyst_vkCmdDraw;
        }
        if (strcmp(pName, "vkCmdDrawIndexed") == 0) {
            if (!g_real_vkCmdDrawIndexed && g_real_vkGetDeviceProcAddr) {
                g_real_vkCmdDrawIndexed = (PFN_zkCmdDrawIndexed)
                    g_real_vkGetDeviceProcAddr(device, pName);
            }
            return (void*)amethyst_vkCmdDrawIndexed;
        }
        if (strcmp(pName, "vkCmdDrawIndirect") == 0) {
            if (!g_real_vkCmdDrawIndirect && g_real_vkGetDeviceProcAddr) {
                g_real_vkCmdDrawIndirect = (PFN_zkCmdDrawIndirect)
                    g_real_vkGetDeviceProcAddr(device, pName);
            }
            return (void*)amethyst_vkCmdDrawIndirect;
        }
        if (strcmp(pName, "vkCmdDrawIndexedIndirect") == 0) {
            if (!g_real_vkCmdDrawIndexedIndirect && g_real_vkGetDeviceProcAddr) {
                g_real_vkCmdDrawIndexedIndirect = (PFN_zkCmdDrawIndexedIndirect)
                    g_real_vkGetDeviceProcAddr(device, pName);
            }
            return (void*)amethyst_vkCmdDrawIndexedIndirect;
        }
        if (strcmp(pName, "vkCmdDrawIndirectCount") == 0) {
            if (!g_real_vkCmdDrawIndirectCount && g_real_vkGetDeviceProcAddr) {
                g_real_vkCmdDrawIndirectCount = (PFN_zkCmdDrawIndirectCount)
                    g_real_vkGetDeviceProcAddr(device, pName);
            }
            return (void*)amethyst_vkCmdDrawIndirectCount;
        }
        if (strcmp(pName, "vkCmdDrawIndexedIndirectCount") == 0) {
            if (!g_real_vkCmdDrawIndexedIndirectCount && g_real_vkGetDeviceProcAddr) {
                g_real_vkCmdDrawIndexedIndirectCount = (PFN_zkCmdDrawIndexedIndirectCount)
                    g_real_vkGetDeviceProcAddr(device, pName);
            }
            return (void*)amethyst_vkCmdDrawIndexedIndirectCount;
        }
        // vkDestroyPipeline hook：dummy pipeline 销毁时跳过，避免 MoltenVK 崩溃
        if (strcmp(pName, "vkDestroyPipeline") == 0) {
            if (!g_real_vkDestroyPipeline && g_real_vkGetDeviceProcAddr) {
                g_real_vkDestroyPipeline = (PFN_zkDestroyPipeline)
                    g_real_vkGetDeviceProcAddr(device, pName);
            }
            return (void*)amethyst_vkDestroyPipeline;
        }
    }
    if (!g_real_vkGetDeviceProcAddr) {
        // 关键：必须用 amethyst_orig_dlsym 绕过 hooked_dlsym，否则 pName
        // 恰好是 "vkGetDeviceProcAddr" 时会触发无限递归
        return amethyst_orig_dlsym(RTLD_DEFAULT, pName);
    }
    return g_real_vkGetDeviceProcAddr(device, pName);
}

/// vkCmdBindPipeline hook
/// 跟踪当前绑定的 graphics pipeline，dummy pipeline 跳过实际绑定
static void amethyst_vkCmdBindPipeline(VkZCommandBuffer cmd, VkZPipelineBindPoint bp, VkZPipeline pipeline) {
    if (bp == VK_Z_PIPELINE_BIND_POINT_GRAPHICS) {
        g_currentBoundGraphicsPipeline = pipeline;
        if (isDummyPipeline(pipeline)) {
            // Dummy pipeline：跳过实际绑定，避免 MoltenVK 因无效句柄崩溃
            return;
        }
    }
    if (g_real_vkCmdBindPipeline) {
        g_real_vkCmdBindPipeline(cmd, bp, pipeline);
    }
}

/// vkCmdDraw hook：当前绑定 dummy pipeline 时跳过绘制
static void amethyst_vkCmdDraw(VkZCommandBuffer cmd, uint32_t vertexCount, uint32_t instanceCount, uint32_t firstVertex, uint32_t firstInstance) {
    if (isDummyPipeline(g_currentBoundGraphicsPipeline)) return;
    if (g_real_vkCmdDraw) g_real_vkCmdDraw(cmd, vertexCount, instanceCount, firstVertex, firstInstance);
}

/// vkCmdDrawIndexed hook：当前绑定 dummy pipeline 时跳过绘制
static void amethyst_vkCmdDrawIndexed(VkZCommandBuffer cmd, uint32_t indexCount, uint32_t instanceCount, uint32_t firstIndex, int32_t vertexOffset, uint32_t firstInstance) {
    if (isDummyPipeline(g_currentBoundGraphicsPipeline)) return;
    if (g_real_vkCmdDrawIndexed) g_real_vkCmdDrawIndexed(cmd, indexCount, instanceCount, firstIndex, vertexOffset, firstInstance);
}

/// vkCmdDrawIndirect hook：当前绑定 dummy pipeline 时跳过绘制
static void amethyst_vkCmdDrawIndirect(VkZCommandBuffer cmd, uint64_t buffer, uint64_t offset, uint32_t drawCount, uint32_t stride) {
    if (isDummyPipeline(g_currentBoundGraphicsPipeline)) return;
    if (g_real_vkCmdDrawIndirect) g_real_vkCmdDrawIndirect(cmd, buffer, offset, drawCount, stride);
}

/// vkCmdDrawIndexedIndirect hook：当前绑定 dummy pipeline 时跳过绘制
static void amethyst_vkCmdDrawIndexedIndirect(VkZCommandBuffer cmd, uint64_t buffer, uint64_t offset, uint32_t drawCount, uint32_t stride) {
    if (isDummyPipeline(g_currentBoundGraphicsPipeline)) return;
    if (g_real_vkCmdDrawIndexedIndirect) g_real_vkCmdDrawIndexedIndirect(cmd, buffer, offset, drawCount, stride);
}

/// vkCmdDrawIndirectCount hook：当前绑定 dummy pipeline 时跳过绘制
static void amethyst_vkCmdDrawIndirectCount(VkZCommandBuffer cmd, uint64_t buffer, uint64_t offset, uint64_t countBuffer, uint64_t countBufferOffset, uint32_t maxDrawCount, uint32_t stride) {
    if (isDummyPipeline(g_currentBoundGraphicsPipeline)) return;
    if (g_real_vkCmdDrawIndirectCount) g_real_vkCmdDrawIndirectCount(cmd, buffer, offset, countBuffer, countBufferOffset, maxDrawCount, stride);
}

/// vkCmdDrawIndexedIndirectCount hook：当前绑定 dummy pipeline 时跳过绘制
static void amethyst_vkCmdDrawIndexedIndirectCount(VkZCommandBuffer cmd, uint64_t buffer, uint64_t offset, uint64_t countBuffer, uint64_t countBufferOffset, uint32_t maxDrawCount, uint32_t stride) {
    if (isDummyPipeline(g_currentBoundGraphicsPipeline)) return;
    if (g_real_vkCmdDrawIndexedIndirectCount) g_real_vkCmdDrawIndexedIndirectCount(cmd, buffer, offset, countBuffer, countBufferOffset, maxDrawCount, stride);
}

/// vkDestroyPipeline hook：销毁 dummy pipeline 时跳过，避免 MoltenVK 解引用 magic handle 崩溃
/// 关键修复：切换 shaderpack 时 zink 会销毁所有旧 pipelines，包括 dummy pipeline
/// 句柄（0xDEAD0001 等）。MoltenVK 的 vkDestroyPipeline 会解引用 pipeline 指针
/// 查找内部资源，dummy handle 是无效指针，导致 SIGSEGV。
static void amethyst_vkDestroyPipeline(VkZDevice device, VkZPipeline pipeline, const void* pAllocator) {
    if (isDummyPipeline(pipeline)) {
        // Dummy pipeline：跳过销毁，避免 MoltenVK 崩溃
        // 同时从 dummy pipeline 集合中移除（避免集合无限增长）
        uintptr_t val = (uintptr_t)pipeline;
        for (uint32_t i = 0; i < g_dummyPipelineCount; i++) {
            if (g_dummyPipelines[i] == val) {
                // 用最后一个元素填补空洞（顺序无关紧要，数组只是用于查找）
                g_dummyPipelines[i] = g_dummyPipelines[g_dummyPipelineCount - 1];
                g_dummyPipelineCount--;
                break;
            }
        }
        // 如果正在销毁的 dummy pipeline 恰好是当前绑定的，清除绑定状态
        if (g_currentBoundGraphicsPipeline == pipeline) {
            g_currentBoundGraphicsPipeline = NULL;
        }
        return;
    }
    if (g_real_vkDestroyPipeline) g_real_vkDestroyPipeline(device, pipeline, pAllocator);
}

/// 内部：执行 fishhook 重绑定（可在新 image 加载后重复调用以捕获新引用）
/// fishhook 的 rebind_symbols 是幂等的——会遍历所有已加载 image 并重绑定
/// vkGetInstanceProcAddr / vkGetDeviceProcAddr 的引用到我们的 wrapper。
/// 使用静态存储的 rebindings 数组（避免栈上局部变量在 future-image 加载时 UAF：
/// fishhook 会保留 rebindings 用于后续 dlopen 加载的 image）。
static void zinkStrideFixRebind(void) {
    static struct rebinding rebindings[] = {
        {"vkGetInstanceProcAddr", (void*)amethyst_vkGetInstanceProcAddr, (void**)&g_real_vkGetInstanceProcAddr},
        {"vkGetDeviceProcAddr", (void*)amethyst_vkGetDeviceProcAddr, (void**)&g_real_vkGetDeviceProcAddr},
    };
    rebind_symbols(rebindings, sizeof(rebindings)/sizeof(struct rebinding));
}

/// 安装 zink vertex stride 对齐 fix
/// 仅在 zink 渲染器被选中时激活。通过 fishhook 重绑定符号引用，
/// 并通过 hooked_dlsym 拦截 dlsym 查找（双重机制确保覆盖所有调用路径）。
void installZinkStrideFix(void) {
    if (g_zinkStrideFixActive) return;

    const char* renderer = getenv("AMETHYST_RENDERER");
    if (!renderer || !strstr(renderer, "libOSMesa")) {
        NSLog(@"[ZinkStrideFix] Skipped (zink not selected, AMETHYST_RENDERER=%s)",
              renderer ? renderer : "(null)");
        return;
    }

    g_zinkStrideFixActive = YES;

    // 初次重绑定（捕获当前已加载 image 的引用，主要是启动器主二进制）
    zinkStrideFixRebind();

    NSLog(@"[ZinkStrideFix] Installed vertex stride alignment hooks for zink (Mesa 25.0.7 + MoltenVK)");
}

/// 在新 image（特别是 libOSMesa / libMoltenVK）加载后调用，重新执行 fishhook
/// 以捕获新 image 对 vkGetInstanceProcAddr / vkGetDeviceProcAddr 的符号引用。
/// 由 hooked_dlopen 在检测到 libOSMesa 加载时调用。
void rebindZinkStrideFixForNewImage(void) {
    if (!g_zinkStrideFixActive) return;
    zinkStrideFixRebind();
    NSLog(@"[ZinkStrideFix] Re-rebound Vulkan symbols for newly loaded image");
}

/// dlsym hook：拦截 Vulkan loader 函数请求，返回我们的 wrapper
///
/// 仅拦截 zink stride fix 相关函数：
///   - vkGetInstanceProcAddr → 返回 amethyst_vkGetInstanceProcAddr
///     （拦截 vkCreateGraphicsPipelines 调用，强制 stride 4 字节对齐）
///   - vkGetDeviceProcAddr → 返回 amethyst_vkGetDeviceProcAddr
///     （跟踪 dummy pipeline）
///
/// 其他函数正常返回 orig_dlsym 的结果，避免日志爆炸。

// MARK: - shaderc 编译重定向到 32MB 栈线程（MC 26.3 RenderPearl）
//
// MC 26.3 起 RenderPearl 用 LWJGL 的 shaderc 绑定在游戏线程上直接编译 GLSL
// （shaderc_compile_into_spv / _spv_assembly / _preprocessed_text 三个入口，
// dlsym 解析自 libshaderc.dylib，内含 glslang）。glslang 的解析与 AST 遍历是
// 深递归、帧大、深度不可控，实测在 JVM 1MB 线程栈上 SIGSEGV —— 崩溃点
// glslang::TParseContext::lValueErrorCheck+0x204（设备日志，构建 662d6e2，
// JVM Flags 含 iOS OpenJDK 运行时注入的 -Xss1M）。
//
// 26.3-pre-1 真机第二击（hs_err_pid27118）：重定向生效后，glslang 首次读源码
// 就 SEGV_ACCERR @ 0x143ed900 —— sources[0] 指针与长度 0x278 均自洽，但该页
// 已无读权限。反汇编 stub 字节码证实：MC 把 GLSL 源文本经 MemoryStack.nUTF8
// 编码进 LWJGL MemoryStack 的 direct ByteBuffer（HotSpot native 内存），指针
// 由 getPointerAddress() 计算后传给我们。该缓冲页的生命周期归 JVM/Cleaner
// 管：我们把编译 hop 到 32MB 栈线程后原线程阻塞等待，等待窗口内 JVM 侧的
// GC（实测 3.3s 内 24 次 young GC）/Cleaner/运行时可能回收或去提交该页，
// job 线程随后读取 → SEGV_ACCERR。
//
// 修复：在调用方线程上（此刻源码页刚被 nUTF8 写入、必然可读）先把 source /
// input_file / entry_point 快照进 malloc 副本，job 线程全程只触碰副本；spvc
// 两个入口同理 —— 输出槽（parsed_ir / glsl 输出指针位）原本也指向 JVM 侧
// 内存，改用本地槽承载 job 线程写入，join 后由调用方线程回写。
//
// MobileGlues 自己的转换管线早已为同一批着色器配备了专用 32MB 栈线程（设备
// 日志原文 "dedicated 32MB-stack thread"），证明该库家族需要这一栈预算。
// shaderc 的编译入口是线程安全 API，参数与返回值均为裸指针/标量，跨线程
// 传递无副作用；GLSL emission 与结果访问器均作用在堆对象上，线程亲和性无关。
//
// 26.3-pre-1 真机第三击（hs_err_pid27240，快照修复 3d0b882a 之后）：首个编译
// 任务日志 "source=0x278 size=0" —— 暴露快照读到了错位槽。旧 typedef 把 kind
// 写在 source 之前（与 shaderc.h ABI 的 source_text/source_size/shader_kind
// 顺序不符）：474b71d3 时代无快照、纯按位置转发，错位在机器层自相抵消
// （pid27118 的源指针 <4GB，流经 int kind 槽截断后侥幸自洽，遂未察觉）；
// 3d0b882a 的快照按"形参名"取值后，两个恶果同时显形：
//   1) source 槽实际装的是 source_size(0x278)、source_size 槽装的是
//      shader_kind(0=vertex) → 快照 memcpy(0x278, 0 字节) = 空转；
//   2) 真实 64 位 source 指针流经 int kind 槽被截断成 32 位
//      （0x14007c000 → 0x4007c000，恰落入 JVM 保留未提交区），job 线程
//      首次读源码即 SEGV_ACCERR。
// 修复：typedef 改为与 shaderc.h 公开 ABI 严格一致
//   (compiler, source_text, source_size, shader_kind, input_file_name,
//    entry_point_name, additional_options)
// 类型与位置双重对齐后，快照取的是真源码、64 位指针不再流经 32 位槽。
// 此前 snapshot-10 未触发是因为该版本不走 RenderPearl 的 shaderc 编译路径
// —— dlsym 拦截日志只证明符号被解析，不代表函数被调用。
//
// 26.3-pre-1 真机第五击（hs_err_pid27946，构建 744642f2，Task 30 判读）：
// shaderc 首批 8 次编译 + MG 转换全部成功、首帧已渲染；第 9 次编译（LWJGL
// Java 直调路径，经本 wrapper → shaderc-shim → impl）在
// glslang::TParseContext::lValueErrorCheck+0x204 崩。反汇编（impl dylib 本地
// 复核）：EOpVectorSwizzle 分支的 swizzle 重复分量检查循环里
// `(*p)->getAsTyped()->getAsConstantUnion()->getConstArray()[0]` 链条，
// TIntermConstantUnion 对象偏移 +0xd8 的 constArray 指针字段装着 8 字节 ASCII
// （si_addr=0x66617263656e6900 ≈ "\0inceraf"）——池内存被释放后又被字符串
// 分配复用的特征，非栈溢出（32MB 栈 free=32705k）。
// 修复职责分层：本文件维持快照 + 32MB hop + 逐编译取证日志；
// shaderc/spvc **生命周期入口**（compiler/options 的 initialize/release/
// clone/add_macro_definition、spvc context destroy 族）由 shaderc_shim.c /
// spvc_shim.c 纳入编译同一把锁——release-vs-compile 竞态（MC 资源重载 = 旧
// RenderPearl 管线释放 + 新管线并发编译）是当前主嫌疑，MobileGlues 侧另加
// 转换进程级互斥（见 MobileGlues-cpp/gl/glsl/glsl_for_es.cpp）。
// options 结构体为 impl 私有不透明类型无法深拷贝；其内嵌宏名/宏值在
// add_macro_definition 时已由 impl 拷贝为自有内存，危险面是 options 结构
// 本体被并发 release——已由 shim 锁关闭。
//
// 对 26.3 之前版本无影响：只有真正 dlsym 请求这些符号的代码（LWJGL 的
// shaderc / spvc 绑定）才会被包装。与 JavaLauncher.m 的 -Xss32M 形成双保险
// —— 即便运行时注入的 -Xss1M 覆盖了我们的参数，本重定向仍按构造生效。

typedef void *(*ame_shaderc_compile_fn)(void *compiler, const char *source,
                                        size_t source_size, int kind,
                                        const char *input_file,
                                        const char *entry_point, void *options);

typedef int (*ame_spvc_parse_fn)(void *context, const unsigned *spirv, size_t word_count,
                                 void **parsed_ir);
typedef int (*ame_spvc_compile_fn)(void *compiler, const char **source);

static ame_shaderc_compile_fn g_real_shaderc_into_spv = NULL;
static ame_shaderc_compile_fn g_real_shaderc_into_spv_assembly = NULL;
static ame_shaderc_compile_fn g_real_shaderc_into_preprocessed_text = NULL;
static ame_spvc_parse_fn     g_real_spvc_parse_spirv = NULL;
static ame_spvc_compile_fn   g_real_spvc_compiler_compile = NULL;

// 通用"在 32MB 栈线程上执行 job->main_fn 并 join"的底座。
// 返回 false = pthread_create 失败（调用方退回原线程直跑）。
static bool ame_run_on_32mb_stack(void *(*main_fn)(void *), void *job) {
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 32ull * 1024ull * 1024ull);
    pthread_t tid;
    int rc = pthread_create(&tid, &attr, main_fn, job);
    pthread_attr_destroy(&attr);
    if (rc != 0) return false;
    pthread_join(tid, NULL);
    return true;
}

static void ame_log_redirect_once(const char *tag) {
    static bool sLogged[2] = {false, false};
    bool *logged = (strcmp(tag, "shaderc") == 0) ? &sLogged[0] : &sLogged[1];
    if (!*logged) {
        *logged = true;
        NSLog(@"[%s] redirecting compiles to a 32MB-stack thread "
              @"(glslang/spirv-cross deep recursion overflows the JVM 1MB stack)", tag);
    }
}

// ---- shaderc（GLSL → SPIR-V）----

typedef struct {
    ame_shaderc_compile_fn fn;
    void      *compiler;
    const char *source;
    size_t     source_size;
    int        kind;
    const char *input_file;
    const char *entry_point;
    void       *options;
    void       *result;
} ame_shaderc_job;

static void *ame_shaderc_job_main(void *arg) {
    ame_shaderc_job *job = (ame_shaderc_job *)arg;
    job->result = job->fn(job->compiler, job->source, job->source_size, job->kind,
                          job->input_file, job->entry_point, job->options);
    return NULL;
}

// 调用方线程上的参数快照工具：job 线程绝不直接触碰 JVM 侧内存。
static char *ame_copy_bytes(const void *src, size_t n) {
    char *copy = (char *)malloc(n != 0 ? n : 1);
    if (copy == NULL) return NULL;
    if (n != 0) memcpy(copy, src, n);
    return copy;
}

// C 字符串副本（strnlen 限界，防失控扫描；含 NUL 结尾）。
static char *ame_copy_cstr(const char *src, size_t limit) {
    if (src == NULL) return NULL;
    return ame_copy_bytes(src, strnlen(src, limit) + 1);
}

static void *ame_shaderc_run_on_big_stack(ame_shaderc_compile_fn real, void *compiler,
                                          const char *source, size_t source_size, int kind,
                                          const char *input_file, const char *entry_point,
                                          void *options) {
    ame_log_redirect_once("shaderc");
    // Task 30 取证日志（hs_err_pid27946）：逐编译打印全参数（长度/文件名/入口名/
    // options 指针 + source 头 16 字节安全转写）。下轮崩溃日志可据此直接指认：
    // 崩溃的是第几次编译、参数是否来自已释放内存（对照 [shaderc-shim] 的
    // options_release / compiler_release 行与 BLOCKED 行）。
    static int sCompileSeq = 0;
    int seq = __sync_fetch_and_add(&sCompileSeq, 1);
    char head[17];
    head[0] = '\0';
    if (source != NULL && source_size > 0) {
        size_t n = (source_size < 16) ? source_size : 16;
        for (size_t i = 0; i < n; ++i) {
            unsigned char c = (unsigned char)source[i];
            head[i] = (c >= 0x20 && c < 0x7f) ? (char)c : '.';
        }
        head[n] = '\0';
    }
    // 截断 C 字符串副本（防止超长文件名刷爆 latestlog 管道窗口）。
    char inBuf[49], epBuf[33];
    snprintf(inBuf, sizeof(inBuf), "%s", input_file ? input_file : "(null)");
    snprintf(epBuf, sizeof(epBuf), "%s", entry_point ? entry_point : "(null)");
    NSLog(@"[shaderc] compile#%d snapshot: len=%zu kind=%d in='%s' entry='%s' opt=%p "
          @"head16='%s' (source snapshot + 32MB-stack hop)",
          seq, source_size, kind, inBuf, epBuf, options, head);

    // 1) 调用方线程上快照输入：此刻源码页刚被 nUTF8 写入，必然可读。
    char *source_copy = (source != NULL) ? ame_copy_bytes(source, source_size) : NULL;
    char *input_file_copy = ame_copy_cstr(input_file, 8192);
    char *entry_point_copy = ame_copy_cstr(entry_point, 256);

    // malloc 失败时回退用原指针（OOM 极端场景，行为同旧版）。
    ame_shaderc_job job = {
        real, compiler,
        (source_copy != NULL) ? source_copy : source, source_size, kind,
        (input_file_copy != NULL) ? input_file_copy : input_file,
        (entry_point_copy != NULL) ? entry_point_copy : entry_point,
        options, NULL};

    bool ok = ame_run_on_32mb_stack(ame_shaderc_job_main, &job);

    // 2) job 已 join，副本生命周期结束。
    free(source_copy);
    free(input_file_copy);
    free(entry_point_copy);

    if (ok) return job.result;
    NSLog(@"[shaderc] pthread_create failed, falling back to caller thread");
    return real(compiler, source, source_size, kind, input_file, entry_point, options);
}

static void *amethyst_shaderc_into_spv(void *compiler, const char *source,
                                       size_t source_size, int kind,
                                       const char *input_file,
                                       const char *entry_point, void *options) {
    return ame_shaderc_run_on_big_stack(g_real_shaderc_into_spv, compiler, source,
                                        source_size, kind, input_file, entry_point, options);
}

static void *amethyst_shaderc_into_spv_assembly(void *compiler, const char *source,
                                                size_t source_size, int kind,
                                                const char *input_file,
                                                const char *entry_point, void *options) {
    return ame_shaderc_run_on_big_stack(g_real_shaderc_into_spv_assembly, compiler, source,
                                        source_size, kind, input_file, entry_point, options);
}

static void *amethyst_shaderc_into_preprocessed_text(void *compiler, const char *source,
                                                     size_t source_size, int kind,
                                                     const char *input_file,
                                                     const char *entry_point, void *options) {
    return ame_shaderc_run_on_big_stack(g_real_shaderc_into_preprocessed_text, compiler, source,
                                        source_size, kind, input_file, entry_point, options);
}

// ---- spvc（SPIR-V → 桌面 GLSL）----
//
// RenderPearl 的跨后端管线：游戏 GLSL 经 shaderc 编为 SPIR-V 作为核心 IR；
// GLES 无 GL_ARB_gl_spirv，GL 后端必须用 spvc 把 IR 重新发射成桌面 GLSL
// （MG 日志里收到的 "#version 330" 即此产物），再由 MobileGlues 转成 ESSL。
// spvc_context_parse_spirv / spvc_compiler_compile 与 shaderc 同族（glslang /
// spirv-cross 深递归），一并重定向。

typedef struct {
    ame_spvc_parse_fn fn;
    void       *context;
    const unsigned *spirv;
    size_t      word_count;
    void      **parsed_ir;
    int         rc;
} ame_spvc_parse_job;

static void *ame_spvc_parse_job_main(void *arg) {
    ame_spvc_parse_job *job = (ame_spvc_parse_job *)arg;
    job->rc = job->fn(job->context, job->spirv, job->word_count, job->parsed_ir);
    return NULL;
}

typedef struct {
    ame_spvc_compile_fn fn;
    void       *compiler;
    const char **source;
    int         rc;
} ame_spvc_compile_job;

static void *ame_spvc_compile_job_main(void *arg) {
    ame_spvc_compile_job *job = (ame_spvc_compile_job *)arg;
    job->rc = job->fn(job->compiler, job->source);
    return NULL;
}

static int amethyst_spvc_parse_spirv(void *context, const unsigned *spirv, size_t word_count,
                                     void **parsed_ir) {
    ame_log_redirect_once("spvc");
    // 同 shaderc：输入 SPIR-V 可能也在 JVM 侧可回收内存里；输出槽（parsed_ir
    // 指向的指针位）同样如此。job 线程全程用副本/本地槽，join 后在调用方线程回写。
    unsigned *spirv_copy = (spirv != NULL && word_count != 0)
        ? (unsigned *)ame_copy_bytes(spirv, word_count * sizeof(unsigned)) : NULL;
    void *ir_slot = NULL;

    ame_spvc_parse_job job = {g_real_spvc_parse_spirv, context,
                              (spirv_copy != NULL) ? spirv_copy : spirv, word_count,
                              &ir_slot, 0};
    bool ok = ame_run_on_32mb_stack(ame_spvc_parse_job_main, &job);
    free(spirv_copy);
    if (!ok) {
        NSLog(@"[spvc] pthread_create failed, falling back to caller thread");
        return g_real_spvc_parse_spirv(context, spirv, word_count, parsed_ir);
    }
    if (parsed_ir != NULL) *parsed_ir = ir_slot;
    return job.rc;
}

static int amethyst_spvc_compiler_compile(void *compiler, const char **source) {
    ame_log_redirect_once("spvc");
    // 同上：spvc 把发射的 GLSL 指针写进 *source（JVM 侧内存），改用本地槽承载
    // job 线程写入，join 后回写。
    const char *out = NULL;
    ame_spvc_compile_job job = {g_real_spvc_compiler_compile, compiler, &out, 0};
    if (ame_run_on_32mb_stack(ame_spvc_compile_job_main, &job)) {
        if (source != NULL) *source = out;
        return job.rc;
    }
    NSLog(@"[spvc] pthread_create failed, falling back to caller thread");
    return g_real_spvc_compiler_compile(compiler, source);
}

void* hooked_dlsym(void* handle, const char* name) {
    // Task 133：入口镜像扫描（兜底触发面）——即使 dlopen 链因意外形态
    // 失守（如 JVM 库换了名字/路径），启动器自身的高频 dlsym（egl_bridge/
    // gl_bridge/initSDLEventFuncs 等符号解析）也会在 controlify 初始化
    // 之前把已加载的 libjli/libjvm/libjnidispatch 绑进 hook。增量游标，
    // 无新镜像时开销 = 一次 dyld 计数调用。
    amethyst_task133_ensure_jvm_chain();
    // SDL3 兼容层：建窗前强制 ES profile、主窗口复用、EGL 兼容重试、
    // Vulkan loader 句柄共享。返回非 NULL 表示已接管该符号。
    {
        void *ame_p = amethyst_sdl3_hook_resolve(handle, name);
        if (ame_p != NULL) return ame_p;
    }
    // MC 26.3 用 SDL3，通过 SDL_SetWindowRelativeMouseMode 切换抓取状态。
    // LWJGL 是 dlsym 取函数指针后直接调用（不走 __la_symbol_ptr，fishhook 拦不住），
    // 所以必须在这里拦截。这样 MC 一调用就同步，不再依赖触摸轮询。
    if (name != NULL && strcmp(name, "SDL_SetWindowRelativeMouseMode") == 0) {
        if (!g_real_SDL_SetWindowRelativeMouseMode) {
            g_real_SDL_SetWindowRelativeMouseMode = (bool (*)(void *, bool))orig_dlsym(handle, name);
        }
        NSLog(@"[InputDiag] dlsym intercepted: SDL_SetWindowRelativeMouseMode -> hook (real=%p)",
              (void *)g_real_SDL_SetWindowRelativeMouseMode);
        return (void *)amethyst_SDL_SetWindowRelativeMouseMode;
    }
    if (name != NULL && strcmp(name, "SDL_SetWindowMouseGrab") == 0) {
        if (!g_real_SDL_SetWindowMouseGrab) {
            g_real_SDL_SetWindowMouseGrab = (bool (*)(void *, bool))orig_dlsym(handle, name);
        }
        NSLog(@"[InputDiag] dlsym intercepted: SDL_SetWindowMouseGrab -> hook (real=%p)",
              (void *)g_real_SDL_SetWindowMouseGrab);
        return (void *)amethyst_SDL_SetWindowMouseGrab;
    }
    // 诊断：记录 MC 查询了哪些其它 SDL 鼠标/抓取相关 API，便于判断它实际用了哪条路径
    if (name != NULL && strncmp(name, "SDL_Set", 7) == 0 &&
        (strstr(name, "Mouse") != NULL || strstr(name, "Relative") != NULL)) {
        NSLog(@"[InputDiag] dlsym query: %s", name);
    }

    // SDL3 OpenGL 装载：见上方 amethyst_SDL_GL_LoadLibrary 的说明
    if (name != NULL && strcmp(name, "SDL_GL_LoadLibrary") == 0) {
        if (!g_real_SDL_GL_LoadLibrary) {
            g_real_SDL_GL_LoadLibrary = (PFN_SDL_GL_LoadLibrary)orig_dlsym(handle, name);
            g_real_SDL_GetError = (PFN_SDL_GetError)orig_dlsym(handle, "SDL_GetError");
        }
        NSLog(@"[SDLGL] dlsym intercepted: SDL_GL_LoadLibrary (real=%p)",
              (void *)g_real_SDL_GL_LoadLibrary);
        return (void *)amethyst_SDL_GL_LoadLibrary;
    }
    if (name != NULL && strcmp(name, "SDL_GL_SetAttribute") == 0) {
        if (!g_real_SDL_GL_SetAttribute) {
            g_real_SDL_GL_SetAttribute = (PFN_SDL_GL_SetAttribute)orig_dlsym(handle, name);
        }
        return (void *)amethyst_SDL_GL_SetAttribute;
    }
    // 诊断：记录 MC 查询了哪些 SDL_GL_* 入口，用于判断它实际走的上下文路径
    if (name != NULL && strncmp(name, "SDL_GL_", 7) == 0) {
        NSLog(@"[SDLGL] dlsym query: %s", name);
    }

    // shaderc / spvc 编译入口 → 32MB 栈线程重定向（见上方 MARK 注释）。
    // LWJGL 3.4.1 绑定恰好只 dlsym 这五个入口（三个 shaderc 编译 + 两个 spvc 重活）。
    if (name != NULL && strncmp(name, "shaderc_compile_into_", 21) == 0) {
        ame_shaderc_compile_fn *slot = NULL;
        void *wrapper = NULL;
        if (strcmp(name, "shaderc_compile_into_spv") == 0) {
            slot = &g_real_shaderc_into_spv;
            wrapper = (void *)amethyst_shaderc_into_spv;
        } else if (strcmp(name, "shaderc_compile_into_spv_assembly") == 0) {
            slot = &g_real_shaderc_into_spv_assembly;
            wrapper = (void *)amethyst_shaderc_into_spv_assembly;
        } else if (strcmp(name, "shaderc_compile_into_preprocessed_text") == 0) {
            slot = &g_real_shaderc_into_preprocessed_text;
            wrapper = (void *)amethyst_shaderc_into_preprocessed_text;
        }
        if (slot != NULL) {
            if (*slot == NULL) {
                *slot = (ame_shaderc_compile_fn)orig_dlsym(handle, name);
            }
            if (*slot == NULL) return NULL;  // 真实符号缺失：保持原有失败语义
            NSLog(@"[shaderc] dlsym intercepted: %s -> 32MB-stack wrapper (real=%p)",
                  name, (void *)*slot);
            return wrapper;
        }
    }
    if (name != NULL && (strcmp(name, "spvc_context_parse_spirv") == 0 ||
                         strcmp(name, "spvc_compiler_compile") == 0)) {
        NSLog(@"[spvc] dlsym intercepted: %s -> 32MB-stack wrapper", name);
        if (strcmp(name, "spvc_context_parse_spirv") == 0) {
            if (g_real_spvc_parse_spirv == NULL) {
                g_real_spvc_parse_spirv = (ame_spvc_parse_fn)orig_dlsym(handle, name);
            }
            if (g_real_spvc_parse_spirv == NULL) return NULL;
            return (void *)amethyst_spvc_parse_spirv;
        } else {
            if (g_real_spvc_compiler_compile == NULL) {
                g_real_spvc_compiler_compile = (ame_spvc_compile_fn)orig_dlsym(handle, name);
            }
            if (g_real_spvc_compiler_compile == NULL) return NULL;
            return (void *)amethyst_spvc_compiler_compile;
        }
    }

    if (name != NULL && g_zinkStrideFixActive) {
        if (strcmp(name, "vkGetInstanceProcAddr") == 0) {
            if (!g_real_vkGetInstanceProcAddr) {
                g_real_vkGetInstanceProcAddr = (PFN_zkGetInstanceProcAddr)orig_dlsym(handle, name);
            }
            NSLog(@"[ZinkStrideFix] dlsym intercepted: vkGetInstanceProcAddr -> hook");
            return (void*)amethyst_vkGetInstanceProcAddr;
        }
        if (strcmp(name, "vkGetDeviceProcAddr") == 0) {
            if (!g_real_vkGetDeviceProcAddr) {
                g_real_vkGetDeviceProcAddr = (PFN_zkGetDeviceProcAddr)orig_dlsym(handle, name);
            }
            NSLog(@"[ZinkStrideFix] dlsym intercepted: vkGetDeviceProcAddr -> hook");
            return (void*)amethyst_vkGetDeviceProcAddr;
        }
    }
    return orig_dlsym(handle, name);
}

int hooked_open(const char *path, int oflag, ...) {
    va_list args;
    va_start(args, oflag);
    mode_t mode = va_arg(args, int);
    va_end(args);
    if (path && !strcmp(path, "/etc/resolv.conf")) {
        return orig_open([NSString stringWithFormat:@"%s/resolv.conf", getenv("POJAV_HOME")].UTF8String, oflag, mode);
    }

    return orig_open(path, oflag, mode);
}

void init_hookFunctions() {
    struct rebinding rebindings[] = (struct rebinding[]){
        {"abort", hooked_abort, (void *)&orig_abort},
        {"__assert_rtn", hooked___assert_rtn, NULL},
        {"exit", hooked_exit, (void *)&orig_exit},
        {"dlopen", hooked_dlopen, (void *)&orig_dlopen},
        {"dlsym", hooked_dlsym, (void *)&orig_dlsym},
        {"open", hooked_open, (void *)&orig_open},
    };
    rebind_symbols(rebindings, sizeof(rebindings)/sizeof(struct rebinding));
}
