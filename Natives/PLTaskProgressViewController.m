#import "utils.h"
#import "PLTaskProgressViewController.h"
#import "DownloadTaskItem.h"
#import "DownloadTaskManager.h"
#import "PLTaskStages.h"
#import "LauncherPreferences.h"
#import "BackgroundManager.h"
#import "ModLoaderIconHelper.h"
#import "IconLoader.h"
#include <math.h>

#pragma mark - 常量与辅助

/// 任务完成后自动最小化的延迟（秒）
static const NSTimeInterval kPLTaskProgressAutoDismissDelay = 1.5;
/// iPad FormSheet 居中卡片尺寸（约 560pt 宽，内容超高内部滚动）
static const CGFloat kPLTaskProgressPadCardWidth = 560.0;
static const CGFloat kPLTaskProgressPadCardHeight = 640.0;

/// 本地化辅助：strings 暂无条目时回退代码内中文默认值
/// （Phase 7 统一补全语言文件后 NSLocalizedString 命中，兜底自动失效）
static NSString *PLTaskProgressText(NSString *key, NSString *fallback) {
    NSString *value = NSLocalizedString(key, @"");
    return [value isEqualToString:key] ? fallback : value;
}

/// 字节格式化（紧凑风格，与下载中心 compactSpeedText 一致）
static NSString *PLFormatBytes(int64_t bytes) {
    double value = (double)bytes;
    if (value < 0.0) value = 0.0;
    if (value < 1024.0) {
        return [NSString stringWithFormat:@"%.0fB", value];
    } else if (value < 1024.0 * 1024.0) {
        return [NSString stringWithFormat:@"%.1fKB", value / 1024.0];
    } else if (value < 1024.0 * 1024.0 * 1024.0) {
        return [NSString stringWithFormat:@"%.1fMB", value / (1024.0 * 1024.0)];
    }
    return [NSString stringWithFormat:@"%.2fGB", value / (1024.0 * 1024.0 * 1024.0)];
}

/// 速率格式化（速率为 0 时返回空串，调用方按需隐藏）
static NSString *PLFormatSpeed(double speed) {
    if (speed <= 0.0) return @"";
    if (speed >= 1024.0 * 1024.0 * 1024.0) {
        return [NSString stringWithFormat:@"%.2fGB/s", speed / (1024.0 * 1024.0 * 1024.0)];
    } else if (speed >= 1024.0 * 1024.0) {
        return [NSString stringWithFormat:@"%.1fMB/s", speed / (1024.0 * 1024.0)];
    } else if (speed >= 1024.0) {
        return [NSString stringWithFormat:@"%.1fKB/s", speed / 1024.0];
    }
    return [NSString stringWithFormat:@"%.0fB/s", speed];
}

/// 时长格式化（ETA 用）；超出合理范围（<1s 或 >1 天）返回 nil 不展示
static NSString *PLFormatDuration(NSTimeInterval seconds) {
    if (seconds < 1.0 || seconds > 86400.0) return nil;
    NSInteger total = (NSInteger)ceil(seconds);
    if (total < 60) {
        return [NSString stringWithFormat:PLTaskProgressText(@"taskProgress.eta.seconds", localize(@"i18n_str_1299", nil)), (long)total];
    }
    NSInteger minutes = total / 60;
    NSInteger secs = total % 60;
    if (minutes < 60) {
        if (secs > 0) {
            return [NSString stringWithFormat:PLTaskProgressText(@"taskProgress.eta.minutesSeconds", localize(@"i18n_str_1300", nil)),
                    (long)minutes, (long)secs];
        }
        return [NSString stringWithFormat:PLTaskProgressText(@"taskProgress.eta.minutes", localize(@"i18n_str_1301", nil)), (long)minutes];
    }
    NSInteger hours = minutes / 60;
    minutes = minutes % 60;
    if (minutes > 0) {
        return [NSString stringWithFormat:PLTaskProgressText(@"taskProgress.eta.hoursMinutes", localize(@"i18n_str_1302", nil)),
                (long)hours, (long)minutes];
    }
    return [NSString stringWithFormat:PLTaskProgressText(@"taskProgress.eta.hours", localize(@"i18n_str_1303", nil)), (long)hours];
}

#pragma mark - 不确定进度流动指示（CAGradientLayer 位移动画）

/// 不确定进度（progress < 0）的流动动画进度条：
/// 用 CAGradientLayer 的 locations 位移动画模拟"流动"效果，无需定时器驱动
@interface PLFlowIndicatorView : UIView
- (void)startFlowing;
- (void)stopFlowing;
@end

@implementation PLFlowIndicatorView

+ (Class)layerClass {
    return [CAGradientLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor tertiarySystemFillColor];
        self.layer.cornerRadius = 2.0;
        self.layer.masksToBounds = YES;
    }
    return self;
}

- (void)startFlowing {
    CAGradientLayer *layer = (CAGradientLayer *)self.layer;
    // 颜色在启动时刷新（accentColor 为可变主题色）
    layer.colors = @[(id)[UIColor tertiarySystemFillColor].CGColor,
                     (id)accentColor().CGColor,
                     (id)[UIColor tertiarySystemFillColor].CGColor];
    if (![layer animationForKey:@"plFlowAnimation"]) {
        CABasicAnimation *flow = [CABasicAnimation animationWithKeyPath:@"locations"];
        flow.fromValue = @[@(-0.8), @(-0.4), @(0.0)];
        flow.toValue = @[@(1.0), @(1.4), @(1.8)];
        flow.duration = 1.2;
        flow.repeatCount = HUGE_VALF;
        [layer addAnimation:flow forKey:@"plFlowAnimation"];
    }
}

- (void)stopFlowing {
    [(CAGradientLayer *)self.layer removeAnimationForKey:@"plFlowAnimation"];
}

@end

#pragma mark - 阶段行视图

/**
 * 单个阶段行：状态图标 + 阶段标题（+「进行中」徽标），
 * 仅运行中阶段展开详情区（当前文件名 / 进度条+速率+百分比 / 双维度 / ETA）。
 * 详情区通过 wrapper 作为垂直 stack 的 arrangedSubview，hidden 时自动收起。
 */
@interface PLTaskStageRowView : UIView

@property (nonatomic, strong) UIImageView *statusIconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *runningBadgeLabel;
@property (nonatomic, strong) UIView *detailWrapperView;
@property (nonatomic, strong) UIStackView *detailStack;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UIStackView *progressRowStack;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) PLFlowIndicatorView *flowView;
@property (nonatomic, strong) UILabel *percentRateLabel;
@property (nonatomic, strong) UILabel *dimsLabel;
@property (nonatomic, strong) UILabel *etaLabel;

/// 当前行绑定的阶段标题 key（阶段结构变化时用于判断是否整行重建）
@property (nonatomic, copy) NSString *stageTitleKey;

/// 配置行内容；overallTask 提供任务级补充数据（字节维度 / 速率 / ETA 估算）
- (void)configureWithStage:(PLTaskStage *)stage overallTask:(DownloadTaskItem *)task;

@end

@implementation PLTaskStageRowView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    UIStackView *verticalStack = [[UIStackView alloc] init];
    verticalStack.axis = UILayoutConstraintAxisVertical;
    verticalStack.spacing = 6.0;
    verticalStack.alignment = UIStackViewAlignmentFill;
    verticalStack.distribution = UIStackViewDistributionFill;
    verticalStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:verticalStack];

    // 标题行：状态图标（20x20）+ 标题 +「进行中」徽标
    self.statusIconView = [[UIImageView alloc] init];
    self.statusIconView.contentMode = UIViewContentModeScaleAspectFit;
    self.statusIconView.image = [UIImage systemImageNamed:@"circle"];
    self.statusIconView.tintColor = [UIColor tertiaryLabelColor];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    self.titleLabel.textColor = [UIColor labelColor];
    self.titleLabel.numberOfLines = 1;
    [self.titleLabel setContentHuggingPriority:249 forAxis:UILayoutConstraintAxisHorizontal];
    [self.titleLabel setContentCompressionResistancePriority:749 forAxis:UILayoutConstraintAxisHorizontal];

    self.runningBadgeLabel = [[UILabel alloc] init];
    self.runningBadgeLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    self.runningBadgeLabel.textColor = [UIColor whiteColor];
    self.runningBadgeLabel.backgroundColor = accentColor();
    self.runningBadgeLabel.layer.cornerRadius = 4.0;
    self.runningBadgeLabel.layer.masksToBounds = YES;
    self.runningBadgeLabel.textAlignment = NSTextAlignmentCenter;
    self.runningBadgeLabel.text = PLTaskProgressText(@"taskProgress.stage.running", localize(@"i18n_str_1265", nil));
    self.runningBadgeLabel.hidden = YES;
    [self.runningBadgeLabel setContentHuggingPriority:251 forAxis:UILayoutConstraintAxisHorizontal];
    [self.runningBadgeLabel setContentCompressionResistancePriority:752 forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *titleRowStack = [[UIStackView alloc] init];
    titleRowStack.axis = UILayoutConstraintAxisHorizontal;
    titleRowStack.spacing = 8.0;
    titleRowStack.alignment = UIStackViewAlignmentCenter;
    [titleRowStack addArrangedSubview:self.statusIconView];
    [titleRowStack addArrangedSubview:self.titleLabel];
    [titleRowStack addArrangedSubview:self.runningBadgeLabel];
    [verticalStack addArrangedSubview:titleRowStack];

    // 详情区（仅运行中展开）：缩进对齐标题文字（图标 20 + 间距 8）
    self.detailWrapperView = [[UIView alloc] init];
    [verticalStack addArrangedSubview:self.detailWrapperView];

    self.detailStack = [[UIStackView alloc] init];
    self.detailStack.axis = UILayoutConstraintAxisVertical;
    self.detailStack.spacing = 5.0;
    self.detailStack.alignment = UIStackViewAlignmentFill;
    self.detailStack.distribution = UIStackViewDistributionFill;
    self.detailStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.detailWrapperView addSubview:self.detailStack];

    // 当前文件名（单行中部截断，长文件名仍能看清首尾）
    self.messageLabel = [[UILabel alloc] init];
    self.messageLabel.font = [UIFont systemFontOfSize:12];
    self.messageLabel.textColor = [UIColor secondaryLabelColor];
    self.messageLabel.numberOfLines = 1;
    self.messageLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.messageLabel.hidden = YES;
    [self.detailStack addArrangedSubview:self.messageLabel];

    // 进度行：进度条（确定）/ 流动动画（不确定）+ 百分比·速率
    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.progressTintColor = accentColor();
    self.progressView.trackTintColor = [UIColor tertiarySystemFillColor];
    [self.progressView setContentHuggingPriority:251 forAxis:UILayoutConstraintAxisHorizontal];

    self.flowView = [[PLFlowIndicatorView alloc] init];
    self.flowView.hidden = YES;
    [self.flowView setContentHuggingPriority:251 forAxis:UILayoutConstraintAxisHorizontal];

    self.percentRateLabel = [[UILabel alloc] init];
    self.percentRateLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    self.percentRateLabel.textColor = [UIColor secondaryLabelColor];
    self.percentRateLabel.textAlignment = NSTextAlignmentRight;
    self.percentRateLabel.numberOfLines = 1;
    [self.percentRateLabel setContentHuggingPriority:252 forAxis:UILayoutConstraintAxisHorizontal];
    [self.percentRateLabel setContentCompressionResistancePriority:752 forAxis:UILayoutConstraintAxisHorizontal];

    self.progressRowStack = [[UIStackView alloc] init];
    self.progressRowStack.axis = UILayoutConstraintAxisHorizontal;
    self.progressRowStack.spacing = 8.0;
    self.progressRowStack.alignment = UIStackViewAlignmentCenter;
    [self.progressRowStack addArrangedSubview:self.progressView];
    [self.progressRowStack addArrangedSubview:self.flowView];
    [self.progressRowStack addArrangedSubview:self.percentRateLabel];
    [self.detailStack addArrangedSubview:self.progressRowStack];

    // 双维度："12/38 个文件 · 45MB/180MB"
    self.dimsLabel = [[UILabel alloc] init];
    self.dimsLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.dimsLabel.textColor = [UIColor secondaryLabelColor];
    self.dimsLabel.numberOfLines = 1;
    self.dimsLabel.hidden = YES;
    [self.detailStack addArrangedSubview:self.dimsLabel];

    // ETA："剩余约 1 分 20 秒"
    self.etaLabel = [[UILabel alloc] init];
    self.etaLabel.font = [UIFont systemFontOfSize:12];
    self.etaLabel.textColor = [UIColor tertiaryLabelColor];
    self.etaLabel.numberOfLines = 1;
    self.etaLabel.hidden = YES;
    [self.detailStack addArrangedSubview:self.etaLabel];

    [NSLayoutConstraint activateConstraints:@[
        [verticalStack.topAnchor constraintEqualToAnchor:self.topAnchor],
        [verticalStack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [verticalStack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [verticalStack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

        [self.statusIconView.widthAnchor constraintEqualToConstant:20],
        [self.statusIconView.heightAnchor constraintEqualToConstant:20],
        [self.runningBadgeLabel.heightAnchor constraintEqualToConstant:16],
        [self.runningBadgeLabel.widthAnchor constraintGreaterThanOrEqualToConstant:28],
        [self.flowView.heightAnchor constraintEqualToConstant:8],

        [self.detailStack.leadingAnchor constraintEqualToAnchor:self.detailWrapperView.leadingAnchor constant:28],
        [self.detailStack.trailingAnchor constraintEqualToAnchor:self.detailWrapperView.trailingAnchor],
        [self.detailStack.topAnchor constraintEqualToAnchor:self.detailWrapperView.topAnchor],
        [self.detailStack.bottomAnchor constraintEqualToAnchor:self.detailWrapperView.bottomAnchor],
    ]];

    // 默认收起，仅运行中阶段展开
    self.detailWrapperView.hidden = YES;
}

- (void)configureWithStage:(PLTaskStage *)stage overallTask:(DownloadTaskItem *)task {
    self.stageTitleKey = stage.title;
    self.titleLabel.text = PLTaskStageTitleDisplay(stage.title);

    // 五态图标：✓绿(完成) / ◐主题色(运行中) / ○灰(未开始) / ✕红(失败) / -灰(跳过)
    NSString *symbol = @"circle";
    UIColor *iconTint = [UIColor tertiaryLabelColor];
    UIColor *titleColor = [UIColor secondaryLabelColor];
    switch (stage.status) {
        case PLTaskStageStatusCompleted:
            symbol = @"checkmark.circle.fill";
            iconTint = [UIColor systemGreenColor];
            titleColor = [UIColor labelColor];
            break;
        case PLTaskStageStatusRunning:
            symbol = @"circle.lefthalf.fill";
            iconTint = accentColor();
            titleColor = [UIColor labelColor];
            break;
        case PLTaskStageStatusFailed:
            symbol = @"xmark.circle.fill";
            iconTint = [UIColor systemRedColor];
            titleColor = [UIColor labelColor];
            break;
        case PLTaskStageStatusSkipped:
            symbol = @"minus.circle";
            break;
        case PLTaskStageStatusPending:
        default:
            break;
    }
    self.statusIconView.image = [UIImage systemImageNamed:symbol];
    self.statusIconView.tintColor = iconTint;
    self.titleLabel.textColor = titleColor;
    self.progressView.progressTintColor = accentColor();

    // 仅运行中阶段展开详情区与「进行中」徽标
    BOOL running = (stage.status == PLTaskStageStatusRunning);
    self.runningBadgeLabel.hidden = !running;
    self.runningBadgeLabel.backgroundColor = accentColor();
    self.detailWrapperView.hidden = !running;
    if (!running) {
        [self.flowView stopFlowing];
        return;
    }

    // message：当前文件名
    self.messageLabel.text = stage.message.length > 0 ? stage.message : nil;
    self.messageLabel.hidden = (stage.message.length == 0);

    // 进度条 + 百分比 + 速率；不确定进度（-1）：流动动画且不显示百分比
    double rate = stage.rateBytesPerSec > 0.0 ? stage.rateBytesPerSec : task.speed;
    NSString *rateText = rate > 0.0 ? PLFormatSpeed(rate) : nil;
    if (stage.progress >= 0.0) {
        double clamped = MIN(1.0, MAX(0.0, stage.progress));
        self.progressView.hidden = NO;
        self.flowView.hidden = YES;
        [self.flowView stopFlowing];
        [self.progressView setProgress:(float)clamped animated:NO];
        NSInteger displayPercent = (stage.status == PLTaskStageStatusCompleted)
            ? 100
            : MIN(99, (NSInteger)floor(clamped * 100.0));
        NSString *percent = [NSString stringWithFormat:@"%ld%%", (long)displayPercent];
        self.percentRateLabel.text = rateText ? [NSString stringWithFormat:@"%@ · %@", percent, rateText] : percent;
    } else {
        self.progressView.hidden = YES;
        self.flowView.hidden = NO;
        [self.flowView startFlowing];
        self.percentRateLabel.text = rateText;
    }
    self.percentRateLabel.hidden = (self.percentRateLabel.text.length == 0);

    // 双维度：文件计数（阶段级）+ 字节（任务级）
    self.dimsLabel.text = [self dimsTextForStage:stage task:task];
    self.dimsLabel.hidden = (self.dimsLabel.text.length == 0);

    // ETA：速率 + 剩余字节可估算时显示
    NSString *eta = [self etaTextForStage:stage task:task];
    self.etaLabel.text = eta;
    self.etaLabel.hidden = (eta.length == 0);
}

/// 双维度文案：优先组合"文件数 + 字节"，仅有其一则单独展示
- (NSString *)dimsTextForStage:(PLTaskStage *)stage task:(DownloadTaskItem *)task {
    BOOL hasFileCount = (stage.totalFileCount > 0);
    BOOL hasBytes = (task.totalSize > 0);
    if (hasFileCount && hasBytes) {
        return [NSString stringWithFormat:PLTaskProgressText(@"taskProgress.fileCount.format", localize(@"i18n_str_1304", nil)),
                (long)stage.completedFileCount, (long)stage.totalFileCount,
                PLFormatBytes(task.downloadedSize), PLFormatBytes(task.totalSize)];
    }
    if (hasFileCount) {
        return [NSString stringWithFormat:PLTaskProgressText(@"taskProgress.fileCount.onlyCount", localize(@"i18n_str_1305", nil)),
                (long)stage.completedFileCount, (long)stage.totalFileCount];
    }
    if (hasBytes) {
        return [NSString stringWithFormat:@"%@/%@",
                PLFormatBytes(task.downloadedSize), PLFormatBytes(task.totalSize)];
    }
    return nil;
}

/// ETA 文案：优先按"剩余字节 / 速率"估算，其次沿用 manager 上报的 estimatedTimeRemaining
- (NSString *)etaTextForStage:(PLTaskStage *)stage task:(DownloadTaskItem *)task {
    double rate = task.speed > 0.0 ? task.speed : stage.rateBytesPerSec;
    NSTimeInterval eta = 0.0;
    if (rate > 0.0 && task.totalSize > 0 && task.downloadedSize >= 0 && task.totalSize > task.downloadedSize) {
        eta = (double)(task.totalSize - task.downloadedSize) / rate;
    } else if (task.estimatedTimeRemaining > 0.0) {
        eta = task.estimatedTimeRemaining;
    } else {
        return nil;
    }
    NSString *duration = PLFormatDuration(eta);
    if (!duration) return nil;
    return [NSString stringWithFormat:PLTaskProgressText(@"taskProgress.eta.format", localize(@"i18n_str_1306", nil)), duration];
}

@end

#pragma mark - PLTaskProgressViewController

/// 同屏唯一的活动进度页实例（weak：dismiss 后自动置空）
static __weak PLTaskProgressViewController *PLTaskProgressActiveInstance = nil;

@interface PLTaskProgressViewController ()

@property (nonatomic, copy, readwrite) NSString *taskId;

// 头部（标题 + 类别图标 + 副标题）
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, copy) NSString *lastIconTaskId;

// 滚动内容区
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *contentStack;
@property (nonatomic, strong) UIStackView *stagesStack;
@property (nonatomic, copy) NSArray<PLTaskStageRowView *> *stageRows;

// 错误展示（失败摘要 + 可展开详情）
@property (nonatomic, strong) UILabel *errorSummaryLabel;
@property (nonatomic, strong) UIView *errorDetailContainer;
@property (nonatomic, strong) UILabel *errorDetailTitleLabel;
@property (nonatomic, strong) UILabel *errorDetailBodyLabel;
@property (nonatomic, assign) BOOL errorDetailExpanded;

// 底部（总进度汇总条 + 按钮区）
@property (nonatomic, strong) UIView *footerView;
@property (nonatomic, strong) UILabel *totalTitleLabel;
@property (nonatomic, strong) UILabel *totalValueLabel;
@property (nonatomic, strong) UIProgressView *totalProgressView;
@property (nonatomic, strong) PLFlowIndicatorView *totalFlowView;
@property (nonatomic, strong) UIStackView *buttonStack;
@property (nonatomic, strong) UIButton *minimizeButton;
@property (nonatomic, strong) UIButton *pauseResumeButton;
@property (nonatomic, strong) UIButton *cancelButton;
@property (nonatomic, strong) UIButton *retryButton;
@property (nonatomic, strong) UIButton *detailToggleButton;

@property (nonatomic, assign) BOOL autoDismissScheduled;

/// 同屏单实例支持：原地替换展示的任务（供 presentForTaskId: 调用）
- (void)switchToTaskId:(NSString *)taskId;

@end

@implementation PLTaskProgressViewController

#pragma mark - Lifecycle

- (instancetype)initWithTaskId:(NSString *)taskId {
    self = [super init];
    if (self) {
        _taskId = [taskId copy];
        _autoDismissOnCompletion = YES;
        _errorDetailExpanded = NO;
        _stageRows = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // 适配自定义启动器背景（与下载中心一致）
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // iPad：FormSheet 居中卡片（约 560pt 宽，内容超高内部滚动）；iPhone：PageSheet 近全屏
    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        self.preferredContentSize = CGSizeMake(kPLTaskProgressPadCardWidth, kPLTaskProgressPadCardHeight);
    }

    [self setupFooterView];
    [self setupScrollView];
    [self setupHeader];
    [self setupStageList];
    [self setupErrorSection];
    [self setupNotifications];

    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 页面重新可见时全量刷新（任务状态可能在最小化期间变化）
    [self refresh];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Setup

- (void)setupScrollView {
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:self.scrollView];

    self.contentStack = [[UIStackView alloc] init];
    self.contentStack.axis = UILayoutConstraintAxisVertical;
    self.contentStack.spacing = 18.0;
    self.contentStack.alignment = UIStackViewAlignmentFill;
    self.contentStack.distribution = UIStackViewDistributionFill;
    self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentStack.layoutMarginsRelativeArrangement = YES;
    self.contentStack.layoutMargins = UIEdgeInsetsMake(20, 20, 12, 20);
    [self.scrollView addSubview:self.contentStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.footerView.topAnchor],

        [self.contentStack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor],
        [self.contentStack.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor],
        [self.contentStack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor],
        // 宽度跟随滚动区可视宽度（内容不横向滚动）
        [self.contentStack.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor],
    ]];
}

- (void)setupHeader {
    UIView *headerContainer = [[UIView alloc] init];
    [self.contentStack addArrangedSubview:headerContainer];

    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.tintColor = accentColor();
    [headerContainer addSubview:self.iconView];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    self.titleLabel.textColor = [UIColor labelColor];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.numberOfLines = 0;
    [headerContainer addSubview:self.titleLabel];

    self.subtitleLabel = [[UILabel alloc] init];
    self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.subtitleLabel.font = [UIFont systemFontOfSize:13];
    self.subtitleLabel.textColor = [UIColor secondaryLabelColor];
    self.subtitleLabel.textAlignment = NSTextAlignmentCenter;
    self.subtitleLabel.numberOfLines = 1;
    [headerContainer addSubview:self.subtitleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.topAnchor constraintEqualToAnchor:headerContainer.topAnchor],
        [self.iconView.centerXAnchor constraintEqualToAnchor:headerContainer.centerXAnchor],
        [self.iconView.widthAnchor constraintEqualToConstant:44],
        [self.iconView.heightAnchor constraintEqualToConstant:44],

        [self.titleLabel.topAnchor constraintEqualToAnchor:self.iconView.bottomAnchor constant:10],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:headerContainer.leadingAnchor],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:headerContainer.trailingAnchor],

        [self.subtitleLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:4],
        [self.subtitleLabel.leadingAnchor constraintEqualToAnchor:headerContainer.leadingAnchor],
        [self.subtitleLabel.trailingAnchor constraintEqualToAnchor:headerContainer.trailingAnchor],
        [self.subtitleLabel.bottomAnchor constraintEqualToAnchor:headerContainer.bottomAnchor],
    ]];
}

- (void)setupStageList {
    self.stagesStack = [[UIStackView alloc] init];
    self.stagesStack.axis = UILayoutConstraintAxisVertical;
    self.stagesStack.spacing = 14.0;
    self.stagesStack.alignment = UIStackViewAlignmentFill;
    self.stagesStack.distribution = UIStackViewDistributionFill;
    [self.contentStack addArrangedSubview:self.stagesStack];
}

- (void)setupErrorSection {
    // 失败摘要（多行，始终随失败态显示）
    self.errorSummaryLabel = [[UILabel alloc] init];
    self.errorSummaryLabel.font = [UIFont systemFontOfSize:13];
    self.errorSummaryLabel.textColor = [UIColor systemRedColor];
    self.errorSummaryLabel.numberOfLines = 0;
    self.errorSummaryLabel.hidden = YES;
    [self.contentStack addArrangedSubview:self.errorSummaryLabel];

    // 完整错误详情（「查看详情」按钮展开）
    self.errorDetailContainer = [[UIView alloc] init];
    self.errorDetailContainer.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.errorDetailContainer.layer.cornerRadius = 12.0;
    self.errorDetailContainer.layer.masksToBounds = YES;
    self.errorDetailContainer.hidden = YES;
    [self.contentStack addArrangedSubview:self.errorDetailContainer];

    self.errorDetailTitleLabel = [[UILabel alloc] init];
    self.errorDetailTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.errorDetailTitleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.errorDetailTitleLabel.textColor = [UIColor labelColor];
    self.errorDetailTitleLabel.text = PLTaskProgressText(@"taskProgress.errorDetail.title", localize(@"i18n_str_1307", nil));
    [self.errorDetailContainer addSubview:self.errorDetailTitleLabel];

    self.errorDetailBodyLabel = [[UILabel alloc] init];
    self.errorDetailBodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.errorDetailBodyLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.errorDetailBodyLabel.textColor = [UIColor secondaryLabelColor];
    self.errorDetailBodyLabel.numberOfLines = 0;
    [self.errorDetailContainer addSubview:self.errorDetailBodyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.errorDetailTitleLabel.topAnchor constraintEqualToAnchor:self.errorDetailContainer.topAnchor constant:12],
        [self.errorDetailTitleLabel.leadingAnchor constraintEqualToAnchor:self.errorDetailContainer.leadingAnchor constant:14],
        [self.errorDetailTitleLabel.trailingAnchor constraintEqualToAnchor:self.errorDetailContainer.trailingAnchor constant:-14],

        [self.errorDetailBodyLabel.topAnchor constraintEqualToAnchor:self.errorDetailTitleLabel.bottomAnchor constant:6],
        [self.errorDetailBodyLabel.leadingAnchor constraintEqualToAnchor:self.errorDetailContainer.leadingAnchor constant:14],
        [self.errorDetailBodyLabel.trailingAnchor constraintEqualToAnchor:self.errorDetailContainer.trailingAnchor constant:-14],
        [self.errorDetailBodyLabel.bottomAnchor constraintEqualToAnchor:self.errorDetailContainer.bottomAnchor constant:-12],
    ]];
}

- (void)setupFooterView {
    self.footerView = [[UIView alloc] init];
    self.footerView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.footerView];

    // 总进度汇总卡片
    UIView *totalCard = [[UIView alloc] init];
    totalCard.translatesAutoresizingMaskIntoConstraints = NO;
    totalCard.backgroundColor = [UIColor secondarySystemBackgroundColor];
    totalCard.layer.cornerRadius = 12.0;
    totalCard.layer.masksToBounds = YES;
    [self.footerView addSubview:totalCard];

    self.totalTitleLabel = [[UILabel alloc] init];
    self.totalTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.totalTitleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.totalTitleLabel.textColor = [UIColor secondaryLabelColor];
    self.totalTitleLabel.text = PLTaskProgressText(@"taskProgress.total.title", localize(@"i18n_str_1308", nil));
    [totalCard addSubview:self.totalTitleLabel];

    self.totalValueLabel = [[UILabel alloc] init];
    self.totalValueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.totalValueLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
    self.totalValueLabel.textColor = [UIColor labelColor];
    self.totalValueLabel.textAlignment = NSTextAlignmentRight;
    [totalCard addSubview:self.totalValueLabel];

    self.totalProgressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.totalProgressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.totalProgressView.progressTintColor = accentColor();
    self.totalProgressView.trackTintColor = [UIColor tertiarySystemFillColor];
    [totalCard addSubview:self.totalProgressView];

    // 流动动画条与普通进度条同位置叠放（不确定进度时互斥显示）
    self.totalFlowView = [[PLFlowIndicatorView alloc] init];
    self.totalFlowView.translatesAutoresizingMaskIntoConstraints = NO;
    self.totalFlowView.hidden = YES;
    [totalCard addSubview:self.totalFlowView];

    // 底部按钮区（最小化在左，动态操作按钮在右）
    self.buttonStack = [[UIStackView alloc] init];
    self.buttonStack.axis = UILayoutConstraintAxisHorizontal;
    self.buttonStack.spacing = 8.0;
    self.buttonStack.alignment = UIStackViewAlignmentFill;
    self.buttonStack.distribution = UIStackViewDistributionFill;
    self.buttonStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.footerView addSubview:self.buttonStack];

    self.minimizeButton = [self makeFooterButton];
    self.minimizeButton.backgroundColor = [UIColor systemGrayColor];
    [self.minimizeButton setTitle:PLTaskProgressText(@"taskProgress.button.minimize", localize(@"i18n_str_1309", nil)) forState:UIControlStateNormal];
    [self.minimizeButton addTarget:self action:@selector(minimizeTapped) forControlEvents:UIControlEventTouchUpInside];

    UIView *spacer = [[UIView alloc] init];
    [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow - 1 forAxis:UILayoutConstraintAxisHorizontal];
    [spacer setContentCompressionResistancePriority:UILayoutPriorityDefaultLow - 1 forAxis:UILayoutConstraintAxisHorizontal];

    self.detailToggleButton = [self makeFooterButton];
    self.detailToggleButton.backgroundColor = accentColor();
    [self.detailToggleButton addTarget:self action:@selector(detailToggleTapped) forControlEvents:UIControlEventTouchUpInside];

    self.retryButton = [self makeFooterButton];
    self.retryButton.backgroundColor = accentColor();
    [self.retryButton addTarget:self action:@selector(retryTapped) forControlEvents:UIControlEventTouchUpInside];

    self.pauseResumeButton = [self makeFooterButton];
    self.pauseResumeButton.backgroundColor = accentColor();
    [self.pauseResumeButton addTarget:self action:@selector(pauseResumeTapped) forControlEvents:UIControlEventTouchUpInside];

    self.cancelButton = [self makeFooterButton];
    self.cancelButton.backgroundColor = [UIColor systemRedColor];
    [self.cancelButton setTitle:PLTaskProgressText(@"taskProgress.button.cancel", localize(@"resman.common.cancel", nil)) forState:UIControlStateNormal];
    [self.cancelButton addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];

    [self.buttonStack addArrangedSubview:self.minimizeButton];
    [self.buttonStack addArrangedSubview:spacer];
    [self.buttonStack addArrangedSubview:self.detailToggleButton];
    [self.buttonStack addArrangedSubview:self.retryButton];
    [self.buttonStack addArrangedSubview:self.pauseResumeButton];
    [self.buttonStack addArrangedSubview:self.cancelButton];

    // 初始全部隐藏，待刷新时按任务能力显示
    self.detailToggleButton.hidden = YES;
    self.retryButton.hidden = YES;
    self.pauseResumeButton.hidden = YES;
    self.cancelButton.hidden = YES;

    [NSLayoutConstraint activateConstraints:@[
        [self.footerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.footerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.footerView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],

        [totalCard.topAnchor constraintEqualToAnchor:self.footerView.topAnchor],
        [totalCard.leadingAnchor constraintEqualToAnchor:self.footerView.leadingAnchor],
        [totalCard.trailingAnchor constraintEqualToAnchor:self.footerView.trailingAnchor],

        [self.totalTitleLabel.topAnchor constraintEqualToAnchor:totalCard.topAnchor constant:10],
        [self.totalTitleLabel.leadingAnchor constraintEqualToAnchor:totalCard.leadingAnchor constant:12],
        [self.totalValueLabel.centerYAnchor constraintEqualToAnchor:self.totalTitleLabel.centerYAnchor],
        [self.totalValueLabel.trailingAnchor constraintEqualToAnchor:totalCard.trailingAnchor constant:-12],
        [self.totalValueLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.totalTitleLabel.trailingAnchor constant:8],

        [self.totalProgressView.topAnchor constraintEqualToAnchor:self.totalTitleLabel.bottomAnchor constant:8],
        [self.totalProgressView.leadingAnchor constraintEqualToAnchor:totalCard.leadingAnchor constant:12],
        [self.totalProgressView.trailingAnchor constraintEqualToAnchor:totalCard.trailingAnchor constant:-12],
        [totalCard.bottomAnchor constraintEqualToAnchor:self.totalProgressView.bottomAnchor constant:10],

        [self.totalFlowView.centerYAnchor constraintEqualToAnchor:self.totalProgressView.centerYAnchor],
        [self.totalFlowView.leadingAnchor constraintEqualToAnchor:self.totalProgressView.leadingAnchor],
        [self.totalFlowView.trailingAnchor constraintEqualToAnchor:self.totalProgressView.trailingAnchor],
        [self.totalFlowView.heightAnchor constraintEqualToConstant:8],

        [self.buttonStack.topAnchor constraintEqualToAnchor:totalCard.bottomAnchor constant:12],
        [self.buttonStack.leadingAnchor constraintEqualToAnchor:self.footerView.leadingAnchor],
        [self.buttonStack.trailingAnchor constraintEqualToAnchor:self.footerView.trailingAnchor],
        [self.buttonStack.bottomAnchor constraintEqualToAnchor:self.footerView.bottomAnchor],
    ]];
}

- (UIButton *)makeFooterButton {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    button.contentEdgeInsets = UIEdgeInsetsMake(8, 14, 8, 14);
    button.layer.cornerRadius = 10.0;
    button.layer.masksToBounds = YES;
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    return button;
}

- (void)setupNotifications {
    // 仅刷新自身 taskId 匹配的任务（userInfo 携带 DownloadTaskManagerTaskKey → item）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleTaskUpdateNotification:)
                                                 name:DownloadTaskManagerDidUpdateTaskNotification
                                               object:nil];
}

#pragma mark - Public（弹出入口）

+ (void)presentForTaskId:(NSString *)taskId {
    if (taskId.length == 0) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentForTaskId:taskId];
        });
        return;
    }

    // 同屏已有进度页：展示相同任务直接返回，不同任务原地替换（不再叠加弹出）
    PLTaskProgressViewController *active = PLTaskProgressActiveInstance;
    if (active && (active.view.window != nil || active.isBeingPresented)) {
        if (![active.taskId isEqualToString:taskId]) {
            [active switchToTaskId:taskId];
        }
        return;
    }

    UIViewController *topVC = [self pl_topMostViewController];
    if (!topVC) return;

    PLTaskProgressViewController *vc = [[PLTaskProgressViewController alloc] initWithTaskId:taskId];
    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        // iPad：FormSheet 居中卡片（约 560pt 宽）
        vc.modalPresentationStyle = UIModalPresentationFormSheet;
        vc.preferredContentSize = CGSizeMake(kPLTaskProgressPadCardWidth, kPLTaskProgressPadCardHeight);
    } else {
        // iPhone：PageSheet 近全屏模态
        vc.modalPresentationStyle = UIModalPresentationPageSheet;
    }

    PLTaskProgressActiveInstance = vc;
    [topVC presentViewController:vc animated:YES completion:nil];
}

/// 从 keyWindow 根视图控制器逐层找出最顶层 VC（含已 present 的页面）
+ (UIViewController *)pl_topMostViewController {
    UIWindow *keyWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                keyWindow = scene.windows.firstObject;
                break;
            }
        }
    }
    if (!keyWindow) {
        keyWindow = [[UIApplication sharedApplication] windows].firstObject;
    }
    UIViewController *top = keyWindow.rootViewController;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    return top;
}

#pragma mark - 刷新

- (void)refresh {
    DownloadTaskItem *task = [[DownloadTaskManager sharedManager] taskWithId:self.taskId];
    [self refreshWithTask:task];
}

- (void)refreshWithTask:(nullable DownloadTaskItem *)task {
    if (!task) {
        // 任务已从 manager 移除（如下载中心手动移除记录）：仅保留最小化按钮
        [self configureButtonsForTask:nil];
        return;
    }
    [self configureHeaderForTask:task];
    [self refreshStageRowsForTask:task];
    [self configureErrorSectionForTask:task];
    [self configureTotalProgressForTask:task];
    [self configureButtonsForTask:task];
    [self scheduleAutoDismissIfNeededForTask:task];
}

- (void)handleTaskUpdateNotification:(NSNotification *)notification {
    DownloadTaskItem *item = notification.userInfo[DownloadTaskManagerTaskKey];
    if (!item || ![item.taskId isEqualToString:self.taskId]) return;
    // 主队列刷新 UI（沿用现有 VC 的通知监听模式）
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshWithTask:item];
    });
}

- (void)switchToTaskId:(NSString *)taskId {
    if ([self.taskId isEqualToString:taskId]) return;
    self.taskId = [taskId copy];
    self.autoDismissScheduled = NO;
    self.errorDetailExpanded = NO;
    self.lastIconTaskId = nil;
    // 清空阶段行，强制按新任务结构重建
    for (UIView *row in [self.stagesStack.arrangedSubviews copy]) {
        [self.stagesStack removeArrangedSubview:row];
        [row removeFromSuperview];
    }
    self.stageRows = @[];
    [self refresh];
}

#pragma mark - 头部

- (void)configureHeaderForTask:(DownloadTaskItem *)task {
    self.titleLabel.text = task.displayName.length > 0 ? task.displayName : task.resourceName;

    // 副标题：类别 · 状态 · 阶段计数（如 "整合包 · 下载中 · 3/6"）
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:[self categoryNameForType:task.resourceType]];
    [parts addObject:[self stateTextForTask:task]];
    if (task.currentStage != nil && task.stages.count > 0) {
        [parts addObject:[NSString stringWithFormat:@"%ld/%lu",
                           (long)task.currentStageIndex + 1, (unsigned long)task.stages.count]];
    }
    self.subtitleLabel.text = [parts componentsJoinedByString:@" · "];

    // 图标仅在任务切换时重新加载（避免异步回调闪烁）
    if (![self.lastIconTaskId isEqualToString:task.taskId]) {
        self.lastIconTaskId = task.taskId;
        [self configureIconWithTask:task];
    }
}

/// 类别图标：Minecraft 本体/加载器优先品牌图标（与下载中心卡片一致），其余用类别 SF Symbol
- (void)configureIconWithTask:(DownloadTaskItem *)task {
    UIImage *placeholder = nil;
    NSString *loaderTag = nil;

    if ([task.resourceType isEqualToString:DownloadTaskResourceTypeMinecraft]) {
        loaderTag = @"vanilla";
        placeholder = [ModLoaderIconHelper iconImageForLoader:loaderTag
                                              traitCollection:self.traitCollection];
        [ModLoaderIconHelper configureImageView:self.iconView
                                       forLoader:loaderTag
                                  traitCollection:self.traitCollection];
    } else if ([task.resourceType isEqualToString:DownloadTaskResourceTypeModloader]) {
        // resourceName 通常已带 loader 标识（如 "fabric-1.20.1-0.15.7"）
        NSString *candidate = task.resourceName.length > 0 ? task.resourceName : task.displayName;
        loaderTag = [ModLoaderIconHelper detectLoaderFromVersionId:candidate];
        if (loaderTag.length > 0) {
            placeholder = [ModLoaderIconHelper iconImageForLoader:loaderTag
                                                  traitCollection:self.traitCollection];
            [ModLoaderIconHelper configureImageView:self.iconView
                                           forLoader:loaderTag
                                      traitCollection:self.traitCollection];
        } else {
            placeholder = [UIImage systemImageNamed:[self iconNameForType:task.resourceType]];
            self.iconView.image = placeholder;
            self.iconView.tintColor = [UIColor secondaryLabelColor];
        }
    } else {
        placeholder = [UIImage systemImageNamed:[self iconNameForType:task.resourceType]];
        self.iconView.image = placeholder;
        self.iconView.tintColor = [UIColor secondaryLabelColor];
    }

    if (task.iconURL.length > 0) {
        [IconLoader loadIconForImageView:self.iconView
                                     URL:task.iconURL
                             placeholder:placeholder
                                fallback:placeholder
                               targetSize:CGSizeMake(44, 44)];
    } else {
        [IconLoader cancelLoadingForImageView:self.iconView];
    }
}

- (NSString *)categoryNameForType:(NSString *)type {
    NSDictionary *map = @{
        DownloadTaskResourceTypeMinecraft: localize(@"i18n_str_113", nil),
        DownloadTaskResourceTypeModloader: localize(@"i18n_str_114", nil),
        DownloadTaskResourceTypeMod: @"Mod",
        DownloadTaskResourceTypeShader: localize(@"i18n_str_115", nil),
        DownloadTaskResourceTypeResourcePack: localize(@"i18n_str_116", nil),
        DownloadTaskResourceTypeDataPack: localize(@"i18n_str_117", nil),
        DownloadTaskResourceTypeModpack: localize(@"i18n_str_118", nil),
        DownloadTaskResourceTypeJavaRuntime: localize(@"i18n_str_120", nil)
    };
    return map[type] ?: type ?: localize(@"i18n_str_121", nil);
}

- (NSString *)iconNameForType:(NSString *)type {
    NSDictionary *map = @{
        DownloadTaskResourceTypeMinecraft: @"cube.box.fill",
        DownloadTaskResourceTypeModloader: @"wrench.and.screwdriver",
        DownloadTaskResourceTypeMod: @"puzzlepiece.extension",
        DownloadTaskResourceTypeShader: @"sun.max",
        DownloadTaskResourceTypeResourcePack: @"photo",
        DownloadTaskResourceTypeDataPack: @"archivebox",
        DownloadTaskResourceTypeModpack: @"shippingbox",
        DownloadTaskResourceTypeJavaRuntime: @"cpu"
    };
    return map[type] ?: @"arrow.down.circle";
}

- (NSString *)stateTextForTask:(DownloadTaskItem *)task {
    switch (task.state) {
        case DownloadTaskStatePending:
            return PLTaskProgressText(@"taskProgress.state.pending", localize(@"i18n_str_124", nil));
        case DownloadTaskStateDownloading:
            return [task.userInfo[DownloadTaskUserInfoTransferCompleteKey] boolValue]
                ? localize(@"i18n_str_78", nil)
                : PLTaskProgressText(@"taskProgress.state.downloading", localize(@"i18n_str_138", nil));
        case DownloadTaskStatePaused:
            return PLTaskProgressText(@"taskProgress.state.paused", localize(@"i18n_str_125", nil));
        case DownloadTaskStateCompleted:
            return PLTaskProgressText(@"taskProgress.state.completed", localize(@"i18n_str_126", nil));
        case DownloadTaskStateCancelled:
            return PLTaskProgressText(@"taskProgress.state.cancelled", localize(@"i18n_str_127", nil));
        case DownloadTaskStateFailed:
            return PLTaskProgressText(@"taskProgress.state.failed", localize(@"i18n_str_108", nil));
    }
}

#pragma mark - 阶段列表

- (void)refreshStageRowsForTask:(DownloadTaskItem *)task {
    NSArray<PLTaskStage *> *stages = task.stages;
    if (stages.count == 0) {
        // 无阶段信息（旧快照回退 / 未接入阶段上报的任务）：虚拟单阶段纯进度展示
        stages = @[[self fallbackStageForTask:task]];
    }

    // 阶段结构变化（数量或标题 key 变化）时整行重建，否则原地更新（保留流动动画状态）
    BOOL needsRebuild = (self.stageRows.count != stages.count);
    if (!needsRebuild) {
        for (NSUInteger i = 0; i < stages.count; i++) {
            if (![self.stageRows[i].stageTitleKey isEqualToString:stages[i].title]) {
                needsRebuild = YES;
                break;
            }
        }
    }
    if (needsRebuild) {
        for (UIView *row in [self.stagesStack.arrangedSubviews copy]) {
            [self.stagesStack removeArrangedSubview:row];
            [row removeFromSuperview];
        }
        NSMutableArray<PLTaskStageRowView *> *rows = [NSMutableArray array];
        for (PLTaskStage *stage in stages) {
            PLTaskStageRowView *row = [[PLTaskStageRowView alloc] init];
            [self.stagesStack addArrangedSubview:row];
            [rows addObject:row];
        }
        self.stageRows = [rows copy];
    }

    for (NSUInteger i = 0; i < stages.count; i++) {
        [self.stageRows[i] configureWithStage:stages[i] overallTask:task];
    }
}

/// 无阶段信息任务的虚拟阶段（单文件下载语义），映射任务级进度/速率/文件计数
- (PLTaskStage *)fallbackStageForTask:(DownloadTaskItem *)task {
    PLTaskStage *stage = [[PLTaskStage alloc] initWithTitle:PLTaskStageTitleDownloadFile
                                                   iconName:@"arrow.down.circle"];
    switch (task.state) {
        case DownloadTaskStateCompleted:
            stage.status = PLTaskStageStatusCompleted;
            stage.progress = 1.0;
            break;
        case DownloadTaskStateDownloading:
            stage.status = PLTaskStageStatusRunning;
            stage.progress = task.progress;
            break;
        case DownloadTaskStateFailed:
            stage.status = PLTaskStageStatusFailed;
            break;
        default:
            // Pending / Paused / Cancelled：保持未开始（灰圈）
            break;
    }
    stage.rateBytesPerSec = task.speed;
    stage.completedFileCount = task.completedFileCount;
    stage.totalFileCount = task.totalFileCount;
    return stage;
}

#pragma mark - 错误展示

- (void)configureErrorSectionForTask:(DownloadTaskItem *)task {
    BOOL terminalFailed = (task.state == DownloadTaskStateFailed || task.state == DownloadTaskStateCancelled);
    NSError *error = task.errorInfo;

    // 失败摘要：优先错误描述，无错误信息时显示状态文字
    if (terminalFailed) {
        self.errorSummaryLabel.text = (error.localizedDescription.length > 0)
            ? error.localizedDescription
            : [self stateTextForTask:task];
        self.errorSummaryLabel.hidden = NO;
    } else {
        self.errorSummaryLabel.text = nil;
        self.errorSummaryLabel.hidden = YES;
    }

    // 完整错误详情（可展开）：domain/code、底层错误、已重试次数、当前阶段名
    if (error) {
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        [lines addObject:[NSString stringWithFormat:PLTaskProgressText(@"taskProgress.errorDetail.domainCode", localize(@"i18n_str_1310", nil)),
                          error.domain ?: @"-", (long)error.code]];
        NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
        if ([underlying isKindOfClass:[NSError class]] && underlying.localizedDescription.length > 0) {
            [lines addObject:[NSString stringWithFormat:PLTaskProgressText(@"taskProgress.errorDetail.underlying", localize(@"i18n_str_1311", nil)),
                              underlying.localizedDescription]];
        }
        [lines addObject:[NSString stringWithFormat:PLTaskProgressText(@"taskProgress.errorDetail.retry", localize(@"i18n_str_1312", nil)),
                          (long)task.retryCount, (long)task.maxRetryCount]];
        NSString *stageName = [self failedStageDisplayNameForTask:task];
        if (stageName.length > 0) {
            [lines addObject:[NSString stringWithFormat:PLTaskProgressText(@"taskProgress.errorDetail.stage", localize(@"i18n_str_1313", nil)),
                              stageName]];
        }
        self.errorDetailBodyLabel.text = [lines componentsJoinedByString:@"\n"];
    } else {
        self.errorDetailBodyLabel.text = nil;
    }
    [self updateErrorDetailVisibility];
}

/// 失败时的当前阶段名：优先取 Failed 状态的阶段，其次 currentStage
- (NSString *)failedStageDisplayNameForTask:(DownloadTaskItem *)task {
    for (PLTaskStage *stage in task.stages) {
        if (stage.status == PLTaskStageStatusFailed) {
            return PLTaskStageTitleDisplay(stage.title);
        }
    }
    PLTaskStage *current = task.currentStage;
    return current ? PLTaskStageTitleDisplay(current.title) : nil;
}

- (void)updateErrorDetailVisibility {
    BOOL show = self.errorDetailExpanded && self.errorDetailBodyLabel.text.length > 0;
    self.errorDetailContainer.hidden = !show;
}

- (void)updateDetailToggleTitle {
    NSString *title = self.errorDetailExpanded
        ? PLTaskProgressText(@"taskProgress.button.hideDetail", localize(@"i18n_str_1314", nil))
        : PLTaskProgressText(@"taskProgress.button.viewDetail", localize(@"i18n_str_19", nil));
    [self.detailToggleButton setTitle:title forState:UIControlStateNormal];
}

#pragma mark - 总进度汇总

- (void)configureTotalProgressForTask:(DownloadTaskItem *)task {
    self.totalProgressView.progressTintColor = accentColor();

    double overall = [self overallProgressForTask:task];
    double rate = [self effectiveRateForTask:task];
    NSString *rateText = rate > 0.0 ? PLFormatSpeed(rate) : nil;

    if (overall >= 0.0) {
        self.totalProgressView.hidden = NO;
        self.totalFlowView.hidden = YES;
        [self.totalFlowView stopFlowing];
        [self.totalProgressView setProgress:(float)MIN(1.0, MAX(0.0, overall)) animated:NO];
        double clampedOverall = MIN(1.0, MAX(0.0, overall));
        NSInteger displayPercent = (task.state == DownloadTaskStateCompleted)
            ? 100
            : MIN(99, (NSInteger)floor(clampedOverall * 100.0));
        NSString *percent = [NSString stringWithFormat:@"%ld%%", (long)displayPercent];
        self.totalValueLabel.text = rateText ? [NSString stringWithFormat:@"%@ · %@", percent, rateText] : percent;
    } else {
        // 不确定进度：流动动画，不显示百分比
        self.totalProgressView.hidden = YES;
        self.totalFlowView.hidden = NO;
        [self.totalFlowView startFlowing];
        self.totalValueLabel.text = rateText ?: PLTaskProgressText(@"taskProgress.total.indeterminate", localize(@"i18n_str_1265", nil));
    }
}

/// 全部阶段加权汇总进度（每阶段等权；Skipped 计满；不确定的运行中阶段按半程估算）
- (double)overallProgressForTask:(DownloadTaskItem *)task {
    if (task.stages.count == 0) {
        return task.progress; // 可能为 -1（不确定），由调用方处理
    }
    double sum = 0.0;
    for (PLTaskStage *stage in task.stages) {
        switch (stage.status) {
            case PLTaskStageStatusCompleted:
            case PLTaskStageStatusSkipped:
                sum += 1.0;
                break;
            case PLTaskStageStatusRunning: {
                double p = stage.progress;
                sum += (p >= 0.0) ? MIN(1.0, MAX(0.0, p)) : 0.5;
                break;
            }
            default:
                // Pending / Failed 不计入
                break;
        }
    }
    return sum / (double)task.stages.count;
}

/// 实时速率：优先汇总运行中阶段的上报速率，回退任务级 speed
- (double)effectiveRateForTask:(DownloadTaskItem *)task {
    double stageRate = 0.0;
    for (PLTaskStage *stage in task.stages) {
        if (stage.status == PLTaskStageStatusRunning) {
            stageRate += stage.rateBytesPerSec;
        }
    }
    return stageRate > 0.0 ? stageRate : task.speed;
}

#pragma mark - 按钮区

- (void)configureButtonsForTask:(nullable DownloadTaskItem *)task {
    // 最小化始终可用
    self.minimizeButton.hidden = NO;

    if (!task) {
        self.pauseResumeButton.hidden = YES;
        self.cancelButton.hidden = YES;
        self.retryButton.hidden = YES;
        self.detailToggleButton.hidden = YES;
        return;
    }

    // 暂停（运行中/排队中且支持断点续传）/ 继续（已暂停且支持恢复）
    NSString *pauseResumeTitle = nil;
    if (task.state == DownloadTaskStateDownloading || task.state == DownloadTaskStatePending) {
        if (task.supportsResume) {
            pauseResumeTitle = PLTaskProgressText(@"taskProgress.button.pause", localize(@"i18n_str_128", nil));
        }
    } else if (task.state == DownloadTaskStatePaused) {
        if (task.supportsResume) {
            pauseResumeTitle = PLTaskProgressText(@"taskProgress.button.resume", localize(@"i18n_str_129", nil));
        }
    }
    self.pauseResumeButton.hidden = (pauseResumeTitle == nil);
    if (pauseResumeTitle) {
        [self.pauseResumeButton setTitle:pauseResumeTitle forState:UIControlStateNormal];
    }

    // 取消：未到终态的任务均可取消（运行中/排队中/已暂停）
    BOOL showCancel = (task.state == DownloadTaskStateDownloading ||
                       task.state == DownloadTaskStatePending ||
                       task.state == DownloadTaskStatePaused);
    self.cancelButton.hidden = !showCancel;

    // 重试：失败/取消且重试能力可用（retryHandler 存在且未超上限）
    BOOL canRetry = (task.retryHandler != nil) &&
                    (task.maxRetryCount <= 0 || task.retryCount < task.maxRetryCount);
    BOOL showRetry = (task.state == DownloadTaskStateFailed || task.state == DownloadTaskStateCancelled) && canRetry;
    self.retryButton.hidden = !showRetry;
    if (showRetry) {
        if (task.retryCount > 0) {
            [self.retryButton setTitle:[NSString stringWithFormat:PLTaskProgressText(@"taskProgress.button.retryWithCount", localize(@"i18n_str_1315", nil)),
                                         (long)task.retryCount, (long)task.maxRetryCount]
                              forState:UIControlStateNormal];
        } else {
            [self.retryButton setTitle:PLTaskProgressText(@"taskProgress.button.retry", localize(@"i18n_str_21", nil)) forState:UIControlStateNormal];
        }
    }

    // 查看详情：失败/取消且携带错误信息
    BOOL showDetail = (task.state == DownloadTaskStateFailed || task.state == DownloadTaskStateCancelled) &&
                      (task.errorInfo != nil);
    self.detailToggleButton.hidden = !showDetail;
    if (showDetail) {
        [self updateDetailToggleTitle];
    }

    // 主题色实时跟随（用户切换强调色后无需重启页面）
    self.pauseResumeButton.backgroundColor = accentColor();
    self.retryButton.backgroundColor = accentColor();
    self.detailToggleButton.backgroundColor = accentColor();
}

/// 任务完成且开启自动最小化时，延迟 1.5s dismiss（期间用户可查看终态）
- (void)scheduleAutoDismissIfNeededForTask:(DownloadTaskItem *)task {
    if (task.state != DownloadTaskStateCompleted) return;
    if (!self.autoDismissOnCompletion || self.autoDismissScheduled) return;
    self.autoDismissScheduled = YES;

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPLTaskProgressAutoDismissDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        // 仅当页面仍在展示，且任务仍处于完成态（或已被移除）时自动最小化；
        // 若期间已切换到其他任务则不关闭
        DownloadTaskItem *latest = [[DownloadTaskManager sharedManager] taskWithId:strongSelf.taskId];
        BOOL stillCompleted = (!latest || latest.state == DownloadTaskStateCompleted);
        if (stillCompleted && strongSelf.view.window != nil) {
            [strongSelf dismissViewControllerAnimated:YES completion:nil];
        }
    });
}

#pragma mark - Actions

- (void)minimizeTapped {
    // 最小化：仅关闭进度页，任务后台继续；从下载中心点击卡片可重新打开
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)pauseResumeTapped {
    DownloadTaskItem *task = [[DownloadTaskManager sharedManager] taskWithId:self.taskId];
    if (!task) return;
    if (task.state == DownloadTaskStateDownloading || task.state == DownloadTaskStatePending) {
        [[DownloadTaskManager sharedManager] pauseTaskWithId:self.taskId];
    } else if (task.state == DownloadTaskStatePaused) {
        [[DownloadTaskManager sharedManager] resumeTaskWithId:self.taskId];
    }
}

- (void)cancelTapped {
    [[DownloadTaskManager sharedManager] cancelTaskWithId:self.taskId];
}

- (void)retryTapped {
    [[DownloadTaskManager sharedManager] retryTaskWithId:self.taskId];
}

- (void)detailToggleTapped {
    self.errorDetailExpanded = !self.errorDetailExpanded;
    [self updateErrorDetailVisibility];
    [self updateDetailToggleTitle];
}

@end
