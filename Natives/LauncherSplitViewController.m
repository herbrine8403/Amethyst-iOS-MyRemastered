#import "LauncherSplitViewController.h"
#import "LauncherMenuViewController.h"
#import "LauncherNewsViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "utils.h"
#import "BackgroundManager.h"

extern NSMutableDictionary *prefDict;

@interface LauncherSplitViewController ()<UISplitViewControllerDelegate>
@end

@implementation LauncherSplitViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    // Set background color based on whether custom background exists
    if ([[BackgroundManager sharedManager] hasBackground]) {
        self.view.backgroundColor = [UIColor clearColor];
    } else {
        if (@available(iOS 13.0, *)) {
            self.view.backgroundColor = [UIColor systemBackgroundColor];
        } else {
            self.view.backgroundColor = [UIColor blackColor];
        }
    }

    if ([getPrefObject(@"control.control_safe_area") length] == 0) {
        setPrefObject(@"control.control_safe_area", NSStringFromUIEdgeInsets(getDefaultSafeArea()));
    }

    self.delegate = self;

    // FCL Style: MenuViewController as master, NavigationController as detail
    UINavigationController *masterVc = [[UINavigationController alloc] initWithRootViewController:[[LauncherMenuViewController alloc] init]];
    LauncherNavigationController *detailVc = [[LauncherNavigationController alloc] initWithRootViewController:[[LauncherNewsViewController alloc] init]];
    detailVc.toolbarHidden = NO;

    self.viewControllers = @[masterVc, detailVc];

    // FCL Style: Fixed sidebar width
    self.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
    self.preferredSplitBehavior = UISplitViewControllerSplitBehaviorTile;
    self.minimumPrimaryColumnWidth = 70;  // Sidebar width
    self.maximumPrimaryColumnWidth = 70;

    // primaryColumnWidth is only writable on iOS 16+
    // Use performSelector to avoid compiler readonly check on iOS < 16
    if (@available(iOS 16.0, *)) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        SEL setPrimaryColumnWidthSel = NSSelectorFromString(@"setPrimaryColumnWidth:");
        if ([self respondsToSelector:setPrimaryColumnWidthSel]) {
            [self performSelector:setPrimaryColumnWidthSel withObject:@(70)];
        }
#pragma clang diagnostic pop
    }

    // Apply global background (now also handles default background)
    [[BackgroundManager sharedManager] applyBackgroundToSplitViewController:self];

    // Listen for background change notifications
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(backgroundChanged:)
                                                 name:@"BackgroundChanged"
                                               object:nil];

    // Listen for UI effect change notifications
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(uiEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    // Listen for navigation changes to ensure transparency
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(navigationControllerDidShow:)
                                                 name:@"UINavigationControllerDidShowViewControllerNotification"
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)navigationControllerDidShow:(NSNotification *)notification {
    // Ensure transparency is maintained when navigating (only for custom backgrounds)
    if ([[BackgroundManager sharedManager] hasBackground]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[BackgroundManager sharedManager] makeSplitViewControllerTransparent:self];
        });
    }
}

- (void)applyBackground {
    [[BackgroundManager sharedManager] applyBackgroundToSplitViewController:self];
}

- (void)backgroundChanged:(NSNotification *)notification {
    // Reapply background when changed
    [[BackgroundManager sharedManager] applyBackgroundToSplitViewController:self];
    
    // Update view background color based on current state
    if ([[BackgroundManager sharedManager] hasBackground]) {
        self.view.backgroundColor = [UIColor clearColor];
    } else {
        if (@available(iOS 13.0, *)) {
            self.view.backgroundColor = [UIColor systemBackgroundColor];
        } else {
            self.view.backgroundColor = [UIColor blackColor];
        }
    }
}

- (void)uiEffectChanged:(NSNotification *)notification {
    // Refresh UI effect when settings changed
    [[BackgroundManager sharedManager] refreshUIEffect];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    // Resume video background
    [[BackgroundManager sharedManager] resumeVideo];

    // Ensure transparency only for custom backgrounds
    if ([[BackgroundManager sharedManager] hasBackground]) {
        [[BackgroundManager sharedManager] makeSplitViewControllerTransparent:self];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Pause video to save resources
    [[BackgroundManager sharedManager] pauseVideo];
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];

    // FCL Style: Always landscape, fixed sidebar
    self.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;

    // Update background frame on rotation
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        [[BackgroundManager sharedManager] updateBackgroundFrame];
    } completion:nil];
}

- (void)splitViewController:(UISplitViewController *)svc willChangeToDisplayMode:(UISplitViewControllerDisplayMode)displayMode {
    // Keep FCL style layout
    if (displayMode != UISplitViewControllerDisplayModeOneBesideSecondary) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
        });
    }
}

- (void)dismissViewController {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Orientation Support

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

@end
