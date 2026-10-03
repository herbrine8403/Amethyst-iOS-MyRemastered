#import <UIKit/UIKit.h>

// FCL风格右侧面板 - 显示账户信息、版本选择和启动按钮
//
// ★ [NORIGHT] 右栏卡片已下线(用户拍板:干掉右栏卡,把里面的东西搬家)。
//   本控制器**保留**为「不可见控制器」:容器被钉成 0×0 + hidden,内部约束由
//   norightCollapsePanelLayout: 整组停用(否则 0×0 会与内部 required 约束冲突)。
//   启动全链路(账号校验/JIT/下载拦截/版本解析)、执行 Jar、选择版本、下载中心、
//   JIT 监视 —— 全部仍在本类里原样运行,只是 UI 入口搬到了新位置:
//
//     · 头像 + 用户名 + 版本号  → 主页「欢迎回来」卡(LauncherNewsViewController)
//        (头像仍可点 / 长按:点 = 账户管理,长按 = 自定义头像菜单 —— 同样转发到本类原方法)
//     · 启动游戏               → 主页底部「紧凑胶囊」(LauncherNewsViewController)
//     · JIT 状态               → 主页顶栏右侧 pill(与「⚙ 自定义」并排)
//     · 执行 Jar / 选择版本     → 「实例」页顶部工具区(VersionManagerViewController)
//     · 下载中/暂停            → 不搬(「下载」标签本来就有下载中心);通知逻辑保留
//
//   新 UI 只 post 动作名,由下面的通知转发到**本类原来的方法** —— 零复制逻辑。
//
// ★ [FIX511] 换底到 5.1.0 时本头文件误取了上游 5.1.0 的 13 行小版本,丢掉了下面
//   整块 fork 独有的声明(3 个通知常量 + 3 个 noright 方法),导致:
//     AccountListViewController.m:165  [LauncherRightPanelViewController norightPostAction:]
//       → error: no known class method for selector 'norightPostAction:'
//     LauncherRootViewController.m:597 [rightPanelVC norightCollapsePanelLayout:YES]
//     LauncherNewsViewController.m    AmeRightPanelStateNotification / …RequestStateNotification
//   现从 fork 版取回(fork 的 .h 与本文件其余内容一致,纯超集)。

/// 新 UI 入口 → 右栏原实现。
/// userInfo: @{@"action": @"launch" | @"executeJar" | @"versionPicker" | @"downloadCenter"}
extern NSString * const AmeRightPanelActionNotification;
/// 右栏状态广播(版本号 / JIT 文本与颜色 / 用户名 / 启动键标题与可用性)。userInfo 见 .m。
extern NSString * const AmeRightPanelStateNotification;
/// 外部主动索取一次状态(右栏收到后会实时重算 JIT 并回广播)。
extern NSString * const AmeRightPanelRequestStateNotification;

@interface LauncherRightPanelViewController : UIViewController

// 更新账户信息显示
- (void)updateAccountInfo;

// 更新版本信息显示
- (void)updateVersionInfo;

// ★ [NORIGHT] 收起(collapsed=YES)/恢复面板内部全部约束 + 隐藏子视图。幂等。
- (void)norightCollapsePanelLayout:(BOOL)collapsed;

// ★ [NORIGHT] 广播一次当前状态(内部更新时也会自动广播)。
- (void)norightBroadcastState;

// ★ [NORIGHT] 新 UI 发起动作的唯一入口(内部即 post AmeRightPanelActionNotification)。
+ (void)norightPostAction:(NSString *)action;

@end
