//
//  ModsManagerViewController.m
//  Amethyst
//
//  Mod 管理页实现（继承 ResourceListViewController）。
//  参照 ZL2 ModsManagerScreen 模式：顶栏"检查更新"内置更新流程
//  （并发检测 → 确认弹窗 → 并发下载到临时目录 → 删旧移新 → 刷新 + 徽章）。
//

#import "ModsManagerViewController.h"
#import "ModTableViewCell.h"
#import "ModService.h"
#import "ModItem.h"
#import "ModUpdateService.h"
#import "ModVersion.h"
#import "PLDownloadClient.h"
#import "PLMirrorCenter.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "DownloadViewController.h"
#import "DownloadTaskManager.h"
#import "utils.h"
#import <CommonCrypto/CommonDigest.h>

#pragma mark - 内部模型与枚举

/// 更新下载任务（检查命中后的一次待更新项）
@interface ModUpdateTask : NSObject
/// 更新检查结果（含本地文件路径与候选版本）
@property (nonatomic, strong) ModUpdateResult *result;
/// 对应的本地 ModItem（用于名称显示与文件替换）
@property (nonatomic, strong) ModItem *mod;
/// 目标版本（candidateVersions 首个，即最新候选）
@property (nonatomic, strong) ModVersion *targetVersion;
/// 下载完成后的临时文件路径（下载成功时非空）
@property (nonatomic, copy) NSString *tempPath;
/// 下载是否成功
@property (nonatomic, assign) BOOL downloadSucceeded;
@end

@implementation ModUpdateTask
@end

/// 状态筛选模式
typedef NS_ENUM(NSInteger, ModsFilterMode) {
    ModsFilterModeAll = 0,
    ModsFilterModeEnabled,
    ModsFilterModeDisabled,
};

/// 排序模式
typedef NS_ENUM(NSInteger, ModsSortMode) {
    ModsSortModeName = 0,
    ModsSortModeModifiedDate,
};

#pragma mark - 工具函数

/// 流式计算文件 SHA1（CommonCrypto 分块，支持大文件），失败返回 nil
static NSString *ModsManagerSHA1ForFile(NSString *path) {
    if (path.length == 0) return nil;
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return nil;
    CC_SHA1_CTX ctx;
    CC_SHA1_Init(&ctx);
    @try {
        while (YES) {
            @autoreleasepool {
                NSData *chunk = [handle readDataOfLength:1 << 16];
                if (chunk.length == 0) break;
                CC_SHA1_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
            }
        }
    } @catch (NSException *exception) {
        [handle closeFile];
        return nil;
    }
    [handle closeFile];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

#pragma mark - 类扩展

@interface ModsManagerViewController () <UITableViewDataSource, UITableViewDelegate, ModTableViewCellDelegate, UISearchBarDelegate, UIDocumentPickerDelegate>

// ===== 数据 =====
@property (nonatomic, strong) NSMutableArray<ModItem *> *localMods;       // 全量本地 Mod
@property (nonatomic, strong) NSMutableArray<ModItem *> *filteredLocalMods; // 搜索 + 筛选 + 排序后
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *modDates; // filePath → 文件修改时间（排序用）

// ===== 筛选 / 排序 =====
@property (nonatomic, assign) ModsFilterMode filterMode;
@property (nonatomic, assign) ModsSortMode sortMode;
@property (nonatomic, strong) UIScrollView *chipsScrollView;   // chips 水平滚动容器
@property (nonatomic, strong) UIStackView *chipsStack;         // chips 排列
@property (nonatomic, strong) NSArray<UIButton *> *filterChips;
@property (nonatomic, strong) UIButton *sortChipButton;

// ===== 导航按钮 =====
@property (nonatomic, strong) UIBarButtonItem *closeButtonItem;
@property (nonatomic, strong) UIBarButtonItem *refreshButton;
@property (nonatomic, strong) UIBarButtonItem *checkUpdateButton;
@property (nonatomic, strong) UIBarButtonItem *importButton;
@property (nonatomic, strong) UIBarButtonItem *selectButtonItem;
@property (nonatomic, strong) UIBarButtonItem *doneButtonItem;
@property (nonatomic, strong) UIBarButtonItem *navSpinnerItem;
@property (nonatomic, strong) UIActivityIndicatorView *navSpinner;

// ===== 批量操作按钮（batchActionStack 内容）=====
@property (nonatomic, strong) UIButton *batchEnableButton;
@property (nonatomic, strong) UIButton *batchDisableButton;
@property (nonatomic, strong) UIButton *batchDeleteButton;

// ===== 更新流程状态 =====
/// 更新流程是否进行中（检查中 / 下载替换中均为 YES，期间按钮禁用防重复触发）
@property (nonatomic, assign) BOOL isUpdateBusy;
/// 更新流程的阶段提示文本（显示在导航标题位置）
@property (nonatomic, copy) NSString *updateBusyText;
/// 检查更新命中（可更新）的结果：filePath → result，用于 Cell 徽章
@property (nonatomic, strong) NSMutableDictionary<NSString *, ModUpdateResult *> *updateResultsByPath;

// ===== 其他 =====
@property (nonatomic, assign) BOOL hasPlayedInitialAnimation; // 首次加载连锁动画只播一次

@end

@implementation ModsManagerViewController

#pragma mark - Init

- (instancetype)init {
    // 兼容现有调用点 [[ModsManagerViewController alloc] init]：
    // 转调基类便利初始化（标题 + Mod 语义色 puzzlepiece.fill / systemOrange）
    return [self initWithTitle:localize(@"resman.mods.title", nil)
              resourceTypeIcon:@"puzzlepiece.fill"
                      iconColor:[UIColor systemOrangeColor]];
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad]; // 基类构建背景/搜索栏/表格/空态/加载态/批量工具栏

    self.profileName = [PLProfiles effectiveProfileNameForPreferredName:self.profileName];

    self.localMods = [NSMutableArray array];
    self.filteredLocalMods = [NSMutableArray array];
    self.modDates = [NSMutableDictionary dictionary];
    self.updateResultsByPath = [NSMutableDictionary dictionary];

    // 搜索栏
    self.searchBar.delegate = self;
    self.searchBar.placeholder = localize(@"resman.mods.search_placeholder", nil);

    [self setupNavigationButtons];
    [self setupChipsRow];
    [self setupTableViewExtras];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleDownloadTaskCompleted:)
                                                 name:DownloadTaskManagerTaskCompletedNotification
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadMods];
}

#pragma mark - 导航按钮

- (void)setupNavigationButtons {
    self.closeButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                         target:self
                                                                         action:@selector(closeTapped)];
    self.closeButtonItem.accessibilityLabel = localize(@"resman.common.close", nil);

    self.refreshButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                       target:self
                                                                       action:@selector(handleRefresh:)];
    self.refreshButton.accessibilityLabel = localize(@"resman.common.refresh", nil);

    UIImage *checkImage = [UIImage systemImageNamed:@"arrow.triangle.2.circlepath"];
    self.checkUpdateButton = [[UIBarButtonItem alloc] initWithImage:checkImage
                                                              style:UIBarButtonItemStylePlain
                                                             target:self
                                                             action:@selector(checkForUpdates)];
    self.checkUpdateButton.accessibilityLabel = localize(@"resman.mods.check_update", nil);

    UIImage *importImage = [UIImage systemImageNamed:@"square.and.arrow.down"] ?: [UIImage systemImageNamed:@"plus"];
    self.importButton = [[UIBarButtonItem alloc] initWithImage:importImage
                                                         style:UIBarButtonItemStylePlain
                                                        target:self
                                                        action:@selector(importModTapped)];
    self.importButton.accessibilityLabel = localize(@"resman.mods.import", nil);

    UIImage *selectImage = [UIImage systemImageNamed:@"checklist"] ?: [UIImage systemImageNamed:@"checkmark.circle"];
    self.selectButtonItem = [[UIBarButtonItem alloc] initWithImage:selectImage
                                                             style:UIBarButtonItemStylePlain
                                                            target:self
                                                            action:@selector(enterSelectMode)];
    self.selectButtonItem.accessibilityLabel = localize(@"resman.common.select", nil);

    self.doneButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                        target:self
                                                                        action:@selector(exitSelectMode)];
    self.doneButtonItem.accessibilityLabel = localize(@"resman.common.done", nil);

    // 更新流程忙态的导航栏转圈指示
    self.navSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.navSpinner.hidesWhenStopped = YES;
    self.navSpinnerItem = [[UIBarButtonItem alloc] initWithCustomView:self.navSpinner];

    [self updateNavigationButtons];
}

/// 按当前状态（普通 / 选择模式 / 更新忙态）刷新导航栏按钮与标题
- (void)updateNavigationButtons {
    if (self.selectModeEnabled) {
        self.navigationItem.leftBarButtonItem = self.closeButtonItem;
        self.navigationItem.rightBarButtonItems = @[self.doneButtonItem];
        [self updateSelectModeTitle];
    } else if (self.isUpdateBusy) {
        // 更新流程进行中：仅显示转圈指示，禁用其余操作防止重复触发
        self.navigationItem.leftBarButtonItem = self.closeButtonItem;
        self.navigationItem.rightBarButtonItems = @[self.navSpinnerItem];
        [self.navSpinner startAnimating];
        self.navigationItem.title = self.updateBusyText ?: localize(@"resman.mods.processing", nil);
    } else {
        self.navigationItem.leftBarButtonItem = self.closeButtonItem;
        // 从右到左：导入、刷新、检查更新、选择
        self.navigationItem.rightBarButtonItems = @[self.importButton, self.refreshButton, self.checkUpdateButton, self.selectButtonItem];
        self.navigationItem.title = self.pageTitle;
    }
}

/// 选择模式标题：显示已选数量
- (void)updateSelectModeTitle {
    if (self.selectModeEnabled) {
        self.navigationItem.title = [NSString stringWithFormat:localize(@"resman.common.selected_count", nil), (long)self.selectedIndexPaths.count];
    }
}

- (void)closeTapped {
    // 兼容两种容器：push 进导航栈 → pop；present 弹窗 → dismiss
    if (self.navigationController && self.navigationController.viewControllers.firstObject != self) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)handleRefresh:(id)sender {
    // 刷新前退出选择模式，避免选择状态与新数据不一致
    if (self.selectModeEnabled) {
        [self setSelectMode:NO];
    }
    [self loadMods];
}

#pragma mark - 筛选 chips 行（搜索栏下方）

- (void)setupChipsRow {
    // 基类默认把 tableView 顶部锚到 searchBar 底部；插入 chips 行需要先停用该约束
    for (NSLayoutConstraint *constraint in [self.view.constraints copy]) {
        if (constraint.firstItem == self.tableView && constraint.secondItem == self.searchBar
            && constraint.firstAttribute == NSLayoutAttributeTop) {
            constraint.active = NO;
            break;
        }
    }

    // 水平滚动 chips 容器
    self.chipsScrollView = [[UIScrollView alloc] init];
    self.chipsScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.chipsScrollView.showsHorizontalScrollIndicator = NO;
    self.chipsScrollView.alwaysBounceHorizontal = NO;
    [self.view addSubview:self.chipsScrollView];

    self.chipsStack = [[UIStackView alloc] init];
    self.chipsStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.chipsStack.axis = UILayoutConstraintAxisHorizontal;
    self.chipsStack.alignment = UIStackViewAlignmentCenter;
    self.chipsStack.spacing = 8.0;
    [self.chipsScrollView addSubview:self.chipsStack];

    // 三个筛选 chip：全部 / 已启用 / 已禁用
    NSMutableArray<UIButton *> *chips = [NSMutableArray array];
    NSArray<NSString *> *titles = @[localize(@"resman.mods.filter.all", nil),
                                    localize(@"resman.mods.filter.enabled", nil),
                                    localize(@"resman.mods.filter.disabled", nil)];
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *chip = [self makeChipButtonWithTitle:titles[i]];
        chip.tag = i;
        [chip addTarget:self action:@selector(filterChipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.chipsStack addArrangedSubview:chip];
        [chips addObject:chip];
    }
    self.filterChips = chips;

    // 行尾排序按钮：名称 / 修改时间 切换
    self.sortChipButton = [self makeChipButtonWithTitle:localize(@"resman.mods.sort.name", nil)];
    [self.sortChipButton setImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"]
                  forState:UIControlStateNormal];
    self.sortChipButton.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight; // 图标在左
    [self.sortChipButton addTarget:self action:@selector(sortChipTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.chipsStack addArrangedSubview:self.sortChipButton];

    [NSLayoutConstraint activateConstraints:@[
        // chips 行：紧贴搜索栏下方，tableView 改为锚到 chips 行底部
        [self.chipsScrollView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:2],
        [self.chipsScrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:ResourceListCardSideInset],
        [self.chipsScrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-ResourceListCardSideInset],
        [self.chipsScrollView.heightAnchor constraintEqualToConstant:34],

        [self.chipsStack.topAnchor constraintEqualToAnchor:self.chipsScrollView.topAnchor],
        [self.chipsStack.bottomAnchor constraintEqualToAnchor:self.chipsScrollView.bottomAnchor],
        [self.chipsStack.leadingAnchor constraintEqualToAnchor:self.chipsScrollView.contentLayoutGuide.leadingAnchor],
        [self.chipsStack.trailingAnchor constraintEqualToAnchor:self.chipsScrollView.contentLayoutGuide.trailingAnchor],
        [self.chipsStack.centerYAnchor constraintEqualToAnchor:self.chipsScrollView.centerYAnchor],

        [self.tableView.topAnchor constraintEqualToAnchor:self.chipsScrollView.bottomAnchor constant:2],
    ]];

    [self refreshChipStyles];
}

/// 创建胶囊 chip 按钮（选中 = accent 底白字；未选中 = 半透明底 labelColor 文字）
- (UIButton *)makeChipButtonWithTitle:(NSString *)title {
    UIButton *chip = [UIButton buttonWithType:UIButtonTypeSystem];
    chip.translatesAutoresizingMaskIntoConstraints = NO;
    [chip setTitle:title forState:UIControlStateNormal];
    chip.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    chip.contentEdgeInsets = UIEdgeInsetsMake(5, 14, 5, 14);
    chip.layer.cornerRadius = 14.0;
    chip.layer.cornerCurve = kCACornerCurveContinuous;
    chip.layer.masksToBounds = YES;
    [chip.heightAnchor constraintEqualToConstant:28].active = YES;
    [chip setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [chip setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return chip;
}

/// 应用选中 / 未选中样式
- (void)applyChipStyle:(UIButton *)chip selected:(BOOL)selected {
    if (selected) {
        chip.backgroundColor = accentColor();
        [chip setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        chip.tintColor = [UIColor whiteColor];
        chip.layer.borderWidth = 0;
    } else {
        chip.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
        [chip setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        chip.tintColor = [UIColor labelColor];
        chip.layer.borderWidth = 0.5;
        chip.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15].CGColor;
    }
}

/// 刷新全部 chip 样式（按当前筛选 / 排序状态）
- (void)refreshChipStyles {
    for (NSUInteger i = 0; i < self.filterChips.count; i++) {
        [self applyChipStyle:self.filterChips[i] selected:((NSInteger)i == self.filterMode)];
    }
    [self applyChipStyle:self.sortChipButton selected:YES]; // 排序按钮常为选中样式（当前生效的排序）
    NSString *sortTitle = (self.sortMode == ModsSortModeName) ? localize(@"resman.mods.sort.name", nil)
                                                              : localize(@"resman.mods.sort.modified", nil);
    [self.sortChipButton setTitle:sortTitle forState:UIControlStateNormal];
}

- (void)filterChipTapped:(UIButton *)sender {
    self.filterMode = (ModsFilterMode)sender.tag;
    [self refreshChipStyles];
    [self applyFilter];
}

- (void)sortChipTapped {
    self.sortMode = (self.sortMode == ModsSortModeName) ? ModsSortModeModifiedDate : ModsSortModeName;
    [self refreshChipStyles];
    [self applyFilter];
}

#pragma mark - TableView 补充配置

- (void)setupTableViewExtras {
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.tableView registerClass:[ModTableViewCell class] forCellReuseIdentifier:@"ModCell"];
    self.tableView.rowHeight = 68.0;
}

#pragma mark - Data Loading

/// 基类刷新钩子：下载完成通知 / viewWillAppear 时重载 Mod 列表。
/// 关键修复（下载成功后资源管理页不刷新）：文件落盘后自动刷新页面。
- (void)reloadResourceList {
    [self loadMods];
}

- (void)loadMods {
    [self setLoading:YES];
    NSString *profile = self.profileName ?: @"default";
    __weak typeof(self) weakSelf = self;
    [[ModService sharedService] scanModsForProfile:profile completion:^(NSArray<ModItem *> *mods) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.localMods removeAllObjects];
            [strongSelf.localMods addObjectsFromArray:mods];
            [strongSelf cacheModificationDates];
            [strongSelf applyFilter];
            [strongSelf setLoading:NO];
            // 首次加载播放连锁进场动画（Air-Design 15.3）
            if (!strongSelf.hasPlayedInitialAnimation && strongSelf.localMods.count > 0) {
                strongSelf.hasPlayedInitialAnimation = YES;
                [strongSelf animateCellsInChain];
            }
        });
    }];
}

/// 缓存各 Mod 文件修改时间（排序用，避免比较器内反复 IO）
- (void)cacheModificationDates {
    [self.modDates removeAllObjects];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (ModItem *mod in self.localMods) {
        if (mod.filePath.length == 0) continue;
        NSDate *date = [[fm attributesOfItemAtPath:mod.filePath error:nil] fileModificationDate];
        if (date) self.modDates[mod.filePath] = date;
    }
}

/// 搜索 + 状态筛选 + 排序 → filteredLocalMods + 空态刷新
- (void)applyFilter {
    NSString *query = [self.searchBar.text lowercaseString];
    NSMutableArray<ModItem *> *result = [NSMutableArray array];
    for (ModItem *mod in self.localMods) {
        // 状态筛选
        if (self.filterMode == ModsFilterModeEnabled && mod.disabled) continue;
        if (self.filterMode == ModsFilterModeDisabled && !mod.disabled) continue;
        // 搜索过滤
        if (query.length > 0) {
            NSString *name = mod.displayName.lowercaseString ?: @"";
            NSString *file = mod.fileName.lowercaseString ?: @"";
            if (![name containsString:query] && ![file containsString:query]) continue;
        }
        [result addObject:mod];
    }

    // 排序
    if (self.sortMode == ModsSortModeName) {
        [result sortUsingComparator:^NSComparisonResult(ModItem *_Nonnull a, ModItem *_Nonnull b) {
            NSString *nameA = a.displayName ?: a.fileName;
            NSString *nameB = b.displayName ?: b.fileName;
            return [nameA localizedCaseInsensitiveCompare:nameB];
        }];
    } else {
        // 修改时间降序（最新改动的在前，无时间的排后）
        [result sortUsingComparator:^NSComparisonResult(ModItem *_Nonnull a, ModItem *_Nonnull b) {
            NSDate *dateA = self.modDates[a.filePath];
            NSDate *dateB = self.modDates[b.filePath];
            if (!dateA && !dateB) return NSOrderedSame;
            if (!dateA) return NSOrderedDescending;
            if (!dateB) return NSOrderedAscending;
            return [dateB compare:dateA];
        }];
    }

    [self.filteredLocalMods removeAllObjects];
    [self.filteredLocalMods addObjectsFromArray:result];

    // 空态
    if (result.count == 0) {
        if (self.localMods.count == 0) {
            __weak typeof(self) weakSelf = self;
            [self showEmptyStateWithIcon:nil
                               iconColor:nil
                                 message:localize(@"resman.mods.empty", nil)
                            actionTitle:localize(@"resman.common.go_download", nil)
                          actionHandler:^{
                [weakSelf openDownloadPage];
            }];
        } else {
            [self showEmptyStateWithIcon:@"magnifyingglass"
                               iconColor:[UIColor secondaryLabelColor]
                                 message:localize(@"resman.mods.search_empty", nil)
                            actionTitle:nil
                          actionHandler:nil];
        }
    } else {
        [self hideEmptyState];
    }

    // "选择"按钮可用性
    self.selectButtonItem.enabled = (result.count > 0);

    [self.tableView reloadData];
}

/// 空状态"去下载"：跳转统一下载页（无参数化资源类型入口，进入默认页）
- (void)openDownloadPage {
    DownloadViewController *vc = [[DownloadViewController alloc] init];
    vc.initialTabIndex = 1;
    // 关键修复（目标实例不一致）：传入本管理页绑定的 profileName，
    // 保证下载写入的实例与当前打开的实例一致
    vc.targetProfileName = self.profileName;
    if (self.navigationController) {
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:nav animated:YES completion:nil];
    }
}

- (void)handleDownloadTaskCompleted:(NSNotification *)notification {
    DownloadTaskItem *task = notification.userInfo[DownloadTaskManagerTaskKey];
    if (task.state != DownloadTaskStateCompleted ||
        ![task.resourceType isEqualToString:DownloadTaskResourceTypeMod] ||
        ![task.userInfo[@"profileName"] isEqualToString:self.profileName]) return;
    [self loadMods];
}

#pragma mark - UISearchBarDelegate

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self applyFilter];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

#pragma mark - UITableViewDataSource & Delegate

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredLocalMods.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ModTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ModCell" forIndexPath:indexPath];
    cell.delegate = self;

    ModItem *mod = self.filteredLocalMods[indexPath.row];
    [cell configureWithMod:mod displayMode:ModTableViewCellDisplayModeLocal];

    // 更新徽章：检测命中（可更新）的 Mod 显示 arrow.up.circle.fill
    [cell setUpdateAvailable:(self.updateResultsByPath[mod.filePath] != nil)];

    // 选择模式下隐藏启用开关（避免与勾选视觉冲突），普通模式恢复
    cell.toggleSwitch.hidden = self.selectModeEnabled;

    return cell;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return [ResourceListViewController cardSpacingHeaderView];
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return ResourceListCardSpacing;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.selectModeEnabled) {
        // 编辑（勾选）模式：行点击切换勾选，更新标题计数
        [self updateSelectModeTitle];
    } else {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
    }
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.selectModeEnabled) {
        [self updateSelectModeTitle];
    }
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    // 选择模式下禁用滑动删除，避免误操作
    if (self.selectModeEnabled) return nil;

    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                               title:localize(@"resman.common.delete", nil)
                                                                             handler:^(UIContextualAction *_Nonnull action, __kindof UIView *_Nonnull sourceView, void (^_Nonnull completionHandler)(BOOL)) {
        ModItem *modToDelete = self.filteredLocalMods[indexPath.row];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"resman.common.confirm_delete", nil)
                                                                       message:[NSString stringWithFormat:localize(@"resman.common.delete_message_irreversible", nil), modToDelete.displayName]
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction *_Nonnull a) {
            completionHandler(NO);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.delete", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_Nonnull a) {
            NSError *error = nil;
            [[ModService sharedService] deleteMod:modToDelete error:&error];
            if (error) {
                NSLog(@"[ModsManager] Error deleting mod: %@", error);
                completionHandler(NO);
            } else {
                // 同步数据源并删除行
                NSUInteger idxFull = [self.localMods indexOfObject:modToDelete];
                if (idxFull != NSNotFound) [self.localMods removeObjectAtIndex:idxFull];
                [self.modDates removeObjectForKey:modToDelete.filePath];
                [self.updateResultsByPath removeObjectForKey:modToDelete.filePath];
                [self.filteredLocalMods removeObjectAtIndex:indexPath.row];
                [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
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

#pragma mark - 批量选择模式（基类工具栏整合）

- (void)enterSelectMode {
    if (self.filteredLocalMods.count == 0) return;
    [self setSelectMode:YES]; // 基类处理编辑模式 + 工具栏滑入 + selectModeDidChange:
}

- (void)exitSelectMode {
    [self setSelectMode:NO];
}

- (void)selectModeDidChange:(BOOL)enabled {
    if (enabled) {
        // 填充批量操作按钮（首次懒创建，之后保持在 stack 中随工具栏显隐）
        if (!self.batchEnableButton) {
            self.batchEnableButton = [self makeBatchActionButtonWithTitle:localize(@"resman.common.enable", nil) tintColor:[UIColor systemGreenColor]];
            [self.batchEnableButton addTarget:self action:@selector(batchEnableTapped) forControlEvents:UIControlEventTouchUpInside];

            self.batchDisableButton = [self makeBatchActionButtonWithTitle:localize(@"resman.common.disable", nil) tintColor:[UIColor systemOrangeColor]];
            [self.batchDisableButton addTarget:self action:@selector(batchDisableTapped) forControlEvents:UIControlEventTouchUpInside];

            self.batchDeleteButton = [self makeBatchActionButtonWithTitle:localize(@"resman.common.delete", nil) tintColor:[UIColor systemRedColor]];
            [self.batchDeleteButton addTarget:self action:@selector(batchDeleteTapped) forControlEvents:UIControlEventTouchUpInside];

            [self.batchActionStack addArrangedSubview:self.batchEnableButton];
            [self.batchActionStack addArrangedSubview:self.batchDisableButton];
            [self.batchActionStack addArrangedSubview:self.batchDeleteButton];
        }
    }
    [self updateNavigationButtons];
    [self.tableView reloadData];
}

/// 批量操作胶囊按钮
- (UIButton *)makeBatchActionButtonWithTitle:(NSString *)title tintColor:(UIColor *)color {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [button setTitleColor:color forState:UIControlStateNormal];
    button.backgroundColor = [color colorWithAlphaComponent:0.14];
    button.contentEdgeInsets = UIEdgeInsetsMake(6, 14, 6, 14);
    button.layer.cornerRadius = 15.0;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.layer.masksToBounds = YES;
    [button.heightAnchor constraintEqualToConstant:30].active = YES;
    [button setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [button setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return button;
}

/// 当前勾选的 ModItem 列表（基于基类 selectedIndexPaths）
- (NSArray<ModItem *> *)selectedModItems {
    NSMutableArray<ModItem *> *items = [NSMutableArray array];
    NSArray<NSIndexPath *> *indexPaths = [self.selectedIndexPaths sortedArrayUsingComparator:^NSComparisonResult(NSIndexPath *a, NSIndexPath *b) {
        return [a compare:b];
    }];
    for (NSIndexPath *indexPath in indexPaths) {
        if (indexPath.row < (NSInteger)self.filteredLocalMods.count) {
            [items addObject:self.filteredLocalMods[indexPath.row]];
        }
    }
    return items;
}

- (void)batchEnableTapped {
    [self batchSetDisabled:NO];
}

- (void)batchDisableTapped {
    [self batchSetDisabled:YES];
}

/// 批量启用（target=NO）/ 禁用（target=YES）：仅对状态不符的项执行切换
- (void)batchSetDisabled:(BOOL)target {
    NSArray<ModItem *> *mods = [self selectedModItems];
    if (mods.count == 0) {
        [self showDialogWithTitle:localize(@"resman.common.notice", nil) message:localize(@"resman.mods.none_selected", nil)];
        return;
    }

    NSInteger success = 0, failed = 0;
    for (ModItem *mod in mods) {
        if (mod.disabled == target) continue; // 状态已符合，跳过
        NSError *error = nil;
        if ([[ModService sharedService] toggleEnableForMod:mod error:&error]) {
            success++;
        } else {
            failed++;
            NSLog(@"[ModsManager] Batch toggle failed: %@ - %@", mod.displayName, error);
        }
    }

    [self setSelectMode:NO];
    [self loadMods]; // 文件名（.disabled 后缀）已变化，重新扫描

    NSString *verb = target ? localize(@"resman.common.disable", nil) : localize(@"resman.common.enable", nil);
    if (failed > 0) {
        [self showDialogWithTitle:[NSString stringWithFormat:localize(@"resman.mods.batch.toggle_complete", nil), verb]
                         message:[NSString stringWithFormat:localize(@"resman.mods.batch.result_message", nil), (long)success, (long)failed]];
    }
}

- (void)batchDeleteTapped {
    NSArray<ModItem *> *mods = [self selectedModItems];
    if (mods.count == 0) {
        [self showDialogWithTitle:localize(@"resman.common.notice", nil) message:localize(@"resman.mods.none_selected", nil)];
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"resman.common.batch_delete", nil)
                                                                   message:[NSString stringWithFormat:localize(@"resman.mods.batch.delete_message", nil), (long)mods.count]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.delete", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_Nonnull action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSMutableArray<ModItem *> *failedMods = [NSMutableArray array];
        for (ModItem *mod in mods) {
            NSError *error = nil;
            if (![[ModService sharedService] deleteMod:mod error:&error]) {
                NSLog(@"[ModsManager] Batch delete failed: %@ - %@", mod.displayName, error);
                [failedMods addObject:mod];
            } else {
                [strongSelf.modDates removeObjectForKey:mod.filePath];
                [strongSelf.updateResultsByPath removeObjectForKey:mod.filePath];
            }
        }

        [strongSelf setSelectMode:NO];
        [strongSelf loadMods]; // 重新扫描同步数据源

        if (failedMods.count > 0) {
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            for (ModItem *m in failedMods) [names addObject:m.displayName ?: m.fileName];
            [strongSelf showDialogWithTitle:[NSString stringWithFormat:localize(@"resman.common.delete_complete_failures", nil), (long)failedMods.count]
                                    message:[names componentsJoinedByString:@"\n"]];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Import Mod

- (void)importModTapped {
    NSError *dirError = nil;
    NSString *modsDir = [[ModService sharedService] ensureModsFolderForProfile:nil error:&dirError];
    if (!modsDir) {
        [self showDialogWithTitle:localize(@"resman.common.cannot_import", nil) message:dirError.localizedDescription ?: localize(@"resman.mods.dir_not_found", nil)];
        return;
    }

    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"com.sun.java.jar", @"public.item"]
                                                                                                   inMode:UIDocumentPickerModeImport];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    picker.title = localize(@"resman.mods.picker_title", nil);
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;

    NSError *dirError = nil;
    NSString *modsDir = [[ModService sharedService] ensureModsFolderForProfile:nil error:&dirError];
    if (!modsDir) {
        [self showDialogWithTitle:localize(@"resman.common.import_failed", nil) message:dirError.localizedDescription ?: localize(@"resman.mods.dir_not_found", nil)];
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSInteger successCount = 0;
    NSMutableArray<NSString *> *failedFiles = [NSMutableArray array];

    for (NSURL *url in urls) {
        BOOL accessing = [url startAccessingSecurityScopedResource];
        @try {
            NSString *fileName = url.lastPathComponent;
            NSString *destPath = [modsDir stringByAppendingPathComponent:fileName];
            // 同名文件处理
            if ([fm fileExistsAtPath:destPath]) {
                NSString *baseName = [fileName stringByDeletingPathExtension];
                NSString *ext = [fileName pathExtension];
                destPath = [modsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_copy.%@", baseName, ext]];
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

    [self loadMods];

    if (failedFiles.count > 0) {
        [self showDialogWithTitle:[NSString stringWithFormat:localize(@"resman.common.import_result", nil), (long)successCount, (long)failedFiles.count]
                          message:[failedFiles componentsJoinedByString:@"\n"]];
    } else {
        NSLog(@"[ModsManager] Successfully imported %ld mods", (long)successCount);
    }
}

#pragma mark - ModTableViewCellDelegate

- (void)modCellDidTapToggle:(UITableViewCell *)cell {
    NSIndexPath *indexPath = [self.tableView indexPathForCell:cell];
    if (!indexPath) return;

    ModItem *mod = self.filteredLocalMods[indexPath.row];
    NSError *error = nil;
    BOOL success = [[ModService sharedService] toggleEnableForMod:mod error:&error];
    if (!success) {
        NSLog(@"[ModsManager] Error toggling mod: %@", error);
    }
    // 无论成败按服务端状态回滚/刷新开关视觉（失败时 mod.disabled 未变）
    if ([cell isKindOfClass:[ModTableViewCell class]]) {
        [(ModTableViewCell *)cell updateToggleState:mod.disabled];
    }
}

- (void)modCellDidTapOpenLink:(UITableViewCell *)cell {
    NSIndexPath *indexPath = [self.tableView indexPathForCell:cell];
    if (!indexPath) return;

    ModItem *modItem = self.filteredLocalMods[indexPath.row];
    if (modItem.onlineID.length > 0) {
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://modrinth.com/mod/%@", modItem.onlineID]];
        if (url) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }
    } else {
        [self showDialogWithTitle:localize(@"resman.mods.link_unavailable", nil) message:localize(@"resman.mods.link_unavailable_message", nil)];
    }
}

#pragma mark - 内置更新流程（状态机：空闲 → 检查中 → 确认 → 下载替换中 → 完成 → 空闲）

/// 进入更新忙态：禁用按钮、导航栏转圈 + 阶段文本
- (void)enterUpdateBusyWithText:(NSString *)text {
    self.isUpdateBusy = YES;
    self.updateBusyText = [text copy];
    [self updateNavigationButtons];
}

/// 更新忙态内更新阶段文本（仅改标题，不重建按钮组）
- (void)setUpdateBusyTextOnly:(NSString *)text {
    self.updateBusyText = [text copy];
    self.navigationItem.title = self.updateBusyText;
}

/// 退出更新忙态：恢复按钮与标题
- (void)exitUpdateBusy {
    self.isUpdateBusy = NO;
    self.updateBusyText = nil;
    [self.navSpinner stopAnimating];
    [self updateNavigationButtons];
}

/// 顶栏"检查更新"入口：
/// 1) 补齐每个 Mod 的 SHA1（Modrinth 反查依赖）
/// 2) dispatch_group + 限流 3 并发调 ModUpdateService checkUpdateForMod
/// 3) 结果三分类：可更新 / 最新（已识别无更新）/ 无法识别（双源未命中）
/// 4) 可更新 > 0 → 确认弹窗；否则提示"所有 Mod 均为最新版本"
- (void)checkForUpdates {
    if (self.isUpdateBusy) return; // 防重复触发
    if (self.localMods.count == 0) {
        [self showDialogWithTitle:localize(@"resman.common.notice", nil) message:localize(@"resman.mods.no_local_for_update", nil)];
        return;
    }

    // 从当前 profile 的 lastVersionId 解析 gameVersion 和 loader
    NSString *lastVersionId = PLProfiles.current.selectedProfile[@"lastVersionId"];
    if (lastVersionId.length == 0) {
        [self showDialogWithTitle:localize(@"resman.common.notice", nil) message:localize(@"resman.mods.no_version_info", nil)];
        return;
    }
    NSString *gameVersion = nil;
    NSString *loader = nil;
    NSArray<NSString *> *loaders = @[@"forge", @"fabric", @"neoforge", @"quilt"];
    for (NSString *name in loaders) {
        NSRange range = [lastVersionId rangeOfString:[NSString stringWithFormat:@"-%@-", name]];
        if (range.location != NSNotFound) {
            gameVersion = [lastVersionId substringToIndex:range.location];
            loader = name;
            break;
        }
    }
    if (!gameVersion) {
        // 纯 <mc> 格式，无 loader
        gameVersion = lastVersionId;
        loader = nil;
    }

    // 若处于选择模式先退出（后续数据可能变化）
    if (self.selectModeEnabled) {
        [self setSelectMode:NO];
    }

    NSArray<ModItem *> *mods = [self.localMods copy];
    [self enterUpdateBusyWithText:localize(@"resman.mods.update.checking", nil)];

    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    __weak typeof(self) weakSelf = self;
    dispatch_async(queue, ^{
        // 阶段 1：补齐 SHA1（Modrinth 反查必需；大文件流式计算放后台）
        for (ModItem *mod in mods) {
            if (mod.fileSHA1.length == 0) {
                mod.fileSHA1 = ModsManagerSHA1ForFile(mod.filePath);
            }
        }

        // 阶段 2：并发检查（dispatch_group 汇总 + 信号量限流 3）
        dispatch_group_t group = dispatch_group_create();
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(3);
        NSObject *lock = [[NSObject alloc] init];
        NSMutableArray<ModUpdateResult *> *updatable = [NSMutableArray array];
        __block NSInteger unrecognized = 0;
        __block NSInteger completed = 0;
        NSInteger total = mods.count;

        for (ModItem *mod in mods) {
            dispatch_group_enter(group);
            dispatch_async(queue, ^{
                dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
                [[ModUpdateService sharedService] checkUpdateForMod:mod
                                                        gameVersion:gameVersion
                                                             loader:loader
                                                        projectType:@"mod"
                                                         completion:^(ModUpdateResult *_Nullable result) {
                    // 服务保证主线程回调
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    @synchronized(lock) {
                        if (result) {
                            if ([result hasUpdate]) [updatable addObject:result];
                        } else {
                            unrecognized++; // 双源未命中 → 无法识别
                        }
                        completed++;
                    }
                    if (strongSelf) {
                        [strongSelf setUpdateBusyTextOnly:[NSString stringWithFormat:localize(@"resman.mods.update.checking_progress", nil), (long)completed, (long)total]];
                    }
                    dispatch_semaphore_signal(semaphore);
                    dispatch_group_leave(group);
                }];
            });
        }

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf exitUpdateBusy];

            // 徽章：命中更新的 Mod 显示更新标记
            [strongSelf.updateResultsByPath removeAllObjects];
            for (ModUpdateResult *result in updatable) {
                if (result.localFilePath.length > 0) {
                    strongSelf.updateResultsByPath[result.localFilePath] = result;
                }
            }
            [strongSelf.tableView reloadData];

            if (updatable.count == 0) {
                NSString *message = localize(@"resman.mods.update.all_latest", nil);
                if (unrecognized > 0) {
                    message = [NSString stringWithFormat:localize(@"resman.mods.update.all_latest_skipped", nil), (long)unrecognized];
                }
                [strongSelf showDialogWithTitle:localize(@"resman.mods.check_update", nil) message:message];
            } else {
                [strongSelf presentUpdateConfirmAlertWithResults:[updatable copy] skipped:unrecognized];
            }
        });
    });
}

/// 更新确认弹窗：列出每项（名称 当前版本 → 新版本），全部更新 / 取消
- (void)presentUpdateConfirmAlertWithResults:(NSArray<ModUpdateResult *> *)results skipped:(NSInteger)skipped {
    if (results.count == 0) return;

    // 构建列表文本（超长时截断保护，最多列 8 项）
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSUInteger maxLines = 8;
    for (NSUInteger i = 0; i < results.count && i < maxLines; i++) {
        ModUpdateResult *result = results[i];
        NSString *name = result.localFilePath.lastPathComponent ?: localize(@"resman.common.unknown_file", nil);
        // 优先用 ModItem 显示名
        for (ModItem *mod in self.localMods) {
            if ([mod.filePath isEqualToString:result.localFilePath] && mod.displayName.length > 0) {
                name = mod.displayName;
                break;
            }
        }
        NSString *current = result.currentVersion.versionNumber ?: @"?";
        NSString *target = result.candidateVersions.firstObject.versionNumber ?: localize(@"resman.mods.update.latest", nil);
        [lines addObject:[NSString stringWithFormat:@"%@\n%@ → %@", name, current, target]];
    }
    if (results.count > maxLines) {
        [lines addObject:[NSString stringWithFormat:localize(@"resman.mods.update.more_total", nil), (long)results.count]];
    }
    if (skipped > 0) {
        [lines addObject:[NSString stringWithFormat:localize(@"resman.mods.update.skipped_line", nil), (long)skipped]];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:localize(@"resman.mods.update.found_title", nil), (long)results.count]
                                                                   message:[lines componentsJoinedByString:@"\n"]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.mods.update.update_all", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *_Nonnull action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf performModUpdatesWithResults:results skipped:skipped];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// 执行更新：并发下载到临时目录（PLDownloadClient，带 SHA1 校验 + 镜像候选）
/// → 全部下载完成后替换文件（删旧 → 移新，保留旧文件的禁用状态）
/// → 清徽章、重新加载列表、汇总提示
- (void)performModUpdatesWithResults:(NSArray<ModUpdateResult *> *)results skipped:(NSInteger)skipped {
    if (results.count == 0 || self.isUpdateBusy) return;

    // 构建下载任务列表
    NSMutableArray<ModUpdateTask *> *tasks = [NSMutableArray array];
    for (ModUpdateResult *result in results) {
        ModVersion *target = result.candidateVersions.firstObject;
        if (!target) continue; // 无候选版本，跳过
        ModUpdateTask *task = [[ModUpdateTask alloc] init];
        task.result = result;
        task.targetVersion = target;
        for (ModItem *mod in self.localMods) {
            if ([mod.filePath isEqualToString:result.localFilePath]) {
                task.mod = mod;
                break;
            }
        }
        [tasks addObject:task];
    }
    if (tasks.count == 0) return;

    // 临时目录
    NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ModUpdate_%@", [[NSUUID UUID] UUIDString]]];
    NSError *mkError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:tempDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&mkError];
    if (mkError) {
        [self showDialogWithTitle:localize(@"resman.mods.update.failed_title", nil)
                         message:[NSString stringWithFormat:localize(@"resman.mods.update.temp_dir_failed", nil), mkError.localizedDescription]];
        return;
    }

    [self enterUpdateBusyWithText:[NSString stringWithFormat:localize(@"resman.mods.update.downloading", nil), 0L, (long)tasks.count]];

    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_group_t group = dispatch_group_create();
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(4);
    NSObject *progressLock = [[NSObject alloc] init];
    __block NSInteger downloadDone = 0;
    NSInteger total = tasks.count;
    __weak typeof(self) weakSelf = self;

    for (ModUpdateTask *task in tasks) {
        // 从 primaryFile 提取下载信息（url / filename / sha1）
        NSDictionary *primaryFile = task.targetVersion.primaryFile;
        if (![primaryFile isKindOfClass:[NSDictionary class]]) {
            task.downloadSucceeded = NO;
            continue;
        }
        NSString *urlString = [primaryFile[@"url"] isKindOfClass:[NSString class]] ? primaryFile[@"url"] : nil;
        NSString *fileName = [primaryFile[@"filename"] isKindOfClass:[NSString class]] ? primaryFile[@"filename"] : nil;
        NSDictionary *hashes = [primaryFile[@"hashes"] isKindOfClass:[NSDictionary class]] ? primaryFile[@"hashes"] : nil;
        NSString *sha1 = [hashes[@"sha1"] isKindOfClass:[NSString class]] ? hashes[@"sha1"] : nil;
        NSURL *url = urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;

        if (!url || fileName.length == 0) {
            task.downloadSucceeded = NO;
            continue;
        }

        dispatch_group_enter(group);
        dispatch_async(queue, ^{
            dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

            PLDownloadRequest *request = [[PLDownloadRequest alloc] init];
            // 镜像候选列表（官方 CDN + MCIM 镜像，按用户策略排序）
            request.candidateURLs = [PLMirrorCenter candidateURLsForOriginalURL:url
                                                                   resourceType:PLMirrorResourceTypeAssetDownload];
            // 版本文件自带 SHA1 → 启用校验（失败由下载器按镜像/退避节奏重试）
            request.expectedSHA1 = sha1.length > 0 ? sha1 : nil;
            request.destinationPath = [tempDir stringByAppendingPathComponent:fileName];
            request.taskIdentifier = [NSString stringWithFormat:@"modupdate-%@", [[NSUUID UUID] UUIDString]];
            request.allowZipFallbackCheck = YES; // 无 SHA1 时 zip EOCD 兜底

            [[PLDownloadClient sharedClient] startRequest:request
                                                 progress:nil
                                                    speed:nil
                                               completion:^(BOOL success, NSError *_Nullable error) {
                // 回调在下载器内部串行队列（非主线程）
                if (success) {
                    task.downloadSucceeded = YES;
                    task.tempPath = request.destinationPath;
                } else {
                    task.downloadSucceeded = NO;
                    task.tempPath = nil;
                    NSLog(@"[ModsManager] Update download failed (%@): %@", fileName, error);
                }

                NSInteger done;
                @synchronized(progressLock) { downloadDone++; done = downloadDone; }
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (strongSelf) {
                        [strongSelf setUpdateBusyTextOnly:[NSString stringWithFormat:localize(@"resman.mods.update.downloading", nil), (long)done, (long)total]];
                    }
                });

                dispatch_semaphore_signal(semaphore);
                dispatch_group_leave(group);
            }];
        });
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            [[NSFileManager defaultManager] removeItemAtPath:tempDir error:nil];
            return;
        }

        // 阶段：替换文件（后台执行文件操作，完成后回主线程汇总）
        [strongSelf setUpdateBusyTextOnly:localize(@"resman.mods.update.replacing", nil)];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSFileManager *fm = [NSFileManager defaultManager];
            NSInteger successCount = 0;
            NSInteger failCount = 0;

            for (ModUpdateTask *task in tasks) {
                NSString *fileName = task.result.localFilePath.lastPathComponent ?: localize(@"resman.common.unknown_file", nil);
                if (!task.downloadSucceeded || task.tempPath.length == 0) {
                    failCount++;
                    continue;
                }
                // 下载文件名优先（新版本文件名可能变化）
                NSDictionary *primaryFile = task.targetVersion.primaryFile;
                NSString *downloadName = [primaryFile isKindOfClass:[NSDictionary class]]
                    ? ([primaryFile[@"filename"] isKindOfClass:[NSString class]] ? primaryFile[@"filename"] : nil)
                    : nil;
                if (downloadName.length > 0) fileName = downloadName;

                NSString *oldPath = task.result.localFilePath;
                NSString *oldDir = [oldPath stringByDeletingLastPathComponent];
                // 旧文件处于禁用状态（.disabled 后缀）时，新文件同样禁用，保留用户意图
                BOOL keepDisabled = [oldPath.lowercaseString hasSuffix:@".disabled"];
                NSString *newPath = [oldDir stringByAppendingPathComponent:fileName];
                if (keepDisabled && ![newPath.lowercaseString hasSuffix:@".disabled"]) {
                    newPath = [newPath stringByAppendingString:@".disabled"];
                }

                @try {
                    // 删旧 → 移新（ZL2 ModUpdater 替换逻辑）
                    if ([fm fileExistsAtPath:oldPath]) {
                        [fm removeItemAtPath:oldPath error:nil];
                    }
                    if (![newPath isEqualToString:oldPath] && [fm fileExistsAtPath:newPath]) {
                        [fm removeItemAtPath:newPath error:nil];
                    }
                    NSError *moveError = nil;
                    if ([fm moveItemAtPath:task.tempPath toPath:newPath error:&moveError]) {
                        successCount++;
                        task.tempPath = nil; // 已移走，避免后续误判
                    } else {
                        failCount++;
                        NSLog(@"[ModsManager] Update replace failed (%@): %@", fileName, moveError);
                    }
                } @catch (NSException *exception) {
                    failCount++;
                    NSLog(@"[ModsManager] Update replace exception (%@): %@", fileName, exception);
                }
            }

            // 清理临时目录
            [fm removeItemAtPath:tempDir error:nil];

            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) innerSelf = weakSelf;
                if (!innerSelf) return;
                // 清除更新徽章 + 退出忙态 + 重新加载列表
                [innerSelf.updateResultsByPath removeAllObjects];
                [innerSelf exitUpdateBusy];
                [innerSelf loadMods];
                [innerSelf showDialogWithTitle:localize(@"resman.mods.update.done_title", nil)
                                      message:[NSString stringWithFormat:localize(@"resman.mods.update.done_message", nil),
                                               (long)successCount, (long)failCount, (long)skipped]];
            });
        });
    });
}

#pragma mark - 工具方法

- (void)showDialogWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.ok", nil) style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
