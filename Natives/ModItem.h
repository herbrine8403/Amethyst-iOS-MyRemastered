#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ModItem : NSObject

// --- Properties for Local Mods ---
@property (nonatomic, copy, nullable) NSString *fileName;
@property (nonatomic, copy, nullable) NSString *filePath;
@property (nonatomic, assign) BOOL disabled;

// --- Properties for Online Mods ---
@property (nonatomic, copy, nullable) NSString *onlineID;
/// 在线 API 来源：1=Modrinth，2=CurseForge。
@property (nonatomic, assign) NSInteger apiSource;
@property (nonatomic, copy, nullable) NSString *author;
@property (nonatomic, strong, nullable) NSNumber *downloads;
@property (nonatomic, strong, nullable) NSNumber *likes;
@property (nonatomic, copy, nullable) NSString *lastUpdated;
@property (nonatomic, strong, nullable) NSArray<NSString *> *categories;
@property (nonatomic, copy, nullable) NSString *selectedVersionDownloadURL; // For passing download URL to ModService


// --- Common/Metadata Properties ---
@property (nonatomic, copy, nullable) NSString *displayName;
@property (nonatomic, copy, nullable) NSString *modDescription;
@property (nonatomic, copy, nullable) NSString *iconURL;
@property (nonatomic, strong, nullable) UIImage *icon;
@property (nonatomic, copy, nullable) NSString *fileSHA1;
@property (nonatomic, copy, nullable) NSString *version;
@property (nonatomic, copy, nullable) NSString *gameVersion;
@property (nonatomic, copy, nullable) NSString *homepage;
@property (nonatomic, copy, nullable) NSString *sources;
@property (nonatomic, assign) BOOL isFabric;
@property (nonatomic, assign) BOOL isForge;
@property (nonatomic, assign) BOOL isNeoForge;

// --- Initializers ---
- (instancetype)initWithFilePath:(NSString *)path;
- (instancetype)initWithOnlineData:(NSDictionary *)data;

// --- Utility Methods ---
- (NSString *)basename;
- (void)refreshDisabledFlag;

@end

NS_ASSUME_NONNULL_END
