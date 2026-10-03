//
//  AIViewController.m
//  Amethyst
//

#import "AIViewController.h"
#import "AIMessageCell.h"
#import "AIInputBarView.h"
#import "AiAgent.h"
#import "AiSessionStore.h"
#import "AiProviderStore.h"
#import "AiSettings.h"
#import "BackgroundManager.h"
#import "LauncherPreferences.h"
#import "AISessionListViewController.h"
#import "AIProviderConfigViewController.h"

/// 流式 UI 刷新节流阈值，避免 Markdown 反复重算
static const NSTimeInterval kUIThrottleInterval = 0.2;

@interface AIViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) AiSession *session;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) AIInputBarView *inputBar;
@property (nonatomic, strong) NSLayoutConstraint *inputBarBottomConstraint;
@property (nonatomic, assign) NSTimeInterval lastStreamUpdateTime;
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;

// 空态视图
@property (nonatomic, strong) UIView *emptyStateView;
@property (nonatomic, strong) UIImageView *emptyIcon;
@property (nonatomic, strong) UILabel *emptyTitle;
@property (nonatomic, strong) UILabel *emptySubtitle;
@property (nonatomic, strong) UIButton *configureButton;
@end

@implementation AIViewController

#pragma mark - 初始化

- (instancetype)initWithSession:(AiSession *)session {
    self = [super init];
    if (self) {
        _session = session;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // 懒创建会话
    if (!self.session) {
        self.session = [[AiSessionStore sharedStore] newSession];
        [[AiSessionStore sharedStore] updateSession:self.session];
    }
    if (self.session.title.length == 0) {
        self.session.title = @"AI 助手";
    }

    // 浅色背景（内容区整体毛玻璃由外层 BackgroundManager 提供），不加额外毛玻璃
    self.view.backgroundColor = [[UIColor labelColor] colorWithAlphaComponent:0.04];

    self.navigationItem.title = self.session.title;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;

    [self setupNavBar];
    [self setupUI];
    [self setupKeyboardObservers];
    [self updateModelLabel];
    [self updateEmptyState];

    // 监听会话消息变更通知：AiAgent 在 tool_calls / tool 结果消息追加后发出（object=session），
    // 收到后即时整表刷新，保证「assistant tool_calls → tool 结果 → 下一轮回复」按序显示。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleSessionMessagesChanged:)
                                                 name:@"AiSessionMessagesDidChangeNotification"
                                               object:nil];
}

/// 会话消息变更通知回调：仅当通知携带的正是当前会话时才整表刷新并滚底
- (void)handleSessionMessagesChanged:(NSNotification *)note {
    if (note.object && ![note.object isEqual:self.session]) return;
    [self reloadAndScrollToBottom];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.activityIndicator stopAnimating];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // 进入会话页滚动到底；无动画避免进场跳动。空会话不滚动。
    if (self.session.messages.count > 0) {
        [self scrollToBottomAnimated:NO];
    }
}

#pragma mark - Nav Bar

- (void)setupNavBar {
    // 右侧「会话」图标（Phase 2 接入会话列表，本期占位）
    UIBarButtonItem *sessionsItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"rectangle.stack.badge.person.crop"]
                                                                     style:UIBarButtonItemStylePlain
                                                                    target:self
                                                                    action:@selector(sessionsAction)];
    self.navigationItem.rightBarButtonItem = sessionsItem;
    // 返回键由导航栈提供，不需要额外设置
}

- (void)sessionsAction {
    AISessionListViewController *listVC = [[AISessionListViewController alloc] init];
    __weak typeof(self) weakSelf = self;
    listVC.onSelectSession = ^(AiSession *session) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf switchToSession:session];
        [strongSelf.navigationController popViewControllerAnimated:YES];
    };
    listVC.onNewSession = ^(AiSession *session) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf switchToSession:session];
        [strongSelf.navigationController popToRootViewControllerAnimated:YES];
    };

    if (self.navigationController) {
        [self.navigationController pushViewController:listVC animated:YES];
    } else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:listVC];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [self presentViewController:nav animated:YES completion:nil];
    }
}

/// 切换到指定会话并刷新界面
- (void)switchToSession:(AiSession *)session {
    if (!session) return;
    self.session = session;
    NSString *title = session.title.length > 0 ? session.title : @"AI 助手";
    self.navigationItem.title = title;
    [self reloadAndScrollToBottom];
    [self updateEmptyState];
}

/// 进入提供商配置页
- (void)presentProviderConfig {
    AIProviderConfigViewController *vc = [[AIProviderConfigViewController alloc] init];
    if (self.navigationController) {
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [self presentViewController:nav animated:YES completion:nil];
    }
}

#pragma mark - 布局

- (void)setupUI {
    // 表格
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.tableView.alwaysBounceVertical = YES;
    self.tableView.estimatedRowHeight = 80;
    [self.tableView registerClass:[AIMessageCell class] forCellReuseIdentifier:@"AIMessageCell"];
    [self.view addSubview:self.tableView];

    // 底部输入栏
    self.inputBar = [[AIInputBarView alloc] init];
    [self.view addSubview:self.inputBar];
    self.inputBar.bottomInset = self.view.safeAreaInsets.bottom;

    __weak typeof(self) weakSelf = self;
    self.inputBar.onSend = ^(NSString *text) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf handleSend:text];
    };
    self.inputBar.onStop = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf handleStop];
    };
    self.inputBar.onModelTap = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf handleModelTap];
    };

    // 空态视图
    [self setupEmptyState];

    self.inputBarBottomConstraint = [self.inputBar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.inputBar.topAnchor],

        [self.inputBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.inputBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        self.inputBarBottomConstraint,
    ]];

    // loading 指示器：用于发送消息时的加载反馈（简单实现）
    self.activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.activityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.activityIndicator.hidesWhenStopped = YES;
    [self.view addSubview:self.activityIndicator];
    [NSLayoutConstraint activateConstraints:@[
        [self.activityIndicator.centerXAnchor constraintEqualToAnchor:self.tableView.centerXAnchor],
        [self.activityIndicator.centerYAnchor constraintEqualToAnchor:self.tableView.centerYAnchor],
    ]];
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    // 旋转/分屏等导致安全区变化时同步输入栏底部垫高
    self.inputBar.bottomInset = self.view.safeAreaInsets.bottom;
}

- (void)setupEmptyState {
    self.emptyStateView = [[UIView alloc] init];
    self.emptyStateView.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyStateView.hidden = YES;
    self.emptyStateView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.emptyStateView];

    // 关键修复（空态图标显示成一串英文字母）：原为 UILabel 却填入 SF Symbol 名（"sparkles"）
    // 导致显示成文字。改为 UIImageView + systemImageNamed: 真正渲染图标。
    self.emptyIcon = [[UIImageView alloc] init];
    self.emptyIcon.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyIcon.contentMode = UIViewContentModeScaleAspectFit;
    UIImageSymbolConfiguration *iconConfig = [UIImageSymbolConfiguration configurationWithPointSize:56 weight:UIImageSymbolWeightRegular];
    self.emptyIcon.image = [UIImage systemImageNamed:@"sparkles" withConfiguration:iconConfig];
    self.emptyIcon.tintColor = [UIColor secondaryLabelColor];
    [self.emptyStateView addSubview:self.emptyIcon];

    self.emptyTitle = [[UILabel alloc] init];
    self.emptyTitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyTitle.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    self.emptyTitle.textColor = [UIColor labelColor];
    self.emptyTitle.textAlignment = NSTextAlignmentCenter;
    self.emptyTitle.numberOfLines = 0;
    [self.emptyStateView addSubview:self.emptyTitle];

    self.emptySubtitle = [[UILabel alloc] init];
    self.emptySubtitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptySubtitle.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    self.emptySubtitle.textColor = [UIColor secondaryLabelColor];
    self.emptySubtitle.textAlignment = NSTextAlignmentCenter;
    self.emptySubtitle.numberOfLines = 0;
    [self.emptyStateView addSubview:self.emptySubtitle];

    self.configureButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.configureButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.configureButton.hidden = YES;
    self.configureButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [self.configureButton setTitle:@"去配置" forState:UIControlStateNormal];
    [self.configureButton addTarget:self action:@selector(configureAction) forControlEvents:UIControlEventTouchUpInside];
    // 胶囊按钮
    self.configureButton.backgroundColor = [accentColor() colorWithAlphaComponent:0.15];
    self.configureButton.layer.cornerRadius = 16;
    self.configureButton.layer.cornerCurve = kCACornerCurveContinuous;
    self.configureButton.clipsToBounds = YES;
    [self.configureButton setTitleColor:accentColor() forState:UIControlStateNormal];
    [self.emptyStateView addSubview:self.configureButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.emptyStateView.centerXAnchor constraintEqualToAnchor:self.tableView.centerXAnchor],
        [self.emptyStateView.centerYAnchor constraintEqualToAnchor:self.tableView.centerYAnchor],
        [self.emptyStateView.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.tableView.leadingAnchor constant:32],
        [self.emptyStateView.trailingAnchor constraintLessThanOrEqualToAnchor:self.tableView.trailingAnchor constant:-32],

        [self.emptyIcon.topAnchor constraintEqualToAnchor:self.emptyStateView.topAnchor],
        [self.emptyIcon.centerXAnchor constraintEqualToAnchor:self.emptyStateView.centerXAnchor],

        [self.emptyTitle.topAnchor constraintEqualToAnchor:self.emptyIcon.bottomAnchor constant:12],
        [self.emptyTitle.leadingAnchor constraintEqualToAnchor:self.emptyStateView.leadingAnchor],
        [self.emptyTitle.trailingAnchor constraintEqualToAnchor:self.emptyStateView.trailingAnchor],

        [self.emptySubtitle.topAnchor constraintEqualToAnchor:self.emptyTitle.bottomAnchor constant:6],
        [self.emptySubtitle.leadingAnchor constraintEqualToAnchor:self.emptyStateView.leadingAnchor],
        [self.emptySubtitle.trailingAnchor constraintEqualToAnchor:self.emptyStateView.trailingAnchor],

        [self.configureButton.topAnchor constraintEqualToAnchor:self.emptySubtitle.bottomAnchor constant:16],
        [self.configureButton.centerXAnchor constraintEqualToAnchor:self.emptyStateView.centerXAnchor],
        [self.configureButton.heightAnchor constraintEqualToConstant:36],
        [self.configureButton.widthAnchor constraintEqualToConstant:96],
        [self.configureButton.bottomAnchor constraintEqualToAnchor:self.emptyStateView.bottomAnchor],
    ]];
}

#pragma mark - 键盘

- (void)setupKeyboardObservers {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
}

- (void)keyboardWillShow:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    CGRect keyboardFrame = [userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect converted = [self.view convertRect:keyboardFrame fromView:nil];
    CGFloat overlap = self.view.bounds.size.height - converted.origin.y;
    if (overlap < 0) overlap = 0;
    self.inputBarBottomConstraint.constant = -overlap;
    // 输入框底部锚定 view.bottomAnchor，键盘弹起时底部安全区消失，直接抬升即可
    [self animateLayoutWithUserInfo:userInfo];
    [self scrollToBottomAnimated:YES];
}

- (void)keyboardWillHide:(NSNotification *)notification {
    self.inputBarBottomConstraint.constant = 0;
    [self animateLayoutWithUserInfo:notification.userInfo];
}

- (void)animateLayoutWithUserInfo:(NSDictionary *)userInfo {
    NSTimeInterval duration = [userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue] ?: 0.25;
    [UIView animateWithDuration:duration animations:^{
        [self.view layoutIfNeeded];
    }];
}

#pragma mark - 模型 / 提供商

- (AiProvider *)currentProvider {
    return [[AiProviderStore sharedStore] selectedProvider];
}

- (void)updateModelLabel {
    AiProvider *provider = [self currentProvider];
    if (provider && provider.name.length > 0) {
        NSString *model = provider.model.length > 0 ? provider.model : @"默认模型";
        self.inputBar.modelLabel.text = [NSString stringWithFormat:@"%@ / %@", provider.name, model];
        self.inputBar.modelLabel.textColor = [UIColor labelColor];
    } else {
        self.inputBar.modelLabel.text = @"未配置 AI 提供商";
        self.inputBar.modelLabel.textColor = [UIColor secondaryLabelColor];
    }
}

- (void)handleModelTap {
    // Phase 2：点击模型标签直接进入提供商配置页（切换/配置服务）
    [self presentProviderConfig];
}

- (void)showConfigureHint {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"尚未配置 AI 提供商"
                                                                    message:@"请在设置 → AI 助手 中配置 API 服务。"
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)configureAction {
    [self presentProviderConfig];
}

#pragma mark - 发送 / 停止

- (void)handleSend:(NSString *)text {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return;

    AiProvider *provider = [self currentProvider];
    if (!provider) {
        [self showConfigureHint];
        return;
    }

    [self.inputBar clearText];
    [self.inputBar setIsSending:YES];

    // 发送流程：AiAgent 会追加用户消息 + 助手占位消息并处理持久化
    __weak typeof(self) weakSelf = self;
    [[AiAgent sharedAgent] sendUserMessage:trimmed
                                   session:self.session
                                  provider:provider
                                  streaming:YES
                              chunkHandler:^(NSString *partial) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf updateStreamingCell];
    } completionHandler:^(NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        // 关键修复（发送消息崩溃）：completionHandler 同样来自后台队列，UI 更新须回主线程
        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf.inputBar setIsSending:NO];
            [strongSelf.activityIndicator stopAnimating];
            strongSelf.lastStreamUpdateTime = 0;
            if (error) {
                [strongSelf showErrorAlert:error];
            }
            [strongSelf reloadAndScrollToBottom];
            [strongSelf updateEmptyState];
        });
    }];

    // 关键修复（发送后用户消息不立即显示）：sendUserMessage 已同步把用户消息与助手占位
    // 追加进 session.messages，此刻再 reloadData 即可让用户消息立即显示；此前在调用前刷新，
    // 用户消息尚未加入，只有等首个 AI chunk 到来才显示。
    [self reloadAndScrollToBottom];
    // 首条消息发送后欢迎语立即消失：用户消息已同步加入 session.messages，立刻刷新空态。
    [self updateEmptyState];
}

/// 节流刷新正在流式生成的最后一条助手消息
- (void)updateStreamingCell {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if ((now - self.lastStreamUpdateTime) < kUIThrottleInterval) return;
    self.lastStreamUpdateTime = now;

    // 关键修复（发送消息崩溃）：chunkHandler 由 AiAPIClient 的后台 dispatch 队列回调，
    // 但 UITableView 只能在主线程更新。原实现直接在回调线程 reloadRows 导致 UIKit 断言崩溃。
    // 这里统一派发到主线程，且行数与数据源不一致时用 reloadData 同步（避免 reloadRows
    // 触发 "invalid update: invalid number of rows"）。
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = self;
        if (!strongSelf) return;

        NSInteger modelCount = strongSelf.session.messages.count;
        if (modelCount == 0) return;
        NSInteger tableCount = [strongSelf.tableView numberOfRowsInSection:0];

        // 从末尾向前找第一条 streaming==YES 的流式占位消息；找不到则整表刷新
        NSInteger streamingRow = NSNotFound;
        for (NSInteger i = modelCount - 1; i >= 0; i--) {
            AiMessage *m = strongSelf.session.messages[i];
            if (m.streaming) {
                streamingRow = i;
                break;
            }
        }

        if (streamingRow == NSNotFound) {
            // 没有流式占位行：整表刷新兜底
            [strongSelf.tableView reloadData];
        } else if (modelCount != tableCount) {
            // 数据源已新增行但表尚未同步：整表刷新让行数一致
            [strongSelf.tableView reloadData];
        } else {
            NSIndexPath *idx = [NSIndexPath indexPathForRow:streamingRow inSection:0];
            [strongSelf.tableView reloadRowsAtIndexPaths:@[idx] withRowAnimation:UITableViewRowAnimationNone];
        }
        [strongSelf scrollToBottomAnimated:NO];
    });
}

- (void)handleStop {
    [[AiAgent sharedAgent] stopCurrent];
    [self.inputBar setIsSending:NO];
    [self.activityIndicator stopAnimating];
    [self reloadAndScrollToBottom];
}

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.session.messages.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    AIMessageCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AIMessageCell" forIndexPath:indexPath];
    AiMessage *message = self.session.messages[indexPath.row];
    BOOL md = [[AiSettings sharedSettings] markdownEnabled];
    [cell configureWithMessage:message markdownEnabled:md];
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    AiMessage *message = self.session.messages[indexPath.row];
    BOOL md = [[AiSettings sharedSettings] markdownEnabled];
    return [AIMessageCell cellHeightForMessage:message width:tableView.bounds.size.width markdownEnabled:md];
}

#pragma mark - 空态

- (void)updateEmptyState {
    if (!self.emptyStateView) return;
    BOOL hasProvider = [self currentProvider] != nil;
    BOOL hasMessages = self.session.messages.count > 0;

    if (!hasProvider) {
        // 未配置提供商：无论是否已有消息都显示配置引导
        self.emptyStateView.hidden = NO;
        self.emptyIcon.image = [UIImage systemImageNamed:@"gearshape.2" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:56 weight:UIImageSymbolWeightRegular]];
        self.emptyTitle.text = @"尚未配置 AI 提供商";
        self.emptySubtitle.text = @"请到 设置 → AI 助手 配置 API 服务";
        self.configureButton.hidden = NO;
    } else if (!hasMessages) {
        self.emptyStateView.hidden = NO;
        self.emptyIcon.image = [UIImage systemImageNamed:@"sparkles" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:56 weight:UIImageSymbolWeightRegular]];
        self.emptyTitle.text = @"和 AI 助手打个招呼吧";
        self.emptySubtitle.text = @"向 Air 询问启动器问题或 Minecraft 知识";
        self.configureButton.hidden = YES;
    } else {
        self.emptyStateView.hidden = YES;
    }
}

#pragma mark - 辅助

- (void)reloadAndScrollToBottom {
    [self.tableView reloadData];
    [self scrollToBottomAnimated:YES];
}

- (void)scrollToBottomAnimated:(BOOL)animated {
    NSInteger rows = [self.tableView numberOfRowsInSection:0];
    if (rows == 0) return;
    NSIndexPath *ip = [NSIndexPath indexPathForRow:(rows - 1) inSection:0];
    [self.tableView scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionBottom animated:animated];
}

- (void)showErrorAlert:(NSError *)error {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"请求失败"
                                                                    message:error.localizedDescription ?: @"未知错误"
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end