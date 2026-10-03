//
//  LauncherSkeletonView.m
//  Amethyst
//
//  列表骨架屏实现。
//
//  视觉沿用项目现有毛玻璃体系的语言（见 BackgroundManager / InlineMessageView）：
//  半透明白色圆角占位条 + 浅描边，透出底层壁纸，再叠一层错峰渐隐的"呼吸"动画，
//  让"正在加载"这件事可被看见，而不是空白或卡住。
//

#import "LauncherSkeletonView.h"

#include <math.h>

/// 列表行占位高度 / 行间距
static CGFloat const kSkeletonListRowHeight = 64.0;
static CGFloat const kSkeletonListRowSpacing = 10.0;
/// 网格卡片高度 / 卡片间距
static CGFloat const kSkeletonGridCardHeight = 104.0;
static CGFloat const kSkeletonGridSpacing = 10.0;
/// 占位条底色 / 描边（保持通透，避免遮死壁纸）
static CGFloat const kSkeletonFillAlpha = 0.12;
static CGFloat const kSkeletonBorderAlpha = 0.06;
/// 宽屏（iPad / 横屏）下的网格列数阈值
static CGFloat const kSkeletonGridWideWidth = 520.0;

@interface LauncherSkeletonView ()

/// 占位样式（创建时固定）
@property (nonatomic, assign) LauncherSkeletonStyle skeletonStyle;
/// 当前所有占位条
@property (nonatomic, strong) NSMutableArray<UIView *> *placeholderViews;
/// 上次构建占位条时的尺寸（尺寸变化才重建）
@property (nonatomic, assign) CGSize lastPlaceholderLayoutSize;

/// 指定样式的初始化器（仅内部使用）
- (instancetype)initWithFrame:(CGRect)frame style:(LauncherSkeletonStyle)style;
/// 按当前尺寸重建占位条
- (void)rebuildPlaceholdersIfNeeded:(BOOL)force;
/// 构建列表行样式占位条
- (void)buildListPlaceholdersForSize:(CGSize)size;
/// 构建卡片网格样式占位条
- (void)buildCardGridPlaceholdersForSize:(CGSize)size;
/// 创建一条占位条
- (UIView *)makePlaceholderViewWithFrame:(CGRect)frame cornerRadius:(CGFloat)cornerRadius;
/// 统一占位条视觉（底色 / 圆角 / 描边）
- (void)applyPlaceholderStyleToView:(UIView *)view cornerRadius:(CGFloat)cornerRadius;
/// 呼吸动画
- (void)startBreathingAnimation;
- (void)stopBreathingAnimation;

@end

@implementation LauncherSkeletonView

#pragma mark - 创建 / 销毁

+ (instancetype)attachToView:(UIView *)hostView style:(LauncherSkeletonStyle)style {
    if (!hostView) {
        return nil;
    }
    UIView *parentView = hostView.superview ?: hostView;
    if (!parentView) {
        return nil;
    }

    LauncherSkeletonView *skeleton = [[LauncherSkeletonView alloc] initWithFrame:hostView.bounds style:style];
    skeleton.translatesAutoresizingMaskIntoConstraints = NO;
    skeleton.hidden = YES;
    // 纯视觉层：不拦截触摸，列表滚动 / 下拉刷新照常可用
    skeleton.userInteractionEnabled = NO;
    [parentView addSubview:skeleton];

    [NSLayoutConstraint activateConstraints:@[
        [skeleton.topAnchor constraintEqualToAnchor:hostView.topAnchor],
        [skeleton.bottomAnchor constraintEqualToAnchor:hostView.bottomAnchor],
        [skeleton.leadingAnchor constraintEqualToAnchor:hostView.leadingAnchor],
        [skeleton.trailingAnchor constraintEqualToAnchor:hostView.trailingAnchor],
    ]];

    return skeleton;
}

- (instancetype)initWithFrame:(CGRect)frame style:(LauncherSkeletonStyle)style {
    self = [super initWithFrame:frame];
    if (self) {
        _skeletonStyle = style;
        _placeholderViews = [NSMutableArray array];
        self.backgroundColor = [UIColor clearColor];
        self.clipsToBounds = YES;
        self.layer.masksToBounds = YES;
    }
    return self;
}

- (void)dealloc {
    [self stopBreathingAnimation];
}

#pragma mark - 显示 / 隐藏

- (void)showSkeleton {
    [self rebuildPlaceholdersIfNeeded:YES];
    self.hidden = NO;
    _skeletonVisible = YES;
    [self startBreathingAnimation];

    if (self.alpha < 1.0) {
        [UIView animateWithDuration:0.15 animations:^{
            self.alpha = 1.0;
        }];
    }
}

- (void)hideSkeleton {
    if (self.hidden) {
        return;
    }
    _skeletonVisible = NO;

    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:0.2 animations:^{
        weakSelf.alpha = 0.0;
    } completion:^(BOOL finished) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.skeletonVisible) {
            return;  // 淡出过程中又被要求显示，保持现状
        }
        strongSelf.hidden = YES;
        strongSelf.alpha = 1.0;
        [strongSelf stopBreathingAnimation];
    }];
}

- (void)hideSkeletonImmediately {
    _skeletonVisible = NO;
    [self stopBreathingAnimation];
    [self.layer removeAllAnimations];
    self.hidden = YES;
    self.alpha = 1.0;
}

#pragma mark - 布局

- (void)layoutSubviews {
    [super layoutSubviews];

    if (CGSizeEqualToSize(self.bounds.size, self.lastPlaceholderLayoutSize)) {
        return;
    }
    [self rebuildPlaceholdersIfNeeded:YES];
    if (self.skeletonVisible) {
        [self startBreathingAnimation];
    }
}

- (void)rebuildPlaceholdersIfNeeded:(BOOL)force {
    if (!force && CGSizeEqualToSize(self.bounds.size, self.lastPlaceholderLayoutSize)) {
        return;
    }
    self.lastPlaceholderLayoutSize = self.bounds.size;

    for (UIView *placeholder in self.placeholderViews) {
        [placeholder.layer removeAllAnimations];
        [placeholder removeFromSuperview];
    }
    [self.placeholderViews removeAllObjects];

    CGSize size = self.bounds.size;
    if (size.width < 1.0 || size.height < 1.0) {
        return;
    }

    if (self.skeletonStyle == LauncherSkeletonStyleCardGrid) {
        [self buildCardGridPlaceholdersForSize:size];
    } else {
        [self buildListPlaceholdersForSize:size];
    }
}

/// 列表行样式：左侧图标方块 + 两行文本条，尽量贴近真实卡片的视觉重量
- (void)buildListPlaceholdersForSize:(CGSize)size {
    CGFloat sideInset = 4.0;
    CGFloat rowWidth = MAX(size.width - sideInset * 2.0, 1.0);
    NSInteger rowCount = (NSInteger)ceil((size.height + kSkeletonListRowSpacing) /
                                         (kSkeletonListRowHeight + kSkeletonListRowSpacing));

    for (NSInteger index = 0; index < rowCount; index++) {
        CGRect rowFrame = CGRectMake(sideInset,
                                     index * (kSkeletonListRowHeight + kSkeletonListRowSpacing),
                                     rowWidth,
                                     kSkeletonListRowHeight);
        UIView *row = [self makePlaceholderViewWithFrame:rowFrame cornerRadius:12.0];
        [self addSubview:row];
        [self.placeholderViews addObject:row];

        CGFloat iconSide = 44.0;
        UIView *icon = [[UIView alloc] initWithFrame:CGRectMake(14.0,
                                                               (kSkeletonListRowHeight - iconSide) / 2.0,
                                                               iconSide,
                                                               iconSide)];
        [self applyPlaceholderStyleToView:icon cornerRadius:10.0];
        [row addSubview:icon];

        CGFloat textLeft = 14.0 + iconSide + 12.0;
        CGFloat textWidth = MAX(rowWidth - textLeft - 16.0, 1.0);

        UIView *titleBar = [[UIView alloc] initWithFrame:CGRectMake(textLeft, 19.0, textWidth * 0.62, 13.0)];
        [self applyPlaceholderStyleToView:titleBar cornerRadius:6.0];
        [row addSubview:titleBar];

        UIView *subtitleBar = [[UIView alloc] initWithFrame:CGRectMake(textLeft, 40.0, textWidth * 0.42, 10.0)];
        [self applyPlaceholderStyleToView:subtitleBar cornerRadius:5.0];
        [row addSubview:subtitleBar];
    }
}

/// 卡片网格样式：与版本列表的卡片流对齐（iPhone 两列，宽屏三列）
- (void)buildCardGridPlaceholdersForSize:(CGSize)size {
    CGFloat sideInset = 8.0;
    CGFloat gap = kSkeletonGridSpacing;
    NSInteger columnCount = (size.width >= kSkeletonGridWideWidth) ? 3 : 2;
    CGFloat cardWidth = floor((size.width - sideInset * 2.0 - gap * (CGFloat)(columnCount - 1)) / (CGFloat)columnCount);
    if (cardWidth < 40.0) {
        columnCount = 1;
        cardWidth = MAX(size.width - sideInset * 2.0, 1.0);
    }
    NSInteger rowCount = (NSInteger)ceil((size.height + gap) / (kSkeletonGridCardHeight + gap));

    for (NSInteger rowIndex = 0; rowIndex < rowCount; rowIndex++) {
        for (NSInteger columnIndex = 0; columnIndex < columnCount; columnIndex++) {
            CGRect cardFrame = CGRectMake(sideInset + columnIndex * (cardWidth + gap),
                                          rowIndex * (kSkeletonGridCardHeight + gap),
                                          cardWidth,
                                          kSkeletonGridCardHeight);
            UIView *card = [self makePlaceholderViewWithFrame:cardFrame cornerRadius:14.0];
            [self addSubview:card];
            [self.placeholderViews addObject:card];
        }
    }
}

#pragma mark - 占位条样式与动画

- (UIView *)makePlaceholderViewWithFrame:(CGRect)frame cornerRadius:(CGFloat)cornerRadius {
    UIView *view = [[UIView alloc] initWithFrame:frame];
    view.autoresizingMask = UIViewAutoresizingNone;
    [self applyPlaceholderStyleToView:view cornerRadius:cornerRadius];
    return view;
}

- (void)applyPlaceholderStyleToView:(UIView *)view cornerRadius:(CGFloat)cornerRadius {
    if (!view) {
        return;
    }
    view.backgroundColor = [UIColor colorWithWhite:1.0 alpha:kSkeletonFillAlpha];
    view.layer.cornerRadius = cornerRadius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.borderWidth = 1.0;
    view.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:kSkeletonBorderAlpha].CGColor;
    view.layer.masksToBounds = YES;
}

/// 呼吸动画：占位条按行错峰渐隐渐显，暗示"正在加载"
- (void)startBreathingAnimation {
    NSTimeInterval stagger = 0.0;
    for (UIView *placeholder in self.placeholderViews) {
        [placeholder.layer removeAllAnimations];
        placeholder.alpha = 1.0;
        [UIView animateWithDuration:0.85
                              delay:stagger
                            options:(UIViewAnimationOptionRepeat |
                                     UIViewAnimationOptionAutoreverse |
                                     UIViewAnimationOptionCurveEaseInOut)
                         animations:^{
            placeholder.alpha = 0.45;
        }
                         completion:nil];

        stagger += 0.05;
        if (stagger > 0.3) {
            stagger = 0.0;
        }
    }
}

- (void)stopBreathingAnimation {
    for (UIView *placeholder in self.placeholderViews) {
        [placeholder.layer removeAllAnimations];
        placeholder.alpha = 1.0;
    }
}

@end
