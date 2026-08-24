//
//  ShaderService.h
//  Amethyst
//
//  Service for managing shader packs (local and online)
//

#import <Foundation/Foundation.h>
#import "ShaderItem.h"

NS_ASSUME_NONNULL_BEGIN

typedef void(^ShaderListHandler)(NSArray<ShaderItem *> *shaders);
typedef void(^ShaderMetadataHandler)(ShaderItem *item, NSError * _Nullable error);
typedef void(^ShaderDownloadHandler)(NSError * _Nullable error);

@interface ShaderService : NSObject

@property (nonatomic, assign) BOOL onlineSearchEnabled;

+ (instancetype)sharedService;

// --- Local Shader Management ---
- (void)scanShadersForProfile:(NSString * _Nullable)profileName completion:(ShaderListHandler)completion;
- (void)fetchMetadataForShader:(ShaderItem *)shader completion:(ShaderMetadataHandler)completion;
- (BOOL)toggleEnableForShader:(ShaderItem *)shader error:(NSError **)error;
- (BOOL)deleteShader:(ShaderItem *)shader error:(NSError **)error;

// --- Online Shader Downloading ---
- (void)downloadShader:(ShaderItem *)shader toProfile:(NSString * _Nullable)profileName completion:(ShaderDownloadHandler)completion;

/// 下载光影包并上报进度
- (void)downloadShader:(ShaderItem *)shader
             toProfile:(NSString * _Nullable)profileName
              progress:(void (^)(NSProgress *downloadProgress))progress
            completion:(ShaderDownloadHandler)completion;

/// 下载光影包并启用 SHA1 校验（spec Task 5.1）。
/// expectedSHA1 来自版本模型 primaryFile[@"hashes"][@"sha1"]（Modrinth files[].hashes.sha1），
/// 传入即启用校验，校验失败由统一下载器按镜像/退避节奏重试；
/// 为 nil 时不做 SHA1 校验，靠 zip EOCD 兜底校验保证完整性。
- (void)downloadShader:(ShaderItem *)shader
             toProfile:(NSString * _Nullable)profileName
          expectedSHA1:(nullable NSString *)expectedSHA1
              progress:(nullable void (^)(NSProgress *downloadProgress))progress
            completion:(ShaderDownloadHandler)completion;

// --- Utility ---
- (NSString *)iconCachePathForURL:(NSString *)urlString;

/// 获取当前 profile 的 shaderpacks 目录，不存在时自动创建
- (nullable NSString *)ensureShadersFolderForProfile:(NSString * _Nullable)profileName error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
