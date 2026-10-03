#import "LauncherRightPanelViewController.h"
#import "authenticator/BaseAuthenticator.h"
#import "AccountListViewController.h"
#import "SurfaceViewController.h"
#import "JavaGUIViewController.h"
#import "JavaLauncher.h"
#import "PLCrashView.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceUtils.h"
#import "MinecraftResourceDownloadTask.h"
#import "DownloadTaskManager.h"
#import "DownloadTasksViewController.h"
#import "DownloadTaskItem.h"
#import "PLTaskProgressViewController.h"
#import "ALTServerConnection.h"
#import "BackgroundManager.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "AvatarManager.h"
#import "ImageCropperViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <sys/time.h>

// ★ [NORIGHT] 右栏卡片下线:下面三个通知是「新 UI 入口 ⇄ 右栏原实现」的唯一接线。
//   新 UI 只 post 动作名;右栏在 norightHandleAction: 里调用**自己原来的方法**,零复制逻辑。
NSString * const AmeRightPanelActionNotification       = @"AmeRightPanelAction";        // 新入口 → 右栏原方法
NSString * const AmeRightPanelStateNotification        = @"AmeRightPanelState";         // 右栏 → 外部(版本/JIT/启动键文案)
NSString * const AmeRightPanelRequestStateNotification = @"AmeRightPanelRequestState";  // 外部 → 右栏(索取一次状态)

// 添加 C 函数声明 - 这些函数在 LauncherPreferences.m 或其他地方定义
extern void setPrefString(NSString *key, NSString *value);
extern void setPrefInt(NSString *key, NSInteger value);

static void *ProgressObserverContext = &ProgressObserverContext;

@interface LauncherRightPanelViewController () <UIDocumentPickerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>

// ★ [NORIGHT] 头像裁剪器的呈现宿主(容器 0×0 后改由"顶层可见 VC"代呈,关闭时要用同一个)
@property(nonatomic, weak) UIViewController *norightAvatarHost;

// ★ [NORIGHT] 右栏 UI 已下线(容器 0×0 + hidden),但本控制器保留为不可见控制器:
//   下面两个数组用于"整组停用/恢复"setupUI 里的内部约束,避免 0×0 与 required 约束打架。
@property(nonatomic, strong) NSArray<NSLayoutConstraint *> *norightPanelConstraints;   // setupUI 里那一大组
@property(nonatomic, strong) NSArray<NSLayoutConstraint *> *norightExtraConstraints;   // 两条防重叠守卫
@property(nonatomic, assign) BOOL norightPanelCollapsed;

@property(nonatomic, strong) UIImageView *avatarImageView;
@property(nonatomic, strong) UILabel *usernameLabel;
@property(nonatomic, strong) UILabel *versionLabel;
@property(nonatomic, strong) UIButton *launchButton;
@property(nonatomic, strong) UIButton *manageVersionBtn;
@property(nonatomic, strong) UIButton *executeJarBtn;
// JIT 状态指示标签（启动游戏按钮上方）
@property(nonatomic, strong) UILabel *jitStatusLabel;

// ★ [LAUNCHA] 竖屏「紧凑胶囊」启动键：需要按方向改【常量】的约束引用。
//   横屏仍是大发光胶囊，所以同一属性只保存一套约束、方向变化时改 constant，绝不双钉。
@property(nonatomic, strong) NSLayoutConstraint *launchHeightConstraint;        // 启动键高度 46↔36
@property(nonatomic, strong) NSLayoutConstraint *jitHeightConstraint;           // JIT 标签高度 20↔18
@property(nonatomic, strong) NSLayoutConstraint *jitToLaunchConstraint;         // JIT 底 ↔ 启动键顶 -8↔-4
@property(nonatomic, strong) NSLayoutConstraint *launchToExecuteConstraint;     // 启动键底 ↔ 执行JAR 顶 -8↔-6
@property(nonatomic, strong) NSLayoutConstraint *downloadToJitConstraint;       // 下载中心底 ↔ JIT 顶 -8↔-6
@property(nonatomic, strong) NSLayoutConstraint *bottomRowMarginConstraint;     // 底部排距 safeArea 底 -12↔-10
// ★ [LAUNCHA] 已应用的方向态缓存：-1=尚未应用，0=横屏(大发光)，1=竖屏(紧凑)。
//   用于避免 layout 期间重复重算样式；只有真正切换方向时才重做。
@property(nonatomic, assign) NSInteger launchCompactState;

// 下载相关属性
@property(nonatomic, strong) MinecraftResourceDownloadTask *task;
@property(nonatomic, strong) UIProgressView *progressView;
@property(nonatomic, strong) UILabel *progressLabel;

// ===== 下载中心入口（参照 FCL/ZL2/HMCL 的统一下载进度弹窗入口）=====
// FCL/ZL2/HMCL 都在启动器主界面提供一个"下载管理/下载中心"入口按钮，
// 点击后弹出下载进度对话框，集中显示所有下载任务（MC本体/模组/光影/资源包等）的实时进度。
// 本按钮即对应这个入口：当 DownloadTaskManager 中存在任何下载任务时显示，
// 点击以 FormSheet 方式弹出 DownloadTasksViewController（全任务列表 + 进度详情）。
@property(nonatomic, strong) UIButton *downloadCenterButton;
// 按钮上的活动指示器（下载进行中时旋转，表示有活跃任务）
@property(nonatomic, strong) UIActivityIndicatorView *downloadCenterActivityIndicator;
// 按钮上的进度百分比标签（实时显示所有活动任务的聚合进度）
@property(nonatomic, strong) UILabel *downloadCenterProgressLabel;
// 进行中任务数徽标（redesign-download-ui Task 2.4）：红色圆形小徽标显示
// 进行中（下载中/排队中）任务数，无进行中任务时隐藏
@property(nonatomic, strong) UILabel *downloadCenterBadgeLabel;
// 当前弹出的下载中心 VC（弱引用，避免循环持有）
@property(nonatomic, weak) DownloadTasksViewController *presentedDownloadCenterVC;
// 标记用户是否手动关闭了下载中心（避免下载任务更新时反复自动弹出）
@property(nonatomic, assign) BOOL userDismissedDownloadCenter;

// FCL 风格：无账号时点击启动游戏跳转添加账号界面，登录完成后自动继续启动。
// pendingLaunchAfterLogin=YES 表示用户从启动按钮进入账号登录，登录成功后应自动触发 launchGame。
@property(nonatomic, assign) BOOL pendingLaunchAfterLogin;

@end

@implementation LauncherRightPanelViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor clearColor];

    // 适配自定义启动器背景：将当前视图控制器透明化，让全局背景（图片/视频）能够透出显示。
    // 即使本控制器在 LauncherRootViewController 中作为子 VC 添加，仍需在自身 viewDidLoad 中调用。
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    [self setupUI];
    [self updateAccountInfo];
    [self updateVersionInfo];
    
    // 监听账户信息更新通知
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAccountInfo)
                                                 name:@"UpdateAccountInfo"
                                               object:nil];
    // 监听版本/配置切换通知
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateVersionInfo)
                                                 name:@"SelectedProfileChanged"
                                               object:nil];

    // 监听统一下载任务聚合状态变化，以更新启动按钮
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateLaunchButtonState)
                                                 name:DownloadTaskManagerAggregateStateDidChangeNotification
                                               object:nil];

    // ===== 下载中心入口通知监听 =====
    // 监听下载任务更新通知（进度变化、新任务注册等），实时更新下载中心按钮的显示状态和进度百分比。
    // 这确保了模组、光影、资源包、数据包、世界存档等所有通过 DownloadTaskManager 注册的下载任务
    // 都能在下载中心按钮上反映出来，用户点击即可查看详情（参照 FCL/ZL2/HMCL 的下载进度弹窗）。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleDownloadTaskUpdate:)
                                                 name:DownloadTaskManagerDidUpdateTaskNotification
                                               object:nil];
    // 监听任务完成通知，更新按钮状态并在全部完成时隐藏活动指示器
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleDownloadTaskCompleted:)
                                                 name:DownloadTaskManagerTaskCompletedNotification
                                               object:nil];
    // 监听下载中心被用户手动关闭的通知，设置标记避免反复自动弹出
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleDownloadCenterDismissed)
                                                 name:@"DownloadCenterDidDismiss"
                                               object:nil];

    // 监听启动器外观变化（自定义字体/卡片颜色），刷新文字颜色
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyCustomAppearance)
                                                 name:@"LauncherAppearanceChanged"
                                               object:nil];

    // 监听背景 UI 效果变化通知：当用户在背景设置中切换毛玻璃/半透明或调整透明度时，
    // 重新调用 makeViewControllerTransparent 以应用最新的视觉效果，保证背景始终正确透出。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    // ★ [NORIGHT] 右栏 UI 已下线(容器 0×0 + hidden)。新入口(主页欢迎卡 / 主页底部启动胶囊 /
    //   顶栏 pill 排(JIT / 执行Jar / 选择版本 / 下载中心))通过这两个通知把动作转发到【本类原有的方法】——
    //   启动链路 / 执行 Jar / 版本选择 / 下载中心 一律走原实现,零复制、零改动。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(norightHandleAction:)
                                                 name:AmeRightPanelActionNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(norightHandleStateRequest:)
                                                 name:AmeRightPanelRequestStateNotification
                                               object:nil];

    // ★ [NORIGHT] 首次广播一次状态:主页若已注册监听,即可拿到版本号 / JIT / 启动键文案。
    [self norightBroadcastState];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateAccountInfo];
    [self updateVersionInfo];
    [self updateLaunchButtonState];
    [self updateJITStatus];
    [self applyCustomAppearance];
    [self updateDownloadCenterButton];
}

/// 重新应用背景效果：当 BackgroundUIEffectChanged 通知到达时调用，
/// 通过 BackgroundManager 重新设置当前视图控制器的透明度/毛玻璃效果，
/// 确保全局背景能够正常透出。
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // 关键修复（UI 累积异常）：KVO 兜底移除，防止 task 仍在进行中时 VC 被释放导致野指针。
    if (self.task && self.task.progress) {
        @try {
            [self.task.progress removeObserver:self
                                    forKeyPath:@"fractionCompleted"
                                       context:ProgressObserverContext];
        } @catch (NSException *e) {}
    }
}

#pragma mark - UI Setup

- (void)setupUI {
    // 头像
    self.avatarImageView = [[UIImageView alloc] init];
    self.avatarImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.avatarImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.avatarImageView.layer.cornerRadius = 36;
    self.avatarImageView.layer.masksToBounds = YES;
    self.avatarImageView.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    self.avatarImageView.image = [UIImage systemImageNamed:@"person.circle.fill"];
    self.avatarImageView.tintColor = [UIColor systemGrayColor];
    self.avatarImageView.userInteractionEnabled = YES;
    [self.avatarImageView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(selectAccount:)]];
    // 长按头像：弹出自定义头像导入/清除菜单
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(showAvatarMenu:)];
    longPress.minimumPressDuration = 0.5;
    [self.avatarImageView addGestureRecognizer:longPress];
    [self.view addSubview:self.avatarImageView];
    
    // 用户名标签
    self.usernameLabel = [[UILabel alloc] init];
    self.usernameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.usernameLabel.font = [UIFont boldSystemFontOfSize:16];
    self.usernameLabel.textColor = [UIColor labelColor];
    self.usernameLabel.textAlignment = NSTextAlignmentCenter;
    // iPhone 上侧栏宽度更窄，开启字号自适应避免长用户名被截断
    self.usernameLabel.adjustsFontSizeToFitWidth = YES;
    self.usernameLabel.minimumScaleFactor = 0.7;
    self.usernameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.usernameLabel.text = localize(@"i18n_str_357", nil);
    [self.view addSubview:self.usernameLabel];

    // 版本标签
    self.versionLabel = [[UILabel alloc] init];
    self.versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionLabel.font = [UIFont systemFontOfSize:13];
    self.versionLabel.textColor = [UIColor secondaryLabelColor];
    self.versionLabel.textAlignment = NSTextAlignmentCenter;
    self.versionLabel.adjustsFontSizeToFitWidth = YES;
    self.versionLabel.minimumScaleFactor = 0.7;
    self.versionLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.versionLabel.text = localize(@"i18n_str_411", nil);
    // FCL 风格：点击版本标签也能弹出选择器
    self.versionLabel.userInteractionEnabled = YES;
    [self.versionLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showVersionPicker)]];
    [self.view addSubview:self.versionLabel];
    
    // 进度标签
    self.progressLabel = [[UILabel alloc] init];
    self.progressLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressLabel.font = [UIFont systemFontOfSize:12];
    self.progressLabel.textColor = [UIColor secondaryLabelColor];
    self.progressLabel.textAlignment = NSTextAlignmentCenter;
    self.progressLabel.text = @"";
    self.progressLabel.hidden = YES;
    [self.view addSubview:self.progressLabel];
    
    // 进度条
    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressView.hidden = YES;
    [self.view addSubview:self.progressView];

    // ===== 下载中心入口按钮（参照 FCL/ZL2/HMCL 下载进度弹窗入口）=====
    // 设计理念：FCL 和 ZL2 在启动器主界面提供一个"下载管理"按钮，点击后弹出下载进度对话框；
    // HMCL 在下载页面显示所有下载任务的进度。本按钮综合三者风格：
    // - 按钮样式：圆角卡片式，与启动器其他按钮统一
    // - 左侧：下载图标 + 活动指示器（下载中时旋转）
    // - 中间："下载中心"文字 + 进度百分比
    // - 右侧：箭头图标（表示点击可查看详情）
    // - 当 DownloadTaskManager 中存在任何下载任务时显示，无任务时隐藏
    self.downloadCenterButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.downloadCenterButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.downloadCenterButton setTitle:localize(@"i18n_str_136", nil) forState:UIControlStateNormal];
    [self.downloadCenterButton setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    self.downloadCenterButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.downloadCenterButton.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.downloadCenterButton.titleLabel.minimumScaleFactor = 0.7;
    self.downloadCenterButton.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.downloadCenterButton.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    self.downloadCenterButton.layer.cornerRadius = 10;
    self.downloadCenterButton.layer.masksToBounds = YES;
    // 左侧下载图标
    UIImage *downloadIcon = [UIImage systemImageNamed:@"arrow.down.circle"];
    [self.downloadCenterButton setImage:downloadIcon forState:UIControlStateNormal];
    self.downloadCenterButton.tintColor = accentColor();
    self.downloadCenterButton.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 4);
    self.downloadCenterButton.titleEdgeInsets = UIEdgeInsetsMake(0, 4, 0, -4);
    self.downloadCenterButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.downloadCenterButton.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
    [self.downloadCenterButton addTarget:self action:@selector(openDownloadCenter) forControlEvents:UIControlEventTouchUpInside];
    self.downloadCenterButton.hidden = YES; // 默认隐藏，有下载任务时显示
    [self.view addSubview:self.downloadCenterButton];

    // 活动指示器（下载中时旋转，叠加在按钮右侧）
    self.downloadCenterActivityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.downloadCenterActivityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.downloadCenterActivityIndicator.color = accentColor();
    self.downloadCenterActivityIndicator.hidesWhenStopped = YES;
    [self.downloadCenterButton addSubview:self.downloadCenterActivityIndicator];

    // 进度百分比标签（叠加在按钮右侧，显示聚合进度）
    self.downloadCenterProgressLabel = [[UILabel alloc] init];
    self.downloadCenterProgressLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.downloadCenterProgressLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    self.downloadCenterProgressLabel.textColor = accentColor();
    self.downloadCenterProgressLabel.textAlignment = NSTextAlignmentRight;
    self.downloadCenterProgressLabel.text = @"0%";
    [self.downloadCenterButton addSubview:self.downloadCenterProgressLabel];

    // 进行中任务数徽标（红色圆形，位于进度百分比左侧，redesign-download-ui Task 2.4）
    self.downloadCenterBadgeLabel = [[UILabel alloc] init];
    self.downloadCenterBadgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.downloadCenterBadgeLabel.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightBold];
    self.downloadCenterBadgeLabel.textColor = [UIColor whiteColor];
    self.downloadCenterBadgeLabel.backgroundColor = [UIColor systemRedColor];
    self.downloadCenterBadgeLabel.textAlignment = NSTextAlignmentCenter;
    self.downloadCenterBadgeLabel.layer.cornerRadius = 8.0;
    self.downloadCenterBadgeLabel.layer.masksToBounds = YES;
    self.downloadCenterBadgeLabel.hidden = YES;
    [self.downloadCenterButton addSubview:self.downloadCenterBadgeLabel];
    
    // 启动游戏按钮（FCL 复合布局 + ZL2 按压动画风格）
    self.launchButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.launchButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.launchButton setTitle:localize(@"i18n_str_412", nil) forState:UIControlStateNormal];
    [self.launchButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.launchButton.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    // iPhone 右侧面板更窄：标题字号自适应，避免"下载中..."等长文案被截断
    self.launchButton.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.launchButton.titleLabel.minimumScaleFactor = 0.6;
    self.launchButton.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.launchButton.backgroundColor = accentColor();
    self.launchButton.layer.cornerRadius = 10;
    self.launchButton.layer.masksToBounds = YES;
    // FCL 风格：按钮阴影（elevation 效果），增强层次感
    self.launchButton.layer.shadowColor = [UIColor blackColor].CGColor;
    self.launchButton.layer.shadowOffset = CGSizeMake(0, 2);
    self.launchButton.layer.shadowRadius = 4;
    self.launchButton.layer.shadowOpacity = 0.3;
    // masksToBounds 会裁剪阴影，改用 backgroundColor + cornerRadius 不裁剪
    // 但 masksToBounds=YES 是为了让背景色圆角生效，阴影需要单独的容器视图
    // 权衡：保留 masksToBounds=YES（圆角更重要），放弃阴影（iOS 上 UIButton 本身有高亮效果）
    self.launchButton.layer.masksToBounds = YES;

    [self.launchButton addTarget:self action:@selector(launchButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    // ZL2 风格按压动画：按下时缩放到 0.95，松开时恢复
    [self.launchButton addTarget:self action:@selector(launchButtonTouchDown) forControlEvents:UIControlEventTouchDown];
    [self.launchButton addTarget:self action:@selector(launchButtonTouchUp) forControlEvents:UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self.view addSubview:self.launchButton];

    // JIT 状态指示标签（位于启动游戏按钮上方）
    self.jitStatusLabel = [[UILabel alloc] init];
    self.jitStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.jitStatusLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    self.jitStatusLabel.textAlignment = NSTextAlignmentCenter;
    self.jitStatusLabel.layer.cornerRadius = 8;
    self.jitStatusLabel.layer.masksToBounds = YES;
    self.jitStatusLabel.text = localize(@"i18n_str_413", nil);
    [self.view addSubview:self.jitStatusLabel];

    // 选择版本按钮（FCL 风格：右侧版本选择入口；控制设置已挪到左侧菜单 case 3）
    self.manageVersionBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.manageVersionBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.manageVersionBtn setTitle:localize(@"i18n_str_38", nil) forState:UIControlStateNormal];
    [self.manageVersionBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    [self.manageVersionBtn.titleLabel setFont:[UIFont systemFontOfSize:14 weight:UIFontWeightMedium]];
    self.manageVersionBtn.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.manageVersionBtn.titleLabel.minimumScaleFactor = 0.7;
    self.manageVersionBtn.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.manageVersionBtn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    self.manageVersionBtn.layer.cornerRadius = 10;
    [self.manageVersionBtn addTarget:self action:@selector(showVersionPicker) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.manageVersionBtn];

    // 执行JAR按钮
    self.executeJarBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.executeJarBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.executeJarBtn setTitle:localize(@"i18n_str_414", nil) forState:UIControlStateNormal];
    [self.executeJarBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    self.executeJarBtn.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.executeJarBtn.titleLabel.minimumScaleFactor = 0.7;
    self.executeJarBtn.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.executeJarBtn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    self.executeJarBtn.layer.cornerRadius = 10;
    [self.executeJarBtn addTarget:self action:@selector(executeJar) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.executeJarBtn];
    
    // 约束布局：
    // - 上半部分（头像/用户名/版本/进度）自上而下锚定在顶部
    // - 下半部分（执行Jar/选择版本/JIT/启动按钮）自下而上锚定在底部
    // 这样 JIT 显示和启动游戏按钮位于右侧面板下方，与头像区分离，避免拥挤。
    // ★ [NORIGHT] 这一整组约束改存进属性:容器被归零时整组停用 ⇒ 0×0 不会与内部 required 约束冲突。
    self.norightPanelConstraints = @[
        // 头像（顶部）
        [self.avatarImageView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:10],   // ★ [NOOVERLAP-2]
        [self.avatarImageView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        // ★ [NOOVERLAP-2] 上半截压矮,给"下载中心"按钮腾位置(见文件末硬防护)
        [self.avatarImageView.widthAnchor constraintEqualToConstant:56],
        [self.avatarImageView.heightAnchor constraintEqualToConstant:56],

        // 用户名
        [self.usernameLabel.topAnchor constraintEqualToAnchor:self.avatarImageView.bottomAnchor constant:6],   // ★ [NOOVERLAP-2]
        [self.usernameLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.usernameLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        // 版本
        [self.versionLabel.topAnchor constraintEqualToAnchor:self.usernameLabel.bottomAnchor constant:3],   // ★ [NOOVERLAP-2]
        [self.versionLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.versionLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        // 进度标签
        [self.progressLabel.topAnchor constraintEqualToAnchor:self.versionLabel.bottomAnchor constant:5],   // ★ [NOOVERLAP-2]
        [self.progressLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.progressLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        // 进度条
        [self.progressView.topAnchor constraintEqualToAnchor:self.progressLabel.bottomAnchor constant:4],
        [self.progressView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.progressView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        // ===== 下载中心入口按钮（进度条下方）=====
        // 当有下载任务时显示，点击弹出 DownloadTasksViewController（参照 FCL/ZL2/HMCL 下载进度弹窗）
        // ★ [NOOVERLAP] 竖屏右栏矮:下载中心按钮不再"从进度条往下长",
        //   改成【钉在 JIT 标签上方】—— 两边各自有归属,数学上不可能重叠。
        self.downloadToJitConstraint = [self.downloadCenterButton.bottomAnchor constraintEqualToAnchor:self.jitStatusLabel.topAnchor constant:-8], // ★ [LAUNCHA]
        [self.downloadCenterButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.downloadCenterButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.downloadCenterButton.heightAnchor constraintEqualToConstant:36],

        // 活动指示器（按钮右侧，垂直居中）
        [self.downloadCenterActivityIndicator.trailingAnchor constraintEqualToAnchor:self.downloadCenterButton.trailingAnchor constant:-12],
        [self.downloadCenterActivityIndicator.centerYAnchor constraintEqualToAnchor:self.downloadCenterButton.centerYAnchor],

        // 进度百分比标签（指示器左侧，垂直居中）
        [self.downloadCenterProgressLabel.trailingAnchor constraintEqualToAnchor:self.downloadCenterActivityIndicator.leadingAnchor constant:-6],
        [self.downloadCenterProgressLabel.centerYAnchor constraintEqualToAnchor:self.downloadCenterButton.centerYAnchor],

        // 进行中任务数徽标（进度百分比左侧，垂直居中；隐藏时自动收起不占位）
        [self.downloadCenterBadgeLabel.trailingAnchor constraintEqualToAnchor:self.downloadCenterProgressLabel.leadingAnchor constant:-6],
        [self.downloadCenterBadgeLabel.centerYAnchor constraintEqualToAnchor:self.downloadCenterButton.centerYAnchor],
        [self.downloadCenterBadgeLabel.heightAnchor constraintEqualToConstant:16],
        [self.downloadCenterBadgeLabel.widthAnchor constraintGreaterThanOrEqualToConstant:16],

        // ===== 下方按钮区（自下而上锚定到 safeArea 底部，参照 FCL 两按钮一排）=====
        // 执行Jar 按钮（最底部，左半区）
        self.bottomRowMarginConstraint = [self.executeJarBtn.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12], // ★ [LAUNCHA]
        [self.executeJarBtn.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.executeJarBtn.heightAnchor constraintEqualToConstant:38],

        // 管理版本按钮（最底部，右半区，与执行Jar 同一排）
        [self.manageVersionBtn.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
        [self.manageVersionBtn.leadingAnchor constraintEqualToAnchor:self.executeJarBtn.trailingAnchor constant:8],
        [self.manageVersionBtn.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.manageVersionBtn.heightAnchor constraintEqualToConstant:38],

        // 两个按钮宽度相等（各占一半，减去中间 8pt 间距）
        [self.executeJarBtn.widthAnchor constraintEqualToAnchor:self.manageVersionBtn.widthAnchor],

        // 启动按钮（占满整排，位于两按钮上方）
        // ★ [LAUNCHA] 高度改为可调常量：竖屏紧凑 36pt，横屏保持原 46pt（见 ameApplyLaunchButtonAppearance）
        self.launchToExecuteConstraint = [self.launchButton.bottomAnchor constraintEqualToAnchor:self.executeJarBtn.topAnchor constant:-8], // ★ [LAUNCHA]
        [self.launchButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.launchButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        self.launchHeightConstraint = [self.launchButton.heightAnchor constraintEqualToConstant:46], // ★ [LAUNCHA]

        // JIT 状态标签（启动按钮上方）
        // ★ [LAUNCHA] 标签高度与到启动键的间距均为可调常量（竖屏收紧）
        self.jitToLaunchConstraint = [self.jitStatusLabel.bottomAnchor constraintEqualToAnchor:self.launchButton.topAnchor constant:-8], // ★ [LAUNCHA]
        [self.jitStatusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.jitStatusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        self.jitHeightConstraint = [self.jitStatusLabel.heightAnchor constraintEqualToConstant:20], // ★ [LAUNCHA]
    ];   // ★ [NORIGHT]
    [NSLayoutConstraint activateConstraints:self.norightPanelConstraints];

    // ★ [NOOVERLAP-2] 下载中心按钮【顶部】不得高于进度条底部 + 8:
    //   上半截(头像→版本→进度条)自上而下、下半截(按钮→JIT→启动按钮)自下而上,
    //   两截相遇处原本没人管 ⇒ 按钮压住"游戏信息"(版本号),用户实测已报。
    NSLayoutConstraint *norightDownloadTopGuard = [NSLayoutConstraint constraintWithItem:self.downloadCenterButton
                                attribute:NSLayoutAttributeTop
                                relatedBy:NSLayoutRelationGreaterThanOrEqual
                                   toItem:self.progressView
                                attribute:NSLayoutAttributeBottom
                               multiplier:1.0
                                 constant:8];

    // 进度条底部需留出空间避免与下方 JIT 标签重叠（弱约束，允许中间留白）
    NSLayoutConstraint *norightJITTopGuard = [NSLayoutConstraint constraintWithItem:self.jitStatusLabel
                                attribute:NSLayoutAttributeTop
                                relatedBy:NSLayoutRelationGreaterThanOrEqual
                                   toItem:self.progressView
                                attribute:NSLayoutAttributeBottom
                               multiplier:1.0
                                 constant:12];

    // ★ [NORIGHT] 两条"防重叠"守卫也纳入可停用集合(与上面那一大组同生共死)。
    self.norightExtraConstraints = @[norightDownloadTopGuard, norightJITTopGuard];
    [NSLayoutConstraint activateConstraints:self.norightExtraConstraints];
}

#pragma mark - ★ [LAUNCHA] 竖屏紧凑启动键（方向自适应）

/// 当前是否竖屏：以 view 实际尺寸判定（与 LauncherRootViewController 的 ameIsPortraitNow 口径一致，
/// 比 traitCollection 更可靠——iPad 分屏/旋转时 size class 可能不变）。
- (BOOL)ameIsPortraitNow {
    CGSize size = self.view.bounds.size;
    if (size.width <= 0 || size.height <= 0) return NO;
    return size.width <= size.height;
}

/// 竖屏：启动键 = 紧凑胶囊（淡 accent 底 + 1px 描边 + ▶ 图标 + 副标题字号，无大渐变/发光）；
/// 横屏：保持原「大发光胶囊」不动。
/// 只改观感与占高，绝不触碰 target/action、可用性判断与文案 localize key。
/// 全部走常量（高度/间距），不做 frame 硬摆、不双钉同一属性。
- (void)ameApplyLaunchButtonAppearance {
    if (!self.launchButton) return;

    BOOL portrait = [self ameIsPortraitNow];
    UIColor *accent = accentColor() ?: [UIColor systemBlueColor];

    // ---- ① 占高：高度 + 相关间距（竖屏收紧；横屏改回原值，与改动前完全一致）----
    self.launchHeightConstraint.constant    = portrait ? 36.0 : 46.0;
    self.jitHeightConstraint.constant       = portrait ? 18.0 : 20.0;
    self.jitToLaunchConstraint.constant     = portrait ? -4.0 : -8.0;
    self.launchToExecuteConstraint.constant = portrait ? -6.0 : -8.0;
    self.downloadToJitConstraint.constant   = portrait ? -6.0 : -8.0;
    self.bottomRowMarginConstraint.constant = portrait ? -10.0 : -12.0;

    // ---- ② 观感 ----
    if (portrait) {
        // 淡色底（accent alpha 0.15）+ 1px accent 描边 + 胶囊圆角
        self.launchButton.backgroundColor = [accent colorWithAlphaComponent:0.15];
        self.launchButton.layer.borderWidth = 1.0;
        self.launchButton.layer.borderColor = accent.CGColor;
        self.launchButton.layer.cornerRadius = 18.0;   // 36/2，viewDidLayoutSubviews 再按真实高度校正
        self.launchButton.layer.masksToBounds = YES;
        self.launchButton.layer.shadowOpacity = 0.0;   // 去发光/投影
        // 字号降到 Subheadline 一档
        self.launchButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        [self.launchButton setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        // 左侧 ▶ 图标（play.fill），图标+文字居中
        UIImage *play = [UIImage systemImageNamed:@"play.fill"];
        if (play) {
            play = [play imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        }
        [self.launchButton setImage:play forState:UIControlStateNormal];
        self.launchButton.tintColor = accent;
        self.launchButton.imageEdgeInsets = UIEdgeInsetsMake(0, -6, 0, 0);
        self.launchButton.titleEdgeInsets = UIEdgeInsetsMake(0, 6, 0, 0);
        self.launchButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
        self.launchButton.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    } else {
        // 横屏：完全恢复改动前的「大发光胶囊」外观（实心主题色 + Title3 + 白字，无描边/无图标）
        self.launchButton.backgroundColor = accent;
        self.launchButton.layer.borderWidth = 0.0;
        self.launchButton.layer.cornerRadius = 10.0;
        self.launchButton.layer.masksToBounds = YES;
        // 原阴影参数（masksToBounds=YES 会裁剪阴影，故视觉上本就不显示；此处仅为与改前逐值一致）
        self.launchButton.layer.shadowColor = [UIColor blackColor].CGColor;
        self.launchButton.layer.shadowOffset = CGSizeMake(0, 2);
        self.launchButton.layer.shadowRadius = 4;
        self.launchButton.layer.shadowOpacity = 0.3;
        self.launchButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle3];
        [self.launchButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [self.launchButton setImage:nil forState:UIControlStateNormal];
        self.launchButton.tintColor = [UIColor whiteColor];
        self.launchButton.imageEdgeInsets = UIEdgeInsetsZero;
        self.launchButton.titleEdgeInsets = UIEdgeInsetsZero;
        self.launchButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
        self.launchButton.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    }

    self.launchCompactState = portrait ? 1 : 0;
}

/// 方向变化回调：重算启动键观感/占高。
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    // ★ [LAUNCHA] iPhone 旋转会改变 size class，这里即时重算（高度/间距/样式一起切）。
    [self ameApplyLaunchButtonAppearance];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    // ★ [LAUNCHA] 兜底：iPad 分屏/旋转时 size class 可能不变，traitCollectionDidChange 不触发。
    //   仅在「竖/横真正切换」时才重做，避免 layout 期间反复重算样式。
    NSInteger want = [self ameIsPortraitNow] ? 1 : 0;
    if (self.launchCompactState != want) {
        [self ameApplyLaunchButtonAppearance];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // ★ [LAUNCHA] 胶囊圆角按真实高度一半校正（竖屏）；横屏圆角由 ameApplyLaunchButtonAppearance 固定 10。
    if ([self ameIsPortraitNow]) {
        CGFloat h = CGRectGetHeight(self.launchButton.bounds);
        if (h > 0) self.launchButton.layer.cornerRadius = h / 2.0;
    }
}

#pragma mark - Actions

- (void)selectAccount:(UITapGestureRecognizer *)gesture {
    // 用户主动管理账号（非启动入口），取消任何"待启动"意图，
    // 避免登录后意外自动启动游戏。
    self.pendingLaunchAfterLogin = NO;
    // FCL 风格：账户管理在中间内容区显示，发送通知让 LauncherRootViewController 切换内容
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowAccountManager" object:nil];
}

#pragma mark - 下载中心（参照 FCL/ZL2/HMCL 下载进度弹窗）

/// 打开下载中心弹窗
/// 参照 FCL/ZL2/HMCL 的下载进度显示方式：以 FormSheet 方式弹出 DownloadTasksViewController，
/// 集中显示所有下载任务（MC本体/模组/光影/资源包/数据包/世界存档/整合包）的实时进度。
/// 所有通过 DownloadTaskManager 注册的下载任务都会在这里显示，实现统一的下载进度管理。
- (void)openDownloadCenter {
    // 如果已经弹出了下载中心，直接返回避免重复弹出
    if (self.presentedDownloadCenterVC) {
        return;
    }

    // 用户主动打开了下载中心，重置"用户已关闭"标记
    self.userDismissedDownloadCenter = NO;

    DownloadTasksViewController *downloadCenterVC = [[DownloadTasksViewController alloc] init];
    downloadCenterVC.modalPresentationStyle = UIModalPresentationFormSheet;
    // 弹出时不要覆盖全屏，FormSheet 方式在 iPad 上居中显示，在 iPhone 上接近全屏
    downloadCenterVC.preferredContentSize = CGSizeMake(500, 600);

    // 弱引用持有，避免循环持有
    self.presentedDownloadCenterVC = downloadCenterVC;

    // 获取最顶层的视图控制器来 present
    // ★ [NORIGHT] 右栏容器已 0×0 + hidden ⇒ 改用"窗口里最顶层的可见 VC"作宿主
    //   (弹出的内容、模态样式、回调 delegate 全部不变)。
    UIViewController *topVC = [self norightPresenter];

    [topVC presentViewController:downloadCenterVC animated:YES completion:nil];
}

/// 处理下载任务更新通知（进度变化、新任务注册等）
/// 当收到通知时仅更新下载中心按钮的状态，不再自动弹出下载中心界面。
///
/// redesign-download-ui Phase 3：单任务进度展示统一由任务注册时置
/// autoPresentDetail=YES 的 DownloadTaskItem 触发 DownloadTaskManager
/// 自动弹出统一进度页（PLTaskProgressViewController）；下载中心
/// DownloadTasksViewController 仅保留为手动打开（通过下载中心按钮）。
- (void)handleDownloadTaskUpdate:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateDownloadCenterButton];
    });
}

/// 处理下载任务完成通知
/// 当任务完成时更新按钮状态；如果所有任务都已完成，延迟隐藏下载中心按钮
- (void)handleDownloadTaskCompleted:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateDownloadCenterButton];
    });
}

/// 处理下载中心被用户手动关闭的通知
/// 设置 userDismissedDownloadCenter=YES，避免后续下载任务更新时反复自动弹出下载中心。
/// 用户可以通过点击启动器上的"下载中心"按钮重新打开（会重置此标记）。
- (void)handleDownloadCenterDismissed {
    self.userDismissedDownloadCenter = YES;
    self.presentedDownloadCenterVC = nil;
}

/// 更新下载中心按钮的显示状态和进度百分比
/// 根据 DownloadTaskManager 的当前状态：
/// - 无任务：隐藏按钮
/// - 有活跃任务（downloading/pending）：显示按钮 + 活动指示器旋转 + 进行中任务数徽标 + 显示聚合进度百分比
/// - 全部完成：显示按钮 + 活动指示器停止 + 显示"已完成"
- (void)updateDownloadCenterButton {
    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    NSArray<DownloadTaskItem *> *allTasks = [manager allTasks];

    if (allTasks.count == 0) {
        // 无任何下载任务，隐藏下载中心按钮
        self.downloadCenterButton.hidden = YES;
        self.downloadCenterBadgeLabel.hidden = YES;
        [self.downloadCenterActivityIndicator stopAnimating];
        [self norightPostState];   // ★ [TOPBAR2] 无任务也广播(顶栏 pill 回到纯入口态)
        return;
    }

    // 有下载任务，显示按钮
    self.downloadCenterButton.hidden = NO;

    // 计算聚合进度（所有活动任务的平均进度）
    BOOL hasActive = NO;
    BOOL allCompleted = YES;
    double totalProgress = 0.0;
    NSInteger activeCount = 0;

    for (DownloadTaskItem *task in allTasks) {
        if (task.state == DownloadTaskStateDownloading || task.state == DownloadTaskStatePending) {
            hasActive = YES;
            allCompleted = NO;
            totalProgress += task.progress;
            activeCount++;
        } else if (task.state != DownloadTaskStateCompleted) {
            allCompleted = NO;
        }
    }

    // 进行中任务数徽标（redesign-download-ui Task 2.4）：有进行中任务时显示数量
    if (hasActive) {
        self.downloadCenterBadgeLabel.text = activeCount > 99 ? @"99+" : [NSString stringWithFormat:@"%ld", (long)activeCount];
        self.downloadCenterBadgeLabel.hidden = NO;
    } else {
        self.downloadCenterBadgeLabel.hidden = YES;
    }

    if (hasActive) {
        // 有活跃下载任务
        double avgProgress = activeCount > 0 ? totalProgress / activeCount : 0.0;
        NSInteger percent = (NSInteger)(avgProgress * 100.0 + 0.5);
        percent = MAX(0, MIN(100, percent));
        self.downloadCenterProgressLabel.text = [NSString stringWithFormat:@"%ld%%", (long)percent];
        [self.downloadCenterActivityIndicator startAnimating];
    } else if (allCompleted) {
        // 全部完成
        self.downloadCenterProgressLabel.text = localize(@"i18n_str_126", nil);
        [self.downloadCenterActivityIndicator stopAnimating];
    } else {
        // 有暂停/失败/取消的任务但没有活跃任务
        self.downloadCenterProgressLabel.text = localize(@"i18n_str_125", nil);
        [self.downloadCenterActivityIndicator stopAnimating];
    }
    [self norightPostState];   // ★ [TOPBAR2] 角标/百分比 → 顶栏「下载中心」pill
}

#pragma mark - 自定义头像导入

- (void)showAvatarMenu:(UILongPressGestureRecognizer *)gesture {
    // ★ [NORIGHT] 允许外部(主页欢迎卡的头像长按)以 nil gesture 直接调用:nil 视为"要弹菜单"。
    if (gesture && gesture.state != UIGestureRecognizerStateBegan) return;

    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    NSString *accountId = currentAuth.authData[@"accountId"];
    if (!accountId || accountId.length == 0) {
        [self showAlert:localize(@"i18n_str_357", nil) message:localize(@"i18n_str_415", nil)];
        return;
    }

    BOOL hasCustom = [[AvatarManager sharedManager] hasCustomAvatarForAccount:accountId];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_416", nil)
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_417", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self openAvatarImagePicker];
    }]];
    if (hasCustom) {
        [sheet addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_418", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            [[AvatarManager sharedManager] removeAvatarForAccount:accountId];
            [self updateAccountInfo];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];

    // iPad 适配：用 popover 锚定到头像
    // ★ [NORIGHT] 右栏头像已随容器下线(0×0)⇒ 锚点改用"当前顶层可见 VC 的 view 中心",
    //   否则 ActionSheet 会落到屏幕原点;菜单选项与 handler 一字不改。
    UIViewController *norightHost = [self norightPresenter];
    UIView *norightAnchor = norightHost.view ?: self.view;
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = norightAnchor;
        sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(norightAnchor.bounds), CGRectGetMidY(norightAnchor.bounds), 1, 1);
    }
    [norightHost presentViewController:sheet animated:YES completion:nil];
}

- (void)openAvatarImagePicker {
    // 防止重复弹出
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        for (UIView *view in window.subviews) {
            if ([view isKindOfClass:[UIImagePickerController class]]) return;
        }
    }
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.delegate = self;
    [[self norightPresenter] presentViewController:picker animated:YES completion:nil];   // ★ [NORIGHT]
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    [picker dismissViewControllerAnimated:YES completion:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImage *selectedImage = info[UIImagePickerControllerOriginalImage];
            if (!selectedImage) {
                [self showAlert:localize(@"i18n_str_42", nil) message:localize(@"i18n_str_368", nil)];
                return;
            }
            // 头像需要正方形，非正方形则裁剪
            if (selectedImage.size.width != selectedImage.size.height) {
                ImageCropperViewController *cropperVC = [[ImageCropperViewController alloc] initWithImage:selectedImage];
                __weak typeof(self) weakSelf = self;
                cropperVC.completionHandler = ^(UIImage * _Nullable croppedImage) {
                    // ★ [NORIGHT] 裁剪器由 norightAvatarHost 代呈 ⇒ 关闭必须用同一个宿主
                    //   (原来 self 既是呈者又是关者;容器 0×0 后 self 上已无 presented VC)。
                    UIViewController *norightCloser = weakSelf.norightAvatarHost ?: weakSelf;
                    [norightCloser dismissViewControllerAnimated:YES completion:^{
                        if (croppedImage) {
                            [weakSelf saveAvatarImage:croppedImage];
                        }
                    }];
                };
                // 本 VC 为 child view controller，self.navigationController 可能为 nil，
                // 故用 present 方式呈现裁剪器（包装在 NavigationController 中以保留其导航栏样式）
                // ★ [NORIGHT] 右栏容器 0×0 + hidden ⇒ 由"顶层可见 VC"代呈裁剪器(内容/样式不变);
                //   宿主记到 norightAvatarHost,后面的 completionHandler 要用**同一个**把它关掉。
                UIViewController *norightHost = [self norightPresenter];
                self.norightAvatarHost = norightHost;
                UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:cropperVC];
                nav.modalPresentationStyle = UIModalPresentationFullScreen;
                [norightHost presentViewController:nav animated:YES completion:nil];
            } else {
                [self saveAvatarImage:selectedImage];
            }
        });
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)saveAvatarImage:(UIImage *)image {
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    NSString *accountId = currentAuth.authData[@"accountId"];
    if (!accountId || accountId.length == 0) {
        [self showAlert:localize(@"i18n_str_42", nil) message:localize(@"i18n_str_419", nil)];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [[AvatarManager sharedManager] saveAvatarForAccount:accountId image:image withCompletion:^(BOOL success, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                [weakSelf updateAccountInfo];
            } else {
                NSString *msg = error.localizedDescription ?: localize(@"i18n_str_420", nil);
                [weakSelf showAlert:localize(@"i18n_str_42", nil) message:msg];
            }
        });
    }];
}

#pragma mark - JIT 状态显示

- (void)updateJITStatus {
    if (!self.jitStatusLabel) return;
    BOOL enabled = isJITEnabled(NO);
    // 三态显示（议题 #133）：TXM 机型上 JIT 可能"已启用"（CS_DEBUGGED 置位）
    // 而服务 brk #0x69 的调试器已脱离——这是预期可恢复状态（启动时自动重附加），
    // 用琥珀色区别于红色"未开启"，两边都不误报。
    if (enabled && DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM) &&
        !JIT26IsLikelyDebuggerKeepAttached()) {
        self.jitStatusLabel.text = localize(@"i18n_str_jit26_pending", nil);
        self.jitStatusLabel.textColor = [UIColor colorWithRed:0.95 green:0.75 blue:0.2 alpha:1.0];
        self.jitStatusLabel.backgroundColor = [[UIColor colorWithRed:0.95 green:0.75 blue:0.2 alpha:1.0] colorWithAlphaComponent:0.15];
    } else if (enabled) {
        self.jitStatusLabel.text = localize(@"i18n_str_421", nil);
        self.jitStatusLabel.textColor = [UIColor colorWithRed:0.2 green:0.7 blue:0.3 alpha:1.0];
        self.jitStatusLabel.backgroundColor = [[UIColor colorWithRed:0.2 green:0.7 blue:0.3 alpha:1.0] colorWithAlphaComponent:0.15];
    } else {
        self.jitStatusLabel.text = localize(@"i18n_str_422", nil);
        self.jitStatusLabel.textColor = [UIColor colorWithRed:0.9 green:0.4 blue:0.3 alpha:1.0];
        self.jitStatusLabel.backgroundColor = [[UIColor colorWithRed:0.9 green:0.4 blue:0.3 alpha:1.0] colorWithAlphaComponent:0.15];
    }
    [self norightPostState];   // ★ [NORIGHT] 把 JIT 文本/颜色同步给主页顶栏 pill
}

#pragma mark - 自定义外观（字体颜色）

/// 读取 general.text_color 偏好并应用到右侧面板的主要文字。
/// 卡片背景始终深色（BackgroundManager），用户若设置浅色 card_color 则需同时设置 text_color。
/// 同时读取 general.accent_color 刷新启动按钮主题色（FCL 风格主题强调色）。
- (void)applyCustomAppearance {
    // 主题强调色：刷新启动按钮背景，使用户自选的主题色立即生效
    // ★ [LAUNCHA] 改为方向自适应刷新：竖屏紧凑胶囊是「淡底 + 描边」，横屏才是实心主题色。
    //   原实现写死 accentColor() 实心底，会在竖屏把紧凑胶囊覆盖回大色块。
    [self ameApplyLaunchButtonAppearance];

    NSString *hex = getPrefObject(@"general.text_color");
    UIColor *customColor = [self colorFromHexString:hex];
    if (customColor) {
        self.usernameLabel.textColor = customColor;
        self.versionLabel.textColor = [customColor colorWithAlphaComponent:0.75];
        self.progressLabel.textColor = [customColor colorWithAlphaComponent:0.75];
        self.jitStatusLabel.textColor = customColor;
        [self.manageVersionBtn setTitleColor:customColor forState:UIControlStateNormal];
        [self.executeJarBtn setTitleColor:customColor forState:UIControlStateNormal];
    } else {
        // 未设置自定义字体颜色时，恢复系统自适应颜色
        self.usernameLabel.textColor = [UIColor labelColor];
        self.versionLabel.textColor = [UIColor secondaryLabelColor];
        self.progressLabel.textColor = [UIColor secondaryLabelColor];
        [self.manageVersionBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        [self.executeJarBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        // JIT 状态颜色由 updateJITStatus 单独管理，不在此重置
    }
}

- (nullable UIColor *)colorFromHexString:(id)hex {
    if (![hex isKindOfClass:[NSString class]] || [(NSString *)hex length] == 0) return nil;
    NSString *clean = [(NSString *)hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (clean.length != 6 && clean.length != 8) return nil;
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:clean];
    if (![scanner scanHexInt:&rgb]) return nil;
    unsigned int r, g, b, a;
    if (clean.length == 6) {
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
    return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a / 255.0];
}

- (void)showVersionPicker {
    // FCL 风格：在右侧面板弹出 ActionSheet 让用户选择已安装的版本
    NSDictionary *profiles = PLProfiles.current.profiles;
    NSArray *sortedNames = [[profiles allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSString *currentSelected = PLProfiles.current.selectedProfileName;
    
    if (sortedNames.count == 0) {
        [self showAlert:localize(@"i18n_str_423", nil) message:localize(@"i18n_str_424", nil)];
        return;
    }
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_38", nil)
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    for (NSString *profileName in sortedNames) {
        NSDictionary *profile = profiles[profileName];
        NSString *versionId = profile[@"lastVersionId"] ?: @"";
        // 检测是否启用版本隔离（gameDir != "."）
        NSString *gameDir = profile[@"gameDir"] ?: @".";
        BOOL isolated = ![gameDir isEqualToString:@"."];
        NSMutableString *title = [NSMutableString string];
        if ([profileName isEqualToString:currentSelected]) {
            [title appendString:@"✓ "];
        }
        [title appendString:profileName];
        [title appendFormat:@"  (%@)", versionId];
        if (isolated) {
            [title appendString:[@"  · " stringByAppendingString:localize(@"i18n_str_2026", nil)]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self selectProfile:profileName];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_426", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        // 跳转到版本管理页面
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowVersionManager" object:nil];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    
    // iPad 上 ActionSheet 必须指定 popoverPresentationController
    // ★ [NORIGHT] 右栏按钮已随容器下线(0×0)⇒ 拿它当锚点会让 ActionSheet 贴到屏幕原点;
    //   改用"当前顶层可见 VC 的 view 中心"作锚点(ActionSheet 的内容/选项一字不改)。
    UIViewController *norightHost = [self norightPresenter];
    UIView *norightAnchor = norightHost.view ?: self.view;
    alert.popoverPresentationController.sourceView = norightAnchor;
    alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(norightAnchor.bounds), CGRectGetMidY(norightAnchor.bounds), 1, 1);
    [norightHost presentViewController:alert animated:YES completion:nil];
}

- (void)selectProfile:(NSString *)profileName {
    PLProfiles.current.selectedProfileName = profileName;
    [PLProfiles.current save];
    // SelectedProfileChanged 通知已由 setSelectedProfileName 内部发送
    [self updateVersionInfo];
}

- (void)showVersionManager {
    // 兼容旧调用方：跳转到版本管理页面
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowVersionManager" object:nil];
}

- (void)executeJar {
    // 执行JAR功能 - 打开文件选择器选择JAR文件
    // 使用 asCopy:YES 保证文件被复制到应用沙盒，避免安全作用域 URL 导致 UZKArchive 读取失败
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[[UTType typeWithMIMEType:@"application/java-archive"]]
        asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [[self norightPresenter] presentViewController:picker animated:YES completion:nil];   // ★ [NORIGHT]
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;
    NSURL *jarURL = urls[0];
    [self enterModInstallerWithPath:jarURL.path hitEnterAfterWindowShown:NO];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
}

- (void)enterModInstallerWithPath:(NSString *)path hitEnterAfterWindowShown:(BOOL)hitEnter {
    // 关键修复（二次执行 jar 卡死）：iOS 进程内 JVM 只能创建一次
    // （gJVMUsedInProcess，第二次 JLI_Launch 会崩溃）。首次执行 jar 已在本进程
    // 创建过 JVM，再次进入 JavaGUIViewController 会黑屏卡死。因此在此处提前拦截，
    // 提示用户重启启动器，而不是进入注定失败的界面。
    if (JVMUsedInProcess()) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_214", nil)
                                                                       message:localize(@"i18n_str_1143", nil)
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_216", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [PLCrashView restartLauncher];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_217", nil) style:UIAlertActionStyleCancel handler:nil]];
        [[self norightPresenter] presentViewController:alert animated:YES completion:nil];   // ★ [NORIGHT]
        return;
    }

    JavaGUIViewController *vc = [[JavaGUIViewController alloc] init];
    vc.filepath = path;
    vc.hitEnterAfterWindowShown = hitEnter;
    // requiredJavaVersion 会读取 JAR 的 MANIFEST.MF 解析主类
    int javaVersion = vc.requiredJavaVersion;
    if (!javaVersion) {
        // JAR 解析失败：vc 还没 present，showDialog 不会显示，这里在 self 上弹明确提示
        [self showAlert:localize(@"i18n_str_427", nil)
                  message:[NSString stringWithFormat:localize(@"i18n_str_428", nil), path.lastPathComponent ?: @""]];
        return;
    }

    // execute_jar 路径：Caciocavallo17 jar 现已统一为 Java 17 编译版本，
    // Java 17/21 均可加载，不再需要强制提升 requiredJavaVersion 到 25。
    // - Java 8 JAR（如 OptiFine 安装器）走 Caciocavallo（非 17）路径，用 Java 8
    // - Java 17+ JAR 走 Caciocavallo17 路径，用 Java 17/21 即可
    // 与 JavaLauncher.m launchJar 分支保持一致。
    int requiredJavaVersion = javaVersion;

    // 预检 execute_jar 标签的 JRE 是否已配置，避免 present 后才发现没 JRE 导致黑屏
    NSString *javaHome = getSelectedJavaHome(@"execute_jar", requiredJavaVersion);
    if (!javaHome) {
        [self showAlert:localize(@"i18n_str_429", nil)
                  message:[NSString stringWithFormat:localize(@"i18n_str_222", nil), requiredJavaVersion, requiredJavaVersion]];
        return;
    }

    [self invokeAfterJITEnabled:^{
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        NSLog(@"[ModInstaller] launching %@ (Java %d, home=%@)", vc.filepath, requiredJavaVersion, javaHome);
        [[self norightPresenter] presentViewController:vc animated:YES completion:nil];   // ★ [NORIGHT]
    }];
}

/// 显示简单的提示弹窗
- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_322", nil) style:UIAlertActionStyleDefault handler:nil]];
    [[self norightPresenter] presentViewController:alert animated:YES completion:nil];   // ★ [NORIGHT]
}

#pragma mark - Launch Game

/// ZL2 风格按压动画：按下时缩放到 0.95
- (void)launchButtonTouchDown {
    [UIView animateWithDuration:0.1
                          delay:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        self.launchButton.transform = CGAffineTransformMakeScale(0.95, 0.95);
    } completion:nil];
}

/// ZL2 风格按压动画：松开时恢复到 1.0
- (void)launchButtonTouchUp {
    [UIView animateWithDuration:0.1
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.launchButton.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)launchButtonTapped {
    // 恢复按压动画（TouchUpInside 不触发 launchButtonTouchUp）
    [UIView animateWithDuration:0.1
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.launchButton.transform = CGAffineTransformIdentity;
    } completion:nil];

    if (self.task) {
        // redesign-download-ui Phase 3 Task 3.4：下载中点击启动按钮改为打开统一进度页。
        // 任务由 MinecraftResourceDownloadTask 内部注册到 DownloadTaskManager，
        // 此处按 rawTask 反查 taskId 后呈现统一进度页。
        NSString *taskId = nil;
        for (DownloadTaskItem *item in [DownloadTaskManager sharedManager].allTasks) {
            if (item.rawTask == self.task) {
                taskId = item.taskId;
                break;
            }
        }
        if (taskId) {
            [PLTaskProgressViewController presentForTaskId:taskId];
        }
    } else if ([[DownloadTaskManager sharedManager] hasActiveTasks]) {
        // 下载中仍允许启动游戏（不再硬阻断），仅提示用户有进行中的下载。
        // 原实现在此处 return 导致"开了下载球后任意下载未完成就永远无法启动游戏"，
        // 且某些下载任务状态机异常会卡住导致永久无法启动。
        [self showAlert:localize(@"i18n_str_388", nil) message:localize(@"i18n_str_430", nil)];
        [self launchGame];
    } else {
        [self launchGame];
    }
}

- (void)launchGame {
    // 下载任务不再阻断启动。某些下载（如 Mod/光影）与游戏本体启动无依赖关系，
    // 强制等待会造成"启动游戏过慢或无法启动"的体验问题。
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    if (!currentAuth) {
        // FCL 风格：无账号时跳转到账号管理界面，登录完成后自动继续启动。
        // 之前的行为是弹 alert 提示"请先登录账户"然后 return，用户需手动去登录再回来启动，
        // 体验不友好。改为设置 pendingLaunchAfterLogin 标记后发送 ShowAccountManager 通知，
        // 账号添加成功后 UpdateAccountInfo 通知回到此处时自动触发 launchGame 继续启动。
        self.pendingLaunchAfterLogin = YES;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowAccountManager" object:nil];
        return;
    }

    // 正常启动，清除待启动标记
    self.pendingLaunchAfterLogin = NO;

    NSString *selectedProfile = PLProfiles.current.selectedProfileName;
    if (!selectedProfile) {
        [self showAlert:localize(@"i18n_str_431", nil)];
        return;
    }

    NSString *versionId = PLProfiles.current.profiles[selectedProfile][@"lastVersionId"];
    if (!versionId) {
        [self showAlert:localize(@"i18n_str_43", nil)];
        return;
    }

    // FCL 风格：记录最后游玩时间戳到 profile，供版本管理页显示
    NSMutableDictionary *profiles = PLProfiles.current.profiles;
    NSMutableDictionary *profile = [profiles[selectedProfile] mutableCopy];
    if (profile) {
        profile[@"lastPlayed"] = @([[NSDate date] timeIntervalSince1970]);
        profiles[selectedProfile] = profile;
        [PLProfiles.current save];
    }

    // 设置UI为下载状态
    [self setInteractionEnabled:NO];
    
    // 查找版本对象
    NSDictionary *versionObject = nil;
    
    // 从远程版本列表中查找（通过 LauncherRootViewController 的 remoteVersionList）
    // 由于 remoteVersionList 在 LauncherRootViewController 中，我们需要通过其他方式获取
    // 这里使用通知来请求版本信息
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[@"versionId"] = versionId;
    userInfo[@"callback"] = ^(NSDictionary *version) {
        if (version) {
            [self startDownloadWithVersion:version profileName:selectedProfile];
        } else {
            // 如果在远程列表中找不到，可能是本地版本
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setInteractionEnabled:YES];
                [self showAlert:localize(@"i18n_str_432", nil)];
            });
        }
    };
    
    [[NSNotificationCenter defaultCenter] postNotificationName:@"FindVersionInRemoteList" object:nil userInfo:userInfo];
}

- (void)startDownloadWithVersion:(NSDictionary *)versionObject profileName:(NSString *)profileName {
    self.task = [MinecraftResourceDownloadTask new];

    __weak LauncherRightPanelViewController *weakSelf = self;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        weakSelf.task.handleError = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf setInteractionEnabled:YES];
                // 关键修复（UI 累积异常）：handleError 时未移除 KVO 观察者，
                // task.progress 被释放后 KVO 仍指向已释放对象，多次启动会导致野指针崩溃。
                // 现在在 task = nil 之前先移除 KVO。
                @try {
                    [weakSelf.task.progress removeObserver:weakSelf
                                                forKeyPath:@"fractionCompleted"
                                                   context:ProgressObserverContext];
                } @catch (NSException *e) {}
                weakSelf.progressView.observedProgress = nil;
                weakSelf.task = nil;
            });
        };

        [weakSelf.task downloadVersion:versionObject];

        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.progressView.observedProgress = weakSelf.task.progress;
            [weakSelf.task.progress addObserver:weakSelf
                                    forKeyPath:@"fractionCompleted"
                                       options:NSKeyValueObservingOptionInitial
                                       context:ProgressObserverContext];

            // redesign-download-ui Phase 3 Task 3.4：启动下载的进度页已由任务内部
            // 阶段上报（MinecraftResourceDownloadTask.downloadVersion: 注册任务并
            // 置 autoPresentDetail=YES）自动弹出统一进度页，此处不再手动 present 旧进度 VC。
        });
    });
}

- (void)setInteractionEnabled:(BOOL)enabled {
    self.manageVersionBtn.enabled = enabled;
    self.executeJarBtn.enabled = enabled;

    // 启动游戏的完整性检查/下载：始终显示进度（HMCL 风格进度条+文本），
    // 不再被悬浮球设置隐藏。悬浮球（球心百分比）与此处进度条互为补充，
    // 确保用户在启动前能"一模一样"地看到完整性检查进度。
    BOOL showProgressUI = YES;
    if (enabled) {
        self.progressView.hidden = YES;
        self.progressLabel.hidden = YES;
        self.progressLabel.text = @"";
    } else {
        self.progressView.hidden = !showProgressUI;
        self.progressLabel.hidden = !showProgressUI;
        self.progressLabel.text = showProgressUI ? localize(@"i18n_str_2052", nil) : @"";
    }

    UIApplication.sharedApplication.idleTimerDisabled = !enabled;
    [self updateLaunchButtonState];
}

- (void)updateLaunchButtonState {
    BOOL hasActiveTasks = [[DownloadTaskManager sharedManager] hasActiveTasks];
    BOOL hasAccount = (BaseAuthenticator.current != nil);
    NSString *selectedProfile = PLProfiles.current.selectedProfileName;
    BOOL hasVersion = selectedProfile && PLProfiles.current.profiles[selectedProfile][@"lastVersionId"] != nil;
    // FCL 风格：无账号时按钮仍可点击，点击后跳转账号管理界面（登录后自动继续启动）。
    // 之前 hasAccount 参与禁用判断导致无账号时按钮完全不可点，用户"点击启动游戏完全没有反应"。
    // 现在无账号时按钮可点，标题改为"登录并启动"提示用户点击后会先登录。
    BOOL enabled = hasVersion && !self.task;

    self.launchButton.enabled = enabled;
    NSString *title;
    if (hasActiveTasks) {
        title = localize(@"i18n_str_434", nil);
    } else if (!hasAccount) {
        title = localize(@"i18n_str_435", nil);
    } else {
        title = localize(@"i18n_str_412", nil);
    }
    [self.launchButton setTitle:title forState:UIControlStateNormal];
    [self norightPostState];   // ★ [NORIGHT] 启动键文案/可用性 → 主页底部胶囊
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != ProgressObserverContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    
    // 计算下载速度和剩余时间
    static CGFloat lastMsTime;
    static NSUInteger lastSecTime, lastCompletedUnitCount;
    NSProgress *progress = self.task.textProgress;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    NSInteger completedUnitCount = self.task.progress.totalUnitCount * self.task.progress.fractionCompleted;
    progress.completedUnitCount = completedUnitCount;
    if (lastSecTime < tv.tv_sec) {
        CGFloat currentTime = tv.tv_sec + tv.tv_usec / 1000000.0;
        NSInteger throughput = (completedUnitCount - lastCompletedUnitCount) / (currentTime - lastMsTime);
        progress.throughput = @(throughput);
        progress.estimatedTimeRemaining = @((progress.totalUnitCount - completedUnitCount) / throughput);
        lastCompletedUnitCount = completedUnitCount;
        lastSecTime = tv.tv_sec;
        lastMsTime = currentTime;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // 启动游戏的完整性检查/下载：始终显示进度（HMCL 风格进度条+文本），
        // 不再被悬浮球设置隐藏。悬浮球（球心百分比）与此处进度条互为补充，
        // 确保用户在启动前能"一模一样"地看到完整性检查进度。
        BOOL showProgressUI = YES;
        if (showProgressUI) {
            self.progressLabel.text = progress.localizedAdditionalDescription;
        }

        if (!progress.finished) return;

        // 关键修复（UI 累积异常）：进度完成时未移除 KVO 观察者，
        // 导致每次下载完成后 KVO 仍挂在已释放的 task.progress 上，多次启动累积后崩溃。
        // 现在在 task 完成（无论是否启动游戏）后立即移除 KVO。
        @try {
            [self.task.progress removeObserver:self
                                    forKeyPath:@"fractionCompleted"
                                       context:ProgressObserverContext];
        } @catch (NSException *e) {}

        self.progressView.observedProgress = nil;
        
        if (self.task.metadata) {
            // 应用配置特定的设置
            NSString *profileName = PLProfiles.current.selectedProfileName;
            NSDictionary *profile = PLProfiles.current.profiles[profileName];
            
            if (profile) {
                // 应用渲染器设置
                NSString *renderer = profile[@"renderer"] ?: @"auto";
                if (![renderer isEqualToString:@"auto"]) {
                    setPrefString(@"video.renderer", renderer);
                }

                // 应用图形 API 设置（MC 26.2+ 游戏内 OpenGL/Vulkan 切换）
                // 由 JavaLauncher.m 读取并设置 AMETHYST_GRAPHICS_API 环境变量，
                // PojavLauncher.java 写入 options.txt 的 graphicsApi 字段
                NSString *graphicsApi = profile[@"graphicsApi"];
                if (graphicsApi.length > 0) {
                    setPrefString(@"video.graphics_api", graphicsApi);
                }

                // 应用Java版本设置（兼容旧版直装器写入的 NSDictionary 格式）
                id javaVerRaw = profile[@"javaVersion"];
                NSString *javaVer = nil;
                if ([javaVerRaw isKindOfClass:[NSDictionary class]]) {
                    id major = javaVerRaw[@"majorVersion"];
                    javaVer = major ? [major description] : @"auto";
                } else if ([javaVerRaw isKindOfClass:[NSString class]]) {
                    javaVer = javaVerRaw;
                } else {
                    javaVer = @"auto";
                }
                if (![javaVer isEqualToString:@"auto"]) {
                    setPrefString(@"java.java_version", javaVer);
                }
                
                // 应用内存设置
                NSInteger allocatedMemory = [profile[@"allocatedMemory"] integerValue];
                if (allocatedMemory > 0) {
                    setPrefInt(@"general.ram_allocation", (int)allocatedMemory);
                }
            }
            
            [self invokeAfterJITEnabled:^{
                UIKit_launchMinecraftSurfaceVC(self.view.window, self.task.metadata);
            }];
        } else {
            self.task = nil;
            [self setInteractionEnabled:YES];
            // 通知刷新版本列表
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
        }
    });
}

- (void)invokeAfterJITEnabled:(void(^)(void))handler {
    BOOL hasTrollStoreJIT = getEntitlementValue(@"jb.pmap_cs.custom_trust");
    
    if (isJITEnabled(false)) {
        [ALTServerManager.sharedManager stopDiscovering];
        // TXM 机型（议题 #133）：CS_DEBUGGED 置位只证明"曾经启用过"，外部工具
        // 退出后调试器早已脱离（ppid=1、无 P_TRACED、无异常端口），此时直接启动
        // 会在 launchJVM 的 brk #0x69 上 EXC_BREAKPOINT 闪退。探针全无时先经
        // stikjit:// 把 UniversalJIT26 脚本重附加，等调试器真正存活再启动。
        if (DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM) &&
            !JIT26IsLikelyDebuggerKeepAttached() &&
            !getPrefBool(@"debug.jit26_script_disable")) {
            NSLog(@"[JIT] [RightPanel] CS_DEBUGGED set but no live JIT26 debugger (ppid=%d traced=%d exn=%d) -- re-attaching",
                  getppid(), JIT26DebuggerAttachedViaPtrace(), JIT26DebuggerViaExceptionPorts());
            [self jit_reattachJIT26ThenLaunch:handler];
            return;
        }
        NSLog(@"[JIT] [RightPanel] JIT enabled with live JIT26 debugger, launching directly");
        handler();
        return;
    } else if (hasTrollStoreJIT) {
        NSURL *jitURL = [NSURL URLWithString:[NSString stringWithFormat:@"apple-magnifier://enable-jit?bundle-id=%@", NSBundle.mainBundle.bundleIdentifier]];
        [UIApplication.sharedApplication openURL:jitURL options:@{} completionHandler:nil];
    } else if (getPrefBool(@"debug.debug_skip_wait_jit")) {
        NSLog(@"Debug option skipped waiting for JIT. Java might not work.");
        handler();
        return;
    } else if (@available(iOS 17.4, *)) {
        NSString *scriptDataString = @"";
        if (DeviceNeedsDebugJITMapping()) {
            NSData *scriptData = [NSData dataWithContentsOfFile:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
            scriptDataString = [@"&script-data=" stringByAppendingString:[scriptData base64EncodedStringWithOptions:0]];
        }
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:[NSString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@&pid=%d%@", NSBundle.mainBundle.bundleIdentifier, getpid(), scriptDataString]] options:@{} completionHandler:^(BOOL urlOK) {
            NSLog(@"[JIT] [RightPanel] openURL stikjit:// -> %d", urlOK);
            if (!urlOK) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    showDialog(localize(@"Error", nil), @"stikjit:// 无响应（未安装 StikDebug？）。请安装 StikDebug 后重试，或换用其它 JIT 开启方式。\nstikjit:// was not handled (StikDebug not installed?). Install StikDebug and retry.");
                });
            }
        }];
    } else {
        // Assuming 16.7-17.3.1. SideStore still lacks this URL scheme at the time of writing, so it only jumps to SideStore.
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:[NSString stringWithFormat:@"sidestore://sidejit-enable?pid=%d", getpid()]] options:@{} completionHandler:nil];
    }

    self.progressLabel.text = localize(@"i18n_str_436", nil);

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_437", nil)
                                                                   message:hasTrollStoreJIT ? localize(@"i18n_str_2054", nil) : localize(@"i18n_str_439", nil)
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [[self norightPresenter] presentViewController:alert animated:YES completion:nil];   // ★ [NORIGHT]

    // 后台任务断言：stikjit:// 会把 App 切后台，无断言时 iOS 立即挂起进程，
    // 等待循环被冻结、用户只能看到无限转圈。
    __block UIBackgroundTaskIdentifier jit_bgt = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"jit-wait" expirationHandler:^{}];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 有界等待 120s + 心跳日志，超时走重试弹窗（替代裸 while 死循环）。
        BOOL ok = ame169_waitForJITCondition(^{ return isJITEnabled(false); }, 120.0, @"isJITEnabled");
        // 自愈式派发：后台被楔死的主队列上续接块可能丢失，三道防线兜底。
        ame185_dispatchToMainSelfHealing(^{
            if (jit_bgt != UIBackgroundTaskInvalid) {
                [UIApplication.sharedApplication endBackgroundTask:jit_bgt];
                jit_bgt = UIBackgroundTaskInvalid;
            }
            if (ok) {
                // 后台态 dismiss 的 completion 可能悬空，completion:nil + 直接执行。
                [alert dismissViewControllerAnimated:YES completion:nil];
                // 等待成功不等于能安全启动：TXM 上调试器可能在等待期间再次脱离，
                // 存活性复查不过就重挂。
                if (DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM) &&
                    !JIT26IsLikelyDebuggerKeepAttached() &&
                    !getPrefBool(@"debug.jit26_script_disable")) {
                    NSLog(@"[JIT] [RightPanel] wait satisfied but JIT26 debugger is gone -- re-attaching before launch");
                    [self jit_reattachJIT26ThenLaunch:handler];
                } else {
                    handler();
                }
            } else {
                [alert dismissViewControllerAnimated:YES completion:nil];
                [self jit_showTimeoutRetryAlert:handler];
            }
        }, @"RightPanel main wait");
    });
}

// JIT26 调试器重挂统一助手：stikjit://（附 UniversalJIT26.js）+ 前台等待 +
// 后台断言 + 有界等调试器存活，超时走重试弹窗。
- (void)jit_reattachJIT26ThenLaunch:(void(^)(void))handler {
    self.progressLabel.text = localize(@"i18n_str_436", nil);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_437", nil)
                                                                   message:localize(@"i18n_str_439", nil)
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [[self norightPresenter] presentViewController:alert animated:YES completion:nil];   // ★ [NORIGHT]

    __block UIBackgroundTaskIdentifier jit_bgt = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"jit26-reattach" expirationHandler:^{}];

    void (^fireURL)(void) = ^{
        NSString *scriptDataString = @"";
        NSData *scriptData = [NSData dataWithContentsOfFile:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
        if (scriptData) {
            scriptDataString = [@"&script-data=" stringByAppendingString:[scriptData base64EncodedStringWithOptions:0]];
        }
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:[NSString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@&pid=%d%@", NSBundle.mainBundle.bundleIdentifier, getpid(), scriptDataString]] options:@{} completionHandler:^(BOOL urlOK) {
            NSLog(@"[JIT] [RightPanel] re-attach stikjit:// -> %d (script=%lu bytes)", urlOK, (unsigned long)scriptData.length);
        }];
    };

    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        // 后台态 openURL 无效：先等回前台再拉起（一次性监听 + 10s 兜底）。
        __block id obs = nil;
        obs = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            [[NSNotificationCenter defaultCenter] removeObserver:obs];
            obs = nil;
            fireURL();
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (obs) {
                [[NSNotificationCenter defaultCenter] removeObserver:obs];
                obs = nil;
                fireURL();
            }
        });
    } else {
        fireURL();
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 等调试器真正存活（探针），绝不用 CS_DEBUGGED（早已置位，会抢跑进首个 brk）。
        BOOL ok = ame169_waitForJITCondition(^{ return JIT26IsLikelyDebuggerKeepAttached(); }, 120.0, @"JIT26 debugger attach");
        ame185_dispatchToMainSelfHealing(^{
            if (jit_bgt != UIBackgroundTaskInvalid) {
                [UIApplication.sharedApplication endBackgroundTask:jit_bgt];
                jit_bgt = UIBackgroundTaskInvalid;
            }
            [alert dismissViewControllerAnimated:YES completion:nil];
            if (ok) {
                if (handler) handler();
            } else {
                [self jit_showTimeoutRetryAlert:handler];
            }
        }, @"RightPanel reattach wait");
    });
}

// JIT 等待超时后的出路弹窗：重试 = 重走一轮 invokeAfterJITEnabled；
// 取消 = 回到启动器，用户可手动附加调试器后重试。
- (void)jit_showTimeoutRetryAlert:(void(^)(void))handler {
    NSLog(@"[JIT] [RightPanel] JIT wait timed out, showing retry alert");
    UIAlertController *retry = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_437", nil)
                                                                   message:localize(@"jit.timeout_retry_msg", nil)
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [retry addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [retry addAction:[UIAlertAction actionWithTitle:localize(@"jit.retry", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self invokeAfterJITEnabled:handler];
    }]];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        retry.popoverPresentationController.sourceView = self.view;
        retry.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
    }
    [[self norightPresenter] presentViewController:retry animated:YES completion:nil];   // ★ [NORIGHT]
}

- (void)showAlert:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_388", nil)
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil]];
    [[self norightPresenter] presentViewController:alert animated:YES completion:nil];   // ★ [NORIGHT]
}

#pragma mark - Data Updates

- (void)updateAccountInfo {
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    if (currentAuth && currentAuth.authData) {
        NSString *username = currentAuth.authData[@"username"];
        if (username) {
            if ([username hasPrefix:@"Demo."]) {
                username = [username substringFromIndex:5];
            }
            self.usernameLabel.text = username;
        }

        // 加载头像：本地自定义头像优先，回退到在线 URL
        // 头像文件名使用 accountId（唯一标识），同名账户头像不再冲突
        UIImage *localAvatar = [[AvatarManager sharedManager] avatarForAccount:currentAuth.authData[@"accountId"]];
        if (localAvatar) {
            self.avatarImageView.image = localAvatar;
        } else {
            NSString *avatarURL = currentAuth.authData[@"profilePicURL"];
            if (avatarURL) {
                avatarURL = [avatarURL stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    NSData *imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:avatarURL]];
                    if (imageData) {
                        UIImage *image = [UIImage imageWithData:imageData];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            self.avatarImageView.image = image;
                        });
                    }
                });
            }
        }
    } else {
        self.usernameLabel.text = localize(@"i18n_str_357", nil);
        self.avatarImageView.image = [UIImage systemImageNamed:@"person.circle.fill"];
    }

    [self updateLaunchButtonState];

    // FCL 风格：若用户从"启动游戏"进来登录（pendingLaunchAfterLogin=YES），
    // 且账号已就绪，自动继续启动游戏。
    if (self.pendingLaunchAfterLogin && BaseAuthenticator.current != nil) {
        self.pendingLaunchAfterLogin = NO;
        [self launchGame];
    }
    [self norightPostState];   // ★ [NORIGHT]
}

- (void)updateVersionInfo {
    NSString *selectedProfile = PLProfiles.current.selectedProfileName;
    if (selectedProfile) {
        NSDictionary *profile = PLProfiles.current.profiles[selectedProfile];
        if (profile) {
            NSString *versionId = profile[@"lastVersionId"] ?: @"unknown";
            // 显示版本隔离状态：gameDir != "." 表示已隔离
            NSString *gameDir = profile[@"gameDir"] ?: @".";
            BOOL isolated = ![gameDir isEqualToString:@"."];
            if (isolated) {
                self.versionLabel.text = [NSString stringWithFormat:localize(@"i18n_str_440", nil), versionId];
            } else {
                self.versionLabel.text = versionId;
            }
        }
    } else {
        self.versionLabel.text = localize(@"i18n_str_411", nil);
    }

    [self updateLaunchButtonState];
    [self norightPostState];   // ★ [NORIGHT] 版本号 → 主页「欢迎回来」卡
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

#pragma mark - ★ [NORIGHT] 右栏卡片下线(新 UI 入口 → 原方法转发)

/// 收起/展开本面板内部的全部约束。
/// ★ 必须做:容器在 LauncherRootViewController 里被钉成 0×0,而本面板内部那一大组约束是
///   required(头像宽 56 / 左右 12 / 底部按钮排…),不整组停用就会刷
///   "Unable to simultaneously satisfy constraints"。
- (void)norightCollapsePanelLayout:(BOOL)collapsed {
    if (self.norightPanelCollapsed == collapsed) return;   // 幂等:状态没变直接返回
    self.norightPanelCollapsed = collapsed;
    if (collapsed) {
        [NSLayoutConstraint deactivateConstraints:self.norightPanelConstraints ?: @[]];
        [NSLayoutConstraint deactivateConstraints:self.norightExtraConstraints ?: @[]];
    } else {
        [NSLayoutConstraint activateConstraints:self.norightPanelConstraints ?: @[]];
        [NSLayoutConstraint activateConstraints:self.norightExtraConstraints ?: @[]];
    }
    for (UIView *v in self.view.subviews) { v.hidden = collapsed; }   // 视觉兜底(容器的 hidden 已在根 VC 设)
    NSLog(@"[NORIGHT] right panel collapsed=%d (panel=%lu extra=%lu)",
          collapsed,
          (unsigned long)self.norightPanelConstraints.count,
          (unsigned long)self.norightExtraConstraints.count);
}

/// ★ 新 UI 发起动作的**唯一入口**:只广播动作名,真正的实现仍是本类原来的方法
///   (见 norightHandleAction:)。这样主页/实例页不需要持有本控制器的引用。
+ (void)norightPostAction:(NSString *)action {
    if (action.length == 0) return;
    [[NSNotificationCenter defaultCenter] postNotificationName:AmeRightPanelActionNotification
                                                        object:nil
                                                      userInfo:@{@"action": action}];
}

/// 动作转发:新 UI 的每一次点击都落到**原方法**上,行为逐条不变。
- (void)norightHandleAction:(NSNotification *)note {
    NSString *action = note.userInfo[@"action"];
    if (![action isKindOfClass:[NSString class]]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([action isEqualToString:@"launch"]) {
            [self launchButtonTapped];        // ★ 原实现:账号校验 / 下载拦截 / 版本解析 / JIT / 进度页
        } else if ([action isEqualToString:@"executeJar"]) {
            [self executeJar];                // ★ 原实现:文件选择器 → enterModInstallerWithPath:
        } else if ([action isEqualToString:@"versionPicker"]) {
            [self showVersionPicker];         // ★ 原实现:版本 ActionSheet → selectProfile:
        } else if ([action isEqualToString:@"downloadCenter"]) {
            [self openDownloadCenter];        // ★ [TOPBAR2] 原实现:下载中心 FormSheet(顶栏 pill 转发)
        } else if ([action isEqualToString:@"accountManager"]) {
            [self selectAccount:nil];         // ★ 原实现:清"待启动"标记 + 发 ShowAccountManager
        } else if ([action isEqualToString:@"avatarMenu"]) {
            [self showAvatarMenu:nil];        // ★ 原实现:导入/清除自定义头像菜单
        } else {
            NSLog(@"[NORIGHT] unknown action: %@", action);
        }
    });
}

/// 外部索取状态(主页 viewWillAppear 会发一次)⇒ 实时重算 JIT 后广播。
- (void)norightHandleStateRequest:(NSNotification *)note {
    [self norightBroadcastState];
}

/// 广播当前状态(版本号 / JIT 文本与颜色 / 用户名 / 启动键标题与可用性)。
/// 主页欢迎卡(版本号)、顶栏 JIT pill、底部启动胶囊全靠它保持与右栏原逻辑同源。
- (void)norightBroadcastState {
    [self updateJITStatus];            // 实时重算(内部也会 norightPostState 一次)
    [self updateDownloadCenterButton]; // ★ [TOPBAR2] 顺带刷新下载中心角标/百分比(内部也会 norightPostState)
    [self norightPostState];           // 其余字段补齐
}

- (void)norightPostState {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (self.versionLabel.text)  info[@"version"] = self.versionLabel.text;
    if (self.usernameLabel.text) info[@"user"]    = self.usernameLabel.text;
    if (self.jitStatusLabel.text)      info[@"jit"]      = self.jitStatusLabel.text;
    if (self.jitStatusLabel.textColor) info[@"jitColor"] = self.jitStatusLabel.textColor;
    NSString *title = [self.launchButton titleForState:UIControlStateNormal];
    if (title) info[@"launchTitle"] = title;
    info[@"launchEnabled"] = @(self.launchButton.enabled);
    // ★ [TOPBAR2] 下载中心状态:数值**直接取自**本类原按钮的 badge/progress 标签,不重算、不复制。
    //   顶栏「下载中心」pill 只做展示,与右栏原按钮永远同口径。
    info[@"dcActive"]   = @(!self.downloadCenterButton.hidden);
    info[@"dcBadge"]    = self.downloadCenterBadgeLabel.hidden ? @"" : (self.downloadCenterBadgeLabel.text ?: @"");
    info[@"dcProgress"] = self.downloadCenterProgressLabel.text ?: @"";
    [[NSNotificationCenter defaultCenter] postNotificationName:AmeRightPanelStateNotification
                                                        object:nil
                                                      userInfo:info];
}

/// ★ present 宿主:容器已 0×0 + hidden,自身不再是可靠的呈现宿主。
///   统一取"窗口里当前最顶层的可见 VC" —— 弹出的内容 / 顺序 / delegate 回调全部不变。
- (UIViewController *)norightPresenter {
    UIViewController *host = self.view.window.rootViewController ?: self;
    NSUInteger guard = 0;
    while (guard++ < 16) {
        UIViewController *next = host.presentedViewController;
        if (next) { host = next; continue; }
        if ([host isKindOfClass:[UITabBarController class]]) {
            UIViewController *sel = [(UITabBarController *)host selectedViewController];
            if (sel && sel != host) { host = sel; continue; }
        }
        if ([host isKindOfClass:[UINavigationController class]]) {
            UIViewController *top = [(UINavigationController *)host topViewController];
            if (top && top != host) { host = top; continue; }
        }
        break;
    }
    return host;
}

@end
