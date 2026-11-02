#import "utils.h"
#import "installer/FabricUtils.h"
#import "ModpackUtils.h"
#import "PLMirrorCenter.h"

#pragma mark - 解压路径穿越防护（zip-slip）

/// 判断 zip 条目名是否可以安全写入 baseDir 下的相对路径。
///
/// 对齐 ZalithLauncher2 的 FileUtils.kt（L351-360）双层防护：
///   1. 条目名里不得含 ".." 路径段 —— 直接拒绝；
///   2. 归一化后必须仍在 baseDir 之内 —— 拦住 "a/../../b" 这类
///      归一化前不含 ".."、归一化后才越界的写法。
///
/// @param fileName 已剥离包装根目录的条目相对路径
/// @param baseDir  解压根目录（绝对路径）
/// @return 安全的绝对目标路径；不安全时返回 nil
static NSString *ameSafeZipDestination(NSString *fileName, NSString *baseDir) {
    if (fileName.length == 0 || baseDir.length == 0) return nil;

    // 统一分隔符：zip 规范用 '/'，但有些打包器会写 '\\'
    NSString *normalizedEntry = [fileName stringByReplacingOccurrencesOfString:@"\\\\" withString:@"/"];

    // 1) 拒绝任何 ".." 路径段（开头、中间、结尾都拦）
    for (NSString *seg in [normalizedEntry componentsSeparatedByString:@"/"]) {
        if ([seg isEqualToString:@".."]) {
            NSLog(@"[ModpackDL] Rejected zip entry with path traversal segment: %@", fileName);
            return nil;
        }
    }
    // 绝对路径条目同样拒绝（"C:/..." 或 "/etc/..."）
    if ([normalizedEntry hasPrefix:@"/"] || [normalizedEntry containsString:@":"]) {
        NSLog(@"[MODPACK-SEC] Rejected absolute zip entry: %@", fileName);
        return nil;
    }

    NSString *dest = [[baseDir stringByAppendingPathComponent:normalizedEntry] stringByStandardizingPath];
    NSString *root = [baseDir stringByStandardizingPath];

    // 2) 归一化后必须仍在根目录之内（含根目录本身）
    if (![dest isEqualToString:root] && ![dest hasPrefix:[root stringByAppendingString:@"/"]]) {
        NSLog(@"[MODPACK-SEC] Rejected zip entry escaping the extraction root: %@ -> %@", fileName, dest);
        return nil;
    }
    return dest;
}

@implementation ModpackUtils

+ (void)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path error:(NSError *__autoreleasing*)error {
    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        if (![fileInfo.filename hasPrefix:dir] ||
            fileInfo.filename.length <= dir.length) {
            return;
        }
        NSString *fileName = [fileInfo.filename substringFromIndex:dir.length+1];
        // zip-slip 防护（见 ameSafeZipDestination）：此前是裸拼接，
        // 含 ".." 的条目可写到解压根目录之外。nil 表示该条目不安全，跳过。
        NSString *destItemPath = ameSafeZipDestination(fileName, path);
        if (destItemPath == nil) {
            return;
        }
        NSString *destDirPath = fileInfo.isDirectory ? destItemPath : destItemPath.stringByDeletingLastPathComponent;
        BOOL createdDir = [NSFileManager.defaultManager createDirectoryAtPath:destDirPath
            withIntermediateDirectories:YES
            attributes:nil error:error];
        if (!createdDir) {
            *stop = YES;
            return;
        } else if (fileInfo.isDirectory) {
            return;
        }

        NSData *data = [archive extractData:fileInfo error:error];
        BOOL written = [data writeToFile:destItemPath options:NSDataWritingAtomic error:error];
        *stop = !data || !written;
        if (!*stop) {
            NSLog(@"[ModpackDL] Extracted %@", fileInfo.filename);
        }
    } error:error];
}

+ (NSDictionary *)infoForDependencies:(NSDictionary *)dependency {
    NSMutableDictionary *info = [NSMutableDictionary new];
    NSString *minecraftVersion = dependency[@"minecraft"];
    if (dependency[@"forge"]) {
        // Forge 没有独立的 version JSON 下载 URL，version JSON 嵌入在 installer.jar 中。
        // 设置 installer URL 和 loader 类型，让 ModrinthAPI/CurseForgeAPI 在整合包安装时
        // 下载 installer.jar 并调用 ForgeDirectInstaller 写入完整的 version.json + 下载 Forge 库。
        // 之前不设置任何字段会导致整合包安装后只设置 profile 但不下载版本 JSON，
        // 启动时报"找不到版本信息"。
        info[@"id"] = [NSString stringWithFormat:@"%@-forge-%@", minecraftVersion, dependency[@"forge"]];
        info[@"loader"] = @"Forge";
        info[@"loaderVersion"] = dependency[@"forge"];
        info[@"installer"] = [self installerURLForLoader:@"Forge"
                                          loaderVersion:dependency[@"forge"]
                                       minecraftVersion:minecraftVersion] ?: @"";
    } else if (dependency[@"fabric-loader"]) {
        info[@"id"] = [NSString stringWithFormat:@"fabric-loader-%@-%@", dependency[@"fabric-loader"], minecraftVersion];
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Fabric"][@"json"], minecraftVersion, dependency[@"fabric-loader"]];
    } else if (dependency[@"quilt-loader"]) {
        info[@"id"] = [NSString stringWithFormat:@"quilt-loader-%@-%@", dependency[@"quilt-loader"], minecraftVersion];
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Quilt"][@"json"], minecraftVersion, dependency[@"quilt-loader"]];
    } else if (dependency[@"neoforge"]) {
        // NeoForge 同 Forge，version JSON 嵌入在 installer.jar 中。
        // 设置 installer URL 和 loader 类型，让整合包安装时调用 NeoForgeDirectInstaller。
        NSString *neoforgeVer = dependency[@"neoforge"];
        info[@"id"] = [NSString stringWithFormat:@"%@-neoforge-%@", minecraftVersion, neoforgeVer];
        info[@"loader"] = @"NeoForge";
        info[@"loaderVersion"] = neoforgeVer;
        info[@"installer"] = [self installerURLForLoader:@"NeoForge"
                                          loaderVersion:neoforgeVer
                                       minecraftVersion:minecraftVersion] ?: @"";
    }
    info[@"minecraftVersion"] = minecraftVersion ?: @"";
    return info;
}

+ (nullable NSString *)installerURLForLoader:(NSString *)loader
                               loaderVersion:(NSString *)loaderVersion
                            minecraftVersion:(NSString *)minecraftVersion {
    // 统一经 PLMirrorCenter（ModLoader 类型）按当前策略取首选 URL：
    // mirror_first → BMCLAPI /maven（替换原硬编码 BMCLAPI 拼接），
    // official_first → 官方 maven 原样返回；策略键 download.modLoaderSource，
    // 未设置时由 PLMirrorCenter 回退旧键 general.download_source
    NSString *officialURL = nil;

    if ([loader isEqualToString:@"Forge"]) {
        // Forge versionString = "<mc>-<loaderVersion>"，例如 "1.20.1-47.3.0"
        NSString *versionString = [NSString stringWithFormat:@"%@-%@", minecraftVersion, loaderVersion];
        officialURL = [NSString stringWithFormat:@"https://maven.minecraftforge.net/net/minecraftforge/forge/%@/forge-%@-installer.jar", versionString, versionString];
    } else if ([loader isEqualToString:@"NeoForge"]) {
        // NeoForge 1.20.1 早期版本 artifactId 是 net.neoforged:forge，之后是 net.neoforged:neoforge
        // loaderVersion 例如 "47.1.0"（1.20.1）或 "20.6.119-beta"（1.20.6+）
        BOOL isLegacyForgeArtifact = [minecraftVersion isEqualToString:@"1.20.1"];
        if (isLegacyForgeArtifact) {
            // 官方 maven 路径必须包含 /releases/，否则 404
            officialURL = [NSString stringWithFormat:@"https://maven.neoforged.net/releases/net/neoforged/forge/%@/forge-%@-installer.jar", loaderVersion, loaderVersion];
        } else {
            officialURL = [NSString stringWithFormat:@"https://maven.neoforged.net/releases/net/neoforged/neoforge/%@/neoforge-%@-installer.jar", loaderVersion, loaderVersion];
        }
    }

    if (!officialURL) return nil;
    return [[PLMirrorCenter preferredURLForOriginalURL:[NSURL URLWithString:officialURL]
                                          resourceType:PLMirrorResourceTypeModLoader] absoluteString];
}

+ (NSInteger)javaMajorVersionForMC:(NSString *)mcVersion {
    NSArray *parts = [mcVersion componentsSeparatedByString:@"."];
    if (parts.count < 2) return 8;
    // 年份制（"26.3"）此前误把 parts[1]=3 当 1.x minor → Java 8
    NSInteger yearMajor = [parts[0] integerValue];
    if (yearMajor >= 26) return 25;
    if (yearMajor != 1) return 17;
    NSInteger major = [parts[1] integerValue];
    if (major >= 21) return 21;       // 1.21+
    if (major >= 20 && parts.count >= 3 && [parts[2] integerValue] >= 5) return 21; // 1.20.5+
    if (major >= 18) return 17;       // 1.18+
    if (major >= 17) return 17;       // 1.17（项目未捆绑 Java 16，Java 17 可向后兼容运行 1.17）
    return 8;                          // 1.16.5 及以下
}

+ (void)writePlaceholderVersionJSONForVersionId:(NSString *)versionId
                               minecraftVersion:(NSString *)minecraftVersion
                                         loader:(NSString *)loader
                                 loaderVersion:(NSString *)loaderVersion
                                          error:(NSError *)error {
    // 占位 JSON：mainClass 指向不存在的类，启动时显式报错
    // 避免 Forge/NeoForge 直装失败后误装作 vanilla MC 让用户以为 mods 生效
    NSInteger javaMajor = [self javaMajorVersionForMC:minecraftVersion];
    NSString *comment = error.localizedDescription.length > 0
        ? [NSString stringWithFormat:localize(@"i18n_str_557", nil), loader, loaderVersion, error.localizedDescription]
        : [NSString stringWithFormat:localize(@"i18n_str_555", nil), loader, loaderVersion];
    NSDictionary *placeholderJSON = @{
        @"_comment_": comment,
        @"id": versionId ?: @"",
        @"inheritsFrom": minecraftVersion ?: @"",
        @"type": @"release",
        @"mainClass": @"net.angelaura.installer.MissingLoader",
        @"javaVersion": @{@"component": @"java-runtime", @"majorVersion": @(javaMajor)}
    };
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:placeholderJSON options:NSJSONWritingPrettyPrinted error:nil];
    if (!jsonData) return;

    // 占位 JSON 写入 POJAV_GAME_DIR/versions/{versionId}/{versionId}.json
    // 原因：Java 端固定从 POJAV_GAME_DIR/versions 加载版本 JSON
    NSString *versionDir = [NSString stringWithFormat:@"%s/versions/%@", getenv("POJAV_GAME_DIR"), versionId];
    [NSFileManager.defaultManager createDirectoryAtPath:versionDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *versionJsonPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", versionId]];
    [jsonData writeToFile:versionJsonPath options:NSDataWritingAtomic error:nil];
    NSLog(@"[ModpackUtils] Placeholder version JSON written: %@", versionJsonPath);
}

@end
