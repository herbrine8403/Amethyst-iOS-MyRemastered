#import "utils.h"
#import "DownloadTaskManager.h"
#import "DownloadHistoryStore.h"
#import "PLDownloadClient.h"
#import "PLTaskProgressViewController.h"

NSString * const DownloadTaskManagerDidUpdateTaskNotification          = @"com.amethyst.DownloadTaskManager.DidUpdateTask";
NSString * const DownloadTaskManagerAggregateStateDidChangeNotification = @"com.amethyst.DownloadTaskManager.AggregateStateDidChange";
NSString * const DownloadTaskManagerTaskCompletedNotification           = @"com.amethyst.DownloadTaskManager.TaskCompleted";
NSString * const DownloadTaskManagerTaskKey                             = @"DownloadTaskManagerTaskKey";

/// 全局并发下载上限（同时 Downloading 的任务数）
NSInteger const PLDownloadMaxConcurrentTasks = 3;

static BOOL PLDownloadTaskStateIsTerminal(DownloadTaskState state) {
    return state == DownloadTaskStateCompleted ||
           state == DownloadTaskStateCancelled ||
           state == DownloadTaskStateFailed;
}

/// NSURLSession 断点续传失效错误码（即文档中的 NSURLErrorCannotResume，
/// iOS SDK 头文件未导出该符号，此处按系统取值本地定义）
static NSInteger const PLNSURLErrorCannotResume = -3004;

/// 快照持久化 debounce 间隔（秒）：状态变化后合并写
static const NSTimeInterval kSnapshotDebounceInterval = 0.5;
/// 进度上报触发落盘的最小间隔（秒）：高频进度下节流，保证长下载期间快照也能定期落盘
static const NSTimeInterval kSnapshotProgressThrottleInterval = 3.0;
/// 进度类 UI 通知节流间隔（秒）：下载器 KVO/回调每秒可触发数百次，
/// 若每次都派发主队列通知会让进度页/下载中心全量刷新刷爆主队列，
/// 触摸事件无法响应（表现为进度页卡死、按钮点不动）。
/// 进度/速率/文件计数类更新按此间隔合并；状态变化（state/stages/终态）仍立即通知。
static const NSTimeInterval kUIProgressNotifyThrottleInterval = 0.2;

@interface DownloadTaskManager ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, DownloadTaskItem *> *tasks;
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, assign) DownloadTaskAggregateState lastAggregateState;

/// 全局并发上限信号量：可用槽位 = PLDownloadMaxConcurrentTasks - 当前 Downloading 数
@property (nonatomic, strong) dispatch_semaphore_t concurrencySemaphore;
/// 排队等待槽位的任务 FIFO（taskId），槽位释放时自动出队启动
@property (nonatomic, strong) NSMutableArray<NSString *> *waitQueue;
/// manager 对 NSURLSessionTask 施加的额外 suspend 次数（出队时平衡 resume）
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *holdCounts;
/// 当前实际占用并发槽位的 taskId 集合。
/// 信号量的 wait/signal 必须与集合的添加/移除严格配对：
/// rawTask=nil 的任务（整合包聚合卡片等）不占用槽位，离开 Downloading 时
/// 依据此集合判断是否需要释放，防止信号量超发导致并发上限失效。
@property (nonatomic, strong) NSMutableSet<NSString *> *slotOwningTaskIds;

/// 磁盘 IO 专用串行队列（快照持久化 / resumeData 落盘）
@property (nonatomic, strong) dispatch_queue_t ioQueue;
/// debounce 中的待写 block（仅在 ioQueue 上访问）
@property (nonatomic, strong, nullable) dispatch_block_t pendingPersistBlock;
/// 上次快照落盘时间（仅在 ioQueue 上访问）
@property (nonatomic, strong, nullable) NSDate *lastPersistDate;

/// 下载历史存储
@property (nonatomic, strong) DownloadHistoryStore *historyStore;

/// 已自动弹出过统一进度页的 taskId（redesign-download-ui Task 2.3）。
/// 仅在主队列访问（postUpdateForTask: 的 dispatch block 内），无需加锁；
/// 用于保证 autoPresentDetail 任务只弹出一次（用户最小化后进度更新不再打扰）。
@property (nonatomic, strong) NSMutableSet<NSString *> *autoPresentedTaskIds;

/// 进度类 UI 通知节流状态（仅在主队列访问，无需加锁）：
/// lastProgressNotifyDates：taskId → 上次进度通知时间
/// pendingProgressNotifyTaskIds：已排队等待补发通知的 taskId（防止重复堆积 dispatch_after）
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *lastProgressNotifyDates;
@property (nonatomic, strong) NSMutableSet<NSString *> *pendingProgressNotifyTaskIds;
@end

@implementation DownloadTaskManager

+ (instancetype)sharedManager {
    static DownloadTaskManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _tasks = [NSMutableDictionary dictionary];
        _lock = [[NSLock alloc] init];
        _lastAggregateState = DownloadTaskAggregateStateNone;
        _concurrencySemaphore = dispatch_semaphore_create(PLDownloadMaxConcurrentTasks);
        _waitQueue = [NSMutableArray array];
        _holdCounts = [NSMutableDictionary dictionary];
        _slotOwningTaskIds = [NSMutableSet set];
        _ioQueue = dispatch_queue_create("com.amethyst.downloadtaskmanager.io", DISPATCH_QUEUE_SERIAL);
        _historyStore = [DownloadHistoryStore sharedStore];
        _autoPresentedTaskIds = [NSMutableSet set];
        _lastProgressNotifyDates = [NSMutableDictionary dictionary];
        _pendingProgressNotifyTaskIds = [NSMutableSet set];
        [self restoreTasksFromDisk];
    }
    return self;
}

#pragma mark - 路径

/// 任务快照持久化目录（启动器自身数据）
- (NSString *)dataDirectoryPath {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Amethyst"];
}

- (NSString *)tasksSnapshotPath {
    return [[self dataDirectoryPath] stringByAppendingPathComponent:@"download_tasks.json"];
}

/// resumeData 持久化目录（缓存性质，可被系统清理）
- (NSString *)resumeDataDirectoryPath {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/PLDownloadResumeData"];
}

- (NSString *)resumeDataPathForTaskId:(NSString *)taskId {
    return [self.resumeDataDirectoryPath
        stringByAppendingPathComponent:[taskId stringByAppendingPathExtension:@"resume"]];
}

#pragma mark - Registration / Query

- (DownloadTaskItem *)registerTaskWithResourceType:(NSString *)resourceType
                                      resourceName:(NSString *)resourceName
                                       displayName:(NSString *)displayName
                                    downloadSource:(NSString *)downloadSource
                                           rawTask:(id)rawTask
                                    supportsResume:(BOOL)supportsResume
                                           iconURL:(NSString *)iconURL {
    DownloadTaskItem *item = [[DownloadTaskItem alloc] initWithResourceType:resourceType
                                                               resourceName:resourceName
                                                                displayName:displayName
                                                             downloadSource:downloadSource
                                                                    rawTask:rawTask
                                                             supportsResume:supportsResume
                                                                    iconURL:iconURL];
    [self.lock lock];
    self.tasks[item.taskId] = item;
    [self.lock unlock];

    [self postUpdateForTask:item];
    [self checkAggregateStateChange];
    [self schedulePersistSnapshot];
    return item;
}

- (void)removeTaskWithId:(NSString *)taskId {
    if (!taskId) return;
    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    if (!item) { [self.lock unlock]; return; }

    BOOL wasDownloading = (item.state == DownloadTaskStateDownloading);
    [self removeFromWaitQueueLocked:taskId];
    self.holdCounts[taskId] = nil;
    [self.tasks removeObjectForKey:taskId];
    if (wasDownloading) {
        // 释放并发槽位（幂等：rawTask=nil 任务未持槽位则跳过；remove 不取消底层 rawTask，由业务方管理生命周期）
        BOOL didReleaseSlot = [self taskOwnsSlotLocked:taskId];
        [self releaseSlotForTaskLocked:taskId];
        [self.lock unlock];

        if (didReleaseSlot) {
            [self.lock lock];
            [self dequeueNextTasksLocked];
            [self.lock unlock];
        }
    } else {
        [self.lock unlock];
    }

    // 清理该任务的持久化断点数据
    [self deleteResumeDataForItem:item];

    [self postUpdateForTask:item];
    [self checkAggregateStateChange];
    [self schedulePersistSnapshot];
}

- (DownloadTaskItem *)taskWithId:(NSString *)taskId {
    if (!taskId) return nil;
    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    [self.lock unlock];
    return item;
}

- (NSArray<DownloadTaskItem *> *)allTasks {
    [self.lock lock];
    NSArray *copy = [self.tasks.allValues copy];
    [self.lock unlock];
    return copy;
}

- (NSArray<DownloadTaskItem *> *)tasksWithState:(DownloadTaskState)state {
    return [self tasksWithStates:@[@(state)]];
}

- (NSArray<DownloadTaskItem *> *)tasksWithStates:(NSArray<NSNumber *> *)states {
    NSMutableArray *result = [NSMutableArray array];
    [self.lock lock];
    for (DownloadTaskItem *item in self.tasks.allValues) {
        if ([states containsObject:@(item.state)]) {
            [result addObject:item];
        }
    }
    [self.lock unlock];
    return [result copy];
}

- (NSInteger)countOfTasksWithState:(DownloadTaskState)state {
    [self.lock lock];
    NSInteger count = 0;
    for (DownloadTaskItem *item in self.tasks.allValues) {
        if (item.state == state) count++;
    }
    [self.lock unlock];
    return count;
}

#pragma mark - Aggregate State

- (DownloadTaskAggregateState)currentAggregateState {
    [self.lock lock];
    NSArray *values = [self.tasks.allValues copy];
    [self.lock unlock];

    if (values.count == 0) return DownloadTaskAggregateStateNone;

    BOOL hasActive = NO;
    BOOL hasPaused = NO;
    BOOL hasPending = NO;
    BOOL allCompleted = YES;
    BOOL hasFailed = NO;

    for (DownloadTaskItem *item in values) {
        switch (item.state) {
            case DownloadTaskStateDownloading:
                hasActive = YES;
                allCompleted = NO;
                break;
            case DownloadTaskStatePending:
                hasPending = YES;
                allCompleted = NO;
                break;
            case DownloadTaskStatePaused:
                hasPaused = YES;
                allCompleted = NO;
                break;
            case DownloadTaskStateFailed:
                hasFailed = YES;
                allCompleted = NO;
                break;
            case DownloadTaskStateCancelled:
                allCompleted = NO;
                break;
            case DownloadTaskStateCompleted:
                break;
        }
    }

    if (hasActive || hasPending) return DownloadTaskAggregateStateActive;
    if (hasPaused) return DownloadTaskAggregateStatePaused;
    if (allCompleted) return DownloadTaskAggregateStateCompleted;
    if (hasFailed) return DownloadTaskAggregateStateFailed;
    return DownloadTaskAggregateStateIdle;
}

- (BOOL)hasActiveTasks {
    return [self hasTasksInStates:@[@(DownloadTaskStateDownloading), @(DownloadTaskStatePending)]];
}

- (BOOL)hasTasksInStates:(NSArray<NSNumber *> *)states {
    [self.lock lock];
    BOOL found = NO;
    for (DownloadTaskItem *item in self.tasks.allValues) {
        if ([states containsObject:@(item.state)]) {
            found = YES;
            break;
        }
    }
    [self.lock unlock];
    return found;
}

#pragma mark - 并发槽位辅助（以下方法除说明外均需持 self.lock 调用）

/// 尝试为任务占用一个下载槽位（非阻塞）。成功返回 YES 并记录所有权。
- (BOOL)acquireSlotForTaskLocked:(NSString *)taskId {
    if (!taskId) return NO;
    if (dispatch_semaphore_wait(self.concurrencySemaphore, DISPATCH_TIME_NOW) != 0) {
        return NO;
    }
    [self.slotOwningTaskIds addObject:taskId];
    return YES;
}

/// 释放任务占用的下载槽位（幂等：仅当任务确实持有槽位时才 signal，
/// rawTask=nil 的任务从未占用槽位，此处安全跳过，防止信号量超发）
- (void)releaseSlotForTaskLocked:(NSString *)taskId {
    if (!taskId) return;
    if (![self.slotOwningTaskIds containsObject:taskId]) return;
    [self.slotOwningTaskIds removeObject:taskId];
    dispatch_semaphore_signal(self.concurrencySemaphore);
}

/// 任务当前是否持有并发槽位
- (BOOL)taskOwnsSlotLocked:(NSString *)taskId {
    return taskId ? [self.slotOwningTaskIds containsObject:taskId] : NO;
}

/// 当前 Downloading 任务数（诊断/日志用）
- (NSInteger)downloadingCountLocked {
    NSInteger count = 0;
    for (DownloadTaskItem *item in self.tasks.allValues) {
        if (item.state == DownloadTaskStateDownloading) count++;
    }
    return count;
}

/// 挂起底层任务（排队时调用，抵消业务方的 resume / 阻止其继续下载）
/// - NSURLSessionTask：suspend 一次并记录 holdCount（resume/suspend 为平衡计数）
/// - PLDownloadOperation：Running 状态下 pauseOperation（其内部自动落盘 resumeData，天然支持跨进程续传）
/// - 其他自定义对象：responds suspend 则 best-effort 挂起（不计数）
- (void)holdRawTaskLocked:(DownloadTaskItem *)item {
    id rawTask = item.rawTask;
    if (!rawTask) return; // rawTask 为 nil 时仅做状态层排队

    if ([rawTask isKindOfClass:[PLDownloadOperation class]]) {
        // 不在此处预读 operation.state：pauseOperation 自身会在 PLDownloadClient
        // 的串行 stateQueue 上做幂等检查。无条件入队可保证快速出队时形成
        // begin -> pause -> resume 的确定顺序，避免 TOCTOU 后永久停在 Paused。
        [[PLDownloadClient sharedClient] pauseOperation:rawTask];
        NSNumber *held = self.holdCounts[item.taskId];
        self.holdCounts[item.taskId] = @((held ? held.integerValue : 0) + 1);
        return;
    }

    if ([rawTask respondsToSelector:@selector(suspend)]) {
        [rawTask suspend];
        NSNumber *held = self.holdCounts[item.taskId];
        self.holdCounts[item.taskId] = @((held ? held.integerValue : 0) + 1);
    }
}

/// 解除挂起（出队启动时调用，恢复底层任务实际下载）
/// - NSURLSessionTask：state==Suspended 时 resume；若仍为 Suspended 再补一次
///   （覆盖"业务方 resume 永不到来"的计数缺口，保证任务真正运行）
/// - PLDownloadOperation：Paused 状态下 resumeOperation（自动用 resumeData 断点续传）
- (void)releaseRawTaskHoldLocked:(DownloadTaskItem *)item {
    NSNumber *held = self.holdCounts[item.taskId];
    NSInteger holdCount = held ? held.integerValue : 0;
    self.holdCounts[item.taskId] = nil;
    if (holdCount <= 0) return;

    id rawTask = item.rawTask;
    if (!rawTask) return;

    if ([rawTask isKindOfClass:[PLDownloadOperation class]]) {
        // 与 pause 同一串行队列排队；不要用异步更新前的 state 做判断。
        [[PLDownloadClient sharedClient] resumeOperation:rawTask];
        return;
    }

    if ([rawTask isKindOfClass:[NSURLSessionTask class]]) {
        NSURLSessionTask *task = (NSURLSessionTask *)rawTask;
        if (task.state == NSURLSessionTaskStateSuspended) {
            [task resume];
            // 计数缺口补偿：业务方的 resume 从未到来时一次 resume 不够
            if (task.state == NSURLSessionTaskStateSuspended) {
                [task resume];
            }
        }
        return;
    }

    if ([rawTask respondsToSelector:@selector(resume)]) {
        for (NSInteger i = 0; i < holdCount; i++) {
            [rawTask resume];
        }
    }
}

/// 加入等待队列（去重）
- (void)enqueueItemLocked:(DownloadTaskItem *)item {
    if (![self.waitQueue containsObject:item.taskId]) {
        [self.waitQueue addObject:item.taskId];
    }
}

/// 从等待队列移除，返回移除前是否在队列中
- (BOOL)removeFromWaitQueueLocked:(NSString *)taskId {
    NSUInteger index = [self.waitQueue indexOfObject:taskId];
    if (index == NSNotFound) return NO;
    [self.waitQueue removeObjectAtIndex:index];
    return YES;
}

- (BOOL)isQueuedLocked:(NSString *)taskId {
    return [self.waitQueue containsObject:taskId];
}

/// 槽位释放后自动出队：FIFO 启动排队任务，直到无槽位或队列空。
/// 注意：内部调用 postUpdateForTask（异步派发，持锁安全），不调用 checkAggregateStateChange（会重入加锁），
/// 聚合状态检查由调用方在解锁后执行。
- (void)dequeueNextTasksLocked {
    while (self.waitQueue.count > 0) {
        NSString *taskId = self.waitQueue.firstObject;
        DownloadTaskItem *item = self.tasks[taskId];

        // 任务已被移除或进入不可出队状态：跳过（不消耗槽位）
        if (!item || (item.state != DownloadTaskStatePending && item.state != DownloadTaskStatePaused)) {
            [self.waitQueue removeObjectAtIndex:0];
            self.holdCounts[taskId] = nil;
            continue;
        }

        // 占用一个槽位；无槽位则停止出队
        if (![self acquireSlotForTaskLocked:taskId]) break;

        [self.waitQueue removeObjectAtIndex:0];
        item.state = DownloadTaskStateDownloading;
        item.needsRecreate = NO;
        [self releaseRawTaskHoldLocked:item];
        [self postUpdateForTask:item];
    }
}

/// 核心入口：让任务进入 Downloading（槽位满则排队等待，保持 Pending 状态）
- (void)requestDownloadingStateForItem:(DownloadTaskItem *)item {
    if (!item) return;

    [self.lock lock];
    if (PLDownloadTaskStateIsTerminal(item.state)) {
        [self.lock unlock];
        return;
    }
    if (item.state == DownloadTaskStateDownloading) {
        [self.lock unlock];
        return; // 已占用槽位，幂等返回
    }

    // rawTask=nil（如整合包每文件卡片/聚合卡片）：底层传输由 PLDownloadClient 自身
    // 的连接数上限限流，manager 无可挂起的底层任务，不消耗并发槽位，直接进入
    // Downloading——避免 12 路并发下载在卡片上被误显示为 Pending 排队。
    if (item.rawTask == nil) {
        [self removeFromWaitQueueLocked:item.taskId];
        item.state = DownloadTaskStateDownloading;
        // 防御：清除可能存在的陈旧槽位所有权（正常流程 rawTask=nil 从不占槽位）
        [self releaseSlotForTaskLocked:item.taskId];
        [self.lock unlock];
        [self postUpdateForTask:item];
        [self checkAggregateStateChange];
        [self schedulePersistSnapshot];
        return;
    }

    if ([self acquireSlotForTaskLocked:item.taskId]) {
        [self removeFromWaitQueueLocked:item.taskId];
        item.state = DownloadTaskStateDownloading;
        [self.lock unlock];
    } else {
        item.state = DownloadTaskStatePending;
        [self holdRawTaskLocked:item];
        [self enqueueItemLocked:item];
        [self.lock unlock];
    }

    [self postUpdateForTask:item];
    [self checkAggregateStateChange];
    [self schedulePersistSnapshot];
}

#pragma mark - Actions

- (void)pauseTaskWithId:(NSString *)taskId {
    if (!taskId) return;

    DownloadTaskItem *item = nil;
    id rawTaskToPause = nil;
    BOOL needDequeue = NO;
    BOOL didReleaseSlot = NO;

    [self.lock lock];
    item = self.tasks[taskId];
    if (!item) { [self.lock unlock]; return; }

    DownloadTaskState state = item.state;
    if (state != DownloadTaskStateDownloading && state != DownloadTaskStatePending) {
        [self.lock unlock];
        return;
    }

    BOOL wasQueued = [self removeFromWaitQueueLocked:taskId];
    item.state = DownloadTaskStatePaused;
    item.speed = 0.0;
    item.estimatedTimeRemaining = 0.0;

    if (wasQueued) {
        // 排队中的任务：底层任务已被 hold 挂起，保持 holdCount（下次 resume/出队时平衡释放）
    } else if (state == DownloadTaskStateDownloading) {
        // 真正下载中：释放槽位（幂等：rawTask=nil 任务未持槽位则跳过）并暂停底层任务（真断点续传）
        didReleaseSlot = [self taskOwnsSlotLocked:taskId];
        [self releaseSlotForTaskLocked:taskId];
        needDequeue = didReleaseSlot;
        id rawTask = item.rawTask;
        if ([rawTask isKindOfClass:[NSURLSessionDownloadTask class]]) {
            // downloadTask 走 cancelByProducingResumeData（锁外异步，resumeData 落盘）
            rawTaskToPause = rawTask;
        } else if (rawTask) {
            // PLDownloadOperation / 自定义对象：hold（pauseOperation / suspend + holdCount 记录，
            // 保证后续 resumeTaskWithId: 能真正恢复底层任务）
            [self holdRawTaskLocked:item];
        }
    } else {
        // Pending 未排队：挂起底层任务，防止业务方稍后的 resume 启动它
        [self holdRawTaskLocked:item];
    }
    [self.lock unlock];

    if (needDequeue) {
        [self.lock lock];
        [self dequeueNextTasksLocked];
        [self.lock unlock];
    }
    if (rawTaskToPause) {
        [self pauseRawTask:rawTaskToPause forItem:item];
    }

    [self postUpdateForTask:item];
    [self checkAggregateStateChange];
    [self schedulePersistSnapshot];
}

- (void)resumeTaskWithId:(NSString *)taskId {
    if (!taskId) return;

    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    if (!item) { [self.lock unlock]; return; }

    DownloadTaskState state = item.state;
    if (state != DownloadTaskStatePaused && state != DownloadTaskStatePending) {
        [self.lock unlock];
        return;
    }

    // App 重启恢复的任务：底层 rawTask 与 retryHandler 均不可恢复，无法真正续传
    if (!item.rawTask && item.needsRecreate && !item.retryHandler) {
        [self.lock unlock];
        NSLog(@"[DownloadTaskManager] resumeTaskWithId: task %@ restored from disk without rawTask/retryHandler, cannot resume", taskId);
        return;
    }

    id rawTask = item.rawTask;

    // NSURLSessionTask 在取消式暂停的 delegate 收尾后可能已释放；rawTask 是 weak，
    // 此时会变成 nil。业务方提供了 retryHandler 时直接重建，避免“继续”把状态
    // 改回 Downloading 却没有任何底层任务在运行。
    if (!rawTask && state == DownloadTaskStatePaused && item.retryHandler) {
        [self removeFromWaitQueueLocked:taskId];
        [self.lock unlock];
        [self deleteResumeDataForItem:item];
        [self retryTaskWithId:taskId];
        return;
    }

    // 底层任务已终止（此前 pause 经 cancelByProducingResumeData: 结束）：
    // resumeData 无业务方 session 归属无法直接复用 → 清除断点，回退 retryHandler 从头下载
    if ([rawTask isKindOfClass:[NSURLSessionTask class]] &&
        ((NSURLSessionTask *)rawTask).state == NSURLSessionTaskStateCompleted) {
        [self removeFromWaitQueueLocked:taskId];
        [self.lock unlock];
        [self deleteResumeDataForItem:item];
        if (item.retryHandler) {
            [self retryTaskWithId:taskId];
        } else {
            // 无 retryHandler 且断点不可用：标记不可续传（UI 隐藏继续按钮）
            item.supportsResume = NO;
            [self postUpdateForTask:item];
            [self schedulePersistSnapshot];
        }
        return;
    }

    // 尝试占用槽位；满则排队等待自动启动（rawTask=nil 任务无底层传输可控，同样排队以保持语义一致）
    if (![self acquireSlotForTaskLocked:taskId]) {
        item.state = DownloadTaskStatePending;
        [self holdRawTaskLocked:item];
        [self enqueueItemLocked:item];
        [self.lock unlock];
        [self postUpdateForTask:item];
        [self checkAggregateStateChange];
        [self schedulePersistSnapshot];
        return;
    }

    [self removeFromWaitQueueLocked:taskId];
    item.state = DownloadTaskStateDownloading;
    item.needsRecreate = NO;
    [self releaseRawTaskHoldLocked:item]; // PLDownloadOperation 走 resumeOperation（内部断点续传）
    [self.lock unlock];

    // 清理我方持久化的陈旧断点数据（底层任务接管续传）
    [self deleteResumeDataForItem:item];

    [self postUpdateForTask:item];
    [self checkAggregateStateChange];
    [self schedulePersistSnapshot];
}

- (void)cancelTaskWithId:(NSString *)taskId {
    if (!taskId) return;

    BOOL didReleaseSlot = NO;
    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    if (!item) { [self.lock unlock]; return; }

    if (item.state == DownloadTaskStateCompleted ||
        item.state == DownloadTaskStateCancelled ||
        item.state == DownloadTaskStateFailed) {
        [self.lock unlock];
        return;
    }

    BOOL wasDownloading = (item.state == DownloadTaskStateDownloading);
    BOOL wasQueued = [self removeFromWaitQueueLocked:taskId];
    id rawTask = item.rawTask;
    item.state = DownloadTaskStateCancelled;
    item.speed = 0.0;
    item.estimatedTimeRemaining = 0.0;
    self.holdCounts[taskId] = nil; // 任务即将取消，挂起计数不再需要平衡

    if (wasDownloading && !wasQueued) {
        // 幂等释放：rawTask=nil 任务未持槽位则跳过，避免信号量超发
        didReleaseSlot = [self taskOwnsSlotLocked:taskId];
        [self releaseSlotForTaskLocked:taskId];
    }
    [self.lock unlock];

    // 取消底层任务（锁外调用；NSURLSessionTask 走 cancel: 不保留 resumeData）
    [self cancelRawTask:rawTask];

    // 清理持久化断点数据
    [self deleteResumeDataForItem:item];

    if (didReleaseSlot) {
        [self.lock lock];
        [self dequeueNextTasksLocked];
        [self.lock unlock];
    }

    [self postUpdateForTask:item];
    [self checkAggregateStateChange];
    [self schedulePersistSnapshot];
}

- (void)retryTaskWithId:(NSString *)taskId {
    if (!taskId) return;

    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    if (!item) { [self.lock unlock]; return; }

    // 重试只允许从可恢复的静止状态进入。否则快速双击“重试”或自动重试与
    // 人工重试重叠时，会同时重建多个 rawTask，较晚返回的旧任务还可能覆盖
    // 新任务，导致后续暂停/取消控制错对象。
    if (item.state != DownloadTaskStateFailed &&
        item.state != DownloadTaskStateCancelled &&
        item.state != DownloadTaskStatePaused) {
        [self.lock unlock];
        return;
    }

    // 无 retryHandler 无法重建
    if (!item.retryHandler) {
        [self.lock unlock];
        NSLog(@"[DownloadTaskManager] retryTaskWithId: task %@ has no retryHandler, cannot retry", taskId);
        return;
    }

    // 超过最大重试次数则不再重试
    if (item.maxRetryCount > 0 && item.retryCount >= item.maxRetryCount) {
        [self.lock unlock];
        NSLog(@"[DownloadTaskManager] retryTaskWithId: task %@ has reached max retry count %ld", taskId, (long)item.maxRetryCount);
        return;
    }

    BOOL wasDownloading = (item.state == DownloadTaskStateDownloading);
    id oldRawTask = item.rawTask;

    // 清理排队/挂起状态
    [self removeFromWaitQueueLocked:taskId];
    self.holdCounts[taskId] = nil;

    // 重置 item 状态（保留 taskId/displayName/iconURL/resourceType 等元数据）
    item.rawTask = nil;
    item.state = DownloadTaskStatePending;
    item.progress = -1.0;
    item.totalSize = -1;
    item.downloadedSize = 0;
    item.speed = 0.0;
    item.estimatedTimeRemaining = 0.0;
    item.errorInfo = nil;
    [item.userInfo removeObjectForKey:DownloadTaskUserInfoTransferCompleteKey];
    item.retryCount += 1;
    item.needsRecreate = NO;

    if (wasDownloading) {
        // 先释放旧任务占用的槽位（幂等：rawTask=nil 任务未持槽位则跳过；
        // retryHandler 重建后的 setTaskWithId:Downloading 可立即占用）
        [self releaseSlotForTaskLocked:taskId];
    }
    [self.lock unlock];

    // 取消旧 rawTask（避免悬挂任务继续下载/上报进度）
    [self cancelRawTask:oldRawTask];

    // 调用业务方 retryHandler 重建底层 rawTask
    // 业务方在 handler 内创建新任务并赋值给 item.rawTask，最后调用 setTaskWithId:state:Downloading 启动
    // （setTaskWithId 内部走并发槽位逻辑：满则排队并挂起新任务）
    @try {
        id newRawTask = item.retryHandler(item);
        if (newRawTask) {
            [self.lock lock];
            item.rawTask = newRawTask;
            [self.lock unlock];
        }
    } @catch (NSException *exception) {
        NSLog(@"[DownloadTaskManager] retryTaskWithId: retryHandler threw exception: %@", exception);
        [self.lock lock];
        item.state = DownloadTaskStateFailed;
        item.errorInfo = [NSError errorWithDomain:@"DownloadTaskManager" code:3
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Retry failed: %@", exception.reason ?: @"Unknown error"]}];
        [self.lock unlock];
        [self postUpdateForTask:item];
        [self checkAggregateStateChange];
        [self schedulePersistSnapshot];
        return;
    }

    [self postUpdateForTask:item];
    [self checkAggregateStateChange];

    // retryHandler 未主动调用 setTaskWithId:Downloading 的兜底：尝试启动
    if (item.state == DownloadTaskStatePending && item.rawTask) {
        [self requestDownloadingStateForItem:item];
    }

    // 释放出的槽位交给排队任务
    if (wasDownloading) {
        [self.lock lock];
        [self dequeueNextTasksLocked];
        [self.lock unlock];
    }
    [self schedulePersistSnapshot];
}

- (void)switchDownloadSourceForTaskId:(NSString *)taskId
                             toSource:(NSString *)source
                           completion:(void (^)(BOOL shouldRecreate, BOOL supportsResume, NSError * _Nullable error))completion {
    if (!completion) return;
    if (!taskId || !source) {
        completion(YES, NO, [NSError errorWithDomain:@"DownloadTaskManager" code:1 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_122", nil)}]);
        return;
    }

    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    if (item) {
        item.downloadSource = [source copy];
    }
    BOOL supportsResume = item.supportsResume;
    [self.lock unlock];

    if (!item) {
        completion(YES, NO, [NSError errorWithDomain:@"DownloadTaskManager" code:2 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_123", nil)}]);
        return;
    }

    [self postUpdateForTask:item];
    [self schedulePersistSnapshot];
    // 当前实现下，运行中的任务无法直接切换 URL，需要调用方重新创建下载。
    // supportsResume 为 YES 时，业务方可尝试断点续传；为 NO 时则需从头开始。
    completion(YES, supportsResume, nil);
}

#pragma mark - Progress / State Reporting

- (void)updateTaskWithId:(NSString *)taskId
                progress:(double)progress
              totalBytes:(int64_t)totalBytes
         downloadedBytes:(int64_t)downloadedBytes {
    if (!taskId) return;

    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    if (item) {
        if (PLDownloadTaskStateIsTerminal(item.state)) {
            [self.lock unlock];
            return; // 忽略终态之后迟到的进度回调
        }
        // 收到全部字节并不等于任务完成：之后还可能校验哈希、原子落盘或解压。
        // 任务进入终态前将可见进度封顶为 99%，避免显示“下载中 100%”。
        BOOL transferComplete = (progress >= 1.0 &&
                                 item.state != DownloadTaskStateCompleted &&
                                 item.state != DownloadTaskStateCancelled &&
                                 item.state != DownloadTaskStateFailed);
        item.progress = transferComplete ? 0.99 : progress;
        if (transferComplete) {
            item.userInfo[DownloadTaskUserInfoTransferCompleteKey] = @YES;
        } else {
            [item.userInfo removeObjectForKey:DownloadTaskUserInfoTransferCompleteKey];
        }
        if (totalBytes >= 0) item.totalSize = totalBytes;
        item.downloadedSize = downloadedBytes;
        if (item.state == DownloadTaskStatePending && ![self isQueuedLocked:taskId]) {
            // 首次进度上报：尝试进入 Downloading（占用槽位；满则排队并挂起底层任务）
            if ([self acquireSlotForTaskLocked:taskId]) {
                item.state = DownloadTaskStateDownloading;
            } else {
                [self holdRawTaskLocked:item];
                [self enqueueItemLocked:item];
            }
        }
        // 排队中的任务保持 Pending，等待槽位释放后由 dequeueNextTasksLocked 启动
    }
    [self.lock unlock];

    if (item) {
        [self postProgressUpdateForTask:item];
        [self checkAggregateStateChange];
        [self schedulePersistSnapshotForProgress];
    }
}

- (void)updateTaskWithId:(NSString *)taskId
                   speed:(double)speed
  estimatedTimeRemaining:(NSTimeInterval)estimatedTimeRemaining {
    if (!taskId) return;
    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    if (item) {
        if (PLDownloadTaskStateIsTerminal(item.state)) {
            [self.lock unlock];
            return;
        }
        item.speed = speed;
        item.estimatedTimeRemaining = estimatedTimeRemaining;
    }
    [self.lock unlock];

    if (item) [self postProgressUpdateForTask:item];
}

- (void)updateTaskWithId:(NSString *)taskId
      completedFileCount:(NSInteger)completedFileCount
          totalFileCount:(NSInteger)totalFileCount {
    if (!taskId) return;
    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    if (item) {
        item.completedFileCount = MAX(0, completedFileCount);
        item.totalFileCount = MAX(0, totalFileCount);
    }
    [self.lock unlock];

    if (item) {
        [self postProgressUpdateForTask:item];
        [self schedulePersistSnapshotForProgress];
    }
}

- (void)setTaskWithId:(NSString *)taskId state:(DownloadTaskState)state {
    if (!taskId) return;

    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    if (!item) { [self.lock unlock]; return; }

    DownloadTaskState oldState = item.state;

    // 终态不可逆。显式重试会在 retryTaskWithId: 内先直接重置为 Pending，
    // 因此不会被这里拦截；迟到的启动/暂停回调则不能把完成任务写回下载中。
    if (PLDownloadTaskStateIsTerminal(oldState)) {
        [self.lock unlock];
        return;
    }

    // 防御：manager 主动 pause/cancel（cancelByProducingResumeData / cancel）后，
    // 业务方 session delegate 会收到 NSURLErrorCancelled 并上报 Failed——此时保持 Paused/Cancelled 不被覆盖
    if (state == DownloadTaskStateFailed &&
        (oldState == DownloadTaskStatePaused || oldState == DownloadTaskStateCancelled) &&
        (![item.errorInfo isKindOfClass:[NSError class]] || [self isErrorPureCancellation:item.errorInfo])) {
        item.errorInfo = nil;
        [self.lock unlock];
        return;
    }

    if (state == DownloadTaskStateDownloading) {
        [self.lock unlock];
        // 走并发槽位逻辑（满则排队保持 Pending）
        [self requestDownloadingStateForItem:item];
        return;
    }

    item.state = state;
    if (state != DownloadTaskStateDownloading) {
        [item.userInfo removeObjectForKey:DownloadTaskUserInfoTransferCompleteKey];
    }
    [self removeFromWaitQueueLocked:taskId];
    self.holdCounts[taskId] = nil;

    BOOL needDequeue = NO;
    if (oldState == DownloadTaskStateDownloading && state != DownloadTaskStateDownloading) {
        item.speed = 0.0;
        // 幂等释放：rawTask=nil 任务未持槽位则跳过，避免信号量超发
        needDequeue = [self taskOwnsSlotLocked:taskId];
        [self releaseSlotForTaskLocked:taskId];
    }
    [self.lock unlock];

    if (needDequeue) {
        [self.lock lock];
        [self dequeueNextTasksLocked];
        [self.lock unlock];
    }

    [self postUpdateForTask:item];
    [self checkAggregateStateChange];
    [self schedulePersistSnapshot];
}

- (void)setTaskWithId:(NSString *)taskId completedWithError:(nullable NSError *)error {
    if (!taskId) return;

    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    if (!item) { [self.lock unlock]; return; }
    if (PLDownloadTaskStateIsTerminal(item.state)) {
        [self.lock unlock];
        return;
    }

    // 防御：同 setTaskWithId:state:，抑制 cancelByProducingResumeData 触发的残留失败上报
    if (error &&
        (item.state == DownloadTaskStatePaused || item.state == DownloadTaskStateCancelled) &&
        [self isErrorPureCancellation:error]) {
        item.errorInfo = nil;
        [self.lock unlock];
        return;
    }

    BOOL wasDownloading = (item.state == DownloadTaskStateDownloading);
    [self removeFromWaitQueueLocked:taskId];
    self.holdCounts[taskId] = nil;

    if (error) {
        item.state = DownloadTaskStateFailed;
        item.errorInfo = error;
        item.speed = 0.0;
        item.estimatedTimeRemaining = 0.0;
    } else {
        item.state = DownloadTaskStateCompleted;
        item.progress = 1.0;
        item.errorInfo = nil;
        item.speed = 0.0;
        item.estimatedTimeRemaining = 0.0;
    }
    [item.userInfo removeObjectForKey:DownloadTaskUserInfoTransferCompleteKey];

    BOOL didReleaseSlot = NO;
    if (wasDownloading) {
        // 幂等释放：rawTask=nil 任务未持槽位则跳过，避免信号量超发
        didReleaseSlot = [self taskOwnsSlotLocked:taskId];
        [self releaseSlotForTaskLocked:taskId];
    }
    [self.lock unlock];

    if (didReleaseSlot) {
        [self.lock lock];
        [self dequeueNextTasksLocked];
        [self.lock unlock];
    }

    if (!error) {
        // 成功完成：写一条下载历史
        [self.historyStore recordEntryWithDictionary:[item historyDictionary]];
        [self deleteResumeDataForItem:item];
    } else if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == PLNSURLErrorCannotResume) {
        // 断点续传失效：自动清除断点数据并回退 retryHandler 从头下载
        [self deleteResumeDataForItem:item];
        if (item.retryHandler) {
            [self retryTaskWithId:taskId];
            return; // retry 内部已处理通知与持久化
        }
    }

    [self postUpdateForTask:item];
    [self postCompletionForTask:item];
    [self checkAggregateStateChange];
    [self schedulePersistSnapshot];
}

- (void)updateTaskWithId:(NSString *)taskId error:(nullable NSError *)error {
    if (!taskId) return;
    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    if (item) item.errorInfo = error ?: item.errorInfo;
    [self.lock unlock];

    if (item) [self postUpdateForTask:item];
}

#pragma mark - 阶段上报（redesign-download-ui Phase 1）

/// 锁内辅助：取出任务指定下标的阶段（item 不存在 / index 越界 / 类型非法时返回 nil）
- (PLTaskStage *)stageForItem:(DownloadTaskItem *)item atIndex:(NSUInteger)index {
    if (!item || index >= item.stages.count) return nil;
    PLTaskStage *stage = item.stages[index];
    return [stage isKindOfClass:[PLTaskStage class]] ? stage : nil;
}

- (void)setTaskWithId:(NSString *)taskId stages:(NSArray<PLTaskStage *> *)stages {
    if (!taskId) return;

    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    if (item) {
        // 过滤非法对象，保证 stages 内全部为 PLTaskStage
        NSMutableArray *valid = [NSMutableArray array];
        for (PLTaskStage *stage in stages) {
            if ([stage isKindOfClass:[PLTaskStage class]]) {
                [valid addObject:stage];
            }
        }
        item.stages = [valid copy];
        // 阶段列表非空时当前阶段指向第一个；空列表回退纯进度展示
        item.currentStageIndex = item.stages.count > 0 ? 0 : -1;
    }
    [self.lock unlock];

    if (item) {
        [self postUpdateForTask:item];
        [self schedulePersistSnapshot];
    }
}

- (void)updateTaskWithId:(NSString *)taskId
           stageAtIndex:(NSUInteger)index
                 status:(PLTaskStageStatus)status {
    if (!taskId) return;

    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    PLTaskStage *stage = [self stageForItem:item atIndex:index];
    BOOL ignoredTerminal = (stage && PLDownloadTaskStateIsTerminal(item.state) && status == PLTaskStageStatusRunning);
    if (stage && !ignoredTerminal) {
        stage.status = status;
    }
    [self.lock unlock];

    if (stage && !ignoredTerminal) {
        [self postUpdateForTask:item];
        [self schedulePersistSnapshot];
    } else if (item && !ignoredTerminal) {
        NSLog(@"[DownloadTaskManager] updateTaskWithId:stageAtIndex:status: invalid stage index %lu for task %@", (unsigned long)index, taskId);
    }
}

- (void)updateTaskWithId:(NSString *)taskId
           stageAtIndex:(NSUInteger)index
                progress:(double)progress
                message:(nullable NSString *)message {
    if (!taskId) return;

    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    PLTaskStage *stage = [self stageForItem:item atIndex:index];
    BOOL ignoredTerminal = (stage && PLDownloadTaskStateIsTerminal(item.state));
    if (stage && !ignoredTerminal) {
        BOOL transferComplete = (progress >= 1.0 &&
                                 stage.status == PLTaskStageStatusRunning &&
                                 item.state != DownloadTaskStateCompleted &&
                                 item.state != DownloadTaskStateCancelled &&
                                 item.state != DownloadTaskStateFailed);
        stage.progress = transferComplete ? 0.99 : progress;
        if (message) stage.message = [message copy]; // nil 表示保留原文案
    }
    [self.lock unlock];

    if (stage && !ignoredTerminal) {
        [self postProgressUpdateForTask:item];
        [self schedulePersistSnapshotForProgress];
    } else if (item && !ignoredTerminal) {
        NSLog(@"[DownloadTaskManager] updateTaskWithId:stageAtIndex:progress:message: invalid stage index %lu for task %@", (unsigned long)index, taskId);
    }
}

- (void)updateTaskWithId:(NSString *)taskId
           stageAtIndex:(NSUInteger)index
                   rate:(double)rate {
    if (!taskId) return;

    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    PLTaskStage *stage = [self stageForItem:item atIndex:index];
    if (stage) stage.rateBytesPerSec = rate;
    [self.lock unlock];

    // 速率为瞬时值，不触发快照持久化（与 updateTaskWithId:speed: 一致）
    if (stage) {
        [self postProgressUpdateForTask:item];
    } else if (item) {
        NSLog(@"[DownloadTaskManager] updateTaskWithId:stageAtIndex:rate: invalid stage index %lu for task %@", (unsigned long)index, taskId);
    }
}

- (void)updateTaskWithId:(NSString *)taskId
           stageAtIndex:(NSUInteger)index
              fileCount:(NSInteger)completedFileCount
          totalFileCount:(NSInteger)totalFileCount {
    if (!taskId) return;

    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    PLTaskStage *stage = [self stageForItem:item atIndex:index];
    if (stage) {
        stage.completedFileCount = MAX(0, completedFileCount);
        stage.totalFileCount = MAX(0, totalFileCount);
    }
    [self.lock unlock];

    if (stage) {
        [self postProgressUpdateForTask:item];
        [self schedulePersistSnapshotForProgress];
    } else if (item) {
        NSLog(@"[DownloadTaskManager] updateTaskWithId:stageAtIndex:fileCount:totalFileCount: invalid stage index %lu for task %@", (unsigned long)index, taskId);
    }
}

- (void)updateTaskWithId:(NSString *)taskId
      currentStageIndex:(NSInteger)currentStageIndex {
    if (!taskId) return;

    BOOL updated = NO;
    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    if (item && currentStageIndex >= 0 && (NSUInteger)currentStageIndex < item.stages.count) {
        item.currentStageIndex = currentStageIndex;
        updated = YES;
    }
    [self.lock unlock];

    if (updated) {
        [self postUpdateForTask:item];
        [self schedulePersistSnapshot];
    } else if (item) {
        NSLog(@"[DownloadTaskManager] updateTaskWithId:currentStageIndex: invalid index %ld for task %@", (long)currentStageIndex, taskId);
    }
}

#pragma mark - 并发 / 断点查询（Phase 2 新增公开接口）

- (NSInteger)pendingQueueCount {
    [self.lock lock];
    NSInteger count = self.waitQueue.count;
    [self.lock unlock];
    return count;
}

- (nullable NSData *)storedResumeDataForTaskId:(NSString *)taskId {
    if (!taskId) return nil;
    return [NSData dataWithContentsOfFile:[self resumeDataPathForTaskId:taskId]];
}

#pragma mark - 底层任务控制（锁外调用）

/// 判断是否为"用户/manager 主动取消"产生的残留错误
- (BOOL)isErrorPureCancellation:(NSError *)error {
    return [error isKindOfClass:[NSError class]] &&
           [error.domain isEqualToString:NSURLErrorDomain] &&
           error.code == NSURLErrorCancelled;
}

/// 暂停 NSURLSessionDownloadTask 底层任务（真断点续传）：
/// cancelByProducingResumeData: 后将 resumeData 持久化到
/// <Home>/Library/Caches/PLDownloadResumeData/<taskId>.resume。
/// PLDownloadOperation / 自定义对象的暂停已由 holdRawTaskLocked: 在锁内处理。
- (void)pauseRawTask:(id)rawTask forItem:(DownloadTaskItem *)item {
    if (!rawTask || !item) return;

    if ([rawTask isKindOfClass:[NSURLSessionDownloadTask class]]) {
        // cancelByProducingResumeData: 声明在 NSURLSessionDownloadTask 上，需按该类型调用
        NSURLSessionDownloadTask *task = (NSURLSessionDownloadTask *)rawTask;
        if (task.state == NSURLSessionTaskStateRunning || task.state == NSURLSessionTaskStateSuspended) {
            NSString *taskId = [item.taskId copy];
            [task cancelByProducingResumeData:^(NSData *resumeData) {
                // session delegate queue 回调
                [self handleResumeData:resumeData forTaskId:taskId];
            }];
        }
        return;
    }

    // 防御性回退（正常流程不会到达）
    if ([rawTask respondsToSelector:@selector(suspend)]) {
        [rawTask suspend];
    }
}

/// cancelByProducingResumeData: 回调：落盘/清除断点数据并修正 supportsResume
- (void)handleResumeData:(NSData *)resumeData forTaskId:(NSString *)taskId {
    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    BOOL stillPaused = (item.state == DownloadTaskStatePaused);
    [self.lock unlock];

    if (!item) return;

    if (!stillPaused) {
        // 回调到达前任务状态已变化（如用户快速点击继续）：清除断点数据避免陈旧
        if (resumeData.length > 0) {
            [self deleteResumeDataFileForTaskId:taskId];
        }
        return;
    }

    if (resumeData.length > 0) {
        [self persistResumeData:resumeData forItem:item];
        item.supportsResume = YES;
    } else {
        // 服务器不支持断点续传：无可恢复数据，仅剩 retryHandler 重下能力
        [self deleteResumeDataFileForTaskId:taskId];
        item.resumeDataPath = nil;
        if (!item.retryHandler) {
            item.supportsResume = NO;
        }
    }

    [self postUpdateForTask:item];
    [self schedulePersistSnapshot];
}

/// 取消底层任务
- (void)cancelRawTask:(id)rawTask {
    if (!rawTask) return;
    if ([rawTask isKindOfClass:[PLDownloadOperation class]]) {
        // 内部同时清理 resumeData 与 .part 半成品文件
        [[PLDownloadClient sharedClient] cancelOperation:rawTask];
    } else if ([rawTask isKindOfClass:[NSOperation class]]) {
        [(NSOperation *)rawTask cancel];
    } else if ([rawTask respondsToSelector:@selector(cancel)]) {
        [rawTask cancel];
    }
}

#pragma mark - resumeData 持久化

/// resumeData 原子落盘（ioQueue），并记录 item.resumeDataPath
- (void)persistResumeData:(NSData *)resumeData forItem:(DownloadTaskItem *)item {
    if (resumeData.length == 0 || !item) return;
    NSString *path = [self resumeDataPathForTaskId:item.taskId];
    item.resumeDataPath = path; // 先记录路径，文件异步写入

    dispatch_async(self.ioQueue, ^{
        NSString *directory = [path stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSError *error = nil;
        if (![resumeData writeToFile:path options:NSDataWritingAtomic error:&error]) {
            NSLog(@"[DownloadTaskManager] Failed to persist resumeData for task %@: %@", item.taskId, error.localizedDescription);
        }
    });
}

/// 删除任务的持久化断点数据（ioQueue），并清空 item.resumeDataPath
- (void)deleteResumeDataForItem:(DownloadTaskItem *)item {
    if (!item) return;
    item.resumeDataPath = nil;
    [self deleteResumeDataFileForTaskId:item.taskId];
}

- (void)deleteResumeDataFileForTaskId:(NSString *)taskId {
    if (!taskId) return;
    dispatch_async(self.ioQueue, ^{
        [[NSFileManager defaultManager] removeItemAtPath:[self resumeDataPathForTaskId:taskId] error:nil];
    });
}

#pragma mark - 任务快照持久化

/// 状态变化后调度快照写盘（debounce 0.5s 合并高频变化）
- (void)schedulePersistSnapshot {
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.ioQueue, ^{
        DownloadTaskManager *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf cancelPendingPersistOnQueue];
        // block 内捕获 weakSelf：避免 self -> pendingPersistBlock -> self 循环 retain
        dispatch_block_t block = dispatch_block_create(0, ^{
            [weakSelf writeSnapshotNowOnQueue];
        });
        strongSelf.pendingPersistBlock = block;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSnapshotDebounceInterval * NSEC_PER_SEC)),
                       strongSelf.ioQueue, block);
    });
}

/// 进度上报触发的快照写盘（节流：距上次写盘 >= 3s 立即写，避免长下载期间 debounce 永不触发）
- (void)schedulePersistSnapshotForProgress {
    dispatch_async(self.ioQueue, ^{
        NSTimeInterval sinceLastWrite = self.lastPersistDate
            ? -[self.lastPersistDate timeIntervalSinceNow]
            : (kSnapshotProgressThrottleInterval + 1.0); // 从未写过：视为已超阈值
        if (sinceLastWrite >= kSnapshotProgressThrottleInterval) {
            [self cancelPendingPersistOnQueue];
            [self writeSnapshotNowOnQueue];
            return;
        }
        if (!self.pendingPersistBlock) {
            [self schedulePersistSnapshot];
        }
    });
}

/// 取消 debounce 中的待写 block（仅在 ioQueue 上调用）
- (void)cancelPendingPersistOnQueue {
    if (self.pendingPersistBlock) {
        dispatch_block_cancel(self.pendingPersistBlock);
        self.pendingPersistBlock = nil;
    }
}

/// 立即写快照（仅在 ioQueue 上调用）
- (void)writeSnapshotNowOnQueue {
    // debounce block 已执行：清掉暂存引用（避免长期持有已完成的 block）
    self.pendingPersistBlock = nil;
    [self.lock lock];
    NSArray<DownloadTaskItem *> *items = [self.tasks.allValues copy];
    [self.lock unlock];

    // 按创建时间升序排序，保证快照顺序稳定
    NSMutableArray<DownloadTaskItem *> *sorted = [NSMutableArray arrayWithArray:items];
    [sorted sortUsingComparator:^NSComparisonResult(DownloadTaskItem *a, DownloadTaskItem *b) {
        return [a.createdDate compare:b.createdDate];
    }];

    NSMutableArray<NSDictionary *> *snapshots = [NSMutableArray array];
    for (DownloadTaskItem *item in sorted) {
        [snapshots addObject:[item snapshotDictionary]];
    }

    NSString *path = [self tasksSnapshotPath];
    NSString *directory = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    NSData *data = [NSJSONSerialization dataWithJSONObject:snapshots
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    if (data) {
        [data writeToFile:path options:NSDataWritingAtomic error:nil];
    } else {
        // 序列化失败：删除损坏文件（下次写盘重建）
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    self.lastPersistDate = [NSDate date];
}

/// 启动时从磁盘恢复任务列表：
/// - Downloading/Pending → Paused + needsRecreate（底层任务不可恢复）
/// - Paused/Failed → 保留状态 + needsRecreate
/// - Completed → 转入历史 store，不进入活动列表
/// - Cancelled → 丢弃
/// retryHandler 闭包不可序列化：恢复的任务无 retryHandler，supportsResume 置 NO（UI 继续按钮置灰），
/// 状态仍可见；有 resumeDataPath 的保留路径引用。
- (void)restoreTasksFromDisk {
    NSMutableArray<DownloadTaskItem *> *restored = [NSMutableArray array];
    NSMutableArray<DownloadTaskItem *> *completedItems = [NSMutableArray array];

    dispatch_sync(self.ioQueue, ^{
        NSString *path = [self tasksSnapshotPath];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data.length == 0) return;

        id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![object isKindOfClass:[NSArray class]]) {
            // 损坏文件：删除重建
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            return;
        }

        NSFileManager *fileManager = [NSFileManager defaultManager];
        for (id entry in (NSArray *)object) {
            if (![entry isKindOfClass:[NSDictionary class]]) continue;
            DownloadTaskItem *item = [[DownloadTaskItem alloc] initWithSnapshotDictionary:entry];
            if (!item) continue;

            switch (item.state) {
                case DownloadTaskStateDownloading:
                case DownloadTaskStatePending:
                    item.state = DownloadTaskStatePaused;
                    item.speed = 0.0;
                    item.needsRecreate = YES;
                    item.retryHandler = nil;
                    item.supportsResume = NO;
                    [self validateResumeDataReferenceForItem:item fileManager:fileManager];
                    [restored addObject:item];
                    break;
                case DownloadTaskStatePaused:
                case DownloadTaskStateFailed:
                    item.needsRecreate = YES;
                    item.retryHandler = nil;
                    item.supportsResume = NO;
                    [self validateResumeDataReferenceForItem:item fileManager:fileManager];
                    [restored addObject:item];
                    break;
                case DownloadTaskStateCompleted:
                    [completedItems addObject:item];
                    break;
                case DownloadTaskStateCancelled:
                    break; // 已取消任务无恢复意义
            }
        }
    });

    if (restored.count == 0 && completedItems.count == 0) return;

    // Completed 项转入历史 store
    for (DownloadTaskItem *item in completedItems) {
        [self.historyStore recordEntryWithDictionary:[item historyDictionary]];
    }

    // 恢复活动任务并立即重写快照（移除已完成/已取消项）
    if (restored.count > 0) {
        [self.lock lock];
        for (DownloadTaskItem *item in restored) {
            self.tasks[item.taskId] = item;
        }
        [self.lock unlock];
    }

    dispatch_async(self.ioQueue, ^{
        [self writeSnapshotNowOnQueue];
    });
}

/// 恢复时校验 resumeData 文件是否仍存在（Caches 可能被系统清理），不存在则清空引用
- (void)validateResumeDataReferenceForItem:(DownloadTaskItem *)item fileManager:(NSFileManager *)fileManager {
    if (item.resumeDataPath.length > 0 && ![fileManager fileExistsAtPath:item.resumeDataPath]) {
        item.resumeDataPath = nil;
    }
}

#pragma mark - Notifications

/// 主队列内直接执行：发送任务更新通知 + autoPresentDetail 自动弹出处理
- (void)postUpdateNotificationOnMainThreadForTaskItem:(DownloadTaskItem *)item {
    NSAssert([NSThread isMainThread], @"must be called on main thread");
    [[NSNotificationCenter defaultCenter] postNotificationName:DownloadTaskManagerDidUpdateTaskNotification
                                                        object:self
                                                      userInfo:@{DownloadTaskManagerTaskKey: item}];

    // 自动弹出统一进度页（redesign-download-ui Task 2.3）：
    // 安装类任务标记 autoPresentDetail 后，在首次非终态更新时自动弹出；
    // 仅弹一次（最小化后进度更新不再打扰），同屏仅一个进度页由
    // PLTaskProgressViewController.presentForTaskId: 保证（新任务替换内容）。
    if (item.autoPresentDetail && ![self.autoPresentedTaskIds containsObject:item.taskId]) {
        [self.autoPresentedTaskIds addObject:item.taskId];
        BOOL terminal = (item.state == DownloadTaskStateCompleted ||
                         item.state == DownloadTaskStateCancelled ||
                         item.state == DownloadTaskStateFailed);
        // 任务仍存在（未被移除）且未到终态才弹出（防止移除通知误触发）
        if (!terminal && [self taskWithId:item.taskId] != nil) {
            [PLTaskProgressViewController presentForTaskId:item.taskId];
        }
    }
}

- (void)postUpdateForTask:(DownloadTaskItem *)item {
    if (!item) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self postUpdateNotificationOnMainThreadForTaskItem:item];
    });
}

/// 进度类更新（progress/speed/rate/fileCount/stage进度）专用：
/// 按 kUIProgressNotifyThrottleInterval 节流合并 UI 通知，避免高频回调刷爆主队列。
/// 终态任务直接立即通知（不走节流，确保完成/失败状态第一时间可见）。
- (void)postProgressUpdateForTask:(DownloadTaskItem *)item {
    if (!item) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL terminal = (item.state == DownloadTaskStateCompleted ||
                         item.state == DownloadTaskStateCancelled ||
                         item.state == DownloadTaskStateFailed);
        if (terminal) {
            [self.lastProgressNotifyDates removeObjectForKey:item.taskId];
            [self.pendingProgressNotifyTaskIds removeObject:item.taskId];
            [self postUpdateNotificationOnMainThreadForTaskItem:item];
            return;
        }

        NSDate *last = self.lastProgressNotifyDates[item.taskId];
        NSDate *now = [NSDate date];
        if (!last || [now timeIntervalSinceDate:last] >= kUIProgressNotifyThrottleInterval) {
            self.lastProgressNotifyDates[item.taskId] = now;
            [self postUpdateNotificationOnMainThreadForTaskItem:item];
            return;
        }

        // 节流窗口内：安排一次补发（携带补发时刻的最新任务数据），避免末尾进度被吞
        if ([self.pendingProgressNotifyTaskIds containsObject:item.taskId]) return;
        [self.pendingProgressNotifyTaskIds addObject:item.taskId];
        NSTimeInterval delay = kUIProgressNotifyThrottleInterval - [now timeIntervalSinceDate:last];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self.pendingProgressNotifyTaskIds removeObject:item.taskId];
            // 重新取最新 item：任务可能已推进/移除
            DownloadTaskItem *latest = [self taskWithId:item.taskId];
            if (latest) {
                self.lastProgressNotifyDates[latest.taskId] = [NSDate date];
                [self postUpdateNotificationOnMainThreadForTaskItem:latest];
            } else {
                [self.lastProgressNotifyDates removeObjectForKey:item.taskId];
            }
        });
    });
}

- (void)postCompletionForTask:(DownloadTaskItem *)item {
    if (!item) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DownloadTaskManagerTaskCompletedNotification
                                                            object:self
                                                          userInfo:@{DownloadTaskManagerTaskKey: item}];
    });
}

- (void)checkAggregateStateChange {
    DownloadTaskAggregateState newState = [self currentAggregateState];
    if (newState != self.lastAggregateState) {
        self.lastAggregateState = newState;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:DownloadTaskManagerAggregateStateDidChangeNotification
                                                                object:self
                                                              userInfo:@{@"aggregateState": @(newState)}];
        });
    }
}

@end
