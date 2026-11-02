//
//  MultiplayerViewController.m
//  Amethyst
//
//  MC 联机界面实现（FCL 风格重制版）
//
//  本文件参照 FCL (FoldCraftLauncher) 的联机流程重新设计：
//
//  模式 1：启动器模式（MultiplayerVCModeLauncher）
//    用户在启动游戏前在此界面启用联机、设置预设 Network ID、管理房间、配置直连。
//    Section 0「联机设置」：UISwitch 启用联机开关 + 预设 Network ID 显示/编辑
//    Section 1「我的房间」：保存的房间列表（每行显示 房间名 + Network ID + 状态 + 连接/断开按钮）
//    Section 2「直连」：IP+端口输入 + 加入游戏按钮（写入 PLProfiles）
//
//  模式 2：游戏内模式（MultiplayerVCModeInGame）
//    用户启动游戏后通过悬浮球菜单进入，选择当房主或房客。
//    Section 0「选择角色」：当房主按钮 + 当房客按钮（大卡片样式）
//    Section 1「联机状态」：当前联机状态 + Network ID + 本地 IP
//
//  关键变更（端口检测改为手动输入）：
//    之前房主流程依赖 LanPortDetector 自动检测 LAN 端口（拦截 MC 日志或读取
//    latestlog.txt），存在以下问题：
//      - latestlog.txt 可能包含上次会话的 LAN 端口日志，误检测为当前会话的端口
//      - 不同 MC 版本日志格式差异大，自动检测不可靠
//      - 用户在游戏未真正"对局域网开放"时就生成了分享代码
//    现在改为手动输入端口：连接成功后弹出输入对话框，用户在 MC 中"对局域网开放"
//    后手动输入聊天框显示的端口号，才会生成分享代码。
//  房主流程：
//    1. 检查 ZeroTier 框架可用性 + 预设 Network ID 是否已设置
//    2. 连接到预设 Network ID 房间（调用 connectToRoom:completion:）
//    3. 连接成功后弹出手动输入端口对话框（showManualPortInputAlert）
//    4. 用户在 MC 中"对局域网开放"后，手动输入聊天框显示的端口号
//    5. 生成分享代码（调用 generateShareCodeForRoom:）
//    6. 显示分享代码（可复制、可分享）
//
//  房客流程：
//    1. 弹出输入框（UIAlertController with textField）
//    2. 解析分享代码（调用 parseShareCode:）
//    3. 连接到房间（调用 connectToRoom:completion:）
//    4. 连接成功后提示并显示服务器地址（房主 IP:端口）
//

#import "MultiplayerViewController.h"
#import "MultiplayerManager.h"
#import "BackgroundManager.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "LanPortDetector.h"
#import "ZeroTierBridge.h"
#import "utils.h"
#import "McLanPortDetector.h"   // ★ [PORT-AUTO]

/// 本地化辅助函数
/// 优先通过 localize() 查找本地化文本；若未找到（返回值等于 key），则使用传入的 fallback。
/// 这样既满足"所有新增文本需要本地化"的要求，又避免 key 未注册时用户看到原始 key。
NS_INLINE NSString *MPLocalized(NSString *key, NSString *fallback) {
    NSString *value = localize(key, nil);
    return [value isEqualToString:key] ? (fallback ?: key) : value;
}

@interface MultiplayerViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate, MultiplayerManagerDelegate>

/// 当前界面模式（启动器 / 游戏内）
@property (nonatomic, assign) MultiplayerVCMode mode;

/// 主表格视图（InsetGrouped 风格）
@property (nonatomic, strong) UITableView *tableView;

/// 当前已保存的房间列表
@property (nonatomic, strong) NSArray<MultiplayerRoom *> *rooms;

#pragma mark - 启动器模式专用控件

/// Section 0 Row 0 的"启用联机"开关
@property (nonatomic, strong) UISwitch *enableSwitch;

/// Section 2 Row 0 的 IP 地址输入框（强引用，确保跨 cell 复用时数据不丢失）
@property (nonatomic, strong) UITextField *directIPField;

/// Section 2 Row 0 的端口输入框（强引用）
@property (nonatomic, strong) UITextField *directPortField;

#pragma mark - 游戏内模式专用状态

/// 房主流程是否激活（已点击"当房主"且正在等待/已连接）
@property (nonatomic, assign) BOOL isHostFlowActive;

/// 房客流程是否激活（已点击"当房客"且正在等待/已连接）
@property (nonatomic, assign) BOOL isGuestFlowActive;

/// 房主流程中最新生成的分享代码（用于显示与复制）
@property (nonatomic, copy, nullable) NSString *lastShareCode;

/// 房客流程中最新解析出的服务器地址（hostIP:hostPort，用于显示给用户）
@property (nonatomic, copy, nullable) NSString *lastServerAddress;

/// 房主流程中正在使用的房间对象（用于生成分享代码）
@property (nonatomic, strong, nullable) MultiplayerRoom *hostRoom;

/// 房客流程中正在连接的房间对象（用于显示连接状态）
@property (nonatomic, strong, nullable) MultiplayerRoom *guestRoom;

/// 连接进度提示 Alert（用于动态更新进度文本）
///
/// 当房主或房客流程开始连接时，会 present 此 Alert 并在其中显示进度文本。
/// multiplayerConnectionProgress: 回调会更新此 Alert 的 message 属性，
/// 让用户实时看到"步骤 1/6：正在启动 ZeroTier 节点..."等进度。
///
/// 关键修复：之前连接流程只显示一个静态的"正在连接到 ZeroTier 网络"提示，
/// 用户无法知道后台进度，只能干等 15-30 秒直到成功或失败。
/// 现在通过此 Alert 实时更新进度，让用户看到详细的步骤信息。
@property (nonatomic, strong, nullable) UIAlertController *connectionProgressAlert;

@end

@implementation MultiplayerViewController

#pragma mark - Init

/// 通过模式初始化联机界面
/// @param mode 界面模式（启动器 / 游戏内）
- (instancetype)initWithMode:(MultiplayerVCMode)mode {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _mode = mode;
    }
    return self;
}

/// 兜底初始化：未指定模式时默认使用启动器模式
- (instancetype)init {
    return [self initWithMode:MultiplayerVCModeLauncher];
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    // 不设置 self.title，避免顶部导航栏出现"联机"标题黑条（参照 FCL 无 title 风格）

    // 适配自定义启动器背景：透明化当前 VC，让全局背景图/毛玻璃透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // 彻底隐藏导航栏黑条（仅当作为根页面时；modal/pushed 仍保留导航栏）
    [self hideNavBarIfRoot];

    // 初始化数据：从 MultiplayerManager 读取已保存的房间列表
    self.rooms = [[MultiplayerManager sharedManager] savedRooms] ?: @[];

    // 构建 UI
    [self setupUI];

    // 注册为 MultiplayerManager 代理，接收节点/网络状态变化的实时回调
    [MultiplayerManager sharedManager].delegate = self;

    // 监听背景效果变化通知，背景切换时重新应用透明效果并刷新表格
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(backgroundEffectChanged)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    // 游戏内模式：监听 LAN 端口检测通知（房主流程依赖）
    if (self.mode == MultiplayerVCModeInGame) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(lanPortDidDetect:)
                                                     name:LanPortDetectorDidDetectPortNotification
                                                   object:nil];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    // 重新隐藏导航栏黑条（pop 回根页面时）
    [self hideNavBarIfRoot];

    // ★ [MP-BACK] pushed 呈现(栈里非根)：显式打开导航栏 —— 容器根页通常把导航栏藏了，
    //   否则注入的关闭按钮(左上角 xmark)会被一起藏住 ⇒ 用户「进得去、出不来」。
    if (self.navigationController &&
        self.navigationController.viewControllers.count > 1 &&
        self.navigationController.viewControllers.firstObject != self &&
        self.navigationController.topViewController == self) {
        self.navigationController.navigationBarHidden = NO;
    }

    // 进入界面时重新应用背景效果（背景可能在其他界面被修改）
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;

    // 重新应用导航栏毛玻璃效果
    [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];

    // 刷新房间列表（可能在其他界面修改过）
    [self refreshRooms];

    // 启动器模式：根据持久化的用户意图恢复开关状态
    //
    // 关键修复（开关状态不同步）：
    // 之前使用 isNodeStarted（运行时状态）恢复开关，存在以下问题：
    //   - 用户点击开关 ON → 后台开始启动节点（耗时 5+ 秒）→ 用户关闭 VC →
    //     重新打开 VC → 此时节点可能仍在启动中（isNodeStarted=NO）→ 开关显示 OFF
    //   - 用户点击开关 ON → 节点启动成功 → 用户关闭启动器（杀进程）→
    //     重新打开启动器 → isNodeStarted=NO（进程重启后状态丢失）→ 开关显示 OFF
    //
    // 修复方案：使用 isMultiplayerEnabled（持久化到 NSUserDefaults）恢复开关状态，
    // 表示用户的意图而非节点实际状态。即使关闭启动器再重新打开，开关也能正确显示。
    if (self.mode == MultiplayerVCModeLauncher) {
        BOOL enabled = [[MultiplayerManager sharedManager] isMultiplayerEnabled];
        [self.enableSwitch setOn:enabled animated:NO];

        // 如果用户之前启用了联机但节点未启动（如关闭启动器后重新打开），
        // 自动重启节点以恢复联机功能，让用户体验无缝衔接。
        if (enabled && ![[MultiplayerManager sharedManager] isNodeStarted]) {
            if ([[MultiplayerManager sharedManager] isFrameworkAvailable]) {
                NSLog(@"[MultiplayerVC] Multiplayer enabled but node not started, auto-restarting node...");
                __weak typeof(self) weakSelf = self;
                [[MultiplayerManager sharedManager] ensureNodeStartedWithCompletion:^(BOOL success, NSError *error) {
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (!strongSelf) return;

                    if (!success) {
                        // 关键修复（严重5）：节点启动失败时不应清除用户的持久化意图。
                        // 之前的实现会调用 setMultiplayerEnabled:NO，导致用户下次打开启动器
                        // 开关已自动变为 OFF，需要重新手动启用。
                        // 现在仅回退 UI 开关状态（视觉上关闭），但保留 isMultiplayerEnabled=YES，
                        // 这样用户下次打开启动器时开关会显示 ON 并自动重试启动节点。
                        // 只有 framework 不可用（永久不可用）时才清除意图。
                        NSLog(@"[MultiplayerVC] Auto-restart node failed (preserving user intent, retry next time): %@", error.localizedDescription);
                        [strongSelf.tableView reloadData];
                    } else {
                        NSLog(@"[MultiplayerVC] Auto-restart node succeeded");
                        [strongSelf.tableView reloadData];
                    }
                }];
            } else {
                // framework 不可用是永久性故障，清除用户意图
                [[MultiplayerManager sharedManager] setMultiplayerEnabled:NO];
                [self.enableSwitch setOn:NO animated:NO];
            }
        }
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // push 子页面时显示导航栏（子页面需要返回按钮）
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil) {
        self.navigationController.navigationBarHidden = NO;
    }
    // ★ [MP-BACK] pushed 被 pop 时恢复导航栏隐藏态(容器根页通常无导航栏)
    if (self.navigationController &&
        self.navigationController.viewControllers.count > 1 &&
        self.navigationController.viewControllers.firstObject != self) {
        self.navigationController.navigationBarHidden = YES;
    }
}

- (void)backgroundEffectChanged {
    // 背景效果改变时重新透明化当前 VC 并刷新表格，让所有 cell 重新适配文字颜色
    dispatch_async(dispatch_get_main_queue(), ^{
        [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
        self.tableView.backgroundColor = [UIColor clearColor];
        self.tableView.backgroundView = nil;
        // 重新应用导航栏毛玻璃效果
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
        // 刷新表格，让所有 cell 重新读取背景状态并适配颜色
        [self.tableView reloadData];
    });
}

- (void)dealloc {
    // 移除通知观察者，避免 dealloc 后收到通知导致崩溃
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // 清除代理引用，避免悬空指针
    if ([MultiplayerManager sharedManager].delegate == self) {
        [MultiplayerManager sharedManager].delegate = nil;
    }
}

#pragma mark - UI Setup

- (void)setupUI {
    // 使用 InsetGrouped 风格，卡片式布局，与系统设置界面一致
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
    // 启用自动尺寸计算
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56;
    // 注册复用的 cell 类型
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"DefaultCell"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"ButtonCell"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"EmptyCell"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"SwitchCell"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"NetworkIdCell"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"DirectInputCell"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"RoleCardCell"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"StatusCell"];
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    // 导航栏左上角：关闭按钮（xmark），两种模式都需要
    UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"xmark"]
                                                                     style:UIBarButtonItemStylePlain
                                                                    target:self
                                                                    action:@selector(closeTapped)];
    closeButton.accessibilityLabel = MPLocalized(@"mp.close", @"Close");
    self.navigationItem.leftBarButtonItem = closeButton;

    // 注意：启动器模式右上角不需要按钮（Network ID 通过 Section 0 设置）
    // 注意：游戏内模式右上角也不需要按钮（房主/房客通过 Section 0 选择）

    // 应用导航栏毛玻璃效果
    [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
}

#pragma mark - Navigation Actions

/// 关闭按钮回调：兼容 push 和 present 两种容器
- (void)closeTapped {
    [self.view endEditing:YES];
    if (self.navigationController && self.navigationController.viewControllers.firstObject != self) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

/// 当本 VC 是 nav 根、非 modal 呈现且是栈中唯一 VC 时彻底隐藏导航栏黑条
/// 快捷入口预 push 子页面时 count > 1，不隐藏导航栏
- (void)hideNavBarIfRoot {
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil &&
        self.navigationController.viewControllers.count == 1) {
        self.navigationController.navigationBarHidden = YES;
    } else if (self.navigationController &&
               self.navigationController.viewControllers.firstObject == self &&
               self.navigationController.presentingViewController == nil &&
               self.navigationController.topViewController == self) {
        // pop 回根页面时重新隐藏
        self.navigationController.navigationBarHidden = YES;
    }
}

#pragma mark - 启动器模式：启用联机开关

/// "启用联机"开关状态变化回调
///
/// 对标 FCL 启动器界面顶部的联机总开关：
///   - 打开：调用 ensureNodeStartedWithCompletion: 启动 ZeroTier 节点
///   - 关闭：调用 disconnectCurrentRoom 停止所有联机活动（节点保持运行，可再次打开）
///
/// 关键修复（开关状态不同步）：
/// 打开/关闭时通过 setMultiplayerEnabled: 持久化用户意图到 NSUserDefaults，
/// 这样即使关闭启动器再重新打开，开关状态也能正确恢复。
- (void)enableSwitchChanged:(UISwitch *)sender {
    if (sender.on) {
        // 检查 ZeroTier 框架可用性
        if (![[MultiplayerManager sharedManager] isFrameworkAvailable]) {
            [sender setOn:NO animated:YES];
            [self showSimpleAlertWithTitle:MPLocalized(@"mp.core.unavailable_title", @"Multiplayer core unavailable")
                                    message:MPLocalized(@"mp.core.unavailable_msg", @"ZeroTier multiplayer core is not loaded. Please use a build that includes the real zt.framework.")];
            return;
        }

        // 持久化用户启用联机的意图
        [[MultiplayerManager sharedManager] setMultiplayerEnabled:YES];

        // 启动 ZeroTier 节点
        __weak typeof(self) weakSelf = self;
        [[MultiplayerManager sharedManager] ensureNodeStartedWithCompletion:^(BOOL success, NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (!success) {
                // 关键修复（严重5）：节点启动失败时保留用户意图，仅回退 UI 开关。
                // 这样下次打开启动器时开关仍会显示 ON 并自动重试。
                // 之前会调用 setMultiplayerEnabled:NO，导致用户需要每次重新手动启用。
                [strongSelf.enableSwitch setOn:NO animated:YES];
                [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.node.start_failed_title", @"Start failed")
                                              message:error.localizedDescription ?: MPLocalized(@"mp.node.start_failed_msg", @"Failed to start the ZeroTier node. Please try again.")];
            } else {
                // 启动成功：刷新表格以更新开关行的辅助文字
                [strongSelf.tableView reloadData];
            }
        }];
    } else {
        // 持久化用户关闭联机的意图
        [[MultiplayerManager sharedManager] setMultiplayerEnabled:NO];

        // 关闭联机：断开当前房间（如有）
        if ([[MultiplayerManager sharedManager] currentRoom]) {
            [[MultiplayerManager sharedManager] disconnectCurrentRoom];
        }
        [self refreshRooms];
    }
}

#pragma mark - 启动器模式：预设 Network ID 编辑

/// 点击 Network ID 行：弹出 UIAlertController 让用户输入预设 Network ID
///
/// 对标 FCL：房主首次设置一次 Network ID（在 central.zerotier.com 创建后填入），
/// 之后每次开房自动使用，分享代码中自动包含此 Network ID。
- (void)networkIdCellTapped {
    [self.view endEditing:YES];

    // 检查 ZeroTier 框架可用性
    if (![[MultiplayerManager sharedManager] isFrameworkAvailable]) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.core.unavailable_title", @"Multiplayer core unavailable")
                                message:MPLocalized(@"mp.core.unavailable_msg", @"ZeroTier multiplayer core is not loaded, so Network ID cannot be set.")];
        return;
    }

    NSString *current = [[MultiplayerManager sharedManager] presetNetworkId] ?: @"";

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:MPLocalized(@"mp.network_id.title", @"Set Network ID")
                                                                   message:MPLocalized(@"mp.network_id.message", @"Create a network at central.zerotier.com, then enter the 16-character Network ID. It will be used automatically when hosting.")
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = current;
        textField.placeholder = MPLocalized(@"mp.network_id.placeholder", @"16-character hex Network ID");
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.keyboardType = UIKeyboardTypeASCIICapable;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.cancel", @"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    // 快速模式按钮：自动生成 Ad-hoc 网络 ID，无需注册账号
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.network_id.use_adhoc", @"Use Quick Mode (no signup)")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // 检查 ZeroTier 框架可用性
        if (![[MultiplayerManager sharedManager] isFrameworkAvailable]) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.core.unavailable_title", @"Multiplayer core unavailable")
                                          message:MPLocalized(@"mp.core.unavailable_msg", @"ZeroTier multiplayer core is not loaded, so Quick Mode cannot be used.")];
            return;
        }

        // 生成 Ad-hoc 网络 ID
        NSString *adhocNetId = [[MultiplayerManager sharedManager] generateAdhocNetworkId];
        if (!adhocNetId.length) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.network_id.adhoc_failed_title", @"Generation failed")
                                          message:MPLocalized(@"mp.network_id.adhoc_failed_msg", @"Could not generate a Quick Mode Network ID. Please use Standard Mode instead.")];
            return;
        }

        // 保存为预设 Network ID
        [[MultiplayerManager sharedManager] setPresetNetworkId:adhocNetId];
        [strongSelf.tableView reloadData];

        // 提示用户
        [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.network_id.adhoc_success_title", @"Quick Mode enabled")
                                      message:[NSString stringWithFormat:@"%@\n\n%@",
                                               MPLocalized(@"mp.network_id.adhoc_success_msg", @"A Network ID was generated automatically. No account is required. Note: Quick Mode is less stable than Standard Mode, and the IP may change."),
                                               [NSString stringWithFormat:@"Network ID: %@", adhocNetId]]];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.save", @"Save")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        UITextField *field = alert.textFields.firstObject;
        NSString *value = [field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

        if (value.length == 0) {
            // 空字符串：清除预设
            [[MultiplayerManager sharedManager] setPresetNetworkId:nil];
            [strongSelf.tableView reloadData];
            return;
        }

        // 校验格式
        if (![[MultiplayerManager sharedManager] isValidNetworkId:value]) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.network_id.invalid_title", @"Invalid format")
                                          message:MPLocalized(@"mp.network_id.invalid_msg", @"Network ID must be a 16-character hexadecimal string.")];
            return;
        }

        [[MultiplayerManager sharedManager] setPresetNetworkId:value];
        [strongSelf.tableView reloadData];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 启动器模式：ZeroTier 网络创建教程

/// 显示 ZeroTier 网络创建教程
///
/// 对标 FCL 的"联机帮助"功能：说明两种联机模式的区别和使用方法。
///
/// 两种模式：
///   1. 标准模式（稳定）：在 central.zerotier.com 注册账号创建网络
///      - 优点：IP 固定、支持 Private 授权、每人独立网络
///      - 缺点：需要注册账号、配置较复杂
///   2. 快速模式（不稳定）：使用 Ad-hoc 网络自动分配
///      - 优点：无需注册账号、即开即用
///      - 缺点：只有 IPv6、公开网络、IP 可能变化
- (void)showZeroTierGuide {
    [self.view endEditing:YES];

    // 构建教程内容：两种模式对比
    NSString *modeStandard = [NSString stringWithFormat:@"%@（%@）\n%@",
                              MPLocalized(@"mp.guide.mode_standard", @"Standard Mode"),
                              MPLocalized(@"mp.guide.stable", @"Stable"),
                              MPLocalized(@"mp.guide.mode_standard_desc", @"Sign up at central.zerotier.com and create an organization to get a fixed Network ID. Stable IP, member authorization, and a private network per user.")];

    NSString *modeFast = [NSString stringWithFormat:@"%@（%@）\n%@",
                          MPLocalized(@"mp.guide.mode_fast", @"Quick Mode"),
                          MPLocalized(@"mp.guide.unstable", @"Unstable"),
                          MPLocalized(@"mp.guide.mode_fast_desc", @"Uses an ad-hoc network to auto-generate a Network ID with no signup. IPv6-only, weaker public-network security, and the IP may change.")];

    // 标准模式步骤
    NSString *standardTitle = [NSString stringWithFormat:@"\n【%@】", MPLocalized(@"mp.guide.mode_standard", @"Standard Mode")];

    NSString *step1 = [NSString stringWithFormat:@"1. %@\n   %@",
                       MPLocalized(@"mp.guide.step1_title", @"Create a ZeroTier account"),
                       MPLocalized(@"mp.guide.step1_desc", @"Visit central.zerotier.com (new Central), sign up and sign in (free; Google/GitHub/Microsoft supported).")];

    NSString *step2 = [NSString stringWithFormat:@"2. %@\n   %@",
                       MPLocalized(@"mp.guide.step2_title", @"Create an organization"),
                       MPLocalized(@"mp.guide.step2_desc", @"After signing in, enter an organization name and tap Create Organization. The free plan includes one Network Group and one Network.")];

    NSString *step3 = [NSString stringWithFormat:@"3. %@\n   %@",
                       MPLocalized(@"mp.guide.step3_title", @"Get the Network ID"),
                       MPLocalized(@"mp.guide.step3_desc", @"Expand Networks in the sidebar, open the default network (e.g. my-first-network), and copy the 16-character Network ID at the top.")];

    NSString *step4 = [NSString stringWithFormat:@"4. %@\n   %@",
                       MPLocalized(@"mp.guide.step4_title", @"Set network access control"),
                       MPLocalized(@"mp.guide.step4_desc", @"Private (recommended): manually authorize members. Public: anyone can join.")];

    NSString *step5 = [NSString stringWithFormat:@"5. %@\n   %@",
                       MPLocalized(@"mp.guide.step5_title", @"Enter it in the launcher"),
                       MPLocalized(@"mp.guide.step5_desc", @"Return here, tap the Preset Network ID row, paste, and save.")];

    NSString *step6 = [NSString stringWithFormat:@"6. %@\n   %@",
                       MPLocalized(@"mp.guide.step6_title", @"Authorize guest devices"),
                       MPLocalized(@"mp.guide.step6_desc", @"After a guest joins, open Member Devices, tap the three-dot menu → Authorize (required for Private; skip for Public).")];

    NSString *step7 = [NSString stringWithFormat:@"7. %@\n   %@",
                       MPLocalized(@"mp.guide.step7_title", @"Start multiplayer"),
                       MPLocalized(@"mp.guide.step7_desc", @"After launching the game, open multiplayer from the floating ball and choose Host.")];

    // 快速模式步骤
    NSString *fastTitle = [NSString stringWithFormat:@"\n【%@】", MPLocalized(@"mp.guide.mode_fast", @"Quick Mode")];

    NSString *fastStep1 = [NSString stringWithFormat:@"1. %@\n   %@",
                           MPLocalized(@"mp.guide.fast_step1_title", @"Tap Preset Network ID"),
                           MPLocalized(@"mp.guide.fast_step1_desc", @"On this page, tap the Preset Network ID row.")];

    NSString *fastStep2 = [NSString stringWithFormat:@"2. %@\n   %@",
                           MPLocalized(@"mp.guide.fast_step2_title", @"Choose Quick Mode"),
                           MPLocalized(@"mp.guide.fast_step2_desc", @"Tap Use Quick Mode (no signup). The system generates a Network ID automatically.")];

    NSString *fastStep3 = [NSString stringWithFormat:@"3. %@\n   %@",
                           MPLocalized(@"mp.guide.fast_step3_title", @"Start multiplayer"),
                           MPLocalized(@"mp.guide.fast_step3_desc", @"After launching the game, open multiplayer from the floating ball and choose Host.")];

    NSString *message = [NSString stringWithFormat:@"%@\n\n%@\n\n%@\n\n%@%@",
                         MPLocalized(@"mp.guide.intro", @"ZeroTier offers two multiplayer modes. Choose the one that fits:"),
                         modeStandard,
                         modeFast,
                         standardTitle, step1];

    // 使用多行格式拼接所有步骤（标准模式 7 步 + 快速模式 3 步）
    message = [NSString stringWithFormat:@"%@\n\n%@\n\n%@\n\n%@\n\n%@\n\n%@\n\n%@\n\n%@\n\n%@",
               message,
               step2,
               step3,
               step4,
               step5,
               step6,
               step7,
               fastTitle,
               [NSString stringWithFormat:@"%@\n%@\n%@", fastStep1, fastStep2, fastStep3]];

    // 添加注意事项
    message = [NSString stringWithFormat:@"%@\n\n%@",
               message,
               MPLocalized(@"mp.guide.note", @"Note: host and guests must use the same Network ID. Standard Mode requires authorizing members (Private) or setting Public. Quick Mode shares one public network.")];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:MPLocalized(@"mp.guide.title", @"ZeroTier multiplayer guide")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];

    // 「打开 central.zerotier.com」按钮：直接跳转到浏览器（标准模式需要）
    // 新版 Central：central.zerotier.com（推荐新用户使用）
    // 旧版 Central：my.zerotier.com（老用户继续使用）
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.guide.open_website", @"Open central.zerotier.com (Standard Mode)")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        NSURL *url = [NSURL URLWithString:@"https://central.zerotier.com/"];
        if (url && [[UIApplication sharedApplication] canOpenURL:url]) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }
    }]];

    // 「使用快速模式」按钮：直接生成 Ad-hoc 网络 ID
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.guide.use_fast_mode", @"Use Quick Mode")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // 检查 ZeroTier 框架可用性
        if (![[MultiplayerManager sharedManager] isFrameworkAvailable]) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.core.unavailable_title", @"Multiplayer core unavailable")
                                          message:MPLocalized(@"mp.core.unavailable_msg", @"ZeroTier multiplayer core is not loaded, so Quick Mode cannot be used.")];
            return;
        }

        // 生成 Ad-hoc 网络 ID
        NSString *adhocNetId = [[MultiplayerManager sharedManager] generateAdhocNetworkId];
        if (!adhocNetId.length) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.network_id.adhoc_failed_title", @"Generation failed")
                                          message:MPLocalized(@"mp.network_id.adhoc_failed_msg", @"Could not generate a Quick Mode Network ID. Please use Standard Mode instead.")];
            return;
        }

        // 保存为预设 Network ID
        [[MultiplayerManager sharedManager] setPresetNetworkId:adhocNetId];
        [strongSelf.tableView reloadData];

        // 提示用户
        [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.network_id.adhoc_success_title", @"Quick Mode enabled")
                                      message:[NSString stringWithFormat:@"%@\n\n%@",
                                               MPLocalized(@"mp.network_id.adhoc_success_msg", @"A Network ID was generated automatically. No account is required. Note: Quick Mode is less stable than Standard Mode, and the IP may change."),
                                               [NSString stringWithFormat:@"Network ID: %@", adhocNetId]]];
    }]];

    // 「我知道了」按钮
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.ok", @"Got it")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 房间连接

/// 连接到指定房间
///
/// 内部调用 MultiplayerManager 的 connectToRoom:completion:，
/// 并在主线程更新房间状态和 UI。连接成功后回调 completion。
- (void)connectToRoom:(MultiplayerRoom *)room completion:(void (^)(BOOL success, NSError *error))completion {
    // 关键修复（避免重复设置 status）：
    // Manager.connectToRoom: 内部已在 _stateLock 内设置 room.status = Connecting，
    // 这里不再重复设置——状态修改统一由 Manager 负责，VC 只读。
    // 仅刷新 UI 以反映 Manager 已设置的状态。
    [self refreshRooms];

    __weak typeof(self) weakSelf = self;
    [[MultiplayerManager sharedManager] connectToRoom:room completion:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            // 连接结果状态由 Manager 内部已更新（status = Connected/Error），
            // 这里仅刷新 UI 与持久化（保持原有的 lastConnectedAt 记录逻辑）。
            if (success) {
                room.lastConnectedAt = [NSDate date];
            }
            [[MultiplayerManager sharedManager] updateRoom:room];
            [strongSelf refreshRooms];

            if (completion) {
                completion(success, error);
            }
        });
    }];
}

/// 断开当前房间连接
- (void)disconnectRoom:(MultiplayerRoom *)room {
    [[MultiplayerManager sharedManager] disconnectCurrentRoom];
    room.status = MultiplayerRoomStatusDisconnected;
    [[MultiplayerManager sharedManager] updateRoom:room];
    [self refreshRooms];
}

#pragma mark - 房间行按钮回调

/// 房间行的"连接/断开"按钮回调
///
/// 通过 button.tag 找到对应的房间索引
- (void)roomButtonTapped:(UIButton *)button {
    NSInteger row = button.tag;
    if (row < 0 || row >= (NSInteger)self.rooms.count) {
        return;
    }

    MultiplayerRoom *room = self.rooms[row];

    // 防止连接中重复点击
    if (room.status == MultiplayerRoomStatusConnecting) {
        return;
    }

    if (room.status == MultiplayerRoomStatusConnected) {
        // 已连接则断开
        [self disconnectRoom:room];
    } else {
        // 未连接则连接
        [self connectToRoom:room completion:^(BOOL success, NSError *error) {
            if (!success) {
                [self showSimpleAlertWithTitle:MPLocalized(@"mp.connect.failed", @"Connection failed")
                                        message:error.localizedDescription ?: MPLocalized(@"mp.connect.failed_msg", @"Could not connect to the room. Check the Network ID and your network connection.")];
            }
        }];
    }
}

#pragma mark - 房间详情 ActionSheet

/// 显示房间详情 ActionSheet
///
/// 提供以下操作：
///   - 连接 / 断开（根据当前状态显示）
///   - 分享房间（生成分享文本，调用系统分享面板）
///   - 删除房间（二次确认后删除）
- (void)showRoomActionsForRoom:(MultiplayerRoom *)room {
    [self.view endEditing:YES];

    NSString *title = room.name.length ? room.name : MPLocalized(@"mp.room.unnamed", @"Unnamed room");
    NSString *message = [NSString stringWithFormat:@"%@: %@",
                         MPLocalized(@"mp.room.network_id", @"Network ID"),
                         room.networkId ?: @"-"];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    // 连接 / 断开按钮（根据当前状态切换标题）
    NSString *connectTitle = (room.status == MultiplayerRoomStatusConnected)
        ? MPLocalized(@"mp.room.action.disconnect", @"Disconnect")
        : MPLocalized(@"mp.room.action.connect", @"Connect");

    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:connectTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (room.status == MultiplayerRoomStatusConnected) {
            [strongSelf disconnectRoom:room];
        } else {
            [strongSelf connectToRoom:room completion:^(BOOL success, NSError *error) {
                if (!success) {
                    [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.connect.failed", @"Connection failed")
                                                  message:error.localizedDescription ?: MPLocalized(@"mp.connect.failed_msg", @"Could not connect to the room. Check the Network ID and your network connection.")];
                }
            }];
        }
    }]];

    // 分享房间按钮（使用 shareTextForRoom: 生成可读分享文本）
    [sheet addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.room.action.share", @"Share room")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSString *shareText = [[MultiplayerManager sharedManager] shareTextForRoom:room];
        UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[shareText] applicationActivities:nil];

        // iPad 适配：popover 指向屏幕中央
        if (activityVC.popoverPresentationController) {
            activityVC.popoverPresentationController.sourceView = strongSelf.view;
            activityVC.popoverPresentationController.sourceRect = CGRectMake(strongSelf.view.bounds.size.width / 2.0,
                                                                              strongSelf.view.bounds.size.height / 2.0,
                                                                              1, 1);
        }
        [strongSelf presentViewController:activityVC animated:YES completion:nil];
    }]];

    // 删除房间按钮（destructive 红色）
    [sheet addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.room.action.delete", @"Delete room")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // 二次确认对话框
        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:MPLocalized(@"mp.room.delete.confirm_title", @"Confirm delete")
                                                                         message:[NSString stringWithFormat:@"%@「%@」？\n%@",
                                                                                  MPLocalized(@"mp.room.delete.confirm_prefix", @"Delete room"),
                                                                                  room.name,
                                                                                  MPLocalized(@"mp.room.delete.confirm_warning", @"This cannot be undone.")]
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
        [confirm addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.room.delete.button", @"Delete") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            // 如果该房间已连接，先断开连接
            if (room.status == MultiplayerRoomStatusConnected) {
                [[MultiplayerManager sharedManager] disconnectCurrentRoom];
            }
            [[MultiplayerManager sharedManager] removeRoom:room.roomId];
            [strongSelf refreshRooms];
        }]];
        [strongSelf presentViewController:confirm animated:YES completion:nil];
    }]];

    // 取消按钮
    [sheet addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];

    // iPad 适配：popover 指向屏幕中央
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2.0,
                                                                    self.view.bounds.size.height / 2.0,
                                                                    1, 1);
    }

    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 启动器模式：直连

/// 点击"加入游戏"按钮：将 IP:端口 写入当前 profile，启动游戏后自动加入
- (void)joinDirectConnect {
    [self.view endEditing:YES];

    NSString *ip = [self.directIPField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *port = [self.directPortField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // 校验：IP 非空
    if (ip.length == 0) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.direct.error_title", @"Notice")
                                message:MPLocalized(@"mp.direct.error.ip_empty", @"Enter the server IP address")];
        return;
    }

    // 端口默认值
    if (port.length == 0) {
        port = @"25565";
    }

    // 校验：IP 格式
    if (![[MultiplayerManager sharedManager] isValidIPAddress:ip]) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.direct.error_title", @"Notice")
                                message:MPLocalized(@"mp.direct.error.ip_invalid", @"Invalid IP address format. Please check your input.")];
        return;
    }

    // 拼接服务器地址 "IP:端口"
    NSString *serverAddress = [NSString stringWithFormat:@"%@:%@", ip, port];

    // 将服务器地址写入当前 profile
    NSString *profileName = [PLProfiles current].selectedProfileName;
    if (!profileName || profileName.length == 0) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.direct.error_title", @"Notice")
                                message:MPLocalized(@"mp.direct.error.no_profile", @"No profile selected. Choose a game profile first.")];
        return;
    }
    [[PLProfiles current] setServerIp:serverAddress forProfile:profileName];

    // 显示成功提示
    [self showSimpleAlertWithTitle:MPLocalized(@"mp.direct.success_title", @"Server added")
                           message:[NSString stringWithFormat:@"%@ %@",
                                    MPLocalized(@"mp.direct.success_msg_prefix", @"Server added"),
                                    serverAddress]];
}

#pragma mark - 游戏内模式：房主流程

/// 点击"当房主"按钮：进入房主流程
///
/// 对标 FCL 房主流程：
///   1. 检查 ZeroTier 框架可用性
///   2. 检查预设 Network ID 是否已设置（未设置则提示去启动器设置）
///   3. 自动连接到预设 Network ID 的房间
///   4. 连接成功后弹出手动输入端口对话框（showManualPortInputAlert）
///   5. 用户在 MC 中"对局域网开放"后，手动输入聊天框显示的端口号
///   6. 生成分享代码（generateShareCodeForRoom:）
///   7. 显示分享代码（可复制、可分享）
///
/// 关键变更（端口检测改为手动输入）：
/// 之前流程的第 4-5 步是"监听 LanPortDetectorDidDetectPortNotification +
/// 自动检测 LAN 端口"，存在以下问题：
///   - latestlog.txt 可能包含上次会话的 LAN 端口日志，误检测为当前会话的端口
///   - 不同 MC 版本日志格式差异大，自动检测不可靠
///   - 用户在游戏未真正"对局域网开放"时就生成了分享代码
/// 现在改为手动输入端口，确保端口来自当前会话的真实 LAN 端口。
- (void)hostButtonTapped {
    NSLog(@"[MP-ROLE] view=ingame event=host_tapped role=host");   // ★ [MP-ROLE]
    [self.view endEditing:YES];

    // 检查 1：ZeroTier 框架可用性
    if (![[MultiplayerManager sharedManager] isFrameworkAvailable]) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.core.unavailable_title", @"Multiplayer core unavailable")
                                message:MPLocalized(@"mp.core.unavailable_msg", @"ZeroTier multiplayer core is not loaded, so hosting is unavailable. Please use a build that includes the real zt.framework.")];
        return;
    }

    // 检查 2：预设 Network ID 是否已设置
    NSString *presetNetId = [[MultiplayerManager sharedManager] presetNetworkId];
    if (!presetNetId.length) {
        // 未设置：提示用户去启动器设置
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:MPLocalized(@"mp.host.no_network_id_title", @"Network ID not set")
                                                                       message:MPLocalized(@"mp.host.no_network_id_msg", @"The host must set a preset ZeroTier Network ID in the launcher multiplayer screen first.")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.ok", @"OK") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    // 校验 Network ID 格式
    if (![[MultiplayerManager sharedManager] isValidNetworkId:presetNetId]) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.network_id.invalid_title", @"Invalid Network ID format")
                                message:MPLocalized(@"mp.network_id.invalid_msg", @"Set a valid 16-character hexadecimal Network ID in the launcher multiplayer screen")];
        return;
    }

    // ============================================================
    // 幂等性检查：房主流程已激活时的短路处理
    // ============================================================
    // 关键修复：之前再次点击"当房主"按钮会重新走整个连接流程，
    // 即使已经连接成功且 LAN 端口已检测到，也会：
    //   1. 清空 lastShareCode/lastServerAddress（丢失已生成的分享代码）
    //   2. 重新显示"正在开启联机"进度提示
    //   3. 重新调用 connectToRoom（把 status 重置为 Connecting）
    //   4. 连接成功后再次显示"等待检测 LAN 端口..."提示（误导）
    //   5. 由于 LanPortDetector 对相同端口去重，不会再次触发 lanPortDidDetect:
    //      导致用户无法重新看到分享代码
    //
    // 修复方案：如果房主流程已激活且房间已连接，根据是否已有分享代码
    // 直接显示对应提示，不重新走连接流程。
    if (self.isHostFlowActive) {
        MultiplayerRoom *currentRoom = [[MultiplayerManager sharedManager] currentRoom];
        if (currentRoom && [currentRoom.networkId isEqualToString:presetNetId]) {
            // 房间已连接
            if (self.lastShareCode.length) {
                // 分享代码已存在
                //
                // 关键修复（多房客优化）：房主 IP 变化检测
                // 如果 ZeroTier 重连后房主 IP 已变化，旧分享代码中的 hostIP 已失效，
                // 房客用旧代码无法加入房间。需要使用当前 IP 重新生成分享代码。
                // LAN 端口本身不受 ZeroTier IP 变化影响（它绑定在 MC Netty 上），可复用。
                NSString *currentLocalIP = [[MultiplayerManager sharedManager] currentLocalIP];
                if (currentLocalIP.length > 0 &&
                    currentRoom.hostIP.length > 0 &&
                    ![currentRoom.hostIP isEqualToString:currentLocalIP]) {
                    NSLog(@"[MultiplayerVC] Host flow active but IP changed: %@ -> %@, regenerating share code with existing port",
                          currentRoom.hostIP, currentLocalIP);
                    [self generateShareCodeWithPort:currentRoom.hostPort];
                } else {
                    // IP 未变化：直接显示分享代码
                    NSLog(@"[MultiplayerVC] Host flow active and share code exists, displaying directly");
                    [self showHostShareCodeAlert];
                }
            } else {
                // 分享代码不存在：弹出手动输入端口对话框
                // 关键修复（端口检测改为手动输入）：不再自动检测端口，改为用户手动输入
                NSLog(@"[MultiplayerVC] Host flow active but share code not yet generated, showing manual port input dialog");
                [self showManualPortInputAlert];
            }
            return;
        }
        // 房间未连接或 networkId 不匹配：继续走完整流程（会先断开旧连接）
    }

    // 标记房主流程激活
    self.isHostFlowActive = YES;
    self.lastShareCode = nil;
    self.lastServerAddress = nil;

    // 构建/复用房主房间对象
    MultiplayerRoom *room = self.hostRoom;
    if (!room || ![room.networkId isEqualToString:presetNetId]) {
        room = [[MultiplayerRoom alloc] init];
        room.roomId = [[MultiplayerManager sharedManager] generateRoomId];
        room.name = MPLocalized(@"mp.host.default_room_name", @"My multiplayer rooms");
        room.networkId = presetNetId;
        room.hostIP = @"";
        room.hostPort = @"25565";
        room.roomDescription = @"";
        room.ownerName = @"";
        room.status = MultiplayerRoomStatusDisconnected;
        // 关键修复：显式标记房主角色，替代 IP 启发式判断
        room.role = MultiplayerRoomRoleHost;
        room.createdAt = [NSDate date];
        self.hostRoom = room;
    } else {
        // 已存在的房间确保 role 正确（兼容旧数据 role=Unknown 的情况）
        room.role = MultiplayerRoomRoleHost;
    }

    // 如果当前已连接到其他房间，先断开
    MultiplayerRoom *currentRoom = [[MultiplayerManager sharedManager] currentRoom];
    if (currentRoom && ![currentRoom.networkId isEqualToString:presetNetId]) {
        [[MultiplayerManager sharedManager] disconnectCurrentRoom];
    }

    // 显示"正在连接"进度提示（可动态更新进度文本）
    //
    // 关键修复（前台无反馈）：
    // 之前只显示一个静态的"正在连接到 ZeroTier 网络，请稍候..."提示，
    // 用户无法知道后台进度，连接流程耗时 15-30 秒期间用户只能干等。
    // 现在使用 showConnectionProgressWithTitle:message: 显示一个带 Cancel 按钮的 Alert，
    // 并通过 multiplayerConnectionProgress: 回调实时更新 message 为"步骤 1/6：..."等进度。
    [self showConnectionProgressWithTitle:MPLocalized(@"mp.host.connecting_title", @"Starting multiplayer")
                                   message:MPLocalized(@"mp.host.connecting_msg", @"Connecting to ZeroTier…")];

    // 关键修复（端口检测改为手动输入）：
    // 不再启动 LanPortDetector 的自动检测。自动检测存在以下问题：
    //   - latestlog.txt 可能包含上次会话的 LAN 端口日志，误检测为当前会话的端口
    //   - 不同 MC 版本日志格式差异大，自动检测不可靠
    //   - 用户在游戏未真正"对局域网开放"时就生成了分享代码
    // 现在改为手动输入端口：连接成功后弹出输入框，用户在 MC 中"对局域网开放"后
    // 手动输入聊天框显示的端口号，才会生成分享代码。

    // 连接到预设房间
    __weak typeof(self) weakSelf = self;
    [self connectToRoom:room completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // 先关闭进度提示 Alert，再显示结果
        [strongSelf dismissConnectionProgressAlertWithCompletion:^{
            if (success) {
                // 连接成功
                //
                // 关键修复（端口检测改为手动输入）：
                // 之前依赖 LanPortDetector 自动检测 LAN 端口（通过拦截 MC 日志或读取 latestlog.txt），
                // 存在以下问题：
                //   1. 自动检测不可靠：不同 MC 版本日志格式差异大，部分版本无法匹配
                //   2. 误检测旧日志：latestlog.txt 可能包含上次会话的 LAN 端口日志，
                //      导致 MC 还没真正"对局域网开放"就生成了错误的分享代码
                //   3. 用户在游戏未进入时就能生成代码：因为 LanPortDetector 从旧日志中
                //      读取到端口，立即触发分享代码生成
                //
                // 修复方案：改为手动输入端口。连接成功后弹出手动输入对话框，
                // 用户必须在 MC 中"对局域网开放"后，手动输入聊天框显示的端口号，
                // 才会生成分享代码。这样既保证了端口的准确性，也避免了在游戏未真正
                // 开放局域网时生成错误代码的问题。
                NSLog(@"[MultiplayerVC] Connection successful, waiting for user to manually enter LAN port");
                [strongSelf showManualPortInputAlert];
            } else {
                // 连接失败
                strongSelf.isHostFlowActive = NO;
                [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.connect.failed", @"Connection failed")
                                              message:error.localizedDescription ?: MPLocalized(@"mp.connect.failed_msg", @"Could not connect to the ZeroTier network. Check the Network ID and your network connection.")];
            }
        }];
        [strongSelf.tableView reloadData];
    }];

    [self.tableView reloadData];
}

/// 显示房主连接成功后的手动输入端口对话框
///
/// 关键修复（端口检测改为手动输入）：
/// 之前连接成功后依赖 LanPortDetector 自动检测 LAN 端口，存在以下问题：
///   - latestlog.txt 可能包含上次会话的 LAN 端口日志，误检测为当前会话的端口
///   - 不同 MC 版本日志格式差异大，自动检测不可靠
///   - 用户在游戏未真正"对局域网开放"时就生成了分享代码
///
/// 现在改为手动输入端口：连接成功后弹出输入对话框，提示用户在 MC 中
/// "对局域网开放"后，手动输入聊天框显示的端口号。用户输入端口号后
/// 才会生成分享代码。这样既保证了端口的准确性，也避免了在游戏未真正
/// 开放局域网时生成错误代码的问题。
- (void)showManualPortInputAlert {
    NSString *localIP = [[MultiplayerManager sharedManager] currentLocalIP] ?: @"-";

    // ★ [PORT-AUTO] 自动探测 MC 局域网端口（读游戏日志取最后一次出现的端口），预填到输入框
    NSString *autoGameDir = [McLanPortDetector resolveGameDirectoryWithInstanceName:getPrefObject(@"general.game_directory")];
    uint16_t autoPort = [McLanPortDetector detectPortInGameDirectory:autoGameDir
                                                       launcherHome:[McLanPortDetector launcherHome]];
    NSString *autoPortText = (autoPort > 0) ? [NSString stringWithFormat:@"%u", autoPort] : nil;
    NSLog(@"[PORT-AUTO] host manual-port dialog prefill: gameDir=%@ detected=%u", autoGameDir ?: @"(nil)", autoPort);

    NSMutableString *message = [NSMutableString stringWithFormat:@"%@\n\n%@\n%@\n\n%@: %@",
                         MPLocalized(@"mp.host.connected_msg", @"Connected to the multiplayer network. Open to LAN in Minecraft, then enter the port"),
                         MPLocalized(@"mp.host.tip.create_world", @"Create a world in Minecraft and tap Open to LAN"),
                         MPLocalized(@"mp.host.tip.manual_port", @"After opening to LAN, Minecraft shows the port in chat — enter it below"),
                         MPLocalized(@"mp.host.local_ip", @"Device IP"),
                         localIP];
    if (autoPortText.length > 0) {
        [message appendFormat:@"\n\n%@", [NSString stringWithFormat:
            MPLocalized(@"mp.host.port_autodetected", @"Detected port %@. You can generate a share code now (or edit it manually)"), autoPortText]];
    } else {
        [message appendFormat:@"\n\n%@", MPLocalized(@"mp.host.port_notdetected", @"No port detected. Open to LAN in-game first (or enter it manually)")];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:MPLocalized(@"mp.host.connected_title", @"Multiplayer enabled")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = MPLocalized(@"mp.host.port_placeholder", @"Port (e.g. 54321)");
        textField.keyboardType = UIKeyboardTypeNumberPad;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        if (autoPortText.length > 0) textField.text = autoPortText;   // ★ [PORT-AUTO] 预填
    }];

    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.cancel", @"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.host.generate_code", @"Generate share code")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        UITextField *field = alert.textFields.firstObject;
        NSString *port = [field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

        // 校验：端口非空
        if (port.length == 0) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.host.port_empty_title", @"Port is empty")
                                          message:MPLocalized(@"mp.host.port_empty_msg", @"Enter the LAN port")];
            return;
        }

        // 校验：端口范围（1-65535）
        NSInteger portNum = [port integerValue];
        if (portNum < 1 || portNum > 65535) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.host.port_invalid_title", @"Invalid port")
                                          message:MPLocalized(@"mp.host.port_invalid_msg", @"Port must be between 1 and 65535")];
            return;
        }

        NSLog(@"[MultiplayerVC] User manually entered LAN port: %@", port);
        // 将端口设置到 LanPortDetector（手动输入），方便其他模块读取
        // 注意：LanPortDetector 的 API 是 sharedInstance + setManualPort:(uint16_t)
        [[LanPortDetector sharedInstance] setManualPort:(uint16_t)portNum];
        // 生成分享代码（内部会启动 PortForwarder 房主模式）
        [strongSelf generateShareCodeWithPort:port];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 游戏内模式：LAN 端口检测回调

/// LanPortDetector 检测到端口后的回调
///
/// 注意：自动检测已禁用（改为手动输入端口），此回调通常不会被触发。
/// 保留此方法是为了兼容性：如果未来重新启用自动检测，或外部代码通过
/// setManualPort: 设置端口后调用此回调，仍能正常生成分享代码。
///
/// 房主流程核心：MC 开放局域网后，LanPortDetector 自动检测到端口号，
/// 触发本回调。本方法负责：
///   1. 将检测到的端口写入房主房间对象
///   2. 生成分享代码（generateShareCodeForRoom:）
///   3. 刷新 UI 显示分享代码
- (void)lanPortDidDetect:(NSNotification *)notification {
    // 仅在房主流程激活时处理
    if (!self.isHostFlowActive) {
        return;
    }

    // LanPortDetector.setManualPort: 发送的 userInfo 中 port 是 NSNumber（@(port)），
    // 不是 NSString。这里统一转换成 NSString 再使用。
    id portValue = notification.userInfo[@"port"];
    NSString *port = nil;
    if ([portValue isKindOfClass:[NSString class]]) {
        port = portValue;
    } else if ([portValue isKindOfClass:[NSNumber class]]) {
        port = [(NSNumber *)portValue stringValue];
    }
    if (!port.length) {
        return;
    }

    // 关键修复（避免重复生成分享代码）：
    // 手动输入流程中，showManualPortInputAlert 已经在用户点击"生成"按钮时
    // 直接调用了 generateShareCodeWithPort: 生成分享代码。
    // 此时 LanPortDetector.setManualPort: 又会发送通知触发本回调，
    // 会导致分享代码被生成两次（虽然 PortForwarder 启动是幂等的，但显示会闪烁）。
    // 因此本回调仅做日志记录，不再重复调用 generateShareCodeWithPort:。
    NSLog(@"[MultiplayerVC] lanPortDidDetect: received port %@ notification (manual input flow already generated share code, skipping duplicate)", port);
}

/// 根据用户输入的 LAN 端口生成分享代码并显示
///
/// 此方法供以下场景复用：
///   1. lanPortDidDetect: 收到 LanPortDetector 通知时调用（兼容性保留，通常不触发）
///   2. showManualPortInputAlert 中用户手动输入端口后调用（主要场景）
///   3. hostButtonTapped 幂等检查中复用（通过 showManualPortInputAlert 间接调用）
///
/// 关键变更（端口检测改为手动输入）：
/// 之前此方法在 hostButtonTapped 连接成功后由自动检测端口触发，
/// 现在改为由用户手动输入端口后触发，确保端口来自当前会话的真实 LAN 端口。
- (void)generateShareCodeWithPort:(NSString *)port {
    MultiplayerRoom *room = self.hostRoom;
    if (!room) {
        return;
    }

    // 更新房间的端口和本机 IP
    room.hostPort = port;
    NSString *localIP = [[MultiplayerManager sharedManager] currentLocalIP];

    // 关键修复（多房客优化）：hostIP 非空保护
    // 如果 currentLocalIP 为空（异常情况），不生成无效分享代码
    if (!localIP.length) {
        NSLog(@"[MultiplayerVC] Warning: currentLocalIP is nil, cannot generate valid share code");
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.host.share_code_failed", @"Failed to generate share code")
                                  message:MPLocalized(@"mp.host.no_local_ip", @"Could not get this device's ZeroTier IP. Check the network and try again.")];
        return;
    }

    // 关键修复（多房客优化）：房主 IP 变化检测
    // 如果 room.hostIP 已存在且与当前 localIP 不同，说明房主 ZeroTier IP 已变化
    // 旧分享代码已失效，需要提示房主重新分享
    BOOL ipChanged = (room.hostIP.length > 0 && ![room.hostIP isEqualToString:localIP]);
    if (ipChanged) {
        NSLog(@"[MultiplayerVC] Host IP changed: %@ -> %@, old share code is invalid", room.hostIP, localIP);
    }

    room.hostIP = localIP;
    [[MultiplayerManager sharedManager] updateRoom:room];

    // 生成分享代码
    self.lastShareCode = [[MultiplayerManager sharedManager] generateShareCodeForRoom:room];
    // 关键修复（P1-4）：IPv6 地址需要用方括号包裹，否则冒号会与端口分隔符混淆
    if ([room.hostIP containsString:@":"]) {
        self.lastServerAddress = [NSString stringWithFormat:@"[%@]:%@", room.hostIP, room.hostPort];
    } else {
        self.lastServerAddress = [NSString stringWithFormat:@"%@:%@", room.hostIP, room.hostPort];
    }

    // 刷新表格，让 Section 1 显示最新的分享代码
    [self.tableView reloadData];

    // 弹出提示告知用户分享代码已生成
    [self showHostShareCodeAlert];

    // 如果 IP 变化，额外提示房主旧代码已失效
    if (ipChanged) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showSimpleAlertWithTitle:MPLocalized(@"mp.host.ip_changed_title", @"Host IP changed")
                                      message:MPLocalized(@"mp.host.ip_changed_msg", @"Your ZeroTier IP changed, so earlier share codes no longer work. Send guests the new share code.")];
        });
    }
}

/// 显示房主分享代码 Alert
///
/// 提供以下操作：
///   - 复制分享代码到剪贴板
///   - 通过系统分享面板分享
- (void)showHostShareCodeAlert {
    NSString *shareCode = self.lastShareCode ?: @"";
    NSString *serverAddr = self.lastServerAddress ?: @"-";

    NSString *message = [NSString stringWithFormat:@"%@\n\n%@\n\n%@\n%@\n\n%@",
                         MPLocalized(@"mp.host.share_code_ready", @"Share code generated! Send this code to your guests:"),
                         shareCode,
                         MPLocalized(@"mp.host.tip.wait_guest", @"Guests enter this code to join your multiplayer network"),
                         [NSString stringWithFormat:@"%@: %@", MPLocalized(@"mp.host.server_address", @"Server address"), serverAddr],
                         MPLocalized(@"mp.host.tip.copy_or_share", @"You can copy or share the code with the buttons below")];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:MPLocalized(@"mp.host.share_code_title", @"Share code generated")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];

    // 复制按钮
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.host.copy_code", @"Copy code")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        pasteboard.string = shareCode;
    }]];

    // 分享按钮
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.host.share_button", @"Share…")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[shareCode] applicationActivities:nil];
        if (activityVC.popoverPresentationController) {
            activityVC.popoverPresentationController.sourceView = strongSelf.view;
            activityVC.popoverPresentationController.sourceRect = CGRectMake(strongSelf.view.bounds.size.width / 2.0,
                                                                              strongSelf.view.bounds.size.height / 2.0,
                                                                              1, 1);
        }
        [strongSelf presentViewController:activityVC animated:YES completion:nil];
    }]];

    // 关闭按钮
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.ok", @"OK")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 游戏内模式：房客流程

/// 点击"当房客"按钮：进入房客流程
///
/// 对标 FCL 房客流程：
///   1. 弹出输入框（UIAlertController with textField）
///   2. 用户输入分享代码
///   3. 解析代码（parseShareCode:）
///   4. 连接到房间（connectToRoom:completion:）
///   5. 连接成功后提示并显示服务器地址
- (void)guestButtonTapped {
    NSLog(@"[MP-ROLE] view=ingame event=guest_tapped role=guest");   // ★ [MP-ROLE]
    [self.view endEditing:YES];

    // 检查 ZeroTier 框架可用性
    if (![[MultiplayerManager sharedManager] isFrameworkAvailable]) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.core.unavailable_title", @"Multiplayer core unavailable")
                                message:MPLocalized(@"mp.core.unavailable_msg", @"ZeroTier multiplayer core is not loaded, so joining as a guest is unavailable. Please use a build that includes the real zt.framework.")];
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:MPLocalized(@"mp.guest.input_title", @"Enter share code")
                                                                   message:MPLocalized(@"mp.guest.input_msg", @"Enter the share code from the host")
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = MPLocalized(@"mp.guest.code_placeholder", @"Paste the share code here");
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.keyboardType = UIKeyboardTypeASCIICapable;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.cancel", @"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.guest.join_button", @"Join")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        UITextField *field = alert.textFields.firstObject;
        NSString *code = [field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

        // 校验：代码非空
        if (code.length == 0) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.guest.error_title", @"Input is empty")
                                          message:MPLocalized(@"mp.guest.error.empty", @"Enter the share code from the host")];
            return;
        }

        // 解析分享代码
        MultiplayerRoom *parsedRoom = [[MultiplayerManager sharedManager] parseShareCode:code];
        if (!parsedRoom) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.guest.error_title", @"Invalid code")
                                          message:MPLocalized(@"mp.guest.error.invalid_code", @"Could not parse the share code. Make sure it is complete and correct.")];
            return;
        }

        // 校验解析出的 Network ID
        if (!parsedRoom.networkId.length || ![[MultiplayerManager sharedManager] isValidNetworkId:parsedRoom.networkId]) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.guest.error_title", @"Invalid code")
                                          message:MPLocalized(@"mp.guest.error.invalid_network_id", @"The Network ID in the share code is invalid")];
            return;
        }

        // 关键修复（P0-6）：校验分享码中的 hostIP 非空
        // 房客必须有房主 IP 才能进行端口转发，空 hostIP 的分享码无法使用
        if (!parsedRoom.hostIP.length) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.sharecode.invalid", @"Invalid share code")
                                          message:MPLocalized(@"mp.sharecode.missing_host", @"Share code is missing the host IP. Make sure the code is complete.")];
            return;
        }

        [strongSelf performGuestJoinWithRoom:parsedRoom shareCode:code];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

/// 房客流程：执行加入房间
///
/// @param parsedRoom 从分享代码解析出的房间对象
/// @param shareCode 原始分享代码（用于显示）
- (void)performGuestJoinWithRoom:(MultiplayerRoom *)parsedRoom shareCode:(NSString *)shareCode {
    // 标记房客流程激活
    self.isGuestFlowActive = YES;
    self.lastShareCode = shareCode;
    // 临时设置房主地址，连接成功后会在 showGuestConnectedAlert 中更新为端口转发地址
    self.lastServerAddress = [NSString stringWithFormat:@"%@:%@", parsedRoom.hostIP, parsedRoom.hostPort];

    // 设置房客房间对象（保存以便显示状态）
    self.guestRoom = parsedRoom;

    // 如果当前已连接到其他房间，先断开
    MultiplayerRoom *currentRoom = [[MultiplayerManager sharedManager] currentRoom];
    if (currentRoom && ![currentRoom.networkId isEqualToString:parsedRoom.networkId]) {
        [[MultiplayerManager sharedManager] disconnectCurrentRoom];
    }

    // 显示"正在连接"进度提示（可动态更新进度文本）
    //
    // 关键修复（前台无反馈）：
    // 与 hostButtonTapped 相同，使用可更新进度的 Alert 替代静态提示。
    [self showConnectionProgressWithTitle:MPLocalized(@"mp.guest.connecting_title", @"Joining multiplayer")
                                   message:MPLocalized(@"mp.guest.connecting_msg", @"Connecting to the host ZeroTier network…")];

    // 连接到房间
    __weak typeof(self) weakSelf = self;
    [self connectToRoom:parsedRoom completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // 先关闭进度提示 Alert，再显示结果
        [strongSelf dismissConnectionProgressAlertWithCompletion:^{
            if (success) {
                // 连接成功：显示房客加入成功提示
                [strongSelf showGuestConnectedAlert];
            } else {
                // 连接失败
                strongSelf.isGuestFlowActive = NO;
                [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.connect.failed", @"Connection failed")
                                              message:error.localizedDescription ?: MPLocalized(@"mp.connect.failed_msg", @"Could not connect to the host network. Check the share code and your network connection.")];
            }
        }];
        [strongSelf.tableView reloadData];
    }];

    [self.tableView reloadData];
}

/// 显示房客连接成功后的提示
///
/// 对标 FCL 房客加入成功后的引导：
///   - "已连接到房主的联机网络"
///   - 自动将服务器地址写入当前 profile（下次启动 MC 自动连接）
///   - 自动将服务器地址复制到剪贴板（方便在 MC 中粘贴）
///   - 显示操作引导和服务器地址
///
/// 由于我们使用进程内 libzt（不创建系统网络接口），MC 的 UDP 局域网广播
/// 无法通过 ZeroTier 网络，因此"自动发现房间"不可行。替代方案是：
///   1. 自动写入 profile 的 serverIp（下次启动 MC 时自动连接）
///   2. 自动复制服务器地址到剪贴板（方便房客在 MC 中"添加服务器"时粘贴）
///   3. 显示清晰的操作引导
- (void)showGuestConnectedAlert {
    MultiplayerRoom *room = self.guestRoom;
    // 关键修复（P1-5）：hostIP 为空时显示"未知"，而非用 currentLocalIP 误导用户
    NSString *hostIP = room.hostIP.length ? room.hostIP : MPLocalized(@"mp.unknown", @"Unknown");
    NSString *hostPort = room.hostPort.length ? room.hostPort : @"25565";

    // 关键修复：MC 使用 Netty 的 NioSocketChannel，不走 Java 的 SOCKS5 代理。
    // 房客不能直接输入房主的 ZeroTier IP（系统无法路由），必须通过本地端口转发器。
    // PortForwarder 在 127.0.0.1:25565（或下一个可用端口）监听，转发到房主的 ZeroTier IP:端口。
    // 房客在 MC 中输入 127.0.0.1:转发端口 即可连接。
    uint16_t forwardPort = [[MultiplayerManager sharedManager] currentForwardingPort];
    NSString *serverAddress;
    if (forwardPort > 0) {
        // 端口转发器已启动，使用本地地址
        serverAddress = [NSString stringWithFormat:@"127.0.0.1:%u", forwardPort];
        NSLog(@"[MultiplayerVC] Guest using port forwarding address: %@ (forwarding to %@:%@)",
              serverAddress, hostIP, hostPort);
        self.lastServerAddress = serverAddress;

        // 自动将服务器地址写入当前 profile（下次启动 MC 时会自动连接到此服务器）
        NSString *profileName = [PLProfiles current].selectedProfileName;
        if (profileName && profileName.length > 0) {
            [[PLProfiles current] setServerIp:serverAddress forProfile:profileName];
            NSLog(@"[Multiplayer] Auto-wrote server address %@ to profile %@", serverAddress, profileName);
        }
    } else {
        // 关键修复（P0-5）：端口转发器未启动，不写入 profile
        // 房客无法通过 ZeroTier IP 直连（系统无法路由），写入 profile 会导致下次启动 MC 连接失败
        serverAddress = [NSString stringWithFormat:@"%@:%@", hostIP, hostPort];
        NSLog(@"[MultiplayerVC] Warning: port forwarder not started, not writing profile serverIp");
        // 显示警告提示而非成功提示
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.connect.failed", @"Connection failed")
                               message:MPLocalized(@"mp.connect.port_forward_failed_msg", @"Port forwarder failed to start, so the host could not be reached. Disconnect and try again.")];
        return;
    }

    // 自动复制服务器地址到剪贴板（方便房客在 MC 中"添加服务器"时直接粘贴）
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    pasteboard.string = serverAddress;

    // 构建提示信息
    NSString *message = [NSString stringWithFormat:@"%@\n\n%@\n%@\n\n%@: %@\n\n%@",
                         MPLocalized(@"mp.guest.connected_msg", @"Connected to the host multiplayer network"),
                         MPLocalized(@"mp.guest.tip.add_server", @"In Minecraft multiplayer, tap Add Server and paste this address to join"),
                         MPLocalized(@"mp.guest.tip.address_copied", @"Server address copied to the clipboard — paste it directly"),
                         MPLocalized(@"mp.guest.server_address", @"Server address"),
                         serverAddress,
                         MPLocalized(@"mp.guest.tip.auto_saved", @"Address saved to the current profile and will connect automatically next launch")];

    [self showSimpleAlertWithTitle:MPLocalized(@"mp.guest.connected_title", @"Joined multiplayer")
                           message:message];
}

#pragma mark - MultiplayerManagerDelegate

/// ZeroTier 节点已上线：刷新房间列表与状态
- (void)multiplayerNodeOnline {
    [self refreshRooms];
    [self.tableView reloadData];
}

/// ZeroTier 节点已离线：刷新房间列表与状态
- (void)multiplayerNodeOffline {
    [self refreshRooms];
    [self.tableView reloadData];
}

/// 指定房间已连接成功：刷新房间列表与状态
- (void)multiplayerRoomConnected:(MultiplayerRoom *)room {
    [self refreshRooms];
    [self.tableView reloadData];
}

/// 指定房间连接失败：刷新房间列表与状态
- (void)multiplayerRoom:(MultiplayerRoom *)room didFailWithError:(NSError *)error {
    [self refreshRooms];
    [self.tableView reloadData];
}

/// ZeroTier 框架可用性检测结果：刷新房间列表
- (void)multiplayerFrameworkAvailabilityChecked:(BOOL)available {
    [self refreshRooms];
    [self.tableView reloadData];
}

/// 连接流程进度更新
///
/// 由 MultiplayerManager 的 notifyConnectionProgress: 在主线程调用。
/// 更新 connectionProgressAlert 的 message 属性，让用户实时看到当前连接步骤。
///
/// 关键修复（前台无反馈）：
/// 之前连接流程只显示静态"正在连接到 ZeroTier 网络"提示，
/// 用户无法知道后台进度（启动节点、等待上线、加入网络、等待就绪、启动代理...）。
/// 现在通过此回调实时更新进度文本，让用户看到详细的步骤信息。
///
/// @param message 进度描述文本（如"步骤 2/6：正在等待节点上线..."）
- (void)multiplayerConnectionProgress:(NSString *)message {
    // 此方法已在主线程调用（由 MultiplayerManager.notifyConnectionProgress: 保证）
    if (self.connectionProgressAlert) {
        // 更新已显示的进度 Alert 的 message
        // UIAlertController 的 message 属性可以在 present 后动态更新，
        // 系统会自动刷新 UI 显示，无需重新 present。
        self.connectionProgressAlert.message = message;
    }
    NSLog(@"[MultiplayerVC] Connection progress: %@", message);
}

#pragma mark - 工具方法

/// 刷新房间列表（主线程）
- (void)refreshRooms {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.rooms = [[MultiplayerManager sharedManager] savedRooms] ?: @[];
        [self.tableView reloadData];
    });
}

/// 显示简单的 Alert 提示
- (void)showSimpleAlertWithTitle:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 关键修复：显示新 Alert 前清除进度 Alert 引用（如果存在）
        self.connectionProgressAlert = nil;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.ok", @"OK") style:UIAlertActionStyleDefault handler:nil]];
        // 避免重复 present
        if (self.presentedViewController) {
            [self.presentedViewController dismissViewControllerAnimated:NO completion:^{
                [self presentViewController:alert animated:YES completion:nil];
            }];
        } else {
            [self presentViewController:alert animated:YES completion:nil];
        }
    });
}

/// 显示连接进度 Alert（可动态更新 message）
///
/// 此 Alert 包含一个"取消"按钮，允许用户在连接过程中取消连接。
/// 取消时会调用 disconnectCurrentRoom 中止连接流程。
///
/// 显示后，通过 multiplayerConnectionProgress: 回调更新 self.connectionProgressAlert.message
/// 即可实时更新 Alert 中显示的进度文本，无需重新 present。
///
/// @param title   Alert 标题（如"正在开启联机"）
/// @param message 初始进度文本（如"正在连接到 ZeroTier 网络，请稍候..."）
- (void)showConnectionProgressWithTitle:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 如果已有进度 Alert 在显示，先关闭它
        if (self.connectionProgressAlert && self.presentedViewController == self.connectionProgressAlert) {
            [self dismissViewControllerAnimated:NO completion:^{
                [self presentNewConnectionProgressAlertWithTitle:title message:message];
            }];
        } else if (self.presentedViewController) {
            // 有其他 VC 在显示（如之前的简单 Alert），先关闭
            [self.presentedViewController dismissViewControllerAnimated:NO completion:^{
                [self presentNewConnectionProgressAlertWithTitle:title message:message];
            }];
        } else {
            [self presentNewConnectionProgressAlertWithTitle:title message:message];
        }
    });
}

/// 内部方法：创建并 present 新的连接进度 Alert
- (void)presentNewConnectionProgressAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];

    // 添加"取消"按钮：用户可在连接过程中取消
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.cancel", @"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // 用户取消连接：中止正在进行的连接流程
        NSLog(@"[MultiplayerVC] User cancelled the connection flow");
        strongSelf.isHostFlowActive = NO;
        strongSelf.isGuestFlowActive = NO;
        [[MultiplayerManager sharedManager] disconnectCurrentRoom];
        strongSelf.connectionProgressAlert = nil;
        [strongSelf.tableView reloadData];
    }]];

    self.connectionProgressAlert = alert;
    [self presentViewController:alert animated:YES completion:nil];
}

/// 关闭连接进度 Alert
///
/// 在连接完成（成功或失败）后调用，关闭进度提示 Alert，
/// 然后在 completion 中显示结果 Alert（成功提示或错误提示）。
///
/// @param completion Alert 关闭后的回调
- (void)dismissConnectionProgressAlertWithCompletion:(void (^)(void))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.connectionProgressAlert && self.presentedViewController == self.connectionProgressAlert) {
            // 进度 Alert 正在显示：关闭它，然后在 completion 中执行后续操作
            self.connectionProgressAlert = nil;
            [self dismissViewControllerAnimated:YES completion:^{
                if (completion) completion();
            }];
        } else {
            // 进度 Alert 不在显示（可能已被用户取消或未创建）：
            // 清除引用，直接执行 completion
            self.connectionProgressAlert = nil;
            if (completion) completion();
        }
    });
}

/// 生成纯色圆形小图标（用于状态指示点）
/// @param color 圆形颜色
/// @param size 圆形直径（pt）
/// @return 圆形 UIImage
- (UIImage *)circleImageWithColor:(UIColor *)color size:(CGFloat)size {
    CGRect rect = CGRectMake(0, 0, size, size);
    UIGraphicsBeginImageContextWithOptions(rect.size, NO, [UIScreen mainScreen].scale);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(context, color.CGColor);
    CGContextFillEllipseInRect(context, rect);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

/// 获取房间状态对应的颜色
/// @param status 房间状态
/// @return 状态颜色（连接中=橙、已连接=绿、断开=灰、错误=红）
- (UIColor *)colorForRoomStatus:(MultiplayerRoomStatus)status {
    switch (status) {
        case MultiplayerRoomStatusDisconnected:
            return [UIColor systemGrayColor];
        case MultiplayerRoomStatusConnecting:
            return [UIColor systemOrangeColor];
        case MultiplayerRoomStatusConnected:
            return [UIColor systemGreenColor];
        case MultiplayerRoomStatusError:
            return [UIColor systemRedColor];
    }
    return [UIColor systemGrayColor];
}

/// 获取房间状态对应的本地化文本
/// @param status 房间状态
/// @return 状态文本（"未连接" / "连接中" / "已连接" / "错误"）
- (NSString *)textForRoomStatus:(MultiplayerRoomStatus)status {
    switch (status) {
        case MultiplayerRoomStatusDisconnected:
            return MPLocalized(@"mp.room.status.disconnected", @"Disconnected");
        case MultiplayerRoomStatusConnecting:
            return MPLocalized(@"mp.room.status.connecting", @"Connecting");
        case MultiplayerRoomStatusConnected:
            return MPLocalized(@"mp.room.status.connected", @"Connected");
        case MultiplayerRoomStatusError:
            return MPLocalized(@"mp.room.status.error", @"Error");
    }
    return @"";
}

/// 创建房间行的连接/断开按钮
///
/// 按钮样式：圆角矩形，宽 64pt 高 32pt
/// - 已连接：显示"断开"，红色背景
/// - 连接中：显示"连接中"，灰色背景，禁用点击
/// - 其他：显示"连接"，蓝色背景
///
/// @param room 房间对象
/// @return 配置好的按钮
- (UIButton *)makeActionButtonForRoom:(MultiplayerRoom *)room {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(0, 0, 64, 32);
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    button.layer.cornerRadius = 8;
    button.layer.masksToBounds = YES;

    NSString *title;
    UIColor *bgColor;

    if (room.status == MultiplayerRoomStatusConnected) {
        title = MPLocalized(@"mp.room.button.disconnect", @"Disconnect");
        bgColor = [UIColor systemRedColor];
        button.enabled = YES;
    } else if (room.status == MultiplayerRoomStatusConnecting) {
        title = MPLocalized(@"mp.room.button.connecting", @"Connecting");
        bgColor = [UIColor systemGrayColor];
        button.enabled = NO;
    } else {
        title = MPLocalized(@"mp.room.button.connect", @"Connect");
        bgColor = [UIColor systemBlueColor];
        button.enabled = YES;
    }

    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.backgroundColor = bgColor;

    return button;
}

#pragma mark - UITextFieldDelegate

/// 点击 Return 键时收起键盘
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == self.directIPField) {
        // 在 IP 输入框按 Return 切换到端口输入框
        [self.directPortField becomeFirstResponder];
    } else {
        [textField resignFirstResponder];
    }
    return YES;
}

#pragma mark - UITableViewDataSource

/// Section 数量：根据模式返回
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if (self.mode == MultiplayerVCModeInGame) {
        // 游戏内模式：选择角色 + 联机状态
        return 2;
    }
    // 启动器模式：联机设置 + 我的房间 + 直连
    return 3;
}

/// 每个 Section 的行数：根据模式和 Section 返回
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.mode == MultiplayerVCModeInGame) {
        switch (section) {
            case 0:
                // 选择角色：当房主 + 当房客
                return 2;
            case 1:
                // 联机状态：1 行综合状态
                return 1;
            default:
                return 0;
        }
    }
    // 启动器模式
    switch (section) {
        case 0:
            // 联机设置：启用联机开关 + Network ID + ZeroTier 创建教程
            return 3;
        case 1:
            // 我的房间：至少 1 行（空状态提示）
            return MAX(1, (NSInteger)self.rooms.count);
        case 2:
            // 直连：IP+端口输入 + 加入游戏按钮
            return 2;
        default:
            return 0;
    }
}

/// Section 标题：根据模式返回
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.mode == MultiplayerVCModeInGame) {
        switch (section) {
            case 0:
                return MPLocalized(@"mp.ingame.section.role", @"Choose role");
            case 1:
                return MPLocalized(@"mp.ingame.section.status", @"Multiplayer status");
            default:
                return nil;
        }
    }
    switch (section) {
        case 0:
            return MPLocalized(@"mp.section.settings", @"Multiplayer settings");
        case 1:
            return MPLocalized(@"mp.section.rooms", @"My rooms");
        case 2:
            return MPLocalized(@"mp.section.direct", @"Direct connect");
        default:
            return nil;
    }
}

/// Section 脚注：根据模式返回
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.mode == MultiplayerVCModeInGame) {
        switch (section) {
            case 0:
                return MPLocalized(@"mp.ingame.section.role_footer", @"Host opens to LAN in Minecraft; guests join with the share code");
            case 1:
                return MPLocalized(@"mp.ingame.section.status_footer", @"Show current multiplayer network status");
            default:
                return nil;
        }
    }
    switch (section) {
        case 0:
            return MPLocalized(@"mp.section.settings_footer", @"After enabling multiplayer you can set a Network ID, used automatically when hosting");
        case 2:
            return MPLocalized(@"mp.section.direct_footer", @"Enter server IP and port, save to the current profile, and auto-join on launch");
        default:
            return nil;
    }
}

/// 根据 IndexPath 配置对应的 cell
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.mode == MultiplayerVCModeInGame) {
        return [self cellForInGameSection:indexPath];
    }
    return [self cellForLauncherSection:indexPath];
}

#pragma mark - 启动器模式 Cell 配置

/// 启动器模式 cell 配置分发
- (UITableViewCell *)cellForLauncherSection:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case 0:
            return [self cellForSettingsSectionAtRow:indexPath.row];
        case 1:
            return [self cellForRoomsSectionAtRow:indexPath.row];
        case 2:
            return [self cellForDirectSectionAtRow:indexPath.row];
        default:
            return [UITableViewCell new];
    }
}

/// Section 0「联机设置」的 cell 配置
/// @param row 行号（0=启用联机开关，1=预设 Network ID，2=ZeroTier 创建教程）
- (UITableViewCell *)cellForSettingsSectionAtRow:(NSInteger)row {
    if (row == 2) {
        // ZeroTier 网络创建教程入口
        return [self cellForGuideSection];
    }
    if (row == 0) {
        // 启用联机开关行
        UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"SwitchCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = MPLocalized(@"mp.settings.enable_multiplayer", @"Enable multiplayer");
        cell.textLabel.font = [UIFont systemFontOfSize:16];

        // 懒初始化 UISwitch
        if (!self.enableSwitch) {
            self.enableSwitch = [[UISwitch alloc] init];
            [self.enableSwitch addTarget:self action:@selector(enableSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        }
        // 初始状态：根据持久化的用户意图设置开关（与 viewWillAppear: 保持一致）
        BOOL enabled = [[MultiplayerManager sharedManager] isMultiplayerEnabled];
        [self.enableSwitch setOn:enabled animated:NO];
        cell.accessoryView = self.enableSwitch;

        // 辅助文字：显示节点的实际运行状态（而非用户意图）
        BOOL started = [[MultiplayerManager sharedManager] isNodeStarted];
        if (started) {
            if ([[MultiplayerManager sharedManager] isNodeOnline]) {
                cell.detailTextLabel.text = MPLocalized(@"mp.settings.node_online", @"Node online");
            } else {
                cell.detailTextLabel.text = MPLocalized(@"mp.settings.node_starting", @"Starting node…");
            }
        } else {
            // 节点未启动：如果用户已启用（等待自动重启），显示"启动中"
            if (enabled) {
                cell.detailTextLabel.text = MPLocalized(@"mp.settings.node_starting", @"Starting node…");
            } else {
                cell.detailTextLabel.text = MPLocalized(@"mp.settings.node_offline", @"Node not started");
            }
        }
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];

        // 适配自定义背景
        if ([[BackgroundManager sharedManager] hasBackground]) {
            cell.textLabel.textColor = [UIColor whiteColor];
            cell.detailTextLabel.textColor = [UIColor whiteColor];
        } else {
            cell.textLabel.textColor = [UIColor labelColor];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        }

        [[BackgroundManager sharedManager] applyEffectToCell:cell];
        return cell;
    } else {
        // 预设 Network ID 行
        UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"NetworkIdCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.textLabel.text = MPLocalized(@"mp.settings.preset_network_id", @"Preset Network ID");
        cell.textLabel.font = [UIFont systemFontOfSize:16];

        // 显示当前预设的 Network ID（脱敏显示：前 4 + ... + 后 4）
        NSString *presetNetId = [[MultiplayerManager sharedManager] presetNetworkId];
        NSString *displayValue;
        if (presetNetId.length >= 16) {
            displayValue = [NSString stringWithFormat:@"%@...%@",
                            [presetNetId substringToIndex:4],
                            [presetNetId substringFromIndex:presetNetId.length - 4]];
        } else if (presetNetId.length > 0) {
            displayValue = presetNetId;
        } else {
            displayValue = MPLocalized(@"mp.settings.not_set", @"Not set");
        }

        // 使用 detailTextLabel 显示值
        cell.detailTextLabel.text = displayValue;
        cell.detailTextLabel.font = [UIFont systemFontOfSize:14];
        cell.detailTextLabel.numberOfLines = 1;
        cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
        cell.detailTextLabel.minimumScaleFactor = 0.7;

        // 右侧显示编辑图标
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

        // 适配自定义背景
        if ([[BackgroundManager sharedManager] hasBackground]) {
            cell.textLabel.textColor = [UIColor whiteColor];
            cell.detailTextLabel.textColor = [UIColor whiteColor];
        } else {
            cell.textLabel.textColor = [UIColor labelColor];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        }

        [[BackgroundManager sharedManager] applyEffectToCell:cell];
        return cell;
    }
}

/// Section 0「联机设置」的教程入口 cell（row == 2）
///
/// 对标 FCL 的"联机帮助"入口：引导房主完成 ZeroTier 网络的创建和配置。
/// 点击后弹出详细的图文教程，包含注册账号、创建网络、获取 Network ID、
/// 设置网络可见性等步骤，并提供"打开 central.zerotier.com"快捷按钮。
- (UITableViewCell *)cellForGuideSection {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"DefaultCell"];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.text = MPLocalized(@"mp.settings.zt_guide", @"ZeroTier network setup guide");
    cell.textLabel.font = [UIFont systemFontOfSize:16];

    // 左侧图标：问号圆圈
    cell.imageView.image = [UIImage systemImageNamed:@"questionmark.circle"];
    cell.imageView.tintColor = [UIColor systemBlueColor];

    // 右侧箭头
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    // 辅助文字：简短说明
    cell.detailTextLabel.text = MPLocalized(@"mp.settings.zt_guide_desc", @"Not sure how to create a network? Tap here");
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];

    // 适配自定义背景
    if ([[BackgroundManager sharedManager] hasBackground]) {
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.detailTextLabel.textColor = [UIColor whiteColor];
    } else {
        cell.textLabel.textColor = [UIColor labelColor];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }

    [[BackgroundManager sharedManager] applyEffectToCell:cell];
    return cell;
}

/// Section 1「我的房间」的 cell 配置
/// @param row 行号
- (UITableViewCell *)cellForRoomsSectionAtRow:(NSInteger)row {
    // 空状态：显示提示文字
    if (self.rooms.count == 0) {
        UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"EmptyCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = MPLocalized(@"mp.rooms.empty", @"No rooms (rooms are kept for this session only)");
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [UIFont systemFontOfSize:14];
        // 适配自定义背景
        if ([[BackgroundManager sharedManager] hasBackground]) {
            cell.textLabel.textColor = [UIColor whiteColor];
        } else {
            cell.textLabel.textColor = [UIColor secondaryLabelColor];
        }
        [[BackgroundManager sharedManager] applyEffectToCell:cell];
        return cell;
    }

    // 有房间：使用 subtitle 风格的标准 UITableViewCell
    MultiplayerRoom *room = self.rooms[row];
    // 不注册 RoomCell，使用 dequeueReusableCellWithIdentifier: 手工创建 subtitle 风格的 cell
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"RoomCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"RoomCell"];
    }
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    // 房间名
    cell.textLabel.text = room.name.length ? room.name : MPLocalized(@"mp.room.unnamed", @"Unnamed room");
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];

    // 详情：Network ID + 状态 + 服务器地址（已连接时显示完整地址方便分享）
    NSString *statusText = [self textForRoomStatus:room.status];
    NSMutableString *detail = [NSMutableString string];
    [detail appendFormat:@"%@: %@",
        MPLocalized(@"mp.room.network_id", @"Network ID"),
        room.networkId ?: @"-"];
    [detail appendFormat:@"\n%@", statusText];
    // ★ [MP-ROLE] 角色标识：这个房间是我当房主还是房客（MultiplayerRoom.role 已有，不新造状态）
    NSString *roomRoleTag = nil;
    if (room.role == MultiplayerRoomRoleHost) {
        roomRoleTag = [NSString stringWithFormat:@"%@ · %@",
                       MPLocalized(@"i18n_str_2068", @"Me"), MPLocalized(@"i18n_str_1027", @"Host")];
    } else if (room.role == MultiplayerRoomRoleGuest) {
        roomRoleTag = [NSString stringWithFormat:@"%@ · %@",
                       MPLocalized(@"i18n_str_2068", @"Me"), MPLocalized(@"i18n_str_2069", @"Guest")];
    }
    if (roomRoleTag.length > 0) {
        [detail appendFormat:@"\n%@", roomRoleTag];
        NSLog(@"[MP-ROLE] view=rooms room=%@ role=%@", room.name ?: @"(unnamed)", roomRoleTag);
    }
    if (room.status == MultiplayerRoomStatusConnected) {
        // 已连接时显示完整服务器地址
        NSString *hostIP = room.hostIP.length ? room.hostIP : [[MultiplayerManager sharedManager] currentLocalIP];
        NSString *hostPort = room.hostPort.length ? room.hostPort : @"25565";
        if (hostIP.length) {
            [detail appendFormat:@"\n%@: %@:%@",
                MPLocalized(@"mp.room.server_address", @"Server address"),
                hostIP, hostPort];
        }
    }
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.detailTextLabel.numberOfLines = 0;

    // 状态指示点（imageView 显示彩色小圆点）
    UIColor *statusColor = [self colorForRoomStatus:room.status];
    UIImage *dotImage = [self circleImageWithColor:statusColor size:10];
    cell.imageView.image = dotImage;

    // 连接 / 断开按钮（accessoryView）
    UIButton *actionButton = [self makeActionButtonForRoom:room];
    [actionButton addTarget:self action:@selector(roomButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    actionButton.tag = row;
    cell.accessoryView = actionButton;

    // 适配自定义背景
    if ([[BackgroundManager sharedManager] hasBackground]) {
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.detailTextLabel.textColor = [UIColor whiteColor];
    } else {
        cell.textLabel.textColor = [UIColor labelColor];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }

    [[BackgroundManager sharedManager] applyEffectToCell:cell];
    return cell;
}

/// Section 2「直连」的 cell 配置
/// @param row 行号（0=IP+端口输入，1=加入游戏按钮）
- (UITableViewCell *)cellForDirectSectionAtRow:(NSInteger)row {
    if (row == 0) {
        // IP + 端口输入行
        UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"DirectInputCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        // 懒初始化 IP 输入框
        if (!self.directIPField) {
            self.directIPField = [[UITextField alloc] init];
            self.directIPField.placeholder = MPLocalized(@"mp.direct.ip_placeholder", @"Server IP");
            self.directIPField.font = [UIFont systemFontOfSize:15];
            self.directIPField.autocapitalizationType = UITextAutocapitalizationTypeNone;
            self.directIPField.autocorrectionType = UITextAutocorrectionTypeNo;
            self.directIPField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
            self.directIPField.clearButtonMode = UITextFieldViewModeWhileEditing;
            self.directIPField.returnKeyType = UIReturnKeyNext;
            self.directIPField.delegate = self;
            self.directIPField.translatesAutoresizingMaskIntoConstraints = NO;
        }

        // 懒初始化端口输入框
        if (!self.directPortField) {
            self.directPortField = [[UITextField alloc] init];
            self.directPortField.placeholder = @"25565";
            self.directPortField.font = [UIFont systemFontOfSize:15];
            self.directPortField.autocapitalizationType = UITextAutocapitalizationTypeNone;
            self.directPortField.autocorrectionType = UITextAutocorrectionTypeNo;
            self.directPortField.keyboardType = UIKeyboardTypeNumberPad;
            self.directPortField.clearButtonMode = UITextFieldViewModeWhileEditing;
            self.directPortField.returnKeyType = UIReturnKeyDone;
            self.directPortField.delegate = self;
            self.directPortField.translatesAutoresizingMaskIntoConstraints = NO;
        }

        // 懒初始化冒号分隔标签
        UILabel *colonLabel = (UILabel *)[cell.contentView viewWithTag:9528];
        if (!colonLabel) {
            colonLabel = [[UILabel alloc] init];
            colonLabel.tag = 9528;
            colonLabel.text = @":";
            colonLabel.font = [UIFont systemFontOfSize:15];
            colonLabel.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:colonLabel];
        }

        // 如果 textField 已在别的 cell 上（cell 复用场景），先移除
        if (self.directIPField.superview && self.directIPField.superview != cell.contentView) {
            [self.directIPField removeFromSuperview];
        }
        if (self.directPortField.superview && self.directPortField.superview != cell.contentView) {
            [self.directPortField removeFromSuperview];
        }

        BOOL needsNewConstraints = NO;
        if (!self.directIPField.superview) {
            [cell.contentView addSubview:self.directIPField];
            needsNewConstraints = YES;
        }
        if (!self.directPortField.superview) {
            [cell.contentView addSubview:self.directPortField];
            needsNewConstraints = YES;
        }

        // 仅在 textField 首次添加到 cell 时设置约束（避免重复激活导致冲突）
        if (needsNewConstraints) {
            [NSLayoutConstraint activateConstraints:@[
                [self.directIPField.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
                [self.directIPField.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:12],
                [self.directIPField.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-12],
                [self.directIPField.trailingAnchor constraintEqualToAnchor:colonLabel.leadingAnchor constant:-4],

                [colonLabel.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
                [colonLabel.widthAnchor constraintEqualToConstant:8],

                [self.directPortField.leadingAnchor constraintEqualToAnchor:colonLabel.trailingAnchor constant:4],
                [self.directPortField.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
                [self.directPortField.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
                [self.directPortField.widthAnchor constraintEqualToConstant:80],
            ]];
        }

        // 适配自定义背景
        BOOL hasBackground = [[BackgroundManager sharedManager] hasBackground];
        if (hasBackground) {
            self.directIPField.textColor = [UIColor whiteColor];
            self.directPortField.textColor = [UIColor whiteColor];
            colonLabel.textColor = [UIColor whiteColor];
        } else {
            self.directIPField.textColor = [UIColor labelColor];
            self.directPortField.textColor = [UIColor labelColor];
            colonLabel.textColor = [UIColor labelColor];
        }

        [[BackgroundManager sharedManager] applyEffectToCell:cell];
        return cell;
    } else {
        // 加入游戏按钮行
        UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"ButtonCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = MPLocalized(@"mp.direct.join_button", @"Join game");
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        // 适配自定义背景
        if ([[BackgroundManager sharedManager] hasBackground]) {
            cell.textLabel.textColor = [UIColor whiteColor];
        } else {
            cell.textLabel.textColor = [UIColor systemBlueColor];
        }
        [[BackgroundManager sharedManager] applyEffectToCell:cell];
        return cell;
    }
}

#pragma mark - 游戏内模式 Cell 配置

/// 游戏内模式 cell 配置分发
- (UITableViewCell *)cellForInGameSection:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case 0:
            return [self cellForRoleSectionAtRow:indexPath.row];
        case 1:
            return [self cellForInGameStatusSection];
        default:
            return [UITableViewCell new];
    }
}

/// Section 0「选择角色」的 cell 配置
/// @param row 行号（0=当房主，1=当房客）
- (UITableViewCell *)cellForRoleSectionAtRow:(NSInteger)row {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"RoleCardCell"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    // 自定义卡片式布局：左侧大图标 + 右侧标题和说明
    if (row == 0) {
        // 当房主
        cell.imageView.image = [UIImage systemImageNamed:@"crown"];
        cell.imageView.tintColor = [UIColor systemOrangeColor];
        cell.textLabel.text = MPLocalized(@"mp.ingame.host_title", @"Host");
        cell.textLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
        cell.detailTextLabel.text = MPLocalized(@"mp.ingame.host_desc", @"Create a multiplayer room, open to LAN, then generate a share code");
        cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
        cell.detailTextLabel.numberOfLines = 0;

        // 房主流程激活时显示状态指示
        if (self.isHostFlowActive) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
        } else {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else {
        // 当房客
        cell.imageView.image = [UIImage systemImageNamed:@"person.2"];
        cell.imageView.tintColor = [UIColor systemBlueColor];
        cell.textLabel.text = MPLocalized(@"mp.ingame.guest_title", @"Join as guest");
        cell.textLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
        cell.detailTextLabel.text = MPLocalized(@"mp.ingame.guest_desc", @"Enter the share code to join the host network");
        cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
        cell.detailTextLabel.numberOfLines = 0;

        // 房客流程激活时显示状态指示
        if (self.isGuestFlowActive) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
        } else {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    }

    // 适配自定义背景
    if ([[BackgroundManager sharedManager] hasBackground]) {
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.detailTextLabel.textColor = [UIColor whiteColor];
    } else {
        cell.textLabel.textColor = [UIColor labelColor];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }

    [[BackgroundManager sharedManager] applyEffectToCell:cell];
    return cell;
}

/// Section 1「联机状态」的 cell 配置
///
/// 综合显示：
///   - 当前联机状态（已连接/未连接）
///   - Network ID
///   - 本地 IP
///   - 房主流程：分享代码
///   - 房客流程：服务器地址
- (UITableViewCell *)cellForInGameStatusSection {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"StatusCell"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    MultiplayerManager *manager = [MultiplayerManager sharedManager];
    MultiplayerRoom *currentRoom = manager.currentRoom;
    BOOL connected = (currentRoom != nil) && (currentRoom.status == MultiplayerRoomStatusConnected);

    // 标题：联机状态
    cell.textLabel.text = connected ? MPLocalized(@"mp.ingame.status.connected", @"Connected") : MPLocalized(@"mp.ingame.status.disconnected", @"Disconnected");
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];

    // 详情：Network ID + 本地 IP + （房主）分享代码 / （房客）服务器地址
    NSMutableString *detail = [NSMutableString string];

    // 状态指示
    if (self.isHostFlowActive) {
        [detail appendString:MPLocalized(@"mp.ingame.status.host_mode", @"Host mode")];
    } else if (self.isGuestFlowActive) {
        [detail appendString:MPLocalized(@"mp.ingame.status.guest_mode", @"Guest mode")];
    } else {
        [detail appendString:MPLocalized(@"mp.ingame.status.idle", @"Not started")];
    }

    // Network ID
    NSString *networkId = currentRoom.networkId.length ? currentRoom.networkId : [manager presetNetworkId];
    if (networkId.length) {
        [detail appendFormat:@"\n%@: %@", MPLocalized(@"mp.ingame.status.network_id", @"Network ID"), networkId];
    } else {
        [detail appendFormat:@"\n%@: %@", MPLocalized(@"mp.ingame.status.network_id", @"Network ID"), MPLocalized(@"mp.settings.not_set", @"Not set")];
    }

    // 本地 IP
    NSString *localIP = manager.currentLocalIP;
    if (localIP.length) {
        [detail appendFormat:@"\n%@: %@", MPLocalized(@"mp.ingame.status.local_ip", @"Local IP"), localIP];
    }

    // 房主流程：显示分享代码
    if (self.isHostFlowActive && self.lastShareCode.length) {
        [detail appendFormat:@"\n%@: %@",
            MPLocalized(@"mp.ingame.status.share_code", @"Share code"),
            self.lastShareCode];
    }

    // 房客流程：显示服务器地址
    if (self.isGuestFlowActive && self.lastServerAddress.length) {
        [detail appendFormat:@"\n%@: %@",
            MPLocalized(@"mp.ingame.status.server_address", @"Server address"),
            self.lastServerAddress];
    }

    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
    cell.detailTextLabel.numberOfLines = 0;

    // 状态指示点
    UIColor *statusColor = connected ? [UIColor systemGreenColor] : [UIColor systemGrayColor];
    UIImage *dotImage = [self circleImageWithColor:statusColor size:10];
    cell.imageView.image = dotImage;

    // 适配自定义背景
    if ([[BackgroundManager sharedManager] hasBackground]) {
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.detailTextLabel.textColor = [UIColor whiteColor];
    } else {
        cell.textLabel.textColor = [UIColor labelColor];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }

    [[BackgroundManager sharedManager] applyEffectToCell:cell];
    return cell;
}

#pragma mark - UITableViewDelegate

/// 点击行回调：根据模式和 Section 分发
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (self.mode == MultiplayerVCModeInGame) {
        [self handleInGameSelectionAtIndexPath:indexPath];
        return;
    }
    [self handleLauncherSelectionAtIndexPath:indexPath];
}

/// 启动器模式点击处理
- (void)handleLauncherSelectionAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case 0:
            if (indexPath.row == 0) {
                // 点击开关行：让开关获得焦点（切换开关状态）
                // 不做处理，开关自身会响应
            } else if (indexPath.row == 1) {
                // 点击 Network ID 行：弹出编辑对话框
                [self networkIdCellTapped];
            } else if (indexPath.row == 2) {
                // 点击教程入口：弹出 ZeroTier 网络创建教程
                [self showZeroTierGuide];
            }
            break;
        case 1:
            if (self.rooms.count == 0) {
                // 空状态：提示用户先设置 Network ID 或直接加入房间
                [self showSimpleAlertWithTitle:MPLocalized(@"mp.rooms.empty_title", @"No rooms")
                                         message:MPLocalized(@"mp.rooms.empty_msg", @"Set a Network ID in Section 0 first, then choose Host or Guest in-game")];
            } else {
                // 点击房间行：弹出 ActionSheet
                MultiplayerRoom *room = self.rooms[indexPath.row];
                [self showRoomActionsForRoom:room];
            }
            break;
        case 2:
            if (indexPath.row == 0) {
                // 点击直连输入行：让 IP 输入框获得焦点
                [self.directIPField becomeFirstResponder];
            } else if (indexPath.row == 1) {
                // 点击加入游戏按钮
                [self joinDirectConnect];
            }
            break;
        default:
            break;
    }
}

/// 游戏内模式点击处理
- (void)handleInGameSelectionAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case 0:
            if (indexPath.row == 0) {
                // 当房主
                [self hostButtonTapped];
            } else if (indexPath.row == 1) {
                // 当房客
                [self guestButtonTapped];
            }
            break;
        case 1:
            // 联机状态行：无操作（仅显示信息）
            // 房主流程激活时点击可重新显示分享代码
            if (self.isHostFlowActive && self.lastShareCode.length) {
                [self showHostShareCodeAlert];
            }
            break;
        default:
            break;
    }
}

/// 行高：根据模式和 IndexPath 返回
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.mode == MultiplayerVCModeInGame) {
        if (indexPath.section == 0) {
            // 选择角色卡片行：大卡片样式，更高
            return 76;
        }
        if (indexPath.section == 1) {
            // 联机状态行：动态高度（多行详情）
            return UITableViewAutomaticDimension;
        }
        return 56;
    }
    // 启动器模式
    if (indexPath.section == 0) {
        // 联机设置行
        return 56;
    }
    if (indexPath.section == 1) {
        if (self.rooms.count == 0) {
            // 空状态提示行
            return 60;
        }
        // 房间行：subtitle 显示 2-3 行，需要更多空间
        return 76;
    }
    if (indexPath.section == 2) {
        // IP+端口输入行 / 加入按钮行
        return 48;
    }
    return UITableViewAutomaticDimension;
}

@end
