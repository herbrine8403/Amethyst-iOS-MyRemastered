#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// UI 材质包节点视图：一棵 PLUINodeView 树对应 build(ui) 返回的节点树。
///
/// row/column 节点在 layoutSubviews 中自行完成栈布局（权重分配 / 间距 / 内边距 /
/// 固定尺寸），不依赖 UIStackView —— 权重语义完全可控，边栏宽度、内容区伸展
/// 都能精确还原。cornerMask=outer 由父容器把"外沿边"递归传下来，圆角只落在
/// 真正贴外的角上。
@interface PLUINodeView : UIView

@property (nonatomic, copy, readonly, nullable) NSString *nodeId;
@property (nonatomic, copy, readonly) NSString *kind;
/// 主轴权重，0 = 不伸展（按固定尺寸或内容尺寸布局）。
@property (nonatomic, readonly) CGFloat weight;
/// 动作名（如 open:download / launch），由 PLUIActionRouter 解析执行。
@property (nonatomic, copy, readonly, nullable) NSString *action;
/// 状态绑定键（account.name / download.summary / ...），壳负责喂数据。
@property (nonatomic, copy, readonly, nullable) NSString *bind;
/// content 节点：原生功能页 VC 的挂载占位。
@property (nonatomic, readonly, getter=isContentArea) BOOL contentArea;
/// content 节点的初始页面标识（如 home），壳据此挂载首个功能页。
@property (nonatomic, copy, readonly, nullable) NSString *initialPage;
/// row/column 轴向；叶子节点为 NO。
@property (nonatomic, readonly) BOOL isHorizontalStack;
@property (nonatomic, readonly) BOOL isVerticalStack;

/// 点击回调（button / nav item）。nil = 无动作。
@property (nonatomic, copy, nullable) void (^tapHandler)(PLUINodeView *node);

/// 引擎入口：应用节点属性并递归构建子节点。非法子节点被静默丢弃（容错契约）。
/// outerEdges 是该节点"贴外沿"的边（cornerMask=outer 用）；compact=phone 尺寸类；
/// dark=当前深浅色（visibleWhen 用）。
- (BOOL)applyNode:(NSDictionary *)node
       outerEdges:(UIRectEdge)outerEdges
          compact:(BOOL)compact
             dark:(BOOL)dark;

/// 子树节点总数（含自身），供引擎限额校验。
- (NSUInteger)nodeCount;

/// 主轴上的内容需求（无权重且无固定尺寸时用于布局测量）。
- (CGFloat)preferredMainSizeForCrossSize:(CGFloat)crossSize horizontal:(BOOL)horizontal;

/// 文本类节点的内容读写（launcher.view("id"):setText 的落点）。
- (void)updateText:(nullable NSString *)text;
- (nullable NSString *)currentText;
- (void)updateImageSpec:(nullable NSString *)imageSpec;
/// 文本色（"$color:token" / "#RRGGBB"）与可用性。
- (void)updateTextColorSpec:(nullable NSString *)colorSpec;
- (void)updateEnabled:(BOOL)enabled;

@end

NS_ASSUME_NONNULL_END
