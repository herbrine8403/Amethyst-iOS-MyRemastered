//
//  LauncherSkeletonView.h
//  Amethyst
//
//  列表骨架屏：异步加载期间在列表区域显示骨架占位，替代"空白 / 只有一个转圈"的无反馈等待。
//  仅使用 UIKit + QuartzCore，无第三方依赖。
//
//  用法：
//      self.skeleton = [LauncherSkeletonView attachToView:self.modTableView
//                                                   style:LauncherSkeletonStyleList];
//      [self.skeleton showSkeleton];   // 请求发起时
//      [self.skeleton hideSkeleton];   // 成功 / 失败都要隐藏
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 骨架占位样式
typedef NS_ENUM(NSInteger, LauncherSkeletonStyle) {
    /// 列表行样式（模组 / 光影 / 资源包 / 数据包 / 整合包 / 世界 / 版本列表）
    LauncherSkeletonStyleList = 0,
    /// 卡片网格样式（版本列表使用的卡片流）
    LauncherSkeletonStyleCardGrid,
};

/// 覆盖在列表视图之上的骨架占位层。
///
/// 说明：骨架层本身不接收触摸（userInteractionEnabled = NO），
/// 因此不会影响列表的滚动与下拉刷新。
@interface LauncherSkeletonView : UIView

/// 当前是否正在显示骨架（只读）
@property (nonatomic, assign, readonly, getter=isSkeletonVisible) BOOL skeletonVisible;

/// 在 hostView 之上创建骨架层（四边与 hostView 对齐，随其约束自动变化）。
/// @return hostView 为空时返回 nil。
+ (nullable instancetype)attachToView:(UIView *)hostView style:(LauncherSkeletonStyle)style;

/// 显示骨架（淡入 + 呼吸动画）
- (void)showSkeleton;

/// 隐藏骨架（淡出；可重复调用）
- (void)hideSkeleton;

/// 立即隐藏并停止动画（用于列表销毁前的清理）
- (void)hideSkeletonImmediately;

@end

NS_ASSUME_NONNULL_END
