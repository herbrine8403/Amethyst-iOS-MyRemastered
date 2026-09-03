//
//  WorldsManagerViewController.m
//  Amethyst
//
//  世界存档管理视图控制器实现（继承 ResourceListViewController 基类）
//  使用 WorldService 进行本地扫描与删除（含健壮解压导入）
//  在线下载入口已移至统一下载界面：空状态提供"去下载"引导按钮
//

#import "WorldsManagerViewController.h"
#import "WorldService.h"
#import "WorldItem.h"
#import "ResourceCardTableViewCell.h"
#import "DownloadViewController.h"
#import "DownloadTaskManager.h"
#import "PLProfiles.h"
#import "utils.h"

#pragma mark - 世界卡片 Cell（继承 Air-Design 卡片基类，本文件内轻量子类）

@interface WorldCardCell : ResourceCardTableViewCell
@end

@implementation WorldCardCell

- (void)configureWithWorld:(WorldItem *)item {
    NSString *title = item.worldName.length > 0 ? item.worldName : item.displayName;
    // 副标题：最后游玩时间
    NSString *subtitle = item.lastPlayed.length > 0 ? [NSString stringWithFormat:localize(@"resman.worlds.last_played", nil), item.lastPlayed] : nil;
    // 元信息：世界大小
    NSString *detail = nil;
    if (item.worldSize) {
        unsigned long long bytes = [item.worldSize unsignedLongValue];
        if (bytes >= 1024 * 1024) {
            detail = [NSString stringWithFormat:@"%.1f MB", bytes / (1024.0 * 1024.0)];
        } else if (bytes >= 1024) {
            detail = [NSString stringWithFormat:@"%.1f KB", bytes / 1024.0];
        } else {
            detail = [NSString stringWithFormat:@"%llu B", bytes];
        }
    }

    [self configureWithIcon:@"globe.asia.australia.fill"
                  iconColor:[UIColor systemGreenColor]
                      title:title
                   subtitle:subtitle
                     detail:detail];
    // 世界暂无详情页：不显示 chevron / 开关
}

@end

#pragma mark - 视图控制器

@interface WorldsManagerViewController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate, UIDocumentPickerDelegate>

@property (nonatomic, strong) UIBarButtonItem *refreshButton;
@property (nonatomic, strong) UIBarButtonItem *importButton;

@property (nonatomic, strong) NSMutableArray<WorldItem *> *localItems;
@property (nonatomic, strong) NSMutableArray<WorldItem *> *filteredLocalItems;

// 首屏连锁进场动画只播一次
@property (nonatomic, assign) BOOL didPlayChainAnimation;

@end

@implementation WorldsManagerViewController

#pragma mark - Init

- (instancetype)init {
    // 接入资源列表基类：标题 + 世界类型语义色图标（绿 / globe.asia.australia.fill）
    // 兼容既有调用方 [[WorldsManagerViewController alloc] init] 的创建方式
    return [super initWithTitle:localize(@"resman.worlds.title", nil) resourceTypeIcon:@"globe.asia.australia.fill" iconColor:[UIColor systemGreenColor]];
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.profileName = [PLProfiles effectiveProfileNameForPreferredName:self.profileName];
    // 在线下载入口已移至下载界面：固定本地模式（currentMode 等属性保留仅为兼容 .h 既有声明）
    self.currentMode = WorldsManagerModeLocal;
    self.localItems = [NSMutableArray array];
    self.filteredLocalItems = [NSMutableArray array];
    self.onlineSearchResults = [NSMutableArray array];

    // 搜索栏（基类构建）：只搜本地
    self.searchBar.delegate = self;
    self.searchBar.placeholder = localize(@"resman.worlds.search_placeholder", nil);

    // 列表（基类构建）：注册卡片 Cell + 下拉刷新
    [self.tableView registerClass:[WorldCardCell class] forCellReuseIdentifier:@"WorldCardCell"];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 84;

    UIRefreshControl *rc = [UIRefreshControl new];
    [rc addTarget:self action:@selector(handleRefresh:) forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = rc;

    // 导航按钮：左侧关闭，右侧导入 + 刷新
    UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closeTapped)];
    self.refreshButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(handleRefresh:)];
    UIImage *importImage = [UIImage systemImageNamed:@"square.and.arrow.down"] ?: [UIImage systemImageNamed:@"plus"];
    self.importButton = [[UIBarButtonItem alloc] initWithImage:importImage style:UIBarButtonItemStylePlain target:self action:@selector(importTapped)];
    self.importButton.accessibilityLabel = localize(@"resman.worlds.import", nil);
    self.navigationItem.leftBarButtonItem = closeButton;
    self.navigationItem.rightBarButtonItems = @[self.importButton, self.refreshButton];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleDownloadTaskCompleted:)
                                                 name:DownloadTaskManagerTaskCompletedNotification
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshLocalList];
}

#pragma mark - 关闭

- (void)closeTapped {
    // 兼容两种容器：
    // - push 进 UINavigationController（ProfileSettingsViewController 跳转）：pop 回上一级
    // - present 弹窗（旧调用路径）：dismiss
    if (self.navigationController && self.navigationController.viewControllers.firstObject != self) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

#pragma mark - 导入世界 zip

- (void)importTapped {
    NSError *dirError = nil;
    NSString *dir = [[WorldService sharedService] ensureWorldsFolderForProfile:self.profileName error:&dirError];
    if (!dir) {
        [self showSimpleAlertWithTitle:localize(@"resman.common.cannot_import", nil) message:dirError.localizedDescription ?: localize(@"resman.worlds.dir_not_found", nil)];
        return;
    }

    // 仅允许选择 zip 文件
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.zip", @"public.item"] inMode:UIDocumentPickerModeImport];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    picker.title = localize(@"resman.worlds.picker_title", nil);
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;

    // 第一个文件先导入，后续文件依次排队（每次导入都需要解压，避免并发冲突）
    [self importNextURLFromQueue:[urls mutableCopy] index:0];
}

- (void)importNextURLFromQueue:(NSMutableArray<NSURL *> *)queue index:(NSInteger)index {
    if (index >= (NSInteger)queue.count) {
        // 全部导入完成，刷新列表
        [self refreshLocalList];
        return;
    }

    NSURL *url = queue[index];
    __weak typeof(self) weakSelf = self;

    // 显示导入中提示
    UIAlertController *importingAlert = [UIAlertController alertControllerWithTitle:localize(@"resman.worlds.importing", nil)
                                                                             message:[NSString stringWithFormat:@"%@ (%ld/%ld)...", url.lastPathComponent, (long)(index + 1), (long)queue.count]
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    indicator.translatesAutoresizingMaskIntoConstraints = NO;
    [importingAlert.view addSubview:indicator];
    [NSLayoutConstraint activateConstraints:@[
        [indicator.centerXAnchor constraintEqualToAnchor:importingAlert.view.centerXAnchor],
        [indicator.centerYAnchor constraintEqualToAnchor:importingAlert.view.centerYAnchor constant:20]
    ]];
    [indicator startAnimating];
    [self presentViewController:importingAlert animated:YES completion:nil];

    [[WorldService sharedService] importWorldFromURL:url
                                              toProfile:self.profileName
                                               progress:nil
                                             completion:^(BOOL success, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [importingAlert dismissViewControllerAnimated:YES completion:^{
                if (!success || error) {
                    [weakSelf showSimpleAlertWithTitle:localize(@"resman.common.import_failed", nil)
                                                message:[NSString stringWithFormat:@"%@: %@", url.lastPathComponent, error.localizedDescription ?: localize(@"resman.common.unknown_error", nil)]];
                }
                // 继续处理下一个文件
                [weakSelf importNextURLFromQueue:queue index:index + 1];
            }];
        });
    }];
}

#pragma mark - 数据加载

- (void)handleRefresh:(id)sender {
    [self refreshLocalList];
}

/// 基类刷新钩子：下载完成通知 / viewWillAppear 时重载世界列表。
/// 关键修复（下载成功后资源管理页不刷新）：文件落盘后自动刷新页面。
- (void)reloadResourceList {
    [self refreshLocalList];
}

- (void)refreshLocalList {
    [self setLoading:YES];
    NSString *profile = self.profileName ?: @"default";
    [[WorldService sharedService] scanWorldsForProfile:profile completion:^(NSArray<WorldItem *> *items) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.localItems removeAllObjects];
            [self.localItems addObjectsFromArray:items];
            [self filterLocalItems];
            [self setLoading:NO];
            [self.tableView.refreshControl endRefreshing];
            // 首屏连锁进场动画（Air-Design 15.3）：只播一次
            if (!self.didPlayChainAnimation && self.filteredLocalItems.count > 0) {
                self.didPlayChainAnimation = YES;
                [self animateCellsInChain];
            }
        });
    }];
}

#pragma mark - 搜索与空状态

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self filterLocalItems];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = @"";
    [searchBar resignFirstResponder];
    [self filterLocalItems];
}

- (void)filterLocalItems {
    [self.filteredLocalItems removeAllObjects];
    if (self.searchBar.text.length == 0) {
        [self.filteredLocalItems addObjectsFromArray:self.localItems];
    } else {
        NSString *searchText = [self.searchBar.text lowercaseString];
        for (WorldItem *item in self.localItems) {
            if ([item.worldName.lowercaseString containsString:searchText] ||
                [item.displayName.lowercaseString containsString:searchText]) {
                [self.filteredLocalItems addObject:item];
            }
        }
    }
    [self.tableView reloadData];
    [self updateEmptyState];
}

- (void)updateEmptyState {
    if (self.filteredLocalItems.count > 0) {
        [self hideEmptyState];
        return;
    }
    if (self.localItems.count == 0) {
        // 目录为空：类型图标 + "去下载"引导（跳转统一下载界面）
        [self showEmptyStateWithIcon:nil
                           iconColor:nil
                             message:localize(@"resman.worlds.empty", nil)
                        actionTitle:localize(@"resman.common.go_download", nil)
                      actionHandler:^{
                          [self openDownloadPage];
                      }];
    } else {
        // 搜索无结果：不放引导按钮
        [self showEmptyStateWithIcon:@"magnifyingglass"
                           iconColor:[UIColor secondaryLabelColor]
                             message:localize(@"resman.worlds.search_empty", nil)
                        actionTitle:nil
                      actionHandler:nil];
    }
}

#pragma mark - 跳转统一下载界面

- (void)openDownloadPage {
    // 在线下载入口已收敛到统一下载界面（未区分资源类型 Tab，进入默认页）
    DownloadViewController *downloadVC = [[DownloadViewController alloc] init];
    downloadVC.initialTabIndex = 6;
    // 关键修复（目标实例不一致）：传入本管理页绑定的 profileName
    downloadVC.targetProfileName = self.profileName;
    if (self.navigationController) {
        [self.navigationController pushViewController:downloadVC animated:YES];
    } else {
        // 无导航栈（旧 present 路径）时全屏弹出
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:downloadVC];
        nav.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:nav animated:YES completion:nil];
    }
}

- (void)handleDownloadTaskCompleted:(NSNotification *)notification {
    DownloadTaskItem *task = notification.userInfo[DownloadTaskManagerTaskKey];
    if (task.state != DownloadTaskStateCompleted ||
        ![task.resourceType isEqualToString:DownloadTaskResourceTypeWorld] ||
        ![task.userInfo[@"profileName"] isEqualToString:self.profileName]) return;
    [self refreshLocalList];
}

#pragma mark - UITableView DataSource & Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredLocalItems.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    WorldCardCell *cell = [tableView dequeueReusableCellWithIdentifier:@"WorldCardCell" forIndexPath:indexPath];
    WorldItem *item = self.filteredLocalItems[indexPath.row];
    [cell configureWithWorld:item];
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    // 卡片间距（Air-Design space-sm）：顶部留白 + 卡片之间留白
    return ResourceListCardSpacing;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return [ResourceListViewController cardSpacingHeaderView];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    __weak typeof(self) weakSelf = self;
    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:localize(@"resman.common.delete", nil) handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
        WorldItem *item = weakSelf.filteredLocalItems[indexPath.row];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"resman.common.confirm_delete", nil)
                                                                        message:[NSString stringWithFormat:localize(@"resman.worlds.delete_message", nil), item.worldName ?: item.displayName]
                                                                 preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            completionHandler(NO);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.delete", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            NSError *error = nil;
            if (![[WorldService sharedService] deleteWorld:item error:&error]) {
                [weakSelf showSimpleAlertWithTitle:localize(@"resman.common.delete_failed", nil) message:error.localizedDescription];
                completionHandler(NO);
                return;
            }
            NSInteger indexInFull = [weakSelf.localItems indexOfObject:item];
            if (indexInFull != NSNotFound) {
                [weakSelf.localItems removeObjectAtIndex:indexInFull];
            }
            [weakSelf.filteredLocalItems removeObjectAtIndex:indexPath.row];
            [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
            completionHandler(YES);
        }]];
        [weakSelf presentViewController:alert animated:YES completion:nil];
    }];
    deleteAction.backgroundColor = [UIColor systemRedColor];

    return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
}

#pragma mark - 工具方法

- (void)showSimpleAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.ok", nil) style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
