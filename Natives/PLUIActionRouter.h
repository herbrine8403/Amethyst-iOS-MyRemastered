#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 动作白名单路由：材质包脚本/节点 → 原生行为。
///
/// 只接受白名单内的动作字符串，未知动作 log + no-op；
/// 绝不使用 NSSelectorFromString 解析材质包提供的任何字符串。
/// open:* 直接转发既有 Show* 通知，零新增页面逻辑。
@interface PLUIActionRouter : NSObject

+ (instancetype)sharedRouter;

/// 执行动作。
/// open:home/download/versionManager/settings/ai/mods/shaders/modpackImport/
/// gameDirectory/accountManager/profileEditor → 切换内容区页面；
/// open:multiplayer / open:zeroTier → 联机暂不可用提示；
/// launch / pickVersion / executeJar / openDownloadCenter / selectAccount → M4 接入
/// LauncherLaunchService，当前记录日志不执行。
- (void)performAction:(NSString *)action fromViewController:(nullable UIViewController *)presenter;

@end

NS_ASSUME_NONNULL_END
