#import <Foundation/Foundation.h>

@interface PLProfiles : NSObject

@property(nonatomic) NSString *profilePath;
@property(nonatomic) NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSString *> *> *> *profileDict;

+ (PLProfiles *)current;
+ (void)updateCurrent;

+ (id)profile:(NSMutableDictionary *)profile resolveKey:(id)key;
+ (NSString *)resolveKeyForCurrentProfile:(id)key;

/// 优先使用 preferredName；无效时依次回退到当前选中档案和首个可用档案。
+ (NSString *)effectiveProfileNameForPreferredName:(NSString *)preferredName;

/// 将档案 gameDir 统一解析为绝对路径（支持 "."、相对隔离目录和绝对目录）。
+ (NSString *)resolvedGameDirectoryForProfileName:(NSString *)profileName;

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
