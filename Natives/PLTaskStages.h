#import "utils.h"
#import <Foundation/Foundation.h>
#import "PLTaskStage.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * 统一阶段定义常量（redesign-download-ui Phase 1）。
 *
 * 收敛原硬编码在 DownloadViewController 4 处的安装阶段列表，供业务方（注册/上报阶段）
 * 与 UI（渲染阶段标题/图标）共用。阶段组成：
 * - 原版 6 步：获取版本清单→下载版本JSON→下载客户端→下载库文件→下载资源文件→验证完整性
 * - +Fabric/Quilt 追加 3 步：获取加载器 profile→下载加载器库→写入版本 JSON
 * - +Forge/NeoForge 追加 3 步：下载安装器→解析依赖→安装加载器
 * - 整合包 6 步：解析整合包→解压文件→下载依赖文件→安装加载器→下载游戏文件→完成配置
 * - 单文件下载（Mod/Shader/资源包/数据包等）1 步：下载文件
 *
 * 标题 key 均为纯头文件 static 常量（各编译单元持有独立副本，比较请用 isEqualToString:）；
 * PLTaskStage.title 存储 key 本身，UI 层负责 NSLocalizedString 渲染
 * （strings 条目于 Phase 7 全语言补齐）。
 * 图标名均为 SF Symbols（iOS 14 / SF Symbols 2 可用，与项目最低系统支持一致）。
 */

#pragma mark - 原版安装 6 步

/// 获取版本清单
static NSString * const PLTaskStageTitleFetchVersionManifest = @"taskStage.title.fetchVersionManifest";
/// 下载版本 JSON
static NSString * const PLTaskStageTitleDownloadVersionJSON = @"taskStage.title.downloadVersionJSON";
/// 下载客户端
static NSString * const PLTaskStageTitleDownloadClient = @"taskStage.title.downloadClient";
/// 下载库文件
static NSString * const PLTaskStageTitleDownloadLibraries = @"taskStage.title.downloadLibraries";
/// 下载资源文件
static NSString * const PLTaskStageTitleDownloadAssets = @"taskStage.title.downloadAssets";
/// 验证完整性
static NSString * const PLTaskStageTitleVerifyIntegrity = @"taskStage.title.verifyIntegrity";

#pragma mark - Fabric/Quilt 追加 3 步

/// 获取加载器 profile
static NSString * const PLTaskStageTitleFetchLoaderProfile = @"taskStage.title.fetchLoaderProfile";
/// 下载加载器库
static NSString * const PLTaskStageTitleDownloadLoaderLibraries = @"taskStage.title.downloadLoaderLibraries";
/// 写入版本 JSON
static NSString * const PLTaskStageTitleWriteVersionJSON = @"taskStage.title.writeVersionJSON";

#pragma mark - Forge/NeoForge 追加 3 步

/// 下载安装器
static NSString * const PLTaskStageTitleDownloadInstaller = @"taskStage.title.downloadInstaller";
/// 解析依赖
static NSString * const PLTaskStageTitleResolveDependencies = @"taskStage.title.resolveDependencies";
/// 安装加载器（Forge/NeoForge 与整合包导入共用）
static NSString * const PLTaskStageTitleInstallLoader = @"taskStage.title.installLoader";

#pragma mark - 整合包导入 6 步

/// 解析整合包
static NSString * const PLTaskStageTitleParseModpack = @"taskStage.title.parseModpack";
/// 解压文件
static NSString * const PLTaskStageTitleExtractFiles = @"taskStage.title.extractFiles";
/// 下载依赖文件
static NSString * const PLTaskStageTitleDownloadDependencies = @"taskStage.title.downloadDependencies";
/// 下载游戏文件
static NSString * const PLTaskStageTitleDownloadGameFiles = @"taskStage.title.downloadGameFiles";
/// 完成配置
static NSString * const PLTaskStageTitleFinalizeConfig = @"taskStage.title.finalizeConfig";

#pragma mark - 单文件下载 1 步

/// 下载文件（Mod/Shader/资源包/数据包/JRE 等单文件任务）
static NSString * const PLTaskStageTitleDownloadFile = @"taskStage.title.downloadFile";

#pragma mark - 阶段组合便捷函数

/// 原版安装 6 步：获取版本清单→下载版本JSON→下载客户端→下载库文件→下载资源文件→验证完整性
NS_INLINE NSArray<PLTaskStage *> *PLTaskStagesVanilla(void) {
    return @[
        [PLTaskStage stageWithTitle:PLTaskStageTitleFetchVersionManifest iconName:@"list.bullet"],
        [PLTaskStage stageWithTitle:PLTaskStageTitleDownloadVersionJSON iconName:@"doc.text"],
        [PLTaskStage stageWithTitle:PLTaskStageTitleDownloadClient iconName:@"arrow.down.circle"],
        [PLTaskStage stageWithTitle:PLTaskStageTitleDownloadLibraries iconName:@"shippingbox"],
        [PLTaskStage stageWithTitle:PLTaskStageTitleDownloadAssets iconName:@"paintpalette"],
        [PLTaskStage stageWithTitle:PLTaskStageTitleVerifyIntegrity iconName:@"checkmark.seal"],
    ];
}

/// Fabric/Quilt 安装追加 3 步：获取加载器 profile→下载加载器库→写入版本 JSON
NS_INLINE NSArray<PLTaskStage *> *PLTaskStagesFabricExtra(void) {
    return @[
        [PLTaskStage stageWithTitle:PLTaskStageTitleFetchLoaderProfile iconName:@"link"],
        [PLTaskStage stageWithTitle:PLTaskStageTitleDownloadLoaderLibraries iconName:@"shippingbox.fill"],
        [PLTaskStage stageWithTitle:PLTaskStageTitleWriteVersionJSON iconName:@"doc.badge.plus"],
    ];
}

/// Forge/NeoForge 安装追加 3 步：下载安装器→解析依赖→安装加载器
NS_INLINE NSArray<PLTaskStage *> *PLTaskStagesForgeExtra(void) {
    return @[
        [PLTaskStage stageWithTitle:PLTaskStageTitleDownloadInstaller iconName:@"arrow.down.doc"],
        [PLTaskStage stageWithTitle:PLTaskStageTitleResolveDependencies iconName:@"text.magnifyingglass"],
        [PLTaskStage stageWithTitle:PLTaskStageTitleInstallLoader iconName:@"wrench.and.screwdriver"],
    ];
}

/// 原版 + Fabric/Quilt 安装（原版 6 步 + 加载器 3 步，共 9 步）
NS_INLINE NSArray<PLTaskStage *> *PLTaskStagesVanillaWithFabric(void) {
    NSMutableArray *stages = [PLTaskStagesVanilla() mutableCopy];
    [stages addObjectsFromArray:PLTaskStagesFabricExtra()];
    return [stages copy];
}

/// 原版 + Forge/NeoForge 安装（原版 6 步 + 安装器 3 步，共 9 步）
NS_INLINE NSArray<PLTaskStage *> *PLTaskStagesVanillaWithForge(void) {
    NSMutableArray *stages = [PLTaskStagesVanilla() mutableCopy];
    [stages addObjectsFromArray:PLTaskStagesForgeExtra()];
    return [stages copy];
}

/// 整合包导入 6 步：解析整合包→解压文件→下载依赖文件→安装加载器→下载游戏文件→完成配置
NS_INLINE NSArray<PLTaskStage *> *PLTaskStagesModpack(void) {
    return @[
        [PLTaskStage stageWithTitle:PLTaskStageTitleParseModpack iconName:@"doc.text.magnifyingglass"],
        [PLTaskStage stageWithTitle:PLTaskStageTitleExtractFiles iconName:@"archivebox"],
        [PLTaskStage stageWithTitle:PLTaskStageTitleDownloadDependencies iconName:@"square.stack.3d.up"],
        [PLTaskStage stageWithTitle:PLTaskStageTitleInstallLoader iconName:@"wrench.and.screwdriver"],
        [PLTaskStage stageWithTitle:PLTaskStageTitleDownloadGameFiles iconName:@"gamecontroller"],
        [PLTaskStage stageWithTitle:PLTaskStageTitleFinalizeConfig iconName:@"slider.horizontal.3"],
    ];
}

/// 单文件下载 1 步（Mod/Shader/资源包/数据包/JRE 等）
NS_INLINE NSArray<PLTaskStage *> *PLTaskStagesSingleFile(void) {
    return @[
        [PLTaskStage stageWithTitle:PLTaskStageTitleDownloadFile iconName:@"arrow.down.circle"],
    ];
}

/// 世界下载 2 步：下载压缩包→解压并验证 level.dat
NS_INLINE NSArray<PLTaskStage *> *PLTaskStagesWorld(void) {
    return @[
        [PLTaskStage stageWithTitle:PLTaskStageTitleDownloadFile iconName:@"arrow.down.circle"],
        [PLTaskStage stageWithTitle:PLTaskStageTitleExtractFiles iconName:@"archivebox"],
    ];
}

#pragma mark - 阶段标题渲染（UI 层共用，redesign-download-ui Phase 2）

/// 渲染阶段标题为用户可见文案：PLTaskStage.title 存储本地化 key，
/// 优先 NSLocalizedString 查表（Phase 7 补全各语言 strings 后自动生效）；
/// strings 暂无条目时回退到代码内中文默认值，避免过渡期直接显示裸 key。
/// 供统一进度页（PLTaskProgressViewController）与下载中心卡片（DownloadTasksViewController）共用。
NS_INLINE NSString *PLTaskStageTitleDisplay(NSString *titleKey) {
    if (titleKey.length == 0) return @"";
    NSString *value = NSLocalizedString(titleKey, @"");
    if (![value isEqualToString:titleKey]) return value;

    // 过渡期中文兜底（与上方阶段常量一一对应；strings 补全后不再走到这里）
    static NSDictionary *fallbackMap = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fallbackMap = @{
            PLTaskStageTitleFetchVersionManifest: localize(@"i18n_str_1240", nil),
            PLTaskStageTitleDownloadVersionJSON: localize(@"i18n_str_1241", nil),
            PLTaskStageTitleDownloadClient: localize(@"i18n_str_1242", nil),
            PLTaskStageTitleDownloadLibraries: localize(@"i18n_str_1243", nil),
            PLTaskStageTitleDownloadAssets: localize(@"i18n_str_1244", nil),
            PLTaskStageTitleVerifyIntegrity: localize(@"i18n_str_1245", nil),
            PLTaskStageTitleFetchLoaderProfile: localize(@"i18n_str_1246", nil),
            PLTaskStageTitleDownloadLoaderLibraries: localize(@"i18n_str_1247", nil),
            PLTaskStageTitleWriteVersionJSON: localize(@"i18n_str_1248", nil),
            PLTaskStageTitleDownloadInstaller: localize(@"i18n_str_1249", nil),
            PLTaskStageTitleResolveDependencies: localize(@"i18n_str_1250", nil),
            PLTaskStageTitleInstallLoader: localize(@"i18n_str_1251", nil),
            PLTaskStageTitleParseModpack: localize(@"i18n_str_1252", nil),
            PLTaskStageTitleExtractFiles: localize(@"i18n_str_1253", nil),
            PLTaskStageTitleDownloadDependencies: localize(@"i18n_str_1254", nil),
            PLTaskStageTitleDownloadGameFiles: localize(@"i18n_str_1255", nil),
            PLTaskStageTitleFinalizeConfig: localize(@"i18n_str_1256", nil),
            PLTaskStageTitleDownloadFile: localize(@"i18n_str_1257", nil),
        };
    });
    return fallbackMap[titleKey] ?: titleKey;
}

NS_ASSUME_NONNULL_END
