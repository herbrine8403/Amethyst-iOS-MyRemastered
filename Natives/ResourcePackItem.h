//
//  ResourcePackItem.h
//  Amethyst
//
//  资源包数据模型，参照 ShaderItem，新增 packFormat（从 pack.mcmeta 解析）
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ResourcePackItem : NSObject

// --- 本地资源包属性 ---
@property (nonatomic, copy, nullable) NSString *fileName;
@property (nonatomic, copy, nullable) NSString *filePath;
@property (nonatomic, assign) BOOL disabled;

// --- 在线资源包属性 ---
@property (nonatomic, copy, nullable) NSString *onlineID;
/// 在线 API 来源：1=Modrinth，2=CurseForge。
@property (nonatomic, assign) NSInteger apiSource;
@property (nonatomic, copy, nullable) NSString *author;
@property (nonatomic, strong, nullable) NSNumber *downloads;
@property (nonatomic, strong, nullable) NSNumber *likes;
@property (nonatomic, copy, nullable) NSString *lastUpdated;
@property (nonatomic, strong, nullable) NSArray<NSString *> *categories;
@property (nonatomic, copy, nullable) NSString *selectedVersionDownloadURL;

// --- 通用/元数据属性 ---
@property (nonatomic, copy, nullable) NSString *displayName;
@property (nonatomic, copy, nullable) NSString *resourcePackDescription;
@property (nonatomic, copy, nullable) NSString *iconURL;
@property (nonatomic, strong, nullable) UIImage *icon;
@property (nonatomic, copy, nullable) NSString *fileSHA1;
@property (nonatomic, copy, nullable) NSString *version;
@property (nonatomic, copy, nullable) NSString *gameVersion;
@property (nonatomic, copy, nullable) NSString *homepage;
@property (nonatomic, copy, nullable) NSString *sources;
// pack.mcmeta 中的 pack_format 字段
@property (nonatomic, strong, nullable) NSNumber *packFormat;

// --- 初始化方法 ---
- (instancetype)initWithFilePath:(NSString *)path;
- (instancetype)initWithOnlineData:(NSDictionary *)data;

// --- 工具方法 ---
- (NSString *)basename;
- (void)refreshDisabledFlag;

@end

NS_ASSUME_NONNULL_END
