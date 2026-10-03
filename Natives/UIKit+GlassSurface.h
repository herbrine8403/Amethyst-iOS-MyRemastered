//
//  UIKit+GlassSurface.h —— 液态玻璃外观助手(纯头文件,不新增 .m ⇒ 不改 CMake 源列表)
//
//  ★ CI 用 Xcode 15.4(iOS 17 SDK)⇒ UIGlassEffect(iOS 26)在 SDK 里无声明,
//    所以这里【不用编译期符号】,走 NSClassFromString + objc_msgSend 的运行时调用。
//  ★ 带探针:每次第一次解析材质时打一行日志,明确告知"玻璃生效"还是"回退常规材质",
//    免得再靠肉眼猜。日志 tag:[glass]
//
//  ★ [E3|2026-10-02] 落地 SPEC §2 设计令牌:颜色 / 圆角 / 玻璃四要素。
//    令牌来源:D:\hermes workplace\amethyst-air\_uiwork\D\SPEC.md §2.1 / §2.2 / §2.5。
//    改动逐处标注「原值 → 新值」。仅动参数,不动结构/布局。
//
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 设计令牌 · 玻璃参数(SPEC §2.5 ★核心)

/// 标准玻璃(卡片 .glass):blur(26px) + saturate(180%)
static const CGFloat AmeGlassBlurRadius          = 26.0;  // SPEC §2.5 .glass
static const CGFloat AmeGlassSaturate            = 1.80;  // SPEC §2.5 saturate(180%)
/// 强玻璃(面板/栏 .glass2):blur(30px) + saturate(200%)
static const CGFloat AmeGlassStrongBlurRadius    = 30.0;  // SPEC §2.5 .glass2
static const CGFloat AmeGlassStrongSaturate      = 2.00;  // SPEC §2.5 saturate(200%)
/// 高光描边宽度:1px(SPEC §2.5 "border 1px solid var(--rim)")
static const CGFloat AmeGlassBorderWidth         = 1.0;
/// 外阴影:0 8px 24px shade(SPEC §2.5 标准玻璃)
static const CGFloat AmeGlassShadowOffsetY       = 8.0;
static const CGFloat AmeGlassShadowRadius        = 24.0;
/// 外阴影:0 10px 30px shade(SPEC §2.5 .glass2 强玻璃)
static const CGFloat AmeGlassStrongShadowOffsetY = 10.0;
static const CGFloat AmeGlassStrongShadowRadius  = 30.0;

#pragma mark - 设计令牌 · 圆角(SPEC §2.2)

typedef NS_ENUM(NSInteger, AmeGlassRadius) {
    AmeGlassRadiusSmall = 13,   // 图标块 40(SPEC §2.2)
    AmeGlassRadiusRow   = 16,   // ★[E3] 新增:普通实例卡 / 列表行玻璃卡 / 弹出菜单(SPEC §2.2)
    AmeGlassRadiusCard  = 22,   // 大卡 / 面板卡 glass(SPEC §2.2)
    AmeGlassRadiusPanel = 26,   // 面板卡 glass2 / 竖屏底部标签栏(SPEC §2.2)
};

/// 控件圆角:按钮 / 胶囊 / 分段 / 输入框 / 开关 一律 100(SPEC §2.2)
static const CGFloat AmeRadiusPill = 100.0;

#pragma mark - 设计令牌 · 颜色(SPEC §2.1)

/// 便捷:0-255 RGB + alpha
static inline UIColor *AmeRGBA(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a];
}

/// 深浅色动态色工厂(SPEC §2.1:深/浅两套变量表)
static inline UIColor *AmeDynamicColor(UIColor *dark, UIColor *light) {
    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
            return (tc.userInterfaceStyle == UIUserInterfaceStyleDark) ? dark : light;
        }];
    }
    return light;
}

/// ★ 强调色(统一系统蓝):深 #0A84FF / 浅 #007AFF(SPEC §2.1 accent)
///   供各处导航选中态 / 主按钮 / 圆形启动键 / 开关旋钮引用。
static inline UIColor *AmeAccentColor(void) {
    return AmeDynamicColor(AmeRGBA(0x0A, 0x84, 0xFF, 1.0),
                           AmeRGBA(0x00, 0x7A, 0xFF, 1.0));
}

/// 主文字 fg:深 #FFFFFF / 浅 #0B0B0C(SPEC §2.1)
static inline UIColor *AmeTextPrimaryColor(void) {
    return AmeDynamicColor([UIColor whiteColor], AmeRGBA(0x0B, 0x0B, 0x0C, 1.0));
}
/// 次要文字 dim:深 rgba(255,255,255,.58) / 浅 rgba(0,0,0,.55)(SPEC §2.1)
static inline UIColor *AmeTextSecondaryColor(void) {
    return AmeDynamicColor([[UIColor whiteColor] colorWithAlphaComponent:0.58],
                           [[UIColor blackColor] colorWithAlphaComponent:0.55]);
}
/// 成功 / 已启用:#34C759(深浅同,SPEC §2.1)
static inline UIColor *AmeSuccessColor(void) {
    return AmeRGBA(0x34, 0xC7, 0x59, 1.0);
}

/// glass 普通卡底:深 rgba(255,255,255,.10) / 浅 rgba(255,255,255,.55)(SPEC §2.1)
static inline UIColor *AmeGlassFillColor(void) {
    return AmeDynamicColor([[UIColor whiteColor] colorWithAlphaComponent:0.10],
                           [[UIColor whiteColor] colorWithAlphaComponent:0.55]);
}
/// glass2 强卡/栏底:深 .16 / 浅 .68(SPEC §2.1)
static inline UIColor *AmeGlassStrongFillColor(void) {
    return AmeDynamicColor([[UIColor whiteColor] colorWithAlphaComponent:0.16],
                           [[UIColor whiteColor] colorWithAlphaComponent:0.68]);
}
/// rim 高光描边:深 rgba(255,255,255,.28) / 浅 rgba(255,255,255,.85)(SPEC §2.1 + §2.5)
static inline UIColor *AmeGlassRimColor(void) {
    return AmeDynamicColor([[UIColor whiteColor] colorWithAlphaComponent:0.28],
                           [[UIColor whiteColor] colorWithAlphaComponent:0.85]);
}
/// shade 外阴影:深 rgba(0,0,0,.35) / 浅 rgba(0,0,0,.06)(SPEC §2.1)
static inline UIColor *AmeGlassShadeColor(void) {
    return AmeDynamicColor([[UIColor blackColor] colorWithAlphaComponent:0.35],
                           [[UIColor blackColor] colorWithAlphaComponent:0.06]);
}
/// 内高光(顶):rgba(255,255,255,.45)(SPEC §2.5,标准玻璃)
static inline UIColor *AmeGlassInnerHighlightColor(void) {
    return [[UIColor whiteColor] colorWithAlphaComponent:0.45];
}
/// 内高光(顶,强):rgba(255,255,255,.55)(SPEC §2.5,.glass2)
static inline UIColor *AmeGlassStrongInnerHighlightColor(void) {
    return [[UIColor whiteColor] colorWithAlphaComponent:0.55];
}
/// 面板底(横屏卡):深 rgba(28,28,30,.55) / 浅 rgba(255,255,255,.68)(SPEC §2.1 panel)
static inline UIColor *AmePanelColor(void) {
    return AmeDynamicColor(AmeRGBA(28, 28, 30, 0.55), AmeRGBA(255, 255, 255, 0.68));
}
/// 分隔线:深 rgba(84,84,88,.45) / 浅 rgba(60,60,67,.16)(SPEC §2.1 separator)
static inline UIColor *AmeSeparatorColor(void) {
    return AmeDynamicColor(AmeRGBA(84, 84, 88, 0.45), AmeRGBA(60, 60, 67, 0.16));
}
/// 左栏材质:深 rgba(18,18,20,.55) / 浅 rgba(242,242,247,.6)(SPEC §2.1 side)
static inline UIColor *AmeSideColor(void) {
    return AmeDynamicColor(AmeRGBA(18, 18, 20, 0.55), AmeRGBA(242, 242, 247, 0.6));
}
/// 分段 / 标签底:深 rgba(118,118,128,.28) / 浅 rgba(118,118,128,.12)(SPEC §2.1 seg)
static inline UIColor *AmeSegColor(void) {
    return AmeDynamicColor(AmeRGBA(118, 118, 128, 0.28), AmeRGBA(118, 118, 128, 0.12));
}

#pragma mark - 玻璃四要素 · 描边 / 内高光 / 外阴影

/// 外阴影(SPEC §2.5:0 8px 24px shade;强玻璃 0 10px 30px)。
/// 注意:阴影需要溢出宿主边界 ⇒ 宿主 layer.masksToBounds 必须为 NO(见 AmeAttachGlassRim)。
static inline void AmeApplyGlassShadow(UIView *host, CGFloat radius, BOOL strong) {
    if (host == nil) { return; }
    host.layer.shadowColor   = (AmeGlassShadeColor()).CGColor;
    host.layer.shadowOpacity = 1.0;
    host.layer.shadowOffset  = CGSizeMake(0.0, strong ? AmeGlassStrongShadowOffsetY : AmeGlassShadowOffsetY);
    host.layer.shadowRadius  = strong ? AmeGlassStrongShadowRadius : AmeGlassShadowRadius;
    // bounds 为空时不设 shadowPath(留 nil 让 CA 自行按内容计算),避免零尺寸路径把阴影"打死"
    if (!CGRectIsEmpty(host.bounds)) {
        host.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:host.bounds
                                                          cornerRadius:radius].CGPath;
    }
}

/// ★ [RIM-UI] 高光强度(0…1;由 BackgroundManager 按用户设置写入,1.0 = SPEC 原值)。
///   0 ⇒ 完全不刷(用户:"要不就别亮");>0 ⇒ 描边与内高光按比例缩放。
static CGFloat gAmeGlassRimStrength = 1.0;
static inline void AmeSetGlassRimStrength(CGFloat s) { gAmeGlassRimStrength = MAX(0.0, MIN(1.0, s)); }
static inline CGFloat AmeGlassRimStrengthValue(void) { return gAmeGlassRimStrength; }

/// 摘掉已存在的高光(改强度后要重刷,否则旧图层还挂着)
static inline void AmeDetachGlassRim(UIView *host) {
    if (host == nil) return;
    static const NSInteger kAmeRimTag2 = 0x4D52494D;
    for (UIView *sub in [host.subviews copy]) { if (sub.tag == kAmeRimTag2) [sub removeFromSuperview]; }
    host.layer.borderWidth = 0;
    host.layer.shadowOpacity = 0;
}

/// ★ 玻璃质感(不依赖 iOS 26 SDK):给载体加「1px 高光描边 + 上/下缘内高光 + 外阴影」。
/// 为什么要它:真系统液态玻璃需要 iOS 26 SDK 构建(CI 现已换到 Xcode 26.3/iOS 26.2 SDK,
/// 那时系统会自动接管;此外这里作叠层仍然成立)。旧 SDK 下它是主要观感来源。
/// 幂等:用一个 tag 去重,重复调用不会叠加。
static inline void AmeAttachGlassRim(UIView *host, CGFloat radius) {
    if (host == nil) return;
    CGFloat ameStrength = AmeGlassRimStrengthValue();
    if (ameStrength <= 0.001) { AmeDetachGlassRim(host); return; }   // ★ 强度 0 ⇒ 一条都不刷
    static const NSInteger kAmeRimTag = 0x4D52494D;   // 'MRIM'
    for (UIView *sub in host.subviews) {
        if (sub.tag == kAmeRimTag) { return; }        // 已加过 ⇒ 幂等
    }
    host.layer.cornerRadius = radius;
    host.layer.cornerCurve = kCACornerCurveContinuous;
    // 原值:masksToBounds = YES(外阴影被裁掉 ⇒ 观感"没落地")
    // 新值:masksToBounds = NO —— SPEC §2.5 要求外阴影 0 8px 24px 溢出宿主边界;
    //       圆角裁剪改由 blur 子视图 / shine 子视图各自 masksToBounds 保证。
    host.layer.masksToBounds = NO;

    // 玻璃描边:深浅色都给亮边(SPEC §2.1 深 .28 / 浅 .85)
    UIColor *rim = AmeGlassRimColor();   // 原:深 0.22 / 浅 0.75 → 新:深 0.28 / 浅 0.85
    rim = [rim colorWithAlphaComponent:CGColorGetAlpha(rim.CGColor) * ameStrength];   // ★ [RIM-UI] 按强度缩放
    host.layer.borderWidth = AmeGlassBorderWidth;   // 原:1.0/screen.scale(≈0.33pt) → 新:1.0pt(SPEC 1px)
    host.layer.borderColor = rim.CGColor;

    // 外阴影 0 8px 24px(原:无 → 新:有)
    AmeApplyGlassShadow(host, radius, NO);

    // 上缘内高光 + 下缘微高光:inset 0 1px 0 rgba(255,255,255,.45) + inset 0 -1px 0 rgba(255,255,255,.10)
    // 原渐变: [.20, .05, clear] @ [0, .28, .62] → 新: [.45, clear, .10] @ [0, .50, 1.0]
    UIView *shine = [[UIView alloc] initWithFrame:CGRectZero];
    shine.tag = kAmeRimTag;
    shine.userInteractionEnabled = NO;
    shine.translatesAutoresizingMaskIntoConstraints = NO;
    shine.backgroundColor = [UIColor clearColor];
    CAGradientLayer *g = [CAGradientLayer layer];
    UIColor *ameTopHl = AmeGlassInnerHighlightColor();
    ameTopHl = [ameTopHl colorWithAlphaComponent:CGColorGetAlpha(ameTopHl.CGColor) * ameStrength];  // ★ [RIM-UI]
    g.colors = @[(id)ameTopHl.CGColor,      // 顶 .45(SPEC)
                 (id)[UIColor clearColor].CGColor,
                 (id)[UIColor colorWithWhite:1.0 alpha:0.10 * ameStrength].CGColor]; // 底 .10(SPEC)
    g.locations = @[@0.0, @0.50, @1.0];
    g.startPoint = CGPointMake(0.5, 0.0);
    g.endPoint   = CGPointMake(0.5, 1.0);
    g.cornerRadius = radius;
    if (@available(iOS 13.0, *)) { g.cornerCurve = kCACornerCurveContinuous; }
    [shine.layer addSublayer:g];
    shine.clipsToBounds = YES;
    shine.layer.cornerRadius = radius;
    [host addSubview:shine];
    [NSLayoutConstraint activateConstraints:@[
        [shine.leadingAnchor  constraintEqualToAnchor:host.leadingAnchor],
        [shine.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [shine.topAnchor      constraintEqualToAnchor:host.topAnchor],
        [shine.bottomAnchor   constraintEqualToAnchor:host.bottomAnchor],
    ]];
    objc_setAssociatedObject(shine, "ameRimGradient", g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/// 载体尺寸变化时刷新高光渐变与阴影路径(布局后调用;找不到就什么也不做)
static inline void AmeRefreshGlassRim(UIView *host) {
    if (host == nil) return;
    static const NSInteger kAmeRimTag = 0x4D52494D;   // 'MRIM'
    for (UIView *sub in host.subviews) {
        if (sub.tag != kAmeRimTag) { continue; }
        // host 是玻璃载体:尺寸变后重设阴影路径,深浅色切换后刷新描边/阴影色
        if (!CGRectIsEmpty(host.bounds)) {
            host.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:host.bounds
                                                               cornerRadius:host.layer.cornerRadius].CGPath;
        }
        host.layer.borderColor = (AmeGlassRimColor()).CGColor;
        host.layer.shadowColor = (AmeGlassShadeColor()).CGColor;
        CAGradientLayer *g = (CAGradientLayer *)objc_getAssociatedObject(sub, "ameRimGradient");
        if (g != nil) { g.frame = sub.bounds; }
    }
}

#pragma mark - 统一材质(iOS 26 液态玻璃优先 / 旧系统回退)

/// 统一材质:iOS 26+ 尝试液态玻璃;失败/旧系统回退 fallbackStyle。
static inline UIVisualEffect *AmeGlassEffect(UIBlurEffectStyle fallbackStyle) {
    static Class glassCls = Nil;
    static BOOL probed = NO;
    static BOOL glassOK = NO;
    static NSString *probeWhy = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        glassCls = NSClassFromString(@"UIGlassEffect");
        if (glassCls == Nil) {
            probeWhy = @"UIGlassEffect 类不存在(系统 < iOS 26 或未链接)";
        } else {
            SEL sel = @selector(effectWithStyle:);
            if ([glassCls respondsToSelector:sel]) {
                id g = ((id (*)(id, SEL, NSInteger))objc_msgSend)(glassCls, sel, 0);
                if (g != nil && [g isKindOfClass:[UIVisualEffect class]]) {
                    glassOK = YES;
                    probeWhy = [NSString stringWithFormat:@"UIGlassEffect 生效(sdk=%s)", __VERSION__];
                } else {
                    probeWhy = @"UIGlassEffect.effectWithStyle: 返回空/类型不符 ⇒ 回退";
                }
            } else {
                probeWhy = @"UIGlassEffect 无 effectWithStyle: 方法 ⇒ 回退";
            }
        }
        NSLog(@"[glass] 材质解析:%@ ⇒ %@", glassOK ? @"玻璃" : @"常规材质(回退)", probeWhy ?: @"?");
        probed = YES;
    });
    (void)probed;

    if (glassOK && glassCls != Nil) {
        id g = ((id (*)(id, SEL, NSInteger))objc_msgSend)(glassCls, @selector(effectWithStyle:), 0);
        if (g != nil && [g isKindOfClass:[UIVisualEffect class]]) {
            return (UIVisualEffect *)g;
        }
    }
    return [UIBlurEffect effectWithStyle:fallbackStyle];
}

/// ★ [E3] 尽力把 SPEC §2.5 的 blur / saturate 落到系统材质上。
/// 系统没有公开 API 控制系统材质的模糊半径/饱和度 ⇒ 走私有 backdrop 滤镜通道(GaussianBlur.inputRadius /
/// ColorControls.inputSaturation / Vibrance.inputAmount),全程 @try 包裹,失败即回退系统默认并打日志(自证)。
/// 返回 YES 表示已按 SPEC 应用。
static inline BOOL AmeTuneGlassBackdrop(UIVisualEffectView *vev, CGFloat blurRadius, CGFloat saturation) {
    if (vev == nil) { return NO; }
    id backdrop = nil, layer = nil;
    @try { backdrop = [vev valueForKey:@"backdropView"]; } @catch (__unused NSException *e) { backdrop = nil; }
    @try { if (backdrop) { layer = [backdrop valueForKey:@"backdropLayer"]; } } @catch (__unused NSException *e) { layer = nil; }
    if (layer == nil) {
        NSLog(@"[glass] blur=%.0f saturate=%.0f%% 未应用(系统材质默认:私有 backdrop 通道不可用)", blurRadius, saturation * 100.0);
        return NO;
    }
    BOOL ok = NO;
    @try {
        NSArray *filters = [layer valueForKey:@"filters"];
        for (id f in filters) {
            NSString *name = nil;
            @try { name = [f valueForKey:@"name"]; } @catch (__unused NSException *e) { name = nil; }
            if (name.length == 0) { continue; }
            if ([name containsString:@"GaussianBlur"]) {
                [f setValue:@(blurRadius) forKey:@"inputRadius"];      ok = YES;
            } else if ([name containsString:@"ColorControls"]) {
                [f setValue:@(saturation) forKey:@"inputSaturation"];  ok = YES;
            } else if ([name containsString:@"Vibrance"]) {
                [f setValue:@(saturation - 1.0) forKey:@"inputAmount"]; ok = YES;
            }
        }
        [layer setValue:filters forKey:@"filters"];
    } @catch (__unused NSException *e) { ok = NO; }
    NSLog(@"[glass] blur=%.0f saturate=%.0f%% %@", blurRadius, saturation * 100.0,
          ok ? @"已应用(SPEC §2.5)" : @"未应用(回退系统默认)");
    return ok;
}

/// 给 view 贴一层玻璃并设圆角(卡片/面板/列表行用)。返回承载视图,插在最底层。
/// ★ [E3] 补齐四要素:blur(AmeGlassEffect)+ saturate/blur 调参 + 1px 描边 + 内高光 + 外阴影。
static inline UIVisualEffectView * _Nullable AmeApplyGlassSurface(UIView *view, AmeGlassRadius radius) {
    if (view == nil) { return nil; }
    UIVisualEffect *effect = AmeGlassEffect(UIBlurEffectStyleSystemMaterial);
    if (effect == nil) { return nil; }
    view.backgroundColor = [UIColor clearColor];
    view.layer.cornerRadius = (CGFloat)radius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.masksToBounds = YES;
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:effect];
    blur.translatesAutoresizingMaskIntoConstraints = NO;
    blur.userInteractionEnabled = NO;
    blur.layer.cornerRadius = (CGFloat)radius;
    blur.layer.cornerCurve = kCACornerCurveContinuous;
    blur.layer.masksToBounds = YES;
    // ★ [E3] 玻璃底填充(SPEC §2.1 glass:.10/.55)
    blur.contentView.backgroundColor = AmeGlassFillColor();
    [view insertSubview:blur atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [blur.leadingAnchor  constraintEqualToAnchor:view.leadingAnchor],
        [blur.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [blur.topAnchor      constraintEqualToAnchor:view.topAnchor],
        [blur.bottomAnchor   constraintEqualToAnchor:view.bottomAnchor],
    ]];
    // ★ [E3] blur 26 / saturate 180% + 描边 + 内高光 + 外阴影
    AmeTuneGlassBackdrop(blur, AmeGlassBlurRadius, AmeGlassSaturate);
    AmeAttachGlassRim(view, (CGFloat)radius);   // 会把 view.layer.masksToBounds 置 NO(为外阴影)
    return blur;
}

/// 灵动岛/刘海安全区(横屏有岛那侧 ≈59pt、另一侧 0;iPad 两者皆 0)
static inline UIEdgeInsets AmeSafeInsets(UIView *view) {
    if (@available(iOS 11.0, *)) { return view.safeAreaInsets; }
    return UIEdgeInsetsZero;
}

NS_ASSUME_NONNULL_END
