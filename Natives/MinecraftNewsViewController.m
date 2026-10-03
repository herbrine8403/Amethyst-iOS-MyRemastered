//
//  MinecraftNewsViewController.m
//  Amethyst
//

#import "MinecraftNewsViewController.h"
#import "MinecraftNewsService.h"
#import "MinecraftNewsItem.h"
#import "BackgroundManager.h"
#import "IconLoader.h"
#import <SafariServices/SafariServices.h>

/// 缩略图目标尺寸（用于 IconLoader 降采样）
static const CGFloat kNewsThumbnailTargetWidth = 400.0;
/// 卡片间距
static const CGFloat kNewsCardSpacing = 12.0;
/// 卡片内边距
static const CGFloat kNewsCardPadding = 12.0;
/// 卡片圆角
static const CGFloat kNewsCardCornerRadius = 12.0;
/// 缩略图圆角
static const CGFloat kNewsThumbnailCornerRadius = 8.0;
/// 每页条数
static const NSInteger kNewsPageSize = 24;

#pragma mark - MCNewsCollectionViewCell

@interface MCNewsCollectionViewCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *thumbnailView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *metaLabel;     // 作者 + 时间
@property (nonatomic, strong) UILabel *summaryLabel;
@property (nonatomic, strong) UILabel *readMoreLabel; // "查看详情"按钮
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, copy) NSString *currentImageURL;
@property (nonatomic, copy) NSString *currentArticleURL;
@end

@implementation MCNewsCollectionViewCell

- (void)prepareForReuse {
    [super prepareForReuse];
    [IconLoader cancelLoadingForImageView:self.thumbnailView];
    self.thumbnailView.image = [UIImage systemImageNamed:@"newspaper.fill"];
    self.thumbnailView.tintColor = [UIColor secondaryLabelColor];
    self.titleLabel.text = nil;
    self.metaLabel.text = nil;
    self.summaryLabel.text = nil;
    self.currentImageURL = nil;
    self.currentArticleURL = nil;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.contentView.backgroundColor = [UIColor clearColor];

        // 卡片背景：设为 clearColor，由 BackgroundManager.applyEffectToCollectionViewCell: 注入毛玻璃/半透明
        self.backgroundColor = [UIColor clearColor];
        self.layer.cornerRadius = kNewsCardCornerRadius;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.clipsToBounds = YES;
        // contentView 也要圆角匹配，让注入的 blurView 圆角一致
        self.contentView.layer.cornerRadius = kNewsCardCornerRadius;
        self.contentView.layer.cornerCurve = kCACornerCurveContinuous;
        self.contentView.clipsToBounds = YES;

        // 缩略图
        _thumbnailView = [[UIImageView alloc] init];
        _thumbnailView.translatesAutoresizingMaskIntoConstraints = NO;
        _thumbnailView.contentMode = UIViewContentModeScaleAspectFill;
        _thumbnailView.clipsToBounds = YES;
        _thumbnailView.layer.cornerRadius = kNewsThumbnailCornerRadius;
        _thumbnailView.layer.cornerCurve = kCACornerCurveContinuous;
        _thumbnailView.backgroundColor = [UIColor secondarySystemBackgroundColor];
        _thumbnailView.image = [UIImage systemImageNamed:@"newspaper.fill"];
        _thumbnailView.tintColor = [UIColor secondaryLabelColor];
        [self.contentView addSubview:_thumbnailView];

        // 加载指示器（封面图加载时显示）
        _loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
        _loadingIndicator.hidesWhenStopped = YES;
        [_thumbnailView addSubview:_loadingIndicator];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [UIColor labelColor];
        _titleLabel.numberOfLines = 3;
        [self.contentView addSubview:_titleLabel];

        _metaLabel = [[UILabel alloc] init];
        _metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _metaLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
        _metaLabel.textColor = [UIColor tertiaryLabelColor];
        _metaLabel.numberOfLines = 1;
        [self.contentView addSubview:_metaLabel];

        _summaryLabel = [[UILabel alloc] init];
        _summaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _summaryLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        _summaryLabel.textColor = [UIColor secondaryLabelColor];
        _summaryLabel.numberOfLines = 4;
        [self.contentView addSubview:_summaryLabel];

        _readMoreLabel = [[UILabel alloc] init];
        _readMoreLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _readMoreLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        _readMoreLabel.textColor = [UIColor systemBlueColor];
        _readMoreLabel.text = NSLocalizedString(@"mc_news.read_more", @"查看详情");
        _readMoreLabel.textAlignment = NSTextAlignmentRight;
        [self.contentView addSubview:_readMoreLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_thumbnailView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:kNewsCardPadding],
            [_thumbnailView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:kNewsCardPadding],
            [_thumbnailView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-kNewsCardPadding],
            [_thumbnailView.heightAnchor constraintEqualToConstant:140],

            [_loadingIndicator.centerXAnchor constraintEqualToAnchor:_thumbnailView.centerXAnchor],
            [_loadingIndicator.centerYAnchor constraintEqualToAnchor:_thumbnailView.centerYAnchor],

            [_titleLabel.topAnchor constraintEqualToAnchor:_thumbnailView.bottomAnchor constant:8],
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:kNewsCardPadding],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-kNewsCardPadding],

            [_metaLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:4],
            [_metaLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_metaLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],

            [_summaryLabel.topAnchor constraintEqualToAnchor:_metaLabel.bottomAnchor constant:6],
            [_summaryLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_summaryLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],

            [_readMoreLabel.topAnchor constraintEqualToAnchor:_summaryLabel.bottomAnchor constant:6],
            [_readMoreLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_readMoreLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
            [_readMoreLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-kNewsCardPadding],
        ]];
    }
    return self;
}

- (void)configureWithItem:(MinecraftNewsItem *)item {
    self.titleLabel.text = item.title ?: @"";
    self.summaryLabel.text = item.summary ?: @"";

    NSString *author = item.author.length > 0 ? item.author : @"Minecraft";
    NSString *dateStr = item.formattedDateString;
    if (dateStr.length > 0) {
        self.metaLabel.text = [NSString stringWithFormat:@"%@ · %@", author, dateStr];
    } else {
        self.metaLabel.text = author;
    }

    self.currentArticleURL = item.articleURL;
    self.currentImageURL = item.imageURL;

    if (item.imageURL.length > 0) {
        [_loadingIndicator startAnimating];
        UIImage *placeholder = [UIImage systemImageNamed:@"newspaper.fill"];
        [IconLoader loadIconForImageView:_thumbnailView
                                     URL:item.imageURL
                             placeholder:placeholder
                                fallback:placeholder
                            targetSize:CGSizeMake(kNewsThumbnailTargetWidth, 200)
                                options:IconLoaderOptionsDefault
                             completion:^(UIImage *image) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_loadingIndicator stopAnimating];
            });
        }];
    }
}

@end

#pragma mark - MinecraftNewsViewController

@interface MinecraftNewsViewController () <UICollectionViewDataSource, UICollectionViewDelegate, SFSafariViewControllerDelegate>
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property (nonatomic, strong) UILabel *errorLabel;
@property (nonatomic, strong) UIButton *retryButton;
@property (nonatomic, strong) NSMutableArray<MinecraftNewsItem *> *items;
@property (nonatomic, assign) NSInteger totalCount;
@property (nonatomic, assign) NSInteger currentPage;
@property (nonatomic, assign) BOOL isLoading;
@property (nonatomic, assign) BOOL hasMore;
@property (nonatomic, strong) UIRefreshControl *refreshControl;
@property (nonatomic, strong) UIView *footerLoadingView;
@end

@implementation MinecraftNewsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = NSLocalizedString(@"mc_news.title", @"Minecraft 新闻");
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // ★ [LAND-BUG] 本页只由首页(MinecraftNews tile)以 UIModalPresentationPageSheet 整页弹出，
    //   且原先没有设置任何 navigationItem（无关闭/返回）⇒ iPhone 上 PageSheet 铺满全屏时
    //   只剩「下滑手势」这一条退出路径，横屏/无明显抓手时用户会认为「退不出去」。
    //   在此补一个标准「关闭」按钮（与 AnnouncementListViewController 一致）。
    UIBarButtonItem *landBugCloseItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                                      target:self
                                                                                      action:@selector(landBugCloseTapped)];
    landBugCloseItem.accessibilityLabel = @"关闭";
    self.navigationItem.leftBarButtonItem = landBugCloseItem;

    // 适配自定义启动器背景
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    self.items = [NSMutableArray array];
    self.currentPage = 0;
    self.hasMore = YES;

    [self setupUI];
    // 透明化 collectionView 背景与 cell 背景，避免遮挡全局背景
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.backgroundView = nil;

    // 监听背景效果变化通知
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    [self loadFirstPage];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.backgroundView = nil;
    [self.collectionView reloadData];
}

- (void)setupUI {
    // 双列瀑布流布局（用 CompositionalLayout 的 estimateSize 实现 PCL-CE WaterfallPanel 类似效果）
    UICollectionViewLayout *layout = [self createCompositionalLayout];
    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.alwaysBounceVertical = YES;
    [self.collectionView registerClass:[MCNewsCollectionViewCell class] forCellWithReuseIdentifier:@"NewsCell"];
    self.collectionView.contentInset = UIEdgeInsetsMake(8, 8, 8, 8);
    [self.view addSubview:self.collectionView];

    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(pullToRefresh) forControlEvents:UIControlEventValueChanged];
    [self.collectionView addSubview:self.refreshControl];

    self.activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.activityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.activityIndicator.hidesWhenStopped = YES;
    [self.view addSubview:self.activityIndicator];

    self.errorLabel = [[UILabel alloc] init];
    self.errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.errorLabel.textColor = [UIColor secondaryLabelColor];
    self.errorLabel.textAlignment = NSTextAlignmentCenter;
    self.errorLabel.numberOfLines = 0;
    self.errorLabel.hidden = YES;
    [self.view addSubview:self.errorLabel];

    self.retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.retryButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.retryButton setTitle:NSLocalizedString(@"mc_news.retry", @"重试") forState:UIControlStateNormal];
    self.retryButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [self.retryButton addTarget:self action:@selector(loadFirstPage) forControlEvents:UIControlEventTouchUpInside];
    self.retryButton.hidden = YES;
    [self.view addSubview:self.retryButton];

    // 底部加载更多指示器
    self.footerLoadingView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 50)];
    UIActivityIndicatorView *footerIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    footerIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    footerIndicator.hidesWhenStopped = YES;
    [footerIndicator startAnimating];
    [self.footerLoadingView addSubview:footerIndicator];
    [NSLayoutConstraint activateConstraints:@[
        [footerIndicator.centerXAnchor constraintEqualToAnchor:self.footerLoadingView.centerXAnchor],
        [footerIndicator.centerYAnchor constraintEqualToAnchor:self.footerLoadingView.centerYAnchor],
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [self.collectionView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.activityIndicator.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.activityIndicator.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],

        [self.errorLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.errorLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-20],
        [self.errorLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:32],
        [self.errorLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-32],

        [self.retryButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.retryButton.topAnchor constraintEqualToAnchor:self.errorLabel.bottomAnchor constant:12],
    ]];
}

/// 双列自适应瀑布流布局（每列宽度相同，cell 高度由内容估算）
- (UICollectionViewLayout *)createCompositionalLayout {
    UICollectionViewCompositionalLayoutConfiguration *config = [[UICollectionViewCompositionalLayoutConfiguration alloc] init];
    config.interSectionSpacing = kNewsCardSpacing;
    config.scrollDirection = UICollectionViewScrollDirectionVertical;

    // section provider block 接收两个参数：sectionIndex 和 layoutEnvironment
    // 构造方法为 -initWithSectionProvider:configuration:（不是 +layoutWithConfiguration:sectionProvider:）
    return [[UICollectionViewCompositionalLayout alloc] initWithSectionProvider:^NSCollectionLayoutSection *(NSInteger sectionIndex, id<NSCollectionLayoutEnvironment> env) {
        // 双列布局，每列等宽
        NSCollectionLayoutSize *itemSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:0.5]
                                                                            heightDimension:[NSCollectionLayoutDimension estimatedDimension:280]];
        NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:itemSize];

        NSCollectionLayoutGroup *group = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:[NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                                                                                                                                             heightDimension:[NSCollectionLayoutDimension estimatedDimension:280]]
                                                                                      subitems:@[item]];
        group.interItemSpacing = [NSCollectionLayoutSpacing fixedSpacing:kNewsCardSpacing];

        NSCollectionLayoutSection *section = [NSCollectionLayoutSection sectionWithGroup:group];
        section.interGroupSpacing = kNewsCardSpacing;
        section.contentInsets = NSDirectionalEdgeInsetsMake(0, 0, 0, 0);
        return section;
    } configuration:config];
}

#pragma mark - Data Loading

- (void)loadFirstPage {
    if (self.isLoading) return;
    self.isLoading = YES;
    self.currentPage = 0;
    self.hasMore = YES;
    [self.items removeAllObjects];
    [self.collectionView reloadData];

    if (self.currentPage == 0) {
        self.errorLabel.hidden = YES;
        self.retryButton.hidden = YES;
        [self.activityIndicator startAnimating];
    }

    __weak typeof(self) weakSelf = self;
    [[MinecraftNewsService sharedService] fetchLatestNewsWithCompletion:^(NSArray<MinecraftNewsItem *> *items, NSInteger totalCount, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.isLoading = NO;
        [strongSelf.activityIndicator stopAnimating];
        [strongSelf.refreshControl endRefreshing];

        if (error) {
            if (strongSelf.items.count == 0) {
                strongSelf.errorLabel.text = [NSString stringWithFormat:@"%@\n%@", NSLocalizedString(@"mc_news.load_failed", @"加载失败"), error.localizedDescription ?: @""];
                strongSelf.errorLabel.hidden = NO;
                strongSelf.retryButton.hidden = NO;
            }
            return;
        }

        [strongSelf.items addObjectsFromArray:items];
        strongSelf.totalCount = totalCount;
        strongSelf.currentPage = 1;
        strongSelf.hasMore = (strongSelf.items.count < totalCount) && (items.count > 0);
        strongSelf.errorLabel.hidden = YES;
        strongSelf.retryButton.hidden = YES;
        [strongSelf.collectionView reloadData];
    }];
}

- (void)loadNextPage {
    if (self.isLoading || !self.hasMore) return;
    self.isLoading = YES;
    self.footerLoadingView.hidden = NO;

    NSInteger nextPage = self.currentPage + 1;
    __weak typeof(self) weakSelf = self;
    [[MinecraftNewsService sharedService] fetchNewsWithPage:nextPage pageSize:kNewsPageSize completion:^(NSArray<MinecraftNewsItem *> *items, NSInteger totalCount, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.isLoading = NO;
        strongSelf.footerLoadingView.hidden = YES;

        if (error || items.count == 0) {
            strongSelf.hasMore = NO;
            return;
        }

        NSInteger oldCount = strongSelf.items.count;
        [strongSelf.items addObjectsFromArray:items];
        strongSelf.currentPage = nextPage;
        strongSelf.hasMore = (strongSelf.items.count < totalCount);

        // 增量插入新行
        NSMutableArray<NSIndexPath *> *indexPaths = [NSMutableArray array];
        for (NSInteger i = oldCount; i < strongSelf.items.count; i++) {
            [indexPaths addObject:[NSIndexPath indexPathForItem:i inSection:0]];
        }
        [strongSelf.collectionView insertItemsAtIndexPaths:indexPaths];
    }];
}

- (void)pullToRefresh {
    [self loadFirstPage];
}

#pragma mark - UICollectionView DataSource

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.items.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    MCNewsCollectionViewCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"NewsCell" forIndexPath:indexPath];
    MinecraftNewsItem *item = self.items[indexPath.item];
    [cell configureWithItem:item];
    // 适配自定义启动器背景：为 cell 注入毛玻璃/半透明效果
    [[BackgroundManager sharedManager] applyEffectToCollectionViewCell:cell];
    return cell;
}

#pragma mark - UICollectionView Delegate

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];
    MinecraftNewsItem *item = self.items[indexPath.item];
    [self openArticleURL:item.articleURL];
}

/// 滚动接近底部时自动加载下一页
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    CGFloat offsetY = scrollView.contentOffset.y;
    CGFloat contentHeight = scrollView.contentSize.height;
    CGFloat threshold = contentHeight - scrollView.bounds.size.height - 300;
    if (offsetY > threshold && offsetY > 0) {
        [self loadNextPage];
    }
}

/// 用 SFSafariViewController 内嵌打开文章页（不跳出 App）
- (void)openArticleURL:(NSString *)urlString {
    if (urlString.length == 0) return;
    if (![MinecraftNewsService isSafeNewsLink:urlString]) {
        // 非白名单链接直接忽略（参考 PCL-CE IsSafeNewsLink 安全过滤）
        return;
    }
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    SFSafariViewController *safari = [[SFSafariViewController alloc] initWithURL:url];
    safari.delegate = self;
    safari.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:safari animated:YES completion:nil];
}

#pragma mark - SFSafariViewControllerDelegate

- (void)safariViewControllerDidFinish:(SFSafariViewController *)controller {
    [controller dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - ★ [LAND-BUG] 关闭

- (void)landBugCloseTapped {
    UINavigationController *nav = self.navigationController;
    if (nav.presentingViewController) {
        [nav dismissViewControllerAnimated:YES completion:nil];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

@end
