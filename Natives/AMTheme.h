// AMTheme.h —— Amethyst 新 UI 设计系统 · 主题色（ui-redesign P0）
// 数据来源：ZalithLauncher2 ui/theme/Color.kt（35 角色 × 7 色板 × 明暗，脚本生成，勿手改）
//   生成器：docs 同目录 gen_amtheme.py；重新生成：python3 gen_amtheme.py
// 语义参考：ui/theme/Palette.kt 的层级色 + components/Colors.kt 的背景感知透明度。
//
// 用法：
//   UIColor *c = AMTheme.primaryColor;          // 自动跟随明暗 + 当前色板
//   UIColor *k = AMTheme.cardColor;            // ZL2 cardColor 语义（背景感知）
//   [AMTheme setPalette:AMPaletteGlacier];     // 切色板，广播通知后视图自行刷新
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, AMPalette) {
    AMPaletteEmbermire,
    AMPaletteVelvetRose,
    AMPaletteMistwave,
    AMPaletteGlacier,
    AMPaletteVerdantField,
    AMPaletteUrbanAsh,
    AMPaletteVerdantDawn,
    AMPaletteCount
};

typedef NS_ENUM(NSUInteger, AMColorRole) {
    AMColorRolePrimary,
    AMColorRoleOnPrimary,
    AMColorRolePrimaryContainer,
    AMColorRoleOnPrimaryContainer,
    AMColorRoleSecondary,
    AMColorRoleOnSecondary,
    AMColorRoleSecondaryContainer,
    AMColorRoleOnSecondaryContainer,
    AMColorRoleTertiary,
    AMColorRoleOnTertiary,
    AMColorRoleTertiaryContainer,
    AMColorRoleOnTertiaryContainer,
    AMColorRoleError,
    AMColorRoleOnError,
    AMColorRoleErrorContainer,
    AMColorRoleOnErrorContainer,
    AMColorRoleBackground,
    AMColorRoleOnBackground,
    AMColorRoleSurface,
    AMColorRoleOnSurface,
    AMColorRoleSurfaceVariant,
    AMColorRoleOnSurfaceVariant,
    AMColorRoleOutline,
    AMColorRoleOutlineVariant,
    AMColorRoleScrim,
    AMColorRoleInverseSurface,
    AMColorRoleInverseOnSurface,
    AMColorRoleInversePrimary,
    AMColorRoleSurfaceDim,
    AMColorRoleSurfaceBright,
    AMColorRoleSurfaceContainerLowest,
    AMColorRoleSurfaceContainerLow,
    AMColorRoleSurfaceContainer,
    AMColorRoleSurfaceContainerHigh,
    AMColorRoleSurfaceContainerHighest,
    AMColorRoleCount
};

/// 色板切换通知（object=nil，userInfo=nil）——视图收到后重取颜色并刷新
extern NSString * const AMThemePaletteDidChangeNotification;

@interface AMTheme : NSObject

#pragma mark - 取色

/// 动态色：跟随系统明暗 + 当前色板（同一实例在深浅色切换时自动重解析）
+ (UIColor *)colorForRole:(AMColorRole)role;

/// 解析为具体色（不随 trait 变化）
+ (UIColor *)resolvedColorForRole:(AMColorRole)role dark:(BOOL)dark;

/// 35 个角色便捷访问器
+ (UIColor *)primaryColor;
+ (UIColor *)onPrimaryColor;
+ (UIColor *)primaryContainerColor;
+ (UIColor *)onPrimaryContainerColor;
+ (UIColor *)secondaryColor;
+ (UIColor *)onSecondaryColor;
+ (UIColor *)secondaryContainerColor;
+ (UIColor *)onSecondaryContainerColor;
+ (UIColor *)tertiaryColor;
+ (UIColor *)onTertiaryColor;
+ (UIColor *)tertiaryContainerColor;
+ (UIColor *)onTertiaryContainerColor;
+ (UIColor *)errorColor;
+ (UIColor *)onErrorColor;
+ (UIColor *)errorContainerColor;
+ (UIColor *)onErrorContainerColor;
+ (UIColor *)backgroundColor;
+ (UIColor *)onBackgroundColor;
+ (UIColor *)surfaceColor;
+ (UIColor *)onSurfaceColor;
+ (UIColor *)surfaceVariantColor;
+ (UIColor *)onSurfaceVariantColor;
+ (UIColor *)outlineColor;
+ (UIColor *)outlineVariantColor;
+ (UIColor *)scrimColor;
+ (UIColor *)inverseSurfaceColor;
+ (UIColor *)inverseOnSurfaceColor;
+ (UIColor *)inversePrimaryColor;
+ (UIColor *)surfaceDimColor;
+ (UIColor *)surfaceBrightColor;
+ (UIColor *)surfaceContainerLowestColor;
+ (UIColor *)surfaceContainerLowColor;
+ (UIColor *)surfaceContainerColor;
+ (UIColor *)surfaceContainerHighColor;
+ (UIColor *)surfaceContainerHighestColor;

#pragma mark - 色板偏好（UserDefaults: amui.theme.palette，默认 Embermire）

+ (AMPalette)currentPalette;
+ (void)setPalette:(AMPalette)palette;
+ (NSString *)paletteDisplayName:(AMPalette)palette;   // @"Glacier"
+ (NSArray<NSString *> *)allPaletteDisplayNames;       // 供设置页枚举

#pragma mark - ZL2 层级色（Palette.kt 语义）

+ (UIColor *)cardColor;       // surfaceBright（背景感知）
+ (UIColor *)onCardColor;     // onSurface
+ (UIColor *)cardTitleColor;  // surface @ 0.5 alpha
+ (UIColor *)itemColor;       // 暗=surfaceVariant / 亮=surfaceContainerLow（≈2dp elevation）
+ (UIColor *)onItemColor;     // onSurface
+ (UIColor *)pageBackgroundColor;      // surfaceContainer
+ (UIColor *)onPageBackgroundColor;    // onSurfaceVariant

#pragma mark - 背景感知透明度（ZL2 launcherBackgroundOpacity 语义）

/// 自定义背景图激活时置 YES（P2 接 BackgroundManager），卡片/条目色自动降透明
+ (BOOL)backgroundInfluencesColors;
+ (void)setBackgroundInfluencesColors:(BOOL)enabled;

/// 背景不透明度 20..100（%），默认 80（ZL2 intSetting 默认值）
+ (NSInteger)backgroundOpacityPercent;
+ (void)setBackgroundOpacityPercent:(NSInteger)percent;

/// enabled 时把 color 降到背景不透明度（color.copy(alpha=opacity/100)）
+ (UIColor *)applyBackgroundInfluence:(UIColor *)color;

@end

NS_ASSUME_NONNULL_END
