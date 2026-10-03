//
//  NMToast.h
//  Amethyst
//
//  Task 125/126：应用内通知（toast）。Task137：新拟态样式退役，卡片改用
//  iOS 原生表面（UIKit+NativeSurface），类名保留（调用面广，改名无行为收益）。
//
//  背景（5.1.0 用户实测反馈）：
//    "正版账号登录的时候会使用系统弹窗提示，而且用户需要手动删除"
//    ——旧 showDialog 走 UIAlertController + 新建 UIWindow(windowLevel 1000)
//    呈现"系统级"弹窗，且 OK 后 window 不回收（handler 为 nil，
//    alertWindow 泄漏并占据 key window），用户被迫手动处理。
//
//  本组件：应用内卡片式通知，iOS 原生卡片表面（secondarySystemGroupedBackground
//  + 圆角，深浅色由语义色自动适配），从安全区顶部滑入，**自动消失**（默认 4.5s），
//  点击可提前关闭；带可选动作按钮（如"查看"跳转更新页）。
//  同一时间只保留一条（新 toast 顶替旧 toast）。
//
//
//  用途：
//    - Task 125：启动器启动时自动检测更新，发现新版本 -> 非侵入式 toast
//    - Task 126：正版账号登录成功/状态提示 -> toast（不再弹系统窗）
//    - 任何"用户不需要做决定"的提示场景（错误提示仍走 AlertDialog）
//
//  线程安全：主线程调度（内部 dispatch_async(main)）。
//
//  ★ 来源:Gsjsjzhznsz/Air-Minecraft-iOS-Launcher(同一上游的派生 fork)的 Natives/NMToast.h,
//    按其实现移植;原作者注释中的 Task 编号与"踩过的坑"说明保留。

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface NMToast : NSObject

/// 显示一条 toast（默认 4.5 秒自动消失）
/// @param message 正文（支持多行）
+ (void)showMessage:(NSString *)message;

/// 显示一条 toast，自定义停留时长（duration <= 0 时使用默认 4.5s）
+ (void)showMessage:(NSString *)message duration:(NSTimeInterval)duration;

/// 显示带动作按钮的 toast（如"查看新版"-> 打开发布页）
/// @param actionTitle 劳作按钮标题；nil 则不显示按钮
/// @param onAction 点击动作按钮的回调（toast 自动关闭后调用，主线程）
+ (void)showMessage:(NSString *)message
         actionTitle:(nullable NSString *)actionTitle
            onAction:(nullable void (^)(void))onAction;

/// 立即关闭当前 toast（若存在）
+ (void)dismiss;

@end

NS_ASSUME_NONNULL_END
