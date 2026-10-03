#pragma once

#import <UIKit/UIKit.h>

// ★ [LANG-SWITCH] 启动器界面语言选择子页：
//   第 0 组「跟随系统」+ 第 1 组「可用语言」（自动枚举 App 包内所有 .lproj，
//   显示名用 NSLocale 取系统语言名）。选中即写 NSUserDefaults 自定义键
//   (ame_launcher_language) 并广播 AmeLauncherLanguageChangedNotification。
// 由 LauncherPreferencesViewController 的「语言」项(typeChildPane)推入。
@interface LauncherLanguageViewController : UITableViewController

@end

// ★ [LANG-SWITCH] 语言切换广播：各页收到后 reloadData/重取 localize() 文案，即时生效。
extern NSString * const AmeLauncherLanguageChangedNotification;
