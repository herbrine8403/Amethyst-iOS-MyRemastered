//
//  AIProviderConfigViewController.m
//  Amethyst
//
//  AI 提供商配置页 + 提供商编辑表单（同文件私有类）+ 连通性测试。
//

#import "AIProviderConfigViewController.h"
#import "AiProvider.h"
#import "AiProviderStore.h"
#import "AiAPIClient.h"
#import "BackgroundManager.h"
#import "LauncherPreferences.h"
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 提供商编辑表单（私有）

/// 编辑 / 新增提供商表单页
@interface AIProviderEditViewController : UITableViewController

/// 待编辑的提供商（nil 表示新增）
@property (nonatomic, strong, nullable) AiProvider *provider;
/// 保存成功回调（用于父列表刷新）
@property (nonatomic, copy, nullable) void (^onSaved)(void);

@end

NS_ASSUME_NONNULL_END

#pragma mark - 提供商配置列表

@interface AIProviderConfigViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@end

@implementation AIProviderConfigViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"提供商配置";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.backgroundColor = [[UIColor labelColor] colorWithAlphaComponent:0.04];
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    [self setupTable];
    [self.tableView reloadData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 从编辑页返回后刷新（选中态 / 列表）
    [self.tableView reloadData];

    // ★ [LAND-BUG] 本页会被「设置 ▸ AI ▸ 提供商配置」(LauncherPreferencesViewController:1167)
    //   与 AI 会话页以模态 UINavigationController(root) 弹出；本页原先没有任何 navigationItem，
    //   全屏模态下没有返回/关闭 ⇒ 退不出去。补一个左上「关闭」（pushed 进栈时不注入）。
    UINavigationController *landBugNav = self.navigationController;
    if (landBugNav.presentingViewController != nil && landBugNav.viewControllers.firstObject == self &&
        self.navigationItem.leftBarButtonItem == nil) {
        UIBarButtonItem *landBugCloseItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                                          target:self
                                                                                          action:@selector(landBugCloseTapped)];
        landBugCloseItem.accessibilityLabel = @"关闭";
        self.navigationItem.leftBarButtonItem = landBugCloseItem;
    }
}

- (void)landBugCloseTapped {
    UINavigationController *nav = self.navigationController;
    if (nav.presentingViewController) {
        [nav dismissViewControllerAnimated:YES completion:nil];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)setupTable {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.estimatedRowHeight = 96;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"AiProviderCell"];
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

#pragma mark - 顶部说明/新增卡

- (UIView *)headerView {
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 0)];

    // 说明卡
    UIView *infoCard = [[UIView alloc] init];
    infoCard.translatesAutoresizingMaskIntoConstraints = NO;
    infoCard.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    infoCard.layer.cornerRadius = 16;
    infoCard.layer.cornerCurve = kCACornerCurveContinuous;
    infoCard.layer.borderWidth = 0.5;
    infoCard.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    [[BackgroundManager sharedManager] applyEffectToView:infoCard];
    [header addSubview:infoCard];

    UILabel *infoLabel = [[UILabel alloc] init];
    infoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    infoLabel.text = @"支持 OpenAI / DeepSeek / Kimi / GLM / Ollama 等任意 OpenAI 兼容接口。填写 Base URL 与模型名即可使用。";
    infoLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    infoLabel.textColor = [UIColor secondaryLabelColor];
    infoLabel.numberOfLines = 0;
    [infoCard addSubview:infoLabel];

    // 新增按钮
    UIButton *addButton = [UIButton buttonWithType:UIButtonTypeSystem];
    addButton.translatesAutoresizingMaskIntoConstraints = NO;
    [addButton setTitle:@"＋ 新增提供商" forState:UIControlStateNormal];
    addButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [addButton setTitleColor:accentColor() forState:UIControlStateNormal];
    addButton.backgroundColor = [accentColor() colorWithAlphaComponent:0.15];
    addButton.layer.cornerRadius = 16;
    addButton.layer.cornerCurve = kCACornerCurveContinuous;
    addButton.clipsToBounds = YES;
    [addButton addTarget:self action:@selector(addProviderAction) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:addButton];

    [NSLayoutConstraint activateConstraints:@[
        [infoCard.topAnchor constraintEqualToAnchor:header.topAnchor constant:8],
        [infoCard.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [infoCard.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],

        [infoLabel.topAnchor constraintEqualToAnchor:infoCard.topAnchor constant:14],
        [infoLabel.leadingAnchor constraintEqualToAnchor:infoCard.leadingAnchor constant:16],
        [infoLabel.trailingAnchor constraintEqualToAnchor:infoCard.trailingAnchor constant:-16],
        [infoLabel.bottomAnchor constraintEqualToAnchor:infoCard.bottomAnchor constant:-14],

        [addButton.topAnchor constraintEqualToAnchor:infoCard.bottomAnchor constant:12],
        [addButton.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [addButton.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],
        [addButton.heightAnchor constraintEqualToConstant:44],
        [addButton.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-4],
    ]];

    // 计算高度
    CGFloat width = self.tableView.bounds.size.width ?: [UIScreen mainScreen].bounds.size.width;
    header.frame = CGRectMake(0, 0, width, 0);
    [header setNeedsLayout];
    [header layoutIfNeeded];
    CGFloat height = [header systemLayoutSizeFittingSize:CGSizeMake(width, 0)
                            withHorizontalFittingPriority:UILayoutPriorityRequired
                                  verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    header.frame = CGRectMake(0, 0, width, height);
    return header;
}

#pragma mark - 动作

- (void)addProviderAction {
    AIProviderEditViewController *editVC = [[AIProviderEditViewController alloc] init];
    editVC.provider = nil;
    __weak typeof(self) weakSelf = self;
    editVC.onSaved = ^{
        [weakSelf.tableView reloadData];
    };
    [self.navigationController pushViewController:editVC animated:YES];
}

- (void)editProvider:(AiProvider *)provider {
    AIProviderEditViewController *editVC = [[AIProviderEditViewController alloc] init];
    editVC.provider = provider;
    __weak typeof(self) weakSelf = self;
    editVC.onSaved = ^{
        [weakSelf.tableView reloadData];
    };
    [self.navigationController pushViewController:editVC animated:YES];
}

- (void)selectProvider:(AiProvider *)provider {
    [[AiProviderStore sharedStore] setSelectedProvider:provider];
    [self.tableView reloadData];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

// 说明卡 + 新增按钮作为表头，其余为提供商卡片
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [AiProviderStore sharedStore].providers.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AiProviderCell" forIndexPath:indexPath];
    for (UIView *sub in cell.contentView.subviews) {
        [sub removeFromSuperview];
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];

    AiProvider *provider = [AiProviderStore sharedStore].providers[indexPath.row];
    AiProvider *selected = [[AiProviderStore sharedStore] selectedProvider];
    BOOL isSelected = (selected != nil && [selected.identifier isEqualToString:provider.identifier]);

    // 卡片容器
    UIView *cardView = [[UIView alloc] init];
    cardView.translatesAutoresizingMaskIntoConstraints = NO;
    cardView.backgroundColor = isSelected ? [accentColor() colorWithAlphaComponent:0.15]
                                         : [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    cardView.layer.cornerRadius = 16;
    cardView.layer.cornerCurve = kCACornerCurveContinuous;
    cardView.layer.borderWidth = 0.5;
    cardView.layer.borderColor = isSelected ? accentColor().CGColor
                                            : [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    cardView.layer.shadowColor = [UIColor blackColor].CGColor;
    cardView.layer.shadowOffset = CGSizeMake(0, 2);
    cardView.layer.shadowOpacity = 0.10;
    cardView.layer.shadowRadius = 6;
    [[BackgroundManager sharedManager] applyEffectToView:cardView];
    [cell.contentView addSubview:cardView];

    // 名称
    UILabel *nameLabel = [[UILabel alloc] init];
    nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    nameLabel.text = provider.name.length > 0 ? provider.name : @"未命名提供商";
    nameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    nameLabel.textColor = [UIColor labelColor];
    nameLabel.numberOfLines = 1;
    [cardView addSubview:nameLabel];

    // 模型
    UILabel *modelLabel = [[UILabel alloc] init];
    modelLabel.translatesAutoresizingMaskIntoConstraints = NO;
    modelLabel.text = provider.model.length > 0 ? provider.model : @"未设置模型";
    modelLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    modelLabel.textColor = [UIColor secondaryLabelColor];
    modelLabel.numberOfLines = 1;
    modelLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [cardView addSubview:modelLabel];

    // Base URL
    UILabel *urlLabel = [[UILabel alloc] init];
    urlLabel.translatesAutoresizingMaskIntoConstraints = NO;
    urlLabel.text = provider.baseURL.length > 0 ? provider.baseURL : @"未设置 Base URL";
    urlLabel.font = [UIFont systemFontOfSize:12];
    urlLabel.textColor = [UIColor secondaryLabelColor];
    urlLabel.numberOfLines = 1;
    urlLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [cardView addSubview:urlLabel];

    // 选中勾
    UIImageView *checkView = [[UIImageView alloc] init];
    checkView.translatesAutoresizingMaskIntoConstraints = NO;
    checkView.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
    checkView.tintColor = accentColor();
    checkView.contentMode = UIViewContentModeScaleAspectFit;
    checkView.hidden = !isSelected;
    [cardView addSubview:checkView];

    // 编辑按钮
    UIButton *editButton = [UIButton buttonWithType:UIButtonTypeSystem];
    editButton.translatesAutoresizingMaskIntoConstraints = NO;
    [editButton setImage:[UIImage systemImageNamed:@"pencil"] forState:UIControlStateNormal];
    editButton.tintColor = accentColor();
    __weak typeof(self) weakSelf = self;
    [editButton addTarget:weakSelf action:@selector(editProviderAction:) forControlEvents:UIControlEventTouchUpInside];
    // 用关联对象传 provider 引用
    objc_setAssociatedObject(editButton, "provider", provider, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [cardView addSubview:editButton];

    [NSLayoutConstraint activateConstraints:@[
        [cardView.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:6],
        [cardView.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [cardView.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [cardView.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-6],

        [nameLabel.leadingAnchor constraintEqualToAnchor:cardView.leadingAnchor constant:16],
        [nameLabel.topAnchor constraintEqualToAnchor:cardView.topAnchor constant:14],
        [nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:editButton.leadingAnchor constant:-8],

        [modelLabel.leadingAnchor constraintEqualToAnchor:nameLabel.leadingAnchor],
        [modelLabel.trailingAnchor constraintEqualToAnchor:nameLabel.trailingAnchor],
        [modelLabel.topAnchor constraintEqualToAnchor:nameLabel.bottomAnchor constant:4],

        [urlLabel.leadingAnchor constraintEqualToAnchor:nameLabel.leadingAnchor],
        [urlLabel.trailingAnchor constraintEqualToAnchor:cardView.trailingAnchor constant:-16],
        [urlLabel.topAnchor constraintEqualToAnchor:modelLabel.bottomAnchor constant:4],
        [urlLabel.bottomAnchor constraintEqualToAnchor:cardView.bottomAnchor constant:-14],

        [editButton.trailingAnchor constraintEqualToAnchor:cardView.trailingAnchor constant:-12],
        [editButton.topAnchor constraintEqualToAnchor:cardView.topAnchor constant:12],
        [editButton.widthAnchor constraintEqualToConstant:28],
        [editButton.heightAnchor constraintEqualToConstant:28],

        [checkView.trailingAnchor constraintEqualToAnchor:cardView.trailingAnchor constant:-14],
        [checkView.bottomAnchor constraintEqualToAnchor:cardView.bottomAnchor constant:-12],
        [checkView.widthAnchor constraintEqualToConstant:18],
        [checkView.heightAnchor constraintEqualToConstant:18],
    ]];

    return cell;
}

- (void)editProviderAction:(UIButton *)sender {
    AiProvider *provider = objc_getAssociatedObject(sender, "provider");
    if (provider) {
        [self editProvider:provider];
    }
}

#pragma mark - UITableViewDelegate

- (nullable UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return [self headerView];
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return [[self headerView] frame].size.height;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    AiProvider *provider = [AiProviderStore sharedStore].providers[indexPath.row];
    [self selectProvider:provider];
}

- (nullable NSArray<UITableViewRowAction *> *)tableView:(UITableView *)tableView editActionsForRowAtIndexPath:(NSIndexPath *)indexPath {
    __weak typeof(self) weakSelf = self;
    UITableViewRowAction *deleteAction = [UITableViewRowAction rowActionWithStyle:UITableViewRowActionStyleDestructive
                                                                           title:@"删除"
                                                                         handler:^(UITableViewRowAction * _Nonnull action, NSIndexPath * _Nonnull ip) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        AiProvider *provider = [AiProviderStore sharedStore].providers[ip.row];
        [[AiProviderStore sharedStore] deleteProvider:provider];
        [strongSelf.tableView reloadData];
    }];
    return @[deleteAction];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleDelete;
}

@end

#pragma mark - AIProviderEditViewController 实现

@implementation AIProviderEditViewController {
    UITextField *_nameField;
    UITextField *_baseURLField;
    UITextField *_apiKeyField;
    UITextField *_modelField;
    UITextField *_maxTokensField;
    UITextField *_contextWindowField;
    UISlider *_temperatureSlider;
    UILabel *_temperatureLabel;
    BOOL _isEditing;
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _isEditing = NO;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _isEditing = (self.provider != nil);
    self.title = _isEditing ? @"编辑提供商" : @"新增提供商";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.backgroundColor = [[UIColor labelColor] colorWithAlphaComponent:0.04];
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    UIBarButtonItem *saveItem = [[UIBarButtonItem alloc] initWithTitle:@"保存"
                                                                 style:UIBarButtonItemStyleDone
                                                                target:self
                                                                action:@selector(saveAction)];
    self.navigationItem.rightBarButtonItem = saveItem;

    [self buildFields];
    [self loadValues];
}

#pragma mark - 构建字段

- (UITextField *)makeTextField:(NSString *)placeholder keyboard:(UIKeyboardType)keyboard secure:(BOOL)secure {
    UITextField *field = [[UITextField alloc] init];
    field.placeholder = placeholder;
    field.keyboardType = keyboard;
    field.secureTextEntry = secure;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.returnKeyType = UIReturnKeyDone;
    field.delegate = self;
    return field;
}

- (void)buildFields {
    _nameField = [self makeTextField:@"例如 DeepSeek / OpenAI / Ollama" keyboard:UIKeyboardTypeDefault secure:NO];
    _baseURLField = [self makeTextField:@"https://api.deepseek.com/v1" keyboard:UIKeyboardTypeURL secure:NO];
    _apiKeyField = [self makeTextField:@"API Key" keyboard:UIKeyboardTypeDefault secure:YES];
    _modelField = [self makeTextField:@"例如 deepseek-chat" keyboard:UIKeyboardTypeDefault secure:NO];
    _maxTokensField = [self makeTextField:@"留空使用默认 4096" keyboard:UIKeyboardTypeNumberPad secure:NO];
    _contextWindowField = [self makeTextField:@"留空使用默认 8192" keyboard:UIKeyboardTypeNumberPad secure:NO];

    _temperatureSlider = [[UISlider alloc] init];
    _temperatureSlider.minimumValue = 0;
    _temperatureSlider.maximumValue = 2;
    _temperatureSlider.continuous = YES;
    [_temperatureSlider addTarget:self action:@selector(temperatureChanged:) forControlEvents:UIControlEventValueChanged];
}

/// 将 provider 的值载入字段
- (void)loadValues {
    if (!self.provider) {
        _temperatureSlider.value = 0.7;
        [self refreshTemperatureLabel];
        if ([AiProviderStore sharedStore].providers.count == 0) {
            // 无任何提供商时，预填 DeepSeek 预设，减少输入成本
            AiProvider *preset = [AiProvider providerWithDictionary:[AiProviderStore defaultPresets].firstObject];
            _nameField.text = preset.name;
            _baseURLField.text = preset.baseURL;
            _modelField.text = preset.model;
        }
        return;
    }
    _nameField.text = self.provider.name;
    _baseURLField.text = self.provider.baseURL;
    // API Key 已存在时不回显明文，仅显示占位提示，留空表示保留原密钥
    if (self.provider.apiKey.length > 0) {
        _apiKeyField.placeholder = @"已保存（重新输入以修改）";
    }
    _modelField.text = self.provider.model;
    _temperatureSlider.value = self.provider.temperature;
    _maxTokensField.text = self.provider.maxTokens > 0 ? [NSString stringWithFormat:@"%ld", (long)self.provider.maxTokens] : @"";
    _contextWindowField.text = self.provider.contextWindow > 0 ? [NSString stringWithFormat:@"%ld", (long)self.provider.contextWindow] : @"";
    [self refreshTemperatureLabel];
}

- (void)refreshTemperatureLabel {
    if (!_temperatureLabel) return;
    _temperatureLabel.text = [NSString stringWithFormat:@"%.2f", _temperatureSlider.value];
}

- (void)temperatureChanged:(UISlider *)sender {
    [self refreshTemperatureLabel];
    // 直接更新当前温度 cell 的详情文本，避免整行重建中断滑动
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:1]];
    cell.detailTextLabel.text = _temperatureLabel.text;
}

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 4; // 名称 / Base URL / API Key / 模型
    if (section == 1) return 3; // 温度 / 最大 Token / 上下文窗口
    return 1;                    // 测试连接
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"连接信息";
    if (section == 1) return @"参数";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    [[BackgroundManager sharedManager] applyEffectToCell:cell];

    if (indexPath.section == 0) {
        switch (indexPath.row) {
            case 0:
                [self configureInputCell:cell label:@"名称" field:_nameField];
                break;
            case 1:
                [self configureInputCell:cell label:@"Base URL" field:_baseURLField];
                break;
            case 2:
                [self configureInputCell:cell label:@"API Key" field:_apiKeyField];
                break;
            case 3:
                [self configureInputCell:cell label:@"模型" field:_modelField];
                break;
        }
    } else if (indexPath.section == 1) {
        switch (indexPath.row) {
            case 0: {
                cell.textLabel.text = @"温度";
                if (!_temperatureLabel) {
                    _temperatureLabel = [[UILabel alloc] init];
                    _temperatureLabel.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
                    _temperatureLabel.textColor = [UIColor secondaryLabelColor];
                    _temperatureLabel.textAlignment = NSTextAlignmentCenter;
                }
                [self refreshTemperatureLabel];
                cell.detailTextLabel.text = _temperatureLabel.text;
                // 滑块放入 contentView 右侧撑满，避免 accessoryView 区域过窄
                _temperatureSlider.translatesAutoresizingMaskIntoConstraints = NO;
                [cell.contentView addSubview:_temperatureSlider];
                [NSLayoutConstraint activateConstraints:@[
                    [_temperatureSlider.leadingAnchor constraintEqualToAnchor:cell.textLabel.trailingAnchor constant:12],
                    [_temperatureSlider.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
                    [_temperatureSlider.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
                ]];
                break;
            }
            case 1:
                [self configureInputCell:cell label:@"最大 Token 上限" field:_maxTokensField];
                break;
            case 2:
                [self configureInputCell:cell label:@"上下文窗口" field:_contextWindowField];
                break;
        }
    } else {
        cell.textLabel.text = @"测试连接";
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = accentColor();
    }
    return cell;
}

/// 把输入框放入 cell.contentView 右侧并撑满可点区域。
/// 关键修复（Base URL 等输入框点不动/视觉错位）：此前输入框放在 cell.accessoryView，
/// 该区域窄、靠近 cell 最右，触摸面积小且易被遮挡；改用 contentView + AutoLayout 后
/// 输入框紧贴标签右侧并延伸至 cell 右缘，点击区显著变大、布局稳定。
- (void)configureInputCell:(UITableViewCell *)cell label:(NSString *)label field:(UITextField *)field {
    cell.textLabel.text = label;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:field];
    [NSLayoutConstraint activateConstraints:@[
        [field.leadingAnchor constraintEqualToAnchor:cell.textLabel.trailingAnchor constant:12],
        [field.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [field.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [field.heightAnchor constraintGreaterThanOrEqualToConstant:34],
    ]];
}

- (nullable UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    if (section == 2) {
        UILabel *footer = [[UILabel alloc] init];
        footer.backgroundColor = [UIColor clearColor];
        footer.font = [UIFont systemFontOfSize:12];
        footer.textColor = [UIColor secondaryLabelColor];
        footer.textAlignment = NSTextAlignmentCenter;
        footer.numberOfLines = 0;
        footer.text = @"测试连接会向此提供商发送一条极短的 \"ping\" 请求以验证可用性。";
        return footer;
    }
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return section == 2 ? 44 : CGFLOAT_MIN;
}

#pragma mark - 键盘
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

#pragma mark - 保存 / 测试

/// 由当前表单字段构造一个 AiProvider（编辑时沿用原 identifier）
- (AiProvider *)providerFromForm {
    AiProvider *provider = nil;
    if (_isEditing && self.provider) {
        provider = self.provider;
    } else {
        provider = [[AiProvider alloc] init];
    }

    provider.name = [_nameField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    provider.baseURL = [_baseURLField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    provider.model = [_modelField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    provider.temperature = _temperatureSlider.value;

    NSString *maxTokensText = [_maxTokensField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (maxTokensText.length > 0) {
        provider.maxTokens = maxTokensText.integerValue;
    }
    NSString *ctxText = [_contextWindowField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (ctxText.length > 0) {
        provider.contextWindow = ctxText.integerValue;
    }

    // API Key：编辑且留空则保留原密钥
    if (_apiKeyField.text.length > 0) {
        provider.apiKey = _apiKeyField.text;
    } else if (!_isEditing) {
        provider.apiKey = @"";
    }
    return provider;
}

- (void)saveAction {
    AiProvider *provider = [self providerFromForm];
    NSString *name = [provider.name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (name.length == 0) {
        [self showMessage:@"提示" body:@"请填写提供商名称"];
        return;
    }
    if (provider.baseURL.length == 0) {
        [self showMessage:@"提示" body:@"请填写 Base URL"];
        return;
    }
    if (provider.model.length == 0) {
        [self showMessage:@"提示" body:@"请填写模型名称"];
        return;
    }

    if (_isEditing) {
        [[AiProviderStore sharedStore] updateProvider:provider];
    } else {
        [[AiProviderStore sharedStore] addProvider:provider];
        [[AiProviderStore sharedStore] setSelectedProvider:provider];
    }
    if (self.onSaved) {
        self.onSaved();
    }
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 2 && indexPath.row == 0) {
        [self testConnectionAction];
    }
}

- (void)testConnectionAction {
    AiProvider *provider = [self providerFromForm];
    if (provider.baseURL.length == 0 || provider.model.length == 0) {
        [self showMessage:@"无法测试" body:@"请先填写 Base URL 与模型名称。"];
        return;
    }

    UIAlertController *loading = [UIAlertController alertControllerWithTitle:@"测试连接" message:@"正在测试，请稍候…" preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:loading animated:YES completion:nil];

    AiAPIClient *client = [[AiAPIClient alloc] init];
    [client testConnectionWithProvider:provider completion:^(NSString * _Nullable successMessage, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [loading dismissViewControllerAnimated:YES completion:^{
                if (error) {
                    [self showMessage:@"连接失败" body:error.localizedDescription ?: @"未知错误"];
                } else {
                    [self showMessage:@"连接成功" body:successMessage ?: @"连接成功"];
                }
            }];
        });
    }];
}

- (void)showMessage:(NSString *)title body:(NSString *)body {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:body
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end