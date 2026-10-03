//
//  UIViewController+AMEPanel.m
//  Amethyst
//
//  Task137：子面板原生基底样式实现。设计说明见头文件。
//
//  ★ 来源:Gsjsjzhznsz/Air-Minecraft-iOS-Launcher(同一上游 herbrine8403/Amethyst-iOS-MyRemastered
//    的派生 fork)的 Natives/UIViewController+AMEPanel.m,按其实现移植。原作者注释中的 Task 编号保留。

#import "UIViewController+AMEPanel.h"
#import <objc/runtime.h>

static void *s_ame137_appliedKey = &s_ame137_appliedKey;

@implementation UIViewController (AMEPanel)

- (BOOL)ame_subpanelExcludesBaseStyle {
    // 分类默认不排除；子类按需覆盖（见头注释）
    return NO;
}

- (void)ame_applySubpanelBaseStyle {
    // 幂等：每个 VC 实例只应用一次
    if (objc_getAssociatedObject(self, s_ame137_appliedKey)) return;
    objc_setAssociatedObject(self, s_ame137_appliedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if ([self ame_subpanelExcludesBaseStyle]) return;

    UIView *rootView = self.view;
    if (!rootView) return;

    // (1) 基底画布：系统默认底（nil）-> systemBackgroundColor（iOS 原生，
    //     深浅色自动适配）。已是 clearColor 的（BackgroundManager 全局背景
    //     透出面板）不动——那是刻意的透明定制，覆盖会破坏背景照片/视频功能
    //     （Task111）。
    if (rootView.backgroundColor != UIColor.clearColor) {
        rootView.backgroundColor = [UIColor systemBackgroundColor];
    }

    // (2) 表格基底：背景清透（画布/照片透出）+ 系统分隔线。
    //     只动 UITableView 自身底色，不动 cell（cell 样式归各自实现：
    //     卡片 cell 已自绘，普通 cell 维持系统样式即可）。
    //     遍历规则：深度上限 3（view > 容器 > 容器 > 表格 足以覆盖常规面板），
    //     且不深入 UITableView 内部（其子视图是 cell，不归基底样式管）。
    [self ame137_styleTableViewsInView:rootView depth:0];
}

- (void)ame137_styleTableViewsInView:(UIView *)view depth:(NSInteger)depth {
    if (depth > 3) return;
    if ([view isKindOfClass:UITableView.class]) {
        UITableView *tv = (UITableView *)view;
        // 页面底色场景：表格清透，页面底色接管；照片透出场景同样清透（原本多为此值，幂等）
        if (tv.backgroundColor != UIColor.clearColor) {
            // 已被面板自定义为卡片色的不动。系统默认底判定：nil /
            // groupTableViewBackgroundColor / systemBackgroundColor。
            BOOL ame137_isSysDefault = (tv.backgroundColor == nil ||
                [tv.backgroundColor isEqual:UIColor.groupTableViewBackgroundColor] ||
                [tv.backgroundColor isEqual:[UIColor systemBackgroundColor]]);
            if (ame137_isSysDefault) {
                tv.backgroundColor = UIColor.clearColor;
            }
        }
        // Task137：分隔线回归系统默认色（原新拟态版本改成了 secondaryLabel 灰）
        tv.separatorColor = [UIColor separatorColor];
        // 滚动指示器回归系统默认（自动适配深浅色）
        if (@available(iOS 13.0, *)) {
            tv.indicatorStyle = UIScrollViewIndicatorStyleDefault;
        }
        return;   // 不深入表格内部（cell 归各自实现）
    }
    for (UIView *sub in view.subviews) {
        [self ame137_styleTableViewsInView:sub depth:depth + 1];
    }
}

@end
