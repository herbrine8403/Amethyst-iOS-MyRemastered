#import "utils.h"
//
//  WorldService.m
//  Amethyst
//
//  世界存档服务实现，结构参照 ResourcePackService/DataPackService
//  API 签名统一使用 NSString *profileName
//  使用 defaultSessionConfiguration + NSURLSessionDownloadTask 提升下载效率和速度
//  实现健壮解压逻辑：检测 zip 内是否含顶层目录，若无则创建子目录再解压
//

#import "WorldService.h"
#import <CommonCrypto/CommonCrypto.h>
#import <UIKit/UIKit.h>
#import "PLProfiles.h"
#import "WorldItem.h"
#import "UZKArchive.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "PLTaskStages.h"
#import "LauncherPreferences.h"

static NSString * const PLWorldDownloadGenerationKey = @"worldDownloadGeneration";

@interface WorldService () <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *downloadSession;
// 内部统一存储带 success/error 的 completion handler
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, WorldDownloadCompletionHandler> *downloadCompletionHandlers;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSString *> *downloadDestinationPaths;
// 进度回调相关：分别保存进度 handler 和 NSProgress 对象
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, WorldDownloadProgressHandler> *downloadProgressHandlers;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSProgress *> *downloadProgresses;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, DownloadTaskItem *> *downloadTaskItems;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSMutableDictionary *> *downloadProgressSnapshots;
@property (nonatomic, strong) NSLock *downloadStateLock;
// 导入任务专用字典（不通过 NSURLSession 下载，但同样需要进度上报）
@property (nonatomic, strong) NSMutableDictionary<NSString *, WorldDownloadCompletionHandler> *importCompletionHandlers;
@end

@implementation WorldService

+ (instancetype)sharedService {
    static WorldService *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [[WorldService alloc] init];
    });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        // 使用默认会话配置，避免后台会话限速
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 120.0;
        config.timeoutIntervalForResource = 600.0; // 世界包通常较大，超时设长一些
        config.allowsCellularAccess = YES;
        config.HTTPMaximumConnectionsPerHost = 6;

        _downloadSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
        _downloadCompletionHandlers = [NSMutableDictionary dictionary];
        _downloadDestinationPaths = [NSMutableDictionary dictionary];
        _downloadProgressHandlers = [NSMutableDictionary dictionary];
        _downloadProgresses = [NSMutableDictionary dictionary];
        _downloadTaskItems = [NSMutableDictionary dictionary];
        _downloadProgressSnapshots = [NSMutableDictionary dictionary];
        _downloadStateLock = [[NSLock alloc] init];
        _importCompletionHandlers = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - 工具方法

// 解析 profile 的 gameDir，返回 gameDir 或 nil
- (nullable NSString *)gameDirForProfile:(NSString *)profileName {
    return [PLProfiles resolvedGameDirectoryForProfileName:profileName];
}

#pragma mark - Saves folder detection & scan

// 查找指定 profile 的 saves 目录（已存在时返回路径，否则返回 nil）
- (nullable NSString *)existingWorldsFolderForProfile:(NSString *)profileName {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *savesPath = [[self gameDirForProfile:profileName] stringByAppendingPathComponent:@"saves"];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:savesPath isDirectory:&isDir] && isDir) return savesPath;
    return nil;
}

/// 获取当前 profile 的 saves 目录，不存在时自动创建
- (nullable NSString *)ensureWorldsFolderForProfile:(NSString *)profileName error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *savesPath = [[self gameDirForProfile:profileName] stringByAppendingPathComponent:@"saves"];

    if (!savesPath) {
        if (error) {
            *error = [NSError errorWithDomain:@"WorldService" code:1 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_105", nil)}];
        }
        return nil;
    }

    BOOL isDir = NO;
    if (![fm fileExistsAtPath:savesPath isDirectory:&isDir]) {
        NSError *createError = nil;
        [fm createDirectoryAtPath:savesPath withIntermediateDirectories:YES attributes:nil error:&createError];
        if (createError) {
            if (error) *error = createError;
            return nil;
        }
        NSLog(@"[WorldService] created saves directory: %@", savesPath);
    } else if (!isDir) {
        if (error) {
            *error = [NSError errorWithDomain:@"WorldService" code:2 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_451", nil), savesPath]}];
        }
        return nil;
    }
    return savesPath;
}

- (void)scanWorldsForProfile:(NSString *)profileName completion:(WorldListHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *savesFolder = [self existingWorldsFolderForProfile:profileName];
        NSMutableArray<WorldItem *> *items = [NSMutableArray array];

        if (!savesFolder) {
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(items); });
            }
            return;
        }

        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *listError = nil;
        NSArray<NSString *> *contents = [fm contentsOfDirectoryAtPath:savesFolder error:&listError];
        if (!contents) {
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(items); });
            }
            return;
        }

        for (NSString *subDir in contents) {
            NSString *fullPath = [savesFolder stringByAppendingPathComponent:subDir];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:fullPath isDirectory:&isDir] || !isDir) {
                continue;
            }
            // 检测 level.dat 是否存在，以确认这是一个有效的世界存档
            NSString *levelDat = [fullPath stringByAppendingPathComponent:@"level.dat"];
            if ([fm fileExistsAtPath:levelDat]) {
                WorldItem *world = [[WorldItem alloc] initWithFilePath:fullPath];
                [items addObject:world];
            }
        }

        // 按上次游玩时间倒序排序（无时间的排末尾）
        [items sortUsingComparator:^NSComparisonResult(WorldItem *obj1, WorldItem *obj2) {
            NSString *t1 = obj1.lastPlayed ?: @"";
            NSString *t2 = obj2.lastPlayed ?: @"";
            return [t2 compare:t1]; // 倒序
        }];

        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(items); });
        }
    });
}

// 删除世界目录（递归）
- (BOOL)deleteWorld:(WorldItem *)item error:(NSError **)error {
    if (!item.filePath) {
        if (error) {
            *error = [NSError errorWithDomain:@"WorldServiceError" code:101 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1094", nil)}];
        }
        return NO;
    }
    return [[NSFileManager defaultManager] removeItemAtPath:item.filePath error:error];
}

#pragma mark - 健壮解压逻辑

// 检测 zip 内是否存在顶层目录（即所有条目都以同一个目录名开头）
// 若存在，返回该顶层目录名；否则返回 nil（说明 zip 直接散装了 level.dat 等文件）
- (nullable NSString *)detectTopLevelDirectoryInZip:(NSString *)zipPath {
    NSError *err = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:zipPath error:&err];
    if (!archive || err) return nil;

    NSArray<NSString *> *fileNames = [archive listFilenames:&err];
    if (!fileNames || fileNames.count == 0) return nil;

    NSMutableSet<NSString *> *topLevels = [NSMutableSet set];
    for (NSString *name in fileNames) {
        if (name.length == 0) continue;
        // 跳过 macOS 元数据文件（如 __MACOSX/...）
        if ([name hasPrefix:@"__MACOSX/"]) continue;
        // 取第一段作为顶层目录候选
        NSString *firstComponent = [name componentsSeparatedByString:@"/"].firstObject;
        if (firstComponent.length == 0) continue;
        [topLevels addObject:firstComponent];
    }

    // 仅当所有条目共享同一个顶层目录时，才认为 zip 内有顶层目录
    if (topLevels.count == 1) {
        return [topLevels anyObject];
    }
    return nil;
}

// 健壮解压：
// - 若 zip 内有顶层目录，直接解压到 saves/
// - 若 zip 内无顶层目录（散装），先用世界名创建子目录，再解压到该子目录
// - worldName 用于无顶层目录时命名新世界目录
- (nullable NSString *)worldDirectoryContainingLevelDatUnderPath:(NSString *)rootPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *directLevelDat = [rootPath stringByAppendingPathComponent:@"level.dat"];
    if ([fm fileExistsAtPath:directLevelDat]) return rootPath;

    NSDirectoryEnumerator<NSString *> *enumerator = [fm enumeratorAtPath:rootPath];
    for (NSString *relativePath in enumerator) {
        if ([[relativePath lastPathComponent] isEqualToString:@"level.dat"]) {
            return [[rootPath stringByAppendingPathComponent:relativePath] stringByDeletingLastPathComponent];
        }
    }
    return nil;
}

- (BOOL)extractWorldZipAt:(NSString *)zipPath
                toSavesDir:(NSString *)savesDir
                worldName:(NSString *)worldName
                    error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *topLevelDir = [self detectTopLevelDirectoryInZip:zipPath];
    NSString *extractTargetDir = nil;
    NSString *finalWorldDir = nil;
    BOOL finalWorldDirExistedBefore = NO;

    if (topLevelDir) {
        // zip 内有顶层目录，直接解压到 saves/
        extractTargetDir = savesDir;
        finalWorldDir = [savesDir stringByAppendingPathComponent:topLevelDir];
        finalWorldDirExistedBefore = [fm fileExistsAtPath:finalWorldDir];
    } else {
        // zip 内无顶层目录，需要创建子目录后再解压
        NSString *baseName = worldName.length > 0 ? worldName : [zipPath lastPathComponent];
        // 去除可能的 .zip 后缀
        if ([baseName.lowercaseString hasSuffix:@".zip"]) {
            baseName = [baseName substringToIndex:baseName.length - @".zip".length];
        }
        // 若 saves/<baseName> 已存在，则追加数字后缀避免覆盖
        NSString *candidate = [savesDir stringByAppendingPathComponent:baseName];
        NSInteger suffix = 1;
        while ([fm fileExistsAtPath:candidate]) {
            candidate = [savesDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%ld", baseName, (long)suffix]];
            suffix++;
        }
        extractTargetDir = candidate;
        finalWorldDir = candidate;

        // 创建目标子目录
        NSError *createError = nil;
        if (![fm createDirectoryAtPath:extractTargetDir withIntermediateDirectories:YES attributes:nil error:&createError]) {
            if (error) *error = createError;
            return NO;
        }
    }

    // 使用 UnzipKit 解压到目标目录
    NSError *archiveError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:zipPath error:&archiveError];
    if (!archive || archiveError) {
        if (!finalWorldDirExistedBefore) [fm removeItemAtPath:finalWorldDir error:nil];
        if (error) *error = archiveError;
        return NO;
    }

    NSError *extractError = nil;
    BOOL success = [archive extractFilesTo:extractTargetDir overwrite:YES error:&extractError];
    if (!success || extractError) {
        if (error) *error = extractError;
        // 仅清理本次新建的世界目录，保留下载前已经存在的用户数据。
        if (!finalWorldDirExistedBefore) [fm removeItemAtPath:finalWorldDir error:nil];
        return NO;
    }

    // Minecraft 只识别 saves/ 的直接子目录。若压缩包多套了一层目录，找到真正
    // 包含 level.dat 的目录并提升到 saves/，否则管理页和游戏都会把它当作不存在。
    NSString *actualWorldDir = [self worldDirectoryContainingLevelDatUnderPath:finalWorldDir];
    if (!actualWorldDir) {
        if (!finalWorldDirExistedBefore) [fm removeItemAtPath:finalWorldDir error:nil];
        if (error) {
            *error = [NSError errorWithDomain:@"WorldServiceError"
                                         code:7
                                     userInfo:@{NSLocalizedDescriptionKey: @"The downloaded archive does not contain a valid Minecraft world (level.dat is missing)."}];
        }
        return NO;
    }

    if (![actualWorldDir isEqualToString:finalWorldDir]) {
        NSString *baseName = actualWorldDir.lastPathComponent.length > 0 ? actualWorldDir.lastPathComponent : worldName;
        NSString *promotedWorldDir = [savesDir stringByAppendingPathComponent:baseName];
        NSInteger suffix = 1;
        while ([fm fileExistsAtPath:promotedWorldDir]) {
            promotedWorldDir = [savesDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%ld", baseName, (long)suffix++]];
        }

        NSError *moveError = nil;
        if (![fm moveItemAtPath:actualWorldDir toPath:promotedWorldDir error:&moveError]) {
            if (error) *error = moveError;
            return NO;
        }
        if (!finalWorldDirExistedBefore) [fm removeItemAtPath:finalWorldDir error:nil];
        finalWorldDir = promotedWorldDir;
    }

    NSLog(@"[WorldService] world extracted to: %@", finalWorldDir);
    return YES;
}

#pragma mark - 在线世界下载（含健壮解压）

- (void)downloadWorld:(WorldItem *)item
            toProfile:(NSString *)profileName
             progress:(WorldDownloadProgressHandler _Nullable)progress
           completion:(WorldDownloadCompletionHandler _Nullable)completion {
    // 确保 saves 目录存在
    NSError *ensureError = nil;
    NSString *savesFolder = [self ensureWorldsFolderForProfile:profileName error:&ensureError];
    if (!savesFolder) {
        if (completion) {
            NSError *error = ensureError ?: [NSError errorWithDomain:@"WorldServiceError"
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
            NSError *error = [NSError errorWithDomain:@"WorldServiceError"
                                                 code:2
                                             userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_454", nil)}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
        }
        return;
    }

    // 下载到临时 zip 路径，解压后再删除
    NSString *tempZipName = [NSString stringWithFormat:@"world_%@.zip", [[NSUUID UUID] UUIDString]];
    NSString *destinationPath = [NSTemporaryDirectory() stringByAppendingPathComponent:tempZipName];
    // 同时记录预期世界名（用于无顶层目录时的子目录命名）
    NSString *worldNameForExtract = item.displayName ?: item.worldName ?: [url lastPathComponent];

    // 创建下载任务（默认会话配置，无后台限速）
    NSURLSessionDownloadTask *task = [self.downloadSession downloadTaskWithURL:url];
    // 用 taskDescription 暂存世界名和 saves 目录（用于解压阶段）
    // 格式："worldName\nsavesFolder"
    task.taskDescription = [NSString stringWithFormat:@"%@\n%@", worldNameForExtract, savesFolder];
    NSProgress *progressObj = nil;
    if (progress) {
        progressObj = [NSProgress progressWithTotalUnitCount:-1];
        progressObj.kind = NSProgressKindFile;
    }

    // 注册到统一下载任务管理器（悬浮球已移除，始终注册以便下载任务列表跟踪）
    NSString *resourceName = item.worldName.length > 0 ? item.worldName : (item.displayName.length > 0 ? item.displayName : @"world");
    NSString *displayName = item.displayName.length > 0 ? item.displayName : resourceName;
    NSString *downloadSource = getPrefObject(@"general.download_source") ?: @"official";
    DownloadTaskItem *taskItem = [[DownloadTaskManager sharedManager]
        registerTaskWithResourceType:DownloadTaskResourceTypeWorld
                        resourceName:resourceName
                         displayName:displayName
                      downloadSource:downloadSource
                             rawTask:task
                      supportsResume:YES
                             iconURL:item.iconURL];
    taskItem.downloadURL = item.selectedVersionDownloadURL;
    NSString *taskProfileName = [PLProfiles effectiveProfileNameForPreferredName:profileName];
    if (taskProfileName.length > 0) taskItem.userInfo[@"profileName"] = taskProfileName;
    taskItem.userInfo[@"destinationPath"] = destinationPath;
    taskItem.userInfo[PLWorldDownloadGenerationKey] = @(task.taskIdentifier);
    // 世界暂停恢复需要用新的 NSURLSessionTask 从头重建，不应消耗网络失败重试预算。
    taskItem.maxRetryCount = 0;
    taskItem.autoPresentDetail = YES;
    [self.downloadStateLock lock];
    if (completion) self.downloadCompletionHandlers[task] = completion;
    self.downloadDestinationPaths[task] = destinationPath;
    if (progressObj) self.downloadProgresses[task] = progressObj;
    if (progress) self.downloadProgressHandlers[task] = progress;
    self.downloadTaskItems[task] = taskItem;
    [self.downloadStateLock unlock];
    [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId stages:PLTaskStagesWorld()];
    [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId state:DownloadTaskStateDownloading];
    [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId stageAtIndex:0 status:PLTaskStageStatusRunning];

    // 设置 retryHandler：FCL 风格重新下载
    __weak typeof(self) weakSelf = self;
    NSString *capturedDestPath = destinationPath;
    NSString *capturedTaskDescription = task.taskDescription;
    WorldDownloadCompletionHandler capturedCompletion = completion;
    void (^capturedProgress)(NSProgress *) = progress;
    taskItem.retryHandler = ^id(DownloadTaskItem *taskItemRef) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return nil;
        NSURL *retryURL = [NSURL URLWithString:taskItemRef.downloadURL] ?: url;
        if (!retryURL) return nil;
        NSURLSessionDownloadTask *newTask = [strongSelf.downloadSession downloadTaskWithURL:retryURL];
        newTask.taskDescription = capturedTaskDescription;
        taskItemRef.userInfo[PLWorldDownloadGenerationKey] = @(newTask.taskIdentifier);
        // manager 随后依据 rawTask 获取并发槽；必须在切换 Downloading 前写入。
        taskItemRef.rawTask = newTask;
        [strongSelf.downloadStateLock lock];
        if (capturedCompletion) strongSelf.downloadCompletionHandlers[newTask] = capturedCompletion;
        strongSelf.downloadDestinationPaths[newTask] = capturedDestPath;
        if (capturedProgress) {
            NSProgress *progressObj = [NSProgress progressWithTotalUnitCount:-1];
            progressObj.kind = NSProgressKindFile;
            strongSelf.downloadProgresses[newTask] = progressObj;
            strongSelf.downloadProgressHandlers[newTask] = capturedProgress;
        }
        strongSelf.downloadTaskItems[newTask] = taskItemRef;
        [strongSelf.downloadStateLock unlock];
        [[DownloadTaskManager sharedManager] setTaskWithId:taskItemRef.taskId stages:PLTaskStagesWorld()];
        [[DownloadTaskManager sharedManager] setTaskWithId:taskItemRef.taskId state:DownloadTaskStateDownloading];
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskItemRef.taskId stageAtIndex:0 status:PLTaskStageStatusRunning];
        [newTask resume];
        return newTask;
    };

    [task resume];

    NSLog(@"[WorldService] started downloading world: %@ -> %@", url, destinationPath);
}

#pragma mark - 从本地文件导入世界

- (void)importWorldFromURL:(NSURL *)sourceURL
                toProfile:(NSString *)profileName
                 progress:(WorldDownloadProgressHandler _Nullable)progress
               completion:(WorldDownloadCompletionHandler _Nullable)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // 确保 saves 目录存在
        NSError *ensureError = nil;
        NSString *savesFolder = [self ensureWorldsFolderForProfile:profileName error:&ensureError];
        if (!savesFolder) {
            if (completion) {
                NSError *error = ensureError ?: [NSError errorWithDomain:@"WorldServiceError"
                                                                     code:1
                                                                 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_106", nil)}];
                dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
            }
            return;
        }

        // 安全访问文件（UIDocumentPicker 返回的 URL 需要 startAccessingSecurityScopedResource）
        BOOL needsStopAccessing = NO;
        if ([sourceURL isKindOfClass:[NSURL class]] && sourceURL.isFileURL) {
            needsStopAccessing = [sourceURL startAccessingSecurityScopedResource];
        }

        @try {
            NSString *sourcePath = sourceURL.path;
            if (!sourcePath || ![[NSFileManager defaultManager] fileExistsAtPath:sourcePath]) {
                if (completion) {
                    NSError *error = [NSError errorWithDomain:@"WorldServiceError"
                                                         code:3
                                                     userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1095", nil)}];
                    dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
                }
                return;
            }

            // 复制到临时文件以便 UnzipKit 安全读取（避免安全作用域限制）
            NSString *tempZipPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                     [NSString stringWithFormat:@"world_import_%@.zip", [[NSUUID UUID] UUIDString]]];
            NSError *copyError = nil;
            if (![[NSFileManager defaultManager] copyItemAtPath:sourcePath toPath:tempZipPath error:&copyError]) {
                if (completion) {
                    NSError *error = copyError ?: [NSError errorWithDomain:@"WorldServiceError"
                                                                       code:4
                                                                   userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1096", nil)}];
                    dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
                }
                return;
            }

            // 本地导入可直接上报 100% 进度（无网络下载阶段）
            if (progress) {
                NSProgress *prog = [NSProgress progressWithTotalUnitCount:1];
                prog.completedUnitCount = 1;
                dispatch_async(dispatch_get_main_queue(), ^{ progress(prog); });
            }

            // 推导世界名（去除 .zip 后缀）
            NSString *worldName = [sourceURL lastPathComponent];
            if ([worldName.lowercaseString hasSuffix:@".zip"]) {
                worldName = [worldName substringToIndex:worldName.length - @".zip".length];
            }

            // 解压
            NSError *extractError = nil;
            BOOL success = [self extractWorldZipAt:tempZipPath
                                        toSavesDir:savesFolder
                                        worldName:worldName
                                            error:&extractError];

            // 删除临时文件
            [[NSFileManager defaultManager] removeItemAtPath:tempZipPath error:nil];

            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (success) {
                        completion(YES, nil);
                    } else {
                        completion(NO, extractError ?: [NSError errorWithDomain:@"WorldServiceError"
                                                                            code:5
                                                                        userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1097", nil)}]);
                    }
                });
            }
        } @finally {
            if (needsStopAccessing) {
                [sourceURL stopAccessingSecurityScopedResource];
            }
        }
    });
}

#pragma mark - NSURLSessionDownloadDelegate

// 下载进度回调：更新 NSProgress 并在主线程上报
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    [self.downloadStateLock lock];
    NSProgress *progressObj = self.downloadProgresses[downloadTask];
    WorldDownloadProgressHandler progressHandler = self.downloadProgressHandlers[downloadTask];
    DownloadTaskItem *taskItem = self.downloadTaskItems[downloadTask];

    if (taskItem) {
        double fraction = totalBytesExpectedToWrite > 0 ? (double)totalBytesWritten / (double)totalBytesExpectedToWrite : -1.0;
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        NSMutableDictionary *snapshot = self.downloadProgressSnapshots[downloadTask];
        double speed = 0.0;
        NSTimeInterval eta = 0.0;
        if (snapshot) {
            NSTimeInterval lastTime = [snapshot[@"lastTime"] doubleValue];
            int64_t lastBytes = [snapshot[@"lastBytes"] longLongValue];
            if (lastTime > 0 && now > lastTime) {
                speed = (double)(totalBytesWritten - lastBytes) / (now - lastTime);
                if (speed > 0 && totalBytesExpectedToWrite > totalBytesWritten) {
                    eta = (double)(totalBytesExpectedToWrite - totalBytesWritten) / speed;
                }
            }
        } else {
            snapshot = [NSMutableDictionary dictionary];
            self.downloadProgressSnapshots[downloadTask] = snapshot;
        }
        snapshot[@"lastTime"] = @(now);
        snapshot[@"lastBytes"] = @(totalBytesWritten);
        [self.downloadStateLock unlock];
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId
                                                     progress:fraction
                                                   totalBytes:totalBytesExpectedToWrite
                                              downloadedBytes:totalBytesWritten];
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId
                                                          speed:speed
                                        estimatedTimeRemaining:eta];
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId
                                                  stageAtIndex:0
                                                      progress:fraction
                                                       message:nil];
    } else {
        [self.downloadStateLock unlock];
    }

    if (!progressObj || !progressHandler) return;

    // 首次回调时设置总字节数（HTTP 响应头中可能未提供，则保持 -1）
    if (progressObj.totalUnitCount < 0 && totalBytesExpectedToWrite > 0) {
        progressObj.totalUnitCount = totalBytesExpectedToWrite;
    }
    progressObj.completedUnitCount = totalBytesWritten;

    // progress 回调在主线程执行（UI 更新安全）
    dispatch_async(dispatch_get_main_queue(), ^{
        progressHandler(progressObj);
    });
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
    NSNumber *generation = @(downloadTask.taskIdentifier);
    [self.downloadStateLock lock];
    WorldDownloadCompletionHandler handler = self.downloadCompletionHandlers[downloadTask];
    NSString *destinationPath = self.downloadDestinationPaths[downloadTask];
    NSString *taskDescription = downloadTask.taskDescription;
    DownloadTaskItem *taskItem = self.downloadTaskItems[downloadTask];

    [self.downloadCompletionHandlers removeObjectForKey:downloadTask];
    [self.downloadDestinationPaths removeObjectForKey:downloadTask];
    [self.downloadProgresses removeObjectForKey:downloadTask];
    [self.downloadProgressHandlers removeObjectForKey:downloadTask];
    [self.downloadTaskItems removeObjectForKey:downloadTask];
    [self.downloadProgressSnapshots removeObjectForKey:downloadTask];
    [self.downloadStateLock unlock];

    if (!destinationPath) {
        NSError *metadataError = [NSError errorWithDomain:@"WorldServiceError"
                                                      code:6
                                                  userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1098", nil)}];
        if (taskItem) {
            [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId completedWithError:metadataError];
        }
        if (handler) dispatch_async(dispatch_get_main_queue(), ^{ handler(NO, metadataError); });
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *moveError = nil;
    NSString *dir = [destinationPath stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    if ([fm fileExistsAtPath:destinationPath]) {
        [fm removeItemAtPath:destinationPath error:nil];
    }
    if (![fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:destinationPath] error:&moveError]) {
        NSError *finalMoveError = moveError ?: [NSError errorWithDomain:@"WorldServiceError"
                                                                    code:4
                                                                userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1096", nil)}];
        if (taskItem) {
            [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId completedWithError:finalMoveError];
        }
        if (handler) dispatch_async(dispatch_get_main_queue(), ^{ handler(NO, finalMoveError); });
        return;
    }

    // 解析 taskDescription：worldName 与 savesFolder
    NSString *worldName = nil;
    NSString *savesFolder = nil;
    if (taskDescription.length > 0) {
        NSArray<NSString *> *parts = [taskDescription componentsSeparatedByString:@"\n"];
        if (parts.count >= 1) worldName = parts[0];
        if (parts.count >= 2) savesFolder = parts[1];
    }
    if (!savesFolder) {
        // 无 saves 目录信息，回退：删除临时 zip 并报错
        [fm removeItemAtPath:destinationPath error:nil];
        NSError *metadataError = [NSError errorWithDomain:@"WorldServiceError"
                                                      code:6
                                                  userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1098", nil)}];
        if (taskItem) {
            [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId completedWithError:metadataError];
        }
        if (handler) dispatch_async(dispatch_get_main_queue(), ^{ handler(NO, metadataError); });
        return;
    }

    if (taskItem) {
        DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
        [manager updateTaskWithId:taskItem.taskId stageAtIndex:0 status:PLTaskStageStatusCompleted];
        [manager updateTaskWithId:taskItem.taskId currentStageIndex:1];
        [manager updateTaskWithId:taskItem.taskId stageAtIndex:1 status:PLTaskStageStatusRunning];
    }

    // 在后台线程做解压
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *extractError = nil;
        BOOL success = [self extractWorldZipAt:destinationPath
                                    toSavesDir:savesFolder
                                    worldName:worldName ?: @"imported_world"
                                        error:&extractError];

        // 解压完成后删除临时 zip
        [fm removeItemAtPath:destinationPath error:nil];

        dispatch_async(dispatch_get_main_queue(), ^{
            DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
            DownloadTaskItem *latestTask = taskItem ? [manager taskWithId:taskItem.taskId] : nil;
            // 下载完成后解压仍在后台运行。若用户在此期间暂停或取消，保持用户
            // 选择，不再把阶段改写为成功/失败，也不弹出相反的结果提示。
            if (taskItem &&
                (latestTask.state != DownloadTaskStateDownloading ||
                 ![latestTask.userInfo[PLWorldDownloadGenerationKey] isEqual:generation])) {
                return;
            }
            if (success) {
                if (taskItem) {
                    [manager updateTaskWithId:taskItem.taskId stageAtIndex:1 status:PLTaskStageStatusCompleted];
                    [manager setTaskWithId:taskItem.taskId completedWithError:nil];
                }
                if (handler) handler(YES, nil);
            } else {
                NSError *finalError = extractError ?: [NSError errorWithDomain:@"WorldServiceError"
                                                                           code:5
                                                                       userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1097", nil)}];
                if (taskItem) {
                    [manager updateTaskWithId:taskItem.taskId stageAtIndex:1 status:PLTaskStageStatusFailed];
                    [manager setTaskWithId:taskItem.taskId completedWithError:finalError];
                }
                if (handler) handler(NO, finalError);
            }
        });
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        NSNumber *generation = @(task.taskIdentifier);
        [self.downloadStateLock lock];
        WorldDownloadCompletionHandler handler = self.downloadCompletionHandlers[task];
        DownloadTaskItem *taskItem = self.downloadTaskItems[task];
        [self.downloadTaskItems removeObjectForKey:task];
        [self.downloadProgressSnapshots removeObjectForKey:task];
        [self.downloadCompletionHandlers removeObjectForKey:task];
        [self.downloadDestinationPaths removeObjectForKey:task];
        [self.downloadProgresses removeObjectForKey:task];
        [self.downloadProgressHandlers removeObjectForKey:task];
        [self.downloadStateLock unlock];

        dispatch_async(dispatch_get_main_queue(), ^{
            DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
            DownloadTaskItem *latestTask = taskItem ? [manager taskWithId:taskItem.taskId] : nil;
            BOOL isCancellation = [error.domain isEqualToString:NSURLErrorDomain] &&
                                  error.code == NSURLErrorCancelled;
            // 该回调若属于已被 retry 替换的旧 NSURLSessionTask，只清理旧映射，
            // 不得影响新一代任务。
            if (taskItem &&
                (!latestTask ||
                 ![latestTask.userInfo[PLWorldDownloadGenerationKey] isEqual:generation])) {
                return;
            }
            // cancelByProducingResumeData: 也以 NSURLErrorCancelled 收尾。暂停时等待
            // retryHandler 的最终结果；显式取消由任务列表状态表达，均不误报失败。
            if (isCancellation) {
                // 用户在 cancelByProducingResumeData: 尚未收尾时快速点了继续，
                // manager 会暂时回到 Downloading。旧任务已经无法恢复，转为一次
                // 原子重试，避免卡在没有活动 rawTask 的“下载中”。
                if (latestTask.state == DownloadTaskStateDownloading) {
                    [manager setTaskWithId:taskItem.taskId state:DownloadTaskStatePaused];
                    [manager retryTaskWithId:taskItem.taskId];
                }
                return;
            }
            if (taskItem && latestTask.state != DownloadTaskStateDownloading) return;
            if (taskItem) {
                [manager updateTaskWithId:taskItem.taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                [manager setTaskWithId:taskItem.taskId completedWithError:error];
            }
            if (handler) handler(NO, error);
        });
    }
}

@end
