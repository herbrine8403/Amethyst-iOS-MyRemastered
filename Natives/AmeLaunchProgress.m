//
//  AmeLaunchProgress.m
//  ★ [LAUNCH-PROGRESS] 启动阶段上报 API 的实现
//
//  只做三件事：存状态、加锁、广播。不引用任何启动器内部逻辑，便于单独演进。
//

#import "AmeLaunchProgress.h"

// 每个阶段的「起始比例」：阶段推进时，进度条跳到该比例。
// 单调递增，Completed = 1.0。数值是经验值：前段（环境 / JIT / 渲染器解析）
// 很快，真正耗时在最后「等待游戏画面」，所以给它留了较大的区间（0.90 → 1.00）。
static double const kAmeStageFractions[] = {
    0.00,  // AmeLaunchStagePrepareEnv
    0.10,  // AmeLaunchStageJITReady
    0.25,  // AmeLaunchStageRenderer
    0.40,  // AmeLaunchStageRuntime
    0.60,  // AmeLaunchStageArgsReady
    0.75,  // AmeLaunchStageJVMStarting
    0.90,  // AmeLaunchStageWaitingFirstFrame
    1.00,  // AmeLaunchStageCompleted
};

NSNotificationName const AmeLaunchProgressChangedNotification = @"AmeLaunchProgressChanged";

// ---- 内部状态（受 sAmeLock 保护） ----
static NSLock *sAmeLock = nil;
static AmeLaunchStage sAmeStage = AmeLaunchStagePrepareEnv;
static double sAmeFraction = 0.0;
static NSString *sAmeKey = nil;

/// 惰性建锁。dispatch_once 本身线程安全，任意线程首调都安全。
static NSLock *AmeLaunchProgressLock(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sAmeLock = [[NSLock alloc] init];
    });
    return sAmeLock;
}

/// 统一在主队列广播，订阅方（UI）无须自己切线程。
static void AmeLaunchProgressPostChanged(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:AmeLaunchProgressChangedNotification
                                                            object:nil];
    });
}

NSInteger AmeLaunchProgressStageCount(void) {
    return (NSInteger)(sizeof(kAmeStageFractions) / sizeof(kAmeStageFractions[0]));
}

void AmeLaunchProgressReset(void) {
    NSLock *lock = AmeLaunchProgressLock();
    [lock lock];
    sAmeStage = AmeLaunchStagePrepareEnv;
    sAmeFraction = kAmeStageFractions[AmeLaunchStagePrepareEnv];
    sAmeKey = nil;
    [lock unlock];
    AmeLaunchProgressPostChanged();
}

void AmeLaunchProgressSetStage(AmeLaunchStage stage) {
    if (stage < 0 || stage >= AmeLaunchProgressStageCount()) {
        return;   // 越界忽略，防御性：上报点写崩也不要连累启动流程
    }
    NSLock *lock = AmeLaunchProgressLock();
    [lock lock];
    sAmeStage = stage;
    sAmeFraction = kAmeStageFractions[stage];
    sAmeKey = nil;
    [lock unlock];
    AmeLaunchProgressPostChanged();
}

void AmeLaunchProgressReport(NSString *key, double fraction) {
    if (fraction < 0.0) fraction = 0.0;
    if (fraction > 1.0) fraction = 1.0;
    NSLock *lock = AmeLaunchProgressLock();
    [lock lock];
    sAmeFraction = fraction;
    sAmeKey = [key copy];   // key 可为 nil
    [lock unlock];
    AmeLaunchProgressPostChanged();
}

AmeLaunchStage AmeLaunchProgressCurrentStage(void) {
    NSLock *lock = AmeLaunchProgressLock();
    [lock lock];
    AmeLaunchStage stage = sAmeStage;
    [lock unlock];
    return stage;
}

double AmeLaunchProgressCurrentFraction(void) {
    NSLock *lock = AmeLaunchProgressLock();
    [lock lock];
    double fraction = sAmeFraction;
    [lock unlock];
    return fraction;
}

NSString *AmeLaunchProgressCurrentKey(void) {
    NSLock *lock = AmeLaunchProgressLock();
    [lock lock];
    NSString *key = sAmeKey;
    [lock unlock];
    return key;
}

NSString *AmeLaunchStageLocalizationKey(AmeLaunchStage stage) {
    switch (stage) {
        case AmeLaunchStagePrepareEnv:      return @"launch.progress.stage.prepare_env";
        case AmeLaunchStageJITReady:        return @"launch.progress.stage.jit_ready";
        case AmeLaunchStageRenderer:        return @"launch.progress.stage.renderer";
        case AmeLaunchStageRuntime:         return @"launch.progress.stage.runtime";
        case AmeLaunchStageArgsReady:       return @"launch.progress.stage.args_ready";
        case AmeLaunchStageJVMStarting:     return @"launch.progress.stage.jvm_starting";
        case AmeLaunchStageWaitingFirstFrame: return @"launch.progress.stage.waiting_first_frame";
        case AmeLaunchStageCompleted:       return @"launch.progress.stage.completed";
    }
    return @"launch.progress.stage.prepare_env";
}
