#import "utils.h"
#import "ModpackExportService.h"
#import "PLProfiles.h"
#import "ModService.h"
#import "external/UnzipKit/UZKArchive.h"
#import <CommonCrypto/CommonCrypto.h>

@interface ModpackExportService ()
/// 解析 profile gameDir 为绝对路径（复用 ModService 的逻辑）
- (nullable NSString *)resolveAbsoluteGameDirForProfile:(NSString *)profileName;
/// 计算文件 sha1（分块读取，避免大文件内存压力）
- (nullable NSString *)sha1ForFileAtPath:(NSString *)path;
/// 计算文件 sha512（分块读取）
- (nullable NSString *)sha512ForFileAtPath:(NSString *)path;
/// 将目录递归写入 zip
- (void)addDirectoryToArchive:(UZKArchive *)archive
                      dirPath:(NSString *)dirPath
                  prefixInZip:(NSString *)prefixInZip
                     progress:(void (^_Nullable)(NSUInteger done, NSUInteger total))progress;
/// 内部使用：检查取消信号
- (BOOL)checkCancelledWithError:(NSError **)error;
@end

@implementation ModpackExportService

+ (instancetype)sharedService {
    static ModpackExportService *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _cancelled = NO;
    }
    return self;
}

- (void)resetCancelState {
    @synchronized(self) {
        _cancelled = NO;
    }
}

- (BOOL)checkCancelledWithError:(NSError **)error {
    @synchronized(self) {
        if (_cancelled) {
            if (error) {
                *error = [NSError errorWithDomain:@"ModpackExportService"
                                             code:9999
                                         userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_469", nil)}];
            }
            return YES;
        }
    }
    return NO;
}

+ (NSArray<NSString *> *)overrideDirectoriesForOptions:(ModpackExportFileOptions)options {
    NSMutableArray *dirs = [NSMutableArray array];
    if (options & ModpackExportFileMods) {
        [dirs addObject:@"mods"];
    }
    if (options & ModpackExportFileConfigs) {
        [dirs addObject:@"config"];
        [dirs addObject:@"defaultconfigs"];
    }
    if (options & ModpackExportFileResourcePacks) {
        [dirs addObject:@"resourcepacks"];
    }
    if (options & ModpackExportFileShaderPacks) {
        [dirs addObject:@"shaderpacks"];
    }
    if (options & ModpackExportFileSaves) {
        [dirs addObject:@"saves"];
    }
    if (options & ModpackExportFileScripts) {
        [dirs addObject:@"kubejs"];
        [dirs addObject:@"scripts"];
        [dirs addObject:@"localization"];
        [dirs addObject:@"patchouli_books"];
    }
    return [dirs copy];
}

+ (NSArray<NSString *> *)overrideFilesForOptions:(ModpackExportFileOptions)options {
    NSMutableArray *files = [NSMutableArray array];
    if (options & ModpackExportFileGameSettings) {
        [files addObject:@"options.txt"];
        [files addObject:@"optionsof.txt"];
        [files addObject:@"optionsshaders.txt"];
        [files addObject:@"hotbar.nbt"];
    }
    if (options & ModpackExportFileServers) {
        [files addObject:@"servers.dat"];
        [files addObject:@"servers.dat_old"];
        [files addObject:@"realms_persistence.json"];
    }
    if (options & ModpackExportFileGameSettings) {
        [files addObject:@"launcher_profiles.json"];
    }
    return [files copy];
}

#pragma mark - 公开导出 API

- (BOOL)exportModpackForProfile:(NSString *)profileName
                         toPath:(NSString *)destPath
                            name:(NSString *)name
                         version:(NSString *)version
                          author:(NSString *)author
                         format:(ModpackExportFormat)format
                includeOverrides:(BOOL)includeOverrides
                       progress:(void (^_Nullable)(double progress, NSString *stageMessage))progress
                          error:(NSError **)error {
    ModpackExportFileOptions options = includeOverrides ? ModpackExportFileDefault : ModpackExportFileMods;
    return [self exportModpackForProfile:profileName
                                  toPath:destPath
                                     name:name
                                  version:version
                                   author:author
                                  format:format
                              fileOptions:options
                                 progress:progress
                                    error:error];
}

- (BOOL)exportModpackForProfile:(NSString *)profileName
                         toPath:(NSString *)destPath
                            name:(NSString *)name
                         version:(NSString *)version
                          author:(NSString *)author
                         format:(ModpackExportFormat)format
                     fileOptions:(ModpackExportFileOptions)fileOptions
                       progress:(void (^_Nullable)(double progress, NSString *stageMessage))progress
                          error:(NSError **)error {
    if (error) *error = nil;
    NSString *resolvedAuthor = author.length > 0 ? author : @"Amethyst User";

    void (^reportProgress)(double, NSString *) = ^(double p, NSString *msg) {
        NSLog(@"[ModpackExport] Progress: %.2f - %@", p, msg);
        if (progress) progress(p, msg);
    };

    reportProgress(0.0, localize(@"i18n_str_1274", nil));

    // 取消检查点
    if ([self checkCancelledWithError:error]) return NO;

    // 1. 获取 profile 信息
    NSDictionary *profile = PLProfiles.current.profiles[profileName];
    if (![profile isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackExportService" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_471", nil)}];
        }
        return NO;
    }

    NSString *lastVersionId = profile[@"lastVersionId"] ?: @"";
    NSString *gameDirAbsolute = [self resolveAbsoluteGameDirForProfile:profileName];
    if (gameDirAbsolute.length == 0) {
        const char *env = getenv("POJAV_GAME_DIR");
        gameDirAbsolute = env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
    }

    // 2. 解析 loader 和 mc 版本
    NSDictionary *versionInfo = [ModpackExportService parseVersionId:lastVersionId];
    NSString *mcVersion = versionInfo[@"minecraft"] ?: @"";
    NSString *loader = versionInfo[@"loader"] ?: @"";
    NSString *loaderVersion = versionInfo[@"loaderVersion"] ?: @"";

    NSLog(@"[ModpackExport] Profile=%@, mcVersion=%@, loader=%@ %@, gameDir=%@",
          profileName, mcVersion, loader, loaderVersion, gameDirAbsolute);

    if (mcVersion.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackExportService" code:2
                                     userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_472", nil)}];
        }
        return NO;
    }

    // 取消检查点
    if ([self checkCancelledWithError:error]) return NO;

    // 3. 收集 mods 文件列表
    reportProgress(0.1, localize(@"i18n_str_1275", nil));
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *modsDir = [gameDirAbsolute stringByAppendingPathComponent:@"mods"];
    NSMutableArray<NSDictionary *> *modFiles = [NSMutableArray new];
    if ([fm fileExistsAtPath:modsDir]) {
        // 嵌套目录扫描（部分整合包 mod 分子目录存放）
        NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:modsDir];
        NSString *relativePath;
        while ((relativePath = [enumerator nextObject])) {
            NSString *fullPath = [modsDir stringByAppendingPathComponent:relativePath];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:fullPath isDirectory:&isDir] || isDir) continue;
            // 只包含 .jar 文件（不包含 .disabled）
            if (![relativePath hasSuffix:@".jar"]) continue;
            NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
            unsigned long long fileSize = [attrs fileSize];
            NSString *sha1 = [self sha1ForFileAtPath:fullPath];
            [modFiles addObject:@{
                @"path": [NSString stringWithFormat:@"mods/%@", relativePath],
                @"fullPath": fullPath,
                @"fileName": relativePath.lastPathComponent,
                @"sha1": sha1 ?: @"",
                @"fileSize": @(fileSize)
            }];
        }
    }
    NSLog(@"[ModpackExport] Found %lu mod files", (unsigned long)modFiles.count);

    // 取消检查点
    if ([self checkCancelledWithError:error]) return NO;

    // 4. 根据格式导出
    switch (format) {
        case ModpackExportFormatModrinth:
            return [self exportModrinthFormat:modFiles
                                      toPath:destPath
                                         name:name
                                      version:version
                                       author:resolvedAuthor
                                    mcVersion:mcVersion
                                       loader:loader
                                loaderVersion:loaderVersion
                                gameDirAbsolute:gameDirAbsolute
                                  fileOptions:fileOptions
                                      progress:reportProgress
                                         error:error];
        case ModpackExportFormatCurseForge:
            return [self exportCurseForgeFormat:modFiles
                                         toPath:destPath
                                            name:name
                                         version:version
                                          author:resolvedAuthor
                                       mcVersion:mcVersion
                                          loader:loader
                                    loaderVersion:loaderVersion
                                gameDirAbsolute:gameDirAbsolute
                                  fileOptions:fileOptions
                                        progress:reportProgress
                                           error:error];
        case ModpackExportFormatMMC:
            return [self exportMMCFormat:modFiles
                                  toPath:destPath
                                     name:name
                                  version:version
                                   author:resolvedAuthor
                                mcVersion:mcVersion
                                   loader:loader
                            loaderVersion:loaderVersion
                            gameDirAbsolute:gameDirAbsolute
                              fileOptions:fileOptions
                                profileName:profileName
                                  progress:reportProgress
                                     error:error];
        case ModpackExportFormatPlainZip:
            return [self exportPlainZipFormat:modFiles
                                       toPath:destPath
                                          name:name
                                       version:version
                                        author:resolvedAuthor
                                     mcVersion:mcVersion
                                        loader:loader
                                  loaderVersion:loaderVersion
                                  gameDirAbsolute:gameDirAbsolute
                                    fileOptions:fileOptions
                                      progress:reportProgress
                                         error:error];
        case ModpackExportFormatLinkList:
            return [self exportLinkListFormat:modFiles
                                       toPath:destPath
                                      mcVersion:mcVersion
                                         loader:loader
                                   loaderVersion:loaderVersion
                                         name:name
                                       version:version
                                         error:error];
    }
    return NO;
}

#pragma mark - Modrinth 格式导出

- (BOOL)exportModrinthFormat:(NSArray<NSDictionary *> *)modFiles
                      toPath:(NSString *)destPath
                        name:(NSString *)name
                     version:(NSString *)version
                      author:(NSString *)author
                   mcVersion:(NSString *)mcVersion
                      loader:(NSString *)loader
              loaderVersion:(NSString *)loaderVersion
            gameDirAbsolute:(NSString *)gameDirAbsolute
                fileOptions:(ModpackExportFileOptions)fileOptions
                    progress:(void (^)(double, NSString *))progress
                       error:(NSError **)error {
    (void)author;
    if ([self checkCancelledWithError:error]) return NO;

    progress(0.2, localize(@"i18n_str_1276", nil));
    NSFileManager *fm = [NSFileManager defaultManager];

    // 构造 dependencies
    NSMutableDictionary *dependencies = @{@"minecraft": mcVersion}.mutableCopy;
    if ([loader isEqualToString:@"fabric"] && loaderVersion.length > 0) {
        dependencies[@"fabric-loader"] = loaderVersion;
    } else if ([loader isEqualToString:@"quilt"] && loaderVersion.length > 0) {
        dependencies[@"quilt-loader"] = loaderVersion;
    } else if ([loader isEqualToString:@"forge"] && loaderVersion.length > 0) {
        dependencies[@"forge"] = loaderVersion;
    } else if ([loader isEqualToString:@"neoforge"] && loaderVersion.length > 0) {
        dependencies[@"neoforge"] = loaderVersion;
    }

    // 构造 files 列表
    NSMutableArray *files = [NSMutableArray new];
    for (NSDictionary *modFile in modFiles) {
        if ([self checkCancelledWithError:error]) return NO;
        NSString *sha512 = [self sha512ForFileAtPath:modFile[@"fullPath"]];
        [files addObject:@{
            @"path": modFile[@"path"],
            @"hashes": @{
                @"sha1": modFile[@"sha1"],
                @"sha512": sha512 ?: @""
            },
            @"downloads": @[],  // 不填下载链接，导入时走 overrides 还原（与 HMCL 导出策略一致）
            @"fileSize": modFile[@"fileSize"]
        }];
    }

    // 构造 modrinth.index.json
    NSDictionary *indexJson = @{
        @"formatVersion": @(1),
        @"game": @"minecraft",
        @"versionId": version.length > 0 ? version : @"1.0",
        @"name": name.length > 0 ? name : @"Exported Modpack",
        @"files": files,
        @"dependencies": dependencies
    };

    NSData *indexData = [NSJSONSerialization dataWithJSONObject:indexJson options:NSJSONWritingPrettyPrinted error:error];
    if (!indexData) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:@"ModpackExportService" code:3
                                     userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_475", nil)}];
        }
        return NO;
    }

    if ([self checkCancelledWithError:error]) return NO;

    progress(0.3, localize(@"i18n_str_1258", nil));
    [fm removeItemAtPath:destPath error:nil];

    NSError *archiveError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:destPath error:&archiveError];
    if (!archive || archiveError) {
        if (error) *error = archiveError;
        return NO;
    }

    // 写入 modrinth.index.json
    progress(0.4, localize(@"i18n_str_1277", nil));
    if (![archive writeData:indexData filePath:@"modrinth.index.json" error:&archiveError]) {
        if (error) *error = archiveError;
        return NO;
    }

    // 写入 overrides
    if (![self writeOverridesToArchive:archive
                          gameDirAbsolute:gameDirAbsolute
                            fileOptions:fileOptions
                              zipPrefix:@"overrides"
                          baseProgress:0.5
                          progressRange:0.4
                                progress:progress
                                  error:error]) {
        return NO;
    }

    progress(0.95, localize(@"i18n_str_1259", nil));
    archive = nil;

    progress(1.0, localize(@"i18n_str_1260", nil));
    NSLog(@"[ModpackExport] Modrinth format export completed: %@", destPath);
    return YES;
}

#pragma mark - CurseForge 格式导出

- (BOOL)exportCurseForgeFormat:(NSArray<NSDictionary *> *)modFiles
                        toPath:(NSString *)destPath
                           name:(NSString *)name
                        version:(NSString *)version
                         author:(NSString *)author
                      mcVersion:(NSString *)mcVersion
                         loader:(NSString *)loader
                 loaderVersion:(NSString *)loaderVersion
               gameDirAbsolute:(NSString *)gameDirAbsolute
                   fileOptions:(ModpackExportFileOptions)fileOptions
                       progress:(void (^)(double, NSString *))progress
                          error:(NSError **)error {
    if ([self checkCancelledWithError:error]) return NO;

    progress(0.2, localize(@"i18n_str_1278", nil));
    NSFileManager *fm = [NSFileManager defaultManager];

    // 构造 modLoaders
    NSMutableArray *modLoaders = [NSMutableArray new];
    if (loader.length > 0 && loaderVersion.length > 0) {
        NSString *loaderId = [NSString stringWithFormat:@"%@-%@", loader, loaderVersion];
        [modLoaders addObject:@{@"id": loaderId, @"primary": @YES}];
    }

    // 构造 manifest.json
    // 注意：CurseForge 格式需要 projectID/fileID，本地 mod 无法获取。
    // 简化方案：files 为空，所有 mod 打进 overrides/mods/（与 HMCL 导出策略一致）
    NSDictionary *manifest = @{
        @"minecraft": @{
            @"version": mcVersion,
            @"modLoaders": modLoaders
        },
        @"manifestType": @"minecraftModpack",
        @"manifestVersion": @(1),
        @"name": name.length > 0 ? name : @"Exported Modpack",
        @"version": version.length > 0 ? version : @"1.0",
        @"author": author.length > 0 ? author : @"Amethyst User",
        @"files": @[],
        @"overrides": @"overrides"
    };

    NSData *manifestData = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:error];
    if (!manifestData) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:@"ModpackExportService" code:4
                                     userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_481", nil)}];
        }
        return NO;
    }

    if ([self checkCancelledWithError:error]) return NO;

    progress(0.3, localize(@"i18n_str_1258", nil));
    [fm removeItemAtPath:destPath error:nil];

    NSError *archiveError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:destPath error:&archiveError];
    if (!archive || archiveError) {
        if (error) *error = archiveError;
        return NO;
    }

    progress(0.4, localize(@"i18n_str_1279", nil));
    if (![archive writeData:manifestData filePath:@"manifest.json" error:&archiveError]) {
        if (error) *error = archiveError;
        return NO;
    }

    if (![self writeOverridesToArchive:archive
                          gameDirAbsolute:gameDirAbsolute
                            fileOptions:fileOptions
                              zipPrefix:@"overrides"
                          baseProgress:0.5
                          progressRange:0.4
                                progress:progress
                                  error:error]) {
        return NO;
    }

    progress(0.95, localize(@"i18n_str_1259", nil));
    archive = nil;

    progress(1.0, localize(@"i18n_str_1260", nil));
    NSLog(@"[ModpackExport] CurseForge format export completed: %@", destPath);
    return YES;
}

#pragma mark - MMC (MultiMC/Prism) 格式导出

/// MMC 格式：
///   mmc-pack.json: 包含 components 数组（net.minecraft + 加载器 component）
///   instance.cfg: key=value 格式，含 name/JvmArgs/InstanceType 等
///   .minecraft/: 包含 mods/config/options.txt 等（不放在 overrides/ 下，直接是 .minecraft/）
- (BOOL)exportMMCFormat:(NSArray<NSDictionary *> *)modFiles
                 toPath:(NSString *)destPath
                    name:(NSString *)name
                 version:(NSString *)version
                  author:(NSString *)author
               mcVersion:(NSString *)mcVersion
                  loader:(NSString *)loader
          loaderVersion:(NSString *)loaderVersion
          gameDirAbsolute:(NSString *)gameDirAbsolute
            fileOptions:(ModpackExportFileOptions)fileOptions
            profileName:(NSString *)profileName
                progress:(void (^)(double, NSString *))progress
                   error:(NSError **)error {
    if ([self checkCancelledWithError:error]) return NO;

    progress(0.2, localize(@"i18n_str_1280", nil));
    NSFileManager *fm = [NSFileManager defaultManager];

    // 构造 components 数组
    NSMutableArray *components = [NSMutableArray array];
    [components addObject:@{
        @"cachedName": @"Minecraft",
        @"cachedVersion": mcVersion,
        @"important": @YES,
        @"uid": @"net.minecraft",
        @"version": mcVersion
    }];
    if ([loader isEqualToString:@"fabric"] && loaderVersion.length > 0) {
        [components addObject:@{
            @"cachedName": @"Fabric Loader",
            @"uid": @"net.fabricmc.fabric-loader",
            @"version": loaderVersion
        }];
    } else if ([loader isEqualToString:@"quilt"] && loaderVersion.length > 0) {
        [components addObject:@{
            @"cachedName": @"Quilt Loader",
            @"uid": @"org.quiltmc.quilt-loader",
            @"version": loaderVersion
        }];
    } else if ([loader isEqualToString:@"forge"] && loaderVersion.length > 0) {
        [components addObject:@{
            @"cachedName": @"Forge",
            @"uid": @"net.minecraftforge",
            @"version": loaderVersion
        }];
    } else if ([loader isEqualToString:@"neoforge"] && loaderVersion.length > 0) {
        [components addObject:@{
            @"cachedName": @"NeoForge",
            @"uid": @"net.neoforged",
            @"version": loaderVersion
        }];
    }

    NSDictionary *mmcPack = @{
        @"components": components,
        @"formatVersion": @(1)
    };

    NSData *mmcPackData = [NSJSONSerialization dataWithJSONObject:mmcPack options:NSJSONWritingPrettyPrinted error:error];
    if (!mmcPackData) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:@"ModpackExportService" code:5
                                     userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_484", nil)}];
        }
        return NO;
    }

    // 构造 instance.cfg（key=value 格式）
    NSString *instanceName = name.length > 0 ? name : (profileName ?: @"Exported Modpack");
    NSMutableString *cfgContent = [NSMutableString string];
    [cfgContent appendFormat:@"InstanceType=OneSix\n"];
    [cfgContent appendFormat:@"name=%@\n", instanceName];
    [cfgContent appendFormat:@"%s=%@\n", "notes", [NSString stringWithFormat:@"Exported by Amethyst v%@", version.length > 0 ? version : @"1.0"]];
    [cfgContent appendFormat:@"%s=%@\n", "iconKey", "default"];
    [cfgContent appendFormat:@"%s=%@\n", "OverrideCommands", "false"];
    [cfgContent appendFormat:@"%s=%@\n", "OverrideConsole", "false"];
    [cfgContent appendFormat:@"%s=%@\n", "OverrideJava", "false"];
    [cfgContent appendFormat:@"%s=%@\n", "OverrideJavaArgs", "false"];
    [cfgContent appendFormat:@"%s=%@\n", "OverrideMCLauncher", "false"];
    [cfgContent appendFormat:@"%s=%@\n", "OverrideWindow", "false"];
    NSData *cfgData = [cfgContent dataUsingEncoding:NSUTF8StringEncoding];

    if ([self checkCancelledWithError:error]) return NO;

    progress(0.3, localize(@"i18n_str_1258", nil));
    [fm removeItemAtPath:destPath error:nil];

    NSError *archiveError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:destPath error:&archiveError];
    if (!archive || archiveError) {
        if (error) *error = archiveError;
        return NO;
    }

    progress(0.4, localize(@"i18n_str_1281", nil));
    if (![archive writeData:mmcPackData filePath:@"mmc-pack.json" error:&archiveError]) {
        if (error) *error = archiveError;
        return NO;
    }
    progress(0.45, localize(@"i18n_str_1282", nil));
    if (cfgData && ![archive writeData:cfgData filePath:@"instance.cfg" error:&archiveError]) {
        if (error) *error = archiveError;
        return NO;
    }

    // MMC 的 overrides 写入到 .minecraft/ 前缀（MMC 标准结构）
    if (![self writeOverridesToArchive:archive
                          gameDirAbsolute:gameDirAbsolute
                            fileOptions:fileOptions
                              zipPrefix:@".minecraft"
                          baseProgress:0.5
                          progressRange:0.4
                                progress:progress
                                  error:error]) {
        return NO;
    }

    progress(0.95, localize(@"i18n_str_1259", nil));
    archive = nil;

    progress(1.0, localize(@"i18n_str_1260", nil));
    NSLog(@"[ModpackExport] MMC format export completed: %@", destPath);
    return YES;
}

#pragma mark - Plain Zip 格式导出（HMCL 兼容）

/// Plain Zip 格式：直接打包 .minecraft 目录，无 manifest/mmc-pack.json
/// 适合于 PojavLauncher/HMCL 互通：直接将 gameDir 内容打包到 .minecraft/ 前缀下
- (BOOL)exportPlainZipFormat:(NSArray<NSDictionary *> *)modFiles
                      toPath:(NSString *)destPath
                         name:(NSString *)name
                      version:(NSString *)version
                       author:(NSString *)author
                     mcVersion:(NSString *)mcVersion
                        loader:(NSString *)loader
                  loaderVersion:(NSString *)loaderVersion
                  gameDirAbsolute:(NSString *)gameDirAbsolute
                    fileOptions:(ModpackExportFileOptions)fileOptions
                      progress:(void (^)(double, NSString *))progress
                         error:(NSError **)error {
    (void)name; (void)version; (void)author; (void)loader; (void)loaderVersion;
    if ([self checkCancelledWithError:error]) return NO;

    progress(0.2, localize(@"i18n_str_1258", nil));
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:destPath error:nil];

    NSError *archiveError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:destPath error:&archiveError];
    if (!archive || archiveError) {
        if (error) *error = archiveError;
        return NO;
    }

    // 写入 .minecraft/AMETHYST_INFO.txt 元信息（可选，帮助其他启动器识别来源）
    NSString *infoContent = [NSString stringWithFormat:
        @"Amethyst Exported Modpack\n"
        @"Minecraft: %@\n"
        @"Loader: %@ %@\n"
        @"Export Time: %@\n",
        mcVersion,
        loader ?: @"vanilla",
        loaderVersion ?: @"",
        [[NSDate date] description]];
    NSData *infoData = [infoContent dataUsingEncoding:NSUTF8StringEncoding];
    if (infoData) {
        [archive writeData:infoData filePath:@".minecraft/AMETHYST_INFO.txt" error:nil];
    }

    // 写入 .minecraft/<...> 前缀
    if (![self writeOverridesToArchive:archive
                          gameDirAbsolute:gameDirAbsolute
                            fileOptions:fileOptions
                              zipPrefix:@".minecraft"
                          baseProgress:0.3
                          progressRange:0.6
                                progress:progress
                                  error:error]) {
        return NO;
    }

    progress(0.95, localize(@"i18n_str_1259", nil));
    archive = nil;

    progress(1.0, localize(@"i18n_str_1260", nil));
    NSLog(@"[ModpackExport] Plain Zip format export completed: %@", destPath);
    return YES;
}

#pragma mark - 链接列表格式导出（FCL 支持的简单格式）

- (BOOL)exportLinkListFormat:(NSArray<NSDictionary *> *)modFiles
                      toPath:(NSString *)destPath
                   mcVersion:(NSString *)mcVersion
                      loader:(NSString *)loader
              loaderVersion:(NSString *)loaderVersion
                        name:(NSString *)name
                     version:(NSString *)version
                       error:(NSError **)error {
    // FCL 链接列表格式：
    // # Minecraft: <mcVersion>
    // # Loader: <loader>-<loaderVersion>
    // # Name: <name>
    // # Version: <version>
    // <zip内路径>|<下载链接或本地路径>
    NSMutableString *content = [NSMutableString string];
    [content appendFormat:@"# Minecraft: %@\n", mcVersion];
    if (loader.length > 0 && loaderVersion.length > 0) {
        [content appendFormat:@"# Loader: %@-%@\n", loader, loaderVersion];
    }
    [content appendFormat:@"# Name: %@\n", name.length > 0 ? name : @"Exported Modpack"];
    [content appendFormat:@"# Version: %@\n", version.length > 0 ? version : @"1.0"];
    [content appendString:localize(@"i18n_str_487", nil)];

    for (NSDictionary *modFile in modFiles) {
        // 链接列表格式：mod 路径 + 空下载链接（用户可手动填写）
        [content appendFormat:@"%@|\n", modFile[@"path"]];
    }

    NSError *writeError = nil;
    BOOL success = [content writeToFile:destPath atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
    if (!success) {
        if (error) *error = writeError;
        return NO;
    }
    NSLog(@"[ModpackExport] Link list format export completed: %@", destPath);
    return YES;
}

#pragma mark - 通用 Overrides 写入

/// 通用 overrides 写入：根据 fileOptions 决定哪些目录/文件被打包
- (BOOL)writeOverridesToArchive:(UZKArchive *)archive
               gameDirAbsolute:(NSString *)gameDirAbsolute
                     fileOptions:(ModpackExportFileOptions)fileOptions
                       zipPrefix:(NSString *)zipPrefix
                     baseProgress:(double)baseProgress
                   progressRange:(double)progressRange
                         progress:(void (^)(double, NSString *))progress
                            error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *overrideDirs = [ModpackExportService overrideDirectoriesForOptions:fileOptions];
    NSArray<NSString *> *overrideFiles = [ModpackExportService overrideFilesForOptions:fileOptions];

    NSUInteger totalItems = overrideDirs.count + overrideFiles.count;
    if (totalItems == 0) {
        progress(baseProgress + progressRange, localize(@"i18n_str_1264", nil));
        return YES;
    }

    __block NSUInteger processed = 0;
    __block NSError *blockError = nil;

    // 计算每个目录的文件总数，用于精确进度
    NSUInteger totalFiles = 0;
    for (NSString *dir in overrideDirs) {
        NSString *dirPath = [gameDirAbsolute stringByAppendingPathComponent:dir];
        if (![fm fileExistsAtPath:dirPath]) continue;
        NSDirectoryEnumerator *e = [fm enumeratorAtPath:dirPath];
        NSString *rel;
        while ((rel = [e nextObject])) {
            NSString *full = [dirPath stringByAppendingPathComponent:rel];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:full isDirectory:&isDir] && !isDir) {
                totalFiles++;
            }
        }
    }
    totalFiles += overrideFiles.count;
    if (totalFiles == 0) {
        progress(baseProgress + progressRange, localize(@"i18n_str_1264", nil));
        return YES;
    }

    __block NSUInteger processedFiles = 0;

    // 打包目录
    for (NSString *dir in overrideDirs) {
        if ([self checkCancelledWithError:error]) return NO;
        NSString *dirPath = [gameDirAbsolute stringByAppendingPathComponent:dir];
        if (![fm fileExistsAtPath:dirPath]) {
            processed++;
            continue;
        }
        NSString *prefixInZip = [NSString stringWithFormat:@"%@/%@", zipPrefix, dir];
        [self addDirectoryToArchive:archive
                            dirPath:dirPath
                        prefixInZip:prefixInZip
                           progress:^(NSUInteger done, NSUInteger total) {
            processedFiles = done;
            double p = baseProgress + progressRange * ((double)processedFiles / (double)totalFiles);
            progress(p, [NSString stringWithFormat:localize(@"i18n_str_489", nil), zipPrefix, dir]);
        }];
        processed++;
    }

    // 打包单个文件
    for (NSString *file in overrideFiles) {
        if ([self checkCancelledWithError:error]) return NO;
        NSString *filePath = [gameDirAbsolute stringByAppendingPathComponent:file];
        if ([fm fileExistsAtPath:filePath]) {
            NSData *data = [NSData dataWithContentsOfFile:filePath];
            if (data) {
                NSError *writeErr = nil;
                [archive writeData:data
                          filePath:[NSString stringWithFormat:@"%@/%@", zipPrefix, file]
                             error:&writeErr];
                if (writeErr) {
                    NSLog(@"[ModpackExport] Warning: failed to write %@/%@: %@", zipPrefix, file, writeErr.localizedDescription);
                }
            }
        }
        processedFiles++;
        double p = baseProgress + progressRange * ((double)processedFiles / (double)totalFiles);
        progress(p, [NSString stringWithFormat:localize(@"i18n_str_489", nil), zipPrefix, file]);
        processed++;
    }

    if (blockError) {
        if (error) *error = blockError;
        return NO;
    }
    return YES;
}

#pragma mark - 辅助方法

- (void)addDirectoryToArchive:(UZKArchive *)archive
                      dirPath:(NSString *)dirPath
                  prefixInZip:(NSString *)prefixInZip
                     progress:(void (^_Nullable)(NSUInteger done, NSUInteger total))progress {
    NSFileManager *fileManager = [NSFileManager defaultManager];

    // 先统计文件总数
    NSUInteger total = 0;
    NSDirectoryEnumerator *counter = [fileManager enumeratorAtPath:dirPath];
    NSString *relPath;
    while ((relPath = [counter nextObject])) {
        NSString *fullPath = [dirPath stringByAppendingPathComponent:relPath];
        BOOL isDir = NO;
        if ([fileManager fileExistsAtPath:fullPath isDirectory:&isDir] && !isDir) {
            total++;
        }
    }
    if (total == 0) {
        if (progress) progress(0, 0);
        return;
    }

    NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtPath:dirPath];
    NSUInteger done = 0;
    while ((relPath = [enumerator nextObject])) {
        // 取消检查点
        @synchronized(self) {
            if (self.cancelled) {
                if (progress) progress(done, total);
                return;
            }
        }

        NSString *fullPath = [dirPath stringByAppendingPathComponent:relPath];
        BOOL isDir = NO;
        if (![fileManager fileExistsAtPath:fullPath isDirectory:&isDir] || isDir) continue;

        NSData *data = [NSData dataWithContentsOfFile:fullPath];
        if (!data) continue;

        NSString *zipPath = [NSString stringWithFormat:@"%@/%@", prefixInZip, relPath];
        [archive writeData:data filePath:zipPath error:nil];
        done++;
        if (progress) progress(done, total);
    }
}

- (nullable NSString *)resolveAbsoluteGameDirForProfile:(NSString *)profileName {
    NSString *profile = profileName.length ? profileName : @"default";
    @try {
        NSDictionary *profiles = PLProfiles.current.profiles;
        NSDictionary *prof = profiles[profile];
        if (![prof isKindOfClass:[NSDictionary class]]) return nil;
        NSString *gameDir = [PLProfiles effectiveGameDirForProfile:prof];
        if (![gameDir isKindOfClass:[NSString class]] || gameDir.length == 0) return nil;
        if ([gameDir isEqualToString:@"."]) {
            const char *env = getenv("POJAV_GAME_DIR");
            return env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
        }
        if ([gameDir isAbsolutePath]) {
            return gameDir;
        }
        const char *env = getenv("POJAV_GAME_DIR");
        NSString *baseDir = env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
        NSString *cleanGameDir = [gameDir hasPrefix:@"./"] ? [gameDir substringFromIndex:2] : gameDir;
        return [baseDir stringByAppendingPathComponent:cleanGameDir];
    } @catch (NSException *ex) {
        return nil;
    }
}

- (nullable NSString *)sha1ForFileAtPath:(NSString *)path {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return nil;

    CC_SHA1_CTX ctx;
    CC_SHA1_Init(&ctx);

    static const NSUInteger bufferSize = 64 * 1024;  // 64KB
    NSData *chunk;
    while ((chunk = [handle readDataOfLength:bufferSize]) && chunk.length > 0) {
        CC_SHA1_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
    }
    [handle closeFile];

    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1_Final(digest, &ctx);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (size_t i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex copy];
}

- (nullable NSString *)sha512ForFileAtPath:(NSString *)path {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return nil;

    CC_SHA512_CTX ctx;
    CC_SHA512_Init(&ctx);

    static const NSUInteger bufferSize = 64 * 1024;  // 64KB
    NSData *chunk;
    while ((chunk = [handle readDataOfLength:bufferSize]) && chunk.length > 0) {
        CC_SHA512_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
    }
    [handle closeFile];

    unsigned char digest[CC_SHA512_DIGEST_LENGTH];
    CC_SHA512_Final(digest, &ctx);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA512_DIGEST_LENGTH * 2];
    for (size_t i = 0; i < CC_SHA512_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex copy];
}

+ (NSDictionary *)parseVersionId:(NSString *)versionId {
    if (versionId.length == 0) return @{};

    // fabric-loader-<loaderVer>-<mcVer>
    if ([versionId hasPrefix:@"fabric-loader-"]) {
        NSString *rest = [versionId substringFromIndex:@"fabric-loader-".length];
        NSArray *parts = [rest componentsSeparatedByString:@"-"];
        if (parts.count >= 2) {
            NSString *loaderVersion = parts[0];
            NSString *mcVersion = [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@"-"];
            return @{@"loader": @"fabric", @"loaderVersion": loaderVersion, @"minecraft": mcVersion};
        }
    }

    // quilt-loader-<loaderVer>-<mcVer>
    if ([versionId hasPrefix:@"quilt-loader-"]) {
        NSString *rest = [versionId substringFromIndex:@"quilt-loader-".length];
        NSArray *parts = [rest componentsSeparatedByString:@"-"];
        if (parts.count >= 2) {
            NSString *loaderVersion = parts[0];
            NSString *mcVersion = [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@"-"];
            return @{@"loader": @"quilt", @"loaderVersion": loaderVersion, @"minecraft": mcVersion};
        }
    }

    // <mcVer>-forge-<loaderVer>
    NSRange forgeRange = [versionId rangeOfString:@"-forge-"];
    if (forgeRange.location != NSNotFound) {
        NSString *mcVersion = [versionId substringToIndex:forgeRange.location];
        NSString *loaderVersion = [versionId substringFromIndex:forgeRange.location + forgeRange.length];
        return @{@"loader": @"forge", @"loaderVersion": loaderVersion, @"minecraft": mcVersion};
    }

    // <mcVer>-neoforge-<loaderVer>
    NSRange neoforgeRange = [versionId rangeOfString:@"-neoforge-"];
    if (neoforgeRange.location != NSNotFound) {
        NSString *mcVersion = [versionId substringToIndex:neoforgeRange.location];
        NSString *loaderVersion = [versionId substringFromIndex:neoforgeRange.location + neoforgeRange.length];
        return @{@"loader": @"neoforge", @"loaderVersion": loaderVersion, @"minecraft": mcVersion};
    }

    // 纯 mc 版本（无 loader）
    return @{@"minecraft": versionId};
}

@end
