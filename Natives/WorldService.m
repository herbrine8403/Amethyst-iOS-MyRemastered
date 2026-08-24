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
static NSString * const PLWorldStagingRootName = @".amethyst-world-staging";
static NSString * const PLWorldArchiveFileName = @"world.zip";

@interface PLStagedWorld : NSObject
@property (nonatomic, copy) NSString *stagingDirectory;
@property (nonatomic, copy) NSString *worldDirectory;
@property (nonatomic, copy) NSString *suggestedName;
@end

@implementation PLStagedWorld
@end

@interface WorldService () <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *downloadSession;
// 内部统一存储带 success/error 的 completion handler
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, WorldDownloadCompletionHandler> *downloadCompletionHandlers;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSString *> *downloadDestinationPaths;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSString *> *downloadStagingDirectories;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSString *> *downloadWorldNames;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSString *> *downloadSavesFolders;
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
        _downloadStagingDirectories = [NSMutableDictionary dictionary];
        _downloadWorldNames = [NSMutableDictionary dictionary];
        _downloadSavesFolders = [NSMutableDictionary dictionary];
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
    NSString *gameDir = [self gameDirForProfile:profileName];
    if (gameDir.length == 0) return nil;
    NSString *savesPath = [gameDir stringByAppendingPathComponent:@"saves"];
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

// 每次下载/导入使用 saves 同级的唯一 staging。它与 saves 位于同一卷，最终
// moveItemAtPath: 可安全 rename，同时任何解压失败都不会触碰已有世界。
- (nullable NSString *)createWorldStagingDirectoryForSavesDir:(NSString *)savesDir
                                                         error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *gameDirectory = savesDir.stringByDeletingLastPathComponent;
    NSString *stagingRoot = [gameDirectory stringByAppendingPathComponent:PLWorldStagingRootName];
    BOOL isDirectory = NO;
    if ([fm fileExistsAtPath:stagingRoot isDirectory:&isDirectory]) {
        if (!isDirectory) {
            if (error) {
                *error = [NSError errorWithDomain:@"WorldServiceError"
                                             code:8
                                         userInfo:@{NSLocalizedDescriptionKey: @"The world staging path is not a directory."}];
            }
            return nil;
        }
    } else if (![fm createDirectoryAtPath:stagingRoot
              withIntermediateDirectories:YES
                               attributes:nil
                                    error:error]) {
        return nil;
    }

    NSString *stagingDirectory = [stagingRoot stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (![fm createDirectoryAtPath:stagingDirectory
       withIntermediateDirectories:NO
                        attributes:nil
                             error:error]) {
        return nil;
    }
    return stagingDirectory.stringByStandardizingPath;
}

- (void)cleanupWorldStagingDirectory:(nullable NSString *)stagingDirectory {
    if (stagingDirectory.length == 0) return;
    NSString *standardPath = stagingDirectory.stringByStandardizingPath;
    NSString *parentName = standardPath.stringByDeletingLastPathComponent.lastPathComponent;
    if (![parentName isEqualToString:PLWorldStagingRootName] || standardPath.lastPathComponent.length == 0) {
        NSLog(@"[WorldService] refusing to remove unexpected staging path: %@", stagingDirectory);
        return;
    }
    [[NSFileManager defaultManager] removeItemAtPath:standardPath error:nil];
}

- (BOOL)archiveEntries:(NSArray<NSString *> *)entries
  areSafeUnderDirectory:(NSString *)directory
                  error:(NSError **)error {
    NSString *root = directory.stringByStandardizingPath;
    NSString *rootPrefix = [root stringByAppendingString:@"/"];
    for (id rawEntry in entries) {
        if (![rawEntry isKindOfClass:[NSString class]]) continue;
        NSString *entry = [(NSString *)rawEntry stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        if (entry.length == 0) continue;
        NSArray<NSString *> *components = [entry componentsSeparatedByString:@"/"];
        if ([entry hasPrefix:@"/"] || [components containsObject:@".."]) {
            if (error) {
                *error = [NSError errorWithDomain:@"WorldServiceError"
                                             code:9
                                         userInfo:@{NSLocalizedDescriptionKey: @"The world archive contains an unsafe path."}];
            }
            return NO;
        }
        NSString *candidate = [[root stringByAppendingPathComponent:entry] stringByStandardizingPath];
        if (![candidate isEqualToString:root] && ![candidate hasPrefix:rootPrefix]) {
            if (error) {
                *error = [NSError errorWithDomain:@"WorldServiceError"
                                             code:9
                                         userInfo:@{NSLocalizedDescriptionKey: @"The world archive contains an unsafe path."}];
            }
            return NO;
        }
    }
    return YES;
}

// 找到唯一的最浅层世界根目录。压缩包可有任意层 wrapper，但多个同层世界
// 属于歧义输入，不能依赖目录枚举顺序任意安装其中一个。
- (nullable NSString *)worldDirectoryContainingLevelDatUnderPath:(NSString *)rootPath
                                                             error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = rootPath.stringByStandardizingPath;
    NSString *rootPrefix = [root stringByAppendingString:@"/"];
    NSMutableDictionary<NSString *, NSNumber *> *candidates = [NSMutableDictionary dictionary];
    NSDirectoryEnumerator<NSString *> *enumerator = [fm enumeratorAtPath:root];

    for (NSString *relativePath in enumerator) {
        NSString *fullPath = [[root stringByAppendingPathComponent:relativePath] stringByStandardizingPath];
        if (![fullPath hasPrefix:rootPrefix]) {
            if (error) {
                *error = [NSError errorWithDomain:@"WorldServiceError"
                                             code:9
                                         userInfo:@{NSLocalizedDescriptionKey: @"The extracted world escaped its staging directory."}];
            }
            return nil;
        }

        NSError *attributeError = nil;
        NSDictionary *attributes = [fm attributesOfItemAtPath:fullPath error:&attributeError];
        if (attributeError) {
            if (error) *error = attributeError;
            return nil;
        }
        if ([attributes[NSFileType] isEqualToString:NSFileTypeSymbolicLink]) {
            if (error) {
                *error = [NSError errorWithDomain:@"WorldServiceError"
                                             code:9
                                         userInfo:@{NSLocalizedDescriptionKey: @"The world archive contains a symbolic link."}];
            }
            return nil;
        }
        if (![relativePath.lastPathComponent isEqualToString:@"level.dat"] ||
            [[relativePath pathComponents] containsObject:@"__MACOSX"]) {
            continue;
        }
        if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular]) continue;

        NSString *worldDirectory = fullPath.stringByDeletingLastPathComponent;
        NSString *relativeWorld = [worldDirectory isEqualToString:root]
            ? @""
            : [worldDirectory substringFromIndex:rootPrefix.length];
        NSUInteger depth = relativeWorld.length == 0 ? 0 : relativeWorld.pathComponents.count;
        candidates[worldDirectory] = @(depth);
    }

    if (candidates.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"WorldServiceError"
                                         code:7
                                     userInfo:@{NSLocalizedDescriptionKey: @"The downloaded archive does not contain a valid Minecraft world (level.dat is missing)."}];
        }
        return nil;
    }

    NSUInteger minimumDepth = NSUIntegerMax;
    for (NSNumber *depth in candidates.allValues) minimumDepth = MIN(minimumDepth, depth.unsignedIntegerValue);
    NSArray<NSString *> *shallowest = [candidates keysOfEntriesPassingTest:^BOOL(NSString *key, NSNumber *depth, BOOL *stop) {
        return depth.unsignedIntegerValue == minimumDepth;
    }].allObjects;
    if (shallowest.count != 1) {
        if (error) {
            *error = [NSError errorWithDomain:@"WorldServiceError"
                                         code:10
                                     userInfo:@{NSLocalizedDescriptionKey: @"The world archive contains multiple ambiguous worlds."}];
        }
        return nil;
    }
    return shallowest.firstObject;
}

- (NSString *)sanitizedWorldDirectoryName:(nullable NSString *)preferredName {
    NSString *normalized = [(preferredName ?: @"") stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    NSString *name = [normalized.lastPathComponent stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([name.lowercaseString hasSuffix:@".zip"]) {
        name = [name substringToIndex:name.length - @".zip".length];
    }
    name = [[name componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet] componentsJoinedByString:@"_"];
    if (name.length == 0 || [name isEqualToString:@"."] || [name isEqualToString:@".."]) {
        return @"imported_world";
    }
    return name;
}

- (nullable PLStagedWorld *)stageWorldZipAt:(NSString *)zipPath
                           stagingDirectory:(NSString *)stagingDirectory
                                  worldName:(NSString *)worldName
                                      error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *staging = stagingDirectory.stringByStandardizingPath;
    NSString *stagingPrefix = [staging stringByAppendingString:@"/"];
    NSString *archivePath = zipPath.stringByStandardizingPath;
    if (![archivePath hasPrefix:stagingPrefix]) {
        if (error) {
            *error = [NSError errorWithDomain:@"WorldServiceError"
                                         code:9
                                     userInfo:@{NSLocalizedDescriptionKey: @"The world archive is outside its staging directory."}];
        }
        return nil;
    }

    NSError *archiveError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:archivePath error:&archiveError];
    NSArray<NSString *> *entries = archive ? [archive listFilenames:&archiveError] : nil;
    if (!archive || archiveError || entries.count == 0) {
        if (error) *error = archiveError ?: [NSError errorWithDomain:@"WorldServiceError"
                                                                code:5
                                                            userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1097", nil)}];
        return nil;
    }

    NSString *extractDirectory = [staging stringByAppendingPathComponent:@"extracted"];
    if (![self archiveEntries:entries areSafeUnderDirectory:extractDirectory error:error]) return nil;
    if (![fm createDirectoryAtPath:extractDirectory
       withIntermediateDirectories:NO
                        attributes:nil
                             error:error]) {
        return nil;
    }

    NSError *extractError = nil;
    if (![archive extractFilesTo:extractDirectory overwrite:NO error:&extractError] || extractError) {
        if (error) *error = extractError;
        return nil;
    }

    NSString *worldDirectory = [self worldDirectoryContainingLevelDatUnderPath:extractDirectory error:error];
    if (!worldDirectory) return nil;

    PLStagedWorld *stagedWorld = [[PLStagedWorld alloc] init];
    stagedWorld.stagingDirectory = staging;
    stagedWorld.worldDirectory = worldDirectory;
    stagedWorld.suggestedName = [self sanitizedWorldDirectoryName:
        [worldDirectory isEqualToString:extractDirectory] ? worldName : worldDirectory.lastPathComponent];
    return stagedWorld;
}

- (nullable NSString *)commitStagedWorld:(PLStagedWorld *)stagedWorld
                              toSavesDir:(NSString *)savesDir
                                   error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *staging = stagedWorld.stagingDirectory.stringByStandardizingPath;
    NSString *source = stagedWorld.worldDirectory.stringByStandardizingPath;
    NSString *stagingPrefix = [staging stringByAppendingString:@"/"];
    if (![source hasPrefix:stagingPrefix]) {
        if (error) {
            *error = [NSError errorWithDomain:@"WorldServiceError"
                                         code:9
                                     userInfo:@{NSLocalizedDescriptionKey: @"The staged world is outside its staging directory."}];
        }
        return nil;
    }

    NSString *levelDat = [source stringByAppendingPathComponent:@"level.dat"];
    NSDictionary *attributes = [fm attributesOfItemAtPath:levelDat error:error];
    if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular]) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:@"WorldServiceError"
                                         code:7
                                     userInfo:@{NSLocalizedDescriptionKey: @"The staged world does not contain a regular level.dat file."}];
        }
        return nil;
    }

    NSString *baseName = [self sanitizedWorldDirectoryName:stagedWorld.suggestedName];
    for (NSInteger suffix = 0; suffix < 10000; suffix++) {
        NSString *candidateName = suffix == 0
            ? baseName
            : [NSString stringWithFormat:@"%@_%ld", baseName, (long)suffix];
        NSString *destination = [savesDir stringByAppendingPathComponent:candidateName];
        if ([fm fileExistsAtPath:destination]) continue;

        NSError *moveError = nil;
        if ([fm moveItemAtPath:source toPath:destination error:&moveError]) {
            NSString *installedLevelDat = [destination stringByAppendingPathComponent:@"level.dat"];
            NSDictionary *installedAttributes = [fm attributesOfItemAtPath:installedLevelDat error:&moveError];
            if ([installedAttributes[NSFileType] isEqualToString:NSFileTypeRegular]) {
                NSLog(@"[WorldService] staged world committed to: %@", destination);
                return destination;
            }
            [fm removeItemAtPath:destination error:nil];
            if (error) *error = moveError ?: [NSError errorWithDomain:@"WorldServiceError"
                                                                  code:7
                                                              userInfo:@{NSLocalizedDescriptionKey: @"The installed world failed level.dat validation."}];
            return nil;
        }

        // 两个并发导入可能同时选择同一名字。目标刚被占用时换下一个后缀；
        // 其他移动错误直接返回，绝不删除或覆盖目标目录。
        if ([fm fileExistsAtPath:destination]) continue;
        if (error) *error = moveError;
        return nil;
    }

    if (error) {
        *error = [NSError errorWithDomain:@"WorldServiceError"
                                     code:11
                                 userInfo:@{NSLocalizedDescriptionKey: @"Unable to allocate a unique world directory name."}];
    }
    return nil;
}

- (BOOL)isWorldTaskItemCurrent:(nullable DownloadTaskItem *)taskItem
                     generation:(NSNumber *)generation {
    if (!taskItem || !generation) return NO;
    DownloadTaskItem *latestTask = [[DownloadTaskManager sharedManager] taskWithId:taskItem.taskId];
    return latestTask != nil &&
           latestTask.state == DownloadTaskStateDownloading &&
           [latestTask.userInfo[PLWorldDownloadGenerationKey] isEqual:generation];
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

    // 下载到 saves 同卷的唯一 staging。任何下载、解压或验证失败都只清理该目录，
    // 不会把压缩包内容直接写入已有世界。
    NSError *stagingError = nil;
    NSString *stagingDirectory = [self createWorldStagingDirectoryForSavesDir:savesFolder error:&stagingError];
    if (!stagingDirectory) {
        if (completion) {
            NSError *error = stagingError ?: [NSError errorWithDomain:@"WorldServiceError"
                                                                  code:8
                                                              userInfo:@{NSLocalizedDescriptionKey: @"Unable to create world staging directory."}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
        }
        return;
    }
    NSString *destinationPath = [stagingDirectory stringByAppendingPathComponent:PLWorldArchiveFileName];
    // 同时记录预期世界名（用于无顶层目录时的子目录命名）
    NSString *worldNameForExtract = item.displayName ?: item.worldName ?: [url lastPathComponent];

    // 创建下载任务（默认会话配置，无后台限速）
    NSURLSessionDownloadTask *task = [self.downloadSession downloadTaskWithURL:url];
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
    taskItem.userInfo[@"stagingDirectory"] = stagingDirectory;
    taskItem.userInfo[PLWorldDownloadGenerationKey] = @(task.taskIdentifier);
    // 世界暂停恢复需要用新的 NSURLSessionTask 从头重建，不应消耗网络失败重试预算。
    taskItem.maxRetryCount = 0;
    taskItem.autoPresentDetail = YES;
    [self.downloadStateLock lock];
    if (completion) self.downloadCompletionHandlers[task] = completion;
    self.downloadDestinationPaths[task] = destinationPath;
    self.downloadStagingDirectories[task] = stagingDirectory;
    self.downloadWorldNames[task] = worldNameForExtract;
    self.downloadSavesFolders[task] = savesFolder;
    if (progressObj) self.downloadProgresses[task] = progressObj;
    if (progress) self.downloadProgressHandlers[task] = progress;
    self.downloadTaskItems[task] = taskItem;
    [self.downloadStateLock unlock];
    [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId stages:PLTaskStagesWorld()];
    [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId state:DownloadTaskStateDownloading];
    [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId stageAtIndex:0 status:PLTaskStageStatusRunning];

    // 设置 retryHandler：FCL 风格重新下载
    __weak typeof(self) weakSelf = self;
    NSString *capturedWorldName = worldNameForExtract;
    NSString *capturedSavesFolder = savesFolder;
    WorldDownloadCompletionHandler capturedCompletion = completion;
    void (^capturedProgress)(NSProgress *) = progress;
    taskItem.retryHandler = ^id(DownloadTaskItem *taskItemRef) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return nil;
        NSURL *retryURL = [NSURL URLWithString:taskItemRef.downloadURL] ?: url;
        if (!retryURL) return nil;
        NSError *retryStagingError = nil;
        NSString *retryStagingDirectory = [strongSelf createWorldStagingDirectoryForSavesDir:capturedSavesFolder
                                                                                        error:&retryStagingError];
        if (!retryStagingDirectory) {
            NSError *finalError = retryStagingError ?: [NSError errorWithDomain:@"WorldServiceError"
                                                                            code:8
                                                                        userInfo:@{NSLocalizedDescriptionKey: @"Unable to create world staging directory."}];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskItemRef.taskId completedWithError:finalError];
            return nil;
        }
        NSString *retryDestinationPath = [retryStagingDirectory stringByAppendingPathComponent:PLWorldArchiveFileName];
        NSURLSessionDownloadTask *newTask = [strongSelf.downloadSession downloadTaskWithURL:retryURL];
        taskItemRef.userInfo[PLWorldDownloadGenerationKey] = @(newTask.taskIdentifier);
        taskItemRef.userInfo[@"destinationPath"] = retryDestinationPath;
        taskItemRef.userInfo[@"stagingDirectory"] = retryStagingDirectory;
        taskItemRef.supportsResume = YES;
        // manager 随后依据 rawTask 获取并发槽；必须在切换 Downloading 前写入。
        taskItemRef.rawTask = newTask;
        [strongSelf.downloadStateLock lock];
        if (capturedCompletion) strongSelf.downloadCompletionHandlers[newTask] = capturedCompletion;
        strongSelf.downloadDestinationPaths[newTask] = retryDestinationPath;
        strongSelf.downloadStagingDirectories[newTask] = retryStagingDirectory;
        strongSelf.downloadWorldNames[newTask] = capturedWorldName;
        strongSelf.downloadSavesFolders[newTask] = capturedSavesFolder;
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

        __block NSString *stagingDirectory = nil;
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

            NSError *stagingError = nil;
            stagingDirectory = [self createWorldStagingDirectoryForSavesDir:savesFolder error:&stagingError];
            if (!stagingDirectory) {
                if (completion) {
                    NSError *error = stagingError ?: [NSError errorWithDomain:@"WorldServiceError"
                                                                          code:8
                                                                      userInfo:@{NSLocalizedDescriptionKey: @"Unable to create world staging directory."}];
                    dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
                }
                return;
            }

            // 复制进唯一 staging 后再读取，既保持 security-scoped URL 生命周期安全，
            // 也确保后续解压和最终 rename 都不接触现有世界。
            NSString *stagedZipPath = [stagingDirectory stringByAppendingPathComponent:PLWorldArchiveFileName];
            NSError *copyError = nil;
            if (![[NSFileManager defaultManager] copyItemAtPath:sourcePath toPath:stagedZipPath error:&copyError]) {
                if (completion) {
                    NSError *error = copyError ?: [NSError errorWithDomain:@"WorldServiceError"
                                                                       code:4
                                                                   userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1096", nil)}];
                    dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
                }
                return;
            }

            // 推导世界名（去除 .zip 后缀）
            NSString *worldName = [sourceURL lastPathComponent];
            if ([worldName.lowercaseString hasSuffix:@".zip"]) {
                worldName = [worldName substringToIndex:worldName.length - @".zip".length];
            }

            NSError *installError = nil;
            PLStagedWorld *stagedWorld = [self stageWorldZipAt:stagedZipPath
                                             stagingDirectory:stagingDirectory
                                                    worldName:worldName
                                                        error:&installError];
            NSString *installedWorldPath = stagedWorld
                ? [self commitStagedWorld:stagedWorld toSavesDir:savesFolder error:&installError]
                : nil;
            BOOL success = installedWorldPath.length > 0;

            if (completion || (success && progress)) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (success) {
                        if (progress) {
                            NSProgress *prog = [NSProgress progressWithTotalUnitCount:1];
                            prog.completedUnitCount = 1;
                            progress(prog);
                        }
                        if (completion) completion(YES, nil);
                    } else if (completion) {
                        completion(NO, installError ?: [NSError errorWithDomain:@"WorldServiceError"
                                                                            code:5
                                                                        userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1097", nil)}]);
                    }
                });
            }
        } @finally {
            [self cleanupWorldStagingDirectory:stagingDirectory];
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
    NSString *stagingDirectory = self.downloadStagingDirectories[downloadTask];
    NSString *worldName = self.downloadWorldNames[downloadTask];
    NSString *savesFolder = self.downloadSavesFolders[downloadTask];
    DownloadTaskItem *taskItem = self.downloadTaskItems[downloadTask];

    [self.downloadCompletionHandlers removeObjectForKey:downloadTask];
    [self.downloadDestinationPaths removeObjectForKey:downloadTask];
    [self.downloadStagingDirectories removeObjectForKey:downloadTask];
    [self.downloadWorldNames removeObjectForKey:downloadTask];
    [self.downloadSavesFolders removeObjectForKey:downloadTask];
    [self.downloadProgresses removeObjectForKey:downloadTask];
    [self.downloadProgressHandlers removeObjectForKey:downloadTask];
    [self.downloadTaskItems removeObjectForKey:downloadTask];
    [self.downloadProgressSnapshots removeObjectForKey:downloadTask];
    [self.downloadStateLock unlock];

    if (!destinationPath || !stagingDirectory || !savesFolder) {
        NSError *metadataError = [NSError errorWithDomain:@"WorldServiceError"
                                                      code:6
                                                  userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1098", nil)}];
        [self cleanupWorldStagingDirectory:stagingDirectory];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self isWorldTaskItemCurrent:taskItem generation:generation]) return;
            DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
            [manager updateTaskWithId:taskItem.taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
            [manager setTaskWithId:taskItem.taskId completedWithError:metadataError];
            if (handler) handler(NO, metadataError);
        });
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *moveError = nil;
    if (![fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:destinationPath] error:&moveError]) {
        NSError *finalMoveError = moveError ?: [NSError errorWithDomain:@"WorldServiceError"
                                                                    code:4
                                                                userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1096", nil)}];
        [self cleanupWorldStagingDirectory:stagingDirectory];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self isWorldTaskItemCurrent:taskItem generation:generation]) return;
            DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
            [manager updateTaskWithId:taskItem.taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
            [manager setTaskWithId:taskItem.taskId completedWithError:finalMoveError];
            if (handler) handler(NO, finalMoveError);
        });
        return;
    }

    // 下载完成后只允许在 staging 中继续解压。暂停、取消或旧 generation 即使
    // 解压仍在运行，也只能清理 staging，不能把任何目录提交到 saves。
    if (![self isWorldTaskItemCurrent:taskItem generation:generation]) {
        [self cleanupWorldStagingDirectory:stagingDirectory];
        return;
    }
    taskItem.supportsResume = NO;
    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    [manager updateTaskWithId:taskItem.taskId stageAtIndex:0 status:PLTaskStageStatusCompleted];
    [manager updateTaskWithId:taskItem.taskId currentStageIndex:1];
    [manager updateTaskWithId:taskItem.taskId stageAtIndex:1 status:PLTaskStageStatusRunning];

    // 后台阶段只写唯一 staging；最终进入 saves 的 rename 在主线程 gate 内完成，
    // 与 UI 的暂停/取消操作形成确定顺序。
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *stageError = nil;
        PLStagedWorld *stagedWorld = [self stageWorldZipAt:destinationPath
                                          stagingDirectory:stagingDirectory
                                                 worldName:worldName ?: @"imported_world"
                                                     error:&stageError];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self isWorldTaskItemCurrent:taskItem generation:generation]) {
                [self cleanupWorldStagingDirectory:stagingDirectory];
                return;
            }

            DownloadTaskManager *currentManager = [DownloadTaskManager sharedManager];
            if (!stagedWorld) {
                NSError *finalError = stageError ?: [NSError errorWithDomain:@"WorldServiceError"
                                                                         code:5
                                                                     userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1097", nil)}];
                [self cleanupWorldStagingDirectory:stagingDirectory];
                [currentManager updateTaskWithId:taskItem.taskId stageAtIndex:1 status:PLTaskStageStatusFailed];
                [currentManager setTaskWithId:taskItem.taskId completedWithError:finalError];
                if (handler) handler(NO, finalError);
                return;
            }

            NSError *commitError = nil;
            NSString *installedWorldPath = [self commitStagedWorld:stagedWorld
                                                        toSavesDir:savesFolder
                                                             error:&commitError];
            [self cleanupWorldStagingDirectory:stagingDirectory];
            if (!installedWorldPath) {
                NSError *finalError = commitError ?: [NSError errorWithDomain:@"WorldServiceError"
                                                                          code:5
                                                                      userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1097", nil)}];
                if (![self isWorldTaskItemCurrent:taskItem generation:generation]) return;
                [currentManager updateTaskWithId:taskItem.taskId stageAtIndex:1 status:PLTaskStageStatusFailed];
                [currentManager setTaskWithId:taskItem.taskId completedWithError:finalError];
                if (handler) handler(NO, finalError);
                return;
            }

            // 防御后台状态变更：若 commit 后任务已不再属于本 generation，回滚
            // 本次唯一目标。它从未覆盖旧世界，因此可安全删除。
            if (![self isWorldTaskItemCurrent:taskItem generation:generation]) {
                [fm removeItemAtPath:installedWorldPath error:nil];
                return;
            }
            [currentManager updateTaskWithId:taskItem.taskId stageAtIndex:1 status:PLTaskStageStatusCompleted];
            [currentManager setTaskWithId:taskItem.taskId completedWithError:nil];
            DownloadTaskItem *completedTask = [currentManager taskWithId:taskItem.taskId];
            if (completedTask.state != DownloadTaskStateCompleted ||
                ![completedTask.userInfo[PLWorldDownloadGenerationKey] isEqual:generation]) {
                [fm removeItemAtPath:installedWorldPath error:nil];
                return;
            }
            if (handler) handler(YES, nil);
        });
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        NSNumber *generation = @(task.taskIdentifier);
        [self.downloadStateLock lock];
        WorldDownloadCompletionHandler handler = self.downloadCompletionHandlers[task];
        DownloadTaskItem *taskItem = self.downloadTaskItems[task];
        NSString *stagingDirectory = self.downloadStagingDirectories[task];
        [self.downloadTaskItems removeObjectForKey:task];
        [self.downloadProgressSnapshots removeObjectForKey:task];
        [self.downloadCompletionHandlers removeObjectForKey:task];
        [self.downloadDestinationPaths removeObjectForKey:task];
        [self.downloadStagingDirectories removeObjectForKey:task];
        [self.downloadWorldNames removeObjectForKey:task];
        [self.downloadSavesFolders removeObjectForKey:task];
        [self.downloadProgresses removeObjectForKey:task];
        [self.downloadProgressHandlers removeObjectForKey:task];
        [self.downloadStateLock unlock];
        [self cleanupWorldStagingDirectory:stagingDirectory];

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
