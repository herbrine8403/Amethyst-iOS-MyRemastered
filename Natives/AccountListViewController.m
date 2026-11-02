#import <AuthenticationServices/AuthenticationServices.h>

#import "authenticator/BaseAuthenticator.h"
#import "authenticator/ThirdPartyAuthenticator.h"
#import "AccountListViewController.h"
#import "AccountLoginViewController.h"
#import "ThirdPartyLoginViewController.h"
#import "AFNetworking.h"
#import "LauncherPreferences.h"
#import "UIImageView+AFNetworking.h"
#import "BackgroundManager.h"
// ★ [ACCT-AUDIT] 删除账户时清理其自定义头像文件（Documents/avatars/<accountId>.png）。
#import "AvatarManager.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
// ★ [EDIT3] 头像设置入口:复用既有通知动作(LauncherRightPanelViewController norightPostAction:)。
#import "LauncherRightPanelViewController.h"

@interface AccountListViewController()<ASWebAuthenticationPresentationContextProviding>

@property(nonatomic, strong) NSMutableArray *accountList;
@property(nonatomic) ASWebAuthenticationSession *authVC;
// ★ [ADDBTN-INSET] 底部「添加账户」按钮的底边约束:单独持有,交由布局期按【实际遮挡量】调整。
@property(nonatomic, strong) NSLayoutConstraint *ameAddAccountBottomConstraint;
// ★ [ACCT-DUP] 登录/选号重入守卫：同一时刻只允许一条登录流程在飞。
@property(nonatomic) BOOL ameLoginInFlight;
// ★ [ACCT-DUP] 登录「代数」:每次发起登录自增;回调携带旧代数时被判定过期并丢弃,
//   防止上一次登录的迟到回调改动本次 UI(回调侧防重的 generation 计数)。
@property(nonatomic) NSUInteger ameAuthGeneration;
// ★ [ACCT-DUP] 「添加账户」入口重入守卫:防连点 push 出两个登录方式页。
@property(nonatomic) BOOL ameAddAccountInFlight;
// ★ [ACCT-DONE] 在飞锁「代次」:每次置位/解锁自增;看门狗延时块只在代次未变且仍在飞时解锁,
//   避免把后来的一次新登录误解锁。
@property(nonatomic) NSUInteger ameLoginInFlightToken;

@end

@implementation AccountListViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // 适配自定义启动器背景：将当前视图控制器透明化，使全局背景壁纸能够透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    self.title = localize(@"login.title", @"Accounts");
    self.view.backgroundColor = [UIColor clearColor];

    if (self.accountList == nil) {
        self.accountList = [NSMutableArray array];
    } else {
        [self.accountList removeAllObjects];
    }

    // List accounts（★ [ACCT-DUP] 载入前先合并存量重复，再过滤损坏文件）
    [self ameLoadAccountListFromDisk];

    // 参照 FCL：卡片式账户列表，去除默认分割线，圆角卡片自带视觉分隔
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.estimatedRowHeight = 88;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    // 底部内边距避免最后一个 cell 被浮动按钮遮挡
    self.tableView.contentInset = UIEdgeInsetsMake(8, 0, 80, 0);
    self.tableView.scrollIndicatorInsets = self.tableView.contentInset;
    // 注册卡片 cell
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"accountCardCell"];

    // 添加底部"添加账户"浮动按钮（FCL 风格）
    [self setupAddAccountButton];

    // 应用背景
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];

    // 监听背景 UI 效果变化通知，当用户切换背景效果（半透明/毛玻璃）时重新应用透明化
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

/// 背景效果改变时重新应用透明化（由 BackgroundUIEffectChanged 通知触发）
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - ★ [ACCOUNTBACK] 返回键(账户链路“进得去出不来”修复)

/// ★ [ACCOUNTBACK] 每次出现时保证本页有一个**可用的返回出口**。
///
/// 根因(实查,见 _EDITMODE_REPORT.md ①):
///   showAccountManager(LauncherRootViewController.m:848 / LauncherCardLayoutViewController.m:989)
///   把本页作为**一个全新 UINavigationController 的根**(initWithRootViewController:)塞进中间内容区。
///   根视图控制器没有可 pop 的上级 ⇒ UIKit 不会给返回键,导航栏虽然可见却是一个空壳
///   ⇒ 用户从主页进得来、出不去。
///
/// 修法(不改任何账户业务逻辑,只补出口):
///   ① 确认本页确实是“导航栈根、没有系统返回键”时,注入一枚「返回」左键;
///      点击只发既有通知 ShowHomePage —— RootVC(:602) / CardLayoutVC(:752) 都已监听
///      并切回主页,故不依赖具体宿主类,也不用复制任何导航代码。
///   ② 顺带把承载本页的那个 nav 的导航栏显示出来(navigationBarHidden = NO)。
///      ★ 这里**故意不做 viewWillDisappear 还原**:该 nav 是 showAccountManager 为账户链路
///        临时新建、且只服务这一条链路的私有容器;若在 disappear 时还原成 hidden,
///        紧接着 push 上来的登录页(AccountLoginViewController)就会丢掉系统返回键 ——
///        那正是本任务要修的毛病。作用域仅限这条私有 nav,不会影响别的页面。
///   ③ 触发时机放在 viewWillAppear:此时 navigationController 关系已经建立。
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // ★ [ACCT-DUP] 从登录方式页 pop 回来时解除「添加账户」重入锁（入口在 push 前置位）。
    self.ameAddAccountInFlight = NO;
    // ★ [ACCT-DONE] 每次出现都无条件把【登录在飞锁】归零:即便上一轮因回调丢失/网络 hang
    //   把锁留在置位态(表禁用、按钮禁用),回到本页也一定可交互。幂等:在飞期间本页本就可见,
    //   viewWillAppear 不会重复触发,故不会打断真正进行中的登录。
    [self ameSetLoginInFlight:NO];
    [self ameAccountEnsureBackItemIfNeeded];
}

#pragma mark - ★ [ADDBTN-INSET] 底部「添加账户」按钮避开底栏

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self ame_updateAddAccountButtonInset];
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self ame_updateAddAccountButtonInset];
}

/// 把按钮顶到底栏之上:inset = max(自身 safeArea 底, 底栏与本页底部的【实际重叠】高度)。
///   这样在"有/无底栏、底栏显示/隐藏、横竖屏、底栏半透明与否"下都成立;
///   找不到底栏时退化为 safeAreaInsets.bottom(与系统一致)。
- (void)ame_updateAddAccountButtonInset {
    if (!self.ameAddAccountBottomConstraint) { return; }

    CGFloat inset = self.view.safeAreaInsets.bottom;

    UITabBarController *tbc = self.tabBarController;
    if (!tbc) {
        // 本页挂在主页的「内容容器」里,不一定是 tabBarController 的直接子 VC ⇒ 再往上找一层
        UIViewController *root = self.view.window.rootViewController;
        if ([root isKindOfClass:[UITabBarController class]]) {
            tbc = (UITabBarController *)root;
        }
    }
    UIView *bar = tbc.tabBar;
    if (tbc && bar && !bar.hidden && bar.window) {
        CGRect barRect = [self.view convertRect:bar.bounds fromView:bar];
        CGFloat overlap = CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(barRect);
        // 只在"确实被压住"且量值合理时采纳(防异常值)
        if (overlap > 0 && overlap < CGRectGetHeight(self.view.bounds) * 0.5) {
            inset = MAX(inset, overlap);
        }
    }
    self.ameAddAccountBottomConstraint.constant = -(inset + 16.0);
}

/// ★ [ACCOUNTBACK] 见 viewWillAppear 注释。
- (void)ameAccountEnsureBackItemIfNeeded {
    UINavigationController *nav = self.navigationController;
    if (!nav) return;                                       // 不在导航栈(无宿主 nav)⇒ 无从注入

    // ① 显示导航栏:根页没有可 pop 的对象时,系统不会画返回键,空导航栏等于没有出口。
    if (nav.navigationBarHidden) {
        [nav setNavigationBarHidden:NO animated:NO];
    }
    // 语义色:随浅色/深色外观自适应(与主页顶栏同一套语义色),不写死黑白。
    nav.navigationBar.tintColor = [UIColor labelColor];
    // ★ [ACCT-DONE] 导航栏出口永不失效:每次出现都把导航栏与已注入的左键拉回可交互态。
    //   账户链路的「完成/返回」是唯一出口,绝不能因为一次在飞锁/转圈把导航 chrome 一起关掉
    //   (用户实测:「完成」点不动 ⇒ 进得去出不来)。业务锁只该锁"会触发登录的控件"。
    nav.navigationBar.userInteractionEnabled = YES;
    if (self.navigationItem.leftBarButtonItem) self.navigationItem.leftBarButtonItem.enabled = YES;

    // ★ [EDIT3] 自定义头像菜单的**新入口**:本页 = 点头像进入的「账户管理」页。
    //   原来“长按主页欢迎卡头像”才能弹出的自定义头像菜单(导入 / 清除),其长按触发器已让位给
    //   “长按进编辑模式”(见 LauncherNewsViewController.m ★[EDIT3]);为不丢功能,在此给一颗
    //   明确可见的右键「自定义头像」:点击**只** post 既有动作名 avatarMenu ⇒ 仍由
    //   LauncherRightPanelViewController 的 showAvatarMenu: 原实现弹出,菜单项/回调/账户校验/
    //   裁剪保存链路一律不动;本页不复制任何头像逻辑。
    //   幂等:已注入过就不再注入。按钮挂在本 VC 的 navigationItem 上 ⇒ 只有本页可见,
    //   push 出去的登录页用的是它自己的 navigationItem,不受影响。
    if (!self.navigationItem.rightBarButtonItem) {
        UIBarButtonItem *avatarItem = [[UIBarButtonItem alloc] initWithTitle:localize(@"i18n_str_416", @"Custom Avatar")
                                                                      style:UIBarButtonItemStylePlain
                                                                     target:self
                                                                     action:@selector(ameAccountAvatarSettingsTapped)];
        avatarItem.tintColor = [UIColor labelColor];
        avatarItem.accessibilityLabel = localize(@"i18n_str_416", @"Custom Avatar");
        self.navigationItem.rightBarButtonItem = avatarItem;
    }

    // ② 只在“栈里没有再上一级(没有系统返回键)”时注入;已被 push 的页面保留系统返回键原样。
    if (nav.viewControllers.count > 1) return;
    if (self.navigationItem.leftBarButtonItem) return;      // 幂等:已注入过就不再注入

    UIBarButtonItem *backItem = [[UIBarButtonItem alloc] initWithTitle:localize(@"resman.common.done", nil)
                                                                style:UIBarButtonItemStylePlain
                                                               target:self
                                                               action:@selector(ameAccountBackToHomeTapped)];
    backItem.tintColor = [UIColor labelColor];
    backItem.accessibilityLabel = localize(@"resman.common.done", nil);
    self.navigationItem.leftBarButtonItem = backItem;

    // ③ 横屏时灵动岛在侧边(≈59pt):左键由系统导航栏摆放在 safeAreaLayoutGuide 内,天然不会被岛压住。
}

/// ★ [ACCOUNTBACK] 「返回」= 回主页。只发既有通知,不动任何账户业务(登录/登出/头像/用户名)。
- (void)ameAccountBackToHomeTapped {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowHomePage" object:nil];
}

/// ★ [EDIT3] 「自定义头像」= 弹自定义头像菜单(导入 / 清除)。
///   只转发到既有动作名 avatarMenu ⇒ LauncherRightPanelViewController 的 showAvatarMenu: 原实现,
///   菜单选项、回调、账户校验、裁剪/保存链路一律不变;本页不复制任何头像逻辑。
- (void)ameAccountAvatarSettingsTapped {
    [LauncherRightPanelViewController norightPostAction:@"avatarMenu"];
}

- (void)setupAddAccountButton {
    UIButton *addBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    addBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [addBtn setTitle:localize(@"login.option.add", @"Add account") forState:UIControlStateNormal];
    addBtn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [addBtn setImage:[UIImage systemImageNamed:@"plus"] forState:UIControlStateNormal];
    addBtn.tintColor = [UIColor whiteColor];
    addBtn.backgroundColor = accentColor();
    addBtn.layer.cornerRadius = 24;
    addBtn.layer.cornerCurve = kCACornerCurveContinuous;
    addBtn.titleEdgeInsets = UIEdgeInsetsMake(0, 6, 0, 0);
    addBtn.imageEdgeInsets = UIEdgeInsetsMake(0, -6, 0, 0);
    // 投影增强浮动感（FCL 风格）
    addBtn.layer.shadowColor = [UIColor blackColor].CGColor;
    addBtn.layer.shadowOpacity = 0.35;
    addBtn.layer.shadowOffset = CGSizeMake(0, 4);
    addBtn.layer.shadowRadius = 10;
    [addBtn addTarget:self action:@selector(addAccountTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:addBtn];
    // 使用 frameLayoutGuide（UITableView 的可见区域锚点）而非 safeAreaLayoutGuide，
    // 确保按钮随可见区域底部浮动，不会跟随 cell 滚动
    // ★ [ADDBTN-INSET] 底边约束【单独持有】:底栏(UITabBarController 的 tabBar)是半透明悬浮的,
    //   本页内容区延伸到底栏之下 ⇒ 写死 -16 会让按钮被底栏压住(用户实测:新旧系统都被挡)。
    //   改为交给 ame_updateAddAccountButtonInset 按实际遮挡量设置 constant。
    self.ameAddAccountBottomConstraint =
        [addBtn.bottomAnchor constraintEqualToAnchor:self.tableView.frameLayoutGuide.bottomAnchor constant:-16];
    [NSLayoutConstraint activateConstraints:@[
        self.ameAddAccountBottomConstraint,
        [addBtn.centerXAnchor constraintEqualToAnchor:self.tableView.frameLayoutGuide.centerXAnchor],
        [addBtn.heightAnchor constraintEqualToConstant:48],
        [addBtn.widthAnchor constraintGreaterThanOrEqualToConstant:160]
    ]];
    self.addAccountButton = addBtn;
    [self ame_updateAddAccountButtonInset];
}

- (void)addAccountTapped {
    [self actionAddAccount:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    // FCL 风格：列表只显示已有账户，添加账户改由底部浮动按钮触发
    return self.accountList.count;
}

/// 计算账户类型标签文字与配色（参照 FCL：微软=蓝、第三方=橙、本地=灰、Demo=紫）
- (void)applyAccountTypeBadgeForAccount:(NSDictionary *)accountData
                              badgeLabel:(UILabel *)badgeLabel {
    NSString *username = accountData[@"username"];
    if ([username hasPrefix:@"Demo."]) {
        badgeLabel.text = localize(@"login.option.demo", @"Demo");
        badgeLabel.backgroundColor = [UIColor colorWithRed:0.55 green:0.35 blue:0.85 alpha:1.0];
    } else if (accountData[@"clientToken"] != nil) {
        badgeLabel.text = localize(@"login.option.3rdparty", @"Third-party");
        badgeLabel.backgroundColor = [UIColor colorWithRed:0.92 green:0.55 blue:0.18 alpha:1.0];
    } else if (accountData[@"xboxGamertag"] == nil) {
        badgeLabel.text = localize(@"login.option.local", @"Local");
        badgeLabel.backgroundColor = [UIColor colorWithWhite:0.45 alpha:1.0];
    } else {
        // 微软账户
        badgeLabel.text = @"Microsoft";
        badgeLabel.backgroundColor = [UIColor colorWithRed:0.20 green:0.55 blue:0.95 alpha:1.0];
    }
}

/// 当前选中的账户 accountId（用于卡片显示选中状态）
/// 使用 accountId 而非 username，确保同名账户也能正确区分选中状态
- (NSString *)currentSelectedAccountId {
    // BaseAuthenticator.current 保存当前活跃账户的 authData
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    return currentAuth.authData[@"accountId"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    // FCL 风格卡片 cell：圆角 + 毛玻璃 + 左侧头像 + 中间用户名/副标题 + 右侧类型徽章/选中勾
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"accountCardCell" forIndexPath:indexPath];

    // 重置 cell：移除上一次复用残留的 contentView 子视图
    for (UIView *sub in cell.contentView.subviews) {
        [sub removeFromSuperview];
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];

    NSDictionary *accountData = self.accountList[indexPath.row];
    NSString *displayName = accountData[@"username"];
    NSString *subtitle = @"";

    // 副标题：Demo 账户显示"演示账户"，第三方显示服务器名，微软显示 Xbox gamertag，本地显示"离线模式"
    if ([displayName hasPrefix:@"Demo."]) {
        displayName = [displayName substringFromIndex:5];
        subtitle = localize(@"login.option.demo", @"Demo account");
    } else if (accountData[@"clientToken"] != nil) {
        // 第三方账户：显示其 authserver 地址
        subtitle = accountData[@"authserver"] ?: localize(@"login.option.3rdparty", @"Third-party account");
    } else if (accountData[@"xboxGamertag"] == nil) {
        subtitle = localize(@"login.option.local", @"Local account");
    } else {
        subtitle = accountData[@"xboxGamertag"] ?: @"Microsoft";
    }

    // 卡片容器（圆角 + 半透明背景 + 毛玻璃）
    UIView *cardView = [[UIView alloc] init];
    cardView.translatesAutoresizingMaskIntoConstraints = NO;
    cardView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10];
    cardView.layer.cornerRadius = 16;
    cardView.layer.cornerCurve = kCACornerCurveContinuous;
    cardView.layer.borderWidth = 0.5;
    cardView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12].CGColor;
    cardView.layer.shadowColor = [UIColor blackColor].CGColor;
    cardView.layer.shadowOffset = CGSizeMake(0, 4);
    cardView.layer.shadowOpacity = 0.12;
    cardView.layer.shadowRadius = 10;
    [cell.contentView addSubview:cardView];
    [[BackgroundManager sharedManager] applyEffectToView:cardView];

    // 左侧头像
    UIImageView *avatarView = [[UIImageView alloc] init];
    avatarView.translatesAutoresizingMaskIntoConstraints = NO;
    avatarView.contentMode = UIViewContentModeScaleAspectFill;
    avatarView.clipsToBounds = YES;
    avatarView.layer.cornerRadius = 24;
    avatarView.layer.cornerCurve = kCACornerCurveContinuous;
    avatarView.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
    avatarView.image = [UIImage imageNamed:@"DefaultAccount"];
    [cardView addSubview:avatarView];
    NSString *picURLStr = [accountData[@"profilePicURL"] stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
    if (picURLStr.length > 0) {
        [avatarView setImageWithURL:[NSURL URLWithString:picURLStr] placeholderImage:[UIImage imageNamed:@"DefaultAccount"]];
    }

    // 用户名
    UILabel *usernameLabel = [[UILabel alloc] init];
    usernameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    usernameLabel.text = displayName;
    usernameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    usernameLabel.textColor = [UIColor labelColor];
    usernameLabel.adjustsFontSizeToFitWidth = YES;
    usernameLabel.minimumScaleFactor = 0.7;
    usernameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [cardView addSubview:usernameLabel];

    // 副标题
    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.text = subtitle;
    subtitleLabel.font = [UIFont systemFontOfSize:12];
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.adjustsFontSizeToFitWidth = YES;
    subtitleLabel.minimumScaleFactor = 0.7;
    subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [cardView addSubview:subtitleLabel];

    // 右侧账户类型徽章
    UILabel *badgeLabel = [[UILabel alloc] init];
    badgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    badgeLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
    badgeLabel.textColor = [UIColor whiteColor];
    badgeLabel.textAlignment = NSTextAlignmentCenter;
    badgeLabel.layer.cornerRadius = 8;
    badgeLabel.layer.cornerCurve = kCACornerCurveContinuous;
    badgeLabel.layer.masksToBounds = YES;
    [cardView addSubview:badgeLabel];
    [self applyAccountTypeBadgeForAccount:accountData badgeLabel:badgeLabel];

    // 选中状态指示
    UIImageView *checkmark = [[UIImageView alloc] init];
    checkmark.translatesAutoresizingMaskIntoConstraints = NO;
    checkmark.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
    checkmark.tintColor = [UIColor colorWithRed:0.20 green:0.65 blue:0.40 alpha:1.0];
    checkmark.contentMode = UIViewContentModeScaleAspectFit;
    [cardView addSubview:checkmark];

    NSString *selectedAccountId = [self currentSelectedAccountId];
    BOOL isCurrentSelected = (selectedAccountId.length > 0 &&
                              [selectedAccountId isEqualToString:accountData[@"accountId"]]);
    checkmark.hidden = !isCurrentSelected;

    // 卡片内边距与子视图布局约束
    [NSLayoutConstraint activateConstraints:@[
        [cardView.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:6],
        [cardView.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [cardView.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [cardView.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-6],

        [avatarView.leadingAnchor constraintEqualToAnchor:cardView.leadingAnchor constant:14],
        [avatarView.centerYAnchor constraintEqualToAnchor:cardView.centerYAnchor],
        [avatarView.widthAnchor constraintEqualToConstant:48],
        [avatarView.heightAnchor constraintEqualToConstant:48],

        [usernameLabel.leadingAnchor constraintEqualToAnchor:avatarView.trailingAnchor constant:14],
        [usernameLabel.topAnchor constraintEqualToAnchor:cardView.topAnchor constant:18],
        [usernameLabel.trailingAnchor constraintEqualToAnchor:badgeLabel.leadingAnchor constant:-8],

        [subtitleLabel.leadingAnchor constraintEqualToAnchor:usernameLabel.leadingAnchor],
        [subtitleLabel.topAnchor constraintEqualToAnchor:usernameLabel.bottomAnchor constant:3],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:usernameLabel.trailingAnchor],
        [subtitleLabel.bottomAnchor constraintEqualToAnchor:cardView.bottomAnchor constant:-18],

        [badgeLabel.trailingAnchor constraintEqualToAnchor:cardView.trailingAnchor constant:-14],
        [badgeLabel.topAnchor constraintEqualToAnchor:cardView.topAnchor constant:14],
        [badgeLabel.heightAnchor constraintEqualToConstant:20],
        [badgeLabel.widthAnchor constraintGreaterThanOrEqualToConstant:52],

        [checkmark.trailingAnchor constraintEqualToAnchor:cardView.trailingAnchor constant:-14],
        [checkmark.bottomAnchor constraintEqualToAnchor:cardView.bottomAnchor constant:-14],
        [checkmark.widthAnchor constraintEqualToConstant:20],
        [checkmark.heightAnchor constraintEqualToConstant:20],
    ]];

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    // ★ [ACCT-DUP] 重入守卫：登录流程在飞时忽略重复选行（连点/长按），避免同一账户被登录两次。
    if (self.ameLoginInFlight) return;
    [self ameSetLoginInFlight:YES];
    NSUInteger generation = ++self.ameAuthGeneration;

    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    [self addActivityIndicatorTo:cell];

    id callback = ^(id status, BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^(){
            // ★ [ACCT-DUP] 回调侧防重：只接受本次登录(generation)的回调，丢弃上一次登录的迟到回调。
            if (generation != self.ameAuthGeneration) return;
            [self callbackMicrosoftAuth:status success:success forCell:cell];
        });
    };

    // Check if this is a third party account
    NSDictionary *accountData = self.accountList[indexPath.row];
    // 优先用 accountId 加载；若 accountId 缺失（旧格式账户未迁移），回退到 username 触发迁移
    NSString *loadKey = accountData[@"accountId"];
    if (loadKey.length == 0) {
        loadKey = accountData[@"username"];
    }
    BaseAuthenticator *auth = nil;
    if (accountData[@"clientToken"] != nil) {
        // This is a third party account
        auth = [ThirdPartyAuthenticator loadSavedName:loadKey];
    } else {
        // This is a Microsoft or local account
        auth = [BaseAuthenticator loadSavedName:loadKey];
    }
    // ★ [ACCT-AUDIT] 状态一致性：loadSavedName 在账户文件缺失/损坏（或读取报错）时返回 nil，
    //   此时 refreshTokenWithCallback: 不会触发任何 callback ⇒ 列表会永久停留在
    //   modalInPresentation=YES + userInteractionEnabled=NO + 转圈，用户被卡死只能杀进程。
    //   这里补回滚：恢复可交互、清掉转圈并提示，accountList 与磁盘状态保持不变。
    if (auth == nil) {
        // ★ [ACCT-DUP] 与重入守卫兼容：统一走 ameSetLoginInFlight:NO 恢复交互与按钮，
        //   保持上一轮 [ACCT-AUDIT] 的 nil 回滚语义（恢复可交互、停转圈、提示）。
        [self ameSetLoginInFlight:NO];
        [self removeActivityIndicatorFrom:cell];
        // ★ [AUDIT-DECIDE] A-10/A-11：account data 载入失败的提示此前硬编码英文，走 localize。
        showDialog(localize(@"Error", nil), localize(@"login.error.account_load", nil));
        return;
    }
    [auth refreshTokenWithCallback:callback];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        // ★ [AUDIT-DECIDE] E-1：删除账户不再"只删本地凭据"——尽力让**远端会话**失效。
        //   判定与登录一致：有 clientToken ⇒ 第三方(Yggdrasil/authlib-injector)；否则 Microsoft/本地。
        //   · 第三方：调官方 Yggdrasil 失效端点 POST <API Root>/authserver/invalidate（见下方 helper）。
        //   · Microsoft：identity platform **没有**消费级 refresh token 的公开撤销端点
        //     （无 RFC 7009 /revoke 等价物；end_session 只结束浏览器会话）⇒ 只做本地失效：
        //     删账户文件 + 清 keychain 里的 access/refresh token（clearTokenDataOfProfile:），
        //     并把内存里该账户的 token/refresh 字段随文件一并丢弃（"标记失效"= 本地不再持有任何可用凭据）。
        //   · 本地账户：无远端会话。
        //   远端调用异步、非阻塞、失败仅记日志（绝不阻断删除）；★ 任何日志都不打印 token 明文。
        NSDictionary *accountData = self.accountList[indexPath.row];

        // 用 accountId 作为文件名（唯一标识），同名账户删除互不影响
        // 若 accountId 缺失（旧格式账户未迁移），回退到 username
        NSString *accountId = accountData[@"accountId"];
        if (accountId.length == 0) {
            accountId = accountData[@"username"];
        }
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *path = [NSString stringWithFormat:@"%s/accounts/%@.json", getenv("POJAV_HOME"), accountId];
        if (self.whenDelete != nil) {
            self.whenDelete(accountId);
        }
        NSString *xuid = accountData[@"xuid"];
        if (xuid) {
            [MicrosoftAuthenticator clearTokenDataOfProfile:xuid];
        }
        [fm removeItemAtPath:path error:nil];
        // ★ [AUDIT-DECIDE] E-1：本地凭据已清除（账户文件 + keychain token），再尽力触发远端失效。
        [self ameInvalidateRemoteSessionForAccountData:accountData accountId:accountId];
        // ★ [ACCT-AUDIT] 清理：删除账户时一并移除其自定义头像文件（Documents/avatars/<accountId>.png），
        //   避免用户图像残留在磁盘上。AvatarManager 按 accountId 存储，删除幂等、文件不存在时安全跳过。
        [[AvatarManager sharedManager] removeAvatarForAccount:accountId];
        // 若删除的正是当前选中账户，清空 selected_account，避免下次启动尝试加载已删除的账户
        if ([getPrefObject(@"internal.selected_account") isEqualToString:accountId]) {
            setPrefObject(@"internal.selected_account", @"");
            [BaseAuthenticator setCurrent:nil];
        }
        [self.accountList removeObjectAtIndex:indexPath.row];
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
    }
}

#pragma mark - ★ [AUDIT-DECIDE] E-1 删除账户 → 远端会话失效

// 尽力让被删账户的远端会话失效。口径（需求："尽量调官方失效/登出接口；无公开接口就写清并只做本地失效"）：
//   ① 第三方(Yggdrasil / authlib-injector)：调用规范中的官方失效端点
//      `POST <API Root>/authserver/invalidate`，body = { accessToken, clientToken }。
//      与既有 authenticate/refresh 同一 API Root；ely.by 沿用旧式 `auth/*` 路径保持一致。
//   ② Microsoft：官方 **没有** 消费级账户 refresh token 的公开撤销端点（无 RFC 7009 /revoke
//      等价物；identity platform 的 logout/end_session 仅结束浏览器会话、不吊销 refresh token）
//      ⇒ 不做远端调用，只做本地失效（账户文件删除 + keychain token 清除，均在调用点已完成）。
//   ③ 非阻塞：网络请求异步发出，删除流程/界面不等待；失败只 NSLog，绝不阻断删除。
//   ④ 隐私：日志只记 accountId / 端点 / 结果（状态码/域名），★ 绝不含 accessToken / clientToken 明文。
- (void)ameInvalidateRemoteSessionForAccountData:(NSDictionary *)data accountId:(NSString *)accountId {
    if (![data isKindOfClass:[NSDictionary class]]) return;
    NSString *tag = accountId.length > 0 ? accountId : @"(unknown)";

    NSString *clientToken = data[@"clientToken"];
    if (clientToken.length == 0) {
        NSLog(@"[ACCT-INVALIDATE] account=%@ kind=msa/local remote=unsupported local=cleared "
              @"(Microsoft exposes no public refresh-token revoke endpoint; account file + keychain token removed)",
              tag);
        return;
    }

    NSString *accessToken = data[@"accessToken"];
    if (accessToken.length == 0) {
        NSLog(@"[ACCT-INVALIDATE] account=%@ kind=3rdparty remote=skipped local=deleted (no access token on record)", tag);
        return;
    }

    NSString *serverURL = data[@"authserver"] ?: @"https://authserver.ely.by";
    if (![serverURL hasSuffix:@"/"]) serverURL = [serverURL stringByAppendingString:@"/"];
    NSString *invalidateURL = [serverURL isEqualToString:@"https://authserver.ely.by/"]
        ? [serverURL stringByAppendingString:@"auth/invalidate"]
        : [serverURL stringByAppendingString:@"authserver/invalidate"];

    NSDictionary *body = @{ @"accessToken": accessToken, @"clientToken": clientToken };
    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
    manager.requestSerializer = AFJSONRequestSerializer.serializer;
    // 失效端点常以 204 空体响应：显式容许空响应，避免被误判为「解析失败」。
    manager.responseSerializer = [AFHTTPResponseSerializer serializer];
    [manager POST:invalidateURL parameters:body headers:nil progress:nil
          success:^(NSURLSessionDataTask *task, id responseObject) {
        NSLog(@"[ACCT-INVALIDATE] account=%@ kind=3rdparty remote=ok url=%@", tag, invalidateURL);
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        NSHTTPURLResponse *http = [task.response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)task.response : nil;
        NSLog(@"[ACCT-INVALIDATE] account=%@ kind=3rdparty remote=failed status=%ld domain=%@ (local deletion kept)",
              tag, (long)http.statusCode, error.domain);
    }];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    // 所有账户行都可滑动删除
    return UITableViewCellEditingStyleDelete;
}

- (NSDictionary *)parseQueryItems:(NSString *)url {
    NSMutableDictionary *result = [NSMutableDictionary new];
    NSArray<NSURLQueryItem *> *queryItems = [NSURLComponents componentsWithString:url].queryItems;
    for (NSURLQueryItem *item in queryItems) {
        result[item.name] = item.value;
    }
    return result;
}

- (void)actionAddAccount:(UIView *)sender {
    // ★ [ACCT-DUP] 重入守卫：防连点「添加账户」push 出两个登录方式页（解锁见 viewWillAppear）。
    if (self.ameAddAccountInFlight) return;
    self.ameAddAccountInFlight = YES;
    // 参照 FCL：push 卡片式登录方式选择页（替代原来的 ActionSheet）
    AccountLoginViewController *loginVC = [[AccountLoginViewController alloc] init];
    loginVC.onSelectLoginType = ^(AccountLoginType type) {
        // 选完登录方式后 pop 回账户列表，再触发对应登录流程
        [self.navigationController popViewControllerAnimated:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            switch (type) {
                case AccountLoginTypeMicrosoft:
                    [self actionLoginMicrosoft:sender];
                    break;
                case AccountLoginTypeLittleSkin:
                    [self actionLoginLittleSkin:sender];
                    break;
                case AccountLoginTypeThirdParty:
                    [self actionLoginThirdParty:sender];
                    break;
                case AccountLoginTypeLocal:
                    [self actionLoginLocal:sender];
                    break;
            }
        });
    };
    [self.navigationController pushViewController:loginVC animated:YES];
}

- (void)actionLoginLocal:(UIView *)sender {
    if (getPrefBool(@"warnings.local_warn")) {
        setPrefBool(@"warnings.local_warn", NO);
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"login.warn.title.localmode", nil) message:localize(@"login.warn.message.localmode", nil) preferredStyle:UIAlertControllerStyleActionSheet];
        // 修复：sender 为 nil 时（从 addAccountTapped -> actionAddAccount:nil 链路进入），
        // ActionSheet 在 iPad/LiveContainer 等 popover 场景下必须提供 sourceView，
        // 否则会因 popoverPresentationController.sourceView 为 nil 而崩溃。
        // 回退顺序：sender -> addAccountButton -> self.view 中心点。
        UIView *sourceView = sender ?: self.addAccountButton;
        if (sourceView) {
            alert.popoverPresentationController.sourceView = sourceView;
            alert.popoverPresentationController.sourceRect = sourceView.bounds;
        } else {
            alert.popoverPresentationController.sourceView = self.view;
            alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
            alert.popoverPresentationController.permittedArrowDirections = 0;
        }
        UIAlertAction *ok = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {[self actionLoginLocal:sender];}];
        [alert addAction:ok];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    // ★ [AUDIT-DECIDE] A-11：English 字面量当 key（.strings 无此键）→ 新增键 login.sign_in。
    UIAlertController *controller = [UIAlertController alertControllerWithTitle:localize(@"login.sign_in", nil) message:localize(@"login.option.local", nil) preferredStyle:UIAlertControllerStyleAlert];
    [controller addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = localize(@"login.alert.field.username", nil);
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.borderStyle = UITextBorderStyleRoundedRect;
    }];
    [controller addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSArray *textFields = controller.textFields;
        UITextField *usernameField = textFields[0];
        if (usernameField.text.length < 3 || usernameField.text.length > 16) {
            controller.message = localize(@"login.error.username.outOfRange", nil);
            [self presentViewController:controller animated:YES completion:nil];
        } else {
            id callback = ^(id status, BOOL success) {
                if (self.whenItemSelected) self.whenItemSelected();
                // ★ [ACCT-DUP] 本地登录也刷新列表（与微软/三方路径口径一致），
                //   立即反映存储幂等去重的结果（重复用户名只会得到同一条）。
                [self reloadAccountList];
                [self dismissViewControllerAnimated:YES completion:nil];
            };
            [[[LocalAuthenticator alloc] initWithInput:usernameField.text] loginWithCallback:callback];
        }
    }]];
    [controller addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:controller animated:YES completion:nil];
}

- (void)actionLoginThirdParty:(UIView *)sender {
    // 参照 FCL：push 卡片式第三方登录表单页（替代原 UIAlertController 三字段输入）
    ThirdPartyLoginViewController *vc = [[ThirdPartyLoginViewController alloc] init];
    vc.mode = ThirdPartyLoginModeCustom;
    __weak typeof(self) weakSelf = self;
    vc.onLoginComplete = ^(BOOL success, NSString *errorMessage) {
        if (success) {
            [weakSelf.navigationController popViewControllerAnimated:YES];
            if (weakSelf.whenItemSelected) weakSelf.whenItemSelected();
        }
    };
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)actionLoginLittleSkin:(UIView *)sender {
    // 参照 FCL：push 卡片式 LittleSkin 登录表单页（替代原 UIAlertController 双字段输入）
    // LittleSkin 端点固定为 https://littleskin.cn/api/yggdrasil，由 VC 内部预设
    ThirdPartyLoginViewController *vc = [[ThirdPartyLoginViewController alloc] init];
    vc.mode = ThirdPartyLoginModeLittleSkin;
    __weak typeof(self) weakSelf = self;
    vc.onLoginComplete = ^(BOOL success, NSString *errorMessage) {
        if (success) {
            [weakSelf.navigationController popViewControllerAnimated:YES];
            if (weakSelf.whenItemSelected) weakSelf.whenItemSelected();
        }
    };
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)actionLoginMicrosoft:(UIView *)sender {
    NSURL *url = [NSURL URLWithString:@"https://login.live.com/oauth20_authorize.srf?client_id=00000000402b5328&response_type=code&scope=service%3A%3Auser.auth.xboxlive.com%3A%3AMBI_SSL&redirect_url=https%3A%2F%2Flogin.live.com%2Foauth20_desktop.srf"];

    self.authVC =
        [[ASWebAuthenticationSession alloc] initWithURL:url
        callbackURLScheme:@"ms-xal-00000000402b5328"
        completionHandler:^(NSURL * _Nullable callbackURL, NSError * _Nullable error)
    {
        if (callbackURL == nil) {
            if (error.code != ASWebAuthenticationSessionErrorCodeCanceledLogin) {
                showDialog(localize(@"Error", nil), error.localizedDescription);
            }
            return;
        }
        // NSLog(@"URL returned = %@", [callbackURL absoluteString]);

        NSDictionary *queryItems = [self parseQueryItems:callbackURL.absoluteString];
        if (queryItems[@"code"]) {
            dispatch_async(dispatch_get_main_queue(), ^(){
                // ★ [ACCT-DONE] 统一走 in-flight 锁(只锁列表+「添加账户」按钮,绝不动导航栏出口);
                //   原实现此处散写 modalInPresentation/tableView —— modalInPresentation 对本页
                //   (内容容器里的子 VC)无效,已随 ameSetLoginInFlight: 一并收敛。
                [self ameSetLoginInFlight:YES];
                // 仅当 sender 是 UITableViewCell 时才显示加载指示器
                if ([sender isKindOfClass:[UITableViewCell class]]) {
                    [self addActivityIndicatorTo:(UITableViewCell *)sender];
                }
            });
            id callback = ^(id status, BOOL success) {
                if ([status isKindOfClass:NSString.class] && [status isEqualToString:@"DEMO"] && success) {
                    showDialog(localize(@"login.warn.title.demomode", nil), localize(@"login.warn.message.demomode", nil));
                }
                dispatch_async(dispatch_get_main_queue(), ^(){
                    UITableViewCell *cell = [sender isKindOfClass:[UITableViewCell class]] ? (UITableViewCell *)sender : nil;
                    [self callbackMicrosoftAuth:status success:success forCell:cell];
                });
            };
            [[[MicrosoftAuthenticator alloc] initWithInput:queryItems[@"code"]] loginWithCallback:callback];
        } else {
            if ([queryItems[@"error"] hasPrefix:@"access_denied"]) {
                // Ignore access denial responses
                return;
            }
            showDialog(localize(@"Error", nil), queryItems[@"error_description"]);
        }
    }];

    self.authVC.prefersEphemeralWebBrowserSession = YES;
    self.authVC.presentationContextProvider = self;

    if ([self.authVC start] == NO) {
        showDialog(localize(@"Error", nil), @"Unable to open Safari");
    }
}

- (void)addActivityIndicatorTo:(UITableViewCell *)cell {
    UIActivityIndicatorViewStyle indicatorStyle = UIActivityIndicatorViewStyleMedium;
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:indicatorStyle];
    cell.accessoryView = indicator;
    [indicator sizeToFit];
    [indicator startAnimating];
}

- (void)removeActivityIndicatorFrom:(UITableViewCell *)cell {
    UIActivityIndicatorView *indicator = (id)cell.accessoryView;
    [indicator stopAnimating];
    cell.accessoryView = nil;
}

/// ★ [AUTH-FIX] 把认证失败对象转成**可辨识**的用户可读文案（不再只给 AFNetworking 的
///   "Request failed: unauthorized (401)" 这类笼统串）：
///   · NSString  → 原样返回；
///   · NSError   → 优先解析响应体里的 XErr / Message / errorMessage / error_description / error；
///                 拿不到再退回 HTTP 状态码 + localizedDescription。
///   安全性：响应体只含错误码与说明文本，**不含任何 token/凭据**；本方法不回显凭据。
- (NSString *)ameReadableAuthError:(id)status {
    if ([status isKindOfClass:[NSString class]]) {
        return status;
    }
    if (![status isKindOfClass:[NSError class]]) {
        return localize(@"login.error.invalid_response", nil);
    }
    NSError *error = (NSError *)status;
    NSHTTPURLResponse *http = error.userInfo[AFNetworkingOperationFailingURLResponseErrorKey];
    NSInteger code = ([http isKindOfClass:[NSHTTPURLResponse class]]) ? http.statusCode : 0;

    NSString *detail = nil;
    NSData *errorData = error.userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey];
    if (errorData.length > 0) {
        id json = [NSJSONSerialization JSONObjectWithData:errorData options:kNilOptions error:nil];
        if ([json isKindOfClass:[NSDictionary class]]) {
            NSDictionary *d = json;
            id xerr = d[@"XErr"];
            id msg = d[@"Message"] ?: d[@"errorMessage"] ?: d[@"error_description"] ?: d[@"error"];
            if (xerr != nil || msg != nil) {
                NSMutableArray *parts = [NSMutableArray array];
                if (msg != nil) [parts addObject:[msg description]];
                if (xerr != nil) [parts addObject:[NSString stringWithFormat:@"XErr=%@", xerr]];
                detail = [parts componentsJoinedByString:@" "];
            }
        } else {
            NSString *raw = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
            if (raw.length > 0 && raw.length < 512) detail = raw;   // 短非 JSON 正文也带上
        }
    }

    if (detail.length > 0) {
        return (code > 0) ? [NSString stringWithFormat:@"HTTP %ld — %@", (long)code, detail] : detail;
    }
    if (code > 0) {
        return [NSString stringWithFormat:@"HTTP %ld — %@", (long)code, error.localizedDescription ?: @""];
    }
    return error.localizedDescription ?: localize(@"login.error.invalid_response", nil);
}

- (void)callbackMicrosoftAuth:(id)status success:(BOOL)success forCell:(UITableViewCell *)cell {
    // ★ [AUTH-FIX] 区分「进度」与「完成」——修微软登录卡在「(2/6) 请求 Xbox Live 令牌」的误判：
    //   认证器每一步都发 (status != nil, success = YES) 的**进度**回调
    //   （如 localize(@"login.msa.progress.acquireXBLToken") == "(2/6) 请求 Xbox Live 令牌"）。
    //   原实现把这种回调当成「登录成功」收尾（弹"账户"对话框 + reload + dismiss + 解锁），于是：
    //     ① 刚点登录就弹出进度对话框并提前收尾/解锁；
    //     ② 若紧接着 XBL 步骤失败，用户最后看到的进度文本正是「请求 Xbox Live 令牌」，
    //        而失败提示又很笼统 ⇒ 用户表现为"无法请求 Xbox 令牌"。
    //   上游语义：(status != nil, success = YES) = 进度；(status == nil, success = YES) = 完成。
    //   唯一终态例外：@"DEMO"（Demo 账户已保存）走完成收尾。
    BOOL isDemo = (success && [status isKindOfClass:[NSString class]] && [status isEqualToString:@"DEMO"]);

    // ① 进度：只更新 UI，绝不 dismiss / reload / 解锁 / whenItemSelected
    if (status != nil && success && !isDemo) {
        NSString *progress = [status isKindOfClass:[NSError class]] ? [(NSError *)status localizedDescription]
                            : ([status isKindOfClass:[NSString class]] ? status : [status description]);
        NSLog(@"[MSA] progress: %@", progress);
        if (cell && cell.detailTextLabel) cell.detailTextLabel.text = progress;
        return;
    }

    // ② 认证失败：恢复交互并展示**可辨识**错误
    if (status != nil && !success) {
        [self ameSetLoginInFlight:NO];
        if (cell) [self removeActivityIndicatorFrom:cell];
        NSString *message = [self ameReadableAuthError:status];
        NSLog(@"[MSA] Error: %@", message);
        showDialog(localize(@"Error", nil), message);
        return;
    }

    // ③ 完成：status == nil（或 DEMO 终态）
    if (success) {
        if (isDemo) {
            showDialog(localize(@"login.warn.title.demomode", nil), localize(@"login.warn.message.demomode", nil));
        }
        if (cell) [self removeActivityIndicatorFrom:cell];
        [self ameSetLoginInFlight:NO];
        [self reloadAccountList];
        if (self.whenItemSelected) self.whenItemSelected();
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }

    // ④ status == nil 且 success == NO（取消/无内容回调）：同样必须解锁
    // ★ [ACCT-DONE] 原实现缺这一支 ⇒ in-flight 永久置位、列表与「添加账户」永久禁用(只能杀进程)。
    if (cell) [self removeActivityIndicatorFrom:cell];
    [self ameSetLoginInFlight:NO];
    showDialog(localize(@"Error", nil), localize(@"login.error.invalid_response", nil));
}

/// 重新加载账户列表并刷新表格（FCL 风格：登录/删除后刷新卡片视图）
- (void)reloadAccountList {
    [self ameLoadAccountListFromDisk];
    [self.tableView reloadData];
}

/// ★ [ACCT-DUP] 从磁盘载入账户列表（viewDidLoad / reloadAccountList 共用）：
///   ① 载入前先调用 deduplicateAccountsDirectory 合并**同身份**的存量重复（幂等，只删真正重复的文件，
///      不同 username/xuid/profileId 的合法多账号一律保留）；
///   ② 跳过 parseJSONFromFile 失败的损坏文件（返回 @{NSErrorObject:…}），
///      避免列表里凭空多出一条无用户名的“幽灵账户”。
- (void)ameLoadAccountListFromDisk {
    if (self.accountList == nil) {
        self.accountList = [NSMutableArray array];
    } else {
        [self.accountList removeAllObjects];
    }
    [BaseAuthenticator deduplicateAccountsDirectory];

    NSString *listPath = [NSString stringWithFormat:@"%s/accounts", getenv("POJAV_HOME")];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:listPath error:nil];
    for (NSString *file in files) {
        NSString *path = [listPath stringByAppendingPathComponent:file];
        BOOL isDir = NO;
        [fm fileExistsAtPath:path isDirectory:(&isDir)];
        if (isDir || ![file hasSuffix:@".json"]) continue;
        NSMutableDictionary *data = parseJSONFromFile(path);
        if (data == nil || data[@"NSErrorObject"] != nil) continue;
        [self.accountList addObject:data];
    }
}

/// ★ [ACCT-DUP] 统一的「登录进行中」开关：置位的同一处即禁用列表与「添加账户」按钮，
///   结束（成功/失败/取消/nil 回滚/页面离开/看门狗）时恢复——保证一次登录流程在飞期间无法被重复触发。
///
/// ★ [ACCT-DONE] 本轮修正两点：
///   ① 只锁【会触发登录的控件】(表格行 + 「添加账户」按钮)。原先还写 self.modalInPresentation,
///      但本页是内容容器里的**子 VC**(setContentViewController: 塞进主页 contentContainer),
///      不是模态呈现 ⇒ 该属性无意义,是历史 FormSheet 时代的残留;真正该守的是"导航栏出口(
///      「完成」左键)任何时候都能点",导航 chrome 一律不锁(见 ameAccountEnsureBackItemIfNeeded)。
///   ② 加【看门狗】:置位后 60s 若代次未变且仍在飞 ⇒ 强制解锁。防"回调丢失/网络 hang"把
///      列表永久锁死(与 viewWillAppear 的无条件解锁互为双保险 = defer 式保证)。
- (void)ameSetLoginInFlight:(BOOL)inFlight {
    self.ameLoginInFlight = inFlight;
    self.tableView.userInteractionEnabled = !inFlight;
    self.addAccountButton.enabled = !inFlight;
    NSUInteger token = ++self.ameLoginInFlightToken;
    if (!inFlight) return;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.ameLoginInFlightToken != token) return;   // 已被正常解锁/又换了新一次 ⇒ 不管
        if (!strongSelf.ameLoginInFlight) return;
        NSLog(@"[ACCT-DONE] in-flight 看门狗超时(60s),强制解锁(防回调丢失把列表锁死)");
        [strongSelf ameSetLoginInFlight:NO];
    });
}

/// ★ [ACCT-DONE] 页面真的离开窗口(被 pop / 被内容区换走)时解锁;只是被网页登录盖住时
///   self.view.window 仍在 ⇒ 不解锁,不会打断正在进行的登录。
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.view.window == nil) {
        [self ameSetLoginInFlight:NO];
    }
}

#pragma mark - UIPopoverPresentationControllerDelegate
- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller traitCollection:(UITraitCollection *)traitCollection {
    return UIModalPresentationNone;
}

#pragma mark - ASWebAuthenticationPresentationContextProviding
- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession *)session {
    return UIApplication.sharedApplication.windows.firstObject;
}

@end
