#pragma once

#include <Foundation/Foundation.h>
#include "jni.h"

typedef jint JLI_Launch_func(int argc, const char ** argv, /* main argc, argc */
        int jargc, const char** jargv,          /* java args */
        int appclassc, const char** appclassv,  /* app classpath */
        const char* fullversion,                /* full version defined */
        const char* dotversion,                 /* dot version defined */
        const char* pname,                      /* program name */
        const char* lname,                      /* launcher name */
        jboolean javaargs,                      /* JAVA_ARGS */
        jboolean cpwildcard,                    /* classpath wildcard*/
        jboolean javaw,                         /* windows-only javaw */
        jint ergo                               /* ergonomics class policy */
);
JLI_Launch_func *pJLI_Launch;

int launchJVM(NSString *accountId, id launchTarget, int width, int height, int minVersion);

// Task98：从任意形态的版本 ID（原版 "26.3" / 快照 "26w14a" / Fabric
// "fabric-loader-0.19.5-26.3-e4ecd7db" / Forge "1.20.1-forge-47.3.0"）提取
// MC 主版本号（年份制口径）。1.x 谱系返回 1；无法解析返回 0。
// 供 ResolveLwjglVersion（LWJGL 333/341 选择）与 SurfaceViewController 的
// LTW × 26.x 预检门共用，保证两处口径一致（详见 JavaLauncher.m 内实现头注释）。
NSInteger ame98_mcMajorFromVersionId(NSString *versionId);

// Headless JVM：在当前进程内以最小参数（无 caciocavallo/LWJGL/渲染）创建 JVM，
// 经 JNI 反射运行指定 main 类，返回后进程继续存活。用于 Forge/NeoForge 直装
// 执行 install_profile 的 processors（必须可返回，禁止走 JLI_Launch——后者在
// main 返回后调用 exit() 终结进程）。
// 返回 0 = 成功（最终成败以 processor 的 status.json 为准）；负数为启动器侧错误：
//   -1 JIT 未启用 / legacy JIT 脚本需要重启
//   -2 JVM 创建失败（JNI_CreateJavaVM 符号缺失或返回非 JNI_OK）
//   -3 无可用 JRE 运行时
//   -4 VM 库/运行类加载失败（libjvm 缺失、ForgeProcessorRunner/main 方法/参数构造失败）
//   -5 进程内 JVM 已创建过（需重启 app）
int launchHeadlessJVM(NSString *mainClass, NSArray<NSString *> *args, int minJavaVersion);

// 当前进程是否已创建过 JVM（游戏或 headless 任一次）。
// 进程内 JVM 只能创建一次，再次 JLI_Launch 会崩溃；调用方据此提示用户重启 app。
BOOL JVMUsedInProcess(void);
