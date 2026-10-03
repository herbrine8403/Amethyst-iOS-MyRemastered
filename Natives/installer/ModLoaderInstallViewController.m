#import "utils.h"
//
//  ModLoaderInstallViewController.m
//  Amethyst
//
//  参照 FCL (FoldCraftLauncher) page_installer.xml + view_installer_item.xml 重构。
//  - 顶部紧凑 toolbar：版本名输入框 + 右上角下载图标按钮（替代原底部 72pt 大按钮）
//  - 加载器列表用 UITableView InsetGrouped 扁平条目（每行 ~54pt，无阴影/无卡片边框）
//  - 每行：左侧 28pt 图标 + 中间名称/状态双行 + 右侧 chevron/选中标记
//  - 附加选项（Fabric API / OptiFine 共存）作为独立 section 的开关行
//  - 版本选择子页面也改为 UITableView 扁平条目
//  - 互斥逻辑与 FCL 完全一致
//

#import "ModLoaderInstallViewController.h"
#import "NeoForgeVersionFetcher.h"
#import "LauncherPreferences.h"
#import "BackgroundManager.h"
#import "ModLoaderIconHelper.h"
#import "ScreenUtils.h"
#import <QuartzCore/QuartzCore.h>

#pragma mark - ★ [PCL-ALIGN] 版本列表拉取工具（与 ForgeInstallViewController.m 同一实现风格）
//
// 背景：本文件的 ModLoaderVersionPickerViewController 才是“下载→下载实例→选加载器”实际
// 走的取版本路径。旧 loadForgeVersions 用“双源并发竞速 + 无缓存 + 单次 20s”，用户报
// “PCL 一次能拿到 forge，我们要好几次”。此处对齐 PCL2 ModDownload.vb / ModNet.vb：
//   ① BMCLAPI 轻接口 /forge/minecraft/<mc> 优先（数据量小、秒回）；
//   ② 全量 maven-metadata.xml 仅兜底（BMCLAPI 主 → 官方备，短超时单次）；
//   ③ 成功结果写磁盘缓存（与 ForgeInstallViewController.m 同目录/命名）。

// ★ [PCL-ALIGN] 同步 GET（带超时 + 线性退避重试），非 2xx 视为失败；全失败返回 nil。
static NSData *PALFetchWithRetry(NSString *urlString, NSInteger maxAttempts, NSTimeInterval timeout) {
    if (urlString.length == 0) return nil;
    if (maxAttempts < 1) maxAttempts = 1;
    if (timeout <= 0) timeout = 12.0;
    NSString *userAgent = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";
    for (NSInteger attempt = 1; attempt <= maxAttempts; attempt++) {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
        req.timeoutInterval = timeout;
        req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        [req setValue:userAgent forHTTPHeaderField:@"User-Agent"];
        __block NSData *d = nil;
        __block NSInteger status = 0;
        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                d = data;
                if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                    status = ((NSHTTPURLResponse *)response).statusCode;
                }
                dispatch_semaphore_signal(sem);
            }];
        [task resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 5.0) * NSEC_PER_SEC)));
        BOOL httpOK = (status == 0 || (status >= 200 && status < 300));
        if (d.length > 0 && httpOK) return d;
        NSLog(@"[PCL-ALIGN] Forge fetch attempt %ld/%ld failed (http=%ld, bytes=%lu) %@",
              (long)attempt, (long)maxAttempts, (long)status, (unsigned long)d.length, urlString);
        if (attempt < maxAttempts) [NSThread sleepForTimeInterval:1.2 * (double)attempt];
    }
    return nil;
}

// ★ [PCL-ALIGN] 版本列表磁盘缓存（PCL2 用 CacheCow FileStore 做 HTTP 缓存，效果等价）。
//   路径：Caches/pcl_align_version_cache/<vendor>_<mc>.json，内容 {ts, versions[]}。有效期 6h。
static NSString *PALVersionCacheDirectory(void) {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *base = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
        if (base.length == 0) base = NSTemporaryDirectory();
        dir = [base stringByAppendingPathComponent:@"pcl_align_version_cache"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    });
    return dir;
}
static NSString *PALVersionCachePath(NSString *vendor, NSString *gameVersion) {
    NSString *raw = [NSString stringWithFormat:@"%@_%@",
                     vendor.length ? vendor : @"Unknown",
                     gameVersion.length ? gameVersion : @"all"];
    NSCharacterSet *bad = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    NSString *safe = [[raw componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
    return [PALVersionCacheDirectory() stringByAppendingPathComponent:[safe stringByAppendingString:@".json"]];
}
static NSArray<NSString *> *PALCacheRead(NSString *vendor, NSString *gameVersion, NSTimeInterval ttl) {
    NSData *data = [NSData dataWithContentsOfFile:PALVersionCachePath(vendor, gameVersion)];
    if (data.length == 0) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *dict = (NSDictionary *)obj;
    NSArray *versions = dict[@"versions"];
    NSNumber *ts = dict[@"ts"];
    if (![versions isKindOfClass:[NSArray class]] || versions.count == 0) return nil;
    if (ttl > 0 && ([NSDate date].timeIntervalSince1970 - ts.doubleValue) > ttl) return nil;
    NSMutableArray<NSString *> *out = [NSMutableArray new];
    for (id v in versions) {
        if ([v isKindOfClass:[NSString class]] && [v length] > 0) [out addObject:v];
    }
    return out.count > 0 ? out : nil;
}
static void PALCacheWrite(NSString *vendor, NSString *gameVersion, NSArray<NSString *> *versions) {
    if (versions.count == 0) return;
    NSDictionary *obj = @{ @"ts": @([NSDate date].timeIntervalSince1970),
                           @"vendor": vendor ?: @"",
                           @"gameVersion": gameVersion ?: @"",
                           @"versions": versions };
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (data.length == 0) return;
    [data writeToFile:PALVersionCachePath(vendor, gameVersion) atomically:YES];
}

// ★ [PCL-ALIGN] Forge 全量 maven-metadata.xml 解析器：返回与 gameVersion 匹配的“纯 Forge 版本号”。
//   口径与旧 delegate 一致：<version>1.20.1-47.2.0</version> → "47.2.0"（供 picker 显示，
//   下游 ForgeInstallViewController 会补全 <mc>-<forge> 前缀）。
@interface PALForgeMetaParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, copy) NSString *gameVersion;
@property (nonatomic, strong) NSMutableArray<NSString *> *versions;
@property (nonatomic, strong) NSMutableString *current;
@property (nonatomic, assign) BOOL inVersion;
@end
@implementation PALForgeMetaParser
- (instancetype)init {
    if ((self = [super init])) { _versions = [NSMutableArray new]; }
    return self;
}
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary *)attributeDict {
    if ([elementName isEqualToString:@"version"]) {
        _inVersion = YES;
        _current = [NSMutableString new];
    }
}
- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    if (_inVersion && string) [_current appendString:string];
}
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName {
    if (![elementName isEqualToString:@"version"]) return;
    _inVersion = NO;
    NSString *raw = [_current stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    _current = nil;
    if (raw.length == 0) return;
    NSString *prefix = [NSString stringWithFormat:@"%@-", _gameVersion ?: @""];
    NSString *forgeVer = nil;
    if ([raw hasPrefix:prefix]) forgeVer = [raw substringFromIndex:prefix.length];
    else if ([raw isEqualToString:_gameVersion]) forgeVer = raw;
    if (forgeVer.length > 0 && ![_versions containsObject:forgeVer]) [_versions addObject:forgeVer];
}
@end
static NSArray<NSString *> *PALParseForgeMetaXML(NSData *data, NSString *gameVersion) {
    if (data.length == 0) return @[];
    // 校验响应是 XML 而非 HTML 错误页（BMCLAPI 限流 429 / 5xx 时可能返回 HTML）
    NSUInteger previewLen = MIN(256, data.length);
    NSString *preview = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, previewLen)] encoding:NSUTF8StringEncoding];
    NSString *lower = preview.lowercaseString ?: @"";
    if ([lower containsString:@"<html"] || [lower containsString:@"<!doctype"] || [lower containsString:@"<head"]) return @[];
    PALForgeMetaParser *p = [PALForgeMetaParser new];
    p.gameVersion = gameVersion;
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    parser.delegate = p;
    [parser parse];
    return [p.versions copy];
}

#pragma mark - Data Models

/// 加载器元数据
@interface ModLoaderRow : NSObject
@property (nonatomic, copy) NSString *identifier;   // "vanilla"/"fabric"/"forge"/"neoforge"/"quilt"/"optifine"
@property (nonatomic, copy) NSString *name;         // 显示名
@property (nonatomic, copy) NSString *desc;         // 描述
@property (nonatomic, copy) NSString *iconName;     // SF Symbol 名（PNG 缺失时回退用）
@property (nonatomic, strong) UIColor *iconColor;   // 图标主色
@property (nonatomic, assign) BOOL compatible;      // 与当前游戏版本是否兼容
@property (nonatomic, copy, nullable) NSString *selectedVersion; // 选中版本（nil 表示未选）
@end
@implementation ModLoaderRow
@end

#pragma mark - Loader Row Cell (扁平条目，参照 FCL view_installer_item.xml)

@interface ModLoaderRowCell : UITableViewCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *stateLabel;
@property (nonatomic, strong) UIView *selectedBadge;
@end

@implementation ModLoaderRowCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier];
    if (self) {
        [self setupViews];
    }
    return self;
}

- (void)setupViews {
    // 扁平条目：无阴影、无边框，仅依赖 BackgroundManager.applyEffectToCell: 提供毛玻璃/半透明
    self.selectionStyle = UITableViewCellSelectionStyleDefault;
    self.accessoryType = UITableViewCellAccessoryNone;

    CGFloat iconSize = [ScreenUtils dp:28];
    CGFloat nameFont = [ScreenUtils sp:15];
    CGFloat stateFont = [ScreenUtils sp:12];

    _iconView = [[UIImageView alloc] init];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    [self.contentView addSubview:_iconView];

    _nameLabel = [[UILabel alloc] init];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [UIFont systemFontOfSize:nameFont weight:UIFontWeightMedium];
    _nameLabel.textColor = [UIColor labelColor];
    _nameLabel.numberOfLines = 1;
    _nameLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentView addSubview:_nameLabel];

    _stateLabel = [[UILabel alloc] init];
    _stateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _stateLabel.font = [UIFont systemFontOfSize:stateFont];
    _stateLabel.textColor = [UIColor secondaryLabelColor];
    _stateLabel.numberOfLines = 1;
    _stateLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentView addSubview:_stateLabel];

    _selectedBadge = [[UIView alloc] init];
    _selectedBadge.translatesAutoresizingMaskIntoConstraints = NO;
    _selectedBadge.backgroundColor = [UIColor systemGreenColor];
    _selectedBadge.layer.cornerRadius = 10;
    _selectedBadge.hidden = YES;
    [self.contentView addSubview:_selectedBadge];

    UIImageView *checkmark = [[UIImageView alloc] init];
    checkmark.translatesAutoresizingMaskIntoConstraints = NO;
    checkmark.image = [UIImage systemImageNamed:@"checkmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:9 weight:UIFontWeightBold]];
    checkmark.tintColor = [UIColor whiteColor];
    [_selectedBadge addSubview:checkmark];

    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [self.iconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.iconView.widthAnchor constraintEqualToConstant:iconSize],
        [self.iconView.heightAnchor constraintEqualToConstant:iconSize],

        [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:12],
        [self.nameLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:9],
        [self.nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.selectedBadge.leadingAnchor constant:-8],

        [self.stateLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [self.stateLabel.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:2],
        [self.stateLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.selectedBadge.leadingAnchor constant:-8],
        [self.stateLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-9],

        [self.selectedBadge.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [self.selectedBadge.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.selectedBadge.widthAnchor constraintEqualToConstant:20],
        [self.selectedBadge.heightAnchor constraintEqualToConstant:20],
        [checkmark.centerXAnchor constraintEqualToAnchor:self.selectedBadge.centerXAnchor],
        [checkmark.centerYAnchor constraintEqualToAnchor:self.selectedBadge.centerYAnchor],
    ]];
}

- (void)setIncompatible:(BOOL)incompatible reason:(NSString *)reason {
    if (incompatible) {
        self.stateLabel.hidden = NO;
        self.stateLabel.text = reason ?: localize(@"i18n_str_1199", nil);
        self.stateLabel.textColor = [UIColor systemRedColor];
        self.nameLabel.textColor = [UIColor tertiaryLabelColor];
        self.iconView.alpha = 0.45;
        self.selectedBadge.hidden = YES;
        self.accessoryType = UITableViewCellAccessoryNone;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.contentView.userInteractionEnabled = NO;
    } else {
        self.nameLabel.textColor = [UIColor labelColor];
        self.stateLabel.textColor = [UIColor secondaryLabelColor];
        self.iconView.alpha = 1.0;
        self.selectionStyle = UITableViewCellSelectionStyleDefault;
        self.contentView.userInteractionEnabled = YES;
    }
}

- (void)setSelectedVersionText:(NSString *)text {
    if (text.length > 0) {
        self.stateLabel.hidden = NO;
        self.stateLabel.text = text;
        self.stateLabel.textColor = [UIColor systemGreenColor];
    } else {
        self.stateLabel.hidden = NO;
        self.stateLabel.text = localize(@"i18n_str_1200", nil);
        self.stateLabel.textColor = [UIColor secondaryLabelColor];
    }
}

- (void)clearStatusText {
    self.stateLabel.hidden = NO;
    self.stateLabel.text = localize(@"i18n_str_1201", nil);
    self.stateLabel.textColor = [UIColor secondaryLabelColor];
}

- (void)configureWithRow:(ModLoaderRow *)row
            isSelected:(BOOL)isSelected
      selectedVersionDisplay:(NSString *)versionDisplay
                incompatible:(BOOL)incompatible
                     reason:(NSString *)reason {
    self.nameLabel.text = row.name;

    [ModLoaderIconHelper configureImageView:self.iconView
                                  forLoader:row.identifier
                             traitCollection:self.traitCollection];

    if (incompatible) {
        [self setIncompatible:YES reason:reason];
        return;
    }

    [self setIncompatible:NO reason:nil];

    if (isSelected) {
        if (versionDisplay.length > 0) {
            [self setSelectedVersionText:versionDisplay];
        } else if ([row.identifier isEqualToString:@"vanilla"]) {
            [self setSelectedVersionText:localize(@"i18n_str_1202", nil)];
        } else {
            [self setSelectedVersionText:nil];
        }
        self.selectedBadge.hidden = NO;
        self.accessoryType = UITableViewCellAccessoryNone;
    } else {
        [self clearStatusText];
        self.selectedBadge.hidden = YES;
        self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
}

@end

#pragma mark - Switch Row Cell (Fabric API / OptiFine 选项开关行)

@interface ModLoaderSwitchCell : UITableViewCell
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UISwitch *switchControl;
@end

@implementation ModLoaderSwitchCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier];
    if (self) {
        [self setupViews];
    }
    return self;
}

- (void)setupViews {
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    CGFloat titleFont = [ScreenUtils sp:15];
    CGFloat descFont = [ScreenUtils sp:12];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:titleFont weight:UIFontWeightMedium];
    _titleLabel.textColor = [UIColor labelColor];
    _titleLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentView addSubview:_titleLabel];

    _descLabel = [[UILabel alloc] init];
    _descLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _descLabel.font = [UIFont systemFontOfSize:descFont];
    _descLabel.textColor = [UIColor secondaryLabelColor];
    _descLabel.numberOfLines = 0;
    _descLabel.lineBreakMode = NSLineBreakByWordWrapping;
    _descLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentView addSubview:_descLabel];

    _switchControl = [[UISwitch alloc] init];
    _switchControl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_switchControl];

    [NSLayoutConstraint activateConstraints:@[
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:9],
        [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.switchControl.leadingAnchor constant:-12],

        [self.descLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.descLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:2],
        [self.descLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.switchControl.leadingAnchor constant:-12],
        [self.descLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-9],

        [self.switchControl.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [self.switchControl.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
    ]];
}

@end

#pragma mark - Version Row Cell (版本选择子页面扁平条目)

@interface ModLoaderVersionCell : UITableViewCell
@property (nonatomic, strong) UILabel *versionLabel;
@property (nonatomic, strong) UIView *selectedBadge;
@end

@implementation ModLoaderVersionCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier];
    if (self) {
        [self setupViews];
    }
    return self;
}

- (void)setupViews {
    self.selectionStyle = UITableViewCellSelectionStyleDefault;

    CGFloat versionFont = [ScreenUtils sp:15];

    _versionLabel = [[UILabel alloc] init];
    _versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _versionLabel.font = [UIFont systemFontOfSize:versionFont weight:UIFontWeightRegular];
    _versionLabel.textColor = [UIColor labelColor];
    _versionLabel.numberOfLines = 1;
    _versionLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentView addSubview:_versionLabel];

    _selectedBadge = [[UIView alloc] init];
    _selectedBadge.translatesAutoresizingMaskIntoConstraints = NO;
    _selectedBadge.backgroundColor = [UIColor systemGreenColor];
    _selectedBadge.layer.cornerRadius = 10;
    _selectedBadge.hidden = YES;
    [self.contentView addSubview:_selectedBadge];

    UIImageView *checkmark = [[UIImageView alloc] init];
    checkmark.translatesAutoresizingMaskIntoConstraints = NO;
    checkmark.image = [UIImage systemImageNamed:@"checkmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:9 weight:UIFontWeightBold]];
    checkmark.tintColor = [UIColor whiteColor];
    [_selectedBadge addSubview:checkmark];

    [NSLayoutConstraint activateConstraints:@[
        [self.versionLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [self.versionLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.versionLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.selectedBadge.leadingAnchor constant:-8],

        [self.selectedBadge.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [self.selectedBadge.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.selectedBadge.widthAnchor constraintEqualToConstant:20],
        [self.selectedBadge.heightAnchor constraintEqualToConstant:20],
        [checkmark.centerXAnchor constraintEqualToAnchor:self.selectedBadge.centerXAnchor],
        [checkmark.centerYAnchor constraintEqualToAnchor:self.selectedBadge.centerYAnchor],
    ]];
}

- (void)configureWithVersion:(NSString *)version isSelected:(BOOL)isSelected {
    // OptiFine packed 格式：type\x1fpatch\x1ffilename\x1fdisplay
    NSString *display = version;
    if ([version containsString:@"\x1f"]) {
        NSArray *parts = [version componentsSeparatedByString:@"\x1f"];
        if (parts.count >= 4) display = parts[3];
        else if (parts.count >= 1) display = parts[0];
    }
    self.versionLabel.text = display;
    self.selectedBadge.hidden = !isSelected;
    self.accessoryType = isSelected ? UITableViewCellAccessoryNone : UITableViewCellAccessoryNone;
}

@end

#pragma mark - Version Picker View Controller (版本选择子页面，扁平 UITableView)

@interface ModLoaderVersionPickerViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, NSXMLParserDelegate>
@property (nonatomic, copy) NSString *loaderId;
@property (nonatomic, copy) NSString *gameVersion;
@property (nonatomic, copy) NSString *selectedVersion;
@property (nonatomic, copy) void (^onSelected)(NSString *version);
@property (nonatomic, copy) void (^onCancelled)(void);
@end

@interface ModLoaderVersionPickerViewController ()
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UILabel *errorLabel;
@property (nonatomic, strong) NSArray *versions;
// Forge XML 解析
@property (nonatomic, strong) NSMutableArray *forgeVersionList;
@property (nonatomic, strong) NSMutableString *currentVersionValue;
@property (nonatomic, assign) BOOL isParsingForge;
// 网络任务
@property (nonatomic, strong) NSURLSessionDataTask *currentTask;
@property (nonatomic, strong) NSURLSessionDataTask *bmclTask;
@end

@implementation ModLoaderVersionPickerViewController

- (void)dealloc {
    if (_currentTask) { [_currentTask cancel]; _currentTask = nil; }
    if (_bmclTask) { [_bmclTask cancel]; _bmclTask = nil; }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self pickerTitle];
    self.view.backgroundColor = [UIColor clearColor];
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    if (self.navigationController) {
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
    }
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.left"]
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(backTapped)];

    [self setupTableView];
    [self startLoading];
}

- (void)refreshBackgroundEffect {
    // 背景效果切换时刷新 cell 毛玻璃外观
    [_tableView reloadData];
}

- (NSString *)pickerTitle {
    if ([_loaderId isEqualToString:@"fabric"])   return localize(@"i18n_str_1203", nil);
    if ([_loaderId isEqualToString:@"forge"])    return localize(@"i18n_str_1204", nil);
    if ([_loaderId isEqualToString:@"neoforge"]) return localize(@"i18n_str_1205", nil);
    if ([_loaderId isEqualToString:@"quilt"])    return localize(@"i18n_str_1206", nil);
    if ([_loaderId isEqualToString:@"optifine"]) return localize(@"i18n_str_1207", nil);
    return localize(@"i18n_str_38", nil);
}

- (void)setupTableView {
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.backgroundView = nil;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 50;
    _tableView.estimatedRowHeight = 50;
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    // extendedLayoutIncludesOpaqueBars / edgesForExtendedLayout 是 UIViewController 的属性，
    // 不能设置到 UITableView 上，否则编译报 "property not found on object of type 'UITableView *'"
    self.extendedLayoutIncludesOpaqueBars = YES;
    self.edgesForExtendedLayout = UIRectEdgeAll;
    [_tableView registerClass:[ModLoaderVersionCell class] forCellReuseIdentifier:@"VersionCell"];
    [self.view addSubview:_tableView];

    _loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    _loadingIndicator.hidesWhenStopped = YES;
    [self.view addSubview:_loadingIndicator];

    _emptyLabel = [[UILabel alloc] init];
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyLabel.text = localize(@"i18n_str_1208", nil);
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.textColor = [UIColor secondaryLabelColor];
    _emptyLabel.font = [UIFont systemFontOfSize:15];
    _emptyLabel.hidden = YES;
    [self.view addSubview:_emptyLabel];

    _errorLabel = [[UILabel alloc] init];
    _errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _errorLabel.text = localize(@"i18n_str_1209", nil);
    _errorLabel.textAlignment = NSTextAlignmentCenter;
    _errorLabel.textColor = [UIColor systemRedColor];
    _errorLabel.font = [UIFont systemFontOfSize:15];
    _errorLabel.numberOfLines = 0;
    _errorLabel.hidden = YES;
    [self.view addSubview:_errorLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.loadingIndicator.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.loadingIndicator.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],

        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],

        [self.errorLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.errorLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.errorLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24],
        [self.errorLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-24],
    ]];
}

- (void)backTapped {
    if (_onCancelled) _onCancelled();
    if (self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)startLoading {
    _versions = nil;
    [_tableView reloadData];
    _emptyLabel.hidden = YES;
    _errorLabel.hidden = YES;
    [_loadingIndicator startAnimating];

    if ([_loaderId isEqualToString:@"fabric"] || [_loaderId isEqualToString:@"quilt"]) {
        [self loadFabricLikeVersions:_loaderId];
    } else if ([_loaderId isEqualToString:@"forge"]) {
        [self loadForgeVersions];
    } else if ([_loaderId isEqualToString:@"neoforge"]) {
        [self loadNeoForgeVersions];
    } else if ([_loaderId isEqualToString:@"optifine"]) {
        [self loadOptiFineVersions];
    } else {
        [self finishLoadingWithVersions:@[] error:nil];
    }
}

#pragma mark Fabric / Quilt

- (void)loadFabricLikeVersions:(NSString *)loaderType {
    NSString *metaBase = [loaderType isEqualToString:@"quilt"]
        ? @"https://meta.quiltmc.org/v3/versions/loader"
        : @"https://meta.fabricmc.net/v2/versions/loader";
    NSString *urlString = [NSString stringWithFormat:@"%@/%@", metaBase, _gameVersion];
    NSURL *url = [NSURL URLWithString:urlString];

    __weak typeof(self) weakSelf = self;
    _currentTask = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error && error.code != NSURLErrorCancelled) {
                [strongSelf finishLoadingWithVersions:@[] error:error];
                return;
            }
            if (!data || error) {
                [strongSelf finishLoadingWithVersions:@[] error:nil];
                return;
            }
            NSError *jsonError;
            NSArray *versions = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (!versions || jsonError) {
                [strongSelf finishLoadingWithVersions:@[] error:jsonError];
                return;
            }
            NSMutableArray *list = [NSMutableArray array];
            for (NSDictionary *ver in versions) {
                if (![ver isKindOfClass:[NSDictionary class]]) continue;
                NSString *loaderVersion = ver[@"loader"][@"version"];
                if (loaderVersion && ![list containsObject:loaderVersion]) {
                    [list addObject:loaderVersion];
                }
            }
            [strongSelf finishLoadingWithVersions:list error:nil];
        });
    }];
    [_currentTask resume];
}

#pragma mark Forge (★ [PCL-ALIGN] BMCLAPI 轻接口优先 + 全量 maven-metadata 兜底)

- (void)loadForgeVersions {
    // ★ [PCL-ALIGN] 对齐 PCL2：BMCLAPI /forge/minecraft/<mc> 轻接口优先 →
    //   全量 maven-metadata.xml 仅兜底（BMCLAPI 主 → 官方备，短超时单次）+ 磁盘缓存。
    NSString *mc = _gameVersion ?: @"";
    NSLog(@"[PCL-ALIGN] ModLoaderInstallViewController.loadForgeVersions begin: mc=%@ (impl=ModLoaderInstallViewController.m)", mc);
    if (mc.length == 0) {
        [self finishLoadingWithVersions:@[] error:nil];
        return;
    }

    _forgeVersionList = [NSMutableArray array];
    _isParsingForge = NO;  // XML 解析改由 PALForgeMetaParser 在后台线程完成

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // ① 磁盘缓存（6h）
        NSArray<NSString *> *cached = PALCacheRead(@"Forge", mc, 6 * 3600.0);
        if (cached.count > 0) {
            NSLog(@"[PCL-ALIGN] Forge list cache HIT vendor=Forge mc=%@ (%lu)", mc, (unsigned long)cached.count);
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf finishLoadingWithVersions:cached error:nil];
            });
            return;
        }
        NSLog(@"[PCL-ALIGN] Forge list cache MISS vendor=Forge mc=%@", mc);

        NSMutableArray<NSString *> *collected = [NSMutableArray new];
        NSString *lastSource = nil;

        // ② 最快：BMCLAPI 按版本轻接口（返回纯 Forge 版本号，如 "47.2.0"）
        NSString *encodedMC = [mc stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
        NSString *fastURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/forge/minecraft/%@", encodedMC];
        NSData *fastData = PALFetchWithRetry(fastURL, 3, 10.0);
        if (fastData) {
            NSArray *tokens = [NSJSONSerialization JSONObjectWithData:fastData options:0 error:nil];
            if ([tokens isKindOfClass:[NSArray class]]) {
                for (id t in tokens) {
                    if (![t isKindOfClass:[NSDictionary class]]) continue;
                    NSString *ver = ((NSDictionary *)t)[@"version"];
                    if ([ver isKindOfClass:[NSString class]] && ver.length > 0 && ![collected containsObject:ver]) {
                        [collected addObject:ver];
                    }
                }
            }
            NSLog(@"[PCL-ALIGN] Forge source=BMCLAPI-fast URL=%@ bytes=%lu parsed=%lu",
                  fastURL, (unsigned long)fastData.length, (unsigned long)collected.count);
        } else {
            NSLog(@"[PCL-ALIGN] Forge source=BMCLAPI-fast URL=%@ fetch FAILED", fastURL);
        }
        if (collected.count > 0) lastSource = @"BMCLAPI-fast";

        // ③ 兜底：全量 maven-metadata.xml（BMCLAPI 主 → 官方备）
        if (collected.count == 0) {
            NSArray<NSArray<NSString *> *> *pairs = @[
                @[@"https://bmclapi2.bangbang93.com/maven/net/minecraftforge/forge/maven-metadata.xml", @"BMCLAPI-metadata"],
                @[@"https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml", @"official-metadata"],
            ];
            for (NSArray<NSString *> *pair in pairs) {
                NSData *data = PALFetchWithRetry(pair[0], 1, 12.0);
                if (!data) {
                    NSLog(@"[PCL-ALIGN] Forge source=%@ URL=%@ fetch FAILED", pair[1], pair[0]);
                    continue;
                }
                NSArray<NSString *> *vers = PALParseForgeMetaXML(data, mc);
                NSLog(@"[PCL-ALIGN] Forge source=%@ URL=%@ bytes=%lu parsed=%lu",
                      pair[1], pair[0], (unsigned long)data.length, (unsigned long)vers.count);
                if (vers.count > 0) {
                    [collected addObjectsFromArray:vers];
                    lastSource = pair[1];
                    break;
                }
            }
        }

        NSArray<NSString *> *sorted = [collected sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            // 降序，让最新版本在前
            return [b compare:a options:NSNumericSearch];
        }];
        if (sorted.count > 0) PALCacheWrite(@"Forge", mc, sorted);
        NSLog(@"[PCL-ALIGN] Forge list done: mc=%@ source=%@ count=%lu",
              mc, lastSource ?: @"none", (unsigned long)sorted.count);

        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf finishLoadingWithVersions:sorted
                                            error:(sorted.count > 0 ? nil
                                                   : [NSError errorWithDomain:@"Forge" code:1
                                                                     userInfo:@{NSLocalizedDescriptionKey:@"No Forge version list available"}])];
        });
    });
}

#pragma mark NeoForge

- (void)loadNeoForgeVersions {
    // ★ [PCL-ALIGN] 本页 NeoForge 版本列表委托给 NeoForgeVersionFetcher（已同步对标 PCL：
    //   BMCLAPI 轻接口优先 + 两/三种 JSON 形态通吃 + rawVersion 归一化 + 6h 磁盘缓存）。
    NSLog(@"[PCL-ALIGN] ModLoaderInstallViewController.loadNeoForgeVersions begin: mc=%@ (delegates to NeoForgeVersionFetcher.m)", _gameVersion ?: @"");
    __weak typeof(self) weakSelf = self;
    // ★ [NEOFORGE-FIX] 捕获当前 MC 版本：空结果提示需要它（例如 MC 26.4 实测 /neoforge/list/26.4 返回 []，
    //   NeoForge 尚未为该版本发版）。不能把“没有适配”谎报成有版本，也不该空转/无限加载。
    NSString *mcForLog = [_gameVersion copy];
    [NeoForgeVersionFetcher fetchVersionsForGameVersion:_gameVersion completion:^(NSArray *versions, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            // ★ [NEOFORGE-FIX] error.code==2 表示“源里确实有数据，但没有任何一条归属到当前 MC” ⇒
            //   该 MC 版本暂无 NeoForge 适配（诚实告知），而不是“加载失败/请检查网络”。
            if ((versions == nil || versions.count == 0) &&
                error && [error.domain isEqualToString:@"NeoForge"] && error.code == 2) {
                [strongSelf finishNeoForgeUnavailableForGameVersion:mcForLog];
                return;
            }
            [strongSelf finishLoadingWithVersions:versions ?: @[] error:error];
        });
    }];
}

// ★ [NEOFORGE-FIX] NeoForge 无适配版本时的专用提示：明确“该 MC 版本暂无 NeoForge 适配”，
//   不谎报版本、不空列表、不无限加载。文案 neoforge.no_version_for_mc 含 %@（MC 版本号）。
- (void)finishNeoForgeUnavailableForGameVersion:(NSString *)gameVersion {
    [_loadingIndicator stopAnimating];
    _isParsingForge = NO;
    _versions = @[];
    _emptyLabel.hidden = YES;
    _errorLabel.hidden = NO;
    if (gameVersion.length > 0) {
        _errorLabel.text = [NSString stringWithFormat:localize(@"neoforge.no_version_for_mc", nil), gameVersion];
    } else {
        _errorLabel.text = localize(@"i18n_str_1208", nil);
    }
    [_tableView reloadData];
    NSLog(@"[PCL-ALIGN] ModLoaderInstallViewController NeoForge unavailable: mc=%@ → 提示 neoforge.no_version_for_mc（该版本暂无 NeoForge 适配）", gameVersion ?: @"");
}

#pragma mark OptiFine (BMCLAPI 列表)

- (void)loadOptiFineVersions {
    NSString *urlString = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@", _gameVersion];
    NSURL *url = [NSURL URLWithString:urlString];

    __weak typeof(self) weakSelf = self;
    _currentTask = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error && error.code != NSURLErrorCancelled) {
                [strongSelf finishLoadingWithVersions:@[] error:error];
                return;
            }
            if (!data || error) {
                [strongSelf finishLoadingWithVersions:@[] error:nil];
                return;
            }
            NSError *jsonError;
            NSArray *list = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (!list || jsonError || ![list isKindOfClass:[NSArray class]]) {
                [strongSelf finishLoadingWithVersions:@[] error:jsonError];
                return;
            }
            NSMutableArray *versions = [NSMutableArray array];
            for (NSDictionary *item in list) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                NSString *type = item[@"type"] ?: @"";
                NSString *patch = item[@"patch"] ?: @"";
                NSString *filename = item[@"filename"] ?: @"";
                if (patch.length == 0) continue;
                // 显示格式：HD_U_I6 (filename)
                NSString *display = [NSString stringWithFormat:@"%@_%@", type, patch];
                if (filename.length > 0) {
                    display = [NSString stringWithFormat:@"%@_%@ (%@)", type, patch, filename];
                }
                // 把完整信息打包进 version 字符串，用 \x1f 分隔（unit separator）
                NSString *packed = [NSString stringWithFormat:@"%@\x1f%@\x1f%@\x1f%@", type, patch, filename, display];
                [versions addObject:packed];
            }
            [strongSelf finishLoadingWithVersions:versions error:nil];
        });
    }];
    [_currentTask resume];
}

- (void)finishLoadingWithVersions:(NSArray *)versions error:(NSError *)error {
    [_loadingIndicator stopAnimating];
    _isParsingForge = NO;

    if (error && versions.count == 0) {
        _versions = @[];
        _errorLabel.hidden = NO;
        _emptyLabel.hidden = YES;
        _errorLabel.text = [NSString stringWithFormat:localize(@"i18n_str_1210", nil), error.localizedDescription ?: localize(@"i18n_str_97", nil)];
    } else {
        _versions = versions ?: @[];
        _errorLabel.hidden = YES;
        _emptyLabel.hidden = (_versions.count > 0);
    }
    [_tableView reloadData];

    // 若当前已选中版本，滚动到选中行
    if (_selectedVersion.length > 0 && _versions.count > 0) {
        NSUInteger idx = [_versions indexOfObject:_selectedVersion];
        if (idx != NSNotFound) {
            NSIndexPath *path = [NSIndexPath indexPathForRow:idx inSection:0];
            [_tableView scrollToRowAtIndexPath:path atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
        }
    }
}

#pragma mark NSXMLParserDelegate (Forge)

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary *)attributeDict {
    if ([elementName isEqualToString:@"version"]) {
        _currentVersionValue = [NSMutableString new];
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    [_currentVersionValue appendString:string];
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName {
    if (!_isParsingForge) return;
    if ([elementName isEqualToString:@"version"]) {
        NSString *raw = [_currentVersionValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (raw.length > 0 && [_forgeVersionList indexOfObject:raw] == NSNotFound) {
            // Forge 版本格式：<mcver>-<forgever>，例如 "1.20.1-47.2.0"
            // 按 FCL/HMCL 做法：只保留与当前 gameVersion 匹配的版本
            NSString *prefix = [NSString stringWithFormat:@"%@-", _gameVersion];
            if ([raw hasPrefix:prefix]) {
                NSString *forgeVer = [raw substringFromIndex:prefix.length];
                if (forgeVer.length > 0 && ![_forgeVersionList containsObject:forgeVer]) {
                    [_forgeVersionList addObject:forgeVer];
                }
            } else if ([raw hasPrefix:_gameVersion] && [raw isEqualToString:_gameVersion]) {
                // 极少数情况：版本号就是 gameVersion 本身
                if (![_forgeVersionList containsObject:raw]) {
                    [_forgeVersionList addObject:raw];
                }
            }
        }
        _currentVersionValue = nil;
    } else if ([elementName isEqualToString:@"metadata"]) {
        _isParsingForge = NO;
        // 解析完成
        NSArray *sorted = [_forgeVersionList sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            // 简单降序排序，让最新版本在前
            return [b compare:a options:NSNumericSearch];
        }];
        // NSXMLParser 在后台线程（NSURLSession completionHandler）同步执行，
        // finishLoadingWithVersions: 内部调用 reloadData / stopAnimating 等 UI 操作，
        // 必须切回主线程，否则触发 AutoLayout 后台线程修改崩溃。
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishLoadingWithVersions:sorted error:nil];
        });
    }
}

#pragma mark UITableViewDataSource / UITableViewDelegate

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _versions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ModLoaderVersionCell *cell = [tableView dequeueReusableCellWithIdentifier:@"VersionCell" forIndexPath:indexPath];
    NSString *version = _versions[indexPath.row];
    BOOL isSelected = [_selectedVersion isEqualToString:version];
    [cell configureWithVersion:version isSelected:isSelected];
    // 适配自定义启动器背景：cell 应用毛玻璃/半透明效果
    [[BackgroundManager sharedManager] applyEffectToCell:cell];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *raw = _versions[indexPath.row];

    // 立即更新选中状态视觉反馈
    _selectedVersion = raw;
    [tableView reloadData];

    // 短暂展示选中状态后 pop
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.onSelected) self.onSelected(raw);
        if (self.navigationController.viewControllers.count > 1) {
            [self.navigationController popViewControllerAnimated:YES];
        } else {
            [self dismissViewControllerAnimated:YES completion:nil];
        }
    });
}

@end

#pragma mark - Main Controller

@interface ModLoaderInstallViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UITextField *versionNameField;
@property (nonatomic, strong) UIView *nameBar;

// 数据
@property (nonatomic, strong) NSMutableArray<ModLoaderRow *> *loaders;
@property (nonatomic, copy) NSString *selectedLoaderId;       // "vanilla"/"fabric"/"forge"/"neoforge"/"quilt"/"optifine"
@property (nonatomic, copy) NSString *selectedFabricVersion;
@property (nonatomic, copy) NSString *selectedForgeVersion;
@property (nonatomic, copy) NSString *selectedNeoForgeVersion;
@property (nonatomic, copy) NSString *selectedQuiltVersion;
@property (nonatomic, copy) NSString *selectedOptiFineVersion;
@property (nonatomic, copy) NSString *selectedOptiFineType;     // HD_U 等
@property (nonatomic, copy) NSString *selectedOptiFinePatch;
@property (nonatomic, copy) NSString *selectedOptiFineFilename;

// 选项
@property (nonatomic, assign) BOOL installFabricAPI;
@property (nonatomic, assign) BOOL installOptiFine;  // 仅 forge 选中时显示

// 用户是否手动修改过版本名
@property (nonatomic, assign) BOOL nameManuallyModified;
@end

@implementation ModLoaderInstallViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = localize(@"i18n_str_1211", nil);
    self.view.backgroundColor = [UIColor clearColor];
    if (self.navigationController) {
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
    }
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.left"]
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(backTapped)];

    // FCL 风格：右上角下载图标按钮（替代原底部 72pt 大按钮）
    UIBarButtonItem *installItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.down.circle.fill"]
                                                                      style:UIBarButtonItemStyleDone
                                                                     target:self
                                                                     action:@selector(installTapped)];
    installItem.tintColor = [UIColor systemGreenColor];
    self.navigationItem.rightBarButtonItem = installItem;

    _installFabricAPI = YES;  // Fabric 默认勾选 Fabric API（与 FCL 默认行为一致）

    [self setupLoaders];
    [self setupNameBar];
    [self setupTableView];
    [self refreshIncompatibilities];
    [self refreshVersionName];
}

- (void)refreshBackgroundEffect {
    // 背景效果切换时刷新 cell 与 nameBar 的毛玻璃外观
    [_tableView reloadData];
}

#pragma mark Setup

- (void)setupLoaders {
    _loaders = [NSMutableArray array];

    BOOL fabricCompatible = [self isFabricCompatible];
    BOOL quiltCompatible = [self isQuiltCompatible];
    BOOL forgeCompatible = [self isForgeCompatible];
    BOOL neoForgeCompatible = [self isNeoForgeCompatible];
    BOOL optiFineCompatible = [self isOptiFineCompatible];

    // 通过 ModLoaderIconHelper 统一获取加载器图标和品牌色（优先 PNG，回退 SF Symbol）
    NSArray *defs = @[
        @{ @"id": @"vanilla",  @"name": localize(@"i18n_str_1212", nil), @"desc": localize(@"i18n_str_1213", nil), @"compatible": @YES },
        @{ @"id": @"fabric",   @"name": @"Fabric",        @"desc": localize(@"i18n_str_1214", nil),      @"compatible": @(fabricCompatible) },
        @{ @"id": @"forge",    @"name": @"Forge",         @"desc": localize(@"i18n_str_1215", nil),        @"compatible": @(forgeCompatible) },
        @{ @"id": @"neoforge", @"name": @"NeoForge",      @"desc": localize(@"i18n_str_1216", nil),          @"compatible": @(neoForgeCompatible) },
        @{ @"id": @"quilt",    @"name": @"Quilt",         @"desc": localize(@"i18n_str_1217", nil),         @"compatible": @(quiltCompatible) },
        @{ @"id": @"optifine", @"name": @"OptiFine",      @"desc": localize(@"i18n_str_1218", nil),  @"compatible": @(optiFineCompatible) },
    ];

    for (NSDictionary *d in defs) {
        ModLoaderRow *row = [ModLoaderRow new];
        row.identifier = d[@"id"];
        row.name = d[@"name"];
        row.desc = d[@"desc"];
        // 通过 ModLoaderIconHelper 统一获取图标符号名和品牌色（PNG 缺失时回退用）
        row.iconName = [ModLoaderIconHelper symbolNameForLoader:d[@"id"]];
        row.compatible = [d[@"compatible"] boolValue];
        row.iconColor = [ModLoaderIconHelper brandColorForLoader:d[@"id"]];
        [_loaders addObject:row];
    }
}

- (void)setupNameBar {
    // FCL 风格 name_bar：紧凑横向条目（"版本名" label + 输入框），高度 40pt
    _nameBar = [[UIView alloc] init];
    _nameBar.translatesAutoresizingMaskIntoConstraints = NO;
    // 适配自定义启动器背景：有全局背景时用毛玻璃，否则用默认实色
    if ([[BackgroundManager sharedManager] hasBackground]) {
        _nameBar.backgroundColor = [UIColor clearColor];
        [[BackgroundManager sharedManager] applyEffectToView:_nameBar];
        _nameBar.layer.cornerRadius = 10;
        _nameBar.layer.masksToBounds = YES;
    } else {
        _nameBar.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        _nameBar.layer.cornerRadius = 10;
        _nameBar.layer.masksToBounds = YES;
    }
    [self.view addSubview:_nameBar];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = localize(@"i18n_str_1219", nil);
    label.font = [UIFont systemFontOfSize:[ScreenUtils sp:13] weight:UIFontWeightMedium];
    label.textColor = [UIColor secondaryLabelColor];
    label.adjustsFontForContentSizeCategory = NO;
    [_nameBar addSubview:label];

    _versionNameField = [[UITextField alloc] init];
    _versionNameField.translatesAutoresizingMaskIntoConstraints = NO;
    _versionNameField.font = [UIFont systemFontOfSize:[ScreenUtils sp:14]];
    _versionNameField.textColor = [UIColor labelColor];
    _versionNameField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:localize(@"i18n_str_1220", nil)
                                                                             attributes:@{
        NSForegroundColorAttributeName: [UIColor placeholderTextColor]
    }];
    _versionNameField.borderStyle = UITextBorderStyleNone;
    _versionNameField.returnKeyType = UIReturnKeyDone;
    _versionNameField.delegate = self;
    _versionNameField.autocorrectionType = UITextAutocorrectionTypeNo;
    _versionNameField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _versionNameField.clearButtonMode = UITextFieldViewModeWhileEditing;
    [_nameBar addSubview:_versionNameField];

    [NSLayoutConstraint activateConstraints:@[
        [_nameBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [_nameBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_nameBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_nameBar.heightAnchor constraintEqualToConstant:40],

        [label.leadingAnchor constraintEqualToAnchor:_nameBar.leadingAnchor constant:12],
        [label.centerYAnchor constraintEqualToAnchor:_nameBar.centerYAnchor],

        [_versionNameField.leadingAnchor constraintEqualToAnchor:label.trailingAnchor constant:10],
        [_versionNameField.trailingAnchor constraintEqualToAnchor:_nameBar.trailingAnchor constant:-12],
        [_versionNameField.centerYAnchor constraintEqualToAnchor:_nameBar.centerYAnchor],
        [_versionNameField.heightAnchor constraintEqualToAnchor:_nameBar.heightAnchor],
    ]];
}

- (void)setupTableView {
    // FCL 风格：扁平 UITableView InsetGrouped，加载器列表 + 附加选项 section
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.backgroundView = nil;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 54;
    _tableView.estimatedRowHeight = 54;
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    // extendedLayoutIncludesOpaqueBars / edgesForExtendedLayout 是 UIViewController 的属性，
    // 不能设置到 UITableView 上，否则编译报 "property not found on object of type 'UITableView *'"
    self.extendedLayoutIncludesOpaqueBars = YES;
    self.edgesForExtendedLayout = UIRectEdgeAll;
    _tableView.sectionHeaderTopPadding = 0;
    [_tableView registerClass:[ModLoaderRowCell class] forCellReuseIdentifier:@"LoaderRowCell"];
    [_tableView registerClass:[ModLoaderSwitchCell class] forCellReuseIdentifier:@"SwitchCell"];
    [self.view addSubview:_tableView];

    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:_nameBar.bottomAnchor constant:8],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

#pragma mark Compatibility checks (与原 LoaderSelectionViewController 一致)

- (BOOL)isFabricCompatible {
    if (!_gameVersion) return YES;
    NSArray *c = [_gameVersion componentsSeparatedByString:@"."];
    if (c.count < 2) return YES;
    NSInteger major = [c[0] integerValue];
    NSInteger minor = [c[1] integerValue];
    if (major > 1) return YES;
    if (major == 1 && minor >= 14) return YES;
    return NO;
}

- (BOOL)isQuiltCompatible {
    if (!_gameVersion) return YES;
    NSArray *c = [_gameVersion componentsSeparatedByString:@"."];
    if (c.count < 2) return YES;
    NSInteger major = [c[0] integerValue];
    NSInteger minor = [c[1] integerValue];
    if (major > 1) return YES;
    if (major == 1 && minor >= 18) return YES;
    return NO;
}

- (BOOL)isForgeCompatible {
    if (!_gameVersion) return YES;
    NSArray *c = [_gameVersion componentsSeparatedByString:@"."];
    if (c.count < 2) return YES;
    NSInteger major = [c[0] integerValue];
    NSInteger minor = [c[1] integerValue];
    if (major == 1 && minor >= 1) return YES;
    if (major > 1) return YES;
    return NO;
}

- (BOOL)isNeoForgeCompatible {
    if (!_gameVersion) return NO;
    NSArray *c = [_gameVersion componentsSeparatedByString:@"."];
    if (c.count < 2) return NO;
    NSInteger major = [c[0] integerValue];
    NSInteger minor = [c[1] integerValue];
    NSInteger patch = (c.count > 2) ? [c[2] integerValue] : 0;
    if (major > 1) return YES;
    if (major == 1 && minor == 20 && patch >= 1) return YES;
    if (major == 1 && minor > 20) return YES;
    return NO;
}

- (BOOL)isOptiFineCompatible {
    // OptiFine 1.14+ 与 Forge 兼容，1.13 及以下独立装为版本补丁
    if (!_gameVersion) return YES;
    NSArray *c = [_gameVersion componentsSeparatedByString:@"."];
    if (c.count < 2) return YES;
    NSInteger major = [c[0] integerValue];
    NSInteger minor = [c[1] integerValue];
    if (major > 1) return YES;
    if (major == 1 && minor >= 8) return YES;
    return NO;
}

#pragma mark Compatibility (互斥逻辑，参照 FCL InstallerItemGroup)

- (NSString *)incompatibleReasonForLoaderId:(NSString *)loaderId {
    // fabricApi 与 forge/optifine/neoforge 互斥
    // optifine 与 fabric/quilt/neoforge 互斥（与 forge 可共存）
    // forge/fabric/quilt/neoforge 互斥

    if ([loaderId isEqualToString:@"vanilla"]) return nil;

    BOOL fabricSelected  = [_selectedLoaderId isEqualToString:@"fabric"];
    BOOL forgeSelected   = [_selectedLoaderId isEqualToString:@"forge"];
    BOOL neoSelected     = [_selectedLoaderId isEqualToString:@"neoforge"];
    BOOL quiltSelected   = [_selectedLoaderId isEqualToString:@"quilt"];
    BOOL optiSelected    = [_selectedLoaderId isEqualToString:@"optifine"];

    if ([loaderId isEqualToString:@"fabric"] || [loaderId isEqualToString:@"forge"] ||
        [loaderId isEqualToString:@"neoforge"] || [loaderId isEqualToString:@"quilt"]) {
        // 加载器组互斥
        if (fabricSelected  && ![loaderId isEqualToString:@"fabric"])  return localize(@"i18n_str_1221", nil);
        if (forgeSelected   && ![loaderId isEqualToString:@"forge"])   return localize(@"i18n_str_1222", nil);
        if (neoSelected     && ![loaderId isEqualToString:@"neoforge"]) return localize(@"i18n_str_1223", nil);
        if (quiltSelected   && ![loaderId isEqualToString:@"quilt"])   return localize(@"i18n_str_1224", nil);
        // optifine 与 fabric/quilt/neoforge 互斥
        if (optiSelected) {
            if ([loaderId isEqualToString:@"fabric"])  return localize(@"i18n_str_1225", nil);
            if ([loaderId isEqualToString:@"quilt"])   return localize(@"i18n_str_1225", nil);
            if ([loaderId isEqualToString:@"neoforge"]) return localize(@"i18n_str_1225", nil);
        }
    }

    if ([loaderId isEqualToString:@"optifine"]) {
        if (fabricSelected)  return localize(@"i18n_str_1221", nil);
        if (quiltSelected)   return localize(@"i18n_str_1224", nil);
        if (neoSelected)     return localize(@"i18n_str_1223", nil);
    }

    return nil;
}

- (void)refreshIncompatibilities {
    // 重新渲染所有行，互斥/兼容状态在 cellForRowAtIndexPath 中计算
    [_tableView reloadData];
}

#pragma mark Version name (参照 FCL VersionInstallInfoPage.generateVersionName)

- (NSString *)generateVersionName {
    if (!_gameVersion) return @"";
    NSMutableString *name = [NSMutableString stringWithString:_gameVersion];

    // 已选加载器追加 -loaderName
    NSString *loaderId = _selectedLoaderId;
    if (loaderId.length > 0 && ![loaderId isEqualToString:@"vanilla"]) {
        NSString *loaderName = nil;
        if ([loaderId isEqualToString:@"fabric"])   loaderName = @"fabric";
        else if ([loaderId isEqualToString:@"forge"])    loaderName = @"forge";
        else if ([loaderId isEqualToString:@"neoforge"]) loaderName = @"neoforge";
        else if ([loaderId isEqualToString:@"quilt"])    loaderName = @"quilt";
        else if ([loaderId isEqualToString:@"optifine"]) loaderName = @"OptiFine";
        if (loaderName) [name appendFormat:@"-%@", loaderName];
    }

    // 若同时勾选了 OptiFine（与 Forge 共存），追加 -OptiFine
    if (_installOptiFine && [loaderId isEqualToString:@"forge"]) {
        if (![_selectedLoaderId isEqualToString:@"optifine"]) {
            [name appendString:@"-OptiFine"];
        }
    }

    return [name copy];
}

- (void)refreshVersionName {
    if (_nameManuallyModified) return;
    // 注意：变量名不能使用 "auto"，因为 auto 是 C/C++/Objective-C 的保留关键字
    // （存储类说明符），作为标识符会导致 "expected identifier or '('" 编译错误。
    // 改用 autoGeneratedName 以避免与关键字冲突。
    NSString *autoGeneratedName = [self generateVersionName];
    if (![autoGeneratedName isEqualToString:_versionNameField.text]) {
        // programmatic edit, ignore text change notification
        _versionNameField.text = autoGeneratedName;
    }
}

#pragma mark Actions

- (void)backTapped {
    if (_cancelled) _cancelled();
    if (self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)installTapped {
    if (_selectedLoaderId.length == 0) {
        [self showAlert:localize(@"i18n_str_1226", nil) message:nil];
        return;
    }

    if (![_selectedLoaderId isEqualToString:@"vanilla"] && ![_selectedLoaderId isEqualToString:@"optifine"]) {
        NSString *selectedVersion = [self selectedVersionForLoader:_selectedLoaderId];
        if (selectedVersion.length == 0) {
            [self showAlert:localize(@"i18n_str_1227", nil) message:localize(@"i18n_str_1228", nil)];
            return;
        }
    }

    // OptiFine 单独安装时必须有选中版本
    if ([_selectedLoaderId isEqualToString:@"optifine"] && _selectedOptiFineVersion.length == 0) {
        [self showAlert:localize(@"i18n_str_1229", nil) message:nil];
        return;
    }

    BOOL installFabricAPI = NO;
    BOOL installOptiFine = NO;
    NSString *loaderVersion = [self selectedVersionForLoader:_selectedLoaderId];

    if ([_selectedLoaderId isEqualToString:@"fabric"]) {
        installFabricAPI = _installFabricAPI;
    } else if ([_selectedLoaderId isEqualToString:@"forge"]) {
        installOptiFine = _installOptiFine;
    } else if ([_selectedLoaderId isEqualToString:@"optifine"]) {
        // 单独安装 OptiFine：作为版本补丁
        installOptiFine = YES;
        // 单独 optifine 时 loaderVersion 为 OptiFine 完整描述（type\x1fpatch\x1ffilename\x1fdisplay）
        loaderVersion = _selectedOptiFineVersion;
    }

    if (_completion) {
        _completion(_selectedLoaderId, installFabricAPI, installOptiFine, loaderVersion);
    }
}

- (NSString *)selectedVersionForLoader:(NSString *)loaderId {
    if ([loaderId isEqualToString:@"fabric"])   return _selectedFabricVersion;
    if ([loaderId isEqualToString:@"forge"])    return _selectedForgeVersion;
    if ([loaderId isEqualToString:@"neoforge"]) return _selectedNeoForgeVersion;
    if ([loaderId isEqualToString:@"quilt"])    return _selectedQuiltVersion;
    if ([loaderId isEqualToString:@"optifine"]) return _selectedOptiFineVersion;
    return nil;
}

- (void)setSelectedVersion:(NSString *)version forLoader:(NSString *)loaderId {
    if ([loaderId isEqualToString:@"fabric"])   self.selectedFabricVersion = version;
    else if ([loaderId isEqualToString:@"forge"])    self.selectedForgeVersion = version;
    else if ([loaderId isEqualToString:@"neoforge"]) self.selectedNeoForgeVersion = version;
    else if ([loaderId isEqualToString:@"quilt"])    self.selectedQuiltVersion = version;
    else if ([loaderId isEqualToString:@"optifine"]) {
        self.selectedOptiFineVersion = version;
        // 解析 packed 格式：type\x1fpatch\x1ffilename\x1fdisplay
        if ([version containsString:@"\x1f"]) {
            NSArray *parts = [version componentsSeparatedByString:@"\x1f"];
            if (parts.count >= 3) {
                self.selectedOptiFineType = parts[0];
                self.selectedOptiFinePatch = parts[1];
                self.selectedOptiFineFilename = parts[2];
            }
        }
    }
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_406", nil) style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - TextField

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    // 用户开始手动编辑
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    // 注意：变量名不能使用 "auto"，因为 auto 是 C/C++/Objective-C 的保留关键字
    // （存储类说明符），作为标识符会导致 "expected identifier or '('" 编译错误。
    // 改用 autoGeneratedName 以避免与关键字冲突。
    NSString *autoGeneratedName = [self generateVersionName];
    if (textField.text.length == 0) {
        _nameManuallyModified = NO;
        textField.text = autoGeneratedName;
    } else if (![textField.text isEqualToString:autoGeneratedName]) {
        _nameManuallyModified = YES;
    }
}

#pragma mark - TableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;  // 0: 加载器列表, 1: 附加选项
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) {
        return _loaders.count;
    }
    // section 1: 附加选项
    return [self currentOptions].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return localize(@"i18n_str_160", nil);
    return [self currentOptions].count > 0 ? localize(@"i18n_str_2048", nil) : nil;
}

- (NSMutableArray *)currentOptions {
    NSMutableArray *opts = [NSMutableArray array];
    if ([_selectedLoaderId isEqualToString:@"fabric"]) {
        [opts addObject:@{ @"type": @"fabric_api" }];
    }
    if ([_selectedLoaderId isEqualToString:@"forge"]) {
        [opts addObject:@{ @"type": @"optifine_mod" }];
    }
    return opts;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        ModLoaderRowCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LoaderRowCell" forIndexPath:indexPath];
        ModLoaderRow *row = _loaders[indexPath.row];

        BOOL isSelected = [_selectedLoaderId isEqualToString:row.identifier];

        // 计算选中版本的显示文本（OptiFine packed 格式提取 display）
        NSString *versionDisplay = nil;
        if (isSelected && ![row.identifier isEqualToString:@"vanilla"]) {
            NSString *selVer = [self selectedVersionForLoader:row.identifier];
            if (selVer.length > 0) {
                versionDisplay = selVer;
                if ([selVer containsString:@"\x1f"]) {
                    NSArray *parts = [selVer componentsSeparatedByString:@"\x1f"];
                    if (parts.count >= 4) versionDisplay = parts[3];
                    else if (parts.count >= 1) versionDisplay = parts[0];
                }
            }
        }

        // 兼容性 + 互斥判断
        BOOL incompatible = NO;
        NSString *reason = nil;
        if (!row.compatible) {
            incompatible = YES;
            reason = localize(@"i18n_str_1231", nil);
        } else {
            reason = [self incompatibleReasonForLoaderId:row.identifier];
            if (reason) incompatible = YES;
        }

        [cell configureWithRow:row
                    isSelected:isSelected
          selectedVersionDisplay:versionDisplay
                    incompatible:incompatible
                         reason:reason];
        // 适配自定义启动器背景：cell 应用毛玻璃/半透明效果
        [[BackgroundManager sharedManager] applyEffectToCell:cell];
        return cell;
    } else {
        // section 1: 附加选项（Fabric API / OptiFine 共存开关）
        ModLoaderSwitchCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SwitchCell" forIndexPath:indexPath];
        NSMutableArray *opts = [self currentOptions];
        NSDictionary *opt = opts[indexPath.row];
        NSString *type = opt[@"type"];

        if ([type isEqualToString:@"fabric_api"]) {
            cell.titleLabel.text = localize(@"i18n_str_1232", nil);
            cell.descLabel.text = localize(@"i18n_str_1233", nil);
            cell.switchControl.on = _installFabricAPI;
            cell.switchControl.tag = 1001;
        } else if ([type isEqualToString:@"optifine_mod"]) {
            cell.titleLabel.text = localize(@"i18n_str_1234", nil);
            cell.descLabel.text = localize(@"i18n_str_1235", nil);
            cell.switchControl.on = _installOptiFine;
            cell.switchControl.tag = 1002;
        } else {
            cell.titleLabel.text = @"";
            cell.descLabel.text = @"";
            cell.switchControl.on = NO;
            cell.switchControl.tag = 0;
        }
        [cell.switchControl removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
        [cell.switchControl addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        // 适配自定义启动器背景：cell 应用毛玻璃/半透明效果
        [[BackgroundManager sharedManager] applyEffectToCell:cell];
        return cell;
    }
}

- (void)switchChanged:(UISwitch *)sender {
    if (sender.tag == 1001) {
        _installFabricAPI = sender.on;
    } else if (sender.tag == 1002) {
        _installOptiFine = sender.on;
    }
    [self refreshVersionName];
    // 重新加载 section 0 让行选中状态和互斥状态同步刷新
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 0) return;

    ModLoaderRow *row = _loaders[indexPath.row];
    if (!row.compatible) return;

    NSString *reason = [self incompatibleReasonForLoaderId:row.identifier];
    if (reason) {
        [self showAlert:reason message:nil];
        return;
    }

    if ([row.identifier isEqualToString:@"vanilla"]) {
        _selectedLoaderId = @"vanilla";
        // 清空加载器版本（vanilla 无需版本号）
        _installOptiFine = NO;
        _installFabricAPI = NO;
        [self refreshVersionName];
        [tableView reloadData];
        return;
    }

    // 切换加载器
    _selectedLoaderId = row.identifier;
    // 重置互斥选项
    if (![row.identifier isEqualToString:@"fabric"])  _installFabricAPI = NO;
    if (![row.identifier isEqualToString:@"forge"])   _installOptiFine = NO;
    if ([row.identifier isEqualToString:@"fabric"])   _installFabricAPI = YES;

    [self refreshVersionName];

    // 直接 push 版本选择页
    [self pushVersionPickerForLoader:row.identifier];
    [tableView reloadData];
}

- (void)pushVersionPickerForLoader:(NSString *)loaderId {
    ModLoaderVersionPickerViewController *picker = [[ModLoaderVersionPickerViewController alloc] init];
    picker.loaderId = loaderId;
    picker.gameVersion = _gameVersion;
    picker.selectedVersion = [self selectedVersionForLoader:loaderId];

    __weak typeof(self) weakSelf = self;
    picker.onSelected = ^(NSString *version) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf setSelectedVersion:version forLoader:loaderId];
        [strongSelf refreshVersionName];
        [strongSelf.tableView reloadData];
    };
    picker.onCancelled = nil;

    [self.navigationController pushViewController:picker animated:YES];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
