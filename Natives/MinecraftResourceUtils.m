#include <CommonCrypto/CommonDigest.h>

#import "authenticator/BaseAuthenticator.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceUtils.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "PLMirrorCenter.h"
#import "UZKArchive.h"

@implementation MinecraftResourceUtils

#pragma mark - Forge/NeoForge 启动修复（参照 ZL2 Install.ForgeLike.progressIgnoreList）

/// 判断点分版本号 a 是否 >= b（仅用于 bootstraplauncher 版本判断）
+ (BOOL)pl_version:(NSString *)a isBiggerOrEqualTo:(NSString *)b {
    NSArray<NSString *> *aParts = [a componentsSeparatedByString:@"."];
    NSArray<NSString *> *bParts = [b componentsSeparatedByString:@"."];
    NSUInteger count = MAX(aParts.count, bParts.count);
    for (NSUInteger i = 0; i < count; i++) {
        NSInteger aValue = i < aParts.count ? aParts[i].integerValue : 0;
        NSInteger bValue = i < bParts.count ? bParts[i].integerValue : 0;
        if (aValue != bValue) return aValue > bValue;
    }
    return YES;
}

+ (void)applyBootstrapLauncherIgnoreListFix:(NSMutableDictionary *)json {
    NSArray *libraries = json[@"libraries"];
    if (![libraries isKindOfClass:[NSArray class]]) return;

    BOOL hasNewBootstrapLauncher = NO;
    for (id item in libraries) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *name = item[@"name"];
        if (![name isKindOfClass:[NSString class]]) continue;
        NSArray<NSString *> *parts = [name componentsSeparatedByString:@":"];
        if (parts.count >= 3 &&
            [parts[0] isEqualToString:@"cpw.mods"] &&
            [parts[1] isEqualToString:@"bootstraplauncher"] &&
            [self pl_version:parts[2] isBiggerOrEqualTo:@"0.1.17"]) {
            hasNewBootstrapLauncher = YES;
            break;
        }
    }
    if (!hasNewBootstrapLauncher) return;

    NSDictionary *arguments = json[@"arguments"];
    if (![arguments isKindOfClass:[NSDictionary class]]) return;
    NSArray *jvm = arguments[@"jvm"];
    if (![jvm isKindOfClass:[NSArray class]]) return;

    NSInteger ignoreListIndex = NSNotFound;
    for (NSInteger i = (NSInteger)jvm.count - 1; i >= 0; i--) {
        id arg = jvm[(NSUInteger)i];
        if ([arg isKindOfClass:[NSString class]] && [arg hasPrefix:@"-DignoreList="]) {
            ignoreListIndex = i;
            break;
        }
    }
    if (ignoreListIndex == NSNotFound) return;

    NSMutableArray *mutableJvm = [jvm mutableCopy];
    NSString *originalArg = mutableJvm[(NSUInteger)ignoreListIndex];
    NSString *updatedArg = originalArg;

    // ${primary_jar_name}（ZL2 progressIgnoreList 原逻辑，幂等）
    if (![updatedArg containsString:@"${primary_jar_name}"]) {
        updatedArg = [updatedArg stringByAppendingString:@",${primary_jar_name}"];
    }

    // iOS 特有：JavaApp/Makefile 在合成 lwjgl-<ver>.jar 时把 launcher 的
    // com/apple/ios/audio/*.class 一并复制进去，导致 launcher.jar 与 lwjgl.jar
    // 两个自动模块导出同一个包。Forge/NeoForge 的 bootstraplauncher 走 JPMS
    // (Configuration.resolveAndBind) 时直接失败：
    //   java.lang.module.ResolutionException:
    //   Modules launcher and lwjgl export package com.apple.ios.audio to module brigadier
    // 把 lwjgl 加入 ignoreList：它仍留在 classpath 上供游戏正常调用，但不再被
    // 当作模块解析，重复导出消失，模块图得以构建。
    if (![updatedArg containsString:@"lwjgl"]) {
        updatedArg = [updatedArg stringByAppendingString:@",lwjgl"];
    }

    mutableJvm[(NSUInteger)ignoreListIndex] = updatedArg;

    NSMutableDictionary *mutableArguments = [arguments mutableCopy];
    mutableArguments[@"jvm"] = mutableJvm;
    json[@"arguments"] = mutableArguments;
    NSLog(@"[MCDL] bootstraplauncher >= 0.1.17: 已向 -DignoreList 追加 ${primary_jar_name} 与 lwjgl（消除 launcher/lwjgl 重复导出 com.apple.ios.audio）");
}

#pragma mark - OptiFine launchwrapper（参照 ZL2 Install.OptiFine.checkOFLaunchWrapper）

+ (NSArray *)optifineLaunchWrapperLibrariesWithOptiFineJarPath:(NSString *)optifineJarPath
                                                  librariesDir:(NSString *)librariesDir {
    // 1. OptiFine 1.13+：安装包内嵌 launchwrapper-of（OptiFine 自带的 launchwrapper 分支）
    NSError *archiveError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:optifineJarPath error:&archiveError];
    if (archive && !archiveError) {
        NSData *versionData = [archive extractDataFromFile:@"launchwrapper-of.txt" error:nil];
        if (versionData) {
            NSString *lwVersion = [[[NSString alloc] initWithData:versionData encoding:NSUTF8StringEncoding]
                                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (lwVersion.length > 0 &&
                [lwVersion rangeOfString:@"^[0-9]+(\\.[0-9]+)*$" options:NSRegularExpressionSearch].location != NSNotFound) {
                NSString *fileName = [NSString stringWithFormat:@"launchwrapper-of-%@.jar", lwVersion];
                NSData *lwData = [archive extractDataFromFile:fileName error:nil];
                if (lwData.length > 0) {
                    NSString *relativePath = [NSString stringWithFormat:@"optifine/launchwrapper-of/%@/%@", lwVersion, fileName];
                    NSString *absolutePath = [librariesDir stringByAppendingPathComponent:relativePath];
                    [[NSFileManager defaultManager] createDirectoryAtPath:[absolutePath stringByDeletingLastPathComponent]
                                              withIntermediateDirectories:YES attributes:nil error:nil];
                    [lwData writeToFile:absolutePath options:NSDataWritingAtomic error:nil];
                    NSLog(@"[MCDL] OptiFine launchwrapper-of %@ -> %@", lwVersion, relativePath);
                    return @[@{
                        @"name": [NSString stringWithFormat:@"optifine:launchwrapper-of:%@", lwVersion],
                        @"downloads": @{@"artifact": @{
                            @"path": relativePath,
                            @"url": @"",
                            @"size": @(lwData.length),
                            @"sha1": @""
                        }}
                    }];
                }
            }
        }
    }

    // 2. 旧版 OptiFine（1.12 及以下）：net.minecraft:launchwrapper:1.12
    NSString *relativePath = @"net/minecraft/launchwrapper/1.12/launchwrapper-1.12.jar";
    NSString *absolutePath = [librariesDir stringByAppendingPathComponent:relativePath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:absolutePath]) {
        NSURL *officialURL = [NSURL URLWithString:@"https://libraries.minecraft.net/net/minecraft/launchwrapper/1.12/launchwrapper-1.12.jar"];
        NSData *data = nil;
        for (NSURL *candidate in [PLMirrorCenter candidateURLsForOriginalURL:officialURL
                                                                resourceType:PLMirrorResourceTypeModLoader]) {
            data = [self pl_synchronousDownload:candidate];
            if (data.length > 0) break;
        }
        if (data.length == 0) {
            NSLog(@"[MCDL] OptiFine launchwrapper 1.12 下载失败");
            return nil;
        }
        [[NSFileManager defaultManager] createDirectoryAtPath:[absolutePath stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        [data writeToFile:absolutePath options:NSDataWritingAtomic error:nil];
    }
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:absolutePath error:nil];
    return @[@{
        @"name": @"net.minecraft:launchwrapper:1.12",
        @"downloads": @{@"artifact": @{
            @"path": relativePath,
            @"url": @"",
            @"size": attributes[NSFileSize] ?: @(0),
            @"sha1": @""
        }}
    }];
}

/// 同步下载（带移动端浏览器 UA，BMCLAPI 镜像校验 UA）
+ (NSData *)pl_synchronousDownload:(NSURL *)url {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
    request.timeoutInterval = 120;
    __block NSData *result = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && [response isKindOfClass:[NSHTTPURLResponse class]] &&
            ((NSHTTPURLResponse *)response).statusCode == 200) {
            result = data;
        }
        dispatch_semaphore_signal(semaphore);
    }];
    [task resume];
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(180 * NSEC_PER_SEC)));
    return result;
}

// Handle inheritsFrom
+ (void)processVersion:(NSMutableDictionary *)json inheritsFrom:(NSMutableDictionary *)inheritsFrom {
    [self insertSafety:inheritsFrom from:json arr:@[
        @"assetIndex", @"assets", @"id",
        @"inheritsFrom",
        @"mainClass", @"minecraftArguments",
        @"optifineLib", @"releaseTime", @"time", @"type"
    ]];
    // 合并 arguments 而非覆盖（参照 HMCL 的合并逻辑）
    // 修复：原代码 inheritsFrom[@"arguments"] = json[@"arguments"] 会无条件用子版本 arguments
    //   覆盖父版本，当子版本没有 arguments 字段时会把父版本的 arguments 清空为 nil，
    //   导致父版本的 arguments.jvm（可能包含 26.x 新增强制 --add-opens/--add-exports）被完全忽略，
    //   引发反射访问失败崩溃。
    if (json[@"arguments"]) {
        NSMutableDictionary *mergedArgs = [NSMutableDictionary dictionary];
        // 先保留父版本的 arguments
        if (inheritsFrom[@"arguments"]) {
            [mergedArgs addEntriesFromDictionary:inheritsFrom[@"arguments"]];
        }
        // 再用子版本的 arguments 覆盖（但保留父版本中子版本没有的键）
        if ([json[@"arguments"] isKindOfClass:[NSDictionary class]]) {
            for (NSString *key in json[@"arguments"]) {
                mergedArgs[key] = json[@"arguments"][key];
            }
        }
        inheritsFrom[@"arguments"] = mergedArgs;
    }

    for (NSMutableDictionary *lib in json[@"libraries"]) {
        NSString *libName = [lib[@"name"] substringToIndex:[lib[@"name"] rangeOfString:@":" options:NSBackwardsSearch].location];
        int i;
        for (i = 0; i < [inheritsFrom[@"libraries"] count]; i++) {
            NSMutableDictionary *libAdded = inheritsFrom[@"libraries"][i];
            NSString *libAddedName = [libAdded[@"name"] substringToIndex:[libAdded[@"name"] rangeOfString:@":" options:NSBackwardsSearch].location];

            if ([libAdded[@"name"] hasPrefix:libName]) {
                inheritsFrom[@"libraries"][i] = lib;
                i = -1;
                break;
            }
        }

        if (i != -1) {
            [inheritsFrom[@"libraries"] addObject:lib];
        }
    }

    //inheritsFrom[@"inheritsFrom"] = nil;
}

+ (void)insertSafety:(NSMutableDictionary *)targetVer from:(NSDictionary *)fromVer arr:(NSArray *)arr {
    for (NSString *key in arr) {
        if (([fromVer[key] isKindOfClass:NSString.class] && [fromVer[key] length] > 0) || targetVer[key] == nil) {
            targetVer[key] = fromVer[key];
        } else {
            NSLog(@"[MCDL] insertSafety: how to insert %@?", key);
        }
    }
}

+ (NSInteger)numberOfArgsToSkipForArg:(NSString *)arg {
    if (![arg isKindOfClass:NSString.class]) {
        // Skip non-string arg
        return 1;
    } else if ([arg hasPrefix:@"-cp"]) {
        // Skip "-cp <classpath>"
        return 2;
    } else if ([arg hasPrefix:@"-Djava.library.path="]) {
        return 1;
    } else if ([arg hasPrefix:@"-XX:HeapDumpPath"]) {
        return 1;
    } else if ([arg hasPrefix:@"-XstartOnFirstThread"]) {
        // 已由启动器硬编码设置，跳过避免重复
        return 1;
    } else if ([arg hasPrefix:@"-Djava.system.class.loader="]) {
        // 已由启动器硬编码设置
        return 1;
    } else {
        return 0;
    }
}

// 评估 Mojang 版本 JSON 中的 OS 规则。
// iOS 视作 osx（Apple 平台），因为 JVM 在 iOS 上以 macOS 兼容方式运行。
+ (BOOL)evaluateRules:(NSArray *)rules {
    if (rules.count == 0) return YES;
    BOOL allowed = NO;
    for (NSDictionary *rule in rules) {
        NSString *action = rule[@"action"];
        NSDictionary *os = rule[@"os"];
        NSDictionary *features = rule[@"features"];
        // 带 features 的规则（如 is_demo_user）本启动器不支持，跳过
        if (features.count > 0) {
            allowed = NO;
            continue;
        }
        BOOL match = YES;
        if (os[@"name"]) {
            // iOS 上 JVM 视为 osx 环境
            match = [os[@"name"] isEqualToString:@"osx"];
        }
        if (match) {
            allowed = [action isEqualToString:@"allow"];
        }
    }
    return allowed;
}

// 将规则化的 JVM 参数项展开为字符串数组
+ (NSArray<NSString *> *)flattenJvmArg:(id)arg {
    if ([arg isKindOfClass:NSString.class]) {
        return @[arg];
    } else if ([arg isKindOfClass:NSDictionary.class]) {
        if (![self evaluateRules:arg[@"rules"]]) return @[];
        id value = arg[@"value"];
        if ([value isKindOfClass:NSString.class]) return @[value];
        if ([value isKindOfClass:NSArray.class]) return value;
    }
    return @[];
}

+ (void)tweakVersionJson:(NSMutableDictionary *)json {
    // Exclude some libraries
    for (NSMutableDictionary *library in json[@"libraries"]) {
        library[@"skip"] = @(
            // Exclude platform-dependant libraries
            library[@"downloads"][@"classifiers"] != nil ||
            library[@"natives"] != nil ||
            // Exclude LWJGL libraries
            [library[@"name"] hasPrefix:@"org.lwjgl"]
        );

        NSString *versionStr = [library[@"name"] componentsSeparatedByString:@":"][2];
        NSArray<NSString *> *version = [versionStr componentsSeparatedByString:@"."];
        if ([library[@"name"] hasPrefix:@"net.java.dev.jna:jna:"]) {
            // 强制将 JNA 替换为 5.13.0 以保证 iOS 兼容性。
            // MC 26.3+ 要求 JNA 5.17.0，但其 darwin-aarch64 libjnidispatch 在 iOS 上
            // 加载 IOKit/CoreFoundation 后会导致 native crash/卡死（26.2 + JNA 5.13.0 正常）。
            // MC 不直接使用 JNA API（通过 oshi 间接使用），5.13.0 的 API 完全兼容。
            // PatchJNAAgent 会替换 Platform.class，与 JNA jar 版本无关。
            if (version.count >= 3 && version[0].intValue == 5 && version[1].intValue == 13 && version[2].intValue == 0) {
                continue;
            }
            NSLog(@"[MCDL] Replacing JNA %@ with 5.13.0 for iOS compatibility (required by %@)", versionStr, json[@"id"]);
            library[@"name"] = @"net.java.dev.jna:jna:5.13.0";
            library[@"downloads"][@"artifact"][@"path"] = @"net/java/dev/jna/jna/5.13.0/jna-5.13.0.jar";
            library[@"downloads"][@"artifact"][@"url"] = @"https://repo1.maven.org/maven2/net/java/dev/jna/jna/5.13.0/jna-5.13.0.jar";
            library[@"downloads"][@"artifact"][@"sha1"] = @"1200e7ebeedbe0d10062093f32925a912020e747";
        } else if ([library[@"name"] hasPrefix:@"org.ow2.asm:asm-all:"]) {
            // Early versions of the ASM library get repalced with 5.0.4 because Pojav's LWJGL is compiled for
            // Java 8, which is not supported by old ASM versions. Mod loaders like Forge, which depend on this
            // library, often include lwjgl in their class transformations, which causes errors with old ASM versions.
            if(version[0].intValue >= 5) continue;
            library[@"name"] = @"org.ow2.asm:asm-all:5.0.4";
            library[@"downloads"][@"artifact"][@"path"] = @"org/ow2/asm/asm-all/5.0.4/asm-all-5.0.4.jar";
            library[@"downloads"][@"artifact"][@"sha1"] = @"e6244859997b3d4237a552669279780876228909";
            library[@"downloads"][@"artifact"][@"url"] = @"https://repo1.maven.org/maven2/org/ow2/asm/asm-all/5.0.4/asm-all-5.0.4.jar";
        }
    }

    // Add the client as a library
    NSMutableDictionary *client = [[NSMutableDictionary alloc] init];
    client[@"downloads"] = [[NSMutableDictionary alloc] init];
    if (json[@"downloads"][@"client"] == nil) {
        client[@"downloads"][@"artifact"] = [[NSMutableDictionary alloc] init];
        client[@"skip"] = @YES;
    } else {
        client[@"downloads"][@"artifact"] = json[@"downloads"][@"client"];
    }
    client[@"downloads"][@"artifact"][@"path"] = [NSString stringWithFormat:@"../versions/%1$@/%1$@.jar", json[@"id"]];
    client[@"name"] = [NSString stringWithFormat:@"%@.jar", json[@"id"]];
    [json[@"libraries"] addObject:client];

    // 解析所有版本的官方 JVM Arguments（包括 vanilla 26.x）。
    // 原代码仅在 inheritsFrom 存在时解析，导致 vanilla 版本的 arguments.jvm
    // （可能包含 26.x 新增强制 --add-opens/--add-exports）被完全忽略，
    // 引发反射访问失败崩溃。
    if (json[@"arguments"][@"jvm"] == nil) {
        return;
    }
    json[@"arguments"][@"jvm_processed"] = [[NSMutableArray alloc] init];
    NSDictionary *varArgMap = @{
        @"${classpath_separator}": @":",
        @"${library_directory}": [NSString stringWithFormat:@"%s/libraries", getenv("POJAV_GAME_DIR")],
        @"${version_name}": json[@"id"]
    };
    int argsToSkip = 0;
    for (id rawArg in json[@"arguments"][@"jvm"]) {
        // 展开规则化参数（dict with rules），iOS 视为 osx
        NSArray<NSString *> *expanded = [self flattenJvmArg:rawArg];
        if (expanded.count == 0) continue;
        for (NSString *arg in expanded) {
            if (argsToSkip == 0) {
                argsToSkip = [self numberOfArgsToSkipForArg:arg];
            }
            if (argsToSkip == 0) {
                NSString *argStr = arg;
                for (NSString *key in varArgMap.allKeys) {
                    argStr = [argStr stringByReplacingOccurrencesOfString:key withString:varArgMap[key]];
                }
                [json[@"arguments"][@"jvm_processed"] addObject:argStr];
            } else {
                argsToSkip--;
            }
        }
    }
}

+ (NSObject *)findVersion:(NSString *)version inList:(NSArray *)list {
    return [list filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"(id == %@)", version]].firstObject;
}

+ (NSObject *)findNearestVersion:(NSObject *)version expectedType:(int)type {
    if (type != TYPE_RELEASE && type != TYPE_SNAPSHOT) {
        // Only support finding for releases and snapshot for now
        return nil;
    }

    if ([version isKindOfClass:NSString.class]){
        // Find in inheritsFrom
        NSDictionary *versionDict = parseJSONFromFile([NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), version]);
        NSAssert(versionDict != nil, @"version should not be null");
        if (versionDict[@"inheritsFrom"] == nil) {
            // How then?
            return nil; 
        }
        NSObject *inheritsFrom = [self findVersion:versionDict[@"inheritsFrom"] inList:remoteVersionList];
        if (type == TYPE_RELEASE) {
            return inheritsFrom;
        } else if (type == TYPE_SNAPSHOT) {
            return [self findNearestVersion:inheritsFrom expectedType:type];
        }
    }

    NSString *versionType = [version valueForKey:@"type"];
    int index = [remoteVersionList indexOfObject:(NSDictionary *)version];
    if ([versionType isEqualToString:@"release"] && type == TYPE_SNAPSHOT) {
        // Returns the (possible) latest snapshot for the version
        NSDictionary *result = remoteVersionList[index + 1];
        // Sometimes, a release is followed with another release (1.16->1.16.1), go lower in this case
        if ([result[@"type"] isEqualToString:@"release"]) {
            return [self findNearestVersion:result expectedType:type];
        }
        return result;
    } else if ([versionType isEqualToString:@"snapshot"] && type == TYPE_RELEASE) {
        while (remoteVersionList.count > abs(index)) {
            // In case the snapshot has yet attached to a release, perform a reverse find
            NSDictionary *result = remoteVersionList[abs(index)];
            // Returns the corresponding release for the snapshot, or latest release if none found
            if ([result[@"type"] isEqualToString:@"release"]) {
                return result;
            }
            // Continue to decrement, later abs() it
            index--;
        }
    }

    // No idea on handling everything else
    return nil;
}

@end
