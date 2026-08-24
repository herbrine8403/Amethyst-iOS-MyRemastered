#import "utils.h"
#import "ModVersionViewController.h"
#import "installer/modpack/ModrinthAPI.h"
#import "installer/modpack/CurseForgeAPI.h"
#import "ModVersion.h"
#import "ModVersionTableViewCell.h"
#import "AssetDetailHeaderView.h"
#import "BackgroundManager.h"

// ============================================================================
// 下载源常量（与 ModVersion.apiSource 字段保持一致：1=Modrinth, 2=CurseForge）
// ============================================================================
static const NSInteger kSourceModrinth    = 1;
static const NSInteger kSourceCurseForge  = 2;

// ============================================================================
// 排序方式常量（参照 FCL/ZL2 的排序选项）
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

@interface ModVersionViewController () <UITableViewDataSource, UITableViewDelegate>

// 主表格视图（展示版本列表）
@property (nonatomic, strong) UITableView *tableView;

// ===== 侧边筛选面板（参照 FCL/ZL2 的水平滚动 chips 筛选条）=====
// 筛选面板容器（半透明 + 毛玻璃背景，固定在 tableView 上方不随列表滚动）
@property (nonatomic, strong) UIView *filterContainerView;
// 主垂直 stack（容纳 4 行筛选：来源 / 版本 / 加载器 / 排序）
@property (nonatomic, strong) UIStackView *filterMainStack;

// --- 下载源筛选行 ---
@property (nonatomic, strong) UIScrollView *sourceScrollView;   // 水平滚动容器
@property (nonatomic, strong) UIStackView  *sourceChipStack;    // chips 水平排列

// --- 游戏版本筛选行 ---
@property (nonatomic, strong) UIScrollView *versionScrollView;
@property (nonatomic, strong) UIStackView  *versionChipStack;

// --- 模组加载器筛选行 ---
@property (nonatomic, strong) UIScrollView *loaderScrollView;
@property (nonatomic, strong) UIStackView  *loaderChipStack;

// --- 排序方式筛选行 ---
@property (nonatomic, strong) UIScrollView *sortScrollView;
@property (nonatomic, strong) UIStackView  *sortChipStack;

// ===== 当前选中的筛选状态 =====
@property (nonatomic, assign) NSInteger selectedSource;  // 1=Modrinth, 2=CurseForge
@property (nonatomic, copy)   NSString *selectedSort;    // 排序方式 key

// ===== 数据源 =====
@property (nonatomic, strong) NSArray<ModVersion *> *allVersions;
@property (nonatomic, strong) NSArray<ModVersion *> *filteredVersions;

// 可选的筛选选项列表（从版本数据中动态提取）
@property (nonatomic, strong) NSArray<NSString *> *availableGameVersions;
@property (nonatomic, strong) NSArray<NSString *> *availableLoaders;

// 当前选中的版本 / 加载器（"全部" 表示不过滤）
@property (nonatomic, strong) NSString *selectedGameVersion;
@property (nonatomic, strong) NSString *selectedLoader;

// 项目详情头部视图（展示项目封面图/标题/作者/下载量/标签/描述，补齐信息显示缺口）
@property (nonatomic, strong) AssetDetailHeaderView *detailHeaderView;

@end

@implementation ModVersionViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.modItem.displayName;
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    // 适配自定义启动器背景：透明化当前 VC，让全局背景图/毛玻璃透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // 从搜索结果继承 API 来源，避免拿 CurseForge 数字 ID 请求 Modrinth。
    self.selectedSource = self.initialSource == kSourceCurseForge ? kSourceCurseForge : kSourceModrinth;
    self.selectedSort = kSortRelevance;

    [self setupSideFilterPanel];
    [self setupTableView];
    [self setupActivityIndicator];
    [self setupDetailHeader];

    // 透明化 tableView 背景，避免遮挡全局背景
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;

    [self fetchVersionsFromCurrentSource];

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

    // 用搜索阶段已有的 modItem 数据填充（无需额外 API 调用）
    [self.detailHeaderView configureWithIconURL:self.modItem.iconURL
                                          title:self.modItem.displayName
                                         author:self.modItem.author
                                      downloads:self.modItem.downloads
                                          likes:self.modItem.likes
                                descriptionText:self.modItem.modDescription
                                    categories:self.modItem.categories
                                   lastUpdated:self.modItem.lastUpdated
                           placeholderSymbolName:@"puzzlepiece.extension.fill"
                               placeholderColor:[UIColor systemOrangeColor]];

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

#pragma mark - 侧边筛选面板（参照 FCL/ZL2 水平滚动 chips）

/// 创建侧边筛选面板：4 行水平滚动 chips（下载源 / 游戏版本 / 加载器 / 排序方式）
/// 参照 FCL 安卓版的筛选条设计：每个类别一行，图标+标签前缀，chips 水平滚动，
/// 选中项高亮（主题色背景 + 白字），未选中项半透明背景 + 浅边框。
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

    // ===== 主垂直 stack（4 行筛选，每行 = 图标标签 + 水平滚动 chips）=====
    self.filterMainStack = [[UIStackView alloc] init];
    self.filterMainStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.filterMainStack.axis = UILayoutConstraintAxisVertical;
    self.filterMainStack.spacing = 4;
    self.filterMainStack.alignment = UIStackViewAlignmentFill;
    [self.filterContainerView addSubview:self.filterMainStack];

    // ----- 第 1 行：下载源筛选（Modrinth / CurseForge）-----
    {
        UIScrollView *scrollOut = nil;
        UIStackView *chipOut = nil;
        UIStackView *sourceRow = [self createFilterRowWithIconName:@"globe"
                                                             label:localize(@"i18n_str_462", nil)
                                                        scrollStackOut:&scrollOut
                                                          chipStackOut:&chipOut];
        self.sourceScrollView = scrollOut;
        self.sourceChipStack = chipOut;
        [self.filterMainStack addArrangedSubview:sourceRow];
    }
    [self rebuildSourceChips];

    // ----- 第 2 行：游戏版本筛选（动态填充，初始显示"加载中"）-----
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

    // ----- 第 3 行：模组加载器筛选（动态填充，初始显示"加载中"）-----
    {
        UIScrollView *scrollOut = nil;
        UIStackView *chipOut = nil;
        UIStackView *loaderRow = [self createFilterRowWithIconName:@"puzzlepiece.extension.fill"
                                                             label:localize(@"i18n_str_114", nil)
                                                        scrollStackOut:&scrollOut
                                                          chipStackOut:&chipOut];
        self.loaderScrollView = scrollOut;
        self.loaderChipStack = chipOut;
        [self.filterMainStack addArrangedSubview:loaderRow];
    }
    [self addChipToStack:self.loaderChipStack title:localize(@"i18n_str_40", nil) selected:NO action:NULL];

    // ----- 第 4 行：排序方式筛选（相关性 / 下载量 / 最新更新 / 创建时间）-----
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
/// 参照 FCL 筛选面板的行结构：icon + label + horizontal scrollview
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
    // 固定行高，让 4 行总高度可控
    [row.heightAnchor constraintEqualToConstant:30].active = YES;
    return row;
}

/// 创建单个筛选 chip 按钮（pill 样式，参照 FCL/ZL2 的标签条）
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

/// 应用 chip 选中/未选中样式
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

/// 向 chipStack 添加一个 chip（快捷方法，用于初始占位）
- (void)addChipToStack:(UIStackView *)stack title:(NSString *)title selected:(BOOL)selected action:(SEL)action {
    UIButton *chip = [self createFilterChipWithTitle:title selected:selected];
    if (action) {
        [chip addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    }
    [stack addArrangedSubview:chip];
}

/// 清空 chipStack 中所有已排列的子视图（用于重建 chips）
- (void)clearChipStack:(UIStackView *)stack {
    [stack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
}

#pragma mark - 重建各筛选行 chips

/// 重建下载源 chips（Modrinth / CurseForge）
- (void)rebuildSourceChips {
    [self clearChipStack:self.sourceChipStack];

    // Modrinth chip
    UIButton *modrinthChip = [self createFilterChipWithTitle:@"Modrinth"
                                                    selected:(self.selectedSource == kSourceModrinth)];
    modrinthChip.tag = kSourceModrinth;
    [modrinthChip addTarget:self action:@selector(sourceChipTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.sourceChipStack addArrangedSubview:modrinthChip];

    // CurseForge chip
    UIButton *curseforgeChip = [self createFilterChipWithTitle:@"CurseForge"
                                                      selected:(self.selectedSource == kSourceCurseForge)];
    curseforgeChip.tag = kSourceCurseForge;
    [curseforgeChip addTarget:self action:@selector(sourceChipTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.sourceChipStack addArrangedSubview:curseforgeChip];
}

/// 重建游戏版本 chips（从 availableGameVersions 动态填充，含"全部"）
- (void)rebuildVersionChips {
    [self clearChipStack:self.versionChipStack];
    if (!self.availableGameVersions || self.availableGameVersions.count == 0) {
        [self addChipToStack:self.versionChipStack title:localize(@"i18n_str_463", nil) selected:NO action:NULL];
        return;
    }
    for (NSString *version in self.availableGameVersions) {
        BOOL isSelected = [self.selectedGameVersion isEqualToString:version];
        UIButton *chip = [self createFilterChipWithTitle:version selected:isSelected];
        [chip addTarget:self action:@selector(versionChipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.versionChipStack addArrangedSubview:chip];
    }
    // 滚动到选中项位置（让用户能看到当前选中的 chip）
    [self scrollToSelectedChipInStack:self.versionChipStack withTitle:self.selectedGameVersion];
}

/// 重建加载器 chips（从 availableLoaders 动态填充，含"全部"）
- (void)rebuildLoaderChips {
    [self clearChipStack:self.loaderChipStack];
    if (!self.availableLoaders || self.availableLoaders.count == 0) {
        [self addChipToStack:self.loaderChipStack title:localize(@"i18n_str_464", nil) selected:NO action:NULL];
        return;
    }
    for (NSString *loader in self.availableLoaders) {
        BOOL isSelected = [self.selectedLoader isEqualToString:loader];
        UIButton *chip = [self createFilterChipWithTitle:loader selected:isSelected];
        [chip addTarget:self action:@selector(loaderChipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.loaderChipStack addArrangedSubview:chip];
    }
    // 滚动到选中项位置
    [self scrollToSelectedChipInStack:self.loaderChipStack withTitle:self.selectedLoader];
}

/// 重建排序方式 chips（固定 4 个选项：相关性 / 下载量 / 最新更新 / 创建时间）
- (void)rebuildSortChips {
    [self clearChipStack:self.sortChipStack];
    for (NSDictionary *item in SortOptionItems()) {
        NSString *key = item[@"key"];
        NSString *title = item[@"title"];
        BOOL isSelected = [self.selectedSort isEqualToString:key];
        UIButton *chip = [self createFilterChipWithTitle:title selected:isSelected];
        chip.accessibilityIdentifier = key; // 用 accessibilityIdentifier 存储 sort key
        [chip addTarget:self action:@selector(sortChipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.sortChipStack addArrangedSubview:chip];
    }
}

/// 滚动 scrollView 使指定标题的 chip 可见
- (void)scrollToSelectedChipInStack:(UIStackView *)stack withTitle:(NSString *)title {
    if (!title || title.length == 0) return;
    UIScrollView *scrollView = (UIScrollView *)stack.superview;
    if (![scrollView isKindOfClass:[UIScrollView class]]) return;
    for (UIButton *chip in stack.arrangedSubviews) {
        if (![chip isKindOfClass:[UIButton class]]) continue;
        NSString *chipTitle = chip.titleLabel.text;
        if ([chipTitle isEqualToString:title]) {
            CGRect frameInScroll = [chip.superview convertRect:chip.frame toView:scrollView];
            CGFloat targetX = frameInScroll.origin.x - scrollView.bounds.size.width / 2 + frameInScroll.size.width / 2;
            targetX = MAX(0, targetX);
            CGFloat maxOffset = scrollView.contentSize.width - scrollView.bounds.size.width;
            targetX = MIN(targetX, MAX(0, maxOffset));
            [scrollView setContentOffset:CGPointMake(targetX, 0) animated:YES];
            break;
        }
    }
}

#pragma mark - Chip 点击事件处理

/// 下载源 chip 点击：切换 Modrinth / CurseForge，并重新拉取版本列表
- (void)sourceChipTapped:(UIButton *)sender {
    NSInteger newSource = sender.tag;
    if (newSource == self.selectedSource) return; // 未切换则忽略

    // CurseForge 源：检查 API Key 是否已配置
    if (newSource == kSourceCurseForge && ![CurseForgeAPI isAPIKeyConfigured]) {
        [self showSourceAlertWithTitle:localize(@"i18n_str_465", nil)
                                message:localize(@"i18n_str_466", nil)];
        return;
    }

    self.selectedSource = newSource;
    // 更新 chips 选中样式
    for (UIButton *chip in self.sourceChipStack.arrangedSubviews) {
        if (![chip isKindOfClass:[UIButton class]]) continue;
        [self applyChipStyle:chip selected:(chip.tag == self.selectedSource)];
    }
    // 清空已有数据，重新拉取
    self.allVersions = nil;
    self.filteredVersions = nil;
    [self.tableView reloadData];
    [self fetchVersionsFromCurrentSource];
}

/// 游戏版本 chip 点击：切换选中版本，重新筛选
- (void)versionChipTapped:(UIButton *)sender {
    NSString *newVersion = sender.titleLabel.text;
    if ([newVersion isEqualToString:self.selectedGameVersion]) return;
    self.selectedGameVersion = newVersion;
    // 更新 chips 选中样式
    for (UIButton *chip in self.versionChipStack.arrangedSubviews) {
        if (![chip isKindOfClass:[UIButton class]]) continue;
        [self applyChipStyle:chip selected:[chip.titleLabel.text isEqualToString:self.selectedGameVersion]];
    }
    [self applyFiltersAndSort];
}

/// 加载器 chip 点击：切换选中加载器，重新筛选
- (void)loaderChipTapped:(UIButton *)sender {
    NSString *newLoader = sender.titleLabel.text;
    if ([newLoader isEqualToString:self.selectedLoader]) return;
    self.selectedLoader = newLoader;
    // 更新 chips 选中样式
    for (UIButton *chip in self.loaderChipStack.arrangedSubviews) {
        if (![chip isKindOfClass:[UIButton class]]) continue;
        [self applyChipStyle:chip selected:[chip.titleLabel.text isEqualToString:self.selectedLoader]];
    }
    [self applyFiltersAndSort];
}

/// 排序方式 chip 点击：切换排序，重新排序并刷新列表
- (void)sortChipTapped:(UIButton *)sender {
    NSString *newSort = sender.accessibilityIdentifier;
    if (!newSort || [newSort isEqualToString:self.selectedSort]) return;
    self.selectedSort = newSort;
    // 更新 chips 选中样式
    for (UIButton *chip in self.sortChipStack.arrangedSubviews) {
        if (![chip isKindOfClass:[UIButton class]]) continue;
        [self applyChipStyle:chip selected:[chip.accessibilityIdentifier isEqualToString:self.selectedSort]];
    }
    [self applyFiltersAndSort];
}

/// 显示来源切换失败提示
- (void)showSourceAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - TableView 设置

- (void)setupTableView {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    // 启用自动行高，让紧凑卡片自适应内容
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 78;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.tableView registerClass:[ModVersionTableViewCell class] forCellReuseIdentifier:@"ModVersionCell"];
    [self.view addSubview:self.tableView];

    // tableView 紧贴筛选面板下方
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.filterContainerView.bottomAnchor constant:6],
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

#pragma mark - 数据拉取

/// 根据当前选中的下载源拉取版本列表
/// Modrinth 源 → ModrinthAPI；CurseForge 源 → CurseForgeAPI
- (void)fetchVersionsFromCurrentSource {
    [self.activityIndicator startAnimating];

    if (self.selectedSource == kSourceCurseForge) {
        // ===== CurseForge 源 =====
        // CurseForgeAPI.getVersionsForModWithID: 返回 ModVersion 数组（含 CurseForge 的 fileId/projectId）
        [[CurseForgeAPI sharedInstance] getVersionsForModWithID:self.modItem.onlineID
                                                     completion:^(NSArray<ModVersion *> * _Nullable versions, NSError * _Nullable error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self handleVersionsResponse:versions error:error];
            });
        }];
    } else {
        // ===== Modrinth 源（默认）=====
        [[ModrinthAPI sharedInstance] getVersionsForModWithID:self.modItem.onlineID
                                                   completion:^(NSArray<ModVersion *> * _Nullable versions, NSError * _Nullable error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self handleVersionsResponse:versions error:error];
            });
        }];
    }
}

/// 统一处理版本拉取回调
- (void)handleVersionsResponse:(NSArray<ModVersion *> *)versions error:(NSError *)error {
    [self.activityIndicator stopAnimating];
    if (error) {
        NSLog(@"[ModVersionVC] Error fetching versions (source=%ld): %@", (long)self.selectedSource, error);
        // 修复"下载版本点击下载按钮后没有反应"：
        // 之前版本列表拉取失败时仅 NSLog，用户看到空白列表毫无反馈，误以为按钮失灵。
        // 现在补 UIAlertController 提示（与 ShaderVersionViewController 保持一致）。
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_42", nil)
                                                                        message:localize(@"i18n_str_467", nil)
                                                                 preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    if (!versions || versions.count == 0) {
        // 列表为空时也给出反馈，避免用户误以为"按钮无反应"
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_388", nil)
                                                                        message:localize(@"i18n_str_468", nil)
                                                                 preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    self.allVersions = versions;
    [self processFilters];
    [self applyFiltersAndSort];
}

- (void)processFilters {
    // 从版本数据中提取所有可选的游戏版本和加载器
    NSMutableSet<NSString *> *gameVersions = [NSMutableSet setWithObject:localize(@"resman.mods.filter.all", nil)];
    NSMutableSet<NSString *> *loaders = [NSMutableSet setWithObject:localize(@"resman.mods.filter.all", nil)];

    for (ModVersion *version in self.allVersions) {
        for (NSString *gameVersion in version.gameVersions) {
            [gameVersions addObject:gameVersion];
        }
        for (NSString *loader in version.loaders) {
            [loaders addObject:[loader capitalizedString]]; // 首字母大写用于显示
        }
    }

    // 游戏版本按语义版本号降序排列（新的在前），"全部"始终在最前
    self.availableGameVersions = [[gameVersions allObjects] sortedArrayUsingComparator:^NSComparisonResult(NSString *obj1, NSString *obj2) {
        if ([obj1 isEqualToString:@"全部"]) return NSOrderedAscending;
        if ([obj2 isEqualToString:@"全部"]) return NSOrderedDescending;
        return [obj2 compare:obj1 options:NSNumericSearch];
    }];

    // 加载器按字母序排列，"全部"始终在最前
    self.availableLoaders = [[loaders allObjects] sortedArrayUsingSelector:@selector(compare:)];

    // FCL 风格：默认选中"全部"，但如果 preferredGameVersion/preferredLoader
    // 在可选列表中，则自动选中匹配项（让用户无需手动筛选）
    self.selectedGameVersion = self.availableGameVersions.firstObject ?: localize(@"resman.mods.filter.all", nil);
    self.selectedLoader = self.availableLoaders.firstObject ?: localize(@"resman.mods.filter.all", nil);

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
    // 自动选中 preferred 加载器（preferredLoader 是小写如 "fabric"，
    // availableLoaders 是首字母大写如 "Fabric"）
    if (self.preferredLoader.length > 0) {
        NSString *preferredCapitalized = [self.preferredLoader capitalizedString];
        for (NSString *ld in self.availableLoaders) {
            if ([ld caseInsensitiveCompare:preferredCapitalized] == NSOrderedSame) {
                self.selectedLoader = ld;
                break;
            }
        }
    }

    // 重建版本/加载器 chips（从"加载中..."替换为实际数据）
    [self rebuildVersionChips];
    [self rebuildLoaderChips];
}

#pragma mark - 筛选 + 排序

/// 应用筛选 + 排序并刷新表格
/// 先按游戏版本/加载器过滤，再按排序方式排序
- (void)applyFiltersAndSort {
    // ----- 1. 筛选：游戏版本 + 加载器 -----
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(ModVersion *evaluatedObject, NSDictionary *bindings) {
        BOOL gameVersionMatch = [self.selectedGameVersion isEqualToString:@"全部"] ||
                                 [evaluatedObject.gameVersions containsObject:self.selectedGameVersion];
        BOOL loaderMatch = [self.selectedLoader isEqualToString:@"全部"] ||
                            [evaluatedObject.loaders containsObject:self.selectedLoader.lowercaseString];
        return gameVersionMatch && loaderMatch;
    }];
    NSArray<ModVersion *> *filtered = [self.allVersions filteredArrayUsingPredicate:predicate];

    // ----- 2. 排序：按选中的排序方式 -----
    NSArray<ModVersion *> *sorted = [self sortVersions:filtered];

    // ----- 3. FCL 风格：把匹配 preferred 版本+加载器的版本置顶 -----
    // 用户从 profile（如 neoforge + 1.21.1）进入版本列表时，
    // 自动把完全匹配的版本置顶，避免在长列表中手动查找
    if (self.preferredGameVersion.length > 0 || self.preferredLoader.length > 0) {
        NSMutableArray<ModVersion *> *pinned = [NSMutableArray array];
        NSMutableArray<ModVersion *> *rest = [NSMutableArray array];
        for (ModVersion *v in sorted) {
            BOOL versionMatch = (self.preferredGameVersion.length == 0) ||
                                [v.gameVersions containsObject:self.preferredGameVersion];
            BOOL loaderMatch = (self.preferredLoader.length == 0) ||
                               [v.loaders containsObject:self.preferredLoader.lowercaseString];
            if (versionMatch && loaderMatch) {
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

/// 对版本数组按当前选中的排序方式进行排序
- (NSArray<ModVersion *> *)sortVersions:(NSArray<ModVersion *> *)versions {
    if (!versions || versions.count <= 1) return versions;

    // 相关性 / 下载量：保持 API 原始顺序
    // （ModVersion 模型无单版本下载量字段，下载量排序回退为原始顺序，
    //   下载量数据仅存在于项目级别 ModItem.downloads）
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
        } else if ([strongSelf.selectedSort isEqualToString:kSortCreated]) {
            // 创建时间：升序（旧的在前）
            return [d1 compare:d2];
        }
        return NSOrderedSame;
    }];
    return [sorted copy];
}


#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredVersions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ModVersionTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ModVersionCell" forIndexPath:indexPath];
    ModVersion *version = self.filteredVersions[indexPath.row];
    [cell configureWithVersion:version];
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    ModVersion *selectedVersion = self.filteredVersions[indexPath.row];
    if ([self.delegate respondsToSelector:@selector(modVersionViewController:didSelectVersion:)]) {
        [self.delegate modVersionViewController:self didSelectVersion:selectedVersion];
    }
    [self.navigationController popViewControllerAnimated:YES];
}

@end
