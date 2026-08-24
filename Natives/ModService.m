#import "utils.h"
//
//  ModService.m
//  AmethystMods
//
//  修改：增加文件修改时间缓存，大幅提升扫描速度
//  修改：文件下载改走 PLDownloadClient 统一下载器（镜像候选 + SHA1 校验 + 断点续传），
//        移除自建 NSURLSession 下载 delegate（spec optimize-download-system Task 4.2 / 5.1 / 5.2）
//

#import "ModService.h"
#import <CommonCrypto/CommonCrypto.h>
#import <UIKit/UIKit.h>
#import "PLProfiles.h"
#import "ModItem.h"
#import "UnzipKit.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "PLTaskStages.h"
#import "LauncherPreferences.h"
#import "PLDownloadClient.h"
#import "PLMirrorCenter.h"

@interface ModService ()
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
@property (nonatomic, strong) NSMutableDictionary<NSString *, void(^)(NSProgress *)> *downloadProgressHandlers;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ModDownloadHandler> *downloadCompletionHandlers;

// 缓存
@property (nonatomic, strong) NSMutableDictionary<NSString *, ModItem *> *metadataCache;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *checkpointTimes;
@property (nonatomic, strong) dispatch_queue_t cacheQueue;
@end

@implementation ModService

// ---------- TOML 解析（未修改）----------
- (nullable id)parseTomlValue:(NSString *)valPart inLines:(NSArray<NSString *> *)lines atIndex:(NSUInteger *)i {
    NSString *trimmedVal = [valPart stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *delimiter = nil;
    if ([trimmedVal hasPrefix:@"'''"]) delimiter = @"'''";
    else if ([trimmedVal hasPrefix:@"\"\"\""]) delimiter = @"\"\"\"";

    if (delimiter) {
        NSMutableString *multiLineContent = [[trimmedVal substringFromIndex:3] mutableCopy];
        if ([multiLineContent hasSuffix:delimiter]) {
            return [multiLineContent substringToIndex:multiLineContent.length - 3];
        } else {
            NSMutableArray<NSString *> *contentLines = [NSMutableArray array];
            [contentLines addObject:multiLineContent];
            (*i)++;
            while (*i < lines.count) {
                NSString *nextLine = lines[*i];
                NSRange endDelimiterRange = [nextLine rangeOfString:delimiter];
                if (endDelimiterRange.location != NSNotFound) {
                    [contentLines addObject:[nextLine substringToIndex:endDelimiterRange.location]];
                    break;
                } else {
                    [contentLines addObject:nextLine];
                }
                (*i)++;
            }
            return [contentLines componentsJoinedByString:@"\n"];
        }
    }

    if (([trimmedVal hasPrefix:@"\""] && [trimmedVal hasSuffix:@"\""]) ||
        ([trimmedVal hasPrefix:@"'"] && [trimmedVal hasSuffix:@"'"])) {
        if (trimmedVal.length > 1) {
            return [trimmedVal substringWithRange:NSMakeRange(1, trimmedVal.length - 2)];
        }
        return @"";
    }
    return trimmedVal;
}

- (NSDictionary<NSString *, id> *)parseTomlString:(NSString *)s {
    if (!s) return nil;
    NSMutableDictionary<NSString *, id> *root = [NSMutableDictionary dictionary];
    NSMutableDictionary *currentTable = root;
    NSString *currentTableName = nil;
    NSArray<NSString *> *lines = [s componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *line = lines[i];
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed hasPrefix:@"#"] || trimmed.length == 0) continue;

        if ([trimmed hasPrefix:@"[["] && [trimmed hasSuffix:@"]]"]) {
            currentTableName = [trimmed substringWithRange:NSMakeRange(2, trimmed.length - 4)];
            NSMutableArray *array = root[currentTableName] ?: [NSMutableArray array];
            root[currentTableName] = array;
            currentTable = [NSMutableDictionary dictionary];
            [array addObject:currentTable];
            continue;
        } else if ([trimmed hasPrefix:@"["] && [trimmed hasSuffix:@"]"]) {
            currentTableName = [trimmed substringWithRange:NSMakeRange(1, trimmed.length - 2)];
            currentTable = [NSMutableDictionary dictionary];
            root[currentTableName] = currentTable;
            continue;
        }

        NSRange eqRange = [trimmed rangeOfString:@"="];
        if (eqRange.location != NSNotFound) {
            NSString *key = [[trimmed substringToIndex:eqRange.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSString *valPart = [trimmed substringFromIndex:NSMaxRange(eqRange)];
            id value = [self parseTomlValue:valPart inLines:lines atIndex:&i];
            if (value) {
                currentTable[key] = value;
            }
        }
    }
    return root;
}

// ---------- 初始化 ----------
+ (instancetype)sharedService {
    static ModService *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [[ModService alloc] init];
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

        // 初始化缓存
        _metadataCache = [NSMutableDictionary dictionary];
        _checkpointTimes = [NSMutableDictionary dictionary];
        _cacheQueue = dispatch_queue_create("com.amethyst.modcache", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

// ---------- 辅助方法 ----------
- (nullable NSString *)sha1ForFileAtPath:(NSString *)path {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) return nil;
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(d.bytes, (CC_LONG)d.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex copy];
}

- (NSString *)iconCachePathForURL:(NSString *)urlString {
    if (!urlString) return nil;
    NSString *cacheDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    NSString *folder = [cacheDir stringByAppendingPathComponent:@"mod_icons"];
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

- (nullable NSData *)readFileFromJar:(NSString *)jarPath entryName:(NSString *)entryName {
    if (!jarPath || !entryName) return nil;
    NSError *err = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:jarPath error:&err];
    if (!archive || err) return nil;
    NSData *data = [archive extractDataFromFile:entryName error:&err];
    return data;
}

/// 解析 profile 的 gameDir 为绝对路径。
/// profile gameDir 通常是相对路径（如 "./custom_gamedir/{name}"），需相对于 POJAV_GAME_DIR 解析。
/// 之前直接使用相对路径会导致 mods 文件夹找不到（fileExistsAtPath 对相对路径基于 cwd 解析，
/// 而 cwd 不一定是 POJAV_GAME_DIR）。
- (nullable NSString *)resolveAbsoluteGameDirForProfile:(NSString *)profileName {
    return [PLProfiles resolvedGameDirectoryForProfileName:profileName];
}

- (nullable NSString *)existingModsFolderForProfile:(NSString *)profileName {
    NSString *profile = profileName.length ? profileName : @"default";
    NSFileManager *fm = [NSFileManager defaultManager];

    // 优先用 profile gameDir（已解析为绝对路径）
    NSString *resolvedGameDir = [self resolveAbsoluteGameDirForProfile:profile];
    if (resolvedGameDir.length > 0) {
        NSString *modsPath = [resolvedGameDir stringByAppendingPathComponent:@"mods"];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:modsPath isDirectory:&isDir] && isDir) {
            return modsPath;
        }
    }

    // 回退到 POJAV_GAME_DIR/mods
    const char *gameDirC = getenv("POJAV_GAME_DIR");
    if (gameDirC) {
        NSString *gameDir = [NSString stringWithUTF8String:gameDirC];
        NSString *modsPath = [gameDir stringByAppendingPathComponent:@"mods"];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:modsPath isDirectory:&isDir] && isDir) {
            return modsPath;
        }
    }
    return nil;
}

/// 获取当前 profile 的 mods 目录，不存在时自动创建
- (nullable NSString *)ensureModsFolderForProfile:(NSString *)profileName error:(NSError **)error {
    NSString *profile = profileName.length ? profileName : @"default";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *modsPath = nil;

    // 优先用 profile gameDir（已解析为绝对路径）
    NSString *resolvedGameDir = [self resolveAbsoluteGameDirForProfile:profile];
    if (resolvedGameDir.length > 0) {
        modsPath = [resolvedGameDir stringByAppendingPathComponent:@"mods"];
    }

    if (!modsPath) {
        const char *gameDirC = getenv("POJAV_GAME_DIR");
        if (gameDirC) {
            NSString *gameDir = [NSString stringWithUTF8String:gameDirC];
            modsPath = [gameDir stringByAppendingPathComponent:@"mods"];
        }
    }

    if (!modsPath) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModService" code:1 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_105", nil)}];
        }
        return nil;
    }

    BOOL isDir = NO;
    if (![fm fileExistsAtPath:modsPath isDirectory:&isDir]) {
        // 目录不存在，创建
        NSError *createError = nil;
        [fm createDirectoryAtPath:modsPath withIntermediateDirectories:YES attributes:nil error:&createError];
        if (createError) {
            if (error) *error = createError;
            return nil;
        }
        NSLog(@"[ModService] Created mods directory: %@", modsPath);
    } else if (!isDir) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModService" code:2 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_451", nil), modsPath]}];
        }
        return nil;
    }
    return modsPath;
}

// ---------- 缓存方法 ----------
- (BOOL)needsRescanForPath:(NSString *)path {
    __block BOOL needs = YES;
    dispatch_sync(self.cacheQueue, ^{
        NSDate *lastScan = self.checkpointTimes[path];
        if (lastScan) {
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
            NSDate *modifyDate = attrs[NSFileModificationDate];
            if (modifyDate && [modifyDate isEqualToDate:lastScan]) {
                needs = NO;
            }
        }
    });
    return needs;
}

- (void)updateCheckpointForPath:(NSString *)path {
    dispatch_barrier_async(self.cacheQueue, ^{
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        NSDate *modifyDate = attrs[NSFileModificationDate];
        if (modifyDate) {
            self.checkpointTimes[path] = modifyDate;
        }
    });
}

- (nullable ModItem *)cachedModForPath:(NSString *)path {
    __block ModItem *item = nil;
    dispatch_sync(self.cacheQueue, ^{
        item = self.metadataCache[path];
    });
    return item;
}

- (void)cacheModItem:(ModItem *)item forPath:(NSString *)path {
    dispatch_barrier_async(self.cacheQueue, ^{
        self.metadataCache[path] = item;
    });
}

// ---------- 扫描模组（核心优化）----------
- (void)scanModsForProfile:(NSString *)profileName completion:(ModListHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *modsFolder = [self existingModsFolderForProfile:profileName];
        NSMutableArray<ModItem *> *items = [NSMutableArray array];

        if (!modsFolder) {
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(items); });
            }
            return;
        }

        NSArray<NSString *> *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:modsFolder error:nil];
        dispatch_group_t group = dispatch_group_create();

        for (NSString *fileName in contents) {
            if ([fileName.lowercaseString hasSuffix:@".jar"] || [fileName.lowercaseString hasSuffix:@".jar.disabled"]) {
                NSString *fullPath = [modsFolder stringByAppendingPathComponent:fileName];

                // 检查缓存
                if (![self needsRescanForPath:fullPath]) {
                    ModItem *cached = [self cachedModForPath:fullPath];
                    if (cached) {
                        [items addObject:cached];
                        continue;
                    }
                }

                ModItem *mod = [[ModItem alloc] initWithFilePath:fullPath];
                [items addObject:mod];

                dispatch_group_enter(group);
                [self fetchMetadataForMod:mod completion:^(ModItem *populatedMod, NSError *error) {
                    if (!error) {
                        [self cacheModItem:populatedMod forPath:fullPath];
                        [self updateCheckpointForPath:fullPath];
                    }
                    dispatch_group_leave(group);
                }];
            }
        }

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            [items sortUsingComparator:^NSComparisonResult(ModItem *obj1, ModItem *obj2) {
                NSString *name1 = obj1.displayName ?: obj1.fileName;
                NSString *name2 = obj2.displayName ?: obj2.fileName;
                return [name1 localizedCaseInsensitiveCompare:name2];
            }];
            if (completion) completion(items);
        });
    });
}

// ---------- 元数据获取（原逻辑，仅被上面调用）----------
- (void)fetchMetadataForMod:(ModItem *)mod completion:(ModMetadataHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try {
            // Fabric
            NSData *fabricData = [self readFileFromJar:mod.filePath entryName:@"fabric.mod.json"];
            if (fabricData) {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:fabricData options:0 error:nil];
                if ([json isKindOfClass:[NSDictionary class]]) {
                    mod.isFabric = YES;
                    mod.onlineID = json[@"id"];
                    mod.version = json[@"version"];
                    mod.displayName = json[@"name"];
                    mod.modDescription = json[@"description"];
                    mod.author = [json[@"authors"] componentsJoinedByString:@", "];

                    NSDictionary *deps = json[@"depends"];
                    if ([deps isKindOfClass:[NSDictionary class]] && [deps[@"minecraft"] isKindOfClass:[NSString class]]) {
                        mod.gameVersion = deps[@"minecraft"];
                    }

                    NSString *iconPath = json[@"icon"];
                    if ([iconPath isKindOfClass:[NSString class]]) {
                        NSData *iconData = [self readFileFromJar:mod.filePath entryName:iconPath];
                        if (iconData) mod.icon = [[UIImage alloc] initWithData:iconData];
                    }
                    if (completion) completion(mod, nil);
                    return;
                }
            }

            // Forge / NeoForge
            NSData *tomlData = [self readFileFromJar:mod.filePath entryName:@"META-INF/mods.toml"];
            if (tomlData) {
                mod.isForge = YES;
            } else {
                tomlData = [self readFileFromJar:mod.filePath entryName:@"META-INF/neoforge.mods.toml"];
                if (tomlData) mod.isNeoForge = YES;
            }

            if (tomlData) {
                NSString *tomlString = [[NSString alloc] initWithData:tomlData encoding:NSUTF8StringEncoding];
                NSDictionary<NSString *, id> *toml = [self parseTomlString:tomlString];
                NSArray *mods = toml[@"mods"];
                if ([mods isKindOfClass:[NSArray class]] && mods.count > 0) {
                    NSDictionary *modInfo = mods.firstObject;
                    if ([modInfo isKindOfClass:[NSDictionary class]]) {
                        mod.onlineID = modInfo[@"modId"];
                        mod.version = modInfo[@"version"];
                        mod.displayName = modInfo[@"displayName"];
                        mod.modDescription = modInfo[@"description"];
                        mod.author = modInfo[@"authors"];

                        NSArray *deps = nil;
                        for (NSString *key in toml) {
                            if ([key hasPrefix:@"dependencies"]) {
                                deps = toml[key];
                                break;
                            }
                        }
                        if ([deps isKindOfClass:[NSArray class]]) {
                            for (NSDictionary *depInfo in deps) {
                                if ([depInfo isKindOfClass:[NSDictionary class]] && [depInfo[@"modId"] isEqualToString:@"minecraft"]) {
                                    mod.gameVersion = depInfo[@"versionRange"];
                                    break;
                                }
                            }
                        }

                        NSString *logoFile = modInfo[@"logoFile"];
                        if (logoFile.length > 0) {
                            NSData *logoData = [self readFileFromJar:mod.filePath entryName:logoFile];
                            if (logoData) mod.icon = [[UIImage alloc] initWithData:logoData];
                        }
                        if (completion) completion(mod, nil);
                        return;
                    }
                }
            }
        } @catch (NSException *exception) {
            NSLog(@"[ModService] CRITICAL: Exception while parsing %@: %@", mod.fileName, exception);
        }
        if (completion) completion(mod, nil);
    });
}

// ---------- 文件操作（启用/禁用、删除）----------
- (BOOL)toggleEnableForMod:(ModItem *)mod error:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *currentPath = mod.filePath;
    NSString *newPath;

    if (mod.disabled) {
        if ([currentPath.lowercaseString hasSuffix:@".jar.disabled"]) {
            newPath = [currentPath substringToIndex:currentPath.length - 9];
        } else {
            if (error) *error = [NSError errorWithDomain:@"ModServiceError" code:101 userInfo:@{NSLocalizedDescriptionKey:localize(@"i18n_str_452", nil)}];
            return NO;
        }
    } else {
        newPath = [currentPath stringByAppendingString:@".disabled"];
    }

    BOOL success = [fileManager moveItemAtPath:currentPath toPath:newPath error:error];
    if (success) {
        mod.filePath = newPath;
        mod.fileName = [newPath lastPathComponent];
        [mod refreshDisabledFlag];
    }
    return success;
}

- (BOOL)deleteMod:(ModItem *)mod error:(NSError **)error {
    return [[NSFileManager defaultManager] removeItemAtPath:mod.filePath error:error];
}

// ---------- 下载（PLDownloadClient 统一下载器：镜像候选 + SHA1 校验 + 增量命中 + 断点续传）----------
- (void)downloadMod:(ModItem *)mod toProfile:(NSString *)profileName completion:(ModDownloadHandler)completion {
    [self downloadMod:mod toProfile:profileName expectedSHA1:nil progress:nil completion:completion];
}

// ---------- 带进度回调的下载 ----------
- (void)downloadMod:(ModItem *)mod
          toProfile:(NSString *)profileName
            progress:(void (^)(NSProgress *downloadProgress))progress
          completion:(ModDownloadHandler)completion {
    [self downloadMod:mod toProfile:profileName expectedSHA1:nil progress:progress completion:completion];
}

// ---------- 带 SHA1 校验的下载（spec Task 5.1：expectedSHA1 传入即启用校验）----------
- (void)downloadMod:(ModItem *)mod
          toProfile:(NSString *)profileName
       expectedSHA1:(nullable NSString *)expectedSHA1
           progress:(nullable void (^)(NSProgress *downloadProgress))progress
         completion:(ModDownloadHandler)completion {
    NSError *folderError = nil;
    NSString *modsFolder = [self ensureModsFolderForProfile:profileName error:&folderError];
    if (!modsFolder) {
        if (completion) {
            NSError *error = folderError ?: [NSError errorWithDomain:@"ModServiceError" code:1 userInfo:@{NSLocalizedDescriptionKey:localize(@"i18n_str_453", nil)}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
        }
        return;
    }

    NSURL *url = [NSURL URLWithString:mod.selectedVersionDownloadURL];
    if (!url) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"ModServiceError" code:2 userInfo:@{NSLocalizedDescriptionKey:localize(@"i18n_str_454", nil)}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
        }
        return;
    }

    NSString *destinationPath = [modsFolder stringByAppendingPathComponent:mod.fileName];

    // 注册到统一下载任务管理器（rawTask 稍后赋值为 PLDownloadOperation；悬浮球已移除，始终注册以便下载任务列表跟踪）
    NSString *resourceName = mod.fileName.length > 0 ? mod.fileName : (mod.displayName.length > 0 ? mod.displayName : @"mod");
    NSString *displayName = mod.displayName.length > 0 ? mod.displayName : resourceName;
    NSString *downloadSource = getPrefObject(@"general.download_source") ?: @"official";
    DownloadTaskItem *taskItem = [[DownloadTaskManager sharedManager]
        registerTaskWithResourceType:DownloadTaskResourceTypeMod
                        resourceName:resourceName
                         displayName:displayName
                      downloadSource:downloadSource
                             rawTask:nil
                      supportsResume:YES
                             iconURL:mod.iconURL];
    taskItem.downloadURL = mod.selectedVersionDownloadURL;
    NSString *taskProfileName = [PLProfiles effectiveProfileNameForPreferredName:profileName];
    if (taskProfileName.length > 0) taskItem.userInfo[@"profileName"] = taskProfileName;
    taskItem.userInfo[@"destinationPath"] = destinationPath;
    // redesign-download-ui Phase 4：单文件下载接入统一进度页——
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
    // 镜像候选列表：原始 CDN URL（cdn.modrinth.com / edge.forgecdn.net 等）+ MCIM 镜像，
    // 按 download.assetDownloadSource 策略排序（PLMirrorCenter 统一收敛，替代旧版独立镜像工具类）
    request.candidateURLs = [PLMirrorCenter candidateURLsForOriginalURL:url
                                                          resourceType:PLMirrorResourceTypeAssetDownload];
    // Task 5.1：expectedSHA1（版本模型 files[].hashes.sha1）传入即启用 SHA1 校验，
    // 校验失败由 PLDownloadClient 内部按镜像/退避节奏重试
    request.expectedSHA1 = expectedSHA1;
    // Task 5.2：目标文件已存在且校验通过 → PLDownloadClient 零流量直接成功（增量下载）；
    // 目标路径语义与原实现一致（mods/<fileName>.jar）
    request.destinationPath = destinationPath;
    // taskIdentifier 用 DownloadTaskManager 的 taskId，resumeData 断点数据跨次下载可复用
    request.taskIdentifier = taskItem.taskId;
    // 无 SHA1 时对 .jar（zip 格式）做 EOCD 兜底完整性校验
    request.allowZipFallbackCheck = YES;
    retryRequest = request;

    [self startPLDownloadWithRequest:request taskItem:taskItem progress:progress completion:completion];
}

#pragma mark - PLDownloadClient 封装（进度 delta 累计 / 速率采样 / 完成分发）

/// 发起（或重发）PLDownloadClient 请求并挂接进度、速率、完成回调。
/// progress/completion 传 nil 时不覆盖已登记的回调（retryHandler 重发时复用首次回调）。
- (nullable PLDownloadOperation *)startPLDownloadWithRequest:(PLDownloadRequest *)request
                                                     taskItem:(DownloadTaskItem *)taskItem
                                                     progress:(nullable void(^)(NSProgress *))progress
                                                   completion:(nullable ModDownloadHandler)completion {
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
    // redesign-download-ui Phase 4：单阶段任务进入下载时将阶段0 置为 Running
    [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                              stageAtIndex:0
                                                  status:PLTaskStageStatusRunning];
    // 与完成回调共用同一把锁，确保“注册为下载中”严格发生在任何终态之前。
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
    void (^progressHandler)(NSProgress *) = self.downloadProgressHandlers[taskId];
    [self.downloadStateLock unlock];

    double fraction = totalStored > 0 ? (double)accumulated / (double)totalStored : -1.0;
    [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                 progress:fraction
                                               totalBytes:totalStored
                                          downloadedBytes:accumulated];
    // redesign-download-ui Phase 4：单阶段任务的阶段进度与任务总进度保持一致
    [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                              stageAtIndex:0
                                                  progress:fraction
                                                 message:nil];

    if (!progressHandler) return;

    // 构造带 throughput/ETA 的 NSProgress，供调用方（DownloadViewController）
    // 在 FCL 风格的下载进度卡片上显示速度和 ETA
    NSProgress *downloadProgress = [NSProgress progressWithTotalUnitCount:totalStored > 0 ? totalStored : -1];
    downloadProgress.completedUnitCount = accumulated;
    if (lastSpeed > 0) {
        downloadProgress.throughput = @(lastSpeed);
        if (totalStored > accumulated) {
            downloadProgress.estimatedTimeRemaining = @((double)(totalStored - accumulated) / lastSpeed);
        }
    }
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
- (void)handlePLDownloadCompletion:(BOOL)success
                             error:(nullable NSError *)error
                            taskId:(NSString *)taskId
                         generation:(NSInteger)generation {
    [self.downloadStateLock lock];
    if ([self.downloadGenerations[taskId] integerValue] != generation) {
        [self.downloadStateLock unlock];
        return;
    }
    ModDownloadHandler completion = self.downloadCompletionHandlers[taskId];
    [self cleanupPLDownloadStateForTaskId:taskId];
    [self.downloadStateLock unlock];

    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    NSError *completionError = success ? nil : (error ?: [NSError errorWithDomain:@"ModServiceError" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Mod download failed."}]);
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
        NSError *capturedError = completionError;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(capturedError);
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
