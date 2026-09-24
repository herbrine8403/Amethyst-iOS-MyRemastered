#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 镜像资源类型（决定 URL 走哪个镜像体系，以及读取哪个策略偏好键）
typedef NS_ENUM(NSInteger, PLMirrorResourceType) {
    /// 游戏本体 / 库 / 资产文件（Mojang 系分发文件），走 BMCLAPI 镜像
    PLMirrorResourceTypeGameFile = 0,
    /// Modrinth / CurseForge API 查询，走 MCIM 镜像
    PLMirrorResourceTypeAssetSearch = 1,
    /// Mod / 光影 / 资源包文件 CDN 下载，走 MCIM 镜像
    PLMirrorResourceTypeAssetDownload = 2,
    /// 加载器 meta / maven / installer 文件，走 BMCLAPI 镜像
    PLMirrorResourceTypeModLoader = 3,
};

/// 镜像使用策略
typedef NS_ENUM(NSInteger, PLMirrorPolicy) {
    /// 官方优先，镜像 URL 作为回退候选
    PLMirrorPolicyOfficialFirst = 0,
    /// 镜像优先，官方 URL 作为回退候选
    PLMirrorPolicyMirrorFirst = 1,
};

/// BMCLAPI 镜像根地址（https://bmclapi2.bangbang93.com，全工程唯一定义处，供他处引用）
FOUNDATION_EXPORT NSString *const PLMirrorBMCLAPIRootURL;

/// MCIM 镜像根地址（https://mod.mcimirror.top，全工程唯一定义处，供他处引用）
FOUNDATION_EXPORT NSString *const PLMirrorMCIMRootURL;

/// 统一镜像配置中心（纯工具类，无网络请求）
///
/// 收敛全工程的镜像 URL 映射与策略读取，替代散落在
/// MinecraftResourceDownloadTask / MCIMMirror / 各 installer 中的重写逻辑：
///   - GameFile / ModLoader → BMCLAPI（参考 ZalithLauncher 2 REPLACE_MIRROR_HOLDERS + Air 现有行为）
///   - AssetSearch / AssetDownload → MCIM（保持 MCIMMirror.m 现有精确行为）
///
/// 策略偏好键（值 auto / official_first / mirror_first）：
///   - GameFile      → download.fileSource
///   - AssetSearch   → download.assetSearchSource
///   - AssetDownload → download.assetDownloadSource
///   - ModLoader     → download.modLoaderSource
/// auto（默认）对齐 ZL2 MirrorSourceType.AUTO：大陆环境（时区 Asia/Shanghai 等）镜像优先，
/// 其余官方优先；未设置时回退旧键 general.download_source
/// （official → 官方优先；bmclapi / mcim → 镜像优先），再回退 auto 语义。
///
/// 特殊规则：MirrorFirst 时 GameFile 的资产资源（resources.download.minecraft.net）
/// 仍官方优先，以减轻镜像源压力（参考 ZalithLauncher 2 的设计）。
///
/// 使用方式：
///   NSURL *url = [PLMirrorCenter preferredURLForOriginalURL:originalURL
///                                               resourceType:PLMirrorResourceTypeGameFile];
///   NSArray<NSURL *> *candidates = [PLMirrorCenter candidateURLsForOriginalURL:originalURL
///                                                                   resourceType:PLMirrorResourceTypeGameFile];
@interface PLMirrorCenter : NSObject

/// 按当前策略返回候选 URL 数组（含原始 URL 与镜像 URL，去重，按尝试顺序排序）
/// 无法识别的主机原样返回仅含原始 URL 的数组
/// @param originalURL 原始（官方）URL
/// @param type 资源类型（决定镜像体系与策略键）
+ (NSArray<NSURL *> *)candidateURLsForOriginalURL:(NSURL *)originalURL
                                     resourceType:(PLMirrorResourceType)type;

/// 便捷方法：取候选数组的第一个（当前策略下的首选 URL）
/// @param url 原始（官方）URL
/// @param type 资源类型（决定镜像体系与策略键）
+ (NSURL *)preferredURLForOriginalURL:(NSURL *)url
                         resourceType:(PLMirrorResourceType)type;

/// Modrinth API base URL（等价 MCIMMirror 同名能力：按 AssetSearch 策略返回官方或 MCIM 镜像基址）
+ (NSString *)modrinthAPIBaseURL;

/// CurseForge API base URL（等价 MCIMMirror 同名能力：按 AssetSearch 策略返回官方或 MCIM 镜像基址）
+ (NSString *)curseForgeAPIBaseURL;

/// 读取指定资源类型当前生效的镜像策略（含旧键回退逻辑）
+ (PLMirrorPolicy)policyForType:(PLMirrorResourceType)type;

@end

NS_ASSUME_NONNULL_END
