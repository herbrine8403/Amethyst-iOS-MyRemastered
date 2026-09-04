#import "PLUIActionRouter.h"
#import "PLProfiles.h"
#import "utils.h"

/// 动作名 → Show* 通知名。内容区页面切换全部复用既有通知，零新增逻辑。
static NSDictionary<NSString *, NSString *> *PLUIActionNotificationMap(void) {
    static NSDictionary *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"open:home": @"ShowHomePage",
            @"open:download": @"ShowDownloadPage",
            @"open:versionManager": @"ShowVersionManager",
            @"open:settings": @"ShowSettings",
            @"open:ai": @"ShowAIPage",
            @"open:mods": @"ShowModsManager",
            @"open:shaders": @"ShowShadersManager",
            @"open:modpackImport": @"ShowModpackImport",
            @"open:gameDirectory": @"ShowGameDirectory",
            @"open:accountManager": @"ShowAccountManager",
            @"open:profileEditor": @"ShowProfileEditor",
        };
    });
    return map;
}

/// M4 由 LauncherLaunchService 接管的动作（当前记录日志不执行）。
static NSSet<NSString *> *PLUIActionReservedForLaunchService(void) {
    static NSSet *actions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        actions = [NSSet setWithArray:@[
            @"launch", @"pickVersion", @"executeJar", @"openDownloadCenter", @"selectAccount",
        ]];
    });
    return actions;
}

@implementation PLUIActionRouter

+ (instancetype)sharedRouter {
    static PLUIActionRouter *router;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        router = [PLUIActionRouter new];
    });
    return router;
}

- (void)performAction:(NSString *)action fromViewController:(nullable UIViewController *)presenter {
    if (![action isKindOfClass:NSString.class] || action.length == 0) return;

    NSString *notificationName = PLUIActionNotificationMap()[action];
    if (notificationName) {
        // profileEditor 需要携带当前版本名（与旧壳 ShowProfileEditor 的 object 语义一致）
        id object = [action isEqualToString:@"open:profileEditor"]
            ? PLProfiles.current.selectedProfileName : nil;
        [[NSNotificationCenter defaultCenter] postNotificationName:notificationName object:object];
        return;
    }

    if ([action isEqualToString:@"open:multiplayer"] || [action isEqualToString:@"open:zeroTier"]) {
        // ZeroTier/Terracotta 联机暂时移除（与旧壳行为一致：提示不可用）
        if (presenter) {
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:localize(@"i18n_str_320", nil)
                                  message:localize(@"i18n_str_321", nil)
                           preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_322", nil)
                                                      style:UIAlertActionStyleDefault
                                                    handler:nil]];
            [presenter presentViewController:alert animated:YES completion:nil];
        }
        return;
    }

    if ([PLUIActionReservedForLaunchService() containsObject:action]) {
        NSLog(@"[PLUIActionRouter] action '%@' reserved for LauncherLaunchService (M4)", action);
        return;
    }

    // 未知动作：log + no-op，绝不做动态 selector 派发
    NSLog(@"[PLUIActionRouter] unknown action ignored: %@", action);
}

@end
