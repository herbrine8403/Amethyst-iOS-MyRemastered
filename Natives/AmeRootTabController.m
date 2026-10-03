//
//  AmeRootTabController.m
//  ★ [ROOTTAB] 见头文件注释。
//
//  ★ 第 3 版(正经结构,和音乐 / LiveContainer / SideStore 同构):
//    根 = UITabBarController,5 个标签【各自是真页面】,统统交给 UIKit:
//      · 触摸:UIKit 自己管(不再手工塞视图、不再关交互 —— 上一版的坑)
//      · 生命周期:真子控制器 ⇒ viewWillAppear 等回调正常(修「JIT 一直检测中」)
//      · 横竖屏 / 安全区:UIKit 自己算
//    第 2 版把主页当"底衬"手工塞 subview ⇒ 触摸被容器吞、生命周期不走、JIT 不刷新,
//    用户实测一次性报了三个 bug —— 那条路已废弃。
//
#import "AmeRootTabController.h"
#import "DownloadViewController.h"
#import "VersionManagerViewController.h"
#import "LauncherPreferencesViewController.h"
#import "AI/AISessionListViewController.h"

NSString * const AmeTabTappedNotification = @"AmeTabTapped";   // ★ [ROOTTAB]

@interface AmeRootTabController () <UITabBarControllerDelegate>   // ★ 声明协议,消掉 delegate 赋值警告
@end

#pragma mark - ★ [TAB-OVERLAP] 零时长标签过渡(保证任一时刻只有一个页面视图)

/// ★ [TAB-OVERLAP] 让 UIKit 的标签切换【瞬时完成】,不做交叉淡入淡出。
/// 背景:系统默认的标签过渡是“容器快照淡入淡出”——过渡期间 from 页与 to 页同时存在。
/// 用户“连续快速点不同底栏按钮”时,前一次的过渡还没收尾、后一次已经叠上,
/// 于是两屏快照同时留在容器里 ⇒ 看到的就是“画面重叠 / 残影”。
/// 这里返回一个 0 时长的过渡器:旧页立刻移除、新页立刻挂上、随即 completeTransition,
/// 结构上任何时刻只有一个页面视图 ⇒ 连点也不可能重叠。
/// 只用公开 API;不动选中态、不动页面生命周期、不禁点。
@interface AmeTabInstantAnimator : NSObject <UIViewControllerAnimatedTransitioning>
@end

@implementation AmeTabInstantAnimator

- (NSTimeInterval)transitionDuration:(nullable id<UIViewControllerContextTransitioning>)transitionContext {
    return 0.0;
}

- (void)animateTransition:(id<UIViewControllerContextTransitioning>)transitionContext {
    UIView *container = transitionContext.containerView;
    UIViewController *fromVC = [transitionContext viewControllerForKey:UITransitionContextFromViewControllerKey];
    UIViewController *toVC   = [transitionContext viewControllerForKey:UITransitionContextToViewControllerKey];

    UIView *toView   = [transitionContext viewForKey:UITransitionContextToViewKey]   ?: (toVC ? toVC.view : nil);
    UIView *fromView = [transitionContext viewForKey:UITransitionContextFromViewKey] ?: (fromVC ? fromVC.view : nil);

    if (toView) {
        toView.frame = [transitionContext finalFrameForViewController:toVC];
        toView.alpha = 1.0;
        [container addSubview:toView];
    }
    if (fromView && fromView.superview == container) {
        [fromView removeFromSuperview];    // ★ 关键:旧页立刻撤,不留快照 ⇒ 不可能重叠
    }
    // 标签栏本身也是容器的兄弟视图:新页加到最上层后把它抬回来,别被内容盖住。
    for (UIView *sv in container.subviews) {
        if ([sv isKindOfClass:[UITabBar class]]) {
            [container bringSubviewToFront:sv];
        }
    }
    [transitionContext completeTransition:YES];
}

@end

@implementation AmeRootTabController

/// 页面统一包进导航控制器:页面里若自己 push/present 也能正常工作
static UIViewController *AmeWrapInNav(UIViewController *vc) {
    if (!vc) return [[UIViewController alloc] init];
    if ([vc isKindOfClass:[UINavigationController class]]) return vc;
    return [[UINavigationController alloc] initWithRootViewController:vc];
}

+ (instancetype)tabControllerWithHomeViewController:(UIViewController *)home {
    AmeRootTabController *tbc = [[AmeRootTabController alloc] init];

    // ★ [ROOTTAB] 5 项:主页 · 下载 · AI · 实例 · 设置(★ 已按用户指示删掉「多人游戏」)
    NSArray<NSDictionary *> *items = @[
        @{@"t": @"主页", @"i": @"house.fill"},
        @{@"t": @"下载", @"i": @"arrow.down.circle.fill"},
        @{@"t": @"AI",   @"i": @"sparkles"},
        @{@"t": @"实例", @"i": @"square.stack.3d.up.fill"},
        @{@"t": @"设置", @"i": @"gearshape.fill"},
    ];

    NSMutableArray<UIViewController *> *vcs = [NSMutableArray arrayWithCapacity:items.count];
    for (NSInteger i = 0; i < (NSInteger)items.count; i++) {
        UIViewController *content = nil;
        switch (i) {
            case 0: content = home ?: [[UIViewController alloc] init]; break;   // 主页 = 启动器现有全部界面
            // ★ [ROOTTAB-FIX] 下载 = 【下载实例】(DownloadViewController:版本/模组/光影/资源包…七标签),
            //   ★ 不包导航控制器 —— 包了会多一条导航栏,把内容整体压低(用户报"下载实例界面还是有点低")。
            case 1: content = [[DownloadViewController alloc] init]; break;
            case 2: content = [[AISessionListViewController alloc] init]; break;
            case 3: content = [[VersionManagerViewController alloc] init]; break;
            case 4: content = [[LauncherPreferencesViewController alloc] init]; break;
            default: content = [[UIViewController alloc] init]; break;
        }

        // ★ [ROOTTAB-FIX] tabBarItem 必须设在【内容 VC】上:导航控制器会用它 push 栈顶页面的
        //   item 覆盖自己那个 —— 上一版设在 nav 上 ⇒ 第 3 个标签显示成了"会话列表"。
        content.tabBarItem = [[UITabBarItem alloc] initWithTitle:items[i][@"t"]
                                                          image:[UIImage systemImageNamed:items[i][@"i"]]
                                                  selectedImage:nil];
        content.tabBarItem.tag = i;

        UIViewController *vc = AmeWrapInNav(content);   // ★ 全部包 nav:页面内要 push 子流程(见 RootVC:719 注释)
        [vcs addObject:vc];
    }
    tbc.viewControllers = vcs;
    tbc.selectedIndex = 0;
    tbc.delegate = tbc;

    // ★ 不设 UITabBarAppearance:设了就盖掉 iOS 26 系统玻璃
    return tbc;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // 标签控制器自己的 view 透明(否则会盖出一片黑);壁纸由 window 与各页面负责
    self.view.backgroundColor = [UIColor clearColor];
}

#pragma mark - UITabBarControllerDelegate

- (void)tabBarController:(UITabBarController *)tabBarController
 didSelectViewController:(UIViewController *)viewController {
    NSInteger idx = [tabBarController.viewControllers indexOfObject:viewController];
    if (idx == NSNotFound) return;
    NSLog(@"[ROOTTAB] tap index=%ld", (long)idx);
    // 广播给关心导航的老代码(LauncherMenuViewController 等);页面本身由 UIKit 负责切
    [[NSNotificationCenter defaultCenter] postNotificationName:AmeTabTappedNotification
                                                       object:nil
                                                     userInfo:@{@"index": @(idx)}];
}

#pragma mark - ★ [TAB-OVERLAP] 底栏切换过渡

/// ★ [TAB-OVERLAP] 标签切换用 0 时长过渡(见 AmeTabInstantAnimator):
/// 连点底栏不同按钮时不再有“上一张快照未撤、下一张已上”的窗口 ⇒ 不重叠。
- (id<UIViewControllerAnimatedTransitioning>)tabBarController:(UITabBarController *)tabBarController
        animationControllerForTransitionFromViewController:(UIViewController *)fromViewController
                                          toViewController:(UIViewController *)toViewController {
    return [[AmeTabInstantAnimator alloc] init];
}

@end
