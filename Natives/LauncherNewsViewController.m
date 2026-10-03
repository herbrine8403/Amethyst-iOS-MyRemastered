#import "LauncherNewsViewController.h"
#import "HomeCustomizeViewController.h"
#import "authenticator/BaseAuthenticator.h"
#import "LauncherPreferences.h"
#import "ModsManagerViewController.h"
#import "ShadersManagerViewController.h"
#import "ModpackImportViewController.h"
#import "VersionManagerViewController.h"   // ★ [FIX3] 版本管理快捷入口改「切标签 + 栈内定位」需要该类
#import "BackgroundSettingsViewController.h"
#import "BackgroundManager.h"
#import "PLProfiles.h"
#import "utils.h"
#import "ios_uikit_bridge.h"
#import "MinecraftNewsService.h"
#import "MinecraftNewsItem.h"
#import "MinecraftNewsViewController.h"
#import "AnnouncementService.h"
#import "AnnouncementItem.h"
#import "AnnouncementListViewController.h"
#import "IconLoader.h"
#import <SafariServices/SafariServices.h>
#import <QuartzCore/QuartzCore.h>
#import "UIKit+GlassSurface.h"   // ★ [HOME6] 液态玻璃四要素(运行时取 UIGlassEffect,不用 iOS26 编译期符号)
#import "LauncherRightPanelViewController.h"   // ★ [NORIGHT] 右栏状态广播 / 动作转发入口

// MARK: - Shortcut Action Constants

NSString * const kShortcutActionMods       = @"mods";
NSString * const kShortcutActionShaders    = @"shaders";
NSString * const kShortcutActionModpack    = @"modpack";
NSString * const kShortcutActionBackground = @"background";
NSString * const kShortcutActionVersions   = @"versions";

// MARK: - ★ [BENTO] 便当盒布局常量
// 主页磁贴从“一排等宽卡片”改成大小不一的便当盒拼贴。所有几何参数集中在这里。
static const CGFloat   kBentoGap        = 10.0;   // 格子之间的间距(横竖一致)
static const CGFloat   kBentoEdgeH      = 15.0;   // section 左右内边距(每个 item 再各留 gap/2 ⇒ 视觉边距 20)
static const CGFloat   kBentoEdgeV      = 6.0;    // section 上下内边距
static const CGFloat   kBentoSmallMin   = 84.0;   // 小格可见高度下限
static const CGFloat   kBentoSmallMax   = 124.0;  // 小格可见高度上限
static const CGFloat   kBentoMinRowH    = 96.0;   // 单格 section 的最小行高
static const CGFloat   kBentoWideWidth  = 700.0;  // ★ [HOME6] ≥ 此值 ⇒ 3 列(横屏≈844),否则 2 列(竖屏≈390)

// MARK: - ★ [HOME6] 卡片便当盒(⑥)常量
//   唯一设计依据:D:\hermes workplace\amethyst-air\_uiwork\home\home6.html
//   该稿 em 基准 = 真机 15pt ⇒ 下列 pt = 稿中 em × 15(逐条对应见 HOME6_REPORT.md ③)。
static const CGFloat   kHome6HeaderHeight    = 34.0;   // .c6 .chd padding .5em/.45em + 行高 ≈ 34(原 44)
static const CGFloat   kHome6HeaderPadH      = 13.0;   // .chd padding 左右 .85em(原 20)
static const CGFloat   kHome6HeaderTitleSize = 15.5;   // .c6 .chd .h1 font-size:1.02em(原 Title1≈28)
static const CGFloat   kHome6PillFontSize    = 10.0;   // .c6 .cus font-size:.64em
static const CGFloat   kHome6PillHeight      = 24.0;   // .c6 .cus padding .4em/.78em + 字形高
static const CGFloat   kHome6CardRadius      = 13.0;   // .c6 .bt border-radius:.9em(落 12~16 区间)
static const CGFloat   kHome6AccentWidth     = 3.5;    // .c6 .bt .acc width:.22em(左侧竖色条)
static const CGFloat   kHome6AccentInsetV    = 8.0;    // 色条上下留白,不贴卡片边

// ★ [HOME6] 卡片编排配置键(顺序 + 尺寸),存 NSUserDefaults。
//   结构 @[ @{@"id":@"profile", @"size":@2}, ... ]
//   ★ [SIZE4] size 码位(1-based):1=Small(1×1) 2=Wide(2×1) 3=Tall(1×2) 4=Large(2×2)。
//   旧数据只有 1/2 ⇒ 读回时 1⇒Small、2⇒Wide,与旧 Compact/Full 语义一致,不丢尺寸。
//   读取 ⇒ 主页卡片顺序与尺寸;未存过则写回默认(home6.html 的顺序)。
static NSString * const kAmeHomeCardLayoutKey = @"ameHomeCardLayout";

// ★ [HOMEWIRE] 自定义面板保存后广播的通知名:主页监听 ⇒ 重读 home_tiles_config + ameHomeCardLayout 并重排。
static NSString * const AmeHomeCardLayoutChangedNotification = @"AmeHomeCardLayoutChanged";

// ★ [NORIGHT] 主页底部「启动游戏」紧凑胶囊(右栏启动键搬家;用户明确:「大色块干掉」⇒
//   横竖屏都用紧凑胶囊,不再是整条大渐变底)。数值取自 mix.html 的竖屏 A 方案:
//   真机高 ≈32~36pt、胶囊圆角 = 高/2、淡底 + 细描边 + ▶ 图标。
static const CGFloat kNoRightCapsuleHeight = 36.0;
static const CGFloat kNoRightCapsuleMaxW   = 320.0;   // 横屏不要拉成整条 ⇒ 上限 320 居中

// ★ [TOPBAR2] 顶栏右侧动作 pill 排:JIT 状态 · 执行 Jar · 选择版本 · 下载中心 · ⚙自定义。
//   相邻 pill 的水平间距：横竖屏同一值 ⇒ 一条链式约束即可两朝向通用(无同属性双钉)。
static const CGFloat kTopBar2PillGap = 6.0;

// ★ [TOPBAR2] 顶栏动作 pill 的 tag ⇒ 各自转发到右栏 VC 的原方法(executeJar / showVersionPicker / openDownloadCenter)。
typedef NS_ENUM(NSInteger, TopBar2PillAction) {
    TopBar2PillActionExecuteJar     = 9501,   // ★ [TOPBAR2] → 右栏 executeJar
    TopBar2PillActionVersionPicker  = 9502,   // ★ [TOPBAR2] → 右栏 showVersionPicker
    TopBar2PillActionDownloadCenter = 9503,   // ★ [TOPBAR2] → 右栏 openDownloadCenter
};

// ★ [HOMEWIRE] 「唯一排版真相源」写入:由面板保存后的卡片数组反推「顺序 + 尺寸」写 ameHomeCardLayout。
//   只写 id 与 size 两个字段 —— 可见性 / 类型 / 图标 / 标题 / 颜色 / action 一律不碰(那些归 home_tiles_config)。
//   面板未提到的卡片由 configsByApplyingStoredBentoLayout: 按原顺序兜底追加,保证不漏卡。
// ★ [SIZE4-FIX] 前置声明:C 里 static 函数必须先声明后用。
//   这两个 helper 定义在下方(~152/163 行),但上面 AmeWriteBentoLayoutFromConfigs(~85 行)
//   就要用 ⇒ 不加前置声明会报 "call to undeclared function" + "static declaration follows non-static"。
static NSInteger AmeSizeCodeForTileSize(HomeTileSize size);
static HomeTileSize AmeTileSizeForSizeCode(NSInteger code);

// ★ [EDIT3] 白名单让位机制**整体删除**:长按卡片任意位置(含欢迎卡头像)一律归本页长按 ⇒ 进编辑模式。
//   头像的“自定义头像菜单”已搬到「账户管理」页(见 AccountListViewController.m 的 ★[EDIT3] 右键入口),
//   故这里不再需要任何“让位”判定;原先的 static 前置声明一并删除(函数已不存在,保留会报未定义)。

static void AmeWriteBentoLayoutFromConfigs(NSArray<HomeTileConfig *> *configs) {
    if (![configs isKindOfClass:[NSArray class]] || configs.count == 0) return;
    NSMutableArray<NSDictionary *> *layout = [NSMutableArray arrayWithCapacity:configs.count];
    for (HomeTileConfig *c in configs) {
        if (![c isKindOfClass:[HomeTileConfig class]]) continue;
        if (c.tileId.length == 0) continue;
        [layout addObject:@{@"id": c.tileId,
                            @"size": @(AmeSizeCodeForTileSize(c.tileSize))}];   // ★ [SIZE4] 1/2/3/4
    }
    if (layout.count == 0) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:layout forKey:kAmeHomeCardLayoutKey];
    [ud synchronize];
    NSLog(@"[HOMEWIRE] ameHomeCardLayout 已更新(%lu 张卡)", (unsigned long)layout.count);
}

// MARK: - ★ [SIZE4] 尺寸跨度 / 名称 / 码位 helper

/// ★ [SIZE4] 列跨度:1×1 与 1×2 占 1 列;2×1 与 2×2 占 2 列。
NSInteger AmeTileSpanColumns(HomeTileSize size) {
    switch (size) {
        case HomeTileSizeWide:
        case HomeTileSizeLarge: return 2;
        case HomeTileSizeSmall:
        case HomeTileSizeTall:
        default:                return 1;
    }
}

/// ★ [SIZE4] 行跨度:1×1 与 2×1 占 1 行;1×2 与 2×2 占 2 行。
NSInteger AmeTileSpanRows(HomeTileSize size) {
    switch (size) {
        case HomeTileSizeTall:
        case HomeTileSizeLarge: return 2;
        default:                return 1;
    }
}

/// ★ [SIZE4] 几何名(列×行,跨语言通用,不走本地化)。
NSString *AmeTileSizeShortName(HomeTileSize size) {
    switch (size) {
        case HomeTileSizeWide:  return @"2×1";
        case HomeTileSizeTall:  return @"1×2";
        case HomeTileSizeLarge: return @"2×2";
        case HomeTileSizeSmall:
        default:                return @"1×1";
    }
}

/// ★ [SIZE4] 显示名:尽量复用旧 key(2018/281 就是旧的 Compact/Full 名);Tall/Large 用新 key。
///   新 key 暂未写入 .strings(本任务只许改 .m/.h)⇒ 未命中时回退到英文兜底,避免界面出现原始 key。
NSString *AmeTileSizeDisplayName(HomeTileSize size) {
    NSString *fallback = nil;
    NSString *key = nil;
    switch (size) {
        case HomeTileSizeSmall: return localize(@"i18n_str_2018", nil);   // 旧 Compact 名:Half Width
        case HomeTileSizeWide:  return localize(@"i18n_str_281",  nil);   // 旧 Full 名:Full Width
        case HomeTileSizeTall:  key = @"i18n_str_9101"; fallback = @"Tall";  break;
        case HomeTileSizeLarge: key = @"i18n_str_9102"; fallback = @"Large"; break;
        default:                return localize(@"i18n_str_2018", nil);
    }
    NSString *localized = localize(key, nil);
    if (localized.length == 0 || [localized isEqualToString:key]) return fallback;
    return localized;
}

/// ★ [SIZE4] tileSize ⇒ ameHomeCardLayout 的 "size" 码位(1..4)。
static NSInteger AmeSizeCodeForTileSize(HomeTileSize size) {
    switch (size) {
        case HomeTileSizeSmall: return 1;
        case HomeTileSizeWide:  return 2;
        case HomeTileSizeTall:  return 3;
        case HomeTileSizeLarge: return 4;
        default:                return 1;
    }
}

/// ★ [SIZE4] "size" 码位 ⇒ tileSize;兼容旧值(1⇒Small,2⇒Wide),新增 3⇒Tall、4⇒Large,越界回退 Small。
static HomeTileSize AmeTileSizeForSizeCode(NSInteger code) {
    switch (code) {
        case 1:  return HomeTileSizeSmall;
        case 2:  return HomeTileSizeWide;
        case 3:  return HomeTileSizeTall;
        case 4:  return HomeTileSizeLarge;
        default: return HomeTileSizeSmall;
    }
}

// MARK: - Color Helpers

static UIColor *colorFromHex(NSString *hex) {
    hex = [hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    unsigned int rgb = 0;
    [[NSScanner scannerWithString:hex] scanHexInt:&rgb];
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

// MARK: - ★ [EDITMODE] 主页「长按进编辑 / 拖拽排序 / 拖把手改尺寸」常量与 helper

// 把手视觉边长(与 HomeTileBaseCell 里的把手保持同一数值)。
static const CGFloat kHomeEditHandleSize = 26.0;
// 把手的命中容差:手指比视觉大 ⇒ 命中矩形比视觉向外扩这么多(仍不足以误伤卡片中部)。
static const CGFloat kHomeEditHandleTouchSlop = 18.0;
// 改档阈值:拖动位移超过「当前卡宽/高的 30%(且不低于 24pt)」才换档,防抖。
static const CGFloat kHomeEditResizeThresholdRatio = 0.30;
static const CGFloat kHomeEditResizeThresholdMin   = 24.0;

// ★ [EDIT3] 让位白名单机制已删除(原为「命中 tag == kAmeHomeEditOwnLongPressTag 的控件
//   (欢迎卡头像)⇒ 本页长按让位」)。删除原因:长按头像不进编辑,与系统主屏
//   「长按任何图标都进编辑」不一致。头像自身的长按手势也已移除(见 HomeProfileTileCell
//   的 ★[EDIT3]),卡片上不再存在任何“自带长按”⇒ 本页长按在卡片任意位置(含头像)都能进编辑。
//   编辑态“不误触卡内控件”仍由 contentView.userInteractionEnabled 统一保证(未改动)。

// MARK: - HomeTileConfig Implementation

@implementation HomeTileConfig

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _tileId = [coder decodeObjectOfClass:[NSString class] forKey:@"tileId"];
        _tileType = [coder decodeIntegerForKey:@"tileType"];
        _tileSize = [coder decodeIntegerForKey:@"tileSize"];
        _visible = [coder decodeBoolForKey:@"visible"];
        _customTitle = [coder decodeObjectOfClass:[NSString class] forKey:@"customTitle"];
        _iconName = [coder decodeObjectOfClass:[NSString class] forKey:@"iconName"];
        _accentColorHex = [coder decodeObjectOfClass:[NSString class] forKey:@"accentColorHex"];
        _shortcutAction = [coder decodeObjectOfClass:[NSString class] forKey:@"shortcutAction"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:_tileId forKey:@"tileId"];
    [coder encodeInteger:_tileType forKey:@"tileType"];
    [coder encodeInteger:_tileSize forKey:@"tileSize"];
    [coder encodeBool:_visible forKey:@"visible"];
    [coder encodeObject:_customTitle forKey:@"customTitle"];
    [coder encodeObject:_iconName forKey:@"iconName"];
    [coder encodeObject:_accentColorHex forKey:@"accentColorHex"];
    [coder encodeObject:_shortcutAction forKey:@"shortcutAction"];
}

- (NSDictionary *)toDictionary {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (_tileId) dict[@"tileId"] = _tileId;
    dict[@"tileType"] = @(_tileType);
    dict[@"tileSize"] = @(_tileSize);
    dict[@"visible"] = @(_visible);
    if (_customTitle) dict[@"customTitle"] = _customTitle;
    if (_iconName) dict[@"iconName"] = _iconName;
    if (_accentColorHex) dict[@"accentColorHex"] = _accentColorHex;
    if (_shortcutAction) dict[@"shortcutAction"] = _shortcutAction;
    return dict;
}

+ (instancetype)fromDictionary:(NSDictionary *)dict {
    HomeTileConfig *config = [[HomeTileConfig alloc] init];
    config.tileId = dict[@"tileId"];
    config.tileType = [dict[@"tileType"] integerValue];
    config.tileSize = [dict[@"tileSize"] integerValue];
    config.visible = [dict[@"visible"] boolValue];
    config.customTitle = dict[@"customTitle"];
    config.iconName = dict[@"iconName"];
    config.accentColorHex = dict[@"accentColorHex"];
    config.shortcutAction = dict[@"shortcutAction"];
    return config;
}

- (UIColor *)accentColor {
    if (_accentColorHex) return colorFromHex(_accentColorHex);
    // 默认颜色基于磁贴类型
    switch (_tileType) {
        case HomeTileTypeProfile:        return colorFromHex(@"#8B5CF6");
        case HomeTileTypeAnnouncement:   return colorFromHex(@"#3B82F6");
        case HomeTileTypeVersionRelease: return colorFromHex(@"#10B981");
        case HomeTileTypeVersionSnapshot:return colorFromHex(@"#F59E0B");
        case HomeTileTypeNews:           return colorFromHex(@"#EF4444");
        case HomeTileTypeShortcut:       return colorFromHex(@"#14B8A6");
        default:                         return [UIColor systemBlueColor];
    }
}

+ (NSArray<HomeTileConfig *> *)defaultTileConfigs {
    NSMutableArray *tiles = [NSMutableArray array];
    
    // 0. 用户资料 (全宽)
    HomeTileConfig *profile = [[HomeTileConfig alloc] init];
    profile.tileId = @"profile";
    profile.tileType = HomeTileTypeProfile;
    profile.tileSize = HomeTileSizeFull;
    profile.visible = YES;
    profile.iconName = @"person.crop.circle.fill";
    profile.accentColorHex = @"#8B5CF6";
    [tiles addObject:profile];
    
    // 1. 公告 (全宽) — 位于版本信息之前
    HomeTileConfig *announcement = [[HomeTileConfig alloc] init];
    announcement.tileId = @"announcement";
    announcement.tileType = HomeTileTypeAnnouncement;
    announcement.tileSize = HomeTileSizeFull;
    announcement.visible = YES;
    announcement.iconName = @"megaphone.fill";
    announcement.accentColorHex = @"#3B82F6";
    [tiles addObject:announcement];
    
    // 2. 最新正式版 (半宽)
    HomeTileConfig *release = [[HomeTileConfig alloc] init];
    release.tileId = @"latest_release";
    release.tileType = HomeTileTypeVersionRelease;
    release.tileSize = HomeTileSizeCompact;
    release.visible = YES;
    release.iconName = @"cube.box.fill";
    release.accentColorHex = @"#10B981";
    [tiles addObject:release];
    
    // 3. 最新快照 (半宽)
    HomeTileConfig *snapshot = [[HomeTileConfig alloc] init];
    snapshot.tileId = @"latest_snapshot";
    snapshot.tileType = HomeTileTypeVersionSnapshot;
    snapshot.tileSize = HomeTileSizeCompact;
    snapshot.visible = YES;
    snapshot.iconName = @"ant.fill";
    snapshot.accentColorHex = @"#F59E0B";
    [tiles addObject:snapshot];
    
    // 4. 新闻 (全宽)
    HomeTileConfig *news = [[HomeTileConfig alloc] init];
    news.tileId = @"news";
    news.tileType = HomeTileTypeNews;
    news.tileSize = HomeTileSizeFull;
    news.visible = YES;
    news.iconName = @"newspaper.fill";
    news.accentColorHex = @"#EF4444";
    [tiles addObject:news];
    
    // 5. 快捷入口: Mod管理 (半宽)
    HomeTileConfig *mods = [[HomeTileConfig alloc] init];
    mods.tileId = @"shortcut_mods";
    mods.tileType = HomeTileTypeShortcut;
    mods.tileSize = HomeTileSizeCompact;
    mods.visible = YES;
    mods.customTitle = localize(@"i18n_str_275", nil);
    mods.iconName = @"puzzlepiece.extension.fill";
    mods.shortcutAction = kShortcutActionMods;
    mods.accentColorHex = @"#14B8A6";
    [tiles addObject:mods];
    
    // 6. 快捷入口: 光影管理 (半宽)
    HomeTileConfig *shaders = [[HomeTileConfig alloc] init];
    shaders.tileId = @"shortcut_shaders";
    shaders.tileType = HomeTileTypeShortcut;
    shaders.tileSize = HomeTileSizeCompact;
    shaders.visible = YES;
    shaders.customTitle = localize(@"i18n_str_2016", nil);
    shaders.iconName = @"sun.max.fill";
    shaders.shortcutAction = kShortcutActionShaders;
    shaders.accentColorHex = @"#F97316";
    [tiles addObject:shaders];
    
    // 7. 快捷入口: 整合包 (半宽)
    HomeTileConfig *modpack = [[HomeTileConfig alloc] init];
    modpack.tileId = @"shortcut_modpack";
    modpack.tileType = HomeTileTypeShortcut;
    modpack.tileSize = HomeTileSizeCompact;
    modpack.visible = YES;
    modpack.customTitle = localize(@"i18n_str_277", nil);
    modpack.iconName = @"shippingbox.fill";
    modpack.shortcutAction = kShortcutActionModpack;
    modpack.accentColorHex = @"#8B5CF6";
    [tiles addObject:modpack];
    
    // 8. 快捷入口: 壁纸设置 (半宽)
    HomeTileConfig *bg = [[HomeTileConfig alloc] init];
    bg.tileId = @"shortcut_bg";
    bg.tileType = HomeTileTypeShortcut;
    bg.tileSize = HomeTileSizeCompact;
    bg.visible = YES;
    bg.customTitle = localize(@"i18n_str_278", nil);
    bg.iconName = @"photo.fill.on.rectangle.fill";
    bg.shortcutAction = kShortcutActionBackground;
    bg.accentColorHex = @"#EC4899";
    [tiles addObject:bg];
    
    return tiles;
}

+ (NSArray<HomeTileConfig *> *)loadSavedConfigs {
    NSArray *savedArray = [[NSUserDefaults standardUserDefaults] objectForKey:@"home_tiles_config"];
    if (!savedArray || ![savedArray isKindOfClass:[NSArray class]]) {
        return [self defaultTileConfigs];
    }
    
    NSMutableArray *configs = [NSMutableArray array];
    for (NSDictionary *dict in savedArray) {
        if ([dict isKindOfClass:[NSDictionary class]]) {
            [configs addObject:[self fromDictionary:dict]];
        }
    }
    return configs.count > 0 ? configs : [self defaultTileConfigs];
}

+ (void)saveConfigs:(NSArray<HomeTileConfig *> *)configs {
    NSMutableArray *arr = [NSMutableArray array];
    for (HomeTileConfig *c in configs) {
        [arr addObject:[c toDictionary]];
    }
    [[NSUserDefaults standardUserDefaults] setObject:arr forKey:@"home_tiles_config"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end

// MARK: - Festival Detection

static NSString *festivalGreeting(void) {
    NSDate *now = [NSDate date];
    NSCalendar *gregorian = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    NSDateComponents *solar = [gregorian components:(NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:now];
    NSInteger month = solar.month;
    NSInteger day = solar.day;
    
    // 公历节日
    if (month == 1  && day == 1)  return localize(@"i18n_str_324", nil);
    if (month == 4  && (day >= 4 && day <= 6)) return localize(@"i18n_str_325", nil);
    if (month == 5  && day == 1)  return localize(@"i18n_str_326", nil);
    if (month == 6  && day == 1)  return localize(@"i18n_str_327", nil);
    if (month == 9  && day == 10) return localize(@"i18n_str_328", nil);
    if (month == 10 && (day >= 1 && day <= 7)) return localize(@"i18n_str_329", nil);
    if (month == 12 && day == 24) return localize(@"i18n_str_330", nil);
    if (month == 12 && day == 25) return localize(@"i18n_str_331", nil);
    
    // 农历节日 (使用中国日历)
    NSCalendar *chineseCalendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierChinese];
    NSDateComponents *lunar = [chineseCalendar components:(NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:now];
    NSInteger lunarMonth = lunar.month;
    NSInteger lunarDay = lunar.day;
    
    if (lunarMonth == 1  && lunarDay == 1)  return localize(@"i18n_str_332", nil);
    if (lunarMonth == 1  && lunarDay == 2)  return localize(@"i18n_str_333", nil);
    if (lunarMonth == 1  && lunarDay == 3)  return localize(@"i18n_str_334", nil);
    if (lunarMonth == 1  && lunarDay == 15) return localize(@"i18n_str_335", nil);
    if (lunarMonth == 5  && lunarDay == 5)  return localize(@"i18n_str_336", nil);
    if (lunarMonth == 7  && lunarDay == 7)  return localize(@"i18n_str_337", nil);
    if (lunarMonth == 8  && lunarDay == 15) return localize(@"i18n_str_338", nil);
    if (lunarMonth == 9  && lunarDay == 9)  return localize(@"i18n_str_339", nil);
    if (lunarMonth == 12 && (lunarDay == 29 || lunarDay == 30)) return localize(@"i18n_str_340", nil);
    
    // 非节日 - 按时段随机问候
    NSInteger hour = [gregorian component:NSCalendarUnitHour fromDate:now];
    if (hour < 6)       return localize(@"i18n_str_341", nil);
    if (hour < 12)      return localize(@"i18n_str_342", nil);
    if (hour < 14)      return localize(@"i18n_str_343", nil);
    if (hour < 18)      return localize(@"i18n_str_344", nil);
    return localize(@"i18n_str_345", nil);
}

// MARK: - HomeTileBaseCell

@interface HomeTileBaseCell : UICollectionViewCell
@property (nonatomic, strong) UIView *contentContainer;
@property (nonatomic, strong) CAGradientLayer *accentBar;
@property (nonatomic, strong) UIView *accentBarView;   // ★ [HOME6] 左侧竖色条载体(subview,不会被 blur 盖住)
// ★ [EDITMODE] 编辑模式右下角「改尺寸把手」:小圆角方块 + 双向箭头图标,默认隐藏。
@property (nonatomic, strong) UIView *homeEditHandleView;
// ★ [EDITMODE] 编辑态标记:编辑态不做按压缩放动画(避免与抖动/拖动抢 cell.transform)。
@property (nonatomic, assign) BOOL homeEditAppearanceOn;
- (void)setupBaseViews;
- (void)setAccentColor:(UIColor *)color;
/// ★ [EDITMODE] 编辑模式外观:显示/隐藏把手 + 轻微抖动(= iOS 主屏幕的“可编辑”提示)。
- (void)setHomeEditAppearance:(BOOL)editing;
/// ★ [EDIT2] 编辑态切换的唯一实现:animated=YES ⇒ 把手弹簧弹入/淡出 + 卡片一次轻微浮起;
///   复用复位等断言路径一律 animated=NO(硬复位,保证不残留)。
- (void)homeEditTransitionToEditing:(BOOL)editing animated:(BOOL)animated;
@end

@implementation HomeTileBaseCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupBaseViews];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleBackgroundUIEffectChanged)
                                                     name:@"BackgroundUIEffectChanged"
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleBackgroundUIEffectChanged {
    [[BackgroundManager sharedManager] applyEffectToCollectionViewCell:self];
    // ★ [HOME6] 背景观感/高光强度重刷后重新贴玻璃(幂等;用户把高光强度调到 0 时会自动摘掉)
    AmeAttachGlassRim(self, kHome6CardRadius);
    AmeRefreshGlassRim(self);
}

- (void)setupBaseViews {
    // ★ [HOME6] 便当盒玻璃卡:圆角照 home6 `.c6 .bt{border-radius:.9em}` ⇒ 13pt(12~16 区间)。
    //   圆角裁剪交给 contentView(保证 BackgroundManager 注入的 blur 圆角一致);
    //   描边 / 内高光 / 外阴影交给 cell 本身(AmeAttachGlassRim;外阴影需 masksToBounds=NO)。
    self.contentView.layer.cornerRadius = kHome6CardRadius;
    self.contentView.layer.cornerCurve = kCACornerCurveContinuous;
    self.contentView.layer.masksToBounds = YES;

    // 内容容器
    self.contentContainer = [[UIView alloc] initWithFrame:self.contentView.bounds];
    self.contentContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.contentContainer.backgroundColor = [UIColor clearColor];
    [self.contentView addSubview:self.contentContainer];

    // ★ [HOME6] 左侧竖向强调色条(home6 `.c6 .bt .acc{left:0;top:0;bottom:0;width:.22em}`)。
    //   原实现是「顶部 3pt 横条 + 挂在 contentView.layer 上」—— 会被 blur 子视图整条盖住(等于没画);
    //   这里改为 contentView 的 subview(层次在 blur 之上),颜色仍由 setAccentColor: 注入,不碰业务。
    self.accentBarView = [[UIView alloc] initWithFrame:CGRectZero];
    self.accentBarView.translatesAutoresizingMaskIntoConstraints = NO;
    self.accentBarView.userInteractionEnabled = NO;
    self.accentBarView.layer.cornerRadius = kHome6AccentWidth / 2.0;
    self.accentBarView.layer.cornerCurve = kCACornerCurveContinuous;
    self.accentBarView.layer.masksToBounds = YES;
    self.accentBar = [CAGradientLayer layer];
    self.accentBar.startPoint = CGPointMake(0.5, 0.0);   // ★ [HOME6] 竖向渐变(原 0,0.5→1,0.5 为横向)
    self.accentBar.endPoint   = CGPointMake(0.5, 1.0);
    [self.accentBarView.layer addSublayer:self.accentBar];
    [self.contentView addSubview:self.accentBarView];
    [NSLayoutConstraint activateConstraints:@[
        [self.accentBarView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [self.accentBarView.topAnchor     constraintEqualToAnchor:self.contentView.topAnchor constant:kHome6AccentInsetV],
        [self.accentBarView.bottomAnchor  constraintEqualToAnchor:self.contentView.bottomAnchor constant:-kHome6AccentInsetV],
        [self.accentBarView.widthAnchor   constraintEqualToConstant:kHome6AccentWidth],
    ]];

    // 背景效果(既有机制:用户在背景设置里选 毛玻璃 / 半透明 —— 不动)
    [[BackgroundManager sharedManager] applyEffectToCollectionViewCell:self];

    // ★ [HOME6] 玻璃四要素收尾:1px rim 描边 + 上缘内高光 + 外阴影。
    //   blur 由上面既有机制提供,**不**再叠第二层 UIVisualEffectView(避免双重模糊)。
    AmeAttachGlassRim(self, kHome6CardRadius);

    // ★ [EDITMODE] 改尺寸把手:必须在 applyEffectToCollectionViewCell: 之后加,
    //   否则会被 BackgroundManager 注入的 blur 子视图盖住(与 accentBarView 同一个坑)。
    //   位置:卡片右下角内缩 6pt;几何全部走约束 ⇒ 横竖屏 / 改档位后自动跟随,不硬摆 frame。
    self.homeEditHandleView = [[UIView alloc] initWithFrame:CGRectZero];
    self.homeEditHandleView.translatesAutoresizingMaskIntoConstraints = NO;
    self.homeEditHandleView.userInteractionEnabled = NO;   // 命中判定由主页 VC 自己做(单一手势源)
    self.homeEditHandleView.hidden = YES;
    self.homeEditHandleView.backgroundColor = [UIColor tertiarySystemFillColor];
    self.homeEditHandleView.layer.cornerRadius = kHomeEditHandleSize / 2.0;
    self.homeEditHandleView.layer.cornerCurve = kCACornerCurveContinuous;
    self.homeEditHandleView.layer.borderWidth = 1.0;
    self.homeEditHandleView.layer.borderColor = [UIColor separatorColor].CGColor;
    [self.contentView addSubview:self.homeEditHandleView];

    UIImageView *handleIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.left.and.arrow.down.right"]];
    handleIcon.translatesAutoresizingMaskIntoConstraints = NO;
    handleIcon.contentMode = UIViewContentModeScaleAspectFit;
    handleIcon.tintColor = [UIColor secondaryLabelColor];
    [self.homeEditHandleView addSubview:handleIcon];
    [NSLayoutConstraint activateConstraints:@[
        [self.homeEditHandleView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-6],
        [self.homeEditHandleView.bottomAnchor  constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6],
        [self.homeEditHandleView.widthAnchor  constraintEqualToConstant:kHomeEditHandleSize],
        [self.homeEditHandleView.heightAnchor constraintEqualToConstant:kHomeEditHandleSize],

        [handleIcon.centerXAnchor constraintEqualToAnchor:self.homeEditHandleView.centerXAnchor],
        [handleIcon.centerYAnchor constraintEqualToAnchor:self.homeEditHandleView.centerYAnchor],
        [handleIcon.widthAnchor  constraintEqualToConstant:14],
        [handleIcon.heightAnchor constraintEqualToConstant:14],
    ]];
}

/// ★ [EDITMODE] 编辑模式外观:把手显隐 + 轻微抖动(0.012 rad 往复,与 iOS 主屏幕同观感)。
///   抖动只加在 layer 的 transform.rotation 上;**编辑态同时关掉"按压缩放"动画**
///   (见 touchesBegan/Ended/Cancelled 的 homeEditAppearanceOn 守卫),
///   这样拖动/抖动期间不会有第二个人来写 cell.transform。
/// ★ [EDIT2] 默认(非动画)入口 = 硬复位,供 prepareForReuse / willDisplayCell 断言使用。
- (void)setHomeEditAppearance:(BOOL)editing {
    [self homeEditTransitionToEditing:editing animated:NO];
}

/// ★ [EDIT2] 编辑态切换(唯一实现):
///   · 进入且 animated:把手 0.5→1.0 弹簧弹入 + 卡片一次轻微浮起(1.0→1.022→1.0,回落原点 ⇒ 不留 transform);
///   · 退出且 animated:把手淡出 + 缩小,动画结束后才 hidden=YES(期间被复用由 prepareForReuse 兜底);
///   · animated=NO:一律立即 hidden 复位 —— 复用路径“不残留”的保证。
- (void)homeEditTransitionToEditing:(BOOL)editing animated:(BOOL)animated {
    self.homeEditAppearanceOn = editing;
    UIView *handle = self.homeEditHandleView;
    if (editing) {
        if (![self.layer animationForKey:@"ameHomeEditWiggle"]) {
            CABasicAnimation *wiggle = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
            wiggle.fromValue = @(-0.012);
            wiggle.toValue   = @(0.012);
            wiggle.duration  = 0.14;
            wiggle.autoreverses = YES;
            wiggle.repeatCount = HUGE_VALF;
            wiggle.beginTime = CACurrentMediaTime() + (double)(self.hash % 7) * 0.02;   // 错开相位,像主屏幕
            [self.layer addAnimation:wiggle forKey:@"ameHomeEditWiggle"];
        }
        [self.contentView bringSubviewToFront:handle];
        BOOL wasHidden = handle.hidden;
        handle.hidden = NO;
        if (animated && wasHidden) {
            // ★ [EDIT2] 把手弹簧弹入(不再硬出现)
            handle.alpha = 0.0;
            handle.transform = CGAffineTransformMakeScale(0.5, 0.5);
            [UIView animateWithDuration:0.30 delay:0 usingSpringWithDamping:0.68 initialSpringVelocity:0.7
                                options:(UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState)
                             animations:^{
                handle.alpha = 1.0;
                handle.transform = CGAffineTransformIdentity;
            } completion:nil];
        } else {
            handle.alpha = 1.0;
            handle.transform = CGAffineTransformIdentity;
        }
        if (animated) {
            // ★ [EDIT2] 像系统主屏进“抖动模式”:整块轻微浮起再落回(结束在 identity ⇒ 不与拖动抢 transform)
            [UIView animateWithDuration:0.16 delay:0
                                options:(UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState)
                             animations:^{
                self.transform = CGAffineTransformMakeScale(1.022, 1.022);
            } completion:^(BOOL finished) {
                if (!self.homeEditAppearanceOn) return;   // 期间被复用/已退出 ⇒ 不写 transform
                [UIView animateWithDuration:0.18 delay:0
                                    options:(UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut)
                                 animations:^{
                    self.transform = CGAffineTransformIdentity;
                } completion:nil];
            }];
        } else {
            self.transform = CGAffineTransformIdentity;
        }
    } else {
        [self.layer removeAnimationForKey:@"ameHomeEditWiggle"];
        self.transform = CGAffineTransformIdentity;
        if (handle.hidden) {
            handle.alpha = 1.0;
            handle.transform = CGAffineTransformIdentity;
        } else if (animated) {
            // ★ [EDIT2] 把手淡出,动画结束后才真正 hidden(不残留)
            [UIView animateWithDuration:0.18 delay:0
                                options:(UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState)
                             animations:^{
                handle.alpha = 0.0;
                handle.transform = CGAffineTransformMakeScale(0.6, 0.6);
            } completion:^(BOOL finished) {
                if (!self.homeEditAppearanceOn) { handle.hidden = YES; }
                handle.alpha = 1.0;
                handle.transform = CGAffineTransformIdentity;
            }];
        } else {
            handle.hidden = YES;
            handle.alpha = 1.0;
            handle.transform = CGAffineTransformIdentity;
        }
    }
}

/// ★ [EDIT2] 复用复位(修「退出编辑后右下角把手残留」的关键一环):
///   任何被回收的 cell 在再次出场前,必须把编辑态外观整体清零 ——
///   否则上一次的把手/抖动会跟着 cell 被带到下一张卡上。
- (void)prepareForReuse {
    [super prepareForReuse];
    [self homeEditTransitionToEditing:NO animated:NO];
    self.alpha = 1.0;
    self.contentView.userInteractionEnabled = YES;   // ★ [EDIT2] 编辑态写入的 NO 一并还原(状态泄漏的另一半)
}

- (void)setAccentColor:(UIColor *)color {
    CGFloat h, s, b, a;
    [color getHue:&h saturation:&s brightness:&b alpha:&a];
    UIColor *lighter = [UIColor colorWithHue:h saturation:s * 0.7 brightness:MIN(b * 1.3, 1.0) alpha:a];
    // ★ [HOME6] 色值不动,仅配合左侧竖色条(竖向渐变:上本色 → 下提亮)
    self.accentBar.colors = @[(id)color.CGColor, (id)lighter.CGColor];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // ★ [HOME6] 色条渐变跟随卡片尺寸;关掉隐式动画,避免旋转过程中渐变/阴影"飘"
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.accentBar.frame = self.accentBarView.bounds;
    [CATransaction commit];
    // ★ [HOME6] 尺寸变化后重算玻璃描边/内高光/阴影路径(否则外阴影残留旧路径)
    AmeRefreshGlassRim(self);
    // ★ [EDITMODE] 背景观感重刷(handleBackgroundUIEffectChanged)会重新注入 blur 子视图 ⇒
    //   每次都把编辑把手提到最上层,保证它不被盖住(幂等,零成本)。
    if (self.homeEditHandleView && !self.homeEditHandleView.hidden) {
        [self.contentView bringSubviewToFront:self.homeEditHandleView];
    }
}

/// ★ [EDIT2] 每次套用布局属性再兜一次:非编辑态把手必须不可见、无缩放残留。
///   复用残留的“最后一道闸”(prepareForReuse → willDisplayCell → applyLayoutAttributes)。
- (void)applyLayoutAttributes:(UICollectionViewLayoutAttributes *)layoutAttributes {
    [super applyLayoutAttributes:layoutAttributes];
    if (!self.homeEditAppearanceOn && self.homeEditHandleView) {
        self.homeEditHandleView.hidden = YES;
        self.homeEditHandleView.alpha = 1.0;
        self.homeEditHandleView.transform = CGAffineTransformIdentity;
    }
}

// 弹簧按压动画
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    // ★ [EDITMODE] 编辑态:不做按压缩放 —— 此刻 cell.transform 归拖动/抖动管,避免互相抢。
    if (self.homeEditAppearanceOn) return;
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.6 initialSpringVelocity:0.8 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform = CGAffineTransformMakeScale(0.96, 0.96);
    } completion:nil];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    if (self.homeEditAppearanceOn) return;   // ★ [EDITMODE]
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    if (self.homeEditAppearanceOn) return;   // ★ [EDITMODE]
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform = CGAffineTransformIdentity;
    } completion:nil];
}

@end

// MARK: - HomeProfileTileCell

@interface HomeProfileTileCell : HomeTileBaseCell
@property (nonatomic, strong) UIImageView *skinImageView;
@property (nonatomic, strong) UIImageView *avatarImageView;
@property (nonatomic, strong) UILabel *welcomeLabel;
@property (nonatomic, strong) UILabel *greetingLabel;
@property (nonatomic, strong) UILabel *versionLabel;   // ★ [NORIGHT] 右栏版本号搬进本卡
@end

@implementation HomeProfileTileCell

- (void)setupBaseViews {
    [super setupBaseViews];
    
    // 皮肤全身预览
    self.skinImageView = [[UIImageView alloc] init];
    self.skinImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.skinImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.skinImageView.layer.shadowColor = [UIColor blackColor].CGColor;
    self.skinImageView.layer.shadowOffset = CGSizeMake(2, 4);
    self.skinImageView.layer.shadowOpacity = 0.35;
    self.skinImageView.layer.shadowRadius = 6;
    [self.contentContainer addSubview:self.skinImageView];
    
    // 头像 (圆形)
    self.avatarImageView = [[UIImageView alloc] init];
    self.avatarImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.avatarImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.avatarImageView.layer.cornerRadius = 26;
    self.avatarImageView.layer.masksToBounds = YES;
    self.avatarImageView.layer.borderWidth = 2.5;
    self.avatarImageView.layer.borderColor = [UIColor separatorColor].CGColor;
    self.avatarImageView.backgroundColor = [UIColor tertiarySystemFillColor];
    self.avatarImageView.image = [UIImage systemImageNamed:@"person.circle.fill"];
    self.avatarImageView.tintColor = [UIColor systemGrayColor];
    // ★ [NORIGHT] 头像可交互:右栏头像的行为随头像一起搬过来 ——
    //   点 = 账户管理(selectAccount:)。
    //   ★ [EDIT3] 长按 = 已改:不再弹自定义头像菜单(让位给“长按进编辑”),菜单移到账户管理页。
    //   本卡只转发通知,不复制任何逻辑。
    self.avatarImageView.userInteractionEnabled = YES;
    // ★ [EDIT3] 头像只保留「单击 = 账户管理」。
    //   ① 原白名单 tag(kAmeHomeEditOwnLongPressTag)删除 ⇒ 长按头像与长按卡片其它位置一样,
    //      归本页长按 ⇒ 直接进编辑模式(与系统主屏一致);
    //   ② 头像自带的 UILongPress(旧入口:自定义头像导入/清除菜单)删除 ⇒ 不再与本页长按双触发。
    //      该菜单改由「账户管理」页的「自定义头像」按钮触发(AccountListViewController.m ★[EDIT3])。
    [self.avatarImageView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(norightAvatarTapped)]];
    [self.contentContainer addSubview:self.avatarImageView];
    
    // 欢迎文本
    self.welcomeLabel = [[UILabel alloc] init];
    self.welcomeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.welcomeLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    self.welcomeLabel.textColor = [UIColor labelColor];
    self.welcomeLabel.numberOfLines = 1;
    self.welcomeLabel.adjustsFontSizeToFitWidth = YES;
    self.welcomeLabel.minimumScaleFactor = 0.7;
    [self.contentContainer addSubview:self.welcomeLabel];
    
    // 节日/时段问候
    self.greetingLabel = [[UILabel alloc] init];
    self.greetingLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.greetingLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.greetingLabel.textColor = [UIColor secondaryLabelColor];
    self.greetingLabel.numberOfLines = 1;
    [self.contentContainer addSubview:self.greetingLabel];

    // ★ [NORIGHT] 版本号从右栏搬进「欢迎回来」卡(用户:头像 + 用户名 + 版本号 → 主页欢迎卡)。
    //   文本仍由右栏 updateVersionInfo 决定(含版本隔离文案 i18n_str_440),经
    //   AmeRightPanelStateNotification 同步过来 ⇒ 显示口径与右栏完全一致。
    self.versionLabel = [[UILabel alloc] init];
    self.versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
    self.versionLabel.textColor = [UIColor secondaryLabelColor];
    self.versionLabel.textAlignment = NSTextAlignmentCenter;
    self.versionLabel.layer.cornerRadius = 10.0;
    self.versionLabel.layer.cornerCurve = kCACornerCurveContinuous;
    self.versionLabel.layer.masksToBounds = YES;
    self.versionLabel.backgroundColor = [UIColor tertiarySystemFillColor];
    self.versionLabel.hidden = YES;   // 未拿到版本号前不占视觉
    [self.contentContainer addSubview:self.versionLabel];

    [NSLayoutConstraint activateConstraints:@[
        // 皮肤预览 (左侧)
        [self.skinImageView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:18],
        [self.skinImageView.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:10],
        [self.skinImageView.bottomAnchor constraintEqualToAnchor:self.contentContainer.bottomAnchor constant:-8],
        [self.skinImageView.widthAnchor constraintEqualToAnchor:self.skinImageView.heightAnchor multiplier:0.55],
        
        // 头像 (皮肤右侧)
        [self.avatarImageView.leadingAnchor constraintEqualToAnchor:self.skinImageView.trailingAnchor constant:18],
        [self.avatarImageView.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor constant:-14],
        [self.avatarImageView.widthAnchor constraintEqualToConstant:52],
        [self.avatarImageView.heightAnchor constraintEqualToConstant:52],
        
        // 欢迎文本
        [self.welcomeLabel.leadingAnchor constraintEqualToAnchor:self.avatarImageView.trailingAnchor constant:14],
        [self.welcomeLabel.centerYAnchor constraintEqualToAnchor:self.avatarImageView.centerYAnchor constant:-10],
        [self.welcomeLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-18],
        
        // 问候语
        [self.greetingLabel.leadingAnchor constraintEqualToAnchor:self.welcomeLabel.leadingAnchor],
        [self.greetingLabel.topAnchor constraintEqualToAnchor:self.welcomeLabel.bottomAnchor constant:4],
        [self.greetingLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-18],

        // ★ [NORIGHT] 版本号 pill(欢迎卡内、问候语下方;左对齐欢迎语、高度 20)
        [self.versionLabel.leadingAnchor constraintEqualToAnchor:self.welcomeLabel.leadingAnchor],
        [self.versionLabel.topAnchor constraintEqualToAnchor:self.greetingLabel.bottomAnchor constant:6],
        [self.versionLabel.heightAnchor constraintEqualToConstant:20],
        [self.versionLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentContainer.trailingAnchor constant:-18],
    ]];
}

// ★ [NORIGHT] 头像单击 ⇒ 账户管理(转发右栏原实现)
// ★ [EDIT3] 头像长按处理 `norightAvatarLongPressed:` 已删除 —— 头像长按不再弹自定义头像菜单,
//   而是与卡片其他位置一致,由本页长按直接进入编辑模式。
//   该菜单的新入口在「账户管理」页(见 AccountListViewController.m ★[EDIT3] 的「自定义头像」右键)。
- (void)norightAvatarTapped {
    [LauncherRightPanelViewController norightPostAction:@"accountManager"];
}

@end

// MARK: - HomeInfoTileCell

@interface HomeInfoTileCell : HomeTileBaseCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@end

@implementation HomeInfoTileCell

- (void)setupBaseViews {
    [super setupBaseViews];
    
    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.tintColor = [UIColor systemGreenColor];
    [self.contentContainer addSubview:self.iconView];
    
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    self.titleLabel.textColor = [UIColor tertiaryLabelColor];
    self.titleLabel.textAlignment = NSTextAlignmentLeft;
    [self.contentContainer addSubview:self.titleLabel];
    
    self.valueLabel = [[UILabel alloc] init];
    self.valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.valueLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle3];
    self.valueLabel.textColor = [UIColor labelColor];
    self.valueLabel.numberOfLines = 2;
    self.valueLabel.adjustsFontSizeToFitWidth = YES;
    self.valueLabel.minimumScaleFactor = 0.6;
    [self.contentContainer addSubview:self.valueLabel];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:18],
        [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:16],
        [self.iconView.widthAnchor constraintEqualToConstant:26],
        [self.iconView.heightAnchor constraintEqualToConstant:26],
        
        [self.titleLabel.centerYAnchor constraintEqualToAnchor:self.iconView.centerYAnchor],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:8],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-16],
        
        [self.valueLabel.topAnchor constraintEqualToAnchor:self.iconView.bottomAnchor constant:10],
        [self.valueLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:16],
        [self.valueLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-16],
    ]];
}

@end

// MARK: - HomeAnnouncementTileCell

@interface HomeAnnouncementTileCell : HomeTileBaseCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UIButton *actionButton;
@end

@implementation HomeAnnouncementTileCell

- (void)setupBaseViews {
    [super setupBaseViews];
    
    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.image = [UIImage systemImageNamed:@"megaphone.fill"];
    self.iconView.tintColor = colorFromHex(@"#3B82F6");
    [self.contentContainer addSubview:self.iconView];
    
    self.messageLabel = [[UILabel alloc] init];
    self.messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.messageLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.messageLabel.textColor = [UIColor labelColor];
    self.messageLabel.numberOfLines = 0;
    [self.contentContainer addSubview:self.messageLabel];
    
    self.actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.actionButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.actionButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.actionButton.layer.cornerRadius = 8;
    self.actionButton.layer.cornerCurve = kCACornerCurveContinuous;
    self.actionButton.clipsToBounds = YES;
    self.actionButton.hidden = YES;
    [self.contentContainer addSubview:self.actionButton];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:16],
        [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:16],
        [self.iconView.widthAnchor constraintEqualToConstant:22],
        [self.iconView.heightAnchor constraintEqualToConstant:22],
        
        [self.messageLabel.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:16],
        [self.messageLabel.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:10],
        [self.messageLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-16],
        
        [self.actionButton.topAnchor constraintEqualToAnchor:self.messageLabel.bottomAnchor constant:10],
        [self.actionButton.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:16],
        [self.actionButton.widthAnchor constraintEqualToConstant:100],
        [self.actionButton.heightAnchor constraintEqualToConstant:30],
    ]];
}

@end

// MARK: - HomeNewsTileCell

@interface HomeNewsTileCell : HomeTileBaseCell
@property (nonatomic, strong) UIImageView *thumbnailView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *summaryLabel;
@property (nonatomic, strong) UILabel *placeholderLabel;
@end

@implementation HomeNewsTileCell

- (void)setupBaseViews {
    [super setupBaseViews];
    
    // 左侧缩略图占位
    self.thumbnailView = [[UIImageView alloc] init];
    self.thumbnailView.translatesAutoresizingMaskIntoConstraints = NO;
    self.thumbnailView.contentMode = UIViewContentModeScaleAspectFill;
    self.thumbnailView.clipsToBounds = YES;
    self.thumbnailView.layer.cornerRadius = 10;
    self.thumbnailView.layer.cornerCurve = kCACornerCurveContinuous;
    self.thumbnailView.backgroundColor = [UIColor tertiarySystemFillColor];
    self.thumbnailView.image = [UIImage systemImageNamed:@"newspaper.fill"];
    self.thumbnailView.tintColor = [UIColor tertiaryLabelColor];
    [self.contentContainer addSubview:self.thumbnailView];
    
    // 标题
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.titleLabel.textColor = [UIColor labelColor];
    self.titleLabel.numberOfLines = 2;
    [self.contentContainer addSubview:self.titleLabel];
    
    // 摘要
    self.summaryLabel = [[UILabel alloc] init];
    self.summaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    self.summaryLabel.textColor = [UIColor tertiaryLabelColor];
    self.summaryLabel.numberOfLines = 2;
    [self.contentContainer addSubview:self.summaryLabel];
    
    // 占位提示
    self.placeholderLabel = [[UILabel alloc] init];
    self.placeholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.placeholderLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
    self.placeholderLabel.textColor = [UIColor quaternaryLabelColor];
    self.placeholderLabel.text = localize(@"i18n_str_346", nil);
    [self.contentContainer addSubview:self.placeholderLabel];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.thumbnailView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:14],
        [self.thumbnailView.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.thumbnailView.widthAnchor constraintEqualToConstant:80],
        [self.thumbnailView.heightAnchor constraintEqualToConstant:60],
        
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.thumbnailView.topAnchor],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.thumbnailView.trailingAnchor constant:14],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-14],
        
        [self.summaryLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:4],
        [self.summaryLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.summaryLabel.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],
        
        [self.placeholderLabel.bottomAnchor constraintEqualToAnchor:self.thumbnailView.bottomAnchor],
        [self.placeholderLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-14],
    ]];
}

@end

// MARK: - HomeShortcutTileCell

@interface HomeShortcutTileCell : HomeTileBaseCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIImageView *chevronView;
@end

@implementation HomeShortcutTileCell

- (void)setupBaseViews {
    [super setupBaseViews];
    
    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.tintColor = [UIColor systemTealColor];
    [self.contentContainer addSubview:self.iconView];
    
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.titleLabel.textColor = [UIColor labelColor];
    self.titleLabel.numberOfLines = 1;
    self.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.titleLabel.minimumScaleFactor = 0.7;
    [self.contentContainer addSubview:self.titleLabel];
    
    self.chevronView = [[UIImageView alloc] init];
    self.chevronView.translatesAutoresizingMaskIntoConstraints = NO;
    self.chevronView.contentMode = UIViewContentModeScaleAspectFit;
    self.chevronView.image = [UIImage systemImageNamed:@"chevron.right"];
    self.chevronView.tintColor = [UIColor tertiaryLabelColor];
    [self.contentContainer addSubview:self.chevronView];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:16],
        [self.iconView.widthAnchor constraintEqualToConstant:28],
        [self.iconView.heightAnchor constraintEqualToConstant:28],
        
        [self.titleLabel.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:12],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.chevronView.leadingAnchor constant:-8],
        
        [self.chevronView.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.chevronView.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-14],
        [self.chevronView.widthAnchor constraintEqualToConstant:12],
        [self.chevronView.heightAnchor constraintEqualToConstant:16],
    ]];
}

@end

// MARK: - LauncherNewsViewController

@interface LauncherNewsViewController () <UICollectionViewDataSource, UICollectionViewDelegate, UIGestureRecognizerDelegate>   // ★ [EDIT2] 手势代理

@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) UILabel *headerTitleLabel;
@property (nonatomic, strong) UIButton *customizeButton;

// ★ [HOME6] 两套头部约束集(竖/横),同一属性只被一套钉住
@property (nonatomic, strong) NSArray<NSLayoutConstraint *> *headerPortraitConstraints;
@property (nonatomic, strong) NSArray<NSLayoutConstraint *> *headerLandscapeConstraints;
@property (nonatomic, assign) BOOL homeUIWasLandscape;      // ★ [HOME6] 朝向去抖
@property (nonatomic, assign) UIEdgeInsets homeSafeInsets;  // ★ [HOME6] 实时安全区(布局 provider 读取)

// 磁贴配置
@property (nonatomic, strong) NSMutableArray<HomeTileConfig *> *allTileConfigs;
@property (nonatomic, strong) NSArray<NSArray<HomeTileConfig *> *> *displaySections;

// 数据
@property (nonatomic, strong) NSString *latestRelease;
@property (nonatomic, strong) NSString *latestSnapshot;
@property (nonatomic, strong) NSString *currentUsername;
@property (nonatomic, strong) UIImage *currentSkin;
@property (nonatomic, strong) UIImage *currentAvatar;
@property (nonatomic, assign) BOOL isLoadingVersions;

// 公告/更新检测
@property (nonatomic, strong) NSString *announcementText;
@property (nonatomic, assign) BOOL hasUpdate;
@property (nonatomic, strong) NSString *latestVersion;
// 公告系统（从官网拉取 JSON 的最新一条公告）
@property (nonatomic, strong, nullable) AnnouncementItem *latestAnnouncement;

// MC 新闻（首页 News tile 预览用，展示最新一条）
@property (nonatomic, strong, nullable) MinecraftNewsItem *latestNewsItem;
@property (nonatomic, assign) BOOL isLoadingNews;

// ★ [NORIGHT] 右栏卡片下线后的三个新入口(+ 状态镜像)
@property (nonatomic, strong) UILabel *norightJITPill;          // 顶栏右侧 JIT 状态 pill(「⚙自定义」左侧)
@property (nonatomic, strong) UIButton *norightLaunchCapsule;   // 主页底部「启动游戏」紧凑胶囊
@property (nonatomic, strong) NSLayoutConstraint *norightCapsuleWidth;
@property (nonatomic, copy)   NSString *norightVersionText;     // 欢迎卡里的版本号(来自右栏状态广播)

// ★ [TOPBAR2] 顶栏动作 pill 排(JIT 状态侧边;JIT pill 本身仍是 norightJITPill)。
//   三个动作 pill 全部只转发右栏原方法;下载中心的角标/百分比来自 AmeRightPanelStateNotification。
@property (nonatomic, strong) UIButton *topbarExecuteJarPill;       // ★ [TOPBAR2] → 右栏 executeJar
@property (nonatomic, strong) UIButton *topbarVersionPickerPill;    // ★ [TOPBAR2] → 右栏 showVersionPicker
@property (nonatomic, strong) UIButton *topbarDownloadCenterPill;   // ★ [TOPBAR2] → 右栏 openDownloadCenter
@property (nonatomic, strong) UILabel  *topbarDownloadBadgeLabel;   // ★ [TOPBAR2] 进行中任务数角标(红)
@property (nonatomic, copy)   NSString *topbarDownloadBadgeText;    // ★ [TOPBAR2] 角标数字(来自右栏广播)
@property (nonatomic, copy)   NSString *topbarDownloadProgressText; // ★ [TOPBAR2] 百分比/状态文案(来自右栏广播)
@property (nonatomic, assign) BOOL      topbarDownloadActive;       // ★ [TOPBAR2] 是否有下载任务(决定是否展示百分比)

// ★ [SIZE4] 四档跨度布局 helper(前置声明,消除定义顺序依赖)
- (CGFloat)bentoBaseUnitHeightForTileType:(HomeTileType)type;
- (CGFloat)heightForTileConfig:(HomeTileConfig *)config;
- (CGFloat)bentoRowUnitForTiles:(NSArray<HomeTileConfig *> *)tiles;
- (NSCollectionLayoutSection *)bentoSectionForTiles:(NSArray<HomeTileConfig *> *)tiles cols:(NSInteger)cols;

// ★ [FIX2] 快捷入口改「切标签 + 在该标签自己的导航栈 push」的助手(前置声明,消除定义顺序依赖)。
- (BOOL)fix2PushTab:(NSInteger)tabIndex
             pushes:(Class)vcClass
             makeVC:(UIViewController * (^)(void))makeVC;

// ★ [EDITMODE] 主页直接编辑(像 iOS 小组件):长按进编辑 → 拖拽排序 + 右下角把手拖动改四档尺寸。
//   全部走 UICollectionView 自带交互(UICollectionViewDataSource 的
//   canMoveItemAtIndexPath: / moveItemAtIndexPath:toIndexPath: + begin/update/endInteractiveMovement),
//   几何仍由 compositional layout 计算 ⇒ 不硬摆 frame、横竖屏都成立。
@property (nonatomic, strong) UILongPressGestureRecognizer *homeEditLongPress;
@property (nonatomic, strong) UIButton *homeEditDoneButton;     // 顶栏「✓ 完成」(编辑模式出口)
@property (nonatomic, assign) BOOL      homeEditing;            // 是否处于编辑模式
@property (nonatomic, assign) BOOL      homeMoveActive;         // 正在拖拽排序(interactive movement)
@property (nonatomic, assign) BOOL      homeResizeActive;       // 正在拖把手改尺寸
@property (nonatomic, assign) NSInteger homeResizeIndex;        // 改尺寸中的卡片序号(单 section ⇒ item 即序号)
@property (nonatomic, assign) CGPoint   homeResizeStartPoint;   // 本次改尺寸的起点(collectionView 坐标)
@property (nonatomic, assign) HomeTileSize homeResizeStartSize; // 本次改尺寸的起始档位(阈值以此为准)
// ★ [EDIT2] 编辑态「点空白退出」手势(仅在编辑模式接收触屏,非编辑态零介入)。
@property (nonatomic, strong) UITapGestureRecognizer *homeEditBlankTap;

// ★ [EDITMODE] 前置声明(方法定义在文件下方,消除定义顺序依赖 —— 与 SIZE4 helper 同一约定)。
- (void)homeEditLongPressed:(UILongPressGestureRecognizer *)gesture;
- (void)homeEditEnter;
- (void)homeEditDoneTapped;
- (void)homeEditApplyAppearanceToVisibleCells;
- (void)homeEditApplyAppearanceToCell:(UICollectionViewCell *)cell;
// ★ [EDIT2] 动画版外观切换 + 点空白退出(前置声明,消除定义顺序依赖)
- (void)homeEditApplyAppearanceToVisibleCellsAnimated:(BOOL)animated;
- (void)homeEditApplyAppearanceToCell:(UICollectionViewCell *)cell animated:(BOOL)animated;
- (void)homeEditBlankTapped:(UITapGestureRecognizer *)gesture;
- (void)homeEditSetHeaderChromeHidden:(BOOL)hidden;
- (BOOL)homeEditPoint:(CGPoint)point hitsResizeHandleOfIndex:(NSInteger *)outIndex;
- (void)homeEditUpdateResizeAtPoint:(CGPoint)point;
- (void)homeEditRebuildAllConfigsFromVisibleOrder;
- (void)homeEditPersistLayout;

@end

@implementation LauncherNewsViewController

- (id)init {
    self = [super init];
    if (self) {
        // 不设置 self.title，避免顶部导航栏出现"主页"标题黑条（参照 FCL 无 title 风格）
        self.latestRelease = localize(@"i18n_str_347", nil);
        self.latestSnapshot = localize(@"i18n_str_347", nil);
        self.isLoadingVersions = YES;
        self.announcementText = localize(@"i18n_str_348", nil);
        self.hasUpdate = NO;
        // ★ [EDIT2] 编辑态显式初始化为「非编辑」——首次长按即可直接进编辑,
        //   不依赖“先点一次 ✓ 完成”把状态掰回来(上一版状态没显式收口)。
        self.homeEditing = NO;
        self.homeMoveActive = NO;
        self.homeResizeActive = NO;
        self.homeResizeIndex = -1;
    }
    return self;
}

- (NSString *)imageName {
    return @"MenuNews";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor clearColor];
    self.navigationController.navigationBarHidden = YES;
    
    // 加载磁贴配置
    self.allTileConfigs = [[HomeTileConfig loadSavedConfigs] mutableCopy];
    // ★ [HOME6] 按 ameHomeCardLayout(顺序 + 尺寸)重排;未存过则写回默认(等价 home6.html 默认布局)。
    self.allTileConfigs = [[self configsByApplyingStoredBentoLayout:self.allTileConfigs] mutableCopy];
    [self rebuildDisplaySections];
    
    [self setupHeader];
    [self setupCollectionView];
    [self applyHomeSafeAreaInsets];   // ★ [HOME6] 首次按实时安全区铺一次(竖/横通用)
    [self updateSkinDisplay];
    [self checkMinecraftVersions];
    [self checkForUpdate];
    [self loadLatestNewsForTile];
    [self loadAnnouncementsForTile];

    // 适配自定义启动器背景：将当前视图控制器透明化，让全局背景（图片/视频）能够透出显示。
    // 本控制器为 UIViewController 子类，其 collectionView 为手动创建，
    // makeViewControllerTransparent 会设置 view 背景透明；collectionView 背景已在 setupCollectionView 中清空。
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // 监听背景 UI 效果变化通知：当用户在背景设置中切换毛玻璃/半透明或调整透明度时，
    // 重新调用 makeViewControllerTransparent 以应用最新的视觉效果，保证背景始终正确透出。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateSkinDisplay)
                                                 name:@"AccountChanged"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateSkinDisplay)
                                                 name:@"UpdateAccountInfo"
                                               object:nil];

    // ★ [HOMEWIRE] 自定义面板保存 ⇒ 主页立即重排(面板已把顺序/尺寸写入 ameHomeCardLayout)
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleHomeCardLayoutChanged:)
                                                 name:AmeHomeCardLayoutChangedNotification
                                               object:nil];

    // ★ [NORIGHT] 右栏状态广播 ⇒ 欢迎卡版本号 / 顶栏 JIT pill / 底部启动胶囊文案保持一致
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(norightStateChanged:)
                                                 name:AmeRightPanelStateNotification
                                               object:nil];
    // ★ [NORIGHT] 主题色变化 ⇒ 重刷底部胶囊的淡底/描边(与右栏同一触发时机)
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(norightRefreshCapsuleAppearance)
                                                 name:@"LauncherAppearanceChanged"
                                               object:nil];
}

#pragma mark - ★ [NORIGHT] 右栏状态镜像 + 底部启动胶囊

/// 每次主页出现都向(不可见的)右栏索取一次最新状态(版本号 / JIT / 启动键文案)。
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // ★ [NORIGHT] 右栏 viewDidLoad 可能早于本页注册监听 ⇒ 这里主动索取一次,保证首屏就有值。
    [[NSNotificationCenter defaultCenter] postNotificationName:AmeRightPanelRequestStateNotification object:nil];
    [self norightRefreshCapsuleAppearance];
}

/// 右栏广播的状态 → 欢迎卡版本号 / 顶栏 JIT pill / 底部启动胶囊。
- (void)norightStateChanged:(NSNotification *)note {
    NSDictionary *info = note.userInfo;
    if (![info isKindOfClass:[NSDictionary class]]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *ver = info[@"version"];
        if ([ver isKindOfClass:[NSString class]]) {
            self.norightVersionText = ver;
            [self norightApplyVersionToVisibleCells];
        }
        NSString *jit = info[@"jit"];
        if ([jit isKindOfClass:[NSString class]]) {
            self.norightJITPill.text = [NSString stringWithFormat:@" %@ ", jit];
        }
        UIColor *jitColor = info[@"jitColor"];
        if ([jitColor isKindOfClass:[UIColor class]]) {
            self.norightJITPill.textColor = jitColor;
            self.norightJITPill.backgroundColor = [jitColor colorWithAlphaComponent:0.15];
        }
        NSString *launchTitle = info[@"launchTitle"];
        if ([launchTitle isKindOfClass:[NSString class]] && launchTitle.length > 0) {
            [self.norightLaunchCapsule setTitle:launchTitle forState:UIControlStateNormal];
        }
        NSNumber *launchEnabled = info[@"launchEnabled"];
        if ([launchEnabled isKindOfClass:[NSNumber class]]) {
            // 与右栏按钮**完全同口径**(同一份 enabled 值)⇒ 可用性判断不变
            self.norightLaunchCapsule.enabled = launchEnabled.boolValue;
            self.norightLaunchCapsule.alpha = launchEnabled.boolValue ? 1.0 : 0.6;
        }
        // ★ [TOPBAR2] 下载中心:角标(进行中任务数) + 百分比/状态，全部来自右栏原按钮的计算结果
        NSString *dcBadge = info[@"dcBadge"];
        if ([dcBadge isKindOfClass:[NSString class]]) self.topbarDownloadBadgeText = dcBadge;
        NSString *dcProgress = info[@"dcProgress"];
        if ([dcProgress isKindOfClass:[NSString class]]) self.topbarDownloadProgressText = dcProgress;
        NSNumber *dcActive = info[@"dcActive"];
        if ([dcActive isKindOfClass:[NSNumber class]]) self.topbarDownloadActive = dcActive.boolValue;
        [self norightRefreshDownloadCenterPill];
    });
}

/// 版本号落到欢迎卡 pill(可见 cell 就地改;新建的 cell 在 cellForItemAtIndexPath 里取 norightVersionText)。
- (void)norightApplyVersionToVisibleCells {
    NSString *text = self.norightVersionText;
    for (UICollectionViewCell *c in self.collectionView.visibleCells) {
        if (![c isKindOfClass:[HomeProfileTileCell class]]) continue;
        HomeProfileTileCell *pc = (HomeProfileTileCell *)c;
        pc.versionLabel.text = text.length ? [NSString stringWithFormat:@"  %@  ", text] : @"";
        pc.versionLabel.hidden = (text.length == 0);
    }
}

/// 主题色变化后重刷底部胶囊的淡底 / 描边 / 图标色。
- (void)norightRefreshCapsuleAppearance {
    UIColor *accent = accentColor() ?: [UIColor systemBlueColor];
    self.norightLaunchCapsule.backgroundColor = [accent colorWithAlphaComponent:0.15];
    self.norightLaunchCapsule.layer.borderColor = accent.CGColor;
    self.norightLaunchCapsule.tintColor = accent;
}

/// 点击底部启动胶囊 —— 只转发,不在本页复制任何启动逻辑。
- (void)norightLaunchTapped {
    [LauncherRightPanelViewController norightPostAction:@"launch"];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// MARK: - Build Display Sections

- (void)rebuildDisplaySections {
    // ★ [SIZE4] 四档跨度后,若仍按“feature + 小格”分段,section 边界会把空位切成块 ⇒ 尾段必然留洞,
    //   且自定义 item 无法跨段回填。故把所有可见卡片放进**同一个 section**,交给
    //   bentoSectionForTiles:cols: 的占位图算法统一排布(行优先首次适配 ⇒ 后续卡补空位)。
    //   数据源形状 displaySections[section][item] 保持不变,cellForItem / numberOfItems 等全部不动。
    NSMutableArray<HomeTileConfig *> *visible = [NSMutableArray array];
    for (HomeTileConfig *tile in self.allTileConfigs) {
        if (tile.visible) [visible addObject:tile];
    }
    if (visible.count == 0) {
        self.displaySections = @[];
        return;
    }
    self.displaySections = @[ [visible copy] ];
}

// MARK: - Header Setup

- (void)setupHeader {
    // ★ [HOME6] 紧凑头部(照 home6 `.c6 .chd`):标题 1.02em≈15.5pt / 高 34(原 44)/ 左右 .85em≈13(原 20)。
    self.headerView = [[UIView alloc] init];
    self.headerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.headerView];

    self.headerTitleLabel = [[UILabel alloc] init];
    self.headerTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerTitleLabel.text = localize(@"i18n_str_349", nil);   // ★ [HOME6] 文案 key 不动
    self.headerTitleLabel.font = [UIFont systemFontOfSize:kHome6HeaderTitleSize weight:UIFontWeightBold];
    self.headerTitleLabel.textColor = [UIColor labelColor];
    [self.headerView addSubview:self.headerTitleLabel];

    self.customizeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.customizeButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIImage *gearIcon = [UIImage systemImageNamed:@"slider.horizontal.3"];
    [self.customizeButton setImage:gearIcon forState:UIControlStateNormal];
    [self.customizeButton setTitle:[@" " stringByAppendingString:localize(@"preference.title.appicon-custom", nil)] forState:UIControlStateNormal];
    // ★ [HOME6] 「⚙ 自定义」入口与点击行为原样保留(action 仍是 openCustomize),仅外观改玻璃胶囊(.cus)。
    self.customizeButton.titleLabel.font = [UIFont systemFontOfSize:kHome6PillFontSize weight:UIFontWeightMedium];
    self.customizeButton.tintColor = AmeTextSecondaryColor();
    self.customizeButton.backgroundColor = AmeGlassFillColor();
    self.customizeButton.layer.cornerRadius = AmeRadiusPill;
    self.customizeButton.layer.cornerCurve = kCACornerCurveContinuous;
    self.customizeButton.layer.borderWidth = AmeGlassBorderWidth;
    self.customizeButton.layer.borderColor = AmeGlassRimColor().CGColor;
    self.customizeButton.contentEdgeInsets = UIEdgeInsetsMake(0, 11.0, 0, 11.0);   // .cus padding .78em
    [self.customizeButton addTarget:self action:@selector(openCustomize) forControlEvents:UIControlEventTouchUpInside];
    [self.headerView addSubview:self.customizeButton];

    // ★ [EDITMODE] 编辑模式的「✓ 完成」pill:占「⚙自定义」同一个槽位(同一套两向约束),
    //   进编辑模式时隐藏「⚙自定义」、显示它 ⇒ 不重叠、不动既有约束链、横竖屏自动跟随。
    self.homeEditDoneButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.homeEditDoneButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.homeEditDoneButton setImage:[UIImage systemImageNamed:@"checkmark"] forState:UIControlStateNormal];
    [self.homeEditDoneButton setTitle:[@" " stringByAppendingString:localize(@"resman.common.done", nil)] forState:UIControlStateNormal];
    self.homeEditDoneButton.titleLabel.font = [UIFont systemFontOfSize:kHome6PillFontSize weight:UIFontWeightMedium];
    self.homeEditDoneButton.tintColor = AmeTextSecondaryColor();
    self.homeEditDoneButton.backgroundColor = AmeGlassFillColor();
    self.homeEditDoneButton.layer.cornerRadius = AmeRadiusPill;
    self.homeEditDoneButton.layer.cornerCurve = kCACornerCurveContinuous;
    self.homeEditDoneButton.layer.borderWidth = AmeGlassBorderWidth;
    self.homeEditDoneButton.layer.borderColor = AmeGlassRimColor().CGColor;
    self.homeEditDoneButton.contentEdgeInsets = UIEdgeInsetsMake(0, 11.0, 0, 11.0);
    self.homeEditDoneButton.hidden = YES;   // 默认不在编辑模式
    [self.homeEditDoneButton addTarget:self action:@selector(homeEditDoneTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.headerView addSubview:self.homeEditDoneButton];

    // ★ [NORIGHT] JIT 状态从右栏搬到主页顶栏右侧,和「⚙ 自定义」并排一个小 pill。
    //   文本/颜色**完全来自**右栏 updateJITStatus(经 AmeRightPanelStateNotification 同步);
    //   本 pill 自己不判定 JIT、不参与任何启动行为,只做状态镜像。
    self.norightJITPill = [[UILabel alloc] init];
    self.norightJITPill.translatesAutoresizingMaskIntoConstraints = NO;
    self.norightJITPill.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightSemibold];
    self.norightJITPill.textAlignment = NSTextAlignmentCenter;
    self.norightJITPill.layer.cornerRadius = 8.0;
    self.norightJITPill.layer.cornerCurve = kCACornerCurveContinuous;
    self.norightJITPill.layer.masksToBounds = YES;
    self.norightJITPill.text = [NSString stringWithFormat:@" %@ ", localize(@"i18n_str_413", nil)];
    self.norightJITPill.textColor = [UIColor secondaryLabelColor];
    self.norightJITPill.backgroundColor = [UIColor tertiarySystemFillColor];
    [self.headerView addSubview:self.norightJITPill];

    // ★ [TOPBAR2] 右栏「执行 Jar / 选择版本 / 下载中心」三个入口搬到主页顶栏，
    //   与 JIT 状态同一排(顶栏右侧)。三个 pill 全部只做动作转发到右栏
    //   原方法(executeJar / showVersionPicker / openDownloadCenter)，本页零业务逻辑、零复制。
    self.topbarExecuteJarPill = [self topbarActionPillWithTitle:localize(@"i18n_str_414", nil)
                                                          icon:@"doc.badge.arrow.up"
                                                        action:TopBar2PillActionExecuteJar];
    self.topbarVersionPickerPill = [self topbarActionPillWithTitle:localize(@"i18n_str_38", nil)
                                                             icon:@"square.stack.3d.up.fill"
                                                           action:TopBar2PillActionVersionPicker];
    self.topbarDownloadCenterPill = [self topbarActionPillWithTitle:localize(@"i18n_str_136", nil)
                                                              icon:@"arrow.down.circle"
                                                            action:TopBar2PillActionDownloadCenter];
    [self.headerView addSubview:self.topbarExecuteJarPill];
    [self.headerView addSubview:self.topbarVersionPickerPill];
    [self.headerView addSubview:self.topbarDownloadCenterPill];

    // ★ [TOPBAR2] 下载中心角标(进行中任务数)：固定在 pill 右上角，
    //   数值/显隐由右栏 updateDownloadCenterButton 广播驱动 ⇒ 与原按钮同口径。
    self.topbarDownloadBadgeLabel = [[UILabel alloc] init];
    self.topbarDownloadBadgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.topbarDownloadBadgeLabel.font = [UIFont monospacedDigitSystemFontOfSize:9 weight:UIFontWeightBold];
    self.topbarDownloadBadgeLabel.textColor = [UIColor whiteColor];
    self.topbarDownloadBadgeLabel.backgroundColor = [UIColor systemRedColor];
    self.topbarDownloadBadgeLabel.textAlignment = NSTextAlignmentCenter;
    self.topbarDownloadBadgeLabel.layer.cornerRadius = 7.5;
    self.topbarDownloadBadgeLabel.layer.masksToBounds = YES;
    self.topbarDownloadBadgeLabel.hidden = YES;
    [self.headerView addSubview:self.topbarDownloadBadgeLabel];

    // 公共约束(与朝向无关;不含任何会被两套约束重复钉住的属性)
    [NSLayoutConstraint activateConstraints:@[
        [self.headerView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.headerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.headerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.headerView.heightAnchor constraintEqualToConstant:kHome6HeaderHeight],

        [self.headerTitleLabel.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        // ★ [NORIGHT] 标题右界改让给 JIT pill(原来直接让给「⚙自定义」)
        [self.headerTitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.norightJITPill.leadingAnchor constant:-8],

        [self.customizeButton.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [self.customizeButton.heightAnchor constraintEqualToConstant:kHome6PillHeight],

        // ★ [EDITMODE] 「✓ 完成」与「⚙自定义」同槽位:centerY/高一致,trailing 也挂在同一套两向约束里
        //   (竖屏贴 view 边、横屏贴 safeArea 边)⇒ 两朝向自动跟随,不存在同属性双钉。
        [self.homeEditDoneButton.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [self.homeEditDoneButton.heightAnchor constraintEqualToConstant:kHome6PillHeight],

        // ★ [TOPBAR2] 顶栏右侧一排(方向无关的唯一一组约束;链式互钉 ⇒ 同一属性只有一条约束):
        //   JIT 状态 · 执行 Jar · 选择版本 · 下载中心 · ⚙自定义(从左到右)
        [self.norightJITPill.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [self.norightJITPill.heightAnchor constraintEqualToConstant:kHome6PillHeight],
        [self.norightJITPill.trailingAnchor constraintEqualToAnchor:self.topbarExecuteJarPill.leadingAnchor constant:-kTopBar2PillGap],

        [self.topbarExecuteJarPill.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [self.topbarExecuteJarPill.heightAnchor constraintEqualToConstant:kHome6PillHeight],
        [self.topbarExecuteJarPill.trailingAnchor constraintEqualToAnchor:self.topbarVersionPickerPill.leadingAnchor constant:-kTopBar2PillGap],

        [self.topbarVersionPickerPill.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [self.topbarVersionPickerPill.heightAnchor constraintEqualToConstant:kHome6PillHeight],
        [self.topbarVersionPickerPill.trailingAnchor constraintEqualToAnchor:self.topbarDownloadCenterPill.leadingAnchor constant:-kTopBar2PillGap],

        [self.topbarDownloadCenterPill.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [self.topbarDownloadCenterPill.heightAnchor constraintEqualToConstant:kHome6PillHeight],
        [self.topbarDownloadCenterPill.trailingAnchor constraintEqualToAnchor:self.customizeButton.leadingAnchor constant:-kTopBar2PillGap],

        // ★ [TOPBAR2] 下载中心角标:贴 pill 右上角、完全落在 34pt 顶栏内(不侵入状态栏)
        [self.topbarDownloadBadgeLabel.trailingAnchor constraintEqualToAnchor:self.topbarDownloadCenterPill.trailingAnchor constant:2],
        [self.topbarDownloadBadgeLabel.centerYAnchor constraintEqualToAnchor:self.topbarDownloadCenterPill.topAnchor constant:3],
        [self.topbarDownloadBadgeLabel.heightAnchor constraintEqualToConstant:15],
        [self.topbarDownloadBadgeLabel.widthAnchor constraintGreaterThanOrEqualToConstant:15],
    ]];

    // ★ [HOME6] 两套头部约束集:竖屏一套(贴 view 边 +13)、横屏一套(贴 safeAreaLayoutGuide 边 +13,
    //   横屏让开侧边灵动岛 ≈59pt)。两套只钉「标题 leading」「胶囊 trailing」,且分属不同 anchor
    //   ⇒ 不可能被两套同时钉住(规避"同属性双钉"⇒约束冲突/错位)。切换见 applyHomeSafeAreaInsets。
    self.headerPortraitConstraints = @[
        [self.headerTitleLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:kHome6HeaderPadH],
        [self.customizeButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-kHome6HeaderPadH],
        // ★ [EDITMODE] 「✓ 完成」的竖屏 trailing(与 ⚙自定义 完全同一锚点;两朝向各挂一套 ⇒ 无双钉)
        [self.homeEditDoneButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-kHome6HeaderPadH],
    ];
    self.headerLandscapeConstraints = @[
        [self.headerTitleLabel.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:kHome6HeaderPadH],
        [self.customizeButton.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-kHome6HeaderPadH],
        // ★ [EDITMODE] 横屏:贴 safeArea 右缘 ⇒ 让开侧边灵动岛(与 ⚙自定义 同一策略)
        [self.homeEditDoneButton.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-kHome6HeaderPadH],
    ];
    [self activateHeaderConstraintsForLandscape:[self homeIsLandscape]];
}

// MARK: - Collection View Setup

- (void)setupCollectionView {
    UICollectionViewLayout *layout = [self createLayout];
    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.showsVerticalScrollIndicator = NO;
    // ★ [HOME6] 安全区由我们自己按「实时 view.safeAreaInsets」控制(底部 Home 条 / 标签栏),
    //   故关掉系统自动内缩,避免与自定义值叠加。
    self.collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.collectionView.contentInset = UIEdgeInsetsMake(0, 0, 20, 0);
    
    [self.collectionView registerClass:[HomeProfileTileCell class]      forCellWithReuseIdentifier:@"ProfileCell"];
    [self.collectionView registerClass:[HomeInfoTileCell class]         forCellWithReuseIdentifier:@"InfoCell"];
    [self.collectionView registerClass:[HomeAnnouncementTileCell class] forCellWithReuseIdentifier:@"AnnouncementCell"];
    [self.collectionView registerClass:[HomeNewsTileCell class]         forCellWithReuseIdentifier:@"NewsCell"];
    [self.collectionView registerClass:[HomeShortcutTileCell class]     forCellWithReuseIdentifier:@"ShortcutCell"];

    // ★ [EDITMODE] 主页直接编辑:关掉 UIKit 自带的“长按拖动”标准手势 ——
    //   本页要由**自己**的长按统一驱动「进编辑 / 拖拽排序 / 拖把手改尺寸」三件事,
    //   留着标准手势会与我们的长按双触发(同一格被两个 recognizer 抢)。
    // ★ [EDITMODE-FIX] 这里**不能**写 `self.collectionView.installsStandardGestureForInteractiveMovement = NO;`
    //   —— 那个属性属于 `UICollectionViewController`,不属于 `UICollectionView`;
    //   本页是普通 UIViewController + 裸 collectionView,UIKit 根本不会自动装"长按拖动"标准手势,
    //   所以无需关闭。排重交给下面自己的长按(★[EDIT3] 已无白名单让位:卡片上不再有任何自带长按)。
    self.homeEditLongPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(homeEditLongPressed:)];
    self.homeEditLongPress.minimumPressDuration = 0.45;   // 与 iOS 主屏幕接近
    self.homeEditLongPress.allowableMovement = 12.0;      // 先动超过 12pt ⇒ 让位给滚动,不误进编辑
    self.homeEditLongPress.delegate = self;               // ★ [EDIT3] 代理现仅供 homeEditBlankTap 用;长按不再让位
    [self.collectionView addGestureRecognizer:self.homeEditLongPress];

    // ★ [EDIT2] 编辑态「点空白退出」:单击手势。
    //   非编辑态完全不接收触屏(shouldReceiveTouch: 返回 NO)⇒ 不可能干扰正常点击/滚动;
    //   编辑态也只认“落点不在任何卡片上”的空白处(落在卡片上不算 —— 编辑态卡片点击本就被忽略)。
    self.homeEditBlankTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(homeEditBlankTapped:)];
    self.homeEditBlankTap.cancelsTouchesInView = NO;
    self.homeEditBlankTap.delegate = self;
    [self.collectionView addGestureRecognizer:self.homeEditBlankTap];

    [self.view addSubview:self.collectionView];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.collectionView.topAnchor constraintEqualToAnchor:self.headerView.bottomAnchor],
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    // ★ [NORIGHT] 主页底部「启动游戏」紧凑胶囊 = 右栏启动键的搬家落点(用户:「大色块干掉」)。
    //   位置:钉在**安全区底部之上 8pt** ⇒ 正好落在系统标签栏上沿,不遮标签栏(横竖屏同一组约束)。
    //   宽度:由 norightCapsuleWidth 一条**等宽**约束的 constant 表达(applyHomeSafeAreaInsets 里
    //   按实时宽度算:竖屏≈满宽-32、横屏收 320)= 不存在同属性双钉。
    //   行为:点击只发通知 ⇒ 落到右栏原 launchButtonTapped(账号校验/JIT/下载拦截/版本解析全链路不变)。
    self.norightLaunchCapsule = [UIButton buttonWithType:UIButtonTypeSystem];
    self.norightLaunchCapsule.translatesAutoresizingMaskIntoConstraints = NO;
    [self.norightLaunchCapsule setTitle:localize(@"i18n_str_412", nil) forState:UIControlStateNormal];
    self.norightLaunchCapsule.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.norightLaunchCapsule.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.norightLaunchCapsule.titleLabel.minimumScaleFactor = 0.7;
    UIColor *norightAccent = accentColor() ?: [UIColor systemBlueColor];
    self.norightLaunchCapsule.backgroundColor = [norightAccent colorWithAlphaComponent:0.15];
    self.norightLaunchCapsule.layer.cornerRadius = kNoRightCapsuleHeight / 2.0;
    self.norightLaunchCapsule.layer.cornerCurve = kCACornerCurveContinuous;
    self.norightLaunchCapsule.layer.borderWidth = 1.0;
    self.norightLaunchCapsule.layer.borderColor = norightAccent.CGColor;
    [self.norightLaunchCapsule setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    UIImage *norightPlay = [UIImage systemImageNamed:@"play.fill"];
    if (norightPlay) {
        norightPlay = [norightPlay imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        [self.norightLaunchCapsule setImage:norightPlay forState:UIControlStateNormal];
    }
    self.norightLaunchCapsule.tintColor = norightAccent;
    self.norightLaunchCapsule.imageEdgeInsets = UIEdgeInsetsMake(0, -6, 0, 0);
    self.norightLaunchCapsule.titleEdgeInsets = UIEdgeInsetsMake(0, 6, 0, 0);
    self.norightLaunchCapsule.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    [self.norightLaunchCapsule addTarget:self action:@selector(norightLaunchTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.norightLaunchCapsule];
    [self.view bringSubviewToFront:self.norightLaunchCapsule];

    self.norightCapsuleWidth = [self.norightLaunchCapsule.widthAnchor constraintEqualToConstant:kNoRightCapsuleMaxW];
    // 800 兜底:任何情况下不越出屏幕左右 16pt(可被 solver 静默让步 ⇒ 不会报冲突)
    NSLayoutConstraint *norightCapsuleLeadGuard = [self.norightLaunchCapsule.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:16];
    NSLayoutConstraint *norightCapsuleTrailGuard = [self.norightLaunchCapsule.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-16];
    norightCapsuleLeadGuard.priority = 800;
    norightCapsuleTrailGuard.priority = 800;
    [NSLayoutConstraint activateConstraints:@[
        [self.norightLaunchCapsule.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
        [self.norightLaunchCapsule.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.norightLaunchCapsule.heightAnchor constraintEqualToConstant:kNoRightCapsuleHeight],
        self.norightCapsuleWidth,
        norightCapsuleLeadGuard, norightCapsuleTrailGuard,
    ]];
}

// MARK: - ★ [TOPBAR2] 顶栏动作 pill(创建 / 刷新 / 点击转发)

/// ★ [TOPBAR2] 顶栏动作 pill:观感沿用「⚙自定义」玻璃胶囊(字体 10 / 高 24 / 圆角 pill)。
///   宽度一律由内容决定(无固定宽约束)；竖屏窄时由 norightApplyTopBarPillTitlesForLandscape: 只留图标。
- (UIButton *)topbarActionPillWithTitle:(NSString *)title
                                   icon:(NSString *)iconName
                                 action:(TopBar2PillAction)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:kHome6PillFontSize weight:UIFontWeightMedium];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.7;
    b.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    b.tintColor = AmeTextSecondaryColor();
    b.backgroundColor = AmeGlassFillColor();
    b.layer.cornerRadius = AmeRadiusPill;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    b.layer.borderWidth = AmeGlassBorderWidth;
    b.layer.borderColor = AmeGlassRimColor().CGColor;
    b.contentEdgeInsets = UIEdgeInsetsMake(0, 7.0, 0, 7.0);   // 紧凑:左右各 7pt
    b.imageEdgeInsets = UIEdgeInsetsMake(0, -3, 0, 3);
    b.titleEdgeInsets = UIEdgeInsetsMake(0, 3, 0, -3);
    UIImage *img = [UIImage systemImageNamed:iconName];
    if (img) [b setImage:img forState:UIControlStateNormal];
    b.tag = action;
    [b addTarget:self action:@selector(topbarActionTapped:) forControlEvents:UIControlEventTouchUpInside];
    return b;
}

/// ★ [TOPBAR2] 点击 = 只发动作名 ⇒ 落到右栏 norightHandleAction: 的原方法
///   (executeJar / showVersionPicker / openDownloadCenter)。不在本页复制任何业务逻辑。
- (void)topbarActionTapped:(UIButton *)sender {
    switch ((TopBar2PillAction)sender.tag) {
        case TopBar2PillActionExecuteJar:     [LauncherRightPanelViewController norightPostAction:@"executeJar"];     break;
        case TopBar2PillActionVersionPicker:  [LauncherRightPanelViewController norightPostAction:@"versionPicker"];  break;
        case TopBar2PillActionDownloadCenter: [LauncherRightPanelViewController norightPostAction:@"downloadCenter"]; break;
        default: break;
    }
}

/// ★ [TOPBAR2] 竖屏窄 ⇒ 三个动作 pill 只留图标;横屏宽 ⇒ 图标 + 小字。
///   只切 title 文案，不动任何约束/尺寸常量 ⇒ 不产生约束冲突，也不涉及 frame 硬摆。
- (void)norightApplyTopBarPillTitlesForLandscape:(BOOL)landscape {
    [self.topbarExecuteJarPill setTitle:(landscape ? localize(@"i18n_str_414", nil) : @"") forState:UIControlStateNormal];
    [self.topbarVersionPickerPill setTitle:(landscape ? localize(@"i18n_str_38", nil) : @"") forState:UIControlStateNormal];
    [self norightRefreshDownloadCenterPill];
}

/// ★ [TOPBAR2] 下载中心 pill 文案 = 入口名(横屏) + 百分比/状态(有任务时)。
///   百分比/角标数值全部来自右栏 updateDownloadCenterButton 的广播，本页只做展示。
- (void)norightRefreshDownloadCenterPill {
    if (!self.topbarDownloadCenterPill) return;
    BOOL landscape = [self homeIsLandscape];
    NSString *progress = self.topbarDownloadActive ? (self.topbarDownloadProgressText ?: @"") : @"";
    NSString *title;
    if (landscape) {
        title = localize(@"i18n_str_136", nil);
        if (progress.length > 0) title = [title stringByAppendingFormat:@" %@", progress];
    } else {
        title = progress;   // 竖屏:图标 + 百分比/状态(无任务 ⇒ 纯图标)
    }
    [self.topbarDownloadCenterPill setTitle:title forState:UIControlStateNormal];

    NSString *badge = self.topbarDownloadBadgeText ?: @"";
    self.topbarDownloadBadgeLabel.text = badge;
    self.topbarDownloadBadgeLabel.hidden = (badge.length == 0);
    // ★ [EDITMODE] 编辑模式顶栏 pill 已隐藏 ⇒ 角标不能单独飘出来。
    if (self.homeEditing) self.topbarDownloadBadgeLabel.hidden = YES;
}

/// ★ [SIZE4] 1×1 名义高度(按类型;与尺寸档位无关)。
- (CGFloat)bentoBaseUnitHeightForTileType:(HomeTileType)type {
    switch (type) {
        case HomeTileTypeProfile:         return 140.0;
        case HomeTileTypeAnnouncement:    return 90.0;
        case HomeTileTypeVersionRelease:
        case HomeTileTypeVersionSnapshot: return 100.0;
        case HomeTileTypeNews:            return 120.0;
        case HomeTileTypeShortcut:        return 76.0;
        default:                          return 100.0;
    }
}

/// ★ [SIZE4] 四档尺寸 ⇒ 高度:行跨度 1 ⇒ 1 个行高;行跨度 2(Tall/Large)⇒ 两倍行高 + 间距。
- (CGFloat)heightForTileConfig:(HomeTileConfig *)config {
    CGFloat unit = [self bentoBaseUnitHeightForTileType:config.tileType];
    switch (config.tileSize) {
        case HomeTileSizeTall:
        case HomeTileSizeLarge:
            return unit * 2.0 + kBentoGap;
        case HomeTileSizeSmall:
        case HomeTileSizeWide:
        default:
            return unit;
    }
}

// MARK: - ★ [BENTO] 便当盒布局

/// ★ [BENTO] 造一个 item:宽度用分数(相对所在 group),高度用绝对值。
- (NSCollectionLayoutItem *)bentoItemWithWidthFraction:(CGFloat)widthFraction
                                                height:(CGFloat)height
                                                insets:(NSDirectionalEdgeInsets)insets {
    NSCollectionLayoutSize *size = [NSCollectionLayoutSize
        sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:widthFraction]
        heightDimension:[NSCollectionLayoutDimension absoluteDimension:height]];
    NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:size];
    item.contentInsets = insets;
    return item;
}

/// ★ [BENTO] 统一的小格可见高度:取该组小格的原设计高度,夹在 [kBentoSmallMin, kBentoSmallMax]。
- (CGFloat)bentoSmallHeightForTiles:(NSArray<HomeTileConfig *> *)tiles {
    CGFloat h = 0;
    for (HomeTileConfig *t in tiles) {
        if (t.tileSize == HomeTileSizeFull) continue;   // 大格不参与小格基准高度
        h = MAX(h, [self heightForTileConfig:t]);
    }
    if (h <= 0) h = 100.0;
    return MIN(MAX(h, kBentoSmallMin), kBentoSmallMax);
}

/// ★ [BENTO] 给 group 套上统一的 section 内边距。
- (NSCollectionLayoutSection *)bentoSectionWithGroup:(NSCollectionLayoutGroup *)group {
    NSCollectionLayoutSection *section = [NSCollectionLayoutSection sectionWithGroup:group];
    // ★ [HOME6] 安全区:横屏灵动岛在侧边(≈59pt)⇒ 该侧多让 59、另一侧贴边(0);竖屏左右皆 0。
    //   读的是「实时」值 self.homeSafeInsets(由 viewSafeAreaInsetsDidChange 刷新),不缓存旧朝向的值。
    UIEdgeInsets sa = self.homeSafeInsets;
    section.contentInsets = NSDirectionalEdgeInsetsMake(kBentoEdgeV,
                                                        kBentoEdgeH + sa.left,
                                                        kBentoEdgeV,
                                                        kBentoEdgeH + sa.right);
    return section;
}

/// ★ [BENTO] 单格 section(该 section 只有一个磁贴):整行大格。
- (NSCollectionLayoutSection *)bentoSectionForSingleTile:(HomeTileConfig *)tile {
    CGFloat h = MAX([self heightForTileConfig:tile], kBentoMinRowH);
    NSDirectionalEdgeInsets insets = NSDirectionalEdgeInsetsMake(0, kBentoGap / 2.0, 0, kBentoGap / 2.0);
    NSCollectionLayoutItem *item = [self bentoItemWithWidthFraction:1.0 height:h insets:insets];
    NSCollectionLayoutSize *groupSize = [NSCollectionLayoutSize
        sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
        heightDimension:[NSCollectionLayoutDimension absoluteDimension:h]];
    NSCollectionLayoutGroup *group = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:groupSize subitems:@[item]];
    return [self bentoSectionWithGroup:group];
}

/// ★ [SIZE4] 便当盒 section(整段网格):用「行列占位图 + 行优先首次适配」自己算每张卡的四边坐标,
///   支持 Small(1×1)/Wide(2×1)/Tall(1×2)/Large(2×2) 四种跨度:
///     ① 不重叠:放置前逐格探测目标区域,任一格已被占就换位置;
///     ② 不留死洞:后面的卡会补进前面卡留下的空位(行优先扫描,先放得下的先占);
///        末尾若仍有放不下的余位,保持空白(不回填、不拉伸、不重叠)——这是唯一允许的“留白”。
///   几何用 NSCollectionLayoutGroupCustomItemProvider(列宽比例 + 行高绝对值)算出,横竖屏重算,
///   不硬摆 frame。item 顺序与 displaySections[section] 完全一致 ⇒ index path 不错位。
- (NSCollectionLayoutSection *)bentoSectionForTiles:(NSArray<HomeTileConfig *> *)tiles cols:(NSInteger)cols {
    if (tiles.count == 0) return nil;

    const NSInteger C = MAX((NSInteger)1, cols);
    const CGFloat gap = kBentoGap;
    const CGFloat unitH = [self bentoRowUnitForTiles:tiles];   // 统一行单元高(像小组件:1×1 等大)

    // ★ [FIX2] 本条 section 的左右内边距 —— 必须与 bentoSectionWithGroup: 里设的完全一致。
    //   自定义 item 的坐标系是 **group 自己的坐标空间**,而 group 宽 = section 可用宽
    //   = 容器整宽 − 左右内边距。若直接拿「容器整宽」当可用宽算 colW,colW 会偏大,
    //   整排卡片会向右溢出内边距(用户实测:卡片太靠右、左边留白、2×2 撑爆)。
    UIEdgeInsets fix2SA = self.homeSafeInsets;
    const CGFloat insetL = kBentoEdgeH + fix2SA.left;
    const CGFloat insetR = kBentoEdgeH + fix2SA.right;
    const CGFloat insetW = insetL + insetR;

    // ---- ① 占位图:行优先“首次适配”,得到每张卡的 (col,row,colSpan,rowSpan) ----
    NSMutableArray<NSMutableIndexSet *> *occ = [NSMutableArray array];   // occ[row] = 该行已占列集合
    NSMutableArray<NSNumber *> *slotCol = [NSMutableArray arrayWithCapacity:tiles.count];
    NSMutableArray<NSNumber *> *slotRow = [NSMutableArray arrayWithCapacity:tiles.count];
    NSMutableArray<NSNumber *> *slotCS  = [NSMutableArray arrayWithCapacity:tiles.count];
    NSMutableArray<NSNumber *> *slotRS  = [NSMutableArray arrayWithCapacity:tiles.count];

    for (HomeTileConfig *tile in tiles) {
        NSInteger cspan = MIN(AmeTileSpanColumns(tile.tileSize), C);
        NSInteger rspan = AmeTileSpanRows(tile.tileSize);
        NSInteger putRow = 0, putCol = 0;
        BOOL placed = NO;
        for (NSInteger r = 0; !placed; r++) {              // 行优先扫描
            for (NSInteger c = 0; c + cspan <= C; c++) {   // 逐列试放
                BOOL fits = YES;
                for (NSInteger rr = r; rr < r + rspan && fits; rr++) {
                    if (rr < (NSInteger)occ.count) {
                        for (NSInteger cc = c; cc < c + cspan; cc++) {
                            if ([occ[(NSUInteger)rr] containsIndex:(NSUInteger)cc]) { fits = NO; break; }
                        }
                    }
                }
                if (fits) { putRow = r; putCol = c; placed = YES; break; }
            }
        }
        while ((NSInteger)occ.count < putRow + rspan) [occ addObject:[NSMutableIndexSet indexSet]];   // 补行
        for (NSInteger rr = putRow; rr < putRow + rspan; rr++) {
            for (NSInteger cc = putCol; cc < putCol + cspan; cc++) {
                [occ[(NSUInteger)rr] addIndex:(NSUInteger)cc];                                        // 标记占用
            }
        }
        [slotCol addObject:@(putCol)];
        [slotRow addObject:@(putRow)];
        [slotCS  addObject:@(cspan)];
        [slotRS  addObject:@(rspan)];
    }

    NSInteger rows = (NSInteger)occ.count;
    CGFloat totalH = (CGFloat)rows * unitH + (CGFloat)(rows > 0 ? rows - 1 : 0) * gap;
    if (totalH <= 0) totalH = unitH;

    NSCollectionLayoutSize *groupSize = [NSCollectionLayoutSize
        sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
        heightDimension:[NSCollectionLayoutDimension absoluteDimension:totalH]];

    __weak typeof(self) fix2WeakSelf = self;   // ★ [FIX2] provider 内取实时容器宽(弱引用,不形成循环)
    NSCollectionLayoutGroup *group = [NSCollectionLayoutGroup customGroupWithLayoutSize:groupSize
        itemProvider:^NSArray<NSCollectionLayoutGroupCustomItem *> * _Nonnull(id<NSCollectionLayoutEnvironment> environment) {
        // ★ [FIX2] 容器「整宽」优先取 collectionView 的实时 bounds(与 section inset 同一坐标系,最确定);
        //   取不到再退 environment 的 contentSize / effectiveContentSize。
        //   注意:自定义 item provider 里 effectiveContentSize 给的是**未扣 section inset** 的容器宽,
        //   直接当可用宽会让 colW 偏大 —— 这正是「卡片偏右 / 2×2 溢出」的根因。
        UICollectionView *fix2CV = fix2WeakSelf.collectionView;
        CGFloat containerW = fix2CV ? CGRectGetWidth(fix2CV.bounds) : 0.0;
        if (containerW <= 0) containerW = environment.container.contentSize.width;
        if (containerW <= 0) containerW = environment.container.effectiveContentSize.width;
        // ★ [FIX2] 可用宽 = 容器整宽 − 左右内边距 ⇒ 列宽一律从「可用宽 − 间距」推算。
        CGFloat innerW = containerW - insetW;
        if (innerW <= 0) innerW = containerW;                          // 兜底:容器宽本就 ≤ inset 时不再扣
        CGFloat colW = (innerW - gap * (CGFloat)(C - 1)) / (CGFloat)C;   // 列宽由实时可用宽度算出
        if (colW < 1.0) colW = 1.0;
        NSMutableArray<NSCollectionLayoutGroupCustomItem *> *items =
            [NSMutableArray arrayWithCapacity:tiles.count];
        for (NSUInteger k = 0; k < tiles.count; k++) {
            NSInteger c  = slotCol[k].integerValue;
            NSInteger r  = slotRow[k].integerValue;
            NSInteger cs = slotCS[k].integerValue;
            NSInteger rs = slotRS[k].integerValue;
            // ★ [FIX2] 单卡宽一律 min(计算值, 可用宽),再对右缘做夹取保险 ⇒
            //   Wide / Large 绝不超出可用宽;2×2(跨满两列)的宽恰好 = 整行可用宽
            //   ⇒ 竖屏两张 2×2 各占整行、稳稳往下排,不溢出、不触发横向滚动。
            CGFloat w = (CGFloat)cs * colW + (CGFloat)(cs - 1) * gap;    // Mixed 跨度:宽度累加各列 + 中间间距
            w = MIN(w, innerW);
            CGFloat x = (CGFloat)c * (colW + gap);
            if (x + w > innerW) x = MAX((CGFloat)0.0, innerW - w);        // 右缘保险:任何情况下都不越界
            CGFloat y = (CGFloat)r * (unitH + gap);
            CGFloat h = (CGFloat)rs * unitH + (CGFloat)(rs - 1) * gap;  // 高卡 = 两倍行高 + 间距
            [items addObject:[NSCollectionLayoutGroupCustomItem
                              customItemWithFrame:CGRectMake(x, y, MAX(w, 1.0), MAX(h, 1.0))]];
        }
        return items;
    }];
    return [self bentoSectionWithGroup:group];
}

/// ★ [SIZE4] 整个网格的统一“行单元高”:取所有 1 行高卡片名义高的中位数,夹在 [kBentoSmallMin, kBentoSmallMax]。
///   目的:像系统小组件那样让所有 1×1 单元等大方正(旧的按类型 76~140 参差高度不再直接进入网格)。
- (CGFloat)bentoRowUnitForTiles:(NSArray<HomeTileConfig *> *)tiles {
    NSMutableArray<NSNumber *> *units = [NSMutableArray array];
    for (HomeTileConfig *t in tiles) {
        if (AmeTileSpanRows(t.tileSize) != 1) continue;      // 2 行高的卡不参与基准
        [units addObject:@([self heightForTileConfig:t])];   // Small/Wide ⇒ 名义单元高
    }
    if (units.count == 0) {
        for (HomeTileConfig *t in tiles) {
            [units addObject:@([self bentoBaseUnitHeightForTileType:t.tileType])];
        }
    }
    if (units.count == 0) return 100.0;
    NSArray<NSNumber *> *sorted = [units sortedArrayUsingSelector:@selector(compare:)];
    CGFloat unit = sorted[sorted.count / 2].doubleValue;     // 中位数
    return MIN(MAX(unit, kBentoSmallMin), kBentoSmallMax);
}

/// ★ [BENTO] section provider:列数由可用宽度决定(窄屏 2 列 / 宽屏 3 列),
/// 每个多格 section 内至少产出两种 item 尺寸(大格 vs 小格)。
- (UICollectionViewLayout *)createLayout {
    __weak typeof(self) weakSelf = self;

    return [[UICollectionViewCompositionalLayout alloc] initWithSectionProvider:^NSCollectionLayoutSection * _Nullable(NSInteger sectionIndex, id<NSCollectionLayoutEnvironment> env) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return nil;
        if (sectionIndex >= (NSInteger)strongSelf.displaySections.count) return nil;

        NSArray<HomeTileConfig *> *tiles = strongSelf.displaySections[sectionIndex];
        if (tiles.count == 0) return nil;

        // ★ [BENTO] 列数随可用宽度变化:宽屏 3 列、窄屏 2 列(竖屏/横屏都成立)。
        // ★ [HOME6] 列数:竖屏 2 列 / 横屏 3 列(判据 = 实时容器宽,横屏 ≈844 ≥ 700)。
        //   卡片宽度一律 fractionalWidthDimension(比例),任何朝向都不写死 px 宽。
        CGFloat availW = env.container.effectiveContentSize.width;
        NSInteger cols = (availW >= kBentoWideWidth) ? 3 : 2;

        return [strongSelf bentoSectionForTiles:tiles cols:cols];
    }];
}

// MARK: - UICollectionView DataSource

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return self.displaySections.count;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.displaySections[section].count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    HomeTileConfig *config = self.displaySections[indexPath.section][indexPath.item];
    
    switch (config.tileType) {
        case HomeTileTypeProfile: {
            HomeProfileTileCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"ProfileCell" forIndexPath:indexPath];
            [cell setAccentColor:[config accentColor]];
            
            NSString *name = self.currentUsername ?: localize(@"i18n_str_351", nil);
            cell.welcomeLabel.text = [NSString stringWithFormat:localize(@"i18n_str_352", nil), name];
            cell.greetingLabel.text = festivalGreeting();
            // ★ [NORIGHT] 版本号(来自右栏 updateVersionInfo 的广播;没有则隐藏 pill)
            cell.versionLabel.text = self.norightVersionText.length ? [NSString stringWithFormat:@"  %@  ", self.norightVersionText] : @"";
            cell.versionLabel.hidden = (self.norightVersionText.length == 0);
            cell.skinImageView.image = self.currentSkin ?: [UIImage systemImageNamed:@"person.fill"];
            if (self.currentAvatar) {
                cell.avatarImageView.image = self.currentAvatar;
            } else {
                cell.avatarImageView.image = [UIImage systemImageNamed:@"person.circle.fill"];
                cell.avatarImageView.tintColor = [UIColor systemGrayColor];
            }
            return cell;
        }
            
        case HomeTileTypeVersionRelease: {
            HomeInfoTileCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"InfoCell" forIndexPath:indexPath];
            [cell setAccentColor:[config accentColor]];
            cell.titleLabel.text = config.customTitle ?: localize(@"i18n_str_283", nil);
            cell.valueLabel.text = self.latestRelease;
            cell.iconView.image = [UIImage systemImageNamed:config.iconName ?: @"cube.box.fill"];
            cell.iconView.tintColor = [config accentColor];
            return cell;
        }
            
        case HomeTileTypeVersionSnapshot: {
            HomeInfoTileCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"InfoCell" forIndexPath:indexPath];
            [cell setAccentColor:[config accentColor]];
            cell.titleLabel.text = config.customTitle ?: localize(@"i18n_str_284", nil);
            cell.valueLabel.text = self.latestSnapshot;
            cell.iconView.image = [UIImage systemImageNamed:config.iconName ?: @"ant.fill"];
            cell.iconView.tintColor = [config accentColor];
            return cell;
        }
            
        case HomeTileTypeAnnouncement: {
            HomeAnnouncementTileCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"AnnouncementCell" forIndexPath:indexPath];
            [cell setAccentColor:[config accentColor]];

            if (self.latestAnnouncement) {
                AnnouncementItem *ann = self.latestAnnouncement;
                NSString *previewLevel = getPrefObject(@"general.announcement_preview_level") ?: @"summary";

                if ([previewLevel isEqualToString:@"title_only"]) {
                    // 仅标题
                    cell.messageLabel.text = ann.title;
                } else if ([previewLevel isEqualToString:@"full"]) {
                    // 完整：标题 + 日期 + 摘要
                    cell.messageLabel.text = [NSString stringWithFormat:@"%@\n%@\n%@", ann.title, ann.formattedDateString, ann.summary];
                } else {
                    // summary（默认）：标题 + 摘要
                    cell.messageLabel.text = [NSString stringWithFormat:@"%@\n%@", ann.title, ann.summary];
                }

                // 如果有 actionURL，显示按钮
                if (ann.actionURL.length > 0 && ann.actionTitle.length > 0) {
                    cell.actionButton.hidden = NO;
                    [cell.actionButton setTitle:ann.actionTitle forState:UIControlStateNormal];
                    cell.actionButton.backgroundColor = colorFromHex(@"#3B82F6");
                    [cell.actionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                    [cell.actionButton removeTarget:nil action:nil forControlEvents:UIControlEventAllEvents];
                    [cell.actionButton addTarget:self action:@selector(openAnnouncementActionURL) forControlEvents:UIControlEventTouchUpInside];
                } else {
                    cell.actionButton.hidden = YES;
                }
            } else {
                // 无公告数据时显示更新检测结果
                cell.messageLabel.text = self.announcementText;

                if (self.hasUpdate) {
                    cell.actionButton.hidden = NO;
                    [cell.actionButton setTitle:localize(@"i18n_str_353", nil) forState:UIControlStateNormal];
                    cell.actionButton.backgroundColor = colorFromHex(@"#3B82F6");
                    [cell.actionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                    [cell.actionButton removeTarget:nil action:nil forControlEvents:UIControlEventAllEvents];
                    [cell.actionButton addTarget:self action:@selector(downloadLatestVersion) forControlEvents:UIControlEventTouchUpInside];
                } else {
                    cell.actionButton.hidden = YES;
                }
            }
            return cell;
        }
            
        case HomeTileTypeNews: {
            HomeNewsTileCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"NewsCell" forIndexPath:indexPath];
            [cell setAccentColor:[config accentColor]];

            if (self.latestNewsItem) {
                // 显示最新一条新闻的标题/摘要/封面
                cell.titleLabel.text = self.latestNewsItem.title ?: localize(@"i18n_str_285", nil);
                cell.summaryLabel.text = self.latestNewsItem.summary ?: @"";
                cell.placeholderLabel.text = self.latestNewsItem.formattedDateString ?: @"";
                // 加载封面图（用 IconLoader，带缓存）
                [IconLoader cancelLoadingForImageView:cell.thumbnailView];
                if (self.latestNewsItem.imageURL.length > 0) {
                    [IconLoader loadIconForImageView:cell.thumbnailView
                                                 URL:self.latestNewsItem.imageURL
                                         placeholder:[UIImage systemImageNamed:@"newspaper.fill"]
                                            fallback:[UIImage systemImageNamed:@"newspaper.fill"]
                                        targetSize:CGSizeMake(160, 120)];
                } else {
                    cell.thumbnailView.image = [UIImage systemImageNamed:@"newspaper.fill"];
                }
            } else if (self.isLoadingNews) {
                cell.titleLabel.text = localize(@"i18n_str_285", nil);
                cell.summaryLabel.text = localize(@"i18n_str_354", nil);
                cell.placeholderLabel.text = localize(@"i18n_str_40", nil);
                cell.thumbnailView.image = [UIImage systemImageNamed:@"newspaper.fill"];
            } else {
                // 加载失败或未加载
                cell.titleLabel.text = localize(@"i18n_str_285", nil);
                cell.summaryLabel.text = localize(@"i18n_str_355", nil);
                cell.placeholderLabel.text = localize(@"i18n_str_356", nil);
                cell.thumbnailView.image = [UIImage systemImageNamed:@"newspaper.fill"];
            }
            return cell;
        }
            
        case HomeTileTypeShortcut: {
            HomeShortcutTileCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"ShortcutCell" forIndexPath:indexPath];
            [cell setAccentColor:[config accentColor]];
            cell.titleLabel.text = config.customTitle ?: localize(@"i18n_str_286", nil);
            cell.iconView.image = [UIImage systemImageNamed:config.iconName ?: @"arrow.right.circle.fill"];
            cell.iconView.tintColor = [config accentColor];
            return cell;
        }
    }
    
    // Fallback
    return [collectionView dequeueReusableCellWithReuseIdentifier:@"InfoCell" forIndexPath:indexPath];
}

// MARK: - UICollectionView Delegate

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];

    // ★ [EDITMODE] 编辑模式下卡片点击不得误触跳转(此时点按/拖动只服务于排序与改尺寸)。
    if (self.homeEditing) return;

    HomeTileConfig *config = self.displaySections[indexPath.section][indexPath.item];

    if (config.tileType == HomeTileTypeShortcut) {
        [self handleShortcutAction:config.shortcutAction];
    } else if (config.tileType == HomeTileTypeVersionRelease || config.tileType == HomeTileTypeVersionSnapshot) {
        [self checkMinecraftVersions];
    } else if (config.tileType == HomeTileTypeNews) {
        // 跳转到 MC 新闻列表页
        MinecraftNewsViewController *newsVC = [[MinecraftNewsViewController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:newsVC];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        // 适配自定义启动器背景：透明化导航栏，让全局背景透出
        [self presentViewController:nav animated:YES completion:nil];
    } else if (config.tileType == HomeTileTypeAnnouncement) {
        // 跳转到公告列表页
        AnnouncementListViewController *listVC = [[AnnouncementListViewController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:listVC];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [self presentViewController:nav animated:YES completion:nil];
    }
}

// MARK: - Shortcut Actions

- (void)handleShortcutAction:(NSString *)action {
    // ★ [FIX2] 坑:模组 / 光影 / 整合包三个快捷入口原来 **只发通知**,而 RootVC 收到通知后会把
    //   【主页内容】整体换成 下载页 / 版本管理页 ⇒ 用户从子页返回后,主页就永久停在“实例下载”
    //   (用户实测:点整合包导入 → 返回 → 主页变成实例下载)。
    //   改法(沿用上次 createNewVersion 的 TABFIX 思路):优先「切到对应标签 + 在该标签自己的
    //   导航栈里 push 子页」—— 主页内容完全不被触碰;仅当不在标签栏(老流程)时回退到原通知行为。
    //   ★ 业务结果不变:导入/管理页该 push 还是 push,只是不再换主页。
    if ([action isEqualToString:kShortcutActionMods]) {
        // ★ [FIX2] 模组 → 「实例」标签(index 3)自己的栈里 push 模组管理
        if ([self fix2PushTab:3 pushes:[ModsManagerViewController class]
                       makeVC:^UIViewController *{ return [[ModsManagerViewController alloc] init]; }]) return;
        // 兜底:不在标签栏(老流程)保持原行为
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowModsManager" object:nil];

    } else if ([action isEqualToString:kShortcutActionShaders]) {
        // ★ [FIX2] 光影 → 「实例」标签(index 3);参数与原接收端 showShadersManager 一致
        if ([self fix2PushTab:3 pushes:[ShadersManagerViewController class]
                       makeVC:^UIViewController *{
                           ShadersManagerViewController *s = [[ShadersManagerViewController alloc] init];
                           s.initialMode = ShadersManagerModeLocal;
                           return s;
                       }]) return;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowShadersManager" object:nil];

    } else if ([action isEqualToString:kShortcutActionModpack]) {
        // ★ [FIX2] 整合包导入 → 「下载」标签(index 1);导入页 push 到下载标签自己的导航栈,
        //   导入流程照跑,主页内容不动 ⇒ 返回后不会再看到“实例下载”。
        if ([self fix2PushTab:1 pushes:[ModpackImportViewController class]
                       makeVC:^UIViewController *{ return [[ModpackImportViewController alloc] init]; }]) return;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowModpackImport" object:nil];

    } else if ([action isEqualToString:kShortcutActionBackground]) {
        BackgroundSettingsViewController *vc = [[BackgroundSettingsViewController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [self presentViewController:nav animated:YES completion:nil];

    } else if ([action isEqualToString:kShortcutActionVersions]) {
        // ★ [FIX3] 版本管理 → 「实例」标签(index 3)自己的导航栈。该标签的根页本即 VersionManagerViewController,
        //   fix2PushTab 会在栈里定位到已有同类实例并 pop 回去(不会重复 push),主页内容区完全不被替换;
        //   只有不在标签栏里(老流程)时才回退到原通知行为 —— 与上面 mods / shaders / modpack 三处的处理完全一致。
        //   根因:改造前这里只发 ShowVersionManager,LauncherRootViewController(:733)/LauncherCardLayoutViewController
        //   收到后会调 setContentViewController: 把【主页内容】整体换成版本管理页 ⇒ 用户从子页返回后主页
        //   就永久停在版本管理(即用户复现的“串台”)。
        if ([self fix2PushTab:3 pushes:[VersionManagerViewController class]
                       makeVC:^UIViewController *{ return [[VersionManagerViewController alloc] init]; }]) return;
        // 兜底:不在标签栏(老流程)保持原行为
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowVersionManager" object:nil];
    }
}

/// ★ [FIX2] 主页快捷入口的通用落地:优先切到 `tabIndex` 标签,并在**该标签自己的导航栈**里
///   push 一个 `vcClass` 页面(已存在则不重复 push)。这样主页内容区完全不被替换,
///   用户从子页返回 / 再回主页标签时看到的仍是主页。
///   @return YES = 已用标签栏处理完(调用方直接 return);NO = 当前不在标签栏里(老流程),
///           调用方回退到原来的通知行为 —— 业务结果与改造前完全一致。
- (BOOL)fix2PushTab:(NSInteger)tabIndex
             pushes:(Class)vcClass
             makeVC:(UIViewController * (^)(void))makeVC {
    if (!vcClass || !makeVC) return NO;
    UIViewController *rootVC = self.tabBarController;
    if (![rootVC isKindOfClass:[UITabBarController class]]) return NO;   // 不在标签栏 ⇒ 交给老流程
    UITabBarController *tbc = (UITabBarController *)rootVC;
    NSArray<UIViewController *> *tabs = tbc.viewControllers;
    if (tabIndex < 0 || tabIndex >= (NSInteger)tabs.count) return NO;
    UIViewController *tabVC = tabs[(NSUInteger)tabIndex];
    if (![tabVC isKindOfClass:[UINavigationController class]]) return NO;   // 结构不符 ⇒ 交给老流程
    UINavigationController *nav = (UINavigationController *)tabVC;

    tbc.selectedIndex = tabIndex;                    // ① 切到目标标签(只影响标签区,不碰任何页面内容)
    for (UIViewController *c in nav.viewControllers) {   // ② 栈里已有同类页面 ⇒ 直接回到它,不重复 push
        if ([c isKindOfClass:vcClass]) {
            [nav popToViewController:c animated:YES];
            return YES;
        }
    }
    [nav popToRootViewControllerAnimated:NO];        // ③ 否则先回本标签根页,保证不会越叠越多
    UIViewController *vc = makeVC();
    if (vc) [nav pushViewController:vc animated:YES];
    return YES;
}

// MARK: - Customize

- (void)openCustomize {
    HomeCustomizeViewController *customVC = [[HomeCustomizeViewController alloc] init];
    customVC.tileConfigs = [self.allTileConfigs copy];
    
    customVC.onConfigsChanged = ^(NSArray<HomeTileConfig *> *newConfigs) {
        // ★ [HOMEWIRE] ① 业务字段(可见性 / 类型 / 图标 / 标题 / 颜色 / action)照旧写 home_tiles_config,
        //   业务语义完全不变。
        [HomeTileConfig saveConfigs:newConfigs];
        // ★ [HOMEWIRE] ② 排版字段(顺序 + 尺寸)写「唯一排版真相源」ameHomeCardLayout;
        //   两个键各管各的字段,不互相覆盖整张表(详见 HOMEWIRE_REPORT.md)。
        AmeWriteBentoLayoutFromConfigs(newConfigs);
        // ★ [HOMEWIRE] ③ 广播 ⇒ 主页(可能多实例)重读两个键 + reloadData + invalidateLayout,立即生效。
        [[NSNotificationCenter defaultCenter] postNotificationName:AmeHomeCardLayoutChangedNotification
                                                            object:nil];
    };
    
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:customVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    
    // 毛玻璃背景
    if ([[BackgroundManager sharedManager] hasBackground]) {
        nav.view.backgroundColor = [UIColor clearColor];
    }
    
    [self presentViewController:nav animated:YES completion:nil];
}

// MARK: - ★ [EDITMODE] 主页「长按进编辑 / 拖拽排序 / 拖把手改尺寸」

#pragma mark 进入 / 退出编辑模式

/// ★ [EDITMODE] 长按卡片 ⇒ 进编辑模式:卡片轻微抖动 + 右下角出现改尺寸把手,
///   顶栏「⚙自定义」让位给同槽位的「✓ 完成」(约束一条不动,只切显隐)。
- (void)homeEditEnter {
    if (self.homeEditing) return;
    self.homeEditing = YES;
    self.homeMoveActive = NO;
    self.homeResizeActive = NO;
    self.homeResizeIndex = -1;
    self.customizeButton.hidden = YES;        // 让位给「✓ 完成」(同一个 trailing 槽位)
    self.homeEditDoneButton.hidden = NO;
    [self homeEditSetHeaderChromeHidden:YES];
    [self homeEditApplyAppearanceToVisibleCellsAnimated:YES];   // ★ [EDIT2] 动画进(把手弹入 + 卡片轻微浮起)
    NSLog(@"[EDITMODE] 进入编辑模式(%lu 张可见卡)", (unsigned long)(self.displaySections.firstObject.count));
}

/// ★ [EDITMODE] 编辑模式顶栏收窄:JIT 状态 / 执行 Jar / 选择版本 / 下载中心(+角标)/
///   ⚙自定义 全部隐起来,只留右侧「✓ 完成」。
///   目的:这几颗 pill 与「✓ 完成」共用同一条链式约束,隐掉它们 ⇒ 完成键独占右端,
///   即使「✓ 完成」比「⚙自定义」更宽也不可能压到别的 pill 上(零重叠风险,约束一条不改)。
///   只切 hidden,不动任何约束/几何 ⇒ 横竖屏都安全。
- (void)homeEditSetHeaderChromeHidden:(BOOL)hidden {
    self.norightJITPill.hidden = hidden;
    self.topbarExecuteJarPill.hidden = hidden;
    self.topbarVersionPickerPill.hidden = hidden;
    self.topbarDownloadCenterPill.hidden = hidden;
    self.topbarDownloadBadgeLabel.hidden = (hidden ? YES : (self.topbarDownloadBadgeText.length == 0));
}

/// ★ [EDITMODE] 「✓ 完成」= 退出编辑模式(并再写一次盘,幂等)。
/// ★ [EDIT2] 出口共三个、全部收敛在这里:①「✓ 完成」按钮 ②编辑态点空白 ③编辑态长按空白。
///   退出不再 reloadData(那是硬跳一闪):改为对可见卡做一次**动画收回**
///   (把手淡出 + 停抖动 + 恢复卡内交互);复用/滚入的卡由 prepareForReuse / willDisplayCell 再兜一层。
- (void)homeEditDoneTapped {
    if (!self.homeEditing) return;
    if (self.homeMoveActive) {                 // 兜底:理论上松手时已收干净
        self.homeMoveActive = NO;
        [self.collectionView cancelInteractiveMovement];
    }
    self.homeResizeActive = NO;
    self.homeResizeIndex = -1;
    [self homeEditPersistLayout];              // 顺序/尺寸落盘(与拖动、改尺寸同一真相源)
    self.homeEditing = NO;
    self.customizeButton.hidden = NO;
    self.homeEditDoneButton.hidden = YES;
    [self homeEditSetHeaderChromeHidden:NO];   // 顶栏 pill 复原(角标按当前下载状态回显)
    [self homeEditApplyAppearanceToVisibleCellsAnimated:YES];   // ★ [EDIT2] 动画收回把手 + 恢复卡内交互(不 reloadData)
    NSLog(@"[EDITMODE] 退出编辑模式(已写盘)");
}

#pragma mark 编辑态外观

- (void)homeEditApplyAppearanceToVisibleCells {
    [self homeEditApplyAppearanceToVisibleCellsAnimated:NO];
}

/// ★ [EDIT2] 动画版:进退编辑模式统一走它(animated=YES);复用/断言路径走 NO。
- (void)homeEditApplyAppearanceToVisibleCellsAnimated:(BOOL)animated {
    for (UICollectionViewCell *cell in self.collectionView.visibleCells) {
        [self homeEditApplyAppearanceToCell:cell animated:animated];
    }
}

- (void)homeEditApplyAppearanceToCell:(UICollectionViewCell *)cell {
    [self homeEditApplyAppearanceToCell:cell animated:NO];
}

- (void)homeEditApplyAppearanceToCell:(UICollectionViewCell *)cell animated:(BOOL)animated {
    if (![cell isKindOfClass:[HomeTileBaseCell class]]) return;
    HomeTileBaseCell *tileCell = (HomeTileBaseCell *)cell;
    [tileCell homeEditTransitionToEditing:self.homeEditing animated:animated];
    // 编辑模式下禁掉卡片内部交互(公告卡的按钮、欢迎卡头像手势…),避免点按误触业务;
    // 拖拽 / 改尺寸由挂在 collectionView 上的手势驱动,不经 contentView ⇒ 不受影响。
    // ★ [EDIT2] 退出时必须还原为 YES —— 上一版只在编辑态写 NO、退出不还原,卡内手势/按钮会永久失效(状态泄漏)。
    tileCell.contentView.userInteractionEnabled = !self.homeEditing;
}

#pragma mark 长按手势:进编辑 / 拖拽排序 / 拖把手改尺寸

/// ★ [EDITMODE] 一个长按手势扛三件事(浏览器态绝不误动布局):
///   · 未进编辑:长按 ⇒ 进编辑模式,并把按住的这张卡顺手“拎起来”(继续拖即排序);
///   · 已进编辑 + 按在卡片右下角把手命中区:本次拖动 = 改尺寸(实时换四档);
///   · 已进编辑 + 按在卡片其它位置:本次拖动 = 拖拽排序(UIKit interactive movement)。
- (void)homeEditLongPressed:(UILongPressGestureRecognizer *)gesture {
    UICollectionView *cv = self.collectionView;
    if (!cv) return;
    CGPoint point = [gesture locationInView:cv];

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            // ★ [EDIT3] 白名单让位已删除:卡片上不再有任何“自带长按”控件(头像的长按已移除),
            //   长按卡片任意位置(含欢迎卡头像)都直接走下面的「进编辑 / 拖拽 / 改尺寸」分支。
            NSIndexPath *ip = [cv indexPathForItemAtPoint:point];
            if (!self.homeEditing) {
                [self homeEditEnter];
                if (ip) {
                    self.homeMoveActive = YES;
                    [cv beginInteractiveMovementForItemAtIndexPath:ip];   // 长按即可继续拖(同 iOS 主屏幕)
                }
                return;
            }
            // ★ [EDIT2] 编辑态长按空白 ⇒ 退出编辑(与“点空白退出”对称的 toggle 手感)。
            if (!ip) { [self homeEditDoneTapped]; return; }

            NSInteger handleIndex = -1;
            if ([self homeEditPoint:point hitsResizeHandleOfIndex:&handleIndex]) {
                NSArray<HomeTileConfig *> *visible = self.displaySections.firstObject;
                if (handleIndex < 0 || handleIndex >= (NSInteger)visible.count) return;
                self.homeResizeActive    = YES;
                self.homeResizeIndex     = handleIndex;
                self.homeResizeStartPoint = point;
                self.homeResizeStartSize  = visible[(NSUInteger)handleIndex].tileSize;
                return;
            }
            self.homeMoveActive = YES;
            [cv beginInteractiveMovementForItemAtIndexPath:ip];
            break;
        }

        case UIGestureRecognizerStateChanged: {
            if (self.homeResizeActive) {
                [self homeEditUpdateResizeAtPoint:point];
                break;
            }
            if (self.homeMoveActive) {
                [cv updateInteractiveMovementTargetPosition:point];
            }
            break;
        }

        case UIGestureRecognizerStateEnded: {
            if (self.homeResizeActive) {
                self.homeResizeActive = NO;
                self.homeResizeIndex = -1;
                [self homeEditPersistLayout];                 // 松手写配置
                [cv.collectionViewLayout invalidateLayout];   // 按新档位重算占位网格
                // ★ [EDIT2] 不再 reloadData(硬跳/闪一下):尺寸变化已在拖动中动画消化,
                //   这里只按新档位重铺一次外观(把手由约束跟随 contentView,自动落位)。
                [self homeEditApplyAppearanceToVisibleCellsAnimated:NO];
                break;
            }
            if (self.homeMoveActive) {
                self.homeMoveActive = NO;
                [cv endInteractiveMovement];   // UIKit 随即回调 moveItemAtIndexPath:toIndexPath: ⇒ 那里写盘
            }
            break;
        }

        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            if (self.homeResizeActive) {
                self.homeResizeActive = NO;
                self.homeResizeIndex = -1;
                [cv.collectionViewLayout invalidateLayout];
                [self homeEditApplyAppearanceToVisibleCellsAnimated:NO];   // ★ [EDIT2] 同上:去掉 reloadData 硬跳
                break;
            }
            if (self.homeMoveActive) {
                self.homeMoveActive = NO;
                [cv cancelInteractiveMovement];
            }
            break;
        }

        default:
            break;
    }
}

#pragma mark ★ [EDIT2] 手势代理 + 编辑态点空白退出

/// ★ [EDIT2] 本页长按(进编辑/拖拽/改尺寸)与“点空白退出”的**唯一**触屏分发口。
/// ★ [EDIT3] 原来的“白名单让位”分支删除:本页长按现在对卡片上**所有**位置(含欢迎卡头像)一律接收,
///   于是长按头像也能进编辑,与系统主屏一致(头像的“自定义头像菜单”已移到账户管理页)。
///   · 点空白退出只在编辑态、且落点不在任何卡片上时才接收 ⇒ 非编辑态零介入。
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    UICollectionView *cv = self.collectionView;
    if (!cv) return YES;
    CGPoint point = [touch locationInView:cv];

    // ★ [EDIT3] homeEditLongPress 不再做任何让位判定:直接落到方法末尾的 return YES。
    if (gestureRecognizer == self.homeEditBlankTap) {
        if (!self.homeEditing) return NO;                        // 非编辑态完全不介入
        return [cv indexPathForItemAtPoint:point] == nil;         // 只认空白(落在卡片上不算)
    }
    return YES;
}

/// ★ [EDIT2] 编辑态点空白 ⇒ 退出编辑(与「✓ 完成」走同一出口:写盘 + 动画收回)。
- (void)homeEditBlankTapped:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    if (!self.homeEditing) return;
    [self homeEditDoneTapped];
}

#pragma mark 改尺寸:把手命中判定 + 拖动换档

/// ★ [EDITMODE] 命中判定:点是否落在某张卡「右下角把手」的命中矩形里。
///   坐标系说明:layoutAttributes.frame 是 collectionView **内容坐标系**,
///   与 locationInView:self.collectionView 同一坐标系 ⇒ 可直接比较(不受滚动偏移影响)。
///   命中矩形 = 视觉把手(26pt)向外扩 18pt 容差(手指比视觉大),仍远离卡片中部,不会误伤拖拽排序。
- (BOOL)homeEditPoint:(CGPoint)point hitsResizeHandleOfIndex:(NSInteger *)outIndex {
    UICollectionView *cv = self.collectionView;
    NSIndexPath *ip = [cv indexPathForItemAtPoint:point];
    if (!ip || ip.section != 0) return NO;
    UICollectionViewLayoutAttributes *attrs = [cv layoutAttributesForItemAtIndexPath:ip];
    if (!attrs) return NO;
    CGRect frame = attrs.frame;
    CGFloat side = kHomeEditHandleSize + kHomeEditHandleTouchSlop;
    CGRect hitRect = CGRectMake(CGRectGetMaxX(frame) - side, CGRectGetMaxY(frame) - side, side, side);
    if (!CGRectContainsPoint(hitRect, point)) return NO;
    if (outIndex) *outIndex = ip.item;
    return YES;
}

/// ★ [EDITMODE] 拖动把手 ⇒ 按位移阈值**实时**换档(向右过阈 = 加宽;向下过阈 = 加高;反向 = 缩回),
///   然后 invalidateLayout 让占位网格立刻重排(几何仍由 compositional layout 算,不硬摆 frame)。
- (void)homeEditUpdateResizeAtPoint:(CGPoint)point {
    if (!self.homeResizeActive) return;
    NSArray<HomeTileConfig *> *visible = self.displaySections.firstObject;
    if (self.homeResizeIndex < 0 || self.homeResizeIndex >= (NSInteger)visible.count) return;
    HomeTileConfig *config = visible[(NSUInteger)self.homeResizeIndex];

    UICollectionView *cv = self.collectionView;
    NSIndexPath *ip = [NSIndexPath indexPathForItem:self.homeResizeIndex inSection:0];
    UICollectionViewLayoutAttributes *attrs = [cv layoutAttributesForItemAtIndexPath:ip];
    CGFloat cardW = attrs ? CGRectGetWidth(attrs.frame) : 120.0;
    CGFloat cardH = attrs ? CGRectGetHeight(attrs.frame) : 120.0;

    CGFloat dx = point.x - self.homeResizeStartPoint.x;
    CGFloat dy = point.y - self.homeResizeStartPoint.y;
    CGFloat thX = MAX(kHomeEditResizeThresholdMin, cardW * kHomeEditResizeThresholdRatio);
    CGFloat thY = MAX(kHomeEditResizeThresholdMin, cardH * kHomeEditResizeThresholdRatio);

    // 一律以「本次起点的档位」为基准判断(而不是以当前档位)⇒ 全程不抖、可进可退。
    NSInteger startCols = AmeTileSpanColumns(self.homeResizeStartSize);
    NSInteger startRows = AmeTileSpanRows(self.homeResizeStartSize);
    NSInteger cols = (startCols >= 2) ? (dx > -thX ? 2 : 1) : (dx > thX ? 2 : 1);
    NSInteger rows = (startRows >= 2) ? (dy > -thY ? 2 : 1) : (dy > thY ? 2 : 1);

    // 四档一一对应(SIZE4 同一套语义):1×1 Small · 2×1 Wide · 1×2 Tall · 2×2 Large
    HomeTileSize newSize = (cols >= 2) ? (rows >= 2 ? HomeTileSizeLarge : HomeTileSizeWide)
                                       : (rows >= 2 ? HomeTileSizeTall  : HomeTileSizeSmall);
    if (newSize == config.tileSize) return;   // 同档不折腾布局

    config.tileSize = newSize;
    // ★ [EDIT2] 换档时把网格重排包进弹簧动画(对齐系统主屏:其余卡片平滑让位),
    //   替换上一版 performWithoutAnimation 的硬跳;BeginFromCurrentState ⇒ 连续跨档也不打架。
    [UIView animateWithDuration:0.26 delay:0
         usingSpringWithDamping:0.82 initialSpringVelocity:0.4
                        options:(UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState)
                     animations:^{
        [cv.collectionViewLayout invalidateLayout];
        [cv layoutIfNeeded];
    } completion:nil];
    NSLog(@"[EDITMODE] 拖动改尺寸 → %@ (%@)", AmeTileSizeShortName(newSize), config.tileId ?: @"?");
}

#pragma mark 写配置(唯一真相源)

/// ★ [EDITMODE] 把「可见卡的新顺序」写回 allTileConfigs:可见卡按新顺序在前,
///   不可见卡保持原相对顺序跟在后面(配置里没提到的卡不会丢)。只搬元素,不动任何业务字段。
- (void)homeEditRebuildAllConfigsFromVisibleOrder {
    NSArray<HomeTileConfig *> *visible = self.displaySections.firstObject ?: @[];
    NSMutableArray<HomeTileConfig *> *ordered = [NSMutableArray arrayWithCapacity:self.allTileConfigs.count];
    NSMutableSet<NSString *> *used = [NSMutableSet set];
    for (HomeTileConfig *config in visible) {
        [ordered addObject:config];
        if (config.tileId.length > 0) [used addObject:config.tileId];
    }
    for (HomeTileConfig *config in self.allTileConfigs) {
        if (config.tileId.length > 0 && [used containsObject:config.tileId]) continue;   // 已在可见段
        [ordered addObject:config];
    }
    self.allTileConfigs = ordered;
}

/// ★ [EDITMODE] 落盘 = 与 ⚙自定义面板完全相同的两个键(双向一致的根据):
///   ① home_tiles_config([HomeTileConfig saveConfigs:])—— 面板 openCustomize 读的配置,
///      顺序 + tileSize 一并写回 ⇒ 面板再打开看到的就是主页刚拖出来的布局;
///   ② ameHomeCardLayout(AmeWriteBentoLayoutFromConfigs(),与面板保存走同一个 static 写入函数)
///      —— 唯一排版真相源(顺序 + size 码位 1..4),下次启动 configsByApplyingStoredBentoLayout: 照它重排。
///   不新建第二套配置、不复制面板的写入逻辑。
- (void)homeEditPersistLayout {
    if (self.allTileConfigs.count == 0) return;
    [HomeTileConfig saveConfigs:self.allTileConfigs];
    AmeWriteBentoLayoutFromConfigs(self.allTileConfigs);
    NSLog(@"[EDITMODE] 布局已写盘(%lu 张卡)", (unsigned long)self.allTileConfigs.count);
}

// MARK: - Data Loading

- (void)updateSkinDisplay {
    BaseAuthenticator *auth = BaseAuthenticator.current;
    
    if (auth && auth.authData) {
        NSString *username = auth.authData[@"username"];
        if (username) {
            if ([username hasPrefix:@"Demo."]) {
                username = [username substringFromIndex:5];
            }
            self.currentUsername = username;
        } else {
            self.currentUsername = localize(@"i18n_str_351", nil);
        }
        
        // 加载头像 (与右侧面板相同来源)
        NSString *avatarURL = auth.authData[@"profilePicURL"];
        if (avatarURL) {
            avatarURL = [avatarURL stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:avatarURL]];
                if (data) {
                    UIImage *img = [UIImage imageWithData:data];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        self.currentAvatar = img;
                        [self reloadProfileSection];
                    });
                }
            });
        }
        
        // 加载皮肤全身图 (原有API)
        NSString *uuid = auth.authData[@"uuid"];
        if (uuid) {
            [self loadSkinForUUID:uuid];
        } else {
            [self loadDefaultSkin];
        }
    } else {
        self.currentUsername = localize(@"i18n_str_357", nil);
        self.currentAvatar = nil;
        [self loadDefaultSkin];
    }
    
    [self reloadProfileSection];
}

- (void)loadSkinForUUID:(NSString *)uuid {
    NSString *skinURL = [NSString stringWithFormat:@"http://111.170.35.224:3000/renders/body/%@?overlay", uuid];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:skinURL]];
        UIImage *skin = data ? [UIImage imageWithData:data] : nil;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (skin) {
                self.currentSkin = skin;
            } else {
                [self loadDefaultSkin];
                return;
            }
            [self reloadProfileSection];
        });
    });
}

- (void)loadDefaultSkin {
    NSString *steveSkinURL = @"http://111.170.35.224:3000/renders/body/8667ba71b85a4004af54457a9734eed7?overlay";
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:steveSkinURL]];
        UIImage *steve = data ? [UIImage imageWithData:data] : nil;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            self.currentSkin = steve ?: [UIImage systemImageNamed:@"person.fill"];
            [self reloadProfileSection];
        });
    });
}

- (void)reloadProfileSection {
    // 找到 Profile 类型的 section 并刷新
    for (NSInteger s = 0; s < self.displaySections.count; s++) {
        for (HomeTileConfig *tile in self.displaySections[s]) {
            if (tile.tileType == HomeTileTypeProfile) {
                [self.collectionView reloadSections:[NSIndexSet indexSetWithIndex:s]];
                return;
            }
        }
    }
}

- (void)loadLatestNewsForTile {
    if (self.isLoadingNews) return;
    self.isLoadingNews = YES;
    __weak typeof(self) weakSelf = self;
    [[MinecraftNewsService sharedService] fetchLatestNewsWithCompletion:^(NSArray<MinecraftNewsItem *> *items, NSInteger totalCount, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.isLoadingNews = NO;
        if (items.count > 0) {
            strongSelf.latestNewsItem = items.firstObject;
        }
        // 刷新 News tile 显示最新标题/摘要/封面
        [strongSelf reloadNewsSection];
    }];
}

/// 重新加载 News tile 所在 section
- (void)reloadNewsSection {
    for (NSInteger s = 0; s < self.displaySections.count; s++) {
        for (HomeTileConfig *tile in self.displaySections[s]) {
            if (tile.tileType == HomeTileTypeNews) {
                [self.collectionView reloadSections:[NSIndexSet indexSetWithIndex:s]];
                return;
            }
        }
    }
}

- (void)checkMinecraftVersions {
    self.isLoadingVersions = YES;
    self.latestRelease = localize(@"i18n_str_347", nil);
    self.latestSnapshot = localize(@"i18n_str_347", nil);
    [self reloadVersionSections];
    
    NSString *downloadSource = getPrefObject(@"general.download_source");
    NSString *url;
    if ([downloadSource isEqualToString:@"bmclapi"]) {
        url = @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json";
    } else {
        url = @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
    }
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:url] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isLoadingVersions = NO;
            if (data && !error) {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (json) {
                    NSDictionary *latest = json[@"latest"];
                    self.latestRelease = latest[@"release"] ?: localize(@"i18n_str_121", nil);
                    self.latestSnapshot = latest[@"snapshot"] ?: localize(@"i18n_str_121", nil);
                } else {
                    self.latestRelease = localize(@"i18n_str_358", nil);
                    self.latestSnapshot = localize(@"i18n_str_358", nil);
                }
            } else {
                self.latestRelease = localize(@"i18n_str_202", nil);
                self.latestSnapshot = localize(@"i18n_str_202", nil);
            }
            [self reloadVersionSections];
        });
    }];
    [task resume];
}

- (void)reloadVersionSections {
    for (NSInteger s = 0; s < self.displaySections.count; s++) {
        for (HomeTileConfig *tile in self.displaySections[s]) {
            if (tile.tileType == HomeTileTypeVersionRelease || tile.tileType == HomeTileTypeVersionSnapshot) {
                [self.collectionView reloadSections:[NSIndexSet indexSetWithIndex:s]];
                return;
            }
        }
    }
}

// MARK: - Update Check

- (void)checkForUpdate {
    NSString *currentVersion = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
    
    if ([currentVersion rangeOfString:@"Preview" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        self.announcementText = localize(@"i18n_str_359", nil);
        self.hasUpdate = NO;
        [self reloadAnnouncementSection];
        return;
    }
    
    NSURL *url = [NSURL URLWithString:@"https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/releases/latest"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"GET"];
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || ((NSHTTPURLResponse *)response).statusCode != 200 || !data) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.announcementText = localize(@"i18n_str_360", nil);
                self.hasUpdate = NO;
                [self reloadAnnouncementSection];
            });
            return;
        }
        
        NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSString *latestVer = [self extractVersionFromHTML:html];
        
        if (!latestVer) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.announcementText = localize(@"i18n_str_360", nil);
                self.hasUpdate = NO;
                [self reloadAnnouncementSection];
            });
            return;
        }
        
        if ([latestVer hasPrefix:@"v"]) {
            latestVer = [latestVer substringFromIndex:1];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            NSComparisonResult cmp = [self compareVersion:currentVersion withVersion:latestVer];
            if (cmp == NSOrderedAscending) {
                self.announcementText = [NSString stringWithFormat:localize(@"i18n_str_361", nil), latestVer];
                self.latestVersion = latestVer;
                self.hasUpdate = YES;
            } else {
                self.announcementText = localize(@"i18n_str_362", nil);
                self.hasUpdate = NO;
            }
            [self reloadAnnouncementSection];
        });
    }];
    [task resume];
}

- (void)reloadAnnouncementSection {
    for (NSInteger s = 0; s < self.displaySections.count; s++) {
        for (HomeTileConfig *tile in self.displaySections[s]) {
            if (tile.tileType == HomeTileTypeAnnouncement) {
                [self.collectionView reloadSections:[NSIndexSet indexSetWithIndex:s]];
                return;
            }
        }
    }
}

// MARK: - Announcements (官网 JSON 公告)

/// 为首页公告磁贴拉取最新公告（取首条），失败时回退到更新检测文案
- (void)loadAnnouncementsForTile {
    __weak typeof(self) weakSelf = self;
    [[AnnouncementService sharedService] fetchAnnouncementsWithCompletion:^(NSArray<AnnouncementItem *> *items, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (items.count > 0) {
            strongSelf.latestAnnouncement = items.firstObject;
        }
        [strongSelf reloadAnnouncementSection];
    }];
}

/// 打开公告磁贴上 actionURL 指向的链接（SFSafariViewController 内嵌打开）
- (void)openAnnouncementActionURL {
    if (self.latestAnnouncement.actionURL.length > 0) {
        NSURL *url = [NSURL URLWithString:self.latestAnnouncement.actionURL];
        if (url) {
            SFSafariViewController *safari = [[SFSafariViewController alloc] initWithURL:url];
            safari.modalPresentationStyle = UIModalPresentationPageSheet;
            [self presentViewController:safari animated:YES completion:nil];
        }
    }
}

- (NSString *)extractVersionFromHTML:(NSString *)html {
    NSRange titleRange = [html rangeOfString:@"<title>"];
    if (titleRange.location == NSNotFound) return nil;
    
    NSString *afterTitle = [html substringFromIndex:NSMaxRange(titleRange)];
    NSRange endTitleRange = [afterTitle rangeOfString:@"</title>"];
    if (endTitleRange.location == NSNotFound) return nil;
    
    NSString *titleContent = [afterTitle substringToIndex:endTitleRange.location];
    
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"v([0-9]+\\.[0-9]+\\.[0-9]+)" options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:titleContent options:0 range:NSMakeRange(0, titleContent.length)];
    
    if (match) {
        return [titleContent substringWithRange:[match rangeAtIndex:1]];
    }
    return nil;
}

- (NSComparisonResult)compareVersion:(NSString *)v1 withVersion:(NSString *)v2 {
    NSArray *c1 = [v1 componentsSeparatedByString:@"."];
    NSArray *c2 = [v2 componentsSeparatedByString:@"."];
    NSInteger max = MAX(c1.count, c2.count);
    
    for (NSInteger i = 0; i < max; i++) {
        NSInteger n1 = (i < c1.count) ? [c1[i] integerValue] : 0;
        NSInteger n2 = (i < c2.count) ? [c2[i] integerValue] : 0;
        if (n1 < n2) return NSOrderedAscending;
        if (n1 > n2) return NSOrderedDescending;
    }
    return NSOrderedSame;
}

- (void)downloadLatestVersion {
    NSString *urlString = @"https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/releases/latest";
    NSURL *url = [NSURL URLWithString:urlString];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

// MARK: - Cell Fade-In Animation

- (void)collectionView:(UICollectionView *)collectionView willDisplayCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath {
    // ★ [EDITMODE] 编辑模式:显隐把手 + 抖动,且**不做**入场缩放动画
    //   (入场动画写的是 cell.transform,会和抖动/拖动中的卡片视觉打架)。
    // ★ [EDIT2] 不论是否编辑态,都先按当前编辑态**断言一次**外观(把手显隐 / 卡内交互 / 抖动):
    //   复用池里带出来的“残留把手”在这条必经之路上被清掉 —— “退出后把手不再残留”的第二道保险。
    [self homeEditApplyAppearanceToCell:cell animated:NO];
    if (self.homeEditing) {
        cell.alpha = 1;
        cell.transform = CGAffineTransformIdentity;
        return;
    }
    cell.alpha = 0;
    cell.transform = CGAffineTransformMakeTranslation(0, 12);
    [UIView animateWithDuration:0.35 delay:indexPath.section * 0.04 usingSpringWithDamping:0.85 initialSpringVelocity:0.3 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        cell.alpha = 1;
        cell.transform = CGAffineTransformIdentity;
    } completion:nil];
}

// MARK: - ★ [EDITMODE] 拖拽排序(UIKit 自带 interactive movement 的数据源两件套)

/// ★ [EDITMODE] 只有编辑模式允许拖动换位(非编辑模式下 UIKit 根本不会发起 movement,
///   这里再兜一层,确保“浏览态绝不误动布局”)。
- (BOOL)collectionView:(UICollectionView *)collectionView canMoveItemAtIndexPath:(NSIndexPath *)indexPath {
    return self.homeEditing && indexPath.section == 0;
}

/// ★ [EDITMODE] 松手落位:只改「可见卡片的顺序」,然后把新顺序同步回
///   allTileConfigs 并写盘(唯一真相源 ameHomeCardLayout + 面板读的 home_tiles_config)。
///   卡片类型/图标/点击/数据源一律不动 —— 这里只搬数组元素。
- (void)collectionView:(UICollectionView *)collectionView
    moveItemAtIndexPath:(NSIndexPath *)sourceIndexPath
            toIndexPath:(NSIndexPath *)destinationIndexPath {
    if (!self.homeEditing) return;
    NSArray<HomeTileConfig *> *visible = self.displaySections.firstObject ?: @[];
    if (sourceIndexPath.item >= visible.count || destinationIndexPath.item >= visible.count) return;

    NSMutableArray<HomeTileConfig *> *items = [visible mutableCopy];
    HomeTileConfig *moved = items[(NSUInteger)sourceIndexPath.item];
    [items removeObjectAtIndex:(NSUInteger)sourceIndexPath.item];
    [items insertObject:moved atIndex:(NSUInteger)destinationIndexPath.item];
    NSArray<HomeTileConfig *> *newVisibleOrder = [items copy];
    self.displaySections = @[ newVisibleOrder ];

    // 顺序真相:可见卡按新顺序在前,不可见卡保持原相对顺序在后(配置里没提到的卡不会丢)。
    [self homeEditRebuildAllConfigsFromVisibleOrder];
    // 落盘:两个键一起写 —— 主页下次启动 / ⚙自定义面板重开时读到的是同一份新布局。
    [self homeEditPersistLayout];
}

// MARK: - ★ [HOME6] 卡片编排配置(顺序 + 尺寸)

/// ★ [HOME6] 默认编排 = home6.html 的顺序与尺寸。
///   ★ [SIZE4] "size":1=Small(1×1) 2=Wide(2×1) 3=Tall(1×2) 4=Large(2×2) —— 默认只用 1/2(与旧数据同值)。
+ (NSArray<NSDictionary *> *)defaultBentoLayout {
    return @[
        @{@"id": @"profile",          @"size": @2},
        @{@"id": @"announcement",     @"size": @2},
        @{@"id": @"latest_release",   @"size": @1},
        @{@"id": @"latest_snapshot",  @"size": @1},
        @{@"id": @"news",             @"size": @2},
        @{@"id": @"shortcut_mods",    @"size": @1},
        @{@"id": @"shortcut_shaders", @"size": @1},
        @{@"id": @"shortcut_modpack", @"size": @1},
        @{@"id": @"shortcut_bg",      @"size": @1},
    ];
}

/// ★ [HOME6] 读 ameHomeCardLayout:按它重排卡片顺序 + 覆盖尺寸(只动顺序/尺寸这两个外观属性,
///   可见性 / 类型 / 图标 / 点击 action 全部不动)。
///   未存过 ⇒ 写入默认布局(不留"半成品开关");配置里没提到的卡片按原顺序追加,保证不漏卡。
- (NSArray<HomeTileConfig *> *)configsByApplyingStoredBentoLayout:(NSArray<HomeTileConfig *> *)configs {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *stored = [ud arrayForKey:kAmeHomeCardLayoutKey];
    if (![stored isKindOfClass:[NSArray class]] || stored.count == 0) {
        stored = [LauncherNewsViewController defaultBentoLayout];
        [ud setObject:stored forKey:kAmeHomeCardLayoutKey];   // 首次写回默认
        [ud synchronize];
    }

    NSMutableDictionary<NSString *, HomeTileConfig *> *byId = [NSMutableDictionary dictionary];
    for (HomeTileConfig *c in configs) {
        if (c.tileId.length > 0) byId[c.tileId] = c;
    }

    NSMutableArray<HomeTileConfig *> *ordered = [NSMutableArray arrayWithCapacity:configs.count];
    NSMutableSet<NSString *> *used = [NSMutableSet set];
    for (NSDictionary *entry in stored) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSString *tileId = entry[@"id"];
        if (![tileId isKindOfClass:[NSString class]]) continue;
        HomeTileConfig *c = byId[tileId];
        if (c == nil || [used containsObject:tileId]) continue;
        NSNumber *size = entry[@"size"];
        if ([size isKindOfClass:[NSNumber class]]) {
            c.tileSize = AmeTileSizeForSizeCode(size.integerValue);   // ★ [SIZE4] 1/2 兼容旧值,3=Tall 4=Large
        }
        [ordered addObject:c];
        [used addObject:tileId];
    }
    for (HomeTileConfig *c in configs) {
        if (c.tileId.length == 0 || ![used containsObject:c.tileId]) [ordered addObject:c];
    }
    return [ordered copy];
}

/// ★ [HOMEWIRE] 自定义面板保存后:重读两个键并按 ameHomeCardLayout 重排主页(立即生效)。
///   home_tiles_config ⇒ 业务字段(可见性 / 类型 / 图标 / …);ameHomeCardLayout ⇒ 顺序 + 尺寸。
///   几何仍交给 compositional layout:只 reloadData + invalidateLayout,不硬摆 frame。
- (void)handleHomeCardLayoutChanged:(NSNotification *)note {
    NSArray<HomeTileConfig *> *saved = [HomeTileConfig loadSavedConfigs];
    self.allTileConfigs = [[self configsByApplyingStoredBentoLayout:saved] mutableCopy];
    [self rebuildDisplaySections];
    [self.collectionView reloadData];
    [self.collectionView.collectionViewLayout invalidateLayout];
}

// MARK: - ★ [HOME6] 朝向与安全区(横竖屏切换的唯一入口)

/// ★ [HOME6] 实时朝向:优先问 windowScene(旋转进行中 bounds 可能尚未更新),退化用 bounds 比对。
- (BOOL)homeIsLandscape {
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = self.view.window.windowScene;
        if (scene) return UIInterfaceOrientationIsLandscape(scene.interfaceOrientation);
    }
    CGSize s = self.view.bounds.size;
    return s.width > s.height;
}

/// ★ [HOME6] 激活 / 停用两套头部约束集(横屏激活横屏那套、竖屏激活竖屏那套,先停另一套)。
- (void)activateHeaderConstraintsForLandscape:(BOOL)landscape {
    NSArray<NSLayoutConstraint *> *p = self.headerPortraitConstraints ?: @[];
    NSArray<NSLayoutConstraint *> *l = self.headerLandscapeConstraints ?: @[];
    if (landscape) {
        [NSLayoutConstraint deactivateConstraints:p];
        [NSLayoutConstraint activateConstraints:l];
    } else {
        [NSLayoutConstraint deactivateConstraints:l];
        [NSLayoutConstraint activateConstraints:p];
    }
}

/// ★ [HOME6] 按「实时」安全区重排:横屏岛侧(≈59)让开、另一侧贴边(0);底部 Home 条 / 标签栏。
///   全程不缓存旧值 ⇒ 旋转后不会残留上一朝向的内边距。
///   ★ 卡片本身不在这里摆 frame —— 它们是 UICollectionViewCell,几何由 compositional layout 计算;
///     这里只更新「实时安全区 + 列数」参数并 invalidate,布局随之整体重算。
- (void)applyHomeSafeAreaInsets {
    UIEdgeInsets sa = self.view.safeAreaInsets;
    self.homeSafeInsets = sa;                       // 供布局 provider 实时读取
    NSLog(@"[HOME6] safeArea l=%.0f t=%.0f r=%.0f b=%.0f landscape=%d",
          sa.left, sa.top, sa.right, sa.bottom, [self homeIsLandscape] ? 1 : 0);

    self.customizeButton.layer.borderColor = AmeGlassRimColor().CGColor;   // ★ [HOME6] 深浅色切换后刷新胶囊描边

    UICollectionView *cv = self.collectionView;
    if (cv) {
        // 顶部由 headerView 承担;左右交给 section contentInsets(bentoSectionWithGroup:);底部在此兜底。
        // ★ [NORIGHT] 底部再补「启动胶囊高 + 呼吸」⇒ 最后一张卡不会被底部启动胶囊压住。
        CGFloat norightBottomRoom = kNoRightCapsuleHeight + 10.0;
        cv.contentInset = UIEdgeInsetsMake(0, 0, sa.bottom + kBentoEdgeV + norightBottomRoom, 0);
        cv.verticalScrollIndicatorInsets = UIEdgeInsetsMake(0, 0, sa.bottom, 0);
    }

    // ★ [NORIGHT] 底部启动胶囊宽度:竖屏接近满宽、横屏收到 320(紧凑胶囊,不拉成整条)。
    //   只用一条**等宽**约束的 constant 表达 ⇒ 同一个属性只有一条约束(无双钉)。
    if (self.norightCapsuleWidth) {
        CGFloat avail = self.view.bounds.size.width - 32.0;
        if (avail <= 0) avail = kNoRightCapsuleMaxW;
        self.norightCapsuleWidth.constant = MIN(avail, kNoRightCapsuleMaxW);
    }

    [self activateHeaderConstraintsForLandscape:[self homeIsLandscape]];

    // ★ [TOPBAR2] 朝向变了 ⇒ 顶栏动作 pill 在「图标-only(竖屏)/ 图标+小字(横屏)」之间切文案
    [self norightApplyTopBarPillTitlesForLandscape:[self homeIsLandscape]];
    if (self.topbarExecuteJarPill) {   // 顶栏 pill 一定在(防御:安全区回调早于 setupHeader 时也不会崩)
        for (UIButton *p in @[self.topbarExecuteJarPill, self.topbarVersionPickerPill, self.topbarDownloadCenterPill]) {
            p.layer.borderColor = AmeGlassRimColor().CGColor;   // ★ [TOPBAR2] 深浅色切换后刷新胶囊描边
            p.backgroundColor = AmeGlassFillColor();
        }
    }

    // ★ [HOME6] 切换后必须重算:invalidate 让 provider 用新的 safeInsets / 列数重建 section,
    //   setNeedsLayout 让头部两套约束的新位置立即生效。
    [cv.collectionViewLayout invalidateLayout];
    [self.view setNeedsLayout];
}

/// ★ [HOME6] 安全区变化(旋转 / 分屏 / 状态栏)入口
- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self applyHomeSafeAreaInsets];
}

/// ★ [HOME6] 特征变化(旋转 / 深色浅色 / 分屏)入口 —— 只在「朝向真的变了」时重排,避免无谓重刷。
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    BOOL landscape = [self homeIsLandscape];
    if (previousTraitCollection == nil || landscape != self.homeUIWasLandscape) {
        self.homeUIWasLandscape = landscape;
        [self applyHomeSafeAreaInsets];
    }
}

// MARK: - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    // ★ [PORTRAIT-UNLOCK] 放开竖屏:原来是写死 Landscape ⇒ iPhone 上竖屏进不来
    //   (主页是该 VC,它锁横屏 ⇒ 整个 App 被钉在横屏)。游戏页仍单独锁横屏。
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) { return UIInterfaceOrientationMaskAll; }
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

/// 重新应用背景效果：当 BackgroundUIEffectChanged 通知到达时调用，
/// 通过 BackgroundManager 重新设置当前视图控制器的透明度/毛玻璃效果，
/// 并手动清空 collectionView 背景色（UICollectionView 无 backgroundView 属性），
/// 确保全局背景能够正常透出。
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.collectionView.backgroundColor = [UIColor clearColor];
}

@end