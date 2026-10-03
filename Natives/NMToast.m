//
//  NMToast.m
//  Amethyst
//
//  Task 125/126：应用内通知实现。头注释见 NMToast.h。Task137：卡片表面
//  改用 iOS 原生样式（ame_applyCardSurfaceWithRadius，无自绘阴影）。
//
//  实现要点：
//  - 容器挂在当前 key window（UIWindow.mainWindow）上，不新建 window
//    （Task126 的教训：新 window + level 1000 = "系统弹窗"观感 + 回收难题）
//  - 卡片：原生卡片表面（secondarySystemGroupedBackground + 圆角 18，
//    深浅色由语义色自动适配），自动布局（左右边距 16、顶部贴安全区 + 8）
//  - 交互：整卡点按 = 提前关闭；动作按钮触发 onAction
//  - 顶替语义：静态 s_current 管理当前实例，新 toast 直接替换旧的
//    （旧的淡出，新的滑入，二者动画独立不冲突）
//  - 自动消失：dispatch_after + 代际令牌（generation counter），
//    防止"旧 toast 的关闭定时器误关新 toast"
//
//  ★ 来源:Gsjsjzhznsz/Air-Minecraft-iOS-Launcher(同一上游的派生 fork)的 Natives/NMToast.m,
//    按其实现移植;原作者注释中的 Task 编号与"踩过的坑"说明保留。

#import "NMToast.h"
// ★ 移植改动:原实现在此处引入 @Gsjsjzhznsz 的 UIKit+NativeSurface 头,并使用其
//   ame_applyCardSurfaceWithRadius:(新拟态卡片表面,378 行引擎)。该文件本仓库没有,
//   ⇒ 改为直接使用本仓库已有的系统语义色 + BackgroundManager 材质(见下)。故不需要该头文件。
#import "BackgroundManager.h"   // ★ 卡片表面走本仓库既有材质(已是液态玻璃)
// UIWindow.mainWindow 来自工程内 UIWindow(global) 分类（UIKit+hook.h）
// Task137：文件已从 NeomorphKit/ 迁至 Natives/ 根，相对路径 ../ 已平化
#import "UIKit+hook.h"

static NSTimeInterval const kNMToastDefaultDuration = 4.5;
static CGFloat const kNMToastHorizontalMargin = 16.0;
static CGFloat const kNMToastTopMargin = 8.0;
static CGFloat const kNMToastCornerRadius = 18.0;

// 当前在场的 toast（弱引用：toast 关闭后容器自行清理，不阻止释放）
static __weak NMToast *s_nm125_current = nil;

@interface NMToast ()
@property (nonatomic, strong) UIView *containerView;   // 全宽透明容器（布局锚点）
@property (nonatomic, strong) UIView *cardView;        // 新拟物卡片
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UIButton *actionButton;
@property (nonatomic, copy) void (^onAction)(void);
@property (nonatomic, assign) NSInteger generation;    // 自动关闭代际令牌
@end

@implementation NMToast

#pragma mark - Public

+ (void)showMessage:(NSString *)message {
    [self showMessage:message actionTitle:nil onAction:nil];
}

+ (void)showMessage:(NSString *)message duration:(NSTimeInterval)duration {
    [self showMessage:message duration:duration actionTitle:nil onAction:nil];
}

+ (void)showMessage:(NSString *)message
         actionTitle:(nullable NSString *)actionTitle
            onAction:(nullable void (^)(void))onAction {
    [self showMessage:message duration:kNMToastDefaultDuration
           actionTitle:actionTitle onAction:onAction];
}

+ (void)showMessage:(NSString *)message
                 duration:(NSTimeInterval)duration
              actionTitle:(nullable NSString *)actionTitle
                 onAction:(nullable void (^)(void))onAction {
    if (message.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        // 顶替旧 toast：直接令其退场（代际令牌使旧定时器失效）
        [s_nm125_current dismissNowAnimated:NO];

        NMToast *toast = [[NMToast alloc] initWithMessage:message
                                              actionTitle:actionTitle
                                                 onAction:onAction];
        s_nm125_current = toast;
        [toast presentWithDuration:(duration > 0 ? duration : kNMToastDefaultDuration)];
    });
}

+ (void)dismiss {
    dispatch_async(dispatch_get_main_queue(), ^{
        [s_nm125_current dismissNowAnimated:YES];
    });
}

#pragma mark - Init / Layout

- (instancetype)initWithMessage:(NSString *)message
                    actionTitle:(nullable NSString *)actionTitle
                       onAction:(nullable void (^)(void))onAction {
    self = [super init];
    if (self) {
        _onAction = onAction;
        [self buildViews:message actionTitle:actionTitle];
    }
    return self;
}

- (void)buildViews:(NSString *)message actionTitle:(nullable NSString *)actionTitle {
    UIWindow *window = UIWindow.mainWindow;
    if (!window) return;

    // ---- 全宽透明容器：布局锚点 + 拖拽/点击目标 ----
    self.containerView = [[UIView alloc] initWithFrame:CGRectZero];
    self.containerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.containerView.backgroundColor = UIColor.clearColor;

    // ---- 通知卡片（Task137：原生表面，无自绘阴影）----
    self.cardView = [[UIView alloc] initWithFrame:CGRectZero];
    self.cardView.translatesAutoresizingMaskIntoConstraints = NO;
    // ★ 移植改动:原为 [self.cardView ame_applyCardSurfaceWithRadius:kNMToastCornerRadius]
    //   (他的新拟态卡片表面)。这里改为本仓库的做法:系统语义底 + 圆角 + BackgroundManager 材质。
    //   好处:本仓库 BackgroundManager 的材质已是液态玻璃(iOS 26 UIGlassEffect),toast 与全 App 一致。
    self.cardView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.cardView.layer.cornerRadius = kNMToastCornerRadius;
    self.cardView.layer.cornerCurve = kCACornerCurveContinuous;
    self.cardView.layer.masksToBounds = YES;
    [[BackgroundManager sharedManager] applyEffectToView:self.cardView];

    // ---- 正文 ----
    self.messageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.messageLabel.numberOfLines = 0;
    self.messageLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    // ★ 移植改动:原为 AmeNeumorphPrimaryTextColor()(他的新拟态主文字色,原生模式下等于 labelColor)
    //   ⇒ 直接用系统语义色。
    self.messageLabel.textColor = [UIColor labelColor];
    self.messageLabel.text = message;

    [self.cardView addSubview:self.messageLabel];

    // ---- 可选动作按钮 ----
    if (actionTitle.length > 0) {
        self.actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.actionButton.translatesAutoresizingMaskIntoConstraints = NO;
        self.actionButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
        [self.actionButton setTitle:actionTitle forState:UIControlStateNormal];
        [self.actionButton addTarget:self action:@selector(actionTapped)
                    forControlEvents:UIControlEventTouchUpInside];
        // 高对比但不过分抢眼：label 色加粗（不引入品牌色依赖）
        [self.actionButton setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        [self.cardView addSubview:self.actionButton];
    }

    [self.containerView addSubview:self.cardView];

    // ---- 点击整卡提前关闭 ----
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(cardTapped)];
    [self.cardView addGestureRecognizer:tap];

    // ---- 布局 ----
    [window addSubview:self.containerView];
    UILayoutGuide *safe = window.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.containerView.topAnchor constraintEqualToAnchor:safe.topAnchor
                                                     constant:kNMToastTopMargin],
        [self.containerView.leadingAnchor constraintEqualToAnchor:window.leadingAnchor
                                                         constant:kNMToastHorizontalMargin],
        [self.containerView.trailingAnchor constraintEqualToAnchor:window.trailingAnchor
                                                          constant:-kNMToastHorizontalMargin],
        // 卡片贴容器（容器自身高度由卡片撑起）
        [self.cardView.topAnchor constraintEqualToAnchor:self.containerView.topAnchor],
        [self.cardView.leadingAnchor constraintEqualToAnchor:self.containerView.leadingAnchor],
        [self.cardView.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor],
        [self.cardView.bottomAnchor constraintEqualToAnchor:self.containerView.bottomAnchor],
        // 正文
        [self.messageLabel.topAnchor constraintEqualToAnchor:self.cardView.topAnchor
                                                     constant:12],
        [self.messageLabel.leadingAnchor constraintEqualToAnchor:self.cardView.leadingAnchor
                                                         constant:16],
    ]];
    if (self.actionButton) {
        // 横排：[正文 ... 动作按钮]；正文撑高，按钮垂直居中于首行
        [NSLayoutConstraint activateConstraints:@[
            [self.actionButton.leadingAnchor constraintEqualToAnchor:self.messageLabel.trailingAnchor
                                                             constant:12],
            [self.actionButton.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor
                                                             constant:-16],
            [self.actionButton.centerYAnchor constraintEqualToAnchor:self.cardView.topAnchor
                                                             constant:26],
            [self.messageLabel.bottomAnchor constraintEqualToAnchor:self.cardView.bottomAnchor
                                                            constant:-12],
        ]];
    } else {
        [self.messageLabel.bottomAnchor constraintEqualToAnchor:self.cardView.bottomAnchor
                                                        constant:-12]
            .active = YES;
    }
}

#pragma mark - Presentation

- (void)presentWithDuration:(NSTimeInterval)duration {
    if (!self.containerView.superview) return;

    // 滑入 + 淡入（从安全区上方一点落到原位）
    self.containerView.alpha = 0.0;
    self.containerView.transform = CGAffineTransformMakeTranslation(0, -12);
    [UIView animateWithDuration:0.35 delay:0
         usingSpringWithDamping:0.8
          initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.containerView.alpha = 1.0;
        self.containerView.transform = CGAffineTransformIdentity;
    } completion:nil];

    // 自动消失（代际令牌防误关后续 toast）
    NSInteger gen = self.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(duration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.generation != gen) return;          // 已被顶替
        if (s_nm125_current != self) return;         // 已退场
        [self dismissNowAnimated:YES];
    });
}

- (void)dismissNowAnimated:(BOOL)animated {
    // 代际 +1：作废所有未决的自动关闭定时器
    self.generation += 1;
    UIView *container = self.containerView;
    if (!container || !container.superview) return;

    // completion: 签名要求 BOOL finished 参数（CI 35457821271 类型错误教训）
    void (^teardown)(BOOL) = ^(BOOL finished) {
        [container removeFromSuperview];
    };
    if (animated) {
        [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseIn
                         animations:^{
            container.alpha = 0.0;
            container.transform = CGAffineTransformMakeTranslation(0, -12);
        } completion:teardown];
    } else {
        teardown(NO);
    }
}

#pragma mark - Actions

- (void)cardTapped {
    void (^block)(void) = self.onAction;
    [self dismissNowAnimated:YES];
    // 点击整卡仅关闭，不触发动动作（动作由按钮专属触发）
    (void)block;
}

- (void)actionTapped {
    void (^block)(void) = self.onAction;
    self.onAction = nil;                    // 防重复触发
    [self dismissNowAnimated:YES];
    if (block) block();
}

@end
