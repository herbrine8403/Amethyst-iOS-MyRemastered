//
//  WorldItem.h
//  Amethyst
//
//  世界存档数据模型，参照 ShaderItem，新增 worldName、levelDatPath 等世界特有属性
//  本地扫描 saves/ 目录下的子目录（每个含 level.dat 的子目录是一个世界）
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WorldItem : NSObject

// --- 本地世界属性 ---
// 世界目录名（saves/ 下的子目录名）
@property (nonatomic, copy, nullable) NSString *worldName;
// 世界目录完整路径（saves/<worldName>）
@property (nonatomic, copy, nullable) NSString *filePath;
// level.dat 文件路径
@property (nonatomic, copy, nullable) NSString *levelDatPath;
// level.dat 最后修改时间（用于显示"上次游玩"）
@property (nonatomic, copy, nullable) NSString *lastPlayed;
// 世界大小（字节，递归计算目录大小）
@property (nonatomic, strong, nullable) NSNumber *worldSize;

// --- 在线世界属性（用于在线下载） ---
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
@property (nonatomic, copy, nullable) NSString *worldDescription;
@property (nonatomic, copy, nullable) NSString *iconURL;
@property (nonatomic, strong, nullable) UIImage *icon;
@property (nonatomic, copy, nullable) NSString *fileSHA1;
@property (nonatomic, copy, nullable) NSString *version;
@property (nonatomic, copy, nullable) NSString *gameVersion;
@property (nonatomic, copy, nullable) NSString *homepage;
@property (nonatomic, copy, nullable) NSString *sources;

// --- 初始化方法 ---
// 从本地世界目录路径初始化（path 指向 saves/<worldName>）
- (instancetype)initWithFilePath:(NSString *)path;
// 从在线搜索结果初始化
- (instancetype)initWithOnlineData:(NSDictionary *)data;

// --- 工具方法 ---
- (NSString *)basename;

@end

NS_ASSUME_NONNULL_END
