#import <UIKit/UIKit.h>

void loadPreferences(BOOL reset);
void toggleIsolatedPref(BOOL forceEnable);

/// 一次性迁移：旧键 general.download_source → 新版分类镜像策略键
/// （download.fileSource / assetSearchSource / assetDownloadSource / modLoaderSource）。
/// 在 AppDelegate 启动早期调用，幂等（哨兵键 download.sourceMigrated 保证只执行一次）。
void migrateDownloadSourcePreferences(void);

id getPrefObject(NSString *key);
BOOL getPrefBool(NSString *key);
float getPrefFloat(NSString *key);
NSInteger getPrefInt(NSString *key);

void setPrefObject(NSString *key, id value);
void setPrefBool(NSString *key, BOOL value);
void setPrefFloat(NSString *key, float value);
void setPrefInt(NSString *key, NSInteger value);
void setPrefString(NSString *key, NSString *value);  // 新增

void resetWarnings();

/// 获取用户自定义主题强调色（偏好键 general.accent_color）。
/// 未设置时返回启动器默认蓝 RGB(0.26, 0.63, 0.96) = #429CF5。
/// 通过 "LauncherAppearanceChanged" 通知联动刷新，调用方应在通知回调里重新读取。
/// 参照 FCL 主题色机制：用户可在设置中选择 FCL 长春花蓝 #7797CF 等任意强调色，
/// 影响启动按钮、菜单选中态、账户添加按钮等所有"主蓝"元素。
UIColor *accentColor(void);

/// accentColor 的默认值（当前蓝 #429CF5），供需要区分"默认/自定义"的场景使用
#define ACCENT_COLOR_DEFAULT_HEX @"429CF5"

BOOL getEntitlementValue(NSString *key);

UIEdgeInsets getDefaultSafeArea();
CGRect getSafeArea(CGRect screenBounds);
void setSafeArea(CGSize screenSize, CGRect safeArea);

NSString* getSelectedJavaHome(NSString* defaultJRETag, int minVersion);
// 按精确版本号取 JRE home（profile javaVersion pin 用）：只查 java_homes[version]，
// 不看全局 "0" 槽默认。未配置或目录缺失返回 nil，调用方回退到 getSelectedJavaHome。
NSString* getExactJavaHome(int version);

NSArray* getRendererKeys(BOOL containsDefault);
NSArray* getRendererNames(BOOL containsDefault);
