#import <Foundation/Foundation.h>
#import "PLTaskStage.h"

NS_ASSUME_NONNULL_BEGIN

// 下载任务状态
typedef NS_ENUM(NSInteger, DownloadTaskState) {
    DownloadTaskStatePending = 0,    // 等待中
    DownloadTaskStateDownloading,    // 下载中
    DownloadTaskStatePaused,         // 已暂停
    DownloadTaskStateCompleted,      // 已完成
    DownloadTaskStateCancelled,      // 已取消
    DownloadTaskStateFailed          // 失败
};

// 聚合状态（用于悬浮球、启动保护等）
typedef NS_ENUM(NSInteger, DownloadTaskAggregateState) {
    DownloadTaskAggregateStateNone = 0,   // 无任务
    DownloadTaskAggregateStateIdle,       // 全部暂停/等待中但无活动
    DownloadTaskAggregateStateActive,     // 存在下载中任务
    DownloadTaskAggregateStatePaused,     // 至少有一个暂停且无活动任务
    DownloadTaskAggregateStateCompleted,  // 全部完成
    DownloadTaskAggregateStateFailed      // 全部失败/取消后仍有失败记录（可选）
};

// 资源类型常量
extern NSString * const DownloadTaskResourceTypeMinecraft;
extern NSString * const DownloadTaskResourceTypeModloader;
extern NSString * const DownloadTaskResourceTypeMod;
extern NSString * const DownloadTaskResourceTypeShader;
extern NSString * const DownloadTaskResourceTypeResourcePack;
extern NSString * const DownloadTaskResourceTypeDataPack;
extern NSString * const DownloadTaskResourceTypeModpack;
extern NSString * const DownloadTaskResourceTypeWorld;
extern NSString * const DownloadTaskResourceTypeJavaRuntime;

/// 传输字节已完成，但任务仍在校验、落盘、解压或安装。
/// 此阶段不应在 UI 中显示为“下载中 100%”。
extern NSString * const DownloadTaskUserInfoTransferCompleteKey;

@class DownloadTaskItem;

/// 重试回调类型：业务方注册任务时设置，DownloadTaskManager.retryTaskWithId: 会调用它重建底层 rawTask。
/// 业务方在 handler 内创建新的 NSURLSessionTask 并赋值给 item.rawTask，无需移除旧 item（manager 已处理）。
/// 参数为当前 item（已重置状态），返回新的 rawTask（用于 manager 更新 item.rawTask）。
typedef id _Nullable (^DownloadRetryHandler)(DownloadTaskItem *item);

/**
 * 统一下载任务数据模型。
 * 每个下载任务（MC 本体、加载器、Mod、资源包等）在 DownloadTaskManager 中对应一个实例。
 */
@interface DownloadTaskItem : NSObject

@property (nonatomic, copy) NSString *taskId;
@property (nonatomic, copy) NSString *resourceType;
@property (nonatomic, copy) NSString *resourceName;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *downloadSource;
@property (nonatomic, assign) DownloadTaskState state;

/// 0.0 ~ 1.0；< 0 表示未知/不确定
@property (nonatomic, assign) double progress;
@property (nonatomic, assign) int64_t totalSize;
@property (nonatomic, assign) int64_t downloadedSize;
@property (nonatomic, assign) double speed;                    // bytes/s
@property (nonatomic, assign) NSTimeInterval estimatedTimeRemaining;

/// 多文件任务（如整合包）的文件级进度（Phase 6 Task 6.1 双维度进度）；
/// totalFileCount <= 0 表示单文件任务（不展示文件计数维度）
@property (nonatomic, assign) NSInteger completedFileCount;
@property (nonatomic, assign) NSInteger totalFileCount;

@property (nonatomic, copy, nullable) NSString *iconURL;
@property (nonatomic, assign) BOOL supportsResume;
@property (nonatomic, strong) NSDate *createdDate;

/// 底层任务对象，弱引用以避免循环持有（MinecraftResourceDownloadTask / NSURLSessionTask 等）
@property (nonatomic, weak, nullable) id rawTask;
@property (nonatomic, strong, nullable) NSError *errorInfo;

/// 供业务方存放扩展字段
@property (nonatomic, strong) NSMutableDictionary *userInfo;

#pragma mark - 重试支持（FCL 风格重新下载）

/// 原始下载 URL，便于重试/切换源时在模型层直接重建（可选，业务方可不填）
@property (nonatomic, copy, nullable) NSString *downloadURL;

/// 重试回调：业务方注册任务时设置，DownloadTaskManager.retryTaskWithId: 会调用它重建底层 rawTask。
/// 业务方在 handler 内创建新的 NSURLSessionTask 并赋值给 item.rawTask，无需移除旧 item（manager 已处理）。
/// 参数为当前 item（已重置状态），返回新的 rawTask（用于 manager 更新 item.rawTask）。
@property (nonatomic, copy, nullable) DownloadRetryHandler retryHandler;

/// 已重试次数（manager 在每次 retryTaskWithId: 时自增）
@property (nonatomic, assign) NSInteger retryCount;

/// 最大重试次数，默认 3。超过后 UI 不再显示"重试"按钮（仍可"移除"）
@property (nonatomic, assign) NSInteger maxRetryCount;

#pragma mark - 断点续传 / 持久化恢复支持（Phase 2）

/// 断点续传数据文件路径（pause 时由 manager 落盘到
/// <Home>/Library/Caches/PLDownloadResumeData/<taskId>.resume；从磁盘快照恢复时保留路径引用）
@property (nonatomic, copy, nullable) NSString *resumeDataPath;

/// 从磁盘快照恢复标记：底层 rawTask 与 retryHandler 闭包无法序列化，
/// 恢复的任务需业务方重新注册才能真正续传/重试；恢复项的 supportsResume 会被置 NO。
@property (nonatomic, assign) BOOL needsRecreate;

#pragma mark - 阶段化进度（redesign-download-ui Phase 1）

/// 阶段列表（安装类任务的多步骤进度；空数组表示无阶段信息，回退纯进度展示）。
/// 阶段对象可变，业务方通过 DownloadTaskManager 的阶段上报 API 逐个更新。
@property (nonatomic, copy) NSArray<PLTaskStage *> *stages;

/// 当前进行到的阶段下标；-1 表示未进入任何阶段（无阶段信息时保持 -1）
@property (nonatomic, assign) NSInteger currentStageIndex;

/// 当前阶段（stages 为空或 currentStageIndex 越界时返回 nil，UI 可安全调用）
- (nullable PLTaskStage *)currentStage;

/// 安装类任务自动弹出统一进度页标记（redesign-download-ui Phase 2）：
/// 业务方注册任务后置 YES，DownloadTaskManager 在该任务首次状态更新时
/// 自动弹出 PLTaskProgressViewController（同屏仅一个，新任务替换内容）。
/// 纯运行时标记，不参与快照序列化（恢复的任务不自动弹出）。
@property (nonatomic, assign) BOOL autoPresentDetail;

- (instancetype)initWithResourceType:(NSString *)resourceType
                        resourceName:(NSString *)resourceName
                         displayName:(NSString *)displayName
                      downloadSource:(NSString *)downloadSource
                             rawTask:(nullable id)rawTask
                      supportsResume:(BOOL)supportsResume
                             iconURL:(nullable NSString *)iconURL;

#pragma mark - 快照序列化（由 DownloadTaskManager 持久化/恢复时调用）

/// 导出可 JSON 序列化的任务快照（taskId、resourceType、name、displayName、iconURL、state、
/// totalBytes、receivedBytes、downloadSource、timestamp、downloadURL 等字段）
- (NSDictionary *)snapshotDictionary;

/// 从快照重建任务（沿用原 taskId；rawTask/retryHandler 不可恢复）。
/// 快照非法（缺 taskId / 类型不符）时返回 nil。
- (nullable instancetype)initWithSnapshotDictionary:(NSDictionary *)snapshot;

/// 导出下载历史条目（名称/类型/大小/时间/结果，供 DownloadHistoryStore 记录）
- (NSDictionary *)historyDictionary;

@end

NS_ASSUME_NONNULL_END
