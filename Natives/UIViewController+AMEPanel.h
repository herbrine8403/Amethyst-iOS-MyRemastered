//
//  UIViewController+AMEPanel.h
//  Amethyst
//
//  Task137：子面板原生基底样式（原 UIViewController+NMPanel 新拟态版本的
//  原生化重写，语义不变：统一子面板页面底色与表格基底，幂等应用）。
//
//  背景：侧栏推入的子面板数量众多（LauncherNavigationController 承载的
//  全部推入面板），逐页改造不现实，由导航容器在 push/viewDidAppear 时
//  统一调用本分类（幂等；透明定制面板自动跳过，见下方说明）。
//
//  ★ 来源:Gsjsjzhznsz/Air-Minecraft-iOS-Launcher(同一上游 herbrine8403/Amethyst-iOS-MyRemastered
//    的派生 fork)的 Natives/UIViewController+AMEPanel.h,按其实现移植。原作者注释中的 Task 编号保留。

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface UIViewController (AMEPanel)

/// 子面板是否排除基底样式（默认 NO；特殊面板可覆盖返回 YES，
/// 例如自带全屏自绘背景的面板）
- (BOOL)ame_subpanelExcludesBaseStyle;

/// 应用子面板原生基底样式（幂等：每个 VC 实例只应用一次）：
///   1. 页面底色 -> systemBackgroundColor（iOS 原生，深浅色自动适配）；
///      已是 clearColor 的（BackgroundManager 全局背景透出面板）不动；
///   2. 表格基底：背景清透（页面底色/背景照片透出）+ 系统分隔线。
///      只动 UITableView 自身底色，不动 cell（cell 样式归各自实现）。
- (void)ame_applySubpanelBaseStyle;

@end

NS_ASSUME_NONNULL_END
