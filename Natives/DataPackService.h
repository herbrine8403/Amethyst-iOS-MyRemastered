//
//  DataPackService.h
//  Amethyst
//
//  数据包本地管理与下载服务，结构参照 ShaderService/ModService
//  API 签名统一使用 NSString *profileName（与 ModService 一致）
//  新增 pack.mcmeta 解析（pack_format / description）
//  新增 worldName 参数支持下载到指定世界的 datapacks 目录（saves/<worldName>/datapacks/）
//  下载改走 PLDownloadClient 统一下载器（镜像候选 + SHA1 校验 + 增量下载 + 断点续传）
//

#import <Foundation/Foundation.h>
#import "DataPackItem.h"

NS_ASSUME_NONNULL_BEGIN

// 数据包列表回调
typedef void(^DataPackListHandler)(NSArray<DataPackItem *> *items);
// 数据包元数据回调
typedef void(^DataPackMetadataHandler)(DataPackItem *item, NSError * _Nullable error);
// 下载完成回调（success 表示是否成功）
typedef void(^DataPackDownloadCompletionHandler)(BOOL success, NSError * _Nullable error);
// 下载进度回调（在主线程执行，UI 更新安全）
typedef void(^DataPackDownloadProgressHandler)(NSProgress * _Nullable downloadProgress);

@interface DataPackService : NSObject

@property (nonatomic, assign) BOOL onlineSearchEnabled;

+ (instancetype)sharedService;

// --- 本地数据包管理 ---
// 扫描指定 profile 的 datapacks 目录，返回 .zip 和 .zip.disabled 文件列表
- (void)scanDataPacksForProfile:(NSString * _Nullable)profileName completion:(DataPackListHandler)completion;
// 获取数据包元数据（解析 zip 内的 pack.mcmeta，获取 pack_format 和 description）
- (void)fetchMetadataForDataPack:(DataPackItem *)item completion:(DataPackMetadataHandler)completion;
// 启用/禁用数据包（加/去 .disabled 后缀）
- (BOOL)toggleEnableForDataPack:(DataPackItem *)item error:(NSError **)error;
// 删除数据包文件
- (BOOL)deleteDataPack:(DataPackItem *)item error:(NSError **)error;

// --- 在线数据包下载 ---
// 下载数据包到指定 profile 的 datapacks 目录（<gameDir>/datapacks/），支持实时进度回调
// 注意：Minecraft 要求数据包放在 <gameDir>/saves/<世界名>/datapacks/，但 iOS 上无法选择世界，
// 因此默认下载到 <gameDir>/datapacks/，需用户手动移动到对应世界目录。
- (void)downloadDataPack:(DataPackItem *)item
               toProfile:(NSString * _Nullable)profileName
                progress:(DataPackDownloadProgressHandler _Nullable)progress
              completion:(DataPackDownloadCompletionHandler _Nullable)completion;

// 下载数据包到指定世界的 datapacks 目录（<gameDir>/saves/<worldName>/datapacks/）
// worldName 为 nil 时回退到 <gameDir>/datapacks/
- (void)downloadDataPack:(DataPackItem *)item
               toProfile:(NSString * _Nullable)profileName
               worldName:(nullable NSString *)worldName
                progress:(DataPackDownloadProgressHandler _Nullable)progress
              completion:(DataPackDownloadCompletionHandler _Nullable)completion;

/// 下载数据包并启用 SHA1 校验（spec optimize-download-system Task 5.1）。
/// expectedSHA1 来自版本模型 primaryFile[@"hashes"][@"sha1"]（Modrinth files[].hashes.sha1 /
/// CurseForge hashes algo=1），传入即启用校验，校验失败由统一下载器按镜像/退避节奏重试；
/// 为 nil 时不做 SHA1 校验，靠 zip EOCD 兜底校验保证完整性。
- (void)downloadDataPack:(DataPackItem *)item
               toProfile:(NSString * _Nullable)profileName
               worldName:(nullable NSString *)worldName
            expectedSHA1:(nullable NSString *)expectedSHA1
                progress:(DataPackDownloadProgressHandler _Nullable)progress
              completion:(DataPackDownloadCompletionHandler _Nullable)completion;

// --- 工具方法 ---
- (NSString *)iconCachePathForURL:(NSString *)urlString;

/// 获取当前 profile 的 datapacks 目录，不存在时自动创建
- (nullable NSString *)ensureDataPacksFolderForProfile:(NSString * _Nullable)profileName error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
