#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const PLThemeDidChangeNotification;
FOUNDATION_EXPORT NSString * const PLDefaultThemeIdentifier;

/// 数据驱动的启动器主题管理器。
///
/// 内置主题位于 App Bundle 的 themes/<identifier>/，用户主题位于
/// $POJAV_HOME/themes/<identifier>/。主题包只描述视觉令牌，不承载业务逻辑。
@interface PLThemeManager : NSObject

@property (class, nonatomic, readonly) PLThemeManager *sharedManager;
@property (nonatomic, copy, readonly) NSString *activeIdentifier;
@property (nonatomic, copy, readonly) NSString *displayName;

/// 重新读取当前主题。无效或缺失的主题会安全回退到内置默认主题。
- (void)reload;

/// 返回可用主题的 manifest 摘要，按显示名排序。
- (NSArray<NSDictionary *> *)availableThemes;

/// 验证并切换主题；成功后发送 PLThemeDidChangeNotification。
- (BOOL)applyThemeIdentifier:(NSString *)identifier error:(NSError **)error;

/// 读取语义颜色。主题未定义或颜色格式错误时返回 fallback。
- (UIColor *)colorForToken:(NSString *)token fallback:(UIColor *)fallback;

/// "#RRGGBB[AA]" / "#RGB" 解析；格式错误返回 nil。布局引擎的原始色值也走这里。
- (nullable UIColor *)colorFromHex:(NSString *)hex;

/// 读取主题图片。未定义、路径不安全或文件损坏时返回 nil。
- (nullable UIImage *)imageForToken:(NSString *)token;

/// 解析主题/UI 包根目录（外部目录优先于同名内置包）。identifier 不安全或包不存在返回 nil。
/// 供 PLUIPackManager 等复用同一套包定位规则。
- (nullable NSString *)rootForIdentifier:(NSString *)identifier;

@end

NS_ASSUME_NONNULL_END
