#import "config.h"
#import "utils.h"
#import "LauncherPreferences.h"
#import "PLThemeManager.h"
#import "PLPreferences.h"
#import "UIKit+hook.h"
#import <CoreFoundation/CoreFoundation.h>

static PLPreferences* pref;

void loadPreferences(BOOL reset) {
    assert(getenv("POJAV_HOME"));
    if (reset) {
        [pref reset];
    } else {
        pref = [[PLPreferences alloc] initWithAutomaticMigrator];
    }
}

void toggleIsolatedPref(BOOL forceEnable) {
    // 总是基于当前 POJAV_GAME_DIR 重新计算 instancePath。
    // POJAV_GAME_DIR 是符号链接（指向 $POJAV_HOME/instances/<current>），
    // 切换游戏目录时 changeSelectionTo 已更新该符号链接的目标。
    // 之前用 `if (!pref.instancePath)` 缓存了第一次设置的旧路径，
    // 导致切换目录后仍读取旧实例的 launcher_preferences.plist，
    // 用户必须重启启动器才能让 instancePath 重新计算。这里改为每次都刷新。
    pref.instancePath = [NSString stringWithFormat:@"%s/launcher_preferences.plist", getenv("POJAV_GAME_DIR")];
    [pref toggleIsolationForced:forceEnable];
}

#pragma mark Download source migration

/// 一次性迁移：旧键 general.download_source → 新版 4 个分类镜像策略键
///
/// 迁移规则：
///   official            → 4 键全部 official_first（官方优先）
///   bmclapi / mcim      → 4 键全部 mirror_first（镜像优先）
///     （bmclapi 与 mcim 都是"走国内镜像"的用户意愿：bmclapi 覆盖文件/加载器、
///       mcim 覆盖资源搜索/下载，新模型中 PLMirrorCenter 已按资源类型把
///       mirror_first 映射到对应镜像体系，故统一保留"走镜像"意愿）
///
/// 执行条件：旧键存在 且 未迁移过（哨兵键 download.sourceMigrated）。
/// 说明：4 个新键在 PLPreferences defaults 中注册了默认值 official_first，
/// 加载后无法通过"键是否为 nil"区分默认值与用户设置，故用哨兵键保证一次性；
/// 哨兵也避免了"用户手动把新键改回 official_first 后，下次启动被旧键再次覆盖"。
///
/// 迁移完成后保留旧键不删（向后兼容：尚未切换到 PLMirrorCenter 的旧读取方仍可使用）。
void migrateDownloadSourcePreferences(void) {
    if ([getPrefObject(@"download.sourceMigrated") boolValue]) return;

    NSString *legacy = getPrefObject(@"general.download_source");
    if (![legacy isKindOfClass:[NSString class]] || legacy.length == 0) return;

    // bmclapi / mcim 均视为镜像意图，其余值（official / 未知）按官方优先处理
    BOOL mirrorFirst = [legacy isEqualToString:@"bmclapi"] || [legacy isEqualToString:@"mcim"];
    NSString *value = mirrorFirst ? @"mirror_first" : @"official_first";

    NSArray<NSString *> *newKeys = @[
        @"download.fileSource",
        @"download.assetSearchSource",
        @"download.assetDownloadSource",
        @"download.modLoaderSource"
    ];
    for (NSString *key in newKeys) {
        setPrefObject(key, value);
    }
    setPrefObject(@"download.sourceMigrated", @YES);
    NSLog(@"[Preferences] Migrated general.download_source(%@) -> %@ for 4 mirror policy keys", legacy, value);
}

id getPrefObject(NSString *key) {
    return [pref getObject:key];
}
BOOL getPrefBool(NSString *key) {
    return [getPrefObject(key) boolValue];
}
float getPrefFloat(NSString *key) {
    return [getPrefObject(key) floatValue];
}
NSInteger getPrefInt(NSString *key) {
    return [getPrefObject(key) intValue];
}

void setPrefObject(NSString *key, id value) {
    [pref setObject:key value:value];
}
void setPrefBool(NSString *key, BOOL value) {
    setPrefObject(key, @(value));
}
void setPrefFloat(NSString *key, float value) {
    setPrefObject(key, @(value));
}
void setPrefInt(NSString *key, NSInteger value) {
    setPrefObject(key, @(value));
}
void setPrefString(NSString *key, NSString *value) {  // 新增
    setPrefObject(key, value);
}

void resetWarnings() {
    for (int i = 0; i < pref.globalPref[@"warnings"].count; i++) {
        NSString *key = pref.globalPref[@"warnings"].allKeys[i];
        pref.globalPref[@"warnings"][key] = @YES;
    }
}

#pragma mark Accent Color

/// 将 hex 字符串（如 "429CF5" 或 "#429CF5"）解析为 UIColor，失败返回 nil
static UIColor *colorFromHex(NSString *hex) {
    if (![hex isKindOfClass:[NSString class]] || hex.length == 0) return nil;
    NSString *clean = [hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:clean];
    if (![scanner scanHexInt:&rgb]) return nil;
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

UIColor *accentColor(void) {
    // 优先读取用户自定义主题强调色，未设置则回退到默认蓝 #429CF5
    NSString *hex = getPrefObject(@"general.accent_color");
    UIColor *custom = colorFromHex(hex);
    if (custom) return custom;
    // 未手动覆盖时由主题包提供强调色，缺失再回退到旧默认蓝。
    UIColor *legacyDefault = [UIColor colorWithRed:0.26 green:0.63 blue:0.96 alpha:1.0];
    return [PLThemeManager.sharedManager colorForToken:@"accent" fallback:legacyDefault];
}

#pragma mark Safe area

CGRect getSafeArea(CGRect screenBounds) {
    UIEdgeInsets safeArea = UIEdgeInsetsFromString(getPrefObject(@"control.control_safe_area"));
    if (screenBounds.size.width < screenBounds.size.height) {
        safeArea = UIEdgeInsetsMake(safeArea.right, safeArea.top, safeArea.left, safeArea.bottom);
    }
    return UIEdgeInsetsInsetRect(screenBounds, safeArea);
}

void setSafeArea(CGSize screenSize, CGRect frame) {
    UIEdgeInsets safeArea;
    // TODO: make safe area consistent across opposite orientations?
    if (screenSize.width < screenSize.height) {
        safeArea = UIEdgeInsetsMake(
            frame.origin.x,
            screenSize.height - CGRectGetMaxY(frame),
            screenSize.width - CGRectGetMaxX(frame),
            frame.origin.y);
    } else {
        safeArea = UIEdgeInsetsMake(
            frame.origin.y,
            frame.origin.x,
            screenSize.height - CGRectGetMaxY(frame),
            screenSize.width - CGRectGetMaxX(frame));
    }
    setPrefObject(@"control.control_safe_area", NSStringFromUIEdgeInsets(safeArea));
}

UIEdgeInsets getDefaultSafeArea() {
    UIEdgeInsets safeArea = UIApplication.sharedApplication.windows.firstObject.safeAreaInsets;
    CGSize screenSize = UIScreen.mainScreen.bounds.size;
    if (screenSize.width < screenSize.height) {
        safeArea.left = safeArea.top;
        safeArea.right = safeArea.bottom;
    }
    safeArea.top = safeArea.bottom = 0;
    return safeArea;
}

#pragma mark Java runtime

NSString* getSelectedJavaHome(NSString* defaultJRETag, int minVersion) {
    NSDictionary *pref = getPrefObject(@"java.java_homes");
    NSDictionary<NSString *, NSString *> *selected = pref[@"0"];
    NSString *selectedVer = selected[defaultJRETag];
    if (minVersion > selectedVer.intValue) {
        NSArray *sortedVersions = [pref.allKeys valueForKeyPath:@"self.integerValue"];
        sortedVersions = [sortedVersions sortedArrayUsingSelector:@selector(compare:)];
        BOOL found = NO;
        for (NSNumber *version in sortedVersions) {
            if (version.intValue >= minVersion) {
                selectedVer = version.stringValue;
                found = YES;
                break;
            }
        }
        // 修复：原代码在找不到满足 minVersion 的 runtime 时 selectedVer 仍为初始值（如 "17"），
        // 导致 if (!selectedVer) 永远为假，静默降级到 Java 17 启动 26.x 等新版本时必然崩溃。
        if (!found) {
            NSLog(@"Error: requested Java >= %d was not installed! (available: %@)", minVersion, sortedVersions);
            return nil;
        }
    }

    id selectedDir = pref[selectedVer];
    if ([selectedDir isEqualToString:@"internal"]) {
        selectedDir = [NSString stringWithFormat:@"%@/java_runtimes/java-%@-openjdk", NSBundle.mainBundle.bundlePath, selectedVer];
    } else {
        selectedDir = [NSString stringWithFormat:@"%s/java_runtimes/%@", getenv("POJAV_HOME"), selectedDir];
    }

    if ([NSFileManager.defaultManager fileExistsAtPath:selectedDir]) {
        return selectedDir;
    } else {
        NSLog(@"Error: selected runtime for %@ does not exist: %@", defaultJRETag, selectedDir);
        return nil;
    }
}

#pragma mark Renderer
NSString * const PLProfileInheritedValue = @"(default)";

NSString *PLProfileInheritedDisplayName(void) {
    return [NSString stringWithFormat:@"(%@)", localize(@"i18n_str_943", nil)];
}

NSArray* getRendererKeys(BOOL containsDefault) {
    NSMutableArray *array = @[
        @"auto",
        @ RENDERER_NAME_GL4ES,
        @ RENDERER_NAME_MTL_ANGLE,
        @ RENDERER_NAME_MOBILEGLUES,
        @ RENDERER_NAME_VK_ZINK,
        @ RENDERER_NAME_LTW,
        @ RENDERER_NAME_VULKAN
    ].mutableCopy;

    if (containsDefault) {
        [array insertObject:PLProfileInheritedValue atIndex:0];
    }
    
    return array;
}

NSArray* getRendererNames(BOOL containsDefault) {
    NSMutableArray *array;

    array = @[
        localize(@"preference.title.renderer.debug.auto", nil),
        localize(@"preference.title.renderer.debug.gl4es", nil),
        localize(@"preference.title.renderer.debug.angle", nil),
        localize(@"preference.title.renderer.debug.mg", nil),
        localize(@"preference.title.renderer.debug.zink", nil),
        localize(@"preference.title.renderer.debug.ltw", nil),
        localize(@"preference.title.renderer.debug.vulkan", nil)
    ].mutableCopy;

    if (containsDefault) {
        [array insertObject:PLProfileInheritedDisplayName() atIndex:0];
    }

    return array;
}

NSString *PLNormalizeRendererKey(id value) {
    if (![value isKindOfClass:[NSString class]]) {
        return @"auto";
    }

    NSString *key = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (key.length == 0 || ![getRendererKeys(NO) containsObject:key]) {
        if (key.length > 0) {
            NSLog(@"[Renderer] Unsupported renderer key '%@'; falling back to Auto", key);
        }
        return @"auto";
    }
    return key;
}

NSString *PLResolveRendererKey(id value) {
    NSString *key = PLNormalizeRendererKey(value);
    // 26.2+ 在 MobileGlues 自动路径上存在上下文初始化崩溃；当前稳定策略与
    // JavaLauncher 既有行为保持一致，由 Auto 确定地选择 ANGLE。
    return [key isEqualToString:@"auto"] ? @ RENDERER_NAME_MTL_ANGLE : key;
}

#pragma mark Graphics API
NSArray* getGraphicsApiKeys(BOOL containsDefault) {
    NSMutableArray *array = @[
        @"default",
        @"prefer_vulkan",
        @"prefer_opengl"
    ].mutableCopy;

    if (containsDefault) {
        [array insertObject:PLProfileInheritedValue atIndex:0];
    }
    return array;
}

NSArray* getGraphicsApiNames(BOOL containsDefault) {
    NSMutableArray *array = @[
        localize(@"i18n_str_943", nil),
        localize(@"i18n_str_941", nil),
        localize(@"i18n_str_942", nil)
    ].mutableCopy;

    if (containsDefault) {
        [array insertObject:PLProfileInheritedDisplayName() atIndex:0];
    }
    return array;
}

NSString *PLNormalizeGraphicsApiKey(id value) {
    if (![value isKindOfClass:[NSString class]]) {
        return @"default";
    }

    NSString *key = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (key.length == 0 || ![getGraphicsApiKeys(NO) containsObject:key]) {
        if (key.length > 0) {
            NSLog(@"[GraphicsAPI] Unsupported key '%@'; falling back to Default", key);
        }
        return @"default";
    }
    return key;
}
