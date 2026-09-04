#import "SceneDelegate.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "LauncherRootViewController.h"
#import "LauncherCardLayoutViewController.h"
#import "LauncherPreferences.h"
#import "BackgroundManager.h"
#import "PLUIShellViewController.h"
// Terracotta 暂时移除（排查启动崩溃）
// #import "TerracottaManager.h"
// #import "TerracottaBridge.h"

extern UIWindow *mainWindow;

@interface SceneDelegate ()
@end

@implementation SceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    
    // 强制横屏 (iOS 16+)
    if (@available(iOS 16.0, *)) {
        UIWindowSceneGeometryPreferencesIOS *geometryPreferences = [[UIWindowSceneGeometryPreferencesIOS alloc] init];
        geometryPreferences.interfaceOrientations = UIInterfaceOrientationMaskLandscape;
        [windowScene requestGeometryUpdateWithPreferences:geometryPreferences errorHandler:^(NSError *error) {
            NSLog(@"[SceneDelegate] Failed to update geometry: %@", error);
        }];
    }
    
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    self.window.frame = windowScene.coordinateSpace.bounds;
    // 修复：使用 systemBackgroundColor 自适应浅色/深色模式。
    // 之前硬编码深灰（0.08）在浅色模式下导致"中间一片黑"。
    // systemBackgroundColor 在浅色模式为白、深色模式为黑，自动适配。
    // BackgroundManager.applyBackgroundToWindow 会根据用户是否设置自定义壁纸覆盖此颜色。
    if (@available(iOS 13.0, *)) {
        self.window.backgroundColor = [UIColor systemBackgroundColor];
    } else {
        self.window.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    }
    mainWindow = self.window;

    [self installRootViewController];

    // 监听 UI 壳切换（设置页 general.ui_shell 变更时实时换壳，无需重启）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(uiShellChanged:)
                                                 name:@"UIShellChanged"
                                               object:nil];

    // 外观模式（浅色/深色/跟随系统）：读 general.ui_theme 偏好。
    //   light  -> UIUserInterfaceStyleLight
    //   dark   -> UIUserInterfaceStyleDark（默认，保持与原行为一致）
    //   auto   -> UIUserInterfaceStyleUnspecified（跟随系统）
    // iOS 13+ 支持 overrideUserInterfaceStyle。仅设置 window 级别，不触碰账号/偏好。
    if (@available(iOS 13.0, *)) {
        NSString *theme = getPrefObject(@"general.ui_theme");
        if ([theme isEqualToString:@"light"]) {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
        } else if ([theme isEqualToString:@"auto"]) {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
        } else {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        }
    }

    [self.window makeKeyAndVisible];

    // 立即应用背景（移除原来的 0.1s 延迟）：
    // 延迟会在启动时露出窗口底色形成"黑条"或"黑闪"。BackgroundManager 在其 init
    // 中已 loadSavedBackground/loadUISettings，单例首次访问即完成初始化，无需延迟。
    [[BackgroundManager sharedManager] applyBackgroundToWindow:self.window];

    [self showTranslationNoticeIfNeeded];

    // Terracotta 暂时移除（排查启动崩溃）
    // if ([TerracottaBridge isAvailable]) {
    //     TerracottaManager *mgr = [TerracottaManager shared];
    //     NSLog(@"[SceneDelegate] Terracotta manager initialized: %d", mgr.initialized);
    // } else {
    //     NSLog(@"[SceneDelegate] libterracotta not linked, multiplayer disabled");
    // }
    NSLog(@"[SceneDelegate] Terracotta temporarily disabled for crash investigation");

    // 监听主题切换通知（设置页"外观模式"切换时实时应用，无需重启）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyUITheme:)
                                                 name:@"UIThemeChanged"
                                               object:nil];
}

#pragma mark - Root VC 安装（ui_shell 双轨开关）

/// 根据 general.ui_shell 偏好安装根控制器：
/// - legacy（默认）：旧壳（general.ui_layout 继续决定 vs / card 布局）
/// - engine：PLUIShellViewController（Lua 材质包引擎）
/// 引擎壳构建抛异常时写回 legacy 并换回旧壳，保证坏包/引擎 bug 都不会打不开启动器。
- (void)installRootViewController {
    UIViewController *rootVC = nil;
    if ([getPrefObject(@"general.ui_shell") isEqualToString:@"engine"]) {
        @try {
            rootVC = [[PLUIShellViewController alloc] init];
        } @catch (NSException *exception) {
            NSLog(@"[SceneDelegate] engine shell failed (%@: %@), falling back to legacy",
                  exception.name, exception.reason);
            setPrefObject(@"general.ui_shell", @"legacy");
            rootVC = nil;
        }
    }
    if (!rootVC) {
        // 旧壳：默认 VS 三栏布局，可切换为卡片式便当盒布局
        NSString *layout = getPrefObject(@"general.ui_layout");
        if ([layout isEqualToString:@"card"]) {
            rootVC = [[LauncherCardLayoutViewController alloc] init];
        } else {
            rootVC = [[LauncherRootViewController alloc] init];
        }
    }
    self.window.rootViewController = rootVC;
    [[BackgroundManager sharedManager] applyBackgroundToWindow:self.window];
}

- (void)uiShellChanged:(NSNotification *)notification {
    [self installRootViewController];
}

- (void)showTranslationNoticeIfNeeded {
    // 仅当系统语言为英文时提示：部分内容为机翻，可能不够准确，欢迎提交翻译 PR。
    // 用户选择"不再提醒"后通过偏好持久化，下次不再弹出。
    if (![NSLocale.preferredLanguages.firstObject hasPrefix:@"en"]) {
        return;
    }
    if (getPrefBool(@"general.translation_notice_dismissed")) {
        return;
    }

    UIViewController *presenter = self.window.rootViewController;
    if (presenter == nil) {
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_2000", nil)
                                                                   message:localize(@"i18n_str_2001", nil)
                                                            preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *gotItAction = [UIAlertAction actionWithTitle:localize(@"i18n_str_2002", nil)
                                                          style:UIAlertActionStyleDefault
                                                        handler:nil];
    [alert addAction:gotItAction];

    UIAlertAction *dontAskAction = [UIAlertAction actionWithTitle:localize(@"i18n_str_2003", nil)
                                                            style:UIAlertActionStyleCancel
                                                          handler:^(UIAlertAction *action) {
        setPrefBool(@"general.translation_notice_dismissed", YES);
    }];
    [alert addAction:dontAskAction];

    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)applyUITheme:(NSNotification *)notification {
    // 实时切换外观模式。仅修改 window.overrideUserInterfaceStyle，
    // 不触碰 PLPreferences 重置逻辑、不读写账号数据，确保切换主题不会导致账号退出。
    NSString *theme = notification.object ?: getPrefObject(@"general.ui_theme");
    if (@available(iOS 13.0, *)) {
        if ([theme isEqualToString:@"light"]) {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
        } else if ([theme isEqualToString:@"auto"]) {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
        } else {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        }
    }
}

- (void)sceneDidDisconnect:(UIScene *)scene {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"UIThemeChanged" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"UIShellChanged" object:nil];
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
}

- (void)sceneWillResignActive:(UIScene *)scene {
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
    CallbackBridge_pauseGameIfNeed();
}

#pragma mark - Orientation Support (iOS 16+)

- (UIInterfaceOrientationMask)scene:(UIScene *)scene supportedInterfaceOrientationsForWindowScene:(UIWindowScene *)windowScene API_AVAILABLE(ios(16.0)) {
    return UIInterfaceOrientationMaskLandscape;
}

@end
