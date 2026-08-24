#import "utils.h"
//
//  ResourcePackService.m
//  Amethyst
//
//  资源包服务实现，结构参照 ShaderService/ModService
//  API 签名统一使用 NSString *profileName
//  修改：文件下载改走 PLDownloadClient 统一下载器（镜像候选 + SHA1 校验 + 增量下载 + 断点续传），
//        移除自建 NSURLSession 下载 delegate（spec optimize-download-system Task 4.2 / 5.1 / 5.2）
//  实现 pack.mcmeta 解析（pack_format / description）
//

#import "ResourcePackService.h"
#import <CommonCrypto/CommonCrypto.h>
#import <UIKit/UIKit.h>
#import "PLProfiles.h"
#import "ResourcePackItem.h"
#import "UZKArchive.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "PLTaskStages.h"
#import "LauncherPreferences.h"
#import "PLDownloadClient.h"
#import "PLMirrorCenter.h"

@interface ResourcePackService ()
// ---- PLDownloadClient 下载跟踪（key = DownloadTaskItem.taskId，即 PLDownloadRequest.taskIdentifier）----
@property (nonatomic, strong) NSLock *downloadStateLock;
@property (nonatomic, strong) NSMutableDictionary<NSString *, DownloadTaskItem *> *downloadTaskItems;
// 强持有当前 operation：pause 后 PLDownloadClient 会移除内部 task 映射，
// 需由 Service 保活，DownloadTaskManager 的 rawTask（weak）才能继续 pause/resume
@property (nonatomic, strong) NSMutableDictionary<NSString *, PLDownloadOperation *> *downloadOperations;
// 重试代数：retryHandler 重建请求后旧 operation 的迟到回调（如取消）按此丢弃
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *downloadGenerations;
// 进度累计（PLDownloadClient 为 delta 语义，含镜像切换/重试的负 delta 回退，直接累加即可）
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *downloadAccumulatedBytes;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *downloadTotalBytes;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *downloadLastSpeeds;
// 请求描述缓存：retryHandler 复用同一请求（同 taskIdentifier 可复用断点语义）
@property (nonatomic, strong) NSMutableDictionary<NSString *, PLDownloadRequest *> *downloadRequests;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ResourcePackDownloadProgressHandler> *downloadProgressHandlers;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ResourcePackDownloadCompletionHandler> *downloadCompletionHandlers;
@end

@implementation ResourcePackService

+ (instancetype)sharedService {
    static ResourcePackService *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [[ResourcePackService alloc] init];
    });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        _onlineSearchEnabled = NO;

        // 下载已改走 [PLDownloadClient sharedClient]（镜像候选 + SHA1 校验 + 断点续传），
        // 不再自建 NSURLSession download delegate
        _downloadStateLock = [[NSLock alloc] init];
        _downloadTaskItems = [NSMutableDictionary dictionary];
        _downloadOperations = [NSMutableDictionary dictionary];
        _downloadGenerations = [NSMutableDictionary dictionary];
        _downloadAccumulatedBytes = [NSMutableDictionary dictionary];
        _downloadTotalBytes = [NSMutableDictionary dictionary];
        _downloadLastSpeeds = [NSMutableDictionary dictionary];
        _downloadRequests = [NSMutableDictionary dictionary];
        _downloadProgressHandlers = [NSMutableDictionary dictionary];
        _downloadCompletionHandlers = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - 工具方法

// 计算 URL 字符串的 SHA1，用作图标缓存文件名
- (NSString *)iconCachePathForURL:(NSString *)urlString {
    if (!urlString) return nil;
    NSString *cacheDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    NSString *folder = [cacheDir stringByAppendingPathComponent:@"resourcepack_icons"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:folder]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    }
    const char *cstr = [urlString UTF8String];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(cstr, (CC_LONG)strlen(cstr), digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [folder stringByAppendingPathComponent:hex];
}

// 从 zip 中读取指定条目的数据
- (nullable NSData *)readFileFromZip:(NSString *)zipPath entryName:(NSString *)entryName {
    if (!zipPath || !entryName) return nil;
    NSError *err = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:zipPath error:&err];
    if (!archive || err) return nil;
    NSData *data = [archive extractDataFromFile:entryName error:&err];
    return data;
}

// 解析 pack.mcmeta，提取 pack_format 和 description
- (void)parsePackMcmetaForItem:(ResourcePackItem *)item {
    if (!item.filePath) return;
    NSData *mcmetaData = [self readFileFromZip:item.filePath entryName:@"pack.mcmeta"];
    if (!mcmetaData) return;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:mcmetaData options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *pack = json[@"pack"];
    if (![pack isKindOfClass:[NSDictionary class]]) return;

    id packFormatValue = pack[@"pack_format"];
    if ([packFormatValue isKindOfClass:[NSNumber class]]) {
        item.packFormat = packFormatValue;
    } else if ([packFormatValue respondsToSelector:@selector(integerValue)]) {
        item.packFormat = @([packFormatValue integerValue]);
    }

    id descValue = pack[@"description"];
    if ([descValue isKindOfClass:[NSString class]]) {
        item.resourcePackDescription = descValue;
    } else if ([descValue respondsToSelector:@selector(description)]) {
        item.resourcePackDescription = [descValue description];
    }
}

#pragma mark - ResourcePacks folder detection & scan

// 查找指定 profile 的 resourcepacks 目录（已存在时返回路径，否则返回 nil）
- (nullable NSString *)existingResourcePacksFolderForProfile:(NSString *)profileName {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *gameDir = [PLProfiles resolvedGameDirectoryForProfileName:profileName];
    if (gameDir.length == 0) return nil;
    NSString *resourcePacksPath = [gameDir stringByAppendingPathComponent:@"resourcepacks"];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:resourcePacksPath isDirectory:&isDir] && isDir) return resourcePacksPath;
    return nil;
}

/// 获取当前 profile 的 resourcepacks 目录，不存在时自动创建
- (nullable NSString *)ensureResourcePacksFolderForProfile:(NSString *)profileName error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *gameDir = [PLProfiles resolvedGameDirectoryForProfileName:profileName];
    NSString *resourcePacksPath = [gameDir stringByAppendingPathComponent:@"resourcepacks"];

    if (!resourcePacksPath) {
        if (error) {
            *error = [NSError errorWithDomain:@"ResourcePackService" code:1 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_105", nil)}];
        }
        return nil;
    }

    BOOL isDir = NO;
    if (![fm fileExistsAtPath:resourcePacksPath isDirectory:&isDir]) {
        NSError *createError = nil;
        [fm createDirectoryAtPath:resourcePacksPath withIntermediateDirectories:YES attributes:nil error:&createError];
        if (createError) {
            if (error) *error = createError;
            return nil;
        }
        NSLog(@"[ResourcePackService] Created resourcepacks directory: %@", resourcePacksPath);
    } else if (!isDir) {
        if (error) {
            *error = [NSError errorWithDomain:@"ResourcePackService" code:2 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_451", nil), resourcePacksPath]}];
        }
        return nil;
    }
    return resourcePacksPath;
}

- (void)scanResourcePacksForProfile:(NSString *)profileName completion:(ResourcePackListHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *resourcePacksFolder = [self existingResourcePacksFolderForProfile:profileName];
        NSMutableArray<ResourcePackItem *> *items = [NSMutableArray array];

        if (!resourcePacksFolder) {
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(items); });
            }
            return;
        }

        NSArray<NSString *> *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:resourcePacksFolder error:nil];
        dispatch_group_t group = dispatch_group_create();

        for (NSString *fileName in contents) {
            if ([fileName.lowercaseString hasSuffix:@".zip"] || [fileName.lowercaseString hasSuffix:@".zip.disabled"]) {
                NSString *fullPath = [resourcePacksFolder stringByAppendingPathComponent:fileName];
                ResourcePackItem *resourcePack = [[ResourcePackItem alloc] initWithFilePath:fullPath];
                [items addObject:resourcePack];

                dispatch_group_enter(group);
                [self fetchMetadataForResourcePack:resourcePack completion:^(ResourcePackItem *populatedItem, NSError * _Nullable error) {
                    dispatch_group_leave(group);
                }];
            }
        }

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            [items sortUsingComparator:^NSComparisonResult(ResourcePackItem *obj1, ResourcePackItem *obj2) {
                NSString *name1 = obj1.displayName ?: obj1.fileName;
                NSString *name2 = obj2.displayName ?: obj2.fileName;
                return [name1 localizedCaseInsensitiveCompare:name2];
            }];

            if (completion) {
                completion(items);
            }
        });
    });
}

#pragma mark - Metadata fetch

// 解析 zip 内的 pack.mcmeta，获取 pack_format 和 description
- (void)fetchMetadataForResourcePack:(ResourcePackItem *)item completion:(ResourcePackMetadataHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try {
            [self parsePackMcmetaForItem:item];
        } @catch (NSException *exception) {
            NSLog(@"[ResourcePackService] Exception parsing pack.mcmeta %@: %@", item.fileName, exception);
        }
        if (completion) completion(item, nil);
    });
}

#pragma mark - File operations

// 启用/禁用资源包：通过加/去 .disabled 后缀实现
- (BOOL)toggleEnableForResourcePack:(ResourcePackItem *)item error:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *currentPath = item.filePath;
    NSString *newPath;

    if (item.disabled) {
        if ([currentPath.lowercaseString hasSuffix:@".zip.disabled"]) {
            newPath = [currentPath substringToIndex:currentPath.length - [@".disabled" length]];
        } else {
            if (error) *error = [NSError errorWithDomain:@"ResourcePackServiceError" code:101 userInfo:@{NSLocalizedDescriptionKey:localize(@"i18n_str_452", nil)}];
            return NO;
        }
    } else {
        newPath = [currentPath stringByAppendingString:@".disabled"];
    }

    BOOL success = [fileManager moveItemAtPath:currentPath toPath:newPath error:error];
    if (success) {
        item.filePath = newPath;
        item.fileName = [newPath lastPathComponent];
        [item refreshDisabledFlag];
    }

    return success;
}

// 删除资源包文件
- (BOOL)deleteResourcePack:(ResourcePackItem *)item error:(NSError **)error {
    return [[NSFileManager defaultManager] removeItemAtPath:item.filePath error:error];
}

#pragma mark - Online ResourcePack Downloading（PLDownloadClient 统一下载器）

// 带实时进度回调的下载方法
- (void)downloadResourcePack:(ResourcePackItem *)item
                   toProfile:(NSString *)profileName
                    progress:(ResourcePackDownloadProgressHandler _Nullable)progress
                  completion:(ResourcePackDownloadCompletionHandler _Nullable)completion {
    [self downloadResourcePack:item toProfile:profileName expectedSHA1:nil progress:progress completion:completion];
}

// ---------- 带 SHA1 校验的下载（spec Task 5.1：expectedSHA1 传入即启用校验）----------
- (void)downloadResourcePack:(ResourcePackItem *)item
                   toProfile:(NSString *)profileName
                expectedSHA1:(nullable NSString *)expectedSHA1
                    progress:(ResourcePackDownloadProgressHandler _Nullable)progress
                  completion:(ResourcePackDownloadCompletionHandler _Nullable)completion {
    // 确保 resourcepacks 目录存在
    NSError *folderError = nil;
    NSString *resourcePacksFolder = [self ensureResourcePacksFolderForProfile:profileName error:&folderError];
    if (!resourcePacksFolder) {
        if (completion) {
            NSError *error = folderError ?: [NSError errorWithDomain:@"ResourcePackServiceError"
                                                              code:1
                                                          userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_106", nil)}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
        }
        return;
    }

    // 校验下载链接
    NSURL *url = [NSURL URLWithString:item.selectedVersionDownloadURL];
    if (!url) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"ResourcePackServiceError"
                                                 code:2
                                             userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_454", nil)}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
        }
        return;
    }

    // 确保文件名有效
    NSString *fileName = item.fileName;
    if (!fileName || fileName.length == 0) {
        fileName = [url lastPathComponent];
    }
    if (!fileName || fileName.length == 0) {
        fileName = @"resourcepack.zip";
    }
    if (![fileName.lowercaseString hasSuffix:@".zip"]) {
        fileName = [fileName stringByAppendingString:@".zip"];
    }

    NSString *destinationPath = [resourcePacksFolder stringByAppendingPathComponent:fileName];

    // 注册到统一下载任务管理器（rawTask 稍后赋值为 PLDownloadOperation；悬浮球已移除，始终注册以便下载任务列表跟踪）
    NSString *resourceName = item.fileName.length > 0 ? item.fileName : (item.displayName.length > 0 ? item.displayName : @"resourcepack");
    NSString *displayName = item.displayName.length > 0 ? item.displayName : resourceName;
    NSString *downloadSource = getPrefObject(@"general.download_source") ?: @"official";
    DownloadTaskItem *taskItem = [[DownloadTaskManager sharedManager]
        registerTaskWithResourceType:DownloadTaskResourceTypeResourcePack
                        resourceName:resourceName
                         displayName:displayName
                      downloadSource:downloadSource
                             rawTask:nil
                      supportsResume:YES
                             iconURL:item.iconURL];
    taskItem.downloadURL = item.selectedVersionDownloadURL;
    NSString *taskProfileName = [PLProfiles effectiveProfileNameForPreferredName:profileName];
    if (taskProfileName.length > 0) taskItem.userInfo[@"profileName"] = taskProfileName;
    taskItem.userInfo[@"destinationPath"] = destinationPath;
    // redesign-download-ui Phase 3：单文件下载接入统一进度页——
    // PLTaskStagesSingleFile 单阶段 + autoPresentDetail 自动弹出 PLTaskProgressViewController
    [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId stages:PLTaskStagesSingleFile()];
    taskItem.autoPresentDetail = YES;

    // retryHandler：FCL 风格重新下载，复用同一 taskItem，重新发起 PLDownloadClient 请求
    __weak typeof(self) weakSelf = self;
    __block PLDownloadRequest *retryRequest = nil;
    taskItem.retryHandler = ^id(DownloadTaskItem *taskItemRef) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !retryRequest) return nil;
        return [strongSelf startPLDownloadWithRequest:retryRequest taskItem:taskItemRef progress:progress completion:completion];
    };

    PLDownloadRequest *request = [[PLDownloadRequest alloc] init];
    // 镜像候选列表：原始 CDN URL + MCIM 镜像，按 download.assetDownloadSource 策略排序
    // （PLMirrorCenter 统一收敛镜像映射与策略读取）
    request.candidateURLs = [PLMirrorCenter candidateURLsForOriginalURL:url
                                                          resourceType:PLMirrorResourceTypeAssetDownload];
    // Task 5.1：expectedSHA1（版本模型 files[].hashes.sha1）传入即启用 SHA1 校验，
    // 校验失败由 PLDownloadClient 内部按镜像/退避节奏重试
    request.expectedSHA1 = expectedSHA1;
    // Task 5.2：目标文件已存在且校验通过 → 零流量直接成功（增量下载）；
    // 目标路径语义与原实现一致（resourcepacks/<fileName>.zip），落盘由 PLDownloadClient 原子替换完成
    request.destinationPath = destinationPath;
    // taskIdentifier 用 DownloadTaskManager 的 taskId，resumeData 断点数据跨次下载可复用
    request.taskIdentifier = taskItem.taskId;
    // 无 SHA1 时对 .zip 做 EOCD 兜底完整性校验
    request.allowZipFallbackCheck = YES;
    retryRequest = request;

    [self startPLDownloadWithRequest:request taskItem:taskItem progress:progress completion:completion];

    NSLog(@"[ResourcePackService] Starting download task (with progress) for resource pack: %@ -> %@", url, destinationPath);
}

#pragma mark - PLDownloadClient 封装（进度 delta 累计 / 速率采样 / 完成分发）

/// 发起（或重发）PLDownloadClient 请求并挂接进度、速率、完成回调。
/// progress/completion 传 nil 时不覆盖已登记的回调（retryHandler 重发时复用首次回调）。
- (nullable PLDownloadOperation *)startPLDownloadWithRequest:(PLDownloadRequest *)request
                                                     taskItem:(DownloadTaskItem *)taskItem
                                                     progress:(ResourcePackDownloadProgressHandler _Nullable)progress
                                                   completion:(ResourcePackDownloadCompletionHandler _Nullable)completion {
    NSString *taskId = taskItem.taskId;
    __weak typeof(self) weakSelf = self;

    [self.downloadStateLock lock];
    NSInteger generation = [self.downloadGenerations[taskId] integerValue] + 1;
    self.downloadGenerations[taskId] = @(generation);
    self.downloadTaskItems[taskId] = taskItem;
    self.downloadRequests[taskId] = request;
    if (progress) self.downloadProgressHandlers[taskId] = progress;
    if (completion) self.downloadCompletionHandlers[taskId] = completion;
    // 重发从头下载：归零累计（PLDownloadClient 的负 delta 回退语义在单次 operation 内自洽）
    self.downloadAccumulatedBytes[taskId] = @(0);
    self.downloadTotalBytes[taskId] = @(-1);
    self.downloadLastSpeeds[taskId] = @(0.0);

    PLDownloadOperation *operation = [[PLDownloadClient sharedClient] startRequest:request
                                                                          progress:^(int64_t deltaBytes, int64_t totalExpectedBytes) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf handlePLDownloadDelta:deltaBytes total:totalExpectedBytes taskId:taskId generation:generation];
    }
                                                                             speed:^(int64_t bytesPerSecond) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf handlePLDownloadSpeed:bytesPerSecond taskId:taskId generation:generation];
    }
                                                                        completion:^(BOOL success, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf handlePLDownloadCompletion:success error:error taskId:taskId generation:generation];
    }];
    if (!operation) {
        // 参数错误：PLDownloadClient 会异步回调 completion（error），由统一失败路径收尾
        [self.downloadStateLock unlock];
        return nil;
    }

    self.downloadOperations[taskId] = operation;

    // rawTask 为 weak 引用：operation 由 PLDownloadClient 与本 Service 共同持有，
    // DownloadTaskManager 据此对 PLDownloadOperation 做 pause/resume/cancel
    taskItem.rawTask = operation;
    // 占用并发槽位（满则由 DownloadTaskManager 自动 pauseOperation 排队）
    [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateDownloading];
    // redesign-download-ui Phase 3：单阶段任务进入下载时将阶段0 置为 Running
    [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                              stageAtIndex:0
                                                  status:PLTaskStageStatusRunning];
    [self.downloadStateLock unlock];
    return operation;
}

/// retryHandler 入口：复用登记的请求描述重新发起下载
- (nullable id)restartPLDownloadForTaskId:(NSString *)taskId {
    [self.downloadStateLock lock];
    PLDownloadRequest *request = self.downloadRequests[taskId];
    DownloadTaskItem *taskItem = self.downloadTaskItems[taskId];
    [self.downloadStateLock unlock];
    if (!request || !taskItem) return nil;
    return [self startPLDownloadWithRequest:request taskItem:taskItem progress:nil completion:nil];
}

/// 进度 delta 累计：负 delta（镜像切换/重试/断点失效回退）直接累加即可贴合真实进度
- (void)handlePLDownloadDelta:(int64_t)delta total:(int64_t)total taskId:(NSString *)taskId generation:(NSInteger)generation {
    [self.downloadStateLock lock];
    if ([self.downloadGenerations[taskId] integerValue] != generation) {
        [self.downloadStateLock unlock];
        return;
    }
    int64_t accumulated = [self.downloadAccumulatedBytes[taskId] longLongValue] + delta;
    if (accumulated < 0) accumulated = 0;
    if (total > 0) self.downloadTotalBytes[taskId] = @(total);
    int64_t totalStored = [self.downloadTotalBytes[taskId] longLongValue];
    self.downloadAccumulatedBytes[taskId] = @(accumulated);
    double lastSpeed = [self.downloadLastSpeeds[taskId] doubleValue];
    ResourcePackDownloadProgressHandler progressHandler = self.downloadProgressHandlers[taskId];
    [self.downloadStateLock unlock];

    double fraction = totalStored > 0 ? (double)accumulated / (double)totalStored : -1.0;
    [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                 progress:fraction
                                               totalBytes:totalStored
                                          downloadedBytes:accumulated];
    // redesign-download-ui Phase 3：单阶段任务的阶段进度与任务总进度保持一致
    [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                              stageAtIndex:0
                                                  progress:fraction
                                                 message:nil];

    if (!progressHandler) return;

    // 构造带 throughput/ETA 的 NSProgress，供调用方在下载进度 UI 上显示速度和 ETA
    NSProgress *downloadProgress = [NSProgress progressWithTotalUnitCount:totalStored > 0 ? totalStored : -1];
    downloadProgress.completedUnitCount = accumulated;
    if (lastSpeed > 0) {
        downloadProgress.throughput = @(lastSpeed);
        if (totalStored > accumulated) {
            downloadProgress.estimatedTimeRemaining = @((double)(totalStored - accumulated) / lastSpeed);
        }
    }
    // progress 回调在主线程执行（UI 更新安全）
    dispatch_async(dispatch_get_main_queue(), ^{
        progressHandler(downloadProgress);
    });
}

/// 速率采样（PLDownloadClient 每秒回调一次；结束/暂停时回调 0）
- (void)handlePLDownloadSpeed:(int64_t)bytesPerSecond taskId:(NSString *)taskId generation:(NSInteger)generation {
    [self.downloadStateLock lock];
    if ([self.downloadGenerations[taskId] integerValue] != generation) {
        [self.downloadStateLock unlock];
        return;
    }
    self.downloadLastSpeeds[taskId] = @(bytesPerSecond);
    int64_t total = [self.downloadTotalBytes[taskId] longLongValue];
    int64_t accumulated = [self.downloadAccumulatedBytes[taskId] longLongValue];
    [self.downloadStateLock unlock];

    double eta = (bytesPerSecond > 0 && total > accumulated)
        ? (double)(total - accumulated) / (double)bytesPerSecond : 0.0;
    [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                    speed:(double)bytesPerSecond
                                  estimatedTimeRemaining:eta];
}

/// 完成分发：更新 DownloadTaskManager 状态并回调业务方（主线程）
/// 文件落盘由 PLDownloadClient 校验通过后原子替换到 destinationPath，无需再手动移动
- (void)handlePLDownloadCompletion:(BOOL)success
                             error:(nullable NSError *)error
                            taskId:(NSString *)taskId
                         generation:(NSInteger)generation {
    [self.downloadStateLock lock];
    if ([self.downloadGenerations[taskId] integerValue] != generation) {
        [self.downloadStateLock unlock];
        return;
    }
    ResourcePackDownloadCompletionHandler completion = self.downloadCompletionHandlers[taskId];
    [self cleanupPLDownloadStateForTaskId:taskId];
    [self.downloadStateLock unlock];

    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    NSError *completionError = success ? nil : (error ?: [NSError errorWithDomain:@"ResourcePackServiceError" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Resource pack download failed."}]);
    if (success) {
        [manager updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusCompleted];
        [manager setTaskWithId:taskId completedWithError:nil];
    } else if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) {
        // 用户取消（DownloadTaskManager 已置 Cancelled，这里幂等对齐）
        [manager setTaskWithId:taskId state:DownloadTaskStateCancelled];
    } else {
        [manager updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
        [manager setTaskWithId:taskId completedWithError:completionError];
    }

    if (completion) {
        BOOL successFlag = success ? YES : NO;
        NSError *capturedError = completionError;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(successFlag, capturedError);
        });
    }
}

/// 清理指定任务的全部跟踪状态（须在 downloadStateLock 内调用）
- (void)cleanupPLDownloadStateForTaskId:(NSString *)taskId {
    [self.downloadTaskItems removeObjectForKey:taskId];
    [self.downloadOperations removeObjectForKey:taskId];
    [self.downloadGenerations removeObjectForKey:taskId];
    [self.downloadAccumulatedBytes removeObjectForKey:taskId];
    [self.downloadTotalBytes removeObjectForKey:taskId];
    [self.downloadLastSpeeds removeObjectForKey:taskId];
    [self.downloadRequests removeObjectForKey:taskId];
    [self.downloadProgressHandlers removeObjectForKey:taskId];
    [self.downloadCompletionHandlers removeObjectForKey:taskId];
}

@end
