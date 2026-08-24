#import "ProfileSettingsViewController.h"
#import "ModsManagerViewController.h"
#import "ShadersManagerViewController.h"
#import "ResourcePacksManagerViewController.h"
#import "DataPacksManagerViewController.h"
#import "WorldsManagerViewController.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "LauncherNavigationController.h" // for localVersionList/remoteVersionList
#import "MinecraftResourceUtils.h"
#import "installer/modpack/ModrinthAPI.h"
#import "ModVersion.h"
#import "ios_uikit_bridge.h" // for showDialog
#import "utils.h"
#import "BackgroundManager.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "PLTaskStages.h"
#import "ModpackExportService.h" // for parseVersionId:

@interface ProfileSettingsViewController () <UITextFieldDelegate, UIPickerViewDataSource, UIPickerViewDelegate>

@property (nonatomic, strong) NSArray<NSArray *> *sections;
@property (nonatomic, strong) NSString *selectedRenderer;
@property (nonatomic, strong) NSString *selectedGraphicsApi;  // MC 26.2+ 图形 API: default/prefer_vulkan/prefer_opengl
@property (nonatomic, strong) NSString *selectedJavaVersion;
@property (nonatomic, assign) NSInteger allocatedMemory;
@property (nonatomic, assign) NSInteger maxMemory;
// 服务器地址（FCL 风格：留空则不自动加入）
@property (nonatomic, strong) NSString *serverIp;
// JVM 启动参数（如 -Dfoo=bar -Xnoclassgc 等；Xms/Xmx/d32/d64 由内存分配控制会被过滤）
@property (nonatomic, strong) NSString *javaArgs;
// JVM 参数输入框
@property (nonatomic, strong) UITextField *javaArgsTextField;
// 版本选择器
@property (nonatomic, strong) UITextField *versionTextField;
@property (nonatomic, strong) UITextField *nameTextField;
@property (nonatomic, strong) UISegmentedControl *versionTypeControl;
@property (nonatomic, strong) UIPickerView *versionPickerView;
@property (nonatomic, strong) UIToolbar *versionPickerToolbar;
@property (nonatomic, strong) NSArray *versionList;
@property (nonatomic, assign) NSInteger versionSelectedAt;
// 原始名称，用于重命名检测
@property (nonatomic, copy) NSString *originalName;
// Hero 卡片（顶部 Profile 信息卡片）
@property (nonatomic, strong, nullable) UIView *heroCard;

// 双列 tableView（横屏双列布局）
// leftTableView：竖屏时显示所有 sections（0-4）；横屏时只显示 sections 0,1（版本信息、资源管理）
// rightTableView：仅横屏时显示，显示 sections 2,3,4（组件安装、高级设置、服务器）
@property (nonatomic, strong, nullable) UITableView *leftTableView;
@property (nonatomic, strong, nullable) UITableView *rightTableView;
// Hero 卡片容器（包含 heroCard，作为 leftTableView 的 tableHeaderView）
@property (nonatomic, strong, nullable) UIView *heroContainer;

@end

// 已汉化/英化的行标题显示映射：模块标题在 self.sections 中仍保留中文作为逻辑键（isEqualToString 比较），
// 仅在渲染 cell 时翻译为界面语言。若命中的键不存在会回退为标题本身。
static NSString * localizeProfileTitle(NSString *title) {
    static NSDictionary *map = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"渲染器": @"preference.title.renderer",
            @"图形 API": @"i18n_str_2057",
            @"Java版本": @"i18n_str_2036",
            @"内存分配": @"i18n_str_2037",
            @"JVM 启动参数": @"preference.title.java_args",
            @"清除JVM参数": @"i18n_str_2038",
            @"名称": @"preference.profile.title.name",
            @"游戏版本": @"i18n_str_2031",
            @"游戏目录": @"preference.title.game_directory",
            @"模组管理": @"i18n_str_2039",
            @"光影管理": @"i18n_str_2016",
            @"资源包管理": @"i18n_str_2040",
            @"数据包管理": @"i18n_str_2041",
            @"世界管理": @"i18n_str_2042",
            @"Fabric API": @"Fabric API",
            @"OptiFine": @"OptiFine",
        };
    });
    NSString *key = map[title] ?: title;
    return localize(key, nil);
}

@implementation ProfileSettingsViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    // 如果只传了 profileName 没传 profile，从 PLProfiles 加载
    if (!self.profile && self.profileName) {
        self.profile = [PLProfiles.current.profiles[self.profileName] mutableCopy];
        if (!self.profile) {
            self.profile = [NSMutableDictionary dictionary];
            self.profile[@"name"] = self.profileName;
        }
    }
    // 安全网：如果调用方既没传 profileName 也没传 profile，创建空字典避免后续 nil 写入
    if (!self.profile) {
        self.profile = [NSMutableDictionary dictionary];
    }

    // 确保 profile 有 name 字段
    self.originalName = self.profile[@"name"];
    if ([self.originalName length] == 0) {
        self.originalName = self.profileName ?: @"New Profile";
        self.profile[@"name"] = self.originalName;
    }

    self.title = [NSString stringWithFormat:localize(@"i18n_str_863", nil), self.originalName];

    // 导航栏按钮
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(actionDone)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];

    // 设置表格（双列布局：leftTableView 主表格，rightTableView 仅横屏时显示）
    // UIViewController 的 self.view 是容器视图，包含两个 tableView
    self.leftTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.leftTableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.leftTableView.dataSource = self;
    self.leftTableView.delegate = self;
    self.leftTableView.backgroundColor = [UIColor clearColor];
    // 使用 Automatic 让系统自动避开导航栏（修复内容上移被导航栏遮挡）
    // 配合 edgesForExtendedLayout = UIRectEdgeAll 让背景延伸到导航栏后方
    self.leftTableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    [self.view addSubview:self.leftTableView];

    self.rightTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.rightTableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.rightTableView.dataSource = self;
    self.rightTableView.delegate = self;
    self.rightTableView.backgroundColor = [UIColor clearColor];
    self.rightTableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    self.rightTableView.hidden = YES; // 默认隐藏，横屏时显示
    [self.view addSubview:self.rightTableView];

    // 适配自定义启动器背景：透明背景让底层背景毛玻璃透出。
    // 两条进入路径（push 和 showProfileEditor modal）都使用 clearColor，
    // 统一由 BackgroundManager 管理背景效果。
    // 适配自定义启动器背景：给 tableView 设置毛玻璃 backgroundView，遮挡栈底 VC 内容。
    // 修复"点击版本管理进入版本设置后前一页面未及时消失"问题：
    // 若 tableView 完全透明，push 后会透出栈底 VersionManagerViewController 的卡片，造成"前一页未消失"。
    // 这里给 backgroundView 设置 UIVisualEffectView（毛玻璃），既能模糊并透出全局背景图，
    // 又能遮挡栈底 VC 内容，同时保持视觉一致性。
    [self applyBackgroundBlurToTableView];
    // 适配自定义启动器背景：导航栏毛玻璃 + 视图透明
    if (self.navigationController) {
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
    }
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.extendedLayoutIncludesOpaqueBars = YES;
    self.edgesForExtendedLayout = UIRectEdgeAll;

    // 计算最大内存
    [self calculateMaxMemory];

    // 加载设置
    [self loadSettings];

    // 设置版本选择器
    [self setupVersionPicker];

    // 设置分区
    [self setupSections];

    // 顶部 Hero 卡片（Profile 名 + 当前版本 pill + 游戏目录）
    [self setupHeroCard];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleBackgroundUIEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadVersionList)
                                                 name:@"ReloadProfileList"
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 修复"前一个页面没有及时消失"：viewDidLoad 时 tableView.bounds 可能为 zero，
    // 导致 applyBackgroundBlurToTableView 设置的 backgroundView frame 为 zero，
    // push 转场初期无法遮挡栈底 VersionManagerViewController 的内容。
    // 在 viewWillAppear 中重新应用，此时 bounds 已正确，确保转场前遮挡到位。
    [self applyBackgroundBlurToTableView];
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    // 横竖屏切换时，重新计算 tableHeaderView（Hero 卡片）的高度，并切换双列布局
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        // 切换 rightTableView 的显示状态（横屏时显示）
        BOOL landscape = size.width > size.height;
        self.rightTableView.hidden = !landscape;

        // 重新计算 Hero 卡片高度（仅 leftTableView 显示 Hero 卡片）
        UIView *header = self.leftTableView.tableHeaderView;
        if (header) {
            // 横屏时 leftTableView 宽度是总宽度的一半（减去间距）
            CGFloat headerWidth = landscape ? (size.width / 2.0 - 8.0) : size.width;
            header.frame = CGRectMake(0, 0, headerWidth, 0);
            [header setNeedsLayout];
            [header layoutIfNeeded];
            CGFloat fittingHeight = [header systemLayoutSizeFittingSize:CGSizeMake(headerWidth, 0)
                                                    withHorizontalFittingPriority:UILayoutPriorityRequired
                                                          verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
            header.frame = CGRectMake(0, 0, headerWidth, fittingHeight);
            self.leftTableView.tableHeaderView = header;
        }

        // 重新加载两个 tableView 的数据（visible sections 会根据方向变化）
        [self.leftTableView reloadData];
        [self.rightTableView reloadData];
    } completion:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        // 转场完成后再次应用背景模糊（frame 已稳定）
        [self applyBackgroundBlurToTableView];
    }];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    [self layoutDualTableViews];
}

/// 布局双列 tableView
/// - 竖屏：leftTableView 占满整个 view，rightTableView 隐藏
/// - 横屏：leftTableView 占左半部分，rightTableView 占右半部分，中间 16pt 间距
- (void)layoutDualTableViews {
    CGRect bounds = self.view.bounds;
    BOOL landscape = [self isLandscape];

    if (landscape) {
        // 横屏双列布局
        CGFloat spacing = 16.0;
        CGFloat halfWidth = (bounds.size.width - spacing) / 2.0;
        self.leftTableView.frame = CGRectMake(0, 0, halfWidth, bounds.size.height);
        self.rightTableView.frame = CGRectMake(halfWidth + spacing, 0, halfWidth, bounds.size.height);
        self.rightTableView.hidden = NO;
    } else {
        // 竖屏单列布局
        self.leftTableView.frame = bounds;
        self.rightTableView.hidden = YES;
    }

    // 重新计算 Hero 卡片（tableHeaderView）的宽度和高度
    [self relayoutHeroHeader];

    // 同步背景模糊视图的 frame
    [self syncBackgroundBlurFrames];
}

/// 重新计算 Hero 卡片（tableHeaderView）的宽度和高度
- (void)relayoutHeroHeader {
    UIView *header = self.leftTableView.tableHeaderView;
    if (!header) return;
    CGFloat width = self.leftTableView.bounds.size.width;
    if (width == 0) return;
    header.frame = CGRectMake(0, 0, width, 0);
    [header setNeedsLayout];
    [header layoutIfNeeded];
    CGFloat fittingHeight = [header systemLayoutSizeFittingSize:CGSizeMake(width, 0)
                                            withHorizontalFittingPriority:UILayoutPriorityRequired
                                                  verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    header.frame = CGRectMake(0, 0, width, fittingHeight);
    self.leftTableView.tableHeaderView = header;
}

/// 同步 leftTableView 和 rightTableView 的 backgroundView frame
- (void)syncBackgroundBlurFrames {
    for (UITableView *tv in @[self.leftTableView, self.rightTableView]) {
        if (!tv || tv.hidden) continue;
        if (tv.backgroundView) {
            tv.backgroundView.frame = tv.bounds;
        }
    }
}

- (void)reloadVersionList {
    self.versionList = nil;
    self.versionSelectedAt = -1;
    if (self.versionPickerView && self.versionPickerView.window) {
        [self changeVersionType:nil];
    }
}

#pragma mark - Hero Card

/// 顶部 Hero 卡片：Profile 名 + 当前版本 pill + 游戏目录（Air-Design v1.2 L3 大卡片）
- (void)setupHeroCard {
    // ===== Hero 卡片容器（L3：16pt 圆角 + 半透明背景 + 毛玻璃 + 浅边框 + 中阴影）=====
    UIView *heroCard = [[UIView alloc] init];
    heroCard.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.14]; // surface-bright
    heroCard.layer.cornerRadius = 16;
    heroCard.layer.cornerCurve = kCACornerCurveContinuous;
    heroCard.layer.borderWidth = 0.5;
    heroCard.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    heroCard.layer.shadowColor = [UIColor blackColor].CGColor;
    heroCard.layer.shadowOpacity = 0.12;
    heroCard.layer.shadowRadius = 8;
    heroCard.layer.shadowOffset = CGSizeMake(0, 3);
    [[BackgroundManager sharedManager] applyEffectToView:heroCard];

    // ===== Hero 图标（56x56，14pt 圆角，accentColor 背景，白色 cube.fill SF Symbol）=====
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.image = [UIImage systemImageNamed:@"cube.fill"];
    iconView.tintColor = [UIColor whiteColor];
    iconView.contentMode = UIViewContentModeCenter;
    iconView.backgroundColor = accentColor();
    iconView.layer.cornerRadius = 14;
    iconView.layer.cornerCurve = kCACornerCurveContinuous;
    iconView.layer.masksToBounds = YES;
    [heroCard addSubview:iconView];

    // ===== 标题（Profile 名，17pt bold，labelColor）=====
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = self.profile[@"name"] ?: self.originalName ?: @"New Profile";
    titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    titleLabel.textColor = [UIColor labelColor];
    titleLabel.adjustsFontSizeToFitWidth = YES;
    titleLabel.minimumScaleFactor = 0.8;
    [heroCard addSubview:titleLabel];

    // ===== 版本 pill（11pt bold，绿底白字，checkmark.circle.fill + 版本号）=====
    UIView *versionPill = [[UIView alloc] init];
    versionPill.backgroundColor = [UIColor systemGreenColor];
    versionPill.layer.cornerRadius = 9;
    versionPill.layer.cornerCurve = kCACornerCurveContinuous;
    versionPill.layer.masksToBounds = YES;
    [heroCard addSubview:versionPill];

    UIImageView *pillIcon = [[UIImageView alloc] init];
    pillIcon.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
    pillIcon.tintColor = [UIColor whiteColor];
    pillIcon.contentMode = UIViewContentModeScaleAspectFit;
    [versionPill addSubview:pillIcon];

    UILabel *pillLabel = [[UILabel alloc] init];
    NSString *currentVersion = self.profile[@"lastVersionId"];
    pillLabel.text = currentVersion.length > 0 ? currentVersion : localize(@"i18n_str_864", nil);
    pillLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    pillLabel.textColor = [UIColor whiteColor];
    pillLabel.adjustsFontSizeToFitWidth = YES;
    pillLabel.minimumScaleFactor = 0.7;
    [versionPill addSubview:pillLabel];

    // ===== 副标题（游戏目录，12pt regular，secondaryLabelColor）=====
    UILabel *subtitleLabel = [[UILabel alloc] init];
    NSString *gameDir = self.profile[@"gameDir"] ?: @".";
    NSString *instanceName = getPrefObject(@"general.game_directory") ?: @"default";
    subtitleLabel.text = [NSString stringWithFormat:@"%@ → /instances/%@", gameDir, instanceName];
    subtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.adjustsFontSizeToFitWidth = YES;
    subtitleLabel.minimumScaleFactor = 0.7;
    [heroCard addSubview:subtitleLabel];

    self.heroCard = heroCard;

    // ===== 布局：使用 container 包装，设置为 tableHeaderView =====
    UIView *container = [[UIView alloc] init];
    [container addSubview:heroCard];

    heroCard.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    versionPill.translatesAutoresizingMaskIntoConstraints = NO;
    pillIcon.translatesAutoresizingMaskIntoConstraints = NO;
    pillLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    [NSLayoutConstraint activateConstraints:@[
        // heroCard：左右 16pt 外边距，上下 8pt
        [heroCard.topAnchor constraintEqualToAnchor:container.topAnchor constant:8],
        [heroCard.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [heroCard.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [heroCard.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8],

        // iconView：56x56，左侧 16pt，上下 16pt
        [iconView.leadingAnchor constraintEqualToAnchor:heroCard.leadingAnchor constant:16],
        [iconView.topAnchor constraintEqualToAnchor:heroCard.topAnchor constant:16],
        [iconView.bottomAnchor constraintEqualToAnchor:heroCard.bottomAnchor constant:-16],
        [iconView.widthAnchor constraintEqualToConstant:56],
        [iconView.heightAnchor constraintEqualToConstant:56],

        // titleLabel：iconView 右侧 14pt，顶部 16pt
        [titleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:14],
        [titleLabel.topAnchor constraintEqualToAnchor:heroCard.topAnchor constant:16],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:heroCard.trailingAnchor constant:-16],

        // versionPill：titleLabel 下方 4pt，高度 18pt，左侧对齐 titleLabel
        [versionPill.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [versionPill.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:4],
        [versionPill.heightAnchor constraintEqualToConstant:18],

        // pillIcon：8x8，左侧 6pt，垂直居中
        [pillIcon.leadingAnchor constraintEqualToAnchor:versionPill.leadingAnchor constant:6],
        [pillIcon.centerYAnchor constraintEqualToAnchor:versionPill.centerYAnchor],
        [pillIcon.widthAnchor constraintEqualToConstant:10],
        [pillIcon.heightAnchor constraintEqualToConstant:10],

        // pillLabel：紧跟 pillIcon 右侧 2pt，右侧 6pt，垂直居中
        [pillLabel.leadingAnchor constraintEqualToAnchor:pillIcon.trailingAnchor constant:2],
        [pillLabel.centerYAnchor constraintEqualToAnchor:versionPill.centerYAnchor],
        [pillLabel.trailingAnchor constraintEqualToAnchor:versionPill.trailingAnchor constant:-6],

        // subtitleLabel：versionPill 下方 4pt，底部 16pt
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [subtitleLabel.topAnchor constraintEqualToAnchor:versionPill.bottomAnchor constant:4],
        [subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:heroCard.trailingAnchor constant:-16],
        [subtitleLabel.bottomAnchor constraintEqualToAnchor:heroCard.bottomAnchor constant:-16],
    ]];

    // 手动计算 container 高度并设置 tableHeaderView
    CGFloat width = self.leftTableView.bounds.size.width;
    if (width == 0) width = [UIScreen mainScreen].bounds.size.width;
    container.frame = CGRectMake(0, 0, width, 0);
    [container setNeedsLayout];
    [container layoutIfNeeded];
    CGFloat fittingHeight = [container systemLayoutSizeFittingSize:CGSizeMake(width, 0)
                                               withHorizontalFittingPriority:UILayoutPriorityRequired
                                                     verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    container.frame = CGRectMake(0, 0, width, fittingHeight);
    self.heroContainer = container;
    self.leftTableView.tableHeaderView = container;
}

/// 更新 Hero 卡片内容（用户修改名称/版本后调用）
- (void)updateHeroCard {
    if (!self.heroCard) return;
    // 遍历 heroCard 子视图找到 titleLabel/versionPill/subtitleLabel 并更新
    for (UIView *sub in self.heroCard.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)sub;
            // 通过字体特征区分：17pt bold = 标题；12pt regular = 副标题；11pt bold = 版本 pill label
            if (label.font.pointSize >= 16) {
                label.text = self.profile[@"name"] ?: self.originalName ?: @"New Profile";
            } else if (label.font.pointSize <= 11) {
                NSString *currentVersion = self.profile[@"lastVersionId"];
                label.text = currentVersion.length > 0 ? currentVersion : localize(@"i18n_str_864", nil);
            } else {
                NSString *gameDir = self.profile[@"gameDir"] ?: @".";
                NSString *instanceName = getPrefObject(@"general.game_directory") ?: @"default";
                label.text = [NSString stringWithFormat:@"%@ → /instances/%@", gameDir, instanceName];
            }
        }
    }
}

#pragma mark - Memory

- (void)calculateMaxMemory {
    long long totalMemory = [NSProcessInfo processInfo].physicalMemory;
    self.maxMemory = (NSInteger)(totalMemory / (1024 * 1024));
    self.maxMemory = (NSInteger)(self.maxMemory * 0.8);
    if (self.maxMemory < 1024) {
        self.maxMemory = 1024;
    }
}

#pragma mark - Load Settings

- (void)loadSettings {
    // 渲染器
    id profileRenderer = self.profile[@"renderer"];
    self.selectedRenderer = ([profileRenderer isKindOfClass:[NSString class]] &&
                             [(NSString *)profileRenderer length] > 0)
        ? PLNormalizeRendererKey(profileRenderer)
        : @"(default)";

    // 图形 API（MC 26.2+ 游戏内 OpenGL/Vulkan 切换）
    id profileGraphicsApi = self.profile[@"graphicsApi"];
    self.selectedGraphicsApi = ([profileGraphicsApi isKindOfClass:[NSString class]] &&
                                [(NSString *)profileGraphicsApi length] > 0)
        ? profileGraphicsApi
        : @"(default)";

    // Java版本（兼容旧版直装器写入的 NSDictionary 格式）
    id javaVerRaw = self.profile[@"javaVersion"];
    if ([javaVerRaw isKindOfClass:[NSDictionary class]]) {
        id major = javaVerRaw[@"majorVersion"];
        self.selectedJavaVersion = major ? [major description] : @"0";
    } else {
        self.selectedJavaVersion = [javaVerRaw isKindOfClass:[NSString class]] ? javaVerRaw : @"0";
    }

    // 内存分配 (MB)
    self.allocatedMemory = [self.profile[@"allocatedMemory"] integerValue];
    if (self.allocatedMemory == 0) {
        self.allocatedMemory = MIN(self.maxMemory / 2, 2048);
    }
    if (self.allocatedMemory > self.maxMemory) {
        self.allocatedMemory = self.maxMemory;
    }

    // 服务器地址（默认空字符串，留空不自动加入）
    NSString *profName = self.profile[@"name"] ?: self.profileName;
    self.serverIp = [PLProfiles.current serverIpForProfile:profName] ?: @"";

    // JVM 启动参数：参照 main 分支，仅读取 profile 自身字段；
    // 为空时 UI 显示 "(default)" placeholder，实际启动时由 PLProfiles.resolveKeyForCurrentProfile
    // 回退到全局 java.java_args（见 JavaLauncher.init_loadCustomJvmFlags）。
    id rawArgs = self.profile[@"javaArgs"];
    if ([rawArgs isKindOfClass:[NSString class]]) {
        self.javaArgs = rawArgs;
    } else {
        self.javaArgs = @"";
    }
}

#pragma mark - Sections

- (void)setupSections {
    // 高级设置 section：渲染器 + 图形 API（仅 MC 26.2+）+ Java/内存/JVM
    NSMutableArray *advancedRows = [NSMutableArray arrayWithArray:@[@"渲染器"]];
    if ([self isCurrentProfileModernVersion]) {
        [advancedRows addObject:@"图形 API"];
    }
    [advancedRows addObjectsFromArray:@[@"Java版本", @"内存分配", @"JVM 启动参数", @"清除JVM参数"]];

    // 重构（Air-Design v1.2）：5 个 Bento 分组
    // 顺序与横屏布局对应：左侧（0,1）+ 右侧（2,3,4）
    //   0: 版本信息  - 名称 / 游戏版本 / 游戏目录
    //   1: 资源管理  - 模组 / 光影 / 资源包 / 数据包 / 世界
    //   2: 组件安装  - Fabric API / OptiFine
    //   3: 高级设置  - 渲染器 / 图形 API / Java / 内存 / JVM 参数
    //   4: 服务器    - 服务器地址
    self.sections = @[
        @[@"名称", @"游戏版本", @"游戏目录"],
        @[@"模组管理", @"光影管理", @"资源包管理", @"数据包管理", @"世界管理"],
        @[@"Fabric API", @"OptiFine"],
        [advancedRows copy],
        @[localize(@"i18n_str_730", nil)]
    ];
}

#pragma mark - Dual Table View Helpers

/// 是否处于横屏（宽度 > 高度）
- (BOOL)isLandscape {
    CGSize size = self.view.bounds.size;
    return size.width > size.height;
}

/// 返回指定 tableView 显示的全局 section 索引数组
/// - leftTableView：竖屏时显示所有 sections (0,1,2,3,4)；横屏时只显示 (0,1)
/// - rightTableView：仅横屏时显示 (2,3,4)
- (NSArray<NSNumber *> *)visibleSectionsForTableView:(UITableView *)tableView {
    if (tableView == self.rightTableView) {
        return @[@2, @3, @4];
    }
    // leftTableView
    if ([self isLandscape]) {
        return @[@0, @1];
    }
    return @[@0, @1, @2, @3, @4];
}

/// 将 tableView 的本地 section 索引转换为全局 section 索引
- (NSInteger)globalSectionForTableView:(UITableView *)tableView localSection:(NSInteger)localSection {
    NSArray<NSNumber *> *visible = [self visibleSectionsForTableView:tableView];
    if (localSection < 0 || localSection >= (NSInteger)visible.count) return -1;
    return visible[localSection].integerValue;
}

/// 主 tableView（用于与外部代码交互，如 Hero 卡片、背景模糊等）
- (UITableView *)mainTableView {
    return self.leftTableView;
}

/// 重新加载所有 tableView 的数据
- (void)reloadAllTableViews {
    [self.leftTableView reloadData];
    if (self.rightTableView && !self.rightTableView.hidden) {
        [self.rightTableView reloadData];
    }
}

/// 根据全局 section 和 row 查找 cell（用于 popover sourceView 等）
/// 遍历 leftTableView 和 rightTableView，找到包含该全局 section 的 tableView
- (UITableViewCell *)cellForGlobalSection:(NSInteger)globalSection row:(NSInteger)row {
    // 检查 leftTableView
    NSArray<NSNumber *> *leftVisible = [self visibleSectionsForTableView:self.leftTableView];
    NSInteger leftLocal = [leftVisible indexOfObject:@(globalSection)];
    if (leftLocal != NSNotFound) {
        NSIndexPath *ip = [NSIndexPath indexPathForRow:row inSection:leftLocal];
        return [self.leftTableView cellForRowAtIndexPath:ip];
    }
    // 检查 rightTableView
    if (self.rightTableView && !self.rightTableView.hidden) {
        NSArray<NSNumber *> *rightVisible = [self visibleSectionsForTableView:self.rightTableView];
        NSInteger rightLocal = [rightVisible indexOfObject:@(globalSection)];
        if (rightLocal != NSNotFound) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:row inSection:rightLocal];
            return [self.rightTableView cellForRowAtIndexPath:ip];
        }
    }
    return nil;
}

#pragma mark - Save

- (void)saveSettings {
    // 仅保存渲染器/Java/内存/服务器等设置项，不处理重命名
    // 重命名逻辑在 actionDone 中处理
    // 注意：必须使用 originalName 作为 key，且不能把用户正在编辑的 name 写入 PLProfiles
    // 否则用户改名后关闭（不点 Done），PLProfiles 中的 profile.name 会变成新名但 key 仍是旧名
    NSString *profName = self.originalName ?: self.profile[@"name"];
    if (!profName) return;

    // 保存用户正在编辑的字段（name 和 lastVersionId 可能在编辑中，尚未确认）
    NSString *userInputName = self.profile[@"name"];
    NSString *userInputVersion = self.profile[@"lastVersionId"];

    NSMutableDictionary *existing = [PLProfiles.current.profiles[profName] mutableCopy];
    if (!existing) {
        existing = [NSMutableDictionary dictionary];
    }
    if ([self.selectedRenderer isEqualToString:@"(default)"]) {
        [existing removeObjectForKey:@"renderer"];
    } else {
        existing[@"renderer"] = PLNormalizeRendererKey(self.selectedRenderer);
    }
    if ([self.selectedGraphicsApi isEqualToString:@"(default)"]) {
        [existing removeObjectForKey:@"graphicsApi"];
    } else {
        existing[@"graphicsApi"] = self.selectedGraphicsApi;
    }
    existing[@"javaVersion"] = self.selectedJavaVersion;
    existing[@"allocatedMemory"] = @(self.allocatedMemory);
    existing[@"serverIp"] = self.serverIp ?: @"";
    // 参照 main 分支：javaArgs 为空时移除 key，让 profile 回退到全局 java.java_args
    if (self.javaArgs.length > 0) {
        existing[@"javaArgs"] = self.javaArgs;
    } else {
        [existing removeObjectForKey:@"javaArgs"];
    }
    // 保存游戏目录（版本隔离用）：gameDir 为 nil 时默认 "."，与 main 分支行为一致
    existing[@"gameDir"] = self.profile[@"gameDir"] ?: @".";
    // existing 中的 name 和 lastVersionId 字段保持原始值不变
    PLProfiles.current.profiles[profName] = existing;
    [PLProfiles.current save];

    // 同步到 working copy（深拷贝，避免与 PLProfiles 共享对象）
    // 恢复用户正在编辑的 name 和 lastVersionId，这样 actionDone 仍能拿到用户改的值
    self.profile = [existing mutableCopy];
    if (userInputName.length > 0) {
        self.profile[@"name"] = userInputName;
    }
    if (userInputVersion.length > 0) {
        self.profile[@"lastVersionId"] = userInputVersion;
    }
}

#pragma mark - Table View Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return [[self visibleSectionsForTableView:tableView] count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSInteger globalSection = [self globalSectionForTableView:tableView localSection:section];
    if (globalSection < 0 || globalSection >= (NSInteger)self.sections.count) return 0;
    return [self.sections[globalSection] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSInteger globalSection = [self globalSectionForTableView:tableView localSection:section];
    switch (globalSection) {
        case 0: return localize(@"i18n_str_289", nil);
        case 1: return localize(@"i18n_str_877", nil);
        case 2: return localize(@"i18n_str_878", nil);
        case 3: return localize(@"i18n_str_879", nil);
        case 4: return localize(@"i18n_str_880", nil);
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    NSInteger globalSection = [self globalSectionForTableView:tableView localSection:section];
    if (globalSection == 0) {
        return localize(@"i18n_str_881", nil);
    }
    if (globalSection == 2) {
        return localize(@"i18n_str_882", nil);
    }
    if (globalSection == 4) {
        return localize(@"i18n_str_883", nil);
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellIdentifier = @"SettingsCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cellIdentifier];
        [[BackgroundManager sharedManager] applyEffectToCell:cell];
    }

    // 重置复用 cell 的状态
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.imageView.image = nil;
    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;
    // 重置可能被"清除JVM参数"修改过的颜色
    cell.imageView.tintColor = nil;
    cell.textLabel.textColor = [UIColor labelColor];

    NSInteger globalSection = [self globalSectionForTableView:tableView localSection:indexPath.section];
    if (globalSection < 0 || globalSection >= (NSInteger)self.sections.count) return cell;

    NSString *title = self.sections[globalSection][indexPath.row];
    cell.textLabel.text = localizeProfileTitle(title);

    switch (globalSection) {
        case 0: // 版本信息
            if ([title isEqualToString:@"名称"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"tag"];
                cell.accessoryView = [self buildNameTextField];
            } else if ([title isEqualToString:@"游戏版本"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"archivebox"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.accessoryView = [self buildVersionTextField];
                cell.detailTextLabel.text = nil;
            } else if ([title isEqualToString:@"游戏目录"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"folder"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                NSString *gameDir = self.profile[@"gameDir"] ?: @".";
                cell.detailTextLabel.text = gameDir;
            }
            break;

        case 1: // 资源管理
            if ([title isEqualToString:@"模组管理"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"puzzlepiece.fill"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            } else if ([title isEqualToString:@"光影管理"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"paintbrush.fill"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            } else if ([title isEqualToString:@"资源包管理"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"rectangle.stack.fill"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            } else if ([title isEqualToString:@"数据包管理"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"shippingbox.fill"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            } else if ([title isEqualToString:@"世界管理"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"globe.asia.australia.fill"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
            break;

        case 2: // 组件安装
            if ([title isEqualToString:@"Fabric API"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"bolt.fill"];
                cell.imageView.tintColor = [UIColor systemOrangeColor];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.detailTextLabel.text = [self isFabricProfile] ? localize(@"i18n_str_2043", nil) : localize(@"i18n_str_885", nil);
            } else if ([title isEqualToString:@"OptiFine"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"speedometer"];
                cell.imageView.tintColor = [UIColor systemRedColor];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.detailTextLabel.text = [self isOptiFineCompatibleProfile] ? localize(@"i18n_str_2043", nil) : localize(@"i18n_str_886", nil);
            }
            break;

        case 3: // 高级设置
            if ([title isEqualToString:@"渲染器"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"cpu"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.detailTextLabel.text = [self rendererDisplayName:self.selectedRenderer];
            } else if ([title isEqualToString:@"图形 API"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"rectangle.dashed"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.detailTextLabel.text = [self graphicsApiDisplayName:self.selectedGraphicsApi];
            } else if ([title isEqualToString:@"Java版本"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"j.square"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.detailTextLabel.text = [self.selectedJavaVersion isEqualToString:@"0"] ? localize(@"preference.auto", nil) : [NSString stringWithFormat:@"Java %@", self.selectedJavaVersion];
            } else if ([title isEqualToString:@"内存分配"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"memorychip"];
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld MB / %ld MB", (long)self.allocatedMemory, (long)self.maxMemory];
            } else if ([title isEqualToString:@"JVM 启动参数"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"slider.vertical.3"];
                cell.accessoryView = [self buildJavaArgsTextField];
                cell.detailTextLabel.text = nil;
            } else if ([title isEqualToString:@"清除JVM参数"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"trash"];
                cell.imageView.tintColor = [UIColor systemRedColor];
                cell.textLabel.textColor = [UIColor systemRedColor];
                cell.detailTextLabel.text = self.javaArgs.length > 0 ? localize(@"i18n_str_2044", nil) : localize(@"i18n_str_889", nil);
            }
            break;

        case 4: // 服务器地址（FCL 风格）
            cell.imageView.image = [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"];
            cell.accessoryView = [self buildServerIpTextField];
            break;
    }

    return cell;
}

#pragma mark - 名称输入框

- (UITextField *)buildNameTextField {
    // 复用已有 textField
    if (self.nameTextField) {
        // 检查是否已被其他 cell 持有（复用机制下需要重新添加）
        if (!self.nameTextField.superview || self.nameTextField.superview == self.view) {
            return self.nameTextField;
        }
    }
    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 200, 30)];
    textField.placeholder = localize(@"i18n_str_890", nil);
    textField.text = self.profile[@"name"];
    textField.font = [UIFont systemFontOfSize:14];
    textField.adjustsFontSizeToFitWidth = YES;
    textField.minimumFontSize = 10;
    textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    textField.returnKeyType = UIReturnKeyDone;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textField.textAlignment = NSTextAlignmentRight;
    textField.tag = 1001;
    textField.delegate = self;
    [textField addTarget:self action:@selector(nameTextFieldChanged:) forControlEvents:UIControlEventEditingChanged];
    [textField addTarget:self action:@selector(nameTextFieldDidEnd:) forControlEvents:UIControlEventEditingDidEnd];
    self.nameTextField = textField;
    return textField;
}

- (void)nameTextFieldChanged:(UITextField *)textField {
    self.profile[@"name"] = textField.text ?: @"";
    [self updateHeroCard];
}

- (void)nameTextFieldDidEnd:(UITextField *)textField {
    NSString *trimmed = [textField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    self.profile[@"name"] = trimmed;
    textField.text = trimmed;
    [self updateHeroCard];
}

#pragma mark - 版本选择器

- (void)setupVersionPicker {
    self.versionPickerView = [[UIPickerView alloc] init];
    self.versionPickerView.delegate = self;
    self.versionPickerView.dataSource = self;

    self.versionPickerToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, 44)];
    self.versionTypeControl = [[UISegmentedControl alloc] initWithItems:@[
        localize(@"i18n_str_891", nil), localize(@"i18n_str_2058", nil), localize(@"i18n_str_1288", nil), @"Old-beta", @"Old-alpha"
    ]];
    [self.versionTypeControl addTarget:self action:@selector(changeVersionType:) forControlEvents:UIControlEventValueChanged];
    self.versionPickerToolbar.items = @[
        [[UIBarButtonItem alloc] initWithCustomView:self.versionTypeControl],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(versionClosePicker)]
    ];

    // 自动选择版本类型
    NSString *currentVersion = self.profile[@"lastVersionId"];
    if (currentVersion) {
        if ([MinecraftResourceUtils findVersion:currentVersion inList:localVersionList]) {
            self.versionTypeControl.selectedSegmentIndex = 0;
        } else {
            NSDictionary *selected = (id)[MinecraftResourceUtils findVersion:currentVersion inList:remoteVersionList];
            if (selected) {
                NSArray *types = @[@"installed", @"release", @"snapshot", @"old_beta", @"old_alpha"];
                NSString *type = selected[@"type"];
                self.versionTypeControl.selectedSegmentIndex = [types indexOfObject:type];
                if (self.versionTypeControl.selectedSegmentIndex == NSNotFound) {
                    self.versionTypeControl.selectedSegmentIndex = 0;
                }
            } else {
                self.versionTypeControl.selectedSegmentIndex = 0;
            }
        }
    } else {
        self.versionTypeControl.selectedSegmentIndex = 0;
    }
    self.versionSelectedAt = -1;
}

- (UITextField *)buildVersionTextField {
    if (self.versionTextField) {
        if (!self.versionTextField.superview || self.versionTextField.superview == self.view) {
            return self.versionTextField;
        }
    }
    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 200, 30)];
    textField.text = self.profile[@"lastVersionId"] ?: @"";
    textField.font = [UIFont systemFontOfSize:13];
    textField.adjustsFontSizeToFitWidth = YES;
    textField.minimumFontSize = 9;
    textField.textAlignment = NSTextAlignmentRight;
    textField.tag = 1002;
    textField.delegate = self;
    textField.inputView = self.versionPickerView;
    textField.inputAccessoryView = self.versionPickerToolbar;
    [textField addTarget:self action:@selector(versionTextFieldDidEnd:) forControlEvents:UIControlEventEditingDidEnd];
    self.versionTextField = textField;

    // 初始化版本列表
    [self changeVersionType:nil];
    return textField;
}

- (void)versionTextFieldDidEnd:(UITextField *)textField {
    // 更新 profile 中的版本
    self.profile[@"lastVersionId"] = textField.text ?: @"";
}

- (void)versionClosePicker {
    [self.versionTextField endEditing:YES];
    [self pickerView:self.versionPickerView didSelectRow:[self.versionPickerView selectedRowInComponent:0] inComponent:0];
}

- (void)changeVersionType:(UISegmentedControl *)sender {
    NSArray *newVersionList = self.versionList;
    if (sender || !self.versionList) {
        if (self.versionTypeControl.selectedSegmentIndex == 0) {
            // nil 安全：启动器刚启动时 localVersionList 可能尚未加载
            newVersionList = localVersionList ?: @[];
        } else {
            NSString *type = @[@"installed", @"release", @"snapshot", @"old_beta", @"old_alpha"][self.versionTypeControl.selectedSegmentIndex];
            // nil 安全：remoteVersionList 为 nil 时用空数组，避免 filteredArrayUsingPredicate 崩溃
            NSArray *remote = remoteVersionList ?: @[];
            newVersionList = [remote filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"(type == %@)", type]];
        }
    }

    if (self.versionSelectedAt == -1) {
        NSDictionary *selected = (id)[MinecraftResourceUtils findVersion:self.versionTextField.text inList:newVersionList];
        self.versionSelectedAt = [newVersionList indexOfObject:selected];
    } else {
        NSObject *lastSelected = nil;
        if (self.versionList.count > self.versionSelectedAt) {
            lastSelected = self.versionList[self.versionSelectedAt];
        }
        if (lastSelected != nil) {
            NSObject *nearest = [MinecraftResourceUtils findNearestVersion:lastSelected expectedType:self.versionTypeControl.selectedSegmentIndex];
            if (nearest != nil) {
                self.versionSelectedAt = [newVersionList indexOfObject:(id)nearest];
            }
        }
        self.versionSelectedAt = MIN(labs(self.versionSelectedAt), (NSInteger)newVersionList.count - 1);
    }

    self.versionList = newVersionList;
    [self.versionPickerView reloadAllComponents];
    if (self.versionSelectedAt != -1 && self.versionSelectedAt < (NSInteger)newVersionList.count) {
        [self.versionPickerView selectRow:self.versionSelectedAt inComponent:0 animated:NO];
        [self pickerView:self.versionPickerView didSelectRow:self.versionSelectedAt inComponent:0];
    }
}

#pragma mark - UIPickerView DataSource/Delegate

- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pickerView {
    return 1;
}

- (NSInteger)pickerView:(UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component {
    return self.versionList.count;
}

- (NSString *)pickerView:(UIPickerView *)pickerView titleForRow:(NSInteger)row forComponent:(NSInteger)component {
    if (self.versionList.count <= row) return nil;
    NSObject *object = self.versionList[row];
    if ([object isKindOfClass:[NSString class]]) {
        return (NSString *)object;
    } else {
        return [object valueForKey:@"id"];
    }
}

- (void)pickerView:(UIPickerView *)pickerView didSelectRow:(NSInteger)row inComponent:(NSInteger)component {
    if (self.versionList.count == 0) {
        self.versionTextField.text = @"";
        return;
    }
    self.versionSelectedAt = row;
    self.versionTextField.text = [self pickerView:pickerView titleForRow:row forComponent:component];
    self.profile[@"lastVersionId"] = self.versionTextField.text;
    [self updateHeroCard];
}

#pragma mark - 服务器地址输入框

- (UITextField *)buildServerIpTextField {
    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 220, 30)];
    textField.placeholder = localize(@"i18n_str_893", nil);
    textField.text = self.serverIp;
    textField.font = [UIFont systemFontOfSize:13];
    textField.adjustsFontSizeToFitWidth = YES;
    textField.minimumFontSize = 9;
    textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    textField.returnKeyType = UIReturnKeyDone;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textField.keyboardType = UIKeyboardTypeURL;
    textField.tag = 9527;
    textField.delegate = self;
    [textField addTarget:self action:@selector(serverIpTextFieldEditingChanged:) forControlEvents:UIControlEventEditingChanged];
    [textField addTarget:self action:@selector(serverIpTextFieldEditingDidEnd:) forControlEvents:UIControlEventEditingDidEnd];
    return textField;
}

#pragma mark - JVM 启动参数输入框

- (UITextField *)buildJavaArgsTextField {
    if (self.javaArgsTextField) {
        if (!self.javaArgsTextField.superview || self.javaArgsTextField.superview == self.view) {
            return self.javaArgsTextField;
        }
    }
    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 200, 30)];
    // 参照 main 分支 LauncherProfileEditorViewController：placeholder 为 "(default)"，
    // 表示未设置时回退到全局 java.java_args。
    textField.placeholder = @"(default)";
    // 仅当 profile 显式设置了 javaArgs 时才显示，否则留空显示 placeholder
    textField.text = self.profile[@"javaArgs"] ?: @"";
    textField.font = [UIFont systemFontOfSize:13];
    textField.adjustsFontSizeToFitWidth = YES;
    textField.minimumFontSize = 9;
    textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    textField.returnKeyType = UIReturnKeyDone;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textField.tag = 1003;
    textField.delegate = self;
    [textField addTarget:self action:@selector(javaArgsTextFieldEditingChanged:) forControlEvents:UIControlEventEditingChanged];
    [textField addTarget:self action:@selector(javaArgsTextFieldEditingDidEnd:) forControlEvents:UIControlEventEditingDidEnd];
    self.javaArgsTextField = textField;
    return textField;
}

- (void)javaArgsTextFieldEditingChanged:(UITextField *)textField {
    self.javaArgs = textField.text ?: @"";
}

- (void)javaArgsTextFieldEditingDidEnd:(UITextField *)textField {
    // 参照 main 分支：空串或 "(default)" 视为未设置，保存时移除 key 以回退全局 java.java_args
    NSString *trimmed = [textField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (trimmed.length == 0 || [trimmed isEqualToString:@"(default)"]) {
        self.javaArgs = @"";
        textField.text = @"";
    } else {
        self.javaArgs = trimmed;
        textField.text = trimmed;
    }
    [self saveSettings];
}

/// 一键清除当前版本已设置的 JVM 启动参数
- (void)clearJavaArgs {
    if (self.javaArgs.length == 0) {
        UIAlertController *tip = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_388", nil)
                                                                     message:localize(@"i18n_str_894", nil)
                                                              preferredStyle:UIAlertControllerStyleAlert];
        [tip addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:tip animated:YES completion:nil];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_895", nil)
                                                                   message:localize(@"i18n_str_896", nil)
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_77", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        self.javaArgs = @"";
        self.javaArgsTextField.text = @"";
        [self saveSettings];
        [self reloadAllTableViews];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2.0, self.view.bounds.size.height / 2.0, 1, 1);
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)serverIpTextFieldEditingChanged:(UITextField *)textField {
    self.serverIp = textField.text ?: @"";
}

- (void)serverIpTextFieldEditingDidEnd:(UITextField *)textField {
    self.serverIp = [textField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    textField.text = self.serverIp;
    [self saveSettings];
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

#pragma mark - Helpers

- (NSString *)rendererDisplayName:(NSString *)renderer {
    NSArray *keys = getRendererKeys(YES);
    NSArray *names = getRendererNames(YES);
    NSUInteger idx = [keys indexOfObject:renderer];
    if (idx != NSNotFound && idx < names.count) {
        return names[idx];
    }
    return renderer ?: @"auto";
}

- (NSString *)currentProfileName {
    return self.profile[@"name"] ?: self.profileName;
}

#pragma mark - Table View Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSInteger globalSection = [self globalSectionForTableView:tableView localSection:indexPath.section];
    if (globalSection < 0 || globalSection >= (NSInteger)self.sections.count) return;

    NSString *title = self.sections[globalSection][indexPath.row];

    switch (globalSection) {
        case 0: // 版本信息
            if ([title isEqualToString:@"名称"]) {
                // 聚焦名称输入框
                if (self.nameTextField) [self.nameTextField becomeFirstResponder];
            } else if ([title isEqualToString:@"游戏版本"]) {
                // 聚焦版本选择器
                if (self.versionTextField) [self.versionTextField becomeFirstResponder];
            } else if ([title isEqualToString:@"游戏目录"]) {
                [self editGameDir];
            }
            break;

        case 1: // 资源管理
            if ([title isEqualToString:@"模组管理"]) {
                [self openModsManager];
            } else if ([title isEqualToString:@"光影管理"]) {
                [self openShadersManager];
            } else if ([title isEqualToString:@"资源包管理"]) {
                [self openResourcePacksManager];
            } else if ([title isEqualToString:@"数据包管理"]) {
                [self openDataPacksManager];
            } else if ([title isEqualToString:@"世界管理"]) {
                [self openWorldsManager];
            }
            break;

        case 2: // 组件安装
            if ([title isEqualToString:@"Fabric API"]) {
                [self installFabricAPIStandalone];
            } else if ([title isEqualToString:@"OptiFine"]) {
                [self installOptiFineStandalone];
            }
            break;

        case 3: // 高级设置
            if ([title isEqualToString:@"渲染器"]) {
                [self showRendererSelector];
            } else if ([title isEqualToString:@"图形 API"]) {
                [self showGraphicsApiSelector];
            } else if ([title isEqualToString:@"Java版本"]) {
                [self showJavaVersionSelector];
            } else if ([title isEqualToString:@"内存分配"]) {
                [self showMemoryAllocator];
            } else if ([title isEqualToString:@"JVM 启动参数"]) {
                if (self.javaArgsTextField) [self.javaArgsTextField becomeFirstResponder];
            } else if ([title isEqualToString:@"清除JVM参数"]) {
                [self clearJavaArgs];
            }
            break;

        case 4: // 服务器地址
            [self focusTextFieldInCellAtIndexPath:indexPath inTableView:tableView];
            break;
    }
}

- (void)focusTextFieldInCellAtIndexPath:(NSIndexPath *)indexPath inTableView:(UITableView *)tableView {
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (!cell) return;
    UITextField *textField = [self findTextFieldInView:cell.contentView];
    if ([textField canBecomeFirstResponder]) {
        [textField becomeFirstResponder];
    }
}

- (UITextField *)findTextFieldInView:(UIView *)view {
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UITextField class]]) {
            return (UITextField *)sub;
        }
        UITextField *found = [self findTextFieldInView:sub];
        if (found) return found;
    }
    return nil;
}

#pragma mark - Actions

/// 编辑游戏目录（仿 main 分支 LauncherProfileEditorViewController 的 gameDir 文本框）
/// gameDir="." 表示使用当前 POJAV_GAME_DIR（即"游戏目录切换"选中的实例目录）
/// 也可以输入相对路径（相对于 POJAV_GAME_DIR）或绝对路径来实现版本隔离
- (void)editGameDir {
    NSString *currentGameDir = self.profile[@"gameDir"] ?: @".";
    NSString *currentInstance = getPrefObject(@"general.game_directory") ?: @"default";

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"i18n_str_2004", nil)
                         message:[NSString stringWithFormat:
                                  [[[localize(@"i18n_str_897", nil)
                                      stringByAppendingString:localize(@"i18n_str_2010", nil)]
                                     stringByAppendingString:localize(@"i18n_str_2011", nil)]
                                    stringByAppendingString:localize(@"i18n_str_2012", nil)],
                                  currentInstance]
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = currentGameDir;
        textField.placeholder = [NSString stringWithFormat:@". -> /Documents/instances/%@", currentInstance];
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_898", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        self.profile[@"gameDir"] = @".";
        [self saveSettings];
        [self reloadAllTableViews];
        [self updateHeroCard];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *newGameDir = alert.textFields.firstObject.text;
        newGameDir = [newGameDir stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (newGameDir.length == 0) {
            newGameDir = @".";
        }
        self.profile[@"gameDir"] = newGameDir;
        [self saveSettings];
        [self reloadAllTableViews];
        [self updateHeroCard];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openModsManager {
    ModsManagerViewController *vc = [[ModsManagerViewController alloc] init];
    vc.profileName = [self currentProfileName];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openShadersManager {
    ShadersManagerViewController *vc = [[ShadersManagerViewController alloc] init];
    vc.profileName = [self currentProfileName];
    vc.initialMode = ShadersManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openResourcePacksManager {
    ResourcePacksManagerViewController *vc = [[ResourcePacksManagerViewController alloc] init];
    vc.profileName = [self currentProfileName];
    vc.initialMode = ResourcePacksManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openDataPacksManager {
    DataPacksManagerViewController *vc = [[DataPacksManagerViewController alloc] init];
    vc.profileName = [self currentProfileName];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openWorldsManager {
    WorldsManagerViewController *vc = [[WorldsManagerViewController alloc] init];
    vc.profileName = [self currentProfileName];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - 组件独立安装（Fabric API / OptiFine）

- (BOOL)isFabricProfile {
    NSString *lastVersionId = self.profile[@"lastVersionId"];
    if (![lastVersionId isKindOfClass:[NSString class]] || lastVersionId.length == 0) return NO;
    // Fabric profile id 形如 "fabric-loader-0.16.0-1.21"，含 "fabric"
    // Quilt profile id 含 "quilt"
    return [lastVersionId.lowercaseString containsString:@"fabric"];
}

- (BOOL)isOptiFineCompatibleProfile {
    return [self isVanillaProfile] || [self isForgeProfile];
}

/// 是否为原版 (Vanilla) profile
/// lastVersionId 不含 forge/fabric/quilt/neoforge 等加载器标识
- (BOOL)isVanillaProfile {
    NSString *lastVersionId = self.profile[@"lastVersionId"];
    if (![lastVersionId isKindOfClass:[NSString class]] || lastVersionId.length == 0) return NO;
    NSString *lower = lastVersionId.lowercaseString;
    return ![lower containsString:@"forge"]
        && ![lower containsString:@"fabric"]
        && ![lower containsString:@"quilt"];
}

/// 是否为 Forge profile（排除 NeoForge）
/// 关键修复：原先用 `containsString:@"forge"` 会误判 neoforge 为 forge，
/// 现显式排除 neoforge（参照 FCL/HMCL 的 OptiFine 兼容性判断）
- (BOOL)isForgeProfile {
    NSString *lastVersionId = self.profile[@"lastVersionId"];
    if (![lastVersionId isKindOfClass:[NSString class]] || lastVersionId.length == 0) return NO;
    NSString *lower = lastVersionId.lowercaseString;
    return [lower containsString:@"forge"] && ![lower containsString:@"neoforge"];
}

/// 当前 profile 的 mods 目录路径
- (NSString *)currentProfileModsPath {
    NSString *gameDir = self.profile[@"gameDir"];
    NSString *baseDir;
    const char *env = getenv("POJAV_GAME_DIR");
    if (env) {
        baseDir = [NSString stringWithUTF8String:env];
    } else {
        baseDir = NSHomeDirectory();
    }

    NSString *modsBase;
    if ([gameDir isKindOfClass:[NSString class]] && gameDir.length > 0 && ![gameDir isEqualToString:@"."]) {
        if ([gameDir isAbsolutePath]) {
            modsBase = gameDir;
        } else {
            modsBase = [baseDir stringByAppendingPathComponent:gameDir];
        }
    } else {
        modsBase = baseDir;
    }

    NSString *modsDir = [modsBase stringByAppendingPathComponent:@"mods"];
    [[NSFileManager defaultManager] createDirectoryAtPath:modsDir withIntermediateDirectories:YES attributes:nil error:nil];
    return modsDir;
}

/// 当前 profile 的游戏版本（从 lastVersionId 解析）
- (NSString *)currentGameVersion {
    NSString *lastVersionId = self.profile[@"lastVersionId"];
    if (![lastVersionId isKindOfClass:[NSString class]] || lastVersionId.length == 0) return nil;
    // 解析 loader 前的游戏版本：1.21.1-forge-47.3.0 → 1.21.1
    // fabric-loader-0.16.0-1.21 → 1.21
    NSArray<NSString *> *loaders = @[@"forge", @"fabric", @"neoforge", @"quilt", @"fabric-loader"];
    NSString *result = lastVersionId;
    for (NSString *loader in loaders) {
        NSString *delimiter = [NSString stringWithFormat:@"-%@-", loader];
        NSRange range = [result rangeOfString:delimiter options:NSCaseInsensitiveSearch];
        if (range.location != NSNotFound) {
            result = [result substringToIndex:range.location];
            break;
        }
        // 处理 "fabric-loader-0.16.0-1.21" 形式：取最后一个版本号
        if ([result.lowercaseString hasPrefix:[NSString stringWithFormat:@"%@-", loader]]) {
            // fabric-loader-0.16.0-1.21 → 取最后的 "1.21"
            NSArray *parts = [result componentsSeparatedByString:@"-"];
            if (parts.count >= 2) {
                // 找到形如 1.x.x 的部分
                for (NSString *part in [parts reverseObjectEnumerator]) {
                    if ([part hasPrefix:@"1."]) {
                        return part;
                    }
                }
            }
        }
    }
    return result;
}

- (void)installFabricAPIStandalone {
    if (![self isFabricProfile]) {
        [self showComponentAlert:localize(@"i18n_str_899", nil)
                          message:localize(@"i18n_str_900", nil)];
        return;
    }

    NSString *gameVersion = [self currentGameVersion];
    if (!gameVersion) {
        [self showComponentAlert:localize(@"i18n_str_899", nil) message:localize(@"i18n_str_901", nil)];
        return;
    }

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_902", nil)
                                                                     message:[NSString stringWithFormat:localize(@"i18n_str_903", nil), gameVersion, gameVersion]
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_904", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self startInstallFabricAPIWithGameVersion:gameVersion];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)installOptiFineStandalone {
    if (![self isOptiFineCompatibleProfile]) {
        [self showComponentAlert:localize(@"i18n_str_899", nil)
                          message:localize(@"i18n_str_905", nil)];
        return;
    }

    NSString *gameVersion = [self currentGameVersion];
    if (!gameVersion) {
        [self showComponentAlert:localize(@"i18n_str_899", nil) message:localize(@"i18n_str_901", nil)];
        return;
    }

    // 关键修复（参照 FCL/HMCL OptiFine 安装流程）：
    //   - Vanilla profile: 必须以版本补丁方式安装（launchwrapper + tweakClass），
    //     仅把 jar 放进 mods/ 目录对原版完全无效，因为原版没有 mods 加载机制。
    //   - Forge profile: Forge 可作为 mod 加载 OptiFine jar，沿用 mods/ 方式。
    BOOL isVanilla = [self isVanillaProfile];
    NSString *message = nil;
    if (isVanilla) {
        NSString *fmt = [[[[[localize(@"i18n_str_906", nil)
                              stringByAppendingString:localize(@"i18n_str_907", nil)]
                             stringByAppendingString:localize(@"i18n_str_2006", nil)]
                            stringByAppendingString:localize(@"i18n_str_2007", nil)]
                           stringByAppendingString:localize(@"i18n_str_2008", nil)]
                          stringByAppendingString:localize(@"i18n_str_911", nil)];
        message = [NSString stringWithFormat:fmt, gameVersion, gameVersion, gameVersion];
    } else {
        NSString *fmt = [[localize(@"i18n_str_906", nil)
                          stringByAppendingString:localize(@"i18n_str_912", nil)]
                         stringByAppendingString:localize(@"i18n_str_913", nil)];
        message = [NSString stringWithFormat:fmt, gameVersion, gameVersion];
    }

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_914", nil)
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_904", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        if (isVanilla) {
            [self startInstallOptiFineAsPatch:gameVersion];
        } else {
            [self startInstallOptiFineWithGameVersion:gameVersion];
        }
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)showComponentAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_322", nil) style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (UIAlertController *)showProgressAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    indicator.translatesAutoresizingMaskIntoConstraints = NO;
    [alert.view addSubview:indicator];
    [NSLayoutConstraint activateConstraints:@[
        [indicator.centerXAnchor constraintEqualToAnchor:alert.view.centerXAnchor],
        [indicator.centerYAnchor constraintEqualToAnchor:alert.view.centerYAnchor constant:20]
    ]];
    [indicator startAnimating];
    [self presentViewController:alert animated:YES completion:nil];
    return alert;
}

- (void)startInstallFabricAPIWithGameVersion:(NSString *)gameVersion {
    // redesign-download-ui Phase 4 Task 4.4：Fabric API 安装注册为统一下载任务，
    // PLTaskStagesSingleFile 单阶段 + autoPresentDetail 自动弹出统一进度页
    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    DownloadTaskItem *taskItem = [manager
        registerTaskWithResourceType:DownloadTaskResourceTypeMod
                        resourceName:[NSString stringWithFormat:@"fabric-api-%@", gameVersion]
                         displayName:@"Fabric API"
                      downloadSource:@"modrinth"
                             rawTask:nil
                      supportsResume:NO
                             iconURL:nil];
    NSString *taskId = taskItem.taskId;
    if (taskItem) {
        [[DownloadTaskManager sharedManager] setTaskWithId:taskId stages:PLTaskStagesSingleFile()];
        taskItem.autoPresentDetail = YES;
        [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateDownloading];
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                 stageAtIndex:0
                                                       status:PLTaskStageStatusRunning];
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                 stageAtIndex:0
                                                     progress:-1.0
                                                      message:[NSString stringWithFormat:localize(@"i18n_str_915", nil), gameVersion]];
    }

    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"query"] = @"fabric api";
    filters[@"limit"] = @"20";

    __weak typeof(self) weakSelf = self;
    [[ModrinthAPI sharedInstance] searchModWithFilters:filters completion:^(NSArray *results, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (error || results.count == 0) {
                NSError *failError = [NSError errorWithDomain:@"FabricAPI" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_916", nil), error.localizedDescription ?: localize(@"i18n_str_917", nil)]}];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                [strongSelf showComponentAlert:localize(@"i18n_str_918", nil) message:[NSString stringWithFormat:localize(@"i18n_str_916", nil), error.localizedDescription ?: localize(@"i18n_str_917", nil)]];
                return;
            }

            // 找到标题包含 "fabric api" 且不包含 "kotlin" 的项目
            NSDictionary *fabricAPI = nil;
            for (NSDictionary *mod in results) {
                NSString *title = mod[@"title"] ?: @"";
                if ([title.lowercaseString containsString:@"fabric api"] && ![title.lowercaseString containsString:@"kotlin"]) {
                    fabricAPI = mod;
                    break;
                }
            }
            if (!fabricAPI) {
                NSError *failError = [NSError errorWithDomain:@"FabricAPI" code:2 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_919", nil)}];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                [strongSelf showComponentAlert:localize(@"i18n_str_918", nil) message:localize(@"i18n_str_919", nil)];
                return;
            }

            [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                     stageAtIndex:0
                                                         progress:-1.0
                                                          message:localize(@"i18n_str_920", nil)];

            [[ModrinthAPI sharedInstance] getVersionsForModWithID:fabricAPI[@"id"] completion:^(NSArray<ModVersion *> *versions, NSError *versionError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) strongSelf2 = weakSelf;
                    if (!strongSelf2) return;

                    if (versionError || versions.count == 0) {
                        NSError *failError = [NSError errorWithDomain:@"FabricAPI" code:3 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_921", nil), versionError.localizedDescription ?: localize(@"i18n_str_463", nil)]}];
                        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                        [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                        [strongSelf2 showComponentAlert:localize(@"i18n_str_918", nil) message:[NSString stringWithFormat:localize(@"i18n_str_921", nil), versionError.localizedDescription ?: localize(@"i18n_str_463", nil)]];
                        return;
                    }

                    // 找到匹配当前 gameVersion 的版本
                    ModVersion *matchingVersion = nil;
                    for (ModVersion *ver in versions) {
                        if ([ver.gameVersions containsObject:gameVersion]) {
                            matchingVersion = ver;
                            break;
                        }
                    }
                    if (!matchingVersion) {
                        matchingVersion = versions.firstObject;
                    }

                    NSDictionary *primaryFile = matchingVersion.primaryFile;
                    if (!primaryFile || ![primaryFile[@"url"] isKindOfClass:[NSString class]]) {
                        NSError *failError = [NSError errorWithDomain:@"FabricAPI" code:4 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_922", nil)}];
                        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                        [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                        [strongSelf2 showComponentAlert:localize(@"i18n_str_918", nil) message:localize(@"i18n_str_922", nil)];
                        return;
                    }

                    [strongSelf2 downloadFabricAPIFile:primaryFile[@"url"]
                                                filename:primaryFile[@"filename"]
                                                  taskId:taskId
                                                 modInfo:fabricAPI];
                });
            }];
        });
    }];
}

- (void)downloadFabricAPIFile:(NSString *)urlString filename:(NSString *)filename taskId:(NSString *)taskId modInfo:(NSDictionary *)modInfo {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSURL *url = [NSURL URLWithString:urlString];
        NSError *downloadError = nil;
        NSData *data = [self downloadDataWithURL:url error:&downloadError];

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf2 = weakSelf;
            if (!strongSelf2) return;

            if (!data || downloadError) {
                NSError *failError = downloadError ?: [NSError errorWithDomain:@"FabricAPI" code:5 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_448", nil)}];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                [strongSelf2 showComponentAlert:localize(@"i18n_str_918", nil) message:[NSString stringWithFormat:localize(@"i18n_str_923", nil), downloadError.localizedDescription ?: localize(@"i18n_str_97", nil)]];
                return;
            }

            NSString *modsDir = [strongSelf2 currentProfileModsPath];
            NSString *saveFilename = filename ?: @"fabric-api.jar";
            NSString *savePath = [modsDir stringByAppendingPathComponent:saveFilename];

            NSError *writeError = nil;
            BOOL success = [data writeToFile:savePath options:NSDataWritingAtomic error:&writeError];

            if (success) {
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                          stageAtIndex:0
                                                               progress:1.0
                                                               message:[NSString stringWithFormat:localize(@"i18n_str_924", nil), saveFilename]];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusCompleted];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateCompleted];
                [strongSelf2 showComponentAlert:localize(@"i18n_str_253", nil) message:[NSString stringWithFormat:localize(@"i18n_str_925", nil), saveFilename]];
            } else {
                NSError *failError = writeError ?: [NSError errorWithDomain:@"FabricAPI" code:6 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_926", nil)}];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                [strongSelf2 showComponentAlert:localize(@"i18n_str_918", nil) message:[NSString stringWithFormat:localize(@"i18n_str_927", nil), writeError.localizedDescription ?: localize(@"i18n_str_97", nil)]];
            }
        });
    });
}

- (void)startInstallOptiFineWithGameVersion:(NSString *)gameVersion {
    // redesign-download-ui Phase 4 Task 4.4：OptiFine（mods 方式）注册为统一下载任务，
    // PLTaskStagesSingleFile 单阶段 + autoPresentDetail 自动弹出统一进度页
    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    DownloadTaskItem *taskItem = [manager
        registerTaskWithResourceType:DownloadTaskResourceTypeMod
                        resourceName:[NSString stringWithFormat:@"optifine-%@", gameVersion]
                         displayName:@"OptiFine"
                      downloadSource:@"bmclapi"
                             rawTask:nil
                      supportsResume:NO
                             iconURL:nil];
    NSString *taskId = taskItem.taskId;
    if (taskItem) {
        [[DownloadTaskManager sharedManager] setTaskWithId:taskId stages:PLTaskStagesSingleFile()];
        taskItem.autoPresentDetail = YES;
        [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateDownloading];
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                 stageAtIndex:0
                                                       status:PLTaskStageStatusRunning];
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                 stageAtIndex:0
                                                     progress:-1.0
                                                      message:[NSString stringWithFormat:localize(@"i18n_str_928", nil), gameVersion]];
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // BMCL API 列表查询
        NSString *listURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@", gameVersion];
        NSURL *url = [NSURL URLWithString:listURL];
        NSError *listError = nil;
        NSData *listData = [self downloadDataWithURL:url error:&listError];

        NSString *optiFineType = nil;
        NSString *optiFinePatch = nil;
        NSString *filename = nil;

        if (listData && !listError) {
            NSError *jsonError = nil;
            NSArray *versions = [NSJSONSerialization JSONObjectWithData:listData options:0 error:&jsonError];
            if (!jsonError && [versions isKindOfClass:[NSArray class]] && versions.count > 0) {
                NSDictionary *first = versions.firstObject;
                if ([first isKindOfClass:[NSDictionary class]]) {
                    optiFineType = first[@"type"] ?: @"HD_U";
                    optiFinePatch = first[@"patch"];
                    filename = first[@"filename"];
                }
            }
        }

        if (!optiFinePatch) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                NSError *failError = [NSError errorWithDomain:@"OptiFine" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_929", nil), gameVersion]}];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                [strongSelf2 showComponentAlert:localize(@"i18n_str_918", nil) message:[NSString stringWithFormat:localize(@"i18n_str_929", nil), gameVersion]];
            });
            return;
        }

        // 切换到下载阶段
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                 stageAtIndex:0
                                                     progress:-1.0
                                                      message:[NSString stringWithFormat:localize(@"i18n_str_930", nil), optiFineType, optiFinePatch]];

        // 下载 OptiFine
        NSString *downloadURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@/%@/%@", gameVersion, optiFineType, optiFinePatch];
        NSURL *dlURL = [NSURL URLWithString:downloadURL];
        NSError *downloadError = nil;
        NSData *data = [self downloadDataWithURL:dlURL error:&downloadError];

        // fallback: OptiFine 官方源
        if ((!data || downloadError) && filename) {
            NSString *officialURL = [NSString stringWithFormat:@"https://optifine.net/downloadx?f=%@", filename];
            NSURL *officialURLObject = [NSURL URLWithString:officialURL];
            NSError *officialError = nil;
            NSData *officialData = [self downloadDataWithURL:officialURLObject error:&officialError];
            if (officialData && !officialError) {
                data = officialData;
                downloadError = nil;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf2 = weakSelf;
            if (!strongSelf2) return;

            if (!data || downloadError) {
                NSError *failError = downloadError ?: [NSError errorWithDomain:@"OptiFine" code:2 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_448", nil)}];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                [strongSelf2 showComponentAlert:localize(@"i18n_str_918", nil) message:[NSString stringWithFormat:localize(@"i18n_str_931", nil), downloadError.localizedDescription ?: localize(@"i18n_str_97", nil)]];
                return;
            }

            NSString *modsDir = [strongSelf2 currentProfileModsPath];
            NSString *saveFilename = filename ?: [NSString stringWithFormat:@"OptiFine_%@_%@_%@.jar", gameVersion, optiFineType, optiFinePatch];
            NSString *savePath = [modsDir stringByAppendingPathComponent:saveFilename];

            NSError *writeError = nil;
            BOOL success = [data writeToFile:savePath options:NSDataWritingAtomic error:&writeError];

            if (success) {
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                          stageAtIndex:0
                                                               progress:1.0
                                                               message:[NSString stringWithFormat:localize(@"i18n_str_924", nil), saveFilename]];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusCompleted];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateCompleted];
                [strongSelf2 showComponentAlert:localize(@"i18n_str_253", nil) message:[NSString stringWithFormat:localize(@"i18n_str_932", nil), optiFineType, optiFinePatch]];
            } else {
                NSError *failError = writeError ?: [NSError errorWithDomain:@"OptiFine" code:3 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_926", nil)}];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                [strongSelf2 showComponentAlert:localize(@"i18n_str_918", nil) message:[NSString stringWithFormat:localize(@"i18n_str_927", nil), writeError.localizedDescription ?: localize(@"i18n_str_97", nil)]];
            }
        });
    });
}

#pragma mark - OptiFine 版本补丁安装（Vanilla profile，参照 FCL/HMCL OptiFineInstallTask）

/// 以版本补丁方式安装 OptiFine（适用于 Vanilla profile）
/// 参照 FCL OptiFineInstallTask 与 HMCL OptiFineInstallTask：
///   1. 下载 OptiFine jar 到 libraries/optifine/OptiFine/<mcVersion>/<versionId>.jar
///   2. 创建 versions/<versionId>/<versionId>.json，mainClass 设为
///      net.minecraft.launchwrapper.Launcher，并附加 --tweakClass optifine.OptiFineTweaker
///   3. inheritsFrom 指向原版版本（vanilla parent 必须已存在）
///   4. 创建新 profile 并切换为当前 profile
- (void)startInstallOptiFineAsPatch:(NSString *)gameVersion {
    // redesign-download-ui Phase 4 Task 4.4：OptiFine 版本补丁安装注册为统一下载任务，
    // PLTaskStagesSingleFile 单阶段 + autoPresentDetail 自动弹出统一进度页
    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    DownloadTaskItem *taskItem = [manager
        registerTaskWithResourceType:DownloadTaskResourceTypeModloader
                        resourceName:[NSString stringWithFormat:@"optifine-patch-%@", gameVersion]
                         displayName:[NSString stringWithFormat:@"OptiFine (%@)", gameVersion]
                      downloadSource:@"bmclapi"
                             rawTask:nil
                      supportsResume:NO
                             iconURL:nil];
    NSString *taskId = taskItem.taskId;
    if (taskItem) {
        [[DownloadTaskManager sharedManager] setTaskWithId:taskId stages:PLTaskStagesSingleFile()];
        taskItem.autoPresentDetail = YES;
        [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateDownloading];
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                 stageAtIndex:0
                                                       status:PLTaskStageStatusRunning];
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                 stageAtIndex:0
                                                     progress:-1.0
                                                      message:[NSString stringWithFormat:localize(@"i18n_str_928", nil), gameVersion]];
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // 1. BMCL API 查询适配当前游戏版本的 OptiFine 列表
        NSString *listURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@", gameVersion];
        NSURL *url = [NSURL URLWithString:listURL];
        NSError *listError = nil;
        NSData *listData = [self downloadDataWithURL:url error:&listError];

        NSString *optiFineType = nil;
        NSString *optiFinePatch = nil;
        NSString *filename = nil;

        if (listData && !listError) {
            NSError *jsonError = nil;
            NSArray *versions = [NSJSONSerialization JSONObjectWithData:listData options:0 error:&jsonError];
            if (!jsonError && [versions isKindOfClass:[NSArray class]] && versions.count > 0) {
                NSDictionary *first = versions.firstObject;
                if ([first isKindOfClass:[NSDictionary class]]) {
                    optiFineType = first[@"type"] ?: @"HD_U";
                    optiFinePatch = first[@"patch"];
                    filename = first[@"filename"];
                }
            }
        }

        if (!optiFinePatch) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                NSError *failError = [NSError errorWithDomain:@"OptiFine" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_929", nil), gameVersion]}];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                [strongSelf2 showComponentAlert:localize(@"i18n_str_918", nil) message:[NSString stringWithFormat:localize(@"i18n_str_929", nil), gameVersion]];
            });
            return;
        }

        // 2. 下载 OptiFine jar
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                 stageAtIndex:0
                                                     progress:-1.0
                                                      message:[NSString stringWithFormat:localize(@"i18n_str_930", nil), optiFineType, optiFinePatch]];
        NSString *downloadURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@/%@/%@", gameVersion, optiFineType, optiFinePatch];
        NSURL *dlURL = [NSURL URLWithString:downloadURL];
        NSError *downloadError = nil;
        NSData *jarData = [self downloadDataWithURL:dlURL error:&downloadError];

        // fallback: OptiFine 官方源
        if ((!jarData || downloadError) && filename.length > 0) {
            NSString *officialURL = [NSString stringWithFormat:@"https://optifine.net/downloadx?f=%@", filename];
            NSURL *officialURLObject = [NSURL URLWithString:officialURL];
            NSError *officialError = nil;
            NSData *officialData = [self downloadDataWithURL:officialURLObject error:&officialError];
            if (officialData && !officialError) {
                jarData = officialData;
                downloadError = nil;
            }
        }

        if (!jarData || downloadError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                NSError *failError = downloadError ?: [NSError errorWithDomain:@"OptiFine" code:2 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_448", nil)}];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                [strongSelf2 showComponentAlert:localize(@"i18n_str_918", nil) message:[NSString stringWithFormat:localize(@"i18n_str_931", nil), downloadError.localizedDescription ?: localize(@"i18n_str_97", nil)]];
            });
            return;
        }

        // 3. 检查原版父版本必须已存在（否则 inheritsFrom 会失败）
        const char *env = getenv("POJAV_GAME_DIR");
        NSString *gameDir = env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
        NSString *parentJsonPath = [gameDir stringByAppendingPathComponent:
                                    [NSString stringWithFormat:@"versions/%@/%@.json", gameVersion, gameVersion]];
        if (![[NSFileManager defaultManager] fileExistsAtPath:parentJsonPath]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                NSError *failError = [NSError errorWithDomain:@"OptiFine" code:4 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_933", nil), gameVersion]}];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                [strongSelf2 showComponentAlert:localize(@"i18n_str_918", nil) message:[NSString stringWithFormat:localize(@"i18n_str_934", nil), gameVersion, gameVersion]];
            });
            return;
        }

        // 4. 写入 jar 到 libraries/optifine/OptiFine/<mcVersion>/<versionId>.jar
        //    参照 FCL/HMCL：OptiFine jar 作为 launchwrapper 的 tweakClass 输入，
        //    mainClass 设为 net.minecraft.launchwrapper.Launcher
        NSString *versionId = [NSString stringWithFormat:@"%@-OptiFine_%@_%@", gameVersion, optiFineType, optiFinePatch];
        NSString *optifineJarPath = [NSString stringWithFormat:@"optifine/OptiFine/%@/%@.jar", gameVersion, versionId];
        NSString *optifineJarAbsPath = [NSString stringWithFormat:@"%@/libraries/%@", gameDir, optifineJarPath];
        NSString *jarDir = [optifineJarAbsPath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:jarDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSError *writeJarError = nil;
        BOOL jarOk = [jarData writeToFile:optifineJarAbsPath options:NSDataWritingAtomic error:&writeJarError];
        if (!jarOk) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                NSError *failError = writeJarError ?: [NSError errorWithDomain:@"OptiFine" code:5 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_935", nil)}];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                [strongSelf2 showComponentAlert:localize(@"i18n_str_918", nil) message:[NSString stringWithFormat:localize(@"i18n_str_936", nil), writeJarError.localizedDescription ?: localize(@"i18n_str_97", nil)]];
            });
            return;
        }

        // 5. 创建 version JSON（launchwrapper + tweakClass + inheritsFrom）
        NSDictionary *versionJson = @{
            @"id": versionId,
            @"inheritsFrom": gameVersion,
            @"type": @"release",
            @"mainClass": @"net.minecraft.launchwrapper.Launcher",
            @"minecraftArguments": @"--username ${auth_player_name} --version ${version_name} --gameDir ${game_directory} --assetsDir ${assets_root} --assetIndex ${assets_index_name} --uuid ${auth_uuid} --accessToken ${auth_access_token} --userType ${user_type} --versionType ${version_type} --tweakClass optifine.OptiFineTweaker",
            @"libraries": @[
                @{
                    @"name": [NSString stringWithFormat:@"optifine:OptiFine:%@", gameVersion],
                    @"downloads": @{
                        @"artifact": @{
                            @"path": optifineJarPath,
                            @"url": @"",
                            @"size": @(jarData.length),
                            @"sha1": @""
                        }
                    }
                }
            ],
            @"jar": gameVersion,
            @"minimumLauncherVersion": @21
        };
        NSString *versionDir = [gameDir stringByAppendingPathComponent:[NSString stringWithFormat:@"versions/%@", versionId]];
        [[NSFileManager defaultManager] createDirectoryAtPath:versionDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *jsonPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", versionId]];
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:versionJson options:NSJSONWritingPrettyPrinted error:nil];
        NSError *writeJsonError = nil;
        [jsonData writeToFile:jsonPath options:NSDataWritingAtomic error:&writeJsonError];

        if (writeJsonError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:writeJsonError];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                [strongSelf2 showComponentAlert:localize(@"i18n_str_918", nil) message:[NSString stringWithFormat:localize(@"i18n_str_937", nil), writeJsonError.localizedDescription ?: localize(@"i18n_str_97", nil)]];
            });
            return;
        }

        // 6. 注册新 profile 并切换为当前 profile（参照 FCL/HMCL 行为）
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf2 = weakSelf;
            if (!strongSelf2) return;

            NSMutableDictionary *profile = [NSMutableDictionary dictionary];
            profile[@"name"] = versionId;
            profile[@"lastVersionId"] = versionId;
            profile[@"gameDir"] = @".";
            profile[@"type"] = @"custom";
            profile[@"created"] = [NSDate date].description;
            [PLProfiles.current saveProfile:profile withName:versionId];
            PLProfiles.current.selectedProfileName = versionId;

            [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];

            [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                      stageAtIndex:0
                                                           progress:1.0
                                                           message:[NSString stringWithFormat:localize(@"i18n_str_938", nil), versionId]];
            [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusCompleted];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateCompleted];
            [strongSelf2 showComponentAlert:localize(@"i18n_str_253", nil)
                                     message:[NSString stringWithFormat:
                                              localize(@"i18n_str_939", nil),
                                              optiFineType, optiFinePatch, versionId]];
        });
    });
}

- (void)showRendererSelector {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_940", nil)
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray *renderers = getRendererKeys(YES);
    NSArray *displayNames = getRendererNames(YES);

    for (NSInteger i = 0; i < renderers.count; i++) {
        NSString *renderer = renderers[i];
        NSString *name = i < displayNames.count ? displayNames[i] : renderer;
        [alert addAction:[UIAlertAction actionWithTitle:name
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.selectedRenderer = renderer;
            [self saveSettings];
            [self reloadAllTableViews];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        UITableViewCell *cell = [self cellForGlobalSection:3 row:0];
        alert.popoverPresentationController.sourceView = cell ?: self.view;
        alert.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

/// 判断当前 profile 的 MC 版本是否为 26.2+（需要图形 API 切换）
- (BOOL)isCurrentProfileModernVersion {
    NSString *versionId = self.profile[@"lastVersionId"] ?: @"";
    // 修复 Fabric/Quilt/Forge loader profile 的版本号识别：
    //   原 implementation 用 hasPrefix:@"26." 判断，但 Fabric profile 的 lastVersionId
    //   形如 "fabric-loader-0.16.0-26.2"，前缀是 "fabric-loader" 不是 "26."，导致
    //   MC 26.2+ Fabric profile 看不到"图形 API"选项。
    //   修复：先用 ModpackExportService.parseVersionId 提取 minecraft 版本号，
    //   再用提取后的版本号判断。也支持 forge/neoforge 形如 "26.2-forge-..."。
    NSDictionary *parsed = [ModpackExportService parseVersionId:versionId];
    NSString *mcVersion = parsed[@"minecraft"] ?: versionId;
    // 26.x 版本（26w02a 等快照也匹配）
    if ([mcVersion hasPrefix:@"26."]) return YES;
    if ([mcVersion hasPrefix:@"26w"]) return YES;
    // 1.21.8+ 版本（Mojang 在 1.21.8 引入 Vulkan API）
    if ([mcVersion hasPrefix:@"1.21."]) {
        NSString *minorStr = [mcVersion substringFromIndex:5];
        NSInteger minor = [minorStr integerValue];
        if (minor >= 8) return YES;
    }
    return NO;
}

/// 图形 API 显示名
- (NSString *)graphicsApiDisplayName:(NSString *)api {
    if ([api isEqualToString:@"(default)"]) return @"(default)";
    if ([api isEqualToString:@"prefer_vulkan"]) return localize(@"i18n_str_941", nil);
    if ([api isEqualToString:@"prefer_opengl"]) return localize(@"i18n_str_942", nil);
    return localize(@"i18n_str_943", nil);
}

/// 图形 API 选择器（MC 26.2+ 专用）
- (void)showGraphicsApiSelector {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_944", nil)
                                                                   message:localize(@"i18n_str_945", nil)
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray *keys = @[@"(default)", @"default", @"prefer_vulkan", @"prefer_opengl"];
    NSArray *names = @[@"(default)", localize(@"i18n_str_943", nil), localize(@"i18n_str_941", nil), localize(@"i18n_str_942", nil)];

    for (NSInteger i = 0; i < keys.count; i++) {
        NSString *key = keys[i];
        NSString *name = i < names.count ? names[i] : key;
        [alert addAction:[UIAlertAction actionWithTitle:name
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.selectedGraphicsApi = key;
            [self saveSettings];
            [self reloadAllTableViews];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        UITableViewCell *cell = [self cellForGlobalSection:3 row:1];
        alert.popoverPresentationController.sourceView = cell ?: self.view;
        alert.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showJavaVersionSelector {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_946", nil)
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    // 从 java.java_homes 偏好动态获取已安装的 Java 版本列表
    NSMutableDictionary *javaHomes = [getPrefObject(@"java.java_homes") mutableCopy];
    if (!javaHomes) {
        javaHomes = [NSMutableDictionary dictionary];
    }
    NSMutableArray *versions = [[javaHomes allKeys] mutableCopy];
    // "0" 表示自动选择，单独处理
    [versions removeObject:@"0"];
    [versions sortUsingSelector:@selector(compare:)];
    // 自动选项放最前
    [versions insertObject:@"0" atIndex:0];

    for (NSString *ver in versions) {
        NSString *name = [ver isEqualToString:@"0"] ? localize(@"preference.auto_select", nil) : [NSString stringWithFormat:@"Java %@", ver];
        [alert addAction:[UIAlertAction actionWithTitle:name
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.selectedJavaVersion = ver;
            [self saveSettings];
            [self reloadAllTableViews];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        UITableViewCell *cell = [self cellForGlobalSection:3 row:1];
        alert.popoverPresentationController.sourceView = cell ?: self.view;
        alert.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showMemoryAllocator {
    NSInteger minMemory = 512;
    NSInteger step = 512;
    NSMutableArray *options = [NSMutableArray array];
    for (NSInteger mem = minMemory; mem <= self.maxMemory; mem += step) {
        [options addObject:@(mem)];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_948", nil)
                                                                   message:[NSString stringWithFormat:localize(@"i18n_str_949", nil), (long)(self.maxMemory / 0.8), (long)self.maxMemory]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSNumber *memNum in options) {
        NSInteger mem = [memNum integerValue];
        NSString *title = [NSString stringWithFormat:@"%ld MB", (long)mem];
        [alert addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.allocatedMemory = mem;
            [self saveSettings];
            [self reloadAllTableViews];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        UITableViewCell *cell = [self cellForGlobalSection:3 row:2];
        alert.popoverPresentationController.sourceView = cell ?: self.view;
        alert.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Done / Close

- (void)actionClose {
    // 收起键盘
    [self.view endEditing:YES];
    // 直接关闭，不保存（设置项在编辑过程中已自动保存）
    if (self.navigationController) {
        if (self.navigationController.viewControllers.firstObject == self) {
            [self dismissViewControllerAnimated:YES completion:nil];
        } else {
            [self.navigationController popViewControllerAnimated:YES];
        }
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)actionDone {
    // 收起键盘，触发 EditingDidEnd
    [self.view endEditing:YES];

    NSString *newName = self.profile[@"name"];
    if ([newName length] == 0) {
        // 名称为空，恢复原名
        self.profile[@"name"] = self.originalName;
        newName = self.originalName;
    }

    // 检查重命名冲突
    if (![self.originalName isEqualToString:newName]) {
        // 名称变了，检查新名是否已存在
        if (PLProfiles.current.profiles[newName]) {
            // 重名，提示并取消
            showDialog(localize(@"i18n_str_42", nil), localize(@"i18n_str_1289", nil));
            return;
        }
        // 删除旧名，添加新名
        if (self.originalName.length > 0) {
            [PLProfiles.current.profiles removeObjectForKey:self.originalName];
        }
        PLProfiles.current.profiles[newName] = self.profile;
        // 如果原来选中的是被重命名的 profile，更新选中
        if ([PLProfiles.current.selectedProfileName isEqualToString:self.originalName]) {
            PLProfiles.current.selectedProfileName = newName;
        }
    } else {
        // 名称没变，直接保存
        PLProfiles.current.profiles[newName] = self.profile;
    }

    [PLProfiles.current save];

    // 发送通知刷新配置文件列表
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:newName];

    // 关闭
    [self actionClose];
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

- (void)handleBackgroundUIEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 背景效果切换后重新应用 tableView 毛玻璃 backgroundView，
        // 否则切换毛玻璃↔半透明后旧 backgroundView 仍存在造成视觉不一致
        [self applyBackgroundBlurToTableView];
        [self reloadAllTableViews];
    });
}

/// 给 self.tableView 设置底层背景视图，遮挡栈底 VC 内容同时透出全局背景。
/// - 有自定义启动器背景时：使用 UIVisualEffectView (SystemThinMaterial) 毛玻璃背景，
///   模糊全局背景图但仍能透出，并遮挡栈底 VersionManager 的卡片。
/// - 无自定义背景时：使用 systemBackgroundColor，与系统默认外观一致。
- (void)applyBackgroundBlurToTableView {
    // 应用到两个 tableView（leftTableView 和 rightTableView）
    for (UITableView *tv in @[self.leftTableView, self.rightTableView]) {
        if (!tv) continue;
        // 清理旧 backgroundView（避免叠加）
        tv.backgroundView = nil;

        if ([[BackgroundManager sharedManager] hasBackground]) {
            // 有自定义背景：使用毛玻璃 backgroundView 模糊背景并遮挡栈底 VC
            UIBlurEffect *blur;
            if (@available(iOS 13.0, *)) {
                blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
            } else {
                blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
            }
            UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
            blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            blurView.frame = tv.bounds;
            // 按 uiEffect 调整透明度：毛玻璃模式保持默认 0.7 通透，半透明模式按 uiOpacity
            BackgroundUIEffect effect = [BackgroundManager sharedManager].uiEffect;
            if (effect == BackgroundUIEffectBlur) {
                blurView.alpha = 0.85;
            } else {
                blurView.alpha = MAX(0.5, [BackgroundManager sharedManager].uiOpacity);
            }
            tv.backgroundView = blurView;
        } else {
            // 无自定义背景：使用系统默认色，保持原 UI 风格
            if (@available(iOS 13.0, *)) {
                UIView *bg = [[UIView alloc] initWithFrame:tv.bounds];
                bg.backgroundColor = [UIColor systemBackgroundColor];
                bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                tv.backgroundView = bg;
            }
        }
        // tableView 本身保持透明，让 backgroundView 显示
        tv.backgroundColor = [UIColor clearColor];
    }
}

#pragma mark - UA-aware download helper

/// 阶段6修复（参照 FCL）：用带浏览器 User-Agent 的 NSURLSession 替代 NSData dataWithContentsOfURL:
/// 进行同步下载。BMCLAPI 的 optifine/curseforge 转发受 Cloudflare 保护，默认 UA 会被拦截返回 403。
/// 与 DownloadViewController.downloadDataWithURLString:error: 等价，但接收 NSURL 参数
/// （本文件调用处均已构造好 NSURL）。
- (NSData *)downloadDataWithURL:(NSURL *)url error:(NSError **)error {
    if (!url) {
        if (error) {
            *error = [NSError errorWithDomain:@"ProfileSettingsDownload"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"nil URL"}];
        }
        return nil;
    }
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 60;
    cfg.HTTPAdditionalHeaders = @{
        @"User-Agent": @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        @"Accept": @"*/*"
    };
    __block NSData *result = nil;
    __block NSError *resultError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    NSURLSessionDataTask *task = [session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
        if (err) {
            resultError = err;
        } else if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSInteger statusCode = ((NSHTTPURLResponse *)response).statusCode;
            if (statusCode >= 400) {
                resultError = [NSError errorWithDomain:@"ProfileSettingsDownload"
                                                  code:statusCode
                                              userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld for %@", (long)statusCode, url.absoluteString]}];
            } else {
                result = data;
            }
        } else {
            result = data;
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 70 * NSEC_PER_SEC));
    if (error) *error = resultError;
    [session finishTasksAndInvalidate];
    return result;
}

@end
