#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 材质包引擎壳（general.ui_shell = engine 时由 SceneDelegate 启用）。
///
/// 职责：加载 UI 材质包（Lua 树 → PLUILayoutEngine 渲染）、接管全部 Show*
/// 通知与内容区 VC 切换（实现整段搬迁自 LauncherRootViewController，含三处
/// 历史修复）、向 Lua 桥提供状态与动作路由。默认回退链：坏包 → 内置
/// pcl-classic → 程序化默认树；引擎自身异常由 SceneDelegate @try 兜底换回旧壳。
@interface PLUIShellViewController : UIViewController

@end

NS_ASSUME_NONNULL_END
