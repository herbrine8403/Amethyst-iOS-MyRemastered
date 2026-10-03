#import "utils.h"
//
//  BackgroundManager.m
//  Amethyst
//
//  Background wallpaper manager implementation - Global Version with Transparency
//

#import "BackgroundManager.h"
#import "UIKit+GlassSurface.h"   // ★ 液态玻璃材质 + 玻璃质感(高光边)
#import <Photos/Photos.h>

static NSString * const kBackgroundTypeKey = @"background_type";
static NSString * const kBackgroundPathKey = @"background_path";
static NSString * const kBackgroundUIEffectKey = @"background_ui_effect";
static NSString * const kBackgroundUIOpacityKey = @"background_ui_opacity";
static NSString * const kBackgroundBlurIntensityKey = @"background_blur_intensity";
static NSString * const kGlassRimEnabledKey  = @"background_glass_rim_enabled";   // ★ [RIM-UI]
static NSString * const kGlassRimStrengthKey = @"background_glass_rim_strength";  // ★ [RIM-UI]
static NSString * const kBackgroundsFolder = @"backgrounds";
static const NSInteger kGlobalBackgroundTag = 99999;
static const NSInteger kBackgroundImageTag = 99998;
static const NSInteger kBackgroundBlurTag = 99997;
static const NSInteger kBackgroundDimTag = 99996;
static const NSInteger kDefaultBackgroundTag = 99995;
// ★ [GLASSUI] 合并同一 runloop 内的多次玻璃重刷(强度滑块连续拖动时避免反复遍历视图树)
static BOOL gAmeGlassRimApplyScheduled = NO;

#pragma mark - ★ [E3] 默认背景渐变视图(SPEC §2.1:深=紫蓝 / 浅=白→粉紫)
//
// 未设自定义背景图/视频时的默认背景。原实现是平面 systemBackgroundColor(深黑/浅白),
// 与 E 稿「深 = 紫蓝渐变 / 浅 = 白→粉紫渐变」不符。
// 本视图自绘渐变(base 线性 + 3 个椭圆径向光斑),仅当 currentType == BackgroundTypeNone
// (无自定义背景)时挂载 ⇒ 不触碰自定义背景图/视频路径,主界面自定义能力保留。
@interface AmeGradientBackgroundView : UIView
@end

@implementation AmeGradientBackgroundView {
    CGSize _ameLastLayoutSize;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.userInteractionEnabled = NO;
        self.opaque = YES;
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 13.0, *)) {
        if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
            [self setNeedsDisplay];
        }
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // 尺寸变化(旋转/分屏)后重绘,保证渐变铺满
    if (!CGSizeEqualToSize(_ameLastLayoutSize, self.bounds.size)) {
        _ameLastLayoutSize = self.bounds.size;
        [self setNeedsDisplay];
    }
}

- (void)drawRect:(CGRect)rect {
    BOOL dark = YES;
    if (@available(iOS 13.0, *)) {
        dark = (self.traitCollection.userInterfaceStyle != UIUserInterfaceStyleLight);
    }
    [AmeGradientBackgroundView ame_drawDefaultBackgroundInRect:self.bounds dark:dark];
}

// 一个椭圆径向渐变(CSS radial(rx ry at x y) 用 CTM 缩放近似:先画圆再压扁)
+ (void)ame_drawRadialInContext:(CGContextRef)ctx
                         center:(CGPoint)c
                             rx:(CGFloat)rx
                             ry:(CGFloat)ry
                          color:(UIColor *)color
                           stop:(CGFloat)stop {
    if (rx <= 0.0 || ry <= 0.0 || color == nil) { return; }
    CGFloat r = 0.0, g = 0.0, b = 0.0, a = 1.0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        const CGFloat *cs = CGColorGetComponents(color.CGColor);
        size_t n = CGColorGetNumberOfComponents(color.CGColor);
        if (cs != NULL) {
            r = cs[0]; g = cs[1]; b = cs[2]; a = (n >= 4) ? cs[3] : 1.0;
        }
    }
    CGFloat comps[8] = { r, g, b, a, r, g, b, 0.0 };
    CGFloat locs[2]  = { 0.0, MAX(0.01, MIN(1.0, stop)) };
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef grad = CGGradientCreateWithColorComponents(space, comps, locs, 2);
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, c.x, c.y);
    CGContextScaleCTM(ctx, 1.0, ry / rx);            // 圆 → 椭圆
    CGContextDrawRadialGradient(ctx, grad, CGPointZero, 0.0, CGPointZero, rx,
                                kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGContextRestoreGState(ctx);
    CGGradientRelease(grad);
    CGColorSpaceRelease(space);
}

+ (void)ame_drawDefaultBackgroundInRect:(CGRect)b dark:(BOOL)dark {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx == NULL || b.size.width <= 0.0 || b.size.height <= 0.0) { return; }
    const CGFloat W = b.size.width, H = b.size.height;

    UIColor *base0 = nil, *base1 = nil, *r1 = nil, *r2 = nil, *r3 = nil;
    CGFloat r1x = 0.9 * W, r1y = 0.70 * H, r1s = 0.60;   // 蓝光斑
    CGFloat r2x = 0.9 * W, r2y = 0.80 * H, r2s = 0.55;   // 品红/粉光斑
    CGFloat r3x = 0.8 * W, r3y = 0.70 * H, r3s = 0.60;   // 青色/薄荷光斑
    if (dark) {
        // 深色:紫蓝渐变  base #101322 → #05060c
        base0 = AmeRGBA(0x10, 0x13, 0x22, 1.0);
        base1 = AmeRGBA(0x05, 0x06, 0x0C, 1.0);
        r1 = AmeRGBA(90, 130, 255, 0.55);
        r2 = AmeRGBA(210, 90, 220, 0.50);
        r3 = AmeRGBA(0, 220, 200, 0.32);
    } else {
        // 浅色:白→粉紫  base #eef3ff → #fdf8ff
        base0 = AmeRGBA(0xEE, 0xF3, 0xFF, 1.0);
        base1 = AmeRGBA(0xFD, 0xF8, 0xFF, 1.0);
        r1 = AmeRGBA(150, 185, 255, 0.90);
        r2 = AmeRGBA(255, 175, 235, 0.85);
        r3 = AmeRGBA(160, 240, 225, 0.70);
    }

    // 线性底(top → bottom)
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef baseGrad = CGGradientCreateWithColors(space,
        (__bridge CFArrayRef)@[(id)base0.CGColor, (id)base1.CGColor], NULL);
    CGContextDrawLinearGradient(ctx, baseGrad,
                                CGPointMake(CGRectGetMinX(b), CGRectGetMinY(b)),
                                CGPointMake(CGRectGetMinX(b), CGRectGetMaxY(b)), 0);
    CGGradientRelease(baseGrad);
    CGColorSpaceRelease(space);

    // 三个径向光斑(坐标 = CSS 的 at x% y%)
    [self ame_drawRadialInContext:ctx
                           center:CGPointMake(CGRectGetMinX(b) + 0.12 * W, CGRectGetMinY(b) + 0.00 * H)
                               rx:r1x ry:r1y color:r1 stop:r1s];
    [self ame_drawRadialInContext:ctx
                           center:CGPointMake(CGRectGetMinX(b) + 0.92 * W, CGRectGetMinY(b) + 0.22 * H)
                               rx:r2x ry:r2y color:r2 stop:r2s];
    [self ame_drawRadialInContext:ctx
                           center:CGPointMake(CGRectGetMinX(b) + 0.40 * W, CGRectGetMinY(b) + 1.00 * H)
                               rx:r3x ry:r3y color:r3 stop:r3s];
}

@end

@interface BackgroundManager ()
@property (nonatomic, strong) AVPlayer *videoPlayer;
@property (nonatomic, strong) AVPlayerLayer *videoPlayerLayer;
@property (nonatomic, weak) UIView *currentBackgroundView;
@property (nonatomic, readwrite) BackgroundType currentType;
@property (nonatomic, readwrite, nullable) NSString *currentBackgroundPath;
@property (nonatomic, weak) UIWindow *currentWindow;
@property (nonatomic, weak) UISplitViewController *currentSplitVC;
@property (nonatomic, strong, readwrite, nullable) UIView *globalBackgroundContainer;
// ★ [E3] 记住默认渐变宿主(removeGlobalBackground 的 currentWindow 会被置 nil,需单独持弱引用清理)
@property (nonatomic, weak) UIView *ameDefaultGradientHost;
// ★ [E3] 私有:把默认渐变背景挂到宿主(window / splitVC.view)
- (void)ame_applyDefaultGradientToHost:(UIView *)host;
// ★ [GLASSUI] 私有:玻璃高光设置即时生效(设置页接入用)
- (void)applyGlassRimSettingsNow;
- (void)ameApplyGlassRimSettingsToViewTree:(UIView *)root;
@end

@implementation BackgroundManager

+ (instancetype)sharedManager {
    static BackgroundManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self loadSavedBackground];
        [self loadUISettings];
        [self setupNotifications];
    }
    return self;
}

- (void)setupNotifications {
    // App lifecycle
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidEnterBackground)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appWillEnterForeground)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
    
    // Video loop
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerItemDidReachEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:nil];
    
    // Orientation changes
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleOrientationChange)
                                                 name:UIApplicationDidChangeStatusBarOrientationNotification
                                               object:nil];
    
    // Window size changes (iPad multitasking, rotation)
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateBackgroundFrame)
                                                 name:UIApplicationWillChangeStatusBarFrameNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self cleanupVideoPlayer];
}

#pragma mark - Backgrounds Folder

- (NSString *)backgroundsFolderPath {
    NSString *docsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *folder = [docsDir stringByAppendingPathComponent:kBackgroundsFolder];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:folder]) {
        [fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    return folder;
}

#pragma mark - Load/Save Background

- (void)loadSavedBackground {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    self.currentType = [defaults integerForKey:kBackgroundTypeKey];
    self.currentBackgroundPath = [defaults stringForKey:kBackgroundPathKey];
    
    // Validate path exists
    if (self.currentBackgroundPath && ![[NSFileManager defaultManager] fileExistsAtPath:self.currentBackgroundPath]) {
        self.currentBackgroundPath = nil;
        self.currentType = BackgroundTypeNone;
        [self saveBackgroundSettings];
    }
}

- (void)saveBackgroundSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:self.currentType forKey:kBackgroundTypeKey];
    // ★ [AUDIT] currentBackgroundPath 是 nullable(见头文件),clearBackgroundInternal /
    //   loadSavedBackground 都会把它置为 nil;而 setObject:forKey: 传 nil 会抛
    //   NSInvalidArgumentException(object cannot be nil)→ 崩溃(与
    //   「setTitleTextAttributes:nil」属同一类「把 nil 传给非空参数」的崩法)。
    //   nil 时改用 removeObjectForKey: 清除该键(NSUserDefaults 的官方清值方式)。
    if (self.currentBackgroundPath.length > 0) {
        [defaults setObject:self.currentBackgroundPath forKey:kBackgroundPathKey];
    } else {
        [defaults removeObjectForKey:kBackgroundPathKey];
    }
    [defaults synchronize];
}

- (void)loadUISettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    // ★ [UI-B] 修复(2026-10-02):键不存在时 integerForKey 返回 0,而 0 == BackgroundUIEffectTranslucent,
    //   越界校验永远判不出"从未设置过" ⇒ 首装默认落到"半透明" ⇒ applyEffectToView: 的 Blur 分支永不执行
    //   ⇒ 整条玻璃路径被静默跳过(用户现场:"我可以保证主界面绝对没有玻璃")。用 objectForKey 区分。
    id ameEffObj = [defaults objectForKey:kBackgroundUIEffectKey];
    _uiEffect = ameEffObj ? [defaults integerForKey:kBackgroundUIEffectKey] : BackgroundUIEffectBlur;
    if (_uiEffect < BackgroundUIEffectTranslucent || _uiEffect > BackgroundUIEffectBlur) {
        _uiEffect = BackgroundUIEffectBlur; // 默认毛玻璃效果
    }
    
    _uiOpacity = [defaults floatForKey:kBackgroundUIOpacityKey];
    if (_uiOpacity < 0.1 || _uiOpacity > 1.0) {
        _uiOpacity = 0.7; // 默认透明度
    }
    
    // ★ [UI-B] 同型修复(2026-10-02):键不存在返回 0.0,恰在合法区间 [0,1] 内 ⇒ 强度 0%
    //   ⇒ blurView.alpha = 0.3 + 0*0.7 = 0.3,观感近于无。默认给 0.7。
    id ameBlurObj = [defaults objectForKey:kBackgroundBlurIntensityKey];
    _blurIntensity = ameBlurObj ? [defaults floatForKey:kBackgroundBlurIntensityKey] : 0.7;
    if (_blurIntensity < 0.0 || _blurIntensity > 1.0) {
        _blurIntensity = 0.7; // 默认模糊程度
    }

    // ★ [GLASS-MIGRATE] 一次性迁移:老版本"键不存在 => 0 => 半透明"的 bug 会把第一次运行写成
    //   "半透明",于是 applyEffectToView: 永远走 else 分支 ⇒ 用户现场"主界面绝对没有玻璃"。
    //   这里只做【一次】:若当前是半透明且从未迁移过,改成毛玻璃并打标记(用户仍可在设置里改回)。
    static NSString * const kGlassMigratedKey = @"background.glass_migrated_v1";
    if (_uiEffect == BackgroundUIEffectTranslucent && ![defaults boolForKey:kGlassMigratedKey]) {
        _uiEffect = BackgroundUIEffectBlur;
        [defaults setInteger:_uiEffect forKey:kBackgroundUIEffectKey];
        [defaults setBool:YES forKey:kGlassMigratedKey];
        [defaults synchronize];
        NSLog(@"[glass] migrated uiEffect: Translucent -> Blur (一次性,可在设置里改回)");
    }
    // ★ [RIM-UI] 高光开关 / 强度(默认:开、1.0)
    id ameRimObj  = [defaults objectForKey:kGlassRimEnabledKey];
    _glassRimEnabled  = ameRimObj ? [defaults boolForKey:kGlassRimEnabledKey] : YES;
    id ameRimSObj = [defaults objectForKey:kGlassRimStrengthKey];
    _glassRimStrength = ameRimSObj ? [defaults floatForKey:kGlassRimStrengthKey] : 1.0;
    if (_glassRimStrength < 0.0 || _glassRimStrength > 1.0) _glassRimStrength = 1.0;
    AmeSetGlassRimStrength(_glassRimEnabled ? _glassRimStrength : 0.0);

    NSLog(@"[glass] settings loaded: uiEffect=%ld (0=半透明,1=毛玻璃) blurIntensity=%.2f uiOpacity=%.2f",
          (long)_uiEffect, _blurIntensity, _uiOpacity);
    NSLog(@"[glass] rim: enabled=%d strength=%.2f", (int)self.glassRimEnabled, self.glassRimStrength);
}

- (void)saveUISettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:self.uiEffect forKey:kBackgroundUIEffectKey];
    [defaults setFloat:self.uiOpacity forKey:kBackgroundUIOpacityKey];
    [defaults setFloat:self.blurIntensity forKey:kBackgroundBlurIntensityKey];
    [defaults setBool:self.glassRimEnabled forKey:kGlassRimEnabledKey];      // ★ [RIM-UI]
    [defaults setFloat:self.glassRimStrength forKey:kGlassRimStrengthKey];   // ★ [RIM-UI]
    [defaults synchronize];
}

- (void)setUiEffect:(BackgroundUIEffect)uiEffect {
    _uiEffect = uiEffect;
    [self saveUISettings];
}

- (void)setUiOpacity:(CGFloat)uiOpacity {
    _uiOpacity = MAX(0.1, MIN(1.0, uiOpacity));
    [self saveUISettings];
}

- (void)setBlurIntensity:(CGFloat)blurIntensity {
    _blurIntensity = MAX(0.0, MIN(1.0, blurIntensity));
    [self saveUISettings];
}

#pragma mark - ★ [GLASSUI] 玻璃高光 开关 / 强度(设置页接入:夹紧 + 持久化 + 即时生效)
//
// 说明:glassRimEnabled / glassRimStrength 原本只有自动合成的访问器 —— 外部直接赋值既不会
// 写进 NSUserDefaults,也不会写进 UIKit+GlassSurface.h 里的全局强度变量 gAmeGlassRimStrength。
// 这里补显式 setter,复用【既有】键(background_glass_rim_enabled / background_glass_rim_strength,
// 见本文件顶部常量),不新增第二套键/第二套实现:
//   ① 夹紧到合法区间;② saveUISettings 持久化;③ AmeSetGlassRimStrength 写全局强度(关 ⇒ 0);
//   ④ applyGlassRimSettingsNow 立即重刷屏幕上所有已挂高光的载体(即时生效)。
// 载入路径(init 里直写 _glassRimEnabled / _glassRimStrength 两个 ivar)不经过 setter ⇒ 启动不会触发重刷。
- (void)setGlassRimEnabled:(BOOL)glassRimEnabled {
    _glassRimEnabled = glassRimEnabled;
    [self saveUISettings];
    AmeSetGlassRimStrength(_glassRimEnabled ? _glassRimStrength : 0.0);
    [self applyGlassRimSettingsNow];
}

- (void)setGlassRimStrength:(CGFloat)glassRimStrength {
    _glassRimStrength = MAX(0.0, MIN(1.0, glassRimStrength));   // ★ 夹紧:0…1,越界不入
    [self saveUISettings];
    AmeSetGlassRimStrength(_glassRimEnabled ? _glassRimStrength : 0.0);
    [self applyGlassRimSettingsNow];
}

#pragma mark - Global Background Application

- (void)applyBackgroundToWindow:(UIWindow *)window {
    if (!window) {
        [self removeGlobalBackground];
        return;
    }
    
    self.currentWindow = window;
    self.currentSplitVC = nil;
    
    // Remove existing
    [self removeGlobalBackground];

    // For default background, just set the window's background color
    // No need for container
    // 修复：使用 systemBackgroundColor 自适应浅色/深色模式。
    // 之前硬编码深灰（0.08）在浅色模式下导致"中间一片黑"。
    // systemBackgroundColor 在浅色模式为白、深色模式为黑，自动适配。
    // 为避免状态栏区域透出纯黑，使用 systemBackground 而非纯黑。
    if (self.currentType == BackgroundTypeNone) {
        // ★ [E3] SPEC §2.1:未设自定义背景时改用默认渐变(深=紫蓝 / 浅=白→粉紫)。
        //   原值:window.backgroundColor = systemBackgroundColor(深黑/浅白,平面无色)
        //   新值:挂 AmeGradientBackgroundView —— 仅无自定义背景时生效,自定义背景路径不受影响
        [self ame_applyDefaultGradientToHost:window];
        return;
    }
    
    // Create container (for custom backgrounds)
    UIView *container = [[UIView alloc] initWithFrame:window.bounds];
    container.tag = kGlobalBackgroundTag;
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    container.backgroundColor = [UIColor clearColor];
    
    // Insert at index 0 (behind everything)
    [window insertSubview:container atIndex:0];
    self.globalBackgroundContainer = container;
    
    // Apply content
    switch (self.currentType) {
        case BackgroundTypeImage:
            [self applyImageBackgroundToContainer:container];
            break;
        case BackgroundTypeVideo:
            [self applyVideoBackgroundToContainer:container];
            break;
        default:
            break;
    }
}

- (void)applyBackgroundToSplitViewController:(UISplitViewController *)splitVC {
    if (!splitVC || !splitVC.view) {
        [self removeGlobalBackground];
        return;
    }
    
    self.currentSplitVC = splitVC;
    self.currentWindow = nil;
    
    // Remove existing
    [self removeGlobalBackground];
    
    // For default background, just set the view's background color
    // No need for container or transparency
    // 修复：使用 systemBackgroundColor 自适应浅色/深色模式
    if (self.currentType == BackgroundTypeNone) {
        // ★ [E3] SPEC §2.1:默认渐变背景(同 window 路径;原为平面 systemBackgroundColor)
        [self ame_applyDefaultGradientToHost:splitVC.view];
        return;
    }
    
    // Create container that covers entire split view (for custom backgrounds)
    UIView *container = [[UIView alloc] initWithFrame:splitVC.view.bounds];
    container.tag = kGlobalBackgroundTag;
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    container.backgroundColor = [UIColor clearColor];
    
    // Insert at the very bottom
    [splitVC.view insertSubview:container atIndex:0];
    self.globalBackgroundContainer = container;
    
    // Apply content
    switch (self.currentType) {
        case BackgroundTypeImage:
            [self applyImageBackgroundToContainer:container];
            break;
        case BackgroundTypeVideo:
            [self applyVideoBackgroundToContainer:container];
            break;
        default:
            break;
    }
    
    // Make all child controllers transparent (only for custom backgrounds)
    [self makeSplitViewControllerTransparent:splitVC];
}

- (void)removeGlobalBackground {
    // Remove from window
    if (self.currentWindow) {
        UIView *existing = [self.currentWindow viewWithTag:kGlobalBackgroundTag];
        if (existing) [existing removeFromSuperview];
    }
    
    // Remove from split VC
    if (self.currentSplitVC && self.currentSplitVC.view) {
        UIView *existing = [self.currentSplitVC.view viewWithTag:kGlobalBackgroundTag];
        if (existing) [existing removeFromSuperview];
    }
    
    // ★ [E3] 同时移除默认渐变背景 —— 切自定义背景 / 清空背景时必须清掉,否则会盖住后续内容
    if (self.currentWindow) {
        UIView *dg = [self.currentWindow viewWithTag:kDefaultBackgroundTag];
        if (dg) [dg removeFromSuperview];
    }
    if (self.currentSplitVC && self.currentSplitVC.view) {
        UIView *dg = [self.currentSplitVC.view viewWithTag:kDefaultBackgroundTag];
        if (dg) [dg removeFromSuperview];
    }
    // ★ [E3] 兜底:通过弱持有的宿主清理(切背景时 currentWindow/currentSplitVC 可能已被置 nil)
    if (self.ameDefaultGradientHost) {
        UIView *dg = [self.ameDefaultGradientHost viewWithTag:kDefaultBackgroundTag];
        if (dg) [dg removeFromSuperview];
        self.ameDefaultGradientHost = nil;
    }
    
    // Cleanup
    [self cleanupVideoPlayer];
    self.globalBackgroundContainer = nil;
    self.currentWindow = nil;
    self.currentSplitVC = nil;
}

- (void)updateBackgroundFrame {
    if (!self.globalBackgroundContainer) return;
    
    UIView *parent = self.globalBackgroundContainer.superview;
    if (!parent) return;
    
    // Update container frame
    self.globalBackgroundContainer.frame = parent.bounds;
    
    // Update default background view
    UIView *defaultBg = [self.globalBackgroundContainer viewWithTag:kDefaultBackgroundTag];
    if (defaultBg) defaultBg.frame = self.globalBackgroundContainer.bounds;
    
    // Update image view
    UIView *imageView = [self.globalBackgroundContainer viewWithTag:kBackgroundImageTag];
    if (imageView) imageView.frame = self.globalBackgroundContainer.bounds;
    
    // Update blur view
    UIView *blurView = [self.globalBackgroundContainer viewWithTag:kBackgroundBlurTag];
    if (blurView) blurView.frame = self.globalBackgroundContainer.bounds;
    
    // Update dim view
    UIView *dimView = [self.globalBackgroundContainer viewWithTag:kBackgroundDimTag];
    if (dimView) dimView.frame = self.globalBackgroundContainer.bounds;
    
    // Update video layer
    if (self.videoPlayerLayer) self.videoPlayerLayer.frame = self.globalBackgroundContainer.bounds;
}

- (void)handleOrientationChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateBackgroundFrame];
    });
}

#pragma mark - Background Content Application

// ★ [E3] 把默认渐变背景挂到宿主(window / splitVC.view)。仅无自定义背景时调用。
- (void)ame_applyDefaultGradientToHost:(UIView *)host {
    if (!host) return;
    UIView *existing = [host viewWithTag:kDefaultBackgroundTag];
    if (existing) [existing removeFromSuperview];

    AmeGradientBackgroundView *g = [[AmeGradientBackgroundView alloc] initWithFrame:host.bounds];
    g.tag = kDefaultBackgroundTag;
    [host insertSubview:g atIndex:0];
    self.ameDefaultGradientHost = host;   // ★ [E3] 弱持有,便于清理
    // 兜底底色(与渐变基色一致,避免首帧/渐变外露黑)
    host.backgroundColor = AmeDynamicColor(AmeRGBA(0x10, 0x13, 0x22, 1.0),
                                           AmeRGBA(0xEE, 0xF3, 0xFF, 1.0));
}

- (void)applyDefaultBackgroundToContainer:(UIView *)container {
    // Remove existing default background
    UIView *existing = [container viewWithTag:kDefaultBackgroundTag];
    if (existing) [existing removeFromSuperview];

    // ★ [E3] SPEC §2.1:默认背景改为「深=紫蓝 / 浅=白→粉紫」渐变。
    //   原值:平面 systemBackgroundColor(深黑/浅白,与 E 稿不符)
    //   新值:AmeGradientBackgroundView(随 traitCollection 自动切换深浅)
    AmeGradientBackgroundView *defaultBackgroundView =
        [[AmeGradientBackgroundView alloc] initWithFrame:container.bounds];
    defaultBackgroundView.tag = kDefaultBackgroundTag;
    [container addSubview:defaultBackgroundView];
}

- (void)applyImageBackgroundToContainer:(UIView *)container {
    if (!self.currentBackgroundPath) return;
    
    UIImage *image = [UIImage imageWithContentsOfFile:self.currentBackgroundPath];
    if (!image) return;
    
    // Remove existing
    UIView *existing = [container viewWithTag:kBackgroundImageTag];
    if (existing) [existing removeFromSuperview];
    
    // Image view
    UIImageView *imageView = [[UIImageView alloc] initWithImage:image];
    imageView.tag = kBackgroundImageTag;
    imageView.contentMode = UIViewContentModeScaleAspectFill;
    imageView.clipsToBounds = YES;
    imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    imageView.frame = container.bounds;
    
    [container addSubview:imageView];
    
    // Add blur effect for UI readability
    [self addBlurEffectToContainer:container];
}

- (void)applyVideoBackgroundToContainer:(UIView *)container {
    if (!self.currentBackgroundPath) return;
    
    NSURL *videoURL = [NSURL fileURLWithPath:self.currentBackgroundPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.currentBackgroundPath]) return;
    
    [self cleanupVideoPlayer];
    
    // Create player
    self.videoPlayer = [AVPlayer playerWithURL:videoURL];
    self.videoPlayer.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    self.videoPlayer.muted = YES; // Mute to avoid interrupting other audio
    
    // Create player layer
    self.videoPlayerLayer = [AVPlayerLayer playerLayerWithPlayer:self.videoPlayer];
    self.videoPlayerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.videoPlayerLayer.frame = container.bounds;
    
    // Insert at bottom
    [container.layer insertSublayer:self.videoPlayerLayer atIndex:0];
    
    // Add blur effect
    [self addBlurEffectToContainer:container];
    
    // Start playing
    [self.videoPlayer play];
}

- (void)addBlurEffectToContainer:(UIView *)container {
    // Remove existing blur
    UIView *existingBlur = [container viewWithTag:kBackgroundBlurTag];
    if (existingBlur) [existingBlur removeFromSuperview];

    UIView *existingDim = [container viewWithTag:kBackgroundDimTag];
    if (existingDim) [existingDim removeFromSuperview];

    // 修复：使用 SystemThinMaterial（自适应浅色/深色，且较通透）替代硬编码 Dark。
    // 之前使用 UIBlurEffectStyleDark + 黑色 dim view 叠加，导致：
    // 1. 浅色模式下背景图被完全压暗成"中间一片黑"
    // 2. 左右侧栏完全不透明，背景图透不出来
    // SystemThinMaterial 会在浅色模式呈浅色毛玻璃、深色模式呈深色毛玻璃，
    // 且透明度适中，背景图可见。
    UIBlurEffect *blurEffect;
    if (@available(iOS 13.0, *)) {
        blurEffect = AmeGlassEffect(UIBlurEffectStyleSystemThinMaterial);   // ★ 液态玻璃(iOS 26+)/ 旧系统回退
    } else {
        blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
    }
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    blurView.tag = kBackgroundBlurTag;
    blurView.alpha = self.blurIntensity * 0.5; // max 0.5 for readability
    blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blurView.frame = container.bounds;

    [container addSubview:blurView];

    // 修复：dim view 改为自适应颜色而非纯黑，避免浅色模式下过度压暗
    UIView *dimView = [[UIView alloc] initWithFrame:container.bounds];
    dimView.tag = kBackgroundDimTag;
    if (@available(iOS 13.0, *)) {
        dimView.backgroundColor = [UIColor labelColor];
    } else {
        dimView.backgroundColor = [UIColor blackColor];
    }
    dimView.alpha = self.blurIntensity * 0.2; // 降低到 0.2，避免过度压暗
    dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    [container addSubview:dimView];
}

#pragma mark - Transparency Helpers with UI Effect Support

- (void)makeViewControllerTransparent:(UIViewController *)viewController {
    if (!viewController) return;
    
    // Main view - apply effect based on settings
    if (self.uiEffect == BackgroundUIEffectBlur) {
        // 毛玻璃效果 - clear background, let blur show through
        viewController.view.backgroundColor = [UIColor clearColor];
    } else {
        // 半透明效果 - semi-transparent background
        // 修复：使用 systemBackgroundColor 替代硬编码黑色，自适应浅色/深色模式
        if (@available(iOS 13.0, *)) {
            UIColor *base = [UIColor systemBackgroundColor];
            viewController.view.backgroundColor = [base colorWithAlphaComponent:1.0 - self.uiOpacity];
        } else {
            viewController.view.backgroundColor = [UIColor colorWithWhite:0 alpha:1.0 - self.uiOpacity];
        }
    }
    
    // For UITableViewController
    if ([viewController isKindOfClass:[UITableViewController class]]) {
        UITableViewController *tableVC = (UITableViewController *)viewController;
        tableVC.tableView.backgroundColor = [UIColor clearColor];
        tableVC.tableView.backgroundView = nil;
        
        // Make cells semi-transparent or with blur effect
        tableVC.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
        
        // Apply to all visible cells
        for (UITableViewCell *cell in tableVC.tableView.visibleCells) {
            [self applyEffectToCell:cell];
        }
    }
    
    // For UICollectionViewController
    if ([viewController isKindOfClass:[UICollectionViewController class]]) {
        UICollectionViewController *collectionVC = (UICollectionViewController *)viewController;
        collectionVC.collectionView.backgroundColor = [UIColor clearColor];
    }
    
    // Child view controllers
    for (UIViewController *childVC in viewController.childViewControllers) {
        [self makeViewControllerTransparent:childVC];
    }
}

- (void)applyEffectToCell:(UITableViewCell *)cell {
    if (self.uiEffect == BackgroundUIEffectBlur) {
        // 毛玻璃效果 - use UIBlurEffect on cell background
        if (@available(iOS 13.0, *)) {
            UIVisualEffect *blur = AmeGlassEffect(UIBlurEffectStyleSystemMaterial);   // ★ 列表行玻璃
            UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
            blurView.frame = cell.bounds;
            // ★ [E3] SPEC §2:玻璃底 + blur 26 / saturate 180%
            blurView.contentView.backgroundColor = AmeGlassFillColor();
            AmeTuneGlassBackdrop(blurView, AmeGlassBlurRadius, AmeGlassSaturate);
            // ★ [NO-RIM] 列表行不再刷高光(用户反馈:设置页 / 实例子目录不要这个描边)
            //   主界面卡片的 rim 仍在 applyEffectToView: 里保留。
            blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

            // Remove old background views
            for (UIView *subview in cell.contentView.superview.subviews) {
                if ([subview isKindOfClass:[UIVisualEffectView class]] && subview != blurView) {
                    [subview removeFromSuperview];
                }
            }

            // ★ [ROUND-ROW] 选项行改圆角(设置页/实例子目录的选项)
            CGFloat rowRadius = 12.0;
            blurView.layer.cornerRadius = rowRadius;
            blurView.layer.masksToBounds = YES;
            cell.layer.cornerRadius = rowRadius;
            cell.layer.masksToBounds = YES;
            cell.backgroundView = blurView;
        } else {
            cell.backgroundColor = [UIColor colorWithWhite:0.1 alpha:self.uiOpacity];
        }
        cell.contentView.backgroundColor = [UIColor clearColor];
    } else {
        // 半透明效果 - simple semi-transparent background
        // 修复：使用 secondarySystemBackgroundColor 替代硬编码 0.1 黑色
        if (@available(iOS 13.0, *)) {
            cell.backgroundColor = [[UIColor secondarySystemBackgroundColor] colorWithAlphaComponent:self.uiOpacity];
        } else {
            cell.backgroundColor = [UIColor colorWithWhite:0.1 alpha:self.uiOpacity];
        }
        cell.contentView.backgroundColor = [UIColor clearColor];
        cell.backgroundView = nil;
        // ★ [ROUND-ROW] 半透明模式下行也圆角(与毛玻璃模式一致)
        cell.layer.cornerRadius = 12.0;
        cell.layer.masksToBounds = YES;
    }
}

- (void)makeSplitViewControllerTransparent:(UISplitViewController *)splitVC {
    if (!splitVC) return;
    
    // Make split view itself transparent
    splitVC.view.backgroundColor = [UIColor clearColor];
    
    // Make all view controllers transparent
    for (UIViewController *vc in splitVC.viewControllers) {
        if ([vc isKindOfClass:[UINavigationController class]]) {
            UINavigationController *nav = (UINavigationController *)vc;
            
            // Navigation controller setup
            nav.view.backgroundColor = [UIColor clearColor];
            nav.navigationBar.translucent = YES;
            nav.toolbar.translucent = YES;
            
            // Apply effect to navigation bar
            [self applyEffectToNavigationBar:nav.navigationBar];
            [self applyEffectToToolbar:nav.toolbar];
            
            // Make all view controllers in stack transparent
            for (UIViewController *childVC in nav.viewControllers) {
                [self makeViewControllerTransparent:childVC];
            }
        } else {
            [self makeViewControllerTransparent:vc];
        }
    }
}

- (void)applyEffectToNavigationBar:(UINavigationBar *)navigationBar {
    // 关键修复（UI 累积异常 + 小白条根治）：
    // 1. 之前每次调用都重建 UINavigationBarAppearance，iOS 内部会重新生成 hairline
    //    UIImageView，累积后表现为"上方一行小白条"。现改为静态单例 Appearance，
    //    同一种效果只构建一次，避免反复触发 iOS 内部 hairline view 重建。
    // 2. 之前清理 hairline 只遍历 navigationBar.subviews（直接子视图），但 iOS 的
    //    hairline 常嵌在 _UINavigationBarBackground / _UIBarBackground 等私有子视图
    //    内部。改为递归遍历所有后代视图，彻底清理累积的 hairline。
    static UIImage *emptyImage = nil;
    static UINavigationBarAppearance *blurAppearance = nil;
    static UINavigationBarAppearance *translucentAppearance = nil;
    static UIColor *translucentBarColor = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        emptyImage = [UIImage new];
        // 预构建毛玻璃 Appearance（configureWithTransparentBackground + shadowImage 置空）
        blurAppearance = [[UINavigationBarAppearance alloc] init];
        [blurAppearance configureWithTransparentBackground];
        blurAppearance.backgroundColor = [UIColor clearColor];
        blurAppearance.backgroundEffect = AmeGlassEffect(UIBlurEffectStyleSystemMaterial);   // ★ 导航栏玻璃
        blurAppearance.shadowColor = nil;
        blurAppearance.shadowImage = emptyImage;
        // 半透明 Appearance 在首次调用时按当前 uiOpacity 构建（见下方懒加载）
    });

    // 递归清理 iOS 内部累积的 hairline UIImageView（高度极小的分割线视图）
    // hairline 常嵌在 _UINavigationBarBackground / _UIBarBackground 等私有子视图内部
    //
    // 关键修复（Card/Root 布局进入所有页闪退加固）：
    //   block 内引用自身（removeHairlines(sub)）必须用 __block 限定符，否则
    //   捕获的是 nil（block 字面量赋值还未完成时的栈帧值），递归调用是 no-op，
    //   只会处理 navigationBar 的直接子视图，无法清理 _UIBarBackground 内层的 hairline。
    //   累积的 hairline 在 setContentViewController 反复切换时会触发私有子视图
    //   layout 解算异常，导致 EXC_BAD_ACCESS（不被 NSUncaughtExceptionHandler 捕获）。
    __block void (^removeHairlines)(UIView *) = ^(UIView *view) {
        for (UIView *sub in view.subviews) {
            if ([sub isKindOfClass:[UIImageView class]] &&
                sub.bounds.size.height > 0 &&
                sub.bounds.size.height <= 2.0) {
                [sub removeFromSuperview];
            } else {
                removeHairlines(sub);
            }
        }
    };
    removeHairlines(navigationBar);

    if (self.uiEffect == BackgroundUIEffectBlur) {
        // 毛玻璃效果 - 复用静态单例
        if (@available(iOS 13.0, *)) {
            navigationBar.standardAppearance = blurAppearance;
            navigationBar.scrollEdgeAppearance = blurAppearance;
            navigationBar.compactAppearance = blurAppearance;
        }
        navigationBar.barTintColor = [UIColor clearColor];
        navigationBar.backgroundColor = [UIColor clearColor];
        navigationBar.shadowImage = emptyImage;
    } else {
        // 半透明效果
        if (@available(iOS 13.0, *)) {
            UIColor *barColor = [[UIColor secondarySystemBackgroundColor] colorWithAlphaComponent:self.uiOpacity];
            navigationBar.barTintColor = barColor;
            navigationBar.backgroundColor = barColor;
            // 半透明 Appearance 需要按当前 uiOpacity 构建（uiOpacity 可变，无法像 blur 一样全局单例）
            // 但同一 uiOpacity 下复用同一实例，避免反复重建
            if (!translucentAppearance || ![translucentBarColor isEqual:barColor]) {
                UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
                [appearance configureWithTransparentBackground];
                appearance.backgroundColor = barColor;
                appearance.backgroundEffect = nil;
                appearance.shadowColor = nil;
                appearance.shadowImage = emptyImage;
                translucentAppearance = appearance;
                translucentBarColor = barColor;
            }
            navigationBar.standardAppearance = translucentAppearance;
            navigationBar.scrollEdgeAppearance = translucentAppearance;
            navigationBar.compactAppearance = translucentAppearance;
        } else {
            navigationBar.barTintColor = [UIColor colorWithWhite:0.1 alpha:self.uiOpacity];
            navigationBar.backgroundColor = [UIColor colorWithWhite:0.1 alpha:self.uiOpacity];
        }
        navigationBar.shadowImage = emptyImage;
    }
}

- (void)applyEffectToToolbar:(UIToolbar *)toolbar {
    // 关键修复（同 applyEffectToNavigationBar:）：静态单例 Appearance + 递归清理 hairline
    static UIImage *emptyImage = nil;
    static UIToolbarAppearance *blurToolbarAppearance = nil;
    static UIToolbarAppearance *translucentToolbarAppearance = nil;
    static UIColor *translucentToolbarColor = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        emptyImage = [UIImage new];
        blurToolbarAppearance = [[UIToolbarAppearance alloc] init];
        [blurToolbarAppearance configureWithTransparentBackground];
        blurToolbarAppearance.backgroundColor = [UIColor clearColor];
        blurToolbarAppearance.backgroundEffect = AmeGlassEffect(UIBlurEffectStyleSystemMaterial);   // ★ 工具栏玻璃
        blurToolbarAppearance.shadowColor = nil;
        blurToolbarAppearance.shadowImage = emptyImage;
    });

    // 递归清理累积的 hairline UIImageView
    // 关键修复：同 applyEffectToNavigationBar:，block 内引用自身必须用 __block
    // 限定符，否则递归调用是 no-op，无法清理 _UIBarBackground 内层的 hairline。
    __block void (^removeHairlines)(UIView *) = ^(UIView *view) {
        for (UIView *sub in view.subviews) {
            if ([sub isKindOfClass:[UIImageView class]] &&
                sub.bounds.size.height > 0 &&
                sub.bounds.size.height <= 2.0) {
                [sub removeFromSuperview];
            } else {
                removeHairlines(sub);
            }
        }
    };
    removeHairlines(toolbar);

    if (self.uiEffect == BackgroundUIEffectBlur) {
        // 毛玻璃效果 - 复用静态单例
        if (@available(iOS 13.0, *)) {
            toolbar.standardAppearance = blurToolbarAppearance;
            toolbar.scrollEdgeAppearance = blurToolbarAppearance;
            toolbar.compactAppearance = blurToolbarAppearance;
        }
        toolbar.barTintColor = [UIColor clearColor];
        toolbar.backgroundColor = [UIColor clearColor];
    } else {
        // 半透明效果
        if (@available(iOS 13.0, *)) {
            UIColor *barColor = [[UIColor secondarySystemBackgroundColor] colorWithAlphaComponent:self.uiOpacity];
            toolbar.barTintColor = barColor;
            toolbar.backgroundColor = barColor;
            if (!translucentToolbarAppearance || ![translucentToolbarColor isEqual:barColor]) {
                UIToolbarAppearance *appearance = [[UIToolbarAppearance alloc] init];
                [appearance configureWithTransparentBackground];
                appearance.backgroundColor = barColor;
                appearance.backgroundEffect = nil;
                appearance.shadowColor = nil;
                appearance.shadowImage = emptyImage;
                translucentToolbarAppearance = appearance;
                translucentToolbarColor = barColor;
            }
            toolbar.standardAppearance = translucentToolbarAppearance;
            toolbar.scrollEdgeAppearance = translucentToolbarAppearance;
            toolbar.compactAppearance = translucentToolbarAppearance;
        } else {
            toolbar.barTintColor = [UIColor colorWithWhite:0.1 alpha:self.uiOpacity];
            toolbar.backgroundColor = [UIColor colorWithWhite:0.1 alpha:self.uiOpacity];
        }
    }
}

- (void)refreshUIEffect {
    if (self.currentSplitVC && self.currentType != BackgroundTypeNone) {
        [self makeSplitViewControllerTransparent:self.currentSplitVC];
    }
    
    // Re-apply blur intensity to background container
    if (self.globalBackgroundContainer) {
        [self addBlurEffectToContainer:self.globalBackgroundContainer];
    }
    
    // Post notification for other views to refresh
    [[NSNotificationCenter defaultCenter] postNotificationName:@"BackgroundUIEffectChanged" object:nil];
}

#pragma mark - Unified View Effect Application

- (void)applyEffectToView:(UIView *)view {
    if (!view) return;

    if (self.uiEffect == BackgroundUIEffectBlur) {
        NSLog(@"[glass] applyEffectToView: BLUR path on %@ (blur=%.1f sat=%.2f intensity=%.2f hasBg=%d)",
              NSStringFromClass(view.class), (double)AmeGlassBlurRadius, (double)AmeGlassSaturate,
              (double)self.blurIntensity, (int)[self hasBackground]);
        // 毛玻璃效果 - 创建 UIVisualEffectView 作为子视图
        // 先移除已有的 blur view
        for (UIView *subview in view.subviews) {
            if ([subview isKindOfClass:[UIVisualEffectView class]] && subview.tag == kBackgroundBlurTag) {
                [subview removeFromSuperview];
            }
        }

        // 修复：使用 SystemThinMaterial 替代 SystemMaterialDark，使左右侧栏
        // 在浅色/深色模式下都自适应，且足够通透让背景图透出。
        // SystemMaterialDark 过于不透明，导致"左右两边完全不透明"。
        // ★ 真玻璃可用就用真玻璃(iOS 26 设备),否则系统材质 + 下面加的高光边
        UIVisualEffect *blur = AmeGlassEffect(UIBlurEffectStyleSystemThinMaterial);
        UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        blurView.tag = kBackgroundBlurTag;
        blurView.frame = view.bounds;
        blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        blurView.layer.cornerRadius = view.layer.cornerRadius;
        blurView.layer.masksToBounds = YES;

        // 参照 ZL2 双层透明度控制：
        // 1. blurIntensity 控制毛玻璃本身的模糊强度（0.3~1.0 范围，避免过低完全透明）
        // 2. 有自定义背景时降低不透明度让背景透出，无背景时保持较高不透明度
        // 这样实现了 ZL2 的 influencedByBackgroundColor 效果：
        // 有背景图/视频时卡片更通透，无背景时卡片更不透明（与系统默认一致）
        CGFloat effectiveAlpha = 0.3 + (self.blurIntensity * 0.7);  // 0.3~1.0
        if (![self hasBackground]) {
            // 无自定义背景时，提高不透明度，使 UI 更清晰
            effectiveAlpha = MIN(effectiveAlpha + 0.2, 1.0);
        }
        blurView.alpha = effectiveAlpha;

        // 毛玻璃本身不响应触摸，让事件穿透到宿主视图（如 UIControl 卡片）。
        // 否则 blurView 会拦截 touch，导致 AccountLoginViewController 的登录卡片
        // 点击无反应（UIControlEventTouchUpInside 永远不触发）。
        blurView.userInteractionEnabled = NO;

        [view insertSubview:blurView atIndex:0];
        view.backgroundColor = [UIColor clearColor];
        // ★ [E3] SPEC §2 设计令牌:玻璃底填充(glass 深.10/浅.55)+ blur 26 / saturate 180%
        blurView.contentView.backgroundColor = AmeGlassFillColor();
        AmeTuneGlassBackdrop(blurView, AmeGlassBlurRadius, AmeGlassSaturate);
        // ★ 玻璃质感:高光描边 + 上缘内高光(不依赖 iOS 26 SDK)
        // ★ [RIM-UI] 按用户开关/强度刷高光;先摘旧图层,再按新强度重刷
        AmeSetGlassRimStrength(self.glassRimEnabled ? self.glassRimStrength : 0.0);
        AmeDetachGlassRim(view);
        AmeAttachGlassRim(view, view.layer.cornerRadius);
        // ★ [UI-B] 修复(2026-10-02):AmeRefreshGlassRim 全工程原本 0 个调用者
        //   ⇒ 高光 CAGradientLayer 的 frame 恒为 (0,0,0,0) ⇒ 上缘高光从来没画出来过。
        dispatch_async(dispatch_get_main_queue(), ^{
            AmeRefreshGlassRim(view);
            [self ameRefreshRimsRecursive:view];
        });
    } else {
        NSLog(@"[glass] applyEffectToView: TRANSLUCENT path on %@ (uiEffect=%ld)",
              NSStringFromClass(view.class), (long)self.uiEffect);
        // 半透明效果 - 移除 blur view，使用半透明背景
        // 修复：使用 systemBackgroundColor 替代硬编码深灰，自适应浅色/深色模式
        for (UIView *subview in view.subviews) {
            if ([subview isKindOfClass:[UIVisualEffectView class]] && subview.tag == kBackgroundBlurTag) {
                [subview removeFromSuperview];
            }
        }
        if (@available(iOS 13.0, *)) {
            // 使用 secondarySystemBackgroundColor 作为半透明基底，再叠加 alpha
            // 参照 ZL2 双层透明度控制：有背景时降低不透明度让背景透出
            CGFloat effectiveOpacity = self.uiOpacity;
            if (![self hasBackground]) {
                // 无自定义背景时，提高不透明度，使 UI 更清晰
                effectiveOpacity = MIN(effectiveOpacity + 0.3, 1.0);
            }
            UIColor *base = [UIColor secondarySystemBackgroundColor];
            view.backgroundColor = [base colorWithAlphaComponent:effectiveOpacity];
        } else {
            view.backgroundColor = [UIColor colorWithWhite:0.08 alpha:self.uiOpacity];
        }
    }
}

- (void)applyEffectToCollectionViewCell:(UICollectionViewCell *)cell {
    if (!cell) return;
    if (self.uiEffect == BackgroundUIEffectBlur) {
        // 毛玻璃效果
        for (UIView *subview in cell.contentView.subviews) {
            if ([subview isKindOfClass:[UIVisualEffectView class]] && subview.tag == kBackgroundBlurTag) {
                [subview removeFromSuperview];
            }
        }

        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
        UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        blurView.tag = kBackgroundBlurTag;
        blurView.frame = cell.contentView.bounds;
        blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        blurView.layer.cornerRadius = cell.contentView.layer.cornerRadius;
        blurView.layer.masksToBounds = YES;
        // ★ [E3] SPEC §2.5:blur 26 / saturate 180%(尽力落到系统材质,失败回退默认并打日志)
        AmeTuneGlassBackdrop(blurView, AmeGlassBlurRadius, AmeGlassSaturate);

        [cell.contentView insertSubview:blurView atIndex:0];
        cell.backgroundColor = [UIColor clearColor];
        cell.contentView.backgroundColor = [UIColor clearColor];
    } else {
        // 半透明效果
        for (UIView *subview in cell.contentView.subviews) {
            if ([subview isKindOfClass:[UIVisualEffectView class]] && subview.tag == kBackgroundBlurTag) {
                [subview removeFromSuperview];
            }
        }
        // 修复：使用 secondarySystemBackgroundColor 替代硬编码 0.1 黑色
        if (@available(iOS 13.0, *)) {
            cell.backgroundColor = [[UIColor secondarySystemBackgroundColor] colorWithAlphaComponent:self.uiOpacity];
        } else {
            cell.backgroundColor = [UIColor colorWithWhite:0.1 alpha:self.uiOpacity];
        }
        cell.contentView.backgroundColor = [UIColor clearColor];
    }
}

- (void)applyEffectToSearchBar:(UISearchBar *)searchBar {
    if (!searchBar) return;

    // 1. searchBar 整体背景透明，让底层自定义启动器背景透出
    //    UISearchBar 默认是不透明的 systemBackgroundColor，会遮挡全局背景图/毛玻璃
    searchBar.barTintColor = [UIColor clearColor];
    searchBar.backgroundColor = [UIColor clearColor];
    searchBar.translucent = YES;
    // Minimal 样式让系统不绘制不透明背景，仅保留输入框背景
    searchBar.searchBarStyle = UISearchBarStyleMinimal;
    // 移除系统自动添加的 _UISearchBarBackground 不透明背景视图
    for (UIView *sub in searchBar.subviews) {
        for (UIView *inner in sub.subviews) {
            if ([NSStringFromClass(inner.class) containsString:@"Background"]) {
                inner.backgroundColor = [UIColor clearColor];
                inner.hidden = NO;
            }
        }
        if ([NSStringFromClass(sub.class) containsString:@"Background"]) {
            sub.backgroundColor = [UIColor clearColor];
        }
    }

    // 2. 透明化内部 UITextField（搜索输入框）背景
    //    UITextField 默认带 systemFillColor 浅灰色背景，遮挡自定义背景
    UITextField *textField = nil;
    for (UIView *sub in searchBar.subviews) {
        for (UIView *inner in sub.subviews) {
            if ([inner isKindOfClass:[UITextField class]]) {
                textField = (UITextField *)inner;
                break;
            }
        }
        if (textField) break;
    }
    // iOS 13+ 可直接用 -searchTextField
    if (!textField && [searchBar respondsToSelector:@selector(searchTextField)]) {
        @try {
            textField = [searchBar performSelector:@selector(searchTextField)];
        } @catch (NSException *e) {
            textField = nil;
        }
    }
    if (textField) {
        if (self.uiEffect == BackgroundUIEffectBlur) {
            // 毛玻璃：输入框背景设为浅色半透明，保证文字可读且不挡背景
            if (@available(iOS 13.0, *)) {
                textField.backgroundColor = [[UIColor secondarySystemBackgroundColor] colorWithAlphaComponent:0.5];
            } else {
                textField.backgroundColor = [UIColor colorWithWhite:0.95 alpha:0.5];
            }
        } else {
            // 半透明效果：输入框背景按 uiOpacity 调整
            if (@available(iOS 13.0, *)) {
                textField.backgroundColor = [[UIColor secondarySystemBackgroundColor] colorWithAlphaComponent:MAX(0.3, self.uiOpacity)];
            } else {
                textField.backgroundColor = [UIColor colorWithWhite:0.95 alpha:MAX(0.3, self.uiOpacity)];
            }
        }
    }
}

#pragma mark - Legacy Methods

- (void)applyBackgroundToView:(UIView *)view {
    // Find the view controller or window
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:[UISplitViewController class]]) {
            [self applyBackgroundToSplitViewController:(UISplitViewController *)responder];
            return;
        }
        if ([responder isKindOfClass:[UIWindow class]]) {
            [self applyBackgroundToWindow:(UIWindow *)responder];
            return;
        }
        responder = responder.nextResponder;
    }
}

- (void)removeBackgroundFromView:(UIView *)view {
    [self removeGlobalBackground];
}

#pragma mark - Video Management

- (void)cleanupVideoPlayer {
    if (self.videoPlayer) {
        [self.videoPlayer pause];
        self.videoPlayer = nil;
    }
    if (self.videoPlayerLayer) {
        [self.videoPlayerLayer removeFromSuperlayer];
        self.videoPlayerLayer = nil;
    }
}

- (void)playerItemDidReachEnd:(NSNotification *)notification {
    AVPlayerItem *playerItem = notification.object;
    [playerItem seekToTime:kCMTimeZero completionHandler:nil];
}

#pragma mark - App Lifecycle

- (void)appDidEnterBackground {
    [self pauseVideo];
}

- (void)appWillEnterForeground {
    [self resumeVideo];
}

- (void)pauseVideo {
    if (self.videoPlayer) [self.videoPlayer pause];
}

- (void)resumeVideo {
    if (self.videoPlayer && self.currentType == BackgroundTypeVideo) {
        [self.videoPlayer play];
    }
}

#pragma mark - Set Background

- (void)setImageBackground:(UIImage *)image completion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    if (!image) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:@"BackgroundManager" code:1 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_48", nil)}]);
        }
        return;
    }
    
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Clear existing
        [self clearBackgroundInternal];
        
        // Save image
        NSString *fileName = [NSString stringWithFormat:@"background_image_%ld.jpg", (long)[[NSDate date] timeIntervalSince1970]];
        NSString *filePath = [[self backgroundsFolderPath] stringByAppendingPathComponent:fileName];
        
        NSData *imageData = UIImageJPEGRepresentation(image, 0.85);
        if (!imageData) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, [NSError errorWithDomain:@"BackgroundManager" code:2 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_49", nil)}]);
            });
            return;
        }
        
        BOOL saved = [imageData writeToFile:filePath atomically:YES];
        
        if (saved) {
            self.currentType = BackgroundTypeImage;
            self.currentBackgroundPath = filePath;
            [self saveBackgroundSettings];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                // Reapply if needed
                if (self.currentSplitVC) {
                    [self applyBackgroundToSplitViewController:self.currentSplitVC];
                } else if (self.currentWindow) {
                    [self applyBackgroundToWindow:self.currentWindow];
                }
                
                if (completion) completion(YES, nil);
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, [NSError errorWithDomain:@"BackgroundManager" code:3 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_50", nil)}]);
            });
        }
    });
}

- (void)setVideoBackgroundWithURL:(NSURL *)videoURL completion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    if (!videoURL || ![[NSFileManager defaultManager] fileExistsAtPath:videoURL.path]) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:@"BackgroundManager" code:4 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_51", nil)}]);
        }
        return;
    }
    
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Clear existing
        [self clearBackgroundInternal];
        
        // Copy video
        NSString *fileName = [NSString stringWithFormat:@"background_video_%ld.mp4", (long)[[NSDate date] timeIntervalSince1970]];
        NSString *filePath = [[self backgroundsFolderPath] stringByAppendingPathComponent:fileName];
        
        NSError *copyError = nil;
        BOOL copied = [[NSFileManager defaultManager] copyItemAtURL:videoURL toURL:[NSURL fileURLWithPath:filePath] error:&copyError];
        
        if (copied) {
            self.currentType = BackgroundTypeVideo;
            self.currentBackgroundPath = filePath;
            [self saveBackgroundSettings];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                // Reapply if needed
                if (self.currentSplitVC) {
                    [self applyBackgroundToSplitViewController:self.currentSplitVC];
                } else if (self.currentWindow) {
                    [self applyBackgroundToWindow:self.currentWindow];
                }
                
                if (completion) completion(YES, nil);
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, copyError ?: [NSError errorWithDomain:@"BackgroundManager" code:5 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_52", nil)}]);
            });
        }
    });
}

- (void)clearBackground {
    [self clearBackgroundInternal];
    [self removeGlobalBackground];
    [self saveBackgroundSettings];
}

- (void)clearBackgroundInternal {
    [self cleanupVideoPlayer];
    
    if (self.currentBackgroundPath) {
        [[NSFileManager defaultManager] removeItemAtPath:self.currentBackgroundPath error:nil];
    }
    
    self.currentType = BackgroundTypeNone;
    self.currentBackgroundPath = nil;
}

#pragma mark - Check Background

- (BOOL)hasBackground {
    return self.currentType != BackgroundTypeNone && self.currentBackgroundPath != nil;
}

- (BOOL)hasImageBackground {
    return self.currentType == BackgroundTypeImage && self.currentBackgroundPath != nil;
}

- (BOOL)hasVideoBackground {
    return self.currentType == BackgroundTypeVideo && self.currentBackgroundPath != nil;
}

#pragma mark - Preview

- (nullable UIImage *)backgroundPreview {
    if (self.currentType == BackgroundTypeImage && self.currentBackgroundPath) {
        return [UIImage imageWithContentsOfFile:self.currentBackgroundPath];
    }
    return nil;
}


// ★ [UI-B] 递归重刷玻璃高光(frame 不随 autoresize 变化,必须在布局后重设)
- (void)ameRefreshRimsRecursive:(UIView *)v {
    if (!v) return;
    AmeRefreshGlassRim(v);
    for (UIView *sub in v.subviews) { [self ameRefreshRimsRecursive:sub]; }
}

#pragma mark - ★ [GLASSUI] 玻璃高光设置即时生效

// 遍历视图树:只对「已经挂了高光图层(tag 'MRIM')」的载体做摘除 + 按当前开关/强度重建。
// 关 ⇒ AmeDetachGlassRim 摘掉;开 ⇒ AmeAttachGlassRim 按新强度重建(内部先查强度,0 也不刷)。
// 主路径(applyEffectToView:)与其它文件自挂的高光都会在这里被按新强度重建。
- (void)ameApplyGlassRimSettingsToViewTree:(UIView *)root {
    if (root == nil) { return; }
    static const NSInteger kAmeGlassRimTag = 0x4D52494D;   // 'MRIM',与 UIKit+GlassSurface.h 一致
    BOOL hasRim = NO;
    for (UIView *sub in root.subviews) {
        if (sub.tag == kAmeGlassRimTag) { hasRim = YES; break; }
    }
    if (hasRim) {
        AmeSetGlassRimStrength(self.glassRimEnabled ? self.glassRimStrength : 0.0);
        AmeDetachGlassRim(root);                                // ★ 摘除(禁用函数)
        if (self.glassRimEnabled && self.glassRimStrength > 0.001) {
            AmeAttachGlassRim(root, root.layer.cornerRadius);   // ★ 恢复/按新强度重建
        }
        AmeRefreshGlassRim(root);
    }
    for (UIView *sub in [root.subviews copy]) {
        [self ameApplyGlassRimSettingsToViewTree:sub];
    }
}

// 立即把当前开关/强度刷到所有窗口上(合并同一 runloop 的重复调用),并广播通知让各页重新应用。
- (void)applyGlassRimSettingsNow {
    AmeSetGlassRimStrength(self.glassRimEnabled ? self.glassRimStrength : 0.0);
    if (gAmeGlassRimApplyScheduled) { return; }   // ★ 本 runloop 已排队 ⇒ 合并,不重复遍历
    gAmeGlassRimApplyScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        gAmeGlassRimApplyScheduled = NO;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            [self ameApplyGlassRimSettingsToViewTree:w];
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:@"BackgroundUIEffectChanged" object:nil];
    });
}
@end