#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import "SurfaceViewController.h"
#import "LauncherPreferences.h"

#include <dlfcn.h>
#include <string.h>
#include <time.h>
#include <stdatomic.h>
#include "bridge_tbl.h"
#include "environ.h"
#include "gl_bridge.h"
#include "utils.h"

// ---------------------------------------------------------------------------
// 兼容垫片：Amethyst_SDL3SurfaceWantsPoints()
//
// Air Task 60（664f58a3）已定案：本函数代表的「1x 点数对齐」（Task 50）退役，
// 恒返回 NO 让 1x 分支全部走不通（Air 侧连函数都已删除）。本仓库历史上由
// sdl3_hook / SurfaceViewController 引用过它，为免对齐 Air 的 gl_bridge 后
// 出现未定义符号，这里保留一个恒 NO 的导出实现；当前唯一调用点已按 Air
// 移除，保留它只是 ABI 保险，不改变任何行为。
// ---------------------------------------------------------------------------
BOOL Amethyst_SDL3SurfaceWantsPoints(void) {
    return NO;
}

static EGLDisplay g_EglDisplay;
static egl_library handle;

// ============================================================================
// 黑屏取证（Task 32）：eglSwapBuffers 成功/失败原子计数器
//
// 背景（latestlog b199c07 设备实测）：游戏完整启动（390 shader 全部转换成功、
// 资源/图集/声音加载完毕、SDL 事件循环存活、MC 事件被推入队列），但屏幕全黑。
// 旧版 gl_swap_buffers 只在 eglGetError()==EGL_BAD_SURFACE 时才打日志，
// 其余错误码（EGL_BAD_NATIVE_WINDOW / EGL_CONTEXT_LOST / EGL_BAD_ALLOC 等）
// 完全静默；而 pojavSwapBuffers 的 "First frame rendered" 又是无条件打印的，
// 无法证明首帧真的上屏。这两个计数器 + SurfaceVC 的 5 秒心跳日志
// （[RenderDiag] fps= swapOK= swapFail=）可以一锤定音地判断：
//   - swapFail 持续增长 → 呈现路径断了（layer/surface 生命周期问题）
//   - swapOK 增长但黑屏 → 帧被换入了错误的目标（覆盖/尺寸/scale 问题）
//   - 两个都不动 → 渲染线程已卡死（渲染循环在启动后期被阻塞）
// ============================================================================
static _Atomic unsigned long g_eglSwapOK = 0;
static _Atomic unsigned long g_eglSwapFail = 0;

// ============================================================================
// Task 76：swap 帧间隔尖峰跟踪（帧节奏诊断）
//
// 背景（bef0f08 双日志对比）：MG/MobileGlues 场次 fps 在 5~60 剧烈震荡而
// Zink 场次稳定 40-53 —— 用户主观“30fps 看得像 10fps”。帧率均值掩盖了
// 帧时间尖峰：fps=5 的窗口意味着单帧 200ms，而 vsync 锁 60（MG 场次在
// max.fps=260 解锁下从未超过 60）把帧到达时间量化到 16.7ms 的整数倍——
// 丢拍阶梯才是观感卡顿的机理。本计数器在 gl_swap_buffers 成功路径上
// 记录相邻 swap 的间隔，维护 5 秒窗口（心跳周期）内的 max 与均值，由
// [RenderDiag] 心跳一并上报，下轮设备日志可直接对比修复前后的帧节奏。
// 只在渲染线程读写（swap 本就在渲染线程），无需原子操作。
// ============================================================================
static uint64_t ame76_last_swap_ms = 0;   // 0 = 尚无首帧
static uint32_t ame76_max_gap_ms = 0;     // 本窗口最大帧间隔
static uint64_t ame76_gap_sum_ms = 0;     // 本窗口间隔总和（ms 粒度够用）
static uint32_t ame76_gap_count = 0;      // 本窗口间隔样本数

void ame_egl_swap_stats(unsigned long *ok, unsigned long *fail) {
    if (ok) *ok = atomic_load(&g_eglSwapOK);
    if (fail) *fail = atomic_load(&g_eglSwapFail);
}

// Task 76：读取并重置帧间隔窗口统计（SurfaceViewController 5 秒心跳调用）。
// count==0 时 max/avg 均报告 0。首帧不算间隔（冷启动间隔无意义）。
void ame_egl_swap_framegap(uint32_t *maxGapMs, uint32_t *avgGapMs) {
    uint32_t mx = ame76_max_gap_ms;
    uint32_t avg = ame76_gap_count ? (uint32_t)(ame76_gap_sum_ms / ame76_gap_count) : 0;
    if (maxGapMs) *maxGapMs = mx;
    if (avgGapMs) *avgGapMs = avg;
    ame76_max_gap_ms = 0;
    ame76_gap_sum_ms = 0;
    ame76_gap_count = 0;
}

static void ame76_record_swap(uint64_t now_ms) {
    if (ame76_last_swap_ms != 0 && now_ms > ame76_last_swap_ms) {
        uint32_t gap = (uint32_t)(now_ms - ame76_last_swap_ms);
        if (gap > ame76_max_gap_ms) ame76_max_gap_ms = gap;
        ame76_gap_sum_ms += gap;
        ame76_gap_count++;
    }
    ame76_last_swap_ms = now_ms;
}

// ============================================================================
// Task 77：帧相位计时（present vs build 分相归因）
//
// 背景（66e57f0 双 MG 日志 + 量化关联分析）：MG 场次 avgGap 在 17ms 与
// 250ms 之间震荡（fps 60↔4），而同日同包 Zink 场次稳定 37-53fps。
// GC/内存/shader 编译/FSR1/取证探针/深度 workaround 全部排除后，250ms
// 只能出在渲染线程帧循环的两个相位之一：
//   build  = 上一次 eglSwapBuffers 返回 → 本次进入 gl_swap_buffers
//            （MC tick + 事件泵 + GL 编码穿 MobileGlues/ANGLE 的 CPU 税）
//   present= handle.eglSwapBuffers 内部（ANGLE Metal 编码提交 + nextDrawable
//            等待 + GPU 追赶；maxDrawableCount=3 耗尽时阻塞）
// 本计时器按相位分别累计 5 秒窗口的 avg/max，由 [RenderDiag] 心跳上报。
// 下轮设备日志判读法（二选一，直接定案）：
//   presAvg/presMax ≈ avgGap   → 停在 ANGLE Metal 呈现/GPU 侧（换渲染器/
//                                 降 resolutionScale 才有效，CPU 优化无效）
//   buildAvg/buildMax ≈ avgGap → 停在 MC 帧 CPU 侧（GL 转译税，MobileGlues
//                                 /ANGLE 逐 draw 开销线才有效）
// 微秒粒度累计（ms 粒度下 1-2ms 的正常 present 会被舍入噪声淹没），
// 上报时折算毫秒。只在渲染线程读写，无需原子操作。
// ============================================================================
static uint64_t ame77_last_swap_end_us = 0;   // 上次 swap 返回时刻（0=无）
static uint64_t ame77_present_sum_us = 0;     // 窗口内 present 时长总和
static uint32_t ame77_present_max_us = 0;     // 窗口内 present 最大时长
static uint32_t ame77_present_count = 0;      // 窗口内 present 样本数
static uint64_t ame77_build_sum_us = 0;       // 窗口内 build 时长总和
static uint32_t ame77_build_max_us = 0;       // 窗口内 build 最大时长
static uint32_t ame77_build_count = 0;        // 窗口内 build 样本数

static uint64_t ame77_now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000ull + (uint64_t)ts.tv_nsec / 1000ull;
}

// Task 77：读取并重置帧相位窗口统计（SurfaceViewController 5 秒心跳调用）。
// 值一律折算为毫秒（向下取整）；count==0 时对应 avg/max 报 0。
void ame_egl_swap_phase_stats(uint32_t *presentAvgMs, uint32_t *presentMaxMs,
                              uint32_t *buildAvgMs, uint32_t *buildMaxMs) {
    uint32_t pAvg = ame77_present_count ? (uint32_t)(ame77_present_sum_us / ame77_present_count / 1000ull) : 0;
    uint32_t pMax = ame77_present_count ? ame77_present_max_us / 1000u : 0;
    uint32_t bAvg = ame77_build_count ? (uint32_t)(ame77_build_sum_us / ame77_build_count / 1000ull) : 0;
    uint32_t bMax = ame77_build_count ? ame77_build_max_us / 1000u : 0;
    if (presentAvgMs) *presentAvgMs = pAvg;
    if (presentMaxMs) *presentMaxMs = pMax;
    if (buildAvgMs) *buildAvgMs = bAvg;
    if (buildMaxMs) *buildMaxMs = bMax;
    ame77_present_sum_us = 0;
    ame77_present_max_us = 0;
    ame77_present_count = 0;
    ame77_build_sum_us = 0;
    ame77_build_max_us = 0;
    ame77_build_count = 0;
}

// Task 77：swap 入口记录 build 相位（上一帧 present 结束 → 本帧进入 swap）。
static void ame77_record_build(uint64_t now_us) {
    if (ame77_last_swap_end_us != 0 && now_us > ame77_last_swap_end_us) {
        uint32_t dur = (uint32_t)(now_us - ame77_last_swap_end_us);
        if (dur > ame77_build_max_us) ame77_build_max_us = dur;
        ame77_build_sum_us += dur;
        ame77_build_count++;
    }
}

// Task 77：present 相位计时（eglSwapBuffers 内部时长），成功失败都计
// （失败的慢 present 同样是归因证据）。
static void ame77_record_present(uint64_t dur_us, uint64_t now_us) {
    if (dur_us > ame77_present_max_us) ame77_present_max_us = (uint32_t)dur_us;
    ame77_present_sum_us += dur_us;
    ame77_present_count++;
    ame77_last_swap_end_us = now_us;
}

// ============================================================================
// Task 50：GL 呈现层所有权标志（跨线程）。
//
// currentBundle（bridge_tbl.h）是 __thread 的——只在渲染线程非空，
// 主线程（updateSavedResolution）读它永远得到 NULL。因此需要一个跨线程
// 的原子标志：GL 路径在 gl_init_context 成功创建 surface 后置位，
// gl_terminate 清零。SurfaceViewController 据此判断"GL 拥有呈现层"，
// 并把 layer 对齐到原生 scale 像素（Task60 单一事实源几何，详见
// gl_init_context 内的 Task60 对齐块；Task50 1x 已退役——CA 线性 2x
// 放大是画面模糊根源）。Vulkan 路径不创建 EGL surface → 标志恒 0 →
// 主线程保持旧的 2x 行为（MoltenVK 自管 drawableSize，互不干扰）。
// ============================================================================
static _Atomic int g_ame50_gl_owns_layer = 0;

bool ame_gl_surface_owns_layer(void) {
    return atomic_load(&g_ame50_gl_owns_layer) != 0;
}

// ============================================================================
// Task 41：交换时刻 GL 状态取证 + 自愈呈现（GL 路径黑屏定位）
//
// 现状（latestlog d638c22）：swapOK=529、fps=57、390 编译零崩溃、图集/音效
// 全齐、遮罩正常移除——但画面全黑。MC RenderPearl GL 后端自建 1180x820 双
// 缓冲交换链 FBO（[MG] depth alloc #1/#2 两个 D32F 1180x820）。最后疑点：
// MC 的合成画面从未进入 FBO 0（ANGLE 窗口后缓冲），或进入后被翻译层丢弃。
//
// 本块在每次 eglSwapBuffers 之前（MC 渲染线程、MC 上下文 current）：
//   1) 探针帧（#1-#5 + 每 200 帧）：glGetIntegerv 查 DRAW/READ binding +
//      viewport，eglQuerySurface 查表面尺寸（Task58 官方宏），记日志。
//      【Task 75】回读探针已退役——4770b53 日志实锤：swap#8400（游戏暂停
//      剧集、dynamic_fps 降帧）探针 glReadPixels 触发 ANGLE Metal
//      readPixelsCopyImpl → CopyBGRA8ToRGBA8 SIGBUS（读的是即将呈现的
//      CAMetalLayer drawable 纹理；iOS glReadPixels 间歇性崩溃为社区已知
//      现象；上游 herbrine8403/Amethyst-iOS swap 路径全程零回读同源佐证）。
//      内容 uniq/fbo0/corner 字段随之移除。
//   2) 自愈 latch（Task 75 几何判据化，零回读）：几何对齐（viewport==
//      surface）→ mode=normal；几何失配 → Task55 realign / Task49
//      geo-heal blit（纯 blit 零回读、确定性）。黑屏时代（Task41-58）已
//      闭案：几何判据 + 呈现层卫兵（Task52）足以覆盖全部已知形态。
//
// ES 指针从 MG 同款 pin 路径解析（@executable_path/Frameworks/
// libGLESv2.framework/libGLESv2），指向同一 ANGLE 镜像；对 gl4es 等
// 渲染器同样适用（它们的底层同为 ANGLE ES 上下文）。
// ============================================================================
typedef void (*ame_es_getint_t)(unsigned int, int *);
typedef void (*ame_es_bindfb_t)(unsigned int, unsigned int);
typedef unsigned int (*ame_es_geterr_t)(void);
typedef unsigned char (*ame_es_isenabled_t)(unsigned int);
typedef void (*ame_es_enable_t)(unsigned int, unsigned char);
typedef void (*ame_es_blitfb_t)(int, int, int, int, int, int, int, int, unsigned int, unsigned int);
typedef void (*ame_es_bindtex_t)(unsigned int, unsigned int);
typedef void (*ame_es_texparami_t)(unsigned int, unsigned int, int);
typedef void (*ame_es_gentex_t)(int, unsigned int *);
typedef void (*ame_es_deltex_t)(int, const unsigned int *);
typedef void (*ame_es_teximg2d_t)(unsigned int, int, int, int, int, int, unsigned int, unsigned int, const void *);
typedef void (*ame_es_genfb_t)(int, unsigned int *);
typedef void (*ame_es_delfb_t)(int, const unsigned int *);
typedef void (*ame_es_fbtex2d_t)(unsigned int, unsigned int, unsigned int, unsigned int, int);
typedef unsigned int (*ame_es_checkfb_t)(unsigned int);

typedef struct {
    ame_es_getint_t    getIntegerv;
    ame_es_bindfb_t    bindFramebuffer;
    ame_es_geterr_t    getError;
    ame_es_isenabled_t isEnabled;
    ame_es_enable_t    enable;
    ame_es_blitfb_t    blitFramebuffer;
    EGLBoolean (*querySurface)(EGLDisplay, EGLSurface, EGLint, EGLint *);
    ame_es_bindtex_t   bindTexture;        // Task 49 几何自愈
    ame_es_texparami_t texParameteri;      // Task 49 几何自愈
    ame_es_gentex_t    genTextures;        // Task 49 几何自愈
    ame_es_deltex_t    deleteTextures;     // Task 49 几何自愈
    ame_es_teximg2d_t  texImage2D;         // Task 49 几何自愈
    ame_es_genfb_t     genFramebuffers;    // Task 49 几何自愈
    ame_es_delfb_t     deleteFramebuffers; // Task 49 几何自愈
    ame_es_fbtex2d_t   framebufferTexture2D; // Task 49 几何自愈
    ame_es_checkfb_t   checkFramebufferStatus; // Task 49 几何自愈
} ame_es_t;

static ame_es_t ame_es(void) {
    static ame_es_t s_es;
    static BOOL s_tried = NO;
    if (s_tried) return s_es;
    s_tried = YES;
    static const char *const kCandidates[] = {
        "@executable_path/Frameworks/libGLESv2.framework/libGLESv2",
        "@rpath/libGLESv2.framework/libGLESv2",
        "libGLESv2",
        NULL,
    };
    void *h = NULL;
    for (int i = 0; kCandidates[i] != NULL; ++i) {
        h = dlopen(kCandidates[i], RTLD_NOW | RTLD_LOCAL);
        if (h != NULL) {
            NSLog(@"[RenderDiag] Task41 ES probe pinned to %s", kCandidates[i]);
            break;
        }
    }
    if (h == NULL) {
        NSLog(@"[RenderDiag] Task41 ES probe unavailable (libGLESv2 not loadable)");
        return s_es;
    }
    s_es.getIntegerv     = (ame_es_getint_t)dlsym(h, "glGetIntegerv");
    s_es.bindFramebuffer = (ame_es_bindfb_t)dlsym(h, "glBindFramebuffer");
    // Task 75：glReadPixels 解析已移除（回读探针退役，Swap 路径零回读）。
    s_es.getError        = (ame_es_geterr_t)dlsym(h, "glGetError");
    s_es.isEnabled       = (ame_es_isenabled_t)dlsym(h, "glIsEnabled");
    s_es.enable          = (ame_es_enable_t)dlsym(h, "glEnable");
    s_es.blitFramebuffer = (ame_es_blitfb_t)dlsym(h, "glBlitFramebuffer");
    // Task 49：几何自愈 blit 需要的 FBO/纹理管理函数（同源 libGLESv2/ANGLE）
    s_es.bindTexture     = (ame_es_bindtex_t)dlsym(h, "glBindTexture");
    s_es.texParameteri   = (ame_es_texparami_t)dlsym(h, "glTexParameteri");
    s_es.genTextures     = (ame_es_gentex_t)dlsym(h, "glGenTextures");
    s_es.deleteTextures  = (ame_es_deltex_t)dlsym(h, "glDeleteTextures");
    s_es.texImage2D      = (ame_es_teximg2d_t)dlsym(h, "glTexImage2D");
    s_es.genFramebuffers = (ame_es_genfb_t)dlsym(h, "glGenFramebuffers");
    s_es.deleteFramebuffers = (ame_es_delfb_t)dlsym(h, "glDeleteFramebuffers");
    s_es.framebufferTexture2D = (ame_es_fbtex2d_t)dlsym(h, "glFramebufferTexture2D");
    s_es.checkFramebufferStatus = (ame_es_checkfb_t)dlsym(h, "glCheckFramebufferStatus");
    // eglQuerySurface 在 libEGL（ANGLE EGL）里，与 libGLESv2 同一 ANGLE 家族，
    // 已加载镜像 dlopen 仅引用计数 +1。自行解析以避免前向依赖文件后部的
    // ame_raw_query_surface（static 声明位于本块之后，不可提前引用）。
    static const char *const kEglCandidates[] = {
        "@executable_path/Frameworks/libEGL.framework/libEGL",
        "@rpath/libEGL.framework/libEGL",
        "libEGL",
        NULL,
    };
    for (int i = 0; kEglCandidates[i] != NULL; ++i) {
        void *he = dlopen(kEglCandidates[i], RTLD_NOW | RTLD_LOCAL);
        if (he != NULL) {
            s_es.querySurface = (EGLBoolean (*)(EGLDisplay, EGLSurface, EGLint, EGLint *))dlsym(he, "eglQuerySurface");
            break;
        }
    }
    return s_es;
}

// Task 75：ame_count_unique_rgba / ame_float_readback_has_content 已随
// 回读探针一并退役（唯一调用方是探针的内容判定；保留会成死代码告警）。
// 8x8 回读 → uniq 计数 → “有内容”判定的整条链路自此处消失。

// ============================================================================
// Task 49：几何自愈 blit（scratch-FBO 两段中转）
//
// latestlog 53febda（d11eb66）铁证：MC 的帧确实在后缓冲里，但只覆盖
// viewport 区域（1180x820，SDL3 点数），而表面是 2x 像素（2360x1640 或
// 1640x2360）——帧占后缓冲左上 ~25%，其余永远平坦暗色（corner=27，近乎黑）。
// 用户看到的就是"黑屏"。旧版 mode-2 blit 直接 READ=drawFb → DRAW=0，
// 但实测 drawFb==0（MC 交换时刻绑定回默认帧缓冲）→ blit 变成 FBO0→FBO0
// 自拷贝，矩形重叠 = ES 非法/无操作，且旧 latch 判据永不满足 → 自愈从未
// 启动。
//
// 新设计（几何判定，零回读、每帧确定性）：
//   viewport 维度 != surface 维度 → 帧无法覆盖后缓冲 → 启用两段 blit：
//     段1: READ = (drawFb ? drawFb : 0) 的 viewport 区域 → scratch（缩放到 surface 尺寸）
//     段2: READ = scratch → DRAW = FBO 0 全表面（1:1）
//   两段各自无矩形重叠，ES3 合法。帧被放大铺满整个后缓冲 = 全屏可见，
//   无论 1x/2x 尺寸单位失配、竖横转置、创建竞态还是旋转残留。
//   表面尺寸变化时 scratch 懒重建（glTexImage2D 同名重分配）。
// ============================================================================
static unsigned int g_ame49_scratch_fb = 0;
static unsigned int g_ame49_scratch_tex = 0;
static int g_ame49_scratch_w = 0, g_ame49_scratch_h = 0;
static int g_ame49_heal_disabled = 0;   // scratch FBO 完整性失败后的永久熔断
// Task51：呈现 layer 引用（CFBridgingRetain）。声明前置——swap 诊断函数
//（Fix F' 钉扎与 hierarchy dump）在本文件更早处使用，原声明位置（Task48
// 段内）在使用点之后，b9634f4 CI 实测报 undeclared identifier。
static void *g_ame48_layer_cf = NULL;

// Task52：来自 sdl3_hook.m —— 嵌入的 SDL 触摸视图（可见性卫兵 z 序执法用）。
// 返回值是 __bridge 裸指针，只做同一性比较，不得解引用为 ARC 对象持有。
extern void *ame_hook_getEmbeddedSDLView(void);

static void ame_task49_geo_heal_blit(ame_es_t es, int drawFb, int readFb,
                                     int vw, int vh, int sw, int sh) {
    if (g_ame49_heal_disabled) return;
    if (es.genFramebuffers == NULL || es.genTextures == NULL ||
        es.texImage2D == NULL || es.framebufferTexture2D == NULL ||
        es.checkFramebufferStatus == NULL || es.bindTexture == NULL ||
        es.texParameteri == NULL || es.blitFramebuffer == NULL) {
        g_ame49_heal_disabled = 1;   // 函数指针不全：熔断（创建执法/卫兵钉扎仍在）
        return;
    }
    // 1) scratch 尺寸跟随 surface（懒创建 / 尺寸变化时重分配）
    if (g_ame49_scratch_fb == 0 || g_ame49_scratch_w != sw || g_ame49_scratch_h != sh) {
        if (g_ame49_scratch_fb == 0) {
            es.genFramebuffers(1, &g_ame49_scratch_fb);
            es.genTextures(1, &g_ame49_scratch_tex);
        }
        es.bindTexture(0x0DE1 /*GL_TEXTURE_2D*/, g_ame49_scratch_tex);
        es.texImage2D(0x0DE1, 0, 0x8058 /*GL_RGBA8*/, sw, sh, 0,
                      0x1908 /*GL_RGBA*/, 0x1401 /*GL_UNSIGNED_BYTE*/, NULL);
        es.texParameteri(0x0DE1, 0x2801 /*GL_TEXTURE_MIN_FILTER*/, 0x2601 /*GL_LINEAR*/);
        es.texParameteri(0x0DE1, 0x2800 /*GL_TEXTURE_MAG_FILTER*/, 0x2601 /*GL_LINEAR*/);
        es.bindFramebuffer(0x8D40 /*GL_FRAMEBUFFER*/, g_ame49_scratch_fb);
        es.framebufferTexture2D(0x8D40, 0x8CE0 /*GL_COLOR_ATTACHMENT0*/,
                                0x0DE1, g_ame49_scratch_tex, 0);
        if (es.checkFramebufferStatus(0x8D40) != 0x8CD5 /*GL_FRAMEBUFFER_COMPLETE*/) {
            NSLog(@"[RenderDiag] Task49 scratch FBO incomplete %dx%d -- geo-heal fused off", sw, sh);
            es.bindFramebuffer(0x8D40, (unsigned)drawFb);
            while (es.getError() != 0) {}
            if (g_ame49_scratch_fb != 0) es.deleteFramebuffers(1, &g_ame49_scratch_fb);
            if (g_ame49_scratch_tex != 0) es.deleteTextures(1, &g_ame49_scratch_tex);
            g_ame49_scratch_fb = 0; g_ame49_scratch_tex = 0;
            g_ame49_scratch_w = 0; g_ame49_scratch_h = 0;
            g_ame49_heal_disabled = 1;
            return;
        }
        g_ame49_scratch_w = sw; g_ame49_scratch_h = sh;
        NSLog(@"[RenderDiag] Task49 scratch FBO ready %dx%d", sw, sh);
    }
    // 2) scissor 保存/关闭 + 两段 blit
    int scissorWasOn = es.isEnabled(0x0C11 /*GL_SCISSOR_TEST*/);
    if (scissorWasOn) es.enable(0x0C11, 0 /*GL_FALSE*/);
    // 段1：MC 帧（viewport 区域，源 = MC 当前 FBO 或 FBO 0）→ scratch 全尺寸缩放
    es.bindFramebuffer(0x8CA8 /*GL_READ_FRAMEBUFFER*/, (unsigned)(drawFb != 0 ? drawFb : 0));
    es.bindFramebuffer(0x8CA9 /*GL_DRAW_FRAMEBUFFER*/, g_ame49_scratch_fb);
    es.blitFramebuffer(0, 0, vw, vh, 0, 0, sw, sh,
                       0x4000 /*GL_COLOR_BUFFER_BIT*/, 0x2601 /*GL_LINEAR*/);
    // 段2：scratch → FBO 0 全表面 1:1
    es.bindFramebuffer(0x8CA8, g_ame49_scratch_fb);
    es.bindFramebuffer(0x8CA9, 0);
    es.blitFramebuffer(0, 0, sw, sh, 0, 0, sw, sh,
                       0x4000, 0x2601 /*GL_LINEAR*/);
    unsigned int blitErr = es.getError();
    // 3) 状态恢复
    es.bindFramebuffer(0x8CA8, (unsigned)readFb);
    es.bindFramebuffer(0x8CA9, (unsigned)drawFb);
    if (scissorWasOn) es.enable(0x0C11, 1 /*GL_TRUE*/);
    while (es.getError() != 0) {}
    static unsigned long s_blitLogs = 0;
    s_blitLogs++;
    if (s_blitLogs <= 3 || s_blitLogs % 300 == 0 || blitErr != 0) {
        NSLog(@"[RenderDiag] geo-heal blit #%lu (Task49): srcFb=%d %dx%d -> scratch %dx%d -> FBO0 %dx%d blitErr=0x%x",
              s_blitLogs, drawFb, vw, vh, sw, sh, sw, sh, blitErr);
    }
}

// ============================================================================
// Task 53：EGL 表面重对齐（画面分裂 + 输入异常根因根治）
//
// 设备铁证（latestlog f4ab8e3，iPad Air M4 / iPadOS 26.6，Task52 修复黑屏
// 后的首轮真机日志）：
//   - 表面创建时 1180x820（eglQuerySurface 双确认），但首次交换时已转置为
//     820x1180 且 1400+ 帧锁死永不恢复（转置发生在加载期"无 swap 的盲窗"
//     ——窗口事件/UIKit 布局瞬时竖屏，ANGLE 随 layer 重读几何时捕获转置
//     值，Task48 已证其转置后不随 layer 回横屏）；
//   - MC viewport 恒 1180x820：帧被裁到转置后缓冲左侧 820 列，Task49
//     geo-heal blit 再把整帧压扁铺进 820x1180；
//   - drawableSize 拉锯战：updateSavedResolution（写 bounds 横屏 1180x820）
//     vs Task52 guard（写 surface 转置值 820x1180，每 200 帧互覆）→
//     drawable 为横屏的帧：blit 只覆盖左侧 820x820，右侧 360 列残留原始
//     帧内容 = 用户看到的"画面分裂"（左半压扁 + 右半残影）；
//   - 触摸按全窗口 1180x820 点空间映射（Task51 px->pt 换算本身正确），
//     所见画面却错位/压扁 → 点不中所见按钮 = "输入异常"。
//
// 修复（治本——消灭转置本身，让全部补偿机制回到无害 no-op）：
//   几何失配首检出时销毁优先重建 EGL window surface。Task48 重建恒败
//   （EGL_BAD_ALLOC 0x3003）的根因是"先建后毁"——同 layer 双 surface
//   并存；销毁优先（先 MakeCurrent 解绑再销毁）则层自由，创建必成：
//     1) 主线程 dispatch_sync 钉扎 layer（contentsScale=1.0、drawableSize=
//        bounds 点数）——Task50 已证主线程写是唯一可靠写入路径；
//     2) eglMakeCurrent(无表面) 解绑 → eglDestroySurface(旧) →
//        eglCreateWindowSurface（读钉扎后的横屏 layer）→ eglMakeCurrent
//        (新表面)（经 Task36 前端路由，MGContext 跟踪保持；前端
//        MakeCurrent 对 EGL_NO_SURFACE 纯透传，安全）；
//     3) 成功后 surface == viewport == drawable == bounds：几何失配判定
//        不再触发、geo-heal 自动退出（Task50 latch 恢复分支）、拉锯战
//        自然终止（两写者写同值）、画面 1:1 全屏、触摸坐标与所见画面对齐
//        （输入随几何自愈）；
//     4) 失败兜底：预算 3 次 + 2s 限速 + 链路任一步失败即永久熔断，回退
//        Task49/51/52 既有补偿路径（行为不劣于修复前，零回归）。
// ============================================================================
static int      g_ame53_attempts = 0;    // 已消耗的重试预算
static uint64_t g_ame53_last_ms = 0;     // 上次尝试时刻（2s 限速）
static int      g_ame53_disabled = 0;    // 熔断：预算耗尽或链路失败
static int      g_ame53_transposed = 0;  // surface 与 MC viewport 失配标志
//（供 updateSavedResolution 判断停火——失配未治愈期间让 Task52 guard
//  独占 drawableSize 写权，终结拉锯战；由交换路径逐帧刷新）

bool ame_gl_surface_transposed(void) {
    return g_ame53_transposed != 0;
}

static uint64_t ame53_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ull + (uint64_t)ts.tv_nsec / 1000000ull;
}

// ---- Task 55：梯度式重对齐的三个辅助 ----

// 同步等待主队列 runloop 拍数（每拍强制 [CATransaction flush]：CA 事务立即
// 提交，ANGLE 若监听 layer/CA 通知则获得触发窗口；dispatch_sync 嵌套保证
// 至少走过 turns 个主队列周期）。
static void ame55_wait_main_turns(int turns) {
    for (int i = 0; i < turns; ++i) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            @try { [CATransaction flush]; } @catch (NSException *e) {}
        });
    }
}

// 渲染线程同步等待 ms 毫秒（主队列 dispatch_after 栅栏——期间主 runloop 照
// 常转动，CA/ANGLE 有完整窗口清理）。Step B 的销毁-重建真间隔。
static void ame55_main_gap_ms(uint64_t ms) {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)ms * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ dispatch_semaphore_signal(sem); });
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
}

// 治愈判定：querySurface == layer 期望几何（与交换探针同源的权威值）。
// outQ 非 NULL 时回填实际查询值（日志指纹用）。
static BOOL ame55_verify_surface(ame_es_t es, EGLSurface s, CGSize expected,
                                 EGLint *outQW, EGLint *outQH) {
    if (es.querySurface == NULL || s == EGL_NO_SURFACE) return NO;
    EGLint w = 0, h = 0;
    // Task 58 根因修正（画面分裂定案）：EGL_HEIGHT=0x3056、EGL_WIDTH=0x3057
    //（egl.h 官方定义，Natives/external/mesa/EGL/egl.h:90/123）。旧代码两常量
    // 对调（0x3056 当宽、0x3057 当高）→ 宽高读反 → “治愈判定”永远失败——
    // 这就是 Task53/55 realign 历轮报 "NOT cured (recreate reads transposed
    // geometry)" 的真相：新表面其实一直是横屏健康的。
    if (!es.querySurface(g_EglDisplay, s, EGL_WIDTH, &w) ||
        !es.querySurface(g_EglDisplay, s, EGL_HEIGHT, &h)) return NO;
    if (outQW) *outQW = w;
    if (outQH) *outQH = h;
    return (w == (EGLint)MAX(1.0, round(expected.width))) &&
           (h == (EGLint)MAX(1.0, round(expected.height)));
}

/// Task 55 梯度式表面重对齐（取代 Task53 的单式 destroy-recreate）。
/// 调用方：MC 渲染线程（swap 路径、上下文 current）。
/// 返回 YES = querySurface == layer bounds（真治愈；调用方复位 latch mode）。
///
/// a901050 真机日志判读（Task 54 构建，2026-09-11 23:10，驱动本轮设计）：
///   - 初始创建 querySurface=1180x820 正确；盲窗内（8500 行加载、零 swap）
///     转置为 820x1180；Task53 destroy-first recreate 后【依然 820x1180】
///     ——对着横屏 layer（pin 打印 bounds 1180x820）重建仍转置；
///   - 旧判定只验“create 非 NULL”即宣称 SUCCESS（假成功）→ transposed=0 →
///     updateSavedResolution ceasefire 解除 → drawableSize 拉锯回归 →
///     画面分裂（用户本轮症状）；
///   - 转置的 ANGLE 读数源（transform 链 / UIScreen 回退 / swapchain 缓存）
///     现有日志无法裁定 → 梯度覆盖三假说，每步独立验证 + 指纹日志，
///     无论哪条路走通都能治愈，全失败则下轮日志带回决定性证据。
///
/// 梯度（一步治愈即停）：
///   A 几何信号（零销毁）：主线程写 drawableSize=bounds + bounds 轻碰
///     （1pt 偏差同事务写回）+ 2 拍主 runloop（CATransaction flush）→ 查询。
///     假说：ANGLE 监听 layer 几何事件（622166a 转置即其跟随能力的实证）。
///   B 延迟重建（Task53 原方案强化）：destroy → 100ms 真间隔（修句柄即时
///     回收复用——上轮新旧句柄同为 0x1 的疑点）→ recreate（显式横屏
///     attribs）→ MakeCurrent → 2 拍 → 查询。
///   C 反向转置旅程：写 drawableSize=转置值 → 2 拍 → 写回横屏 bounds →
///     2 拍 → 查询（复现盲窗转置事件的正向旅程、收尾落在横屏——若 ANGLE
///     是事件驱动跟随，一来一回落在最后的横屏值上）。
/// 全失败 → 本轮 attempt 失败（预算 3 次梯度 + 2s 冷却不变，熔断后补偿照旧）。
static BOOL ame_task53_realign_surface(void) {
    if (g_ame53_disabled) return NO;
    if (g_ame53_attempts >= 3) {
        g_ame53_disabled = 1;
        NSLog(@"[GLGeo] Task55 realign: budget exhausted after %d attempts -- fused off, compensation path continues", g_ame53_attempts);
        return NO;
    }
    uint64_t now = ame53_now_ms();
    if (g_ame53_last_ms != 0 && now - g_ame53_last_ms < 2000) return NO;
    g_ame53_last_ms = now;
    g_ame53_attempts++;

    basic_render_window_t *bundle = currentBundle;
    CALayer *layer = (__bridge CALayer *)g_ame48_layer_cf;
    if (bundle == NULL || layer == nil || ![layer isKindOfClass:CAMetalLayer.class]) {
        NSLog(@"[GLGeo] Task55 realign: prerequisites missing (bundle/layer) -- fused off");
        g_ame53_disabled = 1;
        return NO;
    }

    NSLog(@"[GLGeo] Task55 realign: attempt %d/3 (gradient A geometry-signal -> B deferred-recreate -> C transpose-roundtrip)",
          g_ame53_attempts);

    // 期望几何（主线程权威 bounds x contentsScale，像素口径——Task60：
    // surface/query/drawable 全链已统一像素口径；旧 1x 点数 pin 会让
    // verify 永远 FAIL、heal 步骤把 drawableSize 拉回 1x）。
    __block CGSize pin55 = CGSizeZero;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            CGFloat w55 = MAX(1.0, round(layer.bounds.size.width));
            CGFloat h55 = MAX(1.0, round(layer.bounds.size.height));
            CGFloat sc55 = layer.contentsScale;
            if (sc55 <= 0.0) sc55 = 1.0;
            pin55 = CGSizeMake(round(w55 * sc55), round(h55 * sc55));
        } @catch (NSException *e) {
            NSLog(@"[GLGeo] Task55 pin exception: %@", e);
        }
    });
    if (pin55.width < 1 || pin55.height < 1) {
        NSLog(@"[GLGeo] Task55 realign FAILED: layer pin unavailable -- fused off, compensation continues");
        g_ame53_disabled = 1;
        return NO;
    }

    ame_es_t es55 = ame_es();
    EGLSurface cur55 = bundle->gl.surface;
    EGLint q55w = 0, q55h = 0;

    // --- Step A：零销毁几何信号 ---
    NSLog(@"[GLGeo] Task55 realign stepA: drawableSize=bounds + bounds nudge + 2 main turns (no destroy)");
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            CAMetalLayer *mlA = (CAMetalLayer *)layer;
            mlA.drawableSize = pin55;
            // bounds 轻碰：1pt 偏差再写回（同一 CA 事务内提交原值，屏幕无可
            // 感知闪变；目的是强制 CA/KVO 发出“layer 几何变化”通知）。
            CGRect bA = layer.bounds;
            layer.bounds = CGRectMake(bA.origin.x, bA.origin.y, bA.size.width, bA.size.height + 1.0);
            layer.bounds = bA;
        } @catch (NSException *e) {
            NSLog(@"[GLGeo] Task55 stepA exception: %@", e);
        }
    });
    ame55_wait_main_turns(2);
    if (ame55_verify_surface(es55, cur55, pin55, &q55w, &q55h)) {
        NSLog(@"[GLGeo] Task55 realign CURED by stepA: query=%dx%d == bounds %.0fx%.0f (ANGLE follows layer geometry; transposed lock released)",
              q55w, q55h, pin55.width, pin55.height);
        return YES;
    }
    NSLog(@"[GLGeo] Task55 stepA verify: query=%dx%d expected=%.0fx%.0f -- NOT cured (ANGLE ignored drawableSize+bounds nudge)",
          q55w, q55h, pin55.width, pin55.height);

    // --- Step B：销毁 + 100ms 真间隔 + 重建（修句柄即时回收复用） ---
    NSLog(@"[GLGeo] Task55 realign stepB: destroy -> 100ms gap -> recreate (explicit landscape attribs)");
    EGLContext ctx55 = bundle->gl.context;
    EGLSurface old55 = cur55;
    handle.eglMakeCurrent(g_EglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx55);
    handle.eglDestroySurface(g_EglDisplay, old55);
    while (handle.eglGetError() != EGL_SUCCESS) {}
    ame55_main_gap_ms(100);

    const BOOL mobileGL55 = isMobileGLRenderer(getenv("AMETHYST_RENDERER"));
    EGLSurface new55 = EGL_NO_SURFACE;
    for (int try55 = 0; try55 < 2 && new55 == EGL_NO_SURFACE; try55++) {
        const EGLint attribs55[] = {
            EGL_WIDTH,  (EGLint)pin55.width,
            EGL_HEIGHT, (EGLint)pin55.height,
            EGL_NONE
        };
        new55 = handle.eglCreateWindowSurface(g_EglDisplay, bundle->gl.config,
            (__bridge EGLNativeWindowType)layer,
            (mobileGL55 || try55 > 0) ? attribs55 : NULL);
        if (new55 == EGL_NO_SURFACE) {
            NSLog(@"[GLGeo] Task55 create attempt %d failed: eglError=0x%x", try55 + 1,
                  (unsigned int)(uintptr_t)handle.eglGetError());
        }
    }
    if (new55 == EGL_NO_SURFACE) {
        NSLog(@"[GLGeo] Task55 stepB FAILED: recreation refused after destroy+gap (old surface %p) -- fused off, compensation continues",
              (void *)old55);
        bundle->gl.surface = EGL_NO_SURFACE;
        g_ame53_disabled = 1;
        return NO;
    }
    if (!handle.eglMakeCurrent(g_EglDisplay, new55, new55, ctx55)) {
        NSLog(@"[GLGeo] Task55 stepB FAILED: eglMakeCurrent error 0x%x -- fused off",
              (unsigned int)(uintptr_t)handle.eglGetError());
        handle.eglDestroySurface(g_EglDisplay, new55);
        bundle->gl.surface = EGL_NO_SURFACE;
        g_ame53_disabled = 1;
        return NO;
    }
    bundle->gl.surface = new55;
    cur55 = new55;
    while (handle.eglGetError() != EGL_SUCCESS) {}
    ame55_wait_main_turns(2);
    if (ame55_verify_surface(es55, cur55, pin55, &q55w, &q55h)) {
        NSLog(@"[GLGeo] Task55 realign CURED by stepB: surface %p -> %p, query=%dx%d == bounds %.0fx%.0f",
              (void *)old55, (void *)new55, q55w, q55h, pin55.width, pin55.height);
        return YES;
    }
    NSLog(@"[GLGeo] Task55 stepB verify: query=%dx%d expected=%.0fx%.0f -- NOT cured (recreate reads transposed geometry)",
          q55w, q55h, pin55.width, pin55.height);

    // --- Step C：反向转置旅程 ---
    NSLog(@"[GLGeo] Task55 realign stepC: transpose roundtrip (drawableSize transposed -> turns -> landscape -> turns)");
    __block CGSize pinC = pin55;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            CAMetalLayer *mlC = (CAMetalLayer *)layer;
            mlC.drawableSize = CGSizeMake(pinC.height, pinC.width);
        } @catch (NSException *e) {
            NSLog(@"[GLGeo] Task55 stepC exception: %@", e);
        }
    });
    ame55_wait_main_turns(2);
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            CAMetalLayer *mlC = (CAMetalLayer *)layer;
            mlC.drawableSize = pinC;
        } @catch (NSException *e) {
            NSLog(@"[GLGeo] Task55 stepC exception: %@", e);
        }
    });
    ame55_wait_main_turns(2);
    if (ame55_verify_surface(es55, cur55, pin55, &q55w, &q55h)) {
        NSLog(@"[GLGeo] Task55 realign CURED by stepC: query=%dx%d == bounds %.0fx%.0f (event-follow confirmed: roundtrip landed landscape)",
              q55w, q55h, pin55.width, pin55.height);
        return YES;
    }
    NSLog(@"[GLGeo] Task55 stepC verify: query=%dx%d expected=%.0fx%.0f -- NOT cured (gradient exhausted this attempt; compensation continues, retry after cooldown)",
          q55w, q55h, pin55.width, pin55.height);
    return NO;
}

// 探针 + 自愈主入口。swapIndex 从 1 计。
// 0 = undecided, 1 = normal, 2 = geo-heal blit
static void ame_task41_swap_forensics(EGLSurface surface, unsigned long swapIndex) {
    ame_es_t es = ame_es();
    if (es.getIntegerv == NULL || es.bindFramebuffer == NULL) return;

    static int s_mode = 0;          // 0 undecided / 1 normal / 2 blit
    // Task 76：取证降频 —— 健康 NORMAL 态下 swap 前零 GL/EGL 查询。
    //
    // 背景（bef0f08 双日志定案）：本函数自 Task41 起每帧在渲染线程跑
    //   3 次 glGetIntegerv + while(glGetError) 清错 + 2 次 eglQuerySurface；
    // 上游 Amethyst 的 swap 路径（ame_geo_check_and_heal）零 GL 状态查询。
    // MobileGlues 场次下这些查询直达 raw ANGLE，绕过前端状态机：
    //   1) glGetError 清空底层错误队列 —— MobileGlues 的错误转译依赖该
    //      队列，清空等于吞掉本应转译给 MC 的 GL 错误（正确性风险）；
    //   2) 每帧 5 次跨层查询是纯诊断税（Task58 后几何恒 NORMAL，多轮
    //      设备日志 0 失配）。
    // 降频策略：前 5 帧、每 200 帧、以及任何非 NORMAL 态（未决/补偿中）
    // 保持全量取证与执法；稳定 NORMAL 帧直接返回。逐帧几何执法由 Task48
    // guard（surface vs drawable 漂移检测）继续承担，viewport vs surface
    // 判定随 probe 帧复核——失配场景（旋转/resize）总会先经过 s_mode!=1
    // 或最多 200 帧内的 probe 帧，无检测盲区。
    const BOOL probe = (swapIndex <= 5) || (swapIndex % 200 == 0) || s_mode != 1;
    if (!probe) return;

    int drawFb = 0, readFb = 0, viewport[4] = {0, 0, 0, 0};
    es.getIntegerv(0x8CA9 /*GL_DRAW_FRAMEBUFFER_BINDING*/, &drawFb);
    es.getIntegerv(0x8CAA /*GL_READ_FRAMEBUFFER_BINDING*/, &readFb);
    es.getIntegerv(0x0BA2 /*GL_VIEWPORT*/, viewport);
    // Task 76：退役 while(es.getError() != 0) 清错循环——它会把底层 ANGLE
    // 错误队列清空，吞掉 MobileGlues 待转译的错误。getIntegerv 本身不产生
    // GL 错误，残留错误不影响本探针读数的正确性。

    int surfW = 0, surfH = 0;
    if (es.querySurface != NULL && surface != EGL_NO_SURFACE) {
        EGLint sw = 0, sh = 0;
        // Task 58 根因修正（画面分裂 + 输入错位定案）：EGL_HEIGHT=0x3056、
        // EGL_WIDTH=0x3057。自 Task41 起本探针把 0x3056 读进 surfW、0x3057 读进
        // surfH——宽高颠倒，1180x820 的健康表面被读成 "820x1180 转置" →
        // geoMismatch 每帧误判 → Task49 geo-heal 把完好的横屏帧 blit 进竖屏
        // scratch 再回写 → 分裂画面 + 输入错位全部由补偿链自造（Task48/49/50/
        // 51/52/53/55/56/57 六轮修复追的都是这个幻影；ANGLE 实现/Metal layer/
        // drawable 全程健康——创建时用宏查询的 1180x820 即铁证，Task57 split-brain
        // 探针读渲染线程 layer 恒横屏为旁证）。改用官方宏，永绝后患。
        if (es.querySurface(g_EglDisplay, surface, EGL_WIDTH, &sw) &&
            es.querySurface(g_EglDisplay, surface, EGL_HEIGHT, &sh)) {
            surfW = sw; surfH = sh;
        }
        // Task 58 一次性指纹：修正后的读数（下轮设备日志验证点——预期
        // surface == viewport，latch NORMAL，geo-heal/blit 全不触发）。
        static BOOL s_task58_logged = NO;
        if (!s_task58_logged && surfW > 0 && surfH > 0) {
            s_task58_logged = YES;
            NSLog(@"[GLGeo] Task58 query constants corrected: surface=%dx%d viewport=%dx%d (EGL_WIDTH=0x3057/EGL_HEIGHT=0x3056 per egl.h; legacy probe read them swapped since Task41)",
                  surfW, surfH, viewport[2], viewport[3]);
        }
    }
    if (surfW <= 0) surfW = viewport[2];
    if (surfH <= 0) surfH = viewport[3];

    // Task 49：几何失配判定（每帧、零回读、确定性）。
    // viewport 维度 != surface 维度 → MC 的帧无法铺满后缓冲（1x/2x 尺寸单位
    // 失配或竖横转置——latestlog 53febda 的确切形态）→ 立即启用 geo-heal。
    // 此判定优先于一切 latch：几何不匹配时“FBO 0 有内容”也不等于可见。
    //
    // Task 78（FSR 联动豁免）：MG 渲染器 + FSR 预设开启时，启动器把 MC 的
    // 窗口告知值缩到 surface/fsr_scale（updateSavedResolution），MC viewport
    // 恒小于 surface 且【两个维度都小】——这是 FSR1 升采样路径的预期形态，
    // 不是几何事故；补偿链（Task49 geo-heal / Task55 realign / Task51/52
    // drawable 钉扎）若介入会与 ApplyFSR 的 blit 打架。豁免条件刻意要求
    // viewport 双维严格小于 surface：转置形态（一维大一维小，如 820x1180 vs
    // 1180x820）不满足 → 真正的几何事故仍会走自愈链。FSR 关闭或非 MG
    // 渲染器时 viewport==surface，豁免天然无操作。
    static int s_task78_fsr_link = -1;
    if (s_task78_fsr_link < 0) {
        const char *ame78_renderer = getenv("AMETHYST_RENDERER");
        NSInteger ame78_fsr = getPrefInt(@"mobileglues.fsr1_setting");
        s_task78_fsr_link = (ame78_renderer != NULL &&
                             strcmp(ame78_renderer, RENDERER_NAME_MOBILEGLUES) == 0 &&
                             ame78_fsr > 0) ? 1 : 0;
        if (s_task78_fsr_link) {
            NSLog(@"[GLGeo] Task78 FSR linkage active: renderer=MobileGlues fsr1_setting=%ld -- viewport (render) < surface is the expected upscale geometry, compensation chain exempted", (long)ame78_fsr);
        }
    }
    const BOOL geoMismatch = (viewport[2] > 0 && viewport[3] > 0 &&
                              surfW > 0 && surfH > 0 &&
                              (viewport[2] != surfW || viewport[3] != surfH)) &&
                             !(s_task78_fsr_link &&
                               viewport[2] < surfW && viewport[3] < surfH);
    if (s_task78_fsr_link && viewport[2] > 0 && viewport[2] < surfW &&
        viewport[3] > 0 && viewport[3] < surfH) {
        static BOOL s_task78_logged = NO;
        if (!s_task78_logged) {
            s_task78_logged = YES;
            NSLog(@"[GLGeo] Task78 FSR render<surface expected: viewport=%dx%d surface=%dx%d -- geo-heal/realign exempted (MG FSR1 upscale path presents the frame)",
                  viewport[2], viewport[3], surfW, surfH);
        }
    }
    g_ame53_transposed = geoMismatch ? 1 : 0;
    if (!geoMismatch) {
        // Task53：对齐帧重置冷却——下一个失配剧集（几何从对齐转为失配）立即可
        // 重试。否则冷却期被跳过的尝试会让 mode 卡在 2（补偿态不重入分支），
        // realign 永远失去重臂机会（逻辑测试 S3 场景实测暴露）。
        g_ame53_last_ms = 0;
    }
    if (geoMismatch && s_mode != 2) {
        // Task 57（取证闭环）：失配首检出瞬间，从【渲染线程】（本函数运行处，
        // 与 ANGLE 的 layer 读取同一执行环境）读一次渲染层几何。主线程心跳
        // （SurfaceViewController updateGameStats）读同一 layer 对象恒报横屏
        // 1180x820，而 ANGLE 在此环境算出转置 820x1180——两侧并排入日志，
        // CALayer 跨线程 split-brain（622166a 心跳 2360x1640 vs 卫兵读
        // 1640x2360；bbe6d63 零 drift 行 = 渲染线程 drawableSize 读数与转置
        // 表面一致）一锤定音。sublayers 计数顺带证伪/证实 ANGLE 自建子层假说
        // （initialize 的 isKindOfClass:[CAMetalLayer class] 为真 → 直接使用，
        // 计数应为 0）。
        {
            CALayer *l57 = (__bridge CALayer *)g_ame48_layer_cf;
            if (l57 != nil) {
                BOOL m57 = [l57 isKindOfClass:CAMetalLayer.class];
                CGSize d57 = m57 ? ((CAMetalLayer *)l57).drawableSize : CGSizeZero;
                NSLog(@"[GLGeo] Task57 render-thread layer read (split-brain probe): bounds=%.0fx%.0f drawable=%.0fx%.0f scale=%.2f sublayers=%lu surface=%dx%d (对照主线程心跳: bounds/drawable 恒 1180x820)",
                      l57.bounds.size.width, l57.bounds.size.height,
                      d57.width, d57.height, (double)l57.contentsScale,
                      (unsigned long)[l57.sublayers count], surfW, surfH);
            }
        }
        // Task 55（画面分裂根治）：几何失配首检出时先治本——梯度式重对齐
        //（A 几何信号 / B 延迟重建 / C 反向转置旅程，一步治愈即停；治愈判定
        // = querySurface == layer bounds，杜绝 Task53 假成功）。成功后
        // surface==viewport==drawable==bounds，补偿全部回到 no-op。
        // Task 57 补丁生效时本分支预期不可达（表面冻结在创建几何 = viewport）；
        // 可达即说明 viewport 变化（窗口 resize）——stepB 销毁重建成为冻结
        // 体制下唯一合法换尺寸通道，予以保留。
        if (ame_task53_realign_surface()) {
            // 表面已对齐：mode 复位，下一帧重新 latch（几何对齐 + FBO0 有
            // 内容 → NORMAL，geo-heal 经 Task50 恢复分支自动退出）。
            s_mode = 0;
            g_ame53_transposed = 0;
            // 刷新本地 surfW/surfH：下方探针 / hierarchy / guard 全部输出新
            // 表面的真实状态。surface 形参此时是已销毁的旧句柄，改查
            // currentBundle 里的新表面。
            basic_render_window_t *b53 = currentBundle;
            if (b53 != NULL && es.querySurface != NULL && b53->gl.surface != EGL_NO_SURFACE) {
                EGLint sw53 = 0, sh53 = 0;
                // Task 58：常量修正（0x3056=EGL_HEIGHT、0x3057=EGL_WIDTH，
                // 与探针/验证函数同源同修）。
                if (es.querySurface(g_EglDisplay, b53->gl.surface, EGL_WIDTH, &sw53) &&
                    es.querySurface(g_EglDisplay, b53->gl.surface, EGL_HEIGHT, &sh53)) {
                    surfW = sw53;
                    surfH = sh53;
                }
            }
            NSLog(@"[RenderDiag] Task55 realign applied: viewport=%dx%d surface=%dx%d (mode reset; expect NORMAL latch next frame)",
                  viewport[2], viewport[3], surfW, surfH);
        } else {
        NSLog(@"[RenderDiag] Task49 geo mismatch ENGAGED: viewport=%dx%d surface=%dx%d (was mode=%d) -- frame covers only %.0f%% of backbuffer",
              viewport[2], viewport[3], surfW, surfH, s_mode,
              100.0 * (double)viewport[2] * (double)viewport[3] / ((double)surfW * (double)surfH));
        s_mode = 2;
        // Task51 Fix F'（Task55 语义反转）：转置固化期一次性把 drawableSize
        // 钉到【横屏 bounds 值】——与 Task52 guard 的 heal-align 同向。
        // 旧语义（钉成 surface 转置值"present 自洽"）被 a901050 日志证伪：
        // 它与 guard 一起反向钉死转置，阻断 ANGLE 依据 drawableSize 自愈；
        // 且旧语义下 drawableSize 拉锯（updateSavedResolution 写 bounds）即
        // 用户看到的"画面分裂"。失配期间保持单一写者单一方向（横屏信号）；
        // 治愈后本写入变同值 no-op。主线程 dispatch_async（e6886e2 证明主
        // 线程写有效；622166a 证伪渲染线程写）。
        // 触发条件 s_mode != 2 保证整个失配剧集至多执行一次，guard 随后接管。
        void *ame51_layer_ref = g_ame48_layer_cf;
        if (ame51_layer_ref != NULL) {
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    CALayer *l = (__bridge CALayer *)ame51_layer_ref;
                    if ([l isKindOfClass:CAMetalLayer.class]) {
                        CAMetalLayer *ml = (CAMetalLayer *)l;
                        CGSize old = ml.drawableSize;
                        CGFloat bw = MAX(1.0, round(l.bounds.size.width));
                        CGFloat bh = MAX(1.0, round(l.bounds.size.height));
                        // Task 60：像素口径（bounds x contentsScale）——与
                        // surface/drawable 全链一致；旧 1x 点数写入会把 2x
                        // drawableSize 拉回 1x（模糊回归）。
                        CGFloat sc51 = l.contentsScale;
                        if (sc51 <= 0.0) sc51 = 1.0;
                        CGSize tgt51 = CGSizeMake(round(bw * sc51), round(bh * sc51));
                        if (fabs(old.width - tgt51.width) > 0.5 || fabs(old.height - tgt51.height) > 0.5) {
                            ml.drawableSize = tgt51;
                            NSLog(@"[GLGeo] Task51 heal-align (main thread): drawableSize %.0fx%.0f -> %.0fx%.0f == bounds x scale (landscape signal, same direction as Task52 guard heal)",
                                  old.width, old.height, tgt51.width, tgt51.height);
                        } else {
                            NSLog(@"[GLGeo] Task51 heal-align: already at bounds x scale %.0fx%.0f (landscape signal in place)", tgt51.width, tgt51.height);
                        }
                    }
                } @catch (NSException *e) {
                    NSLog(@"[GLGeo] Task51 heal-align exception: %@", e);
                }
            });
        }
        }  // Task53 else：重对齐不可用/失败 → 既有补偿路径（行为不变）
    }

    if (probe) {
        // Task 75：回读探针退役（整块移除）。原实现在此对当前 FBO 中心、
        // FBO 0 中心、FBO 0 远角各做 8x8 glReadPixels（UBYTE + FLOAT 兜底），
        // uniq 计数判断“有内容”。4770b53 日志：同一探针连续 46 次成功后
        // （swap#1..#8200 全部 err=0x0），第 47 次 swap#8400（游戏暂停、
        // dynamic_fps 降帧剧集）在回读中触发 angle::CopyBGRA8ToRGBA8+0x114
        // SIGBUS，帧栈：GL_ReadPixels ← ame_task41_swap_forensics ←
        // gl_swap_buffers。根因：drawFb==0 时回读对象是即将 eglSwapBuffers
        // 呈现的 CAMetalLayer drawable 纹理，ANGLE Metal readback 的 staging
        // blit 与 drawable 生命周期存在竞态（暂停时帧间隔变长、回收周期
        // 改变，竞态窗口被踩中）；iOS glReadPixels 间歇崩溃为社区已知现象，
        // 上游 Amethyst swap 路径从不回读。诊断收益早已归零（Task58 后几何
        // 判据已覆盖），风险是整机崩溃——退役，swap 路径自此零回读。
        NSLog(@"[RenderDiag] swap#%lu (Task75 geo-probe): drawFb=%d readFb=%d viewport=%d,%d %dx%d surface=%dx%d mode=%d (readback retired -- CopyBGRA8ToRGBA8 SIGBUS @4770b53)",
              swapIndex, drawFb, readFb, viewport[0], viewport[1], viewport[2], viewport[3],
              surfW, surfH, s_mode);

        // Task51 取证：呈现层可见性全量 dump（首帧 + 每 500 帧，主线程执行）。
        // 动机：连续四轮日志（48/49/50/51 基线）都显示"GL 全绿 + present 成功"
        // 但用户黑屏——断点极可能在 UIKit 呈现层（layer 不在树 / 被遮挡 /
        // hidden / transform 旋转 / window 不显示）。本 dump 一次打印全部
        // 可见性关键状态，下轮日志无论好坏都能一锤定音。
        if (swapIndex == 1 || (swapIndex > 0 && swapIndex % 500 == 0)) {
            void *ame51_h_layer = g_ame48_layer_cf;
            int h_sw = surfW, h_sh = surfH;
            unsigned long h_idx = swapIndex;
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    CALayer *l = (__bridge CALayer *)ame51_h_layer;
                    if (l == nil) {
                        NSLog(@"[GLGeo] Task51 hierarchy #%lu: render layer is NIL", h_idx);
                        return;
                    }
                    NSMutableString *chain = [NSMutableString stringWithCapacity:256];
                    CALayer *cur = l;
                    int depth = 0;
                    while (cur != nil && depth < 10) {
                        [chain appendFormat:@" -> [%@ %dx%d pos=(%d,%d) hid=%d op=%.2f%@]",
                            NSStringFromClass(cur.class),
                            (int)round(cur.bounds.size.width), (int)round(cur.bounds.size.height),
                            (int)round(cur.position.x), (int)round(cur.position.y),
                            (int)cur.hidden, (double)cur.opacity,
                            CATransform3DIsIdentity(cur.transform) ? @"" : @" ROT"];
                        cur = (CALayer *)cur.superlayer;
                        depth++;
                    }
                    NSString *dw = @"n/a";
                    if ([l isKindOfClass:CAMetalLayer.class]) {
                        CAMetalLayer *ml = (CAMetalLayer *)l;
                        dw = [NSString stringWithFormat:@"%.0fx%.0f",
                              ml.drawableSize.width, ml.drawableSize.height];
                    }
                    BOOL inTree = (l.superlayer != nil);
                    NSLog(@"[GLGeo] Task51 hierarchy #%lu: layer=%p drawable=%@ scale=%.2f surface=%dx%d inTree=%d chain=%@",
                          h_idx, ame51_h_layer, dw, (double)l.contentsScale,
                          h_sw, h_sh, (int)inTree, chain);
                } @catch (NSException *e) {
                    NSLog(@"[GLGeo] Task51 hierarchy exception: %@", e);
                }
            });
        }

        // ====================================================================
        // Task 52：呈现层可见性卫兵（每 50 帧一次，主线程异步执行，零渲染阻塞）。
        //
        // 根因（hierarchy dump 实锤，b805f51 日志 8967 行）：CAMetalLayer
        //   hid=1 —— 供应商 libSDL3.dylib 的 Zalith 同源嵌入补丁在每次真实
        //   SDL_CreateWindow / SDL_Metal_CreateView 时按类名查找并
        //   [GameSurfaceView setHidden:YES]（反汇编 @0x152e6c）。GL 帧全部
        //   呈现进这个被隐藏的 layer → 渲染全绿 + 黑屏。
        // 本卫兵持续执法三不变量（嵌入层的步骤 3.5 负责首拍，这里兜住
        //   MetalCreate/后续嵌入重跑/任何外部隐藏者的复发）：
        //   1) 渲染 layer 可见；2) SDL 触摸视图 z 序高于画面层；3)
        //   drawableSize == surface 尺寸（present 自洽，接替一次性 Fix F'，
        //   对抗宿主 updateSavedResolution 的周期性写回）。
        // ====================================================================
        if (swapIndex == 1 || (swapIndex > 0 && swapIndex % 50 == 0)) {
            int g52_sw = surfW, g52_sh = surfH;
            unsigned long g52_idx = swapIndex;
            void *g52_layer = g_ame48_layer_cf;
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    // 1) 揭开渲染层（主线程读写，权威值）
                    UIView *g52_gs = [SurfaceViewController surface];
                    if (g52_gs != nil && (g52_gs.hidden || g52_gs.layer.hidden)) {
                        g52_gs.hidden = NO;
                        g52_gs.layer.hidden = NO;
                        NSLog(@"[GLGeo] Task52 guard #%lu: render layer was HIDDEN by external code -- UN-HIDDEN (surface=%dx%d)",
                              g52_idx, g52_sw, g52_sh);
                    }
                    // 2) z 序：SDL 触摸视图必须在画面层之上（否则触摸被画面层截走）
                    UIView *g52_sdl = (__bridge UIView *)ame_hook_getEmbeddedSDLView();
                    if (g52_gs != nil && g52_sdl != nil && g52_gs.superview != nil &&
                        g52_sdl.superview == g52_gs.superview) {
                        NSArray *g52_subs = g52_gs.superview.subviews;
                        NSUInteger g52_gi = [g52_subs indexOfObjectIdenticalTo:g52_gs];
                        NSUInteger g52_si = [g52_subs indexOfObjectIdenticalTo:g52_sdl];
                        if (g52_gi != NSNotFound && g52_si != NSNotFound && g52_gi > g52_si) {
                            [g52_gs.superview insertSubview:g52_gs belowSubview:g52_sdl];
                            NSLog(@"[GLGeo] Task52 guard #%lu: z-order re-pinned (GameSurfaceView below SDL touch view)",
                                  g52_idx);
                        }
                    }
                    // 3) present 几何执法（Task55 语义自适应）：
                    //    - 失配未治愈（转置锁死）：写【横屏 bounds 值】——持续
                    //      给 ANGLE“回横屏”信号。a901050 日志铁证：写 surface
                    //      转置值（820x1180）是反向钉死——它阻断 ANGLE 依据
                    //      drawableSize 自愈的一切可能（622166a 铁证 ANGLE
                    //      具备跟随 layer 几何能力；Task50 证明主线程写入是
                    //      唯一可靠通道）。若 ANGLE 不跟随，压扁 blit + CA
                    //      拉伸双重互逆、纵横比还原，优于持续压扁+拉锯分裂。
                    //    - 已治愈/无失配：写 surface 值（present 自洽维护，
                    //      治愈后两值相同，同值 no-op）。
                    CALayer *g52_l = (__bridge CALayer *)g52_layer;
                    if (g52_l != nil && [g52_l isKindOfClass:CAMetalLayer.class] &&
                        g52_sw > 0 && g52_sh > 0) {
                        CAMetalLayer *g52_ml = (CAMetalLayer *)g52_l;
                        CGSize g52_old = g52_ml.drawableSize;
                        BOOL g52_heal = ame_gl_surface_transposed();
                        // Task 60：heal 分支同样用像素口径（bounds x
                        // contentsScale）——与 present 分支的 surface 像素
                        // 口径同尺度，避免把 2x drawableSize 拉回 1x。
                        CGFloat g52_sc = g52_l.contentsScale;
                        if (g52_sc <= 0.0) g52_sc = 1.0;
                        CGSize g52_target = g52_heal
                            ? CGSizeMake(round(MAX(1.0, round(g52_l.bounds.size.width)) * g52_sc),
                                         round(MAX(1.0, round(g52_l.bounds.size.height)) * g52_sc))
                            : CGSizeMake(g52_sw, g52_sh);
                        if (fabs(g52_old.width - g52_target.width) > 0.5 ||
                            fabs(g52_old.height - g52_target.height) > 0.5) {
                            g52_ml.drawableSize = g52_target;
                            NSLog(@"[GLGeo] Task52 guard #%lu: %@ drawable %.0fx%.0f -> %.0fx%.0f (%@)",
                                  g52_idx, g52_heal ? @"heal-align" : @"present-align",
                                  g52_old.width, g52_old.height,
                                  g52_target.width, g52_target.height,
                                  g52_heal ? @"transposed-uncured: feeding landscape bounds signal"
                                           : @"== surface, self-consistent present");
                        }
                    }
                } @catch (NSException *e) {
                    NSLog(@"[GLGeo] Task52 guard exception: %@", e);
                }
            });
        }

        // latch 判定（Task 75 重写：纯几何判据，零回读）。
        // 旧版依赖 FBO 0 内容回读（fbo0Content/fbo0Flat）——回读已随 Task75
        // 退役（SIGBUS 崩溃源，见上方退役说明）。新判据：几何对齐
        // （viewport==surface）本身就是"帧能铺满后缓冲"的充要信号（Task58
        // 定案：surface==viewport 的会话 100% 健康，本日志 43 次探针同证）。
        // 几何失配的检出/治愈/降级路径（geoMismatch 分支：Task57 探测 →
        // Task55 realign → Task51/52 钉扎）不受影响，全部零回读。进入
        // mode=2 的唯一通道 = geoMismatch 分支的 realign 失败；退出通道保留
        // Task50 语义（几何恢复对齐即退出，不再要求内容证据）。
        if (s_mode == 0 && !geoMismatch) {
            s_mode = 1;
            NSLog(@"[RenderDiag] Task41 latch: NORMAL present (geometry aligned, readback retired by Task75)");
        } else if (s_mode == 2 && !geoMismatch) {
            // Task 50 语义保留（判据改几何）：几何恢复对齐 → 退出 geo-heal，
            // 停止逐帧 scratch 中转（旧版一旦进入 mode=2 便永不退出，几何
            // 修复后仍每帧 blit，白耗带宽且状态机无法回到正常呈现路径）。
            s_mode = 1;
            NSLog(@"[RenderDiag] Task50 heal disengaged: geometry aligned (viewport==surface) -- back to normal present");
        }
    }

    if (s_mode == 2) {
        // Task 49：两段 scratch-FBO blit（源=MC 帧 viewport 区域，缩放铺满 FBO 0）
        ame_task49_geo_heal_blit(es, drawFb, readFb, viewport[2], viewport[3], surfW, surfH);
    }
}

// ============================================================================
// Task 48：呈现几何卫兵（GL 路径黑屏根因修复）
//
// 设备铁证（latestlog 1518ce1，iPad Air M4 / iPadOS 26.6）：
//   - 渲染管线 100% 健康：1032 帧 swap 全成功、fps=57、swapFail=0、GL 零错误、
//     MC 26.3 到标题画面（图集/音效全载入）、fbo 内容探针 uniq=44-49；
//   - [RenderDiag] EGL surface 创建时 = 2360x1640（layer 当时正确，eglQuerySurface
//     证实），但到交换时 surface = 1640x2360（竖屏转置）且 1032 帧永不恢复；
//   - CAMetalLayer 心跳报 drawable=2360x1640（横屏正确）、bounds=1180x820；
//   - MC 的 glViewport = 1180x820（SDL3-on-iOS 以"点"而非"像素"回报窗口尺寸，
//     MC 请求 2360x1640 被钳到 1180x820 → MC 实际以 1x 渲染）。
// 三者互相失配 → 呈现的 backbuffer 维度与 drawable 维度对不上 → 屏幕全黑。
//
// 修复策略（对"谁转置了 surface"不做任何单一假设，全部自愈）：
//   1) 创建钉扎：MobileGlues 渲染器在 eglCreateWindowSurface 前把
//      drawableSize 钉到 layer.bounds（点数）——即 MC 将要渲染的真实尺寸
//      （1180x820）。ANGLE 在创建时刻会读 layer（本日志已证实此读取可靠），
//      于是 surface == MC viewport == drawable，三者一致，画面 1:1 全屏。
//   2) 交换卫兵：每次 eglSwapBuffers 前核对 surface 实际尺寸 vs layer
//      drawableSize，不等则立刻把 drawableSize 钉回 surface 尺寸
//      （drawable 必须等于将要呈现的 backbuffer 尺寸——这是"帧能上屏"的
//      硬约束，无论 ANGLE/MG/旋转把哪边改了都能收敛）。
//   3) 重建升级：若 surface 偏离创建时的期望尺寸并稳定持续 30+ 帧，
//      限速（5s）重建 EGL window surface（先钉 layer，再创建，MG 前端
//      MakeCurrent 重绑，销毁旧表面）——重建是重置 ANGLE 内部表面尺寸的
//      唯一可靠手段。最多 3 次，避免无限循环。
//
// 线程安全：卫兵在 MC 渲染线程（上下文 current）运行；只触碰 CALayer/
// CAMetalLayer API（Apple 明确支持渲染线程驱动 CAMetalLayer），不碰 UIKit。
// layer 指针在创建时以 CFBridgingRetain 缓存，避免渲染线程访问 UIView。
// Vulkan 路径完全不受影响（本文件仅 GL 桥）。
// ============================================================================
//（声明已前置至 Task49 静态区——见 g_ame48_layer_cf）
static int   g_ame48_expected_w = 0;         // 期望表面宽（创建钉扎值）
static int   g_ame48_expected_h = 0;         // 期望表面高
static long  g_ame48_drift_swaps = 0;        // surface != drawable 的连续帧数（纯取证）
static int   g_ame48_recreates = 0;          // 历史保留（Task50 起不再重建）
static uint64_t g_ame48_last_recreate_ms = 0;

/// 创建时调用：缓存呈现 layer、记录期望尺寸、复位卫兵状态。
static void ame48_record_creation(CALayer *layer, EGLDisplay dpy, EGLSurface surface) {
    if (g_ame48_layer_cf != NULL) {
        CFRelease(g_ame48_layer_cf);
        g_ame48_layer_cf = NULL;
    }
    if (layer != nil) {
        g_ame48_layer_cf = (void *)CFBridgingRetain(layer);
    }
    g_ame48_drift_swaps = 0;
    g_ame48_recreates = 0;
    g_ame48_last_recreate_ms = 0;
    g_ame48_expected_w = 0;
    g_ame48_expected_h = 0;
    // 期望值 = 创建完成时 ANGLE 报告的表面实际尺寸（创建钉扎生效后
    // 即 MC 的渲染尺寸）。查询失败则保持 0（卫兵漂移检测停用，
    // 但"drawable == surface"的逐帧钉扎仍然全程有效）。
    ame_es_t es = ame_es();
    if (es.querySurface != NULL && surface != EGL_NO_SURFACE) {
        EGLint sw = 0, sh = 0;
        if (es.querySurface(dpy, surface, EGL_WIDTH, &sw) &&
            es.querySurface(dpy, surface, EGL_HEIGHT, &sh) && sw > 0 && sh > 0) {
            g_ame48_expected_w = sw;
            g_ame48_expected_h = sh;
        }
    }
    NSLog(@"[GLGeo] Task48 creation recorded: layer=%p expectedSurface=%dx%d",
          g_ame48_layer_cf, g_ame48_expected_w, g_ame48_expected_h);
}

/// 交换卫兵：gl_swap_buffers 每帧调用（渲染线程、上下文 current）。
/// Task 50：本函数已降级为**纯取证**（只读 + 日志，零写入）。
///
/// 622166a 设备日志证明旧卫兵的全部三个自愈动作无效且有害：
///   1. 跨线程写 drawableSize（渲染线程 vs 主线程 CA 提交树状态分叉：
///      心跳读到 drawable=2360x1640 而卫兵读到 1640x2360，全日志 0 条
///      "Task48 pin" = 逐帧钉扎从未生效）；
///   2. 同 layer 二次 eglCreateWindowSurface 恒 EGL_BAD_ALLOC 0x3003；
///   3. 钉扎与 updateSavedResolution（旋转时主线程写 2x）互相打架。
/// Task60 之后几何由"原生 scale 像素单一事实源"保证一致（gl_init_context
/// 创建时对齐 + updateSavedResolution GL 分支跟随 bounds x scale 像素），
/// 本函数只保留漂移取证（surface vs drawable，同为像素口径）。
/// ANGLE 会随 layer 自然 resize（622166a 的 surface 转置事件即实证），
/// 瞬态失配由 Task49 geo-heal blit 兜底（双向 latch，几何恢复即退出）。
static void ame48_swap_geometry_guard(basic_render_window_t *bundle) {
    if (bundle == NULL || bundle->gl.surface == EGL_NO_SURFACE) return;
    CALayer *layer = (__bridge CALayer *)g_ame48_layer_cf;
    if (layer == nil || ![layer isKindOfClass:CAMetalLayer.class]) return;
    ame_es_t es = ame_es();
    if (es.querySurface == NULL) return;

    EGLint sw = 0, sh = 0;
    if (!es.querySurface(g_EglDisplay, bundle->gl.surface, EGL_WIDTH, &sw) ||
        !es.querySurface(g_EglDisplay, bundle->gl.surface, EGL_HEIGHT, &sh)) {
        return;  // 查询失败（EGL 错误）不干预
    }
    if (sw <= 0 || sh <= 0) return;

    CAMetalLayer *ml = (CAMetalLayer *)layer;
    CGSize d = ml.drawableSize;
    int dw = (int)round(d.width), dh = (int)round(d.height);

    if (dw != sw || dh != sh) {
        g_ame48_drift_swaps++;
        if (g_ame48_drift_swaps == 1 || g_ame48_drift_swaps % 200 == 0) {
            NSLog(@"[GLGeo] Task50 drift (info only): surface=%dx%d drawable=%dx%d bounds=%.0fx%.0f (consecutive=%ld) -- ANGLE resizes with layer; transient mismatch covered by geo-heal blit",
                  (int)sw, (int)sh, dw, dh,
                  layer.bounds.size.width, layer.bounds.size.height,
                  g_ame48_drift_swaps);
        }
    } else {
        g_ame48_drift_swaps = 0;
    }
}

static void* load_egl_symbol(void *dl_handle, const char *symbol) {
    dlerror();
    void *addr = dlsym(dl_handle, symbol);
    const char *error = dlerror();
    if (!addr || error) {
        NSLog(@"EGLBridge: failed to resolve %s: %s", symbol, error ?: "symbol not found");
    }
    return addr;
}

// ============================================================================
// Task 36：MobileGlues 前端 EGL 路由（GL 路径黑屏修复）
//
// 设备实测（latestlog e28e4c3 + libmobileglues.dylib）：MC 26.3 的 OpenGL
// 后端被接受（c71dcfa 的 glGetError 一致性检查已过），渲染循环全速运转
// （fps=57~58、eglSwapBuffers 成功 485 次、零失败、零 GL 错误），但屏幕全黑、
// 只有声音。日志里 MobileGlues 自己给出了三条铁证：
//
//   [MG] SYMBOL THEFT: ... （平坦命名空间把 gl* 解析给了别的镜像 —— 警告性）
//   [MG] depth filter scan: context untracked (EGL bypassed this layer)...
//   （深位查询返回 -1，每上下文状态全部落在 context-0 回退实例上）
//
// 根因：本 bridge 此前把 MobileGlues 的 EGL 符号从 libtinygl4angle.dylib
// （raw ANGLE）解析，上下文/MakeCurrent 全部绕过了 MobileGlues 2.0.16+ 的
// 前端 EGL。MobileGlues 的 egl/context.cpp 里 MGContext 虚拟上下文记录只能
// 由前端 eglCreateContext 创建、由前端 eglMakeCurrent 绑定（g_current_ctx +
// mg_framebuffer_bind_context(id) + gl_state 重指向）。被绕过时
// mg_context_make_current 走 “handle is not tracked, leaving no current
// record” 分支 —— g_current_ctx 永远为 NULL，FBO 转译/状态机全部退化为
// 进程级单例，MC 26.3 RenderPearl 的合成画面从未进入默认帧缓冲，
// eglSwapBuffers 呈现的是从未被画过的黑帧。
//
// 修复：生命周期函数（eglBindAPI/eglCreateContext/eglDestroyContext/
// eglMakeCurrent/eglSwapBuffers/eglSwapInterval）改经 libmobileglues.dylib
// 的前端 EGL；基础设施函数（display/config/surface 等 —— 前端本来就是纯
// 透传）保持 raw ANGLE，两者指向同一个 ANGLE 实例（tinygl4angle 只是
// libEGL/libGLESv2 framework 的别名垫片）。
//
// 时序约束：前端函数内部的 LOAD_EGL 静态指针是首次调用时一次性初始化的，
// 而后端句柄 `egl` 只在 mg_init_gles()（Apple 平台）里绑定；mg_init_gles
// 又需要“有当前上下文”才能做正确的 caps 检测。因此在首个前端调用之前，
// 用 raw ANGLE 建一个 16x16 pbuffer + 临时 ES 上下文 → eglMakeCurrent →
// 调 mg_init_gles()（真实上下文在场，caps 检测有效）→ 释放并销毁临时资源
// → 再把生命周期指针切换到前端。引导失败则保持旧行为（全 raw ANGLE），
// 不引入新风险。
// ============================================================================
static void *ame_mg_handle = NULL;        // libmobileglues.dylib（前端 EGL/GL）
static void *ame_mg_angle_handle = NULL;  // libtinygl4angle.dylib（raw ANGLE 垫片）
static BOOL  ame_mgFrontendActive = NO;   // 生命周期函数已切到前端
static BOOL  ame_mgBootstrapTried = NO;   // 引导只尝试一次

typedef void (*ame_mg_init_gles_t)(void);
static ame_mg_init_gles_t ame_mg_init_gles = NULL;

// 引导专用 raw ANGLE 指针（不进 handle 表：仅 bootstrap + 取证使用）
typedef EGLSurface (*ame_fn_create_pbuffer)(EGLDisplay, EGLConfig, const EGLint *);
typedef EGLBoolean (*ame_fn_egl_query_surface)(EGLDisplay, EGLSurface, EGLint, EGLint *);
static ame_fn_create_pbuffer       ame_raw_create_pbuffer = NULL;
static ame_fn_egl_query_surface    ame_raw_query_surface = NULL;
static PFNEGLCREATECONTEXTPROC     ame_raw_create_context = NULL;
static PFNEGLMAKECURRENTPROC       ame_raw_make_current = NULL;
static PFNEGLDESTROYCONTEXTPROC    ame_raw_destroy_context = NULL;
static PFNEGLDESTROYSURFACEPROC    ame_raw_destroy_surface = NULL;
static PFNEGLSWAPINTERVALPROC      ame_raw_swap_interval = NULL;   // Task 76 双保险

static bool dlsym_EGL() {
    // EGL 符号来源：
    //   - Mithril / MobileGL：自带完整 EGL 实现，必须从自身 dylib 解析。
    //     若复用 ANGLE 的 EGL，会创建 ANGLE 的 Metal 上下文而不是渲染器自己的
    //     surface，且 eglChooseConfig 在这些渲染器请求的属性组合下可能返回 0
    //     个配置，触发 gl_init_context 里的 assert(bundle->config) 崩溃。
    //   - MobileGlues：生命周期函数经其前端 EGL（Task 36，见上方大段注释），
    //     其余基础设施函数仍从 ANGLE 解析（前端本来就是透传，且必须在
    //     mg_init_gles 引导完成前避免触发前端内部的 LOAD_EGL 一次性初始化）。
    //   - 其余渲染器（gl4es / ANGLE / LTW）：全部从 ANGLE 解析。
    const char *renderer = getenv("AMETHYST_RENDERER");
    // SFPEW 叠加模式下 AMETHYST_RENDERER 已换成 libSimpleFPEWrapper.dylib，但 EGL
    // 基础设施必须由真后端提供（对齐安卓：POJAVEXEC_EGL 不变，只换 renderLibrary）。
    // 真后端名在 AMETHYST_SFPEW_BACKEND（JavaLauncher.m 设置）：
    //   - MobileGlues：与单独使用时一致，EGL 走 ANGLE
    //   - MobileGL(-gles)：自带 EGL，从 libMobileGL.dylib 解析
    const char *eglRenderer = renderer;
    if (isSFPEWRenderer(renderer)) {
        const char *sfpewBackend = getenv("AMETHYST_SFPEW_BACKEND");
        if (sfpewBackend != NULL && sfpewBackend[0] != '\0') eglRenderer = sfpewBackend;
    }
    const char *eglLibrary = isSelfEglRenderer(eglRenderer) ? eglRenderer : RENDERER_NAME_MTL_ANGLE;
    NSString *eglPath = [NSString stringWithFormat:@"@rpath/%s", eglLibrary ?: ""];
    void* dl_handle = dlopen(eglPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (!dl_handle) {
        NSLog(@"EGLBridge: failed to load %@ for renderer %s: %s",
            eglPath, renderer ?: "<unset>", dlerror() ?: "unknown dlopen error");
        return false;
    }

    // Task 36：MobileGlues 前端 EGL 准备（不改变任何行为，仅记录句柄/符号，
    // 真正的指针切换发生在 ame_mgBootstrap 成功之后）。
    if (renderer && strcmp(renderer, RENDERER_NAME_MOBILEGLUES) == 0 &&
        !isSelfEglRenderer(renderer)) {
        ame_mg_angle_handle = dl_handle;
        void *mg = dlopen("@rpath/" RENDERER_NAME_MOBILEGLUES, RTLD_NOW | RTLD_LOCAL);
        if (!mg) {
            mg = dlopen(RENDERER_NAME_MOBILEGLUES, RTLD_NOW | RTLD_LOCAL);
        }
        if (mg) {
            ame_mg_handle = mg;
            ame_mg_init_gles = (ame_mg_init_gles_t)dlsym(mg, "mg_init_gles");
            NSLog(@"[MG-Bridge] MobileGlues frontend image loaded (%p, mg_init_gles=%p); "
                  @"lifecycle EGL will route through it after bootstrap",
                  mg, (void *)ame_mg_init_gles);
        } else {
            NSLog(@"[MG-Bridge] failed to load " RENDERER_NAME_MOBILEGLUES
                  @" (%s) -- EGL stays on raw ANGLE (legacy behavior)",
                  dlerror() ?: "unknown");
        }
        // 引导与取证用的 raw 指针（始终来自 ANGLE 垫片）
        ame_raw_create_pbuffer   = (ame_fn_create_pbuffer)load_egl_symbol(dl_handle, "eglCreatePbufferSurface");
        ame_raw_query_surface    = (ame_fn_egl_query_surface)load_egl_symbol(dl_handle, "eglQuerySurface");
        ame_raw_create_context   = (PFNEGLCREATECONTEXTPROC)load_egl_symbol(dl_handle, "eglCreateContext");
        ame_raw_make_current     = (PFNEGLMAKECURRENTPROC)load_egl_symbol(dl_handle, "eglMakeCurrent");
        ame_raw_destroy_context  = (PFNEGLDESTROYCONTEXTPROC)load_egl_symbol(dl_handle, "eglDestroyContext");
        ame_raw_destroy_surface  = (PFNEGLDESTROYSURFACEPROC)load_egl_symbol(dl_handle, "eglDestroySurface");
        // Task 76：raw eglSwapInterval —— POJAV_DISABLE_VSYNC 双保险直调用。
        // handle.eglSwapInterval 在 bootstrap 后指向 MobileGlues 前端（前端
        // 理论上透传后端，但 bef0f08 MG 场 33 条心跳在 max.fps=260 解锁下
        // fps 从未超过 60，vsync 疑似未被 ANGLE Metal 接受）。raw 直调绕过
        // 前端转译链，两路各设一次（幂等），设备日志双路打印返回值分诊。
        ame_raw_swap_interval    = (PFNEGLSWAPINTERVALPROC)load_egl_symbol(dl_handle, "eglSwapInterval");
    }

    // NOTE: mg_init_gles() is called from gl_make_current() after the
    // EGL context is made current, because init_target_gles() queries
    // GL version/extensions which requires an active context.

    // LTW 模式：eglCreateContext / eglDestroyContext / eglMakeCurrent 三个函数
    // 必须从 libltw.dylib 直接 dlsym 解析，而非 ANGLE。
    //
    // 原因：LTW 是 OpenGL Core 3.3 → OpenGL ES 3 的转译层，它在这三个函数中
    // 注入 wrapper 逻辑（创建 ES3 上下文 + 安装 GL 函数指针转译表 + 伪装 ARB 扩展）。
    // 如果直接使用 ANGLE 的 eglCreateContext，创建的是原生 ES3 上下文，MC 1.17+
    // 检测到 GL_VERSION 不含 "Core Profile" 会拒绝启动；Sodium/Iris 的 ARB 扩展
    // 查询也会全部失败。LTW 的 wrapper 让 MC 看到的是 OpenGL 3.3 Core Profile，
    // 且主动声明 GL_ARB_buffer_storage 等 ARB 扩展，让 Sodium 的 persistent mapped
    // buffers / texture buffers 和 Iris 的 draw_buffers_blend 正常工作。
    //
    // 注意：不能用 RTLD_DEFAULT dlsym（iOS 的 flat namespace 中 ANGLE 符号会先命中），
    // 必须显式 dlopen libltw.dylib 后从其 handle dlsym。
    //
    // 其余 EGL 函数（eglChooseConfig / eglCreateWindowSurface / eglSwapBuffers 等）
    // LTW 不做 wrapper，直接从 ANGLE 解析。
    BOOL useLTW = renderer && strcmp(renderer, RENDERER_NAME_LTW) == 0;
    void *ltw_handle = NULL;
    if (useLTW) {
        ltw_handle = dlopen("@rpath/" RENDERER_NAME_LTW, RTLD_NOW | RTLD_LOCAL);
        if (!ltw_handle) {
            NSLog(@"EGLBridge: LTW renderer selected but failed to load libltw.dylib: %s",
                  dlerror() ?: "unknown dlopen error");
            // 致命错误：LTW 模式下没有 LTW 的 wrapper，MC 1.17+ 无法启动
            return false;
        }
        NSLog(@"EGLBridge: LTW mode active, eglCreateContext/Destroy/MakeCurrent resolved from libltw.dylib");
    }

    // SFPEW：与 LTW 同构的部分拦截层。基础设施（display / config / surface）
    // 仍从 ANGLE 解析，生命周期 wrapper 从 libSimpleFPEWrapper.dylib 取，
    // 否则固定管线仿真根本不会被安装（SFPEW 静默降级为透传）。
    BOOL useSFPEW = renderer && isSFPEWRenderer(renderer);
    void *sfpew_handle = NULL;
    if (useSFPEW) {
        sfpew_handle = dlopen("@rpath/" RENDERER_NAME_SFPEW, RTLD_NOW | RTLD_LOCAL);
        if (!sfpew_handle) {
            NSLog(@"EGLBridge: SFPEW renderer selected but failed to load %s: %s",
                  RENDERER_NAME_SFPEW, dlerror() ?: "unknown dlopen error");
            return false;
        }
        NSLog(@"EGLBridge: SFPEW mode active, lifecycle EGL resolved from %s",
              RENDERER_NAME_SFPEW);
    }

    memset(&handle, 0, sizeof(handle));
    handle.eglBindAPI = load_egl_symbol(dl_handle, "eglBindAPI");
    handle.eglChooseConfig = load_egl_symbol(dl_handle, "eglChooseConfig");
    if (useLTW && ltw_handle) {
        // 从 LTW 解析三个 wrapper 函数（关键：让 LTW 的 GL Core→ES 转译逻辑生效）
        handle.eglCreateContext = load_egl_symbol(ltw_handle, "eglCreateContext");
        handle.eglDestroyContext = load_egl_symbol(ltw_handle, "eglDestroyContext");
        handle.eglMakeCurrent = load_egl_symbol(ltw_handle, "eglMakeCurrent");
    } else if (useSFPEW && sfpew_handle) {
        // 从 SFPEW 解析三个 wrapper（关键：FPE 的 GL 入口转译表在
        // eglCreateContext / eglMakeCurrent 里安装，直接调 ANGLE 的会绕过它）
        handle.eglCreateContext = load_egl_symbol(sfpew_handle, "eglCreateContext");
        handle.eglDestroyContext = load_egl_symbol(sfpew_handle, "eglDestroyContext");
        handle.eglMakeCurrent = load_egl_symbol(sfpew_handle, "eglMakeCurrent");
    } else {
        handle.eglCreateContext = load_egl_symbol(dl_handle, "eglCreateContext");
        handle.eglDestroyContext = load_egl_symbol(dl_handle, "eglDestroyContext");
        handle.eglMakeCurrent = load_egl_symbol(dl_handle, "eglMakeCurrent");
    }
    handle.eglCreateWindowSurface = load_egl_symbol(dl_handle, "eglCreateWindowSurface");
    handle.eglDestroySurface = load_egl_symbol(dl_handle, "eglDestroySurface");
    handle.eglGetConfigAttrib = load_egl_symbol(dl_handle, "eglGetConfigAttrib");
    handle.eglGetCurrentContext = load_egl_symbol(dl_handle, "eglGetCurrentContext");
    handle.eglGetDisplay = load_egl_symbol(dl_handle, "eglGetDisplay");
    handle.eglGetError = load_egl_symbol(dl_handle, "eglGetError");
    handle.eglGetPlatformDisplay = load_egl_symbol(dl_handle, "eglGetPlatformDisplay");
    handle.eglInitialize = load_egl_symbol(dl_handle, "eglInitialize");
    handle.eglSwapBuffers = load_egl_symbol(dl_handle, "eglSwapBuffers");
    if (useSFPEW && sfpew_handle) {
        // SFPEW 的 swap 先 flush 再交给后端，绕过它会导致 FPE 的立即模式
        // 绘制与后端的提交顺序错乱。
        void *sfpewSwap = load_egl_symbol(sfpew_handle, "eglSwapBuffers");
        if (sfpewSwap) handle.eglSwapBuffers = sfpewSwap;
    }
    handle.eglReleaseThread = load_egl_symbol(dl_handle, "eglReleaseThread");
    handle.eglSwapInterval = load_egl_symbol(dl_handle, "eglSwapInterval");
    handle.eglTerminate = load_egl_symbol(dl_handle, "eglTerminate");
    handle.eglGetCurrentSurface = load_egl_symbol(dl_handle, "eglGetCurrentSurface");

    return handle.eglBindAPI && handle.eglChooseConfig && handle.eglCreateContext &&
        handle.eglCreateWindowSurface && handle.eglDestroyContext && handle.eglDestroySurface &&
        handle.eglGetConfigAttrib && handle.eglGetDisplay && handle.eglGetError &&
        handle.eglInitialize && handle.eglMakeCurrent && handle.eglSwapBuffers &&
        handle.eglReleaseThread && handle.eglSwapInterval && handle.eglTerminate;
}

// 只应在 gl_init_context（eglChooseConfig 之后、eglBindAPI/eglCreateContext 之前）
// 调用一次。返回 YES 表示生命周期 EGL 已切换到 MobileGlues 前端。
static BOOL ame_mgBootstrap(EGLDisplay dpy, EGLConfig config) {
    if (ame_mgBootstrapTried) return ame_mgFrontendActive;
    ame_mgBootstrapTried = YES;

    if (ame_mg_handle == NULL || ame_mg_init_gles == NULL) {
        NSLog(@"[MG-Bridge] bootstrap skipped: frontend image or mg_init_gles unavailable "
              @"-- EGL stays on raw ANGLE (legacy behavior)");
        return NO;
    }
    if (ame_raw_create_pbuffer == NULL || ame_raw_create_context == NULL ||
        ame_raw_make_current == NULL || ame_raw_destroy_context == NULL ||
        ame_raw_destroy_surface == NULL) {
        NSLog(@"[MG-Bridge] bootstrap skipped: raw ANGLE pointers incomplete -- EGL stays on raw ANGLE");
        return NO;
    }

    // 1) 临时 pbuffer + ES3 上下文（raw ANGLE）：唯一目的是让 mg_init_gles() 的
    //    caps 查询（glGetString 等）发生在"有当前上下文"的正确环境里。
    const EGLint pbAttribs[] = { EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE };
    EGLSurface pb = ame_raw_create_pbuffer(dpy, config, pbAttribs);
    const EGLint tmpCtxAttribs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    EGLContext tmpCtx = (pb != EGL_NO_SURFACE)
        ? ame_raw_create_context(dpy, config, EGL_NO_CONTEXT, tmpCtxAttribs)
        : EGL_NO_CONTEXT;

    BOOL ok = NO;
    if (pb != EGL_NO_SURFACE && tmpCtx != EGL_NO_CONTEXT &&
        ame_raw_make_current(dpy, pb, pb, tmpCtx)) {
        // 2) 绑定 gles/egl 后端句柄 + 真实 caps 检测（MobileGlues 内部幂等）
        ame_mg_init_gles();
        ok = YES;
        NSLog(@"[MG-Bridge] bootstrap: mg_init_gles complete under throwaway ES context "
              @"(GLES/ANGLE handles bound, caps detected)");
    } else {
        NSLog(@"[MG-Bridge] bootstrap FAILED (pbuffer=%p ctx=%p, eglError=0x%x) "
              @"-- EGL stays on raw ANGLE (legacy behavior)",
              (void *)pb, (void *)tmpCtx,
              (unsigned int)(uintptr_t)handle.eglGetError());
    }

    // 3) 无论成败都释放临时资源（MobileGlues 从未见过它们，无残留状态）
    if (pb != EGL_NO_SURFACE || tmpCtx != EGL_NO_CONTEXT) {
        ame_raw_make_current(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (tmpCtx != EGL_NO_CONTEXT) ame_raw_destroy_context(dpy, tmpCtx);
        if (pb != EGL_NO_SURFACE) ame_raw_destroy_surface(dpy, pb);
    }
    if (!ok) return NO;

    // 4) 把生命周期 EGL 切换到 MobileGlues 前端（此后 eglCreateContext 会建立
    //    MGContext 记录、eglMakeCurrent 会绑定 g_current_ctx 与每上下文子系统，
    //    eglSwapBuffers 走 presentSurface）。任一符号缺失则单独回退 raw。
    void *fn = NULL;
    #define AME_MG_SWAP(field, name)                                                  \
        do {                                                                          \
            fn = dlsym(ame_mg_handle, name);                                          \
            if (fn != NULL) { handle.field = fn; }                                    \
            else NSLog(@"[MG-Bridge] frontend " name " missing -- raw ANGLE retained"); \
        } while (0)
    AME_MG_SWAP(eglBindAPI,        "eglBindAPI");
    AME_MG_SWAP(eglCreateContext,  "eglCreateContext");
    AME_MG_SWAP(eglDestroyContext, "eglDestroyContext");
    AME_MG_SWAP(eglMakeCurrent,    "eglMakeCurrent");
    AME_MG_SWAP(eglSwapBuffers,    "eglSwapBuffers");
    AME_MG_SWAP(eglSwapInterval,   "eglSwapInterval");
    #undef AME_MG_SWAP

    ame_mgFrontendActive = YES;
    NSLog(@"[MG-Bridge] EGL lifecycle routed through MobileGlues frontend "
          @"(MGContext tracking + presentSurface active)");
    return YES;
}

static bool gl_init() {
    if (!dlsym_EGL()) {
        return false;
    }

    g_EglDisplay = handle.eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (g_EglDisplay == EGL_NO_DISPLAY) {
        NSDebugLog(@"EGLBridge: eglGetDisplay(EGL_DEFAULT_DISPLAY) returned EGL_NO_DISPLAY");
        return false;
    }
    if (!handle.eglInitialize(g_EglDisplay, NULL, NULL)) {
        NSDebugLog(@"EGLBridge: Error eglInitialize() failed: 0x%x", handle.eglGetError());
        return false;
    }
    return true;
}

gl_render_window_t* gl_init_context(gl_render_window_t *share) {
    gl_render_window_t* bundle = calloc(1, sizeof(gl_render_window_t));

    NSString *renderer = NSProcessInfo.processInfo.environment[@"AMETHYST_RENDERER"];
    // ANGLE / Mithril / MobileGL 导出的都是 desktop OpenGL，走 EGL_OPENGL_BIT +
    // eglBindAPI(EGL_OPENGL_API)；其余（gl4es / MobileGlues / LTW）是 OpenGL ES。
    BOOL desktopGL = isDesktopGLRenderer(renderer.UTF8String);
    BOOL mobileGL = isMobileGLRenderer(renderer.UTF8String);

    const EGLint attribs[] = {
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 24,
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT|EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, desktopGL ? EGL_OPENGL_BIT : EGL_OPENGL_ES3_BIT,
        EGL_NONE
    };

    EGLint num_configs;
    EGLint vid;
    if (!handle.eglChooseConfig(g_EglDisplay, attribs, &bundle->config, 1, &num_configs)) {
        NSDebugLog(@"EGLBridge: Error couldn't get an EGL visual config: 0x%x", handle.eglGetError());
        free(bundle);
        return NULL;
    }
    assert(bundle->config);
    assert(num_configs > 0);

    if (!handle.eglGetConfigAttrib(g_EglDisplay, bundle->config, EGL_NATIVE_VISUAL_ID, &vid)) {
        NSDebugLog(@"EGLBridge: Error eglGetConfigAttrib() failed: 0x%x", handle.eglGetError());
        free(bundle);
        return NULL;
    }

    // Task 36：在首个前端 EGL 调用（eglBindAPI）之前完成 MobileGlues 引导 ——
    // 绑定后端句柄 + caps 检测 + 把生命周期指针切到前端。
    // 必须位于此处：config 已可用（引导需要），eglBindAPI/eglCreateContext
    // 尚未发生（前端函数内部 LOAD_EGL 静态指针需要后端已绑定）。
    ame_mgBootstrap(g_EglDisplay, bundle->config);

    EGLBoolean bindResult;
    if (desktopGL) {
        NSDebugLog(@"EGLBridge: Binding to desktop OpenGL");
        bindResult = handle.eglBindAPI(EGL_OPENGL_API);
    } else {
        NSDebugLog(@"EGLBridge: Binding to OpenGL ES");
        bindResult = handle.eglBindAPI(EGL_OPENGL_ES_API);
    }
    if (!bindResult) NSDebugLog(@"EGLBridge: bind failed: %p\n", handle.eglGetError());

    CALayer *layer = SurfaceViewController.surface.layer;
    // ============================================================================
    // Task 50（黑屏根因修复）→ Task 60（画面模糊根因修复）：呈现几何单一
    // 事实源 —— 原生 scale 像素对齐。
    //
    // 历史（622166a 黑屏时代，本块取代 Task48 创建钉扎 + Task49 重试环）：
    //   1. 全日志 0 条 "Task48 pin"（卫兵逐帧钉扎从未生效）——渲染线程读
    //      layer 属性与主线程心跳读到不同值（CALayer 跨线程状态分叉），
    //      跨线程写 drawableSize 打不进主线程的 CA 提交树；
    //   2. Task49 重试环 5 连败：pin 写 1180x820 后 ANGLE 仍建出 2360x1640
    //      —— ANGLE 读的是 bounds×contentsScale（=1180x820×2.0），不是
    //      drawableSize；
    //   3. 卫兵重建表面恒 EGL_BAD_ALLOC 0x3003（同 layer 二次建 window
    //      surface 必败），重建失败 → surface 被锁死在转置态 1640x2360，
    //      而 drawable/viewport 是横屏 2360x1640 —— 600+ 帧 present 尺寸
    //      失配 = 用户看到的全黑。
    //
    // 当年黑屏的结构性根源：三套尺寸（1x 点 viewport / 2x drawable /
    // ANGLE surface）互相打架。Task50 以 1x 点数对齐终结拉锯——但代价
    // 是渲染分辨率减半：
    //   - MC 26.3：surface 1180x820 → MC viewport 跟随 → 半分辨率渲染，
    //     CA 线性放大 2x = 全屏模糊（5f1df50 真机实测"画面模糊"；
    //     "MC 像素风格最近邻无损"的假设不成立——CAMetalLayer 默认线性
    //     过滤，且 MC 26.3 有平滑光照/字体/渐变）；
    //   - MC 26.2 LWJGL：MC 信念 2360x1640 ≠ surface 1180x820 → Task49
    //     geo-heal 每帧降采样 blit（双重模糊 + 带宽开销）= 真机实测
    //     "MG 对 LWJGL 兼容性倒退"（MG 2.0.16 SYMBOL THEFT 警告为无害
    //     环境诊断——其符号解析不依赖 flat 顺序）。
    //
    // Task 60 修复（口径已由 Task58 EGL 常量修正 + Task59 输入像素直通
    // 定案）：对齐到原生 scale 像素——contentsScale = 权威 screen scale
    //（layer 所属 view 的 window screen，兜底主屏），drawableSize =
    // bounds × scale（= 2360x1640）。全链像素口径：surface==drawable==
    // 物理屏像素 1:1 零缩放；launchJVM 告知 MC 的 2360x1640 与 MC 窗口
    // 信念一致；输入链（Task59 直通）零影响；26.2 LWJGL viewport 2360x1640
    // == surface → geo-heal blit 自然退出。旋转时 bounds 跟随 → 同步翻转
    //（ANGLE 具备跟随 layer 几何能力，622166a 转置事件即实证）。
    //   Vulkan 路径不受影响：gl_init_context 只在 GL 路径执行。
    // ============================================================================
    // Task60 对齐写 layer 必须发生在主线程：旧代码的致命伤之一就是从渲染线程
    // 写 drawableSize（CALayer 跨线程状态分叉：渲染线程读到一套、主线程的
    // CA 提交树另一套——622166a 心跳 drawable=2360x1640 与卫兵读取 1640x2360
    // 的矛盾即其表现）。单一写入者纪律：本块与 updateSavedResolution（主线程，
    // 旋转时）是 layer 尺寸仅有的两个写入者，且都在主线程。
    if ([layer isKindOfClass:CAMetalLayer.class]) {
        __block CGSize oldDrawable50 = CGSizeZero;
        __block CGFloat oldScale50 = 0.0;
        void (^align60)(void) = ^{
            CAMetalLayer *ml60 = (CAMetalLayer *)layer;
            CGFloat w60 = MAX(1.0, round(layer.bounds.size.width));
            CGFloat h60 = MAX(1.0, round(layer.bounds.size.height));
            // Task 60：权威 scale —— layer 所属 view 的 window screen
            //（外接屏正确），兜底主屏，再兜底 1.0。与 Task59 输入链的
            // screenScale 同源；resolutionScale 语义由宿主
            // updateSavedResolution 负责（此处创建时以原生 scale 钉齐）。
            CGFloat scale60 = 0.0;
            UIView *v60 = (UIView *)layer.delegate;  // CALayer.delegate == owning UIView
            if (v60 != nil && v60.window != nil && v60.window.screen != nil) {
                scale60 = v60.window.screen.scale;
            }
            if (scale60 <= 0.0) scale60 = UIScreen.mainScreen.scale;
            if (scale60 <= 0.0) scale60 = 1.0;
            // Task 78：创建时同步应用 resolutionScale（video.resolution）。
            // 旧行为在 resolutionScale<100% 时把 drawableSize 钉到全物理
            // 分辨率，随后 updateSavedResolution 写缩小值 → 创建后拉锯（
            // Task57 冻结补丁下 surface 锁死在创建尺寸，guard 每次把
            // drawableSize 拉回 surface 全尺寸，用户看到的是"半分辨率
            // 选项 + 每帧 geo-heal blit"）。创建与旋转两个写者现在同口径
            // （bounds × screenScale × resolutionScale），单一事实源成立；
            // resolutionScale=100% 时数值与旧行为完全一致（零回归）。
            // Task 78 FSR 联动：MC 的告知窗口（=viewport=渲染尺寸）由
            // updateSavedResolution 单独缩至 surface/fsr_scale，本块只负责
            // surface/drawable 口径，不受 fsr_scale 影响。
            CGFloat rs60 = resolutionScale;
            if (rs60 <= 0.0) rs60 = 1.0;  // 防御：全局未初始化（JavaGUI 等路径）
            oldDrawable50 = ml60.drawableSize;
            oldScale50 = layer.contentsScale;
            layer.contentsScale = scale60 * rs60;
            ml60.drawableSize = CGSizeMake(round(w60 * scale60 * rs60), round(h60 * scale60 * rs60));
        };
        if ([NSThread isMainThread]) {
            align60();
        } else {
            // gl_init_context 运行于 JVM 渲染线程；此刻主线程处于空闲 runloop
            // （launchJVM 在后台线程，主线程无任何等待渲染线程的锁——同窗口期
            // ame_embedSDLViewIntoHost 的 dispatch_sync 已在设备上验证安全）。
            dispatch_sync(dispatch_get_main_queue(), align60);
        }
        NSLog(@"[GLGeo] Task60 native-scale alignment (main thread): bounds=%.0fx%.0f drawableSize %.0fx%.0f scale %.2f -> drawableSize %.0fx%.0f scale %.2f (surface==drawable==physical px; Task50 1x retired -- CA linear 2x upscale was the blur)",
              layer.bounds.size.width, layer.bounds.size.height,
              oldDrawable50.width, oldDrawable50.height, oldScale50,
              layer.bounds.size.width * layer.contentsScale,
              layer.bounds.size.height * layer.contentsScale,
              (double)layer.contentsScale);
    }
    // MobileGL 的 eglCreateWindowSurface 不会从 CALayer 推断尺寸，必须显式给出
    // 宽高（读取已对齐原生 scale 的 layer，与 drawableSize 保持一致），否则 surface
    // 会按 1x1 创建，进世界后画面异常。其余渲染器从 layer 自行推断，传 NULL。
    const EGLint mobileGLSurfaceAttribs[] = {
        EGL_WIDTH, (EGLint)MAX(1.0, round(layer.bounds.size.width * layer.contentsScale)),
        EGL_HEIGHT, (EGLint)MAX(1.0, round(layer.bounds.size.height * layer.contentsScale)),
        EGL_NONE
    };
    // 单次创建（无重试环）：原生 scale 对齐后 ANGLE 无论读 bounds×scale 还是
    // drawableSize 都得到与 MC viewport 相同的尺寸，无需执法。
    bundle->surface = handle.eglCreateWindowSurface(g_EglDisplay, bundle->config,
        (__bridge EGLNativeWindowType)layer, mobileGL ? mobileGLSurfaceAttribs : NULL);
    if (!bundle->surface) {
        NSDebugLog(@"EGLBridge: eglCreateWindowSurface finished with error: 0x%x", handle.eglGetError());
        free(bundle);
        return NULL;
    }
    // 黑屏取证（Task 32）：surface 创建成功时，把呈现目标的完整状态记入日志——
    // layer 指针/bounds/contentsScale/drawableSize/是否已在窗口层级。
    // 若后续黑屏，对照此处即可判断 layer 尺寸/层级在上下文创建时是否就已经不对。
    {
        BOOL isMetal = [layer isKindOfClass:CAMetalLayer.class];
        CGSize drawable = isMetal ? ((CAMetalLayer *)layer).drawableSize : CGSizeZero;
        UIView *layerView = layer.delegate;  // CALayer.delegate == owning UIView
        BOOL inWindow = (layerView != nil && [(UIView *)layerView window] != nil);
        NSLog(@"[RenderDiag] EGL window surface created: surface=%p layer=%p bounds=%.0fx%.0f contentsScale=%.2f drawableSize=%.0fx%.0f ownerInWindow=%d",
              (void *)bundle->surface, (__bridge void *)layer,
              layer.bounds.size.width, layer.bounds.size.height,
              (double)layer.contentsScale, drawable.width, drawable.height, (int)inWindow);
        // Task 36 取证：surface 在 EGL 侧的真实尺寸（MC RenderPearl 的表面配置
        // 报 1180x820，若此处 eglQuerySurface 报 2360x1640 则存在 2x 不匹配，
        // 下一轮设备日志可据此判断合成/缩放行为）。
        if (ame_raw_query_surface != NULL && bundle->surface != EGL_NO_SURFACE) {
            EGLint sw = 0, sh = 0;
            if (ame_raw_query_surface(g_EglDisplay, bundle->surface, EGL_WIDTH, &sw) &&
                ame_raw_query_surface(g_EglDisplay, bundle->surface, EGL_HEIGHT, &sh)) {
                NSLog(@"[RenderDiag] eglQuerySurface: %dx%d", sw, sh);
            }
        }
        // Task 48：记录呈现 layer（CFBridgingRetain）与期望表面尺寸，
        // 供 ame48_swap_geometry_guard 逐帧自愈使用。
        ame48_record_creation(layer, g_EglDisplay, bundle->surface);
        // Task 50：GL 拥有呈现层（跨线程标志）——此后主线程
        // updateSavedResolution 走原生 scale 对齐分支（bounds x scale 跟随旋转）。
        atomic_store(&g_ame50_gl_owns_layer, 1);
    }

    const EGLint gles_ctx_attribs[] = {
        EGL_CONTEXT_CLIENT_VERSION, 3,
        EGL_NONE
    };
    // MobileGL 走真正的 desktop GL：要求 3.3 Core Profile。
    // Mithril 同样导出 desktop GL 3.3 Core，但其 EGLConfig 已同时声明
    // EGL_OPENGL_BIT | EGL_OPENGL_ES3_BIT，沿用 ES 版的 CLIENT_VERSION=3 即可
    // （与 Uniaball 官方 launcher-patch 中验证过的配置保持一致）。
    const EGLint desktop_ctx_attribs[] = {
        EGL_CONTEXT_MAJOR_VERSION, 3,
        EGL_CONTEXT_MINOR_VERSION, 3,
        EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        EGL_NONE
    };
    bundle->context = handle.eglCreateContext(g_EglDisplay, bundle->config, share ? share->context : EGL_NO_CONTEXT,
        mobileGL ? desktop_ctx_attribs : gles_ctx_attribs);
    if (!bundle->context) {
        NSDebugLog(@"EGLBridge: Error eglCreateContext finished with error: 0x%x", handle.eglGetError());
        free(bundle);
        return NULL;
    }
    //NSDebugLog(@"EGLBridge: Created CTX pointer = %p (source = %p)", bundle->context, share?share->context:0);

    return bundle;
}

void gl_make_current(gl_render_window_t* bundle) {
    if(!bundle) {
        if(handle.eglMakeCurrent(g_EglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT)) {
            currentBundle = NULL;
        }
        return;
    }

    if(handle.eglMakeCurrent(g_EglDisplay, bundle->surface, bundle->surface, bundle->context)) {
        currentBundle = (basic_render_window_t *)bundle;
        if (ame_mgFrontendActive) {
            NSLog(@"[MG-Bridge] eglMakeCurrent via frontend OK (ctx=%p) -- "
                  @"MGContext tracked, per-context state bound",
                  (void *)bundle->context);
        }

        // MobileGlues 2.0: on Apple, init GL ES function pointers now that
        // we have a current context.  mg_init_gles() uses RTLD_DEFAULT to
        // resolve ANGLE's GLES symbols and queries GL version/extensions.
        // Only runs once; subsequent calls are a no-op.
        // (Task 36 引导成功后这里是无害的 no-op；引导失败时仍是原始兜底路径。)
        static BOOL mgInitialized = NO;
        if (!mgInitialized) {
            mgInitialized = YES;
            typedef void (*mg_init_gles_t)(void);
            mg_init_gles_t fn = (mg_init_gles_t)dlsym(RTLD_DEFAULT, "mg_init_gles");
            if (fn) {
                fn();
                NSLog(@"[gl_bridge] mg_init_gles() called after eglMakeCurrent");
            } else {
                NSLog(@"[gl_bridge] mg_init_gles not found (old MobileGlues?)");
            }
        }

        // 帧率解锁关键点：在 EGL context 首次变为 current 后立即设置 swap interval=0。
        //
        // 为什么必须在这里设置（而不是等 MC 调用 glfwSwapInterval 时才设置）：
        //
        // 对于 zink 渲染器（Mesa 21.0），Vulkan swapchain 是延迟创建的——
        // 在第一次 eglSwapBuffers 或需要 swapchain 时才创建。
        // zink 创建 swapchain 时会根据当前 eglSwapInterval 的值选择 present mode：
        //   - interval=0 → VK_PRESENT_MODE_IMMEDIATE_KHR（不等 vsync，帧率可超 60）
        //   - interval=1 → VK_PRESENT_MODE_FIFO_KHR（等 vsync，锁在屏幕刷新率）
        //
        // 如果等 MC 调用 glfwSwapInterval(1) → pojavSwapInterval(0) → eglSwapInterval(0)
        // 时才设置，swapchain 可能已经用默认的 FIFO 创建了。
        // Mesa 21.0 的 zink 不会在 eglSwapInterval 变化时重建 swapchain，
        // 导致 present mode 固定为 FIFO，帧率被锁死在屏幕刷新率（60Hz/120Hz）。
        //
        // 在 gl_make_current 中提前设置 eglSwapInterval(0)，可确保 zink 创建
        // swapchain 时读到 interval=0，从而选择 IMMEDIATE present mode。
        //
        // 这对 ANGLE Metal 后端也有效（ANGLE 在 interval=0 时不等 vsync）。
        if (getenv("POJAV_DISABLE_VSYNC") && strcmp(getenv("POJAV_DISABLE_VSYNC"), "1") == 0) {
            static BOOL s_loggedInitialSwapInterval = NO;
            EGLBoolean feOk = handle.eglSwapInterval(g_EglDisplay, 0);
            // Task 76：双保险 —— MobileGlues 前端 + raw ANGLE 各设一次。
            // 前端的 LOAD_EGL 理论上透传后端，但 MG 场 fps 锁 60（max.fps=260
            // 解锁下 33 条心跳零超 60）提示 interval=0 未被 ANGLE Metal 采纳。
            // raw 直调绕过前端转译；两路返回值一并入日志，下轮设备日志据此
            // 分诊（前端吞掉 vs ANGLE Metal 不支持 interval=0）。
            EGLBoolean rawOk = EGL_FALSE;
            if (ame_raw_swap_interval != NULL) {
                rawOk = ame_raw_swap_interval(g_EglDisplay, 0);
            }
            if (!s_loggedInitialSwapInterval) {
                s_loggedInitialSwapInterval = YES;
                NSLog(@"[gl_bridge] eglSwapInterval(0) after eglMakeCurrent (POJAV_DISABLE_VSYNC=1, renderer=%s) frontend=%d raw=%d(rawPtr=%p)",
                      getenv("AMETHYST_RENDERER") ?: "<unset>", (int)feOk, (int)rawOk,
                      (void *)(uintptr_t)ame_raw_swap_interval);
            }
        }
    } else {
        NSLog(@"EGLBridge: eglMakeCurrent returned with error: 0x%x", handle.eglGetError());
    }
}

void gl_swap_buffers() {
    // currentBundle 只在 eglMakeCurrent 成功后赋值。若 MC 在 MakeCurrent 之前
    // （或 MakeCurrent(NULL) 释放之后）调用 swap，这里解引用空指针会直接段错误。
    // SDL3 路径下 SDL_GL_SwapWindow 由我们接管，调用时机不再由 GLFW 约束，
    // 所以必须显式防护。
    if (currentBundle == NULL) {
        NSLog(@"EGLBridge: gl_swap_buffers called with no current context, ignored");
        return;
    }
    // Task 77：build 相位起点——上一次 present 返回至今的全部 MC 帧构造
    // （tick/事件泵/GL 编码）时长在此刻定格。先于卫兵/取证记录，卫兵与
    // 探针的耗时归入 neither（Task76 后探针帧极稀，可忽略）。
    uint64_t ame77_t_entry = ame77_now_us();
    ame77_record_build(ame77_t_entry);
    // Task 48 呈现几何卫兵：先于一切交换动作执行（可能在内部重建表面，
    // 重建后 currentBundle->gl.surface 已更新，后续探针/交换都作用于新表面）。
    ame48_swap_geometry_guard(currentBundle);
    // 黑屏取证（Task 32）：记录每次 swap 的真实结果。
    // 成功：首次打一条日志（证明呈现路径至少活过一次）；之后交给原子计数器，
    // 由 SurfaceViewController 的 [RenderDiag] 5 秒心跳汇总上报。
    // 失败：任意错误码都打（去掉旧版 EGL_BAD_SURFACE 过滤），前 10 次逐条打，
    // 之后每 100 次打一条，避免日志爆炸。
    ame_task41_swap_forensics(currentBundle->gl.surface,
                              atomic_load(&g_eglSwapOK) + atomic_load(&g_eglSwapFail) + 1);
    // Task 77：present 相位计时——只包 eglSwapBuffers 本体。
    uint64_t ame77_t_present0 = ame77_now_us();
    EGLBoolean swapResult = handle.eglSwapBuffers(g_EglDisplay, currentBundle->gl.surface);
    uint64_t ame77_t_present1 = ame77_now_us();
    ame77_record_present((uint32_t)(ame77_t_present1 - ame77_t_present0), ame77_t_present1);
    if (!swapResult) {
        unsigned long fails = atomic_fetch_add(&g_eglSwapFail, 1) + 1;
        unsigned int eglErr = (unsigned int)(uintptr_t)handle.eglGetError();
        if (fails <= 10 || fails % 100 == 0) {
            NSLog(@"[RenderDiag] eglSwapBuffers FAILED #%lu eglError=0x%x surface=%p (render loop alive, presentation broken)",
                  fails, eglErr, (void *)currentBundle->gl.surface);
        }
        return;
    }
    unsigned long oks = atomic_fetch_add(&g_eglSwapOK, 1) + 1;
    if (oks == 1) {
        NSLog(@"[RenderDiag] first eglSwapBuffers OK surface=%p (presentation path confirmed)",
              (void *)currentBundle->gl.surface);
    }
    // Task 76：帧间隔尖峰跟踪（见文件头计数器块注释）。
    ame76_record_swap(ame53_now_ms());
}

void gl_swap_interval(int swapInterval) {
    handle.eglSwapInterval(g_EglDisplay, swapInterval);
}

void gl_terminate() {
    // Task 50：GL 不再拥有呈现层（下次 updateSavedResolution 回到 2x 默认）。
    atomic_store(&g_ame50_gl_owns_layer, 0);
    handle.eglMakeCurrent(g_EglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    handle.eglDestroySurface(g_EglDisplay, currentBundle->gl.surface);
    handle.eglDestroyContext(g_EglDisplay, currentBundle->gl.context);
    handle.eglTerminate(g_EglDisplay);
    handle.eglReleaseThread();
    free(currentBundle);
    currentBundle = nil;
}

void set_gl_bridge_tbl() {
    br_init = gl_init;
    br_init_context = (br_init_context_t) gl_init_context;
    br_make_current = (br_make_current_t) gl_make_current;
    br_swap_buffers = gl_swap_buffers;
    br_swap_interval = gl_swap_interval;
    br_terminate = gl_terminate;
}
