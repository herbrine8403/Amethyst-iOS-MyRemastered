#import "LauncherCardLayoutViewController.h"
#import "LauncherMenuViewController.h"
#import "UIViewController+AMEPanel.h"   // ★ 子面板原生基底样式(移植)
#import "LauncherNewsViewController.h"
#import "LauncherRightPanelViewController.h"
#import "DownloadViewController.h"
#import "VersionManagerViewController.h"
#import "ProfileSettingsViewController.h"
#import "LauncherPreferencesViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "BackgroundManager.h"
#import "UIKit+GlassSurface.h"   // ★ [E1] 液态玻璃材质 + 高光描边助手(纯头文件,不新增 .m ⇒ 不改 CMake 源列表)
#import "PLProfiles.h"
#import "utils.h"
#import "ModsManagerViewController.h"
#import "ShadersManagerViewController.h"
#import "ModpackImportViewController.h"
#import "LauncherPrefGameDirViewController.h"
#import "CustomControlsViewController.h"
// ZeroTier/Terracotta 联机暂时移除（排查启动崩溃）
// #import "MultiplayerViewController.h"
// #import "TerracottaViewController.h"
// #import "TerracottaManager.h"
// #import "TerracottaBridge.h"
#import "AccountListViewController.h"
#import "AI/AIViewController.h"
#import "AI/AiSessionStore.h"

// 布局常量（iPad/宽屏基准值；iPhone 上通过 traitCollection 适配后会变窄）
static const CGFloat kSidebarWidthPad = 70.0;      // iPad 左侧边栏卡片宽度
static const CGFloat kSidebarWidthPhone = 56.0;    // iPhone 左侧边栏卡片宽度（仅图标）
static const CGFloat kRightPanelWidthPad = 220.0;  // iPad 右侧面板卡片宽度
static const CGFloat kRightPanelWidthPhone = 168.0; // iPhone 右侧面板卡片宽度（保证启动/JAR 按钮可读）
static const CGFloat kCardSpacing = 12.0;          // 卡片间距
static const CGFloat kCardOuterMarginPad = 12.0;   // iPad 卡片到外边缘的间距
static const CGFloat kCardOuterMarginPhone = 8.0;  // iPhone 卡片到外边缘的间距（窄屏减小留白）
static const CGFloat kCardCornerRadius = 16.0;     // 卡片圆角

// ★ [UI-A][PORTRAIT-FIX] 竖屏底部菜单条高度:菜单按钮 50pt + stack 上下内边距 8+8 = 66pt,
//   取 72 留 6pt 余量,避免按钮被 sidebarCard 的圆角 + masksToBounds 裁掉 1~2pt。
static const CGFloat kPortraitMenuBarHeight = 72.0;

/// 检测物理设备是否为 iPhone（不受 debug.debug_ipad_ui 的 idiom hook 影响）。
/// UIKit+hook.m 会把 idiom 强制改成 Pad，导致 trait.userInterfaceIdiom 不可靠。
/// 这里用 UIDevice.model 检测真实设备类型。
static BOOL LauncherCardLayoutIsPhysicalPhone(void) {
    NSString *model = [[UIDevice currentDevice].model lowercaseString];
    return [model containsString:@"iphone"];
}

/// 根据物理设备类型决定卡片外边距
static CGFloat LauncherCardLayoutOuterMargin(UITraitCollection *trait) {
    if (LauncherCardLayoutIsPhysicalPhone()) return kCardOuterMarginPhone;
    return kCardOuterMarginPad;
}

/// 根据物理设备类型决定侧栏宽度
/// - iPhone 横屏（含 SE/8/Plus/X/Pro Max）：56pt（菜单只有图标，56pt 足够）
/// - iPad：70pt
static CGFloat LauncherCardLayoutSidebarWidth(UITraitCollection *trait) {
    if (LauncherCardLayoutIsPhysicalPhone()) return kSidebarWidthPhone;
    return kSidebarWidthPad;
}

/// 根据物理设备类型决定右侧面板宽度
/// - iPhone 横屏：168pt（保证启动/编辑控件/执行 Jar 按钮文字不截断）
/// - iPad：220pt
static CGFloat LauncherCardLayoutRightPanelWidth(UITraitCollection *trait) {
    if (LauncherCardLayoutIsPhysicalPhone()) return kRightPanelWidthPhone;
    return kRightPanelWidthPad;
}

#pragma mark - ★ [E1] E 方案(Liquid Glass)设计令牌 — SPEC §2 深/浅两套
// 说明:本区所有取值逐条来自 _uiwork/D/SPEC.md §2(深色/浅色两套),单位 pt。
// 保留既有 BackgroundManager(背景图/视频、卡片色、玻璃强度)不动,只在其上叠 E 方案的几何与颜色。

static const CGFloat kE1RadiusHero         = 22.0;   // 顶部大卡(面板卡)   SPEC §2.2 (22~26)
static const CGFloat kE1RadiusCard         = 16.0;   // 普通实例卡           SPEC §2.2
static const CGFloat kE1RadiusIconHero     = 13.0;   // 大卡图标块(40×40)   SPEC §2.2
static const CGFloat kE1RadiusIcon         = 10.0;   // 普通卡图标块(32×32) SPEC §2.2
static const CGFloat kE1GridGapPortrait    = 11.0;   // 竖屏网格 gap         SPEC §2.3
static const CGFloat kE1GridGapLandscape   = 12.0;   // 横屏网格 gap(真尺寸) SPEC §2.3
static const CGFloat kE1MarginPortrait     = 14.0;   // 竖屏屏边留白         SPEC §2.3
static const CGFloat kE1MarginLandscape    = 12.0;   // 横屏屏边留白         SPEC §2.3
static const CGFloat kE1HeroHeightPortrait = 82.0;   // 竖屏大卡高(行式:40 图标 + 标题/副文/药丸三行)
static const CGFloat kE1CardHeightPortrait = 126.0;  // 竖屏普通卡高(32 图标/标题/副文/启动键 30)
static const CGFloat kE1HeroHeightLandscape= 112.0;  // 横屏大卡高(与同行普通卡等高 ⇒ 行内卡片齐平)
static const CGFloat kE1CardHeightLandscape= 112.0;  // 横屏普通卡高(30 图标/标题/副文/启动键 26)

/// 是否按"深色令牌"取色。un-specified 也按深色 —— 与启动器默认紫蓝背景(深)保持一致。
static BOOL E1UsesDarkTokens(UITraitCollection *tc) {
    return (tc.userInterfaceStyle != UIUserInterfaceStyleLight);
}

static UIColor *E1HexColor(unsigned int rgb) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

// ---- SPEC §2.1 颜色令牌(深色 / 浅色) ----
static UIColor *E1ColorAccent(BOOL dark) { return E1HexColor(dark ? 0x0A84FF : 0x007AFF); }
static UIColor *E1ColorFG(BOOL dark)     { return dark ? [UIColor whiteColor] : E1HexColor(0x0B0B0C); }
static UIColor *E1ColorDim(BOOL dark)    { return dark ? [UIColor colorWithWhite:1.0 alpha:0.58]
                                                       : [UIColor colorWithWhite:0.0 alpha:0.55]; }
static UIColor *E1ColorGlass(BOOL dark)  { return dark ? [UIColor colorWithWhite:1.0 alpha:0.10]
                                                       : [UIColor colorWithWhite:1.0 alpha:0.55]; }
static UIColor *E1ColorGlass2(BOOL dark) { return dark ? [UIColor colorWithWhite:1.0 alpha:0.16]
                                                       : [UIColor colorWithWhite:1.0 alpha:0.68]; }
static UIColor *E1ColorRim(BOOL dark)    { return dark ? [UIColor colorWithWhite:1.0 alpha:0.28]
                                                       : [UIColor colorWithWhite:1.0 alpha:0.85]; }
static UIColor *E1ColorShade(BOOL dark)  { return dark ? [UIColor colorWithWhite:0.0 alpha:0.35]
                                                       : [UIColor colorWithWhite:0.0 alpha:0.06]; }
static UIColor *E1ColorSeg(BOOL dark)    { return dark ? [UIColor colorWithWhite:0.46 alpha:0.28]
                                                       : [UIColor colorWithWhite:0.46 alpha:0.12]; }
static UIColor *E1ColorSuccess(void)     { return E1HexColor(0x34C759); }
/// 横屏左栏"系统材质"色 —— SPEC §2.1 side 行。
/// 保留为 static inline:E1 的左栏材质落地属于菜单改造(G1/G2,另一个文件),本文件先固化令牌备用,
/// 用 inline 声明避免未使用告警。
static inline UIColor *E1ColorSide(BOOL dark) { return dark ? [UIColor colorWithRed:18.0 / 255.0 green:18.0 / 255.0 blue:20.0 / 255.0 alpha:0.55]
                                                           : [UIColor colorWithRed:242.0 / 255.0 green:242.0 / 255.0 blue:247.0 / 255.0 alpha:0.60]; }

/// SPEC §2.6 图标块底:白系渐变(深/浅通用)
static UIColor *E1ColorIconGradTop(void)    { return [UIColor colorWithWhite:1.0 alpha:0.22]; }
static UIColor *E1ColorIconGradBottom(void) { return [UIColor colorWithWhite:1.0 alpha:0.06]; }

/// 统一造字(卡标题/副文/药丸),避免每处重复 6 行样板
static UILabel *E1MakeLabel(NSString *text, CGFloat size, UIFontWeight weight, UIColor *color) {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.7;
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    return l;
}

/// 实例 → SF Symbol(SPEC §6-6:稿用 emoji 占位,真机按语义近似选)
static NSString *E1SymbolForInstance(NSString *name) {
    NSString *n = [name lowercaseString];
    if ([n containsString:@"fabric"] || [n containsString:@"forge"] ||
        [n containsString:@"quilt"]  || [n containsString:@"neoforge"]) {
        return @"hammer.fill";
    }
    if ([n containsString:@"bsl"] || [n containsString:@"iris"] ||
        [n containsString:@"shader"] || [n containsString:@"光影"]) {
        return @"drop.fill";
    }
    return @"cube.fill";
}

/// 实例副文:真实数据 —— 扫描该实例 gameDir/mods 下的 jar 数量 + lastVersionId。
/// 取不到就退回「无模组」,不编造数字。
static NSString *E1InstanceSubtitle(NSString *name, NSDictionary *profile) {
    NSString *gameDir = profile[@"gameDir"];
    if (![gameDir isKindOfClass:[NSString class]] || gameDir.length == 0 || [gameDir isEqualToString:@"."]) {
        const char *env = getenv("POJAV_GAME_DIR");
        gameDir = env ? @(env) : nil;
    }
    NSUInteger modCount = 0;
    if (gameDir.length > 0) {
        NSString *modsPath = [gameDir stringByAppendingPathComponent:@"mods"];
        NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:modsPath error:nil];
        for (NSString *f in files) {
            if ([f hasSuffix:@".jar"] || [f hasSuffix:@".jar.disabled"]) modCount++;
        }
    }
    NSString *version = profile[@"lastVersionId"];
    if (modCount > 0) {
        return version.length ? [NSString stringWithFormat:@"%lu 个模组 · %@", (unsigned long)modCount, version]
                              : [NSString stringWithFormat:@"%lu 个模组", (unsigned long)modCount];
    }
    return version.length ? [NSString stringWithFormat:@"无模组 · %@", version] : @"无模组";
}

/// 实例当前渲染器(真实偏好,默认 Metal)—— 用于卡上「Metal」药丸(SPEC §2.1 success 绿)
static NSString *E1CurrentRendererName(void) {
    NSString *renderer = getPrefObject(@"video.renderer");
    if (renderer.length == 0) return @"Metal";
    return [renderer capitalizedString];
}

/// 给实例卡挂上"点哪张实例"的上下文(不新增类,用关联对象传递)
static const void *kE1InstanceNameKey = &kE1InstanceNameKey;

@interface LauncherCardLayoutViewController ()

@property(nonatomic, strong) UIView *sidebarCard;
@property(nonatomic, strong) UIView *contentCard;
@property(nonatomic, strong) UIView *rightPanelCard;

@property(nonatomic, strong) NSLayoutConstraint *sidebarWidthConstraint;
@property(nonatomic, strong) NSLayoutConstraint *rightPanelWidthConstraint;
// 存储外边距约束，traitCollection 变化时动态更新
@property(nonatomic, strong) NSArray<NSLayoutConstraint *> *outerMarginConstraints;
// ★ [GLASS-SAFE] 贴屏边的那 4 个约束单独持有:只有"有灵动岛/刘海的那一侧"需要补 safeArea 补偿。
//   其余(卡片之间的间距、宽度)不受安全区影响,保持原样。
@property(nonatomic, strong) NSLayoutConstraint *edgeLeadingConstraint;    // 侧栏 leading → +insets.left
@property(nonatomic, strong) NSLayoutConstraint *edgeTrailingConstraint;   // 右栏 trailing → -insets.right
@property(nonatomic, strong) NSLayoutConstraint *edgeTopConstraint;        // → +insets.top(竖屏时避岛)
@property(nonatomic, strong) NSLayoutConstraint *edgeBottomConstraint;     // → -max(margin, insets.bottom)
// 关键修复（UI 累积异常）：同 LauncherRootViewController，持有当前内容 VC 的约束
// 并先 deactivate 再激活，避免 tmpRootVC 保留场景下缓存复用子 VC 的约束叠加。
@property(nonatomic, strong) NSArray<NSLayoutConstraint *> *currentContentConstraints;

// ★ [PORTRAIT] 竖屏(紧凑高)时的"三卡竖摞"约束集;与横屏约束互斥激活。
@property(nonatomic, strong) NSArray<NSLayoutConstraint *> *portraitConstraints;
@property(nonatomic, strong) NSArray<NSLayoutConstraint *> *landscapeConstraints;
@property(nonatomic, assign) BOOL usingPortraitLayout;

// ★ [PORTRAIT] 菜单页引用(切横/竖排布时要用)
@property(nonatomic, strong) LauncherMenuViewController *menuViewController;

@property(nonatomic, assign) BOOL isShowingProfileEditor;
@property(nonatomic, strong) ProfileSettingsViewController *profileEditorVC;

// ★ [UI-A][PORTRAIT-FIX] 中栏夹在左/右两卡之间那两条横向相邻约束(横屏专用)。
//   原实现只在 setupCardContainers 里 activate 了它们、却没存进 landscapeConstraints,
//   导致切竖屏时它们仍 active:中栏同时被"贴着菜单卡右边"和"贴 view.leading"两条约束拉扯
//   ⇒ 竖屏三卡错位 / 自动布局打断约束(竖屏 bug 根因)。
@property(nonatomic, strong) NSLayoutConstraint *contentBetweenLeadConstraint;
@property(nonatomic, strong) NSLayoutConstraint *contentBetweenTrailConstraint;

// ===== ★ [E1] 实例主区(顶部大卡 + 双列/三列实例网格)=====
//   结构:contentCard ▸ instancesPanel(标题行 + 滚动网格),网格由 e1RebuildInstancesGrid 生成。
@property(nonatomic, strong) UIView *instancesPanel;            // 「实例」主区(挂在 contentCard 内)
@property(nonatomic, strong) UILabel *instancesTitleLabel;      // 大标题「实例」
@property(nonatomic, strong) UIButton *instancesGearButton;     // 竖屏右上齿轮(40×40)
@property(nonatomic, strong) UIButton *instancesSortButton;     // 横屏右上「排序 ⇅」
@property(nonatomic, strong) UIButton *instancesNewButton;      // 横屏右上「＋ 新建」
@property(nonatomic, strong) UIScrollView *instancesScrollView;
// ★ [E1-fix] 实例面板表头高度约束(CI run#77 报 property not found: 漏声明)
@property(nonatomic, strong) NSLayoutConstraint *instancesHeaderHeightConstraint;
@property(nonatomic, strong) UIStackView *instancesGridView;     // 竖向:每行一个横排行容器
@property(nonatomic, strong) NSMutableArray<UIView *> *e1InstanceCards;          // 布局后刷新高光/虚线用
@property(nonatomic, strong) NSMutableArray<CAShapeLayer *> *e1DashedBorderLayers;
@property(nonatomic, assign) BOOL showingInstancesPanel;        // 主区当前是否在「实例」页
@property(nonatomic, assign) BOOL e1GridBuiltPortrait;           // 网格最近一次是按竖屏(2 列)还是横屏(3 列)建的
@property(nonatomic, assign) NSInteger e1SortMode;               // 0=默认(选中优先) 1=按名称 2=最近游玩

/// ★ [E1] 右栏是否参与布局(E 方案主区以实例网格为主,默认不参与 ⇒ 启动入口下沉到卡;SPEC §5 G8)。
///   右栏 VC 仍作为子 VC 存在并可用 KVC 触发启动,只是不再占位(便于一键恢复)。
@property(nonatomic, assign) BOOL e1ShowsRightPanel;

/// ★ [E1] 构建/重建实例主区
- (void)setupInstancesPanel;
- (void)e1RebuildInstancesGrid;
- (void)e1ShowInstancesPage;
- (void)e1ApplyInstancesPanelAppearance;

// ★ [UI-A][DARK-MODE] 深浅色切换时重刷卡片基底(实现在下方)
- (void)applyAppearanceForCurrentInterfaceStyle;

@end

@implementation LauncherCardLayoutViewController

#pragma mark - Lifecycle

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor clearColor];
    
    // 初始化版本列表（必须在其他视图控制器之前）
    [self initializeVersionLists];
    
    // 创建三个卡片容器视图
    [self setupCardContainers];
    
    // 添加子视图控制器
    [self setupChildViewControllers];

    // ★ [E1] 构建「实例」主区(顶部大卡 + 双列实例卡网格),作为主区默认内容
    [self setupInstancesPanel];
    
    // 应用背景
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];

    // 监听启动器外观变化（自定义字体/卡片颜色），刷新卡片背景
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyCustomAppearance)
                                                 name:@"LauncherAppearanceChanged"
                                               object:nil];
}

- (void)initializeVersionLists {
    // 初始化本地版本列表
    if (!localVersionList) {
        localVersionList = [NSMutableArray new];
    }
    [localVersionList removeAllObjects];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *versionPath = [NSString stringWithFormat:@"%s/versions/", getenv("POJAV_GAME_DIR")];
    NSArray *list = [fileManager contentsOfDirectoryAtPath:versionPath error:nil];
    for (NSString *versionId in list) {
        NSString *localPath = [NSString stringWithFormat:@"%s/versions/%@", getenv("POJAV_GAME_DIR"), versionId];
        BOOL isDirectory;
        if ([fileManager fileExistsAtPath:localPath isDirectory:&isDirectory] && isDirectory) {
            [localVersionList addObject:@{
                @"id": versionId,
                @"type": @"custom"
            }];
        }
    }
    
    // 初始化远程版本列表
    if (!remoteVersionList) {
        remoteVersionList = [NSMutableArray new];
    }
    [remoteVersionList removeAllObjects];
    [remoteVersionList addObjectsFromArray:@[
        @{@"id": @"latest-release", @"type": @"release"},
        @{@"id": @"latest-snapshot", @"type": @"snapshot"}
    ]];
    
    // 异步获取远程版本列表
    [self fetchRemoteVersionList];
}

- (void)fetchRemoteVersionList {
    NSString *downloadSource = getPrefObject(@"general.download_source");
    NSString *versionManifestURL;
    
    if ([downloadSource isEqualToString:@"bmclapi"]) {
        versionManifestURL = @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json";
    } else {
        versionManifestURL = @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
    }
    
    NSURL *url = [NSURL URLWithString:versionManifestURL];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data && !error) {
            NSError *jsonError;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (json && json[@"versions"]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [remoteVersionList addObjectsFromArray:json[@"versions"]];
                    setPrefObject(@"internal.latest_version", json[@"latest"]);
                    NSDebugLog(@"[LauncherCardVC] Loaded %d remote versions", remoteVersionList.count);
                });
            }
        } else {
            NSDebugLog(@"[LauncherCardVC] Failed to fetch version list: %@", error.localizedDescription);
        }
    }];
    [task resume];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[BackgroundManager sharedManager] resumeVideo];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [[BackgroundManager sharedManager] pauseVideo];
}

/// ★ [GLASS-SAFE] 转屏(岛换边)或竖屏进出时,safeAreaInsets 变化 ⇒ 重算屏边补偿。
/// 这是灵动岛/刘海屏唯一可靠的重排时机:viewDidLayoutSubviews 里 insets 可能还没更新。
- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self updateLayoutForCurrentOrientation];
    [self applyEdgeInsets];
}

/// ★ [PORTRAIT] 按当前方向二选一激活约束集。竖屏 = 紧凑高(verticalSizeClass == Regular 且宽 < 高)。
/// 只在真正需要切换时动约束,避免每次转屏都重建(原工程有"约束累积"的历史教训)。
- (void)updateLayoutForCurrentOrientation {
    BOOL portraitNow = (self.view.bounds.size.height > self.view.bounds.size.width);
    // ★ [E1] 网格按当前朝向重排(竖屏 2 列 / 横屏 3 列;卡高与色令牌同步切换)。
    //   独立于下面的 usingPortraitLayout 去重 ⇒ 首次布局(还没切过约束)也会按真实朝向正确建一次。
    if (self.e1GridBuiltPortrait != portraitNow || self.e1InstanceCards.count == 0) {
        self.e1GridBuiltPortrait = portraitNow;
        [self e1RebuildInstancesGrid];
        [self e1ApplyInstancesPanelAppearance];
    }
    if (!self.portraitConstraints || !self.landscapeConstraints) return;
    BOOL portrait = portraitNow;
    if (self.usingPortraitLayout == portrait) return;
    self.usingPortraitLayout = portrait;
    // ★ [UI-A] 自证日志:切到哪套布局 + 当前尺寸与安全区,便于装机核对竖/横屏是否真的切了。
    NSLog(@"[UI-A][ORIENT] layout=%@ size=%.0fx%.0f safe(top=%.0f bottom=%.0f left=%.0f right=%.0f)",
          portrait ? @"PORTRAIT" : @"LANDSCAPE",
          self.view.bounds.size.width, self.view.bounds.size.height,
          self.view.safeAreaInsets.top, self.view.safeAreaInsets.bottom,
          self.view.safeAreaInsets.left, self.view.safeAreaInsets.right);
    if (portrait) {
        [NSLayoutConstraint deactivateConstraints:self.landscapeConstraints];
        [NSLayoutConstraint activateConstraints:self.portraitConstraints];
    } else {
        [NSLayoutConstraint deactivateConstraints:self.portraitConstraints];
        [NSLayoutConstraint activateConstraints:self.landscapeConstraints];
    }
    // ★ [TOP-BAR] 右栏(用户头像)两向常驻 ⇒ 宽度交给两套约束集合管理,不再强制关闭。
    // 菜单卡在竖屏走横向排布(图标横排一行),横屏恢复竖排
    if ([self.menuViewController respondsToSelector:@selector(setCompactHorizontalLayout:)]) {
        // ★ [TOP-BAR] 顶栏两向都是横条 ⇒ 菜单恒为紧凑横排(同时隐藏品牌头/版本脚,避免撑高)
        [self.menuViewController performSelector:@selector(setCompactHorizontalLayout:) withObject:@(YES)];
    }
    [self applyEdgeInsets];
    [self.view setNeedsLayout];
}

/// 只做"屏边补偿"这一件事,便于从 traitCollectionDidChange / viewSafeAreaInsetsDidChange 两处调用。
- (void)applyEdgeInsets {
    CGFloat outerMargin = LauncherCardLayoutOuterMargin(self.traitCollection);
    UIEdgeInsets safe = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) {
        safe = self.view.safeAreaInsets;
    }
    CGFloat mTop, mBottom;
    if (self.usingPortraitLayout) {
        // ★ [UI-A][PORTRAIT-SAFE] 竖屏:岛在顶部 ⇒ 顶吃 safe.top(内容区整体下移,不进岛);
        //   底部菜单卡吃 safe.bottom(避开 home indicator)。竖屏 safe.left/right 恒为 0。
        mTop    = outerMargin + safe.top;
        mBottom = outerMargin + safe.bottom;
    } else {
        // ★ [UI-A][LANDSCAPE-FIX] 横屏:底边只让开 home indicator 本体,不再额外叠 outerMargin*0.5,
        //   否则底边(≈29pt)比顶边(≈8pt)宽 3.6 倍,三张卡整体偏上、下空隙过大。
        mTop    = outerMargin + safe.top;
        mBottom = MAX(outerMargin, safe.bottom);
    }
    self.edgeLeadingConstraint.constant  =  outerMargin + safe.left;
    self.edgeTrailingConstraint.constant = -(outerMargin + safe.right);
    self.edgeTopConstraint.constant      =  mTop;
    self.edgeBottomConstraint.constant   = -mBottom;
    for (NSLayoutConstraint *c in self.outerMarginConstraints) {
        if ([c.identifier isEqualToString:@"edge-top"])         { c.constant =  mTop; }
        else if ([c.identifier isEqualToString:@"edge-bottom"]) { c.constant = -mBottom; }
    }
    // ★ [UI-A][PORTRAIT-SAFE] 竖屏专用两条:顶部内容卡吃灵动岛安全区、底部菜单卡吃 home indicator。
    //   横屏用不到这两条(portraitConstraints 未激活),统一复位,避免常量残留。
    for (NSLayoutConstraint *c in self.portraitConstraints) {
        if ([c.identifier isEqualToString:@"portrait-top"]) {
            c.constant = self.usingPortraitLayout ? (kCardOuterMarginPhone + safe.top) : kCardOuterMarginPhone;
        } else if ([c.identifier isEqualToString:@"portrait-bottom"]) {
            c.constant = self.usingPortraitLayout ? -(kCardOuterMarginPhone + safe.bottom) : -kCardOuterMarginPhone;
        }
    }
    [self.view setNeedsLayout];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // ★ [PORTRAIT] 首次进入 / 转屏后对齐布局(只切一次,内部有 usingPortraitLayout 去重)
    [self updateLayoutForCurrentOrientation];
    // ★ [E1] 布局后刷新实例卡"装饰层":虚线边框路径(按卡片实际尺寸)与玻璃高光渐变
    [self e1RefreshInstanceCardChrome];
    // card 布局四边外边距一致性由约束保证（用 view.edgeAnchor + kCardOuterMargin，
    // 不依赖 safeAreaLayoutGuide），此处无需额外补偿。
    // 之前用 additionalSafeAreaInsets 补偿 safeArea 不对称，但补偿后外边距 =
    // max(safeArea) + kCardOuterMargin 反而更大（"下边和左右两边空隙过大"），
    // 故移除该补偿方案，改用 view.edgeAnchor 直接约束。
    //
    // 关键修复（阶段4：Card 布局进入设置崩溃，无日志）：
    // 与 LauncherRootViewController 对齐：清理 additionalSafeAreaInsets 累积。
    // 之前此方法体为空，导致 LauncherPreferencesViewController（含 UISearchController）在
    // nav 栈中时 additionalSafeAreaInsets 可能累积异常，UISearchController.searchBar
    // （作为 tableHeaderView）frame 计算异常 → EXC_BAD_ACCESS（不被 NSUncaughtExceptionHandler
    // 捕获，故无日志）。VS 布局不崩溃是因为 Root 的 viewDidLayoutSubviews 持续清理 inset。
    UIViewController *contentVC = _contentViewController;
    if (!contentVC) return;
    if ([contentVC isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)contentVC;
        for (UIViewController *vc in nav.viewControllers) {
            UIEdgeInsets insets = vc.additionalSafeAreaInsets;
            if (insets.top != 0 || insets.left != 0 || insets.right != 0 || insets.bottom != 0) {
                vc.additionalSafeAreaInsets = UIEdgeInsetsZero;
            }
        }
    } else {
        UIEdgeInsets insets = contentVC.additionalSafeAreaInsets;
        if (insets.top != 0 || insets.left != 0 || insets.right != 0 || insets.bottom != 0) {
            contentVC.additionalSafeAreaInsets = UIEdgeInsetsZero;
        }
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    // iPhone 与 iPad 切换、或分屏调整大小时，更新侧栏与右侧面板宽度
    CGFloat sidebarWidth = LauncherCardLayoutSidebarWidth(self.traitCollection);
    CGFloat rightPanelWidth = LauncherCardLayoutRightPanelWidth(self.traitCollection);
    if (self.sidebarWidthConstraint.constant != sidebarWidth) {
        self.sidebarWidthConstraint.constant = sidebarWidth;
    }
    if (self.rightPanelWidthConstraint.constant != rightPanelWidth) {
        self.rightPanelWidthConstraint.constant = rightPanelWidth;
    }
    // 更新外边距约束（iPhone/iPad 切换时 outerMargin 不同）
    CGFloat outerMargin = LauncherCardLayoutOuterMargin(self.traitCollection);
    for (NSLayoutConstraint *c in self.outerMarginConstraints) {
        if ([c.identifier isEqualToString:@"edge-top"] || [c.identifier isEqualToString:@"edge-bottom"]) {
            continue;   // ★ [GLASS-SAFE]/[UI-A] 带 edge-top/bottom 标识的几条由 applyEdgeInsets 统一按安全区设置
        }
        // 其余(卡片之间 / 尺寸)不受屏边安全区影响,按符号取 ±outerMargin
        if (c.constant >= 0) {
            c.constant = outerMargin;
        } else {
            c.constant = -outerMargin;
        }
    }
    // ★ [UI-A][GLASS-SAFE] 屏边补偿统一走 applyEdgeInsets,避免两处公式漂移:
    //   岛在左/右时该侧让开 safe.left/right;竖屏时顶部内容卡让开岛、底部菜单卡让开 home indicator。
    [self applyEdgeInsets];
    // 关键修复（阶段4：Card 布局进入设置崩溃，无日志）：
    // 与 LauncherRootViewController 对齐：仅遍历直接子 VC，避免递归栈溢出风险。
    // 之前递归遍历所有后代 VC（adjustChildLayoutForTraitCollection:），若 VC 树存在
    // 循环引用会栈溢出（SIGSEGV，不被 NSUncaughtExceptionHandler 捕获，故无日志）。
    // respondsToSelector:@selector(viewWillAppear:) 检查永真（所有 UIViewController 都响应），
    // 属冗余代码，一并删除。
    // ★ [UI-A][DARK-MODE] 深浅色切换:重刷卡片基底(毛玻璃/自定义叠色);布局不变、颜色要对。
    if (previousTraitCollection &&
        previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
        [self applyAppearanceForCurrentInterfaceStyle];
    }
    for (UIViewController *child in self.childViewControllers) {
        [child.view setNeedsLayout];
    }
}

#pragma mark - Setup

- (UIView *)createCardContainer {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = kCardCornerRadius;
    card.layer.masksToBounds = YES;
    [[BackgroundManager sharedManager] applyEffectToView:card];
    [self applyCustomCardColorToCard:card];
    return card;
}

/// 读取 general.card_color 偏好，若已设置则在毛玻璃上叠加半透明色。
///
/// 统一参照 ZL2 的 Haze + tint 方案和 RootVC 的 applySemiTransparentColor: 实现：
/// 保留 BackgroundManager 的毛玻璃 UIVisualEffectView（让背景图能透出），
/// 在容器背景色上叠加用户自定义的半透明颜色。
///
/// 之前 CardVC 的做法是移除毛玻璃用纯色覆盖，导致：
/// 1. 与 RootVC 行为不一致（RootVC 保留毛玻璃叠加半透明色）
/// 2. 自定义背景图被完全遮挡，无法透出
/// 3. 视觉效果与 FCL/ZL2 不符（FCL/ZL2 都保留模糊效果 + 颜色叠加）
///
/// 现统一为：保留毛玻璃 + 叠加半透明色（与 RootVC 完全一致）
- (void)applyCustomCardColorToCard:(UIView *)card {
    NSString *hex = getPrefObject(@"general.card_color");
    UIColor *color = [self colorFromHexString:hex];
    if (!color) return;
    // 保留 BackgroundManager 插入的毛玻璃 UIVisualEffectView，仅叠加半透明色
    // 这样既显示用户自定义的卡片颜色，又能透出背景图（与 RootVC 行为一致）
    // 使用 0.7 alpha 让背景图能适度透出（参照 ZL2 的 influencedByBackgroundColor 思路）
    // ★ [UI-A][DARK-MODE] 深色外观下同样的自定义色若仍叠 0.7 会偏亮发灰,
    //   降到 0.5 让深色毛玻璃基底多透出一些,保证深浅两套观感一致。
    CGFloat alpha = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) ? 0.5 : 0.7;
    card.backgroundColor = [color colorWithAlphaComponent:alpha];
}

- (nullable UIColor *)colorFromHexString:(id)hex {
    if (![hex isKindOfClass:[NSString class]] || [(NSString *)hex length] == 0) return nil;
    NSString *clean = [(NSString *)hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:clean];
    if (![scanner scanHexInt:&rgb]) return nil;
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

/// 外观变化时重新应用卡片颜色（保留圆角，重建背景）
- (void)applyCustomAppearance {
    [self applyCustomCardColorToCard:self.sidebarCard];
    [self applyCustomCardColorToCard:self.contentCard];
    [self applyCustomCardColorToCard:self.rightPanelCard];
    // ★ [E1] 自定义字体颜色/卡片色变化时,实例主区也重新取令牌(标题/卡内文字跟随外观)
    [self e1ApplyInstancesPanelAppearance];
    [self e1RebuildInstancesGrid];
}

/// ★ [UI-A][DARK-MODE] 深浅色切换时重刷三张卡的基底:
/// 重新应用毛玻璃/半透明效果 + 按新外观重刷自定义卡片叠色(applyCustomCardColorToCard 内按 style 取 alpha)。
/// 布局本身不随深浅色变化,变化的只有卡片基底色与毛玻璃亮度。
- (void)applyAppearanceForCurrentInterfaceStyle {
    for (UIView *card in @[self.sidebarCard, self.contentCard, self.rightPanelCard]) {
        if (!card) continue;
        [[BackgroundManager sharedManager] applyEffectToView:card];
        [self applyCustomCardColorToCard:card];
    }
    // ★ [E1] 深浅色切换:实例主区按新外观换整张令牌表(卡底 .10/.55、描边 .28/.85、文字、强调蓝)
    [self e1ApplyInstancesPanelAppearance];
    [self e1RebuildInstancesGrid];
    [self.view setNeedsLayout];
}

- (void)setupCardContainers {
    // 左侧菜单卡片
    self.sidebarCard = [self createCardContainer];
    [self.view addSubview:self.sidebarCard];

    // 中间内容卡片
    self.contentCard = [self createCardContainer];
    [self.view addSubview:self.contentCard];

    // 右侧信息/启动卡片
    self.rightPanelCard = [self createCardContainer];
    [self.view addSubview:self.rightPanelCard];

    // 用自适应宽度创建可变宽度约束，便于 traitCollection 变化时更新
    self.sidebarWidthConstraint = [self.sidebarCard.widthAnchor constraintEqualToConstant:LauncherCardLayoutSidebarWidth(self.traitCollection)];
    self.rightPanelWidthConstraint = [self.rightPanelCard.widthAnchor constraintEqualToConstant:LauncherCardLayoutRightPanelWidth(self.traitCollection)];

    // 卡片外边距：iPhone 窄屏用较小值减少留白
    CGFloat outerMargin = LauncherCardLayoutOuterMargin(self.traitCollection);

    // 设置约束
    // 四个方向均用 view.edgeAnchor（而非 safeAreaLayoutGuide），使外边距完全由 outerMargin 控制，
    // 上下左右边距一致（均 = outerMargin），不受刘海/home indicator 导致的 safeArea 不对称影响。
    //
    // 修复"下面过宽"问题：之前上下用 safeAreaLayoutGuide + outerMargin，
    // 导致底部边距 = homeIndicatorInset + outerMargin（约 21+8=29pt），
    // 而顶部边距 = 0 + outerMargin = 8pt，底部比顶部宽 3.6 倍。
    // 改为 view.topAnchor/view.bottomAnchor 后，上下边距均 = outerMargin，保持一致。
    // 卡片背景会延伸到 home indicator 下方，视觉上无影响（卡片有不透明/毛玻璃背景）。
    // ★ [E1] E 方案主区版式:
    //   横屏 = 左侧栏(菜单)+ 主区「实例」网格(稿中无右栏);
    //   竖屏 = 主区「实例」网格在上 + 底部菜单条(稿中的底部标签栏位)。
    //   ★ [TOP-BAR] 按用户实测反馈改版:
    //     ① 工具栏搬到【顶部横条】;② 右端停在右栏之前 ⇒ 不挡右上角的用户头像;
    //     ③ 主页(内容卡)占掉原工具栏那条竖带(leading 直接贴屏边);④ 右栏(头像)常驻右上。
    self.e1ShowsRightPanel = YES;
    self.rightPanelCard.hidden = NO;

    // ★ [TOP-BAR] 顶栏(原左栏改横条):贴顶,右端停在右栏之前 ⇒ 绝不压住右上角头像
    NSLayoutConstraint *sidebarLeading = [self.sidebarCard.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:outerMargin];
    NSLayoutConstraint *sidebarTop = [self.sidebarCard.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:outerMargin];
    NSLayoutConstraint *sidebarTrail = [self.sidebarCard.trailingAnchor constraintEqualToAnchor:self.rightPanelCard.leadingAnchor constant:-kCardSpacing];
    NSLayoutConstraint *sidebarHeight = [self.sidebarCard.heightAnchor constraintEqualToConstant:56.0];
    // 右栏(用户头像)常驻右上角
    NSLayoutConstraint *rightTop = [self.rightPanelCard.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:outerMargin];
    NSLayoutConstraint *rightTrail = [self.rightPanelCard.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-outerMargin];
    NSLayoutConstraint *rightHeight = [self.rightPanelCard.heightAnchor constraintEqualToConstant:56.0];
    // ★ 主页占掉原工具栏竖带:content.leading 贴屏边;top 从顶栏下沿开始
    NSLayoutConstraint *contentLead = [self.contentCard.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:outerMargin];
    NSLayoutConstraint *contentTop = [self.contentCard.topAnchor constraintEqualToAnchor:self.sidebarCard.bottomAnchor constant:kCardSpacing];
    NSLayoutConstraint *contentBottom = [self.contentCard.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-outerMargin];
    NSLayoutConstraint *contentTrail = [self.contentCard.trailingAnchor constraintEqualToAnchor:self.rightPanelCard.leadingAnchor constant:-kCardSpacing];

    self.outerMarginConstraints = @[sidebarLeading, sidebarTop, rightTop, rightTrail,
                                    contentLead, contentTrail, contentTop, contentBottom];

    // ★ [GLASS-SAFE] 记下"贴屏边"的 4 个,供安全区补偿使用
    self.edgeLeadingConstraint  = sidebarLeading;
    self.edgeTrailingConstraint = contentTrail;
    self.edgeTopConstraint      = sidebarTop;
    // ★ [TOP-BAR] 顶栏后,最靠底的是内容卡(侧栏已是顶横条、无 bottom)→ 底边补偿改挂 contentBottom
    self.edgeBottomConstraint   = contentBottom;
    // contentCard 的上下与侧栏一致,同步补偿(否则中栏会被岛侧顶出去而错位)
    contentTop.identifier    = @"edge-top";
    contentBottom.identifier = @"edge-bottom";
    sidebarTop.identifier    = @"edge-top";

    // ★ [UI-A][PORTRAIT-FIX] 中栏与左栏的横向相邻约束:必须单独持有,否则切竖屏时无法 deactivate。
    // ★ [TOP-BAR] 顶栏改横条后,主区不再挂在侧栏右边 —— 这两条改为"主区左边界"与"右栏左边界",
    //   仍单独持有以便切竖屏时能 deactivate(约束泄漏是上一版竖屏错位的根因)。
    self.contentBetweenLeadConstraint  = contentLead;
    self.contentBetweenTrailConstraint = contentTrail;

    // 横屏约束集(E 横屏:顶栏 + 主区实例网格 + 右上头像)
    self.landscapeConstraints = @[sidebarLeading, sidebarTop, sidebarTrail, sidebarHeight,
                                  rightTop, rightTrail, rightHeight, self.rightPanelWidthConstraint,
                                  contentLead, contentTrail, contentTop, contentBottom];

    [NSLayoutConstraint activateConstraints:self.landscapeConstraints];

    // ★ [E1] 竖屏约束集(E 竖屏:主区实例网格在上 + 底部菜单条)
    // ★ [TOP-BAR] 竖屏也是顶栏:菜单横条在左上、头像小卡在右上,内容填满下方。
    NSLayoutConstraint *pSideTop      = [self.sidebarCard.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:kE1MarginPortrait];
    NSLayoutConstraint *pSideLead     = [self.sidebarCard.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:kE1MarginPortrait];
    NSLayoutConstraint *pSideTrail    = [self.sidebarCard.trailingAnchor constraintEqualToAnchor:self.rightPanelCard.leadingAnchor constant:-kCardSpacing];
    NSLayoutConstraint *pSideHeight   = [self.sidebarCard.heightAnchor constraintEqualToConstant:56.0];
    NSLayoutConstraint *pRightTop     = [self.rightPanelCard.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:kE1MarginPortrait];
    NSLayoutConstraint *pRightTrail   = [self.rightPanelCard.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-kE1MarginPortrait];
    NSLayoutConstraint *pRightHeight  = [self.rightPanelCard.heightAnchor constraintEqualToConstant:56.0];
    NSLayoutConstraint *pRightWidth   = [self.rightPanelCard.widthAnchor constraintEqualToConstant:56.0];
    // ★ [PORTRAIT-SAFE] 顶栏在顶部 ⇒ 这几条要在 applyEdgeInsets 里加 insets.top(避开灵动岛)
    NSLayoutConstraint *pContentTop   = [self.contentCard.topAnchor constraintEqualToAnchor:self.sidebarCard.bottomAnchor constant:kCardSpacing];
    pSideTop.identifier    = @"portrait-top";
    pRightTop.identifier   = @"portrait-top";
    pContentTop.identifier = @"portrait-top";
    NSLayoutConstraint *pContentLead  = [self.contentCard.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:kE1MarginPortrait];
    NSLayoutConstraint *pContentTrail = [self.contentCard.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-kE1MarginPortrait];
    // ★ [IPAD15-CRASH] 删掉一行死约束:它用 NSLayoutAttributeNotAnAttribute 当【第一个 item 的属性】
    //   且 toItem:nil,建完立刻 (void) 丢弃、从未参与布局。iPadOS 15.4.1 上 CoreAutoLayout 会抛
    //   "NSLayoutConstraint ... : Unknown layout attribute" ⇒ LauncherCardLayoutViewController
    //   的 viewDidLoad 直接崩(iPad 走这个 VC,iPhone 走 LauncherRootViewController ⇒ 只在 iPad 复现)。
    for (NSLayoutConstraint *c in @[pContentTop, pContentLead, pContentTrail,
                                    pSideLead, pSideTrail, pSideTop, pSideHeight,
                                    pRightTop, pRightTrail, pRightHeight, pRightWidth]) {
        c.identifier = @"portrait-set";
    }
    self.portraitConstraints = @[pContentTop, pContentLead, pContentTrail,
                                 pSideLead, pSideTrail, pSideTop, pSideHeight,
                                 pRightTop, pRightTrail, pRightHeight, pRightWidth];
}

- (void)setupChildViewControllers {
    // 左侧边栏 - 功能菜单
    LauncherMenuViewController *sidebarVC = [[LauncherMenuViewController alloc] init];
    self.menuViewController = sidebarVC;   // ★ [PORTRAIT] 记下引用
    [self addChildViewController:sidebarVC];
    sidebarVC.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.sidebarCard addSubview:sidebarVC.view];
    [NSLayoutConstraint activateConstraints:@[
        [sidebarVC.view.leadingAnchor constraintEqualToAnchor:self.sidebarCard.leadingAnchor],
        [sidebarVC.view.trailingAnchor constraintEqualToAnchor:self.sidebarCard.trailingAnchor],
        [sidebarVC.view.topAnchor constraintEqualToAnchor:self.sidebarCard.topAnchor],
        [sidebarVC.view.bottomAnchor constraintEqualToAnchor:self.sidebarCard.bottomAnchor]
    ]];
    [sidebarVC didMoveToParentViewController:self];
    _sidebarViewController = sidebarVC;
    
    // ★ [E1] 中间内容 - 默认显示「实例」主区(E 方案主界面 = 实例网格,见 setupInstancesPanel)。
    //   原来这里默认放新闻页;按 E 方案 SPEC §3.1/§3.2「主区 = 实例网格」,主区改由实例网格承载,
    //   实例卡各自带启动入口(启动不再依赖右栏)。新闻页保留可达路径(showNewsPage / ShowNewsPage 通知)。
    
    // 右侧面板 - 账户和启动
    LauncherRightPanelViewController *rightPanelVC = [[LauncherRightPanelViewController alloc] init];
    [self addChildViewController:rightPanelVC];
    rightPanelVC.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.rightPanelCard addSubview:rightPanelVC.view];
    [NSLayoutConstraint activateConstraints:@[
        [rightPanelVC.view.leadingAnchor constraintEqualToAnchor:self.rightPanelCard.leadingAnchor],
        [rightPanelVC.view.trailingAnchor constraintEqualToAnchor:self.rightPanelCard.trailingAnchor],
        [rightPanelVC.view.topAnchor constraintEqualToAnchor:self.rightPanelCard.topAnchor],
        [rightPanelVC.view.bottomAnchor constraintEqualToAnchor:self.rightPanelCard.bottomAnchor]
    ]];
    [rightPanelVC didMoveToParentViewController:self];
    _rightPanelViewController = rightPanelVC;
    
    // 注册通知监听
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showHomePage)
                                                 name:@"ShowHomePage"
                                               object:nil];
    // ★ [E1] 新闻页:主区改为实例网格后,新闻页不再默认显示;保留通知入口(当前无 poster,
    //   待 G1/G2 菜单改造时把「主页/公告」挂到该通知上即可恢复可达)。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showNewsPage)
                                                 name:@"ShowNewsPage"
                                               object:nil];
    // ★ [E1] 实例(profile)变化 / 版本列表重载时,重建实例卡网格(选中项、副文、模组数都要跟着变)
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(e1ProfileChanged)
                                                 name:@"SelectedProfileChanged"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showDownloadPage)
                                                 name:@"ShowDownloadPage"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showVersionManager)
                                                 name:@"ShowVersionManager"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showProfileEditor:)
                                                 name:@"ShowProfileEditor"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showSettings)
                                                 name:@"ShowSettings"
                                               object:nil];
    // ZeroTier/Terracotta 联机暂时移除（排查启动崩溃）
    // [[NSNotificationCenter defaultCenter] addObserver:self
    //                                          selector:@selector(showMultiplayer)
    //                                              name:@"ShowMultiplayer"
    //                                            object:nil];
    // [[NSNotificationCenter defaultCenter] addObserver:self
    //                                          selector:@selector(showZeroTier)
    //                                              name:@"ShowZeroTier"
    //                                            object:nil];
    // 账户管理：右侧面板点击头像会发 ShowAccountManager 通知。
    // 原实现遗漏此监听，导致卡片布局下点头像无反应、无法登录账号。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showAccountManager)
                                                 name:@"ShowAccountManager"
                                               object:nil];
    // AI 助手：卡片布局下点侧边栏 AI Agent 按钮发 ShowAIPage 通知。
    // 关键修复（点 AI 中间栏不切换）：卡片布局此前未监听 ShowAIPage，
    // 导致菜单发出通知后无人响应、中间栏不变。与 LauncherRootViewController 对齐。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showAIPage)
                                                 name:@"ShowAIPage"
                                               object:nil];
    // 首页快捷瓷砖触发：切到对应内容区子页面（不再 FormSheet 弹窗）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showModsManager)
                                                 name:@"ShowModsManager"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showShadersManager)
                                                 name:@"ShowShadersManager"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showModpackImport)
                                                 name:@"ShowModpackImport"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showGameDirectory)
                                                 name:@"ShowGameDirectory"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(backgroundChanged)
                                                 name:@"BackgroundChanged"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(uiEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
    // 监听版本切换，重新加载编辑器
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadProfileEditorIfNeeded)
                                                 name:@"SelectedProfileChanged"
                                               object:nil];
    // 监听游戏目录切换，重新加载版本列表
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadVersionLists)
                                                 name:@"ReloadProfileList"
                                               object:nil];
    // 监听查找版本请求
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(findVersionInRemoteList:)
                                                 name:@"FindVersionInRemoteList"
                                               object:nil];
}

- (void)findVersionInRemoteList:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    NSString *versionId = userInfo[@"versionId"];
    void (^callback)(NSDictionary *) = userInfo[@"callback"];
    
    if (!versionId || !callback) {
        return;
    }
    
    // 在远程版本列表中查找
    NSDictionary *versionObject = nil;
    for (NSDictionary *version in remoteVersionList) {
        if ([version[@"id"] isEqualToString:versionId]) {
            versionObject = version;
            break;
        }
    }
    
    // 如果在远程列表中找不到，检查是否是本地版本
    if (!versionObject) {
        for (NSDictionary *version in localVersionList) {
            if ([version[@"id"] isEqualToString:versionId]) {
                versionObject = version;
                break;
            }
        }
    }
    
    callback(versionObject);
}

- (void)reloadVersionLists {
    // 重新加载版本列表
    [self initializeVersionLists];
    // 通知右侧面板刷新版本显示
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:nil];
    // ★ [E1] 游戏目录/版本列表变化 ⇒ 实例集合也可能变,重建实例卡网格
    if (self.showingInstancesPanel) {
        [self e1RebuildInstancesGrid];
    }
}

- (void)showHomePage {
    // ★ [E1] 主页 = 「实例」主区(E 方案:主界面即实例网格;底部/侧栏「实例」为默认选中项)。
    //   原来是新闻页 —— 新闻页改由 ShowNewsPage 通知承载(见 showNewsPage)。
    [self e1ShowInstancesPage];
}

/// ★ [E1] 新闻页(原主页)。当前菜单/入口不再直接触发,保留方法 + ShowNewsPage 通知,
///   便于后续把「公告/主页」入口挂回来时零改动可用。
- (void)showNewsPage {
    LauncherNewsViewController *newsVC = [[LauncherNewsViewController alloc] init];
    [self setContentViewController:newsVC animated:YES];
}

/// ★ [E1] profile(实例)选中项或列表变化 ⇒ 重建实例网格(选中卡置顶为大卡、副文/模组数刷新)
- (void)e1ProfileChanged {
    if (self.showingInstancesPanel) {
        [self e1RebuildInstancesGrid];
    }
}

- (void)showDownloadPage {
    // 在中间内容区显示下载页面，包在 NavigationController 中以便子流程（版本选择/安装器）push 显示
    DownloadViewController *downloadVC = [[DownloadViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:downloadVC];
    nav.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:nav animated:YES];
}

- (void)showVersionManager {
    // 在中间内容区显示版本管理页面，包在 NavigationController 中以便子流程（模组/光影/游戏目录管理）push
    VersionManagerViewController *vc = [[VersionManagerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:nav animated:YES];
}

- (void)showProfileEditor:(NSNotification *)notification {
    // 在中间内容区显示版本编辑器页面（使用 ProfileSettingsViewController）
    NSString *profileName = notification.object;

    ProfileSettingsViewController *vc = [[ProfileSettingsViewController alloc] init];
    vc.profileName = profileName;

    // 包装在导航控制器中
    UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:vc];
    navVC.navigationBar.prefersLargeTitles = NO;

    self.profileEditorVC = vc;
    self.isShowingProfileEditor = YES;
    [self setContentViewController:navVC animated:YES];
}

- (void)reloadProfileEditorIfNeeded {
    // 如果当前正在显示编辑器页面，重新加载
    if (self.isShowingProfileEditor) {
        NSString *currentProfile = PLProfiles.current.selectedProfileName;
        if (currentProfile) {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowProfileEditor" object:currentProfile];
        }
    }
}

- (void)showSettings {
    // 在中间内容区显示设置页面
    LauncherPreferencesViewController *vc = [[LauncherPreferencesViewController alloc] init];
    // 包装在导航控制器中，使其子页面能够正常导航
    UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:vc];
    navVC.navigationBar.prefersLargeTitles = YES;
    [self setContentViewController:navVC animated:YES];
}

- (void)showAIPage {
    // 在中间内容区显示 AI 助手页面（与 LauncherRootViewController showAIPage 一致）。
    // 关键修复（点 AI 中间栏不切换）：卡片布局此前缺失此方法，
    // 现在 ShowAIPage 通知到达后能正常切到 AI 页面。
    // 从 AiSessionStore 取最近会话，没有则让 AIViewController 新建一个。
    AiSession *session = [[AiSessionStore sharedStore] lastActiveSession];
    AIViewController *vc = [[AIViewController alloc] initWithSession:session];
    UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:vc];
    navVC.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:navVC animated:YES];
}

// ZeroTier/Terracotta 联机暂时移除（排查启动崩溃）
// - (void)showMultiplayer { ... TerracottaViewController ... }
// - (void)showZeroTier { ... MultiplayerViewController ... TerracottaManager ... }
- (void)showMultiplayer {
    [self showMultiplayerDisabledAlert];
}
- (void)showZeroTier {
    [self showMultiplayerDisabledAlert];
}
- (void)showMultiplayerDisabledAlert {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"i18n_str_320", nil)
                          message:localize(@"i18n_str_321", nil)
                   preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_322", nil) style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showAccountManager {
    // 卡片布局下账户管理在中间内容区显示（与 VS 布局 LauncherRootViewController 行为一致）。
    // 右侧面板点击头像发 ShowAccountManager 通知触发此方法。
    // 使用 insetGrouped 样式让账户列表呈现圆角分组卡片（原默认 plain 为直角行）。
    AccountListViewController *vc = [[AccountListViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    vc.whenItemSelected = ^void() {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"UpdateAccountInfo" object:nil];
    };
    vc.whenDelete = ^void(NSString *name) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"UpdateAccountInfo" object:nil];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.prefersLargeTitles = NO;
    // ★ [ACCOUNTBACK] 账户链路“进得去出不来”修复(与 LauncherRootViewController 同根因,见 AccountListViewController.m 注释):
    //   本页是**新 nav 的根** ⇒ 系统不会给返回键;这里显示导航栏 + 语义色 tintColor,
    //   返回键由 AccountListViewController 在 viewWillAppear 注入(只发 ShowHomePage 通知回主页)。
    //   只动外观,账户业务一行不改。
    nav.navigationBarHidden = NO;
    nav.navigationBar.tintColor = [UIColor labelColor];
    [self setContentViewController:nav animated:YES];
}

#pragma mark - 首页快捷入口 (替换原 FormSheet 弹窗)

- (void)showModsManager {
    // 切到版本管理页并直接 push 模组管理
    // 修复"前一界面未消失"竞态：先构建完整 nav 栈再 setContentViewController，
    // 这样 setContentViewController 内的 for 循环能一次性透明化栈中所有 VC，
    // 避免 animated:YES 的 crossDissolve 进行中再 animated:NO push 导致新 VC 未透明化。
    VersionManagerViewController *vm = [[VersionManagerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vm];
    nav.navigationBar.prefersLargeTitles = NO;
    ModsManagerViewController *m = [[ModsManagerViewController alloc] init];
    [nav pushViewController:m animated:NO];
    [self setContentViewController:nav animated:YES];
}

- (void)showShadersManager {
    VersionManagerViewController *vm = [[VersionManagerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vm];
    nav.navigationBar.prefersLargeTitles = NO;
    ShadersManagerViewController *s = [[ShadersManagerViewController alloc] init];
    s.initialMode = ShadersManagerModeLocal;
    [nav pushViewController:s animated:NO];
    [self setContentViewController:nav animated:YES];
}

- (void)showGameDirectory {
    VersionManagerViewController *vm = [[VersionManagerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vm];
    nav.navigationBar.prefersLargeTitles = NO;
    LauncherPrefGameDirViewController *g = [[LauncherPrefGameDirViewController alloc] init];
    [nav pushViewController:g animated:NO];
    [self setContentViewController:nav animated:YES];
}

- (void)showModpackImport {
    // 切到下载页并直接 push 整合包导入界面
    DownloadViewController *d = [[DownloadViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:d];
    nav.navigationBar.prefersLargeTitles = NO;
    ModpackImportViewController *m = [[ModpackImportViewController alloc] init];
    [nav pushViewController:m animated:NO];
    [self setContentViewController:nav animated:YES];
}

- (void)backgroundChanged {
    // 重新应用背景
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];
}

- (void)uiEffectChanged:(NSNotification *)notification {
    // 重新应用毛玻璃/半透明效果到卡片容器视图
    [[BackgroundManager sharedManager] applyEffectToView:self.sidebarCard];
    [[BackgroundManager sharedManager] applyEffectToView:self.contentCard];
    [[BackgroundManager sharedManager] applyEffectToView:self.rightPanelCard];
    // ★ [E1] 玻璃强度/透明度/毛玻璃开关变化 ⇒ 实例卡基底层也要重贴(卡片是逐张创建时贴的玻璃)
    [self e1RebuildInstancesGrid];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Content Switching

- (void)setContentViewController:(UIViewController *)viewController animated:(BOOL)animated {
    // ★ 子面板原生基底样式:统一页面底色(systemBackgroundColor)与表格基底
    //   (清透 + separatorColor),幂等;透明定制面板自动跳过(BackgroundManager 的全局背景不受影响)。
    [viewController ame_applySubpanelBaseStyle];

    if (!viewController) return;

    // ★ [TAB-OVERLAP] 同一实例直接跳过(避免重复加约束 / hairline 累积)。
    //   但必须保证它此刻真的挂在容器上并且完全可见 —— 上一次切换的淡入动画可能还没走完
    //   (alpha < 1),直接 return 会把"半透明 / 没挂上"的状态留在屏幕上。
    if (viewController == _contentViewController) {
        if (viewController.view.superview != self.contentCard) {
            viewController.view.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentCard addSubview:viewController.view];
            if (self.currentContentConstraints.count > 0) {
                [NSLayoutConstraint activateConstraints:self.currentContentConstraints];
            }
        }
        viewController.view.alpha = 1.0;
        return;
    }

    // ★ [E1] 显示任何子页面 ⇒ 收起「实例」主区(主区与子页面共用 contentCard,互斥显示)
    if (self.instancesPanel && !self.instancesPanel.hidden) {
        self.instancesPanel.hidden = YES;
        self.showingInstancesPanel = NO;
    }

    // 检查是否切换到非编辑器页面
    if (![viewController isKindOfClass:[UINavigationController class]] ||
        ![((UINavigationController *)viewController).topViewController isKindOfClass:[ProfileSettingsViewController class]]) {
        self.isShowingProfileEditor = NO;
        self.profileEditorVC = nil;
    }

    // ★ [TAB-OVERLAP] ① 先把"上一次切换"彻底收尾,再进入本次切换。
    //   原实现把 removeFromSuperview / removeFromParentViewController 放进 transitionWithView:
    //   的 completion 里 —— 连点时第二次切换会先于第一次的 completion 执行,
    //   于是"旧视图还挂在容器里(等 completion 才撤),新视图已经加上" ⇒ 两屏共存 = 画面重叠。
    //   现在改成【同步】收尾:任何时刻 contentCard 里至多一个内容视图。
    UIViewController *oldVC = _contentViewController;
    if (oldVC) {
        [oldVC willMoveToParentViewController:nil];
        [oldVC.view removeFromSuperview];
        [oldVC removeFromParentViewController];
    }

    _contentViewController = viewController;
    [self addChildViewController:viewController];
    viewController.view.translatesAutoresizingMaskIntoConstraints = NO;

    // 修复:对齐 LauncherRootViewController 的 nav bar 透明化处理。
    // 原卡片布局缺失此逻辑,导致 VersionManagerViewController 等被 UINavigationController
    // 包裹的子页面顶部出现默认不透明 nav bar(白条),与卡片背景不融合。
    if ([viewController isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)viewController;
        nav.delegate = self;
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:nav.navigationBar];
        // 透明化栈中所有 VC(与 RootVC 一致),防止 push 后子页面背景不透明
        for (UIViewController *vc in nav.viewControllers) {
            [[BackgroundManager sharedManager] makeViewControllerTransparent:vc];
        }
    } else {
        [[BackgroundManager sharedManager] makeViewControllerTransparent:viewController];
    }

    // 关键修复(UI 累积异常):deactivate 旧约束,避免反复激活导致 contentCard 内容区左右变宽。
    if (self.currentContentConstraints.count > 0) {
        [NSLayoutConstraint deactivateConstraints:self.currentContentConstraints];
        self.currentContentConstraints = nil;
    }

    NSArray<NSLayoutConstraint *> *newConstraints = @[
        [viewController.view.leadingAnchor constraintEqualToAnchor:self.contentCard.leadingAnchor],
        [viewController.view.trailingAnchor constraintEqualToAnchor:self.contentCard.trailingAnchor],
        [viewController.view.topAnchor constraintEqualToAnchor:self.contentCard.topAnchor],
        [viewController.view.bottomAnchor constraintEqualToAnchor:self.contentCard.bottomAnchor]
    ];

    // ★ [TAB-OVERLAP] ② 结构切换【同步】完成:上面的旧视图移除 + 这里的挂载/约束/布局一次做完。
    //   刻意不再用 [UIView transitionWithView:]:它会对整个容器抓快照,连点时上一张快照还留在
    //   contentCard 里(要等 0.3s 动画结束才被撤),和这一次叠在一起就是用户看到的"画面重叠 / 残影"。
    //   改成只对【新视图自身】做 alpha 淡入 ⇒ 结构上永远只有一个内容视图,快照无处可叠。
    viewController.view.alpha = (animated && oldVC) ? 0.0 : 1.0;
    [self.contentCard addSubview:viewController.view];
    [NSLayoutConstraint activateConstraints:newConstraints];
    [self.contentCard layoutIfNeeded];   // 先布局到位再淡入(否则会从左上角 0x0 小点扩展出来)
    [viewController didMoveToParentViewController:self];
    self.currentContentConstraints = newConstraints;

    // ★ [TAB-OVERLAP] ③ 只淡入新视图;AllowUserInteraction ⇒ 动画期间照常可点(不禁点、不卡手)。
    //   连点时长的那次淡入会被下一次切换立刻打断(旧视图被同步摘掉),不会留下任何残影。
    if (animated && oldVC) {
        [UIView animateWithDuration:0.22
                              delay:0.0
                            options:(UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState)
                         animations:^{
            viewController.view.alpha = 1.0;
        } completion:nil];
    } else {
        viewController.view.alpha = 1.0;
    }
}

#pragma mark - ★ [E1] 实例主区(顶部大卡 + 双列/三列实例网格)

// ============================================================================
// 本区实现 E 方案(SPEC §3.1/§3.2)的主区版式:
//   竖屏:标题「实例」+ 顶部大卡(右侧圆形 ▶)+ 双列实例卡网格(卡上「启动」)+ 底部菜单条;
//   横屏:标题「实例」+ 右上「排序 ⇅ / ＋ 新建」+ 横向铺开的实例卡(3 列,首卡跨 2 列)。
// 数据源 = PLProfiles 里真实的实例(profile);模组数 = 该实例 gameDir/mods 下 jar 计数;
// 启动 = 复用右栏既有启动链路(见 e1LaunchInstanceNamed:),不在本文件重写启动逻辑。
// ============================================================================

#pragma mark 朝向相关的网格度量

/// 当前是否竖屏(直接看 bounds,避免依赖 usingPortraitLayout 的切换时机)
- (BOOL)e1IsPortraitNow {
    CGSize s = self.view.bounds.size;
    return s.height > s.width;
}

/// 网格列数:竖屏 2 列 / 横屏 3 列(SPEC §3.3 差异矩阵)
- (NSInteger)e1GridColumns {
    return [self e1IsPortraitNow] ? 2 : 3;
}

- (CGFloat)e1GridGap {
    return [self e1IsPortraitNow] ? kE1GridGapPortrait : kE1GridGapLandscape;
}

- (CGFloat)e1HeroHeight {
    return [self e1IsPortraitNow] ? kE1HeroHeightPortrait : kE1HeroHeightLandscape;
}

- (CGFloat)e1CardHeight {
    return [self e1IsPortraitNow] ? kE1CardHeightPortrait : kE1CardHeightLandscape;
}

#pragma mark 构建面板

- (void)setupInstancesPanel {
    if (!self.contentCard || self.instancesPanel) return;

    self.e1InstanceCards = [NSMutableArray array];
    self.e1DashedBorderLayers = [NSMutableArray array];

    UIView *panel = [[UIView alloc] initWithFrame:CGRectZero];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.backgroundColor = [UIColor clearColor];
    [self.contentCard addSubview:panel];
    self.instancesPanel = panel;
    [NSLayoutConstraint activateConstraints:@[
        [panel.leadingAnchor  constraintEqualToAnchor:self.contentCard.leadingAnchor],
        [panel.trailingAnchor constraintEqualToAnchor:self.contentCard.trailingAnchor],
        [panel.topAnchor      constraintEqualToAnchor:self.contentCard.topAnchor],
        [panel.bottomAnchor   constraintEqualToAnchor:self.contentCard.bottomAnchor],
    ]];

    // ---------- 标题行(SPEC §3.1「实例」25/700;§3.2 横屏「实例」21 + 排序 + 新建)----------
    UIView *header = [[UIView alloc] initWithFrame:CGRectZero];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:header];

    self.instancesTitleLabel = E1MakeLabel(@"实例", 25.0, UIFontWeightBold, [UIColor whiteColor]);
    [header addSubview:self.instancesTitleLabel];

    // 竖屏右上:齿轮 40×40 / 圆角 13(SPEC §1.1)
    self.instancesGearButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.instancesGearButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.instancesGearButton.layer.cornerRadius = 13.0;
    self.instancesGearButton.layer.masksToBounds = YES;
    self.instancesGearButton.tintColor = [UIColor whiteColor];
    [self.instancesGearButton setImage:[UIImage systemImageNamed:@"gearshape.fill"] forState:UIControlStateNormal];
    [self.instancesGearButton addTarget:self action:@selector(e1GearTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.instancesGearButton];

    // 横屏右上:「排序 ⇅」胶囊 chip(SPEC §3.2 / §1.2 操作 chip)
    self.instancesSortButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.instancesSortButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.instancesSortButton.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
    [self.instancesSortButton setTitle:@"排序 ⇅" forState:UIControlStateNormal];
    self.instancesSortButton.contentEdgeInsets = UIEdgeInsetsMake(0, 13, 0, 13);
    self.instancesSortButton.layer.cornerRadius = 15.0;
    self.instancesSortButton.layer.masksToBounds = YES;
    [self.instancesSortButton addTarget:self action:@selector(e1SortTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.instancesSortButton];

    // 横屏右上:「＋ 新建」主按钮(强调色)
    self.instancesNewButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.instancesNewButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.instancesNewButton.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
    [self.instancesNewButton setTitle:@"＋ 新建" forState:UIControlStateNormal];
    [self.instancesNewButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.instancesNewButton.contentEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 14);
    self.instancesNewButton.layer.cornerRadius = 15.0;
    self.instancesNewButton.layer.masksToBounds = YES;
    [self.instancesNewButton addTarget:self action:@selector(e1NewInstanceTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.instancesNewButton];

    // 标题行高度随朝向变(竖屏给大标题留高),持有约束便于切换
    NSLayoutConstraint *headerHeight = [header.heightAnchor constraintEqualToConstant:46.0];
    self.instancesHeaderHeightConstraint = headerHeight;

    [NSLayoutConstraint activateConstraints:@[
        [header.leadingAnchor  constraintEqualToAnchor:panel.leadingAnchor constant:2.0],
        [header.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-2.0],
        [header.topAnchor      constraintEqualToAnchor:panel.topAnchor],
        headerHeight,

        [self.instancesTitleLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [self.instancesTitleLabel.centerYAnchor  constraintEqualToAnchor:header.centerYAnchor],

        [self.instancesGearButton.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [self.instancesGearButton.centerYAnchor  constraintEqualToAnchor:header.centerYAnchor],
        [self.instancesGearButton.widthAnchor    constraintEqualToConstant:40.0],
        [self.instancesGearButton.heightAnchor   constraintEqualToConstant:40.0],

        [self.instancesNewButton.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [self.instancesNewButton.centerYAnchor  constraintEqualToAnchor:header.centerYAnchor],
        [self.instancesNewButton.heightAnchor   constraintEqualToConstant:30.0],

        [self.instancesSortButton.trailingAnchor constraintEqualToAnchor:self.instancesNewButton.leadingAnchor constant:-8.0],
        [self.instancesSortButton.centerYAnchor  constraintEqualToAnchor:header.centerYAnchor],
        [self.instancesSortButton.heightAnchor   constraintEqualToConstant:30.0],

        // 标题不可压到右侧动作区
        [self.instancesTitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.instancesSortButton.leadingAnchor constant:-8.0],
    ]];

    // ---------- 滚动网格 ----------
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    scroll.showsVerticalScrollIndicator = YES;
    [panel addSubview:scroll];
    self.instancesScrollView = scroll;

    UIStackView *grid = [[UIStackView alloc] initWithFrame:CGRectZero];
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    grid.axis = UILayoutConstraintAxisVertical;
    grid.alignment = UIStackViewAlignmentFill;
    grid.spacing = kE1GridGapPortrait;
    [scroll addSubview:grid];
    self.instancesGridView = grid;

    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor  constraintEqualToAnchor:panel.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],
        [scroll.topAnchor      constraintEqualToAnchor:header.bottomAnchor constant:6.0],
        [scroll.bottomAnchor   constraintEqualToAnchor:panel.bottomAnchor],

        [grid.leadingAnchor  constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [grid.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [grid.topAnchor      constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [grid.bottomAnchor   constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [grid.widthAnchor    constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
    ]];

    self.showingInstancesPanel = YES;
    [self e1ApplyInstancesPanelAppearance];
    [self e1RebuildInstancesGrid];
}

/// ★ [E1] 切回「实例」主区:收起当前子页面(子 VC 仍按原逻辑按需新建,不缓存),
/// 显示实例面板。ShowHomePage / 主页入口都走这里。
- (void)e1ShowInstancesPage {
    if (_contentViewController) {
        UIViewController *oldVC = _contentViewController;
        [oldVC willMoveToParentViewController:nil];
        [oldVC.view removeFromSuperview];
        [oldVC removeFromParentViewController];
        if (self.currentContentConstraints.count > 0) {
            [NSLayoutConstraint deactivateConstraints:self.currentContentConstraints];
            self.currentContentConstraints = nil;
        }
        _contentViewController = nil;
    }
    self.isShowingProfileEditor = NO;
    self.profileEditorVC = nil;
    if (!self.instancesPanel) {
        [self setupInstancesPanel];
    }
    self.instancesPanel.hidden = NO;
    self.showingInstancesPanel = YES;
    [self e1ApplyInstancesPanelAppearance];
    [self e1RebuildInstancesGrid];
    [self.view setNeedsLayout];
}

/// ★ [E1] 面板外观(深浅令牌 + 朝向版式):标题字号/颜色、齿轮 vs 排序/新建的显隐与配色。
- (void)e1ApplyInstancesPanelAppearance {
    if (!self.instancesPanel) return;
    BOOL dark = E1UsesDarkTokens(self.traitCollection);
    BOOL portrait = [self e1IsPortraitNow];

    // 标题:竖屏 25/700、横屏 21/700(SPEC §2.4 / §3.3)
    self.instancesTitleLabel.font = [UIFont systemFontOfSize:(portrait ? 25.0 : 21.0) weight:UIFontWeightBold];
    self.instancesTitleLabel.textColor = E1ColorFG(dark);
    self.instancesHeaderHeightConstraint.constant = portrait ? 46.0 : 44.0;

    // 竖屏:右上齿轮;横屏:右上「排序 / ＋ 新建」(SPEC §3.1 / §3.2)
    self.instancesGearButton.hidden = !portrait;
    self.instancesSortButton.hidden = portrait;
    self.instancesNewButton.hidden  = portrait;

    self.instancesGearButton.backgroundColor = E1ColorSeg(dark);
    self.instancesGearButton.tintColor = E1ColorFG(dark);

    self.instancesSortButton.backgroundColor = E1ColorSeg(dark);
    [self.instancesSortButton setTitleColor:E1ColorFG(dark) forState:UIControlStateNormal];

    self.instancesNewButton.backgroundColor = E1ColorAccent(dark);
    [self.instancesNewButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
}

#pragma mark 重建网格

- (void)e1RebuildInstancesGrid {
    if (!self.instancesGridView) return;

    BOOL dark = E1UsesDarkTokens(self.traitCollection);
    NSInteger cols = [self e1GridColumns];
    CGFloat gap = [self e1GridGap];
    CGFloat heroH = [self e1HeroHeight];
    CGFloat cardH = [self e1CardHeight];

    // 清空(release 视图交给 ARC)
    for (UIView *v in [self.instancesGridView.arrangedSubviews copy]) {
        [self.instancesGridView removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    [self.e1InstanceCards removeAllObjects];
    [self.e1DashedBorderLayers removeAllObjects];
    self.instancesGridView.spacing = gap;

    // ---- 真实数据源:PLProfiles 的实例 ----
    NSMutableDictionary *profiles = [PLProfiles current].profiles;
    NSString *selectedName = [PLProfiles current].selectedProfileName;
    NSArray<NSString *> *allNames = [profiles.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSMutableArray<NSString *> *rest = [NSMutableArray array];
    for (NSString *n in allNames) {
        if (![n isEqualToString:selectedName]) [rest addObject:n];
    }
    // 排序模式(SPEC §6-13 未定案,这里给两种可预期模式):0=选中优先 1=名称 2=最近游玩
    if (self.e1SortMode == 2) {
        [rest sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            double ta = [profiles[a][@"lastPlayed"] doubleValue];
            double tb = [profiles[b][@"lastPlayed"] doubleValue];
            if (ta == tb) return [a localizedCaseInsensitiveCompare:b];
            return (ta > tb) ? NSOrderedAscending : NSOrderedDescending;
        }];
    }
    NSString *heroName = nil;
    if (self.e1SortMode == 0 && selectedName.length > 0 && profiles[selectedName]) {
        heroName = selectedName;
    } else if (allNames.count > 0) {
        heroName = allNames.firstObject;
    }

    // ---- 组织网格单元:大卡(跨 2 列)+ 普通卡(1 列)+ 末张虚线「新建实例」 ----
    NSMutableArray<NSDictionary *> *cells = [NSMutableArray array];
    if (heroName) {
        UIView *hero = [self e1HeroCardWithName:heroName profile:profiles[heroName] dark:dark height:heroH];
        [cells addObject:@{ @"view": hero, @"span": @2, @"h": @(heroH) }];
    }
    for (NSString *n in rest) {
        UIView *c = [self e1CardWithName:n profile:profiles[n] dark:dark height:cardH];
        [cells addObject:@{ @"view": c, @"span": @1, @"h": @(cardH) }];
    }
    UIView *newCard = [self e1NewInstanceCardDark:dark height:cardH];
    [cells addObject:@{ @"view": newCard, @"span": @1, @"h": @(cardH) }];

    // 贪心装行:竖屏 2 列时大卡独占一行;横屏 3 列时大卡(跨2)+ 首张普通卡同行。
    NSMutableArray<NSArray<NSDictionary *> *> *rows = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *cur = [NSMutableArray array];
    NSInteger used = 0;
    for (NSDictionary *cell in cells) {
        NSInteger span = [cell[@"span"] integerValue];
        if (used + span > cols && cur.count > 0) {
            [rows addObject:cur];
            cur = [NSMutableArray array];
            used = 0;
        }
        [cur addObject:cell];
        used += span;
        if (used >= cols) {
            [rows addObject:cur];
            cur = [NSMutableArray array];
            used = 0;
        }
    }
    if (cur.count > 0) [rows addObject:cur];

    for (NSArray<NSDictionary *> *rowCells in rows) {
        UIView *row = [self e1BuildGridRowWithCells:rowCells cols:cols gap:gap];
        [self.instancesGridView addArrangedSubview:row];
    }

    NSLog(@"[E1][INSTANCES] cols=%ld instances=%lu rows=%lu dark=%d hero=%@",
          (long)cols, (unsigned long)allNames.count, (unsigned long)rows.count, dark, heroName ?: @"(none)");
}

/// 一行 = cols 条等宽"列导轨" + 把各单元按 span 跨导轨摆放(最精确,不受 stack 等分限制)
- (UIView *)e1BuildGridRowWithCells:(NSArray<NSDictionary *> *)cells cols:(NSInteger)cols gap:(CGFloat)gap {
    UIView *row = [[UIView alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.backgroundColor = [UIColor clearColor];

    NSMutableArray<UIView *> *guides = [NSMutableArray array];
    for (NSInteger i = 0; i < cols; i++) {
        UIView *g = [[UIView alloc] initWithFrame:CGRectZero];
        g.backgroundColor = [UIColor clearColor];
        g.userInteractionEnabled = NO;   // 纯布局导轨
        [guides addObject:g];
    }
    UIStackView *guideStack = [[UIStackView alloc] initWithArrangedSubviews:guides];
    guideStack.translatesAutoresizingMaskIntoConstraints = NO;
    guideStack.axis = UILayoutConstraintAxisHorizontal;
    guideStack.distribution = UIStackViewDistributionFillEqually;
    guideStack.spacing = gap;
    [row addSubview:guideStack];
    [NSLayoutConstraint activateConstraints:@[
        [guideStack.leadingAnchor  constraintEqualToAnchor:row.leadingAnchor],
        [guideStack.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [guideStack.topAnchor      constraintEqualToAnchor:row.topAnchor],
        [guideStack.bottomAnchor   constraintEqualToAnchor:row.bottomAnchor],
    ]];

    NSInteger idx = 0;
    CGFloat rowH = 0;
    for (NSDictionary *cell in cells) {
        NSInteger span = MAX(1, [cell[@"span"] integerValue]);
        NSInteger start = MIN(idx, cols - 1);
        NSInteger end = MIN(cols - 1, start + span - 1);
        UIView *v = cell[@"view"];
        [row addSubview:v];
        [NSLayoutConstraint activateConstraints:@[
            [v.leadingAnchor  constraintEqualToAnchor:guides[start].leadingAnchor],
            [v.trailingAnchor constraintEqualToAnchor:guides[end].trailingAnchor],
            [v.topAnchor      constraintEqualToAnchor:row.topAnchor],
            [v.bottomAnchor   constraintEqualToAnchor:row.bottomAnchor],
        ]];
        rowH = MAX(rowH, [cell[@"h"] doubleValue]);
        idx += span;
    }
    // 行高:同一行的单元高度一致(竖屏 82/126、横屏 112),显式给一条避免 stack 推不出高度
    [row.heightAnchor constraintEqualToConstant:rowH].active = YES;
    return row;
}

#pragma mark 卡片工厂

/// 玻璃卡基底:走全局 BackgroundManager(用户的毛玻璃/透明度/玻璃强度偏好继续生效 —— 硬约束),
/// 再叠 SPEC §2 令牌:叠色(glass/glass2)+ 高光描边(rim)+ 外阴影(shade)。
- (UIView *)e1GlassCardWithRadius:(CGFloat)radius strong:(BOOL)strong {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = radius;
    card.layer.cornerCurve = kCACornerCurveContinuous;

    // ① 毛玻璃/半透明(全局偏好;iOS 26 上 AmeGlassEffect 会走真·液态玻璃)
    [[BackgroundManager sharedManager] applyEffectToView:card];

    BOOL dark = E1UsesDarkTokens(self.traitCollection);

    // ② 令牌叠色 + 高光描边(自身裁剪,故宿主可以保留外阴影)
    UIView *tint = [[UIView alloc] initWithFrame:CGRectZero];
    tint.translatesAutoresizingMaskIntoConstraints = NO;
    tint.userInteractionEnabled = NO;
    tint.backgroundColor = strong ? E1ColorGlass2(dark) : E1ColorGlass(dark);
    tint.layer.cornerRadius = radius;
    tint.layer.cornerCurve = kCACornerCurveContinuous;
    tint.layer.masksToBounds = YES;
    tint.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    tint.layer.borderColor = E1ColorRim(dark).CGColor;
    [card addSubview:tint];
    [NSLayoutConstraint activateConstraints:@[
        [tint.leadingAnchor  constraintEqualToAnchor:card.leadingAnchor],
        [tint.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [tint.topAnchor      constraintEqualToAnchor:card.topAnchor],
        [tint.bottomAnchor   constraintEqualToAnchor:card.bottomAnchor],
    ]];

    // ③ 外阴影(SPEC §2.5):blur/shine/tint 各自裁剪 ⇒ 宿主不裁剪也能保持圆角玻璃
    card.layer.masksToBounds = NO;
    card.layer.shadowColor = E1ColorShade(dark).CGColor;   // SPEC §2.1 shade:深 rgba(0,0,0,.35) / 浅 rgba(0,0,0,.06)
    card.layer.shadowOpacity = 1.0;                        // alpha 已含在 shade 令牌里,此处不再二次衰减
    card.layer.shadowRadius = strong ? 12.0 : 9.0;
    card.layer.shadowOffset = CGSizeMake(0, 6);
    return card;
}

/// 图标块(SPEC §2.6):圆角方块 + 白系渐变底 + 1px 高光边 + 单色符号
- (UIView *)e1IconViewSymbol:(NSString *)symbol
                        size:(CGFloat)size
                      radius:(CGFloat)radius
                   pointSize:(CGFloat)pt
                       color:(UIColor *)color {
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, size, size)];
    box.translatesAutoresizingMaskIntoConstraints = NO;
    box.layer.cornerRadius = radius;
    box.layer.cornerCurve = kCACornerCurveContinuous;
    box.layer.masksToBounds = YES;
    box.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    box.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;

    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = CGRectMake(0, 0, size, size);
    g.colors = @[ (id)E1ColorIconGradTop().CGColor, (id)E1ColorIconGradBottom().CGColor ];
    g.startPoint = CGPointMake(0.0, 0.0);
    g.endPoint = CGPointMake(1.0, 1.0);
    [box.layer insertSublayer:g atIndex:0];

    UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.tintColor = color;
    [box addSubview:iv];

    [NSLayoutConstraint activateConstraints:@[
        [box.widthAnchor  constraintEqualToConstant:size],
        [box.heightAnchor constraintEqualToConstant:size],
        [iv.centerXAnchor constraintEqualToAnchor:box.centerXAnchor],
        [iv.centerYAnchor constraintEqualToAnchor:box.centerYAnchor],
        [iv.widthAnchor   constraintEqualToConstant:pt],
        [iv.heightAnchor  constraintEqualToConstant:pt],
    ]];
    return box;
}

/// 状态药丸(SPEC §1.1 .pill / §2.1):高 18 胶囊;on=成功绿文字 + 12~16% 绿底
- (UIView *)e1PillWithText:(NSString *)text on:(BOOL)on dark:(BOOL)dark {
    UIView *pill = [[UIView alloc] initWithFrame:CGRectZero];
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    pill.layer.cornerRadius = 9.0;
    pill.layer.masksToBounds = YES;
    pill.backgroundColor = on ? [E1ColorSuccess() colorWithAlphaComponent:0.16] : E1ColorSeg(dark);

    UILabel *l = E1MakeLabel(text, 10.0, UIFontWeightSemibold, on ? E1ColorSuccess() : E1ColorDim(dark));
    [pill addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [pill.heightAnchor constraintEqualToConstant:18.0],
        [l.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:8.0],
        [l.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-8.0],
        [l.centerYAnchor constraintEqualToAnchor:pill.centerYAnchor],
    ]];
    return pill;
}

/// 顶部大卡(SPEC §3.1/§3.2:行式 —— 左图标 + 标题/副文/药丸 + 右侧圆形 ▶)
- (UIView *)e1HeroCardWithName:(NSString *)name
                       profile:(NSDictionary *)profile
                          dark:(BOOL)dark
                        height:(CGFloat)h {
    UIView *card = [self e1GlassCardWithRadius:kE1RadiusHero strong:YES];
    [card.heightAnchor constraintEqualToConstant:h].active = YES;

    UIView *icon = [self e1IconViewSymbol:E1SymbolForInstance(name)
                                     size:40.0
                                   radius:kE1RadiusIconHero
                                pointSize:20.0
                                    color:E1ColorFG(dark)];

    UILabel *title = E1MakeLabel(name, 14.5, UIFontWeightSemibold, E1ColorFG(dark));
    UILabel *meta  = E1MakeLabel(E1InstanceSubtitle(name, profile), 11.0, UIFontWeightRegular, E1ColorDim(dark));

    UIView *pillRenderer = [self e1PillWithText:E1CurrentRendererName() on:YES dark:dark];
    NSString *ver = profile[@"lastVersionId"];
    UIView *pillVersion = [self e1PillWithText:(ver.length ? ver : @"—") on:NO dark:dark];
    UIStackView *pillRow = [[UIStackView alloc] initWithArrangedSubviews:@[ pillRenderer, pillVersion ]];
    pillRow.axis = UILayoutConstraintAxisHorizontal;
    pillRow.spacing = 6.0;
    pillRow.alignment = UIStackViewAlignmentCenter;

    UIStackView *textCol = [[UIStackView alloc] initWithArrangedSubviews:@[ title, meta, pillRow ]];
    textCol.translatesAutoresizingMaskIntoConstraints = NO;
    textCol.axis = UILayoutConstraintAxisVertical;
    textCol.spacing = 5.0;
    textCol.alignment = UIStackViewAlignmentLeading;

    // 圆形启动键 38×38(SPEC §1.1 .btn 圆形 ▶)
    UIButton *play = [UIButton buttonWithType:UIButtonTypeSystem];
    play.translatesAutoresizingMaskIntoConstraints = NO;
    play.backgroundColor = E1ColorAccent(dark);
    play.tintColor = [UIColor whiteColor];
    [play setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal];
    play.layer.cornerRadius = 19.0;
    play.layer.masksToBounds = YES;
    objc_setAssociatedObject(play, kE1InstanceNameKey, name, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [play addTarget:self action:@selector(e1LaunchButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    play.accessibilityLabel = [NSString stringWithFormat:@"启动 %@", name];

    [card addSubview:icon];
    [card addSubview:textCol];
    [card addSubview:play];
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12.0],
        [icon.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],

        [textCol.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:11.0],
        [textCol.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [textCol.topAnchor constraintGreaterThanOrEqualToAnchor:card.topAnchor constant:8.0],
        [textCol.bottomAnchor constraintLessThanOrEqualToAnchor:card.bottomAnchor constant:-8.0],

        [play.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12.0],
        [play.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [play.leadingAnchor constraintGreaterThanOrEqualToAnchor:textCol.trailingAnchor constant:8.0],
        [play.widthAnchor constraintEqualToConstant:38.0],
        [play.heightAnchor constraintEqualToConstant:38.0],
    ]];

    [self e1AttachSelectionTapTo:card name:name];
    [self.e1InstanceCards addObject:card];
    return card;
}

/// 普通实例卡(SPEC §3.1:列式 —— 图标 + 标题 + 副文 + 底部「启动」按钮)
- (UIView *)e1CardWithName:(NSString *)name
                   profile:(NSDictionary *)profile
                      dark:(BOOL)dark
                    height:(CGFloat)h {
    UIView *card = [self e1GlassCardWithRadius:kE1RadiusCard strong:NO];
    [card.heightAnchor constraintEqualToConstant:h].active = YES;

    BOOL landscape = ![self e1IsPortraitNow];
    CGFloat iconSize = landscape ? 30.0 : 32.0;
    CGFloat pad = landscape ? 10.0 : 11.0;
    CGFloat btnH = landscape ? 26.0 : 30.0;
    CGFloat titleSize = landscape ? 13.0 : 13.5;
    CGFloat metaSize = landscape ? 10.0 : 10.5;

    UIView *icon = [self e1IconViewSymbol:E1SymbolForInstance(name)
                                     size:iconSize
                                   radius:kE1RadiusIcon
                                pointSize:iconSize * 0.5
                                    color:E1ColorFG(dark)];
    UILabel *title = E1MakeLabel(name, titleSize, UIFontWeightSemibold, E1ColorFG(dark));
    UILabel *meta  = E1MakeLabel(E1InstanceSubtitle(name, profile), metaSize, UIFontWeightRegular, E1ColorDim(dark));

    UIButton *launch = [UIButton buttonWithType:UIButtonTypeSystem];
    launch.translatesAutoresizingMaskIntoConstraints = NO;
    [launch setTitle:@"启动" forState:UIControlStateNormal];
    [launch setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    launch.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
    launch.backgroundColor = E1ColorAccent(dark);
    launch.layer.cornerRadius = 10.0;
    launch.layer.masksToBounds = YES;
    objc_setAssociatedObject(launch, kE1InstanceNameKey, name, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [launch addTarget:self action:@selector(e1LaunchButtonTapped:) forControlEvents:UIControlEventTouchUpInside];

    [card addSubview:icon];
    [card addSubview:title];
    [card addSubview:meta];
    [card addSubview:launch];
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:pad],
        [icon.topAnchor constraintEqualToAnchor:card.topAnchor constant:pad],

        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:pad],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-pad],
        [title.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:(landscape ? 6.0 : 7.0)],

        [meta.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:pad],
        [meta.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-pad],
        [meta.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2.0],

        [launch.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:pad],
        [launch.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-pad],
        [launch.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-pad],
        [launch.heightAnchor constraintEqualToConstant:btnH],
        [launch.topAnchor constraintGreaterThanOrEqualToAnchor:meta.bottomAnchor constant:4.0],
    ]];

    [self e1AttachSelectionTapTo:card name:name];
    [self.e1InstanceCards addObject:card];
    return card;
}

/// 末张「＋ 新建实例」虚线卡(SPEC §3.1:虚线边框 + 居中 ＋ / 文案)
- (UIView *)e1NewInstanceCardDark:(BOOL)dark height:(CGFloat)h {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor clearColor];
    card.layer.cornerRadius = kE1RadiusCard;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    [card.heightAnchor constraintEqualToConstant:h].active = YES;

    CAShapeLayer *dash = [CAShapeLayer layer];
    dash.fillColor = [UIColor clearColor].CGColor;
    dash.strokeColor = E1ColorRim(dark).CGColor;
    dash.lineWidth = 1.0;
    dash.lineDashPattern = @[ @5, @4 ];
    dash.cornerRadius = kE1RadiusCard;
    [card.layer addSublayer:dash];
    [self.e1DashedBorderLayers addObject:dash];

    UILabel *plus = E1MakeLabel(@"＋", 22.0, UIFontWeightRegular, E1ColorDim(dark));
    plus.textAlignment = NSTextAlignmentCenter;
    UILabel *cap  = E1MakeLabel(@"新建实例", 10.5, UIFontWeightRegular, E1ColorDim(dark));
    cap.textAlignment = NSTextAlignmentCenter;
    UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:@[ plus, cap ]];
    col.translatesAutoresizingMaskIntoConstraints = NO;
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 3.0;
    col.alignment = UIStackViewAlignmentCenter;
    [card addSubview:col];
    [NSLayoutConstraint activateConstraints:@[
        [col.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [col.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
    ]];

    card.userInteractionEnabled = YES;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(e1NewInstanceTapped)];
    [card addGestureRecognizer:tap];
    [self.e1InstanceCards addObject:card];
    return card;
}

#pragma mark 交互

/// 给卡挂"点卡身 = 选中该实例"(不吞卡内按钮的点击)
- (void)e1AttachSelectionTapTo:(UIView *)card name:(NSString *)name {
    objc_setAssociatedObject(card, kE1InstanceNameKey, name, OBJC_ASSOCIATION_COPY_NONATOMIC);
    card.userInteractionEnabled = YES;
    UITapGestureRecognizer *g = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(e1CardTapped:)];
    g.cancelsTouchesInView = NO;   // 卡内「启动」/▶ 按钮照常收到事件
    [card addGestureRecognizer:g];
}

- (void)e1CardTapped:(UITapGestureRecognizer *)g {
    UIView *card = g.view;
    CGPoint p = [g locationInView:card];
    UIView *hit = [card hitTest:p withEvent:nil];
    for (UIView *v = hit; v && v != card; v = v.superview) {
        if ([v isKindOfClass:[UIControl class]]) return;   // 点在按钮上 ⇒ 交给按钮处理
    }
    NSString *name = objc_getAssociatedObject(card, kE1InstanceNameKey);
    if (name.length == 0) return;
    if (![[PLProfiles current].selectedProfileName isEqualToString:name]) {
        [PLProfiles current].selectedProfileName = name;   // setter 内部会 post SelectedProfileChanged
        [self e1RebuildInstancesGrid];
    }
}

- (void)e1LaunchButtonTapped:(UIButton *)sender {
    NSString *name = objc_getAssociatedObject(sender, kE1InstanceNameKey);
    [self e1LaunchInstanceNamed:name];
}

/// 启动指定实例:先选中它,再复用右栏既有启动链路(账号校验/JIT/下载拦截/版本解析都在里面)。
- (void)e1LaunchInstanceNamed:(NSString *)name {
    if (name.length > 0 && ![[PLProfiles current].selectedProfileName isEqualToString:name]) {
        [PLProfiles current].selectedProfileName = name;   // 内部 post SelectedProfileChanged ⇒ 右栏版本信息同步
    }

    UIViewController *rp = self.rightPanelViewController;
    UIButton *launchBtn = nil;
    @try {
        launchBtn = [rp valueForKey:@"launchButton"];
    } @catch (__unused NSException *ex) {
        launchBtn = nil;
    }

    if ([launchBtn isKindOfClass:[UIButton class]]) {
        if (launchBtn.enabled) {
            [launchBtn sendActionsForControlEvents:UIControlEventTouchUpInside];
        } else {
            // 该实例没有可启动版本(lastVersionId 缺失)⇒ 引导去版本管理(与右栏禁用态语义一致)
            [self e1NewInstanceTapped];
        }
        return;
    }

    // 退化:拿不到按钮(属性改名等)就直接调右栏的启动动作,再退到版本管理
    SEL sel = NSSelectorFromString(@"launchButtonTapped");
    if ([rp respondsToSelector:sel]) {
        ((void (*)(id, SEL))objc_msgSend)(rp, sel);
    } else {
        [self e1NewInstanceTapped];
    }
}

- (void)e1NewInstanceTapped {
    // ★ [FIX3] 与主页快捷入口(LauncherNewsViewController)同一个坑:本方法原来只发 ShowVersionManager,
    //   而本页(卡片布局的主页 tab,index 0)自己的 showVersionManager 收到后会调 setContentViewController:,
    //   把【主页内容区】整体换成版本管理页 ⇒ 用户返回后主页就永久停在版本管理(同类“串台”)。
    //   改为:优先切到「实例」标签(index 3 —— 其根页本即 VersionManagerViewController)并 pop 回根页,
    //   主页内容区完全不被替换;不在标签栏(老流程)时才回退原通知。业务结果不变:仍是打开版本管理。
    UITabBarController *tbc = self.tabBarController;
    if ([tbc isKindOfClass:[UITabBarController class]] &&
        tbc.viewControllers.count > 3 &&
        [tbc.viewControllers[3] isKindOfClass:[UINavigationController class]]) {
        tbc.selectedIndex = 3;
        [(UINavigationController *)tbc.viewControllers[3] popToRootViewControllerAnimated:YES];
        return;
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowVersionManager" object:nil];
}

- (void)e1GearTapped {
    // 竖屏标题右侧齿轮 = 设置(SPEC §1.1)
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowSettings" object:nil];
}

- (void)e1SortTapped {
    self.e1SortMode = (self.e1SortMode + 1) % 3;
    NSString *t = (self.e1SortMode == 0) ? @"排序 ⇅"
                : (self.e1SortMode == 1) ? @"名称 ⇅" : @"最近 ⇅";
    [self.instancesSortButton setTitle:t forState:UIControlStateNormal];
    [self e1RebuildInstancesGrid];
}

#pragma mark 布局后刷新(虚线路径 / 玻璃高光渐变)

- (void)e1RefreshInstanceCardChrome {
    for (UIView *card in self.e1InstanceCards) {
        AmeRefreshGlassRim(card);   // BackgroundManager 贴的玻璃高光渐变按新尺寸刷新
    }
    for (CAShapeLayer *dash in self.e1DashedBorderLayers) {
        CALayer *host = dash.superlayer;
        if (!host) continue;
        CGRect b = host.bounds;
        if (CGRectIsEmpty(b)) continue;
        dash.frame = b;
        dash.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, 0.5, 0.5)
                                              cornerRadius:MAX(0.0, dash.cornerRadius)].CGPath;
    }
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    // ★ [PORTRAIT] 放开竖屏:原来是写死 Landscape ⇒ 竖屏进不去。
    // 竖屏排布由 LauncherCardLayoutViewController 切换(三卡竖摞 + 菜单横排);
    // 游戏(SurfaceViewController)单独锁横屏,保证游戏内不会竖过来。
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        return UIInterfaceOrientationMaskAll;
    }
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

#pragma mark - UINavigationControllerDelegate

/// nav push/pop 后重新透明化所有 VC 并重新应用 nav bar 效果
/// 参照 RootVC 的同名实现，确保 push 后子页面样式与卡片背景一致
- (void)navigationController:(UINavigationController *)navigationController
       didShowViewController:(UIViewController *)viewController
                    animated:(BOOL)animated {
    // 透明化刚显示的 VC
    [[BackgroundManager sharedManager] makeViewControllerTransparent:viewController];
    // 同时透明化栈中所有 VC（防止前一个页面透出残留，解决"前一页面未及时消失"问题）
    for (UIViewController *stackVC in navigationController.viewControllers) {
        [[BackgroundManager sharedManager] makeViewControllerTransparent:stackVC];
    }
    // 重新应用导航栏毛玻璃效果（防止 push 后 nav bar 样式被重置）
    [[BackgroundManager sharedManager] applyEffectToNavigationBar:navigationController.navigationBar];
}

@end
