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
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOffset = CGSizeMake(0, 3);
    self.layer.shadowOpacity = 0.12;
    self.layer.shadowRadius = 6;
    self.layer.masksToBounds = NO;

    self.contentContainer = [[UIView alloc] initWithFrame:self.contentView.bounds];
    self.contentContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.contentContainer.layer.cornerRadius = 12;
    self.contentContainer.layer.masksToBounds = YES;
    [self.contentView addSubview:self.contentContainer];

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
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *versionLabel;
@property (nonatomic, strong) UILabel *lastPlayedLabel;
@property (nonatomic, strong) UIView *selectedBadge;
@property (nonatomic, strong) UILabel *isolatedBadge;
@end

@implementation VMVersionCardCell

- (void)setupViews {
    [super setupViews];

    CGFloat iconSize = [ScreenUtils dp:30];
    CGFloat nameFont = [ScreenUtils sp:15];

    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.image = [UIImage systemImageNamed:@"cube.box.fill"];
    self.iconView.tintColor = [UIColor systemBlueColor];
    [self.contentContainer addSubview:self.iconView];

    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.nameLabel.font = [UIFont systemFontOfSize:nameFont weight:UIFontWeightSemibold];
    self.nameLabel.textColor = [UIColor whiteColor];
    self.nameLabel.numberOfLines = 1;
    self.nameLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.nameLabel];

    self.versionLabel = [[UILabel alloc] init];
    self.versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:11] weight:UIFontWeightRegular];
    self.versionLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.65];
    self.versionLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.versionLabel];

    self.lastPlayedLabel = [[UILabel alloc] init];
    self.lastPlayedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.lastPlayedLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:10] weight:UIFontWeightRegular];
    self.lastPlayedLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.45];
    self.lastPlayedLabel.text = @"";
    self.lastPlayedLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.lastPlayedLabel];

    self.selectedBadge = [[UIView alloc] init];
    self.selectedBadge.translatesAutoresizingMaskIntoConstraints = NO;
    self.selectedBadge.backgroundColor = accentColor();
    self.selectedBadge.layer.cornerRadius = 10;
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
    self.isolatedBadge.layer.masksToBounds = YES;
    self.isolatedBadge.text = @" 隔离 ";
    self.isolatedBadge.hidden = YES;
    [self.contentContainer addSubview:self.isolatedBadge];

    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:14],
        [self.iconView.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.iconView.widthAnchor constraintEqualToConstant:iconSize],
        [self.iconView.heightAnchor constraintEqualToConstant:iconSize],
        [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:10],
        [self.nameLabel.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:12],
        [self.nameLabel.trailingAnchor constraintEqualToAnchor:self.selectedBadge.leadingAnchor constant:-8],
        [self.versionLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [self.versionLabel.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:3],
        [self.versionLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-14],
        [self.lastPlayedLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [self.lastPlayedLabel.topAnchor constraintEqualToAnchor:self.versionLabel.bottomAnchor constant:2],
        [self.lastPlayedLabel.trailingAnchor constraintEqualToAnchor:self.isolatedBadge.leadingAnchor constant:-6],
        [self.isolatedBadge.centerYAnchor constraintEqualToAnchor:self.lastPlayedLabel.centerYAnchor],
        [self.isolatedBadge.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-14],
        [self.isolatedBadge.heightAnchor constraintEqualToConstant:16],
        [self.selectedBadge.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-14],
        [self.selectedBadge.centerYAnchor constraintEqualToAnchor:self.nameLabel.centerYAnchor],
        [self.selectedBadge.widthAnchor constraintEqualToConstant:20],
        [self.selectedBadge.heightAnchor constraintEqualToConstant:20],
        [checkmark.centerXAnchor constraintEqualToAnchor:self.selectedBadge.centerXAnchor],
        [checkmark.centerYAnchor constraintEqualToAnchor:self.selectedBadge.centerYAnchor]
    ]];
}

- (void)configureWithName:(NSString *)name version:(NSString *)version isSelected:(BOOL)isSelected isolated:(BOOL)isolated lastPlayed:(NSString *)lastPlayed {
    self.nameLabel.text = name;
    self.versionLabel.text = version ?: @"未知版本";
    self.selectedBadge.hidden = !isSelected;
    self.selectedBadge.backgroundColor = accentColor();
    self.isolatedBadge.hidden = !isolated;
    self.lastPlayedLabel.text = lastPlayed.length > 0 ? lastPlayed : @"";

    NSString *detectedLoader = [ModLoaderIconHelper detectLoaderFromVersionId:version];
    if (detectedLoader) {
        [ModLoaderIconHelper configureImageView:self.iconView
                                      forLoader:detectedLoader
                                 traitCollection:self.traitCollection];
    } else {
        self.iconView.image = [UIImage systemImageNamed:@"cube.box.fill"];
        self.iconView.tintColor = [UIColor systemBlueColor];
    }

    if (isSelected) {
        self.contentView.layer.borderColor = accentColor().CGColor;
        self.contentView.layer.borderWidth = 1.5;
    } else {
        self.contentView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12].CGColor;
        self.contentView.layer.borderWidth = 0.5;
    }
}

@end

#pragma mark - Game Directory Cell (FCL 风格版本隔离卡片)

@interface VMGameDirCell : VMTileBaseCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UIView *selectedBadge;
@end

@implementation VMGameDirCell

- (void)setupViews {
    [super setupViews];

    CGFloat iconSize = [ScreenUtils dp:22];
    CGFloat nameFont = [ScreenUtils sp:13];

    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.image = [UIImage systemImageNamed:@"folder.fill"];
    self.iconView.tintColor = [UIColor systemBlueColor];
    [self.contentContainer addSubview:self.iconView];

    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.nameLabel.font = [UIFont systemFontOfSize:nameFont weight:UIFontWeightSemibold];
    self.nameLabel.textColor = [UIColor whiteColor];
    self.nameLabel.numberOfLines = 1;
    self.nameLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.nameLabel];

    self.detailLabel = [[UILabel alloc] init];
    self.detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.detailLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:10] weight:UIFontWeightRegular];
    self.detailLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.6];
    self.detailLabel.numberOfLines = 0;
    self.detailLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.detailLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.detailLabel];

    self.selectedBadge = [[UIView alloc] init];
    self.selectedBadge.translatesAutoresizingMaskIntoConstraints = NO;
    self.selectedBadge.backgroundColor = accentColor();
    self.selectedBadge.layer.cornerRadius = 9;
    self.selectedBadge.hidden = YES;
    [self.contentContainer addSubview:self.selectedBadge];

    UIImageView *checkmark = [[UIImageView alloc] init];
    checkmark.translatesAutoresizingMaskIntoConstraints = NO;
    checkmark.image = [UIImage systemImageNamed:@"checkmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:8 weight:UIFontWeightBold]];
    checkmark.tintColor = [UIColor whiteColor];
    [self.selectedBadge addSubview:checkmark];

    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:10],
        [self.iconView.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.iconView.widthAnchor constraintEqualToConstant:iconSize],
        [self.iconView.heightAnchor constraintEqualToConstant:iconSize],
        [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:8],
        [self.nameLabel.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:8],
        [self.nameLabel.trailingAnchor constraintEqualToAnchor:self.selectedBadge.leadingAnchor constant:-6],
        [self.detailLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [self.detailLabel.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:2],
        [self.detailLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-10],
        [self.detailLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentContainer.bottomAnchor constant:-8],
        [self.selectedBadge.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-10],
        [self.selectedBadge.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.selectedBadge.widthAnchor constraintEqualToConstant:18],
        [self.selectedBadge.heightAnchor constraintEqualToConstant:18],
        [checkmark.centerXAnchor constraintEqualToAnchor:self.selectedBadge.centerXAnchor],
        [checkmark.centerYAnchor constraintEqualToAnchor:self.selectedBadge.centerYAnchor]
    ]];
}

- (void)configureWithName:(NSString *)name detail:(NSString *)detail isSelected:(BOOL)isSelected isAddButton:(BOOL)isAddButton {
    if (isAddButton) {
        self.iconView.image = [UIImage systemImageNamed:@"plus.circle.fill"];
        self.iconView.tintColor = [UIColor systemGreenColor];
        self.nameLabel.text = @"新建目录";
        self.detailLabel.text = @"创建新的版本隔离目录";
        self.selectedBadge.hidden = YES;
        self.contentView.layer.borderColor = [UIColor systemGreenColor].CGColor;
        self.contentView.layer.borderWidth = 1.0;
        self.contentView.layer.cornerRadius = 12;
        self.contentView.layer.masksToBounds = YES;
        return;
    }

    self.iconView.image = [UIImage systemImageNamed:@"folder.fill"];
    self.iconView.tintColor = [UIColor systemBlueColor];
    self.nameLabel.text = name;
    self.detailLabel.text = detail ?: @"";
    self.selectedBadge.hidden = !isSelected;
    self.selectedBadge.backgroundColor = accentColor();

    if (isSelected) {
        self.contentView.layer.borderColor = accentColor().CGColor;
        self.contentView.layer.borderWidth = 1.5;
    } else {
        self.contentView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12].CGColor;
        self.contentView.layer.borderWidth = 0.5;
    }
    self.contentView.layer.cornerRadius = 12;
    self.contentView.layer.masksToBounds = YES;
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
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@end

@implementation VMSectionHeaderView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark];
        UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
        blurView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:blurView];

        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.titleLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:16] weight:UIFontWeightBold];
        self.titleLabel.textColor = [UIColor whiteColor];
        [self addSubview:self.titleLabel];

        self.subtitleLabel = [[UILabel alloc] init];
        self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.subtitleLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:11] weight:UIFontWeightRegular];
        self.subtitleLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.55];
        self.subtitleLabel.numberOfLines = 0;
        self.subtitleLabel.lineBreakMode = NSLineBreakByWordWrapping;
        [self addSubview:self.subtitleLabel];

        [NSLayoutConstraint activateConstraints:@[
            [blurView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [blurView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [blurView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [blurView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:18],
            [self.titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
            [self.subtitleLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
            [self.subtitleLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:2],
            [self.subtitleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-18],
            [self.subtitleLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-4]
        ]];
    }
    return self;
}

@end

#pragma mark - View Controller

@interface VersionManagerViewController () <UICollectionViewDataSource, UICollectionViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) NSArray<NSString *> *profileList;
@property (nonatomic, strong) NSString *selectedProfile;
@property (nonatomic, strong) NSMutableArray<NSString *> *gameDirList;
@property (nonatomic, strong) NSString *currentGameDir;
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
    [self setupNavigationBar];
    [self setupLongPressGesture];
    [self loadProfiles];
    [self loadGameDirList];

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
    UIImage *plusImg = [UIImage systemImageNamed:@"plus"];
    [fab setImage:plusImg forState:UIControlStateNormal];
    fab.tintColor = [UIColor whiteColor];
    fab.backgroundColor = [UIColor systemBlueColor];
    fab.layer.cornerRadius = 18;
    fab.layer.masksToBounds = YES;
    fab.translatesAutoresizingMaskIntoConstraints = NO;
    fab.accessibilityLabel = @"新建版本";
    [fab addTarget:self action:@selector(createNewVersion) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:fab];
    [self.view bringSubviewToFront:fab];

    [NSLayoutConstraint activateConstraints:@[
        [fab.widthAnchor constraintEqualToConstant:36],
        [fab.heightAnchor constraintEqualToConstant:36],
        [fab.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [fab.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
    ]];
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
        // 导航栏隐藏时缩小 collectionView 顶部 inset
        self.collectionView.contentInset = UIEdgeInsetsMake(8, 0, 0, 0);
        self.collectionView.scrollIndicatorInsets = UIEdgeInsetsMake(8, 0, 0, 0);
    }
    [PLProfiles updateCurrent];
    [self loadProfiles];
    [self loadGameDirList];
    [self.collectionView reloadData];
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
}

- (void)handleBackgroundUIEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.collectionView reloadData];
    });
}

- (void)handleAccentColorChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.collectionView reloadData];
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
        @"Mithril",
        @"MoltenVK"
    ];
    self.rendererIcons = @[
        @"wand.and.stars",
        @"cpu",
        @"rectangle.stack.fill",
        @"bolt.fill",
        @"circle.hexagongrid.fill",
        @"square.stack.3d.up.fill",
        @"diamond.fill",
        @"flame.fill"
    ];
    self.rendererDescs = @[
        @"自动选择最佳渲染器",
        @"OpenGL ES 1.14 转译（兼容性最佳）",
        @"MetalANGLE，Metal 转 GLES",
        @"Vulkan 转译 OpenGL",
        @"OpenGL 转 Vulkan",
        @"OpenGL Core→ES 转译（Sodium+光影完美兼容）",
        @"OpenGL 3.3 Core→Metal 原生转译（实验性）",
        @"原生 Vulkan"
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
    self.graphicsApiNames = @[@"默认", @"优先 Vulkan", @"优先 OpenGL"];
    self.graphicsApiIcons = @[
        @"wand.and.stars",
        @"flame.fill",
        @"rectangle.stack.fill"
    ];
    self.graphicsApiDescs = @[
        @"由 Mojang 决定（推荐）",
        @"优先 Vulkan，失败回退 OpenGL",
        @"优先 OpenGL，失败回退 Vulkan"
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
    NSDictionary *profile = PLProfiles.current.profiles[self.selectedProfile];
    NSString *r = profile[@"renderer"];
    if (r.length == 0) {
        r = getPrefObject(@"video.renderer");
    }
    return r.length > 0 ? r : @"auto";
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
    // 导航栏隐藏时（根页面模式）顶部留少量间距即可；否则留出导航栏高度
    CGFloat topInset;
    if (self.navigationController && self.navigationController.navigationBarHidden) {
        topInset = 8.0;
    } else {
        topInset = 44.0;
        if (self.navigationController && self.navigationController.navigationBar.bounds.size.height > 0) {
            topInset = self.navigationController.navigationBar.bounds.size.height;
        }
    }
    self.collectionView.contentInset = UIEdgeInsetsMake(topInset, 0, 0, 0);
    self.collectionView.scrollIndicatorInsets = UIEdgeInsetsMake(topInset, 0, 0, 0);

    [self.collectionView registerClass:[VMGameDirCell class] forCellWithReuseIdentifier:@"GameDirCell"];
    [self.collectionView registerClass:[VMVersionCardCell class] forCellWithReuseIdentifier:@"VersionCell"];
    [self.collectionView registerClass:[VMSectionHeaderView class] forSupplementaryViewOfKind:UICollectionElementKindSectionHeader withReuseIdentifier:@"HeaderView"];

    [self.view addSubview:self.collectionView];
}

- (UICollectionViewLayout *)createLayout {
    return [[UICollectionViewCompositionalLayout alloc] initWithSectionProvider:^NSCollectionLayoutSection * _Nullable(NSInteger sectionIndex, id<NSCollectionLayoutEnvironment> _Nonnull layoutEnvironment) {
        CGFloat width = layoutEnvironment.container.contentSize.width;
        BOOL isiPad = width > 700;

        NSCollectionLayoutSize *headerSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                                                                              heightDimension:[NSCollectionLayoutDimension estimatedDimension:48]];
        NSCollectionLayoutBoundarySupplementaryItem *header = [NSCollectionLayoutBoundarySupplementaryItem boundarySupplementaryItemWithLayoutSize:headerSize elementKind:UICollectionElementKindSectionHeader alignment:NSRectAlignmentTop];
        header.contentInsets = NSDirectionalEdgeInsetsMake(0, 0, 0, 0);

        if (sectionIndex == kSectionGameDir) {
            // 游戏目录区段：横向滚动卡片列表
            CGFloat itemWidth = isiPad ? 170 : 150;
            NSCollectionLayoutSize *itemSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension absoluteDimension:itemWidth]
                                                                                       heightDimension:[NSCollectionLayoutDimension absoluteDimension:64]];
            NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:itemSize];
            item.contentInsets = NSDirectionalEdgeInsetsMake(3, 5, 3, 5);

            NSCollectionLayoutSize *groupSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension absoluteDimension:itemWidth]
                                                                                          heightDimension:[NSCollectionLayoutDimension absoluteDimension:64]];
            NSCollectionLayoutGroup *group = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:groupSize subitems:@[item]];

            NSCollectionLayoutSection *section = [NSCollectionLayoutSection sectionWithGroup:group];
            section.orthogonalScrollingBehavior = UICollectionLayoutSectionOrthogonalScrollingBehaviorContinuous;
            section.contentInsets = NSDirectionalEdgeInsetsMake(0, 14, 6, 14);
            section.boundarySupplementaryItems = @[header];
            return section;
        } else {
            // 版本卡片区段：紧凑列表（iPad 双列，iPhone 单列）
            CGFloat itemWidth = isiPad ? 0.5 : 1.0;
            NSCollectionLayoutSize *itemSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:itemWidth]
                                                                                       heightDimension:[NSCollectionLayoutDimension absoluteDimension:78]];
            NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:itemSize];
            item.contentInsets = NSDirectionalEdgeInsetsMake(3, 7, 3, 7);

            NSCollectionLayoutSize *groupSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                                                                                          heightDimension:[NSCollectionLayoutDimension absoluteDimension:78]];
            NSCollectionLayoutGroup *group = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:groupSize subitems:@[item]];

            NSCollectionLayoutSection *section = [NSCollectionLayoutSection sectionWithGroup:group];
            section.contentInsets = NSDirectionalEdgeInsetsMake(0, 14, 18, 14);
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

        [cell configureWithName:dirName detail:@"计算中..." isSelected:isSelected isAddButton:NO];
        return cell;
    } else {
        VMVersionCardCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"VersionCell" forIndexPath:indexPath];

        NSString *profileName = self.profileList[indexPath.item];
        NSDictionary *profile = PLProfiles.current.profiles[profileName];
        NSString *versionId = profile[@"lastVersionId"] ?: @"未知版本";
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
    return [NSString stringWithFormat:@"最后游玩：%@", [fmt stringFromDate:date]];
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath {
    if (kind == UICollectionElementKindSectionHeader) {
        VMSectionHeaderView *header = [collectionView dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:@"HeaderView" forIndexPath:indexPath];
        switch (indexPath.section) {
            case kSectionGameDir:
                header.titleLabel.text = @"游戏目录（版本隔离）";
                header.subtitleLabel.text = @"点击切换 · 长按删除当前目录";
                break;
            case kSectionVersions:
                header.titleLabel.text = @"已安装的版本";
                header.subtitleLabel.text = @"点击进入版本设置 · 长按弹出操作菜单";
                break;
            default:
                header.titleLabel.text = @"";
                header.subtitleLabel.text = @"";
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
        [self showAlert:[NSString stringWithFormat:@"切换游戏目录失败：\n\n%@", linkError.localizedDescription]];
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
}

/// 弹出新建游戏目录对话框
- (void)showCreateGameDirAlert {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"新建游戏目录"
                                                                   message:@"输入新目录名（用于版本隔离）"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"目录名";
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.delegate = self;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"创建" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
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
        [self showAlert:[NSString stringWithFormat:@"创建目录失败：\n\n%@", error.localizedDescription]];
        return;
    }
    [self switchGameDirTo:name];
}

/// 长按游戏目录卡片弹出操作菜单：切换/删除当前目录
- (void)showGameDirActions:(NSString *)dirName {
    BOOL isSelected = [dirName isEqualToString:self.currentGameDir];
    BOOL isDefault = [dirName isEqualToString:@"default"];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:dirName
                                                                   message:isSelected ? @"当前正在使用此目录" : @"切换到此目录"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    if (!isSelected) {
        [alert addAction:[UIAlertAction actionWithTitle:@"切换到此目录" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self switchGameDirTo:dirName];
        }]];
    }

    // 删除目录（默认目录禁止删除，正在使用的目录需要先切换才能删除）
    if (!isDefault) {
        NSString *deleteTitle = isSelected ? @"删除（需先切换到其他目录）" : @"删除此目录";
        [alert addAction:[UIAlertAction actionWithTitle:deleteTitle style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            if (isSelected) {
                [self showAlert:@"请先切换到其他目录，再删除此目录"];
                return;
            }
            [self confirmDeleteGameDir:dirName];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
        alert.popoverPresentationController.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }
    [self presentViewController:alert animated:YES completion:nil];
}

/// 二次确认删除游戏目录
- (void)confirmDeleteGameDir:(NSString *)dirName {
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"确认删除目录"
                                                                     message:[NSString stringWithFormat:@"将删除目录 \"%@\" 及其所有内容（包括存档、Mod、配置等），此操作不可恢复。", dirName]
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"确认删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self deleteGameDir:dirName];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

/// 删除指定游戏目录
- (void)deleteGameDir:(NSString *)dirName {
    if ([dirName isEqualToString:@"default"]) {
        [self showAlert:@"默认目录不可删除"];
        return;
    }
    if ([dirName isEqualToString:self.currentGameDir]) {
        [self showAlert:@"请先切换到其他目录，再删除此目录"];
        return;
    }

    NSString *dest = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), dirName];
    NSError *error = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:dest error:&error]) {
        [self showAlert:[NSString stringWithFormat:@"删除目录失败：\n\n%@", error.localizedDescription]];
        return;
    }

    [self loadGameDirList];
    [self.collectionView reloadData];
    [self showAlert:[NSString stringWithFormat:@"已删除目录 \"%@\"", dirName]];
}

#pragma mark - Renderer Selection (启动器 native 库选择)

/// 选择渲染器并保存到当前 profile
- (void)selectRendererAtIndex:(NSInteger)index {
    if (!self.selectedProfile) {
        [self showAlert:@"请先选择一个版本"];
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

    // 同步到全局偏好（保证启动游戏时 LauncherRightPanelViewController 能读到）
    setPrefString(@"video.renderer", key);

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
        [self showAlert:@"请先选择一个版本"];
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

    // 同步到全局偏好
    setPrefString(@"video.graphics_api", key);

    [self.collectionView reloadData];

    NSLog(@"[VersionMgr] Graphics API for profile '%@' set to '%@' (%@)", self.selectedProfile, key, displayName);
}

#pragma mark - Quick Actions

- (void)openModsManager {
    if (!self.selectedProfile) {
        [self showAlert:@"请先选择一个版本"];
        return;
    }
    ModsManagerViewController *vc = [[ModsManagerViewController alloc] init];
    vc.profileName = self.selectedProfile;
    vc.initialMode = ModsManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openShadersManager {
    if (!self.selectedProfile) {
        [self showAlert:@"请先选择一个版本"];
        return;
    }
    ShadersManagerViewController *vc = [[ShadersManagerViewController alloc] init];
    vc.profileName = self.selectedProfile;
    vc.initialMode = ShadersManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openResourcePacksManager {
    if (!self.selectedProfile) {
        [self showAlert:@"请先选择一个版本"];
        return;
    }
    ResourcePacksManagerViewController *vc = [[ResourcePacksManagerViewController alloc] init];
    vc.profileName = self.selectedProfile;
    vc.initialMode = ResourcePacksManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openDataPacksManager {
    if (!self.selectedProfile) {
        [self showAlert:@"请先选择一个版本"];
        return;
    }
    DataPacksManagerViewController *vc = [[DataPacksManagerViewController alloc] init];
    vc.profileName = self.selectedProfile;
    vc.initialMode = DataPacksManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openWorldsManager {
    if (!self.selectedProfile) {
        [self showAlert:@"请先选择一个版本"];
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
        [alert addAction:[UIAlertAction actionWithTitle:@"选择此版本" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            PLProfiles.current.selectedProfileName = profileName;
            [PLProfiles.current save];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:nil];
            [self loadProfiles];
            [self.collectionView reloadData];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"编辑配置" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self editProfile:profileName];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self deleteProfile:profileName];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
        alert.popoverPresentationController.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)editProfile:(NSString *)profileName {
    // 使用 ProfileSettingsViewController（合并后的统一 Edit Profile 页面，新 UI）
    ProfileSettingsViewController *vc = [[ProfileSettingsViewController alloc] init];
    vc.profileName = profileName;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)deleteProfile:(NSString *)profileName {
    if (self.profileList.count <= 1) {
        [self showAlert:@"至少需要保留一个版本配置"];
        return;
    }

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"确认删除"
                                                                     message:[NSString stringWithFormat:@"确定要删除 \"%@\" 吗？", profileName]
                                                              preferredStyle:UIAlertControllerStyleAlert];

    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [PLProfiles.current.profiles removeObjectForKey:profileName];
        if ([PLProfiles.current.selectedProfileName isEqualToString:profileName]) {
            PLProfiles.current.selectedProfileName = PLProfiles.current.profiles.allKeys.firstObject;
        }
        [PLProfiles.current save];
        [self loadProfiles];
        [self.collectionView reloadData];
    }]];

    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)showAlert:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
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
