#import "VersionManagerViewController.h"
#import "BackgroundManager.h"
#import "PLProfiles.h"
#import "ProfileSettingsViewController.h"
#import "ModsManagerViewController.h"
#import "ShadersManagerViewController.h"
#import "ResourcePacksManagerViewController.h"
#import "DataPacksManagerViewController.h"
#import "WorldsManagerViewController.h"
#import "LauncherPreferences.h"
#import "ScreenUtils.h"
#import "utils.h"
#import "ModLoaderIconHelper.h"
#import "ModpackExportService.h" // for parseVersionId:
#import <QuartzCore/QuartzCore.h>

// Section 索引：2 个 section（游戏目录 / 已安装版本）
// 重新设计要点（参照 FCL 100%）：
//   1. 版本管理界面只展示：游戏目录切换 + 已安装版本列表
//   2. 渲染器、图形 API、Mod/光影/资源包管理等全部移到"版本专属设置页"（ProfileSettingsViewController）
//      点击版本卡片直接进入该版本的专属设置页，设置只对该版本生效（FCL 风格）
//   3. 完全不调用旧 UI（LauncherPrefGameDirViewController / LauncherProfileEditorViewController）
//   4. 游戏目录卡片支持长按弹出菜单（切换/删除当前目录）
//   5. 统一使用 accentColor() 与毛玻璃背景，适配启动器新 UI
static NSInteger const kSectionGameDir     = 0;
static NSInteger const kSectionVersions    = 1;

#pragma mark - Modern Tile Base Cell

@interface VMTileBaseCell : UICollectionViewCell
@property (nonatomic, strong) UIView *contentContainer;
- (void)setupViews;
@end

@implementation VMTileBaseCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupViews];
    }
    return self;
}

- (void)setupViews {
    // 阴影：规范 5.2 中阴影档（0.12, 6, (0,3)）
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOffset = CGSizeMake(0, 3);
    self.layer.shadowOpacity = 0.12;
    self.layer.shadowRadius = 6;
    self.layer.masksToBounds = NO;

    self.contentContainer = [[UIView alloc] initWithFrame:self.contentView.bounds];
    self.contentContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // 规范 5.1：L2 标准卡片 12pt 圆角 + 连续圆角
    self.contentContainer.layer.cornerRadius = 12;
    self.contentContainer.layer.cornerCurve = kCACornerCurveContinuous;
    self.contentContainer.layer.masksToBounds = YES;
    // 规范 6.2：第 1 层浅色半透明基底
    self.contentContainer.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    // 规范 5.3：默认卡片描边 0.5pt 白 0.10
    self.contentContainer.layer.borderWidth = 0.5;
    self.contentContainer.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    [self.contentView addSubview:self.contentContainer];

    // 规范 6.2：第 2 层 BackgroundManager 毛玻璃
    [[BackgroundManager sharedManager] applyEffectToCollectionViewCell:self];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.8 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform = CGAffineTransformMakeScale(0.96, 0.96);
    } completion:nil];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.8 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.8 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform = CGAffineTransformIdentity;
    } completion:nil];
}

@end

#pragma mark - Quick Action Tile Cell

@interface VMQuickActionCell : VMTileBaseCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@end

@implementation VMQuickActionCell

- (void)setupViews {
    [super setupViews];

    CGFloat iconSize = [ScreenUtils dp:24];
    CGFloat titleFont = [ScreenUtils sp:13];

    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    [self.contentContainer addSubview:self.iconView];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont systemFontOfSize:titleFont weight:UIFontWeightSemibold];
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.titleLabel];

    self.subtitleLabel = [[UILabel alloc] init];
    self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.subtitleLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:10] weight:UIFontWeightRegular];
    self.subtitleLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.6];
    self.subtitleLabel.numberOfLines = 0;
    self.subtitleLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.subtitleLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.subtitleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:12],
        [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:12],
        [self.iconView.widthAnchor constraintEqualToConstant:iconSize],
        [self.iconView.heightAnchor constraintEqualToConstant:iconSize],
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.iconView.bottomAnchor constant:8],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:12],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-12],
        [self.subtitleLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:2],
        [self.subtitleLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:12],
        [self.subtitleLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-12],
        [self.subtitleLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentContainer.bottomAnchor constant:-10]
    ]];
}

- (void)configureWithIcon:(NSString *)iconName title:(NSString *)title subtitle:(NSString *)subtitle color:(UIColor *)color {
    self.iconView.image = [UIImage systemImageNamed:iconName];
    self.iconView.tintColor = color;
    self.titleLabel.text = title;
    self.subtitleLabel.text = subtitle;
}

@end

#pragma mark - Version Card Cell

@interface VMVersionCardCell : VMTileBaseCell
@property (nonatomic, strong) UIView *iconContainer;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *versionLabel;
@property (nonatomic, strong) UILabel *lastPlayedLabel;
@property (nonatomic, strong) UIView *selectedBadge;
@property (nonatomic, strong) UILabel *isolatedBadge;
@property (nonatomic, strong) UIImageView *chevronView;
@end

@implementation VMVersionCardCell

- (void)setupViews {
    [super setupViews];

    CGFloat iconBoxSize = [ScreenUtils dp:34];
    CGFloat iconSize = [ScreenUtils dp:20];
    CGFloat nameFont = [ScreenUtils sp:15];

    // 规范 8.2：图标必须放在带类型色的圆角容器内
    self.iconContainer = [[UIView alloc] init];
    self.iconContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconContainer.layer.cornerRadius = 9;
    self.iconContainer.layer.cornerCurve = kCACornerCurveContinuous;
    self.iconContainer.backgroundColor = [UIColor systemBlueColor];
    [self.contentContainer addSubview:self.iconContainer];

    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.image = [UIImage systemImageNamed:@"cube.box.fill"];
    self.iconView.tintColor = [UIColor whiteColor];
    [self.iconContainer addSubview:self.iconView];

    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.nameLabel.font = [UIFont systemFontOfSize:nameFont weight:UIFontWeightSemibold];
    // 规范 2.1：强制使用系统色
    self.nameLabel.textColor = [UIColor labelColor];
    self.nameLabel.numberOfLines = 1;
    self.nameLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.nameLabel];

    self.versionLabel = [[UILabel alloc] init];
    self.versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:11] weight:UIFontWeightRegular];
    // 规范 2.1：副文字用 secondaryLabelColor
    self.versionLabel.textColor = [UIColor secondaryLabelColor];
    self.versionLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.versionLabel];

    self.lastPlayedLabel = [[UILabel alloc] init];
    self.lastPlayedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.lastPlayedLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:10] weight:UIFontWeightRegular];
    // 规范 2.1：元文字用 tertiaryLabelColor
    self.lastPlayedLabel.textColor = [UIColor tertiaryLabelColor];
    self.lastPlayedLabel.text = @"";
    self.lastPlayedLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.lastPlayedLabel];

    // 规范 9.1：选中态徽章（第二层强化）
    self.selectedBadge = [[UIView alloc] init];
    self.selectedBadge.translatesAutoresizingMaskIntoConstraints = NO;
    self.selectedBadge.backgroundColor = accentColor();
    self.selectedBadge.layer.cornerRadius = 10;
    self.selectedBadge.layer.cornerCurve = kCACornerCurveContinuous;
    self.selectedBadge.hidden = YES;
    [self.contentContainer addSubview:self.selectedBadge];

    UIImageView *checkmark = [[UIImageView alloc] init];
    checkmark.translatesAutoresizingMaskIntoConstraints = NO;
    checkmark.image = [UIImage systemImageNamed:@"checkmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:9 weight:UIFontWeightBold]];
    checkmark.tintColor = [UIColor whiteColor];
    [self.selectedBadge addSubview:checkmark];

    self.isolatedBadge = [[UILabel alloc] init];
    self.isolatedBadge.translatesAutoresizingMaskIntoConstraints = NO;
    self.isolatedBadge.font = [UIFont systemFontOfSize:9 weight:UIFontWeightSemibold];
    self.isolatedBadge.textColor = [UIColor whiteColor];
    self.isolatedBadge.backgroundColor = [UIColor systemTealColor];
    self.isolatedBadge.textAlignment = NSTextAlignmentCenter;
    self.isolatedBadge.layer.cornerRadius = 8;
    self.isolatedBadge.layer.cornerCurve = kCACornerCurveContinuous;
    self.isolatedBadge.layer.masksToBounds = YES;
    self.isolatedBadge.text = [[@" " stringByAppendingString:localize(@"i18n_str_2026", nil)] stringByAppendingString:@" "];
    self.isolatedBadge.hidden = YES;
    [self.contentContainer addSubview:self.isolatedBadge];

    // 规范 9.4：chevron 暗示可点击
    self.chevronView = [[UIImageView alloc] init];
    self.chevronView.translatesAutoresizingMaskIntoConstraints = NO;
    self.chevronView.image = [UIImage systemImageNamed:@"chevron.right" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIFontWeightSemibold]];
    self.chevronView.tintColor = [UIColor tertiaryLabelColor];
    [self.contentContainer addSubview:self.chevronView];

    [NSLayoutConstraint activateConstraints:@[
        [self.iconContainer.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:14],
        [self.iconContainer.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.iconContainer.widthAnchor constraintEqualToConstant:iconBoxSize],
        [self.iconContainer.heightAnchor constraintEqualToConstant:iconBoxSize],
        [self.iconView.centerXAnchor constraintEqualToAnchor:self.iconContainer.centerXAnchor],
        [self.iconView.centerYAnchor constraintEqualToAnchor:self.iconContainer.centerYAnchor],
        [self.iconView.widthAnchor constraintEqualToConstant:iconSize],
        [self.iconView.heightAnchor constraintEqualToConstant:iconSize],
        [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.iconContainer.trailingAnchor constant:10],
        [self.nameLabel.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:14],
        [self.nameLabel.trailingAnchor constraintEqualToAnchor:self.chevronView.leadingAnchor constant:-8],
        [self.versionLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [self.versionLabel.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:3],
        [self.versionLabel.trailingAnchor constraintEqualToAnchor:self.chevronView.leadingAnchor constant:-8],
        [self.lastPlayedLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [self.lastPlayedLabel.topAnchor constraintEqualToAnchor:self.versionLabel.bottomAnchor constant:2],
        [self.lastPlayedLabel.trailingAnchor constraintEqualToAnchor:self.isolatedBadge.leadingAnchor constant:-6],
        [self.isolatedBadge.centerYAnchor constraintEqualToAnchor:self.lastPlayedLabel.centerYAnchor],
        [self.isolatedBadge.trailingAnchor constraintEqualToAnchor:self.chevronView.leadingAnchor constant:-8],
        [self.isolatedBadge.heightAnchor constraintEqualToConstant:16],
        [self.chevronView.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-14],
        [self.chevronView.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.chevronView.widthAnchor constraintEqualToConstant:12],
        [self.chevronView.heightAnchor constraintEqualToConstant:12],
        [self.selectedBadge.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-14],
        [self.selectedBadge.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:10],
        [self.selectedBadge.widthAnchor constraintEqualToConstant:20],
        [self.selectedBadge.heightAnchor constraintEqualToConstant:20],
        [checkmark.centerXAnchor constraintEqualToAnchor:self.selectedBadge.centerXAnchor],
        [checkmark.centerYAnchor constraintEqualToAnchor:self.selectedBadge.centerYAnchor]
    ]];
}

- (void)configureWithName:(NSString *)name version:(NSString *)version isSelected:(BOOL)isSelected isolated:(BOOL)isolated lastPlayed:(NSString *)lastPlayed {
    self.nameLabel.text = name;
    self.versionLabel.text = version ?: localize(@"i18n_str_1052", nil);
    self.selectedBadge.hidden = !isSelected;
    self.selectedBadge.backgroundColor = accentColor();
    self.isolatedBadge.hidden = !isolated;
    self.lastPlayedLabel.text = lastPlayed.length > 0 ? lastPlayed : @"";

    NSString *detectedLoader = [ModLoaderIconHelper detectLoaderFromVersionId:version];
    if (detectedLoader) {
        [ModLoaderIconHelper configureImageView:self.iconView
                                      forLoader:detectedLoader
                                 traitCollection:self.traitCollection];
        // 规范 2.6：加载器品牌色作为图标容器背景
        self.iconContainer.backgroundColor = [ModLoaderIconHelper brandColorForLoader:detectedLoader];
    } else {
        self.iconView.image = [UIImage systemImageNamed:@"cube.box.fill"];
        self.iconView.tintColor = [UIColor whiteColor];
        self.iconContainer.backgroundColor = [UIColor systemBlueColor];
    }

    // 规范 9.1：选中态三层强化（边框 + 徽章 + 背景色）
    if (isSelected) {
        self.contentContainer.layer.borderColor = accentColor().CGColor;
        self.contentContainer.layer.borderWidth = 1.5;
        self.contentContainer.backgroundColor = [accentColor() colorWithAlphaComponent:0.10];
        self.chevronView.tintColor = accentColor();
    } else {
        self.contentContainer.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
        self.contentContainer.layer.borderWidth = 0.5;
        self.contentContainer.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
        self.chevronView.tintColor = [UIColor tertiaryLabelColor];
    }
}

@end

#pragma mark - Game Directory Cell (FCL 风格版本隔离卡片)

@interface VMGameDirCell : VMTileBaseCell
@property (nonatomic, strong) UIView *iconContainer;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UIView *selectedBadge;
@property (nonatomic, strong) UIImageView *chevronView;
@end

@implementation VMGameDirCell

- (void)setupViews {
    [super setupViews];

    CGFloat iconBoxSize = [ScreenUtils dp:28];
    CGFloat iconSize = [ScreenUtils dp:16];
    CGFloat nameFont = [ScreenUtils sp:13];

    // 规范 8.2：图标容器
    self.iconContainer = [[UIView alloc] init];
    self.iconContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconContainer.layer.cornerRadius = 8;
    self.iconContainer.layer.cornerCurve = kCACornerCurveContinuous;
    self.iconContainer.backgroundColor = [UIColor systemBlueColor];
    [self.contentContainer addSubview:self.iconContainer];

    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.image = [UIImage systemImageNamed:@"folder.fill"];
    self.iconView.tintColor = [UIColor whiteColor];
    [self.iconContainer addSubview:self.iconView];

    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.nameLabel.font = [UIFont systemFontOfSize:nameFont weight:UIFontWeightSemibold];
    // 规范 2.1：系统色
    self.nameLabel.textColor = [UIColor labelColor];
    self.nameLabel.numberOfLines = 1;
    self.nameLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.nameLabel];

    self.detailLabel = [[UILabel alloc] init];
    self.detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.detailLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:10] weight:UIFontWeightRegular];
    // 规范 2.1：副文字 secondaryLabelColor
    self.detailLabel.textColor = [UIColor secondaryLabelColor];
    self.detailLabel.numberOfLines = 0;
    self.detailLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.detailLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.detailLabel];

    self.selectedBadge = [[UIView alloc] init];
    self.selectedBadge.translatesAutoresizingMaskIntoConstraints = NO;
    self.selectedBadge.backgroundColor = accentColor();
    self.selectedBadge.layer.cornerRadius = 9;
    self.selectedBadge.layer.cornerCurve = kCACornerCurveContinuous;
    self.selectedBadge.hidden = YES;
    [self.contentContainer addSubview:self.selectedBadge];

    UIImageView *checkmark = [[UIImageView alloc] init];
    checkmark.translatesAutoresizingMaskIntoConstraints = NO;
    checkmark.image = [UIImage systemImageNamed:@"checkmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:8 weight:UIFontWeightBold]];
    checkmark.tintColor = [UIColor whiteColor];
    [self.selectedBadge addSubview:checkmark];

    // 规范 9.4：chevron 暗示可点击
    self.chevronView = [[UIImageView alloc] init];
    self.chevronView.translatesAutoresizingMaskIntoConstraints = NO;
    self.chevronView.image = [UIImage systemImageNamed:@"chevron.right" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIFontWeightSemibold]];
    self.chevronView.tintColor = [UIColor tertiaryLabelColor];
    [self.contentContainer addSubview:self.chevronView];

    [NSLayoutConstraint activateConstraints:@[
        [self.iconContainer.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:10],
        [self.iconContainer.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.iconContainer.widthAnchor constraintEqualToConstant:iconBoxSize],
        [self.iconContainer.heightAnchor constraintEqualToConstant:iconBoxSize],
        [self.iconView.centerXAnchor constraintEqualToAnchor:self.iconContainer.centerXAnchor],
        [self.iconView.centerYAnchor constraintEqualToAnchor:self.iconContainer.centerYAnchor],
        [self.iconView.widthAnchor constraintEqualToConstant:iconSize],
        [self.iconView.heightAnchor constraintEqualToConstant:iconSize],
        [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.iconContainer.trailingAnchor constant:8],
        [self.nameLabel.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:8],
        [self.nameLabel.trailingAnchor constraintEqualToAnchor:self.chevronView.leadingAnchor constant:-6],
        [self.detailLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [self.detailLabel.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:2],
        [self.detailLabel.trailingAnchor constraintEqualToAnchor:self.chevronView.leadingAnchor constant:-6],
        [self.detailLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentContainer.bottomAnchor constant:-8],
        [self.selectedBadge.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-10],
        [self.selectedBadge.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:8],
        [self.selectedBadge.widthAnchor constraintEqualToConstant:18],
        [self.selectedBadge.heightAnchor constraintEqualToConstant:18],
        [self.chevronView.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-10],
        [self.chevronView.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.chevronView.widthAnchor constraintEqualToConstant:11],
        [self.chevronView.heightAnchor constraintEqualToConstant:11],
        [checkmark.centerXAnchor constraintEqualToAnchor:self.selectedBadge.centerXAnchor],
        [checkmark.centerYAnchor constraintEqualToAnchor:self.selectedBadge.centerYAnchor]
    ]];
}

- (void)configureWithName:(NSString *)name detail:(NSString *)detail isSelected:(BOOL)isSelected isAddButton:(BOOL)isAddButton {
    if (isAddButton) {
        self.iconView.image = [UIImage systemImageNamed:@"plus"];
        self.iconView.tintColor = [UIColor whiteColor];
        self.iconContainer.backgroundColor = [UIColor systemGreenColor];
        self.nameLabel.text = localize(@"i18n_str_1053", nil);
        self.detailLabel.text = localize(@"i18n_str_1054", nil);
        self.selectedBadge.hidden = YES;
        self.chevronView.hidden = YES;
        // 规范 5.3：推荐态描边 1.0pt accentColor 0.4
        self.contentContainer.layer.borderColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.6].CGColor;
        self.contentContainer.layer.borderWidth = 1.0;
        self.contentContainer.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.08];
        return;
    }

    self.chevronView.hidden = NO;
    self.iconView.image = [UIImage systemImageNamed:@"folder.fill"];
    self.iconView.tintColor = [UIColor whiteColor];
    self.iconContainer.backgroundColor = [UIColor systemBlueColor];
    self.nameLabel.text = name;
    self.detailLabel.text = detail ?: @"";
    self.selectedBadge.hidden = !isSelected;
    self.selectedBadge.backgroundColor = accentColor();

    // 规范 9.1：选中态三层强化
    if (isSelected) {
        self.contentContainer.layer.borderColor = accentColor().CGColor;
        self.contentContainer.layer.borderWidth = 1.5;
        self.contentContainer.backgroundColor = [accentColor() colorWithAlphaComponent:0.10];
        self.chevronView.tintColor = accentColor();
    } else {
        self.contentContainer.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
        self.contentContainer.layer.borderWidth = 0.5;
        self.contentContainer.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
        self.chevronView.tintColor = [UIColor tertiaryLabelColor];
    }
}

@end

#pragma mark - Renderer Card Cell (图形 API 选择卡片，FCL 风格)

@interface VMRendererCell : VMTileBaseCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UIView *selectedBadge;
@end

@implementation VMRendererCell

- (void)setupViews {
    [super setupViews];

    CGFloat iconSize = [ScreenUtils dp:22];

    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    [self.contentContainer addSubview:self.iconView];

    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.nameLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:13] weight:UIFontWeightSemibold];
    self.nameLabel.textColor = [UIColor whiteColor];
    self.nameLabel.numberOfLines = 1;
    self.nameLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.nameLabel];

    self.descLabel = [[UILabel alloc] init];
    self.descLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.descLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:10] weight:UIFontWeightRegular];
    self.descLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.55];
    self.descLabel.numberOfLines = 2;
    self.descLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.descLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.descLabel];

    self.selectedBadge = [[UIView alloc] init];
    self.selectedBadge.translatesAutoresizingMaskIntoConstraints = NO;
    self.selectedBadge.backgroundColor = accentColor();
    self.selectedBadge.layer.cornerRadius = 8;
    self.selectedBadge.hidden = YES;
    [self.contentContainer addSubview:self.selectedBadge];

    UIImageView *checkmark = [[UIImageView alloc] init];
    checkmark.translatesAutoresizingMaskIntoConstraints = NO;
    checkmark.image = [UIImage systemImageNamed:@"checkmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:8 weight:UIFontWeightBold]];
    checkmark.tintColor = [UIColor whiteColor];
    [self.selectedBadge addSubview:checkmark];

    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:10],
        [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:10],
        [self.iconView.widthAnchor constraintEqualToConstant:iconSize],
        [self.iconView.heightAnchor constraintEqualToConstant:iconSize],
        [self.nameLabel.topAnchor constraintEqualToAnchor:self.iconView.bottomAnchor constant:6],
        [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:10],
        [self.nameLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-10],
        [self.descLabel.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:2],
        [self.descLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:10],
        [self.descLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-10],
        [self.descLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentContainer.bottomAnchor constant:-8],
        [self.selectedBadge.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:8],
        [self.selectedBadge.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-8],
        [self.selectedBadge.widthAnchor constraintEqualToConstant:16],
        [self.selectedBadge.heightAnchor constraintEqualToConstant:16],
        [checkmark.centerXAnchor constraintEqualToAnchor:self.selectedBadge.centerXAnchor],
        [checkmark.centerYAnchor constraintEqualToAnchor:self.selectedBadge.centerYAnchor]
    ]];
}

- (void)configureWithIcon:(NSString *)iconName
                     name:(NSString *)name
                  details:(NSString *)details
              isSelected:(BOOL)isSelected
                  isBest:(BOOL)isBest {
    self.iconView.image = [UIImage systemImageNamed:iconName];
    self.iconView.tintColor = isBest ? accentColor() : [UIColor systemGrayColor];
    self.nameLabel.text = name;
    self.descLabel.text = details;
    self.selectedBadge.hidden = !isSelected;
    self.selectedBadge.backgroundColor = accentColor();

    if (isSelected) {
        self.contentView.layer.borderColor = accentColor().CGColor;
        self.contentView.layer.borderWidth = 1.5;
    } else if (isBest) {
        self.contentView.layer.borderColor = [[accentColor() colorWithAlphaComponent:0.4] CGColor];
        self.contentView.layer.borderWidth = 1.0;
    } else {
        self.contentView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12].CGColor;
        self.contentView.layer.borderWidth = 0.5;
    }
    self.contentView.layer.cornerRadius = 12;
    self.contentView.layer.masksToBounds = YES;
}

@end

#pragma mark - Header View

@interface VMSectionHeaderView : UICollectionReusableView
@property (nonatomic, strong) UIView *accentBar;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *countBadge;
@property (nonatomic, strong) UIVisualEffectView *blurView;
- (void)configureWithIcon:(NSString *)iconName title:(NSString *)title subtitle:(NSString *)subtitle count:(NSInteger)count;
@end

@implementation VMSectionHeaderView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // 规范 6.2：SystemMaterial 自动适配亮/暗模式（替代原 SystemMaterialDark）
        UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
        self.blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
        self.blurView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.blurView];

        // 规范 9.5：前导强调色条（4pt 宽，圆角，accentColor）
        self.accentBar = [[UIView alloc] init];
        self.accentBar.translatesAutoresizingMaskIntoConstraints = NO;
        self.accentBar.backgroundColor = accentColor();
        self.accentBar.layer.cornerRadius = 2;
        self.accentBar.layer.cornerCurve = kCACornerCurveContinuous;
        [self addSubview:self.accentBar];

        // 规范 8.2：图标容器（用 SF Symbol，tint = accentColor）
        self.iconView = [[UIImageView alloc] init];
        self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
        self.iconView.tintColor = accentColor();
        [self addSubview:self.iconView];

        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.titleLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:16] weight:UIFontWeightBold];
        // 规范 2.1：强制使用系统色
        self.titleLabel.textColor = [UIColor labelColor];
        [self addSubview:self.titleLabel];

        self.subtitleLabel = [[UILabel alloc] init];
        self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.subtitleLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:11] weight:UIFontWeightRegular];
        // 规范 2.1：副文字 secondaryLabelColor
        self.subtitleLabel.textColor = [UIColor secondaryLabelColor];
        self.subtitleLabel.numberOfLines = 0;
        self.subtitleLabel.lineBreakMode = NSLineBreakByWordWrapping;
        [self addSubview:self.subtitleLabel];

        // 规范 7.1：计数 pill 徽章（右上角，accentColor 浅底）
        self.countBadge = [[UILabel alloc] init];
        self.countBadge.translatesAutoresizingMaskIntoConstraints = NO;
        self.countBadge.font = [UIFont systemFontOfSize:[ScreenUtils sp:11] weight:UIFontWeightBold];
        self.countBadge.textColor = [UIColor whiteColor];
        self.countBadge.textAlignment = NSTextAlignmentCenter;
        self.countBadge.backgroundColor = accentColor();
        self.countBadge.layer.cornerRadius = 9;
        self.countBadge.layer.cornerCurve = kCACornerCurveContinuous;
        self.countBadge.layer.masksToBounds = YES;
        self.countBadge.hidden = YES;
        [self addSubview:self.countBadge];

        [NSLayoutConstraint activateConstraints:@[
            [self.blurView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [self.blurView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [self.blurView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [self.blurView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            // 前导强调条：左侧 18pt，垂直居中，4pt 宽，18pt 高
            [self.accentBar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:18],
            [self.accentBar.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.accentBar.widthAnchor constraintEqualToConstant:4],
            [self.accentBar.heightAnchor constraintEqualToConstant:18],
            // 图标：紧贴强调条右侧 8pt，垂直居中，16x16
            [self.iconView.leadingAnchor constraintEqualToAnchor:self.accentBar.trailingAnchor constant:8],
            [self.iconView.centerYAnchor constraintEqualToAnchor:self.titleLabel.centerYAnchor],
            [self.iconView.widthAnchor constraintEqualToConstant:16],
            [self.iconView.heightAnchor constraintEqualToConstant:16],
            // 标题：图标右侧 6pt
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:6],
            [self.titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
            [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.countBadge.leadingAnchor constant:-8],
            // 副标题：标题下方 2pt
            [self.subtitleLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
            [self.subtitleLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:2],
            [self.subtitleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-18],
            [self.subtitleLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-4],
            // 计数徽章：右侧 18pt，顶部 8pt，最小宽度 18，高度 18
            [self.countBadge.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-18],
            [self.countBadge.centerYAnchor constraintEqualToAnchor:self.titleLabel.centerYAnchor],
            [self.countBadge.heightAnchor constraintEqualToConstant:18]
        ]];
    }
    return self;
}

/// 配置 Header（图标 + 标题 + 副标题 + 计数）
- (void)configureWithIcon:(NSString *)iconName
                    title:(NSString *)title
                 subtitle:(NSString *)subtitle
                    count:(NSInteger)count {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIFontWeightSemibold];
    self.iconView.image = [UIImage systemImageNamed:iconName withConfiguration:config] ?: [UIImage systemImageNamed:iconName];
    self.iconView.tintColor = accentColor();
    self.accentBar.backgroundColor = accentColor();
    self.countBadge.backgroundColor = accentColor();

    self.titleLabel.text = title;
    self.subtitleLabel.text = subtitle;

    if (count >= 0) {
        self.countBadge.text = [NSString stringWithFormat:@" %ld ", (long)count];
        self.countBadge.hidden = NO;
    } else {
        self.countBadge.hidden = YES;
    }
}

@end

#pragma mark - View Controller

@interface VersionManagerViewController () <UICollectionViewDataSource, UICollectionViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) NSArray<NSString *> *profileList;
@property (nonatomic, strong) NSString *selectedProfile;
@property (nonatomic, strong) NSMutableArray<NSString *> *gameDirList;
@property (nonatomic, strong) NSString *currentGameDir;
// 空状态视图（无版本时显示引导）
@property (nonatomic, strong) UIView *emptyStateView;
// 渲染器 section 数据（启动器 native 渲染器库选择，LWJGL 层）
@property (nonatomic, strong) NSArray<NSString *> *rendererKeys;
@property (nonatomic, strong) NSArray<NSString *> *rendererNames;
@property (nonatomic, strong) NSArray<NSString *> *rendererIcons;
@property (nonatomic, strong) NSArray<NSString *> *rendererDescs;
// 图形 API section 数据（MC 26.2+ 游戏内 OpenGL/Vulkan 切换，游戏层）
@property (nonatomic, strong) NSArray<NSString *> *graphicsApiKeys;
@property (nonatomic, strong) NSArray<NSString *> *graphicsApiNames;
@property (nonatomic, strong) NSArray<NSString *> *graphicsApiIcons;
@property (nonatomic, strong) NSArray<NSString *> *graphicsApiDescs;
@end

@implementation VersionManagerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // 不设置 self.title，避免顶部导航栏出现"版本管理"标题黑条（参照 FCL 无 title 风格）
    self.view.backgroundColor = [UIColor clearColor];
    // 彻底隐藏导航栏黑条（仅当作为非 modal 根页面且是栈中唯一 VC 时）
    // 快捷入口（showModsManager 等）会预 push 子页面，此时 count > 1，不隐藏导航栏
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil &&
        self.navigationController.viewControllers.count == 1) {
        self.navigationController.navigationBarHidden = YES;
    }
    if (self.navigationController) {
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
    }
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    [self setupRendererData];
    [self setupGraphicsApiData];
    [self setupCollectionView];
    [self setupEmptyStateView];
    [self setupNavigationBar];
    [self setupLongPressGesture];
    [self loadProfiles];
    [self loadGameDirList];
    [self updateEmptyState];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(profileChanged)
                                                 name:@"SelectedProfileChanged"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(profileChanged)
                                                 name:@"ReloadProfileList"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleBackgroundUIEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleAccentColorChanged)
                                                 name:@"LauncherAppearanceChanged"
                                               object:nil];
}

/// FCL 风格：浮动"+"按钮放置在视图右上角，点击进入下载/新建版本页面
/// 无论导航栏是否可见都使用浮动按钮，确保按钮在所有模式下都可访问
- (void)setupNavigationBar {
    UIButton *fab = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *plusConfig = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIFontWeightBold];
    UIImage *plusImg = [UIImage systemImageNamed:@"plus" withConfiguration:plusConfig];
    [fab setImage:plusImg forState:UIControlStateNormal];
    fab.tintColor = [UIColor whiteColor];
    // 规范 2.6：使用 accentColor() 而非 systemBlueColor
    fab.backgroundColor = accentColor();
    // 规范 5.1：FAB 完全圆形（22pt 圆角 = 44/2）
    fab.layer.cornerRadius = 22;
    fab.layer.cornerCurve = kCACornerCurveContinuous;
    // 规范 5.2：FAB 阴影档（0.20, 8, (0,4)）—— 比 L2 卡片阴影更强
    fab.layer.shadowColor = [UIColor blackColor].CGColor;
    fab.layer.shadowOffset = CGSizeMake(0, 4);
    fab.layer.shadowOpacity = 0.20;
    fab.layer.shadowRadius = 8;
    // 注意：不能用 masksToBounds=YES，否则会裁掉阴影
    fab.layer.masksToBounds = NO;
    fab.translatesAutoresizingMaskIntoConstraints = NO;
    fab.accessibilityLabel = localize(@"i18n_str_2027", nil);
    [fab addTarget:self action:@selector(fabTouchDown) forControlEvents:UIControlEventTouchDown];
    [fab addTarget:self action:@selector(fabTouchUp) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [fab addTarget:self action:@selector(createNewVersion) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:fab];
    [self.view bringSubviewToFront:fab];

    [NSLayoutConstraint activateConstraints:@[
        // 规范 4.1：FAB 44x44（更好的触控目标，符合 iOS HIG）
        [fab.widthAnchor constraintEqualToConstant:44],
        [fab.heightAnchor constraintEqualToConstant:44],
        [fab.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [fab.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
    ]];

    // 规范 15.4：FAB 进场动画（JellyBounce 果冻回弹）
    fab.transform = CGAffineTransformMakeScale(0.3, 0.3);
    [UIView animateWithDuration:0.6
                          delay:0.15
         usingSpringWithDamping:0.55
          initialSpringVelocity:0.8
                         options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        fab.transform = CGAffineTransformIdentity;
    } completion:nil];
}

/// FAB 按下：缩放反馈（规范 9.3）
- (void)fabTouchDown {
    [UIView animateWithDuration:0.15 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.8 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        UIButton *fab = [self findFabButton];
        fab.transform = CGAffineTransformMakeScale(0.90, 0.90);
        fab.layer.shadowOpacity = 0.12;
        fab.layer.shadowRadius = 4;
    } completion:nil];
}

/// FAB 抬起：回弹反馈
- (void)fabTouchUp {
    [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.55 initialSpringVelocity:0.9 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        UIButton *fab = [self findFabButton];
        fab.transform = CGAffineTransformIdentity;
        fab.layer.shadowOpacity = 0.20;
        fab.layer.shadowRadius = 8;
    } completion:nil];
}

/// 找到视图中的 FAB 按钮
- (UIButton *)findFabButton {
    for (UIView *v in self.view.subviews) {
        if ([v isKindOfClass:[UIButton class]] && [v.accessibilityLabel isEqualToString:@"新建版本"]) {
            return (UIButton *)v;
        }
    }
    return nil;
}

/// 长按手势：游戏目录卡片弹出操作菜单（切换/删除），版本卡片弹出选择/编辑/删除
- (void)setupLongPressGesture {
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleLongPress:)];
    longPress.minimumPressDuration = 0.5;
    [self.collectionView addGestureRecognizer:longPress];
}

- (void)createNewVersion {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowDownloadPage" object:nil];
}

#pragma mark - Empty State

/// 创建空状态视图（无版本时显示引导，参照规范 10.1 空状态）
- (void)setupEmptyStateView {
    self.emptyStateView = [[UIView alloc] init];
    self.emptyStateView.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyStateView.hidden = YES;
    [self.view addSubview:self.emptyStateView];
    [self.view bringSubviewToFront:self.emptyStateView];

    // 规范 10.1：图标容器（80x80 圆形，accentColor 0.12 浅底）
    UIView *iconContainer = [[UIView alloc] init];
    iconContainer.translatesAutoresizingMaskIntoConstraints = NO;
    iconContainer.backgroundColor = [accentColor() colorWithAlphaComponent:0.12];
    iconContainer.layer.cornerRadius = 40;
    iconContainer.layer.cornerCurve = kCACornerCurveContinuous;
    [self.emptyStateView addSubview:iconContainer];

    UIImageSymbolConfiguration *iconConfig = [UIImageSymbolConfiguration configurationWithPointSize:36 weight:UIFontWeightRegular];
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.image = [UIImage systemImageNamed:@"cube.box" withConfiguration:iconConfig];
    iconView.tintColor = accentColor();
    [iconContainer addSubview:iconView];

    // 规范 2.1：标题用 labelColor
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:18] weight:UIFontWeightBold];
    titleLabel.textColor = [UIColor labelColor];
    titleLabel.text = localize(@"i18n_str_1056", nil);
    titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.emptyStateView addSubview:titleLabel];

    // 规范 2.1：副标题用 secondaryLabelColor
    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:13] weight:UIFontWeightRegular];
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.text = localize(@"i18n_str_1057", nil);
    subtitleLabel.textAlignment = NSTextAlignmentCenter;
    subtitleLabel.numberOfLines = 0;
    [self.emptyStateView addSubview:subtitleLabel];

    // 规范 9.2：CTA 按钮（accentColor 背景 + 白字 + 圆角）
    UIButton *ctaButton = [UIButton buttonWithType:UIButtonTypeSystem];
    ctaButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *btnIconConfig = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIFontWeightBold];
    UIImage *btnIcon = [UIImage systemImageNamed:@"arrow.down.circle.fill" withConfiguration:btnIconConfig];
    [ctaButton setImage:btnIcon forState:UIControlStateNormal];
    [ctaButton setTitle:[@"  " stringByAppendingString:localize(@"i18n_str_2028", nil)] forState:UIControlStateNormal];
    ctaButton.titleLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:15] weight:UIFontWeightSemibold];
    [ctaButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    ctaButton.tintColor = [UIColor whiteColor];
    ctaButton.backgroundColor = accentColor();
    ctaButton.layer.cornerRadius = 22;
    ctaButton.layer.cornerCurve = kCACornerCurveContinuous;
    ctaButton.layer.shadowColor = [UIColor blackColor].CGColor;
    ctaButton.layer.shadowOffset = CGSizeMake(0, 3);
    ctaButton.layer.shadowOpacity = 0.15;
    ctaButton.layer.shadowRadius = 6;
    ctaButton.layer.masksToBounds = NO;
    ctaButton.contentEdgeInsets = UIEdgeInsetsMake(0, 20, 0, 20);
    [ctaButton addTarget:self action:@selector(createNewVersion) forControlEvents:UIControlEventTouchUpInside];
    [self.emptyStateView addSubview:ctaButton];

    [NSLayoutConstraint activateConstraints:@[
        // 空状态视图居中
        [self.emptyStateView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyStateView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.emptyStateView.widthAnchor constraintEqualToAnchor:self.view.widthAnchor constant:-64],
        // 图标容器：顶部对齐，居中，80x80
        [iconContainer.topAnchor constraintEqualToAnchor:self.emptyStateView.topAnchor],
        [iconContainer.centerXAnchor constraintEqualToAnchor:self.emptyStateView.centerXAnchor],
        [iconContainer.widthAnchor constraintEqualToConstant:80],
        [iconContainer.heightAnchor constraintEqualToConstant:80],
        // 图标居中
        [iconView.centerXAnchor constraintEqualToAnchor:iconContainer.centerXAnchor],
        [iconView.centerYAnchor constraintEqualToAnchor:iconContainer.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:36],
        [iconView.heightAnchor constraintEqualToConstant:36],
        // 标题：图标下方 16pt
        [titleLabel.topAnchor constraintEqualToAnchor:iconContainer.bottomAnchor constant:16],
        [titleLabel.leadingAnchor constraintEqualToAnchor:self.emptyStateView.leadingAnchor],
        [titleLabel.trailingAnchor constraintEqualToAnchor:self.emptyStateView.trailingAnchor],
        // 副标题：标题下方 6pt
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:6],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:self.emptyStateView.leadingAnchor],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:self.emptyStateView.trailingAnchor],
        // CTA 按钮：副标题下方 24pt
        [ctaButton.topAnchor constraintEqualToAnchor:subtitleLabel.bottomAnchor constant:24],
        [ctaButton.centerXAnchor constraintEqualToAnchor:self.emptyStateView.centerXAnchor],
        [ctaButton.heightAnchor constraintEqualToConstant:44],
        [ctaButton.bottomAnchor constraintEqualToAnchor:self.emptyStateView.bottomAnchor]
    ]];
}

/// 根据版本列表数量显示/隐藏空状态视图
- (void)updateEmptyState {
    BOOL isEmpty = (self.profileList.count == 0);
    self.emptyStateView.hidden = !isEmpty;
    self.collectionView.hidden = isEmpty;

    if (isEmpty) {
        // 规范 15.4：空状态进场动画（果冻回弹 + 淡入）
        self.emptyStateView.alpha = 0;
        self.emptyStateView.transform = CGAffineTransformMakeScale(0.85, 0.85);
        [UIView animateWithDuration:0.5
                              delay:0.1
             usingSpringWithDamping:0.7
              initialSpringVelocity:0.6
                             options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            self.emptyStateView.alpha = 1;
            self.emptyStateView.transform = CGAffineTransformIdentity;
        } completion:nil];
    }
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    CGPoint point = [gesture locationInView:self.collectionView];
    NSIndexPath *indexPath = [self.collectionView indexPathForItemAtPoint:point];
    if (!indexPath) return;

    if (indexPath.section == kSectionGameDir) {
        // 游戏目录区段：长按弹出切换/删除菜单（不含"新建目录"按钮项）
        if (indexPath.item >= (NSInteger)self.gameDirList.count) return;
        NSString *dirName = self.gameDirList[indexPath.item];
        [self showGameDirActions:dirName];
    } else if (indexPath.section == kSectionVersions) {
        // 版本卡片区段：长按弹出操作菜单（选择/删除）
        if (indexPath.item >= (NSInteger)self.profileList.count) return;
        [self showProfileActions:self.profileList[indexPath.item]];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 重新隐藏导航栏黑条（pop 回根页面时 topViewController == self）
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil &&
        self.navigationController.topViewController == self) {
        self.navigationController.navigationBarHidden = YES;
        // 规范 4.1：导航栏隐藏时，顶部 inset 需为 FAB 留出空间
        CGFloat topInset = self.view.safeAreaInsets.top + 8 + 44 + 8;
        self.collectionView.contentInset = UIEdgeInsetsMake(topInset, 0, 24, 0);
        self.collectionView.scrollIndicatorInsets = UIEdgeInsetsMake(topInset, 0, 24, 0);
    }
    [PLProfiles updateCurrent];
    [self loadProfiles];
    [self loadGameDirList];
    [self.collectionView reloadData];
    [self updateEmptyState];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // push 子页面时显示导航栏（子页面需要返回按钮）
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil) {
        self.navigationController.navigationBarHidden = NO;
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)profileChanged {
    [PLProfiles updateCurrent];
    [self loadProfiles];
    [self loadGameDirList];
    [self.collectionView reloadData];
    [self updateEmptyState];
}

- (void)handleBackgroundUIEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.collectionView reloadData];
    });
}

- (void)handleAccentColorChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.collectionView reloadData];
        [self updateEmptyState];
    });
}

#pragma mark - Renderer Data Setup

/// 初始化渲染器选项数据（启动器 native 渲染器库选择，LWJGL 层）
/// 参照 FCL/HMCL 的渲染器选择面板，提供 7 个选项及对应描述
/// 注意：名称使用简短标识，不使用 getRendererNames 返回的长本地化字符串
- (void)setupRendererData {
    self.rendererKeys = getRendererKeys(NO);
    // 简短渲染器名称（不使用 getRendererNames 的长本地化字符串）
    // 顺序必须与 getRendererKeys() 完全一致（索引配对）
    self.rendererNames = @[
        @"Auto",
        @"GL4ES",
        @"ANGLE",
        @"MobileGlues",
        @"Zink",
        @"LTW",
        @"MoltenVK"
    ];
    self.rendererIcons = @[
        @"wand.and.stars",
        @"cpu",
        @"rectangle.stack.fill",
        @"bolt.fill",
        @"circle.hexagongrid.fill",
        @"square.stack.3d.up.fill",
        @"flame.fill"
    ];
    self.rendererDescs = @[
        localize(@"i18n_str_1059", nil),
        localize(@"i18n_str_1060", nil),
        localize(@"i18n_str_1061", nil),
        localize(@"i18n_str_1062", nil),
        localize(@"i18n_str_1063", nil),
        localize(@"i18n_str_1064", nil),
        localize(@"i18n_str_1065", nil)
    ];
}

#pragma mark - Graphics API Data Setup (MC 26.2+)

/// 初始化图形 API 选项数据（MC 26.2+ 游戏内 OpenGL/Vulkan 切换，游戏层）
///
/// Mojang 在 MC 26.2 Snapshot 1 引入了 "Graphics API" 视频设置项，有 3 个值：
///   - default        由 Mojang 决定（snapshot-1~7 为 Vulkan，snapshot-8+ 为 OpenGL）
///   - prefer_vulkan  优先使用 Vulkan，失败时回退 OpenGL
///   - prefer_opengl  优先使用 OpenGL，失败时回退 Vulkan
///
/// 注意：与渲染器（renderer）是两个不同维度
- (void)setupGraphicsApiData {
    self.graphicsApiKeys = @[@"default", @"prefer_vulkan", @"prefer_opengl"];
    self.graphicsApiNames = @[localize(@"i18n_str_943", nil), localize(@"i18n_str_941", nil), localize(@"i18n_str_942", nil)];
    self.graphicsApiIcons = @[
        @"wand.and.stars",
        @"flame.fill",
        @"rectangle.stack.fill"
    ];
    self.graphicsApiDescs = @[
        localize(@"i18n_str_1066", nil),
        localize(@"i18n_str_1067", nil),
        localize(@"i18n_str_1068", nil)
    ];
}

/// 判断当前选中 profile 的版本是否为 MC 26.2+（即 1.21.8+ 后的新版本号方案）
/// 26.x 系列 = 1.21.8 起的快照/正式版采用的新版本号格式
- (BOOL)isCurrentProfileModernVersion {
    if (!self.selectedProfile) return NO;
    NSDictionary *profile = PLProfiles.current.profiles[self.selectedProfile];
    NSString *versionId = profile[@"lastVersionId"];
    if (!versionId) return NO;
    // 修复 Fabric/Quilt/Forge loader profile 的版本号识别：
    //   原实现用 digits 字符集截取 prefix，但 fabric-loader-0.16.0-26.2 的第 0 个
    //   字符 'f' 不是数字，prefix 截成空字符串，导致 MC 26.2+ Fabric profile
    //   看不到"图形 API"选项。
    //   修复：先用 ModpackExportService.parseVersionId 提取 minecraft 版本号，
    //   再用提取后的版本号判断。也支持 forge/neoforge 形如 "26.2-forge-..."。
    NSDictionary *parsed = [ModpackExportService parseVersionId:versionId];
    NSString *mcVersion = parsed[@"minecraft"] ?: versionId;
    // 26.x 系列
    if ([mcVersion hasPrefix:@"26."]) return YES;
    if ([mcVersion hasPrefix:@"26w"]) return YES;
    // 1.21.8 及以上
    if ([mcVersion hasPrefix:@"1.21."]) {
        NSString *minorStr = [mcVersion substringFromIndex:5];
        NSInteger minor = [minorStr integerValue];
        if (minor >= 8) return YES;
    }
    return NO;
}

/// 获取当前选中 profile 的渲染器（如未设置则回退到全局偏好）
- (NSString *)currentRendererForSelectedProfile {
    if (!self.selectedProfile) return @"auto";
    return [PLProfiles profile:PLProfiles.current.profiles[self.selectedProfile] resolveKey:@"renderer"] ?: @"auto";
}

/// 获取当前选中 profile 的图形 API（MC 26.2+，如未设置则回退到全局偏好，再回退到 default）
- (NSString *)currentGraphicsApiForSelectedProfile {
    if (!self.selectedProfile) return @"default";
    NSDictionary *profile = PLProfiles.current.profiles[self.selectedProfile];
    NSString *g = profile[@"graphicsApi"];
    if (g.length == 0) {
        g = getPrefObject(@"video.graphics_api");
    }
    return g.length > 0 ? g : @"default";
}

#pragma mark - Setup

- (void)setupCollectionView {
    UICollectionViewLayout *layout = [self createLayout];
    self.collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:layout];
    self.collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.alwaysBounceVertical = YES;
    self.collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    // 规范 4.1：顶部 inset 需为 FAB 留出空间（FAB 44pt + 顶部 8pt + 间距 8pt = 60pt）
    // 避免第一个 section header 的 count badge 被 FAB 遮挡
    CGFloat topInset;
    if (self.navigationController && self.navigationController.navigationBarHidden) {
        // 导航栏隐藏：FAB 位于 safeAreaTop + 8，高度 44
        topInset = self.view.safeAreaInsets.top + 8 + 44 + 8;
    } else {
        // 导航栏可见：FAB 位于 navBar 底部 + 8，高度 44
        CGFloat navBarHeight = 44.0;
        if (self.navigationController && self.navigationController.navigationBar.bounds.size.height > 0) {
            navBarHeight = self.navigationController.navigationBar.bounds.size.height;
        }
        topInset = navBarHeight + 8 + 44 + 8;
    }
    self.collectionView.contentInset = UIEdgeInsetsMake(topInset, 0, 24, 0);
    self.collectionView.scrollIndicatorInsets = UIEdgeInsetsMake(topInset, 0, 24, 0);

    [self.collectionView registerClass:[VMGameDirCell class] forCellWithReuseIdentifier:@"GameDirCell"];
    [self.collectionView registerClass:[VMVersionCardCell class] forCellWithReuseIdentifier:@"VersionCell"];
    [self.collectionView registerClass:[VMSectionHeaderView class] forSupplementaryViewOfKind:UICollectionElementKindSectionHeader withReuseIdentifier:@"HeaderView"];

    [self.view addSubview:self.collectionView];
}

- (UICollectionViewLayout *)createLayout {
    return [[UICollectionViewCompositionalLayout alloc] initWithSectionProvider:^NSCollectionLayoutSection * _Nullable(NSInteger sectionIndex, id<NSCollectionLayoutEnvironment> _Nonnull layoutEnvironment) {
        CGFloat width = layoutEnvironment.container.contentSize.width;
        BOOL isiPad = width > 700;

        // 规范 4.1：Header 估计高度 48pt
        NSCollectionLayoutSize *headerSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                                                                              heightDimension:[NSCollectionLayoutDimension estimatedDimension:48]];
        NSCollectionLayoutBoundarySupplementaryItem *header = [NSCollectionLayoutBoundarySupplementaryItem boundarySupplementaryItemWithLayoutSize:headerSize elementKind:UICollectionElementKindSectionHeader alignment:NSRectAlignmentTop];
        header.contentInsets = NSDirectionalEdgeInsetsMake(0, 0, 0, 0);

        if (sectionIndex == kSectionGameDir) {
            // 游戏目录区段：横向滚动卡片列表
            // 规范 4.1：卡片宽度 160pt（iPad 180pt），高度 70pt（给图标容器留呼吸空间）
            CGFloat itemWidth = isiPad ? 180 : 160;
            CGFloat itemHeight = 70;
            NSCollectionLayoutSize *itemSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension absoluteDimension:itemWidth]
                                                                                       heightDimension:[NSCollectionLayoutDimension absoluteDimension:itemHeight]];
            NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:itemSize];
            // 规范 4.1：卡片间距 8pt（上下各 4pt）
            item.contentInsets = NSDirectionalEdgeInsetsMake(4, 5, 4, 5);

            NSCollectionLayoutSize *groupSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension absoluteDimension:itemWidth]
                                                                                          heightDimension:[NSCollectionLayoutDimension absoluteDimension:itemHeight]];
            NSCollectionLayoutGroup *group = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:groupSize subitems:@[item]];

            NSCollectionLayoutSection *section = [NSCollectionLayoutSection sectionWithGroup:group];
            section.orthogonalScrollingBehavior = UICollectionLayoutSectionOrthogonalScrollingBehaviorContinuous;
            // 规范 4.1：边距 16pt，section 间距 8pt
            section.contentInsets = NSDirectionalEdgeInsetsMake(0, 16, 8, 16);
            section.boundarySupplementaryItems = @[header];
            return section;
        } else {
            // 版本卡片区段：紧凑列表（iPad 双列，iPhone 单列）
            // 规范 4.1：iPad 双列时增加列间距
            CGFloat itemWidth = isiPad ? 0.5 : 1.0;
            // 规范 4.1：卡片高度 84pt（给 34pt 图标容器 + 三行文字留呼吸空间）
            CGFloat itemHeight = 84;
            NSCollectionLayoutSize *itemSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:itemWidth]
                                                                                       heightDimension:[NSCollectionLayoutDimension absoluteDimension:itemHeight]];
            NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:itemSize];
            // 规范 4.1：卡片间距 8pt（上下各 4pt），左右 8pt
            item.contentInsets = NSDirectionalEdgeInsetsMake(4, 8, 4, 8);

            NSCollectionLayoutSize *groupSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                                                                                          heightDimension:[NSCollectionLayoutDimension absoluteDimension:itemHeight]];
            NSCollectionLayoutGroup *group = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:groupSize subitems:@[item]];

            NSCollectionLayoutSection *section = [NSCollectionLayoutSection sectionWithGroup:group];
            // 规范 4.1：列间距 8pt（iPad 双列时）
            section.interGroupSpacing = isiPad ? 8 : 0;
            // 规范 4.1：边距 16pt，底部 24pt（留出底部呼吸空间）
            section.contentInsets = NSDirectionalEdgeInsetsMake(0, 16, 24, 16);
            section.boundarySupplementaryItems = @[header];
            return section;
        }
    }];
}

#pragma mark - Data

- (void)loadProfiles {
    NSMutableDictionary *profiles = PLProfiles.current.profiles;
    NSMutableArray *list = [NSMutableArray array];
    for (NSString *key in profiles.allKeys) {
        [list addObject:key];
    }
    self.profileList = [list sortedArrayUsingComparator:^NSComparisonResult(NSString *obj1, NSString *obj2) {
        return [obj2 compare:obj1];
    }];
    self.selectedProfile = PLProfiles.current.selectedProfileName;
}

/// 加载游戏目录（实例）列表
- (void)loadGameDirList {
    NSMutableArray *list = [NSMutableArray array];
    [list addObject:@"default"];

    NSString *instancesPath = [NSString stringWithFormat:@"%s/instances", getenv("POJAV_HOME")];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:instancesPath error:nil];
    BOOL isDir = NO;
    for (NSString *file in files) {
        NSString *fullPath = [instancesPath stringByAppendingPathComponent:file];
        if ([fm fileExistsAtPath:fullPath isDirectory:&isDir] && isDir && ![file isEqualToString:@"default"]) {
            [list addObject:file];
        }
    }
    self.gameDirList = list;
    id raw = getPrefObject(@"general.game_directory");
    self.currentGameDir = [raw isKindOfClass:[NSString class]] ? raw : @"default";
}

#pragma mark - UICollectionViewDataSource

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return 2;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    if (section == kSectionGameDir) {
        return self.gameDirList.count + 1;  // 末尾追加"新建目录"按钮
    } else {
        return self.profileList.count;
    }
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == kSectionGameDir) {
        VMGameDirCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"GameDirCell" forIndexPath:indexPath];

        if (indexPath.item == (NSInteger)self.gameDirList.count) {
            [cell configureWithName:nil detail:nil isSelected:NO isAddButton:YES];
            return cell;
        }

        NSString *dirName = self.gameDirList[indexPath.item];
        BOOL isSelected = [dirName isEqualToString:self.currentGameDir];

        // 异步计算目录大小
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            unsigned long long folderSize = 0;
            NSString *directory = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), dirName];
            [weakSelf calculateFolderSizeAtPath:directory size:&folderSize];
            NSString *sizeStr = [NSByteCountFormatter stringFromByteCount:folderSize countStyle:NSByteCountFormatterCountStyleMemory];
            dispatch_async(dispatch_get_main_queue(), ^{
                VMGameDirCell *targetCell = (VMGameDirCell *)[collectionView cellForItemAtIndexPath:indexPath];
                if (targetCell && [targetCell isKindOfClass:[VMGameDirCell class]]) {
                    targetCell.detailLabel.text = sizeStr;
                }
            });
        });

        [cell configureWithName:dirName detail:localize(@"i18n_str_134", nil) isSelected:isSelected isAddButton:NO];
        return cell;
    } else {
        VMVersionCardCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"VersionCell" forIndexPath:indexPath];

        NSString *profileName = self.profileList[indexPath.item];
        NSDictionary *profile = PLProfiles.current.profiles[profileName];
        NSString *versionId = profile[@"lastVersionId"] ?: localize(@"i18n_str_1052", nil);
        BOOL isSelected = [profileName isEqualToString:self.selectedProfile];
        NSString *gameDir = profile[@"gameDir"] ?: @".";
        BOOL isolated = ![gameDir isEqualToString:@"."];
        NSString *lastPlayed = [self formatLastPlayed:profile[@"lastPlayed"]];

        [cell configureWithName:profileName version:versionId isSelected:isSelected isolated:isolated lastPlayed:lastPlayed];
        return cell;
    }
}

/// 简易目录大小计算（递归）
- (void)calculateFolderSizeAtPath:(NSString *)path size:(unsigned long long *)size {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:path];
    NSString *relativePath;
    while ((relativePath = [enumerator nextObject])) {
        NSString *fullPath = [path stringByAppendingPathComponent:relativePath];
        NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
        if (attrs) {
            *size += [attrs fileSize];
        }
    }
}

/// 将 lastPlayed 时间戳格式化为"最后游玩：xxx"
- (NSString *)formatLastPlayed:(id)lastPlayedRaw {
    if (!lastPlayedRaw) return @"";
    NSTimeInterval ts;
    if ([lastPlayedRaw isKindOfClass:[NSNumber class]]) {
        ts = [lastPlayedRaw doubleValue];
    } else if ([lastPlayedRaw isKindOfClass:[NSString class]]) {
        ts = [(NSString *)lastPlayedRaw doubleValue];
    } else {
        return @"";
    }
    if (ts <= 0) return @"";
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:ts];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale currentLocale];
    fmt.doesRelativeDateFormatting = YES;
    fmt.dateStyle = NSDateFormatterShortStyle;
    fmt.timeStyle = NSDateFormatterShortStyle;
    return [NSString stringWithFormat:localize(@"i18n_str_1069", nil), [fmt stringFromDate:date]];
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath {
    if (kind == UICollectionElementKindSectionHeader) {
        VMSectionHeaderView *header = [collectionView dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:@"HeaderView" forIndexPath:indexPath];
        switch (indexPath.section) {
            case kSectionGameDir:
                [header configureWithIcon:@"folder.badge.gearshape"
                                     title:localize(@"i18n_str_1070", nil)
                                  subtitle:localize(@"i18n_str_1071", nil)
                                     count:(NSInteger)self.gameDirList.count];
                break;
            case kSectionVersions:
                [header configureWithIcon:@"cube.box.fill"
                                     title:localize(@"i18n_str_1072", nil)
                                  subtitle:localize(@"i18n_str_1073", nil)
                                     count:(NSInteger)self.profileList.count];
                break;
            default:
                [header configureWithIcon:@""
                                     title:@""
                                  subtitle:@""
                                     count:-1];
                break;
        }
        return header;
    }
    return [UICollectionReusableView new];
}

#pragma mark - UICollectionViewDelegate

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];

    if (indexPath.section == kSectionGameDir) {
        if (indexPath.item == (NSInteger)self.gameDirList.count) {
            [self showCreateGameDirAlert];
        } else {
            NSString *dirName = self.gameDirList[indexPath.item];
            if (![dirName isEqualToString:self.currentGameDir]) {
                [self switchGameDirTo:dirName];
            }
        }
    } else if (indexPath.section == kSectionVersions) {
        // 点击版本卡片直接进入该版本的专属设置页（FCL 风格）
        NSString *profileName = self.profileList[indexPath.item];
        [self editProfile:profileName];
    }
}

#pragma mark - Game Directory Actions

/// 切换游戏目录（实例），重建符号链接
- (void)switchGameDirTo:(NSString *)name {
    if (getenv("DEMO_LOCK")) return;

    setPrefObject(@"general.game_directory", name);
    NSString *multidirPath = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), name];
    NSString *lasmPath = @(getenv("POJAV_GAME_DIR"));
    NSError *removeError = nil;
    [NSFileManager.defaultManager removeItemAtPath:lasmPath error:&removeError];

    NSError *linkError = nil;
    BOOL linkOK = [NSFileManager.defaultManager createSymbolicLinkAtPath:lasmPath
                                                       withDestinationPath:multidirPath
                                                                     error:&linkError];
    if (!linkOK) {
        NSLog(@"[VersionMgr] createSymbolicLink failed: %@", linkError.localizedDescription);
        [self showAlert:[NSString stringWithFormat:localize(@"i18n_str_1074", nil), linkError.localizedDescription]];
        return;
    }
    [NSFileManager.defaultManager changeCurrentDirectoryPath:lasmPath];
    toggleIsolatedPref(NO);
    [PLProfiles updateCurrent];

    [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:nil];

    [self loadGameDirList];
    [self loadProfiles];
    [self.collectionView reloadData];
    [self updateEmptyState];
}

/// 弹出新建游戏目录对话框
- (void)showCreateGameDirAlert {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_1075", nil)
                                                                   message:localize(@"i18n_str_1076", nil)
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = localize(@"i18n_str_1077", nil);
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.delegate = self;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_1078", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *name = alert.textFields.firstObject.text;
        if (name.length == 0) return;
        [self createGameDirWithName:name];
    }]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)createGameDirWithName:(NSString *)name {
    NSString *dest = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), name];
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:&error]) {
        [self showAlert:[NSString stringWithFormat:localize(@"i18n_str_1079", nil), error.localizedDescription]];
        return;
    }
    [self switchGameDirTo:name];
}

/// 长按游戏目录卡片弹出操作菜单：切换/删除当前目录
- (void)showGameDirActions:(NSString *)dirName {
    BOOL isSelected = [dirName isEqualToString:self.currentGameDir];
    BOOL isDefault = [dirName isEqualToString:@"default"];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:dirName
                                                                   message:isSelected ? localize(@"i18n_str_2029", nil) : localize(@"i18n_str_1081", nil)
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    if (!isSelected) {
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_1081", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self switchGameDirTo:dirName];
        }]];
    }

    // 删除目录（默认目录禁止删除，正在使用的目录需要先切换才能删除）
    if (!isDefault) {
        NSString *deleteTitle = isSelected ? localize(@"i18n_str_2030", nil) : localize(@"i18n_str_1083", nil);
        [alert addAction:[UIAlertAction actionWithTitle:deleteTitle style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            if (isSelected) {
                [self showAlert:localize(@"i18n_str_1084", nil)];
                return;
            }
            [self confirmDeleteGameDir:dirName];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
        alert.popoverPresentationController.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }
    [self presentViewController:alert animated:YES completion:nil];
}

/// 二次确认删除游戏目录
- (void)confirmDeleteGameDir:(NSString *)dirName {
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_1085", nil)
                                                                     message:[NSString stringWithFormat:localize(@"i18n_str_1086", nil), dirName]
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_457", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self deleteGameDir:dirName];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

/// 删除指定游戏目录
- (void)deleteGameDir:(NSString *)dirName {
    if ([dirName isEqualToString:@"default"]) {
        [self showAlert:localize(@"i18n_str_1087", nil)];
        return;
    }
    if ([dirName isEqualToString:self.currentGameDir]) {
        [self showAlert:localize(@"i18n_str_1084", nil)];
        return;
    }

    NSString *dest = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), dirName];
    NSError *error = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:dest error:&error]) {
        [self showAlert:[NSString stringWithFormat:localize(@"i18n_str_1088", nil), error.localizedDescription]];
        return;
    }

    [self loadGameDirList];
    [self.collectionView reloadData];
    [self updateEmptyState];
    [self showAlert:[NSString stringWithFormat:localize(@"i18n_str_1089", nil), dirName]];
}

#pragma mark - Renderer Selection (启动器 native 库选择)

/// 选择渲染器并保存到当前 profile
- (void)selectRendererAtIndex:(NSInteger)index {
    if (!self.selectedProfile) {
        [self showAlert:localize(@"i18n_str_431", nil)];
        return;
    }
    if (index >= (NSInteger)self.rendererKeys.count) return;

    NSString *key = self.rendererKeys[index];
    NSString *displayName = index < (NSInteger)self.rendererNames.count ? self.rendererNames[index] : key;

    // 写入当前 profile 的 renderer 字段
    NSMutableDictionary *profiles = PLProfiles.current.profiles;
    NSMutableDictionary *profile = [profiles[self.selectedProfile] mutableCopy];
    if (!profile) {
        profile = [NSMutableDictionary dictionary];
    }
    profile[@"renderer"] = key;
    profiles[self.selectedProfile] = profile;
    [PLProfiles.current save];

    [self.collectionView reloadData];

    NSLog(@"[VersionMgr] Renderer for profile '%@' set to '%@' (%@)", self.selectedProfile, key, displayName);
}

#pragma mark - Graphics API Selection (MC 26.2+ 游戏内 OpenGL/Vulkan)

/// 选择图形 API 并保存到当前 profile
/// 注意：graphicsApi 与 renderer 是两个不同维度：
///   - renderer：LWJGL 加载哪个 native 库（libgl4es/libMoltenVK 等）
///   - graphicsApi：MC 26.2+ 内部走 OpenGL 路径还是 Vulkan 路径
/// 当用户选择 prefer_vulkan 时建议同步将 renderer 设为 libMoltenVK.dylib，
/// 但此处不强制联动，允许高级用户分开配置。
- (void)selectGraphicsApiAtIndex:(NSInteger)index {
    if (!self.selectedProfile) {
        [self showAlert:localize(@"i18n_str_431", nil)];
        return;
    }
    if (index >= (NSInteger)self.graphicsApiKeys.count) return;

    NSString *key = self.graphicsApiKeys[index];
    NSString *displayName = index < (NSInteger)self.graphicsApiNames.count ? self.graphicsApiNames[index] : key;

    // 写入当前 profile 的 graphicsApi 字段
    NSMutableDictionary *profiles = PLProfiles.current.profiles;
    NSMutableDictionary *profile = [profiles[self.selectedProfile] mutableCopy];
    if (!profile) {
        profile = [NSMutableDictionary dictionary];
    }
    profile[@"graphicsApi"] = key;
    profiles[self.selectedProfile] = profile;
    [PLProfiles.current save];

    [self.collectionView reloadData];

    NSLog(@"[VersionMgr] Graphics API for profile '%@' set to '%@' (%@)", self.selectedProfile, key, displayName);
}

#pragma mark - Quick Actions

- (void)openModsManager {
    if (!self.selectedProfile) {
        [self showAlert:localize(@"i18n_str_431", nil)];
        return;
    }
    ModsManagerViewController *vc = [[ModsManagerViewController alloc] init];
    vc.profileName = self.selectedProfile;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openShadersManager {
    if (!self.selectedProfile) {
        [self showAlert:localize(@"i18n_str_431", nil)];
        return;
    }
    ShadersManagerViewController *vc = [[ShadersManagerViewController alloc] init];
    vc.profileName = self.selectedProfile;
    vc.initialMode = ShadersManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openResourcePacksManager {
    if (!self.selectedProfile) {
        [self showAlert:localize(@"i18n_str_431", nil)];
        return;
    }
    ResourcePacksManagerViewController *vc = [[ResourcePacksManagerViewController alloc] init];
    vc.profileName = self.selectedProfile;
    vc.initialMode = ResourcePacksManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openDataPacksManager {
    if (!self.selectedProfile) {
        [self showAlert:localize(@"i18n_str_431", nil)];
        return;
    }
    DataPacksManagerViewController *vc = [[DataPacksManagerViewController alloc] init];
    vc.profileName = self.selectedProfile;
    vc.initialMode = DataPacksManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openWorldsManager {
    if (!self.selectedProfile) {
        [self showAlert:localize(@"i18n_str_431", nil)];
        return;
    }
    WorldsManagerViewController *vc = [[WorldsManagerViewController alloc] init];
    vc.profileName = self.selectedProfile;
    vc.initialMode = WorldsManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - Profile Actions

- (void)showProfileActions:(NSString *)profileName {
    NSDictionary *profile = PLProfiles.current.profiles[profileName];
    BOOL isSelected = [profileName isEqualToString:self.selectedProfile];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:profileName
                                                                   message:profile[@"lastVersionId"]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    if (!isSelected) {
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_1090", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            PLProfiles.current.selectedProfileName = profileName;
            [PLProfiles.current save];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:nil];
            [self loadProfiles];
            [self.collectionView reloadData];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_1091", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self editProfile:profileName];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_306", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self deleteProfile:profileName];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
        alert.popoverPresentationController.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)editProfile:(NSString *)profileName {
    // 关键修复（实例渲染器不生效）：点击版本卡片进入其实例设置时，
    // 必须把该 profile 同步为"当前选中实例"。否则用户在实例设置里切换的渲染器
    // 保存在被点击的 profile 上，而启动游戏时 JavaLauncher 只读取
    // PLProfiles.current.selectedProfileName（当前选中实例）的 renderer，
    // 两者不一致时启动会回退到全局 video.renderer（表现为"实例设置改了渲染器，启动却用全局"）。
    // setSelectedProfileName: 内部会保存并发送 SelectedProfileChanged 通知。
    if (![PLProfiles.current.selectedProfileName isEqualToString:profileName]) {
        PLProfiles.current.selectedProfileName = profileName;
        [self loadProfiles];
        [self.collectionView reloadData];
        [self updateEmptyState];
    }

    // 使用 ProfileSettingsViewController（合并后的统一 Edit Profile 页面，新 UI）
    ProfileSettingsViewController *vc = [[ProfileSettingsViewController alloc] init];
    vc.profileName = profileName;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)deleteProfile:(NSString *)profileName {
    if (self.profileList.count <= 1) {
        [self showAlert:localize(@"i18n_str_1092", nil)];
        return;
    }

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_457", nil)
                                                                     message:[NSString stringWithFormat:localize(@"i18n_str_1093", nil), profileName]
                                                              preferredStyle:UIAlertControllerStyleAlert];

    [confirm addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_306", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [PLProfiles.current.profiles removeObjectForKey:profileName];
        if ([PLProfiles.current.selectedProfileName isEqualToString:profileName]) {
            PLProfiles.current.selectedProfileName = PLProfiles.current.profiles.allKeys.firstObject;
        }
        [PLProfiles.current save];
        [self loadProfiles];
        [self.collectionView reloadData];
        [self updateEmptyState];
    }]];

    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)showAlert:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_388", nil) message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    if ([ScreenUtils isPad]) {
        return UIInterfaceOrientationMaskAll;
    }
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

@end
