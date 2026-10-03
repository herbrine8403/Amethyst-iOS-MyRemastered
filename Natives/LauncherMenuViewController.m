// ===========================================================================
//  ★ [SWIFT-BAR] 底部标签栏 = SwiftUI TabView(AmeTabBar.swift 里的系统标签栏)
//  ---------------------------------------------------------------------------
//  背景(三轮演进,记在此处避免下次再绕):
//    v0 自绘:UIStackView + 6 个 UIButton + 自绘 blur/高光 —— 用户:「看不出是玻璃」
//    v1 [SYS-TABBAR] 裸 UITabBar:玻璃对了,但【只有图标没有文字】—— iOS 26 对
//       "游离的 UITabBar"(不在 UITabBarController 里)不给每项的标题版式。
//    v2 [TABC] 真 UITabBarController + UITabBarAppearance(stacked):标题被系统摆
//       在图标【右边】(inline 版式);容器 68→92 也救不回来(截图 md5 与 v2 相同)。
//    参考 LiveContainer(LiveContainerSwiftUI/Views/LCTabView.swift):它就是一句
//    `TabView { … .tabItem { Label(…) } }`,没有任何自绘/appearance —— 唯一能同时
//    拿到【图标在上 / 中文在下】+【系统液态玻璃】的做法。
//
//  做法(v3,本文件):底栏换成 SwiftUI —— Natives/AmeTabBar.swift 里的 `AmeBar`
//    (TabView + 5 个 .tabItem{ Label })。本文件只负责:
//      ① 把宿主子 VC([AmeTabBarHost makeHostWithTag:0])四边铺满本 VC 的 view;
//      ② 监听 NSNotificationCenter 通知名 "AmeTabSelected"(userInfo @{@"index"}),
//         转发给既有的 handleMenuSelection:(导航语义与 v1/v2 逐条相同)。
//
//  ★ 5 项(★ 用户指示:删掉「多人游戏」—— 还在维护、无实际入口):
//     0 实例 → ShowHomePage          1 下载 → ShowDownloadPage
//     2 AI   → showAI(present)       3 资源 → ShowVersionManager
//     4 设置 → ShowSettings
//
//  ★ 外观(玻璃/圆角/版式)一个字节都不自绘,也不设 UITabBarAppearance —— 全部
//    交给系统,与 LiveContainer 底栏同一思路。本文件仅保留"未选中项 tint"能力。
// ===========================================================================
#import "LauncherMenuViewController.h"
#import "LauncherPreferencesViewController.h"
#import "LauncherPreferences.h"
#import "VersionManagerViewController.h"
#import "ProfileSettingsViewController.h"
#import "PLProfiles.h"
#import "BackgroundManager.h"
#import "utils.h"

// ★ [SWIFT-BAR] 底栏已换成 SwiftUI TabView(Natives/AmeTabBar.swift)。
//   本文件不再持有 UITabBarController;只 ① 挂子 VC ② 铺满容器 ③ 监听 AmeTabSelected。
//
// ★ [SWIFT-BAR] AmeTabBarHost 是 Swift 侧 @objc 导出的类。本工程用 CMake 直接编
//   .m/.swift(不产 Swift module / -Swift.h),所以这里手写前向声明;选择器必须与
//   Swift 的 @objc 导出名逐字一致:
//     + (UIViewController *)makeHostWithTag:(NSInteger)tag;
//     + (void)setIconSize:(double)size;
//     + (void)setHeight:(double)height;
//     + (void)setStyle:(NSInteger)style;
//     + (void)setUnselectedTintColor:(nullable UIColor *)color;
@interface AmeTabBarHost : NSObject
+ (UIViewController *)makeHostWithTag:(NSInteger)tag;
+ (void)setIconSize:(double)size;
+ (void)setHeight:(double)height;
+ (void)setStyle:(NSInteger)style;
+ (void)setUnselectedTintColor:(nullable UIColor *)color;
@end

@interface LauncherMenuViewController ()

// ★ [SWIFT-BAR] 子控制器:SwiftUI TabView 宿主(AmeTabBar.swift 的 AmeTabBarHost)。
//   底部那条液态玻璃标签栏由 SwiftUI 内部的原生 UITabBar 自己画,外观不自绘。
@property(nonatomic, strong) UIViewController *swiftTabBarHost;

@property(nonatomic, strong) NSArray<NSDictionary *> *menuItems;

@property(nonatomic, assign) NSInteger selectedIndex;

// ★ [SYS-TABBAR] 父布局 VC 仍会调 setCompactHorizontalLayout:,这里只记录状态
//   (系统标签栏两向都是同一条横条,不再需要"竖屏/横屏"两套自绘排布)。
@property(nonatomic, assign) BOOL compactLayout;
@property(nonatomic, assign) BOOL hasPendingCompact;
@property(nonatomic, assign) BOOL pendingCompact;
@property(nonatomic, assign) CGSize ameLastRotLoggedSize;

@end

@implementation LauncherMenuViewController

#pragma mark - ★ [SYS-TABBAR] 外部兼容接口(父布局 VC 会调用)

/// ★ [SYS-TABBAR] 父布局 VC(LauncherRootViewController /
/// LauncherCardLayoutViewController)在初始化与转屏时会调本方法。
/// 系统标签栏的排布由它自己负责(永远是一行),这里只记录状态 + 打一行自证日志。
- (void)setCompactHorizontalLayout:(NSNumber *)compactNumber {
    BOOL compact = [compactNumber boolValue];
    self.compactLayout = compact;
    if (!self.swiftTabBarHost) {   // ★ [SWIFT-BAR] viewDidLoad 尚未跑完:先记下,稍后由 viewDidLoad 应用
        self.pendingCompact = compact;
        self.hasPendingCompact = YES;
        return;
    }
    NSLog(@"[SWIFT-BAR][MENU] layout=%@ 菜单=SwiftUI TabView items=%lu",
          compact ? @"PORTRAIT" : @"LANDSCAPE",
          (unsigned long)self.menuItems.count);
}

/// ★ [SYS-TABBAR] 旧接口兼容:系统标签栏不需要"贴合内容宽度"
/// (它是通条,宽度由容器的 leading/trailing 约束决定)⇒ 返回 0,让
/// LauncherRootViewController 走它的兜底宽度(那条宽度约束本就定不了宽度)。
- (CGFloat)preferredTopBarWidth {
    return 0.0;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor clearColor];

    // 适配自定义启动器背景：将当前视图控制器透明化，让全局背景（图片/视频）能够透出显示。
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    // ★ [SYS-TABBAR] 关键:BackgroundManager 在"半透明"模式下会给 view 铺一层带 alpha 的
    //   systemBackgroundColor。工具条现在只承载系统 UITabBar(玻璃要能透出壁纸),
    //   后面垫一块"假底"会让玻璃看起来又像自绘的 ⇒ 这里强制透明。
    self.view.backgroundColor = [UIColor clearColor];

    // 监听背景 UI 效果变化通知：切换毛玻璃/半透明或调整透明度时重新透明化。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    // ★ [SYS-TABBAR] 保留"用户自定义文字色"(general.text_color)能力:
    //   只改 unselectedItemTintColor(未选中项着色),不碰 UITabBarAppearance/背景
    //   ⇒ 系统液态玻璃不受影响;选中色仍用系统强调色。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyCustomAppearance)
                                                 name:@"LauncherAppearanceChanged"
                                               object:nil];

    // ★ [SYS-TABBAR] 菜单项配置(★ [TABC] 5 项:已按用户指示删掉「多人游戏」)。
    //   icon = SF Symbol;tab = 标签栏短名(标签栏横向空间有限,统一两字/AI);
    //   portrait / landscape 仅保留给 onMenuItemSelected 回调用。
    self.menuItems = @[
        @{@"icon": @"house.fill",             @"tab": @"主页", @"portrait": @"主页", @"landscape": @"主页",     @"index": @0},
        @{@"icon": @"arrow.down.circle.fill", @"tab": @"下载", @"portrait": @"下载", @"landscape": @"下载中心", @"index": @1},
        @{@"icon": @"sparkles",               @"tab": @"AI",   @"portrait": @"AI",   @"landscape": @"AI",       @"index": @2},
        @{@"icon": @"square.stack.3d.up.fill",@"tab": @"实例", @"portrait": @"实例", @"landscape": @"实例",     @"index": @3},
        @{@"icon": @"gearshape.fill",         @"tab": @"设置", @"portrait": @"设置", @"landscape": @"设置",     @"index": @4}
    ];

    self.selectedIndex = 0;

    // ★ [ROOTTAB] 底栏 = 根 UITabBarController 的**真页面**标签(下载/AI/实例/设置各自是 VC),
    //   切换由 UIKit 完成 ⇒ 这里【不再】监听 AmeTabTapped 去弹旧页面(否则会重叠弹两次)。
    //   LauncherMenuViewController 只保留 setCompactHorizontalLayout: 等既有职责。
    [self applyCustomAppearance];  // ★ [SWIFT-BAR] 应用用户自定义未选中文字色(tint,不动玻璃)
    // ★ [SWIFT-BAR] 图标竞态自愈已随底栏迁到 AmeTabBar.swift(宿主 viewDidAppear 里的有界重试)

    // 父 VC 若在 viewDidLoad 之前就调过 setCompactHorizontalLayout:,这里补记状态
    if (self.hasPendingCompact) {
        self.hasPendingCompact = NO;
        self.compactLayout = self.pendingCompact;
    }
}

/// ★ [ROOTTAB] 根标签栏被点:转给既有的 handleMenuSelection:(导航语义一个字不变)。
- (void)handleRootTabTapped:(NSNotification *)note {
    NSNumber *n = note.userInfo[@"index"];
    if (![n isKindOfClass:[NSNumber class]]) return;
    NSInteger idx = n.integerValue;
    NSLog(@"[ROOTTAB] MenuVC 收到 index=%ld ⇒ handleMenuSelection:", (long)idx);
    // ★ [ROOTTAB-FIX] 主页(idx=0)也必须走一遍:用户报「从主页跳出后无法通过底栏切回主页」。
    [self handleMenuSelection:idx];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // ★ [SYS-TABBAR] 布置后自证:尺寸变化(含转屏)才打一行,便于装机核对。
    CGSize s = self.view.bounds.size;
    if (fabs(s.width  - self.ameLastRotLoggedSize.width)  > 0.5 ||
        fabs(s.height - self.ameLastRotLoggedSize.height) > 0.5) {
        self.ameLastRotLoggedSize = s;
        NSLog(@"[SWIFT-BAR][ROT] menubar size=%.0fx%.0f hostH=%.0f items=%lu",
              s.width, s.height, self.swiftTabBarHost.view.bounds.size.height,
              (unsigned long)self.menuItems.count);
    }
}

#pragma mark - ★ [SWIFT-BAR] SwiftUI TabView 宿主安装

/// ★ [SWIFT-BAR] 安装 SwiftUI 标签栏宿主(AmeTabBar.swift 的 AmeBar / AmeTabBarHost)。
/// 为什么最终换成 SwiftUI:
///   ① 裸 UITabBar(游离)在 iOS 26 上【没有文字】;
///   ② 真 UITabBarController 把中文标题摆在图标【右边】(inline),UITabBarAppearance
///      设成 stacked 也拉不回竖排;容器 68→92 同样无效(截图 md5 完全相同);
///   ③ LiveContainer 的底栏(LCTabView.swift)就是一句 TabView + .tabItem{ Label } ——
///      只有这个版本能同时拿到【图标在上/中文在下】+【系统液态玻璃】。
/// 本方法只做三件事:建宿主子 VC → 四边铺满本 VC 的 view(容器在屏幕底部,竖屏由
/// LauncherRootViewController 钉在底部)→ 注册 AmeTabSelected 通知转发。
/// 外观(玻璃/圆角/版式)一个字节都不自绘。
- (void)setupSwiftTabBar {
    // ★ [SWIFT-BAR] tag = 初始选中下标(0 = 实例,与 menuItems 顺序一致)
    UIViewController *bar = [AmeTabBarHost makeHostWithTag:0];
    if (!bar) {
        NSLog(@"[SWIFT-BAR] AmeTabBarHost 返回 nil,底部标签栏缺失");
        return;
    }
    bar.view.translatesAutoresizingMaskIntoConstraints = NO;
    bar.view.backgroundColor = [UIColor clearColor];   // ★ 别挡壁纸(玻璃要透出底图)

    [self addChildViewController:bar];
    [self.view addSubview:bar.view];
    [NSLayoutConstraint activateConstraints:@[
        [bar.view.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [bar.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bar.view.topAnchor      constraintEqualToAnchor:self.view.topAnchor],
        [bar.view.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    [bar didMoveToParentViewController:self];
    self.swiftTabBarHost = bar;

    // ★ [SWIFT-BAR] 选中广播:Swift 侧 postNotificationName:@"AmeTabSelected"
    //   userInfo = @{@"index": @(v)} ⇒ 在这里转成既有的 handleMenuSelection:(导航语义不变)。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ameTabSelected:)
                                                 name:@"AmeTabSelected"
                                               object:nil];

    NSLog(@"[SWIFT-BAR] 已安装 SwiftUI TabView 宿主 items=%lu titles=%@",
          (unsigned long)self.menuItems.count, [self.menuItems valueForKey:@"tab"]);
}

/// ★ [SWIFT-BAR] SwiftUI 底栏选中回调(替代原 tabBarController:didSelectViewController:)。
/// 语义与旧实现逐条相同:记录 index → onMenuItemSelected 回调 → handleMenuSelection: 导航。
/// 越界直接 return(通知里的下标本应恒在 0…menuItems.count-1)。
- (void)ameTabSelected:(NSNotification *)note {
    NSNumber *indexNumber = note.userInfo[@"index"];
    if (![indexNumber isKindOfClass:[NSNumber class]]) return;
    NSInteger index = indexNumber.integerValue;
    if (index < 0 || index >= (NSInteger)self.menuItems.count) return;

    self.selectedIndex = index;

    NSString *title = [self sysTabBarTitleForItem:self.menuItems[index]];
    NSLog(@"[SWIFT-BAR] 选中 %ld (%@)", (long)index, title);

    if (self.onMenuItemSelected) {
        self.onMenuItemSelected(index, title ?: @"");
    }

    [self handleMenuSelection:index];
}

/// 标签标题:优先 "tab" 短名,退回 portrait / landscape。
- (NSString *)sysTabBarTitleForItem:(NSDictionary *)item {
    NSString *t = item[@"tab"];
    if (t.length > 0) return t;
    t = item[@"portrait"];
    if (t.length > 0) return t;
    return item[@"landscape"] ?: @"";
}


#pragma mark - Navigation

/// ★ [TABC] 导航映射(沿用既有通知名,不改父控制器行为)。
/// ★ 用户指示删掉「多人游戏」⇒ 原 index 5(设置)前移为 4,此后没有 index 5。
///   0 实例 → ShowHomePage(主页/实例页)
///   1 下载 → ShowDownloadPage
///   2 AI   → 直接 present AI 会话列表
///   3 资源 → ShowVersionManager(资源/版本管理,沿用原 index 3 语义)
///   4 设置 → ShowSettings
- (void)handleMenuSelection:(NSInteger)index {
    switch (index) {
        case 0: // 实例 / 主页
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowHomePage" object:nil];
            break;

        case 1: // 下载 / 下载中心
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowDownloadPage" object:nil];
            break;

        case 2: // AI 入口
            [self showAI];
            break;

        case 3: // 资源 / 资源管理(版本管理,合并了原"当前版本设置"功能)
            [self showVersionManager];
            break;

        case 4: // 设置
            [self showSettings];
            break;

        // ★ [SWIFT-BAR] 原 case 4(多人游戏)已删除:该入口不再出现在标签栏上
    }
}

- (void)showAI {
    // 直接 present AI 会话列表(自包含,不依赖 RootVC 的通知处理器)
    Class cls = NSClassFromString(@"AISessionListViewController");
    if (!cls) { NSLog(@"[SYS-TABBAR][MENU] AISessionListViewController 不存在,AI 入口无动作"); return; }
    UIViewController *vc = [[cls alloc] init];
    if (!vc) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    UIViewController *host = self.view.window.rootViewController ?: self;
    [host presentViewController:nav animated:YES completion:nil];
}

- (void)showVersionManager {
    // 发送通知让 LauncherRootViewController 在中间内容区显示
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowVersionManager" object:nil];
}

/// ★ [TABC] 入口已下线(用户:多人游戏"还在维护、没有实际入口"),方法保留备查 ——
/// 若哪天要回归:在 menuItems 末尾补一项 + 在 handleMenuSelection: 补一个 case 即可。
- (void)showMultiplayer {
    // 发送通知让 LauncherRootViewController 显示陶瓦联机界面
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowMultiplayer" object:nil];
}

- (void)showZeroTier {
    // 发送通知让 LauncherRootViewController 显示 ZeroTier 联机界面
    // ZeroTier 与陶瓦联机为并列的两套联机方案，独立菜单入口避免用户先进入陶瓦再切换。
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowZeroTier" object:nil];
}

- (void)showSettings {
    // 发送通知让 LauncherRootViewController 在中间内容区显示
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowSettings" object:nil];
}

#pragma mark - Data Updates

- (void)updateAccountInfo {
    // 账户信息在右侧面板显示，这里不需要处理
}

#pragma mark - ★ [SYS-TABBAR] 外观(仅未选中项着色,不碰系统玻璃)

/// ★ [SYS-TABBAR] 应用"用户自定义文字色"(设置页 general.text_color)。
/// 只写 unselectedItemTintColor:
///   - 保留原有自定义能力(改造前未选中项用该色);
///   - 不设置 UITabBarAppearance / backgroundEffect / tintColor ⇒ 选中色仍是系统
///     强调色、液态玻璃仍是系统默认外观(用户诉求:"直接换成系统的")。
/// 未设置时传 nil ⇒ 回到系统默认(secondaryLabel)。
/// ★ [SWIFT-BAR] 作用对象换成 Swift 宿主里的原生 tabBar(只改 tint,语义与效果不变)。
- (void)applyCustomAppearance {
    // ★ [SWIFT-BAR] 交给 Swift 宿主:只改未选中项 tint,不碰 UITabBarAppearance/玻璃。
    //   宿主还没建也能调用(setUnselectedTintColor: 会暂存颜色,建宿主时自动应用)。
    [AmeTabBarHost setUnselectedTintColor:[self customTextColor]];   // nil = 系统默认
}

/// 用户自定义文字色(设置页 general.text_color);未设置返回 nil。
- (UIColor *)customTextColor {
    NSString *hex = getPrefObject(@"general.text_color");
    if (hex.length > 0) return [self colorFromHexString:hex];
    return nil;
}

- (UIColor *)colorFromHexString:(NSString *)hexString {
    NSString *hex = [hexString stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (hex.length != 6 && hex.length != 8) return nil;
    unsigned int r = 0, g = 0, b = 0, a = 255;
    if (hex.length == 6) {
        unsigned int v = 0;
        if (![[NSScanner scannerWithString:hex] scanHexInt:&v]) return nil;
        r = (v >> 16) & 0xFF; g = (v >> 8) & 0xFF; b = v & 0xFF;
    } else {
        unsigned int v = 0;
        if (![[NSScanner scannerWithString:hex] scanHexInt:&v]) return nil;
        r = (v >> 24) & 0xFF; g = (v >> 16) & 0xFF; b = (v >> 8) & 0xFF; a = v & 0xFF;
    }
    return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a/255.0];
}

#pragma mark - Background

/// 重新应用背景效果：BackgroundUIEffectChanged 通知到达时调用。
/// ★ [SYS-TABBAR] 同 viewDidLoad:工具条只承载系统玻璃,必须保持完全透明。
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.view.backgroundColor = [UIColor clearColor];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];   // ★ [SWIFT-BAR] 含 AmeTabSelected
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

/// ★ [PORTRAIT] 放开方向:原来写死 Landscape ⇒ 竖屏根本进不去。
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        return UIInterfaceOrientationMaskAll;
    }
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

#pragma mark - ★ [SWIFT-BAR] 标签图标自愈

// 图标竞态自愈(CoreUI 冷启首调用可能拿到 nil)已随底栏一起迁到 AmeTabBar.swift:
// AmeTabBarHostController.viewDidAppear 先补一次,再走 0.25s × 40 的有界重试,
// 只补 image == nil 的项(不覆盖系统已渲染好的图标)。本文件不再持有计时器。

@end
