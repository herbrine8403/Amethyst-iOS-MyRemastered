//
//  NeoForgeDirectInstaller.m
//  Amethyst
//
//  Direct NeoForge installer (new format only, NeoForge 1.20.1+),
//  参照 ZalithLauncher2 / HMCL 的 ForgeNewInstallTask。
//
//  通过 ForgeProcessorExecutor 在本地 headless JVM 中执行 install_profile.json 的
//  processors（binarypatcher、jarsplitter、AutoRenamingTool 等），生成 FML 运行
//  必需的 PATCHED / MC_SRG / MC_EXTRA artifact。
//
//  iOS 沙箱禁止 fork/exec，无法为每个 processor spawn 子 JVM，因此命令被序列化为
//  commands.json，由进程内 headless JVM 中的 ForgeProcessorRunner 逐条执行
//  （见 JavaLauncher.m 的 launchHeadlessJVM）。
//
//  历史方案（已废弃）："直接从 maven 下载预打补丁 client jar"。官方 maven 从未
//  发布 processor 输出产物（client classifier 实测 404），该方案根本不可行。
//
//  注意：执行过 processors 后进程内 JVM 已创建，再次创建 JVM 会崩溃，
//  游戏启动前必须重启 app（见 ForgeProcessorExecutor.jvmUsedThisProcess）。
//
//  JarJar（JarInJar）机制是运行期由 modlauncher 的 JarInJarDependencyLocator 处理，
//  安装期无需任何 processor 介入。
//

#import "NeoForgeDirectInstaller.h"
#import "PLProfiles.h"
#import "utils.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceUtils.h"
#import "ForgeProcessorExecutor.h"
#import "external/UnzipKit/UZKArchive.h"

NSString *const NeoForgeDirectInstallerErrorDomain = @"NeoForgeDirectInstallerErrorDomain";

@implementation NeoForgeDirectInstaller

#pragma mark - Public

+ (BOOL)installNeoForgeFromInstaller:(NSString *)installerPath
                           versionId:(NSString *)versionId
                               error:(NSError **)error {
    return [self installNeoForgeFromInstaller:installerPath versionId:versionId progress:nil error:error];
}

+ (BOOL)installNeoForgeFromInstaller:(NSString *)installerPath
                           versionId:(NSString *)versionId
                            progress:(void (^)(double progress, NSString *stageMessage))progress
                               error:(NSError **)error {
    return [self installNeoForgeFromInstaller:installerPath
                                    versionId:versionId
                                customGameDir:nil
                          skipRegisterVersion:NO
                                     progress:progress
                                       error:error];
}

+ (BOOL)installNeoForgeFromInstaller:(NSString *)installerPath
                           versionId:(NSString *)versionId
                       customGameDir:(nullable NSString *)customGameDir
                 skipRegisterVersion:(BOOL)skipRegisterVersion
                            progress:(void (^)(double progress, NSString *stageMessage))progress
                               error:(NSError **)error {
    void (^reportProgress)(double, NSString *) = ^(double p, NSString *msg) {
        NSLog(@"[NeoForgeDirect] Progress: %.2f - %@", p, msg);
        if (progress) {
            progress(p, msg);
        }
    };

    @try {
        NSLog(@"[NeoForgeDirect] Starting installation: %@", versionId);
        reportProgress(0.0, localize(@"i18n_str_1266", nil));
        if (error) {
            *error = nil;
        }

        // Step 1: Read install_profile.json
        NSLog(@"[NeoForgeDirect] Reading install_profile.json");
        reportProgress(0.05, localize(@"i18n_str_1267", nil));
        NSData *profileData = [self dataFromZip:installerPath entry:@"install_profile.json" error:error];
        if (!profileData) {
            NSLog(@"[NeoForgeDirect] Failed to read install_profile.json");
            if (error && !*error) {
                *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                             code:NeoForgeDirectInstallerErrorMissingProfile
                                         userInfo:@{NSLocalizedDescriptionKey: @"Missing install_profile.json in installer"}];
            }
            return NO;
        }
        NSLog(@"[NeoForgeDirect] Successfully read install_profile.json (%lu bytes)", (unsigned long)profileData.length);

        // Step 2: Parse install_profile.json
        NSLog(@"[NeoForgeDirect] Parsing install_profile.json");
        reportProgress(0.1, localize(@"i18n_str_1317", nil));
        NSError *jsonError = nil;
        NSMutableDictionary *installProfile = [NSJSONSerialization JSONObjectWithData:profileData
                                                                              options:NSJSONReadingMutableContainers
                                                                                error:&jsonError];
        NSLog(@"[NeoForgeDirect] JSON parsing completed, error=%@", jsonError ?: @"none");
        if (![installProfile isKindOfClass:[NSDictionary class]] || jsonError) {
            if (error) {
                *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                             code:NeoForgeDirectInstallerErrorInvalidProfile
                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to parse install_profile.json"}];
            }
            return NO;
        }

        // NeoForge only uses new format (spec field)
        BOOL isNewFormat = (installProfile[@"spec"] != nil);
        NSLog(@"[NeoForgeDirect] Format detection: new=%d", isNewFormat);
        if (!isNewFormat) {
            if (error) {
                *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                             code:NeoForgeDirectInstallerErrorInvalidProfile
                                         userInfo:@{NSLocalizedDescriptionKey: @"NeoForge installer uses unknown format (expected new format with spec)"}];
            }
            return NO;
        }

        // 整合包导入时使用自定义 gameDir；否则使用默认 POJAV_GAME_DIR
        // 注意：gameDir（user.dir，mods/saves/configs 隔离目录）用 customGameDir，
        // 但 versionDir 和 librariesDir 必须始终用 POJAV_GAME_DIR（主目录）。
        // 原因：Minecraft 启动器 Java 端固定从 POJAV_GAME_DIR/versions 和 /libraries 加载，
        // 之前把 versionDir/librariesDir 放到 customGameDir 下会导致启动时"找不到版本信息"。
        NSString *gameDir = customGameDir.length > 0 ? customGameDir : [self gameDirectory];
        NSString *mainGameDir = [self gameDirectory];  // 始终用主目录存放 versions 和 libraries
        NSString *librariesDir = [mainGameDir stringByAppendingPathComponent:@"libraries"];
        NSLog(@"[NeoForgeDirect] Game directory (user.dir): %@", gameDir);
        NSLog(@"[NeoForgeDirect] Main game directory (versions/libraries): %@", mainGameDir);
        NSLog(@"[NeoForgeDirect] Libraries directory: %@", librariesDir);
        reportProgress(0.15, localize(@"i18n_str_1268", nil));

        // 提前创建 libraries 目录，避免后续下载/解压失败
        [[NSFileManager defaultManager] createDirectoryAtPath:librariesDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];

        BOOL success = [self installNewFormat:installProfile
                               installerPath:installerPath
                                   versionId:versionId
                                     gameDir:gameDir
                               librariesDir:librariesDir
                                    progress:progress
                                      error:error];
        if (!success) {
            NSLog(@"[NeoForgeDirect] Installation failed");
            return NO;
        }

        // Step: Register version in launcher_profiles.json (must run on main thread)
        // 整合包导入时跳过（由 ModpackImportService.createProfileForModpack 统一注册）
        if (!skipRegisterVersion) {
            NSLog(@"[NeoForgeDirect] Registering version on main thread");
            reportProgress(0.95, localize(@"i18n_str_1269", nil));
            if ([NSThread isMainThread]) {
                [self registerVersion:versionId];
            } else {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [self registerVersion:versionId];
                });
            }
            NSLog(@"[NeoForgeDirect] Version registered successfully");
        }

        NSLog(@"[NeoForgeDirect] Installation completed successfully");
        reportProgress(1.0, localize(@"i18n_str_1270", nil));
        return YES;
    }
    @catch (NSException *exception) {
        NSString *stack = [exception.callStackSymbols componentsJoinedByString:@"\n"];
        NSLog(@"[NeoForgeDirect] EXCEPTION: name=%@, reason=%@, callStack=%@", exception.name, exception.reason, stack);
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                          code:NeoForgeDirectInstallerErrorException
                                      userInfo:@{
                                          NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_1117", nil), exception.reason ?: localize(@"i18n_str_1118", nil)],
                                          NSLocalizedFailureReasonErrorKey: exception.name ?: @"UnknownException"
                                      }];
        }
        return NO;
    }
}

+ (BOOL)isNewFormatInstaller:(NSString *)installerPath {
    NSData *profileData = [self dataFromZip:installerPath entry:@"install_profile.json" error:nil];
    if (!profileData) {
        return NO;
    }

    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:profileData options:0 error:nil];
    if (![dict isKindOfClass:[NSDictionary class]]) {
        return NO;
    }

    return dict[@"spec"] != nil;
}

#pragma mark - New format (NeoForge 1.20.1+)

+ (BOOL)installNewFormat:(NSDictionary *)installProfile
           installerPath:(NSString *)installerPath
               versionId:(NSString *)versionId
                 gameDir:(NSString *)gameDir
            librariesDir:(NSString *)librariesDir
                progress:(void (^)(double, NSString *))progress
                  error:(NSError **)error {
    NSLog(@"[NeoForgeDirect] installNewFormat started");
    void (^reportProgress)(double, NSString *) = ^(double p, NSString *msg) {
        NSLog(@"[NeoForgeDirect] Progress: %.2f - %@", p, msg);
        if (progress) {
            progress(p, msg);
        }
    };

    // Read version.json
    NSLog(@"[NeoForgeDirect] Reading version.json");
    NSString *versionJsonEntry = installProfile[@"json"];
    if (!versionJsonEntry || ![versionJsonEntry isKindOfClass:[NSString class]]) {
        versionJsonEntry = @"version.json";
    }
    // version.json 路径可能以 "/" 开头，统一去掉
    if ([versionJsonEntry hasPrefix:@"/"]) {
        versionJsonEntry = [versionJsonEntry substringFromIndex:1];
    }
    NSLog(@"[NeoForgeDirect] version.json entry: %@", versionJsonEntry);

    NSData *versionData = [self dataFromZip:installerPath entry:versionJsonEntry error:error];
    if (!versionData) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorMissingProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"Missing version.json in installer"}];
        }
        return NO;
    }
    NSLog(@"[NeoForgeDirect] Successfully read version.json (%lu bytes)", (unsigned long)versionData.length);

    NSLog(@"[NeoForgeDirect] Parsing version.json");
    NSMutableDictionary *versionJson = [NSJSONSerialization JSONObjectWithData:versionData
                                                                       options:NSJSONReadingMutableContainers
                                                                         error:nil];
    if (![versionJson isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to parse version.json"}];
        }
        return NO;
    }
    NSLog(@"[NeoForgeDirect] version.json parsed successfully");

    // 注意：不再把 install_profile.libraries 合并进 version.json。
    // profile 的 libraries 是安装期 processor 工具链依赖，仅供 ForgeProcessorExecutor
    // 使用，全部下载到 libraries/ 后由 processor 消费；合并进 version.json 会污染
    // 运行期 classpath（与游戏依赖版本冲突），参照 ZL2/HMCL 均不合并。
    versionJson[@"id"] = versionId;

    // Prepare version directory
    // 版本 JSON 必须写入 POJAV_GAME_DIR/versions/（主目录），而非 profile gameDir。
    // Minecraft 启动器 Java 端固定从 POJAV_GAME_DIR/versions 加载版本 JSON。
    NSString *versionDir = [[self gameDirectory] stringByAppendingPathComponent:[NSString stringWithFormat:@"versions/%@", versionId]];
    NSString *versionJsonPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", versionId]];
    NSLog(@"[NeoForgeDirect] Version directory: %@", versionDir);
    [[NSFileManager defaultManager] createDirectoryAtPath:versionDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    // Step A: 解压 installer.jar 内 maven/ 下的所有依赖到 libraries 目录
    NSLog(@"[NeoForgeDirect] Extracting all maven entries from installer jar");
    reportProgress(0.2, localize(@"i18n_str_1261", nil));
    NSUInteger extractedCount = [self extractAllMavenEntries:installerPath toLibrariesDir:librariesDir];
    NSLog(@"[NeoForgeDirect] Extracted %lu maven entries", (unsigned long)extractedCount);

    // Step B: 下载 versionJson.libraries 中未在 installer.jar 内的库
    NSLog(@"[NeoForgeDirect] Downloading missing libraries from maven");
    reportProgress(0.3, localize(@"i18n_str_1262", nil));
    NSArray *allLibraries = versionJson[@"libraries"];
    if ([allLibraries isKindOfClass:[NSArray class]]) {
        [self downloadMissingLibraries:allLibraries librariesDir:librariesDir progress:progress baseProgress:0.3 progressSpan:0.2];
    }

    // Step C: 下载 install_profile.libraries（processor 工具链依赖）
    // processor 的 jar 与 classpath 全部来自这份清单，必须先就位
    NSLog(@"[NeoForgeDirect] Downloading processor libraries");
    reportProgress(0.5, localize(@"i18n_str_1271", nil));
    NSArray *processorLibraries = installProfile[@"libraries"];
    if ([processorLibraries isKindOfClass:[NSArray class]] && processorLibraries.count > 0) {
        [self downloadMissingLibraries:processorLibraries librariesDir:librariesDir progress:progress baseProgress:0.5 progressSpan:0.05];
    }

    // Step D: 关键步骤——执行 install_profile processors 生成 PATCHED / MC_SRG 等 artifact
    // 参照 ZL2/HMCL ForgeNewInstallTask：processor 在本地 headless JVM 中执行。
    // 之前"直接从 maven 下载预打补丁 jar"的方案是错的——官方 maven 从未发布过
    // 这些 processor 输出产物（实测 client classifier 均 404）。
    NSString *minecraftVersion = [versionJson[@"inheritsFrom"] isKindOfClass:[NSString class]] ? versionJson[@"inheritsFrom"] : nil;
    if (minecraftVersion.length == 0) {
        NSLog(@"[NeoForgeDirect] version.json missing inheritsFrom, cannot run processors");
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1125", nil)}];
        }
        return NO;
    }
    NSLog(@"[NeoForgeDirect] Running processors for Minecraft %@", minecraftVersion);
    reportProgress(0.55, localize(@"i18n_str_1272", nil));
    if (![ForgeProcessorExecutor runProcessorsWithProfile:installProfile
                                             installerPath:installerPath
                                          minecraftVersion:minecraftVersion
                                                mainGameDir:[self gameDirectory]
                                               baseProgress:0.55
                                              progressSpan:0.3
                                                   progress:progress
                                                      error:error]) {
        NSLog(@"[NeoForgeDirect] Processor execution failed");
        return NO;
    }

    // Write version JSON
    NSLog(@"[NeoForgeDirect] Writing version JSON to: %@", versionJsonPath);
    reportProgress(0.9, localize(@"i18n_str_1263", nil));
    // 参照 ZL2 progressIgnoreList：bootstraplauncher 0.1.17+ 需要 -DignoreList 包含 ${primary_jar_name}
    [MinecraftResourceUtils applyBootstrapLauncherIgnoreListFix:versionJson];
    NSError *writeError = saveJSONToFile(versionJson, versionJsonPath);
    if (writeError) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to write version JSON: %@", writeError.localizedDescription]}];
        }
        return NO;
    }
    NSLog(@"[NeoForgeDirect] Version JSON written successfully");

    // 参照 FCL/HMCL：确保父版本（vanilla MC）的 version JSON 已存在。
    // NeoForge 的 version.json 含 "inheritsFrom": "1.20.1" 等字段，启动时 Java 端会
    // 读取 versions/{inheritsFrom}/{inheritsFrom}.json 与 NeoForge 版本合并。
    // 若用户尚未安装原版，启动会因 FileNotFoundException 崩溃。
    NSString *inheritsFrom = [versionJson[@"inheritsFrom"] isKindOfClass:[NSString class]] ? versionJson[@"inheritsFrom"] : nil;
    if (inheritsFrom.length > 0 && ![inheritsFrom isEqualToString:versionId]) {
        NSLog(@"[NeoForgeDirect] Checking parent vanilla version: %@", inheritsFrom);
        NSError *parentError = nil;
        if (![self ensureParentVersionExists:inheritsFrom error:&parentError]) {
            NSLog(@"[NeoForgeDirect] Warning: parent version %@ auto-completion failed: %@", inheritsFrom, parentError.localizedDescription ?: @"Unknown error");
        } else {
            NSLog(@"[NeoForgeDirect] Parent vanilla version ensured: %@", inheritsFrom);
        }
    }

    NSLog(@"[NeoForgeDirect] installNewFormat completed");
    return YES;
}

#pragma mark - Helpers

// 游戏目录：与 JavaLauncher.m 中 [launchTarget isKindOfClass:NSDictionary.class] 分支保持一致
// 即 $POJAV_HOME/instances/<general.game_directory>/<profile.gameDir>
// 但直装时还没有 profile，无法读 gameDir，使用默认 "."
+ (NSString *)gameDirectory {
    const char *env = getenv("POJAV_GAME_DIR");
    if (env) {
        return [@(env) stringByStandardizingPath];
    }
    return NSHomeDirectory();
}

/// 阶段6修复（参照 FCL）：用 NSURLSession 替代已废弃的 NSURLConnection sendSynchronousRequest:
/// 进行同步 HTTP 下载。原 NSURLConnection 在 iOS 13+ 已废弃，BMCLAPI 等镜像源在某些 iOS 版本
/// 下表现不稳定（TLS 协商失败、超时不生效、不跟随 302 重定向等），导致 ensureParentVersionExists:
/// 拉取父版本 JSON 失败 → NeoForge 版本 inheritsFrom 找不到原版 → 启动崩溃。
+ (NSData *)downloadDataForRequest:(NSURLRequest *)request error:(NSError **)error {
    if (!request) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"nil request"}];
        }
        return nil;
    }
    __block NSData *resultData = nil;
    __block NSError *resultError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                   completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
        if (taskError) {
            resultError = taskError;
        } else if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
            if (statusCode >= 400) {
                resultError = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                                   code:statusCode
                                               userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld for %@", (long)statusCode, request.URL.absoluteString]}];
            } else {
                resultData = data;
            }
        } else {
            resultData = data;
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    long waitResult = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));
    if (waitResult != 0) {
        [task cancel];
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NSURLErrorTimedOut
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_1119", nil), request.URL.absoluteString]}];
        }
        return nil;
    }
    if (error) *error = resultError;
    return resultData;
}

/// 参照 FCL/HMCL：确保父版本（vanilla MC）的 version JSON 已存在。
/// NeoForge 的 version.json 含 "inheritsFrom": "1.20.1" 等字段，启动时 Java 端
/// Tools.getVersionInfo() 会读取 versions/{inheritsFrom}/{inheritsFrom}.json 与当前版本合并。
/// 若用户尚未安装原版，启动会因 FileNotFoundException 崩溃。
/// 本方法仅下载父版本的 version JSON（不下载原版 client.jar，因为 iOS 启动器使用
/// 自有渲染管线，不需要原版 client.jar；但需要 JSON 以提供 mainClass、arguments、
/// assetIndex、vanilla libraries 等元数据）。
+ (BOOL)ensureParentVersionExists:(NSString *)parentVersionId error:(NSError **)error {
    if (parentVersionId.length == 0) return YES;

    NSString *mainGameDir = [self gameDirectory];
    NSString *parentVersionDir = [mainGameDir stringByAppendingPathComponent:
                                  [NSString stringWithFormat:@"versions/%@", parentVersionId]];
    NSString *parentJsonPath = [parentVersionDir stringByAppendingPathComponent:
                                [NSString stringWithFormat:@"%@.json", parentVersionId]];

    // 1. 父版本 JSON 已存在，无需下载
    if ([NSFileManager.defaultManager fileExistsAtPath:parentJsonPath]) {
        NSLog(@"[NeoForgeDirect] Parent version JSON already exists: %@", parentJsonPath);
        return YES;
    }

    NSLog(@"[NeoForgeDirect] Parent version JSON missing, downloading: %@", parentVersionId);

    // 2. 拉取 Mojang 版本清单
    NSString *downloadSource = getPrefObject(@"general.download_source");
    BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];
    NSString *manifestURL = useBMCLAPI
        ? @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json"
        : @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";

    NSURL *url = [NSURL URLWithString:manifestURL];
    if (!url) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid manifest URL"}];
        }
        return NO;
    }

    NSMutableURLRequest *manifestRequest = [NSMutableURLRequest requestWithURL:url];
    manifestRequest.timeoutInterval = 30.0;
    manifestRequest.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [manifestRequest setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];

    NSData *manifestData = [self downloadDataForRequest:manifestRequest error:error];
    if (!manifestData) {
        NSLog(@"[NeoForgeDirect] Failed to download version manifest: %@", error ? [*error localizedDescription] : @"unknown");
        return NO;
    }

    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil];
    NSArray *versions = [manifest isKindOfClass:[NSDictionary class]] ? manifest[@"versions"] : nil;
    if (![versions isKindOfClass:[NSArray class]]) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid version manifest format"}];
        }
        return NO;
    }

    // 3. 查找匹配的版本条目，获取 version JSON URL
    NSString *versionJSONURL = nil;
    for (NSDictionary *v in versions) {
        if ([v isKindOfClass:[NSDictionary class]] && [v[@"id"] isEqualToString:parentVersionId]) {
            versionJSONURL = [v[@"url"] isKindOfClass:[NSString class]] ? v[@"url"] : nil;
            break;
        }
    }
    if (!versionJSONURL) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Version %@ not found in manifest", parentVersionId]}];
        }
        return NO;
    }

    // BMCLAPI 镜像：替换 Mojang 官方域名为 BMCLAPI 域名
    if (useBMCLAPI) {
        versionJSONURL = [versionJSONURL stringByReplacingOccurrencesOfString:@"piston-meta.mojang.com"
                                                                    withString:@"bmclapi2.bangbang93.com"];
        versionJSONURL = [versionJSONURL stringByReplacingOccurrencesOfString:@"launchermeta.mojang.com"
                                                                    withString:@"bmclapi2.bangbang93.com"];
    }

    NSLog(@"[NeoForgeDirect] Downloading parent version JSON from: %@", versionJSONURL);

    // 4. 下载 version JSON
    NSURL *jsonURL = [NSURL URLWithString:versionJSONURL];
    if (!jsonURL) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid version JSON URL"}];
        }
        return NO;
    }

    NSMutableURLRequest *jsonRequest = [NSMutableURLRequest requestWithURL:jsonURL];
    jsonRequest.timeoutInterval = 30.0;
    jsonRequest.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [jsonRequest setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];

    NSData *jsonData = [self downloadDataForRequest:jsonRequest error:error];
    if (!jsonData) {
        NSLog(@"[NeoForgeDirect] Failed to download parent version JSON: %@", error ? [*error localizedDescription] : @"unknown");
        return NO;
    }

    // 5. 创建父版本目录并写入 JSON
    NSError *dirError = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:parentVersionDir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:&dirError];
    if (dirError) {
        NSLog(@"[NeoForgeDirect] Failed to create parent version dir: %@", dirError.localizedDescription);
        if (error) *error = dirError;
        return NO;
    }

    NSError *writeErr = nil;
    if (![jsonData writeToFile:parentJsonPath options:NSDataWritingAtomic error:&writeErr]) {
        NSLog(@"[NeoForgeDirect] Failed to write parent version JSON: %@", writeErr.localizedDescription);
        if (error) *error = writeErr;
        return NO;
    }

    NSLog(@"[NeoForgeDirect] Parent version JSON saved: %@ (%lu bytes)", parentJsonPath, (unsigned long)jsonData.length);
    return YES;
}

+ (void)registerVersion:(NSString *)versionId {
    NSLog(@"[NeoForgeDirect] registerVersion called: %@", versionId);
    PLProfiles *profiles = [PLProfiles current];
    NSLog(@"[NeoForgeDirect] PLProfiles current: %@", profiles ? @"ok" : @"nil");
    NSMutableDictionary *profileDict = [NSMutableDictionary dictionary];
    profileDict[@"name"] = versionId;
    profileDict[@"lastVersionId"] = versionId;
    // 改回原来的"游戏目录切换"机制：所有版本共享根目录（gameDir="."）
    // 用户通过设置中的"游戏目录切换"功能手动切换不同的 gameDir
    profileDict[@"gameDir"] = @".";
    profileDict[@"type"] = @"custom";
    profileDict[@"created"] = [NSDate date].description;
    // 推断 Java 版本：NeoForge 1.20.5+ 需 Java 21，1.18+ 需 Java 17，1.17 需 Java 16
    NSInteger javaMajor = [self inferJavaMajorVersionFromVersionId:versionId];
    // 写入 NSString 而非 NSDictionary，与 ProfileSettingsViewController 等所有读取方一致
    // JavaLauncher 通过 .intValue 读取，"17".intValue = 17
    profileDict[@"javaVersion"] = [NSString stringWithFormat:@"%ld", (long)javaMajor];
    [profiles saveProfile:profileDict withName:versionId];
    // 与 Fabric / Vanilla 安装路径保持一致：自动选中新建的 profile，避免用户回到主界面仍启动旧版本
    profiles.selectedProfileName = versionId;
    NSLog(@"[NeoForgeDirect] Profile saved and selected (javaVersion=%ld, gameDir=%@)", (long)javaMajor, profileDict[@"gameDir"]);
}

/// 从 versionId 中推断所需 Java 主版本号
/// versionId 可能为两种格式：
///   - 整合包路径: "{mc}-neoforge-{loader}"，如 "1.20.1-neoforge-47.1.0"、"1.21.5-neoforge-21.5.75"
///   - UI 路径: "NeoForge-{loader}"，如 "NeoForge-47.1.0"、"NeoForge-21.5.75"
/// 需兼顾两种格式，先尝试直接匹配 MC 版本，失败则从 NeoForge loader 版本号反推 MC 版本
+ (NSInteger)inferJavaMajorVersionFromVersionId:(NSString *)versionId {
    // 1. 先尝试匹配 "1.x.x" 格式的 MC 版本（覆盖整合包路径，以及 UI 路径中可能含 1.x.x 的边界情况）
    //    使用锚定开头（^|[-_]) 避免误匹配 loader 版本号中的 "1.x" 子串
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(?:^|[-_])1\\.(\\d+)(?:\\.(\\d+))?"
                                                                           options:0
                                                                             error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:versionId options:0 range:NSMakeRange(0, versionId.length)];
    if (match && match.numberOfRanges >= 2) {
        NSString *minorStr = [versionId substringWithRange:[match rangeAtIndex:1]];
        NSInteger minor = [minorStr integerValue];
        NSString *patchStr = (match.numberOfRanges >= 3 && [match rangeAtIndex:2].location != NSNotFound)
                            ? [versionId substringWithRange:[match rangeAtIndex:2]]
                            : @"0";
        NSInteger patch = [patchStr integerValue];
        if (minor >= 21) return 21;                  // 1.21+
        if (minor >= 20 && patch >= 5) return 21;    // 1.20.5+
        if (minor >= 18) return 17;                  // 1.18 - 1.20.4
        if (minor >= 17) return 17;                  // 1.17（NeoForge 最低 17，Java 17 可向后兼容运行 1.17）
        return 17;                                    // 1.16 及以下（NeoForge 不支持，但保守返回 17）
    }

    // 2. 匹配失败时（UI 路径 versionId = "NeoForge-{loader}"），从 NeoForge loader 版本号反推 MC 版本
    //    NeoForge 版本号约定：
    //      - 47.x.y         → MC 1.20.1（legacy forge artifactId）→ Java 17
    //      - 20.2.x - 20.4.x → MC 1.20.2-1.20.4                     → Java 17
    //      - 20.5.x - 20.6.x → MC 1.20.5-1.20.6                     → Java 21
    //      - 21.x.x          → MC 1.21.x                            → Java 21
    //      - 26.x.x+         → MC 1.26.x+（未来版本）               → Java 21
    NSString *loaderVersion = [self extractNeoForgeLoaderVersionFromVersionId:versionId];
    if (loaderVersion.length > 0) {
        NSArray *parts = [loaderVersion componentsSeparatedByString:@"."];
        if (parts.count >= 2) {
            NSInteger major = [parts[0] integerValue];
            NSInteger minor = (parts.count >= 2) ? [parts[1] integerValue] : 0;
            // 47.x（1.20.1 legacy）→ Java 17
            if (major == 47) return 17;
            // 20.x 系列：20.5+ → Java 21，20.2-20.4 → Java 17
            if (major == 20) {
                return (minor >= 5) ? 21 : 17;
            }
            // 21.x 及以上（1.21+）→ Java 21
            if (major >= 21) return 21;
        }
    }

    return 17; // NeoForge 最低 Java 17
}

/// 从 versionId 中提取 NeoForge loader 版本号
/// "NeoForge-21.5.75" → "21.5.75"
/// "1.20.1-neoforge-47.1.0" → "47.1.0"
/// "1.21.5-neoforge-21.5.75-beta" → "21.5.75-beta"
+ (NSString *)extractNeoForgeLoaderVersionFromVersionId:(NSString *)versionId {
    if (!versionId.length) return @"";
    // 整合包路径格式: "{mc}-neoforge-{loader}"
    NSString *marker = @"-neoforge-";
    NSRange markerRange = [versionId rangeOfString:marker options:NSCaseInsensitiveSearch];
    if (markerRange.location != NSNotFound) {
        return [versionId substringFromIndex:markerRange.location + markerRange.length];
    }
    // UI 路径格式: "NeoForge-{loader}"
    NSRange dashRange = [versionId rangeOfString:@"-"];
    if (dashRange.location != NSNotFound) {
        return [versionId substringFromIndex:dashRange.location + dashRange.length];
    }
    return versionId;
}

#pragma mark - Maven entry Extraction

// 解压 installer.jar 内 maven/ 目录下所有文件到 libraries 目录
// 返回成功解压的文件数
+ (NSUInteger)extractAllMavenEntries:(NSString *)installerPath toLibrariesDir:(NSString *)librariesDir {
    NSError *openError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:installerPath error:&openError];
    if (!archive || openError) {
        NSLog(@"[NeoForgeDirect] extractAllMavenEntries: failed to open archive: %@", openError.localizedDescription ?: @"unknown");
        return 0;
    }

    NSError *listError = nil;
    NSArray<NSString *> *filenames = [archive listFilenames:&listError];
    if (!filenames || listError) {
        NSLog(@"[NeoForgeDirect] extractAllMavenEntries: failed to list filenames: %@", listError.localizedDescription ?: @"unknown");
        return 0;
    }

    NSUInteger count = 0;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *name in filenames) {
        if (![name hasPrefix:@"maven/"]) continue;
        // 跳过目录条目（以 / 结尾），避免 extractDataFromFile 返回空数据产生误报日志
        if ([name hasSuffix:@"/"]) continue;

        NSString *relativePath = [name substringFromIndex:@"maven/".length];
        if (relativePath.length == 0) continue;

        NSString *destPath = [librariesDir stringByAppendingPathComponent:relativePath];
        // 已存在的文件跳过，避免重复解压（重复安装场景）
        if ([fm fileExistsAtPath:destPath]) {
            count++;
            continue;
        }

        // 直接用已打开的 archive 实例提取，避免每个文件都重新打开 zip（性能优化）
        NSError *extractError = nil;
        NSData *data = [archive extractDataFromFile:name error:&extractError];
        if (!data || extractError) {
            NSLog(@"[NeoForgeDirect] extractAllMavenEntries: failed to extract %@: %@", name, extractError.localizedDescription ?: @"unknown");
            continue;
        }

        // 创建目标目录
        NSString *destDir = [destPath stringByDeletingLastPathComponent];
        [fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];

        // 写入文件
        NSError *writeError = nil;
        if (![data writeToFile:destPath options:NSDataWritingAtomic error:&writeError]) {
            NSLog(@"[NeoForgeDirect] extractAllMavenEntries: failed to write %@: %@", destPath, writeError.localizedDescription ?: @"unknown");
            continue;
        }
        count++;
    }
    return count;
}

#pragma mark - Library Download

// 下载 version.json.libraries 中尚未存在的库
+ (void)downloadMissingLibraries:(NSArray *)libraries
                   librariesDir:(NSString *)librariesDir
                       progress:(void (^)(double, NSString *))progress
                   baseProgress:(double)base
                  progressSpan:(double)span {
    NSUInteger total = libraries.count;
    if (total == 0) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSUInteger downloaded = 0;
    NSUInteger skipped = 0;
    NSUInteger failed = 0;
    NSUInteger processed = 0;  // 已处理数（用于进度计算，包含成功/跳过/失败）
    NSMutableArray<NSString *> *criticalFailures = [NSMutableArray array];  // 关键库失败清单

    for (NSDictionary *library in libraries) {
        if (![library isKindOfClass:[NSDictionary class]]) continue;

        NSString *name = [library[@"name"] isKindOfClass:[NSString class]] ? library[@"name"] : nil;
        if (!name) continue;

        // 参照 FCL/HMCL：评估库的 OS rules，iOS 视为 osx。
        // 跳过仅在 Windows/Linux 上启用的库（如 natives-windows、twitch 平台库等），
        // 避免下载无用的二进制 natives 和潜在的 404 失败。
        id rulesObj = library[@"rules"];
        if ([rulesObj isKindOfClass:[NSArray class]] && [(NSArray *)rulesObj count] > 0) {
            if (![MinecraftResourceUtils evaluateRules:(NSArray *)rulesObj]) {
                NSLog(@"[NeoForgeDirect] Skipping library %@ (OS rules disallow osx/iOS)", name);
                skipped++;
                processed++;
                continue;
            }
        }

        // 解析目标路径
        NSString *relativePath = nil;
        NSDictionary *downloads = library[@"downloads"];
        if ([downloads isKindOfClass:[NSDictionary class]]) {
            NSDictionary *artifact = downloads[@"artifact"];
            if ([artifact isKindOfClass:[NSDictionary class]]) {
                id artifactPathObj = artifact[@"path"];
                if ([artifactPathObj isKindOfClass:[NSString class]] && [(NSString *)artifactPathObj length] > 0) {
                    relativePath = (NSString *)artifactPathObj;
                }
            }
        }
        if (!relativePath) {
            relativePath = [self mavenPathToRelativePath:name];
        }
        if (relativePath.length == 0) continue;

        NSString *destPath = [librariesDir stringByAppendingPathComponent:relativePath];

        // 已存在则跳过
        if ([fm fileExistsAtPath:destPath]) {
            skipped++;
            processed++;
            continue;
        }

        // 拼 URL
        NSString *url = nil;
        if ([downloads isKindOfClass:[NSDictionary class]]) {
            NSDictionary *artifact = downloads[@"artifact"];
            if ([artifact isKindOfClass:[NSDictionary class]]) {
                id urlObj = artifact[@"url"];
                if ([urlObj isKindOfClass:[NSString class]] && [(NSString *)urlObj length] > 0) {
                    url = (NSString *)urlObj;
                }
            }
        }
        if (!url) {
            url = [self buildMavenURLForLibrary:name relativePath:relativePath];
        }

        if (!url) {
            NSLog(@"[NeoForgeDirect] Cannot build URL for library %@, skipping", name);
            failed++;
            processed++;
            continue;
        }

        // 用 processed 计算进度（避免失败时进度停滞）
        if (progress) {
            double p = base + span * ((double)processed / (double)total);
            progress(p, [NSString stringWithFormat:localize(@"i18n_str_1127", nil), (unsigned long)(processed + 1), (unsigned long)total, name]);
        }

        NSError *downloadError = nil;
        if ([self downloadFileFromURL:url toPath:destPath error:&downloadError]) {
            downloaded++;
            NSLog(@"[NeoForgeDirect] Downloaded library: %@", name);
        } else {
            // 主源失败：尝试 fallback 源
            NSLog(@"[NeoForgeDirect] Primary source failed for %@, trying fallback: %@", name, downloadError.localizedDescription ?: @"unknown");
            NSString *fallbackURL = [self buildFallbackURLForLibrary:name relativePath:relativePath];
            if (fallbackURL && ![fallbackURL isEqualToString:url]) {
                NSError *fallbackError = nil;
                if ([self downloadFileFromURL:fallbackURL toPath:destPath error:&fallbackError]) {
                    downloaded++;
                    NSLog(@"[NeoForgeDirect] Downloaded library via fallback: %@", name);
                    processed++;
                    continue;
                }
                NSLog(@"[NeoForgeDirect] Fallback also failed for %@: %@", name, fallbackError.localizedDescription ?: @"unknown");
            }
            failed++;
            // 关键库失败会启动崩溃，记录警告
            if ([self isCriticalLibrary:name]) {
                [criticalFailures addObject:name];
                NSLog(@"[NeoForgeDirect] Warning: critical library download failed (app will crash on launch): %@", name);
            } else {
                NSLog(@"[NeoForgeDirect] Failed to download library %@ (both sources failed)", name);
            }
        }
        processed++;
    }

    NSLog(@"[NeoForgeDirect] Library download summary: downloaded=%lu, skipped=%lu, failed=%lu, total=%lu, criticalFailures=%lu",
          (unsigned long)downloaded, (unsigned long)skipped, (unsigned long)failed, (unsigned long)total, (unsigned long)criticalFailures.count);
    if (criticalFailures.count > 0) {
        NSLog(@"[NeoForgeDirect] Warning: critical library download failures: %@", criticalFailures);
    }
}

/// 判断是否为关键库（缺失会导致启动崩溃）
+ (BOOL)isCriticalLibrary:(NSString *)name {
    if (!name.length) return NO;
    NSArray<NSString *> *criticalPrefixes = @[
        @"cpw.mods:modlauncher",
        @"net.minecraftforge.bootstraplauncher",
        @"net.minecraftforge:forge",
        @"net.neoforged:forge",
        @"net.neoforged:neoforge",
        @"net.neoforged.fancymodloader",
        @"org.spongepowered:mixin",
        @"org.ow2.asm:asm",
        @"com.google.guava:guava",
        @"com.google.code.gson:gson",
        @"org.lwjgl:lwjgl",
        @"com.mojang:authlib",
        @"com.mojang:brigadier",
        @"com.mojang:datafixerupper",
        @"com.mojang:minecraft"
    ];
    for (NSString *prefix in criticalPrefixes) {
        if ([name hasPrefix:prefix]) return YES;
    }
    return NO;
}

// 为 library 构建 maven URL
// 优化路由：根据 groupId 精确匹配到正确的 maven 仓库，避免 404
+ (NSString *)buildMavenURLForLibrary:(NSString *)name relativePath:(NSString *)relativePath {
    NSString *downloadSource = getPrefObject(@"general.download_source");
    BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];

    // NeoForge 自家库走 maven.neoforged.net/releases
    if ([name hasPrefix:@"net.neoforged:"] || [name hasPrefix:@"net.neoforged."] || [name hasPrefix:@"cpw.mods:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.neoforged.net/releases/%@", relativePath];
    }

    // Forge 自家库走 maven.minecraftforge.net
    if ([name hasPrefix:@"net.minecraftforge:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
    }

    // SpongePowered (mixin 等) 走 repo.spongepowered.org
    if ([name hasPrefix:@"org.spongepowered:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://repo.spongepowered.org/repository/maven-public/%@", relativePath];
    }

    // oceanlabs、asm 走 maven.minecraftforge.net
    if ([name hasPrefix:@"de.oceanlabs.mcp:"] || [name hasPrefix:@"org.ow2.asm:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
    }

    // 其他库（Mojang、lwjgl 等）走 libraries.minecraft.net（BMCLAPI 镜像）
    if (useBMCLAPI) {
        return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
    }
    return [NSString stringWithFormat:@"https://libraries.minecraft.net/%@", relativePath];
}

/// 构建 fallback URL（当主源失败时切换到 BMCLAPI 镜像，或反之）
+ (NSString *)buildFallbackURLForLibrary:(NSString *)name relativePath:(NSString *)relativePath {
    NSString *downloadSource = getPrefObject(@"general.download_source");
    BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];

    if (useBMCLAPI) {
        // 从 BMCLAPI 失败，尝试官方源
        if ([name hasPrefix:@"net.neoforged:"] || [name hasPrefix:@"net.neoforged."] || [name hasPrefix:@"cpw.mods:"]) {
            return [NSString stringWithFormat:@"https://maven.neoforged.net/releases/%@", relativePath];
        }
        if ([name hasPrefix:@"net.minecraftforge:"] || [name hasPrefix:@"de.oceanlabs.mcp:"] || [name hasPrefix:@"org.ow2.asm:"]) {
            return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
        }
        if ([name hasPrefix:@"org.spongepowered:"]) {
            return [NSString stringWithFormat:@"https://repo.spongepowered.org/repository/maven-public/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://libraries.minecraft.net/%@", relativePath];
    }
    // 从官方源失败，尝试 BMCLAPI 镜像
    return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
}

// 同步下载文件到指定路径（带 60 秒超时）
+ (BOOL)downloadFileFromURL:(NSString *)urlString toPath:(NSString *)destPath error:(NSError **)error {
    if (error) *error = nil;

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Invalid URL: %@", urlString]}];
        }
        return NO;
    }

    NSString *destDir = [destPath stringByDeletingLastPathComponent];
    NSError *dirError = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:destDir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:&dirError];
    if (dirError) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create directory %@: %@", destDir, dirError.localizedDescription]}];
        }
        return NO;
    }

    // 用 NSURLSession 同步下载，带 60 秒超时（避免弱网下 dataWithContentsOfURL 挂死）
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 60.0;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    // 添加 User-Agent：参照 FCL 使用浏览器风格 UA，提升 BMCLAPI/Cloudflare 源兼容性。
    [request setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/java-archive,*/*;q=0.9" forHTTPHeaderField:@"Accept"];

    __block NSData *resultData = nil;
    __block NSError *resultError = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
        if (taskError) {
            resultError = taskError;
        } else if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
            if (statusCode >= 400) {
                resultError = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                                   code:statusCode
                                               userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld: %@", (long)statusCode, urlString]}];
            } else {
                resultData = data;
            }
        } else {
            resultData = data;
        }
        dispatch_semaphore_signal(semaphore);
    }];
    [task resume];
    long waitResult = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 70 * NSEC_PER_SEC));
    if (waitResult != 0) {
        // 信号量超时：取消 task 释放网络资源，避免后台 task 持续运行导致临时内存泄漏
        [task cancel];
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NSURLErrorTimedOut
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_1129", nil), urlString]}];
        }
        return NO;
    }

    if (resultError) {
        if (error) *error = resultError;
        return NO;
    }
    if (!resultData || resultData.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Empty response: %@", urlString]}];
        }
        return NO;
    }

    BOOL written = [resultData writeToFile:destPath options:NSDataWritingAtomic error:error];
    if (!written) {
        return NO;
    }

    NSLog(@"[NeoForgeDirect] Downloaded %@ (%lu bytes) -> %@", urlString.lastPathComponent ?: urlString, (unsigned long)resultData.length, destPath);
    return YES;
}

#pragma mark - ZIP / UnzipKit helpers

+ (NSData *)dataFromZip:(NSString *)zipPath entry:(NSString *)entryPath error:(NSError **)error {
    if (error) {
        *error = nil;
    }

    NSError *openError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:zipPath error:&openError];
    if (!archive || openError) {
        NSLog(@"[NeoForgeDirect] Failed to open archive: %@", openError.localizedDescription ?: @"unknown");
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorInvalidArchive
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to open installer archive: %@", openError.localizedDescription ?: @"unknown"]}];
        }
        return nil;
    }

    NSError *extractError = nil;
    NSData *result = [archive extractDataFromFile:entryPath error:&extractError];
    if (!result) {
        // 部分版本 entry 路径带前导 "/"，尝试兼容
        if ([entryPath hasPrefix:@"/"]) {
            NSString *altPath = [entryPath substringFromIndex:1];
            result = [archive extractDataFromFile:altPath error:&extractError];
        }
    }
    if (!result) {
        NSLog(@"[NeoForgeDirect] Failed to extract entry '%@': %@", entryPath, extractError.localizedDescription ?: @"unknown");
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorExtractionFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to extract %@: %@", entryPath, extractError.localizedDescription ?: @"not found"]}];
        }
        return nil;
    }

    NSLog(@"[NeoForgeDirect] Extracted entry '%@' (%lu bytes)", entryPath, (unsigned long)result.length);
    return result;
}

+ (BOOL)entryExists:(NSString *)zipPath entry:(NSString *)entryPath {
    NSError *openError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:zipPath error:&openError];
    if (!archive || openError) {
        return NO;
    }

    NSError *listError = nil;
    NSArray<NSString *> *filenames = [archive listFilenames:&listError];
    if (!filenames || listError) {
        return NO;
    }

    for (NSString *name in filenames) {
        if ([name isEqualToString:entryPath]) {
            return YES;
        }
    }
    return NO;
}

+ (BOOL)extractFile:(NSString *)zipPath entry:(NSString *)entryPath to:(NSString *)destPath error:(NSError **)error {
    if (error) {
        *error = nil;
    }

    NSData *data = [self dataFromZip:zipPath entry:entryPath error:error];
    if (!data) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorExtractionFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to extract %@ from installer", entryPath]}];
        }
        return NO;
    }

    NSString *destDir = [destPath stringByDeletingLastPathComponent];
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:destDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&dirError];
    if (dirError) {
        NSLog(@"[NeoForgeDirect] Failed to create directory '%@': %@", destDir, dirError.localizedDescription);
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create directory %@: %@", destDir, dirError.localizedDescription]}];
        }
        return NO;
    }

    BOOL written = [data writeToFile:destPath options:NSDataWritingAtomic error:error];
    if (!written) {
        NSLog(@"[NeoForgeDirect] Failed to write file '%@'", destPath);
        if (error && !*error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to write %@", destPath]}];
        }
        return NO;
    }

    NSLog(@"[NeoForgeDirect] Written file '%@' (%lu bytes)", destPath, (unsigned long)data.length);
    return YES;
}

#pragma mark - Maven path utilities

+ (NSString *)mavenPathToRelativePath:(NSString *)mavenPath {
    NSArray *parts = [mavenPath componentsSeparatedByString:@":"];
    if (parts.count < 3) {
        return mavenPath;
    }

    NSString *groupId = parts[0];
    NSString *artifactId = parts[1];
    NSString *version = parts[2];
    NSString *classifier = (parts.count > 3) ? parts[3] : nil;

    NSString *groupPath = [groupId stringByReplacingOccurrencesOfString:@"." withString:@"/"];
    NSString *jarName;
    if (classifier.length > 0) {
        jarName = [NSString stringWithFormat:@"%@-%@-%@.jar", artifactId, version, classifier];
    } else {
        jarName = [NSString stringWithFormat:@"%@-%@.jar", artifactId, version];
    }

    return [NSString stringWithFormat:@"%@/%@/%@/%@", groupPath, artifactId, version, jarName];
}

+ (NSString *)mavenNameToPath:(NSString *)name {
    return [self mavenPathToRelativePath:name];
}

@end
