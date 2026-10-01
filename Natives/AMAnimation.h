// AMAnimation.h —— Amethyst 新 UI 设计系统 · 动画引擎（ui-redesign P0）
// 公式移植自 ZalithLauncher2 utils/animation/{_Easing,AnimationUtils,TransitionAnimationType}.kt：
//   JellyBounce: f(t) = 1 - 0.6·e^(-8t)·cos(6πt)     （阻尼余弦，约 3 个回弹周期）
//   BounceEasing: 分段 8x²（4 段折返）
//   时长换算:    factor = 1 - speed/10·(1-minFactor)，minFactor=0.25
//                （ZL2 getSwapAnimateTween 的默认 tween 用同一公式调延迟）
//   幅度换算:    scale = 0.5 + extent/10 → 位移乘数 0.5x..1.5x
//
// UIKit 的 UIView 动画不支持任意 easing，这里用 CADisplayLink 驱动器把
// easing 应用到任意属性（frame/alpha/transform 都行），语义与 Compose 的
// animateXAsState(tween(easing=...)) 对齐。
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, AMTransitionType) {
    AMTransitionTypeClose = 0,      // 关闭（直接到位）
    AMTransitionTypeBounce,         // 弹跳
    AMTransitionTypeJellyBounce,    // 果冻回弹（默认，ZL2 招牌）
    AMTransitionTypeSliceIn,        // 切入
};

/// t ∈ [0,1] → 进度值（可 >1 过冲 / <0 回落）
typedef CGFloat (^AMEasingBlock)(CGFloat t);

extern NSString * const AMAnimationSettingsDidChangeNotification;

@interface AMAnimation : NSObject

#pragma mark - 偏好（UserDefaults 持久化）

/// 动画速度 0..10，默认 5。0=原速，10=0.25x 时长
+ (NSInteger)speed;
+ (void)setSpeed:(NSInteger)speed;

/// 幅度 0..10，默认 5。作用于位移类动画的乘数（0.5x..1.5x）
+ (NSInteger)extent;
+ (void)setExtent:(NSInteger)extent;

/// 页面转场类型，默认果冻回弹
+ (AMTransitionType)transitionType;
+ (void)setTransitionType:(AMTransitionType)type;

+ (NSString *)transitionTypeDisplayName:(AMTransitionType)type;
+ (NSArray<NSString *> *)allTransitionTypeDisplayNames;   // 供设置页枚举

#pragma mark - 换算（ZL2 公式）

/// baseSeconds 按当前速度换算后的实际时长
+ (NSTimeInterval)durationForBase:(NSTimeInterval)baseSeconds;

/// 位移类动画的幅度乘数（baseValue × 0.5..1.5）
+ (CGFloat)scaledAmplitude:(CGFloat)baseValue;

/// ZL2 默认转场时长（base 1.5s，与 getAnimateSpeed 的 1500ms 对齐）
+ (NSTimeInterval)defaultSwapDuration;

#pragma mark - Easing

+ (AMEasingBlock)jellyBounceEasing;
+ (AMEasingBlock)bounceEasing;
+ (AMEasingBlock)easeInOutQuadEasing;   // 切入模式用（≈Compose FastOutSlowIn）

/// 当前转场类型对应的入场 easing；CLOSE 返回 nil（调用方直接 set 最终值）
+ (nullable AMEasingBlock)swapInEasing;

#pragma mark - 驱动器（CADisplayLink，任意属性可动画）

/// 通用动画：easing=nil 时按线性推进（progress 直接给 t）
+ (void)animateWithDuration:(NSTimeInterval)duration
                      delay:(NSTimeInterval)delay
                    easing:(nullable AMEasingBlock)easing
                animations:(void (^)(CGFloat progress))animations
                completion:(nullable void (^)(void))completion;

/// 页面进出场统一入口：
///   swapIn=YES  → 入场，按当前转场类型选 easing（CLOSE → 直接完成）
///   swapIn=NO   → 退场，基础缓入缓出（ZL2 退场恒用默认 tween）
+ (void)swapAnimateIn:(BOOL)swapIn
         baseDuration:(NSTimeInterval)baseDuration
           animations:(void (^)(CGFloat progress))animations
           completion:(nullable void (^)(void))completion;

@end

NS_ASSUME_NONNULL_END
