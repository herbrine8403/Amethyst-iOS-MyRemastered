#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class PLUINodeView;

/// 节点树 → UIKit 渲染引擎。
///
/// 职责：校验 build(ui) 产出的节点树（节点数 ≤ 500、深度 ≤ 12、恰好一个
/// content 节点），合法则交给 PLUINodeView 递归构建；非法或 nil 直接回退到
/// 程序化默认三栏树 —— 这是材质包回退链的最后一环，连 main.lua 都坏也能渲染。
@interface PLUILayoutEngine : NSObject

@property (nonatomic, copy, readonly) NSDictionary *tree;
@property (nonatomic, nullable, readonly) PLUINodeView *rootView;

+ (instancetype)engineWithTree:(nullable NSDictionary *)tree;

/// 程序化默认树（sidebar 56pt + content + right panel 的三栏形态）。
+ (NSDictionary *)defaultTree;

/// 构建根节点视图并四边 pin 到 host。返回 nil 仅当默认树也构建失败（视为引擎 bug）。
- (nullable PLUINodeView *)buildRootViewInHost:(UIView *)host
                             traitCollection:(UITraitCollection *)trait;

- (nullable PLUINodeView *)viewForId:(NSString *)viewId;

/// 深度优先遍历全部节点视图（动作路由 / bind 注册用）。
- (void)enumerateNodes:(void (^)(PLUINodeView *node))block;

@end

NS_ASSUME_NONNULL_END
