#import "DownloadViewController.h"
#import "BackgroundManager.h"
// IconLoader：统一的项目图标加载器（双层缓存 + 降采样 + 并发控制 + CDN 镜像），
// 替代 UIImageView+AFNetworking（仅内存缓存，无降采样，无镜像）
// 参照 FCL Glide + ZL2 Coil 的最佳实践
#import "IconLoader.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "PLTaskStages.h"
#import "InlineMessageView.h"
#import "installer/modpack/ModrinthAPI.h"
#import "installer/modpack/CurseForgeAPI.h"
#import "PLPreferences.h"
#import "ModService.h"
#import "ShaderService.h"
#import "ResourcePackService.h"
#import "DataPackService.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "VersionCardCell.h"
#import "MinecraftResourceDownloadTask.h"
#import "ModItem.h"
#import "ModVersionViewController.h"
#import "ModVersion.h"
#import "ShaderItem.h"
#import "ShaderVersionViewController.h"
#import "ShaderVersion.h"
#import "ResourcePackItem.h"
#import "DataPackItem.h"
#import "WorldItem.h"
#import "AssetVersionViewController.h"
#import "WorldService.h"
#import "installer/FabricInstallViewController.h"
#import "installer/ForgeInstallViewController.h"
#import "installer/ForgeDirectInstaller.h"
#import "installer/NeoForgeDirectInstaller.h"
#import "installer/ForgeProcessorExecutor.h"
#import "PLCrashView.h"
#import "installer/NeoForgeVersionFetcher.h"
#import "installer/ModLoaderInstallViewController.h"
#import "LauncherNavigationController.h"
#import "installer/ModpackInstallViewController.h"
#import "ModpackImportViewController.h"
#import "ModpackImportService.h"
#import "ModpackExportService.h"
#import "installer/CurseForgeAPIKeyViewController.h"
#import "UZKArchive.h"
#import <QuartzCore/QuartzCore.h>
#import "JavaGUIViewController.h"
#import "utils.h"
#import "ios_uikit_bridge.h"
#import "ALTServerConnection.h"
#import "ModLoaderIconHelper.h"

#include <sys/time.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <netinet/in.h>

#pragma mark - Modern Asset Cell

// 资源类型枚举：决定占位图标与配色，区分 6 类资源（mod/shader/resourcepack/datapack/world/modpack）
// 参照 FCL CategoryBox 与 ZL2 AddonListLayout 的图标体系，使用 SF Symbols 替代项目自有 PNG
typedef NS_ENUM(NSInteger, ModernAssetType) {
    ModernAssetTypeMod = 0,           // 模组：puzzlepiece.fill + 橙
    ModernAssetTypeShader,            // 光影：paintbrush.fill + 紫
    ModernAssetTypeResourcepack,      // 资源包：photo.stack.fill + 蓝
    ModernAssetTypeDatapack,          // 数据包：doc.text.fill + 青
    ModernAssetTypeWorld,             // 世界：globe.asia.australia.fill + 绿
    ModernAssetTypeModpack            // 整合包：shippingbox.fill + 粉
};

@interface ModernAssetCell : UITableViewCell
@property (nonatomic, strong) UIView *contentContainer;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UILabel *metaLabel;
@property (nonatomic, strong) UIStackView *tagsStack;
@property (nonatomic, strong) UIButton *downloadButton;
// 当前资源类型（用于在 prepareForReuse 时重置占位图标与配色）
@property (nonatomic, assign) ModernAssetType assetType;
// 缓存当前正在加载图片的 URL，避免复用时旧请求覆盖新请求（cell 复用竞态）
@property (nonatomic, copy, nullable) NSString *currentIconURL;
@end

@implementation ModernAssetCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleDefault;
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];
        self.assetType = ModernAssetTypeMod;

        // FCL view_installer_item.xml 风格：扁平条目，无卡片容器、无阴影、无边框
        // 仅依赖 BackgroundManager.applyEffectToView: 提供毛玻璃/半透明背景
        // 行间分隔通过 rowHeight 内的上下 padding 实现（参照 FCL marginBottom 10dp）
        self.contentContainer = [[UIView alloc] init];
        self.contentContainer.translatesAutoresizingMaskIntoConstraints = NO;
        // FCL bg_container_white_clickable 的等效：浅色半透明背景 + 圆角
        self.contentContainer.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.06];
        self.contentContainer.layer.cornerRadius = 8;
        self.contentContainer.layer.cornerCurve = kCACornerCurveContinuous;
        // 移除阴影/边框（FCL 扁平风格不需要）
        [self.contentView addSubview:self.contentContainer];

        // ----- 左侧图标：26x26（FCL 标准 30dp，紧凑模式略小）-----
        self.iconView = [[UIImageView alloc] init];
        self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
        self.iconView.layer.cornerRadius = 5;
        self.iconView.layer.cornerCurve = kCACornerCurveContinuous;
        self.iconView.clipsToBounds = YES;
        self.iconView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.06];
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
        self.iconView.tintColor = [UIColor systemOrangeColor];
        [self.contentContainer addSubview:self.iconView];

        // ----- 标题：13pt Medium（FCL title 14sp，紧凑模式略小）-----
        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        self.titleLabel.textColor = [UIColor labelColor];
        self.titleLabel.numberOfLines = 1;
        self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.titleLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [self.contentContainer addSubview:self.titleLabel];

        // ----- 第二行：下载次数 + 描述（FCL download_count 12sp + description 12sp）-----
        self.descLabel = [[UILabel alloc] init];
        self.descLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.descLabel.font = [UIFont systemFontOfSize:11];
        self.descLabel.textColor = [UIColor secondaryLabelColor];
        self.descLabel.numberOfLines = 1;
        self.descLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.contentContainer addSubview:self.descLabel];

        // ----- 元信息隐藏（已合并到 descLabel 第二行）-----
        self.metaLabel = [[UILabel alloc] init];
        self.metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.metaLabel.hidden = YES;
        [self.contentContainer addSubview:self.metaLabel];

        // ----- 标签 stack：融入第二行右侧（FCL tag 11sp padding 4dp/2dp）-----
        self.tagsStack = [[UIStackView alloc] init];
        self.tagsStack.translatesAutoresizingMaskIntoConstraints = NO;
        self.tagsStack.axis = UILayoutConstraintAxisHorizontal;
        self.tagsStack.spacing = 4;
        self.tagsStack.distribution = UIStackViewDistributionFill;
        self.tagsStack.alignment = UIStackViewAlignmentCenter;
        [self.contentContainer addSubview:self.tagsStack];

        // ----- 下载按钮：右侧 24x24（FCL 风格紧凑按钮）-----
        self.downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
        UIImage *downloadSymbol = [UIImage systemImageNamed:@"arrow.down.circle.fill"
                                          withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIFontWeightRegular]];
        if (!downloadSymbol) {
            downloadSymbol = [UIImage systemImageNamed:@"arrow.down.circle.fill"];
        }
        [self.downloadButton setImage:downloadSymbol forState:UIControlStateNormal];
        self.downloadButton.tintColor = [UIColor systemGreenColor];
        self.downloadButton.showsTouchWhenHighlighted = NO;
        [self.downloadButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self.downloadButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self.contentContainer addSubview:self.downloadButton];

        [NSLayoutConstraint activateConstraints:@[
            // FCL marginBottom 10dp / padding 8dp,10dp 等效：上下 3pt + 左右 8pt（紧凑）
            [self.contentContainer.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:3],
            [self.contentContainer.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:8],
            [self.contentContainer.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8],
            [self.contentContainer.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-3],

            // 图标：左 8，垂直居中，26x26
            [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:8],
            [self.iconView.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
            [self.iconView.widthAnchor constraintEqualToConstant:26],
            [self.iconView.heightAnchor constraintEqualToConstant:26],

            // 标题：紧跟图标右侧 +8，顶部对齐容器顶部 +6
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:8],
            [self.titleLabel.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:6],
            [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.downloadButton.leadingAnchor constant:-4],

            // 第二行 descLabel：紧跟标题下方 +2，左侧对齐标题
            [self.descLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
            [self.descLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:2],
            [self.descLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.tagsStack.leadingAnchor constant:-4],
            [self.descLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentContainer.bottomAnchor constant:-6],

            // 标签 stack：与 descLabel 同行，右侧紧贴下载按钮
            [self.tagsStack.centerYAnchor constraintEqualToAnchor:self.descLabel.centerYAnchor],
            [self.tagsStack.trailingAnchor constraintLessThanOrEqualToAnchor:self.downloadButton.leadingAnchor constant:-4],

            // 下载按钮：右侧 -6，垂直居中，24x24
            [self.downloadButton.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-6],
            [self.downloadButton.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
            [self.downloadButton.widthAnchor constraintEqualToConstant:24],
            [self.downloadButton.heightAnchor constraintEqualToConstant:24]
        ]];

        // 应用毛玻璃背景效果（BackgroundManager 统一管理深浅色与模糊度）
        [[BackgroundManager sharedManager] applyEffectToView:self.contentContainer];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    // 取消该 cell 上正在进行的图标加载请求（cell 复用时旧请求不应继续占用网络与回调）
    // 对应 Glide 的 clear() + ZL2 Compose 组合自动取消
    [IconLoader cancelLoadingForImageView:self.iconView];
    // 重置图标状态：避免复用时旧图残留导致显示错乱
    self.iconView.image = nil;
    self.iconView.tintColor = [UIColor systemOrangeColor];
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.06];
    self.currentIconURL = nil;
    // 移除所有标签
    [self.tagsStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    // 重置下载按钮 target（防止复用后旧 target 残留触发错误下载）
    [self.downloadButton removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
}

#pragma mark - 占位图标与配色（按资源类型）

/// 根据资源类型返回默认占位 SF Symbol 名称
- (NSString *)placeholderIconNameForType:(ModernAssetType)type {
    switch (type) {
        case ModernAssetTypeMod:          return @"puzzlepiece.fill";
        case ModernAssetTypeShader:       return @"paintbrush.fill";
        case ModernAssetTypeResourcepack: return @"photo.stack.fill";
        case ModernAssetTypeDatapack:     return @"doc.text.fill";
        case ModernAssetTypeWorld:        return @"globe.asia.australia.fill";
        case ModernAssetTypeModpack:      return @"shippingbox.fill";
    }
    return @"puzzlepiece.fill";
}

/// 根据资源类型返回占位图标主色（用作 iconView.tintColor，与 FCL/ZL2 各资源类型的视觉色一致）
- (UIColor *)placeholderColorForType:(ModernAssetType)type {
    switch (type) {
        case ModernAssetTypeMod:          return [UIColor systemOrangeColor];
        case ModernAssetTypeShader:       return [UIColor systemPurpleColor];
        case ModernAssetTypeResourcepack: return [UIColor systemBlueColor];
        case ModernAssetTypeDatapack:     return [UIColor systemTealColor];
        case ModernAssetTypeWorld:        return [UIColor systemGreenColor];
        case ModernAssetTypeModpack:      return [UIColor systemPinkColor];
    }
    return [UIColor systemOrangeColor];
}

/// 应用占位图标：先显示类型对应的 SF Symbol，等异步加载完成后替换为项目图标
- (void)applyPlaceholderIconForType:(ModernAssetType)type {
    NSString *iconName = [self placeholderIconNameForType:type];
    UIColor *iconColor = [self placeholderColorForType:type];
    UIImage *symbol = [UIImage systemImageNamed:iconName];
    if (symbol) {
        self.iconView.image = symbol;
    } else {
        self.iconView.image = [UIImage systemImageNamed:@"puzzlepiece.fill"];
    }
    self.iconView.tintColor = iconColor;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
}

#pragma mark - 通用配置辅助

/// 格式化下载量数字：1234 → "1.2K"，1234567 → "1.2M"
- (NSString *)formatDownloadCount:(NSNumber *)downloads {
    if (!downloads) return @"0";
    NSInteger dl = [downloads integerValue];
    if (dl >= 1000000) {
        return [NSString stringWithFormat:@"%.1fM", dl / 1000000.0];
    } else if (dl >= 1000) {
        return [NSString stringWithFormat:@"%.1fK", dl / 1000.0];
    } else {
        return [NSString stringWithFormat:@"%ld", (long)dl];
    }
}

/// 格式化日期字符串："2024-01-15T12:34:56Z" → "2024-01-15"，失败返回空串
- (NSString *)formatDateString:(NSString *)dateString {
    if (![dateString isKindOfClass:[NSString class]] || dateString.length < 10) return @"";
    return [dateString substringToIndex:10];
}

/// 异步加载项目图标（使用 IconLoader 统一加载器）
/// 对应 ZL2 AssetsIcon 的 loadIcon 逻辑：双层缓存 + 降采样 + CDN 镜像 + 占位/兜底
- (void)loadIconFromURL:(NSString *)iconUrl placeholderType:(ModernAssetType)type {
    // 先显示占位图标（加载期间显示类型对应的 SF Symbol）
    [self applyPlaceholderIconForType:type];

    if (![iconUrl isKindOfClass:[NSString class]] || iconUrl.length == 0) {
        return;
    }

    // 记录当前正在加载的 URL，防止 cell 复用后旧请求覆盖新请求
    self.currentIconURL = [iconUrl copy];

    // 构造兜底图：与占位图标相同，加载失败时也显示类型对应的 SF Symbol
    UIImage *placeholder = self.iconView.image;
    UIImage *fallback = [UIImage systemImageNamed:[self placeholderIconNameForType:type]] ?: placeholder;

    // 使用 IconLoader 加载（自动处理：取消旧请求 → 占位 → 内存缓存 → 磁盘缓存 → 降采样解码 → CDN 镜像 → 兜底）
    // 图标显示尺寸 26x26（FCL 标准 30dp，紧凑模式略小），降采样到此尺寸避免按原图解码
    __weak typeof(self) weakSelf = self;
    [IconLoader loadIconForImageView:self.iconView
                                 URL:iconUrl
                         placeholder:placeholder
                            fallback:fallback
                           targetSize:CGSizeMake(26, 26)
                              options:IconLoaderOptionsDefault
                           completion:^(UIImage *image) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !image) return;
        // 校验：cell 复用后 currentIconURL 可能已变，避免旧图覆盖新 cell
        // （IconLoader 内部已通过关联对象做了校验，这里二次校验更稳妥）
        if (![strongSelf.currentIconURL isEqualToString:iconUrl]) return;
        // 真实项目图标使用 AspectFill 填充，覆盖占位 SF Symbol 的 AspectFit 样式
        strongSelf.iconView.contentMode = UIViewContentModeScaleAspectFill;
        strongSelf.iconView.tintColor = [UIColor clearColor];
    }];
}

/// 配置标签 stack：从 categories 数组取最多 3 个，按 loader/类别配色
/// 参照 ZL2 LittleTextLabel：mod loader 用品牌色，普通类别用中性色
- (void)configureTagsWithCategories:(NSArray *)categories {
    [self.tagsStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    if (![categories isKindOfClass:[NSArray class]]) return;

    for (NSInteger i = 0; i < MIN(3, categories.count); i++) {
        id catObj = categories[i];
        NSString *cat = nil;
        if ([catObj isKindOfClass:[NSString class]]) {
            cat = catObj;
        } else if ([catObj isKindOfClass:[NSDictionary class]]) {
            // CurseForge 的 categories 是 dict，取 name 字段
            cat = catObj[@"name"];
        }
        if (![cat isKindOfClass:[NSString class]] || cat.length == 0) continue;

        UILabel *tag = [self createTagLabel:cat];
        [self.tagsStack addArrangedSubview:tag];
    }
}

/// 根据类别名返回配色：加载器品牌色统一委托 ModLoaderIconHelper，类别色保持本地映射
- (UIColor *)colorForCategory:(NSString *)category {
    NSString *lower = category.lowercaseString;
    // 加载器品牌色：统一委托 ModLoaderIconHelper（优先 PNG 图标的官方配色）
    if ([ModLoaderIconHelper isKnownLoader:category]) {
        return [ModLoaderIconHelper brandColorForLoader:category];
    }
    // 常见模组类别配色
    if ([lower containsString:@"magic"])     return [UIColor systemPurpleColor];
    if ([lower containsString:@"tech"])      return [UIColor systemOrangeColor];
    if ([lower containsString:@"adventure"]) return [UIColor systemTealColor];
    if ([lower containsString:@"decoration"]) return [UIColor systemPinkColor];
    if ([lower containsString:@"utility"])   return [UIColor systemBlueColor];
    if ([lower containsString:@"world"])     return [UIColor systemGreenColor];
    // 兜底
    return [UIColor tertiaryLabelColor];
}

- (UILabel *)createTagLabel:(NSString *)text {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    // FCL tag 11sp Medium（紧凑模式 10pt）
    label.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    label.textColor = [UIColor whiteColor];
    label.backgroundColor = [self colorForCategory:text];
    label.layer.cornerRadius = 4;
    label.layer.cornerCurve = kCACornerCurveContinuous;
    label.layer.masksToBounds = YES;
    label.textAlignment = NSTextAlignmentCenter;
    [label setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [label setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    // 内边距：左右 5，上下 1（FCL padding 4dp/2dp 等效，紧凑模式略小）
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [label.heightAnchor constraintEqualToConstant:14]
    ]];
    [label sizeToFit];
    CGFloat textWidth = label.frame.size.width;
    [label.widthAnchor constraintEqualToConstant:textWidth + 8].active = YES;
    return label;
}

#pragma mark - 各资源类型配置入口

- (void)configureWithMod:(NSDictionary *)mod {
    self.assetType = ModernAssetTypeMod;
    [self configureCommonWithData:mod type:ModernAssetTypeMod];
}

- (void)configureWithShader:(NSDictionary *)shader {
    self.assetType = ModernAssetTypeShader;
    [self configureCommonWithData:shader type:ModernAssetTypeShader];
}

- (void)configureWithResourcepack:(NSDictionary *)resourcepack {
    self.assetType = ModernAssetTypeResourcepack;
    [self configureCommonWithData:resourcepack type:ModernAssetTypeResourcepack];
}

- (void)configureWithDatapack:(NSDictionary *)datapack {
    self.assetType = ModernAssetTypeDatapack;
    [self configureCommonWithData:datapack type:ModernAssetTypeDatapack];
}

- (void)configureWithWorld:(NSDictionary *)world {
    self.assetType = ModernAssetTypeWorld;
    [self configureCommonWithData:world type:ModernAssetTypeWorld];
}

- (void)configureWithModpack:(NSDictionary *)modpack {
    self.assetType = ModernAssetTypeModpack;
    [self configureCommonWithData:modpack type:ModernAssetTypeModpack];
}

/// 6 类资源共用的配置逻辑：标题/描述/元信息/图标/标签
/// FCL 风格：标题 14sp + 第二行（下载次数 + 描述），元信息（作者/日期）合并到 descLabel
- (void)configureCommonWithData:(NSDictionary *)data type:(ModernAssetType)type {
    self.titleLabel.text = data[@"title"] ?: data[@"slug"] ?: @"Unknown";

    // 第二行：下载次数 + 描述（FCL download_count + description 同行）
    NSString *downloadsStr = [self formatDownloadCount:data[@"downloads"]];
    NSString *description = data[@"description"] ?: @"";
    // 截断描述，避免太长挤压下载次数显示
    NSString *truncatedDesc = description;
    if (truncatedDesc.length > 40) {
        truncatedDesc = [[description substringToIndex:40] stringByAppendingString:@"…"];
    }
    self.descLabel.text = [NSString stringWithFormat:localize(@"i18n_str_146", nil), downloadsStr, truncatedDesc];

    // metaLabel 已隐藏（保留属性兼容旧代码），不再设置
    self.metaLabel.text = @"";

    // 图标：先占位，再异步加载项目图标
    NSString *iconUrl = data[@"imageUrl"] ?: data[@"icon_url"];
    [self loadIconFromURL:iconUrl placeholderType:type];

    // 标签
    [self configureTagsWithCategories:data[@"categories"]];
}

@end

// LoaderCell 与 LoaderSelectionViewController 已迁移至 installer/ModLoaderInstallViewController.m
// 参照 FCL (FoldCraftLauncher) 的 InstallerListPage + VersionInstallInfoPage 重构

// redesign-download-ui Phase 3 Task 3.2：私有 InstallerProgressViewController（约 400 行）已删除，
// 安装类/整合包/资源下载进度统一由 DownloadTaskManager 阶段上报驱动
// PLTaskProgressViewController（统一进度页）自动弹出展示。


#pragma mark - DownloadViewController

@interface DownloadViewController () <UICollectionViewDataSource, UICollectionViewDelegate, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate, ModVersionViewControllerDelegate, ShaderVersionViewControllerDelegate, AssetVersionViewControllerDelegate>

@property (nonatomic, strong) UISegmentedControl *tabSegment;
@property (nonatomic, strong) UISegmentedControl *versionFilterSegment;
// versionFilterSegment 高度约束：版本 tab 显示（约 32pt），其他 tab 设为 0，
// 避免 hidden=YES 时仍占空间导致 tabSegment 与 searchBar 之间出现"大白条"。
@property (nonatomic, strong) NSLayoutConstraint *versionFilterHeightConstraint;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UIButton *filterButton;
@property (nonatomic, strong) UIButton *importModpackButton;  // 整合包 tab 专用导入按钮（参照 FCL）
@property (nonatomic, strong) NSLayoutConstraint *importModpackButtonWidthConstraint;
@property (nonatomic, strong) UICollectionView *versionCollectionView;
@property (nonatomic, strong) UITableView *modTableView;
@property (nonatomic, strong) UITableView *shaderTableView;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, strong) UILabel *emptyLabel;

@property (nonatomic, strong) NSArray *versionList;
@property (nonatomic, strong) NSArray *filteredVersions;
@property (nonatomic, strong) NSMutableArray *modList;
@property (nonatomic, strong) NSMutableArray *shaderList;

// 版本 tab 搜索关键词（按版本号前缀过滤，例如输入 "1.2" 匹配 1.20.x / 1.2.x）
@property (nonatomic, strong) NSString *versionSearchQuery;

@property (nonatomic, assign) NSInteger currentModOffset;
@property (nonatomic, assign) NSInteger currentShaderOffset;
@property (nonatomic, assign) BOOL isLoadingMods;
@property (nonatomic, assign) BOOL isLoadingShaders;
@property (nonatomic, assign) NSInteger modRequestGeneration;
@property (nonatomic, assign) NSInteger shaderRequestGeneration;
@property (nonatomic, assign) BOOL hasMoreMods;
@property (nonatomic, assign) BOOL hasMoreShaders;
@property (nonatomic, strong) NSString *modSearchQuery;
@property (nonatomic, strong) NSString *shaderSearchQuery;
@property (nonatomic, strong) NSString *currentGameVersion;
@property (nonatomic, strong) NSString *currentModLoader;
@property (nonatomic, strong) NSString *currentSortField;
// FCL 风格：标记用户是否手动改过筛选条件（改过后不再自动覆盖为 profile 的版本）
@property (nonatomic, assign) BOOL hasUserTouchedFilters;

@property (nonatomic, strong) MinecraftResourceDownloadTask *downloadTask;
@property (nonatomic, strong) InlineMessageView *downloadingAlert;

@property (nonatomic, assign) BOOL isObservingProgress;

// 整合包相关属性
@property (nonatomic, strong) UITableView *modpackTableView;
@property (nonatomic, strong) NSMutableArray *modpackList;
@property (nonatomic, assign) NSInteger currentModpackOffset;
@property (nonatomic, assign) BOOL hasMoreModpacks;
@property (nonatomic, assign) BOOL isLoadingModpacks;
@property (nonatomic, strong) NSString *modpackSearchQuery;

// 资源包相关属性
@property (nonatomic, strong) UITableView *resourcepackTableView;
@property (nonatomic, strong) NSMutableArray *resourcepackList;
@property (nonatomic, assign) NSInteger currentResourcepackOffset;
@property (nonatomic, assign) BOOL hasMoreResourcepacks;
@property (nonatomic, assign) BOOL isLoadingResourcepacks;
@property (nonatomic, strong) NSString *resourcepackSearchQuery;

// 数据包相关属性
@property (nonatomic, strong) UITableView *datapackTableView;
@property (nonatomic, strong) NSMutableArray *datapackList;
@property (nonatomic, assign) NSInteger currentDatapackOffset;
@property (nonatomic, assign) BOOL hasMoreDatapacks;
@property (nonatomic, assign) BOOL isLoadingDatapacks;
@property (nonatomic, strong) NSString *datapackSearchQuery;

// 世界相关属性（仿 FCL 安卓新增世界下载分类）
@property (nonatomic, strong) UITableView *worldTableView;
@property (nonatomic, strong) NSMutableArray *worldList;
@property (nonatomic, assign) NSInteger currentWorldOffset;
@property (nonatomic, assign) BOOL hasMoreWorlds;
@property (nonatomic, assign) BOOL isLoadingWorlds;
@property (nonatomic, strong) NSString *worldSearchQuery;

// 源切换 UI（仿 FCL 安卓风格的圆角胶囊切换器：Modrinth 绿 / CurseForge 橙）
@property (nonatomic, strong) UIView *sourceSwitchContainer;
@property (nonatomic, strong) UIView *sourceSwitchTrack;        // 圆角胶囊背景轨道
@property (nonatomic, strong) UIView *sourceSwitchSlider;       // 选中项的彩色滑块
@property (nonatomic, strong) UIButton *modrinthSourceButton;
@property (nonatomic, strong) UIButton *curseforgeSourceButton;
@property (nonatomic, strong) NSLayoutConstraint *sourceSwitchHeightConstraint;
@property (nonatomic, strong) NSLayoutConstraint *sliderLeftPosConstraint;   // 滑块贴左（Modrinth）
@property (nonatomic, strong) NSLayoutConstraint *sliderRightPosConstraint;  // 滑块贴右（CurseForge）

// ===== FCL/ZL2 风格侧边筛选栏 =====
// 参照 FCL（FoldCraftLauncher）和 ZL2（ZalithLauncher）的模组/光影下载界面布局：
// 左侧是筛选面板（下载源、游戏版本、模组加载器、排序方式），右侧是搜索框+列表。
// 侧边栏在模组/光影/资源包/数据包/整合包 tab 显示，版本 tab 和世界 tab 隐藏。
// 窄屏（iPhone 竖屏）时侧边栏宽度自动缩小为 140pt，宽屏（iPad）时为 180pt。
@property (nonatomic, strong) UIView *filterSidebarContainer;      // 侧边栏容器
@property (nonatomic, strong) NSLayoutConstraint *sidebarWidthConstraint;  // 侧边栏宽度约束（隐藏时为 0）
@property (nonatomic, strong) NSLayoutConstraint *sidebarLeadingConstraint; // 侧边栏 leading（隐藏时贴左，列表不偏移）

// 侧边栏内的下载源选择（从顶部移到侧边栏）
@property (nonatomic, strong) UIView *sidebarSourceContainer;
@property (nonatomic, strong) UIButton *sidebarModrinthButton;
@property (nonatomic, strong) UIButton *sidebarCurseforgeButton;
@property (nonatomic, strong) NSLayoutConstraint *sidebarSliderLeftConstraint;
@property (nonatomic, strong) NSLayoutConstraint *sidebarSliderRightConstraint;
@property (nonatomic, strong) UIView *sidebarSourceTrack;
@property (nonatomic, strong) UIView *sidebarSourceSlider;

// 侧边栏内的游戏版本选择按钮（点击弹出 ActionSheet 选择版本）
@property (nonatomic, strong) UIButton *sidebarVersionButton;
@property (nonatomic, strong) UILabel *sidebarVersionTitleLabel;
@property (nonatomic, strong) UILabel *sidebarVersionValueLabel;

// 侧边栏内的模组加载器选择按钮（点击弹出 ActionSheet 选择加载器）
@property (nonatomic, strong) UIButton *sidebarLoaderButton;
@property (nonatomic, strong) UILabel *sidebarLoaderTitleLabel;
@property (nonatomic, strong) UILabel *sidebarLoaderValueLabel;

// 侧边栏内的排序方式选择按钮
@property (nonatomic, strong) UIButton *sidebarSortButton;
@property (nonatomic, strong) UILabel *sidebarSortTitleLabel;
@property (nonatomic, strong) UILabel *sidebarSortValueLabel;

// 侧边栏重置筛选按钮
@property (nonatomic, strong) UIButton *sidebarResetButton;

// 当前待下载资源类型（mod/resourcepack/datapack/world/modpack），用于版本选择回调中决定下载目录
@property (nonatomic, copy) NSString *pendingDownloadType;
// 在线选择版本时临时持有的资源包/数据包/世界对象（AssetVersionViewController 回调使用）
@property (nonatomic, strong, nullable) ResourcePackItem *pendingResourcePackItem;
@property (nonatomic, strong, nullable) DataPackItem *pendingDataPackItem;
@property (nonatomic, strong, nullable) WorldItem *pendingWorldItem;
// 整合包版本选择回调时临时持有的整合包字典（ModVersionViewController 回调使用，与 Mod 共用 VC 但下载流程不同）
@property (nonatomic, strong, nullable) NSDictionary *pendingModpackDict;

// 原版前置安装（FCL 风格：安装模组加载器前先装好对应原版）。
// redesign-download-ui Phase 3：进度展示由 MinecraftResourceDownloadTask 内部阶段上报
// 驱动统一进度页，无需持有任何进度 VC。
@property (nonatomic, strong) MinecraftResourceDownloadTask *vanillaPreinstallTask;
@property (nonatomic, assign) BOOL isObservingVanillaPreinstall;
@property (nonatomic, copy, nullable) void (^vanillaPreinstallCompletion)(BOOL success);

@end

@implementation DownloadViewController

- (void)dealloc {
    if (self.isObservingProgress) {
        @try {
            [self.downloadTask.progress removeObserver:self forKeyPath:@"fractionCompleted"];
        } @catch (NSException *exception) {
            // KVO 观察者可能注册在旧的 downloadTask.progress 上，而 downloadTask 已被
            // 重新赋值为新对象（startVersionDownload: 每次创建新 task），导致从新 progress
            // 移除时抛出 "not registered as an observer" 异常。忽略此异常即可。
            NSLog(@"[DownloadVC] dealloc: removeObserver fractionCompleted failed: %@", exception.reason);
        }
        self.isObservingProgress = NO;
    }
    if (self.downloadTask) {
        [self.downloadTask.progress cancel];
        self.downloadTask = nil;
    }
    // 清理原版前置安装的 KVO 观察者，避免 VC 释放后 KVO 回调向已释放对象发送消息导致崩溃
    if (self.isObservingVanillaPreinstall) {
        @try {
            [self.vanillaPreinstallTask.progress removeObserver:self forKeyPath:@"fractionCompleted"];
        } @catch (NSException *exception) {
            NSLog(@"[DownloadVC] dealloc: removeObserver vanillaPreinstall fractionCompleted failed: %@", exception.reason);
        }
        self.isObservingVanillaPreinstall = NO;
    }
    if (self.vanillaPreinstallTask) {
        [self.vanillaPreinstallTask.progress cancel];
        self.vanillaPreinstallTask = nil;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"BackgroundUIEffectChanged" object:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // 不设置 self.title，避免顶部导航栏出现"下载"标题黑条（参照 FCL 无 title 风格）
    self.view.backgroundColor = [UIColor clearColor];

    // 彻底隐藏导航栏黑条（仅当作为非 modal 根页面且是栈中唯一 VC 时）
    // 快捷入口（showModpackImport 等）会预 push 子页面，此时 count > 1，不隐藏导航栏
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil &&
        self.navigationController.viewControllers.count == 1) {
        self.navigationController.navigationBarHidden = YES;
    }

    // 适配自定义启动器背景（参照 LauncherPreferencesViewController / LauncherRightPanelViewController）
    // makeViewControllerTransparent: 会根据 BackgroundUIEffect 设置（毛玻璃/半透明）正确处理 view 背景，
    // 并递归透明化子 VC。之前缺失此调用导致模组下载界面不适配自定义背景。
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // CurseForge API Key 入口已统一移到设置页（LauncherPreferencesViewController），
    // 下载页不再保留，避免导航栏右侧按钮挤占空间。
    // World tab 强制使用 CurseForge，缺 key 时通过 emptyLabel/InlineMessageView 引导用户去设置页配置。

    self.modList = [NSMutableArray array];
    self.shaderList = [NSMutableArray array];
    self.modpackList = [NSMutableArray array]; // 新增
    self.resourcepackList = [NSMutableArray array];
    self.datapackList = [NSMutableArray array];
    self.worldList = [NSMutableArray array];
    self.currentModOffset = 0;
    self.currentShaderOffset = 0;
    self.currentModpackOffset = 0;
    self.currentResourcepackOffset = 0;
    self.currentDatapackOffset = 0;
    self.currentWorldOffset = 0;
    self.hasMoreMods = YES;
    self.hasMoreShaders = YES;
    self.hasMoreModpacks = YES;
    self.hasMoreResourcepacks = YES;
    self.hasMoreDatapacks = YES;
    self.hasMoreWorlds = YES;
    self.currentSortField = @"follows";
    self.isObservingProgress = NO;

    [self setupUI];
    // 初始 tab：默认 0（版本）；资源管理界面"去下载"引导跳转时会指定对应资源类型 tab
    NSInteger initialTab = MIN(MAX(self.initialTabIndex, 0), 6);
    self.tabSegment.selectedSegmentIndex = initialTab;
    [self switchToTab:initialTab];
    [self loadVersionList];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleBackgroundUIEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 重新隐藏导航栏黑条（pop 回根页面时 topViewController == self）
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil &&
        self.navigationController.topViewController == self) {
        self.navigationController.navigationBarHidden = YES;
    }
    // 重新应用背景透明效果（参照 LauncherPreferencesViewController）
    // 用户可能在外部页面切换了背景设置，回到此页时需重新适配
    if ([[BackgroundManager sharedManager] hasBackground]) {
        self.view.backgroundColor = [UIColor clearColor];
        // 对导航栏应用效果（DownloadViewController 被包在 UINavigationController 中）
        UINavigationController *nav = self.navigationController;
        if (nav) {
            nav.view.backgroundColor = [UIColor clearColor];
            [[BackgroundManager sharedManager] applyEffectToNavigationBar:nav.navigationBar];
        }
        // 重新应用侧边栏效果
        if (self.filterSidebarContainer) {
            [[BackgroundManager sharedManager] applyEffectToView:self.filterSidebarContainer];
        }
    }
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

- (void)setupUI {
    [self setupTabSegment];
    [self setupVersionFilterSegment];
    // 注意：setupSearchBar 内部引用了 filterSidebarContainer.trailingAnchor，
    // 必须在 setupFilterSidebar 之后调用（否则 filterSidebarContainer 为 nil，
    // 约束激活时 UIKit 会抛 NSInvalidArgumentException 导致点击下载 tile 立即闪退）。
    [self setupFilterSidebar];  // FCL/ZL2 风格侧边筛选栏（先创建容器）
    [self setupSearchBar];      // 再设置搜索框（依赖 filterSidebarContainer）
    [self setupSourceSwitch];
    [self setupVersionCollectionView];
    [self setupModTableView];
    [self setupShaderTableView];
    [self setupModpackTableView]; // 新增
    [self setupResourcepackTableView];
    [self setupDatapackTableView];
    [self setupWorldTableView];
    [self setupLoadingIndicator];
    [self setupEmptyLabel];
}

- (void)setupTabSegment {
    // 精简标签文字为单字+图标，避免在窄屏上拥挤截断（参照 FCL 紧凑 tab）
    self.tabSegment = [[UISegmentedControl alloc] initWithItems:@[localize(@"i18n_str_39", nil), localize(@"i18n_str_1283", nil), localize(@"i18n_str_1284", nil), localize(@"i18n_str_1285", nil), localize(@"i18n_str_1286", nil), localize(@"i18n_str_1287", nil), localize(@"i18n_str_119", nil)]];
    self.tabSegment.translatesAutoresizingMaskIntoConstraints = NO;
    self.tabSegment.selectedSegmentIndex = 0;
    // 调小字体，确保 7 个 tab 在 iPhone 竖屏也能完整显示
    NSDictionary *textAttrs = @{NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightMedium]};
    [self.tabSegment setTitleTextAttributes:textAttrs forState:UIControlStateNormal];
    [self.tabSegment addTarget:self action:@selector(tabChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.tabSegment];

    [NSLayoutConstraint activateConstraints:@[
        [self.tabSegment.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.tabSegment.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.tabSegment.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.tabSegment.heightAnchor constraintEqualToConstant:32]
    ]];
}

- (void)setupVersionFilterSegment {
    self.versionFilterSegment = [[UISegmentedControl alloc] initWithItems:@[localize(@"resman.mods.filter.all", nil), localize(@"i18n_str_2058", nil), localize(@"i18n_str_2059", nil), localize(@"i18n_str_154", nil)]];
    self.versionFilterSegment.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionFilterSegment.selectedSegmentIndex = 0;
    [self.versionFilterSegment addTarget:self action:@selector(versionFilterChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.versionFilterSegment];

    // 高度约束：版本 tab 时设为 32（系统默认 UISegmentedControl 高度），其他 tab 设为 0
    // 避免 hidden=YES 仍占空间导致 tabSegment 与 searchBar 之间出现"大白条"
    self.versionFilterHeightConstraint = [self.versionFilterSegment.heightAnchor constraintEqualToConstant:32];

    [NSLayoutConstraint activateConstraints:@[
        [self.versionFilterSegment.topAnchor constraintEqualToAnchor:self.tabSegment.bottomAnchor constant:8],
        [self.versionFilterSegment.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.versionFilterSegment.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        self.versionFilterHeightConstraint
    ]];
}

- (void)setupSearchBar {
    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBar.placeholder = localize(@"i18n_str_155", nil);
    self.searchBar.delegate = self;
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    // 搜索框对所有 tab 都显示（版本 tab 用于按版本号前缀过滤）
    self.searchBar.hidden = NO;
    [self.view addSubview:self.searchBar];

    self.filterButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.filterButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.filterButton setImage:[UIImage systemImageNamed:@"slider.horizontal.3"] forState:UIControlStateNormal];
    [self.filterButton addTarget:self action:@selector(showFilterOptions) forControlEvents:UIControlEventTouchUpInside];
    self.filterButton.hidden = YES;
    [self.view addSubview:self.filterButton];

    // 整合包 tab 专用"导入本地整合包"按钮（参照 FCL 安卓在整合包列表上方提供显眼导入入口）
    self.importModpackButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.importModpackButton.translatesAutoresizingMaskIntoConstraints = NO;
    // square.and.arrow.down.on.square 是 iOS 14+ 符号，加 fallback 避免显示成方块
    UIImage *importIcon = [UIImage systemImageNamed:@"square.and.arrow.down.on.square"]
                          ?: [UIImage systemImageNamed:@"square.and.arrow.down"]
                          ?: [UIImage systemImageNamed:@"tray.and.arrow.down"];
    [self.importModpackButton setImage:importIcon forState:UIControlStateNormal];
    [self.importModpackButton setTitle:localize(@"i18n_str_156", nil) forState:UIControlStateNormal];
    self.importModpackButton.tintColor = [UIColor whiteColor];
    self.importModpackButton.backgroundColor = [UIColor systemPurpleColor];
    self.importModpackButton.layer.cornerRadius = 10;
    self.importModpackButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    self.importModpackButton.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 10);
    self.importModpackButton.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 4);
    self.importModpackButton.hidden = YES;
    [self.importModpackButton addTarget:self action:@selector(openImportModpackView) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.importModpackButton];

    [NSLayoutConstraint activateConstraints:@[
        // 搜索框放在版本筛选框下方，避免与 versionFilterSegment 重合。
        // 关键修复：searchBar.leading 跟随 filterSidebarContainer.trailing（与各 tab 表格一致），
        // 这样侧边筛选栏展开时搜索框会自动右移避让，不再被筛选栏遮挡。
        // 之前 searchBar.leading = view.leading+8，侧栏展开（140/180pt）时水平重叠遮挡搜索框左半部分。
        [self.searchBar.topAnchor constraintEqualToAnchor:self.versionFilterSegment.bottomAnchor constant:8],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor constant:8],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.importModpackButton.leadingAnchor constant:-8],

        [self.importModpackButton.centerYAnchor constraintEqualToAnchor:self.searchBar.centerYAnchor],
        [self.importModpackButton.trailingAnchor constraintEqualToAnchor:self.filterButton.leadingAnchor constant:-4],
        [self.importModpackButton.heightAnchor constraintEqualToConstant:36],

        [self.filterButton.centerYAnchor constraintEqualToAnchor:self.searchBar.centerYAnchor],
        [self.filterButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.filterButton.widthAnchor constraintEqualToConstant:44],
        [self.filterButton.heightAnchor constraintEqualToConstant:44]
    ]];

    // 默认宽度 0（隐藏时不占空间），整合包 tab 切换时设为 80
    self.importModpackButtonWidthConstraint = [self.importModpackButton.widthAnchor constraintEqualToConstant:0];
    self.importModpackButtonWidthConstraint.active = YES;
}

- (void)setupVersionCollectionView {
    // 参照 FCL (item_remote_version.xml 单列列表) 与 ZL2 (LazyColumn VersionItemLayout)：
    // 改为单列横向列表行布局，每行一个全宽卡片，行高 64pt（cell 内部再留 4pt 上下边距，实际卡片 56pt）。
    // itemSize.width 在 viewDidLayoutSubviews 里按 collectionView 实际宽度动态更新，避免横竖屏切换错位。
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.scrollDirection = UICollectionViewScrollDirectionVertical;
    layout.minimumInteritemSpacing = 0;  // 单列，无横向间距
    layout.minimumLineSpacing = 4;       // 行间小间距，卡片自带阴影做视觉分隔
    layout.itemSize = CGSizeMake(360, 64); // 默认宽度，viewDidLayoutSubviews 会覆盖
    layout.sectionInset = UIEdgeInsetsMake(8, 16, 8, 16);

    self.versionCollectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.versionCollectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionCollectionView.backgroundColor = [UIColor clearColor];
    self.versionCollectionView.dataSource = self;
    self.versionCollectionView.delegate = self;
    // 选中态反馈：点击单元格时短暂高亮（FCL/ZL2 都有按压视觉反馈）
    self.versionCollectionView.allowsSelection = YES;
    self.versionCollectionView.alwaysBounceVertical = YES;
    [self.versionCollectionView registerClass:[VersionCardCell class] forCellWithReuseIdentifier:@"VersionCard"];
    [self.view addSubview:self.versionCollectionView];

    [NSLayoutConstraint activateConstraints:@[
        // 版本列表放在搜索框下方，避免与搜索框重合
        [self.versionCollectionView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:4],
        [self.versionCollectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.versionCollectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.versionCollectionView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

// 动态更新版本列表 itemSize 宽度，使其填满 collectionView 宽度（减去 sectionInset 左右各 16pt）。
// 横屏切换或分屏尺寸变化时由系统自动调用，无需手动注册通知。
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!self.versionCollectionView) return;
    UICollectionViewFlowLayout *layout = (UICollectionViewFlowLayout *)self.versionCollectionView.collectionViewLayout;
    if (![layout isKindOfClass:[UICollectionViewFlowLayout class]]) return;
    CGFloat horizInset = layout.sectionInset.left + layout.sectionInset.right;
    CGFloat availableWidth = MAX(0, self.versionCollectionView.bounds.size.width - horizInset);
    CGSize target = CGSizeMake(availableWidth, 64);
    if (!CGSizeEqualToSize(layout.itemSize, target)) {
        layout.itemSize = target;
        // invalidateLayout 触发重新排版，避免 cell 复用时宽度滞后
        [layout invalidateLayout];
    }

    // 动态调整侧边栏宽度（横竖屏切换时）
    if (self.filterSidebarContainer && !self.filterSidebarContainer.hidden) {
        // FCL page_download.xml：search_layout 用 layout_constraintWidth_percent="0.3"
        // 这里按 view 宽度 30% 计算，并加上下限避免极端尺寸（iPhone SE 最小 120pt，iPad 最大 280pt）
        CGFloat screenWidth = self.view.bounds.size.width;
        CGFloat newWidth = screenWidth * 0.3;
        newWidth = MAX(120.0, MIN(280.0, newWidth));
        if (ABS(self.sidebarWidthConstraint.constant - newWidth) > 0.5) {
            self.sidebarWidthConstraint.constant = newWidth;
        }
    }
}

- (void)setupModTableView {
    self.modTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.modTableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.modTableView.backgroundColor = [UIColor clearColor];
    self.modTableView.dataSource = self;
    self.modTableView.delegate = self;
    // FCL view_installer_item.xml：item 高度 ~46dp + marginBottom 10dp
    // 这里 54pt（图标 26pt + 双行文字 + 上下 padding 4pt），每屏显示更多
    self.modTableView.rowHeight = 54;
    self.modTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.modTableView registerClass:[ModernAssetCell class] forCellReuseIdentifier:@"ModCell"];
    self.modTableView.hidden = YES;
    [self.view addSubview:self.modTableView];

    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(refreshModList) forControlEvents:UIControlEventValueChanged];
    self.modTableView.refreshControl = refreshControl;

    // FCL/ZL2 风格：列表 leading 跟随侧边栏 trailing，top 跟随 searchBar
    // 侧边栏隐藏时宽度为 0，trailingAnchor 等于 view.leadingAnchor，列表自动铺满
    // leading 加 8pt 间距，避免与左侧筛选栏紧贴（视觉呼吸感，阶段3 UI 调整）
    [NSLayoutConstraint activateConstraints:@[
        [self.modTableView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:4],
        [self.modTableView.leadingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor constant:8],
        [self.modTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.modTableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

- (void)setupShaderTableView {
    self.shaderTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.shaderTableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.shaderTableView.backgroundColor = [UIColor clearColor];
    self.shaderTableView.dataSource = self;
    self.shaderTableView.delegate = self;
    // FCL 风格扁平条目：行高 54pt
    self.shaderTableView.rowHeight = 54;
    self.shaderTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.shaderTableView registerClass:[ModernAssetCell class] forCellReuseIdentifier:@"ShaderCell"];
    self.shaderTableView.hidden = YES;
    [self.view addSubview:self.shaderTableView];

    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(refreshShaderList) forControlEvents:UIControlEventValueChanged];
    self.shaderTableView.refreshControl = refreshControl;

    // leading 加 8pt 间距，避免与左侧筛选栏紧贴（视觉呼吸感，阶段3 UI 调整）
    [NSLayoutConstraint activateConstraints:@[
        [self.shaderTableView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:4],
        [self.shaderTableView.leadingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor constant:8],
        [self.shaderTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.shaderTableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

- (void)setupModpackTableView {
    self.modpackTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.modpackTableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.modpackTableView.backgroundColor = [UIColor clearColor];
    self.modpackTableView.dataSource = self;
    self.modpackTableView.delegate = self;
    // FCL 风格扁平条目：行高 54pt
    self.modpackTableView.rowHeight = 54;
    self.modpackTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.modpackTableView registerClass:[ModernAssetCell class] forCellReuseIdentifier:@"ModpackCell"];
    self.modpackTableView.hidden = YES;
    [self.view addSubview:self.modpackTableView];

    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(refreshModpackList) forControlEvents:UIControlEventValueChanged];
    self.modpackTableView.refreshControl = refreshControl;

    // leading 加 8pt 间距，避免与左侧筛选栏紧贴（视觉呼吸感，阶段3 UI 调整）
    [NSLayoutConstraint activateConstraints:@[
        [self.modpackTableView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:4],
        [self.modpackTableView.leadingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor constant:8],
        [self.modpackTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.modpackTableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

- (void)setupResourcepackTableView {
    self.resourcepackTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.resourcepackTableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.resourcepackTableView.backgroundColor = [UIColor clearColor];
    self.resourcepackTableView.dataSource = self;
    self.resourcepackTableView.delegate = self;
    // FCL 风格扁平条目：行高 54pt
    self.resourcepackTableView.rowHeight = 54;
    self.resourcepackTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.resourcepackTableView registerClass:[ModernAssetCell class] forCellReuseIdentifier:@"ResourcepackCell"];
    self.resourcepackTableView.hidden = YES;
    [self.view addSubview:self.resourcepackTableView];

    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(refreshResourcepackList) forControlEvents:UIControlEventValueChanged];
    self.resourcepackTableView.refreshControl = refreshControl;

    // leading 加 8pt 间距，避免与左侧筛选栏紧贴（视觉呼吸感，阶段3 UI 调整）
    [NSLayoutConstraint activateConstraints:@[
        [self.resourcepackTableView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:4],
        [self.resourcepackTableView.leadingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor constant:8],
        [self.resourcepackTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.resourcepackTableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

- (void)setupDatapackTableView {
    self.datapackTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.datapackTableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.datapackTableView.backgroundColor = [UIColor clearColor];
    self.datapackTableView.dataSource = self;
    self.datapackTableView.delegate = self;
    // FCL 风格扁平条目：行高 54pt
    self.datapackTableView.rowHeight = 54;
    self.datapackTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.datapackTableView registerClass:[ModernAssetCell class] forCellReuseIdentifier:@"DatapackCell"];
    self.datapackTableView.hidden = YES;
    [self.view addSubview:self.datapackTableView];

    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(refreshDatapackList) forControlEvents:UIControlEventValueChanged];
    self.datapackTableView.refreshControl = refreshControl;

    // leading 加 8pt 间距，避免与左侧筛选栏紧贴（视觉呼吸感，阶段3 UI 调整）
    [NSLayoutConstraint activateConstraints:@[
        [self.datapackTableView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:4],
        [self.datapackTableView.leadingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor constant:8],
        [self.datapackTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.datapackTableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

- (void)setupWorldTableView {
    self.worldTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.worldTableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.worldTableView.backgroundColor = [UIColor clearColor];
    self.worldTableView.dataSource = self;
    self.worldTableView.delegate = self;
    // FCL 风格扁平条目：行高 54pt
    self.worldTableView.rowHeight = 54;
    self.worldTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.worldTableView registerClass:[ModernAssetCell class] forCellReuseIdentifier:@"WorldCell"];
    self.worldTableView.hidden = YES;
    [self.view addSubview:self.worldTableView];

    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(refreshWorldList) forControlEvents:UIControlEventValueChanged];
    self.worldTableView.refreshControl = refreshControl;

    // 世界 tab 不显示侧边栏（强制 CurseForge），列表 leading 直接跟随 view
    // leading 加 8pt 间距，保持与其他 tab 一致的视觉呼吸感（阶段3 UI 调整）
    [NSLayoutConstraint activateConstraints:@[
        [self.worldTableView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:4],
        [self.worldTableView.leadingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor constant:8],
        [self.worldTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.worldTableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

- (void)setupSourceSwitch {
    // 仿 FCL 安卓风格：居中的圆角胶囊切换器，带彩色滑块与品牌色
    self.sourceSwitchContainer = [[UIView alloc] init];
    self.sourceSwitchContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.sourceSwitchContainer.hidden = YES;
    [self.view addSubview:self.sourceSwitchContainer];

    // 圆角胶囊背景轨道
    self.sourceSwitchTrack = [[UIView alloc] init];
    self.sourceSwitchTrack.translatesAutoresizingMaskIntoConstraints = NO;
    self.sourceSwitchTrack.backgroundColor = [UIColor tertiarySystemFillColor];
    self.sourceSwitchTrack.layer.cornerRadius = 16;
    self.sourceSwitchTrack.layer.masksToBounds = YES;
    [self.sourceSwitchContainer addSubview:self.sourceSwitchTrack];

    // 选中项滑块（初始为 Modrinth 绿）
    self.sourceSwitchSlider = [[UIView alloc] init];
    self.sourceSwitchSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.sourceSwitchSlider.backgroundColor = [UIColor systemGreenColor];
    self.sourceSwitchSlider.layer.cornerRadius = 14;
    // 阴影提升层次感
    self.sourceSwitchSlider.layer.shadowColor = [UIColor blackColor].CGColor;
    self.sourceSwitchSlider.layer.shadowOpacity = 0.15;
    self.sourceSwitchSlider.layer.shadowOffset = CGSizeMake(0, 1);
    self.sourceSwitchSlider.layer.shadowRadius = 3;
    [self.sourceSwitchTrack addSubview:self.sourceSwitchSlider];

    // Modrinth 按钮
    self.modrinthSourceButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.modrinthSourceButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.modrinthSourceButton setTitle:@"Modrinth" forState:UIControlStateNormal];
    self.modrinthSourceButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [self.modrinthSourceButton addTarget:self action:@selector(modrinthSourceButtonClicked:) forControlEvents:UIControlEventTouchUpInside];
    [self.sourceSwitchTrack addSubview:self.modrinthSourceButton];

    // CurseForge 按钮
    self.curseforgeSourceButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.curseforgeSourceButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.curseforgeSourceButton setTitle:@"CurseForge" forState:UIControlStateNormal];
    self.curseforgeSourceButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [self.curseforgeSourceButton addTarget:self action:@selector(curseforgeSourceButtonClicked:) forControlEvents:UIControlEventTouchUpInside];
    [self.sourceSwitchTrack addSubview:self.curseforgeSourceButton];

    // 容器约束：居中、固定宽度、固定高度
    self.sliderLeftPosConstraint = [self.sourceSwitchSlider.leadingAnchor constraintEqualToAnchor:self.sourceSwitchTrack.leadingAnchor constant:2];
    self.sliderRightPosConstraint = [self.sourceSwitchSlider.trailingAnchor constraintEqualToAnchor:self.sourceSwitchTrack.trailingAnchor constant:-2];
    self.sliderRightPosConstraint.active = NO; // 初始 Modrinth 在左

    [NSLayoutConstraint activateConstraints:@[
        [self.sourceSwitchContainer.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:6],
        [self.sourceSwitchContainer.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.sourceSwitchContainer.widthAnchor constraintEqualToConstant:220],
        [self.sourceSwitchContainer.heightAnchor constraintEqualToConstant:36],

        // 轨道铺满容器
        [self.sourceSwitchTrack.topAnchor constraintEqualToAnchor:self.sourceSwitchContainer.topAnchor],
        [self.sourceSwitchTrack.leadingAnchor constraintEqualToAnchor:self.sourceSwitchContainer.leadingAnchor],
        [self.sourceSwitchTrack.trailingAnchor constraintEqualToAnchor:self.sourceSwitchContainer.trailingAnchor],
        [self.sourceSwitchTrack.bottomAnchor constraintEqualToAnchor:self.sourceSwitchContainer.bottomAnchor],

        // 滑块高度/宽度（宽度 = 轨道一半 - 2pt 边距），位置由 left/right 约束二选一定位
        [self.sourceSwitchSlider.topAnchor constraintEqualToAnchor:self.sourceSwitchTrack.topAnchor constant:2],
        [self.sourceSwitchSlider.bottomAnchor constraintEqualToAnchor:self.sourceSwitchTrack.bottomAnchor constant:-2],
        [self.sourceSwitchSlider.widthAnchor constraintEqualToAnchor:self.sourceSwitchTrack.widthAnchor multiplier:0.5 constant:-2],
        self.sliderLeftPosConstraint,

        // 两个按钮各占一半
        [self.modrinthSourceButton.topAnchor constraintEqualToAnchor:self.sourceSwitchTrack.topAnchor],
        [self.modrinthSourceButton.bottomAnchor constraintEqualToAnchor:self.sourceSwitchTrack.bottomAnchor],
        [self.modrinthSourceButton.leadingAnchor constraintEqualToAnchor:self.sourceSwitchTrack.leadingAnchor],
        [self.modrinthSourceButton.widthAnchor constraintEqualToAnchor:self.sourceSwitchTrack.widthAnchor multiplier:0.5],

        [self.curseforgeSourceButton.topAnchor constraintEqualToAnchor:self.sourceSwitchTrack.topAnchor],
        [self.curseforgeSourceButton.bottomAnchor constraintEqualToAnchor:self.sourceSwitchTrack.bottomAnchor],
        [self.curseforgeSourceButton.trailingAnchor constraintEqualToAnchor:self.sourceSwitchTrack.trailingAnchor],
        [self.curseforgeSourceButton.widthAnchor constraintEqualToAnchor:self.sourceSwitchTrack.widthAnchor multiplier:0.5]
    ]];

    // 动态高度约束（隐藏时为 0，显示时为 36）
    self.sourceSwitchHeightConstraint = [self.sourceSwitchContainer.heightAnchor constraintEqualToConstant:0];
    self.sourceSwitchHeightConstraint.active = YES;
}

#pragma mark - FCL/ZL2 风格侧边筛选栏

/// 创建侧边筛选栏（参照 FCL/ZL2 的模组/光影下载界面布局）
///
/// 布局结构（侧边栏内从上到下）：
/// 1. 下载源选择器（Modrinth / CurseForge 圆角胶囊切换器）
/// 2. 游戏版本选择按钮（点击弹出 ActionSheet 选择版本）
/// 3. 模组加载器选择按钮（点击弹出 ActionSheet 选择加载器，仅模组 tab 显示）
/// 4. 排序方式选择按钮（点击弹出 ActionSheet 选择排序方式）
/// 5. 重置筛选按钮
///
/// 侧边栏在模组/光影/资源包/数据包/整合包 tab 显示，版本 tab 和世界 tab 隐藏。
/// 隐藏时宽度为 0，不占空间；显示时宽度 180pt（宽屏）或 140pt（窄屏）。
- (void)setupFilterSidebar {
    self.filterSidebarContainer = [[UIView alloc] init];
    self.filterSidebarContainer.translatesAutoresizingMaskIntoConstraints = NO;
    // 适配自定义启动器背景：使用 BackgroundManager 的 applyEffectToView: 而非不透明的
    // secondarySystemBackgroundColor。之前用 secondarySystemBackgroundColor（完全不透明）
    // 会遮挡自定义背景，导致模组/光影下载界面不适配自定义启动器背景。
    // applyEffectToView: 会根据 BackgroundUIEffect 设置（毛玻璃/半透明）正确处理，
    // 参照 LauncherRootViewController.m 中对 sidebarContainer 的处理方式。
    self.filterSidebarContainer.backgroundColor = [UIColor clearColor];
    self.filterSidebarContainer.layer.cornerRadius = 12;
    self.filterSidebarContainer.layer.masksToBounds = YES;
    [[BackgroundManager sharedManager] applyEffectToView:self.filterSidebarContainer];
    self.filterSidebarContainer.hidden = YES;
    [self.view addSubview:self.filterSidebarContainer];

    // 侧边栏宽度约束：隐藏时为 0，显示时为 180（宽屏）或 140（窄屏）
    // 在 viewDidLayoutSubviews 中根据屏幕宽度动态调整
    self.sidebarWidthConstraint = [self.filterSidebarContainer.widthAnchor constraintEqualToConstant:0];

    [NSLayoutConstraint activateConstraints:@[
        [self.filterSidebarContainer.topAnchor constraintEqualToAnchor:self.tabSegment.bottomAnchor constant:8],
        // 关键修复：leading 留 8pt 间距，避免与左侧菜单栏（LauncherMenuViewController）视觉接触。
        // 之前 leading = view.leading+0，filterSidebarContainer 紧贴 contentContainer 左边缘，
        // 而 contentContainer 左边缘就是菜单栏右边缘，视觉上筛选栏与菜单栏"贴在一起"。
        // 加 8pt 间距后两者之间有清晰分隔，与右侧 tableView 的 8pt 间距对称。
        [self.filterSidebarContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [self.filterSidebarContainer.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        self.sidebarWidthConstraint
    ]];

    // ===== 1. 下载源选择器（从顶部移到侧边栏）=====
    self.sidebarSourceContainer = [[UIView alloc] init];
    self.sidebarSourceContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.filterSidebarContainer addSubview:self.sidebarSourceContainer];

    // 下载源标题
    UILabel *sourceTitleLabel = [[UILabel alloc] init];
    sourceTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    sourceTitleLabel.text = localize(@"i18n_str_157", nil);
    sourceTitleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    sourceTitleLabel.textColor = [UIColor secondaryLabelColor];
    [self.filterSidebarContainer addSubview:sourceTitleLabel];

    // 下载源轨道
    self.sidebarSourceTrack = [[UIView alloc] init];
    self.sidebarSourceTrack.translatesAutoresizingMaskIntoConstraints = NO;
    self.sidebarSourceTrack.backgroundColor = [UIColor tertiarySystemFillColor];
    self.sidebarSourceTrack.layer.cornerRadius = 14;
    self.sidebarSourceTrack.layer.masksToBounds = YES;
    [self.sidebarSourceContainer addSubview:self.sidebarSourceTrack];

    // 下载源滑块
    self.sidebarSourceSlider = [[UIView alloc] init];
    self.sidebarSourceSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.sidebarSourceSlider.backgroundColor = [UIColor systemGreenColor];
    self.sidebarSourceSlider.layer.cornerRadius = 12;
    self.sidebarSourceSlider.layer.shadowColor = [UIColor blackColor].CGColor;
    self.sidebarSourceSlider.layer.shadowOpacity = 0.15;
    self.sidebarSourceSlider.layer.shadowOffset = CGSizeMake(0, 1);
    self.sidebarSourceSlider.layer.shadowRadius = 3;
    [self.sidebarSourceTrack addSubview:self.sidebarSourceSlider];

    // Modrinth 按钮
    self.sidebarModrinthButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.sidebarModrinthButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.sidebarModrinthButton setTitle:@"Mod" forState:UIControlStateNormal];
    self.sidebarModrinthButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [self.sidebarModrinthButton addTarget:self action:@selector(sidebarModrinthClicked:) forControlEvents:UIControlEventTouchUpInside];
    [self.sidebarSourceTrack addSubview:self.sidebarModrinthButton];

    // CurseForge 按钮
    self.sidebarCurseforgeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.sidebarCurseforgeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.sidebarCurseforgeButton setTitle:@"CF" forState:UIControlStateNormal];
    self.sidebarCurseforgeButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [self.sidebarCurseforgeButton addTarget:self action:@selector(sidebarCurseforgeClicked:) forControlEvents:UIControlEventTouchUpInside];
    [self.sidebarSourceTrack addSubview:self.sidebarCurseforgeButton];

    // 下载源滑块位置约束
    self.sidebarSliderLeftConstraint = [self.sidebarSourceSlider.leadingAnchor constraintEqualToAnchor:self.sidebarSourceTrack.leadingAnchor constant:2];
    self.sidebarSliderRightConstraint = [self.sidebarSourceSlider.trailingAnchor constraintEqualToAnchor:self.sidebarSourceTrack.trailingAnchor constant:-2];
    self.sidebarSliderRightConstraint.active = NO;

    [NSLayoutConstraint activateConstraints:@[
        // 下载源标题
        [sourceTitleLabel.topAnchor constraintEqualToAnchor:self.filterSidebarContainer.topAnchor constant:12],
        [sourceTitleLabel.leadingAnchor constraintEqualToAnchor:self.filterSidebarContainer.leadingAnchor constant:12],
        [sourceTitleLabel.trailingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor constant:-12],

        // 下载源容器
        [self.sidebarSourceContainer.topAnchor constraintEqualToAnchor:sourceTitleLabel.bottomAnchor constant:4],
        [self.sidebarSourceContainer.leadingAnchor constraintEqualToAnchor:self.filterSidebarContainer.leadingAnchor constant:8],
        [self.sidebarSourceContainer.trailingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor constant:-8],
        [self.sidebarSourceContainer.heightAnchor constraintEqualToConstant:32],

        // 轨道铺满容器
        [self.sidebarSourceTrack.topAnchor constraintEqualToAnchor:self.sidebarSourceContainer.topAnchor],
        [self.sidebarSourceTrack.leadingAnchor constraintEqualToAnchor:self.sidebarSourceContainer.leadingAnchor],
        [self.sidebarSourceTrack.trailingAnchor constraintEqualToAnchor:self.sidebarSourceContainer.trailingAnchor],
        [self.sidebarSourceTrack.bottomAnchor constraintEqualToAnchor:self.sidebarSourceContainer.bottomAnchor],

        // 滑块
        [self.sidebarSourceSlider.topAnchor constraintEqualToAnchor:self.sidebarSourceTrack.topAnchor constant:2],
        [self.sidebarSourceSlider.bottomAnchor constraintEqualToAnchor:self.sidebarSourceTrack.bottomAnchor constant:-2],
        [self.sidebarSourceSlider.widthAnchor constraintEqualToAnchor:self.sidebarSourceTrack.widthAnchor multiplier:0.5 constant:-2],
        self.sidebarSliderLeftConstraint,

        // 两个按钮各占一半
        [self.sidebarModrinthButton.topAnchor constraintEqualToAnchor:self.sidebarSourceTrack.topAnchor],
        [self.sidebarModrinthButton.bottomAnchor constraintEqualToAnchor:self.sidebarSourceTrack.bottomAnchor],
        [self.sidebarModrinthButton.leadingAnchor constraintEqualToAnchor:self.sidebarSourceTrack.leadingAnchor],
        [self.sidebarModrinthButton.widthAnchor constraintEqualToAnchor:self.sidebarSourceTrack.widthAnchor multiplier:0.5],

        [self.sidebarCurseforgeButton.topAnchor constraintEqualToAnchor:self.sidebarSourceTrack.topAnchor],
        [self.sidebarCurseforgeButton.bottomAnchor constraintEqualToAnchor:self.sidebarSourceTrack.bottomAnchor],
        [self.sidebarCurseforgeButton.trailingAnchor constraintEqualToAnchor:self.sidebarSourceTrack.trailingAnchor],
        [self.sidebarCurseforgeButton.widthAnchor constraintEqualToAnchor:self.sidebarSourceTrack.widthAnchor multiplier:0.5]
    ]];

    // ===== 2. 游戏版本选择按钮 =====
    self.sidebarVersionButton = [self createSidebarSelectButtonWithTitle:localize(@"i18n_str_2031", nil)
                                                                    value:@"全部版本"
                                                                  selector:@selector(sidebarVersionButtonClicked:)];
    [self.filterSidebarContainer addSubview:self.sidebarVersionButton];
    self.sidebarVersionTitleLabel = [self findSubviewInButton:self.sidebarVersionButton withTag:100];
    self.sidebarVersionValueLabel = [self findSubviewInButton:self.sidebarVersionButton withTag:101];
    [NSLayoutConstraint activateConstraints:@[
        [self.sidebarVersionButton.topAnchor constraintEqualToAnchor:self.sidebarSourceContainer.bottomAnchor constant:8],
        [self.sidebarVersionButton.leadingAnchor constraintEqualToAnchor:self.filterSidebarContainer.leadingAnchor constant:8],
        [self.sidebarVersionButton.trailingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor constant:-8],
        [self.sidebarVersionButton.heightAnchor constraintEqualToConstant:44]
    ]];

    // ===== 3. 模组加载器选择按钮 =====
    self.sidebarLoaderButton = [self createSidebarSelectButtonWithTitle:localize(@"i18n_str_160", nil)
                                                                   value:@"全部"
                                                                 selector:@selector(sidebarLoaderButtonClicked:)];
    [self.filterSidebarContainer addSubview:self.sidebarLoaderButton];
    self.sidebarLoaderTitleLabel = [self findSubviewInButton:self.sidebarLoaderButton withTag:100];
    self.sidebarLoaderValueLabel = [self findSubviewInButton:self.sidebarLoaderButton withTag:101];
    [NSLayoutConstraint activateConstraints:@[
        [self.sidebarLoaderButton.topAnchor constraintEqualToAnchor:self.sidebarVersionButton.bottomAnchor constant:8],
        [self.sidebarLoaderButton.leadingAnchor constraintEqualToAnchor:self.filterSidebarContainer.leadingAnchor constant:8],
        [self.sidebarLoaderButton.trailingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor constant:-8],
        [self.sidebarLoaderButton.heightAnchor constraintEqualToConstant:44]
    ]];

    // ===== 4. 排序方式选择按钮 =====
    self.sidebarSortButton = [self createSidebarSelectButtonWithTitle:localize(@"i18n_str_161", nil)
                                                                 value:localize(@"i18n_str_162", nil)
                                                               selector:@selector(sidebarSortButtonClicked:)];
    [self.filterSidebarContainer addSubview:self.sidebarSortButton];
    self.sidebarSortTitleLabel = [self findSubviewInButton:self.sidebarSortButton withTag:100];
    self.sidebarSortValueLabel = [self findSubviewInButton:self.sidebarSortButton withTag:101];
    [NSLayoutConstraint activateConstraints:@[
        [self.sidebarSortButton.topAnchor constraintEqualToAnchor:self.sidebarLoaderButton.bottomAnchor constant:8],
        [self.sidebarSortButton.leadingAnchor constraintEqualToAnchor:self.filterSidebarContainer.leadingAnchor constant:8],
        [self.sidebarSortButton.trailingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor constant:-8],
        [self.sidebarSortButton.heightAnchor constraintEqualToConstant:44]
    ]];

    // ===== 5. 重置筛选按钮 =====
    self.sidebarResetButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.sidebarResetButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.sidebarResetButton setTitle:localize(@"i18n_str_163", nil) forState:UIControlStateNormal];
    self.sidebarResetButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [self.sidebarResetButton setImage:[UIImage systemImageNamed:@"arrow.counterclockwise"] forState:UIControlStateNormal];
    self.sidebarResetButton.tintColor = [UIColor systemRedColor];
    self.sidebarResetButton.backgroundColor = [UIColor tertiarySystemFillColor];
    self.sidebarResetButton.layer.cornerRadius = 8;
    self.sidebarResetButton.imageEdgeInsets = UIEdgeInsetsMake(0, -2, 0, 2);
    self.sidebarResetButton.titleEdgeInsets = UIEdgeInsetsMake(0, 2, 0, -2);
    [self.sidebarResetButton addTarget:self action:@selector(sidebarResetButtonClicked:) forControlEvents:UIControlEventTouchUpInside];
    [self.filterSidebarContainer addSubview:self.sidebarResetButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.sidebarResetButton.topAnchor constraintEqualToAnchor:self.sidebarSortButton.bottomAnchor constant:12],
        [self.sidebarResetButton.leadingAnchor constraintEqualToAnchor:self.filterSidebarContainer.leadingAnchor constant:12],
        [self.sidebarResetButton.trailingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor constant:-12],
        [self.sidebarResetButton.heightAnchor constraintEqualToConstant:32]
    ]];

    // 底部分隔线
    UIView *sidebarSeparator = [[UIView alloc] init];
    sidebarSeparator.translatesAutoresizingMaskIntoConstraints = NO;
    sidebarSeparator.backgroundColor = [UIColor separatorColor];
    [self.filterSidebarContainer addSubview:sidebarSeparator];
    [NSLayoutConstraint activateConstraints:@[
        [sidebarSeparator.trailingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor],
        [sidebarSeparator.topAnchor constraintEqualToAnchor:self.filterSidebarContainer.topAnchor],
        [sidebarSeparator.bottomAnchor constraintEqualToAnchor:self.filterSidebarContainer.bottomAnchor],
        [sidebarSeparator.widthAnchor constraintEqualToConstant:0.5]
    ]];
}

/// 创建侧边栏的选择按钮（标题 + 当前值 + 箭头）
/// 按钮内子视图通过 tag 标记：titleTag=100, valueTag=101, arrowTag=102
/// 创建后可通过 findSubviewInButton:withTag: 取出对应的 label
- (UIButton *)createSidebarSelectButtonWithTitle:(NSString *)title
                                           value:(NSString *)value
                                         selector:(SEL)selector {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = [UIColor tertiarySystemFillColor];
    button.layer.cornerRadius = 8;
    [button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    button.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor secondaryLabelColor];
    titleLabel.tag = 100;
    [button addSubview:titleLabel];

    UILabel *valueLabel = [[UILabel alloc] init];
    valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    valueLabel.text = value;
    valueLabel.font = [UIFont systemFontOfSize:12];
    valueLabel.textColor = [UIColor labelColor];
    valueLabel.adjustsFontSizeToFitWidth = YES;
    valueLabel.minimumScaleFactor = 0.7;
    valueLabel.textAlignment = NSTextAlignmentRight;
    valueLabel.tag = 101;
    [button addSubview:valueLabel];

    UIImageView *arrow = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    arrow.translatesAutoresizingMaskIntoConstraints = NO;
    arrow.tintColor = [UIColor tertiaryLabelColor];
    arrow.contentMode = UIViewContentModeScaleAspectFit;
    arrow.tag = 102;
    [button addSubview:arrow];

    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.leadingAnchor constraintEqualToAnchor:button.leadingAnchor constant:12],
        [titleLabel.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],

        [valueLabel.trailingAnchor constraintEqualToAnchor:arrow.leadingAnchor constant:-4],
        [valueLabel.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
        [valueLabel.widthAnchor constraintLessThanOrEqualToConstant:80],

        [arrow.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-12],
        [arrow.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
        [arrow.widthAnchor constraintEqualToConstant:12],
        [arrow.heightAnchor constraintEqualToConstant:12]
    ]];

    return button;
}

/// 从按钮中按 tag 取出子视图（用于 createSidebarSelectButtonWithTitle: 创建的按钮）
- (UILabel *)findSubviewInButton:(UIButton *)button withTag:(NSInteger)tag {
    for (UIView *sub in button.subviews) {
        if (sub.tag == tag && [sub isKindOfClass:[UILabel class]]) {
            return (UILabel *)sub;
        }
    }
    return nil;
}

- (void)setupLoadingIndicator {
    self.loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingIndicator.hidesWhenStopped = YES;
    self.loadingIndicator.color = [UIColor labelColor];
    [self.view addSubview:self.loadingIndicator];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.loadingIndicator.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.loadingIndicator.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]
    ]];
}

- (void)setupEmptyLabel {
    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.text = localize(@"i18n_str_164", nil);
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.emptyLabel.hidden = YES;
    [self.view addSubview:self.emptyLabel];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]
    ]];
}

#pragma mark - Tab Switching

- (void)tabChanged:(UISegmentedControl *)sender {
    [self switchToTab:sender.selectedSegmentIndex];
}

- (void)switchToTab:(NSInteger)index {
    // 列表切换使用淡入淡出，避免生硬的瞬间 hidden 切换
    [UIView transitionWithView:self.view duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        self.versionFilterSegment.hidden = (index != 0);
        self.versionCollectionView.hidden = (index != 0);
        // 搜索框对所有 tab 都显示（版本 tab 用于按版本号前缀过滤本地+远程版本列表）
        self.searchBar.hidden = NO;
        // 过滤按钮仅在版本 tab 显示（用于调出版本类型筛选/排序选项）
        self.filterButton.hidden = (index != 0);
        self.modTableView.hidden = (index != 1);
        self.shaderTableView.hidden = (index != 2);
        self.resourcepackTableView.hidden = (index != 3);
        self.datapackTableView.hidden = (index != 4);
        self.modpackTableView.hidden = (index != 5);
        self.worldTableView.hidden = (index != 6);
    } completion:nil];

    // 源切换仅在非版本 tab 显示；世界 tab 强制 CurseForge，无需切换
    // 注意：顶部 sourceSwitchContainer 现在已弃用（下载源已移到侧边栏），始终隐藏
    // 保留属性避免其他方法引用时崩溃，但高度始终为 0
    BOOL showSourceSwitch = (index != 0 && index != 6);
    self.sourceSwitchContainer.hidden = YES;
    self.sourceSwitchHeightConstraint.constant = 0;

    // ===== FCL/ZL2 风格侧边栏显示/隐藏 =====
    // FCL page_download.xml：5 个资产 tab（mod/modpack/resourcepack/world/shaderpack）共用
    // 左侧 30% 筛选栏。版本 tab 是独立布局（versionFilterSegment + collectionView），无 sidebar。
    // 这里 100% 对齐 FCL：所有非版本 tab 都显示 sidebar（含世界 tab）。
    BOOL showSidebar = (index != 0);
    self.filterSidebarContainer.hidden = !showSidebar;
    // 根据屏幕宽度按 30% 比例计算侧边栏宽度（FCL constraintWidth_percent=0.3）
    CGFloat screenWidth = self.view.bounds.size.width;
    CGFloat sidebarWidth = 0;
    if (showSidebar) {
        sidebarWidth = screenWidth * 0.3;
        sidebarWidth = MAX(120.0, MIN(280.0, sidebarWidth));
    }
    self.sidebarWidthConstraint.constant = sidebarWidth;

    // 模组加载器选择按钮仅在模组 tab 显示（其他 tab 无加载器概念）
    self.sidebarLoaderButton.hidden = (index != 1);
    self.sidebarLoaderTitleLabel.hidden = (index != 1);
    self.sidebarLoaderValueLabel.hidden = (index != 1);

    // 下载源切换：世界 tab 强制 CurseForge，隐藏源切换；其他非版本 tab 显示
    // FCL page_download.xml：仅当有多个来源时才显示 source Spinner
    self.sidebarSourceContainer.hidden = (index == 0 || index == 6);

    // versionFilterSegment 高度同步切换：版本 tab 显示 32pt，其他 tab 设为 0 不占空间，
    // 避免 hidden=YES 仍占空间导致 tabSegment 与 searchBar 之间出现"大白条"
    self.versionFilterHeightConstraint.constant = (index == 0) ? 32 : 0;

    // 整合包 tab 显示"导入本地整合包"按钮（参照 FCL 安卓），其他 tab 隐藏且宽度归零不占空间
    BOOL showImportButton = (index == 5);
    self.importModpackButton.hidden = !showImportButton;
    self.importModpackButtonWidthConstraint.constant = showImportButton ? 80 : 0;

    [UIView animateWithDuration:0.2 animations:^{
        [self.view layoutIfNeeded];
    }];

    if (index == 0) {
        // 版本 tab：按版本号前缀过滤版本列表
        self.searchBar.placeholder = localize(@"i18n_str_155", nil);
        // 版本 tab 不需要源切换
    } else if (index == 1) {
        self.searchBar.placeholder = localize(@"i18n_str_165", nil);
        [self updateSourceSwitchButtonsForType:@"mod"];
        // FCL 风格：首次进入模组 tab 时自动预选当前 profile 的版本和加载器
        // 让搜索结果自动匹配当前游戏环境（如 neoforge + 1.21.1），无需手动筛选
        [self autoApplyProfileFiltersIfNeeded];
        if (self.modList.count == 0) {
            [self loadModList];
        }
    } else if (index == 2) {
        self.searchBar.placeholder = localize(@"i18n_str_166", nil);
        [self updateSourceSwitchButtonsForType:@"shader"];
        [self autoApplyProfileFiltersIfNeeded];
        if (self.shaderList.count == 0) {
            [self loadShaderList];
        }
    } else if (index == 3) {
        self.searchBar.placeholder = localize(@"i18n_str_167", nil);
        [self updateSourceSwitchButtonsForType:@"resourcepack"];
        [self autoApplyProfileFiltersIfNeeded];
        if (self.resourcepackList.count == 0) {
            [self loadResourcePackList];
        }
    } else if (index == 4) {
        self.searchBar.placeholder = localize(@"i18n_str_168", nil);
        [self updateSourceSwitchButtonsForType:@"datapack"];
        [self autoApplyProfileFiltersIfNeeded];
        if (self.datapackList.count == 0) {
            [self loadDataPackList];
        }
    } else if (index == 5) {
        self.searchBar.placeholder = localize(@"i18n_str_169", nil);
        [self updateSourceSwitchButtonsForType:@"modpack"];
        [self autoApplyProfileFiltersIfNeeded];
        if (self.modpackList.count == 0) {
            [self loadModpackList];
        }
    } else if (index == 6) {
        self.searchBar.placeholder = localize(@"i18n_str_170", nil);
        [self updateSourceSwitchButtonsForType:@"world"];
        if (self.worldList.count == 0) {
            [self loadWorldList];
        }
    }

    // 更新侧边栏各筛选项的当前值显示
    [self updateSidebarFilterValues];
}

#pragma mark - Source Switch

- (void)updateSourceSwitchButtonsForType:(NSString *)type {
    NSString *currentSource = [PLPreferences currentDownloadSourceForType:type];
    BOOL isModrinth = [currentSource isEqualToString:@"modrinth"];

    // 选中项文字白色，未选中项使用 labelColor（顶部 sourceSwitch，已弃用但保留同步）
    [self.modrinthSourceButton setTitleColor:isModrinth ? [UIColor whiteColor] : [UIColor labelColor] forState:UIControlStateNormal];
    [self.curseforgeSourceButton setTitleColor:isModrinth ? [UIColor labelColor] : [UIColor whiteColor] forState:UIControlStateNormal];

    // 滑块位置：通过激活 left/right 约束二选一切换，配合颜色动画
    self.sliderLeftPosConstraint.active = isModrinth;
    self.sliderRightPosConstraint.active = !isModrinth;
    UIColor *sliderColor = isModrinth ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];

    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.sourceSwitchSlider.backgroundColor = sliderColor;
        [self.sourceSwitchTrack layoutIfNeeded];
    } completion:nil];

    self.modrinthSourceButton.tag = [self tagForType:type];
    self.curseforgeSourceButton.tag = [self tagForType:type];

    // ===== 同步更新侧边栏的下载源选择器 =====
    [self.sidebarModrinthButton setTitleColor:isModrinth ? [UIColor whiteColor] : [UIColor labelColor] forState:UIControlStateNormal];
    [self.sidebarCurseforgeButton setTitleColor:isModrinth ? [UIColor labelColor] : [UIColor whiteColor] forState:UIControlStateNormal];

    self.sidebarSliderLeftConstraint.active = isModrinth;
    self.sidebarSliderRightConstraint.active = !isModrinth;
    UIColor *sidebarSliderColor = isModrinth ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];

    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.sidebarSourceSlider.backgroundColor = sidebarSliderColor;
        [self.sidebarSourceTrack layoutIfNeeded];
    } completion:nil];

    // 记录当前类型到侧边栏按钮的 tag，用于点击事件中获取类型
    self.sidebarModrinthButton.tag = [self tagForType:type];
    self.sidebarCurseforgeButton.tag = [self tagForType:type];
}

- (NSInteger)tagForType:(NSString *)type {
    if ([type isEqualToString:@"mod"]) return 1;
    if ([type isEqualToString:@"shader"]) return 2;
    if ([type isEqualToString:@"resourcepack"]) return 3;
    if ([type isEqualToString:@"datapack"]) return 4;
    if ([type isEqualToString:@"modpack"]) return 5;
    if ([type isEqualToString:@"world"]) return 6;
    return 0;
}

- (NSString *)typeForTag:(NSInteger)tag {
    switch (tag) {
        case 1: return @"mod";
        case 2: return @"shader";
        case 3: return @"resourcepack";
        case 4: return @"datapack";
        case 5: return @"modpack";
        case 6: return @"world";
        default: return @"mod";
    }
}

- (NSString *)currentTabType {
    NSInteger index = self.tabSegment.selectedSegmentIndex;
    switch (index) {
        case 1: return @"mod";
        case 2: return @"shader";
        case 3: return @"resourcepack";
        case 4: return @"datapack";
        case 5: return @"modpack";
        case 6: return @"world";
        default: return @"mod";
    }
}

- (void)modrinthSourceButtonClicked:(UIButton *)sender {
    NSString *type = [self typeForTag:sender.tag];
    NSString *currentSource = [PLPreferences currentDownloadSourceForType:type];
    if ([currentSource isEqualToString:@"modrinth"]) return;

    [PLPreferences setDownloadSource:@"modrinth" forType:type];
    [self updateSourceSwitchButtonsForType:type];
    [self reloadCurrentList];
}

- (void)curseforgeSourceButtonClicked:(UIButton *)sender {
    NSString *type = [self typeForTag:sender.tag];
    NSString *currentSource = [PLPreferences currentDownloadSourceForType:type];
    if ([currentSource isEqualToString:@"curseforge"]) return;

    // API Key 未配置时在内容区显示提示（替代弹窗）
    if (![CurseForgeAPI isAPIKeyConfigured]) {
        InlineMessageView *msgView = [InlineMessageView showInViewController:self
                                                                       title:localize(@"i18n_str_171", nil)
                                                                    message:localize(@"i18n_str_172", nil)
                                                                       type:InlineMessageTypeInfo];
        // 2 秒后自动跳转设置页
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [msgView dismiss];
            [self openCurseForgeAPIKeySettings];
        });
        return;
    }

    [PLPreferences setDownloadSource:@"curseforge" forType:type];
    [self updateSourceSwitchButtonsForType:type];
    [self reloadCurrentList];
}

#pragma mark - 侧边栏下载源点击事件

/// 侧边栏 Modrinth 源按钮点击
- (void)sidebarModrinthClicked:(UIButton *)sender {
    NSString *type = [self typeForTag:sender.tag];
    NSString *currentSource = [PLPreferences currentDownloadSourceForType:type];
    if ([currentSource isEqualToString:@"modrinth"]) return;

    [PLPreferences setDownloadSource:@"modrinth" forType:type];
    [self updateSourceSwitchButtonsForType:type];
    [self reloadCurrentList];
}

/// 侧边栏 CurseForge 源按钮点击
- (void)sidebarCurseforgeClicked:(UIButton *)sender {
    NSString *type = [self typeForTag:sender.tag];
    NSString *currentSource = [PLPreferences currentDownloadSourceForType:type];
    if ([currentSource isEqualToString:@"curseforge"]) return;

    // API Key 未配置时提示
    if (![CurseForgeAPI isAPIKeyConfigured]) {
        InlineMessageView *msgView = [InlineMessageView showInViewController:self
                                                                       title:localize(@"i18n_str_171", nil)
                                                                    message:localize(@"i18n_str_172", nil)
                                                                       type:InlineMessageTypeInfo];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [msgView dismiss];
            [self openCurseForgeAPIKeySettings];
        });
        return;
    }

    [PLPreferences setDownloadSource:@"curseforge" forType:type];
    [self updateSourceSwitchButtonsForType:type];
    [self reloadCurrentList];
}

#pragma mark - 侧边栏筛选按钮点击事件

/// 侧边栏游戏版本选择按钮点击
- (void)sidebarVersionButtonClicked:(UIButton *)sender {
    [self showGameVersionPicker];
}

/// 侧边栏模组加载器选择按钮点击
- (void)sidebarLoaderButtonClicked:(UIButton *)sender {
    [self showModLoaderPicker];
}

/// 侧边栏排序方式选择按钮点击
- (void)sidebarSortButtonClicked:(UIButton *)sender {
    [self showSortOptions];
}

/// 侧边栏重置筛选按钮点击
- (void)sidebarResetButtonClicked:(UIButton *)sender {
    [self resetFilters];
}

/// 更新侧边栏各筛选项的当前值显示
- (void)updateSidebarFilterValues {
    // 游戏版本
    if (self.currentGameVersion.length > 0) {
        self.sidebarVersionValueLabel.text = self.currentGameVersion;
    } else {
        self.sidebarVersionValueLabel.text = localize(@"i18n_str_2032", nil);
    }

    // 模组加载器
    if (self.currentModLoader.length > 0) {
        // 首字母大写显示
        NSString *loader = self.currentModLoader;
        NSString *capitalized = [[loader substringToIndex:1].uppercaseString stringByAppendingString:[loader substringFromIndex:1]];
        self.sidebarLoaderValueLabel.text = capitalized;
    } else {
        self.sidebarLoaderValueLabel.text = localize(@"resman.mods.filter.all", nil);
    }

    // 排序方式
    if (self.currentSortField.length > 0) {
        // 转换排序字段为中文显示
        NSDictionary *sortDisplayMap = @{
            @"relevance": localize(@"i18n_str_162", nil),
            @"downloads": localize(@"i18n_str_32", nil),
            @"follows": localize(@"i18n_str_173", nil),
            @"newest": localize(@"i18n_str_174", nil),
            @"updated": localize(@"i18n_str_2033", nil)
        };
        NSString *display = sortDisplayMap[self.currentSortField];
        self.sidebarSortValueLabel.text = display ?: self.currentSortField;
    } else {
        self.sidebarSortValueLabel.text = localize(@"i18n_str_162", nil);
    }
}

- (id)currentAPIForTabType:(NSString *)type {
    // Modrinth 不支持 project_type:world facet (其 project_type 仅 mod/modpack/shader/resourcepack/plugin)
    // 世界 tab 强制走 CurseForge (classID 17 = Worlds 真实存在)
    if ([type isEqualToString:@"world"]) {
        return [CurseForgeAPI sharedInstance];
    }
    NSString *source = [PLPreferences currentDownloadSourceForType:type];
    if ([source isEqualToString:@"curseforge"]) {
        return [CurseForgeAPI sharedInstance];
    }
    return [ModrinthAPI sharedInstance];
}

// 导航栏 API Key 入口：直接 push 配置页，不再走 alert 通知绕路
- (void)openCurseForgeAPIKeySettings {
    CurseForgeAPIKeyViewController *vc = [[CurseForgeAPIKeyViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Data Loading

- (void)loadVersionList {
    [self.loadingIndicator startAnimating];
    
    NSString *downloadSource = getPrefObject(@"general.download_source");
    NSString *versionManifestURL;
    
    if ([downloadSource isEqualToString:@"bmclapi"]) {
        versionManifestURL = @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json";
    } else {
        versionManifestURL = @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
    }
    
    NSURL *url = [NSURL URLWithString:versionManifestURL];
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.loadingIndicator stopAnimating];
            
            if (data && !error) {
                NSError *jsonError;
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
                if (json && !jsonError) {
                    strongSelf.versionList = json[@"versions"];
                    [strongSelf applyVersionFilter];
                } else {
                    strongSelf.emptyLabel.text = localize(@"i18n_str_176", nil);
                    strongSelf.emptyLabel.hidden = NO;
                }
            } else {
                strongSelf.emptyLabel.text = localize(@"i18n_str_177", nil);
                strongSelf.emptyLabel.hidden = NO;
            }
        });
    }];
    [task resume];
}

- (void)versionFilterChanged:(UISegmentedControl *)sender {
    [self applyVersionFilter];
}

- (void)applyVersionFilter {
    if (!self.versionList) return;
    
    NSInteger filterIndex = self.versionFilterSegment.selectedSegmentIndex;
    // 搜索关键词：忽略大小写与首尾空格，按版本号前缀匹配
    NSString *query = [self.versionSearchQuery stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *lowerQuery = query.lowercaseString;
    BOOL hasQuery = (lowerQuery.length > 0);
    
    NSMutableArray *filtered = [NSMutableArray array];
    
    for (NSDictionary *version in self.versionList) {
        NSString *type = version[@"type"];
        
        BOOL typeMatch = NO;
        if (filterIndex == 0) {
            typeMatch = YES;
        } else if (filterIndex == 1 && [type isEqualToString:@"release"]) {
            typeMatch = YES;
        } else if (filterIndex == 2 && [type isEqualToString:@"snapshot"]) {
            typeMatch = YES;
        } else if (filterIndex == 3 && ([type isEqualToString:@"old_alpha"] || [type isEqualToString:@"old_beta"])) {
            typeMatch = YES;
        }
        if (!typeMatch) continue;
        
        // 应用搜索关键词过滤（按 id 前缀匹配，例如 "1.2" 命中 "1.20.4"）
        if (hasQuery) {
            NSString *versionId = version[@"id"];
            if (![versionId isKindOfClass:[NSString class]] || versionId.length == 0) continue;
            if (![versionId.lowercaseString hasPrefix:lowerQuery]) continue;
        }
        
        [filtered addObject:version];
    }
    
    self.filteredVersions = filtered;
    [self.versionCollectionView reloadData];
    
    self.emptyLabel.hidden = (self.filteredVersions.count > 0);
    if (self.filteredVersions.count == 0) {
        self.emptyLabel.text = hasQuery ? localize(@"i18n_str_2034", nil) : localize(@"i18n_str_179", nil);
        self.emptyLabel.hidden = NO;
    } else {
        self.emptyLabel.hidden = YES;
    }
}

#pragma mark - Mod Search & Loading

- (void)refreshModList {
    self.modRequestGeneration += 1;
    self.isLoadingMods = NO;
    self.currentModOffset = 0;
    self.hasMoreMods = YES;
    [self.modList removeAllObjects];
    [self.modTableView reloadData];
    [self loadModList];
}

- (void)loadModList {
    if (self.isLoadingMods) return;
    self.isLoadingMods = YES;
    NSInteger generation = self.modRequestGeneration;
    NSInteger requestOffset = self.currentModOffset;
    
    if (self.currentModOffset == 0) {
        [self.loadingIndicator startAnimating];
    }
    
    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"limit"] = @30;
    filters[@"offset"] = @(requestOffset);
    
    if (self.modSearchQuery.length > 0) {
        filters[@"query"] = self.modSearchQuery;
    }
    if (self.currentGameVersion.length > 0) {
        filters[@"version"] = self.currentGameVersion;
    }
    if (self.currentModLoader.length > 0) {
        filters[@"loader"] = self.currentModLoader;
    }
    if (self.currentSortField.length > 0) {
        filters[@"sort"] = self.currentSortField;
    }
    
    __weak typeof(self) weakSelf = self;
    id api = [self currentAPIForTabType:@"mod"];
    [api searchModWithFilters:filters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (generation != strongSelf.modRequestGeneration) return;
            if (strongSelf.tabSegment.selectedSegmentIndex == 1) {
                [strongSelf.loadingIndicator stopAnimating];
            }
            [strongSelf.modTableView.refreshControl endRefreshing];
            strongSelf.isLoadingMods = NO;
            
            if (results) {
                if (requestOffset == 0) {
                    [strongSelf.modList removeAllObjects];
                }
                [strongSelf.modList addObjectsFromArray:results];
                strongSelf.hasMoreMods = (results.count >= 30);
                strongSelf.currentModOffset = requestOffset + results.count;
                
                [strongSelf.modTableView reloadData];
                if (strongSelf.tabSegment.selectedSegmentIndex == 1) {
                    strongSelf.emptyLabel.hidden = (strongSelf.modList.count > 0);
                    if (strongSelf.modList.count == 0) {
                        strongSelf.emptyLabel.text = localize(@"i18n_str_180", nil);
                        strongSelf.emptyLabel.hidden = NO;
                    }
                }
            } else if (error) {
                [strongSelf showError:error.localizedDescription];
            }
        });
    }];
}

- (void)searchMods:(NSString *)query {
    self.modSearchQuery = query;
    [self refreshModList];
}

#pragma mark - Shader Search & Loading

- (void)refreshShaderList {
    self.shaderRequestGeneration += 1;
    self.isLoadingShaders = NO;
    self.currentShaderOffset = 0;
    self.hasMoreShaders = YES;
    [self.shaderList removeAllObjects];
    [self.shaderTableView reloadData];
    [self loadShaderList];
}

- (void)loadShaderList {
    if (self.isLoadingShaders) return;
    self.isLoadingShaders = YES;
    NSInteger generation = self.shaderRequestGeneration;
    NSInteger requestOffset = self.currentShaderOffset;
    
    if (self.currentShaderOffset == 0) {
        [self.loadingIndicator startAnimating];
    }
    
    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"limit"] = @30;
    filters[@"offset"] = @(requestOffset);
    filters[@"projectType"] = @"shader";

    if (self.shaderSearchQuery.length > 0) {
        filters[@"query"] = self.shaderSearchQuery;
    }
    if (self.currentGameVersion.length > 0) {
        filters[@"version"] = self.currentGameVersion;
    }

    __weak typeof(self) weakSelf = self;
    id api = [self currentAPIForTabType:@"shader"];
    [api searchModWithFilters:filters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (generation != strongSelf.shaderRequestGeneration) return;
            if (strongSelf.tabSegment.selectedSegmentIndex == 2) {
                [strongSelf.loadingIndicator stopAnimating];
            }
            [strongSelf.shaderTableView.refreshControl endRefreshing];
            strongSelf.isLoadingShaders = NO;
            
            if (results) {
                if (requestOffset == 0) {
                    [strongSelf.shaderList removeAllObjects];
                }
                [strongSelf.shaderList addObjectsFromArray:results];
                strongSelf.hasMoreShaders = (results.count >= 30);
                strongSelf.currentShaderOffset = requestOffset + results.count;
                
                [strongSelf.shaderTableView reloadData];
                if (strongSelf.tabSegment.selectedSegmentIndex == 2) {
                    strongSelf.emptyLabel.hidden = (strongSelf.shaderList.count > 0);
                    if (strongSelf.shaderList.count == 0) {
                        strongSelf.emptyLabel.text = localize(@"i18n_str_181", nil);
                        strongSelf.emptyLabel.hidden = NO;
                    }
                }
            } else if (error) {
                [strongSelf showError:error.localizedDescription];
            }
        });
    }];
}

- (void)searchShaders:(NSString *)query {
    self.shaderSearchQuery = query;
    [self refreshShaderList];
}

#pragma mark - Modpack Search & Loading

- (void)refreshModpackList {
    self.currentModpackOffset = 0;
    self.hasMoreModpacks = YES;
    [self.modpackList removeAllObjects];
    [self loadModpackList];
}

- (void)loadModpackList {
    if (self.isLoadingModpacks) return;
    self.isLoadingModpacks = YES;
    
    if (self.currentModpackOffset == 0) {
        [self.loadingIndicator startAnimating];
    }
    
    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"isModpack"] = @YES;
    filters[@"projectType"] = @"modpack";
    filters[@"limit"] = @30;
    filters[@"offset"] = @(self.currentModpackOffset);
    if (self.modpackSearchQuery.length > 0) {
        filters[@"query"] = self.modpackSearchQuery;
    }
    if (self.currentGameVersion.length > 0) {
        filters[@"version"] = self.currentGameVersion;
    }
    
    __weak typeof(self) weakSelf = self;
    id api = [self currentAPIForTabType:@"modpack"];
    [api searchModWithFilters:filters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.loadingIndicator stopAnimating];
            [strongSelf.modpackTableView.refreshControl endRefreshing];
            strongSelf.isLoadingModpacks = NO;
            
            if (results) {
                if (strongSelf.currentModpackOffset == 0) {
                    [strongSelf.modpackList removeAllObjects];
                }
                [strongSelf.modpackList addObjectsFromArray:results];
                strongSelf.hasMoreModpacks = (results.count >= 30);
                strongSelf.currentModpackOffset += results.count;
                
                [strongSelf.modpackTableView reloadData];
                strongSelf.emptyLabel.hidden = (strongSelf.modpackList.count > 0);
                if (strongSelf.modpackList.count == 0) {
                    strongSelf.emptyLabel.text = localize(@"i18n_str_182", nil);
                    strongSelf.emptyLabel.hidden = NO;
                }
            } else if (error) {
                [strongSelf showError:error.localizedDescription];
            }
        });
    }];
}

- (void)searchModpacks:(NSString *)query {
    self.modpackSearchQuery = query;
    self.currentModpackOffset = 0;
    self.hasMoreModpacks = YES;
    [self.modpackList removeAllObjects];
    [self.modpackTableView reloadData];
    [self loadModpackList];
}

#pragma mark - Resourcepack Search & Loading

- (void)refreshResourcepackList {
    self.currentResourcepackOffset = 0;
    self.hasMoreResourcepacks = YES;
    [self.resourcepackList removeAllObjects];
    [self loadResourcePackList];
}

- (void)loadResourcePackList {
    if (self.isLoadingResourcepacks) return;
    self.isLoadingResourcepacks = YES;

    if (self.currentResourcepackOffset == 0) {
        [self.loadingIndicator startAnimating];
    }

    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"limit"] = @30;
    filters[@"offset"] = @(self.currentResourcepackOffset);
    filters[@"projectType"] = @"resourcepack";

    if (self.resourcepackSearchQuery.length > 0) {
        filters[@"query"] = self.resourcepackSearchQuery;
    }
    if (self.currentGameVersion.length > 0) {
        filters[@"version"] = self.currentGameVersion;
    }

    __weak typeof(self) weakSelf = self;
    id api = [self currentAPIForTabType:@"resourcepack"];
    [api searchModWithFilters:filters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.loadingIndicator stopAnimating];
            [strongSelf.resourcepackTableView.refreshControl endRefreshing];
            strongSelf.isLoadingResourcepacks = NO;

            if (results) {
                if (strongSelf.currentResourcepackOffset == 0) {
                    [strongSelf.resourcepackList removeAllObjects];
                }
                [strongSelf.resourcepackList addObjectsFromArray:results];
                strongSelf.hasMoreResourcepacks = (results.count >= 30);
                strongSelf.currentResourcepackOffset += results.count;

                [strongSelf.resourcepackTableView reloadData];
                strongSelf.emptyLabel.hidden = (strongSelf.resourcepackList.count > 0);
                if (strongSelf.resourcepackList.count == 0) {
                    strongSelf.emptyLabel.text = localize(@"i18n_str_183", nil);
                    strongSelf.emptyLabel.hidden = NO;
                }
            } else if (error) {
                [strongSelf showError:error.localizedDescription];
            }
        });
    }];
}

- (void)searchResourcepacks:(NSString *)query {
    self.resourcepackSearchQuery = query;
    self.currentResourcepackOffset = 0;
    self.hasMoreResourcepacks = YES;
    [self.resourcepackList removeAllObjects];
    [self.resourcepackTableView reloadData];
    [self loadResourcePackList];
}

#pragma mark - Datapack Search & Loading

- (void)refreshDatapackList {
    self.currentDatapackOffset = 0;
    self.hasMoreDatapacks = YES;
    [self.datapackList removeAllObjects];
    [self loadDataPackList];
}

- (void)loadDataPackList {
    if (self.isLoadingDatapacks) return;
    self.isLoadingDatapacks = YES;

    if (self.currentDatapackOffset == 0) {
        [self.loadingIndicator startAnimating];
    }

    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"limit"] = @30;
    filters[@"offset"] = @(self.currentDatapackOffset);
    filters[@"projectType"] = @"datapack";

    if (self.datapackSearchQuery.length > 0) {
        filters[@"query"] = self.datapackSearchQuery;
    }
    if (self.currentGameVersion.length > 0) {
        filters[@"version"] = self.currentGameVersion;
    }

    __weak typeof(self) weakSelf = self;
    id api = [self currentAPIForTabType:@"datapack"];
    [api searchModWithFilters:filters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.loadingIndicator stopAnimating];
            [strongSelf.datapackTableView.refreshControl endRefreshing];
            strongSelf.isLoadingDatapacks = NO;

            if (results) {
                if (strongSelf.currentDatapackOffset == 0) {
                    [strongSelf.datapackList removeAllObjects];
                }
                [strongSelf.datapackList addObjectsFromArray:results];
                strongSelf.hasMoreDatapacks = (results.count >= 30);
                strongSelf.currentDatapackOffset += results.count;

                [strongSelf.datapackTableView reloadData];
                strongSelf.emptyLabel.hidden = (strongSelf.datapackList.count > 0);
                if (strongSelf.datapackList.count == 0) {
                    strongSelf.emptyLabel.text = localize(@"i18n_str_184", nil);
                    strongSelf.emptyLabel.hidden = NO;
                }
            } else if (error) {
                [strongSelf showError:error.localizedDescription];
            }
        });
    }];
}

- (void)searchDatapacks:(NSString *)query {
    self.datapackSearchQuery = query;
    self.currentDatapackOffset = 0;
    self.hasMoreDatapacks = YES;
    [self.datapackList removeAllObjects];
    [self.datapackTableView reloadData];
    [self loadDataPackList];
}

#pragma mark - World 加载

- (void)refreshWorldList {
    self.currentWorldOffset = 0;
    self.hasMoreWorlds = YES;
    [self.worldList removeAllObjects];
    [self loadWorldList];
}

- (void)loadWorldList {
    if (self.isLoadingWorlds) return;
    self.isLoadingWorlds = YES;

    if (self.currentWorldOffset == 0) {
        [self.loadingIndicator startAnimating];
    }

    // 世界 tab 强制 CurseForge，但需 API Key（与实际请求一致的三层 fallback 判断）；缺失时给出明确入口提示
    if (![CurseForgeAPI isAPIKeyConfigured]) {
        [self.loadingIndicator stopAnimating];
        [self.worldTableView.refreshControl endRefreshing];
        self.isLoadingWorlds = NO;
        [self.worldList removeAllObjects];
        [self.worldTableView reloadData];
        self.emptyLabel.text = localize(@"i18n_str_185", nil);
        self.emptyLabel.hidden = NO;
        return;
    }

    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"limit"] = @30;
    filters[@"offset"] = @(self.currentWorldOffset);
    filters[@"projectType"] = @"world";

    if (self.worldSearchQuery.length > 0) {
        filters[@"query"] = self.worldSearchQuery;
    }
    if (self.currentGameVersion.length > 0) {
        filters[@"version"] = self.currentGameVersion;
    }

    __weak typeof(self) weakSelf = self;
    id api = [self currentAPIForTabType:@"world"];
    [api searchModWithFilters:filters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.loadingIndicator stopAnimating];
            [strongSelf.worldTableView.refreshControl endRefreshing];
            strongSelf.isLoadingWorlds = NO;

            if (results) {
                if (strongSelf.currentWorldOffset == 0) {
                    [strongSelf.worldList removeAllObjects];
                }
                [strongSelf.worldList addObjectsFromArray:results];
                strongSelf.hasMoreWorlds = (results.count >= 30);
                strongSelf.currentWorldOffset += results.count;

                [strongSelf.worldTableView reloadData];
                strongSelf.emptyLabel.hidden = (strongSelf.worldList.count > 0);
                if (strongSelf.worldList.count == 0) {
                    strongSelf.emptyLabel.text = localize(@"i18n_str_186", nil);
                    strongSelf.emptyLabel.hidden = NO;
                }
            } else if (error) {
                [strongSelf showError:error.localizedDescription];
            }
        });
    }];
}

- (void)searchWorlds:(NSString *)query {
    self.worldSearchQuery = query;
    self.currentWorldOffset = 0;
    self.hasMoreWorlds = YES;
    [self.worldList removeAllObjects];
    [self.worldTableView reloadData];
    [self loadWorldList];
}

#pragma mark - Filter Options

- (void)showFilterOptions {
    NSInteger tabIndex = self.tabSegment.selectedSegmentIndex;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_187", nil)
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    if (tabIndex == 1 || tabIndex == 2 || tabIndex == 3 || tabIndex == 4) {
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_188", nil)
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self showGameVersionPicker];
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_161", nil)
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self showSortOptions];
        }]];

        if (tabIndex == 1) {
            [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_160", nil)
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction * _Nonnull action) {
                [self showModLoaderPicker];
            }]];
        }

        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_163", nil)
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self resetFilters];
        }]];
    } else if (tabIndex == 5) {
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_189", nil)
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self openImportModpackView];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_188", nil)
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self showGameVersionPicker];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_163", nil)
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.currentGameVersion = nil;
            [self refreshModpackList];
        }]];
    } else if (tabIndex == 6) {
        // 世界 tab: 强制 CurseForge，提供 API Key 入口与版本筛选
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_190", nil)
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self openCurseForgeAPIKeySettings];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_188", nil)
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self showGameVersionPicker];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_163", nil)
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.currentGameVersion = nil;
            [self refreshWorldList];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.filterButton;
        alert.popoverPresentationController.sourceRect = self.filterButton.bounds;
    }
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showGameVersionPicker {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_188", nil)
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    // 动态构建版本列表：优先使用已加载的 Mojang version_manifest 中的 release 版本，
    // 这样能自动跟随 MC 版本更新（不再使用硬编码列表）。
    // 同时把当前 profile 的 MC 版本置顶（如果有）方便快速选择。
    NSMutableArray<NSString *> *versions = [NSMutableArray arrayWithObject:localize(@"i18n_str_2032", nil)];

    // 当前 profile 的 MC 版本（若有）放第二位，便于快速选择
    NSString *profileMcVersion = [self currentProfileMinecraftVersion];
    if (profileMcVersion.length > 0 && ![versions containsObject:profileMcVersion]) {
        [versions addObject:profileMcVersion];
    }

    // 从 Mojang version_manifest 提取 release 版本
    if (self.versionList && [self.versionList isKindOfClass:[NSArray class]]) {
        for (NSDictionary *version in self.versionList) {
            NSString *type = version[@"type"];
            if (![type isEqualToString:@"release"]) continue;
            NSString *versionId = version[@"id"];
            if (![versionId isKindOfClass:[NSString class]] || versionId.length == 0) continue;
            // 跳过过于旧的版本（1.8 之前的版本 mod 支持极少）
            if ([versionId hasPrefix:@"1."] == NO) continue;
            // 跳过已经在列表中的（避免 profileMcVersion 重复）
            if ([versions containsObject:versionId]) continue;
            [versions addObject:versionId];
        }
    }

    // 若 versionList 还未加载或为空，使用基础 fallback（保证 picker 至少能弹出）
    if (versions.count <= 1) {
        [versions addObjectsFromArray:@[@"1.21", @"1.20.1", @"1.19.2", @"1.18.2", @"1.16.5"]];
    }

    // 限制列表长度避免 alert 过长（保留最近 30 个版本 + 全部 + profile 版本）
    if (versions.count > 32) {
        NSArray *tail = [versions subarrayWithRange:NSMakeRange(0, 32)];
        versions = [NSMutableArray arrayWithArray:tail];
    }

    for (NSString *version in versions) {
        [alert addAction:[UIAlertAction actionWithTitle:version
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            if ([version isEqualToString:@"全部版本"]) {
                self.currentGameVersion = nil;
            } else {
                self.currentGameVersion = version;
            }
            // 用户手动选择后标记，不再自动覆盖
            self.hasUserTouchedFilters = YES;
            [self updateSidebarFilterValues];
            [self reloadCurrentList];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    // iPad popover sourceView 优先使用侧边栏按钮（filterButton 在非版本 tab 隐藏）
    UIView *sourceView = self.sidebarVersionButton.hidden ? self.filterButton : self.sidebarVersionButton;
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = sourceView;
        alert.popoverPresentationController.sourceRect = sourceView.bounds;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

/// 解析当前 profile 的 Minecraft 版本（用于模组下载版本预选）
/// 复用 ModpackExportService.parseVersionId: 从 lastVersionId 反解
- (NSString *)effectiveTargetProfileName {
    return [PLProfiles effectiveProfileNameForPreferredName:self.targetProfileName];
}

- (NSDictionary *)effectiveTargetProfile {
    NSString *profileName = [self effectiveTargetProfileName];
    return profileName.length > 0 ? PLProfiles.current.profiles[profileName] : nil;
}

- (NSString *)currentProfileMinecraftVersion {
    NSDictionary *profile = [self effectiveTargetProfile];
    NSString *lastVersionId = profile[@"lastVersionId"];
    if (lastVersionId.length == 0) return nil;
    NSDictionary *parsed = [ModpackExportService parseVersionId:lastVersionId];
    NSString *mcVersion = parsed[@"minecraft"];
    return mcVersion;
}

/// 解析当前 profile 的模组加载器（fabric/forge/neoforge/quilt）
/// 复用 ModpackExportService.parseVersionId: 从 lastVersionId 反解
- (NSString *)currentProfileLoader {
    NSDictionary *profile = [self effectiveTargetProfile];
    NSString *lastVersionId = profile[@"lastVersionId"];
    if (lastVersionId.length == 0) return nil;
    NSDictionary *parsed = [ModpackExportService parseVersionId:lastVersionId];
    NSString *loader = parsed[@"loader"];
    return loader;
}

/// FCL 风格：首次进入模组/光影/资源包等 tab 时自动应用当前 profile 的版本和加载器筛选
/// 让搜索结果自动匹配当前游戏环境（如 neoforge + 1.21.1）
/// 用户手动改过筛选后不再自动覆盖（通过 hasUserTouchedFilters 标记）
- (void)autoApplyProfileFiltersIfNeeded {
    if (self.hasUserTouchedFilters) return;

    NSString *profileMcVersion = [self currentProfileMinecraftVersion];
    NSString *profileLoader = [self currentProfileLoader];

    BOOL changed = NO;
    // 仅当当前未设置版本时才自动应用（用户主动选过就保留）
    if (profileMcVersion.length > 0 && ![self.currentGameVersion isEqualToString:profileMcVersion]) {
        self.currentGameVersion = profileMcVersion;
        changed = YES;
    }
    // 加载器仅对模组 tab 自动应用（其他 tab 如光影/资源包不一定有加载器概念）
    // 但 Modrinth 的 facets 中 categories 对所有 project_type 都生效，所以统一应用
    if (profileLoader.length > 0 && ![self.currentModLoader isEqualToString:profileLoader]) {
        self.currentModLoader = profileLoader;
        changed = YES;
    }

    if (changed) {
        [self updateSidebarFilterValues];
    }
}

- (void)showSortOptions {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_161", nil)
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSDictionary *sortOptions = @{
        localize(@"i18n_str_2035", nil): @"follows",
        localize(@"i18n_str_2061", nil): @"downloads",
        localize(@"i18n_str_2033", nil): @"updated",
        localize(@"i18n_str_2064", nil): @"newest",
        localize(@"i18n_str_162", nil): @"relevance"
    };

    for (NSString *title in sortOptions) {
        [alert addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.currentSortField = sortOptions[title];
            [self updateSidebarFilterValues];
            [self reloadCurrentList];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    UIView *sourceView = self.sidebarSortButton.hidden ? self.filterButton : self.sidebarSortButton;
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = sourceView;
        alert.popoverPresentationController.sourceRect = sourceView.bounds;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showModLoaderPicker {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_160", nil)
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray *loaderNames = @[localize(@"resman.mods.filter.all", nil), @"Fabric", @"Forge", @"Quilt", @"NeoForge"];
    NSArray *loaderValues = @[[NSNull null], @"fabric", @"forge", @"quilt", @"neoforge"];

    for (NSInteger i = 0; i < loaderNames.count; i++) {
        NSString *name = loaderNames[i];
        id value = loaderValues[i];

        [alert addAction:[UIAlertAction actionWithTitle:name
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.currentModLoader = (value == [NSNull null]) ? nil : value;
            // 用户手动选择后标记，不再自动覆盖
            self.hasUserTouchedFilters = YES;
            [self updateSidebarFilterValues];
            [self reloadCurrentList];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    UIView *sourceView = self.sidebarLoaderButton.hidden ? self.filterButton : self.sidebarLoaderButton;
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = sourceView;
        alert.popoverPresentationController.sourceRect = sourceView.bounds;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)resetFilters {
    self.currentGameVersion = nil;
    self.currentModLoader = nil;
    self.currentSortField = @"follows";
    self.modSearchQuery = nil;
    self.shaderSearchQuery = nil;
    self.resourcepackSearchQuery = nil;
    self.datapackSearchQuery = nil;
    self.searchBar.text = nil;
    [self updateSidebarFilterValues];
    [self reloadCurrentList];
}

- (void)reloadCurrentList {
    NSInteger tabIndex = self.tabSegment.selectedSegmentIndex;
    // 切换 API 源时对当前列表做淡出→加载→淡入，避免瞬间清空的生硬感
    UITableView *targetTable = nil;
    if (tabIndex == 1) {
        targetTable = self.modTableView;
    } else if (tabIndex == 2) {
        targetTable = self.shaderTableView;
    } else if (tabIndex == 3) {
        targetTable = self.resourcepackTableView;
        self.currentResourcepackOffset = 0;
        [self.resourcepackList removeAllObjects];
    } else if (tabIndex == 4) {
        targetTable = self.datapackTableView;
        self.currentDatapackOffset = 0;
        [self.datapackList removeAllObjects];
    } else if (tabIndex == 5) {
        targetTable = self.modpackTableView;
        self.currentModpackOffset = 0;
        [self.modpackList removeAllObjects];
    } else if (tabIndex == 6) {
        targetTable = self.worldTableView;
        self.currentWorldOffset = 0;
        [self.worldList removeAllObjects];
    }

    [UIView animateWithDuration:0.15 animations:^{
        targetTable.alpha = 0;
    } completion:^(BOOL finished) {
        switch (tabIndex) {
            case 1: [self refreshModList]; break;
            case 2: [self refreshShaderList]; break;
            case 3: [self loadResourcePackList]; break;
            case 4: [self loadDataPackList]; break;
            case 5: [self loadModpackList]; break;
            case 6: [self loadWorldList]; break;
        }
        [UIView animateWithDuration:0.2 animations:^{
            targetTable.alpha = 1;
        }];
    }];
}

- (void)showError:(NSString *)message {
    // 在内容区显示错误，替代弹窗
    [InlineMessageView showInViewController:self
                                       title:localize(@"i18n_str_42", nil)
                                    message:message
                                       type:InlineMessageTypeError];
}

#pragma mark - UISearchBarDelegate

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];

    NSInteger tabIndex = self.tabSegment.selectedSegmentIndex;
    if (tabIndex == 0) {
        // 版本 tab：搜索过滤已在 textDidChange 实时执行，此处仅收起键盘
        // 不再重复调用 applyVersionFilter
    } else if (tabIndex == 1) {
        [self searchMods:searchBar.text];
    } else if (tabIndex == 2) {
        [self searchShaders:searchBar.text];
    } else if (tabIndex == 3) {
        [self searchResourcepacks:searchBar.text];
    } else if (tabIndex == 4) {
        [self searchDatapacks:searchBar.text];
    } else if (tabIndex == 5) {
        [self searchModpacks:searchBar.text];
    } else if (tabIndex == 6) {
        [self searchWorlds:searchBar.text];
    }
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = nil;
    self.modSearchQuery = nil;
    self.shaderSearchQuery = nil;
    self.modpackSearchQuery = nil;
    self.resourcepackSearchQuery = nil;
    self.datapackSearchQuery = nil;
    self.worldSearchQuery = nil;
    self.versionSearchQuery = nil;
    [searchBar resignFirstResponder];
    [self reloadCurrentList];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    NSInteger tabIndex = self.tabSegment.selectedSegmentIndex;
    if (tabIndex == 0) {
        // 版本 tab：实时按版本号前缀过滤（无需点击搜索按钮）
        self.versionSearchQuery = searchText;
        [self applyVersionFilter];
    }
}

#pragma mark - UICollectionView DataSource

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.filteredVersions.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    VersionCardCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"VersionCard" forIndexPath:indexPath];

    NSDictionary *version = self.filteredVersions[indexPath.row];
    NSString *versionId = version[@"id"];
    NSString *releaseTime = version[@"releaseTime"];
    NSString *versionType = version[@"type"];

    NSString *formattedDate = [self formatDate:releaseTime];
    [cell configureWithVersionId:versionId date:formattedDate type:versionType];

    // FCL 风格：标记已安装的版本（遍历 PLProfiles，匹配 lastVersionId）
    [cell setInstalled:[self isVersionInstalled:versionId]];

    return cell;
}

/// 检查指定 versionId 是否已安装在本地（任一 profile 的 lastVersionId 匹配即视为已安装）
- (BOOL)isVersionInstalled:(NSString *)versionId {
    if (!versionId.length) return NO;
    NSDictionary *profiles = PLProfiles.current.profiles;
    for (NSString *name in profiles.allKeys) {
        NSDictionary *profile = profiles[name];
        NSString *lastVersionId = profile[@"lastVersionId"];
        if ([lastVersionId isKindOfClass:[NSString class]] && [lastVersionId isEqualToString:versionId]) {
            return YES;
        }
    }
    return NO;
}

- (NSString *)formatDate:(NSString *)dateString {
    if (dateString.length >= 10) {
        return [dateString substringToIndex:10];
    }
    return dateString;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *version = self.filteredVersions[indexPath.row];
    [self showLoaderSelectionForVersion:version];
}

#pragma mark - Loader Selection (push 到中间内容区)

- (void)showLoaderSelectionForVersion:(NSDictionary *)version {
    ModLoaderInstallViewController *loaderVC = [[ModLoaderInstallViewController alloc] init];
    loaderVC.gameVersion = version[@"id"];

    __weak typeof(self) weakSelf = self;
    loaderVC.completion = ^(NSString *loaderType, BOOL installFabricAPI, BOOL installOptiFine, NSString *loaderVersion) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // 修复"前一个页面没有及时消失"：
        // 之前用 popViewControllerAnimated:YES + dispatch_async(main_queue) 立即执行 proceedWithVersion:，
        // 但 pop 动画（约 0.35s）还未完成时 proceedWithVersion: 可能 push 新 VC（如 InstallerProgressViewController），
        // 导致导航控制器在 pop 动画期间收到 push，状态冲突，前一个页面（模组安装器）卡在屏幕上不消失。
        // 修复：用 CATransaction 包裹 pop，在 pop 动画完成的回调中再执行 proceedWithVersion:，
        //       确保导航栈状态一致。
        [CATransaction begin];
        [CATransaction setCompletionBlock:^{
            __strong typeof(weakSelf) ss = weakSelf;
            if (!ss) return;
            [ss proceedWithVersion:version
                        loaderType:loaderType
                  installFabricAPI:installFabricAPI
                   installOptiFine:installOptiFine
                      loaderVersion:loaderVersion];
        }];
        [strongSelf.navigationController popViewControllerAnimated:YES];
        [CATransaction commit];
    };

    loaderVC.cancelled = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf.navigationController popViewControllerAnimated:YES];
        }
    };

    // 已在 DownloadVC 的导航栈中，直接 push，不再用 FormSheet 弹窗
    [self.navigationController pushViewController:loaderVC animated:YES];
}

#pragma mark - Installation

- (void)proceedWithVersion:(NSDictionary *)version loaderType:(NSString *)loaderType installFabricAPI:(BOOL)installFabricAPI installOptiFine:(BOOL)installOptiFine loaderVersion:(NSString *)loaderVersion {
    NSString *versionId = version[@"id"];

    if ([loaderType isEqualToString:@"vanilla"]) {
        // 原版也经过 ensureVanillaInstalled，确保 version.json 正确下载和 BMCLAPI 替换
        // 修复：原先直接调用 downloadVanillaVersion: 不经过 ensureVanillaInstalled:，
        //   在 BMCLAPI 模式下 version.json 直连 piston-meta.mojang.com 会国内超时，
        //   导致一直转圈不下载。ensureVanillaInstalled: 内部会调用 ensureVanillaVersionJSONExists:，
        //   后者已正确将 piston-meta.mojang.com 替换为 bmclapi2.bangbang93.com。
        // 注意：ensureVanillaInstalled: 在 JSON 已存在时会直接跳过，避免重复下载；
        //   downloadVanillaVersion: 内部也会通过 createDownloadTask: 的 SHA1 校验跳过已下载文件。
        //
        // redesign-download-ui Phase 4：进度展示统一由 MinecraftResourceDownloadTask
        // 内部注册的下载任务（autoPresentDetail=YES）自动弹出统一进度页，
        // 此处不再创建底部悬浮进度卡片。
        __weak typeof(self) weakSelf = self;
        [self ensureVanillaInstalled:version completion:^(BOOL success) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (success) {
                [strongSelf downloadVanillaVersion:version];
            } else {
                [strongSelf showError:[NSString stringWithFormat:localize(@"i18n_str_194", nil), versionId]];
            }
        }];
        return;
    }

    // 用户决策（参考 ZL2 的保守策略）：安装模组加载器前检测对应原版是否已安装，
    // 未安装时不再自动代装原版，而是提醒用户先手动安装原版。
    // 原因：原版自动预装 + 加载器安装的复合流程中，若原版安装失败/被中断，
    // 加载器版本虽写入但继承的原版缺失，实例管理会出现"找不到刚安装的版本"等问题；
    // 提醒方式让用户明确先完成原版安装，流程更可控。
    // 注：加载器版本 JSON 均含 "inheritsFrom" 字段，启动时 Java 端会读取
    // versions/{inheritsFrom}/{inheritsFrom}.json 合并，原版缺失会导致启动崩溃。
    if (![self isVanillaVersionInstalled:versionId]) {
        NSDictionary *loaderDisplayNames = @{
            @"fabric": @"Fabric",
            @"forge": @"Forge",
            @"neoforge": @"NeoForge",
            @"quilt": @"Quilt",
            @"optifine": @"OptiFine"
        };
        NSString *loaderDisplayName = loaderDisplayNames[loaderType] ?: loaderType;
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:localize(@"i18n_str_195", nil)
                             message:[NSString stringWithFormat:
                                      localize(@"i18n_str_196", nil),
                                      loaderDisplayName, versionId]
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_197", nil)
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if ([loaderType isEqualToString:@"fabric"]) {
            [self installFabric:versionId loaderVersion:loaderVersion installAPI:installFabricAPI];
        } else if ([loaderType isEqualToString:@"forge"]) {
            [self installForge:versionId installOptiFine:installOptiFine loaderVersion:loaderVersion];
        } else if ([loaderType isEqualToString:@"neoforge"]) {
            [self installNeoForge:versionId loaderVersion:loaderVersion];
        } else if ([loaderType isEqualToString:@"quilt"]) {
            [self installQuilt:versionId loaderVersion:loaderVersion];
        } else if ([loaderType isEqualToString:@"optifine"]) {
            [self installOptiFineAsPatch:versionId loaderVersion:loaderVersion];
        } else {
            [self showError:[NSString stringWithFormat:localize(@"i18n_str_198", nil), loaderType]];
        }
    });
}

/// 检测指定原版版本是否已安装（versions/{versionId}/{versionId}.json 存在即视为已安装，
/// 与版本列表扫描 versions/ 目录的判定标准一致）。
- (BOOL)isVanillaVersionInstalled:(NSString *)versionId {
    if (versionId.length == 0) return NO;
    NSString *gameDir = @(getenv("POJAV_GAME_DIR"));
    if (gameDir.length == 0) {
        gameDir = @(getenv("POJAV_HOME"));
    }
    if (gameDir.length == 0) return NO;
    NSString *versionJsonPath = [gameDir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"versions/%@/%@.json", versionId, versionId]];
    return [NSFileManager.defaultManager fileExistsAtPath:versionJsonPath];
}

/// 参照 FCL：确保原版版本的 version JSON 已存在。
/// 若 versions/{versionId}/{versionId}.json 不存在，从 Mojang/BMCLAPI 版本清单下载。
/// 仅下载 version JSON（不下载 client.jar/assets/libraries，这些在游戏首次启动时由 Java 端自动下载）。
/// Forge/NeoForge 直装器内部也有相同逻辑（ensureParentVersionExists），但 Fabric/Quilt/OptiFine 没有，
/// 因此在 proceedWithVersion 中统一前置调用。
- (void)ensureVanillaVersionJSONExists:(NSString *)versionId completion:(void (^)(BOOL success))completion {
    // 修复：必须使用 POJAV_GAME_DIR（与 ensureVanillaInstalled: 和 MinecraftResourceDownloadTask 一致），
    // 而非 POJAV_HOME。POJAV_GAME_DIR 是 Minecraft 实际读取 versions/ 的目录。
    // 若用 POJAV_HOME，version JSON 会存到错误位置，导致 MinecraftResourceDownloadTask
    // 找不到 JSON 而崩溃，且游戏启动时 Java 端 Tools.getVersionInfo() 也会 FileNotFoundException。
    NSString *gameDir = @(getenv("POJAV_GAME_DIR"));
    if (gameDir.length == 0) {
        gameDir = @(getenv("POJAV_HOME"));
    }
    NSString *versionDir = [gameDir stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"versions/%@", versionId]];
    NSString *versionJsonPath = [versionDir stringByAppendingPathComponent:
                                 [NSString stringWithFormat:@"%@.json", versionId]];

    // 1. 版本 JSON 已存在，无需下载
    if ([NSFileManager.defaultManager fileExistsAtPath:versionJsonPath]) {
        if (completion) completion(YES);
        return;
    }

    NSLog(@"[DownloadVC] Vanilla version JSON missing, downloading: %@", versionId);

    // 2. 在后台线程拉取 Mojang 版本清单并下载 version JSON
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *downloadSource = getPrefObject(@"general.download_source") ?: @"official";
        BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];
        NSString *manifestURL = useBMCLAPI
            ? @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json"
            : @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";

        NSURL *url = [NSURL URLWithString:manifestURL];
        if (!url) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        NSMutableURLRequest *manifestRequest = [NSMutableURLRequest requestWithURL:url];
        manifestRequest.timeoutInterval = 30.0;
        manifestRequest.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        [manifestRequest setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];

        // 使用 NSURLSession 替代已废弃的 NSURLConnection sendSynchronousRequest
        dispatch_semaphore_t manifestSem = dispatch_semaphore_create(0);
        __block NSData *manifestData = nil;
        NSURLSessionDataTask *manifestTask = [[NSURLSession sharedSession] dataTaskWithRequest:manifestRequest
                                                                              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            manifestData = data;
            dispatch_semaphore_signal(manifestSem);
        }];
        [manifestTask resume];
        dispatch_semaphore_wait(manifestSem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));

        if (!manifestData) {
            NSLog(@"[DownloadVC] Failed to download version manifest");
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil];
        NSArray *versions = [manifest isKindOfClass:[NSDictionary class]] ? manifest[@"versions"] : nil;
        if (![versions isKindOfClass:[NSArray class]]) {
            NSLog(@"[DownloadVC] Invalid version manifest format");
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        // 3. 查找匹配的版本条目，获取 version JSON URL
        NSString *versionJSONURL = nil;
        for (NSDictionary *v in versions) {
            if ([v isKindOfClass:[NSDictionary class]] && [v[@"id"] isEqualToString:versionId]) {
                versionJSONURL = [v[@"url"] isKindOfClass:[NSString class]] ? v[@"url"] : nil;
                break;
            }
        }
        if (!versionJSONURL) {
            NSLog(@"[DownloadVC] Version %@ not found in manifest", versionId);
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        // BMCLAPI 镜像：替换 Mojang 官方域名
        if (useBMCLAPI) {
            versionJSONURL = [versionJSONURL stringByReplacingOccurrencesOfString:@"piston-meta.mojang.com"
                                                                        withString:@"bmclapi2.bangbang93.com"];
            versionJSONURL = [versionJSONURL stringByReplacingOccurrencesOfString:@"launchermeta.mojang.com"
                                                                        withString:@"bmclapi2.bangbang93.com"];
        }

        // 4. 下载 version JSON（使用 NSURLSession 替代已废弃的 NSURLConnection）
        NSURL *jsonURL = [NSURL URLWithString:versionJSONURL];
        if (!jsonURL) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        NSMutableURLRequest *jsonRequest = [NSMutableURLRequest requestWithURL:jsonURL];
        jsonRequest.timeoutInterval = 30.0;
        jsonRequest.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        [jsonRequest setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];

        // 使用 NSURLSession dataTaskWithCompletionHandler 替代已废弃的 NSURLConnection sendSynchronousRequest
        // 已在外层 dispatch_async 到后台队列，此处用信号量等待结果
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block NSData *jsonData = nil;
        NSURLSessionDataTask *jsonTask = [[NSURLSession sharedSession] dataTaskWithRequest:jsonRequest
                                                                          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            jsonData = data;
            dispatch_semaphore_signal(sem);
        }];
        [jsonTask resume];
        // 等待最多 30 秒（与 timeoutInterval 一致）
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));

        if (!jsonData) {
            NSLog(@"[DownloadVC] Failed to download version JSON for %@", versionId);
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        // 5. 创建版本目录并写入 JSON
        NSError *dirError = nil;
        [NSFileManager.defaultManager createDirectoryAtPath:versionDir
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:&dirError];
        if (dirError) {
            NSLog(@"[DownloadVC] Failed to create version dir: %@", dirError.localizedDescription);
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        NSError *writeErr = nil;
        if (![jsonData writeToFile:versionJsonPath options:NSDataWritingAtomic error:&writeErr]) {
            NSLog(@"[DownloadVC] Failed to write version JSON: %@", writeErr.localizedDescription);
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        NSLog(@"[DownloadVC] Vanilla version JSON saved: %@ (%lu bytes)", versionJsonPath, (unsigned long)jsonData.length);
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(YES); });
    });
}

/// 参照 FCL：安装模组加载器前，先完整安装对应的原版（version JSON + libraries + assets）。
/// 若原版已安装（versions/{id}/{id}.json 存在于 POJAV_GAME_DIR），直接 completion(YES)。
/// 否则：1) 确保 version JSON 存在；2) 用 MinecraftResourceDownloadTask 下载完整原版文件（库+资源）；
/// 3) 进度展示由 MinecraftResourceDownloadTask 内部的阶段上报驱动统一进度页自动弹出
///    （redesign-download-ui Phase 3 Task 3.1：downloadVersion: 内注册 6 阶段 + autoPresentDetail）。
/// 注：client.jar 由 Java 端启动时按需下载，此处不检查；MinecraftResourceDownloadTask
/// 下载时会对已存在且 SHA1 正确的文件跳过，因此重复调用安全。
- (void)ensureVanillaInstalled:(NSDictionary *)version completion:(void (^)(BOOL success))completion {
    if (![version isKindOfClass:[NSDictionary class]]) {
        if (completion) completion(NO);
        return;
    }
    NSString *versionId = version[@"id"];
    if (![versionId isKindOfClass:[NSString class]] || versionId.length == 0) {
        if (completion) completion(NO);
        return;
    }

    // 用 POJAV_GAME_DIR（与 MinecraftResourceDownloadTask 一致），而非 POJAV_HOME
    NSString *gameDir = @(getenv("POJAV_GAME_DIR"));
    if (gameDir.length == 0) {
        // 极端情况下环境变量缺失，回退到 POJAV_HOME
        gameDir = @(getenv("POJAV_HOME"));
    }
    NSString *versionJsonPath = [gameDir stringByAppendingPathComponent:
                                 [NSString stringWithFormat:@"versions/%@/%@.json", versionId, versionId]];

    // 1. 原版 JSON 已存在（说明之前已下载过原版）。改进3（精细化跳过）：
    //    JSON 存在不代表安装完整——若上次下载中断，可能只有 JSON 而无 client.jar/库文件。
    //    参照 ZL2：检查 client.jar 是否存在，jar 缺失则继续预装补全，jar 存在才真正跳过。
    //    MinecraftResourceDownloadTask 内部对已存在且 SHA1 正确的文件会自动跳过，重复调用安全。
    if ([NSFileManager.defaultManager fileExistsAtPath:versionJsonPath]) {
        NSString *versionDir = [gameDir stringByAppendingPathComponent:
                               [NSString stringWithFormat:@"versions/%@", versionId]];
        NSString *clientJarPath = [versionDir stringByAppendingPathComponent:
                                   [NSString stringWithFormat:@"%@.jar", versionId]];
        if ([NSFileManager.defaultManager fileExistsAtPath:clientJarPath]) {
            NSLog(@"[DownloadVC] Vanilla %@ already installed (JSON + jar exist), skip preinstall", versionId);
            if (completion) completion(YES);
            return;
        }
        NSLog(@"[DownloadVC] Vanilla %@ JSON exists but client.jar missing, resuming preinstall", versionId);
        // 继续往下执行：创建下载任务补全缺失文件（已存在的会跳过）
    }

    NSLog(@"[DownloadVC] Vanilla %@ not installed, preinstalling...", versionId);

    // 保存 completion，KVO 完成时调用
    __weak typeof(self) weakSelf = self;
    self.vanillaPreinstallCompletion = completion;

    // 2. 先确保 version JSON 存在（复用已有逻辑）
    [self ensureVanillaVersionJSONExists:versionId completion:^(BOOL jsonSuccess) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            if (completion) completion(NO);
            return;
        }
        if (!jsonSuccess) {
            strongSelf.vanillaPreinstallCompletion = nil;
            if (completion) completion(NO);
            return;
        }

        // 3. 创建下载任务（redesign-download-ui Phase 3：进度页由任务阶段上报自动弹出，
        //    取消由统一进度页 → DownloadTaskManager.cancelTaskWithId → task.cancel 处理）
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) {
                if (completion) completion(NO);
                return;
            }

            // 4. 创建下载任务
            MinecraftResourceDownloadTask *task = [MinecraftResourceDownloadTask new];
            task.maxRetryCount = 3;
            s.vanillaPreinstallTask = task;

            task.handleError = ^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) ss = weakSelf;
                    if (!ss) return;
                    if (ss.isObservingVanillaPreinstall) {
                        @try {
                            [ss.vanillaPreinstallTask.progress removeObserver:ss forKeyPath:@"fractionCompleted"];
                        } @catch (NSException *exception) {
                            NSLog(@"[DownloadVC] vanillaPreinstall handleError: removeObserver failed: %@", exception.reason);
                        }
                        ss.isObservingVanillaPreinstall = NO;
                    }
                    ss.vanillaPreinstallTask = nil;
                    void (^cb)(BOOL) = ss.vanillaPreinstallCompletion;
                    ss.vanillaPreinstallCompletion = nil;
                    if (cb) cb(NO);
                });
            };

            // 5. KVO 监听进度（用独立 context 与主下载流程区分）
            [task.progress addObserver:s
                            forKeyPath:@"fractionCompleted"
                               options:NSKeyValueObservingOptionInitial
                               context:(void *)@"VanillaPreinstallContext"];
            s.isObservingVanillaPreinstall = YES;

            // 6. 后台线程启动下载
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                __strong typeof(weakSelf) ss = weakSelf;
                if (!ss) return;
                [ss.vanillaPreinstallTask downloadVersion:version];
            });
        });
    }];
}

#pragma mark - Vanilla Installation

- (void)downloadVanillaVersion:(NSDictionary *)version {
    if (![self isNetworkAvailable]) {
        [self showError:localize(@"i18n_str_199", nil)];
        return;
    }

    NSString *versionId = version[@"id"];

    NSMutableDictionary *profile = [NSMutableDictionary dictionary];
    profile[@"name"] = versionId;
    profile[@"lastVersionId"] = versionId;
    // 改回原来的"游戏目录切换"机制：所有版本共享根目录（gameDir="."）
    // 用户通过设置中的"游戏目录切换"功能手动切换不同的 gameDir
    profile[@"gameDir"] = @".";
    profile[@"type"] = @"custom";
    profile[@"created"] = [NSDate date].description;

    [PLProfiles.current saveProfile:profile withName:versionId];
    PLProfiles.current.selectedProfileName = versionId;

    [self startVersionDownload:version];
}

- (void)startVersionDownload:(NSDictionary *)version {
    __weak DownloadViewController *weakSelf = self;

    if (self.downloadingAlert) {
        [self.downloadingAlert dismiss];
        self.downloadingAlert = nil;
    }

    // redesign-download-ui Phase 4：进度展示统一由 MinecraftResourceDownloadTask
    // 内部注册的下载任务（原版 6 阶段 + autoPresentDetail=YES）自动弹出统一进度页，
    // 此处不再创建底部悬浮进度卡片，仅保留 KVO 完成收尾。

    // 重新赋值 downloadTask 前，先移除旧 task 的 KVO 观察者。
    // 否则 dealloc 时 self.downloadTask.progress 已是新对象，removeObserver 会抛
    // "not registered as an observer" 异常。
    if (self.isObservingProgress && self.downloadTask) {
        @try {
            [self.downloadTask.progress removeObserver:self forKeyPath:@"fractionCompleted"];
        } @catch (NSException *exception) {
            NSLog(@"[DownloadVC] startVersionDownload: removeObserver on old task failed: %@", exception.reason);
        }
        self.isObservingProgress = NO;
    }

    self.downloadTask = [MinecraftResourceDownloadTask new];
    self.downloadTask.maxRetryCount = 3;

    self.downloadTask.handleError = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.isObservingProgress) {
                @try {
                    [weakSelf.downloadTask.progress removeObserver:weakSelf forKeyPath:@"fractionCompleted"];
                } @catch (NSException *exception) {
                    NSLog(@"[DownloadVC] handleError: removeObserver failed: %@", exception.reason);
                }
                weakSelf.isObservingProgress = NO;
            }
            weakSelf.view.userInteractionEnabled = YES;
            weakSelf.downloadTask = nil;
        });
    };

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self.downloadTask downloadVersion:version];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.isObservingProgress) {
                @try {
                    [self.downloadTask.progress removeObserver:self forKeyPath:@"fractionCompleted"];
                } @catch (NSException *exception) {
                    NSLog(@"[DownloadVC] re-register: removeObserver failed: %@", exception.reason);
                }
                self.isObservingProgress = NO;
            }
            [self.downloadTask.progress addObserver:self
                                         forKeyPath:@"fractionCompleted"
                                            options:NSKeyValueObservingOptionInitial
                                            context:(void *)@"DownloadProgressContext"];
            self.isObservingProgress = YES;
        });
    });
}

#pragma mark - Fabric Installation

- (void)installFabric:(NSString *)gameVersion loaderVersion:(NSString *)loaderVersion installAPI:(BOOL)installAPI {
    [self installFabricLikeLoader:gameVersion loaderVersion:loaderVersion installAPI:installAPI vendor:@"fabric"];
}

- (void)installQuilt:(NSString *)gameVersion loaderVersion:(NSString *)loaderVersion {
    // Quilt 不安装 Fabric API（用 QSL/QFAPI），强制 installAPI=NO
    [self installFabricLikeLoader:gameVersion loaderVersion:loaderVersion installAPI:NO vendor:@"quilt"];
}

#pragma mark - Installer Task Registration (redesign-download-ui Phase 3 Task 3.2)

/// 注册安装类任务到统一下载管理器并配置阶段列表与自动弹出统一进度页。
/// 返回 taskId（注册失败返回 nil）。resourceType 默认 Modloader。
- (NSString *)registerInstallerTaskWithResourceName:(NSString *)resourceName
                                         displayName:(NSString *)displayName
                                               stages:(NSArray<PLTaskStage *> *)stages {
    NSString *source = getPrefObject(@"general.download_source") ?: @"official";
    DownloadTaskItem *item = [[DownloadTaskManager sharedManager]
        registerTaskWithResourceType:DownloadTaskResourceTypeModloader
                        resourceName:resourceName
                         displayName:displayName
                      downloadSource:source
                             rawTask:nil
                      supportsResume:NO
                             iconURL:nil];
    if (!item) return nil;
    [[DownloadTaskManager sharedManager] setTaskWithId:item.taskId stages:stages];
    item.autoPresentDetail = YES;
    return item.taskId;
}

/// Fabric/Quilt 共用的 meta API 安装实现
/// - vendor: @"fabric" 或 @"quilt"，决定 meta URL 与显示文案
- (void)installFabricLikeLoader:(NSString *)gameVersion loaderVersion:(NSString *)loaderVersion installAPI:(BOOL)installAPI vendor:(NSString *)vendor {
    BOOL isQuilt = [vendor isEqualToString:@"quilt"];
    NSString *displayName = isQuilt ? @"Quilt" : @"Fabric";
    NSString *metaBase = isQuilt ? @"https://meta.quiltmc.org/v3/versions/loader"
                                 : @"https://meta.fabricmc.net/v2/versions/loader";
    NSString *loaderTag = isQuilt ? @"quilt" : @"fabric";

    // redesign-download-ui Phase 3 Task 3.2：注册任务 + 阶段上报 + 自动弹统一进度页，
    // 替代私有 InstallerProgressViewController。原版预装（若发生）是独立任务独立进度页，
    // 加载器安装仅上报自身 3 步（获取 profile→下载加载器库→写入版本 JSON）。
    // 阶段下标与 PLTaskStagesFabricExtra() 一致。
    static const NSUInteger kFabricStageProfile = 0;
    static const NSUInteger kFabricStageLoaderLibs = 1;
    static const NSUInteger kFabricStageWriteJSON = 2;

    NSString *fabricTaskName = [NSString stringWithFormat:@"%@-%@-%@", loaderTag, gameVersion, loaderVersion];
    __block NSString *fabricTaskId = [self registerInstallerTaskWithResourceName:fabricTaskName
                                                                      displayName:[NSString stringWithFormat:@"%@ %@ (%@)", displayName, loaderVersion, gameVersion]
                                                                            stages:PLTaskStagesFabricExtra()];
    if (!fabricTaskId) {
        [self showError:[NSString stringWithFormat:localize(@"i18n_str_200", nil), displayName]];
        return;
    }
    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    // 阶段0：获取加载器 profile（profile JSON 较小，进度不确定）
    [manager updateTaskWithId:fabricTaskId stageAtIndex:kFabricStageProfile status:PLTaskStageStatusRunning];
    [manager updateTaskWithId:fabricTaskId stageAtIndex:kFabricStageProfile progress:-1
                                   message:[NSString stringWithFormat:localize(@"i18n_str_201", nil), gameVersion, loaderVersion]];
    [manager updateTaskWithId:fabricTaskId currentStageIndex:kFabricStageProfile];

    __weak typeof(self) weakSelf = self;
    __block NSURLSessionDataTask *dataTask = nil;

    NSString *urlString = [NSString stringWithFormat:@"%@/%@/%@/profile/json", metaBase, gameVersion, loaderVersion];
    NSURL *url = [NSURL URLWithString:urlString];

    // profile JSON 较小，使用 dataTask；进度通过阶段驱动（无法精确测算）
    dataTask = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (error) {
                [manager updateTaskWithId:fabricTaskId stageAtIndex:kFabricStageProfile status:PLTaskStageStatusFailed];
                [manager updateTaskWithId:fabricTaskId stageAtIndex:kFabricStageProfile progress:0 message:error.localizedDescription];
                if (error.code == NSURLErrorCancelled) {
                    [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId completedWithError:nil];
                    [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId state:DownloadTaskStateCancelled];
                } else {
                    NSError *err = [NSError errorWithDomain:@"FabricInstall" code:error.code userInfo:@{NSLocalizedDescriptionKey: error.localizedDescription ?: localize(@"i18n_str_202", nil)}];
                    [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId completedWithError:err];
                }
                [strongSelf finishInstallerProgressWithError:[NSString stringWithFormat:localize(@"i18n_str_203", nil), displayName, error.localizedDescription ?: localize(@"i18n_str_202", nil)]];
                return;
            }

            if (!data) {
                [manager updateTaskWithId:fabricTaskId stageAtIndex:kFabricStageProfile status:PLTaskStageStatusFailed];
                NSError *err = [NSError errorWithDomain:@"FabricInstall" code:2 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_204", nil)}];
                [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId completedWithError:err];
                [strongSelf finishInstallerProgressWithError:[NSString stringWithFormat:localize(@"i18n_str_205", nil), displayName]];
                return;
            }

            // 解析 JSON（阶段0 收尾）
            NSError *jsonError;
            NSDictionary *profileJson = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (!profileJson || jsonError) {
                [manager updateTaskWithId:fabricTaskId stageAtIndex:kFabricStageProfile status:PLTaskStageStatusFailed];
                [manager updateTaskWithId:fabricTaskId stageAtIndex:kFabricStageProfile progress:0 message:jsonError.localizedDescription];
                NSError *err = [NSError errorWithDomain:@"FabricInstall" code:3 userInfo:@{NSLocalizedDescriptionKey: jsonError.localizedDescription ?: localize(@"i18n_str_206", nil)}];
                [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId completedWithError:err];
                [strongSelf finishInstallerProgressWithError:[NSString stringWithFormat:localize(@"i18n_str_207", nil), displayName]];
                return;
            }
            [manager updateTaskWithId:fabricTaskId stageAtIndex:kFabricStageProfile status:PLTaskStageStatusCompleted];

            // 写入版本 JSON（阶段2）
            [manager updateTaskWithId:fabricTaskId stageAtIndex:kFabricStageWriteJSON status:PLTaskStageStatusRunning];
            [manager updateTaskWithId:fabricTaskId currentStageIndex:kFabricStageWriteJSON];

            NSString *versionId = profileJson[@"id"];
            NSString *jsonPath = [NSString stringWithFormat:@"%s/versions/%@/%@.json", getenv("POJAV_GAME_DIR"), versionId, versionId];
            [[NSFileManager defaultManager] createDirectoryAtPath:[jsonPath stringByDeletingLastPathComponent]
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];

            NSError *saveError;
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:profileJson options:NSJSONWritingPrettyPrinted error:&saveError];
            [jsonData writeToFile:jsonPath options:NSDataWritingAtomic error:&saveError];
            if (saveError) {
                [manager updateTaskWithId:fabricTaskId stageAtIndex:kFabricStageWriteJSON status:PLTaskStageStatusFailed];
                [manager updateTaskWithId:fabricTaskId stageAtIndex:kFabricStageWriteJSON progress:0 message:saveError.localizedDescription];
                NSError *err = [NSError errorWithDomain:@"FabricInstall" code:4 userInfo:@{NSLocalizedDescriptionKey: saveError.localizedDescription}];
                [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId completedWithError:err];
                [strongSelf finishInstallerProgressWithError:[NSString stringWithFormat:localize(@"i18n_str_208", nil), saveError.localizedDescription]];
                return;
            }

            // 注册 profile（阶段2 收尾）
            NSMutableDictionary *profile = [NSMutableDictionary dictionary];
            profile[@"name"] = versionId;
            profile[@"lastVersionId"] = versionId;
            // 改回原来的"游戏目录切换"机制：所有版本共享根目录（gameDir="."）
            // 用户通过设置中的"游戏目录切换"功能手动切换不同的 gameDir
            profile[@"gameDir"] = @".";
            profile[@"type"] = @"custom";
            profile[@"created"] = [NSDate date].description;
            [PLProfiles.current saveProfile:profile withName:versionId];
            PLProfiles.current.selectedProfileName = versionId;
            [manager updateTaskWithId:fabricTaskId stageAtIndex:kFabricStageWriteJSON status:PLTaskStageStatusCompleted];

            // 仅 Fabric 安装 Fabric API；Quilt 用 QSL/QFAPI，不安装（阶段1 Skipped）
            if (installAPI && !isQuilt) {
                [manager updateTaskWithId:fabricTaskId stageAtIndex:kFabricStageLoaderLibs status:PLTaskStageStatusRunning];
                [manager updateTaskWithId:fabricTaskId stageAtIndex:kFabricStageLoaderLibs progress:-1 message:localize(@"i18n_str_209", nil)];
                [manager updateTaskWithId:fabricTaskId currentStageIndex:kFabricStageLoaderLibs];
                [strongSelf downloadFabricAPI:gameVersion completion:^(BOOL success, NSError *apiError) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        __strong typeof(weakSelf) strongSelf2 = weakSelf;
                        if (!strongSelf2) return;
                        if (success) {
                            [manager updateTaskWithId:fabricTaskId stageAtIndex:kFabricStageLoaderLibs status:PLTaskStageStatusCompleted];
                            [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId completedWithError:nil];
                            [strongSelf2 finishInstallerProgressWithSuccess:[NSString stringWithFormat:localize(@"i18n_str_210", nil), displayName, loaderVersion]];
                        } else {
                            [manager updateTaskWithId:fabricTaskId stageAtIndex:kFabricStageLoaderLibs status:PLTaskStageStatusFailed];
                            [manager updateTaskWithId:fabricTaskId stageAtIndex:kFabricStageLoaderLibs progress:0 message:apiError.localizedDescription];
                            NSError *err = [NSError errorWithDomain:@"FabricInstall" code:5 userInfo:@{NSLocalizedDescriptionKey: apiError.localizedDescription ?: localize(@"i18n_str_211", nil)}];
                            [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId completedWithError:err];
                            [strongSelf2 finishInstallerProgressWithSuccess:[NSString stringWithFormat:localize(@"i18n_str_212", nil), displayName, loaderVersion, apiError.localizedDescription ?: localize(@"i18n_str_97", nil)]];
                        }
                    });
                }];
            } else {
                [manager updateTaskWithId:fabricTaskId stageAtIndex:kFabricStageLoaderLibs status:PLTaskStageStatusSkipped];
                [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId completedWithError:nil];
                [strongSelf finishInstallerProgressWithSuccess:[NSString stringWithFormat:localize(@"i18n_str_213", nil), displayName, loaderVersion]];
            }
        });
    }];
    DownloadTaskItem *fabricTaskItem = [[DownloadTaskManager sharedManager] taskWithId:fabricTaskId];
    fabricTaskItem.rawTask = dataTask;
    [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId state:DownloadTaskStateDownloading];
    [dataTask resume];
}

// 安装完成时的统一处理（redesign-download-ui Phase 3：统一进度页自动展示完成态并自动关闭，
// 这里仅负责成功提示与版本列表刷新）
- (void)finishInstallerProgressWithSuccess:(NSString *)message {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf showSuccessMessage:message];
        // 关键修复（issue #61）：Fabric/Forge/NeoForge/OptiFine 安装完成后未发送 ReloadProfileList 通知，
        // 导致"已安装的版本"列表不刷新、新版本卡片不显示、加载器图标也不显示。
        // 此处统一在安装完成后发通知，触发 LauncherRootViewController / VersionManagerViewController 等监听者重新加载版本列表。
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
        // Forge/NeoForge 直装在本进程执行过 processors（headless JVM），进程内 JVM
        // 只能创建一次，直接启动游戏会崩溃，必须重启 app 释放后再玩。
        if ([ForgeProcessorExecutor jvmUsedThisProcess]) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_214", nil)
                                                                           message:localize(@"i18n_str_215", nil)
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_216", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [PLCrashView restartLauncher];
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_217", nil) style:UIAlertActionStyleCancel handler:nil]];
            [strongSelf presentViewController:alert animated:YES completion:nil];
        }
    });
}

// 安装失败时的统一处理（redesign-download-ui Phase 3：统一进度页展示失败态，
// 这里仅负责内容区错误提示）
- (void)finishInstallerProgressWithError:(NSString *)errorMessage {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf showError:errorMessage];
    });
}

- (void)downloadFabricAPI:(NSString *)gameVersion completion:(void (^)(BOOL success, NSError *error))completion {
    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"query"] = @"fabric api";
    filters[@"version"] = gameVersion;
    
    __weak typeof(self) weakSelf = self;
    id api = [self currentAPIForTabType:@"mod"];
    [api searchModWithFilters:filters completion:^(NSArray *results, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            if (completion) completion(NO, [NSError errorWithDomain:@"AppError" code:-1 userInfo:nil]);
            return;
        }
        if (error || results.count == 0) {
            if (completion) completion(NO, error ?: [NSError errorWithDomain:@"DownloadError" code:1 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_218", nil)}]);
            return;
        }
        
        NSDictionary *fabricAPI = nil;
        for (NSDictionary *mod in results) {
            NSString *title = mod[@"title"] ?: @"";
            if ([title.lowercaseString containsString:@"fabric api"] && ![title.lowercaseString containsString:@"kotlin"]) {
                fabricAPI = mod;
                break;
            }
        }
        
        if (!fabricAPI) {
            if (completion) completion(NO, [NSError errorWithDomain:@"DownloadError" code:2 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_219", nil)}]);
            return;
        }
        
        [api getVersionsForModWithID:fabricAPI[@"id"] completion:^(NSArray<ModVersion *> *versions, NSError *versionError) {
            if (versionError || versions.count == 0) {
                if (completion) completion(NO, versionError ?: [NSError errorWithDomain:@"DownloadError" code:3 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_220", nil)}]);
                return;
            }
            
            ModVersion *matchingVersion = nil;
            for (ModVersion *ver in versions) {
                if ([ver.gameVersions containsObject:gameVersion]) {
                    matchingVersion = ver;
                    break;
                }
            }
            
            if (!matchingVersion) {
                matchingVersion = versions.firstObject;
            }
            
            [strongSelf downloadModVersion:matchingVersion modInfo:fabricAPI completion:completion];
        }];
    }];
}

#pragma mark - Forge Installation

- (LauncherNavigationController *)activeLauncherNavigationController {
    // First try the existing logic
    UISplitViewController *splitVC = self.splitViewController;
    if (!splitVC && [self.presentingViewController isKindOfClass:[UISplitViewController class]]) {
        splitVC = (UISplitViewController *)self.presentingViewController;
    }
    if (splitVC.viewControllers.count > 1) {
        UIViewController *candidate = splitVC.viewControllers[1];
        if ([candidate isKindOfClass:[LauncherNavigationController class]]) {
            return (LauncherNavigationController *)candidate;
        }
        if ([candidate isKindOfClass:[UINavigationController class]]) {
            for (UIViewController *vc in ((UINavigationController *)candidate).viewControllers) {
                if ([vc isKindOfClass:[LauncherNavigationController class]]) {
                    return (LauncherNavigationController *)vc;
                }
            }
        }
    }
    if ([self.navigationController isKindOfClass:[LauncherNavigationController class]]) {
        return (LauncherNavigationController *)self.navigationController;
    }

    // Fallback: traverse from key window root view controller
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

    UIViewController *rootVC = keyWindow.rootViewController;
    if (rootVC) {
        LauncherNavigationController *found = [self findLauncherNavigationControllerIn:rootVC];
        if (found) return found;
    }

    return nil;
}

- (LauncherNavigationController *)findLauncherNavigationControllerIn:(UIViewController *)vc {
    if ([vc isKindOfClass:[LauncherNavigationController class]]) {
        return (LauncherNavigationController *)vc;
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *child in ((UINavigationController *)vc).viewControllers) {
            LauncherNavigationController *found = [self findLauncherNavigationControllerIn:child];
            if (found) return found;
        }
    }
    if ([vc isKindOfClass:[UISplitViewController class]]) {
        for (UIViewController *child in ((UISplitViewController *)vc).viewControllers) {
            LauncherNavigationController *found = [self findLauncherNavigationControllerIn:child];
            if (found) return found;
        }
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *child in ((UITabBarController *)vc).viewControllers) {
            LauncherNavigationController *found = [self findLauncherNavigationControllerIn:child];
            if (found) return found;
        }
    }
    if (vc.presentedViewController) {
        LauncherNavigationController *found = [self findLauncherNavigationControllerIn:vc.presentedViewController];
        if (found) return found;
    }
    for (UIViewController *child in vc.childViewControllers) {
        LauncherNavigationController *found = [self findLauncherNavigationControllerIn:child];
        if (found) return found;
    }
    return nil;
}

#pragma mark - Mod Installer (Fallback when LauncherNavigationController is not available)

- (void)launchModInstallerWithPath:(NSString *)path hitEnterAfterWindowShown:(BOOL)hitEnter {
    JavaGUIViewController *vc = [[JavaGUIViewController alloc] init];
    vc.filepath = path;
    vc.hitEnterAfterWindowShown = hitEnter;
    if (!vc.requiredJavaVersion) {
        // 解析失败（manifest 缺失/主类非法）时明确提示，避免静默 return 让用户以为安装器已启动
        showDialog(localize(@"Error", nil),
            [NSString stringWithFormat:localize(@"i18n_str_221", nil), path.lastPathComponent]);
        return;
    }
    // execute_jar 路径：Caciocavallo17 jar 现已统一为 Java 17 编译版本，
    // Java 17/21 均可加载，不再需要强制提升 requiredJavaVersion 到 25。
    // - Java 8 JAR（如 OptiFine 安装器）走 Caciocavallo（非 17）路径，用 Java 8
    // - Java 17+ JAR 走 Caciocavallo17 路径，用 Java 17/21 即可
    // 与 JavaLauncher.m launchJar 分支保持一致。
    int requiredJavaVersion = vc.requiredJavaVersion;
    // 预检 execute_jar 标签的 JRE 是否已配置，避免 present 后才发现没 JRE 导致黑屏
    // 与 LauncherRightPanelViewController.enterModInstallerWithPath: 行为一致
    NSString *javaHome = getSelectedJavaHome(@"execute_jar", requiredJavaVersion);
    if (!javaHome) {
        showDialog(localize(@"Error", nil),
            [NSString stringWithFormat:localize(@"i18n_str_222", nil), requiredJavaVersion, requiredJavaVersion]);
        return;
    }
    [self invokeAfterJITEnabled:^{
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        NSLog(@"[ModInstaller] launching %@", vc.filepath);
        [self presentViewController:vc animated:YES completion:nil];
    }];
}

- (void)invokeAfterJITEnabled:(void(^)(void))handler {
    BOOL hasTrollStoreJIT = getEntitlementValue(@"jb.pmap_cs.custom_trust");
    
    if (isJITEnabled(false)) {
        [ALTServerManager.sharedManager stopDiscovering];
        handler();
        return;
    } else if (hasTrollStoreJIT) {
        NSURL *jitURL = [NSURL URLWithString:[NSString stringWithFormat:@"apple-magnifier://enable-jit?bundle-id=%@", NSBundle.mainBundle.bundleIdentifier]];
        [UIApplication.sharedApplication openURL:jitURL options:@{} completionHandler:nil];
    } else if (getPrefBool(@"debug.debug_skip_wait_jit")) {
        NSLog(@"Debug option skipped waiting for JIT. Java might not work.");
        handler();
        return;
    } else if (@available(iOS 17.4, *)) {
        NSString *scriptDataString = @"";
        if (DeviceNeedsDebugJITMapping()) {
            NSData *scriptData = [NSData dataWithContentsOfFile:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
            scriptDataString = [@"&script-data=" stringByAppendingString:[scriptData base64EncodedStringWithOptions:0]];
        }
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:[NSString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@&pid=%d%@", NSBundle.mainBundle.bundleIdentifier, getpid(), scriptDataString]] options:@{} completionHandler:nil];
    } else {
        // Assuming 16.7-17.3.1. SideStore still lacks this URL scheme at the time of writing, so it only jumps to SideStore.
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:[NSString stringWithFormat:@"sidestore://sidejit-enable?pid=%d", getpid()]] options:@{} completionHandler:nil];
    }
    
    // 在内容区显示 JIT 等待提示，替代弹窗
    InlineMessageView *jitAlert = [InlineMessageView showInViewController:self
                                                                    title:localize(@"launcher.wait_jit.title", nil)
                                                                 message:hasTrollStoreJIT ? localize(@"launcher.wait_jit_trollstore.message", nil) : localize(@"launcher.wait_jit.message", nil)
                                                                    type:InlineMessageTypeLoading];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (!isJITEnabled(false)) {
            usleep(1000 * 200);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [jitAlert dismiss];
            if (handler) handler();
        });
    });
}

- (void)handleInstallerDownloadResultWithVendorName:(NSString *)vendorName
                                        gameVersion:(NSString *)gameVersion
                                        profileName:(NSString *)profileName
                                    resultOrError:(id)resultOrError
                                     installAction:(void (^)(void))installAction {
    if ([resultOrError isKindOfClass:[NSError class]]) {
        NSError *error = (NSError *)resultOrError;
        if ([error.domain isEqualToString:ForgeInstallerFlowErrorDomain] && error.code == ForgeInstallerFlowErrorCodeCancelled) {
            return;
        }
        [self showError:error.localizedDescription ?: [NSString stringWithFormat:localize(@"i18n_str_223", nil), vendorName]];
        return;
    }
    
    NSString *filePath = nil;
    if ([resultOrError isKindOfClass:[NSDictionary class]]) {
        filePath = ((NSDictionary *)resultOrError)[@"filePath"];
    } else if ([resultOrError isKindOfClass:[NSString class]]) {
        filePath = (NSString *)resultOrError;
    }
    if (filePath.length == 0) {
        [self showError:[NSString stringWithFormat:localize(@"i18n_str_224", nil), vendorName]];
        return;
    }
    
    LauncherNavigationController *navVC = [self activeLauncherNavigationController];
    
    NSString *message = [NSString stringWithFormat:localize(@"i18n_str_225", nil), vendorName];
    
    void (^launchInstaller)(void) = ^{
        if (navVC) {
            [navVC enterModInstallerWithPath:filePath hitEnterAfterWindowShown:YES];
        } else {
            [self launchModInstallerWithPath:filePath hitEnterAfterWindowShown:YES];
        }
        
        if (installAction) {
            installAction();
        } else {
            [self showSuccessMessage:[NSString stringWithFormat:localize(@"i18n_str_226", nil), vendorName, profileName ?: gameVersion]];
        }
    };
    
    void (^showAlertAndLaunch)(void) = ^{
        // 在内容区显示下载完成提示，替代弹窗
        InlineMessageView *msgView = [InlineMessageView showInViewController:self
                                                                       title:localize(@"i18n_str_227", nil)
                                                                    message:message
                                                                       type:InlineMessageTypeSuccess];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [msgView dismiss];
            if (launchInstaller) launchInstaller();
        });
    };

    if (self.presentedViewController) {
        [self dismissViewControllerAnimated:YES completion:showAlertAndLaunch];
    } else {
        showAlertAndLaunch();
    }
}

- (void)installForge:(NSString *)gameVersion installOptiFine:(BOOL)installOptiFine loaderVersion:(NSString *)loaderVersion {
    ForgeInstallViewController *forgeVC = [[ForgeInstallViewController alloc] init];
    forgeVC.gameVersion = gameVersion;
    // ModLoaderInstallViewController 已选好版本，传入以跳过重复的版本列表 UI
    forgeVC.presetVersionString = loaderVersion;

    __weak typeof(self) weakSelf = self;
    void (^completion)(BOOL, NSString *, id) = ^(BOOL success, NSString *profileName, id resultOrError) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // 解析 ForgeInstallViewController 打包的回调结果（无论成败都需要先解析）
        NSInteger selectedScheme = 0;
        NSString *filePath = nil;
        if ([resultOrError isKindOfClass:[NSDictionary class]]) {
            NSDictionary *result = (NSDictionary *)resultOrError;
            filePath = result[@"filePath"];
            selectedScheme = [result[@"selectedScheme"] integerValue];
        } else if ([resultOrError isKindOfClass:[NSString class]]) {
            filePath = (NSString *)resultOrError;
        }

        // 先 pop 掉 ForgeInstallViewController；pop 完成后再走后续流程，
        // 否则在 pop 动画期间 present alert / push 进度页会失败或弹错 VC
        void (^continuation)(void) = ^{
            __strong typeof(weakSelf) strongSelf2 = weakSelf;
            if (!strongSelf2) return;

            if (!success) {
                [strongSelf2 handleInstallerDownloadResultWithVendorName:@"Forge"
                                                              gameVersion:gameVersion
                                                              profileName:profileName
                                                            resultOrError:resultOrError
                                                             installAction:nil];
                return;
            }

            if (selectedScheme == 1 && filePath.length > 0) {
                // 直装方案（redesign-download-ui Phase 3 Task 3.2/3.3）：注册任务 + 阶段上报 +
                // 自动弹统一进度页，ForgeDirectInstaller 的 progress 回调桥接为阶段上报
                NSLog(@"[ForgeDirect] DownloadViewController: starting direct install with unified progress UI");
                // 阶段下标与 PLTaskStagesForgeExtra() 一致：下载安装器→解析依赖→安装加载器
                static const NSUInteger kForgeStageInstaller = 0;
                static const NSUInteger kForgeStageResolve = 1;
                static const NSUInteger kForgeStageInstall = 2;

                NSString *forgeTaskId = [strongSelf2 registerInstallerTaskWithResourceName:[NSString stringWithFormat:@"forge-%@-%@", gameVersion, profileName]
                                                                                  displayName:[NSString stringWithFormat:@"Forge %@ (%@)", profileName ?: @"", gameVersion]
                                                                                        stages:PLTaskStagesForgeExtra()];
                if (!forgeTaskId) {
                    [strongSelf2 showError:localize(@"i18n_str_228", nil)];
                    return;
                }
                DownloadTaskManager *forgeManager = [DownloadTaskManager sharedManager];
                // 阶段0 下载安装器：installer jar 已由 ForgeInstallViewController 下载完成，直接标记
                [forgeManager updateTaskWithId:forgeTaskId stageAtIndex:kForgeStageInstaller status:PLTaskStageStatusCompleted];
                // 阶段1 解析依赖：读取 install_profile.json / 解析 JSON（installer 进度 0~0.15）
                [forgeManager updateTaskWithId:forgeTaskId stageAtIndex:kForgeStageResolve status:PLTaskStageStatusRunning];
                [forgeManager updateTaskWithId:forgeTaskId stageAtIndex:kForgeStageResolve progress:0 message:nil];
                [forgeManager updateTaskWithId:forgeTaskId currentStageIndex:kForgeStageResolve];

                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    NSError *directError = nil;
                    BOOL installed = [ForgeDirectInstaller installForgeFromInstaller:filePath
                                                                           versionId:profileName
                                                                             progress:^(double progress, NSString *stageMessage) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            // 阶段桥接（Task 3.3，不改安装器回调签名）：
                            // p<0.15 解析依赖；p>=0.15 安装加载器（映射回 0~1 阶段进度）
                            if (progress < 0.15) {
                                [forgeManager updateTaskWithId:forgeTaskId
                                                   stageAtIndex:kForgeStageResolve
                                                      progress:MIN(progress / 0.15, 1.0)
                                                       message:stageMessage];
                            } else {
                                if (progress >= 0.2) {
                                    [forgeManager updateTaskWithId:forgeTaskId stageAtIndex:kForgeStageResolve status:PLTaskStageStatusCompleted];
                                    [forgeManager updateTaskWithId:forgeTaskId stageAtIndex:kForgeStageInstall status:PLTaskStageStatusRunning];
                                    [forgeManager updateTaskWithId:forgeTaskId currentStageIndex:kForgeStageInstall];
                                }
                                double installProgress = MIN((progress - 0.15) / 0.85, 1.0);
                                [forgeManager updateTaskWithId:forgeTaskId
                                                   stageAtIndex:kForgeStageInstall
                                                      progress:installProgress
                                                       message:stageMessage];
                            }
                        });
                    }
                                                                               error:&directError];

                    dispatch_async(dispatch_get_main_queue(), ^{
                        __strong typeof(weakSelf) strongSelf3 = weakSelf;
                        if (!strongSelf3) return;
                        if (!installed) {
                            [forgeManager updateTaskWithId:forgeTaskId stageAtIndex:kForgeStageInstall status:PLTaskStageStatusFailed];
                            [forgeManager updateTaskWithId:forgeTaskId stageAtIndex:kForgeStageInstall progress:0 message:directError.localizedDescription];
                            NSError *err = [NSError errorWithDomain:@"ForgeDirectInstall" code:1 userInfo:@{NSLocalizedDescriptionKey: directError.localizedDescription ?: localize(@"i18n_str_97", nil)}];
                            [[DownloadTaskManager sharedManager] setTaskWithId:forgeTaskId completedWithError:err];
                            [strongSelf3 finishInstallerProgressWithError:[NSString stringWithFormat:localize(@"i18n_str_229", nil), directError.localizedDescription ?: localize(@"i18n_str_97", nil)]];
                            return;
                        }
                        // 直装成功：收敛全部阶段状态
                        [forgeManager updateTaskWithId:forgeTaskId stageAtIndex:kForgeStageResolve status:PLTaskStageStatusCompleted];
                        [forgeManager updateTaskWithId:forgeTaskId stageAtIndex:kForgeStageInstall status:PLTaskStageStatusCompleted];
                        [forgeManager updateTaskWithId:forgeTaskId stageAtIndex:kForgeStageInstall progress:1 message:nil];
                        [[DownloadTaskManager sharedManager] setTaskWithId:forgeTaskId completedWithError:nil];
                        // 直装成功后，若用户勾选了 OptiFine，继续下载（之前的实现这里直接 return 漏掉了 OptiFine）
                        if (installOptiFine) {
                            [forgeManager updateTaskWithId:forgeTaskId stageAtIndex:kForgeStageInstall progress:1 message:localize(@"i18n_str_230", nil)];
                            [strongSelf3 downloadOptiFine:gameVersion completion:^(BOOL optiSuccess, NSError *optiError) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    __strong typeof(weakSelf) strongSelf4 = weakSelf;
                                    if (!strongSelf4) return;
                                    if (optiSuccess) {
                                        [strongSelf4 finishInstallerProgressWithSuccess:[NSString stringWithFormat:localize(@"i18n_str_231", nil), profileName ?: gameVersion]];
                                    } else {
                                        [strongSelf4 finishInstallerProgressWithSuccess:[NSString stringWithFormat:localize(@"i18n_str_232", nil), optiError.localizedDescription ?: localize(@"i18n_str_97", nil), profileName ?: gameVersion]];
                                    }
                                });
                            }];
                        } else {
                            [strongSelf3 finishInstallerProgressWithSuccess:[NSString stringWithFormat:localize(@"i18n_str_233", nil), profileName ?: gameVersion]];
                        }
                    });
                });
                return;
            }

            // 原版方案（运行安装器）：进入 AWT 安装器 GUI 流程
            [strongSelf2 handleInstallerDownloadResultWithVendorName:@"Forge"
                                                          gameVersion:gameVersion
                                                          profileName:profileName
                                                        resultOrError:resultOrError
                                                         installAction:^{
                if (installOptiFine) {
                    [strongSelf2 downloadOptiFine:gameVersion completion:^(BOOL optiSuccess, NSError *optiError) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (optiSuccess) {
                                [strongSelf2 showSuccessMessage:[NSString stringWithFormat:localize(@"i18n_str_234", nil), profileName ?: gameVersion]];
                            } else {
                                [strongSelf2 showSuccessMessage:[NSString stringWithFormat:localize(@"i18n_str_235", nil), optiError.localizedDescription ?: localize(@"i18n_str_97", nil), profileName ?: gameVersion]];
                            }
                        });
                    }];
                } else {
                    [strongSelf2 showSuccessMessage:[NSString stringWithFormat:localize(@"i18n_str_236", nil), profileName ?: gameVersion]];
                }
            }];
        };

        if (strongSelf.navigationController.topViewController != strongSelf) {
            [strongSelf.navigationController popViewControllerAnimated:YES];
            // 等待 pop 动画结束后再触发后续 present / push，避免动画冲突
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), continuation);
        } else {
            continuation();
        }
    };
    forgeVC.completionHandler = completion;

    // 直接 push 到中间内容区，不再用 FormSheet 弹窗
    [self.navigationController pushViewController:forgeVC animated:YES];
}

- (void)downloadOptiFine:(NSString *)gameVersion completion:(void (^)(BOOL success, NSError *error))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 修复: 不再依赖硬编码的版本映射表（容易过期），改用 BMCLAPI 动态查询游戏版本对应的最新 OptiFine 版本
        NSString *listURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@", gameVersion];
        // 阶段6修复（参照 FCL）：使用带 User-Agent 的 NSURLSession 同步下载替代 NSData dataWithContentsOfURL:
        // BMCLAPI/Cloudflare 会拦截无 UA 或默认 UA 的请求，返回 403 或 HTML 错误页
        NSError *listError = nil;
        NSData *listData = [self downloadDataWithURLString:listURL error:&listError];
        NSString *optiFineType = nil;
        NSString *optiFinePatch = nil;
        NSString *filename = nil;

        if (listData && !listError) {
            NSError *jsonError = nil;
            NSArray *versions = [NSJSONSerialization JSONObjectWithData:listData options:0 error:&jsonError];
            if (!jsonError && [versions isKindOfClass:[NSArray class]] && versions.count > 0) {
                // 取列表中第一个（通常为最新发布版本）
                NSDictionary *first = versions.firstObject;
                if ([first isKindOfClass:[NSDictionary class]]) {
                    optiFineType = first[@"type"] ?: @"HD_U";
                    optiFinePatch = first[@"patch"];
                    filename = first[@"filename"];
                }
            }
        }

        // fallback: 列表 API 失败时回退到本地硬编码映射
        if (!optiFinePatch) {
            NSString *mapped = [self mapGameVersionToOptiFine:gameVersion];
            if (mapped) {
                // 映射表里是 "HD_U_I6" 形式，拆出 type=HD_U, patch=I6
                NSRange range = [mapped rangeOfString:@"_"];
                if (range.location != NSNotFound) {
                    optiFineType = [mapped substringToIndex:range.location];
                    optiFinePatch = [mapped substringFromIndex:range.location + 1];
                }
            }
        }

        if (!optiFinePatch) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, [NSError errorWithDomain:@"DownloadError" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_237", nil), gameVersion]}]);
            });
            return;
        }

        // BMCLAPI OptiFine 下载 URL: /optifine/{mcversion}/{type}/{patch}
        NSString *downloadURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@/%@/%@",
                                 gameVersion, optiFineType, optiFinePatch];
        // 阶段6修复：使用带 UA 的下载方法
        NSError *downloadError = nil;
        NSData *data = [self downloadDataWithURLString:downloadURL error:&downloadError];

        // fallback: OptiFine 官方源
        if ((!data || downloadError) && filename) {
            NSString *officialURL = [NSString stringWithFormat:@"https://optifine.net/downloadx?f=%@", filename];
            // 阶段6修复：使用带 UA 的下载方法
            NSError *officialError = nil;
            NSData *officialData = [self downloadDataWithURLString:officialURL error:&officialError];
            if (officialData && !officialError) {
                data = officialData;
                downloadError = nil;
            }
        }

        if (!data || downloadError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *errDesc = downloadError.localizedDescription;
                if (downloadError.code == NSURLErrorFileDoesNotExist || [errDesc containsString:@"404"]) {
                    errDesc = [NSString stringWithFormat:localize(@"i18n_str_238", nil), optiFineType, optiFinePatch];
                }
                if (completion) completion(NO, [NSError errorWithDomain:@"DownloadError" code:2 userInfo:@{NSLocalizedDescriptionKey: errDesc ?: localize(@"i18n_str_239", nil)}]);
            });
            return;
        }

        NSString *modsDir = [self currentInstanceModsPath];
        // 优先用 API 返回的 filename；否则用 type_patch 构造
        NSString *saveFilename = filename ?: [NSString stringWithFormat:@"OptiFine_%@_%@_%@.jar", gameVersion, optiFineType, optiFinePatch];
        NSString *savePath = [modsDir stringByAppendingPathComponent:saveFilename];

        NSError *saveError;
        BOOL success = [data writeToFile:savePath options:NSDataWritingAtomic error:&saveError];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(success, saveError);
        });
    });
}

- (NSString *)mapGameVersionToOptiFine:(NSString *)gameVersion {
    NSDictionary *versionMap = @{
        @"1.21.4": @"HD_U_J3",
        @"1.21.3": @"HD_U_J2",
        @"1.21.1": @"HD_U_J1",
        @"1.21": @"HD_U_I9",
        @"1.20.4": @"HD_U_I7",
        @"1.20.2": @"HD_U_I6",
        @"1.20.1": @"HD_U_I6",
        @"1.20": @"HD_U_I5",
        @"1.19.4": @"HD_U_I4",
        @"1.19.3": @"HD_U_I3",
        @"1.19.2": @"HD_U_H9",
        @"1.18.2": @"HD_U_H7",
        @"1.17.1": @"HD_U_H1",
        @"1.16.5": @"HD_U_G8",
        @"1.16.4": @"HD_U_G7",
        @"1.15.2": @"HD_U_G6",
        @"1.14.4": @"HD_U_G5",
        @"1.12.2": @"HD_U_G5",
        @"1.8.9": @"HD_U_L5",
    };
    
    NSString *optiFineVersion = versionMap[gameVersion];
    if (optiFineVersion) return optiFineVersion;
    
    for (NSString *key in versionMap) {
        if ([gameVersion hasPrefix:key]) {
            return versionMap[key];
        }
    }
    
    return nil;
}

#pragma mark - OptiFine as Patch Installation (单独安装，参照 FCL OptiFineInstallTask)

/// 单独安装 OptiFine 作为版本补丁（不依赖 Forge）
/// loaderVersion 是 packed 格式：type\x1fpatch\x1ffilename\x1fdisplay
- (void)installOptiFineAsPatch:(NSString *)gameVersion loaderVersion:(NSString *)loaderVersion {
    // 解析 packed 格式
    NSArray *parts = [loaderVersion componentsSeparatedByString:@"\x1f"];
    if (parts.count < 3) {
        [self showError:localize(@"i18n_str_240", nil)];
        return;
    }
    NSString *optiType = parts[0];
    NSString *optiPatch = parts[1];
    NSString *filename = parts[2];

    NSString *versionId = [NSString stringWithFormat:@"%@-OptiFine_%@_%@", gameVersion, optiType, optiPatch];

    // redesign-download-ui Phase 3 Task 3.2：注册任务 + 阶段上报 + 自动弹统一进度页。
    // 阶段映射（PLTaskStagesForgeExtra 3 步）：下载安装器=下载 OptiFine JAR，
    // 解析依赖=Skipped（OptiFine 无依赖解析），安装加载器=写入版本 JSON + 注册 profile。
    static const NSUInteger kOptiFineStageInstaller = 0;
    static const NSUInteger kOptiFineStageResolve = 1;
    static const NSUInteger kOptiFineStageInstall = 2;

    NSString *taskName = [NSString stringWithFormat:@"optifine-%@-%@-%@", gameVersion, optiType, optiPatch];
    NSString *taskId = [self registerInstallerTaskWithResourceName:taskName
                                                        displayName:[NSString stringWithFormat:@"OptiFine %@_%@ (%@)", optiType, optiPatch, gameVersion]
                                                              stages:PLTaskStagesForgeExtra()];
    if (!taskId) {
        [self showError:localize(@"i18n_str_241", nil)];
        return;
    }
    DownloadTaskManager *optiManager = [DownloadTaskManager sharedManager];
    [optiManager updateTaskWithId:taskId stageAtIndex:kOptiFineStageInstaller status:PLTaskStageStatusRunning];
    [optiManager updateTaskWithId:taskId stageAtIndex:kOptiFineStageInstaller progress:-1
                                 message:[NSString stringWithFormat:localize(@"i18n_str_242", nil), optiType, optiPatch]];
    [optiManager updateTaskWithId:taskId currentStageIndex:kOptiFineStageInstaller];

    __weak typeof(self) weakSelf = self;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 1. 下载 OptiFine jar
        // 阶段6修复（参照 FCL）：使用带 User-Agent 的 NSURLSession 同步下载替代 NSData dataWithContentsOfURL:
        // BMCLAPI 部分镜像源（特别是 CurseForge/optifine 转发）受 Cloudflare 保护，
        // 默认 UA 会被拦截返回 403。必须使用浏览器 UA。
        NSString *bmclURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@/%@/%@", gameVersion, optiType, optiPatch];
        NSError *downloadError = nil;
        NSData *jarData = [self downloadDataWithURLString:bmclURL error:&downloadError];

        // fallback 官方源
        if ((!jarData || downloadError) && filename.length > 0) {
            NSString *officialURL = [NSString stringWithFormat:@"https://optifine.net/downloadx?f=%@", filename];
            NSError *officialError = nil;
            NSData *officialData = [self downloadDataWithURLString:officialURL error:&officialError];
            if (officialData && !officialError) {
                jarData = officialData;
                downloadError = nil;
            }
        }

        if (!jarData || downloadError) {
            [optiManager updateTaskWithId:taskId stageAtIndex:kOptiFineStageInstaller status:PLTaskStageStatusFailed];
            [optiManager updateTaskWithId:taskId stageAtIndex:kOptiFineStageInstaller progress:0 message:downloadError.localizedDescription];
            NSError *err = [NSError errorWithDomain:@"OptiFineInstall" code:1 userInfo:@{NSLocalizedDescriptionKey: downloadError.localizedDescription ?: localize(@"i18n_str_239", nil)}];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskId completedWithError:err];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf finishInstallerProgressWithError:[NSString stringWithFormat:localize(@"i18n_str_243", nil), downloadError.localizedDescription ?: localize(@"i18n_str_97", nil)]];
            });
            return;
        }

        // jar 下载完成：阶段0 完成，阶段1 跳过，阶段2（写入版本文件）进行中
        [optiManager updateTaskWithId:taskId stageAtIndex:kOptiFineStageInstaller status:PLTaskStageStatusCompleted];
        [optiManager updateTaskWithId:taskId stageAtIndex:kOptiFineStageResolve status:PLTaskStageStatusSkipped];
        [optiManager updateTaskWithId:taskId stageAtIndex:kOptiFineStageInstall status:PLTaskStageStatusRunning];
        [optiManager updateTaskWithId:taskId stageAtIndex:kOptiFineStageInstall progress:0 message:localize(@"i18n_str_244", nil)];
        [optiManager updateTaskWithId:taskId currentStageIndex:kOptiFineStageInstall];
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId progress:0.5 totalBytes:-1 downloadedBytes:0];

        // 2. 创建版本目录
        const char *env = getenv("POJAV_GAME_DIR");
        NSString *gameDir = env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
        NSString *versionDir = [gameDir stringByAppendingPathComponent:[NSString stringWithFormat:@"versions/%@", versionId]];
        [[NSFileManager defaultManager] createDirectoryAtPath:versionDir withIntermediateDirectories:YES attributes:nil error:nil];

        // 3. 写入 jar 文件到 libraries 目录（参照 FCL OptiFineInstallTask / HMCL OptiFineInstallTask）
        // OptiFine 使用 launchwrapper 作为入口，通过 tweaker 加载，jar 不再作为 client.jar
        // 而是作为普通库条目写入 libraries/optifine/OptiFine/{gameVersion}/{versionId}.jar
        // 这样做的目的：
        //   1. 让原版 client.jar 仍可被 inheritsFrom 引用（保留原版 jar）
        //   2. OptiFine jar 作为 launchwrapper 的 tweakClass 输入
        //   3. mainClass 设为 net.minecraft.launchwrapper.Launcher，通过 --tweakClass optifine.OptiFineTweaker 加载
        NSString *optifineJarPath = [NSString stringWithFormat:@"optifine/OptiFine/%@/%@.jar", gameVersion, versionId];
        NSString *optifineJarAbsPath = [NSString stringWithFormat:@"%s/libraries/%@", getenv("POJAV_GAME_DIR"), optifineJarPath];
        // 确保 jar 文件写入到正确的 libraries 路径
        NSString *jarDir = [optifineJarAbsPath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:jarDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSError *writeError = nil;
        [jarData writeToFile:optifineJarAbsPath options:NSDataWritingAtomic error:&writeError];
        if (writeError) {
            [optiManager updateTaskWithId:taskId stageAtIndex:kOptiFineStageInstall status:PLTaskStageStatusFailed];
            [optiManager updateTaskWithId:taskId stageAtIndex:kOptiFineStageInstall progress:0 message:writeError.localizedDescription];
            NSError *err = [NSError errorWithDomain:@"OptiFineInstall" code:2 userInfo:@{NSLocalizedDescriptionKey: writeError.localizedDescription}];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskId completedWithError:err];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf finishInstallerProgressWithError:[NSString stringWithFormat:localize(@"i18n_str_245", nil), writeError.localizedDescription]];
            });
            return;
        }

        // 4. 创建 version.json（参照 FCL OptiFineInstallTask / HMCL OptiFineInstallTask）
        // OptiFine 使用 launchwrapper 作为入口，通过 tweaker 加载
        // 关键：mainClass 必须是 net.minecraft.launchwrapper.Launcher
        //       必须添加 --tweakClass optifine.OptiFineTweaker
        //       OptiFine jar 必须加入 libraries 列表
        NSDictionary *versionJson = @{
            @"id": versionId,
            @"inheritsFrom": gameVersion,
            @"type": @"release",
            @"mainClass": @"net.minecraft.launchwrapper.Launcher",
            @"minecraftArguments": @"--username ${auth_player_name} --version ${version_name} --gameDir ${game_directory} --assetsDir ${assets_root} --assetIndex ${assets_index_name} --uuid ${auth_uuid} --accessToken ${auth_access_token} --userType ${user_type} --versionType ${version_type} --tweakClass optifine.OptiFineTweaker",
            @"libraries": @[
                @{
                    @"name": [NSString stringWithFormat:@"optifine:OptiFine:%@", gameVersion],
                    @"downloads": @{
                        @"artifact": @{
                            @"path": optifineJarPath,
                            @"url": @"",  // 已下载，URL 留空
                            @"size": @(jarData.length),
                            @"sha1": @""
                        }
                    }
                }
            ],
            @"jar": gameVersion,  // 使用原版 jar
            @"minimumLauncherVersion": @21
        };
        NSString *jsonPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", versionId]];
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:versionJson options:NSJSONWritingPrettyPrinted error:nil];
        [jsonData writeToFile:jsonPath options:NSDataWritingAtomic error:nil];

        // 4.1 确保父版本（vanilla）的 version JSON 已存在
        NSString *parentJsonPath = [gameDir stringByAppendingPathComponent:
                                    [NSString stringWithFormat:@"versions/%@/%@.json", gameVersion, gameVersion]];
        if (![[NSFileManager defaultManager] fileExistsAtPath:parentJsonPath]) {
            // 父版本不存在，提示用户先安装原版
            NSError *err = [NSError errorWithDomain:@"OptiFineInstall" code:3
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_246", nil), gameVersion, gameVersion]}];
            [optiManager updateTaskWithId:taskId stageAtIndex:kOptiFineStageInstall status:PLTaskStageStatusFailed];
            [optiManager updateTaskWithId:taskId stageAtIndex:kOptiFineStageInstall progress:0 message:err.localizedDescription];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskId completedWithError:err];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf finishInstallerProgressWithError:err.localizedDescription];
            });
            return;
        }

        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId progress:0.85 totalBytes:-1 downloadedBytes:0];
        [optiManager updateTaskWithId:taskId stageAtIndex:kOptiFineStageInstall progress:0.7 message:localize(@"i18n_str_247", nil)];

        // 5. 注册 profile
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            NSMutableDictionary *profile = [NSMutableDictionary dictionary];
            profile[@"name"] = versionId;
            profile[@"lastVersionId"] = versionId;
            profile[@"gameDir"] = @".";
            profile[@"type"] = @"custom";
            profile[@"created"] = [NSDate date].description;
            [PLProfiles.current saveProfile:profile withName:versionId];
            PLProfiles.current.selectedProfileName = versionId;

            [optiManager updateTaskWithId:taskId stageAtIndex:kOptiFineStageInstall status:PLTaskStageStatusCompleted];
            [optiManager updateTaskWithId:taskId stageAtIndex:kOptiFineStageInstall progress:1 message:nil];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskId completedWithError:nil];
            [strongSelf finishInstallerProgressWithSuccess:[NSString stringWithFormat:localize(@"i18n_str_248", nil), versionId, versionId]];
        });
    });
}

#pragma mark - NeoForge Installation

- (void)installNeoForge:(NSString *)gameVersion loaderVersion:(NSString *)loaderVersion {
    ForgeInstallViewController *neoForgeVC = [[ForgeInstallViewController alloc] init];
    neoForgeVC.gameVersion = gameVersion;
    neoForgeVC.isNeoForge = YES;
    // ModLoaderInstallViewController 已选好版本，传入以跳过重复的版本列表 UI
    neoForgeVC.presetVersionString = loaderVersion;

    __weak typeof(self) weakSelf = self;
    void (^completion)(BOOL, NSString *, id) = ^(BOOL success, NSString *profileName, id resultOrError) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // 解析 ForgeInstallViewController 打包的回调结果（无论成败都需要先解析）
        NSInteger selectedScheme = 0;
        NSString *filePath = nil;
        if ([resultOrError isKindOfClass:[NSDictionary class]]) {
            NSDictionary *result = (NSDictionary *)resultOrError;
            filePath = result[@"filePath"];
            selectedScheme = [result[@"selectedScheme"] integerValue];
        } else if ([resultOrError isKindOfClass:[NSString class]]) {
            filePath = (NSString *)resultOrError;
        }

        // 先 pop 掉 NeoForge 安装器选择页；pop 完成后再走后续流程，避免动画期间 present/push 失败
        void (^continuation)(void) = ^{
            __strong typeof(weakSelf) strongSelf2 = weakSelf;
            if (!strongSelf2) return;

            if (!success) {
                [strongSelf2 handleInstallerDownloadResultWithVendorName:@"NeoForge"
                                                              gameVersion:gameVersion
                                                              profileName:profileName
                                                            resultOrError:resultOrError
                                                             installAction:nil];
                return;
            }

            if (selectedScheme == 1 && filePath.length > 0) {
                // 直装方案（redesign-download-ui Phase 3 Task 3.2/3.3）：注册任务 + 阶段上报 +
                // 自动弹统一进度页，NeoForgeDirectInstaller 的 progress 回调桥接为阶段上报
                NSLog(@"[NeoForgeDirect] DownloadViewController: starting direct install with unified progress UI");
                // 阶段下标与 PLTaskStagesForgeExtra() 一致：下载安装器→解析依赖→安装加载器
                static const NSUInteger kNeoStageInstaller = 0;
                static const NSUInteger kNeoStageResolve = 1;
                static const NSUInteger kNeoStageInstall = 2;

                NSString *neoTaskId = [strongSelf2 registerInstallerTaskWithResourceName:[NSString stringWithFormat:@"neoforge-%@-%@", gameVersion, profileName]
                                                                                displayName:[NSString stringWithFormat:@"NeoForge %@ (%@)", profileName ?: @"", gameVersion]
                                                                                      stages:PLTaskStagesForgeExtra()];
                if (!neoTaskId) {
                    [strongSelf2 showError:localize(@"i18n_str_249", nil)];
                    return;
                }
                DownloadTaskManager *neoManager = [DownloadTaskManager sharedManager];
                // 阶段0 下载安装器：installer jar 已由 ForgeInstallViewController 下载完成，直接标记
                [neoManager updateTaskWithId:neoTaskId stageAtIndex:kNeoStageInstaller status:PLTaskStageStatusCompleted];
                // 阶段1 解析依赖：解压内嵌 maven / 解析依赖（installer 进度 0~0.2）
                [neoManager updateTaskWithId:neoTaskId stageAtIndex:kNeoStageResolve status:PLTaskStageStatusRunning];
                [neoManager updateTaskWithId:neoTaskId stageAtIndex:kNeoStageResolve progress:0 message:nil];
                [neoManager updateTaskWithId:neoTaskId currentStageIndex:kNeoStageResolve];

                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    NSError *directError = nil;
                    BOOL installed = [NeoForgeDirectInstaller installNeoForgeFromInstaller:filePath
                                                                                   versionId:profileName
                                                                                    progress:^(double progress, NSString *stageMessage) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            // 阶段桥接（Task 3.3，不改安装器回调签名）：
                            // p<0.2 解析依赖；p>=0.2 安装加载器（映射回 0~1 阶段进度）
                            if (progress < 0.2) {
                                [neoManager updateTaskWithId:neoTaskId
                                                   stageAtIndex:kNeoStageResolve
                                                      progress:MIN(progress / 0.2, 1.0)
                                                       message:stageMessage];
                            } else {
                                if (progress >= 0.25) {
                                    [neoManager updateTaskWithId:neoTaskId stageAtIndex:kNeoStageResolve status:PLTaskStageStatusCompleted];
                                    [neoManager updateTaskWithId:neoTaskId stageAtIndex:kNeoStageInstall status:PLTaskStageStatusRunning];
                                    [neoManager updateTaskWithId:neoTaskId currentStageIndex:kNeoStageInstall];
                                }
                                double installProgress = MIN((progress - 0.2) / 0.8, 1.0);
                                [neoManager updateTaskWithId:neoTaskId
                                                   stageAtIndex:kNeoStageInstall
                                                      progress:installProgress
                                                       message:stageMessage];
                            }
                        });
                    }
                                                                                       error:&directError];

                    dispatch_async(dispatch_get_main_queue(), ^{
                        __strong typeof(weakSelf) strongSelf3 = weakSelf;
                        if (!strongSelf3) return;
                        if (installed) {
                            [neoManager updateTaskWithId:neoTaskId stageAtIndex:kNeoStageResolve status:PLTaskStageStatusCompleted];
                            [neoManager updateTaskWithId:neoTaskId stageAtIndex:kNeoStageInstall status:PLTaskStageStatusCompleted];
                            [neoManager updateTaskWithId:neoTaskId stageAtIndex:kNeoStageInstall progress:1 message:nil];
                            [[DownloadTaskManager sharedManager] setTaskWithId:neoTaskId completedWithError:nil];
                            [strongSelf3 finishInstallerProgressWithSuccess:[NSString stringWithFormat:localize(@"i18n_str_250", nil), profileName ?: gameVersion]];
                        } else {
                            [neoManager updateTaskWithId:neoTaskId stageAtIndex:kNeoStageInstall status:PLTaskStageStatusFailed];
                            [neoManager updateTaskWithId:neoTaskId stageAtIndex:kNeoStageInstall progress:0 message:directError.localizedDescription];
                            NSError *err = [NSError errorWithDomain:@"NeoForgeDirectInstall" code:1 userInfo:@{NSLocalizedDescriptionKey: directError.localizedDescription ?: localize(@"i18n_str_97", nil)}];
                            [[DownloadTaskManager sharedManager] setTaskWithId:neoTaskId completedWithError:err];
                            [strongSelf3 finishInstallerProgressWithError:[NSString stringWithFormat:localize(@"i18n_str_251", nil), directError.localizedDescription ?: localize(@"i18n_str_97", nil)]];
                        }
                    });
                });
                return;
            }

            // 原版方案（运行安装器）
            [strongSelf2 handleInstallerDownloadResultWithVendorName:@"NeoForge"
                                                          gameVersion:gameVersion
                                                          profileName:profileName
                                                        resultOrError:resultOrError
                                                         installAction:^{
                [strongSelf2 showSuccessMessage:[NSString stringWithFormat:localize(@"i18n_str_252", nil), profileName ?: gameVersion]];
            }];
        };

        if (strongSelf.navigationController.topViewController != strongSelf) {
            [strongSelf.navigationController popViewControllerAnimated:YES];
            // 等待 pop 动画结束后再触发后续 present / push，避免动画冲突
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), continuation);
        } else {
            continuation();
        }
    };
    neoForgeVC.completionHandler = completion;

    // 直接 push 到中间内容区，不再用 FormSheet 弹窗
    [self.navigationController pushViewController:neoForgeVC animated:YES];
}

- (void)showSuccessMessage:(NSString *)message {
    // 在内容区显示成功提示，替代弹窗
    [InlineMessageView showInViewController:self
                                       title:localize(@"i18n_str_253", nil)
                                    message:message
                                       type:InlineMessageTypeSuccess];
}

#pragma mark - Mod Download Helper (Shared)

- (void)downloadModVersion:(ModVersion *)version modInfo:(NSDictionary *)modInfo completion:(void (^)(BOOL success, NSError *error))completion {
    NSString *downloadURL = version.primaryFile[@"url"];
    NSString *filename = version.primaryFile[@"filename"];
    
    if (!downloadURL || downloadURL.length == 0) {
        if (completion) completion(NO, [NSError errorWithDomain:@"DownloadError" code:4 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_254", nil)}]);
        return;
    }
    
    NSString *modsDir = [self currentInstanceModsPath];
    NSString *savePath = [modsDir stringByAppendingPathComponent:filename];
    
    NSURL *url = [NSURL URLWithString:downloadURL];
    NSURLSessionDownloadTask *downloadTask = [[NSURLSession sharedSession] downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        if (error || !location) {
            if (completion) completion(NO, error);
            return;
        }
        
        [[NSFileManager defaultManager] removeItemAtPath:savePath error:nil];
        NSError *moveError;
        [[NSFileManager defaultManager] moveItemAtPath:location.path toPath:savePath error:&moveError];
        
        if (completion) completion(moveError == nil, moveError);
    }];
    
    [downloadTask resume];
}

#pragma mark - Modpack Installation

- (void)openImportModpackView {
    // 修复: 改为 push 到中间内容区，与其他下载子流程一致，不再 FormSheet 弹窗
    ModpackImportViewController *importVC = [[ModpackImportViewController alloc] init];
    [self.navigationController pushViewController:importVC animated:YES];
}

- (void)installModpack:(UIButton *)sender {
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:sender.tag inSection:0];
    [self installModpackAtIndexPath:indexPath];
}

- (void)installModpackAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *modpack = self.modpackList[indexPath.row];

    // 仿 FCL/ZL2：整合包也使用独立的版本选择页（复用 ModVersionViewController + AssetDetailHeaderView）
    // 替代原有的 ActionSheet 选版本方式，补齐项目封面图/描述/作者/下载量/标签等信息显示
    ModItem *modItem = [[ModItem alloc] initWithOnlineData:modpack];

    ModVersionViewController *versionVC = [[ModVersionViewController alloc] init];
    versionVC.modItem = modItem;
    versionVC.initialSource = modItem.apiSource;
    versionVC.delegate = self;
    versionVC.title = modItem.displayName;
    // FCL 风格：传入当前 profile 的偏好版本和加载器，自动选中匹配 chip 并置顶
    versionVC.preferredGameVersion = [self currentProfileMinecraftVersion];
    versionVC.preferredLoader = [self currentProfileLoader];

    // 标记当前为整合包下载类型，版本选择回调时走整合包安装流程（而非 Mod 下载流程）
    self.pendingDownloadType = @"modpack";
    self.pendingModpackDict = modpack;

    // 在中间内容区 push 显示，与 Mod/Shader/ResourcePack 等保持一致的交互
    [self.navigationController pushViewController:versionVC animated:YES];
}

- (void)startModpackInstallation:(ModVersion *)version modpack:(NSDictionary *)modpack {
    NSString *downloadURL = version.primaryFile[@"url"];
    if (!downloadURL) {
        [self showError:localize(@"i18n_str_254", nil)];
        return;
    }

    // redesign-download-ui Phase 3 Task 3.2：删除私有 InstallerProgressViewController，
    // 改为注册 Modpack 任务 + PLTaskStagesModpack() 6 阶段 + autoPresentDetail
    // 自动弹出统一进度页（PLTaskProgressViewController）。
    // 阶段映射：0=解析整合包(含 zip 下载) 1=解压文件(parse 内部完成)
    //           2=下载依赖文件(导入 p<0.3) 3=安装加载器(0.3-0.7) 4=下载游戏文件(原版预装) 5=完成配置(0.7-1.0)
    NSURL *url = [NSURL URLWithString:downloadURL];
    NSString *downloadSource = getPrefObject(@"general.download_source") ?: @"official";
    __block DownloadTaskItem *taskItem = nil;

    // 关键修复（参照 FCL/ZL2 整合包下载容错）：原实现单次下载无重试，
    // 网络偶发抖动或镜像源 5xx 会导致整个整合包下载失败。改为最多 3 次重试。
    __block NSInteger downloadAttempt = 0;
    __block NSURL *downloadLocation = nil;
    __block NSError *downloadError = nil;
    __weak typeof(self) weakSelf = self;

    void (^attemptDownload)(void) = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        downloadAttempt++;
        NSLog(@"[ModpackDownload] Modpack download attempt %ld: %@", (long)downloadAttempt, downloadURL);
        NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                if (error || !location) {
                    downloadError = error ?: [NSError errorWithDomain:@"DownloadError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Download returned empty data"}];
                    NSLog(@"[ModpackDownload] Attempt %ld failed: %@", (long)downloadAttempt, downloadError.localizedDescription);
                    if (downloadAttempt < 3) {
                        // 间隔 1.5s 后重试，避免连续请求触发限流
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            attemptDownload();
                        });
                    } else {
                        [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId
                                                              stageAtIndex:0
                                                                  status:PLTaskStageStatusFailed];
                        [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId completedWithError:downloadError];
                        [strongSelf2 showError:[NSString stringWithFormat:@"Modpack download failed (retried %ld times): %@", (long)downloadAttempt, downloadError.localizedDescription ?: @"Unknown error"]];
                    }
                    return;
                }
                downloadLocation = location;
                downloadError = nil;

                // 移动到临时文件
                NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%@.mrpack", modpack[@"id"] ?: @"modpack", [[NSUUID UUID] UUIDString]]];
                [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
                NSError *moveError = nil;
                [[NSFileManager defaultManager] moveItemAtPath:downloadLocation.path toPath:tempPath error:&moveError];
                if (moveError) {
                    if (downloadAttempt < 3) {
                        NSLog(@"[ModpackDownload] File move failed, retrying: %@", moveError.localizedDescription);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            attemptDownload();
                        });
                        return;
                    }
                    [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId
                                                              stageAtIndex:0
                                                                  status:PLTaskStageStatusFailed];
                    [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId completedWithError:moveError];
                    [strongSelf2 showError:moveError.localizedDescription];
                    return;
                }

                // zip 下载完成 → 进入解析阶段（任务整体保持 Downloading，导入完成才标记 Completed）
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId
                                                          stageAtIndex:0
                                                               progress:-1
                                                              message:localize(@"i18n_str_255", nil)];
                ModpackImportService *importService = [[ModpackImportService alloc] init];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSError *parseError = nil;
                NSDictionary *modpackInfo = [importService parseModpackAtURL:[NSURL fileURLWithPath:tempPath] error:&parseError];
                if (!modpackInfo) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId
                                                                  stageAtIndex:0
                                                                      status:PLTaskStageStatusFailed];
                        [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId completedWithError:parseError];
                        [self showError:parseError.localizedDescription ?: localize(@"i18n_str_256", nil)];
                    });
                    return;
                }
                // 用在线 modpack 信息补充 (title、icon 等)
                NSMutableDictionary *mutableInfo = [modpackInfo mutableCopy];
                if (!mutableInfo[@"name"] || [mutableInfo[@"name"] isEqualToString:[tempPath.lastPathComponent stringByDeletingPathExtension]]) {
                    mutableInfo[@"name"] = modpack[@"title"] ?: mutableInfo[@"name"];
                }
                if (modpack[@"imageUrl"]) {
                    // 不强制下载 icon，保留原整合包内的
                }

                // 阶段14增强：参照 FCL/ZL2/HMCL，安装整合包前先安装对应的原版 Minecraft
                // ModpackImportService 只下载 mod 文件和安装加载器，不下载原版 client.jar/libraries/assets
                // 若不预装原版，启动时 Java 端 Tools.getVersionInfo() 会因 FileNotFoundException 崩溃
                NSString *mcVersion = mutableInfo[@"minecraftVersion"];
                if (![mcVersion isKindOfClass:[NSString class]] || mcVersion.length == 0) {
                    mcVersion = mutableInfo[@"dependencies"][@"minecraft"];
                }
                if ([mcVersion isKindOfClass:[NSString class]] && mcVersion.length > 0) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        // 解析 + 解压完成，进入原版预装（阶段4 下载游戏文件）
                        [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId
                                                                  stageAtIndex:0 status:PLTaskStageStatusCompleted];
                        [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId
                                                                  stageAtIndex:1 status:PLTaskStageStatusCompleted];
                        [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId
                                                                  stageAtIndex:4 status:PLTaskStageStatusRunning];
                        [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId
                                                                  stageAtIndex:4
                                                                       progress:-1
                                                                      message:[NSString stringWithFormat:localize(@"i18n_str_257", nil), mcVersion]];
                        [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId currentStageIndex:4];

                        // 调用原版预安装（ensureVanillaInstalled 会检查是否已安装，已安装则直接跳过）
                        NSDictionary *vanillaVersion = @{@"id": mcVersion};
                        __weak typeof(self) weakSelf = self;
                        [self ensureVanillaInstalled:vanillaVersion completion:^(BOOL vanillaSuccess) {
                            __strong typeof(weakSelf) strongSelf = weakSelf;
                            if (!strongSelf) return;
                            if (!vanillaSuccess) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId
                                                                              stageAtIndex:4
                                                                                  status:PLTaskStageStatusFailed];
                                    [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId
                                                                    completedWithError:[NSError errorWithDomain:@"DownloadError" code:-1
                                                                                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_258", nil), mcVersion]}]];
                                    [strongSelf showError:[NSString stringWithFormat:localize(@"i18n_str_194", nil), mcVersion]];
                                });
                                return;
                            }
                            // 原版安装完成，继续导入整合包（进入阶段2 下载依赖文件）
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId
                                                                          stageAtIndex:4 status:PLTaskStageStatusCompleted];
                                [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId
                                                                          stageAtIndex:2 status:PLTaskStageStatusRunning];
                                [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId
                                                                          stageAtIndex:2
                                                                               progress:-1
                                                                              message:localize(@"i18n_str_259", nil)];
                                [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId currentStageIndex:2];
                            });
                            // 在后台线程执行整合包导入
                            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                                [strongSelf importModpackWithService:importService info:mutableInfo taskId:taskItem.taskId tempPath:tempPath];
                            });
                        }];
                    });
                } else {
                    // 无法提取游戏版本，跳过原版预安装（阶段4 标记 Skipped），直接导入
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId
                                                                  stageAtIndex:0 status:PLTaskStageStatusCompleted];
                        [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId
                                                                  stageAtIndex:1 status:PLTaskStageStatusCompleted];
                        [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId
                                                                  stageAtIndex:4 status:PLTaskStageStatusSkipped];
                        [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId
                                                                  stageAtIndex:2 status:PLTaskStageStatusRunning];
                        [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId currentStageIndex:2];
                    });
                    [self importModpackWithService:importService info:mutableInfo taskId:taskItem.taskId tempPath:tempPath];
                }
            });
        });
    }];

        // 注册到下载任务管理器（每次重试均重新注册，taskId 不变因为 taskItem 是外层 __block）
        if (!taskItem) {
            taskItem = [[DownloadTaskManager sharedManager]
                registerTaskWithResourceType:DownloadTaskResourceTypeModpack
                                resourceName:modpack[@"title"] ?: @"modpack"
                                 displayName:modpack[@"title"] ?: localize(@"i18n_str_118", nil)
                              downloadSource:downloadSource
                                     rawTask:task
                              supportsResume:YES
                                     iconURL:modpack[@"imageUrl"]];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId stages:PLTaskStagesModpack()];
            [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId
                                                      stageAtIndex:0
                                                          status:PLTaskStageStatusRunning];
            [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId
                                                      stageAtIndex:0
                                                           progress:-1
                                                          message:localize(@"i18n_str_260", nil)];
            taskItem.autoPresentDetail = YES;
            [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId state:DownloadTaskStateDownloading];
        }

        [task resume];
    };

    // 启动首次下载尝试
    attemptDownload();
}

/// 阶段14：整合包导入辅助方法
/// 参照 FCL/ZL2/HMCL：原版预安装完成后（或跳过后），执行实际的整合包导入流程。
/// 包含：调用 ModpackImportService 下载 mod 文件、安装加载器、写入配置，
/// 并通过 DownloadTaskManager 阶段上报实时驱动统一进度页（redesign-download-ui Phase 3）。
/// 导入完成后清理临时文件，并在主线程展示成功/失败结果。
/// 注：此方法应在后台线程调用（QOS_CLASS_USER_INITIATED），进度回调内部自行 dispatch 到主线程。
/// ModpackImportService 进度区间：0.1-0.3=下载mods(阶段2), 0.3-0.7=安装加载器(阶段3), 0.7-1.0=写配置(阶段5)
- (void)importModpackWithService:(ModpackImportService *)importService
                            info:(NSDictionary *)info
                           taskId:(NSString *)taskId
                        tempPath:(NSString *)tempPath {
    NSError *importError = nil;
    __weak typeof(self) weakSelf = self;
    BOOL success = [importService importModpack:info
                                       progress:^(double p, NSString *stage) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
            if (p < 0.3) {
                // 阶段2 下载依赖文件进行中
                [manager updateTaskWithId:taskId
                              stageAtIndex:2
                                   progress:p / 0.3
                                  message:stage];
            } else if (p < 0.7) {
                // 阶段2 完成，阶段3 安装加载器进行中
                [manager updateTaskWithId:taskId stageAtIndex:2 status:PLTaskStageStatusCompleted];
                [manager updateTaskWithId:taskId
                              stageAtIndex:3
                                   progress:(p - 0.3) / 0.4
                                  message:stage];
                [manager updateTaskWithId:taskId currentStageIndex:3];
            } else if (p < 1.0) {
                // 阶段3 完成，阶段5 完成配置进行中
                [manager updateTaskWithId:taskId stageAtIndex:3 status:PLTaskStageStatusCompleted];
                [manager updateTaskWithId:taskId
                              stageAtIndex:5
                                   progress:(p - 0.7) / 0.3
                                  message:stage];
                [manager updateTaskWithId:taskId currentStageIndex:5];
            } else {
                // 全部阶段完成
                [manager updateTaskWithId:taskId stageAtIndex:2 status:PLTaskStageStatusCompleted];
                [manager updateTaskWithId:taskId stageAtIndex:3 status:PLTaskStageStatusCompleted];
                [manager updateTaskWithId:taskId stageAtIndex:5 status:PLTaskStageStatusCompleted];
            }
        });
    } error:&importError];

    // 清理临时文件
    [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];

    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
        if (success) {
            [manager setTaskWithId:taskId completedWithError:nil];
            NSString *loader = info[@"loader"];
            NSString *msg = [NSString stringWithFormat:localize(@"i18n_str_261", nil), info[@"name"]];
            if ([loader isEqualToString:@"Forge"] || [loader isEqualToString:@"NeoForge"]) {
                msg = [msg stringByAppendingFormat:localize(@"i18n_str_262", nil), loader, info[@"loaderVersion"]];
            }
            [strongSelf showSuccessMessage:msg];
        } else {
            // 失败时将当前运行中的阶段（2/3/5）标记为 Failed
            [manager updateTaskWithId:taskId stageAtIndex:2 status:PLTaskStageStatusFailed];
            [manager updateTaskWithId:taskId stageAtIndex:3 status:PLTaskStageStatusFailed];
            [manager updateTaskWithId:taskId stageAtIndex:5 status:PLTaskStageStatusFailed];
            [manager setTaskWithId:taskId completedWithError:importError];
            [strongSelf showError:importError.localizedDescription ?: localize(@"i18n_str_263", nil)];
        }
    });
}

// installModpackFromFile:modpack: 已删除（redesign-download-ui Phase 3 Task 3.2 / Phase 6 规划）：
// 该方法无任何调用方（在线下载流程统一走 startModpackInstallation:modpack: → ModpackImportService，
// 本地导入走 ModpackImportViewController → ModpackImportService）。

#pragma mark - UITableView DataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (tableView == self.modTableView) {
        return self.modList.count + (self.hasMoreMods ? 1 : 0);
    } else if (tableView == self.shaderTableView) {
        return self.shaderList.count + (self.hasMoreShaders ? 1 : 0);
    } else if (tableView == self.modpackTableView) {
        return self.modpackList.count + (self.hasMoreModpacks ? 1 : 0);
    } else if (tableView == self.resourcepackTableView) {
        return self.resourcepackList.count + (self.hasMoreResourcepacks ? 1 : 0);
    } else if (tableView == self.datapackTableView) {
        return self.datapackList.count + (self.hasMoreDatapacks ? 1 : 0);
    } else if (tableView == self.worldTableView) {
        return self.worldList.count + (self.hasMoreWorlds ? 1 : 0);
    }
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView == self.modTableView && indexPath.row == self.modList.count && self.hasMoreMods) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LoadingCell"];
        cell.textLabel.text = localize(@"i18n_str_264", nil);
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.backgroundColor = [UIColor clearColor];
        return cell;
    }

    if (tableView == self.shaderTableView && indexPath.row == self.shaderList.count && self.hasMoreShaders) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LoadingCell"];
        cell.textLabel.text = localize(@"i18n_str_264", nil);
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.backgroundColor = [UIColor clearColor];
        return cell;
    }

    if (tableView == self.modpackTableView && indexPath.row == self.modpackList.count && self.hasMoreModpacks) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LoadingCell"];
        cell.textLabel.text = localize(@"i18n_str_264", nil);
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.backgroundColor = [UIColor clearColor];
        return cell;
    }

    if (tableView == self.resourcepackTableView && indexPath.row == self.resourcepackList.count && self.hasMoreResourcepacks) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LoadingCell"];
        cell.textLabel.text = localize(@"i18n_str_264", nil);
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.backgroundColor = [UIColor clearColor];
        return cell;
    }

    if (tableView == self.datapackTableView && indexPath.row == self.datapackList.count && self.hasMoreDatapacks) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LoadingCell"];
        cell.textLabel.text = localize(@"i18n_str_264", nil);
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.backgroundColor = [UIColor clearColor];
        return cell;
    }

    if (tableView == self.worldTableView && indexPath.row == self.worldList.count && self.hasMoreWorlds) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LoadingCell"];
        cell.textLabel.text = localize(@"i18n_str_264", nil);
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.backgroundColor = [UIColor clearColor];
        return cell;
    }

    ModernAssetCell *cell;
    if (tableView == self.modTableView) {
        cell = [tableView dequeueReusableCellWithIdentifier:@"ModCell" forIndexPath:indexPath];
        NSDictionary *mod = self.modList[indexPath.row];
        [cell configureWithMod:mod];
        [cell.downloadButton addTarget:self action:@selector(downloadMod:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
    } else if (tableView == self.shaderTableView) {
        cell = [tableView dequeueReusableCellWithIdentifier:@"ShaderCell" forIndexPath:indexPath];
        NSDictionary *shader = self.shaderList[indexPath.row];
        [cell configureWithShader:shader];
        [cell.downloadButton addTarget:self action:@selector(downloadShader:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
    } else if (tableView == self.resourcepackTableView) {
        cell = [tableView dequeueReusableCellWithIdentifier:@"ResourcepackCell" forIndexPath:indexPath];
        NSDictionary *resourcepack = self.resourcepackList[indexPath.row];
        [cell configureWithResourcepack:resourcepack];
        [cell.downloadButton addTarget:self action:@selector(downloadResourcepack:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
    } else if (tableView == self.datapackTableView) {
        cell = [tableView dequeueReusableCellWithIdentifier:@"DatapackCell" forIndexPath:indexPath];
        NSDictionary *datapack = self.datapackList[indexPath.row];
        [cell configureWithDatapack:datapack];
        [cell.downloadButton addTarget:self action:@selector(downloadDatapack:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
    } else if (tableView == self.worldTableView) {
        cell = [tableView dequeueReusableCellWithIdentifier:@"WorldCell" forIndexPath:indexPath];
        NSDictionary *world = self.worldList[indexPath.row];
        [cell configureWithWorld:world];
        [cell.downloadButton addTarget:self action:@selector(downloadWorld:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
    } else {
        cell = [tableView dequeueReusableCellWithIdentifier:@"ModpackCell" forIndexPath:indexPath];
        NSDictionary *modpack = self.modpackList[indexPath.row];
        [cell configureWithModpack:modpack];
        [cell.downloadButton addTarget:self action:@selector(installModpack:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView == self.modTableView && indexPath.row == self.modList.count - 5 && self.hasMoreMods && !self.isLoadingMods) {
        [self loadModList];
    }

    if (tableView == self.shaderTableView && indexPath.row == self.shaderList.count - 5 && self.hasMoreShaders && !self.isLoadingShaders) {
        [self loadShaderList];
    }

    if (tableView == self.modpackTableView && indexPath.row == self.modpackList.count - 5 && self.hasMoreModpacks && !self.isLoadingModpacks) {
        [self loadModpackList];
    }

    if (tableView == self.resourcepackTableView && indexPath.row == self.resourcepackList.count - 5 && self.hasMoreResourcepacks && !self.isLoadingResourcepacks) {
        [self loadResourcePackList];
    }

    if (tableView == self.datapackTableView && indexPath.row == self.datapackList.count - 5 && self.hasMoreDatapacks && !self.isLoadingDatapacks) {
        [self loadDataPackList];
    }

    if (tableView == self.worldTableView && indexPath.row == self.worldList.count - 5 && self.hasMoreWorlds && !self.isLoadingWorlds) {
        [self loadWorldList];
    }

    // ===== 图标预取（参照 FCL Glide 的 prefetch + ZL2 Coil 的 enqueue）=====
    // 在 cell 即将显示时，预取后续 5 个 cell 的图标到磁盘缓存。
    // 这样用户滚动列表时，后续 cell 的图标已经在缓存中，可以立即显示，显著减少"图标加载过慢"的感觉。
    // 预取仅下载+缓存，不绑定 imageView，不影响当前显示。
    [self prefetchIconsForTableView:tableView currentIndex:indexPath.row];
}

/// 预取后续 cell 的图标到缓存
/// @param tableView 当前 tableView
/// @param currentIndex 当前显示的 cell 索引
- (void)prefetchIconsForTableView:(UITableView *)tableView currentIndex:(NSInteger)currentIndex {
    // 预取后续 5 个 cell 的图标
    NSInteger prefetchCount = 5;
    NSInteger startIndex = currentIndex + 1;
    NSInteger endIndex = currentIndex + prefetchCount;

    for (NSInteger row = startIndex; row <= endIndex; row++) {
        NSString *iconUrl = nil;

        if (tableView == self.modTableView && row < (NSInteger)self.modList.count) {
            NSDictionary *mod = self.modList[row];
            iconUrl = mod[@"imageUrl"] ?: mod[@"icon_url"];
        } else if (tableView == self.shaderTableView && row < (NSInteger)self.shaderList.count) {
            NSDictionary *shader = self.shaderList[row];
            iconUrl = shader[@"imageUrl"] ?: shader[@"icon_url"];
        } else if (tableView == self.modpackTableView && row < (NSInteger)self.modpackList.count) {
            NSDictionary *modpack = self.modpackList[row];
            iconUrl = modpack[@"imageUrl"] ?: modpack[@"icon_url"];
        } else if (tableView == self.resourcepackTableView && row < (NSInteger)self.resourcepackList.count) {
            NSDictionary *resourcepack = self.resourcepackList[row];
            iconUrl = resourcepack[@"imageUrl"] ?: resourcepack[@"icon_url"];
        } else if (tableView == self.datapackTableView && row < (NSInteger)self.datapackList.count) {
            NSDictionary *datapack = self.datapackList[row];
            iconUrl = datapack[@"imageUrl"] ?: datapack[@"icon_url"];
        } else if (tableView == self.worldTableView && row < (NSInteger)self.worldList.count) {
            NSDictionary *world = self.worldList[row];
            iconUrl = world[@"imageUrl"] ?: world[@"icon_url"];
        }

        if (iconUrl && iconUrl.length > 0) {
            [IconLoader prefetchIconWithURL:iconUrl targetSize:CGSizeMake(56, 56)];
        }
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (tableView == self.modTableView) {
        if (indexPath.row == self.modList.count && self.hasMoreMods) {
            [self loadModList];
            return;
        }
        [self downloadModAtIndexPath:indexPath];
    } else if (tableView == self.shaderTableView) {
        if (indexPath.row == self.shaderList.count && self.hasMoreShaders) {
            [self loadShaderList];
            return;
        }
        [self downloadShaderAtIndexPath:indexPath];
    } else if (tableView == self.resourcepackTableView) {
        if (indexPath.row == self.resourcepackList.count && self.hasMoreResourcepacks) {
            [self loadResourcePackList];
            return;
        }
        [self downloadResourcepackAtIndexPath:indexPath];
    } else if (tableView == self.datapackTableView) {
        if (indexPath.row == self.datapackList.count && self.hasMoreDatapacks) {
            [self loadDataPackList];
            return;
        }
        [self downloadDatapackAtIndexPath:indexPath];
    } else if (tableView == self.worldTableView) {
        if (indexPath.row == self.worldList.count && self.hasMoreWorlds) {
            [self loadWorldList];
            return;
        }
        [self downloadWorldAtIndexPath:indexPath];
    } else if (tableView == self.modpackTableView) {
        if (indexPath.row == self.modpackList.count && self.hasMoreModpacks) {
            [self loadModpackList];
            return;
        }
        [self installModpackAtIndexPath:indexPath];
    }
}

#pragma mark - Download Actions

- (void)downloadMod:(UIButton *)sender {
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:sender.tag inSection:0];
    [self downloadModAtIndexPath:indexPath];
}

- (void)downloadModAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.modList.count) return;

    NSDictionary *mod = self.modList[indexPath.row];
    ModItem *modItem = [[ModItem alloc] initWithOnlineData:mod];

    ModVersionViewController *versionVC = [[ModVersionViewController alloc] init];
    versionVC.modItem = modItem;
    versionVC.initialSource = modItem.apiSource;
    versionVC.delegate = self;
    versionVC.title = modItem.displayName;
    // FCL 风格：传入当前 profile 的偏好版本和加载器，自动选中匹配 chip 并置顶
    versionVC.preferredGameVersion = [self currentProfileMinecraftVersion];
    versionVC.preferredLoader = [self currentProfileLoader];

    // 在中间内容区 push 显示，而非弹窗盖在下载列表之上（与 FCL 安卓一致）
    [self.navigationController pushViewController:versionVC animated:YES];
}

- (void)downloadShader:(UIButton *)sender {
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:sender.tag inSection:0];
    [self downloadShaderAtIndexPath:indexPath];
}

- (void)downloadShaderAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.shaderList.count) return;

    NSDictionary *shader = self.shaderList[indexPath.row];
    ShaderItem *shaderItem = [[ShaderItem alloc] initWithOnlineData:shader];

    ShaderVersionViewController *versionVC = [[ShaderVersionViewController alloc] init];
    versionVC.shaderItem = shaderItem;
    versionVC.initialSource = shaderItem.apiSource;
    versionVC.delegate = self;
    versionVC.title = shaderItem.displayName;
    // FCL 风格：传入当前 profile 的偏好版本和加载器，自动选中匹配 chip 并置顶匹配版本
    // 补齐与 ModVersionViewController 不对称的 preferred 传参（阶段3统一）
    versionVC.preferredGameVersion = [self currentProfileMinecraftVersion];
    versionVC.preferredLoader = [self currentProfileLoader];

    [self.navigationController pushViewController:versionVC animated:YES];
}

- (void)downloadResourcepack:(UIButton *)sender {
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:sender.tag inSection:0];
    [self downloadResourcepackAtIndexPath:indexPath];
}

- (void)downloadResourcepackAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.resourcepackList.count) return;

    NSDictionary *resourcepack = self.resourcepackList[indexPath.row];
    ResourcePackItem *item = [[ResourcePackItem alloc] initWithOnlineData:resourcepack];

    self.pendingDownloadType = @"resourcepack";
    self.pendingResourcePackItem = item;

    AssetVersionViewController *versionVC = [[AssetVersionViewController alloc] init];
    versionVC.assetType = AssetVersionTypeResourcePack;
    versionVC.apiSource = item.apiSource;
    versionVC.projectID = item.onlineID;
    versionVC.projectDisplayName = item.displayName;
    versionVC.delegate = self;
    versionVC.title = item.displayName;
    // 传入项目展示信息（用于详情 header 显示封面图/作者/下载量/标签/描述）
    versionVC.projectIconURL = item.iconURL;
    versionVC.projectAuthor = item.author;
    versionVC.projectDownloads = item.downloads;
    versionVC.projectLikes = item.likes;
    versionVC.projectDescription = item.resourcePackDescription;
    versionVC.projectCategories = item.categories;
    versionVC.projectLastUpdated = item.lastUpdated;
    // FCL 风格：传入当前 profile 的偏好版本，自动选中匹配 chip 并置顶匹配版本（阶段3统一）
    versionVC.preferredGameVersion = [self currentProfileMinecraftVersion];

    [self.navigationController pushViewController:versionVC animated:YES];
}

- (void)downloadDatapack:(UIButton *)sender {
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:sender.tag inSection:0];
    [self downloadDatapackAtIndexPath:indexPath];
}

- (void)downloadDatapackAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.datapackList.count) return;

    NSDictionary *datapack = self.datapackList[indexPath.row];
    DataPackItem *item = [[DataPackItem alloc] initWithOnlineData:datapack];

    self.pendingDownloadType = @"datapack";
    self.pendingDataPackItem = item;

    AssetVersionViewController *versionVC = [[AssetVersionViewController alloc] init];
    versionVC.assetType = AssetVersionTypeDataPack;
    versionVC.apiSource = item.apiSource;
    versionVC.projectID = item.onlineID;
    versionVC.projectDisplayName = item.displayName;
    versionVC.delegate = self;
    versionVC.title = item.displayName;
    // 传入项目展示信息（用于详情 header 显示封面图/作者/下载量/标签/描述）
    versionVC.projectIconURL = item.iconURL;
    versionVC.projectAuthor = item.author;
    versionVC.projectDownloads = item.downloads;
    versionVC.projectLikes = item.likes;
    versionVC.projectDescription = item.dataPackDescription;
    versionVC.projectCategories = item.categories;
    versionVC.projectLastUpdated = item.lastUpdated;
    // FCL 风格：传入当前 profile 的偏好版本，自动选中匹配 chip 并置顶匹配版本（阶段3统一）
    versionVC.preferredGameVersion = [self currentProfileMinecraftVersion];

    [self.navigationController pushViewController:versionVC animated:YES];
}

- (void)downloadWorld:(UIButton *)sender {
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:sender.tag inSection:0];
    [self downloadWorldAtIndexPath:indexPath];
}

- (void)downloadWorldAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.worldList.count) return;

    NSDictionary *world = self.worldList[indexPath.row];
    WorldItem *item = [[WorldItem alloc] initWithOnlineData:world];

    self.pendingDownloadType = @"world";
    self.pendingWorldItem = item;

    AssetVersionViewController *versionVC = [[AssetVersionViewController alloc] init];
    versionVC.assetType = AssetVersionTypeWorld;
    versionVC.apiSource = item.apiSource;
    versionVC.projectID = item.onlineID;
    versionVC.projectDisplayName = item.displayName;
    versionVC.delegate = self;
    versionVC.title = item.displayName;
    // 传入项目展示信息（用于详情 header 显示封面图/作者/下载量/标签/描述）
    versionVC.projectIconURL = item.iconURL;
    versionVC.projectAuthor = item.author;
    versionVC.projectDownloads = item.downloads;
    versionVC.projectLikes = item.likes;
    versionVC.projectDescription = item.worldDescription;
    versionVC.projectCategories = item.categories;
    versionVC.projectLastUpdated = item.lastUpdated;
    // FCL 风格：传入当前 profile 的偏好版本，自动选中匹配 chip 并置顶匹配版本（阶段3统一）
    versionVC.preferredGameVersion = [self currentProfileMinecraftVersion];

    [self.navigationController pushViewController:versionVC animated:YES];
}

#pragma mark - ModVersionViewControllerDelegate

/// 从版本模型 primaryFile 提取 SHA1（Modrinth files[].hashes.sha1 / CurseForge 构造的同等结构）。
/// 结构异常或缺失时返回 nil（保持无校验行为，靠 zip EOCD 兜底）。
static NSString *PLSha1FromPrimaryFile(NSDictionary *primaryFile) {
    NSDictionary *hashes = primaryFile[@"hashes"];
    if (![hashes isKindOfClass:[NSDictionary class]]) return nil;
    NSString *sha1 = hashes[@"sha1"];
    if ([sha1 isKindOfClass:[NSString class]] && sha1.length > 0) return sha1;
    return nil;
}

- (void)modVersionViewController:(ModVersionViewController *)viewController didSelectVersion:(ModVersion *)version {
    NSDictionary *primaryFile = version.primaryFile;
    if (!primaryFile || ![primaryFile[@"url"] isKindOfClass:[NSString class]]) {
        [self showError:localize(@"i18n_str_265", nil)];
        return;
    }

    // 整合包走独立安装流程（下载+解析+导入），与普通 Mod 下载不同
    if ([self.pendingDownloadType isEqualToString:@"modpack"]) {
        NSDictionary *modpack = self.pendingModpackDict;
        self.pendingDownloadType = nil;
        self.pendingModpackDict = nil;
        // 子页面已 push 到导航栈，选完版本后 pop 回下载列表
        [self.navigationController popViewControllerAnimated:YES];
        [self startModpackInstallation:version modpack:modpack];
        return;
    }

    ModItem *itemToDownload = viewController.modItem;
    itemToDownload.selectedVersionDownloadURL = primaryFile[@"url"];
    itemToDownload.fileName = primaryFile[@"filename"] ?: [NSString stringWithFormat:@"%@.jar", itemToDownload.displayName];
    // spec Task 5.1 收尾：版本模型 files[0].hashes.sha1 接到下载调用，启用 SHA1 校验
    itemToDownload.fileSHA1 = PLSha1FromPrimaryFile(primaryFile);

    // 模组下载走 ModService（resourcepack/datapack/world 已改走 AssetVersionViewController）
    self.pendingDownloadType = nil;

    // 子页面已 push 到导航栈，选完版本后 pop 回下载列表
    [self.navigationController popViewControllerAnimated:YES];
    [self startDownloadForModItem:itemToDownload];
}

#pragma mark - AssetVersionViewControllerDelegate

- (void)assetVersionViewController:(AssetVersionViewController *)viewController didSelectVersion:(ModVersion *)version {
    NSDictionary *primaryFile = version.primaryFile;
    if (!primaryFile || ![primaryFile[@"url"] isKindOfClass:[NSString class]]) {
        [self showError:localize(@"i18n_str_265", nil)];
        return;
    }

    NSString *downloadType = self.pendingDownloadType;
    self.pendingDownloadType = nil;

    // 子页面已 push 到导航栈，选完版本后 pop 回下载列表
    [self.navigationController popViewControllerAnimated:YES];

    if ([downloadType isEqualToString:@"resourcepack"]) {
        ResourcePackItem *item = self.pendingResourcePackItem;
        self.pendingResourcePackItem = nil;
        if (!item) return;
        item.selectedVersionDownloadURL = primaryFile[@"url"];
        item.fileName = primaryFile[@"filename"] ?: [NSString stringWithFormat:@"%@.zip", item.displayName];
        // spec Task 5.1 收尾：资源包版本模型（复用 ModVersion）的 sha1 接到下载调用
        item.fileSHA1 = PLSha1FromPrimaryFile(primaryFile);
        [self startDownloadForResourcePackItem:item];
    } else if ([downloadType isEqualToString:@"datapack"]) {
        DataPackItem *item = self.pendingDataPackItem;
        self.pendingDataPackItem = nil;
        if (!item) return;
        item.selectedVersionDownloadURL = primaryFile[@"url"];
        item.fileName = primaryFile[@"filename"] ?: [NSString stringWithFormat:@"%@.zip", item.displayName];
        // spec Task 5.1 收尾：数据包版本模型（复用 ModVersion）的 sha1 接到下载调用
        item.fileSHA1 = PLSha1FromPrimaryFile(primaryFile);
        [self startDownloadForDataPackItem:item];
    } else if ([downloadType isEqualToString:@"world"]) {
        WorldItem *item = self.pendingWorldItem;
        self.pendingWorldItem = nil;
        if (!item) return;
        item.selectedVersionDownloadURL = primaryFile[@"url"];
        [self startDownloadForWorldItem:item];
    }
}

// 下载 Mod（redesign-download-ui Phase 4：进度由 Service 内部注册的下载任务 +
// PLTaskStagesSingleFile 单阶段上报驱动统一进度页，调用方无需管理进度 UI。）
- (void)startDownloadForModItem:(ModItem *)item {
    NSString *profileName = [self effectiveTargetProfileName];
    __weak typeof(self) weakSelf = self;
    [[ModService sharedService] downloadMod:item
                                  toProfile:profileName
                               expectedSHA1:item.fileSHA1
                                   progress:nil
                                   completion:^(NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error) {
                [strongSelf showError:error.localizedDescription];
            } else {
                [strongSelf showSuccessMessage:[NSString stringWithFormat:localize(@"i18n_str_266", nil), item.displayName]];
            }
        });
    }];
}

// 下载资源包（使用 ResourcePackService，NSString profileName）
// redesign-download-ui Phase 3：进度由 Service 内部注册的下载任务 +
// PLTaskStagesSingleFile 单阶段上报驱动统一进度页，调用方无需管理进度 UI。
- (void)startDownloadForResourcePackItem:(ResourcePackItem *)item {
    NSString *profileName = [self effectiveTargetProfileName];
    __weak typeof(self) weakSelf = self;
    [[ResourcePackService sharedService] downloadResourcePack:item
                                                    toProfile:profileName
                                                 expectedSHA1:item.fileSHA1
                                                     progress:nil
                                                   completion:^(BOOL success, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (success && !error) {
                [strongSelf showSuccessMessage:[NSString stringWithFormat:localize(@"i18n_str_267", nil), item.displayName]];
            } else {
                [strongSelf showError:error.localizedDescription ?: localize(@"i18n_str_268", nil)];
            }
        });
    }];
}

// 下载数据包（使用 DataPackService，NSString profileName）
// redesign-download-ui Phase 3：进度由 Service 内部注册的下载任务 +
// PLTaskStagesSingleFile 单阶段上报驱动统一进度页，调用方无需管理进度 UI。
- (void)startDownloadForDataPackItem:(DataPackItem *)item {
    NSString *profileName = [self effectiveTargetProfileName];
    __weak typeof(self) weakSelf = self;
    [[DataPackService sharedService] downloadDataPack:item
                                            toProfile:profileName
                                            worldName:nil
                                         expectedSHA1:item.fileSHA1
                                             progress:nil
                                           completion:^(BOOL success, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (success && !error) {
                [strongSelf showSuccessMessage:[NSString stringWithFormat:localize(@"i18n_str_269", nil), item.displayName]];
            } else {
                [strongSelf showError:error.localizedDescription ?: localize(@"i18n_str_270", nil)];
            }
        });
    }];
}

// 下载世界存档并解压到 saves 目录（使用 WorldService，含进度回调与健壮解压）
// redesign-download-ui Phase 3：进度由 Service 内部注册的下载任务 +
// PLTaskStagesSingleFile 单阶段上报驱动统一进度页，调用方无需管理进度 UI。
- (void)startDownloadForWorldItem:(WorldItem *)item {
    NSString *profileName = [self effectiveTargetProfileName];
    __weak typeof(self) weakSelf = self;
    [[WorldService sharedService] downloadWorld:item
                                        toProfile:profileName
                                         progress:nil
                                       completion:^(BOOL success, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (success && !error) {
                [strongSelf showSuccessMessage:[NSString stringWithFormat:localize(@"i18n_str_271", nil), item.displayName]];
            } else {
                [strongSelf showError:error.localizedDescription ?: localize(@"i18n_str_272", nil)];
            }
        });
    }];
}

#pragma mark - ShaderVersionViewControllerDelegate

- (void)shaderVersionViewController:(ShaderVersionViewController *)viewController didSelectVersion:(ShaderVersion *)version {
    ShaderItem *itemToDownload = viewController.shaderItem;
    
    NSDictionary *primaryFile = version.primaryFile;
    if (!primaryFile || ![primaryFile[@"url"] isKindOfClass:[NSString class]]) {
        [self showError:localize(@"i18n_str_265", nil)];
        return;
    }
    
    itemToDownload.selectedVersionDownloadURL = primaryFile[@"url"];
    itemToDownload.fileName = primaryFile[@"filename"] ?: [NSString stringWithFormat:@"%@.zip", itemToDownload.displayName];
    // spec Task 5.1 收尾：光影包版本模型 primaryFile 的 sha1 接到下载调用
    itemToDownload.fileSHA1 = PLSha1FromPrimaryFile(primaryFile);

    // 子页面已 push 到导航栈，选完版本后 pop 回下载列表
    [self.navigationController popViewControllerAnimated:YES];
    [self startDownloadForShaderItem:itemToDownload];
}

// 下载光影包（redesign-download-ui Phase 4：进度由 Service 内部注册的下载任务 +
// PLTaskStagesSingleFile 单阶段上报驱动统一进度页，调用方无需管理进度 UI。）
- (void)startDownloadForShaderItem:(ShaderItem *)item {
    NSString *profileName = [self effectiveTargetProfileName];
    __weak typeof(self) weakSelf = self;
    [[ShaderService sharedService] downloadShader:item
                                         toProfile:profileName
                                      expectedSHA1:item.fileSHA1
                                          progress:nil
                                          completion:^(NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error) {
                [strongSelf showError:error.localizedDescription];
            } else {
                [strongSelf showSuccessMessage:[NSString stringWithFormat:localize(@"i18n_str_266", nil), item.displayName]];
            }
        });
    }];
}

#pragma mark - Network & Progress

- (BOOL)isNetworkAvailable {
    struct sockaddr_in zeroAddress;
    bzero(&zeroAddress, sizeof(zeroAddress));
    zeroAddress.sin_len = sizeof(zeroAddress);
    zeroAddress.sin_family = AF_INET;
    
    SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, (const struct sockaddr *)&zeroAddress);
    if (!reachability) return NO;
    
    SCNetworkReachabilityFlags flags;
    BOOL success = SCNetworkReachabilityGetFlags(reachability, &flags);
    CFRelease(reachability);
    
    return success && (flags & kSCNetworkReachabilityFlagsReachable) && !(flags & kSCNetworkReachabilityFlagsConnectionRequired);
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    // 原版前置安装进度（独立 context，避免与主下载流程冲突）
    if ([(__bridge NSString *)context isEqualToString:@"VanillaPreinstallContext"]) {
        [self handleVanillaPreinstallProgress];
        return;
    }
    if (![(__bridge NSString *)context isEqualToString:@"DownloadProgressContext"]) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    
    NSProgress *progress = self.downloadTask.progress;
    if (!progress) return;

    // redesign-download-ui Phase 4：进度展示由任务内部阶段上报驱动统一进度页，
    // 此处仅保留完成收尾（KVO 移除 + ReloadProfileList 通知）。
    if (!progress.finished) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.isObservingProgress) {
            @try {
                [self.downloadTask.progress removeObserver:self forKeyPath:@"fractionCompleted"];
            } @catch (NSException *exception) {
                NSLog(@"[DownloadVC] progress.finished: removeObserver failed: %@", exception.reason);
            }
            self.isObservingProgress = NO;
        }

        self.view.userInteractionEnabled = YES;
        self.downloadTask = nil;

        // 关键修复（issue #61）：Vanilla 版本下载完成后未发送 ReloadProfileList 通知，
        // 导致"已安装的版本"列表不刷新、新版本卡片不显示。
        // downloadVanillaVersion: 中已 saveProfile + setSelectedProfileName（会发 SelectedProfileChanged），
        // 但版本卡片列表（LauncherRootViewController/VersionManagerViewController）监听的是 ReloadProfileList，
        // 不补发此通知则 UI 永远不刷新。
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
    });
}

/// 原版前置安装的进度处理（redesign-download-ui Phase 3 Task 3.2 简化）：
/// 进度展示已由 MinecraftResourceDownloadTask 内部的阶段上报驱动统一进度页自动呈现，
/// 此处仅保留完成收尾逻辑：移除 KVO、刷新版本列表、回调 completion 触发后续加载器安装。
- (void)handleVanillaPreinstallProgress {
    MinecraftResourceDownloadTask *task = self.vanillaPreinstallTask;
    if (!task) return;
    NSProgress *progress = task.progress;
    if (!progress.finished) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(self) s = self;
        if (!s) return;

        if (s.isObservingVanillaPreinstall) {
            @try {
                [s.vanillaPreinstallTask.progress removeObserver:s forKeyPath:@"fractionCompleted"];
            } @catch (NSException *exception) {
                NSLog(@"[DownloadVC] vanillaPreinstall progress.finished: removeObserver failed: %@", exception.reason);
            }
            s.isObservingVanillaPreinstall = NO;
        }
        s.vanillaPreinstallTask = nil;
        // 关键修复（issue #61）：原版前置安装完成后也需发送 ReloadProfileList 通知，
        // 让"已安装的版本"列表及时显示已就绪的原版版本。
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
        void (^cb)(BOOL) = s.vanillaPreinstallCompletion;
        s.vanillaPreinstallCompletion = nil;
        if (cb) cb(YES);
    });
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

#pragma mark - Helper Methods

/// 阶段6修复（参照 FCL）：带 User-Agent 的同步下载工具方法
///
/// 之前 OptiFine 下载全程使用 [NSData dataWithContentsOfURL:]，默认不带 User-Agent 或
/// 使用系统默认 UA，BMCLAPI/Cloudflare 会拦截此类请求返回 403 或 HTML 错误页，
/// 导致 OptiFine 安装失败。Forge/NeoForge 直装器使用 NSURLSession + 浏览器 UA 是正确的，
/// 此方法让 OptiFine 下载也使用同样的方式。
///
/// 此方法为同步阻塞调用，须在后台线程调用。
- (NSData *)downloadDataWithURLString:(NSString *)urlString error:(NSError **)error {
    if (!urlString.length) {
        if (error) *error = [NSError errorWithDomain:@"DownloadError" code:1 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_273", nil)}];
        return nil;
    }
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        // 尝试百分号编码后再解析
        NSString *encoded = [urlString stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        url = [NSURL URLWithString:encoded];
    }
    if (!url) {
        if (error) *error = [NSError errorWithDomain:@"DownloadError" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_274", nil), urlString]}];
        return nil;
    }

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 60;
    cfg.timeoutIntervalForResource = 180;
    // 浏览器 UA（BMCLAPI/Cloudflare 要求非默认 UA，参照 ForgeDirectInstaller.m）
    cfg.HTTPAdditionalHeaders = @{
        @"User-Agent": @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        @"Accept": @"*/*"
    };

    __block NSData *result = nil;
    __block NSError *blockError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    NSURLSessionDataTask *task = [session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
        if (err) {
            blockError = err;
        } else if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
            NSInteger statusCode = httpResp.statusCode;
            if (statusCode >= 400) {
                blockError = [NSError errorWithDomain:@"DownloadError" code:statusCode userInfo:@{
                    NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld", (long)statusCode]
                }];
            } else {
                result = data;
            }
        } else {
            result = data;
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];

    // 等待下载完成（60s 超时由 session 配置控制）
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    [session finishTasksAndInvalidate];

    if (error) *error = blockError;
    return result;
}

- (NSString *)currentInstanceModsPath {
    // 参考 ModService.m 的 existingModsFolderForProfile: 逻辑：
    // 1. 优先读取 profile 的 gameDir，拼接 /mods
    // 2. 若 profile 无 gameDir 或 gameDir 为 "."，回退到 $POJAV_GAME_DIR/mods
    NSString *instanceName = [self effectiveTargetProfileName];

    NSString *modsDir = nil;

    @try {
        NSDictionary *profiles = PLProfiles.current.profiles;
        NSDictionary *prof = profiles[instanceName];
        if ([prof isKindOfClass:[NSDictionary class]]) {
            NSString *gameDir = prof[@"gameDir"];
            if ([gameDir isKindOfClass:[NSString class]] && gameDir.length > 0 && ![gameDir isEqualToString:@"."]) {
                // gameDir 是相对路径时，相对于 POJAV_GAME_DIR 解析
                NSString *baseDir;
                const char *env = getenv("POJAV_GAME_DIR");
                if (env) {
                    baseDir = [NSString stringWithUTF8String:env];
                } else {
                    baseDir = NSHomeDirectory();
                }

                if ([gameDir isAbsolutePath]) {
                    modsDir = [gameDir stringByAppendingPathComponent:@"mods"];
                } else {
                    modsDir = [[baseDir stringByAppendingPathComponent:gameDir] stringByAppendingPathComponent:@"mods"];
                }
            }
        }
    } @catch (NSException *ex) { }

    if (!modsDir) {
        // 回退到 $POJAV_GAME_DIR/mods（与 FCL 默认行为一致）
        const char *env = getenv("POJAV_GAME_DIR");
        NSString *gameDir = env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
        modsDir = [gameDir stringByAppendingPathComponent:@"mods"];
    }

    [[NSFileManager defaultManager] createDirectoryAtPath:modsDir withIntermediateDirectories:YES attributes:nil error:nil];
    return modsDir;
}

- (void)handleBackgroundUIEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 重新应用背景透明效果（参照 LauncherRightPanelViewController.reapplyBackgroundEffect）
        [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
        // 重新应用侧边栏效果（filterSidebarContainer 的毛玻璃/半透明效果需要随设置更新）
        if (self.filterSidebarContainer) {
            [[BackgroundManager sharedManager] applyEffectToView:self.filterSidebarContainer];
        }
        // 对导航栏应用效果
        UINavigationController *nav = self.navigationController;
        if (nav) {
            nav.view.backgroundColor = [UIColor clearColor];
            [[BackgroundManager sharedManager] applyEffectToNavigationBar:nav.navigationBar];
        }
        // 刷新所有列表以更新 cell 的背景效果
        [self.versionCollectionView reloadData];
        [self.modTableView reloadData];
        [self.shaderTableView reloadData];
        [self.modpackTableView reloadData];
        [self.resourcepackTableView reloadData];
        [self.datapackTableView reloadData];
        [self.worldTableView reloadData];
    });
}

@end
