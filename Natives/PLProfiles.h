#import <Foundation/Foundation.h>

@interface PLProfiles : NSObject

@property(nonatomic) NSString *profilePath;
@property(nonatomic) NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSString *> *> *> *profileDict;

+ (PLProfiles *)current;
+ (void)updateCurrent;

+ (id)profile:(NSMutableDictionary *)profile resolveKey:(id)key;
+ (NSString *)resolveKeyForCurrentProfile:(id)key;

/// preferredName 非空时仅接受真实存在的档案，否则返回 nil；
/// preferredName 为空时依次回退到当前选中档案和首个可用档案。
+ (nullable NSString *)effectiveProfileNameForPreferredName:(nullable NSString *)preferredName;

/// 将档案 gameDir 统一解析为绝对路径（支持 "."、相对隔离目录和绝对目录）；
/// 显式指定不存在的档案时返回 nil。
+ (nullable NSString *)resolvedGameDirectoryForProfileName:(nullable NSString *)profileName;

- (id)initWithCurrentInstance;
- (NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSString *> *> *)profiles;

- (NSMutableDictionary<NSString *, NSString *> *)selectedProfile;
- (NSString *)selectedProfileName;
- (void)setSelectedProfileName:(NSString *)name;
- (void)save;

// 新增：修复构建错误 - 添加缺失的方法声明
- (void)saveProfile:(NSMutableDictionary<NSString *, NSString *> *)profile withName:(NSString *)name;

// 服务器地址（FCL 风格：启动后自动加入服务器，留空则不加入）
- (NSString *)serverIpForCurrentProfile;
- (NSString *)serverIpForProfile:(NSString *)profileName;
- (void)setServerIp:(NSString *)serverIp forProfile:(NSString *)profileName;

@end
