#import "utils.h"
#import "DownloadTasksViewController.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "LauncherPreferences.h"
#import "BackgroundManager.h"
#import "IconLoader.h"
#import "ModLoaderIconHelper.h"
#import "DownloadHistoryViewController.h"
#import "PLTaskStages.h"
#import "PLTaskProgressViewController.h"
#include <math.h>

static NSString * const kTaskCellReuseIdentifier = @"DownloadTaskCell";
static NSString * const kEmptyStateReuseIdentifier = @"DownloadTaskEmptyCell";

static const CGFloat kCardCornerRadius = 16.0;
static const CGFloat kCardSpacing = 12.0;
static const CGFloat kSectionInset = 16.0;

@interface DownloadTaskCell : UICollectionViewCell

@property (nonatomic, strong) UIImageView *iconImageView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *typeTagLabel;
@property (nonatomic, strong) UIButton *sourceTagButton;
@property (nonatomic, strong) UILabel *speedLabel;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UILabel *progressLabel;
@property (nonatomic, strong) UIView *separatorView;

// 阶段信息行（redesign-download-ui Task 2.4）：当前阶段名 + "3/6" 阶段计数；
// 无阶段信息（stages 为空或 currentStageIndex 无效）时整行收起
@property (nonatomic, strong) UILabel *stageTitleLabel;
@property (nonatomic, strong) UILabel *stageCountLabel;
@property (nonatomic, strong) NSLayoutConstraint *stageHeightConstraint;
@property (nonatomic, strong) NSLayoutConstraint *progressTopConstraint;

// FCL 风格操作按钮区（直接显示在卡片上，无需长按）
@property (nonatomic, strong) UIButton *primaryActionButton;   // 暂停/继续/重试（主操作，蓝色）
@property (nonatomic, strong) UIButton *secondaryActionButton; // 取消/移除（次操作，红色）
@property (nonatomic, weak) DownloadTaskItem *currentTask;

- (void)configureWithTask:(DownloadTaskItem *)task;

@end

@implementation DownloadTaskCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    self.contentView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.contentView.layer.cornerRadius = kCardCornerRadius;
    self.contentView.layer.masksToBounds = YES;

    self.iconImageView = [[UIImageView alloc] init];
    self.iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconImageView.layer.cornerRadius = 8.0;
    self.iconImageView.layer.masksToBounds = YES;
    self.iconImageView.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    self.iconImageView.tintColor = [UIColor secondaryLabelColor];
    [self.contentView addSubview:self.iconImageView];

    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.nameLabel.font = [UIFont boldSystemFontOfSize:15];
    self.nameLabel.textColor = [UIColor labelColor];
    self.nameLabel.numberOfLines = 1;
    [self.contentView addSubview:self.nameLabel];

    self.typeTagLabel = [[UILabel alloc] init];
    self.typeTagLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.typeTagLabel.font = [UIFont systemFontOfSize:10];
    self.typeTagLabel.textColor = [UIColor whiteColor];
    self.typeTagLabel.backgroundColor = [UIColor systemBlueColor];
    self.typeTagLabel.layer.cornerRadius = 4.0;
    self.typeTagLabel.layer.masksToBounds = YES;
    self.typeTagLabel.textAlignment = NSTextAlignmentCenter;
    [self.contentView addSubview:self.typeTagLabel];

    self.sourceTagButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.sourceTagButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.sourceTagButton.titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    self.sourceTagButton.contentEdgeInsets = UIEdgeInsetsMake(2, 6, 2, 6);
    self.sourceTagButton.layer.cornerRadius = 4.0;
    self.sourceTagButton.layer.masksToBounds = YES;
    self.sourceTagButton.userInteractionEnabled = NO;
    [self.contentView addSubview:self.sourceTagButton];

    self.speedLabel = [[UILabel alloc] init];
    self.speedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.speedLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.speedLabel.textColor = [UIColor secondaryLabelColor];
    self.speedLabel.textAlignment = NSTextAlignmentRight;
    self.speedLabel.numberOfLines = 1;
    [self.contentView addSubview:self.speedLabel];

    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressView.progressTintColor = [UIColor systemBlueColor];
    self.progressView.trackTintColor = [UIColor tertiarySystemBackgroundColor];
    [self.contentView addSubview:self.progressView];

    self.progressLabel = [[UILabel alloc] init];
    self.progressLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
    self.progressLabel.textColor = [UIColor labelColor];
    self.progressLabel.textAlignment = NSTextAlignmentRight;
    self.progressLabel.numberOfLines = 1;
    [self.contentView addSubview:self.progressLabel];

    self.separatorView = [[UIView alloc] init];
    self.separatorView.translatesAutoresizingMaskIntoConstraints = NO;
    self.separatorView.backgroundColor = [UIColor separatorColor];
    [self.contentView addSubview:self.separatorView];

    // 阶段信息行：左侧当前阶段名（单行截断）+ 右侧阶段计数（如 "3/6"）
    self.stageTitleLabel = [[UILabel alloc] init];
    self.stageTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.stageTitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.stageTitleLabel.textColor = [UIColor secondaryLabelColor];
    self.stageTitleLabel.numberOfLines = 1;
    self.stageTitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:self.stageTitleLabel];

    self.stageCountLabel = [[UILabel alloc] init];
    self.stageCountLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.stageCountLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    self.stageCountLabel.textColor = [UIColor secondaryLabelColor];
    self.stageCountLabel.textAlignment = NSTextAlignmentRight;
    self.stageCountLabel.numberOfLines = 1;
    [self.contentView addSubview:self.stageCountLabel];

    // 阶段行高度约束（无阶段信息时置 0 收起）
    self.stageHeightConstraint = [self.stageTitleLabel.heightAnchor constraintEqualToConstant:16.0];
    // 进度条顶部约束（有阶段信息时位于阶段行下方，无阶段信息时回到紧贴分隔线）
    self.progressTopConstraint = [self.progressView.topAnchor constraintEqualToAnchor:self.stageTitleLabel.bottomAnchor constant:6.0];

    // FCL 风格：主操作按钮（暂停/继续/重试），右侧靠齐
    self.primaryActionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.primaryActionButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.primaryActionButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.primaryActionButton.contentEdgeInsets = UIEdgeInsetsMake(4, 10, 4, 10);
    self.primaryActionButton.layer.cornerRadius = 8.0;
    self.primaryActionButton.layer.masksToBounds = YES;
    [self.primaryActionButton addTarget:self action:@selector(primaryActionTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:self.primaryActionButton];

    // FCL 风格：次操作按钮（取消/移除）
    self.secondaryActionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.secondaryActionButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.secondaryActionButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.secondaryActionButton.contentEdgeInsets = UIEdgeInsetsMake(4, 10, 4, 10);
    self.secondaryActionButton.layer.cornerRadius = 8.0;
    self.secondaryActionButton.layer.masksToBounds = YES;
    [self.secondaryActionButton addTarget:self action:@selector(secondaryActionTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:self.secondaryActionButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.iconImageView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
        [self.iconImageView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
        [self.iconImageView.widthAnchor constraintEqualToConstant:44],
        [self.iconImageView.heightAnchor constraintEqualToConstant:44],

        [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.iconImageView.trailingAnchor constant:10],
        [self.nameLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
        [self.nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-12],

        [self.typeTagLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [self.typeTagLabel.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:5],
        [self.typeTagLabel.heightAnchor constraintEqualToConstant:16],
        [self.typeTagLabel.widthAnchor constraintGreaterThanOrEqualToConstant:32],

        [self.sourceTagButton.leadingAnchor constraintEqualToAnchor:self.typeTagLabel.trailingAnchor constant:6],
        [self.sourceTagButton.centerYAnchor constraintEqualToAnchor:self.typeTagLabel.centerYAnchor],
        [self.sourceTagButton.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-12],

        [self.speedLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
        [self.speedLabel.centerYAnchor constraintEqualToAnchor:self.typeTagLabel.centerYAnchor],
        [self.speedLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.sourceTagButton.trailingAnchor constant:8],

        [self.separatorView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
        [self.separatorView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
        [self.separatorView.topAnchor constraintEqualToAnchor:self.iconImageView.bottomAnchor constant:10],
        [self.separatorView.heightAnchor constraintEqualToConstant:0.5],

        // 阶段信息行：位于分隔线下方、进度条上方
        [self.stageTitleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
        [self.stageTitleLabel.topAnchor constraintEqualToAnchor:self.separatorView.bottomAnchor constant:6],
        [self.stageTitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.stageCountLabel.leadingAnchor constant:-8],
        self.stageHeightConstraint,

        [self.stageCountLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
        [self.stageCountLabel.centerYAnchor constraintEqualToAnchor:self.stageTitleLabel.centerYAnchor],

        // 进度区：进度条 + 百分比（顶部约束按是否有阶段信息动态调整间距）
        [self.progressView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
        self.progressTopConstraint,
        [self.progressView.trailingAnchor constraintEqualToAnchor:self.progressLabel.leadingAnchor constant:-8],

        [self.progressLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
        [self.progressLabel.centerYAnchor constraintEqualToAnchor:self.progressView.centerYAnchor],
        [self.progressLabel.widthAnchor constraintEqualToConstant:48],

        // 操作按钮区：右对齐，主操作在前（左），次操作在后（右）
        [self.secondaryActionButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
        [self.secondaryActionButton.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10],
        [self.secondaryActionButton.topAnchor constraintEqualToAnchor:self.progressView.bottomAnchor constant:8],

        [self.primaryActionButton.trailingAnchor constraintEqualToAnchor:self.secondaryActionButton.leadingAnchor constant:-8],
        [self.primaryActionButton.centerYAnchor constraintEqualToAnchor:self.secondaryActionButton.centerYAnchor],
        [self.primaryActionButton.heightAnchor constraintEqualToAnchor:self.secondaryActionButton.heightAnchor]
    ]];
}

- (void)primaryActionTapped {
    if (!self.currentTask) return;
    DownloadTaskItem *task = self.currentTask;
    switch (task.state) {
        case DownloadTaskStateDownloading:
        case DownloadTaskStatePending:
            [[DownloadTaskManager sharedManager] pauseTaskWithId:task.taskId];
            break;
        case DownloadTaskStatePaused:
            [[DownloadTaskManager sharedManager] resumeTaskWithId:task.taskId];
            break;
        case DownloadTaskStateFailed:
        case DownloadTaskStateCancelled:
            [[DownloadTaskManager sharedManager] retryTaskWithId:task.taskId];
            break;
        case DownloadTaskStateCompleted:
            break;
    }
}

- (void)secondaryActionTapped {
    if (!self.currentTask) return;
    DownloadTaskItem *task = self.currentTask;
    if (task.state == DownloadTaskStateCompleted || task.state == DownloadTaskStateCancelled || task.state == DownloadTaskStateFailed) {
        [[DownloadTaskManager sharedManager] removeTaskWithId:task.taskId];
    } else {
        [[DownloadTaskManager sharedManager] cancelTaskWithId:task.taskId];
    }
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.iconImageView.image = nil;
    self.nameLabel.text = nil;
    self.typeTagLabel.text = nil;
    [self.sourceTagButton setTitle:nil forState:UIControlStateNormal];
    self.sourceTagButton.backgroundColor = [UIColor clearColor];
    self.speedLabel.text = nil;
    self.progressView.progress = 0.0;
    self.progressLabel.text = nil;
    self.progressView.hidden = NO;
    self.stageTitleLabel.text = nil;
    self.stageCountLabel.text = nil;
    self.currentTask = nil;
    [self.primaryActionButton setTitle:nil forState:UIControlStateNormal];
    self.primaryActionButton.hidden = YES;
    self.primaryActionButton.userInteractionEnabled = YES;
    [self.secondaryActionButton setTitle:nil forState:UIControlStateNormal];
    self.secondaryActionButton.hidden = YES;
    self.secondaryActionButton.userInteractionEnabled = YES;
}

- (void)configureWithTask:(DownloadTaskItem *)task {
    self.currentTask = task;
    self.nameLabel.text = task.displayName.length > 0 ? task.displayName : task.resourceName;
    self.typeTagLabel.text = [self displayNameForResourceType:task.resourceType];
    [self.typeTagLabel sizeToFit];
    [self configureSourceTagWithSource:task.downloadSource];

    // 图标：Minecraft 本体 / Modloader 使用 ModLoaderIconHelper 加载真实品牌图标
    // （与下载游戏界面 DownloadViewController 保持一致，避免只显示通用 SF Symbol）
    // resourceName 通常已带 loader 标识（如 "fabric-1.20.1-0.15.7" / "optifine-..."），
    // 用 detectLoaderFromVersionId 解析；解析不到则用通用占位符。
    [self configureIconForTask:task];

    // 阶段信息行：当前阶段名（经 PLTaskStageTitleDisplay 本地化渲染）+ 阶段计数（如 "3/6"）。
    // stages 非空且 currentStageIndex 有效（currentStage 非 nil）时展示，否则整行收起回退原布局。
    PLTaskStage *currentStage = task.currentStage;
    BOOL hasStageInfo = (currentStage != nil);
    if (hasStageInfo) {
        self.stageTitleLabel.text = PLTaskStageTitleDisplay(currentStage.title);
        self.stageCountLabel.text = [NSString stringWithFormat:@"%ld/%lu",
                                     (long)task.currentStageIndex + 1, (unsigned long)task.stages.count];
    } else {
        self.stageTitleLabel.text = nil;
        self.stageCountLabel.text = nil;
    }
    self.stageHeightConstraint.constant = hasStageInfo ? 16.0 : 0.0;
    // 有阶段行时进度条距阶段行 6pt；无阶段行时保持原"分隔线下方 8pt"的视觉间距（6+0+2）
    self.progressTopConstraint.constant = hasStageInfo ? 6.0 : 2.0;

    // 速度与进度
    switch (task.state) {
        case DownloadTaskStatePending:
            self.speedLabel.text = localize(@"i18n_str_124", nil);
            self.progressLabel.text = @"--";
            self.progressView.progress = 0.0;
            self.progressView.hidden = NO;
            break;
        case DownloadTaskStateDownloading:
            if ([task.userInfo[DownloadTaskUserInfoTransferCompleteKey] boolValue]) {
                self.speedLabel.text = localize(@"i18n_str_78", nil);
            }
            // Phase 6 Task 6.1：多文件任务显示 "42/100 · 2.1MB/s"（文件计数 + 速率）
            else if (task.totalFileCount > 0) {
                NSString *speedText = [self compactSpeedText:task.speed];
                if (speedText.length > 0) {
                    self.speedLabel.text = [NSString
                        stringWithFormat:NSLocalizedString(@"download.progress.file_count_short",
                                                           @"%1$ld/%2$ld · %3$@"),
                        (long)task.completedFileCount, (long)task.totalFileCount, speedText];
                } else {
                    self.speedLabel.text = [NSString stringWithFormat:@"%ld/%ld",
                                            (long)task.completedFileCount, (long)task.totalFileCount];
                }
            } else {
                self.speedLabel.text = [self formattedSpeed:task.speed];
            }
            self.progressLabel.text = [self formattedProgress:task.progress];
            self.progressView.progress = task.progress >= 0.0 ? (float)task.progress : 0.0;
            self.progressView.hidden = NO;
            break;
        case DownloadTaskStatePaused:
            self.speedLabel.text = localize(@"i18n_str_125", nil);
            self.progressLabel.text = [self formattedProgress:task.progress];
            self.progressView.progress = task.progress >= 0.0 ? (float)task.progress : 0.0;
            self.progressView.hidden = NO;
            break;
        case DownloadTaskStateCompleted:
            self.speedLabel.text = localize(@"i18n_str_126", nil);
            self.progressLabel.text = @"100%";
            self.progressView.progress = 1.0;
            self.progressView.hidden = NO;
            break;
        case DownloadTaskStateCancelled:
            self.speedLabel.text = localize(@"i18n_str_127", nil);
            self.progressLabel.text = @"--";
            self.progressView.progress = 0.0;
            self.progressView.hidden = YES;
            break;
        case DownloadTaskStateFailed:
            self.speedLabel.text = task.errorInfo ? task.errorInfo.localizedDescription : localize(@"i18n_str_108", nil);
            self.progressLabel.text = localize(@"i18n_str_108", nil);
            self.progressView.progress = 0.0;
            self.progressView.hidden = YES;
            break;
    }

    // FCL 风格：按状态配置主/次操作按钮
    [self configureActionButtonsForTask:task];
}

- (void)configureActionButtonsForTask:(DownloadTaskItem *)task {
    UIColor *primaryColor = [UIColor systemBlueColor];
    UIColor *secondaryColor = [UIColor systemRedColor];

    switch (task.state) {
        case DownloadTaskStateDownloading:
        case DownloadTaskStatePending:
            // 主操作：暂停；次操作：取消
            [self.primaryActionButton setTitle:localize(@"i18n_str_128", nil) forState:UIControlStateNormal];
            [self.primaryActionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            self.primaryActionButton.backgroundColor = primaryColor;
            self.primaryActionButton.hidden = NO;

            [self.secondaryActionButton setTitle:localize(@"resman.common.cancel", nil) forState:UIControlStateNormal];
            [self.secondaryActionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            self.secondaryActionButton.backgroundColor = secondaryColor;
            self.secondaryActionButton.hidden = NO;
            break;

        case DownloadTaskStatePaused:
            // 主操作：继续（不可续传时置灰，如 App 重启恢复的暂停任务）；次操作：取消
            if (task.supportsResume) {
                [self.primaryActionButton setTitle:localize(@"i18n_str_129", nil) forState:UIControlStateNormal];
                [self.primaryActionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                self.primaryActionButton.backgroundColor = primaryColor;
                self.primaryActionButton.userInteractionEnabled = YES;
            } else {
                [self.primaryActionButton setTitle:localize(@"i18n_str_130", nil) forState:UIControlStateNormal];
                [self.primaryActionButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
                self.primaryActionButton.backgroundColor = [UIColor tertiarySystemBackgroundColor];
                self.primaryActionButton.userInteractionEnabled = NO;
            }
            self.primaryActionButton.hidden = NO;

            [self.secondaryActionButton setTitle:localize(@"resman.common.cancel", nil) forState:UIControlStateNormal];
            [self.secondaryActionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            self.secondaryActionButton.backgroundColor = secondaryColor;
            self.secondaryActionButton.hidden = NO;
            break;

        case DownloadTaskStateFailed:
        case DownloadTaskStateCancelled: {
            // 主操作：重试（若 retryHandler 可用且未超 maxRetryCount）；次操作：移除
            BOOL canRetry = (task.retryHandler != nil) &&
                            (task.maxRetryCount <= 0 || task.retryCount < task.maxRetryCount);
            if (canRetry) {
                NSString *retryTitle = task.retryCount > 0
                    ? [NSString stringWithFormat:localize(@"i18n_str_131", nil), (long)task.retryCount, (long)task.maxRetryCount]
                    : localize(@"i18n_str_21", nil);
                [self.primaryActionButton setTitle:retryTitle forState:UIControlStateNormal];
                [self.primaryActionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                self.primaryActionButton.backgroundColor = primaryColor;
                self.primaryActionButton.hidden = NO;
            } else if (task.retryHandler != nil && task.retryCount >= task.maxRetryCount && task.maxRetryCount > 0) {
                // 已达最大重试次数，显示禁用状态
                [self.primaryActionButton setTitle:localize(@"i18n_str_132", nil) forState:UIControlStateNormal];
                [self.primaryActionButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
                self.primaryActionButton.backgroundColor = [UIColor tertiarySystemBackgroundColor];
                self.primaryActionButton.userInteractionEnabled = NO;
                self.primaryActionButton.hidden = NO;
            } else {
                self.primaryActionButton.hidden = YES;
            }

            [self.secondaryActionButton setTitle:localize(@"i18n_str_133", nil) forState:UIControlStateNormal];
            [self.secondaryActionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            self.secondaryActionButton.backgroundColor = secondaryColor;
            self.secondaryActionButton.userInteractionEnabled = YES;
            self.secondaryActionButton.hidden = NO;
            break;
        }

        case DownloadTaskStateCompleted:
            // 主操作：无；次操作：移除
            self.primaryActionButton.hidden = YES;

            [self.secondaryActionButton setTitle:localize(@"i18n_str_133", nil) forState:UIControlStateNormal];
            [self.secondaryActionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            self.secondaryActionButton.backgroundColor = [UIColor systemGrayColor];
            self.secondaryActionButton.userInteractionEnabled = YES;
            self.secondaryActionButton.hidden = NO;
            break;
    }
}

// loadIconFromURL: 已移除，改用 IconLoader 统一加载器
// （IconLoader 提供双层缓存+降采样+CDN镜像+并发控制，比原 NSURLSession 直连更高效）

- (NSString *)displayNameForResourceType:(NSString *)type {
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

- (NSString *)iconNameForResourceType:(NSString *)type {
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

/// 为任务配置图标
/// - Minecraft 本体：使用 ModLoaderIconHelper 的 VanillaIcon 草方块（与 VersionCardCell 一致）
/// - Modloader：从 resourceName 解析具体加载器（fabric/forge/neoforge/quilt/optifine），
///   用 ModLoaderIconHelper 加载官方品牌 PNG；解析不到则用通用 SF Symbol
/// - 其他类型：保持原 SF Symbol 占位符逻辑
/// - 若 task.iconURL 非空（如整合包有缩略图），用 IconLoader 异步加载网络图标
- (void)configureIconForTask:(DownloadTaskItem *)task {
    UIImage *placeholder = nil;
    NSString *loaderTag = nil;

    if ([task.resourceType isEqualToString:DownloadTaskResourceTypeMinecraft]) {
        // 原版：用 ModLoaderIconHelper 的 VanillaIcon（与 VersionCardCell 一致）
        loaderTag = @"vanilla";
        placeholder = [ModLoaderIconHelper iconImageForLoader:loaderTag
                                              traitCollection:self.traitCollection];
        [ModLoaderIconHelper configureImageView:self.iconImageView
                                       forLoader:loaderTag
                                  traitCollection:self.traitCollection];
    } else if ([task.resourceType isEqualToString:DownloadTaskResourceTypeModloader]) {
        // 加载器：从 resourceName 解析具体 loader
        // resourceName 格式举例："fabric-1.20.1-0.15.7" / "optifine-1.20.1-..."
        NSString *candidate = task.resourceName.length > 0 ? task.resourceName : task.displayName;
        loaderTag = [ModLoaderIconHelper detectLoaderFromVersionId:candidate];
        if (loaderTag.length > 0) {
            placeholder = [ModLoaderIconHelper iconImageForLoader:loaderTag
                                                  traitCollection:self.traitCollection];
            [ModLoaderIconHelper configureImageView:self.iconImageView
                                           forLoader:loaderTag
                                      traitCollection:self.traitCollection];
        } else {
            // 未识别的加载器：用通用 SF Symbol
            placeholder = [UIImage systemImageNamed:[self iconNameForResourceType:task.resourceType]];
            self.iconImageView.image = placeholder;
            self.iconImageView.tintColor = [UIColor secondaryLabelColor];
        }
    } else {
        placeholder = [UIImage systemImageNamed:[self iconNameForResourceType:task.resourceType]];
        self.iconImageView.image = placeholder;
        self.iconImageView.tintColor = [UIColor secondaryLabelColor];
    }

    if (task.iconURL.length > 0) {
        [IconLoader loadIconForImageView:self.iconImageView
                                     URL:task.iconURL
                             placeholder:placeholder
                                fallback:placeholder
                               targetSize:CGSizeMake(44, 44)];
    } else {
        [IconLoader cancelLoadingForImageView:self.iconImageView];
    }
}

- (NSString *)formattedSpeed:(double)speed {
    if (speed <= 0) {
        return localize(@"i18n_str_134", nil);
    }
    if (speed < 1024.0) {
        return [NSString stringWithFormat:@"%.0f B/s", speed];
    } else if (speed < 1024.0 * 1024.0) {
        return [NSString stringWithFormat:@"%.1f KB/s", speed / 1024.0];
    } else {
        return [NSString stringWithFormat:@"%.2f MB/s", speed / (1024.0 * 1024.0)];
    }
}

/// 紧凑速率文本（Phase 6 Task 6.1：B/KB/MB/GB 1 位小数）；速率为 0 时返回空串（隐藏速率维度）
- (NSString *)compactSpeedText:(double)speed {
    if (speed <= 0) return @"";
    if (speed >= 1024.0 * 1024.0 * 1024.0) {
        return [NSString stringWithFormat:@"%.1fGB/s", speed / (1024.0 * 1024.0 * 1024.0)];
    } else if (speed >= 1024.0 * 1024.0) {
        return [NSString stringWithFormat:@"%.1fMB/s", speed / (1024.0 * 1024.0)];
    } else if (speed >= 1024.0) {
        return [NSString stringWithFormat:@"%.1fKB/s", speed / 1024.0];
    } else {
        return [NSString stringWithFormat:@"%.0fB/s", speed];
    }
}

- (NSString *)formattedProgress:(double)progress {
    if (progress < 0.0) return @"--";
    // 非终态卡片不会走本方法显示 100%；向下截断可避免 99.95% 四舍五入为 100.0%。
    double clamped = MIN(0.999, MAX(0.0, progress));
    double truncated = floor(clamped * 1000.0) / 10.0;
    return [NSString stringWithFormat:@"%.1f%%", truncated];
}

- (void)configureSourceTagWithSource:(NSString *)source {
    NSString *normalized = source.length > 0 ? source.lowercaseString : @"official";
    NSString *title = nil;
    UIColor *backgroundColor = [UIColor systemGrayColor];
    UIColor *textColor = [UIColor whiteColor];

    if ([normalized isEqualToString:@"modrinth"]) {
        title = @"Modrinth";
        backgroundColor = [UIColor colorWithRed:0.18 green:0.80 blue:0.45 alpha:1.0];
    } else if ([normalized isEqualToString:@"curseforge"]) {
        title = @"CurseForge";
        backgroundColor = [UIColor colorWithRed:0.95 green:0.45 blue:0.15 alpha:1.0];
    } else if ([normalized isEqualToString:@"bmclapi"]) {
        title = @"BMCLAPI";
        backgroundColor = [UIColor colorWithRed:0.20 green:0.60 blue:0.90 alpha:1.0];
    } else {
        title = @"Official";
        backgroundColor = [UIColor systemGrayColor];
    }

    [self.sourceTagButton setTitle:title forState:UIControlStateNormal];
    [self.sourceTagButton setTitleColor:textColor forState:UIControlStateNormal];
    self.sourceTagButton.backgroundColor = backgroundColor;
}

@end

#pragma mark - Empty State Cell

@interface DownloadTaskEmptyCell : UICollectionViewCell
@property (nonatomic, strong) UILabel *messageLabel;
@end

@implementation DownloadTaskEmptyCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.messageLabel = [[UILabel alloc] init];
        self.messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.messageLabel.font = [UIFont systemFontOfSize:16];
        self.messageLabel.textColor = [UIColor secondaryLabelColor];
        self.messageLabel.textAlignment = NSTextAlignmentCenter;
        self.messageLabel.numberOfLines = 0;
        self.messageLabel.text = localize(@"i18n_str_135", nil);
        [self.contentView addSubview:self.messageLabel];

        [NSLayoutConstraint activateConstraints:@[
            [self.messageLabel.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
            [self.messageLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [self.messageLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:32],
            [self.messageLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-32]
        ]];
    }
    return self;
}

@end

#pragma mark - View Controller

@interface DownloadTasksViewController () <UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate>

@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIButton *historyButton;
@property (nonatomic, strong) UISegmentedControl *stateSegmentedControl;
@property (nonatomic, strong) UIScrollView *typeScrollView;
@property (nonatomic, strong) UIStackView *typeStackView;
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) UIView *emptyStateView;

@property (nonatomic, copy) NSArray<DownloadTaskItem *> *filteredTasks;
@property (nonatomic, copy) NSArray<NSString *> *resourceTypes;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *typeDisplayNames;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *typeCounts;

@end

@implementation DownloadTasksViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    // 适配自定义启动器背景：将当前视图控制器透明化，使全局背景壁纸能够透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.filterState = DownloadTaskStatePending;
    self.filterType = nil;

    [self setupResourceTypeMetadata];
    [self setupHeaderView];
    [self setupStateFilter];
    [self setupTypeFilter];
    [self setupCollectionView];
    [self setupEmptyStateView];
    [self setupNotifications];

    [self reloadData];

    // 监听背景 UI 效果变化通知，当用户切换背景效果（半透明/毛玻璃）时重新应用透明化
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

/// 背景效果改变时重新应用透明化（由 BackgroundUIEffectChanged 通知触发）
/// 重新设置 collectionView 背景为透明，避免系统在复用过程中重置为不透明色
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.collectionView.backgroundColor = [UIColor clearColor];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadData];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Setup

- (void)setupResourceTypeMetadata {
    self.resourceTypes = @[
        DownloadTaskResourceTypeMinecraft,
        DownloadTaskResourceTypeModloader,
        DownloadTaskResourceTypeMod,
        DownloadTaskResourceTypeShader,
        DownloadTaskResourceTypeResourcePack,
        DownloadTaskResourceTypeDataPack,
        DownloadTaskResourceTypeModpack
    ];
    self.typeDisplayNames = @{
        DownloadTaskResourceTypeMinecraft: localize(@"i18n_str_113", nil),
        DownloadTaskResourceTypeModloader: localize(@"i18n_str_114", nil),
        DownloadTaskResourceTypeMod: @"Mod",
        DownloadTaskResourceTypeShader: localize(@"i18n_str_115", nil),
        DownloadTaskResourceTypeResourcePack: localize(@"i18n_str_116", nil),
        DownloadTaskResourceTypeDataPack: localize(@"i18n_str_117", nil),
        DownloadTaskResourceTypeModpack: localize(@"i18n_str_118", nil)
    };
    self.typeCounts = [NSMutableDictionary dictionary];
}

- (void)setupHeaderView {
    self.headerView = [[UIView alloc] init];
    self.headerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.headerView.layer.cornerRadius = kCardCornerRadius;
    [self.view addSubview:self.headerView];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    self.titleLabel.textColor = [UIColor labelColor];
    self.titleLabel.text = localize(@"i18n_str_136", nil);
    [self.headerView addSubview:self.titleLabel];

    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.closeButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    self.closeButton.tintColor = [UIColor labelColor];
    [self.closeButton addTarget:self action:@selector(closeTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.headerView addSubview:self.closeButton];

    // Phase 6 Task 6.2：历史入口（关闭按钮左侧，时钟图标）
    self.historyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.historyButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.historyButton setImage:[UIImage systemImageNamed:@"clock.arrow.circlepath"] forState:UIControlStateNormal];
    self.historyButton.tintColor = [UIColor labelColor];
    self.historyButton.accessibilityLabel = NSLocalizedString(@"download.history.entry", @"历史");
    [self.historyButton addTarget:self action:@selector(historyTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.headerView addSubview:self.historyButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.headerView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [self.headerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:kSectionInset],
        [self.headerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-kSectionInset],
        [self.headerView.heightAnchor constraintEqualToConstant:56],

        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor constant:16],
        [self.titleLabel.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],

        [self.closeButton.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:-12],
        [self.closeButton.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [self.closeButton.widthAnchor constraintEqualToConstant:36],
        [self.closeButton.heightAnchor constraintEqualToConstant:36],

        [self.historyButton.trailingAnchor constraintEqualToAnchor:self.closeButton.leadingAnchor constant:-8],
        [self.historyButton.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [self.historyButton.widthAnchor constraintEqualToConstant:36],
        [self.historyButton.heightAnchor constraintEqualToConstant:36]
    ]];
}

- (void)setupStateFilter {
    self.stateSegmentedControl = [[UISegmentedControl alloc] initWithItems:@[localize(@"resman.mods.filter.all", nil), localize(@"i18n_str_138", nil), localize(@"i18n_str_126", nil)]];
    self.stateSegmentedControl.translatesAutoresizingMaskIntoConstraints = NO;
    self.stateSegmentedControl.selectedSegmentIndex = 0;
    [self.stateSegmentedControl addTarget:self action:@selector(stateFilterChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.stateSegmentedControl];

    [NSLayoutConstraint activateConstraints:@[
        [self.stateSegmentedControl.topAnchor constraintEqualToAnchor:self.headerView.bottomAnchor constant:12],
        [self.stateSegmentedControl.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:kSectionInset],
        [self.stateSegmentedControl.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-kSectionInset],
        [self.stateSegmentedControl.heightAnchor constraintEqualToConstant:36]
    ]];
}

- (void)setupTypeFilter {
    self.typeScrollView = [[UIScrollView alloc] init];
    self.typeScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.typeScrollView.showsHorizontalScrollIndicator = NO;
    self.typeScrollView.alwaysBounceHorizontal = YES;
    [self.view addSubview:self.typeScrollView];

    self.typeStackView = [[UIStackView alloc] init];
    self.typeStackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.typeStackView.axis = UILayoutConstraintAxisHorizontal;
    self.typeStackView.spacing = 8.0;
    self.typeStackView.alignment = UIStackViewAlignmentFill;
    self.typeStackView.distribution = UIStackViewDistributionFill;
    [self.typeScrollView addSubview:self.typeStackView];

    [NSLayoutConstraint activateConstraints:@[
        [self.typeScrollView.topAnchor constraintEqualToAnchor:self.stateSegmentedControl.bottomAnchor constant:12],
        [self.typeScrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:kSectionInset],
        [self.typeScrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-kSectionInset],
        [self.typeScrollView.heightAnchor constraintEqualToConstant:40],

        [self.typeStackView.topAnchor constraintEqualToAnchor:self.typeScrollView.topAnchor],
        [self.typeStackView.leadingAnchor constraintEqualToAnchor:self.typeScrollView.leadingAnchor],
        [self.typeStackView.trailingAnchor constraintEqualToAnchor:self.typeScrollView.trailingAnchor],
        [self.typeStackView.bottomAnchor constraintEqualToAnchor:self.typeScrollView.bottomAnchor],
        [self.typeStackView.heightAnchor constraintEqualToAnchor:self.typeScrollView.heightAnchor]
    ]];

    [self refreshTypeFilterButtons];
}

- (void)setupCollectionView {
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.scrollDirection = UICollectionViewScrollDirectionVertical;
    layout.minimumLineSpacing = kCardSpacing;
    layout.minimumInteritemSpacing = kCardSpacing;
    layout.sectionInset = UIEdgeInsetsMake(kSectionInset, kSectionInset, kSectionInset, kSectionInset);

    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.alwaysBounceVertical = YES;
    [self.collectionView registerClass:[DownloadTaskCell class] forCellWithReuseIdentifier:kTaskCellReuseIdentifier];
    [self.collectionView registerClass:[DownloadTaskEmptyCell class] forCellWithReuseIdentifier:kEmptyStateReuseIdentifier];
    [self.view addSubview:self.collectionView];

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    longPress.minimumPressDuration = 0.5;
    longPress.delegate = self;
    [self.collectionView addGestureRecognizer:longPress];

    [NSLayoutConstraint activateConstraints:@[
        [self.collectionView.topAnchor constraintEqualToAnchor:self.typeScrollView.bottomAnchor constant:4],
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

- (void)setupEmptyStateView {
    self.emptyStateView = [[UIView alloc] init];
    self.emptyStateView.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyStateView.backgroundColor = [UIColor clearColor];
    self.emptyStateView.hidden = YES;
    [self.view addSubview:self.emptyStateView];

    UIImageView *iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.down.circle"]];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.tintColor = [UIColor tertiaryLabelColor];
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    [self.emptyStateView addSubview:iconView];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont systemFontOfSize:16];
    label.textColor = [UIColor secondaryLabelColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.text = localize(@"i18n_str_139", nil);
    [self.emptyStateView addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [self.emptyStateView.topAnchor constraintEqualToAnchor:self.collectionView.topAnchor],
        [self.emptyStateView.leadingAnchor constraintEqualToAnchor:self.collectionView.leadingAnchor],
        [self.emptyStateView.trailingAnchor constraintEqualToAnchor:self.collectionView.trailingAnchor],
        [self.emptyStateView.bottomAnchor constraintEqualToAnchor:self.collectionView.bottomAnchor],

        [iconView.centerXAnchor constraintEqualToAnchor:self.emptyStateView.centerXAnchor],
        [iconView.centerYAnchor constraintEqualToAnchor:self.emptyStateView.centerYAnchor constant:-30],
        [iconView.widthAnchor constraintEqualToConstant:64],
        [iconView.heightAnchor constraintEqualToConstant:64],

        [label.topAnchor constraintEqualToAnchor:iconView.bottomAnchor constant:16],
        [label.leadingAnchor constraintEqualToAnchor:self.emptyStateView.leadingAnchor constant:32],
        [label.trailingAnchor constraintEqualToAnchor:self.emptyStateView.trailingAnchor constant:-32]
    ]];
}

- (void)setupNotifications {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(handleTaskUpdate:)
                   name:DownloadTaskManagerDidUpdateTaskNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(handleAggregateStateChanged:)
                   name:DownloadTaskManagerAggregateStateDidChangeNotification
                 object:nil];
}

#pragma mark - Data

- (void)reloadData {
    [self applyFilters];
    [self refreshTypeFilterButtons];
    [self.collectionView reloadData];
    [self updateEmptyState];
}

- (void)applyFilters {
    NSArray<DownloadTaskItem *> *allTasks = [[DownloadTaskManager sharedManager] allTasks];
    NSMutableArray<DownloadTaskItem *> *result = [NSMutableArray array];

    for (DownloadTaskItem *task in allTasks) {
        BOOL stateMatch = [self task:task matchesStateFilter:self.filterState];
        BOOL typeMatch = (self.filterType == nil) || [task.resourceType isEqualToString:self.filterType];
        if (stateMatch && typeMatch) {
            [result addObject:task];
        }
    }

    // 按创建时间倒序，最新的在前面
    [result sortUsingComparator:^NSComparisonResult(DownloadTaskItem *a, DownloadTaskItem *b) {
        return [b.createdDate compare:a.createdDate];
    }];

    self.filteredTasks = [result copy];

    // 更新各类型的数量
    [self.typeCounts removeAllObjects];
    DownloadTaskState effectiveState = self.filterState;
    for (DownloadTaskItem *task in allTasks) {
        if (![self task:task matchesStateFilter:effectiveState]) continue;
        NSNumber *count = self.typeCounts[task.resourceType] ?: @0;
        self.typeCounts[task.resourceType] = @(count.integerValue + 1);
    }
}

- (BOOL)task:(DownloadTaskItem *)task matchesStateFilter:(DownloadTaskState)filter {
    switch (filter) {
        case DownloadTaskStatePending:
            return YES;
        case DownloadTaskStateDownloading:
            return task.state == DownloadTaskStateDownloading || task.state == DownloadTaskStatePending;
        case DownloadTaskStateCompleted:
            return task.state == DownloadTaskStateCompleted;
        default:
            return YES;
    }
}

- (void)refreshTypeFilterButtons {
    NSArray *existing = [self.typeStackView.arrangedSubviews copy];
    for (UIView *view in existing) {
        [view removeFromSuperview];
    }

    UIButton *allButton = [self createTypeFilterButtonWithTitle:localize(@"resman.mods.filter.all", nil)
                                                          count:@(self.filteredTasks.count)
                                                        selected:(self.filterType == nil)];
    [allButton addTarget:self action:@selector(typeButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    allButton.tag = -1;
    [self.typeStackView addArrangedSubview:allButton];

    for (NSUInteger i = 0; i < self.resourceTypes.count; i++) {
        NSString *type = self.resourceTypes[i];
        NSString *title = self.typeDisplayNames[type] ?: type;
        NSNumber *count = self.typeCounts[type] ?: @0;
        UIButton *button = [self createTypeFilterButtonWithTitle:title
                                                           count:count
                                                        selected:[type isEqualToString:self.filterType]];
        button.tag = i;
        [button addTarget:self action:@selector(typeButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.typeStackView addArrangedSubview:button];
    }
}

- (UIButton *)createTypeFilterButtonWithTitle:(NSString *)title count:(NSNumber *)count selected:(BOOL)selected {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.translatesAutoresizingMaskIntoConstraints = NO;

    NSString *fullTitle = [NSString stringWithFormat:@"%@ (%@)", title, count];
    [button setTitle:fullTitle forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:13 weight:selected ? UIFontWeightSemibold : UIFontWeightRegular];
    [button setTitleColor:selected ? [UIColor whiteColor] : [UIColor labelColor] forState:UIControlStateNormal];
    button.backgroundColor = selected ? [UIColor systemBlueColor] : [UIColor secondarySystemBackgroundColor];
    button.layer.cornerRadius = 8.0;
    button.layer.masksToBounds = YES;
    button.contentEdgeInsets = UIEdgeInsetsMake(8, 12, 8, 12);

    [button.widthAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    return button;
}

- (void)updateEmptyState {
    BOOL hasData = self.filteredTasks.count > 0;
    self.emptyStateView.hidden = hasData;
    self.collectionView.hidden = NO;
}

#pragma mark - Actions

- (void)closeTapped:(UIButton *)sender {
    // 发送通知：用户手动关闭了下载中心。
    // 启动器（LauncherNavigationController / LauncherRightPanelViewController）收到此通知后，
    // 会设置 userDismissedDownloadCenter=YES，避免后续下载任务更新时反复自动弹出下载中心。
    // 用户可以通过点击启动器上的"下载中心"按钮重新打开。
    [[NSNotificationCenter defaultCenter] postNotificationName:@"DownloadCenterDidDismiss"
                                                      object:nil
                                                    userInfo:nil];
    [self dismissViewControllerAnimated:YES completion:nil];
}

/// Phase 6 Task 6.2：打开下载历史页。
/// 下载中心本身是无导航栏的 FormSheet 弹窗，历史页以 PageSheet + UINavigationController
/// 模态弹出（风格与现有弹窗层级一致，iOS 14 兼容，下滑即可关闭）。
- (void)historyTapped:(UIButton *)sender {
    DownloadHistoryViewController *historyVC = [[DownloadHistoryViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:historyVC];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)stateFilterChanged:(UISegmentedControl *)sender {
    switch (sender.selectedSegmentIndex) {
        case 0:
            self.filterState = DownloadTaskStatePending; // 全部
            break;
        case 1:
            self.filterState = DownloadTaskStateDownloading; // 下载中
            break;
        case 2:
            self.filterState = DownloadTaskStateCompleted; // 已完成
            break;
    }
    [self reloadData];
}

- (void)typeButtonTapped:(UIButton *)sender {
    if (sender.tag < 0) {
        self.filterType = nil;
    } else if ((NSUInteger)sender.tag < self.resourceTypes.count) {
        self.filterType = self.resourceTypes[(NSUInteger)sender.tag];
    }
    [self reloadData];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    CGPoint point = [gesture locationInView:self.collectionView];
    NSIndexPath *indexPath = [self.collectionView indexPathForItemAtPoint:point];
    if (!indexPath || indexPath.item >= self.filteredTasks.count) return;

    DownloadTaskItem *task = self.filteredTasks[indexPath.item];
    [self showActionsForTask:task];
}

- (void)showActionsForTask:(DownloadTaskItem *)task {
    // FCL 风格重构后，常用操作（暂停/继续/取消/重试/移除）已在卡片上直接显示按钮。
    // 长按仅作为辅助入口，提供"切换下载源"等进阶操作。
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:task.displayName
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_140", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self showSourceSwitcherForTask:task];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_141", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
        alert.popoverPresentationController.permittedArrowDirections = 0;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showSourceSwitcherForTask:(DownloadTaskItem *)task {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_140", nil)
                                                                   message:[NSString stringWithFormat:localize(@"i18n_str_142", nil), task.downloadSource ?: @"official"]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray<NSString *> *sources = @[@"official", @"bmclapi"];
    for (NSString *source in sources) {
        if ([source isEqualToString:task.downloadSource]) continue;
        [alert addAction:[UIAlertAction actionWithTitle:source
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            [self confirmSwitchSourceForTask:task toSource:source];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
        alert.popoverPresentationController.permittedArrowDirections = 0;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmSwitchSourceForTask:(DownloadTaskItem *)task toSource:(NSString *)source {
    __weak typeof(self) weakSelf = self;
    [[DownloadTaskManager sharedManager] switchDownloadSourceForTaskId:task.taskId
                                                              toSource:source
                                                            completion:^(BOOL shouldRecreate, BOOL supportsResume, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (error) {
                [strongSelf showAlert:localize(@"i18n_str_143", nil) message:error.localizedDescription];
                return;
            }

            if (!supportsResume) {
                UIAlertController *confirm = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_140", nil)
                                                                                 message:localize(@"i18n_str_144", nil)
                                                                          preferredStyle:UIAlertControllerStyleAlert];
                [confirm addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
                [confirm addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_145", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    [[DownloadTaskManager sharedManager] cancelTaskWithId:task.taskId];
                    // 业务方在取消后需要重新创建下载任务；这里仅更新源并移除旧记录。
                    [[DownloadTaskManager sharedManager] removeTaskWithId:task.taskId];
                }]];
                [strongSelf presentViewController:confirm animated:YES completion:nil];
            } else {
                [[DownloadTaskManager sharedManager] cancelTaskWithId:task.taskId];
                [[DownloadTaskManager sharedManager] removeTaskWithId:task.taskId];
            }
        });
    }];
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Notifications

- (void)handleTaskUpdate:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self reloadData];
    });
}

- (void)handleAggregateStateChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self reloadData];
    });
}

#pragma mark - UICollectionViewDataSource

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    if (self.filteredTasks.count == 0) {
        return 1; // 空状态占位
    }
    return self.filteredTasks.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    if (self.filteredTasks.count == 0) {
        DownloadTaskEmptyCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:kEmptyStateReuseIdentifier forIndexPath:indexPath];
        return cell;
    }

    DownloadTaskCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:kTaskCellReuseIdentifier forIndexPath:indexPath];
    DownloadTaskItem *task = self.filteredTasks[indexPath.item];
    [cell configureWithTask:task];
    return cell;
}

#pragma mark - UICollectionViewDelegate

/// 点击任务卡片打开统一进度页（redesign-download-ui Task 2.4）。
/// 卡片上的操作按钮（暂停/继续/取消/重试/移除）会拦截自身点击，不与本回调冲突；
/// 长按切源等既有交互不受影响。
- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    if (self.filteredTasks.count == 0) return;
    if (indexPath.item >= self.filteredTasks.count) return;
    DownloadTaskItem *task = self.filteredTasks[indexPath.item];
    [PLTaskProgressViewController presentForTaskId:task.taskId];
}

#pragma mark - UICollectionViewDelegateFlowLayout

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    if (self.filteredTasks.count == 0) {
        return CGSizeMake(collectionView.bounds.size.width - kSectionInset * 2, 200);
    }

    CGFloat width = collectionView.bounds.size.width - kSectionInset * 2;
    // 阶段信息行（约 20pt：16 高 + 间距）计入卡片高度
    return CGSizeMake(width, 172);
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        [self.collectionView.collectionViewLayout invalidateLayout];
    } completion:nil];
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if ([gestureRecognizer isKindOfClass:[UILongPressGestureRecognizer class]]) {
        CGPoint point = [touch locationInView:self.collectionView];
        NSIndexPath *indexPath = [self.collectionView indexPathForItemAtPoint:point];
        return indexPath != nil && self.filteredTasks.count > 0;
    }
    return YES;
}

@end
