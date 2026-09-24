#import "PLMirrorCenter.h"
#import "LauncherPreferences.h"

#pragma mark - 公开常量（全工程唯一定义处）

/// BMCLAPI 镜像根地址
NSString *const PLMirrorBMCLAPIRootURL = @"https://bmclapi2.bangbang93.com";

/// MCIM 镜像根地址（参考 ZalithLauncher 2 MCIMMirror.kt）
NSString *const PLMirrorMCIMRootURL = @"https://mod.mcimirror.top";

#pragma mark - 偏好键

/// 新版分资源类型策略键（值 official_first / mirror_first）
static NSString *const kPrefFileSource = @"download.fileSource";
static NSString *const kPrefAssetSearchSource = @"download.assetSearchSource";
static NSString *const kPrefAssetDownloadSource = @"download.assetDownloadSource";
static NSString *const kPrefModLoaderSource = @"download.modLoaderSource";

/// 旧版全局下载源键（official / bmclapi / mcim），为 Phase 4 设置项迁移预留回退
static NSString *const kPrefLegacyDownloadSource = @"general.download_source";

@implementation PLMirrorCenter

#pragma mark - 映射表

/// BMCLAPI 官方前缀 → 镜像前缀映射表（顺序敏感：最长前缀优先）
///
/// 参考 ZalithLauncher 2 BMCLAPI.kt 的 REPLACE_MIRROR_HOLDERS 与 Air 现有
/// MinecraftResourceDownloadTask.m replaceURLWithDownloadSource:forceSource: 的已验证行为。
+ (NSArray<NSArray<NSString *> *> *)bmclapiPrefixPairs {
    static NSArray<NSArray<NSString *> *> *pairs = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pairs = @[
            // Mojang 版本清单 / 版本 JSON（piston-meta / piston-data 为 1.19+ 新域名）
            @[@"https://launchermeta.mojang.com", PLMirrorBMCLAPIRootURL],
            @[@"https://piston-meta.mojang.com", PLMirrorBMCLAPIRootURL],
            @[@"https://piston-data.mojang.com", PLMirrorBMCLAPIRootURL],
            @[@"https://launcher.mojang.com", PLMirrorBMCLAPIRootURL],
            // Mojang 库文件 → /maven（Air 现有已验证行为）
            @[@"https://libraries.minecraft.net", [PLMirrorBMCLAPIRootURL stringByAppendingString:@"/maven"]],
            // Mojang 资产资源 → /assets（数量巨大，MirrorFirst 时仍强制官方优先以减轻镜像压力）
            @[@"http://resources.download.minecraft.net", [PLMirrorBMCLAPIRootURL stringByAppendingString:@"/assets"]],
            @[@"https://resources.download.minecraft.net", [PLMirrorBMCLAPIRootURL stringByAppendingString:@"/assets"]],
            // Forge：Air 现有行为整体替换到根，官方 /maven 路径自然映射到根下 /maven
            @[@"https://files.minecraftforge.net", PLMirrorBMCLAPIRootURL],
            @[@"http://files.minecraftforge.net", PLMirrorBMCLAPIRootURL],
            @[@"https://maven.minecraftforge.net", [PLMirrorBMCLAPIRootURL stringByAppendingString:@"/maven"]],
            // NeoForge：官方 artifact 路径含 /releases 而 BMCLAPI 不含，
            // 必须先吸收 /releases 段（参考 ZL2 / HMCL），故此条目须列在通用条目之前
            @[@"https://maven.neoforged.net/releases", [PLMirrorBMCLAPIRootURL stringByAppendingString:@"/maven"]],
            @[@"https://maven.neoforged.net", [PLMirrorBMCLAPIRootURL stringByAppendingString:@"/maven"]],
            // Fabric：meta → /fabric-meta（参考 ZL2），maven → /maven
            @[@"https://meta.fabricmc.net", [PLMirrorBMCLAPIRootURL stringByAppendingString:@"/fabric-meta"]],
            @[@"https://maven.fabricmc.net", [PLMirrorBMCLAPIRootURL stringByAppendingString:@"/maven"]],
            // Quilt：meta → /quilt-meta，maven → /maven（BMCLAPI 标准映射）
            @[@"https://meta.quiltmc.org", [PLMirrorBMCLAPIRootURL stringByAppendingString:@"/quilt-meta"]],
            @[@"https://maven.quiltmc.org", [PLMirrorBMCLAPIRootURL stringByAppendingString:@"/maven"]],
            // Maven Central：Forge / NeoForge 安装器自身依赖（ASM、Guava、jopt-simple 等）
            // 直接来自中央仓库，大陆直连 repo1.maven.org 常不可达，故映射到腾讯云 maven 镜像
            // （参考 ZL2 BMCLAPI.kt REPLACE_MIRROR_HOLDERS 中 repo1/repo.maven.apache.org 两条）
            @[@"https://repo1.maven.org/maven2", @"https://mirrors.cloud.tencent.com/nexus/repository/maven-public"],
            @[@"https://repo.maven.apache.org/maven2", @"https://mirrors.cloud.tencent.com/nexus/repository/maven-public"],
        ];
    });
    return pairs;
}

/// MCIM 官方前缀 → 镜像前缀映射表
///
/// 保持 Air MCIMMirror.m 现有精确行为：API 域名加平台前缀（/modrinth、/curseforge），
/// CDN 域名做简单主机替换到 MCIM 根（无平台前缀，参考 ZL2 MCIMMirror.kt）。
+ (NSArray<NSArray<NSString *> *> *)mcimPrefixPairs {
    static NSArray<NSArray<NSString *> *> *pairs = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pairs = @[
            // Modrinth API：https://api.modrinth.com/v2/... → https://mod.mcimirror.top/modrinth/v2/...
            @[@"https://api.modrinth.com", [PLMirrorMCIMRootURL stringByAppendingString:@"/modrinth"]],
            // CurseForge API：https://api.curseforge.com/v1/... → https://mod.mcimirror.top/curseforge/v1/...
            @[@"https://api.curseforge.com", [PLMirrorMCIMRootURL stringByAppendingString:@"/curseforge"]],
            // Modrinth CDN：简单主机替换，不加平台前缀（与 MCIMMirror.m 现有行为一致）
            @[@"https://cdn.modrinth.com", PLMirrorMCIMRootURL],
            // CurseForge CDN：简单主机替换，不加平台前缀（与 MCIMMirror.m 中 edge / media 行为一致）
            @[@"https://edge.forgecdn.net", PLMirrorMCIMRootURL],
            @[@"https://mediafilez.forgecdn.net", PLMirrorMCIMRootURL],
            @[@"https://media.forgecdn.net", PLMirrorMCIMRootURL],
        ];
    });
    return pairs;
}

/// 在映射表中查找并替换前缀，返回镜像 URL 字符串；无匹配返回 nil
+ (nullable NSString *)mirrorURLStringForOriginalURLString:(NSString *)urlString
                                               prefixPairs:(NSArray<NSArray<NSString *> *> *)pairs {
    for (NSArray<NSString *> *pair in pairs) {
        NSString *origin = pair.firstObject;
        NSString *mirror = pair.lastObject;
        // 要求前缀后紧跟 "/"，避免误匹配同前缀的其它主机名
        if ([urlString hasPrefix:[origin stringByAppendingString:@"/"]]) {
            return [mirror stringByAppendingString:[urlString substringFromIndex:origin.length]];
        }
    }
    return nil;
}

#pragma mark - 中国大陆环境判定

/// 是否处于中国大陆环境（参考 ZalithLauncher 2 LocalUtils.isChinaMainland）
///
/// ZL2 以系统时区判定：时区 ID 为 Asia/Shanghai、Asia/Chongqing（历史遗留）、
/// Asia/Urumqi 之一即视为大陆（其余情况返回 NO）。用于"自动"档下决定是否镜像优先，
/// 对应 ZL2 resolveMirrorPriority(source = AUTO, mainland = true) → MIRROR_FIRST。
BOOL PLMirrorIsChinaMainland(void) {
    NSString *tzName = [NSTimeZone localTimeZone].name ?: @"";
    return [tzName isEqualToString:@"Asia/Shanghai"] ||
           [tzName isEqualToString:@"Asia/Chongqing"] ||
           [tzName isEqualToString:@"Asia/Urumqi"];
}

#pragma mark - 公开 API

+ (NSArray<NSURL *> *)candidateURLsForOriginalURL:(NSURL *)originalURL
                                     resourceType:(PLMirrorResourceType)type {
    if (!originalURL) return @[];

    NSString *urlString = originalURL.absoluteString;

    // 资产资源文件数量巨大：即使镜像优先也保持官方在前，减轻镜像源压力（参考 ZL2）
    BOOL isAssetsFile = ([urlString hasPrefix:@"http://resources.download.minecraft.net/"] ||
                         [urlString hasPrefix:@"https://resources.download.minecraft.net/"]);

    NSString *mirrorURLString = nil;
    switch (type) {
        case PLMirrorResourceTypeGameFile:
        case PLMirrorResourceTypeModLoader:
            mirrorURLString = [self mirrorURLStringForOriginalURLString:urlString
                                                           prefixPairs:[self bmclapiPrefixPairs]];
            break;
        case PLMirrorResourceTypeAssetSearch:
        case PLMirrorResourceTypeAssetDownload:
            mirrorURLString = [self mirrorURLStringForOriginalURLString:urlString
                                                           prefixPairs:[self mcimPrefixPairs]];
            break;
    }

    // 无法识别的主机（或已是镜像 URL / 重写后与原始相同）：原样返回仅含原始 URL 的数组
    if (mirrorURLString.length == 0 || [mirrorURLString isEqualToString:urlString]) {
        return @[originalURL];
    }

    NSURL *mirrorURL = [NSURL URLWithString:mirrorURLString];
    if (!mirrorURL) return @[originalURL];

    PLMirrorPolicy policy = [self policyForType:type];
    if (isAssetsFile) {
        policy = PLMirrorPolicyOfficialFirst;
    }

    if (policy == PLMirrorPolicyMirrorFirst) {
        return @[mirrorURL, originalURL];
    }
    return @[originalURL, mirrorURL];
}

+ (NSURL *)preferredURLForOriginalURL:(NSURL *)url
                         resourceType:(PLMirrorResourceType)type {
    return [self candidateURLsForOriginalURL:url resourceType:type].firstObject ?: url;
}

+ (NSString *)modrinthAPIBaseURL {
    if ([self policyForType:PLMirrorResourceTypeAssetSearch] == PLMirrorPolicyMirrorFirst) {
        return [NSString stringWithFormat:@"%@/modrinth/v2", PLMirrorMCIMRootURL];
    }
    return @"https://api.modrinth.com/v2";
}

+ (NSString *)curseForgeAPIBaseURL {
    if ([self policyForType:PLMirrorResourceTypeAssetSearch] == PLMirrorPolicyMirrorFirst) {
        return [NSString stringWithFormat:@"%@/curseforge/v1", PLMirrorMCIMRootURL];
    }
    return @"https://api.curseforge.com/v1";
}

+ (PLMirrorPolicy)policyForType:(PLMirrorResourceType)type {
    // 优先读取新版分资源类型策略键（值 auto / official_first / mirror_first）
    NSString *key = nil;
    switch (type) {
        case PLMirrorResourceTypeGameFile:
            key = kPrefFileSource;
            break;
        case PLMirrorResourceTypeAssetSearch:
            key = kPrefAssetSearchSource;
            break;
        case PLMirrorResourceTypeAssetDownload:
            key = kPrefAssetDownloadSource;
            break;
        case PLMirrorResourceTypeModLoader:
            key = kPrefModLoaderSource;
            break;
    }
    NSString *value = getPrefObject(key);
    if ([value isKindOfClass:[NSString class]]) {
        if ([value isEqualToString:@"official_first"]) return PLMirrorPolicyOfficialFirst;
        if ([value isEqualToString:@"mirror_first"]) return PLMirrorPolicyMirrorFirst;
        if ([value isEqualToString:@"auto"]) {
            // 自动档：大陆环境镜像优先，其余官方优先
            // （对齐 ZL2 resolveMirrorPriority(source = AUTO, mainland)）
            return PLMirrorIsChinaMainland() ? PLMirrorPolicyMirrorFirst : PLMirrorPolicyOfficialFirst;
        }
    }

    // 回退旧键 general.download_source：official → 官方优先，bmclapi / mcim → 镜像优先
    NSString *legacy = getPrefObject(kPrefLegacyDownloadSource);
    if ([legacy isKindOfClass:[NSString class]]) {
        if ([legacy isEqualToString:@"official"]) return PLMirrorPolicyOfficialFirst;
        if ([legacy isEqualToString:@"bmclapi"] || [legacy isEqualToString:@"mcim"]) {
            return PLMirrorPolicyMirrorFirst;
        }
    }

    // 默认按大陆检测（对齐 ZL2 默认 AUTO 档）：大陆镜像优先，其余官方优先
    return PLMirrorIsChinaMainland() ? PLMirrorPolicyMirrorFirst : PLMirrorPolicyOfficialFirst;
}

@end
