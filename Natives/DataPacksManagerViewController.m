//
//  DataPacksManagerViewController.m
//  Amethyst
//
//  数据包管理视图控制器实现（继承 ResourceListViewController 基类）
//  使用 DataPackService 进行本地扫描、启用/禁用与删除
//  在线下载入口已移至统一下载界面：空状态提供"去下载"引导按钮
//  提示：iOS 上无法选择世界，数据包位于 <gameDir>/datapacks/，需手动移动到 saves/<世界名>/datapacks/
//

#import "DataPacksManagerViewController.h"
#import "DataPackService.h"
#import "DataPackItem.h"
#import "ResourceCardTableViewCell.h"
#import "DownloadViewController.h"
#import "DownloadTaskManager.h"
#import "PLProfiles.h"
#import "utils.h"

#pragma mark - 数据包卡片 Cell（继承 Air-Design 卡片基类，本文件内轻量子类）

@interface DataPackCardCell : ResourceCardTableViewCell
/// 启用/禁用开关回调（VC 在 cellForRow 中设置，参数为触发开关的 cell）
@property (nonatomic, copy, nullable) void (^toggleHandler)(DataPackCardCell *cell);
@end

@implementation DataPackCardCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        // 开关事件统一挂在 cell 自身（只挂一次），避免复用时重复 addTarget
        [self.toggleSwitch addTarget:self action:@selector(internalSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    }
    return self;
}

- (void)internalSwitchChanged:(UISwitch *)sender {
    if (self.toggleHandler) self.toggleHandler(self);
}

- (void)configureWithDataPack:(DataPackItem *)item {
    NSString *title = item.displayName.length > 0 ? item.displayName : item.fileName;
    // 副标题：pack_format（无则回退文件名）
    NSString *subtitle = item.packFormat ? [NSString stringWithFormat:localize(@"resman.common.pack_format", nil), item.packFormat] : item.fileName;
    // 元信息：数据包描述
    NSString *detail = item.dataPackDescription.length > 0 ? item.dataPackDescription : nil;

    [self configureWithIcon:@"doc.text.fill"
                  iconColor:[UIColor systemTealColor]
                      title:title
                   subtitle:subtitle
                     detail:detail];

    // 启用/禁用开关（.disabled 后缀切换）
    self.toggleSwitch.hidden = NO;
    [self.toggleSwitch setOn:!item.disabled animated:NO];
    self.contentView.alpha = item.disabled ? 0.5 : 1.0;
}

@end

#pragma mark - 视图控制器

@interface DataPacksManagerViewController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate, UIDocumentPickerDelegate>

@property (nonatomic, strong) UIBarButtonItem *refreshButton;
@property (nonatomic, strong) UIBarButtonItem *importButton;

@property (nonatomic, strong) NSMutableArray<DataPackItem *> *localItems;
@property (nonatomic, strong) NSMutableArray<DataPackItem *> *filteredLocalItems;

// 顶部提示横幅（saves/<世界名>/datapacks/ 说明），作为 tableHeaderView 展示
@property (nonatomic, strong) UIView *tipHeaderView;
@property (nonatomic, assign) CGFloat lastTipHeaderWidth;

// 首屏连锁进场动画只播一次
@property (nonatomic, assign) BOOL didPlayChainAnimation;

@end

@implementation DataPacksManagerViewController

#pragma mark - Init

- (instancetype)init {
    // 接入资源列表基类：标题 + 数据包类型语义色图标（teal / doc.text.fill）
    // 兼容既有调用方 [[DataPacksManagerViewController alloc] init] 的创建方式
    return [super initWithTitle:localize(@"resman.datapacks.title", nil) resourceTypeIcon:@"doc.text.fill" iconColor:[UIColor systemTealColor]];
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.profileName = [PLProfiles effectiveProfileNameForPreferredName:self.profileName];
    // 在线下载入口已移至下载界面：固定本地模式（currentMode 等属性保留仅为兼容 .h 既有声明）
    self.currentMode = DataPacksManagerModeLocal;
    self.localItems = [NSMutableArray array];
    self.filteredLocalItems = [NSMutableArray array];
    self.onlineSearchResults = [NSMutableArray array];

    // 搜索栏（基类构建）：只搜本地
    self.searchBar.delegate = self;
    self.searchBar.placeholder = localize(@"resman.datapacks.search_placeholder", nil);

    // 列表（基类构建）：注册卡片 Cell + 下拉刷新
    [self.tableView registerClass:[DataPackCardCell class] forCellReuseIdentifier:@"DataPackCardCell"];
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
    self.importButton.accessibilityLabel = localize(@"resman.datapacks.import", nil);
    self.navigationItem.leftBarButtonItem = closeButton;
    self.navigationItem.rightBarButtonItems = @[self.importButton, self.refreshButton];

    // 顶部提示横幅（保留既有提示文案）
    [self setupTipHeaderView];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleDownloadTaskCompleted:)
                                                 name:DownloadTaskManagerTaskCompletedNotification
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshLocalList];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // tableView 宽度确定/变化（首次布局、旋转）时重算提示横幅高度
    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    if (width > 0 && fabs(width - self.lastTipHeaderWidth) > 0.5) {
        self.lastTipHeaderWidth = width;
        [self fitTipHeaderToWidth:width];
    }
}

#pragma mark - 顶部提示横幅

- (void)setupTipHeaderView {
    // 数据包目录说明横幅：轻量卡片样式（半透明基底 + 0.5pt 描边 + 10pt 圆角）
    UIView *container = [[UIView alloc] init];
    container.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.06];
    container.layer.cornerRadius = 10.0;
    container.layer.cornerCurve = kCACornerCurveContinuous;
    container.layer.borderWidth = 0.5;
    container.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    container.clipsToBounds = YES;

    UILabel *tipLabel = [[UILabel alloc] init];
    tipLabel.translatesAutoresizingMaskIntoConstraints = NO;
    tipLabel.font = [UIFont systemFontOfSize:11];
    tipLabel.textColor = [UIColor systemOrangeColor];
    tipLabel.textAlignment = NSTextAlignmentCenter;
    tipLabel.numberOfLines = 0;
    tipLabel.text = localize(@"resman.datapacks.tip", nil);
    [container addSubview:tipLabel];
    [NSLayoutConstraint activateConstraints:@[
        [tipLabel.topAnchor constraintEqualToAnchor:container.topAnchor constant:8],
        [tipLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:10],
        [tipLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-10],
        [tipLabel.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8],
    ]];
    self.tipHeaderView = container;
}

- (void)fitTipHeaderToWidth:(CGFloat)width {
    if (width <= 0 || !self.tipHeaderView) return;
    // 临时宽度约束用于自适应计算高度，算完即移除
    NSLayoutConstraint *widthConstraint = [self.tipHeaderView.widthAnchor constraintEqualToConstant:width];
    widthConstraint.active = YES;
    CGSize size = [self.tipHeaderView systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
    widthConstraint.active = NO;
    CGRect frame = CGRectMake(0, 0, width, ceil(size.height));
    if (!CGRectEqualToRect(self.tipHeaderView.frame, frame)) {
        self.tipHeaderView.frame = frame;
        self.tableView.tableHeaderView = self.tipHeaderView;
    }
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

#pragma mark - 导入数据包

- (void)importTapped {
    NSError *dirError = nil;
    NSString *dir = [[DataPackService sharedService] ensureDataPacksFolderForProfile:self.profileName error:&dirError];
    if (!dir) {
        [self showSimpleAlertWithTitle:localize(@"resman.common.cannot_import", nil) message:dirError.localizedDescription ?: localize(@"resman.datapacks.dir_not_found", nil)];
        return;
    }

    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.zip", @"public.item"] inMode:UIDocumentPickerModeImport];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    picker.title = localize(@"resman.datapacks.picker_title", nil);
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;

    NSError *dirError = nil;
    NSString *dir = [[DataPackService sharedService] ensureDataPacksFolderForProfile:self.profileName error:&dirError];
    if (!dir) {
        [self showSimpleAlertWithTitle:localize(@"resman.common.import_failed", nil) message:dirError.localizedDescription ?: localize(@"resman.datapacks.dir_not_found", nil)];
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSInteger successCount = 0;
    NSMutableArray<NSString *> *failedFiles = [NSMutableArray array];

    for (NSURL *url in urls) {
        BOOL accessing = [url startAccessingSecurityScopedResource];
        @try {
            NSString *fileName = url.lastPathComponent;
            NSString *destPath = [dir stringByAppendingPathComponent:fileName];
            if ([fm fileExistsAtPath:destPath]) {
                NSString *baseName = [fileName stringByDeletingPathExtension];
                NSString *ext = [fileName pathExtension];
                destPath = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_copy.%@", baseName, ext]];
            }
            NSError *copyError = nil;
            [fm copyItemAtPath:url.path toPath:destPath error:&copyError];
            if (copyError) {
                [failedFiles addObject:[NSString stringWithFormat:@"%@: %@", fileName, copyError.localizedDescription]];
            } else {
                successCount++;
            }
        } @finally {
            if (accessing) [url stopAccessingSecurityScopedResource];
        }
    }

    [self refreshLocalList];

    if (failedFiles.count > 0) {
        [self showSimpleAlertWithTitle:[NSString stringWithFormat:localize(@"resman.common.import_result", nil), (long)successCount, (long)failedFiles.count]
                               message:[failedFiles componentsJoinedByString:@"\n"]];
    }
}

#pragma mark - 数据加载

- (void)handleRefresh:(id)sender {
    [self refreshLocalList];
}

- (void)refreshLocalList {
    [self setLoading:YES];
    NSString *profile = self.profileName ?: @"default";
    [[DataPackService sharedService] scanDataPacksForProfile:profile completion:^(NSArray<DataPackItem *> *items) {
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
        for (DataPackItem *item in self.localItems) {
            if ([item.displayName.lowercaseString containsString:searchText] ||
                [item.fileName.lowercaseString containsString:searchText]) {
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
                             message:localize(@"resman.datapacks.empty", nil)
                        actionTitle:localize(@"resman.common.go_download", nil)
                      actionHandler:^{
                          [self openDownloadPage];
                      }];
    } else {
        // 搜索无结果：不放引导按钮
        [self showEmptyStateWithIcon:@"magnifyingglass"
                           iconColor:[UIColor secondaryLabelColor]
                             message:localize(@"resman.datapacks.search_empty", nil)
                        actionTitle:nil
                      actionHandler:nil];
    }
}

#pragma mark - 跳转统一下载界面

- (void)openDownloadPage {
    // 在线下载入口已收敛到统一下载界面（未区分资源类型 Tab，进入默认页）
    DownloadViewController *downloadVC = [[DownloadViewController alloc] init];
    downloadVC.initialTabIndex = 4;
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
        ![task.resourceType isEqualToString:DownloadTaskResourceTypeDataPack] ||
        ![task.userInfo[@"profileName"] isEqualToString:self.profileName]) return;
    [self refreshLocalList];
}

#pragma mark - UITableView DataSource & Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredLocalItems.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    DataPackCardCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DataPackCardCell" forIndexPath:indexPath];
    DataPackItem *item = self.filteredLocalItems[indexPath.row];
    __weak typeof(self) weakSelf = self;
    cell.toggleHandler = ^(DataPackCardCell *toggleCell) {
        [weakSelf handleToggleOnCell:toggleCell];
    };
    [cell configureWithDataPack:item];
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
        DataPackItem *item = weakSelf.filteredLocalItems[indexPath.row];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"resman.common.confirm_delete", nil)
                                                                        message:[NSString stringWithFormat:localize(@"resman.common.delete_message", nil), item.displayName ?: item.fileName]
                                                                 preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            completionHandler(NO);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.delete", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            NSError *error = nil;
            if (![[DataPackService sharedService] deleteDataPack:item error:&error]) {
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

#pragma mark - 本地启用/禁用切换

- (void)handleToggleOnCell:(DataPackCardCell *)cell {
    NSIndexPath *indexPath = [self.tableView indexPathForCell:cell];
    if (!indexPath || indexPath.row >= (NSInteger)self.filteredLocalItems.count) return;
    DataPackItem *item = self.filteredLocalItems[indexPath.row];
    NSError *error = nil;
    if (![[DataPackService sharedService] toggleEnableForDataPack:item error:&error]) {
        // 失败时恢复开关状态
        [cell.toggleSwitch setOn:!cell.toggleSwitch.on animated:NO];
        [self showSimpleAlertWithTitle:localize(@"resman.common.operation_failed", nil) message:error.localizedDescription];
    } else {
        // 禁用态半透明提示
        cell.contentView.alpha = item.disabled ? 0.5 : 1.0;
    }
}

#pragma mark - 工具方法

- (void)showSimpleAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.ok", nil) style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
