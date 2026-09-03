//
//  WorldService.h
//  Amethyst
//
//  世界存档管理与下载服务，结构参照 ResourcePackService/DataPackService
//  API 签名统一使用 NSString *profileName
//  扫描 saves/ 目录，下载世界 zip 后做健壮解压（检测顶层目录）
//  使用 defaultSessionConfiguration + NSURLSessionDownloadTask 提升下载效率和速度
//

#import <Foundation/Foundation.h>
#import "WorldItem.h"

NS_ASSUME_NONNULL_BEGIN

// 世界列表回调
typedef void(^WorldListHandler)(NSArray<WorldItem *> *items);
// 下载完成回调（success 表示是否成功，error 为失败原因）
typedef void(^WorldDownloadCompletionHandler)(BOOL success, NSError * _Nullable error);
// 下载进度回调（在主线程执行，UI 更新安全）
typedef void(^WorldDownloadProgressHandler)(NSProgress * _Nullable downloadProgress);

@interface WorldService : NSObject

+ (instancetype)sharedService;

// --- 本地世界管理 ---
// 扫描指定 profile 的 saves 目录，返回每个含 level.dat 的子目录作为一个 WorldItem
- (void)scanWorldsForProfile:(NSString * _Nullable)profileName completion:(WorldListHandler)completion;
// 删除世界目录（递归删除）
- (BOOL)deleteWorld:(WorldItem *)item error:(NSError **)error;

// --- 在线世界下载 ---
// 下载世界 zip 到指定 profile 的 saves 目录，下载完成后自动解压（健壮解压逻辑）
// progress 回调实时上报下载进度（不含解压阶段）
// completion 在主线程回调，success 表示下载并解压是否成功
- (void)downloadWorld:(WorldItem *)item
            toProfile:(NSString * _Nullable)profileName
             progress:(WorldDownloadProgressHandler _Nullable)progress
           completion:(WorldDownloadCompletionHandler _Nullable)completion;

// 从本地文件 URL 导入世界 zip（如 UIDocumentPicker 选择的文件）
// 同样做健壮解压，导入完成后可删除临时 zip
- (void)importWorldFromURL:(NSURL *)sourceURL
                toProfile:(NSString * _Nullable)profileName
                 progress:(WorldDownloadProgressHandler _Nullable)progress
               completion:(WorldDownloadCompletionHandler _Nullable)completion;

// --- 工具方法 ---

/// 获取当前 profile 的 saves 目录，不存在时自动创建
- (nullable NSString *)ensureWorldsFolderForProfile:(NSString * _Nullable)profileName error:(NSError **)error;

/// 查找当前 profile 的 saves 目录（已存在时返回路径，否则返回 nil）
- (nullable NSString *)existingWorldsFolderForProfile:(NSString * _Nullable)profileName;

@end

NS_ASSUME_NONNULL_END
