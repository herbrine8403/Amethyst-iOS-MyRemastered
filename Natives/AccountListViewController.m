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
#import "ios_uikit_bridge.h"
#import "utils.h"
// ★ [EDIT3] 头像设置入口:复用既有通知动作(LauncherRightPanelViewController norightPostAction:)。
#import "LauncherRightPanelViewController.h"

@interface AccountListViewController()<ASWebAuthenticationPresentationContextProviding>

@property(nonatomic, strong) NSMutableArray *accountList;
@property(nonatomic) ASWebAuthenticationSession *authVC;
// ★ [ADDBTN-INSET] 底部「添加账户」按钮的底边约束:单独持有,交由布局期按【实际遮挡量】调整。
@property(nonatomic, strong) NSLayoutConstraint *ameAddAccountBottomConstraint;

@end

@implementation AccountListViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // 适配自定义启动器背景：将当前视图控制器透明化，使全局背景壁纸能够透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    self.title = localize(@"login.title", @"账户管理");
    self.view.backgroundColor = [UIColor clearColor];

    if (self.accountList == nil) {
        self.accountList = [NSMutableArray array];
    } else {
        [self.accountList removeAllObjects];
    }

    // List accounts
    NSString *listPath = [NSString stringWithFormat:@"%s/accounts", getenv("POJAV_HOME")];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:listPath error:nil];
    for(NSString *file in files) {
        NSString *path = [listPath stringByAppendingPathComponent:file];
        BOOL isDir = NO;
        [fm fileExistsAtPath:path isDirectory:(&isDir)];
        if(!isDir && [file hasSuffix:@".json"]) {
            [self.accountList addObject:parseJSONFromFile(path)];
        }
    }

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

    // ★ [EDIT3] 自定义头像菜单的**新入口**:本页 = 点头像进入的「账户管理」页。
    //   原来“长按主页欢迎卡头像”才能弹出的自定义头像菜单(导入 / 清除),其长按触发器已让位给
    //   “长按进编辑模式”(见 LauncherNewsViewController.m ★[EDIT3]);为不丢功能,在此给一颗
    //   明确可见的右键「自定义头像」:点击**只** post 既有动作名 avatarMenu ⇒ 仍由
    //   LauncherRightPanelViewController 的 showAvatarMenu: 原实现弹出,菜单项/回调/账户校验/
    //   裁剪保存链路一律不动;本页不复制任何头像逻辑。
    //   幂等:已注入过就不再注入。按钮挂在本 VC 的 navigationItem 上 ⇒ 只有本页可见,
    //   push 出去的登录页用的是它自己的 navigationItem,不受影响。
    if (!self.navigationItem.rightBarButtonItem) {
        UIBarButtonItem *avatarItem = [[UIBarButtonItem alloc] initWithTitle:localize(@"i18n_str_416", @"自定义头像")
                                                                      style:UIBarButtonItemStylePlain
                                                                     target:self
                                                                     action:@selector(ameAccountAvatarSettingsTapped)];
        avatarItem.tintColor = [UIColor labelColor];
        avatarItem.accessibilityLabel = localize(@"i18n_str_416", @"自定义头像");
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
    [addBtn setTitle:localize(@"login.option.add", @"添加账户") forState:UIControlStateNormal];
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
        badgeLabel.text = localize(@"login.option.demo", @"演示");
        badgeLabel.backgroundColor = [UIColor colorWithRed:0.55 green:0.35 blue:0.85 alpha:1.0];
    } else if (accountData[@"clientToken"] != nil) {
        badgeLabel.text = localize(@"login.option.3rdparty", @"第三方");
        badgeLabel.backgroundColor = [UIColor colorWithRed:0.92 green:0.55 blue:0.18 alpha:1.0];
    } else if (accountData[@"xboxGamertag"] == nil) {
        badgeLabel.text = localize(@"login.option.local", @"本地");
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
        subtitle = localize(@"login.option.demo", @"演示账户");
    } else if (accountData[@"clientToken"] != nil) {
        // 第三方账户：显示其 authserver 地址
        subtitle = accountData[@"authserver"] ?: localize(@"login.option.3rdparty", @"第三方账户");
    } else if (accountData[@"xboxGamertag"] == nil) {
        subtitle = localize(@"login.option.local", @"离线模式");
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
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];

    self.modalInPresentation = YES;
    self.tableView.userInteractionEnabled = NO;
    [self addActivityIndicatorTo:cell];

    id callback = ^(id status, BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^(){
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
    if (accountData[@"clientToken"] != nil) {
        // This is a third party account
        [[ThirdPartyAuthenticator loadSavedName:loadKey] refreshTokenWithCallback:callback];
    } else {
        // This is a Microsoft or local account
        [[BaseAuthenticator loadSavedName:loadKey] refreshTokenWithCallback:callback];
    }
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        // TODO: invalidate token

        // 用 accountId 作为文件名（唯一标识），同名账户删除互不影响
        // 若 accountId 缺失（旧格式账户未迁移），回退到 username
        NSString *accountId = self.accountList[indexPath.row][@"accountId"];
        if (accountId.length == 0) {
            accountId = self.accountList[indexPath.row][@"username"];
        }
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *path = [NSString stringWithFormat:@"%s/accounts/%@.json", getenv("POJAV_HOME"), accountId];
        if (self.whenDelete != nil) {
            self.whenDelete(accountId);
        }
        NSString *xuid = self.accountList[indexPath.row][@"xuid"];
        if (xuid) {
            [MicrosoftAuthenticator clearTokenDataOfProfile:xuid];
        }
        [fm removeItemAtPath:path error:nil];
        // 若删除的正是当前选中账户，清空 selected_account，避免下次启动尝试加载已删除的账户
        if ([getPrefObject(@"internal.selected_account") isEqualToString:accountId]) {
            setPrefObject(@"internal.selected_account", @"");
            [BaseAuthenticator setCurrent:nil];
        }
        [self.accountList removeObjectAtIndex:indexPath.row];
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
    }
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
    UIAlertController *controller = [UIAlertController alertControllerWithTitle:localize(@"Sign in", nil) message:localize(@"login.option.local", nil) preferredStyle:UIAlertControllerStyleAlert];
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
                self.modalInPresentation = YES;
                self.tableView.userInteractionEnabled = NO;
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

- (void)callbackMicrosoftAuth:(id)status success:(BOOL)success forCell:(UITableViewCell *)cell {
    if (status != nil) {
        if (success) {
            // 登录成功并伴随状态信息
            if ([status isKindOfClass:[NSError class]]) {
                showDialog(localize(@"login.title", @"账户"), [status localizedDescription]);
            } else {
                if ([status isKindOfClass:[NSString class]] && [status isEqualToString:@"DEMO"]) {
                    showDialog(localize(@"login.warn.title.demomode", nil), localize(@"login.warn.message.demomode", nil));
                } else if ([status isKindOfClass:[NSString class]]) {
                    showDialog(localize(@"login.title", @"账户"), status);
                }
            }
            // 登录成功后刷新列表以显示新账户
            if (cell) [self removeActivityIndicatorFrom:cell];
            self.modalInPresentation = NO;
            self.tableView.userInteractionEnabled = YES;
            [self reloadAccountList];
            if (self.whenItemSelected) self.whenItemSelected();
            [self dismissViewControllerAnimated:YES completion:nil];
        } else {
            // 认证失败：恢复交互并展示错误
            self.modalInPresentation = NO;
            self.tableView.userInteractionEnabled = YES;
            if (cell) [self removeActivityIndicatorFrom:cell];

            if ([status isKindOfClass:[NSError class]]) {
                NSData *errorData = ((NSError *)status).userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey];
                if (errorData) {
                    NSString *errorStr = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
                    NSLog(@"[MSA] Error: %@", errorStr);
                    showDialog(localize(@"Error", nil), errorStr);
                } else {
                    showDialog(localize(@"Error", nil), [status localizedDescription]);
                }
            } else if ([status isKindOfClass:[NSString class]]) {
                showDialog(localize(@"Error", nil), status);
            } else {
                showDialog(localize(@"Error", nil), localize(@"login.error.invalid_response", nil));
            }
        }
    } else if (success) {
        // 成功登录，无消息
        if (cell) [self removeActivityIndicatorFrom:cell];
        self.modalInPresentation = NO;
        self.tableView.userInteractionEnabled = YES;
        [self reloadAccountList];
        if (self.whenItemSelected) self.whenItemSelected();
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

/// 重新加载账户列表并刷新表格（FCL 风格：登录/删除后刷新卡片视图）
- (void)reloadAccountList {
    if (self.accountList == nil) {
        self.accountList = [NSMutableArray array];
    } else {
        [self.accountList removeAllObjects];
    }
    NSString *listPath = [NSString stringWithFormat:@"%s/accounts", getenv("POJAV_HOME")];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:listPath error:nil];
    for (NSString *file in files) {
        NSString *path = [listPath stringByAppendingPathComponent:file];
        BOOL isDir = NO;
        [fm fileExistsAtPath:path isDirectory:(&isDir)];
        if (!isDir && [file hasSuffix:@".json"]) {
            [self.accountList addObject:parseJSONFromFile(path)];
        }
    }
    [self.tableView reloadData];
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
