//
//  PLProfiles.m
//  Amethyst
//
//  Profile manager with JSON-safe save
//

#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "utils.h"

static PLProfiles* current;

@interface PLProfiles()
@end

@implementation PLProfiles

+ (id)defaultProfiles {
    return @{
        @"profiles": @{
            @"(Default)": @{
                @"name": @"(Default)",
                @"lastVersionId": @"latest-release"
            }
        },
        @"selectedProfile": @"(Default)"
    }.mutableCopy;
}

+ (PLProfiles *)current {
    if (!current) {
        [self updateCurrent];
    }
    return current;
}

+ (void)updateCurrent {
    current = [[PLProfiles alloc] initWithCurrentInstance];
}

+ (id)profile:(NSMutableDictionary *)profile resolveKey:(id)key {
    id rawValue = profile[key];
    // renderer 必须先做白名单规范化。显式 "auto" 是档案自己的选择，只有字段
    // 缺失/空字符串时才允许继承全局默认，避免不同档案之间相互污染。
    if ([key isEqual:@"renderer"] &&
        [rawValue isKindOfClass:[NSString class]] &&
        [(NSString *)rawValue length] > 0) {
        return PLNormalizeRendererKey(rawValue);
    }
    // graphicsApi 与 renderer 使用相同的边界策略：档案显式值先做白名单
    // 规范化；只有字段缺失/空字符串时才继承全局设置。
    if ([key isEqual:@"graphicsApi"] &&
        [rawValue isKindOfClass:[NSString class]] &&
        [(NSString *)rawValue length] > 0) {
        return PLNormalizeGraphicsApiKey(rawValue);
    }
    // 兼容 javaVersion 字段：Mojang 规范是 NSDictionary（{component, majorVersion}），
    // 但部分代码（如 ForgeDirectInstaller）也写入 NSDictionary。PLProfiles 期望返回 NSString。
    if ([rawValue isKindOfClass:[NSDictionary class]]) {
        // javaVersion: 返回 majorVersion 的字符串值；缺失则落入下方 valueDefaults
        id major = rawValue[@"majorVersion"];
        if (major) return [major description];
        // 落入下方 valueDefaults 逻辑，避免返回 nil 破坏调用方
    } else if ([rawValue isKindOfClass:[NSString class]] && [(NSString *)rawValue length] > 0) {
        return rawValue;
    }

    NSDictionary *valueDefaults = @{
        @"javaVersion": @"0",
        @"gameDir": @"."
    };
    if (valueDefaults[key]) {
        return valueDefaults[key];
    }

    NSDictionary *prefDefaults = @{
        @"defaultTouchCtrl": @"control.default_ctrl",
        @"defaultGamepadCtrl": @"control.default_gamepad_ctrl",
        @"javaArgs": @"java.java_args",
        @"renderer": @"video.renderer",
        // MC 26.2+ Graphics API（OpenGL/Vulkan 游戏内切换），缺省为 "default"
        // 该字段仅在 MC 26.2+ 生效，旧版本会被 MC 忽略，无副作用。
        @"graphicsApi": @"video.graphics_api"
    };
    id prefValue = getPrefObject(prefDefaults[key]);
    if ([key isEqual:@"renderer"]) {
        return PLNormalizeRendererKey(prefValue);
    }
    if ([key isEqual:@"graphicsApi"]) {
        return PLNormalizeGraphicsApiKey(prefValue);
    }
    return prefValue;
}

+ (id)resolveKeyForCurrentProfile:(id)key {
    return [self profile:self.current.selectedProfile resolveKey:key];
}

+ (nullable NSString *)effectiveProfileNameForPreferredName:(nullable NSString *)preferredName {
    NSDictionary *profiles = self.current.profiles;
    if (preferredName.length > 0) {
        // 显式指定的目标不能静默落到当前或任意首个档案，否则下载可能写错实例。
        return [profiles[preferredName] isKindOfClass:[NSDictionary class]] ? preferredName : nil;
    }

    NSString *selectedName = self.current.selectedProfileName;
    if (selectedName.length > 0 && [profiles[selectedName] isKindOfClass:[NSDictionary class]]) {
        return selectedName;
    }

    for (NSString *name in profiles) {
        if ([name isKindOfClass:[NSString class]] && [profiles[name] isKindOfClass:[NSDictionary class]]) {
            return name;
        }
    }
    return nil;
}

+ (nullable NSString *)resolvedGameDirectoryForProfileName:(nullable NSString *)profileName {
    const char *gameDirC = getenv("POJAV_GAME_DIR");
    NSString *baseDirectory = (gameDirC ? [NSString stringWithUTF8String:gameDirC] : NSHomeDirectory()).stringByStandardizingPath;
    if (!baseDirectory.isAbsolutePath) return nil;
    NSString *effectiveName = [self effectiveProfileNameForPreferredName:profileName];
    if (effectiveName.length == 0) return nil;
    NSDictionary *profile = self.current.profiles[effectiveName];
    NSString *gameDir = profile[@"gameDir"];

    if (![gameDir isKindOfClass:[NSString class]] || gameDir.length == 0 || [gameDir isEqualToString:@"."]) {
        return baseDirectory;
    }
    if (gameDir.isAbsolutePath) {
        return gameDir.stringByStandardizingPath;
    }

    NSString *relativePath = [gameDir hasPrefix:@"./"] ? [gameDir substringFromIndex:2] : gameDir;
    NSString *resolvedPath = [[baseDirectory stringByAppendingPathComponent:relativePath] stringByStandardizingPath];
    NSString *basePrefix = [baseDirectory stringByAppendingString:@"/"];
    if (![resolvedPath isEqualToString:baseDirectory] && ![resolvedPath hasPrefix:basePrefix]) {
        return nil;
    }
    return resolvedPath;
}

- (id)initWithCurrentInstance {
    self = [super init];
    self.profilePath = [@(getenv("POJAV_GAME_DIR")) stringByAppendingPathComponent:@"launcher_profiles.json"];
    self.profileDict = parseJSONFromFile(self.profilePath);
    if (self.profileDict[@"NSErrorObject"]) {
        self.profileDict = PLProfiles.defaultProfiles;
        [self save];
    }

    return self;
}

- (id)profiles {
    id profiles = self.profileDict[@"profiles"];
    if (![profiles isKindOfClass:[NSDictionary class]]) {
        profiles = [NSMutableDictionary dictionary];
        self.profileDict[@"profiles"] = profiles;
    } else if (![profiles isKindOfClass:[NSMutableDictionary class]]) {
        profiles = [profiles mutableCopy];
        self.profileDict[@"profiles"] = profiles;
    }
    return profiles;
}

- (id)selectedProfile {
    return self.profiles[self.selectedProfileName];
}

- (NSString *)selectedProfileName {
    return (id)self.profileDict[@"selectedProfile"];
}

- (void)setSelectedProfileName:(NSString *)name {
    self.profileDict[@"selectedProfile"] = (id)name;
    [self save];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:name];
}

/// 递归清理 NSDate 等非法 JSON 类型，确保保存不崩溃
- (id)jsonSanitizedObject:(id)obj {
    if ([obj isKindOfClass:[NSDate class]]) {
        static NSDateFormatter *formatter = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            formatter = [[NSDateFormatter alloc] init];
            formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
            formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
        });
        return [formatter stringFromDate:obj];
    } else if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *clean = [NSMutableDictionary dictionaryWithCapacity:[obj count]];
        [obj enumerateKeysAndObjectsUsingBlock:^(id key, id val, BOOL *stop) {
            id safeKey = [key isKindOfClass:[NSDate class]] ? [self jsonSanitizedObject:key] : key;
            clean[safeKey] = [self jsonSanitizedObject:val];
        }];
        return clean;
    } else if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *clean = [NSMutableArray arrayWithCapacity:[obj count]];
        for (id item in obj) {
            [clean addObject:[self jsonSanitizedObject:item]];
        }
        return clean;
    }
    return obj;
}

- (void)save {
    id sanitized = [self jsonSanitizedObject:self.profileDict];
    if ([NSJSONSerialization isValidJSONObject:sanitized]) {
        saveJSONToFile(sanitized, self.profilePath);
    } else {
        NSLog(@"[PLProfiles] save failed: profileDict still contains invalid JSON types after sanitization");
    }
}

- (void)saveProfile:(NSMutableDictionary<NSString *, NSString *> *)profile withName:(NSString *)name {
    if (!self.profileDict[@"profiles"]) {
        self.profileDict[@"profiles"] = [NSMutableDictionary dictionary];
    }
    self.profileDict[@"profiles"][name] = profile;
    [self save];
}

#pragma mark - 服务器地址（FCL 风格：启动后自动加入服务器）

// 获取当前选中 profile 的服务器地址，留空返回 @""
- (NSString *)serverIpForCurrentProfile {
    return [self serverIpForProfile:self.selectedProfileName];
}

// 获取指定 profile 的服务器地址，缺失或为空均返回 @""
- (NSString *)serverIpForProfile:(NSString *)profileName {
    NSString *ip = self.profiles[profileName][@"serverIp"];
    return ip ?: @"";
}

// 设置指定 profile 的服务器地址，nil 转为 @""
- (void)setServerIp:(NSString *)serverIp forProfile:(NSString *)profileName {
    NSMutableDictionary *profile = [self.profiles[profileName] mutableCopy];
    if (!profile) {
        profile = [NSMutableDictionary dictionary];
    }
    profile[@"serverIp"] = serverIp ?: @"";
    self.profiles[profileName] = profile;
    [self save];
}

@end
