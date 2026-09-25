// Natives/openal_shim.c — Task 129：ALC_SOFT_system_events 兼容垫片
// ============================================================================
// 崩溃取证（26.1.2 整合包，bd71210 会话 latestlog.old.txt 09:27:29）：
//   net.minecraft.client.sounds.SoundEngine.<init>
//     -> com.mojang.blaze3d.audio.Library.createDeviceTracker()
//     -> CallbackDeviceTracker.isSupported()
//        （26.1.2 无 alcIsExtensionPresent 守卫 —— 26.3 有，见下）
//     -> CallbackDeviceTracker.isSupportedForPlaybackDevice()
//     -> LWJGL SOFTSystemEvents.alcEventIsSupportedSOFT
//        ICD 函数指针为 NULL -> Checks.check 抛 NullPointerException -> 崩溃。
//
// 根因链（三层事实，全部离线验证）：
//   1) 本仓 libopenal_impl.dylib 是 openal-soft 1.20.1 的 iOS 构建，
//      ALC_EXTENSIONS 里没有 ALC_SOFT_system_events，也没有那三个函数；
//   2) LWJGL 3.4.1 ALCCapabilities 只在"扩展在 ALC_EXTENSIONS 串里出现"时才
//      解析 32/33/34 号函数槽（check_SOFT_system_events 的 ext.contains 门），
//      否则槽位保持 0 —— MC 调用绑定时 Checks.check 直接 NPE。
//      即 Task112 的"无扩展 => 干净回退"论断对 26.1.2 这类无守卫版本不成立：
//      回退发生在 MC 层（PollingDeviceTracker），但前提是函数指针非空且返回 0；
//   3) MC 26.3 的 isSupported() 开头有 alcIsExtensionPresent(NULL, ...) 守卫，
//      26.1.2 没有 —— 这就是同一构建上 26.3 存活、26.1.2 崩溃的全部差异。
//
// 修复（本垫片，shaderc_shim.c 同款 re-export 模式）：
//   - re-export impl 的全部符号（真实音频路径零改动）；
//   * 覆盖 alcGetString：ALC_EXTENSIONS 查询时按查询组合追加
//     " ALC_SOFT_system_events"（全局/设备级各自组合，不共用缓存，
//      避免设备级扩展列表被全局列表顶替）；
//   * 覆盖 alcIsExtensionPresent：对 "ALC_SOFT_system_events" 应答 ALC_TRUE；
//   * 定义 alcEventIsSupportedSOFT -> 返回 ALC_FALSE（事件类型不支持）
//     => MC 26.1.2：isSupportedForPlaybackDevice 走 "result==0 => warn+false"
//        分支，干净回退 PollingDeviceTracker（与 26.3 现状同构）；
//     => MC 26.3：守卫通过 -> 同样 warn+回退（多三条 WARN 日志，语义正确）；
//   * 定义 alcEventControlSOFT -> ALC_FALSE、alcEventCallbackSOFT -> no-op，
//     防御任何不查 isSupported 就直接调用的 mod；
//   * 若未来 impl 换成自带真扩展的 openal-soft（>=1.24/1.25），构造期检测
//     alcGetProcAddress 能否解析真实现：能则全部转发，垫片自动退化为透明。
//
// 解析约定（照抄 shaderc_shim.c 的教训）：
//   - 取"未被 fishhook 拦截的原始 dlsym"（hook 只拦 shaderc_/spvc_/SDL 前缀，
//     "dlsym" 本身直通）；
//   - impl 句柄用 NOLOAD 优先（re-export 依赖保证它已加载），@loader_path/
//     @rpath/裸名依次尝试；全部失败时覆盖函数退化为安全返回值。
//
// 设备锚点："[Amethyst] Task129: OpenAL shim active (...)"（stderr，随 latestlog）；
//   26.1.2 会话预期：三条 "Failed to check event 19d6/19d7/19d8, error: 0"
//   WARN + 不再出现 NullPointerException。
// ============================================================================

#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

// ---- OpenAL ALC 基本类型（避免引入完整头；ABI 上 int/uchar 与官方一致） ----
typedef int ALCenum;
typedef unsigned char ALCboolean;
typedef unsigned int ALCsizei;

#define AME129_ALC_EXTENSIONS 0x1006
#define AME129_ALC_FALSE 0
#define AME129_ALC_TRUE 1

static const char AME129_EXT_NAME[] = "ALC_SOFT_system_events";

// ---- impl 函数指针（构造期解析） ----
static void *(*ame129_raw_dlsym)(void *, const char *) = NULL;
static void *ame129_impl = NULL;
static const char *(*ame129_impl_alcGetString)(void *, ALCenum) = NULL;
static ALCboolean (*ame129_impl_alcIsExtensionPresent)(void *, const char *) = NULL;

// 真实现（impl 自带扩展时非 NULL，垫片退化为转发）
static int (*ame129_real_is_supported)(int, int) = NULL;
static ALCboolean (*ame129_real_control)(ALCsizei, const ALCenum *, ALCboolean) = NULL;
static void (*ame129_real_callback)(void *, void *) = NULL;

static int ame129_ready = 0;
static int ame129_forwarding = 0; // 1 = impl 自带真扩展，全部转发

// ALC_EXTENSIONS 组合缓冲（静态，互斥保护；串长 ~300B，2KB 充裕）
static pthread_mutex_t ame129_ext_lock = PTHREAD_MUTEX_INITIALIZER;
static char ame129_ext_buf[2048];

// ---- 桩函数（LWJGL 通过 dlsym 落到这里的调用签名） ----
// LWJGL 3.4.1 SOFTSystemEvents：JNI.invokeI(eventType, deviceType) -> int
int alcEventIsSupportedSOFT(int eventType, int deviceType) {
    if (ame129_real_is_supported)
        return ame129_real_is_supported(eventType, deviceType);
    return AME129_ALC_FALSE; // 事件类型不支持 => MC 回退轮询
}

// LWJGL：JNI.invokePZ(count, events, enable) -> boolean
ALCboolean alcEventControlSOFT(ALCsizei count, const ALCenum *events,
                               ALCboolean enable) {
    if (ame129_real_control)
        return ame129_real_control(count, events, enable);
    return AME129_ALC_FALSE;
}

// LWJGL：JNI.invokePPV(callback, userParam) -> void
void alcEventCallbackSOFT(void *callback, void *userParam) {
    if (ame129_real_callback)
        ame129_real_callback(callback, userParam);
}

// ---- 覆盖：alcGetString（仅 ALC_EXTENSIONS 追加扩展名，其余原样转发） ----
const char *alcGetString(void *device, ALCenum param) {
    if (ame129_impl_alcGetString == NULL)
        return NULL; // 构造失败的安全兜底（正常不可能到达）
    const char *base = ame129_impl_alcGetString(device, param);
    if (param != AME129_ALC_EXTENSIONS || !ame129_ready || ame129_forwarding ||
        base == NULL) {
        return base;
    }
    if (strstr(base, AME129_EXT_NAME) != NULL)
        return base; // 已含（异常态，防御）
    pthread_mutex_lock(&ame129_ext_lock);
    size_t len = strlen(base);
    if (len + 1 + sizeof(AME129_EXT_NAME) <= sizeof(ame129_ext_buf)) {
        memcpy(ame129_ext_buf, base, len);
        ame129_ext_buf[len] = ' ';
        memcpy(ame129_ext_buf + len + 1, AME129_EXT_NAME,
               sizeof(AME129_EXT_NAME));
        pthread_mutex_unlock(&ame129_ext_lock);
        return ame129_ext_buf;
    }
    pthread_mutex_unlock(&ame129_ext_lock);
    return base; // 放不下就不追加（回到旧行为）
}

// ---- 覆盖：alcIsExtensionPresent（对本扩展应答真，其余转发） ----
ALCboolean alcIsExtensionPresent(void *device, const char *name) {
    if (ame129_ready && !ame129_forwarding && name != NULL &&
        strcmp(name, AME129_EXT_NAME) == 0) {
        return AME129_ALC_TRUE;
    }
    if (ame129_impl_alcIsExtensionPresent == NULL)
        return AME129_ALC_FALSE;
    return ame129_impl_alcIsExtensionPresent(device, name);
}

// ---- 构造期：解析 impl、检测真扩展 ----
__attribute__((constructor))
static void ame129_openal_shim_init(void) {
    // 原始 dlsym（shaderc_shim 同款：hook 不拦 "dlsym" 本身）
    ame129_raw_dlsym = (void *(*)(void *, const char *))dlsym(RTLD_DEFAULT, "dlsym");
    if (ame129_raw_dlsym == NULL)
        ame129_raw_dlsym = &dlsym;

    // impl 句柄：re-export 依赖已保证加载，NOLOAD 取回即可
    static const char *const kCandidates[] = {
        "@loader_path/libopenal_impl.dylib",
        "@rpath/libopenal_impl.dylib",
        "libopenal_impl.dylib",
        NULL,
    };
    for (int i = 0; kCandidates[i] != NULL; ++i) {
        ame129_impl = dlopen(kCandidates[i], RTLD_LAZY | RTLD_LOCAL | RTLD_NOLOAD);
        if (ame129_impl == NULL)
            ame129_impl = dlopen(kCandidates[i], RTLD_LAZY | RTLD_LOCAL);
        if (ame129_impl != NULL)
            break;
    }
    if (ame129_impl == NULL) {
        fprintf(stderr, "[Amethyst] Task129: OpenAL shim FAILED to load "
                        "libopenal_impl.dylib: %s\n", dlerror());
        return; // ame129_ready 保持 0：覆盖函数退化为转发/NULL 兜底
    }

    ame129_impl_alcGetString = (const char *(*)(void *, ALCenum))
        ame129_raw_dlsym(ame129_impl, "alcGetString");
    ame129_impl_alcIsExtensionPresent = (ALCboolean (*)(void *, const char *))
        ame129_raw_dlsym(ame129_impl, "alcIsExtensionPresent");
    if (ame129_impl_alcGetString == NULL ||
        ame129_impl_alcIsExtensionPresent == NULL) {
        fprintf(stderr, "[Amethyst] Task129: OpenAL shim FATAL - impl core ALC "
                        "symbols unresolved\n");
        return;
    }

    // 检测 impl 是否自带真扩展（未来换 1.25.x impl 时自动透明转发）
    void *(*impl_alcGetProcAddress)(void *, const char *) =
        (void *(*)(void *, const char *))ame129_raw_dlsym(ame129_impl,
                                                          "alcGetProcAddress");
    if (impl_alcGetProcAddress != NULL) {
        void *p = impl_alcGetProcAddress(NULL, "alcEventIsSupportedSOFT");
        if (p != NULL) {
            ame129_real_is_supported = (int (*)(int, int))(uintptr_t)p;
            ame129_real_control = (ALCboolean (*)(ALCsizei, const ALCenum *,
                                                  ALCboolean))(uintptr_t)
                impl_alcGetProcAddress(NULL, "alcEventControlSOFT");
            ame129_real_callback = (void (*)(void *, void *))(uintptr_t)
                impl_alcGetProcAddress(NULL, "alcEventCallbackSOFT");
            if (ame129_real_control != NULL && ame129_real_callback != NULL)
                ame129_forwarding = 1;
        }
    }

    ame129_ready = 1;
    if (ame129_forwarding) {
        fprintf(stderr, "[Amethyst] Task129: OpenAL shim active (transparent - "
                        "impl provides ALC_SOFT_system_events natively)\n");
    } else {
        fprintf(stderr, "[Amethyst] Task129: OpenAL shim active (ALC_SOFT_system_"
                        "events stubs advertised over openal-soft 1.20.1 impl; "
                        "isSupported->ALC_FALSE => MC polling fallback)\n");
    }
}
