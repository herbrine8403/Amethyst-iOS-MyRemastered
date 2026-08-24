//
//  ShaderVersionViewController.h
//  Amethyst
//
//  View controller for selecting shader versions
//

#import <UIKit/UIKit.h>
#import "ShaderItem.h"
#import "ShaderVersion.h"

NS_ASSUME_NONNULL_BEGIN

@class ShaderVersionViewController;

@protocol ShaderVersionViewControllerDelegate <NSObject>
- (void)shaderVersionViewController:(ShaderVersionViewController *)viewController didSelectVersion:(ShaderVersion *)version;
@end

@interface ShaderVersionViewController : UIViewController

@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property (nonatomic, strong) ShaderItem *shaderItem;
@property (nonatomic, weak) id<ShaderVersionViewControllerDelegate> delegate;
/// 初始 API 来源：1=Modrinth，2=CurseForge；默认 1。
@property (nonatomic, assign) NSInteger initialSource;

// FCL 风格：传入当前 profile 的偏好版本和加载器
// ShaderVersionViewController 会优先选中匹配的 chip，并把匹配的版本置顶
// 不传则保持原有"全部"默认行为
// 补齐与 ModVersionViewController 不对称的 preferred 属性（阶段3统一）
@property (nonatomic, copy, nullable) NSString *preferredGameVersion;
@property (nonatomic, copy, nullable) NSString *preferredLoader;

@end

NS_ASSUME_NONNULL_END
