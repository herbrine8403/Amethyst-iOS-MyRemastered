//
//  ResourcePackService.h
//  Amethyst
//
//  资源包本地管理与下载服务，结构参照 ShaderService/ModService
//  API 签名统一使用 NSString *profileName（与 ModService 一致）
//  新增 pack.mcmeta 解析（pack_format / description）
//  下载改走 PLDownloadClient 统一下载器（镜像候选 + SHA1 校验 + 增量下载 + 断点续传）
//

#import <Foundation/Foundation.h>
#import "ResourcePackItem.h"

NS_ASSUME_NONNULL_BEGIN

// 资源包列表回调
typedef void(^ResourcePackListHandler)(NSArray<ResourcePackItem *> *items);
// 资源包元数据回调
typedef void(^ResourcePackMetadataHandler)(ResourcePackItem *item, NSError * _Nullable error);
// 下载完成回调（success 表示是否成功）
typedef void(^ResourcePackDownloadCompletionHandler)(BOOL success, NSError * _Nullable error);
// 下载进度回调（在主线程执行，UI 更新安全）
typedef void(^ResourcePackDownloadProgressHandler)(NSProgress * _Nullable downloadProgress);

@interface ResourcePackService : NSObject

@property (nonatomic, assign) BOOL onlineSearchEnabled;

+ (instancetype)sharedService;

// --- 本地资源包管理 ---
// 扫描指定 profile 的 resourcepacks 目录，返回 .zip 和 .zip.disabled 文件列表
- (void)scanResourcePacksForProfile:(NSString * _Nullable)profileName completion:(ResourcePackListHandler)completion;
// 获取资源包元数据（解析 zip 内的 pack.mcmeta，获取 pack_format 和 description）
- (void)fetchMetadataForResourcePack:(ResourcePackItem *)item completion:(ResourcePackMetadataHandler)completion;
// 启用/禁用资源包（加/去 .disabled 后缀）
- (BOOL)toggleEnableForResourcePack:(ResourcePackItem *)item error:(NSError **)error;
// 删除资源包文件
- (BOOL)deleteResourcePack:(ResourcePackItem *)item error:(NSError **)error;

// --- 在线资源包下载 ---
// 下载资源包到指定 profile 的 resourcepacks 目录，支持实时进度回调
- (void)downloadResourcePack:(ResourcePackItem *)item
                   toProfile:(NSString * _Nullable)profileName
                    progress:(ResourcePackDownloadProgressHandler _Nullable)progress
                  completion:(ResourcePackDownloadCompletionHandler _Nullable)completion;

/// 下载资源包并启用 SHA1 校验（spec optimize-download-system Task 5.1）。
/// expectedSHA1 来自版本模型 primaryFile[@"hashes"][@"sha1"]（Modrinth files[].hashes.sha1 /
/// CurseForge hashes algo=1），传入即启用校验，校验失败由统一下载器按镜像/退避节奏重试；
/// 为 nil 时不做 SHA1 校验，靠 zip EOCD 兜底校验保证完整性。
- (void)downloadResourcePack:(ResourcePackItem *)item
                   toProfile:(NSString * _Nullable)profileName
                expectedSHA1:(nullable NSString *)expectedSHA1
                    progress:(ResourcePackDownloadProgressHandler _Nullable)progress
                  completion:(ResourcePackDownloadCompletionHandler _Nullable)completion;

// --- 工具方法 ---
- (NSString *)iconCachePathForURL:(NSString *)urlString;

/// 获取当前 profile 的 resourcepacks 目录，不存在时自动创建
- (nullable NSString *)ensureResourcePacksFolderForProfile:(NSString * _Nullable)profileName error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
