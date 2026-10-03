//
//  AISessionListViewController.m
//  Amethyst
//
//  AI 会话列表页实现：UITableView + UISearchController。
//

#import "AISessionListViewController.h"
#import "AiSessionStore.h"
#import "BackgroundManager.h"
#import "LauncherPreferences.h"

@interface AISessionListViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UILabel *emptyLabel;
/// 当前要展示的会话（搜索时过滤，否则为全部；内部按置顶优先 + 更新时间倒序）
@property (nonatomic, strong) NSMutableArray<AiSession *> *displayedSessions;

@end

@implementation AISessionListViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"会话列表";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.backgroundColor = [[UIColor labelColor] colorWithAlphaComponent:0.04];
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // 左上角「新建会话」按钮
    UIBarButtonItem *newItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus"]
                                                                style:UIBarButtonItemStylePlain
                                                               target:self
                                                               action:@selector(newSessionAction)];
    self.navigationItem.leftBarButtonItem = newItem;

    // ★ [LAND-BUG] 本页除「从 AI 会话内 push」外，还会被 LauncherMenuViewController.showAI
    //   以 UIModalPresentationFullScreen 模态整页弹出；FullScreen 模态不支持下滑关闭，
    //   而本页原先只有左上「+」、没有任何返回/关闭入口 ⇒ 进入后「退不出去」。
    //   关闭按钮在 viewWillAppear 里按“是否模态呈现”补上（push 进入时保持用导航返回键），
    //   见下方 viewWillAppear: / landBugCloseTapped。

    [self setupTable];
    [self setupSearch];
    [self setupEmptyState];

    [self reloadDisplayedSessions];
}

#pragma mark - ★ [LAND-BUG] 模态呈现时的关闭入口

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 模态整页弹出时（nav 是 presented 的那个），补一个右上「关闭」；
    // push 进入时 presentingViewController 为 nil，不注入，避免覆盖导航返回键。
    UINavigationController *nav = self.navigationController;
    if (nav.presentingViewController != nil && nav.viewControllers.firstObject == self &&
        self.navigationItem.rightBarButtonItem == nil) {
        UIBarButtonItem *close = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                              target:self
                                                                              action:@selector(landBugCloseTapped)];
        close.accessibilityLabel = @"关闭";
        self.navigationItem.rightBarButtonItem = close;
    }
}

- (void)landBugCloseTapped {
    UINavigationController *nav = self.navigationController;
    if (nav.presentingViewController) {
        [nav dismissViewControllerAnimated:YES completion:nil];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

#pragma mark - 布局

- (void)setupTable {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.estimatedRowHeight = 88;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.contentInset = UIEdgeInsetsMake(8, 0, 40, 0);
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"AiSessionCell"];
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)setupSearch {
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.hidesNavigationBarDuringPresentation = NO;
    self.navigationItem.searchController = self.searchController;
    // 适配全局背景：透明搜索框，文字随系统
    self.searchController.searchBar.barTintColor = [UIColor clearColor];
    self.searchController.searchBar.tintColor = accentColor();
    self.searchController.searchBar.backgroundImage = [UIImage new];
    if (@available(iOS 13.0, *)) {
        self.searchController.searchBar.searchTextField.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    }
    self.definesPresentationContext = YES;
}

- (void)setupEmptyState {
    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.numberOfLines = 0;
    [self.view addSubview:self.emptyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.emptyLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:32],
        [self.emptyLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-32],
    ]];
}

#pragma mark - 数据源处理

/// 重排：置顶会话优先，其余按 updatedAt 倒序（最新在前）
- (void)reloadDisplayedSessions {
    NSString *query = self.searchController.active ? self.searchController.searchBar.text : @"";
    NSArray<AiSession *> *base = [[AiSessionStore sharedStore] sessionsMatchingQuery:query ?: @""];

    self.displayedSessions = [NSMutableArray array];
    NSMutableArray *pinned = [NSMutableArray array];
    NSMutableArray *normal = [NSMutableArray array];
    for (AiSession *session in base) {
        if (session.pinned) {
            [pinned addObject:session];
        } else {
            [normal addObject:session];
        }
    }
    [self.displayedSessions addObjectsFromArray:pinned];
    [self.displayedSessions addObjectsFromArray:normal];

    [self.tableView reloadData];
    [self updateEmptyState];
}

- (void)updateEmptyState {
    if (!self.emptyLabel) return;
    BOOL hasAny = [AiSessionStore sharedStore].sessions.count > 0;
    BOOL searching = self.searchController.active && self.searchController.searchBar.text.length > 0;

    if (self.displayedSessions.count == 0) {
        self.emptyLabel.hidden = NO;
        if (!hasAny) {
            self.emptyLabel.text = @"还没有会话，点左上角 + 新建";
        } else if (searching) {
            self.emptyLabel.text = @"没有匹配的会话";
        } else {
            self.emptyLabel.text = @"还没有会话";
        }
    } else {
        self.emptyLabel.hidden = YES;
    }
}

#pragma mark - 新建 / 删除

- (void)newSessionAction {
    AiSession *session = [[AiSessionStore sharedStore] newSession];
    if (self.onNewSession) {
        self.onNewSession(session);
    } else {
        [self reloadDisplayedSessions];
    }
}

- (void)deleteSession:(AiSession *)session {
    [[AiSessionStore sharedStore] deleteSession:session];
    [self reloadDisplayedSessions];
}

#pragma mark - 相对时间

/// 简单相对时间：刚刚 / X 分钟前 / X 小时前 / X 天前 / 日期
- (NSString *)relativeTimeString:(NSDate *)date {
    if (!date) return @"";
    NSTimeInterval interval = -[date timeIntervalSinceNow];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    if (interval < 60) {
        return @"刚刚";
    } else if (interval < 3600) {
        return [NSString stringWithFormat:@"%ld 分钟前", (long)(interval / 60)];
    } else if (interval < 86400) {
        return [NSString stringWithFormat:@"%ld 小时前", (long)(interval / 3600)];
    } else if (interval < 7 * 86400) {
        return [NSString stringWithFormat:@"%ld 天前", (long)(interval / 86400)];
    }
    formatter.dateFormat = @"MM-dd";
    return [formatter stringFromDate:date];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.displayedSessions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AiSessionCell" forIndexPath:indexPath];
    AiSession *session = self.displayedSessions[indexPath.row];

    // 清空复用残留
    for (UIView *sub in cell.contentView.subviews) {
        [sub removeFromSuperview];
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];

    // 卡片容器
    UIView *cardView = [[UIView alloc] init];
    cardView.translatesAutoresizingMaskIntoConstraints = NO;
    cardView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    cardView.layer.cornerRadius = 16;
    cardView.layer.cornerCurve = kCACornerCurveContinuous;
    cardView.layer.borderWidth = 0.5;
    cardView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    cardView.layer.shadowColor = [UIColor blackColor].CGColor;
    cardView.layer.shadowOffset = CGSizeMake(0, 2);
    cardView.layer.shadowOpacity = 0.10;
    cardView.layer.shadowRadius = 6;
    [[BackgroundManager sharedManager] applyEffectToView:cardView];
    [cell.contentView addSubview:cardView];

    // 会话图标
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.image = [UIImage systemImageNamed:@"bubble.left.and.bubble.right.fill"];
    iconView.tintColor = [UIColor whiteColor];
    iconView.contentMode = UIViewContentModeCenter;
    iconView.backgroundColor = accentColor();
    iconView.layer.cornerRadius = 12;
    iconView.layer.cornerCurve = kCACornerCurveContinuous;
    iconView.layer.masksToBounds = YES;
    [cardView addSubview:iconView];

    // 标题
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = session.title.length > 0 ? session.title : @"新会话";
    titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor labelColor];
    titleLabel.numberOfLines = 1;
    titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [cardView addSubview:titleLabel];

    // 副标题：消息数 + 更新时间
    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.text = [NSString stringWithFormat:@"%lu 条消息 · %@",
                          (unsigned long)session.messages.count,
                          [self relativeTimeString:session.updatedAt]];
    subtitleLabel.font = [UIFont systemFontOfSize:12];
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.numberOfLines = 1;
    subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [cardView addSubview:subtitleLabel];

    // 置顶图标
    UIImageView *pinView = [[UIImageView alloc] init];
    pinView.translatesAutoresizingMaskIntoConstraints = NO;
    pinView.image = [UIImage systemImageNamed:@"pin.fill"];
    pinView.tintColor = accentColor();
    pinView.contentMode = UIViewContentModeScaleAspectFit;
    pinView.hidden = !session.pinned;
    [cardView addSubview:pinView];

    [NSLayoutConstraint activateConstraints:@[
        [cardView.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:6],
        [cardView.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [cardView.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [cardView.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-6],

        [iconView.leadingAnchor constraintEqualToAnchor:cardView.leadingAnchor constant:14],
        [iconView.centerYAnchor constraintEqualToAnchor:cardView.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:42],
        [iconView.heightAnchor constraintEqualToConstant:42],

        [titleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:14],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:pinView.leadingAnchor constant:-8],
        [titleLabel.topAnchor constraintEqualToAnchor:cardView.topAnchor constant:16],

        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor],
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:4],
        [subtitleLabel.bottomAnchor constraintEqualToAnchor:cardView.bottomAnchor constant:-16],

        [pinView.trailingAnchor constraintEqualToAnchor:cardView.trailingAnchor constant:-14],
        [pinView.centerYAnchor constraintEqualToAnchor:cardView.centerYAnchor],
        [pinView.widthAnchor constraintEqualToConstant:16],
        [pinView.heightAnchor constraintEqualToConstant:16],
    ]];

    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (NSArray<UITableViewRowAction *> *)tableView:(UITableView *)tableView editActionsForRowAtIndexPath:(NSIndexPath *)indexPath {
    __weak typeof(self) weakSelf = self;
    UITableViewRowAction *deleteAction = [UITableViewRowAction rowActionWithStyle:UITableViewRowActionStyleDestructive
                                                                           title:@"删除"
                                                                         handler:^(UITableViewRowAction * _Nonnull action, NSIndexPath * _Nonnull ip) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        AiSession *session = strongSelf.displayedSessions[ip.row];
        [strongSelf deleteSession:session];
    }];
    return @[deleteAction];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleDelete;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    AiSession *session = self.displayedSessions[indexPath.row];
    if (self.onSelectSession) {
        self.onSelectSession(session);
    }
}

#pragma mark - UISearchResultsUpdating

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self reloadDisplayedSessions];
}

@end