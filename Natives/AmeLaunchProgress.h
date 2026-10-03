//
//  AmeLaunchProgress.h
//  ★ [LAUNCH-PROGRESS] 启动阶段上报 API
//
//  设计目标：让「启动到哪一步了」有一个统一、可观察的单一事实来源。
//  启动流水线散布在 JavaLauncher.m / SurfaceViewController.m，遮罩 UI 在
//  SurfaceViewController.m。这里做一层极薄的「阶段 + 比例」发布/订阅：
//
//    - 上报方（任意线程）：AmeLaunchProgressSetStage(...) / Report(...)
//    - 订阅方（主线程）：监听 AmeLaunchProgressChangedNotification 后读 getter
//
//  线程安全：内部用 NSLock 保护状态；通知统一投递到主队列，UI 侧无需自己切线程。
//  本层不改动任何启动逻辑，只做「告知现在到哪了」。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 启动阶段（按真实流水线顺序排列，便于「步骤骨架」自上而下阅读）。
///
/// 说明：任务书给的顺序是「渲染器 → 运行环境 → JIT 就绪」，但代码里
/// JIT26 建区/挂脚本（JavaLauncher.m 的 requiresDebugJITMapping 分支）发生在
/// 渲染器解析之前，故此处按实际执行顺序排列 —— 否则步骤骨架会跳步，
/// 反而看不出「卡在哪一步」。
typedef NS_ENUM(NSInteger, AmeLaunchStage) {
    AmeLaunchStagePrepareEnv = 0,      ///< 准备环境
    AmeLaunchStageJITReady,            ///< JIT 就绪
    AmeLaunchStageRenderer,            ///< 渲染器与图形 API
    AmeLaunchStageRuntime,             ///< 运行环境（Java · 内存）
    AmeLaunchStageArgsReady,           ///< 组装启动参数
    AmeLaunchStageJVMStarting,         ///< 启动 JVM
    AmeLaunchStageWaitingFirstFrame,   ///< 等待游戏画面
    AmeLaunchStageCompleted,           ///< 完成
};

/// 阶段总数（供步骤骨架遍历）。
FOUNDATION_EXPORT NSInteger AmeLaunchProgressStageCount(void);

/// 广播：阶段 / 比例发生变化。主队列投递，供遮罩订阅。
FOUNDATION_EXPORT NSNotificationName const AmeLaunchProgressChangedNotification;

/// 重置为初始状态（一次启动开始前调用；会广播一次）。
FOUNDATION_EXPORT void AmeLaunchProgressReset(void);

/// 上报「进入某阶段」。阶段比例取该阶段的起始权重，线程安全。
FOUNDATION_EXPORT void AmeLaunchProgressSetStage(AmeLaunchStage stage);

/// 细粒度上报：直接给一个 0..1 的比例，并可附带一个文案键（nil = 沿用阶段文案）。
/// 线程安全。用于阶段内部的平滑推进（例如等待游戏画面期间）。
FOUNDATION_EXPORT void AmeLaunchProgressReport(NSString * _Nullable key, double fraction);

/// 读取当前状态（供遮罩渲染）。线程安全。
FOUNDATION_EXPORT AmeLaunchStage AmeLaunchProgressCurrentStage(void);
FOUNDATION_EXPORT double AmeLaunchProgressCurrentFraction(void);
FOUNDATION_EXPORT NSString * _Nullable AmeLaunchProgressCurrentKey(void);

/// 阶段 → 本地化键（当前阶段文字 + 步骤骨架文案都用它）。
FOUNDATION_EXPORT NSString *AmeLaunchStageLocalizationKey(AmeLaunchStage stage);

NS_ASSUME_NONNULL_END
