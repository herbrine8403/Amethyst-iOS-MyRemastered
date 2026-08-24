#import "LauncherRightPanelViewController.h"
#import "authenticator/BaseAuthenticator.h"
#import "AccountListViewController.h"
#import "SurfaceViewController.h"
#import "JavaGUIViewController.h"
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

// 添加 C 函数声明 - 这些函数在 LauncherPreferences.m 或其他地方定义
extern void setPrefString(NSString *key, NSString *value);
extern void setPrefInt(NSString *key, NSInteger value);

static void *ProgressObserverContext = &ProgressObserverContext;

@interface LauncherRightPanelViewController () <UIDocumentPickerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>

@property(nonatomic, strong) UIImageView *avatarImageView;
@property(nonatomic, strong) UILabel *usernameLabel;
@property(nonatomic, strong) UILabel *versionLabel;
@property(nonatomic, strong) UIButton *launchButton;
@property(nonatomic, strong) UIButton *manageVersionBtn;
@property(nonatomic, strong) UIButton *executeJarBtn;
// JIT 状态指示标签（启动游戏按钮上方）
@property(nonatomic, strong) UILabel *jitStatusLabel;

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
    [NSLayoutConstraint activateConstraints:@[
        // 头像（顶部）
        [self.avatarImageView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
        [self.avatarImageView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.avatarImageView.widthAnchor constraintEqualToConstant:72],
        [self.avatarImageView.heightAnchor constraintEqualToConstant:72],

        // 用户名
        [self.usernameLabel.topAnchor constraintEqualToAnchor:self.avatarImageView.bottomAnchor constant:8],
        [self.usernameLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.usernameLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        // 版本
        [self.versionLabel.topAnchor constraintEqualToAnchor:self.usernameLabel.bottomAnchor constant:4],
        [self.versionLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.versionLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        // 进度标签
        [self.progressLabel.topAnchor constraintEqualToAnchor:self.versionLabel.bottomAnchor constant:8],
        [self.progressLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.progressLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        // 进度条
        [self.progressView.topAnchor constraintEqualToAnchor:self.progressLabel.bottomAnchor constant:4],
        [self.progressView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.progressView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        // ===== 下载中心入口按钮（进度条下方）=====
        // 当有下载任务时显示，点击弹出 DownloadTasksViewController（参照 FCL/ZL2/HMCL 下载进度弹窗）
        [self.downloadCenterButton.topAnchor constraintEqualToAnchor:self.progressView.bottomAnchor constant:8],
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
        [self.executeJarBtn.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
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
        [self.launchButton.bottomAnchor constraintEqualToAnchor:self.executeJarBtn.topAnchor constant:-8],
        [self.launchButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.launchButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.launchButton.heightAnchor constraintEqualToConstant:46],

        // JIT 状态标签（启动按钮上方）
        [self.jitStatusLabel.bottomAnchor constraintEqualToAnchor:self.launchButton.topAnchor constant:-8],
        [self.jitStatusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.jitStatusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.jitStatusLabel.heightAnchor constraintEqualToConstant:20],
    ]];

    // 进度条底部需留出空间避免与下方 JIT 标签重叠（弱约束，允许中间留白）
    [NSLayoutConstraint constraintWithItem:self.jitStatusLabel
                                attribute:NSLayoutAttributeTop
                                relatedBy:NSLayoutRelationGreaterThanOrEqual
                                   toItem:self.progressView
                                attribute:NSLayoutAttributeBottom
                               multiplier:1.0
                                 constant:12].active = YES;
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
    UIViewController *topVC = self;
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }

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
}

#pragma mark - 自定义头像导入

- (void)showAvatarMenu:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

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
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.avatarImageView;
        sheet.popoverPresentationController.sourceRect = self.avatarImageView.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
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
    [self presentViewController:picker animated:YES completion:nil];
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
                    [weakSelf dismissViewControllerAnimated:YES completion:^{
                        if (croppedImage) {
                            [weakSelf saveAvatarImage:croppedImage];
                        }
                    }];
                };
                // 本 VC 为 child view controller，self.navigationController 可能为 nil，
                // 故用 present 方式呈现裁剪器（包装在 NavigationController 中以保留其导航栏样式）
                UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:cropperVC];
                nav.modalPresentationStyle = UIModalPresentationFullScreen;
                [self presentViewController:nav animated:YES completion:nil];
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
    if (enabled) {
        self.jitStatusLabel.text = localize(@"i18n_str_421", nil);
        self.jitStatusLabel.textColor = [UIColor colorWithRed:0.2 green:0.7 blue:0.3 alpha:1.0];
        self.jitStatusLabel.backgroundColor = [[UIColor colorWithRed:0.2 green:0.7 blue:0.3 alpha:1.0] colorWithAlphaComponent:0.15];
    } else {
        self.jitStatusLabel.text = localize(@"i18n_str_422", nil);
        self.jitStatusLabel.textColor = [UIColor colorWithRed:0.9 green:0.4 blue:0.3 alpha:1.0];
        self.jitStatusLabel.backgroundColor = [[UIColor colorWithRed:0.9 green:0.4 blue:0.3 alpha:1.0] colorWithAlphaComponent:0.15];
    }
}

#pragma mark - 自定义外观（字体颜色）

/// 读取 general.text_color 偏好并应用到右侧面板的主要文字。
/// 卡片背景始终深色（BackgroundManager），用户若设置浅色 card_color 则需同时设置 text_color。
/// 同时读取 general.accent_color 刷新启动按钮主题色（FCL 风格主题强调色）。
- (void)applyCustomAppearance {
    // 主题强调色：刷新启动按钮背景，使用户自选的主题色立即生效
    self.launchButton.backgroundColor = accentColor();

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
    alert.popoverPresentationController.sourceView = self.manageVersionBtn;
    alert.popoverPresentationController.sourceRect = self.manageVersionBtn.bounds;
    [self presentViewController:alert animated:YES completion:nil];
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
    [self presentViewController:picker animated:YES completion:nil];
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
        [self presentViewController:vc animated:YES completion:nil];
    }];
}

/// 显示简单的提示弹窗
- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_322", nil) style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
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
                // renderer / graphicsApi 由 JavaLauncher 直接从当前 profile 解析。
                // 不再写回全局偏好，避免启动一个档案后污染其他继承全局设置的档案。

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
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:[NSString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@&pid=%d%@", NSBundle.mainBundle.bundleIdentifier, getpid(), scriptDataString]] options:@{} completionHandler:nil];
    } else {
        // Assuming 16.7-17.3.1. SideStore still lacks this URL scheme at the time of writing, so it only jumps to SideStore.
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:[NSString stringWithFormat:@"sidestore://sidejit-enable?pid=%d", getpid()]] options:@{} completionHandler:nil];
    }
    
    self.progressLabel.text = localize(@"i18n_str_436", nil);
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_437", nil)
                                                                   message:hasTrollStoreJIT ? localize(@"i18n_str_2054", nil) : localize(@"i18n_str_439", nil)
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:nil];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (!isJITEnabled(false)) {
            usleep(1000 * 200);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:handler];
        });
    });
}

- (void)showAlert:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_388", nil)
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
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
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

@end
