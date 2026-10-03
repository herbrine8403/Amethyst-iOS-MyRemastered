//
//  virgl_server.m
//  Amethyst-iOS-MyRemastered
//
//  Task 111：VirGLRenderer(≤26.2)（ZalithLauncher2 移植）—— 服务端引导桥。
//
//  架构（对齐 ZL2 virgl_bridge.c 的进程内模型，宿主 GL 换成我们的 ANGLE/Metal）：
//
//    MC(LWJGL) --gl*--> libOSMesaVirgl.dylib(Mesa 25.0.7 virgl 驱动, GALLIUM_DRIVER=virgl)
//        --vtest 协议(unix socket, VTEST_SOCKET_NAME)--> libvtestserver.dylib
//        (virglrenderer 1.3.0 + libepoxy) --epoxy(EGL/GLES)--> ANGLE 框架 --> Metal
//
//    呈现：复用 osm_bridge 的 zink 链路（OSMesaMakeCurrent + swap 时
//    glReadPixels 权威回读 + CGImage 上屏）。guest 的 glReadPixels 经
//    vtest transfer 从服务端取回像素，天然正确。
//
//  本文件只做三件事：
//    1. 确定 socket 路径并设置 VTEST_SOCKET_NAME / GALLIUM_DRIVER=virgl
//    2. 用随 app 打包的 ANGLE 框架创建一个离屏(1x1 pbuffer) ES3 宿主上下文
//    3. 起一个线程：MakeCurrent 后调 libvtestserver.dylib 的 vtest_main(
//       "--no-loop-or-fork" "--use-gles" "--socket-path" <path>)
//       （vrend 内部经 epoxy 在同一 EGL display 上按需创建自己的 GLES 上下文）
//
//  注意：vtest_server 内部错误路径会 exit(1)（上游行为，ZL2 同款），
//  socket 采用 unlink+bind，二次启动安全；--no-loop-or-fork 单客户端
//  单发服务，guest 断开即返回。
//

#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <dlfcn.h>

#include "virgl_server.h"

// ---------------------------------------------------------------------------
// raw ANGLE EGL 函数指针（从随 app 打包的 libEGL.framework 解析；
// 与 gl_bridge.m 的 raw ANGLE 同款做法，保持本文件自包含）
// ---------------------------------------------------------------------------
typedef unsigned int EGLBoolean;
typedef void *EGLDisplay;
typedef void *EGLConfig;
typedef void *EGLSurface;
typedef void *EGLContext;
typedef intptr_t EGLNativeDisplayType;
typedef intptr_t EGLint;

static EGLDisplay (*ame_vs_eglGetDisplay)(EGLNativeDisplayType);   // ★ [SHADER-GLSLANG] build-unblock: EGL 的 eglGetDisplay 返回 EGLDisplay(void*), 原 typedef 误写 EGLBoolean 导致 native 编译 -Wint-conversion 报错(挡全仓出包)
static EGLBoolean (*ame_vs_eglInitialize)(EGLDisplay, EGLint *, EGLint *);
static EGLBoolean (*ame_vs_eglBindAPI)(unsigned int);
static EGLBoolean (*ame_vs_eglChooseConfig)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *);
static EGLSurface (*ame_vs_eglCreatePbufferSurface)(EGLDisplay, EGLConfig, const EGLint *);
static EGLContext (*ame_vs_eglCreateContext)(EGLDisplay, EGLConfig, EGLContext, const EGLint *);
static EGLBoolean (*ame_vs_eglMakeCurrent)(EGLDisplay, EGLSurface, EGLSurface, EGLContext);

static EGLDisplay ame_vs_display;
static EGLSurface ame_vs_pbuffer;
static EGLContext ame_vs_context;
static char ame_vs_socket_path[512];
static int ame_vs_started = 0;

// vtest server 入口（libvtestserver.dylib 导出；上游 vtest_server.c:135）
static int (*ame_vs_vtest_main)(int argc, char **argv);

// EGL 常量（避免引入 EGL 头依赖）
#define AME_VS_EGL_DEFAULT_DISPLAY   ((EGLNativeDisplayType)0)
#define AME_VS_EGL_OPENGL_ES_API     0x30A0
#define AME_VS_EGL_SURFACE_TYPE      0x3033
#define AME_VS_EGL_PBUFFER_BIT       0x0001
#define AME_VS_EGL_RENDERABLE_TYPE   0x3040
#define AME_VS_EGL_OPENGL_ES2_BIT    0x0004
#define AME_VS_EGL_RED_SIZE          0x3024
#define AME_VS_EGL_GREEN_SIZE        0x3023
#define AME_VS_EGL_BLUE_SIZE         0x3022
#define AME_VS_EGL_ALPHA_SIZE        0x3021
#define AME_VS_EGL_WIDTH             0x3057
#define AME_VS_EGL_HEIGHT            0x3056
#define AME_VS_EGL_CONTEXT_CLIENT_VERSION 0x3098
#define AME_VS_EGL_NONE              0x3038

static void *ame_vs_server_thread(void *arg __unused)
{
    // ZL2 同款顺序：先 MakeCurrent（vrend 经 epoxy 感知当前上下文/display），
    // 再进 vtest 主循环。
    if (ame_vs_eglMakeCurrent(ame_vs_display, ame_vs_pbuffer, ame_vs_pbuffer, ame_vs_context) != 1) {
        NSLog(@"[VirGL] Task111 host eglMakeCurrent failed -- server thread aborting");
        return NULL;
    }

    void *handle = dlopen("@rpath/" AME_VIRGL_VTEST_SERVER_LIB, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        NSLog(@"[VirGL] Task111 dlopen %s failed: %s", AME_VIRGL_VTEST_SERVER_LIB, dlerror() ?: "unknown");
        return NULL;
    }
    ame_vs_vtest_main = (int (*)(int, char **))dlsym(handle, "vtest_main");
    if (!ame_vs_vtest_main) {
        NSLog(@"[VirGL] Task111 vtest_main not found in %s", AME_VIRGL_VTEST_SERVER_LIB);
        return NULL;
    }

    NSLog(@"[VirGL] Task111 starting vtest server (no-loop-or-fork, use-gles, socket=%s)", ame_vs_socket_path);
    // getopt_long 要求 argv[argc] == NULL；参数与 ZL2 完全一致（外加显式 socket 路径）
    char arg0[] = "vtest";
    char arg1[] = "--no-loop-or-fork";
    char arg2[] = "--use-gles";
    char arg3[] = "--socket-path";
    char *argv[] = { arg0, arg1, arg2, arg3, ame_vs_socket_path, NULL };
    int rc = ame_vs_vtest_main(5, argv);
    NSLog(@"[VirGL] Task111 vtest server finished with rc=%d (guest disconnected?)", rc);
    return NULL;
}

int ame_virgl_start_server(void)
{
    if (ame_vs_started) {
        return 0; // 幂等
    }

    // ---- 1. socket 路径 + guest 环境变量（必须在 osm_bridge dlopen guest 之前）----
    const char *pojavHome = getenv("POJAV_HOME");
    if (!pojavHome || !*pojavHome) {
        pojavHome = getenv("HOME");
    }
    snprintf(ame_vs_socket_path, sizeof(ame_vs_socket_path), "%s/.virgl_test",
             (pojavHome && *pojavHome) ? pojavHome : "/tmp");
    setenv("VTEST_SOCKET_NAME", ame_vs_socket_path, 1);
    setenv("GALLIUM_DRIVER", "virgl", 1);

    // ---- 2. raw ANGLE EGL：离屏宿主上下文 ----
    void *egl = dlopen("@rpath/libEGL.framework/libEGL", RTLD_NOW | RTLD_LOCAL);
    if (!egl) {
        NSLog(@"[VirGL] Task111 dlopen ANGLE libEGL failed: %s", dlerror() ?: "unknown");
        return -1;
    }
    ame_vs_eglGetDisplay = (void *)dlsym(egl, "eglGetDisplay");
    ame_vs_eglInitialize = (void *)dlsym(egl, "eglInitialize");
    ame_vs_eglBindAPI = (void *)dlsym(egl, "eglBindAPI");
    ame_vs_eglChooseConfig = (void *)dlsym(egl, "eglChooseConfig");
    ame_vs_eglCreatePbufferSurface = (void *)dlsym(egl, "eglCreatePbufferSurface");
    ame_vs_eglCreateContext = (void *)dlsym(egl, "eglCreateContext");
    ame_vs_eglMakeCurrent = (void *)dlsym(egl, "eglMakeCurrent");
    if (!ame_vs_eglGetDisplay || !ame_vs_eglInitialize || !ame_vs_eglChooseConfig ||
        !ame_vs_eglCreatePbufferSurface || !ame_vs_eglCreateContext || !ame_vs_eglMakeCurrent ||
        !ame_vs_eglBindAPI) {
        NSLog(@"[VirGL] Task111 ANGLE EGL symbol resolution incomplete");
        return -1;
    }

    ame_vs_display = ame_vs_eglGetDisplay(AME_VS_EGL_DEFAULT_DISPLAY);
    if (!ame_vs_display) {
        NSLog(@"[VirGL] Task111 eglGetDisplay failed");
        return -1;
    }
    if (ame_vs_eglInitialize(ame_vs_display, NULL, NULL) != 1) {
        NSLog(@"[VirGL] Task111 eglInitialize failed");
        return -1;
    }
    ame_vs_eglBindAPI(AME_VS_EGL_OPENGL_ES_API);

    const EGLint config_attribs[] = {
        AME_VS_EGL_SURFACE_TYPE, AME_VS_EGL_PBUFFER_BIT,
        AME_VS_EGL_RENDERABLE_TYPE, AME_VS_EGL_OPENGL_ES2_BIT,
        AME_VS_EGL_RED_SIZE, 8,
        AME_VS_EGL_GREEN_SIZE, 8,
        AME_VS_EGL_BLUE_SIZE, 8,
        AME_VS_EGL_ALPHA_SIZE, 8,
        AME_VS_EGL_NONE
    };
    EGLConfig config = NULL;
    EGLint num_configs = 0;
    if (ame_vs_eglChooseConfig(ame_vs_display, config_attribs, &config, 1, &num_configs) != 1 ||
        !config || num_configs < 1) {
        NSLog(@"[VirGL] Task111 eglChooseConfig found no pbuffer ES config");
        return -1;
    }

    const EGLint pbuffer_attribs[] = {
        AME_VS_EGL_WIDTH, 1,
        AME_VS_EGL_HEIGHT, 1,
        AME_VS_EGL_NONE
    };
    ame_vs_pbuffer = ame_vs_eglCreatePbufferSurface(ame_vs_display, config, pbuffer_attribs);
    if (!ame_vs_pbuffer) {
        NSLog(@"[VirGL] Task111 eglCreatePbufferSurface failed");
        return -1;
    }

    const EGLint ctx_attribs[] = {
        AME_VS_EGL_CONTEXT_CLIENT_VERSION, 3,
        AME_VS_EGL_NONE
    };
    ame_vs_context = ame_vs_eglCreateContext(ame_vs_display, config, NULL /* no share */, ctx_attribs);
    if (!ame_vs_context) {
        NSLog(@"[VirGL] Task111 eglCreateContext(ES3) failed");
        return -1;
    }

    // ---- 3. 服务线程 ----
    pthread_t thread;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    // vrend 着色器编译可能在服务端深度递归，给足栈（对齐 main_hook 32MB 经验值）
    pthread_attr_setstacksize(&attr, 16 * 1024 * 1024);
    int rc = pthread_create(&thread, &attr, ame_vs_server_thread, NULL);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        NSLog(@"[VirGL] Task111 pthread_create failed: %d", rc);
        return -1;
    }

    // ZL2 同款：给服务端 100ms 完成 bind+listen 进入 accept（backlog 也会兜住
    // 更早到来的连接，这里只是额外保险）
    usleep(100 * 1000);

    ame_vs_started = 1;
    NSLog(@"[VirGL] Task111 server bootstrap complete (socket=%s, ES3 host ctx=%p)",
          ame_vs_socket_path, ame_vs_context);
    return 0;
}
