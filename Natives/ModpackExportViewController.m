#import "utils.h"
//
//  ModpackExportViewController.m
//  Amethyst
//
//  参照 FCL ExportModpackViewModel / HMCL ModpackExportPanel / ZL2 ModpackExportScreen 重做
//
//  功能：
//    1. Profile 选择（含 gameDir 预览、loader 信息）
//    2. 5 种格式选择（Modrinth / CurseForge / MMC / Plain Zip / 链接列表）
//    3. 名称 / 版本号 / 作者 输入
//    4. 文件过滤选项（mods / configs / resourcepacks / shaderpacks / saves / options / servers / scripts）
//    5. 进度卡片（百分比 + 阶段文案 + 取消按钮）
//    6. 完成后分享按钮
//

#import "ModpackExportViewController.h"
#import "BackgroundManager.h"
#import "ModpackExportService.h"
#import "PLProfiles.h"

@interface ModpackExportViewController () <UITextFieldDelegate, UITableViewDataSource, UITableViewDelegate>

// 数据
@property (nonatomic, strong) NSArray<NSString *> *profileNames;
@property (nonatomic, copy) NSString *selectedProfileName;
@property (nonatomic, assign) ModpackExportFormat selectedFormat;
@property (nonatomic, assign) ModpackExportFileOptions fileOptions;

// UI - 表单
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *formStackView;

// Profile 选择
@property (nonatomic, strong) UIButton *profileButton;
@property (nonatomic, strong) UILabel *profileInfoLabel;

// 格式选择
@property (nonatomic, strong) UISegmentedControl *formatSegment;

// 名称/版本/作者
@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UITextField *versionField;
@property (nonatomic, strong) UITextField *authorField;

// 文件选项
@property (nonatomic, strong) UITableView *fileOptionsTableView;
@property (nonatomic, strong) NSArray<NSDictionary *> *fileOptionItems;

// 导出按钮
@property (nonatomic, strong) UIButton *exportButton;

// 进度卡片
@property (nonatomic, strong) UIView *progressOverlay;
@property (nonatomic, strong) UIView *progressCard;
@property (nonatomic, strong) UILabel *progressTitleLabel;
@property (nonatomic, strong) UILabel *progressPercentLabel;
@property (nonatomic, strong) UIProgressView *progressBar;
@property (nonatomic, strong) UILabel *progressStageLabel;
@property (nonatomic, strong) UIActivityIndicatorView *progressSpinner;
@property (nonatomic, strong) UIButton *progressCancelButton;

@end

@implementation ModpackExportViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.title = localize(@"i18n_str_490", nil);
    self.view.backgroundColor = [UIColor clearColor];
    [[BackgroundManager sharedManager] applyEffectToView:self.view];

    self.selectedFormat = ModpackExportFormatModrinth;
    self.fileOptions = ModpackExportFileDefault;

    [self loadProfiles];
    [self setupUI];
    [self refreshProfileInfo];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleBackgroundUIEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"BackgroundUIEffectChanged" object:nil];
}

- (void)loadProfiles {
    NSDictionary *profiles = PLProfiles.current.profiles;
    self.profileNames = [profiles.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    if (self.profileNames.count == 0) {
        // 没有 profile，禁用导出
        return;
    }
    // 预选 profile
    if (self.preselectedProfileName && [self.profileNames containsObject:self.preselectedProfileName]) {
        self.selectedProfileName = self.preselectedProfileName;
    } else {
        NSString *current = PLProfiles.current.selectedProfileName;
        if (current && [self.profileNames containsObject:current]) {
            self.selectedProfileName = current;
        } else {
            self.selectedProfileName = self.profileNames.firstObject;
        }
    }
}

#pragma mark - Setup UI

- (void)setupUI {
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.scrollView];

    self.formStackView = [[UIStackView alloc] init];
    self.formStackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.formStackView.axis = UILayoutConstraintAxisVertical;
    self.formStackView.spacing = 16;
    self.formStackView.alignment = UIStackViewAlignmentFill;
    [self.scrollView addSubview:self.formStackView];

    // Profile 选择区
    [self.formStackView addArrangedSubview:[self createProfileSection]];
    // 格式选择区
    [self.formStackView addArrangedSubview:[self createFormatSection]];
    // 信息输入区
    [self.formStackView addArrangedSubview:[self createInfoFieldsSection]];
    // 文件选项区
    [self.formStackView addArrangedSubview:[self createFileOptionsSection]];
    // 导出按钮
    [self.formStackView addArrangedSubview:[self createExportButtonSection]];

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],

        [self.formStackView.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:16],
        [self.formStackView.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor constant:16],
        [self.formStackView.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor constant:-16],
        [self.formStackView.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-16],
        [self.formStackView.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor constant:-32]
    ]];
}

/// 创建带标题的卡片容器
- (UIView *)createCardContainerWithTitle:(NSString *)title {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 14;
    card.layer.masksToBounds = YES;

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor secondaryLabelColor];
    [card addSubview:titleLabel];

    UIStackView *contentStack = [[UIStackView alloc] init];
    contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    contentStack.axis = UILayoutConstraintAxisVertical;
    contentStack.spacing = 10;
    // 用 tag 标记 contentStack，便于后续从 card 取回，避免使用 KVC（UIView 无 contentStack 属性会抛 NSUndefinedKeyException）
    contentStack.tag = 9527;
    [card addSubview:contentStack];

    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [titleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [contentStack.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10],
        [contentStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [contentStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [contentStack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14]
    ]];

    return card;
}

- (UIStackView *)contentStackOfCard:(UIView *)card {
    for (UIView *v in card.subviews) {
        if ([v isKindOfClass:[UIStackView class]] && v.tag == 9527) {
            return (UIStackView *)v;
        }
    }
    return nil;
}

#pragma mark - Profile Section

- (UIView *)createProfileSection {
    UIView *card = [self createCardContainerWithTitle:localize(@"i18n_str_491", nil)];
    UIStackView *stack = [self contentStackOfCard:card];

    self.profileButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.profileButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.profileButton setTitle:localize(@"i18n_str_492", nil) forState:UIControlStateNormal];
    self.profileButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.profileButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.profileButton.contentEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 0);
    [self.profileButton setImage:[UIImage systemImageNamed:@"person.crop.circle"] forState:UIControlStateNormal];
    [self.profileButton setTintColor:[UIColor systemBlueColor]];
    [self.profileButton addTarget:self action:@selector(showProfilePicker) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.profileButton];

    self.profileInfoLabel = [[UILabel alloc] init];
    self.profileInfoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.profileInfoLabel.font = [UIFont systemFontOfSize:12];
    self.profileInfoLabel.textColor = [UIColor tertiaryLabelColor];
    self.profileInfoLabel.numberOfLines = 0;
    [stack addArrangedSubview:self.profileInfoLabel];

    return card;
}

- (void)refreshProfileInfo {
    if (self.profileNames.count == 0) {
        [self.profileButton setTitle:localize(@"i18n_str_493", nil) forState:UIControlStateNormal];
        self.profileInfoLabel.text = localize(@"i18n_str_494", nil);
        self.exportButton.enabled = NO;
        self.exportButton.backgroundColor = [UIColor systemGray3Color];
        return;
    }
    [self.profileButton setTitle:self.selectedProfileName forState:UIControlStateNormal];

    NSDictionary *profile = PLProfiles.current.profiles[self.selectedProfileName];
    if (![profile isKindOfClass:[NSDictionary class]]) {
        self.profileInfoLabel.text = localize(@"i18n_str_495", nil);
        return;
    }
    NSString *lastVersionId = profile[@"lastVersionId"] ?: @"";
    NSString *gameDir = [PLProfiles effectiveGameDirForProfile:profile];
    NSDictionary *parsed = [ModpackExportService parseVersionId:lastVersionId];
    NSString *mcVer = parsed[@"minecraft"] ?: localize(@"i18n_str_121", nil);
    NSString *loader = parsed[@"loader"] ?: @"vanilla";
    NSString *loaderVer = parsed[@"loaderVersion"] ?: @"";

    NSString *info = [NSString stringWithFormat:localize(@"i18n_str_496", nil),
                      mcVer, loader, loaderVer, gameDir];
    self.profileInfoLabel.text = info;
}

#pragma mark - Format Section

- (UIView *)createFormatSection {
    UIView *card = [self createCardContainerWithTitle:localize(@"i18n_str_497", nil)];
    UIStackView *stack = [self contentStackOfCard:card];

    self.formatSegment = [[UISegmentedControl alloc] initWithItems:@[
        @"Modrinth", @"CurseForge", @"MMC", @"Plain Zip", localize(@"i18n_str_1316", nil)
    ]];
    self.formatSegment.translatesAutoresizingMaskIntoConstraints = NO;
    self.formatSegment.selectedSegmentIndex = 0;
    [self.formatSegment addTarget:self action:@selector(formatChanged:) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:self.formatSegment];

    UILabel *hint = [[UILabel alloc] init];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.font = [UIFont systemFontOfSize:11];
    hint.textColor = [UIColor tertiaryLabelColor];
    hint.numberOfLines = 0;
    hint.text = localize(@"i18n_str_499", nil);
    [stack addArrangedSubview:hint];

    return card;
}

- (void)formatChanged:(UISegmentedControl *)sender {
    self.selectedFormat = (ModpackExportFormat)sender.selectedSegmentIndex;
}

#pragma mark - Info Fields

- (UIView *)createInfoFieldsSection {
    UIView *card = [self createCardContainerWithTitle:localize(@"i18n_str_500", nil)];
    UIStackView *stack = [self contentStackOfCard:card];

    self.nameField = [self createTextFieldWithPlaceholder:localize(@"i18n_str_501", nil)];
    self.versionField = [self createTextFieldWithPlaceholder:localize(@"i18n_str_502", nil)];
    self.authorField = [self createTextFieldWithPlaceholder:localize(@"i18n_str_503", nil)];

    // 预填
    self.versionField.text = @"1.0";
    self.authorField.text = @"Amethyst User";
    if (self.selectedProfileName) {
        self.nameField.text = self.selectedProfileName;
    }

    [stack addArrangedSubview:self.nameField];
    [stack addArrangedSubview:self.versionField];
    [stack addArrangedSubview:self.authorField];
    return card;
}

- (UITextField *)createTextFieldWithPlaceholder:(NSString *)placeholder {
    UITextField *field = [[UITextField alloc] init];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.placeholder = placeholder;
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.font = [UIFont systemFontOfSize:15];
    field.delegate = self;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    [field.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    return field;
}

#pragma mark - File Options Section

- (UIView *)createFileOptionsSection {
    UIView *card = [self createCardContainerWithTitle:localize(@"i18n_str_504", nil)];
    UIStackView *stack = [self contentStackOfCard:card];

    // 文件选项数据
    self.fileOptionItems = @[
        @{@"key": @(ModpackExportFileMods),           @"title": localize(@"i18n_str_505", nil),            @"default": @YES},
        @{@"key": @(ModpackExportFileConfigs),        @"title": localize(@"i18n_str_506", nil),         @"default": @YES},
        @{@"key": @(ModpackExportFileResourcePacks),  @"title": localize(@"i18n_str_507", nil),@"default": @YES},
        @{@"key": @(ModpackExportFileShaderPacks),    @"title": localize(@"i18n_str_508", nil),    @"default": @YES},
        @{@"key": @(ModpackExportFileScripts),        @"title": localize(@"i18n_str_509", nil),  @"default": @YES},
        @{@"key": @(ModpackExportFileGameSettings),   @"title": localize(@"i18n_str_510", nil),  @"default": @YES},
        @{@"key": @(ModpackExportFileSaves),          @"title": localize(@"i18n_str_511", nil),          @"default": @NO},
        @{@"key": @(ModpackExportFileServers),        @"title": localize(@"i18n_str_512", nil),@"default": @NO},
    ];

    self.fileOptionsTableView = [[UITableView alloc] init];
    self.fileOptionsTableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.fileOptionsTableView.dataSource = self;
    self.fileOptionsTableView.delegate = self;
    self.fileOptionsTableView.backgroundColor = [UIColor clearColor];
    self.fileOptionsTableView.backgroundView = nil;
    self.fileOptionsTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.fileOptionsTableView.scrollEnabled = NO;
    [self.fileOptionsTableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"FileOptionCell"];

    // UITableView 高度自适应：根据行数计算
    NSLayoutConstraint *heightConstraint = [self.fileOptionsTableView.heightAnchor constraintEqualToConstant:self.fileOptionItems.count * 44];
    heightConstraint.priority = UILayoutPriorityRequired;
    heightConstraint.active = YES;

    [stack addArrangedSubview:self.fileOptionsTableView];
    return card;
}

#pragma mark - File Options TableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.fileOptionItems.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"FileOptionCell" forIndexPath:indexPath];
    cell.backgroundColor = [UIColor clearColor];
    cell.backgroundView = nil;

    NSDictionary *item = self.fileOptionItems[indexPath.row];
    NSString *title = item[@"title"];
    NSNumber *keyNum = item[@"key"];
    ModpackExportFileOptions key = (ModpackExportFileOptions)[keyNum integerValue];

    cell.textLabel.text = title;
    cell.textLabel.font = [UIFont systemFontOfSize:14];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryType = (self.fileOptions & key) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *item = self.fileOptionItems[indexPath.row];
    NSNumber *keyNum = item[@"key"];
    ModpackExportFileOptions key = (ModpackExportFileOptions)[keyNum integerValue];

    if (self.fileOptions & key) {
        self.fileOptions &= ~key;
    } else {
        self.fileOptions |= key;
    }
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - Export Button

- (UIView *)createExportButtonSection {
    self.exportButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.exportButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.exportButton setTitle:localize(@"i18n_str_513", nil) forState:UIControlStateNormal];
    [self.exportButton setImage:[UIImage systemImageNamed:@"square.and.arrow.up"] forState:UIControlStateNormal];
    [self.exportButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.exportButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.exportButton.backgroundColor = [UIColor systemBlueColor];
    self.exportButton.layer.cornerRadius = 12;
    self.exportButton.layer.masksToBounds = YES;
    self.exportButton.tintColor = [UIColor whiteColor];
    [self.exportButton addTarget:self action:@selector(startExport) forControlEvents:UIControlEventTouchUpInside];

    [self.exportButton.heightAnchor constraintEqualToConstant:50].active = YES;

    UIView *wrapper = [[UIView alloc] init];
    wrapper.translatesAutoresizingMaskIntoConstraints = NO;
    [wrapper addSubview:self.exportButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.exportButton.topAnchor constraintEqualToAnchor:wrapper.topAnchor],
        [self.exportButton.leadingAnchor constraintEqualToAnchor:wrapper.leadingAnchor],
        [self.exportButton.trailingAnchor constraintEqualToAnchor:wrapper.trailingAnchor],
        [self.exportButton.bottomAnchor constraintEqualToAnchor:wrapper.bottomAnchor]
    ]];
    return wrapper;
}

#pragma mark - Profile Picker

- (void)showProfilePicker {
    if (self.profileNames.count == 0) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_492", nil)
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *name in self.profileNames) {
        NSString *title = name;
        if ([name isEqualToString:self.selectedProfileName]) {
            title = [NSString stringWithFormat:@"%@ ✓", name];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            self.selectedProfileName = name;
            [self refreshProfileInfo];
            if (self.nameField.text.length == 0 || [self.profileNames containsObject:self.nameField.text]) {
                self.nameField.text = name;
            }
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        sheet.popoverPresentationController.sourceView = self.profileButton;
        sheet.popoverPresentationController.sourceRect = self.profileButton.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Export

- (void)startExport {
    if (self.profileNames.count == 0 || !self.selectedProfileName) {
        [self showAlertWithTitle:localize(@"i18n_str_514", nil) message:localize(@"i18n_str_515", nil)];
        return;
    }
    if (self.fileOptions == 0) {
        [self showAlertWithTitle:localize(@"i18n_str_514", nil) message:localize(@"i18n_str_516", nil)];
        return;
    }

    NSString *name = self.nameField.text ?: @"";
    NSString *version = self.versionField.text ?: @"1.0";
    NSString *author = self.authorField.text ?: @"Amethyst User";
    if (name.length == 0) name = self.selectedProfileName;
    if (version.length == 0) version = @"1.0";

    // 确定扩展名
    NSString *ext = @"zip";
    switch (self.selectedFormat) {
        case ModpackExportFormatModrinth:   ext = @"mrpack"; break;
        case ModpackExportFormatCurseForge: ext = @"zip";    break;
        case ModpackExportFormatMMC:        ext = @"zip";    break;
        case ModpackExportFormatPlainZip:   ext = @"zip";    break;
        case ModpackExportFormatLinkList:   ext = @"txt";    break;
    }

    // 文件名清理
    NSString *destPath = [self buildExportPathWithName:name version:version ext:ext];

    [self showProgressCardWithTitle:localize(@"i18n_str_517", nil)];
    [self setProgress:0.0 stageMessage:localize(@"i18n_str_518", nil)];

    // 重置取消状态
    [[ModpackExportService sharedService] resetCancelState];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        BOOL success = [[ModpackExportService sharedService] exportModpackForProfile:self.selectedProfileName
                                                                               toPath:destPath
                                                                                  name:name
                                                                               version:version
                                                                                author:author
                                                                               format:self.selectedFormat
                                                                           fileOptions:self.fileOptions
                                                                              progress:^(double p, NSString *stageMessage) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setProgress:p stageMessage:stageMessage];
            });
        }
                                                                                  error:&error];

        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL wasCancelled = [[error.userInfo objectForKey:NSLocalizedDescriptionKey] containsString:@"取消"];
            [self hideProgressCard];
            if (success) {
                [self showExportSuccessWithPath:destPath];
            } else if (wasCancelled) {
                [self showAlertWithTitle:localize(@"i18n_str_127", nil) message:localize(@"i18n_str_469", nil)];
            } else {
                [self showAlertWithTitle:localize(@"i18n_str_519", nil) message:error.localizedDescription ?: localize(@"i18n_str_97", nil)];
            }
        });
    });
}

- (NSString *)buildExportPathWithName:(NSString *)name version:(NSString *)version ext:(NSString *)ext {
    NSString *exportsDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Exports"];
    [[NSFileManager defaultManager] createDirectoryAtPath:exportsDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSCharacterSet *invalidChars = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|"];
    NSMutableString *safeName = [[[name componentsSeparatedByCharactersInSet:invalidChars] componentsJoinedByString:@"_"] mutableCopy];

    while (safeName.length > 0 && ([safeName hasPrefix:@" "] || [safeName hasPrefix:@"."])) {
        [safeName deleteCharactersInRange:NSMakeRange(0, 1)];
    }
    while (safeName.length > 0 && ([safeName hasSuffix:@" "] || [safeName hasSuffix:@"."])) {
        [safeName deleteCharactersInRange:NSMakeRange(safeName.length - 1, 1)];
    }
    NSArray *reservedNames = @[@"CON", @"PRN", @"AUX", @"NUL",
        @"COM1", @"COM2", @"COM3", @"COM4", @"COM5", @"COM6", @"COM7", @"COM8", @"COM9",
        @"LPT1", @"LPT2", @"LPT3", @"LPT4", @"LPT5", @"LPT6", @"LPT7", @"LPT8", @"LPT9"];
    if ([reservedNames containsObject:safeName.uppercaseString]) {
        [safeName appendString:@"_modpack"];
    }
    if (safeName.length > 200) {
        [safeName deleteCharactersInRange:NSMakeRange(200, safeName.length - 200)];
    }
    if (safeName.length == 0) {
        [safeName setString:@"ExportedModpack"];
    }

    // 版本号也清理
    NSMutableString *safeVersion = [[[version componentsSeparatedByCharactersInSet:invalidChars] componentsJoinedByString:@"_"] mutableCopy];
    if (safeVersion.length == 0) {
        [safeVersion setString:@"1.0"];
    }

    return [exportsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-v%@.%@", safeName, safeVersion, ext]];
}

#pragma mark - Progress Card

- (void)showProgressCardWithTitle:(NSString *)title {
    [self hideProgressCard];

    UIView *overlay = [[UIView alloc] init];
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
    [self.view addSubview:overlay];

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 16;
    card.layer.masksToBounds = YES;
    [overlay addSubview:card];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    [card addSubview:titleLabel];

    UILabel *percentLabel = [[UILabel alloc] init];
    percentLabel.translatesAutoresizingMaskIntoConstraints = NO;
    percentLabel.font = [UIFont systemFontOfSize:36 weight:UIFontWeightHeavy];
    percentLabel.textAlignment = NSTextAlignmentCenter;
    percentLabel.text = @"0%";
    [card addSubview:percentLabel];

    UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.progressTintColor = [UIColor systemBlueColor];
    [card addSubview:bar];

    UILabel *stageLabel = [[UILabel alloc] init];
    stageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    stageLabel.font = [UIFont systemFontOfSize:13];
    stageLabel.textColor = [UIColor secondaryLabelColor];
    stageLabel.textAlignment = NSTextAlignmentCenter;
    stageLabel.numberOfLines = 0;
    [card addSubview:stageLabel];

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    spinner.hidesWhenStopped = YES;
    [card addSubview:spinner];

    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    cancelBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [cancelBtn setTitle:localize(@"i18n_str_520", nil) forState:UIControlStateNormal];
    cancelBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [cancelBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [cancelBtn addTarget:self action:@selector(cancelExport) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:cancelBtn];

    [NSLayoutConstraint activateConstraints:@[
        [overlay.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [overlay.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [overlay.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [overlay.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [card.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:300],

        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:24],
        [titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [titleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],

        [percentLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:16],
        [percentLabel.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],

        [spinner.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:16],
        [spinner.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],

        [bar.topAnchor constraintEqualToAnchor:percentLabel.bottomAnchor constant:12],
        [bar.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [bar.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [bar.heightAnchor constraintEqualToConstant:8],

        [stageLabel.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:12],
        [stageLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [stageLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],

        [cancelBtn.topAnchor constraintEqualToAnchor:stageLabel.bottomAnchor constant:16],
        [cancelBtn.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [cancelBtn.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-20]
    ]];

    self.progressOverlay = overlay;
    self.progressCard = card;
    self.progressTitleLabel = titleLabel;
    self.progressPercentLabel = percentLabel;
    self.progressBar = bar;
    self.progressStageLabel = stageLabel;
    self.progressSpinner = spinner;
    self.progressCancelButton = cancelBtn;

    [self setProgress:-1 stageMessage:localize(@"i18n_str_2052", nil)];
}

- (void)setProgress:(double)progress stageMessage:(NSString *)stageMessage {
    if (!self.progressCard) return;

    if (progress < 0) {
        self.progressBar.hidden = YES;
        self.progressPercentLabel.hidden = YES;
        self.progressSpinner.hidden = NO;
        [self.progressSpinner startAnimating];
    } else {
        self.progressBar.hidden = NO;
        self.progressPercentLabel.hidden = NO;
        self.progressSpinner.hidden = YES;
        [self.progressSpinner stopAnimating];
        double clamped = MAX(0.0, MIN(1.0, progress));
        NSInteger percent = (NSInteger)(clamped * 100);
        self.progressPercentLabel.text = [NSString stringWithFormat:@"%ld%%", (long)percent];
        [self.progressBar setProgress:(float)clamped animated:YES];
    }
    self.progressStageLabel.text = stageMessage ?: @"";
}

- (void)hideProgressCard {
    if (self.progressOverlay) {
        [self.progressOverlay removeFromSuperview];
        self.progressOverlay = nil;
        self.progressCard = nil;
        self.progressTitleLabel = nil;
        self.progressPercentLabel = nil;
        self.progressBar = nil;
        self.progressStageLabel = nil;
        self.progressSpinner = nil;
        self.progressCancelButton = nil;
    }
}

- (void)cancelExport {
    // 真正取消：通过 service 的 cancel 信号
    [ModpackExportService sharedService].cancelled = YES;
    [self setProgress:-1 stageMessage:localize(@"i18n_str_521", nil)];
}

#pragma mark - 完成提示

- (void)showExportSuccessWithPath:(NSString *)path {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_522", nil)
                                                                   message:[NSString stringWithFormat:localize(@"i18n_str_523", nil), path]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_141", nil) style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_524", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self shareExportedFile:path];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)shareExportedFile:(NSString *)path {
    NSURL *fileURL = [NSURL fileURLWithPath:path];
    UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[fileURL] applicationActivities:nil];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        activityVC.popoverPresentationController.sourceView = self.view;
        activityVC.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
    }
    [self presentViewController:activityVC animated:YES completion:nil];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil]];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)handleBackgroundUIEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
        [[BackgroundManager sharedManager] applyEffectToView:self.view];
        [self.fileOptionsTableView reloadData];
    });
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end
