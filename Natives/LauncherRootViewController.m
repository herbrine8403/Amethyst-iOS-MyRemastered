#import "LauncherRootViewController.h"
#import "LauncherMenuViewController.h"
#import "LauncherNewsViewController.h"
#import "LauncherRightPanelViewController.h"
#import "DownloadViewController.h"
#import "VersionManagerViewController.h"
#import "ProfileSettingsViewController.h"
#import "LauncherPreferencesViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "BackgroundManager.h"
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

// 布局常量（iPad 基准值；iPhone 上通过 LauncherRootLayoutWidth 适配后会变窄）
static const CGFloat kSidebarWidthPad = 70.0;      // iPad 左侧边栏宽度
static const CGFloat kSidebarWidthPhone = 56.0;    // iPhone 左侧边栏宽度（仅图标）
static const CGFloat kRightPanelWidthPad = 220.0;  // iPad 右侧面板宽度
static const CGFloat kRightPanelWidthPhone = 168.0; // iPhone 右侧面板宽度（保证按钮文字可读）
// ★ [ROT-FIX] 顶栏(工具条)兜底宽度:6 按钮×56 + 5 间距×8 = 376(与菜单紧凑形态一致);
//   菜单子 VC 就绪后由 preferredTopBarWidth 覆盖。
static const CGFloat kAmeTopBarFallbackWidth = 376.0;

/// 检测物理设备是否为 iPhone（不受 debug.debug_ipad_ui 的 idiom hook 影响）。
/// UIKit+hook.m 会把 idiom 强制改成 Pad，导致 trait.userInterfaceIdiom 不可靠。
/// 这里用 UIDevice.model 检测真实设备类型。
static BOOL LauncherRootIsPhysicalPhone(void) {
    NSString *model = [[UIDevice currentDevice].model lowercaseString];
    return [model containsString:@"iphone"];
}

/// 根据物理设备类型决定侧栏宽度（与 LauncherCardLayoutViewController 保持一致）
static CGFloat LauncherRootLayoutSidebarWidth(UITraitCollection *trait) {
    if (LauncherRootIsPhysicalPhone()) return kSidebarWidthPhone;
    return kSidebarWidthPad;
}

/// 根据物理设备类型决定右侧面板宽度
static CGFloat LauncherRootLayoutRightPanelWidth(UITraitCollection *trait) {
    if (LauncherRootIsPhysicalPhone()) return kRightPanelWidthPhone;
    return kRightPanelWidthPad;
}

// ★ [PORTRAIT-FIX] 竖屏布局常量。
//   竖屏形态：顶栏(原左栏)贴安全区顶部横排一条 ⇒ 内容区吃满剩余宽度 ⇒
//   右栏(头像/启动)收成【底部一张卡】(竖屏再让它占 168pt 横带会把内容挤成一条缝)。
static const CGFloat kPortraitOuterMargin     = 14.0;   // 竖屏屏边留白(与 Card 布局 kE1MarginPortrait 同一语言)
static const CGFloat kPortraitTopBarHeight    = 0.0;    // ★ [ROOTTAB] 底栏已转到根 UITabBarController ⇒ 这里不再留条(0)
// ★ [NORIGHT] 右栏卡下线后,下面两个常量已无人引用 —— 标 __unused 保留原值备查(消掉"未使用变量"告警)。
static const CGFloat kPortraitGap __unused            = 10.0;   // (原)顶栏 ↔ 内容 ↔ 底部卡 间距
static const CGFloat kPortraitRightPanelMinH __unused = 300.0;   // (原)竖屏底部卡最小高
// ★ [SYS-TABBAR] 顶栏圆角常量已不再使用:顶部工具栏改为系统 UITabBar 后,
//   工具条圆角/玻璃形状由系统自己决定(容器上画圆角会把玻璃裁坏)。
//   保留定义并标 __unused,方便将来回退/对照,且不产生"未使用变量"告警。
static const CGFloat kPortraitTopBarCorner __unused = 14.0;   // (原)竖屏顶栏圆角
static const CGFloat kPortraitCardCorner      = 16.0;   // 竖屏底部卡圆角(与横屏右栏保持一致)

// ★ [ROT-FIX] 菜单 VC 顶栏内容宽度(实现于 LauncherMenuViewController.m)。
//   在 RootVC 侧用分类声明，免改头文件；运行时再 respondsToSelector: 保护。
@interface LauncherMenuViewController (RotFixWidth)
- (CGFloat)preferredTopBarWidth;
@end

@interface LauncherRootViewController ()

@property(nonatomic, strong) UIView *sidebarContainer;
@property(nonatomic, strong) UIView *contentContainer;
@property(nonatomic, strong) UIView *rightPanelContainer;

@property(nonatomic, strong) NSLayoutConstraint *contentLeadingConstraint;
@property(nonatomic, strong) NSLayoutConstraint *contentTrailingConstraint;
@property(nonatomic, strong) NSLayoutConstraint *sidebarWidthConstraint;
// ★ [TOP-BAR] 顶栏那组约束(侧栏横条:贴顶/高56/右端停在右栏之前)
@property(nonatomic, strong) NSArray<NSLayoutConstraint *> *ameTopBarConstraints;
// ★ [ROT-FIX] 顶栏宽度:由我们【显式持有】一条 999 优先级宽度约束(只在【横屏】集里激活)。
//   旧实现横屏只有 trailing ≤ 上限，宽度靠菜单的 self 指向的 hug + 750 按钮宽去解，
//   转屏后无人重算 ⇒ 会落到偏小的解而被 masksToBounds 裁掉一截。
@property(nonatomic, strong) NSLayoutConstraint *ameTopBarWidthConstraint;
@property(nonatomic, strong) NSLayoutConstraint *rightPanelWidthConstraint;
// ★ [NORIGHT] 右栏卡片下线:面板容器的"归零"约束(横/竖两套集合同用这几个对象)。
//   同一个对象被两套集合引用 ⇒ 任一时刻只有一套激活,不会造成"同一属性双钉"。
@property(nonatomic, strong) NSArray<NSLayoutConstraint *> *norightPanelConstraints;

// ★ [PORTRAIT-FIX] 竖屏/横屏两套约束(互斥激活,与 LauncherCardLayoutViewController 同思路):
//   横屏 = 原有三栏形态(保持原样,零回归);竖屏 = 顶栏贴安全区 + 内容满宽 + 右栏收成底部卡。
@property(nonatomic, strong) NSArray<NSLayoutConstraint *> *ameLandscapeConstraints;
@property(nonatomic, strong) NSArray<NSLayoutConstraint *> *amePortraitConstraints;
@property(nonatomic, assign) BOOL ameUsingPortraitLayout;   // 当前是否竖屏那套
@property(nonatomic, assign) BOOL ameLayoutModeApplied;     // 是否已经应用过一次(去重,防约束累积)
// ★ [PORTRAIT-FIX] 安全区补偿要用的几条约束(常量按 insets 动态改)
@property(nonatomic, strong) NSLayoutConstraint *amePortraitTopBarTop;
@property(nonatomic, strong) NSLayoutConstraint *amePortraitTopBarLeading;
@property(nonatomic, strong) NSLayoutConstraint *amePortraitTopBarTrailing;
@property(nonatomic, strong) NSLayoutConstraint *amePortraitCardLeading;
@property(nonatomic, strong) NSLayoutConstraint *amePortraitCardTrailing;
@property(nonatomic, strong) NSLayoutConstraint *amePortraitCardBottom;
@property(nonatomic, strong) NSLayoutConstraint *amePortraitCardPinHeight;
// 关键修复（UI 累积异常）：setContentViewController: 之前每次切换都激活 4 个新约束
// （leading/trailing/top/bottom 到 contentContainer），但旧 VC 的约束未显式 deactivate。
// 在 tmpRootVC 保留场景下，缓存复用的子 VC 反复激活约束，layout 解算时 leading/trailing
// 约束叠加导致 contentContainer 内容区左右变宽。现持有当前约束并先 deactivate 再激活。
@property(nonatomic, strong) NSArray<NSLayoutConstraint *> *currentContentConstraints;

@property(nonatomic, assign) BOOL isShowingProfileEditor;
@property(nonatomic, strong) ProfileSettingsViewController *profileEditorVC;

// ★ [PORTRAIT-FIX] 竖屏/横屏形态切换与安全区补偿(定义在文件下方,此处前置声明)
- (BOOL)ameIsPortraitNow;
- (void)applyRootLayoutForCurrentOrientation;
- (void)applyRootSafeAreaInsets;
// ★ [ROT-FIX] 顶栏宽度重算 + 转屏自证
@property(nonatomic, assign) CGSize ameLastRotLoggedSize;
- (void)ameRefreshTopBarWidthForSize:(CGSize)size;
- (CGFloat)ameTopBarContentWidth;
- (CGFloat)ameClampedTopBarWidthForSize:(CGSize)size;

@end

@implementation LauncherRootViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor clearColor];

    // 初始化版本列表（必须在其他视图控制器之前）
    [self initializeVersionLists];

    // 创建三个容器视图
    [self setupContainers];

    // 添加子视图控制器
    [self setupChildViewControllers];

    // 应用背景
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];

    // 监听外观变更（字体颜色 / 卡片颜色），与 Card 布局保持一致
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyCustomAppearance)
                                                 name:@"LauncherAppearanceChanged"
                                               object:nil];
    [self applyCustomAppearance];
}

- (BOOL)prefersStatusBarHidden {
    return YES;
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
                    NSDebugLog(@"[LauncherRootVC] Loaded %d remote versions", remoteVersionList.count);
                });
            }
        } else {
            NSDebugLog(@"[LauncherRootVC] Failed to fetch version list: %@", error.localizedDescription);
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

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    // ★ [NORIGHT] 右栏已下线:面板宽度恒为 0(该约束已不在任何激活集合里;这里保持常量 0 以免误导)。
    if (self.rightPanelWidthConstraint.constant != 0.0) {
        self.rightPanelWidthConstraint.constant = 0.0;
    }
    // ★ [ROT-FIX] 旧代码这里写 self.sidebarWidthConstraint.constant —— 但该约束在
    //   setupContainers 里已被 active=NO(顶栏改用“内容宽”显式约束),写它等于没写
    //   (“尺寸约束常数未真正重算”)。现改为重算显式顶栏宽度。
    [self ameRefreshTopBarWidthForSize:self.view.bounds.size];
    // 通知子 VC 重新布局
    for (UIViewController *child in self.childViewControllers) {
        [child.view setNeedsLayout];
    }
    // ★ [PORTRAIT-FIX] 尺寸类别变化(iPhone/iPad、分屏、转屏)⇒ 重选竖/横形态
    [self applyRootLayoutForCurrentOrientation];
}

// ★ [PORTRAIT-FIX] 安全区变化(转屏时灵动岛换边、home indicator 进出)⇒ 重算顶栏/底部卡补偿。
//   这是唯二可靠的时机:viewDidLayoutSubviews 里 safeAreaInsets 可能还没更新。
- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self applyRootLayoutForCurrentOrientation];
    [self applyRootSafeAreaInsets];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // ★ [PORTRAIT-FIX] 首帧/转屏后对齐竖横形态(幂等:内部只在换形态时动约束)
    [self applyRootLayoutForCurrentOrientation];
    // ★ [ROT-FIX] 顶栏宽度按当前 bounds 兜底重算(转屏后 bounds 已更新)。
    //   旧实现从不在这里重算宽度,转屏后容器宽度只能靠 solver 猜 ⇒ “半截”。
    [self ameRefreshTopBarWidthForSize:self.view.bounds.size];
    // ★ [ROT-FIX] 布置后自证:尺寸变化(含转屏)才打一行，便于装机核对条宽
    CGSize ameSize = self.view.bounds.size;
    if (fabs(ameSize.width - self.ameLastRotLoggedSize.width) > 0.5 ||
        fabs(ameSize.height - self.ameLastRotLoggedSize.height) > 0.5) {
        self.ameLastRotLoggedSize = ameSize;
        NSLog(@"[ROT] %@ size=%.0fx%.0f barW=%.0f",
              (ameSize.width > ameSize.height) ? @"LANDSCAPE" : @"PORTRAIT",
              ameSize.width, ameSize.height, self.ameTopBarWidthConstraint.constant);
    }
    // 修复：移除原先对 nav 栈所有 VC 一刀切注入负 additionalSafeAreaInsets.top 的逻辑。
    // 该负 inset 会导致两个严重问题：
    //   1. 设置页等使用 safeAreaLayoutGuide.topAnchor 布局的 VC，其内容被推到导航栏之上（"飞到顶上"），
    //      外观调整等选项无法正常滚动和操作。
    //   2. Java 管理等 push 进来的子页面，前一个页面的内容因为负 inset 透出在当前页面下方，
    //      形成"前一页面没有及时消失"的视觉残留。
    // "大白条"问题已通过 makeViewControllerTransparent（将 VC view 背景设为 clearColor）
    // + applyEffectToNavigationBar（导航栏毛玻璃）解决，不再需要此 hack。
    //
    // 关键修复（UI 累积异常）：之前仅清理 NEGATIVE .top 的 additionalSafeAreaInsets，
    // 未覆盖 .left/.right/.bottom 与正值累积。在 tmpRootVC 保留场景下，若其他路径
    // 累加 left/right inset，此方法无法兜底，导致 contentContainer 内容区左右变宽。
    // 现清理所有方向的非零 inset。
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

#pragma mark - ★ [ROT-FIX] 顶栏宽度 + 转屏适配

/// 菜单子 VC 声明的“顶栏内容宽度”(visible 按钮总宽 + 间距); 拿不到则用兜底值。
- (CGFloat)ameTopBarContentWidth {
    LauncherMenuViewController *menu = (LauncherMenuViewController *)self.sidebarViewController;
    if ([menu respondsToSelector:@selector(preferredTopBarWidth)]) {
        CGFloat w = [menu preferredTopBarWidth];
        if (w > 1.0) return w;
    }
    return kAmeTopBarFallbackWidth;
}

/// 把内容宽夹到“屏宽 - 右栏宽”，避免顶栏压到右上角头像(对应 required 的 ≤ 上限)。
- (CGFloat)ameClampedTopBarWidthForSize:(CGSize)size {
    CGFloat contentW = [self ameTopBarContentWidth];
    CGFloat rightPanelW = LauncherRootLayoutRightPanelWidth(self.traitCollection);
    CGFloat available = size.width - rightPanelW;
    if (available < 1.0) return contentW;
    return MIN(contentW, available);
}

/// 按给定尺寸重算顶栏宽度约束常数。仅在值真变时写回 ⇒ 不会在 viewDidLayoutSubviews 里反复触发布局。
- (void)ameRefreshTopBarWidthForSize:(CGSize)size {
    if (!self.ameTopBarWidthConstraint) return;
    CGFloat want = [self ameClampedTopBarWidthForSize:size];
    if (fabs(self.ameTopBarWidthConstraint.constant - want) < 0.5) return;
    self.ameTopBarWidthConstraint.constant = want;
}

/// ★ [ROT-FIX] 转屏入口:按【目标 size】先重算顶栏宽度,再让菜单重放紧凑横排
/// ⇒ 尺寸常数不停留在转屏前的旧值(修“旋转后只剩半截”)。
/// 注意:这里【不】主动 activate 某一套约束集 —— 竖/横两套互斥由
/// applyRootLayoutForCurrentOrientation(见 ★ [PORTRAIT-FIX])统一管理,
/// 此处再激活一套只会与它打架(两套同时激活会短暂产生 required 冲突)。
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [self ameRefreshTopBarWidthForSize:size];
    for (UIViewController *child in self.childViewControllers) {
        if ([child respondsToSelector:@selector(setCompactHorizontalLayout:)]) {
            [child performSelector:@selector(setCompactHorizontalLayout:) withObject:@(YES)];
        }
    }
    [self.view setNeedsLayout];
    NSLog(@"[ROT] %@ size=%.0fx%.0f barW=%.0f",
          (size.width > size.height) ? @"LANDSCAPE" : @"PORTRAIT",
          size.width, size.height, self.ameTopBarWidthConstraint.constant);
}

#pragma mark - Setup

- (void)setupContainers {
    // ★ [SYS-TABBAR] 工具条容器 = 一个"透明定位框",玻璃完全交给里面的系统 UITabBar。
    //   旧实现(用户实测「看不出是玻璃」「圆角不对(有直的地方)」的根因):
    //     ① [[BackgroundManager sharedManager] applyEffectToView:] 自绘 UIVisualEffectView 模糊;
    //     ② iOS 26 又叠了一层 UIGlassEffect(还要先把 ①拆掉才看得见);
    //     ③ 圆角/裁剪(cornerRadius + maskedCorners + masksToBounds)画在【容器】上,
    //        于是系统标签栏自带的液态玻璃形状被裁成圆角矩形 —— 圆角自然"有直的地方"。
    //   现在:容器只负责"定位 + 尺寸"(顶栏高 56 / 右端到右栏前),不做任何绘制、不裁剪。
    self.sidebarContainer = [[UIView alloc] init];
    self.sidebarContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.sidebarContainer.backgroundColor = [UIColor clearColor];
    self.sidebarContainer.layer.cornerRadius = 0.0;
    self.sidebarContainer.layer.maskedCorners = 0;          // 不圆任何角
    self.sidebarContainer.layer.masksToBounds = NO;         // ★ 绝不裁剪:否则切掉 UITabBar 的玻璃/圆角
    [self.view addSubview:self.sidebarContainer];

    // 中间内容容器 - 完全透明，四角直角（内部塞入 nav controller + table view，圆角会裁剪内容且无视觉收益）
    self.contentContainer = [[UIView alloc] init];
    self.contentContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentContainer.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.contentContainer];

    // 右侧面板容器 - 半透明，仅保留外侧（右上/右下）圆角
    self.rightPanelContainer = [[UIView alloc] init];
    self.rightPanelContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.rightPanelContainer.layer.cornerRadius = 16;
    self.rightPanelContainer.layer.maskedCorners = kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
    self.rightPanelContainer.layer.masksToBounds = YES;
    [[BackgroundManager sharedManager] applyEffectToView:self.rightPanelContainer];
    [self.view addSubview:self.rightPanelContainer];
    // ★ [NORIGHT] 右栏卡整个下线(用户拍板:「这张图片右边那一大块(右栏卡)把它干掉」):
    //   容器保留在视图树里(面板 VC 才拿得到 window ⇒ 它的通知/present 语义不变),
    //   但被钉成 0×0 + hidden ⇒ 横竖屏都不占一像素(归零约束见下方 norightPanelConstraints)。
    self.rightPanelContainer.hidden = YES;
    
    // 设置约束
    // 使用可变宽度约束，便于 traitCollection 变化时更新（iPhone/iPad 适配）
    self.sidebarWidthConstraint = [self.sidebarContainer.widthAnchor constraintEqualToConstant:LauncherRootLayoutSidebarWidth(self.traitCollection)];
    self.rightPanelWidthConstraint = [self.rightPanelContainer.widthAnchor constraintEqualToConstant:LauncherRootLayoutRightPanelWidth(self.traitCollection)];

    // ★ [TOP-BAR] 侧栏由「左侧竖栏」改为【顶部横条】(用户实测反馈):
    //   ① 贴顶、高 56;② 右端停在右栏(用户头像)之前 ⇒ 不压头像;
    //   ③ 内容区 leading 直接贴屏边 ⇒ 占掉原工具栏那条竖带;④ 右栏保持通高、贴右上。
    self.sidebarWidthConstraint.active = NO;
    NSLayoutConstraint *ameTopBarLeading = [self.sidebarContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor];
    NSLayoutConstraint *ameTopBarTop     = [self.sidebarContainer.topAnchor constraintEqualToAnchor:self.view.topAnchor];
    // ★ [TOP-BAR] ≤:工具条贴合自身内容,可早于右栏结束
    NSLayoutConstraint *ameTopBarTrail   = [self.sidebarContainer.trailingAnchor constraintEqualToAnchor:self.rightPanelContainer.leadingAnchor];
    NSLayoutConstraint *ameTopBarHeight  = [self.sidebarContainer.heightAnchor constraintEqualToConstant:0.0];   // ★ [LAND-TOP] 横屏顶栏高度归零:用户报"横屏主页还是低" ⇒ 这 40pt 把内容整体压下去了(菜单已移到系统底栏,这里不再需要留条)
    // ★ [ROT-FIX] 显式顶栏宽度,优先级 999(< trailing ≤ 的 required) ⇒ 极窄屏时让 ≤ 上限赢，
    //   不会报 "Unable to simultaneously satisfy constraints"。仅加入【横屏】约束集。
    self.ameTopBarWidthConstraint = [self.sidebarContainer.widthAnchor constraintEqualToConstant:kAmeTopBarFallbackWidth];
    self.ameTopBarWidthConstraint.priority = UILayoutPriorityRequired - 1;
    self.ameTopBarConstraints = @[ameTopBarLeading, ameTopBarTop, ameTopBarTrail, ameTopBarHeight];

    // ★ [NORIGHT] 面板容器"归零"约束(横/竖两套集合同用这一批对象):
    //   0×0 + 贴 view 左上角 ⇒ 不占任何可视宽/高;内容区改为直接贴屏边(满宽/满高)。
    //   (面板 VC 内部那一大组 required 约束会在 setupChildViewControllers 里被整组停用,
    //    否则 0×0 会与它们冲突并刷 "Unable to simultaneously satisfy constraints"。)
    NSLayoutConstraint *norightPanelTop   = [self.rightPanelContainer.topAnchor     constraintEqualToAnchor:self.view.topAnchor];
    NSLayoutConstraint *norightPanelLead  = [self.rightPanelContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor];
    NSLayoutConstraint *norightPanelZeroW = [self.rightPanelContainer.widthAnchor   constraintEqualToConstant:0.0];
    NSLayoutConstraint *norightPanelZeroH = [self.rightPanelContainer.heightAnchor  constraintEqualToConstant:0.0];
    self.norightPanelConstraints = @[norightPanelLead, norightPanelTop, norightPanelZeroW, norightPanelZeroH];

    NSLayoutConstraint *ameLspContentLeading     = [self.contentContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor];
    NSLayoutConstraint *ameLspContentTrailing    = [self.contentContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor];   // ★ [NORIGHT] 原 = rightPanelContainer.leading
    NSLayoutConstraint *ameLspContentTop         = [self.contentContainer.topAnchor constraintEqualToAnchor:self.sidebarContainer.bottomAnchor];
    NSLayoutConstraint *ameLspContentBottom      = [self.contentContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor];

    // ===== 横屏约束集 =====
    // ★ [NORIGHT] 除"右栏归零"外与改动前逐条一致:顶栏照旧、内容区四边贴屏(不再给右栏留 168pt 竖带)。
    self.ameLandscapeConstraints = @[
        ameTopBarLeading, ameTopBarTop, ameTopBarTrail, ameTopBarHeight,
        ameLspContentLeading, ameLspContentTrailing, ameLspContentTop, ameLspContentBottom,
        norightPanelLead, norightPanelTop, norightPanelZeroW, norightPanelZeroH
    ];

    // ===== ★ [PORTRAIT-FIX] 竖屏约束集 =====
    //   用户原话:「你根本没写竖屏的 ui 啊?」—— 旧代码只有上面那套横屏形态:
    //     ① 顶栏 top 钉在 view.top ⇒ 竖屏整条被灵动岛/刘海压住;
    //     ② 右栏(168pt)通高占右侧 ⇒ iPhone 竖屏(≈390pt 宽)内容区只剩 ≈222pt,新闻网格被挤成一条缝;
    //     ③ 顶部/底部都没吃安全区。
    //   竖屏形态:顶栏 = 贴安全区顶部的浮动横条(四角圆角);内容 = 吃满其下全部宽度;
    //             右栏(头像/启动) = 收成底部一张卡,底部避开 home indicator。
    self.amePortraitTopBarLeading  = [self.sidebarContainer.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor  constant:kPortraitOuterMargin];   // ★ [CAPSULE] 参考 LiveContainer:左右留边
    // ★ [BOTTOM-BAR] 竖屏:标签栏从顶部搬到【屏幕底部】(用户要求,像 LiveContainer 底栏)。
    self.amePortraitTopBarTop      = [self.sidebarContainer.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor   constant:-(kPortraitOuterMargin)];   // ★ [CAPSULE] 底留一条缝(下面安全区再补)
    self.amePortraitTopBarTrailing = [self.sidebarContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-kPortraitOuterMargin];   // ★ [CAPSULE]
    NSLayoutConstraint *ptTopBarHeight = [self.sidebarContainer.heightAnchor constraintEqualToConstant:0.0];   // ★ [NORIGHT] 原 92.0(自绘底栏占位;底栏已迁到根 UITabBarController ⇒ 这条 92pt 空带不该再占)

    // ★ [NORIGHT] ★★★ 竖屏"底部右栏卡"整块下线(用户:「这张图片的右边那一大块(右栏卡)把它干掉,
    //   留更多空间给主页,里面的东西搬家」)★★★
    //   面板原来的定位约束(leading / trailing / bottom / minHeight / pinHeight)【一条都不再创建】
    //   ⇒ 天然不存在"同一属性被两套钉住";面板改用横屏那批 norightPanelConstraints(0×0 + hidden)。
    //   (面板里"头像+用户名+版本"搬进主页欢迎卡、"启动游戏"搬成主页底部紧凑胶囊、
    //    "JIT"搬成主页顶栏 pill、"执行Jar/选择版本"搬到实例页顶部 —— 行为全部转发原方法。)

    NSLayoutConstraint *ptContentLeading  = [self.contentContainer.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor];
    NSLayoutConstraint *ptContentTrailing = [self.contentContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor];
    NSLayoutConstraint *ptContentTop      = [self.contentContainer.topAnchor      constraintEqualToAnchor:self.view.topAnchor constant:0];
    // ★ [NORIGHT] 原 = rightPanelContainer.top - gap(内容区被那张卡压掉约 300pt);
    //   现在四边贴屏 = 主页/内容区吃满全部空间,底部标签栏由内容 VC 自己的安全区自动让位。
    NSLayoutConstraint *ptContentBottom   = [self.contentContainer.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor constant:0];

    self.amePortraitConstraints = [@[
        self.amePortraitTopBarLeading, self.amePortraitTopBarTop, self.amePortraitTopBarTrailing, ptTopBarHeight,
        ptContentLeading, ptContentTrailing, ptContentTop, ptContentBottom
    ] arrayByAddingObjectsFromArray:self.norightPanelConstraints];   // ★ [NORIGHT] 面板归零(与横屏同一批对象)

    // ★ [PORTRAIT-FIX] 圆角改用 continuous 曲线(更贴近设计稿;两套形态通用)
    if (@available(iOS 13.0, *)) {
        self.sidebarContainer.layer.cornerCurve = kCACornerCurveContinuous;
        self.rightPanelContainer.layer.cornerCurve = kCACornerCurveContinuous;
    }

    // ★ [TOP-BAR] 横条形态下菜单要横排(否则竖着一列图标会被 56pt 裁掉)
    // ★ [PORTRAIT-FIX] 竖屏同样是横排顶栏 ⇒ 两种形态都横排。
    for (UIViewController *child in self.childViewControllers) {
        if ([child respondsToSelector:@selector(setCompactHorizontalLayout:)]) {
            [child performSelector:@selector(setCompactHorizontalLayout:) withObject:@(YES)];
        }
    }

    // ★ [PORTRAIT-FIX] 立即按当前方向激活一套(不等 viewDidLayoutSubviews,避免首帧用错形态)
    [self applyRootLayoutForCurrentOrientation];
}

#pragma mark - ★ [PORTRAIT-FIX] 竖屏 / 横屏形态切换

/// 当前是否竖屏(以 view 实际尺寸判定,比 traitCollection 更可靠:
/// 本工程 UIKit+hook 会把 idiom 强制成 Pad,竖直 sizeClass 也不一定准)。
- (BOOL)ameIsPortraitNow {
    CGSize s = self.view.bounds.size;
    return (s.width > 0 && s.height > 0 && s.height > s.width);
}

/// 竖屏/横屏两套约束互斥激活 + 圆角形态切换。幂等:只在真正换形态时动约束(防约束累积)。
- (void)applyRootLayoutForCurrentOrientation {
    CGSize s = self.view.bounds.size;
    if (s.width <= 0 || s.height <= 0) return;      // 首帧尺寸还没定,等 viewDidLayoutSubviews
    if (!self.ameLandscapeConstraints || !self.amePortraitConstraints) return;  // setupContainers 还没跑
    BOOL portrait = [self ameIsPortraitNow];
    if (self.ameLayoutModeApplied && self.ameUsingPortraitLayout == portrait) return;
    self.ameUsingPortraitLayout = portrait;
    self.ameLayoutModeApplied = YES;

    if (portrait) {
        // ★ [PORTRAIT-FIX] 竖屏:底部卡是"浮动卡片" ⇒ 四角圆角;右栏不再通高。
        // ★ [SYS-TABBAR] 顶栏容器不再设圆角/裁剪 —— 工具条外观(含圆角)由里面的系统
        //   UITabBar 自己决定;在容器上画圆角会把系统标签栏的玻璃形状裁坏。
        self.rightPanelContainer.layer.cornerRadius = kPortraitCardCorner;
        self.rightPanelContainer.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
                                                       kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
        [NSLayoutConstraint deactivateConstraints:self.ameLandscapeConstraints];
        [NSLayoutConstraint activateConstraints:self.amePortraitConstraints];
    } else {
        // 横屏:维持原形态(右栏通高,只圆右侧两角)
        // ★ [SYS-TABBAR] 同上:顶栏容器的圆角/遮罩交给系统 UITabBar。
        self.rightPanelContainer.layer.cornerRadius = 16.0;
        self.rightPanelContainer.layer.maskedCorners = kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
        [NSLayoutConstraint deactivateConstraints:self.amePortraitConstraints];
        [NSLayoutConstraint activateConstraints:self.ameLandscapeConstraints];
    }

    // 菜单顶栏两向都横排(横屏也是横条)
    for (UIViewController *child in self.childViewControllers) {
        if ([child respondsToSelector:@selector(setCompactHorizontalLayout:)]) {
            [child performSelector:@selector(setCompactHorizontalLayout:) withObject:@(YES)];
        }
    }

    [self applyRootSafeAreaInsets];
    [self.view setNeedsLayout];

    // ★ [PORTRAIT-FIX] 自证日志(一行):装机后 `log stream --predicate 'eventMessage CONTAINS "[PORTRAIT-FIX]"'` 核对。
    NSLog(@"[PORTRAIT-FIX][ROOT][NORIGHT] layout=%@ size=%.0fx%.0f safe(top=%.0f bottom=%.0f left=%.0f right=%.0f) topBarH=%.0f rightPanel=%.0fx%.0f",
          portrait ? @"PORTRAIT" : @"LANDSCAPE",
          s.width, s.height,
          self.view.safeAreaInsets.top, self.view.safeAreaInsets.bottom,
          self.view.safeAreaInsets.left, self.view.safeAreaInsets.right,
          self.sidebarContainer.bounds.size.height,
          self.rightPanelContainer.bounds.size.width, self.rightPanelContainer.bounds.size.height);
}

/// ★ [NORIGHT] 安全区补偿:右栏卡片下线后,竖屏已无卡片需要补偿,顶栏容器也已 0 高。
///   内容区四边贴屏 ⇒ 底部标签栏 / Home 条由**内容 VC 自己**的安全区(view.safeAreaInsets)让位,
///   这里只把(已失效的)顶栏容器钉死在 0 处,并打一行自证日志。
- (void)applyRootSafeAreaInsets {
    if (!self.amePortraitTopBarTop || !self.amePortraitTopBarLeading || !self.amePortraitTopBarTrailing) return;
    // ★ [NORIGHT] 面板卡片的定位约束已全部不再创建 ⇒ 原来那几行 constant 写入已删除
    //   (旧实现按 safe.left/right 把卡片左右往里推 —— 卡片没了,推它没有意义)。
    self.amePortraitTopBarTop.constant      = 0;   // 贴屏幕最底(容器 0 高 ⇒ 不可见)
    self.amePortraitTopBarLeading.constant  = 0;
    self.amePortraitTopBarTrailing.constant = 0;
    NSLog(@"[NORIGHT][ROOT] safeArea l=%.0f t=%.0f r=%.0f b=%.0f panel=%.0fx%.0f (右栏已下线:0×0+hidden,内容区四边贴屏)",
          self.view.safeAreaInsets.left, self.view.safeAreaInsets.top,
          self.view.safeAreaInsets.right, self.view.safeAreaInsets.bottom,
          self.rightPanelContainer.bounds.size.width, self.rightPanelContainer.bounds.size.height);
}

- (void)setupChildViewControllers {
    // 左侧边栏 - 功能菜单
    LauncherMenuViewController *sidebarVC = [[LauncherMenuViewController alloc] init];
    [self addChildViewController:sidebarVC];
    sidebarVC.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.sidebarContainer addSubview:sidebarVC.view];
    [NSLayoutConstraint activateConstraints:@[
        [sidebarVC.view.leadingAnchor constraintEqualToAnchor:self.sidebarContainer.leadingAnchor],
        [sidebarVC.view.trailingAnchor constraintEqualToAnchor:self.sidebarContainer.trailingAnchor],
        [sidebarVC.view.topAnchor constraintEqualToAnchor:self.sidebarContainer.topAnchor],
        [sidebarVC.view.bottomAnchor constraintEqualToAnchor:self.sidebarContainer.bottomAnchor]
    ]];
    [sidebarVC didMoveToParentViewController:self];
    _sidebarViewController = sidebarVC;
    
    // 中间内容 - 默认显示新闻页
    LauncherNewsViewController *newsVC = [[LauncherNewsViewController alloc] init];
    [self setContentViewController:newsVC animated:NO];
    
    // 右侧面板 - 账户和启动
    LauncherRightPanelViewController *rightPanelVC = [[LauncherRightPanelViewController alloc] init];
    [self addChildViewController:rightPanelVC];
    rightPanelVC.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.rightPanelContainer addSubview:rightPanelVC.view];
    [NSLayoutConstraint activateConstraints:@[
        [rightPanelVC.view.leadingAnchor constraintEqualToAnchor:self.rightPanelContainer.leadingAnchor],
        [rightPanelVC.view.trailingAnchor constraintEqualToAnchor:self.rightPanelContainer.trailingAnchor],
        [rightPanelVC.view.topAnchor constraintEqualToAnchor:self.rightPanelContainer.topAnchor],
        [rightPanelVC.view.bottomAnchor constraintEqualToAnchor:self.rightPanelContainer.bottomAnchor]
    ]];
    [rightPanelVC didMoveToParentViewController:self];
    // ★ [NORIGHT] 右栏 UI 下线:停用面板内部的整组 required 约束(否则容器 0×0 会与它们冲突,
    //   控制台会刷 "Unable to simultaneously satisfy constraints")。面板继续作为**不可见控制器**
    //   存在 —— 通知监听、启动全链路、执行 Jar、版本选择、下载中心弹窗一律照旧。
    [rightPanelVC norightCollapsePanelLayout:YES];
    _rightPanelViewController = rightPanelVC;
    
    // 注册通知监听
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showHomePage)
                                                 name:@"ShowHomePage"
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
    // 监听显示 AI 助手页面
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showAIPage)
                                                 name:@"ShowAIPage"
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
    // FCL 风格：账户管理在中间内容区显示（不再 FormSheet 弹窗）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showAccountManager)
                                                 name:@"ShowAccountManager"
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
}

- (void)showHomePage {
    LauncherNewsViewController *newsVC = [[LauncherNewsViewController alloc] init];
    [self setContentViewController:newsVC animated:YES];
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
    // 从 AiSessionStore 取最近会话，没有则让 AIViewController 新建一个
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

/// FCL 风格：账户管理在中间内容区显示（不再 FormSheet 弹窗）
- (void)showAccountManager {
    AccountListViewController *vc = [[AccountListViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    // 账户选择后通知右侧面板刷新（使用已有的 UpdateAccountInfo 通知）
    vc.whenItemSelected = ^void() {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"UpdateAccountInfo" object:nil];
    };
    // 账户删除后也通知右侧面板刷新
    vc.whenDelete = ^void(NSString *name) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"UpdateAccountInfo" object:nil];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.prefersLargeTitles = NO;
    // ★ [ACCOUNTBACK] 账户链路“进得去出不来”修复(本处为根因另一半,详见 AccountListViewController.m 注释):
    //   本页是**新 nav 的根**,系统不会给返回键 ⇒ 这里显式把导航栏显示出来(它本是唯一出口的载体),
    //   并把 tintColor 定为语义色。返回键本身由 AccountListViewController 在 viewWillAppear 注入
    //   (根页才注入;登录页 push 上去后走系统返回键)。只动外观,账户业务一行不改。
    nav.navigationBarHidden = NO;
    nav.navigationBar.tintColor = [UIColor labelColor];
    [self setContentViewController:nav animated:YES];
}

- (void)backgroundChanged {
    // 重新应用背景
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];
}

- (void)uiEffectChanged:(NSNotification *)notification {
    // 重新应用毛玻璃/半透明效果到容器视图
    // ★ [SYS-TABBAR] 顶栏容器不再自绘效果:玻璃由里面的系统 UITabBar 提供。
    [[BackgroundManager sharedManager] applyEffectToView:self.rightPanelContainer];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Custom Appearance（字体颜色 / 卡片颜色，与 Card 布局一致）

- (void)applyCustomAppearance {
    // 应用自定义卡片颜色（半透明覆盖 BackgroundManager 的毛玻璃，而非完全替换）
    NSString *cardColor = getPrefObject(@"general.card_color");
    if (cardColor.length > 0) {
        UIColor *color = [self colorFromHexString:cardColor];
        if (color) {
            // 使用半透明颜色覆盖毛玻璃，alpha 提升到 0.85 增强可见度。
            // 之前 0.7 太淡，浅色背景几乎看不出效果。
            // 保留毛玻璃（backgroundColor 叠加在 UIVisualEffectView 之上），
            // 既显示卡片色调又透出背景图。
            CGFloat r, g, b, a;
            if ([color getRed:&r green:&g blue:&b alpha:&a]) {
                UIColor *semiColor = [UIColor colorWithRed:r green:g blue:b alpha:MIN(a, 0.85)];
                // ★ [SYS-TABBAR] 只给右栏卡片上色;顶栏容器保持透明(不能盖住系统标签栏玻璃)。
                [self applySemiTransparentColor:semiColor toContainer:self.rightPanelContainer];
            }
        }
    } else {
        // 未设置自定义颜色时，恢复毛玻璃效果
        // ★ [SYS-TABBAR] 顶栏容器不恢复自绘效果(玻璃由系统 UITabBar 提供)。
        [self restoreEffectToContainer:self.rightPanelContainer];
    }
    // 通知右侧面板、菜单等子 VC 同步刷新外观（text_color / card_color 联动）
    [[NSNotificationCenter defaultCenter] postNotificationName:@"LauncherAppearanceApplied" object:nil];
}

- (void)applySemiTransparentColor:(UIColor *)color toContainer:(UIView *)container {
    // 保留 BackgroundManager 的毛玻璃 UIVisualEffectView，在其上叠加半透明纯色
    // 这样既显示用户自定义的卡片颜色，又能透出背景图
    container.backgroundColor = color;
}

- (void)restoreEffectToContainer:(UIView *)container {
    container.backgroundColor = [UIColor clearColor];
    // 检查是否已有毛玻璃，没有则重新应用
    BOOL hasBlur = NO;
    for (UIView *sub in container.subviews) {
        if ([sub isKindOfClass:[UIVisualEffectView class]]) {
            hasBlur = YES;
            break;
        }
    }
    if (!hasBlur) {
        [[BackgroundManager sharedManager] applyEffectToView:container];
    }
}

- (UIColor *)colorFromHexString:(NSString *)hexString {
    NSString *hex = [hexString stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (hex.length != 6 && hex.length != 8) return nil;
    unsigned int rgb = 0;
    if (![[NSScanner scannerWithString:hex] scanHexInt:&rgb]) return nil;
    unsigned int r, g, b, a;
    if (hex.length == 6) {
        // RRGGBB
        r = (rgb >> 16) & 0xFF;
        g = (rgb >> 8) & 0xFF;
        b = rgb & 0xFF;
        a = 255;
    } else {
        // AARRGGBB
        a = (rgb >> 24) & 0xFF;
        r = (rgb >> 16) & 0xFF;
        g = (rgb >> 8) & 0xFF;
        b = rgb & 0xFF;
    }
    return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a/255.0];
}

#pragma mark - Content Switching

- (void)setContentViewController:(UIViewController *)viewController animated:(BOOL)animated {
    if (!viewController) return;

    // ★ [TAB-OVERLAP] 同一实例直接跳过(避免重复加约束 / hairline 累积)。
    //   但必须保证它此刻真的挂在容器上并且完全可见 —— 上一次切换的淡入动画可能还没走完
    //   (alpha < 1),直接 return 会把"半透明 / 没挂上"的状态留在屏幕上。
    if (viewController == _contentViewController) {
        if (viewController.view.superview != self.contentContainer) {
            viewController.view.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentContainer addSubview:viewController.view];
            if (self.currentContentConstraints.count > 0) {
                [NSLayoutConstraint activateConstraints:self.currentContentConstraints];
            }
        }
        viewController.view.alpha = 1.0;
        return;
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
    //   现在改成【同步】收尾:任何时刻容器里至多一个内容视图。
    UIViewController *oldVC = _contentViewController;
    if (oldVC) {
        [oldVC willMoveToParentViewController:nil];
        [oldVC.view removeFromSuperview];
        [oldVC removeFromParentViewController];
    }

    _contentViewController = viewController;
    [self addChildViewController:viewController];
    viewController.view.translatesAutoresizingMaskIntoConstraints = NO;

    // FCL 风格:对 UINavigationController 应用 nav bar 毛玻璃效果,并对内容 VC 透明化处理,
    // 避免顶部出现默认白色 nav bar 形成"大白条",同时与两侧深色毛玻璃面板视觉一致。
    if ([viewController isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)viewController;
        nav.delegate = self;
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:nav.navigationBar];
        // 透明化 topViewController,让背景透出 nav bar 毛玻璃
        [[BackgroundManager sharedManager] makeViewControllerTransparent:nav.topViewController];
        // 透明化 nav 栈中所有已存在的 VC(防止前一个页面透出残留)
        for (UIViewController *stackVC in nav.viewControllers) {
            [[BackgroundManager sharedManager] makeViewControllerTransparent:stackVC];
        }
    } else {
        // 非导航控制器包装的 VC 也透明化,确保与背景融合
        [[BackgroundManager sharedManager] makeViewControllerTransparent:viewController];
    }

    // 关键修复(UI 累积异常):deactivate 旧约束,避免在 tmpRootVC 保留场景下
    // 缓存复用的子 VC 反复激活约束导致 contentContainer 内容区左右变宽。
    if (self.currentContentConstraints.count > 0) {
        [NSLayoutConstraint deactivateConstraints:self.currentContentConstraints];
        self.currentContentConstraints = nil;
    }

    NSArray<NSLayoutConstraint *> *newConstraints = @[
        [viewController.view.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
        [viewController.view.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor],
        [viewController.view.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor],
        [viewController.view.bottomAnchor constraintEqualToAnchor:self.contentContainer.bottomAnchor]
    ];

    // ★ [TAB-OVERLAP] ② 结构切换【同步】完成:上面的旧视图移除 + 这里的挂载/约束/布局一次做完。
    //   刻意不再用 [UIView transitionWithView:]:它会对整个容器抓快照,连点时上一张快照还留在
    //   容器里(要等 0.3s 动画结束才被撤),和这一次叠在一起就是用户看到的"画面重叠 / 残影"。
    //   改成只对【新视图自身】做 alpha 淡入 ⇒ 结构上永远只有一个内容视图,快照无处可叠。
    viewController.view.alpha = (animated && oldVC) ? 0.0 : 1.0;
    [self.contentContainer addSubview:viewController.view];
    [NSLayoutConstraint activateConstraints:newConstraints];
    [self.contentContainer layoutIfNeeded];   // 先布局到位再淡入(否则会从左上角 0x0 小点扩展出来)
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

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    // ★ [PORTRAIT] 放开竖屏:原来是写死 Landscape ⇒ 竖屏进不去。
    // 竖屏排布由 LauncherCardLayoutViewController 切换(三卡竖摞 + 菜单横排);
    // 游戏(SurfaceViewController)单独锁横屏,保证游戏内不会竖过来。
    // ★ [PORTRAIT] 游戏页锁横屏:窗口层已放开竖屏(SceneDelegate/AppDelegate),
    //   若当前内容是游戏(SurfaceViewController,可能在导航栈里),这里必须把它锁回横屏,
    //   否则游戏内会跟着竖过来。启动器各页则允许竖屏。
    UIViewController *content = _contentViewController;
    if ([content isKindOfClass:[UINavigationController class]]) {
        content = ((UINavigationController *)content).topViewController;
    }
    Class gameCls = NSClassFromString(@"SurfaceViewController");
    if (gameCls != Nil && [content isKindOfClass:gameCls]) {
        return UIInterfaceOrientationMaskLandscape;
    }

    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        return UIInterfaceOrientationMaskAll;
    }
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

#pragma mark - UINavigationControllerDelegate

/// 当 nav 栈 push 或 pop 完成后，对新显示的 VC 透明化处理，
/// 确保所有 push 进来的子页面（如 Java 管理、模组管理、整合包导入等）
/// 都能透出自定义启动器背景，而非显示默认的 systemBackgroundColor（白色）。
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
