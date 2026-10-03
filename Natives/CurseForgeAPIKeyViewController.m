#import "utils.h"
//
//  CurseForgeAPIKeyViewController.m
//  Amethyst
//
//  CurseForge API Key 运行时设置页实现
//  UI 风格：Bento Grid + Material Design 3
//

// 必须首先导入 Foundation/UIKit，避免其他头文件中的宏定义与 Objective-C 关键字冲突
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// 取消可能存在的 interface 宏定义，避免与 Objective-C 的 @interface 关键字冲突
#ifdef interface
#undef interface
#endif

#import "CurseForgeAPIKeyViewController.h"
#import "PLPreferences.h"
#import "CurseForgeAPI.h"
#import "config.h"
#import "BackgroundManager.h"

/// Material Design 3 主色调（CurseForge 橙色调，与品牌呼应）
static UIColor *CFKMD3PrimaryColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
        if (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithRed:0.85 green:0.55 blue:0.30 alpha:1.0];
        }
        return [UIColor colorWithRed:0.80 green:0.42 blue:0.16 alpha:1.0];
    }];
}

/// Material Design 3 主色调上的文字颜色（始终白色）
static UIColor *CFKMD3OnPrimaryColor(void) {
    return [UIColor whiteColor];
}

/// Material Design 3 描边按钮的描边颜色
static UIColor *CFKMD3OutlineColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
        if (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.32];
        }
        return [UIColor colorWithWhite:0.0 alpha:0.24];
    }];
}

/// 卡片背景色（适配深浅色）
static UIColor *CFKCardBackgroundColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
        if (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.06];
        }
        return [UIColor colorWithWhite:1.0 alpha:0.75];
    }];
}

/// 卡片描边色
static UIColor *CFKCardBorderColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
        if (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.10];
        }
        return [UIColor colorWithWhite:0.0 alpha:0.08];
    }];
}

/// 页面背景色
static UIColor *CFKPageBackgroundColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
        if (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithRed:0.05 green:0.05 blue:0.07 alpha:1.0];
        }
        return [UIColor colorWithRed:0.96 green:0.96 blue:0.98 alpha:1.0];
    }];
}

/// 主要文字颜色
static UIColor *CFKPrimaryTextColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
        if (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor whiteColor];
        }
        return [UIColor colorWithRed:0.10 green:0.10 blue:0.12 alpha:1.0];
    }];
}

/// 次要文字颜色
static UIColor *CFKSecondaryTextColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
        if (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.60];
        }
        return [UIColor colorWithWhite:0.0 alpha:0.55];
    }];
}

/// 输入框背景色
static UIColor *CFKFieldBackgroundColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
        if (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.08];
        }
        return [UIColor colorWithWhite:0.0 alpha:0.04];
    }];
}

/// 成功状态颜色
static UIColor *CFKSuccessColor(void) {
    return [UIColor colorWithRed:0.18 green:0.69 blue:0.45 alpha:1.0];
}

/// 失败状态颜色
static UIColor *CFKErrorColor(void) {
    return [UIColor colorWithRed:0.86 green:0.27 blue:0.27 alpha:1.0];
}

@interface CurseForgeAPIKeyViewController () <UITextFieldDelegate>

// 容器与滚动
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIView *contentView;

// 说明卡片（Bento Grid 风格）
@property (nonatomic, strong) UIView *infoCardView;
@property (nonatomic, strong) UILabel *infoTitleLabel;
@property (nonatomic, strong) UILabel *infoDescLabel;

// 输入区卡片
@property (nonatomic, strong) UIView *inputCardView;
@property (nonatomic, strong) UILabel *inputCardTitleLabel;
@property (nonatomic, strong) UITextField *apiKeyTextField;
@property (nonatomic, strong) UILabel *sourceHintLabel;

// 按钮区卡片
@property (nonatomic, strong) UIView *actionCardView;
@property (nonatomic, strong) UIButton *saveButton;
@property (nonatomic, strong) UIButton *testButton;
@property (nonatomic, strong) UIButton *clearButton;
@property (nonatomic, strong) UIActivityIndicatorView *testActivityIndicator;

// 状态标签
@property (nonatomic, strong) UILabel *statusLabel;

// 键盘适配
@property (nonatomic, assign) CGFloat keyboardOffset;
@property (nonatomic, strong) NSLayoutConstraint *scrollViewBottomConstraint;

// 状态
@property (nonatomic, assign) BOOL isTesting;

@end

@implementation CurseForgeAPIKeyViewController

#pragma mark - 生命周期

// ★ [LAND-BUG] 本页由 4 处调用方以 UIModalPresentationFormSheet + UINavigationController 整页弹出
//   （LauncherPreferencesViewController ×2、DownloadViewController、ServerListViewController）。
//   iPhone 上 formSheet 会自适应为全屏，而本页原先没有设置任何 navigationItem，
//   底部「保存」按钮也只保存不 dismiss ⇒ 保存完仍然退不出去。
//   此处补一个左上「关闭」按钮（模态时注入，push 进入时不注入）。
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    UINavigationController *nav = self.navigationController;
    if (nav.presentingViewController != nil && nav.viewControllers.firstObject == self &&
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

- (void)viewDidLoad {
    [super viewDidLoad];
    // 适配自定义启动器背景：将当前视图控制器透明化，使全局背景壁纸能够透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    self.title = @"CurseForge API Key";
    self.view.backgroundColor = CFKPageBackgroundColor();

    [self setupUI];
    [self loadInitialValue];
    [self registerKeyboardNotifications];

    // 监听背景 UI 效果变化通知，当用户切换背景效果（半透明/毛玻璃）时重新应用透明化
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

/// 背景效果改变时重新应用透明化（由 BackgroundUIEffectChanged 通知触发）
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> _Nonnull context) {
        [self updateLayoutForWidth:size.width];
    } completion:nil];
}

#pragma mark - UI 搭建

- (void)setupUI {
    [self setupScrollView];
    [self setupInfoCard];
    [self setupInputCard];
    [self setupActionCard];
    [self setupStatusLabel];
    [self installLayoutConstraintsForWidth:self.view.bounds.size.width];
}

- (void)setupScrollView {
    _scrollView = [[UIScrollView alloc] init];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.alwaysBounceVertical = YES;
    _scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:_scrollView];

    _contentView = [[UIView alloc] init];
    _contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [_scrollView addSubview:_contentView];

    // 基础约束（宽度自适应）
    _scrollViewBottomConstraint = [_scrollView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor];
    [NSLayoutConstraint activateConstraints:@[
        [_scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        _scrollViewBottomConstraint,
        [_contentView.topAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.topAnchor],
        [_contentView.bottomAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.bottomAnchor],
        [_contentView.leadingAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.leadingAnchor],
        [_contentView.trailingAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.trailingAnchor],
        [_contentView.widthAnchor constraintEqualToAnchor:_scrollView.frameLayoutGuide.widthAnchor],
    ]];
}

- (void)setupInfoCard {
    _infoCardView = [self makeCardView];
    [_contentView addSubview:_infoCardView];

    _infoTitleLabel = [[UILabel alloc] init];
    _infoTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _infoTitleLabel.text = @"CurseForge API Key";
    _infoTitleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    _infoTitleLabel.textColor = CFKPrimaryTextColor();
    _infoTitleLabel.numberOfLines = 1;
    [_infoCardView addSubview:_infoTitleLabel];

    _infoDescLabel = [[UILabel alloc] init];
    _infoDescLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _infoDescLabel.text = localize(@"i18n_str_86", nil);
    _infoDescLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    _infoDescLabel.textColor = CFKSecondaryTextColor();
    _infoDescLabel.numberOfLines = 0;
    [_infoCardView addSubview:_infoDescLabel];
}

- (void)setupInputCard {
    _inputCardView = [self makeCardView];
    [_contentView addSubview:_inputCardView];

    _inputCardTitleLabel = [[UILabel alloc] init];
    _inputCardTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _inputCardTitleLabel.text = @"API Key";
    _inputCardTitleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _inputCardTitleLabel.textColor = CFKPrimaryTextColor();
    [_inputCardView addSubview:_inputCardTitleLabel];

    _apiKeyTextField = [[UITextField alloc] init];
    _apiKeyTextField.translatesAutoresizingMaskIntoConstraints = NO;
    _apiKeyTextField.placeholder = localize(@"i18n_str_87", nil);
    _apiKeyTextField.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    _apiKeyTextField.textColor = CFKPrimaryTextColor();
    _apiKeyTextField.backgroundColor = CFKFieldBackgroundColor();
    _apiKeyTextField.secureTextEntry = YES;
    _apiKeyTextField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _apiKeyTextField.autocorrectionType = UITextAutocorrectionTypeNo;
    _apiKeyTextField.spellCheckingType = UITextSpellCheckingTypeNo;
    _apiKeyTextField.keyboardType = UIKeyboardTypeASCIICapable;
    _apiKeyTextField.returnKeyType = UIReturnKeyDone;
    _apiKeyTextField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _apiKeyTextField.delegate = self;
    _apiKeyTextField.layer.cornerRadius = 12;
    _apiKeyTextField.layer.cornerCurve = kCACornerCurveContinuous;
    // 文本左侧留白
    _apiKeyTextField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    _apiKeyTextField.leftViewMode = UITextFieldViewModeAlways;
    _apiKeyTextField.rightView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    _apiKeyTextField.rightViewMode = UITextFieldViewModeAlways;
    [_inputCardView addSubview:_apiKeyTextField];

    _sourceHintLabel = [[UILabel alloc] init];
    _sourceHintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _sourceHintLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    _sourceHintLabel.textColor = CFKSecondaryTextColor();
    _sourceHintLabel.numberOfLines = 0;
    [_inputCardView addSubview:_sourceHintLabel];
}

- (void)setupActionCard {
    _actionCardView = [self makeCardView];
    [_contentView addSubview:_actionCardView];

    _saveButton = [self makeFilledButtonWithTitle:localize(@"i18n_str_88", nil)
                                          primary:YES];
    [_saveButton addTarget:self action:@selector(saveButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [_actionCardView addSubview:_saveButton];

    _testButton = [self makeOutlinedButtonWithTitle:localize(@"i18n_str_89", nil)];
    [_testButton addTarget:self action:@selector(testButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [_actionCardView addSubview:_testButton];

    _clearButton = [self makeOutlinedButtonWithTitle:localize(@"i18n_str_77", nil)];
    [_clearButton addTarget:self action:@selector(clearButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [_actionCardView addSubview:_clearButton];

    _testActivityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _testActivityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    _testActivityIndicator.hidesWhenStopped = YES;
    [_actionCardView addSubview:_testActivityIndicator];
}

- (void)setupStatusLabel {
    _statusLabel = [[UILabel alloc] init];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _statusLabel.textAlignment = NSTextAlignmentLeft;
    _statusLabel.numberOfLines = 0;
    _statusLabel.text = @"";
    [_contentView addSubview:_statusLabel];
}

#pragma mark - 卡片与按钮工厂

- (UIView *)makeCardView {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = CFKCardBackgroundColor();
    card.layer.cornerRadius = 16;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.borderWidth = 0.5;
    card.layer.borderColor = CFKCardBorderColor().CGColor;
    return card;
}

- (UIButton *)makeFilledButtonWithTitle:(NSString *)title primary:(BOOL)primary {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    button.layer.cornerRadius = 12;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    if (primary) {
        button.backgroundColor = CFKMD3PrimaryColor();
        [button setTitleColor:CFKMD3OnPrimaryColor() forState:UIControlStateNormal];
        button.tintColor = CFKMD3OnPrimaryColor();
    } else {
        button.backgroundColor = [UIColor clearColor];
        [button setTitleColor:CFKPrimaryTextColor() forState:UIControlStateNormal];
        button.tintColor = CFKPrimaryTextColor();
    }
    return button;
}

- (UIButton *)makeOutlinedButtonWithTitle:(NSString *)title {
    UIButton *button = [self makeFilledButtonWithTitle:title primary:NO];
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = CFKMD3OutlineColor().CGColor;
    return button;
}

#pragma mark - 布局

- (void)installLayoutConstraintsForWidth:(CGFloat)width {
    // 移除旧约束（如有重建）
    [self removeConstraintsOnContentView];

    CGFloat horizontalPadding = MAX(16, (width - 600) / 2.0); // 大屏居中限宽
    CGFloat cardSpacing = 12;
    CGFloat contentPadding = 16;

    // 说明卡片
    [NSLayoutConstraint activateConstraints:@[
        [_infoCardView.topAnchor constraintEqualToAnchor:_contentView.topAnchor constant:contentPadding],
        [_infoCardView.leadingAnchor constraintEqualToAnchor:_contentView.leadingAnchor constant:horizontalPadding],
        [_infoCardView.trailingAnchor constraintEqualToAnchor:_contentView.trailingAnchor constant:-horizontalPadding],

        [_infoTitleLabel.topAnchor constraintEqualToAnchor:_infoCardView.topAnchor constant:16],
        [_infoTitleLabel.leadingAnchor constraintEqualToAnchor:_infoCardView.leadingAnchor constant:16],
        [_infoTitleLabel.trailingAnchor constraintEqualToAnchor:_infoCardView.trailingAnchor constant:-16],

        [_infoDescLabel.topAnchor constraintEqualToAnchor:_infoTitleLabel.bottomAnchor constant:8],
        [_infoDescLabel.leadingAnchor constraintEqualToAnchor:_infoCardView.leadingAnchor constant:16],
        [_infoDescLabel.trailingAnchor constraintEqualToAnchor:_infoCardView.trailingAnchor constant:-16],
        [_infoDescLabel.bottomAnchor constraintEqualToAnchor:_infoCardView.bottomAnchor constant:-16],
    ]];

    // 输入区卡片
    [NSLayoutConstraint activateConstraints:@[
        [_inputCardView.topAnchor constraintEqualToAnchor:_infoCardView.bottomAnchor constant:cardSpacing],
        [_inputCardView.leadingAnchor constraintEqualToAnchor:_contentView.leadingAnchor constant:horizontalPadding],
        [_inputCardView.trailingAnchor constraintEqualToAnchor:_contentView.trailingAnchor constant:-horizontalPadding],

        [_inputCardTitleLabel.topAnchor constraintEqualToAnchor:_inputCardView.topAnchor constant:16],
        [_inputCardTitleLabel.leadingAnchor constraintEqualToAnchor:_inputCardView.leadingAnchor constant:16],
        [_inputCardTitleLabel.trailingAnchor constraintEqualToAnchor:_inputCardView.trailingAnchor constant:-16],

        [_apiKeyTextField.topAnchor constraintEqualToAnchor:_inputCardTitleLabel.bottomAnchor constant:10],
        [_apiKeyTextField.leadingAnchor constraintEqualToAnchor:_inputCardView.leadingAnchor constant:16],
        [_apiKeyTextField.trailingAnchor constraintEqualToAnchor:_inputCardView.trailingAnchor constant:-16],
        [_apiKeyTextField.heightAnchor constraintEqualToConstant:44],

        [_sourceHintLabel.topAnchor constraintEqualToAnchor:_apiKeyTextField.bottomAnchor constant:8],
        [_sourceHintLabel.leadingAnchor constraintEqualToAnchor:_inputCardView.leadingAnchor constant:16],
        [_sourceHintLabel.trailingAnchor constraintEqualToAnchor:_inputCardView.trailingAnchor constant:-16],
        [_sourceHintLabel.bottomAnchor constraintEqualToAnchor:_inputCardView.bottomAnchor constant:-16],
    ]];

    // 按钮区卡片
    [NSLayoutConstraint activateConstraints:@[
        [_actionCardView.topAnchor constraintEqualToAnchor:_inputCardView.bottomAnchor constant:cardSpacing],
        [_actionCardView.leadingAnchor constraintEqualToAnchor:_contentView.leadingAnchor constant:horizontalPadding],
        [_actionCardView.trailingAnchor constraintEqualToAnchor:_contentView.trailingAnchor constant:-horizontalPadding],

        [_saveButton.topAnchor constraintEqualToAnchor:_actionCardView.topAnchor constant:16],
        [_saveButton.leadingAnchor constraintEqualToAnchor:_actionCardView.leadingAnchor constant:16],
        [_saveButton.heightAnchor constraintEqualToConstant:44],
        [_saveButton.widthAnchor constraintGreaterThanOrEqualToConstant:88],

        [_testButton.topAnchor constraintEqualToAnchor:_saveButton.topAnchor],
        [_testButton.leadingAnchor constraintEqualToAnchor:_saveButton.trailingAnchor constant:10],
        [_testButton.heightAnchor constraintEqualToConstant:44],
        [_testButton.widthAnchor constraintGreaterThanOrEqualToConstant:88],

        [_clearButton.topAnchor constraintEqualToAnchor:_saveButton.topAnchor],
        [_clearButton.leadingAnchor constraintEqualToAnchor:_testButton.trailingAnchor constant:10],
        [_clearButton.heightAnchor constraintEqualToConstant:44],
        [_clearButton.widthAnchor constraintGreaterThanOrEqualToConstant:88],
        [_clearButton.trailingAnchor constraintLessThanOrEqualToAnchor:_actionCardView.trailingAnchor constant:-16],

        [_testActivityIndicator.centerYAnchor constraintEqualToAnchor:_saveButton.centerYAnchor],
        [_testActivityIndicator.leadingAnchor constraintEqualToAnchor:_clearButton.trailingAnchor constant:8],

        [_saveButton.bottomAnchor constraintEqualToAnchor:_actionCardView.bottomAnchor constant:-16],
    ]];

    // 状态标签
    [NSLayoutConstraint activateConstraints:@[
        [_statusLabel.topAnchor constraintEqualToAnchor:_actionCardView.bottomAnchor constant:cardSpacing],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:_contentView.leadingAnchor constant:horizontalPadding + 4],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:_contentView.trailingAnchor constant:-(horizontalPadding + 4)],
        [_statusLabel.bottomAnchor constraintEqualToAnchor:_contentView.bottomAnchor constant:-contentPadding],
    ]];
}

- (void)removeConstraintsOnContentView {
    // 仅移除与本次布局相关的视图约束（避免重复添加导致冲突）
    NSArray<UIView *> *related = @[_infoCardView, _infoDescLabel, _infoTitleLabel,
                                    _inputCardView, _inputCardTitleLabel, _apiKeyTextField, _sourceHintLabel,
                                    _actionCardView, _saveButton, _testButton, _clearButton, _testActivityIndicator,
                                    _statusLabel];
    for (UIView *v in related) {
        for (NSLayoutConstraint *c in v.constraints) {
            // 仅移除自身参与的、并指向 _contentView 体系内的约束
            if (c.firstAttribute != NSLayoutAttributeWidth && c.firstAttribute != NSLayoutAttributeHeight) {
                [v removeConstraint:c];
            }
        }
    }
    for (UIView *v in related) {
        [v removeFromSuperview];
    }
    // 重新加回 contentView（保持引用与层级）
    [_contentView addSubview:_infoCardView];
    [_infoCardView addSubview:_infoTitleLabel];
    [_infoCardView addSubview:_infoDescLabel];
    [_contentView addSubview:_inputCardView];
    [_inputCardView addSubview:_inputCardTitleLabel];
    [_inputCardView addSubview:_apiKeyTextField];
    [_inputCardView addSubview:_sourceHintLabel];
    [_contentView addSubview:_actionCardView];
    [_actionCardView addSubview:_saveButton];
    [_actionCardView addSubview:_testButton];
    [_actionCardView addSubview:_clearButton];
    [_actionCardView addSubview:_testActivityIndicator];
    [_contentView addSubview:_statusLabel];
}

- (void)updateLayoutForWidth:(CGFloat)width {
    [self installLayoutConstraintsForWidth:width];
}

#pragma mark - 初始值加载

- (void)loadInitialValue {
    // 优先级：运行时偏好 -> 编译时宏 -> Info.plist
    NSString *runtimeKey = [PLPreferences curseForgeAPIKey];
    NSString *compiledKey = @CONFIG_CURSEFORGE_API_KEY;
    if ([compiledKey isEqualToString:@"nil"]) {
        compiledKey = @"";
    }
    NSString *infoPlistKey = [NSBundle.mainBundle.infoDictionary[@"CurseForgeAPIKey"] isKindOfClass:NSString.class]
        ? NSBundle.mainBundle.infoDictionary[@"CurseForgeAPIKey"]
        : @"";

    NSString *displayKey = runtimeKey.length > 0 ? runtimeKey : (compiledKey.length > 0 ? compiledKey : infoPlistKey);
    _apiKeyTextField.text = displayKey;

    // 显示来源提示
    NSString *sourceHint;
    if (runtimeKey.length > 0) {
        sourceHint = localize(@"i18n_str_90", nil);
    } else if (compiledKey.length > 0) {
        sourceHint = localize(@"i18n_str_91", nil);
    } else if (infoPlistKey.length > 0) {
        sourceHint = localize(@"i18n_str_92", nil);
    } else {
        sourceHint = localize(@"i18n_str_93", nil);
    }
    _sourceHintLabel.text = sourceHint;
}

#pragma mark - 按钮事件

- (void)saveButtonTapped {
    NSString *key = [_apiKeyTextField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (key.length == 0) {
        [PLPreferences setCurseForgeAPIKey:nil];
    } else {
        [PLPreferences setCurseForgeAPIKey:key];
    }
    [self loadInitialValue];
    [self setStatusText:localize(@"i18n_str_94", nil) success:YES];
}

- (void)clearButtonTapped {
    [PLPreferences setCurseForgeAPIKey:nil];
    // 清空后回显到编译时默认值，便于用户参考
    NSString *compiledKey = @CONFIG_CURSEFORGE_API_KEY;
    if ([compiledKey isEqualToString:@"nil"]) {
        compiledKey = @"";
    }
    _apiKeyTextField.text = compiledKey.length > 0 ? compiledKey : @"";
    [self loadInitialValue];
    [self setStatusText:localize(@"i18n_str_95", nil) success:YES];
}

- (void)testButtonTapped {
    if (_isTesting) {
        return;
    }
    // 1. 先保存当前输入的 Key 到偏好
    NSString *key = [_apiKeyTextField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [PLPreferences setCurseForgeAPIKey:key.length > 0 ? key : nil];

    if (key.length == 0) {
        [self setStatusText:localize(@"i18n_str_96", nil) success:NO];
        return;
    }

    [self beginTesting];

    // 2. 用 sharedInstance 发起一次轻量搜索（pageSize=1）
    NSDictionary *filters = @{
        @"projectType": @"mod",
        @"query": @"",
        @"limit": @1,
        @"offset": @0
    };
    __weak typeof(self) weakSelf = self;
    [[CurseForgeAPI sharedInstance] searchModWithFilters:filters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf endTesting];
            if (error) {
                NSString *desc = error.localizedDescription ?: localize(@"i18n_str_97", nil);
                [strongSelf setStatusText:[NSString stringWithFormat:localize(@"i18n_str_98", nil), desc] success:NO];
            } else if (results) {
                [strongSelf setStatusText:localize(@"i18n_str_99", nil) success:YES];
            } else {
                [strongSelf setStatusText:localize(@"i18n_str_100", nil) success:NO];
            }
            // 重新刷新来源提示（保存后状态可能变化）
            [strongSelf loadInitialValue];
        });
    }];
}

#pragma mark - 测试状态

- (void)beginTesting {
    _isTesting = YES;
    _saveButton.enabled = NO;
    _testButton.enabled = NO;
    _clearButton.enabled = NO;
    [_saveButton setAlpha:0.5];
    [_testButton setAlpha:0.5];
    [_clearButton setAlpha:0.5];
    [_testActivityIndicator startAnimating];
    [self setStatusText:localize(@"i18n_str_101", nil) success:YES];
}

- (void)endTesting {
    _isTesting = NO;
    _saveButton.enabled = YES;
    _testButton.enabled = YES;
    _clearButton.enabled = YES;
    [_saveButton setAlpha:1.0];
    [_testButton setAlpha:1.0];
    [_clearButton setAlpha:1.0];
    [_testActivityIndicator stopAnimating];
}

- (void)setStatusText:(NSString *)text success:(BOOL)success {
    if (success) {
        _statusLabel.textColor = CFKSuccessColor();
    } else {
        _statusLabel.textColor = CFKErrorColor();
    }
    _statusLabel.text = text;
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    // 即时刷新来源提示
    [self loadInitialValue];
}

#pragma mark - 键盘适配

- (void)registerKeyboardNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillChangeFrame:)
                                                 name:UIKeyboardWillChangeFrameNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
}

- (void)keyboardWillChangeFrame:(NSNotification *)notification {
    NSValue *endFrameValue = notification.userInfo[UIKeyboardFrameEndUserInfoKey];
    CGRect endFrame = [endFrameValue CGRectValue];
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    // 转换到当前视图坐标系
    CGRect converted = [self.view convertRect:endFrame fromView:nil];
    CGFloat overlap = MAX(0, self.view.bounds.size.height - converted.origin.y);
    _keyboardOffset = overlap;
    [self updateScrollViewBottomWithOffset:overlap duration:duration];
}

- (void)keyboardWillHide:(NSNotification *)notification {
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    _keyboardOffset = 0;
    [self updateScrollViewBottomWithOffset:0 duration:duration];
}

- (void)updateScrollViewBottomWithOffset:(CGFloat)offset duration:(NSTimeInterval)duration {
    // 当键盘弹出时，将 scrollView 底部上移，避免输入框被遮挡
    [self.view layoutIfNeeded];
    self.scrollViewBottomConstraint.constant = -offset;
    [UIView animateWithDuration:duration animations:^{
        [self.view layoutIfNeeded];
    }];
}

#pragma mark - dealloc

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
