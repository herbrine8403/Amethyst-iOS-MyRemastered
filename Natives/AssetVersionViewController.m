#import "utils.h"
//
//  AssetVersionViewController.m
//  Amethyst
//
// 通用资源版本选择视图控制器实现
// 阶段3统一：重构为 FCL 风格 chips 筛选条（游戏版本 + 排序方式），与 ModVersionViewController 风格一致
// 资产类型（资源包/数据包/世界）无加载器概念，故无加载器筛选行；版本源继承搜索结果。
//

#import "AssetVersionViewController.h"
#import "installer/modpack/ModrinthAPI.h"
#import "installer/modpack/CurseForgeAPI.h"
#import "ModVersion.h"
#import "ModVersionTableViewCell.h"
#import "AssetDetailHeaderView.h"
#import "BackgroundManager.h"

// ============================================================================
// 排序方式常量（与 ModVersionViewController 保持一致，阶段3统一）
// ============================================================================
static NSString *const kSortRelevance = @"relevance"; // 相关性（保持 API 原始顺序）
static NSString *const kSortDownloads = @"downloads"; // 下载量（版本级别无此字段，回退为原始顺序）
static NSString *const kSortUpdated   = @"updated";   // 最新更新（datePublished 降序）
static NSString *const kSortCreated   = @"created";   // 创建时间（datePublished 升序）

// 排序选项显示文案（与常量一一对应，用于 chips 渲染）
static NSArray<NSDictionary *> *SortOptionItems(void) {
    static NSArray *items = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        items = @[
            @{ @"key": kSortRelevance, @"title": localize(@"i18n_str_162", nil) },
            @{ @"key": kSortDownloads, @"title": localize(@"i18n_str_32", nil) },
            @{ @"key": kSortUpdated,   @"title": localize(@"i18n_str_33", nil) },
            @{ @"key": kSortCreated,   @"title": localize(@"i18n_str_34", nil) },
        ];
    });
    return items;
}

@interface AssetVersionViewController () <UITableViewDataSource, UITableViewDelegate>

// 主表格视图（展示版本列表）
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;

// ===== 侧边筛选面板（阶段3统一：参照 ModVersionViewController 的水平滚动 chips 筛选条）=====
// 筛选面板容器（半透明 + 毛玻璃背景，固定在 tableView 上方不随列表滚动）
@property (nonatomic, strong) UIView *filterContainerView;
// 主垂直 stack（容纳 2 行筛选：版本 / 排序，资产类型无加载器和下载源）
@property (nonatomic, strong) UIStackView *filterMainStack;

// --- 游戏版本筛选行 ---
@property (nonatomic, strong) UIScrollView *versionScrollView;
@property (nonatomic, strong) UIStackView  *versionChipStack;

// --- 排序方式筛选行 ---
@property (nonatomic, strong) UIScrollView *sortScrollView;
@property (nonatomic, strong) UIStackView  *sortChipStack;

// ===== 当前选中的筛选状态 =====
@property (nonatomic, copy)   NSString *selectedSort;    // 排序方式 key

// ===== 数据源 =====
@property (nonatomic, strong) NSArray<ModVersion *> *allVersions;
@property (nonatomic, strong) NSArray<ModVersion *> *filteredVersions;

// 可选的筛选选项列表（从版本数据中动态提取）
@property (nonatomic, strong) NSArray<NSString *> *availableGameVersions;

// 当前选中的版本（"全部" 表示不过滤）
@property (nonatomic, strong) NSString *selectedGameVersion;

// 项目详情头部视图（展示项目封面图/标题/作者/下载量/标签/描述，补齐信息显示缺口）
@property (nonatomic, strong) AssetDetailHeaderView *detailHeaderView;

@end

@implementation AssetVersionViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = self.projectDisplayName ?: [self titleForAssetType];
    // 适配自定义启动器背景：透明化当前 VC，让全局背景图/毛玻璃透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // 初始化筛选状态（默认相关性排序，与 ModVersionViewController 一致）
    self.selectedSort = kSortRelevance;

    [self setupSideFilterPanel];
    [self setupTableView];
    [self setupActivityIndicator];
    [self setupDetailHeader];

    // 透明化 tableView 背景，避免遮挡全局背景
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;

    [self fetchVersions];

    // 监听背景效果变化通知，背景切换时重新应用透明效果
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (void)reapplyBackgroundEffect {
    // 背景效果改变时重新透明化当前 VC
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    // 重新设置 tableView 背景为透明，确保背景效果切换后仍透出全局背景
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
}

- (void)dealloc {
    // 移除通知观察者，避免dealloc后收到通知导致崩溃
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Detail Header（项目信息展示）

/// 创建并配置项目详情头部视图，设置为 tableView.tableHeaderView
/// 补齐之前版本页缺少的项目封面图/标题/作者/下载量/标签/描述等信息显示
- (void)setupDetailHeader {
    self.detailHeaderView = [[AssetDetailHeaderView alloc] init];

    // 描述展开/收起时重新计算 header 高度（避免循环引用，用 weak）
    __weak typeof(self) weakSelf = self;
    self.detailHeaderView.onSizeChanged = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) [strongSelf updateTableHeaderHeight];
    };

    // 根据 assetType 选占位 SF Symbol + 配色（与 ModernAssetCell 的资源类型配色一致）
    NSString *placeholderSymbol = @"doc.fill";
    UIColor *placeholderColor = [UIColor systemBlueColor];
    switch (self.assetType) {
        case AssetVersionTypeResourcePack:
            placeholderSymbol = @"photo.stack.fill";
            placeholderColor = [UIColor systemBlueColor];
            break;
        case AssetVersionTypeDataPack:
            placeholderSymbol = @"doc.text.fill";
            placeholderColor = [UIColor systemTealColor];
            break;
        case AssetVersionTypeWorld:
            placeholderSymbol = @"globe";
            placeholderColor = [UIColor systemGreenColor];
            break;
    }

    // 用 DownloadViewController 传入的项目展示信息填充
    [self.detailHeaderView configureWithIconURL:self.projectIconURL
                                          title:self.projectDisplayName ?: localize(@"i18n_str_27", nil)
                                         author:self.projectAuthor
                                      downloads:self.projectDownloads
                                          likes:self.projectLikes
                                descriptionText:self.projectDescription
                                    categories:self.projectCategories
                                   lastUpdated:self.projectLastUpdated
                           placeholderSymbolName:placeholderSymbol
                               placeholderColor:placeholderColor];

    [self updateTableHeaderHeight];
    self.tableView.tableHeaderView = self.detailHeaderView;
}

/// 重新计算 tableHeaderView 高度并刷新（在 viewDidLayoutSubviews 和描述展开/收起时调用）
- (void)updateTableHeaderHeight {
    if (!self.detailHeaderView) return;
    CGFloat width = self.tableView.bounds.size.width;
    if (width <= 0) width = self.view.bounds.size.width;
    if (width <= 0) width = [UIScreen mainScreen].bounds.size.width;
    CGFloat height = [self.detailHeaderView fittingHeightForWidth:width];
    CGRect frame = self.detailHeaderView.frame;
    if (fabs(frame.size.height - height) < 1) return; // 高度未变化则跳过
    frame.size.height = height;
    self.detailHeaderView.frame = frame;
    // 重新赋值触发 tableView 重新布局 header
    self.tableView.tableHeaderView = self.detailHeaderView;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // 首次 layout 后 tableView 宽度才确定，此时更新一次 header 高度
    if (self.detailHeaderView) {
        [self updateTableHeaderHeight];
    }
}

// 根据资产类型返回默认导航栏标题
- (NSString *)titleForAssetType {
    switch (self.assetType) {
        case AssetVersionTypeResourcePack: return localize(@"i18n_str_35", nil);
        case AssetVersionTypeDataPack:     return localize(@"i18n_str_36", nil);
        case AssetVersionTypeWorld:        return localize(@"i18n_str_37", nil);
    }
    return localize(@"i18n_str_38", nil);
}

#pragma mark - 侧边筛选面板（chips 筛选条，阶段3统一）

/// 创建筛选面板容器 + 2 行 chips（游戏版本 + 排序方式）
/// 参照 ModVersionViewController 的 setupSideFilterPanel，但移除了下载源和加载器行
- (void)setupSideFilterPanel {
    // ===== 筛选面板容器（半透明 + 毛玻璃，固定在顶部不随列表滚动）=====
    self.filterContainerView = [[UIView alloc] init];
    self.filterContainerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.filterContainerView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.06];
    self.filterContainerView.layer.cornerRadius = 14;
    self.filterContainerView.layer.cornerCurve = kCACornerCurveContinuous;
    self.filterContainerView.layer.borderWidth = 0.5;
    self.filterContainerView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    [self.view addSubview:self.filterContainerView];
    // 应用毛玻璃背景效果，与启动器整体风格一致
    [[BackgroundManager sharedManager] applyEffectToView:self.filterContainerView];

    // ===== 主垂直 stack（2 行筛选，每行 = 图标标签 + 水平滚动 chips）=====
    self.filterMainStack = [[UIStackView alloc] init];
    self.filterMainStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.filterMainStack.axis = UILayoutConstraintAxisVertical;
    self.filterMainStack.spacing = 4;
    self.filterMainStack.alignment = UIStackViewAlignmentFill;
    [self.filterContainerView addSubview:self.filterMainStack];

    // ----- 第 1 行：游戏版本筛选（动态填充，初始显示"加载中"）-----
    {
        UIScrollView *scrollOut = nil;
        UIStackView *chipOut = nil;
        UIStackView *versionRow = [self createFilterRowWithIconName:@"gamecontroller.fill"
                                                              label:localize(@"i18n_str_39", nil)
                                                         scrollStackOut:&scrollOut
                                                           chipStackOut:&chipOut];
        self.versionScrollView = scrollOut;
        self.versionChipStack = chipOut;
        [self.filterMainStack addArrangedSubview:versionRow];
    }
    [self addChipToStack:self.versionChipStack title:localize(@"i18n_str_40", nil) selected:NO action:NULL];

    // ----- 第 2 行：排序方式筛选（相关性 / 下载量 / 最新更新 / 创建时间）-----
    {
        UIScrollView *scrollOut = nil;
        UIStackView *chipOut = nil;
        UIStackView *sortRow = [self createFilterRowWithIconName:@"arrow.up.arrow.down"
                                                           label:localize(@"i18n_str_41", nil)
                                                      scrollStackOut:&scrollOut
                                                        chipStackOut:&chipOut];
        self.sortScrollView = scrollOut;
        self.sortChipStack = chipOut;
        [self.filterMainStack addArrangedSubview:sortRow];
    }
    [self rebuildSortChips];

    // ===== 容器约束：顶部紧贴安全区域，左右留 8pt 边距 =====
    [NSLayoutConstraint activateConstraints:@[
        [self.filterContainerView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:6],
        [self.filterContainerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [self.filterContainerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        // 主 stack 内边距
        [self.filterMainStack.topAnchor constraintEqualToAnchor:self.filterContainerView.topAnchor constant:8],
        [self.filterMainStack.bottomAnchor constraintEqualToAnchor:self.filterContainerView.bottomAnchor constant:-8],
        [self.filterMainStack.leadingAnchor constraintEqualToAnchor:self.filterContainerView.leadingAnchor constant:10],
        [self.filterMainStack.trailingAnchor constraintEqualToAnchor:self.filterContainerView.trailingAnchor constant:-10],
    ]];
}

/// 创建单行筛选布局：左侧图标+标签（固定宽度），右侧水平滚动 chips 容器
/// 参照 ModVersionViewController 的 createFilterRowWithIconName（阶段3统一）
- (UIStackView *)createFilterRowWithIconName:(NSString *)iconName
                                       label:(NSString *)labelText
                                scrollStackOut:(UIScrollView **)scrollStackOut
                                  chipStackOut:(UIStackView **)chipStackOut {
    // --- 左侧：图标 + 标签（固定宽度，不随 chips 滚动）---
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.image = [UIImage systemImageNamed:iconName];
    iconView.tintColor = [UIColor secondaryLabelColor];
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    [iconView setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [iconView setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [NSLayoutConstraint activateConstraints:@[
        [iconView.widthAnchor constraintEqualToConstant:15],
        [iconView.heightAnchor constraintEqualToConstant:15],
    ]];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = labelText;
    label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    label.textColor = [UIColor secondaryLabelColor];
    label.textAlignment = NSTextAlignmentLeft;
    [label setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [label setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [label.widthAnchor constraintEqualToConstant:34].active = YES;

    UIStackView *labelStack = [[UIStackView alloc] initWithArrangedSubviews:@[iconView, label]];
    labelStack.translatesAutoresizingMaskIntoConstraints = NO;
    labelStack.axis = UILayoutConstraintAxisHorizontal;
    labelStack.spacing = 3;
    labelStack.alignment = UIStackViewAlignmentCenter;
    [labelStack setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    // --- 右侧：水平滚动 chips 容器 ---
    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.showsHorizontalScrollIndicator = NO;
    scrollView.alwaysBounceHorizontal = YES;

    UIStackView *chipStack = [[UIStackView alloc] init];
    chipStack.translatesAutoresizingMaskIntoConstraints = NO;
    chipStack.axis = UILayoutConstraintAxisHorizontal;
    chipStack.spacing = 6;
    chipStack.alignment = UIStackViewAlignmentCenter;
    [scrollView addSubview:chipStack];

    // chipStack 填满 scrollView 的 contentLayoutGuide，高度与 frameLayoutGuide 一致
    [NSLayoutConstraint activateConstraints:@[
        [chipStack.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor],
        [chipStack.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor],
        [chipStack.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor],
        [chipStack.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor],
        [chipStack.heightAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.heightAnchor],
    ]];

    // 输出到调用方的属性
    if (scrollStackOut) *scrollStackOut = scrollView;
    if (chipStackOut) *chipStackOut = chipStack;

    // --- 行容器：标签 + 滚动视图 水平排列 ---
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[labelStack, scrollView]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 6;
    row.alignment = UIStackViewAlignmentCenter;
    // 固定行高，让总高度可控
    [row.heightAnchor constraintEqualToConstant:30].active = YES;
    return row;
}

/// 创建单个筛选 chip 按钮（pill 样式，参照 ModVersionViewController）
/// 选中态：主题色(systemBlue)背景 + 白字；未选中态：半透明背景 + 标签色文字 + 浅边框
- (UIButton *)createFilterChipWithTitle:(NSString *)title selected:(BOOL)selected {
    UIButton *chip = [UIButton buttonWithType:UIButtonTypeSystem];
    chip.translatesAutoresizingMaskIntoConstraints = NO;
    [chip setTitle:title forState:UIControlStateNormal];
    chip.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    chip.titleLabel.adjustsFontSizeToFitWidth = YES;
    chip.titleLabel.minimumScaleFactor = 0.75;
    chip.contentEdgeInsets = UIEdgeInsetsMake(4, 12, 4, 12);
    chip.layer.cornerRadius = 14;
    chip.layer.cornerCurve = kCACornerCurveContinuous;
    chip.layer.masksToBounds = YES;
    // 固定高度，防止内容变化导致高度跳动
    [chip.heightAnchor constraintEqualToConstant:28].active = YES;
    [chip setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [chip setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self applyChipStyle:chip selected:selected];
    return chip;
}

/// 应用 chip 选中/未选中样式（与 ModVersionViewController 一致，阶段3统一）
- (void)applyChipStyle:(UIButton *)chip selected:(BOOL)selected {
    if (selected) {
        // 选中态：主题色背景 + 白字（参照 FCL 选中标签高亮）
        chip.backgroundColor = [UIColor systemBlueColor];
        [chip setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        chip.layer.borderWidth = 0;
    } else {
        // 未选中态：半透明背景 + 标签色文字 + 浅边框
        chip.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
        [chip setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        chip.layer.borderWidth = 0.5;
        chip.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15].CGColor;
    }
}

/// 向 chipStack 添加一个 chip（自动应用样式 + 绑定点击回调）
- (void)addChipToStack:(UIStackView *)stack title:(NSString *)title selected:(BOOL)selected action:(void(^)(void))action {
    UIButton *chip = [self createFilterChipWithTitle:title selected:selected];
    if (action) {
        [chip addAction:[UIAction actionWithTitle:title image:nil identifier:nil handler:^(__kindof UIAction * _Nonnull act) {
            action();
        }] forControlEvents:UIControlEventTouchUpInside];
    }
    [stack addArrangedSubview:chip];
}

/// 重建游戏版本 chips（从"加载中..."替换为实际数据）
- (void)rebuildVersionChips {
    // 清空旧 chips
    for (UIView *v in self.versionChipStack.arrangedSubviews) {
        [self.versionChipStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    // 添加新 chips
    for (NSString *version in self.availableGameVersions) {
        BOOL isSelected = [self.selectedGameVersion isEqualToString:version];
        __weak typeof(self) weakSelf = self;
        [self addChipToStack:self.versionChipStack title:version selected:isSelected action:^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if ([strongSelf.selectedGameVersion isEqualToString:version]) return;
            strongSelf.selectedGameVersion = version;
            // 更新 chip 选中态
            for (UIView *v in strongSelf.versionChipStack.arrangedSubviews) {
                if ([v isKindOfClass:[UIButton class]]) {
                    UIButton *chip = (UIButton *)v;
                    [strongSelf applyChipStyle:chip selected:[chip.titleLabel.text isEqualToString:version]];
                }
            }
            [strongSelf applyFiltersAndSort];
        }];
    }
    // 滚动到选中 chip
    [self scrollToSelectedChipInStack:self.versionChipStack withTitle:self.selectedGameVersion];
}

/// 重建排序方式 chips（静态选项）
- (void)rebuildSortChips {
    // 清空旧 chips
    for (UIView *v in self.sortChipStack.arrangedSubviews) {
        [self.sortChipStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    // 添加新 chips
    for (NSDictionary *item in SortOptionItems()) {
        NSString *key = item[@"key"];
        NSString *title = item[@"title"];
        BOOL isSelected = [self.selectedSort isEqualToString:key];
        __weak typeof(self) weakSelf = self;
        [self addChipToStack:self.sortChipStack title:title selected:isSelected action:^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if ([strongSelf.selectedSort isEqualToString:key]) return;
            strongSelf.selectedSort = key;
            // 更新 chip 选中态（用 accessibilityIdentifier 存 key）
            for (UIView *v in strongSelf.sortChipStack.arrangedSubviews) {
                if ([v isKindOfClass:[UIButton class]]) {
                    UIButton *chip = (UIButton *)v;
                    [strongSelf applyChipStyle:chip selected:[chip.titleLabel.text isEqualToString:title]];
                }
            }
            [strongSelf applyFiltersAndSort];
        }];
    }
    [self scrollToSelectedChipInStack:self.sortChipStack withTitle:nil];
}

/// 滚动到选中的 chip（如果可见区域内不可见）
- (void)scrollToSelectedChipInStack:(UIStackView *)stack withTitle:(NSString *)title {
    if (!title) return;
    for (UIView *v in stack.arrangedSubviews) {
        if ([v isKindOfClass:[UIButton class]]) {
            UIButton *chip = (UIButton *)v;
            if ([chip.titleLabel.text isEqualToString:title]) {
                UIScrollView *scrollView = (UIScrollView *)stack.superview;
                if ([scrollView isKindOfClass:[UIScrollView class]]) {
                    CGRect chipFrame = [chip convertRect:chip.bounds toView:scrollView];
                    CGFloat targetX = chipFrame.origin.x - scrollView.bounds.size.width / 2 + chipFrame.size.width / 2;
                    targetX = MAX(0, targetX);
                    [scrollView scrollRectToVisible:CGRectMake(targetX, 0, scrollView.bounds.size.width, scrollView.bounds.size.height) animated:YES];
                }
                break;
            }
        }
    }
}

#pragma mark - TableView Setup

- (void)setupTableView {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.tableView registerClass:[ModVersionTableViewCell class] forCellReuseIdentifier:@"AssetVersionCell"];
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.filterContainerView.bottomAnchor constant:8],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)setupActivityIndicator {
    self.activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.activityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.activityIndicator.hidesWhenStopped = YES;
    [self.view addSubview:self.activityIndicator];

    [NSLayoutConstraint activateConstraints:@[
        [self.activityIndicator.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.activityIndicator.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];
}

#pragma mark - 数据获取

- (void)fetchVersions {
    if (!self.projectID.length) {
        NSLog(@"[AssetVersionVC] Missing projectID, cannot fetch version list");
        return;
    }

    [self.activityIndicator startAnimating];
    void (^completion)(NSArray<ModVersion *> * _Nullable, NSError * _Nullable) = ^(NSArray<ModVersion *> * _Nullable versions, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.activityIndicator stopAnimating];
            if (error) {
                NSLog(@"[AssetVersionVC] Failed to fetch version list: %@", error);
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_42", nil)
                                                                                message:localize(@"i18n_str_43", nil)
                                                                         preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
                return;
            }
            self.allVersions = versions ?: @[];
            [self processFilters];
            [self applyFiltersAndSort];
        });
    };

    if (self.apiSource == 2) {
        [[CurseForgeAPI sharedInstance] getVersionsForModWithID:self.projectID completion:completion];
    } else {
        [[ModrinthAPI sharedInstance] getVersionsForModWithID:self.projectID completion:completion];
    }
}

#pragma mark - 筛选 + 排序

- (void)processFilters {
    NSMutableSet<NSString *> *gameVersions = [NSMutableSet setWithObject:localize(@"resman.mods.filter.all", nil)];

    for (ModVersion *version in self.allVersions) {
        for (NSString *gameVersion in version.gameVersions) {
            [gameVersions addObject:gameVersion];
        }
    }

    // 游戏版本按语义版本号倒序排列（新版本在前），"全部"始终在最前
    self.availableGameVersions = [[gameVersions allObjects] sortedArrayUsingComparator:^NSComparisonResult(NSString *obj1, NSString *obj2) {
        if ([obj1 isEqualToString:@"全部"]) return NSOrderedAscending;
        if ([obj2 isEqualToString:@"全部"]) return NSOrderedDescending;
        return [obj2 compare:obj1 options:NSNumericSearch];
    }];

    // FCL 风格：默认选中"全部"，但如果 preferredGameVersion 在可选列表中，则自动选中匹配项
    // 阶段3统一：补齐与 ModVersionViewController 不对称的 preferred 自动选中逻辑
    self.selectedGameVersion = self.availableGameVersions.firstObject ?: localize(@"resman.mods.filter.all", nil);

    // 自动选中 preferred 版本（大小写不敏感比较）
    if (self.preferredGameVersion.length > 0) {
        NSString *preferred = self.preferredGameVersion;
        for (NSString *gv in self.availableGameVersions) {
            if ([gv caseInsensitiveCompare:preferred] == NSOrderedSame) {
                self.selectedGameVersion = gv;
                break;
            }
        }
    }

    // 重建版本 chips（从"加载中..."替换为实际数据）
    [self rebuildVersionChips];
}

/// 应用筛选 + 排序并刷新表格
/// 先按游戏版本过滤，再按排序方式排序，最后把匹配 preferred 的版本置顶
- (void)applyFiltersAndSort {
    // ----- 1. 筛选：游戏版本（资产类型无加载器概念）-----
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(ModVersion *evaluatedObject, NSDictionary *bindings) {
        return [self.selectedGameVersion isEqualToString:@"全部"] ||
               [evaluatedObject.gameVersions containsObject:self.selectedGameVersion];
    }];
    NSArray<ModVersion *> *filtered = [self.allVersions filteredArrayUsingPredicate:predicate];

    // ----- 2. 排序：按选中的排序方式 -----
    NSArray<ModVersion *> *sorted = [self sortVersions:filtered];

    // ----- 3. FCL 风格：把匹配 preferred 版本的版本置顶 -----
    // 阶段3统一：补齐与 ModVersionViewController 不对称的 preferred 置顶逻辑
    if (self.preferredGameVersion.length > 0) {
        NSMutableArray<ModVersion *> *pinned = [NSMutableArray array];
        NSMutableArray<ModVersion *> *rest = [NSMutableArray array];
        for (ModVersion *v in sorted) {
            if ([v.gameVersions containsObject:self.preferredGameVersion]) {
                [pinned addObject:v];
            } else {
                [rest addObject:v];
            }
        }
        // 置顶的部分按原排序顺序，其余接在后面
        if (pinned.count > 0 && pinned.count < sorted.count) {
            sorted = [pinned arrayByAddingObjectsFromArray:rest];
        }
    }

    self.filteredVersions = sorted;
    [self.tableView reloadData];
}

/// 对版本数组按当前选中的排序方式进行排序（与 ModVersionViewController 一致）
- (NSArray<ModVersion *> *)sortVersions:(NSArray<ModVersion *> *)versions {
    if (!versions || versions.count <= 1) return versions;

    // 相关性 / 下载量：保持 API 原始顺序
    if ([self.selectedSort isEqualToString:kSortRelevance] ||
        [self.selectedSort isEqualToString:kSortDownloads]) {
        return versions;
    }

    // 最新更新 / 创建时间：按 datePublished 排序
    NSISO8601DateFormatter *dateFormatter = [[NSISO8601DateFormatter alloc] init];
    NSMutableArray<ModVersion *> *sorted = [versions mutableCopy];
    __weak typeof(self) weakSelf = self;
    [sorted sortUsingComparator:^NSComparisonResult(ModVersion *v1, ModVersion *v2) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        NSDate *d1 = [dateFormatter dateFromString:v1.datePublished];
        NSDate *d2 = [dateFormatter dateFromString:v2.datePublished];
        if (!d1) d1 = [NSDate distantPast];
        if (!d2) d2 = [NSDate distantPast];

        if ([strongSelf.selectedSort isEqualToString:kSortUpdated]) {
            // 最新更新：降序（新的在前）
            return [d2 compare:d1];
        }
        if ([strongSelf.selectedSort isEqualToString:kSortCreated]) {
            // 创建时间：升序（旧的在前）
            return [d1 compare:d2];
        }
        return NSOrderedSame;
    }];
    return sorted;
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredVersions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ModVersionTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AssetVersionCell" forIndexPath:indexPath];
    ModVersion *version = self.filteredVersions[indexPath.row];
    [cell configureWithVersion:version];
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    ModVersion *selectedVersion = self.filteredVersions[indexPath.row];
    if ([self.delegate respondsToSelector:@selector(assetVersionViewController:didSelectVersion:)]) {
        [self.delegate assetVersionViewController:self didSelectVersion:selectedVersion];
    }
    [self.navigationController popViewControllerAnimated:YES];
}

@end
