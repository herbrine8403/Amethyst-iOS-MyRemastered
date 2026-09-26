//
//  AiSettingsTools.m
//  Amethyst
//

#import "AiSettingsTools.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "utils.h"

@interface AiSettingsTools ()
@property (nonatomic, copy) NSString *internalName;
@end

@implementation AiSettingsTools

- (instancetype)initWithName:(NSString *)name {
    self = [super init];
    if (self) {
        _internalName = [name copy] ?: @"";
    }
    return self;
}

- (NSString *)name {
    return self.internalName;
}

- (AiToolPermission)permission {
    if ([self.internalName isEqualToString:@"set_setting"]) {
        return AiToolPermissionControlledWrite;
    }
    return AiToolPermissionReadOnly;
}

- (NSString *)summary {
    if ([self.internalName isEqualToString:@"list_settings"]) {
        return @"列出启动器支持的设置键与取值说明。"
               "\n无参数。"
               "\n返回键表：video.renderer（渲染器，实例级：auto/GL4ES/ANGLE/MobileGlues/Zink/MoltenVK/LTW）、"
               "video.graphics_api（图形 API，实例级，MC 26.2+ 生效：default/prefer_vulkan/prefer_opengl）、"
               "java.allocated_memory（游戏内存 MB，全局）、java.auto_ram（自动分配内存，全局，true/false）、"
               "java.java_args（JVM 参数，全局+实例级覆盖）、general.download_source（下载源，全局：official/bmclapi）、"
               "general.game_directory（当前游戏目录名，全局）、control.default_ctrl（默认控制布局，全局）。";
    }
    if ([self.internalName isEqualToString:@"get_setting"]) {
        return @"读取指定设置键的当前值。"
               "\n参数：key（string，必填，见 list_settings）、instance（string，可选，实例/profile 名，缺省当前选中实例）。"
               "\n返回：全局值 + 实例生效值（实例值优先于全局，实例未设置时回退全局）。";
    }
    // set_setting
    return @"修改启动器设置。"
           "\n参数：key（string，必填）、value（string/number/boolean，必填）、instance（string，可选，缺省修改当前选中实例或全局）。"
           "\n说明：video.renderer / video.graphics_api 为实例级设置（写入指定实例的 profile）；"
           "其余键为全局设置。渲染器可传友好名（MoltenVK/Zink/MobileGlues/GL4ES/ANGLE/auto），内部自动映射为存储键。"
           "\n写成功后返回新值并广播刷新通知。除 YOLO 模式外执行前会请求用户确认。";
}

#pragma mark - 键元数据

/// 实例级键 → profile 字段名
+ (NSDictionary<NSString *, NSString *> *)profileKeyMap {
    return @{
        @"video.renderer": @"renderer",
        @"video.graphics_api": @"graphicsApi",
        @"java.java_args": @"javaArgs",
    };
}

/// 渲染器友好名 → 存储键（getRendererKeys 的实际值）
+ (NSString *)rendererStorageKeyForValue:(NSString *)value {
    if (value.length == 0) return nil;
    NSString *lower = [value lowercaseString];
    // 传入的已是存储键（libxxx.dylib / auto）则原样返回
    NSArray *keys = getRendererKeys(NO);
    for (NSString *key in keys) {
        if ([key.lowercaseString isEqualToString:lower]) return key;
    }
    if ([lower isEqualToString:@"auto"] || [lower containsString:@"自动"]) return @"auto";
    if ([lower containsString:@"moltenvk"] || [lower containsString:@"vulkan"]) return @(RENDERER_NAME_VULKAN);
    if ([lower containsString:@"zink"] || [lower containsString:@"mesa"] || [lower containsString:@"osmesa"]) return @(RENDERER_NAME_VK_ZINK);
    if ([lower containsString:@"mobileglues"] || [lower isEqualToString:@"mg"]) return @(RENDERER_NAME_MOBILEGLUES);
    if ([lower containsString:@"angle"] || [lower containsString:@"tinygl4"]) return @(RENDERER_NAME_MTL_ANGLE);
    // 必须排在 angle 之后："MetalANGLE" 同样含 "metal" 子串
    if ([lower containsString:@"metallum"] || [lower containsString:@"metal"]) return @(RENDERER_NAME_METAL);
    if ([lower containsString:@"gl4es"]) return @(RENDERER_NAME_GL4ES);
    if ([lower containsString:@"ltw"]) return @(RENDERER_NAME_LTW);
    return nil;
}

/// 渲染器存储键 → 友好名（输出给 AI 看）
+ (NSString *)rendererFriendlyName:(NSString *)storageKey {
    if ([storageKey isEqualToString:@"auto"]) return @"auto";
    if ([storageKey isEqualToString:@(RENDERER_NAME_VULKAN)]) return @"MoltenVK (libMoltenVK.dylib)";
    if ([storageKey isEqualToString:@(RENDERER_NAME_VK_ZINK)]) return @"Zink (libOSMesa.8.dylib)";
    if ([storageKey isEqualToString:@(RENDERER_NAME_MOBILEGLUES)]) return @"MobileGlues (libmobileglues.dylib)";
    if ([storageKey isEqualToString:@(RENDERER_NAME_MTL_ANGLE)]) return @"ANGLE/MetalANGLE (libtinygl4angle.dylib)";
    if ([storageKey isEqualToString:@(RENDERER_NAME_GL4ES)]) return @"GL4ES (libgl4es_114.dylib)";
    if ([storageKey isEqualToString:@(RENDERER_NAME_METAL)]) return @"Metal (libmetallum.dylib)";
    if ([storageKey isEqualToString:@(RENDERER_NAME_LTW)]) return @"LTW (libltw.dylib)";
    return storageKey;
}

+ (NSString *)graphicsApiStorageKeyForValue:(NSString *)value {
    if (value.length == 0) return nil;
    NSString *lower = [value lowercaseString];
    if ([lower isEqualToString:@"default"] || [lower containsString:@"默认"]) return @"default";
    if ([lower containsString:@"vulkan"]) return @"prefer_vulkan";
    if ([lower containsString:@"opengl"] || [lower containsString:@"gl"]) return @"prefer_opengl";
    return nil;
}

/// 解析目标 profile 名（instance 参数优先，缺省当前选中）
+ (NSString *)profileNameForParams:(NSDictionary *)params {
    NSString *instance = [params[@"instance"] isKindOfClass:[NSString class]] ? params[@"instance"] : @"";
    if (instance.length > 0) return instance;
    NSString *name = [PLProfiles current].selectedProfileName;
    return name.length > 0 ? name : @"(Default)";
}

/// 目标 profile 字典（不存在时返回 nil）
+ (NSMutableDictionary *)profileDictionaryForName:(NSString *)profileName {
    NSDictionary *profiles = [PLProfiles current].profiles;
    if (![profiles isKindOfClass:[NSDictionary class]]) return nil;
    id prof = profiles[profileName];
    return [prof isKindOfClass:[NSMutableDictionary class]] ? prof : nil;
}

+ (NSString *)stringFromValue:(id)value {
    if (!value || [value isKindOfClass:[NSNull class]]) return @"（未设置）";
    if ([value isKindOfClass:[NSString class]]) return value;
    return [value description];
}

#pragma mark - 执行分发

- (void)execute:(NSDictionary<NSString *, id> *)params
     completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    if (!completion) return;

    if ([self.internalName isEqualToString:@"list_settings"]) {
        [self performListSettings:completion];
        return;
    }
    if ([self.internalName isEqualToString:@"get_setting"]) {
        [self performGetSetting:params completion:completion];
        return;
    }
    if ([self.internalName isEqualToString:@"set_setting"]) {
        [self performSetSetting:params completion:completion];
        return;
    }

    NSError *err = [NSError errorWithDomain:@"AiTool" code:404
                                   userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"未知工具 %@", self.internalName]}];
    completion(nil, err);
}

#pragma mark - list_settings

- (void)performListSettings:(void (^)(NSString *, NSError *))completion {
    NSDictionary *table = @{
        @"video.renderer": @{
            @"scope": @"实例级",
            @"values": @"auto / GL4ES / ANGLE(MetalANGLE) / MobileGlues / Zink / MoltenVK / LTW",
            @"note": @"渲染器。MC 26.2 遇 OpenGL 语法错误时切换为 MoltenVK；Iris 光影建议 Zink",
        },
        @"video.graphics_api": @{
            @"scope": @"实例级",
            @"values": @"default / prefer_vulkan / prefer_opengl",
            @"note": @"MC 26.2+（含 1.21.8+）游戏内图形 API 选择",
        },
        @"java.allocated_memory": @{
            @"scope": @"全局",
            @"values": @"整数（MB），如 2048",
            @"note": @"游戏分配内存；java.auto_ram 开启时由启动器自动决定",
        },
        @"java.auto_ram": @{
            @"scope": @"全局",
            @"values": @"true / false",
            @"note": @"自动分配内存",
        },
        @"java.java_args": @{
            @"scope": @"全局（实例可覆盖）",
            @"values": @"JVM 参数字符串，如 -XX:+UseG1GC",
            @"note": @"实例 profile 的 javaArgs 字段可覆盖全局值",
        },
        @"general.download_source": @{
            @"scope": @"全局",
            @"values": @"official / bmclapi",
            @"note": @"Minecraft 本体下载源（资源类走 Modrinth 自动兜底链）",
        },
        @"general.game_directory": @{
            @"scope": @"全局",
            @"values": @"实例目录名",
            @"note": @"当前游戏目录；新建实例请用 create_instance 工具，不建议直接改此键",
        },
        @"control.default_ctrl": @{
            @"scope": @"全局",
            @"values": @"控制布局文件名（不含扩展名）",
            @"note": @"默认触屏控制布局",
        },
    };

    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:table options:NSJSONWritingPrettyPrinted error:&jsonError];
    if (!data || jsonError) {
        completion(@"序列化设置表失败", nil);
        return;
    }
    completion([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding], nil);
}

#pragma mark - get_setting

- (void)performGetSetting:(NSDictionary *)params
              completion:(void (^)(NSString *, NSError *))completion {
    NSString *key = [params[@"key"] isKindOfClass:[NSString class]] ? params[@"key"] : @"";
    if (key.length == 0) {
        completion(nil, [NSError errorWithDomain:@"AiTool" code:400
                                     userInfo:@{NSLocalizedDescriptionKey: @"参数 key 必填"}]);
        return;
    }

    NSString *profileName = [AiSettingsTools profileNameForParams:params];
    NSString *profileField = [AiSettingsTools profileKeyMap][key];

    // 实例生效值：resolveKey 语义（实例值优先，回退全局）
    id effective = nil;
    if (profileField) {
        NSMutableDictionary *prof = [AiSettingsTools profileDictionaryForName:profileName];
        effective = [PLProfiles profile:prof resolveKey:profileField];
    }
    // 全局值
    id global = getPrefObject(key);

    NSString *globalDesc = [AiSettingsTools stringFromValue:global];
    if ([key isEqualToString:@"video.renderer"]) {
        globalDesc = [AiSettingsTools rendererFriendlyName:[AiSettingsTools stringFromValue:global]];
    }

    NSString *effectiveDesc = profileField ? [AiSettingsTools stringFromValue:effective] : globalDesc;
    if (profileField && [key isEqualToString:@"video.renderer"]) {
        effectiveDesc = [AiSettingsTools rendererFriendlyName:[AiSettingsTools stringFromValue:effective]];
    }

    completion([NSString stringWithFormat:
                @"key: %@\n全局值: %@\n实例生效值（%@）: %@\n当前游戏目录: %@",
                key, globalDesc, profileName, effectiveDesc,
                [AiSettingsTools stringFromValue:getPrefObject(@"general.game_directory")]], nil);
}

#pragma mark - set_setting

- (void)performSetSetting:(NSDictionary *)params
              completion:(void (^)(NSString *, NSError *))completion {
    NSString *key = [params[@"key"] isKindOfClass:[NSString class]] ? params[@"key"] : @"";
    id value = params[@"value"];
    if (key.length == 0 || value == nil || [value isKindOfClass:[NSNull class]]) {
        completion(nil, [NSError errorWithDomain:@"AiTool" code:400
                                     userInfo:@{NSLocalizedDescriptionKey: @"参数 key 与 value 必填"}]);
        return;
    }

    // ---- 实例级键：写入 profile ----
    NSString *profileField = [AiSettingsTools profileKeyMap][key];
    if (profileField) {
        NSString *storageValue = nil;
        if ([key isEqualToString:@"video.renderer"]) {
            storageValue = [AiSettingsTools rendererStorageKeyForValue:[AiSettingsTools stringFromValue:value]];
            if (!storageValue) {
                completion(nil, [NSError errorWithDomain:@"AiTool" code:400
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                 @"无效的渲染器取值；可选 auto/GL4ES/ANGLE/MobileGlues/Zink/MoltenVK/LTW"}]);
                return;
            }
        } else if ([key isEqualToString:@"video.graphics_api"]) {
            storageValue = [AiSettingsTools graphicsApiStorageKeyForValue:[AiSettingsTools stringFromValue:value]];
            if (!storageValue) {
                completion(nil, [NSError errorWithDomain:@"AiTool" code:400
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                 @"无效的图形 API 取值；可选 default/prefer_vulkan/prefer_opengl"}]);
                return;
            }
        } else {
            storageValue = [AiSettingsTools stringFromValue:value];
        }

        NSString *profileName = [AiSettingsTools profileNameForParams:params];
        NSMutableDictionary *prof = [AiSettingsTools profileDictionaryForName:profileName];
        if (!prof) {
            completion(nil, [NSError errorWithDomain:@"AiTool" code:404
                                         userInfo:@{NSLocalizedDescriptionKey:
                                             [NSString stringWithFormat:@"实例 %@ 不存在", profileName]}]);
            return;
        }

        // 深拷贝后写回并保存（避免直接改动共享字典引发竞态）
        NSMutableDictionary *mutable = [prof mutableCopy];
        mutable[profileField] = storageValue;
        [PLProfiles.current.profiles setObject:mutable forKey:profileName];
        [PLProfiles.current save];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];

        NSString *display = storageValue;
        if ([key isEqualToString:@"video.renderer"]) {
            display = [AiSettingsTools rendererFriendlyName:storageValue];
        }
        completion([NSString stringWithFormat:@"已将实例「%@」的 %@ 设置为 %@。",
                    profileName, key, display], nil);
        return;
    }

    // ---- 全局键：写入 LauncherPreferences ----
    if ([key isEqualToString:@"java.allocated_memory"]) {
        setPrefObject(@"java.allocated_memory", @([value integerValue]));
    } else if ([key isEqualToString:@"java.auto_ram"]) {
        NSString *desc = [value isKindOfClass:[NSString class]] ? (NSString *)value : [value description];
        BOOL on = [desc.lowercaseString hasPrefix:@"t"] || [desc isEqualToString:@"1"] || [desc isEqualToString:@"yes"];
        setPrefObject(@"java.auto_ram", @(on));
    } else if ([key isEqualToString:@"general.game_directory"]) {
        completion(nil, [NSError errorWithDomain:@"AiTool" code:400
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"不建议直接修改游戏目录键（涉及符号链接重建）；新建实例请用 create_instance 工具"}]);
        return;
    } else if ([key isEqualToString:@"general.download_source"] ||
               [key isEqualToString:@"java.java_args"] ||
               [key isEqualToString:@"control.default_ctrl"]) {
        setPrefObject(key, [AiSettingsTools stringFromValue:value]);
    } else {
        completion(nil, [NSError errorWithDomain:@"AiTool" code:400
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"不支持的设置键：%@（用 list_settings 查看可用键）", key]}]);
        return;
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
    completion([NSString stringWithFormat:@"已将全局 %@ 设置为 %@。", key, [AiSettingsTools stringFromValue:value]], nil);
}

@end
