//
//  AISystemPromptEditorViewController.m
//  Amethyst
//
//  AI 系统提示词编辑页实现。
//

#import "AISystemPromptEditorViewController.h"
#import "AiSettings.h"
#import "BackgroundManager.h"
#import "LauncherPreferences.h"

@interface AISystemPromptEditorViewController () <UITextViewDelegate>
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIView *cardView;
@end

@implementation AISystemPromptEditorViewController

// ★ [LAND-BUG] 本页由设置页以模态 UINavigationController(root) 弹出，左上原本是「恢复默认」、
//   右上是「保存」，没有关闭入口 ⇒ 不想保存时退不出去。模态时在最左补一个「关闭」。
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    UINavigationController *nav = self.navigationController;
    if (nav.presentingViewController == nil || nav.viewControllers.firstObject != self) return;
    if (self.navigationItem.leftBarButtonItems.count >= 2) return;   // 已注入
    UIBarButtonItem *landBugCloseItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                                      target:self
                                                                                      action:@selector(landBugCloseTapped)];
    landBugCloseItem.accessibilityLabel = @"关闭";
    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray arrayWithObject:landBugCloseItem];
    if (self.navigationItem.leftBarButtonItem) {
        [items addObject:self.navigationItem.leftBarButtonItem];   // 保留「恢复默认」
    }
    self.navigationItem.leftBarButtonItems = items;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"系统提示词";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.backgroundColor = [[UIColor labelColor] colorWithAlphaComponent:0.04];
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // 恢复默认
    UIBarButtonItem *resetItem = [[UIBarButtonItem alloc] initWithTitle:@"恢复默认"
                                                                  style:UIBarButtonItemStylePlain
                                                                 target:self
                                                                 action:@selector(resetAction)];
    self.navigationItem.leftBarButtonItem = resetItem;
    // 保存
    UIBarButtonItem *saveItem = [[UIBarButtonItem alloc] initWithTitle:@"保存"
                                                                 style:UIBarButtonItemStyleDone
                                                                target:self
                                                                action:@selector(saveAction)];
    self.navigationItem.rightBarButtonItem = saveItem;

    [self setupUI];
    // 进入时载入当前系统提示词
    self.textView.text = [[AiSettings sharedSettings] systemPrompt];
    [self.textView becomeFirstResponder];
}

- (void)setupUI {
    // 卡片容器
    self.cardView = [[UIView alloc] init];
    self.cardView.translatesAutoresizingMaskIntoConstraints = NO;
    self.cardView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    self.cardView.layer.cornerRadius = 16;
    self.cardView.layer.cornerCurve = kCACornerCurveContinuous;
    self.cardView.layer.borderWidth = 0.5;
    self.cardView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    self.cardView.layer.shadowColor = [UIColor blackColor].CGColor;
    self.cardView.layer.shadowOffset = CGSizeMake(0, 2);
    self.cardView.layer.shadowOpacity = 0.10;
    self.cardView.layer.shadowRadius = 6;
    [[BackgroundManager sharedManager] applyEffectToView:self.cardView];
    [self.view addSubview:self.cardView];

    // 提示文案
    UILabel *hintLabel = [[UILabel alloc] init];
    hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    hintLabel.text = @"这会注入到每次对话的最前面，用于约定 Air 助手的行为方式。";
    hintLabel.font = [UIFont systemFontOfSize:12];
    hintLabel.textColor = [UIColor secondaryLabelColor];
    hintLabel.numberOfLines = 0;
    [self.view addSubview:hintLabel];

    // 多行文本编辑区
    self.textView = [[UITextView alloc] init];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.delegate = self;
    self.textView.font = [UIFont systemFontOfSize:15];
    self.textView.textColor = [UIColor labelColor];
    self.textView.backgroundColor = [UIColor clearColor];
    self.textView.textContainerInset = UIEdgeInsetsMake(14, 14, 14, 14);
    self.textView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.cardView addSubview:self.textView];

    [NSLayoutConstraint activateConstraints:@[
        [hintLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [hintLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [hintLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],

        [self.cardView.topAnchor constraintEqualToAnchor:hintLabel.bottomAnchor constant:12],
        [self.cardView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.cardView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.cardView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16],

        [self.textView.topAnchor constraintEqualToAnchor:self.cardView.topAnchor],
        [self.textView.leadingAnchor constraintEqualToAnchor:self.cardView.leadingAnchor],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor],
        [self.textView.bottomAnchor constraintEqualToAnchor:self.cardView.bottomAnchor],
    ]];
}

#pragma mark - 动作

- (void)resetAction {
    [self.textView setText:[AiSettings defaultSystemPrompt]];
}

- (void)saveAction {
    NSString *text = [self.textView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [[AiSettings sharedSettings] setSystemPrompt:text];
    // ★ [LAND-BUG] 本页只由设置页以模态 UINavigationController(root) 弹出(LauncherPreferencesViewController:1208)，
    //   此时 pop 是空操作 ⇒ 保存后页面不退、也无其他出口。改走 dismiss（与 ResourcePacksManagerViewController.closeTapped 同款兼容写法）。
    if (self.navigationController && self.navigationController.viewControllers.firstObject != self) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
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

@end