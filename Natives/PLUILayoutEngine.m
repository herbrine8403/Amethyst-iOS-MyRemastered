#import "PLUILayoutEngine.h"
#import "PLUINodeView.h"

static NSUInteger const PLUILayoutMaxNodes = 500;
static NSInteger const PLUILayoutMaxDepth = 12;

@interface PLUILayoutEngine ()
@property (nonatomic, copy, readwrite) NSDictionary *tree;
@property (nonatomic, nullable, readwrite) PLUINodeView *rootView;
@end

/// 递归校验：超限返回 NO（整树判废走默认树）；未知形状的子项不算致命。
static BOOL PLUILayoutValidateNode(NSDictionary *node, NSInteger depth,
                                    NSUInteger *count, NSUInteger *contentCount) {
    if (![node isKindOfClass:NSDictionary.class]) return YES;
    (*count)++;
    if (*count > PLUILayoutMaxNodes || depth > PLUILayoutMaxDepth) return NO;
    if ([node[@"kind"] isKindOfClass:NSString.class] &&
        [node[@"kind"] isEqualToString:@"content"]) {
        (*contentCount)++;
    }
    for (NSString *childKey in @[@"children", @"items"]) {
        id children = node[childKey];
        if (![children isKindOfClass:NSArray.class]) continue;
        for (id child in (NSArray *)children) {
            if (!PLUILayoutValidateNode(child, depth + 1, count, contentCount)) return NO;
        }
    }
    return YES;
}

static void PLUIEnumerateNode(PLUINodeView *node, void (^block)(PLUINodeView *node)) {
    if (!node) return;
    block(node);
    for (UIView *sub in node.subviews) {
        if ([sub isKindOfClass:PLUINodeView.class]) {
            PLUIEnumerateNode((PLUINodeView *)sub, block);
        }
    }
}

@implementation PLUILayoutEngine

+ (instancetype)engineWithTree:(nullable NSDictionary *)tree {
    PLUILayoutEngine *engine = [[PLUILayoutEngine alloc] init];
    engine.tree = [self validatedTree:tree] ?: [self defaultTree];
    return engine;
}

+ (nullable NSDictionary *)validatedTree:(NSDictionary *)tree {
    if (![tree isKindOfClass:NSDictionary.class] ||
        ![tree[@"kind"] isKindOfClass:NSString.class]) {
        return nil;
    }
    NSUInteger count = 0, contentCount = 0;
    if (!PLUILayoutValidateNode(tree, 1, &count, &contentCount)) return nil;
    // 壳必须恰好有一个内容挂载点
    if (contentCount != 1) return nil;
    return tree;
}

+ (NSDictionary *)defaultTree {
    return @{
        @"kind": @"row",
        @"id": @"shell",
        @"children": @[
            @{
                @"kind": @"column",
                @"id": @"sidebar",
                @"width": @56,
                @"background": @"$color:sidebar",
                @"padding": @8,
                @"children": @[@{
                    @"kind": @"nav",
                    @"id": @"nav",
                    @"items": @[
                        @{ @"id": @"nav.home", @"icon": @"sf:house.fill", @"action": @"open:home" },
                        @{ @"id": @"nav.download", @"icon": @"sf:arrow.down.circle.fill", @"action": @"open:download" },
                        @{ @"id": @"nav.versionManager", @"icon": @"sf:cube.transparent.fill", @"action": @"open:versionManager" },
                        @{ @"id": @"nav.settings", @"icon": @"sf:gearshape.fill", @"action": @"open:settings" },
                    ],
                }],
            },
            @{
                @"kind": @"content",
                @"id": @"content",
                @"weight": @1,
                @"initialPage": @"home",
            },
            @{
                @"kind": @"panel",
                @"id": @"panel",
                @"width": @200,
                @"background": @"$color:surface",
                @"padding": @12,
            },
        ],
    };
}

- (nullable PLUINodeView *)buildRootViewInHost:(UIView *)host
                              traitCollection:(UITraitCollection *)trait {
    if (self.rootView) [self.rootView removeFromSuperview];
    BOOL compact = trait.horizontalSizeClass == UIUserInterfaceSizeClassCompact;
    BOOL dark = trait.userInterfaceStyle == UIUserInterfaceStyleDark;

    PLUINodeView *root = [[PLUINodeView alloc] init];
    if (![root applyNode:self.tree outerEdges:UIRectEdgeAll compact:compact dark:dark]) {
        return nil;
    }
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:root];
    [NSLayoutConstraint activateConstraints:@[
        [root.topAnchor constraintEqualToAnchor:host.topAnchor],
        [root.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
        [root.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [root.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
    ]];
    self.rootView = root;
    return root;
}

- (nullable PLUINodeView *)viewForId:(NSString *)viewId {
    if (![viewId isKindOfClass:NSString.class] || viewId.length == 0) return nil;
    __block PLUINodeView *match = nil;
    [self enumerateNodes:^(PLUINodeView *node) {
        if (!match && [node.nodeId isEqualToString:viewId]) match = node;
    }];
    return match;
}

- (void)enumerateNodes:(void (^)(PLUINodeView *node))block {
    PLUIEnumerateNode(self.rootView, block);
}

@end
