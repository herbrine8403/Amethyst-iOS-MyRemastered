#import "LauncherPreferences.h"
#import "PLPreferences.h"
#import "UIKit+hook.h"
#import "config.h"
#import "utils.h"

NSString *const PREF_DOWNLOAD_SOURCE_MOD = @"general.download_source_mod";
NSString *const PREF_DOWNLOAD_SOURCE_SHADER = @"general.download_source_shader";
NSString *const PREF_DOWNLOAD_SOURCE_RESOURCEPACK = @"general.download_source_resourcepack";
NSString *const PREF_DOWNLOAD_SOURCE_DATAPACK = @"general.download_source_datapack";
NSString *const PREF_DOWNLOAD_SOURCE_MODPACK = @"general.download_source_modpack";
NSString *const PREF_DOWNLOAD_SOURCE_WORLD = @"general.download_source_world";
NSString *const PREF_DOWNLOAD_SOURCE_SERVER = @"general.download_source_server";
NSString *const PREF_CURSEFORGE_API_KEY = @"general.curseforge_api_key";
NSString *const PREF_MOD_UPDATE_KEEP_OLD = @"general.mod_update_keep_old";
NSString *const PREF_MOD_MIRROR = @"general.mod_mirror";

@interface PLPreferences()
@end

@implementation PLPreferences

+ (id)defaultPrefForGlobal:(BOOL)global {
    // Preferences that can be isolated
    NSMutableDictionary<NSString *, NSMutableDictionary *> *defaults = @{
        @"general": @{
            @"check_sha": @YES,
            @"cosmetica": @YES,
            @"debug_logging": @(!CONFIG_RELEASE),
            @"news_url": @"https://air-api.vercel.app/api/announcements.php",
            @"download_source": @"bmclapi",
            // 各资源类型独立下载源（未显式设置时回退到 modrinth）
            @"download_source_mod": @"modrinth",
            @"download_source_shader": @"modrinth",
            @"download_source_resourcepack": @"modrinth",
            @"download_source_datapack": @"modrinth",
            @"download_source_modpack": @"modrinth",
            @"download_source_world": @"modrinth",
            @"download_source_server": @"modrinth",
            // CurseForge API Key：空串代表使用编译时内置的默认 key
            @"curseforge_api_key": @"",
            // Mod 更新时是否保留旧文件（默认 YES）
            @"mod_update_keep_old": @YES,
            // 模组镜像源：official（官方源）/ mcim（MCIM 镜像源，国内加速）
            @"mod_mirror": @"official",
            // profile 写入的强制内存分配，0=使用 java.allocated_memory/auto_ram 逻辑
            @"ram_allocation": @(0),
            // 首页公告磁贴预览级别：full（标题+日期+摘要）/ summary（标题+摘要）/ title_only（仅标题）
            @"announcement_preview_level": @"summary",
        }.mutableCopy,
        // 分类镜像策略（值 official_first / mirror_first，由 PLMirrorCenter 统一读取，
        // 未迁移时 PLMirrorCenter 会回退旧键 general.download_source）
        @"download": @{
            @"fileSource": @"official_first",
            @"assetSearchSource": @"official_first",
            @"assetDownloadSource": @"official_first",
            @"modLoaderSource": @"official_first",
            // 一次性迁移哨兵：YES 表示旧键 download_source 已迁移到上述 4 键，
            // 防止用户手动改新键后被重复迁移覆盖（见 LauncherPreferences.m migrateDownloadSourcePreferences）
            @"sourceMigrated": @NO,
        }.mutableCopy,
        @"video": @{ // Video & Audio
            @"renderer": @"auto",
            @"resolution": @(100),
            // max_framerate 选项已移除：CADisplayLink 始终采用 30-120Hz 自适应范围，
            // 由屏幕硬件能力决定实际帧率。保留 disable_game_vsync 作为唯一帧率解锁开关。
            // 解锁帧率（关闭垂直同步）：默认开启。
            // MC 默认 enableVsync=true，会把帧率锁在屏幕刷新率（60Hz 锁 60、120Hz ProMotion 锁 120）。
            // 开启后启动器会在三层联动关闭 VSync：options.txt 强制 enableVsync=false、
            // pojavSwapInterval 强制 interval=0、CAMetalLayer 三缓冲。详见各修改点注释。
            @"disable_game_vsync": @YES,
            @"performance_hud": @NO,
            @"fullscreen_airplay": @YES,
            @"silence_other_audio": @NO,
            @"silence_with_switch": @NO,
            @"fix_simple_voice_chat_mod": @NO,
            @"allow_microphone": @NO,
            // MC 26.2+ 游戏内 OpenGL/Vulkan 切换，空串=默认（由 JavaLauncher 处理）
            @"graphics_api": @""
        }.mutableCopy,
        @"control": @{
            @"default_ctrl": @"default.json",
            @"control_safe_area": UIApplication.sharedApplication ? NSStringFromUIEdgeInsets(getDefaultSafeArea()) : @"",
            @"default_gamepad_ctrl": @"default.json",
            @"controller_type": @"xbox",
            @"hardware_hide": @YES,
            @"recording_hide": @YES,
            @"gesture_mouse": @YES,
            @"gesture_hotbar": @YES,
            @"disable_haptics": @NO,
            @"slideable_hotbar": @NO,
            @"press_duration": @(400),
            @"button_scale": @(100),
            @"mouse_scale": @(100),
            @"mouse_speed": @(100),
            @"virtmouse_enable": @NO,
            @"gyroscope_enable": @NO,
            @"gyroscope_invert_x_axis": @NO,
            @"gyroscope_sensitivity": @(100),
            @"mod_touch_enable": @NO,
            @"mod_touch_mode": @0,
            @"mod_touch_vibrate_enable": @YES,
            @"mod_touch_vibrate_intensity": @2,
            @"mod_touch_moveview_enable": @YES,
            // UI 子面板占位 key（LauncherPreferencesViewController 的 getPreference 回调
            // 会对每个设置项按 "section.key" 查询，包括 button/childPane 类型）。
            // 提供空串默认值避免触发 "Getter could not find preference control.custom_controls" 日志。
            @"custom_controls": @""
        }.mutableCopy,
        @"java": @{
            @"java_homes": @{
                @"0": @{
                    @"1_16_5_older": @"8",
                    @"1_17_newer": @"17",
                    @"execute_jar": @"8"
                }.mutableCopy,
                @"8": @"internal",
                @"17": @"internal",
                @"21": @"internal",
                @"25": @"internal"
            }.mutableCopy,
            @"java_args": @"",
            @"env_variables": @"",
            @"auto_ram": @(!getEntitlementValue(@"com.apple.private.memorystatus")),
            @"allocated_memory": [NSNumber numberWithFloat:roundf((NSProcessInfo.processInfo.physicalMemory / 1048576) * 0.25)],
            // profile 写入的强制 Java 版本，auto=根据游戏版本自动选择
            @"java_version": @"auto"
        }.mutableCopy,
        // MobileGlues 渲染器偏好
        // 当渲染器选择为 MobileGlues 或 Vulkan 时，由 init_loadMobileGluesConfig() 写入
        // <POJAV_HOME>/MG/config.json，控制 GL 版本、ANGLE 后端、FSR 等。
        // Vulkan 渲染器的 OpenGL 回退使用 MobileGlues（对齐 Ynnyny 仓库），设置生效。
        // Auto 渲染器实际使用 ANGLE，不会加载 MobileGlues，这些设置不生效。
        @"mobileglues": @{
            @"enable_angle": @NO,
            @"enable_no_error": @(0),
            @"enable_ext_timer_query": @YES,
            @"enable_ext_compute_shader": @NO,
            @"enable_ext_direct_state_access": @NO,
            @"max_glsl_cache_size": @(32),
            @"multidraw_mode": @(0),
            @"angle_depth_clear_fix_mode": @(0),
            @"custom_gl_version": @(0),
            @"fsr1_setting": @(0)
        }.mutableCopy,
        // 游戏内覆盖层（GameMenuOverlayView）的位置持久化与开关
        // 位置以屏幕宽高百分比存储（0.0~1.0），哨兵值 -1 表示未设置，
        // GameMenuOverlayView 的 restorePositions 会回退到硬编码默认位置。
        @"game": @{
            @"menu_button_x": @(-1.0),
            @"menu_button_y": @(-1.0),
            @"stats_label_x": @(-1.0),
            @"stats_label_y": @(-1.0),
            @"stats_label_visible": @YES
        }.mutableCopy,
        @"internal": @{
            @"isolated": @NO,
            @"latest_version": [NSDictionary new]
        }.mutableCopy
    }.mutableCopy;

    if (global) {
        // Preferences that cannot be isolated
        NSDictionary *general = @{
            @"game_directory": @"default",
            @"hidden_sidebar": @(realUIIdiom == UIUserInterfaceIdiomPhone),
            @"appicon": @"AppIcon-Light",
            @"ui_layout": @"vs",
            @"ui_theme": @"dark",
            // UI 壳双轨开关：legacy（旧壳，默认）/ engine（Lua 材质包引擎）
            @"ui_shell": @"legacy",
            @"multi_threaded": @NO,
            // 自定义外观颜色（hex 字符串，空串=使用默认深色毛玻璃/白色文字）
            @"text_color": @"",
            @"card_color": @"",
            // 主题强调色（hex 字符串，空串=回退到默认蓝 #429CF5，见 LauncherPreferences.m accentColor()）
            // 提供默认值避免每次访问触发 "Getter could not find preference general.accent_color" 日志
            @"accent_color": @"",
            // 可换肤主题包；主题资源位于 Bundle/themes 或 $POJAV_HOME/themes。
            @"theme_pack": @"pcl-classic"
        };
        [defaults[@"general"] addEntriesFromDictionary:general];

        defaults[@"java"][@"manage_runtime"] = @""; // stub
        defaults[@"debug"] = @{
            @"debug_universal_script_jit": @NO,
            @"debug_always_attached_jit": @NO,
            @"debug_skip_wait_jit": @NO,
            @"debug_hide_home_indicator": @NO,
            @"debug_ipad_ui": @(realUIIdiom == UIUserInterfaceIdiomPad),
            @"debug_auto_correction": @YES,
            @"debug_show_layout_bounds": @NO,
            @"debug_show_layout_overlap": @NO
        }.mutableCopy;
        defaults[@"warnings"] = @{
            @"local_warn": @YES,
            @"mem_warn": @YES,
            @"auto_ram_warn": @YES,
            @"limited_ram_warn": @YES
        }.mutableCopy;
        // TODO: isolate this or add account picker into profile editor(?)
        defaults[@"internal"][@"selected_account"] = @"";
    }

    return defaults;
}

+ (id)getPreference:(NSString *)key from:(NSDictionary *)pref {
    for (NSDictionary *section in pref.allValues) {
        if ([section isKindOfClass:NSDictionary.class] && section[key]) {
            return section[key];
        }
    }
    return nil;
}

+ (id)getOldLayoutPreference:(NSString *)key from:(NSDictionary *)pref {
    // Find preference in the root dictionary first
    if (pref[key]) {
        return pref[key];
    }
    // Find preference in subdictionaries
    id value = [self getPreference:key from:pref];
    if (!value) {
        NSLog(@"[PLPreferences] Migrator could not find preference %@", key);
    }
    return value;
}

- (id)initWithGlobalPath:(NSString *)path {
    self = [super init];
    self.globalPath = path;
    self.globalPref = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    [self saveGlobalPref];
    return self;
}

- (id)initWithAutomaticMigrator {
    self = [super init];
    self.globalPath = [@(getenv("POJAV_HOME")) stringByAppendingPathComponent:@"launcher_preferences_v2.plist"];
    NSMutableDictionary *pref = [NSMutableDictionary dictionaryWithContentsOfFile:self.globalPath];

    NSString *oldPath = [@(getenv("POJAV_HOME")) stringByAppendingPathComponent:@"launcher_preferences.plist"];
    NSMutableDictionary *oldPref = [NSMutableDictionary dictionaryWithContentsOfFile:oldPath];

    if (pref || !oldPref[@"env_vars"]) {
        // Initialize or load existing v2 layout
        self.globalPref = pref;
    } else {
        NSDebugLog(@"[PLPreferences] Migrating to %@", self.globalPath.lastPathComponent);
        // Perform migration from v1 layout
        self.globalPref = [NSMutableDictionary new];
        for (NSString *section in self.globalPref.allKeys) {
            for (NSString *key in self.globalPref[section].allKeys) {
                id value = [PLPreferences getOldLayoutPreference:key from:oldPref];
                if (value) {
                    self.globalPref[section][key] = value;
                }
            }
        }
    }

    [self saveGlobalPref];
    return self;
}

- (id)setDefaultsForPref:(NSMutableDictionary *)pref global:(BOOL)global {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *defaults = [PLPreferences defaultPrefForGlobal:global];
    if (!pref) {
        NSLog(@"[PLPreferences] Initializing default values for %@ preferences", global ? @"global" : @"isolated");
        return defaults;
    }

    for (NSString *section in defaults.allKeys) {
        if (!pref[section]) {
            NSDebugLog(@"[PLPreferences] Set default values for section %@", section);
            pref[section] = defaults[section];
            continue;
        }
        // 关键修复：从 plist 加载的嵌套字典是不可变 NSDictionary（NSMutableDictionary
        // dictionaryWithContentsOfFile: 只保证顶层可变，嵌套字典仍为 NSDictionary）。
        // 如果不转为 NSMutableDictionary，后续 setValue:forKeyPath: 调用会抛出异常，
        // 导致用户修改的设置无法保存（mobileglues、video 等所有 section 均受影响）。
        if (![pref[section] isKindOfClass:[NSMutableDictionary class]]) {
            pref[section] = [pref[section] mutableCopy];
        }
        for (NSString *key in defaults[section].allKeys) {
            if (pref[section][key]) continue;
            id value = defaults[section][key];
            NSDebugLog(@"[PLPreferences] Set default vaule: %@", key, value);
            pref[section][key] = value;
        }
    }
    return pref;
}

- (void)setGlobalPref:(NSMutableDictionary *)pref {
    _globalPref = [self setDefaultsForPref:pref global:YES];
}

- (void)setInstancePref:(NSMutableDictionary *)pref {
    _instancePref = [self setDefaultsForPref:pref global:NO];
}

- (void)toggleIsolationForced:(BOOL)force {
    NSMutableDictionary *instancePref = [NSMutableDictionary dictionaryWithContentsOfFile:self.instancePath];
    if (force || [instancePref[@"internal"][@"isolated"] boolValue]) {
        NSLog(@"[PLPreferences] Using isolated preferences from %@", self.instancePath.stringByResolvingSymlinksInPath);
        self.instancePref = instancePref;
        if (!instancePref) {
            // Copy preferences from the global one
            for (NSString *section in self.instancePref) {
                for (NSString *key in self.instancePref[section].allKeys) {
                    self.instancePref[section][key] = self.globalPref[section][key];
                }
            }
        }

        // Declare that itself is isolated
        self.instancePref[@"internal"][@"isolated"] = @YES;

        [self saveInstancePref];
    } else if (self.instancePref) {
        NSLog(@"[PLPreferences] Using global preferences");
        _instancePref = nil;
    }
}

- (id)getObject:(NSString *)key {
    id value = [self.instancePref valueForKeyPath:key];
    if (!value) {
        value = [self.globalPref valueForKeyPath:key];
    }
    if (!value) {
        NSLog(@"[PLPreferences] Getter could not find preference %@", key);
    }
    return value;
}

- (BOOL)setObject:(NSString *)key value:(id)value {
    if ([self.instancePref valueForKeyPath:key]) {
        [self.instancePref setValue:value forKeyPath:key];
        [self saveInstancePref];
        return YES;
    } else if ([self.globalPref valueForKeyPath:key]) {
        [self.globalPref setValue:value forKeyPath:key];
        [self saveGlobalPref];
        return YES;
    }
    NSLog(@"[PLPreferences] Setter could not find preference %@", key);
    return NO;
}

- (void)reset {
    if (self.instancePref) {
        [NSFileManager.defaultManager removeItemAtPath:self.instancePath error:nil];
        [self toggleIsolationForced:YES];
        // Only reset isolated values
        return;
    }

    self.globalPref = nil;
    [self saveGlobalPref];
}

- (void)saveGlobalPref {
    [self.globalPref writeToFile:self.globalPath atomically:YES];
}

- (void)saveInstancePref {
    [self.instancePref writeToFile:self.instancePath atomically:YES];
}

// 下载源管理（按类型独立持久化）
+ (NSString *)currentDownloadSourceForType:(NSString *)type {
    NSString *key = [self downloadSourceKeyForType:type];
    NSString *source = getPrefObject(key);
    return source ?: @"modrinth";
}

+ (void)setDownloadSource:(NSString *)source forType:(NSString *)type {
    NSString *key = [self downloadSourceKeyForType:type];
    setPrefObject(key, source);
}

+ (NSString *)downloadSourceKeyForType:(NSString *)type {
    if ([type isEqualToString:@"mod"]) return PREF_DOWNLOAD_SOURCE_MOD;
    if ([type isEqualToString:@"shader"]) return PREF_DOWNLOAD_SOURCE_SHADER;
    if ([type isEqualToString:@"resourcepack"]) return PREF_DOWNLOAD_SOURCE_RESOURCEPACK;
    if ([type isEqualToString:@"datapack"]) return PREF_DOWNLOAD_SOURCE_DATAPACK;
    if ([type isEqualToString:@"modpack"]) return PREF_DOWNLOAD_SOURCE_MODPACK;
    if ([type isEqualToString:@"world"]) return PREF_DOWNLOAD_SOURCE_WORLD;
    if ([type isEqualToString:@"server"]) return PREF_DOWNLOAD_SOURCE_SERVER;
    return PREF_DOWNLOAD_SOURCE_MOD;
}

// CurseForge API Key（运行时配置，覆盖编译时默认值）
+ (NSString *)curseForgeAPIKey {
    return getPrefObject(PREF_CURSEFORGE_API_KEY);
}

+ (void)setCurseForgeAPIKey:(NSString *)key {
    if (key && key.length > 0) {
        setPrefObject(PREF_CURSEFORGE_API_KEY, key);
    } else {
        // 注意：传 nil 会被 setValue:forKeyPath: 当作 remove，导致下次再写时
        // setObject:value: 因键不存在而静默失败。这里改写为空串以保留键。
        setPrefObject(PREF_CURSEFORGE_API_KEY, @"");
    }
}

// Mod 更新旧文件保留（默认 YES）
+ (BOOL)modUpdateKeepOld {
    NSNumber *value = getPrefObject(PREF_MOD_UPDATE_KEEP_OLD);
    return value ? value.boolValue : YES;
}

+ (void)setModUpdateKeepOld:(BOOL)keepOld {
    setPrefObject(PREF_MOD_UPDATE_KEEP_OLD, @(keepOld));
}

@end
