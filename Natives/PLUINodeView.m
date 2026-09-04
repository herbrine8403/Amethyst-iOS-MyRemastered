#import "PLUINodeView.h"
#import "PLThemeManager.h"

/// 无固定尺寸标记（NAN 表示按内容/权重布局）。
static CGFloat const PLUINodeAuto = NAN;

#pragma mark - 值解析（$color: / $image: / $i18n: / sf: / dimen）

static NSDictionary *PLUIMergedNode(NSDictionary *node, BOOL compact) {
    // responsive.phone 覆盖：compact 尺寸类下浅合并属性
    id override = [node[@"responsive"] isKindOfClass:NSDictionary.class]
        ? node[@"responsive"][@"phone"] : nil;
    if (!compact || ![override isKindOfClass:NSDictionary.class] || [(NSDictionary *)override count] == 0) {
        return node;
    }
    NSMutableDictionary *merged = [node mutableCopy];
    [(NSDictionary *)override enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        if ([key isKindOfClass:NSString.class]) merged[key] = value;
    }];
    return merged;
}

/// 数值或 dimen 表（{_dimen={phone=,pad=,default=}}）→ 具体数值；无法解析返回 NAN。
static CGFloat PLUIResolveDimen(id value, BOOL compact) {
    if ([value isKindOfClass:NSNumber.class]) return [value doubleValue];
    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *dimen = [value[@"_dimen"] isKindOfClass:NSDictionary.class] ? value[@"_dimen"] : nil;
        if (dimen) {
            id picked = compact ? (dimen[@"phone"] ?: dimen[@"default"]) : (dimen[@"pad"] ?: dimen[@"default"]);
            if ([picked isKindOfClass:NSNumber.class]) return [picked doubleValue];
        }
    }
    return PLUINodeAuto;
}

static UIColor *PLUIResolveColor(id spec, UIColor *fallback) {
    if (![spec isKindOfClass:NSString.class] || [(NSString *)spec length] == 0) return fallback;
    if ([spec hasPrefix:@"$color:"]) {
        return [PLThemeManager.sharedManager colorForToken:[spec substringFromIndex:7] fallback:fallback];
    }
    return [PLThemeManager.sharedManager colorFromHex:spec] ?: fallback;
}

static UIImage *PLUIResolveImage(id spec) {
    if (![spec isKindOfClass:NSString.class] || [(NSString *)spec length] == 0) return nil;
    if ([spec hasPrefix:@"sf:"]) {
        NSString *name = [spec substringFromIndex:3];
        return [UIImage systemImageNamed:name] ?: [UIImage imageNamed:name];
    }
    if ([spec hasPrefix:@"$image:"]) {
        return [PLThemeManager.sharedManager imageForToken:[spec substringFromIndex:7]];
    }
    return nil;
}

static NSString *PLUIResolveText(id spec) {
    if (![spec isKindOfClass:NSString.class]) return nil;
    if ([spec hasPrefix:@"$i18n:"]) {
        NSString *key = [spec substringFromIndex:6];
        NSString *localized = NSLocalizedString(key, @"");
        return localized.length > 0 ? localized : key;
    }
    return spec;
}

static UIFont *PLUIFontFromStyle(NSDictionary *style) {
    CGFloat size = [style[@"font"] isKindOfClass:NSNumber.class] ? [style[@"font"] doubleValue] : 15;
    NSString *weightName = [style[@"weight"] isKindOfClass:NSString.class] ? style[@"weight"] : @"regular";
    UIFontWeight weight = UIFontWeightRegular;
    if ([weightName isEqualToString:@"medium"]) weight = UIFontWeightMedium;
    else if ([weightName isEqualToString:@"semibold"]) weight = UIFontWeightSemibold;
    else if ([weightName isEqualToString:@"bold"]) weight = UIFontWeightBold;
    else if ([weightName isEqualToString:@"light"]) weight = UIFontWeightLight;
    return [UIFont systemFontOfSize:size weight:weight];
}

static UIEdgeInsets PLUIResolvePadding(id value) {
    if ([value isKindOfClass:NSNumber.class]) {
        CGFloat inset = [value doubleValue];
        return UIEdgeInsetsMake(inset, inset, inset, inset);
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        CGFloat top = [value[@"top"] doubleValue], left = [value[@"left"] doubleValue];
        CGFloat bottom = [value[@"bottom"] doubleValue], right = [value[@"right"] doubleValue];
        return UIEdgeInsetsMake(top, left, bottom, right);
    }
    return UIEdgeInsetsZero;
}

/// 允许进入节点树的节点种类（未知种类整体丢弃，防脏数据扩散）。
static BOOL PLUIIsKnownKind(NSString *kind) {
    static NSSet<NSString *> *kinds;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        kinds = [NSSet setWithArray:@[@"row", @"column", @"button", @"text", @"image",
                                      @"spacer", @"divider", @"content", @"nav", @"panel", @"tileGrid"]];
    });
    return [kinds containsObject:kind];
}

@interface PLUINodeView ()
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy) NSString *nodeId;
@property (nonatomic, assign) CGFloat weight;
@property (nonatomic, copy) NSString *action;
@property (nonatomic, copy) NSString *bind;
@property (nonatomic, assign) BOOL contentArea;
@property (nonatomic, assign) BOOL horizontalStack;
@property (nonatomic, assign) BOOL verticalStack;
@property (nonatomic, assign) CGFloat spacing;
@property (nonatomic, assign) UIEdgeInsets padding;
@property (nonatomic, assign) CGFloat fixedWidth;
@property (nonatomic, assign) CGFloat fixedHeight;
@property (nonatomic, assign) UIRectEdge outerEdges;
@property (nonatomic, copy) NSString *initialPage;
@property (nonatomic, strong) UILabel *textLabel;
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) UIImageView *contentImageView;
@end

@implementation PLUINodeView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _kind = @"view";
        _fixedWidth = PLUINodeAuto;
        _fixedHeight = PLUINodeAuto;
        _outerEdges = UIRectEdgeAll;
    }
    return self;
}

#pragma mark - 节点应用

- (BOOL)applyNode:(NSDictionary *)node
       outerEdges:(UIRectEdge)outerEdges
          compact:(BOOL)compact
             dark:(BOOL)dark {
    if (![node isKindOfClass:NSDictionary.class]) return NO;
    NSString *kind = [node[@"kind"] isKindOfClass:NSString.class] ? node[@"kind"] : nil;
    if (!kind || !PLUIIsKnownKind(kind)) return NO;
    node = PLUIMergedNode(node, compact);

    _kind = kind;
    _outerEdges = outerEdges;
    _nodeId = [node[@"id"] isKindOfClass:NSString.class] ? node[@"id"] : nil;
    _action = [node[@"action"] isKindOfClass:NSString.class] ? node[@"action"] : nil;
    _bind = [node[@"bind"] isKindOfClass:NSString.class] ? node[@"bind"] : nil;
    _weight = [node[@"weight"] isKindOfClass:NSNumber.class] ? [node[@"weight"] doubleValue] : 0;
    _spacing = [node[@"spacing"] isKindOfClass:NSNumber.class] ? [node[@"spacing"] doubleValue] : 8;
    _padding = PLUIResolvePadding(node[@"padding"]);
    _fixedWidth = PLUIResolveDimen(node[@"width"], compact);
    _fixedHeight = PLUIResolveDimen(node[@"height"], compact);
    _initialPage = [node[@"initialPage"] isKindOfClass:NSString.class] ? node[@"initialPage"] : nil;

    self.backgroundColor = PLUIResolveColor(node[@"background"], self.backgroundColor);

    // 尺寸：size = 正方形边长
    CGFloat square = PLUIResolveDimen(node[@"size"], compact);
    if (!isnan(square)) {
        _fixedWidth = square;
        _fixedHeight = square;
    }

    if ([kind isEqualToString:@"row"] || [kind isEqualToString:@"column"]) {
        _horizontalStack = [kind isEqualToString:@"row"];
        _verticalStack = !_horizontalStack;
        [self applyChildren:node[@"children"] compact:compact dark:dark];
    } else if ([kind isEqualToString:@"panel"]) {
        // panel = column 容器（带默认内边距的可组合面板）
        _verticalStack = YES;
        _padding = UIEdgeInsetsEqualToEdgeInsets(_padding, UIEdgeInsetsZero)
            ? PLUIResolvePadding(@12) : _padding;
        [self applyChildren:node[@"children"] compact:compact dark:dark];
    } else if ([kind isEqualToString:@"nav"]) {
        _horizontalStack = [node[@"layout"] isEqualToString:@"horizontal"];
        _verticalStack = !_horizontalStack;
        _spacing = [node[@"spacing"] isKindOfClass:NSNumber.class] ? [node[@"spacing"] doubleValue] : 12;
        [self applyNavItems:node compact:compact dark:dark];
    } else if ([kind isEqualToString:@"content"]) {
        _contentArea = YES;
        if (_weight <= 0) _weight = 1; // 内容区默认伸展
    } else if ([kind isEqualToString:@"button"]) {
        [self buildButton:node];
    } else if ([kind isEqualToString:@"text"]) {
        [self buildText:node];
    } else if ([kind isEqualToString:@"image"]) {
        [self buildImage:node compact:compact];
    } else if ([kind isEqualToString:@"spacer"]) {
        if (_weight <= 0 && isnan(_fixedWidth) && isnan(_fixedHeight)) _weight = 1;
    } else if ([kind isEqualToString:@"divider"]) {
        self.backgroundColor = PLUIResolveColor(node[@"background"],
            [UIColor separatorColor]);
    } else if ([kind isEqualToString:@"tileGrid"]) {
        // M5 实现；先按透明容器处理，不劣化布局
    }

    [self applyCorner:node];
    [self applyVisibility:node compact:compact dark:dark];
    return YES;
}

- (void)applyChildren:(id)children compact:(BOOL)compact dark:(BOOL)dark {
    if (![children isKindOfClass:NSArray.class]) return;
    NSUInteger count = [(NSArray *)children count];
    for (NSUInteger i = 0; i < count; i++) {
        NSDictionary *childNode = [(NSArray *)children objectAtIndex:i];
        // 外沿边传递：首/末子节点继承父容器对应侧，其余侧由父容器自身决定
        UIRectEdge childEdges = 0;
        if (self.horizontalStack) {
            if (i == 0) childEdges |= (self.outerEdges & UIRectEdgeLeft);
            if (i == count - 1) childEdges |= (self.outerEdges & UIRectEdgeRight);
            childEdges |= (self.outerEdges & (UIRectEdgeTop | UIRectEdgeBottom));
        } else {
            if (i == 0) childEdges |= (self.outerEdges & UIRectEdgeTop);
            if (i == count - 1) childEdges |= (self.outerEdges & UIRectEdgeBottom);
            childEdges |= (self.outerEdges & (UIRectEdgeLeft | UIRectEdgeRight));
        }
        PLUINodeView *child = [[PLUINodeView alloc] init];
        if ([child applyNode:childNode outerEdges:childEdges compact:compact dark:dark]) {
            [self addSubview:child];
        }
    }
}

- (void)applyNavItems:(NSDictionary *)node compact:(BOOL)compact dark:(BOOL)dark {
    id items = node[@"items"];
    if (![items isKindOfClass:NSArray.class]) return;
    NSMutableArray *childNodes = [NSMutableArray array];
    for (id item in (NSArray *)items) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *buttonNode = [NSMutableDictionary dictionary];
        buttonNode[@"kind"] = @"button";
        if ([item[@"id"] isKindOfClass:NSString.class]) buttonNode[@"id"] = item[@"id"];
        if ([item[@"action"] isKindOfClass:NSString.class]) buttonNode[@"action"] = item[@"action"];
        if ([item[@"icon"] isKindOfClass:NSString.class]) buttonNode[@"icon"] = item[@"icon"];
        if ([item[@"label"] isKindOfClass:NSString.class]) buttonNode[@"label"] = item[@"label"];
        if ([item[@"size"] isKindOfClass:NSNumber.class]) buttonNode[@"size"] = item[@"size"];
        buttonNode[@"style"] = item[@"style"] ?: @{};
        [childNodes addObject:buttonNode];
    }
    [self applyChildren:childNodes compact:compact dark:dark];
}

- (void)buildButton:(NSDictionary *)node {
    _button = [UIButton buttonWithType:UIButtonTypeSystem];
    _button.translatesAutoresizingMaskIntoConstraints = YES; // 父节点手动布局
    NSDictionary *style = [node[@"style"] isKindOfClass:NSDictionary.class] ? node[@"style"] : @{};
    NSString *title = PLUIResolveText(node[@"label"] ?: node[@"text"]);
    if (title) {
        [_button setTitle:title forState:UIControlStateNormal];
        UIColor *tint = PLUIResolveColor(style[@"tint"], [UIColor labelColor]);
        [_button setTitleColor:tint forState:UIControlStateNormal];
        _button.titleLabel.font = PLUIFontFromStyle(style);
    }
    UIImage *icon = PLUIResolveImage(node[@"icon"]);
    if (icon) {
        UIColor *tint = PLUIResolveColor(style[@"tint"], nil);
        if (tint) icon = [icon imageWithTintColor:tint];
        [_button setImage:icon forState:UIControlStateNormal];
    }
    _button.backgroundColor = PLUIResolveColor(style[@"background"], _button.backgroundColor);
    [self addSubview:_button];
    [_button addTarget:self action:@selector(nodeTapped:) forControlEvents:UIControlEventTouchUpInside];
}

- (void)buildText:(NSDictionary *)node {
    _textLabel = [UILabel new];
    _textLabel.translatesAutoresizingMaskIntoConstraints = YES;
    NSDictionary *style = [node[@"style"] isKindOfClass:NSDictionary.class] ? node[@"style"] : @{};
    _textLabel.text = PLUIResolveText(node[@"text"] ?: node[@"label"]) ?: @"";
    _textLabel.font = PLUIFontFromStyle(style);
    _textLabel.textColor = PLUIResolveColor(style[@"color"], [UIColor labelColor]);
    _textLabel.adjustsFontForContentSizeCategory = YES;
    [self addSubview:_textLabel];
}

- (void)buildImage:(NSDictionary *)node compact:(BOOL)compact {
    _contentImageView = [UIImageView new];
    _contentImageView.translatesAutoresizingMaskIntoConstraints = YES;
    _contentImageView.contentMode = UIViewContentModeScaleAspectFit;
    _contentImageView.image = PLUIResolveImage(node[@"icon"] ?: node[@"src"]);
    _contentImageView.backgroundColor = PLUIResolveColor(node[@"background"], _contentImageView.backgroundColor);
    [self addSubview:_contentImageView];
}

- (void)applyCorner:(NSDictionary *)node {
    CGFloat corner = [node[@"corner"] isKindOfClass:NSNumber.class] ? [node[@"corner"] doubleValue] : 0;
    if (corner <= 0) return;
    NSString *mask = [node[@"cornerMask"] isKindOfClass:NSString.class] ? node[@"cornerMask"] : @"all";
    self.layer.cornerRadius = corner;
    if ([mask isEqualToString:@"outer"]) {
        // 只圆"贴外"的角：两条相邻边都在外沿才生效
        CACornerMask corners = 0;
        if ((self.outerEdges & UIRectEdgeTop) && (self.outerEdges & UIRectEdgeLeft)) corners |= kCALayerMinXMinYCorner;
        if ((self.outerEdges & UIRectEdgeTop) && (self.outerEdges & UIRectEdgeRight)) corners |= kCALayerMaxXMinYCorner;
        if ((self.outerEdges & UIRectEdgeBottom) && (self.outerEdges & UIRectEdgeLeft)) corners |= kCALayerMinXMaxYCorner;
        if ((self.outerEdges & UIRectEdgeBottom) && (self.outerEdges & UIRectEdgeRight)) corners |= kCALayerMaxXMaxYCorner;
        self.layer.maskedCorners = corners;
    } else {
        self.layer.maskedCorners = kCALayerMaxXMinYCorner | kCALayerMinXMinYCorner
            | kCALayerMaxXMaxYCorner | kCALayerMinXMaxYCorner;
    }
}

- (void)applyVisibility:(NSDictionary *)node compact:(BOOL)compact dark:(BOOL)dark {
    NSString *visibleWhen = [node[@"visibleWhen"] isKindOfClass:NSString.class] ? node[@"visibleWhen"] : nil;
    if (!visibleWhen) return;
    BOOL visible = YES;
    if ([visibleWhen isEqualToString:@"dark"]) visible = dark;
    else if ([visibleWhen isEqualToString:@"light"]) visible = !dark;
    else if ([visibleWhen isEqualToString:@"phone"]) visible = compact;
    else if ([visibleWhen isEqualToString:@"pad"]) visible = !compact;
    self.hidden = !visible;
}

- (void)nodeTapped:(id)sender {
    if (self.tapHandler) self.tapHandler(self);
}

#pragma mark - 布局（row/column 栈：固定尺寸 + 权重分配）

- (void)layoutSubviews {
    [super layoutSubviews];
    if (!self.horizontalStack && !self.verticalStack) return;
    BOOL horizontal = self.horizontalStack;

    // 叶子内容贴合自身 bounds
    if (self.textLabel) self.textLabel.frame = self.bounds;
    if (self.contentImageView) self.contentImageView.frame = self.bounds;
    if (self.button) {
        CGFloat side = MIN(self.bounds.size.width, self.bounds.size.height);
        self.button.frame = CGRectMake((self.bounds.size.width - side) / 2,
                                       (self.bounds.size.height - side) / 2, side, side);
    }

    NSArray<PLUINodeView *> *children = [self.subviews isKindOfClass:NSArray.class] ? (NSArray *)self.subviews : nil;
    if (children.count == 0) return;

    UIEdgeInsets pad = self.padding;
    CGFloat mainLen = horizontal ? self.bounds.size.width - pad.left - pad.right
                                 : self.bounds.size.height - pad.top - pad.bottom;
    CGFloat crossLen = horizontal ? self.bounds.size.height - pad.top - pad.bottom
                                  : self.bounds.size.width - pad.left - pad.right;
    if (mainLen <= 0 || crossLen <= 0) return;

    NSUInteger n = children.count;
    CGFloat spacingTotal = self.spacing * (CGFloat)(n - 1);
    CGFloat fixedTotal = 0;
    CGFloat weightSum = 0;
    NSMutableArray<NSNumber *> *mains = [NSMutableArray arrayWithCapacity:n];
    for (UIView *sub in children) {
        CGFloat main = PLUINodeAuto;
        if (![sub isKindOfClass:PLUINodeView.class]) { [mains addObject:@(0)]; continue; }
        PLUINodeView *child = (PLUINodeView *)sub;
        if (child.weight > 0) {
            weightSum += child.weight;
        } else if (horizontal && !isnan(child.fixedWidth)) {
            main = child.fixedWidth;
        } else if (!horizontal && !isnan(child.fixedHeight)) {
            main = child.fixedHeight;
        } else {
            main = [child preferredMainSizeForCrossSize:crossLen horizontal:horizontal];
            if (isnan(main)) main = 0;
        }
        [mains addObject:@(isnan(main) ? NAN : main)];
        if (!isnan(main)) fixedTotal += main;
    }

    CGFloat weightedAvail = mainLen - spacingTotal - fixedTotal;
    if (weightedAvail < 0) weightedAvail = 0;

    CGFloat offset = horizontal ? pad.left : pad.top;
    for (NSUInteger i = 0; i < n; i++) {
        PLUINodeView *child = children[i];
        CGFloat main = mains[i].doubleValue;
        if (isnan(main)) {
            main = (weightSum > 0 && child.weight > 0) ? weightedAvail * child.weight / weightSum : 0;
        }
        if (horizontal) {
            child.frame = CGRectMake(offset, pad.top, main, crossLen);
        } else {
            child.frame = CGRectMake(pad.left, offset, crossLen, main);
        }
        offset += main + self.spacing;
    }
}

- (CGFloat)preferredMainSizeForCrossSize:(CGFloat)crossSize horizontal:(BOOL)horizontal {
    CGSize fit = [self sizeThatFits:CGSizeMake(horizontal ? CGFLOAT_MAX : crossSize,
                                                horizontal ? crossSize : CGFLOAT_MAX)];
    return horizontal ? fit.width : fit.height;
}

- (CGSize)sizeThatFits:(CGSize)size {
    if (self.textLabel) return [self.textLabel sizeThatFits:size];
    if (self.button) {
        CGSize intrinsic = self.button.intrinsicContentSize;
        return CGSizeMake(intrinsic.width + 8, intrinsic.height + 4);
    }
    if (self.contentImageView) {
        if (!isnan(self.fixedWidth) && !isnan(self.fixedHeight)) return CGSizeMake(self.fixedWidth, self.fixedHeight);
        UIImage *image = self.contentImageView.image;
        if (image) {
            CGSize s = image.size;
            CGFloat scale = MIN(size.width / s.width, size.height / s.height);
            if (scale > 0 && !isinf(scale)) return CGSizeMake(s.width * scale, s.height * scale);
            return s;
        }
        return CGSizeZero;
    }
    if ([self.kind isEqualToString:@"divider"]) return CGSizeMake(1, 1); // 主轴 1pt
    return CGSizeZero;
}

- (CGSize)intrinsicContentSize {
    return [self sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
}

#pragma mark - 文本/图片读写（launcher.view 句柄落点）

- (void)updateText:(NSString *)text {
    if (self.textLabel) {
        self.textLabel.text = text ?: @"";
    } else if (self.button) {
        [self.button setTitle:text forState:UIControlStateNormal];
    }
    [self setNeedsLayout];
}

- (NSString *)currentText {
    if (self.textLabel) return self.textLabel.text;
    if (self.button) return [self.button titleForState:UIControlStateNormal];
    return nil;
}

- (void)updateImageSpec:(NSString *)imageSpec {
    UIImage *image = PLUIResolveImage(imageSpec);
    if (self.contentImageView) self.contentImageView.image = image;
    else if (self.button && image) [self.button setImage:image forState:UIControlStateNormal];
}

- (void)updateTextColorSpec:(NSString *)colorSpec {
    UIColor *color = PLUIResolveColor(colorSpec, nil);
    if (!color) return;
    if (self.textLabel) self.textLabel.textColor = color;
    else if (self.button) [self.button setTitleColor:color forState:UIControlStateNormal];
}

- (void)updateEnabled:(BOOL)enabled {
    if (self.button) self.button.enabled = enabled;
}

#pragma mark - 元数据

- (NSUInteger)nodeCount {
    NSUInteger count = 1;
    for (UIView *sub in self.subviews) {
        if ([sub isKindOfClass:PLUINodeView.class]) count += [(PLUINodeView *)sub nodeCount];
    }
    return count;
}

@end
