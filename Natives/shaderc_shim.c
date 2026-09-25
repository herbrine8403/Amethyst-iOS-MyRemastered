// shaderc 串行化垫片（Amethyst iOS 26.3-pre-1 RenderPearl 稳定性修复）
//
// 背景（hs_err_pid27329，构建 bcf33453）：ABI 修复后 shaderc 首编成功、MG 转换
// 连续成功、首帧渲染完成；随后资源重载阶段，两个 32MB 栈 JVM 线程（Thread-1/
// Thread-2）同时直接执行 libshaderc 的 glslang yyparse（绕过了 hooked_dlsym
// wrapper 的调用路径），并发编译导致 glslang AST 节点内存互相踩踏，
// TParseContext::lValueErrorCheck+0x204 读到脏指针 SEGV_ACCERR，双线程同崩。
//
// 修复策略：把真实库改名 libshaderc_impl.dylib，本垫片顶替 libshaderc.dylib：
//   - 通过 -reexport_library 透传 impl 的全部符号（glslang/shaderc API 原样可用）；
//   - 自行定义三个编译入口（shaderc_compile_into_spv / _spv_assembly /
//     _preprocessed_text），以进程级递归互斥锁强制全部编译串行——无论调用方走
//     hooked dlsym、RTLD_DEFAULT 还是其它任何动态解析路径，拿到的都是这里的
//     带锁转发器，从根上消灭"多上下文并发编译"这一崩溃形态。
//
// Task 30（hs_err_pid27946，构建 744642f2）：串行化已生效，崩溃线程栈确认为
// wrapper → 本垫片 → impl 单线程编译，但第 9 次编译仍在
// glslang::TParseContext::lValueErrorCheck+0x204 崩：SWIZZLE 选择器节点的
// constArray 指针字段（对象偏移 +0xd8）被 8 字节 ASCII 字符串数据覆盖
// （si_addr=0x66617263656e6900 = "\0inceraf"）——内存被释放后又被字符串分配
// 复用的特征。本垫片此前只串行了 3 个编译入口，而 shaderc 的生命周期入口
// 全部裸奔：
//   shaderc_compiler_release →（最后一个 compiler 时）glslang::FinalizeProcess()
//   → 拆全局符号表、释放 glslang 池。MC 26.3 资源重载 = 旧 RenderPearl 管线
//   释放 + 新管线并发编译（release 可能经任意 Java 线程乃至 GC/Cleaner 线程
//   触发），release 与 in-flight 编译竞态 → 编译中的 AST 所在内存被释放、
//   随后被任意字符串分配（JVM young GC / 资源加载 / unifont 装载）复用 →
//   ASCII 字节落进指针字段。2026-08 MobileGlues 2.0.1..2.0.3 的同签名设备
//   崩溃（注释原文 "clean under ASan"）说明该竞态家族早于 Amethyst 介入。
// 修复：compiler/options 的 initialize / release / clone / add_macro_definition
//   一并纳入同一把递归互斥锁。release 若撞上 in-flight 编译会阻塞等待并打出
//   "BLOCKED" 取证日志——竞态窗口从根上关闭。options_set_* 变更族不入锁：
//   options 是单线程编译作用域对象，实际危险的是 release-vs-compile，已覆盖。
//
// ⚠️ 实现要点：解析 impl 真实符号必须用"未被 fishhook 拦截的原始 dlsym"。
// 若直接调用 dlsym(impl, "shaderc_compile_into_spv")，hooked_dlsym 会按符号名
// 拦截并返回 main_hook.m 的 32MB-stack wrapper，而该 wrapper 又会回调本垫片的
// 转发器 —— 同线程重入已持有的锁即自死锁。因此构造时先经
// dlsym(RTLD_DEFAULT, "dlsym") 取回原始 dlsym（hook 只拦 shaderc_/spvc_/SDL
// 前缀，"dlsym" 本身直通），后续一律用它解析 impl。
//
// 注意：本垫片只做串行化 + 取证日志，不做 32MB 栈 hop（hooked 路径的 hop 仍由
// main_hook.m 的 wrapper 负责，二者按构造叠加：wrapper hop → 本垫片加锁）。
// 取证日志（Task 30）：每个生命周期事件与每次编译各一行，带进程启动起的毫秒
// 数与线程标识；release 在锁被占用时先打 "BLOCKED behind in-flight compile"
// 再等锁——若真机日志出现该行，即证明 release-vs-compile 竞态真实发生过
// （且已被本次修复挡下）。
//
// Task 34（hs_err_pid33505，构建 777302c）：黑屏修复验证通过（embed 成功、
// 首帧 eglSwapBuffers OK、fps=10），但 shaderc compile#7（terrain 顶点）在
// glslang::TParseContext::lValueErrorCheck+0x204 SIGSEGV——与 Task 30 同签名
// 同 PC，且同一二进制同一 shader 在上一轮跑了 390 次全过 = 非确定性堆踩踏。
// 双层修复：
//   1) scripts/patch_shaderc_lvalue_guard.py 对 libshaderc_impl.dylib 做机器码
//      级补丁（把脆弱 swizzle 循环体重定位到 __TEXT 尾部 cave，加 5 重空指针
//      + 1 重负值 + 1 重越界防护，与 MobileGlues 源码级 nullguard patch 等价）；
//   2) 本文件加装“编译窗口崩溃恢复网”：真实编译期间进程级接管 SIGSEGV/SIGBUS，
//      编译线程内崩溃→siglongjmp 回未恢复并重试一次；重试再崩→返回 NULL 并
//      把崩溃信息打进日志（非编译线程的崩溃照旧链回 JVM 处理器走 hs_err）。
//      这样即便 impl 里还藏着其它同类脆弱点，也只损失单个 shader 编译而不是
//      整个进程。恢复代价：被丢弃的解析树内存泄漏（罕见事件，可接受）。

//
// Task 37（latestlog 2026-09-06 18:42，构建 e28e4c3，GL 渲染器路径）：
// 渲染器切换成功后 GL 链路首次贯通（embed 成功、首帧 eglSwapBuffers OK），
// 但资源重载阶段 shaderc 复杂 shader（terrain/entity/clouds…）全部双崩
// （重试必崩 = 确定性环境破坏，非瞬态踩踏），崩溃网恢复后返回 NULL →
// LWJGL Checks.check 对 NULL 指针抛 NPE →
// GlslCompiler.compileToSpv:147 → CompletionException → 游戏崩溃。
// 崩溃窗口与 MobileGlues 转换器激活窗口完全重合（[MG] Shader N converted
// 从 t≈280ms 起持续工作；compile#1-4 在 MG 启动前全部成功；同窗口内简单
// shader 也成功、复杂 shader 全崩）。全进程实际存在四套转换引擎并发：
// 本 impl 的 glslang + spvc 的 SPIRV-Cross（RenderPearl 管线，两把独立的
// shim 锁）vs MG 内嵌的 glslang + SPIRV-Cross（GLSLtoGLSLES_2，仅自带
// g_conv_serial 自身互斥）——跨引擎零串行。MG 侧自己的注释（glsl_for_es.cpp
// g_conv_serial 处）已实证同库并发解析会互踩 AST；跨引擎并发同理可信。
// 三连修复：
//   1) ame_master_compile_lock：本垫片升级为跨库总锁持有者并导出 C 符号；
//      spvc_shim / MobileGlues 的 GLSLtoGLSLES_2 通过 dlopen("libshaderc.dylib")
//      + dlsym 协商同一把锁（拿不到则各自退回本地锁，向后兼容）；
//      shaderc 编译 / spvc 交叉编译 / MG 转换三方彻底串行，并发窗口归零。
//   2) 双崩后不再返回 NULL：合成 fake result（magic 标记 + status=
//      internal_error + 取证错误消息），并拦截 shaderc_result_* 访问器族
//      （release / status / errors / warnings / message / bytes / length /
//      spv_bytes / spv_length）识别 fake 指针——LWJGL 拿到非 NULL 句柄，
//      MC 走正常「编译失败」路径，NPE 消失；
//   3) 崩溃网打印崩溃 PC/LR（arm64 ucontext）——下轮日志可直接对着 impl
//      符号表离线 symbolicate，定位具体 glslang 函数。
//
// Task 38（latestlog 2026-09-06 19:42，构建 2613e41，GL 渲染器路径“崩溃了”）：
// 判读：GL 链路全线贯通（embed/EGL 表面/首帧上屏/后端 OpenGL+ANGLE），资源
// 重载阶段 564 次编译中 342 次在固定 PC（0x133a0a430，两次变体相差 8 字节
// =指针解链的相邻两级 load）SIGSEGV，si_addr 为 ASCII 字符串/浮点常量字节
// （"minecraft"/"visible"/float 数据）= 堆踩踏读脏指针；合成失败结果生效
// （NPE 已消失）→ MC 抛 ShaderCompileException → 全部 pipeline 程序加载失败
// → CompletionException → 游戏崩溃退出（crash-2026-09-06_19.42.26）。
// 离线 symbolicate：impl 的 Task34 补丁字节在（trampoline+cave 验证通过），
// 16KB 页对齐穷举（pc mod 16K = 0xa430 → 5 个候选偏移）无一匹配崩溃形状
// → 崩溃 PC 不在 impl / mobileglues / spvc / SDL3 / MoltenVK 等任何本地可
// 枚举镜像 → 极大概率在共享缓存（libsystem malloc 的元数据遍历）。
// 关键时序证据（三份日志交叉比对）：
//   e28e4c3-GL（零崩溃）：402 次编译全部完成后才首次 swap（第 6002 行）；
//   Vulkan（零崩溃）：无 eglSwapBuffers（CAMetalLayer 直呈），无首帧
//     确认-遮罩移除路径；
//   bec59b4/2613e41（崩溃）：首次成功 swap（MG 前端 presentSurface 生效）
//     在 t≈460ms、编译风暴正中，紧随其后的复杂 shader 编译必崩。
// 结论：渲染首帧绘制通路（MG 每帧翻译层/ANGLE/Metal/遮罩移除）与编译并发
// 时踩踏堆；Task 37 总锁无效证明非跨引擎并发竞态。另实锤：2613e41 运行中
// MG 转换全部命中磁盘缓存（GLSLtoGLSLES_2 未被调用，协商日志未打），
// MG 内嵌 glslang 根本没跑——写入者是 MG 之外的某处。
// 四连修复：
//   1) 崩溃网加装 dladdr 取证：直接打印崩溃 PC/LR 所在镜像名、符号名与
//      偏移，下轮日志无需离线猜 slide 即可定位崩溃函数；
//   2) 编译器句柄间接层（java 句柄 ↔ live impl 句柄映射 + 引用计数）；
//   3) glslang 进程状态重建自愈：双崩后释放全部 live compiler（最后一次
//      release 触发 glslang::FinalizeProcess() 拆掉毒化的全局符号表/池）
//      → 重新 initialize（全新 InitializeProcess）→ 全句柄重映射 → 再试
//      编译一次。预算 5 次/进程（每次重建约 50-300ms）。毒化若在 glslang
//      持久结构中则直接痊愈；若在 malloc 自由区域则预算耗尽后退回合成失败
//      （与现状一致，零回退）；
//   4) options 取证：拦截 set_target_env / set_source_language /
//      set_optimization_level / set_generate_debug_info /
//      set_forced_version_profile 五个设置口并打印值——揭示 GL 路径 vs
//      Vulkan 路径的编译选项差异（优化等级/目标环境）。
//
// Task 44（latestlog 0ac1c2f，构建 3f6f3a6，用户“还是一样”）判读定案 +
// 三层进程内防御加固：
// 证据链（跨 5 份日志交叉比对）：
//  a) fork() EPERM + posix_spawn 失败——沙盒侧载安装上进程创建全不可用，
//     Task 42/43 进程外沙箱在本机结构性失效；进程内路径是唯一现实路径；
//  b) 首崩恒为 compile#7（terrain 首个复杂 shader）；同源码→同阶段→同
//     si_addr（跨线程/跨 compiler/跨 glslang 重建完全复现，compile#8 用全新
//     线程 + 重建后新 compiler 依然同 PC 同 si_addr）→ 毒化是【堆布局级】
//     确定性：编译池落在含源码字节/浮点常量的回收内存上；
//  c) d638c22 同二进制同 shader 同事件序列零崩溃（390/390）→ 跨 run 非确定
//     （ASLR/布局运气），同 run 内确定 → 一旦首次碰撞即级联（176/223 失败）；
//  d) glslang 进程状态重建 5/5 全部耗尽且重建后同线程第三搏照崩 →
//     毒化不在 glslang 全局结构，重建救不回；
//  e) 首帧门控生效（First present deferred）且崩溃始于首个复杂 shader →
//     Task 38“首帧 present 踩堆”理论被本日志证伪（present 未发生也崩）。
// 定性修正：崩溃放大器在本垫片自己的重试链上——longjmp 跳过 impl 的 C++
// 析构后，同线程 TLS 上的 glslang 池状态残留，重试必然落回同一片回收内存。
// 三层修复：
//   1) 所有重试/重建后尝试改在【全新 32MB 栈线程】上执行（virgin TLS +
//      全新分配序列），打散“重试落回同一片毒化内存”的确定性；恢复一次
//      即入 Task 43 磁盘缓存，跨启动单调固化；
//   2) 去掉 SA_ONSTACK（从未配置 sigaltstack，属未定义行为依赖）；重建
//      预算 5→8；
//   3) cache miss 即转储精确输入（源码 + kind/entry/options 全字段）到
//      POJAV_HOME/ame_shaderc_dump——跨渲染器播种若因 options 差异 key
//      不相交，下一任务可离线预编译并随 IPA 播种。
// 战略路径（零代码）：Vulkan 路径编译风暴零崩溃（同 shim 同 impl 同 223
// 个 shader，堆安静）→ 一次 Vulkan run 即全量播种 ame_shaderc_cache →
// 切回 GL 后逐条 HIT、零 glslang 暴露、零崩溃窗口。首次失败时打 TIP 日志
// 指引用户走此路径。
//
// Task 45（latestlog 2026-09-07 16:34，用户"还是不行，这次连 Vulkan 都不行"）
// 判读 + 架构根治：本轮 Vulkan run 同样死于 shaderc 编译风暴（compile#7
// terrain 起双崩→合成失败→"Failed to load required shader programs"→MC 崩
// 溃退出；fps=0 swapOK=0，渲染链路本身无辜）——"Vulkan 播种"战略路径被证
// 伪（同一毒化家族对两条 RenderPearl 路径无差别）。45 个任务里唯一从未换
// 过的变量是 libshaderc_impl.dylib 这个预编译 blob 本身（Task 44 实证：同
// blob 同 shader 同事件序列，一个 run 390/390 全过、另一个 run 63% 崩 =
// 跨 run ASLR/堆布局运气）。本任务直接换掉这个变量：
//   dep_shader_shims 现在从源码构建 libshaderc_impl.dylib——
//   Natives/shaderc_impl_glue.c（shaderc 全 ABI 之上的 glslang C 接口实现）
//   链接 dep_mg 刚构建的同一 pin f5f664d 静态库（nullguard 源码补丁 + Task
//   45 池清零/size 守卫补丁都已打上）。进程里唯一的 glslang 从此就是那个
//   打了补丁、新鲜构建、MobileGlues 同源的一份；Task 34 的机器码 cave 补
//   （patch_shaderc_lvalue_guard.py）随之退役（脚本留档）。本垫片的串行化/
//   崩溃网/重建/缓存/沙箱链路零改动——转发目标从预编译 blob 变成了源码
//   构建 impl，沙箱子进程按路径 dlopen 的也是它。
// 端到端验证（Linux 真实构建双补丁 glslang + glue 链接 + 27 断言测试）：
// VS/FS 出合法 SPIR-V、MC 精确调用形态（vulkan 1.2 + debug info）、宏注入
// 在 #version 行之后（glslang set_preamble 会把 #version 挤下首行使版本
// 回落 110）、非 NUL 结尾源码、错误路径、300 次风暴、finalize/init 引用计
// 数循环全绿；preprocess→parse 的 C 接口强序（parse 编译的是
// preprocessedGLSL 而非原始源码）已内建。

#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include "shaderc_sandbox.h" // Task 42：进程外编译沙箱（父侧集成点）
#include "shaderc_include.h" // Task 47：RenderPearl 26.3 #include 文本展开

static pthread_mutex_t ame_shaderc_shim_lock;
static void *ame_shaderc_shim_impl = NULL;
static void *(*ame_shaderc_shim_real_dlsym)(void *, const char *) = NULL;

// ---- Task 37：跨库编译总锁导出 ----
// spvc_shim 与 MobileGlues 的 GLSL 转换器（GLSLtoGLSLES_2）在运行时
// dlopen("libshaderc.dylib") 后 dlsym("ame_master_compile_lock") 拿到本函数，
// 与本垫片的编译/生命周期锁共用同一把递归互斥锁，消灭「四引擎并发」窗口。
// 返回值恒非 NULL；协商失败方退回各自本地锁，不影响本垫片自身行为。
pthread_mutex_t *ame_master_compile_lock(void) {
    return &ame_shaderc_shim_lock;
}

// 进程启动起的毫秒数（取证时间轴；首个调用线程初始化 t0，毫秒精度足够）。
static double ame_shim_ms(void) {
    static struct timespec t0;
    static volatile int t0_set = 0;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC_RAW, &now);
    if (!t0_set) {
        t0 = now;
        t0_set = 1;
    }
    return (double)(now.tv_sec - t0.tv_sec) * 1000.0 +
           (double)(now.tv_nsec - t0.tv_nsec) / 1.0e6;
}

// 线程标识（pthread_t 低 32 位；用于与 hs_err 线程列表人工对照）。
static unsigned long ame_shim_tid(void) {
    return (unsigned long)(((uintptr_t)pthread_self()) & 0xffffffffull);
}

// ---- Task 39：编译活动心跳（首帧呈现门控信号，供 egl_bridge dlsym） ----
// egl_bridge.m 的首帧门控（pojavSwapBuffers）在放行首次 eglSwapBuffers 前，
// 通过 dlsym 本函数确认 shaderc 编译风暴已静止 >= 2s。四份日志交叉取证：
// bec59b4/2613e41/2092d27 三连崩溃构建的首次 present 全部插入编译风暴中
//（First swap 行后紧跟首个 compile CRASHED）；e28e4c3-GL 零崩溃构建的首
// present 在全部 402 次编译完成后（且其后 2.8s 的 post-effect 编译全部
// 干净）。返回 UINT64_MAX = 进程从未有过 shaderc 活动（调用方按"安静"处理）。
// 原子访问：渲染线程（读）与 ForkJoin 编译 worker（写）并发无锁。
static volatile uint64_t ame_last_compile_activity_ms = 0;

static void ame_note_compile_activity(void) {
    uint64_t t = (uint64_t)ame_shim_ms();
    if (t == 0) t = 1; // 0 保留给"从未活动"；首次调用与 t0 同毫秒的碰撞兜底
    __atomic_store_n(&ame_last_compile_activity_ms, t, __ATOMIC_RELAXED);
}

// 距上一次 shaderc 侧活动的毫秒数；UINT64_MAX = 从未活动。
uint64_t ame_shaderc_compile_quiescence_ms(void) {
    uint64_t last = __atomic_load_n(&ame_last_compile_activity_ms, __ATOMIC_RELAXED);
    if (last == 0) return UINT64_MAX;
    double now = ame_shim_ms();
    return (now > (double)last) ? (uint64_t)(now - (double)last) : 0;
}

// 取锁；若已有 in-flight 编译持有锁，先打 BLOCKED 取证行再等待。
static void ame_shim_lock_or_report_blocked(const char *what, const void *obj) {
    // Task 39：所有走锁的 API 入口（options/compiler 生命周期等）都算编译
    // 风暴活动，让 egl_bridge 的首帧门控信号更保守（宁多延不误判）。
    ame_note_compile_activity();
    if (pthread_mutex_trylock(&ame_shaderc_shim_lock) == 0) return;
    fprintf(stderr,
            "[shaderc-shim] %s(%p) BLOCKED behind in-flight compile -- waiting "
            "(t=%.0fms tid=%lx)\n",
            what, obj, ame_shim_ms(), ame_shim_tid());
    pthread_mutex_lock(&ame_shaderc_shim_lock);
}

// 前置声明（定义在下方 result 访问器族；本文件公开 ABI，非 static）。
int shaderc_result_get_compilation_status(void *result);
size_t shaderc_result_get_length(void *result);
const char *shaderc_result_get_bytes(void *result);
const char *shaderc_result_get_spv_bytes(void *result);
size_t shaderc_result_get_spv_length(void *result);
static int ame_is_fake_result(const void *result); // 定义见 fake result 节

// ---- Task 43：SPIR-V 磁盘缓存（跨启动单调积累）----
// 动机：跨 42 个 task 的取证已证明进程内崩溃是非确定性堆踩踏（同二进制
// 同输入：一次 run 390 次全过、另一 run 63% 崩）。fork server（Task 43
// 主修复）根治根因；本缓存作为独立防线让【任何路径】的成功编译跨启动
// 固化：每次 run 只剩未命中的 shader 需要真编译，运气单调积累；沙箱被
// 沙盒拒绝的最坏情况下，也只需崩溃有限次即可集齐全部缓存。
// key = FNV-1a(entry/kind/源码字节/输入名/入口名/options 全字段)。
// 写入 tmp+rename 原子；损坏条目读失败即删；AME_SHADERC_CACHE_OFF 可关。
// 命中返回 malloc 的 ame_sb_result_t（magic 复用沙箱结果链路，访问器族
// 零新增代码）；沙箱/进程内两路成功结果统一在编译出口落盘。
// 锁策略：ame_cache_lock 是叶子锁（不进 master 锁序）；文件 I/O 在锁外
//（rename 原子性保证并发安全）。
static pthread_mutex_t ame_cache_lock = PTHREAD_MUTEX_INITIALIZER;
static int ame_cache_state = 0; // 0 未初始化 / 1 可用 / -1 禁用
static char ame_cache_dir[3800];
#define AME_CACHE_MAX_FILES 4096
#define AME_CACHE_MAX_BLOB (64u * 1024u * 1024u)

static uint64_t ame_cache_fnv(const void *data, size_t n, uint64_t h) {
    const unsigned char *p = (const unsigned char *)data;
    while (n--) {
        h ^= (uint64_t)*p++;
        h *= 0x100000001b3ull;
    }
    return h;
}

static uint64_t ame_cache_key(int entry, int kind, const char *source, size_t source_len,
                              const char *input_file, const char *entry_point,
                              const ame_sb_opt_fields_t *opt) {
    uint64_t h = 0xcbf29ce484222325ull;
    h = ame_cache_fnv(&entry, sizeof(int), h);
    h = ame_cache_fnv(&kind, sizeof(int), h);
    h = ame_cache_fnv(&source_len, sizeof(size_t), h);
    if (source_len > 0) h = ame_cache_fnv(source, source_len, h);
    if (input_file != NULL) {
        h = ame_cache_fnv(input_file, strlen(input_file) + 1, h);
    } else {
        h = ame_cache_fnv("\x01", 1, h); // NULL 与 "" 区分
    }
    if (entry_point != NULL) {
        h = ame_cache_fnv(entry_point, strlen(entry_point) + 1, h);
    } else {
        h = ame_cache_fnv("\x01", 1, h);
    }
    if (opt != NULL) h = ame_cache_fnv(opt, sizeof *opt, h);
    return h;
}

// 持锁调用：初始化目录 + 防御性清理（残留 .tmp 删除；条目超限整目录清空）。
static void ame_cache_init_locked(void) {
    if (ame_cache_state != 0) return;
    if (getenv("AME_SHADERC_CACHE_OFF") != NULL) {
        ame_cache_state = -1;
        return;
    }
    const char *home = getenv("POJAV_HOME");
    if (home == NULL || *home == '\0') {
        ame_cache_state = -1;
        return;
    }
    snprintf(ame_cache_dir, sizeof ame_cache_dir, "%s/ame_shaderc_cache", home);
    if (mkdir(ame_cache_dir, 0755) != 0 && errno != EEXIST) {
        ame_cache_state = -1;
        return;
    }
    int count = 0, wiped = 0;
    DIR *d = opendir(ame_cache_dir);
    if (d != NULL) {
        struct dirent *de;
        char path[4096];
        while ((de = readdir(d)) != NULL) {
            if (de->d_name[0] == '.') continue;
            const char *ext = strrchr(de->d_name, '.');
            if (ext != NULL && strcmp(ext, ".tmp") == 0) {
                // 崩溃残留的半写文件
                snprintf(path, sizeof path, "%s/%s", ame_cache_dir, de->d_name);
                unlink(path);
                wiped++;
                continue;
            }
            count++;
        }
        closedir(d);
    }
    if (count > AME_CACHE_MAX_FILES) {
        d = opendir(ame_cache_dir);
        if (d != NULL) {
            struct dirent *de;
            char path[4096];
            while ((de = readdir(d)) != NULL) {
                if (de->d_name[0] == '.') continue;
                snprintf(path, sizeof path, "%s/%s", ame_cache_dir, de->d_name);
                unlink(path);
            }
            closedir(d);
            count = 0;
            wiped += 1 << 20; // 标记：整目录清空
        }
    }
    ame_cache_state = 1;
    fprintf(stderr, "[shaderc-cache] enabled at %s (%d entries%s)\n", ame_cache_dir,
            count, wiped ? ", cleaned" : "");
}

static void *ame_cache_lookup(uint64_t key) {
    pthread_mutex_lock(&ame_cache_lock);
    ame_cache_init_locked();
    if (ame_cache_state != 1) {
        pthread_mutex_unlock(&ame_cache_lock);
        return NULL;
    }
    char path[4096];
    snprintf(path, sizeof path, "%s/%016llx.spv", ame_cache_dir,
             (unsigned long long)key);
    pthread_mutex_unlock(&ame_cache_lock);

    FILE *f = fopen(path, "rb");
    if (f == NULL) return NULL;
    ame_sb_result_t *res = NULL;
    do {
        if (fseek(f, 0, SEEK_END) != 0) break;
        long sz = ftell(f);
        if (sz < 0 || (unsigned long)sz > AME_CACHE_MAX_BLOB) break;
        if (fseek(f, 0, SEEK_SET) != 0) break;
        res = (ame_sb_result_t *)malloc(sizeof(ame_sb_result_t) + (size_t)sz + 1);
        if (res == NULL) break;
        res->magic = AME_SB_RESULT_MAGIC;
        res->status = 0; // 只存成功编译
        res->spv_len = (uint32_t)sz;
        res->err_len = 0;
        if (sz > 0 && fread((char *)ame_sb_result_spv(res), 1, (size_t)sz, f) != (size_t)sz) {
            free(res);
            res = NULL;
            break;
        }
        *(char *)ame_sb_result_err(res) = '\0';
    } while (0);
    fclose(f);
    if (res == NULL) unlink(path); // 损坏条目：删除，下次重编译
    return res;
}

static int ame_cache_store(uint64_t key, const void *bytes, uint32_t len) {
    if (bytes == NULL || len == 0 || len > AME_CACHE_MAX_BLOB) return -1;
    pthread_mutex_lock(&ame_cache_lock);
    ame_cache_init_locked();
    if (ame_cache_state != 1) {
        pthread_mutex_unlock(&ame_cache_lock);
        return -1;
    }
    char path[4096], tmp[4096];
    snprintf(path, sizeof path, "%s/%016llx.spv", ame_cache_dir,
             (unsigned long long)key);
    snprintf(tmp, sizeof tmp, "%s/%016llx.tmp", ame_cache_dir,
             (unsigned long long)key);
    pthread_mutex_unlock(&ame_cache_lock);

    FILE *f = fopen(tmp, "wb");
    if (f == NULL) return -1;
    int ok = (fwrite(bytes, 1, len, f) == len) && (fflush(f) == 0);
    fclose(f);
    if (!ok) {
        unlink(tmp);
        return -1;
    }
    if (rename(tmp, path) != 0) {
        unlink(tmp);
        return -1;
    }
    return 0;
}

// ---- Task 44：源码转储（cache miss 时把精确输入落盘）----
// 目的：跨渲染器缓存播种（Vulkan run 的成功编译全量落缓存后，GL run 直接
// 命中）若因 options 字段差异而 key 不相交，本转储给出离线预编译的精确
// 输入（源码字节 + kind/entry/输入名/options 全字段），CI 可直接复现编译
// 并随 IPA 播种缓存。转储目录与缓存目录平级（不参与缓存清点/清空）。
// 同一 key 只写一次；失败静默（诊断辅助，绝不影响主链路）。持锁调用。
static char ame_dump_dir[3800];
static void ame_cache_dump_source(uint64_t key, int sb_entry, int kind,
                                  const char *source, size_t source_len,
                                  const char *input_file, const char *entry_point,
                                  const ame_sb_opt_fields_t *opt) {
    if (ame_cache_state != 1) return; // 缓存初始化失败则不转储
    if (ame_dump_dir[0] == '\0') {
        const char *home = getenv("POJAV_HOME");
        if (home == NULL || *home == '\0') return;
        snprintf(ame_dump_dir, sizeof ame_dump_dir, "%s/ame_shaderc_dump", home);
        if (mkdir(ame_dump_dir, 0755) != 0 && errno != EEXIST) return;
    }
    char path[4096], meta[4096];
    snprintf(path, sizeof path, "%s/%016llx.src", ame_dump_dir,
             (unsigned long long)key);
    snprintf(meta, sizeof meta, "%s/%016llx.meta", ame_dump_dir,
             (unsigned long long)key);
    FILE *probe = fopen(meta, "rb");
    if (probe != NULL) { fclose(probe); return; } // 已转储过
    if (source == NULL || source_len == 0) return;
    FILE *f = fopen(path, "wb");
    if (f == NULL) return;
    int ok = (fwrite(source, 1, source_len, f) == source_len) && (fflush(f) == 0);
    fclose(f);
    if (!ok) { unlink(path); return; }
    FILE *m = fopen(meta, "wb");
    if (m == NULL) return;
    fprintf(m, "key=%016llx\nsb_entry=%d\nkind=%d\nsource_len=%zu\ninput=%s\nentry=%s\n",
            (unsigned long long)key, sb_entry, kind, source_len,
            input_file ? input_file : "(null)", entry_point ? entry_point : "(null)");
    if (opt != NULL) {
        fprintf(m, "target_env=%d\ntarget_env_version=%u\nsource_language=%d\n"
                   "optimization_level=%d\ngenerate_debug=%d\nhas_forced=%d\n"
                   "forced_version=%d\nforced_profile=%d\nmacro_count=%d\n",
                opt->target_env, opt->target_env_version, opt->source_language,
                opt->optimization_level, opt->generate_debug, opt->has_forced,
                opt->forced_version, opt->forced_profile, opt->macro_count);
        for (int i = 0; i < opt->macro_count && i < AME_SB_MAX_MACROS; ++i) {
            if (opt->macro_has_value[i]) {
                fprintf(m, "macro[%d]=%s=%s\n", i, opt->macro_name[i],
                        opt->macro_value[i]);
            } else {
                fprintf(m, "macro[%d]=%s\n", i, opt->macro_name[i]);
            }
        }
    }
    fclose(m);
}

// Task 38 前置声明：镜像基址取证（定义见下方 result 访问器族之后）。
static void ame_log_impl_bases(void);

__attribute__((constructor))
static void ame_shaderc_shim_init(void) {
    pthread_mutexattr_t lock_attr;
    pthread_mutexattr_init(&lock_attr);
    pthread_mutexattr_settype(&lock_attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&ame_shaderc_shim_lock, &lock_attr);
    pthread_mutexattr_destroy(&lock_attr);
    // 原始 dlsym（"dlsym" 不在 hooked_dlsym 的拦截名单内，直通 orig_dlsym）
    ame_shaderc_shim_real_dlsym =
        (void *(*)(void *, const char *))dlsym(RTLD_DEFAULT, "dlsym");
    if (ame_shaderc_shim_real_dlsym == NULL) {
        fprintf(stderr, "[shaderc-shim] FATAL: cannot obtain unhooked dlsym\n");
        return;
    }
    static const char *const kCandidates[] = {
        "@loader_path/libshaderc_impl.dylib",
        "@rpath/libshaderc_impl.dylib",
        "libshaderc_impl.dylib",
        NULL,
    };
    for (int i = 0; kCandidates[i] != NULL; ++i) {
        ame_shaderc_shim_impl = dlopen(kCandidates[i], RTLD_NOW | RTLD_LOCAL);
        if (ame_shaderc_shim_impl != NULL) {
            fprintf(stderr, "[shaderc-shim] impl loaded via %s\n", kCandidates[i]);
            ame_log_impl_bases();
            return;
        }
    }
    fprintf(stderr, "[shaderc-shim] FAILED to load libshaderc_impl.dylib: %s\n",
            dlerror());
}

// Task 38：镜像基址取证。用 dladdr 反查 impl 的两个入口与 glslang 重建
// 入口（编译期符号已离线确认导出：InitializeProcess 0xc10f8 / Finalize
// Process 0xc1160 / ShInitialize 0xbf6e8），把运行时 slide 打进日志——
// 下轮任何 PC 都能离线对上 impl 符号表（73542 个符号）。
static void ame_log_impl_bases(void) {
    if (ame_shaderc_shim_real_dlsym == NULL || ame_shaderc_shim_impl == NULL)
        return;
    static const char *const kSyms[] = {
        "shaderc_compiler_initialize",
        "_ZN7glslang17InitializeProcessEv",
        "_ZN7glslang15FinalizeProcessEv",
    };
    for (size_t i = 0; i < sizeof(kSyms) / sizeof(kSyms[0]); ++i) {
        void *sym = ame_shaderc_shim_real_dlsym(ame_shaderc_shim_impl, kSyms[i]);
        Dl_info info;
        if (sym && dladdr(sym, &info) && info.dli_fbase) {
            fprintf(stderr,
                    "[shaderc-shim] impl base = %p (%s @ %p, image offset %#lx)\n",
                    info.dli_fbase, kSyms[i], sym,
                    (unsigned long)((uintptr_t)sym - (uintptr_t)info.dli_fbase));
        } else {
            fprintf(stderr, "[shaderc-shim] impl symbol %s -> %p (dladdr %s)\n",
                    kSyms[i], sym, (sym ? "resolved, base unknown" : "MISSING"));
        }
    }
}

// 每次调用惰性重试（构造期 dyld 环境尚未就绪等极端场景的兜底）
static void *ame_shaderc_shim_impl_handle(void) {
    if (ame_shaderc_shim_impl == NULL) ame_shaderc_shim_init();
    return ame_shaderc_shim_impl;
}

static void *ame_shaderc_shim_resolve(const char *sym) {
    void *impl = ame_shaderc_shim_impl_handle();
    return (impl != NULL && ame_shaderc_shim_real_dlsym != NULL)
               ? ame_shaderc_shim_real_dlsym(impl, sym)
               : NULL;
}

typedef void *(*ame_shaderc_shim_compile_fn_t)(void *compiler, const char *source,
                                               size_t source_size, int kind,
                                               const char *input_file,
                                               const char *entry_point, void *options);

// ---- Task 34：编译窗口崩溃恢复网（SIGSEGV/SIGBUS）——状态声明 ----
// （提前声明：Task 38 的重建函数也要罩网。处理器/install/restore 实现见下方。）
static __thread sigjmp_buf ame_compile_jmp;
static __thread volatile sig_atomic_t ame_in_compile = 0;
static __thread volatile sig_atomic_t ame_last_call_crashed = 0;
static struct sigaction ame_prev_segv;
static struct sigaction ame_prev_bus;
static int ame_net_installed = 0;

// ---- Task 38：编译器句柄间接层 + glslang 进程状态重建 ----
// 目的：双崩（重试必崩 = 确定性环境破坏）后，把 glslang 的进程级全局状态
// （内置符号表 / 字符串池 / 池分配器头——InitializeProcess 建立后跨编译存活）
// 整体拆掉重建，让毒化随 FinalizeProcess 一起释放。重建必须经由 shaderc
// 公开 ABI（compiler_release 在最后一个 compiler 时才调 FinalizeProcess、
// compiler_initialize 建立全新状态），因此 MC 持有的 java 侧句柄需要间接层：
//   java_handle（MC/LWJGL 持有，永不变）  ──映射──▶  live impl 句柄
// 重建时全部 live 句柄被释放、换成同一个新初始化的句柄；引用计数保证多个
// java 句柄共享一个 live 句柄时 release 语义正确（最后一个才真正 release）。
// 映射只在 ame_shaderc_shim_lock 内读写（initialize/release/compile 全部持
// 锁，无并发窗口）。
typedef struct {
    void *java_handle;
    void *live_handle; // NULL = 重建失败后的“已失效”标记
} ame_compiler_entry_t;
#define AME_COMPILER_MAP_MAX 32
static ame_compiler_entry_t ame_compiler_map[AME_COMPILER_MAP_MAX];
static int ame_compiler_map_count = 0;
static int ame_glslang_rebuilds = 0; // 预算：每进程最多 8 次（Task 44：5→8）
#define AME_GLSLANG_REBUILD_BUDGET 8

// 前置声明（重建函数定义在下方，compile 主链路要用）。
static void *ame_translate_compiler(void *java_handle);

// ---- Task 42：options 影子注册表 ----
// 目的：进程外沙箱编译需要 options 的字段值，但 options 是 impl 私有不透明
// 类型无法跨进程传递。本注册表在 shim 拦截的 initialize/clone/release/
// add_macro_definition/set_* 入口处把值镜像下来（编译请求携带快照，子进程
// 按快照重建）。注册表自带小锁（叶子锁，不参与 master 锁序）；options 本身
// 的并发语义维持 Task 30 结论不变（setter 不入 master 锁）。
typedef struct {
    void *options; // 键：MC/LWJGL 侧持有的 options 指针（malloc 可复用地址）
    ame_sb_opt_fields_t fields;
    int in_use;
    // Task 47：include 上行回调（LWJGL libffi closure，仅本进程有效——
    // 绝不进入 ame_sb_opt_fields_t，否则会被序列化传给沙箱子进程变成野指针）。
    void *inc_resolver;
    void *inc_releaser;
    void *inc_user_data;
} ame_opt_shadow_entry_t;
#define AME_OPT_SHADOW_MAX 64
static ame_opt_shadow_entry_t ame_opt_shadow[AME_OPT_SHADOW_MAX];
static pthread_mutex_t ame_opt_shadow_lock = PTHREAD_MUTEX_INITIALIZER;

static void ame_opt_shadow_defaults(ame_sb_opt_fields_t *f) {
    memset(f, 0, sizeof *f);
    // impl 的 shaderc_compile_options_initialize 默认值（shaderc.h 文档语义）
    f->target_env = 0;        // shaderc_target_env_vulkan
    f->target_env_version = 0;
    f->source_language = 0;   // shaderc_source_language_glsl
    f->optimization_level = 0;// shaderc_optimization_level_zero
    f->generate_debug = 0;
    f->has_forced = 0;
    f->macro_count = 0;
}

// 查找/创建（initialize 与地址复用场景共用）：找不到就开新槽（无空槽则忽略）
static ame_opt_shadow_entry_t *ame_opt_shadow_slot(void *options, int create) {
    ame_opt_shadow_entry_t *free_slot = NULL;
    for (int i = 0; i < AME_OPT_SHADOW_MAX; ++i) {
        if (ame_opt_shadow[i].in_use && ame_opt_shadow[i].options == options)
            return &ame_opt_shadow[i];
        if (!ame_opt_shadow[i].in_use && free_slot == NULL) free_slot = &ame_opt_shadow[i];
    }
    if (!create || free_slot == NULL) return NULL;
    free_slot->in_use = 1;
    free_slot->options = options;
    ame_opt_shadow_defaults(&free_slot->fields);
    free_slot->inc_resolver = NULL; // 地址复用防御：全新对象无 include 回调
    free_slot->inc_releaser = NULL;
    free_slot->inc_user_data = NULL;
    return free_slot;
}

static void ame_opt_shadow_register(void *options) {
    if (options == NULL) return;
    pthread_mutex_lock(&ame_opt_shadow_lock);
    // malloc 地址复用防御：同地址命中旧条目时【重置字段】（新 options 对象
    // 与旧对象共享地址但配置状态全新）；无条目则开新槽。
    // Task 54：旧条目分支必须同时清 inc_* 三指针 —— 旧主人（另一 worker
    // 线程）的 include 回调是可能已释放的 LWJGL libffi closure，继承即悬空
    // 指针；slot 创建分支（ame_opt_shadow_slot create=1）已清，此分支此前
    // 漏清。与 release 的锁内注销（Task 54 主修复）双保险。
    ame_opt_shadow_entry_t *e = ame_opt_shadow_slot(options, 0);
    if (e != NULL) {
        ame_opt_shadow_defaults(&e->fields);
        e->inc_resolver = NULL;
        e->inc_releaser = NULL;
        e->inc_user_data = NULL;
    } else {
        ame_opt_shadow_slot(options, 1);
    }
    pthread_mutex_unlock(&ame_opt_shadow_lock);
}

static void ame_opt_shadow_clone(const void *src, void *dst) {
    if (src == NULL || dst == NULL) return;
    pthread_mutex_lock(&ame_opt_shadow_lock);
    ame_opt_shadow_entry_t *e = ame_opt_shadow_slot((void *)src, 0);
    ame_opt_shadow_entry_t *n = ame_opt_shadow_slot(dst, 1);
    if (e != NULL && n != NULL) {
        n->fields = e->fields;
        // Task 54：真实 impl 的 options_clone 会复制 include 回调（回调是
        // options 结构体的值成员）——影子层镜像同一语义，否则 clone 出的
        // options 编译含 #include 的源码会误入无回调直通路径。
        n->inc_resolver = e->inc_resolver;
        n->inc_releaser = e->inc_releaser;
        n->inc_user_data = e->inc_user_data;
    }
    pthread_mutex_unlock(&ame_opt_shadow_lock);
}

static void ame_opt_shadow_release(void *options) {
    if (options == NULL) return;
    pthread_mutex_lock(&ame_opt_shadow_lock);
    for (int i = 0; i < AME_OPT_SHADOW_MAX; ++i) {
        if (ame_opt_shadow[i].in_use && ame_opt_shadow[i].options == options) {
            ame_opt_shadow[i].in_use = 0;
            ame_opt_shadow[i].options = NULL;
        }
    }
    pthread_mutex_unlock(&ame_opt_shadow_lock);
}

static void ame_opt_shadow_fill(const void *options, ame_sb_opt_fields_t *out) {
    ame_opt_shadow_defaults(out);
    if (options == NULL) return;
    pthread_mutex_lock(&ame_opt_shadow_lock);
    ame_opt_shadow_entry_t *e = ame_opt_shadow_slot((void *)options, 0);
    if (e != NULL) *out = e->fields;
    pthread_mutex_unlock(&ame_opt_shadow_lock);
}

// setter 写入（fields 更新 + 可选宏追加）；全部走注册表小锁。
static void ame_opt_shadow_set_env(void *options, int env, unsigned version) {
    pthread_mutex_lock(&ame_opt_shadow_lock);
    ame_opt_shadow_entry_t *e = ame_opt_shadow_slot(options, 1);
    if (e != NULL) {
        e->fields.target_env = env;
        e->fields.target_env_version = version;
    }
    pthread_mutex_unlock(&ame_opt_shadow_lock);
}
static void ame_opt_shadow_set_int(void *options, int which, int value) {
    pthread_mutex_lock(&ame_opt_shadow_lock);
    ame_opt_shadow_entry_t *e = ame_opt_shadow_slot(options, 1);
    if (e != NULL) {
        switch (which) {
            case 0: e->fields.source_language = value; break;
            case 1: e->fields.optimization_level = value; break;
            case 2: e->fields.generate_debug = value; break;
        }
    }
    pthread_mutex_unlock(&ame_opt_shadow_lock);
}
static void ame_opt_shadow_set_vp(void *options, int version, int profile) {
    pthread_mutex_lock(&ame_opt_shadow_lock);
    ame_opt_shadow_entry_t *e = ame_opt_shadow_slot(options, 1);
    if (e != NULL) {
        e->fields.has_forced = 1;
        e->fields.forced_version = version;
        e->fields.forced_profile = profile;
    }
    pthread_mutex_unlock(&ame_opt_shadow_lock);
}
static void ame_opt_shadow_macro(void *options, const char *name, size_t name_len,
                                 const char *value, size_t value_len) {
    if (options == NULL || name == NULL || name_len == 0) return;
    pthread_mutex_lock(&ame_opt_shadow_lock);
    ame_opt_shadow_entry_t *e = ame_opt_shadow_slot(options, 1);
    if (e != NULL && e->fields.macro_count < AME_SB_MAX_MACROS) {
        int idx = e->fields.macro_count++;
        size_t n = name_len < AME_SB_MACRO_NAME_MAX - 1 ? name_len : AME_SB_MACRO_NAME_MAX - 1;
        memcpy(e->fields.macro_name[idx], name, n);
        e->fields.macro_name[idx][n] = '\0';
        if (value != NULL && value_len > 0) {
            size_t v = value_len < AME_SB_MACRO_VALUE_MAX - 1 ? value_len
                                                              : AME_SB_MACRO_VALUE_MAX - 1;
            memcpy(e->fields.macro_value[idx], value, v);
            e->fields.macro_value[idx][v] = '\0';
            e->fields.macro_has_value[idx] = 1;
        } else {
            e->fields.macro_has_value[idx] = 0;
        }
    }
    pthread_mutex_unlock(&ame_opt_shadow_lock);
}

// 注册：initialize 返回的句柄进表（恒等映射初始）。容量溢出时退化为直通
// 并打一次性告警（重建不覆盖该句柄，安全降级）。
static void *ame_register_compiler(void *java_handle) {
    if (java_handle == NULL) return NULL;
    if (ame_compiler_map_count < AME_COMPILER_MAP_MAX) {
        ame_compiler_map[ame_compiler_map_count].java_handle = java_handle;
        ame_compiler_map[ame_compiler_map_count].live_handle = java_handle;
        ame_compiler_map_count++;
    } else {
        static bool s_overflow_warned = false;
        if (!s_overflow_warned) {
            s_overflow_warned = true;
            fprintf(stderr,
                    "[shaderc-shim] compiler map overflow (%d) -- handles beyond "
                    "this point bypass rebuild indirection\n",
                    AME_COMPILER_MAP_MAX);
        }
    }
    return java_handle;
}

// 引用计数释放：同一 live 句柄被 N 个 java 句柄引用时，只有最后一个 release
// 真正下到 impl（避免共享 live 句柄双重释放）。live==NULL（已失效）直接跳过。
static void ame_unregister_compiler(void *java_handle) {
    int idx = -1;
    for (int i = 0; i < ame_compiler_map_count; ++i) {
        if (ame_compiler_map[i].java_handle == java_handle) {
            idx = i;
            break;
        }
    }
    if (idx < 0) return; // 溢出表外的句柄：直通路径，由调用方自行处理
    void *live = ame_compiler_map[idx].live_handle;
    // 删除表项（swap with last）
    ame_compiler_map[idx] = ame_compiler_map[ame_compiler_map_count - 1];
    ame_compiler_map_count--;
    if (live == NULL) return;
    // 还有别的 java 句柄共享这个 live？
    for (int i = 0; i < ame_compiler_map_count; ++i) {
        if (ame_compiler_map[i].live_handle == live) return;
    }
    void *real = ame_shaderc_shim_resolve("shaderc_compiler_release");
    if (real != NULL) ((void (*)(void *))real)(live);
}

// 查表：java → live。不在表内（溢出/异常）返回原句柄并一次性告警。
static void *ame_translate_compiler(void *java_handle) {
    if (java_handle == NULL) return NULL;
    for (int i = 0; i < ame_compiler_map_count; ++i) {
        if (ame_compiler_map[i].java_handle == java_handle) {
            return ame_compiler_map[i].live_handle;
        }
    }
    return java_handle; // 直通（表外句柄）
}

// glslang 进程状态重建：释放全部 live 句柄（最后一次 release 触发
// glslang::FinalizeProcess 拆全局状态）→ 重新 initialize → 全表重映射。
// 成功返回新的 live 句柄；失败返回 NULL（表项 live 置 NULL，后续编译走
// 合成失败，release 走空操作，进程存活）。
// 重建自身也罩在崩溃网内：release/init 在毒化状态上崩 → longjmp 回来 →
// 全部句柄失效（安全降级），绝不把崩溃漏给 JVM 处理器。
// 调用方必须已持锁（递归）。
static void *ame_glslang_rebuild(void) {
    void *rel = ame_shaderc_shim_resolve("shaderc_compiler_release");
    void *init = ame_shaderc_shim_resolve("shaderc_compiler_initialize");
    if (rel == NULL || init == NULL) {
        fprintf(stderr, "[shaderc-shim] rebuild unavailable (ABI symbols missing)\n");
        return NULL;
    }
    ame_last_call_crashed = 0;
    ame_in_compile = 1;
    void *fresh = NULL;
    if (sigsetjmp(ame_compile_jmp, 1) == 0) {
        // 逐个去重释放 live 句柄（共享 live 只释放一次）
        for (int i = 0; i < ame_compiler_map_count; ++i) {
            void *live = ame_compiler_map[i].live_handle;
            if (live == NULL) continue;
            for (int j = 0; j < i; ++j) {
                if (ame_compiler_map[j].live_handle == live) {
                    live = NULL;
                    break;
                }
            }
            if (live != NULL) ((void (*)(void *))rel)(live);
        }
        fresh = ((void *(*)(void))init)();
    } else {
        // 重建途中崩溃：句柄全部失效（live 已释放的不能再碰；未释放的保守
        // 一并失效），编译走合成失败，进程存活。
        fprintf(stderr,
                "[shaderc-shim] rebuild itself CRASHED -- invalidating all mapped "
                "handles (synthetic failure path, process alive)\n");
        fresh = NULL;
        for (int i = 0; i < ame_compiler_map_count; ++i) {
            ame_compiler_map[i].live_handle = NULL;
        }
        ame_last_call_crashed = 1;
    }
    ame_in_compile = 0;
    fprintf(stderr,
            "[shaderc-shim] glslang process state rebuilt (fresh compiler %p, "
            "remapped %d handles, rebuilds used %d/%d)%s\n",
            fresh, ame_compiler_map_count, ame_glslang_rebuilds,
            AME_GLSLANG_REBUILD_BUDGET, (fresh != NULL) ? "" : " [DEGRADED]");
    if (fresh != NULL) {
        for (int i = 0; i < ame_compiler_map_count; ++i) {
            ame_compiler_map[i].live_handle = fresh;
        }
    }
    return fresh;
}

// ---- Task 34：编译窗口崩溃恢复网（SIGSEGV/SIGBUS）——实现 ----
// 状态全部线程局部（编译串行，但同时只有一个编译线程带网运行）；
// 旧的 sigaction 快照是进程级的，只在持锁的 install/restore 窗口内读写。
static void ame_compile_crash_handler(int sig, siginfo_t *si, void *ctx) {
    if (ame_in_compile) {
        ame_in_compile = 0;
        // Task 37：崩溃 PC/LR 取证（arm64 ucontext）——离线对着 impl 符号表
        // symbolicate 即可定位崩溃函数（lValueErrorCheck 家族或新脆弱点）。
        uint64_t pc = 0, lr = 0;
#if defined(__aarch64__)
        if (ctx != NULL) {
            ucontext_t *uc = (ucontext_t *)ctx;
            pc = (uint64_t)uc->uc_mcontext->__ss.__pc;
            lr = (uint64_t)uc->uc_mcontext->__ss.__lr;
        }
#endif
        // Task 38：dladdr 就地 symbolicate。dladdr 对已加载镜像走闭环链表、
        // 不加锁，信号上下文可用（本垫片在崩溃网内本就 fprintf+siglongjmp）。
        // 直接打印镜像名/符号名/偏移，下轮日志无需离线推 slide。
        const char *pc_img = "?", *pc_sym = "?";
        uintptr_t pc_img_off = 0, pc_sym_off = 0;
        const char *lr_img = "?", *lr_sym = "?";
        uintptr_t lr_img_off = 0;
        Dl_info info;
        if (pc && dladdr((void *)(uintptr_t)pc, &info)) {
            pc_img = info.dli_fname ? info.dli_fname : "?";
            pc_sym = info.dli_sname ? info.dli_sname : "(no symbol)";
            pc_img_off = (uintptr_t)pc - (uintptr_t)info.dli_fbase;
            pc_sym_off = info.dli_saddr ? (uintptr_t)pc - (uintptr_t)info.dli_saddr : 0;
        }
        if (lr && dladdr((void *)(uintptr_t)lr, &info)) {
            lr_img = info.dli_fname ? info.dli_fname : "?";
            lr_sym = info.dli_sname ? info.dli_sname : "(no symbol)";
            lr_img_off = (uintptr_t)lr - (uintptr_t)info.dli_fbase;
        }
        // 阻断本信号，防止 longjmp 展开过程中同一错误页立即重触发
        sigset_t set;
        sigemptyset(&set);
        sigaddset(&set, sig);
        sigprocmask(SIG_BLOCK, &set, NULL);
        fprintf(stderr,
                "[shaderc-shim] compile CRASHED (sig=%d si_addr=%p pc=%p lr=%p "
                "tid=%lx t=%.0fms) -- recovered via longjmp\n",
                sig, si ? si->si_addr : NULL, (void *)pc, (void *)lr,
                ame_shim_tid(), ame_shim_ms());
        if (pc) {
            fprintf(stderr,
                    "[shaderc-shim] crash site: pc in %s + %#lx (%s + %#lx); "
                    "lr in %s + %#lx (%s)\n",
                    pc_img, (unsigned long)pc_img_off, pc_sym,
                    (unsigned long)pc_sym_off, lr_img, (unsigned long)lr_img_off,
                    lr_sym);
        }
        siglongjmp(ame_compile_jmp, 1);
    }
    // 非编译线程（或非编译窗口）：链回先前安装的处理器（通常是 JVM 的，
    // 走 hs_err 报告路径），保持进程其它部分的崩溃语义不变。
    struct sigaction prev = (sig == SIGBUS) ? ame_prev_bus : ame_prev_segv;
    if (prev.sa_flags & SA_SIGINFO) {
        prev.sa_sigaction(sig, si, ctx);
    } else if (prev.sa_handler == SIG_DFL) {
        // 恢复默认处置并返回；出错指令重执行时内核套用默认动作。
        signal(sig, SIG_DFL);
    } else if (prev.sa_handler == SIG_IGN) {
        /* 忽略 */
    } else {
        prev.sa_handler(sig);
    }
}

// 仅在持有 ame_shaderc_shim_lock 时调用（编译串行化保证单线程 install/restore）。
static void ame_crash_net_install(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = ame_compile_crash_handler;
    // Task 44：去掉 SA_ONSTACK——本垫片从未配置 sigaltstack，此前依赖
    // “无备用栈时内核回退当前栈”的未定义行为；编译线程本身已是 32MB 栈，
    // 信号帧绰绰有余。
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSEGV, &sa, &ame_prev_segv) != 0) return;
    if (sigaction(SIGBUS, &sa, &ame_prev_bus) != 0) {
        sigaction(SIGSEGV, &ame_prev_segv, NULL);
        return;
    }
    ame_net_installed = 1;
}

static void ame_crash_net_restore(void) {
    if (!ame_net_installed) return;
    sigaction(SIGSEGV, &ame_prev_segv, NULL);
    sigaction(SIGBUS, &ame_prev_bus, NULL);
    ame_net_installed = 0;
}

// 带网调用真实编译；崩溃恢复后置 ame_last_call_crashed 并返回 NULL。
static void *ame_call_real_guarded(ame_shaderc_shim_compile_fn_t fn, void *compiler,
                                   const char *source, size_t source_size, int kind,
                                   const char *input_file, const char *entry_point,
                                   void *options) {
    ame_last_call_crashed = 0;
    ame_in_compile = 1;
    if (sigsetjmp(ame_compile_jmp, 1) == 0) {
        return fn(compiler, source, source_size, kind, input_file, entry_point, options);
    }
    ame_last_call_crashed = 1;
    return NULL;
}

// ---- Task 44：重试尝试上新鲜线程 ----
// 证据（见文件头 Task 44 判读）：longjmp 跳过 impl 的 C++ 析构后，本线程
// TLS 上的 glslang 池/解析状态残留，同线程重试必然落回同一片毒化内存；
// glslang 进程级重建也救不回（重建后同线程第三搏照崩）。每次尝试都给
// virgin TLS + 全新 32MB 栈 + 独立分配序列，把“重试落回同一片回收内存”
// 的确定性打散；恢复一次即入 Task 43 磁盘缓存，跨启动单调固化。
// 持锁调用（编译串行化保证同一时刻只有一个尝试线程）。返回 result；
// *crashed_out 带回该次尝试是否崩溃（__thread 标志在尝试线程上，须經
// job 结构侧信道传回本线程）。
typedef struct {
    ame_shaderc_shim_compile_fn_t fn;
    void *compiler;
    const char *source;
    size_t source_size;
    int kind;
    const char *input_file;
    const char *entry_point;
    void *options;
    void *result;
    int crashed;
} ame_fresh_attempt_t;

static void *ame_fresh_attempt_main(void *arg) {
    ame_fresh_attempt_t *job = (ame_fresh_attempt_t *)arg;
    job->result = ame_call_real_guarded(job->fn, job->compiler, job->source,
                                        job->source_size, job->kind, job->input_file,
                                        job->entry_point, job->options);
    job->crashed = ame_last_call_crashed; // __thread：尝试线程上取回
    return NULL;
}

static void *ame_attempt_on_fresh_thread(ame_shaderc_shim_compile_fn_t fn, void *compiler,
                                         const char *source, size_t source_size, int kind,
                                         const char *input_file, const char *entry_point,
                                         void *options, int *crashed_out) {
    ame_fresh_attempt_t job = {fn, compiler, source, source_size, kind,
                               input_file, entry_point, options, NULL, 0};
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 32ull * 1024ull * 1024ull);
    pthread_t tid;
    int rc = pthread_create(&tid, &attr, ame_fresh_attempt_main, &job);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        // 极端退化：当前线程直跑（与旧版行为一致）
        void *r = ame_call_real_guarded(fn, compiler, source, source_size, kind,
                                        input_file, entry_point, options);
        if (crashed_out) *crashed_out = ame_last_call_crashed;
        return r;
    }
    pthread_join(tid, NULL);
    if (crashed_out) *crashed_out = job.crashed;
    return job.result;
}

// Task 37 前置声明：合成失败 result（定义见下方 result 访问器族）。
static void *ame_fake_result_create(int seq);

// Task 47：cleanup attribute 辅助——编译函数多出口（缓存命中/沙箱/进程
// 内/合成失败）统一释放展开 buffer，杜绝泄漏。
static void ame_ptr_cleanup_generic(void *p) {
    void **slot = (void **)p;
    if (slot != NULL && *slot != NULL) {
        free(*slot);
        *slot = NULL;
    }
}

static void *ame_shaderc_shim_compile(const char *sym, void *compiler,
                                      const char *source, size_t source_size,
                                      int kind, const char *input_file,
                                      const char *entry_point, void *options) {
    void *real = ame_shaderc_shim_resolve(sym);
    if (real == NULL) {
        fprintf(stderr, "[shaderc-shim] %s unresolved (%s) -- returning NULL\n", sym,
                (ame_shaderc_shim_impl == NULL) ? "impl missing" : "symbol missing");
        return NULL;
    }
    pthread_mutex_lock(&ame_shaderc_shim_lock);
    // Task 39：编译入口心跳（本函数直取锁，不经 lock_or_report_blocked）。
    ame_note_compile_activity();
    // Task 38：句柄间接层翻译（锁内读表，避免与 initialize/release 的表操作
    // 竞争；重建后 java 句柄指向新 live 句柄）。
    void *live_compiler = ame_translate_compiler(compiler);
    if (live_compiler == NULL) {
        // 重建失败后的已失效句柄：不再进 impl，直接合成失败。
        pthread_mutex_unlock(&ame_shaderc_shim_lock);
        fprintf(stderr,
                "[shaderc-shim] compile on invalidated compiler %p -- synthetic "
                "failure\n",
                compiler);
        return ame_fake_result_create(0);
    }
    // 逐编译取证（Task 30）：编译序号 + compiler/options 指针 + kind + 长度 +
    // 文件名。下轮崩溃日志可直接对照：第几次编译、compiler 是否在重载后换新、
    // options 指针是否曾被 options_release 日志指认。
    static int s_compile_seq = 0;
    // Task 44 风暴统计：总量/命中/失败/新鲜线程恢复计数（每 100 次汇总）。
    static int s_storm_total = 0, s_storm_hits = 0, s_storm_fails = 0;
    static int s_storm_fresh_recovered = 0;
    static int s_storm_tip_printed = 0;
    int seq = ++s_compile_seq;
    s_storm_total++;
    fprintf(stderr,
            "[shaderc-shim] compile#%d t=%.0fms tid=%lx kind=%d len=%zu comp=%p "
            "opt=%p in='%.48s'\n",
            seq, ame_shim_ms(), ame_shim_tid(), kind, source_size, compiler, options,
            input_file ? input_file : "(null)");
    // Task 47：RenderPearl 26.3 的 `#include <minecraft:...>` 在此展开。
    // 展开必须在调用者线程（= LWJGL/ForkJoin JVM 线程）同步进行：resolver
    // 是 LWJGL libffi upcall，线程安全。展开后的干净源码统一进入下方缓存
    // key / 源码 dump / 沙箱 / 进程内全部下游——沙箱子进程因此无需任何
    // 回调即可编译含 include 的管线（函数指针不可跨进程，这是沙箱路径唯一
    // 可行的 include 支持方式）。展开失败（溢出/深度）保留原始行，下游
    // glslang 会给出与今日一致的可见诊断，绝不静默吞错。
    size_t ame_orig_source_size = source_size;
    char *ame_expanded_local __attribute__((
        cleanup(ame_ptr_cleanup_generic))) = NULL;
    if (source_size > 0 && ame_source_has_include(source, source_size)) {
        ame_include_resolver_fn inc_resolver = NULL;
        ame_include_releaser_fn inc_releaser = NULL;
        void *inc_ud = NULL;
        {
            pthread_mutex_lock(&ame_opt_shadow_lock);
            ame_opt_shadow_entry_t *e = ame_opt_shadow_slot(options, 0);
            if (e != NULL) {
                inc_resolver = (ame_include_resolver_fn)e->inc_resolver;
                inc_releaser = (ame_include_releaser_fn)e->inc_releaser;
                inc_ud = e->inc_user_data;
            }
            pthread_mutex_unlock(&ame_opt_shadow_lock);
        }
        if (inc_resolver != NULL) {
            ame_expanded_local = ame_include_expand(
                source, source_size, input_file, inc_resolver, inc_ud,
                inc_releaser, inc_ud, &source_size);
            if (ame_expanded_local != NULL) {
                source = ame_expanded_local;
                fprintf(stderr,
                        "[shaderc-shim] compile#%d #include expanded: %zu -> %zu "
                        "bytes (resolver=%p)\n",
                        seq, ame_orig_source_size, source_size, (void *)inc_resolver);
            }
        } else {
            fprintf(stderr,
                    "[shaderc-shim] compile#%d source contains #include but no "
                    "include callbacks registered (opt=%p) -- passing through; impl "
                    "will report 'extension not requested'\n",
                    seq, options);
        }
    }
    // Task 43：磁盘缓存优先于一切编译路径（命中 = 毫秒级返回 + 零 glslang
    // 暴露 + 零崩溃窗口）。key 覆盖 entry/kind/源码/输入名/入口名/options
    // 全字段——MC 版本或管线配置变化自动失效。
    ame_sb_opt_fields_t fields;
    ame_opt_shadow_fill(options, &fields);
    int sb_entry = strcmp(sym, "shaderc_compile_into_spv_assembly") == 0    ? 1
                   : strcmp(sym, "shaderc_compile_into_preprocessed_text") == 0 ? 2
                                                                                : 0;
    uint64_t cache_key = ame_cache_key(sb_entry, kind, source, source_size, input_file,
                                       entry_point, &fields);
    void *cache_hit = ame_cache_lookup(cache_key);
    if (cache_hit != NULL) {
        ame_sb_result_t *r = (ame_sb_result_t *)cache_hit;
        fprintf(stderr,
                "[shaderc-cache] compile#%d HIT key=%016llx spv=%uB (t=%.0fms)\n",
                seq, (unsigned long long)cache_key, r->spv_len, ame_shim_ms());
        ame_note_compile_activity(); // 命中也算编译活动（首帧门控语义不变）
        s_storm_hits++;
        pthread_mutex_unlock(&ame_shaderc_shim_lock);
        return cache_hit;
    }
    // Task 44：miss 即转储精确输入（离线预编译/跨渲染器播种取证）。
    ame_cache_dump_source(cache_key, sb_entry, kind, source, source_size, input_file,
                          entry_point, &fields);
    // Task 42：进程外沙箱编译（首选项）。41 个 task 的取证已证明进程内堆踩踏
    // 锁不可防（主锁/门控/重建均不愈），唯一根治 = 编译离开 JVM 进程。沙箱
    // 返回的 ame_sb_result_t 携带真实 status/SPIR-V/错误文本——成功编译与
    // 编译失败都与 impl 语义一致；沙箱传输双重失败（返回 NULL）才落回下方
    // 进程内旧链路（崩溃网 + 重试 + 重建 + 合成失败，行为不劣于 Task 38）。
    // 心跳在出口照常更新——Task 39 首帧门控的静止窗口仍以编译结束起算。
    // Task 43：成功结果（status==0 且有字节）就地落盘缓存。
    if (ame_sandbox_active()) {
        double t0 = ame_shim_ms();
        void *sb = ame_sandbox_compile(sb_entry, source, source_size, kind, input_file,
                                       entry_point, &fields);
        if (sb != NULL) {
            ame_sb_result_t *r = (ame_sb_result_t *)sb;
            fprintf(stderr,
                    "[shaderc-sandbox] compile#%d -> status=%d spv=%uB err=%uB (rt=%.0fms)\n",
                    seq, r->status, r->spv_len, r->err_len, ame_shim_ms() - t0);
            if (r->status == 0 && r->spv_len > 0) {
                ame_cache_store(cache_key, ame_sb_result_spv(r), r->spv_len);
            }
            ame_note_compile_activity();
            pthread_mutex_unlock(&ame_shaderc_shim_lock);
            return sb;
        }
        fprintf(stderr,
                "[shaderc-sandbox] compile#%d sandbox unavailable -- falling back to "
                "in-process impl (legacy path)\n",
                seq);
    }
    // Task 34：崩溃恢复网罩住真实调用；首次崩溃→重试一次（新鲜解析树，
    // 堆踩踏通常是瞬态的）；重试再崩→Task 38：glslang 进程状态重建后
    // 最后一搏；仍崩→返回合成失败 result（Task 37：绝不能返回 NULL——
    // LWJGL Checks.check 对 NULL 抛 NPE，真机 CompletionException 的直接死因）；
    // 诊断链不丢失。
    ame_crash_net_install();
    void *result = ame_call_real_guarded((ame_shaderc_shim_compile_fn_t)real, live_compiler,
                                         source, source_size, kind, input_file,
                                         entry_point, options);
    // Task 44：首后所有尝试换新鲜线程（见上方 ame_attempt_on_fresh_thread）；
    // crashed 标志經 job 结构侧信道传递（__thread 在尝试线程上）。
    int attempt_crashed = ame_last_call_crashed;
    if (attempt_crashed) {
        fprintf(stderr,
                "[shaderc-shim] compile#%d crashed on first attempt -- retrying on a "
                "FRESH THREAD (virgin TLS + 32MB stack, Task 44)\n",
                seq);
        result = ame_attempt_on_fresh_thread((ame_shaderc_shim_compile_fn_t)real,
                                             live_compiler, source, source_size, kind,
                                             input_file, entry_point, options,
                                             &attempt_crashed);
        if (!attempt_crashed && result != NULL) {
            s_storm_fresh_recovered++;
            fprintf(stderr,
                    "[shaderc-shim] compile#%d RECOVERED on fresh-thread retry "
                    "(Task 44) -- result enters disk cache\n",
                    seq);
        }
        if (attempt_crashed && ame_glslang_rebuilds < AME_GLSLANG_REBUILD_BUDGET) {
            // Task 38 自愈：双崩 = 确定性毒化。拆掉 glslang 全局状态重建后
            // 再试一次（毒化若在持久符号表/字符串池中则痊愈）；Task 44：
            // 第三搏也上新鲜线程（重建后同线程照崩的实证见文件头）。
            ame_glslang_rebuilds++;
            fprintf(stderr,
                    "[shaderc-shim] compile#%d crashed on RETRY too -- rebuilding "
                    "glslang process state (attempt %d/%d)\n",
                    seq, ame_glslang_rebuilds, AME_GLSLANG_REBUILD_BUDGET);
            void *rebuilt = ame_glslang_rebuild();
            if (rebuilt != NULL) {
                live_compiler = rebuilt;
                result = ame_attempt_on_fresh_thread(
                    (ame_shaderc_shim_compile_fn_t)real, live_compiler, source,
                    source_size, kind, input_file, entry_point, options,
                    &attempt_crashed);
                if (!attempt_crashed && result != NULL) {
                    s_storm_fresh_recovered++;
                    fprintf(stderr,
                            "[shaderc-shim] compile#%d RECOVERED via glslang "
                            "process-state rebuild + fresh thread (Task 44)\n",
                            seq);
                }
            }
        }
        if (attempt_crashed) {
            fprintf(stderr,
                    "[shaderc-shim] compile#%d crashed on RETRY too -- giving up, "
                    "returning synthetic failure result (compilation will be "
                    "reported failed, no NULL to LWJGL)\n",
                    seq);
            // Task 37：合成 fake result（status=internal_error + 取证消息）。
            result = ame_fake_result_create(seq);
            // Task 44：风暴统计 + 跨渲染器播种指引（只打一次，避免刷屏）。
            s_storm_fails++;
            if (!s_storm_tip_printed) {
                s_storm_tip_printed = 1;
                fprintf(stderr,
                        "[shaderc-cache] TIP: this run uses the from-source "
                        "glslang impl (Task 45); the disk cache still shortens "
                        "every later launch -- successful compiles accumulate "
                        "across runs automatically\n");
            }
            if (s_storm_total % 100 == 0) {
                fprintf(stderr,
                        "[shaderc-cache] storm: %d compiles, %d hits, %d failures, "
                        "%d fresh-thread recoveries\n",
                        s_storm_total, s_storm_hits, s_storm_fails,
                        s_storm_fresh_recovered);
            }
        }
    }
    // Task 38 兜底护栏：任何未崩溃却返回 NULL 的路径（理论上不应存在，但
    // 重建重试后的内部状态未知）一律换合成失败——LWJGL Checks.check 对 NULL
    // 抛 NPE，绝不能把 NULL 交出去。
    if (result == NULL) {
        result = ame_fake_result_create(seq);
    }
    // Task 43：进程内成功编译也落缓存——沙箱被沙盒拒绝的最坏情况下，每次
    // run 崩溃前的"幸运编译"跨启动固化，缓存命中率逐次上升直至全命中。
    // 访问器走本文件自己的拦截链（fake/sb/真实对象三分支；均无锁、
    // 只读），在持 master 锁状态下调用无死锁风险。
    if (!ame_is_fake_result(result)) {
        if (shaderc_result_get_compilation_status(result) == 0) {
            size_t blen = (sb_entry == 0) ? shaderc_result_get_spv_length(result)
                                          : shaderc_result_get_length(result);
            if (blen > 0 && blen < AME_CACHE_MAX_BLOB) {
                const char *bptr = (sb_entry == 0)
                                       ? shaderc_result_get_spv_bytes(result)
                                       : shaderc_result_get_bytes(result);
                if (bptr != NULL) {
                    ame_cache_store(cache_key, bptr, (uint32_t)blen);
                }
            }
        }
    }
    ame_in_compile = 0;
    ame_crash_net_restore();
    // Task 39：编译出口心跳 —— 风暴静止窗口从最后一次编译结束起算。
    ame_note_compile_activity();
    pthread_mutex_unlock(&ame_shaderc_shim_lock);
    return result;
}

// ---- Task 37：合成失败 result（防 NULL → NPE） ----
// 双崩后 MC/LWJGL 需要一个非 NULL 的 shaderc_compilation_result_t；本层
// 用 malloc 的 fake 对象（magic 头识别）+ 拦截的 result 访问器族共同实现。
// malloc 失败的兑底静态件用低位翻转的 magic 标记（release 跳过 free）。
// 访问器转发真实对象时不加锁：result 为调用线程独占的个体堆对象，不存在
// release-vs-compile 的全局状态竞态（Task 30 已证明危险面在 options/compiler）。
typedef struct {
    uint64_t magic;   // AME_FAKE_RESULT_MAGIC / _STATIC
    int seq;          // 崩溃的编译序号（取证）
    char message[96]; // 固定错误消息（含序号）
} ame_fake_result_t;

#define AME_FAKE_RESULT_MAGIC        0x5A17EFA2E51DULL
#define AME_FAKE_RESULT_MAGIC_STATIC (0x5A17EFA2E51DULL ^ 1ull)

static int ame_is_fake_result(const void *result) {
    if (result == NULL) return 0;
    uint64_t m = *(const uint64_t *)result;
    return m == AME_FAKE_RESULT_MAGIC || m == AME_FAKE_RESULT_MAGIC_STATIC;
}

// Task 42：沙箱结果识别（ame_sb_result_t，见 shaderc_sandbox.h）
static int ame_is_sb_result(const void *result) {
    if (result == NULL) return 0;
    return *(const uint64_t *)result == AME_SB_RESULT_MAGIC;
}

static void ame_fake_result_fill(ame_fake_result_t *fr, uint64_t magic, int seq) {
    fr->magic = magic;
    fr->seq = seq;
    snprintf(fr->message, sizeof(fr->message),
             "[amethyst] shaderc compile #%d crashed twice (shim recovery)", seq);
}

static void *ame_fake_result_create(int seq) {
    ame_fake_result_t *fr = (ame_fake_result_t *)malloc(sizeof(ame_fake_result_t));
    if (fr != NULL) {
        ame_fake_result_fill(fr, AME_FAKE_RESULT_MAGIC, seq);
        return fr;
    }
    // malloc 失败的极端场景：静态兑底件（magic 低位翻转，release 识别跳过 free）。
    static ame_fake_result_t s_static_fake;
    ame_fake_result_fill(&s_static_fake, AME_FAKE_RESULT_MAGIC_STATIC, seq);
    return &s_static_fake;
}

// ---- result 访问器族：fake → 合成值；真实对象 → 转发 impl ----
// （拿不到 impl 符号时返回安全值，绝不把 NULL 指针交给 impl 解引用）。
// shaderc_compilation_status 枚举： success=0 / invalid_stage=1 /
// compilation_error=2 / internal_error=3 —— fake 报 3。

void shaderc_result_release(void *result) {
    if (ame_is_fake_result(result)) {
        if (*(uint64_t *)result == AME_FAKE_RESULT_MAGIC) free(result);
        return;
    }
    if (ame_is_sb_result(result)) { // Task 42：沙箱结果直接 free（spv/err 内嵌）
        free(result);
        return;
    }
    void *real = ame_shaderc_shim_resolve("shaderc_result_release");
    if (real == NULL || result == NULL) return;
    ((void (*)(void *))real)(result);
}

int shaderc_result_get_compilation_status(void *result) {
    if (ame_is_fake_result(result)) return 3; // shaderc_compilation_status_internal_error
    if (ame_is_sb_result(result))
        return ((const ame_sb_result_t *)result)->status; // Task 42
    void *real = ame_shaderc_shim_resolve("shaderc_result_get_compilation_status");
    if (real == NULL || result == NULL) return 3;
    return ((int (*)(void *))real)(result);
}

size_t shaderc_result_get_num_errors(void *result) {
    if (ame_is_fake_result(result)) return 1;
    if (ame_is_sb_result(result))
        return (((const ame_sb_result_t *)result)->status != 0) ? 1 : 0; // Task 42
    void *real = ame_shaderc_shim_resolve("shaderc_result_get_num_errors");
    if (real == NULL || result == NULL) return 0;
    return ((size_t (*)(void *))real)(result);
}

size_t shaderc_result_get_num_warnings(void *result) {
    if (ame_is_fake_result(result)) return 0;
    void *real = ame_shaderc_shim_resolve("shaderc_result_get_num_warnings");
    if (real == NULL || result == NULL) return 0;
    return ((size_t (*)(void *))real)(result);
}

const char *shaderc_result_get_error_message(void *result) {
    if (ame_is_fake_result(result))
        return ((ame_fake_result_t *)result)->message;
    if (ame_is_sb_result(result))
        return ame_sb_result_err((const ame_sb_result_t *)result); // Task 42
    void *real = ame_shaderc_shim_resolve("shaderc_result_get_error_message");
    if (real == NULL || result == NULL) return "(shim: result missing)";
    return ((const char *(*)(void *))real)(result);
}

const char *shaderc_result_get_bytes(void *result) {
    if (ame_is_fake_result(result)) return "";
    if (ame_is_sb_result(result))
        return ame_sb_result_spv((const ame_sb_result_t *)result); // Task 42
    void *real = ame_shaderc_shim_resolve("shaderc_result_get_bytes");
    if (real == NULL || result == NULL) return "";
    return ((const char *(*)(void *))real)(result);
}

size_t shaderc_result_get_length(void *result) {
    if (ame_is_fake_result(result)) return 0;
    if (ame_is_sb_result(result))
        return ((const ame_sb_result_t *)result)->spv_len; // Task 42
    void *real = ame_shaderc_shim_resolve("shaderc_result_get_length");
    if (real == NULL || result == NULL) return 0;
    return ((size_t (*)(void *))real)(result);
}

const char *shaderc_result_get_spv_bytes(void *result) {
    if (ame_is_fake_result(result)) return "";
    if (ame_is_sb_result(result))
        return ame_sb_result_spv((const ame_sb_result_t *)result); // Task 42
    void *real = ame_shaderc_shim_resolve("shaderc_result_get_spv_bytes");
    if (real == NULL || result == NULL) return "";
    return ((const char *(*)(void *))real)(result);
}

size_t shaderc_result_get_spv_length(void *result) {
    if (ame_is_fake_result(result)) return 0;
    if (ame_is_sb_result(result))
        return ((const ame_sb_result_t *)result)->spv_len; // Task 42
    void *real = ame_shaderc_shim_resolve("shaderc_result_get_spv_length");
    if (real == NULL || result == NULL) return 0;
    return ((size_t (*)(void *))real)(result);
}

// ---- 生命周期入口（Task 30）：与编译共用同一把锁，关闭 release-vs-compile
// 竞态窗口，见文件头注释。签名与 shaderc.h 公开 ABI 一致（不透明指针以 void*
// 承载，不透明结构句柄在 arm64 上均为指针宽度）。 ----

void *shaderc_compiler_initialize(void) {
    void *real = ame_shaderc_shim_resolve("shaderc_compiler_initialize");
    if (real == NULL) return NULL;
    pthread_mutex_lock(&ame_shaderc_shim_lock);
    void *compiler = ((void *(*)(void))real)();
    // Task 38：入句柄表（恒等映射初始；重建时整体重映射）。
    compiler = ame_register_compiler(compiler);
    pthread_mutex_unlock(&ame_shaderc_shim_lock);
    fprintf(stderr, "[shaderc-shim] compiler_initialize -> %p (t=%.0fms tid=%lx)\n",
            compiler, ame_shim_ms(), ame_shim_tid());
    return compiler;
}

void shaderc_compiler_release(void *compiler) {
    void *real = ame_shaderc_shim_resolve("shaderc_compiler_release");
    if (real == NULL || compiler == NULL) return;
    ame_shim_lock_or_report_blocked("compiler_release", compiler);
    // Task 38：句柄表销号（共享 live 的引用计数语义；表外句柄直通 impl）。
    if (ame_compiler_map_count > 0) {
        bool found = false;
        for (int i = 0; i < ame_compiler_map_count; ++i) {
            if (ame_compiler_map[i].java_handle == compiler) {
                found = true;
                break;
            }
        }
        if (found) {
            ame_unregister_compiler(compiler);
            pthread_mutex_unlock(&ame_shaderc_shim_lock);
            fprintf(stderr, "[shaderc-shim] compiler_release %p done (t=%.0fms tid=%lx)\n",
                    compiler, ame_shim_ms(), ame_shim_tid());
            return;
        }
    }
    // 表外（溢出/异常）句柄：维持旧行为直下 impl。
    ((void (*)(void *))real)(compiler);
    pthread_mutex_unlock(&ame_shaderc_shim_lock);
    fprintf(stderr, "[shaderc-shim] compiler_release %p done (t=%.0fms tid=%lx)\n",
            compiler, ame_shim_ms(), ame_shim_tid());
}

void *shaderc_compile_options_initialize(void) {
    void *real = ame_shaderc_shim_resolve("shaderc_compile_options_initialize");
    if (real == NULL) return NULL;
    pthread_mutex_lock(&ame_shaderc_shim_lock);
    void *options = ((void *(*)(void))real)();
    // Task 42：影子注册（沙箱序列化的字段源）
    ame_opt_shadow_register(options);
    pthread_mutex_unlock(&ame_shaderc_shim_lock);
    return options;
}

void *shaderc_compile_options_clone(const void *options) {
    void *real = ame_shaderc_shim_resolve("shaderc_compile_options_clone");
    if (real == NULL || options == NULL) return NULL;
    pthread_mutex_lock(&ame_shaderc_shim_lock);
    void *cloned = ((void *(*)(const void *))real)(options);
    // Task 42：影子字段随 clone 复制
    ame_opt_shadow_clone(options, cloned);
    pthread_mutex_unlock(&ame_shaderc_shim_lock);
    return cloned;
}

void shaderc_compile_options_release(void *options) {
    void *real = ame_shaderc_shim_resolve("shaderc_compile_options_release");
    if (real == NULL || options == NULL) return;
    ame_shim_lock_or_report_blocked("options_release", options);
    ((void (*)(void *))real)(options);
    // Task 42：影子注销（编译请求携带字段快照，句柄销毁后无需保留）。
    // Task 54：注销必须在 master 锁【内】完成。旧代码在 unlock 之后才清理，
    // 与 options_initialize 的 malloc 地址复用构成 ABA：T1 release 解锁后、
    // 清理前，T2 的 initialize 拿到同一地址并注册了新的 include 回调，T1 
    // 随后的锁外清理会把 T2 的回调一并抹掉 —— 下一个含 #include 的编译
    // 走 "no include callbacks registered" 直通路径，glslang 报
    // "'#include' : required extension not requested"，必需管线编译失败
    // （真机 2026-09-10 22:17：beacon_beam_translucent + entity_translucent_cull
    // 双失败 → "Failed to load required shader programs" → 启动 16s 崩溃）。
    // 锁序：master → shadow，与 initialize/clone/编译入口一致，无死锁风险。
    ame_opt_shadow_release(options);
    pthread_mutex_unlock(&ame_shaderc_shim_lock);
    // Task 54 一次性指纹：strings 产物验证 + 下轮日志锚点（首个 release 即打）。
    {
        static int s_task54_marker = 0;
        if (!s_task54_marker) {
            s_task54_marker = 1;
            fprintf(stderr, "[shaderc-shim] Task54 options-shadow release under master "
                            "lock (ABA address-reuse race fixed)\n");
        }
    }
    fprintf(stderr, "[shaderc-shim] options_release %p done (t=%.0fms tid=%lx)\n",
            options, ame_shim_ms(), ame_shim_tid());
}

// 宏名/宏值写入 options：与 release/clone 同锁，防止 options 被并发拆掉时写入。
void shaderc_compile_options_add_macro_definition(void *options, const char *name,
                                                  size_t name_length, const char *value,
                                                  size_t value_length) {
    void *real = ame_shaderc_shim_resolve("shaderc_compile_options_add_macro_definition");
    if (real == NULL || options == NULL) return;
    pthread_mutex_lock(&ame_shaderc_shim_lock);
    ((void (*)(void *, const char *, size_t, const char *, size_t))real)(
        options, name, name_length, value, value_length);
    pthread_mutex_unlock(&ame_shaderc_shim_lock);
    // Task 42：宏入影子表（锁外小锁，防长宏拷贝占住 master 锁）
    ame_opt_shadow_macro(options, name, name_length, value, value_length);
}

// ---- Task 38：options 取证（透传 + 打印值） ----
// 揭示 MC RenderPearl 在 GL 路径 vs Vulkan 路径下喂给 shaderc 的编译选项差异
// （目标环境 / 源语言 / 优化等级 / 调试信息 / 强制版本）。枚举值以 int 打印，
// 与 shaderc.h 的枚举定义人工对照（target_env: 0=vulkan 1=opengl 3=webgpu...
// optimization_level: 0=无 1=size 2=performance 3=size+performance）。
// 不入锁（options 为单线程作用域对象，同 Task 30 结论）。
void shaderc_compile_options_set_target_env(void *options, int env, unsigned int version) {
    void *real = ame_shaderc_shim_resolve("shaderc_compile_options_set_target_env");
    if (real == NULL || options == NULL) return;
    fprintf(stderr, "[shaderc-shim] options_set: target_env=%d version=%u (opt=%p t=%.0fms)\n",
            env, version, options, ame_shim_ms());
    ((void (*)(void *, int, unsigned int))real)(options, env, version);
    ame_opt_shadow_set_env(options, env, version); // Task 42 影子镜像
}

void shaderc_compile_options_set_source_language(void *options, int lang) {
    void *real = ame_shaderc_shim_resolve("shaderc_compile_options_set_source_language");
    if (real == NULL || options == NULL) return;
    fprintf(stderr, "[shaderc-shim] options_set: source_language=%d (opt=%p t=%.0fms)\n",
            lang, options, ame_shim_ms());
    ((void (*)(void *, int))real)(options, lang);
    ame_opt_shadow_set_int(options, 0, lang); // Task 42 影子镜像
}

void shaderc_compile_options_set_optimization_level(void *options, int level) {
    void *real = ame_shaderc_shim_resolve("shaderc_compile_options_set_optimization_level");
    if (real == NULL || options == NULL) return;
    fprintf(stderr, "[shaderc-shim] options_set: optimization_level=%d (opt=%p t=%.0fms)\n",
            level, options, ame_shim_ms());
    ((void (*)(void *, int))real)(options, level);
    ame_opt_shadow_set_int(options, 1, level); // Task 42 影子镜像
}

// Task 47：RenderPearl 26.3 的 include 上行回调入口。Mojang 的 GlslCompiler
// 对每个管线编译都设置 resolver（LWJGL libffi closure）；旧 glue 将其 no-op
// 丢弃导致 34 个必需管线因 '#include: required extension not requested'
// 全部编译失败。本拦截把回调存入影子注册表（仅本进程有效，绝不序列化给
// 沙箱子进程），编译入口用它在调用者线程做文本展开（见 ame_include_expand）。
// 不转发给 impl：include 语义已在 shim 层收口，impl 收到的是展开后的干净源码。
void shaderc_compile_options_set_include_callbacks(void *options, void *resolver,
                                                   void *result_releaser,
                                                   void *user_data) {
    pthread_mutex_lock(&ame_opt_shadow_lock);
    ame_opt_shadow_entry_t *e = ame_opt_shadow_slot(options, 1);
    if (e != NULL) {
        e->inc_resolver = resolver;
        e->inc_releaser = result_releaser;
        e->inc_user_data = user_data;
    }
    pthread_mutex_unlock(&ame_opt_shadow_lock);
    fprintf(stderr,
            "[shaderc-shim] options_set: include_callbacks resolver=%p "
            "releaser=%p ud=%p (opt=%p t=%.0fms)\n",
            resolver, result_releaser, user_data, options, ame_shim_ms());
}

void shaderc_compile_options_set_generate_debug_info(void *options) {
    void *real = ame_shaderc_shim_resolve("shaderc_compile_options_set_generate_debug_info");
    if (real == NULL || options == NULL) return;
    fprintf(stderr, "[shaderc-shim] options_set: generate_debug_info ON (opt=%p t=%.0fms)\n",
            options, ame_shim_ms());
    ((void (*)(void *))real)(options);
    ame_opt_shadow_set_int(options, 2, 1); // Task 42 影子镜像
}

void shaderc_compile_options_set_forced_version_profile(void *options, int version, int profile) {
    void *real = ame_shaderc_shim_resolve("shaderc_compile_options_set_forced_version_profile");
    if (real == NULL || options == NULL) return;
    fprintf(stderr, "[shaderc-shim] options_set: forced_version=%d profile=%d (opt=%p t=%.0fms)\n",
            version, profile, options, ame_shim_ms());
    ((void (*)(void *, int, int))real)(options, version, profile);
    ame_opt_shadow_set_vp(options, version, profile); // Task 42 影子镜像
}

void *shaderc_compile_into_spv(void *compiler, const char *source, size_t source_size,
                               int kind, const char *input_file, const char *entry_point,
                               void *options) {
    return ame_shaderc_shim_compile("shaderc_compile_into_spv", compiler, source,
                                    source_size, kind, input_file, entry_point, options);
}

void *shaderc_compile_into_spv_assembly(void *compiler, const char *source,
                                        size_t source_size, int kind,
                                        const char *input_file, const char *entry_point,
                                        void *options) {
    return ame_shaderc_shim_compile("shaderc_compile_into_spv_assembly", compiler,
                                    source, source_size, kind, input_file, entry_point, options);
}

void *shaderc_compile_into_preprocessed_text(void *compiler, const char *source,
                                             size_t source_size, int kind,
                                             const char *input_file,
                                             const char *entry_point, void *options) {
    return ame_shaderc_shim_compile("shaderc_compile_into_preprocessed_text", compiler,
                                    source, source_size, kind, input_file, entry_point, options);
}
