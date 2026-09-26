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

/// Task141：启动内存（JVM Xmx）的单一事实源。
/// JavaLauncher 的 launchJVM 与 SurfaceViewController 的 updateJetsamControl
/// 必须读同一个值 —— 两处错位会让 Jetsam 上限低于"Xmx + native 开销"，
/// 系统在 JVM 启动阶段直接 SIGKILL（不可捕获，日志表现为进程凭空消失、无崩溃栈）。
/// 本函数同时按设备物理内存收敛上限，保证 jetsam 上限（allocmem + 1024）
/// 给系统与其它进程留出余量。设 AMETHYST_MEM_NO_CLAMP=1 可关闭收敛。
int ame141_currentLaunchAllocMem(void);

UIEdgeInsets getDefaultSafeArea();
CGRect getSafeArea(CGRect screenBounds);
void setSafeArea(CGSize screenSize, CGRect safeArea);

NSString* getSelectedJavaHome(NSString* defaultJRETag, int minVersion);

NSArray* getRendererKeys(BOOL containsDefault);
NSArray* getRendererNames(BOOL containsDefault);
