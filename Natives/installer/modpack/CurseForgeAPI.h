#import <Foundation/Foundation.h>
#import "ModpackAPI.h"
#import "ModVersion.h"

NS_ASSUME_NONNULL_BEGIN

// NSError userInfo keys for diagnostic information (CurseForge API)
extern NSString *const CurseForgeResponseContentTypeKey;
extern NSString *const CurseForgeResponseSnippetKey;

/// CurseForge API 实现，支持模组、资源包、光影、数据包、整合包等
@interface CurseForgeAPI : ModpackAPI

+ (instancetype)sharedInstance;

/// 判断 CurseForge API Key 是否已配置（运行时偏好 + 编译时宏 + Info.plist 三层 fallback）
/// 用于 UI 门控判断，与实际请求时的 apiKey getter 保持一致
+ (BOOL)isAPIKeyConfigured;

// ★ [MODPACK-FIX] CurseForge 源可用性（UI 门控用）。key 仅官方直连需要；
//   未配 key 时 baseURL 强制落 MCIM 镜像（免 key，实测 200），源对所有人可用。
//   「切源前先查 key」的门控必须用本方法，而不是 isAPIKeyConfigured —— 否则
//   无 key 构建（= 所有 CI/sideload 构建）在 CurseForge 源上一律被挡成报错死路。
+ (BOOL)isSourceAvailable;

// ========== 同步方法（兼容旧代码，注意会阻塞线程） ==========
/// 搜索项目（同步，内部使用 dispatch_group_wait，建议在后台队列调用）
- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters
                     previousPageResult:(nullable NSMutableArray *)previousPageResult;

/// 加载项目详情（同步，会填充 item 的版本信息）
- (void)loadDetailsOfMod:(NSMutableDictionary *)item;

// ========== 异步方法（推荐，不阻塞 UI） ==========
/// 异步搜索（推荐），支持 projectType = @"resourcepack" / @"mod" / @"shader" 等
- (void)searchModWithFilters:(NSDictionary *)filters
                  completion:(void (^)(NSArray * _Nullable results, NSError * _Nullable error))completion;

/// 异步获取某个项目的所有版本
- (void)getVersionsForModWithID:(NSString *)modID
                     completion:(void (^)(NSArray<ModVersion *> * _Nullable versions, NSError * _Nullable error))completion;

// ========== 异步详情加载 ==========
/// 异步加载项目详情（不阻塞调用线程）
- (void)loadDetailsOfMod:(NSMutableDictionary *)item
              completion:(void (^)(NSError * _Nullable error))completion;

#pragma mark - Server Packs（CurseForge 服务端整合包）

/// 异步搜索服务器整合包：搜索 classId=4471（modpack）项目，作为服务器整合包展示
/// @param filters 搜索过滤条件（query/limit/offset/mcVersion 等）
/// @param completion 完成回调，返回字典数组（含 apiSource=2, projectType=modpack, serverID 字段）
- (void)searchServersWithFilters:(NSDictionary *)filters
                      completion:(void (^)(NSArray * _Nullable results, NSError * _Nullable error))completion;

/// 异步获取指定 modpack 项目的服务端整合包文件列表（isServerPack=true 的文件）
/// @param modpackID CurseForge project id
/// @param completion 完成回调，返回 server pack 文件字典数组
- (void)getServerPackFilesForModpack:(NSString *)modpackID
                          completion:(void (^)(NSArray * _Nullable files, NSError * _Nullable error))completion;

// ========== 下载工具方法 ==========
/// 获取文件的直接下载链接（CurseForge 需要二次请求）
- (NSString *)downloadURLForFile:(NSDictionary *)file;

/// 检查文件是否匹配项目类型（如资源包只允许 zip）
- (BOOL)file:(NSDictionary *)file matchesProjectType:(NSString *)projectType;

/// 获取项目类型对应的推荐文件后缀（jar/zip）
- (NSArray<NSString *> *)preferredFileExtensionsForProjectType:(NSString *)projectType;

// ========== 指纹反查 ==========
/// 通过 MurmurHash2 文件指纹反查 CurseForge 项目（单个）
/// @param fingerprint CurseForge MurmurHash2 指纹（对文件过滤空白字节后计算，见 CurseForgeMurmurHash）
- (nullable NSMutableDictionary *)projectForFileHash:(NSNumber *)fingerprint projectType:(NSString *)projectType;

/// 批量指纹反查（用于批量更新检查）
- (NSArray<NSMutableDictionary *> *)fileFingerprints:(NSArray<NSNumber *> *)fingerprints;

// Task 5.10：在线整合包下载已统一走 ModpackImportService 导入流程，
// submitDownloadTasksFromPackage:toPath: 双轨实现已删除。

@end

NS_ASSUME_NONNULL_END