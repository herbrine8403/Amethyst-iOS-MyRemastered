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

@interface LauncherPreferencesViewController()
@property(nonatomic) NSArray<NSString*> *rendererKeys, *rendererList;
@property(nonatomic) BOOL pickingMousePointer;
@end

@implementation LauncherPreferencesViewController

- (id)init {
    self = [super init];
    self.title = localize(@"Settings", nil);
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

#pragma mark - UIImagePickerControllerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    [picker dismissViewControllerAnimated:YES completion:^{
        // 在图片选择器完全关闭后再处理图片
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImage *selectedImage = info[UIImagePickerControllerOriginalImage];
            if (!selectedImage) {
                [self showCustomIconError:@"无法获取选中的图片"];
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
                    [self showSuccessMessage:@"鼠标指针已更新"];
                } else {
                    [self showCustomIconError:@"保存鼠标指针失败"];
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
                                    [weakSelf showSuccessMessage:@"图片已保存，您可以在应用图标设置中选择自定义图标"];
                                    // 更新应用图标选择器的显示
                                    [weakSelf.tableView reloadData];
                                } else {
                                    NSString *errorMessage = error.localizedDescription ?: @"保存自定义图标失败";
                                    [weakSelf showCustomIconError:errorMessage];
                                }
                            });
                        }];
                    } else {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [weakSelf showCustomIconError:@"图片裁剪已取消"];
                        });
                    }
                };
                [weakSelf.navigationController pushViewController:cropperVC animated:YES];
            } else {
                // 如果是正方形，直接保存
                [[CustomIconManager sharedManager] saveCustomIcon:selectedImage withCompletion:^(BOOL success, NSError * _Nullable error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (success) {
                            [self showSuccessMessage:@"图片已保存，您可以在应用图标设置中选择自定义图标"];
                            // 更新应用图标选择器的显示
                            [self.tableView reloadData];
                        } else {
                            NSString *errorMessage = error.localizedDescription ?: @"保存自定义图标失败";
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
                [self showCustomIconError:@"图片选择已取消"];
            }
        });
    }];
}

#pragma mark - Custom Icon Helper Methods

- (void)showProcessingIndicator {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"处理中" message:@"正在处理您选择的图片..." preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:nil];
    
    // 2秒后自动关闭提示
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [alert dismissViewControllerAnimated:YES completion:nil];
    });
}

- (void)showSuccessMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"成功" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:okAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showCustomIconError:(NSString *)errorMessage {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"错误" message:errorMessage preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:okAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)viewDidLoad
{
    self.getPreference = ^id(NSString *section, NSString *key){
        NSString *keyFull = [NSString stringWithFormat:@"%@.%@", section, key];
        return getPrefObject(keyFull);
    };
    self.setPreference = ^(NSString *section, NSString *key, id value){
        NSString *keyFull = [NSString stringWithFormat:@"%@.%@", section, key];
        setPrefObject(keyFull, value);
    };
    
    self.hasDetail = YES;
    self.prefDetailVisible = self.navigationController == nil;
    
    self.prefSections = @[@"general", @"video", @"control", @"java", @"debug"];

    self.rendererKeys = getRendererKeys(NO);
    self.rendererList = getRendererNames(NO);
    
    BOOL(^whenNotInGame)() = ^BOOL(){
        return self.navigationController != nil;
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
    
    // --- 定义 helper：修改环境变量的 Block ---
    void (^toggleTouchEnvVar)(BOOL) = ^(BOOL enable) {
        NSString *envKey = @"java.env_variables";
        NSString *targetEnv = @"TOUCH_CONTROLLER_PROXY=12450";
        NSString *currentEnv = getPrefObject(envKey);
        if (![currentEnv isKindOfClass:[NSString class]]) currentEnv = @"";
        
        NSMutableArray *parts = [[currentEnv componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] mutableCopy];
        if (!parts) parts = [NSMutableArray array];
        [parts filterUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        
        NSMutableArray *newParts = [NSMutableArray array];
        for (NSString *part in parts) {
            if (![part containsString:@"TOUCH_CONTROLLER_PROXY="]) {
                [newParts addObject:part];
            }
        }
        
        if (enable) {
            [newParts addObject:targetEnv];
        }
        
        NSString *finalEnv = [newParts componentsJoinedByString:@" "];
        setPrefObject(envKey, finalEnv);
        setPrefBool(@"control.mod_touch_udp", enable); // 同步保存偏好布尔值
        
        dispatch_async(dispatch_get_main_queue(), ^{
             [weakSelf showSuccessMessage:enable ? @"UDP 协议已开启 (环境变量已添加)" : @"UDP 协议已关闭 (环境变量已移除)"];
             [weakSelf.tableView reloadData]; // 刷新列表以更新 slideable_hotbar 状态
        });
    };
    // -----------------------------------------------------------

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
              @"enableCondition": ^BOOL(){
                  return NO;
              },
              @"action": ^void(NSString *iconName) {
                  if ([iconName isEqualToString:@"AppIcon-Light"]) {
                      iconName = nil;
                      [[CustomIconManager sharedManager] removeCustomIcon];
                  } else if ([iconName isEqualToString:@"CustomIcon"]) {
                      if (![[CustomIconManager sharedManager] hasCustomIcon]) {
                          dispatch_async(dispatch_get_main_queue(), ^{
                              UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" message:@"请先设置自定义应用图标：设置 > 自定义应用图标" preferredStyle:UIAlertControllerStyleAlert];
                              UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil];
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
            @{@"key": @"hidden_sidebar",
              @"hasDetail": @YES,
              @"icon": @"sidebar.leading",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"news_url",
              @"hasDetail": @YES,
              @"icon": @"link",
              @"type": self.typeTextField,
              @"placeholder": @"https://amethyst.ct.ws/welcome",
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"reset_news_url",
              @"icon": @"arrow.counterclockwise",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  setPrefObject(@"general.news_url", nil);
              }
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
            @{@"key": @"max_framerate",
              @"hasDetail": @YES,
              @"icon": @"timelapse",
              @"type": self.typeSwitch,
              @"enableCondition": ^BOOL(){
                  return whenNotInGame() && (UIScreen.mainScreen.maximumFramesPerSecond > 60);
              }
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
            // Control settings
            @{@"icon": @"gamecontroller"},
            
            // --- [修改] TouchController 模组支持开关 ---
            @{@"key": @"mod_touch_enable",
              @"icon": @"hand.point.up.left", // SF Symbols 图标
              @"hasDetail": @YES,
              @"type": self.typeSwitch,
              @"requestReload": @YES,
              @"action": showTouchInfoAlert 
            },
            
            // --- [重构] TouchController UDP 协议控制 ---
            // 采用按钮+弹窗模式，彻底解决开关状态不同步问题
            @{@"key": @"mod_touch_udp",
              @"icon": @"antenna.radiowaves.left.and.right",
              @"hasDetail": @YES,
              @"type": self.typeButton, // 改为按钮类型，点击触发事件
              @"enableCondition": whenNotInGame,
              
              @"action": ^void() {
                  // 1. 读取当前状态 (通过检查环境变量字符串)
                  NSString *currentEnv = getPrefObject(@"java.env_variables");
                  BOOL isOn = [currentEnv isKindOfClass:[NSString class]] && [currentEnv containsString:@"TOUCH_CONTROLLER_PROXY=12450"];
                  
                  // 2. 构建弹窗
                  NSString *title = localize(@"preference.title.mod_touch_udp", nil);
                  // 构建状态提示信息
                  NSString *statusMsg = isOn ? @"✅ 当前状态: 已开启 (ON)" : @"❌ 当前状态: 已关闭 (OFF)";
                  NSString *msg = [NSString stringWithFormat:@"%@\n\n此选项直接修改环境变量。\n开启此功能需要在启动游戏前设置。游戏运行中无法更改。", statusMsg];
                  
                  UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
                  
                  // 3. 根据当前状态添加操作按钮
                  if (!isOn) {
                      [alert addAction:[UIAlertAction actionWithTitle:@"开启 UDP 协议 (Enable)" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                          toggleTouchEnvVar(YES); // 开启逻辑
                      }]];
                  } else {
                      [alert addAction:[UIAlertAction actionWithTitle:@"关闭 UDP 协议 (Disable)" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
                          toggleTouchEnvVar(NO); // 关闭逻辑
                      }]];
                  }
                  
                  // 4. 其他按钮
                  [alert addAction:[UIAlertAction actionWithTitle:@"查看说明" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                       showTouchInfoAlert(YES);
                  }]];
                  
                  [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
                  
                  [weakSelf presentViewController:alert animated:YES completion:nil];
              }
            },
            // ------------------------------------------

            @{@"key": @"default_gamepad_ctrl",
                @"icon": @"hammer",
                @"type": self.typeChildPane,
                @"enableCondition": whenNotInGame,
                @"canDismissWithSwipe": @NO,
                @"class": LauncherPrefContCfgViewController.class
            },
            @{@"key": @"custom_mouse_pointer",
                @"icon": @"cursorarrow",
                @"type": self.typeButton,
                @"enableCondition": whenNotInGame,
                @"action": ^void(){
                    [self openMousePointerPicker];
                }
            },
            @{@"key": @"reset_mouse_pointer",
                @"icon": @"arrow.counterclockwise",
                @"type": self.typeButton,
                @"enableCondition": whenNotInGame,
                @"action": ^void(){
                    NSString *path = [NSString stringWithFormat:@"%s/controlmap/mouse_pointer.png", getenv("POJAV_HOME")];
                    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
                    [NSNotificationCenter.defaultCenter postNotificationName:@"MousePointerUpdated" object:nil];
                    [self showSuccessMessage:@"鼠标指针已恢复默认"];
                }
            },
            @{@"key": @"hardware_hide",
                @"icon": @"eye.slash",
                @"hasDetail": @YES,
                @"type": self.typeSwitch,
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
                      title = @"双指呼出键盘";
                  }
                  
                  NSString *statusMsg = isOn ? @"✅ 当前状态: 已开启 (ON)" : @"❌ 当前状态: 已关闭 (OFF)";
                  NSString *msg = [NSString stringWithFormat:@"%@\n\n开启后，在游戏中双指同时长按屏幕可呼出键盘。", statusMsg];
                  
                  UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
                  
                  // 3. 根据当前状态显示不同的按钮
                  if (!isOn) {
                      [alert addAction:[UIAlertAction actionWithTitle:@"开启 (Enable)" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                          // 强制开启
                          setPrefBool(@"control.two_finger_keyboard", YES);
                          [weakSelf showSuccessMessage:@"双指呼出键盘已开启"];
                          // 刷新界面
                          [weakSelf.tableView reloadData];
                      }]];
                  } else {
                      [alert addAction:[UIAlertAction actionWithTitle:@"关闭 (Disable)" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
                          // 强制关闭
                          setPrefBool(@"control.two_finger_keyboard", NO);
                          [weakSelf showSuccessMessage:@"双指呼出键盘已关闭"];
                          // 刷新界面
                          [weakSelf.tableView reloadData];
                      }]];
                  }
                  
                  [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
                  
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
                @"hasDetail": @NO,
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
                    return ![self.getPreference(@"java", @"auto_ram") boolValue] && whenNotInGame();
                },
                @"warnCondition": ^BOOL(DBNumberedSlider *view){
                    return view.value >= NSProcessInfo.processInfo.physicalMemory / 1048576 * 0.37;
                },
                @"warnKey": @"mem_warn"
            }
        ], @[
            // Debug settings - only recommended for developer use
            @{@"icon": @"ladybug"},
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
        ]
    ];

    [super viewDidLoad];
    if (self.navigationController == nil) {
        self.tableView.alpha = 0.9;
    }
    if (NSProcessInfo.processInfo.isMacCatalystApp) {
        UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeClose];
        closeButton.frame = CGRectOffset(closeButton.frame, 10, 10);
        [closeButton addTarget:self action:@selector(actionClose) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:closeButton];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.navigationController == nil) {
        [self.presentingViewController performSelector:@selector(updatePreferenceChanges)];
    }
}

- (void)actionClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark UITableView

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) { // Add to general section
        return [NSString stringWithFormat:@"Angel Aura Amethyst %@\n%@ on %@ (%s)\nPID: %d",
            NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"],
            UIDevice.currentDevice.completeOSVersion, [HostManager GetModelName], getenv("POJAV_DETECTEDINST"), getpid()];
    }

    NSString *footer = NSLocalizedStringWithDefaultValue(([NSString stringWithFormat:@"preference.section.footer.%@", self.prefSections[section]]), @"Localizable", NSBundle.mainBundle, @" ", nil);
    if ([footer isEqualToString:@" "]) {
        return nil;
    }
    return footer;
}

@end