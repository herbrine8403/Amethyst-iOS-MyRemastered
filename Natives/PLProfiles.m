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
// 相对路径 → 绝对路径（"." 与空串返回 POJAV_GAME_DIR 本体）
+ (NSString *)absolutePathInGameHome:(NSString *)relativePath;
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
        // LWJGL 版本："auto" = MC 26.x 及以上用 3.4.1，其余用 3.3.3。
        // profile 里显式存 "333"/"341" 时以显式值为准。
        @"lwjglVersion": @"auto",
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
    return getPrefObject(prefDefaults[key]);
}

+ (id)resolveKeyForCurrentProfile:(id)key {
    return [self profile:self.current.selectedProfile resolveKey:key];
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
    // 新建版本默认完全隔离（对齐 PCL2）。放在这里可统一覆盖下载安装、加载器安装、导入等全部创建路径。
    if (!self.profiles[name]) {
        [PLProfiles applyDefaultIsolationForNewProfile:(NSMutableDictionary *)profile];
    }
    self.profileDict[@"profiles"][name] = profile;
    [self save];
}

#pragma mark - 版本隔离

NSString * const PLIsolationNone = @"none";
NSString * const PLIsolationMod  = @"mod";
NSString * const PLIsolationFull = @"full";

/// 完全隔离时在版本目录内建的标准结构（对齐 PCL2 / HMCL）
static NSArray<NSString *> *PLIsolationStandardSubdirectories(void) {
    static NSArray<NSString *> *dirs;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dirs = @[@"mods", @"saves", @"config", @"resourcepacks", @"shaderpacks",
                 @"logs", @"crash-reports", @"datapacks", @"screenshots"];
    });
    return dirs;
}

/// profile 里的自定义 gameDir；空串与 "." 均视为"未自定义"
static NSString *PLCustomGameDir(NSDictionary *profile) {
    id raw = profile[@"gameDir"];
    if (![raw isKindOfClass:[NSString class]]) return nil;
    NSString *value = [(NSString *)raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (value.length == 0 || [value isEqualToString:@"."]) return nil;
    return value;
}

static NSString *PLIsolationVersionId(NSDictionary *profile) {
    id raw = profile[@"lastVersionId"];
    return ([raw isKindOfClass:[NSString class]] && [(NSString *)raw length] > 0) ? raw : nil;
}

+ (NSString *)isolationModeForProfile:(NSDictionary *)profile {
    if (![profile isKindOfClass:[NSDictionary class]]) return PLIsolationNone;
    id raw = profile[@"isolation"];
    if ([raw isKindOfClass:[NSString class]] &&
        ([raw isEqualToString:PLIsolationNone] || [raw isEqualToString:PLIsolationMod] || [raw isEqualToString:PLIsolationFull])) {
        return raw;
    }
    // 旧数据兼容：手填过自定义游戏目录的版本继续按完全隔离处理，行为不变
    return PLCustomGameDir(profile) ? PLIsolationFull : PLIsolationNone;
}

+ (NSString *)effectiveGameDirForProfile:(NSDictionary *)profile {
    if (![[self isolationModeForProfile:profile] isEqualToString:PLIsolationFull]) {
        // none / mod：游戏数据仍在实例主目录，mod 模式只把 mods 移出去
        return @".";
    }
    NSString *custom = PLCustomGameDir(profile);
    if (custom) return custom;
    NSString *versionId = PLIsolationVersionId(profile);
    return versionId ? [@"versions" stringByAppendingPathComponent:versionId] : @".";
}

+ (NSString *)effectiveModsDirForProfile:(NSDictionary *)profile {
    if ([[self isolationModeForProfile:profile] isEqualToString:PLIsolationMod]) {
        NSString *versionId = PLIsolationVersionId(profile);
        if (versionId) {
            return [[@"versions" stringByAppendingPathComponent:versionId] stringByAppendingPathComponent:@"mods"];
        }
    }
    return [[self effectiveGameDirForProfile:profile] stringByAppendingPathComponent:@"mods"];
}

+ (NSString *)absolutePathInGameHome:(NSString *)relativePath {
    const char *env = getenv("POJAV_GAME_DIR");
    NSString *base = env ? @(env) : NSHomeDirectory();
    if (relativePath.length == 0 || [relativePath isEqualToString:@"."]) return base;
    if ([relativePath hasPrefix:@"/"]) return relativePath;
    NSString *clean = [relativePath hasPrefix:@"./"] ? [relativePath substringFromIndex:2] : relativePath;
    return [base stringByAppendingPathComponent:clean];
}

+ (NSString *)absoluteGameDirForProfile:(NSDictionary *)profile {
    return [self absolutePathInGameHome:[self effectiveGameDirForProfile:profile]];
}

+ (NSString *)absoluteModsDirForProfile:(NSDictionary *)profile {
    return [self absolutePathInGameHome:[self effectiveModsDirForProfile:profile]];
}

+ (void)ensureIsolationDirectoriesForProfile:(NSDictionary *)profile {
    NSString *mode = [self isolationModeForProfile:profile];
    if ([mode isEqualToString:PLIsolationNone]) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    if ([mode isEqualToString:PLIsolationMod]) {
        // 仅 Mod 隔离：只需版本自己的 mods 目录
        [fm createDirectoryAtPath:[self absoluteModsDirForProfile:profile]
      withIntermediateDirectories:YES attributes:nil error:nil];
        return;
    }

    NSString *root = [self absoluteGameDirForProfile:profile];
    [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *sub in PLIsolationStandardSubdirectories()) {
        [fm createDirectoryAtPath:[root stringByAppendingPathComponent:sub]
      withIntermediateDirectories:YES attributes:nil error:nil];
    }
}

+ (void)alignSharedModsDirectoryForProfile:(NSDictionary *)profile {
    const char *env = getenv("POJAV_GAME_DIR");
    if (!env) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *sharedMods = [@(env) stringByAppendingPathComponent:@"mods"];
    NSString *mode = [self isolationModeForProfile:profile];

    // 非"仅 Mod 隔离"时，共享 mods 必须是真实目录（此前可能被 mod 隔离换成了符号链接）
    if (![mode isEqualToString:PLIsolationMod]) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:sharedMods error:nil];
        if ([attrs[NSFileType] isEqualToString:NSFileTypeSymbolicLink]) {
            [fm removeItemAtPath:sharedMods error:nil];
            [fm createDirectoryAtPath:sharedMods withIntermediateDirectories:YES attributes:nil error:nil];
            NSLog(@"[PLProfiles] 版本隔离：已把共享 mods 恢复为真实目录 (%@)", sharedMods);
        }
        return;
    }

    NSString *isolatedMods = [self absoluteModsDirForProfile:profile];
    if (isolatedMods.length == 0) return;
    [fm createDirectoryAtPath:isolatedMods withIntermediateDirectories:YES attributes:nil error:nil];

    NSDictionary *attrs = [fm attributesOfItemAtPath:sharedMods error:nil];
    if (attrs) {
        if ([attrs[NSFileType] isEqualToString:NSFileTypeSymbolicLink]) {
            NSString *dest = [fm destinationOfSymbolicLinkAtPath:sharedMods error:nil];
            if ([dest isEqualToString:isolatedMods]) return; // 已指向本版本
            [fm removeItemAtPath:sharedMods error:nil];
        } else {
            // 真实目录：把已有 mod 迁移进版本目录，避免"开启 Mod 隔离后 mod 消失"
            NSError *err = nil;
            NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:sharedMods error:&err];
            if (err) {
                NSLog(@"[PLProfiles] 版本隔离：读取共享 mods 失败，保持原状：%@", err.localizedDescription);
                return;
            }
            for (NSString *item in items) {
                NSString *from = [sharedMods stringByAppendingPathComponent:item];
                NSString *to = [isolatedMods stringByAppendingPathComponent:item];
                if ([fm fileExistsAtPath:to]) continue; // 版本目录已有同名文件，保留版本目录的
                if (![fm moveItemAtPath:from toPath:to error:&err]) {
                    NSLog(@"[PLProfiles] 版本隔离：迁移 %@ 失败，取消符号链接以免丢文件：%@", item, err.localizedDescription);
                    return;
                }
            }
            if ([fm contentsOfDirectoryAtPath:sharedMods error:nil].count > 0) {
                NSLog(@"[PLProfiles] 版本隔离：共享 mods 未清空，取消符号链接以免丢文件");
                return;
            }
            [fm removeItemAtPath:sharedMods error:nil];
        }
    }

    NSError *linkErr = nil;
    if ([fm createSymbolicLinkAtPath:sharedMods withDestinationPath:isolatedMods error:&linkErr]) {
        NSLog(@"[PLProfiles] 版本隔离(仅Mod)：%@ → %@", sharedMods, isolatedMods);
    } else {
        NSLog(@"[PLProfiles] 版本隔离：创建 mods 符号链接失败：%@", linkErr.localizedDescription);
    }
}

+ (void)setIsolationMode:(NSString *)mode customGameDir:(NSString *)customGameDir forProfileName:(NSString *)name {
    if (name.length == 0) return;
    if (![mode isEqualToString:PLIsolationNone] && ![mode isEqualToString:PLIsolationMod] && ![mode isEqualToString:PLIsolationFull]) {
        mode = PLIsolationNone;
    }

    NSMutableDictionary *profiles = [PLProfiles current].profiles;
    NSMutableDictionary *profile = [profiles[name] mutableCopy] ?: [NSMutableDictionary dictionary];
    profile[@"isolation"] = mode;
    if ([mode isEqualToString:PLIsolationFull] && customGameDir.length > 0) {
        profile[@"gameDir"] = customGameDir;
    } else {
        // 自动完全隔离 / 仅Mod隔离 / 不隔离：清掉自定义目录，让 gameDir 回落到主目录
        profile[@"gameDir"] = @".";
    }
    profiles[name] = profile;
    [[PLProfiles current] save];

    NSLog(@"[PLProfiles] 版本隔离：profile '%@' → %@%@", name, mode,
          ([mode isEqualToString:PLIsolationFull] && customGameDir.length > 0) ? [NSString stringWithFormat:@" (%@)", customGameDir] : @"");
    [self ensureIsolationDirectoriesForProfile:[profile copy]];
}

+ (void)applyDefaultIsolationForNewProfile:(NSMutableDictionary *)profile {
    if (![profile isKindOfClass:[NSMutableDictionary class]]) return;
    if (profile[@"isolation"]) return;          // 调用方已显式指定
    if (PLCustomGameDir(profile)) return;       // 整合包等自带自定义目录，保持原样
    profile[@"isolation"] = PLIsolationFull;    // 新建版本默认完全隔离（对齐 PCL2）
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
