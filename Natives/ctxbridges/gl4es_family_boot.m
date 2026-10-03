//
//  gl4es_family_boot.m
//  AngelAuraAmethyst
//
//  ★ [RENDERER-GAP] 新增渲染器运行时引导实现。
//  来源：Gsjsjzhznsz/Air-Minecraft-iOS-Launcher（同一项目家族更晚的 fork）：
//    - egl_bridge.m 的 ame204_gl4esProcResolver（Task204 后端符号解析钉扎）
//    - ame211_gl4eszl2_boot（Task211 ZL2 经典版 gl4es，同构镜像）
//    - ctxbridges/virgl_server.m 的 ame_virgl_start_server（Task215 VirGL）
//  这些逻辑对既有渲染器完全无副作用：
//    - 每个入口第一件事就是比对手里的 AMETHYST_RENDERER，不匹配立即返回；
//    - 各自带幂等门，重复调用零成本。
//
//  ⚠ 未在本机编译验证（无 Xcode / iOS 工具链，见报告 ⑦）。所有符号仅为
//    dlopen/dlsym 动态解析，不静态链接任何渲染器 dylib，故宿主编译不因
//    缺少这些 dylib 而失败。
//
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>

#include "utils.h"
#include "ctxbridges/gl4es_family_boot.h"
#include "ctxbridges/virgl_server.h"

// ---------------------------------------------------------------------------
// Task204 后端符号解析器：ANGLE 框架里解析 egl*/gl* 符号，钉给 gl4es 家族的
// proc_address。队友仓库在 egl_bridge.m 内以 ame204_* 命名；此处收敛为静态。
// ---------------------------------------------------------------------------
static void *ame_gap_gl4esGles2 = NULL;   // bundled libGLESv2.framework 句柄
static void *ame_gap_gl4esEgl   = NULL;   // bundled libEGL.framework 句柄
static void *(*ame_gap_gl4esEgpa)(const char *) = NULL;  // bundled eglGetProcAddress

static void *ame_gap_gl4esProcResolver(const char *name) {
    if (name == NULL) return NULL;
    if (strncmp(name, "gl", 2) == 0) {
        if (ame_gap_gl4esEgpa != NULL) {
            void *p = ame_gap_gl4esEgpa(name);
            if (p != NULL) return p;
        }
        if (ame_gap_gl4esGles2 != NULL) {
            void *p = dlsym(ame_gap_gl4esGles2, name);
            if (p != NULL) return p;
        }
    }
    if (strncmp(name, "egl", 3) == 0 && ame_gap_gl4esEgl != NULL) {
        void *p = dlsym(ame_gap_gl4esEgl, name);
        if (p != NULL) return p;
    }
    return NULL;
}

static void ame_gap_load_bundled_angle_egl(void) {
    if (ame_gap_gl4esEgpa != NULL) return;
    ame_gap_gl4esGles2 = dlopen("@executable_path/Frameworks/libGLESv2.framework/libGLESv2",
                                RTLD_NOW | RTLD_LOCAL);
    ame_gap_gl4esEgl = dlopen("@executable_path/Frameworks/libEGL.framework/libEGL",
                              RTLD_NOW | RTLD_LOCAL);
    ame_gap_gl4esEgpa = ame_gap_gl4esEgl
        ? (void *(*)(const char *))dlsym(ame_gap_gl4esEgl, "eglGetProcAddress")
        : NULL;
}

// GL4ESZL2 的 MakeCurrent 后初始化（队友 ame211 的收敛）。
// 该 vendored 树构建带 NO_INIT_CONSTRUCTOR + 显式 initialize_gl4es。
// ★ [DROP-NGG4ES] 原与之共用的 NG-GL4ES（ame208）已随该支移除。
static void ame_gap_gl4es_family_init(const char *dylib) {
    void *h = dlopen(dylib, RTLD_NOW | RTLD_NOLOAD | RTLD_GLOBAL);
    if (h == NULL) {
        NSLog(@"[RENDERER-GAP] %s image not loaded (RTLD_NOLOAD) -- initialize_gl4es NOT called", dylib);
        return;
    }
    ame_gap_load_bundled_angle_egl();
    int resolver = 0;
    if (ame_gap_gl4esEgpa != NULL) {
        void (*sgpa)(void *(*)(const char *)) =
            (void (*)(void *(*)(const char *)))dlsym(h, "set_getprocaddress");
        if (sgpa != NULL) {
            sgpa(ame_gap_gl4esProcResolver);
            resolver = 1;
        }
    }
    // 门：确认线程上确有 current 上下文（经捆绑 ANGLE EGL 查询）。
    if (ame_gap_gl4esEgl != NULL) {
        void *(*getCurCtx)(void) = (void *(*)(void))dlsym(ame_gap_gl4esEgl, "eglGetCurrentContext");
        if (getCurCtx != NULL && getCurCtx() == NULL) {
            NSLog(@"[RENDERER-GAP] %s boot deferred -- no current EGL context on this thread", dylib);
            return;
        }
    }
    void (*init)(void) = (void (*)(void))dlsym(h, "initialize_gl4es");
    if (init == NULL) {
        NSLog(@"[RENDERER-GAP] %s: initialize_gl4es symbol missing -- cannot init", dylib);
        return;
    }
    init();
    NSLog(@"[RENDERER-GAP] %s initialize_gl4es() called post-MakeCurrent (resolver=%@, handle=%p)",
          dylib, resolver ? @"YES" : @"NO(egpa-missing)", h);
}

bool ame_gap_renderer_selected(void) {
    const char *r = getenv("AMETHYST_RENDERER");
    return isRendererGapExtra(r);
}

void ame_gap_gl4es_family_boot(void) {
    static volatile int s_done = 0;
    if (s_done) return;
    const char *r = getenv("AMETHYST_RENDERER");
    if (r == NULL) return;

    if (strcmp(r, RENDERER_NAME_GL4ESZL2) == 0) {
        ame_gap_gl4es_family_init(RENDERER_NAME_GL4ESZL2);
        s_done = 1;
    } else if (strcmp(r, RENDERER_NAME_VGPU) == 0) {
        // ★ [DROP-NGG4ES] 原 NG-GL4ES 分支（ame208_nggl4es_boot）已随该支移除。
        // VGPU 自带惰性装载器（pack/load_all）与构造器，无需宿主显式 initialize。
        NSLog(@"[RENDERER-GAP] VGPU selected: lazy loader handles GL init (no host initialize_gl4es)");
        s_done = 1;
    }
    // 其余渲染器：不置 s_done，保持零成本重入（一次 getenv 比较）。
}

int ame_gap_virgl_boot(void) {
    const char *r = getenv("AMETHYST_RENDERER");
    if (r == NULL || strcmp(r, RENDERER_NAME_VIRGL) != 0) return 0;
    int rc = ame_virgl_start_server();
    if (rc != 0) {
        NSLog(@"[RENDERER-GAP] VirGL vtest server bootstrap failed rc=%d -- osm bridge continues; "
              @"error will surface at guest connect", rc);
    }
    return rc;
}
