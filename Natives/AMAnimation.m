// AMAnimation.m —— 公式与语义见同名头文件注释（ZL2 移植，勿凭感觉改数值）
#import "AMAnimation.h"
#import <math.h>

NSString * const AMAnimationSettingsDidChangeNotification = @"AMAnimationSettingsDidChange";

static NSString * const kSpeedKey = @"amui.anim.speed";
static NSString * const kExtentKey = @"amui.anim.extent";
static NSString * const kTransitionKey = @"amui.anim.transition";

#pragma mark - ZL2 easing 公式（_Easing.kt 逐行移植）

static CGFloat AMJellyBounce(CGFloat t) {
    // 1 - 0.6·e^(-8t)·cos(6πt)：t=0 时 0.4（入场初速快），之后 ~3 次衰减震荡
    return (CGFloat)(1.0 - 0.6 * exp(-8.0 * (double)t) * cos(6.0 * M_PI * (double)t));
}

static CGFloat AMBounceCore(CGFloat x) {
    return x * x * 8.0;
}

static CGFloat AMBounce(CGFloat t) {
    // _Easing.kt BounceEasing：输入拉伸 1.1226 后四段折返
    CGFloat input = t * 1.1226;
    if (input < 0.3535) return AMBounceCore(input);
    if (input < 0.7408) return AMBounceCore(input - 0.54719) + 0.7;
    if (input < 0.9644) return AMBounceCore(input - 0.8526) + 0.9;
    return AMBounceCore(input - 1.0435) + 0.95;
}

static CGFloat AMEaseInOutQuad(CGFloat t) {
    return (t < 0.5) ? (2.0 * t * t) : (1.0 - pow(-2.0 * t + 2.0, 2.0) / 2.0);
}

#pragma mark - 驱动器
// 保留链：CADisplayLink 强持有 driver（target），driver 强持有 link。
// tick 结束时 invalidate 打破环 —— 无泄漏、无需弱代理、天然支持多动画并发。

@interface AMSwapDriver : NSObject
@property (nonatomic, strong, nullable) CADisplayLink *link;
@property (nonatomic, copy) void (^block)(CGFloat);
@property (nonatomic, copy, nullable) void (^completion)(void);
@property (nonatomic, assign) CFTimeInterval startTime;   // 已含 delay
@property (nonatomic, assign) CFTimeInterval duration;
@property (nonatomic, copy, nullable) AMEasingBlock easing;
@end

@implementation AMSwapDriver

- (void)dealloc {
    [_link invalidate];
}

- (void)startWithDelay:(NSTimeInterval)delay {
    self.startTime = CACurrentMediaTime() + delay;
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self
                                                      selector:@selector(tick:)];
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    self.link = link;
}

- (void)tick:(CADisplayLink *)link {
    CFTimeInterval now = CACurrentMediaTime();
    if (now < self.startTime) return;                       // delay 未到
    CFTimeInterval elapsed = now - self.startTime;
    if (self.duration <= 0 || elapsed >= self.duration) {
        self.block(self.easing ? self.easing(1.0) : 1.0);   // 终值（easing(1.0)≈1）
        [link invalidate];
        self.link = nil;
        if (self.completion) self.completion();
        return;
    }
    CGFloat t = (CGFloat)(elapsed / self.duration);
    self.block(self.easing ? self.easing(t) : t);
}

@end

#pragma mark - AMAnimation

@implementation AMAnimation

+ (void)initialize {
    if (self == [AMAnimation class]) {
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
            kSpeedKey: @(5),
            kExtentKey: @(5),
            kTransitionKey: @(AMTransitionTypeJellyBounce),
        }];
    }
}

#pragma mark - 偏好

+ (NSInteger)speed {
    return [[NSUserDefaults standardUserDefaults] integerForKey:kSpeedKey];
}
+ (void)setSpeed:(NSInteger)speed {
    [[NSUserDefaults standardUserDefaults] setInteger:MAX(MIN(speed, 10), 0) forKey:kSpeedKey];
    [AMAnimation notifyChange];
}
+ (NSInteger)extent {
    return [[NSUserDefaults standardUserDefaults] integerForKey:kExtentKey];
}
+ (void)setExtent:(NSInteger)extent {
    [[NSUserDefaults standardUserDefaults] setInteger:MAX(MIN(extent, 10), 0) forKey:kExtentKey];
    [AMAnimation notifyChange];
}
+ (AMTransitionType)transitionType {
    NSInteger t = [[NSUserDefaults standardUserDefaults] integerForKey:kTransitionKey];
    return (t >= 0 && t <= AMTransitionTypeSliceIn) ? (AMTransitionType)t : AMTransitionTypeJellyBounce;
}
+ (void)setTransitionType:(AMTransitionType)type {
    [[NSUserDefaults standardUserDefaults] setInteger:type forKey:kTransitionKey];
    [AMAnimation notifyChange];
}
+ (void)notifyChange {
    [[NSNotificationCenter defaultCenter] postNotificationName:AMAnimationSettingsDidChangeNotification
                                                        object:nil];
}

+ (NSString *)transitionTypeDisplayName:(AMTransitionType)type {
    static NSArray<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[ @"关闭", @"弹跳", @"果冻回弹", @"切入" ];
    });
    return (type <= AMTransitionTypeSliceIn) ? names[type] : @"?";
}
+ (NSArray<NSString *> *)allTransitionTypeDisplayNames {
    NSMutableArray *out = [NSMutableArray array];
    for (NSInteger i = 0; i <= AMTransitionTypeSliceIn; i++) {
        [out addObject:[AMAnimation transitionTypeDisplayName:(AMTransitionType)i]];
    }
    return out;
}

#pragma mark - 换算

+ (NSTimeInterval)durationForBase:(NSTimeInterval)baseSeconds {
    // ZL2 calculateAnimationTime：factor = 1 - speed/10·(1-minFactor)，minFactor=0.25
    CGFloat speed = (CGFloat)[AMAnimation speed];
    CGFloat factor = 1.0 - (speed / 10.0) * (1.0 - 0.25);
    return baseSeconds * MAX(factor, 0.25);
}

+ (CGFloat)scaledAmplitude:(CGFloat)baseValue {
    // ZL2 getTargetValueByAmplitude：scale = 0.5 + extent/10（0→0.5x，5→1x，10→1.5x）
    CGFloat extent = (CGFloat)[AMAnimation extent];
    return baseValue * (0.5 + extent / 10.0);
}

+ (NSTimeInterval)defaultSwapDuration {
    // ZL2 getAnimateSpeed：base 1500ms
    return [AMAnimation durationForBase:1.5];
}

#pragma mark - Easing

+ (AMEasingBlock)jellyBounceEasing {
    return ^CGFloat(CGFloat t) { return AMJellyBounce(t); };
}
+ (AMEasingBlock)bounceEasing {
    return ^CGFloat(CGFloat t) { return AMBounce(t); };
}
+ (AMEasingBlock)easeInOutQuadEasing {
    return ^CGFloat(CGFloat t) { return AMEaseInOutQuad(t); };
}

+ (nullable AMEasingBlock)swapInEasing {
    switch ([AMAnimation transitionType]) {
        case AMTransitionTypeClose:       return nil;
        case AMTransitionTypeBounce:       return [AMAnimation bounceEasing];
        case AMTransitionTypeJellyBounce: return [AMAnimation jellyBounceEasing];
        case AMTransitionTypeSliceIn:     return [AMAnimation easeInOutQuadEasing];
    }
    return nil;
}

#pragma mark - 驱动器

+ (void)animateWithDuration:(NSTimeInterval)duration
                      delay:(NSTimeInterval)delay
                    easing:(nullable AMEasingBlock)easing
                animations:(void (^)(CGFloat progress))animations
                completion:(nullable void (^)(void))completion {
    NSParameterAssert(animations);
    if (duration <= 0) {
        animations(easing ? easing(1.0) : 1.0);
        if (completion) completion();
        return;
    }
    AMSwapDriver *driver = [[AMSwapDriver alloc] init];
    driver.block = animations;
    driver.completion = completion;
    driver.duration = duration;
    driver.easing = easing;
    [driver startWithDelay:delay];
}

+ (void)swapAnimateIn:(BOOL)swapIn
         baseDuration:(NSTimeInterval)baseDuration
           animations:(void (^)(CGFloat progress))animations
           completion:(nullable void (^)(void))completion {
    AMEasingBlock easing = swapIn ? [AMAnimation swapInEasing]
                                  : [AMAnimation easeInOutQuadEasing];
    if (swapIn && !easing) {   // CLOSE：直接到位
        animations(1.0);
        if (completion) completion();
        return;
    }
    [AMAnimation animateWithDuration:[AMAnimation durationForBase:baseDuration]
                              delay:0
                            easing:easing
                        animations:animations
                        completion:completion];
}

@end
