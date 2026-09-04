#import <Foundation/Foundation.h>

#import "DBNumberedSlider.h"
#import "HostManagerBridge.h"
#import "LauncherNavigationController.h"
#import "LauncherMenuViewController.h"
#import "LauncherPreferences.h"
#import "LauncherPreferencesViewController.h"
#import "LauncherPrefContCfgViewController.h"
#import "LauncherPrefManageJREViewController.h"
#import "UIKit+hook.h"

#import "config.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

#import "ImageCropperViewController.h"
#import "CustomIconManager.h"
#import "BackgroundSettingsViewController.h"
#import "BackgroundManager.h"
#import "UpdateChecker.h"
#import "CurseForgeAPIKeyViewController.h"
#import "CustomControlsViewController.h"
#import "AI/AIProviderConfigViewController.h"
#import "AI/AISessionListViewController.h"
#import "AI/AISystemPromptEditorViewController.h"
#import "AI/AiSettings.h"
#import "PLThemeManager.h"

@interface LauncherPreferencesViewController()
@property(nonatomic) NSArray<NSString*> *rendererKeys, *rendererList;
@property(nonatomic) BOOL pickingMousePointer;
// 当前正在选择的颜色偏好键（general.text_color / general.card_color）
@property(nonatomic, copy, nullable) NSString *pickingColorPrefKey;
// 顶部 Hero 卡片视图（App 名 + 版本 + 设备信息），作为 tableHeaderView 的一部分
@property(nonatomic, strong, nullable) UIView *heroCard;
@end

@implementation LauncherPreferencesViewController

- (id)init {
    self = [super init];
    // 不设置 self.title，避免顶部导航栏出现"设置"标题黑条（参照 FCL 无 title 风格）
    return self;
}

- (NSString *)imageName {
    return @"MenuSettings";
}

- (void)openImagePicker {
    // 检查是否已经显示了图片选择器
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *window in scene.windows) {
                    for (UIView *view in window.subviews) {
                        if ([view isKindOfClass:[UIAlertController class]] || 
                            [view isKindOfClass:[UIImagePickerController class]]) {
                            // 如果已经显示了相关控制器，直接返回
                            return;
                        }
                    }
                }
            }
        }
    }
    
    UIImagePickerController *imagePicker = [[UIImagePickerController alloc] init];
    imagePicker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    imagePicker.delegate = self;
    
    // 延迟显示图片选择器，避免与UIAlertController冲突
    dispatch_async(dispatch_get_main_queue(), ^{
        [self presentViewController:imagePicker animated:YES completion:nil];
    });
}

- (void)openMousePointerPicker {
    self.pickingMousePointer = YES;
    UIImagePickerController *imagePicker = [[UIImagePickerController alloc] init];
    imagePicker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    imagePicker.delegate = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self presentViewController:imagePicker animated:YES completion:nil];
    });
}

#pragma mark - 自定义颜色选择（字体/卡片颜色）

- (void)openColorPickerForKey:(NSString *)fullKey title:(NSString *)title {
    if (@available(iOS 14.0, *)) {
        UIColorPickerViewController *picker = [[UIColorPickerViewController alloc] init];
        picker.title = title;
        picker.delegate = self;
        // 预选当前已保存的颜色
        NSString *hex = getPrefObject(fullKey);
        UIColor *current = [self colorFromHexString:hex];
        if (current) {
            picker.selectedColor = current;
        }
        self.pickingColorPrefKey = fullKey;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentViewController:picker animated:YES completion:nil];
        });
    } else {
        [self showCustomIconError:localize(@"i18n_str_367", nil)];
    }
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController API_AVAILABLE(ios(14.0)) {
    NSString *key = self.pickingColorPrefKey;
    self.pickingColorPrefKey = nil;
    if (!key) return;
    UIColor *color = viewController.selectedColor;
    NSString *hex = [self hexStringFromColor:color];
    setPrefObject(key, hex);
    [[NSNotificationCenter defaultCenter] postNotificationName:@"LauncherAppearanceChanged" object:nil];
    [self.tableView reloadData];
}

- (nullable UIColor *)colorFromHexString:(id)hex {
    if (![hex isKindOfClass:[NSString class]] || [(NSString *)hex length] == 0) return nil;
    NSString *clean = [(NSString *)hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:clean];
    if (![scanner scanHexInt:&rgb]) return nil;
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

- (NSString *)hexStringFromColor:(UIColor *)color {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [color getRed:&r green:&g blue:&b alpha:&a];
    return [NSString stringWithFormat:@"%02X%02X%02X", (unsigned)(r * 255), (unsigned)(g * 255), (unsigned)(b * 255)];
}

#pragma mark - UIImagePickerControllerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    [picker dismissViewControllerAnimated:YES completion:^{
        // 在图片选择器完全关闭后再处理图片
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImage *selectedImage = info[UIImagePickerControllerOriginalImage];
            if (!selectedImage) {
                [self showCustomIconError:localize(@"i18n_str_368", nil)];
                return;
            }
            if (self.pickingMousePointer) {
                self.pickingMousePointer = NO;
                NSString *path = [NSString stringWithFormat:@"%s/controlmap/mouse_pointer.png", getenv("POJAV_HOME")];
                NSData *pngData = UIImagePNGRepresentation(selectedImage);
                [NSFileManager.defaultManager createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
                BOOL ok = [pngData writeToFile:path atomically:YES];
                if (ok) {
                    [NSNotificationCenter.defaultCenter postNotificationName:@"MousePointerUpdated" object:nil];
                    [self showSuccessMessage:localize(@"i18n_str_369", nil)];
                } else {
                    [self showCustomIconError:localize(@"i18n_str_370", nil)];
                }
                return;
            }
            // 显示处理中的提示
            [self showProcessingIndicator];
            
            // 检查图片是否为正方形
            if (selectedImage.size.width != selectedImage.size.height) {
                // 如果不是正方形，打开裁剪界面
                ImageCropperViewController *cropperVC = [[ImageCropperViewController alloc] initWithImage:selectedImage];
                __weak typeof(self) weakSelf = self;
                cropperVC.completionHandler = ^(UIImage * _Nullable croppedImage) {
                    if (croppedImage) {
                        // 保存裁剪后的图片
                        [[CustomIconManager sharedManager] saveCustomIcon:croppedImage withCompletion:^(BOOL success, NSError * _Nullable error) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                if (success) {
                                    [weakSelf showSuccessMessage:localize(@"i18n_str_371", nil)];
                                    // 更新应用图标选择器的显示
                                    [weakSelf.tableView reloadData];
                                } else {
                                    NSString *errorMessage = error.localizedDescription ?: localize(@"i18n_str_372", nil);
                                    [weakSelf showCustomIconError:errorMessage];
                                }
                            });
                        }];
                    } else {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [weakSelf showCustomIconError:localize(@"i18n_str_373", nil)];
                        });
                    }
                };
                [weakSelf.navigationController pushViewController:cropperVC animated:YES];
            } else {
                // 如果是正方形，直接保存
                [[CustomIconManager sharedManager] saveCustomIcon:selectedImage withCompletion:^(BOOL success, NSError * _Nullable error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (success) {
                            [self showSuccessMessage:localize(@"i18n_str_371", nil)];
                            // 更新应用图标选择器的显示
                            [self.tableView reloadData];
                        } else {
                            NSString *errorMessage = error.localizedDescription ?: localize(@"i18n_str_372", nil);
                            [self showCustomIconError:errorMessage];
                        }
                    });
                }];
            }
        });
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.pickingMousePointer) {
                self.pickingMousePointer = NO;
            } else {
                [self showCustomIconError:localize(@"i18n_str_374", nil)];
            }
        });
    }];
}

#pragma mark - Custom Icon Helper Methods

- (void)showProcessingIndicator {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_78", nil) message:localize(@"i18n_str_375", nil) preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:nil];
    
    // 2秒后自动关闭提示
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [alert dismissViewControllerAnimated:YES completion:nil];
    });
}

- (void)showSuccessMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_80", nil) message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:okAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showCustomIconError:(NSString *)errorMessage {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_42", nil) message:errorMessage preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:okAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)viewDidLoad
{
    // 彻底隐藏导航栏黑条（仅当作为非 modal 根页面且是栈中唯一 VC 时）
    // 尽早设置，避免导航栏闪烁
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil &&
        self.navigationController.viewControllers.count == 1) {
        self.navigationController.navigationBarHidden = YES;
    }

    // 启用设置项搜索（必须在 super viewDidLoad 之前设置，父类据此创建 searchController）
    self.searchEnabled = YES;

    self.getPreference = ^id(NSString *section, NSString *key){
        // AI 助手分区：直接与 AiSettings 打通（AiSettings 读写 NSUserDefaults，不走通用偏好存储）
        if ([section isEqualToString:@"ai"]) {
            if ([key isEqualToString:@"safety_mode"]) {
                switch ([[AiSettings sharedSettings] safetyMode]) {
                    case AiSafetyModeSafe:  return @"只读自动执行（Safe）";
                    case AiSafetyModeAsk:   return @"写操作逐次确认（Ask）";
                    case AiSafetyModeYOLO:  return @"自动批准（YOLO）";
                }
            }
            if ([key isEqualToString:@"markdown_enabled"]) {
                return @([[AiSettings sharedSettings] markdownEnabled]);
            }
            return nil;
        }
        NSString *keyFull = [NSString stringWithFormat:@"%@.%@", section, key];
        return getPrefObject(keyFull);
    };
    self.setPreference = ^(NSString *section, NSString *key, id value){
        // AI 助手分区：回写到 AiSettings
        if ([section isEqualToString:@"ai"]) {
            if ([key isEqualToString:@"safety_mode"]) {
                AiSafetyMode mode = AiSafetyModeSafe;
                if ([value isKindOfClass:[NSNumber class]]) {
                    mode = (AiSafetyMode)[value integerValue];
                } else if ([value isKindOfClass:[NSString class]]) {
                    NSString *s = value;
                    if ([s containsString:@"逐次确认"]) {
                        mode = AiSafetyModeAsk;
                    } else if ([s containsString:@"自动批准"]) {
                        mode = AiSafetyModeYOLO;
                    }
                }
                [[AiSettings sharedSettings] setSafetyMode:mode];
            } else if ([key isEqualToString:@"markdown_enabled"]) {
                [[AiSettings sharedSettings] setMarkdownEnabled:[value boolValue]];
            }
            return;
        }
        NSString *keyFull = [NSString stringWithFormat:@"%@.%@", section, key];
        setPrefObject(keyFull, value);
    };
    
    self.hasDetail = YES;
    self.prefDetailVisible = self.navigationController == nil;
    
    self.prefSections = @[@"general", @"download", @"video", @"mobileglues", @"control", @"java", @"debug", @"ai"];

    self.rendererKeys = getRendererKeys(NO);
    self.rendererList = getRendererNames(NO);
    
    // 检查是否在游戏中：如果当前可见视图控制器是 SurfaceViewController，则在游戏中
    BOOL(^whenNotInGame)() = ^BOOL(){
        UIViewController *visibleVC = currentVC();
        return ![visibleVC isKindOfClass:NSClassFromString(@"SurfaceViewController")];
    };

    // --- 定义弹窗显示的 Block，防止循环引用使用 weakSelf ---
    __weak typeof(self) weakSelf = self;
    void (^showTouchInfoAlert)(BOOL) = ^(BOOL enabled) {
        // 这个 Block 仅用于显示说明，不再负责逻辑判断
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"preference.popup.touch_info.title", nil)
                                                                           message:localize(@"preference.popup.touch_info.message", nil)
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            
            [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:nil]];
            
            [alert addAction:[UIAlertAction actionWithTitle:@"GitHub" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/TouchController/TouchController"] options:@{} completionHandler:nil];
            }]];
            
            [weakSelf presentViewController:alert animated:YES completion:nil];
        });
    };
    
    
    // -----------------------------------------------------------

    // 主题/材质包选择列表（内置 + 外部，纯颜色包与 UI 包都可选）
    NSMutableArray<NSString *> *themePackIds = [NSMutableArray array];
    NSMutableArray<NSString *> *themePackNames = [NSMutableArray array];
    for (NSDictionary *theme in [PLThemeManager.sharedManager availableThemes]) {
        [themePackIds addObject:theme[@"id"]];
        // UI 包（schemaVersion 2）加后缀标识其会接管布局
        NSString *suffix = ([theme[@"schemaVersion"] integerValue] >= 2) ? @" ·UI" : @"";
        [themePackNames addObject:[NSString stringWithFormat:@"%@%@", theme[@"name"], suffix]];
    }

    self.prefContents = @[
        @[
            // General settings
            @{@"icon": @"cube"},
            @{@"key": @"check_sha",
              @"hasDetail": @YES,
              @"icon": @"lock.shield",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            // 旧"下载源"行已移除：general.download_source 已由启动时的
            // migrateDownloadSourcePreferences 迁移到下方"下载镜像策略"分组的 4 个分类键
            @{@"key": @"mod_mirror",
              @"hasDetail": @YES,
              @"icon": @"network",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[
                  @"official",
                  @"mcim"
              ],
              @"pickList": @[
                  localize(@"preference.title.mod_mirror-official", nil),
                  localize(@"preference.title.mod_mirror-mcim", nil)
              ]
            },
            @{@"key": @"ui_layout",
              @"title": localize(@"i18n_str_376", nil),
              @"hasDetail": @YES,
              @"icon": @"rectangle.split.3x3",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[
                  @"vs",
                  @"card"
              ],
              @"pickList": @[
                  localize(@"i18n_str_377", nil),
                  localize(@"i18n_str_378", nil)
              ]
            },
            // UI 壳双轨开关：legacy（旧壳）/ engine（Lua 材质包引擎）
            @{@"key": @"ui_shell",
              @"title": localize(@"preference.title.ui_shell", nil),
              @"hasDetail": @YES,
              @"icon": @"square.stack.3d.up.fill",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[
                  @"legacy",
                  @"engine"
              ],
              @"pickList": @[
                  localize(@"preference.title.ui_shell-legacy", nil),
                  localize(@"preference.title.ui_shell-engine", nil)
              ],
              @"action": ^(NSString *value){
                  // 实时换壳，由 SceneDelegate 重建根控制器
                  [[NSNotificationCenter defaultCenter] postNotificationName:@"UIShellChanged" object:value];
              }
            },
            // 主题/材质包：纯颜色包（1）只换颜色；UI 包（2）同时接管布局
            @{@"key": @"theme_pack",
              @"title": localize(@"preference.title.theme_pack", nil),
              @"hasDetail": @YES,
              @"icon": @"paintbrush.fill",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": themePackIds,
              @"pickList": themePackNames,
              @"action": ^(NSString *value){
                  // applyThemeIdentifier 内部会 setPrefObject 并发 PLThemeDidChangeNotification，
                  // engine 壳收到通知后用新包即时重渲染
                  [[PLThemeManager sharedManager] applyThemeIdentifier:value error:nil];
              }
            },
            @{@"key": @"ui_theme",
              @"title": localize(@"i18n_str_379", nil),
              @"hasDetail": @YES,
              @"icon": @"circle.lefthalf.filled",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[
                  @"dark",
                  @"light",
                  @"auto"
              ],
              @"pickList": @[
                  localize(@"i18n_str_380", nil),
                  localize(@"i18n_str_381", nil),
                  localize(@"i18n_str_382", nil)
              ],
              @"action": ^(NSString *value){
                  // 实时应用主题，发通知由 SceneDelegate 处理。
                  // 不调用 loadPreferences(YES) 等会重置账号偏好的操作，
                  // 仅设置 window.overrideUserInterfaceStyle，账号数据不受影响。
                  [[NSNotificationCenter defaultCenter] postNotificationName:@"UIThemeChanged" object:value];
              }
            },
            @{@"key": @"custom_accent_color",
              @"title": localize(@"i18n_str_383", nil),
              @"hasDetail": @YES,
              @"icon": @"paintpalette.fill",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  [self openColorPickerForKey:@"general.accent_color" title:localize(@"i18n_str_383", nil)];
              }
            },
            @{@"key": @"custom_text_color",
              @"title": localize(@"i18n_str_384", nil),
              @"hasDetail": @YES,
              @"icon": @"textformat",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  [self openColorPickerForKey:@"general.text_color" title:localize(@"i18n_str_384", nil)];
              }
            },
            @{@"key": @"custom_card_color",
              @"title": localize(@"i18n_str_385", nil),
              @"hasDetail": @YES,
              @"icon": @"rectangle.fill",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  [self openColorPickerForKey:@"general.card_color" title:localize(@"i18n_str_385", nil)];
              }
            },
            @{@"key": @"reset_appearance_colors",
              @"title": localize(@"i18n_str_386", nil),
              @"icon": @"arrow.counterclockwise",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  setPrefObject(@"general.accent_color", @"");
                  setPrefObject(@"general.text_color", @"");
                  setPrefObject(@"general.card_color", @"");
                  [[NSNotificationCenter defaultCenter] postNotificationName:@"LauncherAppearanceChanged" object:nil];
                  [self.tableView reloadData];
              }
            },
            @{@"key": @"multi_threaded",
              @"title": localize(@"i18n_str_387", nil),
              @"hasDetail": @YES,
              @"icon": @"bolt.fill",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"curseforge_api_key",
              @"hasDetail": @YES,
              @"icon": @"key.fill",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  CurseForgeAPIKeyViewController *vc = [[CurseForgeAPIKeyViewController alloc] init];
                  UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
                  nav.modalPresentationStyle = UIModalPresentationFormSheet;
                  [self presentViewController:nav animated:YES completion:nil];
              }
            },
            @{@"key": @"cosmetica",
              @"hasDetail": @YES,
              @"icon": @"eyeglasses",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"debug_logging",
              @"hasDetail": @YES,
              @"icon": @"doc.badge.gearshape",
              @"type": self.typeSwitch,
              @"action": ^(BOOL enabled){
                  debugLogEnabled = enabled;
                  NSLog(@"[Debugging] Debug log enabled: %@", enabled ? @"YES" : @"NO");
              }
            },
            @{@"key": @"appicon",
              @"hasDetail": @YES,
              @"icon": @"paintbrush",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"action": ^void(NSString *iconName) {
                  if ([iconName isEqualToString:@"AppIcon-Light"]) {
                      iconName = nil;
                      [[CustomIconManager sharedManager] removeCustomIcon];
                  } else if ([iconName isEqualToString:@"CustomIcon"]) {
                      if (![[CustomIconManager sharedManager] hasCustomIcon]) {
                          dispatch_async(dispatch_get_main_queue(), ^{
                              UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_388", nil) message:localize(@"i18n_str_389", nil) preferredStyle:UIAlertControllerStyleAlert];
                              UIAlertAction *okAction = [UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil];
                              [alert addAction:okAction];
                              [self presentViewController:alert animated:YES completion:nil];
                          });
                          dispatch_async(dispatch_get_main_queue(), ^{
                              [self.tableView reloadData];
                          });
                          return;
                      }
                      [[CustomIconManager sharedManager] setCustomIconWithCompletion:^(BOOL success, NSError * _Nullable error) {
                          if (!success) {
                              dispatch_async(dispatch_get_main_queue(), ^{
                                  NSLog(@"Error in appicon: %@", error);
                                  showDialog(localize(@"Error", nil), error.localizedDescription);
                              });
                          }
                      }];
                      return;
                  }
                  [UIApplication.sharedApplication setAlternateIconName:iconName completionHandler:^(NSError * _Nullable error) {
                      if (error == nil) return;
                      NSLog(@"Error in appicon: %@", error);
                      showDialog(localize(@"Error", nil), error.localizedDescription);
                  }];
              },
              @"pickKeys": @[
                  @"AppIcon-Light",
                  @"CustomIcon"
              ],
              @"pickList": @[
                  localize(@"preference.title.appicon-default", nil),
                  localize(@"preference.title.appicon-custom", nil)
              ]
            },
            @{@"key": @"custom_appicon",
              @"hasDetail": @YES,
              @"icon": @"photo",
              @"type": self.typeButton,
              @"enableCondition": ^BOOL(){
                  return NO;
              },
              @"action": ^void(){
                  [self openImagePicker];
              }
            },
            @{@"key": @"launcher_background",
              @"hasDetail": @YES,
              @"icon": @"photo.fill.on.rectangle.fill",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  BackgroundSettingsViewController *bgVC = [[BackgroundSettingsViewController alloc] init];
                  UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:bgVC];
                  nav.modalPresentationStyle = UIModalPresentationFormSheet;
                  [self presentViewController:nav animated:YES completion:nil];
              }
            },
            @{@"key": @"hidden_sidebar",
              @"hasDetail": @YES,
              @"icon": @"sidebar.leading",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"announcement_preview_level",
              @"hasDetail": @YES,
              @"icon": @"megaphone",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[
                  @"full",
                  @"summary",
                  @"title_only"
              ],
              @"pickList": @[
                  localize(@"i18n_str_390", nil),
                  localize(@"i18n_str_391", nil),
                  localize(@"i18n_str_392", nil)
              ]
            },
            @{@"key": @"reset_warnings",
              @"icon": @"exclamationmark.triangle",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  resetWarnings();
              }
            },
            @{@"key": @"reset_settings",
              @"icon": @"trash",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"requestReload": @YES,
              @"showConfirmPrompt": @YES,
              @"destructive": @YES,
              @"action": ^void(){
                  loadPreferences(YES);
                  [self.tableView reloadData];
              }
            },
            @{@"key": @"memory_limit_help",
              @"hasDetail": @YES,
              @"icon": @"memorychip",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  [self showMemoryLimitHelp];
              }
            },
            @{@"key": @"erase_demo_data",
              @"icon": @"trash",
              @"type": self.typeButton,
              @"enableCondition": ^BOOL(){
                  NSString *demoPath = [NSString stringWithFormat:@"%s/.demo", getenv("POJAV_HOME")];
                  int count = [NSFileManager.defaultManager contentsOfDirectoryAtPath:demoPath error:nil].count;
                  return whenNotInGame() && count > 0;
              },
              @"showConfirmPrompt": @YES,
              @"destructive": @YES,
              @"action": ^void(){
                  NSString *demoPath = [NSString stringWithFormat:@"%s/.demo", getenv("POJAV_HOME")];
                  NSError *error;
                  if([NSFileManager.defaultManager removeItemAtPath:demoPath error:&error]) {
                      [NSFileManager.defaultManager createDirectoryAtPath:demoPath
                                              withIntermediateDirectories:YES attributes:nil error:nil];
                      [NSFileManager.defaultManager changeCurrentDirectoryPath:demoPath];
                      if (getenv("DEMO_LOCK")) {
                          [(LauncherNavigationController *)self.navigationController fetchLocalVersionList];
                      }
                  } else {
                      NSLog(@"Error in erase_demo_data: %@", error);
                      showDialog(localize(@"Error", nil), error.localizedDescription);
                  }
              }
            },
            @{@"key": @"check_update",
              @"hasDetail": @YES,
              @"icon": @"arrow.triangle.2.circlepath",
              @"type": self.typeButton,
              @"action": ^void(){
                  [self checkForUpdateFromSettings];
              }
            }
        ], @[
            // Download mirror policy settings（分类镜像策略，由 PLMirrorCenter 统一读取）
            @{@"icon": @"arrow.down.circle"},
            @{@"key": @"fileSource",
              @"hasDetail": @YES,
              @"icon": @"arrow.down.circle",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[
                  @"official_first",
                  @"mirror_first"
              ],
              @"pickList": @[
                  localize(@"preference.title.mirror_policy-official_first", nil),
                  localize(@"preference.title.mirror_policy-mirror_first", nil)
              ]
            },
            @{@"key": @"assetSearchSource",
              @"hasDetail": @YES,
              @"icon": @"magnifyingglass",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[
                  @"official_first",
                  @"mirror_first"
              ],
              @"pickList": @[
                  localize(@"preference.title.mirror_policy-official_first", nil),
                  localize(@"preference.title.mirror_policy-mirror_first", nil)
              ]
            },
            @{@"key": @"assetDownloadSource",
              @"hasDetail": @YES,
              @"icon": @"square.and.arrow.down",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[
                  @"official_first",
                  @"mirror_first"
              ],
              @"pickList": @[
                  localize(@"preference.title.mirror_policy-official_first", nil),
                  localize(@"preference.title.mirror_policy-mirror_first", nil)
              ]
            },
            @{@"key": @"modLoaderSource",
              @"hasDetail": @YES,
              @"icon": @"wrench.and.screwdriver",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[
                  @"official_first",
                  @"mirror_first"
              ],
              @"pickList": @[
                  localize(@"preference.title.mirror_policy-official_first", nil),
                  localize(@"preference.title.mirror_policy-mirror_first", nil)
              ]
            }
        ], @[
            // Video and renderer settings
            @{@"icon": @"video"},
            @{@"key": @"renderer",
              @"hasDetail": @YES,
              @"icon": @"cpu",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": self.rendererKeys,
              @"pickList": self.rendererList
            },
            @{@"key": @"resolution",
              @"hasDetail": @YES,
              @"icon": @"viewfinder",
              @"type": self.typeSlider,
              @"min": @(25),
              @"max": @(150)
            },
            // 帧率限制选项已移除：CADisplayLink 始终采用 30-120Hz 自适应范围，
            // 由屏幕硬件能力决定实际帧率（60Hz 设备仍为 60，120Hz ProMotion 设备可达 120）。
            // 不再提供"最大帧率限制 60FPS"开关，避免用户误关闭导致帧率被人为锁死。
            // 解锁帧率（关闭垂直同步）：三层联动关闭 VSync，让游戏帧率可超过屏幕刷新率。
            // 不限制 ProMotion 设备：60Hz 设备同样会被 VSync 锁在 60，也需要解锁。
            @{@"key": @"disable_game_vsync",
              @"hasDetail": @YES,
              @"icon": @"hare",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"performance_hud",
              @"hasDetail": @YES,
              @"icon": @"waveform.path.ecg",
              @"type": self.typeSwitch,
              @"enableCondition": ^BOOL(){
                  return [CAMetalLayer instancesRespondToSelector:@selector(developerHUDProperties)];
              }
            },
            @{@"key": @"fullscreen_airplay",
              @"hasDetail": @YES,
              @"icon": @"airplayvideo",
              @"type": self.typeSwitch,
              @"action": ^(BOOL enabled){
                  if (self.navigationController != nil) return;
                  if (UIApplication.sharedApplication.connectedScenes.count < 2) return;
                  if (enabled) {
                      [self.presentingViewController performSelector:@selector(switchToExternalDisplay)];
                  } else {
                      [self.presentingViewController performSelector:@selector(switchToInternalDisplay)];
                  }
              }
            },
            @{@"key": @"silence_other_audio",
              @"hasDetail": @YES,
              @"icon": @"speaker.slash",
              @"type": self.typeSwitch
            },
            @{@"key": @"silence_with_switch",
              @"hasDetail": @YES,
              @"icon": @"speaker.zzz",
              @"type": self.typeSwitch
            },
            @{@"key": @"allow_microphone",
              @"hasDetail": @YES,
              @"icon": @"mic",
              @"type": self.typeSwitch
            },
        ], @[
            // MobileGlues settings
            // 当渲染器选择为 MobileGlues 或 Vulkan 时，init_loadMobileGluesConfig()
            // 写入的 <POJAV_HOME>/MG/config.json 会被 MobileGlues 读取并生效。
            // Vulkan 渲染器的 OpenGL 回退使用 MobileGlues（对齐 Ynnyny 仓库）。
            // Auto 渲染器会被解析为 ANGLE，不会加载 MobileGlues。
            @{@"icon": @"cpu"},
            @{@"key": @"enable_angle",
              @"hasDetail": @YES,
              @"icon": @"triangle",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"enable_no_error",
              @"hasDetail": @YES,
              @"icon": @"exclamationmark.triangle",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[@"0", @"1", @"2"],
              @"pickList": @[
                  localize(@"preference.title.mg_enable_no_error-0", nil),
                  localize(@"preference.title.mg_enable_no_error-1", nil),
                  localize(@"preference.title.mg_enable_no_error-2", nil)
              ]
            },
            @{@"key": @"enable_ext_timer_query",
              @"hasDetail": @YES,
              @"icon": @"clock",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"enable_ext_compute_shader",
              @"hasDetail": @YES,
              @"icon": @"cube.transparent",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"enable_ext_direct_state_access",
              @"hasDetail": @YES,
              @"icon": @"directconnect",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"max_glsl_cache_size",
              @"hasDetail": @YES,
              @"icon": @"memorychip",
              @"type": self.typeSlider,
              @"min": @(0),
              @"max": @(256),
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"multidraw_mode",
              @"hasDetail": @YES,
              @"icon": @"square.stack.3d.down.dottedline",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[@"0", @"1", @"2"],
              @"pickList": @[
                  localize(@"preference.title.mg_multidraw_mode-0", nil),
                  localize(@"preference.title.mg_multidraw_mode-1", nil),
                  localize(@"preference.title.mg_multidraw_mode-2", nil)
              ]
            },
            @{@"key": @"angle_depth_clear_fix_mode",
              @"hasDetail": @YES,
              @"icon": @"rectangle.3.group",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"custom_gl_version",
              @"hasDetail": @YES,
              @"icon": @"number",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[@"0", @"4.0", @"4.1", @"4.2", @"4.3", @"4.4", @"4.5", @"4.6"],
              @"pickList": @[
                  localize(@"preference.title.mg_custom_gl_version-0", nil),
                  localize(@"preference.title.mg_custom_gl_version-4.0", nil),
                  localize(@"preference.title.mg_custom_gl_version-4.1", nil),
                  localize(@"preference.title.mg_custom_gl_version-4.2", nil),
                  localize(@"preference.title.mg_custom_gl_version-4.3", nil),
                  localize(@"preference.title.mg_custom_gl_version-4.4", nil),
                  localize(@"preference.title.mg_custom_gl_version-4.5", nil),
                  localize(@"preference.title.mg_custom_gl_version-4.6", nil)
              ]
            },
            @{@"key": @"fsr1_setting",
              @"hasDetail": @YES,
              @"icon": @"square.grid.3x2",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[@"0", @"1", @"2", @"3"],
              @"pickList": @[
                  localize(@"preference.title.mg_fsr1_setting-0", nil),
                  localize(@"preference.title.mg_fsr1_setting-1", nil),
                  localize(@"preference.title.mg_fsr1_setting-2", nil),
                  localize(@"preference.title.mg_fsr1_setting-3", nil)
              ]
            },
        ], @[
            // Control settings
            @{@"icon": @"gamecontroller"},
            
            // --- [修改] TouchController 模组支持 ---
            @{@"key": @"mod_touch_enable",
              @"icon": @"hand.point.up.left", // SF Symbols 图标
              @"hasDetail": @YES,
              @"type": self.typeChildPane,
              @"enableCondition": whenNotInGame,
              @"canDismissWithSwipe": @NO,
              @"class": NSClassFromString(@"TouchControllerPreferencesViewController")
            },
            // ------------------------------------------

            // --- [新增] 键位调整（从左侧菜单移到设置中） ---
            @{@"key": @"custom_controls",
              @"icon": @"gamecontroller.fill",
              @"hasDetail": @YES,
              @"type": self.typeChildPane,
              @"enableCondition": whenNotInGame,
              @"canDismissWithSwipe": @NO,
              @"class": CustomControlsViewController.class
            },
            // ---------------------------------------------

            @{@"key": @"default_gamepad_ctrl",
                @"icon": @"hammer",
                @"type": self.typeChildPane,
                @"enableCondition": whenNotInGame,
                @"canDismissWithSwipe": @NO,
                @"class": LauncherPrefContCfgViewController.class
            },
            @{@"key": @"custom_mouse_pointer",
                @"icon": @"cursorarrow",
                @"hasDetail": @YES,
                @"type": self.typeButton,
                @"enableCondition": whenNotInGame,
                @"action": ^void(){
                    [self openMousePointerPicker];
                }
            },
            @{@"key": @"hardware_hide",
                @"icon": @"eye.slash",
                @"hasDetail": @YES,
                @"type": self.typeSwitch,
            },
            @{@"key": @"reset_mouse_pointer",
                @"icon": @"arrow.counterclockwise",
                @"hasDetail": @YES,
                @"type": self.typeButton,
                @"enableCondition": whenNotInGame,
                @"action": ^void(){
                    NSString *path = [NSString stringWithFormat:@"%s/controlmap/mouse_pointer.png", getenv("POJAV_HOME")];
                    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
                    [NSNotificationCenter.defaultCenter postNotificationName:@"MousePointerUpdated" object:nil];
                    [self showSuccessMessage:localize(@"i18n_str_393", nil)];
                }
            },
            @{@"key": @"recording_hide",
                @"icon": @"eye.slash",
                @"hasDetail": @YES,
                @"type": self.typeSwitch,
            },
            
            // --- [重构] 双指呼出键盘控制 ---
            // 同样改为按钮+弹窗模式，彻底解决开关回弹问题
            @{@"key": @"two_finger_keyboard", 
              @"icon": @"keyboard", // 键盘图标
              @"hasDetail": @YES,
              @"type": self.typeButton, // 关键：改为 Button 类型
              
              @"action": ^void() {
                  // 1. 获取当前状态
                  BOOL isOn = getPrefBool(@"control.two_finger_keyboard");
                  
                  // 2. 构建弹窗
                  NSString *title = localize(@"preference.title.two_finger_keyboard", nil);
                  // 如果没有 localization，设置默认标题
                  if (!title || [title isEqualToString:@"preference.title.two_finger_keyboard"]) {
                      title = localize(@"i18n_str_394", nil);
                  }
                  
                  NSString *statusMsg = isOn ? localize(@"i18n_str_2053", nil) : localize(@"i18n_str_396", nil);
                  NSString *msg = [NSString stringWithFormat:localize(@"i18n_str_397", nil), statusMsg];
                  
                  UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
                  
                  // 3. 根据当前状态显示不同的按钮
                  if (!isOn) {
                      [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_398", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                          // 强制开启
                          setPrefBool(@"control.two_finger_keyboard", YES);
                          [weakSelf showSuccessMessage:localize(@"i18n_str_399", nil)];
                          // 刷新界面
                          [weakSelf.tableView reloadData];
                      }]];
                  } else {
                      [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_400", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
                          // 强制关闭
                          setPrefBool(@"control.two_finger_keyboard", NO);
                          [weakSelf showSuccessMessage:localize(@"i18n_str_401", nil)];
                          // 刷新界面
                          [weakSelf.tableView reloadData];
                      }]];
                  }
                  
                  [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
                  
                  [weakSelf presentViewController:alert animated:YES completion:nil];
              }
            },
            // -----------------------------
            
            @{@"key": @"gesture_mouse",
                @"icon": @"cursorarrow.click",
                @"hasDetail": @YES,
                @"type": self.typeSwitch,
            },
            @{@"key": @"gesture_hotbar",
                @"icon": @"hand.tap",
                @"hasDetail": @YES,
                @"type": self.typeSwitch,
            },
            @{@"key": @"disable_haptics",
                @"icon": @"wave.3.left",
                @"hasDetail": @YES,
                @"type": self.typeSwitch,
            },
            @{@"key": @"slideable_hotbar",
                @"hasDetail": @YES,
                @"icon": @"slider.horizontal.below.rectangle",
                @"type": self.typeSwitch,
                // --- [修改] 添加禁用条件 ---
                @"enableCondition": ^BOOL(){
                    // 当 TouchController 启用时，禁用此选项（返回 NO 表示禁用/变灰）
                    return ![self.getPreference(@"control", @"mod_touch_enable") boolValue];
                }
            },
            @{@"key": @"press_duration",
                @"hasDetail": @YES,
                @"icon": @"cursorarrow.click.badge.clock",
                @"type": self.typeSlider,
                @"min": @(100),
                @"max": @(1000),
            },
            @{@"key": @"button_scale",
                @"hasDetail": @YES,
                @"icon": @"aspectratio",
                @"type": self.typeSlider,
                @"min": @(50), // 80?
                @"max": @(500)
            },
            @{@"key": @"mouse_scale",
                @"hasDetail": @YES,
                @"icon": @"arrow.up.left.and.arrow.down.right.circle",
                @"type": self.typeSlider,
                @"min": @(25),
                @"max": @(300)
            },
            @{@"key": @"mouse_speed",
                @"hasDetail": @YES,
                @"icon": @"cursorarrow.motionlines",
                @"type": self.typeSlider,
                @"min": @(25),
                @"max": @(300)
            },
            @{@"key": @"virtmouse_enable",
                @"hasDetail": @YES,
                @"icon": @"cursorarrow.rays",
                @"type": self.typeSwitch
            },
            @{@"key": @"gyroscope_enable",
                @"hasDetail": @YES,
                @"icon": @"gyroscope",
                @"type": self.typeSwitch,
                @"enableCondition": ^BOOL(){
                    return realUIIdiom != UIUserInterfaceIdiomTV;
                }
            },
            @{@"key": @"gyroscope_invert_x_axis",
                @"hasDetail": @YES,
                @"icon": @"arrow.left.and.right",
                @"type": self.typeSwitch,
                @"enableCondition": ^BOOL(){
                    return realUIIdiom != UIUserInterfaceIdiomTV;
                }
            },
            @{@"key": @"gyroscope_sensitivity",
                @"hasDetail": @YES,
                @"icon": @"move.3d",
                @"type": self.typeSlider,
                @"min": @(50),
                @"max": @(300),
                @"enableCondition": ^BOOL(){
                    return realUIIdiom != UIUserInterfaceIdiomTV;
                }
            }
        ], @[
        // Java tweaks
            @{@"icon": @"sparkles"},
            @{@"key": @"manage_runtime",
                @"hasDetail": @YES,
                @"icon": @"cube",
                @"type": self.typeChildPane,
                @"canDismissWithSwipe": @YES,
                @"class": LauncherPrefManageJREViewController.class,
                @"enableCondition": whenNotInGame
            },
            @{@"key": @"java_args",
                @"hasDetail": @YES,
                @"icon": @"slider.vertical.3",
                @"type": self.typeTextField,
                @"enableCondition": whenNotInGame
            },
            @{@"key": @"env_variables",
                @"hasDetail": @YES,
                @"icon": @"terminal",
                @"type": self.typeTextField,
                @"enableCondition": whenNotInGame
            },
            @{@"key": @"auto_ram",
                @"hasDetail": @YES,
                @"icon": @"slider.horizontal.3",
                @"type": self.typeSwitch,
                @"enableCondition": whenNotInGame,
                @"warnCondition": ^BOOL(){
                    return !isJailbroken;
                },
                @"warnKey": @"auto_ram_warn",
                @"requestReload": @YES
            },
            @{@"key": @"allocated_memory",
                @"hasDetail": @YES,
                @"icon": @"memorychip",
                @"type": self.typeSlider,
                @"min": @(250),
                @"max": @((NSProcessInfo.processInfo.physicalMemory / 1048576) * 0.85),
                @"enableCondition": ^BOOL(){
                    return !getPrefBool(@"java.auto_ram") && whenNotInGame();
                },
                @"warnCondition": ^BOOL(DBNumberedSlider *view){
                    return view.value >= NSProcessInfo.processInfo.physicalMemory / 1048576 * 0.37;
                },
                @"warnKey": @"mem_warn"
            }
        ], @[
            // Debug settings - only recommended for developer use
            @{@"icon": @"ladybug"},
            @{@"key": @"debug_universal_script_jit",
                @"icon": @"scroll",
                @"type": self.typeSwitch,
                @"requestReload": @YES,
                @"enableCondition": ^BOOL(){
                    // 同步自 catsruledogs：用 DeviceNeedsDebugJITMapping() 替代旧的 TXM 标志组合
                    // 基于 JIT_FLAG_IS_IOS_26 | JIT_FLAG_FORCE_MIRRORED，确保 iOS 26+ 无 TXM 设备也显示此开关
                    return DeviceNeedsDebugJITMapping() && whenNotInGame();
                },
            },
            @{@"key": @"debug_always_attached_jit",
                @"hasDetail": @YES,
                @"icon": @"app.connected.to.app.below.fill",
                @"type": self.typeSwitch,
                @"enableCondition": ^BOOL(){
                    return getPrefBool(@"debug.debug_universal_script_jit") && whenNotInGame();
                },
            },
            @{@"key": @"debug_skip_wait_jit",
                @"hasDetail": @YES,
                @"icon": @"forward",
                @"type": self.typeSwitch,
                @"enableCondition": whenNotInGame
            },
            @{@"key": @"debug_hide_home_indicator",
                @"hasDetail": @YES,
                @"icon": @"iphone.and.arrow.forward",
                @"type": self.typeSwitch,
                @"enableCondition": ^BOOL(){
                    return
                        self.splitViewController.view.safeAreaInsets.bottom > 0 ||
                        self.view.safeAreaInsets.bottom > 0;
                }
            },
            @{@"key": @"debug_ipad_ui",
                @"hasDetail": @YES,
                @"icon": @"ipad",
                @"type": self.typeSwitch,
                @"enableCondition": whenNotInGame
            },
            @{@"key": @"debug_auto_correction",
                @"hasDetail": @YES,
                @"icon": @"textformat.abc.dottedunderline",
                @"type": self.typeSwitch
            }
        ], @[
            // AI 助手 settings（Air AI Agent Phase 2）
            @{@"icon": @"sparkles"},
            @{@"key": @"provider_config",
              @"title": @"提供商配置",
              @"icon": @"globe.asia.australia.fill",
              @"type": self.typeButton,
              @"action": ^void(){
                  AIProviderConfigViewController *vc = [[AIProviderConfigViewController alloc] init];
                  UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
                  nav.modalPresentationStyle = UIModalPresentationFormSheet;
                  [self presentViewController:nav animated:YES completion:nil];
              }
            },
            @{@"key": @"session_list",
              @"title": @"会话列表",
              @"icon": @"rectangle.stack.badge.person.crop",
              @"type": self.typeButton,
              @"action": ^void(){
                  AISessionListViewController *vc = [[AISessionListViewController alloc] init];
                  UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
                  nav.modalPresentationStyle = UIModalPresentationFormSheet;
                  [self presentViewController:nav animated:YES completion:nil];
              }
            },
            @{@"key": @"safety_mode",
              @"title": @"默认安全模式",
              @"icon": @"hand.raised.fill",
              @"type": self.typePickField,
              @"pickKeys": @[
                  @"只读自动执行（Safe）",
                  @"写操作逐次确认（Ask）",
                  @"自动批准（YOLO）"
              ],
              @"pickList": @[
                  @"只读自动执行（Safe）",
                  @"写操作逐次确认（Ask）",
                  @"自动批准（YOLO）"
              ]
            },
            @{@"key": @"markdown_enabled",
              @"title": @"Markdown 渲染",
              @"icon": @"textformat",
              @"type": self.typeSwitch
            },
            @{@"key": @"system_prompt",
              @"title": @"系统提示词",
              @"icon": @"text.book.closed.fill",
              @"type": self.typeButton,
              @"action": ^void(){
                  AISystemPromptEditorViewController *vc = [[AISystemPromptEditorViewController alloc] init];
                  UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
                  nav.modalPresentationStyle = UIModalPresentationFormSheet;
                  [self presentViewController:nav animated:YES completion:nil];
              }
            }
        ]
    ];

    [super viewDidLoad];
    // 适配自定义启动器背景：通过 BackgroundManager 将当前视图控制器透明化，
    // 让全局背景容器（图片/视频）能够透出显示。必须在 super viewDidLoad 之后调用，
    // 以确保 view 与 tableView 均已就绪。
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // 顶部 Hero 卡片：App 名 + 版本 + 设备信息（参照 Air-Design v1.2 L3 大卡片规范）
    // 与搜索栏一起包装为 tableHeaderView，搜索栏在上、Hero 卡片在下
    [self setupHeroHeader];

    // Apply transparent background if global background is active
    if ([[BackgroundManager sharedManager] hasBackground]) {
        self.view.backgroundColor = [UIColor clearColor];
        self.tableView.backgroundColor = [UIColor clearColor];
        self.tableView.backgroundView = nil;
        
        // Make separator visible on background
        self.tableView.separatorEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        self.tableView.separatorColor = [UIColor colorWithWhite:1.0 alpha:0.2];
    }
    
    if (self.navigationController == nil) {
        self.tableView.alpha = 0.9;
    }
    if (NSProcessInfo.processInfo.isMacCatalystApp) {
        UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeClose];
        closeButton.frame = CGRectOffset(closeButton.frame, 10, 10);
        [closeButton addTarget:self action:@selector(actionClose) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:closeButton];
    }
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleBackgroundUIEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    // 监听背景 UI 效果变化通知：当用户在背景设置中切换毛玻璃/半透明或调整透明度时，
    // 重新调用 makeViewControllerTransparent 以应用最新的视觉效果，保证背景始终正确透出。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(openCurseForgeAPIKeySettings)
                                                 name:@"OpenCurseForgeAPIKeySettings"
                                               object:nil];
}

#pragma mark - Hero Header（顶部 App 信息卡片）

- (NSString *)appName {
    // 优先使用 CFBundleDisplayName（用户可见名称），其次 CFBundleName，兜底 "Air"
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *name = info[@"CFBundleDisplayName"];
    if (name.length == 0) {
        name = info[@"CFBundleName"];
    }
    return name.length ? name : @"Air";
}

- (void)setupHeroHeader {
    // 父类 viewDidLoad 已将 searchController.searchBar 设置为 tableHeaderView
    // 这里取出 searchBar，与 Hero 卡片一起重新包装为新的 tableHeaderView
    // 注意：searchController 是父类 PLPrefTableViewController 的私有属性，子类无法直接访问，
    // 但父类已将 searchBar 设置为 tableView.tableHeaderView，可直接取出。
    UISearchBar *searchBar = nil;
    UIView *currentHeader = self.tableView.tableHeaderView;
    if ([currentHeader isKindOfClass:[UISearchBar class]]) {
        searchBar = (UISearchBar *)currentHeader;
    }
    [searchBar removeFromSuperview];

    // 让 searchBar 适配自定义背景（透明、文字色跟随系统）
    searchBar.barTintColor = [UIColor clearColor];
    searchBar.tintColor = accentColor();
    searchBar.backgroundImage = [UIImage new]; // 去掉默认背景
    if (@available(iOS 13.0, *)) {
        searchBar.searchTextField.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    }

    // ===== Hero 卡片（L3 大卡片：16pt 圆角 + 半透明背景 + 毛玻璃 + 浅边框 + 中阴影）=====
    UIView *heroCard = [[UIView alloc] init];
    heroCard.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.14]; // surface-bright
    heroCard.layer.cornerRadius = 16;
    heroCard.layer.cornerCurve = kCACornerCurveContinuous;
    heroCard.layer.borderWidth = 0.5;
    heroCard.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    heroCard.layer.shadowColor = [UIColor blackColor].CGColor;
    heroCard.layer.shadowOpacity = 0.12;
    heroCard.layer.shadowRadius = 8;
    heroCard.layer.shadowOffset = CGSizeMake(0, 3);
    [[BackgroundManager sharedManager] applyEffectToView:heroCard];

    // Hero 图标（56x56，14pt 圆角，accentColor 纯色背景，白色 SF Symbol）
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.image = [UIImage systemImageNamed:@"cube.fill"];
    iconView.tintColor = [UIColor whiteColor];
    iconView.contentMode = UIViewContentModeCenter;
    iconView.backgroundColor = accentColor();
    iconView.layer.cornerRadius = 14;
    iconView.layer.cornerCurve = kCACornerCurveContinuous;
    iconView.layer.masksToBounds = YES;
    [heroCard addSubview:iconView];

    // 标题（App 名，17pt bold，labelColor）
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = [self appName];
    titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    titleLabel.textColor = [UIColor labelColor];
    titleLabel.adjustsFontSizeToFitWidth = YES;
    titleLabel.minimumScaleFactor = 0.8;
    [heroCard addSubview:titleLabel];

    // 副标题（第一行 App 版本，第二行 设备名 · iOS 系统版本）
    UILabel *subtitleLabel = [[UILabel alloc] init];
    NSString *appVersion = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"1.0";
    NSString *deviceName = [HostManager GetModelName] ?: UIDevice.currentDevice.name ?: @"iPhone";
    NSString *systemVersion = UIDevice.currentDevice.systemVersion ?: @"";
    NSString *subtitle = [NSString stringWithFormat:@"v%@\n%@ · iOS %@", appVersion, deviceName, systemVersion];
    subtitleLabel.text = subtitle;
    subtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.numberOfLines = 0;
    [heroCard addSubview:subtitleLabel];

    // 右侧 chevron（12x12，tertiary-labelColor）
    UIImageView *chevronView = [[UIImageView alloc] init];
    chevronView.image = [UIImage systemImageNamed:@"chevron.right"];
    chevronView.tintColor = [UIColor tertiaryLabelColor];
    chevronView.contentMode = UIViewContentModeScaleAspectFit;
    [heroCard addSubview:chevronView];

    self.heroCard = heroCard;

    // ===== 容器视图：searchBar（上）+ heroCard（下）=====
    UIView *container = [[UIView alloc] init];
    [container addSubview:searchBar];
    [container addSubview:heroCard];

    // 启用 AutoLayout
    searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    heroCard.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    chevronView.translatesAutoresizingMaskIntoConstraints = NO;

    [NSLayoutConstraint activateConstraints:@[
        // searchBar：贴顶部、左右贴边
        [searchBar.topAnchor constraintEqualToAnchor:container.topAnchor],
        [searchBar.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [searchBar.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],

        // heroCard：左右 16pt 外边距，顶部距 searchBar 8pt，底部距容器 8pt
        [heroCard.topAnchor constraintEqualToAnchor:searchBar.bottomAnchor constant:8],
        [heroCard.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [heroCard.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [heroCard.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8],

        // iconView：56x56，左侧 16pt、上下 16pt
        [iconView.leadingAnchor constraintEqualToAnchor:heroCard.leadingAnchor constant:16],
        [iconView.topAnchor constraintEqualToAnchor:heroCard.topAnchor constant:16],
        [iconView.bottomAnchor constraintEqualToAnchor:heroCard.bottomAnchor constant:-16],
        [iconView.widthAnchor constraintEqualToConstant:56],
        [iconView.heightAnchor constraintEqualToConstant:56],

        // titleLabel：位于 iconView 右侧 14pt，顶部 18pt
        [titleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:14],
        [titleLabel.topAnchor constraintEqualToAnchor:heroCard.topAnchor constant:18],
        [titleLabel.trailingAnchor constraintEqualToAnchor:chevronView.leadingAnchor constant:-8],

        // subtitleLabel：紧跟 titleLabel 下方 2pt
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:14],
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:2],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:chevronView.leadingAnchor constant:-8],
        [subtitleLabel.bottomAnchor constraintEqualToAnchor:heroCard.bottomAnchor constant:-16],

        // chevronView：12x12，右侧 16pt，垂直居中
        [chevronView.trailingAnchor constraintEqualToAnchor:heroCard.trailingAnchor constant:-16],
        [chevronView.centerYAnchor constraintEqualToAnchor:heroCard.centerYAnchor],
        [chevronView.widthAnchor constraintEqualToConstant:12],
        [chevronView.heightAnchor constraintEqualToConstant:12],
    ]];

    // UITableView 不会根据 AutoLayout 自动计算 tableHeaderView 高度，
    // 需要手动布局并设置 frame。使用 systemLayoutSizeFitting 计算合适高度。
    CGFloat width = self.tableView.bounds.size.width;
    if (width == 0) width = [UIScreen mainScreen].bounds.size.width;
    container.frame = CGRectMake(0, 0, width, 0);
    [container setNeedsLayout];
    [container layoutIfNeeded];
    CGFloat fittingHeight = [container systemLayoutSizeFittingSize:CGSizeMake(width, 0)
                                               withHorizontalFittingPriority:UILayoutPriorityRequired
                                                     verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    container.frame = CGRectMake(0, 0, width, fittingHeight);

    self.tableView.tableHeaderView = container;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"BackgroundUIEffectChanged" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"OpenCurseForgeAPIKeySettings" object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    // 重新隐藏导航栏黑条（pop 回根页面时 topViewController == self）
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil &&
        self.navigationController.topViewController == self) {
        self.navigationController.navigationBarHidden = YES;
    }

    // Re-apply transparency when appearing (in case background was just set)
    if ([[BackgroundManager sharedManager] hasBackground]) {
        self.view.backgroundColor = [UIColor clearColor];
        self.tableView.backgroundColor = [UIColor clearColor];
        self.tableView.backgroundView = nil;
        
        // Refresh cells to apply background styling
        [self.tableView reloadData];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // push 子页面时显示导航栏（子页面需要返回按钮）
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil) {
        self.navigationController.navigationBarHidden = NO;
    }
    if (self.navigationController == nil) {
        [self.presentingViewController performSelector:@selector(updatePreferenceChanges)];
    }
}

- (void)actionClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)handleBackgroundUIEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.tableView reloadData];
    });
}

/// 重新应用背景效果：当 BackgroundUIEffectChanged 通知到达时调用，
/// 通过 BackgroundManager 重新设置当前视图控制器的透明度/毛玻璃效果，
/// 并将 tableView 背景置为透明、移除默认 backgroundView，确保全局背景能够正常透出。
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
}

#pragma mark - Check For Update

/// 设置页"检查更新"入口：调用 UpdateChecker 检查正式版更新，弹窗显示结果。
- (void)checkForUpdateFromSettings {
    /* 显示加载中的 alert */
    UIAlertController *loadingAlert = [UIAlertController
        alertControllerWithTitle:localize(@"check_update.checking", @"正在检查更新…")
                         message:nil
                  preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:loadingAlert animated:YES completion:nil];

    [UpdateChecker checkForUpdateWithCompletion:^(UpdateInfo *info, NSError *error) {
        [loadingAlert dismissViewControllerAnimated:YES completion:^{
            if (error || info == nil) {
                [self showUpdateAlertWithTitle:localize(@"check_update.failed", @"检查更新失败")
                                         message:error.localizedDescription ?: localize(@"i18n_str_97", nil)
                                       hasUpdate:NO
                                          info:nil];
                return;
            }
            if (info.hasUpdate) {
                [self showUpdateAvailableAlert:info];
            } else {
                [self showUpdateAlertWithTitle:localize(@"check_update.up_to_date", @"已是最新版本")
                                         message:[NSString stringWithFormat:
                                             localize(@"check_update.current_version", @"当前版本 %@，已是最新正式版。"),
                                             info.currentVersion]
                                       hasUpdate:NO
                                          info:nil];
            }
        }];
    }];
}

- (void)showUpdateAlertWithTitle:(NSString *)title
                         message:(NSString *)message
                       hasUpdate:(BOOL)hasUpdate
                          info:(nullable UpdateInfo *)info {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", @"好的")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// 发现新版本时显示更新详情弹窗（参考 FCL/ZL2 风格）
- (void)showUpdateAvailableAlert:(UpdateInfo *)info {
    NSString *title = [NSString stringWithFormat:localize(@"check_update.new_version_title",
                                                          localize(@"i18n_str_407", nil)), info.latestVersion];
    /* 更新日志截断显示，太长的话只显示前 500 字符 + 省略号 */
    NSString *notes = info.releaseNotes ?: @"";
    if (notes.length > 500) {
        notes = [[notes substringToIndex:500] stringByAppendingString:@"…"];
    }
    NSString *message = [NSString stringWithFormat:@"%@\n\n%@",
                         localize(@"check_update.new_version_message",
                                  localize(@"i18n_str_408", nil)),
                         notes];

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"check_update.download", @"前往下载")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [UpdateChecker openReleasePage];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", @"取消")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Memory Limit Help

- (void)showMemoryLimitHelp {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"mem_help.title", @"关于内存限制")
                         message:localize(@"mem_help.message",
                             @"iOS 18 / iOS 26 单实例内存上限约为 1440MB，玩大型整合包时可能因内存不足崩溃。\n\n"
                              "解决方法：\n"
                              "使用 GetMoreRam (LiveContainer 插件) 解除内存限制。\n"
                              "GetMoreRam 仓库：github.com/hugeBlack/GetMoreRam\n\n"
                              "安装后重启启动器即可生效。\n\n"
                              "如果不使用 LiveContainer，可尝试降低内存分配（设置 > Java > 内存分配），"
                              "但部分整合包在内存限制下可能无法正常运行。")
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"GetMoreRam"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        NSURL *url = [NSURL URLWithString:@"https://github.com/hugeBlack/GetMoreRam"];
        if (@available(iOS 10.0, *)) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - CurseForge API Key Settings

- (void)openCurseForgeAPIKeySettings {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 通过 UIScene 获取顶层 VC（不使用 keyWindow）
        UIViewController *topVC = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                topVC = windowScene.windows.firstObject.rootViewController;
                if (topVC) {
                    break;
                }
            }
        }
        if (!topVC) {
            // 退而求其次：取任意一个 UIWindowScene
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    UIWindowScene *windowScene = (UIWindowScene *)scene;
                    topVC = windowScene.windows.firstObject.rootViewController;
                    if (topVC) {
                        break;
                    }
                }
            }
        }
        if (!topVC) {
            return;
        }

        while (topVC.presentedViewController) {
            topVC = topVC.presentedViewController;
        }

        CurseForgeAPIKeyViewController *vc = [[CurseForgeAPIKeyViewController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [topVC presentViewController:nav animated:YES completion:nil];
    });
}

#pragma mark - UITableView Data Source Override

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];

    // ===== iOS 设置 App 风格：彩色圆角图标背景 =====
    // 参照 iOS 设置应用：每个设置项左侧图标用带颜色的圆角方块背景包裹，
    // 图标本身渲染为白色 SF Symbol。不同 section 用不同颜色区分：
    //   general=蓝 / video=紫 / control=绿 / java=橙 / debug=红
    // destructive（危险操作）项统一用红色背景。
    // 搜索结果模式下用蓝灰色背景。
    [self applySettingsAppStyleToCell:cell indexPath:indexPath];

    // Apply background styling if global background is active
    if ([[BackgroundManager sharedManager] hasBackground]) {
        // Set semi-transparent dark background for cells
        [[BackgroundManager sharedManager] applyEffectToCell:cell];

        // Set white text for better visibility on dark background
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.textLabel.shadowColor = [UIColor blackColor];
        cell.textLabel.shadowOffset = CGSizeMake(0, 1);

        // Detail text light gray
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
        cell.detailTextLabel.shadowColor = [UIColor blackColor];
        cell.detailTextLabel.shadowOffset = CGSizeMake(0, 1);

        // Tint color for icons and accessories：使用主题强调色（accentColor）
        cell.tintColor = accentColor();

        // Handle specific cell types
        NSArray *subviews = cell.contentView.subviews;
        for (UIView *subview in subviews) {
            // Style sliders
            if ([subview isKindOfClass:[UISlider class]]) {
                UISlider *slider = (UISlider *)subview;
                slider.tintColor = accentColor();
                slider.thumbTintColor = [UIColor whiteColor];
            }

            // Style switches
            if ([subview isKindOfClass:[UISwitch class]]) {
                UISwitch *switchControl = (UISwitch *)subview;
                switchControl.onTintColor = accentColor();
            }

            // Style text fields
            if ([subview isKindOfClass:[UITextField class]]) {
                UITextField *textField = (UITextField *)subview;
                textField.textColor = [UIColor whiteColor];
                textField.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.6];
                textField.layer.cornerRadius = 8;
            }

            // Style labels
            if ([subview isKindOfClass:[UILabel class]]) {
                UILabel *label = (UILabel *)subview;
                label.textColor = [UIColor whiteColor];
                label.shadowColor = [UIColor blackColor];
                label.shadowOffset = CGSizeMake(0, 1);
            }
        }

        // Style the picker label if exists
        if (cell.accessoryView && [cell.accessoryView isKindOfClass:[UILabel class]]) {
            UILabel *pickerLabel = (UILabel *)cell.accessoryView;
            pickerLabel.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
        }
    } else {
        // Reset to default when no background
        cell.backgroundColor = [UIColor secondarySystemBackgroundColor];
        cell.textLabel.textColor = [UIColor labelColor];
        cell.textLabel.shadowColor = nil;
        cell.textLabel.shadowOffset = CGSizeZero;
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.shadowColor = nil;
        cell.detailTextLabel.shadowOffset = CGSizeZero;
    }

    return cell;
}

/// iOS 设置 App 风格图标背景：给 cell.imageView 加圆角彩色背景 + 白色图标
/// 参照 iOS 设置应用（General=灰、Display=蓝、Privacy=蓝 等彩色圆角图标）
/// 在 cellForRow 中调用，仅做视觉装饰，不改变 cell 数据或交互逻辑
- (void)applySettingsAppStyleToCell:(UITableViewCell *)cell indexPath:(NSIndexPath *)indexPath {
    UIImageView *iconView = cell.imageView;
    if (!iconView) return;

    // 判断是否为 section header 行（row 0 且有 prefSections）
    // section header 行不加彩色背景，保持原始样式（避免与组内项视觉混淆）
    BOOL isSectionHeader = (indexPath.row == 0 && self.prefSections && !self.filteredItems);
    if (isSectionHeader) {
        // section header：恢复默认 tint（不加背景），让图标保持系统默认外观
        iconView.backgroundColor = [UIColor clearColor];
        iconView.layer.cornerRadius = 0;
        iconView.layer.masksToBounds = NO;
        // section header 图标用主题强调色（accentColor），与启动按钮/菜单选中态统一
        iconView.tintColor = accentColor();
        return;
    }

    // 获取当前项的数据
    NSDictionary *item = nil;
    if (self.filteredItems) {
        // 搜索结果模式
        item = self.filteredItems[indexPath.row];
    } else if (self.prefSections && indexPath.section < (NSInteger)self.prefContents.count) {
        NSArray *sectionItems = self.prefContents[indexPath.section];
        if (indexPath.row < (NSInteger)sectionItems.count) {
            item = sectionItems[indexPath.row];
        }
    }

    // 判断是否为危险操作项
    BOOL destructive = [item[@"destructive"] boolValue];

    // 获取图标名，用 UIImageSymbolConfiguration 重新渲染为白色、合适大小的 SF Symbol
    NSString *iconName = item[@"icon"];
    UIImage *styledIcon = nil;
    if (iconName.length > 0) {
        // 用 UIImageSymbolConfiguration 控制图标大小和颜色
        // pointSize 16 适配默认 UITableViewCell imageView 的 29pt 尺寸（留出内边距）
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16
                                                                                            weight:UIFontWeightMedium];
        styledIcon = [UIImage systemImageNamed:iconName withConfiguration:config];
        if (!styledIcon) {
            styledIcon = [UIImage systemImageNamed:iconName];
        }
    }

    // 设置图标：白色模板渲染，在彩色背景上显示
    if (styledIcon) {
        // withTintColor 让 SF Symbol 以白色渲染（模板模式），与背景色搭配
        UIImage *whiteIcon = [styledIcon imageWithTintColor:[UIColor whiteColor]
                                               renderingMode:UIImageRenderingModeAlwaysOriginal];
        iconView.image = whiteIcon;
    }
    iconView.tintColor = [UIColor whiteColor];
    iconView.contentMode = UIViewContentModeCenter;

    // 设置彩色圆角背景
    UIColor *bgColor = [self iconBackgroundColorForItem:item indexPath:indexPath destructive:destructive];
    iconView.backgroundColor = bgColor;
    iconView.layer.cornerRadius = 7;
    iconView.layer.cornerCurve = kCACornerCurveContinuous;
    iconView.layer.masksToBounds = YES;
}

/// 根据设置项所属 section 与图标名返回 iOS 设置 App 风格的彩色背景
/// 参照 iOS 设置应用：不同功能模块用不同颜色区分，一眼可辨识归属
- (UIColor *)iconBackgroundColorForItem:(NSDictionary *)item
                              indexPath:(NSIndexPath *)indexPath
                             destructive:(BOOL)destructive {
    // 危险操作项统一红色背景
    if (destructive) {
        return [UIColor systemRedColor];
    }

    // 搜索结果模式：统一用蓝灰色背景
    if (self.filteredItems) {
        NSNumber *origSection = item[@"__origSection"];
        if (origSection) {
            return [self colorForPreferenceSection:origSection.intValue];
        }
        return [UIColor systemBlueColor];
    }

    // 正常模式：按 section 着色
    return [self colorForPreferenceSection:indexPath.section];
}

/// section 索引 → 配色映射（参照 iOS 设置应用的模块色系）
/// general=蓝（通用设置）/ video=紫（显示）/ control=绿（控制）/ java=橙（运行时）/ debug=红（调试）
- (UIColor *)colorForPreferenceSection:(NSInteger)section {
    if (!self.prefSections || section >= (NSInteger)self.prefSections.count) {
        return [UIColor systemGrayColor];
    }
    NSString *sectionKey = self.prefSections[section];
    if ([sectionKey isEqualToString:@"general"]) {
        return [UIColor systemBlueColor];
    } else if ([sectionKey isEqualToString:@"video"]) {
        return [UIColor systemPurpleColor];
    } else if ([sectionKey isEqualToString:@"mobileglues"]) {
        return [UIColor systemIndigoColor];
    } else if ([sectionKey isEqualToString:@"control"]) {
        return [UIColor systemGreenColor];
    } else if ([sectionKey isEqualToString:@"java"]) {
        return [UIColor systemOrangeColor];
    } else if ([sectionKey isEqualToString:@"debug"]) {
        return [UIColor systemRedColor];
    }
    return [UIColor systemGrayColor];
}

#pragma mark - UITableView Delegate

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) { // Add to general section
        NSString *versionString = [NSString stringWithFormat:@"Amethyst iOS Remastered %@\n%@ on %@ (%s)\nPID: %d",
            NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"],
            UIDevice.currentDevice.completeOSVersion, [HostManager GetModelName], getenv("POJAV_DETECTEDINST"), getpid()];
        
        // Style footer for background if needed
        if ([[BackgroundManager sharedManager] hasBackground]) {
            // Footer text is handled by the table view, but we can ensure visibility
            // by making sure the section has appropriate styling
        }
        
        return versionString;
    }

    NSString *footer = NSLocalizedStringWithDefaultValue(([NSString stringWithFormat:@"preference.section.footer.%@", self.prefSections[section]]), @"Localizable", NSBundle.mainBundle, @" ", nil);
    if ([footer isEqualToString:@" "]) {
        return nil;
    }
    return footer;
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    // Style section headers for background visibility
    if ([[BackgroundManager sharedManager] hasBackground]) {
        if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
            UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
            header.textLabel.textColor = [UIColor whiteColor];
            header.textLabel.shadowColor = [UIColor blackColor];
            header.textLabel.shadowOffset = CGSizeMake(0, 1);
            header.backgroundView = [[UIView alloc] init];
            header.backgroundView.backgroundColor = [UIColor clearColor];
        }
    }
}

/// 重写子页面跳转：为 CustomControlsViewController 设置必需的回调块
- (void)tableView:(UITableView *)tableView openChildPaneAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];

    // 特殊处理：键位调整界面需要 setDefaultCtrl / getDefaultCtrl 回调
    if ([item[@"key"] isEqualToString:@"custom_controls"]) {
        CustomControlsViewController *vc = [[CustomControlsViewController alloc] init];
        vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
        vc.setDefaultCtrl = ^(NSString *name){
            setPrefObject(@"control.default_ctrl", name);
        };
        vc.getDefaultCtrl = ^{
            return getPrefObject(@"control.default_ctrl");
        };
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.navigationBar.prefersLargeTitles = YES;
        nav.modalInPresentation = YES;
        [self.navigationController presentViewController:nav animated:YES completion:nil];
        return;
    }

    // 其他设置项走父类默认逻辑
    [super tableView:tableView openChildPaneAtIndexPath:indexPath];
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    // Style section footers for background visibility
    if ([[BackgroundManager sharedManager] hasBackground]) {
        if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
            UITableViewHeaderFooterView *footer = (UITableViewHeaderFooterView *)view;
            footer.textLabel.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
            footer.textLabel.shadowColor = [UIColor blackColor];
            footer.textLabel.shadowOffset = CGSizeMake(0, 1);
            footer.backgroundView = [[UIView alloc] init];
            footer.backgroundView.backgroundColor = [UIColor clearColor];
        }
    }
}

@end
