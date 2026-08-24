//
//  ShadersManagerViewController.m
//  Amethyst
//
//  光影管理界面实现 —— 接入 ResourceListViewController / ResourceCardTableViewCell 基类
//

#import "ShadersManagerViewController.h"
#import "ResourceCardTableViewCell.h"
#import "ShaderService.h"
#import "ShaderItem.h"
#import "DownloadViewController.h"
#import "DownloadTaskManager.h"
#import "PLProfiles.h"
#import "utils.h"

#pragma mark - ShaderCardCell（光影卡片，Air-Design L2 标准卡片）

// 光影本地条目卡片：三层卡片背景/图标容器/文字层级均由基类提供。
// 图标用光影类型语义色（紫 paintbrush.fill，Air-Design 2.4）；
// 光影无启用开关（本界面只用于查看/删除），右侧不占 accessory 插槽。
@interface ShaderCardCell : ResourceCardTableViewCell
/// 配置本地光影条目：标题=显示名、副标题=文件名、元信息=大小或描述
- (void)configureWithShader:(ShaderItem *)shader;
@end

@implementation ShaderCardCell

- (void)configureWithShader:(ShaderItem *)shader {
    // 元信息：优先显示描述（本地扫描一般为空），否则显示文件大小
    NSString *detail = nil;
    if (shader.shaderDescription.length > 0) {
        detail = shader.shaderDescription;
    } else if (shader.filePath.length > 0) {
        unsigned long long fileSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:shader.filePath error:nil] fileSize];
        if (fileSize > 0) {
            // 文件大小统一用 File 计数风格（Air-Design 3.3）
            detail = [NSByteCountFormatter stringFromByteCount:fileSize countStyle:NSByteCountFormatterCountStyleFile];
        }
    }
    // 已禁用（.zip.disabled）时在元信息末尾追加标记
    if (shader.disabled) {
        detail = detail.length > 0 ? [NSString stringWithFormat:localize(@"resman.common.disabled_format", nil), detail] : localize(@"resman.common.disabled_tag", nil);
    }

    [self configureWithIcon:@"paintbrush.fill"
                  iconColor:[UIColor systemPurpleColor]
                      title:(shader.displayName ?: shader.fileName)
                   subtitle:shader.fileName
                     detail:detail];
}

@end

#pragma mark - ShadersManagerViewController

// 光影卡片行高（L2 卡片：三行文字 + 上下 8pt 内边距 + 余量）
static CGFloat const kShaderCardRowHeight = 76.0;
// 光影卡片 Cell 复用标识
static NSString * const kShaderCardCellIdentifier = @"ShaderCardCell";

@interface ShadersManagerViewController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate, UIDocumentPickerDelegate>

@property (nonatomic, strong) UIBarButtonItem *refreshButton;
@property (nonatomic, strong) UIBarButtonItem *importButton;
@property (nonatomic, strong) UIBarButtonItem *selectButtonItem;
@property (nonatomic, strong) UIBarButtonItem *doneButtonItem;
@property (nonatomic, strong) UIBarButtonItem *closeButtonItem;
/// 批量工具栏"删除选中"按钮（加入基类 batchActionStack）
@property (nonatomic, strong) UIButton *batchDeleteButton;

@property (nonatomic, strong) NSMutableArray<ShaderItem *> *localShaders;
@property (nonatomic, strong) NSMutableArray<ShaderItem *> *filteredLocalShaders;

/// 首次加载完成后是否已播放过连锁进场动画（仅首屏播放一次）
@property (nonatomic, assign) BOOL hasPlayedInitialChainAnimation;

@end

@implementation ShadersManagerViewController

- (instancetype)init {
    // 兼容既有调用方（[[ShadersManagerViewController alloc] init]）：
    // 转发到基类便利初始化，注入光影类型图标与语义色（Air-Design 2.4）
    return [self initWithTitle:localize(@"resman.shaders.title", nil) resourceTypeIcon:@"paintbrush.fill" iconColor:[UIColor systemPurpleColor]];
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad]; // 基类完成标题/毛玻璃背景/搜索栏/表格/三态视图/批量工具栏构建

    self.profileName = [PLProfiles effectiveProfileNameForPreferredName:self.profileName];

    // 始终使用本地模式（在线下载入口已移至下载界面）
    self.localShaders = [NSMutableArray array];
    self.filteredLocalShaders = [NSMutableArray array];

    // 搜索栏（基类已构建）：只搜本地
    self.searchBar.placeholder = localize(@"resman.shaders.search_placeholder", nil);
    self.searchBar.delegate = self;

    // 表格（基类已构建）：注册卡片 Cell；一节一卡 + 4pt 透明 header 形成卡片间距
    [self.tableView registerClass:[ShaderCardCell class] forCellReuseIdentifier:kShaderCardCellIdentifier];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = kShaderCardRowHeight;

    // 下拉刷新
    UIRefreshControl *refreshControl = [UIRefreshControl new];
    [refreshControl addTarget:self action:@selector(handleRefresh:) forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = refreshControl;

    [self setupNavigationButtons];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleDownloadTaskCompleted:)
                                                 name:DownloadTaskManagerTaskCompletedNotification
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshLocalShadersList];
}

#pragma mark - 导航栏

- (void)setupNavigationButtons {
    // 左侧：关闭（兼容 push / present 两种容器）
    self.closeButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closeTapped)];

    self.refreshButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(handleRefresh:)];

    UIImage *importImage = [UIImage systemImageNamed:@"square.and.arrow.down"] ?: [UIImage systemImageNamed:@"plus"];
    self.importButton = [[UIBarButtonItem alloc] initWithImage:importImage style:UIBarButtonItemStylePlain target:self action:@selector(importShaderTapped)];
    self.importButton.accessibilityLabel = localize(@"resman.shaders.import", nil);

    // "选择"按钮：进入基类批量选择模式（编辑勾选 + 底部工具栏）
    UIImage *selectImage = [UIImage systemImageNamed:@"checklist"] ?: [UIImage systemImageNamed:@"checkmark.circle"];
    self.selectButtonItem = [[UIBarButtonItem alloc] initWithImage:selectImage style:UIBarButtonItemStylePlain target:self action:@selector(toggleSelectMode)];
    self.selectButtonItem.accessibilityLabel = localize(@"resman.common.select", nil);

    self.doneButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(exitSelectMode)];
    self.doneButtonItem.accessibilityLabel = localize(@"resman.common.done", nil);

    [self updateNavigationButtons];
}

- (void)updateNavigationButtons {
    if (self.selectModeEnabled) {
        // 选择模式：右侧"完成"退出；标题实时显示已选数量
        self.navigationItem.leftBarButtonItem = nil;
        self.navigationItem.rightBarButtonItems = @[self.doneButtonItem];
        [self updateSelectModeTitle];
    } else {
        // 普通模式：左侧关闭，右侧依次（从右到左）为：导入、刷新、选择
        self.navigationItem.leftBarButtonItem = self.closeButtonItem;
        self.navigationItem.rightBarButtonItems = @[self.importButton, self.refreshButton, self.selectButtonItem];
        self.title = self.pageTitle;
        // 列表为空时禁用"选择"按钮
        self.selectButtonItem.enabled = self.filteredLocalShaders.count > 0;
    }
}

- (void)closeTapped {
    // 兼容两种容器：
    // - push 进 UINavigationController（卡片式布局/版本管理跳转）：pop 回上一级
    // - present 弹窗（旧调用路径）：dismiss
    if (self.navigationController && self.navigationController.viewControllers.firstObject != self) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

#pragma mark - 批量选择模式（基类工具栏）

- (void)toggleSelectMode {
    // 没有数据时不允许进入选择模式
    if (!self.selectModeEnabled && self.filteredLocalShaders.count == 0) return;
    [self setSelectMode:!self.selectModeEnabled];
}

- (void)exitSelectMode {
    [self setSelectMode:NO];
}

- (void)selectModeDidChange:(BOOL)enabled {
    // 基类钩子：切换时填充/清理 batchActionStack 中的批量操作按钮并刷新导航栏
    for (UIView *subview in [self.batchActionStack.arrangedSubviews copy]) {
        [self.batchActionStack removeArrangedSubview:subview];
        [subview removeFromSuperview];
    }
    if (enabled) {
        [self.batchActionStack addArrangedSubview:self.batchDeleteButton];
    }
    [self updateNavigationButtons];
}

- (void)selectionDidChange {
    // 基类钩子：全选/取消全选后同步"已选 N 个"标题
    [self updateSelectModeTitle];
}

- (UIButton *)batchDeleteButton {
    if (!_batchDeleteButton) {
        // 危险操作 pill：红底白字胶囊（高 32 / 圆角 16，Air-Design 7）
        _batchDeleteButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_batchDeleteButton setTitle:localize(@"resman.shaders.delete_selected", nil) forState:UIControlStateNormal];
        [_batchDeleteButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _batchDeleteButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _batchDeleteButton.backgroundColor = [UIColor systemRedColor];
        _batchDeleteButton.contentEdgeInsets = UIEdgeInsetsMake(6, 16, 6, 16);
        _batchDeleteButton.layer.cornerRadius = 16.0;
        _batchDeleteButton.layer.cornerCurve = kCACornerCurveContinuous;
        _batchDeleteButton.layer.masksToBounds = YES;
        [_batchDeleteButton addTarget:self action:@selector(deleteSelectedShaders) forControlEvents:UIControlEventTouchUpInside];
        [_batchDeleteButton.heightAnchor constraintEqualToConstant:32].active = YES;
    }
    return _batchDeleteButton;
}

- (void)updateSelectModeTitle {
    if (self.selectModeEnabled) {
        self.title = [NSString stringWithFormat:localize(@"resman.common.selected_count", nil), (long)self.selectedIndexPaths.count];
    }
}

// 删除选中的光影（带确认弹窗）
- (void)deleteSelectedShaders {
    // 一节一卡：indexPath.section 即列表行号
    NSMutableArray<ShaderItem *> *shadersToDelete = [NSMutableArray array];
    for (NSIndexPath *indexPath in self.selectedIndexPaths) {
        if (indexPath.section < (NSInteger)self.filteredLocalShaders.count) {
            [shadersToDelete addObject:self.filteredLocalShaders[indexPath.section]];
        }
    }
    if (shadersToDelete.count == 0) {
        [self showSimpleAlertWithTitle:localize(@"resman.common.notice", nil) message:localize(@"resman.shaders.none_selected", nil)];
        return;
    }

    NSString *message = [NSString stringWithFormat:localize(@"resman.shaders.batch_delete_message", nil), (long)shadersToDelete.count];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"resman.common.batch_delete", nil) message:message preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.delete", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self performDeleteShaders:shadersToDelete];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// 执行批量删除
- (void)performDeleteShaders:(NSArray<ShaderItem *> *)shadersToDelete {
    NSMutableArray<ShaderItem *> *failedShaders = [NSMutableArray array];

    for (ShaderItem *shader in shadersToDelete) {
        NSError *error = nil;
        BOOL success = [[ShaderService sharedService] deleteShader:shader error:&error];
        if (!success || error) {
            NSLog(@"[ShadersManager] Batch delete failed: %@ - %@", shader.displayName, error);
            [failedShaders addObject:shader];
        }
    }

    // 从数据源中移除已成功删除的光影
    for (ShaderItem *shader in shadersToDelete) {
        if ([failedShaders containsObject:shader]) continue; // 跳过删除失败的
        NSUInteger idxInFull = [self.localShaders indexOfObject:shader];
        if (idxInFull != NSNotFound) [self.localShaders removeObjectAtIndex:idxInFull];
        NSUInteger idxInFiltered = [self.filteredLocalShaders indexOfObject:shader];
        if (idxInFiltered != NSNotFound) [self.filteredLocalShaders removeObjectAtIndex:idxInFiltered];
    }

    if (failedShaders.count > 0) {
        // 部分失败时保留选择模式，提示用户哪些失败
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (ShaderItem *shader in failedShaders) [names addObject:shader.displayName];
        [self showSimpleAlertWithTitle:[NSString stringWithFormat:localize(@"resman.common.delete_complete_failures", nil), (long)failedShaders.count]
                               message:[names componentsJoinedByString:@"\n"]];
        [self.tableView reloadData]; // reloadData 会清空勾选状态
        [self updateEmptyState];
        [self updateNavigationButtons];
    } else {
        // 全部删除成功，退出选择模式并刷新列表/空状态
        [self setSelectMode:NO];
        [self filterLocalShaders];
    }
}

#pragma mark - 导入光影

- (void)importShaderTapped {
    NSError *dirError = nil;
    NSString *shadersDir = [[ShaderService sharedService] ensureShadersFolderForProfile:nil error:&dirError];
    if (!shadersDir) {
        [self showSimpleAlertWithTitle:localize(@"resman.common.cannot_import", nil) message:dirError.localizedDescription ?: localize(@"resman.shaders.dir_not_found", nil)];
        return;
    }

    // 光影包通常是 zip 格式
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.zip-archive", @"public.item"] inMode:UIDocumentPickerModeImport];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    picker.title = localize(@"resman.shaders.picker_title", nil);
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;

    NSError *dirError = nil;
    NSString *shadersDir = [[ShaderService sharedService] ensureShadersFolderForProfile:nil error:&dirError];
    if (!shadersDir) {
        [self showSimpleAlertWithTitle:localize(@"resman.common.import_failed", nil) message:dirError.localizedDescription ?: localize(@"resman.shaders.dir_not_found", nil)];
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSInteger successCount = 0;
    NSMutableArray<NSString *> *failedFiles = [NSMutableArray array];

    for (NSURL *url in urls) {
        BOOL accessing = [url startAccessingSecurityScopedResource];
        @try {
            NSString *fileName = url.lastPathComponent;
            NSString *destPath = [shadersDir stringByAppendingPathComponent:fileName];

            if ([fm fileExistsAtPath:destPath]) {
                NSString *baseName = [fileName stringByDeletingPathExtension];
                NSString *ext = [fileName pathExtension];
                destPath = [shadersDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_copy.%@", baseName, ext]];
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

    [self refreshLocalShadersList];

    if (failedFiles.count > 0) {
        [self showSimpleAlertWithTitle:[NSString stringWithFormat:localize(@"resman.common.import_result", nil), (long)successCount, (long)failedFiles.count]
                               message:[failedFiles componentsJoinedByString:@"\n"]];
    } else {
        NSLog(@"[ShadersManager] Successfully imported %ld shader packs", (long)successCount);
    }
}

#pragma mark - 数据加载与三态

- (void)handleRefresh:(id)sender {
    // 刷新前若处于选择模式，先退出（数据即将更新，避免选择状态与新数据不一致）
    if (self.selectModeEnabled) {
        [self setSelectMode:NO];
    }
    [self refreshLocalShadersList];
}

- (void)setLoading:(BOOL)loading {
    // 加载中隐藏空状态，避免与中央转圈重叠（转圈由基类提供）
    if (loading) [self hideEmptyState];
    [super setLoading:loading];
}

- (void)refreshLocalShadersList {
    [self setLoading:YES];
    NSString *profile = self.profileName ?: @"default";
    [[ShaderService sharedService] scanShadersForProfile:profile completion:^(NSArray<ShaderItem *> *shaders) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.localShaders removeAllObjects];
            [self.localShaders addObjectsFromArray:shaders];
            [self filterLocalShaders];
            [self setLoading:NO];
            [self.tableView.refreshControl endRefreshing];

            // 首次加载完成：播放连锁进场动画（首屏 ≤10 项，每项延迟 50ms 滑入）
            if (!self.hasPlayedInitialChainAnimation) {
                self.hasPlayedInitialChainAnimation = YES;
                [self.tableView layoutIfNeeded]; // 先完成布局，visibleCells 才是新的一批
                [self animateCellsInChain];
            }
        });
    }];
}

- (void)updateEmptyState {
    if (self.filteredLocalShaders.count > 0) {
        [self hideEmptyState];
        return;
    }
    if (self.localShaders.count == 0) {
        // 目录为空：引导去统一下载界面获取光影
        __weak typeof(self) weakSelf = self;
        [self showEmptyStateWithIcon:@"paintbrush.fill"
                           iconColor:[UIColor systemPurpleColor]
                             message:localize(@"resman.shaders.empty", nil)
                        actionTitle:localize(@"resman.common.go_download", nil)
                      actionHandler:^{
                          [weakSelf openDownloadPage];
                      }];
    } else {
        // 仅搜索无结果：无引导按钮
        [self showEmptyStateWithIcon:nil iconColor:nil message:localize(@"resman.shaders.search_empty", nil) actionTitle:nil actionHandler:nil];
    }
}

- (void)openDownloadPage {
    // 跳转统一下载界面并定位到光影 tab（在线下载入口已统一收口到下载页）
    DownloadViewController *downloadVC = [[DownloadViewController alloc] init];
    downloadVC.initialTabIndex = 2; // 0版本 1模组 2光影
    downloadVC.targetProfileName = self.profileName;
    if (self.navigationController) {
        [self.navigationController pushViewController:downloadVC animated:YES];
    } else {
        // 兼容 present 弹窗容器（无导航栈时全屏模态）
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:downloadVC];
        nav.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:nav animated:YES completion:nil];
    }
}

- (void)handleDownloadTaskCompleted:(NSNotification *)notification {
    DownloadTaskItem *task = notification.userInfo[DownloadTaskManagerTaskKey];
    if (task.state != DownloadTaskStateCompleted ||
        ![task.resourceType isEqualToString:DownloadTaskResourceTypeShader] ||
        ![task.userInfo[@"profileName"] isEqualToString:self.profileName]) return;
    [self refreshLocalShadersList];
}

#pragma mark - 搜索（UISearchBarDelegate）

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self filterLocalShaders];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = @"";
    [searchBar resignFirstResponder];
    [self filterLocalShaders];
}

- (void)filterLocalShaders {
    [self.filteredLocalShaders removeAllObjects];
    if (self.searchBar.text.length == 0) {
        [self.filteredLocalShaders addObjectsFromArray:self.localShaders];
    } else {
        NSString *searchText = [self.searchBar.text lowercaseString];
        for (ShaderItem *shader in self.localShaders) {
            if ([shader.displayName.lowercaseString containsString:searchText] ||
                [shader.fileName.lowercaseString containsString:searchText]) {
                [self.filteredLocalShaders addObject:shader];
            }
        }
    }
    // 更新空状态与导航按钮状态（"选择"按钮的可用性等）
    [self updateEmptyState];
    [self updateNavigationButtons];
    [self.tableView reloadData];
}

#pragma mark - UITableView DataSource & Delegate

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    // 一节一卡：section 即列表行，节间 4pt 透明 header 形成卡片间距
    return self.filteredLocalShaders.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ShaderCardCell *cell = [tableView dequeueReusableCellWithIdentifier:kShaderCardCellIdentifier forIndexPath:indexPath];
    [cell configureWithShader:self.filteredLocalShaders[indexPath.section]];
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return ResourceListCardSpacing;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return [ResourceListViewController cardSpacingHeaderView];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    // 批量选择模式：多选勾选样式（圆形勾选圈由系统提供，不显示删除按钮）
    return UITableViewCellEditingStyleNone;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    // 选择模式下禁用滑动删除，避免误操作
    if (self.selectModeEnabled) return nil;

    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:localize(@"resman.common.delete", nil) handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {

        ShaderItem *shaderToDelete = self.filteredLocalShaders[indexPath.section];

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"resman.common.confirm_delete", nil) message:[NSString stringWithFormat:localize(@"resman.common.delete_message_irreversible", nil), shaderToDelete.displayName] preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            completionHandler(NO);
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.delete", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            NSError *error = nil;
            [[ShaderService sharedService] deleteShader:shaderToDelete error:&error];

            if (error) {
                NSLog(@"[ShadersManager] Error deleting shader: %@", error);
                completionHandler(NO);
            } else {
                // 一节一卡：删除对应 section（indexPath.section 可能因前序删除过期，按对象重新定位）
                NSUInteger idxInFull = [self.localShaders indexOfObject:shaderToDelete];
                if (idxInFull != NSNotFound) [self.localShaders removeObjectAtIndex:idxInFull];
                NSUInteger idxInFiltered = [self.filteredLocalShaders indexOfObject:shaderToDelete];
                if (idxInFiltered != NSNotFound) {
                    [self.filteredLocalShaders removeObjectAtIndex:idxInFiltered];
                    [tableView deleteSections:[NSIndexSet indexSetWithIndex:idxInFiltered] withRowAnimation:UITableViewRowAnimationAutomatic];
                } else {
                    [self.tableView reloadData];
                }
                [self updateEmptyState];
                [self updateNavigationButtons];
                completionHandler(YES);
            }
        }]];

        [self presentViewController:alert animated:YES completion:nil];
    }];

    deleteAction.backgroundColor = [UIColor systemRedColor];

    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
    configuration.performsFirstActionWithFullSwipe = YES;

    return configuration;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.selectModeEnabled) {
        // 选择模式：编辑多选勾选由系统处理，这里同步"已选 N 个"标题
        [self updateSelectModeTitle];
    } else {
        // 普通模式：点击无动作，仅取消高亮
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
    }
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.selectModeEnabled) {
        [self updateSelectModeTitle];
    }
}

#pragma mark - Helpers

- (void)showSimpleAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.ok", nil) style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
