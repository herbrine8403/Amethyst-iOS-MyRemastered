// AMTheme.m —— 数据由 gen_amtheme.py 生成，勿手改色值
#import "AMTheme.h"

NSString * const AMThemePaletteDidChangeNotification = @"AMThemePaletteDidChange";

static NSString * const kPaletteKey = @"amui.theme.palette";
static NSString * const kBgInfluencedKey = @"amui.bg.influenced";
static NSString * const kBgOpacityKey = @"amui.bg.opacity";

// [色板][角色]，明/暗两表
static const uint32_t kAMLight[AMPaletteCount][AMColorRoleCount] = {
    /* Embermire     */ { 0xFFA63A17u, 0xFFFFFFFFu, 0xFFFE7A52u, 0xFF2F0700u, 0xFF894F3Du, 0xFFFFFFFFu, 0xFFFFBBA7u, 0xFF5C2B1Cu, 0xFF6E5E00u, 0xFFFFFFFFu, 0xFFBAA015u, 0xFF1A1500u, 0xFFBA1A1Au, 0xFFFFFFFFu, 0xFFFFDAD6u, 0xFF410002u, 0xFFFFF8F6u, 0xFF241916u, 0xFFFFF8F6u, 0xFF241916u, 0xFFFCDBD3u, 0xFF58423Bu, 0xFF8B716Au, 0xFFDFC0B7u, 0xFF000000u, 0xFF3B2D2Au, 0xFFFFEDE8u, 0xFFFFB59Fu, 0xFFEBD5D0u, 0xFFFFF8F6u, 0xFFFFFFFFu, 0xFFFFF1EDu, 0xFFFFE9E4u, 0xFFFAE3DDu, 0xFFF4DED8u },
    /* Velvet Rose   */ { 0xFF723D57u, 0xFFFFFFFFu, 0xFF9B607Cu, 0xFFFFFFFFu, 0xFF725762u, 0xFFFFFFFFu, 0xFFFFDAE8u, 0xFF5B414Du, 0xFF773F27u, 0xFFFFFFFFu, 0xFFA26247u, 0xFFFFFFFFu, 0xFFBA1A1Au, 0xFFFFFFFFu, 0xFFFFDAD6u, 0xFF410002u, 0xFFFFF8F8u, 0xFF1F1A1Cu, 0xFFFFF8F8u, 0xFF1F1A1Cu, 0xFFF1DEE4u, 0xFF504348u, 0xFF827378u, 0xFFD4C2C8u, 0xFF000000u, 0xFF352F31u, 0xFFF9EEF0u, 0xFFF9B2D2u, 0xFFE2D7DAu, 0xFFFFF8F8u, 0xFFFFFFFFu, 0xFFFCF1F3u, 0xFFF7EBEDu, 0xFFF1E5E8u, 0xFFEBE0E2u },
    /* Mistwave      */ { 0xFF426469u, 0xFFFFFFFFu, 0xFFB1D5DBu, 0xFF1E4146u, 0xFF546163u, 0xFFFFFFFFu, 0xFFD8E6E9u, 0xFF3E4B4Du, 0xFF655975u, 0xFFFFFFFFu, 0xFFD8C9E9u, 0xFF423751u, 0xFFBA1A1Au, 0xFFFFFFFFu, 0xFFFFDAD6u, 0xFF410002u, 0xFFFAF9F9u, 0xFF1A1C1Cu, 0xFFFAF9F9u, 0xFF1A1C1Cu, 0xFFDDE4E5u, 0xFF414849u, 0xFF71787Au, 0xFFC1C8C9u, 0xFF000000u, 0xFF2F3131u, 0xFFF1F1F0u, 0xFFA9CDD3u, 0xFFDADADAu, 0xFFFAF9F9u, 0xFFFFFFFFu, 0xFFF4F3F3u, 0xFFEEEEEEu, 0xFFE8E8E8u, 0xFFE3E2E2u },
    /* Glacier       */ { 0xFF006684u, 0xFFFFFFFFu, 0xFF4CAFD6u, 0xFF001B26u, 0xFF426372u, 0xFFFFFFFFu, 0xFFCAECFEu, 0xFF2E4F5Du, 0xFF794C91u, 0xFFFFFFFFu, 0xFFC390DBu, 0xFF2B0041u, 0xFFBA1A1Au, 0xFFFFFFFFu, 0xFFFFDAD6u, 0xFF410002u, 0xFFF6FAFDu, 0xFF181C1Fu, 0xFFF6FAFDu, 0xFF181C1Fu, 0xFFDAE4EAu, 0xFF3E484Eu, 0xFF6E797Eu, 0xFFBEC8CEu, 0xFF000000u, 0xFF2D3134u, 0xFFEEF1F4u, 0xFF73D2FBu, 0xFFD7DADEu, 0xFFF6FAFDu, 0xFFFFFFFFu, 0xFFF0F4F7u, 0xFFEBEEF1u, 0xFFE5E9ECu, 0xFFDFE3E6u },
    /* Verdant Field */ { 0xFF676014u, 0xFFFFFFFFu, 0xFFEFE58Bu, 0xFF1F1C00u, 0xFF635F41u, 0xFFFFFFFFu, 0xFFEAE3BEu, 0xFF1E1C05u, 0xFF406653u, 0xFFFFFFFFu, 0xFFC1ECD4u, 0xFF002114u, 0xFFBA1A1Au, 0xFFFFFFFFu, 0xFFFFDAD6u, 0xFF410002u, 0xFFFEF9EBu, 0xFF1D1C14u, 0xFFFEF9EBu, 0xFF1D1C14u, 0xFFE7E3D0u, 0xFF49473Au, 0xFF7A7768u, 0xFFCBC7B5u, 0xFF000000u, 0xFF323128u, 0xFFF5F0E3u, 0xFFD2C972u, 0xFFDEDACCu, 0xFFFEF9EBu, 0xFFFFFFFFu, 0xFFF8F3E6u, 0xFFF2EEE0u, 0xFFEDE8DAu, 0xFFE7E2D5u },
    /* Urban Ash     */ { 0xFF5E5E5Fu, 0xFFFFFFFFu, 0xFFAEAEAEu, 0xFF222324u, 0xFF5F5E5Eu, 0xFFFFFFFFu, 0xFFE8E6E5u, 0xFF4A4A4Au, 0xFF615D5Fu, 0xFFFFFFFFu, 0xFFB2ADAFu, 0xFF252324u, 0xFFBA1A1Au, 0xFFFFFFFFu, 0xFFFFDAD6u, 0xFF410002u, 0xFFFCF8F8u, 0xFF1C1B1Bu, 0xFFFCF8F8u, 0xFF1C1B1Bu, 0xFFE0E3E3u, 0xFF444748u, 0xFF747878u, 0xFFC4C7C7u, 0xFF000000u, 0xFF313030u, 0xFFF4F0EFu, 0xFFC7C6C6u, 0xFFDDD9D9u, 0xFFFCF8F8u, 0xFFFFFFFFu, 0xFFF7F3F2u, 0xFFF1EDECu, 0xFFEBE7E7u, 0xFFE5E2E1u },
    /* Verdant Dawn  */ { 0xFF004814u, 0xFFFFFFFFu, 0xFF276E31u, 0xFFFFFFFFu, 0xFF4A6548u, 0xFFFFFFFFu, 0xFFCFEFCAu, 0xFF365135u, 0xFF003C77u, 0xFFFFFFFFu, 0xFF2960A6u, 0xFFFFFFFFu, 0xFFBA1A1Au, 0xFFFFFFFFu, 0xFFFFDAD6u, 0xFF410002u, 0xFFF7FBF2u, 0xFF181D18u, 0xFFF7FBF2u, 0xFF181D18u, 0xFFDCE5D7u, 0xFF40493Eu, 0xFF707A6Du, 0xFFC0C9BBu, 0xFF000000u, 0xFF2D322Cu, 0xFFEEF2E9u, 0xFF8ED88Eu, 0xFFD8DBD3u, 0xFFF7FBF2u, 0xFFFFFFFFu, 0xFFF1F5ECu, 0xFFECEFE6u, 0xFFE6E9E1u, 0xFFE0E4DBu },
};

static const uint32_t kAMDark[AMPaletteCount][AMColorRoleCount] = {
    /* Embermire     */ { 0xFFFFB59Fu, 0xFF5F1600u, 0xFFC4502Bu, 0xFFFFFFFFu, 0xFFFFB59Fu, 0xFF512214u, 0xFF643122u, 0xFFFFC8B9u, 0xFFF0D44Cu, 0xFF393000u, 0xFFC4AA22u, 0xFF272000u, 0xFFFFB4ABu, 0xFF690005u, 0xFF93000Au, 0xFFFFDAD6u, 0xFF1C110Eu, 0xFFF4DED8u, 0xFF1C110Eu, 0xFFF4DED8u, 0xFF58423Bu, 0xFFDFC0B7u, 0xFFA68B83u, 0xFF58423Bu, 0xFF000000u, 0xFFF4DED8u, 0xFF3B2D2Au, 0xFFA63A17u, 0xFF1C110Eu, 0xFF443632u, 0xFF160C09u, 0xFF241916u, 0xFF291D19u, 0xFF342723u, 0xFF3F322Eu },
    /* Velvet Rose   */ { 0xFFF9B2D2u, 0xFF4F2039u, 0xFF915873u, 0xFFFFFFFFu, 0xFFE0BDCBu, 0xFF412A34u, 0xFF4F3641u, 0xFFEBC7D5u, 0xFFFFB598u, 0xFF52220Cu, 0xFF97593Fu, 0xFFFFFFFFu, 0xFFFFB4ABu, 0xFF690005u, 0xFF93000Au, 0xFFFFDAD6u, 0xFF171214u, 0xFFEBE0E2u, 0xFF171214u, 0xFFEBE0E2u, 0xFF504348u, 0xFFD4C2C8u, 0xFF9D8C92u, 0xFF504348u, 0xFF000000u, 0xFFEBE0E2u, 0xFF352F31u, 0xFF854D68u, 0xFF171214u, 0xFF3E373Au, 0xFF120D0Fu, 0xFF1F1A1Cu, 0xFF241E20u, 0xFF2E282Au, 0xFF393335u },
    /* Mistwave      */ { 0xFFCEF3F9u, 0xFF11353Au, 0xFFA5C9CFu, 0xFF14383Du, 0xFFBBC9CBu, 0xFF263335u, 0xFF333F41u, 0xFFC5D3D6u, 0xFFF5E9FFu, 0xFF362C45u, 0xFFCCBDDDu, 0xFF392F48u, 0xFFFFB4ABu, 0xFF690005u, 0xFF93000Au, 0xFFFFDAD6u, 0xFF121414u, 0xFFE3E2E2u, 0xFF121414u, 0xFFE3E2E2u, 0xFF414849u, 0xFFC1C8C9u, 0xFF8B9293u, 0xFF414849u, 0xFF000000u, 0xFFE3E2E2u, 0xFF2F3131u, 0xFF426469u, 0xFF121414u, 0xFF38393Au, 0xFF0D0E0Fu, 0xFF1A1C1Cu, 0xFF1E2020u, 0xFF292A2Au, 0xFF333535u },
    /* Glacier       */ { 0xFF73D2FBu, 0xFF003546u, 0xFF007EA2u, 0xFFFFFFFFu, 0xFFAACBDDu, 0xFF113442u, 0xFF204250u, 0xFFB4D6E8u, 0xFFE7B3FFu, 0xFF471C5Fu, 0xFFAF7EC7u, 0xFF000000u, 0xFFFFB4ABu, 0xFF690005u, 0xFF93000Au, 0xFFFFDAD6u, 0xFF101416u, 0xFFDFE3E6u, 0xFF101416u, 0xFFDFE3E6u, 0xFF3E484Eu, 0xFFBEC8CEu, 0xFF889298u, 0xFF3E484Eu, 0xFF000000u, 0xFFDFE3E6u, 0xFF2D3134u, 0xFF006684u, 0xFF101416u, 0xFF353A3Cu, 0xFF0A0F11u, 0xFF181C1Fu, 0xFF1C2023u, 0xFF262B2Du, 0xFF313538u },
    /* Verdant Field */ { 0xFFD2C972u, 0xFF353100u, 0xFF4E4800u, 0xFFEFE58Bu, 0xFFCDC7A3u, 0xFF343117u, 0xFF4B482Cu, 0xFFEAE3BEu, 0xFFA6D0B9u, 0xFF0F3727u, 0xFF284E3Cu, 0xFFC1ECD4u, 0xFFFFB4ABu, 0xFF690005u, 0xFF93000Au, 0xFFFFDAD6u, 0xFF15140Cu, 0xFFE7E2D5u, 0xFF15140Cu, 0xFFE7E2D5u, 0xFF49473Au, 0xFFCBC7B5u, 0xFF949181u, 0xFF49473Au, 0xFF000000u, 0xFFE7E2D5u, 0xFF323128u, 0xFF676014u, 0xFF15140Cu, 0xFF3B3930u, 0xFF0F0E07u, 0xFF1D1C14u, 0xFF212017u, 0xFF2C2A21u, 0xFF37352Cu },
    /* Urban Ash     */ { 0xFFC7C6C6u, 0xFF2F3131u, 0xFF9B9B9Bu, 0xFF0B0C0Du, 0xFFC8C6C6u, 0xFF303030u, 0xFF3D3D3Du, 0xFFD3D0D0u, 0xFFCBC5C7u, 0xFF323031u, 0xFFA09B9Du, 0xFF0F0D0Fu, 0xFFFFB4ABu, 0xFF690005u, 0xFF93000Au, 0xFFFFDAD6u, 0xFF141313u, 0xFFE5E2E1u, 0xFF141313u, 0xFFE5E2E1u, 0xFF444748u, 0xFFC4C7C7u, 0xFF8E9192u, 0xFF444748u, 0xFF000000u, 0xFFE5E2E1u, 0xFF313030u, 0xFF5E5E5Fu, 0xFF141313u, 0xFF3A3939u, 0xFF0E0E0Eu, 0xFF1C1B1Bu, 0xFF201F1Fu, 0xFF2A2A2Au, 0xFF353434u },
    /* Verdant Dawn  */ { 0xFF8ED88Eu, 0xFF00390Fu, 0xFF005219u, 0xFFA6F2A5u, 0xFFB0CFABu, 0xFF1C361Du, 0xFF294329u, 0xFFB9D9B5u, 0xFFA7C8FFu, 0xFF003061u, 0xFF004688u, 0xFFD1E0FFu, 0xFFFFB4ABu, 0xFF690005u, 0xFF93000Au, 0xFFFFDAD6u, 0xFF101410u, 0xFFE0E4DBu, 0xFF101410u, 0xFFE0E4DBu, 0xFF40493Eu, 0xFFC0C9BBu, 0xFF8A9386u, 0xFF40493Eu, 0xFF000000u, 0xFFE0E4DBu, 0xFF2D322Cu, 0xFF246C2Fu, 0xFF101410u, 0xFF363A34u, 0xFF0B0F0Bu, 0xFF181D18u, 0xFF1C211Bu, 0xFF272B26u, 0xFF323630u },
};

static NSString * const kPaletteNames[AMPaletteCount] = {
    @"Embermire",
    @"Velvet Rose",
    @"Mistwave",
    @"Glacier",
    @"Verdant Field",
    @"Urban Ash",
    @"Verdant Dawn",
};

static inline UIColor *AMColorMake(uint32_t v) {
    return [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0
                           green:((v >> 8) & 0xFF) / 255.0
                            blue:(v & 0xFF) / 255.0
                           alpha:1.0];
}

// 已解析色缓存：key = (mode<<10)|(palette<<6)|role —— 最多 490 项
static NSMutableDictionary<NSNumber *, UIColor *> *gResolvedCache;

@implementation AMTheme

+ (void)initialize {
    if (self == [AMTheme class]) {
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
            kPaletteKey: @(0),
            kBgOpacityKey: @(80),
        }];
    }
}

+ (UIColor *)colorForRole:(AMColorRole)role {
    // 动态色不缓存 provider 的解析结果：resolve 时按 gPalette 取值，
    // 切色板只需广播通知让视图重取，明暗切换由 UIKit 自动重解析。
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        BOOL dark = (tc.userInterfaceStyle == UIUserInterfaceStyleDark);
        return [AMTheme resolvedColorForRole:role dark:dark];
    }];
}

+ (UIColor *)resolvedColorForRole:(AMColorRole)role dark:(BOOL)dark {
    if (role >= AMColorRoleCount) return [UIColor magentaColor];
    NSInteger palette = [AMTheme currentPalette];
    NSUInteger key = ((NSUInteger)(dark ? 1 : 0) << 10) | ((NSUInteger)palette << 6) | role;
    @synchronized(gResolvedCache ?: [AMTheme class]) {
        if (!gResolvedCache) gResolvedCache = [NSMutableDictionary new];
        NSNumber *k = @(key);
        UIColor *c = gResolvedCache[k];
        if (!c) {
            const uint32_t v = dark ? kAMDark[palette][role] : kAMLight[palette][role];
            c = AMColorMake(v);
            gResolvedCache[k] = c;
        }
        return c;
    }
}

+ (UIColor *)primaryColor { return [AMTheme colorForRole:AMColorRolePrimary]; }
+ (UIColor *)onPrimaryColor { return [AMTheme colorForRole:AMColorRoleOnPrimary]; }
+ (UIColor *)primaryContainerColor { return [AMTheme colorForRole:AMColorRolePrimaryContainer]; }
+ (UIColor *)onPrimaryContainerColor { return [AMTheme colorForRole:AMColorRoleOnPrimaryContainer]; }
+ (UIColor *)secondaryColor { return [AMTheme colorForRole:AMColorRoleSecondary]; }
+ (UIColor *)onSecondaryColor { return [AMTheme colorForRole:AMColorRoleOnSecondary]; }
+ (UIColor *)secondaryContainerColor { return [AMTheme colorForRole:AMColorRoleSecondaryContainer]; }
+ (UIColor *)onSecondaryContainerColor { return [AMTheme colorForRole:AMColorRoleOnSecondaryContainer]; }
+ (UIColor *)tertiaryColor { return [AMTheme colorForRole:AMColorRoleTertiary]; }
+ (UIColor *)onTertiaryColor { return [AMTheme colorForRole:AMColorRoleOnTertiary]; }
+ (UIColor *)tertiaryContainerColor { return [AMTheme colorForRole:AMColorRoleTertiaryContainer]; }
+ (UIColor *)onTertiaryContainerColor { return [AMTheme colorForRole:AMColorRoleOnTertiaryContainer]; }
+ (UIColor *)errorColor { return [AMTheme colorForRole:AMColorRoleError]; }
+ (UIColor *)onErrorColor { return [AMTheme colorForRole:AMColorRoleOnError]; }
+ (UIColor *)errorContainerColor { return [AMTheme colorForRole:AMColorRoleErrorContainer]; }
+ (UIColor *)onErrorContainerColor { return [AMTheme colorForRole:AMColorRoleOnErrorContainer]; }
+ (UIColor *)backgroundColor { return [AMTheme colorForRole:AMColorRoleBackground]; }
+ (UIColor *)onBackgroundColor { return [AMTheme colorForRole:AMColorRoleOnBackground]; }
+ (UIColor *)surfaceColor { return [AMTheme colorForRole:AMColorRoleSurface]; }
+ (UIColor *)onSurfaceColor { return [AMTheme colorForRole:AMColorRoleOnSurface]; }
+ (UIColor *)surfaceVariantColor { return [AMTheme colorForRole:AMColorRoleSurfaceVariant]; }
+ (UIColor *)onSurfaceVariantColor { return [AMTheme colorForRole:AMColorRoleOnSurfaceVariant]; }
+ (UIColor *)outlineColor { return [AMTheme colorForRole:AMColorRoleOutline]; }
+ (UIColor *)outlineVariantColor { return [AMTheme colorForRole:AMColorRoleOutlineVariant]; }
+ (UIColor *)scrimColor { return [AMTheme colorForRole:AMColorRoleScrim]; }
+ (UIColor *)inverseSurfaceColor { return [AMTheme colorForRole:AMColorRoleInverseSurface]; }
+ (UIColor *)inverseOnSurfaceColor { return [AMTheme colorForRole:AMColorRoleInverseOnSurface]; }
+ (UIColor *)inversePrimaryColor { return [AMTheme colorForRole:AMColorRoleInversePrimary]; }
+ (UIColor *)surfaceDimColor { return [AMTheme colorForRole:AMColorRoleSurfaceDim]; }
+ (UIColor *)surfaceBrightColor { return [AMTheme colorForRole:AMColorRoleSurfaceBright]; }
+ (UIColor *)surfaceContainerLowestColor { return [AMTheme colorForRole:AMColorRoleSurfaceContainerLowest]; }
+ (UIColor *)surfaceContainerLowColor { return [AMTheme colorForRole:AMColorRoleSurfaceContainerLow]; }
+ (UIColor *)surfaceContainerColor { return [AMTheme colorForRole:AMColorRoleSurfaceContainer]; }
+ (UIColor *)surfaceContainerHighColor { return [AMTheme colorForRole:AMColorRoleSurfaceContainerHigh]; }
+ (UIColor *)surfaceContainerHighestColor { return [AMTheme colorForRole:AMColorRoleSurfaceContainerHighest]; }

#pragma mark - 色板偏好

+ (AMPalette)currentPalette {
    NSInteger p = [[NSUserDefaults standardUserDefaults] integerForKey:kPaletteKey];
    return (p >= 0 && p < AMPaletteCount) ? (AMPalette)p : AMPaletteEmbermire;
}

+ (void)setPalette:(AMPalette)palette {
    if (palette >= AMPaletteCount) return;
    [[NSUserDefaults standardUserDefaults] setInteger:palette forKey:kPaletteKey];
    [[NSNotificationCenter defaultCenter] postNotificationName:AMThemePaletteDidChangeNotification
                                                        object:nil];
}

+ (NSString *)paletteDisplayName:(AMPalette)palette {
    return (palette < AMPaletteCount) ? kPaletteNames[palette] : @"?";
}

+ (NSArray<NSString *> *)allPaletteDisplayNames {
    NSMutableArray *names = [NSMutableArray arrayWithCapacity:AMPaletteCount];
    for (NSInteger i = 0; i < AMPaletteCount; i++) [names addObject:kPaletteNames[i]];
    return names;
}

#pragma mark - ZL2 层级色（Palette.kt）

+ (UIColor *)cardColor {
    return [AMTheme applyBackgroundInfluence:[AMTheme surfaceBrightColor]];
}
+ (UIColor *)onCardColor {
    return [AMTheme onSurfaceColor];
}
+ (UIColor *)cardTitleColor {
    return [[AMTheme surfaceColor] colorWithAlphaComponent:0.5];
}
+ (UIColor *)itemColor {
    // ZL2: 暗=surfaceVariant；亮=surfaceColorAtElevation(2dp)。
    // M3 elevation→container 的标准映射取 surfaceContainerLow（2dp 档），
    // 视觉验收若偏差一行即可调。
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        BOOL dark = (tc.userInterfaceStyle == UIUserInterfaceStyleDark);
        AMColorRole role = dark ? AMColorRoleSurfaceVariant : AMColorRoleSurfaceContainerLow;
        return [AMTheme resolvedColorForRole:role dark:dark];
    }];
}
+ (UIColor *)onItemColor {
    return [AMTheme onSurfaceColor];
}
+ (UIColor *)pageBackgroundColor {
    return [AMTheme surfaceContainerColor];
}
+ (UIColor *)onPageBackgroundColor {
    return [AMTheme onSurfaceVariantColor];
}

#pragma mark - 背景感知透明度

+ (BOOL)backgroundInfluencesColors {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kBgInfluencedKey];
}

+ (void)setBackgroundInfluencesColors:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kBgInfluencedKey];
    [[NSNotificationCenter defaultCenter] postNotificationName:AMThemePaletteDidChangeNotification
                                                        object:nil];
}

+ (NSInteger)backgroundOpacityPercent {
    NSInteger p = [[NSUserDefaults standardUserDefaults] integerForKey:kBgOpacityKey];
    return MIN(MAX(p, 20), 100);
}

+ (void)setBackgroundOpacityPercent:(NSInteger)percent {
    [[NSUserDefaults standardUserDefaults] setInteger:MIN(MAX(percent, 20), 100)
                                              forKey:kBgOpacityKey];
}

+ (UIColor *)applyBackgroundInfluence:(UIColor *)color {
    if (![AMTheme backgroundInfluencesColors]) return color;
    return [color colorWithAlphaComponent:[AMTheme backgroundOpacityPercent] / 100.0];
}

@end
