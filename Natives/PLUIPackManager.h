#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 已通过校验的 UI 材质包（schemaVersion 2 主题包）。
/// 纯颜色包（schemaVersion 1）不会产生 PLUIPack 实例。
@interface PLUIPack : NSObject

@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *displayName;
@property (nonatomic, copy, readonly) NSString *author;
/// 入口脚本（main.lua）的绝对路径。
@property (nonatomic, copy, readonly) NSString *entryPath;
/// 包根目录的绝对路径（images/ 等资源的定位基准）。
@property (nonatomic, copy, readonly) NSString *rootPath;

- (instancetype)initWithIdentifier:(NSString *)identifier
                        displayName:(NSString *)displayName
                             author:(NSString *)author
                           rootPath:(NSString *)rootPath
                          entryPath:(NSString *)entryPath;

@end

/// UI 材质包发现/校验/加载。
///
/// 激活源优先级：
/// 1. 导入包 $POJAV_HOME/uipack/active（用户从文件 App 导入，不经 themes 机制）；
/// 2. themes/<general.theme_pack>（schemaVersion 2 的 UI 包）。
/// 都没有时 activePack 为 nil，由壳显示欢迎界面（导入/获取/切回旧引擎）。
@interface PLUIPackManager : NSObject

@property (class, nonatomic, readonly) PLUIPackManager *sharedManager;

/// 当前选中包。无导入包且未选中 UI 包时为 nil（合法状态，非错误）。
@property (nonatomic, nullable, readonly) PLUIPack *activePack;

/// 重新解析激活源（uipack/active 优先，其次 theme_pack 指向的 UI 包）。
/// 主题切换后由调用方（壳控制器）调用，保证 activePack 与 PLThemeManager 同步。
- (void)reload;

/// 所有可用的 UI 材质包（schemaVersion 2），按显示名排序。
- (NSArray<PLUIPack *> *)availableUIPacks;

/// 读取包的入口脚本源码（UTF-8）。文件缺失、超限（256KB）或解码失败返回 nil。
- (nullable NSString *)mainLuaSourceForPack:(PLUIPack *)pack;

/// 导入的激活包根目录（$POJAV_HOME/uipack/active）。POJAV_HOME 未设置时为 nil。
+ (nullable NSString *)importedPackRoot;

/// 导入 UI 包（zip 文件或文件夹）到 uipack/active：
/// 解压/复制到 staging → 校验 manifest（schemaVersion 2 + entry）→ 原子替换 active → reload。
/// 任一步失败返回 NO 并填充 error（staging 会被清理，不影响现有 active 包）。
- (BOOL)importPackFromURL:(NSURL *)url error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
