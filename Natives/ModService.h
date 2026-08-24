//
//  ModService.h
//  AmethystMods
//
//  Created by Copilot on 2025-08-22.
//

#import <Foundation/Foundation.h>
#import "ModItem.h"

NS_ASSUME_NONNULL_BEGIN

typedef void(^ModListHandler)(NSArray<ModItem *> *mods);
typedef void(^ModMetadataHandler)(ModItem *item, NSError * _Nullable error);
typedef void(^ModDownloadHandler)(NSError * _Nullable error); // Added for download completion

@interface ModService : NSObject

@property (nonatomic, assign) BOOL onlineSearchEnabled;

+ (instancetype)sharedService;

// --- Local Mod Management ---
- (void)scanModsForProfile:(NSString * _Nullable)profileName completion:(ModListHandler)completion;
- (void)fetchMetadataForMod:(ModItem *)mod completion:(ModMetadataHandler)completion;
- (BOOL)toggleEnableForMod:(ModItem *)mod error:(NSError **)error;
- (BOOL)deleteMod:(ModItem *)mod error:(NSError **)error;

// --- Online Mod Downloading ---
- (void)downloadMod:(ModItem *)mod toProfile:(NSString * _Nullable)profileName completion:(ModDownloadHandler)completion;

/// 下载 Mod 并上报进度
- (void)downloadMod:(ModItem *)mod
          toProfile:(NSString * _Nullable)profileName
            progress:(void (^)(NSProgress *downloadProgress))progress
          completion:(ModDownloadHandler)completion;

/// 下载 Mod 并启用 SHA1 校验（spec Task 5.1）。
/// expectedSHA1 来自版本模型 primaryFile[@"hashes"][@"sha1"]（Modrinth files[].hashes.sha1 /
/// CurseForge hashes algo=1），传入即启用校验，校验失败由统一下载器按镜像/退避节奏重试；
/// 为 nil 时不做 SHA1 校验，靠 zip EOCD 兜底校验保证完整性。
- (void)downloadMod:(ModItem *)mod
          toProfile:(NSString * _Nullable)profileName
       expectedSHA1:(nullable NSString *)expectedSHA1
           progress:(nullable void (^)(NSProgress *downloadProgress))progress
         completion:(ModDownloadHandler)completion;

// --- Utility ---
- (NSString *)iconCachePathForURL:(NSString *)urlString;

/// 获取当前 profile 的 mods 目录，不存在时自动创建
- (nullable NSString *)ensureModsFolderForProfile:(NSString * _Nullable)profileName error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
