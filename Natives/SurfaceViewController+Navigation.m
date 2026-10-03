#import "CustomControlsViewController.h"
#import "LauncherPreferences.h"
#import "LauncherPreferencesViewController.h"
#import "PLProfiles.h"
#import "SurfaceViewController.h"
#import "GameMenuOverlayView.h"
#import "TrackedTextField.h"
#import "utils.h"
#import "ScreenUtils.h"
// ZeroTier/Terracotta 联机暂时移除（排查启动崩溃）
// #import "MultiplayerViewController.h"
// #import "MultiplayerManager.h"
// #import "TerracottaViewController.h"
#import <objc/runtime.h>

// 暴露 class extension 中的私有属性，供 category 使用
@interface SurfaceViewController()
@property(nonatomic) TrackedTextField *inputTextField;
@property(nonatomic) BOOL toggleHidden;
- (void)updateControlHiddenState:(BOOL)hide;
@end

// category 不能存储 ivar，用 associated object 实现 menuDimView
static const void *kMenuDimViewKey = &kMenuDimViewKey;

@interface SurfaceViewController(Navigation)
// FCL 风格菜单的背景遮罩（半透明黑色，点击关闭菜单）
@property(nonatomic) UIView *menuDimView;
@end

@implementation SurfaceViewController(Navigation)

- (void)setMenuDimView:(UIView *)menuDimView {
    objc_setAssociatedObject(self, kMenuDimViewKey, menuDimView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (UIView *)menuDimView {
    return objc_getAssociatedObject(self, kMenuDimViewKey);
}

- (void)initCategory_Navigation {
    // FCL 安卓风格：菜单从底部弹出，游戏画面不缩小
    // 参照 FCL GameMenu.java / GameMenuView.kt 的底部弹出菜单样式
    self.menuArray = @[
        @"game.menu.force_close",          // 强制关闭
        @"game.menu.log_output",            // 日志输出
        @"game.menu.custom_controls",       // 按键布局编辑
        // ★ [FIX-A] 已按用户指示删除「联机 / 多人游戏」菜单项
        //   (用户:多人游戏还在维护、没有实际入口)。原 index 3 = game.menu.multiplayer 菜单项,
        //   已删除 ⇒ 其后各项 index 顺次前移一位(见 didSelectMenuItem:)。只摘 UI 入口,
        //   底层联机能力代码(MultiplayerManager / Terracotta / ZeroTier 等)一行未动。
        @"game.menu.toggle_stats",          // FPS/内存显示开关
        @"game.menu.toggle_controls",       // 隐藏/显示控制按钮
        @"game.menu.toggle_virtual_mouse",  // 虚拟鼠标开关
        @"game.menu.toggle_keyboard",       // 游戏内键盘
        @"game.menu.resolution",            // 分辨率调整
        @"Settings"                         // 设置
    ];

    // FCL 风格：菜单从底部弹出，宽度为屏幕宽度的 70%（居中），最大高度为屏幕高度的 60%
    CGFloat screenWidth = [ScreenUtils screenSize].width;
    CGFloat screenHeight = [ScreenUtils screenSize].height;
    CGFloat menuWidth = MIN(screenWidth * 0.7, 400);
    CGFloat menuMaxHeight = screenHeight * 0.6;
    CGFloat menuEstimatedHeight = self.menuArray.count * 48 + 16;
    CGFloat menuHeight = MIN(menuEstimatedHeight, menuMaxHeight);

    self.menuView = [[UITableView alloc] initWithFrame:CGRectMake(
        (screenWidth - menuWidth) / 2.0,
        screenHeight,  // 初始放在屏幕底部外（动画时上滑）
        menuWidth,
        menuHeight
    ) style:UITableViewStylePlain];

    self.menuView.dataSource = self;
    self.menuView.delegate = self;
    self.menuView.hidden = YES;
    self.menuView.layer.cornerRadius = 16;
    self.menuView.clipsToBounds = YES;
    self.menuView.scrollEnabled = YES;
    self.menuView.separatorInset = UIEdgeInsetsMake(0, 16, 0, 16);
    // FCL 风格：半透明深色背景
    self.menuView.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
        return [UIColor colorWithRed:28.0/255.0 green:28.0/255.0 blue:30.0/255.0 alpha:0.95];
    }];
    // 添加阴影
    self.menuView.layer.shadowColor = [UIColor blackColor].CGColor;
    self.menuView.layer.shadowOffset = CGSizeMake(0, -2);
    self.menuView.layer.shadowRadius = 12;
    self.menuView.layer.shadowOpacity = 0.4;
    [self.view addSubview:self.menuView];

    // FCL 风格：半透明背景遮罩（点击关闭菜单）
    self.menuDimView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.menuDimView.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.4];
    self.menuDimView.alpha = 0;
    self.menuDimView.hidden = YES;
    UITapGestureRecognizer *dimTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissMenu)];
    dimTap.cancelsTouchesInView = YES;
    [self.menuDimView addGestureRecognizer:dimTap];
    [self.view addSubview:self.menuDimView];
    // 确保菜单在遮罩之上
    [self.view bringSubviewToFront:self.menuView];

    // FCL/ZL2 风格悬浮按钮 + FPS/内存显示
    GameMenuOverlayView *overlay = [[GameMenuOverlayView alloc] initWithParentView:self.view];
    __weak typeof(self) weakSelf = self;
    overlay.onMenuButtonTapped = ^{
        [weakSelf toggleMenu];
    };
    self.gameMenuOverlay = overlay;
}

/// 切换菜单显示状态（悬浮按钮点击触发）
- (void)toggleMenu {
    if (self.menuView.hidden) {
        [self showMenu];
    } else {
        [self dismissMenu];
    }
}

/// FCL 风格：从底部弹出菜单（游戏画面不缩小）
- (void)showMenu {
    self.menuView.hidden = NO;
    self.menuDimView.hidden = NO;

    // 准备动画初始状态：菜单在屏幕底部外
    CGFloat screenHeight = [ScreenUtils screenSize].height;
    CGFloat menuHeight = self.menuView.frame.size.height;
    self.menuView.transform = CGAffineTransformIdentity;
    self.menuView.frame = CGRectMake(
        self.menuView.frame.origin.x,
        screenHeight,  // 屏幕底部外
        self.menuView.frame.size.width,
        menuHeight
    );

    // 计算目标位置：底部弹出，留出安全区域
    CGFloat safeBottom = [ScreenUtils safeAreaBottom];
    CGFloat targetY = screenHeight - menuHeight - safeBottom - 16;

    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.85
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        // 菜单上滑到目标位置
        self.menuView.frame = CGRectMake(
            self.menuView.frame.origin.x,
            targetY,
            self.menuView.frame.size.width,
            menuHeight
        );
        // 背景遮罩淡入
        self.menuDimView.alpha = 1.0;
    } completion:^(BOOL finished) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
        [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
        [self setNeedsStatusBarAppearanceUpdate];
    }];
}

/// FCL 风格：菜单下滑消失（游戏画面不缩小）
- (void)dismissMenu {
    CGFloat screenHeight = [ScreenUtils screenSize].height;

    [UIView animateWithDuration:0.25
                          delay:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        // 菜单下滑到屏幕底部外
        self.menuView.frame = CGRectMake(
            self.menuView.frame.origin.x,
            screenHeight,
            self.menuView.frame.size.width,
            self.menuView.frame.size.height
        );
        // 背景遮罩淡出
        self.menuDimView.alpha = 0.0;
    } completion:^(BOOL finished) {
        self.menuView.hidden = YES;
        self.menuDimView.hidden = YES;
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
        [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
        [self setNeedsStatusBarAppearanceUpdate];
    }];
}

- (void)setupCategory_Navigation {
    // FCL 风格：完全删除原来的右侧滑动调出菜单的方式
    // 不再注册 UIScreenEdgePanGestureRecognizer，菜单通过悬浮按钮触发
    // 保留空方法体，因为 SurfaceViewController.m 中通过 performSelector 调用
}

- (void)actionForceClose {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:nil
        message:localize(@"game.menu.confirm.force_close", nil)
        preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:cancelAction];

    UIAlertAction* okAction = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * action) {
        // ZeroTier/Terracotta 联机暂时移除：原 stopAllMultiplayerServices 调用注释掉
        // @try {
        //     [[MultiplayerManager sharedManager] stopAllMultiplayerServices];
        //     NSLog(@"[ForceClose] Multiplayer resources cleaned up");
        // } @catch (NSException *e) {
        //     NSLog(@"[ForceClose] Exception while cleaning up multiplayer resources: %@", e);
        // }

        // FCL 风格：直接退出，不再做缩小动画
        if (fatalExitGroup == nil) {
            exit(0);
        } else {
            dispatch_group_leave(fatalExitGroup);
        }
    }];
    [alert addAction:okAction];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)actionOpenCustomControls {
    [self dismissMenu];
    [self.ctrlView removeAllButtons];
    CustomControlsViewController *vc = [[CustomControlsViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.setDefaultCtrl = ^(NSString *name){
        if (PLProfiles.current.selectedProfile[@"defaultTouchCtrl"]) {
            // Save default to current profile
            PLProfiles.current.selectedProfile[@"defaultTouchCtrl"] = name;
        } else {
            // Save default to preferences
            setPrefObject(@"control.default_ctrl", name);
        }
    };
    vc.getDefaultCtrl = ^{
        return [PLProfiles resolveKeyForCurrentProfile:@"defaultTouchCtrl"];
    };
    [self presentViewController:vc animated:NO completion:nil];
}

- (void)actionOpenPreferences {
    [self dismissMenu];
    LauncherPreferencesViewController *vc = [[LauncherPreferencesViewController alloc] init];
    [self presentViewController:vc animated:YES completion:nil];
}

/// 游戏内打开联机界面（陶瓦联机，与 HMCL/FCL/ZL2 互通）
///
/// 对标 FCL 流程：启动游戏后通过悬浮球菜单进入联机界面，
/// 选择当房主（创建世界→开放局域网→输入端口→生成邀请码）
/// 或当房客（输入邀请码→加入网络→MC 多人游戏直连 127.0.0.1:25565）。
///
/// ★ [FIX-A] 入口已下线(用户指示:多人游戏"还在维护、没有实际入口"):menuArray 里那条
///   「联机」已删除 ⇒ 本方法不再被 didSelectMenuItem: 调用,保留备查(与 LauncherMenuViewController
///   的 showMultiplayer / showZeroTier 同一处理口径)。底层联机能力代码一行未动。
- (void)actionOpenMultiplayer {
    // ZeroTier/Terracotta 联机暂时移除（排查启动崩溃）
    [self dismissMenu];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"i18n_str_320", nil)
                          message:localize(@"i18n_str_321", nil)
                   preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_322", nil) style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// FCL 风格：隐藏/显示控制按钮（对应 FCL hide_all 开关）
- (void)actionToggleControls {
    self.toggleHidden = !self.toggleHidden;
    [self updateControlHiddenState:self.toggleHidden];
}

/// FCL 风格：切换虚拟鼠标（对应 FCL 鼠标分组 / ZL2 ControlMouse）
- (void)actionToggleVirtualMouse {
    if (!isGrabbing) {
        virtualMouseEnabled = !virtualMouseEnabled;
        self.mousePointerView.hidden = !virtualMouseEnabled;
        setPrefBool(@"control.virtmouse_enable", virtualMouseEnabled);
        [self setNeedsUpdateOfPrefersPointerLocked];
    }
}

/// FCL 风格：打开/关闭游戏内键盘（对应 FCL open_quick_input / ZL2 input_method）
- (void)actionToggleKeyboard {
    if (self.inputTextField.isFirstResponder) {
        [self.inputTextField resignFirstResponder];
        self.inputTextField.alpha = 1.0f;
    } else {
        [self.inputTextField becomeFirstResponder];
        self.inputTextField.text = @" ";
    }
}

/// FCL/ZL2 风格：调整游戏分辨率（对应 FCL window_scale / ZL2 resolutionRatio）
- (void)actionAdjustResolution {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"game.menu.resolution", nil)
                                                                   message:localize(@"game.menu.resolution.message", nil)
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray *options = @[@25, @50, @75, @100, @125, @150];
    NSInteger currentValue = (NSInteger)getPrefFloat(@"video.resolution");
    for (NSNumber *value in options) {
        NSString *title = [NSString stringWithFormat:@"%ld%%", (long)value.intValue];
        if (value.intValue == currentValue) {
            title = [NSString stringWithFormat:@"✓ %@", title];
        }
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            setPrefFloat(@"video.resolution", value.floatValue);
            [self updateSavedResolution];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];

    // iPad 适配
    alert.popoverPresentationController.sourceView = self.view;
    alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)actionOpenNavigationMenu {
    // FCL 风格：游戏内自定义按键的 SPECIALBTN_MENU 也触发底部弹出菜单
    [self toggleMenu];
}

- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    if (!self.menuView.hidden) {
        return 0;
    }
    return UIRectEdgeBottom | UIRectEdgeRight;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return self.menuView.hidden &&
        getPrefBool(@"debug.debug_hide_home_indicator");
}

- (BOOL)prefersStatusBarHidden {
    return self.menuView.hidden;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.menuArray.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"FCLMenuCell"];

    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"FCLMenuCell"];
        cell.backgroundColor = [UIColor clearColor];
        cell.textLabel.textColor = [UIColor whiteColor];
        // 修复：游戏内菜单字体不应使用 sp 缩放，使用固定 16pt 保证所有设备一致
        // 原 [ScreenUtils sp:16] 在 iPad 上会放大到 32pt 导致菜单字体过大
        cell.textLabel.font = [UIFont systemFontOfSize:16];
        cell.textLabel.textAlignment = NSTextAlignmentLeft;
        // FCL 风格：左侧留出图标空间，cell 高度 48
        cell.separatorInset = UIEdgeInsetsMake(0, 16, 0, 16);
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        // 选中状态背景
        UIView *selectedBg = [[UIView alloc] init];
        selectedBg.backgroundColor = [UIColor colorWithRed:80.0/255.0 green:80.0/255.0 blue:90.0/255.0 alpha:0.6];
        cell.selectedBackgroundView = selectedBg;
    }

    cell.textLabel.text = localize(self.menuArray[indexPath.row], nil);
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    // 修复：行高使用固定值 48pt，不随屏幕缩放
    // 原 [ScreenUtils sp:48] 在 iPad 上会放大到 96pt 导致菜单项过高
    return 48;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    [self didSelectMenuItem:indexPath.row];
}

- (void)didSelectMenuItem:(int)item {
    // ★ [FIX-A] case 下标与 menuArray 一一对应;原 index 3(联机/多人游戏)已删除,
    //   其后各项顺次前移一位(用户指示:多人游戏还在维护、没有实际入口)。
    switch (item) {
        case 0: // 强制关闭
            [self actionForceClose];
            break;
        case 1: // 日志输出
            [self.logOutputView actionToggleLogOutput];
            break;
        case 2: // 按键布局编辑
            [self actionOpenCustomControls];
            break;
        case 3: // FPS/内存显示开关
            if ([self.gameMenuOverlay isKindOfClass:[GameMenuOverlayView class]]) {
                [(GameMenuOverlayView *)self.gameMenuOverlay toggleStatsLabel];
            }
            break;
        case 4: // 隐藏/显示控制按钮
            [self actionToggleControls];
            break;
        case 5: // 虚拟鼠标开关
            [self actionToggleVirtualMouse];
            break;
        case 6: // 游戏内键盘
            [self actionToggleKeyboard];
            break;
        case 7: // 分辨率调整
            [self actionAdjustResolution];
            break;
        case 8: // 设置
            [self actionOpenPreferences];
            break;
    }
}

- (void)viewWillTransitionToSize_Navigation:(CGRect)frame {
    // FCL 风格：菜单从底部弹出，旋转时重新计算 frame
    CGFloat screenWidth = frame.size.width;
    CGFloat screenHeight = frame.size.height;
    CGFloat menuWidth = MIN(screenWidth * 0.7, 400);
    CGFloat menuMaxHeight = screenHeight * 0.6;
    CGFloat menuEstimatedHeight = self.menuArray.count * 48 + 16;
    CGFloat menuHeight = MIN(menuEstimatedHeight, menuMaxHeight);

    if (!self.menuView.hidden) {
        // 菜单可见时，更新到新的目标位置
        CGFloat safeBottom = [ScreenUtils safeAreaBottom];
        CGFloat targetY = screenHeight - menuHeight - safeBottom - 16;
        self.menuView.frame = CGRectMake(
            (screenWidth - menuWidth) / 2.0,
            targetY,
            menuWidth,
            menuHeight
        );
    } else {
        // 菜单不可见时，保持在屏幕底部外
        self.menuView.frame = CGRectMake(
            (screenWidth - menuWidth) / 2.0,
            screenHeight,
            menuWidth,
            menuHeight
        );
    }
    // 更新遮罩 frame
    self.menuDimView.frame = CGRectMake(0, 0, screenWidth, screenHeight);
}

@end
