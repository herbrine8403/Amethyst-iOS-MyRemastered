#import <UIKit/UIKit.h>

// MARK: - Tile Type & Size Enums

typedef NS_ENUM(NSInteger, HomeTileType) {
    HomeTileTypeProfile = 0,
    HomeTileTypeAnnouncement,
    HomeTileTypeVersionRelease,
    HomeTileTypeVersionSnapshot,
    HomeTileTypeNews,
    HomeTileTypeShortcut,
};

// ★ [FIX511] 换底到 5.1.0 时本头文件误取了上游 5.1.0 的 2 档枚举,丢掉了 fork 的
//   [SIZE4] 四档跨度枚举 + 4 个 helper 原型。而 tree510 的 LauncherNewsViewController.m /
//   HomeCustomizeViewController.m 用的是四档符号 ⇒ 会报
//   "use of undeclared identifier 'HomeTileSizeSmall' / no prototype for AmeTileSizeShortName"。
//   现整块从 fork 版取回(同值别名保证旧的 Compact/Full 调用点零改动)。
typedef NS_ENUM(NSInteger, HomeTileSize) {
    HomeTileSizeSmall   = 0,   // 1×1(旧 HomeTileSizeCompact)
    HomeTileSizeWide    = 1,   // 2×1(旧 HomeTileSizeFull)
    HomeTileSizeTall    = 2,   // 1×2
    HomeTileSizeLarge   = 3,   // 2×2

    HomeTileSizeCompact = HomeTileSizeSmall,  // ★ [SIZE4] 旧符号别名(同值)
    HomeTileSizeFull    = HomeTileSizeWide,   // ★ [SIZE4] 旧符号别名(同值)
};

// ★ [SIZE4] 跨度 / 名称 helper(实现见 LauncherNewsViewController.m)。
NSInteger AmeTileSpanColumns(HomeTileSize size);    // 列跨度:Small/Tall⇒1,Wide/Large⇒2
NSInteger AmeTileSpanRows(HomeTileSize size);       // 行跨度:Small/Wide⇒1,Tall/Large⇒2
NSString *AmeTileSizeShortName(HomeTileSize size);  // "1×1"/"2×1"/"1×2"/"2×2"(几何,无需本地化)
NSString *AmeTileSizeDisplayName(HomeTileSize size);// 本地化名称(Half Width / Full Width / Tall / Large)

// MARK: - HomeTileConfig

@interface HomeTileConfig : NSObject <NSSecureCoding>

@property (nonatomic, copy) NSString *tileId;
@property (nonatomic, assign) HomeTileType tileType;
@property (nonatomic, assign) HomeTileSize tileSize;
@property (nonatomic, assign) BOOL visible;
@property (nonatomic, copy) NSString *customTitle;
@property (nonatomic, copy) NSString *iconName;
@property (nonatomic, copy) NSString *accentColorHex;
@property (nonatomic, copy) NSString *shortcutAction;  // For HomeTileTypeShortcut

+ (NSArray<HomeTileConfig *> *)defaultTileConfigs;
+ (NSArray<HomeTileConfig *> *)loadSavedConfigs;
+ (void)saveConfigs:(NSArray<HomeTileConfig *> *)configs;
- (UIColor *)accentColor;
- (NSDictionary *)toDictionary;
+ (instancetype)fromDictionary:(NSDictionary *)dict;

@end

// MARK: - Shortcut Action Constants

extern NSString * const kShortcutActionMods;
extern NSString * const kShortcutActionShaders;
extern NSString * const kShortcutActionModpack;
extern NSString * const kShortcutActionBackground;
extern NSString * const kShortcutActionVersions;

// MARK: - LauncherNewsViewController

@interface LauncherNewsViewController : UIViewController

@end
